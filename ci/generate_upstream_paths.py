"""Generate the three-tree path union, including upstream rename sources.

Read-only inputs; output is the only write. See README.md for the pinned trees.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import paths, revision

PINS = ("ba398dfff3e30ff83da07140981ca138410cf608",
        "74d0c72fd9318ad3ab95bfb56f6c2d995e267e2e",
        "83fb95624b0439ee660c2679b43b38c8b63769cd")


def generate(repos):
    result = set()
    for repo, pin in zip(repos, PINS, strict=True):
        if revision(repo, pin) != pin:
            raise ValueError("upstream pin mismatch")
        result.update(paths(repo, pin))
    # A rename source is already a path in its start tree, included above.
    return "".join(p + "\n" for p in sorted(result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_repo")
    parser.add_argument("stone_repo")
    parser.add_argument("v140_repo")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    text = generate((args.base_repo, args.stone_repo, args.v140_repo))
    args.output.write_text(text, encoding="utf-8", newline="\n")
    print(f"upstream paths: {len(text.splitlines())}")


if __name__ == "__main__":
    main()
