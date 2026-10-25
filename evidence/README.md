# Evidence for BENCH-VT-FLOOR-01 (not for merge)

Raw data and scripts behind the figures in `docs/windows-benchmark-methodology.md`
and the pull request that changed the gate.

- `bench_all.json`: the step logs of the `Windows Headless Benchmarks` job for every
  attempt of every Test run between 2026-10-17 and 2026-10-25, parsed by
  `collect_bench2.py` (public CI logs read through `gh`). Per workload, each entry
  is one five-run block in run order, MB/s.
- `noise/bench-noise-<N>/{ascii,utf8,osc,scroll,meta}.json`: 28 `windows-2025`
  runners (N = 1-20 started at 00:40Z, N = 21-28 between 01:16Z and 01:26Z on
  2026-10-25), each running the gate's four workloads with `--runs=60` (OSC 20)
  and no floor. `per_run_mb_s` is in run order; `meta.json` has the runner's CPU.
  The workflow that produced them was `.github/workflows/zz-bench-noise.yml` on
  this branch's earlier commits.
- `final_stats.py`: every figure quoted, from the two sets above:
  `python -I final_stats.py bench_all.json noise noise2`
  (`noise` holds runners 1-20 and `noise2` runners 21-28, as downloaded from the
  two experiment runs).
