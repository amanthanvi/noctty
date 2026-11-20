r"""Tests of ci/soak_judge.py: python -I ci/test_soak_judge.py

The first group is the plan's prototype controls (PLAN.md §15.7: 94 to 100, 107 to 115, 120, 121, 124, 140 to
142 and 164, from zig017\tools\controls.py), each with the failures by kind and the exit code the prototype
gave. Their run directories now also hold the metrics and thread rows the judge reads, flat and complete, so
each control still fails only by the rule it names. The second group covers the metrics stage: the slope
check, the warm-up, the thread bounds and the records it needs. Every case runs the judge as its own process
(`-I`, as CI runs it) on a run directory written into a temporary directory, which is removed afterwards.
"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
JUDGE = os.path.join(HERE, "soak_judge.py")
DEFAULT_THRESHOLDS = os.path.join(HERE, "soak-thresholds.tsv")

# The FILETIME is built at run time: main's lint (ci/test_lints.py, fixture_commit_pins) reads any 7-40 character
# all-hex string literal in a ci/test_*.py as a commit pin that must be on main, and 18 decimal digits are hex.
PID, START = "720", str(134070000000000720)
SOAK_CLASS = "noctty-interactive-zig017-0123456789ab-soak-fast"
OTHER_CLASS = "noctty-interactive-zig017-0123456789ab-soak-safe"
METRICS_HEADER = ("minute\thandles\tthreads\tprivate_bytes\tworking_set\tcommit_charge\tgdi_objects\tuser_objects"
                  "\tchildren\tsurfaces\tchurn\tmissed")
THREADS = (("noctty.exe+0x1000", ""), ("noctty.exe+0x2000", "renderer"), ("noctty.exe+0x3000", "io"),
           ("noctty.exe+0x4000", "io-reader"))
FLAT = {"handles": 400, "threads": len(THREADS), "private_bytes": 50 << 20, "working_set": 80 << 20,
        "commit_charge": 60 << 20, "gdi_objects": 30, "user_objects": 20, "children": 2, "surfaces": 1,
        "churn": 3, "missed": 0}
FLOORS = """floor\thandles\t2
floor\tthreads\t0.5
floor\tprivate_bytes\t4194304
floor\tworking_set\t4194304
floor\tcommit_charge\t4194304
floor\tgdi_objects\t2
floor\tuser_objects\t2
floor\tchildren\t0.5
bound\tthreads\t8
kind\trenderer\t1
"""
# The metrics stage's tests: their own thresholds, so a retuned ci/soak-thresholds.tsv cannot move them.
TEST_THRESHOLDS = "warmup\t30\nwindow\t10\n" + FLOORS
# The prototype's controls had no slope: their 8-minute fixtures are judged with no warm-up and a 3-minute
# window, so the flat metrics pass and each control still fails only by the rule it names.
PROTO_THRESHOLDS = "warmup\t0\nwindow\t3\n" + FLOORS
MiB = 1 << 20


def ok_samples(n):
    return [(m, PID, START, "yes") for m in range(1, n + 1)]


SOAK_OK = ok_samples(8)
SOAK_GONE = [(m, "-", "-", "-") for m in range(6, 9)]


def soak_rows(end, wer="suppressed", planned=8, mode="portable", klass=SOAK_CLASS):
    """The run.tsv rows the judge requires, each once (the prototype's soak_rows)."""
    return [("launch", PID, START), ("mode", mode), ("class", klass), ("exe", "C:/soak/fast/noctty.exe"),
            ("planned", planned), ("wer", wer), ("end", end[0], end[1])]


def flat_metrics(samples, override=None):
    """One metrics row per sample: FLAT on a live one (with `override(minute)`'s changes), `-` on a gone one."""
    rows = []
    for m, pid, _, _ in samples:
        if pid == "-":
            rows.append((m,) + ("-",) * 11)
            continue
        values = dict(FLAT)
        values.update((override or (lambda _m: {}))(m))
        rows.append((m,) + tuple(values[k] for k in METRICS_HEADER.split("\t")[1:]))
    return rows


def thread_rows(metrics, extra=None):
    """THREADS on every live minute, plus `extra(minute)`'s (start, name) rows."""
    rows = []
    for row in metrics:
        if row[1] == "-":
            continue
        for i, (start, name) in enumerate(THREADS + tuple((extra or (lambda _m: ()))(row[0]))):
            rows.append((row[0], 100 + i, start, name))
    return rows


def flat_timing(samples, late=None, took=3):
    """One timing row per sample: its probe started 10 ms after its due time, or `late(minute)` ms when given,
    and ended `took` ms after it started."""
    rows = []
    for m, _, _, _ in samples:
        start = m * 60000 + (late or (lambda _m: 10))(m)
        rows.append((m, start, start + took, 0 if m == 1 else 8000))
    return rows


def write_run(d, rows, samples, crash_dir=True, crash_files=(), metrics="flat", threads="flat", timing="flat"):
    """A recorded soak run directory: run.tsv, samples.tsv, crash\\, metrics.tsv, threads.tsv and timing.tsv.
    `metrics`, `threads` and `timing` are row lists, "flat" for the complete flat ones, or None to leave the
    file out."""
    os.makedirs(d)
    if crash_dir:
        os.makedirs(os.path.join(d, "crash"))
    for name in crash_files:
        with open(os.path.join(d, "crash", name), "wb") as fh:
            fh.write(b"MDMP")

    def put(name, header, lines):
        with open(os.path.join(d, name), "w", encoding="utf-8", newline="\n") as fh:
            if header:
                fh.write(header + "\n")
            fh.write("".join("\t".join(map(str, r)) + "\n" for r in lines))

    put("run.tsv", None, rows)
    put("samples.tsv", None, samples)
    if metrics == "flat":
        metrics = flat_metrics(samples)
    if metrics is not None:
        put("metrics.tsv", METRICS_HEADER, metrics)
    if threads == "flat":
        threads = thread_rows(metrics or flat_metrics(samples))
    if threads is not None:
        put("threads.tsv", "minute\ttid\tstart\tname", threads)
    if timing == "flat":
        timing = flat_timing(samples)
    if timing is not None:
        put("timing.tsv", "minute\tprobe_start_ms\tprobe_end_ms\tworkload_ms", timing)


class JudgeCase(unittest.TestCase):
    THRESHOLDS = PROTO_THRESHOLDS

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="soak-judge-")
        self.addCleanup(self.tmp.cleanup)
        self.thresholds = os.path.join(self.tmp.name, "thresholds.tsv")
        with open(self.thresholds, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(self.THRESHOLDS)
        self.n = 0

    def run_dir(self, *args, **kwargs):
        self.n += 1
        d = os.path.join(self.tmp.name, f"run{self.n}")
        write_run(d, *args, **kwargs)
        return d

    def judge(self, d, min_minutes=8, other_class=None, thresholds=None, extra=()):
        argv = [sys.executable, "-I", JUDGE, d]
        if min_minutes is not None:
            argv += ["--min-minutes", str(min_minutes)]
        if other_class is not None:
            od = self.run_dir([r if r[0] != "class" else ("class", other_class) for r in soak_rows(("quit", 0))],
                              SOAK_OK)
            argv += ["--other-run", od]
        argv += ["--thresholds", thresholds or self.thresholds] + list(extra)
        r = subprocess.run(argv, capture_output=True, encoding="utf-8")
        kinds = {}
        for line in r.stdout.splitlines():
            if line.startswith("FAIL "):
                k = line.split(" ", 2)[1]
                kinds[k] = kinds.get(k, 0) + 1
        return r.returncode, kinds, r.stdout

    def expect(self, d, kinds, **kwargs):
        rc, got, out = self.judge(d, **kwargs)
        self.assertEqual((rc, got), (1 if kinds else 0, kinds), out)
        return out


class PrototypeControls(JudgeCase):
    """§15.7's soak controls, numbered as the plan numbers them."""

    def test_094_a_clean_soak(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK), {})

    def test_095_killed_with_exit_3_at_minute_5(self):
        self.expect(self.run_dir(soak_rows(("early", 3)), SOAK_OK[:5] + SOAK_GONE),
                    {"PROCESS-GONE": 3, "EARLY-EXIT": 1, "EXIT-CODE": 1})

    def test_096_restarted_under_a_new_pid(self):
        samples = SOAK_OK[:5] + [(6, "721", str(134070000000000721), "yes")] + SOAK_OK[6:]
        self.expect(self.run_dir(soak_rows(("quit", 0)), samples), {"PROCESS-CHANGED": 1})

    def test_097_a_hung_window(self):
        samples = SOAK_OK[:3] + [(4, PID, START, "no")] + SOAK_OK[4:]
        self.expect(self.run_dir(soak_rows(("quit", 0)), samples), {"HUNG": 1})

    def test_098_a_minidump_left(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, crash_files=("noctty-720.dmp",)),
                    {"CRASH-REPORT": 1})

    def test_099_wer_not_suppressed(self):
        self.expect(self.run_dir(soak_rows(("quit", 0), wer="default"), SOAK_OK), {"WER-NOT-SUPPRESSED": 1})

    def test_100_still_running_after_the_quit_bound(self):
        self.expect(self.run_dir(soak_rows(("stuck", "-")), SOAK_OK), {"QUIT-TIMEOUT": 1})

    def test_107_a_5_of_480_minute_soak_that_quit_cleanly(self):
        self.expect(self.run_dir(soak_rows(("quit", 0), planned=480), SOAK_OK[:5]), {"SHORT-RUN": 1})

    def test_108_a_minute_missing(self):
        # Minute 4 is missing from every record the harness writes, the metrics and threads included.
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK[:3] + SOAK_OK[4:]), {"MISSING-MINUTE": 1})

    def test_109_a_minute_recorded_twice(self):
        samples = SOAK_OK[:4] + SOAK_OK[3:]
        self.expect(self.run_dir(soak_rows(("quit", 0)), samples, metrics=flat_metrics(SOAK_OK),
                                 timing=flat_timing(SOAK_OK)),
                    {"DUPLICATE-MINUTE": 1})

    def test_110_an_early_end_then_a_clean_one(self):
        rows = soak_rows(("quit", 0))[:-1] + [("end", "early", 3), ("end", "quit", 0)]
        self.expect(self.run_dir(rows, SOAK_OK), {"DUPLICATE-ROW": 1})

    def test_111_two_wer_rows(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)) + [("wer", "default")], SOAK_OK), {"DUPLICATE-ROW": 1})

    def test_112_no_crash_directory(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, crash_dir=False), {"NO-CRASH-DIR": 1})

    def test_113_a_launch_start_time_of_dash(self):
        self.expect(self.run_dir([("launch", PID, "-")] + soak_rows(("quit", 0))[1:], SOAK_OK), {"MALFORMED": 1})

    def test_114_a_sample_with_a_pid_and_no_start_time(self):
        # The malformed sample is the only record of minute 4: no metrics or thread rows are taken for it.
        samples = SOAK_OK[:3] + [(4, PID, "-", "yes")] + SOAK_OK[4:]
        metrics = [r for r in flat_metrics(SOAK_OK) if r[0] != 4]
        self.expect(self.run_dir(soak_rows(("quit", 0)), samples, metrics=metrics, threads=thread_rows(metrics)),
                    {"MALFORMED": 1})

    def test_115_no_mode_row(self):
        rows = [r for r in soak_rows(("quit", 0)) if r[0] != "mode"]
        self.expect(self.run_dir(rows, SOAK_OK), {"MISSING-ROW": 1})

    def test_120_a_plan_below_the_required_minimum(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK), {"PLAN-TOO-SHORT": 1}, min_minutes=480,
                    other_class=OTHER_CLASS)

    def test_121_no_class_row(self):
        rows = [r for r in soak_rows(("quit", 0)) if r[0] != "class"]
        self.expect(self.run_dir(rows, SOAK_OK), {"MISSING-ROW": 1})

    def test_124_the_judge_called_without_a_minimum(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK), {"NO-MINIMUM": 1}, min_minutes=None)

    def test_140_a_class_not_shaped_as_the_launch_helper_makes_it(self):
        rows = soak_rows(("quit", 0), klass="noctty-interactive-soak")
        self.expect(self.run_dir(rows, SOAK_OK), {"BAD-CLASS": 1})

    def test_141_two_copies_with_one_class(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK), {"SHARED-CLASS": 1}, other_class=SOAK_CLASS)

    def test_142_two_copies_with_two_classes(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK), {}, other_class=OTHER_CLASS)

    def test_164_a_release_coverage_soak_without_the_other_copy(self):
        self.expect(self.run_dir(soak_rows(("quit", 0), planned=480), ok_samples(480)), {"NO-OTHER-RUN": 1},
                    min_minutes=480)

    def test_164_with_the_other_copy_passes(self):
        out = self.expect(self.run_dir(soak_rows(("quit", 0), planned=480), ok_samples(480)), {}, min_minutes=480,
                          other_class=OTHER_CLASS)
        self.assertIn("SLOPE-INFO handles slope=+0.0000/h", out)


