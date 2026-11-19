"""Optional two-compiler syntax/semantic controls; never run the application."""

import json
import os
import subprocess
from pathlib import Path

# Decoded relative paths, measured with Windows Zig 0.15.2. Keep the rejected
# spellings too, so path-normalization claims remain tied to native behavior.
# A single trailing directory dot is deliberately absent: acceptance depends on
# whether Zig opens the fixture relative to its cwd or by an absolute path.
IMPORT_PATHS = (
    ("forward", "../../os/windows.zig", True),
    ("backslash", r"..\..\os\windows.zig", True),
    ("mixed", r"..\../os\windows.zig", True),
    ("dot", "./../../os/./windows.zig", True),
    ("parent", "../../os/../os/windows.zig", True),
    ("repeated-slash", "../..//os//windows.zig", True),
    ("repeated-backslash", r"..\\..\os\\windows.zig", True),
    ("case", "../../OS/WINDOWS.zig", True),
    ("file-trailing-dot", "../../os/windows.zig.", False),
    ("file-trailing-space", "../../os/windows.zig ", False),
    ("directory-trailing-space", "../../os /windows.zig", False),
    ("directory-many-dots", "../../os.../windows.zig", False),
    ("directory-dot-space", "../../os. /windows.zig", False),
    ("parent-trailing-space", "../.. /os/windows.zig", False),
    ("dot-trailing-space", "./../../os/. /windows.zig", False),
)

TYPE_SOURCE = '''const std = @import("std");
fn identity(comptime T: type) type { return T; }
fn choose(comptime flag: bool) type { return if (flag) **const u8 else **const u16; }
fn take(p: **const u8) void { _ = p; }
fn result() **const u8 { return undefined; }
fn aligned() align(8) **const u8 { return undefined; }
extern fn foreign() **const u8;
const Fields = struct { p: **const u8 };
const Variant = union(enum) { p: **const u8, empty };
test "pointer expressions in grammar contexts" {
    const T = **const u8;
    const conditional = if (true) **const u8 else **const u8;
    const mixed = if (true) **u8 else *u8;
    const labelled = blk: { break :blk **const u8; };
    const captured = if (@as(?u8, 1)) |_| **const u8 else **const u16;
    const switched = switch (true) { true => **const u8, false => **const u16 };
    const loop = while (false) **const u8 else **const u8;
    const continued = while (false) : ({}) **const u8 else **const u8;
    const iterated = for ([0]u8{}) |_| **const u8 else **const u8;
    const qualified = struct { pub const Pointer = *const **const u8; };
    inline for (.{ T, conditional, mixed, labelled, captured, switched, loop,
        continued, iterated, qualified.Pointer, choose(true), choose(false),
        ?**const u8, [2]**const u8, []**const u8, [*]**const u8,
        anyerror!**const u8, fn () **const u8, identity(**const u8),
        @as(type, **const u8), Fields, Variant }) |Pointer| {
        try std.testing.expect(@TypeOf(Pointer) == type);
    }
    try std.testing.expect(T == conditional and T == labelled and T == captured);
    try std.testing.expect(T == choose(true) and choose(false) == **const u16);
    try std.testing.expect(mixed == **u8);
    try std.testing.expect(@TypeOf(result) == fn () **const u8);
    try std.testing.expect(@TypeOf(foreign) == fn () callconv(.c) **const u8);
    take(undefined);
    _ = aligned();
}
'''

REPEAT_SOURCE = '''const std = @import("std");
fn make() [1]u8 { return .{'x'}; }
fn repeated() [2]u8 { return ("x".*) ** 2; }
test "binary repeat twins" {
    const a0 = "x".* ** 2;
    const a1 = [_]u8{'x'} ** 2;
    const a2 = make() ** 2;
    const a3 = (make()) ** 2;
    const a4 = ([1][1]u8{.{'x'}})[0] ** 2;
    const a5 = if (true) "x".* ** 2 else "y".* ** 2;
    const a6 = blk: { break :blk "x".* ** 2; };
    const a7 = if (@as(?u8, 1)) |_| "x".* ** 2 else "y".* ** 2;
    const a8 = (blk: { break :blk "x".*; }) ** 2;
    const a9 = (if (true) "x".* else "y".*) ** 2;
    const optional: ?[1]u8 = .{'x'};
    const a10 = optional.? ** 2;
    inline for (.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, repeated() }) |value| {
        try std.testing.expectEqualStrings("xx", &value);
    }
}
'''

PARAMETER_SOURCE = '''const Native = struct {
    pub const os = struct { pub const windows = struct { pub const kernel32 = struct {
        pub fn Sleep(_: u32) void {}
    }; }; };
};
fn call(comptime std: type) void { std.os.windows.kernel32.Sleep(1); }
fn choose(comptime std: type) @TypeOf(std.os.windows.kernel32.Sleep) {
    return std.os.windows.kernel32.Sleep;
}
fn chooseLabeled(comptime std: type) blk: {
    break :blk @TypeOf(std.os.windows.kernel32.Sleep);
} {
    return std.os.windows.kernel32.Sleep;
}
test "a parameter named std is not the std module" {
    call(Native); choose(Native)(1); chooseLabeled(Native)(1);
}
'''


