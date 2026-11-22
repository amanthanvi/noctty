r"""Renderer-state mutex inventory, r14 (round 13: AC2; round 12: M-b, M-f; round 11: Opus L4; round 10 Z1; X3, L6).

Usage: python -I lock_inventory19.py <repo> <out-prefix> <table.tsv> <rev>[=fork|1a|1b|upstream] [...] [--overlay DIR]

r19 (round 18, AH2): the runtime compare keys a pair by file and bare symbol name, so this tool also fails (exit 1,
SAME-NAME) when one file of a revision holds two acquiring functions with the same bare name; the summary's last column
counts them. r20 (round 19, AI2): functions nested in test code count too. r21 (round 20, AJ1): so do test blocks. A
test block's own acquisition is keyed `<file>:test:<name>`, and Zig keeps test names unique per container, not per
file (AstGen's scanContainer keeps its test_names map per container: 0.15.2 lib/std/zig/AstGen.zig:13409, 0.17.1
:13006), while std.debug names both `test.<name>`; so a file whose acquiring test block shares its name with another
test block of the file, in any container, fails SAME-NAME as `test:<name>`. r22 (round 21, Opus L1): names are
compared decoded, as Zig compares them (`test "a\x20b"` is `test "a b"`), here and in the TEST column the gate's test
rows key on; and an acquiring test without a string name (`test {`, which std.debug calls `test_<N>` per container, or a
decltest, `decltest.<ident>`) fails SAME-NAME too, since the compare has no key for it. r23 (round 22, AL2): a name
is decoded to bytes, as Zig reads it (a literal character as its UTF-8 bytes, \xNN as one byte, \u{N} as UTF-8) and
compared as bytes, so `test "a\xc3\xa9"`, `test "a\u{e9}"` and `test "aé"` are one name and `test "ae\u{301}"` is
another; a name whose bytes are not UTF-8 (`test "a\xe9"`, which Zig accepts) has no key, so an acquiring test with one
fails SAME-NAME as well. r24 (round 23): a test block's header parses to a tagged result, never read back from the
decoded name (Sol M1: r23 took a test named `(unnamed)`, `(not UTF-8)` or `decltest:...` for the syntax those strings
labelled); and a name holding a control character (below 0x20, or DEL), such as `test "a\tb"`, has no key either
(Opus L1: a TAB split the sites row, so the gate keyed the test by its prefix). r25 (round 24): the TEST column
carries the kind out of band (Muse L1, Opus L1), `test @"..."` is a decltest (Muse L1), and a name keeps its exact
decoded bytes, trailing whitespace included, which thread_gate6.py matches exactly (M1). r25's own finding: a function
declared `fn @"..."(` and a block opened `test @"..." {` are recognised (named by their spelling); r24 opened neither,
so an acquisition inside one was never counted and the gate passed it. r26 (round 25's M1): a quoted identifier whose
decoded bytes form a plain identifier is that identifier (`fn @"same"` is `fn same`, as Zig and std.debug take it), in
functions() and in sc(), so SAME-NAME sees a plain and a quoted declaration of one name; whitespace may precede a
function's parameter list; any other quoted name keeps its spelling, and the gate fails an acquiring function with one.
r27 (round 26's Sol M1 and audit): the source text is normalized once, where it is read (norm_quoted_idents), so every
pass sees a quoted identifier that decodes to a plain one as that identifier: the call-argument flow and its relocks
and parameter carriers included, which r26 read from raw text; a name that decodes to no plain identifier has one
canonical quoted spelling (canon_quoted). r28 (round 27's Opus M1 and L3, Sol M1, and the lead's note): r27 left
a quoted name that is no plain identifier quoted, and sc() then emptied it as a string literal, so every pass that
reads \w+ lost it: a relock through a callee named `@"defer"`, `X.type(...)` or `self` (r27's KW filter dropped the
primitives and `self` as well) went unclassified, and a mutex parameter or receiver named `@"r27 mutex"` made a
direct acquisition vanish, with no row at all. Now the one normalizer turns every quoted identifier into a word every
later pass reads, as a callee, a parameter, a receiver or an alias: a plain identifier into itself, and a Zig keyword
or primitive (std/zig/tokenizer.zig and std/zig/primitives.zig, the same in 0.15.2 and 0.17.1, neither spellable
unquoted at a declaration) or a name holding any byte outside an identifier into its token, `__zqi_<its bytes in
hex>_`; it skips strings and comments. Outputs decode a token to the canonical quoted spelling, so an acquiring
function so named still fails FN-NAME-NOT-IDENTIFIER at the gate. A spelling the normalizer cannot read (an `@"` with
no closing quote on its line, or source that already holds the token prefix) fails the run, exit 2, writing no rows;
so does a lock call whose receiver the site pass cannot name (an expression, `xs[0].lock()`, or a receiver on the line
before, `.lock()` starting its line), which r27 skipped silently (UNREADABLE-RECEIVER).
The call-argument flow drops real keywords only and reads a primitive called after a dot (`X.type(`, which zig fmt
writes for `X.@"type"(`) as its declaration's token; a parameter carrier's declaration allows whitespace before its
parameter list. r29 (round 28's Sol M1, Opus M1 and the lead's note): r28 named
two failing receiver shapes and let every other lock call its site regex could not match pass unseen, with no row
(`mutex.*.lock()`, `p.?.lock()`, a type-called `Mutex.lock(m)`, a `@call` of `Mutex.lock`, an `&`-bound handle's
`lockDemand()`). Now every lock-op token on a code line is read and lands in exactly one bucket: a site, unclassified,
distinct, another lock (a receiver that is no mutex the tool tracks, or a shared lock), or refused
(UNREADABLE-RECEIVER); a token in none is a TOOL-ERROR (exit 3), and the counts go to <prefix>-tokens.tsv. A receiver
is read through `.*` and `.?`; a type-called op and a `@call`ed op value through their first argument; a handle may be
bound by address; lockDemand, yieldToDemand and demand on an unknown receiver are unclassified; and "distinct" holds
only when the receiver resolves, by its declarations, to a value mutex (r28 decided it by the receiver's last name
anywhere in the file). r30 (round 29's lead direction, Sol M1, M2, Opus M1): default-deny. Rounds 26 to 29 each found
a receiver shape that passed, and chasing shapes does not converge: r29 still put every receiver it did not recognise
as a mutex in "other", unchecked (Sol M1's alias chains, Opus M1's `anytype` and generic helpers, a getter's result,
`if` expressions), and resolved "distinct" through guesses (Sol M2: `Q.f()` taken to return a Q). Now an acquisition
is renderer-state, "distinct" or "other" only with evidence: a declaration chain the resolver found by scope (a typed
parameter or local, a literal, `@as`, `allocator.create(T)`, a local type, a field of a struct this file declares
once, an alias this file declares once, a function of the same struct or file by its declared return type, `Q.f()`
by f's own declaration in Q, a switch capture through those), ending in a recognised type: a value std.Thread.Mutex or
std.Io.Mutex (or this file's alias of one) for "distinct"; an RwLock's exclusive lock, a std file's lock, or a value
std mutex this file does not name for "other". The resolver no longer takes a struct or function of that name from
another file, a file by its stem, the nearest of two same-named structs, or a qualified type's bare name. Everything
else is UNCLASSIFIED: the gate fails it in production and test code unless the allow-list names its file, function
and receiver. So a shape the tool does not understand can raise a false alarm, never pass. Also: a local alias of a
local alias (`const second = first;`) and a type alias of a type alias are followed, any length, and `@import("std")`
counts as std; `&x.mutex.*` binds an alias; an op named as a string, `@field(T, "lock")`, is refused
(UNREADABLE-RECEIVER); a mutex pointer handed to an `anytype` or generic parameter is reported as a carrier.
r31 (round 30's Opus M1, Sol M1, M2 and the lead's direction): r30's evidence was a text match, not lexical scope: it
took the nearest `name:` line back to the function's start, a closed sibling block's declaration and a nested
struct's field included, read past a binding it could not read, fell back to a typed local in any function, and
preferred the file's one struct of a type name to the using container's alias. Now a declaration counts only as the
unique binding of that name in the function holding the use (a const or var, a parameter, an |x| or |*x| capture); a
nested container's lines are not the function's; a binding whose form the resolver does not read gives None, never an
earlier line; containers are read, innermost first, only when the function binds no such name, and only for
declarations directly in them; type names resolve the same way, the using container first; a `comptime` type
parameter, or two declarations of a name in one scope, give None. A function's return type is read from a signature
over several lines too. The census reads every `@field` reference in a file's text, its name with Zig's string escapes
decoded (`"\x6cock"` is `lock`): a name that decodes to a lock op is refused (UNREADABLE-RECEIVER), and a called
`@field` whose name is no literal is an unclassified acquisition, which the allow-list must name.
r32 (round 31's Opus M1, M2, Sol M1, M2 and the lead's direction): r31 read the binding index, the lock-op census and
a reflected call's position one cleaned line at a time, so an untyped destructuring declaration bound nothing (Opus
M1), a lock call split by a comment and a line break was no token at all (Opus M2), and a comment or enough
whitespace between a `@field(...)` and its `(` hid the call (Sol M2); and std's namespace aliases were taken from the
whole file, a sibling container's included (Sol M1). Now the source is read through one shared token stream,
zigtok.py, a port of std/zig/tokenizer.zig's lexical rules checked against both compilers' tokenizers: the cleaned
lines every line pass reads come from it (zigtok.clean_line); the binding index (every `const` or `var` that
declares a name, each element of a destructuring declaration as a binding whose form is not read, every capture list
wherever it starts), the parameter lists, the census (an op name after a dot, called or not, whatever lies between
the dot, the name and the parenthesis), the @field and @call positions and the always_inline targets are read from
its code tokens. A `.op` with no call is no lock op when it is a field (a literal's field or an enum literal, or
followed by `.`, `.*` or `=`), or a field read: its chain starts at a runtime value, or it names a variable a struct
this file declares binds as op; any other is refused (UNREADABLE-RECEIVER). A namespace alias of std counts only as
the binding its name has, by scope, where the type text is read, and `std` only when that binding is
`@import("std")`: a shadowed, ambiguous or unreadable one gives no std type. Distinct acquisitions are also written to
<prefix>-distinct.tsv (rev, file, line, function, op, receiver) for bindcheck32.py, the independent binding check.
r33 (round 32's Opus M1, Sol M1 and the lead's direction): r32 took a no-call `.op` for a field read when its chain
started at a "runtime value", decided from the spelling of the root's type; Zig makes a parameter comptime when its
type is comptime-only (an alias of `type`, `?type`, a struct with a `type` field, `(type)`, `@TypeOf(u8)`) and a `var`
in a comptime context comptime too, so a method value formed through one passed with no row. Now `@call`'s callee is
read first, and a no-call `.op` is a field read only with evidence: its chain's type resolves by scope to a struct or
union that declares op as a field, or the chain is one name for a struct this file declares that binds op as a
variable or constant. Any other on a name chain is an unclassified acquisition keyed `<chain>.<op> (no call)`, which
the gate fails unless the allow-list names it with a count (as a called @field whose name is no literal, the user's
r31 decision); one on an expression is refused (UNREADABLE-RECEIVER).
r34 (round 33's Opus M1, Sol M1, L3 and the lead's direction): the last line-based readers, res_index, structs(),
functions() and block_end, counted braces one cleaned line at a time, so a `(` did not change the depth and each line
of a method's multi-line parameter list was recorded as a member of its struct, overwriting a field's type (at
31796f5d0, 2,605 such lines in 359 structs). They read the token stream now, once a file (file_structure: zigtok's
functions_of_tokens, containers_of_tokens, container_members), depth counted over parentheses, brackets and braces
alike. Evidence is explicit only: a `var` is evidence only through its explicit type, never its initializer, which a
reassignment may override (Sol M1: `var T = Decoy; T = @TypeOf(...); ... T.lock`); an inferred type comes only from
an immutable `const`. An unclassified lock op used as a value is keyed with its root's declared type,
`<chain>.<op> (no call; <root>: <type>)`, so a row allowing it no longer holds once that type changes (Opus L3).

thread_gate.py takes its sites from this tool's <out-prefix>-sites.tsv (kinds renderer-state, demand, relock,
handoff-internal), so there is one recogniser. Exit 1 when any non-test site of any revision is UNREVIEWED.

Sites: `<alias>.lock(` / `.lockUncancelable(` / `.tryLock(` on the renderer-state mutex and `<handle>.lockDemand(`
(acquisitions); `<handle>.yieldToDemand(` (yields); relocks (lock calls on a mutex parameter the pointer is handed to:
the mailbox's `send`); handoff-internal (inside renderer/State.zig: upstream's own `self.mutex.lock(` in
lockDemand, and the wrapper's demand acquire `self.mutex.demand(` that the 1A.2 forwarder makes, AC2). Aliases: handles typed `*renderer.State`; a value
mutex assigned into a state (`renderer_state.mutex = &renderer_mutex;`); struct-literal flow by field set, transitively
(this is how a test-only struct such as stream_handler's `Feed` becomes a carrier); call-argument flow; untyped and
typed locals bound from an alias (`const m = self.renderer_state.mutex;`). Every lock call on a receiver declared with
a mutex type that is none of these is UNCLASSIFIED; a value mutex declared in the file is "distinct".
Carriers (X3): declared types (struct fields and parameters), production allocation and free, and every literal or
assignment that sets `.mutex` from a renderer mutex, inline literals included (`.init(alloc, .{ .terminal = &t,
.mutex = &mutex })`); deduplicated by (file, name or line).
Threads: from the reviewed table (thread_gate.py schema: file, function | *[f,...], fingerprint, threads, scope,
reason, chain), using the rows whose scope matches the revision's: `fork` (the fork head); `1a` (the merged 1A
trees: fork rows plus `merged` rows); `1b` (the merged 1B trees: fork, `merged` and `merged-1b` rows); `upstream`
(the stone, v1.4.0). A site in a function with no row
is UNREVIEWED, relocks included. Mutex types: any `\w*Mutex` with a module prefix (`std.Thread.Mutex`,
`renderer.StateMutex`); a receiver typed `StateMutex` is the renderer-state mutex. A struct-flow alias is keyed to
its struct (`self.F` inside it, names typed with it); a value mutex assigned into a state is keyed by its declaration
(a bare local inside the assigning function, a field as a field access). Test code (a test block, and any fn nested in one) is "test".
Site rows: rev, file, line, function, operation, kind, threads (or "test"), text, INLINE, TEST.
INLINE (M-b): `inline-fn` (the owning function is declared `inline fn`), `always-inline@<file:line>,...` (the owning
function is the target of a literal `@call(.always_inline, ...)`), or `-`. TEST (M-f; r25): for a site in test code,
the outermost test block's kind and identity, `named:<exact decoded name>`, `no-key:<reason>`, `decltest:<ident>`,
`unnamed`, or `test-code` (in test code but in no test block); `-` elsewhere. Only `named:` is keyed.
Writes <out-prefix>-sites.tsv, -unclassified.tsv (r30: each row adds its receiver, the allow-list's third key),
-carriers.tsv; prints a summary line per revision.
"""
import bisect
import bisect
import collections
import functools
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

