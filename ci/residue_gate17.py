r"""The post-cutover residue gate's mechanical 0.15 checks (§7.8; run report-only from 1B.3 and at each forward merge,
and enforcing at 1B.10 on the frozen SHA's checkout). r29 (round 28's Sol M2) wrote residue_gate.py; r30 to r35 grew it
(residue_gate2.py to residue_gate7.py: version contexts, not number literals; the shared token stream, zigtok.py; std
origin by scope, then by category); r36 made origin DEFAULT-DENY; r37 made its positive evidence a small explicit
trusted set (RULES, TRUSTED; §7.8's rule table); r38 made the machinery under the trusted rows fail closed; r39 (round
38's lead direction) takes every structure from Zig's own parser; r40 (round 39's) classifies every parent an
occurrence of a var can meet as a read, a pass-through (which climbs), a write or an address, joins a labelled
switch's breaks and continues, checks the astdump's compiler against the tree's pin and each node's roles; r41 (round
40's) walks a place downwards with an explicit stack and no depth limit, holds every write and address to the vars
that walk reaches (an occurrence it does not reach, or a walk that cannot finish, leaves the var unresolved), binds an
unlabelled break as AstGen does, reads no Zig file of a tree pinned below 0.17 (its pin fails ACTIVE-015-SELECTION),
and fails a setup-zig version that is not a literal unless a `setup-zig-step` row names the step; r42 (round 41's)
reads every input it relies on strictly and fails on any it cannot read: build.zig.zon once (its exact name at the
root, UTF-8, no NUL, one minimum_zig_version; else BAD-SETUP), every text file with no silent skip (NOT-TEXT), every
.zig file, and every CI file under .github/ and every local action they name through a closed YAML subset (ciyaml.py;
CI-UNREADABLE), each setup-zig step bound to an explicit version; r43 (round 42's) closes the inputs' characters and
names: a CI file holds LF or CR LF line breaks and ASCII keys only, the pin is read from Zig's tokens
(zigast.read_pin, which the binding check calls too), a `uses` value is a local path read whole with its exact case, a
remote owner/repo[/path]@ref or a docker:// image, the file set of a git checkout is its tracked list
(CASE-COLLISION, TRACKED-UNREAD), a skip directory applies at the root only, and a file with a UTF-16 or UTF-32
byte-order mark is scanned by its code units and by its bytes; r44 (round 43's) reads the bytes each consumer reads and
one spelling of each value: in a git checkout every tracked file's content is its index blob (`git cat-file --batch`),
a tracked path git transforms at checkout fails TRANSFORMED-PATH and a checkout file that differs from its blob beyond
CR LF against LF fails CHECKOUT-DIFFERS (GitHub reads a workflow from the commit and Zig reads the checkout; with the
two rules they read the same bytes), a tracked link is read as its link text and never followed (TRACKED-LINK), a
local action holds exactly one metadata file spelled exactly, a setup-zig version and the pin are read only in one
ASCII form (N.N.N, or N.N.N-dev.N+<hex>), and the CI reader, the uses grammar and the version rule use no
Unicode-aware string operation; r45 (round 44's) reads one commit, HEAD or --rev, with replace objects off and no
GIT_* variable from the caller (its tree, its blobs, its attributes), fails a checkout whose index is not that commit
(INDEX-NOT-COMMIT), holds a tracked link's target to a tracked regular file, refuses a degenerate allowance key, and
names a file it cannot read (UNREADABLE) and a submodule: the Zig files it
reads are parsed by astdump.zig
(std.zig.Ast of the compiler the tree is pinned to) and read through zigast.py, which checks each dump first (the
tiling of every node's children, zigtok's tokens against the compiler's), so no operand, target, declaration or
scope is found by reading tokens by hand.
On a checkout directory's text files:
- RESIDUE-015: a `0.15` mention in a Zig-version context, where the allowance does not permit it. A context is a
  version written out (0.15.2, 0.15.x), a line that names Zig before the mention (Zig 0.15, zig-0.15.2,
  minimum_zig_version, setup-zig), a compiler option (--compiler 0.15), or a TSV field that is exactly 0.15 (a run
  spec's compiler column); a number literal (`@max(0.15, x)`, `0.15 * h`, `rgba(0, 0, 0, 0.15)`) is none;
- STALE-ALLOWANCE and RESIDUE-015-COUNT: an allowance row that permits nothing any more, or a file holding more
  mentions than its count, so the allowance stays exactly as narrow as what it permits;
- ACTIVE-015-SELECTION: build.zig.zon's minimum_zig_version below 0.17 (r41: the gate then reads no Zig file; r42:
  recorded from the one strict read of the pin, before anything else), or a setup-zig step (r42: any step, in a
  workflow or a local action, whose uses names a repository containing setup-zig, any case) with no with.version, or
  a literal version below 0.17 (r44: a literal is N.N.N or N.N.N-dev.N+<lowercase hex>, ASCII digits, quoted or
  plain; any other spelling, such as two parts (0.150, which YAML reads as the number 0.15), a Mach name
  (2024.11.0-mach), master, latest or other digits, is a version the gate cannot read), or (r41) one that is no
  literal unless its `setup-zig-step` row binds it (r42: by
  workflow, job and step id, its version exactly the producer step's output, the producer an earlier step of the
  job whose text's sha256 is the row's), or (r42) a setup-zig mention outside a setup-zig step's uses (a comment
  aside: a run script's text is content);
- NOT-TEXT (r42): a .zig, .zon, .yml, .yaml or .tsv file that is not strict UTF-8 or holds a NUL (every other file is
  scanned for mentions over its bytes, each byte mapped; r43, the user's decision on round 42's Opus L2: a file that
  starts with a UTF-16 or UTF-32 byte-order mark is also scanned decoded by that mark code unit by code unit, lone
  surrogates kept and a trailing partial unit dropped, and never fails NOT-TEXT);
- CI-UNREADABLE (r42): a file under .github/ named .yml or .yaml, or a local action a CI file names, that ciyaml.py
  refuses, a job or a step that is no block mapping, a local action no file holds; r43: ciyaml.py refuses a CR not
  followed by LF, NEL, LS, PS, a byte-order mark anywhere, any other C0 control or DEL, a tab outside a block scalar's
  content or a comment, and a key outside [A-Za-z0-9_-]; a `uses` value that is none of a local path (`./` and
  segments of [A-Za-z0-9._-] joined by `/`), a remote owner/repo[/path]@ref and a docker:// image fails; a local path
  is read whole and must exist with its exact case; r44: in a local action directory, every entry equal to
  action.yml or action.yaml under case folding counts, and exactly one must exist, spelled exactly; with none, every
  entry equal to Dockerfile under case folding counts, and exactly one spelled Dockerfile is a Docker action outside
  the boundary (its code is not read); any other count or spelling fails (r43 matched the exact names, so a Windows
  runner, whose lookup ignores case, loaded an ACTION.YML the gate never read);
- CASE-COLLISION (r43): two paths of a git checkout's tracked list (`git ls-files -z`) that are equal under case
  folding (a case-insensitive checkout keeps one);
- TRACKED-UNREAD (r43): a tracked path the gate did not read (missing from the checkout, or spelled otherwise there,
  or, r45 naming it so, a submodule); a tracked file under a root skip directory is read all the same;
- INDEX-NOT-COMMIT (r45): in a git checkout, an index that differs from the commit read (HEAD, or --rev) at any path,
  mode or object: a staged change, or an index built from another tree; the gate reads the commit's tree and blobs,
  with replace objects off, and holds the checkout to them;
- UNREADABLE (r45): a file (or a directory of the walk) whose read fails with an OSError, a broken untracked link
  among them: named, never a traceback;
- TRANSFORMED-PATH (r44): a tracked path with a filter, working-tree-encoding or ident attribute (`git check-attr
  --cached`; r45: `--source`, the commit's attributes): git rewrites its bytes between the commit and the checkout;
- CHECKOUT-DIFFERS (r44): a tracked file whose checkout bytes differ from its blob (r45: the commit's) other than by
  CR LF against LF, or whose checkout is a link, or a tracked link whose checkout is neither that link nor a file of
  its text;
- TRACKED-LINK (r44): a tracked link (mode 120000) whose name the gate interprets (.zig, .zon, .yml, .yaml or
  Dockerfile, any case), or whose target is a directory or lies outside the tree, or (r45, round 44's Opus M1) is no
  tracked regular file; every tracked link is read as its link text under its own path, never followed;
- UNPARSEABLE (r39): a .zig file (r39: under src/ or a build file; r40: pkg/ too; r42: every one but under a skip
  directory; r43: those at the root only, a tracked file always) the pinned compiler's parser rejects (or astdump cannot
  read): the gate reads only what the tree's pinned compiler parses, and a rejected file fails; AST-TILING,
  AST-ROLES (r40) and AST-TOKENS: a dump zigast.py's checks reject (the file is not read);
- PRODUCTION-SHIM, in a .zig file (the files UNPARSEABLE names): a use of `zig_version` outside requireZig's file, or of
  `zig_version_string` outside the version printer's file (the identifier, a quoted `@"..."` one, and a literal-name
  `@field` whose decoded name is either, escapes included); and more feature tests on std than the file's
  `feature-tests` row allows;
- DERIVED-SHIM: more feature tests on a type derived from std than the file's `derived-tests` row allows;
- UNRESOLVED-ORIGIN: more feature tests whose subject's origin the gate cannot positively resolve, and nonliteral
  `@field` names (in every file) whose object is neither positively local nor a boundary class, than the file's
  `unresolved-origin` row allows (none without one);
- UNRESOLVED-DESTRUCTURING: a feature test on a destructuring element the gate cannot match element-wise (always).
A feature test is a `@hasDecl`, `@hasField` or `@typeInfo` call, or a call of `hasFn` or `hasMethod` (a decoded name,
or a literal `@field` name); any other reference to hasFn or hasMethod is unresolved. Its subject is its first
argument node, read by OriginResolver. The positive evidence ("local") is exactly the rules in RULES that are in
TRUSTED, each with its soundness argument in §7.8's rule table; a rule outside TRUSTED gives UNRESOLVED-ORIGIN; the two
boundary classes are "import" (a project `@import`; the check is per file) and "param" (a function parameter, which
never leaves its function); "std", "derived", "udestr" and "unresolved" fail. §7.8 lists every category predicate
with its direction. A var is evidence only when every occurrence of it is classified by the parent above its climb
through pass-through parents (PASS_THROUGH): a read (READ_PARENTS), a named write (WRITE_PARENTS) or an address
(ADDRESS_PARENTS and `_address_parent`); any other parent leaves it unresolved. Resolution is memoized,
with cycle detection and no fixed depth.
The allowance (ci/residue-allow.tsv; it and the fixture's copy are not scanned) has rows `prefix <path prefix>
<reason>`, `content <path> <the line's text, stripped> <reason>`, `count <path> <n> <reason>`, `zig-version-use <path>
<reason>`, `zig-version-string-use <path> <reason>`, `feature-tests <path> <n> <reason>`, `derived-tests <path> <n>
<reason>`, `unresolved-origin <path> <n> <reason>` and (r41, r42) `setup-zig-step <workflow> <job id> <step id> <producer step
id> <sha256> <reason>`, each exact (fewer than allowed, or a setup-zig-step row that matches no step, fails
STALE-ALLOWANCE; one that matches two steps fails ACTIVE-015-SELECTION); r29's
`lines` rows are refused (BAD-ALLOWANCE). r45 (round 44's Opus L2 and the lead's direction, item 3): an empty path, a
prefix that does not end in `/`, an empty content line, or a count (count, feature-tests, derived-tests,
unresolved-origin) that is no positive ASCII number is BAD-ALLOWANCE; a prefix that names no tracked directory (in a
plain directory: matches no file read) is STALE-ALLOWANCE.
--report-only prints the same and exits 0; --origins also prints each feature test's origin (ORIGIN lines);
--astdump gives the astdump executable built with the tree's pinned compiler (required unless the tree pins below 0.17,
whose Zig files the gate does not read: without it, or with one whose header names another compiler than
build.zig.zon's minimum_zig_version, the gate exits 2, BAD-SETUP; so does a root build.zig.zon that is missing, has a
case variant beside it (or build.zig has), or that zigast.read_pin refuses (r43: a NUL, invalid UTF-8, a quoted
`@"..."` identifier, a backslash in a string or character literal, a multiline string literal, a root that is no
`.{ ... }` of `.name = value` fields, a duplicate root field, or a minimum_zig_version that is not one root field
holding one plain version string; comments are not read; r44: or whose version is not N.N.N or N.N.N-dev.N+<hex>
in ASCII), and (r43) a git checkout whose tracked list `git ls-files` cannot give (r44: or whose index holds an
unmerged path, whose blobs `git cat-file` or attributes `git check-attr` cannot give, or whose build.zig.zon is no
tracked file: in a git checkout the pin is read from its blob; r45: or whose commit git rev-parse or whose tree git
ls-tree cannot give);
--rev a commit to read in a git checkout (default HEAD); the gate prints `COMMIT <sha> (<rev>)` first;
--work a directory for astdump's list and dump (default: a temporary one).
Usage: python -I residue_gate17.py <checkout dir> <allowance.tsv> --astdump <exe> [--work <dir>] [--rev <commit>]
       [--report-only] [--origins]"""
import bisect
import hashlib
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True   # r32: loading zigtok.py writes no __pycache__ beside the installed tools
_here = os.path.dirname(os.path.abspath(__file__))
_zspec = importlib.util.spec_from_file_location("zigtok", os.path.join(_here, "zigtok.py"))
zigtok = importlib.util.module_from_spec(_zspec)
_zspec.loader.exec_module(zigtok)   # r32: the one shared Zig token stream (zigtok.py), installed beside this tool
_aspec = importlib.util.spec_from_file_location("zigast", os.path.join(_here, "zigast.py"))
zigast = importlib.util.module_from_spec(_aspec)
_aspec.loader.exec_module(zigast)   # r39: the compiler's parse (astdump.zig), installed beside this tool
_yspec = importlib.util.spec_from_file_location("ciyaml", os.path.join(_here, "ciyaml.py"))
ciyaml = importlib.util.module_from_spec(_yspec)
_yspec.loader.exec_module(ciyaml)   # r42: the closed YAML subset the CI check reads, installed beside this tool
sys.setrecursionlimit(20000)

# ---- the origin resolver (r36 to r39); measure39.py executes this part alone, between the two markers
# @@RESOLVER-BEGIN@@
RANK = {"local": 0, "import": 1, "param": 2, "derived": 3, "udestr": 4, "unresolved": 5, "std": 6}
PRIMITIVE = re.compile(r"^(?:[iu]\d+|usize|isize|c_char|c_short|c_ushort|c_int|c_uint|c_long|c_ulong|c_longlong|"
                       r"c_ulonglong|c_longdouble|f16|f32|f64|f80|f128|bool|void|noreturn|type|anyerror|comptime_int|"
                       r"comptime_float|anyopaque|anyframe)$")
