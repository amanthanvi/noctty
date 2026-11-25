r"""Thread-table gate, r15 (thread_gate6.py from r25: a test's identity is its exact decoded name, and the TEST column
carries the kind; round 24's M1, Muse L1, Opus L1; thread_gate7.py from r26: a quoted identifier that decodes to a plain
one is that identifier, at a call site as at a declaration, and an acquiring function named otherwise fails
FN-NAME-NOT-IDENTIFIER; round 25's M1; thread_gate8.py from r27: the source normalized once where it is read, and
FN-NAME-NOT-IDENTIFIER at test-code and unclassified acquisitions too; round 26's Sol M1, M2; thread_gate9.py from
r28: every quoted identifier a word every pass reads, keywords and primitives no plain identifiers, and a spelling
the normalizer cannot read a failure; round 27's Opus M1, Sol M1 and lead note; thread_gate10.py from r29: the
thread anchors as reviewed data, test-code UNCLASSIFIED through the allow-list, every acquisition op; round 28's
Opus M1, M2 and the lead's note; thread_gate11.py from r30: default-deny, so the allow-list keys an unclassified
acquisition by its receiver too, and an anchor's proof may be a chain; round 29's lead direction and Opus L2;
thread_gate12.py from r31: an approved count per allow-list row, ALLOW-COUNT, and a called @field whose name is no
literal an acquisition; round 30's Opus L3 and the user's census decision; thread_gate13.py from r32: the source read
through one shared token stream, zigtok.py, so a comment or a line break splits no reference, local or thread entry;
round 31's lead direction; thread_gate14.py from r34: each function's span from the token stream too
(zigtok.functions_of_tokens), so a multi-line signature or a brace in a literal ends none early; round 33's lead
direction; thread_gate15.py from r35: the caller sets too, each body a run of tokens, so a one-line function has a
body and a line two spans share is read by its tokens; round 34's Opus L3 and the lead's direction): the static REVIEW TRIGGER for renderer-state mutex sites (round 10: LEAD decision, Z1-Z4,
Y3, Y4; round 11: AA5, Opus L2; round 12: M-b, M-c, M-f, Sol L4; round 13: AC2). The runtime role check (the owner-tracking wrapper with thread roles and the
observed-pairs dump) is the authoritative thread check. STATED LIMIT: this gate catches an acquisition in a function no
row covers, an added, removed or re-kinded acquisition in an approved function (its signature), and a new or lost
direct caller in a file that imports or names the callee's file. A new caller elsewhere (an anytype caller in a file
that does not name the callee's file) and every transitive path are caught only at runtime, by the observed-pairs
check, for paths the tests exercise.

Usage (run Python with -I; run lock_inventory20.py first, with the same revision string, scope and --overlay):
  thread_gate15.py check   <repo> <rev> <scope> <table.tsv> <allow.tsv|-> <inv-prefix> <entries.tsv|-> <anchors.tsv> [--overlay DIR]
                          [--arm-renderer-demand]
  thread_gate15.py approve <repo> <rev> <scope> <table.tsv> <inv-prefix> [--overlay DIR]   (writes <table>.callers.tsv)
  thread_gate15.py edges   <repo> <rev> <scope> <table.tsv> [--overlay DIR]
  thread_gate15.py chains  <repo> <rev> <scope> <table.tsv> <inv-prefix> <out.tsv> <anchors.tsv> [--overlay DIR]
  thread_gate15.py rekey   <repo> <rev> <table.tsv> <out.tsv>                       (false edges keyed on line text)
  thread_gate15.py sites   <repo> <rev> <inv-prefix>
  thread_gate15.py entries <repo> <rev> [--overlay DIR]
  thread_gate15.py anchors <repo> <rev> <anchors.tsv> [--overlay DIR]

SCOPES: fork (the fork head); 1a (the merged 1A trees: fork rows plus `merged` rows, for functions that exist only in
the merged trees); 1b (the merged 1B trees: fork, `merged` and `merged-1b` rows); upstream (the stone, v1.4.0: counts
only; no fingerprints are approved there, so none is compared).

SITES come from lock_inventory17.py's <inv-prefix>-sites.tsv (kinds renderer-state, demand, relock, handoff-internal):
ONE recogniser. Production sites are checked against the scope's rows; test-code sites against `test` rows (M-f). A site no parsed function owns is attributed to "(container)" and is unreviewed.
The site count must equal the inventory's acquisitions + relocks + handoff-internal for the revision.

TABLE (TSV): file, function | *[f1,...], fingerprint, threads, scope, reason, chain.
  TEST ROWS (M-f): scope `test`; threads = the role(s) the test simulates; fingerprint = `@<signature>`; chain =
  `test:<outermost test name>`, the name exactly as decoded, whitespace included (r25), matched against a site's
  TEST value `named:<name>`; a test with no key (`no-key:`, `decltest:`, `unnamed`, `test-code`) matches no row. They
  apply in every enforced scope and never shadow a production row.
  INLINE ANNOTATION (M-b): a chain item `inline:<inline-fn|always-inline>:<measured attribution>` records how a site
  in an inline function (or an always_inline target) is attributed; it is not a call-chain hop.
  FORWARDERS (AC2): `src/renderer/State.zig` `lockDemand` is the one permanent, intended inline site. It is exempt
  from INLINE-SITE by name, and fails FORWARDER-NOT-INLINE when its site is not in an `inline fn`.
  chain hops: `path:function:token` (the function's body names the next one down); evidence for never-on-win32 rows:
  `absent:<regex>` (no non-test body outside the site's function matches) and
  `guard:path:function:<r1>=><r2>=>...` (in that function, lines matching r1, r2, ... come in that order: for
  termiosTimer, the comptime Windows guard, its `return .disarm` (fork, stone) or `@panic` (v1.4.0), then the site;
  absent: would be false for it because its name appears in threadEnter's POSIX-only arming and after
  focusGained's Windows return). A never row carries only evidence, and each
  function it covers is named by an evidence hop (a one-function row may cite its only caller instead).
  `#false-edge<TAB>callee<TAB>caller<TAB>normalised mentioning line<TAB>why`: the edge is removed only while every
  line of the caller that mentions the callee is one of its recorded lines (Y3): a new mention in the same function
  shows up.
FINGERPRINT: depth-1 word mention (see thread_gate.py's REFERENCE RULE); approve also writes the sorted caller list to
  <table>.callers.tsv, and check prints the added and removed callers of a changed fingerprint.
SIGNATURE (AA5): the function's acquisitions counted by kind and operation (`lock` and `lockUncancelable` are one
  spelling, so the 0.17 rename is no change), approved beside the fingerprint as `fingerprint@signature`; an added,
  removed or re-kinded acquisition (lock -> tryLock, lock -> lockDemand) fails as CHANGED-SIGNATURE.
THREAD ENTRIES (Z2): every non-test `Thread.spawn(`, every `X.async(`/`X.concurrent(` whatever its receiver and
  arguments are spelled (Sol L4: `tasks.async(backend, worker, .{})` too), and Win32
  thread or thread-pool creation call, keyed by (file, function, api, target); check fails on one not in <entries.tsv>
  and on a listed one that is gone. The list is the role registry the runtime check starts from.

ALLOW-LIST (r30, r31): rows `file function receiver count reason`; an unclassified acquisition passes only when its
  file, its function (or `test:<name>` when a test block owns it) and its receiver, as the inventory prints it, are
  one row's, and a revision holds exactly the row's approved count of acquisitions with that key (ALLOW-COUNT
  otherwise, r31: round 30's Opus L3, since r30's set let a second acquisition with an allowed key pass, and one row
  cover same-named functions in two containers). r29 keyed a row by file and function only; a row without a receiver
  or a count fails the run (BAD-ALLOW). A key no acquisition of this revision has is no failure: the list serves
  every tree.
ANCHORS (r29, r30): rows `thread file function proof`; a proof is one hop, `path:function:token`, or a chain of hops
  joined by `=>` (round 29's Opus L2), the first in the anchor's own function, each naming the next one's function
  as its token's last word, so the proof shows the anchor reaches the proving call (`run` to `routeLoopMessage` to
  `DispatchMessageW`); a hop not found, or a link that does not name the next function, fails ANCHOR-MOVED.
CHECK fails (exit 1, enforced scopes) on: UNREVIEWED, CHANGED-FINGERPRINT, CHANGED-SIGNATURE, CHANGED-PATH, NO-PATH, NO-CHAIN,
REASON-NO-LINES, NEVER-CHAIN, NEVER-NO-EVIDENCE, STALE-ROW (a row's function has no site in this tree), ANCHOR-MOVED,
SITE-COUNT-MISMATCH, UNCLASSIFIED-NOT-ALLOWED, ALLOW-COUNT, NEW-THREAD-ENTRY, GONE-THREAD-ENTRY, FALSE-EDGE-NO-TEXT,
INLINE-SITE, INLINE-STALE, FORWARDER-NOT-INLINE, TEST-UNREVIEWED, TEST-NO-ROLE, WHITESPACE-MISMATCH (a test with no
exact row and a row that matches it only once whitespace is trimmed, r25), FN-NAME-NOT-IDENTIFIER (an acquisition in
a function whose quoted name decodes to no plain identifier, r26; at test-code and unclassified acquisitions too, r27;
a name that decodes to a Zig keyword or primitive, such as `@"defer"` or `@"type"`, is no plain identifier, r28),
UNREADABLE-IDENTIFIER (an `@"` with no closing quote on its line, r28) and QUOTED-TOKEN-COLLISION (source that
already holds the tools' token prefix, r28): the gate reads nothing of the tree then and fails; and the inventory's
UNREADABLE-RECEIVER (a lock call on an expression the tools cannot name, r28), reported from its summary,
and with --arm-renderer-demand
RENDERER-PLAIN-LOCK.
"""
import collections
import functools
import hashlib
import importlib.util
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True   # r32: loading zigtok.py writes no __pycache__ beside the installed tools
_zspec = importlib.util.spec_from_file_location("zigtok", os.path.join(os.path.dirname(os.path.abspath(__file__)), "zigtok.py"))
zigtok = importlib.util.module_from_spec(_zspec)
_zspec.loader.exec_module(zigtok)   # r32: the one shared Zig token stream (zigtok.py), installed beside this tool

