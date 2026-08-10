--[[
    apply_transfers.lua — Apply the 48 FotMob transfers to the loaded squads
    via Live Editor (FC 26 LE v26.3.5).

    HOW TO RUN:
      1. In game, open Live Editor -> Features -> Lua Engine
      2. Load this script (or use File -> Open / paste the path)
      3. Press Run / Execute
      4. Progress + results are written to: C:/fc26-mcp/apply_transfers_log.txt

    Notes:
      - Resolves player/team IDs by name at runtime (exact -> substring -> ratio).
      - Transfers use the proven method: direct teamplayerlinks edits
        (native TransferPlayer does not persist reliably).
      - Terminates any active loan first, deletes pre-signed contracts.
      - National-team links are preserved (only club links are rewritten).
]]--

local LOG_PATH = "C:/fc26-mcp/apply_transfers_log.txt"
local FREE_AGENT_TEAMID = 111592 -- NG - FA

local logf
local function write_log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
    if Log then Log("[Transfers] " .. tostring(msg)) end
end

-- ---------------------------------------------------------------------------
-- Accent stripping (same map as the MCP bridge)
-- ---------------------------------------------------------------------------
local function strip_accents(str)
    if str == nil then return "" end
    local map = {
        ["á"]="a", ["à"]="a", ["â"]="a", ["ä"]="a", ["ã"]="a", ["å"]="a", ["æ"]="ae",
        ["é"]="e", ["è"]="e", ["ê"]="e", ["ë"]="e",
        ["í"]="i", ["ì"]="i", ["î"]="i", ["ï"]="i",
        ["ó"]="o", ["ò"]="o", ["ô"]="o", ["ö"]="o", ["õ"]="o", ["ø"]="o",
        ["ú"]="u", ["ù"]="u", ["û"]="u", ["ü"]="u",
        ["ç"]="c", ["ñ"]="n", ["š"]="s", ["ć"]="c", ["č"]="c",
        ["đ"]="d", ["ž"]="z", ["ř"]="r", ["ł"]="l", ["ß"]="ss",
        ["Á"]="A", ["À"]="A", ["Â"]="A", ["Ä"]="A", ["Ã"]="A",
        ["É"]="E", ["È"]="E", ["Ê"]="E", ["Ë"]="E",
        ["Í"]="I", ["Ì"]="I", ["Î"]="I", ["Ï"]="I",
        ["Ó"]="O", ["Ò"]="O", ["Ô"]="O", ["Ö"]="O", ["Õ"]="O",
        ["Ú"]="U", ["Ù"]="U", ["Û"]="U", ["Ü"]="U",
        ["Ç"]="C", ["Ñ"]="N", ["Š"]="S", ["Ć"]="C", ["Č"]="C",
        ["Đ"]="D", ["Ž"]="Z", ["Ř"]="R", ["Ł"]="L"
    }
    local out = {}
    local i = 1
    while i <= #str do
        local byte = str:byte(i)
        local len = 1
        if byte >= 240 then len = 4
        elseif byte >= 224 then len = 3
        elseif byte >= 192 then len = 2
        end
        local char = str:sub(i, i + len - 1)
        table.insert(out, map[char] or char)
        i = i + len
    end
    return table.concat(out)
end

local function norm(s)
    return strip_accents(string.lower(s or ""))
end

-- ---------------------------------------------------------------------------
-- Indexes built from the live DB
-- ---------------------------------------------------------------------------
local PLAYER_INDEX = {}   -- norm(name) -> pid
local TEAM_INDEX = {}     -- norm(name) -> teamid
local CLUB_IDS = {}       -- set of club teamids (clubworth != 0 or FA)

local function build_indexes()
    -- Players
    local ok, rows = pcall(GetDBTableRows, "players")
    if ok and rows then
        for _, row in ipairs(rows) do
            local pid = tonumber(row.playerid.value)
            local pname = GetPlayerName(pid)
            if pid and pname and pname ~= "" then
                PLAYER_INDEX[norm(pname)] = pid
            end
        end
    end
    -- Teams + club detection
    local ok2, trows = pcall(GetDBTableRows, "teams")
    if ok2 and trows then
        for _, row in ipairs(trows) do
            local tid = tonumber(row.teamid.value)
            local tname = row.teamname and row.teamname.value
            local abbr = row.teamabbreviation and row.teamabbreviation.value
            if tid and tname then
                TEAM_INDEX[norm(tname)] = tid
                if abbr and abbr ~= "" then
                    TEAM_INDEX[norm(abbr)] = tid
                end
                local worth = row.clubworth and row.clubworth.value
                if worth and tonumber(worth) ~= 0 then
                    CLUB_IDS[tid] = true
                end
            end
        end
    end
    CLUB_IDS[FREE_AGENT_TEAMID] = true
    return next(PLAYER_INDEX) ~= nil and next(TEAM_INDEX) ~= nil
