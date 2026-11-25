r"""Scratch prototype of §3.5's soak process rules (round 21's AK1; round 22's Opus L1 and L2; round 23's Opus L2 and
L3: the required minimum and the copy's class; round 24's Muse L2: the class's shape, and two copies' classes
differ; round 25's Opus L1: release coverage names the other copy), judged the same way for
both copies, the packaged ReleaseFast one and the ReleaseSafe one. The harness records a run directory; this tool reads
it and fails the soak on any rule below. The role compare (role_compare2.py) does not see these: a process that
recorded its pairs and then panicked still passes it, so the soak's own rules have to.

Run directory:
  run.tsv       each row kind exactly once (DUPLICATE-ROW, MISSING-ROW; a duplicated row's value is not used):
                launch <TAB> <pid> <TAB> <start>      the soaked process, numeric PID and creation time, from the
                                                      handle the harness holds from its creation (the shared launcher
                                                      returns it, §19.3)
                mode <TAB> portable|standard          the copy's mode: portable when a marker sits beside the exe
                                                      (noctty.portable, as the harness places it)
                class <TAB> <class>                   the copy's --class, its own, which names its IPC pipe (with
                                                      --single-instance=false, so neither copy forwards its start);
                                                      shaped as the launch helper makes it, noctty-interactive-
                                                      <worktree slug>-<12 hex>-<sandbox slug> (BAD-CLASS), and
                                                      unlike the other copy's when --other-run names it
                                                      (SHARED-CLASS)
                exe <TAB> <full path>                 the copy's noctty.exe, by which WER reports are matched
                planned <TAB> <minutes>               the soak's planned duration, at least the caller's
                                                      --min-minutes (PLAN-TOO-SHORT)
                wer <TAB> suppressed|default          whether the run suppressed WER's dialog for the process (the
                                                      harness starts it with SEM_NOGPFAULTERRORBOX, which children
                                                      inherit)
                end <TAB> quit|early <TAB> <code>     how the process ended: after the harness's own quit, or before
                                                      it, with the code GetExitCodeProcess gave on the held handle
                                                      (never a default: no code is MALFORMED)
                end <TAB> stuck <TAB> -               still running when the harness's bound after its quit ran out
                                                      (a crashed thread held behind a dialog can leave the window
                                                      answering, so the quit's bound is what catches it)
  samples.tsv   <minute> <TAB> <pid>|- <TAB> <start>|- <TAB> yes|no|-
                                                      one sample a minute, minutes 1..N, each once, N at least the
                                                      planned duration: the process found by the held handle (gone:
                                                      `-` in all three fields), and whether its window answered
                                                      WM_NULL through SendMessageTimeout within the harness's bound
  crash\        must exist, empty when nothing crashed (NO-CRASH-DIR). The harness copies into it, at the end, every
                file of the copy's crash directories, which follow its mode: portable, <copy>\crash and the legacy
                <copy>\ghostty\crash (the portable root comes before any environment variable, src/os/xdg.zig:150-153,
                and `noctty/` is stripped, :88-98); standard, noctty\crash and ghostty\crash under XDG_STATE_HOME,
                else the redirected LOCALAPPDATA (src/crash/dir.zig, src/cli/crash_report.zig:56-57); and every WER
                report whose application path is the run's exe and whose time is after the launch (both soak copies
                are noctty.exe and run in parallel). Any file there is a crash report or a minidump.
Fails (exit 1): NO-MINIMUM (no --min-minutes), PLAN-TOO-SHORT, NO-OTHER-RUN (--min-minutes 480 or more, release
coverage's two-copy night, with no --other-run), BAD-CLASS, SHARED-CLASS, MALFORMED, DUPLICATE-ROW, MISSING-ROW, NO-SAMPLES, DUPLICATE-MINUTE, MISSING-MINUTE, SHORT-RUN (fewer
minutes than planned), PROCESS-GONE (a sample finds no process), PROCESS-CHANGED (another PID or start time than the
launch), HUNG (the window did not answer), EARLY-EXIT (ended before the harness's quit), QUIT-TIMEOUT (still running
when the quit's bound ran out), EXIT-CODE (an exit code other than 0), NO-CRASH-DIR, CRASH-REPORT (a file in crash\),
WER-NOT-SUPPRESSED.
A ReleaseSafe panic exits with code 3 and writes no minidump (Zig's default panic handler; only ReleaseFast traps into
the minidump filter), so EARLY-EXIT and EXIT-CODE are what catch it; a ReleaseFast crash leaves a minidump as well.
Usage: python -I soak_judge4.py <run-dir> --min-minutes <N> [--other-run <the other copy's run-dir>]
       (480 at release coverage, where --other-run is required: the two copies name each other; 60 for 0a's
       hour-long runs, one copy each)"""
