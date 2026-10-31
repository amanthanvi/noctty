"""MEASUREMENT ONLY (LAT-01): pool per-key rows across reps by build x scenario.

usage: python -I aggregate.py <matrix dir> [field ...]
Run dirs are named <build>-<scenario...>-r<rep> and hold summary.json.
"""
import json
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
fields = sys.argv[2:] or ["swap"]
groups = {}
for d in sorted(root.iterdir()):
    s = d / "summary.json"
    if not s.exists():
        continue
    name = d.name
    build, rest = name.split("-", 1)
    scen = rest.rsplit("-r", 1)[0]
    rows = json.loads(s.read_text())["rows"]
    groups.setdefault((scen, build), []).extend(rows)


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


SEG = {
    "post->key_msg": ("post", "key_msg"),
    "key_msg->pty_write": ("key_msg", "pty_write"),
    "pty_write->echo_recv": ("pty_write", "echo_recv"),
    "echo_write->pty_output": ("echo_write", "pty_output"),
    "pty_output->frame": ("pty_output", "frame_update"),
    "frame->swap": ("frame_update", "swap"),
}
for f in fields:
    print(f"== {f} (ms; pooled keys)")
    print(f"{'scenario':34s} {'build':6s} {'n':>5s} {'median':>8s} {'p95':>8s} {'p99':>8s} {'max':>8s}")
    for (scen, build), rows in sorted(groups.items()):
        if f in SEG:
            a, b = SEG[f]
            vals = [r[b] - (r[a] if a != "post" else 0.0) for r in rows if b in r and (a == "post" or a in r)]
        else:
            vals = [r[f] for r in rows if f in r]
        missing = len(rows) - len(vals)
        if not vals:
            continue
        print(f"{scen:34s} {build:6s} {len(vals):5d} {statistics.median(vals):8.2f} {pct(vals, .95):8.2f} {pct(vals, .99):8.2f} {max(vals):8.2f}" + (f"  missing={missing}" if missing else ""))