_argv = sys.argv[1:]
OVERLAY = None
if "--overlay" in _argv:   # files under DIR replace the revision's copies (negative controls; nothing is written)
    _k = _argv.index("--overlay")
    OVERLAY = _argv[_k + 1]
    _argv = _argv[:_k] + _argv[_k + 2:]
repo, out, table_path = _argv[0], _argv[1], _argv[2]
revs, SCOPE = [], {}
for _a in _argv[3:]:
    _r, _, _s = _a.partition("=")
    revs.append(_r)
    SCOPE[_r] = _s or "fork"
LOOKUP = {"fork": ("fork",), "1a": ("merged", "fork"), "1b": ("merged-1b", "merged", "fork"), "upstream": ("upstream",)}
REVIEWED = {}
for _l in open(table_path, encoding="utf-8"):
    if _l.startswith("#") or not _l.strip():
        continue
    _f = _l.rstrip("\n").split("\t")
    while len(_f) < 7:
        _f.append("")
    _names = _f[1][2:-1].split(",") if _f[1].startswith("*[") else [_f[1]]
    for _sc in (("fork", "merged", "merged-1b", "upstream") if _f[4] == "all" else (_f[4],)):
        for _n in _names:
            REVIEWED[(_f[0], _n, _sc)] = _f[3]
OPS = r"(lock|lockUncancelable|tryLock|unlock)"
ACQ = {"lock", "lockUncancelable", "tryLock", "lockDemand", "lockShared", "tryLockShared", "lockSharedUncancelable",
       "@field"}   # r31: a called @field whose name is no literal, an acquisition whose op cannot be known
SKIP = re.compile(r"/gtk|macos|apprt/embedded\.zig")
KW = {"if", "while", "for", "switch", "return", "try", "catch", "orelse", "fn", "struct", "union", "enum",
      "const", "var", "pub", "and", "or", "defer", "errdefer", "comptime", "inline", "test", "break", "continue",
      "unreachable", "undefined", "null", "true", "false", "error", "anytype", "type", "void", "bool", "self"}


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True).stdout.decode("utf-8", "replace")


def zig_unescape(s):
    """r23 (round 22's AL2): a Zig string literal's BYTES as the compiler reads them: a literal character as its UTF-8
    bytes, \\xNN as one byte, \\u{N} as the code point's UTF-8, \\n \\r \\t \\\\ \\' \\" as their byte. AstGen's
    test-name map and std.debug see these bytes, so `test "a\\xc3\\xa9"`, `test "a\\u{e9}"` and `test "aé"` are one
    name (r22 decoded \\xNN to a code point, which split them: round 22's AL2)."""
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


def no_key_reason(s):
    """r23, r24: why a string test name gives no key, or None when it gives one: its decoded bytes are not UTF-8, or
    they hold a control character (below 0x20, or DEL), which would split the sites row (TAB) or a dump line (LF).
    Neither a reviewed table row nor a dump line can spell such a name."""
    try:
        n = zig_unescape(s).decode("utf-8")
    except UnicodeDecodeError:
        return "not UTF-8"
    return "with a control character" if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in n) else None


PLAIN_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# r28 (round 27's Opus M1): Zig's keywords and primitives, read from lib/std/zig/tokenizer.zig (`keywords`) and
# lib/std/zig/primitives.zig (`names`, and isPrimitive's i<digits>/u<digits>), identical in 0.15.2 and 0.17.1. Neither
# is a plain identifier: a declaration needs `@"..."` for both.
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


def quoted_ident(spelled):
    """r26 (round 25's M1): the identifier `@"<spelled>"` names, when its decoded bytes are a plain identifier; else
    None. Zig gives `@"same"` and `same` one identity (std.debug's bytes; ast-check's duplicate member name). r28
    (round 27's Opus M1): a keyword or a primitive is no plain identifier (`fn defer` and `fn type` do not compile), so
    `@"defer"` and `@"type"` give None and become tokens."""
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


CALLEE = re.compile(r"(?:\.|\b)(\w+)\s*\(")


def callee_name(c):
    """r28 (round 27's Opus M1): a callee read from the normalized text, keyed as functions() keys a declaration: a
    token or a plain name as itself, and a primitive (`X.type(`: after a dot Zig and zig fmt write it plain) as the
    token of the quoted name its declaration must use, `@"type"`."""
    return tok(c) if is_primitive(c) else c


# r29 (round 28's Sol M1, Opus M1 and the lead's note): every lock-op token on a code line is read, and each is either
# classified or fails the run explicitly (r28 listed two failing shapes, RECV_EXPR, and let every other receiver its
# site regex could not match pass unseen). The ops: std's Mutex and RwLock acquisitions on 0.15.2 and 0.17.1, and the
# wrapper's. None of the newly read shapes occurs in any of the seven trees (logs-r29\sweep-receivers.txt).
ACQ_OPS = ("lockSharedUncancelable", "tryLockShared", "lockShared", "lockUncancelable", "tryLock", "lockDemand",
           "yieldToDemand", "demand", "lock")
SHARED_OPS = frozenset(("lockSharedUncancelable", "tryLockShared", "lockShared"))
ACQ_SET = frozenset(ACQ_OPS)


def chain_back(toks, j):
    """r32: the receiver whose last token is toks[j], read back through the code tokens: ("none", None) when toks[j]
    is no operand, so the `.op` after it is a literal's field or an enum literal (a keyword, an operator, the `)` of
    an if, while or for condition, or the file's start before the dot); ("chain", names) for a word chain, through
    `.*` and `.?`, that no other operand continues; ("expr", None) for any other receiver (`f().x`, `xs[0]`, `(x)`, a
    literal), which the tools cannot name."""
    if j < 0:
        return "none", None
    t = toks[j]
    if t.kind == "keyword" or (t.kind == "op" and t.text not in (")", "]", "}", ".*", "?")):
        return "none", None
    if zigtok.is_op(t, ")"):
        o = zigtok.match_back(toks, j)
        if o is not None and o >= 1 and toks[o - 1].kind == "keyword" and toks[o - 1].text in ("if", "while", "for"):
            return "none", None
    parts = []
    while j >= 0:
        t = toks[j]
        if zigtok.is_op(t, ".*"):
            j -= 1
            continue
        if zigtok.is_op(t, "?") and j >= 1 and zigtok.is_op(toks[j - 1], "."):
            j -= 2
            continue
        if t.kind == "identifier":
            parts.insert(0, t.text)
            if j >= 1 and zigtok.is_op(toks[j - 1], "."):
                j -= 2
                continue
            return "chain", parts
        return "expr", None
    return "expr", None


def chain_toks(run):
    """(receiver, last name) when an argument's tokens are one word chain, `&` allowed before it, through `.*` and
    `.?`; else None (r29's chain_of, read from tokens)."""
    k = 1 if run and zigtok.is_op(run[0], "&") else 0
    if k >= len(run) or run[k].kind != "identifier":
        return None
    parts, k = [run[k].text], k + 1
    while k < len(run):
        if zigtok.is_op(run[k], ".*"):
            k += 1
        elif zigtok.is_op(run[k], ".") and k + 1 < len(run) and zigtok.is_op(run[k + 1], "?"):
            k += 2
        elif zigtok.is_op(run[k], ".") and k + 1 < len(run) and run[k + 1].kind == "identifier":
            parts.append(run[k + 1].text)
            k += 2
        else:
            return None
    return ".".join(parts), parts[-1]


def type_name(ty):
    """A declared type's last name, its first qualifier, and whether it is a pointer: `*std.Thread.Mutex` ->
    ("Mutex", "std", True), `Mailbox.Queue` -> ("Queue", "Mailbox", False), `BlockingQueue(T, 4)` ->
    ("BlockingQueue", None, False), `*@This()` -> ("This", None, True)."""
    s = (ty or "").strip()
    ptr = bool(re.match(r"^\??\s*(?:\[\*\]|\*)", s))
    s = re.sub(r"^[?*\s]*(?:\[\*\])?\s*(?:const\s+)?", "", s).split("(")[0].strip()
    m = re.search(r"([A-Za-z_]\w*)\s*$", s)
    qual = s.split(".")[0] if "." in s else None
    return (m.group(1) if m else None), qual, ptr


def _strip_type_groups(toks):
    """A return type's tokens without its callconv(...), align(...), linksection(...) and addrspace(...) groups."""
    out, r = [], 0
    while r < len(toks):
        y = toks[r]
        if y.kind == "keyword" and y.text in ("callconv", "align", "linksection", "addrspace") and r + 1 < len(toks) \
                and zigtok.is_op(toks[r + 1], "("):
            r = zigtok.match_paren(toks, r + 1) + 1
            continue
        out.append(y)
        r += 1
    return out


def file_structure(text, stem):
    """r34, r35 (round 34's Opus M1 and the lead's direction): one file's structure, read from its code tokens once,
    every position a TOKEN INDEX into zigtok.split_lines_tokens(text) (the resolver's own token list of the same text):
    (res_index's (scopes, aliases, returns), structs()'s list, functions()'s (defs, def_toks, owner_tok)).
    scopes: [(name, members, open, close, kind, head)] for every struct, union, enum and opaque body
    (containers_of_tokens: named by the declaration it initializes, the type function returning it, or an if's other
    branch; open and close its braces; head its declaration's `const` or `var` token, or None) and the file scope
    (stem, open -1, close len(toks), kind "file"); members map each field (a struct's or a union's: an enum's or an
    opaque's values are no fields) and each explicitly typed container `const`/`var` at its own level to its type,
    the later in the source winning. aliases: [(token, name, rhs)] for `const NAME = a.b.c;` or `const NAME =
    F(args);`, and for `const NAME = switch (builtin.os.tag) {...}` its `.windows` prong. returns: [(start token,
    name, return type)] for each function with a body. structs: [(name, fields, field types, open, close)] for every
    struct body a declaration names, and the file scope's fields (-1, len(toks)). defs: [(name, first line, last line,
    is_winapi, is_test, is_inline)] for every function declaration and test block, in source order; def_toks the
    same list's (start token, end token, functions_of_tokens' dict); owner_tok[q] the innermost def holding token q
    (a def inside a test block is test code). r34 named every container but kept only struct and union bodies as
    scopes, and filed declarations and owners by line."""
    toks, nlines = zigtok.split_lines_tokens(text)
    n = len(toks)
    fns = zigtok.functions_of_tokens(toks)
    conts = zigtok.containers_of_tokens(toks, fns)
    scopes, structs_, returns, aliases = [], [], [], []

    def merged(fields, decls):
        items = [(k, v) for k, v in list(fields.items()) + list(decls.items()) if k not in KW]
        return {k: v[0] for k, v in sorted(items, key=lambda kv: kv[1][1])}

    for c in conts:
        fields, decls = zigtok.container_members(toks, c["open"] + 1, c["close"])
        if c["kind"] in ("enum", "opaque"):   # r35: an enum's or an opaque's values are no fields
            fields = {}
        head = c["head"] if c["naming"] == "declaration" else None
        scopes.append((c["name"], merged(fields, decls), c["open"], c["close"], c["kind"], head))
        if c["kind"] == "struct" and c["naming"] == "declaration":
            ff = {k: v[0] for k, v in fields.items() if k not in KW}
            structs_.append((c["name"], set(ff), ff, c["open"], c["close"]))
    tf, td = zigtok.container_members(toks, 0, n)
    scopes.append((stem, merged(tf, td), -1, n, "file", None))
    structs_.append((stem, {k for k in tf if k not in KW}, {k: v[0] for k, v in tf.items() if k not in KW}, -1, n))
    for q in range(n):
        if not (zigtok.declaration_at(toks, q) and toks[q].text == "const" and q + 2 < n and zigtok.is_op(toks[q + 2], "=")):
            continue
        name, r = toks[q + 1].text, q + 3
        if r < n and toks[r].kind == "keyword" and toks[r].text == "switch" and r + 7 < n \
                and zigtok.spaced(toks[r + 1:r + 8]) == "(builtin.os.tag)" and zigtok.is_op(toks[r + 8], "{"):
            close = zigtok.match_paren(toks, r + 8)
            d, e = 0, r + 9
            while e < close:
                y = toks[e]
                if zigtok.is_op(y, "(", "[", "{"):
                    d += 1
                elif zigtok.is_op(y, ")", "]", "}"):
                    d -= 1
                elif d == 0 and zigtok.is_op(y, ".") and e + 2 < close and toks[e + 1].text == "windows" \
                        and zigtok.is_op(toks[e + 2], "=>"):
                    g = e + 3
                    while g + 1 < close and toks[g].kind == "identifier" and zigtok.is_op(toks[g + 1], "."):
                        g += 2
                    if toks[g].kind == "identifier" and zigtok.is_op(toks[g + 1], ","):
                        aliases.append((e, name, zigtok.spaced(toks[e + 3:g + 1])))
                    break
                e += 1
            continue
        if r + 1 < n and toks[r].kind == "number" and zigtok.is_op(toks[r + 1], ";"):
            aliases.append((q, name, toks[r].text))
            continue
        if not (r < n and toks[r].kind == "identifier"):
            continue
        g = r
        while g + 2 < n and zigtok.is_op(toks[g + 1], ".") and toks[g + 2].kind == "identifier":
            g += 2
        end = g + 1
        if end < n and zigtok.is_op(toks[end], "("):
            pc = zigtok.match_paren(toks, end)
            if any(zigtok.is_op(y, "(") for y in toks[end + 1:pc]):
                continue
            end = pc + 1
        if end < n and zigtok.is_op(toks[end], ";"):
            aliases.append((q, name, zigtok.spaced(toks[r:end], blank=True)))
    defs, def_toks = [], []
    for f_ in sorted(fns, key=lambda d_: d_["start"]):
        if f_["kind"] == "fn":
            ret = toks[f_["ret"][0]:f_["ret"][1]]
            winapi = any(y.kind == "keyword" and y.text == "callconv" and zigtok.spaced(ret[k_:k_ + 5]) == "callconv(.winapi)"
                         for k_, y in enumerate(ret))
            defs.append([f_["name"], toks[f_["start"]].line, toks[f_["end"]].line, winapi, False, "inline" in f_["quals"]])
            if f_["body"] is not None:
                rt = _strip_type_groups(ret)
                if rt and zigtok.is_op(rt[0], "!"):   # an inferred error set: r33 dropped the leading `!` alike
                    rt = rt[1:]
                returns.append((f_["start"], f_["name"], zigtok.spaced(rt, blank=True)))
        else:
            defs.append(["(test)", toks[f_["start"]].line, toks[f_["end"]].line, False, True, False])
        def_toks.append((f_["start"], f_["end"], f_))
    owner_tok = [None] * n
    for k, (a, b, _) in enumerate(def_toks):   # source order: a nested def paints over the def around it
        lo, hi = max(a, 0), min(b, n - 1)
        if lo > hi:
            continue
        outer = owner_tok[lo]
        if outer is not None and defs[outer][4]:
            defs[k][4] = True   # a function inside a test block is test code
        owner_tok[lo:hi + 1] = [k] * (hi - lo + 1)
    return (scopes, aliases, returns), structs_, ([tuple(d) for d in defs], def_toks, owner_tok)


