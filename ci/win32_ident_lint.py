"""Reject added uses of std Win32 names removed by Zig 0.17.1."""

import argparse
import functools
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import added_lines, emit, paths, sources
from zig_bindings import Bindings as LiteralBindings, chain


class Bindings(LiteralBindings):
    def uses(self, removed):
        for start, end, origin in self.accesses():
            if origin.kind != "std" or origin.parts[:2] != ("os", "windows"):
                continue
            parts = origin.parts[2:]
            # Prefer the member when a whole namespace and its member disappeared.
            for size in (2, 1):
                key = ".".join(parts[:size])
                if len(parts) >= size and key in removed:
                    yield key, self.span(start, end, origin), self.tokens[start].line + 1
                    break


def reexports(text):
    bindings, result = LiteralBindings(text), {}
    for (scope, name), (at, expression) in bindings.decls.items():
        if scope != 0 or at == 0 or bindings.tokens[at - 1].text != "pub":
            continue
        parts = chain(expression)
        if parts and parts[0] == "windows":
            result[name] = parts[1:]
    return result


def fork_added(repo, head, upstream):
    """Head paths absent from the three-tree union (upstream rename sources included)."""
    return paths(repo, head) - set(upstream)


@functools.lru_cache(maxsize=64)
def removed_uses(path, text, exports, removed):
    return tuple(Bindings(text, {name: list(parts) for name, parts in exports}, path).uses(removed))


def check(repo, base, head, upstream_path, removed_path):
    upstream = set(upstream_path.read_text(encoding="utf-8").splitlines())
    rows = removed_path.read_text(encoding="utf-8").splitlines()
    if not upstream or not rows or rows != sorted(set(rows)):
        raise ValueError("missing upstream paths or malformed removed-name inventory")
    removed = frozenset(rows)
    added = added_lines(repo, base, head)
    names = set(added) & fork_added(repo, head, upstream)
    texts = sources(repo, head, names | {"src/os/windows.zig"})
    exports = tuple(sorted((name, tuple(parts)) for name, parts in reexports(texts["src/os/windows.zig"]).items()))
    findings = set()
    for name in sorted(names):
        for key, span, line in removed_uses(name, texts[name], exports, removed):
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
