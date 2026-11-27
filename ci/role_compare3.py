r"""Scratch prototype of the 1A.2 compare's run rules, r15 (AD1, Opus L2; round 13's AC5 and AC1 kept), r16
(AE1: an isolated child's dump in the run's directory fails; Opus L3: a malformed manifest row fails closed), r17
(AF2: --isolated, the parent's compare of one isolated child's own directory) and r18 (AG2: a run's expectations come
from the reviewed run spec, never from its launch manifest; Opus L10: an isolated child with no pair fails), r19 (AH2:
a function key is the file and the bare symbol name, which is all std.debug gives; AH3: the supervisor's seal), r20
(AI2: a test key keeps its file, `<file>:test:<name>`; an unqualified key fails, and so do two table rows that normalise
to one identity; Opus L8: run-spec rows may name a compiler, and a run may be advisory on one), r21 (AJ1: duplicate
identities counted by row occurrence, and the per-file premise corrected; AJ3: advisory covers only the pair checks).
The dumps are already symbolised: the probes measured symbolisation separately.

Run spec (TSV, reviewed, one file for every run; `--runs FILE --run NAME --compiler 0.15|0.17` picks one run):
  <run> <TAB> group <TAB> <process kind> <TAB> <n>     at least <n> processes of that kind with pairs (a suite run:
                                                       test-exe; the build runner's restarts and the ConPTY probe
                                                       children are test-exe processes too, and need no launch row)
  <run> <TAB> launch <TAB> gui|cli|forwarded <TAB> <n> at least <n> launch rows of that kind in the manifest
  <run> <TAB> required <TAB> <function key> <TAB> <role>
  <run> <TAB> advisory <TAB> <compiler>                on that compiler the run's pair checks (PAIR-OUTSIDE-TABLE,
                                                       MISSING-REQUIRED-PAIR, which depend on the names it can
                                                       attribute) are reported and do not gate: RESULT ADVISORY,
                                                       exit 0 when they are all that failed; every other kind still
                                                       gates (r21, AJ3)
  Any row may end with a compiler column (`0.15` or `0.17`); such a row applies only to a run compared for that compiler.
  A run with no expectation, a name the file does not hold, or a malformed row of the run fails BAD-RUN-SPEC, before
  any dump is read: every run expects evidence, and without a sound spec there is nothing to judge the dumps against.
Launch manifest (TSV, written by the run's launchers, one run): launch rows, and the supervisor's seal.
  launch <TAB> <pid> <TAB> <start> <TAB> gui|cli|forwarded    a process the launcher started, its kind as the
                                                             launcher knows it (a forwarded start is one the
                                                             launcher meant to forward to a running instance)
  seal <TAB> <n> <TAB> <sha256>                              written once by the run's supervisor after its last
                                                             launch, from the supervisor's own record of the
                                                             launches (AI5; tools\role_supervisor.py): their number
                                                             and the SHA-256 of their rows, sorted, each ending in a
                                                             line feed. A run with no launcher (the Debug suite) is
                                                             sealed by its CI step: `seal 0 <sha256 of nothing>`
  Any other row fails BAD-MANIFEST, a `group` or `required` row included: a launcher cannot set or weaken a run's
  expectations, and an empty or truncated manifest leaves them whole. No seal fails MISSING-SEAL; two seals, or a seal
  whose count or digest differs from the launch rows read, fail BAD-SEAL.
Table, the reviewed one (r26, round 25's Kimi M1): with --table-scope fork|1a|1b, ci/lock-inventory-threads.tsv
  itself, seven columns (file, function, fingerprint, threads, scope, reason, chain). The rows the gate's scope order
  selects (fork: fork, all; 1a: merged, fork, all; 1b: merged-1b, merged, fork, all; an earlier scope shadows a later
  one for one identity) and every `test` row, wildcard rows `*[f1,...]` expanded. A production identity is
  `<file>:<function>`, its roles the row's threads (`never-on-win32` gives none); a test block's is
  `<file>:test:<the chain's exact name after test:>`; a function nested in test code keeps `<file>:<function>`. A
  seven-column row without --table-scope, or a two-column one with it, fails BAD-TABLE.
Table, two columns (the self-test's synthetic fixtures):
  <function key> <TAB> <role>|<role>...                      function key = <file>:<bare symbol name> (AH2: std.debug
                                                             names a function without its container, on both
                                                             compilers; the file comes from its source location), a
                                                             test block = <file>:test:<test name> (AI2; std.debug's
                                                             `test.<name>` with its file). Zig keeps test names unique
                                                             per container, not per file (r21, AJ1), and std.debug
                                                             names a test in any container `test.<name>`; the
                                                             inventory's SAME-NAME fails a file whose acquiring test
                                                             block shares its name, so the key is unique where it acquires
  A key with no `.zig` file fails UNQUALIFIED-KEY (in the table or a dump); two table rows that normalise to one
  identity, counted by row occurrence (identical rows too, r21), fail DUPLICATE-IDENTITY, since the compare could not
  tell them apart.
Dump files (<dir>\*.pairs): `# kind=<gui|cli|test-exe|child> pid=<pid> start=<start>`, then `<function key> <role>`
lines. Only the run directory's own files are read: an isolated child (a test that expects a panic or an off-table
pair, AE1) writes to a directory of its own, or nowhere, so a correct run never shows one.

Joins each dump to its launch row by (pid, start); a dump with no row is a process of one of the run's groups, or
UNEXPECTED-PROCESS. Fails (exit 1) on MISSING-DUMP (a gui row with no dump; or fewer processes of a group's kind with
pairs than the group asks), MISSING-LAUNCH (fewer launch rows of a kind than the run asks), EMPTY-DUMP (a gui row's dump
has no pair), UNEXPECTED-PROCESS, BAD-DUMP, PAIR-OUTSIDE-TABLE (after stripping an instantiation suffix, `__anon_N` /
`__func_N`, unless --no-strip), MISSING-REQUIRED-PAIR, CHILD-DUMP-IN-RUN (a `kind=child` dump in the run directory; its
pairs are not compared), BAD-MANIFEST (a row that is not a well-formed launch row: a torn append fails closed),
MISSING-SEAL, BAD-SEAL, UNQUALIFIED-KEY, DUPLICATE-IDENTITY, BAD-RUN-SPEC, BAD-TABLE. cli and forwarded rows may leave no dump and
no pair. --bare-names keys the table by function name alone, and a test by its name alone (the hazard L2 names).

--isolated (AF2): the parent of an isolated child compares that child's own directory, with no manifest (`-`) and no
run. Every dump there must be `kind=child` (else NOT-CHILD-DUMP), at least one must exist (else MISSING-DUMP), each must
hold a pair (else EMPTY-DUMP: the child recorded nothing, Opus L10), and its pairs are compared with the table
(PAIR-OUTSIDE-TABLE). An off-table variant's parent asserts exactly the PAIR-OUTSIDE-TABLE line it provoked; a panic
variant that also checks its pairs (test 12) asserts a pass and the pair count.
Usage: python -I role_compare3.py --runs <run-spec> --run <name> --compiler 0.15|0.17 <manifest> <table> <dump-dir>
           [--table-scope fork|1a|1b] [--no-strip] [--bare-names]
       python -I role_compare3.py - <table> <child-dir> --isolated [--table-scope fork|1a|1b] [--no-strip]
       (--table-scope: <table> is the reviewed seven-column table, read in that phase's scope)"""
