#!/usr/bin/env python3
"""Overlay only oracle instrumentation onto a clean, task-owned source copy.

Commit the result locally before preparing/capturing. The retained source
revision and exact root-build delta let capture distinguish instrumentation
from a changed production source. Never use this on a retained read-only tree.
"""

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def instrument_build(data, api):
    text = data.decode("utf-8").replace("\r\n", "\n")
    if api == "fork" or (api == "stone_flag" and "    const exe = if (" in text):
        anchor = "    // Standalone feasibility spike."
        addition = '    if (exe) |app| try @import("src/differential_oracle_build.zig").add(b, app.exe);\n\n'
    elif api == "v140":
        anchor = "    // All our steps which we'll hook up later."
        addition = '    try @import("src/differential_oracle_build.zig").addPublic(b, mod.vt);\n\n'
    else:
        anchor = "    const exe = try buildpkg.GhosttyExe.init(b, &config, &deps);\n"
        addition = (
            '    try @import("src/differential_oracle_build.zig").add(b, exe.exe);\n'
        )
        if text.count(anchor) != 1:
            raise ValueError("app-build anchor must occur exactly once")
        return text.replace(anchor, anchor + addition).encode()
    if text.count(anchor) != 1:
        raise ValueError("app-build anchor must occur exactly once")
    return text.replace(anchor, addition + anchor).encode()


def sources(root):
    return sorted(
        [
            p
            for p in (root / "src").glob("differential_oracle*")
            if p.suffix in (".zig", ".cpp")
        ]
        + [
            p
            for p in (root / "test/differential-oracle").iterdir()
            if p.suffix in (".py", ".md", ".zig", ".zon")
        ]
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    parser.add_argument(
        "--api",
        choices=("fork", "stone", "stone_flag", "v140", "v140_fork"),
        required=True,
    )
    args = parser.parse_args()
    repo = args.repo.resolve()
    source = Path(__file__).resolve().parents[2]

    def git(*words):
        return subprocess.check_output(["git", "-C", str(repo), *words]).strip()

    if git("status", "--porcelain=v1", "--untracked-files=all"):
        raise ValueError("stage requires a completely clean source copy")
    revision = git("rev-parse", "HEAD").decode()
    # Preserve the actual blob bytes, including its original final newline.
    before = subprocess.check_output(["git", "-C", str(repo), "show", "HEAD:build.zig"])
    after = instrument_build(before, args.api)
    overlay = sources(source)
    record_path = repo / "test/differential-oracle/staged-source.json"
    targets = [repo / path.relative_to(source) for path in overlay] + [record_path]
    if any(target.exists() or target.is_symlink() for target in targets):
        raise ValueError("oracle instrumentation already exists in source copy")
    for path in overlay:
        relative = path.relative_to(source)
        target = repo / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(path.read_bytes())
    (repo / "build.zig").write_bytes(after)
    record = {
        "production_revision": revision,
        "vt_api": args.api,
        "original_build_sha256": hashlib.sha256(before).hexdigest(),
        "instrumented_build_sha256": hashlib.sha256(after).hexdigest(),
    }
    record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        print(
            "oracle stage: source is dirty, already instrumented, or has an unsupported build shape",
            file=sys.stderr,
        )
        sys.exit(2)
