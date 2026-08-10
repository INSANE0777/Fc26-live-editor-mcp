-- native_transfers_part7.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Michael Frey", pid = 208159, tid = 230, kind = 'perm', wage = 16000, months = 36 },
    { n = "Daniel Bennie", pid = 276561, tid = 181, kind = 'loan', months = 10, buy = 0 },
    { n = "Malcolm Jeng", pid = 275153, tid = 1915, kind = 'loan', months = 11, buy = 0 },
    { n = "Robin van Cruijsen", pid = 80489, tid = 100646, kind = 'perm', wage = 9000, months = 36 },
    { n = "Mike Kleijn", pid = 271120, tid = 645, kind = 'loan', months = 11, buy = 0 },
    { n = "Sander Svendsen", pid = 215195, tid = 113459, kind = 'perm', wage = 9000, months = 36 },
    { n = "Teodor Berg Haltvik", pid = 248392, tid = 1447, kind = 'perm', wage = 7000, months = 36 },
    { n = "Roman Kvet", pid = 272872, tid = 305, kind = 'perm', wage = 16000, months = 36 },
    { n = "Rayan Bamba", pid = 71778, tid = 1739, kind = 'loan', months = 11, buy = 0 },
    { n = "Olwethu Makhanya", pid = 278688, tid = 86, kind = 'perm', wage = 7000, months = 36 },
    { n = "Daiki Hashioka", pid = 242006, tid = 23, kind = 'loan', months = 11, buy = 0 },
    { n = "Rares Burnete", pid = 277636, tid = 112494, kind = 'loan', months = 11, buy = 0 },
    { n = "Aritz Arambarri", pid = 254003, tid = 110069, kind = 'perm', wage = 12000, months = 36 },
    { n = "John Stones", pid = 203574, tid = 131682, kind = 'perm', wage = 88000, months = 36 },
    { n = "Juan Rodríguez", pid = 75896, tid = 111708, kind = 'perm', wage = 5500, months = 36 },
    { n = "Mateo García", pid = 245908, tid = 110396, kind = 'loan', months = 17, buy = 0 },
    { n = "Lucas Michal", pid = 70458, tid = 1750, kind = 'loan', months = 11, buy = 0 },
    { n = "Lovro Majer", pid = 244261, tid = 278, kind = 'perm', wage = 40000, months = 36 },
    { n = "Matías Moreno", pid = 276820, tid = 205, kind = 'loan', months = 11, buy = 0 },
    { n = "Callum Marshall", pid = 278101, tid = 1923, kind = 'perm', wage = 9000, months = 36 },
    { n = "William Fitzgerald", pid = 241582, tid = 306, kind = 'perm', wage = 4500, months = 36 },
    { n = "Marin Soticek", pid = 73582, tid = 263, kind = 'loan', months = 11, buy = 0 },
    { n = "Gustavo Sá", pid = 271057, tid = 280, kind = 'loan', months = 11, buy = 0 },
    { n = "Maxence Lacroix", pid = 244067, tid = 5, kind = 'perm', wage = 68000, months = 36 },
    { n = "Tyler Fredricson", pid = 269233, tid = 1862, kind = 'perm', wage = 7000, months = 36 },
    { n = "Robert Ljubicic", pid = 243525, tid = 252, kind = 'loan', months = 11, buy = 0 },
    { n = "Emiliano Amor", pid = 226170, tid = 1013, kind = 'perm', wage = 12000, months = 36 },
    { n = "Alexander Schwolow", pid = 202789, tid = 169, kind = 'perm', wage = 22000, months = 36 },
    { n = "Davide Veroli", pid = 276443, tid = 112494, kind = 'loan', months = 11, buy = 0 },
    { n = "Raphael Kofler", pid = 277872, tid = 1842, kind = 'loan', months = 11, buy = 0 },
    { n = "Italo", pid = 70419, tid = 1477, kind = 'loan', months = 11, buy = 0 },
    { n = "Kian Fitz-Jim", pid = 262218, tid = 54, kind = 'perm', wage = 22000, months = 36 },
    { n = "Federico Ravaglia", pid = 240657, tid = 1795, kind = 'perm', wage = 22000, months = 36 },
    { n = "Lukas Willen", pid = 268498, tid = 110746, kind = 'perm', wage = 5500, months = 36 },
    { n = "Saba Sazonov", pid = 278013, tid = 1860, kind = 'perm', wage = 22000, months = 36 },
    { n = "Emanuele Rao", pid = 80630, tid = 110738, kind = 'loan', months = 11, buy = 1 },
    { n = "Liam Cullen", pid = 233941, tid = 95, kind = 'perm', wage = 12000, months = 36 },
    { n = "Lautaro Morales", pid = 253012, tid = 111715, kind = 'loan', months = 11, buy = 0 },
    { n = "Federico Mancuello", pid = 214968, tid = 111019, kind = 'perm', wage = 12000, months = 36 },
    { n = "Ignacio Pussetto", pid = 219536, tid = 111711, kind = 'loan', months = 17, buy = 0 },
    { n = "Danilo Arboleda", pid = 227740, tid = 1013, kind = 'perm', wage = 12000, months = 36 },
    { n = "Abdelhamid Sabiri", pid = 237499, tid = 131174, kind = 'perm', wage = 22000, months = 36 },
    { n = "Simone Pafundi", pid = 271575, tid = 110908, kind = 'loan', months = 11, buy = 0 },
    { n = "Martín Payero", pid = 240970, tid = 1795, kind = 'perm', wage = 22000, months = 36 },
    { n = "Kieron Bowie", pid = 257104, tid = 111974, kind = 'loan', months = 11, buy = 0 },
    { n = "Samuele Mulattieri", pid = 243200, tid = 206, kind = 'loan', months = 11, buy = 0 },
    { n = "Olti Hyseni", pid = 73504, tid = 269, kind = 'perm', wage = 7000, months = 36 },
    { n = "Mario Mitaj", pid = 258147, tid = 110556, kind = 'loan', months = 11, buy = 0 },
    { n = "Mathew Ryan", pid = 199005, tid = 1853, kind = 'perm', wage = 53000, months = 36 },
    { n = "Jesse Bisiwu", pid = 55133, tid = 241, kind = 'perm', wage = 5500, months = 36 },
    { n = "Josh Maja", pid = 235161, tid = 1738, kind = 'perm', wage = 16000, months = 36 },
    { n = "Nampalys Mendy", pid = 198861, tid = 68, kind = 'perm', wage = 22000, months = 36 },
    { n = "Lucas Gómez", pid = 70680, tid = 110396, kind = 'loan', months = 17, buy = 0 },
    { n = "Tomás Pérez", pid = 276605, tid = 111710, kind = 'loan', months = 11, buy = 0 },
    { n = "Martín Río", pid = 76469, tid = 1013, kind = 'loan', months = 11, buy = 0 },
    { n = "Aidan Stokes", pid = 73858, tid = 1925, kind = 'loan', months = 11, buy = 0 },
    { n = "Janne Berner", pid = 78130, tid = 110501, kind = 'loan', months = 11, buy = 0 },
    { n = "Favour Fawunmi", pid = 77599, tid = 1920, kind = 'loan', months = 10, buy = 0 },
    { n = "Peter Kiedl", pid = 79942, tid = 27, kind = 'perm', wage = 5500, months = 36 },
    { n = "Meiko Wäschenbach", pid = 74004, tid = 1826, kind = 'perm', wage = 5500, months = 36 },
    { n = "Julian Brandt", pid = 212194, tid = 245, kind = 'perm', wage = 88000, months = 36 },
    { n = "Jesse Dempsey", pid = 274451, tid = 112260, kind = 'loan', months = 11, buy = 0 },
    { n = "Johnly Yfeko", pid = 277272, tid = 82, kind = 'perm', wage = 5500, months = 36 },
    { n = "Jonathan Meier", pid = 243514, tid = 82, kind = 'perm', wage = 7000, months = 36 },
    { n = "Lewis Montsma", pid = 257303, tid = 1928, kind = 'perm', wage = 7000, months = 36 },
    { n = "Jamie Knight-Lebel", pid = 277747, tid = 83, kind = 'loan', months = 10, buy = 0 },
    { n = "Chris Cadden", pid = 222109, tid = 77, kind = 'perm', wage = 9000, months = 36 },
    { n = "Jeremías Lucco", pid = 70688, tid = 111710, kind = 'loan', months = 17, buy = 0 },
}

