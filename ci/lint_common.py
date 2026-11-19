"""Shared Git and reporting support for the migration diff lints (Python 3.13)."""

import os
import re
import subprocess
from pathlib import Path


def git_environment():
    """The explicit repo/arguments own Git reads, independent of shell overrides."""
    env = os.environ.copy()
    for name in tuple(env):
        if name.upper().startswith("GIT_"):
            del env[name]
    return env


def git(repo, *args, input=None):
    return subprocess.run(
        ["git", "-c", "color.ui=never", "-c", "color.diff=false",
         "-C", str(repo), *args], check=True, capture_output=True,
        env=git_environment(), input=input,
    ).stdout


def revision(repo, value):
    if not isinstance(value, str) or not value:
        raise ValueError("missing commit")
    return git(repo, "rev-parse", "--verify", "--end-of-options", value + "^{commit}").decode().strip()


def paths(repo, rev):
    return {
        p.decode("utf-8")
        for p in git(repo, "ls-tree", "-rz", "--name-only", rev).split(b"\0")
        if p
    }


def sources(repo, rev, names):
    """Read Git blobs, never the checkout, and fail on a missing requested blob."""
    names = sorted(names)
    if any("\n" in p or "\r" in p for p in names):
        raise ValueError("source paths containing newlines are unsupported")
    requests = "".join(f"{rev}:{p}\n" for p in names).encode("utf-8")
    data = git(repo, "cat-file", "--batch", input=requests)
    result, offset = {}, 0
    for name in names:
        end = data.index(b"\n", offset)
        header = data[offset:end].split()
        if len(header) != 3 or header[1] != b"blob":
            raise ValueError("missing source blob: " + name)
        size = int(header[2])
        offset = end + 1
        result[name] = data[offset:offset + size].decode("utf-8")
        offset += size + 1
    return result


def merge_base(repo, base, head):
    return git(repo, "merge-base", base, head).decode().strip()


DIFF_OPTIONS = ("--text", "--no-ext-diff", "--no-textconv", "--no-color",
                "--no-renames", "--no-relative", "--ignore-submodules=none",
                "--diff-algorithm=myers", "--no-indent-heuristic",
                "--inter-hunk-context=0", "--unified=0")


def changed_paths(repo, base, head, *pathspecs):
    base = merge_base(repo, base, head)
    return [
        p.decode("utf-8")
        for p in git(repo, "diff", *DIFF_OPTIONS, "--name-only", "-z", base, head,
                     "--", *pathspecs).split(b"\0") if p
    ]


def line_changes(repo, base, head):
    """Added head lines and deletion gaps (number of head lines before the gap).

    A zero-length head hunk starts after its numbered line. Other hunks start
    on that line; each deleted run is at the gap before the next head line.
    """
    base = merge_base(repo, base, head)
    names = changed_paths(repo, base, head, "*.zig")
    result = {}
    for name in names:
        diff = git(repo, "diff", *DIFF_OPTIONS, base, head,
                   "--", ":(literal)" + name).decode("utf-8")
        rows, deleted, current, had_hunk = set(), set(), None, False
        for line in diff.split("\n"):
            match = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
            if match:
                current = int(match[1]) + (match[2] == "0")
                had_hunk = True
            elif current is not None and line.startswith("+"):
                rows.add(current)
                current += 1
            elif current is not None and line.startswith("-"):
                deleted.add(current - 1)
            elif current is not None and line.startswith(" "):
                current += 1
        if not had_hunk and name in paths(repo, head):
            before = sources(repo, base, {name})[name] if name in paths(repo, base) else ""
            if sources(repo, head, {name})[name] != before:
                raise ValueError("changed Zig content produced no diff hunk")
        if rows or deleted:
            result[name] = rows, deleted
    return result


def added_lines(repo, base, head):
    return {name: added for name, (added, _) in line_changes(repo, base, head).items() if added}


def ci_revisions(repo, event):
    """Return declared commits; diff readers resolve their common ancestor."""
    kind = event.get("event_name")
    if kind == "pull_request":
        return revision(repo, event["base"]), revision(repo, event["head"])
    head = revision(repo, event["head"])
    if kind == "push":
        before = event.get("before", "")
        if not before or not before.strip("0"):
            raise ValueError("push has no pre-push commit; refusing an unbounded diff")
        return revision(repo, before), head
    if kind in ("schedule", "workflow_dispatch"):
        return revision(repo, head + "^"), head
    raise ValueError("unsupported CI event")


def lint_input_changes(repo, base, head):
    """Implementation/data edits require explicit review, including self-edits."""
    return [(name, 1, "review", "migration lint code or data changed; review required")
            for name in changed_paths(repo, base, head)
            if name.startswith("ci/") or name in (
                ".github/workflows/test.yml",
                "test/windows/flagship/contracts/Contracts.90-Workflows.ps1")]


def emit(title, findings, mode="enforce"):
    """Only locations and rule names are logged; never source text or Git stderr."""
    failures = sum(f[2] == "error" for f in findings)
    lines = [f"### {title}", "", f"Mode: {mode}. {failures} errors; "
             f"{len(findings) - failures} review flags.", ""]
    for path, line, level, rule in findings:
        # Escape workflow commands and Markdown; paths can be contributor-controlled.
        safe_path = path.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        safe_path = safe_path.replace(":", "%3A").replace(",", "%2C")
        annotation = "warning" if mode == "report" or level != "error" else "error"
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::{annotation} file={safe_path},line={line}::{rule}")
        else:
            print(f"{ascii(path)}:{line}: {level}: {rule}")
        label = ascii(path)
        ticks = "`" * (1 + max((len(m.group()) for m in re.finditer(r"`+", label)), default=0))
        lines.append(f"- {ticks}{label}{ticks}:{line}: {level}: {rule}")
    print(lines[2])
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a", encoding="utf-8", newline="\n") as stream:
            stream.write("\n".join(lines) + "\n")
    return int(bool(failures) and mode == "enforce")