end

local function resolve_player(name, known_id)
    if known_id then return known_id end
    local key = norm(name)
    if PLAYER_INDEX[key] then return PLAYER_INDEX[key] end
    -- substring fallback
    for pkey, pid in pairs(PLAYER_INDEX) do
        if string.find(pkey, key, 1, true) then
            return pid
        end
    end
    return nil
end

local function resolve_team(name, known_id)
    if known_id then return known_id end
    if norm(name) == "free agent" then return FREE_AGENT_TEAMID end
    local key = norm(name)
    if TEAM_INDEX[key] then return TEAM_INDEX[key] end
    for tkey, tid in pairs(TEAM_INDEX) do
        if string.find(tkey, key, 1, true) then
            return tid
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Transfer application (direct teamplayerlinks edits)
-- ---------------------------------------------------------------------------
local function apply_transfer(ent)
    local pid, tid = ent.pid, ent.tid
    local name, team = ent.name, ent.to
    local ok, tbl = pcall(function() return LE.db:GetTable("teamplayerlinks") end)
    if not ok or not tbl then
        return "FAIL: teamplayerlinks table unavailable: " .. tostring(tbl)
    end

    -- Clean up loan / pre-signed state first
    local okp, presigned = pcall(IsPlayerPresigned, pid)
    if okp and presigned then pcall(DeletePresignedContract, pid) end
    if ent.kind == "perm" then
        local okc, contract = pcall(GetPlayerContract, pid)
        if okc and contract then pcall(DeleteContract, pid) end
    end
    local okl, loaned = pcall(IsPlayerLoanedOut, pid)
    if okl and loaned then pcall(TerminateLoan, pid) end

    -- Rewrite every CLUB link of this player to the target team
    local edited, rows_seen = 0, 0
    local record = tbl:GetFirstRecord()
    while record > 0 do
        local row_pid = tonumber(tbl:GetRecordFieldValue(record, "playerid"))
        if row_pid == pid then
            rows_seen = rows_seen + 1
            local row_tid = tonumber(tbl:GetRecordFieldValue(record, "teamid"))
            if CLUB_IDS[row_tid] then
                tbl:SetRecordFieldValue(record, "teamid", tostring(tid))
                edited = edited + 1
            end
        end
        record = tbl:GetNextValidRecord()
    end

    if edited == 0 then
        return "WARN: no club link found for " .. name .. " (rows seen: " .. rows_seen .. ")"
    end

    -- Contract handling
    if ent.kind == "perm" then
        -- players row: contract end + join date
        local okp2, c = pcall(function() return LE.db:GetTable("players") end)
        if okp2 and c then
            local rec = c:GetFirstRecord()
            while rec > 0 do
                if tonumber(c:GetRecordFieldValue(rec, "playerid")) == pid then
                    c:SetRecordFieldValue(rec, "contractvaliduntil", tostring(ent.contractEndYear or 2030))
                    if ent.joinSerial then
                        c:SetRecordFieldValue(rec, "playerjointeamdate", tostring(ent.joinSerial))
                    end
                    break
                end
                rec = c:GetNextValidRecord()
            end
        end

        -- career contract row: wage / role (3=Rotation) / bonus (0=NONE)
        local okc2, cc = pcall(function() return LE.db:GetTable("career_playercontract") end)
        if okc2 and cc then
            local wage = tonumber(ent.wage) or 0
            local role = tonumber(ent.role) or 3
            local bonus = tonumber(ent.bonusType) or 0
            if wage > 0 or role ~= 3 or bonus ~= 0 then
                local rec = cc:GetFirstRecord()
                while rec > 0 do
                    if tonumber(cc:GetRecordFieldValue(rec, "playerid")) == pid then
                        if wage > 0 then cc:SetRecordFieldValue(rec, "wage", tostring(wage)) end
                        cc:SetRecordFieldValue(rec, "playerrole", tostring(role))
                        cc:SetRecordFieldValue(rec, "performancebonustype", tostring(bonus))
                        if ent.joinSerial then
                            cc:SetRecordFieldValue(rec, "contract_date", tostring(ent.joinSerial))
                        end
                        break
                    end
                    rec = cc:GetNextValidRecord()
                end
            end
        end

        -- presigned contract: release clause / squad role
        local okp3, pc = pcall(function() return LE.db:GetTable("career_presignedcontract") end)
        if okp3 and pc then
            local rel = tonumber(ent.releaseClause) or 0
            if rel > 0 then
                local rec = pc:GetFirstRecord()
                while rec > 0 do
                    if tonumber(pc:GetRecordFieldValue(rec, "playerid")) == pid then
                        pc:SetRecordFieldValue(rec, "releaseclause", tostring(rel))
                        pc:SetRecordFieldValue(rec, "squadrole", tostring(tonumber(ent.role) or 3))
                        break
                    end
                    rec = pc:GetNextValidRecord()
                end
            end
        end
        return "OK (" .. edited .. " link(s) updated, contract until " .. (ent.contractEndYear or 2030) .. ")"
    else
        -- Loan: use the game native (creates the playerloans row properly)
        -- cLoanPlayer(playerid, from_teamid, to_teamid, loan_length_months, loantobuy)
        if type(cLoanPlayer) ~= "function" then
            return "WARN: cLoanPlayer native unavailable, loan skipped"
        end
        local end_serial = ent.loanEndSerial or 162426
        local months = math.max(1, math.floor((end_serial - 162093) / 30)) -- Aug 9 2026 -> end serial
        local buy = 0
        if ent.loanBuy then buy = 1 end
        local okl2, res = pcall(cLoanPlayer, pid, ent.loanParent or 0, tid, months, buy)
        if not okl2 then
            return "WARN: cLoanPlayer failed: " .. tostring(res)
        end
        return "OK (" .. edited .. " link(s) updated, loan " .. months .. "mo/buy=" .. buy .. ")"
    end
