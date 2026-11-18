#!/usr/bin/env python3
"""Always-run build identity and executable post-cutover file contract."""

import json
import re
import subprocess
import sys
from pathlib import Path


def main():
    compiler, api, source, output = sys.argv[1:]
    version = tuple(map(int, compiler.split(".")[:2]))
    modern = version >= (0, 17)
    if modern and api in ("fork", "stone", "stone_flag"):
        raise ValueError("legacy oracle API selected on a modern compiler")
    legacy = (
        "src/differential_oracle_adapter_legacy.zig",
        "src/differential_oracle_corpus.zig",
    )
    if modern and source == "app" and any(Path(p).exists() for p in legacy):
        raise ValueError(
            "modern app cutover must delete differential_oracle_adapter_legacy.zig and differential_oracle_corpus.zig; doc comments do not control this check"
        )
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip()
    if not re.fullmatch("[0-9a-f]{40}", revision):
        raise ValueError("invalid build-tree Git HEAD")
    dirty = bool(
        subprocess.check_output(
            ["git", "status", "--porcelain=v1", "--untracked-files=all"]
        )
    )
    Path(output).write_text(
        "pub const revision = "
        + json.dumps(revision)
        + ";\npub const dirty = "
        + str(dirty).lower()
        + ";\n",
        encoding="utf-8",
        newline="\n",
    )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(
            "oracle identity: "
            + (
                str(error)
                if type(error) is ValueError
                else "cannot establish clean build identity"
            ),
            file=sys.stderr,
        )
        sys.exit(2)
