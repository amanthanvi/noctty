"""Executable controls for PLAN 4.1/4.2 and the CI event/diff contract."""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lint_common as common
import win32_ident_lint as win
import zig017_lint as zig
from generate_zig017_baseline import generate

LINE = "var flags_stack = std.heap.stackFallback(4096, alloc);"
REMOVED = {"kernel32.Sleep", "kernel32.GetLastError", "sliceToPrefixedFileW"}
EXPORTS = {"kernel32": ["kernel32"], "sliceToPrefixedFileW": ["sliceToPrefixedFileW"]}


class BaselineControls(unittest.TestCase):
    def check(self, before, after, baseline=None, path="glyf.zig", fork=""):
        return [f for f in zig.check_file(path, before, after, set(range(1, 100)),
                                        baseline or {}, fork) if f[2] == "error"]

    def test_unchanged_baselined_line_and_exhausted_twin(self):
        baseline = {("glyf.zig", "stackFallback", LINE): 1}
        self.assertEqual([], self.check(LINE, LINE, baseline))
        self.assertEqual(2, len(self.check(LINE, LINE + "\n" + LINE, baseline)))

    def test_other_path_negative_and_approved_path_twin(self):
        baseline = {("glyf.zig", "stackFallback", LINE): 1}
        self.assertTrue(self.check("", LINE, baseline, path="other.zig"))
        self.assertEqual([], self.check("", LINE, baseline))

    def test_identical_line_in_another_function_and_removal_twin(self):
        baseline = {("glyf.zig", "stackFallback", LINE): 1}
        before = "fn first() void {\n" + LINE + "\n}"
        after = before + "\nfn second() void {\n" + LINE + "\n}"
        self.assertTrue(self.check(before, after, baseline))
        self.assertEqual([], self.check(after, before, baseline))

    def test_other_failing_form_negative_and_literal_twin(self):
        baseline = {("glyf.zig", "stackFallback", LINE): 1}
        self.assertTrue(self.check(LINE, LINE + "\nconst a = [_]u8{0} ** 2;", baseline))
        self.assertEqual([], self.check(LINE, LINE + '\nconst s = "**";', baseline))

    def test_forward_merge_readd_and_excess_twin(self):
        baseline = {("glyf.zig", "stackFallback", LINE): 2}
        self.assertEqual([], self.check("", LINE + "\n" + LINE, baseline))
        self.assertTrue(self.check("", "\n".join([LINE] * 3), baseline))

    def test_fork_parent_occurrences_do_not_consume_allowance(self):
        baseline = {("glyf.zig", "stackFallback", LINE): 1}
        self.assertEqual([], self.check(LINE, LINE + "\n" + LINE, baseline, fork=LINE))
        self.assertTrue(self.check(LINE + "\n" + LINE, "\n".join([LINE] * 3), baseline, fork=LINE))

    def test_remaining_allowance_never_negative(self):
        baseline = {("glyf.zig", "stackFallback", LINE): 1}
        self.assertEqual([], self.check("\n".join([LINE] * 3), "\n".join([LINE] * 3), baseline))
        self.assertTrue(self.check("\n".join([LINE] * 3), "\n".join([LINE] * 4), baseline))

    def test_all_failing_forms_and_literal_comment_twins(self):
        for source, form in (("const a = [_]u8{0} ** 2;", "**"),
                             ("const T = @Type(.{});", "@Type"),
                             ("const c = @cImport({});", "@cImport"),
                             (LINE, "stackFallback"),
                             ("errdefer |e| report(e);", "errdefer-capture")):
            with self.subTest(form=form):
                self.assertEqual(form, self.check("", source)[0][3])
                for hidden in ("// " + source, "/// " + source, "//! " + source,
                               'const s = "' + source + '";', "const s =\n\\\\" + source + "\n;",
                               'const @"' + source + '" = 1;'):
                    self.assertEqual([], self.check("", hidden))

    def test_multiline_construct_and_literal_barriers(self):
        source = "errdefer // capture\n |e| report(e);\nconst x = std\n.heap\n.stackFallback(1, alloc);"
        self.assertEqual(2, len(self.check("", source)))
        self.assertEqual(1, len(zig.check_file("x.zig", "", source, {2}, {})))
        self.assertEqual([], self.check("", 'const s = "std.heap.stackFallback";'))

    def test_review_flags_never_fail(self):
        source = "\n".join(("builtin.os; builtin.cpu; builtin.abi;", "@intFromEnum(x); @enumFromInt(x);",
                            "std.fmt.allocPrint(a, f, v);", "std.mem.containsAtLeastScalar(u8, s, 1, 0);",
                            '@hasDecl(T, "private");'))
        findings = zig.check_file("x.zig", "", source, set(range(1, 8)), {})
        self.assertEqual(8, len(findings))
        self.assertTrue(all(f[2] == "review" for f in findings))
        # Expected control findings must not enter the real Actions summary.
        with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, common.emit("control", findings))

    def test_private_hasdecl_and_pub_twin(self):
        source = 'const T = struct { fn hook() void {} };\nconst yes = @hasDecl(T, "hook");'
        self.assertTrue(list(zig.matches(source)))
        self.assertEqual([], list(zig.matches(source.replace("fn hook", "pub fn hook"))))

    def test_hasdecl_visibility_uses_its_own_container(self):
        source = ('const A = struct { const T = struct { fn hook() void {} };\n'
                  'fn probe() bool { return @hasDecl(T, "hook"); } };\n'
                  'const B = struct { const T = struct { pub fn hook() void {} }; };')
        self.assertEqual(1, len(zig.matches(source)))
        self.assertEqual(0, len(zig.matches(source.replace("{ fn hook", "{ pub fn hook"))))


