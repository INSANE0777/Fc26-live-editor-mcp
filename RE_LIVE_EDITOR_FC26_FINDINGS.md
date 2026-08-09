# FC 26 Live Editor — Deep Reverse-Engineering Findings

**Scope:** xAranaktu "FC 26 Live Editor" v26.3.5 (silver tier, game v1.0.139.20381 = FC26 v1.6.6)
**Sources:** shipped DLL/binary inspection, shipped Lua v1+v2 API source (`lua/libs/`), `lua/DOC.MD`, `le_config.json`, `le_offsets.json`, `version_info.json`, Live Editor runtime logs, xAranaktu GitHub repo + wiki, career save files parsed on-disk, cooperative tools (FIFA Editor Tool suites, A DB Master/RDBM26).
**Date:** 2026-08-09

---

## 1. Executive summary — what Live Editor actually is

Live Editor is **not a save-file editor**. It is a **C++ DLL (`FCLiveEditor.DLL`) that gets injected into the running `FC26.exe` process and edits the game's live memory in real time**. It works exclusively *inside* the game (and only while the game runs), and its data changes become permanent **only when the game itself saves** its database to the career/squad file on disk. That single fact explains everything else.

Data flow:

```
Launcher.exe ──► spawns FC26.exe (anti-cheat disabled)
        └── injects FCLiveEditor.dll (100 ms later, per config)
                  │
                  ├── PolyHook/Detours hooks:
                  │     • Direct3D12 Present          → overlay UI (Dear ImGui)
                  │     • Legacy file loader (TryFindFile) → Live-Editor mods path
                  │     • Embedded Lua 5.4.6 engine    → user scripts
                  │     • FCEI (career mode) interface & event mailbox
                  │     • TextBed / save IO tracking
                  │
                  ├── Plugin service discovery via djb2 strings-of-class hashes (GetPlugin)
                  │     • Database service  → **live T3DB database in game memory**
                  │     • FeFceGMCommService → CareerMode manager objects (153 managers)
                  │
                  └── Lua API v1 (legacy globals) + v2 (OOP: LE, LE.db, MEMORY, LOGGER, managers)
```

Every edit the user makes in the Player/Team/Manager/Database editors is a direct memory write into the game's T3DB `players`, `teams`, `teamplayerlinks`, `career_users`, … tables (plus a few non-DB structs like the FCE managers). When the user saves the career (or the squad file), the game serializes that memory DB into the `FBCHUNKS`-wrapped `.db` file on disk — so the edits persist.

---

## 2. Package anatomy (`FC 26 LE v26.3.5`)

| Component | What it is |
|---|---|
| `Launcher.exe` | GUI launcher: validates Patreon key, updates, then launches the game + injects DLL |
| `FCLiveEditor.dll` | The tool. ~8 MB C++ DLL (module base `0x7FF94A0B0000`–`0x7FF94A8D5000` per logs). Exported table empty; implements everything via hooks |
| `FakeEAACLauncher\EAAntiCheat.GameServiceLauncher.exe` | EAC bypass: string in binary: `"[+] Fake EA Anticheat Launcher is running the game without the EA Anticheat"`. Starts `EAAntiCheat.GameService` stub so the game believes anti-cheat is running |
| `AuthServer\auth_server.exe` | Local HTTP server (cpp-httplib) that answers the game's auth handshake offline (strings: HTTP/1.1, www-authenticate, Unauthorized…) |
| `lua/` | Script engine payload: `v1` legacy API, `v2` OOP API (full source shipped!), 100+ example scripts |
| `le_offsets.json` | AOB/offset table (`GAME_VER: 1.0.139.20381`, ~85 `[fileOffset, rva]`-ish pairs) |
| `legacy_filename_hash_list.csv` | Hash list used by the "legacy file" system to recognize game files by hashed names |
| `loc/eng_us/localize.json` | Localisation table (kicker) baked into the DLL |
| `filters/players/*.json` | Prebuilt player quick filters (Free Agents, Generated, Retiring) |
| `player_presets/` | FUT-style card presets + base players CSV |
| `mods/` | Live-Editor mods root (only `legacy/` overlays + `locale.ini`) |