for _stream in (sys.stdout, sys.stderr):   # r23: the report in UTF-8 whatever the console's code page
    _stream.reconfigure(encoding="utf-8", errors="backslashreplace")

mode = sys.argv[1]
overlay = None
argv = sys.argv[2:]
if "--overlay" in argv:
    k = argv.index("--overlay")
    overlay = argv[k + 1]
    argv = argv[:k] + argv[k + 2:]
ARM_RENDERER_DEMAND = "--arm-renderer-demand" in argv
argv = [a for a in argv if a != "--arm-renderer-demand"]
args = argv
repo, rev = args[0], args[1]
ROLES = {"ui", "renderer", "termio", "reader", "search", "test_support"}
FORWARDERS = {("src/renderer/State.zig", "lockDemand")}   # AC2: permanent intended inline sites, by name
SKIP = re.compile(r"/gtk|macos|apprt/embedded\.zig")
LOOKUP = {"fork": ("fork", "all"), "1a": ("merged", "fork", "all"), "1b": ("merged-1b", "merged", "fork", "all"),
          "upstream": ("upstream", "all")}
ENFORCED = ("fork", "1a", "1b")


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True).stdout.decode("utf-8", "replace")


files = [f for f in git("ls-tree", "-r", "--name-only", rev, "--", "src").splitlines()
         if f.endswith(".zig") and not SKIP.search(f)]
if overlay:
    for root, _, names in os.walk(overlay):
        for n in names:
            rel = os.path.relpath(os.path.join(root, n), overlay).replace("\\", "/")
            if rel.endswith(".zig") and rel not in files:
                files.append(rel)
texts = {}
for f in files:
    op = os.path.join(overlay, f) if overlay else None
    if op and os.path.exists(op):
        texts[f] = open(op, encoding="utf-8").read()
    else:
        texts[f] = git("show", f"{rev}:{f}")


PLAIN_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# r28 (round 27's Opus M1): Zig's keywords and primitives, as lock_inventory17.py's (std/zig/tokenizer.zig and
# std/zig/primitives.zig, identical in 0.15.2 and 0.17.1)
ZIG_KEYWORDS = frozenset(
    "addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue defer else enum "
    "errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub "
    "resume return struct suspend switch test threadlocal try union unreachable var volatile while".split())
ZIG_PRIMITIVES = frozenset(
    "anyerror anyframe anyopaque bool c_char c_int c_long c_longdouble c_longlong c_short c_uint c_ulong c_ulonglong "
    "c_ushort comptime_float comptime_int f128 f16 f32 f64 f80 false isize noreturn null true type undefined usize "
    "void".split())


def is_primitive(n):
    """std.zig.primitives.isPrimitive: a named primitive, or i or u followed by digits only (length 2 or more)."""
    return n in ZIG_PRIMITIVES or (len(n) >= 2 and n[0] in "iu" and n[1:].isdigit() and n[1:].isascii())


def reserved(n):
    return n in ZIG_KEYWORDS or is_primitive(n)


def zig_unescape(s):
    """A Zig string literal's bytes as the compiler reads them (as lock_inventory17.py's): a literal character as its
    UTF-8, \\xNN one byte, \\u{N} the code point's UTF-8, \\n \\r \\t \\\\ \\' \\" their byte."""
    out, i = bytearray(), 0
    while i < len(s):
        c = s[i]
        if c != "\\" or i + 1 >= len(s):
            out += c.encode("utf-8", "surrogatepass")
            i += 1
            continue
        n = s[i + 1]
        if n in "nrt\\'\"":
            out += {"n": b"\n", "r": b"\r", "t": b"\t"}.get(n, n.encode("ascii"))
            i += 2
        elif n == "x" and re.fullmatch(r"[0-9A-Fa-f]{2}", s[i + 2:i + 4]):
            out.append(int(s[i + 2:i + 4], 16))
            i += 4
        elif n == "u" and s[i + 2:i + 3] == "{" and "}" in s[i + 3:]:
            j = s.index("}", i + 3)
            out += chr(int(s[i + 3:j], 16)).encode("utf-8", "surrogatepass")
            i = j + 1
        else:
            out += c.encode("utf-8", "surrogatepass")
            i += 1
    return bytes(out)


def quoted_ident(spelled):
    """r26 (round 25's M1): the identifier `@"<spelled>"` names, when its decoded bytes are a plain identifier; else
    None. Zig gives `@"same"` and `same` one identity. r28 (round 27's Opus M1): a keyword or a primitive is no plain
    identifier, so `@"defer"` and `@"type"` give None and become tokens, as in lock_inventory17.py."""
    try:
        n = zig_unescape(spelled).decode("utf-8")
    except UnicodeDecodeError:
        return None
    return n if PLAIN_IDENT.fullmatch(n) and not reserved(n) else None


TOKEN_PREFIX = "__zqi_"
TOKEN = re.compile(r"__zqi_([0-9a-f]+)_")


class Unreadable(Exception):
    """r28 (round 27's lead note): a spelling the normalizer cannot turn into a token the later passes read. The tool
    fails on it explicitly; it never reads past it."""


def canon_bytes(b):
    """The one printed spelling of a quoted name's decoded bytes: printable ASCII as itself, and every other byte, the
    quote and the backslash as \\xNN."""
    return '@"' + "".join(chr(x) if 0x20 <= x < 0x7F and x not in (0x22, 0x5C) else f"\\x{x:02x}" for x in b) + '"'


def canon_quoted(spelled_inner):
    """r27: the canonical spelling of a quoted name that is no plain identifier, so `@"a b"` and `@"a\\x20b"` are one
    name; r28 prints it from the token's bytes (canon_bytes)."""
    return canon_bytes(zig_unescape(spelled_inner))


def tok(spelled_inner):
    """r28 (round 27's Opus M1, Sol M1 and lead note): the one word for a quoted name that is no plain identifier (a
    keyword, a primitive, or any name holding a byte outside an identifier): TOKEN_PREFIX, its decoded bytes in hex,
    and `_`. Every pass reads it with \\w+, as a callee, a parameter, a receiver or an alias, as it reads a plain name;
    r27 left such a name quoted, sc() emptied it as a string literal, and the passes that read \\w+ never saw it."""
    return TOKEN_PREFIX + zig_unescape(spelled_inner).hex() + "_"


def untok(s):
    """r28: every token back to its canonical quoted spelling, for output and for names compared with the reviewed
    lists; never applied to text a pass reads."""
    return TOKEN.sub(lambda m: canon_bytes(bytes.fromhex(m.group(1))), s)


