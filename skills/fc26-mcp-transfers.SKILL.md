---
name: "fc26-mcp-transfers"
description: "FC26 career transfers through fc26-mcp: native Lua only, verify every move, crash-safe batches"
version: 1
created: "2026-08-10"
updated: "2026-08-10"
---
## When to Use
Any FC 26 career-mode edit via fc26-mcp: transfers, loans, wages, contracts, squad roles, morale, sharpness, or budget changes. Use whenever someone asks to move players, fix broken transfer state, or apply a transfer window in career mode.

## Procedure
1. Identify the edit: permanent transfer (cTransferPlayer), loan (cLoanPlayer), release (ReleasePlayerFromTeam), loan termination (TerminateLoan), presign clear (DeletePresignedContract), or status (SetPlayerMorale/Sharpness/Fitness/Form).
2. ALWAYS use native Live Editor calls — never raw DB writes (teamplayerlinks update_field, career_playercontract, LE edit_db_field). The game UI reads in-memory career managers, not tables; raw edits corrupt saves (wage -1, contract -1, broken morale/sharpness).
3. Generate the Lua script via MCP apply_transfers (v0.4.0+: emits native Lua, idempotent verify-skip) or write one manually following the Diomande pattern: clear presign/loan -> cTransferPlayer(pid, from_tid, to_tid, 0, -1, wage, months) -> verify.
4. Wage by OVR band: 90->240k, 88->185k, 86->145k, 84->110k, 82->88k, 80->68k, 78->53k, 76->40k, 74->30k, 72->22k, 70->16k, 68->12k, 66->9k, 64->7k, 62->5.5k, 60->4.5k, else 3k. Contract months: (contractEndYear - 2026) * 12 for transfers.
5. VERIFY after every native call: pcall returns true even when natives fail (they log errors like 'TransferPlayer Failed Target Team Squad is Full' and return without throwing). Check GetTeamIdFromPlayerId(pid) == target_tid for transfers, IsPlayerLoanedOut for loans, == 111592 (Free Agents) for releases.
6. Respect the crash budget: ~206 live-DB mutations per game process session. Batch transfers ≤170 (use 68-per-part native_transfers_partN.lua); restart the game between parts. Idempotent scripts (verify-skip) make crashed runs safe to rerun.
7. Squad-full guard counts PlayerStatusManager vector slots (52 cap) INCLUDING pid=-1 sentinel holes — releasing players leaves holes that never free a slot; only the game's own squad management (sim days, in-game squad-screen moves) frees slots.
8. Handle script generation safely: Lua strings need \n escapes written as real backslash-n bytes (use string.char(10) variables to be safe); verify generated Lua with luaparser ast.parse before handing over; check UTF-8 names survive (Valentin Barco = \xc3\xadn).
9. User runs the script in Live Editor Lua Engine, then SAVES THE CAREER. Logs go to C:/fc26-mcp/*_log.txt — check actual results (RESULT: SUCCESS at X), not pcall values.

## Pitfalls
- NEVER raw-edit teamplayerlinks / career_playercontract / career_presignedcontract / playerloans / career_players — v0.4.0 MCP and bridge refuse these; bypassing the guard corrupts the save.
- pcall does NOT detect native failures — always verify with GetTeamIdFromPlayerId after transfers. A 'true' pcall with player still at old team = silent native fail.
- Game crashes (exit 255) after ~206 live-DB mutations per session — split into parts and restart the game between sessions. Two independent runs crashed at exactly entry 206->207.
- Python heredoc generators collapse \n escapes into literal newlines inside Lua strings ('unfinished string near '') — always ast.parse the generated file and byte-check the escape (92,110 = backslash+n).
- Free-Agents team id is 111592; team aliases: Inter='Lombardia FC' 131682, Milan='Milano FC' 131681, Atalanta='Bergamo Calcio' 115845; Real Madrid=243, Chelsea=5.
- LE caches scripts in memory — after editing a script, stop+re-execute Features->Lua Engine, plain reload has no effect.
- Loaned players have 2 teamplayerlinks rows — TerminateLoan first before transfer, or the move silently fails.
- The active file for MCP tools is set at server start — restart Pi/MCP after editing ~/.pi/agent/mcp.json or changing squad file.

## Verification
1. Generated Lua passes luaparser ast.parse with no syntax errors.
2. Log shows 'RESULT: SUCCESS at <team>' / verified_teamid == target tid for every transfer.
3. In-game player screen shows real Wage, Contract Length, Squad Role, Morale after save+reload (not -1 values).
4. career_playercontract table gains rows for transferred players (proves managers updated).
5. No 'TransferPlayer Failed' errors in the LE console for the moved players.