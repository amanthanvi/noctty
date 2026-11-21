r"""Acceptance test 9 of the runtime thread-role layer (PLAN.md §2.7, lines 1008-1020; §19.5): per artifact built
with the layer (the app exe and the fork test exe), every thread entry of the reviewed registry whose function is in
that binary sets its role when it runs, and every role-setting point in the binary is a registry entry, the UI scope
on `main`'s first line, or a test edit point. An entry not in the binary is reported, not counted.

Usage: python -I ci/thread_role_points.py <repo> <rev|-> <thread-entries.tsv> [--overlay DIR] [--verbose]
  <rev> is read with `git show`; `-` reads the working tree under <repo>. The registry is the gate's reviewed
  thread-entry list (file, function, api, target, runtime role, why), as `thread_gate15.py check` reads it.

What it reads, from zigtok.py's token stream (installed beside it), so a comment or a line break hides nothing:
- A ROLE-SETTING POINT is a call `R.enter(`, `R.fixture(` or `R.enterIfNone(` whose receiver R the file binds to
  `src/sync/thread_role.zig` (`const R = @import(".../thread_role.zig")`) or to its role API in one form
  (`const R = [thread_role.]Roles(...)`); the role is the call's first argument (`.ui`, `.{ .worker = "x" }`).
  Calls inside `src/sync/thread_role.zig`'s own non-test functions are the API, not points. A call of one of those
  three names whose first argument is a role literal on any other receiver is UNREADABLE-POINT: default-deny.
- An ARTIFACT holds a file when `src/main.zig` reaches it by `@import` (the test exe through every import, the app
  exe through imports outside test code); a point in test code (a test block, or a function nested in one) counts
  only in the test exe.
- A point is classified, in this order:
  TEST-EDIT-POINT  in test code;
  FIXTURE-HELPER   a `fixture(` in a function of a container that only test code of its file names, the container
                   a file-level `const` that is not `pub` (`ClipboardReplyFixture.init`, `TestStream.init`);
  MAIN-UI-SCOPE    `src/main_ghostty.zig` `main`, role ui, at the top level of its body;
  ENTRY            the function a counted registry entry targets (its last name), with the entry's role, at the top
                   level of the target's body, so it runs whenever the thread does;
  and otherwise fails UNREGISTERED-POINT.
- Each registry entry, per artifact: REPORTED when its file is not in the artifact or its spawn is never built for
  Windows (NOT_BUILT below, or a `why` that says "not built for Windows"); else ENTRY-OK when its target function
  holds a top-level point with its role, and otherwise ENTRY-NO-ROLE, ENTRY-WRONG-ROLE, ENTRY-NOT-TOP-LEVEL,
  ENTRY-TARGET-NOT-FOUND or ENTRY-AMBIGUOUS.
Exit 0 with RESULT PASS, 1 with RESULT FAIL, 2 on bad input.
"""
import importlib.util
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("zigtok", os.path.join(os.path.dirname(os.path.abspath(__file__)), "zigtok.py"))
zigtok = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(zigtok)

for _stream in (sys.stdout, sys.stderr):
    _stream.reconfigure(encoding="utf-8", errors="backslashreplace")

ROLE_FILE = "src/sync/thread_role.zig"
MAIN_FILE = "src/main_ghostty.zig"
ROOT = "src/main.zig"
POINT_OPS = ("enter", "fixture", "enterIfNone")
ROLES = ("none", "ui", "renderer", "termio", "reader", "search", "test_support")
# §2.7 test 9: entries whose spawn no Windows build compiles (P:1013-1016), keyed (file, function, target).
NOT_BUILT = {
    ("src/termio/Exec.zig", "threadEnter", "ReadThread.threadMainPosix"): "the POSIX reader: a comptime non-Windows branch",
    ("src/termio/Exec.zig", "threadMainPosix", "gatherMainPosix"): "spawned only by the POSIX reader",
    ("src/os/flatpak.zig", "spawn", "threadMain"): "flatpak: Linux only",
    ("src/crash/sentry.zig", "init", "initThread"): "Sentry's spawn: after the comptime Windows return",
}


def die(msg):
    print(f"ERROR {msg}")
    sys.exit(2)


