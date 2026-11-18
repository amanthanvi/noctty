"""Optional two-compiler syntax/semantic controls; never run the application."""

import json
import os
import shlex
import subprocess
from pathlib import Path

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


def run(root, zig17, output, pause):
    output.mkdir(parents=True)  # retain every earlier attempt; require a fresh directory
    root, output = root.resolve(), output.resolve()
    names = (root / "ci/win32-removed-identifiers.txt").read_text(encoding="utf-8").splitlines()
    sources = {"types.zig": TYPE_SOURCE, "repeat.zig": REPEAT_SOURCE,
               "census15.zig": census_source(names, len(names)), "census17.zig": census_source(names, 0)}
    for name, source in sources.items():
        (output / name).write_text(source, encoding="utf-8", newline="\n")
    env = {**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(output / "global-cache")}
    bash = str(Path(os.environ["ProgramFiles"]) / "Git/bin/bash.exe")
    results = []
    for version, compiler, operation, source, expected in (
        ("015", "zig", "test", "types.zig", 0),
        ("017", str(zig17), "test", "types.zig", 0),
        ("015", "zig", "test", "repeat.zig", 0),
        ("017", str(zig17), "ast-check", "repeat.zig", 1),
        ("015", "zig", "test", "census15.zig", 0),
        ("017", str(zig17), "test", "census17.zig", 0),
    ):
        # Backslashes keep MSYS from treating drive colons inside cmd's single
        # command argument as a POSIX path list.
        args = [compiler, operation, str(output / source)]
        if operation == "test":
            args += ["--cache-dir", str(output / "local-cache"),
                     "--global-cache-dir", str(output / "global-cache")]
        if any('"' in a for a in args):
            raise ValueError("unsupported quote in compiler control path")
        cmd = 'scripts\\dev-windows.cmd ' + " ".join('"' + a + '"' if " " in a else a for a in args)
        command = ("pwsh -NoProfile -File " + shlex.quote(pause.as_posix()) +
                   " && cmd.exe //c " + shlex.quote(cmd))
        result = subprocess.run([bash, "-c", command], cwd=root, env=env, capture_output=True)
        label = version + "-" + source.removesuffix(".zig")
        (output / (label + ".log")).write_bytes(result.stdout + result.stderr)
        (output / (label + ".exit")).write_text(str(result.returncode) + "\n", encoding="utf-8")
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
