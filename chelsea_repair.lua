-- chelsea_repair.lua — native cTransferPlayer + PlayerStatusManager writes
-- Wage: full weekly wage. cTransferPlayer(pid, from_teamid, to_teamid, transfersum, release_clause, wage, contract_length_in_months)
local LOG_PATH = "C:/fc26-mcp/chelsea_repair_log.txt"
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n") f:close() end
end

-- Inlined v2 helpers: WriteSquadRoleToPlayerStatusManager (SetSquadRole)
local function GetManagerObjByTypeId(type_id)
    local result = 0
    local comm_impl = GetPlugin(0x1297f047) -- ENUM_djb2FeFceGMCommServiceInterface_CLSS
    if (comm_impl <= 0) then return 0 end
    local mode_managers = MEMORY:ReadMultilevelPointer(comm_impl, {0x20, 0x10})
    local mode_manager = mode_managers + (0x20 * type_id)
    if (MEMORY:ReadInt(mode_manager + 0x10) ~= 1) then return 0 end
    local mode_manager_type = MEMORY:ReadPointer(mode_manager + 0x8)
    if (MEMORY:ReadInt(mode_manager_type + 0x10) ~= 1) then return 0 end
    result = MEMORY:ReadMultilevelPointer(mode_manager, {0x18, 0x0})
    return result
end

local function SetSquadRole(playerid, role)
    -- ENUM_FCEGameModesFCECareerModePlayerStatusManager = 89 (from enums.lua)
    local player_status_mgr = GetManagerObjByTypeId(89)
    local PLAYERROLE_STRUCT = { mPlayerID = 0x0, mRole = 0x4, mSize = 0x8 }
    local _start = MEMORY:ReadPointer(player_status_mgr + 0x18)
    local _end = MEMORY:ReadPointer(player_status_mgr + 0x20)
    if (not _start) or (not _end) then return false end
    local current_addr = _start
    for i=1, 55 do
        if current_addr >= _end then return false end
        if (playerid == MEMORY:ReadInt(current_addr + PLAYERROLE_STRUCT.mPlayerID)) then
            MEMORY:WriteInt(current_addr + PLAYERROLE_STRUCT.mRole, role)
            return true
        end
        current_addr = current_addr + PLAYERROLE_STRUCT.mSize
    end
    return false
end

local TRANSFERS = {
    { name = 'Marco Palestra', pid = 278339, from_tid = 115845, tid = 5, wage = 30000, months = 36 },
    { name = 'Morgan Rogers', pid = 260247, from_tid = 2, tid = 5, wage = 110000, months = 48 },
    { name = 'Maxence Lacroix', pid = 244067, from_tid = 1799, tid = 5, wage = 68000, months = 36 },
    { name = 'Danny Welbeck', pid = 186146, from_tid = 1808, tid = 5, wage = 68000, months = 36 },
    { name = 'Jordan Henderson', pid = 183711, from_tid = 111592, tid = 5, wage = 53000, months = 36 },
    { name = 'Valentín Barco', pid = 263370, from_tid = 76, tid = 5, wage = 53000, months = 48 },
}

function main()
    log("== CHELSEA REPAIR START ==")
    for _, ent in ipairs(TRANSFERS) do
        local pid, tid = ent.pid, ent.tid
        log(ent.name .. " pid=" .. pid .. " from=" .. ent.from_tid .. " -> " .. tid .. " wage=" .. ent.wage .. " months=" .. ent.months)

        local okp, presigned = pcall(IsPlayerPresigned, pid)
        if okp and presigned then pcall(DeletePresignedContract, pid) end
        local okl, loaned = pcall(IsPlayerLoanedOut, pid)
        if okl and loaned then pcall(TerminateLoan, pid) end

        local ok = pcall(cTransferPlayer, pid, ent.from_tid, tid, 0, -1, ent.wage, ent.months)
        log("cTransferPlayer -> " .. tostring(ok))
        if not ok then
            log("  !! FAILED for " .. ent.name)
        end

        local okr = SetSquadRole(pid, 3)
        local okm = pcall(SetPlayerMorale, pid, 75)
        local oks = pcall(SetPlayerSharpness, pid, 60)
        local okf = pcall(SetPlayerFitness, pid, 85)
        log("status -> role=" .. tostring(okr) .. " morale=" .. tostring(okm) .. " sharp=" .. tostring(oks) .. " fit=" .. tostring(okf))
        log(ent.name .. " DONE")
    end
    log("== CHELSEA REPAIR DONE ==")
end

main()
