--[[
    Live Editor MCP Bridge - Full Edition

    Place this script in your FC 26 Live Editor lua/scripts folder or run it
    from Features -> Lua Engine. It polls a command folder and executes
    database/transfer/player operations via the Live Editor Lua API.

    Default command folder: <Live Editor folder>/le_bridge/
    You can change FC26_BRIDGE_ROOT env var to override.
]]

local json = require "imports/external/json"

-- Bridge root path. The script expects subfolders: in, out, logs
-- These folders are created by the fc26-mcp-live Python server. Run it before this script.
-- Override this with the FC26_BRIDGE_ROOT environment variable, or edit the fallback below.
local BRIDGE_ROOT = os.getenv("FC26_BRIDGE_ROOT") or "C:/FC26LiveEditor/le_bridge"
BRIDGE_ROOT = BRIDGE_ROOT:gsub("\\", "/")

local IN_DIR  = BRIDGE_ROOT .. "/in"
local OUT_DIR = BRIDGE_ROOT .. "/out"
local LOG_DIR = BRIDGE_ROOT .. "/logs"
local CACHE_DIR = BRIDGE_ROOT .. "/cache"


local function log(msg)
    local f = io.open(LOG_DIR .. "/bridge.log", "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
    if Log then
        Log("[MCP Bridge] " .. tostring(msg))
    end
end

local function write_result(id, payload)
    local path = OUT_DIR .. "/" .. id .. ".json"
    local f = io.open(path, "w")
    if not f then
        log("Failed to open output file: " .. path)
        return false
    end
    f:write(json.encode(payload))
    f:close()
    return true
end

local function safe_name(name)
    return tostring(name or "")
end

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
    -- Lua 5.1 gsub(".") matches bytes, not UTF-8 chars, so iterate UTF-8 chars manually
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

local function normalize_team_arg(arg)
    if type(arg) == "number" then return arg end
    if type(arg) == "string" then
        local n = tonumber(arg)
        if n then return n end
        local lower_arg = strip_accents(string.lower(arg))
        local rows = GetDBTableRows("teams") or {}
        local best_id = nil
        local best_score = 0
        for _, row in ipairs(rows) do
            local name = safe_name(row.teamname and row.teamname.value)
            local abbr = safe_name(row.teamabbreviation and row.teamabbreviation.value)
            local lower_name = strip_accents(string.lower(name))
            local lower_abbr = strip_accents(string.lower(abbr))
            if lower_name == lower_arg or lower_abbr == lower_arg then
                return tonumber(row.teamid.value)
            end
            -- fuzzy substring match
            if string.find(lower_name, lower_arg, 1, true) or string.find(lower_abbr, lower_arg, 1, true) then
                return tonumber(row.teamid.value)
            end
            local score = 0
            if #lower_arg > 0 and #lower_name > 0 then
                score = #lower_arg / #lower_name
            end
            if score > best_score then
                best_score = score
                best_id = tonumber(row.teamid.value)
            end
        end
        if best_score >= 0.5 then
            return best_id
        end
    end
    return nil
end

-- Persistent name caches (loaded from disk, rebuilt on first use if missing)
local PLAYER_CACHE = {}
local PLAYER_NAME_INDEX = {}
local TEAM_CACHE = {}
local TEAM_NAME_INDEX = {}
local CACHE_LOADED = false

local function load_cache_from_file()
    local path = CACHE_DIR .. "/names.json"
    local f = io.open(path, "r")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    local ok, decoded = pcall(json.decode, data)
    if not ok or type(decoded) ~= "table" then return false end
    PLAYER_CACHE = decoded.players or {}
    PLAYER_NAME_INDEX = decoded.player_index or {}
    TEAM_CACHE = decoded.teams or {}
    TEAM_NAME_INDEX = decoded.team_index or {}
    return next(PLAYER_CACHE) ~= nil
end

local function save_cache_to_file()
    local ok, data = pcall(json.encode, {
        players = PLAYER_CACHE,
        player_index = PLAYER_NAME_INDEX,
        teams = TEAM_CACHE,
        team_index = TEAM_NAME_INDEX
    })
    if not ok then return end
    local path = CACHE_DIR .. "/names.json"
    local f = io.open(path, "w")
    if f then
        f:write(data)
        f:close()
    end
end

local function build_caches()
    log("Building name cache (one-time)...")
    PLAYER_CACHE = {}
    PLAYER_NAME_INDEX = {}
    TEAM_CACHE = {}
    TEAM_NAME_INDEX = {}

    local ok, rows = pcall(GetDBTableRows, "players")
    if ok and rows then
        local total = #rows
        local count = 0
        for _, row in ipairs(rows) do
            local pid = tonumber(row.playerid.value)
            local ok2, pname = pcall(GetPlayerName, pid)
            if ok2 and pname then
                local entry = {
                    playerid = pid,
                    name = safe_name(pname),
                    overallrating = tonumber(row.overallrating and row.overallrating.value or 0)
                }
                PLAYER_CACHE[pid] = entry
                PLAYER_NAME_INDEX[strip_accents(string.lower(entry.name))] = entry
            end
            count = count + 1
            if count % 1000 == 0 then
                log("Cache build progress: " .. count .. "/" .. total .. " players")
                if Sleep then Sleep(1) end
            end
        end
        log("Player cache built: " .. count .. " entries")
    end

    local ok2, trows = pcall(GetDBTableRows, "teams")
    if ok2 and trows then
        for _, row in ipairs(trows) do
            local tid = tonumber(row.teamid.value)
            local tname = safe_name(row.teamname and row.teamname.value)
            local abbr = safe_name(row.teamabbreviation and row.teamabbreviation.value)
            local entry = { teamid = tid, teamname = tname, abbreviation = abbr }
            TEAM_CACHE[tid] = entry
            TEAM_NAME_INDEX[strip_accents(string.lower(tname))] = entry
            if abbr ~= "" then
                TEAM_NAME_INDEX[strip_accents(string.lower(abbr))] = entry
            end
        end
    end

    save_cache_to_file()
    CACHE_LOADED = true
    log("Name cache saved to disk")
end

local function ensure_cache_loaded()
    if CACHE_LOADED then return end
    if load_cache_from_file() then
        CACHE_LOADED = true
        log("Name cache loaded from disk")
        return
    end
    build_caches()
end



local function normalize_player_arg(arg)
    if type(arg) == "number" then return arg end
    if type(arg) == "string" then
        local n = tonumber(arg)
        if n then return n end
        ensure_cache_loaded()
        local lower_arg = strip_accents(string.lower(arg))
        local exact = PLAYER_NAME_INDEX[lower_arg]
        if exact then return exact.playerid end
        local best_id = nil
        local best_score = 0
        for pid, entry in pairs(PLAYER_CACHE) do
            local lower_pname = strip_accents(string.lower(entry.name))
            if string.find(lower_pname, lower_arg, 1, true) then
                return pid
            end
            local score = 0
            if #lower_arg > 0 and #lower_pname > 0 then
                score = #lower_arg / #lower_pname
            end
            if score > best_score then
                best_score = score
                best_id = pid
            end
        end
        if best_score >= 0.5 then
            return best_id
        end
    end
    return nil
end

-- Validate that a database table exists
local function check_table_exists(table_name)
    if not (LE and LE.db and LE.db.GetTable) then
        return false, "Live Editor v2 database API not available"
    end
    local ok, table_obj = pcall(function() return LE.db:GetTable(table_name) end)
    if not ok or not table_obj then
        return false, "Table not found: " .. tostring(table_name)
    end
    return true, table_obj
end

-- Helper to convert DBRow to plain table
local function row_to_plain(row)
    local t = {}
    for k, v in pairs(row) do
        if type(v) == "table" and v.value ~= nil then
            t[k] = v.value
        end
    end
    return t
end

local handlers = {}

function handlers.ping(cmd)
    return { success = true, message = "Live Editor bridge is running" }
end

function handlers.rebuild_caches(cmd)
    build_caches()
    return { success = true, players = #PLAYER_CACHE, teams = #TEAM_CACHE }
end

function handlers.list_clubs(cmd)
    local ok, rows = pcall(GetDBTableRows, "teams")
    if not ok or not rows then
        return { success = false, error = "Could not read teams table" }
    end
    local clubs = {}
    local limit = cmd.limit or 100
    for i, row in ipairs(rows) do
        if i > limit then break end
        table.insert(clubs, {
            teamid = tonumber(row.teamid.value),
            teamname = safe_name(row.teamname and row.teamname.value),
            abbreviation = safe_name(row.teamabbreviation and row.teamabbreviation.value)
        })
    end
    return { success = true, clubs = clubs, count = #clubs, limit = limit }
end

function handlers.search_players(cmd)
    local name = cmd.name or ""
    if name == "" then return { success = false, error = "name required" } end
    ensure_cache_loaded()
    local limit = cmd.limit or 20
    local lower_name = strip_accents(string.lower(name))
    local results = {}
    local exact = PLAYER_NAME_INDEX[lower_name]
    if exact then
        table.insert(results, { playerid = exact.playerid, name = exact.name, overallrating = exact.overallrating })
    end
    for pid, entry in pairs(PLAYER_CACHE) do
        local skip = exact and pid == exact.playerid
        if not skip then
            if string.find(strip_accents(string.lower(entry.name)), lower_name, 1, true) then
                table.insert(results, { playerid = pid, name = entry.name, overallrating = entry.overallrating })
                if #results >= limit then break end
            end
        end
    end
    return { success = true, players = results, count = #results }
end

function handlers.list_team_players(cmd)
    local teamid = cmd.teamid or normalize_team_arg(cmd.team)
    if not teamid then return { success = false, error = "team or teamid required" } end
    local ok, rows = pcall(GetDBTableRows, "teamplayerlinks")
    if not ok or not rows then
        return { success = false, error = "Could not read teamplayerlinks table" }
    end
    local results = {}
    for _, row in ipairs(rows) do
        if tonumber(row.teamid.value) == teamid then
            local pid = tonumber(row.playerid.value)
            table.insert(results, {
                playerid = pid,
                name = safe_name(GetPlayerName(pid)),
                teamid = teamid,
                teamname = safe_name(GetTeamName(teamid))
            })
        end
    end
    return { success = true, teamid = teamid, teamname = safe_name(GetTeamName(teamid)), players = results, count = #results }
end

function handlers.get_player_club(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then
        return { success = false, error = "Player not found" }
    end
    local teamid = GetTeamIdFromPlayerId(playerid)
    local teamname = safe_name(GetTeamName(teamid))
    local playername = safe_name(GetPlayerName(playerid))
    return { success = true, playerid = playerid, name = playername, teamid = teamid, teamname = teamname }
end

function handlers.transfer_player(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then
        return { success = false, error = "Player not found" }
    end
    local to_teamid = normalize_team_arg(cmd.new_club or cmd.new_teamid)
    if not to_teamid then
        return { success = false, error = "Target club not found" }
    end
    if IsPlayerPresigned(playerid) then DeletePresignedContract(playerid) end
    if IsPlayerLoanedOut(playerid) then TerminateLoan(playerid) end
    TransferPlayer(playerid, to_teamid, cmd.transfersum or 0, cmd.wage or 0, cmd.contract_length or 60, cmd.from_teamid or 0, cmd.release_clause or -1)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), new_teamid = to_teamid, new_club_name = safe_name(GetTeamName(to_teamid)) }
end

function handlers.loan_player(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    local to_teamid = normalize_team_arg(cmd.new_club or cmd.new_teamid)
    if not to_teamid then return { success = false, error = "Target club not found" } end
    LoanPlayer(playerid, to_teamid, cmd.length or 12, cmd.loantobuy or -1)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), new_teamid = to_teamid, new_club_name = safe_name(GetTeamName(to_teamid)) }
end

function handlers.release_player(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    ReleasePlayerFromTeam(playerid)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)) }
end

function handlers.terminate_loan(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    TerminateLoan(playerid)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)) }
end

