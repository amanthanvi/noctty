# Upstream drift analysis — September 2026

- **Analysis date:** 2026-09-03
- **Fork:** `amanthanvi/noctty`
- **Issue:** #141, C33 — upstream merge cadence and published merge policy
- **Scope:** drift analysis plus the bounded 2026-09 merge window slice

## Conclusion

The fork base is unchanged: `ba398dfff3e30ff83da07140981ca138410cf608`
(2026-04-05). The analyzed upstream head is
`09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8` (2026-09-03), 266 commits past the
head analyzed in the 2026-08 window. At this snapshot the fork is **243 commits
ahead and 1,976 commits behind**, on a **192-file live conflict surface**.

Four upstream commits are picked, each as its own `git cherry-pick -x` commit,
all inside `src/terminal`. They build and leave the full suite green: **4321
passed, 72 skipped, 0 failed**. No renderer and no input-encoding pick was taken
this window; those need the interactive Windows 11 composite and are listed as
deferred.

`997a2aff2afc` (`terminal: preserve pending wrap in VT formatter`) is deferred
again. The accessor it needs is not a small helper — see below.

## Snapshot identity

| Item                            | Value                                                      |
| ------------------------------- | ---------------------------------------------------------- |
| Fork head analyzed              | `26ad242ce85740e6e916778aeb6eadcd37ea0d74` (`origin/main`) |
| Sync branch code head           | `aefef259060ee527932158b27b080f9a1df089b1`                 |
| Upstream head analyzed          | `09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8` (2026-09-03)    |
| Previous window's upstream head | `ca9e5b1301354018f92152c1282a922baacfa0e1` (2026-08-21)    |
| Merge base (unchanged)          | `ba398dfff3e30ff83da07140981ca138410cf608` (2026-04-05)    |
| Ahead / behind                  | 243 / 1976                                                 |
| Recorded `upstreamBaseVersion`  | `1.3.2`                                                    |
| Newest upstream tag in range    | `v1.3.1`                                                   |

The merge base did not move: this window is cherry-picks only, with no merge
commit and no rebase of fork history. `dist/windows/release-metadata.json`
therefore keeps `upstreamBaseVersion` at `1.3.2` and `firstForkPatch` at `100`.

### Snapshot freshness

`scripts/upstream-drift.ps1` reads local refs only. `upstream/main` was fetched
on 2026-09-03 before this analysis; every figure below is pinned to the two SHAs
above rather than a moving `HEAD`.

## Upstream work since the base

Commit counts over `base..upstream/main`, by area:

| Area                                                            | Commits |
| --------------------------------------------------------------- | ------- |
| `src/terminal`                                                  | 520     |
| `libghostty-vt` (`lib_vt.zig`, `terminal/c`, `include/ghostty`) | 181     |
| build / `pkg` / `nix` / CI                                      | 176     |
| `src/config`                                                    | 48      |
| `src/termio`, `src/pty.*` (excluding shell integration)         | 47      |
| `src/renderer`                                                  | 40      |
| `src/font`                                                      | 29      |
| `src/cli`                                                       | 25      |
| `src/input`                                                     | 21      |
| shell integration                                               | 12      |
| `src/simd`                                                      | 9       |

The 266 commits new since the previous window contain 166 non-merge commits, 52
of which touch an eligible path. Most of that 52 is three feature series — the
Kitty clipboard protocol (OSC 5522), Kitty drag-and-drop, and the
`ghostty_search_*` / paste C APIs — plus the Zig 0.16 and freestanding
`libghostty-vt` build migration. None of those is a narrow fix.

## Live conflict surface

Raw path counts over the same range:

| Input                  | Count |
| ---------------------- | ----- |
| Fork-changed paths     | 1380  |
| Upstream-changed paths | 927   |
| Raw intersection       | 405   |
| Fork deletions         | 731   |
| **Live overlap**       | 192   |

The live overlap is `(fork ∩ upstream) − fork-deleted`. It grew from 165 to 192
because the fork advanced 57 commits, not because upstream moved into new areas.
By area: `src/terminal` 30, `src/cli` 19, `src/font` 12, `src/build` 11,
`src/config` 10, `src/renderer` 9, `src/os` 9, `src/termio` 7,
`src/shell-integration` 6, `src/input` 6, `src/apprt` 4.

