-- native_transfers_part4.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Alessandro Bianco", pid = 271477, tid = 1744, kind = 'perm', wage = 16000, months = 36 },
    { n = "Filippo Distefano", pid = 277599, tid = 1746, kind = 'perm', wage = 7000, months = 36 },
    { n = "Simon Simoni", pid = 272787, tid = 897, kind = 'perm', wage = 7000, months = 36 },
    { n = "Daniel Fila", pid = 267593, tid = 2038, kind = 'loan', months = 11, buy = 0 },
    { n = "Guillermo Maripán", pid = 219145, tid = 111325, kind = 'perm', wage = 40000, months = 36 },
    { n = "Gustavo Charrupí", pid = 82500, tid = 7, kind = 'loan', months = 11, buy = 0 },
    { n = "Leonardo Sequeira", pid = 240743, tid = 112965, kind = 'loan', months = 6, buy = 0 },
    { n = "Alan Soñora", pid = 252240, tid = 110396, kind = 'perm', wage = 9000, months = 36 },
    { n = "Ahmad Faqa", pid = 268345, tid = 113892, kind = 'perm', wage = 3000, months = 36 },
    { n = "Per Kristian Bråtveit", pid = 211021, tid = 1463, kind = 'perm', wage = 12000, months = 36 },
    { n = "Malang Sarr", pid = 235454, tid = 131798, kind = 'perm', wage = 53000, months = 36 },
    { n = "Patson Daka", pid = 241202, tid = 28, kind = 'perm', wage = 12000, months = 36 },
    { n = "Álex Sala", pid = 265732, tid = 453, kind = 'loan', months = 11, buy = 0 },
    { n = "Fabio Ferraro", pid = 264711, tid = 681, kind = 'perm', wage = 12000, months = 36 },
    { n = "Darwin Machís", pid = 210463, tid = 110991, kind = 'loan', months = 11, buy = 0 },
    { n = "Will Lankshear", pid = 75272, tid = 12, kind = 'perm', wage = 9000, months = 36 },
    { n = "Antonín Barák", pid = 236791, tid = 100135, kind = 'perm', wage = 22000, months = 36 },
    { n = "Santeri Väänänen", pid = 246757, tid = 1832, kind = 'perm', wage = 7000, months = 36 },
    { n = "Filip Bilbija", pid = 252073, tid = 91, kind = 'perm', wage = 16000, months = 36 },
    { n = "Issa Diop", pid = 231633, tid = 94, kind = 'perm', wage = 40000, months = 36 },
    { n = "Samuel Beltrán", pid = 74838, tid = 111006, kind = 'loan', months = 6, buy = 0 },
    { n = "Tomás Escalante", pid = 255386, tid = 1906, kind = 'perm', wage = 7000, months = 36 },
    { n = "Maximilian Wöber", pid = 231838, tid = 34, kind = 'perm', wage = 30000, months = 36 },
    { n = "Casemiro", pid = 200145, tid = 112893, kind = 'perm', wage = 88000, months = 36 },
    { n = "Paul Nardi", pid = 206218, tid = 57, kind = 'perm', wage = 16000, months = 36 },
    { n = "Elijah Just", pid = 254136, tid = 1960, kind = 'perm', wage = 12000, months = 36 },
    { n = "Matteo Cocchi", pid = 77615, tid = 110912, kind = 'loan', months = 11, buy = 0 },
    { n = "Edson Tortolero", pid = 253579, tid = 101099, kind = 'loan', months = 11, buy = 0 },
    { n = "Matías Borgogno", pid = 243476, tid = 111710, kind = 'loan', months = 11, buy = 0 },
    { n = "Mats Seiler", pid = 70279, tid = 1715, kind = 'perm', wage = 3000, months = 36 },
    { n = "Norman Bassette", pid = 264621, tid = 681, kind = 'loan', months = 11, buy = 0 },
    { n = "Kevin Spadanuda", pid = 269947, tid = 894, kind = 'perm', wage = 9000, months = 36 },
    { n = "Lucas França", pid = 235574, tid = 1438, kind = 'perm', wage = 22000, months = 36 },
    { n = "Loic Lüthi", pid = 276172, tid = 897, kind = 'perm', wage = 7000, months = 36 },
    { n = "Ibrahim Cissoko", pid = 268927, tid = 1914, kind = 'perm', wage = 12000, months = 36 },
    { n = "Elmin Rastoder", pid = 276645, tid = 1884, kind = 'perm', wage = 5500, months = 36 },
    { n = "Clement Bischoff", pid = 278359, tid = 1910, kind = 'loan', months = 11, buy = 0 },
    { n = "Wesley", pid = 74913, tid = 111325, kind = 'perm', wage = 12000, months = 36 },
    { n = "Ibrahim Fofana", pid = 274440, tid = 681, kind = 'perm', wage = 5500, months = 36 },
    { n = "Matteo Lovato", pid = 258946, tid = 110912, kind = 'perm', wage = 12000, months = 36 },
    { n = "Mikayil Faye", pid = 277118, tid = 171, kind = 'loan', months = 11, buy = 0 },
    { n = "Amin Boudri", pid = 70331, tid = 708, kind = 'perm', wage = 16000, months = 36 },
    { n = "Matt Targett", pid = 218659, tid = 1952, kind = 'perm', wage = 22000, months = 36 },
    { n = "Rafiu Durosinmi", pid = 273128, tid = 673, kind = 'perm', wage = 30000, months = 36 },
    { n = "Ismaël Gharbi", pid = 263194, tid = 100888, kind = 'loan', months = 11, buy = 0 },
    { n = "Abdoul Kader Bamba", pid = 246790, tid = 110832, kind = 'perm', wage = 12000, months = 36 },
    { n = "Jovane Cabral", pid = 244193, tid = 1629, kind = 'perm', wage = 16000, months = 36 },
    { n = "Joseph Opoku", pid = 78426, tid = 1960, kind = 'perm', wage = 16000, months = 36 },
    { n = "Awad Al Nashri", pid = 259358, tid = 111674, kind = 'perm', wage = 3000, months = 36 },
    { n = "Valentín Fascendini", pid = 279845, tid = 112670, kind = 'perm', wage = 9000, months = 36 },
    { n = "Aleksandr Guboglo", pid = 77609, tid = 379, kind = 'loan', months = 11, buy = 0 },
    { n = "Ármin Pécsi", pid = 79922, tid = 2017, kind = 'loan', months = 11, buy = 0 },
    { n = "Lukas Grgic", pid = 239091, tid = 1848, kind = 'perm', wage = 9000, months = 36 },
    { n = "Andrea Bozzolan", pid = 80172, tid = 1843, kind = 'loan', months = 11, buy = 0 },
    { n = "Bilal Nadir", pid = 263602, tid = 28, kind = 'perm', wage = 22000, months = 36 },
    { n = "Juan Cruz", pid = 206219, tid = 110827, kind = 'perm', wage = 22000, months = 36 },
    { n = "Ricardo Mangas", pid = 240020, tid = 111811, kind = 'loan', months = 11, buy = 0 },
    { n = "Emre Tezgel", pid = 271626, tid = 1933, kind = 'loan', months = 11, buy = 0 },
    { n = "Daniel Bielica", pid = 244256, tid = 1790, kind = 'perm', wage = 12000, months = 36 },
    { n = "Nicolas Milanovic", pid = 257326, tid = 112427, kind = 'perm', wage = 12000, months = 36 },
    { n = "Tin Plavotic", pid = 237570, tid = 111097, kind = 'perm', wage = 9000, months = 36 },
    { n = "Sergio López", pid = 245287, tid = 110832, kind = 'perm', wage = 12000, months = 36 },
    { n = "Antoniu Roca", pid = 263133, tid = 453, kind = 'loan', months = 11, buy = 0 },
    { n = "Alessandro Milani", pid = 76178, tid = 131682, kind = 'perm', wage = 5500, months = 36 },
    { n = "Iker Bravo", pid = 265194, tid = 1795, kind = 'perm', wage = 9000, months = 36 },
    { n = "Oluwaseun Adewumi", pid = 74864, tid = 166, kind = 'loan', months = 11, buy = 0 },
    { n = "Marcelo Pérez", pid = 259514, tid = 111006, kind = 'loan', months = 6, buy = 0 },
    { n = "Hidemasa Morita", pid = 242087, tid = 1952, kind = 'perm', wage = 53000, months = 36 },
}

function main()
    log("== PART 4 START (68 entries) ==")
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
    log("== PART 4 DONE ==")
end

main()