function handlers.add_to_transfer_list(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    AddPlayerToTransferList(playerid, cmd.teamid or 0)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)) }
end

function handlers.add_to_loan_list(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    AddPlayerToLoanList(playerid, cmd.teamid or 0)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)) }
end

function handlers.remove_from_lists(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    RemovePlayerFromLists(playerid, cmd.teamid or 0)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)) }
end

function handlers.is_transfer_listed(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    return { success = true, playerid = playerid, listed = IsPlayerTransferListed(playerid, cmd.teamid or 0) }
end

function handlers.is_loan_listed(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    return { success = true, playerid = playerid, listed = IsPlayerLoanListed(playerid, cmd.teamid or 0) }
end

function handlers.set_player_sharpness(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    if cmd.value == nil then return { success = false, error = "value required" } end
    SetPlayerSharpness(playerid, cmd.value)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), sharpness = cmd.value }
end

function handlers.set_player_morale(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    if cmd.value == nil then return { success = false, error = "value required" } end
    SetPlayerMorale(playerid, cmd.value)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), morale = cmd.value }
end

function handlers.set_player_form(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    if cmd.value == nil then return { success = false, error = "value required" } end
    SetPlayerForm(playerid, cmd.value)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), form = cmd.value }
end

function handlers.set_player_fitness(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    if cmd.value == nil then return { success = false, error = "value required" } end
    SetPlayerFitness(playerid, cmd.value)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), fitness = cmd.value }
