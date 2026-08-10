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

