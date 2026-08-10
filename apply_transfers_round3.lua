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
    { name = 'Filip Krovinovic', to = 'Gremio', pid = 230988, tid = 1629, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 16000, releaseClause = -1 },
    { name = 'José Salinas', to = 'Malaga', pid = 258684, tid = 573, kind = 'loan', loanParent = 452, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Thomas Ince', to = 'Tranmere', pid = 200521, tid = 15048, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 12000, releaseClause = -1 },
    { name = 'Mohammed Mahzari', to = 'Al Hilal', pid = 277233, tid = 605, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 5500, releaseClause = -1 },
    { name = 'Tomás Muro', to = 'Luqueno', pid = 269832, tid = 111006, kind = 'loan', loanParent = 111020, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Otávio', to = 'Frankfurt', pid = 78088, tid = 1824, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 3000, releaseClause = -1 },
    { name = 'Owen Bevan', to = 'Dundee FC', pid = 271235, tid = 180, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 5500, releaseClause = -1 },
    { name = 'Valentin Sulzbacher', to = 'Excelsior', pid = 78099, tid = 1971, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 4500, releaseClause = -1 },
    { name = 'Calvin Stengs', to = 'AZ Alkmaar', pid = 236593, tid = 1906, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 40000, releaseClause = -1 },
    { name = 'Dirk Proper', to = 'SC Heerenveen', pid = 262334, tid = 1913, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 16000, releaseClause = -1 },
    { name = 'Philipp Förster', to = 'Düsseldorf', pid = 237540, tid = 110636, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 12000, releaseClause = -1 },
    { name = 'Rafa Soares', to = 'Estrela da Amadora', pid = 218936, tid = 718, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 16000, releaseClause = -1 },
    { name = 'Kjell Scherpen', to = 'Ipswich', pid = 243675, tid = 94, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 40000, releaseClause = -1 },
    { name = 'Luke Brooke-Smith', to = 'Portsmouth', pid = 76117, tid = 1790, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 3000, releaseClause = -1 },
    { name = 'Carlo Holse', to = 'St. Louis City', pid = 240040, tid = 113018, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 22000, releaseClause = -1 },
    { name = 'Nolan Galves', to = 'West Brom', pid = 275296, tid = 109, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 7000, releaseClause = -1 },
    { name = 'Joe Gauci', to = 'Lincoln', pid = 243917, tid = 149, kind = 'loan', loanParent = 2, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Luis Vázquez', to = 'Birmingham', pid = 251651, tid = 88, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 22000, releaseClause = -1 },
    { name = 'Ugo Raghouber', to = 'Burnley', pid = 74774, tid = 1796, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 16000, releaseClause = -1 },
    { name = 'Óscar Perea', to = 'América', pid = 274231, tid = 101099, kind = 'loan', loanParent = 76, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Rares Ilie', to = 'Mantova', pid = 262480, tid = 111433, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 12000, releaseClause = -1 },
    { name = 'Piero Quispe', to = 'Universitario de Deportes', pid = 267794, tid = 111014, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 12000, releaseClause = -1 },
    { name = 'Anders Klynge', to = 'Jagiellonia Białystok', pid = 257259, tid = 110745, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 9000, releaseClause = -1 },
    { name = 'Julio Díaz', to = 'Sevilla', pid = 82936, tid = 481, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 7000, releaseClause = -1 },
    { name = 'Andreas Skov Olsen', to = 'Başakşehir', pid = 240017, tid = 101014, kind = 'loan', loanParent = 175, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Sam Parker', to = 'Wycombe', pid = 278958, tid = 1933, kind = 'loan', loanParent = 1960, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Sebastian Berhalter', to = 'Middlesbrough', pid = 255205, tid = 12, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 16000, releaseClause = -1 },
    { name = 'Andrés Vombergar', to = 'Aldosivi', pid = 247143, tid = 111707, kind = 'perm', contractEndYear = 2029, joinSerial = 162089, wage = 30000, releaseClause = -1 },
    { name = 'Jack Shorrock', to = 'Sligo Rovers', pid = 277412, tid = 563, kind = 'loan', loanParent = 1928, loanEndSerial = 162214, loanBuy = 0 },
    { name = 'Stjepan Radeljic', to = 'Dinamo Zagreb', pid = 84037, tid = 211, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 9000, releaseClause = -1 },
    { name = 'Henrique Araújo', to = 'Casa Pia AC', pid = 266905, tid = 114510, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 12000, releaseClause = -1 },
    { name = 'Santiago Mele', to = 'Independiente', pid = 259259, tid = 110093, kind = 'loan', loanParent = 111592, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Patrick Ouotro', to = 'Vitoria de Guimaraes', pid = 72306, tid = 1887, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 5500, releaseClause = -1 },
    { name = 'Isak Helstad Amundsen', to = 'Fredrikstad', pid = 256384, tid = 2041, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 7000, releaseClause = -1 },
    { name = 'Lukas Jonsson', to = 'Djurgården', pid = 237359, tid = 710, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 9000, releaseClause = -1 },
    { name = 'Vozinha', to = 'Colo Colo', pid = 217141, tid = 110980, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 9000, releaseClause = -1 },
    { name = 'Niklas Dorsch', to = 'Toronto', pid = 231227, tid = 111651, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 30000, releaseClause = -1 },
    { name = 'Sankhoun Diawara', to = 'Milan', pid = 74510, tid = 131681, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 4500, releaseClause = -1 },
    { name = 'Jayden Fevrier', to = 'Blackburn', pid = 264581, tid = 3, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 7000, releaseClause = -1 },
    { name = 'Maxime Busi', to = 'Royal Antwerp', pid = 245084, tid = 230, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 12000, releaseClause = -1 },
    { name = 'Leo Sauer', to = 'VfB Stuttgart', pid = 277482, tid = 36, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 22000, releaseClause = -1 },
    { name = 'Joel Ndala', to = 'Cercle Brugge', pid = 74956, tid = 1750, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 9000, releaseClause = -1 },
    { name = 'Alassana Jatta', to = 'Casa Pia AC', pid = 256738, tid = 114510, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 7000, releaseClause = -1 },
    { name = 'René Mitongo', to = 'Trabzonspor', pid = 80182, tid = 436, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 5500, releaseClause = -1 },
    { name = 'Kacper Tobiasz', to = 'Gaziantep FK', pid = 262251, tid = 110776, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 9000, releaseClause = -1 },
    { name = 'Luís Balbo', to = 'Sturm Graz', pid = 83223, tid = 209, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 4500, releaseClause = -1 },
    { name = 'Damián Pizarro', to = 'Audax Italiano', pid = 268396, tid = 101097, kind = 'loan', loanParent = 55, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Pietro Comuzzo', to = 'Torino', pid = 278340, tid = 54, kind = 'loan', loanParent = 110374, loanEndSerial = 162426, loanBuy = 1 },
    { name = 'Eray Cömert', to = 'Torino', pid = 233885, tid = 54, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 22000, releaseClause = -1 },
    { name = 'Mikel Amondarain', to = 'Bologna', pid = 74813, tid = 189, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 22000, releaseClause = -1 },
    { name = 'Umut Bozok', to = 'Başakşehir', pid = 239043, tid = 101014, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 12000, releaseClause = -1 },
    { name = 'Florin Stefan', to = 'Gaziantep FK', pid = 248041, tid = 110776, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 9000, releaseClause = -1 },
    { name = 'Fer Niño', to = 'Elche', pid = 252590, tid = 468, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 16000, releaseClause = -1 },
    { name = 'Mattia Compagnon', to = 'Hellas Verona', pid = 276804, tid = 206, kind = 'loan', loanParent = 205, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Riccardo Pagano', to = 'Cesena', pid = 276951, tid = 110915, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 4500, releaseClause = -1 },
    { name = 'Chidozie Awaziem', to = 'Konyaspor', pid = 232693, tid = 101033, kind = 'perm', contractEndYear = 2029, joinSerial = 162090, wage = 22000, releaseClause = -1 },
    { name = 'Jordan Williams', to = 'Blackpool', pid = 237415, tid = 1926, kind = 'loan', loanParent = 1790, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Alfie Pond', to = 'Chesterfield', pid = 264622, tid = 1924, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 3000, releaseClause = -1 },
    { name = 'Diego Otoya', to = 'Monterey Bay FC', pid = 276045, tid = 131477, kind = 'loan', loanParent = 111013, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Stefan Ortega', to = 'Olympiacos', pid = 200159, tid = 280, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 53000, releaseClause = -1 },
    { name = 'Oliver Antman', to = 'Anderlecht', pid = 247447, tid = 229, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 22000, releaseClause = -1 },
    { name = 'Stefan Schwab', to = 'Ried', pid = 204688, tid = 780, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 16000, releaseClause = -1 },
    { name = 'Erawan Garnier', to = 'SC Bastia', pid = 83218, tid = 58, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 5500, releaseClause = -1 },
    { name = 'Junior Mwanga', to = 'Le Havre', pid = 269184, tid = 1738, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 22000, releaseClause = -1 },
    { name = 'Oliver Sorg', to = 'Ried', pid = 74112, tid = 780, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 3000, releaseClause = -1 },
    { name = 'Alessandro Dellavalle', to = 'Padova', pid = 72097, tid = 110912, kind = 'loan', loanParent = 54, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Thorsten Schriebl', to = 'Wolfsberger AC', pid = 72541, tid = 111822, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 5500, releaseClause = -1 },
    { name = 'Brooklyn Ezeh', to = 'Dynamo Dresden', pid = 262117, tid = 503, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 7000, releaseClause = -1 },
    { name = 'Michael Frey', to = 'Royal Antwerp', pid = 208159, tid = 230, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 16000, releaseClause = -1 },
    { name = 'Daniel Bennie', to = 'Dundee United', pid = 276561, tid = 181, kind = 'loan', loanParent = 15, loanEndSerial = 162396, loanBuy = 0 },
    { name = 'Malcolm Jeng', to = 'FC Groningen', pid = 275153, tid = 1915, kind = 'loan', loanParent = 379, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Robin van Cruijsen', to = 'Sparta Rotterdam', pid = 80489, tid = 100646, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 9000, releaseClause = -1 },
    { name = 'Mike Kleijn', to = 'FC Volendam', pid = 271120, tid = 645, kind = 'loan', loanParent = 100646, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Sander Svendsen', to = 'Kristiansund', pid = 215195, tid = 113459, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 9000, releaseClause = -1 },
    { name = 'Teodor Berg Haltvik', to = 'Sønderjyske', pid = 248392, tid = 1447, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 7000, releaseClause = -1 },
    { name = 'Roman Kvet', to = 'Bohemians 1905', pid = 272872, tid = 305, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 16000, releaseClause = -1 },
    { name = 'Rayan Bamba', to = 'Le Mans', pid = 71778, tid = 1739, kind = 'loan', loanParent = 1823, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Olwethu Makhanya', to = 'Rangers', pid = 278688, tid = 86, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 7000, releaseClause = -1 },
    { name = 'Daiki Hashioka', to = "M'gladbach", pid = 242006, tid = 23, kind = 'loan', loanParent = 674, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Rares Burnete', to = 'Südtirol', pid = 277636, tid = 112494, kind = 'loan', loanParent = 347, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Aritz Arambarri', to = 'CD Mirandes', pid = 254003, tid = 110069, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 12000, releaseClause = -1 },
    { name = 'John Stones', to = 'Inter', pid = 203574, tid = 131682, kind = 'perm', contractEndYear = 2029, joinSerial = 162091, wage = 88000, releaseClause = -1 },
    { name = 'Juan Rodríguez', to = 'Atletico Tucuman', pid = 75896, tid = 111708, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 5500, releaseClause = -1 },
    { name = 'Mateo García', to = "Newell's Old Boys", pid = 245908, tid = 110396, kind = 'loan', loanParent = 101105, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Lucas Michal', to = 'Cercle Brugge', pid = 70458, tid = 1750, kind = 'loan', loanParent = 69, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Lovro Majer', to = 'AEK Athens', pid = 244261, tid = 278, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 40000, releaseClause = -1 },
    { name = 'Matías Moreno', to = 'Venezia', pid = 276820, tid = 205, kind = 'loan', loanParent = 110374, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Callum Marshall', to = 'Luton', pid = 278101, tid = 1923, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 9000, releaseClause = -1 },
    { name = 'William Fitzgerald', to = 'Shamrock Rovers', pid = 241582, tid = 306, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 4500, releaseClause = -1 },
    { name = 'Marin Soticek', to = 'Hajduk Split', pid = 73582, tid = 263, kind = 'loan', loanParent = 896, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Gustavo Sá', to = 'Olympiacos', pid = 271057, tid = 280, kind = 'loan', loanParent = 19, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Maxence Lacroix', to = 'Chelsea', pid = 244067, tid = 5, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 68000, releaseClause = -1 },
    { name = 'Tyler Fredricson', to = 'Lausanne', pid = 269233, tid = 1862, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 7000, releaseClause = -1 },
    { name = 'Robert Ljubicic', to = 'LASK', pid = 243525, tid = 252, kind = 'loan', loanParent = 278, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Emiliano Amor', to = 'San Lorenzo', pid = 226170, tid = 1013, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 12000, releaseClause = -1 },
    { name = 'Alexander Schwolow', to = 'Mainz', pid = 202789, tid = 169, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 22000, releaseClause = -1 },
    { name = 'Davide Veroli', to = 'Südtirol', pid = 276443, tid = 112494, kind = 'loan', loanParent = 1842, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Raphael Kofler', to = 'Cagliari', pid = 277872, tid = 1842, kind = 'loan', loanParent = 112494, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Italo', to = 'Jeonbuk Hyundai Motors FC', pid = 70419, tid = 1477, kind = 'loan', loanParent = 1478, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Kian Fitz-Jim', to = 'Torino', pid = 262218, tid = 54, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 22000, releaseClause = -1 },
    { name = 'Federico Ravaglia', to = 'Watford', pid = 240657, tid = 1795, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 22000, releaseClause = -1 },
    { name = 'Lukas Willen', to = 'Pogoń Szczecin', pid = 268498, tid = 110746, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 5500, releaseClause = -1 },
    { name = 'Saba Sazonov', to = 'Getafe', pid = 278013, tid = 1860, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 22000, releaseClause = -1 },
    { name = 'Emanuele Rao', to = 'Pisa', pid = 80630, tid = 110738, kind = 'loan', loanParent = 48, loanEndSerial = 162426, loanBuy = 1 },
    { name = 'Liam Cullen', to = 'Leicester', pid = 233941, tid = 95, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 12000, releaseClause = -1 },
    { name = 'Lautaro Morales', to = 'Tigre', pid = 253012, tid = 111715, kind = 'loan', loanParent = 110395, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Federico Mancuello', to = 'Argentinos Juniors', pid = 214968, tid = 111019, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 12000, releaseClause = -1 },
    { name = 'Ignacio Pussetto', to = 'Huracan', pid = 219536, tid = 111711, kind = 'loan', loanParent = 110093, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Danilo Arboleda', to = 'San Lorenzo', pid = 227740, tid = 1013, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 12000, releaseClause = -1 },
    { name = 'Abdelhamid Sabiri', to = 'Eyüpspor', pid = 237499, tid = 131174, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 22000, releaseClause = -1 },
    { name = 'Simone Pafundi', to = 'Catanzaro', pid = 271575, tid = 110908, kind = 'loan', loanParent = 55, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Martín Payero', to = 'Watford', pid = 240970, tid = 1795, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 22000, releaseClause = -1 },
    { name = 'Kieron Bowie', to = 'Sassuolo', pid = 257104, tid = 111974, kind = 'loan', loanParent = 206, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Samuele Mulattieri', to = 'Hellas Verona', pid = 243200, tid = 206, kind = 'loan', loanParent = 111974, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Olti Hyseni', to = 'Brøndby IF', pid = 73504, tid = 269, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 7000, releaseClause = -1 },
    { name = 'Mario Mitaj', to = 'Genoa', pid = 258147, tid = 110556, kind = 'loan', loanParent = 607, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mathew Ryan', to = 'Levante', pid = 199005, tid = 1853, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 53000, releaseClause = -1 },
    { name = 'Jesse Bisiwu', to = 'Barcelona', pid = 55133, tid = 241, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 5500, releaseClause = -1 },
    { name = 'Josh Maja', to = 'Le Havre', pid = 235161, tid = 1738, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 16000, releaseClause = -1 },
    { name = 'Nampalys Mendy', to = 'Metz', pid = 198861, tid = 68, kind = 'perm', contractEndYear = 2029, joinSerial = 162092, wage = 22000, releaseClause = -1 },
    { name = 'Lucas Gómez', to = "Newell's Old Boys", pid = 70680, tid = 110396, kind = 'loan', loanParent = 111019, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Tomás Pérez', to = 'Defensa y Justicia', pid = 276605, tid = 111710, kind = 'loan', loanParent = 101085, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Martín Río', to = 'San Lorenzo', pid = 76469, tid = 1013, kind = 'loan', loanParent = 112670, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Aidan Stokes', to = 'Brentford', pid = 73858, tid = 1925, kind = 'loan', loanParent = 689, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Janne Berner', to = 'SC Verl', pid = 78130, tid = 110501, kind = 'loan', loanParent = 166, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Favour Fawunmi', to = 'Oldham', pid = 77599, tid = 1920, kind = 'loan', loanParent = 1806, loanEndSerial = 162396, loanBuy = 0 },
    { name = 'Peter Kiedl', to = 'Hansa Rostock', pid = 79942, tid = 27, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 5500, releaseClause = -1 },
    { name = 'Meiko Wäschenbach', to = 'Alemannia Aachen', pid = 74004, tid = 1826, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 5500, releaseClause = -1 },
    { name = 'Julian Brandt', to = 'Ajax', pid = 212194, tid = 245, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 88000, releaseClause = -1 },
    { name = 'Jesse Dempsey', to = 'Fleetwood', pid = 274451, tid = 112260, kind = 'loan', loanParent = 753, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Johnly Yfeko', to = 'Kilmarnock', pid = 277272, tid = 82, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 5500, releaseClause = -1 },
    { name = 'Jonathan Meier', to = 'Kilmarnock', pid = 243514, tid = 82, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 7000, releaseClause = -1 },
    { name = 'Lewis Montsma', to = 'Port Vale', pid = 257303, tid = 1928, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 7000, releaseClause = -1 },
    { name = 'Jamie Knight-Lebel', to = 'Motherwell', pid = 277747, tid = 83, kind = 'loan', loanParent = 1919, loanEndSerial = 162396, loanBuy = 0 },
    { name = 'Chris Cadden', to = 'Aberdeen', pid = 222109, tid = 77, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 9000, releaseClause = -1 },
    { name = 'Jeremías Lucco', to = 'Defensa y Justicia', pid = 70688, tid = 111710, kind = 'loan', loanParent = 111022, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Imanol Machuca', to = 'Independiente', pid = 259790, tid = 110093, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 16000, releaseClause = -1 },
    { name = 'Tobías Andrada', to = 'River Plate', pid = 79246, tid = 1876, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 7000, releaseClause = -1 },
    { name = 'Francisco Perruzzi', to = 'Aldosivi', pid = 269501, tid = 111707, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 7000, releaseClause = -1 },
    { name = 'Nicolás Orsini', to = 'Barracas Central', pid = 220148, tid = 113044, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 12000, releaseClause = -1 },
    { name = 'Kacper Sezonienko', to = 'Hellas Verona', pid = 263778, tid = 206, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 7000, releaseClause = -1 },
    { name = 'Youssef Maziz', to = 'Colorado', pid = 237138, tid = 694, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 22000, releaseClause = -1 },
    { name = 'Dejan Radonjic', to = 'Ried', pid = 73666, tid = 780, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 7000, releaseClause = -1 },
    { name = 'Ebenezer Akinsanmiro', to = 'Monza', pid = 70471, tid = 111811, kind = 'loan', loanParent = 131682, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Dominic Vavassori', to = 'Palermo', pid = 74573, tid = 1843, kind = 'loan', loanParent = 115845, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Ilias Kostis', to = 'Castellon', pid = 274208, tid = 100852, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 9000, releaseClause = -1 },
    { name = 'Patrick Soko', to = 'Leganes', pid = 240047, tid = 100888, kind = 'loan', loanParent = 1861, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Anto Sekongo', to = 'Samsunspor', pid = 73511, tid = 748, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 7000, releaseClause = -1 },
    { name = 'Damián Rodríguez', to = 'Cadiz', pid = 279112, tid = 1968, kind = 'loan', loanParent = 456, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Kevin Akpoguma', to = 'Frosinone', pid = 211856, tid = 111657, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 22000, releaseClause = -1 },
    { name = 'Danny Welbeck', to = 'Chelsea', pid = 186146, tid = 5, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 68000, releaseClause = -1 },
    { name = 'Redouane Halhal', to = 'Venezia', pid = 264657, tid = 205, kind = 'perm', contractEndYear = 2029, joinSerial = 162093, wage = 9000, releaseClause = -1 },
    { name = 'Lucas Sanseviero', to = 'Instituto', pid = 256159, tid = 110953, kind = 'loan', loanParent = 462, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Kamarl Grant', to = 'Bromley', pid = 278987, tid = 112764, kind = 'loan', loanParent = 97, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Gabriel Pirani', to = 'San Diego FC', pid = 277301, tid = 131439, kind = 'perm', contractEndYear = 2029, joinSerial = 162094, wage = 12000, releaseClause = -1 },
    { name = 'Niklas Ødegård', to = 'Molde', pid = 264295, tid = 417, kind = 'perm', contractEndYear = 2029, joinSerial = 162094, wage = 7000, releaseClause = -1 },
    { name = 'Marco Ruggero', to = 'Catanzaro', pid = 73989, tid = 110908, kind = 'loan', loanParent = 113974, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Simone Zanon', to = 'Pisa', pid = 72916, tid = 110738, kind = 'loan', loanParent = 112493, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Luke Thomas', to = 'St. Mirren', pid = 235059, tid = 100805, kind = 'perm', contractEndYear = 2029, joinSerial = 162094, wage = 4500, releaseClause = -1 },
    { name = 'Nordan Mukiele', to = 'Montpellier', pid = 80804, tid = 70, kind = 'loan', loanParent = 74, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Rodrigo Fernández', to = 'Huracan', pid = 253246, tid = 111711, kind = 'loan', loanParent = 110093, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Luciano Giménez', to = 'Club Atletico Platense', pid = 73887, tid = 112689, kind = 'loan', loanParent = 101083, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Maximiliano Porcel', to = 'Defensa y Justicia', pid = 74856, tid = 111710, kind = 'loan', loanParent = 101088, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Felix Bacher', to = 'Lyon', pid = 262404, tid = 66, kind = 'perm', contractEndYear = 2029, joinSerial = 162094, wage = 12000, releaseClause = -1 },
    { name = 'Nicolás Dubersarsky', to = 'Tigre', pid = 70676, tid = 111715, kind = 'loan', loanParent = 114161, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Jesús Camargo', to = 'Once Caldas', pid = 265675, tid = 101106, kind = 'loan', loanParent = 110990, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Esteban Matus', to = 'Olimpia', pid = 267588, tid = 101108, kind = 'perm', contractEndYear = 2029, joinSerial = 162094, wage = 12000, releaseClause = -1 },
    { name = 'Tom Watson', to = 'Leicester', pid = 275246, tid = 95, kind = 'loan', loanParent = 1808, loanEndSerial = 162396, loanBuy = 0 },
    { name = 'Adam Nhaili', to = 'FCV Dender EH', pid = 279807, tid = 537, kind = 'loan', loanParent = 680, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Jordan Zemura', to = 'Watford', pid = 259634, tid = 1795, kind = 'loan', loanParent = 55, loanEndSerial = 162426, loanBuy = 0 },
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

