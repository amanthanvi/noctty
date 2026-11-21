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
  exe through imports outside test code, an `if (builtin.is_test)` branch being test code); a point in test code (a
  test block, a function nested in one, or such a branch) counts only in the test exe.
- A point is classified, in this order:
  TEST-EDIT-POINT  in test code;
  FIXTURE-HELPER   a `fixture(` in a function of a container that only test code of its file names, the container
                   a file-level `const` that is not `pub` (`ClipboardReplyFixture.init`, `TestStream.init`);
  MAIN-UI-SCOPE    `src/main_ghostty.zig` `main`, role ui, as its eager first statement (below);
  ENTRY            in the function a counted registry entry's spawn names, with the entry's role, as the target's
                   eager first statement, so it runs before anything else the thread does;
  and otherwise fails UNREGISTERED-POINT. An EAGER FIRST STATEMENT (`File.scope_statement`) is the body's first
  statement, beginning with the call itself (`const|var NAME [: T] = R.enter(`, `_ = R.enter(` or `R.enter(`, or
  `fixture`) and ending with it (`...);`): a `defer`, `errdefer`, `if`, `while`, `orelse`, `catch` or any other
  wrapper never counts, since a deferred call runs at the exit and a guarded one may never run (stone round 4:
  Sol's Medium 1, Opus L1). Only `defer` and `errdefer` statements, which run nothing where they stand, may come
  before it (Surface.zig's `Click.run`). The scope must also set a role (`sets_role`): its receiver the module or
  `Roles(.on)`, followed through aliases, never `Roles(.off)` (which keeps no role in any build) or a form the
  checker cannot read, and its role not none (stone round 5, Sol's Low; ENTRY-SETS-NO-ROLE). Tests' own off-form
  scopes are no required entry points and stay test edit points.
- Each registry entry is bound to its spawn: the `Thread.spawn(` call in the entry's function whose second argument
  is spelled as the entry's target, that argument resolved from the call by lexical scope and through `@import`,
  a container's own level and `const` aliases (`Resolver`). A same-named function anywhere else is never the
  target (stone round 3, Sol's Medium 1). A comptime `switch` is read only at the arm its subject evaluates to:
  the build's own artifact selector, `terminal_options`' `artifact` through its real import and aliases, whose
  value the build sets (`Resolver.build_artifact`: `src/terminal/build_options.zig` and `src/build/SharedDeps.zig`'s
  `terminalOptions(.X)`; `.ghostty` for `search.Thread`), or a constant the checker evaluates; any other subject,
  and any `if`, is ambiguous (stone round 4).
- Each registry entry, per artifact: REPORTED when its file is not in the artifact, its spawn is never built for
  Windows (NOT_BUILT below, or a `why` that says "not built for Windows"), or, for the app exe, every spawn is in a
  function only a test build compiles (`spawned_only_by_tests`: test code, a test-only span, or a function whose
  name every file mentions only there; stone round 4, Opus L3); else ENTRY-OK when its bound target opens with its
  role's eager first statement, and otherwise ENTRY-NO-ROLE, ENTRY-WRONG-ROLE, ENTRY-NOT-TOP-LEVEL (only in a nested
  block), ENTRY-NOT-FIRST (no eager first statement: deferred, guarded, or after other work),
  ENTRY-SPAWN-NOT-FOUND (the function makes no such spawn), ENTRY-TARGET-NOT-FOUND (the argument resolves to no
  function the checker can read) or ENTRY-AMBIGUOUS (a switch or if the checker cannot evaluate, or spawns of that
  spelling that name different functions).
Exit 0 with RESULT PASS, 1 with RESULT FAIL, 2 on bad input.
"""
import importlib.util
import os
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
# The calls that make a thread's own scope (an entry's, main's): enterIfNone keeps a role the thread already has.
SCOPE_OPS = ("enter", "fixture")
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
        self.in_test_block = list(self.in_test)   # test blocks and what they nest, before the is_test gates
        self.mark_test_gated()
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

    # Tokens that may not stand in a scope statement's type annotation: anything that makes it no plain declaration.
    WRAPPERS = frozenset(("if", "else", "while", "for", "switch", "orelse", "catch", "try", "defer", "errdefer",
                          "comptime", "and", "or", "return", "break", "continue", "suspend", "nosuspend"))

    def scope_statement(self, k, q):
        """Whether the role call whose op is token q is the eager first statement of function k's body: the
        statement right after the body's `{` begins with the call itself, as `const|var NAME [: T] = R.op(`,
        `_ = R.op(` or `R.op(`, and ends with it (`...);`, so no `.exit()` chained on it). A `defer`, `errdefer`,
        `if`, `while`, `orelse`, `catch` or any other wrapper, and any statement before it, makes it none: a deferred
        call runs at the function's exit and a guarded one may never run (stone round 4: Sol's Medium 1, Opus L1)."""
        body = self.fns[k]["body"]
        toks, n = self.toks, len(self.toks)
        if body is None or q < 2 or not (body[0] < q <= body[1]) or not zigtok.is_op(toks[q - 1], ".") \
                or toks[q - 2].kind != "identifier":
            return False
        # Only `defer` and `errdefer` statements, which run nothing where they stand, may come first (Surface.zig's
        # `Click.run` registers `defer job.done.set();`): the scope is still the first statement executed.
        s, b1 = body[0] + 1, min(body[1], q)
        while s < b1 and toks[s].kind == "keyword" and toks[s].text in ("defer", "errdefer"):
            r, d = s + 1, 0
            if r < b1 and zigtok.is_op(toks[r], "|"):   # errdefer |err|
                r += 1
                while r < b1 and not zigtok.is_op(toks[r], "|"):
                    r += 1
                r += 1
            if r < b1 and zigtok.is_op(toks[r], "{"):
                r = zigtok.match_paren(toks, r) + 1
            else:
                while r < b1:
                    t = toks[r]
                    if zigtok.is_op(t, "(", "[", "{"):
                        d += 1
                    elif zigtok.is_op(t, ")", "]", "}"):
                        d -= 1
                    elif d == 0 and zigtok.is_op(t, ";"):
                        break
                    r += 1
                r += 1
            if r > q - 2:
                return False   # the call is inside the deferred statement
            s = r
        prefix = toks[s:q - 2]   # the statement's tokens before the receiver
        if prefix:
            if len(prefix) == 2 and prefix[0].kind == "identifier" and prefix[0].text == "_" \
                    and zigtok.is_op(prefix[1], "="):
                pass
            elif (len(prefix) >= 3 and prefix[0].kind == "keyword" and prefix[0].text in ("const", "var")
                  and prefix[1].kind == "identifier" and zigtok.is_op(prefix[-1], "=")
                  and (len(prefix) == 3 or (zigtok.is_op(prefix[2], ":") and len(prefix) > 4
                                            and not any(zigtok.is_op(t, "=", ";", "{", "}") or t.text in self.WRAPPERS
                                                        for t in prefix[3:-1])))):
                pass
            else:
                return False
        close = zigtok.match_paren(toks, q + 1)
        return close + 1 < n and zigtok.is_op(toks[close + 1], ";")

    def ident_index(self):
        """Each identifier's token positions, once."""
        if getattr(self, "_idents", None) is None:
            self._idents = {}
            for q, t in enumerate(self.toks):
                if t.kind == "identifier":
                    self._idents.setdefault(t.text, []).append(q)
        return self._idents

    def mark_test_gated(self):
        """Marks as test code what `if (builtin.is_test)` (or `@import("builtin").is_test`) compiles only in a test
        build: its then-branch, exactly a braced block, or a braceless body that reaches its `;`, `,` or `else`
        first (`pub const test_support = if (builtin.is_test) @import(...) else struct {};`); any other braceless
        body is not gated."""
        toks, n = self.toks, len(self.toks)
        for q in range(n - 5):
            if not (toks[q].kind == "keyword" and toks[q].text == "if" and zigtok.is_op(toks[q + 1], "(")):
                continue
            c = zigtok.match_paren(toks, q + 1)
            cond = [t.text for t in toks[q + 2:c]]
            if cond not in (["builtin", ".", "is_test"], ["@import", "(", '"builtin"', ")", ".", "is_test"]):
                continue
            r = c + 1
            if r < n and zigtok.is_op(toks[r], "{"):
                end = zigtok.match_paren(toks, r)
            else:
                # A braceless body is gated only when it reaches `;`, `,` or `else` at its own level first. A
                # closer of an outer block, or a block that closes back to the body's level with anything but
                # `else`, `;`, `,`, `.` or `)` after it (a braceless `for (xs) |x| {...}`, `while`, labelled block
                # or `switch` statement, whose next statement is not the branch's), comes first: then nothing is
                # gated, and the region stays production code (stone round 5, Opus L1, the lead's strict form).
                end, d, gated = r, 0, False
                while end < n:
                    t = toks[end]
                    if zigtok.is_op(t, "(", "[", "{"):
                        d += 1
                    elif zigtok.is_op(t, ")", "]", "}"):
                        if d == 0:
                            break
                        d -= 1
                        if d == 0 and zigtok.is_op(t, "}") and not (
                                end + 1 < n and (zigtok.is_op(toks[end + 1], ";", ",", ".", ")")
                                                 or (toks[end + 1].kind == "keyword" and toks[end + 1].text == "else"))):
                            break
                    elif d == 0 and (zigtok.is_op(t, ";", ",") or (t.kind == "keyword" and t.text == "else")):
                        gated = True
                        break
                    end += 1
                if not gated:
                    continue
                end -= 1
            for p in range(r, min(end, n - 1) + 1):
                self.in_test[p] = True

    def scope(self):
        """Builds, once, what name resolution reads: each token's innermost enclosing `{` (`block_of`, -1 at the
        file's own level), each `{`'s matching `}` (`close_of`), and every declaration by name (`decls`): a
        function (`fn NAME`, with its index in `fns`) or a `const`/`var NAME [: T] = <value>` (with its value's
        first token), each with the block it is declared in."""
        if getattr(self, "decls", None) is not None:
            return
        toks, n = self.toks, len(self.toks)
        self.block_of, self.close_of, stack = [-1] * n, {}, []
        for q, t in enumerate(toks):
            self.block_of[q] = stack[-1] if stack else -1
            if zigtok.is_op(t, "{"):
                stack.append(q)
            elif zigtok.is_op(t, "}") and stack:
                self.close_of[stack.pop()] = q
        for o in stack:
            self.close_of[o] = n - 1   # an unbalanced block ends at the last token
        self.decls = {}
        for k, d in enumerate(self.fns):
            if d["kind"] == "fn":
                self.decls.setdefault(d["name"], []).append(
                    dict(kind="fn", idx=d["fn"], block=self.block_of[d["fn"]], k=k))
        for q in range(n - 2):
            if not zigtok.declaration_at(toks, q):
                continue
            r, depth = q + 2, 0
            while r < n:
                t = toks[r]
                if zigtok.is_op(t, "(", "[", "{"):
                    depth += 1
                elif zigtok.is_op(t, ")", "]", "}"):
                    depth -= 1
                    if depth < 0:
                        break
                elif depth == 0 and zigtok.is_op(t, "=", ";"):
                    break
                r += 1
            if r + 1 < n and zigtok.is_op(toks[r], "="):
                self.decls.setdefault(toks[q + 1].text, []).append(
                    dict(kind="const", idx=q, block=self.block_of[q], value=r + 1))

    def lookup(self, q, name):
        """The declaration of `name` visible at token q: declared in a block that holds q (or at the file's level),
        the innermost one. Zig refuses a shadowing name, so the innermost is the one."""
        self.scope()
        best = None
        for d in self.decls.get(name, ()):
            b = d["block"]
            if (b == -1 or b < q <= self.close_of.get(b, -1)) and (best is None or b > best["block"]):
                best = d
        return best

    def container_of(self, q):
        """The innermost container body holding token q, or None."""
        best = None
        for c in self.containers:
            if c["open"] < q < c["close"] and (best is None or c["open"] > best["open"]):
                best = c
        return best

    def imports(self):
        """[(path, in_test, in_test_block)] for each `@import("<relative .zig path>")`: whether test code holds it
        (an `if (builtin.is_test)` branch included), and whether a test block does."""
        out = []
        for q in range(len(self.toks) - 3):
            t = self.toks[q]
            if t.kind == "builtin" and t.text == "@import" and zigtok.is_op(self.toks[q + 1], "(") \
                    and self.toks[q + 2].kind == "string" and zigtok.is_op(self.toks[q + 3], ")"):
                v = zigtok.string_value(self.toks[q + 2])
                if v and v.endswith(".zig"):
                    target = os.path.normpath(os.path.join(os.path.dirname(self.path), v)).replace("\\", "/")
                    out.append((target, self.in_test[q], self.in_test_block[q]))
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
    """The names the file binds to thread_role.zig or to its role API, each with its form: "module" (the module
    itself, whose functions are this build's form, and `Roles(layer)`), "on" (`Roles(.on)`), "off" (`Roles(.off)`,
    which sets no role in any build) or "unknown" (a `Roles(...)` argument the checker cannot read, or a name bound
    twice to different forms). A `const X = Y;` alias of a bound name takes its form; a name chain whose last name
    is `thread_role` (`const thread_role = bench_core.thread_role;`) is the module."""
    out, aliases = {}, []
    toks = f.toks

    def bind(name, form):
        out[name] = form if out.get(name, form) == form else "unknown"

    for q in range(len(toks) - 4):
        if not zigtok.declaration_at(toks, q) or not zigtok.is_op(toks[q + 2], "="):
            continue
        name, r = toks[q + 1].text, q + 3
        if toks[r].kind == "builtin" and toks[r].text == "@import" and r + 2 < len(toks) \
                and toks[r + 2].kind == "string" and (zigtok.string_value(toks[r + 2]) or "").endswith("thread_role.zig"):
            bind(name, "module")
            continue
        call = None
        if toks[r].kind == "identifier" and toks[r].text == "Roles" and zigtok.is_op(toks[r + 1], "("):
            call = r + 1
        elif toks[r].kind == "identifier" and r + 3 < len(toks) and zigtok.is_op(toks[r + 1], ".") \
                and toks[r + 2].text == "Roles" and zigtok.is_op(toks[r + 3], "("):
            call = r + 3
        if call is not None:
            arg = [t.text for t in toks[call + 1:zigtok.match_paren(toks, call)]]
            if arg == [".", "on"]:
                bind(name, "on")
            elif arg == [".", "off"]:
                bind(name, "off")
            elif arg and arg[-1] == "layer" and all(a == "." or a.isidentifier() for a in arg):
                bind(name, "module")
            else:
                bind(name, "unknown")
            continue
        e = r
        while e + 2 < len(toks) and toks[e].kind == "identifier" and zigtok.is_op(toks[e + 1], "."):
            e += 2
        if e > r and toks[e].kind == "identifier" and toks[e].text == "thread_role" and e + 1 < len(toks) \
                and zigtok.is_op(toks[e + 1], ";"):
            bind(name, "module")
        elif e == r and toks[r].kind == "identifier" and r + 1 < len(toks) and zigtok.is_op(toks[r + 1], ";"):
            aliases.append((name, toks[r].text))
    changed = True
    while changed:
        changed = False
        for name, target in aliases:
            if target in out and out.get(name) != out[target] and (name not in out or out[name] != "unknown"):
                if name in out and out[name] != out[target]:
                    out[name] = "unknown"
                else:
                    out[name] = out[target]
                changed = True
    return out


class Resolver:
    """Resolves a name chain written at a token of a file to the declaration it names: its first name by lexical
    scope from that token (`Desktop` declared in the spawning function, `Deadline` at the file's level), each later
    name as a member of what the previous one names (a file an `@import` opens, a container's own level), through
    `const` aliases (`const updateCheckThreadMain = win32.updateCheckThreadMain;`). Anything else it cannot read
    resolves to ("unresolved", why), never to a guess: a same-named function elsewhere is no binding."""

    def __init__(self, files):
        self.files = files

    def chain(self, f, q, names, depth=0):
        d = f.lookup(q, names[0])
        if d is None:
            return ("unresolved", f"{names[0]} is declared in no scope that holds {f.path}:{f.toks[q].line + 1}")
        b = self.decl(f, d, depth + 1)
        for name in names[1:]:
            b = self.member(b, name, depth + 1)
        return b

    def decl(self, f, d, depth):
        if depth > 32:
            return ("unresolved", "an alias chain longer than 32")
        if d["kind"] == "fn":
            return ("fn", f, d["k"])
        return self.value(f, d, depth)

    def value(self, f, d, depth):
        return self.expression(f, d["value"], d["idx"], (";",), depth)

    def build_artifact(self):
        """The `artifact` every exe's `terminal_options` module holds, read the way the build sets it:
        `src/terminal/build_options.zig` adds the option `artifact` to the module `terminal_options`, and
        `src/build/SharedDeps.zig`, which every exe's root module goes through (the app and the fork test exe),
        adds `terminalOptions(.X)`. X, or None unless the build holds exactly that."""
        if hasattr(self, "_artifact"):
            return self._artifact
        self._artifact = None
        opts, deps = self.files.get("src/terminal/build_options.zig"), self.files.get("src/build/SharedDeps.zig")
        if opts is None or deps is None:
            return None

        def at(toks, i, texts):
            return i + len(texts) <= len(toks) and all(toks[i + j].text == x for j, x in enumerate(texts))

        ot = opts.toks
        if not any(at(ot, i, ("addOptions", "(", '"terminal_options"')) for i in range(len(ot))) \
                or not any(at(ot, i, ("addOption", "(", "Artifact", ",", '"artifact"')) for i in range(len(ot))):
            return None
        dt = deps.toks
        tags = [dt[i + 3].text for i in range(len(dt) - 7)
                if at(dt, i, ("terminalOptions", "(", ".")) and dt[i + 3].kind == "identifier"
                and at(dt, i + 4, (")", ".", "add", "("))]
        if len(tags) == 1:
            self._artifact = tags[0]
        return self._artifact

    def enum_value(self, f, q, subject, depth):
        """The enum tag a comptime switch subject (the tokens `subject`, written at token q) holds, and why not when
        None: the build's own artifact selector (`terminal_options`'s `artifact`, through its real `@import` and
        aliases: `build_artifact`), or a constant the checker evaluates (an enum literal, or a field of an
        anonymous struct literal). Anything else it cannot prove gives None."""
        toks = subject
        if (len(toks) == 6 and toks[0].kind == "builtin" and toks[0].text == "@import" and zigtok.is_op(toks[1], "(")
                and toks[2].kind == "string" and zigtok.is_op(toks[3], ")") and zigtok.is_op(toks[4], ".")
                and toks[5].kind == "identifier"):
            base, field = ("module", zigtok.string_value(toks[2]) or ""), toks[5].text
        else:
            if not toks or len(toks) % 2 == 0 or any(t.kind != "identifier" for t in toks[0::2]) \
                    or any(not zigtok.is_op(t, ".") for t in toks[1::2]):
                return None, "the subject is no name chain"
            names = [t.text for t in toks[0::2]]
            if len(names) == 1:
                b = self.chain(f, q, names, depth)
                return (b[1], "") if b[0] == "enum" else (None, f"{names[0]} is no enum literal constant")
            base, field = self.chain(f, q, names[:-1], depth), names[-1]
        if base[0] == "module":
            if base[1] == "terminal_options" and field == "artifact":
                tag = self.build_artifact()
                return (tag, "") if tag else (None, "the build's terminal_options artifact cannot be read")
            return None, f"the build module {base[1]}'s {field}, which the checker does not evaluate"
        if base[0] == "literal":
            lf, o = base[1], base[2]
            lt, close, depth_ = lf.toks, zigtok.match_paren(lf.toks, base[2]), 0
            for i in range(o + 1, close):
                if zigtok.is_op(lt[i], "(", "[", "{"):
                    depth_ += 1
                elif zigtok.is_op(lt[i], ")", "]", "}"):
                    depth_ -= 1
                elif depth_ == 0 and zigtok.is_op(lt[i], ".") and i + 4 < close and lt[i + 1].text == field \
                        and zigtok.is_op(lt[i + 2], "=") and zigtok.is_op(lt[i + 3], ".") \
                        and lt[i + 4].kind == "identifier" and (i + 5 >= close or zigtok.is_op(lt[i + 5], ",")):
                    return lt[i + 4].text, ""
            return None, f"the literal holds no enum literal field {field}"
        return None, f"{field} of a value the checker does not evaluate ({base[1] if base[0] != 'fn' else 'a function'})"

    @staticmethod
    def switch_arm(toks, open_, tag):
        """The first token of the value of the switch prong (its braces at open_) that holds `.tag`, else of its
        `else` prong; None when neither exists."""
        close, depth_, q, start, other = zigtok.match_paren(toks, open_), 0, open_ + 1, open_ + 1, None
        while q < close:
            t = toks[q]
            if zigtok.is_op(t, "(", "[", "{"):
                depth_ += 1
            elif zigtok.is_op(t, ")", "]", "}"):
                depth_ -= 1
            elif depth_ == 0 and zigtok.is_op(t, "=>"):
                head = toks[start:q]
                if any(zigtok.is_op(head[i], ".") and head[i + 1].kind == "identifier" and head[i + 1].text == tag
                       and (i == 0 or zigtok.is_op(head[i - 1], ",")) and (i + 2 == len(head) or zigtok.is_op(head[i + 2], ","))
                       for i in range(len(head) - 1)):
                    return q + 1
                if len(head) == 1 and head[0].kind == "keyword" and head[0].text == "else":
                    other = q + 1
                # the prong's value runs to the next `,` at this level
                q += 1
                d2 = 0
                while q < close:
                    u = toks[q]
                    if zigtok.is_op(u, "(", "[", "{"):
                        d2 += 1
                    elif zigtok.is_op(u, ")", "]", "}"):
                        d2 -= 1
                    elif d2 == 0 and zigtok.is_op(u, ","):
                        break
                    q += 1
                start = q + 1
            q += 1
        return other

    def expression(self, f, v, at, ends, depth):
        """What the value at token v names, read to one of `ends`: an `@import` of a file and the members after it
        (or of a build module), a container, an anonymous struct literal, an enum literal, a name chain (resolved
        at token `at`, its declaration), or a comptime switch whose subject `enum_value` evaluates, read at the arm
        its tag selects. A switch it cannot evaluate, and any `if`, is ("ambiguous", why): the checker never picks
        an arm the build might not (stone round 4, Sol's Medium 1)."""
        toks, n = f.toks, len(f.toks)
        r, base = v, None
        if toks[r].kind == "keyword" and toks[r].text == "if":
            return ("ambiguous", f"{f.path}:{toks[r].line + 1}: an if the checker does not evaluate")
        if toks[r].kind == "keyword" and toks[r].text == "switch" and r + 1 < n and zigtok.is_op(toks[r + 1], "("):
            c = zigtok.match_paren(toks, r + 1)
            subject = toks[r + 2:c]
            if not (c + 1 < n and zigtok.is_op(toks[c + 1], "{")):
                return ("ambiguous", f"{f.path}:{toks[r].line + 1}: a switch the checker does not read")
            tag, why = self.enum_value(f, r, subject, depth + 1)
            if tag is None:
                return ("ambiguous", f"{f.path}:{toks[r].line + 1}: a switch on {zigtok.spaced(subject)}, "
                                     f"which the checker cannot evaluate ({why})")
            arm = self.switch_arm(toks, c + 1, tag)
            if arm is None:
                return ("ambiguous", f"{f.path}:{toks[r].line + 1}: a switch with no arm for .{tag}")
            return self.expression(f, arm, at, (",", "}"), depth + 1)
        if zigtok.is_op(toks[r], ".") and r + 1 < n and zigtok.is_op(toks[r + 1], "{"):
            close = zigtok.match_paren(toks, r + 1)
            if close + 1 < n and zigtok.is_op(toks[close + 1], *ends):
                return ("literal", f, r + 1)
        if zigtok.is_op(toks[r], ".") and r + 2 < n and toks[r + 1].kind == "identifier" \
                and zigtok.is_op(toks[r + 2], *ends):
            return ("enum", toks[r + 1].text)
        if (toks[r].kind == "builtin" and toks[r].text == "@import" and r + 3 < n and zigtok.is_op(toks[r + 1], "(")
                and toks[r + 2].kind == "string" and zigtok.is_op(toks[r + 3], ")")):
            s = zigtok.string_value(toks[r + 2]) or ""
            if not s.endswith(".zig"):
                if r + 4 < n and zigtok.is_op(toks[r + 4], *ends):
                    return ("module", s)
                return ("unresolved", f"a member of the build module @import(\"{s}\") at {f.path}:{toks[r].line + 1}")
            path = os.path.normpath(os.path.join(os.path.dirname(f.path), s)).replace("\\", "/")
            if path not in self.files:
                return ("unresolved", f"{path}, which the tree does not hold")
            base, r = ("file", path), r + 4
        else:
            h = r
            while h < n and toks[h].kind == "keyword" and toks[h].text in ("extern", "packed"):
                h += 1
            if h < n and toks[h].kind == "keyword" and toks[h].text in zigtok.CONTAINERS:
                h += 1
                if h < n and zigtok.is_op(toks[h], "("):
                    h = zigtok.match_paren(toks, h) + 1
                if h < n and zigtok.is_op(toks[h], "{"):
                    return ("container", f, h)
        names = []
        if base is not None:
            while r + 1 < n and zigtok.is_op(toks[r], ".") and toks[r + 1].kind == "identifier":
                names.append(toks[r + 1].text)
                r += 2
        else:
            while r < n and toks[r].kind == "identifier":
                names.append(toks[r].text)
                if r + 2 < n and zigtok.is_op(toks[r + 1], ".") and toks[r + 2].kind == "identifier":
                    r += 2
                else:
                    r += 1
                    break
        if r >= n or not zigtok.is_op(toks[r], *ends) or (base is None and not names):
            return ("unresolved", f"{f.path}:{toks[v].line + 1}: a value the checker does not read "
                                  f"({zigtok.spaced(toks[v:min(r + 1, n)])[:60]})")
        if base is None:
            return self.chain(f, at, names, depth)
        for name in names:
            base = self.member(base, name, depth)
        return base

    def member(self, b, name, depth):
        if b[0] in ("unresolved", "ambiguous"):
            return b
        if b[0] == "file":
            g, block, where = self.files[b[1]], -1, b[1]
        elif b[0] == "container":
            g, block, where = b[1], b[2], f"{b[1].path}:{b[1].toks[b[2]].line + 1}"
        else:
            return ("unresolved", f"{name} after a value with no members ({b[0]})")
        g.scope()
        ds = [d for d in g.decls.get(name, ()) if d["block"] == block]
        if len(ds) != 1:
            return ("unresolved", f"{name}: {len(ds)} declarations at the level of {where}")
        return self.decl(g, ds[0], depth + 1)


def sets_role(pt):
    """Whether a required entry point's scope sets a role: the module's form or `Roles(.on)`, never `Roles(.off)`
    (which keeps no role even where the layer is on) or a form the checker cannot read, and a role that is not none
    (stone round 5, Sol's Low). Tests' own off-form scopes are no required entry points and stay as they are."""
    return pt["form"] in ("module", "on") and pt["role"] != "none"


def spawn_targets(f, function, target):
    """Each `Thread.spawn(` call (or a `.spawn(` decl literal with no operand) in a function named `function` of f,
    in that function's own body, whose second argument is spelled `target`: [(token index, the argument's
    tokens)]. The registry keys an entry by that spelling (thread_gate15.py's `entries`)."""
    toks, want, out = f.toks, target.replace(" ", ""), []
    for k, d in enumerate(f.fns):
        if d["kind"] != "fn" or d["name"] != function or d["body"] is None:
            continue
        b0, b1 = d["body"]
        for q in range(b0 + 1, min(b1, len(toks) - 1)):
            t = toks[q]
            if f.owner[q] != k or t.kind != "identifier" or t.text != "spawn" or not zigtok.is_op(toks[q - 1], ".") \
                    or not zigtok.is_op(toks[q + 1], "("):
                continue
            r = toks[q - 2] if q >= 2 else None
            if not ((r is not None and r.kind == "identifier" and r.text == "Thread")
                    or r is None or not (r.kind in ("identifier", "number", "string", "char")
                                         or zigtok.is_op(r, ")", "]", "?", ".*"))):
                continue
            runs, _ = zigtok.split_args(toks, q + 1)
            if len(runs) >= 2 and zigtok.spaced(runs[1], blank=True).replace(" ", "") == want:
                out.append((q, runs[1], k))
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
    for art, follow in (("app", lambda in_test, in_block: not in_test), ("test", lambda in_test, in_block: True),
                        ("outside-test-blocks", lambda in_test, in_block: not in_block)):
        seen, todo = set(), [ROOT]
        while todo:
            p = todo.pop()
            if p in seen or p not in files:
                continue
            seen.add(p)
            todo.extend(t for t, in_test, in_block in files[p].imports() if follow(in_test, in_block))
        reach[art] = seen
    # files the test exe reaches only through imports in test code (`conpty_host.zig`, rooted for its own tests):
    # there only what a test calls is compiled, so an entry there counts only when a test of its file names its spawner
    # (an `if (builtin.is_test)` import, such as win32.zig's of test_support.zig, is no such root: the whole file
    # is the test build's)
    test_rooted = reach["test"] - reach["outside-test-blocks"]

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
                               op=t.text, form=recv[r.text]))

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

    resolver = Resolver(files)

    def bind(e):
        """The function entry e's spawn names, resolved from the spawn call itself: ("fn", file, index), or
        ("unresolved"|"no-spawn"|"ambiguous", why)."""
        f = files.get(e["file"])
        if f is None:
            return ("no-spawn", f"{e['file']} is not in the tree")
        spawns = spawn_targets(f, e["function"], e["target"])
        if not spawns:
            return ("no-spawn", f"{e['function']} in {e['file']} makes no Thread.spawn of {e['target']}")
        found = []
        for q, arg, _ in spawns:
            names = [t.text for t in arg[0::2]]
            if not arg or len(arg) % 2 == 0 or any(t.kind != "identifier" for t in arg[0::2]) \
                    or any(not zigtok.is_op(t, ".") for t in arg[1::2]):
                return ("unresolved", f"the spawn at {e['file']}:{f.toks[q].line + 1} names no declaration chain")
            b = resolver.chain(f, q, names)
            if b[0] != "fn":
                return b if b[0] in ("unresolved", "ambiguous") else ("unresolved", f"{e['target']} names no function")
            if all(not (b[1] is x[1] and b[2] == x[2]) for x in found):
                found.append(b)
        if len(found) > 1:
            return ("ambiguous", "its spawns name different functions (" + ", ".join(
                f"{x[1].path}:{x[1].toks[x[1].fns[x[2]]['fn']].line + 1}" for x in found) + ")")
        return found[0]

    def spawned_only_by_tests(e):
        """Whether every spawn of entry e is in a function only a test build compiles: test code, a test-only span
        of its file (`test_only_spans`), or a function every mention of whose name, in every file, is test code or
        inside a test-only span (host.zig's pub `Host.runOnPrivateDesktop`). A name met in production code anywhere
        keeps the entry counted, so a name collision can only keep a check, never drop one."""
        f = files.get(e["file"])
        if f is None:
            return False
        spawns = spawn_targets(f, e["function"], e["target"])
        if not spawns:
            return False
        for q, _, k in spawns:
            if test_only_code(f, q):
                continue
            name, own = f.fns[k]["name"], f.fns[k]["fn"] + 1
            mentions = [(g, r) for g in files.values() for r in g.ident_index().get(name, ())
                        if not (g is f and r == own)]
            if not mentions or not all(test_only_code(g, r) for g, r in mentions):
                return False
        return True

    counted = {"app": [], "test": []}
    matched = {"app": set(), "test": set()}
    test_build_only = set()   # the role points of the targets only test-only spawners start: not in the app exe
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
            if art == "app" and spawned_only_by_tests(e):
                report.append(f"REPORTED {art} {e['file']} {e['function']} -> {e['target']} ({e['role']}): its "
                              f"spawning function is compiled only into a test build; not counted")
                b = bind(e)
                if b[0] == "fn":
                    test_build_only.update((b[1].path, pt["q"]) for pt in points
                                           if pt["file"] == b[1].path and pt["k"] == b[2])
                continue
            b = bind(e)
            head = f"{art} {e['file']} {e['function']} -> {e['target']}"
            if b[0] == "no-spawn":
                failures.append(f"ENTRY-SPAWN-NOT-FOUND {head}: {b[1]}")
                continue
            if b[0] == "unresolved":
                failures.append(f"ENTRY-TARGET-NOT-FOUND {head}: {b[1]}")
                continue
            if b[0] == "ambiguous":
                failures.append(f"ENTRY-AMBIGUOUS {head}: {b[1]}")
                continue
            tf, tk = b[1], b[2]
            # only the bound function's own points: a same-named function elsewhere credits nothing
            cands = [pt for pt in points if pt["file"] == tf.path and pt["k"] == tk and not pt["test"]]
            with_role = [pt for pt in cands if pt["role"] == e["role"]]
            where = f"{tf.path}:{tf.toks[tf.fns[tk]['fn']].line + 1}"
            if not with_role:
                if cands:
                    failures.append(f"ENTRY-WRONG-ROLE {head}: its target ({where}) enters "
                                    f"{', '.join(sorted({pt['role'] for pt in cands}))}, the registry says {e['role']}")
                else:
                    failures.append(f"ENTRY-NO-ROLE {head}: its target ({where}) sets no role ({e['role']})")
                continue
            top = [pt for pt in with_role if tf.top_level_in_body(pt["k"], pt["q"])]
            if not top:
                failures.append(f"ENTRY-NOT-TOP-LEVEL {art} {e['file']} {e['function']} -> {e['target']}: its role is "
                                f"set inside a nested block ({with_role[0]['file']}:{with_role[0]['line']}), so the "
                                f"thread can run without it")
                continue
            eager = [pt for pt in top if pt["op"] in SCOPE_OPS and tf.scope_statement(pt["k"], pt["q"])]
            if not eager:
                failures.append(f"ENTRY-NOT-FIRST {head}: its role call ({top[0]['file']}:{top[0]['line']}) is not "
                                f"the eager first statement of its target (`const s = thread_role."
                                f"{'/'.join(SCOPE_OPS)}(...);`, with no defer, if or other wrapper and nothing "
                                f"before it), so the thread can run without the role")
                continue
            setting = [pt for pt in eager if sets_role(pt)]
            if not setting:
                failures.append(f"ENTRY-SETS-NO-ROLE {head}: its first statement ({eager[0]['file']}:{eager[0]['line']}) "
                                f"is a {eager[0]['form']}-form scope of role {eager[0]['role']}, which sets no role "
                                f"(`Roles(.off)`, role none, or a form the checker cannot read)")
                continue
            eager = setting
            for pt in eager:
                matched[art].add((pt["file"], pt["q"]))
            counted[art].append(e)
            report.append(f"ENTRY-OK {art} {e['file']} {e['function']} -> {e['target']}: {eager[0]['file']}:"
                          f"{eager[0]['line']} {eager[0]['fn']} enters {e['role']}")

    # each point: in which artifact, and what it is
    kinds = {"app": {}, "test": {}}
    for pt in points:
        f = files[pt["file"]]
        for art in ("app", "test"):
            if pt["file"] not in reach[art] or (art == "app" and (pt["test"] or (pt["file"], pt["q"]) in test_build_only)):
                continue
            kind = None
            if pt["test"]:
                kind = "TEST-EDIT-POINT"
            elif pt["op"] == "fixture":
                c = f.container_of(pt["q"])
                if c is not None and any(c is x for x in test_only_containers(f)):
                    kind = "FIXTURE-HELPER"
            if kind is None and pt["file"] == MAIN_FILE and pt["fn"] == "main" and pt["role"] == "ui" \
                    and f.parent[pt["k"]] is None and pt["op"] in SCOPE_OPS and sets_role(pt) \
                    and f.scope_statement(pt["k"], pt["q"]):
                kind = "MAIN-UI-SCOPE"
            if kind is None and (pt["file"], pt["q"]) in matched[art]:
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
            failures.append(f"NO-MAIN-UI-SCOPE {art}: {MAIN_FILE} main does not enter ui in the first statement of "
                            f"its body, before any work")

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