import collections
import ntpath
import os
import re
import sys

for _stream in (sys.stdout, sys.stderr):   # r23: the report in UTF-8 whatever the console's code page
    _stream.reconfigure(encoding="utf-8", errors="backslashreplace")

args = sys.argv[1:]
min_minutes = None
failures = []
if "--min-minutes" in args:
    i = args.index("--min-minutes")
    v = args[i + 1] if i + 1 < len(args) else ""
    args = args[:i] + args[i + 2:]
    if v.isdigit() and int(v) > 0:
        min_minutes = int(v)
    else:
        failures.append(f"MALFORMED --min-minutes {v!r}")
else:
    failures.append("NO-MINIMUM the caller gave no --min-minutes, so no plan can be judged long enough")
other_run = None
if "--other-run" in args:
    i = args.index("--other-run")
    other_run = args[i + 1] if i + 1 < len(args) else ""
    args = args[:i] + args[i + 2:]
CLASS_RE = r"noctty-interactive-(?:[a-z0-9.-]+-)?[0-9a-f]{12}-[a-z0-9.][a-z0-9.-]*"
if min_minutes is not None and min_minutes >= 480 and other_run is None:   # r26 (round 25's Opus L1)
    failures.append("NO-OTHER-RUN release coverage soaks two copies the same night; name the other copy's run "
                    "directory with --other-run, so their classes are compared")
d = args[0]
KINDS = ("launch", "mode", "class", "exe", "planned", "wer", "end")
rows = collections.defaultdict(list)
for l in open(os.path.join(d, "run.tsv"), encoding="utf-8"):
    p = l.rstrip("\n").split("\t")
    if p[0] in KINDS:
        rows[p[0]].append(p)
    elif l.strip():
        failures.append(f"MALFORMED run.tsv: {l.strip()!r}")
val = {}
for k in KINDS:
    if not rows[k]:
        failures.append(f"MISSING-ROW run.tsv has no {k} row")
    elif len(rows[k]) > 1:
        failures.append(f"DUPLICATE-ROW run.tsv has {len(rows[k])} {k} rows; none is used")
    else:
        val[k] = rows[k][0]


def parsed(k, ok, conv):
    p = val.get(k)
    if p is None:
        return None
    if ok(p):
        return conv(p)
    failures.append(f"MALFORMED run.tsv {k} row: {chr(9).join(p)!r}")
    return None


launch = parsed("launch", lambda p: len(p) == 3 and p[1].isdigit() and p[2].isdigit(), lambda p: (p[1], p[2]))
mode = parsed("mode", lambda p: len(p) == 2 and p[1] in ("portable", "standard"), lambda p: p[1])
klass = parsed("class", lambda p: len(p) == 2 and p[1] != "" and not any(ch.isspace() for ch in p[1]), lambda p: p[1])
if klass is not None and not re.fullmatch(CLASS_RE, klass):
    failures.append(f"BAD-CLASS {klass!r} is not the launch helper's noctty-interactive-<worktree>-<hash>-<sandbox>")
if other_run is not None:   # r25 (round 24's Muse L2): the other copy of the same night must have another class
    other = None
    path_ = os.path.join(other_run, "run.tsv")
    for l in open(path_, encoding="utf-8") if other_run and os.path.exists(path_) else []:
        p = l.rstrip("\n").split("\t")
        if p[0] == "class" and len(p) == 2:
            other = p[1] if other is None else ""
    if not other:
        failures.append(f"MALFORMED --other-run {other_run!r}: no single class row in its run.tsv")
    elif klass is not None and other == klass:
        failures.append(f"SHARED-CLASS both copies run as {klass!r}, so they share one IPC pipe")
