"""MEASUREMENT ONLY (LAT-01): per-keystroke latency from a lat-driver run.

usage: python -I analyze.py <run dir> [--json out.json] [--per-key]
"""
import bisect
import json
import pathlib
import statistics
import sys

KIND = {1: "key_msg", 2: "char_msg", 3: "pty_write", 4: "pty_output", 5: "renderer_wake",
        6: "frame_update", 7: "render_action", 8: "paint_begin", 9: "swap_begin", 10: "swap_end",
        11: "app_wake"}


def load(run):
    run = pathlib.Path(run)
    freq = None
    events = {k: [] for k in KIND.values()}
    blob = bytearray()
    for line in (run / "latency.txt").read_text().splitlines():
        parts = line.split(" ")
        if parts[0] == "F":
            freq = int(parts[1])
        elif parts[0] == "E":
            q, kind, a, b = int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4])
            events[KIND[kind]].append((q, a, b))
        elif parts[0] == "B":
            off = int(parts[1])
            data = bytes.fromhex(parts[2])
            if len(blob) < off:
                blob.extend(b"\0" * (off - len(blob)))
            blob[off:off + len(data)] = data
    for v in events.values():
        v.sort()
    keys_down, keys_up = {}, {}
    for line in (run / "keys.txt").read_text().splitlines():
        t, i, q, vk = line.split()
        (keys_down if t == "D" else keys_up)[int(i)] = (int(q), int(vk))
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
    return freq, events, bytes(blob), keys_down, keys_up, recv, sent


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


def analyze(run):
    freq, ev, blob, kd, ku, recv, sent = load(run)
    ms = lambda d: d * 1000.0 / freq
    texts = text_positions(blob)
    # Echoes of the typed sequence, in order.
    n = len(kd)
    echo_offsets = {}
    ti = 0
    # Skip the banner: start matching after "ready".
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
    # Redrawing styles re-emit earlier characters, so map each echo by the
    # time lat-echo wrote it instead: the first chunk noctty read after it.
    launch = (pathlib.Path(run) / "driver.log").read_text()
    by_write = " line\n" in launch.split("launch:", 1)[-1].split("\n", 1)[0] + "\n" or \
        " tui\n" in launch.split("launch:", 1)[-1].split("\n", 1)[0] + "\n"
    if by_write:
        echo_offsets = {}
        for k in range(min(n, len(sent))):
            oi = bisect.bisect_left(outputs, (sent[k][0], -1, -1))
            if oi < len(outputs):
                echo_offsets[k] = outputs[oi][1] - 1
    frames = ev["frame_update"]
    frame_bytes = [f[1] for f in frames]
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
            # first frame/swap whose frame includes the echo, at/after the output
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


def stats(values):
    v = sorted(values)
    if not v:
        return None
    p95 = v[min(len(v) - 1, int(round(0.95 * (len(v) - 1))))]
    return {"n": len(v), "median": statistics.median(v), "p95": p95, "max": v[-1], "mean": statistics.fmean(v)}


FIELDS = ["key_msg", "pty_write", "echo_recv", "echo_write", "pty_output", "frame_update", "swap", "display"]


def summarize(rows):
    out = {}
    for f in FIELDS:
        s = stats([r[f] for r in rows if f in r])
        if s:
            out[f] = s
    seg = {
        "post->key_msg": ("post", "key_msg"),
        "key_msg->pty_write": ("key_msg", "pty_write"),
        "pty_write->echo_recv": ("pty_write", "echo_recv"),
        "echo_write->pty_output": ("echo_write", "pty_output"),
        "pty_output->frame": ("pty_output", "frame_update"),
        "frame->swap": ("frame_update", "swap"),
    }
    for name, (a, b) in seg.items():
        vals = [r[b] - (r[a] if a != "post" else 0.0) for r in rows if b in r and (a == "post" or a in r)]
        s = stats(vals)
        if s:
            out[name] = s
    return out


if __name__ == "__main__":
    run = sys.argv[1]
    rows = analyze(run)
    summ = summarize(rows)
    missing = sum(1 for r in rows if "swap" not in r)
    print(f"{run}: keys={len(rows)} missing_swap={missing}")
    for k, s in summ.items():
        print(f"  {k:24s} n={s['n']:4d} median={s['median']:7.2f} p95={s['p95']:7.2f} max={s['max']:7.2f} mean={s['mean']:7.2f}")
    if "--per-key" in sys.argv:
        for r in rows:
            print("   ", {k: (round(v, 2) if isinstance(v, float) else v) for k, v in r.items() if k != "post"})
    if "--json" in sys.argv:
        out = sys.argv[sys.argv.index("--json") + 1]
        pathlib.Path(out).write_text(json.dumps({"rows": rows, "summary": summ}, indent=1))
