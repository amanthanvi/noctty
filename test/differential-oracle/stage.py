#!/usr/bin/env python3
"""Overlay only oracle instrumentation onto a clean, task-owned source copy.

Commit the result locally before preparing/capturing. The retained source
revision and exact build-file deltas let capture distinguish instrumentation
from a changed production source. Never use this on a retained read-only tree.
"""

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

GIT_CONFIG = ("-c", "core.ignoreStat=false", "-c", "core.fsmonitor=false")
GIT_VERSION = "src/build/GitVersion.zig"


def git_bytes(repo, *args):
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith("GIT_")}
    return subprocess.check_output(
        ["git", *GIT_CONFIG, "-C", str(repo), *args], env=env
    )


def git_source_state(repo):
    repo = repo.resolve(strict=True)
    try:
        root = git_bytes(repo, "rev-parse", "--show-toplevel").decode().rstrip("\r\n")
    except subprocess.CalledProcessError as error:
        raise ValueError("source root must be the Git worktree top-level") from error
    if not root or Path(root).resolve(strict=True) != repo:
        raise ValueError("source root must be the Git worktree top-level")
    for entry in git_bytes(repo, "ls-files", "-v", "-z").split(b"\0"):
        tag = entry[:1]
        if tag.upper() == b"S":
            raise ValueError("source index contains skip-worktree entries")
        if tag.islower():
            raise ValueError("source index contains assume-unchanged entries")
    revision = git_bytes(repo, "rev-parse", "HEAD").decode().strip()
    dirty = bool(git_bytes(repo, "status", "--porcelain=v1", "--untracked-files=all"))
    return revision, dirty


def instrument_git_version(data):
    text = data.decode("utf-8").replace("\r\n", "\n")
    # The legacy and modern builds use the same four GitVersion commands.
    for separator, count in ((" ", 3), ("\n        ", 1)):
        anchor = separator.join(('"git",', '"-C",'))
        if text.count(anchor) != count:
            raise ValueError("unsupported source GitVersion command shape")
        options = (json.dumps(arg) + "," for arg in GIT_CONFIG)
        text = text.replace(anchor, separator.join(('"git",', *options, '"-C",')))
    return text.encode()


def instrument_build(data, api):
    text = data.decode("utf-8").replace("\r\n", "\n")
    entry = "pub fn build(b: *std.Build) !void {\n"
    if text.count(entry) != 1:
        raise ValueError("build entry must occur exactly once")
    text = text.replace(
        entry,
        entry
        + '    const oracle = try @import("src/differential_oracle_build.zig").configure(b);\n',
    )
    if api == "fork" or (api == "stone_flag" and "    const exe = if (" in text):
        anchor = "    // Standalone feasibility spike."
        addition = '    if (exe) |app| try @import("src/differential_oracle_build.zig").add(b, app.exe, oracle);\n\n'
    elif api == "v140":
        anchor = "    // All our steps which we'll hook up later."
        addition = '    try @import("src/differential_oracle_build.zig").addPublic(b, mod.vt, oracle);\n\n'
    else:
        anchor = "    const exe = try buildpkg.GhosttyExe.init(b, &config, &deps);\n"
        addition = '    try @import("src/differential_oracle_build.zig").add(b, exe.exe, oracle);\n'
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


def require_writable(target):
    if target.exists():
        # Acquire write access without changing bytes, length or timestamps.
        with target.open("r+b"):
            pass
    parent = target.parent
    while not parent.exists():
        parent = parent.parent
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        create = kernel.CreateFileW
        create.argtypes = [
            wintypes.LPCWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.HANDLE,
        ]
        create.restype = wintypes.HANDLE
        close = kernel.CloseHandle
        close.argtypes = [wintypes.HANDLE]
        close.restype = wintypes.BOOL
        # FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY; open the directory, no writes.
        handle = create(str(parent), 0x0002 | 0x0004, 7, None, 3, 0x02000000, None)
        if handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        if not close(handle):
            raise ctypes.WinError(ctypes.get_last_error())
    elif not os.access(parent, os.W_OK | os.X_OK):
        raise PermissionError("oracle instrumentation destination is not writable")


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

    revision, dirty = git_source_state(repo)
    if dirty:
        raise ValueError("stage requires a completely clean source copy")
    # Preserve the actual blob bytes, including its original final newline.
    before = git_bytes(repo, "show", "HEAD:build.zig")
    after = instrument_build(before, args.api)
    git_version = instrument_git_version(git_bytes(repo, "show", f"HEAD:{GIT_VERSION}"))
    overlay = sources(source)
    record_path = repo / "test/differential-oracle/staged-source.json"
    targets = [repo / path.relative_to(source) for path in overlay] + [record_path]
    if any(os.path.lexists(target) for target in targets):
        raise ValueError("oracle instrumentation already exists in source copy")
    build_targets = [repo / "build.zig", repo / GIT_VERSION]
    for target in [*targets, *build_targets]:
        for parent in target.parents:
            if not parent.is_relative_to(repo):
                break
            if os.path.lexists(parent) and (
                not parent.is_dir()
                or parent.is_symlink()
                or getattr(parent.lstat(), "st_file_attributes", 0)
                & stat.FILE_ATTRIBUTE_REPARSE_POINT
            ):
                raise ValueError(
                    "oracle instrumentation destination parent is obstructed"
                )
            if parent == repo:
                break
    for target in [*targets, *build_targets]:
        require_writable(target)
    contents = [
        (repo / path.relative_to(source), path.read_bytes()) for path in overlay
    ]
    for target, data in contents:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (repo / "build.zig").write_bytes(after)
    (repo / GIT_VERSION).write_bytes(git_version)
    record = {
        "production_revision": revision,
        "vt_api": args.api,
        "original_build_sha256": hashlib.sha256(before).hexdigest(),
        "instrumented_build_sha256": hashlib.sha256(after).hexdigest(),
    }
    record_path.write_text(
        json.dumps(record, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
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
