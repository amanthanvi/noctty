"""Generate every removed public std.os.windows root and namespace name.

    python -I ci/generate_win32_identifiers.py STD17 STD15 OUTPUT

Reads compiler sources only, with no repository pin or temporary directory.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from zig_bindings import public_names


def declarations(std):
    root = public_names((std / "os/windows.zig").read_text(encoding="utf-8"))
    namespaces = {p.stem: public_names(p.read_text(encoding="utf-8"))
                  for p in (std / "os/windows").glob("*.zig") if p.stem in root}
    return root, namespaces


def generate(std17, std15):
    root15, namespaces15 = declarations(std15)
    root17, namespaces17 = declarations(std17)
    removed = set(root15 - root17)
    for name, members in namespaces15.items():
        removed.update(name + "." + member for member in members - namespaces17.get(name, set()))
    if not removed:
        raise ValueError("empty removed-name inventory")
    return "".join(name + "\n" for name in sorted(removed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("std17", type=Path)
    parser.add_argument("std15", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    text = generate(args.std17, args.std15)
    args.output.write_text(text, encoding="utf-8", newline="\n")
    print(f"verified removed names: {len(text.splitlines())}; plan reached inventory: 124")


if __name__ == "__main__":
    main()
