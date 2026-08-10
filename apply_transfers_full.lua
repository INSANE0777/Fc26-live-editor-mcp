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
    { name = 'Dan Nlundulu', to = 'Petrolul Ploiesti', pid = 236321, tid = 110078, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 4500, releaseClause = -1 },
    { name = 'Jusef Erabi', to = 'Preston', pid = 268597, tid = 1801, kind = 'loan', loanParent = 673, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Jacopo Fazzini', to = 'Cagliari', pid = 266596, tid = 1842, kind = 'loan', loanParent = 110374, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Yann Sommer', to = 'Club Brugge', pid = 177683, tid = 231, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 145000, releaseClause = -1 },
    { name = 'Marius Lode', to = 'Sarpsborg 08', pid = 242160, tid = 112199, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 12000, releaseClause = -1 },
    { name = 'Alan Forrest', to = 'Dundee FC', pid = 256421, tid = 180, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 9000, releaseClause = -1 },
    { name = 'Alex Paulsen', to = 'Motherwell', pid = 263851, tid = 83, kind = 'loan', loanParent = 1943, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Ben Krauhaus', to = 'Falkirk', pid = 72456, tid = 79, kind = 'loan', loanParent = 1925, loanEndSerial = 162396, loanBuy = 0 },
    { name = 'Vincent Sasso', to = 'Le Havre', pid = 188538, tid = 1738, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 22000, releaseClause = -1 },
    { name = 'Nicolás López', to = 'Club Atletico Platense', pid = 207715, tid = 112689, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 30000, releaseClause = -1 },
    { name = 'Luka Vuskovic', to = 'Brighton', pid = 275192, tid = 1808, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 53000, releaseClause = -1 },
    { name = 'Fabio Gerli', to = 'Cremonese', pid = 225428, tid = 111434, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 12000, releaseClause = -1 },
    { name = 'Jorge Fernandes', to = 'Shabab Al-Ahli Dubai FC', pid = 242359, tid = 112387, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 22000, releaseClause = -1 },
    { name = 'Nathan Ordaz', to = 'DC United', pid = 275974, tid = 688, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 9000, releaseClause = -1 },
    { name = 'Amir Saipi', to = 'Castellon', pid = 247077, tid = 100852, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 16000, releaseClause = -1 },
    { name = 'Lohann Doucet', to = 'Vitoria de Guimaraes', pid = 270355, tid = 1887, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 12000, releaseClause = -1 },
    { name = 'Sam Larsson', to = 'IFK Göteborg', pid = 209782, tid = 319, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 12000, releaseClause = -1 },
    { name = 'Nikola Vasic', to = 'GAIS', pid = 272916, tid = 111594, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 9000, releaseClause = -1 },
    { name = 'Jakob Vestergaard Jessen', to = 'Kasımpaşa', pid = 78613, tid = 111339, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 5500, releaseClause = -1 },
    { name = 'Ander Herrera', to = 'Real Zaragoza', pid = 191740, tid = 244, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 40000, releaseClause = -1 },
    { name = 'Jean Batoum', to = 'Nyiregyhaza Spartacus FC', pid = 83925, tid = 1906, kind = 'loan', loanParent = 110747, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Samuele Capolupo', to = 'Spezia', pid = 80835, tid = 113974, kind = 'loan', loanParent = 111811, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Nathan Lowe', to = 'Hibernian', pid = 274472, tid = 81, kind = 'loan', loanParent = 1806, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Danilho Doekhi', to = 'Lazio', pid = 232658, tid = 1906, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 68000, releaseClause = -1 },
    { name = 'Álvaro Rodriguez', to = 'Bournemouth', pid = 237206, tid = 1943, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 9000, releaseClause = -1 },
    { name = 'Fellipe Jack', to = 'Cremonese', pid = 75225, tid = 111434, kind = 'loan', loanParent = 1745, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Jonas Harder', to = 'Basel', pid = 76171, tid = 896, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 7000, releaseClause = -1 },
    { name = 'Murphy Cooper', to = 'Plymouth', pid = 268544, tid = 1929, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 7000, releaseClause = -1 },
    { name = 'Charlie Taylor', to = 'Derby', pid = 204760, tid = 91, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 16000, releaseClause = -1 },
    { name = 'Adam Mayor', to = 'Hibernian', pid = 271675, tid = 81, kind = 'perm', contractEndYear = 2029, joinSerial = 162075, wage = 5500, releaseClause = -1 },
    { name = 'Horatiu Moldovan', to = 'Eyüpspor', pid = 251136, tid = 131174, kind = 'loan', loanParent = 240, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Shin Yamada', to = 'OH Leuven', pid = 269842, tid = 100087, kind = 'loan', loanParent = 78, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Lorenzo Ignacchiti', to = 'Mantova', pid = 74150, tid = 111433, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 9000, releaseClause = -1 },
    { name = 'Coleen Louis', to = 'Basel', pid = 70018, tid = 896, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 5500, releaseClause = -1 },
    { name = 'Giacomo Corona', to = 'Virtus Entella', pid = 276754, tid = 113147, kind = 'loan', loanParent = 1843, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Elías Pereyra', to = 'Barracas Central', pid = 241929, tid = 113044, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 12000, releaseClause = -1 },
    { name = 'Rui Mendes', to = 'Telstar', pid = 269744, tid = 100638, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 7000, releaseClause = -1 },
    { name = 'Tyrese Noslin', to = 'Barnsley', pid = 79032, tid = 1932, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 9000, releaseClause = -1 },
    { name = 'Paulo Díaz', to = 'Atlanta United', pid = 214436, tid = 112885, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 30000, releaseClause = -1 },
    { name = 'Michal Skóras', to = 'Lens', pid = 251633, tid = 64, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 16000, releaseClause = -1 },
    { name = 'Andrej Vasovic', to = 'Club Brugge', pid = 75573, tid = 231, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 3000, releaseClause = -1 },
    { name = 'Alan Franco', to = 'Tigres', pid = 246058, tid = 111715, kind = 'loan', loanParent = 598, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Maxim Dal', to = 'Greuther Fürth', pid = 276863, tid = 165, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 3000, releaseClause = -1 },
    { name = 'Eseosa Sule', to = 'St. Mirren', pid = 79681, tid = 100805, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 3000, releaseClause = -1 },
    { name = 'Tom Wisbereit', to = 'Augsburg', pid = 85547, tid = 100409, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 3000, releaseClause = -1 },
    { name = 'Nahuel Estévez', to = 'Palermo', pid = 240992, tid = 1843, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 16000, releaseClause = -1 },
    { name = 'Harry Winks', to = 'Cagliari', pid = 222400, tid = 1842, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 22000, releaseClause = -1 },
    { name = 'Ebrima Colley', to = 'Konyaspor', pid = 254692, tid = 101033, kind = 'loan', loanParent = 900, loanEndSerial = 162426, loanBuy = 1 },
    { name = 'Mihail Polendakov', to = 'Ludogorets Razgrad', pid = 79950, tid = 1906, kind = 'loan', loanParent = 1794, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Lewis Dobbin', to = 'Southampton', pid = 264039, tid = 17, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 16000, releaseClause = -1 },
    { name = 'Nikolai Skuseth', to = 'Degerfors', pid = 74740, tid = 113892, kind = 'loan', loanParent = 112199, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Thomas Meunier', to = 'Sunderland', pid = 202371, tid = 106, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 40000, releaseClause = -1 },
    { name = 'Martin Ens', to = 'MSV Duisburg', pid = 279530, tid = 1825, kind = 'loan', loanParent = 10030, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Vasco Lopes', to = 'Südtirol', pid = 72658, tid = 112494, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 9000, releaseClause = -1 },
    { name = 'Jawad El Yamiq', to = 'Eyüpspor', pid = 241775, tid = 131174, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 16000, releaseClause = -1 },
    { name = 'Florian Kleinhansl', to = 'Darmstadt', pid = 263089, tid = 110502, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 9000, releaseClause = -1 },
    { name = 'Vincent Burlet', to = 'Cracovia', pid = 72080, tid = 110747, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 9000, releaseClause = -1 },
    { name = 'Elkan Baggott', to = 'Millwall', pid = 260798, tid = 97, kind = 'perm', contractEndYear = 2029, joinSerial = 162076, wage = 5500, releaseClause = -1 },
    { name = 'Oliwier Zych', to = 'Vitoria de Guimaraes', pid = 271411, tid = 1887, kind = 'loan', loanParent = 2, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Áron Csongvai', to = 'Saint-Etienne', pid = 272566, tid = 1819, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 12000, releaseClause = -1 },
    { name = 'Jake Girdwood-Reich', to = 'Motherwell', pid = 272324, tid = 83, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 9000, releaseClause = -1 },
    { name = 'Christ Makosso', to = 'Auxerre', pid = 275337, tid = 57, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 9000, releaseClause = -1 },
    { name = 'Diogo Nascimento', to = 'Rio Ave', pid = 276998, tid = 744, kind = 'loan', loanParent = 280, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mikel Rodriguez', to = 'Deportivo Alaves', pid = 79186, tid = 463, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 9000, releaseClause = -1 },
    { name = 'Aïssa Mandi', to = 'Levante', pid = 201143, tid = 1853, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 40000, releaseClause = -1 },
    { name = 'Andrés García', to = 'Getafe', pid = 275468, tid = 1860, kind = 'loan', loanParent = 2, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Isaac Schmidt', to = 'Young Boys', pid = 256776, tid = 900, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 22000, releaseClause = -1 },
    { name = 'Miguel Silva', to = 'Carabobo FC', pid = 83568, tid = 110991, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 3000, releaseClause = -1 },
    { name = 'Jeison Medina', to = 'Independiente Medellin', pid = 242492, tid = 101103, kind = 'loan', loanParent = 110986, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Alfonso Simarra', to = 'Independiente Medellin', pid = 265186, tid = 101103, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 9000, releaseClause = -1 },
    { name = 'Thiemoko Diarra', to = 'Kasımpaşa', pid = 80238, tid = 111339, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 7000, releaseClause = -1 },
    { name = 'Vivaldo Semedo', to = 'Alverca', pid = 273918, tid = 717, kind = 'loan', loanParent = 1795, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Mathias Sauer', to = 'Sandefjord', pid = 274710, tid = 1757, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 7000, releaseClause = -1 },
    { name = 'Niklas Pyyhtiä', to = 'Südtirol', pid = 274089, tid = 112494, kind = 'loan', loanParent = 189, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Makenzie Kirk', to = 'Barnsley', pid = 278602, tid = 1932, kind = 'loan', loanParent = 1790, loanEndSerial = 162426, loanBuy = 0 },
    { name = 'Alex Král', to = 'FC København', pid = 247028, tid = 819, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 22000, releaseClause = -1 },
    { name = 'Omar Traoré', to = 'Watford', pid = 257136, tid = 1795, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 22000, releaseClause = -1 },
    { name = 'Jakes Gorosabel', to = 'Girona', pid = 80113, tid = 110062, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 5500, releaseClause = -1 },
    { name = 'Diego Mascardi', to = 'Torino', pid = 279891, tid = 54, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 5500, releaseClause = -1 },
    { name = 'Warren Kamanzi', to = 'Malmö FF', pid = 257970, tid = 320, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 22000, releaseClause = -1 },
    { name = 'Conrado', to = 'Radomiak Radom', pid = 238895, tid = 111088, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 7000, releaseClause = -1 },
    { name = 'Dennis Praet', to = 'KV Mechelen', pid = 199652, tid = 110724, kind = 'perm', contractEndYear = 2029, joinSerial = 162077, wage = 30000, releaseClause = -1 },
    { name = 'Tomás Avilés', to = "O'Higgins", pid = 274569, tid = 112116, kind = 'loan', loanParent = 112893, loanEndSerial = 162245, loanBuy = 0 },
    { name = 'Julián Mavilla', to = 'Sarmiento', pid = 76999, tid = 112713, kind = 'loan', loanParent = 111022, loanEndSerial = 162610, loanBuy = 0 },
    { name = 'Luka Jovanovic', to = 'San Jose', pid = 272571, tid = 111928, kind = 'perm', contractEndYear = 2029, joinSerial = 162078, wage = 7000, releaseClause = -1 },
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

