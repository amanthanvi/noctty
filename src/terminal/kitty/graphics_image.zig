const std = @import("std");
const builtin = @import("builtin");
const wuffs = @import("wuffs");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;

const fastmem = @import("../../fastmem.zig");
const animation = @import("graphics_animation.zig");
const command = @import("graphics_command.zig");
const kitty_windows = @import("windows.zig");
const windows_ext = @import("../../os/windows_ext.zig");
const local_path = @import("../../os/local_path.zig");
const PageList = @import("../PageList.zig");
const sys = @import("../sys.zig");
const LimitedAllocator = @import("../../datastruct/main.zig").LimitedAllocator;

const log = std.log.scoped(.kitty_gfx);

/// Maximum width or height of an image. Taken directly from Kitty.
const max_dimension = 10000;

/// Maximum size in bytes, taken from Kitty.
const max_size = 400 * 1024 * 1024; // 400MB

/// Maximum length in bytes of a file medium path. Zig converts a Windows
/// path into a fixed buffer of PATH_MAX_WIDE WTF-16 units without checking
/// that it fits (`sliceToPrefixedFileW`, in `std.Io.Threaded` on 0.17.1),
/// and a WTF-8 byte is at most one unit, so a path no longer than this
/// always fits.
const max_path_len = if (builtin.target.os.tag == .windows)
    std.os.windows.PATH_MAX_WIDE
else
    std.Io.Dir.max_path_bytes - 1;

