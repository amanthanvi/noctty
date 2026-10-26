"""Crop the right end of the tab band (x0..x1, y0..y1) from captures, scale them 4x, stack them with labels."""
import sys
from PIL import Image, ImageDraw

out = sys.argv[1]
items = []
for spec in sys.argv[2:]:
    label, path, x0, y0, x1, y1 = spec.split('|')
    im = Image.open(path).convert('RGB').crop((int(x0), int(y0), int(x1), int(y1)))
    im = im.resize((im.width * 4, im.height * 4), Image.NEAREST)
    items.append((label, im))
W = max(im.width for _, im in items)
H = sum(im.height + 18 for _, im in items)
canvas = Image.new('RGB', (W, H), (255, 255, 255))
d = ImageDraw.Draw(canvas)
y = 0
for label, im in items:
    d.text((2, y + 2), label, fill=(0, 0, 0))
    canvas.paste(im, (0, y + 18))
    y += im.height + 18
canvas.save(out)
print('saved', out, canvas.size)
