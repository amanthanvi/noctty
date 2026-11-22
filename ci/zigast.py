r"""zigast (r39, round 38's lead direction, items 1 and 2): Zig's own parse of each source file, for the residue gate and
the binding check, which take every structure from it. astdump.zig (std.zig.Ast, built with the compiler the tree is
pinned to) writes each file's tokens and nodes; this module runs it, reads its dump and checks the dump before any
tool uses it:
- TILING: every node but the root has exactly one parent, the walk from the root reaches every node once, and each
  node's children lie inside its token span, in order, without overlapping (the tokens no child covers are the node's
  own); the root spans every token. A dump that fails any of these is not used (AST-TILING).
- TOKENS: zigtok.py's token stream (every token but `//` comments, read with the same compiler's dialect) equals the
  compiler's tokens one for one: the same byte start, the same byte end and the same kind (AST-TOKENS), so a tool that
  reads zigtok's tokens reads the tokens the parser's nodes point at.
- UNPARSEABLE: a file the pinned compiler's parser rejects, or one astdump could not read, has no AST; a tool that
  needs it fails the file (the user's decision after r39's blocker report: the gate reads only what the tree's pinned
  compiler parses).
- From r40 (round 39's Opus L1, L2): a node listed twice is a TILING problem (r39 read the second over the first);
  ROLES: every node's children, in token order, must carry the roles ROLE_TABLE names for its tag, in that order and
  in those counts (the table is astdump.zig's walk written out; a tag it does not name is a problem), since the tiling
  cannot see a mislabelled role (AST-ROLES); and the dump's header names the compiler that built astdump, which the
  residue gate and the binding check compare with the tree's pin (`compiler`, `pinned_series`).
- From r43 (round 42's Sol M2, Opus M2 and the lead's direction, item 2): the pin is read from Zig's tokens by one
  function, `read_pin`, which the residue gate and the binding check both call (`pinned_series` reads through it):
  comments are not tokens, so a comment never supplies the field; a quoted `@"..."` identifier, a backslash in a string
  or character literal, a multiline string literal, a root that is no `.{ ... }` of `.name = value` fields, a
  duplicate root field, or a minimum_zig_version that is not exactly one root field holding one plain string literal
  with a version in it, is refused (the caller's BAD-SETUP), as are a NUL and invalid UTF-8.
Usage: python -I -B zigast.py <dump file> (checks every file of a dump: prints one line per
problem file and a summary)."""
import importlib.util
import os
import subprocess
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
_zs = importlib.util.spec_from_file_location("zigtok", os.path.join(_here, "zigtok.py"))
zigtok = importlib.util.module_from_spec(_zs)
_zs.loader.exec_module(zigtok)

# the compiler's token tags, as zigtok's kinds
KIND_OF = {"identifier": "identifier", "builtin": "builtin", "number_literal": "number", "string_literal": "string",
           "char_literal": "char", "multiline_string_literal_line": "mlstring", "doc_comment": "doc_comment",
           "container_doc_comment": "container_doc_comment"}
NOT_OPS = frozenset(("invalid", "invalid_periodasterisks", "eof"))
FORMAT = "astdump 3"
INF = 1 << 30
_UNARY = ("defer", "bool_not", "negation", "bit_not", "negation_wrap", "address_of", "try", "optional_type", "deref",
          "suspend", "resume", "comptime", "nosuspend", "errdefer", "grouped_expression", "asm_input")
_BINARY = ("catch", "equal_equal", "bang_equal", "less_than", "greater_than", "less_or_equal", "greater_or_equal",
           "assign_mul", "assign_div", "assign_mod", "assign_add", "assign_sub", "assign_shl", "assign_shl_sat",
           "assign_shr", "assign_bit_and", "assign_bit_xor", "assign_bit_or", "assign_mul_wrap", "assign_add_wrap",
           "assign_sub_wrap", "assign_mul_sat", "assign_add_sat", "assign_sub_sat", "assign", "merge_error_sets", "mul",
           "div", "mod", "mul_wrap", "mul_sat", "add", "sub", "array_cat", "add_wrap", "sub_wrap", "add_sat",
           "sub_sat", "shl", "shl_sat", "shr", "bit_and", "bit_xor", "bit_or", "orelse", "bool_and", "bool_or",
           "switch_range", "error_union", "array_mult")
