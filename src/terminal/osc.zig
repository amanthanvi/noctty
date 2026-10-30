//! OSC (Operating System Command) related functions and types.
//!
//! OSC is another set of control sequences for terminal programs that start with
//! "ESC ]". Unlike CSI or standard ESC sequences, they may contain strings
//! and other irregular formatting so a dedicated parser is created to handle it.
const osc = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const mem = std.mem;
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = mem.Allocator;
const lib = @import("lib.zig");
const LibEnum = lib.Enum;
const kitty_color = @import("kitty/color.zig");
const parsers = @import("osc/parsers.zig");
const encoding = @import("osc/encoding.zig");
const terminator = @import("osc/terminator.zig");
const progress_report = @import("../progress_report.zig");

pub const color = parsers.color;
pub const semantic_prompt = parsers.semantic_prompt;
pub const program_status = parsers.program_status;

const log = std.log.scoped(.osc);

pub const Command = union(Key) {
    /// This generally shouldn't ever be set except as an initial zero value.
    /// Ignore it.
    invalid,

    /// Set the window title of the terminal
    ///
    /// If title mode 0 is set text is expect to be hex encoded (i.e. utf-8
    /// with each code unit further encoded with two hex digits).
    ///
    /// If title mode 2 is set or the terminal is setup for unconditional
    /// utf-8 titles text is interpreted as utf-8. Else text is interpreted
    /// as latin1.
    change_window_title: [:0]const u8,

    /// Set the icon of the terminal window. The name of the icon is not
    /// well defined, so this is currently ignored by Ghostty at the time
    /// of writing this. We just parse it so that we don't get parse errors
    /// in the log.
    change_window_icon: [:0]const u8,

    /// Semantic prompt command: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
    semantic_prompt: SemanticPrompt,

    /// Set or get clipboard contents. If data is null, then the current
    /// clipboard contents are sent to the pty. If data is set, this
    /// contents is set on the clipboard.
    clipboard_contents: struct {
        kind: u8,
        data: [:0]const u8,
    },

    /// OSC 7. Reports the current working directory of the shell. This is
    /// a moderately flawed escape sequence but one that many major terminals
    /// support so we also support it. To understand the flaws, read through
    /// this terminal-wg issue: https://gitlab.freedesktop.org/terminal-wg/specifications/-/issues/20
    report_pwd: struct {
        /// The reported pwd value. This is not checked for validity. It should
        /// be a file URL but it is up to the caller to utilize this value.
        value: [:0]const u8,

        /// The report came from ConEmu's OSC 9;9, whose value is usually a
        /// plain path (`C:\Users\me`, possibly in double quotes) and carries
        /// no host, unlike OSC 7's file URL.
        conemu: bool = false,
    },

    /// OSC 22. Set the mouse shape. There doesn't seem to be a standard
    /// naming scheme for cursors but it looks like terminals such as Foot
    /// are moving towards using the W3C CSS cursor names. For OSC parsing,
    /// we just parse whatever string is given.
    mouse_shape: struct {
        value: [:0]const u8,
    },

    /// OSC color operations to set, reset, or report color settings. Some OSCs
    /// allow multiple operations to be specified in a single OSC so we need a
    /// list-like datastructure to manage them. We use std.SegmentedList because
    /// it minimizes the number of allocations and copies because a large
    /// majority of the time there will be only one operation per OSC.
    ///
    /// Currently, these OSCs are handled by `color_operation`:
    ///
    /// 4, 5, 10-19, 104, 105, 110-119
    color_operation: struct {
        op: color.Operation,
        requests: color.List = .{},
        terminator: Terminator = .st,
    },

    /// Kitty color protocol, OSC 21
    /// https://sw.kovidgoyal.net/kitty/color-stack/#id1
    kitty_color_protocol: kitty_color.OSC,

    /// Show a desktop notification (OSC 9 or OSC 777)
    show_desktop_notification: struct {
        title: [:0]const u8,
        body: [:0]const u8,
    },

    /// Start a hyperlink (OSC 8)
    hyperlink_start: struct {
        id: ?[:0]const u8 = null,
        uri: [:0]const u8,
    },

    /// End a hyperlink (OSC 8)
    hyperlink_end: void,

    /// ConEmu sleep (OSC 9;1)
    conemu_sleep: struct {
        duration_ms: u16,
    },

    /// ConEmu show GUI message box (OSC 9;2)
    conemu_show_message_box: [:0]const u8,

    /// ConEmu change tab title (OSC 9;3)
    conemu_change_tab_title: union(enum) {
        reset,
        value: [:0]const u8,
    },

    /// ConEmu progress report (OSC 9;4)
    conemu_progress_report: ProgressReport,

    /// ConEmu wait input (OSC 9;5)
    conemu_wait_input,

    /// ConEmu GUI macro (OSC 9;6)
    conemu_guimacro: [:0]const u8,

    /// ConEmu run process (OSC 9;7)
    conemu_run_process: [:0]const u8,

    /// ConEmu output environment variable (OSC 9;8)
    conemu_output_environment_variable: [:0]const u8,

    /// ConEmu XTerm keyboard and output emulation (OSC 9;10)
    /// https://conemu.github.io/en/TerminalModes.html
    conemu_xterm_emulation: struct {
        /// null => do not change
        /// false => turn off
        /// true => turn on
        keyboard: ?bool,
        /// null => do not change
        /// false => turn off
        /// true => turn on
        output: ?bool,
    },

    /// ConEmu comment (OSC 9;11)
    conemu_comment: [:0]const u8,

    /// Kitty text sizing protocol (OSC 66)
    kitty_text_sizing: parsers.kitty_text_sizing.OSC,

    kitty_clipboard_protocol: KittyClipboardProtocol,

    /// OSC 3008. Hierarchical context signalling (UAPI spec).
    /// https://uapi-group.org/specifications/specs/osc_context/
    context_signal: parsers.context_signal.Command,

    /// Program status protocol (OSC 7501). A program reports what it is
    /// doing, such as working or waiting on the user, or asks whether the
    /// terminal supports the protocol. See `ProgramStatus`.
    program_status: ProgramStatus,

    pub const SemanticPrompt = parsers.semantic_prompt.Command;

    pub const KittyClipboardProtocol = parsers.kitty_clipboard_protocol.OSC;

    pub const ProgramStatus = parsers.program_status.Command;

    pub const Key = LibEnum(
        lib.target,
        // NOTE: Order matters, see LibEnum documentation.
        &.{
            "invalid",
            "change_window_title",
            "change_window_icon",
            "semantic_prompt",
            "clipboard_contents",
            "report_pwd",
            "mouse_shape",
            "color_operation",
            "kitty_color_protocol",
            "show_desktop_notification",
            "hyperlink_start",
            "hyperlink_end",
            "conemu_sleep",
            "conemu_show_message_box",
            "conemu_change_tab_title",
            "conemu_progress_report",
            "conemu_wait_input",
            "conemu_guimacro",
            "conemu_run_process",
            "conemu_output_environment_variable",
            "conemu_xterm_emulation",
            "conemu_comment",
            "kitty_text_sizing",
            "kitty_clipboard_protocol",
            "context_signal",
            "program_status",
        },
    );

    pub const ProgressReport = progress_report.Report;

    comptime {
        assert(@sizeOf(Command) == switch (@sizeOf(usize)) {
            4 => 44,
            8 => 64,
            else => unreachable,
        });
    }
};

