"""Apply transfers_to_apply.json directly into the Alpha4 squad file.

Backs up the original, then per entry:
  perm: move club link to target team, set contractvaliduntil + playerjointeamdate,
        delete any existing playerloans row (permanent move ends loans).
  loan: move club link to loan club; update the player's existing playerloans row
        or insert a new one (parent club, loan end serial, buy-option flag).

Requires src/fc26_mcp.fifa_squad.SquadFile with insert_record support.
"""
import sys, json, glob, shutil, time
from collections import Counter
sys.path.insert(0, 'src')
from fc26_mcp.fifa_squad import SquadFile

SQ = glob.glob(r"C:\Users\Afjal\AppData\Local\EA SPORTS FC 26\settings\SquadsFIFER*Alpha4")[0]
META = r"src\fc26_mcp\data\fifa_ng_db-meta-fc26.xml"
APPLY = json.load(open('transfers_to_apply.json', encoding='utf-8'))

assert APPLY, 'no transfers to apply'

bak = SQ + '.preapply' + time.strftime('%Y%m%d_%H%M%S') + '.bak'
shutil.copy(SQ, bak)
print('backup ->', bak)

sf = SquadFile(SQ, META)

clubs = {t['teamid'] for t in sf.get_table('teams') if (t.get('clubworth') or 0) != 0}
players_table = sf.get_table('players')
links = sf.get_table('teamplayerlinks')
loans = sf.get_table('playerloans')

# pre-index record indices
def rec_idx(table, key, val):
    rows = sf.get_table(table)
    for i, r in enumerate(rows):
        if r.get(key) == val:
            return i, r
    return None, None

stats = Counter()
log = []
for e in APPLY:
    pid, tid, kind = e['pid'], e['tid'], e['kind']
    name = e['name']

    # 1) move club link
    moved = 0
    links = sf.get_table('teamplayerlinks')
    for i, r in enumerate(links):
        if r.get('playerid') == pid and r.get('teamid') in clubs:
            sf.update_field('teamplayerlinks', i, 'teamid', tid)
            moved += 1
    if not moved:
        log.append('%-10s %-24s FAIL no club link (pid=%s)' % (kind, name, pid))
        stats.setdefault('no_link', 0); stats['no_link'] += 1
        continue

    loan_row_idx = None
    loans = sf.get_table('playerloans')
    for i, r in enumerate(loans):
        if r.get('playerid') == pid:
            loan_row_idx = i
            break

    if kind == 'perm':
        # end any existing loan
        if loan_row_idx is not None:
            sf.delete_record('playerloans', loan_row_idx)
        # contract
        rows = sf.get_table('players')
        for i, r in enumerate(rows):
            if r.get('playerid') == pid:
                sf.update_field('players', i, 'contractvaliduntil', e['contractEndYear'])
                if e.get('joinSerial'):
                    sf.update_field('players', i, 'playerjointeamdate', e['joinSerial'])
                break
        log.append('%-10s %-24s -> tid %s, contract %s' % (kind, name, tid, e['contractEndYear']))
        stats['perm'] = stats.get('perm', 0) + 1
    else:
        # loan: parent club + end + buy flag
        if loan_row_idx is not None:
            loans = sf.get_table('playerloans')
            for i, r in enumerate(loans):
                if r.get('playerid') == pid:
                    sf.update_field('playerloans', i, 'teamidloanedfrom', e['loanParent'])
                    sf.update_field('playerloans', i, 'loandateend', e['loanEndSerial'])
                    sf.update_field('playerloans', i, 'isloantobuy', 1 if e.get('loanBuy') else 0)
                    break
        else:
            idx = sf.insert_record('playerloans')
            sf.update_field('playerloans', idx, 'playerid', pid)
            sf.update_field('playerloans', idx, 'teamidloanedfrom', e['loanParent'])
            sf.update_field('playerloans', idx, 'loandateend', e['loanEndSerial'])
            sf.update_field('playerloans', idx, 'isloantobuy', 1 if e.get('loanBuy') else 0)
        log.append('loan[%s] -> %s, parent %s, end %s, buy %s' % (name, tid, e['loanParent'], e['loanEndSerial'], 1 if e.get('loanBuy') else 0))
        stats['loan'] = stats.get('loan', 0) + 1

for l in log:
    print(' ', l)
print(stats)
sf.save(SQ)
print('saved to', SQ)

# verify
sf2 = SquadFile(SQ, META)
print('verify:', len(sf2.get_table('players')), len(sf2.get_table('teamplayerlinks')), len(sf2.get_table('playerloans')))