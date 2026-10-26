"""Task 3 evidence: crop the tab band (client rows 0..surface_top+6) of before/after captures, stack them,
and count accent-coloured pixels in the band.
usage: t3evidence.py <out dir> <run dir>...
"""
import os, re, sys
from collections import Counter
from PIL import Image, ImageDraw

out = sys.argv[1]
runs = sys.argv[2:]
os.makedirs(out, exist_ok=True)

def parse(results):
    geo = {}
    cur = None
    for line in open(results, encoding='utf-8', errors='replace'):
        m = re.match(r'== (\S+) / (\S+)', line.strip())
        if m:
            cur = '%s-%s' % (m.group(1), m.group(2))
            continue
        m = re.search(r'\[(\S+)\] dpi=(\d+) .*clientOffset=\((\d+),(\d+)\) client=(\d+)x(\d+) surface=\((-?\d+),(-?\d+)\)', line)
        if m and cur:
            geo[(cur, m.group(1))] = dict(dx=int(m.group(3)), dy=int(m.group(4)), w=int(m.group(5)), top=int(m.group(8)))
    return geo

def hexc(p):
    return '#%02x%02x%02x' % p

caps = {}
for run in runs:
    for (case, label), g in parse(os.path.join(run, 'results.txt')).items():
        path = os.path.join(run, case, label + '-pw2.bmp')
        if os.path.exists(path):
            caps[(case, label)] = (path, g)

# Accent colours the old strip used, read from the before captures: anything bluish (b - r >= 40) in the band
# outside glyph anti-aliasing is counted by exact colour.
def band_stats(path, g):
    im = Image.open(path).convert('RGB')
    px = im.load()
    counts = Counter()
    for y in range(0, g['top']):
        for x in range(0, g['w']):
            counts[px[x + g['dx'], y + g['dy']]] += 1
    return im, counts

accent_set = set()
for (case, label), (path, g) in caps.items():
    if not case.startswith('before'):
        continue
    _, counts = band_stats(path, g)
    for colour, n in counts.items():
        r, gg, b = colour
        if b - r >= 40 and n >= 100:  # solid accent runs, not glyph fringes
            accent_set.add(colour)

lines = ['accent colours found in before captures (>=100 px, b-r>=40): ' + ', '.join(sorted(hexc(c) for c in accent_set))]
for (case, label), (path, g) in sorted(caps.items()):
    _, counts = band_stats(path, g)
    accent = sum(n for c, n in counts.items() if c in accent_set)
    lines.append('%-22s %-10s band rows 0..%d: accent px=%d' % (case, label, g['top'] - 1, accent))
open(os.path.join(out, 'accent-counts.txt'), 'w').write('\n'.join(lines) + '\n')
print('\n'.join(lines))

# Composites per scenario/layout: before over after, 1 tab and 3 tabs.
for layout, (bside, aside) in {'integrated': ('before', 'after'), 'win10-row': ('beforew10', 'afterw10')}.items():
    for scen in ('dark', 'light', 'lightterm'):
        items = []
        for side in (bside, aside):
            for label in ('launch', 'three-tabs'):
                key = ('%s-%s' % (side, scen), label)
                if key not in caps:
                    continue
                path, g = caps[key]
                im = Image.open(path).convert('RGB')
                crop = im.crop((g['dx'], g['dy'], g['dx'] + g['w'], g['dy'] + g['top'] + 8))
                items.append(('%s %s %s' % (side, scen, label), crop))
        if not items:
            continue
        W = max(c.width for _, c in items)
        H = sum(c.height + 16 for _, c in items)
        canvas = Image.new('RGB', (W, H), (255, 255, 255))
        d = ImageDraw.Draw(canvas)
        y = 0
        for name, c in items:
            d.text((2, y + 2), name, fill=(0, 0, 0))
            canvas.paste(c, (0, y + 16))
            y += c.height + 16
        canvas.save(os.path.join(out, 't3-%s-%s.png' % (layout, scen)))
print('composites saved')
