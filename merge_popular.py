"""Merge the previous 40 popular transfers back into apply_transfers_full.lua.

The full-set compare filtered them out as 'already done' (the settings file
had them via apply_squad.py), but the game boots from mod squads which do NOT
have them. Re-insert the 40 with FC-style wage + releaseClause=-1.
"""
import re
from datetime import date
import sys, json
sys.path.insert(0, 'src')
from fc26_mcp.fifa_squad import SquadFile

SQ = r"C:\Users\Afjal\AppData\Local\EA SPORTS FC 26\settings\SquadsFIFER'sBeta4xRODE'sNewSeasonModAlpha4"
META = "src/fc26_mcp/data/fifa_ng_db-meta-fc26.xml"
sf = SquadFile(None if False else SQ, META)

ovr = {}
for p in sf.get_table('players'):
    o = p.get('overallrating')
    if o is not None:
        ovr[p['playerid']] = int(o)

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

old_seg = open('apply_transfers.lua', encoding='utf-8').read()
old_seg = old_seg[old_seg.find('local TRANSFERS'):old_seg.find('-- Main')]

# parse original entries preserving exact original fields
pat = re.compile(r"\{\s*(.*?)\s*\}", re.S)
extra_lines = []
seen = set()
for m in pat.finditer(old_seg):
    body = m.group(1)
    pm = re.search(r"pid = (\d+)", body)
    if not pm: continue
    pid = int(pm.group(1))
    if pid in seen: continue
    seen.add(pid)
    nm = re.search(r"name = [\"']([^\"']+)[\"']", body).group(1)
    to = re.search(r"to = [\"']([^\"']+)[\"']", body).group(1)
    tid = int(re.search(r"tid = (\d+)", body).group(1))
    kind = re.search(r"kind = '(\w+)'", body).group(1)
    o = ovr.get(pid, 60)
    if kind == 'perm':
        ce = re.search(r"contractEndYear = (\d+)", body)
        js = re.search(r"joinSerial = (\d+)", body)
        new = ("    { name = %r, to = %r, pid = %d, tid = %d, kind = 'perm', "
               "contractEndYear = %d, joinSerial = %d, wage = %d, releaseClause = -1 },"
               % (nm, to, pid, tid, int(ce.group(1)), int(js.group(1)), fc_wage(o)))
    else:
        lp = re.search(r"loanParent = (\d+)", body)
        le = re.search(r"loanEndSerial = (\d+)", body)
        lb = re.search(r"loanBuy = (\d+)", body)
        new = ("    { name = %r, to = %r, pid = %d, tid = %d, kind = 'loan', "
               "loanParent = %d, loanEndSerial = %d, loanBuy = %d },"
               % (nm, to, pid, tid, int(lp.group(1)), int(le.group(1)), int(lb.group(1))))
    extra_lines.append(new)

full = open('apply_transfers_full.lua', encoding='utf-8').read()
# insert before the closing '}' of TRANSFERS table (the '}' right before '-- Main')
idx = full.find('-- Main')
tail_start = idx
table_end = full.rfind('\n}', 0, idx)
new_block = '\n'.join(extra_lines)
out = full[:table_end + 1] + '\n' + new_block + '\n' + full[table_end + 1:]
open('apply_transfers_full.lua', 'w', encoding='utf-8').write(out)
print('merged', len(extra_lines), 'entries -> total lines now:', out.count('\n'))

from luaparser import ast
ast.parse(out)
print('LUA SYNTAX VALID')