VALUE_BUILTINS_SAME = frozenset(("@TypeOf",))   # the result names what the arguments name
FEATURE_BUILTINS = frozenset(("@hasDecl", "@hasField", "@typeInfo"))
FEATURE_FNS = frozenset(("hasFn", "hasMethod"))
VERSION_NAMES = frozenset(("zig_version", "zig_version_string"))
LIMIT = 400000   # evaluation steps per file: past it, a value is "unresolved" (a resource limit), never a pass
# r37 (round 36's lead direction): every rule that can give "local", by name. A leaf rule gives local evidence itself;
# a propagation rule gives local only when every value it joins is local. A rule outside TRUSTED gives
# UNRESOLVED-ORIGIN. §7.8's rule table states each one's soundness argument and its local verdicts on the seven trees.
RULES = ("prim", "constant", "literal", "undef", "enumlit", "anon", "container", "this", "cimport", "error", "fntype",
         "asm", "noreturn", "bool", "valuebuiltin", "voidblock", "errcapture", "fnref", "voidfn", "enumfield",
         "indexplain", "decl", "annotation", "member", "fieldtype", "call", "callparam", "capture", "as", "typeof",
         "fieldlit", "newbuiltin", "branch", "block", "parens", "orelse", "arith", "ptrtype", "deref", "unwrap",
         "instance", "arraylit", "addrtyped", "var")
# r37, r38: the trusted set, the rules the seven trees need (an ablation of every rule over the passing verdicts, the
# local ones and the two boundary classes; §7.8's rule table): every other rule's form gives UNRESOLVED-ORIGIN
TRUSTED = {"prim", "constant", "literal", "undef", "enumlit", "anon", "container", "this", "noreturn", "bool",
           "valuebuiltin", "decl", "annotation", "member", "fieldtype", "typeof", "newbuiltin", "branch", "block",
           "arith", "ptrtype", "addrtyped", "var"}

# r39: node tags, by the role the resolver gives them (std.zig.Ast's Node.Tag)
VARDECL = frozenset(("global_var_decl", "local_var_decl", "simple_var_decl", "aligned_var_decl"))
BLOCKS = frozenset(("block_two", "block_two_semicolon", "block", "block_semicolon"))
CONTAINERS = frozenset(("root", "container_decl", "container_decl_trailing", "container_decl_two",
                        "container_decl_two_trailing", "container_decl_arg", "container_decl_arg_trailing",
                        "tagged_union", "tagged_union_trailing", "tagged_union_two", "tagged_union_two_trailing",
                        "tagged_union_enum_tag", "tagged_union_enum_tag_trailing"))
FNPROTOS = frozenset(("fn_proto_simple", "fn_proto_multi", "fn_proto_one", "fn_proto"))
CALLS = frozenset(("call_one", "call_one_comma", "call", "call_comma"))
BUILTINS = frozenset(("builtin_call_two", "builtin_call_two_comma", "builtin_call", "builtin_call_comma"))
FIELDS = frozenset(("container_field_init", "container_field_align", "container_field"))
TUPLES = frozenset(("array_init_dot_two", "array_init_dot_two_comma", "array_init_dot", "array_init_dot_comma"))
ANON = TUPLES | frozenset(("struct_init_dot_two", "struct_init_dot_two_comma", "struct_init_dot",
                           "struct_init_dot_comma"))
TYPED_INIT = frozenset(("array_init_one", "array_init_one_comma", "array_init", "array_init_comma", "struct_init_one",
                        "struct_init_one_comma", "struct_init", "struct_init_comma"))
IFS = frozenset(("if_simple", "if"))
WHILES = frozenset(("while_simple", "while_cont", "while"))
FORS = frozenset(("for_simple", "for"))
SWITCHES = frozenset(("switch", "switch_comma"))
CASES = frozenset(("switch_case_one", "switch_case_inline_one", "switch_case", "switch_case_inline"))
SLICES = frozenset(("slice_open", "slice", "slice_sentinel"))
TYPES = frozenset(("optional_type", "ptr_type_aligned", "ptr_type_sentinel", "ptr_type", "ptr_type_bit_range",
                   "array_type", "array_type_sentinel"))
BOOLS = frozenset(("equal_equal", "bang_equal", "less_than", "greater_than", "less_or_equal", "greater_or_equal",
                   "bool_and", "bool_or"))
JOINS = frozenset(("orelse", "catch"))
ARITH = frozenset(("mul", "div", "mod", "mul_wrap", "mul_sat", "add", "sub", "array_cat", "add_wrap", "sub_wrap",
                   "add_sat", "sub_sat", "shl", "shl_sat", "shr", "bit_and", "bit_xor", "bit_or", "merge_error_sets",
                   "array_mult", "error_union", "for_range"))
UNARY_PLAIN = frozenset(("bool_not", "negation", "bit_not", "negation_wrap"))
TRANSPARENT = frozenset(("comptime", "try", "nosuspend"))
LITERALS = frozenset(("number_literal", "char_literal", "string_literal", "multiline_string_literal"))
COMPOUND = frozenset(("assign_mul", "assign_div", "assign_mod", "assign_add", "assign_sub", "assign_shl",
                      "assign_shl_sat", "assign_shr", "assign_bit_and", "assign_bit_xor", "assign_bit_or",
                      "assign_mul_wrap", "assign_add_wrap", "assign_sub_wrap", "assign_mul_sat", "assign_add_sat",
                      "assign_sub_sat"))
ASMS = frozenset(("asm_simple", "asm", "asm_legacy"))
# r39 (round 38's lead direction, item 3): the occurrence rule, default-deny over parent tags. r40 (round 39's Opus M1
# and the lead's direction, item 1): every parent tag the walk can meet is one of four kinds. An occurrence of a var
# (an identifier node that resolves to it) climbs through every PASS-THROUGH parent, which hands the place or the
# reference on (r39 read these as reads, so `(if (c) t else t) = x` wrote t unseen); the parent above the top of the
# climb decides: a WRITE, an ADDRESS or a READ (each as these roles of these tags; None: any role); any other parent
# leaves the var unresolved. The same climb, read downwards, is the reached-var set `_reached` that the writes and the
# pointer captures use.
PASS_THROUGH = {
    "grouped_expression": ("operand",), **{t: ("operand",) for t in TRANSPARENT},
    **{t: ("then", "else") for t in IFS}, **{t: ("else",) for t in WHILES | FORS},
    **{t: ("lhs", "rhs") for t in JOINS},
    "field_access": ("object",), "array_access": ("object",), "unwrap_optional": ("object",),   # part of the var
    # by their own rules (`_climb`): a switch case's target climbs to its switch, a break's operand to the block,
    # switch or loop its label names (an unlabelled break: the loop it leaves), and `@field`'s first argument is part
}
WRITE_PARENTS = {"assign": ("lhs",), **{t: ("lhs",) for t in COMPOUND}, "assign_destructure": ("target",)}
ADDRESS_PARENTS = {"address_of": ("operand",), **{t: ("object",) for t in SLICES}}
# and by their own rules (`_address_parent`): a call's callee when the climbed node is a field access (a method-call
# receiver, since the call may take `&v` implicitly), an if's or a while's cond with a `|*p|` payload, a for's input
# whose payload is `|*p|`, a switch's cond when a prong captures `|*p|`, and a continue's operand to a labelled switch
# whose prong captures `|*p|`
READ_PARENTS = {
    **{t: ("init", "type", "align", "addrspace", "section") for t in VARDECL},
    **{t: None for t in BOOLS | ARITH | UNARY_PLAIN},
    "switch_range": None, "deref": ("operand",),
    **{t: ("callee", "arg") for t in CALLS}, **{t: ("arg",) for t in BUILTINS},
    **{t: ("cond",) for t in IFS}, **{t: ("cond", "cont", "then") for t in WHILES},
    **{t: ("input", "then") for t in FORS}, **{t: ("cond",) for t in SWITCHES},
    **{t: ("item",) for t in CASES},
    "return": ("operand",), "continue": ("operand",),
    **{t: ("elem", "field", "type") for t in ANON | TYPED_INIT},
    "array_access": ("index",), **{t: ("start", "end", "sentinel") for t in SLICES},
    **{t: ("len", "sentinel", "elem_type", "align", "addrspace", "bit_start", "bit_end", "operand") for t in TYPES},
    **{t: ("type", "align", "value") for t in FIELDS},
    **{t: ("param", "ret", "align", "addrspace", "section", "callconv") for t in FNPROTOS},
    "assign": ("rhs",), **{t: ("rhs",) for t in COMPOUND}, "assign_destructure": ("value",),
    **{t: ("arg",) for t in CONTAINERS}, "anyframe_type": ("type",),
}


class _Limit(Exception):
    pass


class O:
    """An origin: its category; the same-file container scopes it names (a type, or an instance of one: container
    nodes); the same-file functions it names (a callable); whether part of it is a plain value (a primitive, a literal,
    a pointer type) with no members to look up; whether it is a C import's namespace; the forms it went through; why it
    is unresolved."""
    __slots__ = ("cat", "conts", "fns", "plain", "cmod", "via", "why")

    def __init__(self, cat, conts=frozenset(), fns=frozenset(), plain=False, cmod=False, via=frozenset(), why=None):
        self.cat, self.conts, self.fns, self.plain, self.cmod, self.via, self.why = cat, conts, fns, plain, cmod, via, why


def join(a, b):
    if a is None:
        return b
    if b is None:
        return a
    top = a if RANK[a.cat] >= RANK[b.cat] else b
    return O(top.cat, a.conts | b.conts, a.fns | b.fns, a.plain or b.plain, a.cmod and b.cmod, a.via | b.via,
             top.why or a.why or b.why)


def _rule(r):
    return frozenset(("R:" + r,))


def _out(r, via=frozenset()):
    return O("unresolved", via=via | {"R-OUT:" + r}, why=f"a form whose rule ({r}) is outside the trusted set")


def LOCAL(rule):
    """r37: a leaf rule's local evidence, a plain value (no member to look up); UNRESOLVED-ORIGIN outside the set."""
    return O("local", plain=True, via=_rule(rule)) if rule in TRUSTED else _out(rule)


def NEUTRAL(rule):   # an anonymous literal or `undefined`: it takes its declared type, and adds nothing
    return O("local", via=_rule(rule)) if rule in TRUSTED else _out(rule)


def LOC(rule, **kw):
    """r37: a leaf rule's local evidence with containers or functions."""
    if rule not in TRUSTED:
        return _out(rule)
    kw["via"] = kw.get("via", frozenset()) | _rule(rule)
    return O("local", **kw)


def tag(o, rule):
    """r37: a propagation rule: its result is local only when every value it joined is, and then it rests on the rule
    too; outside the set, a local result becomes UNRESOLVED-ORIGIN (a non-local one stays what it is)."""
    if o.cat != "local":
        return o
    if rule not in TRUSTED:
        return _out(rule, o.via)
    return O(o.cat, o.conts, o.fns, o.plain, o.cmod, o.via | _rule(rule), o.why)


def with_rules(res, o):
    """r37: res, also resting on the rules o's local evidence rested on."""
    rs = frozenset(v for v in o.via if v.startswith("R:"))
    if res is None or not rs:
        return res
    return O(res.cat, res.conts, res.fns, res.plain, res.cmod, res.via | rs, res.why)


def pfns(o):
    """r37: the functions whose parameters an origin of category "param" came from."""
    return {int(v[2:]) for v in o.via if v.startswith("P:")}


def U(why, via=frozenset()):
    return O("unresolved", via=via, why=why)


