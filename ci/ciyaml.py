r"""r42 (round 41's Sol M1, Opus M2 and the lead's direction, item 4): a strict reader of a closed YAML subset, for the
residue gate's CI check (residue_gate14.py loads this section; installed beside it). It reads a workflow or action file
into nested block mappings (CiMap) and sequences (CiSeq), flow collections (plain dicts and lists) and scalars
(CiScalar), or refuses it (CiRefuse: a line and a reason). Refused anywhere in the file: a tab in the indentation, a
byte-order mark, a directive, more than one document, a top-level flow collection (the JSON form), an anchor, an alias,
a merge key, a tag, a `?` key, a quoted key, a key holding a flow indicator, a duplicate key in one mapping, a case
variant of `jobs`, `steps`, `uses`, `with`, `version` or `id`, a double-quoted scalar holding a backslash escape, a
quoted scalar that does not close on its line, a multi-line plain scalar, a nested sequence on one line, a reserved
indicator (`@`, a backquote, `%`), an unexpected indentation. A flow collection, or a block scalar, is allowed only as
the value of a key the caller names (FLOW_KEYS, BLOCK_KEYS: what the seven trees use), never as a sequence item, a job,
a step, or the value of `jobs`, `steps`, `with`, `uses`, `version` or `id`. Comments are not content (a `#` at a
token's start, after whitespace, outside quotes); inside a block scalar a `#` is content. Each sequence item keeps its
source lines (`spans`), from which `step_text` gives a step's text: its lines, comments and trailing blanks removed,
dedented to its dash, so the residue gate can pin a step by its sha256.
r43 (round 42's Sol M1, M3, Opus M1, L3 and the lead's direction, items 1 and 3): the accepted characters are closed
too. Line breaks are LF or CR LF only: a CR not followed by LF, a NEL (U+0085), a line separator (U+2028), a paragraph
separator (U+2029), a byte-order mark anywhere, any other C0 control and DEL are refused, each at its line, before any
line is read (r42 split on LF alone, so after a ` #` a lone CR, NEL, LS or PS turned the rest of the LF line into a
comment and hid whole steps). A tab is allowed only inside a block scalar's content or a comment. Every key, block or
flow, is [A-Za-z0-9_-]+ (ASCII), which a key like `ver\N{LATIN SMALL LETTER LONG S}ion` fails. Non-ASCII text is
allowed in values. classify_uses gives a `uses` value's form, the only three accepted: a local path, `./` and segments
of [A-Za-z0-9._-]+ joined by `/` (no `@`, no backslash, no empty, `.` or `..` segment), read whole; a remote
owner/repo[/path]@ref, ASCII; or docker://. Anything else, and any other value starting with `.` or holding a
backslash, is refused.
r44 (round 43's Opus L1 and the lead's direction, item 5): no string operation here is Unicode-aware. YAML's white
space is a space and a tab only, so every strip strips those two (r43 stripped Python's Unicode white space: a line
whose content began with U+3000 and `#` was a comment here and run text to YAML), every `\s` is `[ \t]`, and a key's
case is lowered by ASCII alone. Usage (a check of one file): python -I ciyaml.py <file>"""
import re
import sys

CI_KEYWORDS = ("jobs", "steps", "uses", "with", "version", "id")
NEVER_FLOW = frozenset(CI_KEYWORDS)
# r42: where the seven trees use a flow collection or a block scalar as a value (measure_inputs42.py, every CI file of
# the fork head, both 1A trial results, the stone, both 1B proxies and v1.4.0), as key paths: a job id is <job>, a
# sequence item []; nothing else is allowed
FLOW_PATHS = frozenset((
    "github", "labels", "permissions", "on", "on.push", "on.pull_request", "on.workflow_dispatch", "on.push.branches",
    "on.discussion_comment.types", "on.issue_comment.types", "on.issues.types", "on.pull_request_target.types",
    "on.workflow_run.branches", "on.workflow_run.types", "on.workflow_run.workflows", "jobs.<job>.needs",
    "jobs.<job>.runs-on", "jobs.<job>.strategy.matrix.i18n", "jobs.<job>.strategy.matrix.os",
    "jobs.<job>.strategy.matrix.pkg", "jobs.<job>.strategy.matrix.sentry", "jobs.<job>.strategy.matrix.simd",
    "jobs.<job>.strategy.matrix.target", "jobs.<job>.strategy.matrix.wayland", "jobs.<job>.strategy.matrix.x11"))
