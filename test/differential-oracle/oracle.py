#!/usr/bin/env python3
"""Freeze, capture and compare PLAN.md section 3.4's headless VT oracle."""

import argparse
import base64
import collections
import hashlib
import importlib.util
import json
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass
from functools import cache
from pathlib import Path

# Loading the sibling staging helper must not dirty a captured source tree.
sys.dont_write_bytecode = True

SIZES = ((80, 24), (132, 43))
FORMATS = ("plain", "vt")
KINDS = ("bytes", "utf8", "osc-valid", "osc-invalid")
COMPILER_HASH_FIELDS = ("zig_exe_sha256", "zig_lib_sha256")
CLASSES = (
    "no change",
    "fork behaviour removed",
    "fork-owned semantics",
    "bug candidate",
)
# The VT parser shares the same handler for APC, PM and SOS. Look ahead
# without consuming a possible second introducer in an ambiguous byte stream.
KITTY_HEADERS = re.compile(
    rb"(?:\x1b[X^_]|[\x98\x9e\x9f])"
    rb"(?=[\x98\x9e\x9f]*G([^;\x18\x1a\x1b\x80-\x97\x99-\x9d]*))"
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    with path.open("x", encoding="utf-8", newline="\n") as out:
        json.dump(value, out, indent=2, sort_keys=True, ensure_ascii=True)
        out.write("\n")


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def read_json(path):
    return parse_json(path.read_bytes())


def parse_json(data):
    return json.loads(data.decode("utf-8"), object_pairs_hook=no_duplicates)


def git(repo, *args):
    return staging().git_bytes(repo, *args).decode().strip()


class Binary:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, size):
        if size < 0 or size > len(self.data) - self.pos:
            raise ValueError("truncated binary artifact")
        result = self.data[self.pos : self.pos + size]
        self.pos += size
        return result

    def unpack(self, fmt):
        return struct.unpack("<" + fmt, self.take(struct.calcsize("<" + fmt)))

    def done(self):
        if self.pos != len(self.data):
            raise ValueError("trailing binary artifact bytes")


def unescape(text):
    result = bytearray()
    pos = 0
    while pos < len(text):
        if text[pos] != "\\":
            result.extend(text[pos].encode("utf-8"))
            pos += 1
            continue
        pos += 1
        if pos == len(text):
            raise ValueError("unfinished replay escape")
        escape = text[pos]
        if escape == "x":
            pair = text[pos + 1 : pos + 3]
            if not re.fullmatch("[0-9a-fA-F]{2}", pair):
                raise ValueError("bad hex replay escape")
            result.append(int(pair, 16))
            pos += 3
        else:
            result.extend(
                {"e": b"\x1b", "r": b"\r", "n": b"\n", "t": b"\t", "\\": b"\\"}[escape]
            )
            pos += 1
    return bytes(result)


def send(data):
    return {"send": base64.b64encode(data).decode("ascii")}


def check_kitty_media(operations):
    # A write boundary or resize does not end a partially received command.
    stream = b"".join(
        base64.b64decode(op["send"], validate=True) for op in operations if "send" in op
    )
    # Ignore bytes that may be skipped in the escape or string. Dropping
    # non-delimiting C0 here can only make admission more conservative.
    stream = stream.translate(
        None,
        bytes(range(0x18)) + b"\x19\x1c\x1d\x1e\x1f\x7f" + bytes(range(0xA0, 0x100)),
    )
    for match in KITTY_HEADERS.finditer(stream):
        # In an active string these C1 introducers don't change state.
        fields = match[1].translate(None, b"\x98\x9e\x9f").split(b",")
        # The native parser also accepts numeric ASCII codes. Admit only the
        # canonical direct value or an omitted medium (which defaults to direct).
        if any(field.startswith(b"t=") and field != b"t=d" for field in fields):
            raise ValueError("non-direct Kitty graphics medium in oracle corpus")


def replay(data):
    """Keep every send and resize; expectation rows belong to the Zig tests.

    The oracle substitutes its two required initial sizes for `size`, and
    retains subsequent absolute resize dimensions and ConPTY's no-pull flag.
    This is an oracle input, not a re-evaluation of the fixture's expectations.
    """
    operations = []
    initial = None
    conpty = False
    expecting = False
    pty_allowed = False
    for raw in data.decode("utf-8").split("\n"):
        line = raw.strip(" \r")
        if not line or line.startswith("#"):
            continue
        if expecting:
            if line == "end":
                expecting = False
            elif not (raw.startswith("|") or line == "?"):
                raise ValueError("bad replay expectation")
            continue
        cmd, _, rest = line.partition(" ")
        words = [word for word in rest.split(" ") if word]
        if initial is None and cmd != "size":
            raise ValueError("replay must begin with size")
        if cmd == "size":
            if initial is not None or len(words) != 2:
                raise ValueError("bad replay initial size")
            initial = [int(x) for x in words]
        elif cmd == "pty":
            if not pty_allowed:
                raise ValueError("replay pty must immediately follow size")
            if rest != "conpty":
                raise ValueError("bad replay pty directive")
            conpty = True
        elif cmd == "send":
            operations.append(send(unescape(rest.lstrip(" "))))
        elif cmd == "seq":
            if len(words) not in (3, 4):
                raise ValueError("bad replay seq")
            prefix = unescape(words[0])
            suffix = unescape(words[3]) if len(words) == 4 else b""
            first, last = map(int, words[1:3])
            if not 0 <= first <= last <= 65535:
                raise ValueError("bad replay seq range")
            operations.append(
                send(
                    b"".join(
                        prefix + str(n).encode() + suffix + b"\r\n"
                        for n in range(first, last + 1)
                    )
                )
            )
        elif cmd == "resize":
            if len(words) != 2:
                raise ValueError("bad replay resize")
            operations.append({"resize": [int(x) for x in words]})
        elif cmd == "expect":
            expecting = True
        elif cmd == "cursor":
            if len(words) < 2:
                raise ValueError("bad replay cursor")
        else:
            raise ValueError("unknown replay command")
        pty_allowed = cmd == "size"
    if initial is None or expecting:
        raise ValueError("unfinished replay")
    return operations, conpty, initial


def prepare(args):
    repo = args.repo.resolve()
    provenance = source_provenance(repo)
    revision = provenance["instrumented_revision"]
    args.out.mkdir(parents=True, exist_ok=False)

    def paths_at(pattern):
        return (
            staging().git_bytes(
                repo, "ls-tree", "-r", "--name-only", "-z", revision, "--", pattern
            )
            .decode("utf-8")
            .split("\0")
        )

    paths = paths_at("test/fuzz-libghostty/corpus")
    paths = sorted(
        path for path in paths if path and not path.endswith("/sanitize-filenames.sh")
    )
    if len(paths) != args.expect_fuzz:
        raise ValueError("fuzz seed count differs from the declared corpus")
    cases = []

    def add(name, data, operations, **facts):
        check_kitty_media(operations)
        cases.append(
            {
                "id": name,
                "source_sha256": digest(data),
                "operations": operations,
                **facts,
            }
        )

    for path in paths:
        data = staging().git_bytes(repo, "show", revision + ":" + path)
        # Feed the whole stored file: do not strip the stream fuzzer's mode
        # selector or interpret parser/OSC corpus bytes through a fuzzer ABI.
        add(
            path.removeprefix("test/fuzz-libghostty/corpus/"),
            data,
            [send(data)],
            group="fuzz",
            source=path,
        )
    generated = Binary(args.synthetic.read_bytes())
    if generated.take(4) != b"OSC1" or generated.unpack("I")[0] != 12:
        raise ValueError("bad synthetic corpus header")
    identities = set()
    for _ in range(12):
        seed, kind, length = generated.unpack("QBI")
        if (
            kind >= len(KINDS)
            or seed not in (0, 1, 0xC0FFEEEEEEEEEEEE)
            or (seed, kind) in identities
        ):
            raise ValueError("bad synthetic corpus identity")
        identities.add((seed, kind))
        data = generated.take(length)
        add(
            f"synthetic/{KINDS[kind]}-{seed:016x}",
            data,
            [send(data)],
            group="synthetic",
            seed=f"{seed:016x}",
            generator=KINDS[kind],
        )
    generated.done()
    fixtures = [
        repo / p for p in paths_at("src/terminal/testdata/replay") if p.endswith(".vt")
    ]
    if not fixtures:
        raise ValueError("no replay fixtures")
    for path in fixtures:
        data = staging().git_bytes(
            repo, "show", revision + ":" + path.relative_to(repo).as_posix()
        )
        operations, conpty, initial = replay(data)
        add(
            "replay/" + path.stem,
            data,
            operations,
            group="replay",
            conpty=conpty,
            fixture_initial_size=initial,
            source=path.relative_to(repo).as_posix(),
        )
    corpus = {
        "schema": 1,
        "source_revision": provenance["production_revision"],
        "sizes": SIZES,
        "cases": cases,
    }
    write_json(args.out / "corpus.json", corpus)
    print(
        json.dumps(
            {
                "cases": len(cases),
                "groups": dict(collections.Counter(c["group"] for c in cases)),
                "corpus_sha256": digest((args.out / "corpus.json").read_bytes()),
            },
            sort_keys=True,
        )
    )