def res_index(text, stem):
    """r29 to r35: (scopes, aliases, returns) of one file, for the resolver; read from the token stream from r34
    (file_structure), its positions token indexes from r35."""
    return file_structure(text, stem)[0]


class Resolver:
    """r29 (round 28's Opus M1): whether a receiver names a value mutex by its declarations, so that "distinct" holds
    only then (r28 called any receiver whose last name was a value mutex's anywhere in the file distinct). It follows
    the receiver's base to its declaration (a parameter; a local, typed, cast with `@as`, initialised from a literal,
    from a type's function, from `allocator.create(T)` or from a function's return type; a switch prong's capture of
    a union payload; a container declaration; a type used as a namespace), then each field to its declared type, read
    in the file that declares it, through type aliases, a Windows OS switch and the structs generic type functions
    return; it holds when the last type is a mutex that is no pointer. A receiver it cannot follow is not distinct.
    r35 (round 34's Opus M1, M2 and the lead's direction): every position is a token index into the file's code
    tokens, every owner lookup reads one span tree built from the token ranges containers_of_tokens and
    functions_of_tokens return (every struct, union, enum and opaque body, every function and test block, the file
    scope), and a switch prong's capture finds its switch by token nesting; r34 filed spans, declarations and
    captures by line, kept no enum or opaque body as a scope, and walked cleaned lines back to the nearest switch."""

    def __init__(self, idx, mtypes_of, explicit_of=lambda f_: set(), ns_of=lambda f_: {}):
        self.idx, self.mtypes_of, self.explicit_of, self.ns_of = idx, mtypes_of, explicit_of, ns_of
        self.texts, self._cache = {}, {}   # r31: set by the run; per-file caches of the scope model

    def stem(self, f):
        return f.rsplit("/", 1)[-1][:-4]

    def _toks(self, f):
        """r32: the file's code tokens (zigtok.split_lines_tokens of its normalized text, the list file_structure
        reads, so its token indexes are the resolver's positions), built once."""
        tk = self._cache.setdefault("toks", {}).get(f)
        if tk is None:
            tk = self._cache["toks"][f] = zigtok.split_lines_tokens(self.texts.get(f, ""))[0]
        return tk

    def forget(self, f):
        """r32: drop one file's caches once its sites are read (the resolver reads no other file's)."""
        for c in self._cache.values():
            c.pop(f, None)

    def _scopes(self, f):
        return self.idx.get(f, ([], [], []))[0]

    def _tree(self, f):
        """r35: one file's lexical structure by token range, built once: its spans, (kind, name, first token, last
        token), every container body ("struct", for a struct, union, enum or opaque body: its braces) and the file
        scope (-1, len(toks)), and every function and test block ("fn", from its first qualifier to its body's closing
        brace or its `;`: a function's signature is the function's); each token's innermost span (a container's own
        declaration tokens, before its `{`, belong to the span it is declared in); each span's parent; and each
        function span's functions_of_tokens record."""
        t = self._cache.setdefault("tree", {}).get(f)
        if t is not None:
            return t
        toks = self._toks(f)
        n = len(toks)
        spans = [("struct", s[0], s[2], s[3]) for s in self._scopes(f)]
        fninfo = {}
        for d in zigtok.functions_of_tokens(toks):
            fninfo[len(spans)] = d
            spans.append(("fn", d["name"] if d["kind"] == "fn" else "(test)", d["start"], d["end"]))
        order = sorted(range(len(spans)), key=lambda j: (-(spans[j][3] - spans[j][2]), spans[j][0] == "fn"))
        owners, parent = [None] * n, {}
        for j in order:   # larger spans first, so a span's parent is whatever holds its first token when its turn comes
            kind, _, a, b = spans[j]
            lo, hi = max(a, 0), min(b, n - 1)
            parent[j] = owners[a] if 0 <= a < n else None
            if lo <= hi:
                owners[lo:hi + 1] = [j] * (hi - lo + 1)
        index = {sp: j for j, sp in enumerate(spans)}
        t = self._cache["tree"][f] = (spans, owners, parent, fninfo, index)
        return t

    def _chain(self, f, q):
        """The spans holding token q, innermost first, the file scope last (q None or negative: the file scope)."""
        spans, owners, parent, _, _ = self._tree(f)
        if q is None or q < 0 or q >= len(owners):
            return [sp for sp in spans if sp[2] == -1][:1]
        out, j, seen = [], owners[q], set()
        while j is not None and j not in seen:
            seen.add(j)
            out.append(spans[j])
            j = parent.get(j)
        return out

    def _params(self, f, sp):
        """[(name, type text, comptime)] of a function span's parameter list, read from the file's code tokens; the
        type as the cleaned line spells it; a test block has none."""
        if sp[1] == "(test)":
            return []
        hit = self._cache.setdefault("params", {}).setdefault(f, {}).get(sp[2])
        if hit is not None:
            return hit
        spans, _, _, fninfo, index = self._tree(f)
        d, toks, out = fninfo.get(index.get(sp)), self._toks(f), []
        if d is not None and d["params"]:
            args, _ = zigtok.split_args(toks, d["params"][0])
            for a in args:
                ct = bool(a) and a[0].kind == "keyword" and a[0].text == "comptime"
                b = a[1:] if ct else a
                if b and b[0].kind == "keyword" and b[0].text == "noalias":
                    b = b[1:]
                if len(b) >= 3 and b[0].kind == "identifier" and zigtok.is_op(b[1], ":"):
                    out.append((b[0].text, zigtok.spaced(b[2:], blank=True), ct))
        self._cache["params"][f][sp[2]] = out
        return out

    @staticmethod
    def _switch_of(toks, p):
        """r35 (round 34's Opus M2): the switch a prong's capture list opened at toks[p] belongs to, by token nesting:
        from the `|` back to the innermost `{` no `}` closes, which must close `switch (...)`; its subject's name chain
        (["a", "b"] for `switch (a.b)`), or None (refused: the `{` closes no switch, or the subject is no name chain).
        r34 walked cleaned lines back to the nearest `switch (x)`, so a switch in an earlier prong won."""
        depth, r = 0, p - 1
        while r >= 0:
            if zigtok.is_op(toks[r], "}"):
                depth += 1
            elif zigtok.is_op(toks[r], "{"):
                if depth == 0:
                    break
                depth -= 1
            r -= 1
        if r < 1 or not zigtok.is_op(toks[r - 1], ")"):
            return None
        o = zigtok.match_back(toks, r - 1)
        if o is None or o < 1 or not (toks[o - 1].kind == "keyword" and toks[o - 1].text == "switch"):
            return None
        subj = toks[o + 1:r - 1]
        if not subj or subj[0].kind != "identifier" or len(subj) % 2 == 0:
            return None
        parts = [subj[0].text]
        for k_ in range(1, len(subj), 2):
            if not (zigtok.is_op(subj[k_], ".") and subj[k_ + 1].kind == "identifier"):
                return None
            parts.append(subj[k_ + 1].text)
        return parts

    @staticmethod
    def _capture_range(toks, close):
        """r35: the tokens a capture list closed at toks[close] is visible in: the block after it, or the expression or
        statement after it, to its `;`, `,`, `else` or the bracket that closes around it."""
        n, r = len(toks), close + 1
        if r < n and zigtok.is_op(toks[r], "{"):
            return (r, min(zigtok.match_paren(toks, r), n - 1))
        d = 0
        while r < n:
            x = toks[r]
            if zigtok.is_op(x, "(", "[", "{"):
                d += 1
            elif zigtok.is_op(x, ")", "]", "}"):
                if d == 0:
                    break
                d -= 1
            elif d == 0 and (zigtok.is_op(x, ";", ",") or (x.kind == "keyword" and x.text == "else")):
                break
            r += 1
        return (close + 1, r)

    def _index(self, f):
        """r31, r32, r35: per file, built once from its code tokens: for each span index, {name: [binding]} of the
        declarations directly in it, each filed under the innermost span holding its token (r35: by token range; r34
        by line, so a declaration in an enum or opaque body, or on a line a span opened on, counted for the span
        around it): every `const` or `var` that declares a name (zigtok.declaration_at), wherever it stands; in a
        function, every element of a destructuring declaration, as a binding whose form the resolver does not read;
        and every name of a capture list (zigtok.payload_at). A generic type function `fn Name(...) type` declared in
        a container counts there as a declaration of its struct. Each binding is (kind, token, type text or switch
        detail, initializer text): the type as the cleaned line spells it; the initializer from after `=` through its
        `;`, its first 64 tokens; a switch prong's capture of `.tag =>` as ("switch-capture", token, (tag, subject
        chain or None)); an `if (name) |x|` capture as ("capture", token, None, "if:" + name)."""
        ix = self._cache.setdefault("index", {}).get(f)
        if ix is not None:
            return ix
        spans, owners, parent, _, _ = self._tree(f)
        toks = self._toks(f)
        ix = collections.defaultdict(lambda: collections.defaultdict(list))
        n = len(toks)
        for q, tk in enumerate(toks):
            if zigtok.declaration_at(toks, q):
                j = owners[q]
                if j is None:
                    continue
                name, r, depth, ty_toks = toks[q + 1].text, q + 2, 0, []
                if r < n and zigtok.is_op(toks[r], ":"):
                    r += 1
                    while r < n:
                        x = toks[r]
                        if zigtok.is_op(x, "(", "[", "{"):
                            depth += 1
                        elif zigtok.is_op(x, ")", "]", "}"):
                            if depth == 0:
                                break
                            depth -= 1
                        elif depth == 0 and zigtok.is_op(x, "=", ";", ","):
                            break
                        ty_toks.append(x)
                        r += 1
                end = toks[r] if r < n else None
                prev = toks[q - 1] if q else None
                if spans[j][0] == "fn" and (zigtok.is_op(prev, ",") or zigtok.is_op(end, ",")):
                    ix[j][name].append(("destructure", q, None, ""))
                    continue
                init = ""
                if zigtok.is_op(end, "="):
                    e, d2 = r + 1, 0
                    while e < n and e - r <= 64:
                        x = toks[e]
                        if zigtok.is_op(x, "(", "[", "{"):
                            d2 += 1
                        elif zigtok.is_op(x, ")", "]", "}"):
                            d2 -= 1
                        elif d2 == 0 and zigtok.is_op(x, ";"):
                            break
                        e += 1
                    init = zigtok.spaced(toks[r + 1:min(e + 1, n)])
                ix[j][name].append(("var" if tk.text == "var" else "decl", q,   # r34: a var kept apart
                                    zigtok.spaced(ty_toks, blank=True) or None, init))
            elif zigtok.payload_at(toks, q):
                names, close = zigtok.payload_names(toks, q)
                tag, cond = None, ""
                if (len(names) == 1 and zigtok.is_op(toks[q - 1], "=>") and q >= 3 and toks[q - 2].kind == "identifier"
                        and zigtok.is_op(toks[q - 3], ".")):
                    tag = toks[q - 2].text
                if zigtok.is_op(toks[q - 1], ")"):
                    o = zigtok.match_back(toks, q - 1)
                    if (o is not None and o >= 1 and toks[o - 1].kind == "keyword" and toks[o - 1].text == "if"
                            and q - 1 - o == 2 and toks[o + 1].kind == "identifier" and close == q + 2):
                        cond = "if:" + toks[o + 1].text   # `if (name) |x|`: one name, one capture, no `*`
                rng = self._capture_range(toks, close)
                for nm in names:
                    j = owners[q]
                    if j is None or spans[j][0] != "fn":
                        continue
                    if tag:
                        ix[j][nm.text].append(("switch-capture", q, (tag, self._switch_of(toks, q)), ""))
                    else:
                        ix[j][nm.text].append(("capture", q, rng, cond))
        scopes = self._scopes(f)
        for j, sp in enumerate(spans):
            if sp[0] == "fn" and parent.get(j) is not None and spans[parent[j]][0] == "struct":
                inner = [s for s in scopes if s[0] == sp[1] and sp[2] < s[2] <= sp[3]]
                if inner:
                    ix[parent[j]][sp[1]].append(("typefn", sp[2], inner[0] if len(inner) == 1 else None, ""))
        self._cache["index"][f] = ix
        return ix

    def _span_index(self, f, sp):
        return self._tree(f)[4][sp]

    def _bindings(self, f, sp, name):
        """r31: every binding of `name` at a function's (or test block's) own level: its parameters, then its const and
        var declarations and its captures."""
        out = [("param", sp[2], t, "comptime" if ct else "") for n, t, ct in self._params(f, sp) if n == name]
        return out + list(self._index(f)[self._span_index(f, sp)].get(name, []))

    def _direct(self, f, sp, name):
        """Declarations of `name` directly in container span sp (a generic type function of that name included)."""
        return list(self._index(f)[self._span_index(f, sp)].get(name, []))

    def _fns_in(self, f, sp, name):
        """The functions of that name declared directly in container span sp."""
        spans, owners, parent, _, index = self._tree(f)
        j = index[sp]
        return [spans[q] for q in range(len(spans)) if spans[q][0] == "fn" and spans[q][1] == name and parent.get(q) == j]

    def _scope_of_span(self, f, sp):
        hits = [s for s in self._scopes(f) if s[2] == sp[2] and s[3] == sp[3]]
        return hits[0] if len(hits) == 1 else None

    def _this(self, f, q):
        """The container scope `@This()` names at token q: the innermost container holding it (r35: an enum's or an
        opaque's too)."""
        for sp in self._chain(f, q):
            if sp[0] == "struct":
                return self._scope_of_span(f, sp)
        return None

    def _struct_at(self, f, q):
        """The container scope the declaration whose `const`/`var` is toks[q] initializes."""
        hits = [s for s in self._scopes(f) if s[5] == q]
        return hits[0] if len(hits) == 1 else None

    def _scope_by_open(self, f, open_):
        hits = [s for s in self._scopes(f) if s[2] == open_]
        return hits[0] if len(hits) == 1 else None

    def _type_decl(self, name, f, i, depth=0):
        """r31 (round 30's Opus M1): the declaration a type name means where token i of f uses it, by scope, innermost
        first: a function's parameters and own bindings (a parameter of that name, `comptime name: type` included, is no
        type the tool can know: None), then each container's direct declarations; ("struct", scope) or ("alias", text,
        token), or None when the nearest scope that binds the name binds it twice, binds it with a form the tool does
        not read, or no scope binds it (r35: a container is a struct, union, enum or opaque)."""
        if depth > 6:
            return None
        for sp in self._chain(f, i):
            if sp[0] == "fn":
                if any(p[0] == name for p in self._params(f, sp)):
                    return None
                bs = [b for b in self._bindings(f, sp, name) if b[0] != "param"]
            else:
                bs = self._direct(f, sp, name)
            if not bs:
                continue
            if len(bs) > 1:
                return None
            kind, ln, ty, init = bs[0]
            if kind == "typefn":
                return ("struct", ty) if ty else None
            if kind != "decl" or ty:
                return None
            init = init.strip()
            if re.match(r"(?:extern\s+|packed\s+)?(?:struct|union|enum|opaque)\b", init):
                s = self._struct_at(f, ln)
                return ("struct", s) if s else None
            if re.match(r"@This\(\s*\)\s*;", init):   # the container the declaration is made in
                s = self._this(f, ln)
                return ("struct", s) if s else None
            if re.match(r"switch\s*\(\s*builtin\.os\.tag\s*\)", init):   # the fork builds for Windows only
                al = [(a_ln, rhs) for a_ln, nm, rhs in self.idx.get(f, ([], [], []))[1] if nm == name and a_ln > ln]
                return ("alias", al[0][1], al[0][0]) if al else None
            m = re.match(r"([\w.]+(?:\([^)]*\))?)\s*;", init)
            if m:
                return ("alias", m.group(1), ln)
            return None
        return None

    def field_read(self, parts, op, f, i):
        """r33 (round 32's Opus M1, Sol M1): whether `parts.op`, where token i of f uses it, reads a field, by evidence:
        the chain's type resolves by scope (chain_type) to a container this file declares, whose members list op and
        which declares no constant, variable or function of that name directly (so op is a field, not a declaration;
        r35: an enum's or an opaque's members are its declarations only)."""
        got = self.chain_type(list(parts), f, i, None, None, None)
        if got is None:
            return False
        mem = self.members(got[0], got[1], got[2])
        if mem is None or op not in mem[0]:
            return False
        box = self._scope_by_open(mem[1], mem[2])
        if box is None:
            return False
        sp = ("struct", box[0], box[2], box[3])
        if sp not in self._tree(mem[1])[4]:
            return False
        return not self._direct(mem[1], sp, op) and not self._fns_in(mem[1], sp, op)

    def container_var(self, name, op, f, i):
        """r32: whether `name.op`, where token i of f uses it, reads a variable or constant that a container this file
        declares (name's binding there, by scope) binds directly as op; a function of that name in it gives False."""
        d = self._type_decl(name, f, i)
        if not d or d[0] != "struct" or d[1] is None:
            return False
        s = d[1]
        sp = ("struct", s[0], s[2], s[3])
        if sp not in self._tree(f)[4]:
            return False
        ds = self._direct(f, sp, op)
        return len(ds) == 1 and ds[0][0] in ("decl", "var") and not self._fns_in(f, sp, op)

    def root_type(self, name, f, i):
        """r34 (round 33's Opus L3): the declared type of the binding `name` has where token i of f uses it (its
        parameter's or its const's or var's explicit type), by scope, or "?" when it has none the tool can read."""
        seen_fn = False
        for sp in self._chain(f, i):
            if sp[0] == "fn":
                if seen_fn:
                    continue
                seen_fn = True
                bs = self._bindings(f, sp, name)
            else:
                bs = self._direct(f, sp, name)
            if not bs:
                continue
            if len(bs) > 1:
                return "?"
            kind, _, ty, _ = bs[0]
            return ty.strip() if kind in ("param", "decl", "var") and ty else "?"
        return "?"

    def if_capture(self, name, f, i):
        """r35: the condition name of the `if (cond) |name|` capture that binds `name` where token i of f uses it, by
        scope (the innermost function's own bindings), or None; r34 read `if (cond) |name|` on the acquisition's line."""
        for sp in self._chain(f, i):
            if sp[0] == "fn":
                bs = [b for b in self._bindings(f, sp, name) if b[0] == "capture" and b[2] and b[2][0] <= i <= b[2][1]]
                if len(bs) == 1 and (bs[0][3] or "").startswith("if:"):
                    return bs[0][3][3:]
                return None
        return None

    def _binding_init(self, name, f, i):
        """r32 (round 31's Sol M1): (initializer, token) of the one binding of `name` that token i of f sees, by scope,
        when it is a const with no type; None when the nearest scope that binds the name binds it twice or otherwise,
        or none binds it."""
        for sp in self._chain(f, i):
            if sp[0] == "fn":
                if any(p[0] == name for p in self._params(f, sp)):
                    return None
                bs = [b for b in self._bindings(f, sp, name) if b[0] != "param"]
            else:
                bs = self._direct(f, sp, name)
            if not bs:
                continue
            if len(bs) > 1:
                return None
            kind, ln, ty, init = bs[0]
            return (init.strip(), ln) if kind == "decl" and not ty else None
        return None

    def members(self, ty, f, i, depth=0):
        """(members, file, its body's `{` token) of the container a type text names where token i of file f sees it,
        by scope (_type_decl), or None (r35: a position inside the body is its `{`, which the container's span holds)."""
        if ty is None or depth > 6:
            return None
        name, qual, _ = type_name(ty)
        if name is None:
            return None
        if name == "This" and re.search(r"@This\(\s*\)", ty):   # `@This()` itself: the innermost container
            s = self._this(f, i)
            return (s[1], f, s[2]) if s else None
        if qual and qual not in ("std", "builtin"):   # a qualified type: directly inside its qualifier's container, or nothing
            q = self.members(qual, f, i, depth + 1)
            if q is None or q[1] != f:
                return None
            box = self._scope_by_open(f, q[2])
            if box is None:
                return None
            got = self._direct(f, ("struct", box[0], box[2], box[3]), name)
            if len(got) != 1:
                return None
            kind, ln, t2, init = got[0]
            if kind == "typefn":
                return (t2[1], f, t2[2]) if t2 else None
            if t2:
                return None
            if re.match(r"\s*(?:extern\s+|packed\s+)?(?:struct|union|enum|opaque)\b", init or ""):
                s = self._struct_at(f, ln)
                return (s[1], f, s[2]) if s else None
            m = re.match(r"\s*([\w.]+(?:\([^)]*\))?)\s*;", init or "")
            return self.members(m.group(1), f, ln, depth + 1) if m else None
        if qual:
            return None   # a std or builtin type has no members the tool reads
        d = self._type_decl(name, f, i, depth)
        if d is None:
            return None
        if d[0] == "struct":
            return d[1][1], f, d[1][2]
        return self.members(d[1], f, d[2], depth + 1)

    def _ret_of(self, f, fn):
        rs = [rt for q, nm, rt in self.idx.get(f, ([], [], []))[2] if q == fn[2] and nm == fn[1]]
        return (rs[0].split("!")[-1].strip(), f, fn[2]) if len(rs) == 1 else None

    def returns(self, fname, f, i):
        """r31: the return type of the function an unqualified call `fname(...)` at token i reaches, by scope: a local
        or parameter of that name gives None; else the containers holding token i, innermost first, the first that
        declares a function of that name directly (one, or None)."""
        for sp in self._chain(f, i):
            if sp[0] == "fn":
                if [b for b in self._bindings(f, sp, fname)]:
                    return None
                continue
            fns = self._fns_in(f, sp, fname)
            if len(fns) > 1:
                return None
            if fns:
                return self._ret_of(f, fns[0])
        return None

    def fn_return(self, qtype, fname, f, i):
        """r30 (round 29's Sol M2), r31: the declared return type of function fname declared directly in the container
        qtype names (found by scope), else None."""
        mem = self.members(qtype, f, i)
        if mem is None:
            return None
        _, sf, first = mem
        box = self._scope_by_open(sf, first)
        if box is None:
            return None
        fns = self._fns_in(sf, ("struct", box[0], box[2], box[3]), fname)
        return self._ret_of(sf, fns[0]) if len(fns) == 1 else None

    def _init_type(self, init, base, f, ln, depth):
        """The type an initializer gives, for the forms the resolver reads; None for any other."""
        init = re.sub(r"^\s*try\s+", "", init or "").strip()
        if re.match(r"(?:extern\s+|packed\s+)?(?:struct|union|enum|opaque)\b", init):
            return base, f, ln   # a local type, used as a namespace
        m = re.match(r"@as\(\s*([^,]+?)\s*,", init)
        if m:
            return m.group(1), f, ln
        m = re.match(r"[a-z_][\w.]*\.create\(\s*([A-Z][\w.]*)\s*\)", init)
        if m:
            return "*" + m.group(1), f, ln
        m = re.match(r"&?\s*([\w.]+?(?:\([^)]*\))?)\s*(?:\{|\.\{)", init)
        if m and not re.match(r"\w+\s*:", init):
            return m.group(1), f, ln
        m = re.match(r"((?:\w+\.)*[A-Z]\w*)\.(\w+)\s*\(", init)
        if m:   # r30 (round 29's Sol M2): f's own declaration in Q and its return type, never Q itself
            return self.fn_return(m.group(1), m.group(2), f, ln)
        m = re.match(r"([a-z_]\w*)\s*\(", init)
        if m and m.group(1) not in KW:
            return self.returns(m.group(1), f, ln)
        m = re.match(r"(&\s*)?([A-Za-z_]\w*(?:\.\w+)*)\s*;", init)
        if m and m.group(2).split(".")[0] not in KW and m.group(2) != base:   # a field chain, or its address
            got = self.chain_type(m.group(2).split("."), f, ln, None, None, None, depth + 1)
            if got is None:
                return None
            return (("*" + got[0].strip()) if m.group(1) else got[0]), got[1], got[2]
        return None

    def declared(self, base, f, i, k, fs, clean, depth=0):
        """r31 (round 30's Opus M1, Sol M1): (type text, file, token) of the binding of `base` that token i of f sees,
        by lexical scope, or None. In the function holding token i a binding counts only as the unique binding of that
        name there (a parameter, a const or var, an |x| or |*x| capture); two give None, and so does one whose form the
        resolver cannot read (an if, while, for or catch capture; an initializer it does not follow). Only when the
        function binds no such name are the containers holding token i read, innermost first, each for a declaration
        directly in it (two in one give None). r35 (round 34's Opus M2): a switch prong's capture reads the switch its
        capture list belongs to by token nesting (_switch_of), and none when that is no switch on a name chain."""
        if depth > 6:
            return None
        seen_fn = False
        for sp in self._chain(f, i):
            if sp[0] == "fn":
                if seen_fn:
                    continue   # an enclosing function's runtime locals are not visible inside a nested container
                seen_fn = True
                bs = self._bindings(f, sp, base)
                if len(bs) > 1:
                    return None
                if not bs:
                    continue
                kind, ln, ty, init = bs[0]
                if kind == "param":
                    return None if (init == "comptime" and ty.strip() == "type") else (ty, f, ln)
                if kind == "decl":
                    return (ty, f, ln) if ty else self._init_type(init, base, f, ln, depth)
                if kind == "var":   # r34 (round 33's Sol M1): a var is evidence only through its explicit type
                    return (ty, f, ln) if ty else None
                if kind == "switch-capture":   # the switched value's union, then the prong's payload
                    tag, subject = ty
                    if not subject:
                        return None   # r35: the capture's `{` closes no switch on a name chain: refused
                    got = self.chain_type(subject, f, ln, k, fs, clean, depth + 1)
                    mem = self.members(got[0], got[1], got[2]) if got else None
                    return (mem[0][tag], mem[1], mem[2]) if mem and tag in mem[0] else None
                return None   # an if, while, for or catch capture: a binding form the resolver does not read
            ds = self._direct(f, sp, base)
            if len(ds) > 1:
                return None
            if ds:
                kind, ln, ty, init = ds[0]
                if kind == "typefn":
                    return None
                if kind == "var":   # r34: a container var too, only through its explicit type
                    return (ty, f, ln) if ty else None
                return (ty, f, ln) if ty else self._init_type(init, base, f, ln, depth)
        return None

    def chain_type(self, parts, f, i, k, fs, clean, depth=0):
        """(type text, file, token) at the end of a receiver chain, each member read where its container is declared
        (r35: at its body's `{`)."""
        got = self.declared(parts[0], f, i, k, fs, clean, depth)   # r30: `self` too only by its declaration
        for p in parts[1:]:
            if got is None:
                return None
            mem = self.members(got[0], got[1], got[2])
            if mem is None or p not in mem[0]:
                return None
            got = (mem[0][p], mem[1], mem[2])
        return got

    def value_mutex(self, recv, f, i, k, fs, clean):
        """r30: a value std mutex by a declaration chain (std.Thread.Mutex, std.Io.Mutex, or the declaring file's own
        alias of one); r29 accepted any type whose name ended in Mutex, and an alias of that name in any file."""
        got = self.chain_type(recv.split("."), f, i, k, fs, clean)
        return got is not None and self.is_std_mutex_value(got)

    def std_type(self, got, depth=0):
        """r30, r32 (round 31's Sol M1): a type text without a leading `const`, its leading namespace resolved by scope
        where the text is read (got's file and token): `std` only when the binding the name has there is
        `@import("std")`, another name through its binding there when that is an alias of a std path or of the
        import, aliases of aliases too; a std type comes out spelled `@import("std").<path>`. `std` bound otherwise
        (shadowed, twice in the nearest scope, or by a form the resolver does not read) gives "(unknown)"."""
        ty = re.sub(r"^\s*(?:const\s+)?", "", got[0].strip())
        m = re.match(r"([A-Za-z_]\w*)\.(.+)$", ty)
        if not m or depth > 8:
            return ty
        head, rest = m.group(1), m.group(2)
        b = self._binding_init(head, got[1], got[2])
        if b is None:
            return "(unknown)" if head == "std" else ty
        init, ln = b
        if re.fullmatch(r'@import\(\s*"std"\s*\)\s*;', init):
            return '@import("std").' + rest
        im = re.fullmatch(r'@import\(\s*"std"\s*\)((?:\.\w+)+)\s*;', init)
        if im:
            return '@import("std")' + im.group(1) + "." + rest
        pm = re.fullmatch(r"([A-Za-z_]\w*(?:\.\w+)*)\s*;", init)
        if pm:
            return self.std_type((pm.group(1) + "." + rest, got[1], ln), depth + 1)
        return "(unknown)" if head == "std" else ty

    def is_std_mutex_value(self, got, depth=0):
        """r31: std.Thread.Mutex or std.Io.Mutex, or a bare name whose declaration where it is used (by scope) is an
        alias of one; r30 took any alias of that name the file declared, wherever."""
        ty = self.std_type(got)
        if not ty or ty[0] in "*?[" or depth > 6:
            return False
        if STD_MUTEX.fullmatch(ty):
            return True
        if re.fullmatch(r"\w+", ty):
            d = self._type_decl(ty, got[1], got[2])
            return bool(d and d[0] == "alias" and self.is_std_mutex_value((d[1], got[1], d[2]), depth + 1))
        return False

    def other_lock(self, recv, f, i, k, fs, clean):
        """r30 (round 29's Opus M1, the lead's direction): whether a receiver no rule placed is another lock by evidence:
        it resolves, by its declarations, to an RwLock (its exclusive lock), a std file (a file lock), or a value std
        mutex this file does not name. r29 called every such receiver "other" unchecked. r35: the evidence is also
        returned (other_type), for the independent check of "other" rows."""
        return self.other_type(recv, f, i, k, fs, clean) is not None

    def other_type(self, recv, f, i, k, fs, clean):
        """r35 (round 34's Opus M2): the std type an "other" receiver resolves to, or None."""
        got = self.chain_type(recv.split("."), f, i, k, fs, clean)
        if got is None:
            return None
        ty = self.std_type(got)
        if not ty or ty[0] in "*?[":
            return None
        if OTHER_LOCK.fullmatch(ty) is not None or self.is_std_mutex_value(got):
            return ty
        return None


