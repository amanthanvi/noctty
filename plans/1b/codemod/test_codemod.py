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
         '    const d = try tmp.dir.readFileAlloc(alloc, "a.txt", 1 << 20);\n'
         '    try tmp.dir.symLink("t", "l", .{});\n    const f = try tmp.dir.openFile("a.txt", .{});\n'
         '    try testing.expectError(error.FileNotFound, tmp.dir.access("x", .{}));\n}\n',
         'test "a" {\n    var tmp = std.testing.tmpDir(.{});\n    defer tmp.cleanup();\n'
         '    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "" });\n'
         '    try tmp.dir.createDir(std.testing.io, "real", .default_dir);\n'
         '    try tmp.dir.createDirPath(std.testing.io, "a/b");\n'
         '    const p = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);\n'
         '    const d = try tmp.dir.readFileAlloc(std.testing.io, "a.txt", alloc, .limited(1 << 20));\n'
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

    def test_make_open_path_options_move_under_open_options(self):
        src = ('test "m" {\n    var tmp = std.testing.tmpDir(.{});\n'
               '    var a = try tmp.dir.makeOpenPath("a", .{ .iterate = true });\n'
               '    var b = try tmp.dir.makeOpenPath("b", .{});\n'
               '    var c = try tmp.dir.makeOpenPath("c", opts);\n}\n')
        got, hits = codemod.rewrite(src, {"test-dir-io"})
        self.assertIn('try tmp.dir.createDirPathOpen(std.testing.io, "a", .{ .open_options = .{ .iterate = true } })',
                      got)
        self.assertIn('try tmp.dir.createDirPathOpen(std.testing.io, "b", .{})', got)
        # Options the tokens cannot read stay for a hand edit.
        self.assertIn('try tmp.dir.makeOpenPath("c", opts)', got)

    def test_read_link_is_left_alone(self):
        # 0.17's readLink returns a byte count where 0.15's returned the slice.
        src = 'test "l" {\n    var tmp = std.testing.tmpDir(.{});\n    const t = try tmp.dir.readLink("x", &buf);\n}\n'
        self.assertEqual(codemod.rewrite(src)[0], src)

    def test_a_block_naming_file_too_big_keeps_its_read_file_alloc(self):
        src = ('test "big" {\n    var tmp = std.testing.tmpDir(.{});\n'
               '    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "x" });\n'
               '    try testing.expectError(error.FileTooBig, tmp.dir.readFileAlloc(alloc, "a", 0));\n}\n')
        got, _ = codemod.rewrite(src)
        self.assertIn('tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "x" })', got)
        self.assertIn('tmp.dir.readFileAlloc(alloc, "a", 0)', got)

    def test_reorder_keeps_line_breaks_and_leaves_commented_arguments(self):
        # Each argument's span takes the 0.17 argument at its place; the line breaks stay.
        src = ('test "r" {\n    var tmp = std.testing.tmpDir(.{});\n    const d = try tmp.dir.readFileAlloc(\n'
               '        alloc,\n        "a.txt",\n        1 << 20,\n    );\n}\n')
        got, hits = codemod.rewrite(src)
        self.assertEqual(got.count("\n"), src.count("\n"))
        self.assertIn('readFileAlloc(\n        std.testing.io, "a.txt",\n        alloc,\n'
                      '        .limited(1 << 20),\n    );', got)
        self.assertEqual(len(hits), 1)
        # A comment between arguments that change places would sit beside the wrong one: left for a hand edit.
        commented = src.replace("        alloc,\n", "        alloc, // the allocator\n")
        self.assertEqual(codemod.rewrite(commented)[0], commented)

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
                      'tmp.dir.readFileAlloc(std.testing.io, "b", alloc, .limited(10)) })', got)
        self.assertEqual(len(hits), 2)
        self.assertEqual(codemod.rewrite(got)[0], got)

    def test_multi_line_reorder_in_fork_line_mode(self):
        src = ('test "f" {\n    var tmp = std.testing.tmpDir(.{});\n    const d = try tmp.dir.readFileAlloc(\n'
               '        alloc,\n        "a.txt",\n        1 << 20,\n    );\n}\n')
        got, hits = codemod.rewrite(src, None, set(range(1, 9)))
        self.assertEqual(len(hits), 1)
        self.assertEqual(got.count("\n"), src.count("\n"))

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