def read_tree(repo, rev, overlay):
    texts = {}
    if rev == "-":
        base = os.path.join(repo, "src")
        for root, _, names in os.walk(base):
            for n in names:
                if n.endswith(".zig"):
                    p = os.path.join(root, n)
                    texts[os.path.relpath(p, repo).replace("\\", "/")] = open(p, encoding="utf-8").read()
    else:
        out = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", rev, "--", "src"], capture_output=True)
        if out.returncode != 0:
            die(f"git ls-tree {rev} failed")
        for f in out.stdout.decode("utf-8").splitlines():
            if f.endswith(".zig"):
                texts[f] = subprocess.run(["git", "-C", repo, "show", f"{rev}:{f}"],
                                          capture_output=True).stdout.decode("utf-8", "replace")
    if overlay:
        for root, _, names in os.walk(overlay):
            for n in names:
                if n.endswith(".zig"):
                    p = os.path.join(root, n)
                    texts[os.path.relpath(p, overlay).replace("\\", "/")] = open(p, encoding="utf-8").read()
    return texts


class File:
    """One file's tokens, functions and the facts the passes read."""

    def __init__(self, path, text):
        self.path = path
        self.toks = zigtok.code(text)
        self.fns = sorted(zigtok.functions_of_tokens(self.toks), key=lambda d: d["start"])
        n = len(self.toks)
        self.owner = [None] * n
        self.in_test = [False] * n
        for k, d in enumerate(self.fns):
            lo, hi = max(d["start"], 0), min(d["end"], n - 1)
            if lo > hi:
                continue
            nested_in_test = self.in_test[lo]
            for q in range(lo, hi + 1):
                self.owner[q] = k
                self.in_test[q] = nested_in_test or d["kind"] == "test"
        self.containers = zigtok.containers_of_tokens(self.toks, self.fns)
        self.test_only = None
        # each function's enclosing function or test block, or None at the file's own level
        self.parent, stack = [None] * len(self.fns), []
        for k, d in enumerate(self.fns):
            while stack and self.fns[stack[-1]]["end"] < d["start"]:
                stack.pop()
            self.parent[k] = stack[-1] if stack else None
            stack.append(k)

    def fn_name(self, k):
        return "(test)" if k is None or self.fns[k]["kind"] == "test" else self.fns[k]["name"]

    def top_level_in_body(self, k, q):
        """Whether token q is at the top level of function k's body (its depth 1 inside the body's braces)."""
        body = self.fns[k]["body"]
        if body is None or not (body[0] < q <= body[1]):
            return False
        depth = 0
        for r in range(body[0], q):
            t = self.toks[r]
            if zigtok.is_op(t, "(", "[", "{"):
                depth += 1
            elif zigtok.is_op(t, ")", "]", "}"):
                depth -= 1
        return depth == 1

    def container_of(self, q):
        """The innermost container body holding token q, or None."""
        best = None
        for c in self.containers:
            if c["open"] < q < c["close"] and (best is None or c["open"] > best["open"]):
                best = c
        return best

    def imports(self):
        """[(path, in_test)] for each `@import("<relative .zig path>")`."""
        out = []
        for q in range(len(self.toks) - 3):
            t = self.toks[q]
            if t.kind == "builtin" and t.text == "@import" and zigtok.is_op(self.toks[q + 1], "(") \
                    and self.toks[q + 2].kind == "string" and zigtok.is_op(self.toks[q + 3], ")"):
                v = zigtok.string_value(self.toks[q + 2])
                if v and v.endswith(".zig"):
                    target = os.path.normpath(os.path.join(os.path.dirname(self.path), v)).replace("\\", "/")
                    out.append((target, self.in_test[q]))
        return out


def role_of(toks, open_paren):
    """The role literal a point's first argument spells (`ui`, `worker:<name>`), or None for anything else."""
    runs, _ = zigtok.split_args(toks, open_paren)
    if not runs:
        return None
    a = runs[0]
    if len(a) == 2 and zigtok.is_op(a[0], ".") and a[1].kind == "identifier" and a[1].text in ROLES:
        return a[1].text
    # .{ .worker = "name" }
    if (len(a) >= 7 and zigtok.is_op(a[0], ".") and zigtok.is_op(a[1], "{") and zigtok.is_op(a[2], ".")
            and a[3].text == "worker" and zigtok.is_op(a[4], "=") and a[5].kind == "string"):
        return "worker:" + (zigtok.string_value(a[5]) or "?")
    return None


