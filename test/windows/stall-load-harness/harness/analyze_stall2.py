"""MEASUREMENT ONLY (pacing-stall2): per-run summary of a runner-stall2 batch.

usage: python -I analyze_stall2.py <batch dir> [--json out.json]

For each run (<measurement>/<side>-p<k> with metrics.json, from analyze/metrics.py):
  lat02: display median / p95 / max, swaps per key, every key whose display (or,
         without a display, swap) latency exceeds 500 ms, with its largest stage
         (post->key_msg->pty_write->echo_recv->echo_write->pty_output->frame_update
         ->swap->display), and whether a watchdog stall window covers it.
  held/anim: the metrics.py headline numbers.
Every watchdog event (<side>-p<k>.wd/watchdog.log): STALL_END, SLOW, MISS streak
starts, TRIGGER, CDB_START/END, LATE, CTL_SLOW, with the machine busy % and top
5 processes at that moment (the event's own line, else the nearest L line).
QPC is shared by keys.txt, latency.txt and watchdog.log (same machine, same counter).
"""
import json
import pathlib
import re
import statistics
import sys

STAGES = ["key_msg", "pty_write", "echo_recv", "echo_write", "pty_output", "frame_update", "swap", "display"]


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))] if v else None


def parse_wd(path):
    ev = []
    if not path.exists():
        return ev
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split(" ", 3)
        if len(parts) < 4:
            continue
        try:
            q = int(parts[0])
        except ValueError:
            continue
        ev.append({"qpc": q, "time": parts[1], "kind": parts[2], "text": parts[3]})
    return ev


def kv(text, key):
    m = re.search(r"(?:^| )" + re.escape(key) + r"=(-?[\d.]+)", text)
    return float(m.group(1)) if m else None


def load_at(ev, q):
    """busy and top5 from the L line nearest to q (within 1 s)."""
    best = None
    for e in ev:
        if e["kind"] != "L":
            continue
        d = abs(e["qpc"] - q)
        if best is None or d < best[0]:
            best = (d, e)
    if not best or best[0] > 10_000_000:
        return None
    e = best[1]
    top = e["text"].split("| top5 ", 1)[1] if "| top5 " in e["text"] else ""
    return {"busy_500ms": kv(e["text"], "busy"), "top5": top, "at": e["time"]}


def wd_summary(ev, freq=10_000_000):
    out = {"stalls": [], "slow": [], "triggers": [], "cdb": [], "late": [], "ctl_slow": [], "errors": [], "summary": None,
           "identity": [], "window": None}
    miss_open = None
    for e in ev:
        k, t = e["kind"], e["text"]
        if k == "MISS" and miss_open is None:
            miss_open = e
        if k == "STALL_END":
            first = int(kv(t, "first_send_qpc"))
            start_line = miss_open["text"] if miss_open else ""
            out["stalls"].append({
                "time": e["time"], "unanswered_ms": kv(t, "unanswered_ms"), "misses": kv(t, "misses"),
                "first_send_qpc": first, "reply_qpc": int(kv(t, "reply_qpc")),
                "max_ctl_ms": kv(t, "max_ctl_ms"), "max_watchdog_late_ms": kv(t, "max_watchdog_late_ms"),
                "busy_tick_at_start": kv(start_line, "busy_tick"),
                "threads_at_start": start_line.split("| threads ", 1)[1].split(" | top5 ")[0] if "| threads " in start_line else "",
                "top5_at_start": start_line.split("| top5 ", 1)[1] if "| top5 " in start_line else "",
                "threads_at_end": t.split("| threads ", 1)[1].split(" | top5 ")[0] if "| threads " in t else "",
                "load": load_at(ev, first)})
            miss_open = None
        elif k == "SLOW":
            out["slow"].append({"time": e["time"], "reply_ms": kv(t, "reply_ms"), "send_qpc": int(kv(t, "send_qpc")),
                                "ctl_ms": kv(t, "ctl_ms"), "busy_tick": kv(t, "busy_tick"),
                                "threads": t.split("| threads ", 1)[1].split(" | top5 ")[0] if "| threads " in t else "",
                                "top5": t.split("| top5 ", 1)[1] if "| top5 " in t else ""})
        elif k == "TRIGGER":
            out["triggers"].append({"time": e["time"], "qpc": e["qpc"], "text": t})
        elif k in ("CDB_START", "CDB_END", "CDB"):
            out["cdb"].append({"time": e["time"], "kind": k, "text": t})
        elif k == "LATE":
            out["late"].append({"time": e["time"], "qpc": e["qpc"], "text": t, "load": load_at(ev, e["qpc"])})
        elif k == "CTL_SLOW":
            out["ctl_slow"].append({"time": e["time"], "qpc": e["qpc"], "text": t})
        elif k in ("ERROR", "STALL_OPEN"):
            out["errors"].append(e["time"] + " " + k + " " + t)
        elif k == "SUMMARY":
            out["summary"] = t
        elif k == "PS" and (t.startswith("tree:") or t.startswith("image=") or "FAILED" in t):
            out["identity"].append(t)
        elif k == "WINDOW":
            out["window"] = t
    # cdb suspension windows (qpc)
    wins = []
    for c in out["cdb"]:
        if c["kind"] == "CDB_END":
            a, b = kv(c["text"], "start_qpc"), kv(c["text"], "end_qpc")
            if a and b:
                wins.append((int(a), int(b)))
    out["cdb_windows"] = wins
    return out