The `C:\FC 26 Live Editor\` profile dir contains `le_config.json`, `version_info.json`, `extensions/careers/<SaveUID>/` (per-career JSON sidecars such as `players_development.json`, `selection_bias.json`, `transfer_bans.json`, `match_fixing.json`, `unsackable_managers.json`, …) and `extensions/global/`.

---

## 3. Injection & anti-cheat bypass (evidence)

`le_config.json`:
```json
"launcher": {
    "auto_inject": true, "close_after_injection": true,
    "dlls": ["FCLiveEditor.DLL"],
    "game_proc_name": "FC26.exe",
    "injection_delay": 100, "no_mods": false
}
```
So: Launcher spawns `FC26.exe` (through the EAC-bypass path), waits 100 ms, injects the DLL. Runtime log confirms:
```
Module <FCLiveEditor.DLL> 0x7FF94A0B0000-0x7FF94A8D5000
Game Version:            1.0.139.20381
Init LUA Scripts Manager
[LUA API] Init LIVE EDITOR LUA API V1
[LUA API] Init LIVE EDITOR LUA API V2
Game Init - Stage 1/2/3 ... [DetoursManager::InstallDX12Hooks] Start ... Setup DirectX12 Hooks
```

The DLL imports: `D3DCOMPILER_47.dll` (shaders for overlay), `dxgi.dll` (Present hook), `WS2_32.dll` (network/auth), `bcrypt.dll`, `CRYPT32.dll` (Patreon OAuth signing), `ADVAPI32`. Strings confirm **PolyHook (`x64Detour@PLH` + `asmjit`) and an internal `DetoursManager`**. "AOB not found {}" — it also uses AOB scans to locate game functions across updates (`le_offsets.json` stores per-version addresses).

---

## 4. How it finds the database — the plugin system

Frostbite (the EA engine) exposes services through a **string-hashed (djb2) class registry** — `GetPlugin("classhash")` returns the shared service instance. Live Editor ships the ENTIRE hash table in `lua/libs/v2/imports/services/enums.lua` (617 entries) — the reverse-engineered index of djb2 hashes for every game service. Key ones:

```
ENUM_djb2Database_CLSS          = 0x0AE932D0   ← the database service
ENUM_djb2FeFceGMCommServiceInterface_CLSS = 0x1297F047   ← career-mode managers
ENUM_djb2FifaDBService_CLSS     = 0x76339D17
ENUM_djb2FIFADBHelperService_CLSS = 0x13E1ABA1
ENUM_djb2TournamentEngineService_CLSS = 0x0B83553E
ENUM_djb2SimEngineService_CLSS   = 0x0DFC00AF
ENUM_djb2FootballCompService_CLSS = 0x7E95A4BC
```

### The live T3DB walk (from `imports/t3db/db.lua`, `table.lua`, `field.lua`)

```
GetPlugin(ENUM_djb2Database_CLSS) − 8          → DBServices weakptr...
MEMORY.ReadMultilevelPointer(..., {0x20, 0x08, 0x10}) → DB*  (first DB)
DB + 0x10 → first table*; table + 0x08 → next table; DB + 0x18 → next DB
```

Per T3DB table:
| Offset | Size | Meaning |
|---|---|---|
| +0x10 | — | table list start |
| +0x08 (table) | ptr | next table |
| +0x40 (table) | 4B | ASCII shortname (e.g. `CZUM` = players) |
| +0x30 (table) | qword | `first_record` address (base of record array) |
| +0x44 (table) | int | `record_size` (bytes per record) |
| +0x7C (table) | short | `written_records` count |
| +0x82 (table) | byte | column (field) count |
| +0x84 (table) | arr | field descriptors, **0x10 bytes each** |

Field descriptor (`field.lua`):
| offset | meaning |
|---|---|
| +0x00 | type (int): 0 = ASCII string, 3 = int, 4 = float |
| +0x04 | `bit_offset` (int); byte offset = bit_offset >> 3, start bit = bit_offset & 7 |
| +0x08 | 4-char shortname |
| +0x0C | size |

Reading values:
- **Int** — the field occupies `depth` bits *inside a 64-bit word*: `(uqword >> startbit) & ((1<<depth)−1) + min` (offset+min scaling from the meta XML).
- **Float** — same bit extraction, then re-interpret the 32-bit int as IEEE float.
- **String** — in-line buffer (depth/8 bytes) read as null-terminated string, 0-padded on write.
- Record validity bit: last byte of record (`record+record_size−1`) & 0x80 == 0 (deleted/moved records flip it).

The **names** (`players` → `CZUM` etc.), the field **min**/**depth** values, and *which tables belong to squads vs career* come from the game's own schema file parsed at runtime:
```
[strings] Parse data/db/fifa_ng_db-meta.xml (N bytes)
```
That is `fifa_ng_db-meta.xml` (11,614 lines, 279 tables, 2,140 named fields) — fully available offline. Live Editor's `GetDBMeta()` returns the parsed `{shortname→name, field_desc_map}` structures. This is the **same schema our `fc26-mcp` parses** (`fifa_ng_db-meta-fc26.xml`) — one meta, two consumers (memory + disk).

---

## 5. Career-mode connection (FCE)

`GetManagerObjByTypeId(type_id)` (`career_mode/helpers.lua`):

```
GetPlugin(ENUM_djb2FeFceGMCommServiceInterface_CLSS)  +0x20 → +0x10 → managers array
mode_manager = base + 0x20 * type_id
  sanity: *(mode_manager+0x10) == 1 (instance exists)
         *(mode_manager+0x8 → type) +0x10 == 1