def requests(corpus):
    if (
        corpus["schema"] != 1
        or corpus["sizes"] != [list(s) for s in SIZES]
        or not corpus["cases"]
    ):
        raise ValueError("unsupported or empty corpus")
    records = []
    seen = set()
    for case in corpus["cases"]:
        if case["id"] in seen:
            raise ValueError("duplicate corpus identity")
        seen.add(case["id"])
        check_kitty_media(case["operations"])
        operations = bytearray()
        for op in case["operations"]:
            if set(op) == {"send"}:
                data = base64.b64decode(op["send"], validate=True)
                operations.extend(struct.pack("<BI", 0, len(data)) + data)
            elif set(op) == {"resize"}:
                cols, rows = op["resize"]
                if not 1 <= cols <= 65535 or not 1 <= rows <= 65535:
                    raise ValueError("invalid resize dimensions")
                operations.extend(struct.pack("<BHH", 1, cols, rows))
            else:
                raise ValueError("unknown corpus operation")
        for cols, rows in SIZES:
            record = (
                struct.pack(
                    "<HHBI",
                    cols,
                    rows,
                    int(case.get("conpty", False)),
                    len(case["operations"]),
                )
                + operations
            )
            records.append((case["id"], cols, rows, bytes(record)))
    packet = b"ORQ1" + struct.pack("<I", len(records)) + b"".join(r[3] for r in records)
    return packet, records


def capture(args):
    corpus_bytes = args.corpus.read_bytes()
    corpus = parse_json(corpus_bytes)
    packet, records = requests(corpus)
    source = args.source_root.resolve()
    provenance = source_provenance(source)
    revision = provenance["production_revision"]
    harness = harness_sources(source)
    if harness != harness_sources():
        raise ValueError("capture source harness differs from the running harness")
    exe = args.exe.resolve()
    exe_hash = digest(exe.read_bytes())
    args.out.mkdir(parents=True, exist_ok=False)
    args.work.mkdir(parents=True, exist_ok=False)
    (args.out / "corpus.json").write_bytes(corpus_bytes)
    baseline = None
    for repeat in (1, 2):
        work = args.work / f"run-{repeat}"
        work.mkdir()
        (work / "request.bin").write_bytes(packet)
        # Keep diagnostics as an artifact; never echo parser-controlled text.
        with (
            (work / "stderr.bin").open("xb") as err,
            (work / "stdout.bin").open("xb") as out,
        ):
            proc = subprocess.run(
                [str(exe)],
                cwd=work,
                stdout=out,
                stderr=err,
                timeout=args.timeout,
                check=False,
            )
        if proc.returncode != 0:
            raise ValueError(
                f"oracle run {repeat} failed with exit {proc.returncode}; diagnostics retained"
            )
        response = Binary((work / "response.bin").read_bytes())
        if response.take(4) != b"ORS3":
            raise ValueError("unsupported oracle response")
        header = json.loads(
            response.take(response.unpack("I")[0]), object_pairs_hook=no_duplicates
        )
        profile = header["profile"]
        identity = header["build_identity"]
        validate_build_identity(identity, provenance, profile)
        if (
            source_provenance(source) != provenance
            or harness_sources(source) != harness
            or digest(exe.read_bytes()) != exe_hash
        ):
            raise ValueError("source or executable changed during capture")
        if response.unpack("I")[0] != len(records):
            raise ValueError("bad oracle response count")
        dest = args.out / f"run-{repeat}"
        dest.mkdir()
        (dest / "corpus.json").write_bytes(corpus_bytes)
        items = []
        for index, (name, cols, rows, _) in enumerate(records):
            if response.unpack("I")[0] != index:
                raise ValueError("bad oracle response order")
            for fmt in FORMATS:
                data = response.take(response.unpack("Q")[0])
                leaf = f"{index:05d}-{cols}x{rows}.{fmt}"
                (dest / leaf).write_bytes(data)
                items.append(
                    {
                        "input": name,
                        "cols": cols,
                        "rows": rows,
                        "format": fmt,
                        "file": leaf,
                        "bytes": len(data),
                        "sha256": digest(data),
                    }
                )
        response.done()
        manifest = {
            "schema": 3,
            "revision": revision,
            "provenance": provenance,
            "harness_sources": harness,
            "profile": profile,
            "build_identity": identity,
            "shipped_profile": shipped_profile(profile, identity),
            "corpus_sha256": digest(corpus_bytes),
            "request_sha256": digest(packet),
            "exe_sha256": exe_hash,
            "items": items,
        }
        write_json(dest / "manifest.json", manifest)
        if baseline is not None:
            # Require actual bytes, not just hashes, to match all saved files.
            for item in items:
                if (baseline / item["file"]).read_bytes() != (
                    dest / item["file"]
                ).read_bytes():
                    raise ValueError("nondeterministic oracle output")
            if (baseline / "manifest.json").read_bytes() != (
                dest / "manifest.json"
            ).read_bytes():
                raise ValueError("nondeterministic manifest")
        baseline = dest
    result = {
        "deterministic": True,
        "revision": revision,
        "inputs": len(corpus["cases"]),
        "items_per_run": len(items),
        "dump_bytes_per_run": sum(i["bytes"] for i in items),
        "corpus_sha256": digest(corpus_bytes),
        "manifest_sha256": digest((baseline / "manifest.json").read_bytes()),
    }
    write_json(args.out / "determinism.json", result)
    complete_capture(args.out)
    print(json.dumps(result, sort_keys=True))


@dataclass(frozen=True)
class LoadedRun:
    manifest: dict
    items: dict
    manifest_sha256: str
    corpus_source_revision: str


@dataclass(frozen=True)
class LoadedSet:
    manifest: dict
    items: dict
    manifest_sha256s: dict
    completion_sha256: str
    corpus_source_revision: str


def load_run(root):
    manifest_bytes = (root / "manifest.json").read_bytes()
    manifest = parse_json(manifest_bytes)
    if manifest["schema"] != 3 or not manifest["items"]:
        raise ValueError("unsupported or empty dump set")
    if not re.fullmatch("[0-9a-f]{40}", manifest["revision"]) or not re.fullmatch(
        "[0-9a-f]{64}", manifest["exe_sha256"]
    ):
        raise ValueError("invalid revision/executable provenance")
    provenance = manifest["provenance"]
    if provenance["production_revision"] != manifest["revision"] or not re.fullmatch(
        "[0-9a-f]{40}", provenance["instrumented_revision"]
    ):
        raise ValueError("inconsistent source provenance")
    validate_profile(manifest["profile"])
    validate_build_identity(manifest["build_identity"], provenance, manifest["profile"])
    if manifest["shipped_profile"] != shipped_profile(
        manifest["profile"], manifest["build_identity"]
    ):
        raise ValueError("shipped profile assessment is stale")
    if not manifest["harness_sources"] or any(
        not re.fullmatch("[0-9a-f]{64}", h)
        for h in manifest["harness_sources"].values()
    ):
        raise ValueError("invalid harness provenance")
    corpus_bytes = (root / "corpus.json").read_bytes()
    corpus = parse_json(corpus_bytes)
    if not re.fullmatch("[0-9a-f]{40}", corpus["source_revision"]):
        raise ValueError("invalid corpus source revision")
    packet, _ = requests(corpus)
    if (
        digest(corpus_bytes) != manifest["corpus_sha256"]
        or digest(packet) != manifest["request_sha256"]
    ):
        raise ValueError("dump set does not match its frozen corpus/request")
    items = {}
    files = set()
    for item in manifest["items"]:
        key = (item["input"], item["cols"], item["rows"], item["format"])
        leaf = item["file"]
        if (
            key in items
            or leaf in files
            or Path(leaf).name != leaf
            or "/" in leaf
            or "\\" in leaf
            or leaf in (".", "..")
        ):
            raise ValueError("duplicate or unsafe dump item")
        if key[1:3] not in SIZES or key[3] not in FORMATS:
            raise ValueError("unsupported dump item")
        data = (root / leaf).read_bytes()
        if len(data) != item["bytes"] or digest(data) != item["sha256"]:
            raise ValueError("dump content does not match its manifest")
        items[key] = data
        files.add(leaf)
    names = {case["id"] for case in corpus["cases"]}
    expected = {
        (name, cols, rows, fmt)
        for name in names
        for cols, rows in SIZES
        for fmt in FORMATS
    }
    if set(items) != expected:
        raise ValueError("incomplete input/size/format coverage")
    if {p.name for p in root.iterdir()} != files | {"manifest.json", "corpus.json"}:
        raise ValueError("unmanifested dump files")
    return LoadedRun(manifest, items, digest(manifest_bytes), corpus["source_revision"])


