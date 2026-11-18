"""Reject added uses of the migration inventory's removed std Win32 names."""

import argparse
import functools
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import added_lines, emit, paths, sources
from zig017_lint import identifier
import zigtok

def chain(tokens):
    """A literal identifier access chain, with harmless outer parentheses."""
    while len(tokens) >= 2 and tokens[0].text == "(" and zigtok.match_paren(tokens, 0) == len(tokens) - 1:
        tokens = tokens[1:-1]
    if not tokens or tokens[0].kind != "identifier":
        return None
    result = [identifier(tokens[0])]
    for i in range(1, len(tokens), 2):
        if i + 1 >= len(tokens) or tokens[i].text != "." or tokens[i + 1].kind != "identifier":
            return None
        result.append(identifier(tokens[i + 1]))
    return result


class Bindings:
    """Resolve the inventory's namespace aliases with lexical block ownership.

    This is a namespace lint, not a Zig type checker. It follows const aliases
    and literal imports, including forward container declarations. Arbitrary
    computed namespace values are outside the inventory's binding grammar.
    """

    def __init__(self, text, reexports=None, own_windows=False):
        self.tokens = zigtok.code(text)
        self.reexports = reexports or {}
        self.own_windows = own_windows
        self.resolved = {}
        self.scopes, self.parents, self.decls = [], {0: None}, {}
        stack = [0]
        for i, token in enumerate(self.tokens):
            self.scopes.append(stack[-1])
            if zigtok.is_op(token, "{"):
                self.parents[i + 1] = stack[-1]
                stack.append(i + 1)
            elif zigtok.is_op(token, "}") and len(stack) > 1:
                stack.pop()
        for i, token in enumerate(self.tokens):
            if not zigtok.declaration_at(self.tokens, i):
                continue
            name = identifier(self.tokens[i + 1])
            end, depth, equals = i + 2, 0, None
            while end < len(self.tokens):
                current = self.tokens[end]
                if depth == 0 and zigtok.is_op(current, ";"):
                    break
                if depth == 0 and zigtok.is_op(current, "="):
                    equals = end
                if zigtok.is_op(current, "(", "[", "{"):
                    depth += 1
                elif zigtok.is_op(current, ")", "]", "}"):
                    if depth == 0:
                        break
                    depth -= 1
                end += 1
            if equals is not None:
                self.decls[self.scopes[i], name] = (i, self.tokens[equals + 1:end])

    def lookup(self, name, at):
        scope = self.scopes[at]
        while scope is not None:
            if (scope, name) in self.decls:
                return self.decls[scope, name]
            scope = self.parents[scope]
        return None

    def expression(self, tokens, at, visiting):
        if not tokens or (tokens[0].kind != "identifier" and tokens[0].text not in ("@import", "(")):
            return None
        words = [identifier(t) for t in tokens]
        if len(tokens) >= 4 and words[:2] == ["@import", "("] and tokens[2].kind == "string" and words[3] == ")":
            module = zigtok.unescape(tokens[2].text[1:-1]).decode("utf-8")
            tail = chain(tokens[4:]) if len(tokens) > 4 and words[4] != "." else None
            if len(tokens) > 4:
                tail = chain(tokens[5:]) if words[4] == "." else tail
                if tail is None:
                    return None
            else:
                tail = []
            if module == "std":
                return self.resolve(["std"] + tail, at, visiting, builtin_std=True)
            if module.endswith("win32.zig"):
                return self.resolve(["win32"] + tail, at, visiting, builtin_std=True)
            if module.endswith("os.zig") or module.endswith("os/main.zig"):
                return self.resolve(["internal_os"] + tail, at, visiting, builtin_std=True)
            return None
        parts = chain(tokens)
        return self.resolve(parts, at, visiting) if parts else None

    def resolve(self, parts, at, visiting=frozenset(), builtin_std=False):
        if not parts:
            return None
        name = parts[0]
        decl = None if builtin_std else self.lookup(name, at)
        if decl:
            index, expression = decl
            if index in visiting:
                return None
            if index not in self.resolved:
                self.resolved[index] = self.expression(expression, index, visiting | {index})
            origin = self.resolved[index]
            if origin is None:
                return None
            kind, prefix = origin
            return self.normalize(kind, prefix + parts[1:])
        if name == "std":
            if parts[1:3] == ["os", "windows"]:
                return "std", parts[3:]
            return "std-module", parts[1:]
        if name == "win32":
            return ("std", parts[2:]) if parts[1:2] == ["windows"] else ("win32-module", parts[1:])
        if name in ("internal_os", "os"):
            return ("fork", parts[2:]) if parts[1:2] == ["windows"] else ("os-module", parts[1:])
        return None

    def normalize(self, kind, parts):
        if kind == "std-module" and parts[:2] == ["os", "windows"]:
            return "std", parts[2:]
        if kind == "win32-module" and parts[:1] == ["windows"]:
            return "std", parts[1:]
        if kind == "os-module" and parts[:1] == ["windows"]:
            return "fork", parts[1:]
        if kind == "fork" and parts and parts[0] in self.reexports:
            return "std", self.reexports[parts[0]] + parts[1:]
        return kind, parts

    def uses(self, removed):
        for i, token in enumerate(self.tokens):
            if token.kind != "identifier" or (i and self.tokens[i - 1].text == "."):
                continue
            if i and self.tokens[i - 1].text in ("const", "var", "fn"):
                continue
            end = i + 1
            while end + 1 < len(self.tokens) and self.tokens[end].text == "." and self.tokens[end + 1].kind == "identifier":
                end += 2
            origin = self.resolve(chain(self.tokens[i:end]), i)
            if not origin:
                continue
            kind, parts = self.normalize(*origin)
            if kind == "fork" and self.own_windows:
                kind = "std"
            if kind != "std":
                continue
            # A name is a namespace's first member or a root declaration.
            for size in (1, 2):
                key = ".".join(parts[:size])
                if len(parts) >= size and key in removed:
                    yield key, {t.line + 1 for t in self.tokens[i:end]}, token.line + 1
                    break