instance = ReadMultilevelPointer(mode_manager, {0x18, 0x0})
```

`career_mode/enums.lua` enumerates **153 CareerMode management objects** (FCECareerModeAchievementManager=19 … FCECareerModeAwardUtil=153). Notable:

| type_id | manager |
|---|---|
| 25 | FCECareerModeBudgetManager (transfer budget) |
| 47 | FCECareerModeFitnessManager |
| 59 | FCECareerModeLoansManager |
| 79 | FCECareerModePlayerContractManager |
| 83 | FCECareerModePlayerGrowthManager |
| 85 | FCECareerModePlayerMoraleManager |
| 89 | FCECareerModePlayerStatusManager (squad roles; vector of {mPlayerID@0x0, mRole@0x4, mSize@0x8}, ≤55 entries) |
| 129 | FCECareerModeTransferManager |
| 131 | FCECareerModeUserManager (the player/manager) |

`FCECareerModeUserManager` (`imports/career_mode/FCECareerModeUserManager.lua`):
```
mUserType @0x37: 0 = Manager career, 1 = Player career
mPlayerId @0x3C: 30999  == V-PRO (virtual pro)
```

**Who is "you"?** The `career_users` table (single record → meta `savegroups="careermode"`):
- `usertype` 0 = manager career (1 = player), `clubteamid`, `nationalteamid`, `leagueid`, `primarycompobjid`, `wage`, `sponsorid`… (verified on the user's own save: `Xabier … Alonso` at Chelsea `clubteamid=5`, league `13`, wage `71000`, `usertype=0`.)

Career manager structs are also reachable for **non-DB** features: squad role (`SetSquadRole` writes to PlayerStatusManager vector), budget, form/morale/fitness go through LE's C++ career helpers which call into the FCE managers.

Career events — LE can subscribe to the career mode event mailbox; `imports/career_mode/enums.lua` defines the full CM event message enum 0..119+ (…`PREPARE_FOR_SAVE`=28, `POST_LOAD_PREPARE`=29, `PLAYER_GROWTH`=53, `TRANSFER_MOVE_*`, `LOAN_*`, `USER_TEAM_PLAYER_FORM_CHANGE`=69…) and `consts.lua` maps harder event ids to names (107=LIVE_TABLE_FIRST_UPDATE …). Used by `track_cm_events.lua` and by Live Editor's "Transfer History", "-Retirement" tracking etc.

---

## 6. The Lua API (v1 & v2) — the automation surface

- **Legacy v1** (fully documented in `lua/DOC.MD`): still the fastest for many things: `IsInCM()`, `GetSaveUID()`, `GetCurrentDate()`, `GetUserTeamID()`, `GetTeamIdFromPlayerId()`, `GetTeamName()/GetPlayerName()`, `SetPlayerSharpness/Morale/Form/Fitness`, development plan helpers, `CreatePlayer/DeletePlayer/PlayerExists`, `TransferPlayer/LoanPlayer/ReleaseFromTeam/TerminateLoan`, transfer-loan list add/remove, `GetPlayersStats/GetPlayerStats`, `GetTransferBudget/SetTransferBudget`, `GetDBTablesNames/GetDBTableFields/GetDBTableRows`, `InsertDBTableRow/DeleteDBTableRow/EditDBTableField`, PlayerCapture* (miniface generation)…
- **v2** (OOP, ships as source in `lua/libs/v2/`): `LE.version/data/game_base/game_size`, `LE.db` (T3DB wrapper), `LE.players_manager`, `LE.gameplay_attribulator_manager`, `LE.player_development_manager`, `LE.aardvark_manager`, `LE.game_localization_manager`, plus globals `MEMORY` (raw Read*/Write*/AOBScan/AllocateMemory/…) and `LOGGER`. v2 improvements: events, HTTP requests (`http.lua`), faster DB ops.

The raw memory API (`imports/core/memory.lua`) wraps the native functions injected by the DLL — the full cheat-engine-style capability set: Read/Write Bytes/Short/Int/Float/Qword/String, `AOBScan(moduleBase, moduleSize, pattern)`, `AllocateMemory`, `DeallocateMemory`, `WriteJMP`, multi-level pointer resolver. **Everything a memory-hacking tool needs.**

---

## 7. The career database — on disk (FBCHUNKS/T3DB)

- Squad files (initial squads) and career saves use the **same container**: `FBCHUNKS` magic → version `0x01` → u32 "size" → 8-byte name → 102-byte header → T2DB tables.
- Career saves live at `%LOCALAPPDATA%\EA SPORTS FC 26\settings\GoMgrC<timestamp>` (e.g. `CmMgrC20260829105056967`, ~15 MB).
- Squad file `SquadsFIFER...Alpha4` embeds its mod name: `FIFER's Beta 4 x RODE's 26/27 A4`.

Live Editor has nothing to do with writing that disk file directly: it writes the in-memory DB and the game persists on "save career" (verified conceptually in `ENUM_CM_EVENT_MSG_PREPARE_FOR_SAVE`).

### Career tables (from `fifa_ng_db-meta.xml` savegroups)
| savegroup | count | meaning |
|---|---|---|
| `careermode` | 33 | **career-only** tables (written into `CmMgrC*`) |
| `squads` | 49 | squad-file tables |
| `cmsquads,squads` | 29 | in both |
| `cmsquads,squads,onlsquads` | 3 | + online squads |
| `cmsquads,squads,players` | 1 | players |
| customformations / customteamstyle / settings / teamsheets / tempsquads / worktour / assets | … | other containers |

Career-only (33): `career_managerinfo career_playasplayer career_playerlastgrowth career_playasplayerhistory clubcoefficients clubcoefficients… career_playercontract… career_presignedcontract career_users…`

**Validated on-device:** our `fc26-mcp` FBChunkCks/T2DB parser reads a real `CmMgrC20260908105056967` and returns exactly **33 tables** — including `career_users` (1 row, 19 fields) with `firstname=“Xabier”, commonname=“Xabi Alonso”, clubteamid=5 (Chelsea), leagueid=13 (Premier League), wage=71000, usertype=0, seasoncount=1` (matching the meta `savegroups=careermode` count). So **the same offline parser we built handles career saves too.**

---

## 8. Persistence & what "plays with the career DB" really means

Wiki: *"The Live Editor allows to edit the game database stored in game memory. All changes are temporary unless the table is part of squadfile or career file, if yes then edited data can be saved permanently when you save the career/squad file."* → For career, tables with `savegroups = careermode | cmsquads,squads` are the persistent set; all other tables (279 − these) reset next session.

LE state sidecars keyed by **SaveUID**: `GetSaveUID()` returns-a 31-char id stored in `sponsors` table where `adsponserid == 8181`; the game (and LE) use it to namespace `extensions/careers/<SaveUID>/…json` (player-growth XP, selection-bias, transfer bans, match-fixing state, unsackable managers…).

**"Unsupported Career Teams"**: FC26 v1.4.2 added `DeleteUnsupportedCMLeagues/DeleteUnsupportedCMTeams` (hardcoded allowlist) that runs on new career start — no DB edit can fix it; LE patches the game code (WriteJMP) so the whitelist is bypassed (templates/LE_CM_SUPPORTED_LEAGUES_AND_TEAMS.csv).

**Compdata limits**: `templates/LIVE_EDITOR_LIMITS.json` edits hardcoded exe limits (MAX_FCEDATA_ACTIVTEAMS=64, COMPOBJECTS=2500, STANDINGS=6000, OBJECTIVES=670…) via runtime patches (`log: "Set New Compdata Max Items for STANDINGS: 6000 → 6500"`).

---

## 9. The "FIFA Editor Tool" family (clarify which is which)

1. **FIFA Editing Toolsuite** (fifaedditortool.com) — the "FIFA Editor Tool" most people mean: a **mod-packaging** tool (Editor + Mod Manager; Frosty-descendant) for FIFA/FC 21–26…, imports/exports meshes, textures, audio; manages mod load order. **Not a career-DB editor.**
2. **Revolution DB Master 26 (RDBM26)** (Fidel-adjacent lineage of Rinaldo's RDBM) + **Ultimate EA DB Master** — the actual **career/squad/tournament .db editors** (edit tables inside FBChunk/T2D files offline, incl. language DBs, miniface swap, clone players, youth ID conversion). This is the reference for correlation with LE.
3. **Live Editor** — the in-memory, in-game editor (this report); xAranaktu's Patreon tool. It can also load/import `player_presets` and miniface.

So the ecosystem splits on **offline-file editors (RDBM26 / FIFA Editor Tool) vs in-game live editors (Live Editor)**. Same DB format, different point of attack.

---

## 10. Practical notes for the `fc26-mcp` integration (from bridge usage on this machine)

- Prefer v2 `LE.db:GetTable()` + `GetRecordFieldValue/SetRecordFieldValue` over deprecated v1 `EditDBTableField`/`TransferPlayer` (the latter mis-write / didn't persist in earlier version tests).
- `teamplayerlinks` rows: a player (club+national, loan+parent) can have **multiple rows**; target the right row (shift-first pattern). On-wax contract players have extra rows (`teamidloanedfrom`, `loandateend`), terminate loan first.
- Teams use canonical IDs (Chelsea=5) not the 116xxx modded duplicates; extract per-file IDs.
- T3DB tables are contiguous — deleting a row requires reindexing later table offsets (broke `players` parse once).
- Modded FIFER squad files store only delta names in `editedplayernames`; the full name set comes from game DB/Live Editor — apply transfers by **playerid**.
- `career_users` is a *single-row* table = the active human career; read it to detect manager vs player career anywhere (GUI, or bridge).
- Career saves ARE parseable with `fifa_squad.py` — 33 tables. The GUI/MCP `list_clubs`/`search_player` stats flow works on `CmMgr*` too (tested).

---

## 11. Evidence trail (artifacts used)

- LE install: `…\FC 26 LE v26.3.5\` (DLL, launcher kit, fake EAC launcher, auth server, logs, lua libs, le_offsets, changelog, config)
- `C:\FC 26 Live Editor\` (working profile: le_config, version map, extensions/careers JSON sidecars, mods/legacy)
- Game profile: `%LOCALAPPDATA%\EA SPORTS FC 26\settings` (squad + `CmMgrC*` career saves)
- Schema: `fifa_ng_db-meta-fc26.xml` in this project — the same file LE parses at runtime
- Web: xArankeu/FC-26-Live-Editor (repo+wikl: Editing DB, Compdata Limits, CM Unsupported, Lua API v2), sammygriffs/fifa-career-save-parser, fifa-t3db (npm), fifaeditortool.com, RDBM 26 (FIFA Infinity), soccergaming threads.
---


---

## 12. DLL-level findings: InstallDX12Hooks & the CareerModeManager vtable (task c)

Analysis of `FCLiveEditor.DLL` (8,462,336 bytes, PE32+, image base `0x180000000`, 7 sections;
`.text` 6.47 MB / `.rdata` 1.75 MB). Tooling: `re_le.py` (stdlib PE parse + capstone).
Runtime module base `0x7FF94A0B0000` (per `Logs/live_editor_09-08-2026.log`) — runtime = base + RVA.

### 12.1 InstallDX12Hooks — located and traced

Entry: **RVA `0x34D2C0`** (runtime `0x7FF94A3FD2C0`). Disassembly reproduces the exact log flow:

```
0x18034D2C0  lea rcx,[rip+tag]; call logger          ; "[LE::DetoursManager::InstallDX12Hooks] Start"
0x18034D2F5  SSO-build "Setup DirectX12 Hooks" (len 0x15); movups+movsd copy of the literal, then log
0x18034D371  call 0x18033E8C0                        ; DX12 resolver: logs "DirectX12 - Get Offsets";
                                                     ; loads d3d12.dll / dxgi.dll, GetProcAddress("D3D12CreateDevice"),
                                                     ; "No dxgi.dll" error path, "pSwapChain->ID3D12Device"