def role_receivers(f):
    """Names the file binds to thread_role.zig or to its role API."""
    out = set()
    toks = f.toks
    for q in range(len(toks) - 4):
        if not zigtok.declaration_at(toks, q) or not zigtok.is_op(toks[q + 2], "="):
            continue
        name, r = toks[q + 1].text, q + 3
        if toks[r].kind == "builtin" and toks[r].text == "@import" and r + 2 < len(toks) \
                and toks[r + 2].kind == "string" and (zigtok.string_value(toks[r + 2]) or "").endswith("thread_role.zig"):
            out.add(name)
        elif toks[r].kind == "identifier" and toks[r].text == "Roles" and zigtok.is_op(toks[r + 1], "("):
            out.add(name)
        elif toks[r].kind == "identifier" and r + 3 < len(toks) and zigtok.is_op(toks[r + 1], ".") \
                and toks[r + 2].text == "Roles" and zigtok.is_op(toks[r + 3], "("):
            out.add(name)
        else:
            # a re-export: `const thread_role = bench_core.thread_role;`, a name chain whose last name is thread_role
            e = r
            while e + 2 < len(toks) and toks[e].kind == "identifier" and zigtok.is_op(toks[e + 1], "."):
                e += 2
            if e > r and toks[e].kind == "identifier" and toks[e].text == "thread_role" and e + 1 < len(toks) \
                    and zigtok.is_op(toks[e + 1], ";"):
                out.add(name)
    return out