class MetricsStage(JudgeCase):
    """The slope check and the records it reads (PLAN.md §3.5: thresholds fixed in 0a, a warm-up)."""
    THRESHOLDS = TEST_THRESHOLDS

    def hour(self, override=None, extra_threads=None, samples=None, end=("quit", 0), **kwargs):
        samples = samples or ok_samples(60)
        metrics = flat_metrics(samples, override)
        return self.run_dir(soak_rows(end, planned=60), samples, metrics=metrics,
                            threads=thread_rows(metrics, extra_threads), **kwargs)

    def test_a_clean_hour_passes(self):
        out = self.expect(self.hour(), {}, min_minutes=60)
        self.assertIn("n=30", out)
        self.assertIn("minutes 31-60", out)

    def eight_hours(self, override=None):
        """Release coverage's soak: 480 minutes, judged with the repository's own thresholds."""
        samples = ok_samples(480)
        metrics = flat_metrics(samples, override)
        return self.run_dir(soak_rows(("quit", 0), planned=480), samples, metrics=metrics,
                            threads=thread_rows(metrics))

    def release(self, d, kinds):
        return self.expect(d, kinds, min_minutes=480, other_class=OTHER_CLASS, thresholds=DEFAULT_THRESHOLDS)

    def test_the_repository_thresholds_pass_eight_noisy_flat_hours(self):
        noise = lambda m: {"handles": 400 + (7 if m % 2 else -7), "private_bytes": (50 << 20) + (m % 5) * MiB,
                           "commit_charge": (60 << 20) + (m % 5) * MiB, "user_objects": 20 + m % 3}
        self.release(self.eight_hours(noise), {})

    def test_the_repository_thresholds_fail_a_steady_memory_rise(self):
        # Round 1's Sol High: 1 MiB a minute (60 MiB/h, about 480 MiB in 8 hours) passed the 64 MiB/h thresholds.
        rise = lambda m: {"private_bytes": (50 << 20) + m * MiB, "commit_charge": (60 << 20) + m * MiB}
        out = self.release(self.eight_hours(rise), {"SLOPE": 2})
        self.assertIn("FAIL SLOPE private_bytes", out)

    def test_the_repository_thresholds_fail_a_slow_handle_leak_over_eight_hours(self):
        # Round 1's Opus L1: 15 handles an hour (about 110 after the warm-up) passed a fixed 16/h threshold.
        leak = lambda m: {"handles": 400 + (7 if m % 2 else -7) + m // 4}
        out = self.release(self.eight_hours(leak), {"SLOPE": 1})
        self.assertIn("FAIL SLOPE handles", out)

    def test_the_repository_thresholds_fail_two_leaked_panes_an_hour(self):
        # Round 1's Opus L1: 5 leaked child processes an hour passed a 6/h threshold.
        self.release(self.eight_hours(lambda m: {"children": 2 + m // 30}), {"SLOPE": 1})

    def test_the_negative_control_one_handle_a_minute_fails_on_handles(self):
        out = self.expect(self.hour(lambda m: {"handles": 400 + m}), {"SLOPE": 1}, min_minutes=60)
        self.assertIn("FAIL SLOPE handles rises +60.00/h", out)

    def test_growth_inside_the_warm_up_passes(self):
        self.expect(self.hour(lambda m: {"handles": 400 + 5 * min(m, 30), "private_bytes": (40 + min(m, 30)) << 20}),
                    {}, min_minutes=60)

    def test_a_falling_metric_passes(self):
        self.expect(self.hour(lambda m: {"working_set": (120 << 20) - m * (1 << 20)}), {}, min_minutes=60)

    def test_noise_without_a_trend_passes(self):
        self.expect(self.hour(lambda m: {"handles": 400 + (7 if m % 2 else -7), "threads": len(THREADS)}), {},
                    min_minutes=60)

    def test_a_memory_leak_fails_on_its_metrics(self):
        out = self.expect(self.hour(lambda m: {"private_bytes": (50 << 20) + m * (1 << 20),
                                               "commit_charge": (60 << 20) + m * (1 << 20)}),
                          {"SLOPE": 2}, min_minutes=60)
        self.assertIn("FAIL SLOPE private_bytes", out)
        self.assertIn("FAIL SLOPE commit_charge", out)

    def test_a_process_leak_fails_on_children(self):
        self.expect(self.hour(lambda m: {"children": 2 + m // 10}), {"SLOPE": 1}, min_minutes=60)

    def test_a_thread_over_the_bound_fails(self):
        extra = lambda m: (("ntdll.dll+0x5000", ""),) * 6 if m == 45 else ()
        self.expect(self.hour(lambda m: {"threads": len(THREADS) + (6 if m == 45 else 0)}, extra),
                    {"THREAD-BOUND": 1}, min_minutes=60)

    def test_a_second_renderer_thread_fails_its_kind_bound(self):
        extra = lambda m: (("noctty.exe+0x2000", "renderer"),) if m == 50 else ()
        out = self.expect(self.hour(lambda m: {"threads": len(THREADS) + (1 if m == 50 else 0)}, extra),
                          {"KIND-BOUND": 1}, min_minutes=60)
        self.assertIn("'renderer' at minute 50", out)

    def test_a_kind_is_its_start_address_when_unnamed(self):
        out = self.expect(self.hour(), {}, min_minutes=60)
        self.assertIn("KIND-INFO 'noctty.exe+0x1000' min=1 max=1", out)

    def test_the_kill_control_of_an_hour(self):
        samples = ok_samples(5) + [(m, "-", "-", "-") for m in range(6, 61)]
        self.expect(self.hour(samples=samples, end=("early", 3)),
                    {"PROCESS-GONE": 55, "EARLY-EXIT": 1, "EXIT-CODE": 1, "NO-SLOPE-SAMPLES": 1}, min_minutes=60)

    def test_a_minimum_without_a_slope_window_is_refused(self):
        # Round 1's Opus L3: a --min-minutes within the warm-up used to skip the slope silently and pass.
        samples = ok_samples(39)
        metrics = flat_metrics(samples, lambda m: {"handles": 400 + m})
        d = self.run_dir(soak_rows(("quit", 0), planned=39), samples, metrics=metrics)
        self.expect(d, {"MINIMUM-TOO-SHORT": 1}, min_minutes=39)

    def test_the_shortest_minimum_with_a_window_is_judged(self):
        samples = ok_samples(40)
        metrics = flat_metrics(samples, lambda m: {"handles": 400 + m})
        d = self.run_dir(soak_rows(("quit", 0), planned=40), samples, metrics=metrics)
        self.expect(d, {"SLOPE": 1}, min_minutes=40)

    def test_a_sample_away_from_the_baseline(self):
        self.expect(self.hour(lambda m: {"surfaces": 2} if m == 40 else {}), {"NOT-AT-BASELINE": 1}, min_minutes=60)

    def test_a_workload_action_that_did_not_take_effect(self):
        self.expect(self.hour(lambda m: {"missed": 1} if m == 12 else {}), {"WORKLOAD-MISSED": 1}, min_minutes=60)

    def test_no_workload(self):
        self.expect(self.hour(lambda m: {"churn": 0}), {"NO-WORKLOAD": 1}, min_minutes=60)

    def test_idle_minutes_are_allowed(self):
        self.expect(self.hour(lambda m: {"churn": 0} if m % 10 == 0 else {}), {}, min_minutes=60)

    def test_thread_rows_that_disagree_with_the_count(self):
        metrics = flat_metrics(ok_samples(60))
        threads = [r for r in thread_rows(metrics) if not (r[0] == 33 and r[3] == "io")]
        self.expect(self.run_dir(soak_rows(("quit", 0), planned=60), ok_samples(60), metrics=metrics,
                                 threads=threads),
                    {"MALFORMED": 1}, min_minutes=60)

    def test_thresholds_without_a_metric_fail_closed(self):
        bad = os.path.join(self.tmp.name, "bad-thresholds.tsv")
        with open(bad, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("".join(line + "\n" for line in TEST_THRESHOLDS.splitlines() if "children" not in line))
        self.expect(self.hour(), {"BAD-THRESHOLDS": 1}, min_minutes=60, thresholds=bad)

    def test_thresholds_with_an_unknown_row_fail_closed(self):
        bad = os.path.join(self.tmp.name, "bad-thresholds.tsv")
        with open(bad, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(TEST_THRESHOLDS + "floor\thandles\t99\n")
        self.expect(self.hour(), {"BAD-THRESHOLDS": 1}, min_minutes=60, thresholds=bad)

    def test_a_missing_thresholds_file_fails_closed(self):
        self.expect(self.hour(), {"BAD-THRESHOLDS": 1}, min_minutes=60,
                    thresholds=os.path.join(self.tmp.name, "absent.tsv"))


class Records(JudgeCase):
    """The records the metrics stage reads, complete and once each (8-minute fixtures, no warm-up)."""

    def test_a_late_sample_fails(self):
        # Round 1's Opus H1: a hung copy blocked the driver, and the sample taken after the hang read "yes".
        # The driver then reached minute 4's probe, due 60 s after minute 3's, only once minute 3's had ended.
        late = {3: 66858, 4: 6870}
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK, timing=flat_timing(SOAK_OK, lambda m: late.get(m, 10)))
        out = self.expect(d, {"LATE-SAMPLE": 2})
        self.assertIn("LATE-SAMPLE minute 3's probe started 66858 ms after its due time", out)

    def test_a_sample_at_the_bound_passes(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, timing=flat_timing(SOAK_OK, lambda m: 5000)), {})

    def test_a_probe_that_ends_before_it_starts_is_malformed(self):
        timing = [(3, 180010, 180000, 8000) if r[0] == 3 else r for r in flat_timing(SOAK_OK)]
        out = self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, timing=timing), {"MALFORMED": 1})
        self.assertIn("its probe ends at 180000 ms, before it starts at 180010 ms", out)

    def test_timing_rows_out_of_order_are_malformed(self):
        timing = flat_timing(SOAK_OK)
        timing[2], timing[3] = timing[3], timing[2]
        out = self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, timing=timing), {"MALFORMED": 1})
        self.assertIn("minutes and times must increase", out)

    def test_no_timing_file(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, timing=None), {"NO-TIMING": 1})

    def test_a_timing_row_missing(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, timing=[r for r in flat_timing(SOAK_OK) if r[0] != 6]),
                    {"MISSING-TIMING": 1})

    def test_a_timing_row_twice(self):
        timing = flat_timing(SOAK_OK)
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, timing=timing + timing[1:2]),
                    {"DUPLICATE-TIMING": 1})

    def test_an_end_code_with_two_minus_signs_is_malformed(self):
        # Round 1's Opus L9: `--3` passed the prototype's lstrip check and then crashed int().
        d = self.run_dir(soak_rows(("early", "--3")), SOAK_OK)
        rc, kinds, out = self.judge(d)
        self.assertEqual((rc, kinds), (1, {"MALFORMED": 1}), out)
        self.assertNotIn("Traceback", out)

    def test_no_metrics_file(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, metrics=None,
                                 threads=thread_rows(flat_metrics(SOAK_OK))),
                    {"NO-METRICS": 1})

    def test_no_threads_file(self):
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, threads=None), {"NO-THREADS": 1})

    def test_a_metric_row_missing(self):
        metrics = [r for r in flat_metrics(SOAK_OK) if r[0] != 5]
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, metrics=metrics, threads=thread_rows(metrics)),
                    {"MISSING-METRIC": 1})

    def test_a_metric_row_twice(self):
        metrics = flat_metrics(SOAK_OK)
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, metrics=metrics + metrics[2:3],
                                 threads=thread_rows(metrics)),
                    {"DUPLICATE-METRIC": 1})

    def test_a_live_minute_without_values(self):
        metrics = flat_metrics(SOAK_OK)
        metrics[3] = (4,) + ("-",) * 11
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, metrics=metrics,
                                 threads=thread_rows(flat_metrics(SOAK_OK))),
                    {"MALFORMED": 1})

    def test_a_metrics_file_without_its_header(self):
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK)
        path = os.path.join(d, "metrics.tsv")
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n", 1)[1]
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(lines)
        rc, kinds, out = self.judge(d)
        self.assertEqual(rc, 1, out)
        self.assertGreaterEqual(kinds.get("MALFORMED", 0), 1, out)
        self.assertEqual(kinds.get("MISSING-METRIC"), 8, out)