/// An image that is still being loaded. The image should be initialized
/// using init on the first chunk and then addData for each subsequent
/// chunk. Once all chunks have been added, complete should be called
/// to finalize the image.
pub const LoadingImage = struct {
    /// The in-progress image. The first chunk must have all the metadata
    /// so this comes from that initially.
    image: Image,

    /// The data that is being built up.
    data: std.ArrayListUnmanaged(u8) = .empty,

    /// This is non-null when a transmit and display command is given
    /// so that we display the image after it is fully loaded.
    display: ?command.Display = null,

    /// This is non-null when this load is an animation frame
    /// transmission (a=f) rather than a new image. On completion the
    /// data is composed into the target image's animation instead of
    /// being stored as an image.
    frame: ?FrameContext = null,

    /// Quiet is the quiet settings for the initial load command. This is
    /// used if q isn't set on subsequent chunks.
    quiet: command.Command.Quiet,

    /// Response identifiers from the initial load command. Subsequent chunks
    /// omit these, so completion responses must use the saved values.
    response: command.Response = .{},

    /// The temporary directory for file transmission (null means that
    /// temporary directory transmission is disabled).
    temporary_directory: ?[]const u8,

    pub const FrameContext = struct {
        /// The frame parameters from the initial a=f command. Chunked
        /// continuations only contribute payload bytes; all parameters
        /// come from the command that started the load, matching the
        /// protocol's requirement that chunks repeat a=f.
        cmd: command.AnimationFrameLoading,

        /// The generation of the target image when the load began.
        /// A different generation at completion means the image was
        /// replaced or evicted mid-transmission and the frame must be
        /// discarded rather than composed onto the wrong image.
        image_generation: u64,
    };

    /// The limits of the Kitty Graphics protocol we should allow.
    ///
    /// This can be used to restrict the type of images and other
    /// parameters for resource or security reasons. Note that depending
    /// on how libghostty is compiled, some of these may be fully unsupported
    /// and ignored (e.g. "file" on wasm32-freestanding).
    pub const Limits = struct {
        file: bool,
        temporary_file: union(enum) {
            enabled: struct {
                /// The directory to expect temporary files in.
                directory: []const u8,
            },
            disabled: void,
        },
        shared_memory: bool,

        /// Enables all filesystem-related image transmission mediums. `path`
        /// is the temporary directory to expect files in when files are
        /// transmitted using said medium.
        pub fn allWithTempDir(path: []const u8) Limits {
            return .{
                .file = true,
                .temporary_file = .{ .enabled = .{ .directory = path } },
                .shared_memory = true,
            };
        }

        pub const direct: Limits = .{
            .file = false,
            .temporary_file = .disabled,
            .shared_memory = false,
        };
    };

    /// Initialize a chunked immage from the first image transmission.
    /// If this is a multi-chunk image, this should only be the FIRST
    /// chunk.
    pub fn init(
        io: std.Io,
        alloc: Allocator,
        cmd: *const command.Command,
        limits: Limits,
    ) !LoadingImage {
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
                .metadata = .{ .transient = t.usage.transient },
            },

            .display = cmd.display(),
            .quiet = cmd.quiet,
            .response = .{
                .id = t.image_id,
                .image_number = t.image_number,
                .placement_id = t.placement_id,
            },
            .temporary_directory = switch (limits.temporary_file) {
                .enabled => |d| d.directory,
                .disabled => null,
            },
        };

        // Special case for the direct medium, we just add the chunk directly.
        if (t.medium == .direct) {
            try result.addData(alloc, cmd.data);
            return result;
        }

        // Verify our capabilities and limits allow this.
        {
            // Special case if we don't support decoding PNGs and the format
            // is a PNG we can save a lot of memory/effort buffering the
            // data but failing up front.
            if (t.format == .png and
                sys.decode_png == null)
            {
                return error.UnsupportedMedium;
            }

            // Verify the medium is allowed
            switch (t.medium) {
                .direct => unreachable,
                .file => if (!limits.file) return error.UnsupportedMedium,
                .temporary_file => if (limits.temporary_file == .disabled) return error.UnsupportedMedium,
                .shared_memory => if (!limits.shared_memory) return error.UnsupportedMedium,
            }
        }

        // Otherwise, the payload data is guaranteed to be a path.

        if (cmd.data.len > max_path_len) return error.FilePathTooLong;

        if (comptime builtin.target.os.tag != .windows) {
            if (std.mem.indexOfScalar(u8, cmd.data, 0) != null) {
                // POSIX paths cannot contain internal nulls.
                log.warn("invalid image path: BadPathName", .{});
                return error.InvalidData;
            }
        }

        // Depending on the medium, load the data from the path.
        switch (t.medium) {
            .direct => unreachable, // handled above
            .file => try result.readFile(.file, io, alloc, t, cmd.data),
            .temporary_file => try result.readFile(.temporary_file, io, alloc, t, cmd.data),
            .shared_memory => try result.readSharedMemory(io, alloc, t, cmd.data),
        }

        return result;
    }

    /// Reads the data from a shared memory segment.
    fn readSharedMemory(
        self: *LoadingImage,
        io: std.Io,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        // android does not support POSIX shared memory.
        // windows is currently unsupported, does it support shm?
        if (comptime builtin.target.abi.isAndroid() or builtin.target.os.tag == .windows) {
            return error.UnsupportedMedium;
        }

        // libc is required for shm_open
        if (comptime !builtin.link_libc) {
            return error.UnsupportedMedium;
        }

        // The Kitty protocol requires terminals to pass shared memory names
        // unmodified to shm_open, including names without a leading slash:
        // sandboxed macOS apps can only use names of the form
        // `<app group id>/<name>`. We only reject clearly malformed names.
        if (!validSharedMemoryName(path, posix.NAME_MAX)) {
            log.warn("invalid shared memory name", .{});
            return error.InvalidData;
        }

        // Since we're only supporting posix then max_path_bytes should
        // be enough to stack allocate the path.
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const pathz = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return error.InvalidData;

        const fd = std.c.shm_open(pathz, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
        switch (std.posix.errno(fd)) {
            .SUCCESS => {},
            else => |err| {
                log.warn("unable to open shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            },
        }
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        };

        // We unlink whatever name the client sent, as the Kitty protocol
        // requires. So a client can remove any shared memory object that
        // Ghostty can open, including another app group's on macOS if it
        // can guess the name. This applies to any name, not just ones
        // without a leading slash.
        defer file.close(io);
        defer _ = std.c.shm_unlink(pathz);

        // The size from stat on may be larger than our expected size because
        // shared memory has to be a multiple of the page size.
        const stat_size: usize = stat: {
            const stat = file.stat(io) catch |err| {
                log.warn("unable to fstat shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            };
            if (stat.size <= 0) return error.InvalidData;
            break :stat std.math.cast(usize, stat.size) orelse
                return error.InvalidData;
        };

        // Get the memory range we'll read. Validate it to make sure
        // it doesn't overflow.
        const range = try self.sharedMemoryRange(t, stat_size);

        const map = std.posix.mmap(
            null,
            stat_size, // mmap always uses the stat size
            .{ .READ = true },
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.warn("unable to mmap shared memory {s}: {}", .{ path, err });
            return error.InvalidData;
        };
        defer std.posix.munmap(map);

        assert(self.data.items.len == 0);
        try self.data.appendSlice(alloc, map[range.start..range.end]);
    }

    const SharedMemoryRange = struct {
        start: usize,
        end: usize,
    };

    /// Returns the byte range to copy from a shared memory object.
    fn sharedMemoryRange(
        self: *const LoadingImage,
        t: command.Transmission,
        stat_size: usize,
    ) error{
        InvalidData,
        DimensionsTooLarge,
    }!SharedMemoryRange {
        const expected_size: ?usize = switch (self.image.format) {
            // PNG dimensions come from the decoded data.
            .png => null,

            // Validate before multiplying because protocol dimensions are
            // u32 values and may otherwise overflow in safe builds.
            .gray, .gray_alpha, .rgb, .rgba => size: {
                if (self.image.width > max_dimension or
                    self.image.height > max_dimension)
                {
                    return error.DimensionsTooLarge;
                }

                const bpp: usize = command.Transmission.formatBpp(self.image.format);
                break :size @as(usize, self.image.width) *
                    @as(usize, self.image.height) * bpp;
            },
        };

        // Get our start offset and validate its within the range of
        // the statted data.
        const start = std.math.cast(usize, t.offset) orelse
            return error.InvalidData;
        if (start > stat_size) return error.InvalidData;

        // Validate that our length is within the stat range too.
        const available = stat_size - start;
        const data_size: usize = if (t.size > 0)
            std.math.cast(usize, t.size) orelse return error.InvalidData
        else if (self.image.compression == .none and expected_size != null)
            expected_size.?
        else
            available;
        if (data_size > max_size or data_size > available) {
            return error.InvalidData;
        }

        // data_size <= available guarantees this addition cannot overflow.
        return .{ .start = start, .end = start + data_size };
    }

    /// Reads the data from a temporary file and returns it. This allocates
    /// and does not free any of the data, so the caller must free it.
    ///
    /// This will also delete the temporary file if it is in a safe location.
    fn readFile(
        self: *LoadingImage,
        comptime medium: command.Transmission.Medium,
        io: std.Io,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        switch (medium) {
            .file, .temporary_file => {},
            else => @compileError("readFile only supports file and temporary_file"),
        }

        // Some Windows paths are dangerous to even open, so the raw path
        // is checked before the open. The canonical path of the opened
        // file is checked again in validatedFilePath. See kitty_windows
        // for what is refused and why.
        if (comptime builtin.target.os.tag == .windows) {
            kitty_windows.checkPath(path) catch |err| {
                log.warn("invalid image path: {}", .{err});
                return error.InvalidData;
            };
        }

        // The canonical path buffer is sized for the longest path the
        // platform allows, which is about 96 KiB on Windows, so it is
        // heap allocated rather than placed on the stack of whichever
        // host thread feeds the stream. It is allocated before the open
        // so the deferred temporary file deletion below can still use it.
        const abs_buf = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
        defer alloc.free(abs_buf);

        // Open our file right away before we do validation. This avoids
        // TOCTOU issues. On Windows the open is local_path's, which refuses a
        // link or a mapped drive to a share before any SMB contact (an
        // ordinary open would follow it and wait on the server), and a path
        // that is not drive-absolute, which would resolve against noctty's own
        // current directory, a place the client knows nothing about.
        var file = if (comptime builtin.target.os.tag == .windows) switch (try local_path.open(alloc, path, .{ .data = true })) {
            .found => |found| hit: {
                alloc.free(found.path);
                break :hit found.file;
            },
            else => |opened| {
                log.warn("failed to open image file: {t}", .{opened});
                return error.InvalidData;
            },
        } else std.Io.Dir.cwd().openFile(
            io,
            path,
            .{},
        ) catch |err| {
            log.warn("failed to open image file: {}", .{err});
            return error.InvalidData;
        };

        // We'll populate a delete path if this is a temporary file. It is
        // deleted before the handle closes; see deleteTemporaryFile.
        var delete_path: ?[]const u8 = null;
        defer {
            if (delete_path) |p| deleteTemporaryFile(io, file, p);
            file.close(io);
        }

        // Derive the path from the open handle so the file we validate is the
        // exact file we read. Resolving a path before opening it would allow a
        // cooperating process to swap a symlink or directory entry in between.
        const abs_path = validatedFilePath(
            io,
            file,
            abs_buf,
        ) catch |err| {
            log.warn("failed to validate image file path: {}", .{err});
            return error.InvalidData;
        };

        // Temporary file logic
        if (medium == .temporary_file) {
            assert(self.temporary_directory != null);
            if (!try isPathInTempDir(
                io,
                alloc,
                self.temporary_directory.?,
                abs_path,
            )) return error.TemporaryFileNotInTempDir;
            if (std.mem.indexOf(
                u8,
                abs_path,
                "tty-graphics-protocol",
            ) == null) return error.TemporaryFileNotNamedCorrectly;
            delete_path = abs_path;
        }

        // File must be a regular file
        const stat = file.stat(io) catch |err| {
            log.warn("failed to stat file: {}", .{err});
            return error.InvalidData;
        };
        if (stat.kind != .file) {
            log.warn("file is not a regular file kind={}", .{stat.kind});
            return error.InvalidData;
        }

        // The reader reads at its own position, not the file's, so seek it.
        var buf: [4096]u8 = undefined;
        var buf_reader = file.reader(io, &buf);
        if (t.offset > 0) {
            buf_reader.seekTo(@intCast(t.offset)) catch |err| {
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

            // Refuse an S the file cannot hold before allocating S bytes.
            if (t.offset > stat.size or size > stat.size - t.offset) {
                log.warn(
                    "image file too short offset={} size={} file_size={}",
                    .{ t.offset, size, stat.size },
                );
                return error.InvalidData;
            }

            // Read exact size
            const data = reader.readAlloc(alloc, size) catch |err| {
                log.warn("failed to read image file: {}", .{err});
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidData,
                };
            };
            managed = .fromOwnedSlice(data);
        } else {
            reader.appendRemaining(alloc, &managed, .limited(max_size)) catch {
                log.warn("failed to read image file: {?}", .{buf_reader.err});
                return error.InvalidData;
            };
        }

        // Set our data
        assert(self.data.items.len == 0);
        self.data = managed;
    }

    /// Returns the canonical path of an open file after applying the file
    /// transmission blocklist.
    fn validatedFilePath(io: std.Io, file: std.Io.File, buf: []u8) ![]const u8 {
        const path = buf[0..try file.realPath(io, buf)];

        if (comptime builtin.target.os.tag == .windows) {
            try kitty_windows.checkCanonicalPath(path);
            return path;
        }

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

    /// Deletes a temporary file that was validated and read: `file` is the
    /// open handle, `path` the canonical path validatedFilePath returned.
    /// On Windows the delete goes through the handle, so it removes the
    /// file that was checked even if a path component was swapped since.
    fn deleteTemporaryFile(io: std.Io, file: std.Io.File, path: []const u8) void {
        const result = if (comptime builtin.target.os.tag == .windows)
            windows_ext.deleteOpenedFile(file.handle)
        else
            std.Io.Dir.cwd().deleteFile(io, path);
        result catch |err| {
            log.warn("failed to delete temporary file: {}", .{err});
        };
    }

    /// Returns true if path appears to be in a temporary directory.
    /// Copies logic from Kitty.
    fn isPathInTempDir(
        io: std.Io,
        alloc: Allocator,
        dir: []const u8,
        path: []const u8,
    ) Allocator.Error!bool {
        if (isPathInDir("/tmp", path)) return true;
        if (isPathInDir("/dev/shm", path)) return true;
        if (isPathInDir(dir, path)) return true;

        // On macOS /tmp is a symlink to /private/tmp, and the path is
        // canonical (see validatedFilePath), so files in /tmp only
        // match the canonical directory.
        if (comptime builtin.target.os.tag.isDarwin()) {
            if (isPathInDir("/private/tmp", path)) return true;
        }

        // The temporary dir is sometimes a symlink. On macOS for
        // example /tmp is /private/var/... On Windows the directory a
        // host passes (typically GetTempPath output) regularly differs
        // from the canonical path in case or uses 8.3 short names, and
        // resolving it covers both. The buffer is heap allocated for
        // the reason given in readFile.
        const buf = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
        defer alloc.free(buf);
        const real_dir = buf[0 .. std.Io.Dir.cwd().realPathFile(
            io,
            dir,
            buf,
        ) catch return false];
        if (isPathInDir(real_dir, path)) return true;

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

        // Data length must be what we expect.
        const bpp = command.Transmission.formatBpp(img.format);
        const expected_len = img.width * img.height * bpp;
        const actual_len = self.data.items.len;
        if (self.frame != null) {
            // Kitty allows animation frames to exceed their expected length
            // and just truncates it. Not sure if thats expected but lets
            // allow it too.
            if (actual_len < expected_len) {
                std.log.warn(
                    "insufficient frame data image id={} expected_len={} actual_len={}",
                    .{ img.id, expected_len, actual_len },
                );
                return error.InsufficientData;
            }
            self.data.items.len = expected_len;
        } else if (actual_len != expected_len) {
            std.log.warn(
                "unexpected length image id={} width={} height={} bpp={} expected_len={} actual_len={}",
                .{ img.id, img.width, img.height, bpp, expected_len, actual_len },
            );
            return error.InvalidData;
        }

        // Everything looks good, copy the image data over.
        var result = self.image;
        result.data = .{ .complete = try self.data.toOwnedSlice(alloc) };
        errdefer result.deinit(alloc);
        self.image = .{};
        return result;
    }

    /// Debug function to write the data to a file. This is useful for
    /// capturing some test data for unit tests.
    pub fn debugDump(io: std.Io, self: LoadingImage) !void {
        if (comptime builtin.mode != .debug) @compileError("debugDump in non-debug");

        var buf: [1024]u8 = undefined;
        const filename = try std.mem.print(
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
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.createFile(io, filename, .{});
        defer f.close(io);

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
            @as(usize, img.width) * img.height * command.Transmission.formatBpp(img.format);
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
        self.data = .fromOwnedSlice(result);

        // Make sure we note that our image is no longer compressed
        self.image.compression = .none;
    }

    /// Decode the data as PNG. This will also updated the image dimensions.
    fn decodePng(self: *LoadingImage, alloc: Allocator) !void {
        assert(self.image.format == .png);

        const decode_png_fn = sys.decode_png orelse
            return error.UnsupportedFormat;

        var limited: LimitedAllocator = .init(alloc, max_size);
        const decode_alloc = limited.allocator();
        const result = decode_png_fn(
            decode_alloc,
            self.data.items,
        ) catch |err| switch (err) {
            error.InvalidData => return error.InvalidData,
            error.OutOfMemory => if (limited.limit_exceeded)
                return error.InvalidData
            else
                return error.OutOfMemory,
        };
        defer decode_alloc.free(result.data);

        if (result.data.len > max_size) {
            log.warn("png image too large size={} max_size={}", .{ result.data.len, max_size });
            return error.InvalidData;
        }

        // Replace our data
        self.data.deinit(alloc);
        self.data = .empty;
        try self.data.ensureUnusedCapacity(alloc, result.data.len);
        try self.data.appendSlice(alloc, result.data[0..result.data.len]);

        // Store updated image dimensions
        self.image.width = result.width;
        self.image.height = result.height;
        self.image.format = .rgba;
    }
};

/// Image represents a single image whose metadata is fully known.
///
/// Complete image data is always fully decoded raw pixels: loading inflates
/// any zlib-compressed payload and decodes PNG into RGBA before an image is
/// completed, so `compression` is always `.none` and `format` is never `.png`
/// for a stored image. Pending image data reserves the exact decoded byte
/// length that will be attached later.
pub const Image = struct {
    id: u32 = 0,
    number: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: command.Transmission.Format = .rgb,
    compression: command.Transmission.Compression = .none,
    data: Data = .{ .complete = "" },
    metadata: packed struct(u32) {
        /// The image's transient usage hint, used to prioritize eviction.
        transient: bool = false,

        /// Set this if the image was loaded without an ID or number. Such
        /// images must not receive responses. Kitty gives these client ID
        /// 0 (unaddressable); our storage keys everything by one public
        /// u32 ID, so they get an ID from the upper half of the range
        /// that is guaranteed unused at assignment time, but a client
        /// that explicitly transmits that ID later can still replace
        /// them.
        implicit_id: bool = false,

        /// Number of placements referencing this image.
        placement_count: u30 = 0,
    } = .{},

    /// Unique, monotonically increasing stamp assigned each time an
    /// image is added to (or replaced in) an ImageStorage. A changed
    /// generation for a given image ID means the image contents may
    /// have changed, even if the dimensions and byte length are the
    /// same (e.g. a retransmission of the same ID). Stamps order by
    /// transmission time. Zero means "never stored".
    ///
    /// For animated images this also changes whenever the frame that
    /// should be displayed changes (advance, edit, or delete of the
    /// current frame), since consumers key texture caches off it.
    generation: u64 = 0,

    /// Identifies the transmission that created this image. It is set to
    /// the same stamp as `generation` when the image is added to (or
    /// replaced in) an ImageStorage, and then never changes. Zero means
    /// "never stored".
    ///
    /// Use `generation` to detect that the displayed pixels changed. Use
    /// `transmission` to detect that the image itself was replaced. The
    /// two differ for animations: showing another frame updates
    /// `generation` but leaves `transmission` alone.
    ///
    /// ```zig
    /// const before = storage.imageById(1).?;
    ///
    /// // ... the client shows another animation frame ...
    ///
    /// const after = storage.imageById(1).?;
    /// after.generation != before.generation; // true: new pixels shown
    /// after.transmission == before.transmission; // true: same image
    /// ```
    transmission: u64 = 0,

    /// Animation state, non-null once any animation command (a=f,
    /// a=a) has attached animation state to this image. Owned by the
    /// image; replaced/retransmitted images drop it, which implements
    /// the protocol's "retransmission resets the animation" rule.
    ///
    /// This is only ever attached to images stored in an ImageStorage
    /// and must only be mutated through the storage's own pointer
    /// (Image values are copied around freely; copies share this
    /// pointer and never own it).
    animation: ?*animation.Animation = null,

    pub const Error = error{
        InsufficientData,
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

    pub const Data = union(enum) {
        /// Owned, decoded image bytes. The empty default is not allocated.
        complete: []const u8,

        /// Expected decoded byte length for a payload that has not arrived.
        pending: usize,

        /// Bytes reserved against the storage limit.
        pub fn len(self: Data) usize {
            return switch (self) {
                .complete => |data| data.len,
                .pending => |expected_len| expected_len,
            };
        }

        /// Returns decoded bytes when the payload is complete.
        pub fn bytes(self: Data) ?[]const u8 {
            return switch (self) {
                .complete => |data| data,
                .pending => null,
            };
        }

        pub fn isPending(self: Data) bool {
            return self == .pending;
        }

        pub fn deinit(self: *Data, alloc: Allocator) void {
            switch (self.*) {
                .complete => |data| if (data.len > 0) alloc.free(data),
                .pending => {},
            }
        }
    };

    pub fn deinit(self: *Image, alloc: Allocator) void {
        self.data.deinit(alloc);
        if (self.animation) |anim| {
            anim.deinit(alloc);
            alloc.destroy(anim);
            self.animation = null;
        }
    }

    /// The pixel data that should be displayed for this image. For an
    /// animated image this is the current animation frame. Otherwise,
    /// and for the root frame, it is the image's own data.
    ///
    /// The result is pending when the displayed pixels have not arrived
    /// yet. That can be true even when `data` is complete, because the
    /// current animation frame may still be pending. Code that draws an
    /// image should check this result rather than `data`:
    ///
    /// ```zig
    /// const pixels = image.renderData().bytes() orelse return; // not ready
    /// upload(pixels);
    /// ```
    pub fn renderData(self: *const Image) Data {
        if (self.animation) |anim| {
            if (anim.current_index > 0) {
                const frame = anim.frames.items[anim.current_index - 1];
                if (frame.isPending()) return .{ .pending = frame.pending_len };
                return .{ .complete = frame.data };
            }
        }

        return self.data;
    }

    /// The pixel data of the given 1-based animation frame number, or
    /// null if the frame doesn't exist or its pixels have not arrived
    /// yet. Frame 1 (the root frame) always exists as long as the image
    /// data is complete, even for images without animation state.
    ///
    /// The returned slice is owned by the image (or its animation)
    /// and remains valid until the image or frame is mutated.
    pub fn frameData(self: *const Image, number: u32) ?[]const u8 {
        switch (number) {
            0 => return null,
            1 => return self.data.bytes(),
            else => {
                const anim = self.animation orelse return null;
                // Minus 2 because frame is 1-based and frame 1 is the
                // image base data, so the animation frames start at frame 2.
                const idx = number - 2;
                if (idx >= anim.frames.items.len) return null;
                const frame = anim.frames.items[idx];
                if (frame.isPending()) return null;
                return frame.data;
            },
        }
    }

    /// Total bytes of pixel data reserved against the storage limit
    /// for this image: the base data plus any animation frames.
    pub fn storageSize(self: *const Image) usize {
        var total: usize = self.data.len();
        if (self.animation) |anim| total += anim.frameBytes();
        return total;
    }

    /// Mostly for logging
    pub fn withoutData(self: *const Image) Image {
        var copy = self.*;
        if (copy.data == .complete) copy.data = .{ .complete = "" };
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

/// Returns whether a name can be passed to shm_open. Slashes are left
/// for shm_open to judge since the valid forms are platform specific.
fn validSharedMemoryName(name: []const u8, name_max: usize) bool {
    if (name.len == 0 or name.len > name_max) return false;
    if (std.mem.eql(u8, name, "/")) return false;
    return std.mem.indexOfScalar(u8, name, 0) == null;
}

/// Returns true if `path` is `dir` or is contained within it, requiring a
/// path-separator boundary so similarly prefixed directories do not match.
fn isPathInDir(dir: []const u8, path: []const u8) bool {
    if (dir.len == 0 or !std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len or std.fs.path.isSep(dir[dir.len - 1])) return true;
    return std.fs.path.isSep(path[dir.len]);
}

test {
    _ = kitty_windows;
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

    if (comptime builtin.target.os.tag != .windows) return;
    try testing.expect(isPathInDir("C:\\Temp", "C:\\Temp\\tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("C:\\Temp\\", "C:\\Temp\\tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("C:\\Temp", "C:\\Temp/tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("C:\\", "C:\\tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("C:\\Temp", "C:\\Temp2\\tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("C:\\Temp", "C:\\Templates\\tty-graphics-protocol-image.data"));
}

test "shared memory names" {
    const testing = std.testing;

    try testing.expect(validSharedMemoryName("/kitty", 8));
    try testing.expect(validSharedMemoryName("/1234567", 8));
    try testing.expect(validSharedMemoryName("kitty", 8));
    try testing.expect(validSharedMemoryName("TEAMID.group/kitty", 31));
    try testing.expect(validSharedMemoryName("/kitty/image", 16));

    try testing.expect(!validSharedMemoryName("", 8));
    try testing.expect(!validSharedMemoryName("/", 8));
    try testing.expect(!validSharedMemoryName("/kitty\x00image", 16));
    try testing.expect(!validSharedMemoryName("kitty\x00image", 16));
    try testing.expect(!validSharedMemoryName("/12345678", 8));
}

test "image load rejects shared memory names containing NUL" {
    if (comptime builtin.target.abi.isAndroid() or
        builtin.target.os.tag == .windows or
        !builtin.link_libc)
    {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const alloc = testing.allocator;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .shared_memory,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "/kitty\x00image"),
    };
    defer cmd.deinit(alloc);

    try testing.expectError(
        error.InvalidData,
        LoadingImage.init(testing.io, alloc, &cmd, .{
            .file = false,
            .temporary_file = .disabled,
            .shared_memory = true,
        }),
    );
}

test "image load accepts shared memory names without a leading slash" {
    if (comptime builtin.target.abi.isAndroid() or
        builtin.target.os.tag == .windows or
        !builtin.link_libc)
    {
        return error.SkipZigTest;
    }

    // FreeBSD's shm_open rejects names without a leading slash with
    // EINVAL, so there is no such object for us to load.
    if (comptime builtin.target.os.tag == .freebsd) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Sandboxed macOS apps can only create names of this form. The pid
    // keeps concurrent test runs apart; Darwin limits names to 31 bytes.
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&buf, "{s}{d}", .{
        if (comptime builtin.target.os.tag.isDarwin())
            "ghostty.test/shm-"
        else
            "ghostty-test-shm-",
        std.c.getpid(),
    }, 0);
    const data = "\x01\x02\x03";

    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(std.c.mode_t, 0o600),
    );
    switch (std.posix.errno(fd)) {
        .SUCCESS => {},
        .ACCES, .PERM, .NOSYS => return error.SkipZigTest,
        else => |err| {
            log.warn("unable to create shared memory {s}: {}", .{ name, err });
            return error.TestUnexpectedResult;
        },
    }
    defer _ = std.c.close(fd);
    defer _ = std.c.shm_unlink(name);
    try testing.expectEqual(0, std.c.ftruncate(fd, data.len));
    {
        // macOS does not support write(2) on shared memory, so map it.
        const map = try std.posix.mmap(
            null,
            data.len,
            .{ .READ = true, .WRITE = true },
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );
        defer std.posix.munmap(map);
        @memcpy(map[0..data.len], data);
    }

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .shared_memory,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, name),
    };
    defer cmd.deinit(alloc);

    var loading = try LoadingImage.init(testing.io, alloc, &cmd, .{
        .file = false,
        .temporary_file = .disabled,
        .shared_memory = true,
    });
    defer loading.deinit(alloc);
    try testing.expectEqualSlices(u8, data, loading.data.items);

    // The terminal must unlink the object after reading it. fstat can't
    // tell us this since macOS always reports st_nlink 0 for shared memory.
    const reopened = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(std.c.mode_t, 0),
    );
    if (reopened >= 0) _ = std.c.close(reopened);
    try testing.expectEqual(std.posix.E.NOENT, std.posix.errno(reopened));
}

test "shared memory range with offset and size" {
    const testing = std.testing;

    const loading: LoadingImage = .{
        .image = .{
            .width = 1,
            .height = 1,
            .format = .rgb,
        },
        .quiet = .no,
        .temporary_directory = null,
    };

    const explicit = try loading.sharedMemoryRange(.{
        .offset = 2,
        .size = 3,
    }, 5);
    try testing.expectEqual(@as(usize, 2), explicit.start);
    try testing.expectEqual(@as(usize, 5), explicit.end);

    const implicit = try loading.sharedMemoryRange(.{
        .offset = 2,
    }, 5);
    try testing.expectEqual(@as(usize, 2), implicit.start);
    try testing.expectEqual(@as(usize, 5), implicit.end);
}

test "shared memory range rejects out of bounds offset" {
    const loading: LoadingImage = .{
        .image = .{
            .width = 1,
            .height = 1,
            .format = .rgb,
        },
        .quiet = .no,
        .temporary_directory = null,
    };

    try std.testing.expectError(
        error.InvalidData,
        loading.sharedMemoryRange(.{ .offset = 4 }, 3),
    );
}

test "shared memory range validates dimensions before multiplication" {
    const loading: LoadingImage = .{
        .image = .{
            .width = std.math.maxInt(u32),
            .height = std.math.maxInt(u32),
            .format = .rgba,
        },
        .quiet = .no,
        .temporary_directory = null,
    };

    try std.testing.expectError(
        error.DimensionsTooLarge,
        loading.sharedMemoryRange(.{}, 1),
    );
}

// This specifically tests we ALLOW invalid RGB data because Kitty
// documents that this should work.
test "image load with invalid RGB data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
}

test "image load with image too wide" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load with image too tall" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load: rgb, zlib compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, not compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs: std.Io.Reader = .fixed(data[1024..]);
    var buf: [1024]u8 = undefined;
    while (fbs.readSliceShort(&buf)) |size| {
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
    const io = testing.io;

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs: std.Io.Reader = .fixed(data);
    var buf: [1024]u8 = undefined;
    while (fbs.readSliceShort(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;

    // Complete
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

test "image load: temporary file without correct path" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];

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
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectError(error.TemporaryFileNotNamedCorrectly, LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    ));

    // Temporary file should still be there
    try tmp_dir.dir.access(testing.io, path, .{});
}

test "image load: temporary file outside directory prefix is rejected" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(io, "temp", .default_dir);
    try tmp_dir.dir.createDir(io, "temp-suffix", .default_dir);

    var trusted_dir = try tmp_dir.dir.openDir(io, "temp", .{});
    defer trusted_dir.close(io);
    var outside_dir = try tmp_dir.dir.openDir(io, "temp-suffix", .{});
    defer outside_dir.close(io);

    const filename = "tty-graphics-protocol-image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try outside_dir.writeFile(io, .{
        .sub_path = filename,
        .data = data,
    });

    var trusted_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const trusted_path = trusted_path_buf[0..try trusted_dir.realPath(io, &trusted_path_buf)];
    var outside_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const outside_path = outside_path_buf[0..try outside_dir.realPathFile(io, filename, &outside_path_buf)];

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
    try testing.expectError(
        error.TemporaryFileNotInTempDir,
        LoadingImage.init(io, alloc, &cmd, .allWithTempDir(trusted_path)),
    );

    // Rejection must happen before temporary-file cleanup is armed.
    try outside_dir.access(io, filename, .{});
}

test "image load: temporary file in /tmp on macOS" {
    // /tmp is a symlink to /private/tmp on macOS, so the canonical path
    // of a file in it does not start with /tmp.
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // The configured temporary directory does not contain /tmp, so the
    // file can only be accepted through the /tmp root.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_path_buf[0..try tmp_dir.dir.realPath(io, &dir_path_buf)];

    const path = try std.fmt.allocPrint(
        alloc,
        "/tmp/ghostty-test-{s}-tty-graphics-protocol-image.data",
        .{tmp_dir.sub_path},
    );
    defer alloc.free(path);
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_path));
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);

    // Temporary file should be gone
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, path, .{}),
    );
}

