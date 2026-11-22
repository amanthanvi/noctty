r"""Independent binding check of the inventory's "distinct" acquisitions (r32, round 31's Opus L5), and from r35 of its
"other" acquisitions and field-read exemptions (round 34's Opus M2: each kind checked by this file's own finder; a field
read also needs the op declared as a field, or as a container's own `const`/`var`; r36, round 35's Opus L3: in a
container the root binding names: its parameter's type, or its declaration's type or initializer; and for a receiver
chain, in the container each link's field type names in turn; r37, round 36's Sol M4, and r38, round 37's Opus M3:
every const and var declaration indexed, an unreadable one opaque, every name resolved by lexical scope, an opaque
innermost declaration giving no evidence). A distinct acquisition is a lock on a value mutex the inventory's resolver
reached by its declarations; the gate passes it unreviewed. This tool checks, apart from the resolver and from any
judge, the one fact the resolver's evidence rests on: the receiver's first name is bound exactly once where the
acquisition reads it, either in the function or test block that holds it (a parameter, a `const` or `var` its body
declares outside any nested container, or a capture list's name) or, when that function binds no such name, in the
innermost enclosing container that declares it at its own level (a container global). A name bound twice there, or
bound nowhere, fails.
r39 (round 38's lead direction, items 4 and 1; Sol M3, Opus K4): every structure comes from Zig's own parser
(astdump.zig, std.zig.Ast of the compiler the revision is pinned to, read and checked by zigast.py): functions are
fn_decl and test_decl nodes, containers are container nodes, declarations are var_decl nodes (so a pointer type's
`*volatile const R` is no declaration of R), captures are the capture lists the if, while, for, switch-prong and
catch nodes carry, fields are container_field nodes, and the site is the field-access node whose name is the op. A
name a declaration's initializer or type names is read from that node: a container literal certifies a name only when
it is the declaration's whole initializer (`struct { ... }.Inner` is opaque), `@This()` the enclosing container, a
name through its own declaration, a member access through the container it names, and a pointer, optional or array
type through its element type; anything else names none. A file the pinned compiler's parser rejects fails each of
its rows (BIND-UNPARSEABLE), and a dump zigast.py rejects fails them too (BIND-AST; from r40 its role check as well).
r40 (round 39's Opus L1): each revision's astdump must come from the compiler that revision pins (its build.zig.zon's
minimum_zig_version, the major and minor), or the check exits 2 (BAD-SETUP); --overlay-rev REV=DIR reads that
revision's files from DIR first (the 1B proxies' build.zig.zon as 1B.3 sets it, for the seven-tree run).
r43 (round 42's Sol M2, Opus M2 and the lead's direction, item 2): the pin is read through zigast.read_pin, from the
file's bytes, the one reading the residue gate makes too (Zig's tokens: a comment supplies no field; a quoted
identifier, a backslash in a literal, a multiline string, a duplicate root field or a minimum_zig_version that is not
one root field holding one plain version string is BAD-SETUP, with its reason).
Reads <inv-prefix>-distinct.tsv (rev, file, line, function, op, receiver), -other.tsv (the same, then the type) and
-fieldreads.tsv (rev, file, line, chain, op, field or container-var; lock_inventory20.py) and each named file at its
revision (git show), or from --overlay DIR as the inventory read it. Prints one line per revision and every failure;
exit 1 when any fails, 0 otherwise. Read-only on the repository; writes astdump's list and dump in --work (default: a
temporary directory).
Usage: python -I bindcheck41.py <repo> <inv-prefix> --astdump <exe> [--astdump-rev REV=EXE]... [--overlay DIR]
       [--overlay-rev REV=DIR]... [--work DIR]"""
import collections
import importlib.util
import os
import subprocess
import sys
import tempfile

for _s in (sys.stdout, sys.stderr):
    _s.reconfigure(encoding="utf-8", errors="backslashreplace")
