#!/usr/bin/env python3
"""FC 26 Squad Editor — Python sidecar for the Tauri frontend.

Exposes the battle-tested fifa_squad parser over a localhost JSON API.
The Tauri webview loads static UI and talks to this server via fetch().

Run:  python -m fc26_mcp.sidecar_server [path_to_squad] [--port 8765]
Env:  FC26_SIDECAR_PORT
"""
import argparse
import json
import os
import shutil
import sys
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from fc26_mcp.fifa_squad import SquadFile, career_overview

DEFAULT_META = Path(__file__).parent / "data" / "fifa_ng_db-meta-fc26.xml"
FREE_AGENT_TEAM = 111592
PAGE_SIZE = 400

POSITION_NAMES = {
    0: "GK", 1: "SW", 2: "RWB", 3: "RB", 4: "RCB", 5: "CB", 6: "LCB", 7: "LB",
    8: "LWB", 9: "RDM", 10: "CDM", 11: "LDM", 12: "RM", 13: "RCM", 14: "CM",
    15: "LCM", 16: "LM", 17: "RAM", 18: "CAM", 19: "LAM", 20: "RF", 21: "CF",
    22: "LF", 23: "RW", 24: "RS", 25: "ST", 26: "LS", 27: "LW",
}

# Same guard as the tkinter GUI: these tables must NEVER be raw-edited.
NO_RAW_WRITE_TABLES = frozenset({
    "teamplayerlinks", "career_playercontract", "career_presignedcontract",
    "career_playerloans", "playerloans", "career_players",
})

LOOKUP_LOCK = threading.Lock()