def norm_line(l, where, n):
    """r28: one line's code with each `@"..."` replaced: a plain identifier by itself, anything else by its token.
    A comment, a string or char literal and a multiline string line are left as written, so only an identifier is
    replaced; an `@"` with no closing quote on its line cannot be read and raises Unreadable. A line with no `@"` has
    nothing to replace and is returned as it is, unscanned."""
    if '@"' not in l or l.lstrip().startswith("\\\\"):
        return l
    out, i, ln = [], 0, len(l)
    while i < ln:
        ch = l[i]
        if ch == "/" and l.startswith("//", i):
            out.append(l[i:])
            break
        if ch == "@" and l.startswith('@"', i):
            j = i + 2
            while j < ln and l[j] != '"':
                j += 2 if l[j] == "\\" else 1
            if j >= ln:
                raise Unreadable(f"UNREADABLE-IDENTIFIER {where}:{n}: an @\" with no closing quote on its line; the "
                                 f"tools cannot read the name, so they read nothing of this file")
            inner = l[i + 2:j]
            out.append(quoted_ident(inner) or tok(inner))
            i = j + 1
            continue
        if ch in "\"'":
            j = i + 1
            while j < ln and l[j] != ch:
                j += 2 if l[j] == "\\" else 1
            out.append(l[i:j + 1])
            i = j + 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def norm_quoted_idents(text, where):
    """r27, r28 (round 27's lead note): the one normalizer, applied once to each file's text where it is read, before
    any pass reads a name: every quoted identifier becomes a word every later pass reads (norm_line). A file that
    already holds the token prefix is refused (QUOTED-TOKEN-COLLISION), since a token could not be told from it."""
    if TOKEN_PREFIX in text:
        line = text.count("\n", 0, text.index(TOKEN_PREFIX)) + 1
        raise Unreadable(f"QUOTED-TOKEN-COLLISION {where}:{line}: the source holds the tools' token prefix "
                         f"{TOKEN_PREFIX}, so a quoted name's token could not be told from it")
    return "\n".join(norm_line(l, where, n) for n, l in enumerate(text.split("\n"), 1))


def fn_name(spelled):
    """r26 to r28: a function's name as the passes key it: a plain identifier, or the token of any other (untok gives
    its canonical quoted spelling for output)."""
    if spelled.startswith('@"'):
        return quoted_ident(spelled[2:-1]) or tok(spelled[2:-1])
    return spelled


def retok(name):
    """r28: a reviewed or reported name (plain, or canonical `@"..."`) as the normalized source spells it, for a lookup
    in source; a name a reviewed list could not spell otherwise stays as written."""
    if name.startswith('@"') and name.endswith('"') and len(name) > 3:
        return quoted_ident(name[2:-1]) or tok(name[2:-1])
    return name


@functools.lru_cache(maxsize=1 << 18)
def sc(l):
    """r32: the line as the line passes read it, from its tokens (zigtok.clean_line, as lock_inventory17.py's sc): its
    comment removed, every string and char literal emptied, a multi-line string line dropped."""
    return zigtok.clean_line(l, quoted_ident)


@functools.lru_cache(maxsize=256)
def file_toks(f):
    """r35: one file's code tokens (zigtok.split_lines_tokens of its normalized text), each token's line its line in
    the file; built on demand and kept for the most recently read files."""
    return zigtok.split_lines_tokens(texts[f])[0]


RUN_LINES = {}   # r35: (file, first token, last token) of each body run -> the lines its tokens stand on


def run_lines(f, a, b):
    """r35: the lines a body run's tokens stand on, in order (reviewed regex evidence reads those cleaned lines), kept
    when the run is made, so no file is read again for them."""
    got = RUN_LINES.get((f, a, b))
    if got is None:
        toks = file_toks(f)
        got = RUN_LINES[(f, a, b)] = tuple(sorted({toks[q].line for q in range(a, min(b, len(toks) - 1) + 1)}))
    return got


_unreadable = []
for _f in list(texts):
    try:   # r27, r28: the one normalizer, before any pass reads a name; a spelling it cannot read fails the gate
        texts[_f] = norm_quoted_idents(texts[_f], _f)
    except Unreadable as _e:
        _unreadable.append(str(_e))
if _unreadable:   # r28 (round 27's lead note): explicitly, in every mode, and before any pass reads the tree
    for _x in _unreadable:
        print("FAIL " + _x)
    _k = collections.Counter(_x.split(" ", 1)[0] for _x in _unreadable)
    print(f"RESULT FAIL ({len(_unreadable)} failures) " + " ".join(f"{k}={v}" for k, v in sorted(_k.items())))
    sys.exit(1)
lines_of = {f: t.splitlines() for f, t in texts.items()}
clean_of = {f: [sc(x) for x in ls] for f, ls in lines_of.items()}   # false-edge texts and reviewed evidence read these
# r35 (round 34's Opus L3 and the lead's direction): every structure from the code tokens. Each function's body is
# the runs of tokens between its body's braces that no nested function holds (r34: the lines it owned, its first
# line left out, so a one-line function had none and a line two spans shared went to one); the file's container
# level is the runs no function holds; the caller index, the type names, the imports, the words, the file-level
# constants, the same-named aliases and each function's locals are read from those tokens (r34: regular expressions
# over lines, comments and strings included for the imports and the words).
funcs, def_info = {}, {}
bodies = collections.defaultdict(list)
qualified_bodies = {}
body_index = collections.defaultdict(set)
stems = {f: f.rsplit("/", 1)[-1][:-4] for f in texts}
types, imports, tokens, cconsts, aliases = {}, {}, {}, {}, {}
for f in texts:
    toks = file_toks(f)
    n = len(toks)
    fds = sorted(zigtok.functions_of_tokens(toks), key=lambda d_: d_["start"])
    defs, owner = [], [None] * n
    for k, d in enumerate(fds):
        defs.append([d["name"] if d["kind"] == "fn" else "(test)", toks[d["start"]].line, toks[d["end"]].line,
                     d["kind"] == "test"])
        lo, hi = max(d["start"], 0), min(d["end"], n - 1)
        if lo > hi:
            continue
        if owner[lo] is not None and defs[owner[lo]][3]:
            defs[k][3] = True   # a function inside a test block is test code
        owner[lo:hi + 1] = [k] * (hi - lo + 1)
    funcs[f] = defs
    def_info[f] = fds
    in_cont = [False] * n   # r35: tokens inside a container body (not the file's own level)
    container_defs = zigtok.containers_of_tokens(toks, fds)
    function_paths = zigtok.function_paths(fds, container_defs)
    for c in container_defs:
        lo, hi = c["open"], min(c["close"], n - 1)
        if lo <= hi:
            in_cont[lo:hi + 1] = [True] * (hi - lo + 1)

    def add_runs(key, qs, lc):
        run = []
        for q in qs + [None]:
            if run and (q is None or q != run[-1] + 1):
                bodies[key].append((run[0], run[-1], lc))
                RUN_LINES[(key[0], run[0], run[-1])] = tuple(sorted({toks[r_].line for r_ in run}))
                run = []
            if q is not None:
                run.append(q)
    add_runs((f, "(container)"), [q for q in range(n) if owner[q] is None], set())
    for k, d in enumerate(fds):
        if defs[k][3] or d["kind"] != "fn" or d["body"] is None:
            continue
        b0, b1 = d["body"]
        qs = [q for q in range(b0 + 1, min(b1, n)) if owner[q] == k]
        names = set()
        if d["params"]:
            for run_ in zigtok.split_args(toks, d["params"][0])[0]:
                run_ = [y for y in run_ if not (y.kind == "keyword" and y.text in ("comptime", "noalias"))]
                if len(run_) >= 2 and run_[0].kind == "identifier" and zigtok.is_op(run_[1], ":"):
                    names.add(run_[0].text)
        for q in qs:
            if zigtok.declaration_at(toks, q):
                names.add(toks[q + 1].text)
            elif zigtok.payload_at(toks, q):
                names.update(y.text for y in zigtok.payload_names(toks, q)[0])
        key = (f, d["name"])
        first = len(bodies[key])
        add_runs(key, qs, names)
        if (function_path := function_paths.get(d["fn"])) is not None:
            qualified_bodies.setdefault((f, function_path), []).extend(bodies[key][first:])
    for key in [(f, "(container)")] + [(f, d["name"]) for d in fds if d["kind"] == "fn"]:
        for a, b, _ in bodies.get(key, ()):
            for q in range(a, b + 1):
                if toks[q].kind == "identifier":
                    body_index[toks[q].text].add(key)
    # the sets that decide which files can hold a caller: each the union of the tokens' reading and r34's reading of
    # the text (a file's words and imports with its comments, its type names at a line's start), so each is a
    # superset of r34's and can only let an edge count: a caller that names the callee's file only in a comment (a
    # port's user, Pacer.zig) keeps its edge
    t_ = texts[f]
    types[f] = ({c["name"] for c in zigtok.containers_of_tokens(toks, fds) if c["naming"] == "declaration"
                 and c["head"] is not None and toks[c["head"]].text == "const" and re.fullmatch(r"[A-Z]\w*", c["name"])}
                | set(re.findall(r"^\s*(?:pub\s+)?const\s+([A-Z]\w*)\s*=\s*(?:extern\s+|packed\s+)?(?:struct|union|enum|opaque)\b",
                                 t_, re.M)) | {stems[f]})
    imports[f] = ({zigtok.string_value(toks[q + 2]).rsplit("/", 1)[-1] for q in range(n - 3)
                   if toks[q].kind == "builtin" and toks[q].text == "@import" and zigtok.is_op(toks[q + 1], "(")
                   and toks[q + 2].kind == "string" and zigtok.string_value(toks[q + 2]) is not None
                   and zigtok.is_op(toks[q + 3], ")")}
                  | {p.rsplit("/", 1)[-1] for p in re.findall(r'@import\("([^"]+)"\)', t_)})
    tokens[f] = {x.text for x in toks if x.kind == "identifier"} | set(re.findall(r"\b[A-Za-z_]\w*\b", t_))
    cconsts[f] = ({toks[q + 1].text for q in range(n - 2) if zigtok.declaration_at(toks, q) and toks[q].text == "const"
                   and owner[q] is None and not in_cont[q]}
                  | set(re.findall(r"^(?:pub\s+)?const\s+(\w+)\s*=", t_, re.M)))
    al = set()
    for q in range(n - 3):
        if zigtok.declaration_at(toks, q) and toks[q].text == "const" and zigtok.is_op(toks[q + 2], "="):
            r = q + 3
            parts = []
            while r < n and toks[r].kind == "identifier":
                parts.append(toks[r].text)
                if r + 1 < n and zigtok.is_op(toks[r + 1], "."):
                    r += 2
                    continue
                r += 1
                break
            if len(parts) >= 2 and r < n and zigtok.is_op(toks[r], ";") and parts[-1] == toks[q + 1].text:
                al.add(toks[q + 1].text)
    aliases[f] = al | {m.group(1) for m in re.finditer(r"^\s*(?:pub\s+)?const\s+(\w+)\s*=\s*[\w.]+\.(\w+)\s*;", t_, re.M)
                       if m.group(1) == m.group(2)}
