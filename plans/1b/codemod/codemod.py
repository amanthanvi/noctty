"""The 1B.5 codemod: the fork's Zig 0.15.2 spellings rewritten to Zig 0.17.1's, as rules over Zig's token stream.

PLAN.md row 1B.5 (U7) runs it once over the 1B tree and again at every forward merge through 1B.9, so every rule is
idempotent (a second run over its own output changes nothing) and has a test over a fixture (test_codemod.py). A rule
rewrites a form only where the rewrite is safe from the tokens alone; what needs a reader (an `Io` to thread, a
changed signature, a behaviour) is a hand edit, recorded in residue.tsv with its file and reason.

Usage:
  python plans/1b/codemod/codemod.py [--check] [--rules id,id] [--report out.tsv] <file or directory>...

Without --check it rewrites the files in place (LF kept; a file with CR bytes is refused) and prints one line per rule
with its hit count; with --check it rewrites nothing and exits 1 when a rule would. Directories are walked for *.zig,
skipping `.zig-cache`, `zig-out` and `zig-pkg`. --report writes `<file>\t<rule>\t<line>` per hit.
"""
import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "ci"))
import zigtok  # noqa: E402

DIALECT = "0.17.1"
SKIP_DIRS = {".zig-cache", "zig-cache", "zig-out", "zig-pkg", ".git"}


class Edit:
    __slots__ = ("start", "end", "text", "line")

    def __init__(self, start, end, text, line):
        self.start, self.end, self.text, self.line = start, end, text, line


def code_tokens(text):
    return zigtok.code(text, DIALECT)


def is_tok(tok, kind=None, text=None):
    return tok is not None and (kind is None or tok.kind == kind) and (text is None or tok.text == text)


def at(toks, i):
    return toks[i] if 0 <= i < len(toks) else None