_LEAVES = ("identifier", "number_literal", "char_literal", "string_literal", "multiline_string_literal",
           "enum_literal", "error_value", "unreachable_literal", "error_set_decl", "anyframe_literal")
_VARDECL = ("global_var_decl", "local_var_decl", "simple_var_decl", "aligned_var_decl")
_PTR = ("ptr_type_aligned", "ptr_type_sentinel", "ptr_type", "ptr_type_bit_range")
_ARRAYINIT = ("array_init_one", "array_init_one_comma", "array_init_dot_two", "array_init_dot_two_comma",
              "array_init_dot", "array_init_dot_comma", "array_init", "array_init_comma")
_STRUCTINIT = ("struct_init_one", "struct_init_one_comma", "struct_init_dot_two", "struct_init_dot_two_comma",
               "struct_init_dot", "struct_init_dot_comma", "struct_init", "struct_init_comma")
_CONTAINER = ("container_decl", "container_decl_trailing", "container_decl_two", "container_decl_two_trailing",
              "container_decl_arg", "container_decl_arg_trailing", "tagged_union", "tagged_union_trailing",
              "tagged_union_two", "tagged_union_two_trailing", "tagged_union_enum_tag",
              "tagged_union_enum_tag_trailing")
# r40 (round 39's Opus L2): astdump.zig's walk (`Walk.children`) written out: for each tag, the roles of its children in
# token order, each (role, fewest, most). A node whose children do not match its tag's row, or whose tag has no row,
# is an AST-ROLES problem.
ROLE_TABLE = {
    "root": (("member", 0, INF),),
    **{t: () for t in _LEAVES},
    **{t: (("operand", 1, 1),) for t in _UNARY},
    **{t: (("lhs", 1, 1), ("rhs", 1, 1)) for t in _BINARY},
    "array_type": (("len", 1, 1), ("elem_type", 1, 1)),
    "array_access": (("object", 1, 1), ("index", 1, 1)),
    "fn_decl": (("proto", 1, 1), ("body", 1, 1)),
    "field_access": (("object", 1, 1),), "unwrap_optional": (("object", 1, 1),),
    "return": (("operand", 0, 1),), "break": (("operand", 0, 1),), "continue": (("operand", 0, 1),),
    "test_decl": (("body", 1, 1),),
    "anyframe_type": (("type", 1, 1),),
    "for_range": (("start", 1, 1), ("end", 0, 1)),
    **{t: (("type", 0, 1), ("align", 0, 1), ("addrspace", 0, 1), ("section", 0, 1), ("init", 0, 1)) for t in _VARDECL},
    "assign_destructure": (("target", 1, INF), ("value", 1, 1)),
    "array_type_sentinel": (("len", 1, 1), ("sentinel", 0, 1), ("elem_type", 1, 1)),
    **{t: (("sentinel", 0, 1), ("align", 0, 1), ("bit_start", 0, 1), ("bit_end", 0, 1), ("addrspace", 0, 1),
           ("elem_type", 1, 1)) for t in _PTR},
    **{t: (("object", 1, 1), ("start", 1, 1), ("end", 0, 1), ("sentinel", 0, 1)) for t in ("slice_open", "slice",
                                                                                           "slice_sentinel")},
    **{t: (("type", 0, 1), ("elem", 0, INF)) for t in _ARRAYINIT},
    **{t: (("type", 0, 1), ("field", 0, INF)) for t in _STRUCTINIT},
    **{t: (("callee", 1, 1), ("arg", 0, INF)) for t in ("call_one", "call_one_comma", "call", "call_comma")},
    **{t: (("cond", 1, 1), ("case", 0, INF)) for t in ("switch", "switch_comma")},
    **{t: (("item", 0, INF), ("target", 1, 1)) for t in ("switch_case_one", "switch_case_inline_one", "switch_case",
                                                          "switch_case_inline")},
    **{t: (("cond", 1, 1), ("cont", 0, 1), ("then", 1, 1), ("else", 0, 1)) for t in ("while_simple", "while_cont",
                                                                                     "while")},
    **{t: (("input", 1, INF), ("then", 1, 1), ("else", 0, 1)) for t in ("for_simple", "for")},
    **{t: (("cond", 1, 1), ("then", 1, 1), ("else", 0, 1)) for t in ("if_simple", "if")},
    **{t: (("param", 0, INF), ("align", 0, 1), ("addrspace", 0, 1), ("section", 0, 1), ("callconv", 0, 1),
           ("ret", 0, 1)) for t in ("fn_proto_simple", "fn_proto_multi", "fn_proto_one", "fn_proto")},
    **{t: (("arg", 0, INF),) for t in ("builtin_call_two", "builtin_call_two_comma", "builtin_call",
                                       "builtin_call_comma")},
    **{t: (("arg", 0, 1), ("member", 0, INF)) for t in _CONTAINER},
    **{t: (("type", 0, 1), ("align", 0, 1), ("value", 0, 1)) for t in ("container_field_init",
                                                                       "container_field_align", "container_field")},
    **{t: (("stmt", 0, INF),) for t in ("block_two", "block_two_semicolon", "block", "block_semicolon")},
    **{t: (("template", 1, 1), ("asm_item", 0, INF), ("clobbers", 0, 1)) for t in ("asm_simple", "asm",
                                                                                  "asm_legacy")},
    "asm_output": (("type", 0, 1),),
}


