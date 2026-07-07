#!/usr/bin/env python3
"""MCP bridge for FC 26 Live Editor."""

import argparse
import importlib.resources as pkg_resources
import json
import os
import shutil
import sys
import time
import uuid
from pathlib import Path

DEFAULT_BRIDGE_ROOT = r"C:\FC26LiveEditor\le_bridge"  # override with --bridge-root or FC26_BRIDGE_ROOT env var
POLL_INTERVAL = 0.2
MAX_WAIT = 120

_bridge_root = Path(DEFAULT_BRIDGE_ROOT)
_in_dir = _bridge_root / "in"
_out_dir = _bridge_root / "out"
_log_dir = _bridge_root / "logs"


def set_bridge_root(root):
    global _bridge_root, _in_dir, _out_dir, _log_dir
    _bridge_root = Path(root)
    _in_dir = _bridge_root / "in"
    _out_dir = _bridge_root / "out"
    _log_dir = _bridge_root / "logs"


def ensure_dirs():
    _bridge_root.mkdir(parents=True, exist_ok=True)
    _in_dir.mkdir(exist_ok=True)
    _out_dir.mkdir(exist_ok=True)
    _log_dir.mkdir(exist_ok=True)
    (_bridge_root / "cache").mkdir(exist_ok=True)


def log(msg):
    try:
        with open(_log_dir / "mcp_bridge.log", "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


def send_command(method, arguments):
    ensure_dirs()
    cmd_id = uuid.uuid4().hex
    payload = {"id": cmd_id, "method": method, "arguments": arguments or {}}
    in_path = _in_dir / f"{cmd_id}.json"
    out_path = _out_dir / f"{cmd_id}.json"

    with open(in_path, "w", encoding="utf-8") as f:
        json.dump(payload, f)

    # Append command id to the queue so Lua can discover it without running dir/popen
    queue_path = _in_dir / "_queue.txt"
    with open(queue_path, "a", encoding="utf-8") as f:
        f.write(cmd_id + "\n")

    waited = 0.0
    while waited < MAX_WAIT:
        if out_path.exists():
            try:
                with open(out_path, "r", encoding="utf-8") as f:
                    result = json.load(f)
                out_path.unlink(missing_ok=True)
                return result
            except Exception as e:
                return {"success": False, "error": f"Failed to read result: {e}"}
        time.sleep(POLL_INTERVAL)
        waited += POLL_INTERVAL

    in_path.unlink(missing_ok=True)
    return {"success": False, "error": f"Live Editor did not respond within {MAX_WAIT}s. Is the bridge Lua script running?"}


def make_error(id_, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": id_, "error": err}


def make_result(id_, result):
    return {"jsonrpc": "2.0", "id": id_, "result": result}


def _player_arg_schema():
    return {
        "playerid": {"type": "integer", "description": "Player ID."},
        "player": {"type": "string", "description": "Player name (if ID not provided)."}
    }


def _club_arg_schema():
    return {
        "new_teamid": {"type": "integer", "description": "Target team ID."},
        "new_club": {"type": "string", "description": "Target club name (if ID not provided)."}
    }


def tool_list():
    return {
        "tools": [
            {
                "name": "le_ping",
                "description": "Check if the Live Editor bridge is running.",
                "inputSchema": {"type": "object", "properties": {}}
            },
            {
                "name": "le_rebuild_caches",
                "description": "Rebuild player/team name caches. Use after editing players/teams.",
                "inputSchema": {"type": "object", "properties": {}}
            },
            {
                "name": "le_list_clubs",
                "description": "List clubs/teams from Live Editor.",
                "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer"}}}
            },
            {
                "name": "le_search_players",
                "description": "Search players by name.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                        "limit": {"type": "integer"}
                    },
                    "required": ["name"]
                }
            },
            {
                "name": "le_get_player_club",
                "description": "Get a player's current club.",
                "inputSchema": {"type": "object", "properties": _player_arg_schema()}
            },
            {
                "name": "le_list_team_players",
                "description": "List all players in a club/team.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "teamid": {"type": "integer", "description": "Team ID."},
                        "team": {"type": "string", "description": "Team name (if ID not provided)."}
                    }
                }
            },
            {
                "name": "le_transfer_player",
                "description": "Transfer a player to a club.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        **_player_arg_schema(),
                        **_club_arg_schema(),
                        "transfersum": {"type": "integer"},
                        "wage": {"type": "integer"},
                        "contract_length": {"type": "integer"},
                        "from_teamid": {"type": "integer"},
                        "release_clause": {"type": "integer"}
                    }
                }
            },
            {
                "name": "le_loan_player",
                "description": "Loan a player to a club.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        **_player_arg_schema(),
                        **_club_arg_schema(),
                        "length": {"type": "integer"},
                        "loantobuy": {"type": "integer"}
                    }
                }
            },
            {
                "name": "le_release_player",
                "description": "Release a player to free agents.",
                "inputSchema": {"type": "object", "properties": _player_arg_schema()}
            },
            {
                "name": "le_terminate_loan",
                "description": "Terminate a player's loan.",
                "inputSchema": {"type": "object", "properties": _player_arg_schema()}
            },
            {
                "name": "le_add_to_transfer_list",
                "description": "Add a player to the transfer list.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "teamid": {"type": "integer"}}}
            },
            {
                "name": "le_add_to_loan_list",
                "description": "Add a player to the loan list.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "teamid": {"type": "integer"}}}
            },
            {
                "name": "le_remove_from_lists",
                "description": "Remove a player from transfer and loan lists.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "teamid": {"type": "integer"}}}
            },
            {
                "name": "le_is_transfer_listed",
                "description": "Check if a player is on the transfer list.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "teamid": {"type": "integer"}}}
            },
            {
                "name": "le_is_loan_listed",
                "description": "Check if a player is on the loan list.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "teamid": {"type": "integer"}}}
            },
            {
                "name": "le_set_player_sharpness",
                "description": "Set player sharpness (0-100). Career Mode only.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "value": {"type": "integer"}}, "required": ["value"]}
            },
            {
                "name": "le_set_player_morale",
                "description": "Set player morale (0-100). Career Mode only.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "value": {"type": "integer"}}, "required": ["value"]}
            },
            {
                "name": "le_set_player_form",
                "description": "Set player form (0-100). Career Mode only.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "value": {"type": "integer"}}, "required": ["value"]}
            },
            {
      
          "name": "le_set_player_fitness",
                "description": "Set player fitness (5-95). Career Mode only.",
                "inputSchema": {"type": "object", "properties": {**_player_arg_schema(), "value": {"type": "integer"}}, "required": ["value"]}
            },
            {
                "name": "le_get_transfer_budget",
                "description": "Get transfer budget (Career Mode).",
                "inputSchema": {"type": "object", "properties": {}}
            },
            {
                "name": "le_set_transfer_budget",
                "description": "Set transfer budget (Career Mode).",
                "inputSchema": {"type": "object", "properties": {"value": {"type": "integer"}}, "required": ["value"]}
            },
            {
                "name": "le_get_db_tables",
                "description": "List database tables.",
                "inputSchema": {"type": "object", "properties": {}}
            },
            {
                "name": "le_get_db_fields",
                "description": "List fields of a database table.",
                "inputSchema": {"type": "object", "properties": {"table": {"type": "string"}}, "required": ["table"]}
            },
            {
                "name": "le_get_db_rows",
                "description": "Read rows from a database table (default 50).",
                "inputSchema": {"type": "object", "properties": {"table": {"type": "string"}, "limit": {"type": "integer"}}, "required": ["table"]}
            },
            {
                "name": "le_edit_db_field",
                "description": "Edit a database field.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "table": {"type": "string"},
                        "match_field": {"type": "string"},
                        "match_value": {},
                        "field": {"type": "string"},
                        "value": {}
                    },
                    "required": ["table", "match_field", "match_value", "field", "value"]
                }
            },
            {
                "name": "le_insert_db_row",
                "description": "Insert a database row.",
                "inputSchema": {"type": "object", "properties": {"table": {"type": "string"}, "row": {"type": "object"}}, "required": ["table", "row"]}
            },
            {
                "name": "le_delete_db_row",
                "description": "Delete a database row.",
                "inputSchema": {"type": "object", "properties": {"table": {"type": "string"}, "row": {"type": "object"}}, "required": ["table", "row"]}
            },
            {
                "name": "le_get_players_stats",
                "description": "Get all player stats (default 50).",
                "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer"}}}
            },
            {
                "name": "le_get_player_stats",
                "description": "Get stats for one player.",
                "inputSchema": {"type": "object", "properties": _player_arg_schema()}
            },
            {
                "name": "le_execute_lua",
                "description": "Run custom Lua (powerful, use carefully).",
                "inputSchema": {"type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"]}
            }
        ]
    }


