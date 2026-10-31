"""MEASUREMENT ONLY (LAT-02): which animation frames reached a present.

usage: python -I anim_analyze.py <run dir> [more run dirs]

anim.exe writes each frame inside synchronized output; frame i ends at the
i-th ESC[?2026l in the pty output. Frame i was presented if some
SwapBuffers drew a frame update whose output byte count lies in
[end_i, end_{i+1}). Also counts presents during the animation and how many
carried new output.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))

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
    writes = [int(l.split()[1]) for l in (run / "anim.txt").read_text().splitlines() if l.startswith("W")]
    lo, hi = writes[0], writes[-1] + freq // 10
    in_window = [s for s in swaps if lo <= s[0] <= hi]
    shown = set()
    import bisect
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
    return {
        "frames": len(writes), "frames_in_output": len(ends), "frames_shown": len(shown),
        "presents": len(in_window), "content_presents": content,
        "presents_per_s": len(in_window) / secs,
    }


for run in sys.argv[1:]:
    r = analyze(run)
    print(f"{pathlib.Path(run).name:28s} " + " ".join(f"{k}={v:.1f}" if isinstance(v, float) else f"{k}={v}" for k, v in r.items()))
