# FC 26 Real Transfers & Squad Update Mod

## Description
This mod updates FC 26 Career Mode squads with the latest real-world transfers from the 2026 summer window. It uses a Live Editor bridge to apply confirmed moves directly to your active career save, keeping your database aligned with real-life signings, loans, and free-agent moves.

The project includes both a direct squad-file parser and a Live Editor MCP bridge, so you can edit squads offline or update a running career in real time.

## Installation Instructions

### Option A: Live Editor Bridge (recommended for Career Mode)
1. Install the Python package:
   ```bash
   pip install fc26-mcp
   ```
2. Install the Lua bridge into your Live Editor scripts folder:
   ```bash
   fc26-mcp-live --install-lua
   ```
3. Launch FC 26 and load your career save.
4. Open Live Editor → Lua Engine and run `le_bridge.lua`.
5. Use the MCP server or the provided helper scripts to search players and apply transfers.

### Option B: Direct Squad File Edit
1. Install the package:
   ```bash
   pip install fc26-mcp
   ```
2. Point the file MCP server at your squad file:
   ```bash
   fc26-mcp-file --squad "C:\Path\To\Your\SquadFile"
   ```
3. Edit the FBCHUNKS/T3DB squad file directly through MCP tools.

## Main Features
- **Real transfer database**: Automatically applies confirmed transfers from FotMob and major news outlets.
- **Live Editor bridge**: Edit players, clubs, contracts, and overall ratings while the game is running.
- **Batch transfer tools**: Apply multiple transfers at once or one-by-one through MCP.
- **Accent-insensitive player search**: Find players even with special characters in their names.
- **Persistent name cache**: Fast player/team lookups after the first run.
- **Two-MCP architecture**: Use the file parser for offline squad editing OR the Live Editor bridge for in-career changes.

## Requirements
- FC 26 (PC)
- FC 26 Live Editor v26.3.5 or compatible
- Python 3.11+
- `pip install fc26-mcp`
- Windows Python environment (the MCP executables must be available to your agent/launcher)

## Shout Outs
- EA SPORTS FC community and Live Editor developers for the tooling.
- FotMob for the open transfer data API.
- Fabrizio Romano and football journalists whose reports guide the updates.
- Everyone who tested the bridge and reported bugs.