sys.dont_write_bytecode = True   # r32: loading zigtok.py writes no __pycache__ beside the installed tools
_here = os.path.dirname(os.path.abspath(__file__))
_aspec = importlib.util.spec_from_file_location("zigast", os.path.join(_here, "zigast.py"))
zigast = importlib.util.module_from_spec(_aspec)
_aspec.loader.exec_module(zigast)
zigtok = zigast.zigtok
argv = sys.argv[1:]
overlay = work = astdump = None
by_rev, overlay_rev = {}, {}
while "--astdump-rev" in argv:
    k = argv.index("--astdump-rev")
    r_, _, e_ = argv[k + 1].partition("=")
    by_rev[r_] = e_
    del argv[k:k + 2]
while "--overlay-rev" in argv:   # r40
    k = argv.index("--overlay-rev")
    r_, _, d_ = argv[k + 1].partition("=")
    overlay_rev[r_] = d_
    del argv[k:k + 2]
for opt in ("--overlay", "--work", "--astdump"):
    if opt in argv:
        k = argv.index(opt)
        val = argv[k + 1]
        del argv[k:k + 2]
        if opt == "--overlay":
            overlay = val
        elif opt == "--work":
            work = val
        else:
            astdump = val
if astdump is None and not by_rev:
    print("BAD-SETUP: no astdump executable (--astdump): the check reads Zig only through the pinned compiler's parse")
    sys.exit(2)
repo, prefix = argv[0], argv[1]
_tmp = None
if work is None:
    _tmp = tempfile.TemporaryDirectory()
    work = _tmp.name
os.makedirs(work, exist_ok=True)

FNS = frozenset(("fn_decl", "test_decl"))
CONTAINERS = frozenset(("root", "container_decl", "container_decl_trailing", "container_decl_two",
                        "container_decl_two_trailing", "container_decl_arg", "container_decl_arg_trailing",
                        "tagged_union", "tagged_union_trailing", "tagged_union_two", "tagged_union_two_trailing",
                        "tagged_union_enum_tag", "tagged_union_enum_tag_trailing"))
BLOCKS = frozenset(("block_two", "block_two_semicolon", "block", "block_semicolon"))
VARDECL = frozenset(("global_var_decl", "local_var_decl", "simple_var_decl", "aligned_var_decl"))
FIELDS = frozenset(("container_field_init", "container_field_align", "container_field"))
BUILTINS = frozenset(("builtin_call_two", "builtin_call_two_comma", "builtin_call", "builtin_call_comma"))
CALLS = frozenset(("call_one", "call_one_comma", "call", "call_comma"))
WRAPS = frozenset(("optional_type", "ptr_type_aligned", "ptr_type_sentinel", "ptr_type", "ptr_type_bit_range",
                   "array_type", "array_type_sentinel"))


