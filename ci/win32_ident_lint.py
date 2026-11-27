"""Reject added uses of std Win32 names removed by Zig 0.17.1."""

import argparse
import functools
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import emit, line_changes, paths, sources
from zig_bindings import Bindings as LiteralBindings
import zigtok


PREFIX_KEYWORDS = ("pub", "export", "extern", "threadlocal", "comptime")


def own_tokens(bindings, index):
    """A declaration's first token and its own tokens: its prefix keywords, then `const NAME = ... ;`."""
    tokens = bindings.tokens
    start = index
    while start and tokens[start - 1].kind == "keyword" and tokens[start - 1].text in PREFIX_KEYWORDS:
        start -= 1
    return start, tuple((t.kind, t.text) for t in tokens[start:bindings.ends[index] + 1])


def braces_before(tokens, first, start):
    """The `{` and `}` tokens from `first` up to `start`: where in its hunk a declaration sits."""
    return tuple(t.text for t in tokens[first:start] if zigtok.is_op(t, "{", "}"))


def removed_declarations(lines):
    """(braces before it, its own tokens) of each declaration on a hunk's removed lines."""
    side = LiteralBindings("\n".join(lines))
    found = set()
    for index in side.ends:
        start, own = own_tokens(side, index)
        found.add((braces_before(side.tokens, 0, start), own))
    return found


def changed_declarations(bindings, added, deleted, hunks):
    """The head declarations a changed line or deletion gap touches, but for one that a hunk only rewrote (council P1
    and Q1 on #768): every line of it is an added line of one hunk, and a declaration on that hunk's removed lines
    has the same whole token sequence, name included, and the same braces before it inside the hunk. So a comment on
    an alias line beside an edit to the next line changes no binding. Anything else counts as changed and rechecks
    its uses, a move to another hunk included: a documented over-report, which fails closed."""
    touched = bindings.changed_aliases(added, deleted)
    if not touched or not hunks:
        return touched
    tokens = bindings.tokens
    removed = [removed_declarations(lines) for _, lines in hunks]
    changed = set()
    for index in touched:
        first, last = bindings.definition_lines(index)
        start, own = own_tokens(bindings, index)
        kept = False
        for (rows, _), before in zip(hunks, removed):
            if all(line in rows for line in range(first, last + 1)):
                top = min(rows)
                lead = next(i for i, t in enumerate(tokens) if t.line + 1 >= top)
                kept = (braces_before(tokens, lead, start), own) in before
                break
        if not kept:
            changed.add(index)
    return frozenset(changed)


class Bindings(LiteralBindings):
    def uses(self, removed, added=None, deleted=(), changed_exports=frozenset(), hunks=()):
        changed = changed_declarations(self, added or (), deleted, hunks)
        for start, end, origin in self.accesses():
            if origin.kind != "std" or origin.parts[:2] != ("os", "windows"):
                continue
            parts = origin.parts[2:]
            # Prefer the member when a whole namespace and its member disappeared.
            for size in range(len(parts), 0, -1):
                key = ".".join(parts[:size])
                if len(parts) >= size and key in removed:
                    span = self.span(start, end, origin)
                    reference = self.span(start, end)
                    if (added is None or reference & added or origin.declarations & changed
                            or origin.exports & changed_exports):
                        yield key, span, self.tokens[start].line + 1
                    break


def export_origins(bindings):
    for (scope, name), (at, expression) in bindings.decls.items():
        if scope != 0 or at == 0 or bindings.tokens[at - 1].text != "pub":
            continue
        origin = bindings.resolve([name], at)
        if origin and origin.kind == "std":
            yield name, origin


def reexports(text):
    return {name: list(origin.parts) for name, origin in export_origins(
        LiteralBindings(text, path="src/os/windows.zig"))}


def same_zig_code(removed, added):
    """Whether a hunk's removed and added lines hold the same Zig tokens, comments dropped: an edit to comments or
    whitespace only, which adds no reference and changes no binding (council no-seat N3). No Zig token spans a
    line, so a hunk's lines tokenize as they do in the file."""
    def tokens(lines):
        return [(t.kind, t.text) for t in zigtok.code("\n".join(lines))]
    return tokens(removed) == tokens(added)


def fork_added(repo, head, upstream):
    """Head paths absent from the three-tree union (upstream rename sources included)."""
    return paths(repo, head) - set(upstream)


@functools.lru_cache(maxsize=64)
def removed_uses(path, text, exports, removed, added, deleted, changed_exports, hunks=()):
    bindings = Bindings(text, dict(exports), path)
    return tuple(bindings.uses(removed, frozenset(added), deleted, changed_exports, hunks))


def check(repo, base, head, upstream_path, removed_path):
    upstream = set(upstream_path.read_text(encoding="utf-8").splitlines())
    rows = removed_path.read_text(encoding="utf-8").splitlines()
    if not upstream or not rows or rows != sorted(set(rows)):
        raise ValueError("missing upstream paths or malformed removed-name inventory")
    removed = frozenset(rows)
    hunks = {}
    changes = line_changes(repo, base, head, same_code=same_zig_code, hunks=hunks)

    def hunks_of(name):
        return tuple((frozenset(rows), lines) for rows, lines in hunks.get(name, ()))

    module = "src/os/windows.zig"
    new_module = sources(repo, head, {module})[module]
    bindings = LiteralBindings(new_module, path=module)
    origins = dict(export_origins(bindings))
    exports = tuple(sorted((name, origin.parts) for name, origin in origins.items()))
    changed = changed_declarations(bindings, *changes.get(module, ((), ())), hunks_of(module))
    changed_exports = frozenset(name for name, origin in origins.items() if origin.declarations & changed)
    fork = {name for name in fork_added(repo, head, upstream) if name.endswith(".zig")}
    # A re-export edit can change bindings even in files with no changed lines.
    names = fork if changed_exports else set(changes) & fork
    texts = sources(repo, head, names)
    findings = set()
    for name in sorted(names):
        added, deleted = changes.get(name, ((), ()))
        for key, span, line in removed_uses(name, texts[name], exports, removed, tuple(sorted(added)),
                                          tuple(sorted(deleted)), changed_exports, hunks_of(name)):
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
