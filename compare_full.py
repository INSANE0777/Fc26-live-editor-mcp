"""Compare fotmob transfers against the current squad file, using the FULL
name table exported from fifa_ng_db (playernames.txt) to resolve player names.

Verdicts:
  DONE          - player already at toClub in the file
  NOT_DONE      - player still at fromClub in the file
  ELSEWHERE     - player found but at a third team
  NO_CLUB       - to/from club not in the squad file (non-FC26 club or bogus)
  NO_PLAYER     - player name not found in the game DB / squad
"""
import json, re, sys, unicodedata, csv, os
sys.path.insert(0, 'src')
from fc26_mcp.fifa_squad import SquadFile

SQ = r"C:\Users\Afjal\AppData\Local\EA SPORTS FC 26\settings\SquadsFIFER'sBeta4xRODE'sNewSeasonModAlpha4"
META = "src/fc26_mcp/data/fifa_ng_db-meta-fc26.xml"
BASE_DIR = r"C:\Users\Afjal\Downloads\Example folder - Copy"
TRANSFERS = "fotmob_jul14_aug.json"
OUT_JSON = "transfer_compare_full.json"
OUT_TXT = "transfer_compare_full.txt"

def norm(s):
    s = unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode()
    s = s.lower().replace("'", "").replace(".", "").replace("-", " ")
    return re.sub(r'\s+', ' ', s).strip()

# 1) full game name table
db_names = {}
with open(f"{BASE_DIR}/playernames.txt", encoding='utf-8', errors='replace') as f:
    rd = csv.DictReader(f, delimiter='\t')
    for row in rd:
        try:
            db_names[int(row['nameid'])] = row['name']
        except (ValueError, KeyError):
            pass
print('game name table:', len(db_names))

sf = SquadFile(SQ, META)
# squad pool (mod-added names take priority over base db)
pool = {r['nameid']: r['name'] for r in sf.get_table('dcplayernames')}
def resolve(nid):
    return pool.get(nid) or db_names.get(nid or 0, '')

# 2) teams: name -> teamid (prefer base/real team: default to first found)
team_by_name = {}
teams = sf.get_table('teams')
for t in teams:
    n = t.get('teamname')
    if n:
        team_by_name.setdefault(norm(n), t.get('teamid'))

# 3) players -> display name -> playerid
players = sf.get_table('players')
player_by_name = {}
for p in players:
    pid = p['playerid']
    fn = resolve(p.get('firstnameid', 0))
    ln = resolve(p.get('lastnameid', 0))
    cn = resolve(p.get('commonnameid', 0))
    display = cn or f"{fn} {ln}".strip()
    if display:
        key = norm(display)
        if key not in player_by_name:
            player_by_name[key] = pid
print('resolvable player displays:', len(player_by_name), '/', len(players))

# 4) player -> current team (teamplayerlinks in squad)
player_team = {}
for lr in sf.get_table('teamplayerlinks'):
    player_team.setdefault(lr['playerid'], lr['teamid'])

team_name_of_id = {t['teamid']: t['teamname'] for t in teams}

# licensed-name aliases (mod uses EA-style names: Inter = Lombardia FC, AC Milan = Milano FC)
ALIASES = {
    'inter': 'lombardia fc', 'internazionale': 'lombardia fc',
    'milan': 'milano fc', 'ac milan': 'milano fc',
    'bayer leverkusen': 'bayer 04 leverkusen',
    'atletico madrid': 'atletico de madrid', 'atlético madrid': 'atletico de madrid',
    'lyon': 'olympique lyonnais',
    'barcelona': 'fc barcelona',
    'borussia monchengladbach': "borussia m'gladbach", 'monchengladbach': "borussia m'gladbach",
    'wolfsburg': 'vfl wolfsburg', 'stuttgart': 'vfb stuttgart',
    'strasbourg': 'rc strasbourg', 'nantes': 'fc nantes', 'monaco': 'as monaco',
    'marseille': 'olympique de marseille', 'nice': 'ogc nice', 'lille': 'losc lille',
    'lens': 'rc lens', 'roma': 'roma', 'porto': 'fc porto', 'benfica': 'benfica',
    'sporting cp': 'sporting cp', 'sporting braga': 'sporting de braga', 'braga': 'sporting de braga',
    'manchester city': 'manchester city', 'manchester united': 'manchester united',
    'brighton & hove albion': 'brighton & hove albion', 'newcastle united': 'newcastle united',
    'leicester': 'leicester city', 'leeds united': 'leeds united', 'hull': 'hull city',
    'trabzonspor': 'trabzonspor', 'fenerbahçe': 'fenerbahçe', 'fenerbahce': 'fenerbahçe',
}

def club_of(name):
    n = norm(name)
    if n in team_by_name:
        return team_by_name[n]
    a = ALIASES.get(n)
    if a and a in team_by_name:
        return team_by_name[a]
    cands = [k for k in team_by_name if n and len(n) >= 4 and (n in k or k in n)]
    return team_by_name[cands[0]] if len(cands) == 1 else None

def cur_team_of(pid):
    tid = player_team.get(pid)
    return tid, team_name_of_id.get(tid)

