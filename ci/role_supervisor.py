"""Record launch and exit receipts and seal them independently of the manifest.

  launch <state-dir> <manifest> <pid> <start> <kind>
  exit <state-dir> <manifest> <run> <pid> <start> <kind> <code> <stderr-file>
  seal <state-dir> <manifest> [--from-manifest]

The launcher supplies the process's creation time and full exit code from its
own process handle. Only the presence of the layer marker is copied from stderr.
"""
from contextlib import contextmanager
import hashlib
import os
import re
import sys

LAUNCH_KINDS = ("gui", "cli", "forwarded")
LAUNCH = re.compile(r"launch\t\d+\t[^\t]*\t(?:gui|cli|forwarded)")
EXIT = re.compile(
    r"exit\t([A-Za-z0-9_-]+)\t([1-9][0-9]*)\t([1-9][0-9]*)\t([A-Za-z0-9_-]+)"
    r"\t(normal|abnormal)\t(0|[1-9][0-9]{0,9})\t(yes|no)"
)
LAYER = b"thread-role layer:"


def parse_exit(row):
    match = EXIT.fullmatch(row)
    if match is None:
        return None
    run, pid, start, kind, status, code, marker = match.groups()
    code = int(code)
    if code > 0xffffffff or (status == "normal") != (code == 0):
        return None
    return run, pid, start, kind, code, marker


def seal_row(rows, label="seal"):
    body = "".join(row + "\n" for row in sorted(rows))
    return f"{label}\t{len(rows)}\t{hashlib.sha256(body.encode('utf-8')).hexdigest()}\n"


@contextmanager
def append_lock(state):
    with open(os.path.join(state, "append.lock"), "a+b") as lock:
        lock.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield


def lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as stream:
        return stream.read().splitlines()


def append(path, text):
    with open(path, "a", encoding="utf-8", newline="\n") as stream:
        stream.write(text)


def has_layer_marker(path):
    tail = b""
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            data = tail + chunk
            if LAYER in data:
                return True
            tail = data[-(len(LAYER) - 1):]
    return False


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: role_supervisor.py launch|exit|seal ...")
    cmd, state, manifest, *fields = argv
    os.makedirs(state, exist_ok=True)
    receipts = os.path.join(state, "receipts")
    exits = os.path.join(state, "exits")
    try:
        if cmd == "launch" and len(fields) == 3:
            row = "launch\t" + "\t".join(fields)
            if not LAUNCH.fullmatch(row):
                sys.exit("launch: invalid launch identity")
            receipt = receipts
        elif cmd == "exit" and len(fields) == 6:
            run, pid, start, kind, raw_code, stderr_path = fields
            code = int(raw_code)
            if not -(1 << 31) <= code <= 0xffffffff:
                sys.exit("exit: invalid process exit code")
            code &= 0xffffffff
            marker = "yes" if has_layer_marker(stderr_path) else "no"
            row = f"exit\t{run}\t{pid}\t{start}\t{kind}\t{'abnormal' if code else 'normal'}\t{code}\t{marker}"
            if parse_exit(row) is None:
                sys.exit("exit: invalid process identity")
            receipt = exits
        elif cmd == "seal" and fields in ([], ["--from-manifest"]):
            with append_lock(state):
                launch_rows = ([row for row in lines(manifest) if LAUNCH.fullmatch(row)]
                               if fields else lines(receipts))
                exit_rows = lines(exits)
                append(manifest, seal_row(launch_rows) + (seal_row(exit_rows, "exit-seal") if exit_rows else ""))
            return
        else:
            sys.exit("usage: role_supervisor.py launch|exit|seal ...")
        with append_lock(state):
            append(receipt, row + "\n")
            append(manifest, row + "\n")
    except (OSError, UnicodeError, ValueError) as error:
        sys.exit(f"{cmd}: recording failed ({type(error).__name__})")


if __name__ == "__main__":
    main(sys.argv[1:])