class ReviewRound2(JudgeCase):
    """Round 2's review, judged with the repository's thresholds: the probe's own times (Sol's High), Phase 0a's
    120 minutes (the lead's measured amendment of PLAN.md §3.5), and timing bounded both ways (Sol and Opus)."""

    def phase0a(self, timing=None, minutes=120):
        samples = ok_samples(minutes)
        metrics = flat_metrics(samples)
        return self.run_dir(soak_rows(("quit", 0), planned=minutes), samples, metrics=metrics,
                            threads=thread_rows(metrics), timing=timing or flat_timing(samples))

    def judge0a(self, d, kinds, minimum=120):
        return self.expect(d, kinds, min_minutes=minimum, thresholds=DEFAULT_THRESHOLDS)

    def test_a_clean_phase_0a_run_of_120_minutes_passes(self):
        self.judge0a(self.phase0a(), {})

    def test_the_repository_thresholds_refuse_a_minimum_below_120(self):
        self.judge0a(self.phase0a(), {"MINIMUM-TOO-SHORT": 1}, minimum=119)

    def test_sols_measured_delay_before_the_probe_fails(self):
        # Sol's review-only delay, measured: 15 s of sleep after the old timestamp. The record said minute 3 was
        # sampled at 180,004 ms (4 ms late); the probe ran at 195,021 ms, after the hang had ended. Recorded
        # where it runs, the probe starts 15,021 ms late.
        timing = [(3, 195021, 195024, 3) if r[0] == 3 else r for r in flat_timing(ok_samples(120))]
        out = self.judge0a(self.phase0a(timing=timing), {"LATE-SAMPLE": 1})
        self.assertIn("LATE-SAMPLE minute 3's probe started 15021 ms after its due time", out)

    def test_the_same_delay_inside_the_probe_fails_by_its_end(self):
        timing = [(3, 180004, 195021, 3) if r[0] == 3 else r for r in flat_timing(ok_samples(120))]
        out = self.judge0a(self.phase0a(timing=timing), {"LATE-SAMPLE": 1})
        self.assertIn("LATE-SAMPLE minute 3's probe ended 15021 ms after its due time, beyond 10000 ms", out)

    def test_a_probe_at_both_bounds_passes(self):
        # A probe that starts 5 s late and then waits out the full 5 s response bound on a hung window.
        self.judge0a(self.phase0a(timing=flat_timing(ok_samples(120), lambda m: 5000, took=5000)), {})

    def test_a_probe_a_millisecond_past_its_end_bound_fails(self):
        self.judge0a(self.phase0a(timing=flat_timing(ok_samples(120), lambda m: 5000 if m == 7 else 10,
                                                   took=5001)), {"LATE-SAMPLE": 1})

    def test_a_30_second_sampler_fails_as_early(self):
        # Opus's L4, measured: minute m sampled at m x 30 s (an 8-hour record taken in 4) passed.
        timing = [(m, m * 30000, m * 30000 + 3, w) for m, _, _, w in flat_timing(ok_samples(120))]
        out = self.judge0a(self.phase0a(timing=timing), {"EARLY-SAMPLE": 120})
        self.assertIn("EARLY-SAMPLE minute 2's probe started 60000 ms before its due time", out)

    def test_one_timestamp_for_every_minute_fails(self):
        # Sol's Low, measured: sampled_ms 60000 on every row, with late_ms to match, passed a 90-minute record.
        timing = [(m, 60000, 60003, w) for m, _, _, w in flat_timing(ok_samples(120))]
        self.judge0a(self.phase0a(timing=timing), {"MALFORMED": 119, "EARLY-SAMPLE": 119})