class OriginResolver:
    """r36 to r39: a file's declarations by scope and each value's origin (see the module's documentation), from the
    compiler's parse of the file (a zigast.FileAst and its bytes). A declaration binds its name in the nearest block,
    container or file holding it; a function's parameters bind in its declaration, a capture list's names in the
    branches that see them; a container's fields are its members too. A name resolves to the declarations of that name
    in the innermost scope, from where it is used outward, that has any."""

    def __init__(self, fa, raw):
        self.fa, self.raw, self.N = fa, raw, fa.nodes
        self.ntok = len(fa.tokens)
        self.nl = [i for i, b in enumerate(raw) if b == 10]
        self.kids = fa.children
        self.containers = {i for i, n in self.N.items() if n.tag in CONTAINERS}
        self.decls, self.by_scope, self.fields, self.param_fn = [], {}, {}, {}
        self.decl_of_node = {}
        for i in sorted(self.N, key=lambda k: self.N[k].first):
            n = self.N[i]
            if n.tag in VARDECL:
                self._declaration(n)
            elif n.tag == "fn_decl":
                self._fn(n)
            elif n.tag in FNPROTOS and n.role == "member":   # an extern function: no body
                nt = n.x.get("name", -1)
                if nt >= 0:
                    self._bind(self.name(nt), self._decl_scope(n), "fn", node=i, returns=[], body=None)
            if n.tag in CONTAINERS:
                self._fields(n)
            if n.tag in IFS | WHILES | FORS | CASES or n.tag == "catch" or (n.tag == "errdefer"):
                self._captures(n)
        self.addressed, self.unclassified = set(), {}
        self._reached_memo, self._breaks_to = {}, None   # r41
        self._writes()
        self._occurrences()
        self.memo, self.busy, self.fmemo, self.steps = {}, set(), {}, 0

    # ---- tokens and nodes
    def text(self, t):
        _, s, e = self.fa.tokens[t]
        return self.raw[s:e].decode("utf-8", "replace")

    def ttag(self, t):
        return self.fa.tokens[t][0] if 0 <= t < self.ntok else None

    def name(self, t):
        """An identifier token's name (a quoted `@"..."` one decoded), or None."""
        if self.ttag(t) != "identifier":
            return None
        x = self.text(t)
        if x.startswith('@"'):
            try:
                return zigtok.unescape(x[2:-1]).decode("utf-8")
            except UnicodeDecodeError:
                return None
        return x

    def line(self, t):
        """A token's 0-based line."""
        return bisect.bisect_left(self.nl, self.fa.tokens[t][1])

    def child(self, n, role):
        for k in self.kids.get(n.i, ()):
            if self.N[k].role == role:
                return self.N[k]
        return None

    def children(self, n, role=None):
        return [self.N[k] for k in self.kids.get(n.i, ()) if role is None or self.N[k].role == role]

    def parent(self, n):
        return self.N.get(n.parent)

    def ancestors(self, n):
        while n is not None:
            yield n
            n = self.N.get(n.parent)

    def builtin_name(self, n):
        return self.text(n.main) if n.tag in BUILTINS else None

    def label_of(self, n):
        """A labelled block's label (its first tokens `name :`), or None."""
        if n.tag in BLOCKS and n.main >= 2 and self.text(n.main - 1) == ":" and self.ttag(n.main - 2) == "identifier":
            return self.name(n.main - 2)
        return None

    def node_label(self, n):
        """r40: the label of a block, a switch or a loop (the parse's `lbl` for a switch or a loop), or None."""
        if n.tag in BLOCKS:
            return self.label_of(n)
        if n.tag in SWITCHES or n.tag in WHILES or n.tag in FORS:
            lt = n.x.get("lbl", -1)
            return self.name(lt) if lt >= 0 else None
        return None

    def _break_target(self, b):
        """r40, r41 (round 40's Opus M1 and the lead's direction, item 2): the node a break or continue gives control
        to, as AstGen binds it; None when there is none inside its function. A labelled one: the block, switch or loop
        its label names (a loop's label stays in scope in its else). An unlabelled one: the innermost loop the walk up
        entered through its body (`then`) or, for a while, its continue expression (`cont`), never through its else,
        its condition or a for's input. AstGen clears a loop's unlabelled break and continue targets before its else
        (0.15.2 AstGen.zig:6782-6784 for a while, :7072-7074 for a for; 0.17.1 :6682-6686 and :6984-6988), sets them
        only after a while's condition (0.15.2 :6571 the condition's scope, :6701 the break target; 0.17.1 :6466,
        :6600), and evaluates a for's inputs in the enclosing scope (0.15.2 :6918; 0.17.1 :6826)."""
        lt = b.x.get("lbl", -1)
        label = self.name(lt) if lt >= 0 else None
        c, p = b, self.parent(b)
        while p is not None and p.tag != "fn_decl" and p.tag not in CONTAINERS:
            if label is None:
                if (p.tag in WHILES and c.role in ("then", "cont")) or (p.tag in FORS and c.role == "then"):
                    return p
            elif self.node_label(p) == label:
                return p
            c, p = p, self.parent(p)
        return None

    def _continues(self, sw_):
        """r40: the continues with an operand to a labelled switch (`continue :sw x` dispatches the switch again)."""
        label = self.node_label(sw_)
        if label is None:
            return []
        return [m for m in self._subtree(sw_, stop=frozenset(("fn_decl",)) | CONTAINERS)
                if m.tag == "continue" and m.x.get("lbl", -1) >= 0 and self.name(m.x["lbl"]) == label
                and self.child(m, "operand") is not None
                and not self._inside(m, sw_, frozenset(("fn_decl",)) | CONTAINERS)]

    def _ptr_payload(self, n, c):
        """r40: whether node c, n's cond or input, is captured by pointer (`|*p|`): an if's or a while's payload, the
        for payload at c's place among the inputs, any prong of a switch."""
        if (n.tag in IFS or n.tag in WHILES) and c.role == "cond":
            return any(ptr for _, ptr in self._payload(n.x["pay"])) if n.x.get("pay", -1) >= 0 else False
        if n.tag in FORS and c.role == "input":
            pl = self._payload(n.x["pay"]) if n.x.get("pay", -1) >= 0 else []
            ins = self.children(n, "input")
            k = next((j for j, m in enumerate(ins) if m.i == c.i), -1)
            return 0 <= k < len(pl) and pl[k][1]
        if n.tag in SWITCHES and c.role == "cond":
            return any(any(ptr for _, ptr in self._payload(cs.x["pay"])) for cs in self.children(n, "case")
                       if cs.x.get("pay", -1) >= 0)
        return False

    def _climb(self, x):
        """r40: from an occurrence, up through every pass-through parent: (the node at the top, the parent above it,
        whether a step took part of the var, whether the last step was a field access)."""
        c, partial, field_top = x, False, False
        while True:
            p = self.parent(c)
            if p is None:
                return c, None, partial, field_top
            roles = PASS_THROUGH.get(p.tag)
            if roles is not None and c.role in roles:
                if p.tag in ("field_access", "array_access", "unwrap_optional"):
                    partial = True
                field_top = p.tag == "field_access"
                c = p
                continue
            if self.builtin_name(p) == "@field" and self.children(p, "arg")[:1] == [c]:
                partial, field_top, c = True, False, p
                continue
            if p.tag in CASES and c.role == "target":
                sw_ = self.parent(p)
                if sw_ is None:
                    return c, p, partial, field_top
                c, field_top = sw_, False
                continue
            if p.tag == "break" and c.role == "operand":
                tg = self._break_target(p)
                if tg is None:
                    return c, p, partial, field_top
                c, field_top = tg, False
                continue
            return c, p, partial, field_top

    def _breaks_into(self, n):
        """r41: the breaks with an operand that give control to node n (`_break_target`), indexed once per file."""
        if self._breaks_to is None:
            self._breaks_to = {}
            for m in self.N.values():
                if m.tag == "break" and self.child(m, "operand") is not None:
                    tg = self._break_target(m)
                    if tg is not None:
                        self._breaks_to.setdefault(tg.i, []).append(m)
        return self._breaks_to.get(n.i, ())

    def _reached(self, n):
        """r40, r41 (round 40's Sol M1, Opus M2 and the lead's direction, item 1): the vars a place or reference node
        reaches, the climb read downwards: {var declaration index: whether only part of it}, or None when the walk
        cannot finish (a resource limit), which the callers read as every var unresolved, never as an empty set. Walked
        with an explicit stack and no depth limit (r40 recursed and returned {} past depth 200, so a write 201
        groupings deep went unseen): through grouping, `comptime`, `try`, `nosuspend`, both branches of an if, a
        switch's prong targets and the breaks to it, a labelled block's breaks, a loop's else and its breaks, both sides
        of `orelse` and `catch`, and a field, an index, an unwrap or a `@field` (part)."""
        if n is None:
            return {}
        if n.i in self._reached_memo:
            return self._reached_memo[n.i]
        out, todo, steps, budget = {}, [(n, False)], 0, 2 * len(self.N) + 64
        while todo:
            steps += 1
            if steps > budget:   # every node is entered once (its parent's role, or its break's one target)
                self._reached_memo[n.i] = None
                return None
            m, part = todo.pop()
            t_ = m.tag
            kids = []
            if t_ == "identifier":
                for i in self._var_at(m):
                    out[i] = out.get(i, True) and part
            elif t_ == "grouped_expression" or t_ in TRANSPARENT:
                kids = [(self.child(m, "operand"), part)]
            elif t_ in IFS:
                kids = [(self.child(m, "then"), part), (self.child(m, "else"), part)]
            elif t_ in JOINS:
                kids = [(self.child(m, "lhs"), part), (self.child(m, "rhs"), part)]
            elif t_ in ("field_access", "array_access", "unwrap_optional"):
                kids = [(self.child(m, "object"), True)]
            elif self.builtin_name(m) == "@field":
                a_ = self.children(m, "arg")
                kids = [(a_[0] if a_ else None, True)]
            else:
                if t_ in SWITCHES:
                    kids += [(self.child(cs, "target"), part) for cs in self.children(m, "case")]
                if t_ in WHILES or t_ in FORS:
                    kids.append((self.child(m, "else"), part))
                if t_ in SWITCHES or t_ in WHILES or t_ in FORS or t_ in BLOCKS:
                    kids += [(self.child(b_, "operand"), part) for b_ in self._breaks_into(m)]
            todo.extend((k, pt) for k, pt in kids if k is not None)
        self._reached_memo[n.i] = out
        return out

    def string_value(self, n):
        """A string literal node's decoded value, or None (any other node)."""
        if n is None or n.tag != "string_literal":
            return None
        return zigtok.string_value(zigtok.Token("string", self.text(n.main), 0, 0))

    def _subtree(self, n, stop=frozenset()):
        """n's descendants, not entering nodes whose tag is in `stop` (those are yielded, their insides not)."""
        todo = list(self.kids.get(n.i, ()))
        while todo:
            m = self.N[todo.pop()]
            yield m
            if m.tag not in stop:
                todo.extend(self.kids.get(m.i, ()))

    # ---- structure
    def _bind(self, name, scope, kind, **kw):
        d = dict(name=name, scope=scope, kind=kind, vals=[], ann=None, body=None, node=None, returns=[], cap=None)
        d.update(kw)
        self.decls.append(d)
        self.by_scope.setdefault((scope, name), []).append(len(self.decls) - 1)
        return len(self.decls) - 1

    def _decl_scope(self, n):
        """The block, container or file a declaration node binds in: its nearest such ancestor."""
        p = self.parent(n)
        while p is not None and not (p.tag in BLOCKS or p.tag in CONTAINERS):
            p = self.parent(p)
        return p.i if p is not None else 0

    def _declaration(self, n):
        mut = n.x["mut"]
        ann, init = self.child(n, "type"), self.child(n, "init")
        i = self._bind(self.name(mut + 1), self._decl_scope(n), self.text(mut), node=n.i,
                       vals=[("expr", init.i)] if init is not None else [], ann=ann.i if ann is not None else None)
        self.decl_of_node[n.i] = i

    def _fn(self, n):
        proto, body = self.child(n, "proto"), self.child(n, "body")
        nt = proto.x.get("name", -1) if proto is not None else -1
        if nt < 0:
            return
        returns = [m for m in self._subtree(body, stop=frozenset(("fn_decl",)) | CONTAINERS)
                   if m.tag == "return" and not self._inside(m, body, frozenset(("fn_decl",)) | CONTAINERS)]
        ret = self.child(proto, "ret")
        # r37 (round 36's Opus M1): a labelled return type (`fn get() blk: { ... } { ... }`) leaves the return
        # unresolved; r39: any labelled block in the return type's nodes
        labelled = ret is not None and (self.label_of(ret) is not None
                                        or any(self.label_of(m) is not None for m in self._subtree(ret)))
        fn_i = self._bind(self.name(nt), self._decl_scope(n), "fn", node=n.i, returns=[m.i for m in returns],
                          body=body.i if body is not None else None, labelled=labelled)
        for pt, _ in proto.x.get("p", ()):
            if pt >= 0:
                self.param_fn[self._bind(self.name(pt), n.i, "param", node=n.i)] = fn_i

    def _inside(self, m, top, stop):
        """Whether m lies inside a node with a tag in `stop` below `top`."""
        p = self.parent(m)
        while p is not None and p.i != top.i:
            if p.tag in stop:
                return True
            p = self.parent(p)
        return False

    def _fields(self, n):
        """A container's fields: `name: T [= default]` (`comptime` too), a tuple's fields by index, and an enum's or
        a union's bare `name`."""
        kind = "struct" if n.tag == "root" else self.text(n.main)
        out, k = {}, 0
        for f in self.children(n, "member"):
            if f.tag not in FIELDS:
                continue
            ty, dflt = self.child(f, "type"), self.child(f, "value")
            comptime = f.x.get("ct", -1) >= 0
            if f.x.get("tuple") == 1:
                if kind in ("enum", "union") and ty is not None and ty.tag == "identifier":
                    out[self.name(ty.main)] = dict(type=None, default=None, comptime=False)
                else:
                    out[str(k)] = dict(type=ty.i if ty is not None else None, default=dflt.i if dflt else None,
                                       comptime=comptime)
                    k += 1
                continue
            out[self.name(f.main)] = dict(type=ty.i if ty is not None else None,
                                          default=dflt.i if dflt is not None else None, comptime=comptime)
        self.fields[n.i] = out

    def _payload(self, first):
        """A capture list's names from its first token (after the opening `|`): [(name, is a pointer)]."""
        out, t = [], first
        while 0 <= t < self.ntok and self.text(t) != "|":
            ptr = self.text(t) == "*"
            if ptr:
                t += 1
            if self.ttag(t) == "identifier":
                out.append((self.name(t), ptr))
            t += 1
            if 0 <= t < self.ntok and self.text(t) == ",":
                t += 1
        return out

    def _captures(self, n):
        def bind(names, scopes, ops):
            for k_, (nm, ptr) in enumerate(names):
                op = ops[k_] if k_ < len(ops) else None
                for sc in scopes:
                    if sc is not None:
                        self._bind(nm, sc.i, "capture", cap=op, node=n.i, ptr=ptr)

        if n.tag in IFS or n.tag in WHILES:
            cond = self.child(n, "cond")
            if n.x.get("pay", -1) >= 0:
                sc = [self.child(n, "then")] + ([self.child(n, "cont")] if n.tag in WHILES else [])
                bind(self._payload(n.x["pay"]), sc, [("op", cond.i)])
            if n.x.get("err", -1) >= 0:
                bind(self._payload(n.x["err"]), [self.child(n, "else")], [None])
        elif n.tag in FORS:
            bind(self._payload(n.x["pay"]), [self.child(n, "then")], [("op", m.i) for m in self.children(n, "input")])
        elif n.tag in CASES:
            if n.x.get("pay", -1) >= 0:
                sw = self.parent(n)
                cond = self.child(sw, "cond") if sw is not None else None
                op = ("op", cond.i) if cond is not None else ("unresolved", "a switch prong's capture whose switch "
                                                               "the gate cannot find")
                if cond is not None and self._continues(sw):   # r40: `continue :sw x` dispatches with x too
                    op = ("ops", cond.i) + tuple(self.child(m, "operand").i for m in self._continues(sw))
                bind(self._payload(n.x["pay"]), [self.child(n, "target")], [op])
        elif n.main + 1 < self.ntok and self.text(n.main + 1) == "|":   # `catch |e|`, `errdefer |e|`
            bind(self._payload(n.main + 2), [self.child(n, "rhs") or self.child(n, "operand")], [None])

    def _var_at(self, ident):
        """The var declarations an identifier node resolves to ([] when it names none)."""
        if ident is None:
            return []
        return [i for i in (self.resolve(self.name(ident.main), ident) or ()) if self.decls[i]["kind"] == "var"]

    def _tuple_of(self, n):
        """A destructured value's element nodes: a tuple literal, also behind grouping or `comptime`, or a labelled
        block whose one break gives one; else None."""
        while n is not None and n.tag in ("comptime", "grouped_expression"):
            n = self.child(n, "operand")
        if n is None:
            return None
        if n.tag in TUPLES:
            return self.children(n, "elem")
        lbl = self.label_of(n)
        if lbl is not None:
            brk = self._breaks(n, lbl)
            if len(brk) == 1:
                op = self.child(brk[0], "operand")
                return self._tuple_of(op) if op is not None else None
        return None

    def _breaks(self, blk, label):
        return [m for m in self._subtree(blk, stop=frozenset(("fn_decl",)) | CONTAINERS)
                if m.tag == "break" and m.x.get("lbl", -1) >= 0 and self.name(m.x["lbl"]) == label
                and not self._inside(m, blk, frozenset(("fn_decl",)) | CONTAINERS)]

    def _writes(self):
        """r39 (round 38's lead direction, items 2 and 3): every write a var's value takes, from the nodes: an assign
        (its target the var, whole, or a field, index, unwrap or `@field` of it: part), a compound assign (part), and a
        destructure, each target its element when the value is a tuple literal of as many elements, else
        UNRESOLVED-DESTRUCTURING; a declaration among the targets takes its element the same way."""
        for n in self.N.values():
            if n.tag == "assign" or n.tag in COMPOUND:
                lhs, rhs = self.child(n, "lhs"), self.child(n, "rhs")
                for i, partial in (self._reached(lhs) or {}).items():   # r40: the reached set; r41: None: see below
                    self.decls[i]["vals"].append(("part" if partial or n.tag in COMPOUND else "expr", rhs.i))
            elif n.tag == "assign_destructure":
                targets, value = self.children(n, "target"), self.child(n, "value")
                els = self._tuple_of(value)
                matched = els is not None and len(els) == len(targets)
                for k_, t_ in enumerate(targets):
                    if t_.tag in VARDECL:
                        d = self.decls[self.decl_of_node[t_.i]]
                        d["vals"] = [("expr", els[k_].i) if matched else ("udestr", value.i)]
                        continue
                    for i, partial in (self._reached(t_) or {}).items():   # r40: the reached set (`_` reaches nothing)
                        self.decls[i]["vals"].append((("part" if partial else "expr"), els[k_].i) if matched
                                                     else ("udestr", value.i))
        for d in self.decls:   # r37: a pointer capture over an operand rooted at a var; r40: every var it reaches
            if d["kind"] == "capture" and d.get("ptr") and d["cap"] and d["cap"][0] in ("op", "ops"):
                for k in (d["cap"][1:] if d["cap"][0] == "ops" else [d["cap"][1]]):
                    op = self.N[k]
                    while op is not None and op.tag == "address_of":
                        op = self.child(op, "operand")
                    r_ = self._reached(op)
                    if r_ is None:   # r41: a walk that cannot finish leaves every var under the subject unresolved
                        for x_ in [op] + list(self._subtree(op)):
                            for i in self._var_at(x_) if x_.tag == "identifier" else ():
                                self.unclassified.setdefault(i, "a pointer capture whose subject's walk could not "
                                                                "finish (a resource limit)")
                        continue
                    for i in r_:
                        self.addressed.add(i)

    def _occurrences(self):
        """r39 (round 38's lead direction, item 3); r40 (round 39's Opus M1 and the lead's direction, item 1): every
        occurrence of a var (an identifier node that resolves to one) climbs through every PASS-THROUGH parent
        (`_climb`), and the parent above the top of the climb decides: a WRITE (`_writes` takes its value), an ADDRESS
        (the var is address-taken), a READ, or anything else, which leaves the var unresolved."""
        for x in self.N.values():
            if x.tag != "identifier":
                continue
            vs = self._var_at(x)
            if not vs:
                continue
            c, p, _, field_top = self._climb(x)
            addr = p is not None and self._address_parent(p, c, field_top)
            if p is None:
                why = "an occurrence of the var at the file's top"
            elif addr or (p.tag in WRITE_PARENTS and c.role in WRITE_PARENTS[p.tag]):
                # r41 (round 40's Opus M2 and the lead's direction, item 1): the INVARIANT, both traversals agreeing: a
                # write or an address counts only when the walk down from where the climb stopped reaches the var
                r_ = self._reached(c)
                if r_ is not None and all(i in r_ for i in vs):
                    if addr:
                        for i in vs:
                            self.addressed.add(i)
                    continue   # an address, or a write (_writes took its value)
                kind_ = "an address" if addr else "a write"
                why = (f"{kind_} through the {c.role} of a {p.tag} whose place's walk could not finish (a resource "
                       f"limit)" if r_ is None else f"{kind_} through the {c.role} of a {p.tag} whose place's walk does "
                       f"not reach the var")
            elif p.tag in READ_PARENTS and (READ_PARENTS[p.tag] is None or c.role in READ_PARENTS[p.tag]):
                continue   # a read
            else:
                why = f"an occurrence of the var as the {c.role} of a {p.tag}"
            for i in vs:
                self.unclassified.setdefault(i, why + ", which the gate cannot classify")

    def _address_parent(self, p, c, field_top):
        """r40: whether parent p takes the address of its child c (the top of a climb): ADDRESS_PARENTS, a method-call
        receiver, a cond or input captured by pointer, and a continue's operand to a labelled switch whose prong
        captures by pointer."""
        if p.tag in ADDRESS_PARENTS and c.role in ADDRESS_PARENTS[p.tag]:
            return True
        if p.tag in CALLS and c.role == "callee" and field_top:
            return True
        if c.role in ("cond", "input") and (p.tag in IFS or p.tag in WHILES or p.tag in FORS or p.tag in SWITCHES):
            return self._ptr_payload(p, c)
        if p.tag == "continue" and c.role == "operand":
            tg = self._break_target(p)
            return tg is not None and tg.tag in SWITCHES and self._ptr_payload(tg, self.child(tg, "cond"))
        return False

    def resolve(self, name, at):
        for a in self.ancestors(at):
            hit = self.by_scope.get((a.i, name))
            if hit:
                return hit
        return None

    def _enclosing_container(self, n):
        for a in self.ancestors(n):
            if a.tag in CONTAINERS:
                return a.i
        return 0

    # ---- origins
    def _step(self):
        self.steps += 1
        if self.steps > LIMIT:
            raise _Limit()

    def decl_origin(self, i):
        if i in self.memo:
            return self.memo[i]
        if i in self.busy:
            return U("a cycle", via=frozenset(("cycle",)))
        self.busy.add(i)
        try:
            o = self._decl_origin(i)
            if self.decls[i]["kind"] == "var":   # r38 (item 1): a var binding is evidence only through "var"
                o = tag(o, "var")
        finally:
            self.busy.discard(i)
        self.memo[i] = o
        return o

    def _decl_origin(self, i):
        d = self.decls[i]
        k = d["kind"]
        if k == "param":   # r37: it keeps its function, so it never passes outside it
            return O("param", via=frozenset((f"P:{self.param_fn[i]}",)))
        if k == "fn":
            return LOC("fnref", fns=frozenset((i,)))
        if k == "capture":
            c = d["cap"]
            if c is None:
                return LOCAL("errcapture")   # an error value, or a `for` index
            if c[0] == "unresolved":
                return U(c[1], via=frozenset(("capture",)))
            o = None
            for k in (c[1:] if c[0] == "ops" else (c[1],)):   # r40: a labelled switch's continues too
                o = join(o, self.expr(self.N[k]))
            o = O(o.cat, o.conts, o.fns, o.plain, o.cmod, o.via | {"capture"}, o.why)
            return tag(o, "capture")
        parts_rules = None
        if i in self.addressed or i in self.unclassified:   # r37 (round 36's Sol M2, Opus M1); r38, r39 (the occurrence rule)
            fixed = self._fixed_type(self.N[d["ann"]]) if d["ann"] is not None else None
            if fixed is not None:   # its declared type fixes what a write through a pointer, or any write, can store
                return tag(fixed, "addrtyped")
            if i in self.addressed:
                return U("an address-taken var, whose writes through a pointer the gate does not follow",
                         via=frozenset(("address",)))
            return U(self.unclassified[i], via=frozenset(("occurrence",)))
        res = None
        for v in d["vals"]:
            if v[0] == "expr":
                res = join(res, self.expr(self.N[v[1]]))
            elif v[0] == "part":   # an element or field assigned: its category joins, not its containers
                o = self.expr(self.N[v[1]])
                if o.cat != "local":
                    res = join(res, O(o.cat, via=o.via, why=o.why))
                else:
                    parts_rules = with_rules(parts_rules, o) if parts_rules is not None else o
            else:   # r38 (round 37's Opus M1, F1): an element not matched element-wise to a literal: unresolved
                o = self.expr(self.N[v[1]])   # destructuring, whatever the whole value's category
                res = join(res, O("udestr", via=o.via | {"destructuring"},
                                  why="a destructuring element the gate cannot match element-wise"))
        if d["ann"] is not None:
            a = self.expr(self.N[d["ann"]])
            if res is None:
                res = tag(a, "annotation")
            else:
                if a.cat != "local":
                    res = join(res, O(a.cat, via=a.via, why=a.why))
                if a.conts or a.cmod:
                    res = O(res.cat, res.conts | a.conts, res.fns, res.plain and not a.conts, res.cmod or a.cmod,
                            res.via | a.via, res.why)
                    res = tag(res, "annotation")
                elif a.cat == "local" and a.plain and not res.conts and not res.fns:
                    res = O(res.cat, res.conts, res.fns, True, res.cmod, res.via, res.why)
                res = with_rules(res, a)
        if res is None:
            return U("a declaration with no value")
        if parts_rules is not None:
            res = with_rules(res, parts_rules)
        return tag(res, "decl")

    def fn_return(self, i):
        if i in self.fmemo:
            return self.fmemo[i]
        if ("fn", i) in self.busy:
            return U("a cycle", via=frozenset(("cycle",)))
        self.busy.add(("fn", i))
        try:
            d = self.decls[i]
            if d["body"] is None:
                o = U("a function with no body")
            elif d.get("labelled"):
                o = U("a function whose return type is a labelled block")
            elif not d["returns"]:
                o = LOCAL("voidfn")   # it returns void or never returns
            else:
                o = None
                for r in d["returns"]:
                    v = self.child(self.N[r], "operand")
                    if v is None:
                        o = join(o, U("an empty value"))
                        continue
                    if v.tag == "identifier":   # r37: a bare parameter
                        hit = self.resolve(self.name(v.main), v) or ()
                        if hit and all(self.decls[j]["kind"] == "param" and self.param_fn.get(j) == i for j in hit):
                            o = join(o, O("local", via=frozenset(("BAREPARAM",))))
                            continue
                    o = join(o, self.expr(v))
        finally:
            self.busy.discard(("fn", i))
        self.fmemo[i] = o
        return o

    def member(self, o, name):
        if o.cat != "local":
            return O(o.cat, via=o.via, why=o.why)
        if o.cmod:
            return tag(O("local", cmod=True, via=o.via), "cimport")
        if not o.conts:   # a value with no container (a primitive, a literal, a pointer type) has no member; one
            return U("a member of a value the gate cannot name", via=o.via)   # that is sometimes a container: its containers'
        res = None
        for c in o.conts:
            hit = self.by_scope.get((c, name))
            if hit:
                for i in hit:
                    res = join(res, self.decl_origin(i))
                continue
            f = self.fields.get(c, {}).get(name)
            if f is None:
                return U("a member the gate cannot find", via=o.via)
            res = join(res, self.field_origin(f))
        cat = "derived" if res.cat == "std" and "call" in o.via else res.cat   # std reached through a return
        return tag(O(cat, res.conts, res.fns, res.plain, res.cmod, res.via | o.via, res.why), "member")

    def _bare(self, n):
        """r37, r39: whether a type node is a bare name, a chain of names (`a.b.c`) or `@This()`."""
        if n.tag == "identifier":
            return True
        if n.tag == "field_access":
            return self._bare(self.child(n, "object"))
        return self.builtin_name(n) == "@This" and not self.children(n, "arg")

    def _prim_type(self, n):
        return n.tag == "identifier" and PRIMITIVE.match(self.text(n.main)) is not None \
            and self.text(n.main) not in ("type", "anyopaque", "anyframe", "noreturn")

    def _fixed_type(self, n):
        """r37: the origin a declared type gives its value when it fixes it (a primitive other than `type`, written out:
        a plain value; a bare name, chain or `@This()` naming a same-file container: an instance of it), else None."""
        if self._prim_type(n):
            return O("local", plain=True)
        if self._bare(n):
            o = self.expr(n)
            if o.cat == "local" and o.conts and not o.fns:
                return O("local", o.conts, frozenset(), False, o.cmod, o.via, None)
        return None

    def field_origin(self, f):
        """r37 (round 36's Opus M1): a field's value is local only when its declared type fixes it: a same-file container
        (a bare name, a chain or `@This()` naming one: its value is an instance of it) or a primitive other than `type`
        written out (its value is a number, a bool, ...); any other type (`?type`, `[1]type`, `(type)`, an alias of
        `type`, a pointer, an optional) leaves the value unresolved, and so does a comptime field."""
        if f["type"] is None:
            return LOCAL("enumfield")   # an enum's field: a value of the enum
        if f["comptime"]:
            return U("a comptime field, whose value the gate does not model")
        n = self.N[f["type"]]
        if self._prim_type(n):
            return LOCAL("fieldtype")
        if self._bare(n):
            o = self.expr(n)
            if o.cat == "local" and o.conts and not o.fns:
                return tag(O("local", o.conts, frozenset(), False, o.cmod, o.via, None), "fieldtype")
            if o.cat != "local":
                return O(o.cat, via=o.via, why=o.why)
        return U("a field whose declared type does not fix its value")

    def call(self, callee, args):
        """r37 (round 36's Opus M1): a same-file call's result is its returns' origin; a bare returned parameter passes
        the arguments; a parameter's origin from the callee (a member or a chain of one) never leaves it (unresolved);
        and every non-local argument joins the result."""
        argo, nonlocal_ = None, None
        for a_ in args:
            a = self.expr(a_)
            argo = join(argo, a)
            if a.cat != "local":
                nonlocal_ = join(nonlocal_, O(a.cat, via=a.via, why=a.why))
        if callee.cat in ("std", "derived"):
            return O("derived", via=callee.via | {"call"})
        if callee.cat in ("import", "param"):
            r = O(callee.cat, via=callee.via)
            if nonlocal_ is not None:
                r = join(r, O("derived", via=nonlocal_.via) if nonlocal_.cat in ("std", "derived") else nonlocal_)
            return r
        if callee.cat != "local":
            return O(callee.cat, via=callee.via, why=callee.why)
        if not callee.fns:
            return U("a call of a value the gate cannot name", via=callee.via)
        res = None
        for f in callee.fns:
            r = self.fn_return(f)
            if r.cat == "param" and f in pfns(r):
                r = U("a callee's parameter reached through its return (a parameter never leaves its function)",
                      via=r.via)
            elif "BAREPARAM" in r.via:   # it returns a bare parameter: the arguments' origin
                base = O(r.cat, r.conts, r.fns, r.plain, r.cmod, r.via - {"BAREPARAM"}, r.why)
                r = tag(join(base, argo if argo is not None else LOCAL("voidfn")), "callparam")
            res = join(res, r)
        if nonlocal_ is not None:
            res = join(res, O("derived", via=nonlocal_.via) if nonlocal_.cat in ("std", "derived") else nonlocal_)
        cat = "derived" if res.cat == "std" else res.cat   # a same-file function's return: derived (round 34's Opus L2)
        return tag(O(cat, res.conts, res.fns, res.plain, res.cmod, res.via | {"call"}, res.why), "call")

    def expr(self, n):
        """r39: a value node's origin, by its tag (each node's own children are its operands)."""
        self._step()
        t = n.tag
        if t in TRANSPARENT:
            return self.expr(self.child(n, "operand"))
        if t in ("return", "break", "continue", "unreachable_literal"):
            return NEUTRAL("noreturn")   # noreturn: it gives the value nothing
        if t in IFS:
            return self._if(n)
        if t in SWITCHES:
            return self._switch(n)
        if t in BOOLS:
            return LOCAL("bool")   # r39: a comparison's or a boolean operator's node, exactly
        if t in JOINS or t in ARITH:
            a, b = self.expr(self.child(n, "lhs") or self.child(n, "start")), None
            rhs = self.child(n, "rhs") or self.child(n, "end")
            if rhs is not None:
                b = self.expr(rhs)
            o = join(a, b)
            lvl0 = t in JOINS
            o = O(o.cat, o.conts if lvl0 else frozenset(), o.fns if lvl0 else frozenset(), o.plain or not lvl0,
                  o.cmod, o.via, o.why)
            return tag(o, "orelse" if lvl0 else "arith")
        if t == "address_of":
            return tag(self.expr(self.child(n, "operand")), "arith")
        if t in UNARY_PLAIN:
            o = self.expr(self.child(n, "operand"))
            return tag(O(o.cat, plain=True, via=o.via, why=o.why), "arith")
        if t in TYPES:
            return self._ptrtype(n)
        if t == "grouped_expression":
            o = self.expr(self.child(n, "operand"))
            return tag(O(o.cat, o.conts, o.fns, o.plain, o.cmod, o.via | {"parens"}, o.why), "parens")
        if t in BUILTINS:
            return self.builtin(n)
        if t in BLOCKS:
            lbl = self.label_of(n)
            if lbl is None:
                return NEUTRAL("voidblock")
            o = self._block(n, lbl)
            return tag(O(o.cat, o.conts, o.fns, o.plain, o.cmod, o.via | {"block"}, o.why), "block")
        if t in CONTAINERS:
            return LOC("container", conts=frozenset((n.i,)))
        if t in ("error_set_decl", "error_value"):
            return LOCAL("error")
        if t in FNPROTOS:
            return LOCAL("fntype")   # a function type
        if t in ASMS:
            return LOCAL("asm")
        if t in ANON:
            o = None
            for e in self.children(n, "elem") + self.children(n, "field"):
                o = join(o, self.expr(e))
            if o is None:
                return NEUTRAL("anon")
            if o.cat == "local":   # r38 (round 37's Opus M1, F2): its elements' evidence too
                return tag(O("local", via=o.via), "anon")
            return O(o.cat, via=o.via, why=o.why)
        if t == "enum_literal":
            return NEUTRAL("enumlit")
        if t in LITERALS:
            return LOCAL("literal")
        if t == "identifier":
            nm = self.name(n.main)
            hit = self.resolve(nm, n) if nm is not None else None
            if hit:
                o = None
                for i in hit:
                    o = join(o, self.decl_origin(i))
                return o
            if nm == "std":
                return O("std")
            if nm in ("true", "false", "null"):
                return LOCAL("constant")
            if nm is not None and PRIMITIVE.match(nm):
                return LOCAL("prim")
            if nm == "undefined":
                return NEUTRAL("undef")
            return U(f"a name this file does not declare ({nm})")
        if t == "field_access":
            return self.member(self.expr(self.child(n, "object")), self.name(n.last))
        if t == "deref":
            return tag(self.expr(self.child(n, "operand")), "deref")
        if t == "unwrap_optional":
            return tag(self.expr(self.child(n, "object")), "unwrap")
        if t in CALLS:
            return self.call(self.expr(self.child(n, "callee")), self.children(n, "arg"))
        if t == "array_access" or t in SLICES:
            o = self.expr(self.child(n, "object"))
            if o.cat != "local":
                return O(o.cat, via=o.via | {"index"}, why=o.why)
            if o.plain and not o.conts and not o.fns:
                return O("local", plain=True, via=o.via | _rule("indexplain")) if "indexplain" in TRUSTED \
                    else _out("indexplain", o.via)
            # r37 (round 36's Opus M1): an index of an instance (a tuple or an array of containers): unresolved
            return U("an index of an instance, which the gate does not model", via=o.via)
        if t in TYPED_INIT:
            o = self.expr(self.child(n, "type"))
            if o.plain and not o.conts:   # an array literal (`[_]T{...}`, T no container): its elements are the value
                c = None
                for e in self.children(n, "elem") + self.children(n, "field"):
                    c = join(c, self.expr(e))
                if o.cat != "local":   # r39 (the per-rule comparison with r38): a non-local element type joins too,
                    # since every element is a T (`[_]std.X{imp.x}`: `@TypeOf(arr[0])` is std.X); r38's reader parsed
                    # `[_]T{...}` as `[_](T{...})`, an instance of T, so it failed that form only by accident
                    c = join(c, O(o.cat, via=o.via, why=o.why))
                if c is not None and c.cat != "local":
                    return O(c.cat, via=o.via | c.via, why=c.why)
                return tag(O("local", plain=True, via=o.via | (c.via if c is not None else frozenset())), "arraylit")
            return tag(O(o.cat, o.conts, o.fns, False, o.cmod, o.via, o.why), "instance")   # an instance of the type
        return U("a value the gate does not model")

    def _ptrtype(self, n):
        """r39 (round 38's Opus L2): a pointer, optional, slice or array type over its element type, every other part
        (a length, a sentinel, an alignment, an address space, a bit range) joined: a non-local part gives the type its
        category, a local one its rules. An array literal's inferred length, the `_` of `[_]T`, has no value of its own:
        the literal's element count gives it."""
        elem = self.child(n, "elem_type") or self.child(n, "operand")
        o = self.expr(elem)
        for p in self.children(n):
            if p.i == elem.i:
                continue
            if p.role == "len" and p.tag == "identifier" and self.text(p.main) == "_":
                continue
            po = self.expr(p)
            if po.cat != "local":
                o = join(o, O(po.cat, via=po.via, why=po.why))
            else:
                o = with_rules(o, po)
        return tag(O(o.cat, o.conts, frozenset(), not o.conts, o.cmod, o.via, o.why), "ptrtype")

    def _branch_value(self, n):
        """A branch's value: an unlabelled block gives nothing to the value (voidblock)."""
        if n.tag in BLOCKS and self.label_of(n) is None:
            return NEUTRAL("voidblock")
        return self.expr(n)

    def _if(self, n):
        a = self._branch_value(self.child(n, "then"))
        e = self.child(n, "else")
        o = a if e is None else join(a, self._branch_value(e))
        return tag(O(o.cat, o.conts, o.fns, o.plain, o.cmod, o.via | {"branch"}, o.why), "branch")

    def _switch(self, n):
        res = None
        for case in self.children(n, "case"):
            res = join(res, self._branch_value(self.child(case, "target")))
        lbl = self.node_label(n)
        if lbl is not None:   # r40 (round 39's Opus M2): a labelled switch's value is also what it breaks with
            for b in self._breaks(n, lbl):
                op = self.child(b, "operand")
                res = join(res, self.expr(op) if op is not None else NEUTRAL("voidblock"))
        if res is None:
            return NEUTRAL("voidblock")
        return tag(O(res.cat, res.conts, res.fns, res.plain, res.cmod, res.via | {"branch"}, res.why), "branch")

    def _block(self, n, label):
        """A labelled block's value: what it breaks with to its label (a break with no value gives voidblock's)."""
        res = None
        for b in self._breaks(n, label):
            op = self.child(b, "operand")
            res = join(res, self.expr(op) if op is not None else NEUTRAL("voidblock"))
        return res if res is not None else NEUTRAL("voidblock")

    def builtin(self, n):
        name = self.builtin_name(n)
        args = self.children(n, "arg")
        if name == "@import":
            v = self.string_value(args[0]) if len(args) == 1 else None
            if v == "std":
                return O("std")
            if v == "builtin":
                return O("std", via=frozenset(("builtin",)))
            if v is None:
                return U("an @import the gate cannot read")
            return O("import")
        if name == "@cImport":
            return LOC("cimport", cmod=True)
        if name == "@This":
            return LOC("this", conts=frozenset((self._enclosing_container(n),)))
        if name in VALUE_BUILTINS_SAME:
            res = None
            for a in args:
                res = join(res, self.expr(a))
            if res is not None and res.cat == "local" and "R:newbuiltin" in res.via:
                # r37 (the lead's self-review): a local value's type is local, but not a value a builtin made, whose
                # type is the builtin's (`@TypeOf(@typeInfo(u8))` is std.builtin.Type, `@errorReturnTrace()`'s std's)
                return U("@TypeOf of a value a builtin made, whose type the gate does not know", via=res.via)
            return tag(res, "typeof") if res is not None else U("an empty @TypeOf")
        if name == "@as":   # r37 (round 36's Sol M1): the type and the value, joined
            if len(args) != 2:
                return U("an @as the gate cannot read")
            o = join(self.expr(args[0]), self.expr(args[1]))
            return tag(O(o.cat, o.conts, o.fns, o.plain, o.cmod, o.via | {"@as"}, o.why), "as")
        if name in ("@field", "@FieldType"):
            if len(args) != 2:
                return U(f"an {name} the gate cannot read")
            c = self.expr(args[0])
            lit = self.string_value(args[1])
            if lit is None:
                if c.cat == "local" and c.cmod:
                    return tag(O("local", cmod=True, via=c.via), "cimport")
                if c.cat == "local":
                    return U(f"an {name} whose name is not a literal")
                return O(c.cat, via=c.via, why=c.why)
            m = self.member(c, lit)
            cat = "derived" if name == "@FieldType" and m.cat == "std" else m.cat   # a field's type: through a builtin
            return tag(O(cat, m.conts, m.fns, m.plain, m.cmod, m.via | {name}, m.why), "fieldlit")
        if name in FEATURE_BUILTINS - {"@typeInfo"} or name in ("@sizeOf", "@alignOf", "@bitSizeOf", "@offsetOf",
                                                                   "@bitOffsetOf", "@tagName", "@typeName",
                                                                   "@errorName", "@inComptime", "@returnAddress",
                                                                   "@frameAddress", "@intFromBool", "@hasField",
                                                                   "@breakpoint"):
            return LOCAL("valuebuiltin")   # a bool, a number, a string or void (r38, round 37's Opus L2: @breakpoint)
        if name in ("@compileError", "@panic", "@trap"):
            return NEUTRAL("noreturn")
        res = None   # any other builtin makes a new value: derived when its arguments reach std
        for a in args:
            res = join(res, self.expr(a))
        if res is None:
            return LOCAL("newbuiltin")
        cat = "derived" if res.cat in ("std", "derived") else res.cat
        return tag(O(cat, plain=True, via=res.via | {name}, why=res.why), "newbuiltin")

    def encloses(self, fn_i, at):
        """r37: whether function fn_i's declaration holds the node `at`."""
        top = self.decls[fn_i]["node"]
        return any(a.i == top for a in self.ancestors(at))

    def subject(self, n):
        """A feature test's subject's origin; a resource limit or a too-deep value is "unresolved"; r37: a parameter's
        origin reported outside its function is unresolved (round 36's Opus M1)."""
        try:
            o = self.expr(n)
            if o.cat == "param" and not all(self.encloses(f, n) for f in pfns(o)):
                return U("a parameter's origin outside its function", via=o.via)
            return o
        except _Limit:
            return U("a resource limit", via=frozenset(("limit",)))
        except RecursionError:
            return U("a resource limit (recursion)", via=frozenset(("limit",)))


