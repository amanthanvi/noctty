const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const global = @import("../global.zig");
const flatpak = if (builtin.os.tag == .linux) @import("flatpak.zig") else struct {
    pub fn isFlatpak() bool {
        return false;
    }
};

pub const Error = Allocator.Error;

/// Get the environment map.
pub fn getEnvMap(alloc: Allocator) !std.process.Environ.Map {
    return if (flatpak.isFlatpak())
        .init(alloc)
    else
        try global.environ().createMap(alloc);
}

pub const GetEnvVarOwnedError = error{
    OutOfMemory,
    EnvironmentVariableNotFound,
    InvalidWtf8,
};

/// Zig 0.15.2's `std.process.getEnvVarOwned`, which 0.17 removed: one
/// variable of the live process environment (looked up case-insensitively
/// on Windows), owned by the caller, with 0.15's error names. Unlike
/// `std.process.Environ.getAlloc` it copies the one value only, not the
/// whole block, so a small fixed buffer still holds it.
pub fn getEnvVarOwned(alloc: Allocator, key: []const u8) GetEnvVarOwnedError![]u8 {
    if (comptime builtin.os.tag != .windows) {
        @compileError("getEnvVarOwned is the fork's Windows port");
    }
    const key_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, key);
    defer alloc.free(key_w);
    const value = global.environ().getWindows(key_w) orelse
        return error.EnvironmentVariableNotFound;
    return std.unicode.wtf16LeToWtf8Alloc(alloc, value);
}

/// Zig 0.15.2's `std.process.hasEnvVarConstant`, over the live process
/// environment.
pub fn hasEnvVarConstant(comptime key: []const u8) bool {
    return global.environ().containsConstant(key);
}

/// Append a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
pub fn appendEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    // Otherwise we must prefix.
    return try appendEnvAlways(alloc, current, value);
}

/// Always append value to environment, even when it is empty.
/// This is useful because some env vars (like MANPATH) want there
/// to be an empty prefix to preserve existing values.
///
/// The returned value is always allocated so it must be freed.
pub fn appendEnvAlways(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Error![]u8 {
    return try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        current,
        std.fs.path.delimiter,
        value,
    });
}

/// Prepend a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
pub fn prependEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    return try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        value,
        std.fs.path.delimiter,
        current,
    });
}

/// The result of getenv, with a shared deinit to properly handle allocation
/// on Windows.
pub const GetEnvResult = struct {
    value: []const u8,

    pub fn deinit(self: GetEnvResult, alloc: Allocator) void {
        switch (builtin.os.tag) {
            .windows => alloc.free(self.value),
            else => {},
        }
    }
};

/// Gets the value of an environment variable, or null if not found.
/// This will allocate on Windows but not on other platforms. The returned
/// value should have deinit called to do the proper cleanup no matter what
/// platform you are on.
pub fn getenv(alloc: Allocator, key: []const u8) Error!?GetEnvResult {
    return switch (builtin.os.tag) {
        // Non-Windows doesn't need to allocate
        else => if (posix.getenv(key)) |v| .{ .value = v } else null,

        // Windows needs to allocate
        .windows => if (getEnvVarOwned(alloc, key)) |v| .{
            .value = v,
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            error.InvalidWtf8 => null,
            else => |e| e,
        },
    };
}

/// Gets the value of an environment variable. Returns null if not found or the
/// value is empty. This will allocate on Windows but not on other platforms.
/// The returned value should have deinit called to do the proper cleanup no
/// matter what platform you are on.
pub fn getenvNotEmpty(alloc: Allocator, key: []const u8) !?GetEnvResult {
    const result_ = try getenv(alloc, key);
    if (result_) |result| {
        if (result.value.len == 0) {
            result.deinit(alloc);
            return null;
        }
    }
    return result_;
}

/// Gets an owned environment variable value, trims ASCII whitespace, and
/// returns null if the variable is unset or trims to empty.
pub fn getEnvVarOwnedTrimmedNotEmpty(
    alloc: Allocator,
    key: []const u8,
) Error!?[]const u8 {
    const raw = getEnvVarOwned(alloc, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        error.InvalidWtf8 => return null,
        else => |e| return e,
    };
    errdefer alloc.free(raw);

    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        alloc.free(raw);
        return null;
    }

    if (trimmed.len == raw.len) return raw;
    const duped = try alloc.dupe(u8, trimmed);
    alloc.free(raw);
    return duped;
}

pub fn setenv(key: [:0]const u8, value: [:0]const u8) c_int {
    return switch (builtin.os.tag) {
        .windows => c._putenv_s(key.ptr, value.ptr),
        else => c.setenv(key.ptr, value.ptr, 1),
    };
}

pub fn unsetenv(key: [:0]const u8) c_int {
    return switch (builtin.os.tag) {
        .windows => c._putenv_s(key.ptr, ""),
        else => c.unsetenv(key.ptr),
    };
}

const c = struct {
    // POSIX
    extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: ?[*]const u8) c_int;

    // Windows
    extern "c" fn _putenv_s(varname: ?[*]const u8, value_string: ?[*]const u8) c_int;
};

test "appendEnv empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try appendEnv(alloc, "", "foo");
    defer alloc.free(result);
    try testing.expectEqualStrings(result, "foo");
}

test "appendEnv existing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try appendEnv(alloc, "a:b", "foo");
    defer alloc.free(result);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings(result, "a:b;foo");
    } else {
        try testing.expectEqualStrings(result, "a:b:foo");
    }
}

test "prependEnv empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try prependEnv(alloc, "", "foo");
    defer alloc.free(result);
    try testing.expectEqualStrings(result, "foo");
}

test "prependEnv existing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try prependEnv(alloc, "a:b", "foo");
    defer alloc.free(result);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings(result, "foo;a:b");
    } else {
        try testing.expectEqualStrings(result, "foo:a:b");
    }
}
