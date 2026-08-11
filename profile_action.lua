-- profile_action.lua -- NATIVE loan (idempotent)
-- log helper
local LOG = "C:/fc26-mcp/sidecar_actions_log.txt"
local function log(m) local f = io.open(LOG, 'a') if f then f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. m .. string.char(10)) f:close() end end
local pid, tid = 20801, 5
log('LOAN start pid=' .. pid .. ' tid=' .. tid)
local ok0, cur = pcall(GetTeamIdFromPlayerId, pid)
if ok0 and cur == tid then
    log('LOAN ' .. "Cristiano Ronaldo" .. ' already at ' .. tid .. ', skip')
else
    local okl, loaned = pcall(IsPlayerLoanedOut, pid)
    if okl and loaned then pcall(TerminateLoan, pid) end
    local from = (ok0 and cur and cur > 0) and cur or 0
    pcall(cLoanPlayer, pid, from, tid, 36, 0)
    local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)
    local ol, lo = pcall(IsPlayerLoanedOut, pid)
    local res = (ol and lo) and 'OK-loan' or '??'
    log('LOAN ' .. "Cristiano Ronaldo" .. ' pid=' .. pid .. ' -> ' .. tid .. ' [' .. res .. '] after=' .. tostring(cur2) .. ' loaned=' .. tostring(lo) .. ' pcall=' .. tostring(ok2))
end
log('ACTION DONE')
