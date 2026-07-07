from pathlib import Path

p = Path("C:/fc26-mcp/src/fc26_mcp/le_bridge.lua")
text = p.read_text(encoding="utf-8")

# Add CACHE_DIR
old = '''local IN_DIR  = BRIDGE_ROOT .. "/in"
local OUT_DIR = BRIDGE_ROOT .. "/out"
local LOG_DIR = BRIDGE_ROOT .. "/logs"'''
new = '''local IN_DIR  = BRIDGE_ROOT .. "/in"
local OUT_DIR = BRIDGE_ROOT .. "/out"
local LOG_DIR = BRIDGE_ROOT .. "/logs"
local CACHE_DIR = BRIDGE_ROOT .. "/cache"'''
text = text.replace(old, new)

# Add cache globals and functions before strip_accents
old2 = '''local function strip_accents(str)'''
new2 = '''-- Persistent name caches (loaded from disk, rebuilt on first use if missing)
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

local function strip_accents(str)'''
text = text.replace(old2, new2, 1)

# normalize_player_arg
old_norm_player = '''local function normalize_player_arg(arg)
    if type(arg) == "number" then return arg end
    if type(arg) == "string" then
        local n = tonumber(arg)
        if n then return n end
        local lower_arg = strip_accents(string.lower(arg))
        local rows = GetDBTableRows("players") or {}
        local best_id = nil
        local best_score = 0
        for _, row in ipairs(rows) do
            local pid = tonumber(row.playerid.value)
            local pname = safe_name(GetPlayerName(pid))
            local lower_pname = strip_accents(string.lower(pname))
            if string.find(lower_pname, lower_arg, 1, true) then
                return pid
            end
            -- simple length ratio fallback (exact names often same length)
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
end'''
new_norm_player = '''local function normalize_player_arg(arg)
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
end'''
text = text.replace(old_norm_player, new_norm_player)

# normalize_team_arg
old_norm_team = '''local function normalize_team_arg(arg)
    if type(arg) == "number" then return arg end
    if type(arg) == "string" then
        local n = tonumber(arg)
        if n then return n end
        local lower_arg = strip_accents(string.lower(arg))
        local rows = GetDBTableRows("teams") or {}
        for _, row in ipairs(rows) do
            local tid = tonumber(row.teamid.value)
            local tname = safe_name(row.teamname and row.teamname.value)
            local abbr = safe_name(row.teamabbreviation and row.teamabbreviation.value)
            local lower_name = strip_accents(string.lower(tname))
            local lower_abbr = strip_accents(string.lower(abbr))
            if lower_name == lower_arg or lower_abbr == lower_arg then
                return tid
            end
            if string.find(lower_name, lower_arg, 1, true) or string.find(lower_abbr, lower_arg, 1, true) then
                return tid
            end
        end
    end
    return nil
end'''
new_norm_team = '''local function normalize_team_arg(arg)
    if type(arg) == "number" then return arg end
    if type(arg) == "string" then
        local n = tonumber(arg)
        if n then return n end
        ensure_cache_loaded()
        local lower_arg = strip_accents(string.lower(arg))
        local exact = TEAM_NAME_INDEX[lower_arg]
        if exact then return exact.teamid end
        for tid, entry in pairs(TEAM_CACHE) do
            local lower_name = strip_accents(string.lower(entry.teamname))
            local lower_abbr = strip_accents(string.lower(entry.abbreviation))
            if lower_name == lower_arg or lower_abbr == lower_arg then
                return tid
            end
            if string.find(lower_name, lower_arg, 1, true) or string.find(lower_abbr, lower_arg, 1, true) then
                return tid
            end
        end
    end
    return nil
end'''
text = te
