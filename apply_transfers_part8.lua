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
    { name = 'Domingos Duarte', to = 'Sao Paulo', pid = 234835, tid = 598, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 30000, releaseClause = -1 },
    { name = 'Junior Dina Ebimbe', to = 'Schalke 04', pid = 248573, tid = 34, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 22000, releaseClause = -1 },
    { name = 'Ross Stewart', to = 'Swansea', pid = 244319, tid = 1960, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 16000, releaseClause = -1 },
    { name = 'Bersant Celina', to = 'Al-Ettifaq', pid = 220198, tid = 112096, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 16000, releaseClause = -1 },
    { name = 'Nathaniel Chalobah', to = 'Charlton', pid = 205897, tid = 89, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Metehan Altunbas', to = 'Kocaelispor', pid = 260459, tid = 101032, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 4500, releaseClause = -1 },
    { name = 'Josep Cerdà', to = 'Mallorca', pid = 79751, tid = 453, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 9000, releaseClause = -1 },
    { name = 'Nicolás Valentini', to = 'Deportivo Alaves', pid = 267681, tid = 463, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 22000, releaseClause = -1 },
    { name = 'Nicholas Opoku', to = 'Las Palmas', pid = 245022, tid = 472, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Lewis Temple', to = 'Oldham', pid = 270118, tid = 1920, kind = 'loan', loanParent = 4, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Jens Hjertø-Dahl', to = 'Hull', pid = 274979, tid = 1952, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Finley Barbrook', to = 'Falkirk', pid = 80501, tid = 79, kind = 'loan', loanParent = 94, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Delano Burgzorg', to = 'Preston', pid = 243619, tid = 1801, kind = 'loan', loanParent = 12, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Jay Robinson', to = 'Monza', pid = 78184, tid = 111811, kind = 'loan', loanParent = 17, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Takehiro Tomiyasu', to = 'Crystal Palace', pid = 232938, tid = 1799, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 40000, releaseClause = -1 },
    { name = 'Bjarki Steinn Bjarkason', to = 'Südtirol', pid = 258533, tid = 112494, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Marco Pompetti', to = 'Padova', pid = 237613, tid = 110912, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Gabriel Strefezza', to = 'Palermo', pid = 235949, tid = 1843, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 40000, releaseClause = -1 },
    { name = 'Alessandro Vogliacco', to = 'Cremonese', pid = 245566, tid = 111434, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Manuel Gasparini', to = 'Mantova', pid = 244483, tid = 111433, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 4500, releaseClause = -1 },
    { name = 'Filip Stojilkovic', to = 'FC Rapid', pid = 255562, tid = 310, kind = 'loan', loanParent = 110738, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Facundo Buonanotte', to = 'Elche', pid = 269495, tid = 468, kind = 'loan', loanParent = 1808, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Marash Kumbulla', to = 'Rayo Vallecano', pid = 245426, tid = 480, kind = 'loan', loanParent = 52, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Alex Forés', to = 'Burgos CF', pid = 269643, tid = 10846, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 16000, releaseClause = -1 },
    { name = 'Luca Zidane', to = 'Leganes', pid = 240311, tid = 100888, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Oscar Thorn', to = 'Colchester', pid = 274742, tid = 1935, kind = 'loan', loanParent = 149, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Gastón Togni', to = 'Club Atletico Platense', pid = 237512, tid = 112689, kind = 'loan', loanParent = 111710, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Keenan Gough', to = 'Bristol Rovers', pid = 80567, tid = 1962, kind = 'loan', loanParent = 89, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Caleb Yirenkyi', to = 'Coventry', pid = 73638, tid = 1800, kind = 'perm', contractEndYear = 2029, joinSerial = 162100, wage = 16000, releaseClause = -1 },
    { name = 'Maximiliano Salas', to = 'Independiente Rivadavia', pid = 244205, tid = 111020, kind = 'loan', loanParent = 1876, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Sion Oppong', to = 'Toulouse', pid = 76522, tid = 1809, kind = 'perm', contractEndYear = 2029, joinSerial = 162100, wage = 3000, releaseClause = -1 },
    { name = 'Orel Mangala', to = 'Getafe', pid = 234078, tid = 1860, kind = 'loan', loanParent = 66, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Saïdou Sow', to = 'Nantes', pid = 259119, tid = 71, kind = 'loan', loanParent = 76, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Otso Liimatta', to = 'Sirius', pid = 277310, tid = 113458, kind = 'perm', contractEndYear = 2029, joinSerial = 162100, wage = 9000, releaseClause = -1 },
    { name = 'Sasa Lukic', to = 'Ipswich', pid = 236699, tid = 94, kind = 'perm', contractEndYear = 2029, joinSerial = 162100, wage = 53000, releaseClause = -1 },
    { name = 'Noah Nsoki', to = 'Dinamo Zagreb', pid = 82991, tid = 211, kind = 'perm', contractEndYear = 2029, joinSerial = 162100, wage = 7000, releaseClause = -1 },
    { name = 'Kodai Sano', to = 'PSV Eindhoven', pid = 277809, tid = 247, kind = 'perm', contractEndYear = 2029, joinSerial = 162100, wage = 30000, releaseClause = -1 },
    { name = 'Thimothée Lo-Tutala', to = 'Colchester', pid = 271333, tid = 1935, kind = 'loan', loanParent = 1952, loanEndSerial = 162396, loanBuy = 0 },
    { name = 'Stélios Andreou', to = 'Estoril', pid = 262938, tid = 10020, kind = 'loan', loanParent = 301, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Daouda Traoré', to = 'Le Mans', pid = 279701, tid = 1739, kind = 'loan', loanParent = 17, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Aleksander Andresen', to = 'HamKam', pid = 273575, tid = 1756, kind = 'perm', contractEndYear = 2029, joinSerial = 162101, wage = 3000, releaseClause = -1 },
    { name = 'Andrés Reyes', to = 'Atletico Nacional', pid = 246048, tid = 101100, kind = 'perm', contractEndYear = 2029, joinSerial = 162101, wage = 9000, releaseClause = -1 },
    { name = 'Felipe Salomoni', to = 'Audax Italiano', pid = 264431, tid = 101097, kind = 'loan', loanParent = 111329, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Brynjar Ingi Bjarnason', to = 'Sønderjyske', pid = 263658, tid = 1447, kind = 'perm', contractEndYear = 2029, joinSerial = 162101, wage = 7000, releaseClause = -1 },
    { name = 'Jan Virgili', to = 'Club Brugge', pid = 80915, tid = 231, kind = 'perm', contractEndYear = 2029, joinSerial = 162101, wage = 30000, releaseClause = -1 },
    { name = 'Bruno Guimarães', to = 'Arsenal', pid = 247851, tid = 1, kind = 'perm', contractEndYear = 2030, joinSerial = 162100, wage = 145000, releaseClause = -1 },
    { name = 'Franco Mastantuono', to = 'Fiorentina', pid = 279173, tid = 110374, kind = 'loan', loanParent = 243, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Djibril Sow', to = 'Genoa', pid = 229752, tid = 110556, kind = 'perm', contractEndYear = 2030, joinSerial = 162099, wage = 30000, releaseClause = -1 },
    { name = 'Maghnes Akliouche', to = 'Paris Saint-Germain', pid = 264862, tid = 73, kind = 'perm', contractEndYear = 2030, joinSerial = 162099, wage = 68000, releaseClause = -1 },
    { name = 'James Trafford', to = 'Leeds United', pid = 263063, tid = 8, kind = 'perm', contractEndYear = 2030, joinSerial = 162099, wage = 40000, releaseClause = -1 },
    { name = 'Konstantinos Tzolakis', to = 'Hull City', pid = 252552, tid = 1952, kind = 'perm', contractEndYear = 2030, joinSerial = 162097, wage = 53000, releaseClause = -1 },
    { name = 'Miguel Gutiérrez', to = 'Bayer Leverkusen', pid = 261865, tid = 32, kind = 'perm', contractEndYear = 2030, joinSerial = 162097, wage = 68000, releaseClause = -1 },
    { name = 'Florentino', to = 'Ipswich Town', pid = 234569, tid = 94, kind = 'perm', contractEndYear = 2030, joinSerial = 162096, wage = 40000, releaseClause = -1 },
    { name = 'Gonzalo García', to = 'Fulham', pid = 278399, tid = 144, kind = 'perm', contractEndYear = 2030, joinSerial = 162095, wage = 30000, releaseClause = -1 },
    { name = 'Konstantinos Karetsas', to = 'Borussia Dortmund', pid = 70497, tid = 22, kind = 'perm', contractEndYear = 2030, joinSerial = 162095, wage = 30000, releaseClause = -1 },
    { name = 'Valentín Barco', to = 'Chelsea', pid = 263370, tid = 5, kind = 'perm', contractEndYear = 2030, joinSerial = 162094, wage = 53000, releaseClause = -1 },
    { name = 'Kerim Alajbegovic', to = 'Juventus', pid = 75533, tid = 45, kind = 'perm', contractEndYear = 2030, joinSerial = 162094, wage = 12000, releaseClause = -1 },
    { name = 'Konstantinos Koulierakis', to = 'Roma', pid = 270077, tid = 52, kind = 'perm', contractEndYear = 2030, joinSerial = 162093, wage = 40000, releaseClause = -1 },
    { name = 'Mamadou Sangaré', to = 'Brentford', pid = 258601, tid = 1925, kind = 'perm', contractEndYear = 2030, joinSerial = 162093, wage = 68000, releaseClause = -1 },
    { name = 'António Silva', to = 'AFC Bournemouth', pid = 270086, tid = 1943, kind = 'perm', contractEndYear = 2030, joinSerial = 162093, wage = 40000, releaseClause = -1 },
    { name = 'Carlos Espí', to = 'Real Madrid', pid = 70967, tid = 243, kind = 'perm', contractEndYear = 2030, joinSerial = 162091, wage = 30000, releaseClause = -1 },
    { name = 'Artem Dovbyk', to = 'Bologna', pid = 242458, tid = 189, kind = 'loan', loanParent = 52, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Santiago Castro', to = 'Roma', pid = 267861, tid = 52, kind = 'perm', contractEndYear = 2030, joinSerial = 162091, wage = 40000, releaseClause = -1 },
    { name = 'Matthis Abline', to = 'Monaco', pid = 264422, tid = 69, kind = 'perm', contractEndYear = 2030, joinSerial = 162091, wage = 40000, releaseClause = -1 },
    { name = 'Tolu Arokodare', to = 'Ajax', pid = 258911, tid = 245, kind = 'loan', loanParent = 110, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Loïs Openda', to = 'Lyon', pid = 243580, tid = 66, kind = 'loan', loanParent = 45, loanEndSerial = 162426, loanBuy = 1 },
    { name = 'Crysencio Summerville', to = 'Al Hilal', pid = 251954, tid = 605, kind = 'perm', contractEndYear = 2030, joinSerial = 162085, wage = 53000, releaseClause = -1 },
    { name = 'Aladji Bamba', to = 'Newcastle United', pid = 75734, tid = 13, kind = 'perm', contractEndYear = 2030, joinSerial = 162085, wage = 16000, releaseClause = -1 },
    { name = 'Alejandro Garnacho', to = 'Aston Villa', pid = 268438, tid = 2, kind = 'loan', loanParent = 5, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Christos Tzolis', to = 'Arsenal', pid = 256948, tid = 1, kind = 'perm', contractEndYear = 2030, joinSerial = 162084, wage = 68000, releaseClause = -1 },
    { name = 'Karim Adeyemi', to = 'Barcelona', pid = 251852, tid = 241, kind = 'perm', contractEndYear = 2030, joinSerial = 162084, wage = 88000, releaseClause = -1 },
    { name = 'Ibrahima Ba', to = 'Sporting CP', pid = 71781, tid = 237, kind = 'perm', contractEndYear = 2030, joinSerial = 162083, wage = 9000, releaseClause = -1 },
    { name = 'Morgan Rogers', to = 'Chelsea', pid = 260247, tid = 5, kind = 'perm', contractEndYear = 2030, joinSerial = 162083, wage = 110000, releaseClause = -1 },
    { name = 'Abdul Fatawu', to = 'Ipswich Town', pid = 267680, tid = 94, kind = 'perm', contractEndYear = 2030, joinSerial = 162083, wage = 40000, releaseClause = -1 },
    { name = 'João Gomes', to = 'Aston Villa', pid = 273463, tid = 2, kind = 'perm', contractEndYear = 2030, joinSerial = 162081, wage = 53000, releaseClause = -1 },
    { name = 'Christ Inao Oulaï', to = 'Fiorentina', pid = 74735, tid = 110374, kind = 'perm', contractEndYear = 2030, joinSerial = 162081, wage = 16000, releaseClause = -1 },
    { name = 'Trincão', to = 'Al Ahli', pid = 244778, tid = 112387, kind = 'perm', contractEndYear = 2030, joinSerial = 162079, wage = 88000, releaseClause = -1 },
    { name = 'Johan Manzambi', to = 'Aston Villa', pid = 276694, tid = 2, kind = 'perm', contractEndYear = 2030, joinSerial = 162078, wage = 40000, releaseClause = -1 },
    { name = 'Robin Gosens', to = 'Schalke 04', pid = 223697, tid = 34, kind = 'loan', loanParent = 110374, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Maxime Estève', to = 'RB Leipzig', pid = 262042, tid = 112172, kind = 'perm', contractEndYear = 2030, joinSerial = 162078, wage = 40000, releaseClause = -1 },
    { name = 'Zeki Çelik', to = 'Juventus', pid = 224490, tid = 45, kind = 'perm', contractEndYear = 2030, joinSerial = 162077, wage = 53000, releaseClause = -1 },
    { name = 'Lesley Ugochukwu', to = 'Galatasaray', pid = 257084, tid = 325, kind = 'loan', loanParent = 1796, loanEndSerial = 162426, loanBuy = 1 },
    { name = 'Youri Tielemans', to = 'Manchester United', pid = 216393, tid = 11, kind = 'perm', contractEndYear = 2030, joinSerial = 162075, wage = 110000, releaseClause = -1 },
    { name = 'Leandro Trossard', to = 'Beşiktaş', pid = 207421, tid = 327, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 88000, releaseClause = -1 },
    { name = 'Álex Jiménez', to = 'Fiorentina', pid = 278928, tid = 110374, kind = 'loan', loanParent = 1943, loanEndSerial = 162426, loanBuy = 0 },
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

