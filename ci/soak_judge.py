r"""The soak judge: PLAN.md §3.5's process rules and slope check for one soak run directory.

test/windows/interactive-win11-soak.ps1 records a run directory; this tool reads it and fails the soak on
any rule below. Release coverage judges both copies of its night this way (the packaged ReleaseFast one and
the ReleaseSafe one); Phase 0a's 120-minute runs (60 of warm-up, 60 judged) use it with --min-minutes 120.
The role compare does not see
these rules: a copy that recorded its thread-role pairs and then panicked still passes it, so the soak's own
rules have to catch the end.

Ported from the plan's scratch prototype (tools\soak_judge4.py, §15.7's controls 94 to 100, 107 to 115, 120,
121, 124, 140 to 142 and 164, now ci/test_soak_judge.py): its rules, row kinds, failure names and its
--min-minutes and --other-run interface are kept. What is new is the metrics stage below: the per-minute
metrics and thread rows the soak records, the workload they were taken under, and the slope check.

Usage:
  python -I ci/soak_judge.py <run-dir> --min-minutes <N> [--other-run <dir>] [--thresholds <file>]
    --min-minutes  the run's required minimum: 480 at release coverage, 120 for 0a's runs (the shortest the
                   repository thresholds accept is their warm-up plus window: MINIMUM-TOO-SHORT below it)
    --other-run    the night's other copy's run directory (required from 480 minutes: NO-OTHER-RUN)
    --thresholds   the slope thresholds; default soak-thresholds.tsv beside this file
Exit 0 on a pass, 1 on any failure, 2 on a usage error. The report is UTF-8 whatever the console's code page.

Run directory, process rules (as the prototype):
  run.tsv       each row kind exactly once (DUPLICATE-ROW, MISSING-ROW; a duplicated row's value is not used):
                launch <TAB> <pid> <TAB> <start>      the soaked process, numeric PID and creation time (FILETIME),
                                                      from the handle the harness holds from its creation
                mode <TAB> portable|standard          portable when a marker sits beside the exe
                class <TAB> <class>                   the copy's --class, which names its IPC pipe; shaped as the
                                                      launch helper makes it (BAD-CLASS), and unlike the other
                                                      copy's when --other-run names it (SHARED-CLASS)
                exe <TAB> <full path>                 the copy's noctty.exe, by which WER reports are matched
                planned <TAB> <minutes>               at least --min-minutes (PLAN-TOO-SHORT)
                wer <TAB> suppressed|default          whether WER's dialog cannot hold a crashed copy: it
                                                      started with SEM_NOGPFAULTERRORBOX, inside a job that
                                                      ends a process on an unhandled exception (the process's
                                                      own mode can change during a run; the job's limit holds)
                end <TAB> quit|early <TAB> <code>     ended after the harness's quit or before it, with the code
                                                      GetExitCodeProcess gave on the held handle
                end <TAB> unasked <TAB> <code>        ended during the quit's wait with no WM_CLOSE of the
                                                      harness reaching one of its windows (UNASKED-EXIT): nothing
                                                      shows the exit followed the quit
                end <TAB> stuck <TAB> -               still running when the quit's bound ran out
  samples.tsv   <minute> <TAB> <pid>|- <TAB> <start>|- <TAB> yes|no|-
                                                      one sample a minute, minutes 1..N, each once, N at least the
                                                      planned duration; `-` in all three when the process is gone;
                                                      whether its window answered WM_NULL within the bound
  crash\        must exist (NO-CRASH-DIR); any file in it is a crash report, a minidump or a WER report the
                harness matched to the copy (CRASH-REPORT)

Run directory, metrics stage (new):
  metrics.tsv   the header line `minute handles threads private_bytes working_set commit_charge gdi_objects
                user_objects children surfaces churn missed` (TAB-separated), then one row per sampled minute
                (MISSING-METRIC, DUPLICATE-METRIC). On a live sample every value is a whole number; on a gone
                one every value is `-`. The metrics are taken at the harness's baseline (one tab, one pane,
                after idle time), so each minute's values compare like with like:
                  handles        GetProcessHandleCount
                  threads        the process's threads (one threads.tsv row each)
                  private_bytes  PROCESS_MEMORY_COUNTERS_EX2.PrivateUsage
                  working_set    WorkingSetSize
                  commit_charge  PrivateUsage + SharedCommitUsage
                  gdi_objects, user_objects   GetGuiResources
                  children       the other processes in the harness's job (each pane's ConPTY host and shell)
                  surfaces       the terminal panes (`noctty.win32` windows) at the sample: 1, or NOT-AT-BASELINE
                  churn          workload actions verified in the minute before the sample
                  missed         workload actions that did not take effect (WORKLOAD-MISSED)
  threads.tsv   the header `minute tid start name`, then one row per thread of each live sample: its start
                address as module+offset (`?` when unreadable) and its description (empty when unnamed). A
                thread's kind is its name, else its start address.
  timing.tsv    the header `minute probe_start_ms probe_end_ms workload_ms`, then one row per sampled
                minute (MISSING-TIMING, DUPLICATE-TIMING), minutes and times strictly increasing and no probe
                ending before it starts (MALFORMED otherwise): when the minute's probe (liveness, the windows,
                their WM_NULL answers) started and ended, in ms of the driver's clock, on which minute m is due
                at m x 60 000, and how long the minute's churn ran. A probe that started before its due time
                fails (EARLY-SAMPLE: it did not look at the copy on its schedule); one that started more than
                LATE_SAMPLE_MS after it, or ended more than LATE_SAMPLE_MS + RESPONSE_BOUND_MS after it, fails
                (LATE-SAMPLE): for that long nothing looked at the copy at its due time, so a hang there would
                read as an answer once it ended.
Fails (metrics stage): NO-METRICS, NO-THREADS, NO-TIMING, MISSING-METRIC, DUPLICATE-METRIC, MISSING-TIMING,
DUPLICATE-TIMING, MALFORMED, EARLY-SAMPLE, LATE-SAMPLE, NOT-AT-BASELINE, WORKLOAD-MISSED, NO-WORKLOAD (fewer than half the
live minutes did any churn), BAD-THRESHOLDS, MINIMUM-TOO-SHORT (a required minimum that leaves no slope window
after the warm-up: the call is refused, never judged without a slope), NO-SLOPE-SAMPLES (fewer live minutes
after the warm-up than the window), SLOPE (a metric's least-squares slope over the live minutes after the
warm-up rises with confidence: its lower bound, slope - Z x standard error, per hour, is above the metric's
floor; so a longer run, whose standard error is smaller, holds a slow rise to account), THREAD-BOUND (more
threads after the warm-up than the bound), KIND-BOUND (more threads of one kind than its bound). A plan below
the minimum fails PLAN-TOO-SHORT rather than the slope check.

Fails (process rules): NO-MINIMUM, PLAN-TOO-SHORT, NO-OTHER-RUN, BAD-CLASS, SHARED-CLASS, MALFORMED,
DUPLICATE-ROW, MISSING-ROW, NO-SAMPLES, DUPLICATE-MINUTE, MISSING-MINUTE, SHORT-RUN, PROCESS-GONE,
PROCESS-CHANGED, HUNG, EARLY-EXIT, UNASKED-EXIT, QUIT-TIMEOUT, EXIT-CODE, NO-CRASH-DIR, CRASH-REPORT, WER-NOT-SUPPRESSED.
A ReleaseSafe panic exits with code 3 and writes no minidump (Zig's default panic handler; only ReleaseFast
traps into the minidump filter), so EARLY-EXIT and EXIT-CODE are what catch it.

Thresholds file: `#` comments, blank lines, and TAB-separated rows, each once:
  warmup <minutes>            the warm-up the slope check skips
  window <minutes>            the fewest live minutes after it a slope is fitted over; a --min-minutes below
                              warmup + window is refused (MINIMUM-TOO-SHORT)
  floor <metric> <per hour>   one for every metric above (handles .. children): the rise a slope's lower
                              bound may reach
  bound threads <max>         the most threads a sample after the warm-up may hold
  kind <kind> <max>           optional: the most threads of one kind after the warm-up
"""
import collections
import math
import ntpath
import os
import re
import sys

