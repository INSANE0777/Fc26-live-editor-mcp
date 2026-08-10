-- probe_transfer1.lua -- ONE transfer attempt with vector count logged before/after
local LOG_PATH = "C:/fc26-mcp/probe_transfer1_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

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

local function VectorInfo()
    local psm = GetManagerObjByTypeId(89)
    if not (psm and psm > 0) then return "psm=0" end
    local _start = MEMORY:ReadPointer(psm + 0x18)
    local _end = MEMORY:ReadPointer(psm + 0x20)
    if not (_start and _end) then return "vec=nil" end
    local slots = (_end - _start) / 8
    local real = 0
    local cur = _start
    for i = 1, slots do
        if MEMORY:ReadInt(cur + 0x0) > 0 then real = real + 1 end
        cur = cur + 8
    end
    return "slots=" .. slots .. " real=" .. real
end

function main()
    log("== PROBE+TRANSFER1 START ==")
    log("before: " .. VectorInfo())
    local pid = 278339  -- Palestra
    local from = 111592
    log("transferring pid=" .. pid .. " from=" .. from .. " to=5 wage=30000 months=36")
    local ok = pcall(cTransferPlayer, pid, from, 5, 0, -1, 30000, 36)
    log("pcall=" .. tostring(ok))
    log("after:  " .. VectorInfo())
    local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)
    log("Palestra team now=" .. tostring(cur2))
    log("== PROBE+TRANSFER1 DONE ==")
end

main()
