# Upstream merge policy

## Posture

noctty is a hard fork of Ghostty. It adopts upstream work through deliberate,
scheduled merge windows while retaining a Windows-only application runtime and
fork-owned product behavior. This follows the roadmap's
[published non-goal 9](../plans/2026-competitive-roadmap.md#published-non-goals)
and its
[C33 ruling](../plans/2026-competitive-roadmap.md#c33--upstream-merge-cadence--published-merge-policy--sm-recurring--141).

This policy is not a daily-rebase soft-fork process. Sync work does not rebase
or force-push fork branches, and fork work is not upstreamed to
`ghostty-org/ghostty`. The `upstream` remote is read-only; never push to it.

## Cadence

A normal merge window opens after each tagged upstream Ghostty release. An
out-of-band window may open for an applicable upstream security fix, with a
target of opening within seven calendar days after the fix is identified. That
target is planning guidance for a single-maintainer project, not an SLA.

Each window produces a dated drift report under `plans/`. A window may produce
several sync PRs, but each subsystem appears in at most one of them, so review,
validation, and rollback remain bounded.

## Merge scope

The following paths are eligible for upstream merges. Eligibility does not make
a change automatic; the conflict and validation rules below still apply.

- Terminal and VT core: `src/terminal/**`, `src/simd/**`
- Renderer: `src/renderer/**`, `src/renderer.zig`
- Font: `src/font/**`
- Config: `src/config/**`, `src/config.zig`
- Input and keybindings: `src/input/**`, `src/input.zig`
- Shell integration: `src/shell-integration/**`
- Termio and PTY: `src/termio/**`, `src/termio.zig`, `src/pty.zig`, `src/pty.c`
- CLI: `src/cli/**`, `src/cli.zig`
- `libghostty-vt`: `src/lib_vt.zig`, `src/terminal/c/**`,
  `include/ghostty/**`

The following upstream paths are never merged into the fork:

- GTK runtime: `src/apprt/gtk*`, `src/apprt/gtk/**`
- macOS application and packaging: `macos/**`, `dist/macos/**`
- Linux application packaging: `dist/linux/**`, `flatpak/**`, `snap/**`
- Nix application packaging: `nix/package.nix`, `nix/tests.nix`, `nix/vm/**`
- Upstream CI workflows: `.github/workflows/**`
- Upstream community and governance files: `.github/VOUCHED.td`,
  `CODEOWNERS`, `CONTRIBUTING.md`

## Fork-owned files

The fork wins by default when a conflict crosses Windows platform behavior or
a fork-owned feature. The current high-risk seams are:

- `src/apprt/**`
- `src/config/Config.zig`
- `src/Surface.zig`
- `src/renderer/Thread.zig`
- `src/renderer/Pacer.zig` and its test adapter `src/renderer/pacer_sim.zig`
- `src/renderer/generic.zig`
- `src/termio/Termio.zig`
- `src/termio/Exec.zig`
- `src/termio/stream_handler.zig`
- `src/termio/shell_integration.zig`
- `src/terminal/search/sliding_window.zig`
- `src/terminal/search/Thread.zig`
- `src/terminal/PageList.zig`
- `src/terminal/Terminal.zig`
- `src/Command.zig`
- `src/font/discovery.zig`

Upstream wins on VT and protocol correctness and on memory-safety fixes, but
those changes must be adapted around fork-owned Windows behavior rather than
overwriting it. If neither rule resolves a conflict cleanly, add the change to
the window's deferred list with a written reason; do not force it through.

`PageList.Node` takes upstream's page model as written from the Ghostty
1.4.0 catch-up's stepping-stone merge (`74d0c72fd`) on. Upstream gave the
node an explicit page owner (`16e4b5e98`) and page compression
(`421fe8dab`) before that commit, so the merge brings both, and its
resolution keeps upstream's Node block: `data` is the `resident` and
`compressed` union, `owned` says whether the pool or the heap holds the
page, and the accessors are upstream's (`page()`, `pageIfResident()`,
`pagePreservingState()`, `pageAssumeResident()`, `storage()`, `rows()`,
`cols()` and `capacity()`, and the private `metadata()` and
`isCompressed()`). The block is the same at the stone, at v1.4.0 and on
upstream's `main`. A ported hunk that uses them applies as written and is
not an adaptation to record.

- `page()` restores a compressed node, and so does every read that goes
  through it: the `Pin` reads (`rowAndCell`, `cells`, `grapheme`, `style`,
  `isDirty`), the formatters and the row iterators. Code that must read a
  page's whole content without restoring the node uses
  `pagePreservingState()`, which decodes a compressed node into memory the
  caller frees with `deinit`. `pageIfResident()` returns null for a
  compressed node, so it is only for code that may leave out content that
  is not resident: a walk that skips its nulls silently drops compressed
  history. At the stone `mem.canReclaim` is false on Windows, so
  `PageList.compress` returns `.unsupported` and a release build never
  compresses; the test suite does (`builtin.is_test`). Windows reclaim
  (upstream `60b43068c`) comes after the stone, and the fork's UIA and
  session readers move to `pagePreservingState()` with it; the search
  window's reads move at the merge itself (the last item below).
- The page owner is `node.owned`, never the page's size: upstream's
  `compact` puts a page at or below `std_size` on the heap, and returning
  such a page to the pool corrupts it. The merge takes upstream's `compact`
  as written (it merges cleanly) and `switch (node.owned)` at every site
  where the fork infers the owner from the page's size: in the stone merge,
  the `initPages` and `clone` errdefers, `deinit`, `reset`, `grow`'s reuse
  of a pruned page, and `destroyNodeExt`. What a site left on the fork's
  side does to a compacted heap page depends on the site: `destroyNodeExt`
  returns it to the pool, `grow` reuses it as a full page, and `deinit` and
  `reset` skip it, since their size check takes it for a pool item, so the
  pool's teardown never frees it and it leaks. The two errdefers free pages
  they have just allocated, whose size and allocator still agree, but they
  take upstream's side too. Replacing the cursor's page through `PageList`
  (`compact`, `increaseCapacity`) still leaves the Screen cursor's cached
  row and cell pointing into the old page, so a test that does it calls
  `cursorReload()` before moving the cursor, as the stone's own compact test
  does.
- An adaptation the interim table below already made on `main` goes back
  to upstream's form at the merge. The merge's own conflict hunks list them:
  those whose fork side reads `page()` where upstream's reads
  `pagePreservingState()`, `pageIfResident()`, `storage()` or `restore(`.
  In the stone merge they are `search/sliding_window.zig`'s `append` and
  `appendIfWrapped` (upstream `0d015b2fc`), PageList.zig's own hunks above,
  and `src/inspector/widgets/pagelist.zig:79`, which no build compiles, so
  a wrong side there gets no compile check. One fork read has no conflict
  to point at it, because upstream has no counterpart: the fork's
  `appendPage` adds `Meta.before`, read from the previous node through
  `prev.page()`, while upstream's builds `Meta` from the node alone. That
  fork adaptation merges cleanly, so at the merge it keeps `Meta.before`
  but must read the previous node with `pagePreservingState(self.alloc)`,
  so that a compressed neighbour stays compressed. Left as it is, it
  restores one, and upstream's test "compressed history match spanning
  page boundary remains compressed" fails.

Until that merge lands on `main`, `main`'s node is still resident-only:
`Data = struct { resident: Page }`, the four accessors `page()`, `rows()`,
`cols()` and `capacity()`, and the owner inferred from the page's size. A
hunk ported to `main` before then that uses another of upstream's node names
is an adaptation, and this is what each becomes:

- `pageAssumeResident()` and `metadata()`: `page()` where the node is
  mutable; otherwise add the accessor with upstream's resident arm alone
  (`&self.data.resident`) in the first port that needs it.
- `pageIfResident()`: `page()`; drop the null arm.
- `pagePreservingState(alloc)`: `page()`; drop the `try` and the `deinit`.
- `isCompressed()`: `false`; drop the branch it guards.
- `storage()` and `Storage`: drop the `.compressed` arm.
- `switch (node.data)`: the hunk depends on compression; adapt it.
- `.owned = .pool` or `.heap`: drop it.

Each window diffs upstream's Node block against the fork's and records any
difference in its drift report: from the stepping stone on there should be
none. It also checks that
`git grep -F '.data.resident' -- src ':!src/terminal/PageList.zig'` finds
nothing: outside `PageList.zig`, code reaches a page only through the
accessors. A direct `node.data.resident` compiles anywhere, and from the
merge on it panics in a safe build when the node is compressed. Inside
`PageList.zig`, upstream's own code reaches `node.data` directly
(`compress`, `memoryStats` and tests at the stone); before the merge, the
same grep over all of `src` also finds only Node's accessor bodies.

Renderer scheduling is split in the fork: `Pacer.turn` decides when a frame
updates, presents or waits and when the timers run, and `Thread.Frame` holds
the mechanics (the mailbox drain, `updateFrame` and the present, the libxev
timers). Adapt an upstream hunk that changes the render pass, its timers or
the drain's timer arms in `src/renderer/Thread.zig` into one of those two;
Thread's timer and wakeup callbacks stay one `turn` call each.

The merge scope above decides which paths a window merges from upstream. It is
not a reason to defer an upstream memory-safety fix (a use-after-free, double
free, data race or resource leak) whose code also exists in the fork. When such
a fix lands in a fork-owned seam or outside the merge scope, for example in
`src/Surface.zig` or `src/os/**`, port it by hand into the fork's code, in the
window that finds it or out of band, together with its tests where they exist.
Record the upstream commit and what was adapted in that window's drift report,
or, for a port made between windows, in the latest one. Defer it only for a
written reason that is about the fix itself, such as the fixed code not
existing in the fork.

## Recording the base

At the end of a completed merge window, update
`dist/windows/release-metadata.json` so `upstreamBaseVersion` identifies the
upstream version line represented by the new base. Keep `firstForkPatch` at
`100`. Record the exact merge-base SHA and date in the window's dated drift
report.

Public tags remain plain semantic versions. `major.minor` tracks the upstream
Ghostty line, while `patch` is fork-owned beginning at `100`: `1.3.100`,
`1.3.101`, and so on. The exact upstream base does not appear in the public
tag. The current base is `ba398dfff` from 2026-04-05: post-`v1.3.1` upstream
main, represented as `1.3.2-dev`, not a released upstream tag.

## Validation gates

Every merge window must run:

```powershell
pwsh -NoProfile -File scripts/check-zig-format.ps1
zig build -Demit-exe=true
zig build test -Demit-test-exe=true
pwsh -NoProfile -File scripts/check-source-format.ps1
```

Use `scripts/check-zig-format.ps1` rather than a bare `zig fmt --check src`.
The tracked generated table `src/build/uucode_tables.zig` is not `zig fmt`
clean under the pinned Zig 0.15.2, so the bare command fails on an unmodified
checkout and cannot serve as a merge-window gate. The script formats every
other tracked Zig source under `src/` and `pkg/` plus `build.zig`.

When scripts or validation harnesses change, also run:

```powershell
pwsh -NoProfile -File test/windows/flagship/Test-VerificationContracts.ps1
```

Renderer or input picks can also be checked with the interactive Windows 11
composite validator and the harnesses covering the affected surface (for
example `interactive-win11-ime-candidate.ps1` for preedit changes and
`interactive-win11-key-input.ps1` for key-encoding changes). These runs are
optional: no pick requires a visible or interactive run (the maintainer's
decision, 2026-11-22), and a multi-agent council review takes their place:

```powershell
pwsh -NoProfile -File test/windows/interactive-win11-validate.ps1 -ResetState
```

When such a run is made, record its result in the window's drift report.

**The baseline is zero failures, not a pass count.** Every branch adds its own
tests, so the passing total legitimately differs between windows and proves
nothing; a non-zero failure count is the signal. The suite previously carried
one known failure, `Command: custom env vars`, which `main` has since fixed —
do not treat it, or any other named test, as an allowed exception. A filtered
`-Dtest-filter=` run does not satisfy this gate: narrowed runs have hidden real
breakage before.

## Deferral

A pick that conflicts structurally is deferred to the next merge window with a
written reason in the dated drift report. It is never forced into the current
window.

## How to check drift

`scripts/upstream-drift.ps1` reads local refs only. A fresh clone has only
`origin`, so add the upstream remote once before the first drift check.
Disabling its push URL is not optional politeness — this fork never pushes
upstream, and `DISABLED` makes an accidental `git push upstream` fail instead
of authenticate:

```powershell
git remote add upstream https://github.com/ghostty-org/ghostty.git
git remote set-url --push upstream DISABLED
```

Then refresh the read-only upstream tracking ref explicitly when network and
Git metadata permissions allow it, and run the report:

```powershell
git fetch upstream
pwsh -NoProfile -File scripts/upstream-drift.ps1
```

`upstream-drift.ps1` itself never fetches and never writes. If the tracking ref
is absent — the expected state on a fresh clone — it says so, prints the setup
and fetch commands for the remote and branch it was asked to check, and exits 1
rather than reaching for the network.

Use `-Remote` and `-Branch` only when checking another local tracking-ref pair.
The equivalent raw Git inputs are:

```powershell
$base = git merge-base HEAD upstream/main
git show -s --format='%H%x09%cs' $base
git rev-list --left-right --count HEAD...upstream/main
git diff --name-only "$base..HEAD"
git diff --name-only "$base..upstream/main"
git diff --diff-filter=D --name-only "$base..HEAD"
git show HEAD:dist/windows/release-metadata.json
```

The live overlap is the intersection of the two `--name-only` lists after
removing paths in the fork-deletion list.