# names that don't resolve as written (Korean order, common-name only)
NAME_ALIASES = {
    'kang-in lee': 243780,   # in-game: Lee Kang In, pid verified at Atlético de Madrid
    'lee kang-in': 243780,
    'gonzalo garcia': 278399,  # in-game: Gonzalo (Gonzalo García Torres)
}

with open(TRANSFERS, encoding='utf-8') as f:
    data = json.load(f)
transfers = data['transfers']
if os.environ.get('POPULAR_ONLY'):
    pop = json.load(open('fotmob_popular_latest.json', encoding='utf-8'))['transfers']
    transfers = [t for t in pop if (t.get('transferDate') or '')[:10] >= '2026-07-14']
print('transfers to check:', len(transfers))

results, stats = [], {}
for t in transfers:
    name = t.get('name', '')
    to = (t.get('toClubFullName') or t.get('toClub') or '')
    frm = (t.get('fromClubFullName') or t.get('fromClub') or '')
    date = (t.get('transferDate') or '')[:10]
    fee = (t.get('fee') or {})
    fee_val = fee.get('value') if isinstance(fee, dict) else None
    onloan = bool(t.get('onLoan'))

    nto, nfrm = norm(to), norm(frm)
    to_free = nto == 'free agent'
    from_free = nfrm == 'free agent'
    verdict = None; detail = ''
    to_tid = club_of(to)
    from_tid = club_of(frm)
    # find the player first: name variants (Korean/Chinese surname-first, initial+common-name)
    pid = player_by_name.get(norm(name))
    if not pid:
        pid = NAME_ALIASES.get(norm(name))
    if not pid:
        toks = norm(name).split()
        if len(toks) >= 3:
            pid = player_by_name.get(' '.join([toks[-1], toks[1], toks[0]])) or player_by_name.get(' '.join([toks[-1], *toks[:-1]]))
    if not pid:
        key = norm(name).split()[-1] if norm(name) else ''
        cands = [k for k in player_by_name if key and k.endswith(' ' + key)]
        pid = player_by_name[cands[0]] if len(cands) == 1 else None
        detail = 'surname-only' if pid else 'name not found in game DB'
    if not pid:
        verdict = 'NO_PLAYER'
    else:
        cur_tid, cur_name = cur_team_of(pid)
        if cur_tid is None:
            verdict = 'NO_PLAYER'; detail = 'no club in file (playerid %s)' % pid
        else:
            if to_free:
                verdict = 'DONE' if cur_tid is None else ('NOT_DONE' if cur_tid == from_tid else 'ELSEWHERE')
            elif from_free:
                verdict = 'DONE' if cur_tid == to_tid else ('NOT_DONE' if cur_tid is None else 'ELSEWHERE')
            elif cur_tid == to_tid:
                verdict = 'DONE'
            elif cur_tid == from_tid:
                verdict = 'NOT_DONE'
            elif to_tid is None and from_tid is not None:
                # only destination unknown: not at from club -> cannot confirm move
                verdict = 'ELSEWHERE' if cur_tid != from_tid else 'NOT_DONE'
            elif from_tid is None and to_tid is not None:
                verdict = 'DONE' if cur_tid == to_tid else 'ELSEWHERE'
            else:
                # neither club resolvable but player found: compare names
                cur_n = norm(cur_name or '')
                if nto and nto in cur_n:
                    verdict = 'DONE'
                elif nfrm and nfrm in cur_n:
                    verdict = 'NOT_DONE'
                else:
                    verdict = 'ELSEWHERE' if (nto and nfrm) else 'NO_CLUB'
                    if verdict == 'NO_CLUB':
                        detail = 'clubs not found in squad'
            detail += ('' if detail.startswith('|') or 'current team' in detail else (' | current team: "%s"' % cur_name) if cur_name else '')
    stats[verdict] = stats.get(verdict, 0) + 1
    results.append({
        'name': name, 'date': date, 'onLoan': onloan,
        'fromClub': frm, 'toClub': to,
        'feeM': round(fee_val / 1e6, 1) if fee_val else None,
        'verdict': verdict, 'detail': detail,
        'fotmobPlayerId': t.get('playerId'),
    })

json.dump({'window_from': data.get('window_from'), 'counts': stats,
           'transfers': results},
          open(OUT_JSON, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

def line(r):
    return "{:10s} {:10s} {:26s} {:24s} -> {:<26s} {}".format(
        r['date'], r['verdict'] or '?', (r['name'] or '')[:26],
        (r['fromClub'] or '')[:24], (r['toClub'] or '')[:26], (r['detail'] or '')[:50])

with open(OUT_TXT, 'w', encoding='utf-8') as f:
    f.write('counts: ' + json.dumps(stats) + '\n\n')
    for v in ['DONE', 'NOT_DONE', 'ELSEWHERE', 'NO_PLAYER', 'NO_CLUB']:
        f.write(f'\n===== {v} ({stats.get(v, 0)}) =====\n')
        for r in results:
            if r['verdict'] == v:
                f.write(line(r) + '\n')

print('verdicts:', json.dumps(stats))
for v in ['DONE', 'NOT_DONE', 'ELSEWHERE', 'NO_PLAYER', 'NO_CLUB']:
    print(f'  {v}: {stats.get(v, 0)}')
print('wrote', OUT_JSON, OUT_TXT)