const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;

const fastmem = @import("../../fastmem.zig");
const command = @import("graphics_command.zig");
const PageList = @import("../PageList.zig");
const wuffs = @import("wuffs");
const LimitedAllocator = @import("../../datastruct/main.zig").LimitedAllocator;

const isNetworkOrDevicePath = @import("../../os/path.zig").isNetworkOrDevicePath;

const temp_dir = struct {
    const TempDir = @import("../../os/TempDir.zig");
    const allocTmpDir = @import("../../os/file.zig").allocTmpDir;
    const freeTmpDir = @import("../../os/file.zig").freeTmpDir;
};

const log = std.log.scoped(.kitty_gfx);

/// Maximum width or height of an image. Taken directly from Kitty.
const max_dimension = 10000;

/// Maximum size in bytes, taken from Kitty.
const max_size = 400 * 1024 * 1024; // 400MB

/// Maximum length in bytes of a file medium path. Zig 0.15.2 converts a
/// Windows path into a fixed buffer of PATH_MAX_WIDE WTF-16 units without
/// checking that it fits (`sliceToPrefixedFileW`), and a WTF-8 byte is at
/// most one unit, so a path no longer than this always fits.
const max_path_len = if (builtin.os.tag == .windows)
    std.os.windows.PATH_MAX_WIDE
else
    std.fs.max_path_bytes - 1;

