"""MEASUREMENT ONLY: per-run metrics for the four renderer scratch measurements.

usage: python -I metrics.py <run dir> [--json out.json] [--quiet]

The computations are the committed analyzers' (origin/pkg37-measurement-harness
39d1ec0c0; copies beside this file), unchanged in what they compute:
  held (held.exe)  pkg37-harness/held_analyze.py: cycles, cycles_shown,
                   presents_in_hold, presents_total. Added: per-cycle presents,
                   and invalidations_in_hold from inval.txt (the expose case's
                   "about one per invalidation").
  anim (anim.exe)  lat02-harness/anim_analyze.py: frames, frames_in_output,
                   frames_shown, presents, content_presents, presents_per_s;
                   pkg37-harness/gaps.py: present-to-present intervals
                   (n, mean, min, p10, p50, p90, max) between the first and
                   last line anim.txt logged.
  echo (lat-echo)  lat01-harness/analyze.py per-key rows (key_msg .. swap,
                   display) and lat02-harness/counts.py (swaps, frames, wakes
                   between the first key post and 1 s after the last).
                   Only change: the line/tui style is read from params.json
                   instead of the launch line of driver.log.
The run dir is one probe.ps1 run (latency.txt from the trace-patched build).
"""
import bisect
import json
import pathlib
import statistics
import sys

KIND = {1: "key_msg", 2: "char_msg", 3: "pty_write", 4: "pty_output", 5: "renderer_wake",
        6: "frame_update", 7: "render_action", 8: "paint_begin", 9: "swap_begin", 10: "swap_end",
        11: "app_wake"}
END = b"\x1b[?2026l"


def load_trace(run):
    freq = None
    events = {k: [] for k in KIND.values()}
    raw = []
    blob = bytearray()
    for line in (run / "latency.txt").read_text().splitlines():
        p = line.split(" ")
        if p[0] == "F":
            freq = int(p[1])
        elif p[0] == "E":
            q, kind, a, b = int(p[1]), int(p[2]), int(p[3]), int(p[4])
            raw.append((q, kind, a, b))
            events[KIND[kind]].append((q, a, b))
        elif p[0] == "B":
            off = int(p[1])
            d = bytes.fromhex(p[2])
            if len(blob) < off:
                blob.extend(b"\0" * (off - len(blob)))
            blob[off:off + len(d)] = d
    for v in events.values():
        v.sort()
    return freq, events, raw, bytes(blob)


def esu_ends(blob):
    ends = []
    i = blob.find(END)
    while i != -1:
        ends.append(i + len(END))
        i = blob.find(END, i + 1)
    return ends