def reexports(text):
    bindings = Bindings(text)
    result = {}
    for (scope, name), (at, expression) in bindings.decls.items():
        if scope != 0 or at == 0 or bindings.tokens[at - 1].text != "pub":
            continue
        parts = chain(expression)
        if parts and parts[0] == "windows":
            result[name] = parts[1:]
    return result


def fork_added(repo, head, upstream):
    """Exactly the head paths absent from the three-tree generated path list.

    Upstream rename sources are already in that list. A new head path gains
    no extra exemption by being a fork rename of a previously shared path.
    """
    return paths(repo, head) - set(upstream)


@functools.lru_cache(maxsize=64)
def removed_uses(text, exports, removed):
    return tuple(Bindings(text, dict((name, list(parts)) for name, parts in exports)).uses(removed))


def check(repo, base, head, upstream_path, removed_path):
    upstream = set(upstream_path.read_text(encoding="utf-8").splitlines())
    removed = set(removed_path.read_text(encoding="utf-8").splitlines())
    if not upstream or len(removed) != 124:
        raise ValueError("missing upstream paths or wrong removed-identifier inventory")
    added = added_lines(repo, base, head)
    names = set(added) & fork_added(repo, head, upstream)
    texts = sources(repo, head, names | {"src/os/windows.zig"})
    exports = reexports(texts["src/os/windows.zig"])
    findings = set()
    for name in sorted(names):
        export_key = tuple(sorted((name, tuple(parts)) for name, parts in exports.items()))
        for key, span, line in removed_uses(texts[name], export_key, frozenset(removed)):
            if span & added[name]:
                findings.add((name, line, "error", "removed std.os.windows." + key))
    return sorted(findings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--mode", choices=("report", "enforce"), default="report")
    parser.add_argument("--upstream-paths", type=Path, default=Path(__file__).with_name("upstream-paths.txt"))
    parser.add_argument("--removed-identifiers", type=Path, default=Path(__file__).with_name("win32-removed-identifiers.txt"))
    args = parser.parse_args()
    return emit("Win32 identifier migration lint", check(args.repo, args.base, args.head,
                args.upstream_paths, args.removed_identifiers), args.mode)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, IndexError, UnicodeError, subprocess.CalledProcessError) as error:
        print(f"lint input error ({type(error).__name__}); refusing to pass", file=sys.stderr)
        sys.exit(2)