def kind_of(tag):
    if tag in KIND_OF:
        return KIND_OF[tag]
    if tag.startswith("keyword_"):
        return "keyword"
    return None if tag in NOT_OPS else "op"


class FileAst:
    """One file's dump: `tokens` [(tag, start, end)], `nodes` {index: Node}, `children` {index: [child indices in
    token order]}, `errors` (parse errors) and `first_error`, `problems` (astdump's X lines), `unreadable`, `full`
    (whether tokens and nodes were asked for)."""
    __slots__ = ("path", "tokens", "nodes", "children", "errors", "problems", "unreadable", "node_count", "reached",
                 "first_error", "full", "twice")

    def __init__(self, path):
        self.path, self.tokens, self.nodes, self.children = path, [], {}, {}
        self.errors, self.problems, self.unreadable, self.node_count, self.reached = 0, [], False, 0, 0
        self.first_error, self.full, self.twice = None, False, []

    @property
    def parsed(self):
        return not self.unreadable and not self.errors


class Node:
    """A node: its index, tag, main, first and last token, parent index, role in the parent, and extra keys (`pay`,
    `err`, `lbl`, `name`, `mut`, `ct`, `tuple`: token indices or flags; `p`: [(name token, type node)])."""
    __slots__ = ("i", "tag", "main", "first", "last", "parent", "role", "x")

    def __init__(self, i, tag, main, first, last, parent, role="", x=None):
        self.i, self.tag, self.main, self.first, self.last, self.parent = i, tag, main, first, last, parent
        self.role, self.x = role, x or {}

    def __repr__(self):
        return f"Node({self.i}, {self.tag}, tokens {self.first}-{self.last})"


class Dump(dict):
    """{source path as astdump wrote it: FileAst}, `dialect`, the zigtok dialect of the Ast that wrote it, and from r40
    `compiler`, the version of the compiler that built astdump (the header's last field)."""
    dialect = None
    compiler = None


DIALECT_OF = {"legacy": "0.15.2", "current": "0.17.1"}


def read_dump(path):
    """The dump's files (a Dump)."""
    out, cur, mode = Dump(), None, None
    with open(path, encoding="utf-8", newline="") as fh:
        head = fh.readline().rstrip().split(" ")
        if " ".join(head[:2]) != FORMAT or len(head) != 4 or head[2] not in DIALECT_OF:
            raise ValueError(f"not an {FORMAT} file: {path}")
        out.dialect, out.compiler = DIALECT_OF[head[2]], head[3]
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("F "):
                cur = FileAst(line[2:])
                out[cur.path] = cur
                mode = None
            elif line == "R":
                cur.unreadable = True
            elif line.startswith("P "):
                p_ = line[2:].split(" ")
                cur.errors = int(p_[0])
                if len(p_) == 3:
                    cur.first_error = (p_[1], int(p_[2]))
            elif line.startswith("K "):
                mode = "K"
                cur.full = True
            elif line.startswith("N "):
                a, b = line[2:].split(" ")
                cur.node_count, cur.reached = int(a), int(b)
                mode = "N"
            elif line.startswith("X "):
                cur.problems.append(line[2:])
            elif line == "E":
                for nd in cur.nodes.values():
                    if nd.parent >= 0:
                        cur.children.setdefault(nd.parent, []).append(nd.i)
                for k in cur.children:
                    cur.children[k].sort(key=lambda i: cur.nodes[i].first)
                cur, mode = None, None
            elif mode == "K":
                tag, s, e = line.split(" ")
                cur.tokens.append((tag, int(s), int(e)))
            elif mode == "N":
                p = line.split(" ")
                x = {}
                for kv in p[7:]:
                    k_, _, v_ = kv.partition("=")
                    if k_ == "p":
                        a_, _, b_ = v_.partition("/")
                        x.setdefault("p", []).append((int(a_), int(b_)))
                    else:
                        x[k_] = int(v_)
                if int(p[0]) in cur.nodes:   # r40 (round 39's Opus L2): a node listed twice
                    cur.twice.append(int(p[0]))
                cur.nodes[int(p[0])] = Node(int(p[0]), p[1], int(p[2]), int(p[3]), int(p[4]), int(p[5]), p[6], x)
    return out