# ---- held.exe (pkg37-harness/held_analyze.py) ----
def held(run, freq, ev, blob):
    swaps = [(q, a) for q, a, _ in ev["swap_end"]]
    ends = esu_ends(blob)
    begins, finishes = {}, {}
    for l in (run / "anim.txt").read_text().splitlines():
        p = l.split()
        if p[0] == "B":
            begins[int(p[2])] = int(p[1])
        elif p[0] == "E":
            finishes[int(p[2])] = int(p[1])
    cycles = sorted(finishes)
    times = [s[0] for s in swaps]
    inval = []
    ip = run / "inval.txt"
    if ip.exists():
        inval = sorted(int(l.split()[1]) for l in ip.read_text().splitlines() if l.startswith("I "))
    in_hold = 0
    shown = 0
    per_cycle = []
    inval_in_hold = 0
    for c in cycles:
        b, e = begins[c], finishes[c]
        n = bisect.bisect_left(times, e) - bisect.bisect_left(times, b)
        in_hold += n
        per_cycle.append(n)
        inval_in_hold += bisect.bisect_left(inval, e) - bisect.bisect_left(inval, b)
        nxt = begins.get(c + 1, e + freq // 2)
        lo, hi = bisect.bisect_left(times, e), bisect.bisect_right(times, nxt)
        if c < len(ends) and any(bytes_ >= ends[c] for _, bytes_ in swaps[lo:hi]):
            shown += 1
    span = [s for s in swaps if begins[cycles[0]] <= s[0] <= finishes[cycles[-1]] + freq // 10]
    hold_ms = sum(finishes[c] - begins[c] for c in cycles) * 1000.0 / freq
    out = {
        "cycles": len(cycles), "cycles_shown": shown,
        "presents_in_hold": in_hold, "presents_total": len(span),
        "presents_in_hold_per_cycle": per_cycle,
        "hold_ms_total": round(hold_ms, 1),
    }
    if ip.exists():
        out["invalidations_total"] = len(inval)
        out["invalidations_in_hold"] = inval_in_hold
        gaps = [(b2 - a2) * 1000.0 / freq for a2, b2 in zip(inval, inval[1:])]
        out["invalidation_interval_ms_median"] = round(statistics.median(gaps), 2) if gaps else None
        out["presents_per_invalidation_in_hold"] = round(in_hold / inval_in_hold, 3) if inval_in_hold else None
    return out


# ---- anim.exe (lat02-harness/anim_analyze.py + pkg37-harness/gaps.py) ----
def anim(run, freq, ev, blob):
    swaps = [(q, a) for q, a, _ in ev["swap_end"]]
    ends = esu_ends(blob)
    lines = (run / "anim.txt").read_text().splitlines()
    writes = [int(l.split()[1]) for l in lines if l.startswith("W")]
    lo, hi = writes[0], writes[-1] + freq // 10
    in_window = [s for s in swaps if lo <= s[0] <= hi]
    shown = set()
    for _, b in in_window:
        k = bisect.bisect_right(ends, b) - 1
        if k >= 0:
            shown.add(k)
    content = 0
    last = None
    for _, b in in_window:
        if b != last:
            content += 1
        last = b
    secs = (hi - lo) / freq
    out = {
        "frames": len(writes), "frames_in_output": len(ends), "frames_shown": len(shown),
        "presents": len(in_window), "content_presents": content,
        "presents_per_s": round(len(in_window) / secs, 2),
    }
    # gaps.py: intervals between presents between the first and last W/B/E mark.
    marks = [int(l.split()[1]) for l in lines if l[:1] in ("W", "B", "E")]
    glo, ghi = min(marks), max(marks)
    t = [s[0] for s in swaps if glo <= s[0] <= ghi]
    g = sorted((b - a) * 1000.0 / freq for a, b in zip(t, t[1:]))
    if g:
        q = lambda f: g[min(len(g) - 1, int(f * len(g)))]
        out["gaps"] = {"n": len(g), "mean": round(statistics.mean(g), 2), "min": round(g[0], 2),
                       "p10": round(q(0.1), 2), "p50": round(q(0.5), 2), "p90": round(q(0.9), 2),
                       "max": round(g[-1], 2)}
        out["intervals_ms"] = [round(x, 3) for x in g]
    return out


# ---- lat-echo (lat01-harness/analyze.py + lat02-harness/counts.py) ----
def text_positions(blob):
    """Offsets of printable bytes outside escape sequences."""
    out = []
    i, n = 0, len(blob)
    while i < n:
        b = blob[i]
        if b == 0x1B:
            i += 1
            if i >= n:
                break
            c = blob[i]
            if c == ord("["):
                i += 1
                while i < n and not (0x40 <= blob[i] <= 0x7E):
                    i += 1
                i += 1
            elif c in (ord("]"), ord("P"), ord("_"), ord("^"), ord("X")):
                i += 1
                while i < n:
                    if blob[i] == 0x07:
                        i += 1
                        break
                    if blob[i] == 0x1B and i + 1 < n and blob[i + 1] == ord("\\"):
                        i += 2
                        break
                    i += 1
            elif c in (ord("("), ord(")"), ord("*"), ord("+"), ord("#"), ord("%")):
                i += 2
            else:
                i += 1
            continue
        if 0x20 <= b < 0x7F:
            out.append((i, b))
        i += 1
    return out


def first_at_or_after(seq, q):
    idx = bisect.bisect_left(seq, (q, -1, -1))
    return seq[idx] if idx < len(seq) else None


def echo_rows(run, freq, ev, blob, style):
    ms = lambda d: d * 1000.0 / freq
    kd, ku = {}, {}
    for line in (run / "keys.txt").read_text().splitlines():
        t, i, q, vk = line.split()
        (kd if t == "D" else ku)[int(i)] = (int(q), int(vk))
    recv, sent = [], []
    echo = run / "echo.txt"
    if echo.exists():
        for line in echo.read_text().splitlines():
            parts = line.split()
            if len(parts) != 3:
                continue
            ch = int(parts[2])
            if not (97 <= ch <= 122):
                continue
            (recv if parts[0] == "R" else sent).append((int(parts[1]), ch))
    texts = text_positions(blob)
    n = len(kd)
    echo_offsets = {}
    ti = 0
    banner = blob.find(b"lat-echo ready")
    while ti < len(texts) and texts[ti][0] < banner + 14:
        ti += 1
    for k in range(n):
        want = 0x61 + (kd[k][1] - 0x41)
        while ti < len(texts) and texts[ti][1] != want:
            ti += 1
        if ti >= len(texts):
            break
        echo_offsets[k] = texts[ti][0]
        ti += 1
    keydowns = [e for e in ev["key_msg"] if e[1] == 0x100]
    outputs = ev["pty_output"]
    out_ends = [o[1] for o in outputs]
    if style in ("line", "tui"):
        echo_offsets = {}
        for k in range(min(n, len(sent))):
            oi = bisect.bisect_left(outputs, (sent[k][0], -1, -1))
            if oi < len(outputs):
                echo_offsets[k] = outputs[oi][1] - 1
    frames = ev["frame_update"]
    swaps = ev["swap_end"]
    rows = []
    for k in range(n):
        post = kd[k][0]
        row = {"k": k, "post": post}
        if k < len(keydowns):
            row["key_msg"] = ms(keydowns[k][0] - post)
            w = first_at_or_after(ev["pty_write"], keydowns[k][0])
            if w:
                row["pty_write"] = ms(w[0] - post)
        if k < len(recv):
            row["echo_recv"] = ms(recv[k][0] - post)
        if k < len(sent):
            row["echo_write"] = ms(sent[k][0] - post)
        off = echo_offsets.get(k)
        if off is not None:
            need = off + 1
            oi = bisect.bisect_left(out_ends, need)
            if oi < len(outputs):
                row["pty_output"] = ms(outputs[oi][0] - post)
            fi = None
            for j in range(len(frames)):
                if frames[j][1] >= need:
                    fi = j
                    break
            if fi is not None:
                row["frame_update"] = ms(frames[fi][0] - post)
                fq = frames[fi][0]
                si = bisect.bisect_left(swaps, (fq, -1, -1))
                while si < len(swaps) and swaps[si][1] < need:
                    si += 1
                if si < len(swaps):
                    row["swap"] = ms(swaps[si][0] - post)
                    if swaps[si][2]:
                        row["display"] = ms(swaps[si][2] - post)
        rows.append(row)
    return rows


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def stats(values):
    v = sorted(values)
    if not v:
        return None
    return {"n": len(v), "median": statistics.median(v), "p95": pct(v, .95), "p99": pct(v, .99),
            "max": v[-1], "mean": statistics.fmean(v)}


SOURCES = ["thread_start", "core_surface", "mailbox", "io_output", "cursor_blink",
           "apprt_repaint_retry", "apprt_resize_settle", "apprt_paint_retry",
           "apprt_health_recovery", "apprt_paint_pending", "apprt_first_show", "inspector"]


def counts(run, freq, raw):
    lines = (run / "keys.txt").read_text().splitlines()
    posts = [int(l.split()[2]) for l in lines]
    lo, hi = min(posts), max(posts) + freq
    out = {"keys": sum(1 for l in lines if l.startswith("D")), "swaps": 0, "frames": 0, "wakes": 0}
    for s in SOURCES:
        out["wake_" + s] = 0
    out["content_swaps"] = 0
    last_swap_bytes = None
    for q, kind, a, _ in sorted(raw):
        if kind == 10 and q < lo:
            last_swap_bytes = a
        if not (lo <= q <= hi):
            continue
        if kind == 10:
            out["swaps"] += 1
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
    out["swaps_per_key"] = round(out["swaps"] / out["keys"], 3) if out["keys"] else None
    return out


def analyze(run):
    run = pathlib.Path(run)
    params = json.loads((run / "params.json").read_text(encoding="utf-8-sig"))
    freq, ev, raw, blob = load_trace(run)
    tool = params["Tool"]
    res = {"run": run.name, "tool": tool, "vsync_hz": params.get("VsyncHz"),
           "invalidate_ms": params.get("InvalidateMs"), "extra": params.get("Extra") or [],
           "priority": params.get("Priority", "BelowNormal")}
    lj = run / "load.json"
    if lj.exists():
        load = json.loads(lj.read_text(encoding="utf-8-sig"))
        res["cpu_busy_pct"] = load.get("cpu_busy_pct")
        res["cpu_busy_max_500ms_pct"] = load.get("cpu_busy_max_500ms_pct")
        res["windows_over_80pct"] = load.get("windows_over_80pct")
        res["timer_resolution_ms"] = [load.get("timer_resolution_ms_before"), load.get("timer_resolution_ms_after")]
    dl = run / "driver.log"
    if dl.exists():
        res["driver_notes"] = [l.split(" ", 1)[1] for l in dl.read_text(encoding="utf-8-sig").splitlines()
                               if "tool log" in l]
    if tool in ("held", "anim"):
        # The tool writes its log only at fclose: a short or truncated log means
        # it never finished (starved), and the run is not usable.
        lines = (run / "anim.txt").read_text().splitlines() if (run / "anim.txt").exists() else []
        want = params["A2"] if tool == "held" else params["A1"] * params["A2"]
        got = sum(1 for l in lines if (l.startswith("E ") if tool == "held" else l.startswith("W ")))
        if got != want or (lines and len(lines[-1].split()) != 3):
            raise ValueError(f"tool log incomplete: {got} of {want} {'cycles' if tool == 'held' else 'frames'}")
    if tool == "held":
        res["held"] = held(run, freq, ev, blob)
    elif tool == "anim":
        res["anim"] = anim(run, freq, ev, blob)
    else:
        rows = echo_rows(run, freq, ev, blob, params.get("Style", "plain"))
        res["rows"] = rows
        res["summary"] = {f: stats([r[f] for r in rows if f in r])
                          for f in ["key_msg", "pty_write", "echo_recv", "echo_write", "pty_output",
                                    "frame_update", "swap", "display"]}
        res["missing_display"] = sum(1 for r in rows if "display" not in r)
        res["missing_swap"] = sum(1 for r in rows if "swap" not in r)
        res["counts"] = counts(run, freq, raw)
    return res


def line(res):
    return (f"{line_body(res)} cpu_busy={res.get('cpu_busy_pct')}% max500ms={res.get('cpu_busy_max_500ms_pct')}%"
            f" over80={res.get('windows_over_80pct')} timer_res_ms={res.get('timer_resolution_ms')}") + (
        f" NOTE: {'; '.join(res['driver_notes'])}" if res.get("driver_notes") else "")


def line_body(res):
    name = res["run"]
    if "held" in res:
        h = dict(res["held"])
        keep = ["cycles", "cycles_shown", "presents_in_hold", "presents_total"]
        extra = [k for k in ("invalidations_in_hold", "presents_per_invalidation_in_hold",
                             "invalidation_interval_ms_median") if k in h]
        return f"{name:28s} " + " ".join(f"{k}={h[k]}" for k in keep + extra)
    if "anim" in res:
        a = res["anim"]
        g = a.get("gaps", {})
        return (f"{name:28s} " + " ".join(f"{k}={a[k]}" for k in
                ["frames", "frames_in_output", "frames_shown", "presents", "content_presents", "presents_per_s"])
                + (f" | n={g['n']} mean={g['mean']:.2f} min={g['min']:.2f} p10={g['p10']:.2f} p50={g['p50']:.2f}"
                   f" p90={g['p90']:.2f} max={g['max']:.2f}" if g else ""))
    s = res["summary"]
    c = res["counts"]
    def f(k):
        v = s.get(k)
        return f"{k}: n={v['n']} median={v['median']:.2f} p95={v['p95']:.2f} p99={v['p99']:.2f} max={v['max']:.2f}" if v else f"{k}: none"
    return (f"{name:28s} {f('display')} | {f('swap')} | keys={c['keys']} swaps={c['swaps']} "
            f"content_swaps={c['content_swaps']} frames={c['frames']} swaps_per_key={c['swaps_per_key']}"
            f" missing_display={res['missing_display']}")


if __name__ == "__main__":
    try:
        res = analyze(sys.argv[1])
    except (IndexError, KeyError, ValueError, FileNotFoundError) as err:
        # Typically an empty anim.txt: the tool was starved and never closed its log.
        print(f"ERROR {pathlib.Path(sys.argv[1]).name}: no usable run ({type(err).__name__}: {err})")
        sys.exit(2)
    if "--quiet" not in sys.argv:
        print(line(res))
    if "--json" in sys.argv:
        pathlib.Path(sys.argv[sys.argv.index("--json") + 1]).write_text(json.dumps(res, indent=1))