import collections
import hashlib
import importlib.util
import os
import re
import sys

sys.dont_write_bytecode = True
_supervisor_spec = importlib.util.spec_from_file_location(
    "role_supervisor", os.path.join(os.path.dirname(os.path.abspath(__file__)), "role_supervisor.py"))
supervisor = importlib.util.module_from_spec(_supervisor_spec)
_supervisor_spec.loader.exec_module(supervisor)

for _stream in (sys.stdout, sys.stderr):   # r23: the report in UTF-8 whatever the console's code page
    _stream.reconfigure(encoding="utf-8", errors="backslashreplace")

args = sys.argv[1:]
opts = {}
for name in ("--runs", "--run", "--compiler", "--table-scope"):
    if name in args:
        i = args.index(name)
        opts[name] = args[i + 1]
        args = args[:i] + args[i + 2:]
flags = {a for a in args if a.startswith("--")}
manifest, table, dump_dir = [a for a in args if not a.startswith("--")]
strip, bare = "--no-strip" not in flags, "--bare-names" in flags
isolated = "--isolated" in flags
run_opts = [o in opts for o in ("--runs", "--run", "--compiler")]
if isolated != (manifest == "-") or (isolated and any(run_opts)) or (not isolated and not all(run_opts)) \
        or opts.get("--compiler", "0.17") not in ("0.15", "0.17") \
        or opts.get("--table-scope", "fork") not in ("fork", "1a", "1b"):
    sys.exit("usage: a run needs --runs, --run, --compiler 0.15|0.17 and a manifest; --isolated takes none of them "
             "(`-` for the manifest)")