def run_astdump(exe, paths, status_only, work):
    """Runs astdump on `paths` (each in `status_only`, a set, gets its parse result alone) and reads its dump."""
    os.makedirs(work, exist_ok=True)
    lst, out = os.path.join(work, "astdump-list.txt"), os.path.join(work, "astdump-out.txt")
    open(lst, "w", encoding="utf-8", newline="\n").write("".join(("?" if p in status_only else "") + p + "\n"
                                                                 for p in paths))
    cmd = [sys.executable, "-I", "-B", exe] if exe.endswith(".py") else [exe]
    r = subprocess.run(cmd + [out, lst], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"astdump exit {r.returncode}")
    return read_dump(out)


def tiling_problems(fa):
    """What breaks the tiling of a parsed file's nodes (empty when it holds)."""
    if not fa.parsed or not fa.full:
        return []
    bad = list(fa.problems) + [f"node {k} listed twice" for k in fa.twice]
    if fa.reached != fa.node_count:
        bad.append(f"{fa.reached} of {fa.node_count} nodes reached")
    if len(fa.nodes) != fa.node_count:   # r40: a node the dump does not list (or lists out of range)
        bad.append(f"{len(fa.nodes)} of {fa.node_count} nodes listed")
    root = fa.nodes.get(0)
    if root is None or root.tag != "root" or root.parent != -1:
        bad.append("no root")
        return bad
    if (root.first, root.last) != (0, len(fa.tokens) - 1):
        bad.append(f"the root spans tokens {root.first}-{root.last} of {len(fa.tokens)}")
    for nd in fa.nodes.values():
        if nd.i != 0 and (nd.parent not in fa.nodes):
            bad.append(f"node {nd.i} has no parent node")
        if nd.first > nd.last or not 0 <= nd.first < len(fa.tokens) or not 0 <= nd.last < len(fa.tokens):
            bad.append(f"node {nd.i} ({nd.tag}) spans tokens {nd.first}-{nd.last}")
    seen, todo = {0}, [0]   # every node reached from the root through the parent links read back (no cycle, no orphan)
    while todo:
        for k in fa.children.get(todo.pop(), ()):
            if k not in seen:
                seen.add(k)
                todo.append(k)
    if len(seen) != len(fa.nodes):
        bad.append(f"{len(fa.nodes) - len(seen)} nodes not reached from the root through their parent links")
    for p, kids in fa.children.items():
        pn = fa.nodes.get(p)
        if pn is None:   # r40 (round 39's Opus L2, its control 633): a parent no line lists, reported above
            continue
        prev = None
        for k in kids:
            kn = fa.nodes[k]
            if kn.first < pn.first or kn.last > pn.last:
                bad.append(f"node {k} ({kn.tag}) {kn.first}-{kn.last} outside its parent {p} ({pn.tag}) "
                           f"{pn.first}-{pn.last}")
            if prev is not None and kn.first <= prev.last:
                bad.append(f"node {k} ({kn.tag}) {kn.first}-{kn.last} overlaps its sibling {prev.i} ({prev.tag}) "
                           f"{prev.first}-{prev.last}")
            prev = kn
    return bad