def main(argv):
    verbose = "--verbose" in argv
    argv = [a for a in argv if a != "--verbose"]
    overlay = None
    if "--overlay" in argv:
        k = argv.index("--overlay")
        overlay = argv[k + 1]
        argv = argv[:k] + argv[k + 2:]
    if len(argv) != 3:
        print(__doc__)
        sys.exit(2)
    repo, rev, entries_path = argv
    texts = read_tree(repo, rev, overlay)
    if ROOT not in texts:
        die(f"{ROOT} is not in the tree")
    files = {p: File(p, t) for p, t in texts.items()}

    # artifacts: the files src/main.zig reaches, the app exe through imports outside test code
    reach = {}
    for art, with_tests in (("app", False), ("test", True)):
        seen, todo = set(), [ROOT]
        while todo:
            p = todo.pop()
            if p in seen or p not in files:
                continue
            seen.add(p)
            todo.extend(t for t, in_test in files[p].imports() if with_tests or not in_test)
        reach[art] = seen
    # files the test exe reaches only through imports in test code (`conpty_host.zig`, rooted for its own tests):
    # there only what a test calls is compiled, so an entry there counts only when a test of its file names its spawner
    test_rooted = reach["test"] - reach["app"]

    failures, report = [], []

    # role-setting points
    points = []   # dict(file, fn index, fn name, role, line, q, test, op)
    for p, f in sorted(files.items()):
        recv = role_receivers(f)
        toks = f.toks
        for q in range(2, len(toks) - 1):
            t = toks[q]
            if t.kind != "identifier" or t.text not in POINT_OPS or not zigtok.is_op(toks[q - 1], ".") \
                    or not zigtok.is_op(toks[q + 1], "("):
                continue
            r = toks[q - 2]
            k = f.owner[q]
            role = role_of(toks, q + 1)
            if r.kind != "identifier" or r.text not in recv:
                if role is not None and not (p == ROLE_FILE and r.text == "Self"):
                    failures.append(f"UNREADABLE-POINT {p}:{t.line + 1} {f.fn_name(k)}: {r.text}.{t.text}(.{role}) on a "
                                    f"receiver this file does not bind to thread_role.zig")
                continue
            if p == ROLE_FILE and not f.in_test[q]:
                continue   # the API's own definitions
            if role is None:
                failures.append(f"UNREADABLE-POINT {p}:{t.line + 1} {f.fn_name(k)}: {r.text}.{t.text}( with a role "
                                f"that is no literal")
                continue
            points.append(dict(file=p, k=k, fn=f.fn_name(k), role=role, line=t.line + 1, q=q, test=f.in_test[q],
                               op=t.text))

    # the registry
    entries = []
    try:
        for l in open(entries_path, encoding="utf-8"):
            if l.strip() and not l.startswith("#"):
                c = l.rstrip("\n").split("\t")
                if len(c) < 5:
                    die(f"a registry row with {len(c)} columns: {l.strip()[:80]}")
                entries.append(dict(file=c[0], function=c[1], api=c[2], target=c[3], role=c[4],
                                    why=c[5] if len(c) > 5 else ""))
    except OSError as e:
        die(f"the registry cannot be read: {e}")

    def entry_points(e):
        """Points that can stand for entry e's role: in a function named as its target's last name."""
        name = re.split(r"[.]", e["target"])[-1]
        cands = [pt for pt in points if not pt["test"] and pt["fn"] == name]
        same = [pt for pt in cands if pt["file"] == e["file"]]
        if same:
            return same
        quals = [x.lower() for x in e["target"].split(".")[:-1]]
        if len(cands) > 1 and quals:
            # `rendererpkg.Thread.threadMain`: a file whose stem is the qualifier's last name, under a directory
            # that a qualifier names
            narrowed = [pt for pt in cands if os.path.basename(pt["file"])[:-4].lower() == quals[-1]
                        and any(qq.rstrip("pkg") in pt["file"].lower().split("/") for qq in quals[:-1] or [""])]
            if narrowed:
                return narrowed
        return cands

    counted = {"app": [], "test": []}
    matched = set()
    for e in entries:
        key = (e["file"], e["function"], e["target"])
        for art in ("app", "test"):
            if key in NOT_BUILT or "not built for Windows" in e["why"]:
                report.append(f"REPORTED {art} {e['file']} {e['function']} -> {e['target']} ({e['role']}): "
                              f"{NOT_BUILT.get(key, 'not built for Windows')}; not counted")
                continue
            if e["file"] not in reach[art]:
                report.append(f"REPORTED {art} {e['file']} {e['function']} -> {e['target']} ({e['role']}): its file "
                              f"is not in the {art} exe; not counted")
                continue
            if art == "test" and e["file"] in test_rooted:
                ef = files[e["file"]]
                if not any(ef.in_test[q] and t.kind == "identifier" and t.text == e["function"]
                           for q, t in enumerate(ef.toks)):
                    report.append(f"REPORTED {art} {e['file']} {e['function']} -> {e['target']} ({e['role']}): its "
                                  f"file is rooted in the test exe only for its tests, and no test names "
                                  f"{e['function']}; not counted")
                    continue
            cands = entry_points(e)
            name = e["target"].split(".")[-1]
            with_role = [pt for pt in cands if pt["role"] == e["role"]]
            if not with_role:
                defined = any(f.fns[k]["kind"] == "fn" and f.fns[k]["name"] == name for f in files.values()
                              for k in range(len(f.fns)))
                if cands:
                    failures.append(f"ENTRY-WRONG-ROLE {art} {e['file']} {e['function']} -> {e['target']}: its target "
                                    f"enters {', '.join(sorted({pt['role'] for pt in cands}))}, the registry says "
                                    f"{e['role']}")
                elif defined:
                    failures.append(f"ENTRY-NO-ROLE {art} {e['file']} {e['function']} -> {e['target']}: its target sets "
                                    f"no role ({e['role']})")
                else:
                    failures.append(f"ENTRY-TARGET-NOT-FOUND {art} {e['file']} {e['function']} -> {e['target']}")
                continue
            files_hit = {pt["file"] for pt in with_role}
            if len(files_hit) > 1:
                failures.append(f"ENTRY-AMBIGUOUS {art} {e['file']} {e['function']} -> {e['target']}: "
                                f"{', '.join(sorted(files_hit))}")
                continue
            top = [pt for pt in with_role if files[pt["file"]].top_level_in_body(pt["k"], pt["q"])]
            if not top:
                failures.append(f"ENTRY-NOT-TOP-LEVEL {art} {e['file']} {e['function']} -> {e['target']}: its role is "
                                f"set inside a nested block ({with_role[0]['file']}:{with_role[0]['line']}), so the "
                                f"thread can run without it")
                continue
            for pt in top:
                matched.add((pt["file"], pt["q"]))
            counted[art].append(e)
            report.append(f"ENTRY-OK {art} {e['file']} {e['function']} -> {e['target']}: {top[0]['file']}:"
                          f"{top[0]['line']} {top[0]['fn']} enters {e['role']}")

    # each point: in which artifact, and what it is
    kinds = {"app": {}, "test": {}}
    for pt in points:
        f = files[pt["file"]]
        for art in ("app", "test"):
            if pt["file"] not in reach[art] or (pt["test"] and art == "app"):
                continue
            kind = None
            if pt["test"]:
                kind = "TEST-EDIT-POINT"
            elif pt["op"] == "fixture":
                c = f.container_of(pt["q"])
                if c is not None and any(c is x for x in test_only_containers(f)):
                    kind = "FIXTURE-HELPER"
            if kind is None and pt["file"] == MAIN_FILE and pt["fn"] == "main" and pt["role"] == "ui" \
                    and f.top_level_in_body(pt["k"], pt["q"]):
                kind = "MAIN-UI-SCOPE"
            if kind is None and (pt["file"], pt["q"]) in matched:
                kind = "ENTRY"
            if kind is None:
                failures.append(f"UNREGISTERED-POINT {art} {pt['file']}:{pt['line']} {pt['fn']}: {pt['op']}({pt['role']}) "
                                f"is no registry entry's, not main's UI scope and not test code")
                continue
            if kind == "FIXTURE-HELPER" and art == "app":
                continue   # a container only test code names is not compiled into the app exe
            kinds[art][kind] = kinds[art].get(kind, 0) + 1
            if verbose:
                report.append(f"POINT {art} {kind} {pt['file']}:{pt['line']} {pt['fn']} {pt['op']}({pt['role']})")
    for art in ("app", "test"):
        if not kinds[art].get("MAIN-UI-SCOPE") and MAIN_FILE in reach[art]:
            failures.append(f"NO-MAIN-UI-SCOPE {art}: {MAIN_FILE} main does not enter ui at the top level of its body")

    for line in report:
        print(line)
    for art in ("app", "test"):
        k = kinds[art]
        print(f"{art} exe: {len(reach[art])} files; {len(counted[art])} entries set their role; points "
              + ", ".join(f"{n} {k[n]}" for n in sorted(k)))
    for x in failures:
        print("FAIL " + x)
    if failures:
        print(f"RESULT FAIL ({len(failures)} failures)")
        return 1
    print("RESULT PASS")
    return 0


