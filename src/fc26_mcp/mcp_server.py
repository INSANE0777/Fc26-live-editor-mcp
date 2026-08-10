#!/usr/bin/env python3
"""MCP server for FC 26 squad file editing.

Communicates over stdio using MCP JSON-RPC protocol.
"""

import argparse
import importlib.resources as pkg_resources
import json
import sys
import os
import difflib
from pathlib import Path

from fc26_mcp.fifa_squad import SquadFile, detect_save_type, find_career_files, career_overview

DEFAULT_SQUAD = "SquadsFIFER'sBeta1xRODE'sNewSeasonModAlpha3"
DEFAULT_META = str(pkg_resources.files("fc26_mcp.data") / "fifa_ng_db-meta-fc26.xml")
SETTINGS_DIR = Path(os.environ.get("LOCALAPPDATA", "")) / "EA SPORTS FC 26" / "settings"

_squad = None
_squad_error = None


def set_file(path):
    """Switch the active file (squad OR career save) and validate it loads."""
    global _squad, _squad_error
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"File not found: {p}")
    kind = detect_save_type(p) or "unknown"
    _squad = SquadFile(str(p), DEFAULT_META)
    _squad_error = None
    return {"path": str(p), "kind": kind, "tables": sorted(m["name"] for m in _squad.tables_meta if m["name"])}


def get_squad():
    global _squad, _squad_error
    if _squad is None and _squad_error is None:
        squad_path = os.environ.get("FIFA_SQUAD_FILE", DEFAULT_SQUAD)
        meta_path = os.environ.get("FIFA_META_FILE", DEFAULT_META)
        try:
            _squad = SquadFile(squad_path, meta_path)
        except Exception as e:
            _squad_error = str(e)
    if _squad_error:
        raise RuntimeError(f"Squad file error: {_squad_error}")
    return _squad