test "image load: rgb, not compressed, temporary file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];

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
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);

    // Temporary file should be gone
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(testing.io, path, .{}));
}

test "image load: rgb, not compressed, regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];

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
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try tmp_dir.dir.access(testing.io, path, .{});
}

test "image load: regular file size reads exactly requested bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "image.data",
        .data = &.{ 1, 2, 3, 4, 5, 6 },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(
        io,
        "image.data",
        &path_buf,
    )];

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

        var loading = try LoadingImage.init(io, alloc, &cmd, .{
            .file = true,
            .temporary_file = .disabled,
            .shared_memory = false,
        });
        defer loading.deinit(alloc);
        var img = try loading.complete(alloc);
        defer img.deinit(alloc);

        try testing.expectEqualSlices(u8, &case.expected, img.data.complete);
    }
}

test "image load: regular file size rejects short data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "image.data",
        .data = &.{ 1, 2 },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(
        io,
        "image.data",
        &path_buf,
    )];
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

    try testing.expectError(
        error.InvalidData,
        LoadingImage.init(io, alloc, &cmd, .{
            .file = true,
            .temporary_file = .disabled,
            .shared_memory = false,
        }),
    );
}

test "image load: rgb, not compressed, relative regular file" {
    // On Windows a path that is not drive-absolute is refused (local_path.open;
    // "image load: windows file path that is not drive-absolute is refused").
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.print(
            ".zig-cache/tmp/{s}/image.data",
            .{tmp_dir.sub_path},
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = false,
    });
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

