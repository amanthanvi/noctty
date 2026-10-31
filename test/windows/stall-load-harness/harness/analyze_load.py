"""MEASUREMENT ONLY (pacing-stall2): summary of runner-load / runner-stall2 lat02 batches.

usage: python -I analyze_load.py <out prefix> <batch dir> [<batch dir> ...]

Writes <out prefix>.txt and <out prefix>.json. For each lat02 run (<side>-p<k>
with metrics.json): display median / p95 / max, swaps per key, CPU busy, and,
when <side>-p<k>.load/bursts.txt exists, each key's burst membership (post QPC
inside a burst's observed [first thread start, last thread end]). Per burst:
the max key-to-display of keys posted inside it, and the drain (last in-burst
key's display time minus the burst end). Every key over 500 ms with its
largest stage, burst membership, watchdog stall and cdb overlap. Every
watchdog event with the UI thread's state / wait reason / current / base
priority, machine load, and the UI thread's frames from each cdb stack file.
A watchdog stall is marked cdb-caused when it starts while a cdb attach is in
progress (or its UI thread is Wait/Suspended at its start).
Per side: the same over all its runs.
"""
import json
import pathlib
import re
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import analyze_stall2 as a2  # noqa: E402

FREQ = 10_000_000


def pct(v, p):
    return a2.pct(v, p)


def fmt(x, d=1):
    return "-" if x is None else f"{x:.{d}f}"


def stats(v):
    if not v:
        return {"n": 0, "median": None, "p95": None, "max": None}
    return {"n": len(v), "median": round(statistics.median(v), 2), "p95": round(pct(v, .95), 2), "max": round(max(v), 2)}


def read_bursts(path):
    if not path.exists():
        return None, None
    hdr, out = None, []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("START"):
            hdr = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
        elif line.startswith("BURST"):
            parts = line.split()
            d = dict(kv.split("=", 1) for kv in parts[2:] if "=" in kv)
            out.append({"n": int(parts[1]), "start": int(d["first_start_min"]), "end": int(d["last_end_max"]),
                        "sched_start": int(d["sched_start"]), "sched_end": int(d["sched_end"]),
                        "partial": d.get("partial") == "1", "threads_ran": int(d["threads_ran"]),
                        "start_late_max_ms": float(d["start_late_max_ms"])})
    return hdr, out


UI_RE = re.compile(r"UI:(\d+)\[([^\] ]+) p(\d+)/(\d+)")


def ui_state(threads):
    m = UI_RE.search(threads or "")
    if not m:
        return None
    st = m.group(2)
    state, _, reason = st.partition("/")
    return {"tid": int(m.group(1)), "state": state, "wait_reason": reason or None, "cur_prio": int(m.group(3)), "base_prio": int(m.group(4))}


def stack_summary(path, ui_tid):
    """UI thread's frames (up to 8) from a cdb ~*kn log; also the count of threads per top frame."""
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    blocks = re.split(r"\n(?=[ .#]\s*\d+\s+Id: )", text)
    ui, tops = None, {}
    for b in blocks:
        m = re.match(r"[ .#]\s*\d+\s+Id: ([0-9a-f]+)\.([0-9a-f]+)", b.strip("\n"))
        if not m:
            continue
        tid = int(m.group(2), 16)
        frames = re.findall(r"^[0-9a-f]{2} [0-9a-f`]+ [0-9a-f`]+\s+(\S+)", b, re.M)
        if frames:
            tops[frames[0]] = tops.get(frames[0], 0) + 1
        if tid == ui_tid:
            ui = frames[:8]
    return {"ui_frames": ui, "top_frames": tops}


def overlaps(a0, a1, b0, b1):
    return a0 <= b1 and b0 <= a1


