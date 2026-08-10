-- native_transfers_part8.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Imanol Machuca", pid = 259790, tid = 110093, kind = 'perm', wage = 16000, months = 36 },
    { n = "Tobías Andrada", pid = 79246, tid = 1876, kind = 'perm', wage = 7000, months = 36 },
    { n = "Francisco Perruzzi", pid = 269501, tid = 111707, kind = 'perm', wage = 7000, months = 36 },
    { n = "Nicolás Orsini", pid = 220148, tid = 113044, kind = 'perm', wage = 12000, months = 36 },
    { n = "Kacper Sezonienko", pid = 263778, tid = 206, kind = 'perm', wage = 7000, months = 36 },
    { n = "Youssef Maziz", pid = 237138, tid = 694, kind = 'perm', wage = 22000, months = 36 },
    { n = "Dejan Radonjic", pid = 73666, tid = 780, kind = 'perm', wage = 7000, months = 36 },
    { n = "Ebenezer Akinsanmiro", pid = 70471, tid = 111811, kind = 'loan', months = 11, buy = 0 },
    { n = "Dominic Vavassori", pid = 74573, tid = 1843, kind = 'loan', months = 11, buy = 0 },
    { n = "Ilias Kostis", pid = 274208, tid = 100852, kind = 'perm', wage = 9000, months = 36 },
    { n = "Patrick Soko", pid = 240047, tid = 100888, kind = 'loan', months = 11, buy = 0 },
    { n = "Anto Sekongo", pid = 73511, tid = 748, kind = 'perm', wage = 7000, months = 36 },
    { n = "Damián Rodríguez", pid = 279112, tid = 1968, kind = 'loan', months = 11, buy = 0 },
    { n = "Kevin Akpoguma", pid = 211856, tid = 111657, kind = 'perm', wage = 22000, months = 36 },
    { n = "Danny Welbeck", pid = 186146, tid = 5, kind = 'perm', wage = 68000, months = 36 },
    { n = "Redouane Halhal", pid = 264657, tid = 205, kind = 'perm', wage = 9000, months = 36 },
    { n = "Lucas Sanseviero", pid = 256159, tid = 110953, kind = 'loan', months = 17, buy = 0 },
    { n = "Kamarl Grant", pid = 278987, tid = 112764, kind = 'loan', months = 11, buy = 0 },
    { n = "Gabriel Pirani", pid = 277301, tid = 131439, kind = 'perm', wage = 12000, months = 36 },
    { n = "Niklas Ødegård", pid = 264295, tid = 417, kind = 'perm', wage = 7000, months = 36 },
    { n = "Marco Ruggero", pid = 73989, tid = 110908, kind = 'loan', months = 11, buy = 0 },
    { n = "Simone Zanon", pid = 72916, tid = 110738, kind = 'loan', months = 11, buy = 0 },
    { n = "Luke Thomas", pid = 235059, tid = 100805, kind = 'perm', wage = 4500, months = 36 },
    { n = "Nordan Mukiele", pid = 80804, tid = 70, kind = 'loan', months = 11, buy = 0 },
    { n = "Rodrigo Fernández", pid = 253246, tid = 111711, kind = 'loan', months = 17, buy = 0 },
    { n = "Luciano Giménez", pid = 73887, tid = 112689, kind = 'loan', months = 11, buy = 0 },
    { n = "Maximiliano Porcel", pid = 74856, tid = 111710, kind = 'loan', months = 17, buy = 0 },
    { n = "Felix Bacher", pid = 262404, tid = 66, kind = 'perm', wage = 12000, months = 36 },
    { n = "Nicolás Dubersarsky", pid = 70676, tid = 111715, kind = 'loan', months = 11, buy = 0 },
    { n = "Jesús Camargo", pid = 265675, tid = 101106, kind = 'loan', months = 11, buy = 0 },
    { n = "Esteban Matus", pid = 267588, tid = 101108, kind = 'perm', wage = 12000, months = 36 },
    { n = "Tom Watson", pid = 275246, tid = 95, kind = 'loan', months = 10, buy = 0 },
    { n = "Adam Nhaili", pid = 279807, tid = 537, kind = 'loan', months = 11, buy = 0 },
    { n = "Jordan Zemura", pid = 259634, tid = 1795, kind = 'loan', months = 11, buy = 0 },
    { n = "Raphael Onyedika", pid = 262880, tid = 1824, kind = 'perm', wage = 53000, months = 36 },
    { n = "Willem Geubbels", pid = 241266, tid = 347, kind = 'perm', wage = 22000, months = 36 },
    { n = "Simon Sohm", pid = 244634, tid = 205, kind = 'loan', months = 11, buy = 0 },
    { n = "Randal Kolo Muani", pid = 237679, tid = 45, kind = 'perm', wage = 53000, months = 36 },
    { n = "Emmanuel Latte Lath", pid = 237295, tid = 1831, kind = 'loan', months = 11, buy = 0 },
    { n = "Mihai Lixandru", pid = 253758, tid = 112390, kind = 'perm', wage = 12000, months = 36 },
    { n = "Colin Rösler", pid = 243833, tid = 271, kind = 'perm', wage = 12000, months = 36 },
    { n = "Souleymane Faye", pid = 79547, tid = 217, kind = 'loan', months = 11, buy = 0 },
    { n = "Fran González", pid = 278394, tid = 481, kind = 'perm', wage = 7000, months = 36 },
    { n = "Danny Batth", pid = 195037, tid = 97, kind = 'perm', wage = 12000, months = 36 },
    { n = "Ulises Giménez", pid = 279166, tid = 112713, kind = 'loan', months = 11, buy = 0 },
    { n = "Luis Díaz", pid = 241084, tid = 111020, kind = 'perm', wage = 145000, months = 36 },
    { n = "Manolis Saliakas", pid = 222542, tid = 280, kind = 'perm', wage = 22000, months = 36 },
    { n = "Killian Corredor", pid = 262604, tid = 71, kind = 'perm', wage = 22000, months = 36 },
    { n = "Moritz-Broni Kwarteng", pid = 243970, tid = 110588, kind = 'perm', wage = 12000, months = 36 },
    { n = "Jordan Henderson", pid = 183711, tid = 5, kind = 'perm', wage = 53000, months = 36 },
    { n = "Vasilije Adzic", pid = 75085, tid = 111974, kind = 'loan', months = 11, buy = 1 },
    { n = "Péter Gulácsi", pid = 185122, tid = 483, kind = 'perm', wage = 110000, months = 36 },
    { n = "Cameron Congreve", pid = 268306, tid = 681, kind = 'perm', wage = 7000, months = 36 },
    { n = "Paulinho Bóia", pid = 245790, tid = 301, kind = 'perm', wage = 12000, months = 36 },
    { n = "João Mário", pid = 212814, tid = 110374, kind = 'loan', months = 11, buy = 1 },
    { n = "Yacine Titraoui", pid = 73348, tid = 64, kind = 'perm', wage = 12000, months = 36 },
    { n = "Estanis Pedrola", pid = 266158, tid = 110827, kind = 'perm', wage = 16000, months = 36 },
    { n = "César Palacios", pid = 83235, tid = 144, kind = 'perm', wage = 7000, months = 36 },
    { n = "Faris Abdi", pid = 256130, tid = 607, kind = 'perm', wage = 5500, months = 36 },
    { n = "Nedim Bajrami", pid = 237640, tid = 112393, kind = 'loan', months = 11, buy = 0 },
    { n = "Rodrigo Pinho", pid = 229683, tid = 131463, kind = 'perm', wage = 12000, months = 36 },
    { n = "Ian Subiabre", pid = 279934, tid = 111715, kind = 'loan', months = 11, buy = 0 },
    { n = "Esteban Rolón", pid = 231212, tid = 113044, kind = 'perm', wage = 12000, months = 36 },
    { n = "Edwin Cerrillo", pid = 247509, tid = 101099, kind = 'perm', wage = 12000, months = 36 },
    { n = "Sofiane Bendebka", pid = 255487, tid = 113222, kind = 'perm', wage = 22000, months = 36 },
    { n = "Freddie Potts", pid = 264579, tid = 231, kind = 'perm', wage = 22000, months = 36 },
    { n = "Thierno Baldé", pid = 263250, tid = 1823, kind = 'perm', wage = 5500, months = 36 },
    { n = "Tom Louchet", pid = 278187, tid = 393, kind = 'perm', wage = 22000, months = 36 },
}

function main()
    log("== PART 8 START (68 entries) ==")
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
    log("== PART 8 DONE ==")
end

main()
