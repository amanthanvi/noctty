r"""zigtok: one shared Zig token stream for the static review tools (r32, round 31's lead direction), a small port of
the lexical rules of std/zig/tokenizer.zig, read in 0.15.2 and 0.17.1 (lib/std/zig/tokenizer.zig): line comments
(`//`, skipped), doc comments (`///`, not `////`) and container doc comments (`//!`), string literals and character
literals with their escapes (a backslash takes the next byte; a newline ends an unterminated one), multi-line string
lines (`\\` to the end of the line, before a CR LF from r33), quoted identifiers (`@"..."`, string-literal rules), builtins (`@name`),
identifiers and keywords, number literals (digits, letters and `_`, a `.` only when a digit or letter follows it, and
an exponent's sign after e, E, p or P), and operators by longest match. Every token keeps its text, its start offset
and its 0-based line. Token boundaries are the same in both compilers; they differ only in what they reject: 0.17.1
also rejects a control byte after a backslash in a string literal, has no `**` operator (two `*` tokens) and lexes
`.**` as `.*` and `*` where 0.15.2 gave `invalid_periodasterisks`; the keyword lists are identical. The tools read
source only through code() (every token but comments), so a comment, whitespace or a newline never splits a
construct. Installed beside the tools in ci/ (INSTALL) and loaded by them from their own directory.
Shared readers: code() (the token stream), clean_line() (a line as the line passes read it, from its tokens),
spaced() (a token run's text), match_paren()/match_back()/split_args() (brackets and arguments), declaration_at()
(a `const` or `var` that declares a name, not a pointer type's qualifier), payload_at()/payload_names() (a capture
list wherever it starts); from r34 the structure readers, functions_of_tokens() (function declarations and test
blocks), containers_of_tokens() (struct, union, enum and opaque bodies, and their names) and container_members() (a
container's fields and typed declarations at its own level), depth counted over `(`, `[` and `{` alike."""
import re