NOT_REF = r"\b(?!\s*(?:[.\[:(]|=(?!=)))"
NOT_FIELD = r"\b(?!\s*(?:[.\[:]|=(?!=)))"


def norm(s):
    return " ".join(s.split())


def names_file(g, f):
    return (f.rsplit("/", 1)[-1] in imports[g]) or bool(types[f] & tokens[g])


STARTS_DOT = (".", ".*", "..", "...")


def refs_in(toks, name, lo=0, hi=None):
    """r32 (round 31's lead direction): the references to `name` in a token run, as (line, kind, receiver), r31's
    three patterns read from tokens, so a comment or a line break between a dot, the name and its parenthesis splits
    none: "call", `R.name(` (R: the word before the dot, or None for any other token); "value", `R.name` not followed
    by a token that starts with `.`, nor `[`, `:`, `(`, `=` or `=>` (R: the word before the dot, or `@This()`);
    "bare", `name` not after a dot, `fn` or an adjacent `:`, and not followed by such a token but `(`."""
    out = []
    for q in range(lo, len(toks) if hi is None else min(hi + 1, len(toks))):
        x = toks[q]
        if x.kind != "identifier" or x.text != name:
            continue
        p = toks[q - 1] if q else None
        nx = toks[q + 1] if q + 1 < len(toks) else None
        after_field = nx is not None and ((nx.kind == "op" and nx.text in STARTS_DOT) or zigtok.is_op(nx, "[", ":", "=", "=>"))
        if zigtok.is_op(p, "."):
            r = toks[q - 2] if q >= 2 else None
            word = r.text if r is not None and r.kind in ("identifier", "keyword", "number") else None
            if zigtok.is_op(nx, "("):
                out.append((x.line, "call", word))
            elif not after_field:
                if word is None and zigtok.is_op(r, ")") and q >= 4 and zigtok.is_op(toks[q - 3], "(") \
                        and toks[q - 4].kind == "builtin" and toks[q - 4].text == "@This":
                    word = "@This()"
                if word is not None:
                    out.append((x.line, "value", word))
            continue
        if p is not None and ((p.kind == "keyword" and p.text == "fn") or (zigtok.is_op(p, ":") and p.start + 1 == x.start)):
            continue
        if not after_field:
            out.append((x.line, "bare", None))
    return out


def ref_lines(f, name, g, span_list):
    """Every line index in g's spans that references f's function `name`; r32: read from the code tokens (refs_in),
    each hit on the line its name stands on; r35: each span a run of the file's tokens, read with the file's tokens
    around it; r31 matched three patterns on each cleaned line."""
    out = []
    via_alias = name in aliases[g]
    toks_g = file_toks(g)
    for a, b, lc in span_list:
        if not any(toks_g[q].text == name for q in range(a, b + 1)):
            continue
        bare_ok, hits = None, set()
        for ln, kind, rv in refs_in(toks_g, name, a, b):
            if kind == "call":
                hit = g == f or rv != "self" or via_alias
            elif kind == "value":
                hit = rv != "self" and (rv[0].isupper() or rv == "@This()" or rv in cconsts[g])
            else:
                if bare_ok is None:
                    bare_ok = name not in lc and (g == f or name in cconsts[g] or via_alias)
                hit = bare_ok
            if hit:
                hits.add(ln)
        out.extend(sorted(hits))
    return out


_detail_cache = {}


def caller_detail(f, name):
    """{caller key: [(line number, normalised line)]} before false edges."""
    ck = (f, name)
    # The fingerprint remains a census of possible mentions. A qualified
    # acquisition chooses its own reviewed body and chain independently.
    name = retok(name.rsplit(".", 1)[-1])
    if ck not in _detail_cache:
        out = {}
        for (g, cn) in body_index.get(name, ()):
            if (g, cn) == (f, name):
                continue
            if g != f and not names_file(g, f):
                continue
            ls = ref_lines(f, name, g, bodies[(g, cn)])
            if ls:
                out[f"{g}:{cn}"] = [(i + 1, norm(clean_of[g][i])) for i in ls]
        _detail_cache[ck] = out
    return _detail_cache[ck]


def callers(f, name, false_edges, with_lines=False):
    out = {}
    for c, mentions in caller_detail(f, name).items():
        allowed = false_edges.get((f"{f}:{name}", c))
        if allowed is not None and all(txt in allowed for _, txt in mentions):
            continue
        out[c] = mentions[0][0]
    return dict(sorted(out.items())) if with_lines else sorted(out)


def fingerprint(f, name, false_edges):
    return hashlib.sha1("|".join(callers(f, name, false_edges)).encode()).hexdigest()[:10]


def signature_of(occ):
    """AA5: a function's acquisitions by kind and operation; lock and lockUncancelable are one spelling."""
    c = collections.Counter((kind, "lock" if op == "lockUncancelable" else op) for _, op, kind in occ)
    return "+".join(f"{k}.{o}:{n}" for (k, o), n in sorted(c.items()))


def load_table(path):
    rows, false_edges, bad = [], {}, []
    for l in open(path, encoding="utf-8"):
        l = l.rstrip("\n")
        if l.startswith("#false-edge\t"):
            p = l.split("\t")
            if len(p) < 5:
                bad.append(l)
                continue
            false_edges.setdefault((p[1], p[2]), set()).add(p[3])
            continue
        if not l.strip() or l.startswith("#"):
            continue
        f = l.split("\t")
        while len(f) < 7:
            f.append("")
        rows.append(dict(file=f[0], function=f[1], fingerprint=f[2], threads=f[3], scope=f[4], reason=f[5], chain=f[6]))
    return rows, false_edges, bad


def covered(r):
    return r["function"][2:-1].split(",") if r["function"].startswith("*[") else [r["function"]]


def row_for(rows, f, name, scope):
    """(row, approved fingerprint, approved signature) for a function in this scope."""
    for sc_ in LOOKUP[scope]:
        for r in rows:
            if r["file"] == f and r["scope"] == sc_ and name in covered(r):
                if r["function"].startswith("*["):
                    fps = dict(x.split("=", 1) for x in r["fingerprint"].split(",") if "=" in x)
                    v = fps.get(name, "")
                else:
                    v = r["fingerprint"]
                fp, _, sig = v.partition("@")
                return r, fp, sig
    return None, None, None


@functools.lru_cache(maxsize=None)
def body_text(path, fn):
    """r35: each body run's cleaned lines (the lines its tokens stand on), joined: the text reviewed evidence reads."""
    return tuple("\n".join(clean_of[path][i] for i in run_lines(path, a, b)) for a, b, _ in body_runs(path, fn))


def body_runs(path, fn):
    key = (path, fn)
    return qualified_bodies[key] if key in qualified_bodies else bodies.get(key, ())


def token_rx(token):
    return re.compile(r"(?<!\w)" + re.escape(token) + r"(?!\w)")


def token_line(path, fn, token):
    rx = token_rx(token)
    for a, b, _ in body_runs(path, fn):
        for i in run_lines(path, a, b):
            if rx.search(clean_of[path][i]):
                return i + 1
    return None


