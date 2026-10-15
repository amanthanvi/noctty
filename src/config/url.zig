const std = @import("std");
const oni = @import("oniguruma");

/// Default URL/path regex. This is used to detect URLs and file paths in
/// terminal output.
///
/// This is here in the config package because one day the matchers will be
/// configurable and this will be a default.
///
/// For scheme URLs, this regex is liberal in what it accepts after the scheme,
/// with exceptions for URLs ending with . or ). Although such URLs are
/// perfectly valid, it is common for text to contain URLs surrounded by
/// parentheses (such as in Markdown links) or at the end of sentences.
/// Therefore, this regex excludes them as follows:
///
/// 1. Do not match regexes ending with .
/// 2. Do not match regexes ending with ), except for ones which contain a (
///    without a subsequent )
///
/// Rule 2 means that we handle the following two cases:
///
///   "https://en.wikipedia.org/wiki/Rust_(video_game)" (include parens)
///   "(https://example.com)" (do not include the parens)
///
/// There are many complicated cases where these heuristics break down, but
/// handling them well requires a non-regex approach.
pub const url_schemes =
    \\https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:
;

const ipv6_url_pattern =
    \\(?:\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\](?::[0-9]+)?)
;

const scheme_url_chars =
    \\[\w\-.~:/?#@!$&*+,;=%]
;

const path_chars =
    \\[\w\-.~:\/?#@!$&*+;=%]
;

const optional_bracketed_word_suffix =
    \\(?:[\(\[]\w*[\)\]])?
;

const no_trailing_punctuation =
    \\(?<![,.])
;

const no_trailing_colon =
    \\(?<!:)
;

const trailing_spaces_at_eol =
    \\(?: +(?= *$))?
;

const dotted_path_lookahead =
    \\(?=[\w\-.~:\/?#@!$&*+;=%]*\.)
;

const non_dotted_path_lookahead =
    \\(?![\w\-.~:\/?#@!$&*+;=%]*\.)
;

const dotted_path_space_segments =
    \\(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*
;

const any_path_space_segments =
    \\(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]+)*
;

// Branch 1: URLs with explicit schemes (http, mailto, ftp, etc.).
const scheme_url_branch =
    "(?:" ++ url_schemes ++ ")" ++
    "(?:" ++ ipv6_url_pattern ++ "|" ++ scheme_url_chars ++ "+" ++ optional_bracketed_word_suffix ++ ")+" ++
    no_trailing_punctuation;

const rooted_or_relative_path_prefix =
    \\(?:\.\.\/|\.\/|(?<!\w)~\/|(?:[\w][\w\-.]*\/)*(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))
;

// Branch 2: Absolute paths and dot-relative paths (/, ./, ../).
// A dotted segment is treated as file-like, while the undotted case stays
// broad to capture directory-like paths with spaces.
const rooted_or_relative_path_branch =
    rooted_or_relative_path_prefix ++
    "(?:" ++
    dotted_path_lookahead ++
    path_chars ++ "+" ++
    dotted_path_space_segments ++
    no_trailing_colon ++
    trailing_spaces_at_eol ++
    "|" ++
    non_dotted_path_lookahead ++
    path_chars ++ "+" ++
    any_path_space_segments ++
    no_trailing_colon ++
    trailing_spaces_at_eol ++
    ")";

// Branch 3: Bare relative paths such as src/config/url.zig.
const bare_relative_path_prefix =
    \\(?<!\$\d*)(?<!\w)[\w][\w\-.]*\/
;

const bare_relative_path_branch =
    dotted_path_lookahead ++
    bare_relative_path_prefix ++
    path_chars ++ "+" ++
    no_trailing_colon ++
    trailing_spaces_at_eol;

// Windows paths: `C:\dir\file`, `C:/dir/file`, `\\server\share\file`, `.\x`,
// `..\x` and `dir\file.ext`, with an optional `:line:col` or `(line,col)`.
//
// A path may hold spaces (`C:\Program Files\x`), but regex cannot tell
// `C:\Program Files\x` from `C:\a.txt copied ok`. A space continues the path
// after a word whose last segment has no dot (`Program`), and after one that
// has a dot (`git.exe`, `Node.js`) only when the next word is directory-like
// (`Tools\x.exe`, see `win_dotted_gap`). So `C:\a.txt copied` ends at `.txt`,
// `C:\Program Files\Git\bin\git.exe failed` at `git.exe`, and
// `C:\Program Files\Node.js Tools\x.exe` still holds. Prose after a path whose
// last segment has no dot (`C:\Users\amant and then`) is still swallowed, as
// in the POSIX branch; a quoted path ends at its closing quote.
//
// A parenthesis or bracket belongs to the path only as a closed pair
// (`Program Files (x86)`, `(12,5)`), so an unbalanced one is a delimiter and
// `(C:\a.txt)` does not take its `)`. `;` and `,` end a path (they separate
// the entries of `PATH` and of compiler output, like the POSIX branch's `,`),
// and so do `:`, `"` and the other characters Windows forbids in a name. A
// trailing `.`, `!`, `'` or `}` is dropped.
const win_path_char =
    \\[^\x00-\x20<>:"|?*;,()\[\]]
;

const win_seg_char =
    \\[^\x00-\x20<>:"|?*;,()\[\]\\/.]
;

const win_path_pair =
    \\\([^\x00-\x1f<>:"|?*;()\[\]]*\)|\[[^\x00-\x1f<>:"|?*;()\[\]]*\]
;

const win_path_atom =
    "(?:" ++ win_path_char ++ "|" ++ win_path_pair ++ ")";

const win_seg_atom =
    "(?:" ++ win_seg_char ++ "|" ++ win_path_pair ++ ")";

const win_path_word = win_path_atom ++ "+";

// A word whose last segment has no dot.
const win_dotless_word =
    "(?:" ++ win_path_atom ++ "*[\\\\/]" ++ win_seg_atom ++ "*|" ++ win_seg_atom ++ "+)";

// A word whose last segment has a dot.
const win_dotted_word =
    "(?:" ++ win_path_atom ++ "*[\\\\/])?" ++ win_seg_atom ++ "*\\.(?:" ++ win_seg_atom ++ "|\\.)*";

// The first character after the space must not start another path.
const win_word_gap =
    \\[ ](?![A-Za-z]:)(?!\\\\)
;

// After a dotted word the next one must be a directory-like word: it starts
// with a word character and has a backslash before any `/` or `:`, so a URL,
// `.\b.txt`, `src/c.txt` and `~/x` after a file name are other links.
const win_dotted_gap =
    win_word_gap ++ "(?=\\w[^\\x00-\\x20:\"/]*\\\\)";

const win_location =
    \\(?::[0-9]+){0,2}
;

const win_no_trailing_punctuation =
    \\(?<![.!'}])
;

const win_path_tail =
    "(?:" ++ win_dotless_word ++ win_word_gap ++ "|" ++ win_dotted_word ++ win_dotted_gap ++ ")*" ++
    win_path_word ++ win_location ++ win_no_trailing_punctuation;

const win_drive_root =
    \\(?<![\w\\/])(?<!\w@)[A-Za-z]:[\\/]
;

// `\\.\pipe` and `\\?\C:` are device paths, not shares.
const win_unc_root =
    \\(?<![\w\\/])\\\\(?![.?]\\)[A-Za-z0-9._-]+\\
;

// The quotes tell where a path with spaces ends, whatever follows them.
const win_quoted_root =
    "(?:" ++ win_drive_root ++ "|" ++ win_unc_root ++ "|\\.\\.?\\\\)";

const windows_quoted_path =
    "(?<=\")" ++ win_quoted_root ++ "[^\"\\x00-\\x1f<>|?*]+(?=\")" ++
    "|(?<=')" ++ win_quoted_root ++ "[^'\\x00-\\x1f<>|?*]+(?=')";

const windows_drive_path =
    win_drive_root ++ win_path_tail;

const windows_unc_path =
    win_unc_root ++ win_path_tail;

// `dir\file.ext` needs a dot, like the bare POSIX branch, so that `a\b` in
// prose is not a path.
const win_relative_prefix =
    \\(?<![\w.\\/])\.\.?\\|(?<![\w.~\\/:-])(?=[^\x00-\x20<>:"|?*;]*\.)\w[\w\-.]*\\
;

const windows_relative_path =
    "(?:" ++ win_relative_prefix ++ ")" ++ win_path_tail;

pub const regex =
    scheme_url_branch ++
    "|" ++
    rooted_or_relative_path_branch ++
    "|" ++
    bare_relative_path_branch ++
    "|" ++
    windows_quoted_path ++
    "|" ++
    windows_drive_path ++
    "|" ++
    windows_unc_path ++
    "|" ++
    windows_relative_path;

/// The path in `text` without the location a compiler or test runner appends:
/// `:line`, `:line:col`, `(line)` or `(line,col)`. Null when there is none.
///
/// Nothing here says the rest is a path. A name can end in `(1)`, so a caller
/// that opens something tries the whole text first.
pub fn splitLocation(text: []const u8) ?[]const u8 {
    var end = text.len;
    if (end > 0 and text[end - 1] == ')') {
        const open = std.mem.lastIndexOfScalar(u8, text, '(') orelse return null;
        const inner = text[open + 1 .. end - 1];
        const comma = std.mem.indexOfScalar(u8, inner, ',');
        if (!allDigits(inner[0 .. comma orelse inner.len])) return null;
        if (comma) |i| if (!allDigits(inner[i + 1 ..])) return null;
        end = open;
    } else {
        for (0..2) |_| {
            const colon = std.mem.lastIndexOfScalar(u8, text[0..end], ':') orelse break;
            if (!allDigits(text[colon + 1 .. end])) break;
            end = colon;
        }
    }
    // A drive letter alone is not a path.
    if (end == text.len or end < 2) return null;
    return text[0..end];
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "splitLocation" {
    const testing = std.testing;
    const cases = [_]struct { input: []const u8, expect: ?[]const u8 }{
        .{ .input = "C:\\a\\b.zig:12:5", .expect = "C:\\a\\b.zig" },
        .{ .input = "C:\\a\\b.zig:12", .expect = "C:\\a\\b.zig" },
        .{ .input = ".\\src\\main.zig:12:5", .expect = ".\\src\\main.zig" },
        .{ .input = "src/main.zig:7", .expect = "src/main.zig" },
        .{ .input = "src\\main.zig(12,5)", .expect = "src\\main.zig" },
        .{ .input = "src\\main.cs(12)", .expect = "src\\main.cs" },
        // Two groups at most.
        .{ .input = "a.zig:1:2:3", .expect = "a.zig:1" },
        // Not a location.
        .{ .input = "C:\\a\\b.zig", .expect = null },
        .{ .input = "C:\\a\\b.zig:", .expect = null },
        .{ .input = "C:\\a\\b.zig:x", .expect = null },
        .{ .input = "C:\\a\\x(foo)", .expect = null },
        .{ .input = "C:\\a\\x(1,)", .expect = null },
        .{ .input = "C:\\a\\x()", .expect = null },
        .{ .input = "C:\\Program Files (x86)", .expect = null },
        .{ .input = "C:5", .expect = null },
        .{ .input = ":12", .expect = null },
        .{ .input = "", .expect = null },
    };
    for (cases) |case| {
        const got = splitLocation(case.input);
        if (case.expect) |want| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(want, got.?);
        } else try testing.expect(got == null);
    }
}

test "url regex" {
    const testing = std.testing;

    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // The URL cases to test what our regex matches. Feel free to add to this
    // as we find bugs or just want more coverage.
    const cases = [_]struct {
        input: []const u8,
        expect: []const u8,
        num_matches: usize = 1,
    }{
        .{
            .input = "hello https://example.com world",
            .expect = "https://example.com",
        },
        .{
            .input = "https://example.com/foo(bar) more",
            .expect = "https://example.com/foo(bar)",
        },
        .{
            .input = "https://example.com/foo(bar)baz more",
            .expect = "https://example.com/foo(bar)baz",
        },
        .{
            .input = "Link inside (https://example.com) parens",
            .expect = "https://example.com",
        },
        .{
            .input = "Link period https://example.com. More text.",
            .expect = "https://example.com",
        },
        .{
            .input = "Link trailing comma https://example.com, more text.",
            .expect = "https://example.com",
        },
        .{
            .input = "Link in double quotes \"https://example.com\" and more",
            .expect = "https://example.com",
        },
        .{
            .input = "Link in single quotes 'https://example.com' and more",
            .expect = "https://example.com",
        },
        .{
            .input = "some file with https://google.com https://duckduckgo.com links.",
            .expect = "https://google.com",
        },
        .{
            .input = "and links in it. links https://yahoo.com mailto:test@example.com ssh://1.2.3.4",
            .expect = "https://yahoo.com",
        },
        .{
            .input = "also match http://example.com non-secure links",
            .expect = "http://example.com",
        },
        .{
            .input = "match tel://+12123456789 phone numbers",
            .expect = "tel://+12123456789",
        },
        .{
            .input = "match with query url https://example.com?query=1&other=2 and more text.",
            .expect = "https://example.com?query=1&other=2",
        },
        .{
            .input = "url with dashes [mode 2027](https://github.com/contour-terminal/terminal-unicode-core) for better unicode support",
            .expect = "https://github.com/contour-terminal/terminal-unicode-core",
        },
        .{
            .input = "dot.http://example.com",
            .expect = "http://example.com",
        },
        // weird characters in URL
        .{
            .input = "weird characters https://example.com/~user/?query=1&other=2#hash and more",
            .expect = "https://example.com/~user/?query=1&other=2#hash",
        },
        // square brackets in URL
        .{
            .input = "square brackets https://example.com/[foo] and more",
            .expect = "https://example.com/[foo]",
        },
        // square bracket following url
        .{
            .input = "[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]",
            .expect = "https://example.com/docs/Too-Many-Statements.md",
        },
        // remaining URL schemes tests
        .{
            .input = "match ftp://example.com ftp links",
            .expect = "ftp://example.com",
        },
        .{
            .input = "match file://example.com file links",
            .expect = "file://example.com",
        },
        .{
            .input = "match ssh://example.com ssh links",
            .expect = "ssh://example.com",
        },
        .{
            .input = "match git://example.com git links",
            .expect = "git://example.com",
        },
        .{
            .input = "/tmp/test.txt http://www.google.com",
            .expect = "/tmp/test.txt",
        },
        .{
            .input = "match tel:+18005551234 tel links",
            .expect = "tel:+18005551234",
        },
        .{
            .input = "match magnet:?xt=urn:btih:1234567890 magnet links",
            .expect = "magnet:?xt=urn:btih:1234567890",
        },
        .{
            .input = "match ipfs://QmSomeHashValue ipfs links",
            .expect = "ipfs://QmSomeHashValue",
        },
        .{
            .input = "match ipns://QmSomeHashValue ipns links",
            .expect = "ipns://QmSomeHashValue",
        },
        .{
            .input = "match gemini://example.com gemini links",
            .expect = "gemini://example.com",
        },
        .{
            .input = "match gopher://example.com gopher links",
            .expect = "gopher://example.com",
        },
        .{
            .input = "match news:comp.infosystems.www.servers.unix news links",
            .expect = "news:comp.infosystems.www.servers.unix",
        },
        .{
            .input = "/Users/ghostty.user/code/example.py",
            .expect = "/Users/ghostty.user/code/example.py",
        },
        .{
            .input = "/Users/ghostty.user/code/../example.py",
            .expect = "/Users/ghostty.user/code/../example.py",
        },
        .{
            .input = "/Users/ghostty.user/code/../example.py hello world",
            .expect = "/Users/ghostty.user/code/../example.py",
        },
        .{
            .input = "../example.py",
            .expect = "../example.py",
        },
        .{
            .input = "../example.py ",
            .expect = "../example.py ",
        },
        .{
            .input = "first time ../example.py contributor ",
            .expect = "../example.py",
        },
        .{
            .input = "[link](/home/user/ghostty.user/example)",
            .expect = "/home/user/ghostty.user/example",
        },
        // IPv6 URL tests - Basic tests
        .{
            .input = "Serving HTTP on :: port 8000 (http://[::]:8000/)",
            .expect = "http://[::]:8000/",
        },
        .{
            .input = "IPv6 address https://[2001:db8::1]:8080/path",
            .expect = "https://[2001:db8::1]:8080/path",
        },
        .{
            .input = "IPv6 localhost http://[::1]:3000",
            .expect = "http://[::1]:3000",
        },
        .{
            .input = "Complex IPv6 https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
            .expect = "https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
        },
        // IPv6 URL tests - URLs with paths and query parameters
        .{
            .input = "IPv6 with path https://[2001:db8::1]/path/to/resource",
            .expect = "https://[2001:db8::1]/path/to/resource",
        },
        .{
            .input = "IPv6 with query https://[2001:db8::1]:8080/api?param=value&other=123",
            .expect = "https://[2001:db8::1]:8080/api?param=value&other=123",
        },
        // IPv6 URL tests - Compressed forms
        .{
            .input = "IPv6 compressed http://[2001:db8::]:80/",
            .expect = "http://[2001:db8::]:80/",
        },
        .{
            .input = "IPv6 multiple zeros http://[2001:0:0:0:0:0:0:1]",
            .expect = "http://[2001:0:0:0:0:0:0:1]",
        },
        // IPv6 URL tests - Special cases
        .{
            .input = "IPv6 link-local https://[fe80::1234:5678:9abc]",
            .expect = "https://[fe80::1234:5678:9abc]",
        },
        .{
            .input = "IPv6 multicast http://[ff02::1]/stream",
            .expect = "http://[ff02::1]/stream",
        },
        // IPv6 URL tests - Mixed scenarios
        .{
            .input = "IPv6 in markdown [link](http://[2001:db8::1]/docs)",
            .expect = "http://[2001:db8::1]/docs",
        },
        // File paths with spaces
        .{
            .input = "./spaces-end.   ",
            .expect = "./spaces-end.   ",
        },
        .{
            .input = "./space middle",
            .expect = "./space middle",
        },
        .{
            .input = "../test folder/file.txt",
            .expect = "../test folder/file.txt",
        },
        .{
            .input = "/tmp/test folder/file.txt",
            .expect = "/tmp/test folder/file.txt",
        },
        .{
            .input = "/tmp/test  folder/file.txt",
            .expect = "/tmp/test",
        },
        // unified diff lines
        .{
            .input = "diff --git a/src/font/shaper/harfbuzz.zig b/src/font/shaper/harfbuzz.zig",
            .expect = "a/src/font/shaper/harfbuzz.zig",
        },
        // Two space-separated absolute paths should match only the first
        .{
            .input = "/tmp/foo /tmp/bar",
            .expect = "/tmp/foo",
        },
        .{
            .input = "/tmp/foo.txt /tmp/bar.txt",
            .expect = "/tmp/foo.txt",
        },
        // Bare relative file paths (no ./ or ../ prefix)
        .{
            .input = "src/config/url.zig",
            .expect = "src/config/url.zig",
        },
        .{
            .input = "app/folder/file.rb:1",
            .expect = "app/folder/file.rb:1",
        },
        .{
            .input = "modified:   src/config/url.zig",
            .expect = "src/config/url.zig",
        },
        .{
            .input = "lib/ghostty/terminal.zig:42:10",
            .expect = "lib/ghostty/terminal.zig:42:10",
        },
        .{
            .input = "some-pkg/src/file.txt more text",
            .expect = "some-pkg/src/file.txt",
        },
        // comma should match substrings
        .{
            .input = "src/foo.c,baz.txt",
            .expect = "src/foo.c",
        },
        .{
            .input = "~/foo/bar.txt",
            .expect = "~/foo/bar.txt",
        },
        .{
            .input = "open ~/Documents/notes.md please",
            .expect = "~/Documents/notes.md",
        },
        .{
            .input = "~/.config/ghostty/config",
            .expect = "~/.config/ghostty/config",
        },
        .{
            .input = "directory: ~/src/ghostty-org/ghostty",
            .expect = "~/src/ghostty-org/ghostty",
        },
        .{
            .input = "$HOME/src/config/url.zig",
            .expect = "$HOME/src/config/url.zig",
        },
        .{
            .input = "project dir: $PWD/src/ghostty/main.zig",
            .expect = "$PWD/src/ghostty/main.zig",
        },
        // $VAR mid-path should match fully, not partially from the $
        .{
            .input = "foo/$BAR/baz",
            .expect = "foo/$BAR/baz",
        },
        .{
            .input = ".foo/bar/$VAR",
            .expect = ".foo/bar/$VAR",
        },
        .{
            .input = ".config/ghostty/config",
            .expect = ".config/ghostty/config",
        },
        .{
            .input = "loaded from .local/share/ghostty/state.db now",
            .expect = ".local/share/ghostty/state.db",
        },
        .{
            .input = "../some/where",
            .expect = "../some/where",
        },
        // comma-separated file paths
        .{
            .input = "  - shared/src/foo/SomeItem.m:12, shared/src/",
            .expect = "shared/src/foo/SomeItem.m:12",
        },
        // mid-string dot should not partially match but fully
        .{
            .input = "foo.local/share",
            .expect = "foo.local/share",
        },
        // numeric directory should match fully
        .{
            .input = "2024/report.txt",
            .expect = "2024/report.txt",
        },
        // comma should stop matching in spaced path segments
        .{
            .input = "./foo bar,baz",
            .expect = "./foo bar",
        },
        .{
            .input = "/tmp/foo bar,baz",
            .expect = "/tmp/foo bar",
        },
        // trailing colon should not be part of the path
        .{
            .input = "./.config/ghostty: Needs upstream (main)",
            .expect = "./.config/ghostty",
        },
        .{
            .input = "./Downloads: Operation not permitted",
            .expect = "./Downloads",
        },
    };

    for (cases) |case| {
        //std.debug.print("input: {s}\n", .{case.input});
        //std.debug.print("match: {s}\n", .{case.expect});
        var reg = try re.search(case.input, .{});
        //std.debug.print("count: {d}\n", .{@as(usize, reg.count())});
        //std.debug.print("starts: {d}\n", .{reg.starts()});
        //std.debug.print("ends: {d}\n", .{reg.ends()});
        defer reg.deinit();
        try testing.expectEqual(@as(usize, case.num_matches), reg.count());
        const match = case.input[@intCast(reg.starts()[0])..@intCast(reg.ends()[0])];
        try testing.expectEqualStrings(case.expect, match);
    }

    const no_match_cases = [_][]const u8{
        // bare relative paths without any dot should not match as file paths
        "input/output",
        "foo/bar",
        // $-numeric character should not match
        "$10/bar",
        "$10/$20",
        "$10/bar.txt",
        // comma should not let dot detection look past it
        "foo/bar,baz.txt",
        // $VAR should not match mid-word
        "foo$BAR/baz.txt",
        // ~ should not match mid-word
        "foo~/bar.txt",
        // double-slash comments are not paths
        "// foo bar",
        "//foo",
    };
    for (no_match_cases) |input| {
        var result = re.search(input, .{});
        if (result) |*reg| {
            reg.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

/// Every match of `regex` in `input`, in order, as slices of `input`.
fn allMatches(
    alloc: std.mem.Allocator,
    re: *oni.Regex,
    input: []const u8,
) !std.ArrayList([]const u8) {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer found.deinit(alloc);
    var offset: usize = 0;
    while (offset < input.len) {
        var reg: oni.Region = .{};
        defer reg.deinit();
        _ = re.searchAdvanced(input, offset, input.len, &reg, .{}) catch break;
        const start: usize = @intCast(reg.starts()[0]);
        const end: usize = @intCast(reg.ends()[0]);
        if (end <= start) break;
        try found.append(alloc, input[start..end]);
        offset = end;
    }
    return found;
}

test "url regex Windows paths" {
    const testing = std.testing;
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();

    const cases = [_]struct {
        input: []const u8,
        expect: []const []const u8,
    }{
        // The drive letter is part of the path, in either separator style.
        .{ .input = "C:\\Users\\amant\\file.txt", .expect = &.{"C:\\Users\\amant\\file.txt"} },
        .{ .input = "C:/Users/amant/file.txt", .expect = &.{"C:/Users/amant/file.txt"} },
        .{ .input = "c:\\tmp\\a.log", .expect = &.{"c:\\tmp\\a.log"} },
        // Prose after a file name is not part of it.
        .{ .input = "see C:\\Users\\amant\\file.txt end", .expect = &.{"C:\\Users\\amant\\file.txt"} },
        .{ .input = "wrote C:\\a.txt copied ok", .expect = &.{"C:\\a.txt"} },
        // Spaces inside a path stay.
        .{ .input = "C:\\Program Files\\x\\y.exe", .expect = &.{"C:\\Program Files\\x\\y.exe"} },
        .{ .input = "C:\\Users\\john.doe\\My Documents\\x.txt", .expect = &.{"C:\\Users\\john.doe\\My Documents\\x.txt"} },
        .{ .input = "C:\\a b\\c d\\e.txt", .expect = &.{"C:\\a b\\c d\\e.txt"} },
        // A parenthesis or bracket closes only a pair opened inside the path.
        .{ .input = "C:\\Program Files (x86)\\Tool\\a.exe", .expect = &.{"C:\\Program Files (x86)\\Tool\\a.exe"} },
        .{ .input = "C:\\Program Files (x86)", .expect = &.{"C:\\Program Files (x86)"} },
        .{ .input = "(C:\\foo\\bar.txt) and then", .expect = &.{"C:\\foo\\bar.txt"} },
        .{ .input = "[C:\\a\\b.txt]", .expect = &.{"C:\\a\\b.txt"} },
        .{ .input = "{C:\\a\\b.txt}", .expect = &.{"C:\\a\\b.txt"} },
        // Trailing punctuation is not part of it.
        .{ .input = "see C:\\a.txt, then", .expect = &.{"C:\\a.txt"} },
        .{ .input = "saved to C:\\a\\b.txt.", .expect = &.{"C:\\a\\b.txt"} },
        .{ .input = "is C:\\a\\b.txt?", .expect = &.{"C:\\a\\b.txt"} },
        .{ .input = "PS C:\\Users\\amant>", .expect = &.{"C:\\Users\\amant"} },
        // A list separated by `;` is several paths.
        .{ .input = "C:\\a\\b.txt;C:\\c\\d.txt", .expect = &.{ "C:\\a\\b.txt", "C:\\c\\d.txt" } },
        // Two paths stay two paths.
        .{ .input = "C:\\one D:\\two", .expect = &.{ "C:\\one", "D:\\two" } },
        .{ .input = "C:\\a.txt,C:\\b.txt", .expect = &.{ "C:\\a.txt", "C:\\b.txt" } },
        .{ .input = "C:\\a,D:\\b", .expect = &.{ "C:\\a", "D:\\b" } },
        .{ .input = "--include=C:\\a\\x.h,C:\\b\\y.h", .expect = &.{ "C:\\a\\x.h", "C:\\b\\y.h" } },
        // A space continues a path only after a word with no dot in its last
        // segment, so the words after a file name are not part of it.
        .{
            .input = "C:\\Program Files\\Git\\bin\\git.exe failed with exit code 1",
            .expect = &.{"C:\\Program Files\\Git\\bin\\git.exe"},
        },
        .{ .input = "C:\\Users\\John Smith\\a.txt is here", .expect = &.{"C:\\Users\\John Smith\\a.txt"} },
        .{ .input = "C:\\a b.txt trailing", .expect = &.{"C:\\a b.txt"} },
        .{ .input = "PS C:\\Users\\John Smith>", .expect = &.{"C:\\Users\\John Smith"} },
        // A folder whose name has a dot and a space in it stays whole, because
        // the word after a dotted one continues the path when it has a separator.
        .{ .input = "C:\\Program Files\\Node.js Tools\\x.exe", .expect = &.{"C:\\Program Files\\Node.js Tools\\x.exe"} },
        .{ .input = "C:\\Users\\j.doe Backup\\x.txt", .expect = &.{"C:\\Users\\j.doe Backup\\x.txt"} },
        .{ .input = "C:\\Users\\Jane Q. Public\\x.txt", .expect = &.{"C:\\Users\\Jane Q. Public\\x.txt"} },
        .{ .input = "C:\\Users\\me\\v1.2 beta\\x.txt", .expect = &.{"C:\\Users\\me\\v1.2 beta\\x.txt"} },
        .{ .input = "C:\\x.y z\\w e\\f", .expect = &.{"C:\\x.y z\\w e\\f"} },
        // What follows a file name is another link, not part of the path.
        .{ .input = "C:\\a.txt https://x/y", .expect = &.{ "C:\\a.txt", "https://x/y" } },
        .{
            .input = "Serving C:\\site\\index.html http://localhost:8080/",
            .expect = &.{ "C:\\site\\index.html", "http://localhost:8080/" },
        },
        .{ .input = "copy C:\\a.txt .\\b.txt", .expect = &.{ "C:\\a.txt", ".\\b.txt" } },
        .{ .input = "move C:\\a\\b.txt ..\\c\\d.txt", .expect = &.{ "C:\\a\\b.txt", "..\\c\\d.txt" } },
        .{ .input = "git diff C:\\a.txt b/a.txt", .expect = &.{ "C:\\a.txt", "b/a.txt" } },
        .{ .input = "C:\\a.txt /x/y", .expect = &.{ "C:\\a.txt", "/x/y" } },
        .{ .input = "C:\\a.txt ~/x", .expect = &.{ "C:\\a.txt", "~/x" } },
        // A response file argument is a path; a host before a colon is not a drive.
        .{ .input = "cl @C:\\build\\args.rsp", .expect = &.{"C:\\build\\args.rsp"} },
        .{ .input = "csc @C:/build/args.rsp", .expect = &.{"C:/build/args.rsp"} },
        .{ .input = "user@h:/x/y", .expect = &.{"/x/y"} },
        // Quotes delimit a path that has spaces, whatever follows them.
        .{
            .input = "'C:\\Program Files\\x\\y.exe' is not recognized as an internal or external command",
            .expect = &.{"C:\\Program Files\\x\\y.exe"},
        },
        .{ .input = "open \"C:\\my docs\\a b.txt\" now", .expect = &.{"C:\\my docs\\a b.txt"} },
        .{ .input = "'.\\folder' is here", .expect = &.{".\\folder"} },
        .{ .input = "open \".\\my docs\\a b.txt\" now", .expect = &.{".\\my docs\\a b.txt"} },
        .{ .input = "cd '..\\up dir' now", .expect = &.{"..\\up dir"} },
        // A location after the path is part of the link text.
        .{ .input = "C:\\a\\b.zig:12:5: error: x", .expect = &.{"C:\\a\\b.zig:12:5"} },
        .{ .input = "C:\\a\\b.zig:12 failed", .expect = &.{"C:\\a\\b.zig:12"} },
        .{ .input = "C:\\a\\b.cs(12,5): error CS0103", .expect = &.{"C:\\a\\b.cs(12,5)"} },
        // Relative paths.
        .{ .input = ".\\src\\main.zig:12:5", .expect = &.{".\\src\\main.zig:12:5"} },
        .{ .input = "run ..\\x\\y.txt now", .expect = &.{"..\\x\\y.txt"} },
        .{ .input = "src\\main.zig(12,5)", .expect = &.{"src\\main.zig(12,5)"} },
        .{ .input = "error in src\\config\\url.zig here", .expect = &.{"src\\config\\url.zig"} },
        // Network shares.
        .{ .input = "\\\\server\\share\\dir\\f.txt end", .expect = &.{"\\\\server\\share\\dir\\f.txt"} },
        // A drive path is never read as the rooted path after its colon.
        .{ .input = "C:/x", .expect = &.{"C:/x"} },
    };
    for (cases) |case| {
        var found = try allMatches(testing.allocator, &re, case.input);
        defer found.deinit(testing.allocator);
        testing.expectEqual(case.expect.len, found.items.len) catch |err| {
            std.debug.print("input: {s}\n", .{case.input});
            for (found.items) |item| std.debug.print("  matched: {s}\n", .{item});
            return err;
        };
        for (case.expect, found.items) |want, got| {
            testing.expectEqualStrings(want, got) catch |err| {
                std.debug.print("input: {s}\n", .{case.input});
                return err;
            };
        }
    }

    // Shapes that are not Windows paths.
    for ([_][]const u8{
        "foo\\bar",
        "a\\b",
        "C:",
        "C:\\",
        "\\\\?\\C:\\x",
        "\\\\.\\pipe\\x",
        "prompt>C:5",
    }) |input| {
        var found = try allMatches(testing.allocator, &re, input);
        defer found.deinit(testing.allocator);
        testing.expectEqual(@as(usize, 0), found.items.len) catch |err| {
            std.debug.print("input: {s}\n", .{input});
            for (found.items) |item| std.debug.print("  matched: {s}\n", .{item});
            return err;
        };
    }
}