class ReviewRound3(JudgeCase):
    """Round 3's review: an exit no quit request of the harness reached (Sol's Medium, measured with a test double:
    no window to post to, or a post that failed, then the handle signalled with 0) is a failure, judged on a complete
    120-minute record with the repository's thresholds."""

    def phase0a(self, end):
        samples = ok_samples(120)
        metrics = flat_metrics(samples)
        return self.run_dir(soak_rows(end, planned=120), samples, metrics=metrics, threads=thread_rows(metrics),
                            timing=flat_timing(samples))

    def judge0a(self, d, kinds):
        return self.expect(d, kinds, min_minutes=120, thresholds=DEFAULT_THRESHOLDS)

    def test_a_quit_the_harness_asked_for_passes(self):
        self.judge0a(self.phase0a(("quit", 0)), {})

    def test_an_exit_no_quit_request_reached_fails(self):
        out = self.judge0a(self.phase0a(("unasked", 0)), {"UNASKED-EXIT": 1})
        self.assertIn("UNASKED-EXIT the process ended with no WM_CLOSE of the harness reaching one of its windows", out)

    def test_an_unasked_exit_with_a_code_fails_on_both(self):
        self.judge0a(self.phase0a(("unasked", 1)), {"UNASKED-EXIT": 1, "EXIT-CODE": 1})

    def test_an_unasked_end_without_a_code_is_malformed(self):
        self.judge0a(self.phase0a(("unasked", "-")), {"MALFORMED": 1})


