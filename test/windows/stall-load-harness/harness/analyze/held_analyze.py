"""MEASUREMENT ONLY (PKG-37): presents while synchronized output is held.

usage: python -I held_analyze.py <run dir> [more run dirs]

held.exe logs `B <qpc> <i>` when it writes BSU and `E <qpc> <i>` when it
writes ESU. A present between B_i and E_i (before the ESU was even written) showed a
frame the program had not finished: with synchronized output those are
identical re-presents. A cycle is shown if some present after E_i and
before B_{i+1} drew a frame update whose byte count covers the cycle's ESU.
"""
import bisect
import pathlib
import sys

END = b"\x1b[?2026l"


def analyze(run):
    run = pathlib.Path(run)
    freq = None
    swaps = []
    blob = bytearray()
    for line in (run / "latency.txt").read_text().splitlines():
        p = line.split(" ")
        if p[0] == "F":
            freq = int(p[1])
        elif p[0] == "E" and int(p[2]) == 10:
            swaps.append((int(p[1]), int(p[3])))
        elif p[0] == "B":
            off = int(p[1])
            d = bytes.fromhex(p[2])
            if len(blob) < off:
                blob.extend(b"\0" * (off - len(blob)))
            blob[off:off + len(d)] = d
    ends = []
    i = blob.find(END)
    while i != -1:
        ends.append(i + len(END))
        i = blob.find(END, i + 1)
    begins, finishes = {}, {}
    for l in (run / "anim.txt").read_text().splitlines():
        p = l.split()
        if p[0] == "B":
            begins[int(p[2])] = int(p[1])
        elif p[0] == "E":
            finishes[int(p[2])] = int(p[1])
    cycles = sorted(finishes)
    times = [s[0] for s in swaps]
    in_hold = 0
    shown = 0
    for c in cycles:
        b, e = begins[c], finishes[c]
        in_hold += bisect.bisect_left(times, e) - bisect.bisect_left(times, b)
        nxt = begins.get(c + 1, e + freq // 2)
        lo, hi = bisect.bisect_left(times, e), bisect.bisect_right(times, nxt)
        if c < len(ends) and any(bytes_ >= ends[c] for _, bytes_ in swaps[lo:hi]):
            shown += 1
    span = [s for s in swaps if begins[cycles[0]] <= s[0] <= finishes[cycles[-1]] + freq // 10]
    return {
        "cycles": len(cycles), "cycles_shown": shown,
        "presents_in_hold": in_hold, "presents_total": len(span),
    }


for run in sys.argv[1:]:
    r = analyze(run)
    print(f"{pathlib.Path(run).name:28s} " + " ".join(f"{k}={v}" for k, v in r.items()))
