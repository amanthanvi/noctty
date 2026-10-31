"""MEASUREMENT ONLY (pacing-stall2): positive control for the injected load.

usage: python -I analyze_control.py <control out dir>

Reads load/bursts.txt (CpuLoad load), counter.txt (CpuLoad counter at IDLE
class: loop iterations per 10 ms QPC bucket) and smto.txt (SendMessageTimeout
WM_NULL round trips to a Normal-class window). Classifies each 10 ms bucket and
each round trip as inside a burst (observed [first thread start, last thread
end]), outside (more than 50 ms from any burst edge), or edge.
"""
import json
import pathlib
import statistics
import sys


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))] if v else None


def st(v):
    if not v:
        return {"n": 0}
    return {"n": len(v), "min": min(v), "median": statistics.median(v), "mean": round(statistics.mean(v), 1),
            "p95": pct(v, .95), "max": max(v)}


def main():
    root = pathlib.Path(sys.argv[1])
    hdr, bursts = None, []
    for line in (root / "load" / "bursts.txt").read_text().splitlines():
        if line.startswith("START"):
            hdr = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
        elif line.startswith("BURST"):
            d = dict(kv.split("=", 1) for kv in line.split()[2:] if "=" in kv)
            bursts.append((int(d["first_start_min"]), int(d["last_end_max"]), d))
    f = int(hdr["qpc_freq"])
    edge = f // 20  # 50 ms

    def where(a, b):
        for s, e, _ in bursts:
            if a >= s and b <= e:
                return "in"
        for s, e, _ in bursts:
            if b >= s - edge and a <= e + edge:
                return "edge"
        return "out"

    lines = (root / "counter.txt").read_text().splitlines()
    chdr = dict(kv.split("=", 1) for kv in lines[0].split()[1:] if "=" in kv)
    bq = int(chdr["bucket_qpc"])
    load_t0 = int(hdr["t0"])
    last_end = max(e for _, e, _ in bursts)
    cin, cout, cpre = [], [], []
    zero_run, max_zero_run_in = 0, 0
    for l in lines[1:]:
        q, c = l.split()
        q, c = int(q), int(c)
        if q + bq > last_end + f:  # after the load stopped (+1 s)
            break
        if q + bq <= load_t0 - f // 10:
            cpre.append(c)
            continue
        w = where(q, q + bq)
        if w == "in":
            cin.append(c)
            zero_run = zero_run + 1 if c == 0 else 0
            max_zero_run_in = max(max_zero_run_in, zero_run)
        else:
            zero_run = 0
            if w == "out":
                cout.append(c)
    sin, sout = [], []
    for l in (root / "smto.txt").read_text().splitlines()[1:]:
        q, ms, ok = l.split()
        q, ms = int(q), float(ms)
        a, b = q, q + int(ms * f / 1000)
        w = where(a, b)
        (sin if w == "in" else sout if w == "out" else []).append(ms)
    res = {
        "bursts": [{"n": i, "dur_ms": round((e - s) * 1000 / f, 1), "threads_ran": d["threads_ran"], "start_late_max_ms": d["start_late_max_ms"]}
                   for i, (s, e, d) in enumerate(bursts)],
        "load_header": hdr, "counter_header": chdr,
        "counter_iters_per_10ms_before_load": st(cpre),
        "counter_iters_per_10ms_inside_bursts": st(cin),
        "counter_iters_per_10ms_outside_bursts": st(cout),
        "counter_inside_buckets_zero": sum(1 for c in cin if c == 0),
        "counter_inside_buckets_total": len(cin),
        "counter_inside_longest_zero_run_ms": max_zero_run_in * 10,
        "counter_inside_over_outside_ratio": (statistics.mean(cin) / statistics.mean(cout)) if cin and cout and statistics.mean(cout) else None,
        "smto_rtt_ms_inside_bursts": st(sin),
        "smto_rtt_ms_outside_bursts": st(sout),
    }
    text = json.dumps(res, indent=1)
    (root / "control-summary.json").write_text(text)
    print(text)


if __name__ == "__main__":
    main()
