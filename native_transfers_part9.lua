-- native_transfers_part9.lua -- cTransferPlayer/cLoanPlayer path, verify-skip, idempotent
local LOG_PATH = "C:/fc26-mcp/native_transfers_log.txt"
local NL = string.char(10)
local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. NL) f:close() end
end

local T = {
    { n = "Giovanni Reyna", pid = 245541, tid = 76, kind = 'perm', wage = 22000, months = 36 },
    { n = "Tommaso Maggioni", pid = 72857, tid = 112124, kind = 'perm', wage = 7000, months = 36 },
    { n = "Cisse Sandra", pid = 260577, tid = 681, kind = 'perm', wage = 9000, months = 36 },
    { n = "Joël Drommel", pid = 228279, tid = 1908, kind = 'perm', wage = 22000, months = 36 },
    { n = "Ahmed Abdullahi", pid = 274219, tid = 131174, kind = 'perm', wage = 3000, months = 36 },
    { n = "Max Arfsten", pid = 274535, tid = 12, kind = 'perm', wage = 22000, months = 36 },
    { n = "Afimico Pululu", pid = 239267, tid = 113222, kind = 'perm', wage = 22000, months = 36 },
    { n = "Kamil Lukoszek", pid = 276877, tid = 111097, kind = 'loan', months = 11, buy = 0 },
    { n = "Alessandro Debenedetti", pid = 73928, tid = 110915, kind = 'loan', months = 11, buy = 0 },
    { n = "Paulo Bernardo", pid = 263439, tid = 420, kind = 'loan', months = 11, buy = 0 },
    { n = "Khalil Ayari", pid = 84604, tid = 111276, kind = 'loan', months = 11, buy = 0 },
    { n = "Tobías Reinhart", pid = 254804, tid = 15029, kind = 'perm', wage = 9000, months = 36 },
    { n = "Darlin Yongwa", pid = 253490, tid = 1792, kind = 'perm', wage = 16000, months = 36 },
    { n = "Ibrahim Salah", pid = 270828, tid = 230, kind = 'loan', months = 11, buy = 0 },
    { n = "Gauthier Hein", pid = 234239, tid = 72, kind = 'perm', wage = 40000, months = 36 },
    { n = "Rubén Botta", pid = 215199, tid = 111325, kind = 'perm', wage = 30000, months = 36 },
    { n = "Kyrell Wilson", pid = 272617, tid = 674, kind = 'perm', wage = 4500, months = 36 },
    { n = "Antonio Fiori", pid = 72861, tid = 110915, kind = 'loan', months = 11, buy = 0 },
    { n = "Felix Horn Myhre", pid = 237937, tid = 109, kind = 'perm', wage = 30000, months = 36 },
    { n = "Jesper Daland", pid = 256459, tid = 300, kind = 'loan', months = 6, buy = 0 },
    { n = "Leon Hien", pid = 256429, tid = 418, kind = 'loan', months = 6, buy = 0 },
    { n = "Bruce Anderson", pid = 245174, tid = 621, kind = 'perm', wage = 7000, months = 36 },
    { n = "Daisuke Yokota", pid = 274191, tid = 86, kind = 'perm', wage = 16000, months = 36 },
    { n = "Mikaël Mandron", pid = 204785, tid = 1931, kind = 'perm', wage = 7000, months = 36 },
    { n = "Alan Rodríguez", pid = 253233, tid = 110580, kind = 'loan', months = 11, buy = 0 },
    { n = "Christian Früchtl", pid = 235266, tid = 191, kind = 'perm', wage = 16000, months = 36 },
    { n = "Bilal Boutobba", pid = 226295, tid = 131174, kind = 'perm', wage = 12000, months = 36 },
    { n = "Ibane Bowat", pid = 276677, tid = 1939, kind = 'perm', wage = 9000, months = 36 },
    { n = "Liam Thompson", pid = 263918, tid = 1940, kind = 'perm', wage = 9000, months = 36 },
    { n = "Jack Moylan", pid = 261861, tid = 1961, kind = 'perm', wage = 9000, months = 36 },
    { n = "Ben Amos", pid = 173531, tid = 1796, kind = 'perm', wage = 5500, months = 36 },
    { n = "Mason Melia", pid = 276346, tid = 149, kind = 'loan', months = 11, buy = 0 },
    { n = "Ben Whiteman", pid = 225071, tid = 1947, kind = 'perm', wage = 22000, months = 36 },
    { n = "Dion Lopy", pid = 259190, tid = 607, kind = 'perm', wage = 22000, months = 36 },
    { n = "Mohamed Salah", pid = 209331, tid = 436, kind = 'perm', wage = 185000, months = 36 },
    { n = "Yan Diomande", pid = 78012, tid = 243, kind = 'perm', wage = 68000, months = 36 },
    { n = "Jonathan Moalem", pid = 79034, tid = 922, kind = 'loan', months = 11, buy = 0 },
    { n = "Juanlu Sánchez", pid = 264174, tid = 1943, kind = 'perm', wage = 30000, months = 36 },
    { n = "Joël Veltman", pid = 208004, tid = 19, kind = 'perm', wage = 53000, months = 36 },
    { n = "Igor Drapinski", pid = 263036, tid = 748, kind = 'perm', wage = 9000, months = 36 },
    { n = "Javi Morcillo", pid = 85082, tid = 468, kind = 'perm', wage = 5500, months = 36 },
    { n = "Unai Núñez", pid = 240900, tid = 452, kind = 'loan', months = 11, buy = 0 },
    { n = "Awer Mabil", pid = 212830, tid = 112224, kind = 'perm', wage = 12000, months = 36 },
    { n = "Christian Nørgaard", pid = 210697, tid = 7, kind = 'perm', wage = 68000, months = 36 },
    { n = "Francisco Ortega", pid = 242287, tid = 1876, kind = 'perm', wage = 22000, months = 36 },
    { n = "Lyndon Dykes", pid = 247279, tid = 97, kind = 'perm', wage = 12000, months = 36 },
    { n = "Wes Burns", pid = 212484, tid = 95, kind = 'perm', wage = 22000, months = 36 },
    { n = "Filip Kostic", pid = 208574, tid = 247, kind = 'perm', wage = 68000, months = 36 },
    { n = "Wesley", pid = 74913, tid = 111325, kind = 'perm', wage = 12000, months = 36 },
    { n = "Luciano Rodríguez", pid = 273604, tid = 568, kind = 'loan', months = 12, buy = 0 },
    { n = "João Costa", pid = 73629, tid = 568, kind = 'loan', months = 11, buy = 0 },
    { n = "Domingos Duarte", pid = 234835, tid = 598, kind = 'perm', wage = 30000, months = 36 },
    { n = "Junior Dina Ebimbe", pid = 248573, tid = 34, kind = 'perm', wage = 22000, months = 36 },
    { n = "Ross Stewart", pid = 244319, tid = 1960, kind = 'perm', wage = 16000, months = 36 },
    { n = "Bersant Celina", pid = 220198, tid = 112096, kind = 'perm', wage = 16000, months = 36 },
    { n = "Nathaniel Chalobah", pid = 205897, tid = 89, kind = 'perm', wage = 12000, months = 36 },
    { n = "Metehan Altunbas", pid = 260459, tid = 101032, kind = 'perm', wage = 4500, months = 36 },
    { n = "Josep Cerdà", pid = 79751, tid = 453, kind = 'perm', wage = 9000, months = 36 },
    { n = "Nicolás Valentini", pid = 267681, tid = 463, kind = 'perm', wage = 22000, months = 36 },
    { n = "Nicholas Opoku", pid = 245022, tid = 472, kind = 'perm', wage = 12000, months = 36 },
    { n = "Lewis Temple", pid = 270118, tid = 1920, kind = 'loan', months = 11, buy = 0 },
    { n = "Jens Hjertø-Dahl", pid = 274979, tid = 1952, kind = 'perm', wage = 12000, months = 36 },
    { n = "Finley Barbrook", pid = 80501, tid = 79, kind = 'loan', months = 11, buy = 0 },
    { n = "Delano Burgzorg", pid = 243619, tid = 1801, kind = 'loan', months = 11, buy = 0 },
    { n = "Jay Robinson", pid = 78184, tid = 111811, kind = 'loan', months = 11, buy = 0 },
    { n = "Takehiro Tomiyasu", pid = 232938, tid = 1799, kind = 'perm', wage = 40000, months = 36 },
    { n = "Bjarki Steinn Bjarkason", pid = 258533, tid = 112494, kind = 'perm', wage = 12000, months = 36 },
    { n = "Marco Pompetti", pid = 237613, tid = 110912, kind = 'perm', wage = 12000, months = 36 },
}

function main()
    log("== PART 9 START (68 entries) ==")
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
    log("== PART 9 DONE ==")
end

main()
