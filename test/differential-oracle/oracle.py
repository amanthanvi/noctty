#!/usr/bin/env python3
"""Freeze, capture and compare PLAN.md section 3.4's headless VT oracle."""

import argparse
import base64
import collections
import hashlib
import json
import re
import struct
import subprocess
import sys
from pathlib import Path

SIZES = ((80, 24), (132, 43))
FORMATS = ("plain", "vt")
KINDS = ("bytes", "utf8", "osc-valid", "osc-invalid")
CLASSES = (
    "no change",
    "fork behaviour removed",
    "fork-owned semantics",
    "bug candidate",
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
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicates)


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args]).decode().strip()


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
    for raw in data.decode("utf-8").splitlines():
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
        words = rest.split()
        if initial is None and cmd != "size":
            raise ValueError("replay must begin with size")
        if cmd == "size":
            if initial is not None or len(words) != 2:
                raise ValueError("bad replay initial size")
            initial = [int(x) for x in words]
        elif cmd == "pty":
            if rest != "conpty" or operations:
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
    if initial is None or expecting:
        raise ValueError("unfinished replay")
    return operations, conpty, initial


def prepare(args):
    repo = args.repo.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    paths = git(repo, "ls-files", "-z", "test/fuzz-libghostty/corpus").split("\0")
    paths = sorted(path for path in paths if path)
    if len(paths) != args.expect_fuzz:
        raise ValueError("fuzz seed count differs from the declared corpus")
    cases = []

    def add(name, data, operations, **facts):
        cases.append(
            {
                "id": name,
                "source_sha256": digest(data),
                "operations": operations,
                **facts,
            }
        )

    for path in paths:
        data = (repo / path).read_bytes()
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
    fixtures = sorted((repo / "src/terminal/testdata/replay").glob("*.vt"))
    if not fixtures:
        raise ValueError("no replay fixtures")
    for path in fixtures:
        data = path.read_bytes()
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
        "source_revision": git(repo, "rev-parse", "HEAD"),
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
    corpus = read_json(args.corpus)
    packet, records = requests(corpus)
    source = args.source_root.resolve()
    # New harness overlays on an exact production revision are permitted;
    # any tracked source edit invalidates the revision label.
    if git(source, "status", "--porcelain=v1", "--untracked-files=no"):
        raise ValueError("capture source has tracked changes")
    revision = git(source, "rev-parse", "HEAD")
    exe = args.exe.resolve()
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
        if response.take(4) != b"ORS1" or response.unpack("I")[0] != len(records):
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
            "schema": 1,
            "revision": revision,
            "corpus_sha256": digest(corpus_bytes),
            "request_sha256": digest(packet),
            "exe_sha256": digest(exe.read_bytes()),
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
    print(json.dumps(result, sort_keys=True))


def load_set(root):
    manifest = read_json(root / "manifest.json")
    if manifest["schema"] != 1 or not manifest["items"]:
        raise ValueError("unsupported or empty dump set")
    corpus_bytes = (root / "corpus.json").read_bytes()
    corpus = read_json(root / "corpus.json")
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
    return manifest, items


def classify(pre, branch, upstream):
    if branch == upstream == pre:
        return CLASSES[0]
    if branch == upstream:
        return CLASSES[1]
    if branch == pre:
        return CLASSES[2]
    return CLASSES[3]


def native_controls(args):
    _, items = load_set(args.dumps)
    if {key[0] for key in items} != {"text", "sgr", "reset", "resize"}:
        raise ValueError("native controls require the four sentinel inputs")
    checks = []
    for cols, rows in SIZES:
        for name in ("text", "sgr", "reset", "resize"):
            if items[(name, cols, rows, "plain")] != b"oracle-control":
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
    write_json(args.report, {"passed": len(checks), "checks": checks})
    print(json.dumps({"native_controls_passed": len(checks)}))


def compare(pre_root, branch_root, upstream_root=None, triage=None):
    sets = [
        load_set(root)
        for root in (pre_root, branch_root, upstream_root)
        if root is not None
    ]
    if (
        len({m["corpus_sha256"] for m, _ in sets}) != 1
        or len({m["request_sha256"] for m, _ in sets}) != 1
    ):
        raise ValueError("compared corpus/request identities differ")
    if any(set(items) != set(sets[0][1]) for _, items in sets[1:]):
        raise ValueError("compared dump coverage differs")
    triaged = {}
    for row in triage or []:
        key = (row["input"], row["cols"], row["rows"], row["format"])
        if key in triaged or not row.get("reason", "").strip():
            raise ValueError("duplicate or unexplained triage")
        triaged[key] = row
    differences = []
    counts = collections.Counter()
    for key in sorted(sets[0][1]):
        values = [items[key] for _, items in sets]
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
            if category in CLASSES[1:3] and not entry.get("ledger", "").strip():
                raise ValueError("fork difference requires a ledger entry")
            row.update(triaged=True, reason=entry["reason"], ledger=entry.get("ledger"))
        differences.append(row)
    if triaged:
        raise ValueError("triage names an absent or unchanged item")
    return {
        "counts": dict(sorted(counts.items())),
        "items": len(sets[0][1]),
        "differences": differences,
        "untriaged": sum(not r["triaged"] for r in differences),
    }