STD_MUTEX = re.compile(r"(?:std|@import\(\s*\"std\"\s*\))\.(?:Thread|Io)\.Mutex")
OTHER_LOCK = re.compile(r"(?:std|@import\(\s*\"std\"\s*\))\.(?:(?:Thread|Io)\.RwLock|fs\.File|Io\.File)")




STDP = r"(?:std|@import\(\s*\"std\"\s*\))"   # r30 (round 29's Opus M1): std named by its import too


# ---- r35 (round 34's Opus L3 and the lead's direction): the name sets and flow passes, read from the code tokens.
# r34 read them with regular expressions over cleaned lines (and its alias pass over the raw text, comments and
# strings included), so a declaration over two lines, a capture on another line than its lock, a call two
# statements back or a literal's context eight lines away changed what they found.

def tok_starts(toks):
    return [x.start for x in toks]


def token_at(toks, starts, off):
    """The code token holding text offset off, or None (whitespace, a comment)."""
    j = bisect.bisect_right(starts, off) - 1
    if j < 0:
        return None
    return j if toks[j].start <= off < toks[j].start + len(toks[j].text) else None


def token_ending(toks, starts, end):
    """The code token ending at text offset end, or None."""
    j = bisect.bisect_right(starts, end - 1) - 1
    return j if j >= 0 and toks[j].start + len(toks[j].text) == end else None