Z = 3.0                 # the slope's lower bound is slope - Z x its standard error
LATE_SAMPLE_MS = 5000   # a probe that starts later than this after its due time saw nothing at it
RESPONSE_BOUND_MS = 5000   # the harness's WM_NULL bound: how long a probe may take once it has started
BASELINE_SURFACES = 1
TIMING_HEADER = ("minute", "probe_start_ms", "probe_end_ms", "workload_ms")
KINDS = ("launch", "mode", "class", "exe", "planned", "wer", "end")
METRICS = ("handles", "threads", "private_bytes", "working_set", "commit_charge", "gdi_objects", "user_objects",
           "children")
METRICS_HEADER = ("minute",) + METRICS + ("surfaces", "churn", "missed")
THREADS_HEADER = ("minute", "tid", "start", "name")
# Get-InteractiveWin11LaunchArguments: noctty-interactive-<worktree slug>-<12 hex>-<sandbox slug>
CLASS_RE = r"noctty-interactive-[a-z0-9.-]+-[0-9a-f]{12}-[a-z0-9.][a-z0-9.-]*"   # the slug is never empty
USAGE = ("usage: python -I soak_judge.py <run-dir> --min-minutes <N> [--other-run <dir>] "
         "[--thresholds <file>]")


def read_lines(path):
    """(lines without their line ends, numbers of the lines that are not UTF-8), or (None, []) when the file does
    not exist. A line that is not UTF-8 is left out, so a corrupt byte can never pass as another name or kind."""
    if not os.path.isfile(path):
        return None, []
    with open(path, "rb") as fh:
        data = fh.read()
    lines, bad = [], []
    for number, raw in enumerate(data.split(b"\n"), 1):
        if raw.endswith(b"\r"):
            raw = raw[:-1]
        try:
            lines.append(raw.decode("utf-8"))
        except UnicodeDecodeError:
            bad.append(number)
    return lines, bad