/// An image that is still being loaded. The image should be initialized
/// using init on the first chunk and then addData for each subsequent
/// chunk. Once all chunks have been added, complete should be called
/// to finalize the image.
pub const LoadingImage = struct {
    /// The in-progress image. The first chunk must have all the metadata
    /// so this comes from that initially.
    image: Image,

    /// The data that is being built up.
    data: std.ArrayListUnmanaged(u8) = .{},

    /// This is non-null when a transmit and display command is given
    /// so that we display the image after it is fully loaded.
    display: ?command.Display = null,

    /// Quiet is the quiet settings for the initial load command. This is
    /// used if q isn't set on subsequent chunks.
    quiet: command.Command.Quiet,

    /// Response identifiers from the initial load command. Subsequent chunks
    /// omit these, so completion responses must use the saved values.
    response: command.Response = .{},

    /// Initialize a chunked immage from the first image transmission.
    /// If this is a multi-chunk image, this should only be the FIRST
    /// chunk.
    pub fn init(alloc: Allocator, cmd: *const command.Command) !LoadingImage {
        // Build our initial image from the properties sent via the control.
        // These can be overwritten by the data loading process. For example,
        // PNG loading sets the width/height from the data.
        const t = cmd.transmission().?;

        // Validated here rather than while parsing so the response can
        // carry the image id, matching Kitty's initialize_load_data.
        if (t.format_unknown) return error.UnsupportedFormat;
        var result: LoadingImage = .{
            .image = .{
                .id = t.image_id,
                .number = t.image_number,
                .width = t.width,
                .height = t.height,
                .compression = t.compression,
                .format = t.format,
                .usage = t.usage,
            },

            .display = cmd.display(),
            .quiet = cmd.quiet,
            .response = .{
                .id = t.image_id,
                .image_number = t.image_number,
                .placement_id = t.placement_id,
            },
        };

        // Special case for the direct medium, we just add the chunk directly.
        if (t.medium == .direct) {
            try result.addData(alloc, cmd.data);
            return result;
        }

        // Otherwise, the payload data is guaranteed to be a path.

        if (cmd.data.len > max_path_len) return error.FilePathTooLong;

        if (comptime builtin.os.tag != .windows) {
            if (std.mem.indexOfScalar(u8, cmd.data, 0) != null) {
                // POSIX paths cannot contain internal nulls.
                log.warn("invalid image path: BadPathName", .{});
                return error.InvalidData;
            }
        }

        // On Windows opening a network share or device path
        // (`\\server\share`, `\\?\UNC\...`, `\\.\pipe\x`) contacts it, so
        // refuse those shapes before the open. A program inside the
        // terminal supplies this path.
        if (comptime builtin.os.tag == .windows) {
            if (isNetworkOrDevicePath(cmd.data)) {
                log.warn("refusing network or device path for image file", .{});
                return error.InvalidData;
            }
        }

        // Depending on the medium, load the data from the path.
        switch (t.medium) {
            .direct => unreachable, // handled above
            .file => try result.readFile(.file, alloc, t, cmd.data),
            .temporary_file => try result.readFile(.temporary_file, alloc, t, cmd.data),
            .shared_memory => try result.readSharedMemory(alloc, t, cmd.data),
        }

        return result;
    }

    /// Reads the data from a shared memory segment.
    fn readSharedMemory(
        self: *LoadingImage,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        // windows is currently unsupported, does it support shm?
        if (comptime builtin.target.os.tag == .windows) {
            return error.UnsupportedMedium;
        }

        // libc is required for shm_open
        if (comptime !builtin.link_libc) {
            return error.UnsupportedMedium;
        }

        // Since we're only supporting posix then max_path_bytes should
        // be enough to stack allocate the path.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const pathz = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.InvalidData;

        const fd = std.c.shm_open(pathz, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), 0);
        switch (std.posix.errno(fd)) {
            .SUCCESS => {},
            else => |err| {
                log.warn("unable to open shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            },
        }
        defer _ = std.c.close(fd);
        defer _ = std.c.shm_unlink(pathz);

        // The size from stat on may be larger than our expected size because
        // shared memory has to be a multiple of the page size.
        const stat_size: usize = stat: {
            const stat = std.posix.fstat(fd) catch |err| {
                log.warn("unable to fstat shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            };
            if (stat.size <= 0) return error.InvalidData;
            break :stat @intCast(stat.size);
        };

        const expected_size: usize = switch (self.image.format) {
            // Png we decode the full data size because later decoding will
            // get the proper dimensions and assert validity.
            .png => stat_size,

            // For these formats we have a size we must have.
            .gray, .gray_alpha, .rgb, .rgba => |f| size: {
                const bpp = f.bpp();
                break :size self.image.width * self.image.height * bpp;
            },
        };

        // Our stat size must be at least the expected size otherwise
        // the shared memory data is invalid.
        if (stat_size < expected_size) {
            log.warn(
                "shared memory size too small expected={} actual={}",
                .{ expected_size, stat_size },
            );
            return error.InvalidData;
        }

        const map = std.posix.mmap(
            null,
            stat_size, // mmap always uses the stat size
            std.c.PROT.READ,
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.warn("unable to mmap shared memory {s}: {}", .{ path, err });
            return error.InvalidData;
        };
        defer std.posix.munmap(map);

        // Our end size always uses the expected size so we cut off the
        // padding for mmap alignment.
        const start: usize = @intCast(t.offset);
        const end: usize = if (t.size > 0) @min(
            @as(usize, @intCast(t.offset)) + @as(usize, @intCast(t.size)),
            expected_size,
        ) else expected_size;

        assert(self.data.items.len == 0);
        try self.data.appendSlice(alloc, map[start..end]);
    }

    /// Reads the data from a temporary file and returns it. This allocates
    /// and does not free any of the data, so the caller must free it.
    ///
    /// This will also delete the temporary file if it is in a safe location.
    fn readFile(
        self: *LoadingImage,
        comptime medium: command.Transmission.Medium,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        switch (medium) {
            .file, .temporary_file => {},
            else => @compileError("readFile only supports file and temporary_file"),
        }

        // Open our file right away before we do validation. This avoids
        // TOCTOU issues.
        var file = std.fs.cwd().openFile(path, .{}) catch |err| {
            log.warn("failed to open image file: {}", .{err});
            return error.InvalidData;
        };

        // We'll populate a delete path if this is a temporary file.
        var delete_path: ?[]const u8 = null;
        defer {
            file.close();
            if (delete_path) |p| {
                std.fs.cwd().deleteFile(p) catch |err| {
                    log.warn("failed to delete temporary file: {}", .{err});
                };
            }
        }

        // Derive the path from the open handle so the file we validate is the
        // exact file we read. Resolving a path before opening it would allow a
        // cooperating process to swap a symlink or directory entry in between.
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = validatedFilePath(file, &abs_buf) catch |err| {
            log.warn("failed to validate image file path: {}", .{err});
            return error.InvalidData;
        };

        // Temporary file logic
        if (medium == .temporary_file) {
            if (!isPathInTempDir(abs_path)) return error.TemporaryFileNotInTempDir;
            if (std.mem.indexOf(
                u8,
                abs_path,
                "tty-graphics-protocol",
            ) == null) return error.TemporaryFileNotNamedCorrectly;
            delete_path = abs_path;
        }

        // File must be a regular file
        if (file.stat()) |stat| {
            if (stat.kind != .file) {
                log.warn("file is not a regular file kind={}", .{stat.kind});
                return error.InvalidData;
            }
        } else |err| {
            log.warn("failed to stat file: {}", .{err});
            return error.InvalidData;
        }

        // The reader reads at its own position, not the file's, so seek it.
        var buf: [4096]u8 = undefined;
        var buf_reader = file.reader(&buf);
        if (t.offset > 0) {
            buf_reader.seekTo(t.offset) catch |err| {
                log.warn("failed to seek to offset {}: {}", .{ t.offset, err });
                return error.InvalidData;
            };
        }
        const reader = &buf_reader.interface;

        // Read the file
        var managed: std.ArrayList(u8) = .empty;
        errdefer managed.deinit(alloc);
        if (t.size > 0) {
            // S is the exact number of bytes to read, not a maximum:
            // https://sw.kovidgoyal.net/kitty/graphics-protocol/#local-client
            const size = std.math.cast(usize, t.size) orelse
                return error.InvalidData;
            if (size > max_size) return error.InvalidData;

            // Read exact size
            const data = reader.readAlloc(alloc, size) catch |err| {
                log.warn("failed to read image file: {}", .{err});
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidData,
                };
            };
            managed = .{ .items = data, .capacity = data.len };
        } else {
            reader.appendRemaining(alloc, &managed, .limited(max_size)) catch {
                log.warn("failed to read image file: {?}", .{buf_reader.err});
                return error.InvalidData;
            };
        }

        // Set our data
        assert(self.data.items.len == 0);
        self.data = .{ .items = managed.items, .capacity = managed.capacity };
    }

    /// Returns the canonical path of an open file after applying the file
    /// transmission blocklist.
    fn validatedFilePath(file: std.fs.File, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
        const path = try std.os.getFdPath(file.handle, buf);

        // This is logic copied directly from Kitty, mostly. This is really
        // rough but it will catch obvious bad actors.
        if (std.mem.startsWith(u8, path, "/proc/") or
            std.mem.startsWith(u8, path, "/sys/") or
            (std.mem.startsWith(u8, path, "/dev/") and
                !std.mem.startsWith(u8, path, "/dev/shm/")))
        {
            return error.InvalidData;
        }

        return path;
    }

    /// Returns true if path appears to be in a temporary directory.
    /// Copies logic from Kitty.
    fn isPathInTempDir(path: []const u8) bool {
        if (isPathInDir("/tmp", path)) return true;
        if (isPathInDir("/dev/shm", path)) return true;
        const dir = temp_dir.allocTmpDir(std.heap.page_allocator) catch return false;
        defer temp_dir.freeTmpDir(std.heap.page_allocator, dir);
        if (isPathInDir(dir, path)) return true;

        // The temporary dir is sometimes a symlink. On macOS for
        // example /tmp is /private/var/...
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (posix.realpath(dir, &buf)) |real_dir| {
            if (isPathInDir(real_dir, path)) return true;
        } else |_| {}

        return false;
    }

    pub fn deinit(self: *LoadingImage, alloc: Allocator) void {
        self.image.deinit(alloc);
        self.data.deinit(alloc);
    }

    pub fn destroy(self: *LoadingImage, alloc: Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }

    /// Adds a chunk of data to the image. Use this if the image
    /// is coming in chunks (the "m" parameter in the protocol).
    pub fn addData(self: *LoadingImage, alloc: Allocator, data: []const u8) !void {
        // If no data, skip
        if (data.len == 0) return;

        // If our data would get too big, return an error
        if (self.data.items.len + data.len > max_size) {
            log.warn("image data too large max_size={}", .{max_size});
            return error.InvalidData;
        }

        // Ensure we have enough room to add the data
        // to the end of the ArrayList before doing so.
        try self.data.ensureUnusedCapacity(alloc, data.len);

        const start_i = self.data.items.len;
        self.data.items.len = start_i + data.len;
        fastmem.copy(u8, self.data.items[start_i..], data);
    }

    /// Complete the chunked image, returning a completed image.
    pub fn complete(self: *LoadingImage, alloc: Allocator) !Image {
        const img = &self.image;

        // Decompress the data if it is compressed.
        try self.decompress(alloc);

        // Decode the png if we have to
        if (img.format == .png) try self.decodePng(alloc);

        // Validate our dimensions.
        if (img.width == 0 or img.height == 0) return error.DimensionsRequired;
        if (img.width > max_dimension or img.height > max_dimension) return error.DimensionsTooLarge;

        // Data length must be what we expect
        const bpp = img.format.bpp();
        const expected_len = img.width * img.height * bpp;
        const actual_len = self.data.items.len;
        if (actual_len != expected_len) {
            std.log.warn(
                "unexpected length image id={} width={} height={} bpp={} expected_len={} actual_len={}",
                .{ img.id, img.width, img.height, bpp, expected_len, actual_len },
            );
            return error.InvalidData;
        }

        // Set our time
        self.image.transmit_time = std.time.Instant.now() catch |err| {
            log.warn("failed to get time: {}", .{err});
            return error.InternalError;
        };

        // Everything looks good, copy the image data over.
        var result = self.image;
        result.data = try self.data.toOwnedSlice(alloc);
        errdefer result.deinit(alloc);
        self.image = .{};
        return result;
    }

    /// Debug function to write the data to a file. This is useful for
    /// capturing some test data for unit tests.
    pub fn debugDump(self: LoadingImage) !void {
        if (comptime builtin.mode != .Debug) @compileError("debugDump in non-debug");

        var buf: [1024]u8 = undefined;
        const filename = try std.fmt.bufPrint(
            &buf,
            "image-{s}-{s}-{d}x{d}-{}.data",
            .{
                @tagName(self.image.format),
                @tagName(self.image.compression),
                self.image.width,
                self.image.height,
                self.image.id,
            },
        );
        const cwd = std.fs.cwd();
        const f = try cwd.createFile(filename, .{});
        defer f.close();

        const writer = f.writer();
        try writer.writeAll(self.data.items);
    }

    /// Decompress the data in-place.
    fn decompress(self: *LoadingImage, alloc: Allocator) !void {
        return switch (self.image.compression) {
            .none => {},
            .zlib_deflate => self.decompressZlib(alloc),
        };
    }

    fn decompressZlib(self: *LoadingImage, alloc: Allocator) !void {
        // Use the WUFFS zlib decoder rather than std.compress.flate. Zig
        // 0.15.2's buffered Decompress writes a fixed-Huffman match without
        // checking the room left in its 64 KiB window, so a match that
        // crosses the window's end reaches `unreachable` (ziglang/zig#24963,
        // fixed on master after 0.15). ReleaseFast turns that into an access
        // violation on the io-reader thread (#570). WUFFS is already linked
        // for PNG and is memory safe.
        //
        // Raw formats know their decoded size, so the output is one
        // allocation of exactly that size when the stream is well formed.
        // Within max_dimension the product is at most max_size, so it cannot
        // overflow even a 32-bit usize.
        comptime std.debug.assert(max_dimension * max_dimension * 4 <= max_size);
        const img = &self.image;
        const size_hint: ?usize = if (img.format == .png or
            img.width == 0 or img.height == 0 or
            img.width > max_dimension or img.height > max_dimension)
            null
        else
            @as(usize, img.width) * img.height * img.format.bpp();
        const result = wuffs.zlib.decompress(
            alloc,
            self.data.items,
            max_size,
            size_hint,
        ) catch |err| {
            log.warn("failed to decompress image data err={}", .{err});
            return error.DecompressionFailed;
        };

        // Replace our compressed data with the decompressed data
        self.data.deinit(alloc);
        self.data = .{ .items = result, .capacity = result.len };

        // Make sure we note that our image is no longer compressed
        self.image.compression = .none;
    }

    /// Decode the data as PNG. This will also updated the image dimensions.
    fn decodePng(self: *LoadingImage, alloc: Allocator) !void {
        assert(self.image.format == .png);

        var limited: LimitedAllocator = .init(alloc, max_size);
        const decode_alloc = limited.allocator();
        const result = wuffs.png.decode(
            decode_alloc,
            self.data.items,
        ) catch |err| switch (err) {
            error.WuffsError => return error.InvalidData,
            error.OutOfMemory => if (limited.limit_exceeded)
                return error.InvalidData
            else
                return error.OutOfMemory,
            error.Overflow => return error.InvalidData,
        };
        defer decode_alloc.free(result.data);

        if (result.data.len > max_size) {
            log.warn("png image too large size={} max_size={}", .{ result.data.len, max_size });
            return error.InvalidData;
        }

        // Replace our data
        self.data.deinit(alloc);
        self.data = .{};
        try self.data.ensureUnusedCapacity(alloc, result.data.len);
        try self.data.appendSlice(alloc, result.data[0..result.data.len]);

        // Store updated image dimensions
        self.image.width = result.width;
        self.image.height = result.height;
        self.image.format = .rgba;
    }
};

/// Image represents a single fully loaded image.
pub const Image = struct {
    id: u32 = 0,
    number: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: command.Transmission.Format = .rgb,
    compression: command.Transmission.Compression = .none,
    data: []const u8 = "",
    usage: command.Transmission.Usage = .default,
    transmit_time: std.time.Instant = undefined,

    /// Set this to true if this image was loaded by a command that
    /// doesn't specify an ID or number, since such commands should
    /// not be responded to, even though we do currently give them
    /// IDs in the public range (which is bad!).
    implicit_id: bool = false,

    pub const Error = error{
        InternalError,
        InvalidData,
        DecompressionFailed,
        DimensionsRequired,
        DimensionsTooLarge,
        FilePathTooLong,
        TemporaryFileNotInTempDir,
        TemporaryFileNotNamedCorrectly,
        UnsupportedFormat,
        UnsupportedMedium,
        UnsupportedDepth,
    };

    pub fn deinit(self: *Image, alloc: Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
    }

    /// Mostly for logging
    pub fn withoutData(self: *const Image) Image {
        var copy = self.*;
        copy.data = "";
        return copy;
    }
};

/// The rect taken up by some image placement, in grid cells. This will
/// be rounded up to the nearest grid cell since we can't place images
/// in partial grid cells.
pub const Rect = struct {
    top_left: PageList.Pin,
    bottom_right: PageList.Pin,

    /// Returns true if the grid cell is inside this rectangle. Pin.isBetween
    /// compares page order, so its interior rows intentionally do not constrain
    /// x. Check the column independently and use isBetween only for the row.
    pub fn contains(self: Rect, cell: PageList.Pin) bool {
        if (cell.x < self.top_left.x or cell.x > self.bottom_right.x) return false;

        var row = cell;
        row.x = self.top_left.x;
        return row.isBetween(self.top_left, self.bottom_right);
    }
};

/// Returns true if `path` is `dir` or is contained within it, requiring a
/// path-separator boundary so similarly prefixed directories do not match.
fn isPathInDir(dir: []const u8, path: []const u8) bool {
    if (dir.len == 0 or !std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len or std.fs.path.isSep(dir[dir.len - 1])) return true;
    return std.fs.path.isSep(path[dir.len]);
}

test "temporary file path must be inside directory" {
    const testing = std.testing;

    try testing.expect(isPathInDir("/tmp", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("/tmp/", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("/tmp", "/tmp"));

    try testing.expect(!isPathInDir("", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/tmp", "/tmpX/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/dev/shm", "/dev/shm-evil/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/custom/tmp", "/custom/tmp-suffix/tty-graphics-protocol-image.data"));

    if (comptime builtin.os.tag != .windows) return;
    try testing.expect(isPathInDir("C:\\Temp", "C:\\Temp\\tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("C:\\Temp\\", "C:\\Temp\\tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("C:\\Temp", "C:\\Temp/tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("C:\\", "C:\\tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("C:\\Temp", "C:\\Temp2\\tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("C:\\Temp", "C:\\Templates\\tty-graphics-protocol-image.data"));
}

/// Points TMP, which GetTempPathW reads first, at `dir` until the returned
/// value's restore is called, so a test can name the temporary directory.
const TestTmpDir = struct {
    saved: ?[:0]u16,

    fn set(dir: []const u8) !TestTmpDir {
        const alloc = std.testing.allocator;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("TMP");

        // getenvW points into the environment block, which a change can move.
        const saved = if (std.process.getenvW(name)) |v| try alloc.dupeZ(u16, v) else null;
        errdefer if (saved) |v| alloc.free(v);
        const dir_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dir);
        defer alloc.free(dir_w);
        if (std.os.windows.kernel32.SetEnvironmentVariableW(name, dir_w) == 0) return error.Unexpected;
        return .{ .saved = saved };
    }

    fn restore(self: TestTmpDir) void {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("TMP");
        _ = std.os.windows.kernel32.SetEnvironmentVariableW(name, if (self.saved) |v| v.ptr else null);
        if (self.saved) |v| std.testing.allocator.free(v);
    }
};

/// For Windows tests: symbolic links as an account without the symlink
/// privilege can make them (Developer Mode).
const test_symlink = struct {
    extern "kernel32" fn CreateSymbolicLinkW(
        link: [*:0]const u16,
        target: [*:0]const u16,
        flags: u32,
    ) callconv(.winapi) u8;
    const SYMBOLIC_LINK_FLAG_DIRECTORY = 0x1;
    const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;

    /// A directory symlink at `link` (absolute) to `target`. False when the
    /// account may not make one.
    fn dir(alloc: Allocator, link: []const u8, target: []const u8) !bool {
        const link_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, link);
        defer alloc.free(link_w);
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, target);
        defer alloc.free(target_w);
        const flags = SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
        if (CreateSymbolicLinkW(link_w, target_w, flags) != 0) return true;
        return switch (std.os.windows.kernel32.GetLastError()) {
            .PRIVILEGE_NOT_HELD => false,
            else => error.Unexpected,
        };
    }
};

// This specifically tests we ALLOW invalid RGB data because Kitty
// documents that this should work.
test "image load with invalid RGB data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // <ESC>_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA<ESC>\
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
}

test "image load with image too wide" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = max_dimension + 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load with image too tall" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .height = max_dimension + 1,
            .width = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load: rgb, zlib compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, not compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data");

    // Setup our initial chunk
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
        .data = try alloc.dupe(u8, data[0..1024]),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs = std.io.fixedBufferStream(data[1024..]);
    var buf: [1024]u8 = undefined;
    while (fbs.reader().readAll(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;

    // Complete
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked with zero initial chunk" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data");

    // Setup our initial chunk
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs = std.io.fixedBufferStream(data);
    var buf: [1024]u8 = undefined;
    while (fbs.reader().readAll(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;

    // Complete
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

/// A 160x120 RGBA frame (76,800 bytes) compressed by zlib 1.3.1 with
/// `Z_FIXED`, so every block uses the fixed Huffman code. Its output crosses
/// the 64 KiB window that Zig 0.15.2's buffered flate decoder decodes into,
/// and that decoder reaches `unreachable` (an access violation in ReleaseFast)
/// when a fixed-block match straddles the window's end (#570).
const fixed_huffman_frame = @embedFile("testdata/image-rgba-zlib_deflate_fixed-160x120-raw.data");

/// The pixels of `fixed_huffman_frame`: opaque black bars on rows 0-19 and
/// 100-119, and a horizontal gradient on the rows between.
fn fixedHuffmanFramePixels(alloc: Allocator) ![]u8 {
    const pixels = try alloc.alloc(u8, 160 * 120 * 4);
    for (0..120) |y| for (0..160) |x| {
        const v: u8 = @intCast(x * 255 / 159);
        const px: [4]u8 = if (y < 20 or y >= 100) .{ 0, 0, 0, 255 } else .{ v, 64, 255 - v, 255 };
        @memcpy(pixels[(y * 160 + x) * 4 ..][0..4], &px);
    };
    return pixels;
}

/// Transmit `data` as a zlib-compressed RGBA image in `chunk_len`-byte chunks,
/// the way a `m=1` stream arrives, and complete it.
fn loadZlibRgba(alloc: Allocator, data: []const u8, width: u32, height: u32, chunk_len: usize) !Image {
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgba,
            .medium = .direct,
            .compression = .zlib_deflate,
            .width = width,
            .height = height,
            .image_id = 570,
            .more_chunks = true,
        } },
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var rest = data;
    while (rest.len > 0) {
        const n = @min(chunk_len, rest.len);
        try loading.addData(alloc, rest[0..n]);
        rest = rest[n..];
    }
    return loading.complete(alloc);
}

test "image load: rgba, zlib with fixed Huffman blocks past 64 KiB (#570)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const expected = try fixedHuffmanFramePixels(alloc);
    defer alloc.free(expected);

    // Whole, and chunked at an odd size so chunk edges fall mid-symbol.
    for ([_]usize{ fixed_huffman_frame.len, 37 }) |chunk_len| {
        var img = try loadZlibRgba(alloc, fixed_huffman_frame, 160, 120, chunk_len);
        defer img.deinit(alloc);
        try testing.expect(img.compression == .none);
        try testing.expectEqualSlices(u8, expected, img.data);
    }
}

test "image load: corrupt, truncated and mis-sized zlib data fail cleanly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Wrong Adler-32 trailer.
    const corrupt = try alloc.dupe(u8, fixed_huffman_frame);
    defer alloc.free(corrupt);
    corrupt[corrupt.len - 1] ^= 0x01;
    try testing.expectError(error.DecompressionFailed, loadZlibRgba(alloc, corrupt, 160, 120, 4096));

    // Cut off mid-stream, and cut off before the trailer.
    const half = fixed_huffman_frame[0 .. fixed_huffman_frame.len / 2];
    try testing.expectError(error.DecompressionFailed, loadZlibRgba(alloc, half, 160, 120, 4096));
    const no_trailer = fixed_huffman_frame[0 .. fixed_huffman_frame.len - 4];
    try testing.expectError(error.DecompressionFailed, loadZlibRgba(alloc, no_trailer, 160, 120, 4096));

    // Not zlib at all.
    try testing.expectError(error.DecompressionFailed, loadZlibRgba(alloc, "not zlib", 160, 120, 4096));

    // Declared smaller or larger than the stream decodes to: the size hint
    // is only a starting capacity, and the length check still rejects it.
    try testing.expectError(error.InvalidData, loadZlibRgba(alloc, fixed_huffman_frame, 160, 100, 4096));
    try testing.expectError(error.InvalidData, loadZlibRgba(alloc, fixed_huffman_frame, 160, 140, 4096));
}

test "wuffs zlib: output is capped at the limit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const exact = try wuffs.zlib.decompress(alloc, fixed_huffman_frame, 160 * 120 * 4, null);
    alloc.free(exact);
    try testing.expectError(
        error.Overflow,
        wuffs.zlib.decompress(alloc, fixed_huffman_frame, 160 * 120 * 4 - 1, null),
    );
    // A hint above the limit does not let the output past it.
    try testing.expectError(
        error.Overflow,
        wuffs.zlib.decompress(alloc, fixed_huffman_frame, 1000, 160 * 120 * 4),
    );
}

test "wuffs zlib: a size hint cannot reserve more than the input can produce" {
    const testing = std.testing;

    // A sender can declare s=10000,v=10000 (a 400 MB hint) and send ten
    // bytes. The reservation must follow the input, not the declaration:
    // with 1 MiB to allocate from, this has to fail as bad data, not OOM.
    const memory = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(memory);
    var fba: std.heap.FixedBufferAllocator = .init(memory);
    try testing.expectError(
        error.WuffsError,
        wuffs.zlib.decompress(fba.allocator(), "\x78\x9c not zlib", max_size, max_size),
    );
}

test "image load: bounded fuzz of mutated zlib frames" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Flip bytes in, or truncate, the fixed Huffman frame. Every outcome
    // must be a clean error or a frame of exactly the declared size.
    var prng = std.Random.DefaultPrng.init(570);
    const random = prng.random();
    const buf = try alloc.alloc(u8, fixed_huffman_frame.len);
    defer alloc.free(buf);
    for (0..300) |_| {
        @memcpy(buf, fixed_huffman_frame);
        var len = buf.len;
        if (random.boolean()) {
            for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
                buf[random.uintLessThan(usize, len)] ^= random.intRangeAtMost(u8, 1, 255);
            }
        } else {
            len = random.uintLessThan(usize, len);
        }
        const chunk_len = random.intRangeAtMost(usize, 1, 512);
        if (loadZlibRgba(alloc, buf[0..len], 160, 120, chunk_len)) |img| {
            var owned = img;
            defer owned.deinit(alloc);
            try testing.expectEqual(@as(usize, 160 * 120 * 4), owned.data.len);
        } else |err| switch (err) {
            error.DecompressionFailed, error.InvalidData => {},
            else => return err,
        }
    }
}

test "image load: temporary file without correct path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.TemporaryFileNotNamedCorrectly, LoadingImage.init(alloc, &cmd));

    // Temporary file should still be there
    try tmp_dir.dir.access(path, .{});
}

test "image load: temporary file outside directory prefix is rejected" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    try tmp_dir.dir.makeDir("temp");
    try tmp_dir.dir.makeDir("temp-suffix");

    const filename = "tty-graphics-protocol-image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    var outside_dir = try tmp_dir.dir.openDir("temp-suffix", .{});
    defer outside_dir.close();
    try outside_dir.writeFile(.{ .sub_path = filename, .data = data });

    var trusted_buf: [std.fs.max_path_bytes]u8 = undefined;
    const trusted_path = try tmp_dir.dir.realpath("temp", &trusted_buf);
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_path = try outside_dir.realpath(filename, &outside_buf);

    // The temporary directory is `temp`, so `temp-suffix` only shares its
    // name's prefix.
    const tmp = try TestTmpDir.set(trusted_path);
    defer tmp.restore();

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, outside_path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.TemporaryFileNotInTempDir, LoadingImage.init(alloc, &cmd));

    // Rejection must happen before temporary-file cleanup is armed.
    try outside_dir.access(filename, .{});
}

