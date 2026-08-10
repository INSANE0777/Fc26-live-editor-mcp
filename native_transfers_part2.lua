-- native_transfers_part2.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Jeison Medina", pid = 242492, tid = 101103, kind = 'loan', months = 11, buy = 0 },
    { n = "Alfonso Simarra", pid = 265186, tid = 101103, kind = 'perm', wage = 9000, months = 36 },
    { n = "Thiemoko Diarra", pid = 80238, tid = 111339, kind = 'perm', wage = 7000, months = 36 },
    { n = "Vivaldo Semedo", pid = 273918, tid = 717, kind = 'loan', months = 11, buy = 0 },
    { n = "Mathias Sauer", pid = 274710, tid = 1757, kind = 'perm', wage = 7000, months = 36 },
    { n = "Niklas Pyyhtiä", pid = 274089, tid = 112494, kind = 'loan', months = 11, buy = 0 },
    { n = "Makenzie Kirk", pid = 278602, tid = 1932, kind = 'loan', months = 11, buy = 0 },
    { n = "Alex Král", pid = 247028, tid = 819, kind = 'perm', wage = 22000, months = 36 },
    { n = "Omar Traoré", pid = 257136, tid = 1795, kind = 'perm', wage = 22000, months = 36 },
    { n = "Jakes Gorosabel", pid = 80113, tid = 110062, kind = 'perm', wage = 5500, months = 36 },
    { n = "Diego Mascardi", pid = 279891, tid = 54, kind = 'perm', wage = 5500, months = 36 },
    { n = "Warren Kamanzi", pid = 257970, tid = 320, kind = 'perm', wage = 22000, months = 36 },
    { n = "Conrado", pid = 238895, tid = 111088, kind = 'perm', wage = 7000, months = 36 },
    { n = "Dennis Praet", pid = 199652, tid = 110724, kind = 'perm', wage = 30000, months = 36 },
    { n = "Tomás Avilés", pid = 274569, tid = 112116, kind = 'loan', months = 6, buy = 0 },
    { n = "Julián Mavilla", pid = 76999, tid = 112713, kind = 'loan', months = 17, buy = 0 },
    { n = "Luka Jovanovic", pid = 272571, tid = 111928, kind = 'perm', wage = 7000, months = 36 },
    { n = "Henry Gray", pid = 266151, tid = 111766, kind = 'loan', months = 11, buy = 0 },
    { n = "Aurèle Amenda", pid = 270846, tid = 1800, kind = 'perm', wage = 30000, months = 36 },
    { n = "Rochinha", pid = 222461, tid = 114510, kind = 'perm', wage = 16000, months = 36 },
    { n = "Timon Wellenreuther", pid = 223686, tid = 175, kind = 'perm', wage = 40000, months = 36 },
    { n = "Martin Hellan", pid = 71321, tid = 1757, kind = 'loan', months = 6, buy = 0 },
    { n = "Marius Müller", pid = 208375, tid = 77, kind = 'perm', wage = 30000, months = 36 },
    { n = "Lovro Zvonarek", pid = 269497, tid = 718, kind = 'perm', wage = 9000, months = 36 },
    { n = "Franco Armani", pid = 214584, tid = 101100, kind = 'perm', wage = 40000, months = 36 },
    { n = "Allan Wlk", pid = 274858, tid = 110395, kind = 'perm', wage = 7000, months = 36 },
    { n = "Niklas Tauer", pid = 253474, tid = 110678, kind = 'perm', wage = 9000, months = 36 },
    { n = "Tjark Ernst", pid = 262931, tid = 246, kind = 'perm', wage = 16000, months = 36 },
    { n = "Elias Saad", pid = 274000, tid = 114162, kind = 'loan', months = 11, buy = 0 },
    { n = "Zan Celar", pid = 240317, tid = 896, kind = 'perm', wage = 12000, months = 36 },
    { n = "Tomás Guiacobini", pid = 71944, tid = 110968, kind = 'loan', months = 6, buy = 0 },
    { n = "Manuel Roffo", pid = 240796, tid = 112716, kind = 'perm', wage = 30000, months = 36 },
    { n = "Pablo Pagis", pid = 266099, tid = 111817, kind = 'perm', wage = 22000, months = 36 },
    { n = "Gustavo Cazonatti", pid = 69988, tid = 111975, kind = 'perm', wage = 12000, months = 36 },
    { n = "Rayan Touzghar", pid = 74445, tid = 232, kind = 'perm', wage = 7000, months = 36 },
    { n = "Tarik Muharemovic", pid = 262027, tid = 8, kind = 'perm', wage = 30000, months = 36 },
    { n = "Eric Bailly", pid = 225508, tid = 687, kind = 'perm', wage = 22000, months = 36 },
    { n = "Pau López", pid = 221087, tid = 114554, kind = 'perm', wage = 40000, months = 36 },
    { n = "Grant-Leon Ranos", pid = 276358, tid = 116332, kind = 'perm', wage = 5500, months = 36 },
    { n = "Pirosch Fischer", pid = 83946, tid = 116332, kind = 'loan', months = 11, buy = 0 },
    { n = "Hamed Traorè", pid = 240787, tid = 110556, kind = 'loan', months = 11, buy = 0 },
    { n = "Dani Requena", pid = 277684, tid = 1853, kind = 'loan', months = 11, buy = 0 },
    { n = "Kai Wagner", pid = 239704, tid = 112134, kind = 'perm', wage = 40000, months = 36 },
    { n = "Ian Hoffmann", pid = 261762, tid = 112072, kind = 'loan', months = 11, buy = 0 },
    { n = "Marcos Leonardo", pid = 277797, tid = 245, kind = 'perm', wage = 53000, months = 36 },
    { n = "Pantelis Hatzidiakos", pid = 229150, tid = 393, kind = 'perm', wage = 16000, months = 36 },
    { n = "Maximilian Dietz", pid = 262917, tid = 420, kind = 'perm', wage = 9000, months = 36 },
    { n = "Peru Rodríguez", pid = 265521, tid = 110069, kind = 'perm', wage = 7000, months = 36 },
    { n = "Francisco Calvo", pid = 213064, tid = 111325, kind = 'perm', wage = 9000, months = 36 },
    { n = "Tobias Lauritsen", pid = 230737, tid = 1837, kind = 'perm', wage = 22000, months = 36 },
    { n = "Mauro Pittón", pid = 228961, tid = 116332, kind = 'perm', wage = 22000, months = 36 },
    { n = "Rasmus Holten", pid = 275492, tid = 1757, kind = 'perm', wage = 3000, months = 36 },
    { n = "Maik Nawrocki", pid = 255838, tid = 64, kind = 'perm', wage = 12000, months = 36 },
    { n = "Álvaro Montero", pid = 229541, tid = 101088, kind = 'perm', wage = 40000, months = 36 },
    { n = "Sebastián Villa", pid = 233959, tid = 1877, kind = 'perm', wage = 40000, months = 36 },
    { n = "Julián Fernández", pid = 219452, tid = 111708, kind = 'loan', months = 6, buy = 0 },
    { n = "Kevin Gutiérrez", pid = 74836, tid = 111019, kind = 'perm', wage = 3000, months = 36 },
    { n = "Matheus Cunha", pid = 240243, tid = 111325, kind = 'loan', months = 11, buy = 0 },
    { n = "Nelson Weiper", pid = 268259, tid = 209, kind = 'loan', months = 11, buy = 0 },
    { n = "Yannik Engelhardt", pid = 262906, tid = 25, kind = 'perm', wage = 22000, months = 36 },
    { n = "Joel Roca", pid = 272718, tid = 280, kind = 'perm', wage = 22000, months = 36 },
    { n = "Raúl Lizoain", pid = 199101, tid = 110832, kind = 'perm', wage = 12000, months = 36 },
    { n = "Jorge Meireles", pid = 79293, tid = 131463, kind = 'perm', wage = 5500, months = 36 },
    { n = "Luca Ravanelli", pid = 245091, tid = 1837, kind = 'perm', wage = 16000, months = 36 },
    { n = "Mërgim Vojvoda", pid = 228349, tid = 55, kind = 'perm', wage = 40000, months = 36 },
    { n = "Cenk Özkacar", pid = 258396, tid = 436, kind = 'perm', wage = 16000, months = 36 },
    { n = "Rodrigo Rêgo", pid = 82432, tid = 100852, kind = 'loan', months = 11, buy = 0 },
    { n = "Niklas Niehoff", pid = 276165, tid = 15009, kind = 'loan', months = 11, buy = 0 },
}

function main()
    log("== PART 2 START (68 entries) ==")
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
    log("== PART 2 DONE ==")
end

main()
