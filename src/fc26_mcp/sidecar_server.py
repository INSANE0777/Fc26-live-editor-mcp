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
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from fc26_mcp.fifa_squad import SquadFile, career_overview
from fc26_mcp import game_assets

DEFAULT_META = Path(__file__).parent / "data" / "fifa_ng_db-meta-fc26.xml"
FREE_AGENT_TEAM = 111592
PAGE_SIZE = 400

POSITION_NAMES = {
    0: "GK", 1: "SW", 2: "RWB", 3: "RB", 4: "RCB", 5: "CB", 6: "LCB", 7: "LB",
    8: "LWB", 9: "RDM", 10: "CDM", 11: "LDM", 12: "RM", 13: "RCM", 14: "CM",
    15: "LCM", 16: "LM", 17: "RAM", 18: "CAM", 19: "LAM", 20: "RF", 21: "CF",
    22: "LF", 23: "RW", 24: "RS", 25: "ST", 26: "LS", 27: "LW",
}

# FIFA stores dates as Gregorian day numbers (epoch offset 2331205); the
# stored *birthdate* is one day AFTER the real birthday. Algorithm mirrors
# Live Editor's core/date.lua FromGregorianDays (verified vs Neymar/Mbappe/Ronaldo).
def _gregorian_to_date(days):
    a = days + 2331205
    b = (4 * a + 3) // 146097
    c = a - (b * 146097) // 4
    d = (4 * c + 3) // 1461
    e = c - (1461 * d) // 4
    m = (5 * e + 2) // 153
    day = -((153 * m + 2) // 5) + e + 1
    month = -(m // 10) * 12 + m + 3
    year = b * 100 + d - 4800 + m // 10
    return date(year, month, day)

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
        self.team_league = {}  # teamid -> leagueid (from leagueteamlinks)
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
        team_league = {}
        if "leagueteamlinks" in meta_names:
            for l in sq.get_table("leagueteamlinks"):
                team_league[l["teamid"]] = l.get("leagueid")
        with LOOKUP_LOCK:
            self.sq, self.path = sq, str(path)
            self.teams, self.dc_names, self.full_names = teams, dc, full_names
            self.players, self.club_map, self.club_ids = players, club_map, club_ids
            self.team_league = team_league
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
        league_id = self.team_league.get(tid) if tid else None
        return {
            "playerid": pid,
            "name": name,
            "team": self.teams.get(tid, "") if tid else "(no club)",
            "ovr": p.get("overallrating", ""),
            "pot": p.get("potential", ""),
            "pos": POSITION_NAMES.get(p.get("preferredposition1", -1), ""),
            "contract": p.get("contractvaliduntil", ""),
            "face": f"/assets/face/{pid}",
            "club_badge": f"/assets/club/{tid}" if tid else None,
            "league_icon": f"/assets/league/{league_id}" if league_id else None,
        }

    def search_players(self, q, limit=400, offset=0, sort=None, dir="asc", has_face=False):
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
            if has_face and game_assets.asset_state("face", pid) == "missing":
                continue  # definitively no face on the CDN
            idx.append(i)
        if sort:
            rows = {i: self.player_row(self.players[i]) for i in idx}
            desc = (dir or "asc") == "desc"
            def key(i):
                v = rows[i].get(sort)
                return (v is None, v)
            idx.sort(key=key, reverse=desc)
        page = [self.player_row(self.players[i]) for i in idx[offset:offset + limit]]
        return {"rows": page, "total": len(idx), "offset": offset, "limit": limit}

    # -- player profile ---------------------------------------------------
    @staticmethod
    def _birthdate_str(raw):
        """FIFA stores birthdate as Gregorian day number (epoch 2331205);
        the stored value is one day AFTER the actual birthday."""
        if not raw:
            return ""
        d = _gregorian_to_date(int(raw)) - timedelta(days=1)
        return d.isoformat()

    def player_profile(self, pid):
        p = next((x for x in (self.players or []) if x.get("playerid") == pid), None)
        if p is None:
            raise ValueError(f"Player {pid} not found")
        tid = self.club_map.get(pid)
        league_id = self.team_league.get(tid) if tid else None
        pos_ids = [p.get(f"preferredposition{i}", -1) for i in range(1, 8)]
        pos = [POSITION_NAMES.get(x, "") for x in pos_ids if x and x != -1]
        # jersey number from teamplayerlinks (non-career squad)
        jersey = None
        if "teamplayerlinks" in {m["name"] for m in self.sq.tables_meta if m["name"]}:
            for l in self.sq.get_table("teamplayerlinks"):
                if l.get("playerid") == pid:
                    jersey = l.get("jerseynumber")
                    break
        base = self.player_row(p)
        base.update({
            "firstname": self._name_str(p.get("firstnameid", 0)),
            "lastname": self._name_str(p.get("lastnameid", 0)),
            "jersey_name": self._name_str(p.get("playerjerseynameid", 0)),
            "birthdate": self._birthdate_str(p.get("birthdate")),
            "height_cm": p.get("height"),
            "weight_kg": p.get("weight"),
            "preferred_foot": p.get("preferredfoot"),
            "skill_moves": p.get("skillmoves"),
            "weak_foot": p.get("weakfootabilitytypecode"),
            "positions": pos,
            "nationality": p.get("nationality"),
            "nation_flag": f"/assets/nation/{p.get('nationality')}" if p.get("nationality") else None,
            "jersey_number": jersey,
            "is_retiring": p.get("isretiring", 0),
            "attributes": {
                "pace": [("Acceleration", p.get("acceleration")), ("Sprint Speed", p.get("sprintspeed"))],
                "shooting": [("Finishing", p.get("finishing")), ("Long Shots", p.get("longshots")),
                             ("Positioning", p.get("positioning")), ("Penalties", p.get("penalties")),
                             ("Volleys", p.get("volleys")), ("Shot Power", p.get("shotpower"))],
                "passing": [("Crossing", p.get("crossing")), ("Short Pass", p.get("shortpassing")),
                             ("Long Pass", p.get("longpassing")), ("Vision", p.get("vision")),
                             ("FK Accuracy", p.get("freekickaccuracy")), ("Curve", p.get("curve"))],
                "dribbling": [("Dribbling", p.get("dribbling")), ("Agility", p.get("agility")),
                               ("Balance", p.get("balance")), ("Ball Control", p.get("ballcontrol")),
                               ("Composure", p.get("composure")), ("Reactions", p.get("reactions"))],
                "defending": [("Def. Awareness", p.get("defensiveawareness")), ("Interceptions", p.get("interceptions")),
                               ("Standing Tackle", p.get("standingtackle")), ("Sliding Tackle", p.get("slidingtackle")),
                               ("Heading Acc.", p.get("headingaccuracy"))],
                "physical": [("Jumping", p.get("jumping")), ("Stamina", p.get("stamina")),
                              ("Strength", p.get("strength")), ("Aggression", p.get("aggression"))],
                "goalkeeping": [("Diving", p.get("gkdiving")), ("Handling", p.get("gkhandling")),
                                 ("Kicking", p.get("gkkicking")), ("Reflexes", p.get("gkreflexes")),
                                 ("Speed", p.get("gkspeed")), ("Positioning", p.get("gkpositioning"))],
            },
            "team_id": tid,
            "league_id": league_id,
            "loaned": self.is_loaned_out(pid),
            "loan_to_team": self.loan_target(pid),
        })
        return base

    def _name_str(self, nid):
        if not nid:
            return ""
        return (self.dc_names.get(nid, "") or self.full_names.get(nid, "") or "")

    def is_loaned_out(self, pid):
        if "playerloans" not in {m["name"] for m in self.sq.tables_meta if m["name"]}:
            return False
        for l in self.sq.get_table("playerloans"):
            if l.get("playerid") == pid:
                return True
        return False

    def loan_target(self, pid):
        if "playerloans" not in {m["name"] for m in self.sq.tables_meta if m["name"]}:
            return None
        for l in self.sq.get_table("playerloans"):
            if l.get("playerid") == pid and l.get("teamidloanedfrom"):
                return l.get("teamidloanedfrom")
        return None

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

    # -- action scripts (native transfers via Live Editor) ---------------
    ACTION_LOG = r"C:/fc26-mcp/sidecar_actions_log.txt"

    def _fc_wage(self, ov):
        if ov >= 90: return 240000
        if ov >= 88: return 185000
        if ov >= 86: return 145000
        if ov >= 84: return 110000
        if ov >= 82: return 88000
        if ov >= 80: return 68000
        if ov >= 78: return 53000
        if ov >= 76: return 40000
        if ov >= 74: return 30000
        if ov >= 72: return 22000
        if ov >= 70: return 16000
        if ov >= 68: return 12000
        if ov >= 66: return 9000
        if ov >= 64: return 7000
        if ov >= 62: return 5500
        if ov >= 60: return 4500
        return 3000

    def make_action_script(self, kind, pid, tid=None, months=36, wage=None):
            """Generate a Live Editor Lua script for one native action.

            kind: transfer | loan | terminate | release
            All calls go through cTransferPlayer / cLoanPlayer / TerminateLoan
            (native), which update the in-memory career managers — raw DB edits
            corrupt saves. Semantics:
              transfer  -> permanent move to another club (cTransferPlayer)
              loan      -> temporary loan to another club (cLoanPlayer)
              terminate -> terminate the LOAN, player returns to parent club
              release   -> release from team: move to Free Agents (111592)
            Script is idempotent: skips if already at target / not loaned.
            Every action verifies with GetTeamIdFromPlayerId / IsPlayerLoanedOut;
            pcall results are NOT trusted (cTransferPlayer logs its own failure
            and returns without throwing).
            """
            p = next((x for x in (self.players or []) if x.get("playerid") == pid), None)
            if p is None:
                raise ValueError(f"Player {pid} not found")
            name = self.player_name(p)
            ov = int(p.get("overallrating") or 60)
            wage = int(wage) if wage else self._fc_wage(ov)
            months = int(months or 36)
            out = Path(os.environ.get("FC26_MCP_DIR", "C:/fc26-mcp")) / "profile_action.lua"

            header = LOG_HEAD % _lua_str(str(self.ACTION_LOG))
            nm = _lua_str(name)  # e.g. "Yan Diomande" — valid Lua string literal

            if kind == "terminate":
                clauses = ["-- profile_action.lua -- Terminate loan (native, idempotent)\n"]
                clauses.append(header)
                clauses.append(f"local pid = {pid}\n")
                clauses.append("log('TERMINATE start pid=' .. pid)\n")
                clauses.append("local ok, loaned = pcall(IsPlayerLoanedOut, pid)\n")
                clauses.append("if ok and loaned then\n")
                clauses.append("    local ok2 = pcall(TerminateLoan, pid)\n")
                clauses.append("    local ok3, tid = pcall(GetTeamIdFromPlayerId, pid)\n")
                clauses.append("    local res = (ok3 and tid and tid > 0) and 'OK' or 'FAIL'\n")
                clauses.append(f"    log('TERMINATE ' .. {nm} .. ' pid=' .. pid .. ' res=' .. res .. ' after=' .. tostring(tid) .. ' pcall=' .. tostring(ok2))\n")
                clauses.append("else\n")
                clauses.append(f"    log('TERMINATE ' .. {nm} .. ' not loaned, skip')\n")
                clauses.append("end\n")
                clauses.append("log('ACTION DONE')\n")
                body = "".join(clauses)
            elif kind == "release":
                clauses = ["-- profile_action.lua -- Release to free agents (native, idempotent)\n"]
                clauses.append(header)
                clauses.append(f"local pid = {pid}\n")
                clauses.append("log('RELEASE start pid=' .. pid)\n")
                clauses.append("local ok, cur = pcall(GetTeamIdFromPlayerId, pid)\n")
                clauses.append(f"if ok and cur and cur > 0 and cur ~= {FREE_AGENT_TEAM} then\n")
                clauses.append(f"    pcall(cTransferPlayer, pid, cur, {FREE_AGENT_TEAM}, 0, -1, {wage}, {months})\n")
                clauses.append("    local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)\n")
                clauses.append(f"    local res = (ok2 and cur2 == {FREE_AGENT_TEAM}) and 'OK' or 'FAIL'\n")
                clauses.append(f"    log('RELEASE ' .. {nm} .. ' pid=' .. pid .. ' res=' .. res .. ' after=' .. tostring(cur2) .. ' pcall=' .. tostring(ok2))\n")
                clauses.append("else\n")
                clauses.append(f"    log('RELEASE ' .. {nm} .. ' already free, skip')\n")
                clauses.append("end\n")
                clauses.append("log('ACTION DONE')\n")
                body = "".join(clauses)
            elif kind in ("transfer", "loan"):
                if not tid:
                    raise ValueError("Need target team id")
                tid = int(tid)
                clauses = [f"-- profile_action.lua -- NATIVE {kind} (idempotent)\n"]
                clauses.append(header)
                clauses.append(f"local pid, tid = {pid}, {tid}\n")
                clauses.append(f"log('{kind.upper()} start pid=' .. pid .. ' tid=' .. tid)\n")
                clauses.append("local ok0, cur = pcall(GetTeamIdFromPlayerId, pid)\n")
                clauses.append("if ok0 and cur == tid then\n")
                clauses.append(f"    log('{kind.upper()} ' .. {nm} .. ' already at ' .. tid .. ', skip')\n")
                clauses.append("else\n")
                clauses.append("    local okl, loaned = pcall(IsPlayerLoanedOut, pid)\n")
                clauses.append("    if okl and loaned then pcall(TerminateLoan, pid) end\n")
                clauses.append("    local from = (ok0 and cur and cur > 0) and cur or 0\n")
                if kind == "loan":
                    clauses.append(f"    pcall(cLoanPlayer, pid, from, tid, {months}, 0)\n")
                    clauses.append("    local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)\n")
                    clauses.append("    local ol, lo = pcall(IsPlayerLoanedOut, pid)\n")
                    clauses.append("    local res = (ol and lo) and 'OK-loan' or '??'\n")
                    clauses.append(f"    log('LOAN ' .. {nm} .. ' pid=' .. pid .. ' -> ' .. tid .. ' [' .. res .. '] after=' .. tostring(cur2) .. ' loaned=' .. tostring(lo) .. ' pcall=' .. tostring(ok2))\n")
                else:
                    clauses.append(f"    pcall(cTransferPlayer, pid, from, tid, 0, -1, {wage}, {months})\n")
                    clauses.append("    local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)\n")
                    clauses.append("    local res = (ok2 and cur2 == tid) and 'OK' or 'FAIL'\n")
                    clauses.append(f"    log('TRANSFER ' .. {nm} .. ' pid=' .. pid .. ' -> ' .. tid .. ' [' .. res .. '] after=' .. tostring(cur2) .. ' pcall=' .. tostring(ok2))\n")
                clauses.append("end\n")
                clauses.append("log('ACTION DONE')\n")
                body = "".join(clauses)
            else:
                raise ValueError(f"Unknown action kind: {kind}")
            out.write_text(body, encoding="utf-8")
            return {
                "ok": True, "kind": kind, "pid": pid, "player": name,
                "script": str(out), "log": self.ACTION_LOG,
                "instruction": (
                    "Open the script in Live Editor -> Lua Engine -> Run, then SAVE THE CAREER. "
                    "Native calls update the in-memory managers; direct DB edits corrupt the save. "
                    "The script is idempotent — rerunning after a crash is safe (verify in "
                    "%s)." % self.ACTION_LOG),
            }


LOG_HEAD = (
    "-- log helper\n"
    "local LOG = %s\n"
    "local function log(m) local f = io.open(LOG, 'a') if f then "
    "f:write(os.date('%%Y-%%m-%%d %%H:%%M:%%S') .. ' ' .. m .. string.char(10)) f:close() end end\n"
)
app = App()


def _lua_str(s):
    return json.dumps(str(s), ensure_ascii=False)  # valid Lua string literal


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # keep console clean

    def _serve_asset(self, path):
        """Serve /assets/{face|club|club_dark|league|nation}/{id}."""
        parts = path.split("/")  # ['', 'assets', kind, id]
        if len(parts) < 4:
            self._err(400, "bad asset path")
            return
        kind, asset_id = parts[2], parts[3]
        if not asset_id.isdigit():
            self._err(400, "asset id must be numeric")
            return
        if kind not in game_assets.KINDS:
            self._err(400, f"unknown asset kind {kind}")
            return
        state = game_assets.asset_state(kind, int(asset_id))
        if state == "missing":
            # definitive CDN 404 (0-byte marker): tell the UI to stop
            # retrying — no face exists for this player.
            self.send_response(404)
            self.send_header("X-Asset-State", "missing")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        lp = game_assets.asset_url(kind, int(asset_id))
        try:
            data = Path(lp).read_bytes() if lp else None
        except OSError:
            data = None
        if not data:
            # Not cached yet (background download running). no-store so the
            # browser stops caching the 404 and the UI's retry-with-backoff
            # re-fires once the file lands.
            self.send_response(404)
            self.send_header("X-Asset-State", "pending")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(b"asset not cached yet")
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "max-age=86400")
        self.end_headers()
        self.wfile.write(data)

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
            if u.path.startswith("/assets/"):
                self._serve_asset(u.path)
            elif u.path.startswith("/api/player/"):
                pid = int(u.path.split("/")[-1])
                self._send(200, {"ok": True, "player": app.player_profile(pid)})
            elif u.path == "/api/teams":
                q = parse_qs(u.query).get("q", [""])[0].strip().lower()
                rows = [{"teamid": t, "name": n} for t, n in sorted(app.teams.items()) if not q or q in (n or "").lower()]
                self._send(200, {"ok": True, "rows": rows[:500]})
            elif u.path == "/api/status":
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
                out = app.search_players(
                    q.get("q", [""])[0],
                    int(q.get("limit", [PAGE_SIZE])[0]),
                    int(q.get("offset", ["0"])[0]),
                    q.get("sort", [None])[0],
                    q.get("dir", ["asc"])[0],
                    q.get("has_face", [""])[0] == "1",
                )
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
            elif u.path == "/api/action":
                kind = body.get("kind", "")
                pid = int(body.get("pid", 0))
                out = app.make_action_script(kind, pid, body.get("tid"), body.get("months", 36), body.get("wage"))
                self._send(200, out)
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