class LineEnds(JudgeCase):
    THRESHOLDS = TEST_THRESHOLDS
    def test_records_and_thresholds_with_crlf_line_ends_pass(self):
        # A core.autocrlf checkout gives the thresholds CRLF ends; a record written on Windows may have them too.
        d = self.run_dir(soak_rows(("quit", 0), planned=60), ok_samples(60))
        for name in ("run.tsv", "samples.tsv", "metrics.tsv", "threads.tsv"):
            path = os.path.join(d, name)
            with open(path, encoding="utf-8", newline="") as fh:
                text = fh.read()
            with open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(text.replace("\n", "\r\n"))
        crlf = os.path.join(self.tmp.name, "crlf-thresholds.tsv")
        with open(crlf, "w", encoding="utf-8", newline="") as fh:
            fh.write(TEST_THRESHOLDS.replace("\n", "\r\n"))
        self.expect(d, {}, min_minutes=60, thresholds=crlf)

    def test_a_record_that_is_not_utf8_is_malformed(self):
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK)
        with open(os.path.join(d, "samples.tsv"), "ab") as fh:
            fh.write(b"9\t720\t\xff\tyes\n")
        rc, kinds, out = self.judge(d)
        self.assertEqual((rc, kinds.get("MALFORMED")), (1, 1), out)


