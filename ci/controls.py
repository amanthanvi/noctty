"""The self-test of the static review trigger (round 10: Z1-Z4, Y3, Y4; round 11: AA5, Opus L4; round 12: M-b, M-c,
M-f, Sol L4; round 13: AC2) on the pinned fixture, and of the compare's run rules (round 13: AC5, AC1; round 14:
AD1, Opus L2; round 15: AE1, Opus L3; round 16: AF2; round 17: AG2, Opus L10; round 18: AH2, AH3) on
tools/role_compare2.py with synthetic dumps, sealed launch manifests and run specs (the fixture's, and
ci-draft/role-runs.tsv's drafted runs); keys are <file>:<bare symbol name> from r19 (AH2).

After the base run, controls run four at a time; each has its own inventory prefix, overlay and table copy, and the
summary keeps the numbered order. Each gate control writes one overlay edit (or one table variant), runs
lock_inventory20.py and thread_gate15.py, and asserts
the exit codes, the EXACT failure count by kind, and the inventory's change against the unmodified base run (so the
appending controls are +1 variants that hold on any branch; the replacing ones need the fixture's text). Nothing is
written to the repository. Output: <logdir>/NN-<name>.txt per control and <logdir>/summary.txt.

The round-independent entry point (round 19's AI1): 1A.5 copies this file into ci/ as ci/controls.py, CI runs it
there, and the plan's Part I names only it and §15.7's result; r10_controls.py to r19_controls.py are the history it
grew from. From r20 (round 19): AI2's file-qualified test keys, AI5's supervisor record, Opus L8's compiler column.
From r21 (round 20): AJ1's same-named test blocks and identical rows, AJ2's installed layout, AJ3's gating kinds.
From r22 (round 21): Opus L1's decoded and nameless test names; AK1's soak pass rules (tools/soak_judge.py).
From r23 (round 22): AL1's installed soak judge (INSTALL; --check-layout runs it); AL2's test names as bytes; Opus L1
and L2's soak records (each run.tsv row once, the copy's mode, minutes 1..N, crash/ required).
From r24 (round 23): Sol M1's tagged test-name parse and Opus L1's control characters (lock_inventory9.py); Opus L2's
required minimum and L3's class (soak_judge2.py); L5's temporary directory; the positive controls.
From r25 (round 24): M1's exact test identity and WHITESPACE-MISMATCH (thread_gate6.py); Muse L1 and Opus L1's
out-of-band TEST kinds and `test @"..."` (lock_inventory10.py); Muse L2's class shape and distinct classes
(soak_judge3.py).
From r26 (round 25): M1's quoted identifiers (lock_inventory11.py, thread_gate7.py); Kimi M1's reviewed table, read by
the compare itself (role_compare3.py --table-scope) in place of the DRAFT_TABLE stand-in; Opus L1's NO-OTHER-RUN
(soak_judge4.py) and L3's exact test identity at the compare.
From r27 (round 26): Sol M1 and M2's spelling controls, each shape in plain, quoted, escaped and mixed spellings with
one classification and one verdict per tool (lock_inventory12.py, thread_gate8.py: the source normalized once).
From r28 (round 27): Opus M1's callees named with a keyword, a primitive or `self`, Sol M1's parameter and receiver,
and the lead's matrix of every class of name in each position (lock_inventory13.py, thread_gate9.py: every quoted
identifier a word every pass reads, and a spelling no pass can read an explicit failure); each spelling control's
first spelling is the one zig fmt keeps. Opus M2's scope and modes: the full self-test is pinned to the frozen
fixture set (fixture/FIXTURE.tsv's revision, 31796f5d0, and scope, fork, each file's digest checked), which every
control reads, the compare controls included; --appending runs control 00 and the appending controls (APPENDING) at
any revision whose table was approved there, in the scope --scope names; every inventory, gate and compare call
takes that scope.
From r29 (round 28): every lock-op token read and either classified or refused, Sol M1's and Opus M1's receiver
shapes and "distinct" only by declaration (lock_inventory14.py); the thread anchors as data, a fixture file and an
argument of every gate check, test-code UNCLASSIFIED through the allow-list (thread_gate10.py, Opus M2); §7.8's 0.15
residue checks with the approved bundle (residue_gate.py, Sol M2); FIXTURE.tsv's revision the full SHA (Opus L2).
From r30 (round 29): default-deny (the lead's direction; lock_inventory15.py): an acquisition is renderer-state,
"distinct" or "other" only by evidence, else unclassified, so Sol M1's alias chains, Sol M2's factory, Opus M1's
shapes and an unresolved receiver each come out unclassified or a renderer-state site (217 to 230; 210 stays the
positive); the allow-list keyed by receiver too (thread_gate11.py, 231, 232); an anchor's proof may be a chain (Opus
L2, 211, 233, 234); the full self-test reads nothing live (Opus M3): the layout controls install the fixture's table
and run spec, --check-layout compares with them in the fixture's scope, and the residue controls read the fixture's
copy of the allowance, a fixture file now; the residue controls run residue_gate2.py on the real v1.4.0 tree and the
fork head with this bundle installed (Opus M2, L1, L4; 213 to 216, 235 to 240).
From r31 (round 30): evidence by lexical scope (lock_inventory16.py; Sol M1, Opus M1): a declaration counts only as
the unique binding of its name in the enclosing function, so Sol's sibling blocks and Opus's S1 to S8 (each with a
decoy declaration r30's text match found) come out unclassified, and S1c, S5c and S7c (the same without the decoy)
stay unclassified (241 to 252; 210 stays the positive); the census decodes a reflected name's escapes (Sol M2:
253 to 256) and makes a called @field whose name is no literal an unclassified acquisition (the user's decision, 257
to 259: the fork's two COM vtable calls allow-listed); each allow-list row carries an approved count (Opus L3,
thread_gate12.py: 260 to 262); the residue gate counts feature tests on std through the file's aliases (Opus L1,
residue_gate3.py: 263 to 265).
From r32 (round 31): the tools read the source through one shared token stream (zigtok.py; lock_inventory17.py,
thread_gate13.py, residue_gate4.py), so a destructuring declaration's elements and a capture list wherever it starts
are bindings (Opus M1: P01 and P05 with a decoy, negatives; P02 and P03, positives; 266 to 270), a lock call split by
a comment or a line break is a token and a lock op used as a value with no call is refused unless it is a field read
(Opus M2: Q01 to Q03, O04, O05 and 276; 271 to 276), a reflected call's position is read from the tokens (Sol M2:
277 to 279), std's namespace aliases resolve by scope (Sol M1: 280 to 283), and feature tests are counted from the
tokens, @TypeOf and @typeInfo included (Sol M3, Opus L3, Sol L1: 284 to 287); bindcheck32.py, the independent binding
check, passes the base run's distinct acquisitions and fails a receiver bound twice (Opus L5: 288, 289).
From r33 (round 32): a lock-op name with no call is a field read only with evidence (lock_inventory18.py: its chain's
type resolves by scope to a struct or union declaring it as a field, or a struct's own variable), and @call's callee
is read first, so Opus's OA to OF, OK and OM and Sol's comptime-block `var`, typed and inferred, which r32 took for
field reads from the spelling of a root's type, are unclassified acquisitions (290 to 298, 301, 302; OP, 298, compiles
on 0.15.2 only); CL and CM, the direct calls, were unclassified already (299, 300); 276 stays the positive. The residue
gate reads a typed alias of std and a std head anywhere in a feature test's first argument (residue_gate5.py; Sol M2,
Opus L1: 303 to 307).
From r34 (round 33): every structure the tools read comes from the token stream (zigtok.py's functions_of_tokens,
containers_of_tokens and container_members; lock_inventory19.py, thread_gate14.py), so a line of a method's multi-line
parameter list is no member of its struct (Opus M1: E1, E2a and E2b, negatives, 308 to 310; E2d, the StateMutex
spelled out, a site, 311; FD, a field whose default runs over several lines, the positive, 312), and evidence is
explicit only: a `var` gives its type only when it is explicitly typed (Sol M1: RA, a `var` reassigned after a decoy
initializer, 313). The residue gate takes std origin as a taint over declarations by scope (residue_gate6.py; Sol M2,
Opus L2 and the user's decision: a parenthesized initializer, @field(std, "Thread"), destructuring elements in a
comptime initializer and in a function, and an alias in a nested struct, each over lines with a comment too, 314 to
323); a name std taints only in another function (324) and a std call's result (325) are no shims.
From r35 (round 34): one span tree by token range for every container kind and every function, read for every owner
lookup, and a switch capture's switch found by token nesting (lock_inventory20.py; Opus M1: A1, A2, A4, A5, decoys an
enum or opaque body or a line its container opens filed under the span around it, negatives, 326 to 329; C1, A1
without the decoy, 330; EP, an enum method reading its own declaration, the positive, 331; Opus M2: B1 to B4, a
capture's union read from an earlier prong's switch, negatives, 332 to 335; BP, a value-mutex payload with a switch
in its prong, the positive, 336). The flow passes and the gate's caller sets read the tokens too (thread_gate15.py),
the caller sets' file filter kept a superset of r34's (it can only add an edge). The residue gate reads std origin
by category (residue_gate7.py): container identity through aliases, `@This()` and a literal `@field`, a var's
assignments, destructuring element by element (Sol M1, Opus M3, Sol M2: 337 to 349), an element it cannot match
(UNRESOLVED-DESTRUCTURING, 350), std reached only through a call's or a builtin's arguments or returned from a function
("derived", DERIVED-SHIM beyond the `derived-tests` rows: Opus L2, 351 to 353; 325 too), the per-file scope (354), a
sibling block (355); the binding check reads "other" rows and field-read exemptions (bindcheck35.py; Opus M2: 356,
357); the 1B proxies' derived rows (358, 359). 318 and 319 are valid Zig (Opus L1). The allowance's fork row for Key
(src/config/Config.zig, the user's option 1) is stale on the v1.4.0 tree alone: every residue control there expects
that one STALE-ALLOWANCE more (residue_control).
From r36 (round 35): the residue gate is default-deny (residue_gate8.py): a feature test's subject passes only with
positive evidence that its origin is not std, and anything else is UNRESOLVED-ORIGIN, which needs an exact per-file
unresolved-origin row; resolution is memoized with cycle detection and no fixed depth; a project @import head and a
function parameter are the two named boundary classes. Every shape of both seats is a negative control with a local
twin, the twin of a form the gate does not model carrying its exact row (Sol M1 to M3, Opus M1: 360 to 419; the
cycle, 372 and 373; the parameter boundary, 418 and 419, passes both), zig_version read from the tokens and
zig_version_string a residue identifier (Opus M2: 420 to 427), a declaration after a container field, which r35 never
bound (428, 429); bindcheck36.py takes a field read's op from the root binding's container (Opus L3: the B1 row, 430;
its twin, 431). The allowance's three fork rows (Key's and win32_settings_fields.zig's derived-tests, facade_budget.zig's
unresolved-origin) are stale on the v1.4.0 tree alone: every residue control there expects those three
STALE-ALLOWANCE more (residue_control).
From r37 (round 36): the residue gate's positive evidence is a small explicit trusted set (residue_gate9.py's TRUSTED,
§7.8's rule table: the rules the seven trees need), every other rule's form UNRESOLVED-ORIGIN, and the rules kept are
sound by the seats' standard (@as joins its type and its value; a field's value is local only through a same-file
container or a non-`type` primitive; a bare returned parameter passes its arguments, every non-local argument joins;
a parameter never leaves its function; an index of an instance, a labelled return type and an address-taken var are
unresolved; the return scan skips only `fn NAME` and container bodies); the nonliteral @field rule fires, in every
file, on any object neither positively local nor a boundary class; feature-test names are decoded (a
literal @field name too) and a hasFn reference that is no direct call is unresolved. r36's shapes take r37's outcomes
(360 to 429: some negatives now fail UNRESOLVED-ORIGIN, their twins carrying a row); every shape of round 36 is a
negative with a local twin (Sol M1 to M3, Opus M1 to M3: 432 to 479), and so is each form the lead's self-review found
before the self-test (484 to 497: an address or an assignment through grouping parentheses, an address after an if
condition, a destructuring assignment through them, a hasFn named by a literal @field, called or not, and the type of
a builtin's value), and each the lead's decision after it adds (498 to 503: a hasFn reached by a computed name over a
std, a derived and an unresolved object); the binding check resolves a container name declared more than once by
lexical scope (bindcheck37.py; Sol M4: a same-named sibling and a same-named alias, 480 and 482, their twins 481 and
483). On the v1.4.0 tree alone the fork rows are stale and upstream's GTK runtime and Metal renderer, which 1B
removes, fail UNRESOLVED-ORIGIN (V140_EXTRA); the two 1B proxies' lines are read each on its own.
From r38 (round 37): the machinery under the trusted rows fails closed (residue_gate10.py). A var is positive evidence
only when every occurrence of its name is classified (its declaration, a recognised write, an address, a plain read;
anything else leaves the var unresolved), and a mixed destructuring list, an address after a break or continue label
and a slice are a var's write or address; a destructured element is local only matched element by element to a local
literal element, else UNRESOLVED-DESTRUCTURING, and an anonymous literal keeps its elements' rule evidence; a break,
return or tuple operand ends at its real boundary, and any extracted span holding a top-level `,`, `;` or `=>`, or
unbalanced brackets, is UNRESOLVED-ORIGIN. Every residue and binding-check expectation comes from a generator:
the residue shapes' and the pre-360 shim controls' from expect38.py, the real-tree and binding-check controls' from
controls_measure38.py's run of the controls, V140_EXTRA and the fork head's and proxies' lines from bundlecheck38
(make_controls38.py). Round 37's shapes are negatives with local twins (Sol M1, its comparison-to-constant control
and Sol M2, Opus M1 and M2: 504 to 523); the binding check indexes every const and var, an unreadable one opaque, by
lexical scope (bindcheck38.py; Opus M3: K1 to K3, 524, 526 and 528, their K0 twins 525, 527 and 529).
From r39 (round 38): the residue gate and the binding check take every structure from Zig's own parser
(residue_gate11.py, bindcheck39.py): astdump.zig, built with the compiler the tree is pinned to, dumps each file's
std.zig.Ast, and zigast.py checks the dump (every node's children tile its span; zigtok's tokens equal the compiler's)
before either reads it; a file the pinned compiler rejects fails (UNPARSEABLE, the user's decision). An operand is a
node's child, a destructuring's targets the assign_destructure node's, a declaration a var_decl node, `bool` only a
comparison or boolean node, and a var is evidence only when every occurrence's parent is an allow-listed read or a
named write (a method-call receiver an address). The full self-test takes the two compilers' astdump executables
(--astdump-1a, --astdump-1b). Round 38's shapes are negatives with local twins (Sol M1, M2, Opus X1 to X6: 530 to
557), with the F5 pin controls (558 to 561), the method-call receiver (562, 563) and the UNPARSEABLE controls (564 to
567); the binding check's suffix row (Sol M3) and K4 (568 to 571); the dump's checks are controls too (572 to 575:
a dump whose tiling is broken, one whose tokens differ, a dump passed through unchanged, and a gate given no astdump);
and r39's per-rule comparison with r38 found an array literal's element type dropped behind boundary-class elements
(576 to 579: `[_]std.Thread.Mutex{imp.x}` and the same over a parameter, each with its twin).
From r40 (round 39): every parent an occurrence of a var can meet is a read, a pass-through (which climbs: an if's
branches, a switch prong's target, a break's operand to its label's target, `orelse` and `catch`, `try`,
`nosuspend`, `comptime`, a loop's else, grouping), a write or an address (a cond or input captured by `|*p|` too), and
any other parent leaves the var unresolved (residue_gate12.py); a labelled switch joins its breaks and its continues;
the gate and the binding check (bindcheck41.py) read a tree only through the astdump its pinned compiler built
(BAD-SETUP otherwise), every node's roles are checked against a fixed table (AST-ROLES), and the gate reads pkg/ too.
The 1B proxies are read as 1B.3 leaves them (minimum_zig_version 0.17.0). Round 39's shapes are negatives with local
twins (Opus M1: 580 to 613; Opus M2: 614 to 617; the regression sweep, the labelled switch r39 modelled and r38 failed
closed: 618 to 625); the pin checks (626, 627), a tamper control for each way a dump can fail its checks (628 to 632)
and the self-test's job selector (selftest_jobs.py: an astdump-only change selects both jobs, 633 to 635) are
controls too.
From r41 (round 40): residue_gate13.py (r42: residue_gate14.py; r43: residue_gate15.py; r44: residue_gate16.py; r45: residue_gate17.py) walks a place down from where an occurrence's climb stops with an explicit stack
and no depth limit, and holds every write and address to that walk (an occurrence it does not reach, or a walk that
cannot finish, leaves the var unresolved); an unlabelled break or continue binds to a loop only through its body or a
while's continue expression, as AstGen binds it; a tree pinned below 0.17 fails ACTIVE-015-SELECTION on its pin and
the gate reads none of its Zig files (214, 240 and 665 expect the pin's two failures and none of the bundle's Zig
lines, 665 with no astdump at all);
and a setup-zig version that is no literal fails unless a `setup-zig-step` row names the step, which the self-test
jobs' 1A compiler step is (its version read at run time from the fixture's build.zig.zon, which the fixture now holds).
Round 40's shapes are negatives with local twins (Sol M1 and Opus M2, a place 200, 201 and 1000 groupings deep and a
300-deep mixed chain: 636 to 649; Opus M1, A1 to A7: 650 to 663; the labelled break from an else to its own label:
664), and the workflow controls are 666 to 669.
From r42 (round 41): residue_gate14.py reads build.zig.zon once, strictly (a case variant of it or of build.zig at the
root, invalid UTF-8, a NUL or no single minimum_zig_version: BAD-SETUP, exit 2), fails a .zig, .zon, .yml, .yaml or
.tsv file that is no strict UTF-8 (NOT-TEXT) and scans every other file over its bytes, reads every .zig file, and
reads every CI file under .github/ and every local action they name through ciyaml.py's closed YAML subset
(CI-UNREADABLE otherwise); every setup-zig step needs an explicit with.version, and the one that is no literal is bound
by a `setup-zig-step` row to its workflow, job, step, producer step and the producer's sha256 (the self-test jobs
selftest-full and selftest-appending, step zig-1a, producer pin-1a). Round 41's controls: the pin (670 to 673), Zig
files the gate skipped or did not reach (674 to 677, shapes), the CI forms (678 to 707), the exception (708 to 717)
and the bundle's own dump tool, ci/astdump.zig, which keeps three feature tests on std on purpose (718, 719).
From r43 (round 42): residue_gate15.py accepts one narrow spelling of each input it relies on: a CI file holds LF or CR
LF line breaks only (a CR not followed by LF, NEL, LS, PS, a byte-order mark anywhere, any other C0 control and DEL
fail CI-UNREADABLE), a tab only inside a block scalar's content or a comment, and keys of [A-Za-z0-9_-]; the pin is
read from Zig's tokens by zigast.read_pin, which bindcheck41.py calls too (comments supply no field; a quoted
identifier, a backslash in a literal, a multiline string, a duplicate root field: BAD-SETUP); a `uses` value is a
local path (`./` and [A-Za-z0-9._-] segments, read whole, in its exact case), a remote owner/repo[/path]@ref or a
docker:// image; a git checkout is read by its tracked list (CASE-COLLISION, TRACKED-UNREAD); a skip directory applies
at the root only; a file with a UTF-16 or UTF-32 byte-order mark is scanned by its code units and its bytes. Round
42's controls: the characters (720 to 743), the pin (744 to 753, 752 and 753 the binding check), the uses grammar
(754 to 763), the tracked set on a git checkout of their own (764 to 769), a nested skip directory and byte-order-
marked text (770 to 779, shapes), and the CI boundary's outer edge, each passing by design beside a twin the gate
reads (780 to 791).
From r44 (round 43): residue_gate16.py reads the bytes each consumer reads and one spelling of each value: in a git
checkout every tracked file's content is its index blob, a tracked path with a filter, working-tree-encoding or ident
attribute fails TRANSFORMED-PATH and a checkout file that differs from its blob beyond CR LF against LF fails
CHECKOUT-DIFFERS; a tracked link is read as its link text, never followed (TRACKED-LINK for a name the gate interprets,
a directory target or a target outside the tree); a local action's metadata names count under case folding, exactly
one action.yml or action.yaml spelled exactly (and only when there is none, exactly one Dockerfile: the Docker
boundary); a setup-zig version and the pin are read only as N.N.N or N.N.N-dev.N+<hex> in ASCII; the CI reader strips
only a space and a tab. Round 43's controls: tracked links (792 to 797), a clean/smudge filter, a working-tree encoding
and the hidden producer key through one (798 to 803, each a committed git checkout), the metadata names (804 to 809),
the version spellings (810 to 825), the pin's digits for the gate and the binding check (826 to 829), and Unicode white
space in a continuation line and after a key (830 to 833).
From r45 (round 44): residue_gate17.py reads one commit, HEAD or --rev, with replace objects off and no GIT_* variable
from the caller (its tree, its blobs, its attributes), and fails a checkout whose index is not that commit
(INDEX-NOT-COMMIT); a tracked link's target must be a tracked regular file; an allowance row with a degenerate key (an
empty path, a prefix that does not end in /, an empty content line, a zero count) is BAD-ALLOWANCE, a prefix naming no
tracked directory STALE-ALLOWANCE; a file the gate cannot read is UNREADABLE, and a submodule is named. Round 44's
controls, each a committed git checkout but 866 and 867: a staged-only change and an equal-tree git replace with clean
status (834 to 837), a tracked link to a build's output and two build-written Zig sources the gate does not read by
design, each beside its twin (838 to 843), each allowance row kind's degenerate key (844 to 865), and a broken
untracked link and a submodule (866 to 869).
The run spec and the reviewed table --check-layout requires are found beside this file when installed (ci/), else in
../ci-draft/; its compare reads the fixture's copies, in the fixture's scope; the fixture is in fixture/ beside this
file (ci/fixture/), else ../ci-draft/fixture/.
Usage: python -I controls.py [--scope fork] <repo> <logdir>
           the full self-test, at the fixture's revision (the repository must hold it: CI fetches it first)
       python -I controls.py --appending --scope fork|1a|1b <repo> <rev> <approved-table.tsv> <allow.tsv>
           <entries.tsv> <anchors.tsv> <logdir>
           control 00 and the appending controls at <rev>, with the table approved there in that scope
       python -I controls.py --check-layout
       python -I controls.py --quick <repo> <logdir>
           check the installed files and the fixture's digests, then run one compare with the fixture's run spec on
           the fixture's table in the fixture's scope (r30), and the soak judge on a clean and a kill fixture
"""
import collections
import concurrent.futures
import hashlib
import os
import re
import shutil
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))


def find_run_spec():
    """AJ2: the reviewed run spec as installed (beside this file in ci/), else in the scratch layout; never guessed."""
    for cand in (os.path.join(here, "role-runs.tsv"), os.path.join(here, "..", "ci-draft", "role-runs.tsv")):
        if os.path.exists(cand):
            return os.path.normpath(cand)
    sys.exit("no run spec: expected role-runs.tsv beside this file (installed) or ../ci-draft/role-runs.tsv (scratch)")


def find_table():
    """r26 (round 25's Kimi M1): the reviewed seven-column table as installed (ci/lock-inventory-threads.tsv), else in
    the scratch layout; never synthesized."""
    for cand in (os.path.join(here, "lock-inventory-threads.tsv"),
                 os.path.join(here, "..", "ci-draft", "lock-inventory-threads.tsv")):
        if os.path.exists(cand):
            return os.path.normpath(cand)
    sys.exit("no reviewed table: expected lock-inventory-threads.tsv beside this file (installed) or "
             "../ci-draft/lock-inventory-threads.tsv (scratch)")


FIXTURE_FILES = ("lock-inventory-threads.tsv", "lock-inventory-threads.callers.tsv", "lock-inventory-allow.txt",
                 "thread-entries.tsv", "role-runs.tsv", "thread-anchors.tsv",   # r29 (round 28's Opus M2): the anchors
                 "residue-allow.tsv",   # r30 (round 29's Opus M3): the residue controls' allowance, frozen too
                 "build.zig.zon")   # r41 (round 40's Opus M3 (b)): the fixture revision's pin, which the self-test jobs read
#                                    at run time to install the 1A compiler
SCOPES = ("fork", "1a", "1b")


def find_fixture():
    """r28 (round 27's Opus M2): the full self-test's frozen fixture set: fixture/ beside this file when installed
    (ci/fixture/), else ../ci-draft/fixture/ in the scratch layout; never the live table or run spec."""
    for cand in (os.path.join(here, "fixture"), os.path.join(here, "..", "ci-draft", "fixture")):
        if os.path.exists(os.path.join(cand, "FIXTURE.tsv")):
            return os.path.normpath(cand)
    sys.exit("no fixture: expected fixture/FIXTURE.tsv beside this file (installed) or ../ci-draft/fixture/ (scratch)")


def read_fixture(d):
    """FIXTURE.tsv: `rev`, `scope`, and `file <name> <sha256>` for each of FIXTURE_FILES; every digest must match, so a
    changed table or run spec cannot pass as the fixture."""
    rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(d, "FIXTURE.tsv"), encoding="utf-8")
            if l.strip() and not l.startswith("#")]
    meta = {r[0]: r[1] for r in rows if r[0] in ("rev", "scope") and len(r) == 2}
    files = {r[1]: r[2] for r in rows if r[0] == "file" and len(r) == 3}
    bad = [n for n in FIXTURE_FILES if n not in files or not os.path.exists(os.path.join(d, n))
           or hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest() != files[n]]
    if bad or set(meta) != {"rev", "scope"} or meta["scope"] not in SCOPES:
        sys.exit(f"fixture digest mismatch in {d}: {', '.join(bad) or 'its rev and scope rows'}")
    return meta["rev"], meta["scope"]


INSTALL = ("controls.py", "role_compare3.py", "role_supervisor.py", "lock_inventory20.py", "thread_gate15.py",
           "soak_judge4.py", "residue_gate17.py", "zigtok.py", "bindcheck41.py", "zigast.py", "astdump.zig",
           "selftest_jobs.py", "ciyaml.py")   # r23 (AL1) to r35: what 1A.5 installs in ci/, with the run spec, the reviewed table and
#                                the frozen fixture set (ci/fixture/, r28)
SOAK_OK = [(m, "720", "134070000000000720", "yes") for m in range(1, 9)]
SOAK_CLASS = "noctty-interactive-zig017-0123456789ab-soak-fast"   # r25: the launch helper's shape (Muse L2)
SOAK_GONE = [(m, "-", "-", "-") for m in range(6, 9)]


def soak_rows(end, wer="suppressed", planned=8, mode="portable"):
    """r23 (round 22's Opus L1, L2): the run.tsv rows §3.5's judge requires, each once."""
    return [("launch", "720", "134070000000000720"), ("mode", mode), ("class", SOAK_CLASS),
            ("exe", "C:/soak/fast/noctty.exe"), ("planned", planned), ("wer", wer), ("end", end[0], end[1])]


def write_soak_run(d, rows, samples, crash_dir=True, crash_files=()):
    """A recorded soak run directory: run.tsv, samples.tsv and crash/ (left out when crash_dir is false)."""
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    if crash_dir:
        os.makedirs(os.path.join(d, "crash"))
    open(os.path.join(d, "run.tsv"), "w", encoding="utf-8", newline="\n").write(
        "".join("\t".join(map(str, r)) + "\n" for r in rows))
    open(os.path.join(d, "samples.tsv"), "w", encoding="utf-8", newline="\n").write(
        "".join("\t".join(map(str, s)) + "\n" for s in samples))
    for name in crash_files:
        open(os.path.join(d, "crash", name), "wb").write(b"MDMP")


def _astdump_of(argv):
    """r39 (round 38's lead direction): {"1a": exe, "1b": exe}, the astdump each pinned compiler built
    (--astdump-1a, --astdump-1b); the full self-test's residue and binding-check controls need both."""
    out = {}
    for k_ in ("1a", "1b"):
        if f"--astdump-{k_}" in argv:
            i_ = argv.index(f"--astdump-{k_}")
            out[k_] = argv[i_ + 1] if i_ + 1 < len(argv) else ""
    return out


def _without_astdump(argv):
    out, i_ = [], 0
    while i_ < len(argv):
        if argv[i_] in ("--astdump-1a", "--astdump-1b"):
            i_ += 2
            continue
        out.append(argv[i_])
        i_ += 1
    return out


ASTDUMP = _astdump_of(sys.argv[1:])
args = _without_astdump(sys.argv[1:])
SCOPE = None   # r28 (round 27's Opus M2): every inventory, gate and compare call below takes it
if "--scope" in args:
    _i = args.index("--scope")
    SCOPE = args[_i + 1] if _i + 1 < len(args) else None
    del args[_i:_i + 2]
    if SCOPE not in SCOPES:
        sys.exit(f"--scope takes one of {', '.join(SCOPES)}")
CHECK_LAYOUT, APPEND_MODE, QUICK = (args[:1] == [flag] for flag in ("--check-layout", "--appending", "--quick"))
if CHECK_LAYOUT or APPEND_MODE or QUICK:
    args = args[1:]
FULL = not (CHECK_LAYOUT or APPEND_MODE or QUICK)
if CHECK_LAYOUT:
    import tempfile
    missing = [n for n in INSTALL if not os.path.exists(os.path.join(here, n))]
    if missing:   # r23 (AL1): an installation without one of its files fails here, not in a control's subprocess
        sys.exit(f"incomplete layout: {', '.join(missing)} missing beside controls.py")
    fix_ = find_fixture()   # r28 (round 27's Opus M2): the frozen fixture, every digest checked
    frev_, fscope_ = read_fixture(fix_)
    print(f"fixture: {fix_}, revision {frev_}, scope {fscope_}, {len(FIXTURE_FILES)} files, digests match")
    spec_live = find_run_spec()   # installed, as 1A.5 installs it; r30 (round 29's Opus M3): the compare below reads
    print(f"run spec: {spec_live}")   # the fixture's copies, in the fixture's scope, so a live table approved in another
    if SCOPE not in (None, fscope_):   # scope cannot fail a layout with nothing wrong in it
        sys.exit(f"--check-layout compares in its fixture's scope, {fscope_}")
    spec = os.path.join(fix_, "role-runs.tsv")
    req = [l.rstrip("\n").split("\t") for l in open(spec, encoding="utf-8")
           if l.startswith("debug-suite\trequired\t")]
    td = tempfile.TemporaryDirectory()   # r24 (round 23's Opus L5): removed before exit; mkdtemp leaked one a run
    d = td.name
    os.makedirs(os.path.join(d, "dumps"))
    open(os.path.join(d, "manifest.tsv"), "w", encoding="utf-8", newline="\n").write(
        f"seal\t0\t{hashlib.sha256(b'').hexdigest()}\n")
    print(f"reviewed table: {find_table()}")   # r26 (round 25's Kimi M1): installed beside this file
    table_ = os.path.join(fix_, "lock-inventory-threads.tsv")
    print(f"compared with the fixture's run spec and table, scope {fscope_}")
    open(os.path.join(d, "dumps", "test-exe-1.pairs"), "w", encoding="utf-8", newline="\n").write(
        "# kind=test-exe pid=1 start=1\n" + "".join(f"{r[2]} {r[3]}\n" for r in req))
    r = subprocess.run([sys.executable, "-I", os.path.join(here, "role_compare3.py"), "--runs", spec, "--run", "debug-suite",
                        "--compiler", "0.17", "--table-scope", fscope_, os.path.join(d, "manifest.tsv"), table_,
                        os.path.join(d, "dumps")], capture_output=True, text=True)
    print(r.stdout.strip().split("\n")[-1])
    soak = {}
    for name, end, samples in (("clean", ("quit", 0), SOAK_OK), ("kill", ("early", 3), SOAK_OK[:5] + SOAK_GONE)):
        sd = os.path.join(d, "soak-" + name)
        write_soak_run(sd, soak_rows(end), samples)
        soak[name] = subprocess.run([sys.executable, "-I", os.path.join(here, "soak_judge4.py"), sd,
                                     "--min-minutes", "8"], capture_output=True, text=True).returncode
    print(f"soak judge as installed: clean exit {soak['clean']}, kill control exit {soak['kill']}")
    code = 0 if r.returncode == 0 and soak == {"clean": 0, "kill": 1} else 1
    td.cleanup()
    sys.exit(code)
if APPEND_MODE:   # r28 (round 27's Opus M2): control 00 and the appending controls, at any revision
    if len(args) != 7 or SCOPE is None:
        sys.exit("usage: controls.py --appending --scope fork|1a|1b <repo> <rev> <approved-table.tsv> <allow.tsv> "
                 "<entries.tsv> <anchors.tsv> <logdir>")
    repo, rev, table, allow, entries, anchors, logdir = args
    FIX = None
else:   # the full self-test, pinned to its frozen fixture
    if len(args) != 2:
        sys.exit("usage: controls.py [--quick] [--scope fork] <repo> <logdir> (pinned to its fixture), or "
                 "controls.py --appending --scope fork|1a|1b <repo> <rev> <table> <allow> <entries> <anchors> <logdir>")
    repo, logdir = args
    FIX = find_fixture()
    rev, _fscope = read_fixture(FIX)
    if SCOPE not in (None, _fscope):
        sys.exit(f"the full self-test is pinned to its fixture's scope, {_fscope}; use --appending for scope {SCOPE}")
    SCOPE = _fscope
    if subprocess.run(["git", "-C", repo, "cat-file", "-e", rev + "^{commit}"], capture_output=True).returncode:
        sys.exit(f"FIXTURE-REV-MISSING: {repo} does not hold {rev}, the fixture's revision; fetch it first "
                 f"(git fetch --no-tags --depth=1 origin {rev})")
    os.makedirs(logdir, exist_ok=True)
    table = os.path.join(logdir, "table-approved.tsv")   # a copy: a control's approval writes beside its table
    shutil.copy(os.path.join(FIX, "lock-inventory-threads.tsv"), table)
    shutil.copy(os.path.join(FIX, "lock-inventory-threads.callers.tsv"),
                os.path.join(logdir, "table-approved.callers.tsv"))
    allow, entries = os.path.join(FIX, "lock-inventory-allow.txt"), os.path.join(FIX, "thread-entries.tsv")
    anchors = os.path.join(FIX, "thread-anchors.tsv")   # r29 (round 28's Opus M2): the fixture's own anchors
gate = os.path.join(here, "thread_gate15.py")
inv = os.path.join(here, "lock_inventory20.py")
bindcheck = os.path.join(here, "bindcheck41.py")   # r32 (round 31's Opus L5): the independent binding check
compare = os.path.join(here, "role_compare3.py")
POOL = concurrent.futures.ThreadPoolExecutor(max_workers=4)
py = sys.executable
os.makedirs(logdir, exist_ok=True)
# r28 (round 27's Opus M2): the appending controls. Each overlay only appends to a file (overlay() records it, and an
# appending control whose overlay replaced text fails), each table is the one given or it plus rows of the control's
# own, and what each expects concerns only what it added; 22 has no overlay and tampers the inventory's own count. So
# each holds at any revision whose table was approved there, in the scope given; --appending runs control 00 and these.
# Left out, each for its reason:
#   04, 05, 13, 15, 18, 21, 23 to 28, 30, 31, 33, 35, 36, 146: the overlay replaces text only the fixture holds, and
#     asserts it (replace(), or a lambda that edits a counted spelling);
#   02, 03, 17, 29, 71, 149: the overlay appends, but what it expects is a change to a fixture row's callers, path or
#     signature, which a row re-read on another revision need not keep;
#   16, 37, 39, 40: they read one of the fixture's own rows (a never-on-Win32 row's chain, the test row, updateFrame's
#     chain); 32: it counts the fixture's plain renderer locks;
#   41: it appends `State.lockDemand`, 1A.2's own forwarder, which a branch after 1A.2 already holds;
#   42 to 84, 87 to 91, 94 to 101, 107 to 115, 117, 120 to 122, 124, 140 to 142, 153 to 164, 191, 192: compare, soak
#     and layout controls on synthetic dumps, run directories and installed layouts, with no tree to append to (the
#     full self-test runs them); 189, 190: they run this mode; 211, 212: they read the fixture's own anchors;
#     213 to 216, 235 to 240: the residue controls, on the real trees they extract, with no overlay to append;
#   231, 233, 234: the overlay replaces text only the fixture holds (App.zig's needsModalWake, app.zig's dispatch
#     line); 232: a malformed allow-list, no tree;
#   258: it reads the fixture's own two reflected calls; 259, 260: the overlay replaces text only the fixture holds
#     (win32_jump_list.zig's readRemovedLinkText, App.zig's needsModalWake); 261, 262: an allow-list of their own;
#     263 to 265: residue controls;
#   284 to 287: residue controls; 288: it reads the fixture's base run; 289: a crafted distinct row, no inventory run;
#   303 to 307, 314 to 325, 337 to 359, 360 to 429, 432 to 479, 484 to 523, 530 to 567, 572 to 626, 628 to 632, 636
#     to 751, 754 to 827 and 830 to 869: residue controls (764 to 769, 792 to 803 and 834 to 869 but 866 and 867 on a
#     git checkout of their own);
#     356, 357, 430, 431, 480 to 483, 524 to 529, 568 to 571, 627, 752, 753, 828 and 829: crafted binding-check rows or
#     the binding check's pin; 633 to 635: the job selector, on a list of changed paths.
APPENDING = frozenset((1, 6, 7, 8, 9, 10, 11, 12, 14, 19, 20, 22, 34, 38, 85, 86, 92, 93, 102, 103, 104, 105, 106, 116,
                       118, 119, 123, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 143,
                       144, 145, 147, 148, 150, 151, 152) + tuple(range(165, 189)) + (193, 194) + tuple(range(195, 211))
                      + tuple(range(217, 231)) + tuple(range(241, 258))
                      + tuple(range(266, 284)) + tuple(range(290, 303))
                      + tuple(range(308, 314)) + tuple(range(326, 337)))   # r30 to r35: the default-deny, scope,
#                                                   token-stream, evidence and
#                                                   structure shapes, each appended
OVERLAY_KINDS = {}
QUICK_CONTROLS = frozenset((81, 82, 191, 192, 633, 634, 635, *range(880, 887), *range(889, 894)))


def want(n):
    """r28: whether control n runs: every control in the full self-test; with --appending, the appending ones."""
    return FULL or n in (QUICK_CONTROLS if QUICK else APPENDING)


def show(path):
    return subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"], capture_output=True).stdout.decode("utf-8")


def overlay(name, edits):
    d = os.path.join(logdir, "overlays", name)
    if os.path.exists(d):
        shutil.rmtree(d)
    for path, fn in edits.items():
        p = os.path.join(d, *path.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        before = show(path)
        after = fn(before)
        assert after != before, f"{name}: edit did not apply to {path}"
        open(p, "w", encoding="utf-8", newline="\n").write(after)
    OVERLAY_KINDS[d] = {getattr(fn_, "kind", "edit") for fn_ in edits.values()}   # r28: what the overlay's edits do
    return d


def append(code):
    f = lambda t: t.rstrip("\n") + "\n\n" + code + "\n"
    f.kind = "append"   # r28: an appending control's overlay holds only these
    return f


def replace(old, new):
    def f(t):
        assert t.count(old) == 1, old
        return t.replace(old, new)
    f.kind = "replace"
    return f


def run(cmd):
    r = subprocess.run(cmd, capture_output=True)
    return r.returncode, r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def summary_of(prefix):
    for l in open(prefix + "-summary.tsv", encoding="utf-8"):
        u = l.rstrip("\n").split("\t")
        if u[0] == rev:
            keys = ["acquisitions", "relocks", "handoff_internal", "live", "never", "multi", "unclassified",
                    "carriers", "unreviewed", "inline_flagged", "test_sites", "same_name"]
            return dict(zip(keys, map(int, u[1:])))
    return None


def control(tag, ov, inv_exit, inv_delta, gate_exit, gate_kinds, tbl=None, tamper=None, gate_extra=(), pre=None,
            tests=(), anch=None):
    if BASE is not None:
        return POOL.submit(control_now, tag, ov, inv_exit, inv_delta, gate_exit, gate_kinds, tbl, tamper, gate_extra, pre,
                           tests, anch)
    return control_now(tag, ov, inv_exit, inv_delta, gate_exit, gate_kinds, tbl, tamper, gate_extra, pre, tests, anch)


def test_values(prefix):
    """r25: the TEST values of the revision's test-code sites, as lock_inventory10.py writes them (`named:<name>`...)."""
    out = set()
    for l in open(prefix + "-sites.tsv", encoding="utf-8"):
        u = l.rstrip("\n").split("\t")
        if len(u) >= 10 and u[0] == rev and u[6] == "test":
            out.add(u[9])
    return out


def control_now(tag, ov, inv_exit, inv_delta, gate_exit, gate_kinds, tbl, tamper, gate_extra, pre, tests=(), anch=None):
    prefix = os.path.join(logdir, "inv-" + tag)
    ic, iout = run([py, "-I", inv, repo, prefix, tbl or table, f"{rev}={SCOPE}"] + (["--overlay", ov] if ov else []))
    if tamper:
        tamper(prefix)
    pre_out = ""
    if pre:
        pre_out = pre(prefix)
    gc, gout = run([py, "-I", gate, "check", repo, rev, SCOPE, tbl or table, allow, prefix, entries, anch or anchors]
                   + (["--overlay", ov] if ov else []) + list(gate_extra))
    s = summary_of(prefix)
    delta = ({k: s[k] - BASE[k] for k in s} if BASE else {}) if s else {"no inventory result": 1}
    delta = {k: v for k, v in delta.items() if v}
    kinds = {}
    for l in gout.splitlines():
        if l.startswith("FAIL "):
            k = l.split(" ", 2)[1]
            kinds[k] = kinds.get(k, 0) + 1
    seen = test_values(prefix) if tests else set()
    ok = (ic == inv_exit and delta == inv_delta and gc == gate_exit and kinds == gate_kinds
          and all(x in seen for x in tests))
    if ov and int(tag.split("-", 1)[0]) in APPENDING and OVERLAY_KINDS.get(ov) != {"append"}:
        ok = False   # r28: an appending control may only append, or it would not hold on a branch
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        if tests:
            fh.write(f"## TEST values expected among the test sites: {list(tests)!r}\n## observed: {sorted(seen)!r}\n")
        fh.write(f"## inventory (exit {ic})\n{iout}\n" + (f"## before the gate\n{pre_out}\n" if pre_out else "")
                 + f"## gate (exit {gc})\n{gout}\n")
        fh.write(f"gate extra arguments: {list(gate_extra) or 'none'}\n")
        fh.write(f"expected: inventory exit {inv_exit}, inventory change {inv_delta}, gate exit {gate_exit}, "
                 f"failures {gate_kinds}\n")
        fh.write(f"observed: inventory exit {ic}, inventory change {delta}, gate exit {gc}, failures {kinds}\n")
        fh.write(f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = (f"{tag}: inventory exit {ic} {delta or '(no change)'}; gate exit {gc} {kinds or '(no failures)'}; "
            f"{'AS EXPECTED' if ok else 'UNEXPECTED'}")
    print(line)
    return ok, line


BASE = None
results = []
if not QUICK:
    ok0, l0 = control("00-base", None, 0, {}, 0, {})
    BASE = summary_of(os.path.join(logdir, "inv-00-base"))
    results.append((ok0, l0))
if APPEND_MODE and not ok0:   # r28 (round 27's Opus M2): with no clean base, no appending control can be judged
    _msg = (f"control 00 failed at {rev} in scope {SCOPE}: the inventory and the gate do not pass the table given, so "
            f"no appending control ran (approve the table at this revision, in this scope, first)")
    print(_msg)
    print("0 of 1 as expected")   # the summary's last line, on stdout too, as the full run prints its own
    open(os.path.join(logdir, "summary.txt"), "w", encoding="utf-8", newline="\n").write(
        f"{l0}\n{_msg}\n0 of 1 as expected\n")
    sys.exit(1)
S, TW, A, EX, TM = "src/Surface.zig", "src/apprt/win32/terminal_window.zig", "src/apprt/win32/app.zig", \
    "src/termio/Exec.zig", "src/termio/Termio.zig"
MB = "src/termio/mailbox.zig"

# -- r10's controls, with exact counts
if want(1): results.append(control("01-new-site-under-wildcard", overlay("c01", {S: append(
    "pub fn r11ControlPeek(self: *Surface) bool {\n    self.renderer_state.mutex.lock();\n"
    "    defer self.renderer_state.mutex.unlock();\n    return true;\n}")}),
    1, {"acquisitions": 1, "live": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))
if want(2): results.append(control("02-changed-caller", overlay("c02", {TW: append(
    "fn r11ControlCaller(s: *Surface) bool {\n    return s.core_surface.hasSelection();\n}")}),
    0, {}, 1, {"CHANGED-FINGERPRINT": 1}))
if want(3): results.append(control("03-callback-value", overlay("c03", {EX: append(
    "pub const r11_control_cb = &termio.Termio.processOutput;")}), 0, {}, 1, {"CHANGED-FINGERPRINT": 1}))
if want(4): results.append(control("04-cited-hop-removed", overlay("c04", {"src/renderer/Thread.zig": replace(
    "    t.pacer.turn(.{ .wake = wake_sources }, Frame{ .t = t });\n",
    "    // r11 control: the wake no longer drives the pacer\n    _ = wake_sources;\n")}),
    0, {}, 1, {"CHANGED-PATH": 3}))
if want(5): results.append(control("05-anchor-moved", overlay("c05", {S: replace(
    "        rendererpkg.Thread.threadMain,\n", "        rendererpkg.Thread.threadMainR11,\n")}),
    0, {}, 1, {"ANCHOR-MOVED": 1, "NEW-THREAD-ENTRY": 1, "GONE-THREAD-ENTRY": 1}))
if want(6): results.append(control("06-unclassified-not-allowed", overlay("c06", {A: append(
    "fn r11ControlLock(m: *std.Thread.Mutex) void {\n    m.lock();\n    m.unlock();\n}")}),
    0, {"unclassified": 1}, 1, {"UNCLASSIFIED-NOT-ALLOWED": 1}))
if want(7): results.append(control("07-untyped-alias", overlay("c07", {S: append(
    "pub fn r11ControlAlias(self: *Surface) void {\n    const m = self.renderer_state.mutex;\n    m.lock();\n"
    "    defer m.unlock();\n}")}), 1, {"acquisitions": 1, "live": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))
if want(8): results.append(control("08-inline-carrier", overlay("c08", {"src/terminal/search/query_search.zig": append(
    "test \"r11 control: an inline carrier\" {\n    var mutex: std.Thread.Mutex = .{};\n    var t: Terminal = undefined;\n"
    "    var qs: QuerySearch = .init(std.testing.allocator, .{ .terminal = &t, .mutex = &mutex });\n    _ = &qs;\n}")}),
    0, {"carriers": 1}, 0, {}))
# -- round 10's probes (Z1)
if want(9): results.append(control("09-probe-A-state-copy", overlay("cA", {S: append(
    "pub fn r11ControlCopy(self: *Surface) void {\n    const st = self.renderer_state;\n    st.mutex.lock();\n"
    "    defer st.mutex.unlock();\n}")}), 1, {"acquisitions": 1, "live": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))
if want(10): results.append(control("10-probe-A2-copied-var", overlay("cA2", {S: append(
    "pub fn r11ControlCopied(self: *Surface) void {\n    var copied = self.renderer_state;\n    copied.mutex.lock();\n"
    "    defer copied.mutex.unlock();\n}")}), 1, {"acquisitions": 1, "live": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))
if want(11): results.append(control("11-probe-B-state-parameter", overlay("cB", {S: append(
    "fn r11ControlParam(state: *rendererpkg.State) void {\n    state.mutex.lock();\n    defer state.mutex.unlock();\n}")}),
    1, {"acquisitions": 1, "live": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))
if want(12): results.append(control("12-probe-C-helper-relock", overlay("cC", {S: append(
    "fn r11ControlHelper(m: *std.Thread.Mutex) void {\n    m.lock();\n    m.unlock();\n}\n\n"
    "pub fn r11ControlHelperCaller(self: *Surface) void {\n    r11ControlHelper(self.renderer_state.mutex);\n}")}),
    1, {"relocks": 1, "carriers": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))   # the helper's parameter carries it
if want(13): results.append(control("13-probe-E-relock-respelled", overlay("cE", {MB: replace(
    "                defer if (mutex) |m| m.lock();\n", "                defer if (mutex) |m| m.lockUncancelable(io);\n")}),
    0, {}, 0, {}))
if want(14): results.append(control("14-probe-H-statemutex-parameter", overlay("cH", {S: append(
    "fn r11ControlStateMutex(m: *rendererpkg.StateMutex) void {\n    m.lock();\n    m.unlock();\n}")}),
    1, {"acquisitions": 1, "live": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))   # Opus L4: StateMutex is the renderer mutex
if want(15): results.append(control("15-probe-H2-send-statemutex", overlay("cH2", {MB: replace(
    "        mutex: ?*std.Thread.Mutex,\n", "        mutex: ?*renderer.StateMutex,\n")}), 0, {}, 0, {}))
# -- Z4: never-on-Win32 rows need evidence
if FULL:   # r28 (round 27's Opus M2): reads the fixture's never-on-Win32 row and its UI chain
    tbl_z4 = os.path.join(logdir, "table-z4-never-with-ui-chain.tsv")
    lines = open(table, encoding="utf-8").read().split("\n")
    ui_chain = next(l.split("\t")[6] for l in lines if l.startswith("src/Surface.zig\t*[activateInspector") and "\tfork\t" in l)
    out = []
    for l in lines:
        if l.startswith("src/Surface.zig\t*[dumpText,mouseCaptured,mousePressureCallback]\t") and "\tfork\t" in l:
            f = l.split("\t")
            f[6] = ui_chain
            l = "\t".join(f)
        out.append(l)
    open(tbl_z4, "w", encoding="utf-8", newline="\n").write("\n".join(out))
    if want(16): results.append(control("16-Z4-never-row-carries-ui-chain", None, 0, {}, 1, {"NEVER-CHAIN": 1, "NEVER-NO-EVIDENCE": 1},
                           tbl=tbl_z4))
if want(17): results.append(control("17-Z4-absent-evidence-falsified", overlay("cZ4b", {TW: append(
    "fn r11ControlDump(s: *Surface) void {\n    _ = s.core_surface.dumpText(undefined, undefined) catch {};\n}")}),
    0, {}, 1, {"CHANGED-PATH": 1, "CHANGED-FINGERPRINT": 1}))
# -- Y3: a real call added in a function that already holds a false edge (probe F)
if want(18): results.append(control("18-Y3-probe-F-real-call-beside-false-edge", overlay("cF", {TM: replace(
    "    try self.backend.resize(grid_size, size.terminal());\n",
    "    try self.backend.resize(grid_size, size.terminal());\n    try self.resize(undefined, size);\n")}),
    0, {}, 1, {"CHANGED-FINGERPRINT": 1}))
# -- Z2: a new thread entry (a spawn, and an Io task as 1B would add)
if want(19): results.append(control("19-Z2-new-thread-spawn", overlay("cZ2", {A: append(
    "fn r11ControlWorker() void {}\n\npub fn r11ControlSpawn() !void {\n"
    "    const t = try std.Thread.spawn(.{}, r11ControlWorker, .{});\n    t.detach();\n}")}),
    0, {}, 1, {"NEW-THREAD-ENTRY": 1}))
if want(20): results.append(control("20-Z2-new-io-task", overlay("cZ2b", {A: append(
    "fn r11ControlTask() void {}\n\npub fn r11ControlAsync(io: anytype) void {\n    _ = io.async(r11ControlTask, .{});\n}")}),
    0, {}, 1, {"NEW-THREAD-ENTRY": 1}))
# -- Z1: a stale row, and the site-count assertion
if want(21): results.append(control("21-Z1-stale-row", overlay("cStale", {TM: replace(
    "    try self.backend.resize(grid_size, size.terminal());\n\n    {\n        self.renderer_state.mutex.lock();\n"
    "        defer self.renderer_state.mutex.unlock();\n",
    "    try self.backend.resize(grid_size, size.terminal());\n\n    {\n")}),
    0, {"acquisitions": -1, "live": -1}, 1, {"STALE-ROW": 1}))


def tamper_count(prefix):
    p = prefix + "-summary.tsv"
    t = open(p, encoding="utf-8").read().split("\n")
    t[1] = re.sub(r"^(\S+)\t(\d+)", lambda m: f"{m.group(1)}\t{int(m.group(2)) + 1}", t[1])
    open(p, "w", encoding="utf-8", newline="\n").write("\n".join(t))


if want(22): results.append(control("22-Z1-site-count-assertion", None, 0, {"acquisitions": 1}, 1, {"SITE-COUNT-MISMATCH": 1},
                       tamper=tamper_count))
# -- the stated limit: transitive paths pass the static trigger (the runtime observed-pairs check owns them)
if want(23): results.append(control("23-limit-D-termio-to-ui-only-fn", overlay("cD", {TM: replace(
    "pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {\n",
    "pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {\n"
    "    _ = self.surface_mailbox.surface.needsConfirmQuitNoWait();\n")}), 0, {}, 0, {}))
if want(24): results.append(control("24-limit-G-uia-thread-refresh", overlay("cG", {"src/apprt/win32_terminal_accessibility.zig": replace(
    "        const self: *TerminalAccessibilitySession = @ptrCast(@alignCast(ctx));\n        const hwnd = dispatch: {\n",
    "        const self: *TerminalAccessibilitySession = @ptrCast(@alignCast(ctx));\n        self.refresh(true);\n"
    "        const hwnd = dispatch: {\n")}), 0, {}, 0, {}))
if want(25): results.append(control("25-limit-sol-renderer-to-pwd", overlay("cSol", {"src/renderer/Thread.zig": replace(
    "    t.pacer.turn(.{ .wake = wake_sources }, Frame{ .t = t });\n",
    "    t.pacer.turn(.{ .wake = wake_sources }, Frame{ .t = t });\n    t.surface.core().openLinkText(\"x\") catch {};\n")}),
    0, {}, 0, {}))
# -- AA5: the acquisition signature of an approved function
if want(26): results.append(control("26-AA5-added-acquisition-in-approved-function", overlay("cAA5a", {S: replace(
    "pub fn hasSelection(self: *const Surface) bool {\n",
    "pub fn hasSelection(self: *const Surface) bool {\n    self.renderer_state.mutex.lock();\n"
    "    self.renderer_state.mutex.unlock();\n")}),
    0, {"acquisitions": 1, "live": 1}, 1, {"CHANGED-SIGNATURE": 1}))
if want(27): results.append(control("27-AA5-operation-changed", overlay("cAA5b", {
    TM: replace("pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {\n    self.renderer_state.mutex.lock();\n",
                "pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {\n"
                "    if (!self.renderer_state.mutex.tryLock()) return;\n"),
    S: replace("pub fn hasSelection(self: *const Surface) bool {\n    self.renderer_state.mutex.lock();\n"
               "    defer self.renderer_state.mutex.unlock();\n",
               "pub fn hasSelection(self: *const Surface) bool {\n    self.renderer_state.lockDemand();\n"
               "    defer self.renderer_state.unlockDemand();\n")}),
    0, {}, 1, {"CHANGED-SIGNATURE": 2}))
# -- r13 (round 12): M-b, inline sites
SH = "src/termio/stream_handler.zig"
if want(28): results.append(control("28-Mb-inline-fn-on-approved-function", overlay("cMb1", {TM: replace(
    "pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {\n",
    "pub inline fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {\n")}),
    0, {"inline_flagged": 1}, 1, {"INLINE-SITE": 1}))
if want(29): results.append(control("29-Mb-new-always-inline-call", overlay("cMb2", {EX: append(
    "pub fn r13ControlAlways(t: *termio.Termio) void {\n"
    "    @call(.always_inline, termio.Termio.scrollViewport, .{ t, undefined }) catch {};\n}")}),
    0, {"inline_flagged": 1}, 1, {"INLINE-SITE": 1, "CHANGED-FINGERPRINT": 1}))
if want(30): results.append(control("30-Mb-debug-fix-processOutput-auto", overlay("cMb3", {EX: lambda s: (
    s.replace("@call(.always_inline, termio.Termio.processOutput,",
              "@call(if (builtin.mode == .Debug) .auto else .always_inline, termio.Termio.processOutput,")
    if s.count("@call(.always_inline, termio.Termio.processOutput,") == 2 else s)}),
    0, {"inline_flagged": -1}, 1, {"INLINE-STALE": 1}))
if want(31): results.append(control("31-Mb-debug-fix-surfaceMessageWriter-plain", overlay("cMb4", {SH: replace(
    "    inline fn surfaceMessageWriter(\n", "    fn surfaceMessageWriter(\n")}),
    0, {"inline_flagged": -1}, 1, {"INLINE-STALE": 1}))
# -- M-c: the renderer demand check, armed
ARMED_FORK_FAILURES = 3  # the frozen fork precedes the renderer demand conversion
if want(32): results.append(control("32-Mc-armed-at-fixture", None, 0, {}, 1,
                                    {"RENDERER-PLAIN-LOCK": ARMED_FORK_FAILURES},
                       gate_extra=["--arm-renderer-demand"]))
RT, GEN = "src/renderer/Thread.zig", "src/renderer/generic.zig"
if want(33): results.append(control("33-Mc-armed-after-conversion", overlay("cMc2", {
    RT: lambda s: s.replace("        const state = f.t.state;\n        state.mutex.lock();\n        defer state.mutex.unlock();\n",
                            "        const state = f.t.state;\n        state.lockDemand();\n        defer state.unlockDemand();\n")
    if s.count("        const state = f.t.state;\n        state.mutex.lock();\n        defer state.mutex.unlock();\n") == 2 else s,
    GEN: replace("                state.mutex.lock();\n                defer state.mutex.unlock();\n\n"
                 "                const cursor_blinking = state.terminal.modes.get(.cursor_blinking);\n",
                 "                state.lockDemand();\n                defer state.unlockDemand();\n\n"
                 "                const cursor_blinking = state.terminal.modes.get(.cursor_blinking);\n")}),
    0, {}, 1, {"CHANGED-SIGNATURE": 3}, gate_extra=["--arm-renderer-demand"]))
# -- M-f: test-code sites
if want(34): results.append(control("34-Mf-new-test-acquisition", overlay("cMf1", {S: append(
    "test \"r13 control: a direct test acquisition\" {\n    var surface: Surface = undefined;\n"
    "    var renderer_mutex: std.Thread.Mutex = .{};\n    surface.renderer_state.mutex = &renderer_mutex;\n"
    "    renderer_mutex.lock();\n    renderer_mutex.unlock();\n}")}),
    0, {"test_sites": 1, "carriers": 1}, 1, {"TEST-UNREVIEWED": 1}))
if want(35): results.append(control("35-Mf-approved-test-renamed", overlay("cMf2", {SH: replace(
    'test "a stopped reader gives up waiting on a full mailbox and sends nothing after" {\n',
    'test "a stopped reader gives up waiting on a full mailbox (renamed)" {\n')}),
    0, {}, 1, {"TEST-UNREVIEWED": 1, "STALE-ROW": 1}))
if want(36): results.append(control("36-Mf-test-acquisition-changed", overlay("cMf3", {SH: replace(
    "        fn run(self: *@This()) void {\n            self.mutex.lock();\n",
    "        fn run(self: *@This()) void {\n            if (!self.mutex.tryLock()) return;\n")}),
    0, {}, 1, {"CHANGED-SIGNATURE": 1}))
if FULL:   # r28 (round 27's Opus M2): reads the fixture's test row
    tbl_role = os.path.join(logdir, "table-mf-test-row-not-a-role.tsv")
    lines = open(table, encoding="utf-8").read().split("\n")
    out, n = [], 0
    for l in lines:
        f = l.split("\t")
        if len(f) >= 7 and f[4] == "test" and f[0] == SH:
            f[3] = "the reader"
            n += 1
        out.append("\t".join(f))
    assert n == 1
    open(tbl_role, "w", encoding="utf-8", newline="\n").write("\n".join(out))
    if want(37): results.append(control("37-Mf-test-row-without-a-role", None, 0, {}, 1, {"TEST-NO-ROLE": 1}, tbl=tbl_role))
# -- Sol L4: a task call whose arguments are not spelled io
if want(38): results.append(control("38-SolL4-task-call-any-spelling", overlay("cL4", {A: append(
    "fn r13ControlWorker() void {}\n\npub fn r13ControlTasks(tasks: anytype, backend: anytype) void {\n"
    "    _ = tasks.async(backend, r13ControlWorker, .{});\n}")}),
    0, {}, 1, {"NEW-THREAD-ENTRY": 1}))
# -- r14 (round 13): AC2, the demand forwarder (1A.2's State.lockDemand: an inline fn calling the wrapper's demand)
ST, GEN = "src/renderer/State.zig", "src/renderer/generic.zig"
FWD = "pub inline fn lockDemand(self: *State) void {\n    self.mutex.demand();\n}"
FWD_PLAIN = "pub fn lockDemand(self: *State) void {\n    self.mutex.demand();\n}"
SNAP_OLD = ("                state.mutex.lock();\n                defer state.mutex.unlock();\n\n"
            "                const cursor_blinking = state.terminal.modes.get(.cursor_blinking);\n")
SNAP_NEW = ("                state.lockDemand();\n                defer state.unlockDemand();\n\n"
            "                const cursor_blinking = state.terminal.modes.get(.cursor_blinking);\n")
if FULL:   # r28 (round 27's Opus M2): reads the fixture's updateFrame chain
    upd_chain = next(l.split("\t")[6] for l in open(table, encoding="utf-8").read().split("\n")
                     if l.startswith("src/renderer/generic.zig\tupdateFrame\t") and "\tfork\t" in l)
    FWD_ROW = "\t".join([ST, "lockDemand", "", "renderer|ui", "fork",
                         "the demand forwarder (AC2): updateFrame's snapshot calls it (generic.zig:1557) on the renderer "
                         "thread and in the UI-thread fallback (Windows.zig:217)",
                         upd_chain + ";src/renderer/generic.zig:updateFrame:lockDemand"])


def fwd_table(name):
    p = os.path.join(logdir, name)
    open(p, "w", encoding="utf-8", newline="\n").write(open(table, encoding="utf-8").read().rstrip("\n") + "\n" + FWD_ROW + "\n")
    return p


def approve_hook(tbl, ov):
    def f(prefix):
        rc, out = run([py, "-I", gate, "approve", repo, rev, SCOPE, tbl, prefix, "--overlay", ov])
        return f"approve (exit {rc}): {out.strip()}"
    return f


if FULL:   # r28 (round 27's Opus M2): replaces the fixture's text
    ov39 = overlay("cAC2a", {ST: append(FWD), GEN: replace(SNAP_OLD, SNAP_NEW)})
    t39 = fwd_table("table-ac2-forwarder.tsv")
    if want(39): results.append(control("39-AC2-forwarder-reviewed-inline", ov39, 0, {"handoff_internal": 1, "inline_flagged": 1}, 0, {},
                           tbl=t39, pre=approve_hook(t39, ov39)))
    ov40 = overlay("cAC2b", {ST: append(FWD_PLAIN), GEN: replace(SNAP_OLD, SNAP_NEW)})
    t40 = fwd_table("table-ac2-forwarder-plain.tsv")
    if want(40): results.append(control("40-AC2-forwarder-not-inline", ov40, 0, {"handoff_internal": 1}, 1, {"FORWARDER-NOT-INLINE": 1},
                           tbl=t40, pre=approve_hook(t40, ov40)))
if want(41): results.append(control("41-AC2-forwarder-recognised-unreviewed", overlay("cAC2c", {ST: append(FWD)}),
                       1, {"handoff_internal": 1, "inline_flagged": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))

# -- the compare's run rules (round 13: AC5, AC1; round 14: AD1, Opus L2), tools/role_compare2.py, synthetic dumps
CMP_TABLE = ("src/renderer/generic.zig:updateFrame\trenderer|ui\n"
             "src/Surface.zig:keyCallback\tui\n"
             "src/Surface.zig:confirmQuitAnswer\tui\n"
             "src/termio/mailbox.zig:send\tui|reader\n"
             "src/renderer/Thread.zig:step\trenderer\n"
             "src/terminal/search/query_search.zig:step\tsearch\n"
             "src/termio/stream_handler.zig:test:a stopped reader gives up waiting on a full mailbox and sends nothing "
             "after\treader\n")
CMP_MANIFEST = ("launch\t700\t134070000000000700\tgui\n"
                "launch\t701\t134070000000000701\tcli\n"
                "launch\t702\t134070000000000702\tforwarded\n")
# r18 (AG2): the fixture run's expectations, which r17 kept in the manifest
CMP_RUNS = ("fixture\tgroup\ttest-exe\t1\n"
            "fixture\trequired\tsrc/termio/mailbox.zig:send\treader\n"
            "fixture\trequired\tsrc/Surface.zig:confirmQuitAnswer\tui\n")
GUI = "# kind=gui pid=700 start=134070000000000700\nsrc/Surface.zig:keyCallback ui\n"
SUITE = ("# kind=test-exe pid=800 start=134070000000000800\nsrc/termio/mailbox.zig:send reader\n"
         "src/Surface.zig:confirmQuitAnswer__anon_30924 ui\n")
BASE_DUMPS = {"gui-700.pairs": GUI, "test-exe-800.pairs": SUITE}


def launch_rows(text):
    return [l for l in text.split("\n") if re.fullmatch(r"launch\t\d+\t[^\t]*\t(?:gui|cli|forwarded)", l)]


def seal_row(rows):
    body = "".join(r + "\n" for r in sorted(rows))
    return f"seal\t{len(rows)}\t{hashlib.sha256(body.encode('utf-8')).hexdigest()}\n"


def compare_control(tag, dumps, exp_exit, exp_kinds, extra=(), manifest=None, isolated=False, exp_line=None,
                    runs=None, run_name="fixture", table=None, seal="auto", compiler="0.17", table_file=None,
                    scope=None):
    d = os.path.join(logdir, "compare", tag)
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(os.path.join(d, "dumps"))
    mtext = CMP_MANIFEST if manifest is None else manifest
    if seal == "auto":   # the supervisor sealed what it launched: the manifest's well-formed launch rows
        mtext += seal_row(launch_rows(mtext))
    elif isinstance(seal, list):   # the supervisor launched these, whatever the manifest now holds
        mtext += seal_row(seal)
    open(os.path.join(d, "manifest.tsv"), "w", encoding="utf-8", newline="\n").write(mtext)
    if table_file:   # r26: a table file, the reviewed table itself (Kimi M1)
        shutil.copy(table_file, os.path.join(d, "table.tsv"))
    else:
        open(os.path.join(d, "table.tsv"), "w", encoding="utf-8", newline="\n").write(table or CMP_TABLE)
    open(os.path.join(d, "runs.tsv"), "w", encoding="utf-8", newline="\n").write(CMP_RUNS if runs is None else runs)
    for name, text in dumps.items():
        os.makedirs(os.path.dirname(os.path.join(d, "dumps", name)), exist_ok=True)
        open(os.path.join(d, "dumps", name), "w", encoding="utf-8", newline="\n").write(text)
    extra = list(extra) + (["--table-scope", scope] if scope else []) + \
        (["--isolated"] if isolated else ["--runs", os.path.join(d, "runs.tsv"), "--run", run_name, "--compiler", compiler])
    rc, out = run([py, "-I", compare, "-" if isolated else os.path.join(d, "manifest.tsv"),
                   os.path.join(d, "table.tsv"), os.path.join(d, "dumps")] + extra)
    kinds = {}
    for l in out.splitlines():
        if l.startswith("FAIL "):
            k = l.split(" ", 2)[1]
            kinds[k] = kinds.get(k, 0) + 1
    ok = rc == exp_exit and kinds == exp_kinds and (exp_line is None or exp_line in out.splitlines())
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## compare (exit {rc}; arguments {list(extra) or 'none'})\n{out}\n")
        fh.write(f"dumps: {sorted(dumps)}\nexpected: exit {exp_exit}, failures {exp_kinds}"
                 + (f", the line {exp_line!r}" if exp_line else "") + "\n")
        fh.write(f"observed: exit {rc}, failures {kinds}\nCONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: compare exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


def without(name):
    return {k: v for k, v in BASE_DUMPS.items() if k != name}


if want(42): results.append(compare_control("42-AC5-AD1-optional-kinds-leave-nothing", dict(BASE_DUMPS), 0, {}))
if want(43): results.append(compare_control("43-AC5-launched-gui-recorded-no-pair",
                               {**BASE_DUMPS, "gui-700.pairs": "# kind=gui pid=700 start=134070000000000700\n"},
                               1, {"EMPTY-DUMP": 1}))
if want(44): results.append(compare_control("44-AD1-launched-gui-pid-left-no-dump", without("gui-700.pairs"), 1, {"MISSING-DUMP": 1}))
if want(45): results.append(compare_control("45-AD1-dump-in-no-launch-row",
                               {**BASE_DUMPS, "gui-999.pairs": "# kind=gui pid=999 start=134070000000000999\n"
                                                               "src/Surface.zig:keyCallback ui\n"},
                               1, {"UNEXPECTED-PROCESS": 1}))
if want(46): results.append(compare_control("46-AC1-instantiation-suffix-not-stripped", dict(BASE_DUMPS),
                               1, {"PAIR-OUTSIDE-TABLE": 1, "MISSING-REQUIRED-PAIR": 1}, extra=["--no-strip"]))
if want(47): results.append(compare_control("47-AC5-pair-outside-table",
                               {**BASE_DUMPS, "gui-700.pairs": GUI + "src/Surface.zig:keyCallback termio\n"},
                               1, {"PAIR-OUTSIDE-TABLE": 1}))
if want(48): results.append(compare_control("48-AC5-dump-without-header", {**BASE_DUMPS, "orphan.pairs": "src/termio/mailbox.zig:send reader\n"},
                               1, {"BAD-DUMP": 1}))
if want(49): results.append(compare_control("49-AD1-test-exe-restart-joins-its-group",
                               {**BASE_DUMPS, "test-exe-801.pairs": "# kind=test-exe pid=801 start=134070000000000801\n"
                                                                    "src/termio/mailbox.zig:send reader\n"},
                               0, {}))
if want(50): results.append(compare_control("50-AD1-no-test-exe-with-pairs", without("test-exe-800.pairs"),
                               1, {"MISSING-DUMP": 1, "MISSING-REQUIRED-PAIR": 2}))
if want(51): results.append(compare_control("51-AD1-pid-reused-other-start",
                               {**without("gui-700.pairs"), "gui-700b.pairs": "# kind=gui pid=700 start=134070000000000777\n"
                                                                              "src/Surface.zig:keyCallback ui\n"},
                               1, {"MISSING-DUMP": 1, "UNEXPECTED-PROCESS": 1}))
if want(52): results.append(compare_control("52-AD1-forwarded-start-that-recorded",
                               {**BASE_DUMPS, "gui-702.pairs": "# kind=gui pid=702 start=134070000000000702\n"
                                                               "src/Surface.zig:keyCallback ui\n"},
                               0, {}))
COLLIDE = GUI + "src/terminal/search/query_search.zig:step renderer\n"
if want(53): results.append(compare_control("53-L2-function-name-collision", {**BASE_DUMPS, "gui-700.pairs": COLLIDE},
                               1, {"PAIR-OUTSIDE-TABLE": 1}))
if want(54): results.append(compare_control("54-L2-bare-names-accept-the-collision", {**BASE_DUMPS, "gui-700.pairs": COLLIDE},
                               0, {}, extra=["--bare-names"]))
if want(55): results.append(compare_control("55-L2-test-block-keys",
                               {**BASE_DUMPS, "test-exe-800.pairs": SUITE
                                + "src/termio/stream_handler.zig:test:a stopped reader gives up waiting on a full "
                                  "mailbox and sends nothing after reader\n"
                                + "src/termio/stream_handler.zig:test:another test reader\n"},
                               1, {"PAIR-OUTSIDE-TABLE": 1}))
# -- r16 (round 15): AE1, an isolated child's dump; Opus L3, a torn manifest row
CHILD = ("# kind=child pid=900 start=134070000000000900\n"
         "src/Surface.zig:keyCallback termio\n")   # test 4's deliberate wrong-role pair, recorded by a child
if want(56): results.append(compare_control("56-AE1-child-dump-in-its-own-directory",
                               {**BASE_DUMPS, "children/child-900.pairs": CHILD}, 0, {}))
if want(57): results.append(compare_control("57-AE1-child-dump-reached-the-run-directory",
                               {**BASE_DUMPS, "child-900.pairs": CHILD}, 1, {"CHILD-DUMP-IN-RUN": 1}))
if want(58): results.append(compare_control("58-L3-torn-manifest-row", dict(BASE_DUMPS), 1, {"BAD-MANIFEST": 1},
                               manifest=CMP_MANIFEST + "launch\t703\t1340700\n"))
# -- r17 (round 16): AF2, the parent's compare of an isolated child's own directory (--isolated, no manifest)
CHILD12 = ("# kind=child pid=901 start=134070000000000901\n"
           "src/Surface.zig:keyCallback ui\n"
           "src/termio/mailbox.zig:send reader\n")   # test 12's two in-table sites, then its panic
if want(59): results.append(compare_control("59-AF2-isolated-off-table-variant", {"child-900.pairs": CHILD}, 1,
                               {"PAIR-OUTSIDE-TABLE": 1}, isolated=True,
                               exp_line="FAIL PAIR-OUTSIDE-TABLE child-900.pairs: "
                                        "(src/Surface.zig:keyCallback, termio)"))
if want(60): results.append(compare_control("60-AF2-isolated-panic-variant-pairs-in-table", {"child-901.pairs": CHILD12}, 0, {},
                               isolated=True))
if want(61): results.append(compare_control("61-AF2-isolated-directory-holds-a-non-child-dump",
                               {"child-901.pairs": CHILD12, "gui-700.pairs": GUI}, 1, {"NOT-CHILD-DUMP": 1},
                               isolated=True))
if want(62): results.append(compare_control("62-AF2-isolated-child-left-no-dump", {}, 1, {"MISSING-DUMP": 1}, isolated=True))
# -- r18 (round 17): AG2, expectations from the run spec, not the manifest; Opus L10, an isolated child with no pair
# r28 (round 27's Opus M2): the fixture's run spec and table, frozen with the revision they were approved at; r26 and
# r27 read the live ones, which a branch's re-approved table would change under these controls' expectations
DRAFT_RUNS = open(os.path.join(FIX, "role-runs.tsv"), encoding="utf-8").read() if FULL or QUICK else None
# r26 (round 25's Kimi M1): these controls read the reviewed seven-column table itself, in the fork scope; r18 to r25
# used a seven-row two-column stand-in (DRAFT_TABLE), which hid that the compare could not read the real table
REVIEWED_TABLE = os.path.join(FIX, "lock-inventory-threads.tsv") if FULL or QUICK else None
SUITE_ALL = ("# kind=test-exe pid=810 start=134070000000000810\n"
             "src/termio/stream_handler.zig:surfaceMessageWriter reader\n"
             "src/termio/mailbox.zig:send ui\nsrc/termio/mailbox.zig:send reader\n"
             "src/termio/Termio.zig:focusGained termio\n"
             "src/terminal/search/query_search.zig:stop search\n")
GUI_ALL = ("# kind=gui pid=710 start=134070000000000710\nsrc/renderer/generic.zig:updateFrame renderer\n"
           "src/termio/Termio.zig:processOutput reader\nsrc/Surface.zig:keyCallback ui\n")
if want(63): results.append(compare_control("63-AG2-debug-suite-run-empty-manifest-no-dumps", {}, 1,
                               {"MISSING-DUMP": 1, "MISSING-REQUIRED-PAIR": 5},
                               manifest="", runs=DRAFT_RUNS, run_name="debug-suite", table_file=REVIEWED_TABLE, scope=SCOPE))
if want(64): results.append(compare_control("64-AG2-fixture-suite-dump-gone-manifest-without-expectations",
                               without("test-exe-800.pairs"), 1, {"MISSING-DUMP": 1, "MISSING-REQUIRED-PAIR": 2}))
if want(65): results.append(compare_control("65-AG2-manifest-row-that-would-weaken-the-run", dict(BASE_DUMPS), 1,
                               {"BAD-MANIFEST": 1}, manifest=CMP_MANIFEST + "group\ttest-exe\t0\n"))
if want(66): results.append(compare_control("66-AG2-composite-run-empty-manifest-no-dumps", {}, 1,
                               {"MISSING-LAUNCH": 1, "MISSING-REQUIRED-PAIR": 3},
                               manifest="", runs=DRAFT_RUNS, run_name="composite", table_file=REVIEWED_TABLE, scope=SCOPE))
if want(67): results.append(compare_control("67-AG2-unknown-run", dict(BASE_DUMPS), 1, {"BAD-RUN-SPEC": 1}, run_name="no-such-run"))
if want(68): results.append(compare_control("68-AG2-debug-suite-run-complete", {"test-exe-810.pairs": SUITE_ALL}, 0, {},
                               manifest="", runs=DRAFT_RUNS, run_name="debug-suite", table_file=REVIEWED_TABLE, scope=SCOPE))
if want(69): results.append(compare_control("69-AG2-composite-run-complete", {"gui-710.pairs": GUI_ALL}, 0, {},
                               manifest="launch\t710\t134070000000000710\tgui\n", runs=DRAFT_RUNS,
                               run_name="composite", table_file=REVIEWED_TABLE, scope=SCOPE))
if want(70): results.append(compare_control("70-L10-isolated-child-recorded-no-pair",
                               {"child-902.pairs": "# kind=child pid=902 start=134070000000000902\n"}, 1,
                               {"EMPTY-DUMP": 1}, isolated=True))
# -- r19 (round 18): AH2, a same-named acquiring function in one file; std.debug's test symbol. AH3, the seal.
if want(71): results.append(control("71-AH2-same-name-acquiring-function-in-one-file", overlay("c71", {S: append(
    "const R19SameName = struct {\n    fn keyCallback(s: *Surface) void {\n        s.renderer_state.mutex.lock();\n"
    "        defer s.renderer_state.mutex.unlock();\n    }\n};")}),
    1, {"acquisitions": 1, "live": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))
G710 = "launch\t710\t134070000000000710\tgui"
G711 = "launch\t711\t134070000000000711\tgui"
if want(72): results.append(compare_control("72-AH3-complete-launch-row-removed-required-pairs-kept", {"gui-710.pairs": GUI_ALL}, 1,
                               {"BAD-SEAL": 1}, manifest=G710 + "\n", runs=DRAFT_RUNS, run_name="composite",
                               table_file=REVIEWED_TABLE, scope=SCOPE, seal=[G710, G711]))
if want(73): results.append(compare_control("73-AH3-launch-row-kept-its-dump-missing", {"gui-710.pairs": GUI_ALL}, 1,
                               {"MISSING-DUMP": 1}, manifest=G710 + "\n" + G711 + "\n", runs=DRAFT_RUNS,
                               run_name="composite", table_file=REVIEWED_TABLE, scope=SCOPE))
if want(74): results.append(compare_control("74-AH3-no-seal", dict(BASE_DUMPS), 1, {"MISSING-SEAL": 1}, seal=None))
if want(75): results.append(compare_control("75-AH3-row-changed-after-sealing", dict(BASE_DUMPS), 1, {"BAD-SEAL": 1},
                               manifest=CMP_MANIFEST.replace("\tcli\n", "\tforwarded\n"),
                               seal=launch_rows(CMP_MANIFEST)))
if want(76): results.append(compare_control("76-AH2-std-debug-test-symbol-maps-to-the-test-key",
                               {**BASE_DUMPS, "test-exe-800.pairs": SUITE
                                + "src/termio/stream_handler.zig:test.a stopped reader gives up waiting on a full "
                                  "mailbox and sends nothing after reader\n"}, 0, {}))
# -- r20 (round 19): AI2, file-qualified test keys; AI5, the supervisor's own record; Opus L8, the compiler column
XRUNS = "xfile\tgroup\ttest-exe\t1\n"
XTABLE = "src/a.zig:test:shared name\tui\nsrc/b.zig:test:shared name\treader\n"


def xsuite(line):
    return {"test-exe-830.pairs": "# kind=test-exe pid=830 start=134070000000000830\n" + line + "\n"}


if want(77): results.append(compare_control("77-AI2-same-test-name-in-two-files-wrong-role", xsuite("src/b.zig:test.shared name ui"),
                               1, {"PAIR-OUTSIDE-TABLE": 1}, manifest="", runs=XRUNS, run_name="xfile", table=XTABLE))
if want(78): results.append(compare_control("78-AI2-same-test-name-its-own-file-role", xsuite("src/a.zig:test.shared name ui"),
                               0, {}, manifest="", runs=XRUNS, run_name="xfile", table=XTABLE))
if want(79): results.append(compare_control("79-AI2-two-table-rows-one-identity", xsuite("src/a.zig:test.shared name ui"), 1,
                               {"DUPLICATE-IDENTITY": 1}, manifest="", runs=XRUNS, run_name="xfile",
                               table="src/a.zig:test:shared name\tui\nsrc/a.zig:test.shared name\treader\n"))
if want(80): results.append(compare_control("80-AI2-unqualified-test-key", xsuite("src/a.zig:test.shared name ui"), 1,
                               {"UNQUALIFIED-KEY": 1, "PAIR-OUTSIDE-TABLE": 1}, manifest="", runs=XRUNS,
                               run_name="xfile", table="test:shared name\tui\n"))
supervisor = os.path.join(here, "role_supervisor.py")


def supervised_control(tag, launches, drop, from_manifest, dumps, exp_exit, exp_kinds):
    """The supervisor records each launch; the harness then rewrites the manifest without `drop`'s row, BEFORE the
    seal; the supervisor seals from its own record (or, from_manifest, from the manifest: the hazard)."""
    d = os.path.join(logdir, "compare", tag)
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(os.path.join(d, "dumps"))
    m = os.path.join(d, "manifest.tsv")
    open(m, "w", encoding="utf-8", newline="\n").close()
    steps = []
    for pid, start, kind in launches:
        steps.append(run([py, "-I", supervisor, "launch", os.path.join(d, "state"), m, pid, start, kind]))
    kept = [l for l in open(m, encoding="utf-8") if l.split("\t")[1:2] != [drop]]
    open(m, "w", encoding="utf-8", newline="\n").write("".join(kept))
    steps.append(run([py, "-I", supervisor, "seal", os.path.join(d, "state"), m]
                     + (["--from-manifest"] if from_manifest else [])))
    shutil.copy(REVIEWED_TABLE, os.path.join(d, "table.tsv"))   # r26: the reviewed table, not a stand-in
    open(os.path.join(d, "runs.tsv"), "w", encoding="utf-8", newline="\n").write(DRAFT_RUNS)
    for name, text in dumps.items():
        open(os.path.join(d, "dumps", name), "w", encoding="utf-8", newline="\n").write(text)
    rc, out = run([py, "-I", compare, m, os.path.join(d, "table.tsv"), os.path.join(d, "dumps"),
                   "--runs", os.path.join(d, "runs.tsv"), "--run", "composite", "--compiler", "0.17",
                   "--table-scope", SCOPE])
    kinds = {}
    for l in out.splitlines():
        if l.startswith("FAIL "):
            k = l.split(" ", 2)[1]
            kinds[k] = kinds.get(k, 0) + 1
    ok = all(c == 0 for c, _ in steps) and rc == exp_exit and kinds == exp_kinds
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("## supervisor steps (exit codes)\n" + " ".join(str(c) for c, _ in steps) + "\n")
        fh.write("## the manifest the compare read\n" + open(m, encoding="utf-8").read())
        fh.write(f"## compare (exit {rc})\n{out}\n")
        fh.write(f"expected: exit {exp_exit}, failures {exp_kinds}\nobserved: exit {rc}, failures {kinds}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: compare exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


SUP = [("710", "134070000000000710", "gui"), ("711", "134070000000000711", "gui")]
if want(81): results.append(supervised_control("81-AI5-row-dropped-before-the-seal-sealed-from-the-supervisor-record", SUP, "711",
                                  False, {"gui-710.pairs": GUI_ALL}, 1, {"BAD-SEAL": 1}))
if want(82): results.append(supervised_control("82-AI5-the-same-sealed-from-the-manifest-the-hazard", SUP, "711", True,
                                  {"gui-710.pairs": GUI_ALL}, 0, {}))
SOAK_MANIFEST = "launch\t720\t134070000000000720\tgui\n"
if want(83): results.append(compare_control("83-L8-soak-advisory-on-0.15", {"gui-720.pairs": "# kind=gui pid=720 start=134070000000000720\n"
                                                                "src/start.zig:WinStartup renderer\n"}, 0,
                               {"PAIR-OUTSIDE-TABLE": 1}, manifest=SOAK_MANIFEST, runs=DRAFT_RUNS,
                               run_name="soak-releasesafe", table_file=REVIEWED_TABLE, scope=SCOPE, compiler="0.15"))
if want(84): results.append(compare_control("84-L8-soak-pairs-required-on-0.17", {"gui-720.pairs": "# kind=gui pid=720 start=134070000000000720\n"
                                                                      "src/Surface.zig:keyCallback ui\n"}, 1,
                               {"MISSING-REQUIRED-PAIR": 2}, manifest=SOAK_MANIFEST, runs=DRAFT_RUNS,
                               run_name="soak-releasesafe", table_file=REVIEWED_TABLE, scope=SCOPE, compiler="0.17"))
# -- r21 (round 20): AJ1, same-named acquiring test blocks in two containers of one file, and identical table rows;
# AJ3, the 0.15.2 soak's non-pair kinds gate; AJ2, the installed ci/ layout
W32 = "src/apprt/win32.zig"
NESTED = "".join(
    f"const R21Nested{c} = struct {{\n    test \"r21 nested same name\" {{\n"
    "        var renderer_mutex: std.Thread.Mutex = .{};\n        var other: TerminalWindow = undefined;\n"
    "        other.core_surface.renderer_state.mutex = &renderer_mutex;\n        renderer_mutex.lock();\n"
    "        renderer_mutex.unlock();\n    }\n};\n\n" for c in "AB").rstrip("\n")
if want(85): results.append(control("85-AJ1-same-named-acquiring-tests-in-two-containers", overlay("c85", {W32: append(NESTED)}),
                       1, {"carriers": 2, "test_sites": 2, "same_name": 1}, 1, {"TEST-UNREVIEWED": 2}))
tbl_merged = os.path.join(logdir, "table-aj1-one-merged-test-row.tsv")
open(tbl_merged, "w", encoding="utf-8", newline="\n").write(
    open(table, encoding="utf-8").read().rstrip("\n") + "\n" + W32 + "\t(test)\t@renderer-state.lock:2\tui|termio\ttest\t"
    "one merged row for two same-named tests in two containers (round 20, Opus): the gate passes it\t"
    "test:r21 nested same name\n")
if want(86): results.append(control("86-AJ1-the-same-with-one-merged-row-the-gate-passes", overlay("c86", {W32: append(NESTED)}),
                       1, {"carriers": 2, "test_sites": 2, "same_name": 1}, 0, {}, tbl=tbl_merged))
if want(87): results.append(compare_control("87-AJ1-two-identical-table-rows-two-roles", xsuite("src/a.zig:test.shared name ui"), 1,
                               {"DUPLICATE-IDENTITY": 1}, manifest="", runs=XRUNS, run_name="xfile",
                               table="src/a.zig:test:shared name\tui\nsrc/a.zig:test:shared name\treader\n"))
if want(88): results.append(compare_control("88-AJ3-soak-on-0.15-a-launch-and-no-dump", {}, 1, {"MISSING-DUMP": 1},
                               manifest=SOAK_MANIFEST, runs=DRAFT_RUNS, run_name="soak-releasesafe", table_file=REVIEWED_TABLE, scope=SCOPE,
                               compiler="0.15"))
if want(89): results.append(compare_control("89-AJ3-soak-on-0.15-no-launch", {}, 1, {"MISSING-LAUNCH": 1}, manifest="",
                               runs=DRAFT_RUNS, run_name="soak-releasesafe", table_file=REVIEWED_TABLE, scope=SCOPE, compiler="0.15"))


def layout_control(tag, with_spec, exp_exit, exp_text, omit=(), tmp_check=False, tamper_fixture=False):
    """AJ2, r23's AL1: install ci/ as 1A.5 does (INSTALL and the run spec, no ci-draft/ beside it, less `omit`) and
    run its own check; every string of exp_text must be in its output."""
    root = os.path.join(logdir, "layout", tag)
    if os.path.exists(root):
        shutil.rmtree(root)
    ci = os.path.join(root, "ci")
    os.makedirs(ci)
    for name in INSTALL:
        if name not in omit:
            shutil.copy(os.path.join(here, name), os.path.join(ci, name))
    if with_spec:   # r30 (round 29's Opus M3): the fixture's run spec and table, never the live ones
        shutil.copy(os.path.join(FIX, "role-runs.tsv"), os.path.join(ci, "role-runs.tsv"))
    if "lock-inventory-threads.tsv" not in omit:   # r26: the reviewed table, which --check-layout requires
        shutil.copy(os.path.join(FIX, "lock-inventory-threads.tsv"), os.path.join(ci, "lock-inventory-threads.tsv"))
    if "fixture" not in omit:   # r28 (round 27's Opus M2): the frozen fixture set, as 1A.5 installs it
        shutil.copytree(FIX, os.path.join(ci, "fixture"))
        if tamper_fixture:   # a reviewed table changed after it was frozen: its digest no longer matches
            with open(os.path.join(ci, "fixture", "lock-inventory-threads.tsv"), "a", encoding="utf-8",
                      newline="\n") as fh_:
                fh_.write("# r28 control: a line added after the freeze\n")
    left = []
    if tmp_check:   # r24 (round 23's Opus L5): run with TEMP pointed at an empty directory, which must stay empty
        tmpd = os.path.join(root, "tmp")
        os.makedirs(tmpd)
        r_ = subprocess.run([py, "-I", os.path.join(ci, "controls.py"), "--check-layout"], capture_output=True,
                            env=dict(os.environ, TEMP=tmpd, TMP=tmpd, TMPDIR=tmpd))
        rc, out = r_.returncode, r_.stdout.decode("utf-8", "replace") + r_.stderr.decode("utf-8", "replace")
        left = os.listdir(tmpd)
        out += f"\n## left in TEMP after the run: {left}"
    else:
        rc, out = run([py, "-I", os.path.join(ci, "controls.py"), "--check-layout"])
    ok = (rc == exp_exit and all(x in out for x in exp_text) and not os.path.exists(os.path.join(root, "ci-draft"))
          and not left)
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## installed: {sorted(os.listdir(ci))}\n## ci/controls.py --check-layout (exit {rc})\n{out}\n")
        fh.write(f"expected: exit {exp_exit}, output containing {exp_text!r}\nCONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: exit {rc}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


if want(90): results.append(layout_control("90-AJ2-installed-ci-layout-finds-its-run-spec", True, 0,
                              (os.path.join("ci", "role-runs.tsv"), os.path.join("ci", "lock-inventory-threads.tsv"),
                               "RESULT PASS", "soak judge as installed: clean exit 0, kill control exit 1",
                               "digests match")))
if want(91): results.append(layout_control("91-AJ2-installed-ci-layout-without-a-run-spec", False, 1, ("no run spec",)))
# -- r22 (round 21): Opus L1, test names compared decoded, and acquiring tests without a string name; AK1, the soak
TBODY = ("        var renderer_mutex: std.Thread.Mutex = .{};\n        var other: TerminalWindow = undefined;\n"
         "        other.core_surface.renderer_state.mutex = &renderer_mutex;\n        renderer_mutex.lock();\n"
         "        renderer_mutex.unlock();\n")
ESCAPED = ("const R22EscA = struct {\n    test \"r22\\x20esc\" {\n" + TBODY + "    }\n};\n\n"
           "const R22EscB = struct {\n    test \"r22 esc\" {\n" + TBODY + "    }\n};")
if want(92): results.append(control("92-L1-escaped-and-plain-spellings-of-one-test-name", overlay("c92", {W32: append(ESCAPED)}),
                       1, {"carriers": 2, "test_sites": 2, "same_name": 1}, 1, {"TEST-UNREVIEWED": 2}))
if want(93): results.append(control("93-L1-an-acquiring-test-without-a-string-name",
                       overlay("c93", {W32: append("const R22Unnamed = struct {\n    test {\n" + TBODY + "    }\n};")}),
                       1, {"carriers": 1, "test_sites": 1, "same_name": 1}, 1, {"TEST-UNREVIEWED": 1}))
judge = os.path.join(here, "soak_judge4.py")
OK_SAMPLES = SOAK_OK


def soak_control(tag, samples, end, exp_kinds, wer="suppressed", crash_files=(), rows=None, crash_dir=True,
                 min_minutes=8, other_class=None):
    """AK1, r23's and r24's Opus findings: a recorded soak run directory, judged by tools\\soak_judge2.py with §3.5's
    rules, the caller's required minimum passed as --min-minutes (none when min_minutes is None)."""
    d = os.path.join(logdir, "soak", tag)
    write_soak_run(d, rows if rows is not None else soak_rows(end, wer), samples, crash_dir, crash_files)
    other = []
    if other_class is not None:   # r25 (Muse L2): the night's other copy, with its own run directory and class
        od = os.path.join(logdir, "soak", tag + "-other")
        write_soak_run(od, [r if r[0] != "class" else ("class", other_class) for r in soak_rows(("quit", 0))],
                       OK_SAMPLES)
        other = ["--other-run", od]
    rc, out = run([py, "-I", judge, d] + ([] if min_minutes is None else ["--min-minutes", str(min_minutes)])
                  + other)
    kinds = {}
    for l in out.splitlines():
        if l.startswith("FAIL "):
            k = l.split(" ", 2)[1]
            kinds[k] = kinds.get(k, 0) + 1
    ok = rc == (1 if exp_kinds else 0) and kinds == exp_kinds
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## soak_judge (exit {rc})\n{out}\nexpected: failures {exp_kinds}\nobserved: exit {rc}, failures {kinds}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: judge exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


GONE = SOAK_GONE
if want(94): results.append(soak_control("94-AK1-a-clean-soak", OK_SAMPLES, ("quit", 0), {}))
if want(95): results.append(soak_control("95-AK1-killed-with-exit-3-at-minute-5", OK_SAMPLES[:5] + GONE, ("early", 3),
                            {"PROCESS-GONE": 3, "EARLY-EXIT": 1, "EXIT-CODE": 1}))
if want(96): results.append(soak_control("96-AK1-restarted-under-a-new-pid", OK_SAMPLES[:5] + [(6, "721", "134070000000000721", "yes")]
                            + OK_SAMPLES[6:], ("quit", 0), {"PROCESS-CHANGED": 1}))
if want(97): results.append(soak_control("97-AK1-a-hung-window", OK_SAMPLES[:3] + [(4, "720", "134070000000000720", "no")]
                            + OK_SAMPLES[4:], ("quit", 0), {"HUNG": 1}))
if want(98): results.append(soak_control("98-AK1-a-minidump-left", OK_SAMPLES, ("quit", 0), {"CRASH-REPORT": 1},
                            crash_files=("noctty-720.dmp",)))
if want(99): results.append(soak_control("99-AK1-WER-not-suppressed", OK_SAMPLES, ("quit", 0), {"WER-NOT-SUPPRESSED": 1},
                            wer="default"))
if want(100): results.append(soak_control("100-AK1-still-running-after-the-quit-bound", OK_SAMPLES, ("stuck", "-"),
                            {"QUIT-TIMEOUT": 1}))
# -- r23 (round 22): AL1, the installed ci/ layout without the soak judge; AL2, test names compared as bytes; Opus L2
# and L1, the soak records' completeness and the copy's mode
if want(101): results.append(layout_control("101-AL1-installed-ci-layout-without-the-soak-judge", True, 1,
                              ("soak_judge4.py missing",), omit=("soak_judge4.py",)))


def two_tests(tag, a, b):
    """Two containers of win32.zig, each with one acquiring test, named a and b as written in the source."""
    return ("const " + tag + "A = struct {\n    test \"" + a + "\" {\n" + TBODY + "    }\n};\n\n"
            "const " + tag + "B = struct {\n    test \"" + b + "\" {\n" + TBODY + "    }\n};")


if want(102): results.append(control("102-AL2-byte-escapes-and-a-literal-character-are-one-name",
                       overlay("c102", {W32: append(two_tests("R23Xl", "r23 caf\\xc3\\xa9", "r23 café"))}),
                       1, {"carriers": 2, "test_sites": 2, "same_name": 1}, 1, {"TEST-UNREVIEWED": 2}))
if want(103): results.append(control("103-AL2-a-unicode-escape-and-byte-escapes-are-one-name",
                       overlay("c103", {W32: append(two_tests("R23Ux", "r23 caf\\u{e9}", "r23 caf\\xc3\\xa9"))}),
                       1, {"carriers": 2, "test_sites": 2, "same_name": 1}, 1, {"TEST-UNREVIEWED": 2}))
if want(104): results.append(control("104-AL2-a-literal-character-and-a-unicode-escape-are-one-name",
                       overlay("c104", {W32: append(two_tests("R23Lu", "r23 café", "r23 caf\\u{e9}"))}),
                       1, {"carriers": 2, "test_sites": 2, "same_name": 1}, 1, {"TEST-UNREVIEWED": 2}))
if want(105): results.append(control("105-AL2-composed-and-decomposed-are-two-names",
                       overlay("c105", {W32: append(two_tests("R23Nf", "r23 café", "r23 cafe\\u{301}"))}),
                       0, {"carriers": 2, "test_sites": 2}, 1, {"TEST-UNREVIEWED": 2}))
if want(106): results.append(control("106-AL2-an-acquiring-test-whose-name-is-not-utf-8",
                       overlay("c106", {W32: append("const R23Lone = struct {\n    test \"r23 caf\\xe9\" {\n" + TBODY
                                                    + "    }\n};")}),
                       1, {"carriers": 1, "test_sites": 1, "same_name": 1}, 1, {"TEST-UNREVIEWED": 1}))
if want(107): results.append(soak_control("107-L2-a-5-of-480-minute-soak-that-quit-cleanly", OK_SAMPLES[:5], ("quit", 0),
                            {"SHORT-RUN": 1}, rows=soak_rows(("quit", 0), planned=480)))
if want(108): results.append(soak_control("108-L2-a-minute-missing", OK_SAMPLES[:3] + OK_SAMPLES[4:], ("quit", 0),
                            {"MISSING-MINUTE": 1}))
if want(109): results.append(soak_control("109-L2-a-minute-recorded-twice", OK_SAMPLES[:4] + OK_SAMPLES[3:], ("quit", 0),
                            {"DUPLICATE-MINUTE": 1}))
if want(110): results.append(soak_control("110-L2-an-early-end-then-a-clean-one", OK_SAMPLES, ("quit", 0), {"DUPLICATE-ROW": 1},
                            rows=soak_rows(("quit", 0))[:-1] + [("end", "early", 3), ("end", "quit", 0)]))
if want(111): results.append(soak_control("111-L2-two-wer-rows", OK_SAMPLES, ("quit", 0), {"DUPLICATE-ROW": 1},
                            rows=soak_rows(("quit", 0)) + [("wer", "default")]))
if want(112): results.append(soak_control("112-L2-no-crash-directory", OK_SAMPLES, ("quit", 0), {"NO-CRASH-DIR": 1},
                            crash_dir=False))
if want(113): results.append(soak_control("113-L2-a-launch-start-time-of-dash", OK_SAMPLES, ("quit", 0), {"MALFORMED": 1},
                            rows=[("launch", "720", "-")] + soak_rows(("quit", 0))[1:]))
if want(114): results.append(soak_control("114-L2-a-sample-with-a-pid-and-no-start-time",
                            OK_SAMPLES[:3] + [(4, "720", "-", "yes")] + OK_SAMPLES[4:], ("quit", 0), {"MALFORMED": 1}))
if want(115): results.append(soak_control("115-L1-no-mode-row", OK_SAMPLES, ("quit", 0), {"MISSING-ROW": 1},
                            rows=[r for r in soak_rows(("quit", 0)) if r[0] != "mode"]))
# r23's own finding (control 105's first run): a report naming a test outside the console's code page crashed the tool;
# the inventory's SAME-NAME line and the gate (116) and the compare's PAIR-OUTSIDE-TABLE line (117) name one now
if want(116): results.append(control("116-r23-a-same-name-outside-the-console-code-page",
                       overlay("c116", {W32: append(two_tests("R23Cj", "r23 \\u{65e5}\\u{672c}", "r23 日本"))}),
                       1, {"carriers": 2, "test_sites": 2, "same_name": 1}, 1, {"TEST-UNREVIEWED": 2}))
if want(117): results.append(compare_control("117-r23-a-pair-outside-the-table-named-outside-the-code-page",
                               xsuite("src/a.zig:test.r23 日本 reader"), 1, {"PAIR-OUTSIDE-TABLE": 1}, manifest="",
                               runs=XRUNS, run_name="xfile", table="src/a.zig:test:r23 日本\tui\n"))
# -- r24 (round 23): Opus L1, names with a control character; L2, the required minimum; L3, the class; L5, the
# temporary directory; the positive control for names compared as bytes
if want(118): results.append(control("118-L1-an-acquiring-test-whose-name-holds-a-tab",
                       overlay("c118", {W32: append("const R24Tab = struct {\n    test \"r24\\ttab\" {\n" + TBODY
                                                    + "    }\n};")}),
                       1, {"carriers": 1, "test_sites": 1, "same_name": 1}, 1, {"TEST-UNREVIEWED": 1}))
if want(119): results.append(control("119-L1-an-acquiring-test-whose-name-holds-a-line-feed",
                       overlay("c119", {W32: append("const R24Lf = struct {\n    test \"r24\\nlf\" {\n" + TBODY
                                                    + "    }\n};")}),
                       1, {"carriers": 1, "test_sites": 1, "same_name": 1}, 1, {"TEST-UNREVIEWED": 1}))
if want(120): results.append(soak_control("120-L2-a-plan-below-the-required-minimum", OK_SAMPLES, ("quit", 0), {"PLAN-TOO-SHORT": 1},
                            min_minutes=480, other_class="noctty-interactive-zig017-0123456789ab-soak-safe"))
if want(121): results.append(soak_control("121-L3-no-class-row", OK_SAMPLES, ("quit", 0), {"MISSING-ROW": 1},
                            rows=[r for r in soak_rows(("quit", 0)) if r[0] != "class"]))
if want(122): results.append(layout_control("122-L5-check-layout-leaves-its-temp-empty", True, 0,
                              ("soak judge as installed: clean exit 0, kill control exit 1",), tmp_check=True))
tbl_pos = os.path.join(logdir, "table-r24-a-reviewed-row-written-decoded.tsv")
open(tbl_pos, "w", encoding="utf-8", newline="\n").write(
    open(table, encoding="utf-8").read().rstrip("\n") + "\n" + W32 + "\t(test)\t@renderer-state.lock:1\tui\ttest\t"
    "a reviewed row for a byte-escaped test name, written decoded (round 23, Opus's positive control)\t"
    "test:r24 café\n")
if want(123): results.append(control("123-a-byte-escaped-name-passes-its-reviewed-decoded-row",
                       overlay("c123", {W32: append("const R24Pos = struct {\n    test \"r24 caf\\xc3\\xa9\" {\n" + TBODY
                                                    + "    }\n};")}),
                       0, {"carriers": 1, "test_sites": 1}, 0, {}, tbl=tbl_pos))
if want(124): results.append(soak_control("124-L2-the-judge-called-without-a-minimum", OK_SAMPLES, ("quit", 0), {"NO-MINIMUM": 1},
                            min_minutes=None))


def reviewed(tag, name):
    """r24 (round 23's Sol M1): the approved table plus one reviewed test row for an acquiring test named `name`."""
    p_ = os.path.join(logdir, "table-" + tag + ".tsv")
    open(p_, "w", encoding="utf-8", newline="\n").write(
        open(table, encoding="utf-8").read().rstrip("\n") + "\n" + W32 + "\t(test)\t@renderer-state.lock:1\tui\ttest\t"
        "a reviewed row for an ordinary test whose name looks like a parser label (round 23, Sol M1)\t"
        "test:" + name + "\n")
    return p_


for n_, slug_, tag_, name_ in ((125, "unnamed-in-parentheses", "R24SentU", "(unnamed)"),
                               (126, "not-utf-8-in-parentheses", "R24SentN", "(not UTF-8)"),
                               (127, "decltest-colon-prefix", "R24SentD", "decltest:r24 reviewer named test"),
                               (128, "with-a-control-character-in-parentheses", "R24SentC",
                                "(with a control character)")):
    if want(n_): results.append(control(f"{n_}-M1-a-test-named-{slug_}-passes-its-row",
                           overlay(f"c{n_}", {W32: append("const " + tag_ + " = struct {\n    test \"" + name_ + "\" {\n"
                                                          + TBODY + "    }\n};")}),
                           0, {"carriers": 1, "test_sites": 1}, 0, {}, tbl=reviewed(f"c{n_}", name_),
                           tests=("named:" + name_,)))
if want(129): results.append(control("129-M1-an-acquiring-decltest",
                       overlay("c129", {W32: append("const R24Decl = struct {\n    fn r24decl() void {}\n\n"
                                                    "    test r24decl {\n" + TBODY + "    }\n};")}),
                       1, {"carriers": 1, "test_sites": 1, "same_name": 1}, 1, {"TEST-UNREVIEWED": 1}))
# -- r25 (round 24): M1, the exact test identity (option (a)) and WHITESPACE-MISMATCH; Muse L1 and Opus L1, the TEST
# kinds out of band and `test @"..."`; Muse L2, the class's shape and two copies' distinct classes


def one_test(tag_, spelled):
    """One container of win32.zig with one acquiring test, its name as written in the source."""
    return "const " + tag_ + " = struct {\n    test \"" + spelled + "\" {\n" + TBODY + "    }\n};"


NBSP = "\u00a0"   # U+00A0, a no-break space
if want(130): results.append(control("130-M1-a-trailing-space-passes-its-exact-row",
                       overlay("c130", {W32: append(one_test("R25Sp", "r25 trailing space "))}),
                       0, {"carriers": 1, "test_sites": 1}, 0, {}, tbl=reviewed("c130", "r25 trailing space "),
                       tests=("named:r25 trailing space ",)))
if want(131): results.append(control("131-M1-a-trailing-no-break-space-passes-its-exact-row",
                       overlay("c131", {W32: append(one_test("R25Nb", "r25 trailing nbsp\\u{a0}"))}),
                       0, {"carriers": 1, "test_sites": 1}, 0, {}, tbl=reviewed("c131", "r25 trailing nbsp" + NBSP),
                       tests=("named:r25 trailing nbsp" + NBSP,)))
if want(132): results.append(control("132-M1-the-trimmed-row-cannot-pass-a-trailing-space",
                       overlay("c132", {W32: append(one_test("R25SpT", "r25 trailing space "))}),
                       0, {"carriers": 1, "test_sites": 1}, 1, {"WHITESPACE-MISMATCH": 1},
                       tbl=reviewed("c132", "r25 trailing space")))
if want(133): results.append(control("133-M1-the-trimmed-row-cannot-pass-a-trailing-no-break-space",
                       overlay("c133", {W32: append(one_test("R25NbT", "r25 trailing nbsp\\u{a0}"))}),
                       0, {"carriers": 1, "test_sites": 1}, 1, {"WHITESPACE-MISMATCH": 1},
                       tbl=reviewed("c133", "r25 trailing nbsp")))
if want(134): results.append(control("134-M1-a-row-with-an-extra-trailing-space",
                       overlay("c134", {W32: append(one_test("R25Pl", "r25 plain"))}),
                       0, {"carriers": 1, "test_sites": 1}, 1, {"WHITESPACE-MISMATCH": 1},
                       tbl=reviewed("c134", "r25 plain ")))
for n_, slug_, tag_, name_ in ((135, "name-with-a-control-character-in-parentheses", "R25LabC",
                                "(name with a control character)"),
                               (136, "unnamed-test-in-parentheses", "R25LabU", "(unnamed test)"),
                               (137, "a-decltest-s-bare-identifier", "R25LabD", "r24decl")):
    if want(n_): results.append(control(f"{n_}-L1-a-test-named-{slug_}-passes-its-row",
                           overlay(f"c{n_}", {W32: append(one_test(tag_, name_))}),
                           0, {"carriers": 1, "test_sites": 1}, 0, {}, tbl=reviewed(f"c{n_}", name_),
                           tests=("named:" + name_,)))
if want(138): results.append(control("138-L1-a-decltest-with-a-test-row-for-its-identifier",
                       overlay("c138", {W32: append("const R25Decl = struct {\n    fn r25decl() void {}\n\n"
                                                    "    test r25decl {\n" + TBODY + "    }\n};")}),
                       1, {"carriers": 1, "test_sites": 1, "same_name": 1}, 1, {"TEST-UNREVIEWED": 1, "STALE-ROW": 1},
                       tbl=reviewed("c138", "r25decl"), tests=("decltest:r25decl",)))
if want(139): results.append(control("139-L1-an-at-quoted-decltest",
                       overlay("c139", {W32: append("const R25AtDecl = struct {\n    fn @\"r25 weird decl\"() void {}\n\n"
                                                    "    test @\"r25 weird decl\" {\n" + TBODY + "    }\n};")}),
                       1, {"carriers": 1, "test_sites": 1, "same_name": 1}, 1, {"TEST-UNREVIEWED": 1},
                       tests=("decltest:@\"r25 weird decl\"",)))
if want(140): results.append(soak_control("140-L2-a-class-not-shaped-as-the-launch-helper-makes-it", OK_SAMPLES, ("quit", 0),
                            {"BAD-CLASS": 1},
                            rows=[r if r[0] != "class" else ("class", "noctty-interactive-soak")
                                  for r in soak_rows(("quit", 0))]))
if want(141): results.append(soak_control("141-L2-two-copies-with-one-class", OK_SAMPLES, ("quit", 0), {"SHARED-CLASS": 1},
                            other_class=SOAK_CLASS))
if want(142): results.append(soak_control("142-L2-two-copies-with-two-classes", OK_SAMPLES, ("quit", 0), {},
                            other_class="noctty-interactive-zig017-0123456789ab-soak-safe"))
# r25's own finding: a production function declared `fn @"..."` that locks a local mutex assigned into a state; r24's
# inventory opened no function there, so it never bound the alias, counted no acquisition, and its gate passed
if want(143): results.append(control("143-r25-an-acquiring-function-declared-with-an-at-quoted-name",
                       overlay("c143", {W32: append("const R25AliasFn = struct {\n    fn @\"r25 weird fn2\"() void {\n"
                                                    + TBODY + "    }\n};")}),
                       1, {"acquisitions": 1, "live": 1, "carriers": 1, "unreviewed": 1}, 1,
                       {"FN-NAME-NOT-IDENTIFIER": 1}))
# -- r26 (round 25): M1, quoted identifiers; Opus L3, the exact test identity at the gate and the compare; Kimi M1, the
# reviewed table read by the compare; Opus L1, NO-OTHER-RUN


def fn_container(tag_, decl):
    """One container of win32.zig holding one acquiring function, declared as written."""
    return "const " + tag_ + " = struct {\n    " + decl + " {\n" + TBODY + "    }\n};"


def table_plus(tag_, rows_):
    """The approved table and extra rows, for one control."""
    p_ = os.path.join(logdir, "table-" + tag_ + ".tsv")
    open(p_, "w", encoding="utf-8", newline="\n").write(
        open(table, encoding="utf-8").read().rstrip("\n") + "\n" + "".join(r_ + "\n" for r_ in rows_))
    return p_


if want(144): results.append(control("144-M1-a-plain-and-a-quoted-declaration-of-one-name",
                       overlay("c144", {W32: append(fn_container("R26PlainA", "fn r26same() void") + "\n\n"
                                                    + fn_container("R26QuotedB", "fn @\"r26same\"() void"))}),
                       1, {"acquisitions": 2, "live": 2, "carriers": 2, "unreviewed": 2}, 1,
                       {"UNREVIEWED": 2}))
if want(145): results.append(control("145-M1-a-plain-and-an-escaped-declaration-of-one-name",
                       overlay("c145", {W32: append(fn_container("R26PlainC", "fn r26same2() void") + "\n\n"
                                                    + fn_container("R26EscD", "fn @\"r26s\\x61me2\"() void"))}),
                       1, {"acquisitions": 2, "live": 2, "carriers": 2, "unreviewed": 2}, 1,
                       {"UNREVIEWED": 2}))
if want(146): results.append(control("146-M1-a-reviewed-function-declared-quoted-passes-its-row",
                       overlay("c146", {TM: replace(
                           "pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {",
                           "pub fn @\"focusGained\"(self: *Termio, td: *ThreadData, focused: bool) !void {")}),
                       0, {}, 0, {}))
V6_ROW = (W32 + "\tr26v6\t\tnever-on-win32\tfork\tnever on Win32: no caller (round 25's V6, a false row)\t"
          "absent:\\br26v6\\b")
V6_FN = "fn r26v6() void {\n" + TBODY.replace("        ", "    ") + "}\n\n"
for n_, slug_, call_ in ((147, "plain", "r26v6();"), (148, "quoted", "@\"r26v6\"();")):
    ov_ = overlay(f"c{n_}", {W32: append(V6_FN + "fn r26v6Caller() void {\n    " + call_ + "\n}")})
    t_ = table_plus(f"c{n_}", [V6_ROW])
    if want(n_): results.append(control(f"{n_}-M1-a-false-never-on-win32-row-with-a-{slug_}-caller", ov_,
                           0, {"acquisitions": 1, "never": 1, "carriers": 1}, 1, {"CHANGED-PATH": 1},
                           tbl=t_, pre=approve_hook(t_, ov_)))
if want(149): results.append(control("149-M1-a-quoted-caller-changes-a-fingerprint", overlay("c149", {TW: append(
    "fn r26ControlCaller(s: *Surface) bool {\n    return s.core_surface.@\"hasSelection\"();\n}")}),
    0, {}, 1, {"CHANGED-FINGERPRINT": 1}))
if want(150): results.append(control("150-M1-a-quoted-name-with-a-space-before-its-parameter-list",
                       overlay("c150", {W32: append(fn_container("R26Spaced", "fn @\"r26spaced\" () void"))}),
                       1, {"acquisitions": 1, "live": 1, "carriers": 1, "unreviewed": 1}, 1, {"UNREVIEWED": 1}))
if want(151): results.append(control("151-L3-a-leading-space-passes-its-exact-row",
                       overlay("c151", {W32: append(one_test("R26Lead", " r26 leading space"))}),
                       0, {"carriers": 1, "test_sites": 1}, 0, {}, tbl=reviewed("c151", " r26 leading space"),
                       tests=("named: r26 leading space",)))
if want(152): results.append(control("152-L3-the-trimmed-row-cannot-pass-a-leading-space",
                       overlay("c152", {W32: append(one_test("R26LeadT", " r26 leading space"))}),
                       0, {"carriers": 1, "test_sites": 1}, 1, {"WHITESPACE-MISMATCH": 1},
                       tbl=reviewed("c152", "r26 leading space")))
for n_, slug_, name_ in ((153, "a-trailing-space", "r26 trailing space "),
                         (154, "a-trailing-no-break-space", "r26 nbsp" + NBSP),
                         (155, "a-leading-space", " r26 leading")):
    if want(n_): results.append(compare_control(f"{n_}-L3-the-compare-keys-a-test-with-{slug_}-exactly",
                                   xsuite("src/a.zig:test." + name_ + " ui"), 0, {}, manifest="", runs=XRUNS,
                                   run_name="xfile", table="src/a.zig:test:" + name_ + "\tui\n"))
if want(156): results.append(compare_control("156-L3-the-compare-refuses-a-trimmed-table-key",
                               xsuite("src/a.zig:test.r26 trailing space  ui"), 1, {"PAIR-OUTSIDE-TABLE": 1},
                               manifest="", runs=XRUNS, run_name="xfile", table="src/a.zig:test:r26 trailing space\tui\n"))
SEVEN = "src/a.zig\t(test)\t@renderer-state.lock:1\tui\ttest\ta test row\ttest:r26 trailing space \n"
if want(157): results.append(compare_control("157-L3-the-seven-column-loader-keeps-a-test-name-exactly",
                               xsuite("src/a.zig:test.r26 trailing space  ui"), 0, {}, manifest="", runs=XRUNS,
                               run_name="xfile", table=SEVEN, scope=SCOPE))
for n_, scope_ in ((158, "1a"), (159, "1b")):
    if want(n_): results.append(compare_control(f"{n_}-KM1-the-debug-suite-on-the-reviewed-table-in-scope-{scope_}",
                                   {"test-exe-810.pairs": SUITE_ALL}, 0, {}, manifest="", runs=DRAFT_RUNS,
                                   run_name="debug-suite", table_file=REVIEWED_TABLE, scope=scope_))
TABLE_ROWS = sum(1 for l_ in open(REVIEWED_TABLE, encoding="utf-8") if l_.strip() and not l_.startswith("#")) \
    if FULL else 0
if want(160): results.append(compare_control("160-KM1-the-reviewed-table-read-without-a-scope",
                               {"test-exe-810.pairs": SUITE_ALL}, 1, {"BAD-TABLE": TABLE_ROWS, "PAIR-OUTSIDE-TABLE": 5},
                               manifest="", runs=DRAFT_RUNS, run_name="debug-suite", table_file=REVIEWED_TABLE))
if want(161): results.append(compare_control("161-KM1-a-two-column-table-read-as-the-reviewed-one",
                               xsuite("src/a.zig:x ui"), 1, {"BAD-TABLE": 1, "PAIR-OUTSIDE-TABLE": 1}, manifest="",
                               runs=XRUNS, run_name="xfile", table="src/a.zig:x\tui\n", scope=SCOPE))
if want(162): results.append(compare_control("162-KM1-a-pair-outside-the-reviewed-table",
                               {"test-exe-810.pairs": SUITE_ALL + "src/Surface.zig:keyCallback renderer\n"}, 1,
                               {"PAIR-OUTSIDE-TABLE": 1}, manifest="", runs=DRAFT_RUNS, run_name="debug-suite",
                               table_file=REVIEWED_TABLE, scope=SCOPE))
if want(163): results.append(layout_control("163-KM1-installed-ci-layout-without-the-reviewed-table", True, 1,
                              ("no reviewed table",), omit=("lock-inventory-threads.tsv",)))
if want(164): results.append(soak_control("164-L1-a-release-coverage-soak-without-the-other-copy",
                            [(m, "720", "134070000000000720", "yes") for m in range(1, 481)], ("quit", 0),
                            {"NO-OTHER-RUN": 1}, rows=soak_rows(("quit", 0), planned=480), min_minutes=480))
# -- r27 (round 26): Sol M1 and M2, one shape in every spelling


W32_LINES = len(show(W32).splitlines())


def added_rows(prefix):
    """The classification of the rows the overlay added to win32.zig: (function, operation, kind, threads, TEST), from
    the sites and the unclassified TSVs; line numbers and text are left out, so spellings compare."""
    out = []
    for suffix in ("-sites.tsv", "-unclassified.tsv"):
        for l_ in open(prefix + suffix, encoding="utf-8"):
            u = l_.rstrip("\n").split("\t")
            if len(u) >= 10 and u[0] == rev and u[1] == W32 and int(u[2]) > W32_LINES:
                out.append((suffix[1:-4], u[3], u[4], u[5], u[6], u[9]))
    return sorted(out)


def spelling_control(tag, code, variants, rows, exp, dump_key, role="ui"):
    """r27 (round 26's Sol M1, M2): run `code` with each variant's DECL and CALL spelling; every variant must give the
    same added-row classification, inventory exit and change, gate exit and kinds, and compare exit and kinds, and
    those must equal `exp` (keys: rows, inv_exit, inv_delta, gate_exit, gate_kinds, cmp_exit, cmp_kinds). Runs in the
    worker pool, as the gate controls do."""
    return POOL.submit(spelling_now, tag, code, variants, rows, exp, dump_key, role)


def spelling_now(tag, code, variants, rows, exp, dump_key, role):
    seen, lines = {}, []
    for vname, decl, call in variants:
        sub = f"{tag[:3]}-{vname}"
        ov = overlay("c" + sub, {W32: append(code.replace("DECL", decl).replace("CALL", call))})
        tbl_ = table_plus(sub, rows)
        prefix = os.path.join(logdir, "inv-" + sub)
        ic, iout = run([py, "-I", inv, repo, prefix, tbl_, f"{rev}={SCOPE}", "--overlay", ov])
        if rows:
            run([py, "-I", gate, "approve", repo, rev, SCOPE, tbl_, prefix, "--overlay", ov])
        gc, gout = run([py, "-I", gate, "check", repo, rev, SCOPE, tbl_, allow, prefix, entries, anchors, "--overlay", ov])
        dd = os.path.join(logdir, "compare", sub)
        if os.path.exists(dd):
            shutil.rmtree(dd)
        os.makedirs(dd)
        if dump_key is None:   # r29: a lock no runtime pair records (a distinct value mutex): no compare
            cc, cout = None, ""
        else:
            open(os.path.join(dd, "child.pairs"), "w", encoding="utf-8", newline="\n").write(
                f"# kind=child pid=1 start=1\n{W32}:{dump_key} {role}\n")
            cc, cout = run([py, "-I", compare, "-", tbl_, dd, "--isolated", "--table-scope", SCOPE])
        s = summary_of(prefix)
        got = dict(rows=added_rows(prefix), inv_exit=ic,
                   inv_delta={k: v for k, v in ((k, s[k] - BASE[k]) for k in s) if v} if s else {"no inventory result": 1},
                   gate_exit=gc, gate_kinds=dict(collections.Counter(
                       l_.split(" ", 2)[1] for l_ in gout.splitlines() if l_.startswith("FAIL "))),
                   cmp_exit=cc, cmp_kinds=dict(collections.Counter(
                       l_.split(" ", 2)[1] for l_ in cout.splitlines() if l_.startswith("FAIL "))))
        seen[vname] = got
        lines.append(f"## {vname}: DECL {decl}, CALL {call}\n{got!r}\n### gate\n{gout}\n### compare\n{cout}\n")
    same = all(v == seen[variants[0][0]] for v in seen.values())
    ok = same and seen[variants[0][0]] == exp
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("".join(lines) + f"expected for every spelling: {exp!r}\none outcome for every spelling: {same}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = (f"{tag}: {len(variants)} spellings, {'one outcome' if same else 'OUTCOMES DIFFER'}; gate exit "
            f"{seen[variants[0][0]]['gate_exit']} {seen[variants[0][0]]['gate_kinds'] or '(no failures)'}, compare exit "
            f"{seen[variants[0][0]]['cmp_exit']} {seen[variants[0][0]]['cmp_kinds'] or '(no failures)'}; "
            f"{'AS EXPECTED' if ok else 'UNEXPECTED'}")
    print(line)
    return ok, line


RELOCK = ('test "r27 relock spelling" {\n    const R27Take = struct {\n        fn DECL(p: *std.Thread.Mutex) void {\n'
          '            p.lock();\n            defer p.unlock();\n        }\n    };\n\n'
          '    var actual: std.Thread.Mutex = .{};\n    var renderer_state: @import("../renderer.zig").State = undefined;\n'
          '    renderer_state.mutex = &actual;\n\n    R27Take.CALL(renderer_state.mutex);\n}')
NESTED = ('test "r27 nested helper" {\n    const R27Sol = struct {\n        fn DECL() void {\n'
          '            var mutex: std.Thread.Mutex = .{};\n'
          '            var renderer_state: @import("../renderer.zig").State = undefined;\n'
          '            renderer_state.mutex = &mutex;\n            mutex.lock();\n            defer mutex.unlock();\n'
          '        }\n    };\n    R27Sol.CALL();\n}')


def spellings(plain, quoted, escaped):
    """Declaration and call spellings: each form for both, and two mixed pairs."""
    return [("plain", plain, plain), ("quoted", quoted, quoted), ("escaped", escaped, escaped),
            ("plain-decl-quoted-call", plain, quoted), ("escaped-decl-plain-call", escaped, plain)]


TAKE = spellings("r27Take", "@\"r27Take\"", "@\"r27T\\x61ke\"")
HELP = spellings("r27helper", "@\"r27helper\"", "@\"r27h\\x65lper\"")
SPACED = [("quoted", "@\"r27 spaced helper\"", "@\"r27 spaced helper\""),
          ("escaped", "@\"r27\\x20spaced helper\"", "@\"r27\\x20spaced helper\""),
          ("quoted-decl-escaped-call", "@\"r27 spaced helper\"", "@\"r27\\x20spaced helper\"")]
SPACED_TAKE = [("quoted", "@\"r27 take\"", "@\"r27 take\""), ("escaped", "@\"r27\\x20take\"", "@\"r27\\x20take\""),
               ("escaped-decl-quoted-call", "@\"r27\\x20take\"", "@\"r27 take\"")]
TEST_ROW = W32 + "\t{fn}\t\tui\ttest\ta reviewed test row (round 26, Sol)\ttest:{test}"
RELOCK_ROWS = [("sites", "r27Take", "lock", "relock", "test", "named:r27 relock spelling")]
# every spelling must give these; r26's tools gave a different outcome per spelling in 165, 166, 168 and 169
EXP_165 = dict(rows=RELOCK_ROWS, inv_exit=0, inv_delta={"carriers": 2, "test_sites": 1}, gate_exit=1,
               gate_kinds={"TEST-UNREVIEWED": 1}, cmp_exit=1, cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})
EXP_166 = dict(rows=RELOCK_ROWS, inv_exit=0, inv_delta={"carriers": 2, "test_sites": 1}, gate_exit=0, gate_kinds={},
               cmp_exit=0, cmp_kinds={})
EXP_167 = dict(rows=[("sites", "r27helper", "lock", "renderer-state", "test", "named:r27 nested helper")], inv_exit=0,
               inv_delta={"carriers": 1, "test_sites": 1}, gate_exit=0, gate_kinds={}, cmp_exit=0, cmp_kinds={})
EXP_168 = dict(rows=[("sites", "@\"r27 spaced helper\"", "lock", "renderer-state", "test", "named:r27 nested helper")],
               inv_exit=0, inv_delta={"carriers": 1, "test_sites": 1}, gate_exit=1,
               gate_kinds={"FN-NAME-NOT-IDENTIFIER": 1}, cmp_exit=1, cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})
EXP_169 = dict(rows=[("sites", "@\"r27 take\"", "lock", "relock", "test", "named:r27 relock spelling")], inv_exit=0,
               inv_delta={"carriers": 2, "test_sites": 1}, gate_exit=1, gate_kinds={"FN-NAME-NOT-IDENTIFIER": 1},
               cmp_exit=1, cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})   # r28: the callee read, so a relock (r27: unclassified)
if want(165): results.append(spelling_control("165-M1-a-relock-through-a-pointer-handoff-in-every-spelling", RELOCK, TAKE, [],
                                EXP_165, "r27Take"))
if want(166): results.append(spelling_control("166-M1-the-same-relock-with-its-reviewed-test-row", RELOCK, TAKE,
                                [TEST_ROW.format(fn="r27Take", test="r27 relock spelling")], EXP_166, "r27Take"))
if want(167): results.append(spelling_control("167-M2-a-test-nested-acquiring-helper-with-its-row", NESTED, HELP,
                                [TEST_ROW.format(fn="r27helper", test="r27 nested helper")], EXP_167, "r27helper"))
if want(168): results.append(spelling_control("168-M2-the-helper-named-with-no-plain-identifier", NESTED, SPACED,
                                [TEST_ROW.format(fn="@\"r27 spaced helper\"", test="r27 nested helper")], EXP_168,
                                "r27 spaced helper"))
if want(169): results.append(spelling_control("169-M1-a-relock-through-a-callee-named-with-no-plain-identifier", RELOCK, SPACED_TAKE,
                                [], EXP_169, "r27 take"))
# -- r28 (round 27): Opus M1, a callee named with a keyword, a primitive or `self`; Sol M1 and the lead's note, a mutex
# parameter and a receiver in every class of name; a spelling no pass can read fails explicitly; Opus M2, the scope,
# the appending mode and the frozen fixture. Each spelling control's first spelling is the one zig fmt keeps (zig fmt
# rewrites the others: logs-r28 names-*.txt); r27's tools gave such a callee, parameter or receiver no row at all.
DEFER = [("quoted", '@"defer"', '@"defer"'), ("escaped", '@"d\\x65fer"', '@"d\\x65fer"'),
         ("quoted-decl-escaped-call", '@"defer"', '@"d\\x65fer"')]
TYPE_ = [("quoted-decl-plain-call", '@"type"', "type"), ("quoted", '@"type"', '@"type"'),
         ("escaped-decl-plain-call", '@"t\\x79pe"', "type"), ("escaped", '@"t\\x79pe"', '@"t\\x79pe"')]
SELF = spellings("self", '@"self"', '@"s\\x65lf"')


def relock_exp(fn_, gate_kinds_):
    return dict(rows=[("sites", fn_, "lock", "relock", "test", "named:r27 relock spelling")], inv_exit=0,
                inv_delta={"carriers": 2, "test_sites": 1}, gate_exit=1, gate_kinds=gate_kinds_, cmp_exit=1,
                cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})


if want(170): results.append(spelling_control("170-OM1-a-relock-through-a-callee-named-with-a-keyword", RELOCK, DEFER, [],
                                relock_exp('@"defer"', {"FN-NAME-NOT-IDENTIFIER": 1}), "defer"))
if want(171): results.append(spelling_control("171-OM1-a-relock-through-a-callee-named-with-a-primitive", RELOCK, TYPE_, [],
                                relock_exp('@"type"', {"FN-NAME-NOT-IDENTIFIER": 1}), "type"))
if want(172): results.append(spelling_control("172-OM1-a-relock-through-a-callee-named-self", RELOCK, SELF, [],
                                relock_exp("self", {"TEST-UNREVIEWED": 1}), "self"))
# the lead's matrix: the callee row is 165 (plain, quoted plain), 170 (keyword), 171 (primitive), 172 (self) and 169
# (spaced, escaped); the parameter and the receiver rows follow, one control per class, every spelling one outcome
PARAM = ('test "r28 parameter spelling" {\n    const R28Param = struct {\n        fn r28Take(DECL: *std.Thread.Mutex) void {\n'
         '            DECL.lock();\n            defer DECL.unlock();\n        }\n    };\n\n'
         '    var actual: std.Thread.Mutex = .{};\n    var renderer_state: @import("../renderer.zig").State = undefined;\n'
         '    renderer_state.mutex = &actual;\n\n    R28Param.r28Take(renderer_state.mutex);\n}')
RECEIVER = ('const R28Recv = struct {\n    fn r28Recv(other: *TerminalWindow) void {\n'
            '        const DECL = other.core_surface.renderer_state.mutex;\n        DECL.lock();\n'
            '        defer DECL.unlock();\n    }\n};')
CLASSES = [("plain", [("plain", "r28m")]),
           ("quoted-plain", [("quoted", '@"r28m"'), ("escaped", '@"r28\\x6d"')]),
           ("keyword", [("quoted", '@"defer"'), ("escaped", '@"d\\x65fer"')]),
           ("primitive", [("quoted", '@"type"'), ("escaped", '@"t\\x79pe"')]),
           ("self", [("plain", "self"), ("quoted", '@"self"')]),
           ("spaced", [("quoted", '@"r28 m"')]),
           ("escaped", [("escaped-space", '@"r28\\x20m"'), ("escaped-tab", '@"r28\\x09m"')])]
PARAM_EXP = dict(rows=[("sites", "r28Take", "lock", "relock", "test", "named:r28 parameter spelling")], inv_exit=0,
                 inv_delta={"carriers": 2, "test_sites": 1}, gate_exit=1, gate_kinds={"TEST-UNREVIEWED": 1},
                 cmp_exit=1, cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})
RECV_EXP = dict(rows=[("sites", "r28Recv", "lock", "renderer-state", "UNREVIEWED", "-")], inv_exit=1,
                inv_delta={"acquisitions": 1, "live": 1, "unreviewed": 1}, gate_exit=1, gate_kinds={"UNREVIEWED": 1},
                cmp_exit=1, cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})
for k_, (cls_, sp_) in enumerate(CLASSES):
    if want(173 + k_): results.append(spelling_control(f"{173 + k_}-LN-a-relock-parameter-named-{cls_}", PARAM,
                                                       [(v_, d_, d_) for v_, d_ in sp_], [], PARAM_EXP, "r28Take"))
for k_, (cls_, sp_) in enumerate(CLASSES):
    if want(180 + k_): results.append(spelling_control(f"{180 + k_}-LN-a-receiver-named-{cls_}", RECEIVER,
                                                       [(v_, d_, d_) for v_, d_ in sp_], [], RECV_EXP, "r28Recv"))


def failclosed_control(tag, code, exp_inv, exp_gate_kinds):
    """r28 (round 27's lead note): a spelling the normalizer cannot read: the inventory exits 2 naming it and writes no
    result, and the gate fails naming it; never a pass on zero rows."""
    return POOL.submit(failclosed_now, tag, code, exp_inv, exp_gate_kinds)


def failclosed_now(tag, code, exp_inv, exp_gate_kinds):
    ov = overlay("c" + tag[:3], {W32: append(code)})
    prefix = os.path.join(logdir, "inv-" + tag)
    ic, iout = run([py, "-I", inv, repo, prefix, table, f"{rev}={SCOPE}", "--overlay", ov])
    gc, gout = run([py, "-I", gate, "check", repo, rev, SCOPE, table, allow, prefix, entries, anchors, "--overlay", ov])
    kinds = dict(collections.Counter(l_.split(" ", 2)[1] for l_ in gout.splitlines() if l_.startswith("FAIL ")))
    no_result = summary_of(prefix) is None
    ok = ic == 2 and exp_inv in iout and no_result and gc == 1 and kinds == exp_gate_kinds
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## inventory (exit {ic}; a result for {rev}: {not no_result})\n{iout}\n## gate (exit {gc})\n{gout}\n"
                 f"expected: inventory exit 2 naming {exp_inv!r} with no result, gate exit 1 {exp_gate_kinds}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = (f"{tag}: inventory exit {ic}{' (no result)' if no_result else ''}; gate exit {gc} {kinds or '(no failures)'}; "
            f"{'AS EXPECTED' if ok else 'UNEXPECTED'}")
    print(line)
    return ok, line


if want(187): results.append(failclosed_control("187-LN-an-at-quote-with-no-closing-quote-fails-explicitly",
                                  'test "r28 unterminated" {\n    var renderer_state: @import("../renderer.zig").State = '
                                  'undefined;\n    @"r28 open.lock();\n}', "UNREADABLE-IDENTIFIER src/apprt/win32.zig:",
                                  {"UNREADABLE-IDENTIFIER": 1}))
if want(188): results.append(failclosed_control("188-LN-source-holding-the-token-prefix-fails-explicitly",
                                  "const __zqi_7232382078_ = struct {};", "QUOTED-TOKEN-COLLISION src/apprt/win32.zig:",
                                  {"QUOTED-TOKEN-COLLISION": 1}))
MERGED_FILE = "src/termio/Termio.zig"


def merged_rows_table(name):
    """r28 (round 27's Opus M2): the fixture's table as a 1A branch holds it: the fork rows of MERGED_FILE re-scoped
    `merged` (functions the merge re-read), and the rows for functions only the merged trees hold (`merged`,
    `merged-1b`) left out, since they hold no site here; then approved at this revision in scope 1a."""
    out_, moved = [], 0
    for l_ in open(table, encoding="utf-8").read().split("\n"):
        f_ = l_.split("\t")
        if len(f_) >= 7 and f_[4] in ("merged", "merged-1b"):
            continue
        if len(f_) >= 7 and f_[4] == "fork" and f_[0] == MERGED_FILE:
            f_[4] = "merged"
            moved += 1
        out_.append("\t".join(f_))
    assert moved == 3, moved
    p_ = os.path.join(logdir, name)
    open(p_, "w", encoding="utf-8", newline="\n").write("\n".join(out_))
    prefix = os.path.join(logdir, "inv-" + name[:-4])
    run([py, "-I", inv, repo, prefix, p_, f"{rev}=1a"])
    rc, out = run([py, "-I", gate, "approve", repo, rev, "1a", p_, prefix])
    return p_, f"{moved} rows of {MERGED_FILE} re-scoped merged; approved in scope 1a (exit {rc}): {out.strip()}"


def appending_control(tag, scope_, exp_exit, exp_text):
    """r28 (round 27's Opus M2): this file's --appending mode, as CI runs it on a 1A branch, on the table with merged
    rows: in scope 1a control 00 and every appending control pass; in scope fork (r27's only scope) control 00 fails."""
    return POOL.submit(appending_now, tag, scope_, exp_exit, exp_text)


def appending_now(tag, scope_, exp_exit, exp_text):
    tbl_, note = merged_rows_table("table-" + tag[:3] + "-merged-rows.tsv")
    sub = os.path.join(logdir, "appending", tag)
    if os.path.exists(sub):
        shutil.rmtree(sub)
    import time
    t0_ = time.monotonic()
    rc, out = run([py, "-I", os.path.abspath(__file__), "--appending", "--scope", scope_, repo, rev, tbl_, allow,
                   entries, anchors, sub])
    secs = round(time.monotonic() - t0_)
    tail = (out.strip().splitlines()[-1] if out.strip() else "(no output)") + f" in {secs} s beside the other controls"
    ok = rc == exp_exit and all(x in out for x in exp_text)
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## the table: {note}\n## controls.py --appending --scope {scope_} (exit {rc})\n{out}\n"
                 f"expected: exit {exp_exit}, output holding {exp_text!r}\nCONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: --appending --scope {scope_} exit {rc}, {tail}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


if want(189): results.append(appending_control("189-OM2-the-appending-mode-in-scope-1a-on-a-table-with-merged-rows", "1a", 0,
                                 (f"{1 + len(APPENDING)} of {1 + len(APPENDING)} as expected",)))
if want(190): results.append(appending_control("190-OM2-the-same-in-scope-fork-fails-at-control-00", "fork", 1,
                                 ("no appending control ran", "0 of 1 as expected")))
if want(191): results.append(layout_control("191-OM2-installed-ci-layout-without-the-fixture", True, 1, ("no fixture",),
                              omit=("fixture",)))
if want(192): results.append(layout_control("192-OM2-installed-ci-layout-whose-fixture-table-changed", True, 1,
                              ("fixture digest mismatch",), tamper_fixture=True))
# the lead's note, beyond quoted names: a lock call whose receiver the site pass cannot name fails explicitly too (r27
# skipped it silently); none occurs in any of the seven trees
if want(193): results.append(failclosed_control("193-LN-a-lock-call-on-an-expression-fails-explicitly",
                                  'test "r28 receiver expression" {\n    var ms: [1]std.Thread.Mutex = .{.{}};\n'
                                  '    ms[0].lock();\n    defer ms[0].unlock();\n}',
                                  "UNREADABLE-RECEIVER src/apprt/win32.zig:", {"UNREADABLE-RECEIVER": 1}))
# -- r29 (round 28): Sol M1, Opus M1 and the lead's note, every lock-op token classified or refused; each receiver shape
# at the inventory, the gate and the compare (r28's tools gave every one of 195 to 204 no row and a passing gate);
# Opus M2, the anchors as data; Sol M2, §7.8's 0.15 residue checks


def shape_control(tag, code, exp, dump_key):
    """r29: one receiver shape as written, at the inventory, the gate and the compare (spelling_now, one spelling)."""
    return spelling_control(tag, code, [("as-written", "", "")], [], exp, dump_key)


def prod_fn(name, body):
    return "const " + name.upper() + " = struct {\n    fn " + name + "(other: *TerminalWindow) void {\n" + body + "    }\n};"


RS = "other.core_surface.renderer_state"


def prod_exp(name, op="lock", kind="renderer-state"):
    return dict(rows=[("sites", name, op, kind, "UNREVIEWED", "-")], inv_exit=1,
                inv_delta={"acquisitions": 1, "live": 1, "unreviewed": 1}, gate_exit=1, gate_kinds={"UNREVIEWED": 1},
                cmp_exit=1, cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})


def demand_caller_exp(exp):
    # An overlay adds a caller to the 1A/P6 forwarder when that reviewed row is present.
    with open(table, encoding="utf-8") as rows:
        reviewed = any(row.startswith("src/renderer/State.zig\tlockDemand\t")
                       and row.split("\t")[4] == "merged" for row in rows)
    if reviewed and SCOPE in ("1a", "1b"):
        exp = dict(exp, gate_kinds=dict(exp["gate_kinds"], **{"CHANGED-FINGERPRINT": 1}))
    return exp


def test_exp(fn, test, kind="renderer-state", delta=None):
    return dict(rows=[("sites", fn, "lock", kind, "test", "named:" + test)], inv_exit=0,
                inv_delta=delta or {"carriers": 1, "test_sites": 1}, gate_exit=1, gate_kinds={"TEST-UNREVIEWED": 1},
                cmp_exit=1, cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})


TEST_HEAD = ("    var actual: std.Thread.Mutex = .{};\n    var renderer_state: @import(\"../renderer.zig\").State = undefined;\n"
             "    renderer_state.mutex = &actual;\n")
# r32 (round 31's lead direction): a receiver that ends the line before is read through the token stream (r28 to r31
# refused it, UNREADABLE-RECEIVER, reading one line at a time); the renderer mutex's lock so split is a test site
if want(194): results.append(shape_control("194-LN-r32-a-lock-call-whose-receiver-ends-the-line-before-is-read",
    "test \"r28 receiver on the line before\" {\n" + TEST_HEAD + "    renderer_state.mutex\n        .lock();\n"
    "    defer renderer_state.mutex.unlock();\n}", test_exp("(test)", "r28 receiver on the line before"),
    "test.r28 receiver on the line before"))
if want(195): results.append(shape_control("195-SM1-a-dereferenced-receiver-in-production", prod_fn(
    "r29a", "        " + RS + ".mutex.*.lock();\n        defer " + RS + ".mutex.unlock();\n"), prod_exp("r29a"), "r29a"))
if want(196): results.append(shape_control("196-SM1-a-dereferenced-receiver-in-a-test",
    "test \"r29 deref receiver\" {\n" + TEST_HEAD + "    renderer_state.mutex.*.lock();\n"
    "    defer renderer_state.mutex.unlock();\n}", test_exp("(test)", "r29 deref receiver"), "test.r29 deref receiver"))
if want(197): results.append(shape_control("197-OM1-a-local-then-its-dereference", prod_fn(
    "r29a2", "        const m = " + RS + ".mutex;\n        m.*.lock();\n        defer m.unlock();\n"), prod_exp("r29a2"),
    "r29a2"))
if want(198): results.append(shape_control("198-OM1-an-optional-relock-parameter-unwrapped-in-a-test",
    "test \"r29 optional relock\" {\n    const R29B = struct {\n        fn r29b(p: ?*std.Thread.Mutex) void {\n"
    "            p.?.lock();\n            defer p.?.unlock();\n        }\n    };\n\n" + TEST_HEAD
    + "\n    R29B.r29b(renderer_state.mutex);\n}",
    test_exp("r29b", "r29 optional relock", "relock", {"carriers": 2, "test_sites": 1}), "r29b"))
if want(199): results.append(shape_control("199-OM1-an-optional-local-unwrapped-in-production", prod_fn(
    "r29b2", "        const m: ?*std.Thread.Mutex = " + RS + ".mutex;\n        m.?.lock();\n        defer m.?.unlock();\n"),
    prod_exp("r29b2"), "r29b2"))
if want(200): results.append(shape_control("200-OM1-a-type-alias-called-as-a-function",
    "const R29D = struct {\n    const R29M = std.Thread.Mutex;\n    fn r29d(other: *TerminalWindow) void {\n"
    "        R29M.lock(" + RS + ".mutex);\n        defer R29M.unlock(" + RS + ".mutex);\n    }\n};", prod_exp("r29d"),
    "r29d"))
if want(201): results.append(shape_control("201-OM1-a-lock-op-called-through-at-call", prod_fn(
    "r29g", "        @call(.auto, std.Thread.Mutex.lock, .{" + RS + ".mutex});\n        defer " + RS + ".mutex.unlock();\n"),
    prod_exp("r29g"), "r29g"))
if want(202): results.append(shape_control("202-OM1-a-handle-bound-by-address-then-lockdemand", prod_fn(
    "r29e", "        const st = &" + RS + ";\n        st.lockDemand();\n        defer st.unlockDemand();\n"),
    demand_caller_exp(prod_exp("r29e", "lockDemand", "demand")), "r29e"))
if want(203): results.append(shape_control("203-OM1-a-handle-bound-by-address-then-its-mutex", prod_fn(
    "r29f", "        const st = &" + RS + ";\n        st.mutex.lock();\n        defer st.mutex.unlock();\n"),
    prod_exp("r29f"), "r29f"))
if want(204): results.append(shape_control("204-OM1-the-mutex-type-s-lock-called-on-the-renderer-mutex-in-a-test",
    "test \"r29 type-called lock\" {\n" + TEST_HEAD + "    std.Thread.Mutex.lock(renderer_state.mutex);\n"
    "    defer renderer_state.mutex.unlock();\n}", test_exp("(test)", "r29 type-called lock"), "test.r29 type-called lock"))
if want(205): results.append(failclosed_control("205-SM1-a-parenthesised-receiver-fails-explicitly", prod_fn(
    "r29p", "        (" + RS + ".mutex).lock();\n        defer " + RS + ".mutex.unlock();\n"),
    "UNREADABLE-RECEIVER src/apprt/win32.zig:", {"UNREADABLE-RECEIVER": 1}))
if want(206): results.append(failclosed_control("206-SM1-a-field-builtin-receiver-fails-explicitly", prod_fn(
    "r29q", "        @field(" + RS + ", \"mutex\").lock();\n        defer " + RS + ".mutex.unlock();\n"),
    "UNREADABLE-RECEIVER src/apprt/win32.zig:", {"UNREADABLE-RECEIVER": 1}))
UNC = dict(inv_exit=0, inv_delta={"unclassified": 1}, gate_exit=1, gate_kinds={"UNCLASSIFIED-NOT-ALLOWED": 1}, cmp_exit=1,
           cmp_kinds={"PAIR-OUTSIDE-TABLE": 1})
if want(207): results.append(shape_control("207-OM1-lockdemand-on-an-unknown-receiver-is-unclassified",
    "const R29U = struct {\n    fn r29u(w: anytype) void {\n        w.lockDemand();\n        defer w.unlockDemand();\n    }\n};",
    demand_caller_exp(dict(UNC, rows=[("unclassified", "r29u", "lockDemand", "UNCLASSIFIED", "UNREVIEWED", "-")])),
    "r29u"))
if want(208): results.append(shape_control("208-OM1-a-mutex-name-on-an-unresolved-receiver-is-not-distinct",
    "const R29X = struct {\n    fn r29x(x: anytype) void {\n        x.mutex.lock();\n        defer x.mutex.unlock();\n    }\n};",
    dict(UNC, rows=[("unclassified", "r29x", "lock", "UNCLASSIFIED", "UNREVIEWED", "-")]), "r29x"))
if want(209): results.append(shape_control("209-OM1-the-same-in-test-code-needs-an-allow-list-entry",
    "test \"r29 unresolved value receiver\" {\n    const R29Y = struct {\n        fn r29y(x: anytype) void {\n"
    "            x.mutex.lock();\n            defer x.mutex.unlock();\n        }\n    };\n    _ = R29Y;\n}",
    dict(UNC, inv_delta={}, rows=[("unclassified", "r29y", "lock", "UNCLASSIFIED", "test",
                                    "named:r29 unresolved value receiver")]), "r29y"))
if want(210): results.append(shape_control("210-OM1-a-value-mutex-resolved-by-its-declaration-is-distinct",
    "const R29V = struct {\n    fn r29v() void {\n        var m: std.Thread.Mutex = .{};\n        m.lock();\n"
    "        defer m.unlock();\n    }\n};",
    dict(rows=[], inv_exit=0, inv_delta={}, gate_exit=0, gate_kinds={}, cmp_exit=None, cmp_kinds={}), None))
# -- r30 (round 29's lead direction): default-deny. Each shape below passed r29's tools (logs-r30\precheck30.txt): it
# must come out a renderer-state site or UNCLASSIFIED, never "other" or "distinct"
if want(217): results.append(shape_control("217-SM1-a-local-alias-of-a-local-alias", prod_fn(
    "r30a", "        const first = " + RS + ".mutex;\n        const second = first;\n        second.lock();\n"
    "        defer second.unlock();\n"), prod_exp("r30a"), "r30a"))
if want(218): results.append(shape_control("218-SM1-the-same-in-the-0.17-spelling", prod_fn(
    "r30a2", "        const first = " + RS + ".mutex;\n        const second = first;\n        second.lockUncancelable(io);\n"
    "        defer second.unlock(io);\n"), prod_exp("r30a2", "lockUncancelable"), "r30a2"))
if want(219): results.append(shape_control("219-SM1-a-type-alias-of-a-type-alias-called-as-a-function",
    "const R30C = struct {\n    const First = std.Thread.Mutex;\n    const Second = First;\n"
    "    fn r30c(other: *TerminalWindow) void {\n        Second.lock(" + RS + ".mutex);\n"
    "        defer Second.unlock(" + RS + ".mutex);\n    }\n};", prod_exp("r30c"), "r30c"))
if want(220): results.append(shape_control("220-SM1-the-same-in-the-0.17-spelling",
    "const R30C2 = struct {\n    const First = std.Io.Mutex;\n    const Second = First;\n"
    "    fn r30c2(other: *TerminalWindow) void {\n        Second.lockUncancelable(" + RS + ".mutex, io);\n"
    "        defer Second.unlock(" + RS + ".mutex, io);\n    }\n};", prod_exp("r30c2", "lockUncancelable"), "r30c2"))
UNC30 = dict(UNC, inv_delta={"unclassified": 1})
if want(221): results.append(shape_control("221-SM2-a-factory-returning-another-type-s-pointer-is-not-distinct",
    "const R30F = struct {\n    const SolFactory = struct {\n        mutex: std.Thread.Mutex = .{},\n"
    "        fn get(other: *TerminalWindow) *renderer.State {\n            return &other.core_surface.renderer_state;\n"
    "        }\n    };\n    fn r30f(other: *TerminalWindow) void {\n        const st = SolFactory.get(other);\n"
    "        st.mutex.lock();\n        defer st.mutex.unlock();\n    }\n};",
    dict(UNC30, rows=[("unclassified", "r30f", "lock", "UNCLASSIFIED", "UNREVIEWED", "-")]), "r30f"))
if want(222): results.append(shape_control("222-LD-a-receiver-that-resolves-to-nothing-is-unclassified", prod_fn(
    "r30u", "        const m = blk: {\n            break :blk " + RS + ".mutex;\n        };\n        m.lock();\n"
    "        defer m.unlock();\n"), dict(UNC30, rows=[("unclassified", "r30u", "lock", "UNCLASSIFIED", "UNREVIEWED", "-")]),
    "r30u"))
if want(223): results.append(shape_control("223-OM1-an-anytype-helper-is-a-carrier-and-its-lock-unclassified",
    "const R30H = struct {\n    fn r30h(x: anytype) void {\n        x.lock();\n        defer x.unlock();\n    }\n"
    "    fn r30hCall(other: *TerminalWindow) void {\n        r30h(" + RS + ".mutex);\n    }\n};",
    dict(UNC30, inv_delta={"unclassified": 1, "carriers": 1},
         rows=[("unclassified", "r30h", "lock", "UNCLASSIFIED", "UNREVIEWED", "-")]), "r30h"))
if want(224): results.append(shape_control("224-OM1-a-generic-helper-is-a-carrier-and-its-lock-unclassified",
    "const R30K = struct {\n    fn r30k(comptime T: type, x: *T) void {\n        x.lock();\n        defer x.unlock();\n    }\n"
    "    fn r30kCall(other: *TerminalWindow) void {\n        r30k(std.Thread.Mutex, " + RS + ".mutex);\n    }\n};",
    dict(UNC30, inv_delta={"unclassified": 1, "carriers": 1},
         rows=[("unclassified", "r30k", "lock", "UNCLASSIFIED", "UNREVIEWED", "-")]), "r30k"))
if want(225): results.append(shape_control("225-OM1-a-getter-s-pointer-is-unclassified",
    "const R30G = struct {\n    fn r30get(other: *TerminalWindow) *std.Thread.Mutex {\n        return " + RS + ".mutex;\n"
    "    }\n    fn r30g(other: *TerminalWindow) void {\n        const m = r30get(other);\n        m.lock();\n"
    "        defer m.unlock();\n    }\n};",
    dict(UNC30, rows=[("unclassified", "r30g", "lock", "UNCLASSIFIED", "UNREVIEWED", "-")]), "r30g"))
if want(226): results.append(shape_control("226-OM1-the-address-of-a-dereference-is-an-alias", prod_fn(
    "r30d", "        const m = &" + RS + ".mutex.*;\n        m.lock();\n        defer m.unlock();\n"), prod_exp("r30d"),
    "r30d"))
if want(227): results.append(shape_control("227-OM1-std-named-by-its-import",
    "const R30M = struct {\n    const M = @import(\"std\").Thread.Mutex;\n    fn r30m(other: *TerminalWindow) void {\n"
    "        M.lock(" + RS + ".mutex);\n        defer M.unlock(" + RS + ".mutex);\n    }\n};", prod_exp("r30m"), "r30m"))
if want(228): results.append(shape_control("228-OM1-an-alias-of-an-alias-of-an-alias", prod_fn(
    "r30b", "        const a = " + RS + ".mutex;\n        const b = a;\n        const c = b;\n        c.lock();\n"
    "        defer c.unlock();\n"), prod_exp("r30b"), "r30b"))
if want(229): results.append(shape_control("229-OM1-an-if-expression-is-unclassified", prod_fn(
    "r30i", "        const m = if (other.r30_flag) " + RS + ".mutex else &other.r30_alt;\n        m.lock();\n"
    "        defer m.unlock();\n"), dict(UNC30, rows=[("unclassified", "r30i", "lock", "UNCLASSIFIED", "UNREVIEWED", "-")]),
    "r30i"))
if want(230): results.append(failclosed_control("230-OM1-an-op-named-as-a-string-fails-explicitly", prod_fn(
    "r30s", "        @field(std.Thread.Mutex, \"lock\")(" + RS + ".mutex);\n        defer " + RS + ".mutex.unlock();\n"),
    "UNREADABLE-RECEIVER src/apprt/win32.zig:", {"UNREADABLE-RECEIVER": 1}))
if want(231): results.append(control("231-LD-an-allowed-function-s-new-receiver-is-not-allowed", overlay("c231", {
    "src/App.zig": replace("        mailbox.mutex.lock();\n        defer mailbox.mutex.unlock();\n        return mailbox.len != 0;\n",
                           "        mailbox.mutex.lock();\n        defer mailbox.mutex.unlock();\n"
                           "        self.r30_spare.mutex.lock();\n        defer self.r30_spare.mutex.unlock();\n"
                           "        return mailbox.len != 0;\n")}), 0, {"unclassified": 1}, 1, {"UNCLASSIFIED-NOT-ALLOWED": 1}))


def allow_bad_control(tag):
    """r30: an allow-list row without a receiver fails the gate (BAD-ALLOW), before any check."""
    bad = os.path.join(logdir, "allow-bad.txt")
    open(bad, "w", encoding="utf-8", newline="\n").write("# r30 control\nsrc/App.zig\tneedsModalWake\tr29's three columns\n")
    rc, out = run([py, "-I", gate, "check", repo, rev, SCOPE, table, bad, os.path.join(logdir, "inv-00-base"), entries,
                   anchors])
    ok = rc != 0 and "BAD-ALLOW" in out and "RESULT PASS" not in out
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## gate with a three-column allow-list (exit {rc})\n{out}\nexpected: a failing exit naming BAD-ALLOW\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: gate exit {rc}, {'BAD-ALLOW' if 'BAD-ALLOW' in out else 'no BAD-ALLOW'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


if want(232): results.append(allow_bad_control("232-LD-an-allow-list-row-without-a-receiver-fails-the-gate"))
if FULL:   # r30 (round 29's Opus L2): an anchor proved by a chain, and the same chain once `run` stops calling the hop
    _anch_chain = os.path.join(logdir, "thread-anchors-chain.tsv")
    _src_anch_ = open(anchors, encoding="utf-8").read()
    _old_ui_ = "ui\tsrc/apprt/win32/app.zig\trun\tsrc/apprt/win32/app.zig:run:DispatchMessageW"
    assert _src_anch_.count(_old_ui_) == 1
    open(_anch_chain, "w", encoding="utf-8", newline="\n").write(_src_anch_.replace(_old_ui_, (
        "ui\tsrc/apprt/win32/app.zig\trun\tsrc/apprt/win32/app.zig:run:routeLoopMessage=>"
        "src/apprt/win32/app.zig:routeLoopMessage:DispatchMessageW")))
    _ROUTE = "fn routeLoopMessage(msg: *MSG) void {\n    _ = sys.DispatchMessageW(msg);\n}"

    def _route(new_line):
        f_ = lambda t_: append(_ROUTE)(replace("            _ = sys.DispatchMessageW(&msg);\n", new_line)(t_))
        f_.kind = "replace"
        return f_
    if want(233): results.append(control("233-OL2-an-anchor-proved-by-a-chain-passes", overlay("c233", {
        "src/apprt/win32/app.zig": _route("            _ = routeLoopMessage(&msg);\n")}), 0, {}, 0, {}, anch=_anch_chain))
    if want(234): results.append(control("234-OL2-the-chain-fails-once-run-stops-calling-routeloopmessage", overlay("c234", {
        "src/apprt/win32/app.zig": _route("            _ = &msg;\n")}), 0, {}, 1, {"ANCHOR-MOVED": 1}, anch=_anch_chain))
if FULL:   # r29 (round 28's Opus M2): the anchors as data: a moved anchor fails at the fixture; a malformed file fails
    _anch_head = os.path.join(logdir, "thread-anchors-head.tsv")
    _src_anch = open(anchors, encoding="utf-8").read()
    _old_ui = "ui\tsrc/apprt/win32/app.zig\trun\tsrc/apprt/win32/app.zig:run:DispatchMessageW"
    assert _src_anch.count(_old_ui) == 1
    _chain_ui = ("ui\tsrc/apprt/win32/app.zig\trun\tsrc/apprt/win32/app.zig:run:routeLoopMessage=>"
                 "src/apprt/win32/app.zig:routeLoopMessage:DispatchMessageW")   # r30 (round 29's Opus L2): a chain
    open(_anch_head, "w", encoding="utf-8", newline="\n").write(_src_anch.replace(_old_ui, _chain_ui))
    if want(211): results.append(control("211-OM2-the-anchors-reviewed-for-main-s-head-fail-at-the-fixture", None, 0, {}, 1,
                                          {"ANCHOR-MOVED": 1}, anch=_anch_head))


def anchors_bad_control(tag):
    """r29 (round 28's Opus M2): a malformed anchors file fails the gate, naming it (BAD-ANCHORS), before any check."""
    bad = os.path.join(logdir, "thread-anchors-bad.tsv")
    open(bad, "w", encoding="utf-8", newline="\n").write("thread\tfile\tfunction\tproof\nui\tsrc/apprt/win32/app.zig\trun\n")
    rc, out = run([py, "-I", gate, "check", repo, rev, SCOPE, table, allow, os.path.join(logdir, "inv-00-base"), entries,
                   bad])
    ok = rc != 0 and "BAD-ANCHORS" in out and "RESULT PASS" not in out
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## gate with a malformed anchors file (exit {rc})\n{out}\nexpected: a failing exit naming BAD-ANCHORS\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: gate exit {rc}, {'BAD-ANCHORS' if 'BAD-ANCHORS' in out else 'no BAD-ANCHORS'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


if want(212): results.append(anchors_bad_control("212-OM2-a-malformed-anchors-file-fails-the-gate"))


_RESIDUE_BASES = {}


def residue_base(tree):
    """r30 (round 29's Opus M2): the real tree, extracted once per run from the repository (git archive; nothing is
    written to it), which each residue control links into its own checkout."""
    if tree not in _RESIDUE_BASES:
        import io as io_
        import tarfile
        d = os.path.join(logdir, "residue", "_base-" + tree.replace(".", "_"))
        if os.path.exists(d):
            shutil.rmtree(d)
        os.makedirs(d)
        data = subprocess.run(["git", "-C", repo, "archive", "--format=tar", tree], capture_output=True, check=True).stdout
        with tarfile.open(fileobj=io_.BytesIO(data)) as tf:
            tf.extractall(d, filter="data")
        _RESIDUE_BASES[tree] = d
    return _RESIDUE_BASES[tree]


def link_tree(src_, dst):
    """Each file hard-linked where the volume allows (a mutation removes a file before it writes one), else copied."""
    def cp(a, b):
        try:
            os.link(a, b)
        except OSError:
            shutil.copy2(a, b)
    shutil.copytree(src_, dst, copy_function=cp)


def residue_control(tag, mutate, exp_exit, exp_kinds, tree="v1.4.0", exp_text=(), extra=(), check=None, astdump=None,
                    v140_extra=True, v140_drop=()):
    """r29 (round 28's Sol M2), r30 (round 29's Opus M2, M3, L1, L4), r31 to r45: §7.8's residue checks (residue_gate17.py) on the
    real tree (v1.4.0, the tree 1B holds; or the fork head) with this file's INSTALL bundle, the frozen fixture, the
    fixture's own copy of the allowance (Opus M3: never the live one) and the run spec as 1B.3 leaves it (the
    fixture's, without its 0.15 rows) in ci/; `mutate` restores one 0.15 selection or shim, or nothing. r41: on the
    v1.4.0 tree the bundle's own lines (V140_EXTRA) are expected but, with `v140_extra` "text" (a tree pinned below
    0.17, whose Zig files the gate does not read), only those the text checks give, and none that holds a text of
    `v140_drop` (a row the control satisfies)."""
    root = os.path.join(logdir, "residue", tag)
    if os.path.exists(root):
        shutil.rmtree(root)
    link_tree(residue_base(tree), root)
    if tree in ("trial-hybrid-140", "trial-ours-140"):   # r40 (round 39's Opus L1): the 1B proxies keep the fork's
        # minimum_zig_version and the gate reads a tree only through its pinned compiler's parse; 1B.3 sets the merged
        # tree's (§12), so each proxy is read as 1B.3 leaves it, through the 1B compiler's astdump
        zon_, pin_ = os.path.join(root, "build.zig.zon"), '.minimum_zig_version = "0.15.2"'
        text_ = open(zon_, encoding="utf-8").read()
        assert text_.count(pin_) == 1, tree
        os.remove(zon_)
        open(zon_, "w", encoding="utf-8", newline="\n").write(text_.replace(pin_, '.minimum_zig_version = "0.17.0"'))
    ci = os.path.join(root, "ci")
    os.makedirs(ci, exist_ok=True)
    for name in INSTALL:
        shutil.copy(os.path.join(here, name), os.path.join(ci, name))
    shutil.copytree(FIX, os.path.join(ci, "fixture"))
    shutil.copy(os.path.join(FIX, "residue-allow.tsv"), os.path.join(ci, "residue-allow.tsv"))
    spec_ = [l for l in open(os.path.join(FIX, "role-runs.tsv"), encoding="utf-8") if not re.search(r"0\.15", l)]
    open(os.path.join(ci, "role-runs.tsv"), "w", encoding="utf-8", newline="\n").write("".join(spec_))
    if mutate:
        mutate(root)
    exe_ = astdump if astdump is not None else ASTDUMP.get("1a" if tree == rev else "1b")   # r39: the tree's compiler's
    work_ = os.path.join(logdir, "residue-ast", tag)
    rc, out = run([py, "-I", os.path.join(here, "residue_gate17.py"), root, os.path.join(ci, "residue-allow.tsv")]
                  + (["--astdump", exe_] if exe_ else []) + ["--work", work_] + list(extra))
    v140_ = (tree == "v1.4.0" and exp_kinds is not None and v140_extra and "BAD-ALLOWANCE" not in exp_text
             and "BAD-SETUP" not in exp_text)
    if v140_:   # r35 (the user's option 1),
        # r36: the fork's three rows, stale on v1.4.0 alone (an allowance the gate refuses to read reports nothing else); a
        # stale row fails the run, so an expected pass becomes exit 1 with those failures, but for --report-only (exit 0)
        exp_kinds = dict(exp_kinds)
        zig_ = ("UNRESOLVED-ORIGIN", "DERIVED-SHIM", "PRODUCTION-SHIM", "UNRESOLVED-DESTRUCTURING", "UNPARSEABLE",
                "AST-TILING", "AST-TOKENS", "AST-ROLES")   # r41: the lines only the Zig files give, and their rows' stale lines
        keep_ = [(k_, x_) for k_, x_ in V140_EXTRA if not any(d_ in x_ for d_ in v140_drop)
                 and (v140_extra is True or not (k_ in zig_ or "unresolved origins" in x_ or "feature tests" in x_
                                                 or "zig_version" in x_))]
        for kind_, text_ in keep_:   # r37: the fork's stale rows, and upstream's GTK runtime
            exp_kinds[kind_] = exp_kinds.get(kind_, 0) + 1
        exp_text = tuple(exp_text) + tuple(text_ for _, text_ in keep_)
        if exp_exit == 0 and "--report-only" not in extra:
            exp_exit = 1
    kinds = dict(collections.Counter(l_.split(" ", 2)[1] for l_ in out.splitlines() if l_.startswith(("FAIL ", "REPORT "))))
    ok = rc == exp_exit and (kinds == exp_kinds if check is None else check(kinds, out)) and all(x in out for x in exp_text)
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## residue_gate.py (exit {rc})\n{out}\nexpected: exit {exp_exit}, failures {exp_kinds}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: residue gate exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


def write_into(rel, text, mode="w"):
    """Write (or append to) a file of a linked checkout: the link is removed first, so the shared base stays as read."""
    def f(root):
        p = os.path.join(root, *rel.split("/"))
        old = open(p, encoding="utf-8").read() if mode == "a" and os.path.exists(p) else ""
        if os.path.exists(p):
            os.remove(p)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w", encoding="utf-8", newline="\n").write(old + text)
    return f


def edit_into(rel, old, new):
    def f(root):
        p = os.path.join(root, *rel.split("/"))
        text = open(p, encoding="utf-8").read()
        assert text.count(old) == 1, (rel, old)
        os.remove(p)
        open(p, "w", encoding="utf-8", newline="\n").write(text.replace(old, new))
    return f


def write_bytes_into(rel, data):
    """r42: write raw bytes into a linked checkout (a text that is no UTF-8), the link removed first."""
    def f(root):
        p = os.path.join(root, *rel.split("/"))
        if os.path.exists(p):
            os.remove(p)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(data)
    return f


V140_ZON = '.minimum_zig_version = "0.17.0",'
# r35 (the user's option 1), r36: the allowance's rows for fork code v1.4.0 does not have, which the merged 1B tree
# keeps (Key's derived-tests in src/config/Config.zig; r36's measured derived-tests in win32_settings_fields.zig and
# unresolved-origin in win32/facade_budget.zig); on the v1.4.0 tree alone they are these three stale rows
KEY_STALE = "STALE-ALLOWANCE src/config/Config.zig: allows 4 feature tests on a type derived from std, the file holds 0"
# r37 to r45: on the v1.4.0 tree alone, every fork row of the allowance is stale, and upstream's GTK runtime and Metal
# renderer, which 1B removes and no row names, fail UNRESOLVED-ORIGIN; from r41 the self-test's 1A step rows are stale
# there too; from r42 upstream's own test.yml fails ACTIVE-015-SELECTION three times (two setup-zig steps with no
# version, lines 333 and 948, and a setup-zig mention in a run script, line 967: the user's decision, v1.4.0-only
# lines the merged 1B tree does not hold, which keeps the fork's CI) (read from bundlecheck45 on v1.4.0)
V140_EXTRA = (('ACTIVE-015-SELECTION', 'ACTIVE-015-SELECTION .github/workflows/test.yml:333: a setup-zig step with no with.version, so setup-zig would read whichever build.zig.zon the job checked out'),
              ('ACTIVE-015-SELECTION', 'ACTIVE-015-SELECTION .github/workflows/test.yml:948: a setup-zig step with no with.version, so setup-zig would read whichever build.zig.zon the job checked out'),
              ('ACTIVE-015-SELECTION', "ACTIVE-015-SELECTION .github/workflows/test.yml:967: a setup-zig mention outside a setup-zig step's uses"),
              ('UNRESOLVED-ORIGIN', 'UNRESOLVED-ORIGIN src/apprt/gtk/class.zig: 12 feature tests or @field uses whose origin the gate cannot positively resolve (lines 207, 214, 216, 221, 222, 250, 257, 259, 260, 288, 293, 299), the allowance 0'),
              ('UNRESOLVED-ORIGIN', 'UNRESOLVED-ORIGIN src/renderer/metal/shaders.zig: 2 feature tests or @field uses whose origin the gate cannot positively resolve (lines 135, 140), the allowance 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE docs/agents/log/: a prefix row that names no directory of the tree and matches no file'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE .github/workflows/test.yml: no setup-zig step `zig-1a` in the job `selftest-appending` matches its setup-zig-step row'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE .github/workflows/test.yml: no setup-zig step `zig-1a` in the job `selftest-full` matches its setup-zig-step row'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32.zig: allows 2 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32/chrome_scene.zig: allows 1 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32/facade_budget.zig: allows 3 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32/settings_patch.zig: allows 1 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32/wgl.zig: allows 1 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32/window_state.zig: allows 1 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32_settings.zig: allows 11 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32_settings_fields.zig: allows 11 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32_theme.zig: allows 2 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/apprt/win32_toast_winrt.zig: allows 1 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/config/Config.zig: allows 9 unresolved origins, the file holds 1'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/font/SharedGridSet.zig: allows 1 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/renderer/generic.zig: allows 10 unresolved origins, the file holds 0'),
              ('STALE-ALLOWANCE', 'STALE-ALLOWANCE src/terminal/search/Thread.zig: allows 1 unresolved origins, the file holds 0'),)
FORK_STALE = tuple(text_ for kind_, text_ in V140_EXTRA if kind_ == "STALE-ALLOWANCE")
if want(213): results.append(residue_control("213-SM2-OM2-the-approved-bundle-on-the-real-v1.4.0-tree-passes-but-the-fork-s-rows",
                                              None, 1, {}))   # r35 to r37: exit 1, the lines V140_EXTRA adds
# r41 (round 40's Opus M3 (a)): a tree whose pin the control restores to the fork's fails ACTIVE-015-SELECTION on that
# pin, and the gate reads none of its Zig files, so the pin's two failures, beside the bundle's lines the text and CI
# checks give on this tree (r41: the self-test step's row, stale; r42: its two rows, and upstream test.yml's three
# lines) and none of the Zig lines (r40 read the tree through the 1A compiler's astdump instead)
if want(214): results.append(residue_control("214-SM2-an-active-zig-pin-restored-in-build-zig-zon-fails", edit_into(
    "build.zig.zon", V140_ZON, '.minimum_zig_version = "0.15.2",'), 1, {"ACTIVE-015-SELECTION": 1, "RESIDUE-015": 1},
    v140_extra="text"))
if want(215): results.append(residue_control("215-SM2-the-fixture-s-advisory-row-restored-in-the-live-run-spec-fails",
    write_into("ci/role-runs.tsv", "soak-releasesafe\tadvisory\t0.15\n", "a"), 1, {"RESIDUE-015": 1}))
if want(216): results.append(residue_control("216-SM2-a-zig-version-shim-in-production-fails", write_into(
    "src/r30_shim.zig", 'const builtin = @import("builtin");\n\npub fn shim() void {\n'
    '    if (builtin.zig_version.minor < 17) return;\n}\n'), 1, {"PRODUCTION-SHIM": 1}))
NUMERIC = ("src/renderer/generic.zig", "src/config/Config.zig", "src/font/", "dist/doxygen")


DERIVED_STALE = "feature tests on a type derived from std, the file holds"
UNRES_STALE = "unresolved origins, the file holds"


def derived_lines(out):
    """r35: the residue gate's lines about the derived-tests rows and the derived and unresolved categories; r36: and
    the unresolved-origin rows and UNRESOLVED-ORIGIN; r39: and UNPARSEABLE, AST-TILING and AST-TOKENS; r40: AST-ROLES."""
    return sorted(l_ for l_ in out.splitlines() if l_.startswith("FAIL ") and (
        DERIVED_STALE in l_ or UNRES_STALE in l_
        or l_.split(" ", 2)[1] in ("DERIVED-SHIM", "UNRESOLVED-DESTRUCTURING", "UNRESOLVED-ORIGIN", "UNPARSEABLE",
                                   "AST-TILING", "AST-TOKENS", "AST-ROLES")))   # r39, r40: and the parse's


def fork_head_ok(kinds, out):
    """r30 (round 29's Opus M2): the fork head is a 0.15 tree, so its pins fail (18 at the fixture's revision), and no
    number literal does (the split-dim floor at renderer/generic.zig:129 and :404 failed r29's pattern). r35 (the
    user's option 1): its derived rows exactly: Key's 4 as allowed; lib/enum.zig holds the fork's 4 of v1.4.0's 6 and
    terminal/c/style.zig none of its 2, both stale; no DERIVED-SHIM and no unresolved element. r36: and its
    unresolved-origin rows exactly: its own as allowed, v1.4.0's lib/union.zig and terminal/page.zig rows stale. r37,
    r38 to r45: each of the allowance's rows exactly as bundlecheck45 reads the fork head (bundle45_expect.py), and its
    pins' count as the controls measure it (controls_measure45.py); from r41 (round 40's Opus M3 (a)) the fork head
    pins 0.15, so the gate reads none of its Zig files and judges none of the rows only they can confirm."""
    hits = [l_ for l_ in out.splitlines() if l_.startswith("FAIL ") and any(n in l_ for n in NUMERIC)]
    want = sorted([])
    return kinds.get("ACTIVE-015-SELECTION") == 18 and not hits and derived_lines(out) == want


# r37 to r45: each 1B proxy's lines exactly as bundlecheck45 reads it (bundle45_expect.py), its UNPARSEABLE lines too
# (from r40 its pkg/ files' as well), read as 1B.3 leaves it:
# the two mechanical merges hold
# different versions of some upstream files (terminal/modes.zig), so each has its own
PROXY_WANT = {'trial-hybrid-140': ['FAIL STALE-ALLOWANCE src/Surface.zig: allows 2 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/apprt/win32.zig: allows 2 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/apprt/win32/settings_patch.zig: allows 1 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/apprt/win32_settings.zig: allows 11 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/build/GhosttyResources.zig: allows 1 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/cli/args.zig: allows 4 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/config/Config.zig: allows 9 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/config/key.zig: allows 1 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/lib/enum.zig: allows 6 unresolved origins, the file holds 4', 'FAIL STALE-ALLOWANCE src/terminal/PageList.zig: allows 4 unresolved origins, the file holds 0', "FAIL UNPARSEABLE pkg/apple-sdk/build.zig:31: the pinned compiler's parser rejects the file (expected_token), so the gate cannot read it", "FAIL UNPARSEABLE pkg/harfbuzz/build.zig:81: the pinned compiler's parser rejects the file (decl_between_fields), so the gate cannot read it", "FAIL UNPARSEABLE pkg/simdutf/build.zig:50: the pinned compiler's parser rejects the file (expected_comma_after_initializer), so the gate cannot read it", "FAIL UNPARSEABLE src/App.zig:793: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/Surface.zig:597: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/surface.zig:46: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32.zig:646: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/app.zig:932: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/config_problems.zig:302: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/confirm_text.zig:648: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/gl_startup.zig:830: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/host.zig:3994: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/input.zig:226: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/ipc_server.zig:2668: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/notifications.zig:999: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/palette_controller.zig:754: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/save_target.zig:699: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/search_controls.zig:1224: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/session.zig:2648: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/settings_patch.zig:2263: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/sys.zig:150: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/tab_label.zig:397: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/terminal_window.zig:535: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/test_support.zig:259: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/text.zig:203: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_hints.zig:678: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_jump_list.zig:2291: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_power.zig:629: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_powershell_install.zig:609: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_recovery.zig:824: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_session_state.zig:653: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_settings.zig:2234: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_settings_profiles.zig:1002: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_shell_menu.zig:198: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_terminal_accessibility.zig:110: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_toast_activator.zig:413: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_uia/events.zig:399: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_uia/widgets.zig:1899: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/cli/args.zig:1569: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/cli/ssh_cache.zig:242: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/config/Config.zig:5984: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/config/edit.zig:39: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/config/profile_map.zig:654: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/config/windows_shell.zig:5443: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/crash/minidump_windows.zig:252: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/font/discovery_windows_dwrite.zig:41: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/font/face/freetype.zig:389: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/input/command.zig:861: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/input/key.zig:90: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/os/hostname.zig:77: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/os/local_path.zig:2048: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/renderer/OpenGL.zig:135: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/PageList.zig:1599: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/Terminal.zig:172: the pinned compiler's parser rejects the file (decl_between_fields), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/kitty/graphics_image.zig:443: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/termio/Exec.zig:413: the pinned compiler's parser rejects the file (expected_semi_after_stmt), so the gate cannot read it", "FAIL UNPARSEABLE src/termio/mailbox.zig:113: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/termio/stream_handler.zig:1021: the pinned compiler's parser rejects the file (expected_token), so the gate cannot read it", "FAIL UNPARSEABLE src/termio/wsl_env.zig:1264: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/update/http_windows.zig:615: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/update/portable_apply.zig:156: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/update/util.zig:60: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", 'FAIL UNRESOLVED-ORIGIN src/extra/fish.zig: 2 feature tests or @field uses whose origin the gate cannot positively resolve (lines 124, 135), the allowance 0'], 'trial-ours-140': ['FAIL STALE-ALLOWANCE src/Surface.zig: allows 2 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/apprt/win32.zig: allows 2 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/apprt/win32/settings_patch.zig: allows 1 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/apprt/win32_settings.zig: allows 11 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/build/GhosttyResources.zig: allows 1 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/cli/args.zig: allows 4 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/config/Config.zig: allows 9 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/config/key.zig: allows 1 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/lib/enum.zig: allows 6 unresolved origins, the file holds 4', 'FAIL STALE-ALLOWANCE src/terminal/PageList.zig: allows 4 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/terminal/modes.zig: allows 1 unresolved origins, the file holds 0', 'FAIL STALE-ALLOWANCE src/terminal/tmux/viewer.zig: allows 1 unresolved origins, the file holds 0', "FAIL UNPARSEABLE pkg/apple-sdk/build.zig:31: the pinned compiler's parser rejects the file (expected_token), so the gate cannot read it", "FAIL UNPARSEABLE pkg/harfbuzz/build.zig:81: the pinned compiler's parser rejects the file (decl_between_fields), so the gate cannot read it", "FAIL UNPARSEABLE pkg/simdutf/build.zig:50: the pinned compiler's parser rejects the file (expected_comma_after_initializer), so the gate cannot read it", "FAIL UNPARSEABLE src/App.zig:793: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/Surface.zig:597: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/surface.zig:46: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32.zig:646: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/app.zig:932: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/config_problems.zig:302: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/confirm_text.zig:648: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/gl_startup.zig:830: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/host.zig:3994: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/input.zig:226: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/ipc_server.zig:2668: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/notifications.zig:999: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/palette_controller.zig:754: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/save_target.zig:699: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/search_controls.zig:1224: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/session.zig:2648: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/settings_patch.zig:2263: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/sys.zig:150: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/tab_label.zig:397: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/terminal_window.zig:535: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/test_support.zig:259: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32/text.zig:203: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_hints.zig:678: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_jump_list.zig:2291: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_power.zig:629: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_powershell_install.zig:609: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_recovery.zig:824: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_session_state.zig:653: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_settings.zig:2234: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_settings_profiles.zig:1002: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_shell_menu.zig:198: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_terminal_accessibility.zig:110: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_toast_activator.zig:413: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_uia/events.zig:399: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/apprt/win32_uia/widgets.zig:1899: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/cli/args.zig:1569: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/cli/ssh_cache.zig:242: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/config/Config.zig:5984: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/config/edit.zig:39: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/config/profile_map.zig:654: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/config/windows_shell.zig:5443: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/crash/minidump_windows.zig:252: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/font/discovery_windows_dwrite.zig:41: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/font/face/freetype.zig:389: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/input/command.zig:861: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/input/key.zig:90: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/os/hostname.zig:77: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/os/local_path.zig:2048: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/renderer/OpenGL.zig:135: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/PageList.zig:1599: the pinned compiler's parser rejects the file (expected_statement), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/Terminal.zig:172: the pinned compiler's parser rejects the file (decl_between_fields), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/c/terminal.zig:873: the pinned compiler's parser rejects the file (decl_between_fields), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/kitty/graphics_exec.zig:90: the pinned compiler's parser rejects the file (expected_token), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/kitty/graphics_storage.zig:1030: the pinned compiler's parser rejects the file (expected_token), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/osc/parsers/change_window_title.zig:38: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/osc/parsers/hierarchical_context.zig:492: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/osc/parsers/program_status.zig:654: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/stream_terminal.zig:860: the pinned compiler's parser rejects the file (expected_expr), so the gate cannot read it", "FAIL UNPARSEABLE src/terminal/tmux/viewer.zig:2778: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/termio/Exec.zig:413: the pinned compiler's parser rejects the file (expected_semi_after_stmt), so the gate cannot read it", "FAIL UNPARSEABLE src/termio/mailbox.zig:113: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/termio/stream_handler.zig:1021: the pinned compiler's parser rejects the file (expected_token), so the gate cannot read it", "FAIL UNPARSEABLE src/termio/wsl_env.zig:1264: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/update/http_windows.zig:615: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/update/portable_apply.zig:156: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", "FAIL UNPARSEABLE src/update/util.zig:60: the pinned compiler's parser rejects the file (mismatched_binary_op_whitespace), so the gate cannot read it", 'FAIL UNRESOLVED-ORIGIN src/extra/fish.zig: 2 feature tests or @field uses whose origin the gate cannot positively resolve (lines 124, 135), the allowance 0']}


def proxy_ok(kinds, out, tree):
    """r35 (the user's option 1): a 1B proxy (a mechanical merge of v1.4.0, so its lib/enum.zig is neither v1.4.0's nor
    the fork's) with the bundle: its derived rows exactly: Key's 4 and style.zig's 2 as allowed, lib/enum.zig's 4 of
    v1.4.0's 6 stale; no DERIVED-SHIM, no unresolved element, no feature test on std beyond its rows. r36: and its one
    file the merge broke, src/extra/fish.zig, whose line 124 names an `opt_type` its merged loop no longer binds:
    UNRESOLVED-ORIGIN 2, exactly."""
    return derived_lines(out) == PROXY_WANT[tree] and "PRODUCTION-SHIM" not in kinds


if want(235): results.append(residue_control("235-OM2-the-fork-head-fails-on-its-pins-never-on-a-number-literal", None, 1,
    None, tree=rev, check=fork_head_ok))
if want(236): results.append(residue_control("236-OL1-zig-version-copied-to-a-local-is-a-shim", write_into(
    "src/r30_shim.zig", 'const builtin = @import("builtin");\n\npub fn shim() void {\n    const zv = builtin.zig_version;\n'
    '    if (zv.minor < 17) return;\n}\n'), 1, {"PRODUCTION-SHIM": 1}))
if want(237): results.append(residue_control("237-OL1-a-feature-test-on-std-is-a-shim", write_into(
    "src/r30_shim.zig", 'const std = @import("std");\n\npub const has_mutex = @hasDecl(std.Thread, "Mutex");\n'), 1,
    {"PRODUCTION-SHIM": 1}))
if want(238): results.append(residue_control("238-OL4-a-content-row-whose-line-changed-is-stale", edit_into(
    "src/os/mach.zig", "/// This is based heavily on the Zig 0.15.2 PageAllocator implementation,",
    "/// This is based on the Zig 0.15.2 PageAllocator implementation,"), 1, {"STALE-ALLOWANCE": 1, "RESIDUE-015": 1}))
if want(239): results.append(residue_control("239-OL4-an-r29-lines-row-is-refused", write_into(
    "ci/residue-allow.tsv", "lines\tsrc/os/mach.zig\t46,47\tr29's form\n", "a"), 1, {}, exp_text=("BAD-ALLOWANCE",)))
if want(240): results.append(residue_control("240-OM2-report-only-prints-the-same-and-passes", edit_into(
    "build.zig.zon", V140_ZON, '.minimum_zig_version = "0.15.2",'), 0, {"ACTIVE-015-SELECTION": 1, "RESIDUE-015": 1},
    exp_text=("RESULT REPORT-ONLY",), extra=("--report-only",), v140_extra="text"))
# -- r31 (round 30's Sol M1, Opus M1, the lead's direction): evidence by lexical scope. Each negative carries a decoy
# declaration of the receiver's name that r30's text match found (a sibling block's, a nested struct's field, another
# function's local, a sibling container's struct, a type shadowed by a comptime parameter), and locks the renderer
# mutex through a binding the resolver does not read; r30 gave each "distinct" or another lock and a passing gate
# (logs-r31\precheck31.txt). The positives S1c, S5c and S7c are the same without the decoy: unclassified in both.
# Opus's own overlays are not in the findings file; these are rebuilt from its descriptions.
BLK31 = "blk: {\n                break :blk " + RS + ".mutex;\n            }"
BLK31_ = "blk: {\n            break :blk " + RS + ".mutex;\n        }"
DECOY31 = "        {\n            var m: std.Thread.Mutex = .{};\n            m.lock();\n            defer m.unlock();\n        }\n"
OPT31 = ("    fn r31opt(other: *TerminalWindow) ?*std.Thread.Mutex {\n        return " + RS + ".mutex;\n    }\n"
         "    fn r31all(other: *TerminalWindow) [1]*std.Thread.Mutex {\n        return .{" + RS + ".mutex};\n    }\n")


def wrap31(name, body, extra=""):
    return ("const " + name.upper() + " = struct {\n    fn " + name + "(other: *TerminalWindow) void {\n" + body + "    }\n"
            + extra + "};")


def unc31(fn, n=1, extra=None):
    d = dict(UNC, inv_delta=dict({"unclassified": n}, **(extra or {})), gate_kinds={"UNCLASSIFIED-NOT-ALLOWED": n},
             rows=[("unclassified", fn, "lock", "UNCLASSIFIED", "UNREVIEWED", "-")] * n)
    return d


if want(241): results.append(shape_control("241-SM1-sibling-blocks-binding-one-name-twice", wrap31("r31s", DECOY31
    + "        {\n            const m = " + BLK31 + ";\n            m.lock();\n            defer m.unlock();\n        }\n"),
    unc31("r31s", 2), "r31s"))
if want(242): results.append(shape_control("242-OM1-S1-an-if-capture-and-a-sibling-decoy", wrap31("r31a", DECOY31
    + "        if (r31opt(other)) |m| {\n            m.lock();\n            defer m.unlock();\n        }\n", OPT31),
    unc31("r31a", 2), "r31a"))
if want(243): results.append(shape_control("243-OM1-S2-a-labelled-block-and-a-later-sibling-decoy", wrap31("r31b",
    "        {\n            const m = " + BLK31 + ";\n            m.lock();\n            defer m.unlock();\n        }\n" + DECOY31),
    unc31("r31b", 2), "r31b"))
if want(244): results.append(shape_control("244-OM1-S3-a-for-capture-and-a-sibling-decoy", wrap31("r31c", DECOY31
    + "        for (r31all(other)) |m| {\n            m.lock();\n            m.unlock();\n        }\n", OPT31.replace("r31opt", "r31optb")),
    unc31("r31c", 2), "r31c"))
if want(245): results.append(shape_control("245-OM1-S4-an-rwlock-sibling-decoy", wrap31("r31d",
    "        {\n            var l: std.Thread.RwLock = .{};\n            l.lock();\n            defer l.unlock();\n        }\n"
    "        {\n            const l = " + BLK31 + ";\n            l.lock();\n            defer l.unlock();\n        }\n"),
    unc31("r31d", 2), "r31d"))
if want(246): results.append(shape_control("246-OM1-S5-a-nested-struct-s-field-decoy", wrap31("r31e",
    "        const R31Box = struct {\n            m: std.Thread.Mutex = .{},\n        };\n        _ = R31Box;\n"
    "        const m = " + BLK31_ + ";\n        m.lock();\n        defer m.unlock();\n"), unc31("r31e"), "r31e"))
if want(247): results.append(shape_control("247-OM1-S6-another-function-s-local-decoy",
    "const R31F6 = struct {\n    fn r31f6a() void {\n        var m6: std.Thread.Mutex = .{};\n        m6.lock();\n"
    "        defer m6.unlock();\n    }\n    fn r31f6b(other: *TerminalWindow) void {\n        const m6 = " + BLK31_ + ";\n"
    "        m6.lock();\n        defer m6.unlock();\n    }\n};", unc31("r31f6b"), "r31f6b"))
if want(248): results.append(shape_control("248-OM1-S7-a-sibling-container-s-struct-decoy",
    "const R31A7 = struct {\n    const State7 = renderer.State;\n    fn r31a7(st: *State7) void {\n        st.mutex.lock();\n"
    "        defer st.mutex.unlock();\n    }\n};\nconst R31B7 = struct {\n    const State7 = struct {\n"
    "        mutex: std.Thread.Mutex = .{},\n    };\n};", unc31("r31a7"), "r31a7"))
if want(249): results.append(shape_control("249-OM1-S8-a-comptime-type-parameter-decoy",
    "const R31O8 = struct {\n    const Inner8 = struct {\n        m: std.Thread.Mutex = .{},\n    };\n};\nconst R31F8 = struct {\n"
    "    fn r31f8(comptime Inner8: type, x: *Inner8) void {\n        x.m.lock();\n        defer x.m.unlock();\n    }\n};",
    unc31("r31f8"), "r31f8"))
if want(250): results.append(shape_control("250-OM1-S1c-the-if-capture-alone", wrap31("r31ac",
    "        if (r31optc(other)) |m| {\n            m.lock();\n            defer m.unlock();\n        }\n",
    OPT31.replace("r31opt", "r31optc").replace("r31all", "r31allc")), unc31("r31ac"), "r31ac"))
if want(251): results.append(shape_control("251-OM1-S5c-the-labelled-block-alone", wrap31("r31ec",
    "        const m = " + BLK31_ + ";\n        m.lock();\n        defer m.unlock();\n"), unc31("r31ec"), "r31ec"))
if want(252): results.append(shape_control("252-OM1-S7c-the-alias-alone",
    "const R31A7C = struct {\n    const State7c = renderer.State;\n    fn r31a7c(st: *State7c) void {\n        st.mutex.lock();\n"
    "        defer st.mutex.unlock();\n    }\n};", unc31("r31a7c"), "r31a7c"))
# -- r31 (round 30's Sol M2): the census reads a reflected name with Zig's escapes decoded
if want(253): results.append(failclosed_control("253-SM2-an-escaped-op-name-fails-explicitly", wrap31("r31x1",
    "        @field(std.Thread.Mutex, \"\\x6cock\")(" + RS + ".mutex);\n        defer " + RS + ".mutex.unlock();\n"),
    "UNREADABLE-RECEIVER src/apprt/win32.zig:", {"UNREADABLE-RECEIVER": 1}))
if want(254): results.append(failclosed_control("254-SM2-a-unicode-escaped-op-name-fails-explicitly", wrap31("r31x2",
    "        @field(std.Thread.Mutex, \"lo\\u{63}k\")(" + RS + ".mutex);\n        defer " + RS + ".mutex.unlock();\n"),
    "UNREADABLE-RECEIVER src/apprt/win32.zig:", {"UNREADABLE-RECEIVER": 1}))
if want(255): results.append(failclosed_control("255-SM2-an-escaped-op-name-as-call-s-callee-fails-explicitly", wrap31("r31x3",
    "        @call(.auto, @field(std.Thread.Mutex, \"\\x6cock\"), .{" + RS + ".mutex});\n        defer " + RS
    + ".mutex.unlock();\n"), "UNREADABLE-RECEIVER src/apprt/win32.zig:", {"UNREADABLE-RECEIVER": 1}))
if want(256): results.append(shape_control("256-SM2-an-escaped-field-read-that-is-no-op-changes-nothing", wrap31("r31x4",
    "        _ = @field(other.core_surface, \"\\x72enderer_state\");\n"),
    dict(rows=[], inv_exit=0, inv_delta={}, gate_exit=0, gate_kinds={}, cmp_exit=None, cmp_kinds={}), None))
if want(257): results.append(shape_control("257-UD-a-new-called-field-with-no-literal-name-fails-the-gate", wrap31("r31x5",
    "        const op = \"lock\";\n        @field(std.Thread.Mutex, op)(" + RS + ".mutex);\n        defer " + RS
    + ".mutex.unlock();\n"), dict(UNC, rows=[("unclassified", "r31x5", "@field", "UNCLASSIFIED", "UNREVIEWED", "-")]), "r31x5"))
REFLECTED = (("src/apprt/win32_jump_list.zig", "readRemovedLinkText", "@field(link.vtbl, getter)"),
             ("src/apprt/win32_toast_winrt.zig", "applyTagAndGroup", "@field(toast2.vtbl, pair[1])"))


def reflected_base_control(tag):
    """r31 (the user's census decision): the fork's two COM vtable calls through comptime method names are each one
    unclassified acquisition in the fixture's base run, keyed by their @field text, and the allow-list passes them."""
    rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(logdir, "inv-00-base-unclassified.tsv"), encoding="utf-8")]
    got = {k: sum(1 for u in rows if len(u) > 10 and (u[1], u[3], u[10]) == k) for k in REFLECTED}
    base_ok = open(os.path.join(logdir, "00-base.txt"), encoding="utf-8").read().find("CONTROL AS EXPECTED") >= 0
    ok = all(v == 1 for v in got.values()) and base_ok
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## the base run's reflected calls: {got}; the base control passed: {base_ok}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: {sum(got.values())} allowed reflected calls, base {'passes' if base_ok else 'fails'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


if FULL and want(258): results.append(reflected_base_control("258-UD-the-two-allow-listed-reflected-calls-pass"))
if want(259): results.append(control("259-UD-a-second-reflected-call-at-an-allowed-site-fails-allow-count", overlay("c259", {
    "src/apprt/win32_jump_list.zig": replace(
        "    if (@field(link.vtbl, getter)(link.asRaw(), buffer.ptr, @intCast(buffer.len)) < 0) {\n",
        "    _ = @field(link.vtbl, getter)(link.asRaw(), buffer.ptr, @intCast(buffer.len));\n"
        "    if (@field(link.vtbl, getter)(link.asRaw(), buffer.ptr, @intCast(buffer.len)) < 0) {\n")}),
    0, {"unclassified": 1}, 1, {"ALLOW-COUNT": 1}))
if want(260): results.append(control("260-OL3-a-second-acquisition-with-an-allowed-key-fails-allow-count", overlay("c260", {
    "src/App.zig": replace("        mailbox.mutex.lock();\n        defer mailbox.mutex.unlock();\n        return mailbox.len != 0;\n",
                           "        mailbox.mutex.lock();\n        mailbox.mutex.unlock();\n        mailbox.mutex.lock();\n"
                           "        defer mailbox.mutex.unlock();\n        return mailbox.len != 0;\n")}),
    0, {"unclassified": 1}, 1, {"ALLOW-COUNT": 1}))


def allow_variant_control(tag, mutate, exp_text, exp_kinds):
    """r31 (round 30's Opus L3): the gate on the fixture's base run with an allow-list of the control's own."""
    alt = os.path.join(logdir, tag[:3] + "-allow.txt")
    open(alt, "w", encoding="utf-8", newline="\n").write(mutate(open(allow, encoding="utf-8").read()))
    rc, out = run([py, "-I", gate, "check", repo, rev, SCOPE, table, alt, os.path.join(logdir, "inv-00-base"), entries,
                   anchors])
    kinds = dict(collections.Counter(l_.split(" ", 2)[1] for l_ in out.splitlines() if l_.startswith("FAIL ")))
    ok = rc != 0 and exp_text in out and kinds == exp_kinds
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## gate with the control's allow-list (exit {rc})\n{out}\nexpected: a failing exit naming {exp_text}, "
                 f"failures {exp_kinds}\nCONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: gate exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


def _no_count(text):
    out_ = []
    for l_ in text.splitlines():
        a_ = l_.split("\t")
        out_.append(l_ if l_.startswith("#") or len(a_) < 5 else "\t".join(a_[:3] + a_[4:]))
    return "\n".join(out_) + "\n"


def _count_up(text):
    key_ = "src/App.zig\tneedsModalWake\tmailbox.mutex\t1\t"
    assert text.count(key_) == 1
    return text.replace(key_, "src/App.zig\tneedsModalWake\tmailbox.mutex\t2\t")


if want(261): results.append(allow_variant_control("261-OL3-an-allow-list-row-without-a-count-fails-the-gate", _no_count,
    "BAD-ALLOW", {}))
if want(262): results.append(allow_variant_control("262-OL3-an-approved-count-above-the-tree-s-fails-allow-count", _count_up,
    "ALLOW-COUNT", {"ALLOW-COUNT": 1}))
# -- r31 (round 30's Opus L1): feature tests on std through @import("std"), an alias of std, and std.meta.hasFn
if want(263): results.append(residue_control("263-OL1-a-feature-test-on-import-std-is-a-shim", write_into(
    "src/r31_shim.zig", 'pub const has_mutex = @hasDecl(@import("std").Thread, "Mutex");\n'), 1, {"PRODUCTION-SHIM": 1}))
if want(264): results.append(residue_control("264-OL1-a-feature-test-through-an-alias-of-std-is-a-shim", write_into(
    "src/r31_shim.zig", 'const std = @import("std");\nconst T = std.Thread;\n\npub const has_mutex = @hasDecl(T, "Mutex");\n'), 1,
    {"PRODUCTION-SHIM": 1}))
if want(265): results.append(residue_control("265-OL1-std-meta-hasfn-is-a-shim", write_into(
    "src/r31_shim.zig", 'const std = @import("std");\n\npub const has_lock = std.meta.hasFn(std.Thread.Mutex, "lockUncancelable");\n'),
    1, {"PRODUCTION-SHIM": 1}))
# -- r32 (round 31's Opus M1, M2, Sol M1, M2 and the lead's direction): the source read through one token stream
# (zigtok.py). Each negative passed r31's tools (logs\precheck32.txt): the binding index read a declaration only when a
# type, `=` or `;` followed its name on its line and a capture list only on its opener's line (Opus M1); the census
# read `.op(` per cleaned line and dropped a `.op` with no `(` (Opus M2); a reflected call's position came from a few
# characters around it (Sol M2); std's namespace aliases came from the whole file (Sol M1). The positives are the same
# shapes without what made them pass. The reviewers' own overlays are not in the findings file; these are rebuilt
# from its descriptions.
OPT32 = "    fn r32opt(other: *TerminalWindow) ?*std.Thread.Mutex {\n        return " + RS + ".mutex;\n    }\n"
UNL32 = "        defer " + RS + ".mutex.unlock();\n"
if want(266): results.append(shape_control("266-OM1-P01-a-destructuring-declaration-and-a-decoy-before", wrap31("r32p1",
    DECOY31 + "        {\n            const m, const z = .{ " + RS + ".mutex, @as(u8, 0) };\n            _ = z;\n"
    "            m.lock();\n            defer m.unlock();\n        }\n"), unc31("r32p1", 2), "r32p1"))
if want(267): results.append(shape_control("267-OM1-P05-a-var-destructuring-declaration-and-a-decoy-after", wrap31("r32p5",
    "        {\n            var m, var z = .{ " + RS + ".mutex, @as(u8, 0) };\n            _ = &m;\n            _ = &z;\n"
    "            m.lock();\n            defer m.unlock();\n        }\n" + DECOY31), unc31("r32p5", 2), "r32p5"))
if want(268): results.append(shape_control("268-OM1-P02-the-destructuring-declaration-alone", wrap31("r32p2",
    "        const m, const z = .{ " + RS + ".mutex, @as(u8, 0) };\n        _ = z;\n        m.lock();\n"
    "        defer m.unlock();\n"), unc31("r32p2"), "r32p2"))
if want(269): results.append(shape_control("269-OM1-P03-a-typed-destructuring-declaration-alone", wrap31("r32p3",
    "        const m: *std.Thread.Mutex, const z: u8 = .{ " + RS + ".mutex, 0 };\n        _ = z;\n        m.lock();\n"
    "        defer m.unlock();\n"), unc31("r32p3"), "r32p3"))
if want(270): results.append(shape_control("270-OM1-a-capture-list-on-its-own-line-and-a-decoy", wrap31("r32c",
    DECOY31 + "        if (r32opt(other))\n            |m|\n        {\n            m.lock();\n            defer m.unlock();\n"
    "        }\n", OPT32), unc31("r32c", 2), "r32c"))
if want(271): results.append(shape_control("271-OM2-Q01-a-lock-call-split-by-a-comment-and-a-line-break", wrap31("r32q1",
    "        " + RS + ".mutex.lock // note\n            ();\n" + UNL32), prod_exp("r32q1"), "r32q1"))
if want(272): results.append(shape_control("272-OM2-Q02-the-receiver-then-a-commented-dot-then-the-call", wrap31("r32q2",
    "        " + RS + ".mutex\n            . // note\n            lock();\n" + UNL32), prod_exp("r32q2"), "r32q2"))
if want(273): results.append(failclosed_control("273-OM2-Q03-a-lock-op-named-through-an-expression-fails-explicitly",
    wrap31("r32q3", "        const lock_fn = @TypeOf(" + RS + ".mutex.*).lock;\n        lock_fn(" + RS + ".mutex);\n"
           + UNL32), "UNREADABLE-RECEIVER src/apprt/win32.zig:", {"UNREADABLE-RECEIVER": 1}))
if want(274): results.append(shape_control("274-OM2-O04-a-lock-call-split-by-a-line-break", wrap31("r32o4",
    "        " + RS + ".mutex.lock\n            ();\n" + UNL32), prod_exp("r32o4"), "r32o4"))
if want(275): results.append(shape_control("275-OM2-O05-a-lock-call-split-three-ways", wrap31("r32o5",
    "        " + RS + ".mutex.\n            lock // note\n            ();\n" + UNL32), prod_exp("r32o5"), "r32o5"))
if want(276): results.append(shape_control("276-a-field-and-a-container-variable-named-lock-read-are-no-lock-op",
    "const R32F = struct {\n    lock: bool = false,\n    fn r32f(self: *R32F) bool {\n        return self.lock;\n    }\n};\n"
    "const R32G = struct {\n    threadlocal var lock: bool = false;\n    fn r32g() bool {\n        return R32G.lock;\n    }\n};",
    dict(rows=[], inv_exit=0, inv_delta={}, gate_exit=0, gate_kinds={}, cmp_exit=None, cmp_kinds={}), None))
if want(277): results.append(shape_control("277-SM2-a-called-field-with-a-comment-before-its-call", wrap31("r32x1",
    "        const op = \"lock\";\n        @field(std.Thread.Mutex, op) // a comment\n            (" + RS + ".mutex);\n"
    + UNL32), dict(UNC, rows=[("unclassified", "r32x1", "@field", "UNCLASSIFIED", "UNREVIEWED", "-")]), "r32x1"))
if want(278): results.append(shape_control("278-SM2-a-called-field-with-whitespace-before-its-call", wrap31("r32x2",
    "        const op = \"lock\";\n        @field(std.Thread.Mutex, op)" + " " * 48 + "\n\n\n            (" + RS
    + ".mutex);\n" + UNL32), dict(UNC, rows=[("unclassified", "r32x2", "@field", "UNCLASSIFIED", "UNREVIEWED", "-")]),
    "r32x2"))
if want(279): results.append(shape_control("279-SM2-call-s-callee-field-after-a-comment", wrap31("r32x3",
    "        const op = \"lock\";\n        @call(.auto, // the method\n            @field(std.Thread.Mutex, op), .{" + RS
    + ".mutex});\n" + UNL32), dict(UNC, rows=[("unclassified", "r32x3", "@field", "UNCLASSIFIED", "UNREVIEWED", "-")]),
    "r32x3"))
if want(280): results.append(shape_control("280-SM1-a-sibling-container-s-std-alias-is-no-evidence",
    "const R32SIB = struct {\n    const R32Thread = std.Thread;\n};\nconst R32S = struct {\n"
    "    fn r32s(other: *TerminalWindow) void {\n        var m: R32Thread.Mutex = blk: {\n            break :blk " + RS
    + ".mutex.*;\n        };\n        m.lock();\n        defer m.unlock();\n    }\n};", unc31("r32s"), "r32s"))
if want(281): results.append(shape_control("281-SM1-the-same-with-no-alias-anywhere",
    "const R32S2 = struct {\n    fn r32s2(other: *TerminalWindow) void {\n        var m: R32Thread2.Mutex = blk: {\n"
    "            break :blk " + RS + ".mutex.*;\n        };\n        m.lock();\n        defer m.unlock();\n    }\n};",
    unc31("r32s2"), "r32s2"))
if want(282): results.append(shape_control("282-SM1-the-using-container-s-own-std-alias-is-evidence",
    "const R32S3 = struct {\n    const R32Thread3 = std.Thread;\n    fn r32s3(other: *TerminalWindow) void {\n"
    "        var m: R32Thread3.Mutex = blk: {\n            break :blk " + RS + ".mutex.*;\n        };\n        m.lock();\n"
    "        defer m.unlock();\n    }\n};",
    dict(rows=[], inv_exit=0, inv_delta={}, gate_exit=0, gate_kinds={}, cmp_exit=None, cmp_kinds={}), None))
if want(283): results.append(shape_control("283-SM1-a-shadowed-std-is-no-evidence",
    "const R32STD = struct {\n    const std = struct {\n        const Thread = struct {\n"
    "            const Mutex = *@import(\"std\").Thread.Mutex;\n        };\n    };\n"
    "    fn r32std(other: *TerminalWindow) void {\n        const m: std.Thread.Mutex = blk: {\n            break :blk " + RS
    + ".mutex;\n        };\n        m.lock();\n        defer m.unlock();\n    }\n};", unc31("r32std"), "r32std"))
# -- r32 (round 31's Sol M3, Opus L3, Sol L1): the residue gate counts feature tests from the token stream
if want(284): results.append(residue_control("284-SM3-a-feature-test-over-several-lines-is-a-shim", write_into(
    "src/r32_shim.zig", 'const std = @import("std");\n\npub const has_mutex = @hasDecl(\n    std.Thread,\n    "Mutex",\n);\n'),
    1, {"PRODUCTION-SHIM": 1}))
if want(285): results.append(residue_control("285-SM3-a-feature-test-with-a-comment-inside-is-a-shim", write_into(
    "src/r32_shim.zig", 'const std = @import("std");\n\npub const has_mutex = @hasDecl( // the mutex\n    std.Thread, "Mutex");\n'),
    1, {"PRODUCTION-SHIM": 1}))
if want(286): results.append(residue_control("286-OL3-a-feature-test-through-typeof-is-a-shim", write_into(
    "src/r32_shim.zig", 'const std = @import("std");\n\npub const has_alloc = @hasDecl(@TypeOf(std.heap.page_allocator), "rawAlloc");\n'),
    1, {"PRODUCTION-SHIM": 1}))
if want(287): results.append(residue_control("287-OL3-SL1-typeinfo-on-std-is-a-shim", write_into(
    "src/r32_shim.zig", 'const std = @import("std");\n\npub const mutex_decls = @typeInfo(std.Thread.Mutex).@"struct".decls.len;\n'),
    1, {"PRODUCTION-SHIM": 1}))


def bindcheck_control(tag, prefix, ov, exp_exit, exp_text, exp_kinds, astdump=None):
    """r32 (round 31's Opus L5), r35 to r40: the independent binding check (bindcheck41.py) on an inventory's distinct
    acquisitions: exit, the expected text, and the failure count by kind."""
    exe_ = astdump if astdump is not None else ASTDUMP.get("1a")   # r40: the pin control passes the other one
    rc, out = run([py, "-I", bindcheck, repo, prefix] + (["--astdump", exe_] if exe_ else [])
                  + ["--work", os.path.join(logdir, "bind-ast", tag)] + (["--overlay", ov] if ov else []))   # r39
    kinds = dict(collections.Counter(l_.split(" ", 2)[1] for l_ in out.splitlines() if l_.startswith("FAIL ")))
    ok = rc == exp_exit and all(x in out for x in exp_text) and kinds == exp_kinds
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## bindcheck41.py (exit {rc})\n{out}\nexpected: exit {exp_exit}, text {exp_text}, failures {exp_kinds}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: binding check exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


def _bind_twice(tag):
    ov = overlay("c" + tag[:3], {W32: append(wrap31("r32b", DECOY31 + DECOY31))})
    text = open(os.path.join(ov, *W32.split("/")), encoding="utf-8").read()
    n0 = len(show(W32).splitlines())
    ln = next(i for i, l_ in enumerate(text.splitlines(), 1) if i > n0 and l_.strip() == "m.lock();")
    prefix = os.path.join(logdir, "inv-" + tag[:3])
    open(prefix + "-distinct.tsv", "w", encoding="utf-8", newline="\n").write(f"{rev}\t{W32}\t{ln}\tr32b\tlock\tm\n")
    return bindcheck_control(tag, prefix, ov, 1, ("BIND-TWICE",), {"BIND-TWICE": 1})


if FULL and want(288): results.append(bindcheck_control("288-OL5-the-binding-check-passes-the-base-run-s-distinct-acquisitions",
    os.path.join(logdir, "inv-00-base"), None, 0, ("bound once in their function 121, container globals 26, failures 0",
                                                   "RESULT PASS"), {}))
if FULL and want(289): results.append(_bind_twice("289-OL5-a-distinct-receiver-bound-twice-fails-the-binding-check"))
# -- r33 (round 32's Opus M1, Sol M1 and the lead's direction): the evidence-based exemption. Each negative passed
# r32's tools with no row (logs\precheck33.txt): r32 took the no-call lock op for a field read because its root's
# type was not spelled `type` or `anytype` and its `var` did not follow `comptime`; Zig makes such a parameter or
# `var` comptime. CL and CM, the direct calls, are unclassified in both. Rebuilt from the findings' descriptions
# (shapes33.py; the letters are its own).
if want(290): results.append(shape_control('290-OM1-OA-a-parameter-typed-by-an-alias-of-type',
    'const R33A = struct {\n    const Ty = type;\n    fn r33a(M: Ty, other: *TerminalWindow) void {\n        const lock_fn = M.lock;\n        lock_fn(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33a'), 'r33a'))
if want(291): results.append(shape_control('291-OM1-OB-a-parameter-of-optional-type',
    'const R33B = struct {\n    fn r33b(M: ?type, other: *TerminalWindow) void {\n        const lock_fn = M.?.lock;\n        lock_fn(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33b'), 'r33b'))
if want(292): results.append(shape_control('292-OM1-OC-a-parameter-of-a-struct-with-a-type-field',
    'const R33C = struct {\n    fn r33c(cfg: struct { M: type }, other: *TerminalWindow) void {\n        const lock_fn = cfg.M.lock;\n        lock_fn(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33c'), 'r33c'))
if want(293): results.append(shape_control('293-OM1-OD-a-parameter-of-parenthesised-type',
    'const R33D = struct {\n    fn r33d(M: (type), other: *TerminalWindow) void {\n        const lock_fn = M.lock;\n        lock_fn(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33d'), 'r33d'))
if want(294): results.append(shape_control('294-OM1-OE-a-parameter-of-typeof-u8',
    'const R33E = struct {\n    fn r33e(M: @TypeOf(u8), other: *TerminalWindow) void {\n        const lock_fn = M.lock;\n        lock_fn(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33e'), 'r33e'))
if want(295): results.append(shape_control('295-OM1-OF-a-var-in-a-container-constant-s-comptime-block',
    'const R33F = struct {\n    const take = blk: {\n        var T = @TypeOf(@as(*TerminalWindow, undefined).core_surface.renderer_state.mutex.*);\n        _ = &T;\n        break :blk T.lock;\n    };\n    fn r33f(other: *TerminalWindow) void {\n        take(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('(top level)'), 'r33f'))
if want(296): results.append(shape_control('296-OM1-OK-call-through-a-runtime-struct-s-fn-pointer-field',
    'const R33K = struct {\n    const Ops = struct { lock: *const fn (*std.Thread.Mutex) void };\n    fn r33k(ops: Ops, other: *TerminalWindow) void {\n        @call(.auto, ops.lock, .{other.core_surface.renderer_state.mutex});\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33k'), 'r33k'))
if want(297): results.append(shape_control('297-OM1-OM-a-quoted-op-name-through-an-alias-of-type',
    'const R33M = struct {\n    const Ty = type;\n    fn r33m(M: Ty, other: *TerminalWindow) void {\n        const lock_fn = M.@"lock";\n        lock_fn(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33m'), 'r33m'))
if want(298): results.append(shape_control('298-OM1-OP-a-pointer-to-a-struct-with-a-type-field-0.15.2-only',
    'const R33P = struct {\n    fn r33p(p: *const struct { M: type }, other: *TerminalWindow) void {\n        const lock_fn = p.M.lock;\n        lock_fn(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33p'), 'r33p'))
if want(299): results.append(shape_control('299-OM1-CL-ok-s-direct-call-twin',
    'const R33CL = struct {\n    const Ops = struct { lock: *const fn (*std.Thread.Mutex) void };\n    fn r33cl(ops: Ops, other: *TerminalWindow) void {\n        ops.lock(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33cl'), 'r33cl'))
if want(300): results.append(shape_control('300-OM1-CM-om-s-direct-call-twin',
    'const R33CM = struct {\n    const Ty = type;\n    fn r33cm(M: Ty, other: *TerminalWindow) void {\n        M.@"lock"(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33cm'), 'r33cm'))
if want(301): results.append(shape_control('301-SM1-S1-a-typed-type-var-in-a-comptime-block',
    'const R33S1 = struct {\n    fn r33s1(other: *TerminalWindow) void {\n        const take = comptime blk: {\n            var T: type = void;\n            T = @TypeOf(other.core_surface.renderer_state.mutex.*);\n            break :blk T.lock;\n        };\n        take(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33s1'), 'r33s1'))
if want(302): results.append(shape_control('302-SM1-S2-an-inferred-type-var-in-a-comptime-block',
    'const R33S2 = struct {\n    fn r33s2(other: *TerminalWindow) void {\n        const take = comptime blk: {\n            var T = @TypeOf(other.core_surface.renderer_state.mutex.*);\n            _ = &T;\n            break :blk T.lock;\n        };\n        take(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r33s2'), 'r33s2'))
# -- r33 (round 32's Sol M2, Opus L1): a typed alias of std, and a std head anywhere in the first argument
if want(303): results.append(residue_control('303-SM2-a-typed-alias-of-a-std-path-is-a-shim', write_into(
    "src/r33_shim.zig", 'const std = @import("std");\nconst Thread: type = std.Thread;\n\npub const has_mutex = @hasDecl(Thread, "Mutex");\n'),
    1, {"PRODUCTION-SHIM": 1}))
if want(304): results.append(residue_control('304-SM2-a-typed-alias-of-the-std-import-is-a-shim', write_into(
    "src/r33_shim.zig", 'const standard: type = @import("std");\n\npub const has_mutex = @hasDecl(standard.Thread, "Mutex");\n'),
    1, {"PRODUCTION-SHIM": 1}))
if want(305): results.append(residue_control('305-SM2-a-typed-alias-over-lines-with-comments-is-a-shim', write_into(
    "src/r33_shim.zig", 'const std = @import("std");\nconst Thread: // the namespace\n    type =\n    std.Thread;\n\npub const has_mutex = @hasDecl(\n    Thread, // here\n    "Mutex",\n);\n'),
    1, {"PRODUCTION-SHIM": 1}))
if want(306): results.append(residue_control('306-OL1-a-std-head-inside-the-first-argument-is-a-shim', write_into(
    "src/r33_shim.zig", 'const std = @import("std");\n\npub const has_mutex = @hasDecl(@field(std, "Thread"), "Mutex");\n'),
    1, {"PRODUCTION-SHIM": 1}))
if want(307): results.append(residue_control('307-OL1-the-same-over-lines-with-a-comment-is-a-shim', write_into(
    "src/r33_shim.zig", 'const std = @import("std");\n\npub const has_mutex = @hasDecl(@field(\n    std, // the namespace\n    "Thread",\n), "Mutex");\n'),
    1, {"PRODUCTION-SHIM": 1}))
# -- r34 (round 33's Opus M1, Sol M1 and the lead's direction): structure from the token stream, evidence explicit
# only. Each negative passed r33's tools with no row (logs\precheck34.txt): r33's res_index recorded each line of a
# method's multi-line parameter list as a member of its struct, over a field's type (Opus M1: E1, E2a, E2b; E2d, the
# StateMutex spelled out, was a site in both), and took an untyped `var`'s initializer for its type though the var
# is reassigned (Sol M1: RA). FD, a field whose default runs over several lines, is the positive (r33 did not read
# the field). Rebuilt from the findings' descriptions (shapes34.py; the letters are its own).
if want(308): results.append(shape_control('308-OM1-E1-an-unused-method-s-parameter-over-a-type-field',
    'const R34E1 = struct {\n    const Holder = struct {\n        lock: u8 = 0,\n    };\n    const Cfg = struct {\n        M: type,\n        fn unused(\n            M: Holder,\n        ) void {\n            _ = M;\n        }\n    };\n    fn r34e1(cfg: Cfg, other: *TerminalWindow) void {\n        const lock_fn = cfg.M.lock;\n        lock_fn(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r34e1'), 'r34e1'))
if want(309): results.append(shape_control('309-OM1-E2a-a-parameter-over-a-std-mutex-pointer-field',
    'const R34E2A = struct {\n    const Box = struct {\n        mutex: *std.Thread.Mutex,\n        fn put(\n            self: *Box,\n            mutex: std.Thread.Mutex,\n        ) void {\n            _ = self;\n            _ = mutex;\n        }\n    };\n    fn r34e2a(box: *Box) void {\n        box.mutex.lock();\n        defer box.mutex.unlock();\n    }\n};',
    unc31('r34e2a'), 'r34e2a'))
if want(310): results.append(shape_control('310-OM1-E2b-a-parameter-over-a-state-mutex-alias-pointer-field',
    'const R34E2B = struct {\n    const SM = rendererpkg.StateMutex;\n    const Box = struct {\n        mutex: *SM,\n        fn put(\n            self: *Box,\n            mutex: std.Thread.Mutex,\n        ) void {\n            _ = self;\n            _ = mutex;\n        }\n    };\n    fn r34e2b(box: *Box) void {\n        box.mutex.lock();\n        defer box.mutex.unlock();\n    }\n};',
    unc31('r34e2b'), 'r34e2b'))
if want(311): results.append(shape_control('311-OM1-E2d-a-parameter-over-a-state-mutex-pointer-field-spelled-out',
    'const R34E2D = struct {\n    const Box = struct {\n        mutex: *rendererpkg.StateMutex,\n        fn put(\n            self: *Box,\n            mutex: std.Thread.Mutex,\n        ) void {\n            _ = self;\n            _ = mutex;\n        }\n    };\n    fn r34e2d(box: *Box) void {\n        box.mutex.lock();\n        defer box.mutex.unlock();\n    }\n};',
    prod_exp('r34e2d'), 'r34e2d'))
if want(312): results.append(shape_control('312-OM1-FD-a-field-default-over-several-lines-is-a-field',
    'const R34FD = struct {\n    lock: bool = defaultLock(\n        0,\n    ),\n    fn defaultLock(n: u8) bool {\n        return n == 0;\n    }\n    fn r34fd(self: *R34FD) bool {\n        return self.lock;\n    }\n};',
    dict(rows=[], inv_exit=0, inv_delta={}, gate_exit=0, gate_kinds={}, cmp_exit=None, cmp_kinds={}), None))
if want(313): results.append(shape_control('313-SM1-RA-a-var-reassigned-after-a-decoy-initializer',
    'const R34RA = struct {\n    const Decoy = struct {\n        lock: u8 = 0,\n    };\n    fn r34ra(other: *TerminalWindow) void {\n        const take = comptime blk: {\n            var T = Decoy;\n            T = @TypeOf(other.core_surface.renderer_state.mutex.*);\n            break :blk T.lock;\n        };\n        take(other.core_surface.renderer_state.mutex);\n        defer other.core_surface.renderer_state.mutex.unlock();\n    }\n};',
    unc31('r34ra'), 'r34ra'))
# -- r34 (round 33's Sol M2, Opus L2 and the user's decision B): std origin a taint over declarations by scope
if want(314): results.append(residue_control('314-SM2-a-parenthesized-alias-of-std-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\nconst Thread: type = (std.Thread);\n\npub const has_mutex = @hasDecl(Thread, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(315): results.append(residue_control('315-SM2-the-same-over-lines-with-a-comment-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\nconst Thread: type = ( // the namespace\n    std.Thread\n);\n\npub const has_mutex = @hasDecl(Thread, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(316): results.append(residue_control('316-SM2-an-alias-through-field-of-std-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\nconst Thread = @field(std, "Thread");\n\npub const has_mutex = @hasDecl(Thread, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(317): results.append(residue_control('317-SM2-the-same-over-lines-with-a-comment-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\nconst Thread = @field(\n    std, // the namespace\n    "Thread",\n);\n\npub const has_mutex = @hasDecl(Thread, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
# -- r35 (round 34's Opus L1): 318 and 319 as valid Zig, a plain labelled block (a container-level `comptime blk:`
# is "redundant comptime" on both compilers)
if want(318): results.append(residue_control('318-SM2-a-destructuring-in-a-block-initializer-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\npub const has_mutex = blk: {\n    const Thread, const Io = .{ std.Thread, std.Io };\n    _ = Io;\n    break :blk @hasDecl(Thread, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(319): results.append(residue_control('319-SM2-the-same-over-lines-with-a-comment-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\npub const has_mutex = blk: {\n    const Thread, // the namespace\n    const Io = .{\n        std.Thread,\n        std.Io,\n    };\n    _ = Io;\n    break :blk @hasDecl(Thread, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(320): results.append(residue_control('320-OL2-an-alias-in-a-nested-struct-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\nconst S = struct {\n    const T = std.Thread;\n};\n\npub const has_mutex = @hasDecl(S.T, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(321): results.append(residue_control('321-OL2-the-same-over-lines-with-a-comment-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\nconst S = struct {\n    const T = // the namespace\n        std.Thread;\n};\n\npub const has_mutex = @hasDecl(\n    S // nested\n        .T,\n    "Mutex",\n);\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(322): results.append(residue_control('322-OL2-a-destructured-alias-in-a-function-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\npub fn hasMutex() bool {\n    const Thread, const Io = .{ std.Thread, std.Io };\n    _ = Io;\n    return @hasDecl(Thread, "Mutex");\n}\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(323): results.append(residue_control('323-OL2-the-same-over-lines-with-a-comment-is-a-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\npub fn hasMutex() bool {\n    const Thread, // the namespace\n        const Io =\n        .{ std.Thread, std.Io };\n    _ = Io;\n    return @hasDecl(\n        Thread, // here\n        "Mutex",\n    );\n}\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(324): results.append(residue_control('324-OS-a-name-std-taints-only-in-another-function-is-no-shim', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\nconst Local = struct {\n    pub const Mutex = u8;\n};\n\npub fn first() usize {\n    const Thread = std.Thread;\n    return @sizeOf(Thread.Id);\n}\n\npub fn second() bool {\n    const Thread = Local;\n    return @hasDecl(Thread, "Mutex");\n}\n'),
    0, {}))
if want(325): results.append(residue_control('325-CR-a-std-call-s-result-is-derived-from-r35', write_into(
    "src/r34_shim.zig", 'const std = @import("std");\nconst Pair = struct { a: u8, b: u8 };\nconst Field = std.meta.FieldEnum(Pair);\n\npub const has_a = @hasField(Field, "a");\n'),
    1, {'DERIVED-SHIM': 1}))   # r35 (round 34's Opus L2): a std call's result is derived, and r34_shim.zig has no row
# -- r35 (round 34's Opus M1, M2 and the lead's direction): one span tree by token range, every container kind; a
# switch capture's switch by token nesting. Each negative passed r34's tools with no row (logs\precheck35.txt);
# rebuilt from the findings' descriptions (shapes35.py; the letters are the findings').
if want(326): results.append(shape_control('326-OM1-A1-a-decoy-in-an-enum-body',
    'const R35A1 = struct {\n    var m: *std.Thread.Mutex = undefined;\n    const Inner = struct {\n        const Decoy = enum {\n            a,\n            var m: std.Thread.Mutex = .{};\n        };\n        fn r35a1() void {\n            _ = Decoy;\n            m.lock();\n            defer m.unlock();\n        }\n    };\n};',
    unc31('r35a1'), 'r35a1'))
if want(327): results.append(shape_control('327-OM1-A2-a-decoy-in-an-opaque-body',
    'const R35A2 = struct {\n    var m: *std.Thread.Mutex = undefined;\n    const Inner = struct {\n        const Decoy = opaque {\n            var m: std.Thread.Mutex = .{};\n        };\n        fn r35a2() void {\n            _ = Decoy;\n            m.lock();\n            defer m.unlock();\n        }\n    };\n};',
    unc31('r35a2'), 'r35a2'))
if want(328): results.append(shape_control('328-OM1-A4-a-decoy-on-the-line-its-container-opens',
    'const R35A4 = struct {\n    var m: *std.Thread.Mutex = undefined;\n    const Inner = struct {\n        const Decoy = struct { var m: std.Thread.Mutex = .{}; };\n        fn r35a4() void {\n            _ = Decoy;\n            m.lock();\n            defer m.unlock();\n        }\n    };\n};',
    unc31('r35a4'), 'r35a4'))
if want(329): results.append(shape_control('329-OM1-A5-an-opaque-decoy-in-the-function',
    'const R35A5 = struct {\n    var m: *std.Thread.Mutex = undefined;\n    fn r35a5() void {\n        const Decoy = opaque {\n            var m: std.Thread.Mutex = .{};\n        };\n        _ = Decoy;\n        m.lock();\n        defer m.unlock();\n    }\n};',
    unc31('r35a5'), 'r35a5'))
if want(330): results.append(shape_control('330-OM1-C1-a1-without-the-decoy',
    'const R35C1 = struct {\n    var m: *std.Thread.Mutex = undefined;\n    const Inner = struct {\n        fn r35c1() void {\n            m.lock();\n            defer m.unlock();\n        }\n    };\n};',
    unc31('r35c1'), 'r35c1'))
if want(331): results.append(shape_control('331-OM1-EP-an-enum-method-reads-its-own-declaration',
    'const R35EP = struct {\n    const E = enum {\n        a,\n        var m: std.Thread.Mutex = .{};\n        fn r35ep() void {\n            m.lock();\n            defer m.unlock();\n        }\n    };\n};',
    dict(rows=[], inv_exit=0, inv_delta={}, gate_exit=0, gate_kinds={}, cmp_exit=None, cmp_kinds={}), None))
if want(332): results.append(shape_control('332-OM2-B1-a-type-payload-read-through-an-earlier-prong-s-switch',
    'const R35B1 = struct {\n    const Holder = struct {\n        lock: u8 = 0,\n    };\n    const Fake = union(enum) { h: Holder, n: u8 };\n    const Real = union(enum) { h: type, n: u8 };\n    fn r35b1(comptime real: Real, fake: Fake, other: *TerminalWindow) void {\n        switch (real) {\n            .n => switch (fake) {\n                .h, .n => {},\n            },\n            .h => |H| {\n                const lock_fn = H.lock;\n                lock_fn(other.core_surface.renderer_state.mutex);\n                defer other.core_surface.renderer_state.mutex.unlock();\n            },\n        }\n    }\n};',
    unc31('r35b1'), 'r35b1'))
if want(333): results.append(shape_control('333-OM2-B2-a-state-mutex-payload-read-as-a-value-mutex',
    'const R35B2 = struct {\n    const Fake = union(enum) { s: std.Thread.Mutex, m: std.Thread.Mutex, n: u8 };\n    const Real = union(enum) { s: *rendererpkg.StateMutex, n: u8 };\n    fn r35b2(fake: Fake, real: Real) void {\n        switch (real) {\n            .n => switch (fake) {\n                .s, .m, .n => {},\n            },\n            .s => |m| {\n                m.lock();\n                defer m.unlock();\n            },\n        }\n    }\n};',
    unc31('r35b2'), 'r35b2'))
if want(334): results.append(shape_control('334-OM2-B3-a-mutex-pointer-payload-read-as-a-value-mutex',
    'const R35B3 = struct {\n    const Fake = union(enum) { m: std.Thread.Mutex, n: u8 };\n    const Real = union(enum) { m: *std.Thread.Mutex, n: u8 };\n    fn r35b3(fake: Fake, real: Real) void {\n        switch (real) {\n            .n => switch (fake) {\n                .m, .n => {},\n            },\n            .m => |m| {\n                m.lock();\n                defer m.unlock();\n            },\n        }\n    }\n};',
    unc31('r35b3'), 'r35b3'))
if want(335): results.append(shape_control('335-OM2-B4-a-payload-read-as-an-rwlock-is-no-other-lock',
    'const R35B4 = struct {\n    const Lock = rendererpkg.StateMutex;\n    const Fake = union(enum) { m: std.Thread.RwLock, n: u8 };\n    const Real = union(enum) { m: *Lock, n: u8 };\n    fn r35b4(fake: Fake, real: Real) void {\n        switch (real) {\n            .n => switch (fake) {\n                .m, .n => {},\n            },\n            .m => |m| {\n                m.lock();\n                defer m.unlock();\n            },\n        }\n    }\n};',
    unc31('r35b4'), 'r35b4'))
if want(336): results.append(shape_control('336-OM2-BP-a-value-mutex-payload-with-a-switch-inside-its-prong',
    'const R35BP = struct {\n    const U = union(enum) { m: std.Thread.Mutex, n: u8 };\n    const V = union(enum) { a: u8, b: u8 };\n    var u: U = .{ .n = 0 };\n    fn r35bp(v: V) void {\n        switch (u) {\n            .m => |*m| {\n                switch (v) {\n                    .a, .b => {},\n                }\n                m.lock();\n                defer m.unlock();\n            },\n            .n => {},\n        }\n    }\n};',
    dict(rows=[], inv_exit=0, inv_delta={}, gate_exit=0, gate_kinds={}, cmp_exit=None, cmp_kinds={}), None))
# -- r35 (round 34's Sol M1, M2, Opus M3, L2 and the lead's direction): std origin by category, the per-file scope


def both(*fs_):
    def f(root):
        for g_ in fs_:
            g_(root)
    return f


if want(337): results.append(residue_control('337-SM1-a-nested-alias-named-directly-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst Original = struct {\n    pub const T = std.Thread;\n};\n\npub const has_mutex = @hasDecl(Original.T, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(338): results.append(residue_control('338-SM1-a-container-alias-s-member-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst Original = struct {\n    pub const T = std.Thread;\n};\nconst Alias = Original;\n\npub const has_mutex = @hasDecl(Alias.T, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(339): results.append(residue_control('339-SM1-a-nested-container-alias-s-member-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst Original = struct {\n    pub const T = std.Thread;\n};\nconst Outer = struct {\n    pub const Inner = Original;\n};\n\npub const has_mutex = @hasDecl(Outer.Inner.T, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(340): results.append(residue_control('340-SM1-an-alias-through-a-literal-field-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst Original = struct {\n    pub const T = std.Thread;\n};\nconst Alias = @field(Original, "T");\n\npub const has_mutex = @hasDecl(Alias, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(341): results.append(residue_control('341-SM1-a-literal-field-in-the-feature-test-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst Original = struct {\n    pub const T = std.Thread;\n};\n\npub const has_mutex = @hasDecl(@field(Original, "T"), "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(342): results.append(residue_control('342-OM3-X2-a-struct-alias-s-member-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst S = struct {\n    pub const T = std.Thread;\n};\nconst S2 = S;\n\npub const has_mutex = @hasDecl(S2.T, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(343): results.append(residue_control('343-OM3-X3-a-member-through-this-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst S = struct {\n    const Self = @This();\n    pub const T = std.Thread;\n    pub const has_mutex = @hasDecl(Self.T, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(344): results.append(residue_control('344-OM3-R1-a-var-assigned-std-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\npub const has_mutex = blk: {\n    var T: type = u8;\n    T = std.Thread;\n    break :blk @hasDecl(T, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(345): results.append(residue_control('345-OM3-R2-the-same-over-lines-with-a-comment-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\npub const has_mutex = blk: {\n    var T: type = u8;\n    T = // the namespace\n        std.Thread;\n    break :blk @hasDecl(\n        T,\n        "Mutex",\n    );\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(346): results.append(residue_control('346-SM2-a-destructured-std-element-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\npub const has_mutex = blk: {\n    const Thread, const Local = .{ std.Thread, struct {\n        pub const own = true;\n    } };\n    _ = Local;\n    break :blk @hasDecl(Thread, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(347): results.append(residue_control('347-SM2-its-local-element-is-no-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\npub const has_own = blk: {\n    const Thread, const Local = .{ std.Thread, struct {\n        pub const own = true;\n    } };\n    _ = Thread;\n    break :blk @hasDecl(Local, "own");\n};\n'),
    0, {}))
if want(348): results.append(residue_control('348-SM2-the-local-element-over-lines-with-a-comment-is-no-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\npub const has_own = blk: {\n    const Thread, // the namespace\n    const Local = .{\n        std.Thread,\n        struct {\n            pub const own = true;\n        },\n    };\n    _ = Thread;\n    break :blk @hasDecl(Local, "own");\n};\n'),
    0, {}))
if want(349): results.append(residue_control('349-SM2-the-std-element-over-lines-with-a-comment-is-a-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\npub const has_mutex = blk: {\n    const Thread, // the namespace\n    const Local = .{\n        std.Thread,\n        struct {\n            pub const own = true;\n        },\n    };\n    _ = Local;\n    break :blk @hasDecl(\n        Thread, // here\n        "Mutex",\n    );\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(350): results.append(residue_control('350-SM2-an-element-the-gate-cannot-match-fails-unresolved', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nfn pair() struct { type, type } {\n    return .{ std.Thread, u8 };\n}\n\npub const has_mutex = blk: {\n    const Thread, const Other = pair();\n    _ = Other;\n    break :blk @hasDecl(Thread, "Mutex");\n};\n'),
    1, {'UNRESOLVED-DESTRUCTURING': 1}))
if want(351): results.append(residue_control('351-OL2-R3-a-helper-returning-std-is-derived', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nfn Helper() type {\n    return std.Thread;\n}\n\npub const has_mutex = @hasDecl(Helper(), "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))   # r37: a same-file call's result rests on fnref, outside the trusted set (r35, r36: derived)
if want(352): results.append(residue_control('352-OL2-R4-a-builtin-s-std-argument-is-derived', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst Handle = @FieldType(std.fs.File, "handle");\n\npub const is_int = @typeInfo(Handle) == .int;\n'),
    1, {'DERIVED-SHIM': 1}))
if want(353): results.append(residue_control('353-OL2-a-std-call-s-result-is-derived', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst Pair = struct { a: u8, b: u8 };\nconst Field = std.meta.FieldEnum(Pair);\n\npub const has_a = @hasField(Field, "a");\n'),
    1, {'DERIVED-SHIM': 1}))
if want(354): results.append(residue_control('354-OM3-X1-a-re-export-from-another-file-is-out-of-scope', both(write_into("src/compat.zig", 'const std = @import("std");\npub const Thread = std.Thread;\n'), write_into(
    "src/r35_shim.zig", 'const compat = @import("compat.zig");\n\npub const has_mutex = @hasDecl(compat.Thread, "Mutex");\n')),
    0, {}))
if want(355): results.append(residue_control('355-a-name-tainted-only-in-a-sibling-block-is-no-shim', write_into(
    "src/r35_shim.zig", 'const std = @import("std");\nconst Local = struct {\n    pub const Mutex = u8;\n};\n\npub const has_mutex = blk: {\n    {\n        const Thread = std.Thread;\n        _ = Thread;\n    }\n    const Thread = Local;\n    break :blk @hasDecl(Thread, "Mutex");\n};\n'),
    0, {}))
# -- r35 (round 34's Opus M2): the binding check reads "other" rows and field-read exemptions; crafted rows it must fail


def _field_undeclared(tag):
    ov = overlay("c" + tag[:3], {W32: append("const R35FR = struct {\n    fn r35fr(self: anytype) bool {\n"
                                           "        return self.lock;\n    }\n};")})
    text = open(os.path.join(ov, *W32.split("/")), encoding="utf-8").read()
    n0 = len(show(W32).splitlines())
    ln = next(i for i, l_ in enumerate(text.splitlines(), 1) if i > n0 and l_.strip() == "return self.lock;")
    prefix = os.path.join(logdir, "inv-" + tag[:3])
    open(prefix + "-fieldreads.tsv", "w", encoding="utf-8", newline="\n").write(f"{rev}\t{W32}\t{ln}\tself\tlock\tfield\n")
    return bindcheck_control(tag, prefix, ov, 1, ("FIELD-NOT-DECLARED",), {"FIELD-NOT-DECLARED": 1})


def _other_twice(tag):
    blk = ("        {\n            var m: std.Thread.RwLock = .{};\n            m.lock();\n"
           "            defer m.unlock();\n        }\n")
    ov = overlay("c" + tag[:3], {W32: append(wrap31("r35o", blk + blk))})
    text = open(os.path.join(ov, *W32.split("/")), encoding="utf-8").read()
    n0 = len(show(W32).splitlines())
    ln = next(i for i, l_ in enumerate(text.splitlines(), 1) if i > n0 and l_.strip() == "m.lock();")
    prefix = os.path.join(logdir, "inv-" + tag[:3])
    open(prefix + "-other.tsv", "w", encoding="utf-8", newline="\n").write(
        f'{rev}\t{W32}\t{ln}\tr35o\tlock\tm\t@import("std").Thread.RwLock\n')
    return bindcheck_control(tag, prefix, ov, 1, ("BIND-TWICE",), {"BIND-TWICE": 1})


if FULL and want(356): results.append(_field_undeclared("356-OM2-a-field-read-row-whose-op-no-container-declares"))
if FULL and want(357): results.append(_other_twice("357-OM2-an-other-row-whose-receiver-two-sibling-blocks-bind"))
# -- r35 (the user's option 1): the 1B proxies with the bundle, their derived rows exactly (proxy_ok)
if want(358): results.append(residue_control("358-the-1b-proxy-trial-hybrid-140-s-derived-rows", None, 1, None,
                                              tree="trial-hybrid-140",
                                              check=lambda k_, o_: proxy_ok(k_, o_, "trial-hybrid-140")))
if want(359): results.append(residue_control("359-the-1b-proxy-trial-ours-140-s-derived-rows", None, 1, None,
                                              tree="trial-ours-140", check=lambda k_, o_: proxy_ok(k_, o_, "trial-ours-140")))
# -- r36 (round 35's Sol M1 to M3, Opus M1, M2 and the lead's direction): default-deny origin; every seat's shape
# a negative control with its local twin (residue_shapes36.py); r37 to r45: with the gate's outcomes and rows as
# expect45.py measures them (expect45_out.py)
# -- r37 (round 36's Sol M1 to M3, Opus M1 to M3 and the lead's direction): the trusted set; every shape a negative
# with its local twin (residue_shapes37.py), a twin whose form rests on a rule outside the trusted set, or that a
# soundness rule leaves unresolved, carrying its exact row; 484 to 497 the lead's self-review before the self-test,
# 498 to 503 the lead's decision after it (the nonliteral @field rule in every file)
# -- r38 (round 37's Sol M1, M2, Opus M1, M2 and the lead's direction): the machinery under the trusted rows; every
# shape a negative with its local twin (residue_shapes38.py): a break operand at its prong's comma and the
# comparison-to-constant control beside it (504 to 507), an address after a break label (508, 509), destructuring
# a local value's elements (510 to 515), a var's writes the scan missed (516 to 523)
# -- r39 (round 38's Sol M1, M2, L1, Opus M1 to M3, L1 and the lead's direction): Zig's own parse; every shape a
# negative with its local twin (residue_shapes39.py): an operand past an `else` (530 to 535, 548 to 555), a
# destructuring's index and field targets (536 to 547), `*volatile const` (556, 557), the F5 pins (558 to 561), the
# method-call receiver (562, 563), a file the pinned compiler rejects (564 to 567), an array literal's element
# type (576 to 579, found by r39's per-rule comparison with r38)
# -- r40 (round 39's Opus M1, M2 and the lead's direction): every parent an occurrence meets classified, the labelled
# switch joined; every shape a negative with its local twin (residue_shapes40.py): an assignment, an address, a
# destructuring and a pointer capture through a parent that hands the place on (580 to 611), a method-call
# receiver through one (612, 613), a labelled switch's break and continue (614 to 617), and the regression
# sweep, the labelled switch r39 modelled where r38 failed closed (618 to 625)
# -- r41 (round 40's Sol M1, Opus M1, M2 and the lead's direction): the place walk without a depth limit, held to
# every write and address, and AstGen's break binding; every shape a negative with its local twin
# (residue_shapes41.py): an assignment and a destructuring target 200, 201 and 1000 groupings deep and a 300-deep
# mixed chain (636 to 649), A1 to A7, an unlabelled break in a loop's else, a while's condition or a for's input
# that leaves the enclosing loop (650 to 663), and a labelled break from an else to its own label (664)
# -- r42 (round 41's Opus M1 and L1): Zig files r41 skipped or did not reach (residue_shapes42.py): a .zig file
# with one Latin-1 byte and a 0.15.2 comment fails NOT-TEXT, the same byte as UTF-8 fails on the mention (674,
# 675); a feature test on std in test/windows/ fails PRODUCTION-SHIM, a local one passes (676, 677)
# -- r43 (round 42's Opus L1, L2 and the user's decision on item 6; residue_shapes43.py): a feature test on std in
# a nested zig-out/ fails PRODUCTION-SHIM, the same file in the root's zig-out/ passes (770, 771); a file with a
# UTF-16 or UTF-32 byte-order mark is scanned by its code units and its bytes: Opus's UTF-16LE script, a lone
# surrogate before the mention, an odd-length UTF-16BE file and a UTF-32LE file each fail RESIDUE-015, each twin
# passes (772 to 779)
if want(360): results.append(residue_control('360-SM1-an-unbraced-if-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (true) // the branch\n        T = // the namespace\n            std.mem;\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(361): results.append(residue_control('361-SM1-an-unbraced-if-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (true) // the branch\n        T = // the namespace\n            Local;\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(362): results.append(residue_control('362-SM1-an-unbraced-else-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (false) {} else // the branch\n        T =\n            std.mem;\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(363): results.append(residue_control('363-SM1-an-unbraced-else-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (false) {} else // the branch\n        T =\n            Local;\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(364): results.append(residue_control('364-SM1-a-braced-if-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (true) {\n        // the branch\n        T =\n            std.mem;\n    }\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(365): results.append(residue_control('365-SM1-a-braced-if-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (true) {\n        // the branch\n        T =\n            Local;\n    }\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(366): results.append(residue_control('366-SM1-a-braced-else-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (false) {} else {\n        T = std.mem; // the namespace\n    }\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(367): results.append(residue_control('367-SM1-a-braced-else-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (false) {} else {\n        T = Local; // the namespace\n    }\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(368): results.append(residue_control('368-SM2-an-8-alias-chain', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\nconst A0 = Original;\nconst A1 = A0;\nconst A2 = A1;\nconst A3 = A2;\nconst A4 = A3;\nconst A5 = A4;\nconst A6 = A5;\nconst A7 = A6;\npub const has = @hasDecl(A7.T, "eql");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(369): results.append(residue_control('369-SM2-an-8-alias-chain-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\nconst A0 = Original;\nconst A1 = A0;\nconst A2 = A1;\nconst A3 = A2;\nconst A4 = A3;\nconst A5 = A4;\nconst A6 = A5;\nconst A7 = A6;\npub const has = @hasDecl(A7.T, "eql");\n'),
    0, {}))
if want(370): results.append(residue_control('370-SM2-a-12-alias-chain', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\nconst A0 = Original;\nconst A1 = A0;\nconst A2 = A1;\nconst A3 = A2;\nconst A4 = A3;\nconst A5 = A4;\nconst A6 = A5;\nconst A7 = A6;\nconst A8 = A7;\nconst A9 = A8;\nconst A10 = A9;\nconst A11 = A10;\npub const has = @hasDecl(A11.T, "eql");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(371): results.append(residue_control('371-SM2-a-12-alias-chain-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\nconst A0 = Original;\nconst A1 = A0;\nconst A2 = A1;\nconst A3 = A2;\nconst A4 = A3;\nconst A5 = A4;\nconst A6 = A5;\nconst A7 = A6;\nconst A8 = A7;\nconst A9 = A8;\nconst A10 = A9;\nconst A11 = A10;\npub const has = @hasDecl(A11.T, "eql");\n'),
    0, {}))
if want(372): results.append(residue_control('372-SM2-an-alias-cycle-is-unresolved', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst A0 = A1;\nconst A1 = A0;\npub const has = @hasDecl(A0.T, "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(373): results.append(residue_control('373-SM2-an-alias-cycle-is-unresolved-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst A0 = A1;\nconst A1 = A0;\npub const has = @hasDecl(A0.T, "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(374): results.append(residue_control('374-SM3-a-direct-call-of-a-helper-returning-std', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nfn make() type {\n    return std.mem;\n}\npub const has = @hasDecl(make(), "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(375): results.append(residue_control('375-SM3-a-direct-call-of-a-helper-returning-std-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nfn make() type {\n    return Local;\n}\npub const has = @hasDecl(make(), "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(376): results.append(residue_control('376-SM3-a-function-alias', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nfn make() type {\n    return std.mem;\n}\nconst maker = make;\npub const has = @hasDecl(maker(), "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(377): results.append(residue_control('377-SM3-a-function-alias-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nfn make() type {\n    return Local;\n}\nconst maker = make;\npub const has = @hasDecl(maker(), "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(378): results.append(residue_control('378-SM3-a-function-alias-chain', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nfn make() type {\n    return std.mem;\n}\nconst m1 = make;\nconst m2 = m1;\npub const has = @hasDecl(m2(), "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(379): results.append(residue_control('379-SM3-a-function-alias-chain-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nfn make() type {\n    return Local;\n}\nconst m1 = make;\nconst m2 = m1;\npub const has = @hasDecl(m2(), "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(380): results.append(residue_control('380-OM1-if-true-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (true) T = std.mem;\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(381): results.append(residue_control('381-OM1-if-true-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (true) T = Local;\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(382): results.append(residue_control('382-OM1-else-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (false) {} else T = std.mem;\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(383): results.append(residue_control('383-OM1-else-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    if (false) {} else T = Local;\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(384): results.append(residue_control('384-OM1-a-switch-prong-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    const k: u8 = 0;\n    switch (k) {\n        else => T = std.mem,\n    }\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(385): results.append(residue_control('385-OM1-a-switch-prong-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    const k: u8 = 0;\n    switch (k) {\n        else => T = Local,\n    }\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(386): results.append(residue_control('386-OM1-a-continue-expression-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    var i: usize = 0;\n    while (i < 1) : (T = std.mem) {\n        i += 1;\n    }\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(387): results.append(residue_control('387-OM1-a-continue-expression-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    var i: usize = 0;\n    while (i < 1) : (T = Local) {\n        i += 1;\n    }\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(388): results.append(residue_control('388-OM1-a-destructuring-assignment', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    var U: type = u8;\n    T, U = .{ std.mem, u16 };\n    break :blk @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(389): results.append(residue_control('389-OM1-a-destructuring-assignment-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var T: type = u8;\n    var U: type = u8;\n    T, U = .{ Local, u16 };\n    break :blk @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(390): results.append(residue_control('390-OM1-a-parenthesised-alias', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\nconst S = (Original);\npub const has = @hasDecl(S.T, "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(391): results.append(residue_control('391-OM1-a-parenthesised-alias-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\nconst S = (Original);\npub const has = @hasDecl(S.T, "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(392): results.append(residue_control('392-OM1-an-as-alias', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\nconst S = @as(type, Original);\npub const has = @hasDecl(S.T, "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(393): results.append(residue_control('393-OM1-an-as-alias-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\nconst S = @as(type, Original);\npub const has = @hasDecl(S.T, "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(394): results.append(residue_control('394-OM1-a-labelled-block-alias', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\nconst S = blk: {\n    break :blk Original;\n};\npub const has = @hasDecl(S.T, "eql");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(395): results.append(residue_control('395-OM1-a-labelled-block-alias-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\nconst S = blk: {\n    break :blk Original;\n};\npub const has = @hasDecl(S.T, "eql");\n'),
    0, {}))
if want(396): results.append(residue_control('396-OM1-this-headed-chain', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n    pub const has = @hasDecl(@This().T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(397): results.append(residue_control('397-OM1-this-headed-chain-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n    pub const has = @hasDecl(@This().T, "eql");\n};\n'),
    0, {}))
if want(398): results.append(residue_control('398-OM1-a-parenthesised-head', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\npub const has = @hasDecl((Original).T, "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(399): results.append(residue_control('399-OM1-a-parenthesised-head-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\npub const has = @hasDecl((Original).T, "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(400): results.append(residue_control('400-OM1-an-as-head', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\npub const has = @hasDecl(@as(type, Original).T, "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(401): results.append(residue_control('401-OM1-an-as-head-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\npub const has = @hasDecl(@as(type, Original).T, "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(402): results.append(residue_control('402-OM1-a-returned-container', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\nfn get() type {\n    return Original;\n}\npub const has = @hasDecl(get().T, "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(403): results.append(residue_control('403-OM1-a-returned-container-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\nfn get() type {\n    return Original;\n}\npub const has = @hasDecl(get().T, "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(404): results.append(residue_control('404-OM1-an-if-expression-alias', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst T = if (true) std.mem else u8;\npub const has = @hasDecl(T, "eql");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(405): results.append(residue_control('405-OM1-an-if-expression-alias-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst T = if (true) Local else u8;\npub const has = @hasDecl(T, "eql");\n'),
    0, {}))
if want(406): results.append(residue_control('406-OM1-a-var-assigned-a-container', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\npub const has = blk: {\n    var S2: type = u8;\n    S2 = Original;\n    break :blk @hasDecl(S2.T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(407): results.append(residue_control('407-OM1-a-var-assigned-a-container-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\npub const has = blk: {\n    var S2: type = u8;\n    S2 = Original;\n    break :blk @hasDecl(S2.T, "eql");\n};\n'),
    0, {}))
if want(408): results.append(residue_control('408-OM1-a-comptime-field-default', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Holder = struct {\n    comptime T: type = std.mem,\n};\npub const has = @hasDecl((Holder{}).T, "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(409): results.append(residue_control('409-OM1-a-comptime-field-default-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Holder = struct {\n    comptime T: type = Local,\n};\npub const has = @hasDecl((Holder{}).T, "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(410): results.append(residue_control('410-OM1-a-tuple-index', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\nconst tup = .{Original};\npub const has = @hasDecl(tup[0].T, "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(411): results.append(residue_control('411-OM1-a-tuple-index-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\nconst tup = .{Original};\npub const has = @hasDecl(tup[0].T, "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(412): results.append(residue_control('412-OM1-a-field-name-from-a-const', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = std.mem;\n};\nconst name = "T";\npub const has = @hasDecl(@field(Original, name), "eql");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(413): results.append(residue_control('413-OM1-a-field-name-from-a-const-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst Original = struct {\n    pub const T = Local;\n};\nconst name = "T";\npub const has = @hasDecl(@field(Original, name), "eql");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(414): results.append(residue_control('414-OM1-a-for-capture', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var r = false;\n    for (.{std.mem}) |M| {\n        r = r or @hasDecl(M, "eql");\n    }\n    break :blk r;\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(415): results.append(residue_control('415-OM1-a-for-capture-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\npub const has = blk: {\n    var r = false;\n    for (.{Local}) |M| {\n        r = r or @hasDecl(M, "eql");\n    }\n    break :blk r;\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(416): results.append(residue_control('416-OM1-an-if-capture-over-an-optional', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst maybe: ?type = std.mem;\npub const has = if (maybe) |M| @hasDecl(M, "eql") else false;\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(417): results.append(residue_control('417-OM1-an-if-capture-over-an-optional-local-twin', both(write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst maybe: ?type = Local;\npub const has = if (maybe) |M| @hasDecl(M, "eql") else false;\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r36_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(418): results.append(residue_control('418-OM1-a-helper-taking-a-parameter-is-the-param-boundary', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nfn has(comptime T: type, comptime n: []const u8) bool {\n    return @hasDecl(T, n);\n}\npub const ok = has(std.mem, "eql");\n'),
    0, {}))
if want(419): results.append(residue_control('419-OM1-a-helper-taking-a-parameter-is-the-param-boundary-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nfn has(comptime T: type, comptime n: []const u8) bool {\n    return @hasDecl(T, n);\n}\npub const ok = has(Local, "eql");\n'),
    0, {}))
if want(420): results.append(residue_control('420-OM2-zig-version-through-a-literal-field', write_into('src/r36_shim.zig', 'const builtin = @import("builtin");\npub const old = @field(builtin, "zig_version").minor < 17;\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(421): results.append(residue_control('421-OM2-zig-version-through-a-literal-field-local-twin', write_into('src/r36_shim.zig', 'const builtin = @import("builtin");\npub const is_windows = @field(builtin, "os").tag == .windows;\n'),
    0, {}))
if want(422): results.append(residue_control('422-OM2-zig-version-through-an-escaped-literal-field', write_into('src/r36_shim.zig', 'const builtin = @import("builtin");\npub const old = @field(builtin, "zig_\\x76ersion").minor < 17;\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(423): results.append(residue_control('423-OM2-zig-version-through-an-escaped-literal-field-local-twin', write_into('src/r36_shim.zig', 'const builtin = @import("builtin");\npub const is_windows = @field(builtin, "o\\x73").tag == .windows;\n'),
    0, {}))
if want(424): results.append(residue_control('424-OM2-zig-version-string-outside-the-version-printer', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst builtin = @import("builtin");\npub fn version() !std.SemanticVersion {\n    return std.SemanticVersion.parse(builtin.zig_version_string);\n}\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(425): results.append(residue_control('425-OM2-zig-version-string-outside-the-version-printer-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\npub fn version() !std.SemanticVersion {\n    return std.SemanticVersion.parse("1.4.0");\n}\n'),
    0, {}))
if want(426): results.append(residue_control('426-OM2-a-non-literal-field-name-on-builtin-is-unresolved', write_into('src/r36_shim.zig', 'const builtin = @import("builtin");\nconst name = "zig_" ++ "version";\npub const old = @field(builtin, name).minor < 17;\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(427): results.append(residue_control('427-OM2-a-non-literal-field-name-on-builtin-is-unresolved-local-twin', write_into('src/r36_shim.zig', 'const Info = struct {\n    pub const minor = 17;\n};\nconst name = "mi" ++ "nor";\npub const old = @field(Info, name) < 17;\n'),
    0, {}))
if want(428): results.append(residue_control('428-a-declaration-after-a-field', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst S = struct {\n    x: u8,\n    const T = std.mem;\n    pub const has = @hasDecl(T, "eql");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(429): results.append(residue_control('429-a-declaration-after-a-field-local-twin', write_into('src/r36_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\nconst S = struct {\n    x: u8,\n    const T = Local;\n    pub const has = @hasDecl(T, "eql");\n};\n'),
    0, {}))
if want(432): results.append(residue_control('432-SM1-as-takes-its-type', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst T = @TypeOf(@as(std.Thread, undefined));\npub const Mutex = if (@hasDecl(T, "Mutex")) T.Mutex else u8;\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(433): results.append(residue_control('433-SM1-as-takes-its-type-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst T = @TypeOf(@as(Local, undefined));\npub const Mutex = if (@hasDecl(T, "Mutex")) T.Mutex else u8;\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(434): results.append(residue_control('434-SM2-a-write-through-an-address', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    const p = &Ns;\n    p.* = std.Thread;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(435): results.append(residue_control('435-SM2-a-write-through-an-address-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    const p = &Ns;\n    p.* = Local;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(436): results.append(residue_control('436-SM2-a-write-through-an-aliased-address', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    const p = &Ns;\n    const q = p;\n    q.* = std.Thread;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(437): results.append(residue_control('437-SM2-a-write-through-an-aliased-address-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    const p = &Ns;\n    const q = p;\n    q.* = Local;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(438): results.append(residue_control('438-SM2-a-write-through-a-chained-address', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    var p = &Ns;\n    const pp = &p;\n    pp.*.* = std.Thread;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(439): results.append(residue_control('439-SM2-a-write-through-a-chained-address-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    var p = &Ns;\n    const pp = &p;\n    pp.*.* = Local;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(440): results.append(residue_control('440-SM3-a-returned-builtin-s-nonliteral-field', write_into('src/r37_shim.zig', 'const builtin = @import("builtin");\nfn get() type {\n    return builtin;\n}\nconst name = "zig_" ++ "version";\npub const old = @field(get(), name).minor < 17;\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(441): results.append(residue_control('441-SM3-a-returned-builtin-s-nonliteral-field-local-twin', both(write_into('src/r37_shim.zig', 'const builtin = @import("builtin");\npub const os = builtin.os.tag;\nconst Info = struct {\n    pub const minor = 17;\n};\nfn get() type {\n    return Info;\n}\nconst name = "mi" ++ "nor";\npub const old = @field(get(), name) < 17;\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(442): results.append(residue_control('442-OM1-an-optional-type-field', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: ?type,\n};\npub const has = @hasDecl((Box{ .t = std.Thread }).t.?, "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(443): results.append(residue_control('443-OM1-an-optional-type-field-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: ?type,\n};\npub const has = @hasDecl((Box{ .t = Local }).t.?, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(444): results.append(residue_control('444-OM1-an-optional-type-field-s-default', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: ?type = std.Thread,\n};\npub const has = @hasDecl((Box{}).t.?, "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(445): results.append(residue_control('445-OM1-an-optional-type-field-s-default-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: ?type = Local,\n};\npub const has = @hasDecl((Box{}).t.?, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(446): results.append(residue_control('446-OM1-an-array-of-type-field', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: [1]type,\n};\npub const has = @hasDecl((Box{ .t = .{std.Thread} }).t[0], "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(447): results.append(residue_control('447-OM1-an-array-of-type-field-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: [1]type,\n};\npub const has = @hasDecl((Box{ .t = .{Local} }).t[0], "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(448): results.append(residue_control('448-OM1-a-parenthesised-type-field', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: (type),\n};\npub const has = @hasDecl((Box{ .t = std.Thread }).t, "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(449): results.append(residue_control('449-OM1-a-parenthesised-type-field-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: (type),\n};\npub const has = @hasDecl((Box{ .t = Local }).t, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(450): results.append(residue_control('450-OM1-a-field-typed-by-an-alias-of-type', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Ty = type;\nconst Box = struct {\n    t: Ty,\n};\npub const has = @hasDecl((Box{ .t = std.Thread }).t, "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(451): results.append(residue_control('451-OM1-a-field-typed-by-an-alias-of-type-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Ty = type;\nconst Box = struct {\n    t: Ty,\n};\npub const has = @hasDecl((Box{ .t = Local }).t, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(452): results.append(residue_control('452-OM1-a-decl-literal-s-field', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: ?type,\n    const d: Box = .{ .t = std.Thread };\n};\nconst b: Box = .d;\npub const has = @hasDecl(b.t.?, "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(453): results.append(residue_control('453-OM1-a-decl-literal-s-field-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    t: ?type,\n    const d: Box = .{ .t = Local };\n};\nconst b: Box = .d;\npub const has = @hasDecl(b.t.?, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(454): results.append(residue_control('454-OM1-a-returned-parameter-chain', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn get(comptime X: type) type {\n    return X.Thread;\n}\nconst Ns = struct {\n    pub const Thread = std.Thread;\n};\npub const has = @hasDecl(get(Ns), "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(455): results.append(residue_control('455-OM1-a-returned-parameter-chain-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn get(comptime X: type) type {\n    return X.Thread;\n}\nconst Ns = struct {\n    pub const Thread = Local;\n};\npub const has = @hasDecl(get(Ns), "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(456): results.append(residue_control('456-OM1-a-generic-s-parameter-at-file-scope', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn Gen(comptime T: type) type {\n    return struct {\n        pub const P = T;\n    };\n}\nconst Ns = struct {\n    pub const Thread = std.Thread;\n};\npub const has = @hasDecl(Gen(Ns).P.Thread, "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(457): results.append(residue_control('457-OM1-a-generic-s-parameter-at-file-scope-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn Gen(comptime T: type) type {\n    return struct {\n        pub const P = T;\n    };\n}\nconst Ns = struct {\n    pub const Thread = Local;\n};\npub const has = @hasDecl(Gen(Ns).P.Thread, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(458): results.append(residue_control('458-OM1-an-unresolved-argument-is-joined', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn Wrap(comptime T: type) type {\n    return struct {\n        pub const X = T;\n    };\n}\nconst Holder = struct {\n    comptime t: type = std.Thread,\n};\npub const has = @hasDecl(Wrap((Holder{}).t).X, "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(459): results.append(residue_control('459-OM1-an-unresolved-argument-is-joined-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn Wrap(comptime T: type) type {\n    return struct {\n        pub const X = T;\n    };\n}\nconst Holder = struct {\n    comptime t: type = Local,\n};\npub const has = @hasDecl(Wrap((Holder{}).t).X, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(460): results.append(residue_control('460-OM1-an-index-of-a-tuple-instance', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Pair = struct { type };\npub const has = @hasDecl((Pair{std.Thread})[0], "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(461): results.append(residue_control('461-OM1-an-index-of-a-tuple-instance-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Pair = struct { type };\npub const has = @hasDecl((Pair{Local})[0], "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(462): results.append(residue_control('462-OM1-a-fn-type-in-an-if-hides-no-return', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn get() type {\n    if (@as(?*const fn () void, null) == null) {\n        return std.Thread;\n    }\n    return u8;\n}\npub const has = @hasDecl(get(), "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(463): results.append(residue_control('463-OM1-a-fn-type-in-an-if-hides-no-return-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn get() type {\n    if (@as(?*const fn () void, null) == null) {\n        return Local;\n    }\n    return u8;\n}\npub const has = @hasDecl(get(), "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(464): results.append(residue_control('464-OM1-a-labelled-return-type', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn get() blk: {\n    break :blk type;\n} {\n    return std.Thread;\n}\npub const has = @hasDecl(get(), "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(465): results.append(residue_control('465-OM1-a-labelled-return-type-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn get() blk: {\n    break :blk type;\n} {\n    return Local;\n}\npub const has = @hasDecl(get(), "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(466): results.append(residue_control('466-OM1-a-pointer-capture-over-an-address', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var ts = [_]type{u8};\n    for (&ts) |*p| p.* = std.Thread;\n    break :blk @hasDecl(ts[0], "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(467): results.append(residue_control('467-OM1-a-pointer-capture-over-an-address-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var ts = [_]type{u8};\n    for (&ts) |*p| p.* = Local;\n    break :blk @hasDecl(ts[0], "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(468): results.append(residue_control('468-OM1-a-swap-through-addresses', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var a: type = u8;\n    var b: type = std.Thread;\n    std.mem.swap(type, &a, &b);\n    break :blk @hasDecl(a, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(469): results.append(residue_control('469-OM1-a-swap-through-addresses-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var a: type = u8;\n    var b: type = Local;\n    std.mem.swap(type, &a, &b);\n    break :blk @hasDecl(a, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(470): results.append(residue_control('470-OM2-a-comptime-field-s-builtin', write_into('src/r37_shim.zig', 'const builtin = @import("builtin");\nconst Holder = struct {\n    comptime b: type = builtin,\n};\npub const old = @field((Holder{}).b, "zig_" ++ "version").minor < 17;\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(471): results.append(residue_control('471-OM2-a-comptime-field-s-builtin-local-twin', both(write_into('src/r37_shim.zig', 'const builtin = @import("builtin");\npub const os = builtin.os.tag;\nconst Info = struct {\n    pub const minor = 17;\n};\nconst Holder = struct {\n    comptime b: type = Info,\n};\npub const old = @field((Holder{}).b, "mi" ++ "nor") < 17;\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(472): results.append(residue_control('472-OM2-an-optional-field-s-builtin', write_into('src/r37_shim.zig', 'const builtin = @import("builtin");\nconst Holder = struct {\n    b: ?type = builtin,\n};\npub const old = @field((Holder{}).b.?, "zig_" ++ "version").minor < 17;\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(473): results.append(residue_control('473-OM2-an-optional-field-s-builtin-local-twin', both(write_into('src/r37_shim.zig', 'const builtin = @import("builtin");\npub const os = builtin.os.tag;\nconst Info = struct {\n    pub const minor = 17;\n};\nconst Holder = struct {\n    b: ?type = Info,\n};\npub const old = @field((Holder{}).b.?, "mi" ++ "nor") < 17;\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(474): results.append(residue_control('474-OM3-a-quoted-hasfn', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = std.meta.@"hasFn"(std.Thread, "spawn");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(475): results.append(residue_control('475-OM3-a-quoted-hasfn-local-twin', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = std.meta.@"hasFn"(Local, "spawn");\n'),
    0, {}))
if want(476): results.append(residue_control('476-OM3-an-alias-of-hasfn', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst has = std.meta.hasFn;\npub const ok = has(std.Thread, "spawn");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(477): results.append(residue_control('477-OM3-an-alias-of-hasfn-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst has = std.meta.hasFn;\npub const ok = has(Local, "spawn");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(478): results.append(residue_control('478-OM3-hasfn-through-call', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const ok = @call(.auto, std.meta.hasFn, .{ std.Thread, "spawn" });\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(479): results.append(residue_control('479-OM3-hasfn-through-call-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const ok = @call(.auto, std.meta.hasFn, .{ Local, "spawn" });\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(484): results.append(residue_control('484-LR-an-address-through-parentheses', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    const p = &(Ns);\n    p.* = std.Thread;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(485): results.append(residue_control('485-LR-an-address-through-parentheses-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    const p = &(Ns);\n    p.* = Local;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(486): results.append(residue_control('486-LR-an-address-after-an-if-condition', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    var Other: type = u8;\n    const c = true;\n    const p = if (c) &Ns else &Other;\n    p.* = std.Thread;\n    Other = u16;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(487): results.append(residue_control('487-LR-an-address-after-an-if-condition-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    var Other: type = u8;\n    const c = true;\n    const p = if (c) &Ns else &Other;\n    p.* = Local;\n    Other = u16;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(488): results.append(residue_control('488-LR-an-assignment-through-parentheses', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    (Ns) = std.Thread;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(489): results.append(residue_control('489-LR-an-assignment-through-parentheses-local-twin', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    (Ns) = Local;\n    break :blk @hasDecl(Ns, "Mutex");\n};\n'),
    0, {}))
if want(490): results.append(residue_control('490-LR-a-destructuring-assignment-through-parentheses', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    var Other: type = u8;\n    (Ns), Other = .{ std.Thread, u16 };\n    break :blk @hasDecl(Ns, "Mutex") and Other == u16;\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(491): results.append(residue_control('491-LR-a-destructuring-assignment-through-parentheses-local-twin', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var Ns: type = u8;\n    var Other: type = u8;\n    (Ns), Other = .{ Local, u16 };\n    break :blk @hasDecl(Ns, "Mutex") and Other == u16;\n};\n'),
    0, {}))
if want(492): results.append(residue_control('492-LR-a-hasfn-named-by-a-literal-field', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = @field(std.meta, "hasFn")(std.Thread, "spawn");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(493): results.append(residue_control('493-LR-a-hasfn-named-by-a-literal-field-local-twin', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = @field(std.meta, "hasFn")(Local, "spawn");\n'),
    0, {}))
if want(494): results.append(residue_control('494-LR-a-hasfn-reference-by-a-literal-field', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst has = @field(std.meta, "hasFn");\npub const ok = has(std.Thread, "spawn");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(495): results.append(residue_control('495-LR-a-hasfn-reference-by-a-literal-field-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst has = @field(std.meta, "hasFn");\npub const ok = has(Local, "spawn");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(496): results.append(residue_control('496-LR-the-type-of-a-builtin-s-value', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst info = @typeInfo(u8);\npub const has = @hasDecl(@TypeOf(info), "Fn");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(497): results.append(residue_control('497-LR-the-type-of-a-builtin-s-value-local-twin', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst info: Local = .{};\npub const has = @hasDecl(@TypeOf(info), "Mutex");\n'),
    0, {}))
if want(498): results.append(residue_control('498-LD-hasfn-by-a-computed-name-on-std', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst n = "has" ++ "Fn";\npub const has = @field(std.meta, n)(std.Thread, "spawn");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(499): results.append(residue_control('499-LD-hasfn-by-a-computed-name-on-std-local-twin', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Meta = struct {\n    pub fn hasFn(comptime T: type, comptime name: []const u8) bool {\n        _ = T;\n        _ = name;\n        return true;\n    }\n};\nconst n = "has" ++ "Fn";\npub const has = @field(Meta, n)(Local, "spawn");\n'),
    0, {}))
if want(500): results.append(residue_control('500-LD-hasfn-by-a-computed-name-on-a-derived-object', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst n = "has" ++ "Fn";\npub const has = @field(std.meta.Child(*const std.meta), n)(std.Thread, "spawn");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(501): results.append(residue_control('501-LD-hasfn-by-a-computed-name-on-a-derived-object-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Meta = struct {\n    pub fn hasFn(comptime T: type, comptime name: []const u8) bool {\n        _ = T;\n        _ = name;\n        return true;\n    }\n};\nfn Child(comptime P: type) type {\n    return @typeInfo(P).pointer.child;\n}\nconst n = "has" ++ "Fn";\npub const has = @field(Child(*const Meta), n)(Local, "spawn");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(502): results.append(residue_control('502-LD-hasfn-by-a-computed-name-on-an-address-taken-var', write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var M: type = u8;\n    const p = &M;\n    p.* = std.meta;\n    break :blk @field(M, "has" ++ "Fn")(std.Thread, "spawn");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(503): results.append(residue_control('503-LD-hasfn-by-a-computed-name-on-an-address-taken-var-local-twin', both(write_into('src/r37_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Meta = struct {\n    pub fn hasFn(comptime T: type, comptime name: []const u8) bool {\n        _ = T;\n        _ = name;\n        return true;\n    }\n};\npub const has = blk: {\n    var M: type = u8;\n    const p = &M;\n    p.* = Meta;\n    break :blk @field(M, "has" ++ "Fn")(Local, "spawn");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r37_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(504): results.append(residue_control('504-SM1-a-break-operand-ends-at-its-prong-s-comma', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = switch (true) {\n        true => break :blk std.Thread,\n        false => false == false,\n    };\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(505): results.append(residue_control('505-SM1-a-break-operand-ends-at-its-prong-s-comma-local-twin', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = switch (true) {\n        true => break :blk Local,\n        false => false == false,\n    };\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(506): results.append(residue_control('506-SM1-the-same-with-a-constant-in-the-next-prong', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = switch (true) {\n        true => break :blk std.Thread,\n        false => false,\n    };\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(507): results.append(residue_control('507-SM1-the-same-with-a-constant-in-the-next-prong-local-twin', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = switch (true) {\n        true => break :blk Local,\n        false => false,\n    };\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(508): results.append(residue_control('508-SM2-an-address-after-a-break-label', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = outer: {\n    var value: type = u8;\n    const ptr = address: {\n        break :address &value;\n    };\n    ptr.* = std.Thread;\n    break :outer value;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(509): results.append(residue_control('509-SM2-an-address-after-a-break-label-local-twin', both(write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = outer: {\n    var value: type = u8;\n    const ptr = address: {\n        break :address &value;\n    };\n    ptr.* = Local;\n    break :outer value;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r38_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(510): results.append(residue_control('510-OM1-A1-a-comptime-tuple-field-destructured', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Pair = struct { comptime type = std.Thread, u8 };\npub const has = blk: {\n    const p: Pair = .{ .@"1" = 0 };\n    const N, const k = p;\n    break :blk @hasDecl(N, "Mutex") and k == 0;\n};\n'),
    1, {'UNRESOLVED-DESTRUCTURING': 1}))
if want(511): results.append(residue_control('511-OM1-A1-a-comptime-tuple-field-destructured-local-twin', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Pair = struct { comptime type = Local, u8 };\npub const has = blk: {\n    const p: Pair = .{ .@"1" = 0 };\n    const N, const k = .{ Local, p[1] };\n    break :blk @hasDecl(N, "Mutex") and k == 0;\n};\n'),
    0, {}))
if want(512): results.append(residue_control('512-OM1-G1-a-typed-tuple-written-through-its-address-destructured', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Pair = struct { type, u8 };\npub const has = blk: {\n    var pair: Pair = .{ u8, 0 };\n    const p = &pair;\n    p.*[0] = std.Thread;\n    const N, const k = pair;\n    break :blk @hasDecl(N, "Mutex") and k == 0;\n};\n'),
    1, {'UNRESOLVED-DESTRUCTURING': 1}))
if want(513): results.append(residue_control('513-OM1-G1-a-typed-tuple-written-through-its-address-destructured-local-twin', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Pair = struct { type, u8 };\npub const has = blk: {\n    var pair: Pair = .{ u8, 0 };\n    const p = &pair;\n    p.*[0] = Local;\n    const N, const k = .{ Local, pair[1] };\n    break :blk @hasDecl(N, "Mutex") and k == 0;\n};\n'),
    0, {}))
if want(514): results.append(residue_control('514-OM1-H1-a-builtin-s-value-in-an-anonymous-literal-destructured', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    const pair = .{ @typeInfo(u8), 0 };\n    const info, const k = pair;\n    break :blk @hasDecl(@TypeOf(info), "Declaration") and k == 0;\n};\n'),
    1, {'UNRESOLVED-DESTRUCTURING': 1}))
if want(515): results.append(residue_control('515-OM1-H1-a-builtin-s-value-in-an-anonymous-literal-destructured-local-twin', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    pub const Declaration = u8;\n};\npub const has = blk: {\n    const b: Box = .{};\n    const info, const k = .{ b, 0 };\n    break :blk @hasDecl(@TypeOf(info), "Declaration") and k == 0;\n};\n'),
    0, {}))
if want(516): results.append(residue_control('516-OM2-B1-a-mixed-destructuring-writes-the-var', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    N, const z = .{ std.Thread, 0 };\n    break :blk @hasDecl(N, "Mutex") and z == 0;\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(517): results.append(residue_control('517-OM2-B1-a-mixed-destructuring-writes-the-var-local-twin', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    N, const z = .{ Local, 0 };\n    break :blk @hasDecl(N, "Mutex") and z == 0;\n};\n'),
    0, {}))
if want(518): results.append(residue_control('518-OM2-C1-an-address-after-an-inner-break-label', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    const p = inner: {\n        break :inner &N;\n    };\n    p.* = std.Thread;\n    break :blk @hasDecl(N, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(519): results.append(residue_control('519-OM2-C1-an-address-after-an-inner-break-label-local-twin', both(write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    const p = inner: {\n        break :inner &N;\n    };\n    p.* = Local;\n    break :blk @hasDecl(N, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r38_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(520): results.append(residue_control('520-OM2-D1-a-slice-written-through-then-destructured', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var arr: [2]type = .{ u8, u8 };\n    const s = arr[0..1];\n    s.* = .{std.Thread};\n    const N, const M = arr;\n    break :blk @hasDecl(N, "Mutex") and M == u8;\n};\n'),
    1, {'UNRESOLVED-DESTRUCTURING': 1}))
if want(521): results.append(residue_control('521-OM2-D1-a-slice-written-through-then-destructured-local-twin', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var arr: [2]type = .{ u8, u8 };\n    const s = arr[0..1];\n    s.* = .{Local};\n    const N, const M = .{ Local, u8 };\n    break :blk @hasDecl(N, "Mutex") and M == u8 and arr.len == 2;\n};\n'),
    0, {}))
if want(522): results.append(residue_control('522-OM2-D2-a-memset-through-a-slice-then-destructured', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var arr: [2]type = .{ u8, u8 };\n    @memset(arr[0..], std.Thread);\n    const N, const M = arr;\n    break :blk @hasDecl(N, "Mutex") and M == std.Thread;\n};\n'),
    1, {'UNRESOLVED-DESTRUCTURING': 1}))
if want(523): results.append(residue_control('523-OM2-D2-a-memset-through-a-slice-then-destructured-local-twin', write_into('src/r38_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var arr: [2]type = .{ u8, u8 };\n    @memset(arr[0..], Local);\n    const N, const M = .{ Local, Local };\n    break :blk @hasDecl(N, "Mutex") and M == Local and arr.len == 2;\n};\n'),
    0, {}))
if want(530): results.append(residue_control('530-SM1-a-break-operand-ends-before-an-enclosing-else', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = if (true) break :blk std.Thread else false == false;\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(531): results.append(residue_control('531-SM1-a-break-operand-ends-before-an-enclosing-else-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = if (true) break :blk Local else false == false;\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(532): results.append(residue_control('532-SM1-the-same-in-a-while', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = while (true) break :blk std.Thread else false == false;\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(533): results.append(residue_control('533-SM1-the-same-in-a-while-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = while (true) break :blk Local else false == false;\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(534): results.append(residue_control('534-SM1-a-break-whose-operand-is-an-if-expression', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    break :blk if (true) std.Thread else u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(535): results.append(residue_control('535-SM1-a-break-whose-operand-is-an-if-expression-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    break :blk if (true) Local else u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(536): results.append(residue_control('536-SM2-OX1-a-destructuring-with-an-index-target', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: [1]u8 = .{0};\n    N, sink[0] = .{ std.Thread, 0 };\n    break :blk @hasDecl(N, "Mutex") and sink[0] == 0;\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(537): results.append(residue_control('537-SM2-OX1-a-destructuring-with-an-index-target-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: [1]u8 = .{0};\n    N, sink[0] = .{ Local, 0 };\n    break :blk @hasDecl(N, "Mutex") and sink[0] == 0;\n};\n'),
    0, {}))
if want(538): results.append(residue_control('538-SM2-OX1b-a-destructuring-with-a-field-target', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Sink = struct {\n    x: u8 = 0,\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: Sink = .{};\n    N, sink.x = .{ std.Thread, 0 };\n    break :blk @hasDecl(N, "Mutex") and sink.x == 0;\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(539): results.append(residue_control('539-SM2-OX1b-a-destructuring-with-a-field-target-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Sink = struct {\n    x: u8 = 0,\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: Sink = .{};\n    N, sink.x = .{ Local, 0 };\n    break :blk @hasDecl(N, "Mutex") and sink.x == 0;\n};\n'),
    0, {}))
if want(540): results.append(residue_control('540-SM2-OX2-an-index-target-and-a-declaration', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: [1]u8 = .{0};\n    N, sink[0], const z = .{ std.Thread, 0, 0 };\n    break :blk @hasDecl(N, "Mutex") and sink[0] == z;\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(541): results.append(residue_control('541-SM2-OX2-an-index-target-and-a-declaration-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: [1]u8 = .{0};\n    N, sink[0], const z = .{ Local, 0, 0 };\n    break :blk @hasDecl(N, "Mutex") and sink[0] == z;\n};\n'),
    0, {}))
if want(542): results.append(residue_control('542-SM2-a-field-target-and-a-declaration', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Sink = struct {\n    x: u8 = 0,\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: Sink = .{};\n    N, sink.x, const z = .{ std.Thread, 0, 0 };\n    break :blk @hasDecl(N, "Mutex") and sink.x == z;\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(543): results.append(residue_control('543-SM2-a-field-target-and-a-declaration-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Sink = struct {\n    x: u8 = 0,\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: Sink = .{};\n    N, sink.x, const z = .{ Local, 0, 0 };\n    break :blk @hasDecl(N, "Mutex") and sink.x == z;\n};\n'),
    0, {}))
if want(544): results.append(residue_control('544-OX1c-the-same-in-a-while-s-continue-expression', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: [1]u8 = .{0};\n    var i: u8 = 0;\n    while (i < 1) : (N, sink[0] = .{ std.Thread, 0 }) {\n        i += 1;\n    }\n    break :blk @hasDecl(N, "Mutex") and sink[0] == 0;\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(545): results.append(residue_control('545-OX1c-the-same-in-a-while-s-continue-expression-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    var sink: [1]u8 = .{0};\n    var i: u8 = 0;\n    while (i < 1) : (N, sink[0] = .{ Local, 0 }) {\n        i += 1;\n    }\n    break :blk @hasDecl(N, "Mutex") and sink[0] == 0;\n};\n'),
    0, {}))
if want(546): results.append(residue_control('546-OX3-an-index-target-and-a-typed-tuple-value', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Pair = struct { u8, comptime type = std.Thread };\npub const has = blk: {\n    var N: type = u8;\n    var sink: [1]u8 = .{0};\n    const p: Pair = .{ .@"0" = 0 };\n    sink[0], N = p;\n    break :blk @hasDecl(N, "Mutex") and sink[0] == 0;\n};\n'),
    1, {'UNRESOLVED-DESTRUCTURING': 1}))
if want(547): results.append(residue_control('547-OX3-an-index-target-and-a-typed-tuple-value-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Pair = struct { u8, comptime type = Local };\npub const has = blk: {\n    var N: type = u8;\n    var sink: [1]u8 = .{0};\n    const p: Pair = .{ .@"0" = 0 };\n    sink[0], N = .{ p[0], Local };\n    break :blk @hasDecl(N, "Mutex") and sink[0] == 0;\n};\n'),
    0, {}))
if want(548): results.append(residue_control('548-OX4-an-if-statement-s-break-then-an-else-assignment', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    if (true) break :blk std.Thread else _ = 1 == 1;\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(549): results.append(residue_control('549-OX4-an-if-statement-s-break-then-an-else-assignment-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    if (true) break :blk Local else _ = 1 == 1;\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(550): results.append(residue_control('550-OX4b-the-else-a-return', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn pick() bool {\n    const Ns = blk: {\n        if (true) break :blk std.Thread else return 1 == 1;\n    };\n    return @hasDecl(Ns, "Mutex");\n}\npub const has = pick();\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(551): results.append(residue_control('551-OX4b-the-else-a-return-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn pick() bool {\n    const Ns = blk: {\n        if (true) break :blk Local else return 1 == 1;\n    };\n    return @hasDecl(Ns, "Mutex");\n}\npub const has = pick();\n'),
    0, {}))
if want(552): results.append(residue_control('552-OX4c-the-if-opened-outside-the-operand', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = if (true) break :blk std.Thread else 1 == 1;\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(553): results.append(residue_control('553-OX4c-the-if-opened-outside-the-operand-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    _ = if (true) break :blk Local else 1 == 1;\n    break :blk u8;\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(554): results.append(residue_control('554-OX5-an-assignment-s-value-then-an-else', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    if (true) N = std.Thread else _ = 1 == 1;\n    break :blk @hasDecl(N, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(555): results.append(residue_control('555-OX5-an-assignment-s-value-then-an-else-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var N: type = u8;\n    if (true) N = Local else _ = 1 == 1;\n    break :blk @hasDecl(N, "Mutex");\n};\n'),
    0, {}))
if want(556): results.append(residue_control('556-OX6-a-volatile-const-pointer-type-is-no-declaration', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Ns = std.Thread;\nconst S = struct {\n    const p: *volatile const Ns = undefined;\n    pub const has = @hasDecl(Ns, "Mutex");\n};\npub const has = S.has;\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(557): results.append(residue_control('557-OX6-a-volatile-const-pointer-type-is-no-declaration-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Ns = Local;\nconst S = struct {\n    const p: *volatile const Ns = undefined;\n    pub const has = @hasDecl(Ns, "Mutex");\n};\npub const has = S.has;\n'),
    0, {}))
if want(558): results.append(residue_control('558-SL1-OL1-F5-pinned-a-direct-slice', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var arr: [1]type = .{u8};\n    const s = arr[0..];\n    s[0] = u8;\n    break :blk @hasDecl(@TypeOf(arr), "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(559): results.append(residue_control('559-SL1-OL1-F5-pinned-a-direct-slice-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var arr: [1]type = .{u8};\n    arr[0] = u8;\n    break :blk @hasDecl(@TypeOf(arr), "Mutex");\n};\n'),
    0, {}))
if want(560): results.append(residue_control('560-SL1-OL1-F5-pinned-a-grouped-slice', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var arr: [1]type = .{u8};\n    const s = (arr)[0..];\n    s[0] = u8;\n    break :blk @hasDecl(@TypeOf(arr), "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(561): results.append(residue_control('561-SL1-OL1-F5-pinned-a-grouped-slice-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var arr: [1]type = .{u8};\n    (arr)[0] = u8;\n    break :blk @hasDecl(@TypeOf(arr), "Mutex");\n};\n'),
    0, {}))
if want(562): results.append(residue_control('562-LD-a-method-call-receiver-is-an-address', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    n: u8 = 0,\n    fn bump(self: *Box) void {\n        self.n += 1;\n    }\n};\npub const info = blk: {\n    var b: ?Box = .{};\n    b.?.bump();\n    break :blk @typeInfo(@TypeOf(b));\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(563): results.append(residue_control('563-LD-a-method-call-receiver-is-an-address-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    n: u8 = 0,\n    fn bump(self: *Box) void {\n        self.n += 1;\n    }\n};\npub const info = blk: {\n    var b: ?Box = .{};\n    b.?.n += 1;\n    break :blk @typeInfo(@TypeOf(b));\n};\n'),
    0, {}))
if want(564): results.append(residue_control('564-UD-a-file-the-parser-rejects-fails', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const x = ;\n'),
    1, {'UNPARSEABLE': 1}))
if want(565): results.append(residue_control('565-UD-a-file-the-parser-rejects-fails-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const x = 1;\n'),
    0, {}))
if want(566): results.append(residue_control('566-UD-the-1a-compiler-s-array-repetition-fails-under-0-17-1', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const x = [_]u8{0} ** 2;\n'),
    1, {'UNPARSEABLE': 1}))
if want(567): results.append(residue_control('567-UD-the-1a-compiler-s-array-repetition-fails-under-0-17-1-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const x = [_]u8{ 0, 0 };\n'),
    0, {}))
if want(576): results.append(residue_control('576-SR-an-array-literal-s-element-type-joins-its-import-elements', both(write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst imp = @import("r39_other.zig");\npub const arr = [_]std.Thread.Mutex{imp.x};\npub const has = @hasDecl(@TypeOf(arr[0]), "lock");\n'), write_into('src/r39_other.zig', 'pub const x = .{};\n')),
    1, {'PRODUCTION-SHIM': 1}))
if want(577): results.append(residue_control('577-SR-an-array-literal-s-element-type-joins-its-import-elements-local-twin', both(write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst imp = @import("r39_other.zig");\npub const arr = [_]type{imp.x};\npub const has = @hasDecl(@TypeOf(arr[0]), "lock");\n'), write_into('src/r39_other.zig', 'pub const x = .{};\n')),
    0, {}))
if want(578): results.append(residue_control('578-SR-an-array-literal-s-element-type-joins-its-parameter-elements', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub fn pick(p: anytype) bool {\n    const a = [_]std.Thread.Mutex{p};\n    return @hasDecl(@TypeOf(a[0]), "lock");\n}\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(579): results.append(residue_control('579-SR-an-array-literal-s-element-type-joins-its-parameter-elements-local-twin', write_into('src/r39_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub fn pick(p: anytype) bool {\n    const a = [_]type{p};\n    return @hasDecl(@TypeOf(a[0]), "lock");\n}\n'),
    0, {}))
if want(580): results.append(residue_control('580-OM1-an-assignment-through-an-if', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (if (true) t else t) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(581): results.append(residue_control('581-OM1-an-assignment-through-an-if-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (if (true) t else t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(582): results.append(residue_control('582-OM1-an-assignment-through-a-switch-prong', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (switch (0) { else => t }) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(583): results.append(residue_control('583-OM1-an-assignment-through-a-switch-prong-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (switch (0) { else => t }) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(584): results.append(residue_control('584-OM1-an-assignment-through-a-labelled-block-s-break', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (b: { break :b t; }) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(585): results.append(residue_control('585-OM1-an-assignment-through-a-labelled-block-s-break-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (b: { break :b t; }) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(586): results.append(residue_control('586-OM1-an-assignment-through-orelse', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    var o: ?type = null;\n    (o orelse t) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(587): results.append(residue_control('587-OM1-an-assignment-through-orelse-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    var o: ?type = null;\n    (o orelse t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(588): results.append(residue_control('588-OM1-an-assignment-through-catch', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    var e: anyerror!type = error.Nope;\n    (e catch t) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(589): results.append(residue_control('589-OM1-an-assignment-through-catch-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    var e: anyerror!type = error.Nope;\n    (e catch t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(590): results.append(residue_control('590-OM1-an-assignment-through-a-while-s-else', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (false) {} else t) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(591): results.append(residue_control('591-OM1-an-assignment-through-a-while-s-else-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (false) {} else t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(592): results.append(residue_control('592-OM1-an-assignment-through-a-for-s-else', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (for ([_]u8{}) |_| {} else t) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(593): results.append(residue_control('593-OM1-an-assignment-through-a-for-s-else-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (for ([_]u8{}) |_| {} else t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(594): results.append(residue_control('594-OM1-an-assignment-through-nosuspend', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (nosuspend t) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(595): results.append(residue_control('595-OM1-an-assignment-through-nosuspend-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (nosuspend t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(596): results.append(residue_control('596-OM1-an-assignment-through-try', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn pick() !bool {\n    var t: anyerror!type = u8;\n    (try t) = std.Thread;\n    return @hasDecl(try t, "Mutex");\n}\npub const has = pick() catch false;\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(597): results.append(residue_control('597-OM1-an-assignment-through-try-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn pick() !bool {\n    var t: anyerror!type = u8;\n    (try t) = Local;\n    return @hasDecl(try t, "Mutex");\n}\npub const has = pick() catch false;\n'),
    0, {}))
if want(598): results.append(residue_control('598-OM1-an-address-through-an-if', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    const p = &(if (true) t else t);\n    p.* = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(599): results.append(residue_control('599-OM1-an-address-through-an-if-local-twin', both(write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    const p = &(if (true) t else t);\n    p.* = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r40_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(600): results.append(residue_control('600-OM1-an-address-through-a-switch-prong', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    const p = &(switch (0) { else => t });\n    p.* = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(601): results.append(residue_control('601-OM1-an-address-through-a-switch-prong-local-twin', both(write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    const p = &(switch (0) { else => t });\n    p.* = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r40_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(602): results.append(residue_control('602-OM1-an-address-through-a-labelled-block-s-break', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    const p = &(b: { break :b t; });\n    p.* = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(603): results.append(residue_control('603-OM1-an-address-through-a-labelled-block-s-break-local-twin', both(write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    const p = &(b: { break :b t; });\n    p.* = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r40_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(604): results.append(residue_control('604-OM1-an-address-through-orelse', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    var o: ?type = null;\n    const p = &(o orelse t);\n    p.* = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(605): results.append(residue_control('605-OM1-an-address-through-orelse-local-twin', both(write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    var o: ?type = null;\n    const p = &(o orelse t);\n    p.* = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r40_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(606): results.append(residue_control('606-OM1-a-destructuring-target-through-an-if', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (if (true) t else t), _ = .{ std.Thread, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(607): results.append(residue_control('607-OM1-a-destructuring-target-through-an-if-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (if (true) t else t), _ = .{ Local, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(608): results.append(residue_control('608-OM1-a-destructuring-target-through-a-labelled-block-s-break', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (b: { break :b t; }), _ = .{ std.Thread, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(609): results.append(residue_control('609-OM1-a-destructuring-target-through-a-labelled-block-s-break-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (b: { break :b t; }), _ = .{ Local, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(610): results.append(residue_control('610-OM1-a-pointer-capture-over-an-if', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn pick() !bool {\n    var e: anyerror!type = u8;\n    if (if (true) e else e) |*q| {\n        q.* = std.Thread;\n    } else |_| {}\n    return @hasDecl(try e, "Mutex");\n}\npub const has = pick() catch false;\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(611): results.append(residue_control('611-OM1-a-pointer-capture-over-an-if-local-twin', both(write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nfn pick() !bool {\n    var e: anyerror!type = u8;\n    if (if (true) e else e) |*q| {\n        q.* = Local;\n    } else |_| {}\n    return @hasDecl(try e, "Mutex");\n}\npub const has = pick() catch false;\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r40_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(612): results.append(residue_control('612-OM1-a-method-call-receiver-through-an-if', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    n: u8 = 0,\n    fn bump(self: *Box) void {\n        self.n += 1;\n    }\n};\npub const info = blk: {\n    var b: ?Box = .{};\n    (if (true) b else b).?.bump();\n    break :blk @typeInfo(@TypeOf(b));\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(613): results.append(residue_control('613-OM1-a-method-call-receiver-through-an-if-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    n: u8 = 0,\n    fn bump(self: *Box) void {\n        self.n += 1;\n    }\n};\npub const info = blk: {\n    var b: ?Box = .{};\n    (if (true) b else b).?.n += 1;\n    break :blk @typeInfo(@TypeOf(b));\n};\n'),
    0, {}))
if want(614): results.append(residue_control('614-OM2-a-labelled-switch-s-break', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = sw: switch (0) {\n    else => break :sw std.Thread,\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(615): results.append(residue_control('615-OM2-a-labelled-switch-s-break-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = sw: switch (0) {\n    else => break :sw Local,\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(616): results.append(residue_control('616-OM2-a-labelled-switch-s-continue-into-a-prong-capture', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst K: type = u8;\npub const has = sw: switch (K) {\n    u8 => continue :sw std.Thread,\n    else => |T| break :sw @hasDecl(T, "Mutex"),\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(617): results.append(residue_control('617-OM2-a-labelled-switch-s-continue-into-a-prong-capture-local-twin', both(write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst K: type = u8;\npub const has = sw: switch (K) {\n    u8 => continue :sw Local,\n    else => |T| break :sw @hasDecl(T, "Mutex"),\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r40_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(618): results.append(residue_control('618-SW-a-labelled-switch-mixing-plain-prongs-and-a-break', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = sw: switch (@as(u8, 1)) {\n    0 => u8,\n    else => break :sw std.Thread,\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(619): results.append(residue_control('619-SW-a-labelled-switch-mixing-plain-prongs-and-a-break-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = sw: switch (@as(u8, 1)) {\n    0 => u8,\n    else => break :sw Local,\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(620): results.append(residue_control('620-SW-a-labelled-switch-nested-in-a-block', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    break :blk sw: switch (0) {\n        else => break :sw std.Thread,\n    };\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(621): results.append(residue_control('621-SW-a-labelled-switch-nested-in-a-block-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = blk: {\n    break :blk sw: switch (0) {\n        else => break :sw Local,\n    };\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    0, {}))
if want(622): results.append(residue_control('622-SW-a-labelled-switch-assigned-to-a-var', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    t = sw: switch (0) {\n        else => break :sw std.Thread,\n    };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(623): results.append(residue_control('623-SW-a-labelled-switch-assigned-to-a-var-local-twin', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    t = sw: switch (0) {\n        else => break :sw Local,\n    };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(624): results.append(residue_control('624-SW-a-labelled-switch-s-break-from-a-loop-in-a-prong', write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = sw: switch (0) {\n    else => while (true) break :sw std.Thread,\n};\npub const has = @hasDecl(Ns, "Mutex");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(625): results.append(residue_control('625-SW-a-labelled-switch-s-break-from-a-loop-in-a-prong-local-twin', both(write_into('src/r40_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const Ns = sw: switch (0) {\n    else => while (true) break :sw Local,\n};\npub const has = @hasDecl(Ns, "Mutex");\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r40_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(636): results.append(residue_control('636-SM1-an-assignment-200-groupings-deep', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(637): results.append(residue_control('637-SM1-an-assignment-200-groupings-deep-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(638): results.append(residue_control('638-SM1-a-destructuring-target-200-groupings-deep', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))), _ = .{ std.Thread, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(639): results.append(residue_control('639-SM1-a-destructuring-target-200-groupings-deep-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))), _ = .{ Local, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(640): results.append(residue_control('640-SM1-an-assignment-201-groupings-deep', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(641): results.append(residue_control('641-SM1-an-assignment-201-groupings-deep-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(642): results.append(residue_control('642-SM1-a-destructuring-target-201-groupings-deep', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))), _ = .{ std.Thread, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(643): results.append(residue_control('643-SM1-a-destructuring-target-201-groupings-deep-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))), _ = .{ Local, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(644): results.append(residue_control('644-SM1-an-assignment-1000-groupings-deep', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(645): results.append(residue_control('645-SM1-an-assignment-1000-groupings-deep-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(646): results.append(residue_control('646-SM1-a-destructuring-target-1000-groupings-deep', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))), _ = .{ std.Thread, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(647): results.append(residue_control('647-SM1-a-destructuring-target-1000-groupings-deep-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    ((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((t)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))), _ = .{ Local, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(648): results.append(residue_control('648-OM2-an-assignment-through-a-300-deep-mixed-chain', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    var o: ?type = null;\n    (switch (0) { else => (b298: { break :b298 (o orelse ((switch (0) { else => (b294: { break :b294 (o orelse ((switch (0) { else => (b290: { break :b290 (o orelse ((switch (0) { else => (b286: { break :b286 (o orelse ((switch (0) { else => (b282: { break :b282 (o orelse ((switch (0) { else => (b278: { break :b278 (o orelse ((switch (0) { else => (b274: { break :b274 (o orelse ((switch (0) { else => (b270: { break :b270 (o orelse ((switch (0) { else => (b266: { break :b266 (o orelse ((switch (0) { else => (b262: { break :b262 (o orelse ((switch (0) { else => (b258: { break :b258 (o orelse ((switch (0) { else => (b254: { break :b254 (o orelse ((switch (0) { else => (b250: { break :b250 (o orelse ((switch (0) { else => (b246: { break :b246 (o orelse ((switch (0) { else => (b242: { break :b242 (o orelse ((switch (0) { else => (b238: { break :b238 (o orelse ((switch (0) { else => (b234: { break :b234 (o orelse ((switch (0) { else => (b230: { break :b230 (o orelse ((switch (0) { else => (b226: { break :b226 (o orelse ((switch (0) { else => (b222: { break :b222 (o orelse ((switch (0) { else => (b218: { break :b218 (o orelse ((switch (0) { else => (b214: { break :b214 (o orelse ((switch (0) { else => (b210: { break :b210 (o orelse ((switch (0) { else => (b206: { break :b206 (o orelse ((switch (0) { else => (b202: { break :b202 (o orelse ((switch (0) { else => (b198: { break :b198 (o orelse ((switch (0) { else => (b194: { break :b194 (o orelse ((switch (0) { else => (b190: { break :b190 (o orelse ((switch (0) { else => (b186: { break :b186 (o orelse ((switch (0) { else => (b182: { break :b182 (o orelse ((switch (0) { else => (b178: { break :b178 (o orelse ((switch (0) { else => (b174: { break :b174 (o orelse ((switch (0) { else => (b170: { break :b170 (o orelse ((switch (0) { else => (b166: { break :b166 (o orelse ((switch (0) { else => (b162: { break :b162 (o orelse ((switch (0) { else => (b158: { break :b158 (o orelse ((switch (0) { else => (b154: { break :b154 (o orelse ((switch (0) { else => (b150: { break :b150 (o orelse ((switch (0) { else => (b146: { break :b146 (o orelse ((switch (0) { else => (b142: { break :b142 (o orelse ((switch (0) { else => (b138: { break :b138 (o orelse ((switch (0) { else => (b134: { break :b134 (o orelse ((switch (0) { else => (b130: { break :b130 (o orelse ((switch (0) { else => (b126: { break :b126 (o orelse ((switch (0) { else => (b122: { break :b122 (o orelse ((switch (0) { else => (b118: { break :b118 (o orelse ((switch (0) { else => (b114: { break :b114 (o orelse ((switch (0) { else => (b110: { break :b110 (o orelse ((switch (0) { else => (b106: { break :b106 (o orelse ((switch (0) { else => (b102: { break :b102 (o orelse ((switch (0) { else => (b98: { break :b98 (o orelse ((switch (0) { else => (b94: { break :b94 (o orelse ((switch (0) { else => (b90: { break :b90 (o orelse ((switch (0) { else => (b86: { break :b86 (o orelse ((switch (0) { else => (b82: { break :b82 (o orelse ((switch (0) { else => (b78: { break :b78 (o orelse ((switch (0) { else => (b74: { break :b74 (o orelse ((switch (0) { else => (b70: { break :b70 (o orelse ((switch (0) { else => (b66: { break :b66 (o orelse ((switch (0) { else => (b62: { break :b62 (o orelse ((switch (0) { else => (b58: { break :b58 (o orelse ((switch (0) { else => (b54: { break :b54 (o orelse ((switch (0) { else => (b50: { break :b50 (o orelse ((switch (0) { else => (b46: { break :b46 (o orelse ((switch (0) { else => (b42: { break :b42 (o orelse ((switch (0) { else => (b38: { break :b38 (o orelse ((switch (0) { else => (b34: { break :b34 (o orelse ((switch (0) { else => (b30: { break :b30 (o orelse ((switch (0) { else => (b26: { break :b26 (o orelse ((switch (0) { else => (b22: { break :b22 (o orelse ((switch (0) { else => (b18: { break :b18 (o orelse ((switch (0) { else => (b14: { break :b14 (o orelse ((switch (0) { else => (b10: { break :b10 (o orelse ((switch (0) { else => (b6: { break :b6 (o orelse ((switch (0) { else => (b2: { break :b2 (o orelse (t)); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(649): results.append(residue_control('649-OM2-an-assignment-through-a-300-deep-mixed-chain-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    var o: ?type = null;\n    (switch (0) { else => (b298: { break :b298 (o orelse ((switch (0) { else => (b294: { break :b294 (o orelse ((switch (0) { else => (b290: { break :b290 (o orelse ((switch (0) { else => (b286: { break :b286 (o orelse ((switch (0) { else => (b282: { break :b282 (o orelse ((switch (0) { else => (b278: { break :b278 (o orelse ((switch (0) { else => (b274: { break :b274 (o orelse ((switch (0) { else => (b270: { break :b270 (o orelse ((switch (0) { else => (b266: { break :b266 (o orelse ((switch (0) { else => (b262: { break :b262 (o orelse ((switch (0) { else => (b258: { break :b258 (o orelse ((switch (0) { else => (b254: { break :b254 (o orelse ((switch (0) { else => (b250: { break :b250 (o orelse ((switch (0) { else => (b246: { break :b246 (o orelse ((switch (0) { else => (b242: { break :b242 (o orelse ((switch (0) { else => (b238: { break :b238 (o orelse ((switch (0) { else => (b234: { break :b234 (o orelse ((switch (0) { else => (b230: { break :b230 (o orelse ((switch (0) { else => (b226: { break :b226 (o orelse ((switch (0) { else => (b222: { break :b222 (o orelse ((switch (0) { else => (b218: { break :b218 (o orelse ((switch (0) { else => (b214: { break :b214 (o orelse ((switch (0) { else => (b210: { break :b210 (o orelse ((switch (0) { else => (b206: { break :b206 (o orelse ((switch (0) { else => (b202: { break :b202 (o orelse ((switch (0) { else => (b198: { break :b198 (o orelse ((switch (0) { else => (b194: { break :b194 (o orelse ((switch (0) { else => (b190: { break :b190 (o orelse ((switch (0) { else => (b186: { break :b186 (o orelse ((switch (0) { else => (b182: { break :b182 (o orelse ((switch (0) { else => (b178: { break :b178 (o orelse ((switch (0) { else => (b174: { break :b174 (o orelse ((switch (0) { else => (b170: { break :b170 (o orelse ((switch (0) { else => (b166: { break :b166 (o orelse ((switch (0) { else => (b162: { break :b162 (o orelse ((switch (0) { else => (b158: { break :b158 (o orelse ((switch (0) { else => (b154: { break :b154 (o orelse ((switch (0) { else => (b150: { break :b150 (o orelse ((switch (0) { else => (b146: { break :b146 (o orelse ((switch (0) { else => (b142: { break :b142 (o orelse ((switch (0) { else => (b138: { break :b138 (o orelse ((switch (0) { else => (b134: { break :b134 (o orelse ((switch (0) { else => (b130: { break :b130 (o orelse ((switch (0) { else => (b126: { break :b126 (o orelse ((switch (0) { else => (b122: { break :b122 (o orelse ((switch (0) { else => (b118: { break :b118 (o orelse ((switch (0) { else => (b114: { break :b114 (o orelse ((switch (0) { else => (b110: { break :b110 (o orelse ((switch (0) { else => (b106: { break :b106 (o orelse ((switch (0) { else => (b102: { break :b102 (o orelse ((switch (0) { else => (b98: { break :b98 (o orelse ((switch (0) { else => (b94: { break :b94 (o orelse ((switch (0) { else => (b90: { break :b90 (o orelse ((switch (0) { else => (b86: { break :b86 (o orelse ((switch (0) { else => (b82: { break :b82 (o orelse ((switch (0) { else => (b78: { break :b78 (o orelse ((switch (0) { else => (b74: { break :b74 (o orelse ((switch (0) { else => (b70: { break :b70 (o orelse ((switch (0) { else => (b66: { break :b66 (o orelse ((switch (0) { else => (b62: { break :b62 (o orelse ((switch (0) { else => (b58: { break :b58 (o orelse ((switch (0) { else => (b54: { break :b54 (o orelse ((switch (0) { else => (b50: { break :b50 (o orelse ((switch (0) { else => (b46: { break :b46 (o orelse ((switch (0) { else => (b42: { break :b42 (o orelse ((switch (0) { else => (b38: { break :b38 (o orelse ((switch (0) { else => (b34: { break :b34 (o orelse ((switch (0) { else => (b30: { break :b30 (o orelse ((switch (0) { else => (b26: { break :b26 (o orelse ((switch (0) { else => (b22: { break :b22 (o orelse ((switch (0) { else => (b18: { break :b18 (o orelse ((switch (0) { else => (b14: { break :b14 (o orelse ((switch (0) { else => (b10: { break :b10 (o orelse ((switch (0) { else => (b6: { break :b6 (o orelse ((switch (0) { else => (b2: { break :b2 (o orelse (t)); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }))); }) }) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(650): results.append(residue_control('650-OA1-an-address-through-a-break-in-a-while-s-else', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    const p = &(while (true) while (false) {} else break t);\n    p.* = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(651): results.append(residue_control('651-OA1-an-address-through-a-break-in-a-while-s-else-local-twin', both(write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    const p = &(while (true) while (false) {} else break t);\n    p.* = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'), write_into('ci/residue-allow.tsv', "unresolved-origin\tsrc/r41_shim.zig\t1\tthe control's own form, which the gate leaves unresolved (a rule outside the trusted set, or a soundness rule)\n", 'a')),
    0, {}))
if want(652): results.append(residue_control('652-OA2-an-assignment-through-a-break-in-a-while-s-else', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) while (false) {} else break t) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(653): results.append(residue_control('653-OA2-an-assignment-through-a-break-in-a-while-s-else-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) while (false) {} else break t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(654): results.append(residue_control('654-OA3-an-assignment-through-a-break-in-a-for-s-else', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) for ([_]u8{}) |_| {} else break t) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(655): results.append(residue_control('655-OA3-an-assignment-through-a-break-in-a-for-s-else-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) for ([_]u8{}) |_| {} else break t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(656): results.append(residue_control('656-OA4-an-assignment-through-a-break-in-a-while-s-condition', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) while (break t) {}) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(657): results.append(residue_control('657-OA4-an-assignment-through-a-break-in-a-while-s-condition-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) while (break t) {}) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(658): results.append(residue_control('658-OA5-an-assignment-through-a-break-in-a-for-s-input', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) for (break t) |_| {}) = std.Thread;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(659): results.append(residue_control('659-OA5-an-assignment-through-a-break-in-a-for-s-input-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) for (break t) |_| {}) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(660): results.append(residue_control('660-OA6-a-destructuring-target-through-a-break-in-a-while-s-else', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) while (false) {} else break t), _ = .{ std.Thread, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(661): results.append(residue_control('661-OA6-a-destructuring-target-through-a-break-in-a-while-s-else-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (while (true) while (false) {} else break t), _ = .{ Local, 0 };\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(662): results.append(residue_control('662-OA7-a-method-call-receiver-through-a-break-in-a-while-s-else', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    n: u8 = 0,\n    pub fn bump(self: *Box) void {\n        self.n += 1;\n    }\n};\npub const info = blk: {\n    var b: ?Box = .{};\n    (while (true) while (false) {} else break b).?.bump();\n    break :blk @typeInfo(@TypeOf(b));\n};\n'),
    1, {'UNRESOLVED-ORIGIN': 1}))
if want(663): results.append(residue_control('663-OA7-a-method-call-receiver-through-a-break-in-a-while-s-else-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\nconst Box = struct {\n    n: u8 = 0,\n    pub fn bump(self: *Box) void {\n        self.n += 1;\n    }\n};\npub const info = blk: {\n    var b: ?Box = .{};\n    (while (true) while (false) {} else break b).?.n += 1;\n    break :blk @typeInfo(@TypeOf(b));\n};\n'),
    0, {}))
if want(664): results.append(residue_control('664-LD-a-labelled-break-from-a-while-s-else-to-its-own-label-local-twin', write_into('src/r41_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = blk: {\n    var t: type = u8;\n    (inner: while (false) {} else break :inner t) = Local;\n    break :blk @hasDecl(t, "Mutex");\n};\n'),
    0, {}))
if want(674): results.append(residue_control('674-OM1-a-zig-file-with-a-latin-1-byte-and-a-0-15-2-comment', write_bytes_into('src/r42_latin1.zig', b'// caf\xe9: written for Zig 0.15.2\nconst std = @import("std");\npub const r42_width = std.math.maxInt(u8);\n'),
    1, {'NOT-TEXT': 1}))
if want(675): results.append(residue_control('675-OM1-a-zig-file-with-a-latin-1-byte-and-a-0-15-2-comment-utf-8-twin', write_into('src/r42_latin1.zig', '// café: written for Zig 0.15.2\nconst std = @import("std");\npub const r42_width = std.math.maxInt(u8);\n'),
    1, {'RESIDUE-015': 1}))
if want(676): results.append(residue_control('676-OL1-a-feature-test-on-std-in-test-windows', write_into('test/windows/r42_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = @hasDecl(std.Io, "Threaded");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(677): results.append(residue_control('677-OL1-a-feature-test-on-std-in-test-windows-local-twin', write_into('test/windows/r42_shim.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = @hasDecl(Local, "Threaded");\n'),
    0, {}))
if want(770): results.append(residue_control('770-OL1-a-feature-test-on-std-in-a-nested-zig-out-fails', write_into('src/zig-out/p08.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = @hasDecl(std.Io, "Threaded");\n'),
    1, {'PRODUCTION-SHIM': 1}))
if want(771): results.append(residue_control('771-OL1-the-same-file-in-the-root-s-zig-out-passes-root-twin', write_into('zig-out/p08.zig', 'const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub fn spawn() void {}\n    pub const Mutex = u8;\n    pub const Thread = Local;\n};\npub const has = @hasDecl(std.Io, "Threaded");\n'),
    0, {}))
if want(772): results.append(residue_control('772-OL2-a-utf-16le-script-with-two-mentions-fails', write_bytes_into('scripts/get-zig.ps1', b"\xff\xfe#\x00 \x00i\x00n\x00s\x00t\x00a\x00l\x00l\x00 \x00t\x00h\x00e\x00 \x00Z\x00i\x00g\x00 \x000\x00.\x001\x005\x00.\x002\x00 \x00t\x00o\x00o\x00l\x00c\x00h\x00a\x00i\x00n\x00\r\x00\n\x00$\x00v\x00 \x00=\x00 \x00'\x000\x00.\x001\x005\x00.\x002\x00'\x00\r\x00\n\x00"),
    1, {'RESIDUE-015': 2}))
if want(773): results.append(residue_control('773-OL2-the-same-script-with-no-version-passes-twin', write_bytes_into('scripts/get-zig.ps1', b'\xff\xfe#\x00 \x00i\x00n\x00s\x00t\x00a\x00l\x00l\x00 \x00t\x00h\x00e\x00 \x00Z\x00i\x00g\x00 \x00t\x00o\x00o\x00l\x00c\x00h\x00a\x00i\x00n\x00\r\x00\n\x00$\x00v\x00 \x00=\x00 \x00$\x00a\x00r\x00g\x00s\x00[\x000\x00]\x00\r\x00\n\x00'),
    0, {}))
if want(774): results.append(residue_control('774-UD-a-utf-16le-file-with-a-lone-surrogate-before-a-mention-fails', write_bytes_into('scripts/r43-surrogate.txt', b'\xff\xfep\x00r\x00e\x00 \x00\x00\xd8\n\x00#\x00 \x00i\x00n\x00s\x00t\x00a\x00l\x00l\x00 \x00Z\x00i\x00g\x00 \x000\x00.\x001\x005\x00.\x002\x00\n\x00'),
    1, {'RESIDUE-015': 1}))
if want(775): results.append(residue_control('775-UD-the-same-file-without-the-mention-passes-twin', write_bytes_into('scripts/r43-surrogate.txt', b'\xff\xfep\x00r\x00e\x00 \x00\x00\xd8\n\x00#\x00 \x00i\x00n\x00s\x00t\x00a\x00l\x00l\x00 \x00Z\x00i\x00g\x00\n\x00'),
    0, {}))
if want(776): results.append(residue_control('776-UD-an-odd-length-utf-16be-file-with-a-mention-fails', write_bytes_into('scripts/r43-odd.txt', b'\xfe\xff\x00#\x00 \x00i\x00n\x00s\x00t\x00a\x00l\x00l\x00 \x00Z\x00i\x00g\x00 \x000\x00.\x001\x005\x00.\x002\x00\nA'),
    1, {'RESIDUE-015': 1}))
if want(777): results.append(residue_control('777-UD-the-same-file-without-the-mention-passes-twin', write_bytes_into('scripts/r43-odd.txt', b'\xfe\xff\x00#\x00 \x00i\x00n\x00s\x00t\x00a\x00l\x00l\x00 \x00Z\x00i\x00g\x00\nA'),
    0, {}))
if want(778): results.append(residue_control('778-UD-a-utf-32le-file-with-a-mention-fails', write_bytes_into('scripts/r43-utf32.txt', b'\xff\xfe\x00\x00#\x00\x00\x00 \x00\x00\x00i\x00\x00\x00n\x00\x00\x00s\x00\x00\x00t\x00\x00\x00a\x00\x00\x00l\x00\x00\x00l\x00\x00\x00 \x00\x00\x00Z\x00\x00\x00i\x00\x00\x00g\x00\x00\x00 \x00\x00\x000\x00\x00\x00.\x00\x00\x001\x00\x00\x005\x00\x00\x00.\x00\x00\x002\x00\x00\x00\n\x00\x00\x00'),
    1, {'RESIDUE-015': 1}))
if want(779): results.append(residue_control('779-UD-the-same-file-without-the-mention-passes-twin', write_bytes_into('scripts/r43-utf32.txt', b'\xff\xfe\x00\x00#\x00\x00\x00 \x00\x00\x00i\x00\x00\x00n\x00\x00\x00s\x00\x00\x00t\x00\x00\x00a\x00\x00\x00l\x00\x00\x00l\x00\x00\x00 \x00\x00\x00Z\x00\x00\x00i\x00\x00\x00g\x00\x00\x00\n\x00\x00\x00'),
    0, {}))
# -- r36 (round 35's Opus L3): a field read's op in the root binding's container; r34's B1 row, the Holder decoy


def _field_in_a_decoy(tag, real_has):
    body = ("const R36Holder = struct {\n    lock: u8 = 0,\n};\nconst R36Real = struct {\n"
            + ("    lock: u8 = 0,\n" if real_has else "    state: u8 = 0,\n")
            + "    fn r36fr(self: *R36Real) u8 {\n        return self.lock;\n    }\n};")
    ov = overlay("c" + tag[:3], {W32: append(body)})
    text = open(os.path.join(ov, *W32.split("/")), encoding="utf-8").read()
    n0 = len(show(W32).splitlines())
    ln = next(i for i, l_ in enumerate(text.splitlines(), 1) if i > n0 and l_.strip() == "return self.lock;")
    prefix = os.path.join(logdir, "inv-" + tag[:3])
    open(prefix + "-fieldreads.tsv", "w", encoding="utf-8", newline="\n").write(f"{rev}\t{W32}\t{ln}\tself\tlock\tfield\n")
    if real_has:
        return bindcheck_control(tag, prefix, ov, 0, ("RESULT PASS",), {})
    return bindcheck_control(tag, prefix, ov, 1, ("FIELD-NOT-DECLARED",), {"FIELD-NOT-DECLARED": 1})


if FULL and want(430): results.append(_field_in_a_decoy("430-OL3-a-field-read-whose-op-only-a-decoy-container-declares", False))
if FULL and want(431): results.append(_field_in_a_decoy("431-OL3-the-same-row-its-root-binding-s-container-declares", True))
# -- r37 (round 36's Sol M4): a container name declared more than once gives no evidence unless lexical scope resolves
# it: a same-named sibling container and a same-named alias, each a crafted field-read row, and their twins


def _same_named(tag, code, fails):
    ov = overlay("c" + tag[:3], {W32: append(code)})
    text = open(os.path.join(ov, *W32.split("/")), encoding="utf-8").read()
    n0 = len(show(W32).splitlines())
    ln = next(i for i, l_ in enumerate(text.splitlines(), 1) if i > n0 and l_.strip() == "return self.lock;")
    prefix = os.path.join(logdir, "inv-" + tag[:3])
    open(prefix + "-fieldreads.tsv", "w", encoding="utf-8", newline="\n").write(f"{rev}\t{W32}\t{ln}\tself\tlock\tfield\n")
    if fails:
        return bindcheck_control(tag, prefix, ov, 1, ("FIELD-NOT-DECLARED",), {"FIELD-NOT-DECLARED": 1})
    return bindcheck_control(tag, prefix, ov, 0, ("RESULT PASS",), {})


if FULL and want(480): results.append(_same_named('480-SM4-a-same-named-sibling-container-gives-no-evidence', 'const R37Left = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R37Right = struct {\n    const R = struct {\n        state: u8 = 0,\n        fn r37fr(self: *R) u8 {\n            return self.lock;\n        }\n    };\n};', True))
if FULL and want(481): results.append(_same_named('481-SM4-the-receiver-s-own-container-declares-it-local-twin', 'const R37Left = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R37Right = struct {\n    const R = struct {\n        lock: u8 = 0,\n        fn r37fr(self: *R) u8 {\n            return self.lock;\n        }\n    };\n};', False))
if FULL and want(482): results.append(_same_named('482-SM4-a-same-named-alias-gives-no-evidence', 'const R37LeftA = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R37RightA = struct {\n    const Inner = struct {\n        state: u8 = 0,\n    };\n    const R = Inner;\n    fn r37fa(self: *R) u8 {\n        return self.lock;\n    }\n};', True))
if FULL and want(483): results.append(_same_named('483-SM4-the-alias-s-own-container-declares-it-local-twin', 'const R37LeftA = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R37RightA = struct {\n    const Inner = struct {\n        lock: u8 = 0,\n    };\n    const R = Inner;\n    fn r37fa(self: *R) u8 {\n        return self.lock;\n    }\n};', False))
# -- r38 (round 37's Opus M3): the index holds every const and var, an unreadable declaration opaque, and a name
# resolves by lexical scope; an opaque innermost declaration gives no evidence: a chain alias, an import's member
# and a generic's result as the receiver's own `R` beside a sibling `R` that declares the field, and their K0 twins
if FULL and want(524): results.append(_same_named('524-OM3-K1-a-chain-alias-gives-no-evidence', 'const R38LeftK1 = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R38RightK1 = struct {\n    const Wrap = struct {\n        const Inner = struct {\n            state: u8 = 0,\n        };\n    };\n    const R = Wrap.Inner;\n    fn r38k1(self: *R) u8 {\n        return self.lock;\n    }\n};', True))
if FULL and want(525): results.append(_same_named('525-OM3-K0-the-receiver-s-readable-alias-declares-it-local-twin', 'const R38LeftK1t = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R38RightK1t = struct {\n    const Inner = struct {\n        lock: u8 = 0,\n    };\n    const R = Inner;\n    fn r38k1t(self: *R) u8 {\n        return self.lock;\n    }\n};', False))
if FULL and want(526): results.append(_same_named('526-OM3-K2-an-import-s-member-gives-no-evidence', 'const R38LeftK2 = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R38RightK2 = struct {\n    const R = @import("r38_other.zig").R;\n    fn r38k2(self: *R) u8 {\n        return self.lock;\n    }\n};', True))
if FULL and want(527): results.append(_same_named('527-OM3-K0-the-receiver-s-alias-of-a-file-container-declares-it-local-twin', 'const R38LeftK2t = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R38OtherK2t = struct {\n    lock: u8 = 0,\n};\nconst R38RightK2t = struct {\n    const R = R38OtherK2t;\n    fn r38k2t(self: *R) u8 {\n        return self.lock;\n    }\n};', False))
if FULL and want(528): results.append(_same_named('528-OM3-K3-a-generic-s-result-gives-no-evidence', 'const R38LeftK3 = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nfn R38GenK3(comptime T: type) type {\n    return struct {\n        state: T,\n    };\n}\nconst R38RightK3 = struct {\n    const R = R38GenK3(u8);\n    fn r38k3(self: *R) u8 {\n        return self.lock;\n    }\n};', True))
if FULL and want(529): results.append(_same_named('529-OM3-K0-the-receiver-s-own-container-declares-it-local-twin', 'const R38LeftK3t = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n};\nconst R38RightK3t = struct {\n    const R = struct {\n        lock: u8 = 0,\n    };\n    fn r38k3t(self: *R) u8 {\n        return self.lock;\n    }\n};', False))
# -- r39 (round 38's Sol M3, Opus M3 K4): declarations are var_decl nodes, a container literal certifies a name only
# as the declaration's whole initializer: a suffix, `struct { lock, ... }.Inner`, is opaque, and `*volatile const`
# declares nothing; each negative a crafted field-read row, each twin's receiver declaring the field
if FULL and want(568): results.append(_same_named('568-SM3-a-container-literal-s-suffix-is-opaque', 'const R39RightSuffix = struct {\n    const R = struct {\n        lock: u8 = 0,\n        const Inner = struct {\n            state: u8 = 0,\n        };\n    }.Inner;\n    fn r39s(self: *R) u8 {\n        return self.lock;\n    }\n};', True))
if FULL and want(569): results.append(_same_named('569-SM3-the-receiver-s-whole-container-literal-declares-it-local-twin', 'const R39RightSuffixT = struct {\n    const R = struct {\n        lock: u8 = 0,\n        const Inner = struct {\n            state: u8 = 0,\n        };\n    };\n    fn r39st(self: *R) u8 {\n        return self.lock;\n    }\n};', False))
if FULL and want(570): results.append(_same_named('570-OK4-a-volatile-const-pointer-type-is-no-declaration', 'const R39HolderK4 = struct {\n    lock: u8 = 0,\n};\nconst R39K4 = struct {\n    state: u8 = 0,\n};\nconst R39RightK4 = struct {\n    const p: *volatile const R39K4 = R39HolderK4;\n    fn r39k4(self: *R39K4) u8 {\n        return self.lock;\n    }\n};', True))
if FULL and want(571): results.append(_same_named('571-OK4-the-receiver-s-container-declares-it-local-twin', 'const R39HolderK4t = struct {\n    lock: u8 = 0,\n};\nconst R39K4t = struct {\n    lock: u8 = 0,\n};\nconst R39RightK4t = struct {\n    const p: *volatile const R39K4t = R39HolderK4t;\n    fn r39k4t(self: *R39K4t) u8 {\n        return self.lock;\n    }\n};', False))
# -- r39 (round 38's lead direction, item 8): the dump's checks as controls. The gate reads a file only after zigast.py
# accepts its parse: a dump whose tiling is broken (a node moved under a node that does not hold it) fails AST-TILING, a
# dump whose tokens differ from zigtok's (a token's end moved) fails AST-TOKENS, the dump passed through unchanged
# passes, and a gate given no astdump exits 2 (BAD-SETUP). Each wraps the 1B compiler's astdump.


def _astdump_wrapper(tag, mode):
    """A stand-in astdump (a Python script beside the logs): the real one's dump, then `mode` applied to the file
    r39_tamper.zig: "tiling" moves its last node under a node whose span does not hold it, "tokens" moves one
    identifier token's end, "none" changes nothing; r40 (round 39's Opus L2): "twice" lists its last node again under
    another parent, "unreached" drops its last node, "overlap" stretches a node over its next sibling, "unwalked"
    reports a tag the walk does not know, "role" relabels a builtin's argument."""
    p = os.path.join(logdir, tag + "-astdump.py")
    open(p, "w", encoding="utf-8", newline="\n").write(
        "import subprocess, sys\n"
        f"REAL, MODE = {ASTDUMP['1b']!r}, {mode!r}\n"
        "out, lst = sys.argv[1:3]\n"
        "r = subprocess.run([REAL, out, lst])\n"
        "if r.returncode:\n    sys.exit(r.returncode)\n"
        "L = open(out, encoding='utf-8').read().split('\\n')\n"
        "a = next(i for i, l in enumerate(L) if l.startswith('F ') and l.endswith('r39_tamper.zig'))\n"
        "e = next(i for i in range(a, len(L)) if L[i] == 'E')\n"
        "if MODE == 'tiling':\n"
        "    k = next(i for i in range(a, e) if L[i].startswith('N ')) + 1\n"
        "    rows = [(i, L[i].split(' ')) for i in range(k, e) if not L[i].startswith('X ')]\n"
        "    i, p = rows[-1]\n"
        "    f, l = int(p[3]), int(p[4])\n"
        "    q = next(q for _, q in rows if int(q[4]) < f or int(q[3]) > l)\n"
        "    p[5] = q[0]\n"
        "    L[i] = ' '.join(p)\n"
        "elif MODE == 'tokens':\n"
        "    k = next(i for i in range(a, e) if L[i].startswith('K ')) + 1\n"
        "    i = next(i for i in range(k, e) if L[i].startswith('identifier '))\n"
        "    t_, s_, e_ = L[i].split(' ')\n"
        "    L[i] = f'{t_} {s_} {int(e_) + 1}'\n"
        "elif MODE in ('twice', 'unreached', 'overlap', 'unwalked', 'role'):\n"
        "    k = next(i for i in range(a, e) if L[i].startswith('N ')) + 1\n"
        "    rows = [i for i in range(k, e) if not L[i].startswith('X ')]\n"
        "    last = L[rows[-1]].split(' ')\n"
        "    if MODE == 'twice':\n"
        "        dup = list(last)\n"
        "        dup[5] = '0'\n"
        "        L.insert(rows[-1] + 1, ' '.join(dup))\n"
        "    elif MODE == 'unreached':\n"
        "        del L[rows[-1]]\n"
        "    elif MODE == 'overlap':\n"
        "        by = {}\n"
        "        for i in rows:\n"
        "            by.setdefault(L[i].split(' ')[5], []).append((int(L[i].split(' ')[3]), i))\n"
        "        grp = sorted(next(g for g in reversed(list(by.values())) if len(g) >= 2))\n"
        "        (f1, i1), (f2, i2) = grp[0], grp[1]\n"
        "        q = L[i1].split(' ')\n"
        "        q[4] = str(f2)\n"
        "        L[i1] = ' '.join(q)\n"
        "    elif MODE == 'unwalked':\n"
        "        L.insert(e, 'X unwalked-tag ' + last[0])\n"
        "    else:\n"
        "        i = next(i for i in rows if L[i].split(' ')[6] == 'arg')\n"
        "        q = L[i].split(' ')\n"
        "        q[6] = 'operand'\n"
        "        L[i] = ' '.join(q)\n"
        "open(out, 'w', encoding='utf-8', newline='\\n').write('\\n'.join(L))\n")
    return p


TAMPER_FILE = 'const Local = struct {\n    pub const Mutex = u8;\n};\npub const has = @hasDecl(Local, "Mutex");\n'
if want(572): results.append(residue_control("572-LD-a-dump-whose-tiling-is-broken-fails", write_into(
    "src/r39_tamper.zig", TAMPER_FILE), 1, {"AST-TILING": 1}, astdump=_astdump_wrapper("572", "tiling")))
if want(573): results.append(residue_control("573-LD-a-dump-whose-tokens-differ-fails", write_into(
    "src/r39_tamper.zig", TAMPER_FILE), 1, {"AST-TOKENS": 1}, astdump=_astdump_wrapper("573", "tokens")))
if want(574): results.append(residue_control("574-LD-the-dump-passed-through-unchanged-passes-local-twin", write_into(
    "src/r39_tamper.zig", TAMPER_FILE), 1, {}, astdump=_astdump_wrapper("574", "none")))
if want(575): results.append(residue_control("575-LD-a-gate-given-no-astdump-exits-2", None, 2, {}, exp_text=("BAD-SETUP",),
                                              astdump=""))
# -- r40 (round 39's Opus L1): the gate and the binding check read a tree only through the astdump its pinned compiler
# (build.zig.zon's minimum_zig_version) built: the v1.4.0 tree read with the 1A compiler's, and the fork head checked
# with the 1B compiler's, each exit 2 (BAD-SETUP)
if want(626): results.append(residue_control("626-OL1-the-v1-4-0-tree-read-with-the-1a-compiler-s-astdump-exits-2", None,
                                              2, {}, exp_text=("BAD-SETUP",), astdump=ASTDUMP.get("1a", "")))
if FULL and want(627): results.append(bindcheck_control(
    "627-OL1-the-fork-head-checked-with-the-1b-compiler-s-astdump-exits-2", os.path.join(logdir, "inv-00-base"), None, 2,
    ("BAD-SETUP",), {}, astdump=ASTDUMP.get("1b", "")))
# -- r40 (round 39's Opus L2): a tamper control for each way a dump can fail its checks (572 and 573: a node outside
# its parent, a token's end): a node listed twice, a node dropped, siblings overlapping, a tag the walk does not know
# (AST-TILING each), and a relabelled role (AST-ROLES, the fixed per-tag role table)
if want(628): results.append(residue_control("628-OL2-a-dump-listing-a-node-twice-fails", write_into(
    "src/r39_tamper.zig", TAMPER_FILE), 1, {"AST-TILING": 1}, astdump=_astdump_wrapper("628", "twice")))
if want(629): results.append(residue_control("629-OL2-a-dump-missing-a-node-fails", write_into(
    "src/r39_tamper.zig", TAMPER_FILE), 1, {"AST-TILING": 1}, astdump=_astdump_wrapper("629", "unreached")))
if want(630): results.append(residue_control("630-OL2-a-dump-whose-siblings-overlap-fails", write_into(
    "src/r39_tamper.zig", TAMPER_FILE), 1, {"AST-TILING": 1}, astdump=_astdump_wrapper("630", "overlap")))
if want(631): results.append(residue_control("631-OL2-a-dump-reporting-an-unwalked-tag-fails", write_into(
    "src/r39_tamper.zig", TAMPER_FILE), 1, {"AST-TILING": 1}, astdump=_astdump_wrapper("631", "unwalked")))
if want(632): results.append(residue_control("632-OL2-a-dump-with-a-wrong-role-fails-the-role-table", write_into(
    "src/r39_tamper.zig", TAMPER_FILE), 1, {"AST-ROLES": 1}, astdump=_astdump_wrapper("632", "role")))
# -- r40 (round 39's Sol M1): which self-test jobs a pull request's changed files select (selftest_jobs.py, installed
# beside this file; CI's first step runs it on `git diff --name-only`): an astdump-only change selects both jobs,
# since each builds both astdump executables from the PR's ci/astdump.zig; a reviewed table the appending mode alone;
# a change under src/ neither


def jobs_control(tag, changed, exp_text):
    lst = os.path.join(logdir, tag[:3] + "-changed.txt")
    open(lst, "w", encoding="utf-8", newline="\n").write("".join(p_ + "\n" for p_ in changed))
    rc, out = run([py, "-I", os.path.join(here, "selftest_jobs.py"), lst])
    ok = rc == 0 and out.strip() == exp_text   # the selector's documented rule (selftest_jobs.py)
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## selftest_jobs.py (exit {rc})\n{out}\nexpected: exit 0, {exp_text!r}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: jobs {out.strip() or '(no output)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


if want(633): results.append(jobs_control("633-SM1-an-astdump-only-change-selects-both-self-test-jobs",
                                          ["ci/astdump.zig"], "full appending"))
if want(634): results.append(jobs_control("634-SM1-a-reviewed-table-change-selects-the-appending-job-alone",
                                          ["ci/lock-inventory-threads.tsv"], "appending"))
if want(635): results.append(jobs_control("635-SM1-a-change-under-src-selects-neither-job", ["src/Surface.zig"], "none"))
# -- r41 (round 40's Opus M3): a tree pinned below 0.17 fails ACTIVE-015-SELECTION on its pin and the gate reads none of
# its Zig files, so it needs no astdump at all (665: 214's tree, given none; the residue job never needs the 1A
# compiler); the self-test jobs install the 1A compiler with a version they read at run time from the fixture's
# build.zig.zon, in the one step §7.8's exception names (.github/workflows/test.yml, step id zig-1a, its
# `setup-zig-step` row; r42: one row per job, selftest-full and selftest-appending, bound to the producer step
# pin-1a and its sha256): the frozen tree's workflows pass with those steps present (666, the rows then satisfied), a
# literal 0.15 setup-zig in another workflow still fails (667), and so does a setup-zig version that is no literal in a
# step no row names (668) or the named id in another workflow (669)


R42_ZIG = "mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29"
R42_PIN_RUN = ("          $m = Select-String -Path ci/fixture/build.zig.zon -Pattern '\\.minimum_zig_version\\s*=\\s*\"([^\"]+)\"'\n"
               "          \"version=$($m.Matches[0].Groups[1].Value)\" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append\n")


def _selftest_1a_job(step_id="zig-1a", job="selftest-full", version="${{ steps.pin-1a.outputs.version }}",
                     pin_run=R42_PIN_RUN, pin_note="", with_="        with:\n", more=""):
    """r41: the self-test job's two steps as §3 gives them: read the 1A compiler's version from the fixture's
    build.zig.zon, then set that compiler up (no version written out anywhere). r42 (round 41's lead direction, item
    5): each self-test job by its id (selftest-full, selftest-appending), whose `setup-zig-step` row names the job,
    the step, the producer step pin-1a and the sha256 of the producer's text as ciyaml.py gives it; the arguments are
    the parts the exception's controls change, and `more` the steps after the two."""
    return ("\n  " + job + ":\n    runs-on: windows-2022\n    steps:\n"
            "      - name: Read the 1A compiler's version from the frozen fixture\n        id: pin-1a\n" + pin_note
            + "        shell: pwsh\n        run: |\n" + pin_run
            + "      - name: Set up the 1A compiler, for the 1A astdump\n        id: " + step_id + "\n"
            "        uses: " + R42_ZIG + " # v2.2.1\n" + with_
            + "          version: " + version + "\n          use-cache: false\n" + more)


def _selftest_jobs():
    """r42: the two self-test jobs as test.yml holds them after the cutover (§3)."""
    return _selftest_1a_job(job="selftest-full") + _selftest_1a_job(job="selftest-appending")


R42_ROW_FULL = "in the job `selftest-full` matches"   # r42: the stale line of each self-test job's row
R42_ROW_APP = "in the job `selftest-appending` matches"


if want(665): results.append(residue_control("665-OM3-a-tree-pinned-below-0-17-given-no-astdump-fails-on-its-pin-alone",
                                              edit_into("build.zig.zon", V140_ZON, '.minimum_zig_version = "0.15.2",'),
                                              1, {"ACTIVE-015-SELECTION": 1, "RESIDUE-015": 1}, astdump="",
                                              v140_extra="text"))
if want(666): results.append(residue_control("666-OM3-the-frozen-tree-s-workflows-pass-with-the-self-test-s-1a-step",
                                              write_into(".github/workflows/test.yml", _selftest_jobs(), "a"), 0, {},
                                              v140_drop=(R42_ROW_FULL, R42_ROW_APP)))
if want(667): results.append(residue_control("667-OM3-a-literal-0-15-setup-zig-in-another-workflow-fails", write_into(
    ".github/workflows/nix.yml", "\n  r41-literal:\n    runs-on: ubuntu-latest\n    steps:\n      - name: Set up Zig\n"
    "        uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1\n        with:\n"
    "          version: 0.15.2\n", "a"), 1, {"ACTIVE-015-SELECTION": 1, "RESIDUE-015": 1}))
if want(668): results.append(residue_control("668-OM3-a-setup-zig-version-that-is-no-literal-in-an-unnamed-step-fails",
                                              write_into(".github/workflows/test.yml", _selftest_1a_job("zig-other"),
                                                         "a"), 1, {"ACTIVE-015-SELECTION": 1}))
if want(669): results.append(residue_control("669-OM3-the-named-step-id-in-another-workflow-fails", write_into(
    ".github/workflows/nix.yml", _selftest_1a_job(), "a"), 1, {"ACTIVE-015-SELECTION": 1}))
# -- r42 (round 41's Opus M1, L2, Sol M1, Opus M2 and the lead's direction, items 1, 4, 5 and 7): the pin read once,
# strictly: a build.zig.zon with one 0xE9 byte, and a root BUILD.ZIG.ZON, each pinned below 0.17 over a shim, are
# BAD-SETUP; their twins, the byte written as UTF-8 and the exact name, are read and fail on the pin (670 to 673). Every
# CI file under .github/ and every local action read through ciyaml.py's closed subset: Sol's flow mapping, quoted
# version key, quoted uses key, alias, JSON form and local composite, Opus V1 to V8, an escaped double-quoted uses, a
# local action outside .github/, a setup-zig mention in a run script and a block-scalar uses; each version hidden from
# r41's line scanner by a format() expression, each twin the same selection in the subset's form (failing on it) or the
# same step with a literal 0.17 version (passing) (678 to 707). The exception bound to its job, step, producer and the
# producer's sha256: a job no row names, another expression, a changed producer, a row no step matches and a row two
# steps match, each with its twin (708 to 717). The bundle's own dump tool, ci/astdump.zig, keeps three feature tests on
# std by design (its rows): a fourth fails, a fourth on a local passes (718, 719)
R42_SHIM = 'const std = @import("std");\npub const has = @hasDecl(std.Io, "Threaded");\n'
R42_E1 = "\"${{ format('0.{0}.{1}', 15, 2) }}\""   # r42: a 0.15 selection the text check does not see
R42_E2 = "\"${{ format('0.{0}.2', 15) }}\""
R42_E3 = "\"${{ format('{0}.15.2', 0) }}\""
R42_E4 = "\"${{ format('0.1{0}.2', 5) }}\""
R42_E5 = "\"${{ format('{0}.{1}.{2}', 0, 15, 2) }}\""
R42_E6 = "\"${{ format('0.{1}.{0}', 2, 15) }}\""
R42_E7 = "\"${{ format('0.{0}{1}.2', 1, 5) }}\""
R42_DUP = ("      - name: Set up the 1A compiler again\n        id: zig-1a\n        uses: " + R42_ZIG + "\n        with:\n"
           "          version: ${{ steps.pin-1a.outputs.version }}\n")
V140_TEST_CI = tuple(x_ for _, x_ in V140_EXTRA if x_.startswith("ACTIVE-015-SELECTION .github/workflows/test.yml:"))
ASTDUMP_LEGACY = 'const legacy_ast = @hasDecl(Node, "AsmLegacy");\n'


def zon_into(name, pin, prefix=b""):
    """r42: the tree's build.zig.zon with its pin replaced, written back as `name` at the root (the original removed
    first), after `prefix`, raw bytes."""
    def f(root):
        p = os.path.join(root, "build.zig.zon")
        text = open(p, encoding="utf-8").read()
        assert text.count(V140_ZON) == 1, "the tree's pin"
        os.remove(p)
        open(os.path.join(root, name), "wb").write(prefix + text.replace(V140_ZON, pin).encode("utf-8"))
    return f


def row_copy_into(job_from, job_to):
    """r42: the allowance's setup-zig-step row for test.yml's `job_from`, appended once more for `job_to`."""
    def f(root):
        p = os.path.join(root, "ci", "residue-allow.tsv")
        text = open(p, encoding="utf-8").read()
        rows = [l for l in text.splitlines() if l.startswith("setup-zig-step\t.github/workflows/test.yml\t" + job_from + "\t")]
        assert len(rows) == 1, rows
        p_ = rows[0].split("\t")
        p_[2] = job_to
        os.remove(p)
        open(p, "w", encoding="utf-8", newline="\n").write(text + "\t".join(p_) + "\n")
    return f


def _r42_wf(steps, env=""):
    """r42: a workflow of one job whose steps are the given lines (each step at six spaces)."""
    return "name: r42\non: push\njobs:\n  r42-build:\n    runs-on: ubuntu-latest\n" + env + "    steps:\n" + steps


def _r42_zig(version, with_=None, uses=None):
    """r42: a setup-zig step; its with a block mapping holding `version`, or the lines given."""
    return ("      - uses: " + (uses or R42_ZIG) + "\n"
            + (with_ if with_ is not None else "        with:\n          version: " + version + "\n"))


def _r42_action(version):
    """r42: a local composite action whose one step sets up Zig."""
    return ("name: r42 zig\ndescription: sets up Zig\nruns:\n  using: composite\n  steps:\n    - uses: " + R42_ZIG
            + "\n      with:\n        version: " + version + "\n")


def _r42_ci(n, text):
    return write_into(f".github/workflows/r42-{n}.yml", text)


if want(670): results.append(residue_control("670-OM1-a-build-zig-zon-with-a-0xe9-byte-pinned-0-15-2-is-bad-setup", both(
    zon_into("build.zig.zon", '.minimum_zig_version = "0.15.2",', b"// caf\xe9: one Latin-1 byte\n"),
    write_into("src/r42_shim.zig", R42_SHIM)), 2, {}, exp_text=("BAD-SETUP", "build.zig.zon is not valid UTF-8")))
if want(671): results.append(residue_control("671-OM1-the-same-byte-as-utf-8-is-read-and-fails-on-the-pin-utf-8-twin", both(
    zon_into("build.zig.zon", '.minimum_zig_version = "0.15.2",', "// caf\u00e9: one Latin-1 byte\n".encode("utf-8")),
    write_into("src/r42_shim.zig", R42_SHIM)), 1, {"ACTIVE-015-SELECTION": 1, "RESIDUE-015": 1}, v140_extra="text"))
if want(672): results.append(residue_control("672-OM1-a-root-BUILD-ZIG-ZON-pinned-0-16-is-bad-setup", both(
    zon_into("BUILD.ZIG.ZON", '.minimum_zig_version = "0.16.0",'), write_into("src/r42_shim.zig", R42_SHIM)), 2, {},
    exp_text=("BAD-SETUP", "a case variant of build.zig.zon or build.zig at the root (BUILD.ZIG.ZON)")))
if want(673): results.append(residue_control("673-OM1-the-same-pin-under-the-exact-name-fails-on-it-name-twin", both(
    zon_into("build.zig.zon", '.minimum_zig_version = "0.16.0",'), write_into("src/r42_shim.zig", R42_SHIM)), 1,
    {"ACTIVE-015-SELECTION": 1}, v140_extra="text"))
if want(678): results.append(residue_control("678-SM1-OV1-a-flow-mapping-with-fails-unreadable", _r42_ci(678, _r42_wf(
    _r42_zig("", "        with: {version: " + R42_E1 + "}\n"))), 1, {"CI-UNREADABLE": 1}))
if want(679): results.append(residue_control("679-SM1-OV1-the-same-with-as-a-block-mapping-fails-on-its-version-block-twin",
    _r42_ci(679, _r42_wf(_r42_zig(R42_E1))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(680): results.append(residue_control("680-SM1-OV2-a-quoted-version-key-fails-unreadable", _r42_ci(680, _r42_wf(
    _r42_zig("", "        with:\n          \"version\": " + R42_E2 + "\n"))), 1, {"CI-UNREADABLE": 1}))
if want(681): results.append(residue_control("681-SM1-OV2-the-plain-key-fails-on-its-version-plain-twin", _r42_ci(681, _r42_wf(
    _r42_zig(R42_E2))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(682): results.append(residue_control("682-SM1-a-quoted-uses-key-fails-unreadable", _r42_ci(682, _r42_wf(
    "      - \"uses\": " + R42_ZIG + "\n        with:\n          version: " + R42_E3 + "\n")), 1, {"CI-UNREADABLE": 1}))
if want(683): results.append(residue_control("683-SM1-the-plain-uses-key-fails-on-its-version-plain-twin", _r42_ci(683, _r42_wf(
    _r42_zig(R42_E3))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(684): results.append(residue_control("684-SM1-an-alias-gives-the-step-its-with-and-fails-unreadable", _r42_ci(684, _r42_wf(
    _r42_zig("", "        with: *r42zig\n"), env="    env: &r42zig\n      version: " + R42_E4 + "\n")), 1,
    {"CI-UNREADABLE": 1}))
if want(685): results.append(residue_control("685-SM1-the-mapping-written-out-fails-on-its-version-written-out-twin", _r42_ci(
    685, _r42_wf(_r42_zig(R42_E4), env="    env:\n      version: " + R42_E4 + "\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(686): results.append(residue_control("686-SM1-a-json-form-workflow-fails-unreadable", _r42_ci(686,
    '{"name": "r42", "on": "push", "jobs": {"r42-build": {"runs-on": "ubuntu-latest", "steps": [{"uses": "' + R42_ZIG
    + '", "with": {"version": ' + R42_E5 + '}}]}}}\n'), 1, {"CI-UNREADABLE": 1}))
if want(687): results.append(residue_control("687-SM1-the-same-workflow-in-block-form-fails-on-its-version-block-twin", _r42_ci(
    687, _r42_wf(_r42_zig(R42_E5))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(688): results.append(residue_control("688-SM1-OV6-a-local-composite-action-under-github-is-read-and-fails", both(
    _r42_ci(688, _r42_wf("      - uses: ./.github/actions/r42-zig\n")),
    write_into(".github/actions/r42-zig/action.yml", _r42_action(R42_E6))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(689): results.append(residue_control("689-SM1-OV6-the-action-with-a-literal-0-17-passes-literal-twin", both(
    _r42_ci(689, _r42_wf("      - uses: ./.github/actions/r42-zig\n")),
    write_into(".github/actions/r42-zig/action.yml", _r42_action("0.17.1"))), 0, {}))
if want(690): results.append(residue_control("690-OV3-a-setup-zig-step-with-no-version-after-checking-out-the-fixture-fails",
    _r42_ci(690, _r42_wf("      - uses: actions/checkout@v4\n        with:\n          ref: 31796f5d093fce41446411c5c381b602c1c55757\n"
                         "      - uses: " + R42_ZIG + "\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(691): results.append(residue_control("691-OV3-the-step-with-a-literal-0-17-passes-literal-twin", _r42_ci(691, _r42_wf(
    "      - uses: actions/checkout@v4\n        with:\n          ref: 31796f5d093fce41446411c5c381b602c1c55757\n"
    + _r42_zig("0.17.1"))), 0, {}))
if want(692): results.append(residue_control("692-OV4-the-zig-1a-step-s-with-anchored-and-aliased-in-another-job-fails-unreadable",
    write_into(".github/workflows/test.yml", _selftest_1a_job(with_="        with: &z1a\n")
               + _selftest_1a_job(job="selftest-appending") + "\n  r42-other:\n    runs-on: ubuntu-latest\n    steps:\n"
               "      - uses: " + R42_ZIG + "\n        with: *z1a\n", "a"), 1, {"CI-UNREADABLE": 1},
    v140_drop=V140_TEST_CI))
if want(693): results.append(residue_control("693-OV4-the-with-written-out-in-the-other-job-fails-on-it-written-out-twin",
    write_into(".github/workflows/test.yml", _selftest_jobs() + "\n  r42-other:\n    runs-on: ubuntu-latest\n    steps:\n"
               "      - uses: " + R42_ZIG + "\n        with:\n          version: ${{ steps.pin-1a.outputs.version }}\n", "a"),
    1, {"ACTIVE-015-SELECTION": 1}, v140_drop=(R42_ROW_FULL, R42_ROW_APP)))
if want(694): results.append(residue_control("694-OV5-a-third-job-with-its-own-zig-1a-step-fails", write_into(
    ".github/workflows/test.yml", _selftest_jobs() + _selftest_1a_job(job="selftest-extra"), "a"), 1,
    {"ACTIVE-015-SELECTION": 1}, v140_drop=(R42_ROW_FULL, R42_ROW_APP)))
if want(695): results.append(residue_control("695-OV5-the-third-job-with-a-literal-0-17-passes-literal-twin", write_into(
    ".github/workflows/test.yml", _selftest_jobs() + _selftest_1a_job(job="selftest-extra", version="0.17.1"), "a"), 0, {},
    v140_drop=(R42_ROW_FULL, R42_ROW_APP)))
if want(696): results.append(residue_control("696-OV7-a-block-scalar-with-a-dash-line-before-uses-is-read-whole-and-fails",
    _r42_ci(696, _r42_wf("      - with:\n          version: " + R42_E7 + "\n          body: |\n            - name: not a step\n"
                         "        uses: " + R42_ZIG + "\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(697): results.append(residue_control("697-OV7-the-same-step-with-a-literal-0-17-passes-literal-twin", _r42_ci(697, _r42_wf(
    "      - with:\n          version: 0.17.1\n          body: |\n            - name: not a step\n        uses: " + R42_ZIG
    + "\n")), 0, {}))
if want(698): results.append(residue_control("698-OV8-a-case-variant-version-key-fails-unreadable", _r42_ci(698, _r42_wf(
    _r42_zig("", "        with:\n          Version: " + R42_E1 + "\n"))), 1, {"CI-UNREADABLE": 1}))
if want(699): results.append(residue_control("699-OV8-the-lower-case-key-fails-on-its-version-case-twin", _r42_ci(699, _r42_wf(
    _r42_zig(R42_E1))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(700): results.append(residue_control("700-an-escaped-double-quoted-uses-fails-unreadable", _r42_ci(700, _r42_wf(
    _r42_zig(R42_E2, uses='"mlugg/setup\\u002dzig@d1434d08867e3ee9daa34448df10607b98908d29"'))), 1,
    {"CI-UNREADABLE": 1}))
if want(701): results.append(residue_control("701-the-same-uses-unescaped-fails-on-its-version-unescaped-twin", _r42_ci(701, _r42_wf(
    _r42_zig(R42_E2, uses='"' + R42_ZIG + '"'))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(702): results.append(residue_control("702-a-local-action-outside-github-is-read-and-fails", both(
    _r42_ci(702, _r42_wf("      - uses: ./tools/r42-zig\n")), write_into("tools/r42-zig/action.yml", _r42_action(R42_E6))),
    1, {"ACTIVE-015-SELECTION": 1}))
if want(703): results.append(residue_control("703-the-action-outside-github-with-a-literal-0-17-passes-literal-twin", both(
    _r42_ci(703, _r42_wf("      - uses: ./tools/r42-zig\n")), write_into("tools/r42-zig/action.yml", _r42_action("0.17.1"))),
    0, {}))
if want(704): results.append(residue_control("704-a-setup-zig-mention-in-a-run-script-fails", _r42_ci(704, _r42_wf(
    "      - name: r42\n        run: echo mlugg/setup-zig\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(705): results.append(residue_control("705-the-mention-in-a-comment-passes-comment-twin", _r42_ci(705, _r42_wf(
    "      - name: r42\n        run: echo r42 # mlugg/setup-zig\n")), 0, {}))
if want(706): results.append(residue_control("706-a-block-scalar-uses-fails-unreadable", _r42_ci(706, _r42_wf(
    "      - uses: >-\n          " + R42_ZIG + "\n        with:\n          version: " + R42_E3 + "\n")), 1, {"CI-UNREADABLE": 1}))
if want(707): results.append(residue_control("707-the-plain-uses-fails-on-its-version-plain-twin", _r42_ci(707, _r42_wf(
    _r42_zig(R42_E3))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(708): results.append(residue_control("708-the-self-test-s-steps-in-a-job-no-row-names-fail", write_into(
    ".github/workflows/test.yml", _selftest_1a_job(job="selftest-nightly"), "a"), 1, {"ACTIVE-015-SELECTION": 1}))
if want(709): results.append(residue_control("709-the-steps-in-the-job-its-row-names-pass-job-twin", write_into(
    ".github/workflows/test.yml", _selftest_1a_job(job="selftest-full"), "a"), 0, {}, v140_drop=(R42_ROW_FULL,)))
if want(710): results.append(residue_control("710-the-bound-step-s-version-another-expression-fails", write_into(
    ".github/workflows/test.yml", _selftest_1a_job(version="${{ steps.pin-1a.outputs.version || 'master' }}"), "a"), 1,
    {"ACTIVE-015-SELECTION": 1}, v140_drop=(R42_ROW_FULL,)))
if want(711): results.append(residue_control("711-the-exact-expression-in-the-other-job-passes-expression-twin", write_into(
    ".github/workflows/test.yml", _selftest_1a_job(job="selftest-appending"), "a"), 0, {}, v140_drop=(R42_ROW_APP,)))
if want(712): results.append(residue_control("712-a-producer-step-reading-another-zon-fails", write_into(
    ".github/workflows/test.yml", _selftest_1a_job(pin_run=R42_PIN_RUN.replace("ci/fixture/build.zig.zon", "build.zig.zon")),
    "a"), 1, {"ACTIVE-015-SELECTION": 1}, v140_drop=(R42_ROW_FULL,)))
if want(713): results.append(residue_control("713-a-comment-between-the-producer-s-keys-passes-comment-twin", write_into(
    ".github/workflows/test.yml", _selftest_1a_job(pin_note="        # the frozen fixture's pin, read at run time\n"), "a"),
    0, {}, v140_drop=(R42_ROW_FULL,)))
if want(714): results.append(residue_control("714-a-row-that-matches-no-step-fails", both(write_into(
    ".github/workflows/test.yml", _selftest_jobs(), "a"), row_copy_into("selftest-full", "selftest-nightly")), 1,
    {"STALE-ALLOWANCE": 1}, v140_drop=(R42_ROW_FULL, R42_ROW_APP)))
if want(715): results.append(residue_control("715-the-row-s-job-present-passes-no-match-twin", both(write_into(
    ".github/workflows/test.yml", _selftest_jobs() + _selftest_1a_job(job="selftest-nightly"), "a"),
    row_copy_into("selftest-full", "selftest-nightly")), 0, {}, v140_drop=(R42_ROW_FULL, R42_ROW_APP)))
if want(716): results.append(residue_control("716-two-setup-zig-steps-matching-one-row-fail", write_into(
    ".github/workflows/test.yml", _selftest_1a_job(more=R42_DUP) + _selftest_1a_job(job="selftest-appending"), "a"), 1,
    {"ACTIVE-015-SELECTION": 1}, v140_drop=(R42_ROW_FULL, R42_ROW_APP)))
if want(717): results.append(residue_control("717-the-second-step-under-another-id-with-a-literal-0-17-passes-id-twin", write_into(
    ".github/workflows/test.yml", _selftest_1a_job(more=R42_DUP.replace("id: zig-1a", "id: zig-1b").replace(
        "${{ steps.pin-1a.outputs.version }}", "0.17.1")) + _selftest_1a_job(job="selftest-appending"), "a"), 0, {},
    v140_drop=(R42_ROW_FULL, R42_ROW_APP)))
if want(718): results.append(residue_control("718-a-fourth-feature-test-on-std-in-ci-astdump-zig-fails", edit_into(
    "ci/astdump.zig", ASTDUMP_LEGACY, ASTDUMP_LEGACY + 'const r42_fourth = @hasDecl(Ast, "Location");\n'), 1,
    {"PRODUCTION-SHIM": 1}))
if want(719): results.append(residue_control("719-a-fourth-on-a-local-container-passes-local-twin", edit_into(
    "ci/astdump.zig", ASTDUMP_LEGACY, ASTDUMP_LEGACY + 'const R42Local = struct {};\n'
    'const r42_fourth = @hasDecl(R42Local, "Location");\n'), 0, {}))
# -- r43 (round 42's Sol M1 to M3, Opus M1 to M3, L1 to L4 and the lead's direction, items 1 to 8): one narrow spelling
# of each input. The characters of a CI file (720 to 743): Sol's CR-only workflow and a CR LF one with one CR-only
# break, Opus's lone CR, NEL, LS and PS after a ` #` (each hiding a setup-zig step from r42), the same in a local
# composite, the lone CR hiding a key in the pin-1a producer without changing its sha256, a tab after a colon, Opus's
# `ver` + long s + `ion` beside `version`, a form feed and a mid-file byte-order mark; each twin LF, CR LF or ASCII.
# The pin (744 to 753): Sol's and Opus's quoted, escaped root fields behind a comment, a comment-only field, a duplicate
# root field, and the binding check given Sol's spelling (752); each twin the plain field. The uses grammar (754 to
# 763): Sol's `./ci/local@legacy` beside a benign `ci/local/` and `.\ci\actual`, a local path in another case, a
# remote uses with no @ref, a local action directory holding nothing; each twin the accepted spelling, the last a
# Docker action with only a Dockerfile, outside the boundary. The tracked set (764 to 769, each on a git checkout of
# its own): Opus's case-colliding workflows (the index holds both), a tracked file missing from the checkout, a tracked
# .zig file under the root's zig-out/; each twin the ordinary form. The boundary's outer edge (780 to 791): a run script
# that computes a version, a remote installer other than setup-zig, a remote reusable workflow, a container image, a
# local JavaScript and a local Docker action whose own code selects 0.15, each passing by design; each twin the same
# selection where the gate reads it (a literal, a setup-zig step, a local reusable workflow), failing
R43_SOL = ["name: Review # safe comment", "on: push", "jobs:", "  build:", "    runs-on: windows-latest", "    steps:",
           "      - uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29", "        with:",
           "          version: \"${{ format('0.{0}.{1}', 15, 2) }}\""]
R43_OPUS_HEAD = "name: probe\non: push\njobs:\n  build:\n    runs-on: windows-latest\n    steps:\n"


def _r43_opus(br):
    """r43: Opus's round-42 probe, its hidden step after `br` (a lone CR, NEL, LS or PS; LF for the twin)."""
    return (R43_OPUS_HEAD + "      - run: echo hi #" + br + "      - uses: mlugg/setup-zig@v2" + br + "        with:" + br
            + "          version: ${{ format('0.{0}.{1}', 15, 2) }}\n")


def _r43_ci(n, text):
    return write_into(f".github/workflows/r43-{n}.yml", text)


def _r43_composite(br):
    """r43: a local composite action whose setup-zig step follows `br` after a ` #`."""
    return ("name: r43 zig\ndescription: sets up Zig\nruns:\n  using: composite\n  steps:\n    - shell: bash\n"
            "      run: echo hi #" + br + "    - uses: " + R42_ZIG + br + "      with:" + br + "        version: " + R42_E1
            + "\n")


R43_PRODUCER = "from the frozen fixture\n"
R43_BENIGN = "name: r43 benign\ndescription: reviewed\nruns:\n  using: composite\n  steps:\n    - shell: pwsh\n      run: echo reviewed\n"
R43_ZON_SOL = '// .minimum_zig_version = "0.17.1",\n    .@"minimum_zig_\\x76ersion" = "0.\\x31\\x35.2",'
R43_ZON_OPUS = '// .minimum_zig_version = "0.17.1",\n    .@"minimum\\x5fzig_version" = "0.\\x315.2",'
R43_GIT_ZON = '.{\n    .name = .r43_git,\n    .version = "0.0.0",\n    .minimum_zig_version = "0.17.0",\n    .paths = .{""},\n}\n'
R43_WF_017 = _r42_wf(_r42_zig("0.17.1"))
R43_WF_015 = _r42_wf(_r42_zig(R42_E1))
R43_WF_BENIGN = _r42_wf("      - run: echo r43\n")
R43_SHIM = 'const std = @import("std");\npub const has = @hasDecl(std.Io, "Threaded");\n'


def _zon_overlay(tag, pin_line):
    """r43: a directory holding only the fixture's build.zig.zon, its pin line replaced, for the binding check's
    --overlay (every other file read from the revision)."""
    d = os.path.join(logdir, tag + "-overlay")
    os.makedirs(d, exist_ok=True)
    text = open(os.path.join(FIX, "build.zig.zon"), encoding="utf-8").read()
    old = '.minimum_zig_version = "0.15.2",'
    assert text.count(old) == 1, "the fixture's pin"
    open(os.path.join(d, "build.zig.zon"), "w", encoding="utf-8", newline="\n").write(text.replace(old, pin_line))
    return d


def git_control(tag, files, exp_exit, exp_kinds, index_only=(), untracked=None, remove=()):
    """r43 (round 42's Opus M3 and L1, the lead's direction, items 4 and 5): the residue gate on a small git checkout of
    its own (a build.zig.zon pinned 0.17.0 and `files`, committed; `index_only`: (path, text) entries the index holds
    with no file of that spelling in the checkout, as a case-insensitive clone of a case-colliding commit leaves it;
    `remove`: tracked files then deleted; `untracked`: files written after the commit), with an empty allowance, so
    the gate reads the tree by its tracked list (`git ls-files -z`)."""
    root = os.path.join(logdir, "residue", tag)
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    git_ = ["git", "-C", root, "-c", "core.autocrlf=false", "-c", "init.templateDir=", "-c", "user.name=r43",
            "-c", "user.email=r43@example.invalid", "-c", "commit.gpgsign=false"]

    def put(rel, data):
        p_ = os.path.join(root, *rel.split("/"))
        os.makedirs(os.path.dirname(p_), exist_ok=True)
        open(p_, "wb").write(data if isinstance(data, bytes) else data.encode("utf-8"))
    put("build.zig.zon", R43_GIT_ZON)
    for rel, data in files.items():
        put(rel, data)
    subprocess.run(git_ + ["init", "-q"], check=True, capture_output=True)
    subprocess.run(git_ + ["add", "-A"], check=True, capture_output=True)
    for rel, data in index_only:
        blob = subprocess.run(git_ + ["hash-object", "-w", "--stdin"], input=data.encode("utf-8"), check=True,
                              capture_output=True).stdout.decode("ascii").strip()
        subprocess.run(git_ + ["update-index", "--add", "--cacheinfo", f"100644,{blob},{rel}"], check=True,
                       capture_output=True)
    subprocess.run(git_ + ["commit", "-q", "--no-verify", "-m", "r43"], check=True, capture_output=True)
    for rel in remove:
        os.remove(os.path.join(root, *rel.split("/")))
    for rel, data in (untracked or {}).items():
        put(rel, data)
    allow_ = os.path.join(logdir, tag + "-allow.tsv")
    open(allow_, "w", encoding="utf-8", newline="\n").write("")
    exe_ = ASTDUMP.get("1b")
    rc, out = run([py, "-I", os.path.join(here, "residue_gate17.py"), root, allow_] + (["--astdump", exe_] if exe_ else [])
                  + ["--work", os.path.join(logdir, "residue-ast", tag)])
    kinds = dict(collections.Counter(l_.split(" ", 2)[1] for l_ in out.splitlines() if l_.startswith(("FAIL ", "REPORT "))))
    ok = rc == exp_exit and kinds == exp_kinds   # git_control
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## residue_gate.py on a git checkout (exit {rc})\n{out}\nexpected: exit {exp_exit}, failures {exp_kinds}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: residue gate exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


if want(720): results.append(residue_control("720-SM1-a-cr-only-workflow-fails-unreadable", _r43_ci(
    720, "\r".join(R43_SOL) + "\r"), 1, {"CI-UNREADABLE": 1}))
if want(721): results.append(residue_control("721-SM1-the-same-workflow-in-lf-fails-on-its-version-lf-twin", _r43_ci(
    721, "\n".join(R43_SOL) + "\n"), 1, {"ACTIVE-015-SELECTION": 1}))
if want(722): results.append(residue_control("722-SM1-a-cr-lf-workflow-with-one-cr-only-break-fails-unreadable", _r43_ci(
    722, "\r\n".join(R43_SOL[:6]) + "\r\n      - run: echo hi # safe comment\r" + "\r\n".join(R43_SOL[6:]) + "\r\n"), 1,
    {"CI-UNREADABLE": 1}))
if want(723): results.append(residue_control("723-SM1-the-same-workflow-all-cr-lf-fails-on-its-version-crlf-twin", _r43_ci(
    723, "\r\n".join(R43_SOL[:6]) + "\r\n      - run: echo hi # safe comment\r\n" + "\r\n".join(R43_SOL[6:]) + "\r\n"), 1,
    {"ACTIVE-015-SELECTION": 1}))
if want(724): results.append(residue_control("724-OM1-a-lone-cr-after-a-comment-hides-a-step-and-fails-unreadable", _r43_ci(
    724, _r43_opus("\r")), 1, {"CI-UNREADABLE": 1}))
if want(725): results.append(residue_control("725-OM1-the-same-in-lf-fails-on-its-version-lf-twin", _r43_ci(
    725, _r43_opus("\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(726): results.append(residue_control("726-OM1-a-nel-after-a-comment-hides-a-step-and-fails-unreadable", _r43_ci(
    726, _r43_opus("\x85")), 1, {"CI-UNREADABLE": 1}))
if want(727): results.append(residue_control("727-OM1-the-same-in-lf-fails-on-its-version-lf-twin", _r43_ci(
    727, _r43_opus("\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(728): results.append(residue_control("728-OM1-an-ls-after-a-comment-hides-a-step-and-fails-unreadable", _r43_ci(
    728, _r43_opus("\N{LINE SEPARATOR}")), 1, {"CI-UNREADABLE": 1}))
if want(729): results.append(residue_control("729-OM1-the-same-in-lf-fails-on-its-version-lf-twin", _r43_ci(
    729, _r43_opus("\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(730): results.append(residue_control("730-OM1-a-ps-after-a-comment-hides-a-step-and-fails-unreadable", _r43_ci(
    730, _r43_opus("\N{PARAGRAPH SEPARATOR}")), 1, {"CI-UNREADABLE": 1}))
if want(731): results.append(residue_control("731-OM1-the-same-in-lf-fails-on-its-version-lf-twin", _r43_ci(
    731, _r43_opus("\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(732): results.append(residue_control("732-OM1-a-lone-cr-in-a-local-composite-fails-unreadable", both(
    _r43_ci(732, _r42_wf("      - uses: ./.github/actions/r43-zig\n")),
    write_into(".github/actions/r43-zig/action.yml", _r43_composite("\r"))), 1, {"CI-UNREADABLE": 1}))
if want(733): results.append(residue_control("733-OM1-the-composite-in-lf-fails-on-its-version-lf-twin", both(
    _r43_ci(733, _r42_wf("      - uses: ./.github/actions/r43-zig\n")),
    write_into(".github/actions/r43-zig/action.yml", _r43_composite("\n"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(734): results.append(residue_control("734-OM1-a-lone-cr-hiding-a-key-in-the-producer-step-fails-unreadable",
    write_into(".github/workflows/test.yml", _selftest_1a_job().replace(
        R43_PRODUCER, "from the frozen fixture #\r        working-directory: ci/other\n", 1), "a"), 1,
    {"CI-UNREADABLE": 1}, v140_drop=V140_TEST_CI))
if want(735): results.append(residue_control("735-OM1-the-key-in-lf-changes-the-producer-and-fails-lf-twin",
    write_into(".github/workflows/test.yml", _selftest_1a_job().replace(
        R43_PRODUCER, "from the frozen fixture #\n        working-directory: ci/other\n", 1), "a"), 1,
    {"ACTIVE-015-SELECTION": 1}, v140_drop=(R42_ROW_FULL,)))
if want(736): results.append(residue_control("736-a-tab-after-a-colon-fails-unreadable", _r43_ci(736, _r42_wf(
    _r42_zig("", "        with:\n          version:\t" + R42_E1 + "\n"))), 1, {"CI-UNREADABLE": 1}))
if want(737): results.append(residue_control("737-the-same-with-a-space-fails-on-its-version-space-twin", _r43_ci(737, _r42_wf(
    _r42_zig(R42_E1))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(738): results.append(residue_control("738-OL3-a-non-ascii-key-beside-version-fails-unreadable", _r43_ci(738, _r42_wf(
    _r42_zig("", "        with:\n          version: 0.17.1\n          ver\N{LATIN SMALL LETTER LONG S}ion: " + R42_E1 + "\n"))),
    1, {"CI-UNREADABLE": 1}))
if want(739): results.append(residue_control("739-OL3-an-ascii-key-beside-version-passes-ascii-twin", _r43_ci(739, _r42_wf(
    _r42_zig("", "        with:\n          version: 0.17.1\n          verfion: " + R42_E1 + "\n"))), 0, {}))
if want(740): results.append(residue_control("740-a-form-feed-in-a-value-fails-unreadable", _r43_ci(740, _r42_wf(
    "      - run: echo r43\x0c\n")), 1, {"CI-UNREADABLE": 1}))
if want(741): results.append(residue_control("741-the-same-value-without-it-passes-twin", _r43_ci(741, R43_WF_BENIGN), 0, {}))
if want(742): results.append(residue_control("742-a-byte-order-mark-inside-a-workflow-fails-unreadable", _r43_ci(742,
    R43_WF_BENIGN.replace("on: push", "\N{ZERO WIDTH NO-BREAK SPACE}on: push", 1)), 1, {"CI-UNREADABLE": 1}))
if want(743): results.append(residue_control("743-the-same-workflow-without-it-passes-twin", _r43_ci(743, R43_WF_BENIGN), 0, {}))
if want(744): results.append(residue_control("744-SM2-a-quoted-escaped-root-field-behind-a-comment-is-bad-setup", zon_into(
    "build.zig.zon", R43_ZON_SOL), 2, {}, exp_text=("BAD-SETUP", "a quoted identifier")))
if want(745): results.append(residue_control("745-SM2-the-plain-field-behind-the-comment-fails-on-its-pin-plain-twin", zon_into(
    "build.zig.zon", '// .minimum_zig_version = "0.17.1",\n    .minimum_zig_version = "0.15.2",'), 1,
    {"ACTIVE-015-SELECTION": 1, "RESIDUE-015": 1}, v140_extra="text"))
if want(746): results.append(residue_control("746-OM2-another-quoted-escaped-root-field-is-bad-setup", zon_into(
    "build.zig.zon", R43_ZON_OPUS), 2, {}, exp_text=("BAD-SETUP", "a quoted identifier")))
if want(747): results.append(residue_control("747-OM2-the-plain-field-fails-on-its-pin-plain-twin", zon_into(
    "build.zig.zon", '.minimum_zig_version = "0.15.2",'), 1, {"ACTIVE-015-SELECTION": 1, "RESIDUE-015": 1},
    v140_extra="text"))
if want(748): results.append(residue_control("748-SM2-a-pin-only-in-a-comment-is-bad-setup", zon_into(
    "build.zig.zon", '// .minimum_zig_version = "0.17.1",'), 2, {},
    exp_text=("BAD-SETUP", "has no root field minimum_zig_version")))
if want(749): results.append(residue_control("749-SM2-the-comment-beside-a-real-field-passes-field-twin", zon_into(
    "build.zig.zon", '// .minimum_zig_version = "0.17.1",\n    .minimum_zig_version = "0.17.0",'), 0, {}))
if want(750): results.append(residue_control("750-a-duplicate-root-field-is-bad-setup", zon_into(
    "build.zig.zon", '.minimum_zig_version = "0.17.0",\n    .minimum_zig_version = "0.17.1",'), 2, {},
    exp_text=("BAD-SETUP", "a duplicate root field")))
if want(751): results.append(residue_control("751-the-second-as-a-comment-passes-twin", zon_into(
    "build.zig.zon", '.minimum_zig_version = "0.17.0",\n    // .minimum_zig_version = "0.17.1",'), 0, {}))
if FULL and want(752): results.append(bindcheck_control(
    "752-SM2-the-binding-check-given-a-quoted-escaped-pin-exits-2", os.path.join(logdir, "inv-00-base"), _zon_overlay(
        "752", '// .minimum_zig_version = "0.15.2",\n    .@"minimum_zig_\\x76ersion" = "0.\\x31\\x37.1",'), 2,
    ("BAD-SETUP", "a quoted identifier"), {}))
if FULL and want(753): results.append(bindcheck_control(
    "753-SM2-the-binding-check-given-the-fixture-s-own-pin-passes-twin", os.path.join(logdir, "inv-00-base"),
    _zon_overlay("753", '.minimum_zig_version = "0.15.2",'), 0, ("failures 0",), {}))
if want(754): results.append(residue_control("754-SM3-a-local-path-with-an-at-sign-fails-unreadable", both(
    _r43_ci(754, _r42_wf("      - uses: actions/checkout@v4\n      - uses: ./ci/local@legacy\n")),
    write_into("ci/local/action.yml", R43_BENIGN), write_into("ci/local@legacy/action.yml", _r42_action(R42_E1))), 1,
    {"CI-UNREADABLE": 1}))
if want(755): results.append(residue_control("755-SM3-the-path-without-it-is-read-whole-and-fails-on-its-version-twin", both(
    _r43_ci(755, _r42_wf("      - uses: actions/checkout@v4\n      - uses: ./ci/local-legacy\n")),
    write_into("ci/local/action.yml", R43_BENIGN), write_into("ci/local-legacy/action.yml", _r42_action(R42_E1))), 1,
    {"ACTIVE-015-SELECTION": 1}))
if want(756): results.append(residue_control("756-SM3-a-backslash-local-path-fails-unreadable", both(
    _r43_ci(756, _r42_wf("      - uses: .\\ci\\actual\n")), write_into("ci/actual/action.yml", _r42_action(R42_E1))),
    1, {"CI-UNREADABLE": 1}))
if want(757): results.append(residue_control("757-SM3-the-slash-path-is-read-and-fails-on-its-version-twin", both(
    _r43_ci(757, _r42_wf("      - uses: ./ci/actual\n")), write_into("ci/actual/action.yml", _r42_action(R42_E1))),
    1, {"ACTIVE-015-SELECTION": 1}))
if want(758): results.append(residue_control("758-a-local-path-in-another-case-fails-unreadable", both(
    _r43_ci(758, _r42_wf("      - uses: ./tools/r43zig\n")), write_into("Tools/R43Zig/action.yml", _r42_action(R42_E1))),
    1, {"CI-UNREADABLE": 1}))
if want(759): results.append(residue_control("759-the-path-in-its-exact-case-fails-on-its-version-case-twin", both(
    _r43_ci(759, _r42_wf("      - uses: ./Tools/R43Zig\n")), write_into("Tools/R43Zig/action.yml", _r42_action(R42_E1))),
    1, {"ACTIVE-015-SELECTION": 1}))
if want(760): results.append(residue_control("760-a-remote-uses-with-no-ref-fails-unreadable", _r43_ci(760, _r42_wf(
    _r42_zig(R42_E1, uses="mlugg/setup-zig"))), 1, {"CI-UNREADABLE": 1, "ACTIVE-015-SELECTION": 1}))
if want(761): results.append(residue_control("761-the-same-with-its-ref-fails-on-its-version-ref-twin", _r43_ci(761, _r42_wf(
    _r42_zig(R42_E1))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(762): results.append(residue_control("762-a-local-action-directory-holding-nothing-fails-unreadable", both(
    _r43_ci(762, _r42_wf("      - uses: ./tools/r43-empty\n")), write_into("tools/r43-empty/README.md", "r43\n")), 1,
    {"CI-UNREADABLE": 1}))
if want(763): results.append(residue_control("763-one-holding-only-a-dockerfile-is-outside-the-boundary-twin", both(
    _r43_ci(763, _r42_wf("      - uses: ./tools/r43-empty\n")), write_into("tools/r43-empty/Dockerfile", "FROM alpine:3.20\n")),
    0, {}))
if want(764): results.append(git_control("764-OM3-case-colliding-workflows-fail", {".github/workflows/test.yml": R43_WF_017},
    1, {"CASE-COLLISION": 1, "TRACKED-UNREAD": 1}, index_only=((".github/workflows/TEST.yml", R43_WF_015),)))
if want(765): results.append(git_control("765-OM3-the-same-workflows-under-distinct-names-are-read-twin", {
    ".github/workflows/test.yml": R43_WF_017, ".github/workflows/TEST-ci.yml": R43_WF_015}, 1, {"ACTIVE-015-SELECTION": 1}))
if want(766): results.append(git_control("766-a-tracked-file-missing-from-the-checkout-fails", {
    ".github/workflows/ci.yml": R43_WF_BENIGN}, 1, {"TRACKED-UNREAD": 1}, remove=(".github/workflows/ci.yml",)))
if want(767): results.append(git_control("767-the-tracked-file-present-passes-twin", {".github/workflows/ci.yml": R43_WF_BENIGN},
    0, {}))
if want(768): results.append(git_control("768-OL1-a-tracked-shim-under-the-root-s-zig-out-fails", {"zig-out/p08.zig": R43_SHIM},
    1, {"PRODUCTION-SHIM": 1}))
if want(769): results.append(git_control("769-OL1-the-same-file-untracked-passes-twin", {}, 0, {},
    untracked={"zig-out/p08.zig": R43_SHIM}))
if want(780): results.append(residue_control("780-OL4-a-run-script-that-computes-a-version-passes-by-design", _r43_ci(780, _r42_wf(
    "      - id: ver\n        run: echo \"version=0.$((14 + 1)).2\" >> \"$GITHUB_OUTPUT\"\n"
    "      - run: echo ${{ steps.ver.outputs.version }}\n")), 0, {}))
if want(781): results.append(residue_control("781-OL4-the-same-script-with-the-version-written-fails-literal-twin", _r43_ci(781, _r42_wf(
    "      - id: ver\n        run: echo \"version=0.15.2\" >> \"$GITHUB_OUTPUT\"\n"
    "      - run: echo ${{ steps.ver.outputs.version }}\n")), 1, {"RESIDUE-015": 1}))
if want(782): results.append(residue_control("782-OL4-a-remote-installer-other-than-setup-zig-passes-by-design", _r43_ci(782, _r42_wf(
    "      - uses: example-org/install-zig@v1\n        with:\n          zig-version: " + R42_E1 + "\n")), 0, {}))
if want(783): results.append(residue_control("783-OL4-the-same-named-setup-zig-fails-on-its-version-setup-zig-twin", _r43_ci(783,
    _r42_wf(_r42_zig(R42_E1, uses="example-org/setup-zig@v1"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(784): results.append(residue_control("784-OL4-a-remote-reusable-workflow-passes-by-design", _r43_ci(784,
    "name: r43\non: push\njobs:\n  r43-call:\n    uses: example-org/ci/.github/workflows/zig.yml@v1\n    with:\n"
    "      zig: " + R42_E1 + "\n"), 0, {}))
if want(785): results.append(residue_control("785-OL4-a-local-reusable-workflow-is-read-and-fails-local-twin", both(_r43_ci(785,
    "name: r43\non: push\njobs:\n  r43-call:\n    uses: ./.github/workflows/r43-785-called.yml\n"),
    write_into(".github/workflows/r43-785-called.yml", "name: r43 called\non: workflow_call\njobs:\n  b:\n"
               "    runs-on: ubuntu-latest\n    steps:\n" + _r42_zig(R42_E1))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(786): results.append(residue_control("786-OL4-a-container-image-passes-by-design", _r43_ci(786, _r42_wf(
    "      - run: zig version\n", env="    container:\n      image: ghcr.io/example/zig-build@sha256:" + "0" * 64 + "\n")),
    0, {}))
if want(787): results.append(residue_control("787-OL4-an-image-tag-naming-the-release-fails-literal-twin", _r43_ci(787, _r42_wf(
    "      - run: zig version\n", env="    container:\n      image: ziglang/zig:0.15.2\n")), 1, {"RESIDUE-015": 1}))
R43_JS_META = "name: r43 js\ndescription: installs Zig\nruns:\n  using: node20\n  main: index.js\n"
R43_DOCKER_META = "name: r43 docker\ndescription: installs Zig\nruns:\n  using: docker\n  image: Dockerfile\n"
if want(788): results.append(residue_control("788-OL4-a-local-javascript-action-s-own-code-is-not-read-by-design", both(
    _r43_ci(788, _r42_wf("      - uses: ./tools/r43-js\n")), write_into("tools/r43-js/action.yml", R43_JS_META),
    write_into("tools/r43-js/index.js", "const v = ['0', 7 + 8, '2'].join('.');\nrequire('child_process').execSync('zig-install ' + v);\n")),
    0, {}))
if want(789): results.append(residue_control("789-OL4-its-code-with-the-version-written-fails-literal-twin", both(
    _r43_ci(789, _r42_wf("      - uses: ./tools/r43-js\n")), write_into("tools/r43-js/action.yml", R43_JS_META),
    write_into("tools/r43-js/index.js", "const v = '0.15.2';\nrequire('child_process').execSync('zig-install ' + v);\n")),
    1, {"RESIDUE-015": 1}))
if want(790): results.append(residue_control("790-OL4-a-local-docker-action-s-own-code-is-not-read-by-design", both(
    _r43_ci(790, _r42_wf("      - uses: ./tools/r43-docker\n")), write_into("tools/r43-docker/action.yml", R43_DOCKER_META),
    write_into("tools/r43-docker/Dockerfile", "FROM alpine:3.20\nRUN v=$(printf '0.%d.2' 15) && echo $v\n")), 0, {}))
if want(791): results.append(residue_control("791-OL4-its-dockerfile-with-the-version-written-fails-literal-twin", both(
    _r43_ci(791, _r42_wf("      - uses: ./tools/r43-docker\n")), write_into("tools/r43-docker/action.yml", R43_DOCKER_META),
    write_into("tools/r43-docker/Dockerfile", "FROM alpine:3.20\nARG ZIG=0.15.2\n")), 1, {"RESIDUE-015": 1}))
# -- r44 (round 43's Sol M1 to M3, Opus M1 to M3, L1 and the lead's direction, items 1 to 7, with the user's decision
# on item 3): the bytes each consumer reads, one spelling of each value. Tracked links (792 to 797, each a committed
# git checkout with real links): Sol's zig-out/probe.zig linked to ../payload.txt, a feature test on std that r43
# marked read without reading, a link to a directory and one leaving the tree, each TRACKED-LINK; each twin the
# payload as a tracked file there (read, failing PRODUCTION-SHIM) or a link to a file inside the tree, read as its
# text. Bytes from the commit (798 to 803, committed checkouts): Sol's workflow behind a configured clean/smudge filter
# (the checkout shows 0.17.1, the blob a format() version), Opus's working-tree-encoding=ISO-8859-1 workflow whose
# checkout shows a comment where the blob holds NELs and a setup-zig step, and the same hiding a producer key under the
# bound row; each twin without the attribute. The metadata names (804 to 809, the user's decision): Opus's ACTION.YML
# beside an action.yaml and Action.yml beside a Dockerfile, and an Action.yml alone, each CI-UNREADABLE; each twin
# spelled exactly. The version form (810 to 825): Sol's 0.150 in a local composite and in a workflow, 0.160, a quoted
# "0.150", Opus's 2024.11.0-mach and 2026.4.10-mach, a two-part 0.17 and fullwidth digits, each a version the gate
# cannot read; each twin a version it reads (passing, or the build setup-zig installs, failing below 0.17). The pin's
# digits (826 to 829): Arabic-Indic digits, BAD-SETUP for the gate and the binding check; each twin ASCII. ASCII white
# space (830 to 833): Opus's U+3000 continuation line and a no-break space after `version`, each CI-UNREADABLE; each
# twin an ASCII space
R44_GATE = "residue_gate17.py"   # ciprev44.py names r43's gate here
R44_PAYLOAD = ('const std = @import("std");\npub fn main() void {\n    if (@hasDecl(std.Io, "Threaded")) {\n'
               '        std.debug.print("new path\\n", .{});\n    } else {\n        std.debug.print("old path\\n", .{});\n'
               '    }\n}\n')
R44_FILTER = ("import sys\ns = sys.stdin.buffer.read()\na = b\"${{ format('0.{0}.{1}', 15, 2) }}\"\nb = b\"0.17.1\"\n"
              "sys.stdout.buffer.write(s.replace(a, b) if sys.argv[1] == \"smudge\" else s.replace(b, a))\n")
R44_SOL_WF = ("name: probe\non: push\njobs:\n  build:\n    runs-on: windows-2022\n    steps:\n"
              "      - uses: mlugg/setup-zig@v2\n        with:\n          version: ${{ format('0.{0}.{1}', 15, 2) }}\n")
R44_RING = "\N{LATIN CAPITAL LETTER A WITH RING ABOVE}"   # UTF-8 C3 85: read as ISO-8859-1, A-tilde and a NEL
R44_STORED = "\N{LATIN CAPITAL LETTER A WITH TILDE}\x85"   # what the blob holds for it


def _r44_opus_enc(mark):
    """r44: Opus's round-43 workflow, its setup-zig step after a `#` and `mark` on each line it hides."""
    return (R43_OPUS_HEAD + "      - run: echo hi #" + mark + "      - uses: mlugg/setup-zig@v2 #" + mark + "        with: #"
            + mark + "          version: ${{ format('0.{0}.{1}', 15, 2) }}\n")


def _r44_ci(n, text):
    return write_into(f".github/workflows/r44-{n}.yml", text)


def _r44_numeric(version):
    """r44: Sol's round-43 local composite, its setup-zig version `version`."""
    return ("name: numeric\ndescription: Review fixture\nruns:\n  using: composite\n  steps:\n"
            "    - uses: mlugg/setup-zig@v2\n      with:\n        version: " + version + "\n")


R44_TEST_WF = "name: test\non: push\njobs:"
R44_ENC_ATTR = " text working-tree-encoding=ISO-8859-1\n"


def _r44_row(job):
    """r44: the fixture allowance's setup-zig-step row for test.yml's `job`, as its own allowance."""
    rows = [l_ for l_ in open(os.path.join(FIX, "residue-allow.tsv"), encoding="utf-8")
            if l_.startswith("setup-zig-step\t.github/workflows/test.yml\t" + job + "\t")]
    assert len(rows) == 1, rows
    return rows[0]


def git_control44(tag, files, exp_exit, exp_kinds, links=(), config=(), recheckout=(), allow="", outside=None):
    """r44 (round 43's Sol M1, M3, Opus M1 and the lead's direction, items 1, 2 and 7): the residue gate on a small
    committed git checkout of its own, as git_control builds it (a build.zig.zon pinned 0.17.0 and `files`), with:
    `links`, (path, link text) entries committed as links (mode 120000) and checked out with core.symlinks=true, real
    links; `config`, (key, value) settings of its repository (a clean/smudge filter driver), set before anything is
    added; `recheckout`, tracked paths deleted after the commit and checked out again (a filter's smudge writes them);
    `allow`, the allowance's text; `outside`, a file written beside the checkout (a link's target outside the tree)."""
    root = os.path.join(logdir, "residue", tag)
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    git_ = ["git", "-C", root, "-c", "core.autocrlf=false", "-c", "core.symlinks=true", "-c", "init.templateDir=",
            "-c", "user.name=r44", "-c", "user.email=r44@example.invalid", "-c", "commit.gpgsign=false"]

    def put(rel, data):
        p_ = os.path.join(root, *rel.split("/"))
        os.makedirs(os.path.dirname(p_), exist_ok=True)
        open(p_, "wb").write(data if isinstance(data, bytes) else data.encode("utf-8"))
    put("build.zig.zon", R43_GIT_ZON)
    for rel, data in files.items():
        put(rel, data)
    if outside:
        open(os.path.join(os.path.dirname(root), outside[0]), "w", encoding="utf-8", newline="\n").write(outside[1])
    subprocess.run(git_ + ["init", "-q"], check=True, capture_output=True)
    for k_, v_ in config:
        subprocess.run(git_ + ["config", k_, v_], check=True, capture_output=True)
    subprocess.run(git_ + ["add", "-A"], check=True, capture_output=True)
    for rel, text in links:
        blob = subprocess.run(git_ + ["hash-object", "-w", "--stdin"], input=text.encode("utf-8"), check=True,
                              capture_output=True).stdout.decode("ascii").strip()
        subprocess.run(git_ + ["update-index", "--add", "--cacheinfo", f"120000,{blob},{rel}"], check=True,
                       capture_output=True)
    subprocess.run(git_ + ["commit", "-q", "--no-verify", "-m", "r44"], check=True, capture_output=True)
    for rel in [r_ for r_, _ in links] + list(recheckout):
        p_ = os.path.join(root, *rel.split("/"))
        if os.path.lexists(p_):
            os.remove(p_)
        subprocess.run(git_ + ["checkout", "--", rel], check=True, capture_output=True)
    allow_ = os.path.join(logdir, tag + "-allow.tsv")
    open(allow_, "w", encoding="utf-8", newline="\n").write(allow)
    exe_ = ASTDUMP.get("1b")
    rc, out = run([py, "-I", os.path.join(here, R44_GATE), root, allow_] + (["--astdump", exe_] if exe_ else [])
                  + ["--work", os.path.join(logdir, "residue-ast", tag)])
    kinds = dict(collections.Counter(l_.split(" ", 2)[1] for l_ in out.splitlines() if l_.startswith(("FAIL ", "REPORT "))))
    ok = rc == exp_exit and kinds == exp_kinds   # git_control44
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## residue_gate.py on a git checkout (exit {rc})\n{out}\nexpected: exit {exp_exit}, failures {exp_kinds}\n"
                 f"CONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: residue gate exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


def _r44_filter_config():
    """r44: Sol's clean/smudge driver (required), run by this Python, its script beside the controls' log."""
    p_ = os.path.join(logdir, "r44-filter.py")
    open(p_, "w", encoding="utf-8", newline="\n").write(R44_FILTER)
    cmd_ = '"' + py.replace("\\", "/") + '" -I "' + p_.replace("\\", "/") + '" '
    return (("filter.review.clean", cmd_ + "clean"), ("filter.review.smudge", cmd_ + "smudge"),
            ("filter.review.required", "true"))


R44_ZIG_WF = _r42_wf("      - uses: actions/checkout@v4\n      - uses: ./tools/r44-zig\n")
if want(792): results.append(git_control44("792-SM1-a-tracked-zig-link-under-zig-out-to-a-txt-fails-tracked-link", {
    "payload.txt": R44_PAYLOAD}, 1, {"TRACKED-LINK": 1}, links=(("zig-out/probe.zig", "../payload.txt"),)))
if want(793): results.append(git_control44("793-SM1-the-payload-as-a-tracked-file-there-is-read-and-fails-twin", {
    "payload.txt": R44_PAYLOAD, "zig-out/probe.zig": R44_PAYLOAD}, 1, {"PRODUCTION-SHIM": 1}))
if want(794): results.append(git_control44("794-SM1-a-tracked-link-to-a-directory-fails-tracked-link", {
    "tools/r44/a.txt": "r44\n"}, 1, {"TRACKED-LINK": 1}, links=(("src/r44", "../tools/r44"),)))
if want(795): results.append(git_control44("795-SM1-a-tracked-link-to-a-file-is-read-as-its-text-and-passes-twin", {
    "tools/r44/a.txt": "r44\n"}, 0, {}, links=(("src/r44.txt", "../tools/r44/a.txt"),)))
if want(796): results.append(git_control44("796-a-tracked-link-leaving-the-tree-fails-tracked-link", {}, 1, {"TRACKED-LINK": 1},
    links=(("notes.txt", "../r44-outside.txt"),), outside=("r44-outside.txt", "r44 outside\n")))
if want(797): results.append(git_control44("797-a-tracked-link-inside-the-tree-passes-twin", {"docs/r44.txt": "r44\n"}, 0, {},
    links=(("notes.txt", "docs/r44.txt"),)))
if want(798): results.append(git_control44("798-SM3-a-filtered-workflow-is-read-from-its-blob-and-fails", {
    ".github/workflows/probe.yml": R44_SOL_WF, ".gitattributes": ".github/workflows/probe.yml filter=review\n"}, 1,
    {"TRANSFORMED-PATH": 1, "CHECKOUT-DIFFERS": 1, "ACTIVE-015-SELECTION": 1}, config=_r44_filter_config(),
    recheckout=(".github/workflows/probe.yml",)))
if want(799): results.append(git_control44("799-SM3-the-same-workflow-unfiltered-fails-on-its-version-twin", {
    ".github/workflows/probe.yml": R44_SOL_WF}, 1, {"ACTIVE-015-SELECTION": 1}, config=_r44_filter_config(),
    recheckout=(".github/workflows/probe.yml",)))
if want(800): results.append(git_control44("800-OM1-a-working-tree-encoded-workflow-is-read-from-its-blob-and-fails", {
    ".github/workflows/probe.yml": _r44_opus_enc(R44_RING), ".gitattributes": ".github/workflows/probe.yml" + R44_ENC_ATTR},
    1, {"TRANSFORMED-PATH": 1, "CHECKOUT-DIFFERS": 1, "CI-UNREADABLE": 1}))
if want(801): results.append(git_control44("801-OM1-the-stored-bytes-without-the-attribute-fail-unreadable-twin", {
    ".github/workflows/probe.yml": _r44_opus_enc(R44_STORED)}, 1, {"CI-UNREADABLE": 1}))
if want(802): results.append(git_control44("802-OM1-a-producer-key-hidden-by-a-working-tree-encoding-fails", {
    ".github/workflows/test.yml": R44_TEST_WF + _selftest_1a_job().replace(
        R43_PRODUCER, "from the frozen fixture #" + R44_RING + "        working-directory: ci/other\n", 1),
    ".gitattributes": ".github/workflows/test.yml" + R44_ENC_ATTR}, 1,
    {"TRANSFORMED-PATH": 1, "CHECKOUT-DIFFERS": 1, "CI-UNREADABLE": 1, "STALE-ALLOWANCE": 1},
    allow=_r44_row("selftest-full")))
if want(803): results.append(git_control44("803-OM1-the-key-in-lf-changes-the-producer-and-fails-lf-twin", {
    ".github/workflows/test.yml": R44_TEST_WF + _selftest_1a_job().replace(
        R43_PRODUCER, "from the frozen fixture #\n        working-directory: ci/other\n", 1)}, 1,
    {"ACTIVE-015-SELECTION": 1}, allow=_r44_row("selftest-full")))
if want(804): results.append(residue_control("804-OM2-an-action-yml-in-capitals-beside-an-action-yaml-fails-unreadable", both(
    _r44_ci(804, R44_ZIG_WF), write_into("tools/r44-zig/ACTION.YML", _r42_action(R42_E1)),
    write_into("tools/r44-zig/action.yaml", R43_BENIGN)), 1, {"CI-UNREADABLE": 1}))
if want(805): results.append(residue_control("805-OM2-the-same-spelled-action-yml-beside-it-fails-unreadable-twin", both(
    _r44_ci(805, R44_ZIG_WF), write_into("tools/r44-zig/action.yml", _r42_action(R42_E1)),
    write_into("tools/r44-zig/action.yaml", R43_BENIGN)), 1, {"CI-UNREADABLE": 1}))
if want(806): results.append(residue_control("806-OM2-an-action-yml-capitalized-beside-a-dockerfile-fails-unreadable", both(
    _r44_ci(806, R44_ZIG_WF), write_into("tools/r44-zig/Action.yml", _r42_action(R42_E1)),
    write_into("tools/r44-zig/Dockerfile", "FROM alpine:3.20\n")), 1, {"CI-UNREADABLE": 1}))
if want(807): results.append(residue_control("807-OM2-the-same-spelled-action-yml-is-read-and-fails-on-its-version-twin", both(
    _r44_ci(807, R44_ZIG_WF), write_into("tools/r44-zig/action.yml", _r42_action(R42_E1)),
    write_into("tools/r44-zig/Dockerfile", "FROM alpine:3.20\n")), 1, {"ACTIVE-015-SELECTION": 1}))
if want(808): results.append(residue_control("808-an-action-yml-capitalized-alone-fails-unreadable", both(
    _r44_ci(808, R44_ZIG_WF), write_into("tools/r44-zig/Action.yml", _r42_action(R42_E1))), 1, {"CI-UNREADABLE": 1}))
if want(809): results.append(residue_control("809-the-same-spelled-action-yml-is-read-and-fails-on-its-version-twin", both(
    _r44_ci(809, R44_ZIG_WF), write_into("tools/r44-zig/action.yml", _r42_action(R42_E1))), 1,
    {"ACTIVE-015-SELECTION": 1}))
R44_NUMERIC_WF = ("name: probe\non: push\njobs:\n  build:\n    runs-on: windows-2022\n    steps:\n"
                  "      - uses: actions/checkout@v4\n      - uses: ./ci/numeric\n")
if want(810): results.append(residue_control("810-SM2-a-two-part-0-150-in-a-local-composite-fails", both(
    _r44_ci(810, R44_NUMERIC_WF), write_into("ci/numeric/action.yml", _r44_numeric("0.150"))), 1,
    {"ACTIVE-015-SELECTION": 1}))
if want(811): results.append(residue_control("811-SM2-the-composite-with-0-17-1-passes-twin", both(
    _r44_ci(811, R44_NUMERIC_WF), write_into("ci/numeric/action.yml", _r44_numeric("0.17.1"))), 0, {}))
if want(812): results.append(residue_control("812-SM2-a-two-part-0-150-in-a-workflow-fails", _r44_ci(812, _r42_wf(
    _r42_zig("0.150"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(813): results.append(residue_control("813-SM2-the-workflow-with-0-17-1-passes-twin", _r44_ci(813, _r42_wf(
    _r42_zig("0.17.1"))), 0, {}))
if want(814): results.append(residue_control("814-SM2-a-two-part-0-160-fails", _r44_ci(814, _r42_wf(
    _r42_zig("0.160"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(815): results.append(residue_control("815-SM2-0-16-0-is-read-and-fails-below-0-17-twin", _r44_ci(815, _r42_wf(
    _r42_zig("0.16.0"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(816): results.append(residue_control("816-SM2-a-quoted-0-150-fails", _r44_ci(816, _r42_wf(
    _r42_zig('"0.150"'))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(817): results.append(residue_control("817-SM2-a-quoted-0-17-1-passes-twin", _r44_ci(817, _r42_wf(
    _r42_zig('"0.17.1"'))), 0, {}))
if want(818): results.append(residue_control("818-OM3-a-mach-name-2024-11-0-mach-fails", _r44_ci(818, _r42_wf(
    _r42_zig("2024.11.0-mach"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(819): results.append(residue_control("819-OM3-the-build-it-names-is-read-and-fails-below-0-17-twin", _r44_ci(819,
    _r42_wf(_r42_zig("0.14.0-dev.2577+271452d22"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(820): results.append(residue_control("820-OM3-a-mach-name-2026-4-10-mach-fails", _r44_ci(820, _r42_wf(
    _r42_zig("2026.4.10-mach"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(821): results.append(residue_control("821-OM3-the-build-it-names-is-read-and-fails-below-0-17-twin", _r44_ci(821,
    _r42_wf(_r42_zig("0.16.0-dev.3142+5ccfeb926"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(822): results.append(residue_control("822-a-two-part-0-17-fails", _r44_ci(822, _r42_wf(_r42_zig("0.17"))), 1,
    {"ACTIVE-015-SELECTION": 1}))
if want(823): results.append(residue_control("823-0-17-0-passes-twin", _r44_ci(823, _r42_wf(_r42_zig("0.17.0"))), 0, {}))
if want(824): results.append(residue_control("824-OM3-a-version-in-fullwidth-digits-fails", _r44_ci(824, _r42_wf(_r42_zig(
    "0.\N{FULLWIDTH DIGIT ONE}\N{FULLWIDTH DIGIT SEVEN}.1"))), 1, {"ACTIVE-015-SELECTION": 1}))
if want(825): results.append(residue_control("825-OM3-the-same-in-ascii-digits-passes-twin", _r44_ci(825, _r42_wf(_r42_zig(
    "0.17.1"))), 0, {}))
if want(826): results.append(residue_control("826-OM3-a-pin-in-arabic-indic-digits-is-bad-setup", zon_into(
    "build.zig.zon", '.minimum_zig_version = "0.\N{ARABIC-INDIC DIGIT ONE}\N{ARABIC-INDIC DIGIT SEVEN}.0",'), 2, {},
    exp_text=("BAD-SETUP", "is no version")))
if want(827): results.append(residue_control("827-OM3-the-same-pin-in-ascii-digits-passes-twin", zon_into(
    "build.zig.zon", '.minimum_zig_version = "0.17.0",'), 0, {}))
if FULL and want(828): results.append(bindcheck_control(
    "828-OM3-the-binding-check-given-a-pin-in-arabic-indic-digits-exits-2", os.path.join(logdir, "inv-00-base"),
    _zon_overlay("828", '.minimum_zig_version = "0.\N{ARABIC-INDIC DIGIT ONE}\N{ARABIC-INDIC DIGIT FIVE}.2",'), 2,
    ("BAD-SETUP", "is no version"), {}))
if FULL and want(829): results.append(bindcheck_control(
    "829-OM3-the-binding-check-given-the-same-pin-in-ascii-passes-twin", os.path.join(logdir, "inv-00-base"),
    _zon_overlay("829", '.minimum_zig_version = "0.15.2",'), 0, ("failures 0",), {}))
if want(830): results.append(residue_control("830-OL1-an-ideographic-space-before-a-comment-mark-fails-unreadable", _r44_ci(
    830, R43_OPUS_HEAD + "      - run: echo hi\n          \N{IDEOGRAPHIC SPACE}# ; npx setup-zig\n"), 1,
    {"CI-UNREADABLE": 1}))
if want(831): results.append(residue_control("831-OL1-an-ascii-space-there-makes-a-comment-and-passes-twin", _r44_ci(
    831, R43_OPUS_HEAD + "      - run: echo hi\n           # ; npx setup-zig\n"), 0, {}))
if want(832): results.append(residue_control("832-OL1-a-no-break-space-after-version-fails-unreadable", _r44_ci(832, _r42_wf(
    _r42_zig("", "        with:\n          version\N{NO-BREAK SPACE}: 0.17.1\n"))), 1, {"CI-UNREADABLE": 1}))
if want(833): results.append(residue_control("833-OL1-an-ascii-space-there-is-white-space-and-passes-twin", _r44_ci(833, _r42_wf(
    _r42_zig("", "        with:\n          version : 0.17.1\n"))), 0, {}))
# -- r45 (round 44's Muse M1, L1, Sol M1, Opus M1, L1 to L3 and the lead's direction, items 1 to 4): the commit, not the
# index. Each a committed git checkout of its own (but 866 and 867, a plain tree): the three seats' staged-only change
# (HEAD holds a format() 0.15 version, the index and the checkout 0.17.1) and Sol's equal-tree git replace with clean
# status (the commit's blob replaced by a 0.17.1 one, the checkout written from it, assume-unchanged), each failing,
# each twin the ordinary commit (834 to 837). Build-produced source (838 to 843): a tracked link to a build's output,
# src/gen -> ../zig-out/gen, TRACKED-LINK; Opus's A (build.zig copies a tracked payload.txt to main.zig) and B (build.zig
# writes the program from a multiline string), each passing by design (the gate reads the tracked .zig files, build.zig
# among them, and not what a build writes), each twin the same program as a tracked .zig file, PRODUCTION-SHIM. The
# allowance rows (844 to 865): per row kind a degenerate key (an empty prefix, a prefix without its `/`, a prefix
# naming no directory, an empty path, a zero count), BAD-ALLOWANCE or STALE-ALLOWANCE, each twin the row that holds.
# Read errors (866 to 869): Muse's broken untracked link, UNREADABLE, and a submodule, TRACKED-UNREAD named so; each
# twin the ordinary file
R45_GATE = "residue_gate17.py"   # ciprev45.py names r44's gate here
R45_BAD = ("name: probe\non: push\njobs:\n  build:\n    runs-on: windows-2022\n    steps:\n      - uses: mlugg/setup-zig@v2\n"
           "        with:\n          version: ${{ format('0.{0}.{1}', 15, 2) }}\n")
R45_GOOD = R45_BAD.replace("${{ format('0.{0}.{1}', 15, 2) }}", "0.17.1")
R45_PAYLOAD = R44_PAYLOAD
R45_BUILD_A = ('const std = @import("std");\npub fn build(b: *std.Build) void {\n    const wf = b.addWriteFiles();\n'
               '    const src = wf.addCopyFile(b.path("PAYLOAD"), "main.zig");\n    const exe = b.addExecutable(.{\n'
               '        .name = "probe",\n        .root_module = b.createModule(.{ .root_source_file = src, .target = '
               'b.graph.host, .optimize = .Debug }),\n    });\n    const run = b.addRunArtifact(exe);\n'
               '    b.step("run", "run the probe").dependOn(&run.step);\n}\n')
R45_BUILD_B = ('const std = @import("std");\npub fn build(b: *std.Build) void {\n    const wf = b.addWriteFiles();\n'
               '    const src = wf.add("main.zig",\n' + "".join("        \\\\" + l_ + "\n" for l_ in R44_PAYLOAD.rstrip("\n").split("\n"))
               + '    );\n    const exe = b.addExecutable(.{\n        .name = "probe",\n        .root_module = b.createModule(.{ '
               '.root_source_file = src, .target = b.graph.host, .optimize = .Debug }),\n    });\n'
               '    const run = b.addRunArtifact(exe);\n    b.step("run", "run the probe").dependOn(&run.step);\n}\n')
R45_BUILD_TWIN = ('const std = @import("std");\npub fn build(b: *std.Build) void {\n    const exe = b.addExecutable(.{\n'
                  '        .name = "probe",\n        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), '
                  '.target = b.graph.host, .optimize = .Debug }),\n    });\n    const run = b.addRunArtifact(exe);\n'
                  '    b.step("run", "run the probe").dependOn(&run.step);\n}\n')
R45_NOTE = "install Zig 0.15.2 here\n"
R45_ZV = 'const builtin = @import("builtin");\npub const v = builtin.zig_version;\n'
R45_ZVS = 'const builtin = @import("builtin");\npub const s = builtin.zig_version_string;\n'
R45_DERIVED = ('const std = @import("std");\nconst Pair = struct { a: u8, b: u8 };\nconst Field = std.meta.FieldEnum(Pair);\n\n'
               'pub const has_a = @hasField(Field, "a");\n')
R45_UNRESOLVED = ('const std = @import("std");\nconst Local = struct {\n    pub fn eql() void {}\n    pub const Mutex = u8;\n};\n'
                  'fn make() type {\n    return Local;\n}\npub const has = @hasDecl(make(), "eql");\n')


def git_control45(tag, files, exp_exit, exp_kinds, exp_text=(), allow="", links=(), stage=None, replace=None,
                  gitlinks=(), plain=False, untracked_links=(), fault=None):
    """r45 (round 44's Muse M1, L1, Sol M1, Opus M1, L1 to L3 and the lead's direction, items 1 to 4): the residue gate
    on a small tree of its own (a build.zig.zon pinned 0.17.0 and `files`), committed (or, `plain`, a plain directory
    walked), with: `links`, (path, link text) entries committed as links and checked out as real ones; `gitlinks`, paths
    committed as submodules (mode 160000); `stage`, {path: text} written and `git add`ed after the commit, uncommitted;
    `replace`, (path, text): the commit's blob replaced by one of that text (`git replace`), the checkout written from
    it and marked assume-unchanged, so the index tree is HEAD's and the status clean; `untracked_links`, (path, target)
    links made after the commit and never tracked; `allow`, the allowance's text."""
    root = os.path.join(logdir, "residue", tag)
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    git_ = ["git", "-C", root, "-c", "core.autocrlf=false", "-c", "core.symlinks=true", "-c", "init.templateDir=",
            "-c", "user.name=r45", "-c", "user.email=r45@example.invalid", "-c", "commit.gpgsign=false"]

    def put(rel, data):
        p_ = os.path.join(root, *rel.split("/"))
        os.makedirs(os.path.dirname(p_), exist_ok=True)
        open(p_, "wb").write(data if isinstance(data, bytes) else data.encode("utf-8"))
    put("build.zig.zon", R43_GIT_ZON)
    for rel, data in files.items():
        put(rel, data)
    if not plain:
        subprocess.run(git_ + ["init", "-q"], check=True, capture_output=True)
        subprocess.run(git_ + ["add", "-A"], check=True, capture_output=True)
        for rel, text in links:
            blob = subprocess.run(git_ + ["hash-object", "-w", "--stdin"], input=text.encode("utf-8"), check=True,
                                  capture_output=True).stdout.decode("ascii").strip()
            subprocess.run(git_ + ["update-index", "--add", "--cacheinfo", f"120000,{blob},{rel}"], check=True,
                           capture_output=True)
        for rel in gitlinks:
            subprocess.run(git_ + ["update-index", "--add", "--cacheinfo", f"160000,{'1' * 40},{rel}"], check=True,
                           capture_output=True)
        subprocess.run(git_ + ["commit", "-q", "--no-verify", "-m", "r45"], check=True, capture_output=True)
        for rel, _ in links:
            subprocess.run(git_ + ["checkout", "--", rel], check=True, capture_output=True)
        for rel, data in (stage or {}).items():
            put(rel, data)
            subprocess.run(git_ + ["add", "--", rel], check=True, capture_output=True)
        if replace:
            rel, text = replace
            old = subprocess.run(git_ + ["rev-parse", "HEAD:" + rel], check=True, capture_output=True).stdout.decode().strip()
            new = subprocess.run(git_ + ["hash-object", "-w", "--stdin"], input=text.encode("utf-8"), check=True,
                                 capture_output=True).stdout.decode("ascii").strip()
            subprocess.run(git_ + ["replace", old, new], check=True, capture_output=True)
            put(rel, text)
            subprocess.run(git_ + ["update-index", "--assume-unchanged", "--", rel], check=True, capture_output=True)
            st = subprocess.run(git_ + ["status", "--porcelain"], check=True, capture_output=True).stdout
            assert st == b"", ("the replace control's status is not clean", st)
    for rel, target in untracked_links:
        full = os.path.join(root, *rel.split("/"))
        os.symlink(target, full, target_is_directory=os.path.isdir(os.path.join(os.path.dirname(full), target)))
    allow_ = os.path.join(logdir, tag + "-allow.tsv")
    if allow is not None:
        open(allow_, "w", encoding="utf-8", newline="\n").write(allow)
    exe_ = ASTDUMP.get("1b")
    runner = [py, "-I"] + (["-c", fault] if fault else [])
    rc, out = run(runner + [os.path.join(here, R45_GATE), root, allow_] + (["--astdump", exe_] if exe_ else [])
                  + ["--work", os.path.join(logdir, "residue-ast", tag)])
    kinds = dict(collections.Counter(l_.split(" ", 2)[1] for l_ in out.splitlines() if l_.startswith(("FAIL ", "REPORT "))))
    ok = (rc == exp_exit and kinds == exp_kinds and all(x in out for x in exp_text)
          and "Traceback (most recent call last)" not in out)
    with open(os.path.join(logdir, tag + ".txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"## residue_gate.py on {'a plain tree' if plain else 'a git checkout'} (exit {rc})\n{out}\nexpected: exit "
                 f"{exp_exit}, text {list(exp_text)}, failures {exp_kinds}\nCONTROL {'AS EXPECTED' if ok else 'UNEXPECTED'}\n")
    line = f"{tag}: residue gate exit {rc} {kinds or '(no failures)'}; {'AS EXPECTED' if ok else 'UNEXPECTED'}"
    print(line)
    return ok, line


R45_WF = {".github/workflows/probe.yml": R45_BAD}
if want(834): results.append(git_control45("834-MM1-SM1-a-staged-only-change-is-not-the-commit-and-fails", R45_WF, 1,
    {"INDEX-NOT-COMMIT": 1, "CHECKOUT-DIFFERS": 1, "ACTIVE-015-SELECTION": 1},
    stage={".github/workflows/probe.yml": R45_GOOD}))
if want(835): results.append(git_control45("835-MM1-SM1-the-same-change-committed-passes-twin", {
    ".github/workflows/probe.yml": R45_GOOD}, 0, {}))
if want(836): results.append(git_control45("836-SM1-MM1-an-equal-tree-git-replace-with-clean-status-fails", R45_WF, 1,
    {"CHECKOUT-DIFFERS": 1, "ACTIVE-015-SELECTION": 1}, replace=(".github/workflows/probe.yml", R45_GOOD)))
if want(837): results.append(git_control45("837-SM1-the-same-commit-with-no-replace-fails-on-its-version-twin", R45_WF, 1,
    {"ACTIVE-015-SELECTION": 1}))
if want(838): results.append(git_control45("838-OM1-a-tracked-link-to-a-build-s-output-fails-tracked-link", {}, 1,
    {"TRACKED-LINK": 1}, links=(("src/gen", "../zig-out/gen"),)))
if want(839): results.append(git_control45("839-OM1-the-link-to-a-tracked-file-is-read-as-its-text-and-passes-twin", {
    "tools/gen": "r45\n"}, 0, {}, links=(("src/gen", "../tools/gen"),)))
if want(840): results.append(git_control45("840-OM1-A-build-zig-copying-a-tracked-payload-to-main-zig-passes-by-design", {
    "build.zig": R45_BUILD_A.replace("PAYLOAD", "payload.txt"), "payload.txt": R45_PAYLOAD}, 0, {}))
if want(841): results.append(git_control45("841-OM1-the-payload-as-a-tracked-zig-file-fails-twin", {
    "build.zig": R45_BUILD_A.replace("PAYLOAD", "payload.zig"), "payload.zig": R45_PAYLOAD}, 1, {"PRODUCTION-SHIM": 1}))
if want(842): results.append(git_control45("842-OM1-B-build-zig-writing-the-program-from-a-string-passes-by-design", {
    "build.zig": R45_BUILD_B}, 0, {}))
if want(843): results.append(git_control45("843-OM1-the-program-as-a-tracked-zig-file-fails-twin", {
    "build.zig": R45_BUILD_TWIN, "src/main.zig": R45_PAYLOAD}, 1, {"PRODUCTION-SHIM": 1}))
R45_DOCS = {"docs/notes.md": R45_NOTE, "src/r45.zig": "pub const x = 1;\n"}
if want(844): results.append(git_control45("844-OL2-an-empty-prefix-is-bad-allowance", R45_DOCS, 1, {},
    exp_text=("BAD-ALLOWANCE", "an empty path"), allow="prefix\t\tthe whole tree\n"))
if want(845): results.append(git_control45("845-OL2-the-prefix-docs-passes-twin", R45_DOCS, 0, {}, allow="prefix\tdocs/\tthe docs\n"))
if want(846): results.append(git_control45("846-a-prefix-without-its-slash-is-bad-allowance", {
    "docs/sub/notes.md": R45_NOTE}, 1, {}, exp_text=("BAD-ALLOWANCE", "a prefix that does not end in /"),
    allow="prefix\tdocs/sub\tthe docs\n"))
if want(847): results.append(git_control45("847-the-prefix-with-its-slash-passes-twin", {"docs/sub/notes.md": R45_NOTE}, 0, {},
    allow="prefix\tdocs/sub/\tthe docs\n"))
if want(848): results.append(git_control45("848-a-prefix-naming-no-tracked-directory-is-stale", R45_DOCS, 1,
    {"STALE-ALLOWANCE": 1}, allow="prefix\tdocs/\tthe docs\nprefix\tother/\tnothing\n"))
if want(849): results.append(git_control45("849-a-prefix-naming-a-tracked-directory-passes-twin", R45_DOCS, 0, {},
    allow="prefix\tdocs/\tthe docs\nprefix\tsrc/\tthe sources\n"))
if want(850): results.append(git_control45("850-a-content-row-with-an-empty-path-is-bad-allowance", R45_DOCS, 1, {},
    exp_text=("BAD-ALLOWANCE", "an empty path"), allow="content\t\tinstall Zig 0.15.2 here\tthe note\n"))
if want(851): results.append(git_control45("851-the-content-row-with-its-path-passes-twin", R45_DOCS, 0, {},
    allow="content\tdocs/notes.md\tinstall Zig 0.15.2 here\tthe note\n"))
if want(852): results.append(git_control45("852-a-zero-count-is-bad-allowance", {"docs/plain.md": "no version here\n",
    "docs/notes.md": R45_NOTE}, 1, {}, exp_text=("BAD-ALLOWANCE", "a zero count"),
    allow="count\tdocs/plain.md\t0\tnothing\ncount\tdocs/notes.md\t1\tthe note\n"))
if want(853): results.append(git_control45("853-the-count-that-holds-passes-twin", {"docs/plain.md": "no version here\n",
    "docs/notes.md": R45_NOTE}, 0, {}, allow="count\tdocs/notes.md\t1\tthe note\n"))
if want(854): results.append(git_control45("854-a-zig-version-use-row-with-an-empty-path-is-bad-allowance", {"src/v.zig": R45_ZV},
    1, {}, exp_text=("BAD-ALLOWANCE", "an empty path"), allow="zig-version-use\t\tthe check\n"))
if want(855): results.append(git_control45("855-the-zig-version-use-row-with-its-path-passes-twin", {"src/v.zig": R45_ZV}, 0, {},
    allow="zig-version-use\tsrc/v.zig\tthe check\n"))
if want(856): results.append(git_control45("856-a-zig-version-string-use-row-with-an-empty-path-is-bad-allowance", {
    "src/s.zig": R45_ZVS}, 1, {}, exp_text=("BAD-ALLOWANCE", "an empty path"), allow="zig-version-string-use\t\tthe printer\n"))
if want(857): results.append(git_control45("857-the-zig-version-string-use-row-with-its-path-passes-twin", {
    "src/s.zig": R45_ZVS}, 0, {}, allow="zig-version-string-use\tsrc/s.zig\tthe printer\n"))
if want(858): results.append(git_control45("858-a-zero-feature-tests-row-is-bad-allowance", {"src/f.zig": R43_SHIM}, 1, {},
    exp_text=("BAD-ALLOWANCE", "a zero count"), allow="feature-tests\tsrc/f.zig\t0\tthe shim\n"))
if want(859): results.append(git_control45("859-the-feature-tests-row-that-holds-passes-twin", {"src/f.zig": R43_SHIM}, 0, {},
    allow="feature-tests\tsrc/f.zig\t1\tthe shim\n"))
if want(860): results.append(git_control45("860-a-zero-derived-tests-row-is-bad-allowance", {"src/d.zig": R45_DERIVED}, 1, {},
    exp_text=("BAD-ALLOWANCE", "a zero count"), allow="derived-tests\tsrc/d.zig\t0\tthe derived test\n"))
if want(861): results.append(git_control45("861-the-derived-tests-row-that-holds-passes-twin", {"src/d.zig": R45_DERIVED}, 0,
    {}, allow="derived-tests\tsrc/d.zig\t1\tthe derived test\n"))
if want(862): results.append(git_control45("862-a-zero-unresolved-origin-row-is-bad-allowance", {"src/u.zig": R45_UNRESOLVED},
    1, {}, exp_text=("BAD-ALLOWANCE", "a zero count"), allow="unresolved-origin\tsrc/u.zig\t0\tthe unresolved test\n"))
if want(863): results.append(git_control45("863-the-unresolved-origin-row-that-holds-passes-twin", {"src/u.zig": R45_UNRESOLVED},
    0, {}, allow="unresolved-origin\tsrc/u.zig\t1\tthe unresolved test\n"))
R45_SELFTEST = {".github/workflows/test.yml": R44_TEST_WF + _selftest_1a_job()}
if want(864): results.append(git_control45("864-a-setup-zig-step-row-with-an-empty-workflow-is-bad-allowance", R45_SELFTEST, 1,
    {}, exp_text=("BAD-ALLOWANCE", "an empty path"), allow="\t".join(
        ["setup-zig-step", ""] + _r44_row("selftest-full").split("\t")[2:])))
if want(865): results.append(git_control45("865-the-setup-zig-step-row-that-holds-passes-twin", R45_SELFTEST, 0, {},
    allow=_r44_row("selftest-full")))
if want(866): results.append(git_control45("866-ML1-a-broken-untracked-link-is-unreadable", {"src/r45.zig": "pub const x = 1;\n"},
    1, {"UNREADABLE": 1}, plain=True, untracked_links=(("src/broken.txt", "does-not-exist.txt"),)))
if want(867): results.append(git_control45("867-ML1-the-link-to-a-file-there-is-read-and-passes-twin", {
    "src/r45.zig": "pub const x = 1;\n", "src/exists.txt": "r45\n"}, 0, {}, plain=True,
    untracked_links=(("src/broken.txt", "exists.txt"),)))
if want(868): results.append(git_control45("868-OL3-a-submodule-is-tracked-unread-named-so", {}, 1, {"TRACKED-UNREAD": 1},
    exp_text=("a submodule (a gitlink)",), gitlinks=("pkg/sub",)))
if want(869): results.append(git_control45("869-OL3-the-same-path-as-a-tracked-file-passes-twin", {"pkg/sub/README": "r45\n"},
    0, {}))

# 1A.5: fault injection makes the access failure and lone-surrogate cases portable.
RESIDUE_FAULT_RUN = "sys.argv = sys.argv[1:]\nrunpy.run_path(sys.argv[0], run_name='__main__')\n"
ACTION_LIST_FAULT = (
    "import os, runpy, sys\n"
    "listdir = os.listdir\n"
    "def denied(path):\n"
    "    if os.path.basename(path) == 'local':\n"
    "        raise PermissionError(path)\n"
    "    return listdir(path)\n"
    "os.listdir = denied\n" + RESIDUE_FAULT_RUN)
SURROGATE_WALK_FAULT = (
    "import os, runpy, sys\n"
    "walk = os.walk\n"
    "def with_surrogate(*args, **kwargs):\n"
    "    for directory, dirs, files in walk(*args, **kwargs):\n"
    "        yield directory, dirs, files + (['bad\\ud800.txt'] if directory == args[0] else [])\n"
    "os.walk = with_surrogate\n" + RESIDUE_FAULT_RUN)
LOCAL_ACTION = {
    ".github/workflows/probe.yml": "name: probe\non: push\njobs:\n  probe:\n    runs-on: windows-2022\n"
                                   "    steps:\n      - uses: ./tools/local\n",
    "tools/local/action.yml": "name: local\nruns:\n  using: composite\n  steps:\n"
                              "    - shell: pwsh\n      run: Write-Host ok\n",
}
if want(870): results.append(git_control45("870-local-action-listing-failure-is-named", LOCAL_ACTION, 1,
    {"UNREADABLE": 1}, exp_text=("UNREADABLE tools/local:",), plain=True, fault=ACTION_LIST_FAULT))
if want(871): results.append(git_control45("871-readable-local-action-passes-twin", LOCAL_ACTION, 0, {}, plain=True))
if want(872): results.append(git_control45("872-missing-allowance-is-named", {}, 1, {"UNREADABLE": 1},
    exp_text=("the allowance cannot be read", "RESULT FAIL"), plain=True, allow=None))
if want(873): results.append(git_control45("873-readable-empty-allowance-passes-twin", {}, 0, {}, plain=True))
if want(874): results.append(git_control45("874-surrogate-path-is-named", {}, 1, {"UNREADABLE": 1},
    exp_text=(r"UNREADABLE bad\ud800.txt:",), plain=True, fault=SURROGATE_WALK_FAULT))
if want(875): results.append(git_control45("875-scalar-path-passes-twin", {"good.txt": "text\n"}, 0, {}, plain=True))
if want(876): results.append(git_control45("876-duplicate-allowance-key-is-rejected", R45_DOCS, 1, {},
    exp_text=("BAD-ALLOWANCE", "duplicate key"), plain=True,
    allow="count\tdocs/notes.md\t2\tfirst\ncount\tdocs/notes.md\t1\tsecond\n"))
if want(877): results.append(git_control45("877-single-allowance-key-passes-twin", R45_DOCS, 0, {}, plain=True,
    allow="count\tdocs/notes.md\t1\tsecond\n"))
DIR_LINK_CONTENT = {"target/notes.txt": "text\n"}
if want(878): results.append(git_control45("878-directory-link-is-unreadable", DIR_LINK_CONTENT, 1, {"UNREADABLE": 1},
    exp_text=("UNREADABLE linked:", "directory link"), plain=True, untracked_links=(("linked", "target"),)))
if want(879): results.append(git_control45("879-real-directory-passes-twin", {"linked/notes.txt": "text\n"}, 0, {},
    plain=True))

if want(880): results.append(compare_control("880-T1-run-rejects-problem-header-with-allowed-pairs",
    {**BASE_DUMPS, "test-exe-800.pairs": SUITE.replace("\n", " problem=append_failed\n", 1)},
    1, {"BAD-DUMP": 1}))
if want(881): results.append(compare_control("881-T1-run-rejects-problem-header-with-unqualified-key",
    {**BASE_DUMPS, "test-exe-800.pairs": SUITE.replace("\n", " problem=append_failed\n", 1)
        + "?append_failed:pairs-lost none\n"}, 1, {"BAD-DUMP": 1, "UNQUALIFIED-KEY": 1}))
T1_CHILD = SUITE.replace("kind=test-exe", "kind=child").replace("\n", " problem=append_failed\n", 1)
if want(882): results.append(compare_control("882-T1-isolated-rejects-problem-header-with-allowed-pairs",
    {"child.pairs": T1_CHILD}, 1, {"BAD-DUMP": 1}, isolated=True))
if want(883): results.append(compare_control("883-T1-isolated-rejects-problem-header-with-unqualified-key",
    {"child.pairs": T1_CHILD + "?append_failed:pairs-lost none\n"},
    1, {"BAD-DUMP": 1, "UNQUALIFIED-KEY": 1}, isolated=True))


def process_exit_control(tag, code, exp_kinds, permit=False, forwarded=False):
    """Run five valid dump packets through the supervisor's actual exit and seal entry points."""
    state = os.path.join(logdir, tag)
    os.makedirs(state)
    manifest_path = os.path.join(state, "manifest.tsv")
    stderr_path = os.path.join(state, "stderr")
    script = os.path.join(here, "role_supervisor.py")
    dumps = {}
    for pid in range(800, 805):
        start = str(134070000000000000 + pid)
        dumps[f"test-exe-{pid}.pairs"] = SUITE.replace("pid=800", f"pid={pid}").replace("start=134070000000000800",
                                                                                      f"start={start}")
        outcome = code if pid == 804 else 0
        with open(stderr_path, "wb") as stream:
            stream.write(b"thread-role layer: synthetic failure\n" if outcome else b"")
        subprocess.run([py, "-I", script, "exit", state, manifest_path, "fixture", str(pid), start,
                        "test-exe", str(outcome), stderr_path], check=True, capture_output=True)
    if forwarded:
        pid, start = "900", "134070000000000900"
        subprocess.run([py, "-I", script, "launch", state, manifest_path, pid, start, "forwarded"],
                       check=True, capture_output=True)
        subprocess.run([py, "-I", script, "exit", state, manifest_path, "fixture", pid, start, "forwarded",
                        "0", stderr_path], check=True, capture_output=True)
        dumps["cli-900.pairs"] = f"# kind=cli pid={pid} start={start}\nsrc/Surface.zig:keyCallback ui\n"
    subprocess.run([py, "-I", script, "seal", state, manifest_path], check=True, capture_output=True)
    with open(manifest_path, encoding="utf-8") as stream:
        manifest_text = stream.read()
    fixture_runs = CMP_RUNS + "fixture\texits\trequired\n"
    if permit:
        fixture_runs += f"fixture\texit\ttest-exe\t{code & 0xffffffff}\tyes\n"
    return compare_control(tag, dumps, int(bool(exp_kinds)), exp_kinds, manifest=manifest_text, seal=None,
                           runs=fixture_runs)


if want(884): results.append(process_exit_control("884-T2-valid-dumps-do-not-hide-an-abnormal-process-exit",
    -1073741819, {"ABNORMAL-EXIT": 1}))
if want(885): results.append(process_exit_control("885-T2-the-same-dumps-with-normal-process-exits-pass", 0, {}))
if want(886): results.append(process_exit_control("886-T2-the-run-spec-may-permit-an-exact-abnormal-outcome",
    -1073741819, {}, permit=True))


def same_container_names_control(tag, left_role):
    """A plain lock and try-lock in different containers share only the bare function spelling."""
    ov = overlay(tag, {TW: append(
        "const G1Left = struct {\n    fn g1Same(other: *TerminalWindow) void {\n"
        "        " + RS + ".mutex.lock();\n    }\n};\n"
        "const G1Right = struct {\n    fn g1Same(other: *TerminalWindow) void {\n"
        "        _ = " + RS + ".mutex.tryLock();\n    }\n};\n")})
    left_hop = "absent:G1NeverInvokes" if left_role == "never-on-win32" else f"{TW}:G1Left.g1Same:lock"
    scope = {"fork": "fork", "1a": "merged", "1b": "merged-1b"}[SCOPE]
    tbl = table_plus(tag, [
        f"{TW}\tG1Left.g1Same\tda39a3ee5e@renderer-state.lock:1\t{left_role}\t{scope}\tfixture.zig:1\t{left_hop}",
        f"{TW}\tG1Right.g1Same\tda39a3ee5e@renderer-state.tryLock:1\trenderer\t{scope}\tfixture.zig:1\t"
        f"{TW}:G1Right.g1Same:tryLock",
    ])
    anch = os.path.join(logdir, tag + "-anchors.tsv")
    with open(anchors, encoding="utf-8") as source, open(anch, "w", encoding="utf-8", newline="\n") as out:
        out.write(source.read() + f"renderer\t{TW}\tG1Right.g1Same\t{TW}:G1Right.g1Same:tryLock\n")
        if left_role == "renderer":
            out.write(f"renderer\t{TW}\tG1Left.g1Same\t{TW}:G1Left.g1Same:lock\n")
    if left_role == "renderer":
        inherited = ARMED_FORK_FAILURES if SCOPE == "fork" else 0
        return control(tag, ov, 0, {"acquisitions": 2, "live": 2}, 1, {"RENDERER-PLAIN-LOCK": inherited + 1},
                       tbl=tbl, anch=anch, gate_extra=("--arm-renderer-demand",))
    return control(tag, ov, 0, {"acquisitions": 2, "live": 1, "never": 1}, 0, {}, tbl=tbl, anch=anch)


if want(887): results.append(same_container_names_control("887-G1-distinct-containers-keep-their-own-operations",
                                                         "never-on-win32"))
if want(888): results.append(same_container_names_control("888-G1-only-the-plain-lock-fails-when-armed", "renderer"))
G1_TABLE = f"{TW}:G1Left.g1Same\tui\n{TW}:G1Right.g1Same\trenderer\n"
G1_CHILD = "# kind=child pid=801 start=134070000000000801\n"
if want(889): results.append(compare_control("889-G1-compare-keeps-each-containers-role",
    {"child.pairs": G1_CHILD + f"{TW}:G1Left.g1Same ui\n{TW}:G1Right.g1Same renderer\n"},
    0, {}, isolated=True, table=G1_TABLE))
if want(890): results.append(compare_control("890-G1-compare-refuses-an-ambiguous-bare-key",
    {"child.pairs": G1_CHILD + f"{TW}:g1Same ui\n"}, 1, {"AMBIGUOUS-KEY": 1}, isolated=True, table=G1_TABLE))
if want(891): results.append(process_exit_control("891-T2-forwarded-launch-can-leave-a-cli-dump", 0, {}, forwarded=True))
if want(892): results.append(jobs_control("892-a-workflow-change-selects-both-self-test-jobs",
    [".github/workflows/thread-gate-selftest.yml"], "full appending"))
if want(893): results.append(jobs_control("893-a-nested-ci-input-selects-both-self-test-jobs",
    ["ci/inputs/example.tsv"], "full appending"))

results = [r.result() if hasattr(r, "result") else r for r in results]
POOL.shutdown()
if QUICK and len(results) != len(QUICK_CONTROLS):
    sys.exit(f"QUICK-CONTROL-COUNT: ran {len(results)} controls, expected {len(QUICK_CONTROLS)}")
n_ok = sum(1 for ok, _ in results if ok)
with open(os.path.join(logdir, "summary.txt"), "w", encoding="utf-8", newline="\n") as fh:
    mode_ = (f"appending: control 00 and {len(results) - 1} appending controls at {rev}, scope {SCOPE}" if APPEND_MODE
             else f"{'quick' if QUICK else 'full'}: the fixture's revision {rev}, scope {SCOPE}")
    fh.write("\n".join(l for _, l in results) + f"\n{mode_}\n{n_ok} of {len(results)} as expected\n")
print(f"{n_ok} of {len(results)} as expected")
sys.exit(0 if n_ok == len(results) else 1)
