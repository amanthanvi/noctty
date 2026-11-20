"""Reject added uses of std Win32 names removed by Zig 0.17.1."""

import argparse
import functools
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import emit, line_changes, paths, sources
from zig_bindings import Bindings as LiteralBindings


class Bindings(LiteralBindings):
    def uses(self, removed, added=None, deleted=(), changed_exports=frozenset()):
        changed = self.changed_aliases(added or (), deleted)
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


def fork_added(repo, head, upstream):
    """Head paths absent from the three-tree union (upstream rename sources included)."""
    return paths(repo, head) - set(upstream)


@functools.lru_cache(maxsize=64)
def removed_uses(path, text, exports, removed, added, deleted, changed_exports):
    bindings = Bindings(text, dict(exports), path)
    return tuple(bindings.uses(removed, frozenset(added), deleted, changed_exports))


def check(repo, base, head, upstream_path, removed_path):
    upstream = set(upstream_path.read_text(encoding="utf-8").splitlines())
    rows = removed_path.read_text(encoding="utf-8").splitlines()
    if not upstream or not rows or rows != sorted(set(rows)):
        raise ValueError("missing upstream paths or malformed removed-name inventory")
    removed = frozenset(rows)
    changes = line_changes(repo, base, head)
    module = "src/os/windows.zig"
    new_module = sources(repo, head, {module})[module]
    bindings = LiteralBindings(new_module, path=module)
    origins = dict(export_origins(bindings))
    exports = tuple(sorted((name, origin.parts) for name, origin in origins.items()))
    changed = bindings.changed_aliases(*changes.get(module, ((), ())))
    changed_exports = frozenset(name for name, origin in origins.items() if origin.declarations & changed)
    fork = {name for name in fork_added(repo, head, upstream) if name.endswith(".zig")}
    # A re-export edit can change bindings even in files with no changed lines.
    names = fork if changed_exports else set(changes) & fork
    texts = sources(repo, head, names)
    findings = set()
    for name in sorted(names):
        added, deleted = changes.get(name, ((), ()))
        for key, span, line in removed_uses(name, texts[name], exports, removed, tuple(sorted(added)),
                                          tuple(sorted(deleted)), changed_exports):
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