INST = re.compile(r"(?:__anon_|__func_)\d+$")
KINDS = ("gui", "cli", "forwarded")
TESTSYM = re.compile(r"^(.*?\.zig):test[.:](.*)$")   # std.debug's `<file>:test.<name>`, or the table's `<file>:test:<name>`
FNKEY = re.compile(r"^.*?\.zig:[^:]+$")


def qualified(k):
    return bool(TESTSYM.match(k) or FNKEY.match(k))


def key(k):
    m = TESTSYM.match(k)
    if m:
        return ("test:" + m.group(2)) if bare else f"{m.group(1)}:test:{m.group(2)}"
    k = INST.sub("", k) if strip else k
    if bare:
        k = k.rsplit(":", 1)[-1].rsplit(".", 1)[-1]
    return k


failures = []
groups, launch_min, required, advisory = {}, {}, [], False
exits_required, expected_exits = False, set()
if not isolated:
    spec_rows = 0
    for l in open(opts["--runs"], encoding="utf-8"):
        if not l.strip() or l.startswith("#"):
            continue
        p = l.rstrip("\n").split("\t")
        if p[0] != opts["--run"]:
            continue
        spec_rows += 1
        width = 3 if p[1:2] in (["advisory"], ["exits"]) else 5 if p[1:2] == ["exit"] else 4
        if len(p) == width + 1 and p[width] in ("0.15", "0.17"):
            if p[width] != opts["--compiler"]:
                continue
            p = p[:width]
        if p[1:2] == ["group"] and len(p) == 4 and p[3].isdigit():
            groups[p[2]] = int(p[3])
        elif p[1:2] == ["launch"] and len(p) == 4 and p[2] in KINDS and p[3].isdigit():
            launch_min[p[2]] = int(p[3])
        elif p[1:2] == ["required"] and len(p) == 4 and qualified(p[2]):
            required.append((key(p[2]), p[3]))
        elif p[1:2] == ["advisory"] and len(p) == 3 and p[2] in ("0.15", "0.17"):
            advisory = advisory or p[2] == opts["--compiler"]
        elif p[1:] == ["exits", "required"]:
            exits_required = True
        elif (p[1:2] == ["exit"] and len(p) == 5 and re.fullmatch(r"[1-9][0-9]{0,9}", p[3])
              and int(p[3]) <= 0xffffffff and p[4] in ("yes", "no")):
            expected_exits.add((p[2], int(p[3]), p[4]))
        else:
            failures.append(f"BAD-RUN-SPEC run {opts['--run']}: a malformed row")
    if not required and not any(n > 0 for n in [*groups.values(), *launch_min.values()]):
        failures.append(f"BAD-RUN-SPEC run {opts['--run']}: no expectation ({spec_rows} rows): a run must expect evidence")
    if failures:   # without a sound spec there is nothing to judge the dumps against: fail closed before reading them
        for x in failures:
            print("FAIL " + x)
        print(f"RESULT FAIL ({len(failures)} failures) BAD-RUN-SPEC={len(failures)}")
        sys.exit(1)
