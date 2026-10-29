//! Putting data on the system clipboard, with every format made ready before
//! the clipboard is emptied, so a failure to allocate or lock memory leaves
//! what is already there. A `SetClipboardData` failure after the empty still
//! loses it; see `write`.
//!
//! `EmptyClipboard` is the point of no return: from there the previous
//! contents are gone, and a copy that then fails to allocate or lock its
//! memory has wiped the user's clipboard and copied nothing. So every format
//! is made ready first, in global memory of its own, and only then is the
//! clipboard opened, emptied and handed the memory. `write` is that order for
//! the terminal's copy (text and HTML) and for Settings' "Copy name".
//!
//! Every native call goes through `Ops`, so a test can fail each one without
//! touching the real clipboard (it belongs to the window station, and a test
//! that writes it overwrites the user's).
const std = @import("std");
const c = @import("consts.zig");
const sys = @import("sys.zig");
const types = @import("../win32_types.zig");
const win32 = @import("../win32.zig");

const BOOL = types.BOOL;
const HWND = types.HWND;
const UINT = types.UINT;

/// The most formats one write carries (CF_HTML and CF_UNICODETEXT).
const max_formats = 2;

/// The native calls `write` makes.
pub const Ops = struct {
    globalAlloc: *const fn (UINT, usize) callconv(.winapi) ?*anyopaque = sys.GlobalAlloc,
    globalLock: *const fn (?*anyopaque) callconv(.winapi) ?*anyopaque = sys.GlobalLock,
    globalUnlock: *const fn (?*anyopaque) callconv(.winapi) BOOL = sys.GlobalUnlock,
    globalFree: *const fn (?*anyopaque) callconv(.winapi) ?*anyopaque = sys.GlobalFree,
    open: *const fn (?HWND) bool = win32.openClipboard,
    empty: *const fn () callconv(.winapi) BOOL = sys.EmptyClipboard,
    setData: *const fn (UINT, ?*anyopaque) callconv(.winapi) ?*anyopaque = sys.SetClipboardData,
    close: *const fn () callconv(.winapi) BOOL = sys.CloseClipboard,
};

/// One clipboard format and the bytes it carries.
pub const Format = struct {
    id: UINT,
    /// The payload, without its terminating NUL.
    data: []const u8,
    /// How many bytes of NUL end the payload in memory: 2 for UTF-16 text, 1
    /// for CF_HTML.
    nul_bytes: usize,
};

/// `text_w` (without its terminator, which `write` adds) as CF_UNICODETEXT.
pub fn unicodeText(text_w: []const u16) Format {
    return .{
        .id = c.CF_UNICODETEXT,
        .data = std.mem.sliceAsBytes(text_w),
        .nul_bytes = @sizeOf(u16),
    };
}

pub const Error = error{
    /// Global memory for a format could not be allocated or locked. Not
    /// `OutOfMemory`, so a caller can tell it from its own allocator failing.
    GlobalMemoryUnavailable,
    /// The clipboard would not open, empty or take a format.
    ClipboardUnavailable,
};

/// Replace the clipboard with `formats`. A failure to allocate or lock any
/// format's memory returns before the clipboard is opened, so what it held is
/// untouched. Once it is emptied, a format `SetClipboardData` refuses leaves
/// the formats before it on the clipboard and the old contents gone: no order
/// avoids that, because only an emptied clipboard takes a new owner's data.
/// Memory the clipboard did not take is freed.
pub fn write(ops: Ops, owner: ?HWND, formats: []const Format) Error!void {
    std.debug.assert(formats.len <= max_formats);

    // Ours, and freed, until `SetClipboardData` takes it.
    var mems: [max_formats]?*anyopaque = @splat(null);
    defer for (mems[0..formats.len]) |mem| {
        if (mem) |m| _ = ops.globalFree(m);
    };

    for (formats, mems[0..formats.len]) |format, *mem| mem.* = try prepare(ops, format);

    if (!ops.open(owner)) return error.ClipboardUnavailable;
    defer _ = ops.close();
    if (ops.empty() == 0) return error.ClipboardUnavailable;
    for (formats, mems[0..formats.len]) |format, *mem| {
        if (ops.setData(format.id, mem.*) == null) return error.ClipboardUnavailable;
        // The clipboard owns the memory now.
        mem.* = null;
    }
}

/// `format`'s payload in movable global memory, unlocked. The caller frees it
/// unless `SetClipboardData` takes it.
fn prepare(ops: Ops, format: Format) Error!*anyopaque {
    // GMEM_MOVEABLE is what `SetClipboardData` takes; GMEM_ZEROINIT is what
    // the terminal's writers always asked for.
    const mem = ops.globalAlloc(
        c.GMEM_MOVEABLE | c.GMEM_ZEROINIT,
        format.data.len + format.nul_bytes,
    ) orelse return error.GlobalMemoryUnavailable;
    errdefer _ = ops.globalFree(mem);
    const locked: [*]u8 = @ptrCast(ops.globalLock(mem) orelse return error.GlobalMemoryUnavailable);
    @memcpy(locked[0..format.data.len], format.data);
    @memset(locked[format.data.len..][0..format.nul_bytes], 0);
    // Unlocked before the clipboard sees it: a locked block does not belong to
    // `SetClipboardData`.
    _ = ops.globalUnlock(mem);
    return mem;
}