test "image load: blocklist applies to opened file after symlink swap" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "safe.data",
        .data = "safe",
    });
    try tmp_dir.dir.symLink(io, "/dev/null", "image.data", .{});

    // Pin the blocked file, then simulate the cooperating process replacing
    // the path with a safe target before validation.
    const blocked_file = try tmp_dir.dir.openFile(io, "image.data", .{});
    defer blocked_file.close(io);
    try tmp_dir.dir.symLinkAtomic(io, "safe.data", "image.data", .{});

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectError(
        error.InvalidData,
        LoadingImage.validatedFilePath(io, blocked_file, &path_buf),
    );

    // The pathname now resolves to the safe replacement, demonstrating that
    // the rejection above came from the already-open file handle.
    const safe_file = try tmp_dir.dir.openFile(io, "image.data", .{});
    defer safe_file.close(io);
    _ = try LoadingImage.validatedFilePath(io, safe_file, &path_buf);
}

test "image load: windows UNC path is rejected before open" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Opening a UNC path would resolve the host name and authenticate to
    // it over SMB, so the rejection has to happen on the raw path. The
    // host name is in the reserved .invalid TLD so it can never resolve.
    const paths = [_][]const u8{
        "\\\\nonexistent-host.invalid\\share\\tty-graphics-protocol-image.data",
        "//nonexistent-host.invalid/share/tty-graphics-protocol-image.data",
        "\\\\?\\UNC\\nonexistent-host.invalid\\share\\image.data",
    };
    for (paths) |path| {
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
        try testing.expectError(
            error.InvalidData,
            LoadingImage.init(io, alloc, &cmd, .{
                .file = true,
                .temporary_file = .disabled,
                .shared_memory = false,
            }),
        );
    }
}