end

-- ---------------------------------------------------------------------------
-- Transfer list: { name, team, pid=known id (optional), tid=known id (optional) }
-- ---------------------------------------------------------------------------
-- Auto-generated from transfers_to_apply.json (build_transfers_to_apply.py)
local TRANSFERS = {
    { name = 'Cardoso Varela', to = 'FC Porto', pid = 80384, tid = 236, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 12000, releaseClause = -1 },
    { name = 'Joris van Overeem', to = 'FC Utrecht', pid = 210010, tid = 1903, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 16000, releaseClause = -1 },
    { name = 'Emre Mor', to = 'NEC Nijmegen', pid = 231240, tid = 1910, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 22000, releaseClause = -1 },
    { name = 'Diego Conde', to = 'Real Betis', pid = 258534, tid = 449, kind = 'loan', loanParent = 483, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Jhomier Guerrero', to = 'Millonarios', pid = 84319, tid = 101105, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 12000, releaseClause = -1 },
    { name = 'Kevin Cataño', to = 'Internacional de Bogota', pid = 83086, tid = 111325, kind = 'loan', loanParent = 101100, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Carlo Sickinger', to = 'Darmstadt', pid = 242525, tid = 110502, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 9000, releaseClause = -1 },
    { name = 'Rahim Alhassane', to = 'Bologna', pid = 73502, tid = 189, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 16000, releaseClause = -1 },
    { name = 'Kasper Junker', to = 'Randers FC', pid = 213871, tid = 1786, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 22000, releaseClause = -1 },
    { name = 'Gabriel Batista', to = 'Botafogo RJ', pid = 271571, tid = 517, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 22000, releaseClause = -1 },
    { name = 'André Gomes', to = 'Casa Pia AC', pid = 211575, tid = 114510, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 30000, releaseClause = -1 },
    { name = 'Lucas Monzón', to = 'Botafogo RJ', pid = 79424, tid = 517, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 9000, releaseClause = -1 },
    { name = 'Warleson', to = 'Botafogo RJ', pid = 255754, tid = 517, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 16000, releaseClause = -1 },
    { name = 'Lorent Tolaj', to = 'Bristol City', pid = 266886, tid = 1919, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 9000, releaseClause = -1 },
    { name = 'Darío Benavides', to = 'Dinamo Bucuresti', pid = 279506, tid = 100757, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 7000, releaseClause = -1 },
    { name = 'Dylan Williams', to = 'Motherwell', pid = 264115, tid = 83, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 5500, releaseClause = -1 },
    { name = 'Jhon Córdoba', to = 'Instituto', pid = 210287, tid = 110953, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 53000, releaseClause = -1 },
    { name = 'Markus Gustav Jensen', to = 'Nacional', pid = 277635, tid = 111325, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 5500, releaseClause = -1 },
    { name = 'Luca Sirch', to = 'Elversberg', pid = 73135, tid = 580, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 22000, releaseClause = -1 },
    { name = 'Diego González', to = 'Real Zaragoza', pid = 76415, tid = 244, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 3000, releaseClause = -1 },
    { name = 'Eddie Beach', to = 'Shelbourne', pid = 277904, tid = 834, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 4500, releaseClause = -1 },
    { name = 'Théo De Percin', to = 'SC Bastia', pid = 263402, tid = 58, kind = 'loan', loanParent = 57, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Lassine Sinayoko', to = 'Paris FC', pid = 251170, tid = 111817, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 30000, releaseClause = -1 },
    { name = 'Derensili Sanches Fernandes', to = 'Huddersfield', pid = 271511, tid = 1939, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 9000, releaseClause = -1 },
    { name = 'Emirhan Demircan', to = 'Telstar', pid = 79113, tid = 100638, kind = 'loan', loanParent = 1903, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Diego Gómez', to = 'SD Huesca', pid = 269278, tid = 110839, kind = 'loan', loanParent = 1375, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Yaya Bojang', to = 'Alverca', pid = 70125, tid = 717, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 5500, releaseClause = -1 },
    { name = 'Jeremy Agbonifo', to = 'Jagiellonia Białystok', pid = 71343, tid = 110745, kind = 'loan', loanParent = 64, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Kayne van Oevelen', to = 'Ipswich', pid = 271150, tid = 94, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 12000, releaseClause = -1 },
    { name = 'Hugo Sotelo', to = 'Levante', pid = 264095, tid = 1853, kind = 'loan', loanParent = 450, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mame Alassane Niang', to = 'FC Porto B', pid = 85108, tid = 236, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 3000, releaseClause = -1 },
    { name = 'Angelo Gattermayer', to = 'Hartberg', pid = 264867, tid = 2017, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 7000, releaseClause = -1 },
    { name = 'Danilo Al Saed', to = 'HamKam', pid = 272967, tid = 1756, kind = 'loan', loanParent = 711, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Gustavo Silva', to = 'Mirassol', pid = 74649, tid = 111975, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 16000, releaseClause = -1 },
    { name = 'Alessandro Bianco', to = 'Modena', pid = 271477, tid = 1744, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 16000, releaseClause = -1 },
    { name = 'Filippo Distefano', to = 'Empoli', pid = 277599, tid = 1746, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 7000, releaseClause = -1 },
    { name = 'Simon Simoni', to = 'Luzern', pid = 272787, tid = 897, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 7000, releaseClause = -1 },
    { name = 'Daniel Fila', to = 'Avellino', pid = 267593, tid = 2038, kind = 'loan', loanParent = 205, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Guillermo Maripán', to = 'Internacional', pid = 219145, tid = 111325, kind = 'perm', contractEndYear = 2029, joinSerial = 162082, wage = 40000, releaseClause = -1 },
    { name = 'Gustavo Charrupí', to = 'Everton CD', pid = 82500, tid = 7, kind = 'loan', loanParent = 112992, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Leonardo Sequeira', to = 'Central Cordoba de Santiago', pid = 240743, tid = 112965, kind = 'loan', loanParent = 111711, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Alan Soñora', to = "Newell's Old Boys", pid = 252240, tid = 110396, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 9000, releaseClause = -1 },
    { name = 'Ahmad Faqa', to = 'Degerfors', pid = 268345, tid = 113892, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 3000, releaseClause = -1 },
    { name = 'Per Kristian Bråtveit', to = 'FK Haugesund', pid = 211021, tid = 1463, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 12000, releaseClause = -1 },
    { name = 'Malang Sarr', to = 'Neom SC', pid = 235454, tid = 131798, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 53000, releaseClause = -1 },
    { name = 'Patson Daka', to = 'Hamburger SV', pid = 241202, tid = 28, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 12000, releaseClause = -1 },
    { name = 'Álex Sala', to = 'Mallorca', pid = 265732, tid = 453, kind = 'loan', loanParent = 347, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Fabio Ferraro', to = 'Westerlo', pid = 264711, tid = 681, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 12000, releaseClause = -1 },
    { name = 'Darwin Machís', to = 'Carabobo FC', pid = 210463, tid = 110991, kind = 'loan', loanParent = 101099, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Will Lankshear', to = 'Middlesbrough', pid = 75272, tid = 12, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 9000, releaseClause = -1 },
    { name = 'Antonín Barák', to = 'APOEL Nicosia', pid = 236791, tid = 100135, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 22000, releaseClause = -1 },
    { name = 'Santeri Väänänen', to = 'Karlsruher SC', pid = 246757, tid = 1832, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 7000, releaseClause = -1 },
    { name = 'Filip Bilbija', to = 'Derby', pid = 252073, tid = 91, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 16000, releaseClause = -1 },
    { name = 'Issa Diop', to = 'Ipswich', pid = 231633, tid = 94, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 40000, releaseClause = -1 },
    { name = 'Samuel Beltrán', to = 'Luqueno', pid = 74838, tid = 111006, kind = 'loan', loanParent = 110580, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Tomás Escalante', to = 'Plaza Colonia', pid = 255386, tid = 1906, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 7000, releaseClause = -1 },
    { name = 'Maximilian Wöber', to = 'Schalke 04', pid = 231838, tid = 34, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 30000, releaseClause = -1 },
    { name = 'Casemiro', to = 'Inter Miami CF', pid = 200145, tid = 112893, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 88000, releaseClause = -1 },
    { name = 'Paul Nardi', to = 'Auxerre', pid = 206218, tid = 57, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 16000, releaseClause = -1 },
    { name = 'Elijah Just', to = 'Swansea', pid = 254136, tid = 1960, kind = 'perm', contractEndYear = 2029, joinSerial = 162083, wage = 12000, releaseClause = -1 },
    { name = 'Matteo Cocchi', to = 'Padova', pid = 77615, tid = 110912, kind = 'loan', loanParent = 131682, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Edson Tortolero', to = 'America de Cali', pid = 253579, tid = 101099, kind = 'loan', loanParent = 110991, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Matías Borgogno', to = 'Defensa y Justicia', pid = 243476, tid = 111710, kind = 'loan', loanParent = 112689, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mats Seiler', to = 'Thun', pid = 70279, tid = 1715, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 3000, releaseClause = -1 },
    { name = 'Norman Bassette', to = 'Westerlo', pid = 264621, tid = 681, kind = 'loan', loanParent = 1800, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Kevin Spadanuda', to = 'FC Zürich', pid = 269947, tid = 894, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 9000, releaseClause = -1 },
    { name = 'Lucas França', to = 'Santa Clara', pid = 235574, tid = 1438, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 22000, releaseClause = -1 },
    { name = 'Loic Lüthi', to = 'Luzern', pid = 276172, tid = 897, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 7000, releaseClause = -1 },
    { name = 'Ibrahim Cissoko', to = 'PEC Zwolle', pid = 268927, tid = 1914, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 12000, releaseClause = -1 },
    { name = 'Elmin Rastoder', to = 'Panathinaikos', pid = 276645, tid = 1884, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 5500, releaseClause = -1 },
    { name = 'Clement Bischoff', to = 'NEC Nijmegen', pid = 278359, tid = 1910, kind = 'loan', loanParent = 191, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Wesley', to = 'Nacional', pid = 74913, tid = 111325, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 12000, releaseClause = -1 },
    { name = 'Ibrahim Fofana', to = 'Westerlo', pid = 274440, tid = 681, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 5500, releaseClause = -1 },
    { name = 'Matteo Lovato', to = 'Padova', pid = 258946, tid = 110912, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 12000, releaseClause = -1 },
    { name = 'Mikayil Faye', to = '1. FC Nürnberg', pid = 277118, tid = 171, kind = 'loan', loanParent = 111434, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Amin Boudri', to = 'Hammarby', pid = 70331, tid = 708, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 16000, releaseClause = -1 },
    { name = 'Matt Targett', to = 'Hull', pid = 218659, tid = 1952, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 22000, releaseClause = -1 },
    { name = 'Rafiu Durosinmi', to = 'Genk', pid = 273128, tid = 673, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 30000, releaseClause = -1 },
    { name = 'Ismaël Gharbi', to = 'Leganes', pid = 263194, tid = 100888, kind = 'loan', loanParent = 1391, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Abdoul Kader Bamba', to = 'Granada', pid = 246790, tid = 110832, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 12000, releaseClause = -1 },
    { name = 'Jovane Cabral', to = 'Gremio', pid = 244193, tid = 1629, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 16000, releaseClause = -1 },
    { name = 'Joseph Opoku', to = 'Swansea', pid = 78426, tid = 1960, kind = 'perm', contractEndYear = 2029, joinSerial = 162084, wage = 16000, releaseClause = -1 },
    { name = 'Awad Al Nashri', to = 'Al Shabab', pid = 259358, tid = 111674, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 3000, releaseClause = -1 },
    { name = 'Valentín Fascendini', to = 'Talleres', pid = 279845, tid = 112670, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 9000, releaseClause = -1 },
    { name = 'Aleksandr Guboglo', to = 'Reims', pid = 77609, tid = 379, kind = 'loan', loanParent = 111139, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Ármin Pécsi', to = 'Hartberg', pid = 79922, tid = 2017, kind = 'loan', loanParent = 9, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Lukas Grgic', to = 'Bari', pid = 239091, tid = 1848, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 9000, releaseClause = -1 },
    { name = 'Andrea Bozzolan', to = 'Palermo', pid = 80172, tid = 1843, kind = 'loan', loanParent = 110740, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Bilal Nadir', to = 'Hamburger SV', pid = 263602, tid = 28, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 22000, releaseClause = -1 },
    { name = 'Juan Cruz', to = 'Real Oviedo', pid = 206219, tid = 110827, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 22000, releaseClause = -1 },
    { name = 'Ricardo Mangas', to = 'Monza', pid = 240020, tid = 111811, kind = 'loan', loanParent = 237, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Emre Tezgel', to = 'Wycombe', pid = 271626, tid = 1933, kind = 'loan', loanParent = 1806, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Daniel Bielica', to = 'Portsmouth', pid = 244256, tid = 1790, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 12000, releaseClause = -1 },
    { name = 'Nicolas Milanovic', to = 'Western Sydney', pid = 257326, tid = 112427, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 12000, releaseClause = -1 },
    { name = 'Tin Plavotic', to = 'Motor Lublin', pid = 237570, tid = 111097, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 9000, releaseClause = -1 },
    { name = 'Sergio López', to = 'Granada', pid = 245287, tid = 110832, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 12000, releaseClause = -1 },
    { name = 'Antoniu Roca', to = 'Mallorca', pid = 263133, tid = 453, kind = 'loan', loanParent = 452, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Alessandro Milani', to = 'Inter', pid = 76178, tid = 131682, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 5500, releaseClause = -1 },
    { name = 'Iker Bravo', to = 'Watford', pid = 265194, tid = 1795, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 9000, releaseClause = -1 },
    { name = 'Oluwaseun Adewumi', to = 'Hertha BSC', pid = 74864, tid = 166, kind = 'loan', loanParent = 1796, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Marcelo Pérez', to = 'Luqueno', pid = 259514, tid = 111006, kind = 'loan', loanParent = 111711, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Hidemasa Morita', to = 'Hull', pid = 242087, tid = 1952, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 53000, releaseClause = -1 },
    { name = 'Mika Wallentowitz', to = 'Greuther Fürth', pid = 81991, tid = 165, kind = 'loan', loanParent = 34, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Alessio Zerbin', to = 'Frosinone', pid = 237669, tid = 111657, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 22000, releaseClause = -1 },
    { name = 'Luis Hasa', to = 'Frosinone', pid = 70163, tid = 111657, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 12000, releaseClause = -1 },
    { name = 'Alejandro Marqués', to = 'Granada', pid = 243047, tid = 110832, kind = 'perm', contractEndYear = 2029, joinSerial = 162085, wage = 22000, releaseClause = -1 },
    { name = 'Naif Masoud', to = 'Al Ahli', pid = 70584, tid = 112387, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 4500, releaseClause = -1 },
    { name = 'Stefan Schimmer', to = 'Buriram United', pid = 239078, tid = 112638, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 12000, releaseClause = -1 },
    { name = 'Nawaf Al Habashi', to = 'Al Hilal', pid = 246381, tid = 605, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 4500, releaseClause = -1 },
    { name = 'Dominik Javorcek', to = 'Bohemians 1905', pid = 74877, tid = 305, kind = 'loan', loanParent = 266, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Elias Achouri', to = 'San Diego FC', pid = 263672, tid = 131439, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 16000, releaseClause = -1 },
    { name = 'Conor Townsend', to = 'West Brom', pid = 203751, tid = 109, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 12000, releaseClause = -1 },
    { name = 'Kaheim Dixon', to = 'Novi Pazar', pid = 74922, tid = 1906, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 3000, releaseClause = -1 },
    { name = 'Ryan Strain', to = 'Falkirk', pid = 241244, tid = 79, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 9000, releaseClause = -1 },
    { name = 'Carlos Fernández', to = 'Real Oviedo', pid = 221014, tid = 110827, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 16000, releaseClause = -1 },
    { name = 'Isaiah Ahmed', to = 'Telstar', pid = 74337, tid = 100638, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 3000, releaseClause = -1 },
    { name = 'Anthony Descotte', to = 'Fortuna Sittard', pid = 254503, tid = 634, kind = 'loan', loanParent = 670, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Blerton Isufi', to = 'HamKam', pid = 80263, tid = 1756, kind = 'loan', loanParent = 417, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Luca Erlein', to = 'Leverkusen', pid = 76923, tid = 32, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 7000, releaseClause = -1 },
    { name = 'Alex Lowry', to = 'Motherwell', pid = 266756, tid = 83, kind = 'loan', loanParent = 1933, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Daizen Maeda', to = 'Ipswich', pid = 246321, tid = 94, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 53000, releaseClause = -1 },
    { name = 'Andrei Coubis', to = 'Lincoln', pid = 81262, tid = 149, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 9000, releaseClause = -1 },
    { name = 'Oliver Lukic', to = 'Hartberg', pid = 82763, tid = 2017, kind = 'loan', loanParent = 191, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Lasse Flø', to = 'Westerlo', pid = 278362, tid = 681, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 7000, releaseClause = -1 },
    { name = 'Shamal George', to = 'Bromley', pid = 240346, tid = 112764, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 5500, releaseClause = -1 },
    { name = 'Maxence Prévot', to = 'Dunkerque', pid = 231841, tid = 111276, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 9000, releaseClause = -1 },
    { name = 'Jamie Lawrence', to = 'OH Leuven', pid = 259082, tid = 100087, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 16000, releaseClause = -1 },
    { name = 'Arnau Tenas', to = 'Mallorca', pid = 259065, tid = 453, kind = 'loan', loanParent = 483, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Owen Goodman', to = 'Dundee FC', pid = 276806, tid = 180, kind = 'loan', loanParent = 1799, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Matthew Cox', to = 'Barnet', pid = 256488, tid = 135, kind = 'loan', loanParent = 1925, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Diego Pampín', to = 'Granada', pid = 241055, tid = 110832, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 12000, releaseClause = -1 },
    { name = 'Daniel Villahermosa', to = 'Real Oviedo', pid = 266100, tid = 110827, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 9000, releaseClause = -1 },
    { name = 'José Gragera', to = 'Burgos CF', pid = 250997, tid = 10846, kind = 'loan', loanParent = 452, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Richard Taylor', to = 'Bromley', pid = 252878, tid = 112764, kind = 'loan', loanParent = 4, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Calebe', to = 'Internacional', pid = 264842, tid = 111325, kind = 'loan', loanParent = 463, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Danilo', to = 'Botafogo RJ', pid = 199304, tid = 517, kind = 'loan', loanParent = 86, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Wílder Viera', to = 'Instituto', pid = 260135, tid = 110953, kind = 'perm', contractEndYear = 2029, joinSerial = 162086, wage = 9000, releaseClause = -1 },
    { name = 'Tin Jedvaj', to = 'Al Shabab', pid = 215930, tid = 111674, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 22000, releaseClause = -1 },
    { name = 'Simone Pontisso', to = 'Cremonese', pid = 228882, tid = 111434, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 16000, releaseClause = -1 },
    { name = 'Aodhan Doherty', to = 'Falkirk', pid = 82914, tid = 79, kind = 'loan', loanParent = 3, loanEndSerial = 162396, loanBuy = 0 },
    { name = 'Dudu', to = 'Guarani', pid = 258085, tid = 111329, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 9000, releaseClause = -1 },
    { name = 'Antonio Candela', to = 'Catanzaro', pid = 252315, tid = 110908, kind = 'loan', loanParent = 113974, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Felipe Lima', to = 'Benfica B', pid = 79911, tid = 234, kind = 'loan', loanParent = 717, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Marco Festa', to = 'Cremonese', pid = 230631, tid = 111434, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 12000, releaseClause = -1 },
    { name = 'Lewis Smith', to = 'Aberdeen', pid = 252571, tid = 77, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 5500, releaseClause = -1 },
    { name = 'Giannis Papanikolaou', to = 'Widzew Łódź', pid = 258040, tid = 301, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 9000, releaseClause = -1 },
    { name = 'Gilberto Flores', to = 'Libertad', pid = 268610, tid = 111008, kind = 'loan', loanParent = 113149, loanEndSerial = 162419, loanBuy = 0 },
    { name = 'Brayan Ceballos', to = 'Montreal', pid = 276960, tid = 111139, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 12000, releaseClause = -1 },
    { name = 'Millenic Alli', to = 'Charlton', pid = 71215, tid = 89, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 9000, releaseClause = -1 },
    { name = 'Carlos Marín', to = 'Albacete', pid = 254099, tid = 1854, kind = 'perm', contractEndYear = 2029, joinSerial = 162087, wage = 12000, releaseClause = -1 },
    { name = 'Jusuf Gazibegovic', to = 'Widzew Łódź', pid = 259101, tid = 301, kind = 'loan', loanParent = 209, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Alaa Bellaarouch', to = 'Dinamo Bucuresti', pid = 276988, tid = 100757, kind = 'loan', loanParent = 1896, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Lucas Núñez', to = 'Eibar', pid = 78669, tid = 467, kind = 'loan', loanParent = 461, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Miguel Rodríguez', to = 'Deportivo Alaves', pid = 258730, tid = 463, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 22000, releaseClause = -1 },
    { name = 'Simon Elisor', to = 'Universitatea Craiova', pid = 258526, tid = 308, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 12000, releaseClause = -1 },
    { name = 'Georgios Koutsias', to = 'Famalicao', pid = 258834, tid = 112809, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 9000, releaseClause = -1 },
    { name = 'Rodrigo Rodrigues', to = 'Sporting CP B', pid = 78722, tid = 237, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 3000, releaseClause = -1 },
    { name = 'Jonathan Dubasin', to = 'Osasuna', pid = 263883, tid = 479, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 30000, releaseClause = -1 },
    { name = 'Luca Erlein', to = 'Energie Cottbus', pid = 76923, tid = 162, kind = 'loan', loanParent = 32, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Emmanuel Addai', to = 'OH Leuven', pid = 276093, tid = 100087, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 12000, releaseClause = -1 },
    { name = 'Darko Churlinov', to = 'Pogoń Szczecin', pid = 251545, tid = 110746, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 9000, releaseClause = -1 },
    { name = 'Lanroy Machine', to = 'SC Heerenveen', pid = 78377, tid = 1913, kind = 'loan', loanParent = 1530, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Gustavo Varela', to = 'Monza', pid = 72337, tid = 111811, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 12000, releaseClause = -1 },
    { name = 'Darío Cáceres', to = 'Central Cordoba de Santiago', pid = 242691, tid = 112965, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 12000, releaseClause = -1 },
    { name = 'Aljosa Vasic', to = 'Südtirol', pid = 276451, tid = 112494, kind = 'loan', loanParent = 1843, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mustapha Isah', to = 'RAAL La Louviere', pid = 272529, tid = 132231, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 5500, releaseClause = -1 },
    { name = 'Franck Atoen', to = 'Dunkerque', pid = 81568, tid = 111276, kind = 'loan', loanParent = 748, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Lorenzo Carissoni', to = 'Padova', pid = 235292, tid = 110912, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 9000, releaseClause = -1 },
    { name = 'Emanuele Zuelli', to = 'Padova', pid = 256119, tid = 110912, kind = 'perm', contractEndYear = 2029, joinSerial = 162088, wage = 12000, releaseClause = -1 },
    { name = 'Dan Sinaté', to = 'Amiens', pid = 79493, tid = 1816, kind = 'loan', loanParent = 1530, loanEndSerial = 162426, loanBuy = 0 },
}
-- Main
-- ---------------------------------------------------------------------------
local function count_table(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function main()
    write_log("===== TRANSFER SCRIPT START =====")
    local indexes_ok = build_indexes()
    if not indexes_ok then
        write_log("FATAL: could not build player/team indexes from live DB")
        return
    end
    write_log("Indexes built: " .. count_table(PLAYER_INDEX) .. " players, "
        .. count_table(TEAM_INDEX) .. " teams, " .. count_table(CLUB_IDS) .. " clubs")

    local ok_count, fail_count, warn_count = 0, 0, 0
    for _, ent in ipairs(TRANSFERS) do
        local pid = resolve_player(ent.name, ent.pid)
        if not pid then
            fail_count = fail_count + 1
            write_log(string.format("[%02d] %-22s -> %-20s  PLAYER NOT FOUND", _,
                ent.name, ent.to or ent.team))
            if Sleep then Sleep(1) end
        else
            local tid = resolve_team(ent.to or ent.team, ent.tid)
            if not tid then
                fail_count = fail_count + 1
                write_log(string.format("[%02d] %-22s -> %-22s  TEAM NOT FOUND (pid=%d)", _,
                    ent.name, ent.to or ent.team, pid))
                if Sleep then Sleep(1) end
            else
                ent.pid, ent.tid, ent.to = pid, tid, ent.to or ent.team
                local ok, result = pcall(apply_transfer, ent)
                if not ok then
                    fail_count = fail_count + 1
                    write_log(string.format("[%02d] %-22s -> %-22s  ERROR: %s", _,
                        ent.name, ent.to, tostring(result)))
                else
                    if string.sub(result, 1, 2) == "OK" then
                        ok_count = ok_count + 1
                    else
                        warn_count = warn_count + 1
                    end
                    write_log(string.format("[%02d] %-22s -> %-22s  %s (pid=%d, tid=%d)", _,
                        ent.name, ent.to, result, pid, tid))
                end
                if Sleep then Sleep(5) end
            end
        end
    end
    write_log(string.format("===== DONE: %d ok, %d warn, %d failed =====",
        ok_count, warn_count, fail_count))
end

main()

