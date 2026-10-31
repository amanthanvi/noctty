"""MEASUREMENT ONLY (PKG-37): intervals between presents during a probe.

usage: python -I gaps.py <run dir> [more run dirs]

Prints the present-to-present interval distribution (ms) between the first
and last line anim.txt logged.
"""
import pathlib
import statistics
import sys


def gaps(run):
    run = pathlib.Path(run)
    freq = None
    swaps = []
    for line in (run / "latency.txt").read_text().splitlines():
        p = line.split(" ")
        if p[0] == "F":
            freq = int(p[1])
        elif p[0] == "E" and int(p[2]) == 10:
            swaps.append(int(p[1]))
    marks = [int(l.split()[1]) for l in (run / "anim.txt").read_text().splitlines() if l[:1] in ("W", "B", "E")]
    lo, hi = min(marks), max(marks)
    t = [s for s in swaps if lo <= s <= hi]
    return [(b - a) * 1000.0 / freq for a, b in zip(t, t[1:])]


for run in sys.argv[1:]:
    g = sorted(gaps(run))
    q = lambda f: g[min(len(g) - 1, int(f * len(g)))]
    print(f"{pathlib.Path(run).name:28s} n={len(g)} mean={statistics.mean(g):.2f} min={g[0]:.2f} p10={q(0.1):.2f} p50={q(0.5):.2f} p90={q(0.9):.2f} max={g[-1]:.2f}")
