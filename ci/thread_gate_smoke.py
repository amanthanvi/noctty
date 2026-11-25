"""Exercise the installed and scratch self-test layouts under the fast Test gate."""
from pathlib import Path
import re
import shutil
import subprocess
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: python -I ci/thread_gate_smoke.py <fresh-work-directory>")
    ci = Path(__file__).resolve().parent
    work = Path(sys.argv[1]).resolve()
    tools, draft = work / "scratch/tools", work / "scratch/ci-draft"
    work.mkdir(parents=True)
    tools.mkdir(parents=True)
    draft.mkdir()
    for path in (*ci.glob("*.py"), ci / "astdump.zig"):
        shutil.copyfile(path, tools / path.name)
    shutil.copytree(ci / "fixture", draft / "fixture")
    for name in ("role-runs.tsv", "lock-inventory-threads.tsv"):
        shutil.copyfile(ci / name, draft / name)

    for label, layout in (("installed", ci), ("scratch", tools)):
        for mode, args in (
            ("layout", ["--check-layout"]),
            ("quick controls", ["--quick", str(ci.parent), str(work / label)]),
        ):
            print(f"{label} {mode}", flush=True)
            result = subprocess.run([sys.executable, "-I", str(layout / "controls.py"), *args],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    encoding="utf-8", errors="replace")
            for line in result.stdout.splitlines():
                if re.fullmatch(r"RESULT (?:PASS|FAIL) \(\d+ failures\)", line) or re.fullmatch(
                        r"\d+ of \d+ as expected|\d+-[a-zA-Z0-9-]+: .*; (?:AS EXPECTED|UNEXPECTED)", line):
                    print(line, flush=True)
            if result.returncode:
                print(f"{label} {mode} failed with exit {result.returncode}", flush=True)
                return result.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
