"""Fetch all FotMob transfers with transferDate >= 2026-07-14.

Popular list (170) + full list paged until cutoff. Dedupes, filters by
transferDate, writes pipeline-compatible fotmob_jul14_aug.json + a txt render.
"""
import json, time, urllib.request, gzip, random, sys

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:153.0) Gecko/20100101 Firefox/153.0'
CUT = '2026-07-14'
MAX_PAGES = 160

def fetch(url, retries=3):
    for a in range(retries):
        try:
            req = urllib.request.Request(url, headers={
                'User-Agent': UA, 'Referer': 'https://www.fotmob.com/transfers',
                'Accept-Encoding': 'gzip'})
            r = urllib.request.urlopen(req, timeout=40)
            raw = r.read()
            if r.headers.get('Content-Encoding') == 'gzip':
                raw = gzip.decompress(raw)
            return json.loads(raw)
        except Exception as e:
            if a == retries - 1:
                raise
            time.sleep(2 * (a + 1))

def yield_pages(popular):
    page = 1
    while page <= MAX_PAGES:
        pop = '&popular=true' if popular else ''
        url = (f'https://www.fotmob.com/api/data/transfers?orderBy=lastModified'
               f'&page={page}&minFeeCurrency=EUR{pop}')
        d = fetch(url)
        tr = d.get('transfers') or []
        if not tr:
            return
        dts = [(t.get('transferDate') or '')[:10] for t in tr]
        print(f'  page {page:3d} n={len(tr):3d} hits={d.get("hits")} '
              f'date min={min(dts)} max={max(dts)}', flush=True)
        for t in tr:
            yield t
        if len(tr) < 50 or all(x < CUT for x in dts):
            return
        page += 1
        time.sleep(0.35 + 0.25 * random.random())

def main():
    allr, seen = [], set()
    for popular in (True, False):
        print(f'== {"popular" if popular else "full"} list ==', flush=True)
        for t in yield_pages(popular):
            k = (t.get('playerId'), (t.get('transferDate') or '')[:19], t.get('toClubId'))
            if k not in seen:
                seen.add(k)
                allr.append(t)
    win = [t for t in allr if (t.get('transferDate') or '')[:10] >= CUT]
    win.sort(key=lambda t: (t.get('transferDate') or ''))
    print(f'== merged total={len(allr)} in-window(>= {CUT}): {len(win)}', flush=True)
    payload = {'source': 'fotmob /api/data/transfers (popular+full, orderBy=lastModified)',
               'window_from': CUT, 'merged': len(allr), 'transfers': win}
    json.dump(payload, open('fotmob_jul14_aug.json', 'w', encoding='utf-8'),
              ensure_ascii=False, indent=1)
    lines = []
    for r in win:
        fee = r.get('fee') or {}
        ft = fee.get('localizedFeeText', '') if isinstance(fee, dict) else ''
        if ft == 'transfer_fee':
            ft = '€%dM' % (fee.get('value', 0) / 1e6)
        elif ft == 'on_loan':
            ft = 'loan'
        elif ft == 'transfer_type_free_transfer':
            ft = 'free'
        else:
            ft = ''
        typ = 'L' if r.get('onLoan') else 'P'
        lines.append(f"{r.get('transferDate','')[:10]} [{typ}] {r.get('name'):<24} "
                     f"{r.get('playerId'):<9} {(r.get('fromClubFullName') or r.get('fromClub') or '')[:24]:<24} -> "
                     f"{r.get('toClubFullName') or r.get('toClub')} {ft}")
    open('fotmob_jul14_aug_list.txt', 'w', encoding='utf-8').write('\n'.join(lines))
    print('wrote fotmob_jul14_aug.json + fotmob_jul14_aug_list.txt', flush=True)

if __name__ == '__main__':
    main()