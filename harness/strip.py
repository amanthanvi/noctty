"""Summarise a capture's tab band: accent-like runs per row and colour runs near the band bottom.

usage: strip.py <bmp> <client_dx> <client_dy> <band_bottom> [png_out]
Coordinates printed are client coordinates.
"""
import sys
from PIL import Image

path, dx, dy, bottom = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
im = Image.open(path).convert('RGB')
W, H = im.size
px = im.load()

def hexc(p):
    return '%02x%02x%02x' % p

def bluish(p):
    r, g, b = p
    return b > 120 and b - r > 40 and b - g > 15

print('size', W, H, 'client offset', dx, dy, 'band bottom', bottom)
for y in range(0, bottom + 2):
    runs = []
    x = 0
    cw = W - dx
    while x < cw:
        p = px[x + dx, y + dy]
        if bluish(p):
            s = x
            while x < cw and px[x + dx, y + dy] == p:
                x += 1
            runs.append('%d..%d #%s' % (s, x - 1, hexc(p)))
        else:
            x += 1
    if runs:
        print('row %3d accent-like: %s' % (y, ', '.join(runs[:10]) + (' ...(%d)' % len(runs) if len(runs) > 10 else '')))
# Colour runs (any colour) in the last rows of the band and the first rows under it.
for y in range(max(0, bottom - 7), min(H - dy, bottom + 3)):
    runs = []
    x = 0
    cw = W - dx
    while x < cw:
        p = px[x + dx, y + dy]
        s = x
        while x < cw and px[x + dx, y + dy] == p:
            x += 1
        runs.append('%d..%d #%s' % (s, x - 1, hexc(p)))
    print('row %3d runs(%d): %s' % (y, len(runs), ', '.join(runs[:14]) + (' ...' if len(runs) > 14 else '')))
if len(sys.argv) > 5:
    im.save(sys.argv[5])
