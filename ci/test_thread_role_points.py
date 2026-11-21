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
        "FAIL ENTRY-NO-ROLE app src/worker.zig start -> workerMain: its target (src/worker.zig:7) sets no role "
        "(worker:probe)")
control("an entry whose target enters another role fails", tree(**{"src/worker.zig": WORKER.replace(
    '.{ .worker = "probe" }', '.{ .worker = "other" }')}), 1,
        "FAIL ENTRY-WRONG-ROLE app src/worker.zig start -> workerMain: its target (src/worker.zig:7) enters "
        "worker:other, the registry says worker:probe")
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
control("an entry whose spawn names no declaration fails", tree(**{"src/worker.zig": WORKER + (
    'pub fn startMissing() void {\n    _ = std.Thread.spawn(.{}, missingMain, .{}) catch {};\n}\n')}), 1,
        "FAIL ENTRY-TARGET-NOT-FOUND app src/worker.zig startMissing -> missingMain: missingMain is declared in no "
        "scope",
        registry=REGISTRY + "src/worker.zig\tstartMissing\tThread.spawn\tmissingMain\tworker:probe\ta second spawn\n")
control("an entry whose function makes no such spawn fails", tree(), 1,
        "FAIL ENTRY-SPAWN-NOT-FOUND app src/worker.zig start -> missingMain: start in src/worker.zig makes no "
        "Thread.spawn of missingMain",
        registry=REGISTRY + "src/worker.zig\tstart\tThread.spawn\tmissingMain\tworker:probe\ta second spawn\n")
# Stone round 3, Sol's Medium 1: an entry is the function its spawn names, never a same-named function elsewhere.
# The worker's watcher `Deadline.run` enters no role, and an unrelated file's `run` enters the registry's role.
DEADLINE_WORKER = WORKER + (
    'const Deadline = struct {\n    fn run() void {}\n};\n'
    'pub fn watch() void {\n    const t = std.Thread.spawn(.{}, Deadline.run, .{}) catch return;\n    t.join();\n}\n')
OTHER_RUN = ('const thread_role = @import("sync/thread_role.zig");\n'
             'pub fn run() void {\n    const role = thread_role.enter(.test_support);\n    defer role.exit();\n}\n')
DEADLINE_REGISTRY = REGISTRY + "src/worker.zig\twatch\tThread.spawn\tDeadline.run\ttest_support\tthe watcher\n"
control("an unrelated same-named run that enters the role does not credit the target", tree(**{
    "src/worker.zig": DEADLINE_WORKER, "src/other.zig": OTHER_RUN,
    "src/main_ghostty.zig": GHOSTTY.replace('const worker = @import("worker.zig");',
                                            'const worker = @import("worker.zig");\nconst other = @import("other.zig");')}),
        1, "FAIL ENTRY-NO-ROLE app src/worker.zig watch -> Deadline.run: its target (src/worker.zig:22) sets no role "
        "(test_support)", "FAIL UNREGISTERED-POINT app src/other.zig:3 run: enter(test_support)",
        registry=DEADLINE_REGISTRY, absent=("ENTRY-OK app src/worker.zig watch",))
control("an entry's target through an import is the imported file's function", tree(**{
    "src/worker.zig": WORKER.replace("std.Thread.spawn(.{}, workerMain, .{})", "std.Thread.spawn(.{}, helper.helperMain, .{})")
    .replace('    const role = thread_role.enter(.{ .worker = "probe" });\n    defer role.exit();\n', "")
    .replace('const thread_role = @import("sync/thread_role.zig");',
             'const thread_role = @import("sync/thread_role.zig");\nconst helper = @import("helper.zig");'),
    "src/helper.zig": ('const thread_role = @import("sync/thread_role.zig");\n'
                       'pub fn helperMain() void {\n    const role = thread_role.enter(.{ .worker = "probe" });\n'
                       '    defer role.exit();\n}\n')}), 0,
        "ENTRY-OK app src/worker.zig start -> helper.helperMain: src/helper.zig:3 helperMain enters worker:probe",
        "RESULT PASS",
        registry=REGISTRY.replace("\tworkerMain\t", "\thelper.helperMain\t"))