class RealNoise(JudgeCase):
    """Synthetic leaks on real runs' metrics (round 1's Opus controls), judged with the repository's thresholds.
    The fixtures are metrics.tsv as two clean soaks recorded it (ci/soak-fixtures/, numbers only): a 4-hour
    ReleaseFast copy and a 1-hour ReleaseSafe copy, both of the PR's harness on 2026-11-18. The other records
    are rebuilt to match them, so only the metrics carry the run's own noise."""

    def real_run(self, fixture, add_mib_per_hour=0.0, warmup_window=None):
        with open(os.path.join(HERE, "soak-fixtures", fixture), encoding="utf-8") as fh:
            lines = [line for line in fh.read().splitlines() if line.strip()]
        header = lines[0].split("\t")
        metrics = []
        for line in lines[1:]:
            values = dict(zip(header, line.split("\t")))
            m = int(values["minute"])
            add = int(round(add_mib_per_hour * MiB * m / 60))
            for key in ("private_bytes", "commit_charge"):   # a heap leak moves both
                values[key] = str(int(values[key]) + add)
            metrics.append(tuple(values[k] for k in header))
        samples = ok_samples(len(metrics))
        threads = []
        for row in metrics:
            named = (("noctty.exe+0x2000", "renderer"), ("noctty.exe+0x3000", "io"), ("noctty.exe+0x4000", "io-reader"))
            rest = (("ntdll.dll+0x24990", ""),) * (int(row[2]) - len(named))
            threads += [(row[0], 100 + i, start, name) for i, (start, name) in enumerate(named + rest)]
        d = self.run_dir(soak_rows(("quit", 0), planned=len(metrics)), samples, metrics=metrics, threads=threads)
        thresholds = DEFAULT_THRESHOLDS
        if warmup_window is not None:   # the repository's floors and bounds with another warm-up and window
            with open(DEFAULT_THRESHOLDS, encoding="utf-8") as fh:
                kept = [line for line in fh.read().splitlines() if not line.startswith(("warmup\t", "window\t"))]
            thresholds = os.path.join(self.tmp.name, "real-thresholds.tsv")
            with open(thresholds, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(f"warmup\t{warmup_window[0]}\nwindow\t{warmup_window[1]}\n" + "\n".join(kept) + "\n")
        return d, thresholds, len(metrics)

    def test_the_clean_four_hours_pass(self):
        d, thresholds, n = self.real_run("long4h-releasefast.metrics.tsv")
        self.expect(d, {}, min_minutes=n, thresholds=thresholds)

    def test_the_clean_four_hours_with_20_mib_an_hour_fail(self):
        d, thresholds, n = self.real_run("long4h-releasefast.metrics.tsv", 20)
        out = self.expect(d, {"SLOPE": 2}, min_minutes=n, thresholds=thresholds)
        self.assertIn("FAIL SLOPE private_bytes", out)
        self.assertIn("FAIL SLOPE commit_charge", out)

    def test_the_releasesafe_hour_passes_after_a_30_minute_warm_up(self):
        d, thresholds, n = self.real_run("r3-releasesafe.metrics.tsv", 0, (30, 30))
        self.expect(d, {}, min_minutes=n, thresholds=thresholds)

    def test_the_releasesafe_hour_with_50_mib_an_hour_fails(self):
        d, thresholds, n = self.real_run("r3-releasesafe.metrics.tsv", 50, (30, 30))
        self.expect(d, {"SLOPE": 2}, min_minutes=n, thresholds=thresholds)


class ReviewRound1(JudgeCase):
    """PR #727 round 1's review threads on the judge, one test each."""

    def test_a_class_with_a_hash_and_no_worktree_slug_is_bad(self):
        rows = soak_rows(("quit", 0), klass="noctty-interactive-0123456789ab-soak-fast")
        self.expect(self.run_dir(rows, SOAK_OK), {"BAD-CLASS": 1})

    def test_a_peer_with_two_class_rows_is_malformed(self):
        peer = os.path.join(self.tmp.name, "peer")
        write_run(peer, soak_rows(("quit", 0), klass=OTHER_CLASS) + [("class", OTHER_CLASS, "extra")], SOAK_OK)
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK)
        self.expect(d, {"MALFORMED": 1}, extra=("--other-run", peer))

    def test_a_peer_class_not_of_the_helper_shape_is_malformed(self):
        peer = os.path.join(self.tmp.name, "peer")
        write_run(peer, soak_rows(("quit", 0), klass="noctty-interactive-soak"), SOAK_OK)
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK)
        self.expect(d, {"MALFORMED": 1}, extra=("--other-run", peer))

    def test_a_number_with_thousands_of_digits_is_malformed(self):
        d = self.run_dir(soak_rows(("quit", 0), planned="9" * 4301), SOAK_OK)
        rc, kinds, out = self.judge(d)
        self.assertEqual((rc, kinds.get("MALFORMED")), (1, 1), out)

    def test_a_corrupt_minute_number_is_one_gap(self):
        samples = SOAK_OK + [(999999999999, PID, START, "yes")]
        d = self.run_dir(soak_rows(("quit", 0)), samples, metrics=flat_metrics(SOAK_OK), timing=flat_timing(SOAK_OK))
        rc, kinds, out = self.judge(d)
        self.assertEqual(kinds.get("MISSING-MINUTE"), 1, out)
        self.assertIn("MISSING-MINUTE minutes 9-999999999998", out)

    def test_a_thread_listed_twice_in_a_minute_is_malformed(self):
        metrics = flat_metrics(SOAK_OK)
        threads = thread_rows(metrics)
        threads = [r if not (r[0] == 3 and r[3] == "io") else (3, 101, r[2], r[3]) for r in threads]
        # The copied row, and the count it then leaves short of metrics.tsv's.
        self.expect(self.run_dir(soak_rows(("quit", 0)), SOAK_OK, metrics=metrics, threads=threads), {"MALFORMED": 2})

    def test_a_thread_name_that_is_not_utf8_is_malformed_and_left_out(self):
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK)
        path = os.path.join(d, "threads.tsv")
        with open(path, "rb") as fh:
            data = fh.read()
        with open(path, "wb") as fh:
            fh.write(data.replace(b"3\t102\tnoctty.exe+0x3000\tio\n", b"3\t102\tnoctty.exe+0x3000\tio\xff\n", 1))
        rc, kinds, out = self.judge(d)
        self.assertEqual((rc, kinds), (1, {"MALFORMED": 2}), out)   # the line, and the count it then leaves short

    def test_a_trailing_thresholds_option_is_a_usage_error(self):
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK)
        r = subprocess.run([sys.executable, "-I", JUDGE, d, "--min-minutes", "8", "--thresholds"],
                           capture_output=True, encoding="utf-8")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_the_default_thresholds_are_found_without_the_option(self):
        samples = ok_samples(480)
        metrics = flat_metrics(samples)
        d = self.run_dir(soak_rows(("quit", 0), planned=480), samples, metrics=metrics, threads=thread_rows(metrics))
        peer = self.run_dir(soak_rows(("quit", 0), klass=OTHER_CLASS), SOAK_OK)
        r = subprocess.run([sys.executable, "-I", JUDGE, d, "--min-minutes", "480", "--other-run", peer],
                           capture_output=True, encoding="utf-8")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("RESULT PASS", r.stdout)


class Usage(JudgeCase):
    def test_no_run_directory_is_a_usage_error(self):
        r = subprocess.run([sys.executable, "-I", JUDGE, "--min-minutes", "8"], capture_output=True, encoding="utf-8")
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_an_unknown_option_is_a_usage_error(self):
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK)
        rc, _, _ = self.judge(d, extra=("--max-minutes", "8"))
        self.assertEqual(rc, 2)

    def test_a_missing_run_file_fails_every_row(self):
        d = self.run_dir(soak_rows(("quit", 0)), SOAK_OK)
        os.remove(os.path.join(d, "run.tsv"))
        rc, kinds, out = self.judge(d)
        self.assertEqual((rc, kinds), (1, {"MISSING-ROW": 7}), out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
