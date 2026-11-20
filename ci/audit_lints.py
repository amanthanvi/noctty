"""Retain per-commit lint findings and timings for a bounded main-history audit."""

import argparse
import collections
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lint_common as common
import win32_ident_lint as win
import zig017_lint as zig


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--head", default="origin/main")
    parser.add_argument("--since", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    head = common.revision(args.repo, args.head)
    commits = common.git(args.repo, "log", "--first-parent", "--reverse", "--format=%H",
                         "--since=" + args.since, head).decode().splitlines()
    here, rows = Path(__file__).resolve().parent, []
    for index, commit in enumerate(commits):
        base = common.revision(args.repo, commit + "^")
        started = time.perf_counter()
        zig_rows = zig.check(args.repo, base, commit, here / "zig017-lint-baseline.txt")
        zig_seconds = time.perf_counter() - started
        started = time.perf_counter()
        win_rows = win.check(args.repo, base, commit, here / "upstream-paths.txt",
                             here / "win32-removed-identifiers.txt")
        win_seconds = time.perf_counter() - started
        rows.append(dict(commit=commit, zig=zig_rows, win32=win_rows,
                         zig_seconds=zig_seconds, win32_seconds=win_seconds))
        # Preserve progress before the next commit, including a failed run.
        args.output.write_text(json.dumps(dict(head=head, since=args.since, commits=rows),
                                          indent=2) + "\n", encoding="utf-8")
        if (index + 1) % 20 == 0:
            print(f"audited {index + 1}/{len(commits)} commits", flush=True)
    errors = collections.Counter(f[3] for row in rows for f in row["zig"] if f[2] == "error")
    flags = collections.Counter(f[3] for row in rows for f in row["zig"] if f[2] == "review")
    summary = dict(head=head, since=args.since, commits=len(rows),
                   zig_failed_commits=sum(any(f[2] == "error" for f in row["zig"]) for row in rows),
                   zig_errors=dict(errors), zig_review=dict(flags),
                   win32_failed_commits=sum(bool(row["win32"]) for row in rows),
                   win32_lines=sum(len({(f[0], f[1]) for f in row["win32"]}) for row in rows),
                   zig_seconds=sum(row["zig_seconds"] for row in rows),
                   win32_seconds=sum(row["win32_seconds"] for row in rows))
    args.output.with_suffix(".summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
