//! What a confirm prompt says: the close prompts, the clipboard prompts a
//! paste or a program raises, the link prompt, and the preview pane's text.
//! Callers hand over facts (what closes and how many terminals it ends, the
//! tab that asked, the app a link opens in) and get a `Prompt`, which
//! `Host.showConfirm` copies. Nothing here touches a window.
const std = @import("std");
const Allocator = std.mem.Allocator;
const paint_text = @import("text.zig");

const DecodedCodepoint = paint_text.DecodedCodepoint;
const codepointWidth = paint_text.codepointWidth;
const decodeCodepoint = paint_text.decodeCodepoint;

/// What a caller is asking the user to approve. A struct rather than
/// positional arguments because every string field has the same type:
/// swapping `title` and `accept_label` used to compile cleanly. Borrows
/// the caller's strings; `showConfirm` copies what it keeps.
pub const Prompt = struct {
    title: []const u8,
    body: []const u8,
    accept_label: []const u8,
    cancel_label: []const u8 = "Cancel",
    /// The payload this prompt is about, rendered verbatim in the
    /// preview pane. Null for prompts with nothing to show, such as
    /// the close-surface prompt.
    contents: ?[]const u8 = null,
    /// A program in the terminal asked (an OSC 52 clipboard read or
    /// write), not the user. It can send the request right after a key it
    /// read, so the user's next key lands on the prompt: such a prompt
    /// opens on Cancel, ignores Allow for its first
    /// `program_confirm_arming_ms`, and never replaces an open prompt.
    /// A link prompt (`Words.link`) sets it too, but the user's click
    /// raises it, so it replaces an open prompt.
    program_request: bool = false,
};

/// What a close that ends several terminals at once is closing. One pane
/// keeps its own prompt (`Closing.terminal`).
pub const CloseScope = enum { window, this_tab, other_tabs, right_tabs, app, update };

/// A tab as the tab strip shows it: its number (from 1) and title.
pub const TabRef = struct { number: usize, title: ?[]const u8 };

/// A tab, or a terminal's tab, that is not the one in front (`behind`) is
/// named by its number and title, as the OSC 52 prompt names the tab that
/// asked.
pub const Closing = union(enum) {
    /// A close that would end `terminals` (at least 1) terminals that
    /// `confirm-close-surface` asks about.
    scope: struct {
        scope: CloseScope,
        terminals: usize,
        /// Only `.this_tab` has words for a tab behind: a tab closed from
        /// its button need not be the one in front. The other scopes run
        /// from the tab in front or have no tab.
        behind: ?TabRef = null,
    },
    /// One terminal (`Surface.close`). A read-only terminal asks before it
    /// closes even when its program has exited and it closes by itself,
    /// whatever tab it is in.
    terminal: struct { program_exited: bool = false, behind: ?TabRef = null },
};

pub const Clipboard = union(enum) {
    pub const Request = enum { read, write };

    /// The user's own paste (a keybinding, a drop, a quick-select paste)
    /// that paste protection stopped.
    user_paste: []const u8,
    /// A program's OSC 52 read or write has its own wording, so the prompt
    /// cannot be taken for the one the user's own unsafe paste raises, and
    /// it names the tab that asked.
    program: struct { request: Request, contents: ?[]const u8, asked_by: TabRef },
};

/// What Windows says opens a link's scheme, for `Words.link`.
pub const LinkHandler = union(enum) {
    /// The app's name, one whole line of plain text.
    app: []const u8,
    /// An app is set, but Windows gave no name that can be shown.
    unnamed,
    /// No app is set for the scheme (ERROR_NO_ASSOCIATION).
    none,
};

