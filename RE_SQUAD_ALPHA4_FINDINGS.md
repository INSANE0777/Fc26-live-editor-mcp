# RE: `SquadsFIFER'sBeta4xRODE'sNewSeasonModAlpha4` (FC 26)

Reverse-engineering report for the FIFER "New Season" modded squad file found at
`%LOCALAPPDATA%\EA SPORTS FC 26\settings\SquadsFIFER'sBeta4xRODE'sNewSeasonModAlpha4`.

Artifacts: `squad_alpha4_beta4_summary.json` (table census), `squad_alpha4_beta4_teams.json`
(team id→name map, 855 entries). All figures below re-derived from the file itself via
`fifa_squad.py` (nothing assumed).

---

## 1. File facts

| Property | Value |
|---|---|
| Size | 10,178,639 bytes (10.2 MB) |
| Magic | `FBCHUNKS\x01\x00` (main-header size @14 = 10,177,513 = len−1126) |
| SaveType string @1126 | `SaveType_Squads` |
| DB section | offset 1,178, size 10,138,652 bytes |
| Save groups | squad format (49 savegroups schema); **not** career (33 tables) |
| Version row | schema hash `15eb55a5cc47f3e9732b6b58d81a5e9c6c91f332`, exportdate 162076, `isonline` 0 |

## 2. Structure (same FBCHUNKS/T3DB as career saves)

78 DB tables, parsed with the same meta schema
`fifa_ng_db-meta-fc26.xml` used by LE and RDBM26. Contiguous record array per table
(single-ptr offset pattern). All 78 tables parse cleanly (0 errors).

### Census highlights (full list in `squad_alpha4_beta4_summary.json`)

| Table | Rows | Notes |
|---|---|---|
| teamplayerlinks | 24,621 | club+NT+loan+parent rows (16 fields) |
| players | 22,445 | 145 fields (full player DB + mod additions) |
| dcplayernames | 5,990 | **edited/accented name strings** (nameid 44000–49989) |
| prevcompetitionstats | 4,450 | past-season stats rollover |
| default_mentalities | 4,292 | |
| teamkits | 4,195 | 72 fields |
| playerloans | 1,650 | loan window: playerid, teamidloanedfrom, loandateend, isloantobuy |
| competitionkits / rivalry / ucc / footwear / formations / teamsheets | 1.5k–855 | |
| teams | 855 | 110 fields — see §3 |
| leagues | 53 | leagueid + metadata (names live in game loc DB, not in file) |
| competition | 202 | competition ids only (names in loc DB) |
| fixtures | 19 | competition 39 = **MLS 2026 opening round** — see §4 |
| previousteam | 224 | player↔previous-club edges (transfer provenance) |
| cmplayers / smplayers | 219 / 478 | career/squads mode player snapshots |
| version | 1 | schema hash + export date |
| editedplayernames | **0** | empty in this mod (delta lives in dcplayernames instead) |
| cz_*, cp_*, createplayer, stories, teamformdiff, playerformdiff | 0 | career-only tables, empty (expected) |

## 3. Team set: 855 teams, 399 mod-added

- **Standard EA ids**: 1–~999 (Premier League etc.)
- **110000–119999: 340 teams** — FIFER's added clubs & NTs:
  - NTs: Haiti (112048), Curaçao (112054), Northern Ireland (110061)
  - Big adds: RB Leipzig (112172), Al Nassr (112139), Fiorentina (110374), Genoa (110556),
    Girona (110062), Real Sociedad B (110711), Viktoria Köln, Fortuna Düsseldorf, ...
  - South America: Independiente (110093), Lanús, Newell's, Banfield, Rosario Central,
    Bolívar, Colo-Colo, U. Católica, LDU Quito, Caracas...
  - China: Shanghai Shenhua (110955), Zhejiang (112163), plus Korea (Gangwon 112115,
    Gwangju 112258), Saudi (Al Nassr 112139, Al Ettifaq 112096)...
- **130000–139999: 59 teams** — women's + 2026-new clubs:
  - Women: Finland W, **NG - FA Women (131383)**, Rosengård, Glasgow City, Alhama, Badalona W...
  - 2026 clubs: **San Diego FC (131439)**, Bay FC, Utah Royals, Eyüpspor, Qingdao teams,
    Yunnan Yukun, Unirea Slobozia, AVS, KFUM-Kameratene, 1. FC Nürnberg (dupe), Milan FC / Lombardia FC...
  - Placeholders: 5v5 Team1/Team2, Free Agent Managers (131680), RC Deportivo
- **Beta3→Beta4: 0 teams added/removed/renamed** — the re-team roster is frozen between
  betas; changes are data-only (roster/kits/transfers).

## 4. Season state: "NewSeason" delta

- **Fixtures**: 19 rows, all `competitionid 39` = the 2026 MLS opening round:
  SJ vs Orlando, LA Galaxy vs LAFC, CFM vs Toronto, Seattle vs Portland, Philly vs NYRB,
  St. Louis vs KC, Nashville vs Atlanta, Miami vs Chicago, Charlotte vs Atlanta, Austin vs Seattle,
  Cincy vs Vancouver, Colorado vs San Diego FC (2026)...
- **playerloans (1650)**: summer loan to bentures; rows carry `loandateend` + `isloantobuy`
- **previousteam (224)**: player→previous-club edges (transfer-provenance data)
- **prevcompetitionstats (4450)**: last season's line (stats rollover for the new start)
- **version.exportdate = 162076** — synthetic day-counter (LE/CE epoch), not a calendar date.

## 5. Name handling: the mod's delta mechanism

- `editedplayernames` = **0 rows** (do not look there).
- The edited/accented name strings live in **`dcplayernames`** — 5,990 strings,
  nameid range 44000–49989, of which **1,005 non-ASCII** (accents/spellings):
  Hoeneß, Cesc Fàbregas Soler, Aitor Mañas, Ciubăncan, Ayindé, Pérez Morillo,
  Nicólas, Benaïssa-Yahia, W. Urbański, Rosalía Domínguez, Carlota Sánchez...
- Player name fields (`firstnameid`/`lastnameid`/`commonnameid` in `players`) index into
  this table; ids **outside** 44000–49989 have no string in the file — the full name set
  is resolved from the game DB / Live Editor at runtime (verified: RB Leipzig 112172's
  31 players resolve only the *edited* names — Suleman Sani (83137), Ayodele (83629),
  Kaltefleiter (82847) — the rest need the game DB).
- Implication for editing: to rename a player by hand, either patch an existing
  dcplayernames row to a new string **or** add a row in the 44000-49999 range and point
  the player's name ids at it.

## 6. Editing surface via fc26-mcp

All squad tools work unchanged on this file (it is a plain squads file):
- `set_active_file` / `get_table_data` / `edit_table_field` — any of the 78 tables
- `search_players`, `get_player`, `list_clubs` populated from `teams` + `players`
- transfers = `teamplayerlinks` rows (delete old, insert new teamid; loan flag parity)
- `playerloans` (loan moves), `previousteam` (provenance) stay consistent with it.

Byte-level checks: `save()` zeroes the CRC after `SaveType_Squads`; the DB size field and
main-header size @14 are updated on re-save (layout kept intact, round-trip tested).

---

## 7. Tooling used

```
fifa_squad.py        # SquadFile parser (DB/FBCHUNKS/T3DB, meta-driven)
squad_alpha4_beta4_summary.json   # 78-table census (machine-readable)
squad_alpha4_beta4_teams.json     # teamid → name (machine-readable)
```