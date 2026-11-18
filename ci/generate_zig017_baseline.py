"""Generate PLAN 4.1's baseline from a reviewed result and its fork parent.

The TSV columns match lint_baseline_counts.py. The header retains the parent
needed for remaining-allowance arithmetic. The matcher is shared with the lint.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import paths, revision, sources
from zig017_lint import occurrences


def generate(repo, parent, result):
    parent, result = revision(repo, parent), revision(repo, result)
    names = {p for p in paths(repo, result) if p.endswith(".zig")}
    old = sources(repo, parent, names & paths(repo, parent))
    new = sources(repo, result, names)
    rows = [f"# fork-parent: {parent}\n"]
    for name in sorted(names):
        delta = occurrences(new[name]) - occurrences(old.get(name, ""))
        for (form, line), allowance in sorted(delta.items()):
            rows.append(f"{name}\t{form}\t{allowance}\t{line}\n")
    return "".join(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo")
    parser.add_argument("fork_parent")
    parser.add_argument("result")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    text = generate(args.repo, args.fork_parent, args.result)
    args.output.write_text(text, encoding="utf-8", newline="\n")
    print(f"baseline entries: {len(text.splitlines()) - 1}")


if __name__ == "__main__":
    main()