test "image load: windows device namespace paths are rejected before open" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "tty-graphics-protocol-image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = data });

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp_dir.dir.realPath(io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];

    // The verbatim, local device and NT namespace spellings all resolve
    // to the same real file, so rejecting them proves the check runs on
    // the raw path rather than on the canonical one.
    const prefixes = [_][]const u8{ "\\\\?\\", "\\\\.\\", "\\??\\" };
    for (prefixes) |prefix| {
        const path = try std.mem.concat(alloc, u8, &.{ prefix, real_path });
        defer alloc.free(path);

        const mediums = [_]command.Transmission.Medium{ .file, .temporary_file };
        for (mediums) |medium| {
            var cmd: command.Command = .{
                .control = .{ .transmit = .{
                    .format = .rgb,
                    .medium = medium,
                    .compression = .none,
                    .width = 20,
                    .height = 15,
                    .image_id = 31,
                } },
                .data = try alloc.dupe(u8, path),
            };
            defer cmd.deinit(alloc);
            try testing.expectError(
                error.InvalidData,
                LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_path)),
            );
        }
    }

    // A named pipe reached through the local device namespace.
    {
        var cmd: command.Command = .{
            .control = .{ .transmit = .{
                .format = .rgb,
                .medium = .file,
                .compression = .none,
                .width = 20,
                .height = 15,
                .image_id = 31,
            } },
            .data = try alloc.dupe(u8, "\\\\.\\pipe\\ghostty-kitty-graphics-test"),
        };
        defer cmd.deinit(alloc);
        try testing.expectError(
            error.InvalidData,
            LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_path)),
        );
    }

    // Nothing above reached the temporary file deletion.
    try tmp_dir.dir.access(io, filename, .{});
}