def test_only_spans(f):
    """The file-level declarations that are not `pub` and that only test code names, as (first token, last token,
    container or None): a container (`const NAME = struct {...}`), a function, or another `const NAME = ...;` (an
    alias such as palette_controller.zig's `const runOnPrivateDesktop = test_runtime.runOnPrivateDesktop;`), every
    mention of whose name outside its own span is in test code (an `if (builtin.is_test)` branch included) or inside
    another such span (`ClipboardReplyFixture`, which the test-only helpers `EmptyPasteClipboard` and
    `expectUserPasteWithoutText` also name), with at least one mention. The least fixed point, so declarations that
    name only each other are not test-only."""
    if f.test_only is not None:
        return f.test_only
    toks, idents = f.toks, f.ident_index()
    cands, heads = [], set()   # (name, lo, hi, container or None)
    for c in f.containers:
        h = c["head"]
        if c["naming"] != "declaration" or h is None or f.owner[h] is not None or f.container_of(h) is not None:
            continue   # anonymous, or nested in a function or another container
        heads.add(h)
        if h >= 1 and toks[h - 1].kind == "keyword" and toks[h - 1].text == "pub":
            continue
        cands.append((c["name"], h, c["close"], c))
    for k, d in enumerate(f.fns):
        lo = d["start"]
        if d["kind"] != "fn" or f.parent[k] is not None or f.container_of(lo) is not None \
                or "pub" in d["quals"] or d["body"] is None:
            continue   # a test block, a nested or a container's function, a pub one, or an extern declaration
        cands.append((d["name"], lo, d["end"], None))
    for q in range(len(toks) - 2):
        if q in heads or not zigtok.declaration_at(toks, q) or toks[q].text != "const" or f.owner[q] is not None \
                or f.container_of(q) is not None or (q >= 1 and toks[q - 1].kind == "keyword" and toks[q - 1].text == "pub"):
            continue
        r, d = q + 2, 0
        while r < len(toks):
            t = toks[r]
            if zigtok.is_op(t, "(", "[", "{"):
                d += 1
            elif zigtok.is_op(t, ")", "]", "}"):
                d -= 1
            elif d == 0 and zigtok.is_op(t, ";"):
                break
            r += 1
        cands.append((toks[q + 1].text, q, min(r, len(toks) - 1), None))
    spans = []
    for name, lo, hi, c in cands:
        mentions = [q for q in idents.get(name, ()) if not (lo <= q <= hi)]
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
    f.test_only = [(x[0], x[1], x[2]) for x in chosen]
    return f.test_only


def test_only_containers(f):
    """The containers among `test_only_spans`."""
    return [x[2] for x in test_only_spans(f) if x[2] is not None]


def test_only_code(f, q):
    """Whether token q of f is compiled only into a test build: test code, or inside a test-only span."""
    return f.in_test[q] or any(lo <= q <= hi for lo, hi, _ in test_only_spans(f))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
