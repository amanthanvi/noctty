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
Deferral, below, says what a deferral costs in a real merge.

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

The ConPTY path is fork-owned by thread and function, not only by file. Three
threads own the pty: the reader (`ReadThread.threadMainWindows` and
`readUntilStopped` in `src/termio/Exec.zig`); the IO thread, which starts the
child, writes the pty's input, resizes the pseudo console under the
renderer-state mutex and cancels the reader; and the UI thread, the process's
main thread, which closes the pty. The fork spawns the first two with
`std.Thread.spawn`. The `v1.4.0` merge brings `std.Io`, and none of the three
becomes an `Io` task.

The reader reads, and the IO thread cancels that read, through Win32 externs.
Pty handles and pipes are closed the same way. The IO thread writes the pty's
input through libxev's stream. None of it goes through `Io.File`. Each symbol
has one declaration:

- Upstream's `exp` struct in `src/os/windows.zig` (`exp.kernel32` and
  `exp.ntdll`) stays as upstream wrote it, on std's `BOOL`. That makes the
  struct upstream's inside a class 2 file.
- What upstream lacks goes in one fork-added file, `src/os/windows_ext.zig`,
  with `BOOL = c_int`. The three externs `main` has inside the struct
  (`ResumeThread`, `GetComputerNameExW`, `ReOpenFile`), and the fork's other
  declarations there (the bundled-DLL function-pointer types, its constants,
  `COMPUTER_NAME_FORMAT`), move there on the merge branch, at step 1B.1 of the Ghostty 1.4.0 catch-up. Nothing under
  `src/` changes on `main` for it.
- Re-read the struct at every merge: a name it newly declares leaves the fork
  file, so each symbol on the path keeps one declaration.

On this path `std.Io` does eight things and no others. The list is closed, and
it goes by call site:

- locks, always taken with `lockUncancelable`;
- timestamps;
- thread names;
- passing the `Io` on. The handle is the process's one `std.Io`, from
  `global.io()`, and it goes into three types: `Terminal`, whose `init` keeps
  it; the renderer mailbox, a `BlockingQueue`, whose `push` locks with it; and
  the Kitty `ImageStorage`, whose `delete` in `clearScreen` gets the one the
  terminal kept;
- regular files, at five call sites: the working-directory check in
  `Subprocess.start`, the executable's path in `Subprocess.init`, the `input`
  files that `prepareInput` opens and `threadEnter` reads, the output trace's
  file in `writeSnapshot`, and the bundled ConPTY loader (`loadBundled`,
  `loadBundledFrom` and `openConsoleMatchesArchitecture`);
- `std.Io.sleep`, at upstream's two POSIX sites, `killPid` and `getpgid`,
  which no Windows build reaches. Nothing on the Windows path sleeps through
  `Io`: its waits are on a handle, with a bound;
- the reader's `yieldToDemand` keeps upstream's timed wait between chunks
  (`io.futexWaitTimeout`), the one wait there that is cancelable by
  signature;
- pure types, used as types and constants only, such as `std.Io.Writer` and
  `std.Io.Dir.max_path_bytes`.

The invariant behind the list: nothing in `Io` touches a pty handle, and
those three threads use no `Io.async`, no `Io.concurrent` and no
cancellation. The pty handles are the input and output pipes and their
console-side ends, the quit pipe, an adopted session's signal pipe, and the
pseudo console.

The loader opens one file, to read `OpenConsole.exe`'s header. That is an
ordinary `std.Io` open, and on Zig 0.17 those wait out a sharing violation
before they fail. So the merge decides what a held `OpenConsole.exe` does to
the first pane, at step 1B.6 of the catch-up, and a held-file test pins the
choice.

Upstream's own Windows lines in these files are not taken where they would
undo a fork fix. They:

- stop the reader with one pipe byte and one `CancelIoEx`;
- read in a loop that has no arm for the end of the output;
- spawn the reader with the default stack;
- wait without a bound for a killed child;
- write in 64-byte chunks;
- make the terminal's first resize with `catch unreachable`;
- fail the terminal's resize when the pty's resize fails;
- close all four pipe ends of a pty, two of which a handoff session no longer
  owns;
- call `CreateProcessW` without the fork's inherit lock and job object.

`docs/agents/log/conpty.md` says why (2026-10-10 F1, 2026-10-11 PKG-14,
2026-10-31 SURFACE-STACK, 2026-11-18 REPLY-PATH-01), and
`docs/agents/log/app-lifecycle.md` has the inherit lock (2026-10-15
JUMPLIST-02).

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

| Class | Paths                                                                                                                                                                                                             | Default side                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | `src/apprt/**`, and the fork-owned seams listed above wherever they live                                                                                                                                          | The fork wins on Windows behaviour and fork-owned features; upstream wins on VT and protocol correctness and memory safety, adapted around the fork                                                                                                                                                                                                                                                                             |
| 2     | Windows platform and process: `src/os/**`, `src/pty.zig`, `src/termio/**`, `src/crash/**`, `src/global.zig`, `src/main_ghostty.zig`, `src/App.zig`                                                                | Fork, except the `exp` struct of `src/os/windows.zig` (`exp.kernel32` and `exp.ntdll`), which stays upstream's as written (the ConPTY paragraphs above)                                                                                                                                                                                                                                                                         |
| 3     | Terminal core: the rest of `src/terminal/**`                                                                                                                                                                      | Upstream, re-applying the fork-owned delta (the written override below)                                                                                                                                                                                                                                                                                                                                                         |
| 4     | The libghostty-vt C API: `src/terminal/c/**`, `include/ghostty/**`, `src/lib_vt.zig`                                                                                                                              | Upstream                                                                                                                                                                                                                                                                                                                                                                                                                        |
| 5     | Other shared core: everything no other class names                                                                                                                                                                | Per file, which means no default: each hunk is decided and recorded with its rule and its reason                                                                                                                                                                                                                                                                                                                                |
| 6     | Shell integration: `src/shell-integration/**`                                                                                                                                                                     | Fork, taking upstream's security fixes                                                                                                                                                                                                                                                                                                                                                                                          |
| 7     | Build, CI, packaging, repository files and tests, as `owner()` matches them: `build.zig*`, `src/build/**`, `pkg/**`, `.github/**`, `nix*`, `flake*`, `CODEOWNERS`, `typos*`, `valgrind*`, `.gitignore`, `test/**` | Fork for CI, packaging and repository files; upstream's build port, adapted; the fork's own harnesses (`test/windows/**`) stay the fork's. By default a test hunk takes the side the code it tests took. Where that code was hand-merged from both sides, both sides' tests are kept. Each upstream test that is not taken is ledgered as an absence, as in `plans/stone-1a/test-absences.tsv`, so the ran-test floor counts it |
| 8     | Docs: top-level Markdown and Markdown under `src/`                                                                                                                                                                | Fork                                                                                                                                                                                                                                                                                                                                                                                                                            |

A class chooses a default side and nothing else. Four things say when the
default does not hold: the seam paragraphs under Fork-owned files (the
`PageList.Node` model, renderer scheduling, the ConPTY path), the two rules
below, and the modify/delete rule under "What the tree may hold after a
merge".

Every conflict hunk is decided on its own and recorded, whatever its class.
Class 5 shows why: the stepping stone's 48 class 5 hunks went 17 to the fork,
14 to upstream, 12 rewritten by hand, 4 keeping both sides and 1 neither. A
merge keeps three ledgers, and `plans/stone-1a/` holds the stepping stone's as
the model:

- **The resolution ledger** (`resolution-ledger.tsv`): one row per conflict
  hunk, with the side taken (fork, upstream, both, hand or neither), the rule
  that decided it and one line of why.
