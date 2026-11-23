"""Inventory Phase 1A residual hunks and carry reviewed rows over forward merges.

Run from the repository root. Use --check for the pinned inventory.
After a forward merge, pass --tip and --forward, with --output pointing to
the refreshed ledger. New or changed records require review and exit 1.
Review decisions carry only when the hunk and its attribution still match.
"""

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import csv
from dataclasses import dataclass
from hashlib import sha256
import io
from pathlib import Path
import re
import subprocess
import sys


STONE = "74d0c72fd"
CUT = "6c7401ce0"
TIP = "8f59dbfd6"  # the D70 integration tip (w1a/1a6-int); was 5c7a99a13
MERGE = "ab950cd81"
FORWARD = "358ce0f6a"
LEDGER = Path("plans/stone-1a/residual-ledger.tsv")
FIELDS = ("id", "path", "class", "granularity", "stone_range", "tip_range",
          "hunks", "scope", "attribution", "disposition", "method", "reason", "evidence")
DISPOSITIONS = {"fork-owned", "removed platform", "recorded revert"}

# PLAN §2.1, tools/classify_owner.py. Ordering matters, including the build
# pattern preceding the docs pattern and c_get/segmented_pool falling to 5.
POLICY = {
    "src/config/Config.zig", "src/Surface.zig", "src/renderer/Thread.zig",
    "src/renderer/Pacer.zig", "src/renderer/pacer_sim.zig", "src/renderer/generic.zig",
    "src/termio/Termio.zig", "src/termio/Exec.zig", "src/termio/stream_handler.zig",
    "src/termio/shell_integration.zig", "src/terminal/search/sliding_window.zig",
    "src/terminal/search/Thread.zig", "src/terminal/PageList.zig", "src/terminal/Terminal.zig",
    "src/Command.zig", "src/font/discovery.zig",
}


def owner(path):
    if path.startswith("src/apprt/") or path in POLICY:
        return 1
    if re.match(r"^(src/os/|src/pty\.zig|src/termio/|src/crash/|src/global\.zig|src/main_ghostty\.zig|src/App\.zig)", path):
        return 2
    if re.match(r"^(src/terminal/c/|include/ghostty/|src/lib_vt\.zig)", path):
        return 4
    if path.startswith("src/terminal/"):
        return 3
    if path.startswith("src/shell-integration/"):
        return 6
    if re.match(r"^(build\.zig|src/build/|pkg/|\.github/|nix|flake|CODEOWNERS|typos|valgrind|\.gitignore|test/)", path):
        return 7
    if re.match(r"^[A-Z][A-Za-z_]*\.md$|^src/.*\.md$|^test/.*\.md$", path):
        return 8
    return 5