class FileView:
    """One file's parse, with the readers this check needs."""

    def __init__(self, fa, raw):
        self.fa, self.raw, self.N = fa, raw, fa.nodes
        self.nl = [i for i, b in enumerate(raw) if b == 10]
        self.decls = {}   # scope node -> name -> [var_decl node]
        for n in self.N.values():
            if n.tag in VARDECL:
                self.decls.setdefault(self.scope_of(n), {}).setdefault(self.name(n.x["mut"] + 1), []).append(n)

    def text(self, t):
        _, s, e = self.fa.tokens[t]
        return self.raw[s:e].decode("utf-8", "replace")

    def name(self, t):
        if not 0 <= t < len(self.fa.tokens) or self.fa.tokens[t][0] != "identifier":
            return None
        x = self.text(t)
        if x.startswith('@"'):
            try:
                return zigtok.unescape(x[2:-1]).decode("utf-8")
            except UnicodeDecodeError:
                return None
        return x

    def line(self, t):
        import bisect
        return bisect.bisect_left(self.nl, self.fa.tokens[t][1])

    def kids(self, n, role=None):
        return [self.N[k] for k in self.fa.children.get(n.i, ()) if role is None or self.N[k].role == role]

    def child(self, n, role):
        k = self.kids(n, role)
        return k[0] if k else None

    def parent(self, n):
        return self.N.get(n.parent)

    def ancestors(self, n):
        while n is not None:
            yield n
            n = self.N.get(n.parent)

    def scope_of(self, n):
        """The block, container or file a declaration binds in."""
        for a in self.ancestors(self.parent(n)):
            if a.tag in BLOCKS or a.tag in CONTAINERS:
                return a.i
        return 0

    def container_of(self, n):
        for a in self.ancestors(n):
            if a.tag in CONTAINERS:
                return a.i
        return 0

    def subtree(self, n, stop=frozenset()):
        todo = list(self.fa.children.get(n.i, ()))
        while todo:
            m = self.N[todo.pop()]
            yield m
            if m.tag not in stop:
                todo.extend(self.fa.children.get(m.i, ()))

    # ---- the declaration index (r38's, from the nodes)
    def target(self, d):
        """A var_decl's target: ("box", container node) for a container literal that is its whole initializer or for
        `@This()`, ("alias", the name node) for a bare name, else ("opaque",)."""
        init = self.child(d, "init")
        if init is None:
            return ("opaque",)
        if init.tag in CONTAINERS:
            return ("box", init.i)
        if init.tag in BUILTINS and self.text(init.main) == "@This" and not self.kids(init, "arg"):
            return ("box", self.container_of(d))
        if init.tag == "identifier":
            return ("alias", init)
        return ("opaque",)

    def resolve(self, name, at, seen=frozenset()):
        """The boxes `name`, written at node `at`, names: the first scope outward that declares it decides; exactly one
        readable declaration there gives its box (an alias through its own declaration); an opaque one, or more than
        one, gives none."""
        for a in self.ancestors(at):
            ds = self.decls.get(a.i, {}).get(name)
            if not ds:
                continue
            if len(ds) != 1:
                return set()
            d = ds[0]
            tgt = self.target(d)
            if tgt[0] == "box":
                return {tgt[1]}
            if tgt[0] == "alias" and d.i not in seen:
                return self.resolve(self.name(tgt[1].main), tgt[1], seen | {d.i})
            return set()
        return set()

    def names(self, n):
        """The boxes a type or initializer node names (see the module's documentation)."""
        if n is None:
            return set()
        if n.tag in CONTAINERS:
            return {n.i}
        if n.tag == "identifier":
            return self.resolve(self.name(n.main), n)
        if n.tag in BUILTINS and self.text(n.main) == "@This" and not self.kids(n, "arg"):
            return {self.container_of(n)}
        if n.tag in WRAPS:
            return self.names(self.child(n, "elem_type") or self.child(n, "operand"))
        if n.tag == "grouped_expression":
            return self.names(self.child(n, "operand"))
        if n.tag == "field_access":
            out = set()
            member = self.name(n.last)
            for bx in self.names(self.child(n, "object")):
                for d in self.decls.get(bx, {}).get(member, []):
                    if d.parent == bx:
                        tgt = self.target(d)
                        if tgt[0] == "box":
                            out.add(tgt[1])
                        elif tgt[0] == "alias":
                            out |= self.resolve(self.name(tgt[1].main), tgt[1])
            return out
        return set()

    # ---- containers' members
    def field_nodes(self, box):
        b = self.N[box]
        return [f for f in self.kids(b, "member") if f.tag in FIELDS and f.x.get("tuple") == 0
                and self.text(f.main + 1) == ":"]

    def declared_in(self, box, name, want):
        """Whether the container node `box` declares `name` at its own level: a field (want "field"), or a const or
        var (want "container-var")."""
        b = self.N[box]
        if want == "field":
            return any(self.name(f.main) == name for f in self.field_nodes(box))
        return any(d.tag in VARDECL and self.name(d.x["mut"] + 1) == name for d in self.kids(b, "member"))

    def field_type_boxes(self, box, name):
        for f in self.field_nodes(box):
            if self.name(f.main) == name:
                return self.names(self.child(f, "type"))
        return set()


