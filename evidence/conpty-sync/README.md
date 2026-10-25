# Evidence for PKG-13-HARNESS-NOT-IN-CI (not for merge)

Hosted-runner logs (ANSI stripped) behind the numbers in the pull request that wires
`test/windows/interactive-win11-conpty-sync.ps1` into `.github/workflows/conpty-sync.yml`.
Every log is one hosted `windows-2025` job; `RUN n exit=... seconds=...` lines give each harness run.

- `before-fix/exp1-hosted`: 3 jobs x 3 runs of the first version (one `ReadConsoleOutputW 1` failure).
- `before-fix/exp2`: 6 jobs x 3 runs with the dump retry but the old process walk (two hangs, both run 3).
- `before-fix/hunt`: 8 single-run jobs and 3 jobs x 6 runs with the progress lines and timeout diagnostics
  (three hangs, one VM twice in a row).
- `hang-diagnostics/single3-sync-run-1.log`: the timeout-diagnostics block of one hang (inner PowerShell
  268 s CPU in 300 s, one running thread; csrss, wininit, services and the runner listed as "descendants").
- `after-fix/hunt`: the fixed harness, 8 fresh VMs x 5 runs, 40 of 40 pass.
- `negative-control`: the product with the #262 minimize clamp reverted; only `minimize-restore-cmd` fails.
- `real-workflow`: the committed workflow's first hosted run (earlier harness version).
- `before-fix/local-main-run.log`: 18 of 18 locally on main (hidden desktop, pre-uninstall build).
- `scratch-tests`: the synthetic-input tests the contract fragment is built from, and the mutant generator.