exe = parsed("exe", lambda p: len(p) == 2 and ntpath.isabs(p[1]) and p[1].lower().endswith(".exe"), lambda p: p[1])
planned = parsed("planned", lambda p: len(p) == 2 and p[1].isdigit() and int(p[1]) > 0, lambda p: int(p[1]))
if planned is not None and min_minutes is not None and planned < min_minutes:
    failures.append(f"PLAN-TOO-SHORT {planned} planned minutes, below the run's required {min_minutes}")
wer = parsed("wer", lambda p: len(p) == 2 and p[1] in ("suppressed", "default"), lambda p: p[1])
end = parsed("end", lambda p: len(p) == 3 and ((p[1] in ("quit", "early") and p[2].lstrip("-").isdigit())
                                              or (p[1] == "stuck" and p[2] == "-")),
             lambda p: (p[1], None if p[1] == "stuck" else int(p[2])))

samples, minutes = [], collections.Counter()
path = os.path.join(d, "samples.tsv")
for l in open(path, encoding="utf-8") if os.path.exists(path) else []:
    p = l.rstrip("\n").split("\t")
    if not l.strip():
        continue
    if len(p) != 4 or not p[0].isdigit() or int(p[0]) < 1:
        failures.append(f"MALFORMED samples.tsv: {l.strip()!r}")
        continue
    m = int(p[0])
    minutes[m] += 1
    if minutes[m] > 1:
        failures.append(f"DUPLICATE-MINUTE minute {m} recorded {minutes[m]} times")
        continue
    gone = p[1:] == ["-", "-", "-"]
    if not gone and not (p[1].isdigit() and p[2].isdigit() and p[3] in ("yes", "no")):
        failures.append(f"MALFORMED samples.tsv minute {m}: {chr(9).join(p[1:])!r}")
        continue
    samples.append((m, p[1], p[2], p[3], gone))
if not minutes:
    failures.append("NO-SAMPLES the harness recorded no per-minute sample")
else:
    for m in range(1, max(minutes) + 1):
        if m not in minutes:
            failures.append(f"MISSING-MINUTE minute {m}")
    if planned is not None and max(minutes) < planned:
        failures.append(f"SHORT-RUN {max(minutes)} of {planned} planned minutes")
for m, pid, start, responsive, gone in samples:
    if gone:
        failures.append(f"PROCESS-GONE minute {m}: no soaked process")
    elif launch and (pid, start) != launch:
        failures.append(f"PROCESS-CHANGED minute {m}: pid {pid} start {start}, launched as {launch[0]} {launch[1]}")
    elif responsive != "yes":
        failures.append(f"HUNG minute {m}: the window did not answer WM_NULL")
if end and end[0] == "early":
    failures.append("EARLY-EXIT the process ended before the harness's quit")
if end and end[0] == "stuck":
    failures.append("QUIT-TIMEOUT the process was still running when the quit's bound ran out")
elif end and end[1] != 0:
    failures.append(f"EXIT-CODE {end[1]}")
crash = os.path.join(d, "crash")
if not os.path.isdir(crash):
    failures.append("NO-CRASH-DIR the run directory has no crash\\ (empty is a pass, missing is not)")
for root, _, names in os.walk(crash) if os.path.isdir(crash) else []:
    for n in names:
        failures.append(f"CRASH-REPORT {os.path.relpath(os.path.join(root, n), crash)}")
if wer is not None and wer != "suppressed":
    failures.append("WER-NOT-SUPPRESSED a crash could wait in a WER dialog and look alive")
kc = collections.Counter(x.split(" ", 1)[0] for x in failures)
for x in failures:
    print("FAIL " + x)
print(f"{len(minutes)} minutes sampled of {planned if planned is not None else '?'} planned (at least "
      f"{min_minutes if min_minutes is not None else '?'} required); mode {mode or '?'}; class {klass or '?'}; "
      f"RESULT {'FAIL' if failures else 'PASS'} ({len(failures)} failures)"
      + ("" if not kc else " " + " ".join(f"{k}={v}" for k, v in sorted(kc.items()))))
sys.exit(1 if failures else 0)