def text_of(rev, f):
    if rev in overlay_rev:   # r40
        p = os.path.join(overlay_rev[rev], *f.split("/"))
        if os.path.exists(p):
            return open(p, "rb").read()
    if overlay:
        p = os.path.join(overlay, *f.split("/"))
        if os.path.exists(p):
            return open(p, "rb").read()
    return subprocess.run(["git", "-C", repo, "show", f"{rev}:{f}"], capture_output=True).stdout


def read_rows(suffix, kind):
    p_ = prefix + suffix
    if not os.path.exists(p_):
        return []
    return [(kind, l.rstrip("\n").split("\t")) for l in open(p_, encoding="utf-8") if l.strip()]


rows = read_rows("-distinct.tsv", "distinct") + read_rows("-other.tsv", "other") + read_rows("-fieldreads.tsv", "fieldread")
by_file = collections.defaultdict(list)
for kind_, r in rows:
    by_file[(r[0], r[1])].append((kind_, r))
# every file each revision's rows name, parsed by that revision's compiler in one astdump run per executable
srcs, groups = {}, collections.defaultdict(list)
for k_, (rev, f) in enumerate(sorted(by_file)):
    p_ = os.path.join(work, f"src{k_}.zig")
    open(p_, "wb").write(text_of(rev, f))
    srcs[(rev, f)] = p_
    groups[by_rev.get(rev, astdump)].append(p_)
dumps, built = {}, {}
for exe, ps in groups.items():
    if exe is None:
        continue
    sub = os.path.join(work, f"g{len(dumps)}")
    os.makedirs(sub, exist_ok=True)
    d_ = zigast.run_astdump(exe, ps, set(), sub)
    built[exe] = d_.compiler
    for p_ in ps:
        dumps[p_] = (d_.get(p_), d_.dialect)
# r40 (round 39's Opus L1): each revision read only through the compiler it pins
for rev in sorted({r for r, _ in by_file}):
    exe = by_rev.get(rev, astdump)
    pin, why = zigast.read_pin(text_of(rev, "build.zig.zon"))   # r43: the residue gate's reading, one function
    if why:
        print(f"BAD-SETUP: {rev}: {why}: the check reads a revision only through its pinned compiler's parse")
        sys.exit(2)
    have = zigast.compiler_series(built.get(exe))
    if have != pin:
        print(f"BAD-SETUP: {rev} is read with an astdump built by Zig {built.get(exe) or '(none)'}, but it pins "
              + (".".join(map(str, pin)) if pin else "no minimum_zig_version")
              + ": the check reads a revision only through its pinned compiler's parse")
        sys.exit(2)


def site_nodes(v, ln, recv, op_, called):
    """The field-access nodes on line ln whose name is op_ and whose object ends with recv's last name (or is a
    dereference or an unwrap), called or not as asked."""
    last = recv.split(".")[-1]
    out = []
    for n in v.N.values():
        if n.tag != "field_access" or v.name(n.last) != op_ or v.line(n.last) != ln:
            continue
        o = v.child(n, "object")
        if o is None:
            continue
        ok = (o.tag == "identifier" and v.name(o.main) == last) or (o.tag == "field_access" and v.name(o.last) == last) \
            or o.tag in ("deref", "unwrap_optional")
        if not ok:
            continue
        p = v.parent(n)
        is_call = p is not None and p.tag in CALLS and n.role == "callee"
        if called is not None and is_call != called:
            continue
        out.append(n)
    return out


