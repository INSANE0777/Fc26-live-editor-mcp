-- native_transfers_part10.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Gabriel Strefezza", pid = 235949, tid = 1843, kind = 'perm', wage = 40000, months = 36 },
    { n = "Alessandro Vogliacco", pid = 245566, tid = 111434, kind = 'perm', wage = 12000, months = 36 },
    { n = "Manuel Gasparini", pid = 244483, tid = 111433, kind = 'perm', wage = 4500, months = 36 },
    { n = "Filip Stojilkovic", pid = 255562, tid = 310, kind = 'loan', months = 11, buy = 0 },
    { n = "Facundo Buonanotte", pid = 269495, tid = 468, kind = 'loan', months = 11, buy = 0 },
    { n = "Marash Kumbulla", pid = 245426, tid = 480, kind = 'loan', months = 11, buy = 0 },
    { n = "Alex Forés", pid = 269643, tid = 10846, kind = 'perm', wage = 16000, months = 36 },
    { n = "Luca Zidane", pid = 240311, tid = 100888, kind = 'perm', wage = 12000, months = 36 },
    { n = "Oscar Thorn", pid = 274742, tid = 1935, kind = 'loan', months = 11, buy = 0 },
    { n = "Gastón Togni", pid = 237512, tid = 112689, kind = 'loan', months = 6, buy = 0 },
    { n = "Keenan Gough", pid = 80567, tid = 1962, kind = 'loan', months = 11, buy = 0 },
    { n = "Caleb Yirenkyi", pid = 73638, tid = 1800, kind = 'perm', wage = 16000, months = 36 },
    { n = "Maximiliano Salas", pid = 244205, tid = 111020, kind = 'loan', months = 11, buy = 0 },
    { n = "Sion Oppong", pid = 76522, tid = 1809, kind = 'perm', wage = 3000, months = 36 },
    { n = "Orel Mangala", pid = 234078, tid = 1860, kind = 'loan', months = 11, buy = 0 },
    { n = "Saïdou Sow", pid = 259119, tid = 71, kind = 'loan', months = 11, buy = 0 },
    { n = "Otso Liimatta", pid = 277310, tid = 113458, kind = 'perm', wage = 9000, months = 36 },
    { n = "Sasa Lukic", pid = 236699, tid = 94, kind = 'perm', wage = 53000, months = 36 },
    { n = "Noah Nsoki", pid = 82991, tid = 211, kind = 'perm', wage = 7000, months = 36 },
    { n = "Kodai Sano", pid = 277809, tid = 247, kind = 'perm', wage = 30000, months = 36 },
    { n = "Thimothée Lo-Tutala", pid = 271333, tid = 1935, kind = 'loan', months = 10, buy = 0 },
    { n = "Stélios Andreou", pid = 262938, tid = 10020, kind = 'loan', months = 11, buy = 0 },
    { n = "Daouda Traoré", pid = 279701, tid = 1739, kind = 'loan', months = 11, buy = 0 },
    { n = "Aleksander Andresen", pid = 273575, tid = 1756, kind = 'perm', wage = 3000, months = 36 },
    { n = "Andrés Reyes", pid = 246048, tid = 101100, kind = 'perm', wage = 9000, months = 36 },
    { n = "Felipe Salomoni", pid = 264431, tid = 101097, kind = 'loan', months = 11, buy = 0 },
    { n = "Brynjar Ingi Bjarnason", pid = 263658, tid = 1447, kind = 'perm', wage = 7000, months = 36 },
    { n = "Jan Virgili", pid = 80915, tid = 231, kind = 'perm', wage = 30000, months = 36 },
    { n = "Bruno Guimarães", pid = 247851, tid = 1, kind = 'perm', wage = 145000, months = 48 },
    { n = "Franco Mastantuono", pid = 279173, tid = 110374, kind = 'loan', months = 11, buy = 0 },
    { n = "Djibril Sow", pid = 229752, tid = 110556, kind = 'perm', wage = 30000, months = 48 },
    { n = "Maghnes Akliouche", pid = 264862, tid = 73, kind = 'perm', wage = 68000, months = 48 },
    { n = "James Trafford", pid = 263063, tid = 8, kind = 'perm', wage = 40000, months = 48 },
    { n = "Konstantinos Tzolakis", pid = 252552, tid = 1952, kind = 'perm', wage = 53000, months = 48 },
    { n = "Miguel Gutiérrez", pid = 261865, tid = 32, kind = 'perm', wage = 68000, months = 48 },
    { n = "Florentino", pid = 234569, tid = 94, kind = 'perm', wage = 40000, months = 48 },
    { n = "Gonzalo García", pid = 278399, tid = 144, kind = 'perm', wage = 30000, months = 48 },
    { n = "Konstantinos Karetsas", pid = 70497, tid = 22, kind = 'perm', wage = 30000, months = 48 },
    { n = "Valentín Barco", pid = 263370, tid = 5, kind = 'perm', wage = 53000, months = 48 },
    { n = "Kerim Alajbegovic", pid = 75533, tid = 45, kind = 'perm', wage = 12000, months = 48 },
    { n = "Konstantinos Koulierakis", pid = 270077, tid = 52, kind = 'perm', wage = 40000, months = 48 },
    { n = "Mamadou Sangaré", pid = 258601, tid = 1925, kind = 'perm', wage = 68000, months = 48 },
    { n = "António Silva", pid = 270086, tid = 1943, kind = 'perm', wage = 40000, months = 48 },
    { n = "Carlos Espí", pid = 70967, tid = 243, kind = 'perm', wage = 30000, months = 48 },
    { n = "Artem Dovbyk", pid = 242458, tid = 189, kind = 'loan', months = 11, buy = 0 },
    { n = "Santiago Castro", pid = 267861, tid = 52, kind = 'perm', wage = 40000, months = 48 },
    { n = "Matthis Abline", pid = 264422, tid = 69, kind = 'perm', wage = 40000, months = 48 },
    { n = "Tolu Arokodare", pid = 258911, tid = 245, kind = 'loan', months = 11, buy = 0 },
    { n = "Loïs Openda", pid = 243580, tid = 66, kind = 'loan', months = 11, buy = 1 },
    { n = "Crysencio Summerville", pid = 251954, tid = 605, kind = 'perm', wage = 53000, months = 48 },
    { n = "Aladji Bamba", pid = 75734, tid = 13, kind = 'perm', wage = 16000, months = 48 },
    { n = "Alejandro Garnacho", pid = 268438, tid = 2, kind = 'loan', months = 11, buy = 0 },
    { n = "Christos Tzolis", pid = 256948, tid = 1, kind = 'perm', wage = 68000, months = 48 },
    { n = "Karim Adeyemi", pid = 251852, tid = 241, kind = 'perm', wage = 88000, months = 48 },
    { n = "Ibrahima Ba", pid = 71781, tid = 237, kind = 'perm', wage = 9000, months = 48 },
    { n = "Morgan Rogers", pid = 260247, tid = 5, kind = 'perm', wage = 110000, months = 48 },
    { n = "Abdul Fatawu", pid = 267680, tid = 94, kind = 'perm', wage = 40000, months = 48 },
    { n = "João Gomes", pid = 273463, tid = 2, kind = 'perm', wage = 53000, months = 48 },
    { n = "Christ Inao Oulaï", pid = 74735, tid = 110374, kind = 'perm', wage = 16000, months = 48 },
    { n = "Trincão", pid = 244778, tid = 112387, kind = 'perm', wage = 88000, months = 48 },
    { n = "Johan Manzambi", pid = 276694, tid = 2, kind = 'perm', wage = 40000, months = 48 },
    { n = "Robin Gosens", pid = 223697, tid = 34, kind = 'loan', months = 11, buy = 0 },
    { n = "Maxime Estève", pid = 262042, tid = 112172, kind = 'perm', wage = 40000, months = 48 },
    { n = "Zeki Çelik", pid = 224490, tid = 45, kind = 'perm', wage = 53000, months = 48 },
    { n = "Lesley Ugochukwu", pid = 257084, tid = 325, kind = 'loan', months = 11, buy = 1 },
    { n = "Youri Tielemans", pid = 216393, tid = 11, kind = 'perm', wage = 110000, months = 48 },
    { n = "Leandro Trossard", pid = 207421, tid = 327, kind = 'perm', wage = 88000, months = 36 },
    { n = "Álex Jiménez", pid = 278928, tid = 110374, kind = 'loan', months = 11, buy = 0 },
}

function main()
    log("== PART 10 START (68 entries) ==")
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
    log("== PART 10 DONE ==")
end

main()