def role_problems(fa):
    """r40 (round 39's Opus L2): where a parsed file's nodes' children, in token order, do not carry the roles
    ROLE_TABLE names for the parent's tag, in its order and counts (empty when every node matches)."""
    if not fa.parsed or not fa.full:
        return []
    bad = []
    for nd in sorted(fa.nodes.values(), key=lambda m: m.i):
        row = ROLE_TABLE.get(nd.tag)
        if row is None:
            bad.append(f"node {nd.i} has a tag the role table does not name ({nd.tag})")
            continue
        roles = [fa.nodes[k].role for k in fa.children.get(nd.i, ())]
        k, ok = 0, True
        for role, lo, hi in row:
            n = 0
            while k < len(roles) and roles[k] == role and n < hi:
                k += 1
                n += 1
            if n < lo:
                ok = False
                break
        if not ok or k != len(roles):
            bad.append(f"node {nd.i} ({nd.tag}) has children with roles {' '.join(roles) or '(none)'}, which its "
                       "tag's row does not allow")
    return bad


def read_pin(data):
    """r43 (round 42's Sol M2, Opus M2 and the lead's direction, item 2): ((major, minor), None) for the version a
    build.zig.zon's root field minimum_zig_version holds, read from Zig's tokens (zigtok.py, the 0.17.1 dialect; a
    comment is no token), or (None, the reason the file is refused). `data` is the file's bytes (or its text).
    r44 (round 43's Opus M3 and the lead's direction, items 4 and 5): the version is VERSION_FORM, ASCII digits only,
    the form the residue gate's setup-zig rule reads (r43's \\d took Unicode digits: "0.\N{FULLWIDTH DIGIT ONE}"
    "\N{FULLWIDTH DIGIT SEVEN}.1" read as 0.17)."""
    import re
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogatepass")
    if b"\0" in data:
        return None, f"build.zig.zon holds a NUL (byte {data.index(bytes(1))})"
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        return None, f"build.zig.zon is not valid UTF-8 (byte {e.start})"
    toks = [t_ for t_ in zigtok.tokenize(text, "0.17.1") if t_.kind not in zigtok.COMMENTS]
    for t_ in toks:
        where = f"build.zig.zon:{t_.line + 1}"
        if t_.kind == "identifier" and t_.text.startswith("@"):
            return None, f"{where}: a quoted identifier ({t_.text[:40]})"
        if t_.kind == "mlstring":
            return None, f"{where}: a multiline string literal"
        if t_.kind in ("string", "char"):
            if "\\" in t_.text:
                return None, f"{where}: a backslash in a string or character literal"
            if len(t_.text) < 2 or t_.text[-1] != t_.text[0]:
                return None, f"{where}: an unterminated string or character literal"
    if len(toks) < 3 or toks[0].kind != "op" or toks[0].text != "." or toks[1].text != "{":
        return None, "build.zig.zon: the root is no `.{ ... }` struct"
    fields, depth, k, start = {}, 1, 2, True
    while k < len(toks):
        t_ = toks[k]
        if depth == 1 and start:   # a root entry: `.name = value`, or the root's end
            start = False
            if t_.text == "}":
                depth = 0
                k += 1
                break
            if not (t_.kind == "op" and t_.text == "." and k + 2 < len(toks) and toks[k + 1].kind == "identifier"
                    and toks[k + 2].kind == "op" and toks[k + 2].text == "="):
                return None, f"build.zig.zon:{t_.line + 1}: a root entry that is no `.name = value` field"
            name = toks[k + 1].text
            if name in fields:
                return None, f"build.zig.zon:{t_.line + 1}: a duplicate root field `{name}`"
            fields[name] = []
            k += 3
            continue
        if t_.text in ("{", "(", "["):
            depth += 1
        elif t_.text in ("}", ")", "]"):
            depth -= 1
            if depth == 0:
                k += 1
                break
        elif t_.text == "," and depth == 1:
            start = True
            k += 1
            continue
        if fields and depth >= 1:
            fields[list(fields)[-1]].append(t_)
        k += 1
    if depth != 0:
        return None, "build.zig.zon: the root struct does not close"
    if k < len(toks):
        return None, f"build.zig.zon:{toks[k].line + 1}: text after the root struct"
    if "minimum_zig_version" not in fields:
        return None, "build.zig.zon has no root field minimum_zig_version"
    val = fields["minimum_zig_version"]
    if len(val) != 1 or val[0].kind != "string":
        return None, "build.zig.zon's minimum_zig_version is not one plain string literal"
    m = VERSION_FORM.fullmatch(val[0].text[1:-1])
    if not m:
        return None, "build.zig.zon's minimum_zig_version is no version"
    return (int(m.group(1)), int(m.group(2))), None


