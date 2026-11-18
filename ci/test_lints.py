"""Executable controls for PLAN 4.1/4.2 and the CI event/diff contract."""

import contextlib
import argparse
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
from generate_win32_identifiers import generate as generate_removed

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

    def test_unbaselined_moved_line_and_duplicate_twin(self):
        line = '.data = try alloc.dupe(u8, "*" ** 64),'
        before = "\n".join([line] * 7)
        self.assertEqual([], self.check(before, "// moved\n" + before))
        self.assertTrue(self.check(before, "// moved\n" + before + "\n" + line))
        self.assertEqual([], self.check(before, before))

    def test_stack_fallback_import_and_alias_routes(self):
        for source in ('const heap = std.heap;\nheap.stackFallback(64, alloc);',
                       '@import("std").heap.stackFallback(64, alloc);',
                       'const heap = @import("std").heap;\nheap.stackFallback(64, alloc);',
                       'const sf = std.heap.stackFallback;\nsf(64, alloc);'):
            with self.subTest(source=source):
                self.assertTrue(self.check("", source))
        self.assertEqual([], self.check("", "const heap = local.heap; heap.stackFallback(64, alloc);"))

    def test_pointer_to_pointer_is_not_binary_repeat(self):
        for source in ('const P = **u8;', 'const P = **const u8;', 'const P = ?**volatile u8;',
                       'const P = [2]**const u8;', 'const P = []**u8;',
                       'fn f() **const u8 { unreachable; }', 'const P = fn () **const u8;'):
            with self.subTest(source=source):
                self.assertEqual([], self.check("", source))
        for value in ('"x"', '[_]u8{0}', 'make()', '(value)', 'arrays[0]'):
            self.assertTrue(self.check("", "const repeated = " + value + " ** 2;"))
            self.assertTrue(self.check("", "return " + value + " ** 2;"))

    def test_hasdecl_target_line_is_in_review_span(self):
        source = '@hasDecl(\n T,\n "hook"\n);'
        self.assertEqual(1, len(zig.check_file("x.zig", "", source, {2}, {})))

    def test_tip_consumption_is_counted_for_stale_pr(self):
        baseline = {("glyf.zig", "stackFallback", LINE): 2}
        rows = zig.check_file("glyf.zig", LINE, LINE + "\n" + LINE, {2}, baseline,
                              tip=LINE + "\n" + LINE)
        self.assertTrue(rows)


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

    def test_const_volatile_and_slice_prefixes(self):
        removed = {"RECT", "HRESULT", "KNOWNFOLDERID"}
        for prefix in ("*", "*const ", "?*const ", "[]const ", "[*]const ",
                       "[*c]const ", "*align(8) const ", "*volatile ", "?[*]volatile "):
            for root in ("std.os.windows", "windows"):
                source = "const windows = std.os.windows;\nfn f(x: " + prefix + root + ".RECT) void {}"
                with self.subTest(prefix=prefix, root=root):
                    rows = list(win.Bindings(source).uses(removed))
                    self.assertEqual(1, len(rows))
                    self.assertEqual("RECT", rows[0][0])

    def test_real_const_rect_at_old_pin(self):
        repo = Path(__file__).resolve().parent.parent
        name = "src/apprt/win32_compositor_window_content_native.zig"
        text = common.sources(repo, "31796f5d093fce41446411c5c381b602c1c55757", {name})[name]
        self.assertEqual("?*const windows.RECT,", text.splitlines()[514].strip())
        self.assertTrue(any(key == "RECT" and line == 515
                            for key, span, line in win.Bindings(text, path=name).uses({"RECT"})))

    def test_inline_std_and_relative_reexport_imports(self):
        cases = ('@import("std").os.windows.kernel32.Sleep(1);',
                 'const w = @import("../../os/windows.zig"); w.kernel32.Sleep(1);',
                 '@import("../../os/windows.zig").kernel32.Sleep(1);',
                 'const internal_os = @import("../../os/windows.zig"); internal_os.kernel32.Sleep(1);')
        for source in cases:
            with self.subTest(source=source):
                rows = list(win.Bindings(source, EXPORTS, "src/apprt/win32/probe.zig").uses(REMOVED))
                self.assertTrue(rows)
                self.assertEqual("kernel32.Sleep", rows[-1][0])
                self.assertEqual([], list(win.Bindings(source.replace("Sleep", "Retained"), EXPORTS,
                                                      "src/apprt/win32/probe.zig").uses(REMOVED)))

    def test_computed_forms_are_a_documented_limit(self):
        for source in ('(std.os.windows.kernel32).Sleep(1);',
                       'const S = struct { const k = std.os.windows.kernel32; }; S.k.Sleep(1);',
                       'const k = comptime std.os.windows.kernel32; k.Sleep(1);'):
            self.assertEqual([], self.uses(source))

    def test_full_removed_set_includes_new_names_and_namespaces(self):
        removed = set(Path(__file__).with_name("win32-removed-identifiers.txt").read_text().splitlines())
        for expression in ("std.os.windows.CreatePipe", "std.os.windows.advapi32.RegSetValueExW"):
            self.assertTrue(list(win.Bindings(expression + "();").uses(removed)))

    def test_generator_enumerates_public_names_without_a_repo(self):
        root = Path(tempfile.mkdtemp(prefix="lint-std-control-"))
        for name in ("std15", "std17"):
            (root / name / "os/windows").mkdir(parents=True)
        (root / "std15/os/windows.zig").write_text('pub const kernel32 = @import("windows/kernel32.zig");\n'
            'pub const advapi32 = @import("windows/advapi32.zig");\npub const Removed = u8;\n', encoding="utf-8")
        (root / "std17/os/windows.zig").write_text('pub const kernel32 = @import("windows/kernel32.zig");\n', encoding="utf-8")
        (root / "std15/os/windows/kernel32.zig").write_text('pub extern "kernel32" fn Gone() void;\npub fn Kept() void {}', encoding="utf-8")
        (root / "std17/os/windows/kernel32.zig").write_text('pub fn Kept() void {}', encoding="utf-8")
        (root / "std15/os/windows/advapi32.zig").write_text('pub inline fn AlsoGone() void {}\nconst private = 1;', encoding="utf-8")
        (root / "std15/os/windows/unexported.zig").write_text('pub const Unreachable = 1;', encoding="utf-8")
        self.assertEqual({"Removed", "advapi32", "advapi32.AlsoGone", "kernel32.Gone"},
                         set(generate_removed(root / "std17", root / "std15").splitlines()))


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
        removed.write_text("kernel32.Sleep\n", encoding="utf-8")
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

    def inputs(self):
        upstream, removed, baseline = (self.repo / p for p in ("paths.txt", "removed.txt", "baseline.txt"))
        upstream.write_text("src/os/windows.zig\n", encoding="utf-8")
        removed.write_text("kernel32.Sleep\n", encoding="utf-8")
        baseline.write_text("", encoding="utf-8")
        return upstream, removed, baseline

    def test_unrebased_main_removal_and_new_occurrence_twin(self):
        self.write("src/os/windows.zig", "// reexports\n")
        self.write("x.zig", "const old = @Type(.{});\nstd.os.windows.kernel32.Sleep(1);\n")
        common_parent = self.commit()
        self.write("x.zig", "// main removed both calls\n")
        base_tip = self.commit()
        common.git(self.repo, "checkout", "--detach", common_parent)
        self.write("x.zig", "const old = @Type(.{});\nstd.os.windows.kernel32.Sleep(1);\nconst unrelated = 1;\n")
        head = self.commit()
        upstream, removed, baseline = self.inputs()
        self.assertEqual({"x.zig": {3}}, common.added_lines(self.repo, base_tip, head))
        self.assertEqual([], zig.check(self.repo, base_tip, head, baseline))
        self.assertEqual([], win.check(self.repo, base_tip, head, upstream, removed))
        self.write("x.zig", common.sources(self.repo, head, {"x.zig"})["x.zig"] +
                   "const extra = @Type(.{});\nstd.os.windows.kernel32.Sleep(2);\n")
        twin = self.commit()
        self.assertTrue(zig.check(self.repo, base_tip, twin, baseline))
        self.assertTrue(win.check(self.repo, base_tip, twin, upstream, removed))

    def test_forced_text_diff_attributes_nul_and_user_configuration(self):
        self.write("src/os/windows.zig", "// reexports\n")
        for name in ("minus", "binary", "driver", "nulprobe"):
            self.write(name + ".zig", "// before\n")
        self.write(".gitattributes", "minus.zig -diff\nbinary.zig binary\ndriver.zig diff=hostile\n")
        base = self.commit()
        for name in ("minus", "binary", "driver", "nulprobe"):
            self.write(name + ".zig", ("// NUL \0\n" if name == "nulprobe" else "// before\n") +
                       "const x = @Type(.{});\nstd.os.windows.kernel32.Sleep(1);\n")
        head = self.commit()
        upstream, removed, baseline = self.inputs()
        for key, value in (("color.diff", "always"), ("color.ui", "always"),
                           ("diff.hostile.binary", "true"), ("diff.hostile.command", "exit 91"),
                           ("diff.hostile.textconv", "exit 92"), ("diff.external", "exit 93"),
                           ("diff.algorithm", "histogram"), ("diff.relative", "true"),
                           ("diff.context", "12"), ("diff.interHunkContext", "50")):
            common.git(self.repo, "config", key, value)
        with patch.dict(os.environ, {"GIT_EXTERNAL_DIFF": "exit 94", "GIT_DIFF_OPTS": "--unified=99"}):
            added = common.added_lines(self.repo, base, head)
            self.assertEqual({"minus.zig": {2, 3}, "binary.zig": {2, 3},
                              "driver.zig": {2, 3}, "nulprobe.zig": {1, 2, 3}}, added)
            self.assertEqual(4, len(zig.check(self.repo, base, head, baseline)))
            self.assertEqual(4, len(win.check(self.repo, base, head, upstream, removed)))
            # Exercise the real CLI too: report cannot swallow tool/input errors.
            for script, extra in (("zig017_lint.py", ["--baseline", str(baseline)]),
                                  ("win32_ident_lint.py", ["--mode", "enforce", "--upstream-paths",
                                   str(upstream), "--removed-identifiers", str(removed)])):
                result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name(script)),
                    "--repo", str(self.repo), "--base", base, "--head", head, *extra],
                    capture_output=True, text=True,
                    env={**os.environ, "GITHUB_STEP_SUMMARY": "", "GITHUB_ACTIONS": "false"})
                self.assertEqual(1, result.returncode, result.stdout)

    def test_alias_definition_change_rechecks_unchanged_transitive_uses(self):
        self.write("src/os/windows.zig", "pub const kernel32 = windows.kernel32;\n")
        old = ('const source = local.sys;\nconst k = source;\n'
               'fn f() void { k.Sleep(1); }\n')
        self.write("src/apprt/win32/probe.zig", old)
        base = self.commit()
        upstream, removed, _ = self.inputs()
        for route in ('std.os.windows.kernel32', '@import("std").os.windows.kernel32',
                      '@import("../../os/windows.zig").kernel32'):
            with self.subTest(route=route):
                self.write("src/apprt/win32/probe.zig", old.replace("local.sys", route))
                head = self.commit()
                rows = win.check(self.repo, base, head, upstream, removed)
                self.assertTrue(any(row[1] == 3 for row in rows))
        self.write("src/apprt/win32/probe.zig", old.replace("local.sys", "win32.sys"))
        twin = self.commit()
        self.assertEqual([], win.check(self.repo, base, twin, upstream, removed))

    def test_changed_blob_without_hunk_fails_closed_but_mode_change_passes(self):
        self.write("x.zig", "// before\n")
        base = self.commit()
        self.write("x.zig", "const x = @Type(.{});\n")
        head = self.commit()
        real_git = common.git
        def no_hunk(repo, *args):
            if args[0] == "diff" and "--name-only" not in args:
                return b"Binary files differ\n"
            return real_git(repo, *args)
        with patch.object(common, "git", side_effect=no_hunk), self.assertRaises(ValueError):
            common.added_lines(self.repo, base, head)
        common.git(self.repo, "update-index", "--chmod=+x", "x.zig")
        common.git(self.repo, "commit", "-qm", "mode only")
        mode = common.revision(self.repo, "HEAD")
        self.assertEqual({}, common.added_lines(self.repo, head, mode))

    def test_lint_self_edits_are_reviewed_in_real_job_summary(self):
        self.write("src/os/windows.zig", "// reexports\n")
        base = self.commit()
        for name in ("ci/zig017_lint.py", "ci/zig017-lint-baseline.txt",
                     "ci/win32-removed-identifiers.txt", ".github/workflows/test.yml",
                     "test/windows/flagship/contracts/Contracts.90-Workflows.ps1"):
            self.write(name, "// control\n")
        head = self.commit()
        summary = self.repo / "summary.md"
        result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("run_lints.py")),
            "--win32-mode", "report"], cwd=self.repo, capture_output=True, text=True,
            env={**os.environ, "LINT_EVENT": "pull_request", "LINT_BASE": base, "LINT_HEAD": head,
                 "GITHUB_STEP_SUMMARY": str(summary)})
        self.assertEqual(0, result.returncode, result.stderr)
        content = summary.read_text(encoding="utf-8")
        self.assertIn("5 review flags", content)
        self.assertIn("Migration lint implementation/data review", content)
        self.assertIn("ci/win32-removed-identifiers.txt", content)

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

    def test_invalid_removed_inventory_fails_closed(self):
        self.write("src/os/windows.zig", "// reexports\n")
        base = self.commit()
        upstream, removed, _ = self.inputs()
        for content in ("", "kernel32.Sleep\nkernel32.Sleep\n", "z\na\n"):
            removed.write_text(content, encoding="utf-8")
            with self.assertRaises(ValueError):
                win.check(self.repo, base, base, upstream, removed)

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
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--proxy-repo")
    parser.add_argument("--proxy-ref", default="trial-hybrid")
    parser.add_argument("--proxy-output", type=Path)
    options, rest = parser.parse_known_args()
    if options.proxy_repo:
        if options.proxy_output is None:
            parser.error("--proxy-repo requires --proxy-output")
        class ApprovedProxyControls(unittest.TestCase):
            def test_real_1a_proxy_and_duplicate_twin(self):
                from lint_proxy_control import run
                result = run(options.proxy_repo, options.proxy_ref, options.proxy_output)
                self.assertEqual((8, 9), (result["baseline_entries"], result["baseline_allowance"]))
    unittest.main(argv=[sys.argv[0], *rest], verbosity=2)
