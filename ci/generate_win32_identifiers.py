"""Regenerate the 124-name inventory with the plan's original win_idents3.py.

    python -I ci/generate_win32_identifiers.py REPO STD17 STD15 OUTPUT

Uses the measured 31796f5d0 revision, not the moving PR head. Every generated
name is independently checked against declarations in both compiler std trees.
"""

import argparse
import contextlib
import io
import runpy
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import paths

INVENTORY_REV = "31796f5d0"


def generate(repo, std17, std15):
    old_argv = sys.argv
    try:
        scratch = Path(tempfile.mkdtemp(prefix="win32-inventory-"))
        fork = scratch / "fork.txt"
        fork.write_text("\n".join(sorted(paths(repo, INVENTORY_REV))) + "\n", encoding="utf-8")
        sys.argv = ["win_idents3.py", str(repo), INVENTORY_REV, str(std17), str(std15),
                    str(fork), str(scratch / "uses.tsv")]
        with contextlib.redirect_stdout(io.StringIO()):
            data = runpy.run_path(str(Path(__file__).with_name("win_idents3.py")))
        names = sorted(data["uses"])
        if len(names) != 124 or not all(data["removed"](name.split("."))[0] for name in names):
            raise ValueError("compiler sources disagree with the 124-name inventory")
        return "".join(name + "\n" for name in names)
    finally:
        sys.argv = old_argv


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo")
    parser.add_argument("std17", type=Path)
    parser.add_argument("std15", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    text = generate(args.repo, args.std17, args.std15)
    args.output.write_text(text, encoding="utf-8", newline="\n")
    print(f"verified removed identifiers: {len(text.splitlines())}")


if __name__ == "__main__":
    main()