/// Where a prompt's words live until `showConfirm` has copied them: the
/// returned `Prompt` borrows these buffers and the body this owns. One
/// `Words` per prompt; `deinit` it after the call.
pub const Words = struct {
    title_buf: [32]u8 = undefined,
    body_buf: [256]u8 = undefined,
    owned: ?[]u8 = null,

    pub fn deinit(self: *Words, alloc: Allocator) void {
        if (self.owned) |body| alloc.free(body);
    }

    /// Never fails: with no memory for the body that names a tab behind,
    /// the prompt keeps its numbered title and the plain body.
    pub fn close(self: *Words, alloc: Allocator, what: Closing) Prompt {
        switch (what) {
            .scope => |closing| {
                var prompt = scopePrompt(closing.scope, closing.terminals, &self.body_buf);
                if (closing.scope == .this_tab) if (closing.behind) |tab| self.nameTab(
                    &prompt,
                    std.fmt.bufPrint(&self.title_buf, "Close tab {d}?", .{tab.number}) catch "Close a tab?",
                    backgroundTabBody(alloc, closing.terminals, tab),
                );
                return prompt;
            },
            .terminal => |terminal| {
                var prompt: Prompt = .{
                    .title = "Close this terminal?",
                    // Read-only mode is why a terminal whose program has
                    // exited still asks, in front as behind.
                    .body = if (terminal.program_exited)
                        "The program has exited. Read-only mode makes closing this terminal ask first."
                    else
                        "A process is still running. Closing this surface will terminate it.",
                    .accept_label = "Close",
                };
                if (terminal.behind) |tab| self.nameTab(
                    &prompt,
                    std.fmt.bufPrint(&self.title_buf, "Close terminal in tab {d}?", .{tab.number}) catch "Close a terminal?",
                    backgroundTerminalBody(alloc, tab, terminal.program_exited),
                );
                return prompt;
            },
        }
    }

    /// Sets `contents` and, for a program's request, `program_request`.
    pub fn clipboard(self: *Words, alloc: Allocator, what: Clipboard) Allocator.Error!Prompt {
        return switch (what) {
            .user_paste => |contents| .{
                .title = "Allow clipboard paste?",
                .body = "noctty needs confirmation before completing this clipboard paste.",
                .accept_label = "Allow",
                .contents = contents,
            },
            .program => |program| .{
                .title = switch (program.request) {
                    .read => "Let a program read your clipboard?",
                    .write => "Let a program change your clipboard?",
                },
                .body = self.keep(try programClipboardBody(alloc, program.request, program.asked_by)),
                .accept_label = "Allow",
                .contents = program.contents,
                .program_request = true,
            },
        };
    }

    /// The prompt a link from terminal output raises before it opens
    /// (`App.askBeforeOpeningLink`): the checked `url` in the preview
    /// pane, and the app its `scheme` opens in. Upstream's alert defaults
    /// to Cancel, so this is a `program_request` prompt.
    pub fn link(
        self: *Words,
        alloc: Allocator,
        what: struct { url: []const u8, scheme: []const u8, handler: LinkHandler },
    ) Allocator.Error!Prompt {
        return .{
            .title = "Open link from terminal output?",
            .body = self.keep(try linkBody(alloc, what.handler, what.scheme)),
            .accept_label = "Open link",
            .contents = what.url,
            .program_request = true,
        };
    }

    /// Names a tab behind the front one in `prompt`. The title needs no
    /// memory, so it names the tab even when `body` could not be made, and
    /// the prompt then keeps its plain body.
    fn nameTab(self: *Words, prompt: *Prompt, title: []const u8, body: Allocator.Error![]u8) void {
        prompt.title = title;
        prompt.body = self.keep(body catch return);
    }

    /// Takes `body`, which `deinit` frees, for the prompt to borrow.
    fn keep(self: *Words, body: []u8) []u8 {
        // One `Words` per prompt: a second body would leak the first.
        std.debug.assert(self.owned == null);
        self.owned = body;
        return body;
    }
};

/// The prompt for a close that would end `count` (at least 1) terminals
/// that `confirm-close-surface` asks about. The body may live in `body_buf`.
fn scopePrompt(scope: CloseScope, count: usize, body_buf: *[256]u8) Prompt {
    switch (scope) {
        inline else => |comptime_scope| {
            const text: struct { title: []const u8, accept: []const u8, one: []const u8, many: []const u8 } = comptime switch (comptime_scope) {
                .window => .{
                    .title = "Close this window?",
                    .accept = "Close",
                    .one = "A process is still running in this window. Closing the window will terminate it.",
                    .many = "Processes are still running in {d} terminals in this window. Closing the window will terminate them.",
                },
                .this_tab => .{
                    .title = "Close this tab?",
                    .accept = "Close tab",
                    .one = "A process is still running in this tab. Closing the tab will terminate it, and undo is off.",
                    .many = "Processes are still running in {d} terminals in this tab. Closing the tab will terminate them, and undo is off.",
                },
                .other_tabs => .{
                    .title = "Close the other tabs?",
                    .accept = "Close tabs",
                    .one = "A process is still running in another tab. Closing the other tabs will terminate it.",
                    .many = "Processes are still running in {d} terminals in the other tabs. Closing those tabs will terminate them.",
                },
                .right_tabs => .{
                    .title = "Close the tabs to the right?",
                    .accept = "Close tabs",
                    .one = "A process is still running in a tab to the right. Closing those tabs will terminate it.",
                    .many = "Processes are still running in {d} terminals in the tabs to the right. Closing those tabs will terminate them.",
                },
                .app => .{
                    .title = "Quit noctty?",
                    .accept = "Quit",
                    .one = "A process is still running. Quitting noctty will terminate it.",
                    .many = "Processes are still running in {d} terminals. Quitting noctty will terminate them.",
                },
                .update => .{
                    .title = "Install the update?",
                    .accept = "Install",
                    .one = "A process is still running. Installing the update closes noctty and will terminate it.",
                    .many = "Processes are still running in {d} terminals. Installing the update closes noctty and will terminate them.",
                },
            };
            return .{
                .title = text.title,
                .body = if (count <= 1) text.one else std.fmt.bufPrint(body_buf, text.many, .{count}) catch text.one,
                .accept_label = text.accept,
            };
        },
    }
}

