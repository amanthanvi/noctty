"""Tests of plans/1b/codemod/codemod.py: each rule over its fixture, what it must leave alone, and idempotence (a
second run over a rule's output changes nothing). Run: python -I plans/1b/codemod/test_codemod.py"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import codemod  # noqa: E402

# rule id -> list of (input, expected output). Every input and every output is also run again to check idempotence.
FIXTURES = {
    "arraylist-empty": [
        ("    list: std.ArrayListUnmanaged(FontVariation) = .{},\n",
         "    list: std.ArrayListUnmanaged(FontVariation) = .empty,\n"),
        ("var xs: std.ArrayList(struct { a: u8 }) = .{ };\n",
         "var xs: std.ArrayList(struct { a: u8 }) = .empty;\n"),
        ("var xs: std.ArrayListAlignedUnmanaged(u8, .@\"16\") = .{};\n",
         "var xs: std.ArrayListAlignedUnmanaged(u8, .@\"16\") = .empty;\n"),
        # Left alone: a non-empty initializer, a comparison, a string and a comment.
        ("var xs: std.ArrayList(u8) = .{ .items = &.{} };\n", None),
        ("if (x == std.ArrayList(u8)) {}\n", None),
        ('const s = "std.ArrayList(u8) = .{}";\n', None),
        ("// var xs: std.ArrayList(u8) = .{};\n", None),
    ],
    "mem-trim": [
        ("const t = std.mem.trimLeft(u8, s, \" \");\n", "const t = std.mem.trimStart(u8, s, \" \");\n"),
        ("const t = mem.trimRight(u8, s, \"\\r\\n\");\n", "const t = mem.trimEnd(u8, s, \"\\r\\n\");\n"),
        ("const t = self.trimLeft(s);\n", None),
        ("fn trimLeft() void {}\n", None),
    ],
    "dupe-z": [
        ("const z = try alloc.dupeZ(u8, name);\n", "const z = try alloc.dupeSentinel(u8, name, 0);\n"),
        ("const z = try alloc.dupeZ(\n    u8,\n    name,\n);\n",
         "const z = try alloc.dupeSentinel(\n    u8,\n    name,\n 0,);\n"),
        ("const z = try alloc.dupeZ(u8, f(a, b));\n", "const z = try alloc.dupeSentinel(u8, f(a, b), 0);\n"),
        ("const z = dupeZ(u8, name);\n", None),
        ("const z = alloc.dupeZ(name);\n", None),
    ],
    "ascii-find": [
        ("if (std.ascii.indexOfIgnoreCase(a, b) != null) {}\n",
         "if (std.ascii.findIgnoreCase(a, b) != null) {}\n"),
        ("_ = ascii.indexOfIgnoreCasePos(a, 1, b);\n", "_ = ascii.findIgnoreCasePos(a, 1, b);\n"),
        ("_ = std.mem.indexOf(u8, a, b);\n", None),
    ],
    "optimize-mode": [
        ("@\"gtk-opengl-debug\": bool = builtin.mode == .Debug,\n",
         "@\"gtk-opengl-debug\": bool = builtin.mode == .debug,\n"),
        ("if (builtin.mode != .ReleaseFast) {}\n", "if (builtin.mode != .fast) {}\n"),
        ("if (.ReleaseSafe == @import(\"builtin\").mode) {}\n", "if (.safe == @import(\"builtin\").mode) {}\n"),
        ("const x = switch (builtin.mode) {\n    .Debug, .ReleaseSafe => true,\n    .ReleaseFast, .ReleaseSmall => f(.Debug),\n};\n",
         "const x = switch (builtin.mode) {\n    .debug, .safe => true,\n    .fast, .small => f(.Debug),\n};\n"),
        # Left alone: another value's tags, and a string.
        ("if (config.mode == .Debug) {}\n", None),
        ("const s = \"builtin.mode == .Debug\";\n", None),
    ],
    "test-dir-io": [
        ('test "a" {\n    var tmp = std.testing.tmpDir(.{});\n    defer tmp.cleanup();\n'
         '    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "" });\n'
         '    try tmp.dir.makeDir("real");\n    try tmp.dir.makePath("a/b");\n'
         '    const p = try tmp.dir.realpathAlloc(alloc, ".");\n'
         '    const d = try tmp.dir.readFileAlloc(alloc, "a.txt", max_bytes);\n'
         '    try tmp.dir.symLink("t", "l", .{});\n    const f = try tmp.dir.openFile("a.txt", .{});\n'
         '    try testing.expectError(error.FileNotFound, tmp.dir.access("x", .{}));\n}\n',
         'test "a" {\n    var tmp = std.testing.tmpDir(.{});\n    defer tmp.cleanup();\n'
         '    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "" });\n'
         '    try tmp.dir.createDir(std.testing.io, "real", .default_dir);\n'
         '    try tmp.dir.createDirPath(std.testing.io, "a/b");\n'
         '    const p = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);\n'
         '    const d = try tmp.dir.readFileAlloc(std.testing.io, "a.txt", alloc, .limited(max_bytes + 1));\n'
         '    try tmp.dir.symLink(std.testing.io, "t", "l", .{});\n'
         '    const f = try tmp.dir.openFile(std.testing.io, "a.txt", .{});\n'
         '    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "x", .{}));\n}\n'),
        # Multi-line arguments and a trailing comma keep their layout.
        ('test {\n    var tmp = testing.tmpDir(.{});\n    try tmp.dir.writeFile(.{\n        .sub_path = "a",\n'
         '        .data = "b",\n    });\n}\n',
         'test {\n    var tmp = testing.tmpDir(.{});\n    try tmp.dir.writeFile(std.testing.io, .{\n'
         '        .sub_path = "a",\n        .data = "b",\n    });\n}\n'),
        # What such a call opened closes with the Io, ported or not; another value's close is left alone.
        ('test "o" {\n    var tmp = std.testing.tmpDir(.{});\n    const file = try tmp.dir.createFile("m", .{});\n'
         '    file.close();\n    var d = try tmp.dir.openDir(std.testing.io, "x", .{});\n    defer d.close();\n'
         '    other.close();\n}\n',
         'test "o" {\n    var tmp = std.testing.tmpDir(.{});\n'
         '    const file = try tmp.dir.createFile(std.testing.io, "m", .{});\n'
         '    file.close(std.testing.io);\n    var d = try tmp.dir.openDir(std.testing.io, "x", .{});\n'
         '    defer d.close(std.testing.io);\n    other.close();\n}\n'),
        # The fork's os/TempDir, qualified or not.
        ('test "t" {\n    var tmp = try TempDir.init();\n    try tmp.dir.makeDir("real");\n'
         '    var t2 = try internal_os.TempDir.init();\n    try t2.dir.deleteDir("loop");\n}\n',
         'test "t" {\n    var tmp = try TempDir.init();\n    try tmp.dir.createDir(std.testing.io, "real", .default_dir);\n'
         '    var t2 = try internal_os.TempDir.init();\n    try t2.dir.deleteDir(std.testing.io, "loop");\n}\n'),
        # std.fs.cwd() in a test.
        ('test "c" {\n    try std.fs.cwd().deleteFile("x");\n}\n',
         'test "c" {\n    try std.Io.Dir.cwd().deleteFile(std.testing.io, "x");\n}\n'),
        # Left alone: a ported call, outside a test, another receiver, an unbound tmp, an unknown method.
        ('test "d" {\n    var tmp = std.testing.tmpDir(.{});\n    try tmp.dir.writeFile(io, .{ .sub_path = "a" });\n}\n',
         None),
        ('fn f() void {\n    var tmp = std.testing.tmpDir(.{});\n    try tmp.dir.makeDir("x");\n}\n', None),
        ('test "e" {\n    try self.dir.makeDir("x");\n    try other.dir.makeDir("x");\n}\n', None),
        ('test "f" {\n    var tmp = std.testing.tmpDir(.{});\n    var it = tmp.dir.iterate();\n}\n', None),
    ],
}


class RuleTests(unittest.TestCase):
    def test_every_rule_has_a_fixture(self):
        self.assertEqual({r[0] for r in codemod.RULES}, set(FIXTURES))

    def test_fixtures(self):
        for rule_id, cases in FIXTURES.items():
            for source, expected in cases:
                with self.subTest(rule=rule_id, source=source):
                    got, hits = codemod.rewrite(source, {rule_id})
                    self.assertEqual(expected if expected is not None else source, got)
                    self.assertEqual(bool(hits), expected is not None)

    def test_idempotent(self):
        for rule_id, cases in FIXTURES.items():
            for source, expected in cases:
                once, _ = codemod.rewrite(source)
                twice, hits = codemod.rewrite(once)
                with self.subTest(rule=rule_id, source=source):
                    self.assertEqual(once, twice)
                    self.assertEqual(hits, [])

    # --- the council's round-1 findings (E3, E4, E5, O3, O6) ---------------------------------------------------

    def test_make_open_path_translates_no_follow_and_nothing_else(self):
        # council F3: `.no_follow = true` is 0.17's `.open_options = .{ .follow_symlinks = false }`, one to one;
        # any other option is a hand edit, reported.
        head = 'test "m" {\n    var tmp = std.testing.tmpDir(.{});\n'
        for opts, want in ((".{}", ".{}"),
                           (".{ .no_follow = true }", ".{ .open_options = .{ .follow_symlinks = false } }"),
                           (".{ .no_follow = true, }", ".{ .open_options = .{ .follow_symlinks = false } }")):
            with self.subTest(opts=opts):
                got, hits = codemod.rewrite(head + f'    var a = try tmp.dir.makeOpenPath("a", {opts});\n}}\n')
                self.assertIn(f'    var a = try tmp.dir.createDirPathOpen(std.testing.io, "a", {want});\n', got)
        for opts in (".{ .iterate = true }", ".{ .no_follow = true, .iterate = true }", ".{ .no_follow = false }",
                     ".{ .access_sub_paths = false }", "opts"):
            with self.subTest(opts=opts):
                src = head + f'    var a = try tmp.dir.makeOpenPath("a", {opts});\n}}\n'
                rows = []
                self.assertEqual(codemod.rewrite(src, None, None, rows), (src, []))
                self.assertEqual(rows, [("test-dir-io", 3, "hand edit: " + codemod.OPEN_OPTIONS)])
        # The one translation over several lines would drop its line breaks: the engine's hand edit.
        src = head + '    var a = try tmp.dir.makeOpenPath("a", .{\n        .no_follow = true,\n    });\n}\n'
        rows = []
        self.assertEqual(codemod.rewrite(src, None, None, rows), (src, []))
        self.assertEqual(rows, [("test-dir-io", 3, "hand edit: " + codemod.LINE_COUNT)])

    def test_realpath_alloc_keeps_its_sentinel_type_or_is_a_hand_edit(self):
        # council F3: 0.17's realPathFileAlloc returns `[:0]u8`. Into an untyped const it stays one, and
        # `free(p)` frees the sentinel too; into a `[]u8` (or anywhere it may coerce) a later free would get the
        # wrong size: a hand edit, reported.
        head = 'test "rp" {\n    var tmp = std.testing.tmpDir(.{});\n'
        for call, want in (('tmp.dir.realpathAlloc(alloc, ".")', 'tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc)'),
                           ('std.fs.cwd().realpathAlloc(alloc, ".")',
                            'std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", alloc)')):
            with self.subTest(call=call):
                got, hits = codemod.rewrite(head + f'    const p = try {call};\n    defer alloc.free(p);\n}}\n')
                self.assertIn(f'    const p = try {want};\n    defer alloc.free(p);\n', got)
                self.assertEqual(len(hits), 1)
        for line in ('    const p: []u8 = try tmp.dir.realpathAlloc(alloc, ".");\n    defer alloc.free(p);\n',
                     '    const p: [:0]u8 = try tmp.dir.realpathAlloc(alloc, ".");\n',
                     '    var p = try tmp.dir.realpathAlloc(alloc, ".");\n',
                     '    const p = tmp.dir.realpathAlloc(alloc, ".") catch return;\n',
                     '    s.path = try tmp.dir.realpathAlloc(alloc, ".");\n',
                     '    const s: S = .{ .path = try tmp.dir.realpathAlloc(alloc, ".") };\n',
                     '    try list.append(alloc, try tmp.dir.realpathAlloc(alloc, "."));\n'):
            with self.subTest(line=line):
                src = head + line + '}\n'
                rows = []
                self.assertEqual(codemod.rewrite(src, None, None, rows), (src, []))
                self.assertEqual(rows, [("test-dir-io", 3, "hand edit: " + codemod.REALPATH_SHAPE)])

    def test_open_file_and_the_directory_it_may_open(self):
        # council F3: 0.15.2's openFile refused a directory on Windows (error.IsDir); 0.17.1's opens one unless
        # `.allow_directory = false`. A test's rewrite keeps 0.17's default and the report lists it; product code is
        # never rewritten (it has no std.testing.io), and its 0.15 openFile is a reported hand edit.
        src = ('test "of" {\n    var tmp = std.testing.tmpDir(.{});\n    const f = try tmp.dir.openFile("a", .{});\n'
               '    defer f.close();\n}\n')
        rows = []
        got, hits = codemod.rewrite(src, None, None, rows)
        self.assertIn('    const f = try tmp.dir.openFile(std.testing.io, "a", .{});\n', got)
        self.assertEqual(rows, [("test-dir-io", 3, "rewritten; " + codemod.OPEN_FILE_NOTE)])
        product = ('fn load() !void {\n    const f = try std.fs.cwd().openFile("a", .{});\n    defer f.close();\n'
                   '    const g = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });\n    defer g.close();\n'
                   '    const h = try std.Io.Dir.cwd().openFile(io, "a", .{});\n    const k = try dir.openFile("a", .{});\n'
                   '}\n')
        rows = []
        self.assertEqual(codemod.rewrite(product, None, None, rows), (product, []))
        self.assertEqual(rows, [("test-dir-io", 2, "hand edit: " + codemod.PRODUCT_OPEN_FILE),
                                ("test-dir-io", 4, "hand edit: " + codemod.PRODUCT_OPEN_FILE)])
        # With --fork-lines, only the fork's.
        rows = []
        codemod.rewrite(product, None, {1, 4}, rows)
        self.assertEqual([r[:2] for r in rows], [("test-dir-io", 4)])

    def test_read_link_is_left_alone(self):
        # 0.17's readLink returns a byte count where 0.15's returned the slice.
        src = 'test "l" {\n    var tmp = std.testing.tmpDir(.{});\n    const t = try tmp.dir.readLink("x", &buf);\n}\n'
        self.assertEqual(codemod.rewrite(src)[0], src)

    def test_a_block_naming_file_too_big_keeps_its_read_file_alloc(self):
        src = ('test "big" {\n    var tmp = std.testing.tmpDir(.{});\n'
               '    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "x" });\n'
               '    try testing.expectError(error.FileTooBig, tmp.dir.readFileAlloc(alloc, "a", 0));\n}\n')
        rows = []
        got, _ = codemod.rewrite(src, None, None, rows)
        self.assertIn('tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "x" })', got)
        self.assertIn('tmp.dir.readFileAlloc(alloc, "a", 0)', got)
        self.assertIn(("test-dir-io", 4, "hand edit: " + codemod.FILE_TOO_BIG), rows)

    def test_read_file_alloc_keeps_the_inclusive_bound(self):
        # council F2 (QR-30): 0.15 read a file of exactly n bytes, which 0.17's `.limited(n)` refuses; `n + 1` keeps
        # the bound where n is a literal or a simple name.
        head = 'test "rf" {\n    var tmp = std.testing.tmpDir(.{});\n'
        for limit in ("4096", "0x10_0000", "max_bytes"):
            with self.subTest(limit=limit):
                src = head + f'    const d = try tmp.dir.readFileAlloc(alloc, "a", {limit});\n}}\n'
                got, hits = codemod.rewrite(src)
                self.assertIn(f'readFileAlloc(std.testing.io, "a", alloc, .limited({limit} + 1));', got)
                self.assertEqual(len(hits), 1)
        # Another expression is a hand edit: `1 << 20 + 1` is `1 << 21`, `maxInt(usize) + 1` overflows.
        for limit in ("1 << 20", "(n)", "self.max", "std.math.maxInt(usize)", "@sizeOf(T)", "'a'"):
            with self.subTest(limit=limit):
                src = head + f'    const d = try tmp.dir.readFileAlloc(alloc, "a", {limit});\n}}\n'
                rows = []
                self.assertEqual(codemod.rewrite(src, None, None, rows), (src, []))
                self.assertEqual(rows, [("test-dir-io", 3, "hand edit: " + codemod.LIMIT_SHAPE)])

    def test_file_too_big_anywhere_in_the_file_keeps_read_file_alloc(self):
        # council F2: a helper outside the test consumes the error by name (or by its name's text); 0.17's
        # readFileAlloc returns StreamTooLong instead, so every readFileAlloc of the file is a hand edit.
        test = ('test "h" {\n    var tmp = std.testing.tmpDir(.{});\n'
                '    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "x" });\n'
                '    const d = try tmp.dir.readFileAlloc(alloc, "a", 64);\n}\n')
        for helper in ('fn load(d: anytype) ![]u8 {\n    return d.readFileAlloc(alloc, "a", 64) catch |err| switch (err) {\n'
                       '        error.FileTooBig => &.{},\n        else => err,\n    };\n}\n',
                       'fn tooBig(err: anyerror) bool {\n    return std.mem.eql(u8, @errorName(err), "FileTooBig");\n}\n'):
            with self.subTest(helper=helper):
                src = helper + test
                rows = []
                got, hits = codemod.rewrite(src, None, None, rows)
                line = helper.count("\n") + 4
                self.assertIn('tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "x" })', got)
                self.assertIn('    const d = try tmp.dir.readFileAlloc(alloc, "a", 64);\n', got)
                self.assertEqual(len(hits), 1)
                self.assertIn(("test-dir-io", line, "hand edit: " + codemod.FILE_TOO_BIG), rows)

    def test_arguments_that_change_places_stay_on_one_line(self):
        # council F5: arguments that change places across a line break would move text from one line to another:
        # a hand edit, reported. On one line they are rewritten, and the other arguments keep their line breaks.
        src = ('test "r" {\n    var tmp = std.testing.tmpDir(.{});\n    const d = try tmp.dir.readFileAlloc(\n'
               '        alloc,\n        "a.txt",\n        64,\n    );\n}\n')
        rows = []
        got, hits = codemod.rewrite(src, None, None, rows)
        self.assertEqual((got, hits), (src, []))
        self.assertEqual(rows, [("test-dir-io", 3, "hand edit: " + codemod.ACROSS_LINES)])
        same_line = src.replace("(\n        alloc,\n        \"a.txt\",\n", "(alloc, \"a.txt\",\n")
        got, hits = codemod.rewrite(same_line)
        self.assertIn('readFileAlloc(std.testing.io, "a.txt", alloc,\n        .limited(64 + 1),\n    );', got)
        self.assertEqual(len(hits), 1)
        # A comment between the arguments would end up beside another one: a hand edit, reported.
        for commented in (src.replace("        alloc,\n", "        alloc, // the allocator\n"),
                          same_line.replace('"a.txt",\n', '"a.txt", // the file\n')):
            rows = []
            self.assertEqual(codemod.rewrite(commented, None, None, rows)[0], commented)
            self.assertEqual([r[:2] for r in rows], [("test-dir-io", 3)])
            self.assertTrue(rows[0][2].startswith("hand edit: "))

    def test_open_and_close_are_one_hit(self):
        src = ('test "oc" {\n    var tmp = std.testing.tmpDir(.{});\n'
               '    const f = try tmp.dir.createFile("a", .{});\n    defer f.close();\n'
               '    const g = try std.fs.cwd().openFile("b", .{});\n    g.close();\n}\n')
        # Only the close lines are the fork's: neither the open nor its close changes.
        self.assertEqual(codemod.rewrite(src, None, {4, 6})[0], src)
        # Only the open lines: the same.
        self.assertEqual(codemod.rewrite(src, None, {3, 5})[0], src)
        # Both: each open and its close, cwd's included.
        got, hits = codemod.rewrite(src, None, {3, 4, 5, 6})
        self.assertIn('const f = try tmp.dir.createFile(std.testing.io, "a", .{});\n'
                      '    defer f.close(std.testing.io);', got)
        self.assertIn('const g = try std.Io.Dir.cwd().openFile(std.testing.io, "b", .{});\n'
                      '    g.close(std.testing.io);', got)
        self.assertEqual(len(hits), 2)

    def test_nested_calls_are_rewritten_in_turns(self):
        src = ('test "n" {\n    var tmp = std.testing.tmpDir(.{});\n'
               '    try tmp.dir.writeFile(.{ .sub_path = "a", .data = try tmp.dir.readFileAlloc(alloc, "b", 10) });\n}\n')
        got, hits = codemod.rewrite(src)
        self.assertIn('tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = try '
                      'tmp.dir.readFileAlloc(std.testing.io, "b", alloc, .limited(10 + 1)) })', got)
        self.assertEqual(len(hits), 2)
        self.assertEqual(codemod.rewrite(got)[0], got)

    def test_a_hand_edit_is_reported_on_fork_lines_only(self):
        src = ('test "f" {\n    var tmp = std.testing.tmpDir(.{});\n    const d = try tmp.dir.readFileAlloc(\n'
               '        alloc,\n        "a.txt",\n        64,\n    );\n}\n')
        rows = []
        self.assertEqual(codemod.rewrite(src, None, set(range(1, 9)), rows), (src, []))
        self.assertEqual(rows, [("test-dir-io", 3, "hand edit: " + codemod.ACROSS_LINES)])
        # The call's lines are upstream's: nothing to report.
        rows = []
        self.assertEqual(codemod.rewrite(src, None, {1, 2, 8}, rows), (src, []))
        self.assertEqual(rows, [])

    # --- the council's round-2 findings ------------------------------------------------------------------------

    def test_an_edit_is_checked_on_every_line_it_spans(self):
        # council F5: an edit from line 1 to line 3 touches line 2 too.
        hit = codemod.Hit(1, [codemod.Edit(0, 5, "a\nB\nc")])
        self.assertFalse(codemod._on_lines("a\nb\nc\n", hit, {1, 3}))
        self.assertTrue(codemod._on_lines("a\nb\nc\n", hit, {1, 2, 3}))

    def test_a_three_line_argument_reorder_around_an_inherited_line(self):
        # council F5: the second argument spans lines 3-5 and line 4 is upstream's. Swapping it with the first would
        # rewrite line 4 (and move it), whichever lines are the fork's: a hand edit, reported, never an abort.
        src = ('test "r" {\n    var tmp = std.testing.tmpDir(.{});\n'
               '    const p = try tmp.dir.realpathAlloc(alloc, try std.fmt.allocPrint(\n'
               '        alloc, "{s}", .{name},\n    ));\n}\n')
        for lines in ({1, 2, 3, 5, 6}, {5}, None):
            with self.subTest(lines=lines):
                rows = []
                self.assertEqual(codemod.rewrite(src, None, lines, rows), (src, []))
                self.assertEqual(rows, [("test-dir-io", 3, "hand edit: " + codemod.ACROSS_LINES)])
        # A hit the engine finds reaching an inherited line is reported with that reason.
        src = 'test "o" {\n    var tmp = std.testing.tmpDir(.{});\n    const f = try tmp.dir.openFile("a", .{});\n' \
              '    defer f.close();\n}\n'
        rows = []
        self.assertEqual(codemod.rewrite(src, None, {1, 2, 4, 5}, rows), (src, []))
        self.assertEqual(rows, [("test-dir-io", 3, "hand edit: " + codemod.INHERITED)])

    def test_a_multi_line_empty_array_list_is_a_hand_edit(self):
        # council F5: `.empty` would drop the line break (and the comment): reported, never an abort.
        for src in ("var xs: std.ArrayList(u8) = .{\n};\n", "var xs: std.ArrayList(u8) = .{ // none yet\n};\n"):
            with self.subTest(src=src):
                rows = []
                self.assertEqual(codemod.rewrite(src, None, None, rows), (src, []))
                self.assertEqual(rows, [("arraylist-empty", 1, "hand edit: " + codemod.LINE_COUNT)])

    def test_a_hand_edit_never_aborts_the_run(self):
        import contextlib
        import io
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p, report = Path(d) / "a.zig", Path(d) / "report.tsv"
            p.write_text("var xs: std.ArrayList(u8) = .{\n};\nconst t = std.mem.trimLeft(u8, s, \" \");\n",
                         encoding="utf-8", newline="\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = codemod.main(["--report", str(report), str(p)])
            self.assertEqual(code, 0)
            self.assertEqual(p.read_text(encoding="utf-8"),
                             "var xs: std.ArrayList(u8) = .{\n};\nconst t = std.mem.trimStart(u8, s, \" \");\n")
            self.assertIn(f"hand edit\t{p.as_posix()}\tarraylist-empty\t1\t{codemod.LINE_COUNT}\n", out.getvalue())
            self.assertIn("hand edits\t1\n", out.getvalue())
            self.assertEqual(report.read_text(encoding="utf-8"),
                             f"{p.as_posix()}\tarraylist-empty\t1\thand edit: {codemod.LINE_COUNT}\n"
                             f"{p.as_posix()}\tmem-trim\t3\trewritten\n")

    def test_parse_changed_lines(self):
        diff = ("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,0 +2,3 @@ fn a\n+a\n+b\n+c\n"
                "@@ -5 +7 @@\n-x\n+y\n@@ -9,2 +11,0 @@\n-p\n-q\n")
        self.assertEqual(codemod.parse_changed_lines(diff), {2, 3, 4, 7})
        # council F6: only a `+` record is a fork line; a context line inside a hunk (an inter-hunk context the
        # config set) is upstream's, and an added line that starts `++` is still a record.
        diff = ("--- a/x\n+++ b/x\n@@ -20,6 +20,6 @@\n-r\n+s\n c\n c\n c\n c\n-t\n+u\n"
                "@@ -30 +30 @@\n-v\n\\ No newline at end of file\n+w\n\\ No newline at end of file\n"
                "@@ -40,0 +41 @@\n+++x\n")
        self.assertEqual(codemod.parse_changed_lines(diff), {20, 25, 30, 41})

    def test_bad_baseline_writes_nothing(self):
        # council F6: the file lies inside the repository root, so the run reaches the ref check and not a path
        # outside the root, and the diagnostic is the ref's.
        import contextlib
        import io
        import tempfile
        with tempfile.TemporaryDirectory(dir=Path(codemod.__file__).resolve().parent) as d:
            p = Path(d) / "a.zig"
            p.write_text("const t = std.mem.trimLeft(u8, s, \" \");\n", encoding="utf-8", newline="\n")
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                code = codemod.main(["--fork-lines", "no-such-ref-1b5", str(p)])
            self.assertEqual(code, 2)
            self.assertEqual(err.getvalue(), "codemod: --fork-lines: 'no-such-ref-1b5' is no commit; nothing written\n")
            self.assertIn("trimLeft", p.read_text(encoding="utf-8"))

    def test_a_failing_file_writes_nothing(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            a, b = Path(d) / "a.zig", Path(d) / "b.zig"
            a.write_text("const t = std.mem.trimLeft(u8, s, \" \");\n", encoding="utf-8", newline="\n")
            b.write_bytes(b"const t = std.mem.trimLeft(u8, s, \" \");\r\n")
            self.assertEqual(codemod.main([str(a), str(b)]), 2)
            self.assertIn("trimLeft", a.read_text(encoding="utf-8"))

    def test_fork_lines_only(self):
        # Only the allowed lines are rewritten, and a hit whose halves straddle a disallowed line is dropped whole.
        src = ("const a = std.mem.trimLeft(u8, s, \" \");\nconst b = std.mem.trimLeft(u8, s, \" \");\n"
               "const z = try alloc.dupeZ(\n    u8,\n    name,\n);\n")
        got, hits = codemod.rewrite(src, None, {2, 3})
        self.assertEqual(got, src.replace("const b = std.mem.trimLeft", "const b = std.mem.trimStart"))
        self.assertEqual(hits, [("mem-trim", 2)])
        got, hits = codemod.rewrite(src, None, {3, 4, 5, 6})
        self.assertIn("dupeSentinel(\n    u8,\n    name,\n 0,);", got)
        self.assertNotIn("trimStart", got)

    def test_all_rules_together_match_each_rule_alone(self):
        for rule_id, cases in FIXTURES.items():
            for source, expected in cases:
                with self.subTest(rule=rule_id, source=source):
                    self.assertEqual(codemod.rewrite(source)[0], expected if expected is not None else source)


class ForkLineTests(unittest.TestCase):
    """council F6: `changed_lines` against a scratch repository whose config sets what a user's could."""

    def make_repo(self, files, config=()):
        import tempfile
        d = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(d.cleanup)
        repo = Path(d.name).resolve()
        self.git(repo, "init", "-q")
        for key, value in (("core.autocrlf", "false"), ("core.quotePath", "true")) + tuple(config):
            self.git(repo, "config", key, value)
        for name, data in files.items():
            (repo / name).write_bytes(data)
        self.git(repo, "add", "--", *files)
        self.git(repo, "-c", "user.name=codemod-test", "-c", "user.email=codemod-test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "base")
        return repo, self.git(repo, "rev-parse", "HEAD").strip()

    @staticmethod
    def git(repo, *args):
        import subprocess
        return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout

    def changed(self, repo, name, rev):
        from unittest import mock
        with mock.patch.object(codemod, "ROOT", repo):
            return codemod.changed_lines(repo / name, rev)

    BASE = "".join(f"line {k}\n" for k in range(1, 13)).encode()

    def test_inter_hunk_context_marks_no_unchanged_line(self):
        # Changes at lines 3 and 8 with diff.interHunkContext = 4 make one hunk over 3..8 unless the run sets 0.
        repo, rev = self.make_repo({"a.zig": self.BASE}, [("diff.interHunkContext", "4")])
        (repo / "a.zig").write_bytes(self.BASE.replace(b"line 3\n", b"line three\n").replace(b"line 8\n", b"line 8!\n"))
        self.assertEqual(self.changed(repo, "a.zig", rev), {3, 8})

    def test_non_ascii_path_is_found_in_the_ref(self):
        # Without -z, ls-tree quotes the name, which then reads as missing from the ref: every line eligible.
        name = "café.zig"
        repo, rev = self.make_repo({name: self.BASE})
        (repo / name).write_bytes(self.BASE.replace(b"line 2\n", b"line two\n"))
        self.assertEqual(self.changed(repo, name, rev), {2})

    def test_a_carriage_return_on_the_ref_side_is_no_line_break(self):
        # The ref's line `one<CR>two` is one diff record; read with universal newlines it would be two.
        repo, rev = self.make_repo({"a.zig": b"one\rtwo\nthree\nfour\n"})
        (repo / "a.zig").write_bytes(b"one\nthree\nFOUR\n")
        self.assertEqual(self.changed(repo, "a.zig", rev), {1, 3})


if __name__ == "__main__":
    unittest.main()
