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

    def test_other_receivers_left_alone(self):
        src = ('const w = @import("std").os.windows;\nconst os_windows = @import("../os/windows.zig");\n'
               'fn f() void {\n    _ = w.CloseHandle;\n    _ = self.os_windows.CloseHandle;\n}\n')
        got, hits = self.run_sweep(src, "src/config/x.zig", [("CloseHandle", "ext")])
        self.assertEqual(got, src)
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