/// Cells, and code points, of the tab title a prompt quotes.
const program_prompt_title_width = 24;

/// A tab as a prompt names it, by its number and title as the tab strip
/// shows them: `Tab 2 (vim)`. The title is the program's own text, so it may
/// not crowd out or disguise the words around it: it is cut to
/// `program_prompt_title_width` cells and as many code points (zero-width
/// marks take no cell, and stacked they draw over the line), and controls,
/// line and paragraph separators, and bidirectional formatting characters
/// (which would reorder the words after it; see `isBidiFormatting`) become
/// U+FFFD. Any prompt that can come from a tab other than the one in front
/// names it this way.
fn promptTabName(alloc: Allocator, tab: TabRef) ![]u8 {
    const raw = tab.title orelse "noctty";
    const limit = program_prompt_title_width;
    var title: std.ArrayListUnmanaged(u8) = .empty;
    defer title.deinit(alloc);
    var cells: usize = 0;
    var count: usize = 0;
    // Where "..." goes if the title turns out not to fit.
    var cut: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const decoded = decodeCodepoint(raw, i) orelse DecodedCodepoint{ .cp = 0xFFFD, .len = 1 };
        i += decoded.len;
        const cp = switch (decoded.cp) {
            0...0x1F, 0x7F...0x9F, 0x2028, 0x2029 => 0xFFFD, // controls, line and paragraph separators
            else => if (isBidiFormatting(decoded.cp)) 0xFFFD else decoded.cp,
        };
        cells += codepointWidth(cp);
        count += 1;
        if (cells > limit or count > limit) {
            title.shrinkRetainingCapacity(cut);
            try title.appendSlice(alloc, "...");
            break;
        }
        try appendCodepoint(alloc, &title, cp);
        if (cells <= limit - 3 and count <= limit - 3) cut = title.items.len;
    }
    return std.fmt.allocPrint(alloc, "Tab {d} ({s})", .{ tab.number, title.items });
}

/// The body of a program's clipboard prompt, which names the tab that asked.
fn programClipboardBody(alloc: Allocator, request: Clipboard.Request, tab: TabRef) ![]u8 {
    const name = try promptTabName(alloc, tab);
    defer alloc.free(name);
    return switch (request) {
        .read => std.fmt.allocPrint(alloc, "{s} asked to read your clipboard. Allow sends it the text below.", .{name}),
        .write => std.fmt.allocPrint(alloc, "{s} asked to replace your clipboard with the text below.", .{name}),
    };
}

/// The body of the prompt for closing a tab that is not the one in front
/// (`close_tab:this` from its button), for `count` terminals the tab would
/// end, with undo off.
fn backgroundTabBody(alloc: Allocator, count: usize, tab: TabRef) ![]u8 {
    const name = try promptTabName(alloc, tab);
    defer alloc.free(name);
    return if (count <= 1)
        std.fmt.allocPrint(alloc, "A process is still running in {s}. Closing that tab will terminate it, and undo is off.", .{name})
    else
        std.fmt.allocPrint(alloc, "Processes are still running in {d} terminals in {s}. Closing that tab will terminate them, and undo is off.", .{ count, name });
}

/// The same for a terminal that closes by itself in a tab that is not the
/// one in front (a read-only terminal whose program exited asks first).
fn backgroundTerminalBody(alloc: Allocator, tab: TabRef, program_exited: bool) ![]u8 {
    const name = try promptTabName(alloc, tab);
    defer alloc.free(name);
    // Read-only mode is why a terminal whose program has exited still asks.
    return if (program_exited)
        std.fmt.allocPrint(alloc, "The program in {s} has exited. Read-only mode makes closing that terminal ask first.", .{name})
    else
        std.fmt.allocPrint(alloc, "A process is still running in {s}. Closing that terminal will terminate it.", .{name});
}

fn linkBody(alloc: Allocator, handler: LinkHandler, scheme: []const u8) ![]u8 {
    const tail = " Continue only if you trust where it goes.";
    return switch (handler) {
        .app => |name| std.fmt.allocPrint(alloc, "Windows opens it with \u{201C}{s}\u{201D}." ++ tail, .{name}),
        .unnamed => std.fmt.allocPrint(alloc, "Windows opens it with the app set for {s} links." ++ tail, .{scheme}),
        .none => std.fmt.allocPrint(alloc, "No app is set for {s} links; Windows may ask you to pick one." ++ tail, .{scheme}),
    };
}

/// How much of a confirm payload the preview pane renders. A paste can
/// be megabytes; a Win32 EDIT chokes long before that, and nobody reads
/// a megabyte before clicking Allow. Only the DISPLAY is capped — the
/// bytes actually delivered on Accept come from the Surface's pending
/// clipboard op, never from this preview.
const preview_limit: usize = 64 * 1024;