test "ghostty.h Command.ProgressReport.State" {
    if (comptime build_options.artifact == .lib) return error.SkipZigTest;
    try lib.checkGhosttyHEnum(Command.ProgressReport.State, "GHOSTTY_PROGRESS_STATE_");
}

pub const Terminator = terminator.Terminator;

pub const Parser = struct {
    /// Maximum size of a "normal" OSC.
    pub const MAX_BUF = 2048;

    /// Maximum size of an OSC that requires dynamically allocated storage.
    /// OSC input is untrusted, so these captures must have a finite bound.
    /// OSC 52 is the large one: a program setting the clipboard can send
    /// 8 MiB of base64, a 6 MiB clipboard. The largest clipboard measured
    /// going through a program and back on Windows was a 933 KB reply, so
    /// writing it back stays far below this.
    pub const MAX_ALLOCATING_BUF = 8 * 1024 * 1024;

    /// Optional allocator used to accept data longer than MAX_BUF.
    /// This only applies to some commands (e.g. OSC 52) that can
    /// reasonably exceed MAX_BUF.
    alloc: ?Allocator,

    /// Maximum number of bytes retained by an allocating capture.
    /// This is configurable primarily so callers and tests can choose a
    /// smaller policy than the default.
    max_allocating_bytes: usize,

    /// Current state of the parser.
    state: State,

    /// Buffer for temporary storage of OSC data
    buffer: [MAX_BUF]u8,

    /// Capture state. If this is set then we're actively capturing the
    /// bytes coming into the parser.
    capture: ?Capture,

    /// The command that is the result of parsing.
    command: Command,

    pub const State = enum {
        start,
        invalid,

        // OSC command prefixes. Not all of these are valid OSCs, but may be
        // needed to "bridge" to a valid OSC (e.g. to support OSC 777 we need to
        // have a state "77" even though there is no OSC 77).
        @"0",
        @"1",
        @"2",
        @"3",
        @"4",
        @"5",
        @"6",
        @"7",
        @"8",
        @"9",
        @"30",
        @"300",
        @"3008",
        @"10",
        @"11",
        @"12",
        @"13",
        @"14",
        @"15",
        @"16",
        @"17",
        @"18",
        @"19",
        @"21",
        @"22",
        @"52",
        @"55",
        @"66",
        @"75",
        @"750",
        @"7501",
        @"77",
        @"104",
        @"110",
        @"111",
        @"112",
        @"113",
        @"114",
        @"115",
        @"116",
        @"117",
        @"118",
        @"119",
        @"133",
        @"552",
        @"777",
        @"1337",
        @"5522",
    };

    pub fn init(alloc: ?Allocator) Parser {
        var result: Parser = .{
            .alloc = alloc,
            .max_allocating_bytes = MAX_ALLOCATING_BUF,
            .state = .start,
            .capture = null,
            .command = .invalid,

            // Keeping all our undefined values together so we can
            // visually easily duplicate them in the Valgrind check below.
            .buffer = undefined,
        };
        if (std.valgrind.runningOnValgrind() > 0) {
            // Initialize our undefined fields so Valgrind can catch it.
            // https://github.com/ziglang/zig/issues/19148
            result.buffer = undefined;
        }

        return result;
    }

    /// This must be called to clean up any allocated memory.
    pub fn deinit(self: *Parser) void {
        self.reset();
    }

    /// Reset the parser state.
    pub fn reset(self: *Parser) void {
        // If we're capturing, then stop it.
        if (self.capture) |*cap| cap.deinit();

        // Handle any cleanup that individual OSCs require.
        switch (self.command) {
            .kitty_color_protocol => |*v| kitty_color_protocol: {
                v.deinit(self.alloc orelse break :kitty_color_protocol);
            },
            .color_operation => |*v| color_operation: {
                v.requests.deinit(self.alloc orelse break :color_operation);
            },
            .change_window_icon,
            .change_window_title,
            .clipboard_contents,
            .conemu_change_tab_title,
            .conemu_comment,
            .conemu_guimacro,
            .conemu_output_environment_variable,
            .conemu_progress_report,
            .conemu_run_process,
            .conemu_show_message_box,
            .conemu_sleep,
            .conemu_wait_input,
            .conemu_xterm_emulation,
            .hyperlink_end,
            .hyperlink_start,
            .invalid,
            .mouse_shape,
            .report_pwd,
            .semantic_prompt,
            .show_desktop_notification,
            .kitty_text_sizing,
            .kitty_clipboard_protocol,
            .context_signal,
            .program_status,
            => {},
        }

        self.state = .start;
        self.capture = null;
        self.command = .invalid;

        if (std.valgrind.runningOnValgrind() > 0) {
            // Initialize our undefined fields so Valgrind can catch it.
            // https://github.com/ziglang/zig/issues/19148
            self.buffer = undefined;
        }
    }

    /// Make sure that we have an allocator. If we don't, set the state to
    /// invalid so that any additional OSC data is discarded.
    inline fn ensureAllocator(self: *Parser) bool {
        if (self.alloc != null) return true;
        log.warn("An allocator is required to process OSC {t} but none was provided.", .{self.state});
        self.state = .invalid;
        return false;
    }

    const Capture = struct {
        writer: *std.Io.Writer,
        backing: Backing,

        /// The most bytes to capture. One more byte makes the sequence
        /// invalid. A command can lower it after the capture starts.
        max_bytes: usize,

        const Backing = union(enum) {
            fixed: std.Io.Writer,
            allocating: std.Io.Writer.Allocating,
        };

        const Mode = enum {
            fixed,
            allocating,
        };

        pub inline fn fixed(new: *?Capture, buf: []u8) void {
            new.* = .{
                .backing = .{ .fixed = .fixed(buf) },
                .writer = &new.*.?.backing.fixed,
                .max_bytes = buf.len,
            };
        }

        pub inline fn allocating(
            new: *?Capture,
            alloc: Allocator,
            max_bytes: usize,
        ) error{OutOfMemory}!void {
            new.* = .{
                .backing = .{ .allocating = try std.Io.Writer.Allocating.initCapacity(
                    alloc,
                    @min(MAX_BUF, max_bytes),
                ) },
                .writer = &new.*.?.backing.allocating.writer,
                .max_bytes = max_bytes,
            };
        }

        /// Append one byte without permitting the backing allocation to grow
        /// beyond max_bytes. Allocating.Writer normally grows super-linearly,
        /// so grow it explicitly to keep the allocation itself bounded too.
        pub inline fn writeByte(self: *Capture, byte: u8) error{WriteFailed}!void {
            if (self.writer.buffered().len >= self.max_bytes) return error.WriteFailed;

            switch (self.backing) {
                .fixed => {},
                .allocating => |*w| {
                    if (w.writer.end >= w.writer.buffer.len) {
                        const new_capacity = @min(
                            self.max_bytes,
                            @max(w.writer.buffer.len *| 2, 1),
                        );
                        w.writer.buffer = w.allocator.realloc(
                            w.writer.buffer,
                            new_capacity,
                        ) catch return error.WriteFailed;
                    }
                },
            }

            try self.writer.writeByte(byte);
        }

        pub fn deinit(self: *Capture) void {
            switch (self.backing) {
                .fixed => {},
                .allocating => |*w| w.deinit(),
            }
        }

        /// Return the captured trailing data. This is the data from the
        /// point that trailing data capture was requested.
        pub inline fn trailing(self: *Capture) []u8 {
            return self.writer.buffered();
        }
    };

    /// Begin capturing trailing data. All inputs to next from this point
    /// forward will be captured into the `self.capture.writer` buffer
    /// which may be backed by either a fixed size or allocating buffer
    /// depending on mode.
    ///
    /// Get the trailing data using `capture.trailing()`. Do not access
    /// the writer directly.
    inline fn captureTrailing(
        self: *Parser,
        comptime mode: Capture.Mode,
    ) void {
        assert(self.capture == null);
        switch (mode) {
            .fixed => Capture.fixed(
                &self.capture,
                &self.buffer,
            ),

            .allocating => {
                const alloc = self.alloc orelse {
                    // We don't have an allocator - fall back to a fixed buffer and hope
                    // that it's big enough.
                    self.captureTrailing(.fixed);
                    return;
                };

                Capture.allocating(
                    &self.capture,
                    alloc,
                    self.max_allocating_bytes,
                ) catch {
                    // The allocator failed for some reason, fall back to a fixed buffer
                    // and hope that it's big enough.
                    self.captureTrailing(.fixed);
                    return;
                };
            },
        }
    }

    /// Consume a slice of bytes, advancing the parser state. This is
    /// equivalent to calling `next` for each byte in order.
    pub fn nextSlice(self: *Parser, input: []const u8) void {
        for (input) |c| self.next(c);
    }

    /// Consume the next character c and advance the parser state.
    pub fn next(self: *Parser, c: u8) void {
        // If the state becomes invalid for any reason, just discard
        // any further input.
        if (self.state == .invalid) return;

        // If a writer has been initialized, we just accumulate the rest of the
        // OSC sequence in the writer's buffer and skip the state machine.
        if (self.capture) |*cap| {
            cap.writeByte(c) catch |err| switch (err) {
                // We have overflowed our buffer or had some other error, set the
                // state to invalid so that we discard any further input.
                error.WriteFailed => {
                    // Say so once for a sequence an allocating capture
                    // could hold but its limit doesn't (a huge clipboard
                    // write, say), since it is dropped without a trace.
                    if (cap.backing == .allocating and cap.trailing().len >= cap.max_bytes) {
                        log.warn("OSC {t} is longer than {d} bytes, ignoring it", .{ self.state, cap.max_bytes });
                    }

                    // The rest of the sequence is discarded, so nothing
                    // needs what was captured.
                    self.dropCapture();
                    self.state = .invalid;
                },
            };
            return;
        }

        switch (self.state) {
            // handled above, so should never be here
            .invalid => unreachable,

            .start => switch (c) {
                '0' => self.state = .@"0",
                '1' => self.state = .@"1",
                '2' => self.state = .@"2",
                '3' => self.state = .@"3",
                '4' => self.state = .@"4",
                '5' => self.state = .@"5",
                '6' => self.state = .@"6",
                '7' => self.state = .@"7",
                '8' => self.state = .@"8",
                '9' => self.state = .@"9",
                else => self.state = .invalid,
            },

            .@"3" => switch (c) {
                '0' => self.state = .@"30",
                else => self.state = .invalid,
            },

            .@"30" => switch (c) {
                '0' => self.state = .@"300",
                else => self.state = .invalid,
            },

            .@"300" => switch (c) {
                '8' => self.state = .@"3008",
                else => self.state = .invalid,
            },

            .@"3008" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.state = .invalid,
            },

            .@"1" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '0' => self.state = .@"10",
                '1' => self.state = .@"11",
                '2' => self.state = .@"12",
                '3' => self.state = .@"13",
                '4' => self.state = .@"14",
                '5' => self.state = .@"15",
                '6' => self.state = .@"16",
                '7' => self.state = .@"17",
                '8' => self.state = .@"18",
                '9' => self.state = .@"19",
                else => self.state = .invalid,
            },

            .@"10" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '4' => self.state = .@"104",
                else => self.state = .invalid,
            },

            .@"104" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                else => self.state = .invalid,
            },

            .@"11" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '0' => self.state = .@"110",
                '1' => self.state = .@"111",
                '2' => self.state = .@"112",
                '3' => self.state = .@"113",
                '4' => self.state = .@"114",
                '5' => self.state = .@"115",
                '6' => self.state = .@"116",
                '7' => self.state = .@"117",
                '8' => self.state = .@"118",
                '9' => self.state = .@"119",
                else => self.state = .invalid,
            },

            .@"4",
            .@"12",
            .@"14",
            .@"15",
            .@"16",
            .@"17",
            .@"18",
            .@"19",
            .@"21",
            .@"110",
            .@"111",
            .@"112",
            .@"113",
            .@"114",
            .@"115",
            .@"116",
            .@"117",
            .@"118",
            .@"119",
            => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                else => self.state = .invalid,
            },

            .@"13" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '3' => self.state = .@"133",
                else => self.state = .invalid,
            },

            .@"2" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '1' => self.state = .@"21",
                '2' => self.state = .@"22",
                else => self.state = .invalid,
            },

            .@"5" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '2' => self.state = .@"52",
                '5' => self.state = .@"55",
                else => self.state = .invalid,
            },

            .@"6" => switch (c) {
                '6' => self.state = .@"66",
                else => self.state = .invalid,
            },

            .@"52",
            .@"66",
            => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.state = .invalid,
            },

            .@"55" => switch (c) {
                '2' => self.state = .@"552",
                else => self.state = .invalid,
            },

            .@"7" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '5' => self.state = .@"75",
                '7' => self.state = .@"77",
                else => self.state = .invalid,
            },

            .@"75" => switch (c) {
                '0' => self.state = .@"750",
                else => self.state = .invalid,
            },

            .@"750" => switch (c) {
                '1' => self.state = .@"7501",
                else => self.state = .invalid,
            },

            .@"7501" => switch (c) {
                ';' => {
                    self.captureTrailing(.allocating);
                    const cap = &self.capture.?;
                    cap.max_bytes = @min(cap.max_bytes, parsers.program_status.max_body_bytes);
                },
                else => self.state = .invalid,
            },

            .@"77" => switch (c) {
                '7' => self.state = .@"777",
                else => self.state = .invalid,
            },

            .@"133",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '7' => self.state = .@"1337",
                else => self.state = .invalid,
            },

            .@"552" => switch (c) {
                '2' => self.state = .@"5522",
                else => self.state = .invalid,
            },

            .@"1337",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.state = .invalid,
            },

            .@"5522",
            => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.state = .invalid,
            },

            .@"0",
            .@"22",
            .@"777",
            .@"8",
            .@"9",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.state = .invalid,
            },
        }
    }

    /// End the sequence and return the command, if any. If the return value
    /// is null, then no valid command was found. The optional terminator_ch
    /// is the final character in the OSC sequence. This is used to determine
    /// the response terminator.
    ///
    /// A program can also cancel a sequence partway through by sending CAN
    /// or SUB instead of a terminator. The VT parser passes that byte as
    /// `terminator_ch`, and the sequence is then discarded whatever command
    /// it contained, as xterm does.
    ///
    /// The returned pointer is only valid until the next call to the parser.
    /// Callers should copy out any data they wish to retain across calls.
    pub fn end(self: *Parser, terminator_ch: ?u8) ?*Command {
        const command = self.endCommand(terminator_ch);

        // A sequence that yields no command needs nothing it captured, so
        // free that now rather than at the next OSC, which may never come:
        // a rejected clipboard write would otherwise hold up to 8 MiB.
        if (command == null) self.dropCapture();
        return command;
    }

    /// Free and forget the capture, if there is one.
    inline fn dropCapture(self: *Parser) void {
        if (self.capture) |*cap| cap.deinit();
        self.capture = null;
    }

    fn endCommand(self: *Parser, terminator_ch: ?u8) ?*Command {
        if (terminator_ch) |ch| switch (ch) {
            std.ascii.control_code.can,
            std.ascii.control_code.sub,
            => return null,
            else => {},
        };

        return switch (self.state) {
            .start => null,

            .invalid => null,

            .@"0",
            .@"2",
            => parsers.change_window_title.parse(self, terminator_ch),

            .@"1" => parsers.change_window_icon.parse(self, terminator_ch),

            .@"4",
            .@"5",
            .@"10",
            .@"11",
            .@"12",
            .@"13",
            .@"14",
            .@"15",
            .@"16",
            .@"17",
            .@"18",
            .@"19",
            .@"104",
            .@"110",
            .@"111",
            .@"112",
            .@"113",
            .@"114",
            .@"115",
            .@"116",
            .@"117",
            .@"118",
            .@"119",
            => parsers.color.parse(self, terminator_ch),

            .@"7" => parsers.report_pwd.parse(self, terminator_ch),

            .@"8" => parsers.hyperlink.parse(self, terminator_ch),

            .@"9" => parsers.osc9.parse(self, terminator_ch),

            .@"21" => parsers.kitty_color.parse(self, terminator_ch),

            .@"22" => parsers.mouse_shape.parse(self, terminator_ch),

            .@"52" => parsers.clipboard_operation.parse(self, terminator_ch),

            .@"55" => null,

            .@"3",
            .@"30",
            .@"300",
            => null,

            .@"3008" => parsers.context_signal.parse(self, terminator_ch),

            .@"6" => null,

            .@"66" => parsers.kitty_text_sizing.parse(self, terminator_ch),

            .@"75",
            .@"750",
            => null,

            .@"7501" => parsers.program_status.parse(self, terminator_ch),

            .@"77" => null,

            .@"133" => parsers.semantic_prompt.parse(self, terminator_ch),

            .@"552" => null,

            .@"777" => parsers.rxvt_extension.parse(self, terminator_ch),

            .@"1337" => parsers.iterm2.parse(self, terminator_ch),

            .@"5522" => parsers.kitty_clipboard_protocol.parse(self, terminator_ch),
        };
    }
};

