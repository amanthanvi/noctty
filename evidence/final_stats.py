"""Every figure quoted in the benchmark methodology doc, from the raw data.

usage: python -I final_stats.py bench_all.json noiseDir [noiseDir ...]
"""
import glob
import json
import os
import statistics
import sys

hist = json.load(open(sys.argv[1], encoding="utf-8"))
noise_dirs = sys.argv[2:]
W = ("ascii", "utf8", "osc", "scroll")
OLD = {"ascii": 50, "utf8": 35, "osc": 3, "scroll": 50}
NEW = {"ascii": 40, "utf8": 35, "osc": 3, "scroll": 40}


def clsname(cpu):
    c = cpu.strip()
    for a in ("AMD ", "INTEL(R) ", " 64-Core Processor", " 96-Core Processor", " 80-Core Processor", " CPU @ 2.80GHz"):
        c = c.replace(a, "")
    return c.strip()


runners = []  # (dirname, cpuclass, {w: [runs]})
for nd in noise_dirs:
    for d in sorted(glob.glob(os.path.join(nd, "bench-noise-*"))):
        meta = json.load(open(os.path.join(d, "meta.json"), encoding="utf-8-sig"))
        runs = {w: json.load(open(os.path.join(d, w + ".json"), encoding="utf-8-sig"))["per_run_mb_s"] for w in W}
        runners.append((d, clsname(meta["cpu"]), runs, meta["started"]))
print("runners", len(runners), "sample start stamps:", sorted(set(r[3][:16] for r in runners)))

print("\n== per-class per-runner medians (statistics.median)")
classes = {}
for d, c, runs, _ in runners:
    classes.setdefault(c, []).append(runs)
for c, rs in sorted(classes.items(), key=lambda kv: -len(kv[1])):
    row = []
    for w in W:
        meds = [statistics.median(r[w]) for r in rs]
        row.append(f"{w} {min(meds):.1f}-{max(meds):.1f}")
    print(f"  {c}: n={len(rs)}  " + "  ".join(row))

print("\n== disturbed runs: strictly under 0.7x of the runner's own median")
tot = bad = 0
clusters = []
for d, c, runs, _ in runners:
    for w in W:
        v = runs[w]
        own = statistics.median(v)
        flags = [x < 0.7 * own for x in v]
        tot += len(v)
        bad += sum(flags)
        i = 0
        while i < len(v):
            if flags[i]:
                j = i
                last = i
                # a cluster: disturbed runs separated by at most one undisturbed run
                k = i + 1
                while k < len(v) and k <= last + 2:
                    if flags[k]:
                        last = k
                    k += 1
                clusters.append((os.path.basename(d), w, i, last, last - i + 1, sum(flags[i:last + 1])))
                i = last + 1
            else:
                i += 1
print(f"  {bad} of {tot} runs; clusters (runner, workload, first, last, span, disturbed):")
for c in clusters:
    print("    ", c)

print("\n== longest episode: longest consecutive stretch under a threshold, per runner/workload (seconds at 4 MiB per run)")
best = None
for d, c, runs, _ in runners:
    for w in W:
        v = runs[w]
        own = statistics.median(v)
        for frac in (0.9, ):
            cur = 0
            longest = (0, 0)
            start = 0
            for i, x in enumerate(v):
                if x < frac * statistics.median(classes[c][0][w]) if False else x < frac * max(statistics.median(r[w]) for r in classes[c]):
                    if cur == 0:
                        start = i
                    cur += 1
                    if cur > longest[0]:
                        longest = (cur, start)
                else:
                    cur = 0
            if longest[0] >= 10:
                secs = sum(4194304 / 1e6 / x for x in v[longest[1]:longest[1] + longest[0]])
                print(f"   {os.path.basename(d)} {w}: {longest[0]} consecutive runs under 0.9x of the class median, from run {longest[1]}, {secs:.1f} s, lowest {min(v[longest[1]:longest[1]+longest[0]]):.1f} highest {max(v[longest[1]:longest[1]+longest[0]]):.1f}")

