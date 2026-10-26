"""For each capture in a case dir, list colour runs in the lane under the tab buttons (rows lo..hi, client coords)
that are not the band colour, plus the accent-like runs anywhere in the band right of the tabs.

usage: lane.py <case dir> <results.txt>
"""
import os, re, sys
from PIL import Image

case, results = sys.argv[1], sys.argv[2]
geo = {}
name = os.path.basename(case.rstrip('/\\'))
cur = None
for line in open(results, encoding='utf-8', errors='replace'):
    m = re.match(r'== (\S+) / (\S+)', line.strip())
    if m:
        cur = '%s-%s' % (m.group(1), m.group(2))
        continue
    m = re.search(r'\[(\S+)\] dpi=(\d+) .*clientOffset=\((\d+),(\d+)\) client=(\d+)x(\d+) surface=\((-?\d+),(-?\d+)\)', line)
    if m and cur == name:
        geo[m.group(1)] = dict(dpi=int(m.group(2)), dx=int(m.group(3)), dy=int(m.group(4)), w=int(m.group(5)), h=int(m.group(6)), top=int(m.group(8)))

def hexc(p):
    return '%02x%02x%02x' % p

for label, g in geo.items():
    path = os.path.join(case, label + '-pw2.bmp')
    if not os.path.exists(path):
        continue
    im = Image.open(path).convert('RGB')
    px = im.load()
    s = g['dpi'] / 96.0
    top = g['top']
    lo = top - int(round(5 * s)) - 1
    band = px[g['dx'] + g['w'] // 2, g['dy'] + 2]
    out = []
    for y in range(lo, top):
        runs = []
        x = 0
        while x < g['w']:
            p = px[x + g['dx'], y + g['dy']]
            st = x
            while x < g['w'] and px[x + g['dx'], y + g['dy']] == p:
                x += 1
            if p != band:
                runs.append('%d..%d #%s' % (st, x - 1, hexc(p)))
        out.append('  row %d: %s' % (y, '; '.join(runs) if runs else '-'))
    im.crop((g['dx'], g['dy'], g['dx'] + g['w'], g['dy'] + top + 4)).save(os.path.join(case, label + '-band.png'))
    print('%s [%s] dpi=%d band=#%s surface_top=%d' % (name, label, g['dpi'], hexc(band), top))
    print('\n'.join(out))
