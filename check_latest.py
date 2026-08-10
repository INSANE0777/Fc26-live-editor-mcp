import json, sys
sys.path.insert(0, "C:/fc26-mcp/src")
from fc26_mcp import mcp_le_bridge

mcp_le_bridge.set_bridge_root("C:/Users/Afjal/Downloads/Example folder - Copy/LE/FC 26 LE v26.3.5/le_bridge")

def call(method, args):
    return mcp_le_bridge.send_command(method, args)

def search_player(name):
    res = call("search_players", {"name": name, "limit": 5})
    if res.get("success") and res.get("count", 0) > 0:
        return res["players"][0]
    return None

def get_team_name(teamid):
    res = call("execute_lua", {"code": f"local rows=GetDBTableRows('teams') or {{}} for _,row in ipairs(rows) do if tonumber(row.teamid.value)=={teamid} then return tostring(row.teamname.value) end end return 'unknown'"})
    if res.get("success"):
        return res.get("result", "unknown")
    return "unknown"

def norm(s):
    return s.lower().replace("manchester", "man").replace("fc", "").replace("utd", "united").strip()

with open("C:/fc26-mcp/fotmob_latest.json", "r", encoding="utf-8") as f:
    data = json.load(f)

transfers = data.get("transfers", [])

print("=== CHECKING FOTMOB TRANSFERS AGAINST CURRENT SAVE ===")
needs_move = []
already_done = []
not_in_db = []

for t in transfers:
    name = t.get("name", "")
    to_club = t.get("toClub", "")
    from_club = t.get("fromClub", "")
    player = search_player(name)
    if not player:
        not_in_db.append(name)
        continue
    res = call("execute_lua", {"code": f"local links=GetDBTableRows('teamplayerlinks') or {{}} for _,link in ipairs(links) do if tonumber(link.playerid.value)=={player['playerid']} then return tonumber(link.teamid.value) end end return nil"})
    if res.get("success") and res.get("result") is not None:
        current_teamid = res["result"]
        current_team = get_team_name(current_teamid)
    else:
        current_team = "Free agent"
    
    exp_norm = norm(to_club)
    cur_norm = norm(current_team)
    if exp_norm in cur_norm or cur_norm in exp_norm or (to_club.lower() == "free agent" and current_team == "Free agent"):
        already_done.append((name, to_club, current_team))
    else:
        needs_move.append((name, player['playerid'], to_club, current_team))

print(f"\nALREADY APPLIED ({len(already_done)}):")
for name, exp, cur in already_done:
    print(f"  OK {name} -> {exp} (current: {cur})")

print(f"\nNEEDS MOVE ({len(needs_move)}):")
for name, pid, exp, cur in needs_move:
    print(f"  MOVE {name} (ID {pid}) -> {exp} (current: {cur})")

print(f"\nNOT IN DB ({len(not_in_db)}):")
for name in not_in_db:
    print(f"  MISSING {name}")

# Save results
with open("C:/fc26-mcp/check_latest_results.json", "w", encoding="utf-8") as f:
    json.dump({"already_done": already_done, "needs_move": needs_move, "not_in_db": not_in_db}, f, indent=2)