def make_error(id_, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": id_, "error": err}


def make_result(id_, result):
    return {"jsonrpc": "2.0", "id": id_, "result": result}


def tool_list():
    return {
        "tools": [
            {
                "name": "list_clubs",
                "description": "List all clubs/teams in the squad file with their IDs and names.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "search": {"type": "string", "description": "Optional substring to filter club names."}
                    }
                }
            },
            {
                "name": "search_players",
                "description": "Search players by name. Returns player IDs and current clubs.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "Player name (first, last, or common name) to search for."},
                        "club": {"type": "string", "description": "Optional club name to restrict search."},
                        "limit": {"type": "integer", "description": "Maximum results. Default 20."}
                    },
                    "required": ["name"]
                }
            },
            {
                "name": "get_player_club",
                "description": "Get the current club for a player by name or ID.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "playerid": {"type": "integer", "description": "Player ID."},
                        "name": {"type": "string", "description": "Player name (if ID not provided)."}
                    }
                }
            },
            {
                "name": "list_career_saves",
                "description": "List FC 26 career-mode save files (CmMgr*) found in the settings directory.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "directory": {"type": "string", "description": "Optional settings dir. Defaults to LOCALAPPDATA\\EA SPORTS FC 26\\settings."}
                    }
                }
            },
            {
                "name": "set_active_file",
                "description": "Open a squad file OR career save as the active file for all tools. Returns kind + available tables.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "path": {"type": "string", "description": "Full path to a Squads* or CmMgr* file."}
                    },
                    "required": ["path"]
                }
            },
            {
                "name": "list_db_tables",
                "description": "Tables present in the active file (squad tables for squads, the 33 career tables for career saves).",
                "inputSchema": {"type": "object", "properties": {}}
            },
            {
                "name": "get_table_data",
                "description": "Read rows of any DB table in the active file with their fields.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "table": {"type": "string", "description": "Table name, e.g. career_users or teamplayerlinks."},
                        "fields": {"type": "string", "description": "Comma-separated field subset (optional)."},
                        "filter": {"type": "string", "description": "Optional substring filter across cell values."},
                        "limit": {"type": "integer", "description": "Max rows. Default 50, max 500."}
                    },
                    "required": ["table"]
                }
            },
            {
                "name": "edit_table_field",
                "description": "Set an integer field on a row of the active file's DB table. REFUSES raw writes to transfer-critical tables (teamplayerlinks, career_playercontract, etc.) — those must go through native Live Editor calls, since the game reads wage/contract/squad state from in-memory managers and raw DB edits corrupt the save. Career: e.g. career_users.clubteamid / wage.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "table": {"type": "string"},
                        "row": {"type": "integer", "description": "Row index (0-based, as returned by get_table_data)."},
                        "field": {"type": "string"},
                        "value": {"type": "integer"},
                        "save_path": {"type": "string", "description": "Optional output path to save immediately. Default: no save."}
                    },
                    "required": ["table", "row", "field", "value"]
                }
            },
            {
                "name": "get_career_overview",
                "description": "Decoded summary of the active career file: user/manager/career_users record, calendar, contract count.",
                "inputSchema": {"type": "object", "properties": {}}
            },
            {
                "name": "plan_transfers",
                "description": "Plan transfers without applying them. Returns what would change.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "transfers": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "playerid": {"type": "integer"},
                                    "player": {"type": "string"},
                                    "new_teamid": {"type": "integer"},
                                    "new_club": {"type": "string"}
                                }
                            },
                            "description": "List of transfers. Provide either playerid or player name, and either new_teamid or new_club name."
                        }
                    },
                    "required": ["transfers"]
                }
            },
            {
                "name": "apply_transfers",
                "description": "Generate a Live Editor Lua script that applies transfers with NATIVE calls (cTransferPlayer / cLoanPlayer) — the only path that updates the game's in-memory career managers. Direct DB edits break the save (wage -1, contract -1, broken morale/sharpness). Returns the script path; run it in LE Lua Engine then save the career. Idempotent (skips already-moved players), safe to rerun after a crash.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "transfers": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "playerid": {"type": "integer"},
                                    "player": {"type": "string"},
                                    "new_teamid": {"type": "integer"},
                                    "new_club": {"type": "string"},
                                    "wage": {"type": "integer", "description": "Optional weekly wage override. Defaults to FC band by OVR."},
                                    "months": {"type": "integer", "description": "Optional contract length override in months."}
                                }
                            },
                            "description": "List of transfers. Provide either playerid or player name, and either new_teamid or new_club name."
                        },
                        "contract_months": {"type": "integer", "description": "Default contract length in months (default 36)."},
                        "output_file": {"type": "string", "description": "Optional output path for the generated Lua script. Defaults to C:/fc26-mcp/apply_transfers_native.lua."}
                    },
                    "required": ["transfers"]
                }
            }
        ]
    }


def _resolve_team(sq, name_or_id):
    teams = sq.get_table("teams")
    if isinstance(name_or_id, int):
        for t in teams:
            if t["teamid"] == name_or_id:
                return t["teamid"], t["teamname"]
        return None, None
    name = str(name_or_id).lower()
    best = None
    best_score = 0.0
    for t in teams:
        tname = (t.get("teamname") or "").lower()
        abbr = (t.get("teamabbreviation") or "").lower()
        if name in tname or name in abbr:
            return t["teamid"], t["teamname"]
        score = difflib.SequenceMatcher(None, name, tname).ratio()
        if score > best_score:
            best_score = score
            best = t
    if best and best_score > 0.6:
        return best["teamid"], best["teamname"]
    return None, None


def _resolve_player(sq, name_or_id):
    players = sq.get_table("players")
    dc = {r["nameid"]: r["name"] for r in sq.get_table("dcplayernames")}
    if isinstance(name_or_id, int):
        for p in players:
            if p["playerid"] == name_or_id:
                return p["playerid"], _player_name(p, dc)
        return None, None
    name = str(name_or_id).lower()
    matches = []
    for p in players:
        pname = _player_name(p, dc)
        if name in pname.lower():
            matches.append((p["playerid"], _player_name(p, dc), len(pname)))
    if matches:
        matches.sort(key=lambda x: x[2])
        return matches[0][0], matches[0][1]
    best = None
    best_score = 0.0
    for p in players:
        pname = _player_name(p, dc)
        score = difflib.SequenceMatcher(None, name, pname.lower()).ratio()
        if score > best_score:
            best_score = score
            best = (p["playerid"], pname)
    if best and best_score > 0.6:
        return best
    return None, None


