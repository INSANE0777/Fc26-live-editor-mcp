#!/usr/bin/env python3
"""FC26 game-asset cache — downloads faces/badges/league icons/nation flags
from the fctoolshub CDN on demand and caches them on disk.

CDN base (reverse-engineered from fctoolshub.com Inertia responses):
  players/{eaId}.png        -> 180x180 player face
  clubs/light/{eaId}.png    -> 256x256 club badge (light bg)
  clubs/dark/{eaId}.png     -> club badge (dark bg)
  leagues/light/{eaId}.png  -> 256x256 league icon
  nations/{eaId}.png        -> nation flag

The squad file uses the SAME EA ids, so eaId == squad playerid/teamid/
leagueid/nationid.

Downloads are ASYNC: a single worker queue throttles the CDN (30 req/min
limit) while the HTTP layer never blocks. Missing assets are served as a
"not cached yet" signal (404 + no-store) so the browser retries once the
worker has written the file. Failed/404 CDN responses write a 0-byte marker
so we never re-hammer the CDN for the same asset.
"""
import os
import queue
import threading
import urllib.error
import urllib.request
from pathlib import Path

CDN = "https://generacion-fut.ams3.cdn.digitaloceanspaces.com/game_assets/fc26"
DEFAULT_CACHE = Path(os.environ.get("LOCALAPPDATA", "")) / "fc26-squad-editor" / "assets"

# asset type -> relative CDN path template
KINDS = {
    "face": "players/{}.png",
    "club": "clubs/light/{}.png",
    "club_dark": "clubs/dark/{}.png",
    "league": "leagues/light/{}.png",
    "nation": "nations/{}.png",
}

MIN_INTERVAL = 2.0  # CDN is rate-limited ~30/min -> >=2s between downloads

_cache_dir = DEFAULT_CACHE
_queue = queue.Queue()          # (kind, asset_id) download jobs
_pending = set()                # in-flight or queued (kind, id)
_waker = threading.Event()      # to wake the worker on new jobs
_lock = threading.Lock()        # guards _pending
_worker_started = False


def set_cache_dir(path):
    global _cache_dir
    _cache_dir = Path(path)


def _local_path(kind, asset_id):
    return _cache_dir / kind / f"{asset_id}.png"


def _mark_done(kind, asset_id, ok):
    with _lock:
        _pending.discard((kind, asset_id))


def _download_job(job):
    kind, asset_id = job
    dest = _local_path(kind, asset_id)
    template = KINDS.get(kind)
    if not template:
        _mark_done(kind, asset_id, False)
        return
    remote = f"{CDN}/{template.format(asset_id)}"
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        req = urllib.request.Request(remote, headers={"User-Agent": "fc26-squad-editor/0.1"})
        with urllib.request.urlopen(req, timeout=12) as r:
            data = r.read()
        if data:
            dest.write_bytes(data)
        else:
            dest.write_bytes(b"")  # server 404 with empty body -> permanent marker
    except urllib.error.HTTPError as e:
        if e.code in (404, 403, 410):
            try:
                dest.write_bytes(b"")  # definitive missing -> permanent marker
            except Exception:
                pass
        # other HTTP errors: leave no marker, will retry on next request
    except Exception:
        # transient network failure: leave no marker, will retry on next request
        pass
    finally:
        _mark_done(kind, asset_id, False)


def _worker():
    while True:
        job = None
        try:
            with _lock:
                if not _queue.empty():
                    job = _queue.get_nowait()
        except queue.Empty:
            pass
        if job is None:
            _waker.wait(MIN_INTERVAL)
            _waker.clear()
            continue
        _download_job(job)
        # throttle: min interval between CDN hits
        import time
        time.sleep(MIN_INTERVAL)


def _ensure_worker():
    global _worker_started
    with _lock:
        if not _worker_started:
            _worker_started = True
            t = threading.Thread(target=_worker, name="asset-downloader", daemon=True)
            t.start()


def asset_url(kind, asset_id):
    """Return path if the asset is cached (or a known-missing marker),
    else enqueue a background download and return None.

    Callers deal with None by returning 'not cached yet' (browser retries)."""
    lp = _local_path(kind, asset_id)
    if lp.exists() and lp.stat().st_size > 0:
        return str(lp)
    if lp.exists() and lp.stat().st_size == 0:
        return None          # known-missing marker (may be a real 404)
    if kind not in KINDS:
        return None
    _ensure_worker()
    with _lock:
        key = (kind, asset_id)
        if key not in _pending:
            _pending.add(key)
            _queue.put(key)
            _waker.set()
    return None