def close_of(toks, i):
    """The index of the bracket that closes the one at toks[i], or None."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    opener = toks[i].text
    closer = pairs.get(opener)
    if closer is None:
        return None
    depth = 0
    for k in range(i, len(toks)):
        t = toks[k]
        if t.kind != "op":
            continue
        if t.text in pairs:
            depth += 1
        elif t.text in pairs.values():
            depth -= 1
            if depth == 0:
                return k if t.text == closer else None
    return None


def qualified_at(toks, i, names):
    """True when toks[i] is the last name of a `.`-qualified path whose previous names end with `names`, e.g.
    names ("mem",) matches `std.mem.trimLeft` and `mem.trimLeft` at the `trimLeft` token."""
    k = i
    for name in reversed(names):
        if not (is_tok(at(toks, k - 1), "op", ".") and is_tok(at(toks, k - 2), "identifier", name)):
            return False
        k -= 2
    return True


# --- rules -------------------------------------------------------------------------------------------------------
# Each rule: (id, description, function(text, toks) -> [Edit]).

def rule_arraylist_empty(text, toks):
    """`ArrayListUnmanaged(T) = .{}` (and ArrayList, ArrayListAlignedUnmanaged, ArrayListAligned): Zig 0.17's
    array list has no default for its fields; its empty value is `.empty`."""
    edits = []
    for i, t in enumerate(toks):
        if t.kind != "identifier" or t.text not in ("ArrayListUnmanaged", "ArrayList", "ArrayListAlignedUnmanaged",
                                                    "ArrayListAligned"):
            continue
        if not is_tok(at(toks, i + 1), "op", "("):
            continue
        close = close_of(toks, i + 1)
        if close is None:
            continue
        eq, dot, lb, rb = at(toks, close + 1), at(toks, close + 2), at(toks, close + 3), at(toks, close + 4)
        if is_tok(eq, "op", "=") and is_tok(dot, "op", ".") and is_tok(lb, "op", "{") and is_tok(rb, "op", "}"):
            edits.append(Edit(dot.start, rb.start + 1, ".empty", dot.line + 1))
    return edits


def rule_mem_trim(text, toks):
    """`mem.trimLeft` and `mem.trimRight` are `trimStart` and `trimEnd` in Zig 0.17."""
    edits = []
    names = {"trimLeft": "trimStart", "trimRight": "trimEnd"}
    for i, t in enumerate(toks):
        if t.kind == "identifier" and t.text in names and qualified_at(toks, i, ("mem",)):
            edits.append(Edit(t.start, t.start + len(t.text), names[t.text], t.line + 1))
    return edits


def rule_dupe_z(text, toks):
    """`<allocator>.dupeZ(T, x)` is `dupeSentinel(T, x, 0)` in Zig 0.17."""
    edits = []
    for i, t in enumerate(toks):
        if not (t.kind == "identifier" and t.text == "dupeZ" and is_tok(at(toks, i - 1), "op", ".")
                and is_tok(at(toks, i + 1), "op", "(")):
            continue
        close = close_of(toks, i + 1)
        if close is None:
            continue
        args, _ = zigtok.split_args(toks, i + 1)
        if len(args) != 2:
            continue
        edits.append(Edit(t.start, t.start + len(t.text), "dupeSentinel", t.line + 1))
        trailing_comma = is_tok(at(toks, close - 1), "op", ",")
        edits.append(Edit(toks[close].start, toks[close].start, " 0," if trailing_comma else ", 0", None))
    return edits


def rule_ascii_find(text, toks):
    """`ascii.indexOfIgnoreCase*` are `findIgnoreCase*` in Zig 0.17 (std.mem keeps its indexOf aliases)."""
    edits = []
    names = {"indexOfIgnoreCase": "findIgnoreCase", "indexOfIgnoreCasePos": "findIgnoreCasePos",
             "indexOfIgnoreCasePosLinear": "findIgnoreCasePosLinear"}
    for i, t in enumerate(toks):
        if t.kind == "identifier" and t.text in names and qualified_at(toks, i, ("ascii",)):
            edits.append(Edit(t.start, t.start + len(t.text), names[t.text], t.line + 1))
    return edits


MODE_NAMES = {"Debug": "debug", "ReleaseSafe": "safe", "ReleaseFast": "fast", "ReleaseSmall": "small"}


def _is_builtin_mode(toks, i):
    """toks[i] is the `mode` of `builtin.mode` (or `@import("builtin").mode`)."""
    if not (is_tok(at(toks, i), "identifier", "mode") and is_tok(at(toks, i - 1), "op", ".")):
        return False
    prev = at(toks, i - 2)
    return is_tok(prev, "identifier", "builtin") or (is_tok(prev, "op", ")") and is_tok(at(toks, i - 3), "string",
                                                                                         '"builtin"'))


def rule_optimize_mode(text, toks):
    """`builtin.mode` is a `std.lang.Optimize` in Zig 0.17, whose tags are `.debug`, `.safe`, `.fast` and `.small`:
    the 0.15 tag literals compared with it, or switched on it, are renamed."""
    edits = []

    def rename(k):
        t = at(toks, k)
        if is_tok(at(toks, k - 1), "op", ".") and is_tok(t, "identifier") and t.text in MODE_NAMES:
            edits.append(Edit(t.start, t.start + len(t.text), MODE_NAMES[t.text], t.line + 1))

    for i, t in enumerate(toks):
        if not _is_builtin_mode(toks, i):
            continue
        # builtin.mode == .Debug / != .Debug
        if is_tok(at(toks, i + 1), "op") and toks[i + 1].text in ("==", "!="):
            rename(i + 3)
        # .Debug == builtin.mode
        start = i - 2 if is_tok(at(toks, i - 2), "identifier", "builtin") else i - 5
        if is_tok(at(toks, start - 1), "op") and toks[start - 1].text in ("==", "!="):
            rename(start - 2)
        # switch (builtin.mode) { .Debug, .ReleaseSafe => ..., }
        if is_tok(at(toks, i + 1), "op", ")") and is_tok(at(toks, i + 2), "op", "{"):
            paren = start - 1
            if is_tok(at(toks, paren), "op", "(") and is_tok(at(toks, paren - 1), "keyword", "switch"):
                body_end = close_of(toks, i + 2)
                if body_end is None:
                    continue
                depth, prong_start = 0, True
                for k in range(i + 3, body_end):
                    tk = toks[k]
                    if tk.kind == "op" and tk.text in "([{" and tk.text:
                        depth += 1
                    elif tk.kind == "op" and tk.text in ")]}" and tk.text:
                        depth -= 1
                    elif depth == 0 and tk.kind == "op" and tk.text == "=>":
                        prong_start = False
                    elif depth == 0 and tk.kind == "op" and tk.text == "," and not prong_start:
                        prong_start = True
                    elif depth == 0 and prong_start and tk.kind == "identifier" and tk.text in MODE_NAMES:
                        rename(k)
    return edits


def test_blocks(toks):
    """(open brace index, close brace index) of every `test` block."""
    out = []
    for i, t in enumerate(toks):
        if not (t.kind == "keyword" and t.text == "test"):
            continue
        k = i + 1
        if at(toks, k) is not None and toks[k].kind in ("string", "identifier"):
            k += 1
        if is_tok(at(toks, k), "op", "{"):
            close = close_of(toks, k)
            if close is not None:
                out.append((k, close))
    return out


IO_ARG_NAMES = ("io", "testing.io", "std.testing.io")

# 0.15 std.fs.Dir method -> (0.17 std.Io.Dir method, the 0.15 arity, how the 0.15 arguments become 0.17's).
# "io+" inserts the Io first and keeps the rest; the others reorder (`a`, `p`, `m`: the 0.15 arguments by position).
DIR_METHODS = {
    "writeFile": ("writeFile", 1, "io+"),
    "access": ("access", 2, "io+"),
    "openDir": ("openDir", 2, "io+"),
    "openFile": ("openFile", 2, "io+"),
    "createFile": ("createFile", 2, "io+"),
    "deleteFile": ("deleteFile", 1, "io+"),
    "deleteDir": ("deleteDir", 1, "io+"),
    "deleteTree": ("deleteTree", 1, "io+"),
    "readLink": ("readLink", 2, "io+"),
    "symLink": ("symLink", 3, "io+"),
    "statFile": ("statFile", 1, "{io}, {0}, .{{}}"),
    "makeDir": ("createDir", 1, "{io}, {0}, .default_dir"),
    "makePath": ("createDirPath", 1, "{io}, {0}"),
    "makeOpenPath": ("createDirPathOpen", 2, "{io}, {0}, {1}"),
    "realpathAlloc": ("realPathFileAlloc", 2, "{io}, {1}, {0}"),
    "readFileAlloc": ("readFileAlloc", 3, "{io}, {1}, {0}, .limited({2})"),
}


def _arg_text(text, run):
    return text[run[0].start:run[-1].start + len(run[-1].text)]


def rule_test_dir_io(text, toks):
    """In a test block, a 0.15 `std.fs.Dir` call on a `std.testing.tmpDir` directory (`<tmp>.dir.<method>(`) or on
    `std.fs.cwd()` becomes the 0.17 `std.Io.Dir` call with `std.testing.io` (renamed where 0.17 renamed it:
    makeDir, makePath, makeOpenPath, realpathAlloc; readFileAlloc's byte bound becomes an `Io.Limit`, which refuses
    a file of exactly that size where 0.15 accepted it). Only the 0.15 arity is rewritten, so a ported call is left
    alone; other methods (realpath, iterate, close) are hand edits."""
    edits = []
    for lo, hi in test_blocks(toks):
        tmp_names = set()
        for i in range(lo, hi):
            # var tmp = std.testing.tmpDir(.{}); / testing.tmpDir(...)
            if (toks[i].kind == "keyword" and toks[i].text in ("var", "const")
                    and is_tok(at(toks, i + 1), "identifier") and is_tok(at(toks, i + 2), "op", "=")):
                k = i + 3
                if is_tok(at(toks, k), "keyword", "try"):
                    k += 1
                if (is_tok(at(toks, k), "identifier", "std") and is_tok(at(toks, k + 1), "op", ".")):
                    k += 2
                if (is_tok(at(toks, k), "identifier", "testing") and is_tok(at(toks, k + 1), "op", ".")
                        and is_tok(at(toks, k + 2), "identifier", "tmpDir")):
                    tmp_names.add(toks[i + 1].text)
                # var tmp = try TempDir.init(); (the fork's os/TempDir.zig, whose `dir` is a std.Io.Dir),
                # qualified or not: internal_os.TempDir.init(), os.TempDir.init().
                while is_tok(at(toks, k), "identifier") and is_tok(at(toks, k + 1), "op", ".") \
                        and toks[k].text != "TempDir":
                    k += 2
                if (is_tok(at(toks, k), "identifier", "TempDir") and is_tok(at(toks, k + 1), "op", ".")
                        and is_tok(at(toks, k + 2), "identifier", "init") and is_tok(at(toks, k + 3), "op", "(")
                        and is_tok(at(toks, k + 4), "op", ")")):
                    tmp_names.add(toks[i + 1].text)
        for i in range(lo, hi):
            t = toks[i]
            if t.kind != "identifier" or t.text not in DIR_METHODS or not is_tok(at(toks, i - 1), "op", "."):
                continue
            if not is_tok(at(toks, i + 1), "op", "("):
                continue
            cwd = (is_tok(at(toks, i - 2), "op", ")") and is_tok(at(toks, i - 3), "op", "(")
                   and is_tok(at(toks, i - 4), "identifier", "cwd") and qualified_at(toks, i - 4, ("std", "fs")))
            tmp = (is_tok(at(toks, i - 2), "identifier", "dir") and is_tok(at(toks, i - 3), "op", ".")
                   and is_tok(at(toks, i - 4), "identifier") and toks[i - 4].text in tmp_names
                   and not is_tok(at(toks, i - 5), "op", "."))
            if not (cwd or tmp):
                continue
            new_name, arity, shape = DIR_METHODS[t.text]
            args, close = zigtok.split_args(toks, i + 1)
            if len(args) != arity:
                continue
            first = "".join(x.text for x in args[0]) if args else ""
            if first in IO_ARG_NAMES:
                continue
            io = "std.testing.io"
            if shape == "io+":
                new_args = io + ", " + _arg_text(text, (args[0][0], args[-1][-1]))
            else:
                new_args = shape.format(*[_arg_text(text, (a[0], a[-1])) for a in args], io=io)
            # Keep a trailing comma's layout: rewrite only the argument span.
            span_start, span_end = args[0][0].start, args[-1][-1].start + len(args[-1][-1].text)
            edits.append(Edit(span_start, span_end, new_args, t.line + 1))
            if new_name != t.text:
                edits.append(Edit(t.start, t.start + len(t.text), new_name, None))
            if cwd:
                # std.fs.cwd() -> std.Io.Dir.cwd()
                fs = toks[i - 6]
                edits.append(Edit(fs.start, fs.start + len(fs.text), "Io.Dir", None))
        # A file or directory such a call opened (`const f = try tmp.dir.createFile(...)`) is a std.Io.File or
        # std.Io.Dir, whose close takes the Io: `f.close()` -> `f.close(std.testing.io)`.
        opened = set()
        for i in range(lo, hi):
            if not (toks[i].kind == "keyword" and toks[i].text in ("var", "const")
                    and is_tok(at(toks, i + 1), "identifier") and is_tok(at(toks, i + 2), "op", "=")):
                continue
            k = i + 3
            if is_tok(at(toks, k), "keyword", "try"):
                k += 1
            if (is_tok(at(toks, k), "identifier") and toks[k].text in tmp_names and is_tok(at(toks, k + 1), "op", ".")
                    and is_tok(at(toks, k + 2), "identifier", "dir") and is_tok(at(toks, k + 3), "op", ".")
                    and is_tok(at(toks, k + 4), "identifier")
                    and toks[k + 4].text in ("createFile", "openFile", "openDir", "makeOpenPath", "createDirPathOpen")
                    and is_tok(at(toks, k + 5), "op", "(")):
                opened.add(toks[i + 1].text)
        for i in range(lo, hi):
            if (is_tok(at(toks, i), "identifier") and toks[i].text in opened and is_tok(at(toks, i + 1), "op", ".")
                    and is_tok(at(toks, i + 2), "identifier", "close") and is_tok(at(toks, i + 3), "op", "(")
                    and is_tok(at(toks, i + 4), "op", ")") and not is_tok(at(toks, i - 1), "op", ".")):
                edits.append(Edit(toks[i + 4].start, toks[i + 4].start, "std.testing.io", toks[i].line + 1))
    return edits


RULES = [
    ("arraylist-empty", rule_arraylist_empty.__doc__, rule_arraylist_empty),
    ("mem-trim", rule_mem_trim.__doc__, rule_mem_trim),
    ("dupe-z", rule_dupe_z.__doc__, rule_dupe_z),
    ("ascii-find", rule_ascii_find.__doc__, rule_ascii_find),
    ("optimize-mode", rule_optimize_mode.__doc__, rule_optimize_mode),
    ("test-dir-io", rule_test_dir_io.__doc__, rule_test_dir_io),
]


# --- engine ------------------------------------------------------------------------------------------------------

def apply_edits(text, edits):
    edits = sorted(edits, key=lambda e: (e.start, e.end))
    for a, b in zip(edits, edits[1:]):
        if b.start < a.end:
            raise ValueError(f"overlapping edits at offsets {a.start} and {b.start}")
    out, pos = [], 0
    for e in edits:
        out.append(text[pos:e.start])
        out.append(e.text)
        pos = e.end
    out.append(text[pos:])
    return "".join(out)


def _line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def rewrite(text, rule_ids=None, lines=None):
    """(new text, [(rule id, line)]) for one file's text: each selected rule in order, over the previous rule's
    output. With `lines` (a set of 1-based line numbers of the input), a hit is kept only when every edit of it
    lies on those lines, so upstream's own lines in a shared file are left as upstream wrote them."""
    hits = []
    for rule_id, _, fn in RULES:
        if rule_ids is not None and rule_id not in rule_ids:
            continue
        edits = fn(text, code_tokens(text))
        if lines is not None:
            # A rule emits each hit's edit (the one with a line) and then its other halves (line-less), so the
            # emission order groups them; a group is kept only if every edit in it sits on an allowed line.
            groups, cur = [], []
            for e in edits:
                if e.line is not None and cur:
                    groups.append(cur)
                    cur = []
                cur.append(e)
            if cur:
                groups.append(cur)
            kept = []
            for g in groups:
                if all(_line_of(text, e.start) in lines and _line_of(text, max(e.start, e.end - 1)) in lines
                       for e in g):
                    kept.extend(g)
            edits = kept
        if edits:
            new = apply_edits(text, edits)
            if lines is not None:
                lines = _shift_lines(text, new, lines)
            text = new
            # An edit with no line is the second half of a hit (an inserted argument), not a hit of its own.
            hits.extend((rule_id, e.line) for e in edits if e.line is not None)
    return text, hits