def type_run(toks, r):
    """The tokens of a type after a `:` at toks[r - 1], to the first `,`, `=`, `;` or `)` at its own depth."""
    out, d, n = [], 0, len(toks)
    while r < n:
        x = toks[r]
        if zigtok.is_op(x, "(", "[", "{"):
            d += 1
        elif zigtok.is_op(x, ")", "]", "}"):
            if d == 0:
                break
            d -= 1
        elif d == 0 and zigtok.is_op(x, ",", "=", ";"):
            break
        out.append(x)
        r += 1
    return out


def named_types(toks):
    """[(name token index, name, type text)] for every `name: TYPE` in the tokens (a field, a parameter, a typed
    declaration, a struct literal's typed field), the type as the cleaned line spells it."""
    out = []
    for q in range(len(toks) - 1):
        x = toks[q]
        if x.kind == "identifier" and zigtok.is_op(toks[q + 1], ":") and not (q and zigtok.is_op(toks[q - 1], ".")):
            out.append((q, x.text, zigtok.spaced(type_run(toks, q + 2), blank=True)))
    return out


def decl_statements(toks):
    """[(const/var token, name, type text or None, initializer tokens (after `=`, to its `;`), end token)] of every
    declaration in the tokens."""
    out, n = [], len(toks)
    for q in range(n):
        if not zigtok.declaration_at(toks, q):
            continue
        r = q + 2
        ty = None
        if r < n and zigtok.is_op(toks[r], ":"):
            tr = type_run(toks, r + 1)
            ty = zigtok.spaced(tr, blank=True)
            r = r + 1 + len(tr)
        init = []
        if r < n and zigtok.is_op(toks[r], "="):
            e, d = r + 1, 0
            while e < n:
                y = toks[e]
                if zigtok.is_op(y, "(", "[", "{"):
                    d += 1
                elif zigtok.is_op(y, ")", "]", "}"):
                    d -= 1
                    if d < 0:
                        break
                elif d == 0 and zigtok.is_op(y, ";"):
                    break
                e += 1
            init, r = toks[r + 1:e], e
        out.append((q, toks[q + 1].text, ty, init, r))
    return out


def alias_closure_toks(names, decls_):
    """r30, r35: the names plus every `const X = Y;` alias of one, any length, from the declarations."""
    names = set(names)
    pairs = [(nm, init[0].text) for q, nm, ty, init, e in decls_
             if ty is None and len(init) == 1 and init[0].kind == "identifier"]
    grew = True
    while grew:
        grew = False
        for a, b in pairs:
            if b in names and a not in names:
                names.add(a)
                grew = True
    return names


def std_mutex_aliases_toks(decls_):
    """r30, r35: the names a file declares for std.Thread.Mutex or std.Io.Mutex, aliases of aliases included."""
    base = {nm for q, nm, ty, init, e in decls_ if ty is None
            and re.fullmatch(STDP + r"\.(?:Thread|Io)\.Mutex", zigtok.spaced(init, blank=False).replace(" ", ""))}
    return alias_closure_toks(base, decls_)


def chain_at(toks, q):
    """(first, last) token indexes of the word chain `a.b.c` holding toks[q] (an identifier), or None."""
    if q is None or toks[q].kind != "identifier":
        return None
    a = q
    while a >= 2 and zigtok.is_op(toks[a - 1], ".") and toks[a - 2].kind == "identifier":
        a -= 2
    b = q
    while b + 2 < len(toks) and zigtok.is_op(toks[b + 1], ".") and toks[b + 2].kind == "identifier":
        b += 2
    return a, b


def chain_text(toks, a, b):
    return "".join(x.text for x in toks[a:b + 1])


def enclosing_call(toks, q):
    """The callee's last name of the innermost call whose argument list holds toks[q] (a builtin's or a keyword's
    parenthesis is skipped outward), read back by bracket nesting; None when the statement holding q is in no call
    (r34 took the last `name(` in the 400 characters before the line)."""
    pd, r = 0, q - 1
    while r >= 0:
        x = toks[r]
        if zigtok.is_op(x, ")"):
            pd += 1
        elif zigtok.is_op(x, "("):
            if pd == 0:
                p = toks[r - 1] if r else None
                if p is not None and p.kind == "identifier":
                    return callee_name(p.text)
            else:
                pd -= 1
        elif pd == 0 and zigtok.is_op(x, ";"):
            return None
        elif pd == 0 and zigtok.is_op(x, "{"):
            p = toks[r - 1] if r else None   # a literal's `{` (`.{`, `T{`, `[_]T{`) is inside the call; a block's is not
            if not (p is not None and (zigtok.is_op(p, ".", "]") or p.kind == "identifier")):
                return None
        r -= 1
    return None


def enclosing_brace(toks, q):
    """The innermost `{` no `}` closes before toks[q], or None."""
    d, r = 0, q - 1
    while r >= 0:
        if zigtok.is_op(toks[r], "}"):
            d += 1
        elif zigtok.is_op(toks[r], "{"):
            if d == 0:
                return r
            d -= 1
        r -= 1
    return None


def brace_field_names(toks, o):
    """r35: the `.name =` initializers at the own level of the braces opened at toks[o] (literal_fields, from tokens;
    r34 scanned characters, comments and strings included, and counted a `==` as a `=`)."""
    close = zigtok.match_paren(toks, o)
    names, d = set(), 0
    for r in range(o + 1, min(close, len(toks))):
        x = toks[r]
        if zigtok.is_op(x, "(", "{", "["):
            d += 1
        elif zigtok.is_op(x, ")", "}", "]"):
            d -= 1
        elif d == 0 and zigtok.is_op(x, ".") and r + 2 < close and toks[r + 1].kind == "identifier" \
                and zigtok.is_op(toks[r + 2], "="):
            names.add(toks[r + 1].text)
    return names


def statement_start(toks, o):
    """The first token of the statement or declaration whose tokens reach toks[o] (back to a `;`, `{` or `}` at its own
    level)."""
    d, r = 0, o - 1
    while r >= 0:
        x = toks[r]
        if zigtok.is_op(x, ")", "]"):
            d += 1
        elif zigtok.is_op(x, "(", "["):
            if d == 0:
                return r + 1
            d -= 1
        elif d == 0 and zigtok.is_op(x, ";", "{", "}"):
            return r + 1
        r -= 1
    return 0


def test_header_toks(toks, q):
    """r35: parse_test_header's result for the test block whose `test` keyword is toks[q], from its tokens (r34 read
    the block's first line, so a name on the next line was "unnamed")."""
    x = toks[q + 1] if q + 1 < len(toks) else None
    if x is not None and x.kind == "string":
        inner = x.text[1:-1]
        reason = no_key_reason(inner)
        return ("no-key", reason) if reason else ("named", zig_unescape(inner).decode("utf-8"))
    if x is not None and x.kind == "identifier":
        return ("decltest", x.text)
    return ("unnamed", None)


def literal_value(run):
    """r32: the text a name argument's tokens spell when they are one string literal (its escapes decoded) or one
    multi-line string literal (its lines joined); None for anything else (a name, `"lo" ++ "ck"`) or not UTF-8."""
    if len(run) == 1 and run[0].kind == "string":
        return zigtok.string_value(run[0])
    if run and all(x.kind == "mlstring" for x in run):
        return "\n".join(x.text[2:].rstrip("\r") for x in run)
    return None


def call_callees(toks):
    """r32: {start offset of the last token of each `@call`'s callee argument: (its first token's start, the call's
    argument runs)}, read structurally from the code tokens."""
    out = {}
    for q, x in enumerate(toks):
        if x.kind == "builtin" and x.text == "@call" and q + 1 < len(toks) and zigtok.is_op(toks[q + 1], "("):
            args, _ = zigtok.split_args(toks, q + 1)
            if len(args) >= 2 and args[1]:
                out[args[1][-1].start] = (args[1][0].start, args)
    return out


def field_refs_toks(toks, callees):
    r"""r31, r32 (round 31's Sol M2 and the lead's direction): every `@field(container, name)` reference in a file's
    code tokens, as (its line, 0-based; the name argument's text; whether it is called: the token after its closing
    parenthesis is `(`, whatever comments, whitespace or line breaks lie between, or it is the whole callee argument
    of a `@call`, read structurally; the container argument's text; the name its argument spells, literal_value, or
    None). r31 decided "called" from 39 characters after it with a whitespace-only pattern and @call's callee from
    the 80 before it, so a comment or enough whitespace hid the call (Sol M2)."""
    out = []
    for q, x in enumerate(toks):
        if x.kind == "builtin" and x.text == "@field" and q + 1 < len(toks) and zigtok.is_op(toks[q + 1], "("):
            args, end = zigtok.split_args(toks, q + 1)
            called = (end + 1 < len(toks) and zigtok.is_op(toks[end + 1], "(")) or (
                end < len(toks) and callees.get(toks[end].start, (None,))[0] == x.start)
            name_arg = args[1] if len(args) > 1 else []
            out.append((x.line, zigtok.spaced(name_arg), called, zigtok.spaced(args[0]) if args else "",
                        literal_value(name_arg), q))
    return out


NO_CALL = "(no call)"   # r33: the last-name marker of a lock op used as a value with no evidence it is a field read


def census_of(f, toks, tnames, resolver, callees, freads=None):
    """r32, r33 (round 31's Opus M2; round 32's Opus M1, Sol M1 and the lead's direction): every lock-op token of a
    file, read from its code tokens, so a comment, whitespace or a line break never splits one: an op name after a
    `.`, on the line the name stands on. Returns ({line: [(op, (receiver, last name) or None)]}, {line: [refusal]}):
    - a call (the next token is `(`): its receiver is the word chain before the dot (chain_back), or None (refused)
      for an expression or no receiver; a type-called op (`Mutex.lock(m)`, the chain's last name a type a lock op is
      called on) reads its first argument;
    - a field is no lock op: no receiver (`.lock = x`, `return .lock`, `.{ .lock = ... }`), or followed by `.`, `.*`
      or `=`;
    - `@call`'s callee (`@call(mod, T.op, .{m, ...})`), read before any field exemption (r33): its first tuple
      element when T's last name is such a type, else the chain, as for a call;
    - a field read, by evidence (r33): the chain's type resolves by scope to a struct or union that declares op as a
      field (Resolver.field_read), or the chain is one name for a struct this file declares that binds op as a
      variable or constant (Resolver.container_var);
    - any other `.op` with no call on a name chain is a lock op used as a value with no evidence: an unclassified
      acquisition keyed `<chain>.<op> (no call; <root>: <type>)` (r34: its root's declared type; its last name
      NO_CALL), which the gate fails unless the allow-list
      names it with a count; on an expression it is refused (UNREADABLE-RECEIVER).
    r29 to r31 read `.op(` per cleaned line and dropped a `.op` with no `(` unless its receiver's last name was a
    mutex type (round 31's Opus M2); r32 exempted a chain from a "runtime value", decided from the spelling of the
    root's type, before it read `@call`'s callee (round 32's Opus M1, Sol M1)."""
    acq, refused = collections.defaultdict(list), collections.defaultdict(list)
    n = len(toks)
    for q, x in enumerate(toks):
        if x.kind != "identifier" or x.text not in ACQ_SET or q < 1 or not zigtok.is_op(toks[q - 1], "."):
            continue
        op, nxt = x.text, (toks[q + 1] if q + 1 < n else None)
        kind_, parts = chain_back(toks, q - 2)
        if zigtok.is_op(nxt, "("):
            if kind_ != "chain":
                acq[x.line].append((op, None, q))
                continue
            rcv = (".".join(parts), parts[-1])
            if parts[-1] in tnames:   # `Mutex.lock(m)`: the mutex is its first argument
                args, _ = zigtok.split_args(toks, q + 1)
                rcv = chain_toks(args[0]) if args else None
            acq[x.line].append((op, rcv, q))
            continue
        if kind_ == "none" or zigtok.is_op(nxt, ".", ".*", "="):
            continue
        if kind_ == "chain" and x.start in callees:   # r33: @call's callee first, before any field exemption
            args = callees[x.start][1]
            rcv = (".".join(parts), parts[-1])
            if parts[-1] in tnames:   # the mutex is the first element of the argument tuple
                tup, rcv = (args[2] if len(args) > 2 else []), None
                if len(tup) >= 2 and zigtok.is_op(tup[0], ".") and zigtok.is_op(tup[1], "{"):
                    els, _ = zigtok.split_args(tup, 1)
                    rcv = chain_toks(els[0]) if els else None
            acq[x.line].append((op, rcv, q))
            continue
        if kind_ == "chain":   # r35: positions are tokens; each exemption is recorded for bindcheck35.py
            how_ = ("field" if resolver.field_read(parts, op, f, q)
                    else "container-var" if len(parts) == 1 and resolver.container_var(parts[0], op, f, q) else None)
            if how_:
                if freads is not None:
                    freads.append((f, x.line + 1, ".".join(parts), op, how_))
                continue
        if kind_ == "chain":   # r33: no evidence it is a field read: unclassified, keyed by its text
            key_ = (".".join(parts) + "." + op + " (no call; " + parts[0] + ": "
                    + resolver.root_type(parts[0], f, q) + ")")   # r34 (Opus L3): the root's declared type
            acq[x.line].append((op, (key_, NO_CALL), q))
            continue
        refused[x.line].append(f"UNREADABLE-RECEIVER {f}:{x.line + 1}: a lock op used as a value with no call "
                               f"(an expression's .{op}); call it on a named receiver")
    return acq, refused