test "image load: file path longer than the path limit is refused" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // On Windows a path past the limit wrote past Zig's fixed conversion
    // buffer, so the guard has to run before anything converts it.
    for ([_]usize{ max_path_len + 1, 40000 }) |len| {
        for ([_]command.Transmission.Medium{ .file, .temporary_file }) |medium| {
            const data = try alloc.alloc(u8, len);
            @memset(data, 'a');
            @memcpy(data[0..3], "C:\\");
            var cmd: command.Command = .{
                .control = .{ .transmit = .{
                    .format = .rgb,
                    .medium = medium,
                    .width = 1,
                    .height = 1,
                    .image_id = 31,
                } },
                .data = data,
            };
            defer cmd.deinit(alloc);
            try testing.expectError(error.FilePathTooLong, LoadingImage.init(alloc, &cmd));
        }
    }

    // A path at the limit is converted and then fails as a missing file.
    const data = try alloc.alloc(u8, max_path_len);
    @memset(data, 'a');
    @memcpy(data[0..3], "C:\\");
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = data,
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.InvalidData, LoadingImage.init(alloc, &cmd));
}

test "image load: network and device path spellings are refused" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // A network path cannot be used here without contacting a share. These
    // prefixes make the SAME local file reachable (`realpath` strips them),
    // so loading would succeed without the guard and the file would be
    // deleted for `t=t`, while no network is involved.
    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

    for ([_][]const u8{ "\\\\?\\", "\\\\.\\", "\\??\\", "//?/" }) |prefix| {
        for ([_]command.Transmission.Medium{ .file, .temporary_file }) |medium| {
            var cmd: command.Command = .{
                .control = .{ .transmit = .{
                    .format = .rgb,
                    .medium = medium,
                    .compression = .none,
                    .width = 20,
                    .height = 15,
                    .image_id = 31,
                } },
                .data = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, real }),
            };
            defer cmd.deinit(alloc);
            try testing.expectError(error.InvalidData, LoadingImage.init(alloc, &cmd));
            try tmp_dir.dir.access(real, .{});
        }
    }

    // The plain path of the same file still loads.
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, real),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
}