/// Native-call stand-ins for tests, in place of the real clipboard and global
/// memory. State is static, as the `Ops` functions carry no context; tests in
/// one binary run one at a time and `reset` first.
pub const Fake = struct {
    pub const Step = enum { alloc, lock, unlock, free, open, empty, set_data, close };
    pub const Fail = enum { none, alloc, lock, open, empty, set_data };

    const block_capacity = 1024;
    const max_blocks = 4;
    const Owner = enum { unused, caller, clipboard, freed };
    const Block = struct {
        bytes: [block_capacity]u8 align(8) = undefined,
        size: usize = 0,
        format: UINT = 0,
        locked: bool = false,
        owner: Owner = .unused,
    };

    var fail: Fail = .none;
    var fail_on: usize = 0;
    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var blocks: [max_blocks]Block = undefined;
    var block_count: usize = 0;
    var opened = false;
    var emptied = false;
    var opened_for: ?HWND = null;

    pub const ops: Ops = .{
        .globalAlloc = globalAlloc,
        .globalLock = globalLock,
        .globalUnlock = globalUnlock,
        .globalFree = globalFree,
        .open = open,
        .empty = empty,
        .setData = setData,
        .close = close,
    };

    /// Start a fresh run in which the `nth` (0-based) call of the kind `how`
    /// names fails.
    pub fn reset(how: Fail, nth: usize) void {
        fail = how;
        fail_on = nth;
        step_count = 0;
        block_count = 0;
        opened = false;
        emptied = false;
        opened_for = null;
        for (&blocks) |*block| block.* = .{};
    }

    /// The calls made so far, in order.
    pub fn recorded() []const Step {
        return steps[0..step_count];
    }

    pub fn did(step: Step) bool {
        return std.mem.indexOfScalar(Step, recorded(), step) != null;
    }

    /// Memory the code under test allocated and neither freed nor gave to the
    /// clipboard.
    pub fn leaked() usize {
        return countOwned(.caller);
    }

    /// Memory the clipboard took.
    pub fn taken() usize {
        return countOwned(.clipboard);
    }

    pub fn freed() usize {
        return countOwned(.freed);
    }

    /// The owner window the clipboard was opened for.
    pub fn openedFor() ?HWND {
        return opened_for;
    }

    /// The `index`th block allocated, as the code under test filled it.
    pub fn payload(index: usize) []const u8 {
        return blocks[index].bytes[0..blocks[index].size];
    }

    /// The clipboard format block `index` was handed to the clipboard as.
    pub fn formatOf(index: usize) UINT {
        return blocks[index].format;
    }

    fn countOwned(owner: Owner) usize {
        var n: usize = 0;
        for (blocks[0..block_count]) |block| {
            if (block.owner == owner) n += 1;
        }
        return n;
    }

    fn note(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    /// Whether the call just noted is the one the run fails.
    fn failsNow(kind: Fail, step: Step) bool {
        if (fail != kind) return false;
        return std.mem.count(Step, recorded(), &.{step}) == fail_on + 1;
    }

    fn handleOf(index: usize) *anyopaque {
        return @ptrFromInt(0x1000 + index);
    }

    fn blockOf(mem: ?*anyopaque) *Block {
        const index = @intFromPtr(mem.?) - 0x1000;
        std.debug.assert(index < block_count);
        return &blocks[index];
    }

    fn globalAlloc(flags: UINT, size: usize) callconv(.winapi) ?*anyopaque {
        note(.alloc);
        // `SetClipboardData` takes movable memory only.
        std.debug.assert(flags & c.GMEM_MOVEABLE != 0);
        std.debug.assert(size <= block_capacity);
        if (failsNow(.alloc, .alloc)) return null;
        const index = block_count;
        block_count += 1;
        blocks[index] = .{ .size = size, .owner = .caller };
        // Not zeroed, so a missing terminator shows.
        @memset(&blocks[index].bytes, 0xAA);
        return handleOf(index);
    }

    fn globalLock(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque {
        note(.lock);
        const block = blockOf(mem);
        std.debug.assert(block.owner == .caller);
        if (failsNow(.lock, .lock)) return null;
        block.locked = true;
        return &block.bytes;
    }

    fn globalUnlock(mem: ?*anyopaque) callconv(.winapi) BOOL {
        note(.unlock);
        blockOf(mem).locked = false;
        return 0;
    }

    fn globalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque {
        note(.free);
        const block = blockOf(mem);
        // Freeing what the clipboard owns, or freeing twice, is the bug.
        std.debug.assert(block.owner == .caller);
        block.owner = .freed;
        return null;
    }

    fn open(owner: ?HWND) bool {
        note(.open);
        std.debug.assert(!opened);
        if (failsNow(.open, .open)) return false;
        opened = true;
        opened_for = owner;
        return true;
    }

    fn empty() callconv(.winapi) BOOL {
        note(.empty);
        std.debug.assert(opened);
        if (failsNow(.empty, .empty)) return 0;
        emptied = true;
        return 1;
    }

    fn setData(format: UINT, mem: ?*anyopaque) callconv(.winapi) ?*anyopaque {
        note(.set_data);
        std.debug.assert(opened and emptied);
        const block = blockOf(mem);
        std.debug.assert(block.owner == .caller);
        // A block must be unlocked when it is handed over.
        std.debug.assert(!block.locked);
        if (failsNow(.set_data, .set_data)) return null;
        block.owner = .clipboard;
        block.format = format;
        return mem;
    }

    fn close() callconv(.winapi) BOOL {
        note(.close);
        // Only a clipboard that was opened is closed, and once.
        std.debug.assert(opened);
        opened = false;
        return 1;
    }
};

const cf_test_html: UINT = 0xC0A0;
const test_text = std.unicode.utf8ToUtf16LeStringLiteral("copy");
/// CF_HTML first, then CF_UNICODETEXT, as the terminal's HTML copy writes them.
const test_formats = [_]Format{
    .{ .id = cf_test_html, .data = "<b>copy</b>", .nul_bytes = 1 },
    unicodeText(test_text),
};

test "win32 clipboard write makes every format ready before it opens the clipboard" {
    // A format whose memory cannot be had or locked, the first or the
    // second: the clipboard is never opened, let alone emptied, and what was
    // allocated is freed.
    for ([_]Fake.Fail{ .alloc, .lock }) |how| {
        for (0..test_formats.len) |nth| {
            Fake.reset(how, nth);
            try std.testing.expectError(error.GlobalMemoryUnavailable, write(Fake.ops, null, &test_formats));
            try std.testing.expect(!Fake.did(.open) and !Fake.did(.empty) and !Fake.did(.set_data) and !Fake.did(.close));
            try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
            try std.testing.expectEqual(@as(usize, 0), Fake.taken());
        }
    }
}

test "win32 clipboard write frees what the clipboard did not take" {
    // A clipboard that will not open or empty: all of ours is freed, and the
    // clipboard is closed only once it was opened.
    Fake.reset(.open, 0);
    try std.testing.expectError(error.ClipboardUnavailable, write(Fake.ops, null, &test_formats));
    try std.testing.expect(!Fake.did(.empty) and !Fake.did(.close));
    try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
    try std.testing.expectEqual(@as(usize, 2), Fake.freed());

    Fake.reset(.empty, 0);
    try std.testing.expectError(error.ClipboardUnavailable, write(Fake.ops, null, &test_formats));
    try std.testing.expect(!Fake.did(.set_data) and Fake.did(.close));
    try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
    try std.testing.expectEqual(@as(usize, 2), Fake.freed());

    // The first format refused: nothing was taken, both are freed.
    Fake.reset(.set_data, 0);
    try std.testing.expectError(error.ClipboardUnavailable, write(Fake.ops, null, &test_formats));
    try std.testing.expect(Fake.did(.close));
    try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
    try std.testing.expectEqual(@as(usize, 0), Fake.taken());
    try std.testing.expectEqual(@as(usize, 2), Fake.freed());

    // The second refused after the first was taken. The clipboard was already
    // emptied, so it now holds the first format alone and the old contents are
    // gone: no order avoids that. The memory the clipboard did not take is
    // freed, and the one it took is not.
    Fake.reset(.set_data, 1);
    try std.testing.expectError(error.ClipboardUnavailable, write(Fake.ops, null, &test_formats));
    try std.testing.expect(Fake.did(.close));
    try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
    try std.testing.expectEqual(@as(usize, 1), Fake.taken());
    try std.testing.expectEqual(@as(usize, 1), Fake.freed());
    try std.testing.expectEqual(cf_test_html, Fake.formatOf(0));
}

test "win32 clipboard write runs alloc lock unlock for each format, then open empty set close" {
    const owner: HWND = @ptrFromInt(0x2000);
    Fake.reset(.none, 0);
    try write(Fake.ops, owner, &test_formats);
    try std.testing.expectEqual(@as(?HWND, owner), Fake.openedFor());
    try std.testing.expectEqualSlices(Fake.Step, &.{
        .alloc,    .lock,  .unlock,
        .alloc,    .lock,  .unlock,
        .open,     .empty, .set_data,
        .set_data, .close,
    }, Fake.recorded());
    // The clipboard keeps both blocks, and nothing is freed.
    try std.testing.expectEqual(@as(usize, 2), Fake.taken());
    try std.testing.expectEqual(@as(usize, 0), Fake.leaked() + Fake.freed());
    try std.testing.expectEqual(cf_test_html, Fake.formatOf(0));
    try std.testing.expectEqual(@as(UINT, c.CF_UNICODETEXT), Fake.formatOf(1));
    // Each payload ends in its terminator, whatever the allocator left there.
    try std.testing.expectEqualSlices(u8, "<b>copy</b>\x00", Fake.payload(0));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(test_text[0 .. test_text.len + 1]), Fake.payload(1));
}