control("a main whose UI scope comes after its first work fails", tree(**{"src/main_ghostty.zig": GHOSTTY.replace(
    '    const role_scope = thread_role.enter(.ui);\n    defer role_scope.exit();\n    worker.start();\n',
    '    worker.start();\n    const role_scope = thread_role.enter(.ui);\n    defer role_scope.exit();\n')}), 1,
        "FAIL NO-MAIN-UI-SCOPE app", "FAIL UNREGISTERED-POINT app src/main_ghostty.zig:5 main: enter(ui)")

# Stone round 4, Sol's Medium 1: a deferred role call runs at the function's exit, so it is no scope at entry,
# in main or in an entry's target; and a switch subject the build does not set picks no arm.
control("a deferred first statement in main is no UI scope", tree(**{"src/main_ghostty.zig": GHOSTTY.replace(
    '    const role_scope = thread_role.enter(.ui);\n    defer role_scope.exit();\n',
    '    defer _ = thread_role.enter(.ui);\n')}), 1,
        "FAIL NO-MAIN-UI-SCOPE app", "FAIL UNREGISTERED-POINT app src/main_ghostty.zig:4 main: enter(ui)",
        absent=("POINT app MAIN-UI-SCOPE",))
control("a deferred first statement in an entry's target is no entry scope", tree(**{"src/worker.zig": WORKER.replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n    defer role.exit();\n',
    '    defer _ = thread_role.enter(.{ .worker = "probe" });\n')}), 1,
        "FAIL ENTRY-NOT-FIRST app src/worker.zig start -> workerMain: its role call (src/worker.zig:8)",
        absent=("ENTRY-OK app src/worker.zig start",))
SWITCH_WORKER = WORKER + (
    'const Scoped = struct {\n    fn run() void {\n        const role = thread_role.enter(.{ .worker = "probe" });\n'
    '        defer role.exit();\n    }\n};\n'
    'const Unscoped = struct {\n    fn run() void {}\n};\n'
    'pub fn startSelected() void {\n    const t = std.Thread.spawn(.{}, Target.run, .{}) catch return;\n    t.join();\n}\n')
SWITCH_REGISTRY = REGISTRY + "src/worker.zig\tstartSelected\tThread.spawn\tTarget.run\tworker:probe\tthe selected target\n"
control("a constant .other switch subject does not credit the .ghostty arm", tree(**{"src/worker.zig": SWITCH_WORKER + (
    'const selected = .{ .artifact = .other };\n'
    'const Target = switch (selected.artifact) {\n    .ghostty => Scoped,\n    .other => Unscoped,\n};\n')}), 1,
        "FAIL ENTRY-NO-ROLE app src/worker.zig startSelected -> Target.run: its target (src/worker.zig:28) sets no role",
        "FAIL UNREGISTERED-POINT app src/worker.zig:23 run: enter(worker:probe)",
        registry=SWITCH_REGISTRY, absent=("ENTRY-OK app src/worker.zig startSelected",))
control("a switch subject the checker cannot prove is the build's selects no arm", tree(**{"src/worker.zig": SWITCH_WORKER + (
    'const Target = switch (@import("other_options").artifact) {\n    .ghostty => Scoped,\n    .other => Unscoped,\n};\n')}), 1,
        "FAIL ENTRY-AMBIGUOUS app src/worker.zig startSelected -> Target.run: src/worker.zig:34: a switch on "
        '@import("other_options").artifact, which the checker cannot evaluate',
        registry=SWITCH_REGISTRY, absent=("ENTRY-OK app src/worker.zig startSelected",))
control("the build's own artifact selector selects its arm", tree(**{
    "src/worker.zig": SWITCH_WORKER + (
        'const options = @import("terminal_options");\n'
        'const Target = switch (options.artifact) {\n    .ghostty => Scoped,\n    .other => Unscoped,\n};\n'),
    "src/terminal/build_options.zig": ('pub fn add(self: Options, b: *Build, m: *Module) void {\n'
                                       '    const opts = b.addOptions();\n'
                                       '    opts.addOption(Artifact, "artifact", self.artifact);\n'
                                       '    m.addOptions("terminal_options", opts);\n}\n'),
    "src/build/SharedDeps.zig": ('pub fn add(self: *const SharedDeps, step: *Compile) void {\n'
                                 '    self.config.terminalOptions(.ghostty).add(b, step.root_module);\n}\n')}), 0,
        "ENTRY-OK app src/worker.zig startSelected -> Target.run: src/worker.zig:23 run enters worker:probe",
        "RESULT PASS", registry=SWITCH_REGISTRY)