end

function handlers.get_transfer_budget(cmd)
    return { success = true, budget = GetTransferBudget() }
end

function handlers.set_transfer_budget(cmd)
    SetTransferBudget(cmd.value)
    return { success = true, budget = GetTransferBudget() }
end

function handlers.get_db_tables(cmd)
    return { success = true, tables = GetDBTablesNames() }
end

function handlers.get_db_fields(cmd)
    local table_name = cmd.table
    if not table_name then return { success = false, error = "table required" } end
    local ok, fields_or_obj = pcall(GetDBTableFields, table_name)
    if not ok then
        return { success = false, error = "Table not found or not accessible: " .. tostring(table_name) }
    end
    local fields = fields_or_obj
    local out = {}
    for _, f in ipairs(fields) do
        table.insert(out, { name = f.name, type = f.type, depth = f.depth, rangelow = f.rangelow })
    end
    return { success = true, table = table_name, fields = out, count = #out }
end

function handlers.get_db_rows(cmd)
    local table_name = cmd.table
    if not table_name then return { success = false, error = "table required" } end
    local ok, rows = pcall(GetDBTableRows, table_name)
    if not ok or not rows then
        return { success = false, error = "Table not found or not accessible: " .. tostring(table_name) }
    end
    local out = {}
    local limit = cmd.limit or 50
    for i, row in ipairs(rows) do
        if i > limit then break end
        table.insert(out, row_to_plain(row))
    end
    return { success = true, table = table_name, rows = out, count = #out, total = #rows }
end

function handlers.edit_db_field(cmd)
    local table_name = cmd.table
    if not table_name then return { success = false, error = "table required" } end
    local match_field = cmd.match_field or "playerid"
    if cmd.match_value == nil then return { success = false, error = "match_value required" } end
    local field_name = cmd.field
    if not field_name then return { success = false, error = "field required" } end

    local ok, table_obj = check_table_exists(table_name)
    if not ok then return { success = false, error = table_obj } end

    local record = table_obj:GetFirstRecord()
    local found = false
    while record > 0 do
        local record_value = table_obj:GetRecordFieldValue(record, match_field)
        if tostring(record_value) == tostring(cmd.match_value) then
            table_obj:SetRecordFieldValue(record, field_name, cmd.value)
            found = true
            break
        end
        record = table_obj:GetNextValidRecord()
    end

    if not found then
        return { success = false, error = "Row not found in " .. table_name }
    end
    return { success = true, table = table_name, field = field_name, value = cmd.value }
end

function handlers.insert_db_row(cmd)
    local table_name = cmd.table
    if not table_name then return { success = false, error = "table required" } end
    local row_data = cmd.row or {}
    for k, v in pairs(row_data) do
        row_data[k] = tostring(v)
    end

    local ok, table_obj = check_table_exists(table_name)
    if not ok then return { success = false, error = table_obj } end

    -- Try v2 API first
    if table_obj.InsertRecord or table_obj.AddRecord then
        local ok2, result = pcall(function()
            if table_obj.InsertRecord then
                return table_obj:InsertRecord(row_data)
            elseif table_obj.AddRecord then
                return table_obj:AddRecord(row_data)
            end
            return nil
        end)
        if ok2 and result then
            return { success = true, table = table_name, row = row_to_plain(result) }
        end
    end

    -- Fall back to v1 API
    local ok3, row = pcall(InsertDBTableRow, table_name, row_data)
    if not ok3 then
        return { success = false, error = "Insert failed: " .. tostring(row) }
    end
    return { success = true, table = table_name, row = row_to_plain(row) }
end

function handlers.delete_db_row(cmd)
    local table_name = cmd.table
    if not table_name then return { success = false, error = "table required" } end
    local target = cmd.row or {}
    if not next(target) then return { success = false, error = "row filter required" } end

    local ok, table_obj = check_table_exists(table_name)
    if not ok then return { success = false, error = table_obj } end

    local record = table_obj:GetFirstRecord()
    local found = false
    while record > 0 do
        local match = true
        for k, v in pairs(target) do
            local record_value = table_obj:GetRecordFieldValue(record, k)
            if tostring(record_value) ~= tostring(v) then
                match = false
                break
            end
        end
        if match then
            if table_obj.DeleteRecord then
                table_obj:DeleteRecord(record)
            elseif table_obj.RemoveRecord then
                table_obj:RemoveRecord(record)
            else
                return { success = false, error = "DeleteRecord/RemoveRecord not available" }
            end
            found = true
            break
        end
        record = table_obj:GetNextValidRecord()
    end

    if not found then
        return { success = false, error = "Row not found in " .. table_name }
    end
    return { success = true, table = table_name }
end

function handlers.get_players_stats(cmd)
    local stats = GetPlayersStats()
    local limit = cmd.limit or 50
    local out = {}
    for i, s in ipairs(stats) do
        if i > limit then break end
        table.insert(out, s)
    end
    return { success = true, stats = out, count = #out, total = #stats }
end

function handlers.get_player_stats(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    local stats = GetPlayerStats(playerid)
    return { success = true, playerid = playerid, stats = stats }
end

function handlers.execute_lua(cmd)
    local code = cmd.code
    if not code then return { success = false, error = "code required" } end
    local chunk, err = load(code, "=bridge_execute", "t", _G)
    if not chunk then
        return { success = false, error = err }
    end
    local ok, result = pcall(chunk)
    if not ok then
        return { success = false, error = tostring(result) }
    end
    local MAX_RESULT_LEN = 50000
    if type(result) == "table" then
        result = json.encode(result)
    else
        result = tostring(result)
    end
    if #result > MAX_RESULT_LEN then
        result = result:sub(1, MAX_RESULT_LEN) .. "\n...[truncated]"
    end
    return { success = true, result = result }
end

local function process_file(path, id)
    local f = io.open(path, "r")
    if not f then
        log("Could not open " .. path)
        return
    end
    local content = f:read("*a")
    f:close()

    local ok, cmd = pcall(json.decode, content)
    if not ok or type(cmd) ~= "table" then
        write_result(id, { success = false, error = "Invalid JSON command" })
        os.remove(path)
        return
    end

    local handler = handlers[cmd.method]
    if not handler then
        write_result(id, { success = false, error = "Unknown method: " .. tostring(cmd.method) })
        os.remove(path)
        return
    end

    log("Executing: " .. tostring(cmd.method))
    local ok2, result = pcall(handler, cmd.arguments or {})
    if not ok2 then
        log("Handler error: " .. tostring(result))
        write_result(id, { success = false, error = tostring(result) })
    else
        write_result(id, result)
    end
    os.remove(path)
end

local function poll_once()
    local queue_path = IN_DIR .. "/_queue.txt"
    local proc_path = IN_DIR .. "/_queue.proc"

    -- Atomically move queue to a processing file so the Python side can keep appending safely
    local ok = os.rename(queue_path, proc_path)
    if not ok then return end

    local q = io.open(proc_path, "r")
    if not q then return end
    for line in q:lines() do
        local id = line:match("^%s*(%S+)%s*$")
        if id then
            local cmd_path = IN_DIR .. "/" .. id .. ".json"
            process_file(cmd_path, id)
        end
    end
    q:close()
    os.remove(proc_path)
end

_G.fc26_handlers = handlers

log("Full MCP bridge started. Polling " .. IN_DIR)

while true do
    poll_once()
    if Sleep then
        Sleep(100)
    else
        -- Fallback busy-wait if Sleep() is not available
        local start = os.clock()
        while os.clock() - start < 0.1 do end
    end
end