print("\n== lowest fastest-of-N over all sliding windows")
for w in W:
    row = []
    for N in (5, 9, 15, 20, 30):
        if w == "osc" and N > 20:
            continue
        lo = None
        for d, c, runs, _ in runners:
            v = runs[w]
            for i in range(0, len(v) - N + 1):
                b = max(v[i:i + N])
                if lo is None or b < lo[0]:
                    lo = (b, os.path.basename(d), i)
        row.append(f"N={N}: {lo[0]:.2f} ({lo[1]} run {lo[2]})")
    print(" ", w, " | ".join(row))

print("\n== the gate's own quantity: the fastest run of a whole sequence (60 runs; 20 for osc)")
for w in W:
    n_gate = 20 if w == "osc" else 60
    vals = []
    for d, c, runs, _ in runners:
        v = runs[w][:n_gate]
        vals.append((max(v), os.path.basename(d), c, statistics.median(v)))
    lo = min(vals)
    print(f"  {w}: sequences={len(vals)} lowest fastest-of-{n_gate} = {lo[0]:.2f} ({lo[1]}, {lo[2]}, its median {lo[3]:.2f}); floor new={NEW[w]} old={OLD[w]} -> room {lo[0]/NEW[w]:.2f}x / {lo[0]/OLD[w]:.2f}x")
    slow_only = [x for x in vals if x[2] == "EPYC 7763"]
    print(f"      slowest class only: lowest {min(slow_only)[0]:.2f}, n={len(slow_only)}")

print("\n== first run effect")
ratios = []
for d, c, runs, _ in runners:
    for w in W:
        v = runs[w]
        ratios.append(statistics.median(v[:5]) / statistics.median(v[5:]))
print(f"  long sequences, median(first 5)/median(rest): {min(ratios):.3f}..{max(ratios):.3f}, median {statistics.median(ratios):.3f}")
ok = [e for e in hist if e.get("workloads")]
for w in W:
    blocks = [b for e in ok for b in e["workloads"].get(w, []) if len(b) == 5]
    first_slowest = sum(1 for b in blocks if b[0] == min(b))
    others_slowest = [sum(1 for b in blocks if b[i] == min(b)) for i in range(1, 5)]
    r1 = statistics.median([b[0] / statistics.median(b[1:]) for b in blocks])
    print(f"  historical {w}: blocks={len(blocks)} run1 slowest {first_slowest} ({100*first_slowest/len(blocks):.0f}%), runs 2-5 slowest {others_slowest}, median run1/median(runs 2-5) {r1:.3f}")

print("\n== historical lowest fastest-of-5 and old-gate failures")
for w in W:
    blocks = [(e, b) for e in ok for b in e["workloads"].get(w, []) if len(b) == 5]
    lo = min(max(b) for e, b in blocks)
    fails = sum(1 for e, b in blocks if sorted(b)[2] < OLD[w])
    print(f"  {w}: blocks={len(blocks)} lowest fastest-of-5 {lo:.2f}; blocks the old gate (median<{OLD[w]}) failed: {fails}")

print("\n== slowdown needed to fail the gate on the slowest class (EPYC 7763): class median / threshold")
slow = [r for d, c, r, _ in runners if c == "EPYC 7763"]
for w in W:
    meds = [statistics.median(r[w]) for r in slow]
    print(f"  {w}: old (median-of-5 < {OLD[w]}): {min(meds)/OLD[w]:.2f}-{max(meds)/OLD[w]:.2f}x   new (fastest-of-30 < {NEW[w]}): {min(meds)/NEW[w]:.2f}-{max(meds)/NEW[w]:.2f}x")
fast = [r for d, c, r, _ in runners if c == "EPYC 9V45"]
for w in W:
    meds = [statistics.median(r[w]) for r in fast]
    print(f"  fast class EPYC 9V45 {w}: new {min(meds)/NEW[w]:.2f}-{max(meds)/NEW[w]:.2f}x")