test "image load: the opened file is validated, not what its path names later" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    try tmp_dir.dir.makeDir("allowed");
    try tmp_dir.dir.makeDir("outside");
    const filename = "tty-graphics-protocol-image.data";
    try tmp_dir.dir.writeFile(.{ .sub_path = "allowed\\" ++ filename, .data = "allowed" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "outside\\" ++ filename, .data = "outside" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp_dir.dir.realpath(".", &root_buf);
    const allowed = try std.fs.path.join(alloc, &.{ root, "allowed" });
    defer alloc.free(allowed);
    const outside = try std.fs.path.join(alloc, &.{ root, "outside" });
    defer alloc.free(outside);
    const link = try std.fs.path.join(alloc, &.{ root, "link" });
    defer alloc.free(link);
    const linked = try std.fs.path.join(alloc, &.{ link, filename });
    defer alloc.free(linked);

    const tmp = try TestTmpDir.set(allowed);
    defer tmp.restore();

    // Open the file outside the temporary directory through the link, then
    // point the link at the allowed directory, as a cooperating process
    // could between a check of the path and a later open of it.
    if (!try test_symlink.dir(alloc, link, outside)) return error.SkipZigTest;
    const held = try std.fs.cwd().openFile(linked, .{});
    defer held.close();
    try tmp_dir.dir.deleteDir("link");
    try testing.expect(try test_symlink.dir(alloc, link, allowed));
    defer tmp_dir.dir.deleteDir("link") catch {};

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const held_path = try LoadingImage.validatedFilePath(held, &buf);
    try testing.expect(!LoadingImage.isPathInTempDir(held_path));

    // The path itself now names the allowed file.
    const fresh = try std.fs.cwd().openFile(linked, .{});
    defer fresh.close();
    try testing.expect(LoadingImage.isPathInTempDir(try LoadingImage.validatedFilePath(fresh, &buf)));
}

test "image load: rgb, not compressed, temporary file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);

    // Temporary file should be gone
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(path, .{}));
}

