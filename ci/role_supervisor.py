r"""Scratch prototype of the run supervisor's record (round 19's AI5): the supervisor keeps its own record of every
launch, apart from the launch manifest the harnesses write, and seals the manifest from that record. A harness that
loses or rewrites a manifest row before the seal is then caught too, which a seal computed by re-reading the manifest
cannot do (it only catches edits made after it).

  launch <state-dir> <manifest> <pid> <start> <kind>   the shared launcher's append: one manifest row, and one receipt
                                                        in <state-dir>\receipts, both under one lock file (the real
                                                        launcher takes an exclusive lock; parallel harnesses share it);
                                                        a failed append fails the harness (exit 1)
  seal <state-dir> <manifest> [--from-manifest]         append `seal <n> <sha256>` over the receipts' rows, sorted, each
                                                        ending in a line feed; --from-manifest instead re-reads the
                                                        manifest's launch rows (the non-independent seal, kept to show
                                                        the hazard)
Usage: python -I role_supervisor.py launch|seal ..."""
import hashlib
import os
import re
import sys

cmd, state, manifest = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(state, exist_ok=True)
receipts = os.path.join(state, "receipts")
LAUNCH = re.compile(r"launch\t\d+\t[^\t]*\t(?:gui|cli|forwarded)")


def seal_row(rows):
    body = "".join(r + "\n" for r in sorted(rows))
    return f"seal\t{len(rows)}\t{hashlib.sha256(body.encode('utf-8')).hexdigest()}\n"


if cmd == "launch":
    pid, start, kind = sys.argv[4:7]
    row = f"launch\t{pid}\t{start}\t{kind}"
    if not LAUNCH.fullmatch(row):
        sys.exit("launch: not a well-formed launch row; the harness fails")
    lock = os.open(os.path.join(state, "append.lock"), os.O_CREAT | os.O_RDWR)
    try:
        with open(manifest, "a", encoding="utf-8", newline="\n") as fh:
            fh.write(row + "\n")
        with open(receipts, "a", encoding="utf-8", newline="\n") as fh:
            fh.write(row + "\n")
    except OSError as e:
        sys.exit(f"launch: the append failed ({e.__class__.__name__}); the harness fails")
    finally:
        os.close(lock)
elif cmd == "seal":
    if "--from-manifest" in sys.argv[4:]:
        rows = [l.rstrip("\n") for l in open(manifest, encoding="utf-8") if LAUNCH.fullmatch(l.rstrip("\n"))]
    else:
        rows = [l.rstrip("\n") for l in open(receipts, encoding="utf-8")] if os.path.exists(receipts) else []
    with open(manifest, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(seal_row(rows))
else:
    sys.exit("usage: role_supervisor.py launch|seal ...")