0x18034D378  mov cl,1; call 0x1803445D0              ; hook installer #1 (swapchain/vtable hook family)
0x18034D37F  mov cl,1; call 0x180341FE0              ; hook installer #2 — AOB hook
0x18034D386  mov cl,1; call 0x180345380              ; hook installer #3 — AOB hook
0x18034D38D  mov cl,1; call 0x1803451F0              ; hook installer #4
0x18034D3BF  SSO "DirectX12 - waiting for initialization"; then runtime "Initialize attempt: N" loop
```

- All 4 installers share the PLH detour error path: `"Install hook failed at 0x{:08X}"`.
  RTTI shows `x64Detour@PLH` / `Detour@PLH` classes → **PolyHook-style x64 detours (PLH) + asmjit**.
- Installer #2 AOB signature: `8B C3 99 41 F7 FF 48 8D 15 ?? ?? ?? ?? 8B D8 89 44 24 20 E8`
- Installer #3 AOB signature: `48 83 EC 28 48 8B 49 08 E8 ?? ?? ?? ?? 83 B8 0C 03 00 00 0F 0F 94 C0 48 83 C4 28 C3`
- `0x1801E9980` = the LE logger (timestamp `%02d:%02d:%09.6f`, matches log format).
- Runtime log confirms the end of the chain: "DirectX12 - Present initialized".

**Gotcha**: the literals are referenced by SSE loads — `movups/movsd xmm, [rip+…]`
(std::string SSO copies) — **not** `lea`. A lea-only xref scan finds zero hits.
Also capstone stops at the first invalid byte in a raw `.text` sweep — iterate with a
skip-on-error loop (`off += ins.size`, else `off += 1`) or the scan silently truncates.

### 12.2 CareerModeManager — vtable: NOT RTTI-exposed

- **No RTTI**: `.?AVCareerModeManager@LE@@` has **zero** occurrences in `.rdata`
  (no TypeDescriptor ⇒ no COL ⇒ no derivable vtable). Same for `DetoursManager@LE` and
  `TransferManager@LE`. RTTI *is* present for `x64Detour@PLH`, `Detour@PLH`,
  `AdvancedFilter@LE`, and the UI class `CareerModeFeatures@UIMiscFeatures@UIWindows`.
- The class exists: mangled member names in `.data` at RVA `0x9D80`/`0xE227`
  (`CareerModeManager@LE@@EAAXXZPEAV34@@std@@` — method with args), and the
  Lua-visible method names are `.rdata` strings with **no pointer/instruction references**:
  `CareerModeManager::PAPSetTargetTeam`, `::GetCurrentDate`, `::GetSeasonEndDate`,
  `::GetUserTeamID`, `::GetManagerWage`, `::GetPAPID`, plus `CareerModeEvent`.
- Conclusion: LE talks to career mode through the **hash-based FCEI interface**
  (`FeFceGMComm` hash `0x97F047`, `Database` hash `0x0AE932D0` — §4), not a public vtable.
  `CareerModeManager` is an opaque wrapper; the method names above are its Lua-facing
  surface. Any private vtable is only observable under a live debugger with career mode loaded.

### 12.3 Reusable tooling

`re_le.py` (repo root) = PE section parser + RTTI TypeDescriptor/COL/vtable resolver +
generic rip-relative string-xref sweeper (lea + SSE loads, skip-on-error). Usage:
`python re_le.py <path-to-FCLiveEditor.DLL>`. Reusable for any future FC/LE DLL work.
