-- verify_transfer.lua -- transfer if needed, then VERIFY actual team via GetTeamIdFromPlayerId
local LOG_PATH = "C:/fc26-mcp/verify_transfer_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local TRANSFERS = {
    { name = 'Marco Palestra', pid = 278339, wage = 30000, months = 36 },
    { name = 'Morgan Rogers', pid = 260247, wage = 110000, months = 48 },
    { name = 'Maxence Lacroix', pid = 244067, wage = 68000, months = 36 },
    { name = 'Danny Welbeck', pid = 186146, wage = 68000, months = 36 },
    { name = 'Jordan Henderson', pid = 183711, wage = 53000, months = 36 },
    { name = 'Valentín Barco', pid = 263370, wage = 53000, months = 48 },
}

function main()
    log("== VERIFY/TRANSFER START ==")
    for _, ent in ipairs(TRANSFERS) do
        local pid = ent.pid
        local ok0, cur = pcall(GetTeamIdFromPlayerId, pid)
        log(ent.name .. " pid=" .. pid .. " BEFORE team=" .. tostring(cur) .. " (ok=" .. tostring(ok0) .. ")")
        if ok0 and cur == 5 then
            log("  already at Chelsea, skip transfer")
        else
            local okp, p2 = pcall(IsPlayerPresigned, pid)
            if okp and p2 then pcall(DeletePresignedContract, pid) end
            local okl, l2 = pcall(IsPlayerLoanedOut, pid)
            if okl and l2 then pcall(TerminateLoan, pid) end
            -- from = their CURRENT team (whatever it is right now)
            local from = (ok0 and cur and cur > 0) and cur or 111592
            local ok = pcall(cTransferPlayer, pid, from, 5, 0, -1, ent.wage, ent.months)
            log("  cTransferPlayer(from=" .. from .. ") pcall=" .. tostring(ok))
        end
        local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)
        local tn = ""
        if ok2 and cur2 and cur2 > 0 then
            local o3, n3 = pcall(GetTeamName, cur2)
            tn = tostring(n3 or "")
        end
        log(ent.name .. " AFTER team=" .. tostring(cur2) .. " [" .. tn .. "]")
        if ok2 and cur2 == 5 then
            log("  RESULT: SUCCESS at Chelsea")
        else
            log("  RESULT: NOT at Chelsea (cur=" .. tostring(cur2) .. ")")
        end
    end
    log("== VERIFY/TRANSFER DONE ==")
end

main()