# r44 (round 43's lead direction, item 4): the one version form the gate reads, in build.zig.zon and in a setup-zig
# step's with.version alike: ASCII N.N.N, optionally -dev.N+<lowercase hex>; group 1 and 2 are the major and minor
VERSION_FORM = __import__("re").compile(r"([0-9]+)\.([0-9]+)\.[0-9]+(?:-dev\.[0-9]+\+[0-9a-f]+)?")


def pinned_series(zon_text):
    """r40 (round 39's Opus L1): the (major, minor) a build.zig.zon's minimum_zig_version pins, or None. r43: read
    through read_pin, the one reading (a file read_pin refuses gives None)."""
    return read_pin(zon_text or "")[0]


def compiler_series(version):
    """The (major, minor) of a compiler version string such as the dump header's, or None."""
    parts = (version or "").split(".")
    ok = len(parts) >= 2 and all(p_ and p_.isascii() and p_.isdigit() for p_ in parts[:2])   # r44: ASCII digits only
    return (int(parts[0]), int(parts[1])) if ok else None


def byte_offsets(text):
    """Each character offset's byte offset in the text's UTF-8 encoding (None when the text is ASCII)."""
    if text.isascii():
        return None
    out, b = [], 0
    for ch in text:
        out.append(b)
        b += len(ch.encode("utf-8"))
    out.append(b)
    return out


def token_problems(fa, raw, dialect):
    """Where zigtok's tokens (every one but `//` comments) differ from the compiler's, for the file's bytes `raw`."""
    if not fa.full:
        return []
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return ["the file is not UTF-8"]
    zt = [t for t in zigtok.tokenize(text, dialect) if t.kind != "comment"]
    bo = byte_offsets(text)
    std_toks = [t for t in fa.tokens if t[0] != "eof"]
    bad = []
    if len(zt) != len(std_toks):
        bad.append(f"{len(zt)} zigtok tokens, {len(std_toks)} compiler tokens")
    for k, (a, b) in enumerate(zip(zt, std_toks)):
        s = a.start if bo is None else bo[a.start]
        e = s + len(a.text.encode("utf-8"))
        tag, bs, be = b
        if (s, e) != (bs, be) or kind_of(tag) != a.kind or (a.kind == "keyword" and tag != "keyword_" + a.text):
            bad.append(f"token {k}: zigtok {a.kind} {s}-{e} {a.text[:30]!r}, compiler {tag} {bs}-{be} "
                       f"{raw[bs:be][:30]!r}")
            break
    return bad


if __name__ == "__main__":
    dump = sys.argv[1]
    files = read_dump(dump)
    dialect = files.dialect
    n_unp = n_til = n_tok = n_rol = 0
    for path, fa in files.items():
        if not fa.parsed:
            n_unp += 1
            print(f"UNPARSEABLE {path}: " + ("unreadable" if fa.unreadable else f"{fa.errors} parse errors"))
        til = tiling_problems(fa)
        if til:
            n_til += 1
            print(f"AST-TILING {path}: {len(til)} problems; " + "; ".join(til[:3]))
        rol = role_problems(fa)
        if rol:
            n_rol += 1
            print(f"AST-ROLES {path}: {len(rol)} problems; " + "; ".join(rol[:3]))
        if not fa.unreadable:
            tok = token_problems(fa, open(path, "rb").read(), dialect)
            if tok:
                n_tok += 1
                print(f"AST-TOKENS {path}: " + "; ".join(tok[:2]))
    nodes = sum(len(fa.nodes) for fa in files.values())
    toks = sum(len(fa.tokens) for fa in files.values())
    print(f"files {len(files)}, nodes {nodes}, tokens {toks}; UNPARSEABLE {n_unp}, AST-TILING {n_til}, "
          f"AST-TOKENS {n_tok}, AST-ROLES {n_rol}")
    sys.exit(1 if n_unp or n_til or n_tok or n_rol else 0)