def test_only_containers(f):
    """The file-level declarations that are not `pub` and that only test code names, as spans: a container (`const
    NAME = struct {...}`) or a function, every mention of whose name outside its own span is in test code or inside
    another such span (`ClipboardReplyFixture`, which the test-only helpers `EmptyPasteClipboard` and
    `expectUserPasteWithoutText` also name), with at least one mention. The least fixed point, so declarations that
    name only each other are not test-only. Returns the containers among them."""
    if f.test_only is not None:
        return f.test_only
    toks = f.toks
    cands = []   # (name, lo, hi, container or None)
    for c in f.containers:
        h = c["head"]
        if c["naming"] != "declaration" or h is None or f.owner[h] is not None or f.container_of(h) is not None:
            continue   # anonymous, or nested in a function or another container
        if h >= 1 and toks[h - 1].kind == "keyword" and toks[h - 1].text == "pub":
            continue
        cands.append((c["name"], h, c["close"], c))
    for k, d in enumerate(f.fns):
        lo = d["start"]
        if d["kind"] != "fn" or f.parent[k] is not None or f.container_of(lo) is not None \
                or "pub" in d["quals"] or d["body"] is None:
            continue   # a test block, a nested or a container's function, a pub one, or an extern declaration
        cands.append((d["name"], lo, d["end"], None))
    spans = []
    for name, lo, hi, c in cands:
        mentions = [q for q, t in enumerate(toks) if t.kind == "identifier" and t.text == name and not (lo <= q <= hi)]
        if mentions:
            spans.append((lo, hi, c, mentions))
    chosen = []
    changed = True
    while changed:
        changed = False
        for item in spans:
            if any(item is x for x in chosen):
                continue
            if all(f.in_test[q] or any(x[0] <= q <= x[1] for x in chosen) for q in item[3]):
                chosen.append(item)
                changed = True
    f.test_only = [x[2] for x in chosen if x[2] is not None]
    return f.test_only


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