def regex_line(path, fn, rx):
    rx = re.compile(rx)
    for a, b, _ in body_runs(path, fn):
        for i in run_lines(path, a, b):
            if rx.search(clean_of[path][i]):
                return i + 1
    return None


def hop_line(h):
    if h.startswith("guard:"):
        path, fn, rest = h[len("guard:"):].split(":", 2)
        return regex_line(path, fn, rest.split("=>", 1)[0])
    path, fn, token = h.split(":", 2)
    return token_line(path, fn, token)


def is_evidence(h):
    return h.startswith("absent:") or h.startswith("guard:")


def is_annotation(h):
    """M-b: `inline:<kind>:<attribution>` records a measured attribution; it is not a call-chain hop."""
    return h.strip().startswith("inline:")


def hop_ok(h, site_file, site_fn):
    h = h.strip()
    if not h or is_annotation(h):
        return True
    if h.startswith("absent:"):
        rx = re.compile(h[len("absent:"):])
        return not any(rx.search(t) for (g, cn) in bodies if (g, cn) != (site_file, site_fn) for t in body_text(g, cn))
    if h.startswith("guard:"):
        path, fn, rest = h[len("guard:"):].split(":", 2)
        lines = [regex_line(path, fn, rx) for rx in rest.split("=>")]
        return len(lines) >= 2 and all(x is not None for x in lines) and all(a < b for a, b in zip(lines, lines[1:]))
    path, fn, token = h.split(":", 2)
    rx = token_rx(token)
    return any(rx.search(t) for t in body_text(path, fn))


def load_anchors(path):
    """r29 (round 28's Opus M2): the thread anchors, reviewed data (ci/thread-anchors.tsv; the full self-test reads
    the frozen fixture's copy): {thread: [((file, function), proof hop)]}, from rows `thread file function proof`.
    r28 kept them in this file's code, outside the fixture, so re-pinning the live anchors would have broken the
    pinned self-test's control 00. A malformed row fails the run (BAD-ANCHORS)."""
    out = collections.defaultdict(list)
    for l in open(path, encoding="utf-8"):
        if not l.strip() or l.startswith("#"):
            continue
        p = l.rstrip("\n").split("\t")
        if p[0] == "thread":
            continue
        if len(p) != 4 or p[0] not in ROLES:
            sys.exit(f"BAD-ANCHORS {path}: {l.strip()[:80]}")
        out[p[0]].append(((p[1], p[2]), p[3]))
    return dict(out)


ANCHORS = {}   # r29: loaded from the anchors file by the modes that read them


def anchor_proof_ok(node, proof):
    """r30 (round 29's Opus L2): one hop as before, or a `=>` chain: the first hop in the anchor's own file and
    function, every hop found, and each hop's token naming the next hop's function as its last word."""
    hops = [h.strip() for h in proof.split("=>")]
    if len(hops) == 1:
        return hop_ok(hops[0], "", "")
    parts = [h.split(":", 2) for h in hops]
    if any(len(p) != 3 for p in parts) or (parts[0][0], parts[0][1]) != tuple(node):
        return False
    for (pa, fa, ta), (pb, fb, tb) in zip(parts, parts[1:]):
        words = re.findall(r"\w+", ta)
        if not words or words[-1] != fb:
            return False
    return all(hop_ok(h, "", "") for h in hops)


@functools.lru_cache(maxsize=None)
def winapi_procs():
    out = set()
    for f in lines_of:
        if not f.startswith("src/apprt/win32") or f.endswith("test_support.zig"):
            continue
        toks = file_toks(f)
        for (name, a, b, is_test), d in zip(funcs[f], def_info[f]):   # r35: from the declaration's tokens
            if is_test or d["kind"] != "fn" or not re.search(r"[Pp]roc$", name) or not d["params"]:
                continue
            p0, p1 = d["params"]
            if zigtok.spaced(toks[p1 + 1:p1 + 6]) != "callconv(.winapi)":
                continue
            params = [run_ for run_ in zigtok.split_args(toks, p0)[0] if run_]
            if len(params) == 4 and len(params[1]) >= 3 and zigtok.is_op(params[1][1], ":") and re.fullmatch(
                    r"(?:[\w.]*\.)?(?:UINT|u32)", zigtok.spaced(params[1][2:], blank=True)):
                out.add((f, name))
    return out


def anchor_nodes(thread):
    nodes = {n for n, _ in ANCHORS.get(thread, [])}
    if thread == "ui":
        nodes |= winapi_procs()
    return nodes


def path_ok(site_file, name, thread, hops):
    targets = anchor_nodes(thread)
    if (site_file, name) in targets:
        return True
    by_child = collections.defaultdict(list)
    for h in hops:
        if is_evidence(h) or is_annotation(h) or not h.strip():
            continue
        path, fn, token = h.split(":", 2)
        child = re.findall(r"\w+", token)
        if child:
            by_child[child[-1]].append((path, fn))
    seen, frontier = {name}, [name.rsplit(".", 1)[-1]]
    while frontier:
        nxt = []
        for c in frontier:
            for node in by_child.get(c, []):
                if node in targets:
                    return True
                if node[1] not in seen:
                    seen.add(node[1])
                    nxt.append(node[1].rsplit(".", 1)[-1])
        frontier = nxt
    return False


def chain_to(f, name, thread, false_edges, max_hops=14):
    import heapq
    targets = anchor_nodes(thread)
    start = (f, name)
    if start in targets:
        return []
    best, parent, heap = {start: 0}, {start: None}, [(0, 0, start)]
    while heap:
        cost, hops_n, cur = heapq.heappop(heap)
        if cost > best.get(cur, 1 << 30):
            continue
        if cur in targets:
            hops, n = [], cur
            while parent[n] is not None:
                hops.append(f"{n[0]}:{n[1]}:{parent[n][1]}")
                n = parent[n]
            return hops
        if hops_n >= max_hops:
            continue
        cs = callers(cur[0], cur[1], false_edges)
        for c in cs:
            g, cn = c.split(":", 1)
            if cn == "(container)":
                continue
            nc = cost + len(cs)
            if nc < best.get((g, cn), 1 << 30):
                best[(g, cn)] = nc
                parent[(g, cn)] = cur
                heapq.heappush(heap, (nc, hops_n + 1, (g, cn)))
    return None


def cite(h):
    if h.startswith("absent:"):
        return h
    ln = hop_line(h)
    if h.startswith("guard:"):
        path, fn, _ = h[len("guard:"):].split(":", 2)
    else:
        path, fn, _ = h.split(":", 2)
    return f"{path.rsplit('/', 1)[-1]}:{ln if ln else '?'} {fn}"


def inv_sites(prefix):
    """The gate's sites: lock_inventory5.py's non-test renderer-state, demand, relock and handoff-internal rows."""
    out = []
    for l in open(prefix + "-sites.tsv", encoding="utf-8"):
        u = l.rstrip("\n").split("\t")
        if len(u) < 7 or u[0] != rev or u[6] == "test":
            continue
        if u[5] not in ("renderer-state", "demand", "relock", "handoff-internal"):
            continue
        fname = "(container)" if u[3] == "(top level)" else u[3]
        out.append((u[1], fname, int(u[2]), u[4], u[5]))
    return out


def inv_inline(prefix):
    """M-b: {(file, function): inline flag} for production sites the inventory flags."""
    out = {}
    for l in open(prefix + "-sites.tsv", encoding="utf-8"):
        u = l.rstrip("\n").split("\t")
        if len(u) < 10 or u[0] != rev or u[6] == "test" or u[8] == "-":
            continue
        if u[5] not in ("renderer-state", "demand", "relock", "handoff-internal"):
            continue
        fname = "(container)" if u[3] == "(top level)" else u[3]
        out[(u[1], fname)] = u[8]
    return out


def inv_test_sites(prefix):
    """M-f: test-code sites as (file, function, line, op, kind, outermost test name)."""
    out = []
    for l in open(prefix + "-sites.tsv", encoding="utf-8"):
        u = l.rstrip("\n").split("\t")
        if len(u) < 10 or u[0] != rev or u[6] != "test":
            continue
        if u[5] not in ("renderer-state", "demand", "relock", "handoff-internal"):
            continue
        out.append((u[1], u[3], int(u[2]), u[4], u[5], u[9]))
    return out


def test_key(tid):
    """r25: a site's TEST value, `named:<exact name>`, gives its key; any other kind gives none (lock_inventory10.py)."""
    return tid[len("named:"):] if tid.startswith("named:") else None


def test_row(rows, f, name, key):
    """r25 (round 24's M1): the test row whose chain is exactly `test:` + the test's exact decoded name; never trimmed."""
    for r in rows:
        if r["scope"] == "test" and r["file"] == f and name in covered(r) and r["chain"] == "test:" + key:
            return r
    return None


