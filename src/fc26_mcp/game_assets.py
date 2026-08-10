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
leagueid/nationid. Downloads happen once per asset, then serve from disk.
"""
import os
import threading
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

_lock = threading.Lock()
_cache_dir = DEFAULT_CACHE


def set_cache_dir(path):
    global _cache_dir
    _cache_dir = Path(path)


def _local_path(kind, asset_id):
    return _cache_dir / kind / f"{asset_id}.png"


def asset_url(kind, asset_id):
    """Return a local cache path for this asset, downloading it if missing.

    The URL is returned even on failure so callers can render a fallback;
    failed downloads write a 0-byte marker to avoid re-hammering the CDN."""
    lp = _local_path(kind, asset_id)
    if lp.exists() and lp.stat().st_size > 0:
        return str(lp)
    if lp.exists() and lp.stat().st_size == 0:
        return None  # known-missing marker
    template = KINDS.get(kind)
    if not template:
        return None
    remote = f"{CDN}/{template.format(asset_id)}"
    ok = _download(remote, lp)
    return str(lp) if ok else None


def _download(url, dest):
    with _lock:  # serialize so 30/min rate limit isn't blown by bursts
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            req = urllib.request.Request(url, headers={"User-Agent": "fc26-squad-editor/0.1"})
            with urllib.request.urlopen(req, timeout=10) as r:
                data = r.read()
            if not data:
                dest.write_bytes(b"")
                return False
            dest.write_bytes(data)
            return True
        except Exception:
            try:
                dest.write_bytes(b"")
            except Exception:
                pass
            return False