def git(*args):
    result = subprocess.run(
        ["git", "--no-replace-objects", "-c", "core.quotePath=false", *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise RuntimeError(f"git {args[0]} failed with exit {result.returncode}")
    return result.stdout


def revision(ref):
    return git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}").strip().decode("ascii")


def tree(ref):
    result = {}
    for item in git("ls-tree", "-rz", ref).split(b"\0"):
        if item:
            header, path = item.split(b"\t", 1)
            result[path.decode("utf-8")] = header.decode("ascii")
    return result


def tsv(data):
    return csv.DictReader((line for line in data.split("\n") if line and not line.startswith("#")),
                          delimiter="\t", quoting=csv.QUOTE_NONE)


HUNK = re.compile(rb"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: (.*))?$")
DIFF = ("--no-renames", "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative",
        "--diff-algorithm=myers", "--indent-heuristic", "--src-prefix=a/", "--dst-prefix=b/")


@dataclass(frozen=True)
class Hunk:
    path: str
    old: tuple[int, int]
    new: tuple[int, int]
    scope: str
    patch: tuple[bytes, ...]

    @property
    def fingerprint(self):
        parts = [line for line in self.patch if not line.startswith(b" ")]
        return sha256(b"\0".join((self.path.encode("utf-8"), *parts))).hexdigest()[:20]

    def changed_lines(self, minus):
        marker = b"-" if minus else b"+"
        number = self.old[0] if minus else self.new[0]
        for line in self.patch:
            if line.startswith(marker):
                yield number
            if line.startswith((marker, b" ")):
                number += 1


def changes(old, new, context=0):
    names = git("diff", *DIFF, "--name-only", "-z", old, new, "--").split(b"\0")[:-1]
    sections = git("diff", *DIFF, "--abbrev=40", f"-U{context}", old, new, "--").split(b"\ndiff --git ")
    if not names and sections == [b""]:
        return {}
    if len(sections) != len(names) or not sections[0].startswith(b"diff --git "):
        raise ValueError("patch and path inventory disagree")
    result = {}
    for raw_path, section in zip(names, sections, strict=True):
        path = raw_path.decode("utf-8")
        if any(ch in path for ch in "\t\r\n"):
            raise ValueError("path is not representable in the ledger")
        section = section.removeprefix(b"diff --git ")
        header, *lines = section.split(b"\n")
        if header != b"a/" + raw_path + b" b/" + raw_path:
            raise ValueError(f"unexpected Git patch header for {path}")
        hunks = []
        for line in lines:
            match = HUNK.fullmatch(line)
            if match:
                old_line, old_count, new_line, new_count, scope = match.groups()
                before = (int(old_line), int(old_count or 1))
                after = (int(new_line), int(new_count or 1))
                patch = []
                hunks.append((before, after, (scope or b"").decode("utf-8", "replace"), patch))
            elif hunks and line.startswith((b"+", b"-", b" ", b"\\")):
                patch.append(line)
        if hunks:
            result[path] = []
            for before, after, scope, patch in hunks:
                if (sum(line.startswith((b"-", b" ")) for line in patch) != before[1]
                        or sum(line.startswith((b"+", b" ")) for line in patch) != after[1]):
                    raise ValueError(f"patch line counts disagree for {path}")
                result[path].append(Hunk(path, before, after, scope, tuple(patch)))
        else:
            result[path] = [Hunk(path, (0, 0), (0, 0), "tree entry", tuple(lines))]
    return result


BLAME = re.compile(rb"^([0-9a-f]{40}) \d+ (\d+)(?: (\d+))?$")


def blame(ref, path, spans):
    args = []
    for start, count in spans:
        if count:
            args += ["-L", f"{start},+{count}"]
    if not args:
        return {}
    if len(args) > 128:
        args = []  # Windows command-line limit. Read the file once instead.
    result = {}
    for line in git("blame", "--incremental", *args, ref, "--", path).split(b"\n"):
        match = BLAME.fullmatch(line)
        if match:
            commit, start, count = match.groups()
            result.update((n, commit.decode("ascii")) for n in range(int(start), int(start) + int(count or 1)))
    return result


def commits(ref, *exclude):
    return set(git("rev-list", ref, "--not", *exclude).decode("ascii").splitlines())


def safe(text):
    return text.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def row_id(prefix, path, parts):
    return prefix + sha256("\0".join((path, *parts)).encode("utf-8")).hexdigest()[:16]


def inventory(stone, tip, cut, forward, merge):
    common = git("merge-base", cut, stone).strip().decode("ascii")
    fork_origins = commits(forward, stone)
    stone_origins = commits(stone, common)
    step_origins = commits(tip, forward, stone)
    old_tree = tree(stone)
    new_tree = tree(tip)
    shared = old_tree.keys() & new_tree.keys()
    with ThreadPoolExecutor(max_workers=8) as pool:
        fork_future = pool.submit(changes, stone, forward, 3)
        merge_future = pool.submit(changes, stone, merge, 3)
        delta = {p: h for p, h in changes(stone, tip, 3).items() if p in shared}
        fork_diff = fork_future.result()
        merge_diff = merge_future.result()

        def attribute(item):
            path, hunks = item
            stone_blame = blame(stone, path, [h.old for h in hunks])
            tip_blame = blame(tip, path, [h.new for h in hunks])
            fork_keys = {(h.old[0], h.fingerprint) for h in fork_diff.get(path, ())}
            merge_keys = {(h.old[0], h.fingerprint) for h in merge_diff.get(path, ())}
            result = []
            for h in hunks:
                minus = {stone_blame[n] for n in h.changed_lines(minus=True)} if h.old[1] else set()
                plus = {tip_blame[n] for n in h.changed_lines(minus=False)} if h.new[1] else set()
                key = (h.old[0], h.fingerprint)
                exact = key in fork_keys
                initial = key in merge_keys
                sides = {
                    "stone": minus & stone_origins,
                    "common-removed": minus - stone_origins,
                    "fork": plus & fork_origins,
                    "1A": plus & step_origins,
                    "upstream-kept": plus & stone_origins,
                    "common-kept": plus - (fork_origins | step_origins | stone_origins),
                }
                flags = [label for label, match in (("exact-fork", exact), ("initial-merge", initial)) if match]
                attribution = ";".join(flags + [f"{side}=" + ",".join(c[:12] for c in sorted(cs))
                                                  for side, cs in sides.items() if cs])
                result.append((h, attribution or "tree-entry", sides, exact, initial))
            return path, result

        return len(shared), dict(pool.map(attribute, sorted(delta.items())))


def covered_rows(groups, prior):
    old_by_path = defaultdict(list)
    for row in prior:
        old_by_path[row["path"]].append(row)
    rows = []
    for path, annotated in groups.items():
        counts = Counter()
        atom_rows = []
        for hunk, attribution, _, _, _ in annotated:
            counts[hunk.fingerprint] += 1
            fingerprint = f"{hunk.fingerprint}.{counts[hunk.fingerprint]}"
            atom_rows.append({
                "id": row_id("R-", path, [fingerprint]), "path": path, "class": str(owner(path)),
                "granularity": "hunk", "stone_range": f"{hunk.old[0]},{hunk.old[1]}",
                "tip_range": f"{hunk.new[0]},{hunk.new[1]}", "hunks": fingerprint,
                "scope": safe(hunk.scope) or "-", "attribution": attribution,
                "disposition": "review required", "method": "pending", "reason": "-", "evidence": "-",
            })
        previous = old_by_path[path]
        whole = [r for r in previous if r["granularity"] == "file"]
        fingerprints = [r["hunks"] for r in atom_rows]
        if (owner(path) == 1 and len(whole) == 1 and whole[0]["hunks"].split(",") == fingerprints
                and whole[0]["attribution"] == " | ".join(dict.fromkeys(r["attribution"] for r in atom_rows))):
            rows.extend(whole)
            continue
        previous_atoms = {r["id"]: r for r in previous if r["granularity"] == "hunk"}
        for row in atom_rows:
            old = previous_atoms.get(row["id"])
            if old and all(old[k] == row[k] for k in ("hunks", "attribution", "class", "stone_range", "scope")):
                row.update({k: old[k] for k in ("disposition", "method", "reason", "evidence")})
            rows.append(row)
    if len({r["id"] for r in rows}) != len(rows):
        raise ValueError("duplicate residual IDs")
    return rows


def render(stone, tip, shared, groups, rows):
    hunks = [entry[0] for group in groups.values() for entry in group]
    adds = sum(sum(1 for _ in h.changed_lines(minus=False)) for h in hunks if h.new[1])
    deletes = sum(sum(1 for _ in h.changed_lines(minus=True)) for h in hunks if h.old[1])
    header = f"""# Phase 1A residual ledger, PLAN §3.3 and TD D43.
# Stone {stone}; classified tip {tip}.
# {len(groups)} changed shared paths of {shared}; {len(hunks)} diff records; +{adds}/-{deletes} text lines.
# id: stable key for a path and hunk fingerprint(s). path: Git path. class: PLAN §2.1 owner class.
# granularity: file for uniform class 1; hunk for mixed class 1 and all other classes.
# stone_range/tip_range: Git -U3 start,count (- for a file). hunks: content keys in patch order.
# scope: Git hunk heading, or file for a whole-file disposition. attribution: exact patch witnesses
# and changed-line origins (minus: stone/common-removed; plus: fork/1A/upstream-kept/common-kept).
# A tree-entry record covers a change without line hunks. Attribution is textual provenance.
# disposition: fork-owned, removed platform, or recorded revert. method: tool or manual.
# reason: why the residual is retained. evidence: commit, test, plan exception or prior ledger row.
"""
    output = io.StringIO()
    output.write(header)
    writer = csv.DictWriter(output, FIELDS, delimiter="\t", lineterminator="\n", quotechar=None,
                            quoting=csv.QUOTE_NONE)
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stone", default=STONE)
    parser.add_argument("--tip", default=TIP)
    parser.add_argument("--cut", default=CUT)
    parser.add_argument("--forward", default=FORWARD, help="latest fork-side parent, including the cut")
    parser.add_argument("--merge", default=MERGE)
    parser.add_argument("--decisions", type=Path, default=LEDGER)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--output", type=Path)
    args = parser.parse_args()
    stone, tip, cut, forward, merge = map(revision, (args.stone, args.tip, args.cut, args.forward, args.merge))
    shared, groups = inventory(stone, tip, cut, forward, merge)
    prior = list(tsv(args.decisions.read_text(encoding="utf-8"))) if args.decisions.exists() else []
    rows = covered_rows(groups, prior)
    content = render(stone, tip, shared, groups, rows)
    if args.check and (not args.decisions.exists() or args.decisions.read_text(encoding="utf-8") != content):
        sys.exit("residual ledger differs from regenerated inventory")
    if args.output:
        args.output.write_text(content, encoding="utf-8", newline="\n")
    pending = sum(r["disposition"] not in DISPOSITIONS or r["method"] not in {"tool", "manual"}
                  or r["reason"] == "-" or r["evidence"] == "-" for r in rows)
    print(f"{len(rows)} rows, {len(groups)} shared paths, {pending} require review")
    return int(bool(pending))


if __name__ == "__main__":
    sys.exit(main())