def _dispatch(name, args):
    result = send_command(name.replace("le_", ""), args or {})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "Unknown error"))
    return result


def handle_call(id_, name, args):
    try:
        if name.startswith("le_") and name != "le_":
            return make_result(id_, _dispatch(name, args))
        else:
            return make_error(id_, -32601, f"Unknown tool: {name}")
    except Exception as e:
        import traceback
        return make_error(id_, -32603, str(e), {"traceback": traceback.format_exc()})


def install_lua(le_scripts_path):
    le_scripts_path = Path(le_scripts_path)
    le_scripts_path.mkdir(parents=True, exist_ok=True)
    src = pkg_resources.files("fc26_mcp") / "le_bridge.lua"
    dst = Path(le_scripts_path) / "le_bridge.lua"
    # Auto-detect bridge root from scripts path (LiveEditor/lua/scripts -> LiveEditor/le_bridge)
    le_root = dst.parent.parent.parent
    bridge_root = le_root / "le_bridge"
    lua_text = src.read_text(encoding="utf-8")
    lua_text = lua_text.replace(
        'local BRIDGE_ROOT = os.getenv("FC26_BRIDGE_ROOT") or "C:/FC26LiveEditor/le_bridge"',
        f'local BRIDGE_ROOT = os.getenv("FC26_BRIDGE_ROOT") or "{bridge_root.as_posix()}"'
    )
    dst.write_text(lua_text, encoding="utf-8")
    return str(dst)


def main():
    parser = argparse.ArgumentParser(description="FC 26 Live Editor MCP Bridge")
    parser.add_argument("--bridge-root", help="Path to the bridge folder (must match le_bridge.lua config)")
    parser.add_argument("--install-lua", metavar="LE_SCRIPTS_PATH", help="Copy le_bridge.lua to the given Live Editor lua/scripts folder")
    args = parser.parse_args()

    if args.install_lua:
        dst = install_lua(args.install_lua)
        print(f"Installed le_bridge.lua to: {dst}")
        return

    if args.bridge_root:
        set_bridge_root(args.bridge_root)
    elif os.environ.get("FC26_BRIDGE_ROOT"):
        set_bridge_root(os.environ["FC26_BRIDGE_ROOT"])

    ensure_dirs()
    log("MCP bridge server started")

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
                "serverInfo": {"name": "fc26-live-editor-mcp", "version": "0.2.27"}
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