def lat_run(run, m, wd):
    rows = m["rows"]
    freq = 10_000_000
    disp = [r["display"] for r in rows if "display" in r]
    res = {"display_median": statistics.median(disp) if disp else None, "display_p95": pct(disp, .95),
           "display_max": max(disp) if disp else None, "swaps_per_key": m["counts"]["swaps_per_key"],
           "missing_display": m["missing_display"], "cpu_busy_pct": m.get("cpu_busy_pct"),
           "cpu_busy_max_500ms_pct": m.get("cpu_busy_max_500ms_pct"), "windows_over_80pct": m.get("windows_over_80pct"),
           "timer_res_ms": m.get("timer_resolution_ms"), "slow_keys": []}
    for r in rows:
        total = r.get("display", r.get("swap"))
        if total is None or total <= 500:
            continue
        prev_name, prev_t = "post", 0.0
        best = ("?", 0.0)
        stages = {}
        for s in STAGES:
            if s in r:
                d = r[s] - prev_t
                stages[f"{prev_name}->{s}"] = round(d, 1)
                if d > best[1]:
                    best = (f"{prev_name}->{s}", d)
                prev_name, prev_t = s, r[s]
        post = r["post"]
        end = post + int(total * freq / 1000)
        cover = [s for s in wd["stalls"] if s["first_send_qpc"] <= end and s["reply_qpc"] >= post]
        cdb = any(a <= end and b >= post for a, b in wd["cdb_windows"])
        res["slow_keys"].append({"k": r["k"], "post_qpc": post, "total_ms": round(total, 1), "largest_stage": best[0],
                                 "largest_ms": round(best[1], 1), "stages": stages,
                                 "watchdog_stall_overlap_ms": [s["unanswered_ms"] for s in cover], "cdb_overlap": cdb})
    return res


