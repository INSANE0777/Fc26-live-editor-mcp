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
    { name = 'Henry Gray', to = 'Wellington Phoenix', pid = 266151, tid = 111766, kind = 'loan', loanParent = 94, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Aurèle Amenda', to = 'Coventry', pid = 270846, tid = 1800, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 30000, releaseClause = -1 },
    { name = 'Rochinha', to = 'Casa Pia AC', pid = 222461, tid = 114510, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 16000, releaseClause = -1 },
    { name = 'Timon Wellenreuther', to = 'Wolfsburg', pid = 223686, tid = 175, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 40000, releaseClause = -1 },
    { name = 'Martin Hellan', to = 'Sandefjord', pid = 71321, tid = 1757, kind = 'loan', loanParent = 919, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Marius Müller', to = 'Aberdeen', pid = 208375, tid = 77, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 30000, releaseClause = -1 },
    { name = 'Lovro Zvonarek', to = 'Estrela da Amadora', pid = 269497, tid = 718, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 9000, releaseClause = -1 },
    { name = 'Franco Armani', to = 'Atletico Nacional', pid = 214584, tid = 101100, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 40000, releaseClause = -1 },
    { name = 'Allan Wlk', to = 'Lanus', pid = 274858, tid = 110395, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 7000, releaseClause = -1 },
    { name = 'Niklas Tauer', to = 'TSV Havelse', pid = 253474, tid = 110678, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 9000, releaseClause = -1 },
    { name = 'Tjark Ernst', to = 'Feyenoord', pid = 262931, tid = 246, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 16000, releaseClause = -1 },
    { name = 'Elias Saad', to = 'Nashville SC', pid = 274000, tid = 114162, kind = 'loan', loanParent = 100409, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Zan Celar', to = 'Basel', pid = 240317, tid = 896, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 12000, releaseClause = -1 },
    { name = 'Tomás Guiacobini', to = 'Ciudad de Bolivar', pid = 71944, tid = 110968, kind = 'loan', loanParent = 112713, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Manuel Roffo', to = 'Cerro Porteno', pid = 240796, tid = 112716, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 30000, releaseClause = -1 },
    { name = 'Pablo Pagis', to = 'Paris FC', pid = 266099, tid = 111817, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 22000, releaseClause = -1 },
    { name = 'Gustavo Cazonatti', to = 'Mirassol', pid = 69988, tid = 111975, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 12000, releaseClause = -1 },
    { name = 'Rayan Touzghar', to = 'Standard Liege', pid = 74445, tid = 232, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 7000, releaseClause = -1 },
    { name = 'Tarik Muharemovic', to = 'Leeds', pid = 262027, tid = 8, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 30000, releaseClause = -1 },
    { name = 'Eric Bailly', to = 'Columbus', pid = 225508, tid = 687, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 22000, releaseClause = -1 },
    { name = 'Pau López', to = 'FC Andorra', pid = 221087, tid = 114554, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 40000, releaseClause = -1 },
    { name = 'Grant-Leon Ranos', to = 'Tenerife', pid = 276358, tid = 116332, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 5500, releaseClause = -1 },
    { name = 'Pirosch Fischer', to = 'Tenerife', pid = 83946, tid = 116332, kind = 'loan', loanParent = 1903, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Hamed Traorè', to = 'Genoa', pid = 240787, tid = 110556, kind = 'loan', loanParent = 219, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Dani Requena', to = 'Levante', pid = 277684, tid = 1853, kind = 'loan', loanParent = 483, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Kai Wagner', to = 'Philadelphia', pid = 239704, tid = 112134, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 40000, releaseClause = -1 },
    { name = 'Ian Hoffmann', to = 'Mjällby', pid = 261762, tid = 112072, kind = 'loan', loanParent = 873, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Marcos Leonardo', to = 'Ajax', pid = 277797, tid = 245, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 53000, releaseClause = -1 },
    { name = 'Pantelis Hatzidiakos', to = 'PAOK Thessaloniki', pid = 229150, tid = 393, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 16000, releaseClause = -1 },
    { name = 'Maximilian Dietz', to = 'Górnik Zabrze', pid = 262917, tid = 420, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 9000, releaseClause = -1 },
    { name = 'Peru Rodríguez', to = 'CD Mirandes', pid = 265521, tid = 110069, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 7000, releaseClause = -1 },
    { name = 'Francisco Calvo', to = 'Nacional', pid = 213064, tid = 111325, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 9000, releaseClause = -1 },
    { name = 'Tobias Lauritsen', to = 'Sampdoria', pid = 230737, tid = 1837, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 22000, releaseClause = -1 },
    { name = 'Mauro Pittón', to = 'Tenerife', pid = 228961, tid = 116332, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 22000, releaseClause = -1 },
    { name = 'Rasmus Holten', to = 'Sandefjord', pid = 275492, tid = 1757, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 3000, releaseClause = -1 },
    { name = 'Maik Nawrocki', to = 'Lens', pid = 255838, tid = 64, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 12000, releaseClause = -1 },
    { name = 'Álvaro Montero', to = 'Velez Sarsfield', pid = 229541, tid = 101088, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 40000, releaseClause = -1 },
    { name = 'Sebastián Villa', to = 'Boca Juniors', pid = 233959, tid = 1877, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 40000, releaseClause = -1 },
    { name = 'Julián Fernández', to = 'Atletico Tucuman', pid = 219452, tid = 111708, kind = 'loan', loanParent = 111328, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Kevin Gutiérrez', to = 'Argentinos Juniors', pid = 74836, tid = 111019, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 3000, releaseClause = -1 },
    { name = 'Matheus Cunha', to = 'Internacional', pid = 240243, tid = 111325, kind = 'loan', loanParent = 568, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Nelson Weiper', to = 'Sturm Graz', pid = 268259, tid = 209, kind = 'loan', loanParent = 169, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Yannik Engelhardt', to = 'Freiburg', pid = 262906, tid = 25, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 22000, releaseClause = -1 },
    { name = 'Joel Roca', to = 'Olympiacos', pid = 272718, tid = 280, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 22000, releaseClause = -1 },
    { name = 'Raúl Lizoain', to = 'Granada', pid = 199101, tid = 110832, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 12000, releaseClause = -1 },
    { name = 'Jorge Meireles', to = 'AVS Futebol SAD', pid = 79293, tid = 131463, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 5500, releaseClause = -1 },
    { name = 'Luca Ravanelli', to = 'Sampdoria', pid = 245091, tid = 1837, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 16000, releaseClause = -1 },
    { name = 'Mërgim Vojvoda', to = 'Udinese', pid = 228349, tid = 55, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 40000, releaseClause = -1 },
    { name = 'Cenk Özkacar', to = 'Trabzonspor', pid = 258396, tid = 436, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 16000, releaseClause = -1 },
    { name = 'Rodrigo Rêgo', to = 'Castellon', pid = 82432, tid = 100852, kind = 'loan', loanParent = 1808, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Niklas Niehoff', to = 'Altach', pid = 276165, tid = 15009, kind = 'loan', loanParent = 576, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Noël Aséko', to = 'Frankfurt', pid = 279622, tid = 1824, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 16000, releaseClause = -1 },
    { name = 'Sebastiano Desplanches', to = 'Frosinone', pid = 276839, tid = 111657, kind = 'loan', loanParent = 1843, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mattia Fortin', to = 'Palermo', pid = 78934, tid = 1843, kind = 'loan', loanParent = 64, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Filip Marchwinski', to = 'Cracovia', pid = 246649, tid = 110747, kind = 'loan', loanParent = 347, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Adama Bojang', to = 'Sporting Charleroi', pid = 277578, tid = 670, kind = 'loan', loanParent = 379, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Tanguy Nianzou', to = 'Lille', pid = 252961, tid = 65, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 16000, releaseClause = -1 },
    { name = 'Amir Richardson', to = 'Le Havre', pid = 262236, tid = 1738, kind = 'loan', loanParent = 110374, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Kryspin Szczesniak', to = 'Radomiak Radom', pid = 263262, tid = 111088, kind = 'loan', loanParent = 420, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mahir Emreli', to = 'Raków Częstochowa', pid = 262800, tid = 114326, kind = 'loan', loanParent = 29, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Koray Günter', to = 'Al Ittihad Kalba', pid = 204451, tid = 607, kind = 'perm', contractEndYear = 2029, joinSerial = 162079, wage = 12000, releaseClause = -1 },
    { name = 'Rakan Kaabi', to = 'Al Ittihad', pid = 278132, tid = 607, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 3000, releaseClause = -1 },
    { name = 'Abdullah Al Qahtani', to = 'Al-Fayha', pid = 253207, tid = 113057, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 3000, releaseClause = -1 },
    { name = 'Abdulrahman Al-Obaid', to = 'Al Kholood', pid = 228627, tid = 131735, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 3000, releaseClause = -1 },
    { name = 'Mohammed Al Owais', to = 'Al Hilal', pid = 210923, tid = 605, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 12000, releaseClause = -1 },
    { name = 'Jonathan Herrera', to = 'Sarmiento', pid = 243977, tid = 112713, kind = 'loan', loanParent = 115472, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Hugo Andersson Mella', to = 'IFK Värnamo', pid = 71724, tid = 112126, kind = 'loan', loanParent = 113458, loanEndSerial = 162214, loanBuy = 0 },
    { name = 'Elliot Watt', to = 'Samsunspor', pid = 241982, tid = 748, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 12000, releaseClause = -1 },
    { name = 'Patrick Beach', to = 'Troyes', pid = 267599, tid = 294, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 9000, releaseClause = -1 },
    { name = 'Juan Cruz', to = 'Malaga', pid = 206219, tid = 573, kind = 'loan', loanParent = 100888, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Karlan Grant', to = 'Charlton', pid = 225668, tid = 89, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 16000, releaseClause = -1 },
    { name = 'Tayyip Talha Sanuç', to = 'Rizespor', pid = 242919, tid = 101037, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 9000, releaseClause = -1 },
    { name = 'Rick van Drongelen', to = 'Panathinaikos', pid = 233097, tid = 1884, kind = 'perm', contractEndYear = 2029, joinSerial = 162080, wage = 30000, releaseClause = -1 },
    { name = 'Ahmed Kutucu', to = 'Rizespor', pid = 245762, tid = 101037, kind = 'loan', loanParent = 325, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Xaver Kiefersauer', to = '1. FC Nürnberg', pid = 85508, tid = 171, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 3000, releaseClause = -1 },
    { name = 'Tino Casali', to = 'Bochum', pid = 222024, tid = 160, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 7000, releaseClause = -1 },
    { name = 'Karol Mets', to = 'Bochum', pid = 226506, tid = 160, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 16000, releaseClause = -1 },
    { name = 'Emmanuel Iyoha', to = 'Magdeburg', pid = 231353, tid = 110588, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 12000, releaseClause = -1 },
    { name = 'Andrin Hunziker', to = 'St. Gallen', pid = 267486, tid = 898, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 9000, releaseClause = -1 },
    { name = 'Anas Tajaouart', to = 'RAAL La Louviere', pid = 75197, tid = 132231, kind = 'loan', loanParent = 229, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Diego Alejandro Novoa', to = 'Bucaramanga', pid = 214351, tid = 112992, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 12000, releaseClause = -1 },
    { name = 'Mathieu Cafaro', to = 'Nantes', pid = 231236, tid = 71, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 22000, releaseClause = -1 },
    { name = 'Cristian Jaime', to = 'Peñarol', pid = 81813, tid = 101110, kind = 'loan', loanParent = 1876, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Hossam Abdelmaguid', to = 'Ludogorets Razgrad', pid = 81960, tid = 1906, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 12000, releaseClause = -1 },
    { name = 'Carlos Quintana', to = 'Deportivo Riestra', pid = 234458, tid = 115472, kind = 'perm', contractEndYear = 2029, joinSerial = 162081, wage = 30000, releaseClause = -1 },
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