test {
    _ = parsers;
    _ = encoding;
}

test "Parser end with CAN or SUB cancels the command" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // A fixed capture (OSC 2) cancelled by CAN.
    p.nextSlice("2;title");
    try testing.expect(p.end(std.ascii.control_code.can) == null);

    // An allocating capture (OSC 52) cancelled by SUB.
    p.reset();
    p.nextSlice("52;c;Zm9v");
    try testing.expect(p.end(std.ascii.control_code.sub) == null);

    // The parser still works normally after a cancel.
    p.reset();
    p.nextSlice("2;title");
    const cmd = p.end(std.ascii.control_code.bel).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("title", cmd.change_window_title);
}

test "Parser allocating captures stop at 8 MiB" {
    const testing = std.testing;
    const limit = Parser.MAX_ALLOCATING_BUF;
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024), limit);

    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var p: Parser = .init(counting.allocator());
    defer p.deinit();
    try testing.expectEqual(limit, p.max_allocating_bytes);

    p.nextSlice("52;");
    for (0..limit) |_| p.next('a');

    const cap = &p.capture.?;
    try testing.expectEqual(@as(usize, limit), cap.trailing().len);
    try testing.expect(cap.writer.buffer.len <= limit);

    // One byte more drops the sequence and frees what it held.
    p.next('a');
    try testing.expectEqual(Parser.State.invalid, p.state);
    try testing.expect(p.capture == null);
    try testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}