BLOCK_PATHS = frozenset((
    "body.[].attributes.description", "body.[].attributes.placeholder", "body.[].attributes.value",
    "body.[].attributes.options.[].label", "jobs.<job>.if", "jobs.<job>.steps.[].if", "jobs.<job>.steps.[].run",
    "jobs.<job>.steps.[].with.add-paths", "jobs.<job>.steps.[].with.body", "jobs.<job>.steps.[].with.build-args",
    "jobs.<job>.steps.[].with.cache", "jobs.<job>.steps.[].with.command", "jobs.<job>.steps.[].with.files",
    "jobs.<job>.steps.[].with.filters", "jobs.<job>.steps.[].with.path", "jobs.<job>.steps.[].with.subject-path",
    "runs.steps.[].run"))


def key_path(path):
    """A value's key path as the lists name it: the key after a top-level `jobs` is <job>."""
    return ".".join("<job>" if k == 1 and path[0] == "jobs" else p_ for k, p_ in enumerate(path))


class CiRefuse(Exception):
    def __init__(self, line, why):
        super().__init__(f"line {line}: {why}")
        self.line, self.why = line, why


class CiScalar(str):
    """A scalar value: its text and its style ("plain", "single", "double", "block")."""
    def __new__(cls, text, style, line):
        s = str.__new__(cls, text)
        s.style, s.line = style, line
        return s


class CiMap(dict):
    """A block mapping: key -> value, with each key's line (`lines`) and its own first line."""
    def __init__(self, line):
        super().__init__()
        self.lines, self.line = {}, line


class CiSeq(list):
    """A block sequence: its items, each with the (first, last) line of its source (`spans`)."""
    def __init__(self, line):
        super().__init__()
        self.spans, self.line = [], line


_EMPTY = object()
# r43: the characters a CI file may not hold anywhere (a CR only before an LF)
_BAD_CHARS = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\x85\N{LINE SEPARATOR}\N{PARAGRAPH SEPARATOR}"
                        "\N{ZERO WIDTH NO-BREAK SPACE}]|\r(?!\n)")
_CHAR_NAMES = {"\r": "a carriage return not followed by a line feed", "\x85": "a next-line character (NEL, U+0085)",
               "\N{LINE SEPARATOR}": "a line separator (U+2028)", "\N{PARAGRAPH SEPARATOR}": "a paragraph separator (U+2029)",
               "\N{ZERO WIDTH NO-BREAK SPACE}": "a byte-order mark", "\x7f": "a delete character (U+007F)"}
_KEY = re.compile(r"[A-Za-z0-9_-]+")   # r43: every key, ASCII
WS = " \t"   # r44: YAML's white space, the only characters a strip removes
_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


def lower_ascii(s):
    """r44: s with A-Z lowered and every other character kept (str.lower is Unicode-aware)."""
    return s.translate(_ASCII_LOWER)
LOCAL_USES = re.compile(r"\./[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*")
REMOTE_USES = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[A-Za-z0-9_./-]+")
DOCKER_USES = re.compile(r"docker://[A-Za-z0-9_./:@+-]+")


def classify_uses(u):
    """r43: a `uses` value's form: ("local", its path after `./`, whole), ("remote", None) or ("docker", None); or
    (None, the reason it is refused)."""
    if LOCAL_USES.fullmatch(u):
        if any(s_ in (".", "..") for s_ in u[2:].split("/")):
            return None, "a local path with a `.` or `..` segment"
        return "local", u[2:]
    if u.startswith(".") or "\\" in u:
        return None, "a local path that is not `./` and segments of [A-Za-z0-9._-] joined by `/`"
    if REMOTE_USES.fullmatch(u):
        return "remote", None
    if DOCKER_USES.fullmatch(u):
        return "docker", None
    return None, "a uses value that is no local path, no remote owner/repo[/path]@ref and no docker:// image"