def _callee_args(res, n):
    """When node n is a call's callee, the call's argument nodes, else None."""
    p = res.parent(n)
    if p is not None and p.tag in CALLS and n.role == "callee":
        return res.children(p, "arg")
    return None


def feature_origins(res):
    """r36, r39: [(line, origin)] of every feature test in a file (`@hasDecl`, `@hasField`, `@typeInfo`, a called
    `hasFn` or `hasMethod`), its subject's origin by OriginResolver, in token order."""
    out = []
    for n in sorted(res.N.values(), key=lambda m: m.main):
        if n.tag in BUILTINS:
            name = res.builtin_name(n)
            args = res.children(n, "arg")
            if name in FEATURE_BUILTINS:
                if args:
                    out.append((res.line(n.main), res.subject(args[0])))
                continue
            if name == "@field" and len(args) == 2 and res.string_value(args[1]) in FEATURE_FNS:
                cargs = _callee_args(res, n)   # r37: `@field(std.meta, "hasFn")`, a decoded name
                if cargs is None:
                    out.append((res.line(n.main), U("a hasFn or hasMethod reference that is no direct call",
                                                    via=frozenset(("ref",)))))
                elif cargs:
                    out.append((res.line(n.main), res.subject(cargs[0])))
            continue
        # r37 (round 36's Opus M3): the names decoded (`std.meta.@"hasFn"(...)`), and a hasFn or hasMethod reference
        # that is no direct call (`const has = std.meta.hasFn;`, `@call(.auto, std.meta.hasFn, ...)`) is unresolved
        if n.tag == "identifier" and res.name(n.main) in FEATURE_FNS:
            tok = n.main
        elif n.tag == "field_access" and res.name(n.last) in FEATURE_FNS:
            tok = n.last
        else:
            continue
        cargs = _callee_args(res, n)
        if cargs is None:
            out.append((res.line(tok), U("a hasFn or hasMethod reference that is no direct call",
                                         via=frozenset(("ref",)))))
        elif cargs:
            out.append((res.line(tok), res.subject(cargs[0])))
    return out