def trimmed_payload(chain):
    """r25: a test row's name with surrounding whitespace removed, used only to diagnose WHITESPACE-MISMATCH."""
    c = chain.strip()
    return c[len("test:"):].strip() if c.startswith("test:") else None


def inv_summary(prefix):
    for l in open(prefix + "-summary.tsv", encoding="utf-8"):
        u = l.rstrip("\n").split("\t")
        if u[0] == rev:
            return dict(acquisitions=int(u[1]), relocks=int(u[2]), internal=int(u[3]))
    return None


SPAWN_APIS = r"CreateThread|_beginthreadex|CreateThreadpoolWork|CreateThreadpoolTimer|CreateThreadpoolWait|" \
             r"TrySubmitThreadpoolCallback|QueueUserWorkItem|CreateTimerQueueTimer|RegisterWaitForSingleObject"


SPAWN_SET = frozenset(SPAWN_APIS.split("|"))
ENTRY_WORDS = ("spawn", "async", "concurrent") + tuple(sorted(SPAWN_SET))


def thread_entries():
    """{(file, function, api, target)} for every non-test thread or task creation; r32 (round 31's lead direction):
    read from the code tokens of each function's lines, so a comment or a line break between a name and its
    parenthesis hides none, and the arguments split structurally (r31 matched each cleaned line and read 12 lines of
    arguments): `Thread.spawn(` (the word before the dot `Thread`), the decl literal `.spawn(` (no operand before the
    dot: `state.thread = try .spawn(...)`; a child process's `child.spawn()` has a receiver and is no thread),
    `X.async(` and `X.concurrent(` (X the word before the dot), and a Win32 thread or thread-pool creation call."""
    io_arg = re.compile(r"(?<![\w.])(?:\w+\.)*io(?:\(\))?$|^io$")
    out = set()
    for (f, fn), spans in bodies.items():
        for a, b, _ in spans:
            toks = file_toks(f)   # r35: the body's runs of the file's tokens, read with the file's tokens around them
            if not any(toks[q].text in ENTRY_WORDS for q in range(a, b + 1)):
                continue
            for q in range(a, b + 1):
                x = toks[q]
                if x.kind != "identifier" or q + 1 >= len(toks) or not zigtok.is_op(toks[q + 1], "("):
                    continue
                p = toks[q - 1] if q else None
                r = toks[q - 2] if q >= 2 else None
                api = None
                if x.text == "spawn" and zigtok.is_op(p, "."):
                    if r is not None and r.kind == "identifier" and r.text == "Thread":
                        api = "Thread.spawn"
                    elif r is None or not (r.kind in ("identifier", "number", "string", "char")
                                           or zigtok.is_op(r, ")", "]", "?", ".*")):   # `try .spawn(`: no operand
                        api = "Thread.spawn"
                elif x.text in ("async", "concurrent") and zigtok.is_op(p, ".") and r is not None and r.kind == "identifier":
                    api = r.text + "." + x.text
                elif x.text in SPAWN_SET:
                    api = x.text
                if api is None:
                    continue
                # the call's arguments, from the file's tokens (a nested function may split the span)
                call, k0 = toks, q
                runs, end = zigtok.split_args(call, k0 + 1)
                av = [zigtok.spaced(run_, blank=True) for run_ in runs] or [""]
                if runs and end < len(call) and zigtok.is_op(call[end - 1], ","):
                    av.append("")   # r31's reader gave a trailing comma an empty last argument
                if "spawn" in api:
                    target = av[1] if len(av) > 1 else "?"
                elif api.endswith("async") or api.endswith("concurrent"):
                    recv = api.rsplit(".", 1)[0]
                    io_recv = recv.lower().endswith("io") or recv == "group"
                    io_pos = next((k for k, y in enumerate(av) if io_arg.search(y)), None)
                    # Sol L4: every task-call form is an entry, whatever its arguments are spelled; the target is
                    # the argument after the Io (or after the first argument when no argument is spelled io)
                    if io_recv and not recv == "group":
                        target = av[0] if av else "?"
                    else:
                        k1 = (io_pos + 1) if io_pos is not None else 1
                        target = av[k1] if len(av) > k1 else "?"
                else:
                    target = next((y for y in av if "&" in y or "Proc" in y or "Callback" in y), av[0] if av else "?")
                out.add((f, untok(fn), re.sub(r"^\w*io\.", "io.", api), untok(target)))   # r28: as reviewed
    return out


def load_entries(path):
    out = set()
    if path == "-" or not os.path.exists(path):
        return out
    for l in open(path, encoding="utf-8"):
        if l.strip() and not l.startswith("#"):
            p = l.rstrip("\n").split("\t")
            out.add(tuple(p[:4]))
    return out


if mode == "sites":
    for s in inv_sites(args[2]):
        print("\t".join(map(str, s)))
    sys.exit(0)

if mode == "entries":
    for e in sorted(thread_entries()):
        print("\t".join(e))
    sys.exit(0)

if mode == "anchors":
    ANCHORS = load_anchors(args[2])
    for th, lst in ANCHORS.items():
        for node, proof in lst:
            print(f"{th}\t{node[0]}:{node[1]}\tproof {proof}\t{'ok' if anchor_proof_ok(node, proof) else 'MISSING'}"
                  f"\tline {hop_line(proof.split('=>')[-1].strip())}")
    for node in sorted(winapi_procs()):
        print(f"ui\t{node[0]}:{node[1]}\twindow procedure (callconv(.winapi))")
    sys.exit(0)

