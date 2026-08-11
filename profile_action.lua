-- profile_action.lua -- Release to free agents (native, idempotent)
-- log helper
local LOG = "C:/fc26-mcp/sidecar_actions_log.txt"
local function log(m) local f = io.open(LOG, 'a') if f then f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. m .. string.char(10)) f:close() end end
local pid = 277846
log('RELEASE start pid=' .. pid)
local ok, cur = pcall(GetTeamIdFromPlayerId, pid)
if ok and cur and cur > 0 and cur ~= 111592 then
    pcall(cTransferPlayer, pid, cur, 111592, 0, -1, 88000, 36)
    local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)
    local res = (ok2 and cur2 == 111592) and 'OK' or 'FAIL'
    log('RELEASE ' .. "Nico Paz" .. ' pid=' .. pid .. ' res=' .. res .. ' after=' .. tostring(cur2) .. ' pcall=' .. tostring(ok2))
else
    log('RELEASE ' .. "Nico Paz" .. ' already free, skip')
end
log('ACTION DONE')
