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


if __name__ == "__main__":
    unittest.main()