def _player_name(p, dc):
    first = dc.get(p.get("firstnameid", 0), "")
    last = dc.get(p.get("lastnameid", 0), "")
    common = dc.get(p.get("commonnameid", 0), "")
    jersey = dc.get(p.get("playerjerseynameid", 0), "")
    return common or f"{first} {last}".strip() or jersey or f"Player#{p.get('playerid')}"


def handle_list_clubs(args):
    sq = get_squad()
    search = (args.get("search") or "").lower()
    teams = sq.get_table("teams")
    out = []
    for t in teams:
        name = t.get("teamname", "")
        if search and search not in name.lower():
            continue
        out.append({"teamid": t["teamid"], "teamname": name, "abbreviation": t.get("teamabbreviation", "")})
    return {"clubs": out, "count": len(out)}


FREE_AGENT_TEAM = 111592  # NG - FA


def _club_ids(sq):
    """Team IDs that are clubs (clubworth != 0) plus the free-agent team.
    National teams have clubworth == 0 and are NOT in this set."""
    teams = sq.get_table("teams")
    return {t["teamid"] for t in teams if t["clubworth"] != 0} | {FREE_AGENT_TEAM}


def handle_search_players(args):
    sq = get_squad()
    name = (args.get("name") or "").lower()
    club_filter = (args.get("club") or "").lower()
    limit = args.get("limit", 20)
    if not isinstance(limit, int) or limit <= 0:
        limit = 20
    limit = min(limit, 200)  # cap to avoid context blowup

    teams = {t["teamid"]: t for t in sq.get_table("teams")}
    players = sq.get_table("players")
    dc = {r["nameid"]: r["name"] for r in sq.get_table("dcplayernames")}
    links = sq.get_table("teamplayerlinks")
    club_ids = _club_ids(sq)

    player_team = {}
    for l in links:
        pid = l["playerid"]
        tid = l["teamid"]
        if pid not in player_team or tid in club_ids:
            player_team[pid] = tid

    results = []
    for p in players:
        pname = _player_name(p, dc)
        if name not in pname.lower():
            continue
        tid = player_team.get(p["playerid"])
        t = teams.get(tid, {})
        if club_filter and club_filter not in (t.get("teamname") or "").lower():
            continue
        results.append({
            "playerid": p["playerid"],
            "name": pname,
            "overallrating": p.get("overallrating"),
            "teamid": tid,
            "teamname": t.get("teamname", "")
        })
        if len(results) >= limit:
            break
    return {"players": results, "count": len(results)}


def handle_get_player_club(args):
    sq = get_squad()
    playerid = args.get("playerid")
    name = args.get("name")
    if playerid is None and not name:
        raise ValueError("Provide playerid or name")
    if playerid is not None:
        pid, pname = _resolve_player(sq, int(playerid))
    else:
        pid, pname = _resolve_player(sq, name)
    if pid is None:
        return {"found": False, "message": "Player not found"}

    teams = {t["teamid"]: t for t in sq.get_table("teams")}
    links = sq.get_table("teamplayerlinks")
    club_ids = _club_ids(sq)

    club_link = None
    any_link = None
    for l in links:
        if l["playerid"] == pid:
            any_link = l
            if l["teamid"] in club_ids:
                club_link = l
                break
    l = club_link or any_link
    if l is None:
        return {"found": True, "playerid": pid, "name": pname, "teamid": None, "teamname": "Unattached"}
    tid = l["teamid"]
    t = teams.get(tid, {})
    return {"found": True, "playerid": pid, "name": pname, "teamid": tid, "teamname": t.get("teamname", "")}


