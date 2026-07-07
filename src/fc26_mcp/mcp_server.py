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

from fc26_mcp.fifa_squad import SquadFile

DEFAULT_SQUAD = "SquadsFIFER'sBeta1xRODE'sNewSeasonModAlpha3"
DEFAULT_META = str(pkg_resources.files("fc26_mcp.data") / "fifa_ng_db-meta-fc26.xml")

_squad = None
_squad_error = None


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
                "description": "Apply transfers to the squad file and save it.",
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
                            }
                        },
                        "output_file": {"type": "string", "description": "Optional output file path. Defaults to original file with .new suffix."}
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
    club_ids = {l["teamid"] for l in sq.get_table("leagueteamlinks")}

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
    club_ids = {l["teamid"] for l in sq.get_table("leagueteamlinks")}

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

        normalized.append({"playerid": pid, "player_name": pname, "new_teamid": tid, "new_club_name": tname})
    return normalized


def handle_plan_transfers(args):
    sq = get_squad()
    transfers = _normalize_transfers(sq, args.get("transfers", []))
    return {"planned": transfers, "count": len(transfers)}


def handle_apply_transfers(args):
    sq = get_squad()
    transfers = _normalize_transfers(sq, args.get("transfers", []))

    leagueteamlinks = sq.get_table("leagueteamlinks")
    club_team_ids = {l["teamid"] for l in leagueteamlinks}

    records, _ = sq._parse_table("teamplayerlinks")
    applied = []
    for tr in transfers:
        pid = tr["playerid"]
        tid = tr["new_teamid"]
        target_is_club = tid in club_team_ids

        matching = [
            (i, r) for i, r in enumerate(records)
            if r["playerid"] == pid and (r["teamid"] in club_team_ids) == target_is_club
        ]
        if not matching:
            raise ValueError(f"Player {tr['player_name']} has no {'club' if target_is_club else 'national team'} link")

        rec_idx, rec = matching[0]
        sq.update_field("teamplayerlinks", rec_idx, "teamid", tid)
        applied.append(tr)

    output = args.get("output_file")
    if output:
        sq.save(output)
        saved_path = output
    else:
        original = Path(sq.path)
        saved_path = original.with_suffix(original.suffix + ".new")
        sq.save(str(saved_path))
    return {"applied": applied, "saved_to": str(saved_path), "count": len(applied)}


def handle_call(id_, name, args):
    try:
        if name == "list_clubs":
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
    args = parser.parse_args()

    if args.squad_file:
        os.environ["FIFA_SQUAD_FILE"] = args.squad_file
    if args.meta_file:
        os.environ["FIFA_META_FILE"] = args.meta_file

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
                "serverInfo": {"name": "fc26-squad-file-mcp", "version": "0.2.28"}
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