/// A confirm payload rendered for display.
pub const Preview = struct {
    /// UTF-8 that is safe to hand to a Win32 EDIT: always valid
    /// encoding, never contains NUL, never contains bidirectional
    /// formatting characters that could reorder the displayed payload,
    /// and uses CRLF line endings so the control breaks lines where the
    /// payload does. Other control characters pass through and may
    /// render as a box or as nothing; see `previewUpTo`.
    text: []u8,
    /// One line above the pane, so the size of what is being approved is
    /// visible even when the pane only shows its head.
    caption: []u8,
    /// How many source bytes `text` represents.
    shown_bytes: usize,
    /// How many bytes the source had in total.
    total_bytes: usize,

    pub fn truncated(self: Preview) bool {
        return self.shown_bytes < self.total_bytes;
    }

    pub fn deinit(self: *Preview, alloc: Allocator) void {
        alloc.free(self.text);
        alloc.free(self.caption);
        self.* = undefined;
    }
};

/// `contents` as the preview pane shows it, cut to `preview_limit` bytes.
pub fn preview(alloc: Allocator, contents: []const u8) Allocator.Error!Preview {
    return previewUpTo(alloc, contents, preview_limit);
}

/// Unicode bidirectional formatting characters.
///
/// These are invisible and reorder the text around them, so a preview
/// containing them can display something other than what the payload
/// actually says — the precise failure this pane exists to prevent
/// (CVE-2021-42574, "Trojan Source"). Ordinary control characters are
/// left alone: they render as a box or as nothing, but they do not lie
/// about the order of what surrounds them.
///
/// This is a real trade-off, not a pure win: these characters appear in
/// legitimate right-to-left text too, so a genuine RTL payload shows
/// U+FFFD where its directional marks were. The pane's job is to be
/// trustworthy about order rather than pretty, and the substitution is
/// documented in `docs/windows-capability-matrix.md` so the behaviour is
/// not a surprise.
const isBidiFormatting = paint_text.isBidiFormatting;

fn appendCodepoint(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(alloc, buf[0..len]);
}

/// Render `data` for the confirm preview pane, cut to `limit` bytes.
///
/// The payload is shown as it is, matching upstream Ghostty's GTK and
/// macOS confirmation dialogs. Three things are replaced with U+FFFD
/// rather than given an invented glyph, each because showing them
/// literally would defeat the pane instead of serving it:
///
///   - Invalid UTF-8. OSC 52 write payloads are base64-decoded bytes
///     from the terminal and need not be text at all; the UTF-16
///     conversion on the way to the control would fail outright and
///     show nothing at all.
///   - NUL. The control takes a NUL-terminated string, so a literal NUL
///     would silently drop the entire remainder of the payload — the
///     opposite of what a preview is for.
///   - Bidirectional formatting characters. They are invisible and
///     reorder what is displayed, so the pane could show a different
///     reading order than the payload has. See `isBidiFormatting`.
///
/// Line endings are normalised to CRLF for display. A Win32 multiline
/// EDIT breaks a line only on CRLF: a lone LF is zero-width and a lone
/// CR is swallowed, so `ls -l<spaces>\nrm -rf ~` would read as one
/// padded command. LF-only payloads are the common case (VS Code on an
/// LF file, anything routed through WSL, OSC 52 writes) and a newline
/// is precisely what `input.paste.isSafe` raises this prompt for, so
/// the pane must not be the one place it becomes invisible. Only the
/// display text changes; `shown_bytes` still counts source bytes.
///
/// Every other control character, DEL included, is passed through.
fn previewUpTo(
    alloc: Allocator,
    data: []const u8,
    limit: usize,
) Allocator.Error!Preview {
    // Back off so the tail is never a split codepoint — but only for a
    // sequence that STARTS before `end` and crosses it.
    //
    // Walking back on every continuation byte at the boundary looks
    // identical for well-formed text and destroys malformed text: a run
    // of orphan continuation bytes there drags `end` back through all of
    // them, and a payload that is nothing but continuation bytes drags it
    // to zero and shows an empty pane. Those bytes are displayable as
    // U+FFFD, and the reported byte count has to match what is shown.
    var end = @min(limit, data.len);
    if (end < data.len and end > 0) {
        // A UTF-8 sequence is at most 4 bytes, so the lead byte is at
        // most 3 positions back from the last included byte.
        var scan = end;
        var steps: usize = 0;
        while (steps < 4 and scan > 0) : (steps += 1) {
            scan -= 1;
            const lead = data[scan];
            if ((lead & 0xC0) == 0x80) continue; // still inside a sequence
            const seq_len = std.unicode.utf8ByteSequenceLength(lead) catch break;
            // Back off only for a sequence that is actually whole and
            // valid in `data`. A malformed lead byte at the boundary is
            // rendered as U+FFFD like any other, instead of dragging
            // `end` back over the bytes before it.
            if (scan + seq_len > end and scan + seq_len <= data.len) {
                _ = std.unicode.utf8Decode(data[scan .. scan + seq_len]) catch break;
                end = scan;
            }
            break;
        }
    }
    const src = data[0..end];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, src.len);

    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        if (b < 0x80) {
            switch (b) {
                0 => try appendCodepoint(alloc, &out, 0xFFFD),
                '\r' => {
                    try out.appendSlice(alloc, "\r\n");
                    // Consume the LF of a CRLF so it is not doubled.
                    if (i + 1 < src.len and src[i + 1] == '\n') i += 1;
                },
                '\n' => try out.appendSlice(alloc, "\r\n"),
                else => try out.append(alloc, b),
            }
            i += 1;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            try appendCodepoint(alloc, &out, 0xFFFD);
            i += 1;
            continue;
        };
        if (i + seq_len > src.len) {
            try appendCodepoint(alloc, &out, 0xFFFD);
            i += 1;
            continue;
        }
        // `utf8Decode` validates as it decodes, so this replaces the
        // separate validity check as well as yielding the codepoint the
        // bidi test needs.
        const cp = std.unicode.utf8Decode(src[i .. i + seq_len]) catch {
            try appendCodepoint(alloc, &out, 0xFFFD);
            i += 1;
            continue;
        };
        if (isBidiFormatting(cp)) {
            try appendCodepoint(alloc, &out, 0xFFFD);
        } else {
            try out.appendSlice(alloc, src[i .. i + seq_len]);
        }
        i += seq_len;
    }

    const text = try out.toOwnedSlice(alloc);
    errdefer alloc.free(text);
    return .{
        .text = text,
        .caption = try caption(alloc, end, data.len),
        .shown_bytes = end,
        .total_bytes = data.len,
    };
}

