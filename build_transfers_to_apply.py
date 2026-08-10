"""Generate transfers_to_apply.json from the NOT_DONE popular transfers.

Each entry carries everything apply_transfers.lua needs:
  { name, pid, tid (target club in save), kind: perm|loan,
    fromTeam (parent club for loans), feeM,
    contractEnd (year)  — perm only,
    joinSerial (deal date as Gregorian serial) — perm only,
    loanEndSerial, loanBuy (0/1) — loan only }

Contract rules (no career tables in squads saves):
  - permanent/free: contractvaliduntil = 2026 + 4y, clamped to 2029 for 31+;
    playerjointeamdate = transfer date serial.
  - loan: contractvaliduntil untouched; loan row = parent club + toDate serial.
"""
import json, sys, glob, csv
from datetime import date, timedelta
sys.path.insert(0, 'src')
from fc26_mcp.fifa_squad import SquadFile

SQ = glob.glob(r"C:\Users\Afjal\AppData\Local\EA SPORTS FC 26\settings\SquadsFIFER*Alpha4")[0]
META = r"src\fc26_mcp\data\fifa_ng_db-meta-fc26.xml"
sf = SquadFile(SQ, META)

pool = {r['nameid']: r['name'] for r in sf.get_table('dcplayernames')}
db = {}
for row in csv.DictReader(open(r"C:\Users\Afjal\Downloads\Example folder - Copy\playernames.txt",
                               encoding='utf-8', errors='replace'), delimiter='\t'):
    try: db[int(row['nameid'])] = row['name']
    except: pass
def rev(nid): return pool.get(nid) or db.get(nid or 0, '')

tnames = {t['teamid']: t['teamname'] for t in sf.get_table('teams')}
pt = {}
for l in sf.get_table('teamplayerlinks'):
    pt.setdefault(l['playerid'], l['teamid'])

players = {}
for p in sf.get_table('players'):
    players[p['playerid']] = (rev(p.get('commonnameid', 0)) or
                              (rev(p.get('firstnameid', 0)) + ' ' + rev(p.get('lastnameid', 0))).strip(), p)

EPOCH = date(1582, 10, 15)
def serial(d): return (d - EPOCH).days
def age_years(p):
    bd = p.get('birthdate')
    if not bd: return None
    try: by = (EPOCH + timedelta(days=int(bd))).year
    except Exception: return None
    return 2026 - by

# current club ids from the save, named like compare_full's club_of
def norm(s):
    import unicodedata, re
    s = unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode().lower()
    return re.sub(r'[^a-z0-9 ]', ' ', s).strip()

team_by_name = {}
for t in sf.get_table('teams'):
    n = t.get('teamname')
    if n: team_by_name.setdefault(norm(n), t['teamid'])
ALIASES = {
    'inter': 'lombardia fc', 'internazionale': 'lombardia fc',
    'milan': 'milano fc', 'ac milan': 'milano fc',
    'bayer leverkusen': 'bayer 04 leverkusen',
    'atletico madrid': 'atletico de madrid', 'atlético madrid': 'atletico de madrid',
    'lyon': 'olympique lyonnais',
    'borussia monchengladbach': "borussia m'gladbach", 'monchengladbach': "borussia m'gladbach",
    'wolfsburg': 'vfl wolfsburg', 'stuttgart': 'vfb stuttgart',
    'strasbourg': 'rc strasbourg', 'nantes': 'fc nantes', 'monaco': 'as monaco',
    'marseille': 'olympique de marseille', 'nice': 'ogc nice', 'lille': 'losc lille',
    'lens': 'rc lens', 'roma': 'roma', 'porto': 'fc porto', 'benfica': 'benfica',
    'barcelona': 'fc barcelona',
    'sporting cp': 'sporting cp', 'sporting braga': 'sporting de braga', 'braga': 'sporting de braga',
    'leicester': 'leicester city', 'hull': 'hull city',
    'fenerbahçe': 'fenerbahçe', 'fenerbahce': 'fenerbahçe',
}
def club_of(name):
    n = norm(name)
    if n in team_by_name: return team_by_name[n]
    a = ALIASES.get(n)
    if a and a in team_by_name: return team_by_name[a]
    cands = [k for k in team_by_name if n and len(n) >= 4 and (n in k or k in n)]
    return team_by_name[cands[0]] if len(cands) == 1 else None

NAME_ALIASES = {
    'kang-in lee': 243780, 'lee kang-in': 243780,
    'gonzalo garcia': 278399,
}

results = json.load(open('transfer_compare_full.json', encoding='utf-8'))['transfers']
src_by_name = {}
for t in json.load(open('fotmob_popular_latest.json', encoding='utf-8'))['transfers']:
    # key by (name, date) — a player can have both a perm move and a later loan
    src_by_name[(t['name'], (t.get('transferDate') or '')[:10])] = t

out = []
for r in results:
    if r['verdict'] not in ('NOT_DONE',):
        continue
    name, to, frm = r['name'], r['toClub'], r['fromClub']
    s = src_by_name.get((name, r['date'])) or src_by_name.get((name, '')) or {}
    onloan = bool(s.get('onLoan'))
    kind = 'loan' if onloan else 'perm'

    pid = None
    # re-resolve like compare_full's resolver
    nkey = norm(name)
    pn = {norm(d): pid for pid, (d, p) in players.items()}
    pid = pn.get(nkey) or NAME_ALIASES.get(nkey)
    if not pid and nkey:
        toks = nkey.split()
        if len(toks) >= 3:
            pid = pn.get(' '.join([toks[-1], toks[1], toks[0]])) or pn.get(' '.join([toks[-1]] + toks[:-1]))
    if not pid:
        key = nkey.split()[-1] if nkey else ''
        cands = [k for k in pn if key and k.endswith(' ' + key)]
        pid = pn[cands[0]] if len(cands) == 1 else None
    if not pid:
        print('SKIP (no pid):', name); continue

    tid = club_of(to)
    from_tid = club_of(frm)
    cur_tid = pt.get(pid)
    if tid is None:
        print('SKIP (no to-club):', name, '->', to); continue

    entry = {'name': name, 'pid': pid, 'tid': tid, 'kind': kind,
             'from': frm, 'to': to,
             'pidConfirmedBy': 'file', 'fromTeam': from_tid}
    fee = (s.get('fee') or {}).get('value')
    entry['feeM'] = round(fee / 1e6, 1) if fee else None

    if kind == 'loan':
        toDate = (s.get('toDate') or '2027-06-30T00:00:00Z')[:10]
        y, m, d = map(int, toDate.split('-'))
        entry['loanEndSerial'] = serial(date(y, m, d))
        entry['loanParent'] = from_tid or cur_tid or 111592
        entry['loanBuy'] = 1 if fee else 0
    else:
        _, p = players.get(pid, (None, None))
        a = age_years(p) if p else None
        end = 2030 if (a is None or a < 31) else 2029
        entry['contractEndYear'] = end
        td = (s.get('fromDate') or '2026-08-09T00:00:00Z')[:10]
        y, m, d = map(int, td.split('-'))
        entry['joinSerial'] = serial(date(y, m, d))
    out.append(entry)

json.dump(out, open('transfers_to_apply.json', 'w', encoding='utf-8'),
          ensure_ascii=False, indent=1)
print('wrote %d transfers' % len(out))
for e in out:
    print('  %-6s %-24s pid=%-7s tid=%-6s %s' % (e['kind'], e['name'][:24], e['pid'], e['tid'], e.get('loanParent') and 'parent=%s' % e['loanParent'] or 'end=%s' % e.get('contractEndYear')))