"""CI entry: exact PR commits, pre-push commit, or last main commit on reruns."""

import argparse
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lint_common import ci_revisions, emit, lint_input_changes
import win32_ident_lint
import zig017_lint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--win32-mode", required=True, choices=("report", "enforce"))
    args = parser.parse_args()
    base, head = ci_revisions(".", {
        "event_name": os.environ.get("LINT_EVENT"),
        "base": os.environ.get("LINT_BASE"),
        "head": os.environ.get("LINT_HEAD"),
        "before": os.environ.get("LINT_BEFORE"),
    })
    here = Path(__file__).resolve().parent
    emit("Migration lint implementation/data review", lint_input_changes(".", base, head))
    zig_result = emit("Zig 0.17 migration lint", zig017_lint.check(
        ".", base, head, here / "zig017-lint-baseline.txt"))
    win_result = emit("Win32 identifier migration lint", win32_ident_lint.check(
        ".", base, head, here / "upstream-paths.txt", here / "win32-removed-identifiers.txt"), args.win32_mode)
    return max(zig_result, win_result)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, IndexError, UnicodeError, subprocess.CalledProcessError) as error:
        print(f"lint input error ({type(error).__name__}); refusing to pass", file=sys.stderr)
        sys.exit(2)