def run_record(batch, meas, d, side_label):
    mdir = d.parent
    wd_ev = a2.parse_wd(mdir / f"{d.name}.wd" / "watchdog.log")
    wd = a2.wd_summary(wd_ev)
    m = json.loads((d / "metrics.json").read_text())
    hdr, bursts = read_bursts(mdir / f"{d.name}.load" / "bursts.txt")
    freq = int(hdr["qpc_freq"]) if hdr else FREQ
    rows = m["rows"]
    disp = [r["display"] for r in rows if "display" in r]
    rec = {"batch": batch, "run": d.name, "side": side_label, "keys": len(rows),
           "display": stats(disp), "swaps_per_key": m["counts"]["swaps_per_key"],
           "missing_display": m["missing_display"], "cpu_busy_pct": m.get("cpu_busy_pct"),
           "cpu_busy_max_500ms_pct": m.get("cpu_busy_max_500ms_pct"), "windows_over_80pct": m.get("windows_over_80pct"),
           "loaded": bursts is not None}
    cdbw = wd["cdb_windows"]
    key_in, key_out = [], []
    per_burst = []
    if bursts:
        for b in bursts:
            b["keys"] = []
    for r in rows:
        total = r.get("display", r.get("swap"))
        post = r["post"]
        r["_total"] = total
        r["_burst"] = None
        if bursts:
            for b in bursts:
                if b["start"] <= post <= b["end"]:
                    r["_burst"] = b["n"]
                    b["keys"].append(r)
                    break
        r["_cdb"] = total is not None and any(overlaps(post, post + int(total * freq / 1000), x, y) for x, y in cdbw)
        if total is not None:
            (key_in if r["_burst"] is not None else key_out).append(total)
    rec["lists"] = {"in": [round(x, 2) for x in key_in], "out": [round(x, 2) for x in key_out],
                    "out_no_cdb": [round(r["_total"], 2) for r in rows if r["_total"] is not None and r["_burst"] is None and not r["_cdb"]],
                    "in_no_cdb": [round(r["_total"], 2) for r in rows if r["_total"] is not None and r["_burst"] is not None and not r["_cdb"]]}
    rec["keys_in_burst"] = len(key_in)
    rec["keys_outside_burst"] = len(key_out)
    rec["display_in_burst"] = stats(key_in)
    rec["display_outside_burst"] = stats(key_out)
    rec["display_outside_burst_no_cdb"] = stats([r["_total"] for r in rows if r["_total"] is not None and r["_burst"] is None and not r["_cdb"]])
    rec["display_in_burst_no_cdb"] = stats([r["_total"] for r in rows if r["_total"] is not None and r["_burst"] is not None and not r["_cdb"]])
    if bursts:
        for b in bursts:
            ks = [k for k in b["keys"] if k["_total"] is not None]
            if not ks:
                continue
            mx = max(k["_total"] for k in ks)
            drain = max((k["post"] - b["end"]) * 1000 / freq + k["_total"] for k in ks)
            cdb = any(overlaps(b["start"], b["end"] + int(max(0, drain) * freq / 1000), x, y) for x, y in cdbw)
            per_burst.append({"burst": b["n"], "keys": len(ks), "max_ms": round(mx, 1), "drain_after_end_ms": round(drain, 1),
                              "dur_ms": round((b["end"] - b["start"]) * 1000 / freq, 1), "partial": b["partial"],
                              "start_late_max_ms": b["start_late_max_ms"], "cdb_overlap": cdb})
        # keys posted in the 1 s after a burst end
        after = []
        for r in rows:
            if r["_total"] is None or r["_burst"] is not None:
                continue
            if any(0 < (r["post"] - b["end"]) <= freq for b in bursts):
                after.append(r["_total"])
        rec["display_1s_after_burst"] = stats(after)
        rec["lists_after"] = [round(x, 2) for x in after]
        rec["bursts_total"] = len(bursts)
    rec["per_burst"] = per_burst
    # slow keys
    slow = []
    for r in rows:
        total = r["_total"]
        if total is None or total <= 500:
            continue
        prev_name, prev_t, best = "post", 0.0, ("?", 0.0)
        for s in a2.STAGES:
            if s in r:
                dd = r[s] - prev_t
                if dd > best[1]:
                    best = (f"{prev_name}->{s}", dd)
                prev_name, prev_t = s, r[s]
        end = r["post"] + int(total * freq / 1000)
        cover = [s["unanswered_ms"] for s in wd["stalls"] if s["first_send_qpc"] <= end and s["reply_qpc"] >= r["post"]]
        # how long the key had already waited when the first overlapping cdb attach began (0: posted during a cdb attach)
        pre = None
        for x, y in cdbw:
            if overlaps(r["post"], end, x, y):
                pre = max(0.0, (x - r["post"]) * 1000 / freq)
                break
        slow.append({"k": r["k"], "total_ms": round(total, 1), "largest_stage": best[0], "largest_ms": round(best[1], 1),
                     "in_burst": r["_burst"] is not None, "burst": r["_burst"], "cdb_overlap": r["_cdb"],
                     "waited_before_cdb_ms": None if pre is None else round(pre, 1),
                     "slow_without_cdb": pre is None or pre > 500, "wd_stalls_ms": cover})
    rec["slow_keys"] = slow
    # watchdog events
    events = []
    k_first = min(r["post"] for r in rows)
    k_last = max(r["post"] + int((r["_total"] or 0) * freq / 1000) for r in rows)

    def phase(a, b):
        return "before_first_key" if b < k_first else "after_last_key" if a > k_last else "during_keys"
    for s in wd["stalls"]:
        ui0 = ui_state(s["threads_at_start"])
        ui1 = ui_state(s["threads_at_end"])
        a, b = s["first_send_qpc"], s["reply_qpc"]
        cdb_caused = any(x - freq // 50 <= a <= y for x, y in cdbw) or (ui0 is not None and ui0["wait_reason"] == "Suspended")
        in_b = [bb["n"] for bb in (bursts or []) if overlaps(a, b, bb["start"], bb["end"])]
        ld = s["load"] or {}
        events.append({"kind": "stall", "time": s["time"], "unanswered_ms": s["unanswered_ms"], "misses": s["misses"], "phase": phase(a, b),
                       "ui_at_start": ui0, "ui_at_end": ui1, "max_ctl_ms": s["max_ctl_ms"],
                       "busy_tick_at_start": s["busy_tick_at_start"], "busy_500ms": ld.get("busy_500ms"),
                       "top5_at_start": s["top5_at_start"], "cdb_caused": cdb_caused, "cdb_overlap": any(overlaps(a, b, x, y) for x, y in cdbw),
                       "bursts_overlapped": in_b,
                       "starts_in_burst": any(bb["start"] <= a <= bb["end"] for bb in (bursts or []))})
    for s in wd["slow"]:
        ui0 = ui_state(s["threads"])
        a = s["send_qpc"]
        events.append({"kind": "slow", "time": s["time"], "reply_ms": s["reply_ms"], "ui": ui0, "ctl_ms": s["ctl_ms"],
                       "busy_tick": s["busy_tick"], "top5": s["top5"],
                       "cdb_caused": any(x <= a <= y for x, y in cdbw),
                       "in_burst": any(bb["start"] <= a <= bb["end"] for bb in (bursts or []))})
    for t in wd["triggers"]:
        events.append({"kind": "trigger", "time": t["time"], "text": t["text"]})
    for c in wd["cdb"]:
        events.append({"kind": c["kind"].lower(), "time": c["time"], "text": re.sub(r" log=\S+", "", c["text"])})
    for c in wd["ctl_slow"]:
        events.append({"kind": "ctl_slow", "time": c["time"], "text": c["text"]})
    for e in wd["errors"]:
        events.append({"kind": "error", "text": e})
    rec["wd_summary"] = wd["summary"]
    rec["wd_events"] = events
    # stacks
    stacks = []
    ui_tid = None
    for e in events:
        if e["kind"] == "stall" and e["ui_at_start"]:
            ui_tid = e["ui_at_start"]["tid"]
            break
    if ui_tid is None:
        for line in (e["text"] for e in wd_ev if e["kind"] in ("MISS", "SLOW", "L")):
            mm = UI_RE.search(line) or re.search(r"ui=UI:(\d+)", line)
            if mm:
                ui_tid = int(mm.group(1))
                break
    for f in sorted((mdir / f"{d.name}.wd").glob("stacks-*.log")):
        stacks.append({"file": str(f), **(stack_summary(f, ui_tid) or {})})
    rec["stacks"] = stacks
    rec["ui_tid"] = ui_tid
    # priorities sampled by the runner
    pf = mdir / f"{d.name}.load" / "prio.txt"
    if pf.exists():
        rec["prio"] = [l for l in pf.read_text(encoding="utf-8", errors="replace").splitlines()]
    return rec


def side_summary(runs):
    out = {}
    for label in sorted({r["side"] for r in runs}):
        rs = [r for r in runs if r["side"] == label]
        allk, ink, outk, outk_nocdb, ink_nocdb, after = [], [], [], [], [], []
        pb_max, pb_drain = [], []
        for r in rs:
            pass
        out[label] = {"runs": len(rs)}
        o = out[label]
        o["keys_in_burst"] = sum(r["keys_in_burst"] for r in rs)
        o["keys_outside_burst"] = sum(r["keys_outside_burst"] for r in rs)
        o["slow_keys_gt500"] = sum(len(r["slow_keys"]) for r in rs)
        o["slow_keys_gt500_in_burst"] = sum(1 for r in rs for k in r["slow_keys"] if k["in_burst"])
        o["slow_keys_gt500_outside_burst"] = sum(1 for r in rs for k in r["slow_keys"] if not k["in_burst"])
        o["slow_keys_gt500_outside_burst_no_cdb"] = sum(1 for r in rs for k in r["slow_keys"] if not k["in_burst"] and not k["cdb_overlap"])
        o["slow_keys_gt500_slow_before_any_cdb"] = sum(1 for r in rs for k in r["slow_keys"] if k["slow_without_cdb"])
        o["slow_keys_gt500_slow_before_any_cdb_outside_burst"] = sum(1 for r in rs for k in r["slow_keys"] if k["slow_without_cdb"] and not k["in_burst"])
        hist = {}
        for r in rs:
            for k in r["slow_keys"]:
                key = ("in_burst " if k["in_burst"] else "outside ") + k["largest_stage"]
                hist[key] = hist.get(key, 0) + 1
        o["slow_keys_largest_stage_hist"] = dict(sorted(hist.items(), key=lambda kv: -kv[1]))
        o["keys_pooled_in_burst"] = stats([x for r in rs for x in r["lists"]["in"]])
        o["keys_pooled_outside_burst"] = stats([x for r in rs for x in r["lists"]["out"]])
        o["keys_pooled_in_burst_no_cdb"] = stats([x for r in rs for x in r["lists"]["in_no_cdb"]])
        o["keys_pooled_outside_burst_no_cdb"] = stats([x for r in rs for x in r["lists"]["out_no_cdb"]])
        o["keys_pooled_1s_after_burst"] = stats([x for r in rs for x in r.get("lists_after", [])])
        o["run_max_display_ms"] = sorted(round(r["display"]["max"], 1) for r in rs if r["display"]["max"] is not None)
        o["run_p95_display_ms"] = stats([r["display"]["p95"] for r in rs if r["display"]["p95"] is not None])
        o["run_median_display_ms"] = stats([r["display"]["median"] for r in rs if r["display"]["median"] is not None])
        o["swaps_per_key"] = stats([r["swaps_per_key"] for r in rs])
        o["cpu_busy_pct"] = stats([r["cpu_busy_pct"] for r in rs if r["cpu_busy_pct"] is not None])
        pbs = [b for r in rs for b in r["per_burst"]]
        o["bursts_with_keys"] = len(pbs)
        o["per_burst_max_ms"] = stats([b["max_ms"] for b in pbs])
        o["per_burst_max_ms_no_cdb"] = stats([b["max_ms"] for b in pbs if not b["cdb_overlap"]])
        o["per_burst_drain_after_end_ms"] = stats([b["drain_after_end_ms"] for b in pbs])
        o["per_burst_drain_after_end_ms_no_cdb"] = stats([b["drain_after_end_ms"] for b in pbs if not b["cdb_overlap"]])
        o["bursts_max_over_2500ms"] = sum(1 for b in pbs if b["max_ms"] > 2500)
        o["bursts_max_over_2500ms_no_cdb"] = sum(1 for b in pbs if b["max_ms"] > 2500 and not b["cdb_overlap"])
        o["bursts_drain_over_250ms_no_cdb"] = sum(1 for b in pbs if b["drain_after_end_ms"] > 250 and not b["cdb_overlap"])
        st = [e for r in rs for e in r["wd_events"] if e["kind"] == "stall"]
        o["wd_stalls"] = len(st)
        o["wd_stalls_cdb_caused"] = sum(1 for e in st if e["cdb_caused"])
        o["wd_stall_max_ms"] = max((e["unanswered_ms"] for e in st), default=0)
        o["wd_stall_max_ms_not_cdb_caused"] = max((e["unanswered_ms"] for e in st if not e["cdb_caused"]), default=0)
        o["wd_stall_max_ms_not_cdb_overlap"] = max((e["unanswered_ms"] for e in st if not e["cdb_overlap"]), default=0)
        o["wd_stalls_during_keys"] = sum(1 for e in st if e["phase"] == "during_keys")
        o["wd_stall_max_ms_during_keys_not_cdb_caused"] = max((e["unanswered_ms"] for e in st if e["phase"] == "during_keys" and not e["cdb_caused"]), default=0)
        o["wd_stalls_not_starting_in_burst"] = sum(1 for e in st if not e["starts_in_burst"] and not e["cdb_caused"])
        o["wd_stall_ms_list_not_cdb_caused"] = sorted((e["unanswered_ms"] for e in st if not e["cdb_caused"]), reverse=True)
        alld = []
        # pooled key-level stats
        for r in rs:
            pass
        out[label] = o
    return out


def main():
    out_prefix = pathlib.Path(sys.argv[1])
    runs = []
    for bd in [a for a in sys.argv[2:] if not a.startswith("--")]:
        root = pathlib.Path(bd)
        batch = json.loads((root / "batch.json").read_text(encoding="utf-8-sig"))
        mdir = root / "lat02"
        order = {}
        rl = (root / "runner.log").read_text(encoding="utf-8", errors="replace").splitlines() if (root / "runner.log").exists() else []
        for i, l in enumerate(rl):
            mm = re.match(r"(\d\d:\d\d:\d\d) (?:FAILED )?lat02 ([AB]-p\d+)", l)
            if mm:
                order[mm.group(2)] = (i, mm.group(1))
        dirs = [d for d in mdir.iterdir() if d.is_dir() and re.fullmatch(r"[AB]-p\d+", d.name)]
        dirs.sort(key=lambda d: order.get(d.name, (999, ""))[0])
        for d in dirs:
            label = batch["Sides"][d.name[0]]
            if not (d / "metrics.json").exists():
                runs.append({"batch": root.name, "run": d.name, "side": label, "error": "no metrics.json"})
                continue
            rec = run_record(root.name, "lat02", d, label)
            rec["finished"] = order.get(d.name, (0, None))[1]
            runs.append(rec)
    ok = [r for r in runs if "error" not in r]
    sides = side_summary(ok)
    L = []
    for r in runs:
        if "error" in r:
            L.append(f"{r['batch']} {r['run']:6s} {r['side']:10s} {r['error']}")
            continue
        d = r["display"]
        pb = " ".join(f"b{b['burst']}:{b['max_ms']:.0f}/{b['drain_after_end_ms']:.0f}{'c' if b['cdb_overlap'] else ''}" for b in r["per_burst"])
        L.append(f"{r['batch']} {r['run']:6s} {r['side']:10s} {r.get('finished') or '?'} median={fmt(d['median'],2)} p95={fmt(d['p95'],2)} max={fmt(d['max'],1)} "
                 f"swaps/key={r['swaps_per_key']} busy={r['cpu_busy_pct']}% max500={r['cpu_busy_max_500ms_pct']}% keys_in/out={r['keys_in_burst']}/{r['keys_outside_burst']} "
                 f"slow>500={len(r['slow_keys'])} | wd {r['wd_summary']}")
        if r["per_burst"]:
            L.append(f"    per-burst max/drain ms (c=cdb overlap): {pb}")
            L.append(f"    outside-burst: {r['display_outside_burst']}  outside no-cdb: {r['display_outside_burst_no_cdb']}  1s-after-burst: {r.get('display_1s_after_burst')}")
        if r["slow_keys"]:
            hist = {}
            for k in r["slow_keys"]:
                hist[k["largest_stage"]] = hist.get(k["largest_stage"], 0) + 1
            L.append(f"    slow>500 summary: n={len(r['slow_keys'])} in_burst={sum(1 for k in r['slow_keys'] if k['in_burst'])} outside={sum(1 for k in r['slow_keys'] if not k['in_burst'])} "
                     f"cdb_overlap={sum(1 for k in r['slow_keys'] if k['cdb_overlap'])} max={max(k['total_ms'] for k in r['slow_keys'])} largest_stage_hist={hist}")
        for k in r["slow_keys"]:
            if r["loaded"] and k["in_burst"] and "--all-slow" not in sys.argv:
                continue
            L.append(f"    slow k={k['k']} total={k['total_ms']} largest={k['largest_stage']} {k['largest_ms']} in_burst={k['in_burst']}(b{k['burst']}) cdb={k['cdb_overlap']} waited_before_cdb={k['waited_before_cdb_ms']} wd_stalls={k['wd_stalls_ms']}")
        for e in r["wd_events"]:
            if e["kind"] == "stall":
                u = e["ui_at_start"] or {}
                ue = e["ui_at_end"] or {}
                L.append(f"    WD stall {e['time']} {e['unanswered_ms']:.0f} ms UI@start={u.get('state')}/{u.get('wait_reason')} p{u.get('cur_prio')}/{u.get('base_prio')} "
                         f"UI@end={ue.get('state')}/{ue.get('wait_reason')} p{ue.get('cur_prio')}/{ue.get('base_prio')} ctl_max={e['max_ctl_ms']} busy_tick={e['busy_tick_at_start']}% busy500={e['busy_500ms']}% "
                         f"phase={e['phase']} in_burst={e['starts_in_burst']} bursts={e['bursts_overlapped']} cdb_caused={e['cdb_caused']} cdb_overlap={e['cdb_overlap']} top5: {e['top5_at_start']}")
            elif e["kind"] == "slow":
                u = e["ui"] or {}
                L.append(f"    WD slow {e['time']} {e['reply_ms']:.0f} ms UI={u.get('state')}/{u.get('wait_reason')} p{u.get('cur_prio')}/{u.get('base_prio')} busy_tick={e['busy_tick']}% in_burst={e['in_burst']} cdb={e['cdb_caused']} top5: {e['top5']}")
            elif e["kind"] in ("trigger", "cdb_start", "cdb_end", "ctl_slow"):
                L.append(f"    WD {e['kind']} {e.get('time','')} {e['text'][:160]}")
            elif e["kind"] == "error":
                L.append(f"    WD error {e['text'][:200]}")
        for s in r["stacks"]:
            L.append(f"    stacks {pathlib.Path(s['file']).name}: UI({r['ui_tid']}) {' < '.join(s.get('ui_frames') or ['?'])} | tops {s.get('top_frames')}")
        for p in r.get("prio", [])[:11]:
            L.append(f"    prio {p}")
    L.append("")
    L.append("== per side")
    for label, o in sides.items():
        L.append(f"{label}: " + json.dumps(o))
    text = "\n".join(L)
    out_prefix.with_suffix(".txt").write_text(text + "\n", encoding="utf-8")
    out_prefix.with_suffix(".json").write_text(json.dumps({"runs": runs, "sides": sides}, default=str), encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