test "image load: windows reserved device names are rejected before open" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp_dir.dir.realPath(io, &dir_buf)];

    const names = [_][]const u8{ "CON", "NUL.data", "com1", "LPT9.png", "AUX", "PRN." };
    for (names) |name| {
        const path = try std.fs.path.join(alloc, &.{ dir_path, name });
        defer alloc.free(path);

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
        try testing.expectError(
            error.InvalidData,
            LoadingImage.init(io, alloc, &cmd, .{
                .file = true,
                .temporary_file = .disabled,
                .shared_memory = false,
            }),
        );
    }
}

test "image load: windows local file accepted in forward slash and upper case spellings" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = data });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];

    // Both spellings open the same file; the canonical path the checks
    // see is the backslash, on-disk case form either way.
    const forward = try alloc.dupe(u8, real_path);
    defer alloc.free(forward);
    std.mem.replaceScalar(u8, forward, '\\', '/');
    const upper = try alloc.dupe(u8, real_path);
    defer alloc.free(upper);
    _ = std.ascii.upperString(upper, real_path);

    const spellings = [_][]const u8{ forward, upper };
    for (spellings) |path| {
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
        var loading = try LoadingImage.init(io, alloc, &cmd, .{
            .file = true,
            .temporary_file = .disabled,
            .shared_memory = false,
        });
        defer loading.deinit(alloc);
        var img = try loading.complete(alloc);
        defer img.deinit(alloc);
        try testing.expect(img.compression == .none);
    }

    try tmp_dir.dir.access(io, filename, .{});
}

test "image load: windows temporary file with differently spelled directory" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "tty-graphics-protocol-image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = data });

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp_dir.dir.realPath(io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];

    // Hosts hand over GetTempPath output, which regularly differs from
    // the canonical path in case (`C:\WINDOWS\TEMP\`), so the directory
    // prefix check only passes through the real-path fallback.
    const dir_upper = try alloc.dupe(u8, dir_path);
    defer alloc.free(dir_upper);
    _ = std.ascii.upperString(dir_upper, dir_path);
    const path_upper = try alloc.dupe(u8, real_path);
    defer alloc.free(path_upper);
    _ = std.ascii.upperString(path_upper, real_path);
    try testing.expect(!isPathInDir(dir_upper, real_path) or
        std.mem.eql(u8, dir_upper, dir_path));

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path_upper),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_upper));
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);

    // Temporary file should be gone
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(io, filename, .{}));
}

test "image load: windows canonical path check accepts a local file opened through a device spelling" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "image.data";
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = "safe" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];

    // readFile refuses this spelling before the open, but the post-open
    // check works from the canonical path and so does not care how the
    // file was reached: `\\.\C:\...` canonicalizes back to `C:\...`.
    const device_path = try std.mem.concat(alloc, u8, &.{ "\\\\.\\", real_path });
    defer alloc.free(device_path);
    const file = try std.Io.Dir.cwd().openFile(io, device_path, .{});
    defer file.close(io);

    const canon_buf = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
    defer alloc.free(canon_buf);
    const canon = try LoadingImage.validatedFilePath(io, file, canon_buf);
    try testing.expectEqualStrings(real_path, canon);
}

test "image load: windows canonical path check rejects a file reached through a UNC share" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "image.data";
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = "safe" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];
    try testing.expect(kitty_windows.isDriveAbsolute(real_path));

    // Reach the same local file through the loopback administrative
    // share, which is how a junction or symlink into a share would look
    // to the post-open check. The share needs the server service and an
    // administrative token, so the test is skipped when the open fails.
    const unc_path = try alloc.print(
        "\\\\localhost\\{c}$\\{s}",
        .{ real_path[0], real_path[3..] },
    );
    defer alloc.free(unc_path);
    const file = std.Io.Dir.cwd().openFile(io, unc_path, .{}) catch
        return error.SkipZigTest;
    defer file.close(io);

    const canon_buf = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
    defer alloc.free(canon_buf);
    try testing.expectError(
        error.NotDriveAbsolute,
        LoadingImage.validatedFilePath(io, file, canon_buf),
    );
}

test "image load: png, not compressed, regular file" {
    if (sys.decode_png == null) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];

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
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expect(img.format == .rgba);
    try tmp_dir.dir.access(testing.io, path, .{});
}

test "image load: png, zlib compressed, direct" {
    if (sys.decode_png == null) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const data = @embedFile("testdata/image-png-zlib_deflate-50x76-2147483647-raw.data");

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .direct,
            .compression = .zlib_deflate,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, data),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    try testing.expectEqual(command.Transmission.Compression.none, img.compression);
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
    try testing.expectEqual(@as(u32, 50), img.width);
    try testing.expectEqual(@as(u32, 76), img.height);
}

test "image load: png rejects oversized decoder allocation" {
    const testing = std.testing;

    const oversized_decoder = struct {
        fn decode(
            alloc: Allocator,
            _: []const u8,
        ) sys.DecodeError!sys.Image {
            const data = try alloc.alloc(u8, max_size + 1);
            return .{
                .width = 1,
                .height = 1,
                .data = data,
            };
        }
    }.decode;

    const original_decode_png = sys.decode_png;
    defer sys.decode_png = original_decode_png;
    sys.decode_png = &oversized_decoder;

    // Fail any allocation which reaches the underlying allocator. The size
    // limiter should reject the decoder's request before it gets that far.
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    const alloc = failing.allocator();

    var loading: LoadingImage = .{
        .image = .{ .format = .png },
        .quiet = .no,
        .temporary_directory = null,
    };
    defer loading.deinit(alloc);

    try testing.expectError(error.InvalidData, loading.complete(alloc));
    try testing.expect(!failing.has_induced_failure);
}

test "image load: png rejects oversized Wuffs image before allocation" {
    if (sys.decode_png == null) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Turn the small test PNG into a 32768x32767 image. Its decoded RGBA
    // size is just under Wuffs' 4 GiB package limit but over Kitty's 400 MiB
    // limit, which previously allowed the large allocation to happen first.
    var data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data").*;
    std.mem.writeInt(u32, data[16..20], 32768, .big);
    std.mem.writeInt(u32, data[20..24], 32767, .big);
    std.mem.writeInt(u32, data[29..33], std.hash.Crc32.hash(data[12..29]), .big);

    const cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .direct,
        } },
        .data = &data,
    };
    var loading = try LoadingImage.init(testing.io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);

    try testing.expectError(error.InvalidData, loading.complete(alloc));
}