def captures_in(v, body, stop):
    """The capture-list names bound inside body (not in nested containers)."""
    out = []
    for m in [body] + list(v.subtree(body, stop)):
        firsts = []
        if m.tag in ("if_simple", "if", "while_simple", "while_cont", "while"):
            firsts = [m.x.get("pay", -1), m.x.get("err", -1)]
        elif m.tag in ("for_simple", "for", "switch_case_one", "switch_case_inline_one", "switch_case",
                       "switch_case_inline"):
            firsts = [m.x.get("pay", -1)]
        elif m.tag in ("catch", "errdefer") and m.main + 1 < len(v.fa.tokens) and v.text(m.main + 1) == "|":
            firsts = [m.main + 2]
        for t in firsts:
            while 0 <= t < len(v.fa.tokens) and v.text(t) != "|":
                if v.fa.tokens[t][0] == "identifier":
                    out.append(v.name(t))
                t += 1
    return out


def scoped_ok(v, cur, recv, op_, want):
    """r36: whether op_ is declared (want) in a box the root binding names, through recv's links."""
    for link in recv.split(".")[1:]:
        nxt = set()
        for bx in cur:
            nxt |= v.field_type_boxes(bx, link)
        cur = nxt
    return any(v.declared_in(bx, op_, want) for bx in cur), cur