fn caption(alloc: Allocator, shown_bytes: usize, total_bytes: usize) Allocator.Error![]u8 {
    if (shown_bytes < total_bytes) {
        return std.fmt.allocPrint(alloc, "Showing the first {d} of {d} bytes", .{ shown_bytes, total_bytes });
    }
    if (total_bytes == 1) return alloc.dupe(u8, "1 byte");
    return std.fmt.allocPrint(alloc, "{d} bytes", .{total_bytes});
}

test "win32 close prompts count the terminals they would end" {
    for ([_]struct { Closing, []const u8, []const u8, []const u8 }{
        .{
            .{ .scope = .{ .scope = .right_tabs, .terminals = 1 } },
            "Close the tabs to the right?",
            "Close tabs",
            "A process is still running in a tab to the right. Closing those tabs will terminate it.",
        },
        .{
            .{ .scope = .{ .scope = .this_tab, .terminals = 2 } },
            "Close this tab?",
            "Close tab",
            "Processes are still running in 2 terminals in this tab. Closing the tab will terminate them, and undo is off.",
        },
        .{
            .{ .scope = .{ .scope = .app, .terminals = 3 } },
            "Quit noctty?",
            "Quit",
            "Processes are still running in 3 terminals. Quitting noctty will terminate them.",
        },
        .{
            .{ .scope = .{ .scope = .update, .terminals = 2 } },
            "Install the update?",
            "Install",
            "Processes are still running in 2 terminals. Installing the update closes noctty and will terminate them.",
        },
        // One pane's own prompt, in the tab in front.
        .{
            .{ .terminal = .{} },
            "Close this terminal?",
            "Close",
            "A process is still running. Closing this surface will terminate it.",
        },
        // A read-only terminal asks after its program exits, in front too.
        .{
            .{ .terminal = .{ .program_exited = true } },
            "Close this terminal?",
            "Close",
            "The program has exited. Read-only mode makes closing this terminal ask first.",
        },
    }) |case| {
        var words: Words = .{};
        defer words.deinit(std.testing.allocator);
        const prompt = words.close(std.testing.allocator, case[0]);
        try std.testing.expectEqualStrings(case[1], prompt.title);
        try std.testing.expectEqualStrings(case[2], prompt.accept_label);
        try std.testing.expectEqualStrings(case[3], prompt.body);
        try std.testing.expectEqualStrings("Cancel", prompt.cancel_label);
        try std.testing.expect(prompt.contents == null);
        try std.testing.expect(!prompt.program_request);
    }
}