# Stone round 4, Opus L1: a guarded role call (`if (false) ...`) may never run, so it is no scope; and the scope is
# the first statement executed, so a statement before it fails, while a `defer` before it (which runs nothing where
# it stands, as Surface.zig's Click.run registers `defer job.done.set();`) does not.
control("a braceless if around an entry's role call is no entry scope", tree(**{"src/worker.zig": WORKER.replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n    defer role.exit();\n',
    '    if (false) thread_role.enter(.{ .worker = "probe" }).exit();\n')}), 1,
        "FAIL ENTRY-NOT-FIRST app src/worker.zig start -> workerMain: its role call (src/worker.zig:8)",
        absent=("ENTRY-OK app src/worker.zig start",))
control("a braceless if around main's role call is no UI scope", tree(**{"src/main_ghostty.zig": GHOSTTY.replace(
    '    const role_scope = thread_role.enter(.ui);\n    defer role_scope.exit();\n',
    '    if (false) thread_role.enter(.ui).exit();\n')}), 1,
        "FAIL NO-MAIN-UI-SCOPE app", "FAIL UNREGISTERED-POINT app src/main_ghostty.zig:4 main: enter(ui)",
        absent=("POINT app MAIN-UI-SCOPE",))
control("a statement before an entry's role scope fails", tree(**{"src/worker.zig": WORKER.replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n',
    '    std.debug.print("early\\n", .{});\n    const role = thread_role.enter(.{ .worker = "probe" });\n')}), 1,
        "FAIL ENTRY-NOT-FIRST app src/worker.zig start -> workerMain: its role call (src/worker.zig:9)",
        absent=("ENTRY-OK app src/worker.zig start",))
control("a defer before an entry's role scope keeps it the first statement executed", tree(**{
    "src/worker.zig": WORKER.replace(
        '    const role = thread_role.enter(.{ .worker = "probe" });\n',
        '    defer std.debug.print("done\\n", .{});\n    const role = thread_role.enter(.{ .worker = "probe" });\n')}),
        0, "ENTRY-OK app src/worker.zig start -> workerMain: src/worker.zig:9 workerMain enters worker:probe",
        "RESULT PASS")
# Stone round 4, Opus L3: an entry only a test build spawns is no entry of the app exe: reported there, counted in
# the test exe.
control("an entry whose spawning function only tests name is reported for the app exe", tree(**{
    "src/worker.zig": WORKER + (
        'fn startForTests() void {\n    const t = std.Thread.spawn(.{}, testWorkerMain, .{}) catch return;\n'
        '    t.join();\n}\n'
        'fn testWorkerMain() void {\n    const role = thread_role.enter(.test_support);\n    defer role.exit();\n}\n'
        'test "a spawning test" {\n    startForTests();\n}\n')}), 0,
        "REPORTED app src/worker.zig startForTests -> testWorkerMain (test_support): its spawning function is "
        "compiled only into a test build; not counted",
        "ENTRY-OK test src/worker.zig startForTests -> testWorkerMain: src/worker.zig:26 testWorkerMain enters "
        "test_support", "app exe: 4 files; 1 entries set their role; points ENTRY 1,", "RESULT PASS",
        registry=REGISTRY + "src/worker.zig\tstartForTests\tThread.spawn\ttestWorkerMain\ttest_support\ta test helper\n",
        absent=("ENTRY-OK app src/worker.zig startForTests",))

