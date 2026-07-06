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

local function log(msg)
    local f = io.open(LOG_DIR .. "/bridge.log", "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
    Log("[MCP Bridge] " .. tostring(msg))
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

local function normalize_team_arg(arg)
    if type(arg) == "number" then return arg end
    if type(arg) == "string" then
        local n = tonumber(arg)
        if n then return n end
        local lower_arg = string.lower(arg)
        local rows = GetDBTableRows("teams")
        for _, row in ipairs(rows) do
            local name = safe_name(row.teamname and row.teamname.value)
            local abbr = safe_name(row.teamabbreviation and row.teamabbreviation.value)
            if string.lower(name) == lower_arg or string.lower(abbr) == lower_arg then
                return tonumber(row.teamid.value)
            end
        end
    end
    return nil
end

local function normalize_player_arg(arg)
    if type(arg) == "number" then return arg end
    if type(arg) == "string" then
        local n = tonumber(arg)
        if n then return n end
        local lower_arg = string.lower(arg)
        local rows = GetDBTableRows("players")
        local best_id = nil
        local best_score = 0
        for _, row in ipairs(rows) do
            local pid = tonumber(row.playerid.value)
            local pname = safe_name(GetPlayerName(pid))
            local lower_pname = string.lower(pname)
            if string.find(lower_pname, lower_arg, 1, true) then
                return pid
            end
            local matches = 0
            local max_len = math.max(#lower_arg, #lower_pname)
            for i = 1, max_len do
                if lower_arg:sub(i,i) == lower_pname:sub(i,i) then
                    matches = matches + 1
                end
            end
            local score = matches / max_len
            if score > best_score then
                best_score = score
                best_id = pid
            end
        end
        if best_score > 0.6 then
            return best_id
        end
    end
    return nil
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

function handlers.list_clubs(cmd)
    local rows = GetDBTableRows("teams")
    local clubs = {}
    for _, row in ipairs(rows) do
        table.insert(clubs, {
            teamid = tonumber(row.teamid.value),
            teamname = safe_name(row.teamname and row.teamname.value),
            abbreviation = safe_name(row.teamabbreviation and row.teamabbreviation.value)
        })
    end
    return { success = true, clubs = clubs, count = #clubs }
end

function handlers.search_players(cmd)
    local name = cmd.name or ""
    local limit = cmd.limit or 20
    local rows = GetDBTableRows("players")
    local results = {}
    for _, row in ipairs(rows) do
        local pid = tonumber(row.playerid.value)
        local pname = safe_name(GetPlayerName(pid))
        if string.find(string.lower(pname), string.lower(name), 1, true) then
            table.insert(results, {
                playerid = pid,
                name = pname,
                overallrating = tonumber(row.overallrating and row.overallrating.value or 0)
            })
            if #results >= limit then break end
        end
    end
    return { success = true, players = results, count = #results }
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
    SetPlayerSharpness(playerid, cmd.value)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), sharpness = cmd.value }
end

function handlers.set_player_morale(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    SetPlayerMorale(playerid, cmd.value)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), morale = cmd.value }
end

function handlers.set_player_form(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
    SetPlayerForm(playerid, cmd.value)
    return { success = true, playerid = playerid, name = safe_name(GetPlayerName(playerid)), form = cmd.value }
end

function handlers.set_player_fitness(cmd)
    local playerid = normalize_player_arg(cmd.player or cmd.playerid)
    if not playerid then return { success = false, error = "Player not found" } end
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
    local fields = GetDBTableFields(table_name)
    local out = {}
    for _, f in ipairs(fields) do
        table.insert(out, { name = f.name, type = f.type, depth = f.depth, rangelow = f.rangelow })
    end
    return { success = true, table = table_name, fields = out, count = #out }
end

function handlers.get_db_rows(cmd)
    local table_name = cmd.table
    if not table_name then return { success = false, error = "table required" } end
    local rows = GetDBTableRows(table_name)
    local out = {}
    local limit = cmd.limit or 1000
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

    -- Use Live Editor v2 database API
    if not (LE and LE.db and LE.db.GetTable) then
        return { success = false, error = "Live Editor v2 database API not available" }
    end

    local table_obj = LE.db:GetTable(table_name)
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

    -- Try v2 API first
    if LE and LE.db and LE.db.GetTable then
        local ok, result = pcall(function()
            local table_obj = LE.db:GetTable(table_name)
            if table_obj.InsertRecord then
                return table_obj:InsertRecord(row_data)
            elseif table_obj.AddRecord then
                return table_obj:AddRecord(row_data)
            end
            return nil
        end)
        if ok and result then
            return { success = true, table = table_name, row = row_to_plain(result) }
        end
    end

    -- Fall back to v1 API
    local row = InsertDBTableRow(table_name, row_data)
    return { success = true, table = table_name, row = row_to_plain(row) }
end

function handlers.delete_db_row(cmd)
    local table_name = cmd.table
    if not table_name then return { success = false, error = "table required" } end

    -- Use Live Editor v2 database API
    if not (LE and LE.db and LE.db.GetTable) then
        return { success = false, error = "Live Editor v2 database API not available" }
    end

    local target = cmd.row or {}
    local table_obj = LE.db:GetTable(table_name)
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
    local limit = cmd.limit or 200
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
    if type(result) == "table" then
        return { success = true, result = json.encode(result) }
    end
    return { success = true, result = tostring(result) }
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

log("Full MCP bridge started. Polling " .. IN_DIR)

while true do
    poll_once()
    if Sleep then
        Sleep(500)
    else
        local start = os.clock()
        while os.clock() - start < 0.5 do end
    end
end
