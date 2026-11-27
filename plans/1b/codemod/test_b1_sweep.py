"""Tests of plans/1b/codemod/b1_sweep.py over fixtures: each target, an added windows_ext binding, what it leaves
alone, and idempotence. Run: python -I plans/1b/codemod/test_b1_sweep.py"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import b1_sweep  # noqa: E402


class SweepTests(unittest.TestCase):
    def run_sweep(self, text, rel, entries):
        once, hits = b1_sweep.sweep(text, rel, entries)
        twice, again = b1_sweep.sweep(once, rel, entries)
        self.assertEqual(once, twice)
        self.assertEqual(again, [])
        return once, hits

    def test_ext_through_an_alias_adds_the_binding(self):
        src = ('const std = @import("std");\nconst os_windows = @import("../../os/windows.zig");\n'
               'fn f() void {\n    _ = os_windows.detectProcessArchitecture();\n    _ = os_windows.HANDLE;\n}\n')
        got, hits = self.run_sweep(src, "src/apprt/win32/x.zig", [("detectProcessArchitecture", "ext")])
        self.assertIn('const os_windows = @import("../../os/windows.zig");\n'
                      'const windows_ext = @import("../../os/windows_ext.zig");\n', got)
        self.assertIn("_ = windows_ext.detectProcessArchitecture();", got)
        self.assertIn("_ = os_windows.HANDLE;", got)  # not in the map
        self.assertEqual(len(hits), 1)

    def test_ext_through_internal_os(self):
        src = 'fn f() void {\n    _ = internal_os.windows.knownFolderPathUtf8(&internal_os.windows.FOLDERID_Profile);\n}\n'
        got, _ = self.run_sweep(src, "src/apprt/a.zig", [("knownFolderPathUtf8", "ext"), ("FOLDERID_Profile", "ext")])
        self.assertIn("internal_os.windows_ext.knownFolderPathUtf8(&internal_os.windows_ext.FOLDERID_Profile)", got)

    def test_existing_ext_binding_and_paths(self):
        src = ('const windows = internal_os.windows;\nconst windows_ext = internal_os.windows_ext;\n'
               'fn f() void {\n    _ = windows.exp.STILL_ACTIVE;\n    _ = windows.exp.HPCON;\n'
               '    _ = windows.GetFinalPathNameByHandleW;\n    _ = windows.kernel32.GetLastError;\n}\n')
        got, hits = self.run_sweep(src, "src/termio/x.zig", [("exp.STILL_ACTIVE", "ext"), ("exp.HPCON", "top"),
                                                             ("GetFinalPathNameByHandleW", "exp.kernel32"),
                                                             ("kernel32", "ext")])
        self.assertIn("_ = windows_ext.STILL_ACTIVE;", got)
        self.assertIn("_ = windows.HPCON;", got)
        self.assertIn("_ = windows.exp.kernel32.GetFinalPathNameByHandleW;", got)
        self.assertIn("_ = windows_ext.kernel32.GetLastError;", got)
        self.assertEqual(got.count("const windows_ext"), 1)
        self.assertEqual(len(hits), 4)

    def test_added_binding_follows_the_matched_initializer(self):
        # council F8: a comment that mentions internal_os does not make the added binding `internal_os.windows_ext`
        # (an undefined name here); it is derived from the matched binding's own initializer.
        for init, want in (("os.windows", "os.windows_ext"), ("internal_os.windows", "internal_os.windows_ext"),
                           ('@import("../os/main.zig").windows', '@import("../os/main.zig").windows_ext')):
            with self.subTest(init=init):
                src = ('// internal_os is the module this file once imported\nconst os = @import("../os/main.zig");\n'
                       f'const w = {init};\nfn f() void {{\n    _ = w.detectProcessArchitecture();\n}}\n')
                got, hits = self.run_sweep(src, "src/apprt/x.zig", [("detectProcessArchitecture", "ext")])
                self.assertIn(f"const w = {init};\nconst windows_ext = {want};\n", got)
                self.assertIn("_ = windows_ext.detectProcessArchitecture();", got)
                self.assertEqual(len(hits), 1)

    def test_more_than_one_candidate_binding_is_a_hand_edit(self):
        # council G9: with a local `os.windows` alias and a later file-scope `internal_os.windows` alias, the sweep
        # added windows_ext beside the first, inside a function, where a use in another function cannot see it.
        # More than one binding of the windows module (or of windows_ext) leaves the file to a hand edit: nothing in
        # it is rewritten, and each use the sweep would re-point is reported.
        entries = [("detectProcessArchitecture", "ext")]
        two_windows = ('const internal_os = @import("../os/main.zig");\nfn f() void {\n    const os = internal_os;\n'
                       '    const w = os.windows;\n    _ = w.detectProcessArchitecture();\n}\n'
                       'const windows = internal_os.windows;\n'
                       'fn g() void {\n    _ = windows.detectProcessArchitecture();\n}\n')
        two_ext = ('const windows = internal_os.windows;\nconst ext = internal_os.windows_ext;\nfn f() void {\n'
                   '    const local_ext = internal_os.windows_ext;\n    _ = local_ext;\n}\n'
                   'fn g() void {\n    _ = windows.detectProcessArchitecture();\n}\n')
        for src, why in ((two_windows, b1_sweep.MANY_BINDINGS.format("os/windows", "4, 7")),
                         (two_ext, b1_sweep.MANY_BINDINGS.format("os/windows_ext", "2, 4"))):
            with self.subTest(why=why):
                hand = []
                self.assertEqual(b1_sweep.sweep(src, "src/apprt/x.zig", entries, hand), (src, []))
                lines = [n + 1 for n, line in enumerate(src.split("\n")) if ".detectProcessArchitecture" in line]
                self.assertEqual(hand, [("detectProcessArchitecture", "ext", n, why) for n in lines])
        # One binding of each is the sweep's as before, and a file with nothing to re-point reports nothing.
        one = two_ext.replace("    const local_ext = internal_os.windows_ext;\n    _ = local_ext;\n", "")
        got, hits = self.run_sweep(one, "src/apprt/x.zig", entries)
        self.assertIn("_ = ext.detectProcessArchitecture();", got)
        self.assertEqual(len(hits), 1)
        hand = []
        self.assertEqual(b1_sweep.sweep(two_windows, "src/apprt/x.zig", [("knownFolderPathUtf8", "ext")], hand),
                         (two_windows, []))
        self.assertEqual(hand, [])

    def test_other_receivers_left_alone(self):
        src = ('const w = @import("std").os.windows;\nconst os_windows = @import("../os/windows.zig");\n'
               'fn f() void {\n    _ = w.CloseHandle;\n    _ = self.os_windows.CloseHandle;\n}\n')
        got, hits = self.run_sweep(src, "src/config/x.zig", [("CloseHandle", "ext")])
        self.assertEqual(got, src)
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
