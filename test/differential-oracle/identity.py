#!/usr/bin/env python3
"""Always-run build identity and executable post-cutover file contract."""

import base64
import hashlib
import json
import os
import re
import runpy
import stat
import struct
import subprocess
import sys
from pathlib import Path


def package_digest(root, *, allow_symlinks=True):
    """Zig's SHA-256 file tree hash, without fetch/copy/filter side effects.

    Maker/Fetch hashes normalized paths, two zero bytes and regular contents;
    symlinks hash their normalized target instead. It sorts file digests by
    UTF-8 path bytes before the final SHA-256. Empty directories are ignored.
    Installed packages are already filtered; extra files deliberately fail.
    """
    root = root.resolve(strict=True)
    if os.name == "nt" and not str(root).startswith("\\\\?\\"):
        root = Path("\\\\?\\" + str(root))
    files = []
    size = 0

    def walk(directory):
        nonlocal size
        for entry in directory.iterdir():
            info = entry.lstat()
            relative = entry.relative_to(root).as_posix().encode("utf-8")
            hashed = hashlib.sha256(relative)
            if stat.S_ISLNK(info.st_mode):
                if not allow_symlinks:
                    raise ValueError("Zig lib directory contains a symbolic link")
                hashed.update(os.readlink(entry).replace("\\", "/").encode("utf-8"))
            elif (
                getattr(info, "st_file_attributes", 0)
                & stat.FILE_ATTRIBUTE_REPARSE_POINT
            ):
                raise ValueError("dependency contains an unsupported reparse point")
            elif stat.S_ISDIR(info.st_mode):
                walk(entry)
                continue
            elif stat.S_ISREG(info.st_mode):
                hashed.update(b"\0\0")
                with entry.open("rb") as source:
                    while block := source.read(1024 * 1024):
                        size += len(block)
                        hashed.update(block)
            else:
                raise ValueError("dependency contains an unsupported file type")
            files.append((relative, hashed.digest()))

    walk(root)
    digest = hashlib.sha256()
    for _, hashed in sorted(files):
        digest.update(hashed)
    return digest.digest(), min(size, 0xFFFFFFFF)


def compiler_exe_hash(zig_exe):
    executable = hashlib.sha256()
    with zig_exe.open("rb") as source:
        while block := source.read(1024 * 1024):
            executable.update(block)
    return executable.hexdigest()


def compiler_lib_hash(zig_lib):
    if not all(
        (zig_lib / path).exists() for path in ("std/std.zig", "libc/include", "compiler_rt")
    ):
        raise ValueError("incomplete Zig lib directory")
    lib_digest, _ = package_digest(zig_lib, allow_symlinks=False)
    return lib_digest.hex()


def check_packages(dependencies, source):
    checked = set()
    for expected, root in dependencies:
        root = Path(root).resolve(strict=True)
        if (expected, root) in checked:
            continue
        checked.add((expected, root))
        if re.fullmatch("1220[0-9a-f]{64}", expected):
            digest, _ = package_digest(root)
            matches = digest.hex() == expected[4:]
        elif re.fullmatch(r"[A-Za-z0-9_]+-.+-[A-Za-z0-9_-]{44}", expected):
            encoded = base64.b64decode(expected[-44:], altchars=b"-_", validate=True)
            digest, size = package_digest(root)
            matches = (
                encoded[8:] == digest[:25]
                and struct.unpack("<I", encoded[4:8])[0] == size
            )
        else:
            # Local package wrappers are part of the authenticated source tree.
            # Refuse un-hashed sources outside that tree, even in system mode.
            if not root.is_relative_to(source):
                raise ValueError(
                    "unhashed dependency outside authenticated source tree"
                )
            continue
        if not matches:
            raise ValueError(
                "resolved dependency content differs from its pinned hash; restore pristine packages"
            )


def main():
    root = Path.cwd().resolve()
    stage = runpy.run_path(str(Path(__file__).with_name("stage.py")))
    revision, dirty = stage["git_source_state"](root)
    if sys.argv[1:2] == ["--configure"]:
        print(compiler_exe_hash(Path(sys.argv[2])))
        return

    compiler_sha256, zig_lib, compiler, api, source, *arguments = sys.argv[1:]
    output = arguments.pop()
    if len(arguments) % 3 or any(
        arguments[i] != "--dependency" for i in range(0, len(arguments), 3)
    ):
        raise ValueError("invalid resolved dependency list")
    dependencies = [
        (arguments[i + 1], arguments[i + 2]) for i in range(0, len(arguments), 3)
    ]
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
    if not dependencies:
        raise ValueError("oracle requires dependencies from the resolved build graph")
    check_packages(dependencies, root)
    if not re.fullmatch("[0-9a-f]{40}", revision):
        raise ValueError("invalid build-tree Git HEAD")
    if not re.fullmatch("[0-9a-f]{64}", compiler_sha256):
        raise ValueError("invalid configured Zig executable hash")
    fields = {
        "revision": revision,
        "dirty": dirty,
        "zig_exe_sha256": compiler_sha256,
        "zig_lib_sha256": compiler_lib_hash(Path(zig_lib)),
    }
    Path(output).write_text(
        "".join(f"pub const {key} = {json.dumps(value)};\n" for key, value in fields.items()),
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