test "image load: rgb, not compressed, regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try tmp_dir.dir.access(path, .{});
}

test "image load: regular file offset skips leading bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = &.{ 1, 2, 3, 4, 5, 6 },
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &path_buf);

    // Without S the read runs from the offset to the end of the file.
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .width = 1,
            .height = 1,
            .offset = 3,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);

    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, loading.data.items);
}

test "image load: regular file size reads exactly requested bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = &.{ 1, 2, 3, 4, 5, 6 },
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &path_buf);

    const cases = [_]struct {
        offset: u32,
        expected: [3]u8,
    }{
        .{ .offset = 0, .expected = .{ 1, 2, 3 } },
        .{ .offset = 3, .expected = .{ 4, 5, 6 } },
    };
    for (cases) |case| {
        var cmd: command.Command = .{
            .control = .{ .transmit = .{
                .format = .rgb,
                .medium = .file,
                .width = 1,
                .height = 1,
                .size = 3,
                .offset = case.offset,
                .image_id = 31,
            } },
            .data = try alloc.dupe(u8, path),
        };
        defer cmd.deinit(alloc);

        var loading = try LoadingImage.init(alloc, &cmd);
        defer loading.deinit(alloc);
        var img = try loading.complete(alloc);
        defer img.deinit(alloc);

        try testing.expectEqualSlices(u8, &case.expected, img.data);
    }
}

