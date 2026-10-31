"""MEASUREMENT ONLY: pool a runner batch into per-side medians/p95 and
per-pair differences.

usage: python -I report.py <batch dir> [--json out.json]

<batch dir>/batch.json names the sides ({"A": label, "B": label}) and the
measurements; each run is <batch>/<measurement>/<A|B>-p<k>/metrics.json
(analyze/metrics.py). Percentiles are aggregate.py's (index round(p*(n-1)) of
the sorted values); medians are statistics.median. A per-pair difference is
B minus A within pair k.
"""
import json
import pathlib
import statistics
import sys


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def summ(v):
    v = [x for x in v if x is not None]
    if not v:
        return None
    return {"n": len(v), "median": statistics.median(v), "p95": pct(v, .95), "min": min(v), "max": max(v)}


def fmt(s, unit=""):
    if not s:
        return "n=0"
    return f"n={s['n']:<4d} median={s['median']:9.2f}{unit} p95={s['p95']:9.2f}{unit} min={s['min']:9.2f} max={s['max']:9.2f}"


# measurement -> list of (metric name, extractor(metrics.json) -> number)
def held_metric(key):
    return lambda m: m["held"].get(key)


PER_RUN = {
    "held": [("presents_in_hold", held_metric("presents_in_hold")),
             ("presents_total", held_metric("presents_total")),
             ("cycles_shown", held_metric("cycles_shown")),
             ("hold_ms_total (10 x 200 ms nominal)", held_metric("hold_ms_total"))],
    "expose": [("presents_in_hold", held_metric("presents_in_hold")),
               ("invalidations_in_hold", held_metric("invalidations_in_hold")),
               ("presents_per_invalidation_in_hold", held_metric("presents_per_invalidation_in_hold")),
               ("presents_total", held_metric("presents_total")),
               ("cycles_shown", held_metric("cycles_shown")),
               ("hold_ms_total (10 x 200 ms nominal)", held_metric("hold_ms_total"))],
    "saver60": [("presents_per_s", lambda m: m["anim"]["presents_per_s"]),
                ("interval_mean_ms", lambda m: m["anim"].get("gaps", {}).get("mean")),
                ("interval_p50_ms", lambda m: m["anim"].get("gaps", {}).get("p50")),
                ("interval_p90_ms", lambda m: m["anim"].get("gaps", {}).get("p90")),
                ("frames_shown", lambda m: m["anim"]["frames_shown"])],
    "lat02": [("display_median_ms", lambda m: (m["summary"].get("display") or {}).get("median")),
              ("display_p95_ms", lambda m: (m["summary"].get("display") or {}).get("p95")),
              ("swap_median_ms", lambda m: (m["summary"].get("swap") or {}).get("median")),
              ("swap_p95_ms", lambda m: (m["summary"].get("swap") or {}).get("p95")),
              ("swaps_per_key", lambda m: m["counts"]["swaps_per_key"]),
              ("missing_display", lambda m: m["missing_display"])],
}
PER_RUN["expose-saver"] = PER_RUN["expose"]
# Pooled samples across a side's runs (the entries pooled keys and intervals).
POOLED = {
    "lat02": [("display_ms (pooled keys)", lambda m: [r["display"] for r in m["rows"] if "display" in r]),
              ("swap_ms (pooled keys)", lambda m: [r["swap"] for r in m["rows"] if "swap" in r])],
    "saver60": [("present_interval_ms (pooled)", lambda m: m["anim"].get("intervals_ms", []))],
}
# What each measurement's entry reports, for the reader.
ENTRY = {
    "held": "PKG-37 (1): 127-141 presents inside the holds before the fix, 0 after, every cycle shown (results-G G-held-v60: 127/128 vs 0/0; cycles_shown 10/10)",
    "expose": "PKG-37 (1): child invalidated every 50 ms in holds: 139-141 before the fix, 0 on the first draft, about one per invalidation now (results-G G-held-expose: 139/141, 0/0, 32/33)",
    "expose-saver": "PKG-37 (1) 'also under saver pacing' (results-G G-held-expose-saver: 44/45 before, 0/0 first draft, 32/32 final)",
    "saver60": "PKG-37 (2): 60 fps TUI under saver pacing: 21.2 presents/s before, 29.3 after; mean interval 47.0 -> 34.0 ms",
    "lat02": "LAT-02: emulated 60 Hz, local echo (d0-ssh-steady): 25.85 / 33.17 ms median / p95 before, 8.80 / 16.66 after; presents per key 2-3 -> 1",
}