test "the close prompt for a tab behind the front one names it as the clipboard prompt does" {
    const alloc = std.testing.allocator;
    const vim: TabRef = .{ .number = 3, .title = "vim" };
    for ([_]struct { Closing, []const u8, []const u8 }{
        .{
            .{ .scope = .{ .scope = .this_tab, .terminals = 1, .behind = vim } },
            "Close tab 3?",
            "A process is still running in Tab 3 (vim). Closing that tab will terminate it, and undo is off.",
        },
        .{
            .{ .scope = .{ .scope = .this_tab, .terminals = 2, .behind = .{ .number = 12, .title = null } } },
            "Close tab 12?",
            "Processes are still running in 2 terminals in Tab 12 (noctty). Closing that tab will terminate them, and undo is off.",
        },
        .{
            .{ .terminal = .{ .behind = .{ .number = 2, .title = "vim" } } },
            "Close terminal in tab 2?",
            "A process is still running in Tab 2 (vim). Closing that terminal will terminate it.",
        },
        .{
            .{ .terminal = .{ .program_exited = true, .behind = .{ .number = 2, .title = "vim" } } },
            "Close terminal in tab 2?",
            "The program in Tab 2 (vim) has exited. Read-only mode makes closing that terminal ask first.",
        },
        // The title is the program's own text: bounded and stripped the same way.
        .{
            .{ .scope = .{ .scope = .this_tab, .terminals = 1, .behind = .{ .number = 4, .title = "\u{202E}abcdefghijklmnopqrstuvwxyz0123456789" } } },
            "Close tab 4?",
            "A process is still running in Tab 4 (\u{FFFD}abcdefghijklmnopqrst...). Closing that tab will terminate it, and undo is off.",
        },
        // Only "this tab" has words for a tab behind; the other scopes run
        // from the tab in front or have no tab.
        .{
            .{ .scope = .{ .scope = .other_tabs, .terminals = 1, .behind = vim } },
            "Close the other tabs?",
            "A process is still running in another tab. Closing the other tabs will terminate it.",
        },
    }) |case| {
        var words: Words = .{};
        defer words.deinit(alloc);
        const prompt = words.close(alloc, case[0]);
        try std.testing.expectEqualStrings(case[1], prompt.title);
        try std.testing.expectEqualStrings(case[2], prompt.body);
    }
}

test "a close prompt for a tab behind keeps its numbered title when its body cannot be allocated" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    const vim: TabRef = .{ .number = 3, .title = "vim" };

    var tab_words: Words = .{};
    defer tab_words.deinit(alloc);
    const tab = tab_words.close(alloc, .{ .scope = .{ .scope = .this_tab, .terminals = 2, .behind = vim } });
    try std.testing.expectEqualStrings("Close tab 3?", tab.title);
    try std.testing.expectEqualStrings(
        "Processes are still running in 2 terminals in this tab. Closing the tab will terminate them, and undo is off.",
        tab.body,
    );

    var terminal_words: Words = .{};
    defer terminal_words.deinit(alloc);
    const terminal = terminal_words.close(alloc, .{ .terminal = .{ .program_exited = true, .behind = vim } });
    try std.testing.expectEqualStrings("Close terminal in tab 3?", terminal.title);
    try std.testing.expectEqualStrings("The program has exited. Read-only mode makes closing this terminal ask first.", terminal.body);

    try std.testing.expect(failing.has_induced_failure);
}

test "a program's clipboard prompt names its tab and cannot be reordered by its title" {
    const alloc = std.testing.allocator;
    const read = "Let a program read your clipboard?";
    const write = "Let a program change your clipboard?";
    // Marks that take no cell are cut by count.
    const marks = "x" ++ "\u{0301}" ** 50;
    for ([_]struct { Clipboard, []const u8, []const u8 }{
        .{
            .{ .program = .{ .request = .read, .contents = "a", .asked_by = .{ .number = 2, .title = "vim" } } },
            read,
            "Tab 2 (vim) asked to read your clipboard. Allow sends it the text below.",
        },
        .{
            .{ .program = .{ .request = .write, .contents = "a", .asked_by = .{ .number = 1, .title = null } } },
            write,
            "Tab 1 (noctty) asked to replace your clipboard with the text below.",
        },
        .{
            .{ .program = .{ .request = .read, .contents = "a", .asked_by = .{ .number = 3, .title = "\u{202E}abcdefghijklmnopqrstuvwxyz0123456789" } } },
            read,
            "Tab 3 (\u{FFFD}abcdefghijklmnopqrst...) asked to read your clipboard. Allow sends it the text below.",
        },
        .{
            .{ .program = .{ .request = .write, .contents = "a", .asked_by = .{ .number = 4, .title = marks } } },
            write,
            "Tab 4 (x" ++ "\u{0301}" ** 20 ++ "...) asked to replace your clipboard with the text below.",
        },
        .{
            .{ .program = .{ .request = .read, .contents = "a", .asked_by = .{ .number = 5, .title = "a\x1b[2Jb\u{9B}c\u{2028}d" } } },
            read,
            "Tab 5 (a\u{FFFD}[2Jb\u{FFFD}c\u{FFFD}d) asked to read your clipboard. Allow sends it the text below.",
        },
    }) |case| {
        var words: Words = .{};
        defer words.deinit(alloc);
        const prompt = try words.clipboard(alloc, case[0]);
        try std.testing.expectEqualStrings(case[1], prompt.title);
        try std.testing.expectEqualStrings(case[2], prompt.body);
        try std.testing.expectEqualStrings("Allow", prompt.accept_label);
        try std.testing.expectEqualStrings("a", prompt.contents.?);
        try std.testing.expect(prompt.program_request);
    }

    // The user's own paste keeps its own words and is no program request.
    var paste_words: Words = .{};
    defer paste_words.deinit(alloc);
    const paste = try paste_words.clipboard(alloc, .{ .user_paste = "a\nb" });
    try std.testing.expectEqualStrings("Allow clipboard paste?", paste.title);
    try std.testing.expectEqualStrings("noctty needs confirmation before completing this clipboard paste.", paste.body);
    try std.testing.expectEqualStrings("a\nb", paste.contents.?);
    try std.testing.expect(!paste.program_request);
}

