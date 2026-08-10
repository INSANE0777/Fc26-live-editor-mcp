-- free_then_transfer.lua -- release 6 lowest-rated Chelsea in-squad players (skip loaned), then transfer the 6 targets in, VERIFY after each
local LOG_PATH = "C:/fc26-mcp/free_transfer_log.txt"
local NL = string.char(10)
local CHELSEA, FREE = 5, 111592
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

-- 1) collect Chelsea squad ids + OVR from live DB
local function GetChelseaSquadWithOvr()
    local out = {}
    local tpl = LE.db:GetTable("teamplayerlinks")
    local tbl_players = LE.db:GetTable("players")
    local ovr = {}
    local r = tbl_players:GetFirstRecord()
    while r > 0 do
        ovr[tbl_players:GetRecordFieldValue(r, "playerid")] = tbl_players:GetRecordFieldValue(r, "overallrating")
        r = tbl_players:GetNextValidRecord()
    end
    r = tpl:GetFirstRecord()
    while r > 0 do
        local tid = tpl:GetRecordFieldValue(r, "teamid")
        local artificialkey = tpl:GetRecordFieldValue(r, "artificialkey")
        if tid == CHELSEA and artificialkey > 0 then
            local pid = tpl:GetRecordFieldValue(r, "playerid")
            out[#out + 1] = { pid = pid, ovr = ovr[pid] or -1 }
        end
        r = tpl:GetNextValidRecord()
    end
    return out
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
    log("== FREE+TRANSFER START ==")
    -- pick 6 lowest OVR not loaned out
    local squad = GetChelseaSquadWithOvr()
    log("Chelsea in-squad rows: " .. #squad)
    local elig = {}
    for i = 1, #squad do
        local e = squad[i]
        local okl, loaned = pcall(IsPlayerLoanedOut, e.pid)
        if not (okl and loaned) then elig[#elig + 1] = e end
    end
    table.sort(elig, function(a, b) return a.ovr < b.ovr end)
    local release_count = math.min(6, #elig)
    log("eligible non-loaned: " .. #elig .. ", will release " .. release_count)
    local released = {}
    for i = 1, release_count do
        local e = elig[i]
        local name = pcall(GetPlayerName, e.pid) and select(2, pcall(GetPlayerName, e.pid)) or "?"
        local ok = pcall(ReleasePlayerFromTeam, e.pid)
        log("RELEASE pid=" .. e.pid .. " ovr=" .. e.ovr .. " " .. tostring(name) .. " -> " .. tostring(ok))
        released[#released + 1] = e.pid
    end
    pcall(os.execute, "timeout /t 1 /nobreak > nul")  -- small settle pause
    -- 2) now transfer the 6 targets in, with verification
    for _, ent in ipairs(TRANSFERS) do
        local pid = ent.pid
        local ok0, cur = pcall(GetTeamIdFromPlayerId, pid)
        log(ent.name .. " pid=" .. pid .. " BEFORE team=" .. tostring(cur))
        local okp, p2 = pcall(IsPlayerPresigned, pid)
        if okp and p2 then pcall(DeletePresignedContract, pid) end
        local okl, l2 = pcall(IsPlayerLoanedOut, pid)
        if okl and l2 then pcall(TerminateLoan, pid) end
        local from = (ok0 and cur and cur > 0) and cur or FREE
        local ok = pcall(cTransferPlayer, pid, from, CHELSEA, 0, -1, ent.wage, ent.months)
        log("  cTransferPlayer(from=" .. from .. ") pcall=" .. tostring(ok))
        local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)
        local tn = ""
        if ok2 and cur2 and cur2 > 0 then local o3, n3 = pcall(GetTeamName, cur2) tn = tostring(n3 or "") end
        log(ent.name .. " AFTER team=" .. tostring(cur2) .. " [" .. tn .. "]")
        if ok2 and cur2 == CHELSEA then log("  RESULT: SUCCESS at Chelsea") else log("  RESULT: NOT at Chelsea") end
        pcall(os.execute, "timeout /t 1 /nobreak > nul")
    end
    log("== FREE+TRANSFER DONE ==")
end

main()
