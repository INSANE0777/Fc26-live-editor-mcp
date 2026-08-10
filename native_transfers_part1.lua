-- native_transfers_part1.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Dan Nlundulu", pid = 236321, tid = 110078, kind = 'perm', wage = 4500, months = 36 },
    { n = "Jusef Erabi", pid = 268597, tid = 1801, kind = 'loan', months = 11, buy = 0 },
    { n = "Jacopo Fazzini", pid = 266596, tid = 1842, kind = 'loan', months = 11, buy = 0 },
    { n = "Yann Sommer", pid = 177683, tid = 231, kind = 'perm', wage = 145000, months = 36 },
    { n = "Marius Lode", pid = 242160, tid = 112199, kind = 'perm', wage = 12000, months = 36 },
    { n = "Alan Forrest", pid = 256421, tid = 180, kind = 'perm', wage = 9000, months = 36 },
    { n = "Alex Paulsen", pid = 263851, tid = 83, kind = 'loan', months = 11, buy = 0 },
    { n = "Ben Krauhaus", pid = 72456, tid = 79, kind = 'loan', months = 10, buy = 0 },
    { n = "Vincent Sasso", pid = 188538, tid = 1738, kind = 'perm', wage = 22000, months = 36 },
    { n = "Nicolás López", pid = 207715, tid = 112689, kind = 'perm', wage = 30000, months = 36 },
    { n = "Luka Vuskovic", pid = 275192, tid = 1808, kind = 'perm', wage = 53000, months = 36 },
    { n = "Fabio Gerli", pid = 225428, tid = 111434, kind = 'perm', wage = 12000, months = 36 },
    { n = "Jorge Fernandes", pid = 242359, tid = 112387, kind = 'perm', wage = 22000, months = 36 },
    { n = "Nathan Ordaz", pid = 275974, tid = 688, kind = 'perm', wage = 9000, months = 36 },
    { n = "Amir Saipi", pid = 247077, tid = 100852, kind = 'perm', wage = 16000, months = 36 },
    { n = "Lohann Doucet", pid = 270355, tid = 1887, kind = 'perm', wage = 12000, months = 36 },
    { n = "Sam Larsson", pid = 209782, tid = 319, kind = 'perm', wage = 12000, months = 36 },
    { n = "Nikola Vasic", pid = 272916, tid = 111594, kind = 'perm', wage = 9000, months = 36 },
    { n = "Jakob Vestergaard Jessen", pid = 78613, tid = 111339, kind = 'perm', wage = 5500, months = 36 },
    { n = "Ander Herrera", pid = 191740, tid = 244, kind = 'perm', wage = 40000, months = 36 },
    { n = "Jean Batoum", pid = 83925, tid = 1906, kind = 'loan', months = 11, buy = 0 },
    { n = "Samuele Capolupo", pid = 80835, tid = 113974, kind = 'loan', months = 11, buy = 0 },
    { n = "Nathan Lowe", pid = 274472, tid = 81, kind = 'loan', months = 11, buy = 0 },
    { n = "Danilho Doekhi", pid = 232658, tid = 1906, kind = 'perm', wage = 68000, months = 36 },
    { n = "Álvaro Rodriguez", pid = 237206, tid = 1943, kind = 'perm', wage = 9000, months = 36 },
    { n = "Fellipe Jack", pid = 75225, tid = 111434, kind = 'loan', months = 11, buy = 0 },
    { n = "Jonas Harder", pid = 76171, tid = 896, kind = 'perm', wage = 7000, months = 36 },
    { n = "Murphy Cooper", pid = 268544, tid = 1929, kind = 'perm', wage = 7000, months = 36 },
    { n = "Charlie Taylor", pid = 204760, tid = 91, kind = 'perm', wage = 16000, months = 36 },
    { n = "Adam Mayor", pid = 271675, tid = 81, kind = 'perm', wage = 5500, months = 36 },
    { n = "Horatiu Moldovan", pid = 251136, tid = 131174, kind = 'loan', months = 11, buy = 0 },
    { n = "Shin Yamada", pid = 269842, tid = 100087, kind = 'loan', months = 11, buy = 0 },
    { n = "Lorenzo Ignacchiti", pid = 74150, tid = 111433, kind = 'perm', wage = 9000, months = 36 },
    { n = "Coleen Louis", pid = 70018, tid = 896, kind = 'perm', wage = 5500, months = 36 },
    { n = "Giacomo Corona", pid = 276754, tid = 113147, kind = 'loan', months = 11, buy = 0 },
    { n = "Elías Pereyra", pid = 241929, tid = 113044, kind = 'perm', wage = 12000, months = 36 },
    { n = "Rui Mendes", pid = 269744, tid = 100638, kind = 'perm', wage = 7000, months = 36 },
    { n = "Tyrese Noslin", pid = 79032, tid = 1932, kind = 'perm', wage = 9000, months = 36 },
    { n = "Paulo Díaz", pid = 214436, tid = 112885, kind = 'perm', wage = 30000, months = 36 },
    { n = "Michal Skóras", pid = 251633, tid = 64, kind = 'perm', wage = 16000, months = 36 },
    { n = "Andrej Vasovic", pid = 75573, tid = 231, kind = 'perm', wage = 3000, months = 36 },
    { n = "Alan Franco", pid = 246058, tid = 111715, kind = 'loan', months = 11, buy = 0 },
    { n = "Maxim Dal", pid = 276863, tid = 165, kind = 'perm', wage = 3000, months = 36 },
    { n = "Eseosa Sule", pid = 79681, tid = 100805, kind = 'perm', wage = 3000, months = 36 },
    { n = "Tom Wisbereit", pid = 85547, tid = 100409, kind = 'perm', wage = 3000, months = 36 },
    { n = "Nahuel Estévez", pid = 240992, tid = 1843, kind = 'perm', wage = 16000, months = 36 },
    { n = "Harry Winks", pid = 222400, tid = 1842, kind = 'perm', wage = 22000, months = 36 },
    { n = "Ebrima Colley", pid = 254692, tid = 101033, kind = 'loan', months = 11, buy = 1 },
    { n = "Mihail Polendakov", pid = 79950, tid = 1906, kind = 'loan', months = 11, buy = 0 },
    { n = "Lewis Dobbin", pid = 264039, tid = 17, kind = 'perm', wage = 16000, months = 36 },
    { n = "Nikolai Skuseth", pid = 74740, tid = 113892, kind = 'loan', months = 6, buy = 0 },
    { n = "Thomas Meunier", pid = 202371, tid = 106, kind = 'perm', wage = 40000, months = 36 },
    { n = "Martin Ens", pid = 279530, tid = 1825, kind = 'loan', months = 11, buy = 0 },
    { n = "Vasco Lopes", pid = 72658, tid = 112494, kind = 'perm', wage = 9000, months = 36 },
    { n = "Jawad El Yamiq", pid = 241775, tid = 131174, kind = 'perm', wage = 16000, months = 36 },
    { n = "Florian Kleinhansl", pid = 263089, tid = 110502, kind = 'perm', wage = 9000, months = 36 },
    { n = "Vincent Burlet", pid = 72080, tid = 110747, kind = 'perm', wage = 9000, months = 36 },
    { n = "Elkan Baggott", pid = 260798, tid = 97, kind = 'perm', wage = 5500, months = 36 },
    { n = "Oliwier Zych", pid = 271411, tid = 1887, kind = 'loan', months = 11, buy = 0 },
    { n = "Áron Csongvai", pid = 272566, tid = 1819, kind = 'perm', wage = 12000, months = 36 },
    { n = "Jake Girdwood-Reich", pid = 272324, tid = 83, kind = 'perm', wage = 9000, months = 36 },
    { n = "Christ Makosso", pid = 275337, tid = 57, kind = 'perm', wage = 9000, months = 36 },
    { n = "Diogo Nascimento", pid = 276998, tid = 744, kind = 'loan', months = 11, buy = 0 },
    { n = "Mikel Rodriguez", pid = 79186, tid = 463, kind = 'perm', wage = 9000, months = 36 },
    { n = "Aïssa Mandi", pid = 201143, tid = 1853, kind = 'perm', wage = 40000, months = 36 },
    { n = "Andrés García", pid = 275468, tid = 1860, kind = 'loan', months = 11, buy = 0 },
    { n = "Isaac Schmidt", pid = 256776, tid = 900, kind = 'perm', wage = 22000, months = 36 },
    { n = "Miguel Silva", pid = 83568, tid = 110991, kind = 'perm', wage = 3000, months = 36 },
}

function main()
    log("== PART 1 START (68 entries) ==")
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
    log("== PART 1 DONE ==")
end

main()
