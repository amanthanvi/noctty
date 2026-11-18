"""Shared Git and reporting support for the migration diff lints (Python 3.13)."""

import os
import re
import subprocess
from pathlib import Path


def git(repo, *args):
    return subprocess.run(
        ["git", "-c", "color.ui=never", "-C", str(repo), *args], check=True, capture_output=True
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
    data = subprocess.run(
        ["git", "-C", str(repo), "cat-file", "--batch"],
        input=requests, capture_output=True, check=True,
    ).stdout
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


def added_lines(repo, base, head):
    names = [
        p.decode("utf-8")
        for p in git(repo, "diff", "--name-only", "-z", "--no-renames", base, head,
                     "--", "*.zig").split(b"\0") if p
    ]
    result = {}
    for name in names:
        diff = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                   "--unified=0", base, head, "--", ":(literal)" + name).decode("utf-8")
        rows = set()
        for match in re.finditer(r"(?m)^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", diff):
            start = int(match[1])
            rows.update(range(start, start + int(match[2] or "1")))
        if rows:
            result[name] = rows
    return result


def ci_revisions(repo, event):
    """PR: exact base/head; push: before/head; nightly/manual: last commit."""
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
        lines.append(f"- {ascii(path).replace('`', '&#96;')}:{line}: {level}: {rule}")
    print(lines[2])
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a", encoding="utf-8", newline="\n") as stream:
            stream.write("\n".join(lines) + "\n")
    return int(bool(failures) and mode == "enforce")
