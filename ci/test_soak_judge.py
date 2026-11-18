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

PID, START = "720", "134070000000000720"
SOAK_CLASS = "noctty-interactive-zig017-0123456789ab-soak-fast"
OTHER_CLASS = "noctty-interactive-zig017-0123456789ab-soak-safe"
METRICS_HEADER = ("minute\thandles\tthreads\tprivate_bytes\tworking_set\tcommit_charge\tgdi_objects\tuser_objects"
                  "\tchildren\tsurfaces\tchurn\tmissed")
THREADS = (("noctty.exe+0x1000", ""), ("noctty.exe+0x2000", "renderer"), ("noctty.exe+0x3000", "io"),
           ("noctty.exe+0x4000", "io-reader"))
FLAT = {"handles": 400, "threads": len(THREADS), "private_bytes": 50 << 20, "working_set": 80 << 20,
        "commit_charge": 60 << 20, "gdi_objects": 30, "user_objects": 20, "children": 2, "surfaces": 1,
        "churn": 3, "missed": 0}
TEST_THRESHOLDS = """# the tests' own thresholds, so a retuned ci/soak-thresholds.tsv cannot move them
slope\thandles\t12
slope\tthreads\t2
slope\tprivate_bytes\t8388608
slope\tworking_set\t16777216
slope\tcommit_charge\t8388608
slope\tgdi_objects\t6
slope\tuser_objects\t6
slope\tchildren\t1
bound\tthreads\t8
kind\trenderer\t1
"""


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


def write_run(d, rows, samples, crash_dir=True, crash_files=(), metrics="flat", threads="flat"):
    """A recorded soak run directory: run.tsv, samples.tsv, crash\\, metrics.tsv and threads.tsv. `metrics`
    and `threads` are row lists, "flat" for the complete flat ones, or None to leave the file out."""
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


class JudgeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="soak-judge-")
        self.addCleanup(self.tmp.cleanup)
        self.thresholds = os.path.join(self.tmp.name, "thresholds.tsv")
        with open(self.thresholds, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(TEST_THRESHOLDS)
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
        samples = SOAK_OK[:5] + [(6, "721", "134070000000000721", "yes")] + SOAK_OK[6:]
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
        self.expect(self.run_dir(soak_rows(("quit", 0)), samples, metrics=flat_metrics(SOAK_OK)),
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
    """The slope check and the records it reads (PLAN.md §3.5: thresholds fixed in 0a, 30-minute warm-up)."""

    def hour(self, override=None, extra_threads=None, samples=None, end=("quit", 0), **kwargs):
        samples = samples or ok_samples(60)
        metrics = flat_metrics(samples, override)
        return self.run_dir(soak_rows(end, planned=60), samples, metrics=metrics,
                            threads=thread_rows(metrics, extra_threads), **kwargs)

    def test_a_clean_hour_passes(self):
        out = self.expect(self.hour(), {}, min_minutes=60)
        self.assertIn("n=30", out)
        self.assertIn("minutes 31-60", out)

    def test_the_repository_thresholds_parse(self):
        self.expect(self.hour(), {}, min_minutes=60, thresholds=DEFAULT_THRESHOLDS)

    def test_the_negative_control_one_handle_a_minute_fails_on_handles(self):
        out = self.expect(self.hour(lambda m: {"handles": 400 + m}), {"SLOPE": 1}, min_minutes=60)
        self.assertIn("FAIL SLOPE handles +60.00/h", out)

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

    def test_a_plan_within_the_warm_up_has_no_slope(self):
        samples = ok_samples(30)
        metrics = flat_metrics(samples, lambda m: {"handles": 400 + m})
        d = self.run_dir(soak_rows(("quit", 0), planned=30), samples, metrics=metrics)
        out = self.expect(d, {}, min_minutes=30)
        self.assertIn("slope check: not applicable", out)

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
            fh.write(TEST_THRESHOLDS + "slope\thandles\t99\n")
        self.expect(self.hour(), {"BAD-THRESHOLDS": 1}, min_minutes=60, thresholds=bad)

    def test_a_missing_thresholds_file_fails_closed(self):
        self.expect(self.hour(), {"BAD-THRESHOLDS": 1}, min_minutes=60,
                    thresholds=os.path.join(self.tmp.name, "absent.tsv"))


class LineEnds(JudgeCase):
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