KEYWORDS = frozenset((
    "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "break", "callconv", "catch", "comptime",
    "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline",
    "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "linksection",
    "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "var", "volatile", "while"))
OPERATORS = sorted((
    "<<|=", "<<=", ">>=", "...", "<<|", "+%=", "-%=", "*%=", "+|=", "-|=", "*|=",
    "=>", "==", "!=", "<=", ">=", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "++", "**", "||",
    "+%", "-%", "*%", "+|", "-|", "*|", "->", "..", ".*"), key=len, reverse=True)
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class Token:
    __slots__ = ("kind", "text", "start", "line")

    def __init__(self, kind, text, start, line):
        self.kind, self.text, self.start, self.line = kind, text, start, line

    def __repr__(self):
        return f"Token({self.kind}, {self.text!r}, line {self.line})"


def _literal_end(s, j, quote):
    """The index past a string or character literal opened at s[j] (`quote`), or the newline that ends an
    unterminated one."""
    n, k = len(s), j + 1
    while k < n and s[k] != quote and s[k] != "\n":
        k += 2 if s[k] == "\\" and k + 1 < n and s[k + 1] != "\n" else 1
    return k + 1 if k < n and s[k] == quote else k


OPERATORS_017 = [o for o in OPERATORS if o != "**"]   # 0.17.1 has no `**` operator: two `*` tokens


def _line_end(s, i):
    """r33 (round 32's Opus L2): where a comment or a multi-line string line opened at s[i] ends: before its newline,
    and before a carriage return right before that newline, as both compilers' tokenizers end a doc comment or a
    multi-line string line at a CR LF (0.15.2 and 0.17.1 lib/std/zig/tokenizer.zig: `'\\r' => if (next != '\\n')
    invalid`); r32 kept the carriage return in the token on a CRLF file. The carriage return is then whitespace, which
    the tokenizers skip."""
    j = s.find("\n", i)
    if j < 0:
        return len(s)
    return j - 1 if j > i and s[j - 1] == "\r" else j


def tokenize(s, dialect="0.15.2"):
    """Every token of a source text, comments included (kinds: comment, doc_comment, container_doc_comment, string,
    char, mlstring, identifier (a quoted `@"..."` one too), keyword, builtin, number, op). `dialect` "0.17.1" lexes
    `**` as two `*`, as that compiler does; no construct the tools read depends on it."""
    ops = OPERATORS_017 if dialect.startswith("0.17") else OPERATORS
    out, i, n, line = [], 0, len(s), 0
    while i < n:
        ch = s[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r":
            i += 1
            continue
        if s.startswith("//", i):
            j = _line_end(s, i)
            text = s[i:j]
            kind = ("container_doc_comment" if text.startswith("//!")
                    else "doc_comment" if text.startswith("///") and not text.startswith("////") else "comment")
            out.append(Token(kind, text, i, line))
            i = j
            continue
        if s.startswith("\\\\", i):
            j = _line_end(s, i)
            out.append(Token("mlstring", s[i:j], i, line))
            i = j
            continue
        if ch == '"':
            j = _literal_end(s, i, '"')
            out.append(Token("string", s[i:j], i, line))
            i = j
            continue
        if ch == "'":
            j = _literal_end(s, i, "'")
            out.append(Token("char", s[i:j], i, line))
            i = j
            continue
        if ch == "@":
            if i + 1 < n and s[i + 1] == '"':
                j = _literal_end(s, i + 1, '"')
                out.append(Token("identifier", s[i:j], i, line))
                i = j
                continue
            m = WORD.match(s, i + 1)
            if m:
                out.append(Token("builtin", s[i:m.end()], i, line))
                i = m.end()
                continue
            out.append(Token("op", "@", i, line))
            i += 1
            continue
        if ch.isalpha() or ch == "_":
            m = WORD.match(s, i)
            w = m.group(0)
            out.append(Token("keyword" if w in KEYWORDS else "identifier", w, i, line))
            i = m.end()
            continue
        if ch.isdigit():
            j = i + 1
            while j < n:
                c = s[j]
                if c.isalnum() or c == "_":
                    if c in "eEpP" and j + 1 < n and s[j + 1] in "+-":
                        j += 2
                    else:
                        j += 1
                elif c == "." and j + 1 < n and (s[j + 1].isalnum() or s[j + 1] == "_"):
                    j += 1
                else:
                    break
            out.append(Token("number", s[i:j], i, line))
            i = j
            continue
        for op in ops:
            if s.startswith(op, i):
                out.append(Token("op", op, i, line))
                i += len(op)
                break
        else:
            out.append(Token("op", ch, i, line))
            i += 1
    return out


COMMENTS = ("comment", "doc_comment", "container_doc_comment")


def code(s, dialect="0.15.2"):
    """The tokens the tools read: every token but comments (a doc comment is a comment here too)."""
    return [t for t in tokenize(s, dialect) if t.kind not in COMMENTS]


def clean_line(l, quoted=None):
    """One line as the tools' line passes read it, from its tokens: its comment removed, every string and character
    literal emptied (`""`, `''`), a multi-line string line dropped (the whole line when it starts one), and a quoted
    identifier `@"..."` read as `quoted(inner)` when that gives a name, else `@""`. Zig has no token that spans a
    line (a comment, a string literal and a multi-line string line each end at the newline), so a line's own tokens
    are its tokens in the file. r31's per-line cleaner read the same except a `\\` line opened after code on its
    line, whose text it read as code."""
    toks = tokenize(l)
    if toks and toks[0].kind == "mlstring":
        return ""
    out, pos = [], 0
    for t in toks:
        out.append(l[pos:t.start])
        pos = t.start + len(t.text)
        if t.kind in COMMENTS or t.kind == "mlstring":
            return "".join(out)
        if t.kind == "string":
            out.append('""')
        elif t.kind == "char":
            out.append("''")
        elif t.kind == "identifier" and t.text.startswith('@"'):
            q = quoted(t.text[2:-1]) if quoted and t.text.endswith('"') and len(t.text) >= 3 else None
            out.append(q or '@""')
        else:
            out.append(t.text)
    out.append(l[pos:])
    return "".join(out)


def spaced(toks, blank=False):
    """A token run's text with one space wherever the source had whitespace, a newline or a comment between two of
    its tokens, and none elsewhere: the run as r31's readers gave it after collapsing whitespace. `blank` empties
    string and character literals (`""`, `''`), as the cleaned lines do."""
    out, prev_end = [], None
    for t in toks:
        if prev_end is not None and t.start > prev_end:
            out.append(" ")
        if blank and t.kind == "string":
            out.append('""')
        elif blank and t.kind == "char":
            out.append("''")
        else:
            out.append(t.text)
        prev_end = t.start + len(t.text)
    return "".join(out)


def match_back(toks, k):
    """The index of the token opening the bracket closed at toks[k] (`)`, `]` or `}`), or None."""
    pairs = {")": "(", "]": "[", "}": "{"}
    closer, opener, depth = toks[k].text, pairs[toks[k].text], 0
    for j in range(k, -1, -1):
        t = toks[j].text if toks[j].kind == "op" else None
        if t == closer:
            depth += 1
        elif t == opener:
            depth -= 1
            if depth == 0:
                return j
    return None


def is_op(t, *texts):
    return t is not None and t.kind == "op" and t.text in texts


# the tokens a `const` qualifier follows inside a pointer or slice type (`*const T`, `[]const u8`, `[*c]const u8`,
# `*align(4) const T`, `*allowzero const T`; 0.15.2 lexes `**const T` with a `**`): there `const` is no declaration
TYPE_QUALIFIED = frozenset(("*", "**", "]", ")", "allowzero"))


def declaration_at(toks, q):
    """Whether the `const` or `var` keyword at toks[q] opens a declaration (it is followed by a name and is no
    pointer or slice type's qualifier)."""
    t = toks[q]
    if t.kind != "keyword" or t.text not in ("const", "var") or q + 1 >= len(toks) or toks[q + 1].kind != "identifier":
        return False
    p = toks[q - 1] if q else None
    return not (p is not None and p.kind in ("op", "keyword") and p.text in TYPE_QUALIFIED)


def payload_at(toks, q):
    """Whether the `|` at toks[q] opens a payload capture list: after `catch`, `else`, `errdefer`, `=>`, or the `)` that closes an
    `if`, `while` or `for` condition (anywhere: on its line or the next, a comment between or not); a bitwise `|`
    is none."""
    if not is_op(toks[q], "|") or q == 0:
        return False
    p = toks[q - 1]
    if p.kind == "keyword" and p.text in ("catch", "else", "errdefer"):
        return True
    if is_op(p, "=>"):
        return True
    if is_op(p, ")"):
        o = match_back(toks, q - 1)
        return o is not None and o >= 1 and toks[o - 1].kind == "keyword" and toks[o - 1].text in ("if", "while", "for")
    return False


def payload_names(toks, q):
    """The names a payload capture list opened at toks[q] binds (`|x|`, `|*x|`, `|x, i|`), and the index of its
    closing `|`."""
    names, r = [], q + 1
    while r < len(toks) and not is_op(toks[r], "|"):
        if toks[r].kind == "identifier":
            names.append(toks[r])
        r += 1
    return names, r


def unescape(body):
    r"""A Zig string literal's bytes as the compiler reads them (its inside, without the quotes): a literal character as
    its UTF-8 bytes, \xNN as one byte, \u{N} as the code point's UTF-8, \n \r \t \\ \' \" as their byte."""
    out, i = bytearray(), 0
    while i < len(body):
        c = body[i]
        if c != "\\" or i + 1 >= len(body):
            out += c.encode("utf-8", "surrogatepass")
            i += 1
            continue
        nx = body[i + 1]
        if nx in "nrt\\'\"":
            out += {"n": b"\n", "r": b"\r", "t": b"\t"}.get(nx, nx.encode("ascii"))
            i += 2
        elif nx == "x" and re.fullmatch(r"[0-9A-Fa-f]{2}", body[i + 2:i + 4]):
            out.append(int(body[i + 2:i + 4], 16))
            i += 4
        elif nx == "u" and body[i + 2:i + 3] == "{" and "}" in body[i + 3:]:
            j = body.index("}", i + 3)
            out += chr(int(body[i + 3:j], 16)).encode("utf-8", "surrogatepass")
            i = j + 1
        else:
            out += c.encode("utf-8", "surrogatepass")
            i += 1
    return bytes(out)


def string_value(tok):
    """The decoded text of a single string-literal token, or None when it is no string or not UTF-8."""
    if tok.kind != "string" or len(tok.text) < 2 or not tok.text.endswith('"'):
        return None
    try:
        return unescape(tok.text[1:-1]).decode("utf-8")
    except UnicodeDecodeError:
        return None


def match_paren(toks, k):
    """The index of the token closing the bracket opened at toks[k] (`(`, `[` or `{`), or len(toks)."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    opener, closer, depth = toks[k].text, pairs[toks[k].text], 0
    for j in range(k, len(toks)):
        t = toks[j].text if toks[j].kind == "op" else None
        if t == opener:
            depth += 1
        elif t == closer:
            depth -= 1
            if depth == 0:
                return j
    return len(toks)


def split_args(toks, k):
    """The argument token runs of the call whose `(` is toks[k], split at top-level commas; and the closing index."""
    end = match_paren(toks, k)
    args, cur, depth = [], [], 0
    for t in toks[k + 1:end]:
        if t.kind == "op" and t.text in "([{":
            depth += 1
        elif t.kind == "op" and t.text in ")]}":
            depth -= 1
        if t.kind == "op" and t.text == "," and depth == 0:
            args.append(cur)
            cur = []
            continue
        cur.append(t)
    if cur:
        args.append(cur)
    return args, end


def text_of(toks):
    """A token run as one compact text: tokens joined with no space, but one between two word-like tokens."""
    out, prev = [], None
    for t in toks:
        word = t.kind in ("identifier", "keyword", "builtin", "number")
        if out and word and prev:
            out.append(" ")
        out.append(t.text)
        prev = word
    return "".join(out)


# ---- r34 (round 33's Opus M1 and the lead's direction): structure from the token stream. r33's res_index, structs(),
# functions() and block_end read one cleaned line at a time and counted braces per line, so a `(` did not change the
# depth: each line of a method's multi-line parameter list sat at its struct's brace depth and was recorded as a
# member of the struct, overwriting a field's type. Every reader below works on the code tokens, its depth counted
# over `(`, `[` and `{` alike.

def split_lines_tokens(text):
    """The code tokens of a text, each token's line its splitlines() index (the same as the newline count unless the
    text holds another line separator), and the number of lines."""
    toks = code(text)
    if len(text.splitlines()) != text.count("\n") + (0 if not text or text.endswith("\n") else 1):
        import bisect
        starts, pos = [], 0
        for l_ in text.splitlines(True):
            starts.append(pos)
            pos += len(l_)
        for x in toks:
            x.line = bisect.bisect_right(starts, x.start) - 1
    return toks, len(text.splitlines())


CONTAINERS = ("struct", "union", "enum", "opaque")
FN_QUALIFIERS = ("pub", "inline", "noinline", "export", "extern")


def _type_brace(toks, r):
    """Whether the `{` at toks[r], met after a parameter list, opens a part of the return type (`error{...}`,
    `struct {...}`, `union(enum) {...}`, a `switch (@TypeOf(x)) {...}` that computes it, as paste.zig's encode has)
    rather than the body."""
    pv = toks[r - 1]
    if pv.kind == "keyword" and pv.text in ("error",) + CONTAINERS:
        return True
    if is_op(pv, ")"):
        o = match_back(toks, r - 1)
        return (o is not None and o >= 1 and toks[o - 1].kind == "keyword"
                and toks[o - 1].text in CONTAINERS + ("switch",))
    return False


def functions_of_tokens(toks):
    """Every function declaration (`fn NAME (`, its qualifiers before it) and every test block, from the tokens:
    [dict(kind "fn" or "test", name, start (index of its first token), params (open, close), ret (first index, end
    index), body (open, close) or None, end (index of its last token), quals)]. A body is the first `{` after the
    parameter list, at that depth, that opens no type of the return type; a declaration with none ends at its `;`."""
    out, n = [], len(toks)
    for q, x in enumerate(toks):
        if x.kind != "keyword":
            continue
        if x.text == "fn" and q + 2 < n and toks[q + 1].kind == "identifier" and is_op(toks[q + 2], "("):
            pc = match_paren(toks, q + 2)
            j, quals = q - 1, set()
            while j >= 0 and ((toks[j].kind == "keyword" and toks[j].text in FN_QUALIFIERS)
                              or (toks[j].kind == "string" and j >= 1 and toks[j - 1].kind == "keyword"
                                  and toks[j - 1].text == "extern")):
                quals.add(toks[j].text)
                j -= 1
            r, d, body = pc + 1, 0, None
            while r < n:
                y = toks[r]
                if is_op(y, "(", "["):
                    d += 1
                elif is_op(y, ")", "]"):
                    d -= 1
                elif d == 0 and is_op(y, ";"):
                    break
                elif d == 0 and is_op(y, "{"):
                    if _type_brace(toks, r):
                        r = match_paren(toks, r) + 1
                        continue
                    body = r
                    break
                r += 1
            end = min(match_paren(toks, body), n - 1) if body is not None else min(r, n - 1)   # unbalanced: the end
            out.append(dict(kind="fn", name=toks[q + 1].text, start=j + 1, fn=q, params=(q + 2, pc),
                            ret=(pc + 1, body if body is not None else min(r, n)), body=(body, end) if body is not None else None,
                            end=end, quals=quals))
        elif x.text == "test":
            r = q + 1
            if r < n and toks[r].kind in ("string", "identifier"):
                r += 1
            if r < n and is_op(toks[r], "{"):
                end = min(match_paren(toks, r), n - 1)   # an unbalanced block ends at the last token
                out.append(dict(kind="test", name="(test)", start=q, fn=q, params=None, ret=None, body=(r, end), end=end,
                                quals=set()))
    return out


def _member_start(t):
    """Whether a field or a declaration may begin after token t at a container's own level."""
    return t is None or is_op(t, "{", ",", ";", "}") or (t.kind == "keyword" and t.text in ("comptime", "pub"))


def container_members(toks, lo, hi):
    """The members at a container's own level, toks[lo:hi] (inside its braces, or the whole file): (fields, decls),
    each {name: (type text as a cleaned line spells it, line)} in token order: a field `NAME: TYPE [= default]`, its
    type to the first `=`, `,` or the end at the container's depth; a declaration `const|var NAME: TYPE = ...`, its
    type to the `=` or `;`. Depth counts `(`, `[` and `{` alike, so a parameter list, a body or a default expression
    over several lines holds no member."""
    fields, decls, d, r = {}, {}, 0, lo
    while r < hi:
        y = toks[r]
        if is_op(y, "(", "[", "{"):
            d += 1
        elif is_op(y, ")", "]", "}"):
            d -= 1
            if d < 0:   # more closers than openers (an unbalanced merge): the container's own level has ended
                break
        elif d == 0:
            prev = toks[r - 1] if r > lo else (toks[lo - 1] if lo > 0 else None)
            if (y.kind == "identifier" and r + 1 < hi and is_op(toks[r + 1], ":") and _member_start(prev)
                    and not (prev is not None and is_op(prev, "."))):
                e, dd = r + 2, 0
                while e < hi:
                    z = toks[e]
                    if is_op(z, "(", "[", "{"):
                        dd += 1
                    elif is_op(z, ")", "]", "}"):
                        if dd == 0:
                            break
                        dd -= 1
                    elif dd == 0 and is_op(z, "=", ","):
                        break
                    e += 1
                fields[y.text] = (spaced(toks[r + 2:e], blank=True), y.line)
            elif declaration_at(toks, r) and r + 2 < hi and is_op(toks[r + 2], ":"):
                e, dd = r + 3, 0
                while e < hi:
                    z = toks[e]
                    if is_op(z, "(", "[", "{"):
                        dd += 1
                    elif is_op(z, ")", "]", "}"):
                        if dd == 0:
                            break
                        dd -= 1
                    elif dd == 0 and is_op(z, "=", ";"):
                        break
                    e += 1
                decls[toks[r + 1].text] = (spaced(toks[r + 3:e], blank=True), toks[r].line)
        r += 1
    return fields, decls


def containers_of_tokens(toks, fns):
    """Every struct, union, enum and opaque body: [dict(kind, name, naming, head (index of its first header token),
    open, close)]. The name comes from the declaration it initializes (`const|var NAME [: T] = [extern|packed]
    struct`), from the innermost function returning `type` that returns it (`return struct`), or from the container
    opened just before it (`else struct`, an if's other branch); else "(anonymous)"."""
    out, n, last_name = [], len(toks), None
    type_fns = sorted(((f_["body"][0], f_["body"][1], f_["name"]) for f_ in fns if f_["kind"] == "fn" and f_["body"]
                       and spaced(toks[f_["ret"][0]:f_["ret"][1]]).strip().split("!")[-1].strip() == "type"),
                      key=lambda b: b[1] - b[0])
    for q, x in enumerate(toks):
        if x.kind != "keyword" or x.text not in CONTAINERS:
            continue
        r = q + 1
        if r < n and is_op(toks[r], "("):
            r = match_paren(toks, r) + 1
        if not (r < n and is_op(toks[r], "{")):
            continue
        h = q - 1
        while h >= 0 and toks[h].kind == "keyword" and toks[h].text in ("extern", "packed"):
            h -= 1
        if h >= 1 and is_op(toks[h], ")"):   # `= if (cond) struct {`: the if's first branch, named by the declaration
            o = match_back(toks, h)
            if o is not None and o >= 2 and toks[o - 1].kind == "keyword" and toks[o - 1].text == "if":
                h = o - 2
        name, naming, head = "(anonymous)", "anonymous", q
        if h >= 0 and is_op(toks[h], "="):
            j, dd = h - 1, 0
            while j >= 0:   # back over an optional type annotation to `NAME :` or `NAME`
                z = toks[j]
                if is_op(z, ")", "]", "}"):
                    dd += 1
                elif is_op(z, "(", "[", "{"):
                    if dd == 0:
                        break
                    dd -= 1
                elif dd == 0 and (is_op(z, ";", ",") or z.kind == "keyword" and z.text in ("const", "var")):
                    break
                j -= 1
            if j >= 0 and toks[j].kind == "keyword" and toks[j].text in ("const", "var") and j + 1 < n \
                    and toks[j + 1].kind == "identifier":
                name, naming, head = toks[j + 1].text, "declaration", j
        elif h >= 0 and toks[h].kind == "keyword" and toks[h].text == "return":
            holders = [b for b in type_fns if b[0] < q < b[1]]
            name, naming, head = (holders[0][2] if holders else "(anonymous)"), "return", h
        elif h >= 0 and toks[h].kind == "keyword" and toks[h].text == "else":
            # an if's other branch: the declaration the if-else initializes (`const NAME = if (c) A else struct {`)
            j, dd, decl = h - 1, 0, None
            while j >= 2:
                z = toks[j]
                if is_op(z, ")", "]", "}"):
                    dd += 1
                elif is_op(z, "(", "[", "{"):
                    if dd == 0:
                        break
                    dd -= 1
                elif dd == 0 and is_op(z, ";"):
                    break
                elif dd == 0 and is_op(z, "=") and toks[j - 1].kind == "identifier" and toks[j - 2].kind == "keyword" \
                        and toks[j - 2].text in ("const", "var"):
                    decl = toks[j - 1].text
                    break
                j -= 1
            name, naming, head = (decl or last_name or "(anonymous)"), "else", h
        last_name = name
        out.append(dict(kind=x.text, name=name, naming=naming, head=head, open=r, close=min(match_paren(toks, r), n - 1)))
    return out
