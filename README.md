# FC 26 MCP

[![Python 3.8+](https://img.shields.io/badge/python-3.8+-blue.svg)](https://www.python.org/downloads/)

MCP servers for EA SPORTS FC 26. Works with Claude, Codex, Pi, Cursor, Cline, Windsurf, and any other agent that supports the [Model Context Protocol](https://modelcontextprotocol.io/).

Two servers are included:

1. **`fc26-mcp-file`** — parses and edits raw `Squads*` files in FBCHUNKS/T3DB format.
2. **`fc26-mcp-live`** — controls FC 26 through [xAranaktu's Live Editor](https://www.patreon.com/collection/1744905) Lua API while the game runs.

---

## Install

From PyPI:

```bash
pip install fc26-mcp
```

From GitHub:

```bash
pip install git+https://github.com/INSANE0777/Fc26-live-editor-mcp.git
```

From source:

```bash
git clone https://github.com/INSANE0777/Fc26-live-editor-mcp.git
cd fc26-mcp
pip install -e .
```

---

## Quick start

### 1. Squad file MCP

```bash
fc26-mcp-file --squad-file "C:\Path\To\SquadsFile"
```

The bundled FC 26 metadata is used automatically. You can override it with `--meta-file`.

### 2. Live Editor MCP bridge

1. Launch FC 26 and inject Live Editor.
2. Load Career Mode.
3. Install the Lua bridge into Live Editor once:

```bash
fc26-mcp-live --install-lua "C:\Path\To\FC 26 LE v26.3.5\lua\scripts"
```

4. In Live Editor, go to **Features → Lua Engine** and run `le_bridge.lua`.
5. Start the MCP server:

```bash
fc26-mcp-live --bridge-root "C:\Path\To\FC 26 LE v26.3.5\le_bridge"
```

---

## Tools

### File parser
- `list_clubs`
- `search_players`
- `get_player_club`
- `plan_transfers`
- `apply_transfers`

### Live Editor bridge (28 tools)
- Core: `le_ping`, `le_list_clubs`, `le_search_players`, `le_get_player_club`
- Transfers/loans: `le_transfer_player`, `le_loan_player`, `le_release_player`, `le_terminate_loan`
- Lists: `le_add_to_transfer_list`, `le_add_to_loan_list`, `le_remove_from_lists`, `le_is_transfer_listed`, `le_is_loan_listed`
- Player state: `le_set_player_sharpness`, `le_set_player_morale`, `le_set_player_form`, `le_set_player_fitness`
- Budget: `le_get_transfer_budget`, `le_set_transfer_budget`
- Database editor: `le_get_db_tables`, `le_get_db_fields`, `le_get_db_rows`, `le_edit_db_field`, `le_insert_db_row`, `le_delete_db_row`
- Stats: `le_get_players_stats`, `le_get_player_stats`
- Power user: `le_execute_lua`

See [README_LE_BRIDGE.md](README_LE_BRIDGE.md) for detailed Live Editor docs.

---

## MCP client config

Use `mcp_config.json` as a template, or add these servers manually:

```json
{
  "mcpServers": {
    "fc26-file": {
      "command": "fc26-mcp-file",
      "args": [
        "--squad-file",
        "C:\Path\To\SquadsFile"
      ]
    },
    "fc26-live": {
      "command": "fc26-mcp-live",
      "args": [
        "--bridge-root",
        "C:\Path\To\FC 26 LE v26.3.5\le_bridge"
      ]
    }
  }
}
```

### Claude Desktop

Open `claude_desktop_config.json` and add the server blocks above.

### Cursor

Open **Cursor Settings → MCP → Add MCP Server**, paste the command and args.

### Cline / Roo Code

Add the JSON to your MCP settings file.

### Pi

Pi detects stdio MCP servers from `mcp_config.json` or your workspace settings.

---

## Environment variables

| Variable | Purpose |
|----------|---------|
| `FIFA_SQUAD_FILE` | Default squad file path for `fc26-mcp-file` |
| `FIFA_META_FILE` | Override bundled FC 26 metadata XML |
| `FC26_BRIDGE_ROOT` | Bridge folder for `fc26-mcp-live` |

---

## Safety

- Always back up your squad files and Career Mode saves before editing.
- Career Mode tools only work inside Career Mode.
- `le_execute_lua` can run arbitrary code — use it carefully.

---

## License

MIT
