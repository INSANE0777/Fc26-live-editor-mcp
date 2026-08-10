-- probe_squad.lua -- dump what the squad-full guard actually counts
local LOG_PATH = "C:/fc26-mcp/probe_squad_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

-- copy of inlined GetManagerObjByTypeId (type 89 = PlayerStatusManager)
local function GetManagerObjByTypeId(type_id)
    local result = 0
    local comm_impl = GetPlugin(0x1297f047)
    if (comm_impl <= 0) then return 0 end
    local mode_managers = MEMORY:ReadMultilevelPointer(comm_impl, {0x20, 0x10})
    local mode_manager = mode_managers + (0x20 * type_id)
    if (MEMORY:ReadInt(mode_manager + 0x10) ~= 1) then return 0 end
    local mode_manager_type = MEMORY:ReadPointer(mode_manager + 0x8)
    if (MEMORY:ReadInt(mode_manager_type + 0x10) ~= 1) then return 0 end
    result = MEMORY:ReadMultilevelPointer(mode_manager, {0x18, 0x0})
    return result
end

function main()
    log("== PROBE START ==")
    -- 1) PlayerStatusManager vector: entries = in-squad? count + ids + roles
    local psm = GetManagerObjByTypeId(89)
    log("PlayerStatusManager ptr=" .. tostring(psm))
    if psm and psm > 0 then
        local _start = MEMORY:ReadPointer(psm + 0x18)
        local _end = MEMORY:ReadPointer(psm + 0x20)
        log("vector start=" .. tostring(_start) .. " end=" .. tostring(_end))
        if _start and _end then
            local count = (_end - _start) / 8
            log("IN-SQUAD (status mgr) COUNT=" .. count)
            local cur = _start
            for i = 1, count do
                local pid = MEMORY:ReadInt(cur + 0x0)
                local role = MEMORY:ReadInt(cur + 0x4)
                local nm = ""
                local ok, n = pcall(GetPlayerName, pid)
                if ok then nm = tostring(n or "") end
                log("  [" .. i .. "] pid=" .. pid .. " role=" .. role .. " " .. nm)
                cur = cur + 8
            end
        end
    end
    -- 2) teamplayerlinks count for Chelsea (raw DB)
    local tpl = LE.db:GetTable("teamplayerlinks")
    local c = 0
    local r = tpl:GetFirstRecord()
    while r > 0 do
        if tpl:GetRecordFieldValue(r, "teamid") == 5 and tpl:GetRecordFieldValue(r, "artificialkey") > 0 then c = c + 1 end
        r = tpl:GetNextValidRecord()
    end
    log("teamplayerlinks teamid=5 rows=" .. c)
    -- 3) career_playercontract teamid=5
    local cpc = LE.db:GetTable("career_playercontract")
    local c2 = 0
    local r2 = cpc:GetFirstRecord()
    while r2 > 0 do
        if cpc:GetRecordFieldValue(r2, "teamid") == 5 then c2 = c2 + 1 end
        r2 = cpc:GetNextValidRecord()
    end
    log("career_playercontract teamid=5 rows=" .. c2)
    log("== PROBE DONE ==")
end

main()