def controls(args):
    args.out.mkdir(parents=True, exist_ok=False)
    # All five partitions of equality, including pre=upstream != branch.
    triples = (
        (b"a", b"a", b"a"),
        (b"a", b"b", b"b"),
        (b"a", b"a", b"b"),
        (b"a", b"b", b"c"),
        (b"a", b"b", b"a"),
    )
    roots = [args.out / side for side in ("pre", "branch", "upstream")]
    corpus = {
        "schema": 1,
        "sizes": SIZES,
        "cases": [
            {"id": str(n), "operations": [send(b"control")]}
            for n in range(len(triples))
        ],
    }
    for side, root in enumerate(roots):
        root.mkdir()
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
        write_json(
            root / "manifest.json",
            {
                "schema": 1,
                "corpus_sha256": digest((root / "corpus.json").read_bytes()),
                "request_sha256": digest(requests(read_json(root / "corpus.json"))[0]),
                "items": items,
            },
        )
    result = compare(*roots)
    assert result["counts"] == {
        CLASSES[0]: 4,
        CLASSES[1]: 4,
        CLASSES[2]: 4,
        CLASSES[3]: 8,
    }
    assert result["untriaged"] == 16 and len(result["differences"]) == 16
    triage = [
        dict(row, reason="synthetic control", ledger="control ledger row")
        for row in result["differences"]
    ]
    assert compare(*roots, triage=triage)["untriaged"] == 0
    assert compare(roots[0], roots[0])["untriaged"] == 0
    assert compare(roots[0], roots[1])["counts"] == {"no change": 8, "different": 12}
    checks = [
        "five equality partitions",
        "complete three-way listing",
        "hash-bound triage",
        "pair identical",
        "pair differences",
    ]

    def rejects(label, action):
        try:
            action()
        except (ValueError, FileNotFoundError):
            checks.append(label)
        else:
            raise AssertionError(label + " accepted")

    target = roots[1] / "0-80x24.plain"
    target.write_bytes(b"corrupt")
    rejects("corrupt dump", lambda: compare(*roots))
    target.write_bytes(b"a")
    target.unlink()
    rejects("missing dump", lambda: compare(*roots))
    target.write_bytes(b"a")
    manifest_path = roots[1] / "manifest.json"
    original = manifest_path.read_bytes()
    manifest = read_json(manifest_path)
    manifest["items"].pop()
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects("missing manifest item", lambda: compare(*roots))
    manifest_path.write_bytes(original)
    manifest = read_json(manifest_path)
    manifest["items"] = [item for item in manifest["items"] if item["input"] != "4"]
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects("entire input missing", lambda: compare(*roots))
    manifest_path.write_bytes(original)
    manifest = read_json(manifest_path)
    manifest["items"].append(manifest["items"][0])
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects("duplicate manifest item", lambda: compare(*roots))
    manifest_path.write_bytes(original)
    manifest = read_json(manifest_path)
    manifest["corpus_sha256"] = "different"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    rejects("different corpus", lambda: compare(*roots))
    manifest_path.write_bytes(original)
    rejects(
        "missing ledger",
        lambda: compare(*roots, triage=[dict(row, ledger="") for row in triage]),
    )
    rejects(
        "stale triage",
        lambda: compare(*roots, triage=[dict(row, sha256=[]) for row in triage]),
    )
    assert unescape(r"a\e[1m\r\n\t\\\xff") == b"a\x1b[1m\r\n\t\\\xff"
    ops, conpty, initial = replay(
        b"size 4 2\npty conpty\nsend ab\nresize 8 3\nseq L 1 2\nexpect\n|x\nend\ncursor 0 0\n"
    )
    assert (
        conpty
        and initial == [4, 2]
        and ops == [send(b"ab"), {"resize": [8, 3]}, send(b"L1\r\nL2\r\n")]
    )
    checks.append("replay bytes and resize schedule")
    native_cases = []
    for name, data in (
        ("text", b"oracle-control"),
        ("sgr", b"\x1b[31moracle-control\x1b[0m"),
        ("reset", b"discarded\x1bcoracle-control"),
    ):
        native_cases.append(
            {"id": name, "source_sha256": digest(data), "operations": [send(data)]}
        )
    native_cases.append(
        {
            "id": "resize",
            "conpty": True,
            "operations": [
                send(b"oracle-control"),
                {"resize": [40, 2]},
                {"resize": [80, 24]},
            ],
        }
    )
    write_json(
        args.out / "corpus.json", {"schema": 1, "sizes": SIZES, "cases": native_cases}
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
    command.add_argument("--expect-fuzz", type=int, default=4002)
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
    command.add_argument("--report", type=Path, required=True)
    command = commands.add_parser(
        "controls", help="exercise classifications and invalid-evidence refusals"
    )
    command.add_argument("--out", type=Path, required=True)
    command.set_defaults(action=controls)
    command = commands.add_parser(
        "native-controls", help="verify captured text, SGR and reset sentinels"
    )
    command.add_argument("dumps", type=Path)
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
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        # Do not print parser input, native diagnostics or environment data.
        detail = str(error) if type(error) is ValueError else "see retained artifacts"
        print(f"oracle: {type(error).__name__}: {detail}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
