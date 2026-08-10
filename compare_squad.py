"""Compare fotmob transfers (window) against the current squad file.

Verdicts:
  DONE          - player is in toClub in the file (teamplayerlinks)
  NOT_DONE      - player still at fromClub in the file
  ELSEWHERE     - player found but at a third team
  NO_CLUB       - to/from club not present in the squad file (e.g. non-FC26 club)
  NO_PLAYER     - name not resolvable offline (game-DB name, outside mod pool)
"""
import json, re, sys, unicodedata
sys.path.insert(0, 'src')
from fc26_mcp.fifa_squad import SquadFile

SQ = r"C:\Users\Afjal\AppData\Local\EA SPORTS FC 26\settings\SquadsFIFER'sBeta4xRODE'sNewSeasonModAlpha4"
META = "src/fc26_mcp/data/fifa_ng_db-meta-fc26.xml"
TRANSFERS = "fotmob_jul14_aug.json"
OUT_JSON = "transfer_compare_results.json"
OUT_TXT = "transfer_compare_results.txt"

def norm(s):
    s = unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode()
    s = s.lower().replace("'", "").replace(".", "").replace("-", " ")
    return re.sub(r'\s+', ' ', s).strip()

sf = SquadFile(SQ, META)
pc = sf.player_clubs()

# team name lookup (accent/case insensitive)
team_by_name = {}
for t in sf.get_table('teams'):
    n = t.get('teamname')
    if n:
        team_by_name.setdefault(norm(n), t.get('teamid'))

# player name pool (in-file names only)
names = {r['nameid']: r['name'] for r in sf.get_table('dcplayernames')}

# playerid -> current teamid (team playerlinks: keep first/last link; prefer the
# row that is NOT a loan row when a player has multiple)
link_rows = sf.get_table('teamplayerlinks')
player_team = {}
for lr in link_rows:
    player_team.setdefault(lr['playerid'], lr['teamid'])
print('player_team entries:', len(player_team))

# resolvable player name -> playerid  (display exact match)
player_by_name = {}
for p in sf.get_table('players'):
    pid = p['playerid']
    fn = names.get(p.get('firstnameid', 0), '')
    ln = names.get(p.get('lastnameid', 0), '')
    cn = names.get(p.get('commonnameid', 0), '')
    display = cn or f"{fn} {ln}".strip()
    if display:
        key = norm(display)
        if key not in player_by_name:
            player_by_name[key] = pid
print('resolvable player displays:', len(player_by_name))

def club_name(teamid):
    r = next((t for t in sf.get_table('teams') if t.get('teamid') == teamid), None)
    return r.get('teamname') if r else None

with open(TRANSFERS, encoding='utf-8') as f:
    data = json.load(f)
transfers = data['transfers']
print('transfers to check:', len(transfers))

results = []
stats = {}
for t in transfers:
    name = t.get('name', '')
    to = (t.get('toClubFullName') or t.get('toClub') or '')
    frm = (t.get('fromClubFullName') or t.get('fromClub') or '')
    to_id = t.get('toClubId'); from_id = t.get('fromClubId')
    date = (t.get('transferDate') or '')[:10]
    fee = (t.get('fee') or {})
    fee_text = fee.get('localizedFeeText') if isinstance(fee, dict) else ''
    fee_val = fee.get('value') if isinstance(fee, dict) else None
    onloan = bool(t.get('onLoan'))

    to_team_id = team_by_name.get(norm(to))
    from_team_id = team_by_name.get(norm(frm))
    to_free = norm(to) == 'free agent'
    from_free = norm(frm) == 'free agent'
    verdict = None; detail = ''
    if not to_team_id and not to_free: verdict, detail = 'NO_CLUB', f'toClub "{to}" not found'
    elif not from_team_id and not from_free and not onloan:
        verdict, detail = 'NO_CLUB', f'fromClub "{frm}" not found'
    else:
        pid = player_by_name.get(norm(name))
        if not pid:
            # last-resort: unique surname tokens
            key = norm(name).split()[-1] if norm(name) else ''
            cands = [k for k in player_by_name if key and k.endswith(' ' + key)]
            pid = player_by_name[cands[0]] if len(cands) == 1 else None
            detail = ('surname-only' if pid else 'no in-file resolver name (game DB name)')
        if not pid:
            verdict = 'NO_PLAYER'
        else:
            cur = player_team.get(pid)
            if cur is None:
                verdict = 'NO_PLAYER'; detail = 'player has no club in file'
            elif to_free:
                verdict = 'DONE' if cur is None else ('NOT_DONE' if cur == from_team_id else 'ELSEWHERE')
            elif from_free:
                verdict = 'DONE' if cur == to_team_id else ('NOT_DONE' if cur is None else 'ELSEWHERE')
            elif cur == to_team_id:
                verdict = 'DONE'
            elif cur == from_team_id:
                verdict = 'NOT_DONE'
            else:
                verdict = 'ELSEWHERE'
            detail += f' | current teamid {cur} "{club_name(cur)}"'
    stats[verdict] = stats.get(verdict, 0) + 1
    results.append({
        'name': name, 'date': date, 'onLoan': onloan,
        'fromClub': frm, 'toClub': to,
        'fee': fee_val / 1_000_000 if fee_val else None,
        'feeType': fee_text,
        'verdict': verdict, 'detail': detail,
        'fotmobPlayerId': t.get('playerId'),
    })

json.dump({'window': data.get('window_from'), 'counts': stats,
           'transfers': results},
          open(OUT_JSON, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

def line(r):
    return "{:12s} {:28s} {:8s} {:26s} -> {:<26s} {}".format(
        r['date'], (r['name'] or '')[:28], r['verdict'] or '?',
        (r['fromClub'] or '')[:26], (r['toClub'] or '')[:26], (r['detail'] or '')[:60])

order = ['DONE', 'NOT_DONE', 'ELSEWHERE', 'NO_PLAYER', 'NO_CLUB']
with open(OUT_TXT, 'w', encoding='utf-8') as f:
    f.write('verdict counts: ' + json.dumps(stats) + '\n\n')
    for v in order:
        f.write(f'\n===== {v} ({stats.get(v, 0)}) =====\n')
        for r in results:
            if r['verdict'] == v:
                f.write(line(r) + '\n')

print('verdicts:', json.dumps(stats))
for v in order:
    print(f'  {v}: {stats.get(v, 0)}')
print('wrote', OUT_JSON, OUT_TXT)