### Highest-risk individual files

Changed-line counts on each side since the base:

| File                                     | Fork | Upstream |
| ---------------------------------------- | ---- | -------- |
| `src/terminal/PageList.zig`              | 33   | 9000     |
| `src/terminal/Terminal.zig`              | 42   | 5212     |
| `src/Surface.zig`                        | 2214 | 2179     |
| `src/terminal/Screen.zig`                | 740  | 3365     |
| `src/config/Config.zig`                  | 2658 | 884      |
| `src/terminal/search/sliding_window.zig` | 1449 | 218      |
| `src/termio/Exec.zig`                    | 686  | 874      |
| `src/renderer/Thread.zig`                | 917  | 344      |
| `src/termio/stream_handler.zig`          | 505  | 754      |

`PageList.zig` is the dominant seam and the reason several picks below are
deferred: upstream rewrote it around page compression.

## Security review

### CVE-2026-26982 remains fixed at this head

`37e902d90e6c074e15d19e9e8b59036bf6264d18` (`input: paste encoding replaces
unsafe control characters with spaces`) is still an ancestor of the base;
`git merge-base --is-ancestor` exits 0. The fork has since modified
`src/input/paste.zig` in its own paste-path security work (#123, `3b8c12ba5`),
so this window re-checked the file rather than relying on the base: the strip
table at `src/input/paste.zig:21` still covers VINTR, VQUIT, VKILL, VSUSP, ESC,
DEL and the rest; the replacement loop is at line 75; and the four
`encode strip unsafe bytes*` regression tests are intact at lines 245-273.

No commit message in `base..upstream/main` contains the CVE identifier.

### Security-relevant commits new in this window

The keyword search over `ca9e5b1301..09ff85b2ac7` returns three commits; one is
GTK-only.

| Commit         | Classification                                                                                                | Disposition                                                                                                   |
| -------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `5f5495826c7a` | Accounting bug in `RefCountedSet.addWithId`; upstream reports style-memory over-provisioning, no crash or OOB | Deferred — functional hunk applies, its regression tests need `RefCountedSet.iterator`, absent from the fork. |
| `9313d580c6b0` | Stale cursor style / hyperlink state after scroll clear                                                       | Deferred — conflicts in `src/terminal/Screen.zig`, a 740-line fork seam.                                      |
| `6cd684d5d3b2` | GTK property-binding stale pointers                                                                           | Out of scope: `src/apprt/gtk` is never merged.                                                                |

`090fca451d2c` (`terminal/kitty: validate POSIX shared memory names`) is the one
other security-shaped commit in the range. It conflicts, and it is inert here:
`LoadingImage.readSharedMemory` returns `error.UnsupportedMedium` at comptime on
Windows (`src/terminal/kitty/graphics_image.zig:114`), and upstream's own
regression test skips on Windows. Recorded, not queued.

`33d34cf5ce7b` (VS15 cursor underflow, memory safety) was deferred in 2026-08
and is picked this window; see below.

## Recommended immediate cherry-pick slice

### Gated slice — applied on this branch

| Commit         | Subject                                                               | Files                              | Why it is narrow                                                             |
| -------------- | --------------------------------------------------------------------- | ---------------------------------- | ---------------------------------------------------------------------------- |
| `7cd2f65f5cb3` | `terminal: color reset should set override to null, not default`      | `color.zig`, `stream_terminal.zig` | One-line semantic fix in `DynamicRGB.reset`; consumers read through `get()`. |
| `33d34cf5ce7b` | `terminal: avoid VS15 cursor underflow`                               | `Terminal.zig`                     | Memory-safety fix; ReleaseFast computed an out-of-bounds cell pointer.       |
| `4e817e79a1d7` | `terminal: treat high bytes in DCS strings as payload data`           | `parse_table.zig`                  | Pure table addition; the fork's 3-line divergence is elsewhere.              |
| `eb722cb26dfe` | `terminal: mark the previous row dirty when clearing its spacer head` | `Screen.zig`, `Terminal.zig`       | Five production lines plus a regression test.                                |

All four are `git cherry-pick -x` commits carrying the
`(cherry picked from commit <sha>)` trailer. Nothing outside `src/terminal` is
touched. Three carry a fork adaptation, each recorded in its own commit message:

- `7cd2f65f5cb3`: added `const color = @import("color.zig");` to
  `stream_terminal.zig`. Upstream already carries that import at its line 14;
  the fork's copy predates it and the new test needs `color.RGB`.
- `33d34cf5ce7b`: the two new tests called `init(testing.io, alloc, ...)`.
  `std.testing.io` does not exist under the pinned Zig 0.15.2 and the fork's
  `Terminal.init` takes two arguments, so both use
  `init(testing.allocator, ...)`.
- `eb722cb26dfe`: the new test used `testing.io` and `node.page()`. The fork's
  `PageList.Node` stores `data: Page` directly, so the integrity assert is
  `node.data.assertIntegrity()`, matching the neighbouring fork tests in the
  same file.

In every case the production hunk and every assertion are unmodified; only test
scaffolding was adapted to the fork's older Zig and `PageList` API.

### `997a2aff2afc` — deferred again, with the accessor examined

The 2026-08 window dropped it at the build gate on
`src/terminal/formatter.zig:599: no field or member function named 'page' in
'terminal.PageList.Node'`. This window checked whether the accessor is a small
self-contained helper worth backporting on its own. It is not.

Upstream's `Node.page()` (`src/terminal/PageList.zig:95`) exists only because
`Node.data` became
`union(enum) { resident: Page, compressed: compression.Page }` (line 79). Its
non-resident arm calls `Node.restore()` (line 254), which pulls in
`terminal_mem.recommit`, `RestoreMode`, the `compression.Page` codec, and the
sibling accessors `pageIfResident`, `pageAssumeResident`, `storage`, `metadata`,
and `isCompressed`. The fork's `Node` is still `data: Page` with no storage union
at all (`src/terminal/PageList.zig:44`).

Backporting the accessor verbatim therefore means merging the page-compression
slice, which this window explicitly does not do. The pick stays deferred.

**Residual option for the next window:** the fix has exactly one call site,
`cursor.page_pin.node.page()` in `formatter.zig`, which the fork could spell
`&cursor.page_pin.node.data`. That is a one-line divergence from upstream in
production code, so it is recorded here as a decision for the next window rather
than taken silently in this one.

### Interactive certification

None required. All four picks are terminal-core changes certified by the build
and full-suite gates below. No renderer or input-encoding commit was picked, so
`test/windows/interactive-win11-validate.ps1` was not run this window.

### DEFERRED TO NEXT MERGE WINDOW

| Group                                      | Commits                                                                                                                        | Specific reason                                                                                                                                                                        |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| VT formatter pending-wrap fix              | `997a2aff2afc`                                                                                                                 | Needs `PageList.Node.page()`, the entry point of upstream's page-compression storage model, not a standalone helper. See the section above.                                            |
| Renderer scheduling and state              | `14d9e600acf2`, `25e624569143`, `d34b54e9b4ec`, `446f80f4edd1`, `cde7f93435eb`, `aee7bf347564`, `9490f7134215`                 | Needs interactive certification; next window. The release runner was reserved on the day of this window.                                                                               |
| Input encoding and Surface lifetime        | `28f4676b5d89`, `ab82b8ab720c`                                                                                                 | Needs interactive certification; next window. Both now apply cleanly but land in `src/Surface.zig`, which is not an eligible merge path under `docs/upstream-merge-policy.md`.         |
| RefCountedSet living-count fix             | `5f5495826c7a`                                                                                                                 | Functional hunk applies; both accompanying regression tests need `RefCountedSet.iterator` and a `testing` binding the fork's copy lacks. Not landing a hot-path fix without its tests. |
| Scroll-clear cursor and hyperlink state    | `9313d580c6b0`                                                                                                                 | Conflicts in `src/terminal/Screen.zig` (740 fork lines against 3365 upstream lines).                                                                                                   |
| Row-storage recycling and page pool        | `b31fbc846474`, `e01e75bbb228`, `028af92ce387`                                                                                 | All conflict in `PageList.zig`; `b31fbc846474` also needs snapshot testdata the fork does not carry, and `e01e75bbb228` adds `datastruct/untouched_pool.zig`.                          |
| VT ground-state and OSC stream work        | `0f35043c9ac5`, `40a40f848dfc`, `8c5bc3d29f17`                                                                                 | All conflict in `src/terminal/stream.zig`; upstream's copy has drifted well past the fork's base version. Merge as one coherent stream slice.                                          |
| VT fast-path chain                         | `47e26df60f53`, `1a88f3622b50`, `253e4f9c3c43`, `300f42c7a970`                                                                 | Unchanged from 2026-08: the chain head still conflicts. `1a88f3622b50` and `253e4f9c3c43` now apply textually but are optimization fragments, not fixes; not split off.                |
| Critical UTF-8/VT security and correctness | `aea63d71fe66`, `cb4c49fbf206`, `c992658b2994`, `727b8a02f873`, `6cadad06f468`                                                 | Unchanged from 2026-08: patches fail against upstream-dependent APIs or cross fork-owned `Terminal.zig`, `osc.zig`, and `stream_handler.zig`.                                          |
| Kitty graphics security series             | `64dcb91c1f3f`, `af2faa311a5a`, `e5840bb9bacd`, `ec04900ab957`, `f766f303a7d3`, `590d669c4a72`, `090fca451d2c`                 | Unchanged from 2026-08: the fork predates the necessary Kitty refactors. `090fca451d2c` is additionally inert on a Windows-only build.                                                 |
| Kitty clipboard protocol (OSC 5522)        | `e03475c0cc52` through `70f0065759428` (14 commits)                                                                            | A feature series spanning `clipboard.zig`, `stream_terminal.zig`, `stream_handler.zig`, `Config.zig`, and the C header. Not a fix, and it changes user-visible permission policy.      |
| Kitty drag and drop                        | `7c845e8af5b2`, `38746b8c1432`, `50f69b883cc7`, `af8d28a940be`, `db2f8be59011`                                                 | New protocol feature; whole series or nothing.                                                                                                                                         |
| libghostty-vt search and paste C API       | `149c9f562af3`, `32601cd79a23`, `f0c918fc4b72`, `f9202919f719`, `76d9fcefef59`, `06178eeaad76`, `60a1ae2df755`, `da27e6c90827` | Depends on `src/terminal/search/terminal.zig`, absent from the fork, and crosses the fork-owned search seam.                                                                           |
| Title-report injection fix                 | `38e891e6c0bb`                                                                                                                 | Unchanged from 2026-08: the direct patch fails and opt-in title reports change user-visible policy.                                                                                    |
| Terminal pointer and geometry safety       | `33cda4dc5dbf`, `c5a3c7e2e5b4`                                                                                                 | Unchanged from 2026-08. `33d34cf5ce7b` left this group: it is picked this window.                                                                                                      |
| Kitty placement lifecycle                  | `6760c6482be2`, `d0c516f8f384`, `b5e86a42844e`, `b8222f4a8403`                                                                 | Unchanged from 2026-08: crosses fork-modified `renderer/image.zig`.                                                                                                                    |
| Zig 0.16 and build/dependency migration    | `e8525c0fd907`, `3376153a44e5`, `a5423592cde2`, `d9857eabae06`                                                                 | Repo-wide structural migration. `d9857eabae06` only rewrites the `list-themes` preview sample into Zig 0.16 syntax: cosmetic, and wrong for a fork pinned to 0.15.2.                   |
| Vendored shell-integration upgrade         | `5d6615fc43ce` (bash-preexec 0.7.0)                                                                                            | Applies cleanly, but no gate in this repo covers `bash-preexec.sh`; it is a third-party version bump, not a targeted fix. Needs a live Git Bash session.                               |
| Upstream issue #12600 changes              | `dfccdb2d4dfd`                                                                                                                 | Touches `src/Surface.zig` and `src/config/Config.zig`, the two highest-risk fork-owned seams.                                                                                          |
| Font asset refresh                         | `28b5bf905986`                                                                                                                 | Embedded Noto emoji binary update; belongs in a deliberate font-asset window with glyph-rendering checks.                                                                              |

Nothing touching `src/apprt/**` is proposed. macOS, GTK, Metal-only, and Linux
packaging commits are excluded rather than queued.

## Validation gates

Run on `aefef259060ee527932158b27b080f9a1df089b1`, the last source commit on
this branch, in the window worktree. The branch tip adds only this report,
which changes no code:

| Gate                                                 | Result                                |
| ---------------------------------------------------- | ------------------------------------- |
| `scripts/check-zig-format.ps1`                       | pass (700 tracked sources)            |
| `zig build -Demit-exe=true`                          | exit 0                                |
| `zig build test -Demit-test-exe=true`                | **4321 passed, 72 skipped, 0 failed** |
| `scripts/check-source-format.ps1`                    | pass                                  |
| `prettier@3 --write plans/upstream-drift-2026-09.md` | clean                                 |

Targeted `-Dtest-filter=` runs for `VS15`, `OSC 11`, `spacer head`, and `DCS`
all exit 0. They are recorded for completeness only: this build graph prints no
per-test counts for a filtered run, so a filtered pass cannot be distinguished
from a filter that matched nothing. The full suite above is the gate, as the
policy requires.

## Reproduce this analysis

Pin both heads; a moving `HEAD` or `upstream/main` will drift the numbers.

```powershell
$forkHead = '26ad242ce85740e6e916778aeb6eadcd37ea0d74'
$upstreamHead = '09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8'
$prevUpstream = 'ca9e5b1301354018f92152c1282a922baacfa0e1'
$base = git merge-base $forkHead $upstreamHead

git show -s --format='%H%x09%cs%x09%s' $base
git rev-list --left-right --count "$forkHead...$upstreamHead"
git show "$forkHead`:dist/windows/release-metadata.json"
pwsh -NoProfile -File scripts/upstream-drift.ps1
```

Path inputs behind the live overlap:

```powershell
git diff --name-only "$base..$forkHead"                  # 1380
git diff --name-only "$base..$upstreamHead"              # 927
git diff --diff-filter=D --name-only "$base..$forkHead"  # 731
```

New-range triage and the security search:

```powershell
$range = "$prevUpstream..$upstreamHead"
git rev-list --count $range                              # 266
git rev-list --count --no-merges $range                  # 166

git log --no-merges --format='%H%x09%cs%x09%s' $range -- `
  src/terminal src/simd src/font src/config src/config.zig `
  src/input src/input.zig src/shell-integration src/termio `
  src/termio.zig src/pty.zig src/pty.c src/cli src/cli.zig `
  src/lib_vt.zig include/ghostty                         # 52

git log $range --no-merges --regexp-ignore-case --extended-regexp `
  --grep='security|CVE|overflow|UAF|use-after-free|OOB|bounds|sanitiz|injection|panic|crash|leak' `
  --format='%H%x09%cs%x09%s'                             # 3
```

Candidate gate, run per commit before anything is committed:

```powershell
git cherry-pick --no-commit -n $sha
git status --porcelain=v2 --branch
```

## Deliberate exclusions and residual risk

- No merge commit, no rebase of fork history, and no write to the `upstream`
  remote, whose push URL stays `DISABLED`.
- The merge base did not move, so `upstreamBaseVersion` stays `1.3.2`. A future
  window that actually advances the base must update
  `dist/windows/release-metadata.json`.
- Three of the four picks carry a test-only fork adaptation. Each is spelled out
  in its commit message; none changes a production hunk or an assertion.
- Textual applicability is not evidence of correctness. `1a88f3622b50` and
  `253e4f9c3c43` now apply cleanly and were still declined, because they are
  fragments of a chain whose head does not.
- Two real memory-safety fixes (`28f4676b5d89`, `ab82b8ab720c`) apply cleanly and
  were still declined, because `src/Surface.zig` is not an eligible merge path.
- Renderer and input-encoding work is deferred wholesale this window: the
  interactive Windows 11 runner was unavailable, and the policy does not certify
  those areas without it.