NONLITERAL_CALLS = "unclassified"   # r31: what a called @field whose name is no literal does (make_inventory16.py)


def parse_test_header(line):
    """r24 (round 23's Sol M1 and Opus L1): a test block's first line as a tagged result, decided by the syntax alone
    and never by a decoded name's contents:
      ("named", <text>)      `test "<string>"`, decoded to UTF-8 text with no control character: keyed
                             `<file>:test:<text>` (UTF-8 decoding is one-to-one, so equal text is equal bytes)
      ("no-key", <reason>)   `test "<string>"` whose decoded bytes are not UTF-8 or hold a control character
      ("decltest", <ident>)  `test <ident>`, which std.debug calls `decltest.<ident>`
      ("unnamed", None)      `test {`, which std.debug calls `test_<N>` per container
    Only "named" has a key."""
    m = re.match(r'^\s*test\s+"((?:[^"\\]|\\.)*)"', line)
    if m:
        reason = no_key_reason(m.group(1))
        return ("no-key", reason) if reason else ("named", zig_unescape(m.group(1)).decode("utf-8"))
    m = re.match(r'^\s*test\s+@"((?:[^"\\]|\\.)*)"', line)
    if m:   # r25 (round 24's Muse L1): `test @"weird decl"` names a declaration, so it is a decltest too
        return ("decltest", canon_quoted(m.group(1)))
    m = re.match(r"^\s*test\s+(\w+)", line)
    return ("decltest", m.group(1)) if m else ("unnamed", None)


@functools.lru_cache(maxsize=1 << 18)
def sc(l):
    """r32: the line as the line passes read it, from its tokens (zigtok.clean_line): its comment removed, every
    string and char literal emptied, a multi-line string line dropped, a quoted name that is a plain identifier read
    as that identifier. r31's per-line cleaner gave the same on every line of the seven trees
    (r32-staging\\logs\\cleancmp32.txt, 0 of 4,873,475 lines differ); it read a `\\\\` line opened after code as code."""
    return zigtok.clean_line(l, quoted_ident)


def structs(text, stem="(file)"):
    """[(name, fields, field types, first line, last line)]; the file-level struct spans the whole file. r34: read from
    the token stream (file_structure)."""
    return file_structure(text, stem)[1]


def literal_fields(text, pos):
    depth, i = 0, pos
    while i > 0:
        ch = text[i]
        if ch == "}":
            depth += 1
        elif ch == "{":
            if depth == 0:
                break
            depth -= 1
        i -= 1
    start, depth, j = i, 0, i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    body, names, d = text[start + 1:j], set(), 0
    for k, ch in enumerate(body):
        if ch in "{(":
            d += 1
        elif ch in "})":
            d -= 1
        elif ch == "." and d == 0:
            m = re.match(r"\.(\w+)\s*=", body[k:])
            if m:
                names.add(m.group(1))
    return names


def functions(lines):
    """r34, r35: (defs, def_toks, owner_tok) of one file's lines (file_structure): positions are token indexes."""
    return file_structure("\n".join(lines), "(file)")[2]


def stem_names(path, text):
    stem = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    names = {stem}
    names |= set(re.findall(r"^\s*(?:pub\s+)?const\s+([A-Z]\w*)\s*=\s*(?:extern\s+|packed\s+)?(?:struct|union|enum|opaque)\b", text, re.M))
    return names


