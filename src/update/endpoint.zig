//! Updater endpoint abstraction (C31).
//!
//! Default remains GitHub Releases. Override the API origin with
//! `WINGHOSTTY_UPDATE_API_BASE` so sync tooling can re-point when
//! upstream leaves GitHub. No user-facing config knob.

const std = @import("std");

pub const default_api_base = "https://api.github.com";
pub const default_page_base = "https://github.com";
pub const env_api_base = "WINGHOSTTY_UPDATE_API_BASE";

pub const repo_owner = "amanthanvi";
pub const repo_name = "winghostty";

pub fn latestStableApiUrl(alloc: std.mem.Allocator, api_base: []const u8) ![]u8 {
    const base = std.mem.trimRight(u8, api_base, "/");
    return std.fmt.allocPrint(
        alloc,
        "{s}/repos/{s}/{s}/releases/latest",
        .{ base, repo_owner, repo_name },
    );
}

pub fn releasesPageUrl(alloc: std.mem.Allocator, page_base: []const u8) ![]u8 {
    const base = std.mem.trimRight(u8, page_base, "/");
    return std.fmt.allocPrint(
        alloc,
        "{s}/{s}/{s}/releases",
        .{ base, repo_owner, repo_name },
    );
}

pub fn latestStableApiUrlOwned(alloc: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, env_api_base)) |base| {
        defer alloc.free(base);
        return latestStableApiUrl(alloc, base);
    } else |_| {
        return latestStableApiUrl(alloc, default_api_base);
    }
}

pub fn resolveApiBase(alloc: std.mem.Allocator) []const u8 {
    return std.process.getEnvVarOwned(alloc, env_api_base) catch default_api_base;
}

test "latestStableApiUrl is re-pointable" {
    const testing = std.testing;
    const github = try latestStableApiUrl(testing.allocator, default_api_base);
    defer testing.allocator.free(github);
    try testing.expectEqualStrings(
        "https://api.github.com/repos/amanthanvi/winghostty/releases/latest",
        github,
    );

    const mirror = try latestStableApiUrl(testing.allocator, "https://git.example/api/v3/");
    defer testing.allocator.free(mirror);
    try testing.expectEqualStrings(
        "https://git.example/api/v3/repos/amanthanvi/winghostty/releases/latest",
        mirror,
    );
}