test "limits: direct medium always allowed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);

    // Direct medium should work even with the most restrictive limits
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
}

test "limits: file medium blocked by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];

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
    try testing.expectError(error.UnsupportedMedium, LoadingImage.init(io, alloc, &cmd, .direct));
}

test "limits: file medium allowed by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];

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
    var loading = try LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = false,
    });
    defer loading.deinit(alloc);
}

test "limits: temporary file medium blocked by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];

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
    try testing.expectError(error.UnsupportedMedium, LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = true,
    }));

    // File should still exist since we blocked before reading
    try tmp_dir.dir.access(testing.io, "tty-graphics-protocol-image.data", .{});
}

test "limits: temporary file medium allowed by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];

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
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,

        .{
            .file = false,
            .temporary_file = .{
                .enabled = .{ .directory = dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)] },
            },
            .shared_memory = false,
        },
    );
    defer loading.deinit(alloc);
}

// The fork's tests below (WUFFS zlib #570/#609, the path bound, the Windows
// file medium through os/local_path.zig #638) are re-applied onto upstream's
// tests: the temporary directory a test allows is passed in its limits
// (`.allWithTempDir`), as upstream's own tests do, instead of TMP.

/// The limits the fork's file-medium tests load with: regular files only.
const test_file_limits: LoadingImage.Limits = .{
    .file = true,
    .temporary_file = .disabled,
    .shared_memory = false,
};

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
    var loading = try LoadingImage.init(std.testing.io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var rest = data;
    while (rest.len > 0) {
        const n = @min(chunk_len, rest.len);
        try loading.addData(alloc, rest[0..n]);
        rest = rest[n..];
    }
    return loading.complete(alloc);
}

/// Loads `path` as a `t=f` file, and checks that it loads (`loads`) or that
/// it is refused with `InvalidData`.
fn expectFileLoad(io: std.Io, alloc: Allocator, path: []const u8, loads: bool) !void {
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
    if (loads) {
        var loading = try LoadingImage.init(io, alloc, &cmd, test_file_limits);
        defer loading.deinit(alloc);
        var img = try loading.complete(alloc);
        defer img.deinit(alloc);
    } else {
        try std.testing.expectError(error.InvalidData, LoadingImage.init(io, alloc, &cmd, test_file_limits));
    }
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
        try testing.expectEqualSlices(u8, expected, img.data.bytes().?);
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
            try testing.expectEqual(@as(usize, 160 * 120 * 4), owned.data.bytes().?.len);
        } else |err| switch (err) {
            error.DecompressionFailed, error.InvalidData => {},
            else => return err,
        }
    }
}

test "image load: file path longer than the path limit is refused" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // On Windows a path past the limit panicked in Zig's fixed conversion
    // buffer (Debug), so the guard has to run before anything converts it.
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
            try testing.expectError(error.FilePathTooLong, LoadingImage.init(io, alloc, &cmd, .allWithTempDir("C:\\")));
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
    try testing.expectError(error.InvalidData, LoadingImage.init(io, alloc, &cmd, test_file_limits));
}

test "image load: network and device path spellings are refused" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // A network path cannot be used here without contacting a share. These
    // prefixes make the SAME local file reachable (`realpath` strips them),
    // so loading would succeed without the guard and the file would be
    // deleted for `t=t`, while no network is involved.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp_dir.dir.realPath(io, &dir_buf)];
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real = buf[0..try tmp_dir.dir.realPathFile(io, "tty-graphics-protocol-image.data", &buf)];

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
                .data = try alloc.print("{s}{s}", .{ prefix, real }),
            };
            defer cmd.deinit(alloc);
            try testing.expectError(error.InvalidData, LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_path)));
            try std.Io.Dir.cwd().access(io, real, .{});
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
    var loading = try LoadingImage.init(io, alloc, &cmd, test_file_limits);
    defer loading.deinit(alloc);
}

test "image load: the opened file is validated, not what its path names later" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(io, "allowed", .default_dir);
    try tmp_dir.dir.createDir(io, "outside", .default_dir);
    const filename = "tty-graphics-protocol-image.data";
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "allowed\\" ++ filename, .data = "allowed" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "outside\\" ++ filename, .data = "outside" });

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp_dir.dir.realPath(io, &root_buf)];
    const allowed = try std.fs.path.join(alloc, &.{ root, "allowed" });
    defer alloc.free(allowed);
    const outside = try std.fs.path.join(alloc, &.{ root, "outside" });
    defer alloc.free(outside);
    const link = try std.fs.path.join(alloc, &.{ root, "link" });
    defer alloc.free(link);
    const linked = try std.fs.path.join(alloc, &.{ link, filename });
    defer alloc.free(linked);

    // Open the file outside the temporary directory through the link, then
    // point the link at the allowed directory, as a cooperating process
    // could between a check of the path and a later open of it.
    if (!try local_path.test_links.symlink(alloc, link, outside, true)) return error.SkipZigTest;
    const held = try std.Io.Dir.cwd().openFile(io, linked, .{});
    defer held.close(io);
    try tmp_dir.dir.deleteDir(io, "link");
    try testing.expect(try local_path.test_links.symlink(alloc, link, allowed, true));
    defer tmp_dir.dir.deleteDir(io, "link") catch {};

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const held_path = try LoadingImage.validatedFilePath(io, held, &buf);
    try testing.expect(!try LoadingImage.isPathInTempDir(io, alloc, allowed, held_path));

    // The path itself now names the allowed file.
    const fresh = try std.Io.Dir.cwd().openFile(io, linked, .{});
    defer fresh.close(io);
    const fresh_path = try LoadingImage.validatedFilePath(io, fresh, &buf);
    try testing.expect(try LoadingImage.isPathInTempDir(io, alloc, allowed, fresh_path));
}

test "image load: a temporary file is deleted through its handle, not by its validated path" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const name = "tty-graphics-protocol-image.data";
    try tmp_dir.dir.writeFile(io, .{ .sub_path = name, .data = "validated" });

    const file = try tmp_dir.dir.openFile(io, name, .{});
    defer file.close(io);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try LoadingImage.validatedFilePath(io, file, &buf);

    // After the checks, the validated path comes to name another file.
    try std.Io.Dir.rename(tmp_dir.dir, name, tmp_dir.dir, "moved.data", io);
    try tmp_dir.dir.writeFile(io, .{ .sub_path = name, .data = "other" });

    LoadingImage.deleteTemporaryFile(io, file, path);

    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(io, "moved.data", .{}));
    var other_buf: [16]u8 = undefined;
    try testing.expectEqualStrings("other", try tmp_dir.dir.readFile(io, name, &other_buf));
}

test "image load: windows file reached through a symlink to a share is refused" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(io, "real", .default_dir);
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "real\\image.data", .data = data });

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp_dir.dir.realPath(io, &root_buf)];

    // A local-looking path whose directory is a symlink to the loopback
    // administrative share: it passes every check of the raw path, and the
    // load's open (`local_path.open`) refuses the link without contacting
    // the share. A timing test cannot tell that from a share that does not
    // answer, so this share answers.
    const share = try alloc.print("\\\\localhost\\{c}$\\{s}\\real", .{ root[0], root[3..] });
    defer alloc.free(share);
    const link = try std.fs.path.join(alloc, &.{ root, "link" });
    defer alloc.free(link);
    if (!try local_path.test_links.symlink(alloc, link, share, true)) return error.SkipZigTest;
    defer tmp_dir.dir.deleteDir(io, "link") catch {};
    const linked = try std.fs.path.join(alloc, &.{ link, "image.data" });
    defer alloc.free(linked);

    // Positive control: an ordinary open follows the link on purpose, to
    // show the share answers and holds the file. Without the server service
    // or an administrative token it does not, and the test is skipped.
    const control = std.Io.Dir.cwd().openFile(io, linked, .{}) catch return error.SkipZigTest;
    control.close(io);

    try expectFileLoad(io, alloc, linked, false);
}

