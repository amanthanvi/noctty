r"""Controls for ci/thread_role_points.py, acceptance test 9's checker (python -I ci/test_thread_role_points.py).

Each control writes a small tree (src/main.zig, src/main_ghostty.zig, src/sync/thread_role.zig, a worker file) and a
registry into a fresh temporary directory, runs the checker on it (`-`, the working tree) and asserts its verdict and
the failure it names. The first control is the clean tree every other one breaks once.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "thread_role_points.py")

MAIN = 'const ghostty = @import("main_ghostty.zig");\ntest {\n    _ = @import("tests.zig");\n}\n'
GHOSTTY = '''const thread_role = @import("sync/thread_role.zig");
const worker = @import("worker.zig");
pub fn main() void {
    const role_scope = thread_role.enter(.ui);
    defer role_scope.exit();
    worker.start();
}
'''
ROLE = '''pub fn enter(role: anytype) void {
    _ = role;
}
'''
WORKER = '''const std = @import("std");
const thread_role = @import("sync/thread_role.zig");
pub fn start() void {
    const t = std.Thread.spawn(.{}, workerMain, .{}) catch return;
    t.join();
}
fn workerMain() void {
    const role = thread_role.enter(.{ .worker = "probe" });
    defer role.exit();
}
const ProbeFixture = struct {
    fn init() void {
        _ = thread_role.fixture(.ui);
    }
};
test "a worker test" {
    ProbeFixture.init();
    const scope = thread_role.fixture(.termio);
    defer scope.exit();
}
'''
TESTS = 'test {\n    _ = @import("posix_only.zig");\n}\n'
POSIX = '''const std = @import("std");
pub fn spawn() void {
    _ = std.Thread.spawn(.{}, threadMain, .{}) catch {};
}
fn threadMain() void {}
'''
REGISTRY = ("# file\tfunction\tapi\ttarget\trole\twhy\n"
            "src/worker.zig\tstart\tThread.spawn\tworkerMain\tworker:probe\tthe probe worker\n"
            "src/os/flatpak.zig\tspawn\tThread.spawn\tthreadMain\tworker:flatpak\tLinux only\n")


def tree(**over):
    files = {"src/main.zig": MAIN, "src/main_ghostty.zig": GHOSTTY, "src/sync/thread_role.zig": ROLE,
             "src/worker.zig": WORKER, "src/tests.zig": TESTS, "src/os/flatpak.zig": POSIX}
    files.update(over)
    return files


def run(files, registry=REGISTRY):
    with tempfile.TemporaryDirectory(prefix="trp-") as d:
        for rel, text in files.items():
            p = os.path.join(d, *rel.split("/"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
        reg = os.path.join(d, "entries.tsv")
        with open(reg, "w", encoding="utf-8", newline="\n") as f:
            f.write(registry)
        r = subprocess.run([sys.executable, "-I", TOOL, d, "-", reg, "--verbose"], capture_output=True)
        return r.returncode, r.stdout.decode("utf-8")


failures = []


def control(name, files, want_exit, *want, registry=REGISTRY, absent=()):
    code, out = run(files, registry)
    missing = [w for w in want if w not in out]
    present = [a for a in absent if a in out]
    if code != want_exit or missing or present:
        failures.append(f"{name}: exit {code} (want {want_exit}); missing {missing}; unexpected {present}\n{out}")
    else:
        print(f"ok  {name}")


control("a clean tree passes", tree(), 0,
        "ENTRY-OK app src/worker.zig start -> workerMain: src/worker.zig:8 workerMain enters worker:probe",
        "REPORTED app src/os/flatpak.zig spawn -> threadMain (worker:flatpak): flatpak: Linux only; not counted",
        "POINT test FIXTURE-HELPER src/worker.zig:13 init fixture(ui)",
        "POINT test TEST-EDIT-POINT src/worker.zig:18 (test) fixture(termio)",
        "POINT app MAIN-UI-SCOPE src/main_ghostty.zig:4 main enter(ui)",
        "RESULT PASS")
control("an entry whose target sets no role fails", tree(**{"src/worker.zig": WORKER.replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n    defer role.exit();\n', "")}), 1,
        "FAIL ENTRY-NO-ROLE app src/worker.zig start -> workerMain: its target sets no role (worker:probe)")
control("an entry whose target enters another role fails", tree(**{"src/worker.zig": WORKER.replace(
    '.{ .worker = "probe" }', '.{ .worker = "other" }')}), 1,
        "FAIL ENTRY-WRONG-ROLE app src/worker.zig start -> workerMain: its target enters worker:other, the registry "
        "says worker:probe")
control("a role set inside a nested block fails", tree(**{"src/worker.zig": WORKER.replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n    defer role.exit();\n',
    '    if (true) {\n        const role = thread_role.enter(.{ .worker = "probe" });\n        defer role.exit();\n    }\n')}),
        1, "FAIL ENTRY-NOT-TOP-LEVEL app src/worker.zig start -> workerMain")
control("a role-setting point in production code that no entry targets fails", tree(**{"src/worker.zig": WORKER + (
    'pub fn stray() void {\n    const role = thread_role.enter(.renderer);\n    defer role.exit();\n}\n')}), 1,
        "FAIL UNREGISTERED-POINT app src/worker.zig:22 stray: enter(renderer)")
control("main without its UI scope fails", tree(**{"src/main_ghostty.zig": GHOSTTY.replace(".ui", ".termio")}), 1,
        "FAIL NO-MAIN-UI-SCOPE app", "FAIL UNREGISTERED-POINT app src/main_ghostty.zig:4 main: enter(termio)")
control("a role literal on a receiver the file does not bind fails", tree(**{"src/worker.zig": WORKER + (
    'const roles = struct {\n    fn enter(r: anytype) void {\n        _ = r;\n    }\n};\n'
    'pub fn other() void {\n    roles.enter(.ui);\n}\n')}), 1,
        "FAIL UNREADABLE-POINT src/worker.zig:27 other: roles.enter(.ui)")
control("a re-exported role module is read", tree(**{"src/worker.zig": WORKER.replace(
    'const thread_role = @import("sync/thread_role.zig");',
    'const sync = struct {\n    const thread_role = @import("sync/thread_role.zig");\n};\nconst thread_role = sync.thread_role;')}),
        0, "RESULT PASS", absent=("UNREADABLE-POINT",))
control("a fixture helper that production code also names is no test edit point", tree(**{"src/worker.zig": WORKER + (
    'pub fn usesFixture() void {\n    ProbeFixture.init();\n}\n')}), 1,
        "FAIL UNREGISTERED-POINT app src/worker.zig:13 init: fixture(ui)")
control("an entry in a file no artifact reaches is reported, not counted", tree(), 0,
        "REPORTED app src/elsewhere.zig spawn -> elsewhereMain (worker:x): its file is not in the app exe; not counted",
        "RESULT PASS", registry=REGISTRY + "src/elsewhere.zig\tspawn\tThread.spawn\telsewhereMain\tworker:x\tnowhere\n")
control("an entry whose target is not defined fails", tree(), 1,
        "FAIL ENTRY-TARGET-NOT-FOUND app src/worker.zig start -> missingMain",
        registry=REGISTRY + "src/worker.zig\tstart\tThread.spawn\tmissingMain\tworker:probe\ta second spawn\n")

if failures:
    for f in failures:
        print("FAIL " + f)
    print(f"RESULT FAIL ({len(failures)} of the controls)")
    sys.exit(1)
print("RESULT PASS")
