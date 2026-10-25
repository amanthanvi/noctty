# Hang-hunt artifacts of run 40153047396

Copied on 2026-10-25 from the GitHub Actions artifacts of run 40153047396 (they expire 2026-10-28), because the
repository's `*.log` ignore rule had kept the logs out of the earlier evidence commit. `hunt-single-*` are single
harness runs and `hunt-stress-*` are runs under CPU load. The hang diagnostics PR #566 cites are in
`hunt-single-3` (inner PowerShell spinning in the parent walk; noctty pid 728 with csrss 736 and wininit 860
listed as its children after pid reuse).