test "image load: windows file through a link to a share that does not answer is refused at once" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(io, "real", .default_dir);
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "real\\image.data", .data = data });

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp_dir.dir.realPath(io, &root_buf)];
    const real = try std.fs.path.join(alloc, &.{ root, "real" });
    defer alloc.free(real);

    // A directory symlink to a share on TEST-NET-1 (RFC 5737), which no route
    // reaches: an open that followed it would wait on the connection. (Windows
    // refuses a junction to a share at once, so only a symlink shows this.)
    // Positive control: the same shape of link to a local folder loads.
    const Case = struct { name: []const u8, target: []const u8, loads: bool };
    for ([_]Case{
        .{ .name = "to-local", .target = real, .loads = true },
        .{ .name = "to-share", .target = "\\\\192.0.2.1\\noctty-test-none$", .loads = false },
    }) |case| {
        const link = try std.fs.path.join(alloc, &.{ root, case.name });
        defer alloc.free(link);
        if (!try local_path.test_links.symlink(alloc, link, case.target, true)) {
            std.log.warn("kitty share-link test: this account cannot make symlinks", .{});
            return error.SkipZigTest;
        }
        defer tmp_dir.dir.deleteDir(io, case.name) catch {};
        const linked = try std.fs.path.join(alloc, &.{ link, "image.data" });
        defer alloc.free(linked);

        const start: std.Io.Timestamp = .now(io, .awake);
        try expectFileLoad(io, alloc, linked, case.loads);
        const elapsed = start.durationTo(.now(io, .awake));
        try testing.expect(elapsed.nanoseconds < 5 * std.time.ns_per_s);
    }
}

test "image load: windows file path that is not drive-absolute is refused" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "image.data", .data = data });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, "image.data", &path_buf)];
    const cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    if (!kitty_windows.isDriveAbsolute(real_path) or !std.ascii.eqlIgnoreCase(cwd[0..2], real_path[0..2]))
        return error.SkipZigTest;

    // The same file as text the client cannot mean: relative to noctty's own
    // current directory, rooted on its drive, or relative on its drive.
    const relative = try std.fs.path.relativeAlloc(alloc, cwd, null, cwd, real_path);
    defer alloc.free(relative);
    const drive_relative = try alloc.print("{s}{s}", .{ real_path[0..2], relative });
    defer alloc.free(drive_relative);
    const Case = struct { path: []const u8, loads: bool };
    for ([_]Case{
        // Positive control: the drive-absolute path loads.
        .{ .path = real_path, .loads = true },
        .{ .path = relative, .loads = false },
        .{ .path = real_path[2..], .loads = false },
        .{ .path = drive_relative, .loads = false },
    }) |case| {
        errdefer std.debug.print("kitty image path {s}\n", .{case.path});
        try expectFileLoad(io, alloc, case.path, case.loads);
    }
}

test "image load: windows file the bounded open cannot show is plain local data is refused" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(io, "real", .default_dir);
    try tmp_dir.dir.createDir(io, "to-real", .default_dir);
    defer tmp_dir.dir.deleteDir(io, "to-real") catch {};
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "real\\image.data", .data = data });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp_dir.dir.realPath(io, &root_buf)];
    const file = try std.fs.path.join(alloc, &.{ root, "real\\image.data" });
    defer alloc.free(file);

    // Positive control for each case below: the plain file loads.
    try expectFileLoad(io, alloc, file, true);

    // An alternate data stream of the file, holding the same image: `open`
    // takes no ':' after the drive (a volume without streams skips this).
    const has_stream = if (tmp_dir.dir.writeFile(io, .{ .sub_path = "real\\image.data:s", .data = data })) true else |_| false;
    if (has_stream) {
        const stream = try alloc.print("{s}:s", .{file});
        defer alloc.free(stream);
        try expectFileLoad(io, alloc, stream, false);
    }

    // A drive whose DOS name maps to anything but a direct volume device, as
    // a SUBST drive's `\??\C:\folder` does (`os.windows_ext.directVolumeDeviceName`
    // refuses it), injected at the OS seam the open consults.
    const Reject = struct {
        fn map(_: [*:0]const u16, _: []u16) ?[]const u16 {
            return null;
        }
    };
    windows_ext.TestHooks.direct_volume_mapping = Reject.map;
    defer windows_ext.TestHooks.direct_volume_mapping = null;
    try expectFileLoad(io, alloc, file, false);
    windows_ext.TestHooks.direct_volume_mapping = null;

    // Behind a junction the open walks each name, and refuses one whose
    // reparse tag is no link and no cloud placeholder (here WOF compression,
    // read through `test_cloud`). Positive control: the junction loads.
    const real = try std.fs.path.join(alloc, &.{ root, "real" });
    defer alloc.free(real);
    const junction = try std.fs.path.join(alloc, &.{ root, "to-real" });
    defer alloc.free(junction);
    const real_nt = try alloc.print("\\??\\{s}", .{real});
    defer alloc.free(real_nt);
    try local_path.test_links.junction(alloc, junction, real_nt);
    const linked = try std.fs.path.join(alloc, &.{ junction, "image.data" });
    defer alloc.free(linked);
    try expectFileLoad(io, alloc, linked, true);
    defer local_path.test_cloud.reset();
    local_path.test_cloud.name = "image.data";
    local_path.test_cloud.attributes = 0x400; // FILE_ATTRIBUTE_REPARSE_POINT
    local_path.test_cloud.tag = 0x80000017; // IO_REPARSE_TAG_WOF
    try expectFileLoad(io, alloc, linked, false);
}

test "image load: regular file offset skips leading bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "image.data",
        .data = &.{ 1, 2, 3, 4, 5, 6 },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(io, "image.data", &path_buf)];

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

    var loading = try LoadingImage.init(io, alloc, &cmd, test_file_limits);
    defer loading.deinit(alloc);
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, loading.data.items);
}

test "image load: regular file size past the file is refused before allocation" {
    const testing = std.testing;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "image.data",
        .data = &.{ 1, 2, 3, 4, 5, 6 },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(io, "image.data", &path_buf)];

    // Room for the canonical path buffer, not for a 1 MiB read.
    var limited: LimitedAllocator = .init(testing.allocator, 256 * 1024);
    const alloc = limited.allocator();

    const cases = [_]struct {
        offset: u32,
        size: u32,
        expected: ?[3]u8,
    }{
        .{ .offset = 3, .size = 1024 * 1024, .expected = null },
        .{ .offset = 7, .size = 3, .expected = null },
        .{ .offset = 3, .size = 3, .expected = .{ 4, 5, 6 } },
    };
    for (cases) |case| {
        var cmd: command.Command = .{
            .control = .{ .transmit = .{
                .format = .rgb,
                .medium = .file,
                .width = 1,
                .height = 1,
                .size = case.size,
                .offset = case.offset,
                .image_id = 31,
            } },
            .data = try alloc.dupe(u8, path),
        };
        defer cmd.deinit(alloc);

        const expected = case.expected orelse {
            try testing.expectError(error.InvalidData, LoadingImage.init(io, alloc, &cmd, test_file_limits));
            continue;
        };
        var loading = try LoadingImage.init(io, alloc, &cmd, test_file_limits);
        defer loading.deinit(alloc);
        try testing.expectEqualSlices(u8, &expected, loading.data.items);
    }
    try testing.expect(!limited.limit_exceeded);
}