test "a link prompt names the app, the scheme, or that no app is set" {
    const alloc = std.testing.allocator;
    for ([_]struct { LinkHandler, []const u8 }{
        .{ .{ .app = "PuTTY" }, "Windows opens it with \u{201C}PuTTY\u{201D}. Continue only if you trust where it goes." },
        .{ .unnamed, "Windows opens it with the app set for ssh links. Continue only if you trust where it goes." },
        .{ .none, "No app is set for ssh links; Windows may ask you to pick one. Continue only if you trust where it goes." },
    }) |case| {
        var words: Words = .{};
        defer words.deinit(alloc);
        const prompt = try words.link(alloc, .{ .url = "ssh:user@host", .scheme = "ssh", .handler = case[0] });
        try std.testing.expectEqualStrings(case[1], prompt.body);
        try std.testing.expectEqualStrings("Open link from terminal output?", prompt.title);
        try std.testing.expectEqualStrings("Open link", prompt.accept_label);
        try std.testing.expectEqualStrings("ssh:user@host", prompt.contents.?);
        try std.testing.expect(prompt.program_request);
    }
}

test "win32 confirm preview passes ordinary text through untouched" {
    var shown = try preview(std.testing.allocator, "echo one\r\necho two\r\n");
    defer shown.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("echo one\r\necho two\r\n", shown.text);
    try std.testing.expectEqual(@as(usize, 20), shown.shown_bytes);
    try std.testing.expectEqual(@as(usize, 20), shown.total_bytes);
    try std.testing.expect(!shown.truncated());
}

test "win32 confirm preview passes control characters through, except NUL" {
    // Upstream's GTK and macOS dialogs show the payload as it is, so BEL,
    // DEL, tab, CR and LF all survive verbatim. NUL cannot: the EDIT takes
    // a NUL-terminated string and would drop everything after it.
    var shown = try preview(std.testing.allocator, "a\x00b\x07c\td\x7fe\r\n");
    defer shown.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a\u{FFFD}b\x07c\td\x7fe\r\n", shown.text);
    try std.testing.expect(std.mem.indexOfScalar(u8, shown.text, 0) == null);
    // The bytes after the NUL must still be there — that is the point.
    try std.testing.expect(std.mem.endsWith(u8, shown.text, "e\r\n"));
}

test "win32 confirm preview replaces invalid UTF-8 rather than failing" {
    // OSC 52 write payloads are base64-decoded bytes from the terminal
    // and need not be text at all. The UTF-16 conversion on the way to
    // the EDIT would reject them and show nothing.
    var shown = try preview(std.testing.allocator, "ok\xffbad\xe3\x81");
    defer shown.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ok\u{FFFD}bad\u{FFFD}\u{FFFD}", shown.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shown.text));
}

// The boundary tests below cut at a few bytes through `previewUpTo`, the
// code `preview` runs at `preview_limit`.

test "win32 confirm preview keeps its prefix when the boundary byte is an orphan" {
    // Regression: backing off on any continuation byte at the boundary
    // threw away valid bytes before it. Here only one byte is excluded,
    // and it is not part of any sequence that starts inside the prefix.
    var shown = try previewUpTo(std.testing.allocator, "aaaaaaaa\x80", 8);
    defer shown.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("aaaaaaaa", shown.text);
    try std.testing.expectEqual(@as(usize, 8), shown.shown_bytes);
    try std.testing.expectEqual(@as(usize, 9), shown.total_bytes);
}

test "win32 confirm preview survives a run of orphan continuation bytes" {
    // The old scan walked back through the whole run, so a payload with
    // a long run at the boundary lost that much displayable content.
    var run = try previewUpTo(std.testing.allocator, "aaaa\x80\x80\x80\x80\x80\x80\x80\x80", 8);
    defer run.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 8), run.shown_bytes);
    try std.testing.expectEqualStrings("aaaa\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}", run.text);

    // The pathological case: nothing but continuation bytes used to drag
    // the boundary to zero and show an empty pane.
    var all = try previewUpTo(std.testing.allocator, "\x80" ** 12, 8);
    defer all.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 8), all.shown_bytes);
    try std.testing.expectEqual(@as(usize, 12), all.total_bytes);
    try std.testing.expect(all.text.len > 0);
}

