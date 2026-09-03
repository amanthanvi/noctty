//! Compile-time view of `dist/windows/conpty-redist.json`, the single pin
//! document for Microsoft's bundled ConPTY pair.
//!
//! `scripts/conpty-redist.ps1` stages `conpty.dll` and `OpenConsole.exe` from
//! this file, `scripts/verify-published-release.ps1` re-checks the published
//! portable ZIP against it, and the in-app portable updater checks the same
//! two files against the table below. Embedding the packaging script's own
//! document is what keeps the updater's pins from drifting away from the
//! bytes the release actually shipped.
//!
//! The pair is deliberately outside `Get-WindowsSignedRuntimePayloads` in
//! `scripts/common.ps1`: noctty never re-signs it, so it can never satisfy
//! the updater's publisher pin.
const std = @import("std");
const builtin = @import("builtin");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The raw pin document. `@embedFile` cannot escape the `src/` module root,
/// so `dist/windows/conpty-redist.json` arrives as the `conpty_redist_json`
/// anonymous import wired in `src/build/SharedDeps.zig`.
pub const document = @embedFile("conpty_redist_json");

pub const schema_version = "1";
pub const package_id = "Microsoft.Windows.Console.ConPTY";
pub const license = "MIT";

pub const Entry = struct {
    /// Path relative to the portable payload root, which is the `noctty`
    /// directory inside the portable ZIP.
    payload_relative_path: []const u8,
    /// Key holding this file's pin inside an `architectures.<arch>` object.
    pin_key: []const u8,
    sha256: [Sha256.digest_length]u8,
};

/// The names `Install-ConPtyRedist` writes into the portable root, paired
/// with the pin object that holds each one's hash.
const staged_files = [_]struct {
    pin_key: []const u8,
    payload_relative_path: []const u8,
}{
    .{ .pin_key = "conptyDll", .payload_relative_path = "conpty.dll" },
    .{ .pin_key = "openConsoleExe", .payload_relative_path = "OpenConsole.exe" },
};

pub const x64: [staged_files.len]Entry = entriesFor("x64");
pub const arm64: [staged_files.len]Entry = entriesFor("arm64");

/// The pins for the architecture this build targets.
pub const entries: [staged_files.len]Entry = switch (builtin.cpu.arch) {
    .x86_64 => x64,
    .aarch64 => arm64,
    else => @compileError("unsupported Windows architecture for the bundled ConPTY pin"),
};

/// The pin for a payload-relative path, or null when the path is not one of
/// the bundled Microsoft files. Matching is exact: a differently cased name
/// falls through to the publisher-pinned path and fails closed there.
pub fn find(payload_relative_path: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.payload_relative_path, payload_relative_path)) {
            return entry;
        }
    }
    return null;
}

fn entriesFor(comptime arch: []const u8) [staged_files.len]Entry {
    comptime {
        // Scanning a ~1 KB document byte by byte costs far more than the
        // default budget.
        @setEvalBranchQuota(100_000);
        const root = skipWs(document, 0);
        // The same three guards Install-ConPtyRedist applies before it will
        // stage anything out of this document.
        if (!std.mem.eql(
            u8,
            rawAt(document, objectField(document, root, "schemaVersion")),
            schema_version,
        )) {
            @compileError("conpty-redist.json: unsupported schemaVersion");
        }
        if (!std.mem.eql(
            u8,
            stringAt(document, objectField(document, root, "packageId")),
            package_id,
        )) {
            @compileError("conpty-redist.json: unexpected packageId");
        }
        if (!std.mem.eql(
            u8,
            stringAt(document, objectField(document, root, "license")),
            license,
        )) {
            @compileError("conpty-redist.json: unexpected license");
        }

        const architectures = objectField(document, root, "architectures");
        const architecture = objectField(document, architectures, arch);

        var result: [staged_files.len]Entry = undefined;
        for (staged_files, 0..) |staged, index| {
            const pin = objectField(document, architecture, staged.pin_key);
            const entry_path = stringAt(document, objectField(document, pin, "entryPath"));
            // Install-ConPtyRedist writes each nupkg entry under its own base
            // name; asserting that here keeps the staged name and the pinned
            // hash describing the same file.
            if (!std.mem.eql(
                u8,
                std.fs.path.basenamePosix(entry_path),
                staged.payload_relative_path,
            )) {
                @compileError("conpty-redist.json: " ++ staged.pin_key ++
                    " entryPath does not end in " ++ staged.payload_relative_path);
            }
            result[index] = .{
                .payload_relative_path = staged.payload_relative_path,
                .pin_key = staged.pin_key,
                .sha256 = sha256At(document, objectField(document, pin, "sha256")),
            };
        }
        return result;
    }
}

// A JSON reader small enough to run at comptime. It rejects everything the
// pin document does not need, escapes in particular, instead of guessing.

fn skipWs(comptime src: []const u8, comptime start: usize) usize {
    var i = start;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            ' ', '\t', '\r', '\n' => {},
            else => return i,
        }
    }
    @compileError("conpty-redist.json: unexpected end of document");
}

