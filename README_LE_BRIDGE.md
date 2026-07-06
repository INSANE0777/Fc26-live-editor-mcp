# FC 26 Live Editor MCP Bridge

This MCP bridge lets an AI assistant control FC 26 **through Live Editor** while the game is running. It exposes most of the Live Editor Lua API as MCP tools.

## Paths

The bridge needs to know where your Live Editor folder is. Use `--install-lua` and `--bridge-root` with your actual path, or set the `FC26_BRIDGE_ROOT` environment variable.

## Install

```bash
pip install fc26-mcp
```

## Files

After installation:

- `fc26-mcp-live` — MCP server command
- `fc26_mcp/le_bridge.lua` — bundled Lua bridge script (installed with the package)

You must copy `le_bridge.lua` into your Live Editor scripts folder once:

```bash
fc26-mcp-live --install-lua "C:\Path\To\Your\FC 26 LE\lua\scripts"
```

## How it works

1. MCP server receives a tool call.
2. It writes a JSON command file to `le_bridge/in/{id}.json`.
3. The Lua script running in Live Editor picks up the command, executes it via Live Editor's API, and writes the result to `le_bridge/out/{id}.json`.
4. MCP server reads the result and returns it.

## Setup

1. Launch FC 26 and inject Live Editor.
2. Load Career Mode.
3. Open Live Editor → **Features → Lua Engine**.
4. Load and execute `lua/scripts/le_bridge.lua`.
   - You should see `[MCP Bridge] Full MCP bridge started` in the Live Editor log.
5. Start the MCP server:

```bash
fc26-mcp-live --bridge-root "C:\Path\To\Your\FC 26 LE\le_bridge"
```

## MCP client config

```json
{
  "mcpServers": {
    "fc26-live-editor": {
      "command": "fc26-mcp-live",
      "args": [
        "--bridge-root",
        "C:\Path\To\Your\FC 26 LE\le_bridge"
      ]
    }
  }
}
```

## MCP tools

### Core
- `le_ping` — check bridge connection
- `le_list_clubs` — list all teams
- `le_search_players` — search players by name
- `le_get_player_club` — show player's current club

### Transfers / contracts
- `le_transfer_player` — transfer to a club
- `le_loan_player` — loan to a club
- `le_release_player` — release to free agents
- `le_terminate_loan` — end a loan
- `le_add_to_transfer_list`
- `le_add_to_loan_list`
- `le_remove_from_lists`
- `le_is_transfer_listed`
- `le_is_loan_listed`

### Player state (Career Mode)
- `le_set_player_sharpness` (0-100)
- `le_set_player_morale` (0-100)
- `le_set_player_form` (0-100)
- `le_set_player_fitness` (5-95)

### Club budget
- `le_get_transfer_budget`
- `le_set_transfer_budget`

### Database editor
- `le_get_db_tables` — list accessible tables
- `le_get_db_fields` — list fields of a table
- `le_get_db_rows` — read rows from a table
- `le_edit_db_field` — edit a field in a row
- `le_insert_db_row` — insert a row
- `le_delete_db_row` — delete a row

### Stats
- `le_get_players_stats`
- `le_get_player_stats`

### Power user
- `le_execute_lua` — run arbitrary Lua code inside Live Editor (dangerous; use with care)

## Example transfer

```json
{
  "name": "le_transfer_player",
  "arguments": {
    "playerid": 220901,
    "new_teamid": 2,
    "transfersum": 0,
    "wage": 0,
    "contract_length": 60
  }
}
```

Or by name:

```json
{
  "name": "le_transfer_player",
  "arguments": {
    "player": "Raya Martín",
    "new_club": "Aston Villa"
  }
}
```

## Example database edit

```json
{
  "name": "le_edit_db_field",
  "arguments": {
    "table": "players",
    "match_field": "playerid",
    "match_value": 220901,
    "field": "overallrating",
    "value": 99
  }
}
```

## Important

- Career Mode tools only work inside **Career Mode**.
- Always back up your Career Mode save before running transfers or DB edits.
- The bridge times out after 30 seconds if the Lua script is not running.
