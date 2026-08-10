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
    { name = 'Raphael Onyedika', to = 'Frankfurt', pid = 262880, tid = 1824, kind = 'perm', contractEndYear = 2029, joinSerial = 162094, wage = 53000, releaseClause = -1 },
    { name = 'Willem Geubbels', to = 'Lecce', pid = 241266, tid = 347, kind = 'perm', contractEndYear = 2029, joinSerial = 162094, wage = 22000, releaseClause = -1 },
    { name = 'Simon Sohm', to = 'Venezia', pid = 244634, tid = 205, kind = 'loan', loanParent = 110374, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Randal Kolo Muani', to = 'Juventus', pid = 237679, tid = 45, kind = 'perm', contractEndYear = 2029, joinSerial = 162094, wage = 53000, releaseClause = -1 },
    { name = 'Emmanuel Latte Lath', to = 'Union Berlin', pid = 237295, tid = 1831, kind = 'loan', loanParent = 112885, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mihai Lixandru', to = 'Al Fateh FC', pid = 253758, tid = 112390, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 12000, releaseClause = -1 },
    { name = 'Colin Rösler', to = 'AGF', pid = 243833, tid = 271, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 12000, releaseClause = -1 },
    { name = 'Souleymane Faye', to = 'Lorient', pid = 79547, tid = 217, kind = 'loan', loanParent = 237, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Fran González', to = 'Sevilla', pid = 278394, tid = 481, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 7000, releaseClause = -1 },
    { name = 'Danny Batth', to = 'Millwall', pid = 195037, tid = 97, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 12000, releaseClause = -1 },
    { name = 'Ulises Giménez', to = 'Sarmiento', pid = 279166, tid = 112713, kind = 'loan', loanParent = 1876, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Luis Díaz', to = 'Independiente Rivadavia', pid = 241084, tid = 111020, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 145000, releaseClause = -1 },
    { name = 'Manolis Saliakas', to = 'Olympiacos', pid = 222542, tid = 280, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 22000, releaseClause = -1 },
    { name = 'Killian Corredor', to = 'Nantes', pid = 262604, tid = 71, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 22000, releaseClause = -1 },
    { name = 'Moritz-Broni Kwarteng', to = 'Magdeburg', pid = 243970, tid = 110588, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 12000, releaseClause = -1 },
    { name = 'Jordan Henderson', to = 'Chelsea', pid = 183711, tid = 5, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 53000, releaseClause = -1 },
    { name = 'Vasilije Adzic', to = 'Sassuolo', pid = 75085, tid = 111974, kind = 'loan', loanParent = 45, loanEndSerial = 162426, loanBuy = 1 },
    { name = 'Péter Gulácsi', to = 'Villarreal', pid = 185122, tid = 483, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 110000, releaseClause = -1 },
    { name = 'Cameron Congreve', to = 'Westerlo', pid = 268306, tid = 681, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 7000, releaseClause = -1 },
    { name = 'Paulinho Bóia', to = 'Widzew Łódź', pid = 245790, tid = 301, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 12000, releaseClause = -1 },
    { name = 'João Mário', to = 'Fiorentina', pid = 212814, tid = 110374, kind = 'loan', loanParent = 45, loanEndSerial = 162426, loanBuy = 1 },
    { name = 'Yacine Titraoui', to = 'Lens', pid = 73348, tid = 64, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 12000, releaseClause = -1 },
    { name = 'Estanis Pedrola', to = 'Real Oviedo', pid = 266158, tid = 110827, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 16000, releaseClause = -1 },
    { name = 'César Palacios', to = 'Fulham', pid = 83235, tid = 144, kind = 'perm', contractEndYear = 2029, joinSerial = 162095, wage = 7000, releaseClause = -1 },
    { name = 'Faris Abdi', to = 'Al Ittihad', pid = 256130, tid = 607, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 5500, releaseClause = -1 },
    { name = 'Nedim Bajrami', to = 'Al-Taawoun', pid = 237640, tid = 112393, kind = 'loan', loanParent = 86, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Rodrigo Pinho', to = 'AVS Futebol SAD', pid = 229683, tid = 131463, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 12000, releaseClause = -1 },
    { name = 'Ian Subiabre', to = 'Tigre', pid = 279934, tid = 111715, kind = 'loan', loanParent = 1876, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Esteban Rolón', to = 'Barracas Central', pid = 231212, tid = 113044, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 12000, releaseClause = -1 },
    { name = 'Edwin Cerrillo', to = 'América', pid = 247509, tid = 101099, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 12000, releaseClause = -1 },
    { name = 'Sofiane Bendebka', to = 'Al Hazem', pid = 255487, tid = 113222, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 22000, releaseClause = -1 },
    { name = 'Freddie Potts', to = 'Club Brugge', pid = 264579, tid = 231, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 22000, releaseClause = -1 },
    { name = 'Thierno Baldé', to = 'Nancy', pid = 263250, tid = 1823, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 5500, releaseClause = -1 },
    { name = 'Tom Louchet', to = 'PAOK Thessaloniki', pid = 278187, tid = 393, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 22000, releaseClause = -1 },
    { name = 'Giovanni Reyna', to = 'Strasbourg', pid = 245541, tid = 76, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 22000, releaseClause = -1 },
    { name = 'Tommaso Maggioni', to = 'Juve Stabia', pid = 72857, tid = 112124, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 7000, releaseClause = -1 },
    { name = 'Cisse Sandra', to = 'Westerlo', pid = 260577, tid = 681, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 9000, releaseClause = -1 },
    { name = 'Joël Drommel', to = 'FC Twente', pid = 228279, tid = 1908, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 22000, releaseClause = -1 },
    { name = 'Ahmed Abdullahi', to = 'Eyüpspor', pid = 274219, tid = 131174, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 3000, releaseClause = -1 },
    { name = 'Max Arfsten', to = 'Middlesbrough', pid = 274535, tid = 12, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 22000, releaseClause = -1 },
    { name = 'Afimico Pululu', to = 'Al Hazem', pid = 239267, tid = 113222, kind = 'perm', contractEndYear = 2029, joinSerial = 162096, wage = 22000, releaseClause = -1 },
    { name = 'Kamil Lukoszek', to = 'Motor Lublin', pid = 276877, tid = 111097, kind = 'loan', loanParent = 420, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Alessandro Debenedetti', to = 'Cesena', pid = 73928, tid = 110915, kind = 'loan', loanParent = 110556, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Paulo Bernardo', to = 'Górnik Zabrze', pid = 263439, tid = 420, kind = 'loan', loanParent = 78, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Khalil Ayari', to = 'Dunkerque', pid = 84604, tid = 111276, kind = 'loan', loanParent = 111592, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Tobías Reinhart', to = 'Universidad de Chile', pid = 254804, tid = 15029, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 9000, releaseClause = -1 },
    { name = 'Darlin Yongwa', to = 'Norwich', pid = 253490, tid = 1792, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 16000, releaseClause = -1 },
    { name = 'Ibrahim Salah', to = 'Royal Antwerp', pid = 270828, tid = 230, kind = 'loan', loanParent = 896, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Gauthier Hein', to = 'Nice', pid = 234239, tid = 72, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 40000, releaseClause = -1 },
    { name = 'Rubén Botta', to = 'Nacional', pid = 215199, tid = 111325, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 30000, releaseClause = -1 },
    { name = 'Kyrell Wilson', to = 'Gent', pid = 272617, tid = 674, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 4500, releaseClause = -1 },
    { name = 'Antonio Fiori', to = 'Cesena', pid = 72861, tid = 110915, kind = 'loan', loanParent = 111433, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Felix Horn Myhre', to = 'West Brom', pid = 237937, tid = 109, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 30000, releaseClause = -1 },
    { name = 'Jesper Daland', to = 'Viking', pid = 256459, tid = 300, kind = 'loan', loanParent = 1961, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Leon Hien', to = 'Tromsø', pid = 256429, tid = 418, kind = 'loan', loanParent = 710, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Bruce Anderson', to = 'Livingston', pid = 245174, tid = 621, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 7000, releaseClause = -1 },
    { name = 'Daisuke Yokota', to = 'Rangers', pid = 274191, tid = 86, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 16000, releaseClause = -1 },
    { name = 'Mikaël Mandron', to = 'Stockport County', pid = 204785, tid = 1931, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 7000, releaseClause = -1 },
    { name = 'Alan Rodríguez', to = 'Rosario Central', pid = 253233, tid = 110580, kind = 'loan', loanParent = 111325, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Christian Früchtl', to = 'Salzburg', pid = 235266, tid = 191, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 16000, releaseClause = -1 },
    { name = 'Bilal Boutobba', to = 'Eyüpspor', pid = 226295, tid = 131174, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 12000, releaseClause = -1 },
    { name = 'Ibane Bowat', to = 'Huddersfield', pid = 276677, tid = 1939, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 9000, releaseClause = -1 },
    { name = 'Liam Thompson', to = 'Mansfield', pid = 263918, tid = 1940, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 9000, releaseClause = -1 },
    { name = 'Jack Moylan', to = 'Cardiff', pid = 261861, tid = 1961, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 9000, releaseClause = -1 },
    { name = 'Ben Amos', to = 'Burnley', pid = 173531, tid = 1796, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 5500, releaseClause = -1 },
    { name = 'Mason Melia', to = 'Lincoln', pid = 276346, tid = 149, kind = 'loan', loanParent = 18, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Ben Whiteman', to = 'Wrexham', pid = 225071, tid = 1947, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 22000, releaseClause = -1 },
    { name = 'Dion Lopy', to = 'Al Ittihad', pid = 259190, tid = 607, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 22000, releaseClause = -1 },
    { name = 'Mohamed Salah', to = 'Trabzonspor', pid = 209331, tid = 436, kind = 'perm', contractEndYear = 2029, joinSerial = 162097, wage = 185000, releaseClause = -1 },
    { name = 'Yan Diomande', to = 'Real Madrid', pid = 78012, tid = 243, kind = 'perm', contractEndYear = 2029, joinSerial = 162098, wage = 68000, releaseClause = -1 },
    { name = 'Jonathan Moalem', to = 'Strømsgodset', pid = 79034, tid = 922, kind = 'loan', loanParent = 819, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Juanlu Sánchez', to = 'Bournemouth', pid = 264174, tid = 1943, kind = 'perm', contractEndYear = 2029, joinSerial = 162098, wage = 30000, releaseClause = -1 },
    { name = 'Joël Veltman', to = 'West Ham', pid = 208004, tid = 19, kind = 'perm', contractEndYear = 2029, joinSerial = 162098, wage = 53000, releaseClause = -1 },
    { name = 'Igor Drapinski', to = 'Samsunspor', pid = 263036, tid = 748, kind = 'perm', contractEndYear = 2029, joinSerial = 162098, wage = 9000, releaseClause = -1 },
    { name = 'Javi Morcillo', to = 'Elche', pid = 85082, tid = 468, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 5500, releaseClause = -1 },
    { name = 'Unai Núñez', to = 'Espanyol', pid = 240900, tid = 452, kind = 'loan', loanParent = 461, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Awer Mabil', to = 'Melbourne City FC', pid = 212830, tid = 112224, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Christian Nørgaard', to = 'Everton', pid = 210697, tid = 7, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 68000, releaseClause = -1 },
    { name = 'Francisco Ortega', to = 'River Plate', pid = 242287, tid = 1876, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 22000, releaseClause = -1 },
    { name = 'Lyndon Dykes', to = 'Millwall', pid = 247279, tid = 97, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 12000, releaseClause = -1 },
    { name = 'Wes Burns', to = 'Leicester', pid = 212484, tid = 95, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 22000, releaseClause = -1 },
    { name = 'Filip Kostic', to = 'PSV Eindhoven', pid = 208574, tid = 247, kind = 'perm', contractEndYear = 2029, joinSerial = 162099, wage = 68000, releaseClause = -1 },
    { name = 'Wesley', to = 'Cruzeiro', pid = 74913, tid = 568, kind = 'loan', loanParent = 112139, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Luciano Rodríguez', to = 'Cruzeiro', pid = 273604, tid = 568, kind = 'loan', loanParent = 131798, loanEndSerial = 162457, loanBuy = 0 },
    { name = 'João Costa', to = 'Cruzeiro', pid = 73629, tid = 568, kind = 'loan', loanParent = 112096, loanEndSerial = 162426, loanBuy = 0 },
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