def names_builtin(res):
    """r37 (round 36's Opus M2): whether a file names `@import("builtin")` or holds an `@import` the gate cannot read.
    The nonliteral @field rule no longer depends on it (it runs in every file); measure39.py reads it to split the
    rule's verdicts between such files and the others."""
    for n in res.N.values():
        if res.builtin_name(n) == "@import":
            args = res.children(n, "arg")
            v = res.string_value(args[0]) if len(args) == 1 else None
            if v is None or v == "builtin":
                return True
    return False


def field_name_unknown(res):
    """r36, r37, r39: the lines of each `@field` whose name is no string literal, where it could name zig_version: in
    every file, any such `@field` whose object is neither positively local nor a boundary class."""
    out = []
    for n in sorted(res.N.values(), key=lambda m: m.main):
        if res.builtin_name(n) != "@field":
            continue
        args = res.children(n, "arg")
        if len(args) != 2 or args[1].tag == "string_literal":
            continue
        o = res.subject(args[0])
        if o.cat not in ("local", "import", "param"):
            out.append(res.line(n.main))
    return out


def version_uses(res):
    """r36 (round 35's Opus M2), r39: [(line, name)] of each use of zig_version or zig_version_string: an identifier
    token so named (a quoted one decoded), or a literal-name `@field` node whose decoded name is one."""
    out = []
    for t in range(res.ntok):
        nm = res.name(t)
        if nm in VERSION_NAMES:
            out.append((res.line(t), nm))
    for n in res.N.values():
        if res.builtin_name(n) == "@field":
            args = res.children(n, "arg")
            if len(args) == 2:
                v = res.string_value(args[1])
                if v in VERSION_NAMES:
                    out.append((res.line(n.main), v))
    return sorted(out)
# @@RESOLVER-END@@


# r39: the bytes whose absence shows a file has no feature test, no `@field` and no zig_version name (a quoted
# identifier could spell any name): such a file's parse result alone is read, every other file's tokens and nodes
NEEDS_AST = (b"@hasDecl", b"@hasField", b"@typeInfo", b"@field", b"hasFn", b"hasMethod", b"zig_version", b'@"')
args = sys.argv[1:]
REPORT = "--report-only" in args
ORIGINS = "--origins" in args
args = [a for a in args if a not in ("--report-only", "--origins")]
ASTDUMP = WORK = None
REV = "HEAD"   # r45: the commit a git checkout is read as
for opt in ("--astdump", "--work", "--rev"):
    if opt in args:
        k = args.index(opt)
        if k + 1 >= len(args):
            sys.exit(f"{opt} takes a value")
        if opt == "--astdump":
            ASTDUMP = args[k + 1]
        elif opt == "--rev":
            REV = args[k + 1]
        else:
            WORK = args[k + 1]
        del args[k:k + 2]
if len(args) != 2:
    sys.exit("usage: residue_gate17.py <checkout dir> <allowance.tsv> --astdump <exe> [--work <dir>] [--rev <commit>] "
             "[--report-only] [--origins]")
