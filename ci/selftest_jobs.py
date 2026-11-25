r"""r40 (round 39's Sol M1): which of the self-test's two jobs a pull request's changed files select. 1A.5 installs it as
ci/selftest_jobs.py; CI's first self-test step runs it on the list `git diff --name-only --no-renames <base>...<head>`
writes (with --no-renames a rename lists its old path and its new one, so a file moved out of a trigger still selects).
Workflow and ci/ changes select both modes. Changes confined to the reviewed table and its sidecars, the allow-list,
the thread entries or the thread anchors select appending only, because that mode checks the live table. Test runs
the quick controls when either mode is selected. Prints one line,
"full appending", "appending" or "none", and exits 0; exits 2 (BAD-SETUP) when it cannot read the list.
Usage: python -I selftest_jobs.py <changed-paths file>"""
import sys

APPENDING_ONLY = ("ci/lock-inventory-threads.tsv", "ci/lock-inventory-allow.txt", "ci/thread-entries.tsv",
                  "ci/thread-anchors.tsv")
SIDECAR_PREFIX = "ci/lock-inventory-threads."   # the table's sidecars: ci/lock-inventory-threads.callers.tsv
WORKFLOWS = (".github/workflows/test.yml", ".github/workflows/thread-gate-selftest.yml")


def full_reads(path):
    """True when the full run reads the path (and so the appending mode, which runs every full-mode tool, too)."""
    return path in WORKFLOWS or (path.startswith("ci/") and not appending_only(path))


def appending_only(path):
    return path in APPENDING_ONLY or (path.startswith(SIDECAR_PREFIX) and "/" not in path[3:])


def appending_reads(path):
    return full_reads(path) or appending_only(path)


def main(argv):
    if len(argv) != 2:
        print("BAD-SETUP: usage: selftest_jobs.py <changed-paths file>")
        return 2
    try:
        with open(argv[1], encoding="utf-8") as fh:
            paths = [l_.strip() for l_ in fh if l_.strip()]
    except (OSError, UnicodeDecodeError) as e:
        print(f"BAD-SETUP: cannot read the changed-paths list ({type(e).__name__})")
        return 2
    full = any(full_reads(p) for p in paths)
    appending = any(appending_reads(p) for p in paths)
    print(" ".join(j for j, on in (("full", full), ("appending", appending)) if on) or "none")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