test "Parser allocating captures have a hard limit" {
    const testing = std.testing;
    const prefixes = [_][]const u8{ "52;", "66;", "5522;" };
    const limit = Parser.MAX_BUF + 1;

    for (prefixes) |prefix| {
        var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var p: Parser = .init(counting.allocator());
        defer p.deinit();
        p.max_allocating_bytes = limit;

        p.nextSlice(prefix);
        for (0..limit) |_| p.next('a');

        const cap = &p.capture.?;
        try testing.expectEqual(@as(usize, limit), cap.trailing().len);
        try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);

        p.next('a');
        try testing.expectEqual(Parser.State.invalid, p.state);
        try testing.expect(p.capture == null);
        try testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);

        // The rest of the sequence, and its end, cost nothing.
        for (0..limit) |_| p.next('a');
        try testing.expect(p.end(null) == null);
        try testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
    }
}

test "Parser allocating capture limit includes parser-added bytes" {
    const testing = std.testing;
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var p: Parser = .init(counting.allocator());
    defer p.deinit();
    p.max_allocating_bytes = 4;

    p.nextSlice("52;abcd");
    {
        const cap = &p.capture.?;
        try testing.expectEqual(@as(usize, 4), cap.trailing().len);
        try testing.expectEqual(@as(usize, 4), cap.writer.buffer.len);
    }

    // The terminating NUL the clipboard parser adds does not fit, so the
    // command is rejected and its capture freed.
    try testing.expect(p.end(null) == null);
    try testing.expectEqual(Parser.State.invalid, p.state);
    try testing.expect(p.capture == null);
    try testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}
