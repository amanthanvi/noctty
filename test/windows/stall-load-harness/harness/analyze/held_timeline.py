"""MEASUREMENT ONLY (diagnostic): per-cycle timeline of a held.exe run.

usage: python -I held_timeline.py <run dir>

For each cycle: BSU/ESU write times (ms from the first BSU), the ESU's end
offset in the pty stream, and every swap from that BSU to the next one with
its time, the frame's byte count and whether that frame covered the ESU; plus
pty output chunks and frame updates in the same window.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import metrics  # noqa: E402

run = pathlib.Path(sys.argv[1])
freq, ev, raw, blob = metrics.load_trace(run)
ends = metrics.esu_ends(blob)
begins, finishes = {}, {}
for l in (run / "anim.txt").read_text().splitlines():
    p = l.split()
    (begins if p[0] == "B" else finishes)[int(p[2])] = int(p[1])
t0 = begins[min(begins)]
ms = lambda q: (q - t0) * 1000.0 / freq
for c in sorted(finishes):
    b, e = begins[c], finishes[c]
    nxt = begins.get(c + 1, e + freq // 2)
    print(f"cycle {c}: BSU {ms(b):8.1f}  ESU {ms(e):8.1f}  esu_end={ends[c] if c < len(ends) else None}")
    for q, kind, a, bb in sorted(raw):
        if not (b <= q < nxt):
            continue
        if kind == 10:
            tag = "covers ESU" if c < len(ends) and a >= ends[c] else ""
            where = "IN HOLD" if q < e else ""
            print(f"    swap   {ms(q):8.1f} bytes={a} {where} {tag}")
        elif kind == 4:
            print(f"    output {ms(q):8.1f} end={a} len={bb}")
        elif kind == 6:
            print(f"    frame  {ms(q):8.1f} bytes={a}")
        elif kind == 5:
            print(f"    wake   {ms(q):8.1f} sources=0x{a:x}")
