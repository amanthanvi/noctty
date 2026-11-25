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

Until that merge landed on `main` (`f739b4c7b`, #748), `main`'s node was
resident-only: `Data = struct { resident: Page }`, the four accessors
`page()`, `rows()`, `cols()` and `capacity()`, and the owner inferred from the
page's size. A hunk ported to `main` before then that used another of
upstream's node names was an adaptation, and this is what each became:

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
same grep over all of `src` also found only Node's accessor bodies.

Renderer scheduling is split in the fork: `Pacer.turn` decides when a frame
updates, presents or waits and when the timers run, and `Thread.Frame` holds
the mechanics (the mailbox drain, `updateFrame` and the present, the libxev
timers). Adapt an upstream hunk that changes the render pass, its timers or
the drain's timer arms in `src/renderer/Thread.zig` into one of those two;
Thread's timer and wakeup callbacks stay one `turn` call each.

The ConPTY path is fork-owned by thread and function, not only by file. The
pty reader (`ReadThread.threadMainWindows` and `readUntilStopped` in
`src/termio/Exec.zig`), the IO thread, which starts the child, resizes the
pseudo console under the renderer-state mutex and cancels the reader, and the
UI thread, which closes the pty, are OS threads the fork spawns. The
`v1.4.0` merge brings `std.Io`, and none of the three becomes an `Io` task.
They read, write, cancel and close pty handles and pipes through Win32
externs, one declaration per symbol: upstream's `exp.kernel32` block in
`src/os/windows.zig` stays as upstream wrote it, on std's `BOOL`, and what
upstream lacks goes in one fork-added file under `src/os/` with
`BOOL = c_int`. On this path `std.Io` is for locks taken with
`lockUncancelable`, timestamps, thread names, passing the handle on, and
regular files that are not pty handles (the working-directory check before a
spawn, the `input` files, the bundled ConPTY loader). `Io.File` on a pty
handle or pipe, `Io.async`, `Io.concurrent`, the cancel APIs and `Io.sleep`
stay out of it. Upstream's own Windows lines in these files are not taken
where they stop the reader with one pipe byte and one `CancelIoEx`, spawn it
with the default stack, wait without a bound for a killed child, or write in
64-byte chunks; `docs/agents/log/conpty.md` says why (2026-10-10 F1,
2026-10-31 SURFACE-STACK, 2026-11-18 REPLY-PATH-01).

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

## Default sides

A real merge (`git merge` of an upstream revision, as in the Ghostty 1.4.0
catch-up) resolves each conflict by the ownership class of its path. `owner()`
in `plans/stone-1a/generate_stone_ledgers.py` assigns the class. It tests
class 1 first, so a fork-owned seam stays class 1 where another pattern would
also match.

| Class | Paths                                                                                                                                              | Default side                                                                                                                                        |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | The fork-owned seams listed above                                                                                                                  | The fork wins on Windows behaviour and fork-owned features; upstream wins on VT and protocol correctness and memory safety, adapted around the fork |
| 2     | Windows platform and process: `src/os/**`, `src/pty.zig`, `src/termio/**`, `src/crash/**`, `src/global.zig`, `src/main_ghostty.zig`, `src/App.zig` | Fork                                                                                                                                                |
| 3     | Terminal core: the rest of `src/terminal/**`                                                                                                       | Upstream, re-applying the fork-owned delta (the written override below)                                                                             |
| 4     | The libghostty-vt C API: `src/terminal/c/**`, `include/ghostty/**`, `src/lib_vt.zig`                                                               | Upstream                                                                                                                                            |
| 5     | Other shared core: everything no other class names                                                                                                 | Per file                                                                                                                                            |
| 6     | Shell integration: `src/shell-integration/**`                                                                                                      | Fork, taking upstream's security fixes                                                                                                              |
| 7     | Build, CI, packaging and tests: `build.zig`, `src/build/**`, `pkg/**`, `.github/**`, the Nix files, `test/**`                                      | Fork for CI and packaging; upstream's build port, adapted                                                                                           |
| 8     | Docs: top-level Markdown and Markdown under `src/`                                                                                                 | Fork                                                                                                                                                |

A class chooses a default side and nothing else. The two rules below say when
the default does not hold.

## The written override and its exceptions

**The override.** "Upstream, re-applying the fork-owned delta" is the rule
for class 3. It is also the rule for the terminal-core parts of
`src/terminal/PageList.zig` and `src/terminal/Terminal.zig`, which are class 1
by path: the compression page model, line limits, page-serial renewals,
resize-failure safety and `std.Io` threading. There the merge takes upstream's
code and re-applies what the fork owns onto it. The `PageList.Node` paragraphs
above are this rule applied to the page model.

**The exceptions.** The override does not apply to the behaviours below. In
each, the fork's side wins, and upstream's change is adapted around it or
recorded as dropped.

| Fork-owned behaviour                                                                                                                              | Where                                                                                                                | Commit                                                 |
| ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| The ConPTY resize policy (PKG-14): `keepRowActive`; on a shrink, rows below the cursor are dropped; `Exec.initTerminal` turns scrollback pull off | `src/terminal/Screen.zig`, `src/terminal/PageList.zig`, `src/termio/Exec.zig`                                        | `e7ac5d003` (#328)                                     |
| OSC 7501's Windows half: tab badges, the taskbar, toasts, UIA and `goto_attention`                                                                | `src/termio/stream_handler.zig`, `src/apprt/win32_program_status.zig`                                                | `a4de01394` (#301)                                     |
| The bound on Kitty placement geometry, adapted away from upstream `afb61e1b6`                                                                     | `src/terminal/kitty/graphics_*.zig`                                                                                  | `a603eeac9` (#510)                                     |
| `QuerySearch` orchestration over upstream's search layers                                                                                         | `src/terminal/search/query_search.zig`, `src/terminal/search/terminal.zig`, `src/terminal/search/Thread.zig`         | `2c0571c66` (#636)                                     |
| One `Pattern` matcher under upstream's search layers                                                                                              | `src/terminal/search/pattern.zig`                                                                                    | `78d5671b3` (#635)                                     |
| Undo snapshots restore the cursor; Copy as HTML anchors only web, mail and ftp links (PKG-53)                                                     | `src/terminal/formatter.zig`, `src/terminal/hyperlink.zig`                                                           | `9a624aac9` (#377)                                     |
| A link opens from the message loop, never with the renderer-state mutex held across `ShellExecuteW` (PKG-23, LIFE-01)                             | `src/Surface.zig`                                                                                                    | `9ddd6c5e1` (#326), `369d953af` (#332)                 |
| Program-reported paths go through `os/local_path.zig`: link text, the OSC 7 working directory, Kitty graphics files                               | `src/terminal/kitty/graphics_image.zig`, `src/termio/stream_handler.zig`, `src/Surface.zig`, `src/os/local_path.zig` | `6a5fd27cd` (#638)                                     |
| The `+new-tab` automation verb                                                                                                                    | `src/cli/new_tab.zig`                                                                                                | `461580c9b` (#196)                                     |
| The fork's CI                                                                                                                                     | `.github/workflows/**`                                                                                               | None: a path rule (see "What the tree may hold" below) |
| One WUFFS zlib decoder, taking upstream's alignment fix                                                                                           | `pkg/wuffs/src/zlib.zig`                                                                                             | `a167b852c` (#609)                                     |
| The D3D11 backend refuses images (`.image`, `.bg_image`) until it can draw them                                                                   | `src/renderer/d3d11/RenderPass.zig`                                                                                  | `e6dae0919` (#303)                                     |
| The fork's Windows font backend, under its own name `.windows_freetype`                                                                           | `src/font/**`                                                                                                        | `cb6ba9f83`                                            |
| Sentry is off in the default build                                                                                                                | `src/build/Config.zig`, `src/crash/sentry.zig`                                                                       | `1ba1d5e43` (#431)                                     |

## Ported changes

Between windows the fork ports single upstream changes: the sync PRs of
earlier windows, and security fixes out of band. A later merge then meets the
same change from both sides.

1. A port citation in the fork's history (`cherry picked from`,
   `adapted from upstream`, a cited upstream SHA, a `sync(` subject) is a hint
   for one hunk and nothing more.
2. The ownership class decides the side. A citation never moves a class 1 or
   class 2 hunk, or an exception above, to upstream's side.
3. The citations a search finds are the identified ports, not a complete
   count.
4. **The ancestry clause.** A port-cited hunk may take upstream's text only
   when both of these hold:
   - the cited upstream commit, or a verified equivalent of it, is an ancestor
     of the revision being merged (`74d0c72fd` for the stepping stone,
     `v1.4.0` for the merge after it);
   - the hunk matches that commit.

   Otherwise keep the fork's side, or re-apply it onto upstream's new code.
   The same holds for any hunk whose fork side carries a later upstream fix
   that the merged revision lacks: a port of a commit upstream made after
   `v1.4.0` keeps the fork's side in the `v1.4.0` merge.

5. **Equivalents.** A cited SHA that is not on upstream's history (a commit
   of an upstream PR branch, or a fork commit that a squash replaced) can
   still count, if a commit in the merged revision has the same normalised
   subject or the same `git patch-id --stable`, and the reviewer confirms the
   change.
   - Normalising a subject means: lowercase it; drop a leading `type(scope):`;
     drop trailing `(GHSA-…)`, `(upstream #N)`, `(#N)` and `[…]` groups;
     collapse punctuation.
   - A fork commit that names `(upstream #N)` names upstream's pull request.
     With no subject match, it is matched to the upstream commit whose
     subject ends `(#N)`. `f1158e2e9` (#617) names upstream #14420, which is
     `b1d2b7ef1` in `v1.4.0`.
   - A match by subject is a lead. The reviewer's confirmation is what makes
     it count.
6. **Ledgers follow the same rule.** A dropped-delta entry may say
   "superseded by upstream" only when it names the superseding upstream
   commit, or its verified equivalent, and that commit is an ancestor of the
   revision being merged. Otherwise the entry says "fork behaviour removed",
   with a reason, or the hunk is restored.

## What the tree may hold after a merge

Every path a merge touches is one of three kinds, and each kind has its gate.
The "never merged" list under Merge scope falls into the first two.

**Must be empty.** No tracked file under these paths, after any merge. The
gate is `git ls-files` finding nothing for each;
`test/windows/flagship/contracts/Contracts.15-PathKinds.ps1` holds the
pathspecs and a negative control. Upstream carries them: `v1.4.0` has 271
files under `macos/`, 79 under `src/apprt/gtk*`, 37 under `po/` and 16 under
`nix/vm/`.

- `macos/**`, `dist/macos/**`, `dist/linux/**`, `flatpak/**`, `snap/**`,
  `po/**`;
- `src/apprt/gtk*`, and the embedded C API (`src/apprt/embedded.zig`,
  `include/ghostty.h`, `src/main_c.zig`, `src/config/CApi.zig`);
- `src/renderer/metal/**`, `Metal.zig`, `Dmabuf.zig`, `DisplayLink.zig`;
- the CoreText faces and shapers;
- the macOS, Xcode and i18n build steps. The stepping-stone merge stripped
  the three Apple steps its `GhosttyLibVt.zig` referenced (`LipoStep.zig`,
  `LibtoolStep.zig`, `XCFrameworkStep.zig`; row Qg11-1 of
  `plans/stone-1a/drift-decisions.tsv`), so they are in this kind from then
  on, though the contract's list does not name them yet;
- `LibsystemOverride*`;
- `nix/package.nix`, `nix/tests.nix`, `nix/vm/**`,
  `nix/patches/zig-0.17-ios-process-replace.patch`;
- `pkg/gtk4-layer-shell/**`;
- `example/swift-vt-xcframework/**`, `test/esctest/**`;
- upstream-only `.github` paths: `VOUCHED.td`, `DISCUSSION_TEMPLATE/**`,
  `scripts/**`, `issue-unvouched-message`, and every workflow the fork does
  not have.

**Must keep fork content.** The gate is that the content after the merge
equals the content before it, or the diff is reviewed.

- The fork's `.github` files: 21 at `3c622793c` (13 workflows, 3 issue
  templates, `actions/release-preflight` and 4 top-level files).
- `CONTRIBUTING.md`, `CODEOWNERS`, `README.md`, `HACKING.md`, `PACKAGING.md`.
- The libghostty-vt-only Nix layout (the 2026-04-15 entry in
  `docs/agents/log/build-release-ci.md`): `flake.nix`, `flake.lock`,
  `default.nix`, `shell.nix`, `build.zig.zon.nix`, `nix/devShell.nix`,
  `nix/libghostty-vt.nix`, `nix/zigCacheHash.nix`, `nix/build-support/*`.

**Track upstream.** The gate is that the directory's tree equals the merged
revision's.

| Directory                                                    | Stepping stone (`74d0c72fd`), as landed                                                                                                    | `v1.4.0`                                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| `pkg/fontconfig`                                             | 22 files, equal to the stone's                                                                                                             | 29 files: the gate allow-lists upstream's 11 adds, 4 deletes and 1 rename |
| `pkg/apple-sdk`                                              | 2 files, equal                                                                                                                             | 5 files                                                                   |
| `pkg/libxml2`, `pkg/libintl`, `pkg/macos`, `pkg/android-ndk` | 5, 5, 59 and 2 files, equal                                                                                                                | The same counts, with upstream's content                                  |
| `pkg/breakpad`                                               | Equal but for two fork changes in `build.zig`: no `linkLibCpp` under the MSVC ABI, and #718's `-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH` | Keeps the first; the toolchain cutover removes #718's define              |

Two rules ride on these kinds.

- **Platform dependencies are not copied.** `v1.4.0`'s `build.zig.zon`
  declares `apple_sdk` and `android_ndk` as plain path dependencies. The
  fork's `build.zig.zon` has neither and does not take them.
- **A clean delete needs a user check.** A file upstream deleted and the fork
  never changed is deleted by the merge with no conflict. Before accepting
  each one, check what in the fork still uses it.
  - The stepping stone had five: `pkg/highway/main.zig` and
    `pkg/highway/bridge.cpp`, whose code upstream moved under
    `pkg/highway/src/`, and the three `pkg/utfcpp` files, which lost their
    last user in the same merge.
  - The `v1.4.0` merge has ten at `3c622793c`: `pkg/harfbuzz/c.zig`,
    `pkg/opengl/c.zig` and `pkg/wuffs/src/c.zig`; `src/datastruct/lru.zig`
    (imported by `src/datastruct/main.zig`); `src/lib/string.zig` (imported by
    `src/lib/main.zig`); `src/renderer/WebGL.zig` (imported by
    `src/renderer.zig`); and the four fontconfig alias headers under
    `pkg/fontconfig/override/include/`. An eleventh file is not clean:
    upstream renamed `src/terminal/osc/parsers/context_signal.zig` to
    `hierarchical_context.zig` and the fork has changed it, so it conflicts
    at the new name.

## Landing a merge

An upstream merge lands on `main` as a merge commit: not squashed, not
rebased, not fast-forwarded. A squash keeps the tree and loses the second
parent, so `git merge-base` against upstream stays at the old base and the
next window meets every conflict again. A merge commit also keeps `main`'s
first-parent history `main`'s own.

- The merge is made on a branch that takes forward merges of `main`. The last
  forward merge fixes the gated tip, the commit every gate runs on.
- `main` is held from that forward merge until the prerelease is published,
  by a repository ruleset with the "Restrict updates" rule on
  `refs/heads/main` and no bypass actor, so nothing merges past it, the
  maintainer included. It is disabled for the landing merge itself,
  re-enabled at once, and deleted when the prerelease is out.

The landing:

1. Confirm `main` has not moved since the last forward merge:
   `git merge-base --is-ancestor origin/main <gated tip>`. The tip then
   contains `main`, so the merge commit's tree will equal the tip's.
2. Merge the pull request as a merge commit pinned to the gated tip:
   `gh pr merge --merge --match-head-commit <gated tip>`, never with
   `--admin`. Squash and rebase merging stay enabled for ordinary pull
   requests; the explicit method and the pin are what rule a squash out here.
3. Verify all three, and stop if one fails, because the merge is then not the
   gated candidate:
   - `git merge-base --is-ancestor <merged upstream revision> origin/main`;
   - `git rev-parse <merge>^{tree}` equals `git rev-parse <gated tip>^{tree}`;
   - the merge's first parent is the previous `main`.

The gated tip and the merge commit are one tree under two SHAs. Evidence
bound to the tree carries over from the tip. The Test workflow runs again on
the merge SHA, because `release.yml` requires a successful Test run for the
exact SHA it releases.

The stepping stone landed this way as `f739b4c7b` (#748): its first parent is
`358ce0f6a`, and its tree equals the gated tip `f0a5dc507`'s.

**Rollback.** Never `git revert -m 1` a landed upstream merge without a
written plan to revert that revert before the next upstream merge. Git still
counts the reverted merge's commits as merged, so the next merge would leave
out everything the reverted one brought, without a conflict to say so. A
regression found after landing is fixed forward on `main`.

## Recording the base

At the end of a completed merge window, update
`dist/windows/release-metadata.json` so `upstreamBaseVersion` identifies the
upstream version line represented by the new base. Keep `firstForkPatch` at
`100`. Record the exact merge-base SHA and date in the window's dated drift
report.

Public tags remain plain semantic versions. `major.minor` tracks the upstream
Ghostty line, while `patch` is fork-owned beginning at `100`: `1.3.100`,
`1.3.101`, and so on. The exact upstream base does not appear in the public
tag. The current base is the stepping stone `74d0c72fd` from 2026-07-20,
landed on `main` by the merge commit `f739b4c7b` (#748); its dated drift report
is `plans/stone-1a/drift-report.md`. The stone is still post-`v1.3.1` upstream
main, represented as `1.3.2-dev`, not a released upstream tag, so
`upstreamBaseVersion` stays `1.3.2`. The previous base was `ba398dfff` from
2026-04-05, on the same `1.3.2-dev` line.

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