class Reader:
    def __init__(self, text, flow_keys=None, block_keys=None, record=None):
        """`flow_keys`, `block_keys`: the keys whose value may be a flow collection or a block scalar (None: any, for
        measurement, when each use is appended to `record` as (kind, key path))."""
        bad = _BAD_CHARS.search(text)   # r43: the characters first, before any line is read
        if bad:
            c_ = bad.group(0)
            raise CiRefuse(text.count("\n", 0, bad.start()) + 1,
                           _CHAR_NAMES.get(c_, f"a control character (U+{ord(c_):04X})"))
        if text.startswith("\ufeff"):
            raise CiRefuse(1, "a byte-order mark")
        self.raw = [l[:-1] if l.endswith("\r") else l for l in text.split("\n")]
        self.flow_keys, self.block_keys, self.record = flow_keys, block_keys, record
        self.n = len(self.raw)
        self.bs = set()

    # ---- lines
    def indent(self, i):
        l = self.raw[i]
        k = len(l) - len(l.lstrip(" "))
        if l[k:k + 1] == "\t" or ("\t" in l[:k]):
            raise CiRefuse(i + 1, "a tab in the indentation")
        return k

    def blank(self, i):
        s = self.raw[i].strip(WS)
        return not s or s.startswith("#")

    def next_content(self, i):
        while i < self.n and self.blank(i):
            i += 1
        return i

    # ---- tokens
    @staticmethod
    def _quoted_end(s, k, line):
        """The index after the quoted scalar starting at s[k], refusing an escape or an unclosed one."""
        q = s[k]
        j = k + 1
        while j < len(s):
            if q == '"' and s[j] == "\\":
                raise CiRefuse(line, "a backslash escape in a double-quoted scalar")
            if s[j] == q:
                if q == "'" and s[j + 1:j + 2] == "'":
                    j += 2
                    continue
                return j + 1
            j += 1
        raise CiRefuse(line, "a quoted scalar that does not close on its line")

    def _split_entry(self, s, line):
        """(key, rest) when s is a mapping entry `key: rest` (a `:` followed by a space or the line's end, outside
        quotes and brackets, before a comment), else None."""
        j, depth = 0, 0
        while j < len(s):
            c = s[j]
            if c in "\"'" and (j == 0 or s[j - 1] in " \t[{,"):
                j = self._quoted_end(s, j, line)
                continue
            if c == "#" and (j == 0 or s[j - 1] in " \t"):
                return None
            if c in "[{":
                depth += 1
            elif c in "]}":
                depth -= 1
            elif c == ":" and depth == 0 and (j + 1 == len(s) or s[j + 1] in " \t"):
                return s[:j].rstrip(WS), s[j + 1:]
            j += 1
        return None

    def _check_key(self, key, line, m):
        if not key:
            raise CiRefuse(line, "an empty key")
        if key[0] in "\"'":
            raise CiRefuse(line, "a quoted key")
        if key.startswith("?"):
            raise CiRefuse(line, "a `?` key")
        if key.startswith("<<"):
            raise CiRefuse(line, "a merge key")
        if key[0] in "&*!":
            raise CiRefuse(line, "an anchor, alias or tag on a key")
        if key[0] in "@`%|>-":
            raise CiRefuse(line, f"a key beginning with an indicator ({key[0]})")
        if any(c in key for c in "{}[],#"):
            raise CiRefuse(line, "a key holding a flow indicator or a comment mark")
        if not _KEY.fullmatch(key):   # r43
            raise CiRefuse(line, "a key outside [A-Za-z0-9_-] (ASCII)")
        if lower_ascii(key) in CI_KEYWORDS and key != lower_ascii(key):
            raise CiRefuse(line, f"a case variant of `{lower_ascii(key)}`")
        if key in m:
            raise CiRefuse(line, f"a duplicate key `{key}`")

    def _scalar(self, s, line):
        """The value of a one-line scalar token s (stripped), or a refusal; returns (CiScalar, rest after it)."""
        c0 = s[0]
        if c0 == "&":
            raise CiRefuse(line, "an anchor")
        if c0 == "*":
            raise CiRefuse(line, "an alias")
        if c0 == "!":
            raise CiRefuse(line, "a tag")
        if c0 in "@`%":
            raise CiRefuse(line, f"a reserved indicator ({c0})")
        if c0 in "\"'":
            e = self._quoted_end(s, 0, line)
            body = s[1:e - 1]
            if c0 == "'":
                body = body.replace("''", "'")
            return CiScalar(body, "double" if c0 == '"' else "single", line), s[e:]
        k = 0
        while k < len(s):
            if s[k] == "#" and k > 0 and s[k - 1] in " \t":
                break
            k += 1
        v = s[:k].rstrip(WS)
        if re.search(r":([ \t]|$)", v):
            raise CiRefuse(line, "a `: ` inside a plain scalar")
        return CiScalar(v, "plain", line), s[k:]

    @staticmethod
    def _rest_ok(rest, line):
        r = rest.strip(WS)
        if r and not r.startswith("#"):
            raise CiRefuse(line, f"text after a value ({r[:20]})")

    # ---- flow collections (may span lines)
    def _flow(self, i, col):
        """Parses the flow collection starting at raw line i, column col; returns (value, the index of its last line)."""
        line_ = i

        def peek():
            nonlocal i, col
            while True:
                if i >= self.n:
                    raise CiRefuse(line_ + 1, "an unclosed flow collection")
                s = self.raw[i]
                while col < len(s) and s[col] in " \t":
                    col += 1
                if col >= len(s) or (s[col] == "#" and (col == 0 or s[col - 1] in " \t")):
                    i, col = i + 1, 0
                    continue
                return s[col]

        def node():
            nonlocal col
            c = peek()
            if c == "{":
                col += 1
                d = {}
                while True:
                    if peek() == "}":
                        col += 1
                        return d
                    k_ = atom(key=True)
                    if peek() != ":":
                        raise CiRefuse(i + 1, "a flow mapping entry without a `:`")
                    col += 1
                    v_ = node()
                    if k_ in d:
                        raise CiRefuse(i + 1, f"a duplicate key `{k_}`")
                    d[k_] = v_
                    c2 = peek()
                    if c2 == ",":
                        col += 1
                    elif c2 != "}":
                        raise CiRefuse(i + 1, "a flow mapping that does not continue or close")
            if c == "[":
                col += 1
                a = []
                while True:
                    if peek() == "]":
                        col += 1
                        return a
                    a.append(node())
                    c2 = peek()
                    if c2 == ",":
                        col += 1
                    elif c2 != "]":
                        raise CiRefuse(i + 1, "a flow sequence that does not continue or close")
            return atom()

        def atom(key=False):
            nonlocal col
            s = self.raw[i]
            c = s[col]
            if c in "&*!?@`%|>":
                raise CiRefuse(i + 1, f"an indicator in a flow collection ({c})")
            if c in "\"'":
                if key:
                    raise CiRefuse(i + 1, "a quoted key")
                e = self._quoted_end(s, col, i + 1)
                body = s[col + 1:e - 1]
                if c == "'":
                    body = body.replace("''", "'")
                col = e
                return CiScalar(body, "double" if c == '"' else "single", i + 1)
            k = col
            while k < len(s) and s[k] not in ",]}" and not (s[k] == ":" and (k + 1 == len(s) or s[k + 1] in " \t,]}")) \
                    and not (s[k] == "#" and s[k - 1] in " \t"):
                if s[k] in "[{":
                    raise CiRefuse(i + 1, "a flow indicator inside a plain scalar")
                k += 1
            v = s[col:k].strip(WS)
            col = k
            if key and not _KEY.fullmatch(v):   # r43
                raise CiRefuse(i + 1, "a key outside [A-Za-z0-9_-] (ASCII)")
            if key and lower_ascii(v) in CI_KEYWORDS and v != lower_ascii(v):
                raise CiRefuse(i + 1, f"a case variant of `{lower_ascii(v)}`")
            return CiScalar(v, "plain", i + 1)

        v = node()
        self._rest_ok(self.raw[i][col:], i + 1)
        return v, i

    # ---- block scalars
    def _block_scalar(self, i, parent_indent, header):
        if not re.fullmatch(r"[|>][-+]?[1-9]?[-+]?[ \t]*(#.*)?", header.strip(WS)):
            raise CiRefuse(i + 1, "a block scalar header the subset does not read")
        j, body = i + 1, []
        while j < self.n:
            l = self.raw[j]
            if l.strip(WS) and len(l) - len(l.lstrip(" ")) <= parent_indent:
                break
            body.append(l)
            j += 1
        while body and not body[-1].strip(WS):
            body.pop()
            j -= 1
        self.bs.update(range(i + 1, j))   # its lines: content, where a `#` is no comment
        return CiScalar("\n".join(body), "block", i + 1), j - 1

    # ---- values
    def _allowed(self, kind, path):
        key = path[-1] if path else ""
        if key in NEVER_FLOW or key == "[]" or not path:
            raise CiRefuse(0, f"a {kind} as the value of `{key or 'the document'}`")
        allow = self.flow_keys if kind == "flow collection" else self.block_keys
        if allow is None:
            if self.record is not None:
                self.record.append((kind, ".".join(path)))
            return
        if key_path(path) not in allow:
            raise CiRefuse(0, f"a {kind} as the value of `{key_path(path)}`, which the subset does not allow")

    def _value(self, i, col, s, ind, path):
        """The value whose text s starts on raw line i at column col, for a key or item at indentation ind; returns
        (value, the index of the value's last line)."""
        st = s.strip(WS)
        if not st or st.startswith("#"):
            return _EMPTY, i
        if st[0] in "{[":
            try:
                self._allowed("flow collection", path)
            except CiRefuse as e:
                raise CiRefuse(i + 1, e.why)
            return self._flow(i, col + (len(s) - len(s.lstrip(WS))))
        if st[0] in "|>":
            try:
                self._allowed("block scalar", path)
            except CiRefuse as e:
                raise CiRefuse(i + 1, e.why)
            return self._block_scalar(i, ind, st)
        v, rest = self._scalar(st, i + 1)
        self._rest_ok(rest, i + 1)
        return v, i

    # ---- the block structure
    def parse(self):
        i = self.next_content(0)
        if i < self.n and self.raw[i].startswith("%"):
            raise CiRefuse(i + 1, "a directive")
        if i < self.n and re.fullmatch(r"---[ \t]*(#.*)?", self.raw[i]):
            i = self.next_content(i + 1)
        for j in range(i, self.n):
            if re.fullmatch(r"(---|\.\.\.)([ \t].*)?", self.raw[j]):
                raise CiRefuse(j + 1, "more than one document")
        if i >= self.n:
            return None
        if self.raw[i].lstrip(WS)[:1] in "{[":
            raise CiRefuse(i + 1, "a top-level flow collection (the JSON form)")
        if self.indent(i) != 0:
            raise CiRefuse(i + 1, "a document that does not start at column 0")
        node, j = self._block(i, 0, [])
        j = self.next_content(j + 1)
        if j < self.n:
            raise CiRefuse(j + 1, "text after the document's end, or an unexpected indentation")
        for k_, l_ in enumerate(self.raw):   # r43: a tab only in a block scalar's content or a comment
            if k_ not in self.bs and "\t" in _strip_comment(l_):
                raise CiRefuse(k_ + 1, "a tab outside a block scalar's content or a comment")
        return node

    def _is_item(self, s):
        return s == "-" or s.startswith("- ")

    def _block(self, i, ind, path):
        s = self.raw[i][ind:]
        if self._is_item(s):
            return self._seq(i, ind, path)
        if path and self._split_entry(s, i + 1) is None:   # a key's value on the line after it (a flow collection
            v, last = self._value(i, ind, s, ind - 1, path)   # or a one-line scalar, under the same rules)
            if v is _EMPTY:
                raise CiRefuse(i + 1, "an empty value line")
            k = self.next_content(last + 1)
            if k < self.n and self.indent(k) >= ind:
                raise CiRefuse(k + 1, "a value that continues past its line (a multi-line plain scalar)")
            return v, last
        return self._map(i, ind, ind, path, None)

    def _map(self, i, ind, col, path, first):
        """A block mapping whose keys sit at column `col` (its first entry on raw line i at that column; `first`, when
        given, the text of that entry, the rest of a sequence item's line)."""
        m = CiMap(i + 1)
        while True:
            s = first if first is not None else self.raw[i][col:]
            first = None
            if self._is_item(s):
                raise CiRefuse(i + 1, "a sequence item where a mapping key belongs")
            e = self._split_entry(s, i + 1)
            if e is None:
                raise CiRefuse(i + 1, "a line that is neither a mapping entry nor a sequence item")
            key, rest = e
            self._check_key(key, i + 1, m)
            vcol = col + len(s) - len(rest)
            v, last = self._value(i, vcol, rest, col, path + [key])
            if v is _EMPTY:
                k = self.next_content(last + 1)
                if k < self.n and self.indent(k) > col:
                    v, last = self._block(k, self.indent(k), path + [key])
                elif k < self.n and self.indent(k) == col and self._is_item(self.raw[k][col:]):
                    v, last = self._seq(k, col, path + [key])   # an indentless sequence
                else:
                    v = None
            m[key], m.lines[key] = v, i + 1
            k = self.next_content(last + 1)
            if k >= self.n or self.indent(k) < col:
                return m, last
            if self.indent(k) > col:
                raise CiRefuse(k + 1, "an unexpected indentation (a multi-line plain scalar, or a misplaced line)")
            if self._is_item(self.raw[k][col:]):
                return m, last   # an indentless sequence's parent mapping ends here, or the enclosing item continues
            i = k

    def _seq(self, i, ind, path):
        a = CiSeq(i + 1)
        while True:
            s = self.raw[i][ind:]
            rest = s[1:]
            body_col = ind + 1 + (len(rest) - len(rest.lstrip(" ")))
            rest = rest.lstrip(" ")
            start = i
            if not rest or rest.startswith("#"):
                k = self.next_content(i + 1)
                if k < self.n and self.indent(k) > ind:
                    v, last = self._block(k, self.indent(k), path + ["[]"])
                else:
                    v, last = None, i
            elif self._is_item(rest):
                raise CiRefuse(i + 1, "a nested sequence on one line")
            elif self._split_entry(rest, i + 1) is not None:
                v, last = self._map(i, ind, body_col, path + ["[]"], rest)
            else:
                if rest[0] in "{[" or rest[0] in "|>":
                    raise CiRefuse(i + 1, "a flow collection or a block scalar as a sequence item")
                v, r_ = self._scalar(rest, i + 1)
                self._rest_ok(r_, i + 1)
                last = i
            a.append(v)
            a.spans.append((start + 1, last + 1))
            k = self.next_content(last + 1)
            if k >= self.n or self.indent(k) < ind:
                return a, last
            if self.indent(k) > ind:
                raise CiRefuse(k + 1, "an unexpected indentation in a sequence")
            if not self._is_item(self.raw[k][ind:]):
                return a, last
            i = k

    def step_text(self, span):
        """A sequence item's text as the reader gives it: its source lines (first..last, 1-based), each without its
        comment (none in a block scalar's lines, whose `#` is content) and trailing blanks, comment-only and blank lines
        dropped, dedented to the item's dash."""
        first, last = span
        dash = len(self.raw[first - 1]) - len(self.raw[first - 1].lstrip(" "))
        out = []
        for k in range(first - 1, last):
            l = self.raw[k]
            body = l[dash:] if len(l) - len(l.lstrip(" ")) >= dash else l.lstrip(" ")
            out.append((body if k in self.bs else _strip_comment(body)).rstrip(WS))
        return "\n".join(x for x in out if x.strip(WS)) + "\n"


def _strip_comment(s):
    """s without its YAML comment (a `#` at the start or after whitespace, outside quotes)."""
    j, q = 0, None
    while j < len(s):
        c = s[j]
        if q:
            if c == q:
                if q == "'" and s[j + 1:j + 2] == "'":
                    j += 2
                    continue
                q = None
        elif c in "\"'" and (j == 0 or s[j - 1] in " \t[{,:"):
            q = c
        elif c == "#" and (j == 0 or s[j - 1] in " \t"):
            return s[:j]
        j += 1
    return s


def read(text, flow_keys=FLOW_PATHS, block_keys=BLOCK_PATHS, record=None):
    """(the document, the Reader) for a file's text, or CiRefuse (the measured lists by default; None: any, recorded)."""
    r = Reader(text, flow_keys, block_keys, record)
    return r.parse(), r


if __name__ == "__main__":
    rec = []
    try:
        doc, _ = read(open(sys.argv[1], encoding="utf-8").read())
        print("read", type(doc).__name__, rec)
    except CiRefuse as e:
        print("REFUSED", e)
