-- native_transfers_part3.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Noël Aséko", pid = 279622, tid = 1824, kind = 'perm', wage = 16000, months = 36 },
    { n = "Sebastiano Desplanches", pid = 276839, tid = 111657, kind = 'loan', months = 11, buy = 0 },
    { n = "Mattia Fortin", pid = 78934, tid = 1843, kind = 'loan', months = 11, buy = 0 },
    { n = "Filip Marchwinski", pid = 246649, tid = 110747, kind = 'loan', months = 11, buy = 0 },
    { n = "Adama Bojang", pid = 277578, tid = 670, kind = 'loan', months = 11, buy = 0 },
    { n = "Tanguy Nianzou", pid = 252961, tid = 65, kind = 'perm', wage = 16000, months = 36 },
    { n = "Amir Richardson", pid = 262236, tid = 1738, kind = 'loan', months = 11, buy = 0 },
    { n = "Kryspin Szczesniak", pid = 263262, tid = 111088, kind = 'loan', months = 11, buy = 0 },
    { n = "Mahir Emreli", pid = 262800, tid = 114326, kind = 'loan', months = 11, buy = 0 },
    { n = "Koray Günter", pid = 204451, tid = 607, kind = 'perm', wage = 12000, months = 36 },
    { n = "Rakan Kaabi", pid = 278132, tid = 607, kind = 'perm', wage = 3000, months = 36 },
    { n = "Abdullah Al Qahtani", pid = 253207, tid = 113057, kind = 'perm', wage = 3000, months = 36 },
    { n = "Abdulrahman Al-Obaid", pid = 228627, tid = 131735, kind = 'perm', wage = 3000, months = 36 },
    { n = "Mohammed Al Owais", pid = 210923, tid = 605, kind = 'perm', wage = 12000, months = 36 },
    { n = "Jonathan Herrera", pid = 243977, tid = 112713, kind = 'loan', months = 17, buy = 0 },
    { n = "Hugo Andersson Mella", pid = 71724, tid = 112126, kind = 'loan', months = 6, buy = 0 },
    { n = "Elliot Watt", pid = 241982, tid = 748, kind = 'perm', wage = 12000, months = 36 },
    { n = "Patrick Beach", pid = 267599, tid = 294, kind = 'perm', wage = 9000, months = 36 },
    { n = "Juan Cruz", pid = 206219, tid = 110827, kind = 'perm', wage = 22000, months = 36 },
    { n = "Karlan Grant", pid = 225668, tid = 89, kind = 'perm', wage = 16000, months = 36 },
    { n = "Tayyip Talha Sanuç", pid = 242919, tid = 101037, kind = 'perm', wage = 9000, months = 36 },
    { n = "Rick van Drongelen", pid = 233097, tid = 1884, kind = 'perm', wage = 30000, months = 36 },
    { n = "Ahmed Kutucu", pid = 245762, tid = 101037, kind = 'loan', months = 11, buy = 0 },
    { n = "Xaver Kiefersauer", pid = 85508, tid = 171, kind = 'perm', wage = 3000, months = 36 },
    { n = "Tino Casali", pid = 222024, tid = 160, kind = 'perm', wage = 7000, months = 36 },
    { n = "Karol Mets", pid = 226506, tid = 160, kind = 'perm', wage = 16000, months = 36 },
    { n = "Emmanuel Iyoha", pid = 231353, tid = 110588, kind = 'perm', wage = 12000, months = 36 },
    { n = "Andrin Hunziker", pid = 267486, tid = 898, kind = 'perm', wage = 9000, months = 36 },
    { n = "Anas Tajaouart", pid = 75197, tid = 132231, kind = 'loan', months = 11, buy = 0 },
    { n = "Diego Alejandro Novoa", pid = 214351, tid = 112992, kind = 'perm', wage = 12000, months = 36 },
    { n = "Mathieu Cafaro", pid = 231236, tid = 71, kind = 'perm', wage = 22000, months = 36 },
    { n = "Cristian Jaime", pid = 81813, tid = 101110, kind = 'loan', months = 11, buy = 0 },
    { n = "Hossam Abdelmaguid", pid = 81960, tid = 1906, kind = 'perm', wage = 12000, months = 36 },
    { n = "Carlos Quintana", pid = 234458, tid = 115472, kind = 'perm', wage = 30000, months = 36 },
    { n = "Cardoso Varela", pid = 80384, tid = 236, kind = 'perm', wage = 12000, months = 36 },
    { n = "Joris van Overeem", pid = 210010, tid = 1903, kind = 'perm', wage = 16000, months = 36 },
    { n = "Emre Mor", pid = 231240, tid = 1910, kind = 'perm', wage = 22000, months = 36 },
    { n = "Diego Conde", pid = 258534, tid = 449, kind = 'loan', months = 11, buy = 0 },
    { n = "Jhomier Guerrero", pid = 84319, tid = 101105, kind = 'perm', wage = 12000, months = 36 },
    { n = "Kevin Cataño", pid = 83086, tid = 111325, kind = 'loan', months = 11, buy = 0 },
    { n = "Carlo Sickinger", pid = 242525, tid = 110502, kind = 'perm', wage = 9000, months = 36 },
    { n = "Rahim Alhassane", pid = 73502, tid = 189, kind = 'perm', wage = 16000, months = 36 },
    { n = "Kasper Junker", pid = 213871, tid = 1786, kind = 'perm', wage = 22000, months = 36 },
    { n = "Gabriel Batista", pid = 271571, tid = 517, kind = 'perm', wage = 22000, months = 36 },
    { n = "André Gomes", pid = 211575, tid = 114510, kind = 'perm', wage = 30000, months = 36 },
    { n = "Lucas Monzón", pid = 79424, tid = 517, kind = 'perm', wage = 9000, months = 36 },
    { n = "Warleson", pid = 255754, tid = 517, kind = 'perm', wage = 16000, months = 36 },
    { n = "Lorent Tolaj", pid = 266886, tid = 1919, kind = 'perm', wage = 9000, months = 36 },
    { n = "Darío Benavides", pid = 279506, tid = 100757, kind = 'perm', wage = 7000, months = 36 },
    { n = "Dylan Williams", pid = 264115, tid = 83, kind = 'perm', wage = 5500, months = 36 },
    { n = "Jhon Córdoba", pid = 210287, tid = 110953, kind = 'perm', wage = 53000, months = 36 },
    { n = "Markus Gustav Jensen", pid = 277635, tid = 111325, kind = 'perm', wage = 5500, months = 36 },
    { n = "Luca Sirch", pid = 73135, tid = 580, kind = 'perm', wage = 22000, months = 36 },
    { n = "Diego González", pid = 76415, tid = 244, kind = 'perm', wage = 3000, months = 36 },
    { n = "Eddie Beach", pid = 277904, tid = 834, kind = 'perm', wage = 4500, months = 36 },
    { n = "Théo De Percin", pid = 263402, tid = 58, kind = 'loan', months = 11, buy = 0 },
    { n = "Lassine Sinayoko", pid = 251170, tid = 111817, kind = 'perm', wage = 30000, months = 36 },
    { n = "Derensili Sanches Fernandes", pid = 271511, tid = 1939, kind = 'perm', wage = 9000, months = 36 },
    { n = "Emirhan Demircan", pid = 79113, tid = 100638, kind = 'loan', months = 11, buy = 0 },
    { n = "Diego Gómez", pid = 269278, tid = 110839, kind = 'loan', months = 11, buy = 0 },
    { n = "Yaya Bojang", pid = 70125, tid = 717, kind = 'perm', wage = 5500, months = 36 },
    { n = "Jeremy Agbonifo", pid = 71343, tid = 110745, kind = 'loan', months = 11, buy = 0 },
    { n = "Kayne van Oevelen", pid = 271150, tid = 94, kind = 'perm', wage = 12000, months = 36 },
    { n = "Hugo Sotelo", pid = 264095, tid = 1853, kind = 'loan', months = 11, buy = 0 },
    { n = "Mame Alassane Niang", pid = 85108, tid = 236, kind = 'perm', wage = 3000, months = 36 },
    { n = "Angelo Gattermayer", pid = 264867, tid = 2017, kind = 'perm', wage = 7000, months = 36 },
    { n = "Danilo Al Saed", pid = 272967, tid = 1756, kind = 'loan', months = 6, buy = 0 },
    { n = "Gustavo Silva", pid = 74649, tid = 111975, kind = 'perm', wage = 16000, months = 36 },
}

function main()
    log("== PART 3 START (68 entries) ==")
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
    log("== PART 3 DONE ==")
end

main()
