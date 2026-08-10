-- native_transfers_part5.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Mika Wallentowitz", pid = 81991, tid = 165, kind = 'loan', months = 11, buy = 0 },
    { n = "Alessio Zerbin", pid = 237669, tid = 111657, kind = 'perm', wage = 22000, months = 36 },
    { n = "Luis Hasa", pid = 70163, tid = 111657, kind = 'perm', wage = 12000, months = 36 },
    { n = "Alejandro Marqués", pid = 243047, tid = 110832, kind = 'perm', wage = 22000, months = 36 },
    { n = "Naif Masoud", pid = 70584, tid = 112387, kind = 'perm', wage = 4500, months = 36 },
    { n = "Stefan Schimmer", pid = 239078, tid = 112638, kind = 'perm', wage = 12000, months = 36 },
    { n = "Nawaf Al Habashi", pid = 246381, tid = 605, kind = 'perm', wage = 4500, months = 36 },
    { n = "Dominik Javorcek", pid = 74877, tid = 305, kind = 'loan', months = 11, buy = 0 },
    { n = "Elias Achouri", pid = 263672, tid = 131439, kind = 'perm', wage = 16000, months = 36 },
    { n = "Conor Townsend", pid = 203751, tid = 109, kind = 'perm', wage = 12000, months = 36 },
    { n = "Kaheim Dixon", pid = 74922, tid = 1906, kind = 'perm', wage = 3000, months = 36 },
    { n = "Ryan Strain", pid = 241244, tid = 79, kind = 'perm', wage = 9000, months = 36 },
    { n = "Carlos Fernández", pid = 221014, tid = 110827, kind = 'perm', wage = 16000, months = 36 },
    { n = "Isaiah Ahmed", pid = 74337, tid = 100638, kind = 'perm', wage = 3000, months = 36 },
    { n = "Anthony Descotte", pid = 254503, tid = 634, kind = 'loan', months = 11, buy = 0 },
    { n = "Blerton Isufi", pid = 80263, tid = 1756, kind = 'loan', months = 6, buy = 0 },
    { n = "Luca Erlein", pid = 76923, tid = 32, kind = 'perm', wage = 7000, months = 36 },
    { n = "Alex Lowry", pid = 266756, tid = 83, kind = 'loan', months = 11, buy = 0 },
    { n = "Daizen Maeda", pid = 246321, tid = 94, kind = 'perm', wage = 53000, months = 36 },
    { n = "Andrei Coubis", pid = 81262, tid = 149, kind = 'perm', wage = 9000, months = 36 },
    { n = "Oliver Lukic", pid = 82763, tid = 2017, kind = 'loan', months = 11, buy = 0 },
    { n = "Lasse Flø", pid = 278362, tid = 681, kind = 'perm', wage = 7000, months = 36 },
    { n = "Shamal George", pid = 240346, tid = 112764, kind = 'perm', wage = 5500, months = 36 },
    { n = "Maxence Prévot", pid = 231841, tid = 111276, kind = 'perm', wage = 9000, months = 36 },
    { n = "Jamie Lawrence", pid = 259082, tid = 100087, kind = 'perm', wage = 16000, months = 36 },
    { n = "Arnau Tenas", pid = 259065, tid = 453, kind = 'loan', months = 11, buy = 0 },
    { n = "Owen Goodman", pid = 276806, tid = 180, kind = 'loan', months = 11, buy = 0 },
    { n = "Matthew Cox", pid = 256488, tid = 135, kind = 'loan', months = 11, buy = 0 },
    { n = "Diego Pampín", pid = 241055, tid = 110832, kind = 'perm', wage = 12000, months = 36 },
    { n = "Daniel Villahermosa", pid = 266100, tid = 110827, kind = 'perm', wage = 9000, months = 36 },
    { n = "José Gragera", pid = 250997, tid = 10846, kind = 'loan', months = 11, buy = 0 },
    { n = "Richard Taylor", pid = 252878, tid = 112764, kind = 'loan', months = 11, buy = 0 },
    { n = "Calebe", pid = 264842, tid = 111325, kind = 'loan', months = 11, buy = 0 },
    { n = "Danilo", pid = 199304, tid = 517, kind = 'loan', months = 11, buy = 0 },
    { n = "Wílder Viera", pid = 260135, tid = 110953, kind = 'perm', wage = 9000, months = 36 },
    { n = "Tin Jedvaj", pid = 215930, tid = 111674, kind = 'perm', wage = 22000, months = 36 },
    { n = "Simone Pontisso", pid = 228882, tid = 111434, kind = 'perm', wage = 16000, months = 36 },
    { n = "Aodhan Doherty", pid = 82914, tid = 79, kind = 'loan', months = 10, buy = 0 },
    { n = "Dudu", pid = 258085, tid = 111329, kind = 'perm', wage = 9000, months = 36 },
    { n = "Antonio Candela", pid = 252315, tid = 110908, kind = 'loan', months = 11, buy = 0 },
    { n = "Felipe Lima", pid = 79911, tid = 234, kind = 'loan', months = 11, buy = 0 },
    { n = "Marco Festa", pid = 230631, tid = 111434, kind = 'perm', wage = 12000, months = 36 },
    { n = "Lewis Smith", pid = 252571, tid = 77, kind = 'perm', wage = 5500, months = 36 },
    { n = "Giannis Papanikolaou", pid = 258040, tid = 301, kind = 'perm', wage = 9000, months = 36 },
    { n = "Gilberto Flores", pid = 268610, tid = 111008, kind = 'loan', months = 11, buy = 0 },
    { n = "Brayan Ceballos", pid = 276960, tid = 111139, kind = 'perm', wage = 12000, months = 36 },
    { n = "Millenic Alli", pid = 71215, tid = 89, kind = 'perm', wage = 9000, months = 36 },
    { n = "Carlos Marín", pid = 254099, tid = 1854, kind = 'perm', wage = 12000, months = 36 },
    { n = "Jusuf Gazibegovic", pid = 259101, tid = 301, kind = 'loan', months = 11, buy = 0 },
    { n = "Alaa Bellaarouch", pid = 276988, tid = 100757, kind = 'loan', months = 11, buy = 0 },
    { n = "Lucas Núñez", pid = 78669, tid = 467, kind = 'loan', months = 11, buy = 0 },
    { n = "Miguel Rodríguez", pid = 258730, tid = 463, kind = 'perm', wage = 22000, months = 36 },
    { n = "Simon Elisor", pid = 258526, tid = 308, kind = 'perm', wage = 12000, months = 36 },
    { n = "Georgios Koutsias", pid = 258834, tid = 112809, kind = 'perm', wage = 9000, months = 36 },
    { n = "Rodrigo Rodrigues", pid = 78722, tid = 237, kind = 'perm', wage = 3000, months = 36 },
    { n = "Jonathan Dubasin", pid = 263883, tid = 479, kind = 'perm', wage = 30000, months = 36 },
    { n = "Luca Erlein", pid = 76923, tid = 32, kind = 'perm', wage = 7000, months = 36 },
    { n = "Emmanuel Addai", pid = 276093, tid = 100087, kind = 'perm', wage = 12000, months = 36 },
    { n = "Darko Churlinov", pid = 251545, tid = 110746, kind = 'perm', wage = 9000, months = 36 },
    { n = "Lanroy Machine", pid = 78377, tid = 1913, kind = 'loan', months = 11, buy = 0 },
    { n = "Gustavo Varela", pid = 72337, tid = 111811, kind = 'perm', wage = 12000, months = 36 },
    { n = "Darío Cáceres", pid = 242691, tid = 112965, kind = 'perm', wage = 12000, months = 36 },
    { n = "Aljosa Vasic", pid = 276451, tid = 112494, kind = 'loan', months = 11, buy = 0 },
    { n = "Mustapha Isah", pid = 272529, tid = 132231, kind = 'perm', wage = 5500, months = 36 },
    { n = "Franck Atoen", pid = 81568, tid = 111276, kind = 'loan', months = 11, buy = 0 },
    { n = "Lorenzo Carissoni", pid = 235292, tid = 110912, kind = 'perm', wage = 9000, months = 36 },
    { n = "Emanuele Zuelli", pid = 256119, tid = 110912, kind = 'perm', wage = 12000, months = 36 },
    { n = "Dan Sinaté", pid = 79493, tid = 1816, kind = 'loan', months = 11, buy = 0 },
}

function main()
    log("== PART 5 START (68 entries) ==")
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
    log("== PART 5 DONE ==")
end

main()