root, allow_path = args
# r40 (round 39's Opus L1): the tree's pin decides which compiler's parse the gate reads; r41 (round 40's Opus M3 (a)):
# a tree pinned below 0.17 fails ACTIVE-015-SELECTION on that pin (the text checks below), and the gate reads none of
# its Zig files, so no astdump is needed and the residue job never needs the 1A compiler
# r42 (round 41's Opus M1, L2 and the lead's direction, item 1): the pin is read once, strictly, and nothing else reads
# it: the root must hold build.zig.zon under that exact name (no case variant of it or of build.zig beside it), valid
# UTF-8 with no NUL and one minimum_zig_version; anything else exits 2 before any check


def _bad_setup(why):
    print("BAD-SETUP: " + why + ": the gate reads a tree only through its pinned compiler's parse")
    sys.exit(2)


try:
    _root_names = os.listdir(root)
except OSError as e:
    _bad_setup(f"the checkout cannot be listed ({type(e).__name__})")
_variants = sorted(n for n in _root_names if n.lower() in ("build.zig.zon", "build.zig") and n not in ("build.zig.zon",
                                                                                                       "build.zig"))
if _variants:
    _bad_setup("a case variant of build.zig.zon or build.zig at the root (" + ", ".join(_variants) + ")")
if "build.zig.zon" not in _root_names or not os.path.isfile(os.path.join(root, "build.zig.zon")):
    _bad_setup("the tree has no build.zig.zon at its root")
TRACKED = None   # r43 (round 42's Opus M3 and the lead's direction, item 4): a git checkout's tracked list
# r44 (round 43's Sol M1, M3, Opus M1, L2 and the lead's direction, items 1 and 2): in a git checkout each tracked
# path's mode and object (`git ls-files -s -z`), the bytes of every blob (`git cat-file --batch`: a file's content, a
# link's text) and the attributes that make git rewrite a path at checkout (`git check-attr --cached`); the pin too is
# read from its blob
# r45 (round 44's Muse M1, Sol M1, Opus L1 and the lead's direction, item 1): r44 read the index, and git followed
# replace refs, so a staged change or a replaced blob showed the gate other bytes than the commit; now one commit, HEAD
# or --rev, is read with replace objects off (`git --no-replace-objects`) and no GIT_* variable from the caller (no
# GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES,
# GIT_REPLACE_REF_BASE, GIT_CONFIG_*): its tree (`git ls-tree -r -z`) gives the tracked paths, their modes and objects,
# `git cat-file --batch` their bytes and `git check-attr --source` their attributes; the index must equal that tree
# entry for entry (INDEX-NOT-COMMIT, below)
INDEX, BLOB, TRANSFORMED = {}, {}, {}
COMMIT, INDEX_DIFFERS = None, []
_GIT_ENV = {k_: v_ for k_, v_ in os.environ.items() if not k_.upper().startswith("GIT_")}


def _git(*a, inp=None):
    return subprocess.run(["git", "--no-replace-objects", "-C", root, *a], input=inp, capture_output=True, check=True,
                          env=_GIT_ENV).stdout


if os.path.lexists(os.path.join(root, ".git")):
    try:
        COMMIT = _git("rev-parse", "--verify", "--end-of-options", REV + "^{commit}").decode("ascii").strip()
        _lt = _git("ls-tree", "-r", "-z", "--full-tree", COMMIT).decode("utf-8")
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError) as e:
        _bad_setup(f"the checkout's commit {REV!a} or its tree cannot be read (git rev-parse, ls-tree: {type(e).__name__})")
    print(f"COMMIT {COMMIT} ({REV!a})")
    TRACKED = []
    for _e in _lt.split("\0"):
        if not _e:
            continue
        _meta, _tab, _p = _e.partition("\t")
        _f = _meta.split(" ")
        if not _tab or not _p or len(_f) != 3:
            _bad_setup("the commit's tree gives an entry that is not `<mode> <type> <object>` and a path")
        TRACKED.append(_p)
        INDEX[_p] = (_f[0], _f[2])
    try:
        _ls = _git("ls-files", "-s", "-z").decode("utf-8")
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError) as e:
        _bad_setup(f"the checkout's index cannot be read (git ls-files: {type(e).__name__})")
    _idx = {}
    for _e in _ls.split("\0"):
        if not _e:
            continue
        _meta, _tab, _p = _e.partition("\t")
        _f = _meta.split(" ")
        if not _tab or not _p or len(_f) != 3:
            _bad_setup("the checkout's index gives an entry that is not `<mode> <object> <stage>` and a path")
        if _f[2] != "0":
            _bad_setup(f"the checkout's index holds an unmerged path ({_p[:60]!a})")
        _idx[_p] = (_f[0], _f[1])
    INDEX_DIFFERS = sorted(p_ for p_ in set(_idx) | set(INDEX) if _idx.get(p_) != INDEX.get(p_))
    _ids = sorted({o_ for m_, o_ in INDEX.values() if m_ in ("100644", "100755", "120000")})
    try:
        _cat = _git("cat-file", "--batch", inp="".join(i_ + "\n" for i_ in _ids).encode("ascii"))
    except (OSError, subprocess.CalledProcessError, UnicodeEncodeError) as e:
        _bad_setup(f"the commit's blobs cannot be read (git cat-file: {type(e).__name__})")
    _objs, _k = {}, 0
    while _k < len(_cat):
        _nl = _cat.find(b"\n", _k)
        _h = _cat[_k:_nl if _nl >= 0 else len(_cat)].decode("ascii", "replace").split(" ")
        if _nl < 0 or len(_h) != 3 or _h[1] != "blob" or not _h[2].isascii() or not _h[2].isdigit():
            _bad_setup(f"a tracked path's object is no blob git cat-file gives ({' '.join(_h)[:60]})")
        _objs[_h[0]] = _cat[_nl + 1:_nl + 1 + int(_h[2])]
        _k = _nl + 1 + int(_h[2]) + 1
    if set(_ids) - set(_objs):
        _bad_setup(f"the commit's blobs cannot be read ({len(set(_ids) - set(_objs))} objects missing)")
    BLOB = {p_: _objs[o_] for p_, (m_, o_) in INDEX.items() if o_ in _objs and m_ in ("100644", "100755", "120000")}
    try:
        _ca = _git("check-attr", "-z", "--source=" + COMMIT, "--stdin", "filter", "working-tree-encoding", "ident",
                   inp="".join(p_ + "\0" for p_ in TRACKED).encode("utf-8")).decode("utf-8")
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError) as e:
        _bad_setup(f"the commit's attributes cannot be read (git check-attr: {type(e).__name__})")
    _ca = _ca.split("\0")
    for _j in range(0, len(_ca) - 2, 3):
        if _ca[_j + 2] not in ("unspecified", "unset"):
            TRANSFORMED.setdefault(_ca[_j], []).append(_ca[_j + 1] + ("" if _ca[_j + 2] == "set" else "=" + _ca[_j + 2]))
    if INDEX.get("build.zig.zon", ("",))[0] not in ("100644", "100755"):
        _bad_setup("build.zig.zon at the root is no tracked file")
    _zb = BLOB["build.zig.zon"]
else:
    try:
        _zb = open(os.path.join(root, "build.zig.zon"), "rb").read()
    except OSError as e:
        _bad_setup(f"build.zig.zon cannot be read ({type(e).__name__})")
PIN, _why = zigast.read_pin(_zb)   # r43 (round 42's Sol M2, Opus M2): Zig's tokens, the reading the binding check shares
if _why:
    _bad_setup(_why)
READ_ZIG = PIN >= (0, 17)
if READ_ZIG and (ASTDUMP is None or not os.path.exists(ASTDUMP)):
    print("BAD-SETUP: no astdump executable (--astdump): the gate reads Zig only through the pinned compiler's parse")
    sys.exit(2)
MENTION = re.compile(r"(?<![0-9.])0\.15(?![0-9])")
CONTEXT_BEFORE = re.compile(r"(?i)zig|--compiler\b|\bcompiler\b")
SKIP_DIRS = {".git", ".zig-cache", "zig-cache", "zig-out"}
prefixes, content_ok, counts, zv_ok, zvs_ok, ft_ok, dt_ok, uo_ok = [], {}, {}, set(), set(), {}, {}, {}
zig_rows, zig_matches = {}, {}   # r41 (round 40's Opus M3 (b)); r42: (workflow, job, step) -> (producer, sha256)
COUNTED = ("count", "feature-tests", "derived-tests", "unresolved-origin")


def _degenerate(p):
    """r45 (round 44's Opus L2 and the lead's direction, item 3): why a row's key is degenerate, or None: an empty
    path, a prefix that does not end in `/`, an empty content line, or a count that is no positive ASCII number."""
    if p[0] not in ("prefix", "content", "zig-version-use", "zig-version-string-use", "setup-zig-step") + COUNTED:
        return None   # an unknown kind: refused below
    if len(p) < 2 or not p[1].strip(" \t"):
        return "an empty path"
    if p[0] == "prefix" and not p[1].endswith("/"):
        return "a prefix that does not end in /"
    if p[0] == "content" and (len(p) < 3 or not p[2].strip(" \t")):
        return "an empty content line"
    if p[0] in COUNTED and (len(p) < 3 or not re.fullmatch(r"[0-9]+", p[2])):
        return "a count that is no ASCII number"
    if p[0] in COUNTED and int(p[2]) == 0:
        return "a zero count"
    return None


try:
    with open(allow_path, encoding="utf-8") as allowance_file:
        allowance_lines = list(allowance_file)
except (OSError, UnicodeDecodeError) as error:
    print(f"FAIL UNREADABLE {allow_path}: the allowance cannot be read ({type(error).__name__})")
    print("RESULT FAIL (1 failures) UNREADABLE=1")
    sys.exit(1)

allowance_keys = set()
for l in allowance_lines:
    if not l.strip() or l.startswith("#"):
        continue
    p = l.rstrip("\n").split("\t")
    _dg = _degenerate(p)
    if _dg:
        sys.exit(f"BAD-ALLOWANCE {allow_path}: {_dg}: {l.strip()[:80]}")
    key = tuple(p[:4] if p[0] == "setup-zig-step" else
                (p[0], p[1], p[2].strip()) if p[0] == "content" else p[:2])
    if key in allowance_keys:
        sys.exit(f"BAD-ALLOWANCE {allow_path}: duplicate key {key!a}")
    allowance_keys.add(key)
    if p[0] == "prefix" and len(p) >= 2:
        prefixes.append(p[1])
    elif p[0] == "content" and len(p) >= 3 and p[2].strip():
        content_ok.setdefault(p[1], set()).add(p[2].strip())
    elif p[0] == "count" and len(p) >= 3:
        counts[p[1]] = int(p[2])
    elif p[0] == "zig-version-use" and len(p) >= 2:
        zv_ok.add(p[1])
    elif p[0] == "zig-version-string-use" and len(p) >= 2:   # r36 (round 35's Opus M2)
        zvs_ok.add(p[1])
    elif p[0] == "feature-tests" and len(p) >= 3:
        ft_ok[p[1]] = int(p[2])
    elif p[0] == "derived-tests" and len(p) >= 3:   # r35 (round 34's Opus L2)
        dt_ok[p[1]] = int(p[2])
    elif p[0] == "unresolved-origin" and len(p) >= 3:   # r36 (round 35's lead direction)
        uo_ok[p[1]] = int(p[2])
    elif p[0] == "setup-zig-step" and len(p) >= 7 and all(x.strip() for x in p[1:6]) \
            and re.fullmatch(r"[0-9a-f]{64}", p[5]):   # r41 (round 40's Opus M3 (b)); r42 (round 41's): bound
        zig_rows[(p[1], p[2], p[3])] = (p[4], p[5])
        zig_matches[(p[1], p[2], p[3])] = 0
    else:
        sys.exit(f"BAD-ALLOWANCE {allow_path}: {l.strip()[:80]}")


def same_file(a, b):
    """L4: compare by normalised absolute path, which also works when the checkout and the allowance sit on different
    drives (r29 took a relative path between them and crashed)."""
    return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))


def versions(line, tsv):
    """The version-context mentions on one line (their count)."""
    n = 0
    for m in MENTION.finditer(line):
        after, before = line[m.end():], line[:m.start()]
        if re.match(r"\.(?:\d|x\b)", after) or CONTEXT_BEFORE.search(before):
            n += 1
        elif tsv and (before.endswith("\t") or not before) and (after.startswith("\t") or not after.strip()):
            n += 1
    return n


failures, seen, content_seen, ft_seen, dt_seen, uo_seen, zv_seen, zvs_seen = [], {}, set(), {}, {}, {}, set(), set()
if PIN < (0, 17):   # r42: recorded from the pin itself, before anything else, and only then said
    failures.append(f"ACTIVE-015-SELECTION build.zig.zon: minimum_zig_version {PIN[0]}.{PIN[1]}")
    print(f"NOTE: build.zig.zon pins {PIN[0]}.{PIN[1]}, below 0.17: ACTIVE-015-SELECTION is recorded, and the gate reads "
          f"none of the tree's Zig files")
tally = {}
zig_files = []   # (rel, full path, bytes) of every .zig file (r42: every one but under SKIP_DIRS; r43: at the root only)
ci_files = {}   # r42: the text of every .yml or .yaml file under .github/
TEXT_EXT = (".zig", ".zon", ".yml", ".yaml", ".tsv")
read_rel = set()   # r43: every path the gate read (or, for the allowance, passed over by design), as the checkout spells it
_listing = {}


def _exact_path(rel):
    """r43: the full path of `rel` when every component exists with exactly that case (each directory listed), else
    None (a case-insensitive file system would open another spelling)."""
    cur = root
    for part in rel.split("/"):
        if not part or part in (".", ".."):
            return None
        if cur not in _listing:
            try:
                _listing[cur] = set(os.listdir(cur))
            except OSError:
                _listing[cur] = set()
        if part not in _listing[cur]:
            return None
        cur = os.path.join(cur, part)
    return cur


