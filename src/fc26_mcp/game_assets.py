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

Downloads are ASYNC: a single worker processes the queue while the HTTP
layer never blocks. Missing assets return a "not cached yet" signal
(404 + no-store) so the browser retries once the file lands. Requested
assets are promoted to the FRONT of the queue, so the face the user is
looking at downloads next. Permanent 0-byte markers are written only on
definitive CDN 404/403/410 (players without a real face); transient
errors leave no marker and retry on the next request.
"""
import os
import queue
import threading
import time
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

# The 30/min limit came from fctoolshub.com's site (Laravel API), NOT the
# DigitalOcean Spaces CDN. The bucket serves static PNGs fast and handles
# parallel fetches (verified). A small worker pool drains the queue in
# seconds instead of minutes.
WORKER_GAP = 0.05
WORKERS = 3
HTTP_TIMEOUT = 12

_cache_dir = DEFAULT_CACHE
_queue = queue.deque()          # (kind, asset_id) download jobs, front = next
_pending = set()                # queued or in-flight (kind, id)
_waker = threading.Event()
_lock = threading.Lock()
_worker_started = False


def set_cache_dir(path):
    global _cache_dir
    _cache_dir = Path(path)


def _local_path(kind, asset_id):
    return _cache_dir / kind / f"{asset_id}.png"


def _download_job(job):
    kind, asset_id = job
    dest = _local_path(kind, asset_id)
    template = KINDS.get(kind)
    if not template:
        return
    remote = f"{CDN}/{template.format(asset_id)}"
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        req = urllib.request.Request(remote, headers={"User-Agent": "fc26-squad-editor/0.1"})
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            data = r.read()
        if data:
            dest.write_bytes(data)
        else:
            dest.write_bytes(b"")  # 200 with empty body -> treat as missing
    except urllib.error.HTTPError as e:
        if e.code in (404, 403, 410):
            try:
                dest.write_bytes(b"")  # definitive missing -> permanent marker
            except Exception:
                pass
    except Exception:
        pass  # transient: no marker, retried on next request
    finally:
        with _lock:
            _pending.discard(job)


def _worker():
    while True:
        job = None
        with _lock:
            if _queue:
                job = _queue.popleft()
        if job is None:
            _waker.wait(max(WORKER_GAP, 0.05))
            _waker.clear()
            continue
        _download_job(job)
        time.sleep(WORKER_GAP)


def _ensure_worker():
    global _worker_started
    with _lock:
        if not _worker_started:
            _worker_started = True
            for _ in range(WORKERS):
                threading.Thread(target=_worker, name="asset-downloader", daemon=True).start()


def asset_state(kind, asset_id):
    """Return 'cached' | 'missing' (definitive CDN 404) | None (downloading).
    None means the HTTP layer should answer 404 no-store and the browser
    will retry once the file lands.
    """
    lp = _local_path(kind, asset_id)
    if lp.exists() and lp.stat().st_size > 0:
        return "cached"
    if lp.exists() and lp.stat().st_size == 0:
        return "missing"
    return None


def asset_url(kind, asset_id):
    """Return path if cached (or known-missing marker), else enqueue the
    download (front of queue if already pending) and return None.

    None means "not cached yet" — the HTTP layer answers 404 no-store and
    the browser retries shortly after; the file lands within ~1s of the
    worker picking it up because fresh requests jump the queue.
    """
    lp = _local_path(kind, asset_id)
    if lp.exists() and lp.stat().st_size > 0:
        return str(lp)
    if lp.exists() and lp.stat().st_size == 0:
        return None  # known-missing marker (definitive CDN 404)
    if kind not in KINDS:
        return None
    _ensure_worker()
    with _lock:
        key = (kind, asset_id)
        if key not in _pending:
            _pending.add(key)
            _queue.append(key)
            _waker.set()
        else:
            # already queued — promote to front so the visible face wins
            try:
                _queue.remove(key)
            except ValueError:
                pass
            _queue.appendleft(key)
            _waker.set()
    return None