def main():
    root = pathlib.Path(sys.argv[1])
    batch = json.loads((root / "batch.json").read_text(encoding="utf-8-sig"))
    sides = batch["Sides"]
    out = {"batch": root.name, "sides": sides, "validation_only": batch.get("Validation", False), "measurements": {}}
    lines = []
    lines.append(f"batch {root.name}: A={sides['A']} B={sides['B']} order={batch.get('Order')}"
                 + ("  [VALIDATION RUN: not results]" if batch.get("Validation") else ""))
    for meas in batch["Measurements"]:
        mdir = root / meas
        if not mdir.exists():
            continue
        runs = {}
        for d in sorted(mdir.iterdir()):
            mj = d / "metrics.json"
            if not mj.exists():
                continue
            side, p = d.name.split("-p")
            runs[(side, int(p))] = json.loads(mj.read_text())
        pairs = sorted({p for _, p in runs})
        mres = {"entry": ENTRY.get(meas), "per_side": {}, "pooled": {}, "pair_diff": {}, "runs": {}}
        lines.append("")
        lines.append(f"== {meas}: {ENTRY.get(meas, '')}")
        lines.append(f"   pairs with both sides: {sum(1 for p in pairs if ('A', p) in runs and ('B', p) in runs)} of {len(pairs)}")
        for s in ("A", "B"):
            busy = [(runs[(s, p)].get("cpu_busy_pct"), runs[(s, p)].get("cpu_busy_max_500ms_pct")) for p in pairs if (s, p) in runs]
            prio = sorted({runs[(s, p)].get("priority", "BelowNormal") for p in pairs if (s, p) in runs})
            tres = [runs[(s, p)].get("timer_resolution_ms") for p in pairs if (s, p) in runs]
            lines.append(f"   machine CPU busy during {s} runs (% mean, max per 500 ms): {busy}  priority={prio}  system timer resolution ms [before, after]: {tres}")
        mres["cpu_busy_pct"] = {s: {p: runs[(s, p)].get("cpu_busy_pct") for p in pairs if (s, p) in runs} for s in ("A", "B")}
        for name, fn in PER_RUN[meas]:
            vals = {s: {p: fn(runs[(s, p)]) for p in pairs if (s, p) in runs} for s in ("A", "B")}
            mres["runs"][name] = {s: vals[s] for s in vals}
            lines.append(f"   {name}")
            for s in ("A", "B"):
                st = summ(list(vals[s].values()))
                mres["per_side"].setdefault(name, {})[s] = st
                lines.append(f"     {s} {sides[s]:10s} per-run {fmt(st)}   values={[vals[s][p] for p in sorted(vals[s])]}")
            diffs = {p: vals["B"][p] - vals["A"][p] for p in pairs
                     if p in vals["A"] and p in vals["B"] and vals["A"][p] is not None and vals["B"][p] is not None}
            mres["pair_diff"][name] = diffs
            ds = summ(list(diffs.values()))
            lines.append(f"     B-A per pair {fmt(ds)}   diffs={[round(diffs[p], 3) for p in sorted(diffs)]}")
        for name, fn in POOLED.get(meas, []):
            lines.append(f"   {name}")
            for s in ("A", "B"):
                pooled = [x for p in pairs if (s, p) in runs for x in fn(runs[(s, p)])]
                st = summ(pooled)
                mres["pooled"].setdefault(name, {})[s] = st
                lines.append(f"     {s} {sides[s]:10s} {fmt(st)}")
        out["measurements"][meas] = mres
    text = "\n".join(lines)
    print(text)
    (root / "report.txt").write_text(text + "\n")
    if "--json" in sys.argv:
        pathlib.Path(sys.argv[sys.argv.index("--json") + 1]).write_text(json.dumps(out, indent=1))
    else:
        (root / "report.json").write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
