# Aggressive improvement roadmap

Status: active until the fork PR is squash-merged and its signed release is verified.

## Gates

- [x] Generated package artifacts removed from Git; recurrence check in CI.
- [x] Release and updater documentation consistency checks.
- [x] Layout hot-path pane count hoisted.
- [x] Bounded typed single-instance IPC with hostile-client tests.
- [x] Renderer failures feed frame health and recovery.
- [x] Updater publisher identity and verified-object handoff hardened.
- [x] Concrete Win32 layout, session, history, and chrome seams.
- [x] Accessibility inventory, provider coverage, and UIA acceptance probe.
- [x] Installed-theme palette preview/revert/commit transaction.
- [x] Conditional Apple dependencies and stale exclusions removed.
- [x] PR smoke plus nightly/main interactive Win11 policy.
- [ ] Fork-only review loop clean; squash merge and signed release complete.

Implementation evidence belongs in the PR and release. Reopen a checkbox when
its acceptance condition regresses.