def is_count(text):
    """A whole number the harness can write: ASCII digits, at most 18 of them (below 2**63), so no record can
    reach Python's integer-string limit or overflow the slope's floating point."""
    return text.isascii() and text.isdigit() and len(text) <= 18


def least_squares(points):
    """(slope, standard error) of y on x by ordinary least squares; the error is 0 with fewer than 3 points."""
    n = len(points)
    mx = sum(x for x, _ in points) / n
    my = sum(y for _, y in points) / n
    sxx = sum((x - mx) ** 2 for x, _ in points)
    if sxx == 0:
        return 0.0, 0.0
    slope = sum((x - mx) * (y - my) for x, y in points) / sxx
    if n < 3:
        return slope, 0.0
    resid = sum((y - (my + slope * (x - mx))) ** 2 for x, y in points)
    return slope, (resid / (n - 2) / sxx) ** 0.5


class Judge:
    def __init__(self, run_dir, min_minutes, other_run, thresholds_path):
        self.d = run_dir
        self.min_minutes = min_minutes
        self.other_run = other_run
        self.thresholds_path = thresholds_path
        self.failures = []
        self.info = []

    def fail(self, text):
        self.failures.append(text)

    def read(self, path, label):
        """The lines of `path` (None when it is missing); each line that is not UTF-8 fails as MALFORMED."""
        lines, bad = read_lines(path)
        for number in bad:
            self.fail(f"MALFORMED {label} line {number} is not UTF-8")
        return lines

    # -- process rules (the prototype's) -------------------------------------------------------------------
    def process_rules(self):
        if self.min_minutes is not None and self.min_minutes >= 480 and self.other_run is None:
            self.fail("NO-OTHER-RUN release coverage soaks two copies the same night; name the other copy's run "
                      "directory with --other-run, so their classes are compared")
        rows = collections.defaultdict(list)
        lines = self.read(os.path.join(self.d, "run.tsv"), "run.tsv")
        for line in lines or []:
            p = line.split("\t")
            if p[0] in KINDS:
                rows[p[0]].append(p)
            elif line.strip():
                self.fail(f"MALFORMED run.tsv: {line.strip()!r}")
        self.val = {}
        for k in KINDS:
            if not rows[k]:
                self.fail(f"MISSING-ROW run.tsv has no {k} row")
            elif len(rows[k]) > 1:
                self.fail(f"DUPLICATE-ROW run.tsv has {len(rows[k])} {k} rows; none is used")
            else:
                self.val[k] = rows[k][0]

        self.launch = self.parsed("launch", lambda p: len(p) == 3 and is_count(p[1]) and is_count(p[2]),
                                  lambda p: (p[1], p[2]))
        self.mode = self.parsed("mode", lambda p: len(p) == 2 and p[1] in ("portable", "standard"), lambda p: p[1])
        self.klass = self.parsed("class", lambda p: len(p) == 2 and p[1] != "" and not any(c.isspace() for c in p[1]),
                                 lambda p: p[1])
        if self.klass is not None and not re.fullmatch(CLASS_RE, self.klass):
            self.fail(f"BAD-CLASS {self.klass!r} is not the launch helper's "
                      "noctty-interactive-<worktree>-<hash>-<sandbox>")
        if self.other_run is not None:
            # The other copy's class row: exactly one, well formed and of the helper's shape, or the comparison
            # proves nothing.
            peer = self.read(os.path.join(self.other_run, "run.tsv"), "--other-run run.tsv") if self.other_run else None
            rows = [p for p in (line.split("\t") for line in peer or []) if p[0] == "class"]
            other = rows[0][1] if len(rows) == 1 and len(rows[0]) == 2 and re.fullmatch(CLASS_RE, rows[0][1]) else None
            if not other:
                self.fail(f"MALFORMED --other-run {self.other_run!r}: no single class row of the helper's shape in "
                          "its run.tsv")
            elif self.klass is not None and other == self.klass:
                self.fail(f"SHARED-CLASS both copies run as {self.klass!r}, so they share one IPC pipe")
        self.parsed("exe", lambda p: len(p) == 2 and ntpath.isabs(p[1]) and p[1].lower().endswith(".exe"),
                    lambda p: p[1])
        self.planned = self.parsed("planned", lambda p: len(p) == 2 and is_count(p[1]) and int(p[1]) > 0,
                                   lambda p: int(p[1]))
        if self.planned is not None and self.min_minutes is not None and self.planned < self.min_minutes:
            self.fail(f"PLAN-TOO-SHORT {self.planned} planned minutes, below the run's required {self.min_minutes}")
        wer = self.parsed("wer", lambda p: len(p) == 2 and p[1] in ("suppressed", "default"), lambda p: p[1])
        end = self.parsed("end", lambda p: len(p) == 3 and ((p[1] in ("quit", "early", "unasked")
                                                              and is_count(p[2].removeprefix("-")))
                                                             or (p[1] == "stuck" and p[2] == "-")),
                          lambda p: (p[1], None if p[1] == "stuck" else int(p[2])))

        self.samples, self.minutes = {}, collections.Counter()
        for line in self.read(os.path.join(self.d, "samples.tsv"), "samples.tsv") or []:
            p = line.split("\t")
            if not line.strip():
                continue
            if len(p) != 4 or not is_count(p[0]) or int(p[0]) < 1:
                self.fail(f"MALFORMED samples.tsv: {line.strip()!r}")
                continue
            m = int(p[0])
            self.minutes[m] += 1
            if self.minutes[m] > 1:
                self.fail(f"DUPLICATE-MINUTE minute {m} recorded {self.minutes[m]} times")
                continue
            gone = p[1:] == ["-", "-", "-"]
            if not gone and not (is_count(p[1]) and is_count(p[2]) and p[3] in ("yes", "no")):
                self.fail(f"MALFORMED samples.tsv minute {m}: {chr(9).join(p[1:])!r}")
                continue
            self.samples[m] = (p[1], p[2], p[3], gone)
        if not self.minutes:
            self.fail("NO-SAMPLES the harness recorded no per-minute sample")
        else:
            # Each gap once, as a range: a corrupt minute number cannot make the judge list billions of minutes.
            expected = 1
            for m in sorted(self.minutes):
                if m > expected:
                    self.fail(f"MISSING-MINUTE minute {expected}" if m == expected + 1
                              else f"MISSING-MINUTE minutes {expected}-{m - 1}")
                expected = m + 1
            if self.planned is not None and max(self.minutes) < self.planned:
                self.fail(f"SHORT-RUN {max(self.minutes)} of {self.planned} planned minutes")
        for m in sorted(self.samples):
            pid, start, responsive, gone = self.samples[m]
            if gone:
                self.fail(f"PROCESS-GONE minute {m}: no soaked process")
            elif self.launch and (pid, start) != self.launch:
                self.fail(f"PROCESS-CHANGED minute {m}: pid {pid} start {start}, launched as "
                          f"{self.launch[0]} {self.launch[1]}")
            elif responsive != "yes":
                self.fail(f"HUNG minute {m}: the window did not answer WM_NULL")
        if end and end[0] == "early":
            self.fail("EARLY-EXIT the process ended before the harness's quit")
        if end and end[0] == "unasked":
            self.fail("UNASKED-EXIT the process ended with no WM_CLOSE of the harness reaching one of its windows")
        if end and end[0] == "stuck":
            self.fail("QUIT-TIMEOUT the process was still running when the quit's bound ran out")
        elif end and end[1] != 0:
            self.fail(f"EXIT-CODE {end[1]}")
        crash = os.path.join(self.d, "crash")
        if not os.path.isdir(crash):
            self.fail("NO-CRASH-DIR the run directory has no crash\\ (empty is a pass, missing is not)")
        unreadable = []
        for root, _, names in os.walk(crash, onerror=unreadable.append) if os.path.isdir(crash) else []:
            for n in sorted(names):
                self.fail(f"CRASH-REPORT {os.path.relpath(os.path.join(root, n), crash)}")
        for error in unreadable:   # evidence that cannot be listed cannot be ruled out
            self.fail(f"CRASH-REPORT unreadable {os.path.relpath(error.filename or crash, crash)}")
        if wer is not None and wer != "suppressed":
            self.fail("WER-NOT-SUPPRESSED a crash could wait in a WER dialog and look alive")

    def parsed(self, k, ok, conv):
        p = self.val.get(k)
        if p is None:
            return None
        if ok(p):
            return conv(p)
        self.fail(f"MALFORMED run.tsv {k} row: {chr(9).join(p)!r}")
        return None

    # -- metrics stage --------------------------------------------------------------------------------------
    def read_thresholds(self):
        """{warmup, window, floors, bound, kinds}, or None after a BAD-THRESHOLDS failure."""
        floors, kinds, single = {}, {}, {}
        lines = self.read(self.thresholds_path, "thresholds")
        if lines is None:
            self.fail(f"BAD-THRESHOLDS no thresholds file at {self.thresholds_path!r}")
            return None
        bad = []
        for line in lines:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            p = line.split("\t")
            if len(p) == 3 and p[0] == "floor" and p[1] in METRICS and p[1] not in floors:
                try:
                    value = float(p[2])
                except ValueError:
                    value = -1.0
                if math.isfinite(value) and value >= 0:
                    floors[p[1]] = value
                    continue
            elif len(p) == 2 and p[0] in ("warmup", "window") and p[0] not in single and is_count(p[1]):
                single[p[0]] = int(p[1])
                if p[0] != "window" or single[p[0]] >= 3:
                    continue
            elif len(p) == 3 and p[0] == "bound" and p[1] == "threads" and "bound" not in single and is_count(p[2]):
                single["bound"] = int(p[2])
                continue
            elif len(p) == 3 and p[0] == "kind" and p[1] and p[1] not in kinds and is_count(p[2]):
                kinds[p[1]] = int(p[2])
                continue
            bad.append(line)
        missing = [m for m in METRICS if m not in floors] + [k for k in ("warmup", "window", "bound") if k not in single]
        if bad or missing:
            self.fail(f"BAD-THRESHOLDS {self.thresholds_path!r}: rows not understood {bad!r}, rows missing "
                      f"{missing!r} (one floor per metric, a warmup, a window of at least 3 minutes, a threads bound)")
            return None
        return dict(single, floors=floors, kinds=kinds)

    def metrics_stage(self):
        thresholds = self.read_thresholds()
        live = {m for m, s in self.samples.items() if not s[3]}
        sampled = set(self.samples)
        metrics = {}
        lines = self.read(os.path.join(self.d, "metrics.tsv"), "metrics.tsv")
        if lines is None:
            self.fail("NO-METRICS the run directory has no metrics.tsv")
        else:
            body = [line for line in lines if line.strip()]
            if not body or tuple(body[0].split("\t")) != METRICS_HEADER:
                self.fail(f"MALFORMED metrics.tsv header {body[0] if body else ''!r}")
                body = []
            seen = collections.Counter()
            for line in body[1:]:
                p = line.split("\t")
                if len(p) != len(METRICS_HEADER) or not is_count(p[0]) or int(p[0]) < 1:
                    self.fail(f"MALFORMED metrics.tsv: {line.strip()!r}")
                    continue
                m = int(p[0])
                seen[m] += 1
                if seen[m] > 1:
                    self.fail(f"DUPLICATE-METRIC minute {m} has {seen[m]} metrics rows; none is used")
                    metrics.pop(m, None)
                    continue
                values = p[1:]
                if m not in sampled:
                    self.fail(f"MALFORMED metrics.tsv minute {m} has metrics and no sample")
                elif m in live and all(is_count(v) for v in values):
                    metrics[m] = dict(zip(METRICS_HEADER[1:], map(int, values)))
                elif m not in live and all(v == "-" for v in values):
                    pass
                else:
                    state = "live" if m in live else "gone"
                    self.fail(f"MALFORMED metrics.tsv minute {m} ({state} sample): {chr(9).join(values)!r}")
            for m in sorted(sampled):
                if seen[m] == 0:
                    self.fail(f"MISSING-METRIC minute {m}")
            for m in sorted(metrics):
                row = metrics[m]
                if row["surfaces"] != BASELINE_SURFACES:
                    self.fail(f"NOT-AT-BASELINE minute {m}: {row['surfaces']} panes at the sample, the baseline "
                              f"is {BASELINE_SURFACES}")
                if row["missed"] > 0:
                    self.fail(f"WORKLOAD-MISSED minute {m}: {row['missed']} workload actions did not take effect")
            if live and seen and 2 * sum(1 for m in metrics if metrics[m]["churn"] > 0) < len(live):
                self.fail(f"NO-WORKLOAD only {sum(1 for m in metrics if metrics[m]['churn'] > 0)} of {len(live)} "
                          "live minutes did any tab, split, flood or resize")

        kinds_by_minute = {}
        tlines = self.read(os.path.join(self.d, "threads.tsv"), "threads.tsv")
        if tlines is None:
            self.fail("NO-THREADS the run directory has no threads.tsv")
        else:
            body = [line for line in tlines if line.strip()]
            if not body or tuple(body[0].split("\t")) != THREADS_HEADER:
                self.fail(f"MALFORMED threads.tsv header {body[0] if body else ''!r}")
                body = []
            per_minute = collections.defaultdict(collections.Counter)
            count = collections.Counter()
            tids = set()
            for line in body[1:]:
                p = line.split("\t")
                if len(p) != 4 or not is_count(p[0]) or not is_count(p[1]) or not p[2]:
                    self.fail(f"MALFORMED threads.tsv: {line.strip()!r}")
                    continue
                m = int(p[0])
                if m not in live:
                    self.fail(f"MALFORMED threads.tsv minute {m} has threads and no live sample")
                    continue
                if (m, p[1]) in tids:   # a copied row would hide a thread of another kind
                    self.fail(f"MALFORMED threads.tsv minute {m} lists thread {p[1]} twice")
                    continue
                tids.add((m, p[1]))
                count[m] += 1
                per_minute[m][p[3] if p[3] else p[2]] += 1
            for m in sorted(metrics):
                if count[m] != metrics[m]["threads"]:
                    self.fail(f"MALFORMED threads.tsv minute {m}: {count[m]} thread rows, metrics.tsv says "
                              f"{metrics[m]['threads']}")
            kinds_by_minute = per_minute

        # When each minute's probe ran: one outside its bounds did not look at the copy at its due time.
        tlines = self.read(os.path.join(self.d, "timing.tsv"), "timing.tsv")
        if tlines is None:
            self.fail("NO-TIMING the run directory has no timing.tsv")
        else:
            body = [line for line in tlines if line.strip()]
            if not body or tuple(body[0].split("\t")) != TIMING_HEADER:
                self.fail(f"MALFORMED timing.tsv header {body[0] if body else ''!r}")
                body = []
            timed = collections.Counter()
            previous = None   # the row before, in file order: (minute, probe_end_ms)
            for line in body[1:]:
                p = line.split("\t")
                if len(p) != 4 or not all(is_count(x) for x in p) or int(p[0]) < 1:
                    self.fail(f"MALFORMED timing.tsv: {line.strip()!r}")
                    continue
                m, start, end = int(p[0]), int(p[1]), int(p[2])
                timed[m] += 1
                if timed[m] > 1:
                    self.fail(f"DUPLICATE-TIMING minute {m} has {timed[m]} timing rows")
                    continue
                if end < start:
                    self.fail(f"MALFORMED timing.tsv minute {m}: its probe ends at {end} ms, before it starts at "
                              f"{start} ms")
                    continue
                if previous is not None and (m <= previous[0] or start <= previous[1]):
                    self.fail(f"MALFORMED timing.tsv minute {m}: its probe (from {start} ms) does not follow minute "
                              f"{previous[0]}'s, which ended at {previous[1]} ms; minutes and times must increase")
                previous = (m, end)
                due = m * 60000   # the driver's clock: minute m is due at m x 60 000 ms
                if m not in self.minutes:
                    self.fail(f"MALFORMED timing.tsv minute {m} has a time and no sample")
                elif start < due:
                    self.fail(f"EARLY-SAMPLE minute {m}'s probe started {due - start} ms before its due time")
                elif start - due > LATE_SAMPLE_MS:
                    self.fail(f"LATE-SAMPLE minute {m}'s probe started {start - due} ms after its due time, beyond "
                              f"{LATE_SAMPLE_MS} ms")
                elif end - due > LATE_SAMPLE_MS + RESPONSE_BOUND_MS:
                    self.fail(f"LATE-SAMPLE minute {m}'s probe ended {end - due} ms after its due time, beyond "
                              f"{LATE_SAMPLE_MS + RESPONSE_BOUND_MS} ms ({LATE_SAMPLE_MS} to start, "
                              f"{RESPONSE_BOUND_MS} to answer)")
            for m in sorted(self.minutes):
                if timed[m] == 0:
                    self.fail(f"MISSING-TIMING minute {m}")

        if thresholds is None or lines is None:   # no slope without thresholds, or without metrics.tsv (NO-METRICS)
            return
        warmup, window_min, bound = thresholds["warmup"], thresholds["window"], thresholds["bound"]
        floors, kind_bounds = thresholds["floors"], thresholds["kinds"]
        # A minimum that leaves no slope window is refused, never judged without the slope. The slope judges
        # the samples a plan of the required length gives (a shorter plan fails PLAN-TOO-SHORT instead).
        refused = self.min_minutes is not None and self.min_minutes < warmup + window_min
        if refused:
            self.fail(f"MINIMUM-TOO-SHORT --min-minutes {self.min_minutes} leaves no slope window: the warm-up is "
                      f"{warmup} minutes and a slope needs {window_min} after it")
        applies = (not refused and self.min_minutes is not None
                   and self.planned is not None and self.planned >= self.min_minutes)
        after = sorted(m for m in metrics if m > warmup)
        span = f"minutes {after[0]}-{after[-1]}" if after else "no minutes"
        if not applies:
            self.info.append("slope check: not run (see the failures above)")
        elif len(after) < window_min:
            self.fail(f"NO-SLOPE-SAMPLES {len(after)} live minutes after the {warmup}-minute warm-up, "
                      f"at least {window_min} needed")
        else:
            for metric in METRICS:
                slope, se = least_squares([(m, metrics[m][metric]) for m in after])
                per_hour, se_hour = slope * 60, se * 60
                lower = per_hour - Z * se_hour
                self.info.append(f"SLOPE-INFO {metric} slope={per_hour:+.4f}/h se={se_hour:.4f}/h "
                                 f"lower={lower:+.4f}/h floor={floors[metric]:g}/h n={len(after)} {span}")
                if lower > floors[metric]:
                    self.fail(f"SLOPE {metric} rises {per_hour:+.2f}/h over {span} ({len(after)} samples, standard "
                              f"error {se_hour:.2f}/h): its lower bound {lower:+.2f}/h is above the floor "
                              f"{floors[metric]:g}/h")
            worst = max(after, key=lambda m: metrics[m]["threads"])
            self.info.append(f"THREADS-INFO max {metrics[worst]['threads']} at minute {worst}, bound {bound}")
            if metrics[worst]["threads"] > bound:
                self.fail(f"THREAD-BOUND {metrics[worst]['threads']} threads at minute {worst}, above the bound "
                          f"{bound}")
            for kind, most in sorted(kind_bounds.items()):
                top = max(after, key=lambda m: kinds_by_minute.get(m, {}).get(kind, 0))
                n = kinds_by_minute.get(top, {}).get(kind, 0)
                if n > most:
                    self.fail(f"KIND-BOUND {n} threads of kind {kind!r} at minute {top}, above the bound {most}")
        # Every kind seen, with its range, as evidence (counted by name, else by start address).
        window = after if applies and after else sorted(kinds_by_minute)
        names = sorted({k for m in window for k in kinds_by_minute.get(m, {})})
        for kind in names:
            counts = [kinds_by_minute.get(m, {}).get(kind, 0) for m in window]
            self.info.append(f"KIND-INFO {kind!r} min={min(counts)} max={max(counts)}")