summary = {}
all_rows, all_unc, all_car, all_dist, all_other, all_fr = [], [], [], [], [], []
UNREADABLE = []   # r28 (round 27's lead note): spellings the normalizer cannot read; any fails the run (exit 2)
TOOL_ERRORS = []  # r29: a lock-op token that landed in no bucket; any fails the run (exit 3)
TOKENS = {}       # r29: per revision, every lock-op token by bucket
for rev in revs:
    files = [f for f in git("ls-tree", "-r", "--name-only", rev, "--", "src").splitlines()
             if f.endswith(".zig") and not SKIP.search(f)]
    if OVERLAY:
        import os
        for _root, _, _names in os.walk(OVERLAY):
            for _n in _names:
                _rel = os.path.relpath(os.path.join(_root, _n), OVERLAY).replace("\\", "/")
                if _rel.endswith(".zig") and _rel not in files:
                    files.append(_rel)
    texts, unreadable = {}, []
    for f in files:
        _op = os.path.join(OVERLAY, f) if OVERLAY else None
        try:   # r27, r28: the one normalizer, before any pass reads a name; a spelling it cannot read fails the run
            texts[f] = norm_quoted_idents(
                open(_op, encoding="utf-8").read() if _op and os.path.exists(_op) else git("show", f"{rev}:{f}"), f)
        except Unreadable as e_:
            unreadable.append(f"{e_} (at {rev})")
    if unreadable:
        UNREADABLE.extend(unreadable)
        continue
    lines_of = {f: t.splitlines() for f, t in texts.items()}
    stx = {f: file_structure(t, f.rsplit("/", 1)[-1][:-4]) for f, t in texts.items()}   # r34: one token pass a file
    decls = {f: stx[f][1] for f, t in texts.items() if "utex" in t}
    # r29: the resolver's own struct index, for "distinct" only
    ridx = {f: stx[f][0] for f in texts}
    mtypes_by_file = {}
    resolver = Resolver(ridx, lambda f_: mtypes_by_file.get(f_, {"Mutex"}))
    resolver.texts = texts
    # r35: the flow passes read the tokens of the files their names occur in, each tokenized once (ftoks)
    ftoks = {}

    def toks_of(f_):
        if f_ not in ftoks:
            tk_ = zigtok.split_lines_tokens(texts[f_])[0]
            ftoks[f_] = (tk_, tok_starts(tk_))
        return ftoks[f_]
    # ---- aliases (handles, struct flow, call flow)
    alias = collections.defaultdict(set)
    scoped = collections.defaultdict(set)   # (field, first token, last token): `self.<field>` inside a struct
    handles = collections.defaultdict(set)
    for f, t in texts.items():
        if not re.search(r"State\b|\bstate\b|\brenderer_state\b", t):
            continue
        tk, _ = toks_of(f)
        n_ = len(tk)
        for q_, nm_, ty_ in named_types(tk):   # `name: *State`, `name: *renderer.State`, `name: *rendererpkg.State`
            m = re.match(r"\*(?:const\s+)?((?:renderer(?:pkg)?|rendererpkg)\.)?State(?:\.|$)", ty_)
            if m and (m.group(1) or f.startswith("src/renderer/")):
                handles[f].add(nm_)
        for q_, nm_, ty_, init_, e_ in decl_statements(tk):
            # r29 (round 28's Opus M1): a handle bound by address (`const st = &...renderer_state;`), typed or not
            run_ = init_[1:] if init_ and zigtok.is_op(init_[0], "&") else init_
            ch_ = chain_at(run_, 0) if run_ else None
            if ch_ and ch_ == (0, len(run_) - 1) and ch_[1] >= 2 and run_[-1].text in ("renderer_state", "state") \
                    and (run_[-1].text == "renderer_state" or f.startswith("src/renderer/")):
                handles[f].add(nm_)
        if any(x.kind == "identifier" and x.text == "renderer_state" for x in tk):
            handles[f].add("renderer_state")
        for h in handles[f]:
            alias[f].add(r"\b" + h + r"\.mutex\b")
        # `renderer_state.mutex = &EXPR;` makes that value mutex a renderer mutex, keyed by its declaration (Opus L4):
        # a field (`self.renderer_mutex`) as a field access anywhere in the file; a bare local only inside the
        # function that assigns it (r35: its token range)
        _defs, _dtoks, _own = stx[f][2]
        for q_ in range(n_ - 4):
            if not (tk[q_].kind == "identifier" and tk[q_].text in handles[f] and zigtok.is_op(tk[q_ + 1], ".")
                    and tk[q_ + 2].text == "mutex" and zigtok.is_op(tk[q_ + 3], "=") and zigtok.is_op(tk[q_ + 4], "&")):
                continue
            ch_ = chain_at(tk, q_ + 5) if q_ + 5 < n_ else None
            if not ch_ or ch_[0] != q_ + 5 or not (ch_[1] + 1 < n_ and zigtok.is_op(tk[ch_[1] + 1], ";")):
                continue
            expr = chain_text(tk, *ch_)
            name = expr.split(".")[-1]
            if "." in expr:
                alias[f].add(r"&?\s*[\w.]*\." + re.escape(name) + r"\b")
            else:
                k_ = _own[q_] if q_ < len(_own) else None
                if k_ is not None:
                    scoped[f].add((re.escape(name), _dtoks[k_][0], _dtoks[k_][1]))
    carriers = []
    relock_fns, relock_calls = set(), set()   # r30: and (file, callee) where the mutex is passed
    changed, rounds = True, 0
    while changed and rounds < 6:
        changed, rounds = False, rounds + 1
        for f, t in texts.items():
            if not alias.get(f):
                continue
            src = "(?:" + "|".join(sorted(alias[f])) + ")"
            tk, st_ = toks_of(f)
            for m in re.finditer(src, t):
                # r35: a name found in the text is read from the code tokens: one in a comment or a string is none
                q0 = token_at(tk, st_, m.start() + (len(m.group(0)) - len(m.group(0).lstrip("& \t\r\n"))))
                q1 = token_ending(tk, st_, m.end())
                if q0 is None or q1 is None or q1 < q0:
                    continue
                if (q1 + 3 < len(tk) and zigtok.is_op(tk[q1 + 1], ".") and re.fullmatch(OPS, tk[q1 + 2].text)
                        and zigtok.is_op(tk[q1 + 3], "(")) or enclosing_call(tk, q0) == "destroy":
                    continue
                ch_ = chain_at(tk, q0) if tk[q0].kind == "identifier" else None
                vs = ch_[0] if ch_ else q0
                if vs >= 1 and zigtok.is_op(tk[vs - 1], "&"):
                    vs -= 1
                if vs >= 3 and zigtok.is_op(tk[vs - 1], "=") and tk[vs - 2].kind == "identifier" and zigtok.is_op(tk[vs - 3], "."):
                    fname_ = tk[vs - 2].text
                    o_ = enclosing_brace(tk, vs - 3)
                    names = brace_field_names(tk, o_) if o_ is not None else set()
                    for g, st in decls.items():
                        for sname, fields, types, s_first, s_last in st:
                            ty = types.get(fname_, "")
                            if names and fname_ in fields and names <= fields and re.search(r"\w*Mutex\b", ty) and "MutexState" not in ty:
                                # keyed to the struct (Grok L): `self.F` inside it, and names typed with it
                                key = (r"self\." + re.escape(fname_), s_first, s_last)
                                gk, _ = toks_of(g)
                                typed = {nm for _, nm, ty2 in named_types(gk)
                                         if re.match(r"\*?(?:const\s+)?" + re.escape(sname) + r"\b", ty2)}
                                typed -= {"self"}
                                pat = (r"\b(?:" + "|".join(sorted(typed)) + r")\." + fname_ + r"\b") if typed else None
                                if key not in scoped[g] or (pat and pat not in alias[g]):
                                    scoped[g].add(key)
                                    if pat:
                                        alias[g].add(pat)
                                    changed = True
                                carriers.append((rev, g, f"{sname}.{fname_}", "struct field", types.get(fname_, "").strip()))
                    continue
                callee = enclosing_call(tk, q0)
                if callee is not None and callee not in ZIG_KEYWORDS:
                    relock_calls.add((f, callee))
                    if callee not in relock_fns:
                        relock_fns.add(callee)
                        changed = True
    # carriers: handle fields, allocations and test literals that set the State's mutex (r35: from the code tokens)
    for f, t in texts.items():
        lit_ = re.search(r"\.\s*mutex\s*=|renderer_state", t) is not None
        rel_ = any(d_[0] in relock_fns for d_ in stx[f][2][0])
        if not lit_ and not rel_ and f != "src/renderer/State.zig":
            continue
        lns = lines_of[f]
        tk, _ = toks_of(f) if (lit_ or rel_) else ([], [])
        n_ = len(tk)
        best_ = {}   # one row a line, as r34's: an allocation, else a free, else a literal
        for q_ in range(n_ if lit_ else 0):
            x = tk[q_]
            if x.text != "mutex" or x.kind != "identifier" or not (q_ >= 1 and zigtok.is_op(tk[q_ - 1], ".")):
                continue
            ln_ = x.line
            c = sc(lns[ln_]) if ln_ < len(lns) else ""
            if q_ >= 2 and tk[q_ - 2].text == "renderer_state" and q_ + 1 < n_ and zigtok.is_op(tk[q_ + 1], "="):
                kind_ = "allocation"
            elif (q_ >= 5 and zigtok.is_op(tk[q_ - 2], "{") and zigtok.is_op(tk[q_ - 3], ".") and zigtok.is_op(tk[q_ - 4], "=")
                  and tk[q_ - 5].text == "renderer_state" and q_ + 1 < n_ and zigtok.is_op(tk[q_ + 1], "=")):
                kind_ = "allocation"
            elif q_ >= 2 and tk[q_ - 2].text == "renderer_state" and enclosing_call(tk, q_) == "destroy":
                kind_ = "free"
            elif (q_ >= 2 and tk[q_ - 2].kind == "op" and tk[q_ - 2].text in ("{", ",", "(")
                  and q_ + 2 < n_ and zigtok.is_op(tk[q_ + 1], "=")
                  and (zigtok.is_op(tk[q_ + 2], "&") or tk[q_ + 2].text in ("mutex", "try")
                       or (tk[q_ + 2].kind == "identifier" and (chain_at(tk, q_ + 2) or (0, q_ + 2))[1] < n_
                           and tk[(chain_at(tk, q_ + 2) or (0, q_ + 2))[1]].text == "renderer_mutex"))):
                # every `.mutex = <pointer>` in a literal, inline or not (X3), whose literal is a renderer state, a
                # search option set (`.terminal =`) or a struct the pointer flows into (`renderer_mutex`): r35 reads
                # the literal and the statement it is in, r34 the eight lines before and two after
                o_ = enclosing_brace(tk, q_ - 1)
                if o_ is None:
                    continue
                s0, s1 = statement_start(tk, o_), zigtok.match_paren(tk, o_)
                ctx = tk[s0:min(s1 + 1, n_)]
                txt = zigtok.spaced(ctx)
                if not (re.search(r"\brenderer_state\b|\brenderer\s*\.\s*State\b|\brenderer_mutex\b", txt)
                        or any(zigtok.is_op(ctx[r], ".") and ctx[r + 1].text == "terminal" and zigtok.is_op(ctx[r + 2], "=")
                               for r in range(len(ctx) - 2))):
                    continue
                kind_ = "literal (State, search options or a test fixture)"
            else:
                continue
            rank_ = {"allocation": 0, "free": 1}.get(kind_, 2)
            if ln_ not in best_ or rank_ < best_[ln_][0]:
                best_[ln_] = (rank_, kind_, c.strip()[:80])
        for ln_ in sorted(best_):
            carriers.append((rev, f, f"line {ln_ + 1}", best_[ln_][1], best_[ln_][2]))
        if f == "src/renderer/State.zig":
            ty_ = stx[f][0][0][-1][1].get("mutex")   # the file scope's field
            if ty_:
                carriers.append((rev, f, "State.mutex", "declared type", ty_.strip()))
        _defs, _dtoks, _own = stx[f][2]
        for k_, (a_, b_, d_) in enumerate(_dtoks):
            fn = d_["name"] if d_["kind"] == "fn" else None
            if fn not in relock_fns or not d_["params"]:
                continue
            args_, _ = zigtok.split_args(tk if tk else toks_of(f)[0], d_["params"][0])
            prs = []
            for a in args_:
                ct = bool(a) and a[0].kind == "keyword" and a[0].text == "comptime"
                b = a[1:] if ct else a
                if b and b[0].kind == "keyword" and b[0].text == "noalias":
                    b = b[1:]
                if len(b) >= 3 and b[0].kind == "identifier" and zigtok.is_op(b[1], ":"):
                    prs.append((b[0].text, zigtok.spaced(b[2:], blank=True), ct))
            for pn, pt, _ in prs:
                pm = re.match(r"(\??\*(?:const\s+)?(?:\w+\.)*\w*Mutex)\b", pt)
                if pm:
                    carriers.append((rev, f, f"{fn}({pn})", "parameter", pm.group(1)))
                    break   # r34 read the first such parameter of each declaration
            # r30 (round 29's Opus M1): a mutex pointer handed to an `anytype` or generic parameter is a carrier too;
            # the callee's lock on it reads no declared mutex type, so it is unclassified (default-deny). Reported for
            # a callee this file declares and calls with the mutex
            if (f, fn) in relock_calls:
                generic = {pn for pn, pt, ct in prs if ct and pt.strip() == "type"}
                for pn, pt, _ in prs:
                    gm = re.match(r"(anytype\b|\??\*(?:const\s+)?(\w+)\b)", pt)
                    if gm and (gm.group(1) == "anytype" or (gm.group(2) and gm.group(2) in generic)):
                        carriers.append((rev, f, f"{fn}({pn})", "parameter (anytype or generic)", gm.group(1)))
    ftoks.clear()
    # ---- functions (token-matched; innermost owner by token)
    funcs, def_toks_of, owner_tok_of = {}, {}, {}
    for f in lines_of:
        funcs[f], def_toks_of[f], owner_tok_of[f] = stx[f][2]
    # M-b: functions called through a literal `@call(.always_inline, ...)`, by their last name component
    always_targets = collections.defaultdict(list)
    for f in lines_of:   # r32: read from the code tokens, the callee argument structurally
        if "always_inline" not in texts[f]:
            continue
        toks_ = resolver._toks(f)
        for q_, x_ in enumerate(toks_):
            if x_.kind == "builtin" and x_.text == "@call" and q_ + 1 < len(toks_) and zigtok.is_op(toks_[q_ + 1], "("):
                args_, _ = zigtok.split_args(toks_, q_ + 1)
                if (len(args_) >= 3 and len(args_[0]) == 2 and zigtok.is_op(args_[0][0], ".")
                        and args_[0][1].text == "always_inline" and args_[1]
                        and all(y_.kind == "identifier" or zigtok.is_op(y_, ".") for y_ in args_[1])):
                    always_targets[args_[1][-1].text].append(f"{f}:{x_.line + 1}")
        resolver.forget(f)

    def test_name(f, q):
        """r35: the outermost test block holding token q, by its name (M-f identity), from its tokens."""
        tops = [d for d in def_toks_of[f] if d[2]["kind"] == "test" and d[0] <= q <= d[1]]
        if not tops:
            return "test-code"
        d = min(tops, key=lambda d: d[0])
        kind, v = test_header_toks(resolver._toks(f), d[2]["fn"])   # r25: the kind out of band, then the exact identity
        return kind if v is None else f"{kind}:{v}"

    # ---- sites
    rows, unc, other_calls, distinct = [], [], 0, 0
    dist = []   # r32: the distinct acquisitions, for the independent binding check
    others, freads = [], []   # r35 (round 34's Opus M2): "other" acquisitions and field-read exemptions, for bindcheck
    acct = TOKENS[rev] = collections.Counter()   # r29: tokens, and the bucket each landed in
    site_defs = collections.defaultdict(set)   # (file, function identity) -> definition lines
    production_sites = []
    acquiring_decls = collections.defaultdict(set)
    acq_tests = set()   # r21 (AJ1): (file, test name) of test blocks that acquire directly
    nameless = set()    # r22, r24: (file, label, def line) of acquiring tests whose header gives no key
    headers = {}        # r35: (file, def index) -> the test header its tokens give

    def block_name(f_, k_):
        """r24, r35: the tagged header of def k_'s test block (test_header_toks)."""
        if (f_, k_) not in headers:
            headers[(f_, k_)] = test_header_toks(resolver._toks(f_), def_toks_of[f_][k_][2]["fn"])
        return headers[(f_, k_)]
    for f, t in texts.items():
        lines = lines_of[f]
        fs = funcs[f]
        own_tok = owner_tok_of[f]
        if not (any(op_ in t for op_ in ACQ_OPS) or "@field" in t):   # r32: a file naming no op and no @field has no token
            resolver.forget(f)
            continue
        src = ("(?:" + "|".join(sorted(alias[f])) + ")") if alias.get(f) else None
        toks_f = resolver._toks(f)
        declarations = [d for _, _, d in def_toks_of[f]]
        containers = zigtok.containers_of_tokens(toks_f, declarations)
        function_paths = zigtok.function_paths(declarations, containers)
        ntypes = named_types(toks_f)
        dstat = decl_statements(toks_f)
        mtypes = {"Mutex"} | std_mutex_aliases_toks(dstat)
        state_mutex = {nm for _, nm, ty in ntypes if re.match(r"\??\*?(?:const\s+)?(?:\w+\.)*StateMutex\b", ty)}
        # r29 (round 28's Opus M1): the type names a lock op may be called on as a function, `Mutex.lock(m)`; r30 (round
        # 29's Sol M1, Opus M1): an alias of an alias, any length, and std named by `@import("std")`
        tnames = alias_closure_toks({"Mutex", "RwLock", "StateMutex"} | mtypes | {
            nm for _, nm, ty, init, _ in dstat if ty is None and re.fullmatch(
                r"(?:" + STDP + r"\.(?:Thread|Io)\.(?:Mutex|RwLock)|(?:\w+\.)*StateMutex)",
                zigtok.spaced(init).replace(" ", ""))}, dstat)
        clean = None   # r35: no pass reads cleaned lines
        fields_by_line = collections.defaultdict(list)   # r31, r32: every @field reference, from the code tokens
        callees_f = call_callees(toks_f)
        for ln_, arg_, called_, box_, name_, fq_ in field_refs_toks(toks_f, callees_f):
            fields_by_line[ln_].append((arg_, called_, box_, name_, fq_))
        census = census_of(f, toks_f, tnames, resolver, callees_f, freads)

        mtypes_by_file[f] = mtypes

        def resolves_value_mutex(recv_, q_):
            """r29 (round 28's Opus M1): distinct only when the receiver resolves to a value mutex (Resolver)."""
            return resolver.value_mutex(recv_, f, q_, None, fs, clean)
        tpat = r"(?:\w+\.)*(?:\w*Mutex|" + "|".join(sorted(mtypes)) + r")\b"   # any `\w*Mutex` (Z1: H, H2)
        mutex_names, value_mutex = set(), set()
        for _, nm, ty in ntypes:
            m = re.match(r"(\??\*?)(?:const\s+)?" + tpat, ty)
            if m:
                mutex_names.add(nm)
                if not m.group(1):
                    value_mutex.add(nm)
        for q_, nm, ty, init, e_ in dstat:
            if ty is not None and not re.match(tpat, ty):
                continue
            it = zigtok.spaced(init)
            if re.fullmatch(r"(?:" + tpat + r")?\s*(?:\{\s*\}|\.\s*\{\s*\})", it) or re.match(r"(?:" + tpat + r")?\s*\.\s*init\b", it):
                stmt = zigtok.spaced(toks_f[q_:e_ + 1])
                if "utex" in stmt or re.search(tpat, stmt):
                    mutex_names.add(nm)
                    value_mutex.add(nm)
        mparams_of, alias_decls = {}, collections.defaultdict(list)
        for q_, nm, ty, init, e_ in dstat:   # r35: each function's own declarations, in token order
            alias_decls[own_tok[q_] if q_ < len(own_tok) else None].append((q_, nm, zigtok.spaced(toks_f[q_:e_ + 1])))

        def mparams(k_):
            """r35: the mutex-pointer parameters of def k_ when its name is a relock function, from its tokens (r34
            read the six lines from its first one, and only while the line run it owned had not been broken)."""
            if k_ not in mparams_of:
                out_ = set()
                d_ = def_toks_of[f][k_][2]
                if fs[k_][0] in relock_fns and d_["params"]:
                    for a in zigtok.split_args(toks_f, d_["params"][0])[0]:
                        b = [y for y in a if not (y.kind == "keyword" and y.text in ("comptime", "noalias"))]
                        if len(b) >= 3 and b[0].kind == "identifier" and zigtok.is_op(b[1], ":") and \
                                re.match(r"\??\*(?:const\s+)?" + tpat, zigtok.spaced(b[2:], blank=True)):
                            out_.add(b[0].text)
                mparams_of[k_] = out_
            return mparams_of[k_]

        def local_alias(k_, q_):
            """r35: the names def k_ binds, before token q_, to the renderer mutex (`const m = &...mutex;`) or to such a
            name (`const second = first;`), from its own declarations' tokens (r34: from its lines, reset whenever a
            nested function interrupted them)."""
            out_ = set()
            if not src:
                return out_
            for dq, nm, stmt in alias_decls.get(k_, ()):
                if dq >= q_:
                    break
                if re.search(r"\b(?:const|var)\s+(\w+)\s*(?::[^=]+)?=\s*&?\s*(?:[\w.]*\.)?(?:" + src
                             + r")(?:\s*\.\s*\*)?\s*;", stmt):   # r30 (round 29's Opus M1): `&...mutex.*` too
                    out_.add(nm)
                else:   # r30 (round 29's Sol M1): an alias of a local alias, any length (`const second = first;`)
                    lc = re.search(r"\b(?:const|var)\s+(\w+)\s*(?::[^=]+)?=\s*&?\s*(\w+)(?:\s*\.\s*\*)?\s*;", stmt)
                    if lc and lc.group(2) in out_:
                        out_.add(nm)
            return out_
        for i in sorted(set(census[0]) | set(census[1]) | set(fields_by_line)):
            l = lines[i] if i < len(lines) else ""
            # r29 (round 28's Sol M1, Opus M1), r32 (round 31's Opus M2): every lock-op token, each read once, from the
            # file's code tokens (census_of), on the line its op name stands on
            acqs = list(census[0].get(i, ()))
            for msg_ in census[1].get(i, ()):   # r32: a lock op used as a value that is no field read
                acct["tokens"] += 1
                acct["refused"] += 1
                UNREADABLE.append(f"{msg_} (at {rev})")
            # r30 (round 29's Opus M1), r31 (round 30's Sol M2): an op named as a string, its escapes decoded
            # (`@field(T, "\x6cock")` is `lock`), is a lock-op token no receiver pass can read: refused; a called
            # @field whose name is no literal follows NONLITERAL_CALLS
            for arg_, called_, box_, name_, fq_ in fields_by_line.get(i, ()):
                if name_ is not None and name_ in ACQ_OPS:
                    acct["tokens"] += 1
                    acct["refused"] += 1
                    UNREADABLE.append(f"UNREADABLE-RECEIVER {f}:{i + 1}: a lock op named as a string "
                                      f"(@field(_, {arg_[:40]}) reads {name_!r}); call it by name on a named receiver (at {rev})")
                elif name_ is None and called_ and NONLITERAL_CALLS == "refuse":
                    acct["tokens"] += 1
                    acct["refused"] += 1
                    UNREADABLE.append(f"UNREADABLE-RECEIVER {f}:{i + 1}: a called @field whose name is no literal "
                                      f"({arg_[:40]}); the census cannot tell which function it calls (at {rev})")
                elif name_ is None and called_ and NONLITERAL_CALLS == "unclassified":
                    # the user's r31 decision: a visible reflected call whose op cannot be known is an acquisition the
                    # tool cannot place, keyed by its @field text, so the gate fails it unless the allow-list names it
                    acqs.append(("@field", ("@field(" + box_[:60] + ", " + arg_[:60] + ")", "@field"), fq_))
            for op, rcv, q in acqs:
                acct["tokens"] += 1
                if rcv is None:
                    acct["refused"] += 1
                    UNREADABLE.append(f"UNREADABLE-RECEIVER {f}:{i + 1}: a lock op ({op}) on a receiver the tools "
                                      f"cannot name or classify; bind it to a name first (at {rev})")
                    continue
                recv, last = rcv
                k = own_tok[q] if q < len(own_tok) else None   # r35: the innermost def holding the op's token
                site_text = recv + "." + op + "("
                cap_name = resolver.if_capture(last, f, q) if last != NO_CALL and "." not in recv else None
                fname = fs[k][0] if k is not None else "(top level)"
                in_test = k is not None and fs[k][4]
                mp = mparams(k) if k is not None else set()
                la = local_alias(k, q) if k is not None else set()
                kind = None
                if last == NO_CALL:
                    kind = None   # r33: a lock op used as a value with no evidence: unclassified, keyed by its text
                elif op == "demand":
                    # AC2: only the State forwarder's call of the wrapper's demand acquire is a site
                    if f == "src/renderer/State.zig" and last == "mutex" and recv.startswith("self."):
                        kind = "handoff-internal"
                    else:
                        kind = None   # r29 (round 28's Opus M1): unclassified on an unknown receiver, never dropped
                elif op in ("lockDemand", "yieldToDemand"):
                    if last in handles[f] or last in ("state", "renderer_state"):
                        kind = "demand" if op == "lockDemand" else "yield"
                    else:
                        kind = None   # r29 (round 28's Opus M1): unclassified on an unknown receiver, never dropped
                elif f == "src/renderer/State.zig" and last == "mutex" and recv.startswith("self."):
                    kind = "handoff-internal"
                elif src and re.search(src + r"\." + op + r"\(", site_text):
                    kind = "renderer-state"
                elif any(re.fullmatch(rx_, recv) and a_ <= q <= b_ for rx_, a_, b_ in scoped[f]):
                    kind = "renderer-state"
                elif last in la:
                    kind = "renderer-state"
                elif mp and (last in mp or (cap_name and cap_name in mp)):
                    kind = "relock"
                elif last in state_mutex or (cap_name and cap_name in state_mutex):
                    kind = "renderer-state"   # the wrapper type is the renderer-state mutex (Opus L4)
                elif op in SHARED_OPS:
                    acct["shared"] += 1   # r29: an RwLock's shared lock; a std Mutex has none, so never a mutex name
                    continue
                elif (last in value_mutex and resolves_value_mutex(recv, q)) or \
                        (cap_name and cap_name in value_mutex and resolves_value_mutex(cap_name, q)):
                    kind = "distinct"   # r29: r28's name match, confirmed by declarations (never newly distinct)
                elif last in mutex_names or (cap_name and cap_name in mutex_names) or "utex" in last:
                    kind = None  # a mutex the tool cannot place
                else:
                    if op in SHARED_OPS:
                        acct["shared"] += 1   # r29: a shared lock (an RwLock's) on a receiver that is no mutex
                        continue
                    # r30 (round 29's lead direction, Opus M1): default-deny: "other" only by evidence, an RwLock's
                    # exclusive lock, a std file's lock or a value std mutex this file does not name, each reached by
                    # declarations; anything else is unclassified
                    oty = resolver.other_type(recv, f, q, None, fs, clean)
                    if oty is not None:
                        other_calls += 1
                        acct["other"] += 1
                        others.append((rev, f, i + 1, fname, op, recv, oty))
                        continue
                    kind = None
                acct["site" if kind not in (None, "distinct") else "unclassified" if kind is None else "distinct"] += 1
                if in_test:
                    th = "test"
                else:
                    th = next((REVIEWED[(f, untok(fname), s_)] for s_ in LOOKUP[SCOPE[rev]] if (f, untok(fname), s_) in REVIEWED),
                              "UNREVIEWED")
                if k is not None and fs[k][5]:
                    inl = "inline-fn"
                elif (bare_name := fname.rsplit(".", 1)[-1]) in always_targets:
                    inl = "always-inline@" + ",".join(always_targets[bare_name])
                else:
                    inl = "-"
                tid = test_name(f, q) if in_test else "-"
                row = (rev, f, i + 1, fname, op, kind or "UNCLASSIFIED", th, l.strip()[:100].replace("\t", " "), inl, tid)
                if kind is None:
                    unc.append(row + (recv,))   # r30: the receiver, the allow-list's third key
                elif kind == "distinct":
                    distinct += 1
                    dist.append((rev, f, i + 1, fname, op, recv))
                else:
                    rows.append(row)
                    if k is not None and fs[k][0] != "(test)":
                        definition = fs[k][1] + 1
                        if in_test:
                            site_defs[(f, fname)].add(definition)
                        else:
                            path_name = function_paths.get(declarations[k]["fn"], fname)
                            acquiring_decls[(f, fname)].add(definition)
                            production_sites.append((len(rows) - 1, definition, path_name))
                    elif k is not None:
                        # r21 (AJ1): a test block's own acquisition is keyed file:test:<name>, and Zig keeps test
                        # names unique per container only, so every same-named test block of the file counts
                        kind_, v_ = block_name(f, k)
                        if kind_ == "named":
                            acq_tests.add((f, v_))
                        else:   # r22 to r24: it needs a string name with a key, decided by the tag
                            label_ = {"no-key": f"(name {v_})", "decltest": f"decltest {v_}",
                                      "unnamed": "(unnamed)"}[kind_]
                            nameless.add((f, label_, fs[k][1] + 1))
        resolver.forget(f)   # r32: the resolver reads only this file's text for this file's sites
    for index, definition, path_name in production_sites:
        row = rows[index]
        file, bare = row[1], row[3]
        path_role = next((REVIEWED[(file, untok(path_name), sc)] for sc in LOOKUP[SCOPE[rev]]
                          if (file, untok(path_name), sc) in REVIEWED), None)
        # The frozen table has bare rows for unique acquiring declarations.
        # A second acquisition owner needs a separate reviewed container key.
        if len(acquiring_decls[file, bare]) > 1 or path_role is not None:
            rows[index] = (*row[:3], path_name, *row[4:6], path_role or "UNREVIEWED", *row[7:])
            site_defs[file, path_name].add(definition)
        else:
            site_defs[file, bare].add(definition)
    for f_, n_ in acq_tests:
        defs_ = {funcs[f_][k_][1] + 1 for k_ in range(len(funcs[f_]))
                 if funcs[f_][k_][0] == "(test)" and block_name(f_, k_) == ("named", n_)}
        if len(defs_) > 1:
            site_defs[(f_, "test:" + n_)] |= defs_
    if acct["tokens"] != sum(v for k_, v in acct.items() if k_ != "tokens"):
        TOOL_ERRORS.append(f"TOOL-ERROR {rev}: {acct['tokens']} lock-op tokens, but the buckets hold "
                           f"{sum(v for k_, v in acct.items() if k_ != 'tokens')} ({dict(acct)})")
    all_rows += rows
    all_unc += unc
    all_car += carriers
    all_dist += dist
    all_other += others
    all_fr += [(rev,) + x for x in freads]
    live = [r for r in rows if r[4] in ACQ and r[5] in ("renderer-state", "demand") and r[6] != "test"]
    unreviewed = [r for r in rows if r[6] == "UNREVIEWED" and r[5] in ("renderer-state", "demand", "relock", "handoff-internal")]
    by_thread = collections.Counter()
    for r in live:
        for th in r[6].split("|"):
            by_thread[th] += 1
    multi = [r for r in live if "|" in r[6]]
    never = [r for r in live if r[6] == "never-on-win32"]
    snap = [r for r in rows if r[1] == "src/renderer/generic.zig" and r[3] == "updateFrame" and r[4] in ACQ]
    summary[rev] = dict(n=len(live), files=len({r[1] for r in live}), threads=dict(sorted(by_thread.items())),
                        ops=dict(collections.Counter(r[4] for r in live)), multi=len(multi), never=len(never),
                        live=len(live) - len(never), yields=len([r for r in rows if r[5] == "yield" and r[6] != "test"]),
                        relock=len([r for r in rows if r[5] == "relock" and r[6] != "test"]),
                        internal=len([r for r in rows if r[5] == "handoff-internal" and r[6] != "test"]),
                        unc=len([u for u in unc if u[4] in ACQ and u[6] != "test"]), other=other_calls, distinct=distinct,
                        snapshot="PASS" if snap else "FAIL", carriers=len({(c[1], c[2]) for c in carriers}),
                        unreviewed=len(unreviewed), relock_threads="|".join(sorted({r[6] for r in rows if r[5] == "relock"})),
                        inline=len([r for r in rows if r[8] != "-" and r[6] != "test"
                                    and r[5] in ("renderer-state", "demand", "relock", "handoff-internal")]),
                        tests=len([r for r in rows if r[6] == "test"
                                   and r[5] in ("renderer-state", "demand", "relock", "handoff-internal")]),
                        same_name=sorted((f_, n_, sorted(v_)) for (f_, n_), v_ in site_defs.items() if len(v_) > 1)
                        + sorted((f_, f"test {n_}: an acquiring test needs a UTF-8 string name with no control character", [d_])
                                 for f_, n_, d_ in nameless))

