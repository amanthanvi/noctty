"""The 1B.5 codemod: the fork's Zig 0.15.2 spellings rewritten to Zig 0.17.1's, as rules over Zig's token stream.

PLAN.md row 1B.5 (U7) runs it once over the 1B tree and again at every forward merge through 1B.9, so every rule is
idempotent (a second run over its own output changes nothing) and has a test over a fixture (test_codemod.py). A rule
rewrites a form only where the rewrite is safe from the tokens alone; what needs a reader (an `Io` to thread, a
changed signature, a behaviour) is a hand edit, recorded in residue.tsv with its file and reason.

Usage:
  python plans/1b/codemod/codemod.py [--check] [--rules id,id] [--report out.tsv] [--fork-lines REV] <path>...

Without --check it rewrites the files in place (LF kept; a file with CR bytes is refused) and prints one line per rule
with its hit count; with --check it rewrites nothing and exits 1 when a rule would. Directories are walked for *.zig,
skipping `.zig-cache`, `zig-out` and `zig-pkg`. --report writes `<file>\t<rule>\t<line>\t<what>` per hit
(`rewritten`) and per hand edit (`hand edit: <why>`).

A hand edit is a 0.15 shape a rule recognises but cannot prove equivalent: the run leaves it as it is, prints it
(`hand edit\t<file>\t<rule>\t<line>\t<why>`, and the count), and goes on; it never stops the run. Every file is
rewritten in memory first; nothing is written unless every file rewrote cleanly (a failure, such as an unreadable
baseline, writes nothing). A rule's hit is one group of edits, kept or dropped whole: with --fork-lines a group is
kept only when every line it touches (from each edit's first line to its last) differs from REV, and one that also
touches an inherited line is a hand edit; a file REV has only under another case (a case-only rename the work tree
did not take) is a hand edit whole, each rewrite a rule would make in it reported and none written. A group that
would add, drop or move a line break is a hand edit too, so the line ownership the filter reads stays true. Two
groups that overlap (a call nested in another's arguments) are applied in turns until the rule finds nothing more.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "ci"))
import zigtok  # noqa: E402

DIALECT = "0.17.1"
SKIP_DIRS = {".zig-cache", "zig-cache", "zig-out", "zig-pkg", ".git"}
MAX_PASSES = 8


class Edit:
    __slots__ = ("start", "end", "text")

    def __init__(self, start, end, text):
        self.start, self.end, self.text = start, end, text


class Hit:
    """One rewrite: its edits, applied together or not at all, the 1-based line it is reported at, and a note the
    report gives beside it (what a reader should know of the rewrite), or None."""
    __slots__ = ("edits", "line", "note")

    def __init__(self, line, edits, note=None):
        self.line, self.edits, self.note = line, list(edits), note

    @property
    def start(self):
        return min(e.start for e in self.edits)

    @property
    def end(self):
        return max(e.end for e in self.edits)


class Bail:
    """A shape a rule leaves for a hand edit: the 1-based line it is reported at, why, and the lines it concerns
    (with --fork-lines it is reported only when one of them is the fork's)."""
    __slots__ = ("line", "reason", "lines")

    def __init__(self, line, reason, lines=None):
        self.line, self.reason = line, reason
        self.lines = set(lines) if lines is not None else {line}


class HandEdit(Exception):
    """Raised while a rule builds a hit for a shape it cannot prove equivalent; the rule reports it as a Bail. Also
    raised by changed_lines for a file whose fork lines it cannot tell, which the run leaves whole."""


# Why the engine leaves a hit for a hand edit.
INHERITED = "the rewrite would also edit an inherited line"
LINE_COUNT = "the rewrite would change the number of lines"
ACROSS_LINES = "the rewrite would move text across a line break"


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


def rename(tok, new):
    return Edit(tok.start, tok.start + len(tok.text), new)


# --- rules -------------------------------------------------------------------------------------------------------
# Each rule: (id, description, function(text, toks) -> [Hit]).

def rule_arraylist_empty(text, toks):
    """`ArrayListUnmanaged(T) = .{}` (and ArrayList, ArrayListAlignedUnmanaged, ArrayListAligned): Zig 0.17's
    array list has no default for its fields; its empty value is `.empty`."""
    hits = []
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
            hits.append(Hit(dot.line + 1, [Edit(dot.start, rb.start + 1, ".empty")]))
    return hits


def rule_mem_trim(text, toks):
    """`mem.trimLeft` and `mem.trimRight` are `trimStart` and `trimEnd` in Zig 0.17."""
    names = {"trimLeft": "trimStart", "trimRight": "trimEnd"}
    return [Hit(t.line + 1, [rename(t, names[t.text])]) for i, t in enumerate(toks)
            if t.kind == "identifier" and t.text in names and qualified_at(toks, i, ("mem",))]


def rule_dupe_z(text, toks):
    """`<allocator>.dupeZ(T, x)` is `dupeSentinel(T, x, 0)` in Zig 0.17."""
    hits = []
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
        trailing_comma = is_tok(at(toks, close - 1), "op", ",")
        hits.append(Hit(t.line + 1, [rename(t, "dupeSentinel"),
                                     Edit(toks[close].start, toks[close].start, " 0," if trailing_comma else ", 0")]))
    return hits


def rule_ascii_find(text, toks):
    """`ascii.indexOfIgnoreCase*` are `findIgnoreCase*` in Zig 0.17 (std.mem keeps its indexOf aliases)."""
    names = {"indexOfIgnoreCase": "findIgnoreCase", "indexOfIgnoreCasePos": "findIgnoreCasePos",
             "indexOfIgnoreCasePosLinear": "findIgnoreCasePosLinear"}
    return [Hit(t.line + 1, [rename(t, names[t.text])]) for i, t in enumerate(toks)
            if t.kind == "identifier" and t.text in names and qualified_at(toks, i, ("ascii",))]


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
    hits = []

    def tag(k):
        t = at(toks, k)
        if is_tok(at(toks, k - 1), "op", ".") and is_tok(t, "identifier") and t.text in MODE_NAMES:
            hits.append(Hit(t.line + 1, [rename(t, MODE_NAMES[t.text])]))

    for i, t in enumerate(toks):
        if not _is_builtin_mode(toks, i):
            continue
        # builtin.mode == .Debug / != .Debug
        if is_tok(at(toks, i + 1), "op") and toks[i + 1].text in ("==", "!="):
            tag(i + 3)
        # .Debug == builtin.mode
        start = i - 2 if is_tok(at(toks, i - 2), "identifier", "builtin") else i - 5
        if is_tok(at(toks, start - 1), "op") and toks[start - 1].text in ("==", "!="):
            tag(start - 2)
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
                    if tk.kind == "op" and tk.text in ("(", "[", "{"):
                        depth += 1
                    elif tk.kind == "op" and tk.text in (")", "]", "}"):
                        depth -= 1
                    elif depth == 0 and tk.kind == "op" and tk.text == "=>":
                        prong_start = False
                    elif depth == 0 and tk.kind == "op" and tk.text == "," and not prong_start:
                        prong_start = True
                    elif depth == 0 and prong_start and tk.kind == "identifier" and tk.text in MODE_NAMES:
                        tag(k)
    return hits


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


IO = "std.testing.io"
IO_ARG_NAMES = ("io", "testing.io", "std.testing.io")

# 0.15 std.fs.Dir method -> (0.17 std.Io.Dir method, the 0.15 arity, the 0.17 arguments after the Io). An entry of
# the argument list is the 0.15 argument by position (an int), a literal (a str), or a function of the 0.15 argument
# texts that gives the text or None (no safe rewrite). Each 0.15 argument's span is replaced in place by the 0.17
# argument at its position, so line breaks and comments between arguments stay where they were; an extra 0.17
# argument is appended after the last span. readLink is not here: 0.17's returns a byte count where 0.15's returned
# the slice, so a call's value changes meaning (a hand edit).


OPEN_OPTIONS = "makeOpenPath's options are not `.{}`, the one the rule translates exactly"
NO_FOLLOW = ("makeOpenPath's `.no_follow = true` has no exact 0.17 form: under `.open_options = .{ .follow_symlinks = "
             "false }` 0.17's createDirPathOpen also stats an existing intermediate component without following a "
             "link there (NotDir), where 0.15's stat followed it")
REALPATH_SHAPE = ("realpathAlloc's 0.17 result is a `[:0]u8`: outside an untyped `const` it may lose the sentinel, "
                  "and a later free would get the wrong size")
REALPATH_USE = ("realpathAlloc's 0.17 result is a `[:0]u8`, and its binding has a use other than a direct "
                "`<allocator>.free(<binding>)` or a read in place (`.len`, an index): a coercion or a pass to another "
                "function may drop the sentinel, and a free through that slice would get the wrong size")
OPEN_FILE_NOTE = ("0.17's openFile opens a directory, which 0.15's refused on Windows (error.IsDir); a test keeps "
                  "0.17's default")
PRODUCT_OPEN_FILE = ("outside a test the rule has no Io to pass; 0.17's openFile opens a directory, which 0.15's "
                     "refused on Windows, so the hand edit gives it `.allow_directory = false`")


def _open_options(texts):
    """makeOpenPath's 0.15 `OpenOptions`: `.{}` stays, exact; any other option is a hand edit. `.no_follow = true`
    is too: 0.17's `.open_options = .{ .follow_symlinks = false }` also changes createDirPathOpen's check of an
    existing intermediate component (std.Io.Threaded stats it with the same `follow_symlinks`)."""
    words = [t.text for t in code_tokens(texts[1])]
    if words == [".", "{", "}"]:
        return texts[1]
    if words in ([".", "{", ".", "no_follow", "=", "true", "}"], [".", "{", ".", "no_follow", "=", "true", ",", "}"]):
        raise HandEdit(NO_FOLLOW)
    raise HandEdit(OPEN_OPTIONS)


def _untyped_const_init(toks, s, close):
    """toks[s:close + 1] is the whole initializer of an untyped `const` (`const p = [try] <call>;`)."""
    k = s - 1 if is_tok(at(toks, s - 1), "keyword", "try") else s
    return (is_tok(at(toks, k - 1), "op", "=") and is_tok(at(toks, k - 2), "identifier")
            and is_tok(at(toks, k - 3), "keyword", "const") and is_tok(at(toks, close + 1), "op", ";"))


def _freed_or_read(toks, lo, hi, decl):
    """Every use in toks[lo:hi] of the name toks[decl] declares is a direct `<allocator>.free(<name>)` or a read in
    place (`<name>.len`, `<name>[i]`, not a slice); `<name>.<field>` and `.<name>` are no uses of it."""
    name = toks[decl].text
    for k in range(lo, hi):
        if k == decl or not is_tok(toks[k], "identifier", name) or is_tok(at(toks, k - 1), "op", "."):
            continue
        if (is_tok(at(toks, k - 1), "op", "(") and is_tok(at(toks, k + 1), "op", ")")
                and is_tok(at(toks, k - 2), "identifier", "free") and is_tok(at(toks, k - 3), "op", ".")
                and is_tok(at(toks, k - 4), "identifier")):
            continue
        if is_tok(at(toks, k + 1), "op", ".") and is_tok(at(toks, k + 2), "identifier", "len"):
            continue
        if is_tok(at(toks, k + 1), "op", "["):
            close = close_of(toks, k + 1)
            depth = 0
            for j in range(k + 1, close if close is not None else k + 1):
                if toks[j].kind == "op" and toks[j].text in ("(", "[", "{"):
                    depth += 1
                elif toks[j].kind == "op" and toks[j].text in (")", "]", "}"):
                    depth -= 1
                elif depth == 1 and is_tok(toks[j], "op", ".."):
                    break
            else:
                if close is not None:
                    continue
        return False
    return True


FILE_TOO_BIG = "the file names FileTooBig, which 0.17's readFileAlloc never returns (its oversize error is StreamTooLong)"
IS_DIR = ("the file names IsDir: 0.17's statFile reports a directory as kind = .directory, where 0.15's refused one "
          "with IsDir (council H2)")
STAT_NESTED = ("statFile in a function nested in the test: its `try` hands the error to a caller that may branch "
               "on it, so 0.17's directory report could take the other branch and still pass (council AA2)")
STAT_USE = ("statFile's result is not consumed by `try`: 0.17 reports a directory as kind = .directory where 0.15 "
            "refused one, so code that branches on its success or error can take the other branch and still pass "
            "(council Y4)")
LIMIT_SHAPE = ("readFileAlloc's limit is no integer literal, so `+ 1` (0.15's inclusive bound) could change it "
               "(`1 << 20 + 1` is `1 << 21`) or overflow (a name bound to `maxInt(usize)`)")
INT_LITERAL = re.compile(r"0x[0-9a-fA-F_]+|0o[0-7_]+|0b[01_]+|[0-9][0-9_]*")


def _inclusive_limit(texts):
    """readFileAlloc's 0.15 `max_bytes` accepted a file of exactly that size; 0.17's `Io.Limit` refuses a file that
    reaches it. `.limited(n + 1)` keeps the bound, for an integer literal only: `1 << 20 + 1` is `1 << 21`, and a
    name's value (`maxInt(usize)`, which `+ 1` overflows) is not in the tokens."""
    toks = code_tokens(texts[2])
    if len(toks) == 1 and toks[0].kind == "number" and INT_LITERAL.fullmatch(toks[0].text):
        return ".limited(" + texts[2] + " + 1)"
    raise HandEdit(LIMIT_SHAPE)


DIR_METHODS = {
    "writeFile": ("writeFile", 1, [0]),
    "access": ("access", 2, [0, 1]),
    "openDir": ("openDir", 2, [0, 1]),
    "openFile": ("openFile", 2, [0, 1]),
    "createFile": ("createFile", 2, [0, 1]),
    "deleteFile": ("deleteFile", 1, [0]),
    "deleteDir": ("deleteDir", 1, [0]),
    "deleteTree": ("deleteTree", 1, [0]),
    "symLink": ("symLink", 3, [0, 1, 2]),
    "statFile": ("statFile", 1, [0, ".{}"]),
    "makeDir": ("createDir", 1, [0, ".default_dir"]),
    "makePath": ("createDirPath", 1, [0]),
    "makeOpenPath": ("createDirPathOpen", 2, [0, _open_options]),
    "realpathAlloc": ("realPathFileAlloc", 2, [1, 0]),
    "readFileAlloc": ("readFileAlloc", 3, [1, 0, _inclusive_limit]),
}
OPENING = ("createFile", "openFile", "openDir", "makeOpenPath")


def _span(run):
    return run[0].start, run[-1].start + len(run[-1].text)


def _dir_call_edits(text, toks, i, args):
    """The edits that turn the 0.15 Dir call whose method name is toks[i] into the 0.17 call; HandEdit when the
    call is a shape the rule cannot prove equivalent."""
    t = toks[i]
    new_name, arity, shape = DIR_METHODS[t.text]
    spans = [_span(a) for a in args]
    texts = [text[s:e] for s, e in spans]
    new_args = []
    for item in shape:
        if isinstance(item, int):
            new_args.append(texts[item])
        elif isinstance(item, str):
            new_args.append(item)
        else:
            new_args.append(item(texts))
    moved = [k for k, item in enumerate(shape[:len(spans)]) if isinstance(item, int) and item != k]
    if moved:
        # Arguments that change places must lie on one line, or text would move across a line break.
        involved = set(moved) | {shape[k] for k in moved}
        if len({_line_of(text, p) for k in involved for p in (spans[k][0], spans[k][1] - 1)}) > 1:
            raise HandEdit(ACROSS_LINES)
        if any("//" in text[spans[k][1]:spans[k + 1][0]] for k in range(len(spans) - 1)):
            raise HandEdit("a comment between its arguments would end up beside another one")
    edits = [Edit(spans[0][0], spans[0][0], IO + ", ")]
    for k, (s, e) in enumerate(spans):
        if new_args[k] != texts[k]:
            edits.append(Edit(s, e, new_args[k]))
    if len(new_args) > len(spans):
        tail = spans[-1][1]
        edits.append(Edit(tail, tail, "".join(", " + a for a in new_args[len(spans):])))
    if new_name != t.text:
        edits.append(rename(t, new_name))
    return edits


def _nested_fn_bodies(toks, lo, hi):
    """(open, close) of the body of every `fn` declared inside the block toks[lo..hi] (a helper, a struct's
    method). A body is the first `{` after the parameter list that does not open an `error{...}` set."""
    bodies = []
    for k in range(lo + 1, hi):
        if not is_tok(toks[k], "keyword", "fn"):
            continue
        j = k + 1
        while j < hi and not is_tok(toks[j], "op", "("):
            j += 1
        params = close_of(toks, j) if j < hi else None
        if params is None:
            continue
        j = params + 1
        while j < hi and not is_tok(toks[j], "op", ";"):
            if is_tok(toks[j], "op", "{") and not is_tok(at(toks, j - 1), None, "error"):
                end = close_of(toks, j)
                if end is not None:
                    bodies.append((j, end))
                break
            if is_tok(toks[j], "op", "{"):
                j = close_of(toks, j) or j
            j += 1
    return bodies


def _receiver(toks, i, tmp_names):
    """'tmp' for `<tmp>.dir.<method>` with <tmp> a known temporary directory, 'cwd' for `std.fs.cwd().<method>`,
    else None (toks[i] is the method name)."""
    if (is_tok(at(toks, i - 2), "op", ")") and is_tok(at(toks, i - 3), "op", "(")
            and is_tok(at(toks, i - 4), "identifier", "cwd") and qualified_at(toks, i - 4, ("std", "fs"))):
        return "cwd"
    if (is_tok(at(toks, i - 2), "identifier", "dir") and is_tok(at(toks, i - 3), "op", ".")
            and is_tok(at(toks, i - 4), "identifier") and toks[i - 4].text in tmp_names
            and not is_tok(at(toks, i - 5), "op", ".")):
        return "tmp"
    return None


REUSED_NAME = ("the name `{}` is bound more than once in this test, so which open a close belongs to needs a "
               "reader: its 0.15 opens and its closes are hand edits")
REUSED_RECEIVER = ("the name `{}` is bound more than once in this test, not always to a temporary directory: its "
                   "calls are hand edits")
UNREAD_OPEN = ("the pairing reads an open's binding only as `const f = [try] <open>`, and this open's value goes "
               "elsewhere (a typed binding, an assignment, a field, another expression), so its close would not be "
               "rewritten with it: the open, and the closes and opens of a name it binds, are hand edits")


def _enclosing_open(toks, r):
    """The index of the innermost bracket that is open at toks[r], or None."""
    depth = 0
    for k in range(r - 1, -1, -1):
        t = toks[k]
        if t.kind != "op":
            continue
        if t.text in (")", "]", "}"):
            depth += 1
        elif t.text in ("(", "[", "{"):
            if depth == 0:
                return k
            depth -= 1
    return None


def _statement_start(toks, p):
    """The index of the first token of the statement (or of the bracketed group) toks[p] is in."""
    depth = 0
    for k in range(p - 1, -1, -1):
        t = toks[k]
        if t.kind != "op":
            continue
        if t.text in (")", "]"):
            depth += 1
        elif t.text in ("(", "["):
            if depth == 0:
                return k + 1
            depth -= 1
        elif depth == 0 and t.text in (";", "{", "}"):
            return k + 1
    return 0


def _open_target(toks, r):
    """Where the value of an open that the pairing did not read goes (toks[r] starts its receiver): (True, None)
    when nothing can close it (the open is an argument of `expectError`, or discarded by `_ =`), else (False, the
    name a typed `const`/`var` or an assignment binds it to, or None when it goes anywhere else)."""
    p = r - 1
    if is_tok(at(toks, p), "keyword", "try"):
        p -= 1
    t = at(toks, p)
    if is_tok(t, "op", ",") or is_tok(t, "op", "("):
        o = _enclosing_open(toks, r)
        return (o is not None and is_tok(toks[o], "op", "(") and is_tok(at(toks, o - 1), "identifier", "expectError"),
                None)
    if is_tok(t, "op", "="):
        s = _statement_start(toks, p)
        if s == p - 1 and is_tok(toks[s], "identifier"):
            return (True, None) if toks[s].text == "_" else (False, toks[s].text)
        if (is_tok(at(toks, s), "keyword") and toks[s].text in ("const", "var")
                and is_tok(at(toks, s + 1), "identifier") and is_tok(at(toks, s + 2), "op", ":")):
            return False, toks[s + 1].text
    return False, None


def _binding_counts(toks, lo, hi):
    """How many times each name is bound in toks[lo:hi]: by `var` or `const`, in a capture (`|x|`, `|*x, i|`), or as
    a parameter (`(x: T`, `, x: T`, `comptime x: T`). A struct field or a bitwise `|` can count as one too, which
    errs toward a hand edit."""
    counts = {}

    def add(name):
        counts[name] = counts.get(name, 0) + 1

    k = lo
    while k < hi:
        t = toks[k]
        if t.kind == "keyword" and t.text in ("var", "const") and is_tok(at(toks, k + 1), "identifier"):
            add(toks[k + 1].text)
        elif is_tok(t, "op", "|"):
            j, names = k + 1, []
            while True:
                if is_tok(at(toks, j), "op", "*"):
                    j += 1
                if not is_tok(at(toks, j), "identifier"):
                    break
                names.append(toks[j].text)
                j += 1
                if not is_tok(at(toks, j), "op", ","):
                    break
                j += 1
            if names and is_tok(at(toks, j), "op", "|"):
                for name in names:
                    add(name)
                k = j
        elif (t.kind == "identifier" and is_tok(at(toks, k + 1), "op", ":") and at(toks, k - 1) is not None
              and (toks[k - 1].kind, toks[k - 1].text) in (("op", "("), ("op", ","), ("keyword", "comptime"),
                                                           ("keyword", "noalias"))):
            add(t.text)
        k += 1
    return counts


def _tmp_bindings(toks, lo, hi):
    """The names bound in toks[lo:hi] to a temporary directory, each with how many such bindings it has."""
    names = {}
    for i in range(lo, hi):
        if not (toks[i].kind == "keyword" and toks[i].text in ("var", "const")
                and is_tok(at(toks, i + 1), "identifier") and is_tok(at(toks, i + 2), "op", "=")):
            continue
        k = i + 3
        if is_tok(at(toks, k), "keyword", "try"):
            k += 1
        j = k
        if is_tok(at(toks, j), "identifier", "std") and is_tok(at(toks, j + 1), "op", "."):
            j += 2
        if (is_tok(at(toks, j), "identifier", "testing") and is_tok(at(toks, j + 1), "op", ".")
                and is_tok(at(toks, j + 2), "identifier", "tmpDir")):
            names[toks[i + 1].text] = names.get(toks[i + 1].text, 0) + 1
            continue
        # var tmp = try TempDir.init(); (the fork's os/TempDir.zig, whose `dir` is a std.Io.Dir), qualified or not.
        while is_tok(at(toks, k), "identifier") and is_tok(at(toks, k + 1), "op", ".") and toks[k].text != "TempDir":
            k += 2
        if (is_tok(at(toks, k), "identifier", "TempDir") and is_tok(at(toks, k + 1), "op", ".")
                and is_tok(at(toks, k + 2), "identifier", "init") and is_tok(at(toks, k + 3), "op", "(")
                and is_tok(at(toks, k + 4), "op", ")")):
            names[toks[i + 1].text] = names.get(toks[i + 1].text, 0) + 1
    return names


def rule_test_dir_io(text, toks):
    """In a test block, a 0.15 `std.fs.Dir` call on a `std.testing.tmpDir` or fork TempDir directory
    (`<tmp>.dir.<method>(`) or on `std.fs.cwd()` becomes the 0.17 `std.Io.Dir` call with `std.testing.io`, renamed
    where 0.17 renamed it (makeDir, makePath, makeOpenPath, realpathAlloc). readFileAlloc's byte bound `n` becomes
    the `Io.Limit` `.limited(n + 1)`, since 0.15 accepted a file of exactly `n` bytes and 0.17's limit refuses a file
    that reaches it; a bound that is not an integer literal (a name may be `maxInt(usize)`) is a hand edit. Its
    oversize error is `StreamTooLong` where 0.15's was `FileTooBig`: in a file that names `FileTooBig` anywhere (a
    helper outside the test may consume it), every readFileAlloc is a hand edit. statFile in 0.17 reports a directory
    as `kind = .directory` where 0.15's refused one with `IsDir`: in a file that names `IsDir`, every statFile is a
    hand edit (council H2). realpathAlloc's 0.17 result is a
    `[:0]u8`, so it is rewritten only as the whole initializer of an untyped `const` bound once in the test, whose
    every use is a direct `<allocator>.free(<name>)` or a read in place (`.len`, an index), so a free keeps the
    sentinel's size.
    makeOpenPath's options are rewritten only where the translation is exact (`.{}`; `.no_follow = true` is not).
    openFile in a test keeps 0.17's default, which opens a directory where 0.15's refused one on Windows, and the
    report notes each; outside a test nothing is rewritten (no `std.testing.io` there), and a 0.15 openFile on
    `std.fs.cwd()` or `std.fs.openFileAbsolute` is a reported hand edit that should pass `.allow_directory = false`.
    A file or directory such a call opened (`const f = try tmp.dir.createFile(...)`) closes with the
    Io, in the same hit as its open, so the two are rewritten together or not at all; one whose open is already
    0.17's closes with the Io alone. An open whose value goes anywhere else (a typed binding, an assignment, a field,
    another expression) is a hand edit, with the closes and opens of a name it binds; only one that nothing can close
    (an argument of `expectError`, or `_ =`) is rewritten alone. Only the 0.15 arity is rewritten, so a ported call
    is left alone."""
    hits = []
    names_file_too_big = "FileTooBig" in text   # code, a string or a comment: when in doubt, a hand edit
    names_is_dir = "IsDir" in text   # the same for statFile's directory (council H2)
    blocks = test_blocks(toks)
    for i, t in enumerate(toks):
        # Product code: a 0.15 openFile the rule knows the receiver of, outside every test block.
        if not (t.kind == "identifier" and t.text in ("openFile", "openFileAbsolute")
                and is_tok(at(toks, i - 1), "op", ".") and is_tok(at(toks, i + 1), "op", "(")):
            continue
        if not (_receiver(toks, i, ()) == "cwd" if t.text == "openFile" else qualified_at(toks, i, ("std", "fs"))):
            continue
        if any(lo <= i <= hi for lo, hi in blocks):
            continue
        args, close = zigtok.split_args(toks, i + 1)
        if len(args) == 2:
            hits.append(Bail(t.line + 1, PRODUCT_OPEN_FILE, range(t.line + 1, toks[close].line + 2)))
    for lo, hi in blocks:
        bound = _binding_counts(toks, lo, hi)
        tmp_counts = _tmp_bindings(toks, lo, hi)
        # A name bound to a temporary directory and also to something else (sibling scopes) is no known receiver.
        tmp_names = {n for n, c in tmp_counts.items() if c == bound.get(n, 0)}
        tmp_any = set(tmp_counts)
        nested_bodies = _nested_fn_bodies(toks, lo, hi)
        call_hits = {}   # method-name token index -> Hit
        call_at = {}   # method-name token index -> (the index its receiver starts at, the lines the call spans)
        for i in range(lo, hi):
            t = toks[i]
            if t.kind != "identifier" or t.text not in DIR_METHODS or not is_tok(at(toks, i - 1), "op", "."):
                continue
            if not is_tok(at(toks, i + 1), "op", "("):
                continue
            recv = _receiver(toks, i, tmp_any)
            if recv is None:
                continue
            args, close = zigtok.split_args(toks, i + 1)
            if len(args) != DIR_METHODS[t.text][1] or "".join(x.text for x in args[0]) in IO_ARG_NAMES:
                continue
            call_lines = range(t.line + 1, toks[close].line + 2)
            try:
                if recv == "tmp" and toks[i - 4].text not in tmp_names:
                    raise HandEdit(REUSED_RECEIVER.format(toks[i - 4].text))
                if t.text == "readFileAlloc" and names_file_too_big:
                    raise HandEdit(FILE_TOO_BIG)
                if t.text == "statFile" and names_is_dir:
                    raise HandEdit(IS_DIR)
                if t.text == "statFile" and any(a < i < b for a, b in nested_bodies):
                    raise HandEdit(STAT_NESTED)
                if t.text == "statFile" and not is_tok(at(toks, i - (5 if recv == "tmp" else 9)), "keyword", "try"):
                    raise HandEdit(STAT_USE)
                if t.text == "realpathAlloc":
                    s = i - (4 if recv == "tmp" else 8)
                    if not _untyped_const_init(toks, s, close):
                        raise HandEdit(REALPATH_SHAPE)
                    decl = s - (3 if is_tok(at(toks, s - 1), "keyword", "try") else 2)
                    if bound.get(toks[decl].text, 0) != 1 or not _freed_or_read(toks, lo, hi, decl):
                        raise HandEdit(REALPATH_USE)
                edits = _dir_call_edits(text, toks, i, args)
            except HandEdit as e:
                hits.append(Bail(t.line + 1, str(e), call_lines))
                continue
            if recv == "cwd":
                fs = toks[i - 6]   # std.fs.cwd() -> std.Io.Dir.cwd()
                edits.append(rename(fs, "Io.Dir"))
            hit = Hit(t.line + 1, edits, OPEN_FILE_NOTE if t.text == "openFile" else None)
            hits.append(hit)
            call_hits[i] = hit
            call_at[i] = (i - (4 if recv == "tmp" else 8), call_lines)
        # What such a call opened closes with the Io. A name bound more than once in the block (sibling scopes, a
        # capture, a parameter) could pair a close with the wrong open: its opens and closes are hand edits.
        opened = {}   # name -> the open's Hit, or "ported" when the open is already 0.17's
        open_hits = {}   # name -> the Hits of its 0.15 opens
        paired = set()   # the method-name token index of each 0.15 open the pairing read
        for i in range(lo, hi):
            if not (toks[i].kind == "keyword" and toks[i].text in ("var", "const")
                    and is_tok(at(toks, i + 1), "identifier") and is_tok(at(toks, i + 2), "op", "=")):
                continue
            k = i + 3
            if is_tok(at(toks, k), "keyword", "try"):
                k += 1
            # the method name of `<tmp>.dir.m(` or `std.fs.cwd().m(` / `std.Io.Dir.cwd().m(`
            m = None
            if (is_tok(at(toks, k), "identifier") and toks[k].text in tmp_names and is_tok(at(toks, k + 1), "op", ".")
                    and is_tok(at(toks, k + 2), "identifier", "dir") and is_tok(at(toks, k + 3), "op", ".")):
                m = k + 4
            elif (is_tok(at(toks, k), "identifier", "std") and is_tok(at(toks, k + 1), "op", ".")):
                j = k + 2
                if is_tok(at(toks, j), "identifier", "fs") and is_tok(at(toks, j + 1), "op", "."):
                    j += 2
                elif (is_tok(at(toks, j), "identifier", "Io") and is_tok(at(toks, j + 1), "op", ".")
                      and is_tok(at(toks, j + 2), "identifier", "Dir") and is_tok(at(toks, j + 3), "op", ".")):
                    j += 4
                else:
                    continue
                if (is_tok(at(toks, j), "identifier", "cwd") and is_tok(at(toks, j + 1), "op", "(")
                        and is_tok(at(toks, j + 2), "op", ")") and is_tok(at(toks, j + 3), "op", ".")):
                    m = j + 4
            if m is None or not is_tok(at(toks, m), "identifier") or not is_tok(at(toks, m + 1), "op", "("):
                continue
            name, method = toks[i + 1].text, toks[m].text
            if m in call_hits and method in OPENING:
                opened[name] = call_hits[m]
                open_hits.setdefault(name, []).append(call_hits[m])
                paired.add(m)
            elif method in ("createFile", "openFile", "openDir", "createDirPathOpen"):
                args, _ = zigtok.split_args(toks, m + 1)
                if args and "".join(x.text for x in args[0]) in IO_ARG_NAMES:
                    opened[name] = "ported"
        held = {n: REUSED_NAME.format(n) for n in opened if bound.get(n, 0) > 1}   # name -> why its pairs bail
        # A 0.15 open the pairing did not read (a typed binding, an assignment, a field, an expression) would be
        # rewritten without its close: it is a hand edit, and so are the closes and opens of a name it binds. One
        # that nothing can close (expectError's argument, `_ =`) is rewritten.
        for m, owner in list(call_hits.items()):
            if toks[m].text not in OPENING or m in paired:
                continue
            free, name = _open_target(toks, call_at[m][0])
            if free:
                continue
            hits.remove(owner)
            hits.append(Bail(owner.line, UNREAD_OPEN, call_at[m][1]))
            if name is not None:
                held.setdefault(name, UNREAD_OPEN)
        for name in sorted(held):
            for owner in open_hits.get(name, ()):
                hits.remove(owner)
                hits.append(Bail(owner.line, held[name]))
        for i in range(lo, hi):
            if (is_tok(at(toks, i), "identifier") and (toks[i].text in opened or toks[i].text in held)
                    and is_tok(at(toks, i + 1), "op", ".")
                    and is_tok(at(toks, i + 2), "identifier", "close") and is_tok(at(toks, i + 3), "op", "(")
                    and is_tok(at(toks, i + 4), "op", ")") and not is_tok(at(toks, i - 1), "op", ".")):
                if toks[i].text in held:
                    hits.append(Bail(toks[i].line + 1, held[toks[i].text]))
                    continue
                edit = Edit(toks[i + 4].start, toks[i + 4].start, IO)
                owner = opened[toks[i].text]
                if owner == "ported":
                    hits.append(Hit(toks[i].line + 1, [edit]))
                else:
                    owner.edits.append(edit)
    return hits


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
        if b.start < a.end or (b.start == a.start and a.start == a.end and b.start == b.end):
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


def _touched(text, hit):
    """Every 1-based line an edit of the hit replaces text on or inserts at, the lines between its ends included."""
    out = set()
    for e in hit.edits:
        out.update(range(_line_of(text, e.start), _line_of(text, max(e.start, e.end - 1)) + 1))
    return out


def _on_lines(text, hit, lines):
    return _touched(text, hit) <= lines


def _line_break_problem(text, hit):
    """Why applying the hit would add, drop or move a line break (a hand edit), or None. An edit may replace text
    that spans a line break only by keeping that text whole, wrapped in text without one."""
    for e in hit.edits:
        old = text[e.start:e.end]
        if old.count("\n") != e.text.count("\n"):
            return LINE_COUNT
        if "\n" in old and old not in e.text:
            return ACROSS_LINES
    return None


def _conflict(a, b):
    """Two edits touch the same text (or insert at one point)."""
    if a.start == a.end and b.start == b.end:
        return a.start == b.start
    return a.start < b.end and b.start < a.end or (a.start == a.end and b.start < a.start < b.end) or (
        b.start == b.end and a.start < b.start < a.end)


def _disjoint(hits):
    """The hits that can be applied in one pass, outermost first; one with an edit that overlaps a kept hit's edit
    (a call nested in another's arguments) waits for the next pass."""
    kept, taken = [], []
    for h in sorted(hits, key=lambda h: (h.start, -h.end)):
        if any(_conflict(e, t) for e in h.edits for t in taken):
            continue
        kept.append(h)
        taken.extend(h.edits)
    return kept


def rewrite(text, rule_ids=None, lines=None, rows=None):
    """(new text, [(rule id, line)]) for one file's text: each selected rule in order, over the previous rule's
    output, repeated while it finds more (a call nested in another's arguments is rewritten in a later pass). With
    `lines` (a set of 1-based line numbers), a hit is kept only when every line it touches is one of them; one that
    touches some of them is a hand edit, one that touches none is upstream's and left unreported. A hit that would
    add, drop or move a line break is a hand edit too. `rows`, when given, collects (rule id, line, what) for each
    hit (`rewritten`) and each hand edit (`hand edit: <why>`), these as the rule's last pass finds them."""
    hits_out = []
    for rule_id, _, fn in RULES:
        if rule_ids is not None and rule_id not in rule_ids:
            continue
        for _ in range(MAX_PASSES):
            bails, hits = [], []
            for found in fn(text, code_tokens(text)):
                if isinstance(found, Bail):
                    bails.append(found)
                    continue
                touched = _touched(text, found)
                if lines is not None and not touched <= lines:
                    if touched & lines:
                        bails.append(Bail(found.line, INHERITED, touched))
                    continue
                why = _line_break_problem(text, found)
                if why is not None:
                    bails.append(Bail(found.line, why, touched))
                    continue
                hits.append(found)
            hits = _disjoint(hits)
            if not hits:
                break
            new = apply_edits(text, [e for h in hits for e in h.edits])
            if new.count("\n") != text.count("\n"):
                # Each applied edit keeps its line breaks (_line_break_problem), so this is the engine's own bug.
                raise ValueError(f"rule {rule_id} changed the number of lines")
            text = new
            hits_out.extend((rule_id, h.line) for h in hits)
            if rows is not None:
                rows.extend((rule_id, h.line, "rewritten" + (f"; {h.note}" if h.note else "")) for h in hits)
        else:
            raise ValueError(f"rule {rule_id} did not settle in {MAX_PASSES} passes")
        if rows is not None:
            seen = set()
            for b in sorted(bails, key=lambda b: b.line):
                if (lines is None or b.lines & lines) and (b.line, b.reason) not in seen:
                    seen.add((b.line, b.reason))
                    rows.append((rule_id, b.line, "hand edit: " + b.reason))
    return text, hits_out


HUNK = re.compile(r"@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def parse_changed_lines(diff_text):
    """The 1-based new-side lines a `git diff` output adds: its `+` records, numbered from their hunk's header. A
    context line inside a hunk (which `-U0 --inter-hunk-context=0` should not produce, but a config could) is
    upstream's line, not the fork's. A hunk ends when its header's counts are used up, so an added line that starts
    `++` is a record, not a file header."""
    lines = set()
    old_left = new_left = new_line = 0
    for line in diff_text.split("\n"):
        if old_left <= 0 and new_left <= 0:
            m = HUNK.match(line)
            if m:
                old_left = int(m.group(1)) if m.group(1) is not None else 1
                new_line = int(m.group(2))
                new_left = int(m.group(3)) if m.group(3) is not None else 1
            continue
        if line.startswith("+"):
            lines.add(new_line)
            new_line, new_left = new_line + 1, new_left - 1
        elif line.startswith("-"):
            old_left -= 1
        elif line.startswith("\\"):
            pass   # "\ No newline at end of file"
        else:      # a context line (" ", or "" under diff.suppressBlankEmpty)
            new_line, new_left, old_left = new_line + 1, new_left - 1, old_left - 1
    return lines


def _git(*args):
    """A git command in the repository, its output as bytes (no newline translation: a carriage return on the ref
    side of a diff is part of its record)."""
    return subprocess.run(["git", "-C", str(ROOT), "--no-optional-locks", *args], capture_output=True)


def _text(data):
    return data.decode("utf-8", "surrogateescape")


def check_rev(rev):
    """Stop unless `rev` names a commit."""
    if _git("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}").returncode != 0:
        raise ValueError(f"--fork-lines: {rev!r} is no commit")


CASE_ONLY = ("the ref has this path only in another case (git on Windows keeps a file's case on disk when a merge "
             "renames it by case only), so which lines are the fork's is unknown: the whole file is a hand edit")
_REF_PATHS = {}   # (root, rev) -> the case-folded path of every file in rev's tree


def _ref_paths_folded(rev):
    """The case-folded path of every file in `rev`'s tree (`ls-tree -r -z`, read once per root and ref)."""
    key = (str(ROOT), rev)
    if key not in _REF_PATHS:
        listed = _git("ls-tree", "-r", "-z", "--name-only", rev)
        if listed.returncode != 0:
            raise ValueError(f"git ls-tree -r {rev} failed: {_text(listed.stderr).strip()[:200]}")
        _REF_PATHS[key] = {_text(p).casefold() for p in listed.stdout.split(b"\0") if p}
    return _REF_PATHS[key]


def changed_lines(path, rev):
    """The 1-based lines of `path` (as it is in the work tree) that differ from `rev`, or None when `rev` lacks
    the file (fork-only: every line). An empty set means the file is upstream's as it stands. A path `rev` has only
    in another case (a directory's or the file's own) raises HandEdit(CASE_ONLY): which of its lines are the fork's
    needs a reader. A git failure other than a path `rev` lacks stops the run. `ls-tree -z` names the path
    unquoted, so a non-ASCII name is found."""
    rel = Path(path).resolve().relative_to(ROOT).as_posix()
    listed = _git("ls-tree", "-z", "--name-only", rev, "--", rel)
    if listed.returncode != 0:
        raise ValueError(f"git ls-tree {rev} {rel} failed: {_text(listed.stderr).strip()[:200]}")
    if listed.stdout != (rel + "\0").encode("utf-8"):
        if rel.casefold() in _ref_paths_folded(rev):
            raise HandEdit(CASE_ONLY)
        return None
    out = _git("diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U0", "--inter-hunk-context=0", rev, "--",
               rel)
    if out.returncode != 0:
        raise ValueError(f"git diff {rev} {rel} failed: {_text(out.stderr).strip()[:200]}")
    return parse_changed_lines(_text(out.stdout))


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
                         "whole, a file equal to REV not at all, a file REV has only in another case is a hand edit")
    ap.add_argument("paths", nargs="+")
    args = ap.parse_args(argv)
    rule_ids = set(args.rules.split(",")) if args.rules else None
    if rule_ids is not None:
        unknown = rule_ids - {r[0] for r in RULES}
        if unknown:
            ap.error(f"unknown rules: {', '.join(sorted(unknown))}")
    counts = {r[0]: 0 for r in RULES if rule_ids is None or r[0] in rule_ids}
    report, hand, pending = [], [], []
    try:
        if args.fork_lines:
            check_rev(args.fork_lines)
        for path in zig_files(args.paths):
            raw = path.read_bytes()
            if b"\r" in raw:
                raise ValueError(f"refused (CR bytes): {path}")
            text = raw.decode("utf-8")
            whole = None   # why the whole file is a hand edit, or None
            try:
                lines = changed_lines(path, args.fork_lines) if args.fork_lines else None
            except HandEdit as e:
                lines, whole = None, str(e)
            if lines is not None and not lines:
                continue
            rows = []
            try:
                new, hits = rewrite(text, rule_ids, lines, rows)
            except ValueError as e:
                raise ValueError(f"{path}: {e}") from e
            if whole is not None:
                # Every rewrite a rule would make in the file is reported as a hand edit; nothing is written.
                new, hits = text, []
                rows = [(r, n, f"hand edit: {whole}" if what.startswith("rewritten") else what) for r, n, what in rows]
            for rule_id, line in hits:
                counts[rule_id] += 1
            for rule_id, line, what in sorted(rows, key=lambda r: r[1]):
                report.append(f"{path.as_posix()}\t{rule_id}\t{line}\t{what}")
                if what.startswith("hand edit: "):
                    hand.append(f"hand edit\t{path.as_posix()}\t{rule_id}\t{line}\t{what[len('hand edit: '):]}")
            if new != text:
                pending.append((path, new))
    except ValueError as e:
        print(f"codemod: {e}; nothing written", file=sys.stderr)
        return 2
    if not args.check:
        for path, new in pending:
            path.write_bytes(new.encode("utf-8"))
    for row in hand:
        print(row)
    for rule_id, n in counts.items():
        print(f"{rule_id}\t{n}")
    print(f"hand edits\t{len(hand)}")
    print(f"files {'to change' if args.check else 'changed'}\t{len(pending)}")
    if args.report:
        Path(args.report).write_text("".join(r + "\n" for r in report), encoding="utf-8", newline="\n")
    return 1 if args.check and pending else 0


if __name__ == "__main__":
    sys.exit(main())