# Stone round 5, Sol's Low: a required entry point's scope must set a role. `Roles(.off)` (here through an alias,
# as in Sol's overlay) keeps no role in any build, and role none is no role.
OFF_ALIAS = 'const off_roles = thread_role.Roles(.off);\n'
control("an aliased Roles(.off) scope is no UI scope in main", tree(**{"src/main_ghostty.zig": GHOSTTY.replace(
    'const worker = @import("worker.zig");\n', 'const worker = @import("worker.zig");\n' + OFF_ALIAS).replace(
    '    const role_scope = thread_role.enter(.ui);\n', '    const role_scope = off_roles.enter(.ui);\n')}), 1,
        "FAIL NO-MAIN-UI-SCOPE app", "FAIL UNREGISTERED-POINT app src/main_ghostty.zig:5 main: enter(ui)",
        absent=("POINT app MAIN-UI-SCOPE",))
control("an aliased Roles(.off) scope is no entry scope", tree(**{"src/worker.zig": WORKER.replace(
    'const thread_role = @import("sync/thread_role.zig");\n',
    'const thread_role = @import("sync/thread_role.zig");\n' + OFF_ALIAS + 'const quiet_roles = off_roles;\n').replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n',
    '    const role = off_roles.enter(.{ .worker = "probe" });\n')}), 1,
        "FAIL ENTRY-SETS-NO-ROLE app src/worker.zig start -> workerMain: its first statement (src/worker.zig:10) is "
        "a off-form scope of role worker:probe, which sets no role",
        absent=("ENTRY-OK app src/worker.zig start",))
control("an alias of an aliased Roles(.off) is no entry scope either", tree(**{"src/worker.zig": WORKER.replace(
    'const thread_role = @import("sync/thread_role.zig");\n',
    'const thread_role = @import("sync/thread_role.zig");\n' + OFF_ALIAS + 'const quiet_roles = off_roles;\n').replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n',
    '    const role = quiet_roles.enter(.{ .worker = "probe" });\n')}), 1,
        "FAIL ENTRY-SETS-NO-ROLE app src/worker.zig start -> workerMain: its first statement (src/worker.zig:10) is "
        "a off-form scope of role worker:probe, which sets no role",
        absent=("ENTRY-OK app src/worker.zig start", "UNREADABLE-POINT"))
control("a role none scope is no entry scope, whatever the registry says", tree(**{"src/worker.zig": WORKER.replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n', '    const role = thread_role.enter(.none);\n')}), 1,
        "FAIL ENTRY-SETS-NO-ROLE app src/worker.zig start -> workerMain: its first statement (src/worker.zig:8) is "
        "a module-form scope of role none, which sets no role",
        registry=REGISTRY.replace("\tworker:probe\t", "\tnone\t"), absent=("ENTRY-OK app src/worker.zig start",))
control("a Roles(.on) scope is an entry scope", tree(**{"src/worker.zig": WORKER.replace(
    'const thread_role = @import("sync/thread_role.zig");\n',
    'const thread_role = @import("sync/thread_role.zig");\nconst on_roles = thread_role.Roles(.on);\n').replace(
    '    const role = thread_role.enter(.{ .worker = "probe" });\n',
    '    const role = on_roles.enter(.{ .worker = "probe" });\n')}), 0,
        "ENTRY-OK app src/worker.zig start -> workerMain: src/worker.zig:9 workerMain enters worker:probe",
        "RESULT PASS")

# Stone round 5, Opus L1 (G1): an `if (builtin.is_test)` branch whose braceless body is a block statement (here a
# `for`) reaches no `;`, `,` or `else` first, so nothing of it is test-gated, and the production scope after it is
# no test edit point.
control("G1: a production scope after a braceless block in an is_test branch is not test-gated", tree(**{
    "src/worker.zig": WORKER + (
        'const builtin = @import("builtin");\n'
        'pub fn stray(xs: []const u8) void {\n    if (builtin.is_test) for (xs) |x| {\n        _ = x;\n    }\n'
        '    const role = thread_role.enter(.renderer);\n    defer role.exit();\n}\n')}), 1,
        "FAIL UNREGISTERED-POINT app src/worker.zig:26 stray: enter(renderer)",
        "FAIL UNREGISTERED-POINT test src/worker.zig:26 stray: enter(renderer)",
        absent=("TEST-EDIT-POINT src/worker.zig:26",))

if failures:
    for f in failures:
        print("FAIL " + f)
    print(f"RESULT FAIL ({len(failures)} of the controls)")
    sys.exit(1)
print("RESULT PASS")