def main(argv):
    for stream in (sys.stdout, sys.stderr):   # the report in UTF-8 whatever the console's code page
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")
    args = list(argv)
    opts = {}
    positional = []
    while args:
        a = args.pop(0)
        if a in ("--min-minutes", "--other-run", "--thresholds"):
            opts[a] = args.pop(0) if args else ""
        elif a.startswith("--"):
            print(f"unknown option {a!r}\n{USAGE}", file=sys.stderr)
            return 2
        else:
            positional.append(a)
    if len(positional) != 1:
        print(USAGE, file=sys.stderr)
        return 2
    pre = []
    min_minutes = None
    if "--min-minutes" in opts:
        v = opts["--min-minutes"]
        if is_count(v) and int(v) > 0:
            min_minutes = int(v)
        else:
            pre.append(f"MALFORMED --min-minutes {v!r}")
    else:
        pre.append("NO-MINIMUM the caller gave no --min-minutes, so no plan can be judged long enough")
    if opts.get("--thresholds") == "":   # a trailing --thresholds names nothing; never fall back to the default
        print(f"--thresholds needs a file\n{USAGE}", file=sys.stderr)
        return 2
    thresholds = opts.get("--thresholds") or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                           "soak-thresholds.tsv")
    judge = Judge(positional[0], min_minutes, opts.get("--other-run"), thresholds)
    judge.failures.extend(pre)
    judge.process_rules()
    judge.metrics_stage()
    kc = collections.Counter(x.split(" ", 1)[0] for x in judge.failures)
    for x in judge.failures:
        print("FAIL " + x)
    for x in judge.info:
        print(x)
    planned = judge.planned if judge.planned is not None else "?"
    print(f"{len(judge.minutes)} minutes sampled of {planned} planned (at least "
          f"{min_minutes if min_minutes is not None else '?'} required); mode {judge.mode or '?'}; "
          f"class {judge.klass or '?'}; RESULT {'FAIL' if judge.failures else 'PASS'} ({len(judge.failures)} failures)"
          + ("" if not kc else " " + " ".join(f"{k}={v}" for k, v in sorted(kc.items()))))
    return 1 if judge.failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
