-- profile_action.lua -- NATIVE transfer (idempotent)
-- log helper
local LOG = "C:/fc26-mcp/sidecar_actions_log.txt"
local function log(m) local f = io.open(LOG, 'a') if f then f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. m .. string.char(10)) f:close() end end
local pid, tid = 70145, 1
log('TRANSFER start pid=' .. pid .. ' tid=' .. tid)
local ok0, cur = pcall(GetTeamIdFromPlayerId, pid)
if ok0 and cur == tid then
    log('TRANSFER ' .. "Momoko Tanikawa" .. ' already at ' .. tid .. ', skip')
else
    local okl, loaned = pcall(IsPlayerLoanedOut, pid)
    if okl and loaned then pcall(TerminateLoan, pid) end
    local from = (ok0 and cur and cur > 0) and cur or 0
    pcall(cTransferPlayer, pid, from, tid, 0, -1, 40000, 36)
    local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)
    local res = (ok2 and cur2 == tid) and 'OK' or 'FAIL'
    log('TRANSFER ' .. "Momoko Tanikawa" .. ' pid=' .. pid .. ' -> ' .. tid .. ' [' .. res .. '] after=' .. tostring(cur2) .. ' pcall=' .. tostring(ok2))
end
log('ACTION DONE')