class App:
    """Holds the open squad file + derived caches (single instance, thread-safe)."""

    def __init__(self):
        self.sq = None
        self.path = None
        self.teams = {}
        self.dc_names = {}
        self.full_names = {}
        self.players = None
        self.club_map = {}
        self.club_ids = set()
        self.is_career = False

    # -- loaders ----------------------------------------------------------
    @staticmethod
    def _full_names():
        cands = [
            Path(os.environ.get("FC26_NAMES_FILE", "")),
            Path.home() / "Downloads" / "Example folder - Copy" / "playernames.txt",
            Path.home() / "Downloads" / "playernames.txt",
        ]
        for cand in cands:
            try:
                if not cand or not cand.exists():
                    continue
                out = {}
                with open(cand, encoding="utf-8") as f:
                    f.readline()
                    for line in f:
                        parts = line.rstrip("\n").split("\t")
                        if len(parts) >= 3:
                            try:
                                out[int(parts[0])] = parts[2]
                            except ValueError:
                                pass
                return out
            except OSError:
                continue
        return {}

    def open(self, path):
        sq = SquadFile(str(path), DEFAULT_META)
        meta_names = {m["name"] for m in sq.tables_meta if m["name"]}
        is_career = "career_users" in meta_names and "teamplayerlinks" not in meta_names
        teams = {t["teamid"]: t.get("teamname", "") for t in sq.get_table("teams")} if "teams" in meta_names else {}
        dc = {r["nameid"]: r["name"] for r in sq.get_table("dcplayernames")} if "dcplayernames" in meta_names else {}
        club_ids = {t["teamid"] for t in sq.get_table("teams") if t.get("clubworth", 0) != 0} | {FREE_AGENT_TEAM} if "teams" in meta_names else set()
        club_map = {}
        if "teamplayerlinks" in meta_names:
            for l in sq.get_table("teamplayerlinks"):
                if l["teamid"] in club_ids and l["playerid"] not in club_map:
                    club_map[l["playerid"]] = l["teamid"]
        players = sq.get_table("players") if "players" in meta_names else None
        full_names = self._full_names()
        with LOOKUP_LOCK:
            self.sq, self.path = sq, str(path)
            self.teams, self.dc_names, self.full_names = teams, dc, full_names
            self.players, self.club_map, self.club_ids = players, club_map, club_ids
            self.is_career = is_career
        return {
            "ok": True, "path": str(path), "is_career": is_career,
            "players": len(players) if players else 0, "teams": len(teams),
            "names": f"{len(dc)} edited + {len(full_names)} full",
        }

    # -- helpers ----------------------------------------------------------
    def table_names(self):
        return sorted((m["name"] for m in self.sq.tables_meta if m["name"]), key=str.lower)

    def player_name(self, p):
        dc, fn = self.dc_names, self.full_names
        c = dc.get(p.get("commonnameid", 0), "")
        if c:
            return c
        name = (dc.get(p.get("firstnameid", 0), "") + " " + dc.get(p.get("lastnameid", 0), "")).strip()
        if name:
            return name
        c = fn.get(p.get("commonnameid", 0), "")
        if c:
            return c
        return (fn.get(p.get("firstnameid", 0), "") + " " + fn.get(p.get("lastnameid", 0), "")).strip() or "?"

    def player_row(self, p):
        pid = p.get("playerid", 0)
        name = self.player_name(p)
        if not name or name == "?":
            name = f"Player {pid}"
        tid = self.club_map.get(pid)
        return {
            "playerid": pid,
            "name": name,
            "team": self.teams.get(tid, "") if tid else "(no club)",
            "ovr": p.get("overallrating", ""),
            "pot": p.get("potential", ""),
            "pos": POSITION_NAMES.get(p.get("preferredposition1", -1), ""),
            "contract": p.get("contractvaliduntil", ""),
        }

    def search_players(self, q, limit=400, offset=0):
        q = (q or "").strip()
        ql = q.lower()
        team_hits = [tid for tid, tn in self.teams.items() if tn and ql in tn.lower()]
        idx = []
        for i, p in enumerate(self.players or []):
            pid = p.get("playerid", 0)
            if q.isdigit():
                if str(pid) != q:
                    continue
            elif team_hits:
                if self.club_map.get(pid) not in team_hits:
                    continue
            else:
                if ql not in self.player_name(p).lower():
                    continue
            idx.append(i)
        page = [self.player_row(self.players[i]) for i in idx[offset:offset + limit]]
        return {"rows": page, "total": len(idx), "offset": offset, "limit": limit}

    def table_rows(self, name, limit=400, offset=0, filt=""):
        records, fields = self.sq._parse_table(name)
        cols = [f["name"] for f in fields]
        filt = (filt or "").strip().lower()
        matched = []
        for i, rec in enumerate(records):
            if filt and not any(filt in str(v).lower() for v in rec.values() if v is not None):
                continue
            row = {c: rec.get(c) for c in cols}
            row["_i"] = i  # original record index for edits
            matched.append(row)
        total = len(records)
        page = matched[offset:offset + limit]
        return {"columns": cols, "rows": page, "total": total, "filtered": len(matched), "offset": offset, "limit": limit}

    # -- mutation helpers (guarded) --------------------------------------
    def edit_field(self, table, idx, field, value):
        if table in NO_RAW_WRITE_TABLES:
            raise ValueError(f"Raw edit blocked: '{table}' is transfer-critical. Use Live Editor native calls.")
        rec, fields = self.sq._parse_table(table)
        if idx >= len(rec):
            raise ValueError(f"Row {idx} out of range")
        ftypes = {f["name"]: f["type"] for f in fields}
        if field not in ftypes:
            raise ValueError(f"Unknown field {field}")
        if ftypes[field] != 3:
            # floats/strings not supported by update_field's bit writer for ints only
            raise ValueError(f"Field {field} is type {ftypes[field]}; only integer fields are editable here")
        self.sq.update_field(table, idx, field, int(value))

    def delete_row(self, table, idx):
        if table in NO_RAW_WRITE_TABLES:
            raise ValueError(f"Raw delete blocked: '{table}' is transfer-critical. Use Live Editor native calls.")
        self.sq.delete_record(table, idx)

    def save(self, path=None):
        dst = path or self.path
        if not dst:
            raise ValueError("No file open")
        self.sq.save(dst)
        self.path = dst
        return {"ok": True, "path": dst}

    def backup(self):
        src = Path(self.sq.path)
        bak = Path(os.environ.get("FC26_MCP_DIR", "C:/fc26-mcp")).mkdir(parents=True, exist_ok=True)
        dst = Path(os.environ.get("FC26_MCP_DIR", "C:/fc26-mcp")) / f"backup_{src.stem}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.bak"
        shutil.copy2(src, dst)
        return {"ok": True, "path": str(dst)}

    def settings_dir_files(self):
        d = Path(os.environ.get("LOCALAPPDATA", "")) / "EA SPORTS FC 26" / "settings"
        if not d.exists():
            return {"dir": str(d), "files": []}
        files = sorted(
            (str(p) for p in d.iterdir() if p.is_file() and not str(p).lower().endswith((".txt", ".log"))),
            key=str.lower,
        )
        return {"dir": str(d), "files": files}