def census_source(names, expected):
    paths = ",\n".join(".{" + ",".join(json.dumps(p) for p in name.split(".")) + "}" for name in names)
    return '''const std = @import("std");
fn present(comptime T: type, comptime parts: []const []const u8) bool {
    if (!@hasDecl(T, parts[0])) return false;
    if (parts.len == 1) return true;
    const child = @field(T, parts[0]);
    if (@TypeOf(child) != type) return false;
    return present(child, parts[1..]);
}
test "removed declaration census" {
    @setEvalBranchQuota(1000000);
    comptime var count: usize = 0;
    inline for (.{
''' + paths + '''
    }) |parts| { if (comptime present(std.os.windows, &parts)) count += 1; }
    try std.testing.expectEqual(@as(usize, ''' + str(expected) + '''), count);
}
'''


def compiler_call(root, output, pause, compiler, operation, source, label):
    env = {**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(output / "global-cache")}
    args = [compiler, operation, str(source)]
    if operation == "test":
        args += ["--cache-dir", str(output / "local-cache"),
                 "--global-cache-dir", str(output / "global-cache")]
    # Quotes protect CMD metacharacters such as & and parentheses. Percent and
    # delayed expansion remain active inside quotes, so reject those spellings.
    if any(any(c in a for c in '\"%!\r\n\0') for a in [*args, str(pause)]):
        raise ValueError("unsupported CMD expansion or quote in compiler control path")
    cmd = 'scripts\\dev-windows.cmd ' + " ".join('"' + a + '"' for a in args)
    # Pass a native Windows command line. A Bash/C-argv round trip turns the
    # embedded quotes into literal backslash-quotes for CMD.
    command = ('cmd.exe /d /v:off /s /c "pwsh -NoProfile -File "' + str(pause) +
               '" && ' + cmd + '"')
    result = subprocess.run(command, cwd=root, env=env, capture_output=True,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    (output / (label + ".log")).write_bytes(result.stdout + result.stderr)
    (output / (label + ".exit")).write_text(str(result.returncode) + "\n", encoding="utf-8")
    return result


def run_imports(root, output, pause):
    output.mkdir(parents=True)  # keep previous attempts intact
    root, output = root.resolve(), output.resolve()
    results = []
    for label, spelling, accepted in IMPORT_PATHS:
        fixture = output / label
        (fixture / "src/os").mkdir(parents=True)
        (fixture / "src/apprt/win32").mkdir(parents=True)
        (fixture / "src/os/windows.zig").write_text(
            'pub const kernel32 = @import("std").os.windows.kernel32;\n', encoding="utf-8", newline="\n")
        (fixture / "src/apprt/win32/probe.zig").write_text(
            'const w = @import(' + json.dumps(spelling) + ');\n'
            'pub fn call() void { _ = w.kernel32.GetLastError(); }\n', encoding="utf-8", newline="\n")
        source = fixture / "root.zig"
        source.write_text('test "import spelling" { @import("src/apprt/win32/probe.zig").call(); }\n',
                          encoding="utf-8", newline="\n")
        result = compiler_call(root, output, pause, "zig", "test", source, "015-import-" + label)
        data = result.stdout + result.stderr
        assert result.returncode == (0 if accepted else 1), (label, result.returncode)
        if accepted:
            assert b"All 1 tests passed" in data, label
        else:
            assert b"FileNotFound" in data or b"no module named" in data, label
        results.append(dict(label=label, path=spelling, accepted=accepted, exit=result.returncode))
    (output / "import-result.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print("Windows import spellings:", sum(row["accepted"] for row in results), "accepted /",
          sum(not row["accepted"] for row in results), "rejected as expected")
    return results


def run(root, zig17, output, pause):
    output.mkdir(parents=True)  # retain every earlier attempt; require a fresh directory
    root, output = root.resolve(), output.resolve()
    names = (root / "ci/win32-removed-identifiers.txt").read_text(encoding="utf-8").splitlines()
    sources = {"types.zig": TYPE_SOURCE, "repeat.zig": REPEAT_SOURCE, "parameters.zig": PARAMETER_SOURCE,
               "census15.zig": census_source(names, len(names)), "census17.zig": census_source(names, 0)}
    for name, source in sources.items():
        (output / name).write_text(source, encoding="utf-8", newline="\n")
    results = []
    for version, compiler, operation, source, expected in (
        ("015", "zig", "test", "types.zig", 0),
        ("017", str(zig17), "test", "types.zig", 0),
        ("015", "zig", "test", "parameters.zig", 0),
        ("017", str(zig17), "test", "parameters.zig", 0),
        ("015", "zig", "test", "repeat.zig", 0),
        ("017", str(zig17), "ast-check", "repeat.zig", 1),
        ("015", "zig", "test", "census15.zig", 0),
        ("017", str(zig17), "test", "census17.zig", 0),
    ):
        label = version + "-" + source.removesuffix(".zig")
        result = compiler_call(root, output, pause, compiler, operation, output / source, label)
        assert result.returncode == expected, (label, result.returncode)
        if operation == "test":
            assert b"All 1 tests passed" in result.stdout + result.stderr, label
        else:
            assert b"error:" in result.stderr + result.stdout, label
        results.append(dict(label=label, exit=result.returncode))
    report = dict(removed_names=len(names), runs=results)
    (output / "compiler-result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("Both compilers: pointer controls pass; 0.15 repeat passes / 0.17 rejects; census", len(names))
    return report