result, failures = collections.defaultdict(collections.Counter), []
for (rev, f), rs in sorted(by_file.items()):
    fa, dialect = dumps.get(srcs[(rev, f)], (None, None))
    raw = open(srcs[(rev, f)], "rb").read()
    bad = None
    if fa is None or not fa.parsed:
        bad = "BIND-UNPARSEABLE", "the pinned compiler's parser rejects the file"
    elif zigast.tiling_problems(fa) or zigast.role_problems(fa) or zigast.token_problems(fa, raw, dialect):
        bad = "BIND-AST", "zigast.py rejects the file's parse"
    if bad:
        for kind_, r in rs:
            failures.append(f"{bad[0]} {rev} {f}:{r[2]}: {bad[1]}, so the row cannot be checked")
            result[rev]["fail"] += 1
        continue
    v = FileView(fa, raw)
    boxes = [n.i for n in v.N.values() if n.tag in CONTAINERS]
    for kind_, r in rs:
        ln = int(r[2]) - 1
        recv, op_ = (r[3], r[4]) if kind_ == "fieldread" else (r[5], r[4])
        root = recv.split(".")[0]
        label = f"{kind_} " if kind_ != "distinct" else ""
        if kind_ == "fieldread":
            want = r[5]
            if not any(v.declared_in(bx, op_, want) for bx in boxes):
                failures.append(f"{'FIELD' if want == 'field' else 'VAR'}-NOT-DECLARED {rev} {f}:{ln + 1}: {recv}.{op_} "
                                f"({want}): no container of the file declares {op_} so")
                result[rev]["fail"] += 1
                continue
        sites = site_nodes(v, ln, recv, op_, False if kind_ == "fieldread" else True)
        if not sites:
            failures.append(f"BIND-NO-SITE {rev} {f}:{ln + 1} {label}{recv}.{op_}: no such token on the line")
            result[rev]["fail"] += 1
            continue
        hs = [next((a for a in v.ancestors(s) if a.tag in FNS), None) for s in sites]
        if any(h is None for h in hs) or len({h.i for h in hs}) != 1:
            failures.append(f"BIND-NO-FUNCTION {rev} {f}:{ln + 1} {label}{r[3]}: {recv}")
            result[rev]["fail"] += 1
            continue
        fn = hs[0]
        body = v.child(fn, "body")
        params = {}
        if fn.tag == "fn_decl":
            proto = v.child(fn, "proto")
            for pt, ty in proto.x.get("p", ()):
                if pt >= 0:
                    params.setdefault(v.name(pt), []).append(v.N.get(ty))
        local_decls = [m for m in v.subtree(body, CONTAINERS) if m.tag in VARDECL]   # not in a nested container
        names_here = [v.name(m.x["mut"] + 1) for m in local_decls]
        n_fn = len(params.get(root, [])) + names_here.count(root) + captures_in(v, body, CONTAINERS).count(root)
        if n_fn == 1:
            if kind_ == "fieldread":   # r36 (round 35's Opus L3): the op in the root binding's container
                if root in params:
                    cur = v.names(params[root][0])
                else:
                    d = next((m for m in local_decls if v.name(m.x["mut"] + 1) == root), None)
                    cur = set()
                    if d is not None:
                        cur = v.names(v.child(d, "type")) | v.names(v.child(d, "init"))
                ok_, got_ = scoped_ok(v, cur, recv, op_, r[5])
                if not ok_:
                    failures.append(f"{'FIELD' if r[5] == 'field' else 'VAR'}-NOT-DECLARED {rev} {f}:{ln + 1}: "
                                    f"{recv}.{op_} ({r[5]}): the containers its root binding names "
                                    f"({len(got_)}) do not declare {op_} so")
                    result[rev]["fail"] += 1
                    continue
            result[rev]["function" if kind_ == "distinct" else kind_ + "-function"] += 1
            continue
        if n_fn > 1:
            failures.append(f"BIND-TWICE {rev} {f}:{ln + 1} {r[3]}: {root} is bound {n_fn} times in its function")
            result[rev]["fail"] += 1
            continue
        got, decl = None, None
        for a in v.ancestors(v.parent(fn)):
            if a.tag not in CONTAINERS:
                continue
            ds = [d for d in v.kids(a, "member") if d.tag in VARDECL and v.name(d.x["mut"] + 1) == root]
            if ds:
                got, decl = len(ds), ds[0]
                break
        if got is None:
            got = 0
        if got == 1 and kind_ == "fieldread":   # r36 (round 35's Opus L3): the op in the root binding's container
            cur = v.names(v.child(decl, "type")) | v.names(v.child(decl, "init"))
            ok_, got_ = scoped_ok(v, cur, recv, op_, r[5])
            if not ok_:
                failures.append(f"{'FIELD' if r[5] == 'field' else 'VAR'}-NOT-DECLARED {rev} {f}:{ln + 1}: "
                                f"{recv}.{op_} ({r[5]}): the containers its root binding names ({len(got_)}) do not "
                                f"declare {op_} so")
                result[rev]["fail"] += 1
                continue
        if got == 1:
            result[rev]["global" if kind_ == "distinct" else kind_ + "-global"] += 1
        else:
            failures.append(f"BIND-{'TWICE' if got else 'UNBOUND'} {rev} {f}:{ln + 1} {r[3]}: {root} is bound "
                            f"{got} times in its function's containers and none in the function")
            result[rev]["fail"] += 1
if _tmp is not None:
    _tmp.cleanup()
revs = sorted({r[0] for _, r in rows})
for rev in revs:
    c = result[rev]
    nd = sum(1 for k_, r in rows if r[0] == rev and k_ == "distinct")
    print(f"{rev}: {nd} distinct acquisitions: bound once in their function {c['function']}, "
          f"container globals {c['global']}, failures {c['fail']}; other {c['other-function'] + c['other-global']} "
          f"(function {c['other-function']}, global {c['other-global']}); field-read exemptions "
          f"{c['fieldread-function'] + c['fieldread-global']} (function {c['fieldread-function']}, global "
          f"{c['fieldread-global']})")
for x in failures:
    print("FAIL " + x)
nd_ = sum(1 for k_, _ in rows if k_ == "distinct")
no_ = sum(1 for k_, _ in rows if k_ == "other")
nf_ = sum(1 for k_, _ in rows if k_ == "fieldread")
print(f"RESULT {'FAIL' if failures else 'PASS'} ({len(failures)} failures, {nd_} distinct acquisitions, {no_} other, "
      f"{nf_} field-read exemptions)")
sys.exit(1 if failures else 0)