function main()
    log("== PART 7 START (68 entries) ==")
    for _, e in ipairs(T) do
        local pid, tid = e.pid, e.tid
        -- verify-skip: already at target?
        local ok0, cur = pcall(GetTeamIdFromPlayerId, pid)
        if ok0 and cur == tid then
            log(e.n .. " pid=" .. pid .. " already at " .. tid .. ", skip")
        else
            local okp, p2 = pcall(IsPlayerPresigned, pid)
            if okp and p2 then pcall(DeletePresignedContract, pid) end
            local okl, l2 = pcall(IsPlayerLoanedOut, pid)
            if okl and l2 then pcall(TerminateLoan, pid) end
            local from = (ok0 and cur and cur > 0) and cur or 0
            local ok = false
            if e.kind == "perm" then
                ok = pcall(cTransferPlayer, pid, from, tid, 0, -1, e.wage, e.months)
            else
                ok = pcall(cLoanPlayer, pid, from, tid, e.months, e.buy)
            end
            local ok2, cur2 = pcall(GetTeamIdFromPlayerId, pid)
            local tn = ""
            if ok2 and cur2 and cur2 > 0 then local o3, n3 = pcall(GetTeamName, cur2) tn = tostring(n3 or "") end
            local res = "FAIL"
            if e.kind == "perm" and ok2 and cur2 == tid then res = "OK" end
            if e.kind == "loan" and ok then
                local ol, lo = pcall(IsPlayerLoanedOut, pid)
                res = (ol and lo) and "OK-loan" or "??"
            end
            log(e.n .. " pid=" .. pid .. " -> " .. tid .. " [" .. res .. "] after=" .. tostring(cur2) .. " " .. tn .. " pcall=" .. tostring(ok))
        end
    end
    log("== PART 7 DONE ==")
end

main()
