-- diomande_rm.lua -- single clean transfer: Yan Diomande (78012) -> Real Madrid (243)
local LOG_PATH = "C:/fc26-mcp/diomande_rm_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local PID    = 78012    -- Yan Diomande
local FROM   = 112172   -- RB Leipzig
local TO     = 243      -- Real Madrid
local WAGE   = 68000    -- OVR 81 band
local MONTHS = 60       -- 5 years

function main()
    log("== DIOMANDE -> RM START ==")
    local name = "Yan Diomande"
    local ok0, cur = pcall(GetTeamIdFromPlayerId, PID)
    log(name .. " pid=" .. PID .. " BEFORE team=" .. tostring(cur))
    local okp, p2 = pcall(IsPlayerPresigned, PID)
    if okp and p2 then log("  clearing presigned"); pcall(DeletePresignedContract, PID) end
    local okl, l2 = pcall(IsPlayerLoanedOut, PID)
    if okl and l2 then log("  terminating loan"); pcall(TerminateLoan, PID) end
    local from = (ok0 and cur and cur > 0) and cur or FROM
    log("  cTransferPlayer(" .. PID .. ", " .. from .. ", " .. TO .. ", 0, -1, " .. WAGE .. ", " .. MONTHS .. ")")
    local ok = pcall(cTransferPlayer, PID, from, TO, 0, -1, WAGE, MONTHS)
    log("  pcall=" .. tostring(ok))
    local ok2, cur2 = pcall(GetTeamIdFromPlayerId, PID)
    local tn = ""
    if ok2 and cur2 and cur2 > 0 then local o3, n3 = pcall(GetTeamName, cur2) tn = tostring(n3 or "") end
    log(name .. " AFTER team=" .. tostring(cur2) .. " [" .. tn .. "]")
    if ok2 and cur2 == TO then log("  RESULT: SUCCESS at Real Madrid") else log("  RESULT: NOT at Real Madrid (cur=" .. tostring(cur2) .. ")") end
    log("== DIOMANDE -> RM DONE ==")
end

main()