def harness_sources(repo=None):
    repo = repo or Path(__file__).resolve().parents[2]
    return {
        p.relative_to(repo).as_posix(): digest(p.read_bytes())
        for p in staging().sources(repo)
        if p.suffix != ".md"
    }


@cache
def staging():
    spec = importlib.util.spec_from_file_location(
        "oracle_stage", Path(__file__).with_name("stage.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_provenance(repo):
    stage = staging()
    head, dirty = stage.git_source_state(repo)
    if dirty:
        raise ValueError("source tree must be completely clean")
    record = repo / "test/differential-oracle/staged-source.json"
    if not record.exists():
        return {"production_revision": head, "instrumented_revision": head}
    staged = read_json(record)
    production = staged["production_revision"]
    original = stage.git_bytes(repo, "show", production + ":build.zig")
    after = stage.instrument_build(original, staged["vt_api"])
    if (
        digest(original) != staged["original_build_sha256"]
        or digest(after) != staged["instrumented_build_sha256"]
        or after != (repo / "build.zig").read_bytes()
    ):
        raise ValueError("source instrumentation build delta differs")
    git_version = stage.git_bytes(repo, "show", f"{production}:{stage.GIT_VERSION}")
    if stage.instrument_git_version(git_version) != (
        repo / stage.GIT_VERSION
    ).read_bytes():
        raise ValueError("source instrumentation GitVersion delta differs")
    allowed = {p.relative_to(repo).as_posix() for p in stage.sources(repo)} | {
        "build.zig",
        stage.GIT_VERSION,
        "test/differential-oracle/staged-source.json",
    }
    changed = set(
        git(repo, "diff", "--no-renames", "--name-only", production, head).splitlines()
    )
    if not changed <= allowed:
        raise ValueError(
            "source contains production changes beyond oracle instrumentation"
        )
    return {**staged, "instrumented_revision": head}


def validate_profile(profile):
    if (
        not isinstance(profile, dict)
        or not {"target", "cpu_model", "cpu_features", "optimize", "terminal_options"}
        <= profile.keys()
    ):
        raise ValueError("invalid build profile")
    options = profile["terminal_options"]
    if (
        not isinstance(options, dict)
        or not {
            "artifact",
            "simd",
            "oniguruma",
            "c_abi",
            "slow_runtime_safety",
            "kitty_graphics",
            "tmux_control_mode",
        }
        <= options.keys()
    ):
        raise ValueError("incomplete Terminal profile")
    if options["artifact"] not in ("ghostty", "lib") or any(
        type(options[k]) is not bool
        for k in (
            "simd",
            "oniguruma",
            "c_abi",
            "slow_runtime_safety",
            "kitty_graphics",
            "tmux_control_mode",
        )
    ):
        raise ValueError("invalid Terminal profile values")
    if (
        any(
            not isinstance(profile[k], str) or not profile[k]
            for k in ("target", "cpu_model", "optimize")
        )
        or not isinstance(profile["cpu_features"], list)
        or any(not isinstance(f, str) for f in profile["cpu_features"])
    ):
        raise ValueError("invalid target/CPU/optimization profile")
    if (
        not isinstance(profile["compiler_version"], str)
        or not profile["compiler_version"]
        or not isinstance(profile["runtime_simd"], dict)
        or set(profile["runtime_simd"]) != {"highway", "simdutf"}
        or any(
            not isinstance(v, str) or not v for v in profile["runtime_simd"].values()
        )
    ):
        raise ValueError("invalid compiler/runtime SIMD profile")
    if (
        type(profile["scrollback_bytes"]) is not int
        or profile["scrollback_bytes"] < 0
        or not isinstance(profile["baseline_cpu_model"], str)
        or not isinstance(profile["baseline_cpu_features"], list)
    ):
        raise ValueError("invalid baseline CPU/scrollback profile")


def validate_build_identity(identity, provenance, profile):
    validate_profile(profile)
    if not isinstance(identity, dict) or any(
        not isinstance(identity.get(key), str)
        or not re.fullmatch("[0-9a-f]{64}", identity[key])
        for key in COMPILER_HASH_FIELDS
    ):
        raise ValueError("missing or invalid Zig compiler content identity")
    if (
        identity["dirty"] is not False
        or identity["revision"] != provenance["instrumented_revision"]
    ):
        raise ValueError("executable build HEAD/clean state does not match source-root")
    api = identity["vt_api"]
    if api not in ("fork", "stone", "stone_flag", "v140", "v140_fork") or (
        "vt_api" in provenance and provenance["vt_api"] != api
    ):
        raise ValueError("executable API shape does not match source provenance")
    if profile["conpty_no_pull_supported"] is not (api != "stone"):
        raise ValueError("executable ConPTY policy does not match its API shape")
    if identity["terminal_source"] not in ("app", "public-lib-vt") or profile[
        "terminal_options"
    ]["artifact"] != ("ghostty" if identity["terminal_source"] == "app" else "lib"):
        raise ValueError("executable Terminal source does not match its profile")


def shipped_profile(profile, identity):
    expected_options = {
        k: True
        for k, v in profile["terminal_options"].items()
        if type(v) is bool and not k.startswith("version_")
    }
    expected_options.update(
        artifact="ghostty",
        c_abi=False,
        slow_runtime_safety=False,
        simd=True,
        oniguruma=True,
        kitty_graphics=True,
        tmux_control_mode=True,
    )
    expected = {
        "target": profile["target"].split("-")[0] + "-windows-msvc",
        "optimize": "ReleaseFast",
        "cpu_model": profile["baseline_cpu_model"],
        "cpu_features": profile["baseline_cpu_features"],
        "scrollback_bytes": 10_000_000,
        "conpty_no_pull_supported": True,
        "terminal_options": expected_options,
    }
    actual = profile_options(profile)
    differences = []
    for option, value in sorted(profile_options(expected).items()):
        old = {"present": True, "value": value}
        new = {"present": option in actual}
        if option in actual:
            new["value"] = actual[option]
        if canonical(old) != canonical(new):
            differences.append({"option": option, "old": old, "new": new})
    return {
        "applicable": identity["terminal_source"] == "app",
        "matches": not differences,
        "differences": differences,
    }


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def complete_capture(parent):
    first = load_run(parent / "run-1")
    second = load_run(parent / "run-2")
    if first.manifest != second.manifest or first.items != second.items:
        raise ValueError("cannot complete a nondeterministic capture")
    hashes = {
        "run-1": first.manifest_sha256,
        "run-2": second.manifest_sha256,
    }
    if len(set(hashes.values())) != 1:
        raise ValueError("cannot complete byte-different manifests")
    write_json(
        parent / "completion.json",
        {
            "schema": 2,
            "deterministic": True,
            "manifest_sha256": first.manifest_sha256,
            "manifest_sha256s": hashes,
            **{
                k: first.manifest[k]
                for k in (
                    "corpus_sha256",
                    "profile",
                    "harness_sources",
                    "provenance",
                    "exe_sha256",
                    "build_identity",
                    "shipped_profile",
                )
            },
        },
    )


def load_set(root, declarations=(), used=None):
    root = root.resolve()
    if root.name not in ("run-1", "run-2"):
        raise ValueError("dump set must name a completed capture run")
    completion_bytes = (root.parent / "completion.json").read_bytes()
    record = parse_json(completion_bytes)
    if record.get("schema") != 2 or record.get("deterministic") is not True:
        raise ValueError("invalid completion record")
    first_run = load_run(root.parent / "run-1")
    second_run = load_run(root.parent / "run-2")
    first, items = first_run.manifest, first_run.items
    if first != second_run.manifest or items != second_run.items:
        raise ValueError("completed capture is no longer deterministic")
    if record["manifest_sha256"] != first_run.manifest_sha256 or any(
        record[k] != first[k]
        for k in (
            "corpus_sha256",
            "profile",
            "harness_sources",
            "provenance",
            "exe_sha256",
        )
    ):
        raise ValueError("completion record does not bind this capture")
    hashes = {
        "run-1": first_run.manifest_sha256,
        "run-2": second_run.manifest_sha256,
    }
    if (
        record["manifest_sha256s"] != hashes
        or len(set(hashes.values())) != 1
        or record["build_identity"] != first["build_identity"]
        or record["shipped_profile"] != first["shipped_profile"]
    ):
        raise ValueError(
            "completion does not bind both manifest byte streams and assessments"
        )
    current = digest(json.dumps(harness_sources(), sort_keys=True).encode())
    captured = digest(json.dumps(first["harness_sources"], sort_keys=True).encode())
    if current != captured and f"{captured}:{current}" not in declarations:
        raise ValueError(
            "harness changed; explicit --declare-harness-change OLD:CURRENT required"
        )
    if current != captured and used is not None:
        used.add(f"{captured}:{current}")
    return LoadedSet(
        first, items, hashes, digest(completion_bytes), first_run.corpus_source_revision
    )


def classify(pre, branch, upstream):
    if branch == upstream == pre:
        return CLASSES[0]
    if branch == upstream:
        return CLASSES[1]
    if branch == pre:
        return CLASSES[2]
    return CLASSES[3]


def native_corpus(revision):
    cases = [
        {"id": name, "source_sha256": digest(data), "operations": [send(data)]}
        for name, data in (
            ("text", b"oracle-control"),
            ("sgr", b"\x1b[31moracle-control\x1b[0m"),
            ("reset", b"discarded\x1bcoracle-control"),
        )
    ]
    cases.append(
        {"id": "resize", "operations": [send(b"0123456789" * 6), {"resize": [20, 24]}]}
    )
    for conpty in (False, True):
        cases.append(
            {
                "id": "conpty-on" if conpty else "conpty-off",
                "conpty": conpty,
                "operations": [
                    {"resize": [80, 4]},
                    send(
                        b"".join(b"L" + str(n).encode() + b"\r\n" for n in range(1, 9))
                        + b"prompt"
                    ),
                    {"resize": [80, 6]},
                    send(b"\x1b[4;7HX"),
                ],
            }
        )
    return {
        "schema": 1,
        "source_revision": revision,
        "sizes": [list(s) for s in SIZES],
        "cases": cases,
    }


def native_plain(name, flag_supported):
    if name == "resize":
        return b"\n".join([b"0123456789" * 2] * 3)
    if name.startswith("conpty-"):
        if name == "conpty-on" and flag_supported:
            return b"L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\npromptX"
        return b"L1\nL2\nL3\nL4\nL5\nL6\nL7    X\nL8\nprompt"
    return b"oracle-control"


def native_controls(args):
    used = set()
    capture = load_set(args.dumps, args.declare_harness_change, used)
    items = capture.items
    validate_harness_declarations(args.declare_harness_change, used)
    canonical_request = requests(native_corpus(capture.corpus_source_revision))[0]
    if capture.manifest["request_sha256"] != digest(canonical_request):
        raise ValueError(
            "native controls require the canonical resize/no-pull requests"
        )
    names = {"text", "sgr", "reset", "resize", "conpty-on", "conpty-off"}
    if {key[0] for key in items} != names:
        raise ValueError("native controls require the six sentinel inputs")
    checks = []
    for cols, rows in SIZES:
        for name in sorted(names):
            if items[(name, cols, rows, "plain")] != native_plain(
                name, capture.manifest["profile"]["conpty_no_pull_supported"]
            ):
                raise ValueError("native text/SGR/reset control failed")
            checks.append(f"{name} plain {cols}x{rows}")
        text = items[("text", cols, rows, "vt")]
        if (
            text != items[("reset", cols, rows, "vt")]
            or text == items[("sgr", cols, rows, "vt")]
        ):
            raise ValueError("native VT reset/style control failed")
        if b"oracle-control" not in text or b"\x1b" not in text:
            raise ValueError("native VT formatter control failed")
        checks.append(f"VT reset/style {cols}x{rows}")
    write_json(
        args.report,
        {"passed": len(checks), "checks": checks, "harness_declarations": sorted(used)},
    )
    print(json.dumps({"native_controls_passed": len(checks)}))


def compare(
    pre_root,
    branch_root,
    upstream_root=None,
    triage=None,
    declarations=(),
    expected_corpus=None,
    profile_declarations=None,
    shipped_declarations=None,
):
    if not isinstance(expected_corpus, str) or not re.fullmatch(
        "[0-9a-f]{64}", expected_corpus
    ):
        raise ValueError("--expected-corpus must be a nonempty SHA-256 hash")
    used = set()
    sets = [
        load_set(root, declarations, used)
        for root in (pre_root, branch_root, upstream_root)
        if root is not None
    ]
    validate_harness_declarations(declarations, used)
    if sets[0].manifest["revision"] == sets[1].manifest["revision"]:
        raise ValueError(
            "pre and post captures must have distinct production revisions"
        )
    for index, capture in enumerate(sets):
        manifest = capture.manifest
        for other_capture in sets[:index]:
            other = other_capture.manifest
            if manifest["exe_sha256"] == other["exe_sha256"] and (
                manifest["revision"],
                manifest["provenance"]["instrumented_revision"],
            ) != (other["revision"], other["provenance"]["instrumented_revision"]):
                raise ValueError(
                    "one executable hash is attributed to different source revisions"
                )
    if (
        len({s.manifest["corpus_sha256"] for s in sets}) != 1
        or len({s.manifest["request_sha256"] for s in sets}) != 1
    ):
        raise ValueError("compared corpus/request identities differ")
    if (
        expected_corpus is not None
        and sets[0].manifest["corpus_sha256"] != expected_corpus
    ):
        raise ValueError("corpus differs from the operator pin")
    manifests = {
        side: s.manifest for side, s in zip(("pre", "branch", "upstream"), sets)
    }
    profiles = {side: m["profile"] for side, m in manifests.items()}
    declared_profiles = validate_profile_declarations(
        {
            side: {
                **m["profile"],
                "build_identity": {
                    key: m["build_identity"][key] for key in COMPILER_HASH_FIELDS
                },
            }
            for side, m in manifests.items()
        },
        profile_declarations,
    )
    shipping_differences = {
        (side, d["option"]): {"side": side, **d}
        for side, s in zip(("pre", "branch", "upstream"), sets)
        for m in (s.manifest,)
        if side in ("pre", "branch") or m["build_identity"]["terminal_source"] == "app"
        for d in m["shipped_profile"]["differences"]
    }
    declared_shipping = validate_option_declarations(
        shipping_differences, shipped_declarations, "--declare-shipped-mismatches"
    )
    if (
        any(
            s.manifest["harness_sources"] != sets[0].manifest["harness_sources"]
            for s in sets[1:]
        )
        and not declarations
    ):
        raise ValueError("compared harness sources differ")
    if any(set(s.items) != set(sets[0].items) for s in sets[1:]):
        raise ValueError("compared dump coverage differs")
    triaged = {}
    if triage is not None and not isinstance(triage, list):
        raise ValueError("triage must be a list")
    for row in triage or []:
        if (
            not isinstance(row, dict)
            or not isinstance(row.get("reason"), str)
            or ("ledger" in row and not isinstance(row["ledger"], str))
        ):
            raise ValueError("invalid triage row types")
        key = (row["input"], row["cols"], row["rows"], row["format"])
        if key in triaged or not row.get("reason", "").strip():
            raise ValueError("duplicate or unexplained triage")
        triaged[key] = row
    differences = []
    counts = collections.Counter()
    for key in sorted(sets[0].items):
        values = [s.items[key] for s in sets]
        category = (
            classify(*values)
            if len(values) == 3
            else ("no change" if values[0] == values[1] else "different")
        )
        counts[category] += 1
        if category == "no change":
            continue
        row = dict(zip(("input", "cols", "rows", "format"), key))
        row.update(
            classification=category,
            sha256=[digest(value) for value in values],
            triaged=False,
        )
        if key in triaged:
            entry = triaged.pop(key)
            if (
                entry["classification"] != category
                or entry.get("sha256") != row["sha256"]
            ):
                raise ValueError("triage classification or bytes are stale")
            if (category in CLASSES[1:3] or category == "different") and not entry.get(
                "ledger", ""
            ).strip():
                raise ValueError("fork difference requires a ledger entry")
            row.update(triaged=True, reason=entry["reason"], ledger=entry.get("ledger"))
        differences.append(row)
    if triaged:
        raise ValueError("triage names an absent or unchanged item")
    return {
        "corpus_sha256": sets[0].manifest["corpus_sha256"],
        "expected_corpus": expected_corpus,
        "profiles": profiles,
        "profile_declarations": declared_profiles,
        "shipped_profile_declarations": declared_shipping,
        "harness_declarations": sorted(used),
        "sides": {
            side: {
                "revision": m["revision"],
                "corpus_source_revision": s.corpus_source_revision,
                "harness_sources_sha256": digest(
                    json.dumps(m["harness_sources"], sort_keys=True).encode()
                ),
                "provenance": m["provenance"],
                "build_identity": m["build_identity"],
                "exe_sha256": m["exe_sha256"],
                "manifest_sha256s": s.manifest_sha256s,
                "completion_sha256": s.completion_sha256,
                "shipped_profile": m["shipped_profile"],
            }
            for side, s in zip(("pre", "branch", "upstream"), sets)
            for m in (s.manifest,)
        },
        "counts": dict(sorted(counts.items())),
        "items": len(sets[0].items),
        "differences": differences,
        "untriaged": sum(not r["triaged"] for r in differences),
    }


def profile_options(profile, prefix=""):
    result = {}
    for key, value in profile.items():
        if not isinstance(key, str) or not key or "." in key:
            raise ValueError("invalid profile option name")
        name = prefix + key
        if isinstance(value, dict) and value:
            result.update(profile_options(value, name + "."))
        else:
            result[name] = value
    return result


def validate_profile_declarations(profiles, declarations):
    pre = profile_options(profiles["pre"])
    differing = {}
    for side, profile in profiles.items():
        if side == "pre":
            continue
        options = profile_options(profile)
        for name in sorted(pre.keys() | options.keys()):
            before = {"present": name in pre}
            after = {"present": name in options}
            if name in pre:
                before["value"] = pre[name]
            if name in options:
                after["value"] = options[name]
            if canonical(before) != canonical(after):
                differing[(side, name)] = {
                    "side": side,
                    "option": name,
                    "old": before,
                    "new": after,
                }
    return validate_option_declarations(
        differing, declarations, "--declare-profile-differences"
    )


def validate_option_declarations(differing, declarations, option):
    if declarations is None:
        declarations = []
    if not isinstance(declarations, list):
        raise TypeError(f"{option}: declarations must be a list")
    accepted = {}
    for row in declarations:
        if (
            not isinstance(row, dict)
            or set(row) != {"side", "option", "reason", "old", "new"}
            or any(
                not isinstance(row[k], str) or not row[k].strip()
                for k in ("side", "option", "reason")
            )
        ):
            raise ValueError(f"{option}: invalid declaration")
        key = row["side"], row["option"]
        if key not in differing or key in accepted:
            raise ValueError(
                f"{option}: declaration names an unchanged, absent or duplicate option"
            )
        if canonical(row["old"]) != canonical(differing[key]["old"]) or canonical(
            row["new"]
        ) != canonical(differing[key]["new"]):
            raise ValueError(f"{option}: values are stale or have the wrong direction")
        accepted[key] = {**differing[key], "reason": row["reason"]}
    if set(accepted) != set(differing):
        raise ValueError(
            f"{option}: an exact declaration is required for every differing option"
        )
    return [accepted[key] for key in sorted(accepted)]


def validate_harness_declarations(declarations, used):
    if (
        len(set(declarations)) != len(declarations)
        or any(
            not isinstance(d, str) or not re.fullmatch("[0-9a-f]{64}:[0-9a-f]{64}", d)
            for d in declarations
        )
        or set(declarations) != used
    ):
        raise ValueError("unused, duplicate or malformed harness declaration")


def control_profile():
    return {
        "target": "x86_64-windows-msvc",
        "cpu_model": "x86_64",
        "cpu_features": [],
        "baseline_cpu_model": "x86_64",
        "baseline_cpu_features": [],
        "optimize": "ReleaseFast",
        "compiler_version": "0.17.1",
        "runtime_simd": {"highway": "control", "simdutf": "control"},
        "scrollback_bytes": 10_000_000,
        "conpty_no_pull_supported": True,
        "terminal_options": {
            "artifact": "ghostty",
            "simd": True,
            "oniguruma": True,
            "c_abi": False,
            "slow_runtime_safety": False,
            "kitty_graphics": True,
            "tmux_control_mode": True,
        },
    }


def controls(args):
    args.out.mkdir(parents=True, exist_ok=False)

    def check(condition):
        if not condition:
            raise ValueError("oracle positive control failed")

    # All five partitions of equality, including pre=upstream != branch.
    triples = (
        (b"a", b"a", b"a"),
        (b"a", b"b", b"b"),
        (b"a", b"a", b"b"),
        (b"a", b"b", b"c"),
        (b"a", b"b", b"a"),
    )
    roots = [args.out / side / "run-1" for side in ("pre", "branch", "upstream")]
    corpus = {
        "schema": 1,
        "source_revision": "0" * 40,
        "sizes": SIZES,
        "cases": [
            {"id": str(n), "operations": [send(b"control")]}
            for n in range(len(triples))
        ],
    }
    for side, root in enumerate(roots):
        root.mkdir(parents=True)
        write_json(root / "corpus.json", corpus)
        items = []
        for number, triple in enumerate(triples):
            for cols, rows in SIZES:
                for fmt in FORMATS:
                    data = triple[side]
                    leaf = f"{number}-{cols}x{rows}.{fmt}"
                    (root / leaf).write_bytes(data)
                    items.append(
                        {
                            "input": str(number),
                            "cols": cols,
                            "rows": rows,
                            "format": fmt,
                            "file": leaf,
                            "bytes": len(data),
                            "sha256": digest(data),
                        }
                    )
        identity = {
            "revision": str(side) * 40,
            "dirty": False,
            "vt_api": "v140_fork",
            "terminal_source": "app",
            "zig_exe_sha256": "a" * 64,
            "zig_lib_sha256": "b" * 64,
        }
        profile = control_profile()
        write_json(
            root / "manifest.json",
            {
                "schema": 3,
                "revision": str(side) * 40,
                "exe_sha256": str(side + 1) * 64,
                "provenance": {
                    "production_revision": str(side) * 40,
                    "instrumented_revision": str(side) * 40,
                },
                "build_identity": identity,
                "profile": profile,
                "shipped_profile": shipped_profile(profile, identity),
                "harness_sources": harness_sources(),
                "corpus_sha256": digest((root / "corpus.json").read_bytes()),
                "request_sha256": digest(requests(read_json(root / "corpus.json"))[0]),
                "items": items,
            },
        )
        shutil.copytree(root, root.parent / "run-2")
        complete_capture(root.parent)
    pin = read_json(roots[0] / "manifest.json")["corpus_sha256"]

    def comp(*paths, **options):
        options.setdefault("expected_corpus", pin)
        return compare(*paths, **options)

    def mirror_pre():
        # Equal bytes/profile, but an independently identified production build.
        twin = args.out / "pre-twin"
        shutil.copytree(roots[0].parent, twin, dirs_exist_ok=True)
        for run in ("run-1", "run-2"):
            path = twin / run / "manifest.json"
            value = read_json(path)
            value["revision"] = "e" * 40
            value["exe_sha256"] = "e" * 64
            value["build_identity"]["revision"] = "e" * 40
            value["provenance"].update(
                production_revision="e" * 40, instrumented_revision="e" * 40
            )
            path.write_text(json.dumps(value), encoding="utf-8")
        (twin / "completion.json").unlink()
        complete_capture(twin)
        return twin / "run-1"

    result = comp(*roots)
    check(
        result["counts"]
        == {
            CLASSES[0]: 4,
            CLASSES[1]: 4,
            CLASSES[2]: 4,
            CLASSES[3]: 8,
        }
    )
    check(result["untriaged"] == 16 and len(result["differences"]) == 16)
    expected_classes = (
        "no change",
        "fork behaviour removed",
        "fork-owned semantics",
        "bug candidate",
        "bug candidate",
    )
    expected_items = {
        (str(n), cols, rows, fmt): category
        for n, category in enumerate(expected_classes)
        for cols, rows in SIZES
        for fmt in FORMATS
    }
    actual_items = dict.fromkeys(expected_items, "no change")
    for row in result["differences"]:
        actual_items[(row["input"], row["cols"], row["rows"], row["format"])] = row[
            "classification"
        ]
    check(actual_items == expected_items)
    triage = [
        dict(row, reason="synthetic control", ledger="control ledger row")
        for row in result["differences"]
    ]
    check(comp(*roots, triage=triage)["untriaged"] == 0)
    check(comp(roots[0], mirror_pre())["untriaged"] == 0)
    check(comp(roots[0], roots[1])["counts"] == {"no change": 8, "different": 12})
    checks = [
        "five equality partitions",
        "every item has its expected class label",
        "complete three-way listing",
        "hash-bound triage",
        "pair identical bytes under distinct revisions",
        "pair differences",
    ]

    def rejects(label, action, message=None):
        try:
            action()
        except (ValueError, TypeError, KeyError, FileNotFoundError) as error:
            if message is not None and message not in str(error):
                raise ValueError(label + " failed for the wrong reason") from error
            checks.append(label)
        else:
            raise AssertionError(label + " accepted")

    rejects("missing required corpus pin", lambda: compare(*roots), "--expected-corpus")
    rejects(
        "same production revision in pre and post slots",
        lambda: comp(roots[0], roots[0]),
        "distinct production revisions",
    )
    target = roots[1] / "0-80x24.plain"
    target.write_bytes(b"corrupt")
    rejects("corrupt dump", lambda: comp(*roots))
    target.write_bytes(b"a")
    target.unlink()
    rejects("missing dump", lambda: comp(*roots))
    target.write_bytes(b"a")
    manifest_path = roots[1] / "manifest.json"
    original = manifest_path.read_bytes()
    manifest = read_json(manifest_path)
    manifest["build_identity"].pop("zig_exe_sha256")
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects(
        "missing compiler identity",
        lambda: load_run(roots[1]),
        "missing or invalid Zig compiler content identity",
    )
    manifest["build_identity"]["zig_exe_sha256"] = "a" * 64
    manifest["build_identity"]["zig_lib_sha256"] = "g" * 64
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects(
        "malformed compiler identity",
        lambda: load_run(roots[1]),
        "missing or invalid Zig compiler content identity",
    )
    manifest_path.write_bytes(original)
    manifest = read_json(manifest_path)
    manifest["items"].pop()
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects("missing manifest item", lambda: comp(*roots))
    manifest_path.write_bytes(original)
    missing_input = args.out / "missing-input"
    shutil.copytree(roots[1], missing_input)
    load_run(missing_input)
    manifest = read_json(missing_input / "manifest.json")
    for item in manifest["items"]:
        if item["input"] == "4":
            (missing_input / item["file"]).unlink()
    manifest["items"] = [item for item in manifest["items"] if item["input"] != "4"]
    (missing_input / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    rejects(
        "entire input missing",
        lambda: load_run(missing_input),
        "incomplete input/size/format coverage",
    )
    manifest = read_json(manifest_path)
    manifest["items"].append(manifest["items"][0])
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects("duplicate manifest item", lambda: comp(*roots))
    manifest_path.write_bytes(original)
    manifest = read_json(manifest_path)
    manifest["corpus_sha256"] = "different"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects("different corpus", lambda: comp(*roots))
    manifest_path.write_bytes(original)
    rejects(
        "missing ledger",
        lambda: comp(*roots, triage=[dict(row, ledger="") for row in triage]),
    )
    rejects(
        "stale triage",
        lambda: comp(*roots, triage=[dict(row, sha256=[]) for row in triage]),
    )
    check(unescape(r"a\e[1m\r\n\t\\\xff") == b"a\x1b[1m\r\n\t\\\xff")
    ops, conpty, initial = replay(
        b"size 4 2\npty conpty\nsend ab\nresize 8 3\nseq L 1 2\nexpect\n|x\nend\ncursor 0 0\n"
    )
    check(
        conpty
        and initial == [4, 2]
        and ops == [send(b"ab"), {"resize": [8, 3]}, send(b"L1\r\nL2\r\n")]
    )
    checks.append("replay bytes and resize schedule")
    kitty_input = {"id": "kitty-media", "operations": []}
    kitty_corpus = {
        "schema": 1,
        "sizes": [list(s) for s in SIZES],
        "cases": [kitty_input],
    }
    for name, header in (
        ("file", b"\x1b_Ga=T,t=f"),
        ("temporary file", b"\x1b_Gt=t"),
        ("shared memory", b"\x1b_Gt=s"),
        ("numeric file medium", b"\x1b\x00^Gx=0,t\x9f=102"),
    ):
        kitty_input["operations"] = [
            send(header[:-1]),
            {"resize": [81, 24]},
            send(header[-1:] + b";AAAA\x1b\\"),
        ]
        rejects(
            "Kitty " + name + " medium",
            lambda: requests(kitty_corpus),
            "non-direct Kitty graphics medium",
        )
    kitty_input["operations"] = [send(b"t=f\x1b_Gt=d;AAAt=\x1b\\\x1b_G;AAAA\x1b\\")]
    check(len(requests(kitty_corpus)[1]) == len(SIZES))
    checks.append("direct Kitty media and ordinary text accepted")
    rejects(
        "pty requires exactly one separator space",
        lambda: replay(b"size 4 2\npty  conpty\nsend A\n"),
        "bad replay pty directive",
    )
    rejects(
        "pty must immediately follow size",
        lambda: replay(b"size 4 2\nsend A\npty conpty\n"),
        "pty must immediately follow size",
    )
    for newline in ("\n", "\r\n"):
        payload = "A\u2028#B\u0085C\vD\fE".encode()
        script = ("size 4 2" + newline).encode() + b"send " + payload + newline.encode()
        check(replay(script)[0] == [send(payload)])
        for separator in ("\u2028", "\u0085", "\v", "\f", "\t"):
            prefix = "A" + separator + "#B"
            script = (
                "size 4 2" + newline + "seq " + prefix + " 1 1" + newline
            ).encode()
            check(replay(script)[0] == [send(prefix.encode() + b"1\r\n")])
    checks.append("replay splits only LF and preserves Unicode separators")
    completion = roots[1].parent / "completion.json"
    saved = completion.read_bytes()
    completion.unlink()
    rejects("missing completion (failed second run)", lambda: comp(*roots))
    completion.write_text("{}", encoding="utf-8")
    rejects("invalid completion", lambda: comp(*roots))
    completion.write_bytes(saved)
    record = read_json(completion)
    record["corpus_sha256"] = "0" * 64
    completion.write_text(json.dumps(record), encoding="utf-8")
    rejects("mismatched completion", lambda: comp(*roots))
    completion.write_bytes(saved)
    twin = roots[1].parent / "run-2/0-80x24.plain"
    twin.write_bytes(b"changed")
    sibling_manifest = roots[1].parent / "run-2/manifest.json"
    changed = json.loads(original)
    changed["items"][0].update(bytes=7, sha256=digest(b"changed"))
    sibling_manifest.write_text(json.dumps(changed), encoding="utf-8")
    load_run(roots[1])
    load_run(sibling_manifest.parent)
    rejects(
        "nondeterministic individually valid runs",
        lambda: complete_capture(roots[1].parent),
        "nondeterministic",
    )
    rejects(
        "nondeterministic second run",
        lambda: comp(*roots),
        "no longer deterministic",
    )
    twin.write_bytes(b"a")
    sibling_manifest.write_text(
        json.dumps(json.loads(original), separators=(",", ":")), encoding="utf-8"
    )
    rejects("sibling manifest bytes changed (run-1 selected)", lambda: comp(*roots))
    rejects(
        "sibling manifest bytes changed (run-2 selected)",
        lambda: load_set(sibling_manifest.parent),
    )
    rejects(
        "completion refuses byte-different manifests",
        lambda: complete_capture(roots[1].parent),
    )
    sibling_manifest.write_bytes(original)
    rejects("malformed triage object", lambda: comp(*roots, triage={"a": 1}))
    rejects(
        "malformed triage reason",
        lambda: comp(*roots, triage=[dict(triage[0], reason=1)]),
    )
    pair = comp(roots[0], roots[1])
    pair_triage = [dict(r, reason="control") for r in pair["differences"]]
    rejects(
        "pair triage requires ledger",
        lambda: comp(roots[0], roots[1], triage=pair_triage),
    )
    rejects("operator corpus pin", lambda: comp(*roots, expected_corpus="0" * 64))
    rejects(
        "empty corpus pin",
        lambda: comp(*roots, expected_corpus=""),
        "--expected-corpus",
    )

    def change_manifests(mutate):
        for run in ("run-1", "run-2"):
            path = roots[1].parent / run / "manifest.json"
            value = json.loads(original)
            mutate(value)
            value["shipped_profile"] = shipped_profile(
                value["profile"], value["build_identity"]
            )
            path.write_text(json.dumps(value), encoding="utf-8")
        completion.unlink()
        complete_capture(roots[1].parent)

    for field in COMPILER_HASH_FIELDS:
        old = json.loads(original)["build_identity"][field]
        new = "c" * 64
        change_manifests(
            lambda m, field=field, new=new: m["build_identity"].update({field: new})
        )
        rejects(
            f"undeclared {field} difference",
            lambda: comp(*roots),
            "--declare-profile-differences",
        )
        declaration = {
            "side": "branch",
            "option": f"build_identity.{field}",
            "reason": "synthetic compiler identity control",
            "old": {"present": True, "value": old},
            "new": {"present": True, "value": new},
        }
        check(
            comp(*roots, profile_declarations=[declaration])["profile_declarations"]
            == [declaration]
        )
        checks.append(f"declared {field} difference accepted and recorded")
        stale = {**declaration, "new": {"present": True, "value": "d" * 64}}
        rejects(
            f"stale {field} declaration",
            lambda stale=stale: comp(*roots, profile_declarations=[stale]),
            "values are stale",
        )

    change_manifests(lambda m: m["profile"].update(optimize="different"))
    declaration = [
        {
            "side": "branch",
            "option": "optimize",
            "reason": "synthetic profile control",
            "old": {"present": True, "value": "ReleaseFast"},
            "new": {"present": True, "value": "different"},
        }
    ]
    rejects(
        "different complete build profiles",
        lambda: comp(*roots, shipped_declarations=declaration),
        "--declare-profile-differences",
    )
    declared = comp(
        *roots, profile_declarations=declaration, shipped_declarations=declaration
    )
    check(
        declared["profile_declarations"]
        == [
            {
                "side": "branch",
                "option": "optimize",
                "reason": "synthetic profile control",
                "old": {"present": True, "value": "ReleaseFast"},
                "new": {"present": True, "value": "different"},
            }
        ]
    )
    check(declared["counts"] == result["counts"] and declared["untriaged"] == 16)
    checks.append(
        "declared profile difference accepted and recorded without triaging dumps"
    )
    rejects(
        "wrong profile option declaration",
        lambda: comp(
            *roots,
            shipped_declarations=declaration,
            profile_declarations=[
                dict(declaration[0], option="terminal_options.oniguruma")
            ],
        ),
    )
    rejects(
        "empty profile reason",
        lambda: comp(
            *roots,
            shipped_declarations=declaration,
            profile_declarations=[dict(declaration[0], reason=" ")],
        ),
    )
    rejects(
        "duplicate profile declaration",
        lambda: comp(
            *roots,
            shipped_declarations=declaration,
            profile_declarations=declaration * 2,
        ),
    )
    rejects(
        "wrong profile side",
        lambda: comp(
            *roots,
            shipped_declarations=declaration,
            profile_declarations=[dict(declaration[0], side="upstream")],
        ),
    )
    rejects(
        "malformed profile declaration",
        lambda: comp(
            *roots,
            shipped_declarations=declaration,
            profile_declarations={"option": "optimize"},
        ),
    )
    rejects(
        "unused profile declaration",
        lambda: comp(roots[0], mirror_pre(), profile_declarations=declaration),
    )
    rejects(
        "stale declared new value",
        lambda: comp(
            *roots,
            shipped_declarations=declaration,
            profile_declarations=[
                dict(declaration[0], new={"present": True, "value": "stale"})
            ],
        ),
    )
    rejects(
        "stale declared old value",
        lambda: comp(
            *roots,
            shipped_declarations=declaration,
            profile_declarations=[
                dict(declaration[0], old={"present": True, "value": "stale"})
            ],
        ),
    )
    rejects(
        "missing declared values",
        lambda: comp(
            *roots,
            shipped_declarations=declaration,
            profile_declarations=[
                {k: v for k, v in declaration[0].items() if k not in ("old", "new")}
            ],
        ),
    )
    change_manifests(
        lambda m: m["harness_sources"].update({"src/control.zig": "2" * 64})
    )
    rejects("changed harness", lambda: comp(*roots))
    captured = digest(
        json.dumps(
            read_json(roots[1] / "manifest.json")["harness_sources"], sort_keys=True
        ).encode()
    )
    current = digest(json.dumps(harness_sources(), sort_keys=True).encode())
    check(comp(*roots, declarations=[f"{captured}:{current}"])["untriaged"] == 16)
    check(
        comp(*roots, declarations=[f"{captured}:{current}"])["harness_declarations"]
        == [f"{captured}:{current}"]
    )
    checks.append("explicit harness change declaration")
    for run in ("run-1", "run-2"):
        (roots[1].parent / run / "manifest.json").write_bytes(original)
    completion.write_bytes(saved)
    rejects(
        "unused harness declaration",
        lambda: comp(*roots, declarations=["a" * 64 + ":" + "b" * 64]),
    )
    rejects(
        "malformed harness declaration",
        lambda: comp(*roots, declarations=["deadbeef:cafe"]),
    )
    check(comp(*roots)["sides"]["branch"]["revision"] == "1" * 40)
    checks.append("comparison records revisions, executable and both manifest hashes")

    change_manifests(
        lambda m: (
            m.update(revision="4" * 40),
            m["provenance"].update(production_revision="4" * 40),
        )
    )
    check(comp(*roots)["counts"] == result["counts"])
    pin = read_json(roots[1] / "manifest.json")["corpus_sha256"]
    check(
        comp(roots[1], roots[0], expected_corpus=pin)["counts"]
        == {"no change": 8, "different": 12}
    )
    checks.append("successor production revision accepted in pinned pre slot")
    rejects(
        "successor pre with different corpus pin",
        lambda: comp(roots[1], roots[0], expected_corpus="f" * 64),
        "operator pin",
    )
    checks.append("branch revision may differ from frozen corpus source")
    for run in ("run-1", "run-2"):
        (roots[1].parent / run / "manifest.json").write_bytes(original)
    completion.write_bytes(saved)
    pin = read_json(roots[0] / "manifest.json")["corpus_sha256"]
    pinned = comp(*roots, expected_corpus=pin)
    check(
        pinned["corpus_sha256"] == pin
        and pinned["expected_corpus"] == pin
        and result["expected_corpus"] == pin
    )
    checks.append("report records corpus identity and required operator pin")

    def duplicate_exe_revision(m):
        m["exe_sha256"] = "1" * 64
        m["revision"] = "3" * 40
        m["provenance"]["production_revision"] = "3" * 40

    change_manifests(duplicate_exe_revision)
    rejects("same executable hash under different revisions", lambda: comp(*roots))
    change_manifests(lambda m: None)
    for run in ("run-1", "run-2"):
        (roots[1].parent / run / "manifest.json").write_bytes(original)
    completion.write_bytes(saved)

    pre_manifest = (roots[0] / "manifest.json").read_bytes()
    pre_completion_path = roots[0].parent / "completion.json"
    pre_completion = pre_completion_path.read_bytes()
    non_shipped = json.loads(pre_manifest)
    non_shipped["build_identity"].update(vt_api="v140_fork", terminal_source="app")
    non_shipped["profile"].update(
        target="x86_64-windows-msvc",
        cpu_model="x86_64",
        baseline_cpu_model="x86_64",
        optimize="ReleaseFast",
        compiler_version="0.17.1",
    )
    non_shipped["profile"]["terminal_options"].update(
        artifact="ghostty", simd=False, oniguruma=True, tmux_control_mode=True
    )
    non_shipped["shipped_profile"] = shipped_profile(
        non_shipped["profile"], non_shipped["build_identity"]
    )
    check(
        [d["option"] for d in non_shipped["shipped_profile"]["differences"]]
        == ["terminal_options.simd"]
    )
    for run in ("run-1", "run-2"):
        (roots[0].parent / run / "manifest.json").write_text(
            json.dumps(non_shipped), encoding="utf-8"
        )
    pre_completion_path.unlink()
    complete_capture(roots[0].parent)
    rejects("two equal non-shipped fork profiles", lambda: comp(roots[0], mirror_pre()))
    shipping = [
        {
            "side": side,
            **non_shipped["shipped_profile"]["differences"][0],
            "reason": "explicit non-shipping control",
        }
        for side in ("pre", "branch")
    ]
    accepted = comp(roots[0], mirror_pre(), shipped_declarations=shipping)
    check(
        accepted["untriaged"] == 0
        and accepted["shipped_profile_declarations"]
        == sorted(shipping, key=lambda row: row["side"])
    )
    checks.append("explicit value-bound shipped mismatches accepted and recorded")
    rejects(
        "missing one fork shipped declaration",
        lambda: comp(roots[0], mirror_pre(), shipped_declarations=shipping[:1]),
    )
    rejects(
        "wrong shipped mismatch value",
        lambda: comp(
            roots[0],
            mirror_pre(),
            shipped_declarations=[
                dict(row, old={"present": True, "value": False}) for row in shipping
            ],
        ),
        "values are stale",
    )
    for run in ("run-1", "run-2"):
        (roots[0].parent / run / "manifest.json").write_bytes(pre_manifest)
    pre_completion_path.write_bytes(pre_completion)
    rejects(
        "unused shipped mismatch declaration",
        lambda: comp(roots[0], mirror_pre(), shipped_declarations=shipping),
    )
    public_pre = json.loads(pre_manifest)
    public_pre["build_identity"].update(vt_api="v140", terminal_source="public-lib-vt")
    public_pre["profile"]["terminal_options"].update(
        artifact="lib", oniguruma=False, tmux_control_mode=False
    )
    public_pre["shipped_profile"] = shipped_profile(
        public_pre["profile"], public_pre["build_identity"]
    )
    for run in ("run-1", "run-2"):
        (roots[0].parent / run / "manifest.json").write_text(
            json.dumps(public_pre), encoding="utf-8"
        )
    pre_completion_path.unlink()
    complete_capture(roots[0].parent)
    rejects(
        "public module cannot implicitly claim fork slots",
        lambda: comp(roots[0], mirror_pre()),
    )
    public_shipping = [
        {"side": side, **d, "reason": "Explicit public-as-fork sentinel role control"}
        for side in ("pre", "branch")
        for d in public_pre["shipped_profile"]["differences"]
    ]
    check(
        comp(roots[0], mirror_pre(), shipped_declarations=public_shipping)["untriaged"]
        == 0
    )
    checks.append(
        "public profile in fork slots requires all shipped mismatch declarations"
    )
    for run in ("run-1", "run-2"):
        (roots[0].parent / run / "manifest.json").write_bytes(pre_manifest)
    pre_completion_path.write_bytes(pre_completion)
    for field in ("revision", "exe_sha256", "provenance"):
        manifest = json.loads(original)
        del manifest[field]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        rejects("missing provenance " + field, lambda: comp(*roots))
        manifest_path.write_bytes(original)
    native = native_corpus("0" * 40)
    native_root = args.out / "native-fixture/run-1"
    native_root.mkdir(parents=True)
    write_json(native_root / "corpus.json", native)
    manifest = json.loads(pre_manifest)
    manifest["corpus_sha256"] = digest((native_root / "corpus.json").read_bytes())
    manifest["request_sha256"] = digest(
        requests(parse_json((native_root / "corpus.json").read_bytes()))[0]
    )
    manifest["items"] = []
    for case in native["cases"]:
        for cols, rows in SIZES:
            for fmt in FORMATS:
                data = (
                    native_plain(case["id"], True)
                    if fmt == "plain"
                    else b"\x1b[0moracle-control"
                    + (b"style" if case["id"] == "sgr" else b"")
                )
                leaf = f"{case['id']}-{cols}x{rows}.{fmt}"
                (native_root / leaf).write_bytes(data)
                manifest["items"].append(
                    {
                        "input": case["id"],
                        "cols": cols,
                        "rows": rows,
                        "format": fmt,
                        "file": leaf,
                        "bytes": len(data),
                        "sha256": digest(data),
                    }
                )
    write_json(native_root / "manifest.json", manifest)
    shutil.copytree(native_root, native_root.parent / "run-2")
    complete_capture(native_root.parent)
    native_controls(
        argparse.Namespace(
            dumps=native_root,
            declare_harness_change=[],
            report=args.out / "native-positive.json",
        )
    )
    checks.append("complete valid native sentinel fixture")
    forged = json.loads(json.dumps(native))
    for case in forged["cases"]:
        if case["id"] in ("resize", "conpty-on", "conpty-off"):
            case["operations"] = [
                send(native_plain(case["id"], True).replace(b"\n", b"\r\n"))
            ]
            case["conpty"] = False
    forged_packet = requests(forged)[0]
    forged_manifest = dict(
        manifest,
        corpus_sha256=digest(json.dumps(forged).encode()),
        request_sha256=digest(forged_packet),
    )
    for name in ("run-1", "run-2"):
        (native_root.parent / name / "corpus.json").write_text(
            json.dumps(forged), encoding="utf-8"
        )
        (native_root.parent / name / "manifest.json").write_text(
            json.dumps(forged_manifest), encoding="utf-8"
        )
    (native_root.parent / "completion.json").unlink()
    complete_capture(native_root.parent)
    rejects(
        "native expected text without resize or no-pull requests",
        lambda: native_controls(
            argparse.Namespace(
                dumps=native_root,
                declare_harness_change=[],
                report=args.out / "forged-must-not-exist.json",
            )
        ),
        "canonical resize/no-pull requests",
    )
    for name in ("run-1", "run-2"):
        (native_root.parent / name / "corpus.json").write_bytes(
            json.dumps(native, indent=2, sort_keys=True).encode() + b"\n"
        )
        (native_root.parent / name / "manifest.json").write_bytes(
            json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n"
        )
    (native_root.parent / "completion.json").unlink()
    complete_capture(native_root.parent)
    (native_root.parent / "completion.json").unlink()
    rejects(
        "native controls require completion",
        lambda: native_controls(
            argparse.Namespace(
                dumps=native_root,
                declare_harness_change=[],
                report=args.out / "must-not-exist.json",
            )
        ),
        "completion.json",
    )
    write_json(
        args.out / "corpus.json",
        native_corpus(
            args.source_revision
            or git(Path(__file__).resolve().parents[2], "rev-parse", "HEAD")
        ),
    )
    write_json(args.out / "comparison.json", result)
    write_json(args.out / "triage.json", triage)
    write_json(args.out / "controls.json", {"passed": len(checks), "checks": checks})
    print(
        json.dumps(
            {"controls_passed": len(checks), "classification_counts": result["counts"]},
            sort_keys=True,
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser(
        "prepare", help="freeze pre-side fuzz, synthetic and replay inputs"
    )
    command.add_argument("--repo", type=Path, required=True)
    command.add_argument("--synthetic", type=Path, required=True)
    command.add_argument("--out", type=Path, required=True)
    command.add_argument("--expect-fuzz", type=int, default=4001)
    command.set_defaults(action=prepare)
    command = commands.add_parser(
        "capture", help="run twice and require identical saved bytes"
    )
    command.add_argument("--corpus", type=Path, required=True)
    command.add_argument("--exe", type=Path, required=True)
    command.add_argument("--source-root", type=Path, required=True)
    command.add_argument("--out", type=Path, required=True)
    command.add_argument("--work", type=Path, required=True)
    command.add_argument("--timeout", type=int, default=900)
    command.set_defaults(action=capture)
    command = commands.add_parser(
        "compare", help="list differences; fail until each has current triage"
    )
    command.add_argument("pre", type=Path)
    command.add_argument("branch", type=Path)
    command.add_argument("upstream", type=Path, nargs="?")
    command.add_argument("--triage", type=Path)
    command.add_argument("--declare-harness-change", action="append", default=[])
    command.add_argument(
        "--declare-profile-differences",
        type=Path,
        help="JSON array naming each differing side/option and a reason",
    )
    command.add_argument(
        "--declare-shipped-mismatches",
        type=Path,
        help="value-bound reasons for non-shipped fork options, including pre",
    )
    command.add_argument(
        "--expected-corpus",
        required=True,
        help="required corpus SHA-256 for every comparison",
    )
    command.add_argument("--report", type=Path, required=True)
    command = commands.add_parser(
        "controls", help="exercise classifications and invalid-evidence refusals"
    )
    command.add_argument("--out", type=Path, required=True)
    command.add_argument(
        "--source-revision",
        help="production revision for native sentinel corpus (defaults to running tool HEAD)",
    )
    command.set_defaults(action=controls)
    command = commands.add_parser(
        "native-controls", help="verify captured text, SGR and reset sentinels"
    )
    command.add_argument("dumps", type=Path)
    command.add_argument("--declare-harness-change", action="append", default=[])
    command.add_argument("--report", type=Path, required=True)
    command.set_defaults(action=native_controls)
    args = parser.parse_args()
    try:
        if args.command == "compare":
            result = compare(
                args.pre,
                args.branch,
                args.upstream,
                read_json(args.triage) if args.triage else None,
                args.declare_harness_change,
                args.expected_corpus,
                read_json(args.declare_profile_differences)
                if args.declare_profile_differences
                else None,
                read_json(args.declare_shipped_mismatches)
                if args.declare_shipped_mismatches
                else None,
            )
            write_json(args.report, result)
            print(
                json.dumps(
                    {key: result[key] for key in ("counts", "items", "untriaged")},
                    sort_keys=True,
                )
            )
            return 1 if result["untriaged"] else 0
        args.action(args)
        return 0
    except (
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        # Do not print parser input, native diagnostics or environment data.
        detail = str(error) if type(error) is ValueError else "see retained artifacts"
        print(f"oracle: {type(error).__name__}: {detail}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