def _shift_lines(old, new, lines):
    """The allowed line set after a rewrite. Rules never add or remove a newline, so line numbers are stable."""
    if old.count("\n") != new.count("\n"):
        raise ValueError("a rule changed the number of lines")
    return lines


def changed_lines(path, rev):
    """The 1-based lines of `path` (as it is in the work tree) that differ from `rev`, or None when `rev` lacks
    the file (fork-only: every line). An empty set means the file is upstream's as it stands."""
    import subprocess
    root = Path(__file__).resolve().parents[3]
    rel = Path(path).resolve().relative_to(root).as_posix()
    exists = subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{rev}:{rel}"],
                            capture_output=True).returncode == 0
    if not exists:
        return None
    out = subprocess.run(["git", "-C", str(root), "--no-optional-locks", "diff", "-U0", rev, "--", rel],
                         capture_output=True, text=True, encoding="utf-8", check=True).stdout
    lines = set()
    for line in out.splitlines():
        if line.startswith("@@"):
            plus = line.split("+", 1)[1].split(" ", 1)[0]
            start, _, count = plus.partition(",")
            start, count = int(start), int(count) if count else 1
            lines.update(range(start, start + count))
    return lines


def zig_files(paths):
    for p in paths:
        p = Path(p)
        if p.is_dir():
            for root, dirs, files in os.walk(p):
                dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
                for f in sorted(files):
                    if f.endswith(".zig"):
                        yield Path(root) / f
        elif p.suffix == ".zig":
            yield p


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--rules")
    ap.add_argument("--report")
    ap.add_argument("--fork-lines", metavar="REV",
                    help="rewrite only lines that differ from REV (the upstream tag); a file REV lacks is rewritten "
                         "whole, a file equal to REV not at all")
    ap.add_argument("paths", nargs="+")
    args = ap.parse_args(argv)
    rule_ids = set(args.rules.split(",")) if args.rules else None
    if rule_ids is not None:
        unknown = rule_ids - {r[0] for r in RULES}
        if unknown:
            ap.error(f"unknown rules: {', '.join(sorted(unknown))}")
    counts = {r[0]: 0 for r in RULES if rule_ids is None or r[0] in rule_ids}
    report = []
    changed = 0
    for path in zig_files(args.paths):
        raw = path.read_bytes()
        if b"\r" in raw:
            print(f"refused (CR bytes): {path}", file=sys.stderr)
            return 2
        text = raw.decode("utf-8")
        lines = changed_lines(path, args.fork_lines) if args.fork_lines else None
        if lines is not None and not lines:
            continue
        new, hits = rewrite(text, rule_ids, lines)
        for rule_id, line in hits:
            counts[rule_id] += 1
            report.append(f"{path.as_posix()}\t{rule_id}\t{line}")
        if new != text:
            changed += 1
            if not args.check:
                path.write_bytes(new.encode("utf-8"))
    for rule_id, n in counts.items():
        print(f"{rule_id}\t{n}")
    print(f"files {'to change' if args.check else 'changed'}\t{changed}")
    if args.report:
        Path(args.report).write_text("".join(r + "\n" for r in report), encoding="utf-8", newline="\n")
    return 1 if args.check and changed else 0


if __name__ == "__main__":
    sys.exit(main())