if mode == "rekey":
    table_path, out_path = args[2], args[3]
    out = []
    for l in open(table_path, encoding="utf-8"):
        l = l.rstrip("\n")
        if l.startswith("#false-edge\t"):
            p = l.split("\t")
            callee, caller = p[1], p[2]
            why = p[-1]
            f, name = callee.split(":", 1)
            mentions = caller_detail(f, name).get(caller, [])
            if not mentions:
                out.append(f"# stale false edge, no mention now: {callee} <- {caller} ({why})")
            for txt in sorted({t for _, t in mentions}):
                out.append("\t".join(["#false-edge", callee, caller, txt, why]))
            continue
        out.append(l)
    open(out_path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
    print("rekeyed")
    sys.exit(0)

scope, table_path = args[2], args[3]
rows, false_edges, bad_edges = load_table(table_path)

if mode == "edges":
    for r in rows:
        if r["scope"] not in LOOKUP[scope]:
            continue
        for n in covered(r):
            cs = callers(r["file"], n, false_edges, with_lines=True)
            print(f"{r['file']}:{n}\t[{r['threads']}]\t{len(cs)} callers")
            for c, ln in cs.items():
                g = c.split(":", 1)[0]
                print(f"    {c}\t{ln}: {clean_of[g][ln - 1].strip()[:120]}")
    print(f"# {sum(len(v) for v in false_edges.values())} false-edge lines over {len(false_edges)} edges")
    sys.exit(0)

if mode == "chains":
    inv_prefix, out_path = args[4], args[5]
    ANCHORS = load_anchors(args[6])
    site_fns = {(s[0], s[1]) for s in inv_sites(inv_prefix)}
    rows_out, missing = [], []
    for l in open(table_path, encoding="utf-8"):
        l = l.rstrip("\n")
        if not l.strip() or l.startswith("#"):
            rows_out.append(l)
            continue
        f = l.split("\t")
        while len(f) < 7:
            f.append("")
        if f[4] not in LOOKUP[scope] or f[3] == "never-on-win32":
            rows_out.append("\t".join(f))
            continue
        hops_all = [h for h in f[6].split(";") if h.strip()]
        for n in covered(dict(function=f[1])):
            if (f[0], n) not in site_fns:
                continue
            for th in f[3].split("|"):
                if path_ok(f[0], n, th, hops_all):
                    continue
                c = chain_to(f[0], n, th, false_edges)
                if c is None:
                    missing.append(f"{f[0]}:{n} -> {th}")
                else:
                    hops_all += [h for h in c if h not in hops_all]
        f[6] = ";".join(hops_all)
        reason = re.sub(r"\s*\[chain: .*\]$", "", f[5])
        cited = [cite(h) for h in hops_all if not h.startswith("absent:")]
        if cited:
            reason += " [chain: " + "; ".join(cited) + "]"
        f[5] = reason
        rows_out.append("\t".join(f))
    open(out_path, "w", encoding="utf-8", newline="\n").write("\n".join(rows_out) + "\n")
    print(f"rows written; no chain found for {len(missing)}")
    for m in missing:
        print("  NO-CHAIN " + m)
    sys.exit(0)

if mode == "approve":
    inv_prefix = args[4]
    sig_occ = collections.defaultdict(list)
    for f_, n_, ln_, op_, kind_ in inv_sites(inv_prefix):
        sig_occ[(f_, n_)].append((ln_, op_, kind_))
    test_occ = collections.defaultdict(list)
    for f_, n_, ln_, op_, kind_, tid_ in inv_test_sites(inv_prefix):
        test_occ[(f_, n_, tid_)].append((ln_, op_, kind_))
    out, side = [], []
    for l in open(table_path, encoding="utf-8"):
        l = l.rstrip("\n")
        if not l.strip() or l.startswith("#"):
            out.append(l)
            continue
        f = l.split("\t")
        while len(f) < 7:
            f.append("")
        if f[4] == "test":
            tid = "named:" + f[6][len("test:"):] if f[6].startswith("test:") else None   # r25: exact, never trimmed
            f[2] = "@" + signature_of(test_occ.get((f[0], f[1], tid), []))
        elif f[4] in LOOKUP[scope]:
            names = covered(dict(function=f[1]))
            fps = {n: fingerprint(f[0], n, false_edges) + "@" + signature_of(sig_occ.get((f[0], n), [])) for n in names}
            f[2] = ",".join(f"{n}={fps[n]}" for n in names) if f[1].startswith("*[") else fps[names[0]]
            for n in names:
                side.append(untok("\t".join([f[0], n, f[4], fps[n], "|".join(callers(f[0], n, false_edges))])))
        out.append("\t".join(f))
    open(table_path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
    base = table_path[:-4] if table_path.endswith(".tsv") else table_path
    open(base + ".callers.tsv", "w", encoding="utf-8", newline="\n").write(
        "# file\tfunction\tscope\tfingerprint@signature\tsorted callers (the review diff for a changed fingerprint)\n"
        + "\n".join(side) + "\n")
    print(f"approved fingerprints written for scope {scope} at {rev}; caller sidecar {base}.callers.tsv")
    sys.exit(0)

# ---------------------------------------------------------------- check
allow_path, inv_prefix, entries_path = args[4], args[5], args[6]
ANCHORS = load_anchors(args[7])   # r29 (round 28's Opus M2)
_inv_fail = [l_[2:].rstrip("\n") for l_ in open(inv_prefix + "-summary.tsv", encoding="utf-8")
             if l_.startswith(("# UNREADABLE-", "# QUOTED-TOKEN-COLLISION", "# TOOL-ERROR"))] \
    if os.path.exists(inv_prefix + "-summary.tsv") else []
if _inv_fail:   # r28 (round 27's lead note): the inventory could not read a spelling, so it gave no result to check
    for _x in _inv_fail:
        print("FAIL " + _x)
    _k = collections.Counter(_x.split(" ", 1)[0] for _x in _inv_fail)
    print(f"RESULT FAIL ({len(_inv_fail)} failures) " + " ".join(f"{k}={v}" for k, v in sorted(_k.items())))
    sys.exit(1)
enforced = scope in ENFORCED
failures = []
counts = collections.Counter()
base = table_path[:-4] if table_path.endswith(".tsv") else table_path
sidecar = {}
if os.path.exists(base + ".callers.tsv"):
    for l in open(base + ".callers.tsv", encoding="utf-8"):
        if l.startswith("#") or not l.strip():
            continue
        p = l.rstrip("\n").split("\t")
        sidecar[(p[0], p[1], p[2])] = set(x for x in p[4].split("|") if x)   # p[3] is fingerprint@signature
for l in bad_edges:
    failures.append(f"FALSE-EDGE-NO-TEXT {l.split(chr(9))[1:3]}: key the false edge on its mentioning line (Y3)")
if enforced:
    for th, lst in ANCHORS.items():
        for node, proof in lst:
            if not anchor_proof_ok(node, proof):
                failures.append(f"ANCHOR-MOVED {th} {node[0]}:{node[1]}: {proof} not found")
site_list = inv_sites(inv_prefix)
summ = inv_summary(inv_prefix)
if summ is None:
    failures.append(f"SITE-COUNT-MISMATCH no inventory summary for {rev}")
elif len(site_list) != summ["acquisitions"] + summ["relocks"] + summ["internal"]:
    failures.append(f"SITE-COUNT-MISMATCH gate {len(site_list)} != acquisitions {summ['acquisitions']} + relocks "
                    f"{summ['relocks']} + handoff-internal {summ['internal']}")
reported_hops = set()   # a failing hop is reported once per row, not once per function the row covers
inline_of = inv_inline(inv_prefix)
inline_rows = collections.defaultdict(lambda: ([], []))   # row key -> (flags of its functions, its annotations)
site_fns = collections.defaultdict(list)
for f, name, line, op, kind in site_list:
    site_fns[(f, name)].append((line, op, kind))
seen_rows = set()
for (f, name), occ in sorted(site_fns.items()):
    line = occ[0][0]
    counts["sites"] += len(occ)
    counts["relocks"] += sum(1 for o in occ if o[2] == "relock")
    if name.startswith('@"'):   # r26 (round 25's M1): a quoted name that decodes to no plain identifier
        for ln, op, kind in occ:
            failures.append(f"FN-NAME-NOT-IDENTIFIER {f}:{ln} {name} ({kind}, {op}): rename the function to a plain "
                            f"identifier; a row cannot be reviewed or traced for this name")
        continue
    r, fp, sig = row_for(rows, f, name, scope)
    if r is None:
        for ln, op, kind in occ:
            failures.append(f"UNREVIEWED {f}:{ln} {name} ({kind}, {op})")
        continue
    counts[r["threads"]] += len(occ)
    if not enforced:
        continue
    cur = fingerprint(f, name, false_edges)
    if cur != fp:
        old = fp or "(none)"
        now = {untok(c_) for c_ in callers(f, name, false_edges)}   # r28: decoded, as the sidecar is written
        prev = sidecar.get((f, name, r["scope"]))
        diff = (" added " + ",".join(sorted(now - prev)) + " removed " + ",".join(sorted(prev - now))) if prev is not None \
            else " callers=" + ",".join(sorted(now))
        failures.append(f"CHANGED-FINGERPRINT {f}:{line} {name}: approved {old} now {cur};{diff}")
    cur_sig = signature_of(occ)
    if cur_sig != sig:
        failures.append(f"CHANGED-SIGNATURE {f}:{line} {name}: approved {sig or '(none)'} now {cur_sig}")
    hops = [h for h in r["chain"].split(";") if h.strip() and not is_annotation(h)]
    ann = [h.strip() for h in r["chain"].split(";") if is_annotation(h)]
    if (f, name) in FORWARDERS:
        if inline_of.get((f, name)) != "inline-fn":
            failures.append(f"FORWARDER-NOT-INLINE {f}:{line} {name}: the demand forwarder must stay an inline fn "
                            f"(0.15.2 attributes a demand acquire to its caller only through the inlining)")
    elif r["threads"] != "never-on-win32":
        flag = inline_of.get((f, name))
        if flag is not None:
            want = "inline-fn" if flag == "inline-fn" else "always-inline"
            if not any(a.split(":", 2)[1] == want and len(a.split(":", 2)) == 3 and a.split(":", 2)[2].strip()
                       for a in ann):
                failures.append(f"INLINE-SITE {f}:{line} {name}: {flag}; make it non-inline in Debug (M-b) or record "
                                f"the measured attribution as inline:{want}:<attribution>")
        inline_rows[(r["file"], r["function"], r["scope"])][0].append(flag)
        inline_rows[(r["file"], r["function"], r["scope"])][1].extend(ann)
    if ARM_RENDERER_DEMAND and "renderer" in r["threads"].split("|"):
        for ln, op, kind in occ:
            if op in ("lock", "lockUncancelable") and kind in ("renderer-state", "relock"):
                failures.append(f"RENDERER-PLAIN-LOCK {f}:{ln} {name}: a {op} in a row that lists renderer (M-c: "
                                f"lockDemand)")
    for h in hops:
        if (r["file"], r["function"], r["scope"], h) in reported_hops:
            continue
        if not hop_ok(h, f, name):
            reported_hops.add((r["file"], r["function"], r["scope"], h))
            failures.append(f"CHANGED-PATH {f}:{line} {name}: hop not found: {h.strip()}")
    if r["threads"] == "never-on-win32":
        key = (r["file"], r["function"])
        if key not in seen_rows:
            seen_rows.add(key)
            ev = [h for h in hops if is_evidence(h)]
            if any(not is_evidence(h) for h in hops):
                failures.append(f"NEVER-CHAIN {f} {r['function']}: a never-on-Win32 row carries a call chain")
            if not ev:
                failures.append(f"NEVER-NO-EVIDENCE {f} {r['function']}: no absent: or guard: evidence")
            elif len(covered(r)) > 1:
                for n in covered(r):
                    # regex escapes (`\b`) are removed first, so `absent:\bdumpText\b` names dumpText
                    if not any(re.search(r"(?<!\w)" + re.escape(n) + r"(?!\w)", re.sub(r"\\[A-Za-z]", " ", h))
                               for h in ev):
                        failures.append(f"NEVER-NO-EVIDENCE {f} {n}: no evidence hop names it")
        continue
    if not hops:
        failures.append(f"NO-CHAIN {f}:{line} {name}: a reviewed row must cite its call chain")
    if not re.search(r"\.zig:\d+", r["reason"]):
        failures.append(f"REASON-NO-LINES {f}:{line} {name}: the reason cites no call-chain line")
    for th in r["threads"].split("|"):
        if not path_ok(f, name, th, hops):
            failures.append(f"NO-PATH {f}:{line} {name}: the chain does not reach a {th} anchor")
if enforced:
    for key, (flags, ann) in sorted(inline_rows.items()):
        if ann and not any(flags):
            failures.append(f"INLINE-STALE {key[0]} {key[1]} ({key[2]}): an inline: annotation but no flagged site; "
                            f"remove it")
    # M-f: test-code sites against test rows
    t_occ = collections.defaultdict(list)
    for tf, tn, tl, top, tk, tid in inv_test_sites(inv_prefix):
        t_occ[(tf, tn, tid)].append((tl, top, tk))
    counts["test sites"] = sum(len(v) for v in t_occ.values())
    used = set()
    for (tf, tn, tid), occ in sorted(t_occ.items()):
        if tn.startswith('@"'):   # r27 (round 26's Sol M2): before any test row, as for a production site
            for r in rows:
                if r["scope"] == "test" and r["file"] == tf and tn in covered(r):
                    used.add(id(r))
            for tl, top, tk in occ:
                failures.append(f"FN-NAME-NOT-IDENTIFIER {tf}:{tl} {tn} in test code ({tk}, {top}): rename the function "
                                f"to a plain identifier; std.debug names it unquoted, so no row can be compared")
            continue
        key = test_key(tid)
        tr = test_row(rows, tf, tn, key) if key is not None else None
        if tr is None:
            near = [r for r in rows if key is not None and r["scope"] == "test" and r["file"] == tf
                    and tn in covered(r) and id(r) not in used and trimmed_payload(r["chain"]) == key.strip()]
            if near:   # r25: the exact name has no row, but a row matches it once whitespace is trimmed; still a failure
                used.add(id(near[0]))
                failures.append(f"WHITESPACE-MISMATCH {tf}:{occ[0][0]} {tn}: test {key[:60]!r} has no row with its exact "
                                f"name; the row {near[0]['chain'][:66]!r} matches it only once whitespace is trimmed, and "
                                f"a test's name is its exact decoded bytes")
                continue
            for tl, top, tk in occ:
                if key is None:
                    failures.append(f"TEST-UNREVIEWED {tf}:{tl} {tn} in a test with no key ({tid[:60]}) ({tk}, {top}): "
                                    f"no row can cover it; give it a UTF-8 string name with no control character")
                else:
                    failures.append(f"TEST-UNREVIEWED {tf}:{tl} {tn} in test {key[:60]!r} ({tk}, {top}): add a test "
                                    f"row with the role(s) it simulates")
            continue
        used.add(id(tr))
        sig_ = tr["fingerprint"].partition("@")[2]
        if signature_of(occ) != sig_:
            failures.append(f"CHANGED-SIGNATURE {tf}:{occ[0][0]} {tn} (test): approved {sig_ or '(none)'} now "
                            f"{signature_of(occ)}")
        roles = [x for x in tr["threads"].split("|") if x]
        if not roles or any(x not in ROLES and not x.startswith("worker:") for x in roles):
            failures.append(f"TEST-NO-ROLE {tf} {tn}: threads '{tr['threads']}' are not roles")
    for r in rows:
        if r["scope"] == "test" and id(r) not in used:
            failures.append(f"STALE-ROW {r['file']} {r['function']} (test): no test site named "
                            f"{r['chain'][len('test:'):][:60]!r}, exactly, in this tree")
    for r in rows:
        if r["scope"] not in LOOKUP[scope] or r["scope"] == "all":
            continue
        for n in covered(r):
            if (r["file"], n) not in site_fns:
                # a row whose function holds no site here is stale only if no earlier-scope row shadows it
                rr, _, _ = row_for(rows, r["file"], n, scope)
                if rr is r:
                    failures.append(f"STALE-ROW {r['file']} {n} ({r['scope']}): no acquisition site in this tree")
    reviewed_entries = load_entries(entries_path)
    if entries_path != "-":
        now = thread_entries()
        for e in sorted(now - reviewed_entries):
            failures.append(f"NEW-THREAD-ENTRY {e[0]} {e[1]}: {e[2]}({e[3]})")
        for e in sorted(reviewed_entries - now):
            failures.append(f"GONE-THREAD-ENTRY {e[0]} {e[1]}: {e[2]}({e[3]})")
allow = {}
if allow_path != "-" and os.path.exists(allow_path):
    for l in open(allow_path, encoding="utf-8"):
        if l.strip() and not l.startswith("#"):
            a = l.rstrip("\n").split("\t")
            if len(a) < 5 or not a[2].strip() or not a[3].strip().isdigit() or int(a[3]) < 1:   # r31: and a count
                sys.exit(f"BAD-ALLOW {allow_path}: {l.strip()[:80]}: a row names a file, a function, a receiver and "
                         f"an approved count")
            allow[(a[0], a[1], a[2])] = int(a[3])
seen_allowed = collections.Counter()
unclassified = 0
ACQ_OPS = ("lock", "tryLock", "lockUncancelable", "lockShared", "tryLockShared", "lockSharedUncancelable", "lockDemand",
           "yieldToDemand", "demand", "@field")   # r29: every acquisition op lock_inventory17.py reads; r31: a called
#                                                     @field whose name is no literal
for l in open(inv_prefix + "-unclassified.tsv", encoding="utf-8"):
    u = l.rstrip("\n").split("\t")
    if len(u) > 6 and u[0] == rev and u[4] in ACQ_OPS and u[3].startswith('@"'):
        # r27 (round 26's Sol M1, M2): an unclassified acquisition in such a function fails too, test code included
        failures.append(f"FN-NAME-NOT-IDENTIFIER {u[1]}:{u[2]} {u[3]} (unclassified, {u[4]}): rename the function "
                        f"to a plain identifier")
        continue
    if len(u) > 6 and u[0] == rev and u[4] in ACQ_OPS and u[6] != "test":
        unclassified += 1
        if (u[1], u[3], u[10] if len(u) > 10 else "") not in allow:   # r30: the receiver too
            failures.append(f"UNCLASSIFIED-NOT-ALLOWED {u[1]}:{u[2]} {u[3]} ({u[10] if len(u) > 10 else 'no receiver'})")
        else:
            seen_allowed[(u[1], u[3], u[10])] += 1
    elif len(u) > 9 and u[0] == rev and u[4] in ACQ_OPS:
        # r29 (round 28's Opus M1): test code too, keyed by its function, or by its test when the block owns it
        key_ = (u[1], u[3] if u[3] != "(test)" else "test:" + u[9].split(":", 1)[-1], u[10] if len(u) > 10 else "")
        if key_ not in allow:
            failures.append(f"UNCLASSIFIED-NOT-ALLOWED {u[1]}:{u[2]} {u[3]} (test code, "
                            f"{u[10] if len(u) > 10 else 'no receiver'})")
        else:
            seen_allowed[key_] += 1
for key_, n_ in sorted(seen_allowed.items()):   # r31 (round 30's Opus L3): each allowed key exactly as often as approved
    if n_ != allow[key_]:
        failures.append(f"ALLOW-COUNT {key_[0]} {key_[1]} ({key_[2]}): {n_} unclassified acquisitions, the row approves "
                        f"{allow[key_]}")
by = dict(sorted((k, v) for k, v in counts.items() if k not in ("sites", "relocks")))
by.pop("test sites", None)
print(f"{rev} scope={scope}{'' if enforced else ' (counts only)'}: {counts['sites']} sites ({counts['relocks']} relocks); "
      f"{unclassified} unclassified; by reviewed threads {by}; {counts['test sites']} test-code sites; "
      f"{len(inline_of)} inline-flagged functions; renderer demand check {'ARMED' if ARM_RENDERER_DEMAND else 'off'}")
kinds = collections.Counter(x.split(" ", 1)[0] for x in failures)
for x in failures:
    print("FAIL " + untok(x))   # r28: a token printed as its canonical quoted spelling
print("RESULT " + ("FAIL" if failures else "PASS") + f" ({len(failures)} failures)"
      + ("" if not kinds else " " + " ".join(f"{k}={v}" for k, v in sorted(kinds.items()))))
sys.exit(1 if (failures and enforced) else 0)