- **The dropped-delta ledger** (`dropped-delta.tsv`): what the result dropped
  from either side, each with a disposition. A hunk resolved to the fork's
  side owes one for the upstream lines it leaves out: kept, mapped onto the
  fork's equivalent by name, refused with a reason, or deferred, naming the
  step that re-applies it (see Deferral).
- **The residual ledger** (`residual-ledger.tsv`): every difference that
  remains between the merged tree and the upstream revision on shared paths,
  each with why it stays.

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
recorded as dropped. An exception covers the hunks of its named behaviour, not
every hunk in the files its Where column lists; the other hunks in those files
follow their class.

| Fork-owned behaviour                                                                                                                              | Where                                                                                                                                                                                                                                                                                                | Commit                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| The ConPTY resize policy (PKG-14): `keepRowActive`; on a shrink, rows below the cursor are dropped; `Exec.initTerminal` turns scrollback pull off | `src/terminal/Screen.zig`, `src/terminal/PageList.zig`, `src/termio/Exec.zig`                                                                                                                                                                                                                        | `e7ac5d003` (#328)                                                                       |
| OSC 7501's Windows half: tab badges, the taskbar, toasts, UIA and `goto_attention`                                                                | `src/termio/stream_handler.zig`, `src/apprt/win32_program_status.zig`                                                                                                                                                                                                                                | `a4de01394` (#301)                                                                       |
| The bound on Kitty placement geometry, adapted away from upstream `afb61e1b6`                                                                     | `src/terminal/kitty/graphics_exec.zig`, `src/terminal/kitty/graphics_storage.zig`                                                                                                                                                                                                                    | `a603eeac9` (#510)                                                                       |
| `QuerySearch` orchestration over upstream's search layers                                                                                         | `src/terminal/search/query_search.zig`, `src/terminal/search/terminal.zig`, `src/terminal/search/Thread.zig`                                                                                                                                                                                         | `2c0571c66` (#636)                                                                       |
| One `Pattern` matcher under upstream's search layers                                                                                              | `src/terminal/search/pattern.zig`                                                                                                                                                                                                                                                                    | `78d5671b3` (#635)                                                                       |
| Undo snapshots restore the cursor; Copy as HTML anchors only web, mail and ftp links (PKG-53)                                                     | `src/terminal/formatter.zig`, `src/terminal/hyperlink.zig`                                                                                                                                                                                                                                           | `9a624aac9` (#377)                                                                       |
| A link opens from the message loop, never with the renderer-state mutex held across `ShellExecuteW` (PKG-23, LIFE-01)                             | `src/Surface.zig`; `App.deferOpenTarget` (`369d953af`, then in `src/apprt/win32.zig`) and `App.deferShellRequest` (`6d42d0bd1`), both now in `src/apprt/win32/app.zig`                                                                                                                               | `9ddd6c5e1` (#326), `369d953af` (#332), `6d42d0bd1` (#339)                               |
| Program-reported paths go through `os/local_path.zig`: link text, the OSC 7 working directory, Kitty graphics files                               | `src/terminal/kitty/graphics_image.zig`, `src/termio/stream_handler.zig`, `src/Surface.zig`, `src/os/local_path.zig`                                                                                                                                                                                 | `6a5fd27cd` (#638)                                                                       |
| The `+new-tab` automation verb                                                                                                                    | `src/cli/new_tab.zig`                                                                                                                                                                                                                                                                                | `461580c9b` (#196)                                                                       |
| The fork's CI                                                                                                                                     | `.github/workflows/**`                                                                                                                                                                                                                                                                               | None: a path rule (see "What the tree may hold" below)                                   |
| One WUFFS zlib decoder, taking upstream's alignment fix (`42049f1c4`)                                                                             | `pkg/wuffs/src/zlib.zig`                                                                                                                                                                                                                                                                             | `a167b852c` (#609)                                                                       |
| The D3D11 backend refuses images (`.image`, `.bg_image`) until it can draw them                                                                   | `src/renderer/d3d11/RenderPass.zig`                                                                                                                                                                                                                                                                  | `e6dae0919` (#303)                                                                       |
| The fork's Windows font backend, under its own name `.windows_freetype`, decided arm by arm in the files it shares with upstream                  | `src/font/backend.zig`, `src/font/discovery_windows.zig`, `src/font/discovery_windows_dwrite.zig`, `src/font/DeferredFace_windows.zig`, and the `.windows_freetype` arms of `Collection.zig`, `DeferredFace.zig`, `discovery.zig`, `face.zig`, `library.zig`, `main.zig` and `shape.zig` beside them | `cb6ba9f83` (the name and its arms), `ff7414fe0` (the registry scan), `5e6e930c6` (#280) |
| Sentry is off in the default build                                                                                                                | `src/build/Config.zig`                                                                                                                                                                                                                                                                               | `1ba1d5e43` (#431)                                                                       |

## Ported changes

Between windows the fork ports single upstream changes: the sync PRs of
earlier windows, and security fixes out of band. A later merge then meets the
same change from both sides.

1. A port citation in the fork's history (`cherry picked from`,
   `adapted from upstream`, a cited upstream SHA, a `sync(` subject) is a hint
   for one hunk and nothing more.
2. The ownership class decides the side. A citation never moves a class 1 or
   class 2 hunk, or a hunk of an exception's behaviour, to upstream's side.
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
     subject ends `(#N)`. `f1158e2e9` (#617) cites `837c77305`, a commit of
     its own branch that the squash replaced, whose subject names
     `(upstream #14420)`. That SHA is on no upstream history, and it is
     matched to `b1d2b7ef1` in `v1.4.0`, whose subject ends `(#14420)`. The
     change is in the Nerd Font tables under `src/font/`, which are class 5
     and no part of the font-backend exception, so the ancestry clause decides
     those hunks.
   - A match by subject is a lead. The reviewer's confirmation is what makes
     it count.
6. **Ledgers follow the same rule.** A dropped-delta entry may say
   "superseded by upstream" only when it names the superseding upstream
   commit, or its verified equivalent, and that commit is an ancestor of the
   revision being merged. Otherwise the entry says "fork behaviour removed",
   with a reason, or the hunk is restored.

## What the tree may hold after a merge

Three kinds of path have a tree gate of their own, below. The "never merged"
list under Merge scope falls into the first two. Every other path a merge
touches is resolved by its class (Default sides, above) and checked by the
build, the test suite and the resolution ledger, not by a tree comparison.

**Must be empty.** No tracked file under these paths, after any merge. The
gate is `git ls-files` finding nothing for each. Upstream carries them:
`v1.4.0` has 271 files under `macos/`, 79 under `src/apprt/gtk*`, 37 under
`po/` and 16 under `nix/vm/`.

`test/windows/flagship/contracts/Contracts.15-PathKinds.ps1` runs that gate
with a negative control, for the pathspecs it lists and no others. A bullet
below that has no pathspec there is a rule the contract does not check, and
the merge's own delete list has to carry it. At `9860e6f08` the contract lists
nothing for:

- the i18n, Xcode and Metal build steps `v1.4.0` has under `src/build/`:
  `GhosttyI18n.zig`, `GhosttyXcodebuild.zig`, `MetallibStep.zig` and
  `xcframework.zig`;
- three of upstream's workflows: `clean-artifacts.yml`, `milestone.yml` and
  `publish-tag.yml`;
- the Darwin-only `src/build/libsystem_override.sh`, which `v1.4.0` adds and
  `**/LibsystemOverride*` does not match.

The paths of this kind:

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
  on, and the contract lists them;
- `LibsystemOverride*`, and `v1.4.0`'s Darwin-only
  `src/build/libsystem_override.sh`;
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
  `docs/agents/log/build-release-ci.md` that says to preserve the curated
  layout): `flake.nix`, `flake.lock`, `default.nix`, `shell.nix`,
  `build.zig.zon.nix`, `nix/devShell.nix`, `nix/libghostty-vt.nix`,
  `nix/zigCacheHash.nix`, `nix/build-support/*`.

**Track upstream.** The gate is that the directory's tree equals the merged
revision's, with one allowance and no others: in `pkg/breakpad` one file,
`pkg/breakpad/build.zig`, whose diff against the merged revision must be
exactly the fork changes its row names. Every other file in `pkg/breakpad`
compares equal, and `pkg/fontconfig` compares equal whole.

| Directory                                                    | Stepping stone (`74d0c72fd`), as landed                                                                                                    | `v1.4.0`                                                                                                                                                                            |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pkg/fontconfig`                                             | 22 files, equal to the stone's                                                                                                             | 29 files, equal to `v1.4.0`'s. From the stone, upstream adds 11, deletes 4 and renames 1                                                                                            |
| `pkg/apple-sdk`                                              | 2 files, equal                                                                                                                             | 5 files                                                                                                                                                                             |
| `pkg/libxml2`, `pkg/libintl`, `pkg/macos`, `pkg/android-ndk` | 5, 5, 59 and 2 files, equal                                                                                                                | The same counts, with upstream's content                                                                                                                                            |
| `pkg/breakpad`                                               | Equal but for two fork changes in `build.zig`: no `linkLibCpp` under the MSVC ABI, and #718's `-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH` | Keeps the first, rewritten for `v1.4.0`'s file, which sets `.link_libcpp = true` on the module where the stone's called `linkLibCpp()`; the toolchain cutover removes #718's define |

Three rules ride on these kinds.

- **Platform dependencies are not copied.** `v1.4.0`'s `build.zig.zon`
  declares `apple_sdk` and `android_ndk` as plain path dependencies. The
  fork's `build.zig.zon` has neither and does not take them.
- **A clean delete needs a user check.** A file upstream deleted and the fork
  never changed is deleted by the merge with no conflict. Before accepting
  each one, check what in the fork still uses it, fork-only files first:
  upstream's own importers arrive already changed, and the fork's do not.
  - The stepping stone had five: `pkg/highway/main.zig` and
    `pkg/highway/bridge.cpp`, whose code upstream moved under
    `pkg/highway/src/`, and the three `pkg/utfcpp` files, which lost their
    last user in the same merge.
  - The `v1.4.0` merge has ten at `3c622793c`:
    - `pkg/harfbuzz/c.zig` and `pkg/opengl/c.zig`;
    - `pkg/wuffs/src/c.zig`, which the fork-only `pkg/wuffs/src/deflate.zig`
      imports, and so does `pkg/wuffs/src/zlib.zig`, whose fork side an
      exception keeps;
    - `src/datastruct/lru.zig`, imported by `src/datastruct/main.zig`;
    - `src/lib/string.zig`, imported by `src/lib/main.zig` for `cutPrefix`,
      which the fork-only `src/cli/perform_action.zig` and
      `src/cli/send_text.zig` call;
    - `src/renderer/WebGL.zig`, imported by `src/renderer.zig`;
    - the four fontconfig alias headers under
      `pkg/fontconfig/override/include/`.
- **A modify/delete conflict is decided by who deleted, not by class.**
  - The fork deleted the file and upstream changed it: it stays deleted. The
    fork removed it on purpose, and most such files are of the must-be-empty
    kind. What upstream changed in it gets a dropped-delta row.
  - Upstream deleted the file and the fork changed it: keep the fork's file
    only if the merged tree still uses it, with a residual-ledger row that
    names the user. Otherwise take the delete. A must-keep-fork path is kept.
  - The `v1.4.0` merge has five of the second sort at `63a4c3969`:
    `src/os/args.zig`, `src/os/env.zig`,
    `src/datastruct/array_list_collection.zig`,
    `src/lib/allocator/convenience.zig`, and
    `.github/ISSUE_TEMPLATE/config.yml`, which is a must-keep-fork path. A
    sixth file upstream renamed instead:
    `src/terminal/osc/parsers/context_signal.zig` became
    `hierarchical_context.zig`, and the fork has changed it, so it conflicts
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

1. Fetch (`git fetch origin main`), then confirm `main` has not moved since
   the last forward merge: `git merge-base --is-ancestor origin/main <gated tip>`.
   The tip then contains `main`, so the merge commit's tree will equal the
   tip's.
2. With the hold still on, read the required status checks as passed on the
   gated tip, and confirm no other open pull request could merge while the
   hold is down. Leaving out `--admin` only refuses on the client side, so
   this reading is the real check.
3. Disable the hold, merge, and re-enable the hold at once, with nothing else
   merged while it is down (the stepping stone's was down for six seconds).
   Merge the pull request as a merge commit pinned to the gated tip, never with
   `--admin`:
   `gh pr merge <PR> --repo amanthanvi/noctty --merge --match-head-commit <gated tip>`.
   - Re-enable the hold whether or not the merge call succeeds, and read it
     back as active before anything else.
   - A merge call that fails goes to the maintainer. It is not retried with
     other flags.
   - Squash and rebase merging stay enabled for ordinary pull requests; the
     explicit method and the pin are what rule a squash out here. The pin
     fixes the head, not the base, so step 4 is what proves the base did not
     move.
4. Fetch again, then verify all four. If one fails, the merge is not the
   gated candidate: keep the hold on, stop, and take it to the maintainer,
   with no revert (see Rollback):
   - `git rev-parse origin/main` equals the merge commit, read after the hold
     reads back as active, so nothing landed behind the merge while the hold
     was down;
   - `git merge-base --is-ancestor <merged upstream revision> origin/main`;
   - `git rev-parse <merge>^{tree}` equals `git rev-parse <gated tip>^{tree}`;
   - the merge's first parent is the previous `main`.

The gated tip and the merge commit are one tree under two SHAs. Evidence
bound to the tree carries over from the tip. The Test workflow runs again on
the merge SHA, because `release.yml` releases only `main`'s head, and only
with a successful Test run for that exact SHA.

If that run fails, re-run each failed job once: the tree has already passed,
so a first failure is not yet a regression. A job that never reached a verdict
(a hosted outage, a cancellation) has not failed the tree: start it again when
the runner is back, as often as that takes, and the prerelease waits for it.
The same holds for a job that failed only in a step that does not run the
tree's code (checkout, toolchain setup, an artifact download or upload, a lost
runner), once its log shows that step as the first failure and the cause is
outside the repository (an outage, a mirror or registry that is down). Record
the log line in the drift report. A setup failure that reproduces because of
the repository's own configuration (a pinned tool version, a workflow input,
a cache key) is a failure of the tree, and takes the fix route below. Every re-run or restart here is a new Test run on
`main` (`gh workflow run test.yml --repo amanthanvi/noctty --ref main`, the
recovery `release.yml` names), never GitHub's "Re-run failed jobs": the
portable smoke's evidence artifact is named by run ID
(`flagship-portable-x64-<run id>`), so a second attempt in the same run adds a
second artifact of that name, and `release.yml` accepts a run only when it
holds exactly one. A failure that reproduces in the tree's own build, tests
or gates is fixed on `main`, which is still held. The maintainer disables the
hold for the fix's pull request alone and re-enables it at once, as for the
landing merge. The commit the fix lands as becomes the gated tip, and the
whole pass repeats on it: every gate, not only the ones the fix's diff
touches.

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

That holds for a window of picks, where a deferred change is still unmerged
upstream history and the next window can pick it. A real merge is different.
Once it lands, Git counts every upstream commit up to the merged revision as
merged, so a hunk resolved to the fork's side is never offered again: no
later merge brings it back, with or without a conflict. A change deferred in
a real merge is a ledger row that someone re-applies by hand, in that window
or a later one.

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