launches, bad_rows, seals, launch_lines = {}, [], [], []
exits, exit_seals, exit_lines = {}, [], []
for n_, l in enumerate(open(manifest, encoding="utf-8") if not isolated else [], 1):
    if not l.strip():
        continue
    p = l.rstrip("\n").split("\t")
    if p[0] == "launch" and len(p) == 4 and p[1].isdigit() and p[3] in KINDS:
        launches[(p[1], p[2])] = p[3]
        launch_lines.append("\t".join(p))
    elif p[0] == "seal" and len(p) == 3 and p[1].isdigit() and re.fullmatch(r"[0-9a-f]{64}", p[2]):
        seals.append((int(p[1]), p[2]))
    elif p[0] == "exit-seal" and len(p) == 3 and p[1].isdigit() and re.fullmatch(r"[0-9a-f]{64}", p[2]):
        exit_seals.append(l.rstrip("\n") + "\n")
    elif p[0] == "exit" and (e := supervisor.parse_exit(l.rstrip("\n"))) is not None:
        run, pid, start, kind, code, marker = e
        if run != opts["--run"] or (pid, start) in exits:
            failures.append(f"BAD-EXIT row {n_}: exit belongs to another run or duplicates a process")
        else:
            exits[pid, start] = kind, code, marker
        exit_lines.append(l.rstrip("\n"))
    else:
        bad_rows.append(n_)
if not isolated:   # AH3: the supervisor's seal, checked against the launch rows read
    digest = hashlib.sha256("".join(x + "\n" for x in sorted(launch_lines)).encode("utf-8")).hexdigest()
    if not seals:
        failures.append("MISSING-SEAL the manifest has no supervisor seal: the run's launches cannot be counted")
    elif len(seals) > 1:
        failures.append(f"BAD-SEAL {len(seals)} seals: the supervisor writes one")
    elif seals[0] != (len(launch_lines), digest):
        failures.append(f"BAD-SEAL the seal says {seals[0][0]} launches, the manifest has {len(launch_lines)} launch rows"
                        + ("" if seals[0][1] == digest else "; the rows' digest differs"))
    if exits_required or exit_lines or exit_seals:
        if exit_seals != [supervisor.seal_row(exit_lines, "exit-seal")]:
            failures.append("BAD-EXIT-SEAL exit rows lack one matching supervisor seal")
    for (pid, start), (kind, code, marker) in sorted(exits.items()):
        launch = launches.get((pid, start))
        if (launch is not None and launch != kind) or (launch is None and kind not in groups):
            failures.append(f"UNEXPECTED-EXIT pid {pid} start {start}: exit kind {kind} does not match a process of the run")
        if code and (kind, code, marker) not in expected_exits:
            failures.append(f"ABNORMAL-EXIT run {opts['--run']} pid {pid} start {start}: "
                            f"{kind} code 0x{code:08x}, layer marker {marker}")
allowed, identity = set(), collections.defaultdict(list)
container_names = collections.defaultdict(set)
LOOKUP = {"fork": ("fork", "all"), "1a": ("merged", "fork", "all"), "1b": ("merged-1b", "merged", "fork", "all")}
table_scope = opts.get("--table-scope")
entries = []   # (function key, roles, table row number)
if table_scope is None:   # a two-column table: the self-test's synthetic fixtures
    for n_, l in enumerate(open(table, encoding="utf-8"), 1):
        if l.strip() and not l.startswith("#"):
            p_ = l.rstrip("\n").split("\t")
            if len(p_) >= 5:
                failures.append(f"BAD-TABLE row {n_}: a row of the reviewed seven-column table; read that table with "
                                f"--table-scope fork|1a|1b")
                continue
            entries.append((p_[0], p_[1] if len(p_) > 1 else "", n_))
else:   # r26 (round 25's Kimi M1): the reviewed seven-column table, in the phase's scope, as the gate selects rows
    order, best = LOOKUP[table_scope], {}
    for n_, l in enumerate(open(table, encoding="utf-8"), 1):
        if not l.strip() or l.startswith("#"):
            continue
        p_ = l.rstrip("\n").split("\t")
        if len(p_) < 5:
            failures.append(f"BAD-TABLE row {n_}: not a row of the reviewed seven-column table")
            continue
        p_ += [""] * (7 - len(p_))
        f_, fn_, _, threads_, scope_, _, chain_ = p_[:7]
        roles_ = "|".join(x for x in threads_.split("|") if x and x != "never-on-win32")
        names_ = fn_[2:-1].split(",") if fn_.startswith("*[") and fn_.endswith("]") else [fn_]
        if scope_ == "test":   # every phase; a test block's identity is its exact name, never trimmed (r25)
            for nm in names_:
                if nm != "(test)":
                    entries.append((f"{f_}:{nm}", roles_, n_))
                elif chain_.startswith("test:"):
                    entries.append((f"{f_}:test:{chain_[len('test:'):]}", roles_, n_))
                else:
                    failures.append(f"BAD-TABLE row {n_}: a test row's chain names no test (test:<name>)")
            continue
        if scope_ not in order:
            continue
        for nm in names_:   # an earlier scope shadows a later one for one identity, as the gate's row_for does
            k_, rank = f"{f_}:{nm}", order.index(scope_)
            if k_ not in best or rank < best[k_][0]:
                best[k_] = (rank, [(roles_, n_)])
            elif rank == best[k_][0]:
                best[k_][1].append((roles_, n_))
    for k_, (_, rows_) in sorted(best.items()):
        entries += [(k_, roles_, n_) for roles_, n_ in rows_]