class Win32Controls(unittest.TestCase):
    def uses(self, source):
        return list(win.Bindings(source, EXPORTS).uses(REMOVED))

    def test_required_namespaces_and_alias_twins(self):
        for expression in ("std.os.windows.kernel32.Sleep", "win32.windows.kernel32.Sleep",
                           "internal_os.windows.kernel32.Sleep", "os.windows.kernel32.Sleep"):
            with self.subTest(expression=expression):
                self.assertTrue(self.uses(expression + "(1);"))
                self.assertEqual([], self.uses(expression.replace("Sleep", "Retained") + "(1);"))
                for alias in ("k32", "w", "kernel32"):
                    source = f"const {alias} = {expression.rsplit('.', 1)[0]};\n{alias}.Sleep(1);"
                    self.assertTrue(self.uses(source))
                    self.assertEqual([], self.uses(source.replace(".Sleep", ".Retained")))

    def test_import_aliases_and_chains(self):
        for source in ('const s = @import("std"); const w = s.os.windows; const k = w.kernel32; k.Sleep(1);',
                       'const std = @import("std"); const w = std.os.windows; const k = w.kernel32; k.Sleep(1);',
                       'const win32 = @import("../win32.zig"); const w = win32.windows; w.kernel32.Sleep(1);',
                       'const internal_os = @import("../../os/main.zig"); const w = internal_os.windows; w.kernel32.Sleep(1);',
                       'const k = (std.os.windows.kernel32); k.@"Sleep"(1);',
                       'const k = std.os.windows.kernel32; const call = k.Sleep; call(1);'):
            with self.subTest(source=source):
                self.assertTrue(self.uses(source))

    def test_rehomed_call_passes_and_std_twin_fails(self):
        self.assertEqual([], self.uses('const sys = @import("win32/sys.zig"); sys.Sleep(1);'))
        self.assertTrue(self.uses('const k32 = std.os.windows.kernel32; k32.Sleep(1);'))

    def test_alias_scope_and_rehomed_shadow(self):
        source = ('const k = std.os.windows.kernel32;\n'
                  'fn a() void { const k = local.sys; k.Sleep(1); }\n'
                  'fn b() void { k.Sleep(1); }')
        uses = self.uses(source)
        self.assertEqual(1, len(uses))
        self.assertEqual(3, uses[0][2])

    def test_comments_strings_multiline_and_reexports(self):
        self.assertEqual([], self.uses('// std.os.windows.kernel32.Sleep(1);\nconst s = "std.os.windows.kernel32.Sleep";'))
        self.assertTrue(self.uses("std // root\n.os.windows\n.kernel32.Sleep(1);"))
        self.assertTrue(self.uses("internal_os.windows.sliceToPrefixedFileW(path);"))
        self.assertEqual(EXPORTS, win.reexports('pub const kernel32 = windows.kernel32;\n'
                         'pub const sliceToPrefixedFileW = windows.sliceToPrefixedFileW;'))

    def test_report_switch(self):
        rows = [("x.zig", 1, "error", "removed std.os.windows.kernel32.Sleep")]
        with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, common.emit("control", rows, "report"))
            self.assertEqual(1, common.emit("control", rows, "enforce"))

    def test_public_sibling_and_private_shadow_do_not_hide_std(self):
        source = ('const sys = struct { pub fn Sleep() void {} };\n'
                  'const k32 = std.os.windows.kernel32;\n'
                  'fn a() void { sys.Sleep(); }\nfn b() void { k32.Sleep(1); }')
        self.assertEqual(1, len(self.uses(source)))


class GitControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = Path(tempfile.mkdtemp(prefix="noctty-lint-controls-"))
        print("Retained Git control fixtures:", cls.scratch)

    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(dir=self.scratch))
        common.git(self.repo, "init", "-q")
        common.git(self.repo, "config", "user.name", "Lint Control")
        common.git(self.repo, "config", "user.email", "lint@example.invalid")
        common.git(self.repo, "config", "core.autocrlf", "false")

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")

    def commit(self):
        common.git(self.repo, "add", ".")
        common.git(self.repo, "commit", "-qm", "control", "--allow-empty")
        return common.revision(self.repo, "HEAD")

    def test_real_diff_added_lines_and_rename(self):
        unchanged = "".join(f"const a{i} = {i};\n" for i in range(10))
        self.write("old name.zig", unchanged)
        base = self.commit()
        common.git(self.repo, "mv", "old name.zig", "new name.zig")
        self.write("new name.zig", unchanged + "const b = @Type(.{});\n")
        head = self.commit()
        self.assertEqual(set(range(1, 12)), common.added_lines(self.repo, base, head)["new name.zig"])
        self.assertIn("new name.zig", win.fork_added(self.repo, head, {"old name.zig"}))
        self.assertNotIn("new name.zig", win.fork_added(self.repo, head, {"old name.zig", "new name.zig"}))

    def test_new_fork_file_shared_file_and_rehome(self):
        self.write("src/os/windows.zig", "pub const kernel32 = windows.kernel32;\n")
        self.write("shared.zig", "// shared\n")
        self.write("src/apprt/win32/sys.zig", "// allow-listed fork file\n")
        self.write("src/apprt/win32.zig", "// Phase 1A adaptation file\n")
        base = self.commit()
        self.write("shared.zig", "std.os.windows.kernel32.Sleep(1);\n")
        self.write("new.zig", "std.os.windows.kernel32.Sleep(1);\n")
        self.write("src/apprt/win32/sys.zig", "std.os.windows.kernel32.Sleep(1);\n")
        self.write("src/apprt/win32.zig", "std.os.windows.kernel32.Sleep(1);\n")
        head = self.commit()
        upstream, removed = self.repo / "paths.txt", self.repo / "removed.txt"
        upstream.write_text("shared.zig\nsrc/os/windows.zig\n", encoding="utf-8")
        removed.write_text("\n".join(["kernel32.Sleep"] + [f"dummy{i}" for i in range(123)]), encoding="utf-8")
        rows = win.check(self.repo, base, head, upstream, removed)
        self.assertEqual(["new.zig", "src/apprt/win32.zig", "src/apprt/win32/sys.zig"], [r[0] for r in rows])
        for name in ("new.zig", "src/apprt/win32.zig", "src/apprt/win32/sys.zig"):
            self.write(name, "win32.sys.Sleep(1);\n")
        rehomed = self.commit()
        self.assertEqual([], win.check(self.repo, head, rehomed, upstream, removed))

    def test_literal_diff_paths_and_forced_git_color(self):
        self.write("glob[1].zig", "const a = 1;\n")
        self.write("glob1.zig", "const b = 1;\n")
        base = self.commit()
        self.write("glob[1].zig", "const a = 1;\nconst x = @Type(.{});\n")
        self.write("glob1.zig", "const b = 2;\n")
        head = self.commit()
        common.git(self.repo, "config", "color.ui", "always")
        self.assertEqual({"glob[1].zig": {2}, "glob1.zig": {1}}, common.added_lines(self.repo, base, head))

    def test_generated_baseline_parent_and_forward_readd(self):
        self.write("glyf.zig", LINE + "\n")
        parent = self.commit()
        self.write("glyf.zig", LINE + "\n" + LINE + "\n")
        result = self.commit()
        baseline = self.repo / "baseline.txt"
        baseline.write_text(generate(self.repo, parent, result), encoding="utf-8")
        fork, rows = zig.read_baseline(baseline)
        self.assertEqual(parent, fork)
        self.assertEqual(1, rows["glyf.zig", "stackFallback", LINE])
        self.assertEqual([], zig.check(self.repo, parent, result, baseline))
        self.write("glyf.zig", LINE + "\n")
        removed = self.commit()
        self.write("glyf.zig", LINE + "\n" + LINE + "\n")
        readded = self.commit()
        self.assertEqual([], zig.check(self.repo, removed, readded, baseline))
        self.write("glyf.zig", "\n".join([LINE] * 3))
        excess = self.commit()
        self.assertTrue(zig.check(self.repo, readded, excess, baseline))

    def test_invalid_baseline_fails_closed(self):
        baseline = self.repo / "baseline.txt"
        for text in (f"glyf.zig\tstackFallback\t1\t{LINE}\n",
                     f"# fork-parent: {'a' * 40}\nglyf.zig\tstackFallback\t0\t{LINE}\n",
                     f"# fork-parent: {'a' * 40}\nglyf.zig\tunknown\t1\t{LINE}\n"):
            baseline.write_text(text, encoding="utf-8")
            with self.assertRaises(ValueError):
                zig.read_baseline(baseline)
        baseline.write_text("", encoding="utf-8")
        self.assertEqual((None, {}), zig.read_baseline(baseline))

    def test_pr_push_nightly_and_missing_commit(self):
        self.write("x.zig", "// base\n")
        base = self.commit()
        self.write("x.zig", "// head\n")
        head = self.commit()
        for event in ({"event_name": "pull_request", "base": base, "head": head},
                      {"event_name": "push", "before": base, "head": head},
                      {"event_name": "schedule", "head": head},
                      {"event_name": "workflow_dispatch", "head": head}):
            self.assertEqual((base, head), common.ci_revisions(self.repo, event))
        with self.assertRaises(ValueError):
            common.ci_revisions(self.repo, {"event_name": "push", "before": "0" * 40, "head": head})
        with self.assertRaises(subprocess.CalledProcessError):
            common.ci_revisions(self.repo, {"event_name": "pull_request", "base": "no-such-ref", "head": head})


if __name__ == "__main__":
    unittest.main(verbosity=2)