def _bom_text(data):
    """r43 (the user's decision on round 42's Opus L2): a file that starts with a UTF-32 or UTF-16 byte-order mark,
    decoded by that mark code unit by code unit: lone surrogates kept, a trailing partial code unit dropped (a UTF-32
    unit above U+10FFFF read as U+FFFD); None for any other file."""
    if data[:4] in (b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff"):
        order, body = ("little" if data[0] == 0xFF else "big"), data[4:]
        units = (int.from_bytes(body[k:k + 4], order) for k in range(0, len(body) - len(body) % 4, 4))
        return "".join(chr(u) if u <= 0x10FFFF else "\N{REPLACEMENT CHARACTER}" for u in units)
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        body = data[2:len(data) - len(data) % 2]
        return body.decode("utf-16-le" if data[0] == 0xFF else "utf-16-be", "surrogatepass")
    return None


LINK_NAMES = (".zig", ".zon", ".yml", ".yaml")   # r44: with Dockerfile, the names a tracked link may not take
_blob_parse = set()   # r44: tracked .zig files whose checkout bytes are not their blob's: parsed from the blob


def _held_to_blob(rel, full, data):
    """r44 (round 43's Sol M3, Opus M1 and the lead's direction, item 1): CHECKOUT-DIFFERS when the checkout's file at a
    tracked path is a link, or its bytes are not the blob's beyond CR LF against LF."""
    if os.path.islink(full):
        failures.append(f"CHECKOUT-DIFFERS {rel}: the checkout holds a link where the commit holds a file")
        return
    try:
        got = open(full, "rb").read()
    except OSError as e:   # r45 (round 44's Muse L1): named
        failures.append(f"UNREADABLE {rel}: the checkout's file cannot be read ({type(e).__name__})")
        return
    if got != data:
        _blob_parse.add(rel)
        if got.replace(b"\r\n", b"\n") != data.replace(b"\r\n", b"\n"):
            failures.append(f"CHECKOUT-DIFFERS {rel}: the checkout's bytes differ from the commit's beyond CR LF against "
                            f"LF, so Zig would read other bytes than GitHub")


def _link_dest(rel, target):
    """r44: the tree path a tracked link's text names, from the link's directory (`/` and `\\` both separate), or None
    when the text is absolute or leaves the tree."""
    if not target or target[0] in "/\\" or re.match(r"[A-Za-z]:", target):
        return None
    parts = rel.split("/")[:-1]
    for seg in re.split(r"[/\\]", target):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(seg)
    return "/".join(parts)


def _read_link(rel, full):
    """r44 (round 43's Sol M1, Opus L2 and the lead's direction, item 2): a tracked link (mode 120000) is read as its
    link text, the blob, under its own path, and never followed: TRACKED-LINK when its name is one the gate interprets
    (.zig, .zon, .yml, .yaml or Dockerfile, any case) or its target is a directory, lies outside the tree or (r45)
    is no tracked regular file (a build's output, say, which no build has written yet); the
    checkout must hold that link, or a file of its text (core.symlinks off), else CHECKOUT-DIFFERS."""
    read_rel.add(rel)
    text = BLOB[rel]
    target = text.decode("utf-8", "replace")
    name = ciyaml.lower_ascii(rel.rsplit("/", 1)[-1])
    why = []
    if name.endswith(LINK_NAMES) or name == "dockerfile":
        why.append("a name the gate interprets")
    dest = _link_dest(rel, target)
    if dest is None:
        why.append("a target outside the tree")
    elif dest == "" or any(p_.startswith(dest + "/") for p_ in TRACKED) or os.path.isdir(os.path.join(root, dest)):
        why.append("a directory as its target")
    elif INDEX.get(dest, ("",))[0] not in ("100644", "100755"):   # r45 (round 44's Opus M1): src/gen -> ../zig-out/gen
        why.append("a target that is no tracked regular file")
    if why:
        failures.append(f"TRACKED-LINK {rel}: a tracked link with {' and '.join(why)} ({target[:60]!a}), which the gate "
                        f"does not follow")
    if os.path.islink(full):
        try:
            ok = os.readlink(full).replace("\\", "/") == target.replace("\\", "/")
        except OSError:
            ok = False
    else:
        try:
            ok = os.path.isfile(full) and open(full, "rb").read() == text
        except OSError as e:   # r45: named
            failures.append(f"UNREADABLE {rel}: the checkout's file cannot be read ({type(e).__name__})")
            ok = True
    if not ok:
        failures.append(f"CHECKOUT-DIFFERS {rel}: the checkout holds neither the tracked link nor a file of its text")
    _scan(rel, None, text, True)


def _read_file(rel, full):
    """One file of the checkout. r44: a tracked file's content is its index blob, the checkout's file held to it
    (_held_to_blob); a tracked link is read by _read_link; a submodule is not read (TRACKED-UNREAD)."""
    if TRACKED is not None and rel in INDEX:
        if INDEX[rel][0] == "120000":
            _read_link(rel, full)
            return
        if INDEX[rel][0] not in ("100644", "100755"):
            return
    read_rel.add(rel)
    if TRACKED is not None and rel in INDEX:
        data = BLOB[rel]
        _held_to_blob(rel, full, data)
    else:
        data = None
    if same_file(full, allow_path) or rel == "ci/fixture/residue-allow.tsv":
        return
    if data is None:
        try:
            data = open(full, "rb").read()
        except OSError as e:   # r45 (round 44's Muse L1): an untracked file the walk lists but cannot open, named
            failures.append(f"UNREADABLE {rel}: the file cannot be read ({type(e).__name__})")
            return
    _scan(rel, full, data, False)


def _scan(rel, full, data, link):
    """A file's bytes (r44: a tracked file's blob, a tracked link's text): NOT-TEXT, the Zig and CI file lists (never
    for a link), and the mention checks."""
    if rel.lower().endswith(TEXT_EXT) and not link:   # r42 (round 41's Opus M1 and the lead's direction, item 2): no silent skip
        bad = None
        if b"\0" in data:
            bad = f"a NUL at byte {data.index(bytes(1))}"
        else:
            try:
                texts = [data.decode("utf-8")]
            except UnicodeDecodeError as e:
                bad = f"invalid UTF-8 at byte {e.start}"
        if bad:
            failures.append(f"NOT-TEXT {rel}: {bad}, so the gate cannot read it as text")
            return
    else:
        bom = _bom_text(data)
        if bom is not None:   # r43: its code units and its bytes
            texts = [bom, data.decode("latin-1")]
        elif b"\0" in data:
            texts = [data.decode("latin-1")]   # every other file is scanned over its bytes, each byte mapped
        else:
            try:
                texts = [data.decode("utf-8")]
            except UnicodeDecodeError:
                texts = [data.decode("latin-1")]
    if rel.lower().endswith(".zig") and not link:   # r40: pkg/ too; r42 (round 41's Opus L1): every .zig file
        zig_files.append((rel, os.path.abspath(full), data))
    if rel.startswith(".github/") and rel.lower().endswith((".yml", ".yaml")) and not link:
        ci_files[rel] = texts[0]
    tsv = rel.endswith(".tsv")
    n_hits = 0
    for text in texts:
        for i, l in enumerate(text.splitlines(), 1):
            k = versions(l, tsv)
            if not k:
                continue
            n_hits += k
            if rel in counts or any(rel.startswith(px) for px in prefixes):
                continue
            if l.strip() in content_ok.get(rel, ()):
                content_seen.add((rel, l.strip()))
                continue
            failures.append(f"RESIDUE-015 {rel}:{i}: a Zig 0.15 mention outside the allowance")
    if rel in counts:
        seen[rel] = n_hits


if TRACKED is not None and INDEX_DIFFERS:   # r45: INDEX-NOT-COMMIT, first
    failures.append(f"INDEX-NOT-COMMIT {COMMIT[:12]}: the index differs from the commit's tree at {len(INDEX_DIFFERS)} "
                    f"paths ({', '.join(INDEX_DIFFERS[:3])!a}{', ...' if len(INDEX_DIFFERS) > 3 else ''}), so the "
                    f"checkout need not be the commit GitHub runs")
if TRACKED is not None:   # r43: CASE-COLLISION, before the walk
    _folds = {}
    for p_ in TRACKED:
        _folds.setdefault(p_.casefold(), []).append(p_)
    for grp in sorted(sorted(v) for v in _folds.values() if len(v) > 1):
        failures.append(f"CASE-COLLISION {', '.join(grp)}: tracked paths equal under case folding (a case-insensitive "
                        f"checkout keeps one of them)")
    for p_ in TRACKED:   # r44: TRANSFORMED-PATH, before the walk
        if p_ in TRANSFORMED:
            failures.append(f"TRANSFORMED-PATH {p_}: git rewrites this tracked path between the commit and the checkout "
                            f"({', '.join(TRANSFORMED[p_])}), so Zig would read other bytes than GitHub")
_root_n = os.path.normcase(os.path.abspath(root))
def _walk_error(e):   # r45: a directory the walk cannot list, named (os.walk would skip it silently)
    failures.append(f"UNREADABLE {os.path.relpath(e.filename, root).replace(chr(92), '/')}: the directory cannot be "
                    f"listed ({type(e).__name__})")


def _walk_path(full):
    rel = os.path.relpath(full, root).replace("\\", "/")
    if any(0xd800 <= ord(char) <= 0xdfff for char in rel):
        display = rel.encode("utf-8", "backslashreplace").decode("utf-8")
        failures.append(f"UNREADABLE {display}: the path is not valid Unicode")
        return None
    return rel


for dirpath, dirnames, filenames in os.walk(root, onerror=_walk_error):
    descend = []
    for name in sorted(dirnames):
        full = os.path.join(dirpath, name)
        rel = _walk_path(full)
        if rel is None:
            continue
        if os.path.islink(full) or os.path.isjunction(full):
            if TRACKED is not None and INDEX.get(rel, ("",))[0] == "120000":
                _read_file(rel, full)
            else:
                failures.append(f"UNREADABLE {rel}: directory link")
            continue
        descend.append(name)
    if os.path.normcase(os.path.abspath(dirpath)) == _root_n:   # r43 (round 42's Opus L1): skip directories at the root only
        dirnames[:] = [d for d in descend if d not in SKIP_DIRS]
    else:
        dirnames[:] = descend
    for name in sorted(filenames):
        full = os.path.join(dirpath, name)
        rel = _walk_path(full)
        if rel is not None:
            _read_file(rel, full)
if TRACKED is not None:   # r43: a tracked file is always read (one under a root skip directory too); r44 (round 43's
    for p_ in TRACKED:    # Sol M1, Opus L2): a tracked link by its link text (_read_link), never followed, wherever it is
        if p_ in read_rel:
            continue
        full = _exact_path(p_)
        if full is not None and (INDEX[p_][0] == "120000" or os.path.isfile(full)):
            _read_file(p_, full)
    for p_ in TRACKED:
        if p_ not in read_rel and INDEX[p_][0] == "160000":   # r45 (round 44's Opus L3): the reason named
            failures.append(f"TRACKED-UNREAD {p_}: a submodule (a gitlink), whose content the gate does not read")
        elif p_ not in read_rel:
            failures.append(f"TRACKED-UNREAD {p_}: a tracked path the gate did not read (missing from the checkout, or "
                            f"spelled otherwise there)")
# r42 (round 41's Sol M1, Opus M2 and the lead's direction, items 4 and 5): every CI file under .github/ and every local
# action they name, read through ciyaml.py's closed subset or failed CI-UNREADABLE; each setup-zig step bound to an
# explicit version


def _ci_strings(node):
    """Every key and scalar of a read document, with its line."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield k, (node.lines.get(k) if hasattr(node, "lines") else getattr(k, "line", None))
            yield from _ci_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from _ci_strings(v)
    elif isinstance(node, str):
        yield node, getattr(node, "line", None)


def _folds_to(n, names):
    """r44 (round 43's Opus M2): whether a directory entry is one of `names` (lowercase) under case folding, or under the
    uppercase mapping: what a case-insensitive file system may take for that name (either counts)."""
    return n.casefold() in names or n.upper().casefold() in names


def _ci_local(path, rel, todo):
    """r43 (round 42's Sol M3 and the lead's direction, item 3): the file a local `uses` names (its path after `./`,
    whole, as ciyaml.classify_uses gives it), queued; a failure line when no single file holds it with that exact
    case; None when it is queued, or when it is a Docker action outside the boundary (its own code is not read). r44
    (round 43's Opus M2 and the lead's direction, item 3): the metadata names are counted under case folding (the
    Windows runner's lookup ignores case) and the one read must be spelled exactly."""
    if ciyaml.lower_ascii(path).endswith((".yml", ".yaml")):   # a local reusable workflow
        full = _exact_path(path)
        if full is None or not os.path.isfile(full):
            return f"CI-UNREADABLE {rel}: a local reference the checkout does not hold with that exact case (./{path[:60]})"
        todo.append(path)
        return None
    d = _exact_path(path)
    if d is None or not os.path.isdir(d):
        return f"CI-UNREADABLE {rel}: a local action the checkout does not hold with that exact case (./{path[:60]})"
    try:
        names = sorted(os.listdir(d))
    except OSError as error:
        return f"UNREADABLE {path}: the local action directory cannot be listed ({type(error).__name__})"
    meta = [n for n in names if _folds_to(n, ("action.yml", "action.yaml"))]
    if meta:
        if set(meta) == {"action.yml", "action.yaml"}:
            return f"CI-UNREADABLE {rel}: the local action ./{path[:60]} has both an action.yml and an action.yaml"
        if len(meta) != 1 or meta[0] not in ("action.yml", "action.yaml"):
            return (f"CI-UNREADABLE {rel}: the local action ./{path[:60]} holds {', '.join(meta)!a}: exactly one "
                    f"action.yml or action.yaml, spelled exactly, is read")
        todo.append(path + "/" + meta[0])
        return None
    dock = [n for n in names if _folds_to(n, ("dockerfile",))]
    if dock == ["Dockerfile"]:
        return None
    if dock:
        return (f"CI-UNREADABLE {rel}: the local action ./{path[:60]} holds {', '.join(dock)!a} and no action.yml or "
                f"action.yaml: only one file spelled Dockerfile makes a Docker action")
    return f"CI-UNREADABLE {rel}: the local action ./{path[:60]} has no action.yml, action.yaml or Dockerfile"


def _ci_check(rel, doc, rd, todo):
    if doc is not None and not isinstance(doc, ciyaml.CiMap):
        failures.append(f"CI-UNREADABLE {rel}: the document is no block mapping")
        return
    groups = []   # (job, its steps)
    if doc is not None and "jobs" in doc:
        jobs = doc["jobs"]
        if not isinstance(jobs, ciyaml.CiMap):
            failures.append(f"CI-UNREADABLE {rel}:{doc.lines['jobs']}: `jobs` is no block mapping")
            return
        for job, jv in jobs.items():
            if not isinstance(jv, ciyaml.CiMap):
                failures.append(f"CI-UNREADABLE {rel}:{jobs.lines[job]}: the job `{job}` is no block mapping")
                continue
            ju = jv.get("uses")
            if isinstance(ju, str):   # r43: a reusable workflow's reference, in the closed grammar
                form, info = ciyaml.classify_uses(str(ju))
                if form is None:
                    failures.append(f"CI-UNREADABLE {rel}:{jv.lines.get('uses', jv.line)}: {info} ({str(ju)[:60]})")
                elif form == "local":
                    f_ = _ci_local(info, rel, todo)
                    if f_:
                        failures.append(f_)
            if "steps" in jv:
                groups.append((job, jv["steps"], jv.lines["steps"]))
    if doc is not None and isinstance(doc.get("runs"), ciyaml.CiMap) and "steps" in doc["runs"]:
        groups.append(("(action)", doc["runs"]["steps"], doc["runs"].lines["steps"]))
    elif doc is not None and "runs" in doc and not isinstance(doc["runs"], ciyaml.CiMap):
        failures.append(f"CI-UNREADABLE {rel}:{doc.lines['runs']}: `runs` is no block mapping")
    zig_uses = set()
    for job, seq, sline in groups:
        if not isinstance(seq, ciyaml.CiSeq):
            failures.append(f"CI-UNREADABLE {rel}:{sline}: the steps of `{job}` are no block sequence")
            continue
        for k, st in enumerate(seq):
            line = seq.spans[k][0]
            if not isinstance(st, ciyaml.CiMap):
                failures.append(f"CI-UNREADABLE {rel}:{line}: a step of `{job}` that is no block mapping")
                continue
            u = st.get("uses")
            if u is None:
                continue
            if not isinstance(u, str):
                failures.append(f"CI-UNREADABLE {rel}:{line}: a step whose uses is no scalar")
                continue
            form, info = ciyaml.classify_uses(str(u))   # r43: the closed uses grammar
            if form is None:
                failures.append(f"CI-UNREADABLE {rel}:{st.lines.get('uses', line)}: {info} ({str(u)[:60]})")
                continue
            if form == "local":
                f_ = _ci_local(info, rel, todo)
                if f_:
                    failures.append(f_)
            if "setup-zig" not in ciyaml.lower_ascii(u):   # r44: ASCII case only
                continue
            zig_uses.add(id(u))
            sid = st.get("id")
            key = (rel, job, str(sid) if sid is not None else None)
            if key in zig_matches:
                zig_matches[key] += 1
            w = st.get("with")
            ver = w.get("version") if isinstance(w, ciyaml.CiMap) else None
            if not isinstance(ver, str):
                failures.append(f"ACTIVE-015-SELECTION {rel}:{st.lines.get('uses', line)}: a setup-zig step with no "
                                f"with.version, so setup-zig "
                                f"would read whichever build.zig.zon the job checked out")
                continue
            # r44 (round 43's Sol M2, Opus M3 and the lead's direction, item 4): a literal is the one ASCII form
            # zigast.VERSION_FORM, quoted or plain (YAML reads it as a string); any other spelling is unread
            lit = zigast.VERSION_FORM.fullmatch(str(ver))
            if lit:
                if (int(lit.group(1)), int(lit.group(2))) < (0, 17):
                    failures.append(f"ACTIVE-015-SELECTION {rel}:{ver.line}: setup-zig version {lit.group(1)}."
                                    f"{lit.group(2)}")
                continue
            if key not in zig_rows:
                if "${{" in str(ver):
                    failures.append(f"ACTIVE-015-SELECTION {rel}:{ver.line}: a setup-zig version that is no literal "
                                    f"({str(ver)[:40]}), in a step no setup-zig-step row binds (job `{job}`, step "
                                    f"`{sid}`)")
                else:
                    failures.append(f"ACTIVE-015-SELECTION {rel}:{ver.line}: a setup-zig version the gate cannot read "
                                    f"({str(ver)[:40]!a}; it reads N.N.N or N.N.N-dev.N+<hex>, ASCII), in a step no "
                                    f"setup-zig-step row binds (job `{job}`, step `{sid}`)")
                continue
            producer, sha = zig_rows[key]
            if str(ver) != "${{ steps." + producer + ".outputs.version }}":
                failures.append(f"ACTIVE-015-SELECTION {rel}:{ver.line}: the bound step's version is not exactly "
                                f"${{{{ steps.{producer}.outputs.version }}}}")
                continue
            prev = [j for j in range(k) if isinstance(seq[j], ciyaml.CiMap) and str(seq[j].get("id")) == producer]
            if len(prev) != 1:
                failures.append(f"ACTIVE-015-SELECTION {rel}:{line}: no single earlier step `{producer}` in the job "
                                f"`{job}` produces the bound version")
                continue
            got = hashlib.sha256(rd.step_text(seq.spans[prev[0]]).encode("utf-8")).hexdigest()
            if got != sha:
                failures.append(f"ACTIVE-015-SELECTION {rel}:{seq.spans[prev[0]][0]}: the producer step `{producer}`'s "
                                f"text changed (sha256 {got[:12]}..., the row's {sha[:12]}...)")
    for s_, line in _ci_strings(doc):   # a setup-zig mention anywhere else (a comment aside) fails
        if "setup-zig" in ciyaml.lower_ascii(s_) and id(s_) not in zig_uses:   # r44: ASCII case only
            if getattr(s_, "style", None) == "block":   # the line inside the block scalar that holds it
                line = s_.line + 1 + next(k for k, l_ in enumerate(s_.split("\n")) if "setup-zig" in ciyaml.lower_ascii(l_))
            failures.append(f"ACTIVE-015-SELECTION {rel}:{line}: a setup-zig mention outside a setup-zig step's uses")
# r39 (round 38's lead direction, item 1; the user's decision after the blocker report): every Zig file the gate reads
# through the pinned compiler's parse; a rejected file fails, and a dump zigast.py rejects is not read
_tmp = None
if WORK is None:
    _tmp = tempfile.TemporaryDirectory()
    WORK = _tmp.name
os.makedirs(WORK, exist_ok=True)
_todo, _done = sorted(ci_files), set()
while _todo:
    _rel = _todo.pop(0)
    if _rel in _done:
        continue
    _done.add(_rel)
    _text = ci_files.get(_rel)
    if _text is None:   # a local action outside .github/ (r43: read by its exact path; r44: a tracked one from its blob)
        try:
            _text = (BLOB[_rel] if _rel in BLOB else open(_exact_path(_rel), "rb").read()).decode("utf-8")
        except OSError as e:   # r45: named
            failures.append(f"UNREADABLE {_rel}: a local action that cannot be read ({type(e).__name__})")
            continue
        except (TypeError, UnicodeDecodeError) as e:
            failures.append(f"CI-UNREADABLE {_rel}: a local action that cannot be read as UTF-8 ({type(e).__name__})")
            continue
        if "\0" in _text:
            failures.append(f"CI-UNREADABLE {_rel}: a local action that holds a NUL")
            continue
    try:
        _doc, _rd = ciyaml.read(_text)
    except ciyaml.CiRefuse as e:
        failures.append(f"CI-UNREADABLE {_rel}:{e.line}: {e.why}")
        continue
    _ci_check(_rel, _doc, _rd, _todo)
if not READ_ZIG:   # r41 (round 40's Opus M3 (a)); r42: said where the pin's failure is recorded
    zig_files = []
for _j, (_r, _f, _d) in enumerate(zig_files):   # r44: a tracked file whose checkout bytes are not its blob's (a CR LF
    if _r in _blob_parse:                       # checkout) is parsed from its blob, the bytes the gate reads
        os.makedirs(os.path.join(WORK, "blobs"), exist_ok=True)
        _bp = os.path.abspath(os.path.join(WORK, "blobs", f"{_j}.zig"))
        open(_bp, "wb").write(_d)
        zig_files[_j] = (_r, _bp, _d)
paths = [f for _, f, _ in zig_files]
light = {f for _, f, data in zig_files if not any(s in data for s in NEEDS_AST)}
dump = zigast.run_astdump(ASTDUMP, paths, light, WORK) if READ_ZIG else None
# r40 (round 39's Opus L1): the astdump must come from the compiler the tree pins (build.zig.zon's
# minimum_zig_version, the major and minor), or the gate would read the tree with another compiler's grammar
if READ_ZIG and zigast.compiler_series(dump.compiler) != PIN:
    print("BAD-SETUP: the astdump was built with Zig " + (dump.compiler or "(unknown)") + ", but the tree pins "
          + ".".join(map(str, PIN)) + ": the gate reads a tree only through its pinned compiler's parse")
    sys.exit(2)
for rel, full, data in zig_files:
    fa = dump.get(full)
    if fa is None or not fa.parsed:
        if fa is not None and fa.first_error:
            tg, off = fa.first_error
            ln_ = data[:off].count(b"\n") + 1
            failures.append(f"UNPARSEABLE {rel}:{ln_}: the pinned compiler's parser rejects the file ({tg}), so the "
                            f"gate cannot read it")
        else:
            failures.append(f"UNPARSEABLE {rel}: the pinned compiler's parser could not read the file")
        continue
    if not fa.full:
        continue   # nothing in it the gate reads
    til = zigast.tiling_problems(fa)
    if til:
        failures.append(f"AST-TILING {rel}: the parse's nodes do not tile ({til[0]}), so the gate does not read it")
        continue
    rol = zigast.role_problems(fa)   # r40 (round 39's Opus L2)
    if rol:
        failures.append(f"AST-ROLES {rel}: the parse's roles do not match the role table ({rol[0]}), so the gate does "
                        f"not read it")
        continue
    tok = zigast.token_problems(fa, data, dump.dialect)
    if tok:
        failures.append(f"AST-TOKENS {rel}: zigtok's tokens differ from the compiler's ({tok[0]}), so the gate does "
                        f"not read it")
        continue
    res_ = OriginResolver(fa, data)
    for ln_, nm in version_uses(res_):   # r36 (round 35's Opus M2)
        if nm == "zig_version":
            zv_seen.add(rel)
            if rel not in zv_ok:
                failures.append(f"PRODUCTION-SHIM {rel}:{ln_ + 1}: a use of zig_version outside requireZig's file")
        else:
            zvs_seen.add(rel)
            if rel not in zvs_ok:
                failures.append(f"PRODUCTION-SHIM {rel}:{ln_ + 1}: a use of zig_version_string outside the "
                                f"version printer's file")
    origins = feature_origins(res_)
    unknown_fields = field_name_unknown(res_)
    n_ft = sum(1 for _, o in origins if o.cat == "std")
    n_dt = sum(1 for _, o in origins if o.cat == "derived")
    uo_lines = [ln_ for ln_, o in origins if o.cat == "unresolved"] + unknown_fields
    if unknown_fields:
        tally["field-name unresolved"] = tally.get("field-name unresolved", 0) + len(unknown_fields)
    for _, o in origins:
        tally[o.cat] = tally.get(o.cat, 0) + 1
        if "capture" in o.via:
            tally["via capture " + o.cat] = tally.get("via capture " + o.cat, 0) + 1
    if ORIGINS:
        for ln_, o in origins:
            print(f"ORIGIN {rel}:{ln_ + 1} {o.cat}" + (f" ({o.why})" if o.why else "")
                  + (f" via {','.join(sorted(v for v in o.via if not v.startswith(('R:', 'P:'))))}" if o.via else "")
                  + (f" rules {','.join(sorted(v[2:] for v in o.via if v.startswith('R:')))}" if o.cat == "local" else ""))
        for ln_ in unknown_fields:
            print(f"ORIGIN {rel}:{ln_ + 1} unresolved (a @field whose name is no literal, on an object neither "
                  "positively local nor a boundary class)")
    if n_ft or rel in ft_ok:
        ft_seen[rel] = n_ft
    if n_dt or rel in dt_ok:
        dt_seen[rel] = n_dt
    if uo_lines or rel in uo_ok:
        uo_seen[rel] = len(uo_lines)
    if n_ft > ft_ok.get(rel, 0):
        failures.append(f"PRODUCTION-SHIM {rel}: {n_ft} feature tests on std, the allowance {ft_ok.get(rel, 0)}")
    if n_dt > dt_ok.get(rel, 0):
        failures.append(f"DERIVED-SHIM {rel}: {n_dt} feature tests on a type derived from std, the allowance "
                        f"{dt_ok.get(rel, 0)}")
    if len(uo_lines) > uo_ok.get(rel, 0):
        failures.append(f"UNRESOLVED-ORIGIN {rel}: {len(uo_lines)} feature tests or @field uses whose origin the "
                        f"gate cannot positively resolve (lines {', '.join(str(x + 1) for x in sorted(uo_lines))}), "
                        f"the allowance {uo_ok.get(rel, 0)}")
    for ln_, o in origins:   # r35 (round 34's Sol M2): fail closed, explicitly
        if o.cat == "udestr":
            failures.append(f"UNRESOLVED-DESTRUCTURING {rel}:{ln_ + 1}: a feature test on a destructuring "
                            f"element the gate cannot match to its value, which is not positively local")
if _tmp is not None:
    _tmp.cleanup()
for rel, n in sorted(counts.items()):
    got = seen.get(rel)
    if got is None or got < n:
        failures.append(f"STALE-ALLOWANCE {rel}: allows {n} mentions, the file holds {got if got is not None else 'none'}")
    elif got > n:
        failures.append(f"RESIDUE-015-COUNT {rel}: holds {got} mentions, the allowance {n}")
for rel, texts in sorted(content_ok.items()):
    for t_ in sorted(texts):
        if (rel, t_) not in content_seen:
            failures.append(f"STALE-ALLOWANCE {rel}: no line `{t_[:60]}` holds a mention any more")
for px in sorted(set(prefixes)):   # r45 (round 44's Opus L2): a prefix names a tracked directory and matches a file
    if not any(r_.startswith(px) for r_ in (TRACKED if TRACKED is not None else read_rel)):
        failures.append(f"STALE-ALLOWANCE {px}: a prefix row that names no " + ("tracked directory" if TRACKED is not None
                        else "directory of the tree") + " and matches no file")
if not READ_ZIG:   # r41: rows only the Zig files can confirm are not judged on a tree whose Zig files were not read
    ft_ok, dt_ok, uo_ok, zv_ok, zvs_ok = {}, {}, {}, set(), set()
for (rel, job, sid), n in sorted(zig_matches.items()):   # r41 (round 40's Opus M3 (b)); r42: exactly one match
    if n == 0:
        failures.append(f"STALE-ALLOWANCE {rel}: no setup-zig step `{sid}` in the job `{job}` matches its setup-zig-step "
                        f"row")
    elif n > 1:
        failures.append(f"ACTIVE-015-SELECTION {rel}: {n} setup-zig steps match the row for the job `{job}`, step "
                        f"`{sid}`")
for rel, n in sorted(ft_ok.items()):
    if ft_seen.get(rel, 0) < n:
        failures.append(f"STALE-ALLOWANCE {rel}: allows {n} feature tests on std, the file holds {ft_seen.get(rel, 0)}")
for rel, n in sorted(dt_ok.items()):
    if dt_seen.get(rel, 0) < n:
        failures.append(f"STALE-ALLOWANCE {rel}: allows {n} feature tests on a type derived from std, the file holds "
                        f"{dt_seen.get(rel, 0)}")
for rel, n in sorted(uo_ok.items()):
    if uo_seen.get(rel, 0) < n:
        failures.append(f"STALE-ALLOWANCE {rel}: allows {n} unresolved origins, the file holds {uo_seen.get(rel, 0)}")
for rel in sorted(zv_ok):
    if rel not in zv_seen:
        failures.append(f"STALE-ALLOWANCE {rel}: no zig_version use left to allow")
for rel in sorted(zvs_ok):
    if rel not in zvs_seen:
        failures.append(f"STALE-ALLOWANCE {rel}: no zig_version_string use left to allow")
kinds = {}
for x in failures:
    kinds[x.split(" ", 1)[0]] = kinds.get(x.split(" ", 1)[0], 0) + 1
for x in failures:
    print(("REPORT " if REPORT else "FAIL ") + x)
print("ORIGINS " + (", ".join(f"{k} {v}" for k, v in sorted(tally.items())) or "none"))
summary = f"({len(failures)} failures)" + ("" if not kinds else " " + " ".join(f"{k}={v}" for k, v in sorted(kinds.items())))
print(("RESULT REPORT-ONLY " if REPORT else "RESULT " + ("FAIL " if failures else "PASS ")) + summary)
sys.exit(0 if REPORT or not failures else 1)