for fn, roles, n_ in entries:
    if not qualified(fn):
        failures.append(f"UNQUALIFIED-KEY table row {fn!r}: a key names its .zig file")
        continue
    identity[key(fn)].append(n_)   # AJ1: by row occurrence, so two identical rows count as two
    allowed |= {(key(fn), r) for r in roles.split("|") if r}
    if not bare and not TESTSYM.match(fn):
        file, symbol = key(fn).rsplit(":", 1)
        container_names[(file, symbol.rsplit(".", 1)[-1])].add(symbol)
if not bare:   # under --bare-names the merge is the hazard being shown, not a table error
    for k_, rows_ in sorted(identity.items()):
        if len(rows_) > 1:
            failures.append(f"DUPLICATE-IDENTITY {k_}: table rows {rows_} normalise to one identity")
failures += [f"BAD-MANIFEST row {n_}: not a well-formed launch row (expectations come from the run spec)"
             for n_ in bad_rows]
seen, matched = set(), set()
dump_processes = set()
with_pairs = collections.Counter()
for name in sorted(os.listdir(dump_dir)):
    if not name.endswith(".pairs") or not os.path.isfile(os.path.join(dump_dir, name)):
        continue
    lines = [x for x in open(os.path.join(dump_dir, name), encoding="utf-8").read().split("\n") if x.strip()]
    h = re.match(r"# kind=(\S+) pid=(\S+) start=(\S+)", lines[0]) if lines else None
    if not h:
        failures.append(f"BAD-DUMP {name}: no header")
        continue
    kind, pid, start = h.groups()
    if re.search(r"(?:^|\s)problem=", lines[0][h.end():]):
        failures.append(f"BAD-DUMP {name}: the symbolised header reports a problem")
    pairs = [tuple(x.rsplit(" ", 1)) for x in lines[1:]]   # a test key holds spaces; the role is the last word
    row = launches.get((pid, start))
    if not isolated and (exits_required or exit_lines):
        if (pid, start) in dump_processes:
            failures.append(f"BAD-DUMP {name}: duplicate process dump")
            continue
        dump_processes.add((pid, start))
        process_exit = exits.get((pid, start))
        if process_exit is None:
            failures.append(f"MISSING-EXIT {name}: pid {pid} start {start} has no recorded exit")
        # A launcher classifies the request (including "forwarded"); the
        # recorder classifies the executable. Only group processes use a
        # recorder kind as their supervisor kind.
        elif row is None and process_exit[0] != kind:
            failures.append(f"BAD-EXIT {name}: pid {pid} start {start} does not match its recorded exit kind")
    if isolated:
        if kind != "child":
            failures.append(f"NOT-CHILD-DUMP {name}: kind {kind} in an isolated child's directory (pid {pid})")
            continue
        with_pairs["child-dumps"] += 1
        if not pairs:
            failures.append(f"EMPTY-DUMP {name}: the isolated child (pid {pid}) recorded no pair")
    elif kind == "child":
        failures.append(f"CHILD-DUMP-IN-RUN {name}: an isolated child's dump reached the run's directory (pid {pid})")
        continue
    elif row is not None:
        matched.add((pid, start))
        if row == "gui" and not pairs:
            failures.append(f"EMPTY-DUMP {name}: launched gui process (pid {pid}) recorded no pair")
    elif kind in groups:
        if pairs:
            with_pairs[kind] += 1
    else:
        failures.append(f"UNEXPECTED-PROCESS {name}: pid {pid} start {start} is in no launch row (kind {kind})")
        continue
    for pair in pairs:
        if len(pair) != 2:
            failures.append(f"BAD-DUMP {name}: a pair has no role")
            continue
        fn, role = pair
        if not qualified(fn):
            failures.append(f"UNQUALIFIED-KEY {name}: ({fn}, {role}) names no .zig file")
            continue
        pair_key = key(fn)
        if not bare and not TESTSYM.match(fn):
            file, symbol = pair_key.rsplit(":", 1)
            if "." not in symbol and len(container_names[(file, symbol)]) > 1:
                failures.append(f"AMBIGUOUS-KEY {name}: {pair_key} names more than one reviewed function")
                continue
            # DbgHelp names a container's function bare, as it does a plain one (src/sync/symbolise.zig's doc;
            # its site-shape test names `Shapes.Holder.Inner.symboliseNestedSite` `symboliseNestedSite`), so a
            # bare key takes the key of the one reviewed function of that name in its file, a container's
            # (`Compression.step` in renderer/Thread.zig, which a composite with compression live records as
            # `step`). Two such functions are the AMBIGUOUS-KEY above; that no unreviewed function of the name
            # acquires is the lock inventory's gate (lock_inventory20.py), not this compare's.
            if "." not in symbol and len(container_names[(file, symbol)]) == 1:
                pair_key = f"{file}:{next(iter(container_names[(file, symbol)]))}"
        seen.add((pair_key, role))
        if (pair_key, role) not in allowed:
            failures.append(f"PAIR-OUTSIDE-TABLE {name}: ({fn}, {role})")
    if not isolated and (exits_required or exit_lines) and kind in groups and not pairs:
        failures.append(f"EMPTY-DUMP {name}: group process pid {pid} start {start} recorded no pair")
