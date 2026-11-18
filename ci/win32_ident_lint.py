"""Reject added uses of std Win32 names removed by Zig 0.17.1."""

import argparse
import functools
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import added_lines, emit, merge_base, paths, sources
from zig_bindings import Bindings as LiteralBindings


class Bindings(LiteralBindings):
    def uses(self, removed, added=None):
        for start, end, origin in self.accesses():
            if origin.kind != "std" or origin.parts[:2] != ("os", "windows"):
                continue
            parts = origin.parts[2:]
            # Prefer the member when a whole namespace and its member disappeared.
            for size in range(len(parts), 0, -1):
                key = ".".join(parts[:size])
                if len(parts) >= size and key in removed:
                    span = self.span(start, end, origin)
                    if added is None or span & added or origin.exports & self.changed_exports:
                        yield key, span, self.tokens[start].line + 1
                    break


def reexports(text):
    bindings, result = LiteralBindings(text, path="src/os/windows.zig"), {}
    for (scope, name), (at, expression) in bindings.decls.items():
        if scope != 0 or at == 0 or bindings.tokens[at - 1].text != "pub":
            continue
        origin = bindings.resolve([name], at)
        if origin and origin.kind == "std":
            result[name] = list(origin.parts)
    return result


def fork_added(repo, head, upstream):
    """Head paths absent from the three-tree union (upstream rename sources included)."""
    return paths(repo, head) - set(upstream)


@functools.lru_cache(maxsize=64)
def removed_uses(path, before, text, old_exports, exports, removed, added):
    bindings = Bindings(text, dict(exports), path)
    bindings.previous = Bindings(before, dict(old_exports), path)
    bindings.changed_exports = frozenset(name for name, value in exports
                                        if dict(old_exports).get(name) != value)
    return tuple(bindings.uses(removed, frozenset(added)))


def check(repo, base, head, upstream_path, removed_path):
    upstream = set(upstream_path.read_text(encoding="utf-8").splitlines())
    rows = removed_path.read_text(encoding="utf-8").splitlines()
    if not upstream or not rows or rows != sorted(set(rows)):
        raise ValueError("missing upstream paths or malformed removed-name inventory")
    removed = frozenset(rows)
    comparison = merge_base(repo, base, head)
    added = added_lines(repo, base, head)
    module = "src/os/windows.zig"
    old_paths = paths(repo, comparison)
    old_module = sources(repo, comparison, {module})[module] if module in old_paths else ""
    new_module = sources(repo, head, {module})[module]
    old_exports, exports = (tuple(sorted((name, tuple(parts)) for name, parts in reexports(text).items()))
                            for text in (old_module, new_module))
    fork = {name for name in fork_added(repo, head, upstream) if name.endswith(".zig")}
    # A re-export edit can change bindings even in files with no changed lines.
    names = fork if old_exports != exports else set(added) & fork
    texts = sources(repo, head, names)
    before = sources(repo, comparison, names & old_paths)
    findings = set()
    for name in sorted(names):
        for key, span, line in removed_uses(name, before.get(name, ""), texts[name], old_exports,
                                          exports, removed, tuple(sorted(added.get(name, ())))):
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
