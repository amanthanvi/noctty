# 1A.5 renderer-state acquisition review

The comparison runs from the first green tree `b16452cdc` to the 1A.5
source baseline `d07497b9f`. The tools branch changes the CI readers and
tables. Both endpoints use the branch's approved roles for the inventory
comparison. The captured first-green gate also records the review gaps
against the earlier table.

The inventory reports 96 acquisitions in 13 files at first green and 99
in 14 files at the source baseline. The latter has 48 test-code
acquisitions. Comparing rows by file, enclosing function, and exact test
identity gives 72 changed groups, 38 added groups, and one removed group.

| Area | Source review |
| --- | --- |
| Surface and Win32 | The moved selection, clipboard, input, and accessibility sites still run from UI callbacks. The left-button release captures links while holding the lock, opens them after releasing it, and reacquires for the prompt-click fallback. This replaces the former `processLinks` acquisition with a UI acquisition in `mouseButtonCallback`. `Surface.open` acquires on the UI action path. |
| Renderer | `State.lockDemand` now calls the wrapper's demand operation and remains an inline handoff. The frame snapshot and frame readers use demand acquisitions. Compression's two sites remain try-locks reached from the renderer's wakeup and timer callbacks, with the upstream compression test restriction. |
| Search and termio | The search row movements retain the search-thread owner, with UI also reaching `stop`. Termio keeps its thread and reader row split. The new `drainMailbox` acquisition belongs to the Debug test hook on the termio thread. The benchmark's new `streamLocked` acquisition belongs to its registered reader. |

The first-green gate reported seven changed caller fingerprints, for
`draw`, `step`, `wake`, `updateFrame`, `select`, `stop`, and
`resize`. The base's approved table already records their resulting
owners, signatures, and caller fingerprints. G1 gives the Compression
sites their container-qualified keys while retaining that approved
fingerprint and signature data. There are no new role or fingerprint
re-approvals proposed at the source baseline.