def _normalize_transfers(sq, transfers):
    normalized = []
    for tr in transfers:
        playerid = tr.get("playerid")
        player_name = tr.get("player")
        new_teamid = tr.get("new_teamid")
        new_club = tr.get("new_club")
        if playerid is None and not player_name:
            raise ValueError("Each transfer needs playerid or player name")
        if new_teamid is None and not new_club:
            raise ValueError("Each transfer needs new_teamid or new_club name")

        if playerid is not None:
            pid, pname = _resolve_player(sq, int(playerid))
        else:
            pid, pname = _resolve_player(sq, player_name)
        if pid is None:
            raise ValueError(f"Player not found: {player_name or playerid}")

        if new_teamid is not None:
            tid, tname = _resolve_team(sq, int(new_teamid))
        else:
            tid, tname = _resolve_team(sq, new_club)
        if tid is None:
            raise ValueError(f"Club not found: {new_club or new_teamid}")

        normalized.append({"playerid": pid, "player_name": pname, "new_teamid": tid, "new_club_name": tname,
                          "wage": tr.get("wage"), "months": tr.get("months")})
    return normalized


def _fc_wage(ov):
    """FC-style weekly wage by OVR (career currency). Matches the game's
    rating-based wage bands."""
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


def _lua_str(s):
    return json.dumps(str(s), ensure_ascii=False)  # valid Lua string literal


# Tables that, when edited raw, break the in-game career managers
# (wage/contract/squad-role/morale state lives in memory, not the DB).
# Writes to these MUST go through Live Editor native calls instead.
NO_RAW_WRITE_TABLES = frozenset({
    "teamplayerlinks",
    "career_playercontract",
    "career_presignedcontract",
    "career_playerloans",
    "playerloans",
    "career_players",
})


def handle_plan_transfers(args):
    sq = get_squad()
    transfers = _normalize_transfers(sq, args.get("transfers", []))
    return {"planned": transfers, "count": len(transfers)}


def handle_apply_transfers(args):
    """Generate a Live Editor Lua script that applies transfers with NATIVE
    calls (cTransferPlayer / cLoanPlayer), the only path that updates the
    game's in-memory career managers. Direct DB edits leave the managers
    stale (wage -1, contract -1, broken morale/sharpness) and can corrupt
    the save.

    Returns the Lua script path + instructions: run it in Live Editor
    -> Lua Engine, then save the career. Script is idempotent (skips
    players already at the target team), so a crashed run is safe to rerun.
    """
    sq = get_squad()
    transfers = _normalize_transfers(sq, args.get("transfers", []))

    # OVR -> wage per player
    players = sq.get_table("players")
    ovr = {p.get("playerid"): int(p.get("overallrating") or 60) for p in players}
    months_default = args.get("contract_months", 36)

    L = []
    A = L.append
    A('-- fc26_mcp apply_transfers.lua -- NATIVE transfers (cTransferPlayer/cLoanPlayer)')
    A('-- Generated by fc26-mcp. Run: Live Editor -> Lua Engine -> Run.')
    A('local LOG_PATH = "C:/fc26-mcp/mcp_transfer_log.txt"')
    A('local NL = string.char(10)')
    A('local function log(msg)')
    A('    local f = io.open(LOG_PATH, "a")')
    A('    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end')
    A('end')
    A('')
    A('local T = {')
    for tr in transfers:
        pid = tr["playerid"]
        tid = tr["new_teamid"]
        name = tr["player_name"]
        wage = tr.get("wage") or _fc_wage(ovr.get(pid, 60))
        months = tr.get("months") or months_default
        A("    { n = %s, pid = %d, tid = %d, wage = %d, months = %d }," %
          (_lua_str(name), pid, tid, int(wage), int(months)))
    A('}')
    A('')
    A('function main()')
    A('    log("== NATIVE TRANSFERS START (%d) ==")' % len(transfers))
    A('    for _, e in ipairs(T) do')
    A('        local pid, tid = e.pid, e.tid')
    A('        local ok0, cur = pcall(GetTeamIdFromPlayerId, pid)')
    A('        if ok0 and cur == tid then')
    A('            log(e.n .. " pid=" .. pid .. " already at " .. tid .. ", skip")')
    A('        else')
    A('            local okp, p2 = pcall(IsPlayerPresigned, pid)')
    A('            if okp and p2 then pcall(DeletePresignedContract, pid) end')
    A('            local okl, l2 = pcall(IsPlayerLoanedOut, pid)')
    A('            if okl and l2 then pcall(TerminateLoan, pid) end')
    A('            local from = (ok0 and cur and cur > 0) and cur or 0')
    A('            local ok = pcall(cTransferPlayer, pid, from, tid, 0, -1, e.wage, e.months)')
    A('            local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)')
    A('            local tn = ""')
    A('            if ok2 and cur2 and cur2 > 0 then local o3, n3 = pcall(GetTeamName, cur2) tn = tostring(n3 or "") end')
    A('            local res = (ok2 and cur2 == tid) and "OK" or "FAIL"')
    A('            log(e.n .. " pid=" .. pid .. " -> " .. tid .. " [" .. res .. "] after=" .. tostring(cur2) .. " " .. tn .. " pcall=" .. tostring(ok))')
    A('        end')
    A('    end')
    A('    log("== NATIVE TRANSFERS DONE ==")')
    A('end')
    A('')
    A('main()')

    script = "\n".join(L) + "\n"

    out = args.get("output_file")
    if not out:
        out = str(Path(__file__).resolve().parent.parent.parent / "apply_transfers_native.lua")
    Path(out).write_text(script, encoding="utf-8")

    return {
        "applied_plan": transfers,
        "lua_script": str(out),
        "count": len(transfers),
        "instruction": "Open the Lua script in Live Editor -> Lua Engine -> Run, then SAVE THE CAREER. "
                        "Native cTransferPlayer is the only path that updates contract/wage managers; "
                        "direct DB edits break the save. The script is idempotent (safe to rerun after a crash)."
    }