test "image load: regular file size rejects short data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = &.{ 1, 2 },
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &path_buf);
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .width = 1,
            .height = 1,
            .size = 3,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);

    try testing.expectError(error.InvalidData, LoadingImage.init(alloc, &cmd));
}

test "image load: png rejects oversized Wuffs image before allocation" {
    const testing = std.testing;

    // Turn the small test PNG into a 32768x32767 image. Its decoded RGBA
    // size is just under Wuffs' 4 GiB package limit but over Kitty's 400 MiB
    // limit, which previously allowed the large allocation to happen first.
    var data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data").*;
    std.mem.writeInt(u32, data[16..20], 32768, .big);
    std.mem.writeInt(u32, data[20..24], 32767, .big);
    std.mem.writeInt(u32, data[29..33], std.hash.Crc32.hash(data[12..29]), .big);

    // Refuse, and record, any request over the limit that gets past the
    // decoder's own limit to the test's allocator.
    var outer: LimitedAllocator = .init(testing.allocator, max_size);
    const alloc = outer.allocator();

    const cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .direct,
        } },
        .data = &data,
    };
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);

    try testing.expectError(error.InvalidData, loading.complete(alloc));
    try testing.expect(!outer.limit_exceeded);
}

test "image load: png, not compressed, regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try temp_dir.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .file,
            .compression = .none,
            .width = 0,
            .height = 0,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expect(img.format == .rgba);
    try tmp_dir.dir.access(path, .{});
}
