"""Collect per-run vt-throughput samples from EVERY attempt of recent Test runs.

Usage: python -I collect_bench2.py <out.json> <max_runs>
Public CI logs only, through gh. Output records which attempt and runner image.
"""
import json
import re
import subprocess
import sys

REPO = "amanthanvi/noctty"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, encoding="utf-8", errors="replace")
    return r.returncode, r.stdout, r.stderr


def parse(log):
    workloads = {}
    cur = []
    failed = {}
    for line in log.splitlines():
        line = ANSI.sub("", line)
        m = re.search(r"\s+run (\d+): ([0-9.]+) MB/s", line)
        if m:
            cur.append(float(m.group(2)))
            continue
        m = re.search(r"workload\s+=\s+(\w+)", line)
        if m and cur:
            workloads.setdefault(m.group(1), []).append(cur)
            cur = []
    return workloads


def main():
    out_path = sys.argv[1]
    limit = int(sys.argv[2])
    rc, out, err = gh("run", "list", "--repo", REPO, "--workflow", "test.yml", "--limit", str(limit),
                      "--json", "databaseId,headBranch,event,conclusion,createdAt,headSha,attempt")
    if rc != 0:
        print("run list failed", err[:200], flush=True)
        sys.exit(1)
    runs = json.loads(out)
    results = []
    for run in runs:
        rid = run["databaseId"]
        for attempt in range(1, int(run.get("attempt") or 1) + 1):
            rc, out, err = gh("api", f"repos/{REPO}/actions/runs/{rid}/attempts/{attempt}/jobs?per_page=100",
                              "--jq", '.jobs[] | select(.name=="Windows Headless Benchmarks") | {id, conclusion, started_at, runner_name, runner_id}')
            if rc != 0:
                print("jobs failed", rid, attempt, err[:100], flush=True)
                continue
            for line in out.splitlines():
                if not line.strip():
                    continue
                job = json.loads(line)
                rc, log, err = gh("api", "--allow-escape-sequences", f"repos/{REPO}/actions/jobs/{job['id']}/logs")
                rec = {"run": rid, "attempt": attempt, "job": job["id"], "jobConclusion": job["conclusion"],
                       "startedAt": job["started_at"], "runner": job.get("runner_name"),
                       **{k: run[k] for k in ("headBranch", "event", "createdAt", "headSha")}}
                if rc != 0:
                    rec["error"] = err[:100]
                else:
                    rec["workloads"] = parse(log)
                    # Fails carry the gate line on stderr: "median_mb_s X MB/s below threshold Y MB/s"
                    rec["gateFailLines"] = [ANSI.sub("", l).split("Z ", 1)[-1] for l in log.splitlines() if "below threshold" in l]
                results.append(rec)
                print(rid, attempt, job["conclusion"], sorted((rec.get("workloads") or {}).keys()), flush=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=1)


main()
