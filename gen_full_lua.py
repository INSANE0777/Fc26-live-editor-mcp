"""Generate apply_transfers_full.lua from transfers_full_apply.json.

Approximate FC26-style weekly wage from the player's overallrating (the
game computes wages from rating); release clause none (-1), role Rotation
(3), bonus NONE (0) by default. Keeps the exact skeleton of the known-good
apply_transfers.lua and replaces ONLY the TRANSFERS table.
"""
import json, re, sys
from datetime import date
import unicodedata

apply_set = json.load(open('transfers_full_apply.json', encoding='utf-8'))

EPOCH = date(1582, 10, 15)
def serial(d): return (d - EPOCH).days

src = json.load(open('fotmob_jul14_aug.json', encoding='utf-8'))['transfers']
by_key = {}
for t in src:
    by_key[(t['name'], (t.get('transferDate') or '')[:10])] = t

SQ = r"C:\Users\Afjal\AppData\Local\EA SPORTS FC 26\settings\SquadsFIFER'sBeta4xRODE'sNewSeasonModAlpha4"
META = "src/fc26_mcp/data/fifa_ng_db-meta-fc26.xml"
sys.path.insert(0, 'src')
from fc26_mcp.fifa_squad import SquadFile
sf = SquadFile(SQ, META)

ovr = {}
for p in sf.get_table('players'):
    o = p.get('overallrating')
    if o is not None:
        ovr[p['playerid']] = int(o)

# FC-style weekly wage by OVR (approximation; values in career currency)
def fc_wage(ov):
    if ov >= 90: return 240000
    if ov >= 88: return 185000
    if ov >= 86: return 145000
    if ov >= 84: return 110000
    if ov >= 82: return 88000
    if ov >= 80: return 68000
    if ov >= 78: return 53000
    if ov >= 76: return 40000
    if ov >= 74: return 30000
    if ov >= 72: return 22000
    if ov >= 70: return 16000
    if ov >= 68: return 12000
    if ov >= 66: return 9000
    if ov >= 64: return 7000
    if ov >= 62: return 5500
    if ov >= 60: return 4500
    return 3000

FREE = 111592  # NG - FA

def club_of_name_map():
    def norm(s):
        s = unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode()
        s = s.lower().replace("'", "").replace(".", "").replace("-", " ")
        return re.sub(r'\s+', ' ', s).strip()
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
    }
    def club_of(name):
        n = norm(name)
        if n in team_by_name: return team_by_name[n]
        a = ALIASES.get(n)
        if a and a in team_by_name: return team_by_name[a]
        cands = [k for k in team_by_name if n and len(n) >= 4 and (n in k or k in n)]
        return team_by_name[cands[0]] if len(cands) == 1 else None
    return club_of

club_of = club_of_name_map()

lines = ['local TRANSFERS = {']
n_perm = n_loan = 0
for t in apply_set:
    pid, tid = t['pid'], t['tid']
    s = by_key.get((t['name'], t['date'])) or {}
    if t['onLoan']:
        toDate = (s.get('toDate') or '2027-06-30T00:00:00Z')[:10]
        y, m, d = map(int, toDate.split('-'))
        endSer = serial(date(y, m, d))
        parent = club_of(t.get('fromClub')) or t.get('curTeamId') or FREE
        buy = 1 if (s.get('fee') or {}).get('value') else 0
        lines.append(
            "    { name = %r, to = %r, pid = %d, tid = %d, kind = 'loan', "
            "loanParent = %d, loanEndSerial = %d, loanBuy = %d }," %
            (t['name'], t['toClub'], pid, tid, parent, endSer, buy))
        n_loan += 1
    else:
        o = ovr.get(pid, 60)
        endY = 2029
        wage = fc_wage(o)
        jd = (s.get('transferDate') or '2026-08-09T00:00:00Z')[:10]
        y0, m0, d0 = map(int, jd.split('-'))
        js = serial(date(y0, m0, d0))
        lines.append(
            "    { name = %r, to = %r, pid = %d, tid = %d, kind = 'perm', "
            "contractEndYear = %d, joinSerial = %d, wage = %d, releaseClause = %d }," %
            (t['name'], t['toClub'], pid, tid, endY, js, wage, -1))
        n_perm += 1
lines.append('}')
print('entries: perm=%d loan=%d (total %d)' % (n_perm, n_loan, n_perm + n_loan))
open('transfers_table_block.lua', 'w', encoding='utf-8').write('\n'.join(lines))
print('wrote transfers_table_block.lua')