test "win32 confirm preview leaves the boundary alone when a sequence ends on it" {
    // Three bytes in, three bytes out: the sequence ends exactly at the
    // limit, so there is nothing to back off from.
    var shown = try previewUpTo(std.testing.allocator, "\u{3042}\u{3042}", 3);
    defer shown.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\u{3042}", shown.text);
    try std.testing.expectEqual(@as(usize, 3), shown.shown_bytes);
}

test "win32 confirm preview replaces bidirectional formatting characters" {
    // Trojan Source (CVE-2021-42574): these are invisible and reorder the
    // text around them, so the pane would show a different reading order
    // than the payload actually has.
    var shown = try preview(std.testing.allocator, "echo \u{202E}dlrow olleh\u{202C}");
    defer shown.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo \u{FFFD}dlrow olleh\u{FFFD}", shown.text);

    const bidi = [_]u21{
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C,
        0x202D, 0x202E, 0x2066,
        0x2067, 0x2068, 0x2069,
    };
    for (bidi) |cp| {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        var one = try preview(std.testing.allocator, buf[0..len]);
        defer one.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("\u{FFFD}", one.text);
    }

    // Neighbouring codepoints outside the set must survive untouched, or
    // the ranges have been written too wide.
    for ([_]u21{ 0x061B, 0x061D, 0x200D, 0x2010, 0x2029, 0x202F, 0x2065, 0x206A }) |cp| {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        var one = try preview(std.testing.allocator, buf[0..len]);
        defer one.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(buf[0..len], one.text);
    }
}

test "win32 confirm preview truncates on a codepoint boundary" {
    // Two 3-byte codepoints, cut at 4 bytes: backing off to 3 keeps the
    // first whole and never emits a split sequence.
    var shown = try previewUpTo(std.testing.allocator, "\u{3042}\u{3042}", 4);
    defer shown.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\u{3042}", shown.text);
    try std.testing.expectEqual(@as(usize, 3), shown.shown_bytes);
    try std.testing.expectEqual(@as(usize, 6), shown.total_bytes);
    try std.testing.expect(shown.truncated());
    try std.testing.expect(std.unicode.utf8ValidateSlice(shown.text));
}

test "win32 confirm preview normalises line endings to CRLF" {
    // A Win32 EDIT breaks lines only on CRLF. A lone LF renders as
    // nothing and a lone CR is swallowed, which would hide the one
    // structural fact the paste prompt exists to show.
    var shown = try preview(std.testing.allocator, "one\ntwo\rthree\r\nfour\n\nfive\r\r\nsix");
    defer shown.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "one\r\ntwo\r\nthree\r\nfour\r\n\r\nfive\r\n\r\nsix",
        shown.text,
    );
    // The caption still counts source bytes, not display bytes.
    try std.testing.expectEqual(@as(usize, 31), shown.shown_bytes);
    try std.testing.expectEqual(@as(usize, 31), shown.total_bytes);
    try std.testing.expect(!shown.truncated());
}

test "win32 confirm preview keeps a malformed lead byte at the boundary" {
    // A lead byte whose sequence crosses the limit is backed off only
    // when the sequence is whole and valid. A malformed one is shown as
    // U+FFFD instead of dragging the boundary back over the bytes
    // before it -- here all the way to an empty pane.
    var shown = try previewUpTo(std.testing.allocator, "\xE0\x80x", 2);
    defer shown.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\u{FFFD}\u{FFFD}", shown.text);
    try std.testing.expectEqual(@as(usize, 2), shown.shown_bytes);
    try std.testing.expectEqual(@as(usize, 3), shown.total_bytes);
    try std.testing.expect(shown.truncated());

    // A sequence that is cut by the end of the data itself is malformed
    // too, and likewise must not move the boundary.
    var cut = try previewUpTo(std.testing.allocator, "abc\xE3\x81", 4);
    defer cut.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc\u{FFFD}", cut.text);
    try std.testing.expectEqual(@as(usize, 4), cut.shown_bytes);
}

test "win32 confirm preview caption reports what is being approved" {
    const alloc = std.testing.allocator;

    var whole = try preview(alloc, "a" ** 12);
    defer whole.deinit(alloc);
    try std.testing.expectEqualStrings("12 bytes", whole.caption);

    var single = try preview(alloc, "a");
    defer single.deinit(alloc);
    try std.testing.expectEqualStrings("1 byte", single.caption);

    // A paste past the pane's 64 KiB shows only its head.
    const big = try alloc.alloc(u8, 3145728);
    defer alloc.free(big);
    @memset(big, 'a');
    var cut = try preview(alloc, big);
    defer cut.deinit(alloc);
    try std.testing.expectEqualStrings("Showing the first 65536 of 3145728 bytes", cut.caption);
    try std.testing.expectEqual(@as(usize, 65536), cut.text.len);
}
