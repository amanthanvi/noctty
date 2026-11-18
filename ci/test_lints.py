"""Executable controls for PLAN 4.1/4.2 and the CI event/diff contract."""

import contextlib
import argparse
import ast
import io
import json
import os
import re
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
EXPORTS = {"kernel32": ["os", "windows", "kernel32"],
           "sliceToPrefixedFileW": ["os", "windows", "sliceToPrefixedFileW"]}


def fixture_commit_pins(files):
    """Find every SHA literal in executable controls, including abbreviated pins."""
    return [(path.name, node.lineno, node.value) for path in files
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8")))
            if isinstance(node, ast.Constant) and isinstance(node.value, str)
            and re.fullmatch(r"[0-9a-f]{7,40}", node.value)]


def require_main_fixture_history(repo, pins):
    """A fetched PR branch is temporary; fixture commits must survive its deletion."""
    for path, line, pin in pins:
        try:
            common.git(repo, "merge-base", "--is-ancestor", common.revision(repo, pin), "origin/main")
        except subprocess.CalledProcessError as error:
            raise AssertionError(f"{path}:{line}: fixture commit {pin} is not an ancestor of origin/main") from error


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

    def test_pointer_expression_contexts_and_binary_twins(self):
        from lint_compiler_control import TYPE_SOURCE, REPEAT_SOURCE
        self.assertEqual([], self.check("", TYPE_SOURCE))
        rows = self.check("", REPEAT_SOURCE)
        self.assertEqual(12, len(rows))
        self.assertTrue(all(row[3] == "**" for row in rows))
        # The approved mechanical proxy has a stray brace. It must not turn
        # this lexical lint into a whole-file syntax gate.
        self.assertEqual([], self.check("", "}\nconst P = **u8;"))
        self.assertTrue(self.check("", '}\nconst a = "x" ** 2;'))

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

    def test_windows_import_spellings_and_known_routes(self):
        from lint_compiler_control import IMPORT_PATHS
        path = "src/apprt/win32/probe.zig"
        for label, spelling, accepted in IMPORT_PATHS:
            source = 'const w = @import(' + json.dumps(spelling) + '); w.kernel32.GetLastError();'
            with self.subTest(spelling=label):
                rows = list(win.Bindings(source, EXPORTS, path).uses(REMOVED))
                self.assertEqual(accepted, bool(rows))
        # Layout-dependent native acceptance remains a safe-side lint match.
        for spelling in ("../../os./windows.zig", r"..\..\os.\windows.zig"):
            source = 'const w = @import(' + json.dumps(spelling) + '); w.kernel32.GetLastError();'
            self.assertTrue(list(win.Bindings(source, EXPORTS, path).uses(REMOVED)))
        for route, tail in (("../../os/windows.zig", "kernel32.GetLastError"),
                            ("../../os/main.zig", "windows.kernel32.GetLastError"),
                            ("../../os.zig", "windows.kernel32.GetLastError"),
                            ("../win32.zig", "windows.kernel32.GetLastError")):
            for spelling in (route, route.replace("/", "\\"), route.replace("/", "\\", 1)):
                source = 'const w = @import(' + json.dumps(spelling) + '); w.' + tail + '();'
                self.assertTrue(list(win.Bindings(source, EXPORTS, path).uses(REMOVED)))
        wrong = 'const w = @import("../os/windows.zig"); w.kernel32.GetLastError();'
        rehomed = 'const w = @import("sys.zig"); w.kernel32.GetLastError();'
        self.assertEqual([], list(win.Bindings(wrong, EXPORTS, path).uses(REMOVED)))
        self.assertEqual([], list(win.Bindings(rehomed, EXPORTS, path).uses(REMOVED)))

    def test_computed_forms_are_a_documented_limit(self):
        for source in ('(std.os.windows.kernel32).Sleep(1);',
                       'const S = struct { const k = std.os.windows.kernel32; }; S.k.Sleep(1);',
                       'const k = comptime std.os.windows.kernel32; k.Sleep(1);'):
            self.assertEqual([], self.uses(source))

    def test_full_removed_set_includes_new_names_and_namespaces(self):
        removed = set(Path(__file__).with_name("win32-removed-identifiers.txt").read_text().splitlines())
        for expression in ("std.os.windows.CreatePipe", "std.os.windows.advapi32.RegSetValueExW"):
            self.assertTrue(list(win.Bindings(expression + "();").uses(removed)))

    def test_nested_removed_names_and_real_registry_line(self):
        removed = set(Path(__file__).with_name("win32-removed-identifiers.txt").read_text().splitlines())
        for key in ("REG.DWORD", "REG.BINARY", "ws2_32.SOCK.CLOEXEC", "ws2_32.SOCK.NONBLOCK",
                    "ws2_32.MSG.ERRQUEUE", "advapi32.RRF.RT_DWORD", "KNOWNFOLDERID.parse"):
            self.assertIn(key, removed)
            self.assertEqual(key, list(win.Bindings("std.os.windows." + key).uses(removed))[0][0])
        repo = Path(__file__).resolve().parent.parent
        name = "src/os/color_scheme.zig"
        text = common.sources(repo, "263eacfa08ba4c4e550364760a935149863d41ec", {name})[name]
        self.assertIn("windows.REG.DWORD", text.splitlines()[46])
        self.assertTrue(any(key == "REG.DWORD" and line == 47
                            for key, span, line in win.Bindings(text, path=name).uses(removed)))

    def test_reexports_share_literal_resolver(self):
        for expression in ("windows.kernel32.Sleep", "std.os.windows.kernel32.Sleep",
                           '@import("std").os.windows.kernel32.Sleep', "w.kernel32.Sleep"):
            source = 'const std = @import("std"); const windows = std.os.windows; const w = windows;\n'
            source += "pub const call = " + expression + ";"
            self.assertEqual({"call": ["os", "windows", "kernel32", "Sleep"]}, win.reexports(source))
        exports = win.reexports('pub const s = @import("std");')
        self.assertEqual({"s": []}, exports)
        self.assertTrue(list(win.Bindings('internal_os.windows.s.os.windows.kernel32.Sleep(1);', exports).uses(REMOVED)))

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

    def test_generator_follows_nested_containers_imports_and_aliases(self):
        root = Path(tempfile.mkdtemp(prefix="lint-nested-control-"))
        for version in ("15", "17"):
            (root / version / "os/windows").mkdir(parents=True)
            (root / version / "os/windows.zig").write_text(
                'const private = @import("windows/detail.zig");\npub const Imported = private;\n'
                'pub const Outer = struct { pub const Inner = struct { ' +
                ('pub const Gone = 1;' if version == "15" else '') +
                ' }; pub const Alias = Inner; };\n', encoding="utf-8")
            (root / version / "os/windows/detail.zig").write_text(
                'pub const N = struct { ' + ('pub const Missing = 1;' if version == "15" else '') +
                ' const Hidden = 0; };\n', encoding="utf-8")
        self.assertEqual({"Outer.Inner.Gone", "Outer.Alias.Gone", "Imported.N.Missing"},
                         set(generate_removed(root / "17", root / "15").splitlines()))


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

    def test_fixture_history_guard_rejects_existing_branch_commit(self):
        self.write("source.zig", "// main\n")
        base = self.commit()
        common.git(self.repo, "update-ref", "refs/remotes/origin/main", base)
        self.write("source.zig", "// branch\n")
        branch = self.commit()
        control = self.repo / "test_fixture.py"
        for pin, accepted in ((base, True), (branch, False), ("f" * 40, False)):
            control.write_text("PIN = " + repr(pin) + "\n", encoding="utf-8")
            pins = fixture_commit_pins([control])
            self.assertEqual([(control.name, 1, pin)], pins)
            if accepted:
                require_main_fixture_history(self.repo, pins)
            else:
                with self.assertRaisesRegex(AssertionError, "not an ancestor of origin/main"):
                    require_main_fixture_history(self.repo, pins)

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

    def test_full_origin_changes_recheck_all_four_routes(self):
        self.write("src/os/windows.zig", "pub const kernel32 = windows.kernel32;\n")
        self.write("src/apprt/win32/sys.zig", 'pub const kernel32 = struct { pub fn Sleep(_: u32) void {} };\n'
                   'pub const windows = @This();\n')
        path = "src/apprt/win32/probe.zig"
        original = ('const k = @import("sys.zig");\n'
                    'fn direct() void { k.kernel32.Sleep(1); }\n'
                    'fn indirect() void { k.windows.kernel32.Sleep(1); }\n')
        self.write(path, original)
        base = self.commit()
        upstream, removed, _ = self.inputs()
        for route, line in (('@import("../../os/windows.zig")', 2), ("internal_os.windows", 2),
                            ("win32", 3), ("internal_os", 3)):
            with self.subTest(route=route):
                self.write(path, original.replace('@import("sys.zig")', route))
                head = self.commit()
                rows = win.check(self.repo, base, head, upstream, removed)
                self.assertEqual([(path, line)], [(r[0], r[1]) for r in rows])
                self.write(path, original)
                rehomed = self.commit()
                self.assertEqual([], win.check(self.repo, head, rehomed, upstream, removed))

    def test_windows_import_spellings_through_ci_entry(self):
        from lint_compiler_control import IMPORT_PATHS
        self.write("src/os/windows.zig", 'pub const kernel32 = @import("std").os.windows.kernel32;\n')
        path = "src/apprt/win32/probe.zig"
        self.write(path, "// empty probe\n")
        base = self.commit()
        for label, spelling, accepted in IMPORT_PATHS:
            if not accepted:
                continue
            self.write(path, 'const w = @import(' + json.dumps(spelling) + ');\n'
                       'pub fn call() void { _ = w.kernel32.GetLastError(); }\n')
            head = self.commit()
            result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("run_lints.py")),
                "--win32-mode", "enforce"], cwd=self.repo, capture_output=True, text=True,
                env={**os.environ, "LINT_EVENT": "pull_request", "LINT_BASE": base, "LINT_HEAD": head,
                     "GITHUB_STEP_SUMMARY": "", "GITHUB_ACTIONS": "false"})
            self.assertEqual(1, result.returncode, (label, result.stderr))
            self.assertIn("kernel32.GetLastError", result.stdout)
        # Re-spelling only the import must preserve the declaration origin;
        # the legacy call line itself did not change.
        forward = ('const w = @import("../../os/windows.zig");\n'
                   'pub fn call() void { _ = w.kernel32.GetLastError(); }\n')
        self.write(path, forward)
        before = self.commit()
        self.write(path, forward.replace("../../os/windows.zig", r"..\\..\\os\\windows.zig"))
        after = self.commit()
        here = Path(__file__).resolve().parent
        self.assertEqual([], win.check(self.repo, before, after, here / "upstream-paths.txt",
                                       here / "win32-removed-identifiers.txt"))

    def test_alias_move_visibility_comment_and_equivalent_origin_pass(self):
        self.write("src/os/windows.zig", "// reexports\n")
        source = ('const std = @import("std");\nconst w = std.os.windows.kernel32;\n'
                  'const unrelated = 1;\nfn f() void { w.Sleep(1); }\n')
        self.write("probe.zig", source)
        base = self.commit()
        upstream, removed, _ = self.inputs()
        variants = (source.replace("const w =", "pub const w ="),
                    source.replace("kernel32;", "kernel32; // Win32 API"),
                    source.replace("const w = std.os.windows.kernel32;\n", "").replace(
                        "const unrelated = 1;", "const unrelated = 1;\nconst w = std.os.windows.kernel32;"),
                    source.replace("std.os.windows.kernel32;", '@import("std").os.windows.kernel32;'))
        for variant in variants:
            self.write("probe.zig", variant)
            head = self.commit()
            self.assertEqual([], win.check(self.repo, base, head, upstream, removed))

    def test_alias_matching_keeps_function_scopes(self):
        self.write("src/os/windows.zig", "// reexports\n")
        first = 'fn first() void { const k = local.sys; k.Sleep(1); }\n'
        second = 'fn second() void { const k = std.os.windows.kernel32; k.Sleep(1); }\n'
        self.write("probe.zig", first + second)
        base = self.commit()
        upstream, removed, _ = self.inputs()
        self.write("probe.zig", first.replace("local.sys", "std.os.windows.kernel32") + second)
        head = self.commit()
        rows = win.check(self.repo, base, head, upstream, removed)
        self.assertEqual([1], [row[1] for row in rows])

    def test_reexport_changes_recheck_other_files_and_same_origin_twin(self):
        module = "src/os/windows.zig"
        source = 'const std = @import("std"); const windows = std.os.windows; const w = windows;\n'
        self.write(module, source + "pub const call = local.sys.Sleep;\n")
        self.write("probe.zig", 'const w = @import("src/os/windows.zig");\nfn f() void { w.call(1); }\n')
        base = self.commit()
        upstream, removed, _ = self.inputs()
        for route in ("windows.kernel32.Sleep", "std.os.windows.kernel32.Sleep", "w.kernel32.Sleep",
                      '@import("std").os.windows.kernel32.Sleep'):
            self.write(module, source + "pub const call = " + route + ";\n")
            head = self.commit()
            rows = win.check(self.repo, base, head, upstream, removed)
            self.assertEqual([("probe.zig", 2)], [(r[0], r[1]) for r in rows])
        # Changing the spelling or moving a re-export without changing its origin
        # does not recheck the unchanged caller.
        old = head
        self.write(module, source + '// moved\npub const call = windows.kernel32.Sleep; // comment\n')
        same = self.commit()
        self.assertEqual([], win.check(self.repo, old, same, upstream, removed))
        self.write(module, source + "pub const call = windows.kernel32.GetLastError;\n")
        changed = self.commit()
        removed.write_text("kernel32.GetLastError\nkernel32.Sleep\n", encoding="utf-8")
        self.assertTrue(win.check(self.repo, same, changed, upstream, removed))
        self.write(module, source + "pub const call = local.sys.Sleep;\n")
        rehomed = self.commit()
        self.assertEqual([], win.check(self.repo, changed, rehomed, upstream, removed))

    def test_git_environment_cannot_hide_paths_or_choose_another_repo(self):
        self.write("src/os/windows.zig", "// reexports\n")
        base = self.commit()
        self.write("glob[1].zig", 'const repeated = "a" ** 4;\nstd.os.windows.kernel32.Sleep(1);\n')
        head = self.commit()
        environments = [{name: "1"} for name in ("GIT_LITERAL_PATHSPECS", "GIT_NOGLOB_PATHSPECS",
                        "GIT_GLOB_PATHSPECS", "GIT_ICASE_PATHSPECS")]
        environments.append({**{name: "1" for row in environments for name in row},
            "GIT_DIR": "nonexistent-control-repo", "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "color.diff", "GIT_CONFIG_VALUE_0": "always",
            "GIT_DIFF_OPTS": "--unified=100", "GIT_EXTERNAL_DIFF": "exit 91"})
        for hostile in environments:
            result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("run_lints.py")),
                "--win32-mode", "enforce"], cwd=self.repo, capture_output=True, text=True,
                env={**os.environ, **hostile, "LINT_EVENT": "pull_request", "LINT_BASE": base,
                     "LINT_HEAD": head, "GITHUB_STEP_SUMMARY": "", "GITHUB_ACTIONS": "false"})
            self.assertEqual(1, result.returncode, result.stderr)
            self.assertIn("**", result.stdout)
            self.assertIn("kernel32.Sleep", result.stdout)

    def test_changed_blob_without_hunk_fails_closed_but_mode_change_passes(self):
        self.write("x.zig", "// before\n")
        base = self.commit()
        self.write("x.zig", "const x = @Type(.{});\n")
        head = self.commit()
        real_git = common.git
        def no_hunk(repo, *args, **kwargs):
            if args[0] == "diff" and "--name-only" not in args:
                return b"Binary files differ\n"
            return real_git(repo, *args, **kwargs)
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


class HistoryControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(__file__).resolve().parent.parent
        cls.repo = Path(tempfile.mkdtemp(prefix="lint-history-controls-"))
        common.git(cls.repo, "init", "-q")
        common.git(cls.repo, "config", "user.name", "Lint History Control")
        common.git(cls.repo, "config", "user.email", "lint@example.invalid")
        common.git(cls.repo, "config", "commit.gpgsign", "false")
        objects = common.git(cls.source, "rev-parse", "--path-format=absolute", "--git-path", "objects").decode().strip()
        (cls.repo / ".git/objects/info/alternates").write_text(objects.replace("\\", "/") + "\n",
                                                               encoding="utf-8", newline="\n")
        cls.base = "263eacfa08ba4c4e550364760a935149863d41ec"
        cls.ci = cls.source / "ci"

    def test_all_control_sha_literals_survive_branch_deletion(self):
        files = [path for path in self.ci.rglob("*.py")
                 if path.name.startswith("test_") or path.stem.endswith("_control")]
        pins = fixture_commit_pins(files)
        self.assertTrue(pins)
        require_main_fixture_history(self.source, pins)

    def fixture(self, path, source, parent=None):
        parent = parent or self.base
        blob = common.git(self.repo, "hash-object", "-w", "--stdin", input=source.encode()).decode().strip()
        common.git(self.repo, "read-tree", parent)
        common.git(self.repo, "update-index", "--cacheinfo", "100644," + blob + "," + path)
        tree = common.git(self.repo, "write-tree").decode().strip()
        return common.git(self.repo, "commit-tree", tree, "-p", parent, "-m", "alias control").decode().strip()

    def check(self, base, head):
        return win.check(self.repo, base, head, self.ci / "upstream-paths.txt", self.ci / "win32-removed-identifiers.txt")

    def test_real_import_swap_and_ipc_alias_move(self):
        path = "src/apprt/win32.zig"
        source = common.sources(self.repo, self.base, {path})[path]
        lines = source.splitlines(keepends=True)
        self.assertEqual('const std = @import("std");\n', lines[10])
        lines[10], lines[11] = lines[11], lines[10]
        self.assertEqual([], self.check(self.base, self.fixture(path, "".join(lines))))
        path = "src/apprt/win32/ipc_server.zig"
        source = common.sources(self.repo, self.base, {path})[path]
        lines = source.splitlines(keepends=True)
        at = lines.index("const windows = std.os.windows;\n")
        line = lines.pop(at)
        lines.insert(at + 2, line)
        self.assertEqual([], self.check(self.base, self.fixture(path, "".join(lines))))

    def test_real_refactors_do_not_recheck_unchanged_uses(self):
        for head in ("1c8d4d39463e43415f8e8de603ed7312ad907420", "2ec37a2c80f9dab40b06b036b66ca575487d633b"):
            base = common.revision(self.repo, head + "^")
            rows = self.check(base, head)
            added = common.added_lines(self.repo, base, head)
            unchanged = [row for row in rows if row[1] not in added.get(row[0], ())]
            self.assertEqual([], unchanged)
            if head.startswith("1c8d4d394"):
                self.assertEqual([], rows)
            else:
                self.assertEqual(45, len(rows))
                path = "src/apprt/win32.zig"
                module = "src/os/windows.zig"
                texts = common.sources(self.repo, head, {path, module})
                # With no previous snapshot, span() reproduces the old
                # declaration-touch rule, accounting for the removed 29 errors.
                legacy = win.Bindings(texts[path], win.reexports(texts[module]), path)
                old_false = {(key, line) for key, span, line in legacy.uses(
                    set((self.ci / "win32-removed-identifiers.txt").read_text().splitlines()))
                    if span & added.get(path, set()) and line not in added.get(path, set())}
                self.assertEqual(29, len(old_false))
            print("Historical alias control:", head[:9], "unchanged-use errors", len(unchanged),
                  "genuine added-line errors", len(rows))

    def test_real_pty_alias_revert_rechecks_46_unchanged_uses(self):
        base = self.base
        path = "src/pty_transport_probe.zig"
        source = common.sources(self.repo, base, {path})[path]
        before = 'const windows = internal_os.windows;'
        after = 'const windows = @import("apprt/win32/sys.zig");'
        self.assertEqual(1, source.count(before))
        rehomed = self.fixture(path, source.replace(before, after), parent=base)
        reverted = self.fixture(path, source, parent=rehomed)
        rows = self.check(rehomed, reverted)
        self.assertEqual(46, len(rows))
        added = common.added_lines(self.repo, rehomed, reverted)
        self.assertTrue(all(row[1] not in added.get(row[0], ()) for row in rows))
        twin = self.fixture(path, source.replace(before, after), parent=reverted)
        self.assertEqual([], self.check(reverted, twin))
        print("Real pty alias revert: 46 unchanged-use errors; re-homed twin: 0")

    def test_documented_safe_side_intermediate_alias_overreport(self):
        path = "src/apprt/win32/ipc_server.zig"
        source = common.sources(self.repo, self.base, {path})[path]
        variants = (
            (source.replace('const windows = std.os.windows;',
                            'const os = std.os;\nconst windows = os.windows;'), 40),
            (source.replace('const std = @import("std");',
                            'const zstd = @import("std");\nconst std = zstd;'), 40),
            (source.replace('const windows = std.os.windows;',
                            'const windows = @import("../../os/windows.zig");'), 32),
        )
        for text, count in variants:
            self.assertEqual(count, len(self.check(self.base, self.fixture(path, text))))
        print("Documented safe-side over-report retained: 40 / 40 / 32")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--proxy-repo")
    parser.add_argument("--proxy-ref", default="trial-hybrid")
    parser.add_argument("--proxy-output", type=Path)
    parser.add_argument("--compiler-output", type=Path)
    parser.add_argument("--zig017", type=Path)
    parser.add_argument("--pause-script", type=Path)
    options, rest = parser.parse_known_args()
    if options.proxy_repo:
        if options.proxy_output is None:
            parser.error("--proxy-repo requires --proxy-output")
        class ApprovedProxyControls(unittest.TestCase):
            def test_real_1a_proxy_and_duplicate_twin(self):
                from lint_proxy_control import run
                result = run(options.proxy_repo, options.proxy_ref, options.proxy_output)
                self.assertEqual((8, 9), (result["baseline_entries"], result["baseline_allowance"]))
    if options.compiler_output:
        if options.zig017 is None or options.pause_script is None:
            parser.error("--compiler-output requires --zig017 and --pause-script")
        class CompilerControls(unittest.TestCase):
            def test_both_compilers_and_removed_declaration_census(self):
                from lint_compiler_control import run
                result = run(Path(__file__).resolve().parent.parent, options.zig017,
                             options.compiler_output, options.pause_script)
                self.assertEqual(6, len(result["runs"]))
            def test_windows_import_spellings_on_015(self):
                from lint_compiler_control import IMPORT_PATHS, run_imports
                result = run_imports(Path(__file__).resolve().parent.parent,
                                     options.compiler_output / "imports", options.pause_script)
                self.assertEqual(len(IMPORT_PATHS), len(result))
    unittest.main(argv=[sys.argv[0], *rest], verbosity=2)