def handle_list_career_saves(args):
    directory = Path(args.get("directory") or SETTINGS_DIR)
    if not directory.exists():
        return {"saves": [], "message": f"Settings dir not found: {directory}"}
    files = []
    for p in sorted(find_career_files(directory), reverse=True):
        fp = Path(p)
        files.append({"path": str(fp), "name": fp.name, "size": fp.stat().st_size,
                      "kind": detect_save_type(fp)})
    return {"saves": files, "count": len(files)}


def handle_set_active_file(args):
    return set_file(args.get("path"))


def handle_list_db_tables(args):
    sq = get_squad()
    return {"tables": sorted(m["name"] for m in sq.tables_meta if m["name"]), "count": len(sq.tables_meta)}


def handle_get_table_data(args):
    sq = get_squad()
    table = args.get("table")
    if not table:
        raise ValueError("table required")
    records, fields = sq._parse_table(table)
    wanted = [f["name"] for f in fields]
    subset = args.get("fields")
    if subset:
        subset_set = {s.strip() for s in subset.split(",") if s.strip()}
        wanted = [f for f in wanted if f in subset_set]
    filt = (args.get("filter") or "").lower()
    limit = args.get("limit", 50)
    if not isinstance(limit, int) or limit <= 0:
        limit = 50
    limit = min(limit, 500)
    rows = []
    for rec in records:
        row = {f: rec.get(f) for f in wanted}
        if filt and not any(filt in str(v).lower() for v in row.values() if v is not None):
            continue
        rows.append(row)
        if len(rows) >= limit:
            break
    return {"table": table, "fields": wanted, "rows": rows, "count": len(records), "returned": len(rows)}