fn stringEnd(comptime src: []const u8, comptime start: usize) usize {
    if (src[start] != '"') @compileError("conpty-redist.json: expected a string");
    var i = start + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') @compileError("conpty-redist.json: string escapes are not supported");
        if (src[i] == '"') return i + 1;
    }
    @compileError("conpty-redist.json: unterminated string");
}

fn valueEnd(comptime src: []const u8, comptime start: usize) usize {
    switch (src[start]) {
        '"' => return stringEnd(src, start),
        '{', '[' => {
            var depth: usize = 0;
            var i = start;
            while (i < src.len) {
                switch (src[i]) {
                    '"' => {
                        i = stringEnd(src, i);
                        continue;
                    },
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
                i += 1;
            }
            @compileError("conpty-redist.json: unterminated object or array");
        },
        else => {
            var i = start;
            while (i < src.len) : (i += 1) {
                switch (src[i]) {
                    ',', '}', ']', ' ', '\t', '\r', '\n' => return i,
                    else => {},
                }
            }
            @compileError("conpty-redist.json: unterminated value");
        },
    }
}

/// Offset of the value stored under `key` in the object starting at
/// `object_start`. A missing key is a compile error, never a default.
fn objectField(
    comptime src: []const u8,
    comptime object_start: usize,
    comptime key: []const u8,
) usize {
    const brace = skipWs(src, object_start);
    if (src[brace] != '{') {
        @compileError("conpty-redist.json: expected an object holding \"" ++ key ++ "\"");
    }
    var i = skipWs(src, brace + 1);
    while (src[i] != '}') {
        const name_end = stringEnd(src, i);
        const name = src[i + 1 .. name_end - 1];
        const colon = skipWs(src, name_end);
        if (src[colon] != ':') @compileError("conpty-redist.json: expected ':' after a key");
        const value_start = skipWs(src, colon + 1);
        if (std.mem.eql(u8, name, key)) return value_start;
        i = skipWs(src, valueEnd(src, value_start));
        if (src[i] == ',') i = skipWs(src, i + 1);
    }
    @compileError("conpty-redist.json: missing key \"" ++ key ++ "\"");
}

fn stringAt(comptime src: []const u8, comptime start: usize) []const u8 {
    return src[start + 1 .. stringEnd(src, start) - 1];
}

fn rawAt(comptime src: []const u8, comptime start: usize) []const u8 {
    return src[start..valueEnd(src, start)];
}

fn sha256At(comptime src: []const u8, comptime start: usize) [Sha256.digest_length]u8 {
    const text = stringAt(src, start);
    if (text.len != Sha256.digest_length * 2) {
        @compileError("conpty-redist.json: a pinned sha256 is not 64 hex digits");
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    for (&digest, 0..) |*byte, index| {
        byte.* = (hexNibble(text[index * 2]) << 4) | hexNibble(text[index * 2 + 1]);
    }
    return digest;
}

fn hexNibble(comptime character: u8) u8 {
    return switch (character) {
        '0'...'9' => character - '0',
        // The packaging scripts compare lowercase hex, so an uppercase digit
        // means the document and the scripts disagree.
        'a'...'f' => character - 'a' + 10,
        else => @compileError("conpty-redist.json: a pinned sha256 is not lowercase hex"),
    };
}

test "conpty pins cover exactly the staged pair for every architecture" {
    try std.testing.expectEqual(@as(usize, 2), staged_files.len);
    inline for (.{ x64, arm64 }) |architecture| {
        try std.testing.expectEqual(staged_files.len, architecture.len);
        try std.testing.expectEqualStrings("conpty.dll", architecture[0].payload_relative_path);
        try std.testing.expectEqualStrings("OpenConsole.exe", architecture[1].payload_relative_path);
    }
    // The two architectures pin different bytes; a copy-paste in the document
    // would otherwise go unnoticed.
    try std.testing.expect(!std.mem.eql(u8, &x64[0].sha256, &arm64[0].sha256));
    try std.testing.expect(!std.mem.eql(u8, &x64[1].sha256, &arm64[1].sha256));
}

test "conpty pins equal dist/windows/conpty-redist.json" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, document, .{});
    defer parsed.deinit();

    const architectures = parsed.value.object.get("architectures").?.object;
    try std.testing.expectEqual(@as(usize, 2), architectures.count());
    inline for (.{ .{ "x64", x64 }, .{ "arm64", arm64 } }) |pair| {
        const pinned = architectures.get(pair[0]).?.object;
        try std.testing.expectEqual(staged_files.len, pinned.count());
        for (pair[1]) |entry| {
            const hex = pinned.get(entry.pin_key).?.object.get("sha256").?.string;
            var expected: [Sha256.digest_length]u8 = undefined;
            _ = try std.fmt.hexToBytes(&expected, hex);
            try std.testing.expectEqualSlices(u8, &expected, &entry.sha256);
        }
    }
}

test "conpty pin lookup is exact" {
    try std.testing.expect(find("conpty.dll") != null);
    try std.testing.expect(find("OpenConsole.exe") != null);
    try std.testing.expect(find("noctty.exe") == null);
    try std.testing.expect(find("ghostty-vt.dll") == null);
    try std.testing.expect(find("share/conpty.dll") == null);
    try std.testing.expect(find("CONPTY.DLL") == null);
}
