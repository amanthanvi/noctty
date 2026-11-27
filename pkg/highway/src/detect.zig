const std = @import("std");
const builtin = @import("builtin");
const HwyTargets = @import("targets.zig").Targets;

/// This file is the root of highway's static library. Zig 0.17.1's stack
/// tracing does not compile in an MSVC static library for aarch64:
/// lib/std/debug/SelfInfo/Windows.zig:668 @ptrCasts an `*anyopaque` to a
/// function pointer without @alignCast (a function is aligned 4 on aarch64,
/// 1 on x86_64), and Debug's safety panics reach it through `defaultPanic`.
/// There a panic here prints its message without a stack trace; elsewhere
/// this is std's default. Remove once Zig fixes that line
/// (ZIG017-AARCH64-SELFINFO-01 in docs/agents/log/build-release-ci.md).
pub const std_options: std.Options = .{
    .allow_stack_tracing = !builtin.strip_debug_info and
        !(builtin.cpu.arch == .aarch64 and builtin.abi == .msvc),
};

const x86 = @import("detect/x86.zig");
const aarch64_darwin = @import("detect/aarch64_darwin.zig");
const aarch64_linux = @import("detect/aarch64_linux.zig");
const ppc = @import("detect/ppc.zig");
const s390x = @import("detect/s390x.zig");
const riscv = @import("detect/riscv.zig");
const loongarch = @import("detect/loongarch.zig");

/// Detect Highway targets at runtime using minimal, direct CPU feature
/// probing.
///
/// Previous versions called std.zig.system.resolveTargetQuery which
/// drags in the full Zig target/CPU model tables for every architecture,
/// bloating the binary by ~300 KB and causing code-layout regressions in
/// unrelated hot paths (icache / branch-predictor pressure).
///
/// This version uses only inline assembly (CPUID on x86, MRS on AArch64)
/// and lightweight syscalls (sysctlbyname on Darwin, getauxval on Linux),
/// so it adds no data tables and no std.Target dependency.
pub export fn ghostty_hwy_detect_targets() callconv(.c) i64 {
    return switch (builtin.target.cpu.arch) {
        .x86_64, .x86 => x86.detect(),
        .aarch64, .aarch64_be => detectAarch64(),
        .powerpc, .powerpc64, .powerpc64le => ppc.detect(),
        .s390x => s390x.detect(),
        .riscv32, .riscv64 => riscv.detect(),
        .loongarch32, .loongarch64 => loongarch.detect(),
        else => 0,
    };
}

fn detectAarch64() i64 {
    var t: HwyTargets = .{};

    // All AArch64 implementations have NEON.
    t.neon_without_aes = true;

    if (comptime builtin.target.os.tag.isDarwin()) {
        return aarch64_darwin.detect(&t);
    } else if (comptime builtin.target.os.tag == .linux) {
        return aarch64_linux.detect(&t);
    }

    // Other OS: return baseline NEON.
    return @bitCast(t);
}