def handle_edit_table_field(args):
    sq = get_squad()
    table = args.get("table")
    row = args.get("row")
    field = args.get("field")
    value = args.get("value")
    if not table or row is None or not field or value is None:
        raise ValueError("table, row, field, value required")

    if table in NO_RAW_WRITE_TABLES:
        raise ValueError(
            f"Refusing raw edit of '{table}': the game reads contract/wage/squad state "
            "from in-memory managers, not the DB. Direct edits here corrupt the save "
            "(wage -1, contract -1, broken morale). Use plan_transfers/apply_transfers "
            "(native Lua) or LE native calls instead."
        )

    sq.update_field(table, int(row), field, int(value))
    save_path = args.get("save_path")
    if save_path:
        sq.save(save_path)
        return {"ok": True, "table": table, "row": int(row), "field": field, "value": int(value), "saved_to": save_path}
    return {"ok": True, "table": table, "row": int(row), "field": field, "value": int(value), "saved": False}


def handle_get_career_overview(args):
    return career_overview(get_squad())


def handle_call(id_, name, args):
    try:
        if name == "list_career_saves":
            return make_result(id_, handle_list_career_saves(args or {}))
        elif name == "set_active_file":
            return make_result(id_, handle_set_active_file(args or {}))
        elif name == "list_db_tables":
            return make_result(id_, handle_list_db_tables(args or {}))
        elif name == "get_table_data":
            return make_result(id_, handle_get_table_data(args or {}))
        elif name == "edit_table_field":
            return make_result(id_, handle_edit_table_field(args or {}))
        elif name == "get_career_overview":
            return make_result(id_, handle_get_career_overview(args or {}))
        elif name == "list_clubs":
            return make_result(id_, handle_list_clubs(args or {}))
        elif name == "search_players":
            return make_result(id_, handle_search_players(args or {}))
        elif name == "get_player_club":
            return make_result(id_, handle_get_player_club(args or {}))
        elif name == "plan_transfers":
            return make_result(id_, handle_plan_transfers(args or {}))
        elif name == "apply_transfers":
            return make_result(id_, handle_apply_transfers(args or {}))
        else:
            return make_error(id_, -32601, f"Unknown tool: {name}")
    except Exception as e:
        import traceback
        return make_error(id_, -32603, str(e), {"traceback": traceback.format_exc()})


def main():
    parser = argparse.ArgumentParser(description="FC 26 Squad File MCP Server")
    parser.add_argument("--squad-file", help="Path to the Squads file")
    parser.add_argument("--meta-file", help="Path to fifa_ng_db-meta XML (defaults to bundled FC26 metadata)")
    parser.add_argument("--settings-dir", help="Settings directory for career/squad discovery (defaults to LOCALAPPDATA\\EA SPORTS FC 26\\settings)")
    args = parser.parse_args()

    if args.squad_file:
        os.environ["FIFA_SQUAD_FILE"] = args.squad_file
    if args.meta_file:
        os.environ["FIFA_META_FILE"] = args.meta_file
    if args.settings_dir:
        global SETTINGS_DIR
        SETTINGS_DIR = Path(args.settings_dir)

    try:
        get_squad()
    except Exception as e:
        print(json.dumps({"jsonrpc": "2.0", "method": "$/log", "params": {"level": "error", "message": f"Failed to load squad: {e}"}}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            print(json.dumps(make_error(None, -32700, "Parse error", str(e))), flush=True)
            continue

        if not isinstance(msg, dict):
            print(json.dumps(make_error(None, -32600, "Invalid Request")), flush=True)
            continue

        id_ = msg.get("id")
        method = msg.get("method")
        params = msg.get("params", {})

        if method == "initialize":
            print(json.dumps(make_result(id_, {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fc26-squad-file-mcp", "version": "0.2.29"}
            })), flush=True)
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            print(json.dumps(make_result(id_, tool_list())), flush=True)
        elif method == "tools/call":
            name = params.get("name")
            args = params.get("arguments", {})
            call_result = handle_call(id_, name, args)
            if "error" in call_result:
                print(json.dumps(call_result), flush=True)
            else:
                mcp_result = {
                    "content": [{"type": "text", "text": json.dumps(call_result["result"])}],
                    "isError": False
                }
                print(json.dumps(make_result(id_, mcp_result)), flush=True)
        else:
            print(json.dumps(make_error(id_, -32601, f"Method not found: {method}")), flush=True)


if __name__ == "__main__":
    main()