if UNREADABLE or TOOL_ERRORS:   # r28, r29: a spelling no pass can read fails the run explicitly, never zero rows
    for _sfx in ("-sites.tsv", "-unclassified.tsv", "-carriers.tsv", "-distinct.tsv", "-other.tsv", "-fieldreads.tsv"):
        open(out + _sfx, "w", encoding="utf-8", newline="\n").close()
    with open(out + "-summary.tsv", "w", encoding="utf-8", newline="\n") as fh:   # the header only: no result at all
        fh.write("rev\tacquisitions\trelocks\thandoff_internal\tlive\tnever\tmulti\tunclassified\tcarriers\tunreviewed"
             "\tinline_flagged\ttest_sites\tsame_name\n")
        fh.write("".join(f"# {_u}\n" for _u in TOOL_ERRORS + UNREADABLE))   # what the gate reports, explicitly
    for _u in TOOL_ERRORS + UNREADABLE:
        print(_u)
    print(f"RESULT {'TOOL-ERROR' if TOOL_ERRORS else 'UNREADABLE'} ({len(TOOL_ERRORS) + len(UNREADABLE)}): "
          f"no inventory was written")
    sys.exit(3 if TOOL_ERRORS else 2)
with open(out + "-summary.tsv", "w", encoding="utf-8", newline="\n") as fh:
    fh.write("rev\tacquisitions\trelocks\thandoff_internal\tlive\tnever\tmulti\tunclassified\tcarriers\tunreviewed"
             "\tinline_flagged\ttest_sites\tsame_name\n")
    for rev, s in summary.items():
        fh.write(f"{rev}\t{s['n']}\t{s['relock']}\t{s['internal']}\t{s['live']}\t{s['never']}\t{s['multi']}\t"
                 f"{s['unc']}\t{s['carriers']}\t{s['unreviewed']}\t{s['inline']}\t{s['tests']}\t{len(s['same_name'])}\n")
with open(out + "-sites.tsv", "w", encoding="utf-8", newline="\n") as fh:
    for r in all_rows:
        fh.write(untok("\t".join(str(x) for x in r)) + "\n")
with open(out + "-unclassified.tsv", "w", encoding="utf-8", newline="\n") as fh:
    for r in all_unc:
        fh.write(untok("\t".join(str(x) for x in r)) + "\n")
with open(out + "-distinct.tsv", "w", encoding="utf-8", newline="\n") as fh:   # r32: for bindcheck32.py
    for r in all_dist:
        fh.write(untok("\t".join(str(x) for x in r)) + "\n")
with open(out + "-other.tsv", "w", encoding="utf-8", newline="\n") as fh:   # r35: for bindcheck35.py
    for r in all_other:
        fh.write(untok("\t".join(str(x) for x in r)) + "\n")
with open(out + "-fieldreads.tsv", "w", encoding="utf-8", newline="\n") as fh:   # r35: for bindcheck35.py
    for r in all_fr:
        fh.write(untok("\t".join(str(x) for x in r)) + "\n")
with open(out + "-tokens.tsv", "w", encoding="utf-8", newline="\n") as fh:   # r29: every lock-op token's bucket
    _b = ("site", "unclassified", "distinct", "other", "shared", "refused")
    fh.write("rev\ttokens\t" + "\t".join(_b) + "\n")
    for rev, a_ in TOKENS.items():
        fh.write(f"{rev}\t{a_['tokens']}\t" + "\t".join(str(a_[x]) for x in _b) + "\n")
with open(out + "-carriers.tsv", "w", encoding="utf-8", newline="\n") as fh:
    _seen = set()
    for r in sorted(set(all_car)):
        if (r[0], r[1], r[2]) in _seen:
            continue
        _seen.add((r[0], r[1], r[2]))
        fh.write(untok("\t".join(str(x) for x in r)) + "\n")
for rev, s in summary.items():
    print(f"{rev}: acquisitions {s['n']} in {s['files']} files (ops {s['ops']}); live on Win32 {s['live']}, never/no caller {s['never']}; "
          f"multi-thread sites {s['multi']}; thread memberships {s['threads']}; yields {s['yields']}; relocks {s['relock']}; "
          f"handoff-internal {s['internal']}; unclassified {s['unc']}; distinct {s['distinct']}; other lock calls {s['other']}; "
          f"carriers {s['carriers']}; snapshot control {s['snapshot']}; UNREVIEWED sites {s['unreviewed']}; relock threads {s['relock_threads']}; "
          f"inline-flagged sites {s['inline']}; test-code sites {s['tests']}")
for rev, s in summary.items():
    if s["unreviewed"]:
        for r in all_rows:
            if r[0] == rev and r[6] == "UNREVIEWED" and r[5] in ("renderer-state", "demand", "relock", "handoff-internal"):
                print(untok(f"UNREVIEWED {rev} {r[1]}:{r[2]} {r[3]} ({r[5]}, {r[4]})"))
for rev, s in summary.items():   # r19 (AH2): a compare key is file + bare name, so two acquiring functions may not share one
    print(f"{rev}: same-name acquiring functions within a file: {len(s['same_name'])}")
    for f_, n_, defs_ in s["same_name"]:
        print(untok(f"SAME-NAME {rev} {f_}: {n_} defined at lines {defs_}"))
sys.exit(1 if any(s["unreviewed"] or s["same_name"] for s in summary.values()) else 0)
