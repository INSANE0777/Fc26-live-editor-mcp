-- native_transfers_part6.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Filip Krovinovic", pid = 230988, tid = 1629, kind = 'perm', wage = 16000, months = 36 },
    { n = "José Salinas", pid = 258684, tid = 573, kind = 'loan', months = 11, buy = 0 },
    { n = "Thomas Ince", pid = 200521, tid = 15048, kind = 'perm', wage = 12000, months = 36 },
    { n = "Mohammed Mahzari", pid = 277233, tid = 605, kind = 'perm', wage = 5500, months = 36 },
    { n = "Tomás Muro", pid = 269832, tid = 111006, kind = 'loan', months = 6, buy = 0 },
    { n = "Otávio", pid = 78088, tid = 1824, kind = 'perm', wage = 3000, months = 36 },
    { n = "Owen Bevan", pid = 271235, tid = 180, kind = 'perm', wage = 5500, months = 36 },
    { n = "Valentin Sulzbacher", pid = 78099, tid = 1971, kind = 'perm', wage = 4500, months = 36 },
    { n = "Calvin Stengs", pid = 236593, tid = 1906, kind = 'perm', wage = 40000, months = 36 },
    { n = "Dirk Proper", pid = 262334, tid = 1913, kind = 'perm', wage = 16000, months = 36 },
    { n = "Philipp Förster", pid = 237540, tid = 110636, kind = 'perm', wage = 12000, months = 36 },
    { n = "Rafa Soares", pid = 218936, tid = 718, kind = 'perm', wage = 16000, months = 36 },
    { n = "Kjell Scherpen", pid = 243675, tid = 94, kind = 'perm', wage = 40000, months = 36 },
    { n = "Luke Brooke-Smith", pid = 76117, tid = 1790, kind = 'perm', wage = 3000, months = 36 },
    { n = "Carlo Holse", pid = 240040, tid = 113018, kind = 'perm', wage = 22000, months = 36 },
    { n = "Nolan Galves", pid = 275296, tid = 109, kind = 'perm', wage = 7000, months = 36 },
    { n = "Joe Gauci", pid = 243917, tid = 149, kind = 'loan', months = 11, buy = 0 },
    { n = "Luis Vázquez", pid = 251651, tid = 88, kind = 'perm', wage = 22000, months = 36 },
    { n = "Ugo Raghouber", pid = 74774, tid = 1796, kind = 'perm', wage = 16000, months = 36 },
    { n = "Óscar Perea", pid = 274231, tid = 101099, kind = 'loan', months = 11, buy = 0 },
    { n = "Rares Ilie", pid = 262480, tid = 111433, kind = 'perm', wage = 12000, months = 36 },
    { n = "Piero Quispe", pid = 267794, tid = 111014, kind = 'perm', wage = 12000, months = 36 },
    { n = "Anders Klynge", pid = 257259, tid = 110745, kind = 'perm', wage = 9000, months = 36 },
    { n = "Julio Díaz", pid = 82936, tid = 481, kind = 'perm', wage = 7000, months = 36 },
    { n = "Andreas Skov Olsen", pid = 240017, tid = 101014, kind = 'loan', months = 11, buy = 0 },
    { n = "Sam Parker", pid = 278958, tid = 1933, kind = 'loan', months = 11, buy = 0 },
    { n = "Sebastian Berhalter", pid = 255205, tid = 12, kind = 'perm', wage = 16000, months = 36 },
    { n = "Andrés Vombergar", pid = 247143, tid = 111707, kind = 'perm', wage = 30000, months = 36 },
    { n = "Jack Shorrock", pid = 277412, tid = 563, kind = 'loan', months = 6, buy = 0 },
    { n = "Stjepan Radeljic", pid = 84037, tid = 211, kind = 'perm', wage = 9000, months = 36 },
    { n = "Henrique Araújo", pid = 266905, tid = 114510, kind = 'perm', wage = 12000, months = 36 },
    { n = "Santiago Mele", pid = 259259, tid = 110093, kind = 'loan', months = 11, buy = 0 },
    { n = "Patrick Ouotro", pid = 72306, tid = 1887, kind = 'perm', wage = 5500, months = 36 },
    { n = "Isak Helstad Amundsen", pid = 256384, tid = 2041, kind = 'perm', wage = 7000, months = 36 },
    { n = "Lukas Jonsson", pid = 237359, tid = 710, kind = 'perm', wage = 9000, months = 36 },
    { n = "Vozinha", pid = 217141, tid = 110980, kind = 'perm', wage = 9000, months = 36 },
    { n = "Niklas Dorsch", pid = 231227, tid = 111651, kind = 'perm', wage = 30000, months = 36 },
    { n = "Sankhoun Diawara", pid = 74510, tid = 131681, kind = 'perm', wage = 4500, months = 36 },
    { n = "Jayden Fevrier", pid = 264581, tid = 3, kind = 'perm', wage = 7000, months = 36 },
    { n = "Maxime Busi", pid = 245084, tid = 230, kind = 'perm', wage = 12000, months = 36 },
    { n = "Leo Sauer", pid = 277482, tid = 36, kind = 'perm', wage = 22000, months = 36 },
    { n = "Joel Ndala", pid = 74956, tid = 1750, kind = 'perm', wage = 9000, months = 36 },
    { n = "Alassana Jatta", pid = 256738, tid = 114510, kind = 'perm', wage = 7000, months = 36 },
    { n = "René Mitongo", pid = 80182, tid = 436, kind = 'perm', wage = 5500, months = 36 },
    { n = "Kacper Tobiasz", pid = 262251, tid = 110776, kind = 'perm', wage = 9000, months = 36 },
    { n = "Luís Balbo", pid = 83223, tid = 209, kind = 'perm', wage = 4500, months = 36 },
    { n = "Damián Pizarro", pid = 268396, tid = 101097, kind = 'loan', months = 11, buy = 0 },
    { n = "Pietro Comuzzo", pid = 278340, tid = 54, kind = 'loan', months = 11, buy = 1 },
    { n = "Eray Cömert", pid = 233885, tid = 54, kind = 'perm', wage = 22000, months = 36 },
    { n = "Mikel Amondarain", pid = 74813, tid = 189, kind = 'perm', wage = 22000, months = 36 },
    { n = "Umut Bozok", pid = 239043, tid = 101014, kind = 'perm', wage = 12000, months = 36 },
    { n = "Florin Stefan", pid = 248041, tid = 110776, kind = 'perm', wage = 9000, months = 36 },
    { n = "Fer Niño", pid = 252590, tid = 468, kind = 'perm', wage = 16000, months = 36 },
    { n = "Mattia Compagnon", pid = 276804, tid = 206, kind = 'loan', months = 11, buy = 0 },
    { n = "Riccardo Pagano", pid = 276951, tid = 110915, kind = 'perm', wage = 4500, months = 36 },
    { n = "Chidozie Awaziem", pid = 232693, tid = 101033, kind = 'perm', wage = 22000, months = 36 },
    { n = "Jordan Williams", pid = 237415, tid = 1926, kind = 'loan', months = 11, buy = 0 },
    { n = "Alfie Pond", pid = 264622, tid = 1924, kind = 'perm', wage = 3000, months = 36 },
    { n = "Diego Otoya", pid = 276045, tid = 131477, kind = 'loan', months = 11, buy = 0 },
    { n = "Stefan Ortega", pid = 200159, tid = 280, kind = 'perm', wage = 53000, months = 36 },
    { n = "Oliver Antman", pid = 247447, tid = 229, kind = 'perm', wage = 22000, months = 36 },
    { n = "Stefan Schwab", pid = 204688, tid = 780, kind = 'perm', wage = 16000, months = 36 },
    { n = "Erawan Garnier", pid = 83218, tid = 58, kind = 'perm', wage = 5500, months = 36 },
    { n = "Junior Mwanga", pid = 269184, tid = 1738, kind = 'perm', wage = 22000, months = 36 },
    { n = "Oliver Sorg", pid = 74112, tid = 780, kind = 'perm', wage = 3000, months = 36 },
    { n = "Alessandro Dellavalle", pid = 72097, tid = 110912, kind = 'loan', months = 11, buy = 0 },
    { n = "Thorsten Schriebl", pid = 72541, tid = 111822, kind = 'perm', wage = 5500, months = 36 },
    { n = "Brooklyn Ezeh", pid = 262117, tid = 503, kind = 'perm', wage = 7000, months = 36 },
}

function main()
    log("== PART 6 START (68 entries) ==")
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
    log("== PART 6 DONE ==")
end

main()
