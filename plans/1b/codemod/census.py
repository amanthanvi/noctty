"""The compile-error census of a `zig build` log: one row per distinct error (file, line, column, message), the
compiler's own words, with the message's kind (quoted names replaced by X, numbers by N).

Usage: python plans/1b/codemod/census.py <build log> <out.tsv> [--prefix src/os/]
Prints the count per file and per kind. A path prefix keeps only that subtree's errors (forward slashes)."""
import argparse
import collections
import re
import sys

HEADER = re.compile(r"^(?P<path>[^:\s][^:]*(?::\\[^:]*)?):(?P<line>\d+):(?P<col>\d+): error: (?P<msg>.*)$")


def kind(msg):
    return re.sub(r"\d+", "N", re.sub(r"'[^']*'", "'X'", msg))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log")
    ap.add_argument("out")
    ap.add_argument("--prefix", default="")
    args = ap.parse_args(argv)
    rows = {}
    for raw in open(args.log, encoding="utf-8", errors="replace"):
        m = HEADER.match(raw.rstrip("\r\n"))
        if not m:
            continue
        path = m.group("path").replace("\\", "/")
        if not path.startswith(args.prefix):
            continue
        key = (path, int(m.group("line")), int(m.group("col")), m.group("msg"))
        rows[key] = kind(m.group("msg"))
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        for (path, line, col, msg), k in sorted(rows.items()):
            fh.write(f"{path}\t{line}\t{col}\t{k}\t{msg}\n")
    by_file = collections.Counter(p for p, *_ in rows)
    by_kind = collections.Counter(rows.values())
    print(f"{len(rows)} distinct errors in {len(by_file)} files")
    for k, n in by_kind.most_common(15):
        print(f"{n}\t{k}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
