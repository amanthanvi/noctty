"""MEASUREMENT ONLY (LAT-02): presents and renderer wakes per run.

usage: python -I counts.py <matrix dir>

For every run dir (<build>-<scenario>-r<rep>) counts, from latency.txt, the
events between the first key post and 1 s after the last key release:
SwapBuffers (swap_end), frame updates, and renderer wakes split by
WakeSource bit (a coalesced wake can carry several). Also reads the whole-run
swap_buffers_count from render.json. Pools reps per build x scenario.
"""
import json
import pathlib
import sys

SOURCES = ["thread_start", "core_surface", "mailbox", "io_output", "cursor_blink",
           "apprt_repaint_retry", "apprt_resize_settle", "apprt_paint_retry",
           "apprt_health_recovery", "apprt_paint_pending", "apprt_first_show", "inspector"]


def count(run):
    freq = None
    ev = []
    for line in (run / "latency.txt").read_text().splitlines():
        p = line.split(" ")
        if p[0] == "F":
            freq = int(p[1])
        elif p[0] == "E":
            ev.append((int(p[1]), int(p[2]), int(p[3]), int(p[4])))
    posts = [int(l.split()[2]) for l in (run / "keys.txt").read_text().splitlines()]
    lo, hi = min(posts), max(posts) + freq
    out = {"keys": sum(1 for l in (run / "keys.txt").read_text().splitlines() if l.startswith("D")),
           "swaps": 0, "frames": 0, "wakes": 0}
    for s in SOURCES:
        out["wake_" + s] = 0
    out["content_swaps"] = 0
    last_swap_bytes = None
    for q, kind, a, _ in ev:
        if kind == 10 and q < lo:
            last_swap_bytes = a
        if not (lo <= q <= hi):
            continue
        if kind == 10:
            out["swaps"] += 1
            # A present whose frame carries pty output the previous one did not.
            if a != last_swap_bytes:
                out["content_swaps"] += 1
            last_swap_bytes = a
        elif kind == 6:
            out["frames"] += 1
        elif kind == 5:
            out["wakes"] += 1
            for i, s in enumerate(SOURCES):
                if a & (1 << i):
                    out["wake_" + s] += 1
    rj = run / "render.json"
    if rj.exists():
        try:
            data = json.loads(rj.read_text())
            out["run_swap_buffers_count"] = data.get("swap_buffers_count")
        except Exception:
            pass
    return out


root = pathlib.Path(sys.argv[1])
groups = {}
for d in sorted(root.iterdir()):
    if not (d / "latency.txt").exists():
        continue
    build, rest = d.name.split("-", 1)
    scen = rest.rsplit("-r", 1)[0]
    c = count(d)
    g = groups.setdefault((scen, build), {})
    for k, v in c.items():
        if v is None:
            continue
        g[k] = g.get(k, 0) + v
cols = ["keys", "swaps", "content_swaps", "frames", "wakes", "wake_core_surface", "wake_io_output",
        "wake_apprt_repaint_retry", "wake_cursor_blink", "wake_mailbox", "run_swap_buffers_count"]
print(f"{'scenario':38s} {'build':6s} " + " ".join(f"{c.replace('wake_', 'w:')[:14]:>14s}" for c in cols))
for (scen, build), g in sorted(groups.items()):
    print(f"{scen:38s} {build:6s} " + " ".join(f"{g.get(c, 0):14d}" for c in cols))