def main():
    root = pathlib.Path(sys.argv[1])
    batch = json.loads((root / "batch.json").read_text(encoding="utf-8-sig"))
    out = {"batch": root.name, "sides": batch["Sides"], "runs": []}
    lines = []
    for meas in batch["Measurements"]:
        mdir = root / meas
        if not mdir.exists():
            continue
        runs = []
        for d in mdir.iterdir():
            if d.is_dir() and re.fullmatch(r"[AB]-p\d+", d.name):
                runs.append(d)
        # run order from the runner log
        order = []
        rl = (root / "runner.log").read_text(encoding="utf-8", errors="replace").splitlines() if (root / "runner.log").exists() else []
        for l in rl:
            mm = re.match(r"(\d\d:\d\d:\d\d) (?:FAILED )?" + re.escape(meas) + r" ([AB]-p\d+)", l)
            if mm:
                order.append((mm.group(2), mm.group(1)))
        pos = {n: i for i, (n, _) in enumerate(order)}
        finished = {n: t for n, t in order}
        runs.sort(key=lambda d: pos.get(d.name, 999))
        lines.append(f"== {meas}")
        for d in runs:
            side = d.name[0]
            label = batch["Sides"][side]
            wd = wd_summary(parse_wd(mdir / f"{d.name}.wd" / "watchdog.log"))
            mj = d / "metrics.json"
            rec = {"measurement": meas, "run": d.name, "side": label, "finished": finished.get(d.name), "watchdog": wd}
            if not mj.exists():
                rec["error"] = "no metrics.json"
                lines.append(f"{d.name:6s} {label:10s} NO METRICS")
                out["runs"].append(rec)
                continue
            m = json.loads(mj.read_text())
            if meas == "lat02":
                r = lat_run(d, m, wd)
                rec.update(r)
                lines.append(f"{d.name:6s} {label:10s} {finished.get(d.name,'?')} median={r['display_median']:.2f} p95={r['display_p95']:.2f} max={r['display_max']:.2f} "
                             f"swaps/key={r['swaps_per_key']} busy={r['cpu_busy_pct']}% max500={r['cpu_busy_max_500ms_pct']}% slow>500={len(r['slow_keys'])} "
                             f"| wd {wd['summary']}")
                for sk in r["slow_keys"]:
                    lines.append(f"    slow key k={sk['k']} total={sk['total_ms']} largest={sk['largest_stage']} {sk['largest_ms']} ms "
                                 f"wd_stalls={sk['watchdog_stall_overlap_ms']} cdb={sk['cdb_overlap']}")
            elif "held" in m:
                h = m["held"]
                rec["held"] = {k: h.get(k) for k in ("cycles", "cycles_shown", "presents_in_hold", "presents_total", "invalidations_in_hold",
                                                     "presents_per_invalidation_in_hold", "invalidation_interval_ms_median")}
                rec.update({"cpu_busy_pct": m.get("cpu_busy_pct"), "cpu_busy_max_500ms_pct": m.get("cpu_busy_max_500ms_pct")})
                lines.append(f"{d.name:6s} {label:10s} {finished.get(d.name,'?')} " + " ".join(f"{k}={v}" for k, v in rec["held"].items())
                             + f" busy={m.get('cpu_busy_pct')}% max500={m.get('cpu_busy_max_500ms_pct')}% | wd {wd['summary']}")
            elif "anim" in m:
                a = m["anim"]
                g = a.get("gaps", {})
                rec["anim"] = {k: a.get(k) for k in ("frames", "frames_shown", "presents", "content_presents", "presents_per_s")}
                rec["anim"]["gaps"] = g
                rec.update({"cpu_busy_pct": m.get("cpu_busy_pct"), "cpu_busy_max_500ms_pct": m.get("cpu_busy_max_500ms_pct")})
                lines.append(f"{d.name:6s} {label:10s} {finished.get(d.name,'?')} " + " ".join(f"{k}={v}" for k, v in rec["anim"].items() if k != "gaps")
                             + (f" gap mean={g.get('mean')} p50={g.get('p50')} p90={g.get('p90')} max={g.get('max')}" if g else "")
                             + f" busy={m.get('cpu_busy_pct')}% max500={m.get('cpu_busy_max_500ms_pct')}% | wd {wd['summary']}")
            for s in wd["stalls"]:
                ld = s["load"] or {}
                lines.append(f"    WD stall {s['time']} unanswered={s['unanswered_ms']} ms misses={s['misses']} ctl_max={s['max_ctl_ms']} wd_late={s['max_watchdog_late_ms']} "
                             f"busy_tick={s['busy_tick_at_start']}% busy500={ld.get('busy_500ms')}% top5@start: {s['top5_at_start']}")
                lines.append(f"      threads@start: {s['threads_at_start'][:400]}")
            for s in wd["slow"]:
                lines.append(f"    WD slow {s['time']} reply={s['reply_ms']} ms ctl={s['ctl_ms']} busy_tick={s['busy_tick']}% top5: {s['top5']}")
                lines.append(f"      threads: {s['threads'][:300]}")
            for c in wd["triggers"] + wd["cdb"]:
                lines.append(f"    WD {c.get('kind', 'TRIGGER')} {c['time']} {c['text'][:200]}")
            for l in wd["late"]:
                lines.append(f"    WD late {l['time']} {l['text']} load={l['load']}")
            for c in wd["ctl_slow"]:
                lines.append(f"    WD ctl_slow {c['time']} {c['text']}")
            for e in wd["errors"]:
                lines.append(f"    WD ERROR {e}")
            out["runs"].append(rec)
    text = "\n".join(lines)
    print(text)
    (root / "stall2-summary.txt").write_text(text + "\n", encoding="utf-8")
    jp = pathlib.Path(sys.argv[sys.argv.index("--json") + 1]) if "--json" in sys.argv else root / "stall2-summary.json"
    jp.write_text(json.dumps(out, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