for (pid, start), kind in sorted(launches.items()):
    if kind == "gui" and (pid, start) not in matched:
        failures.append(f"MISSING-DUMP launched gui process pid {pid} start {start}: no dump")
    if (exits_required or exit_lines) and (pid, start) not in exits and (pid, start) not in dump_processes:
        failures.append(f"MISSING-EXIT launched {kind} process pid {pid} start {start}: no recorded exit")
for pid_start, (kind, _, _) in sorted(exits.items()):
    if kind in groups and pid_start not in dump_processes:
        pid, start = pid_start
        failures.append(f"MISSING-DUMP {kind} process pid {pid} start {start}: no dump")
for kind, n in sorted(launch_min.items()):
    have = sum(1 for k in launches.values() if k == kind)
    if have < n:
        failures.append(f"MISSING-LAUNCH {kind}: {have} launch rows, at least {n} needed by run {opts['--run']}")
for kind, n in sorted(groups.items()):
    if with_pairs[kind] < n:
        failures.append(f"MISSING-DUMP group {kind}: {with_pairs[kind]} processes with pairs, at least {n} needed")
for fn, role in required:
    if (fn, role) not in seen:
        failures.append(f"MISSING-REQUIRED-PAIR ({fn}, {role})")
if isolated and with_pairs["child-dumps"] == 0:
    failures.append("MISSING-DUMP isolated child: no child dump in its directory")
kc = collections.Counter(x.split(" ", 1)[0] for x in failures)
for x in failures:
    print("FAIL " + x)
print(f"run {opts.get('--run', '(isolated)')}" + (f" for {opts['--compiler']}" if not isolated else "")
      + f": {len(launches)} launch rows, {len(matched)} joined; with pairs {dict(with_pairs)}; {len(seen)} distinct pairs")
# AJ3: on an advisory compiler only the name-dependent kinds stop gating; a run that never launched, left no dump, broke
# its seal or saw an unexpected process still fails there
NAME_DEPENDENT = ("PAIR-OUTSIDE-TABLE", "MISSING-REQUIRED-PAIR")
gating = [x for x in failures if not (advisory and x.split(" ", 1)[0] in NAME_DEPENDENT)]
verdict = "PASS" if not failures else ("FAIL" if gating else "ADVISORY")
print(f"RESULT {verdict} ({len(failures)} failures)" + ("" if not kc else " " + " ".join(f"{k}={v}" for k, v in sorted(kc.items())))
      + (" (advisory on this compiler: the pair checks are reported, not gating)" if advisory and failures and not gating else ""))
sys.exit(1 if gating else 0)