app = App()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # keep console clean

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def _err(self, code, msg):
        self._send(code, {"ok": False, "error": str(msg)})

    def do_OPTIONS(self):
        self._send(200, {})

    def do_GET(self):
        u = urlparse(self.path)
        try:
            if u.path == "/api/status":
                if app.sq is None:
                    self._send(200, {"ok": True, "open": False})
                else:
                    self._send(200, {
                        "ok": True, "open": True, "path": app.path,
                        "is_career": app.is_career, "tables": app.table_names(),
                        "settings_dir": str(Path(os.environ.get("LOCALAPPDATA", "")) / "EA SPORTS FC 26" / "settings"),
                    })
            elif u.path == "/api/tables":
                self._send(200, {"ok": True, "tables": app.table_names()} if app.sq else {"ok": False, "error": "no file open"})
            elif u.path == "/api/table":
                q = parse_qs(u.query)
                out = app.table_rows(q.get("name", [""])[0], int(q.get("limit", [PAGE_SIZE])[0]), int(q.get("offset", ["0"])[0]), q.get("filter", [""])[0])
                self._send(200, {"ok": True, **out})
            elif u.path == "/api/players":
                q = parse_qs(u.query)
                out = app.search_players(q.get("q", [""])[0], int(q.get("limit", [PAGE_SIZE])[0]), int(q.get("offset", ["0"])[0]))
                self._send(200, {"ok": True, **out})
            elif u.path == "/api/settings-dir":
                self._send(200, {"ok": True, **app.settings_dir_files()})
            else:
                self._err(404, "not found")
        except Exception as e:
            self._err(500, str(e))

    def do_POST(self):
        u = urlparse(self.path)
        try:
            ln = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(ln).decode("utf-8")) if ln else {}
            if u.path == "/api/open":
                self._send(200, app.open(body.get("path", "")))
            elif u.path == "/api/save":
                self._send(200, app.save(body.get("path")))
            elif u.path == "/api/backup":
                self._send(200, app.backup())
            elif u.path == "/api/edit":
                app.edit_field(body.get("table"), int(body.get("idx")), body.get("field"), body.get("value"))
                self._send(200, {"ok": True})
            elif u.path == "/api/delete":
                app.delete_row(body.get("table"), int(body.get("idx")))
                self._send(200, {"ok": True})
            else:
                self._err(404, "not found")
        except Exception as e:
            self._err(500, str(e))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", help="optional squad file to open at startup")
    parser.add_argument("--port", type=int, default=int(os.environ.get("FC26_SIDECAR_PORT", "8765")))
    args = parser.parse_args()
    if args.path:
        try:
            res = app.open(args.path)
            print(f"Opened: {res['path']} | players={res['players']} names={res['names']}", file=sys.stderr)
        except Exception as e:
            print(f"Open failed: {e}", file=sys.stderr)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"FC26 sidecar listening on http://127.0.0.1:{args.port}", file=sys.stderr, flush=True)
    # Watchdog: when the Tauri parent dies (even hard-killed), its stdin pipe
    # breaks -> EOF -> exit. Active only when launched by the Tauri app.
    if os.environ.get("FC26_SIDECAR_WATCH") == "1":
        def _watch():
            try:
                sys.stdin.read()
            except Exception:
                pass
            os._exit(0)
        threading.Thread(target=_watch, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()