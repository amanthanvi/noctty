# Upstream drift analysis — August 2026

- **Analysis date:** 2026-08-22
- **Fork:** `amanthanvi/noctty`
- **Issue:** #141, C33 — upstream merge cadence and published merge policy
- **Scope:** drift analysis plus the bounded 2026-08 merge window slice

## Conclusion

The fork base is
`ba398dfff3e30ff83da07140981ca138410cf608` (2026-04-05). The analyzed
upstream head is `ca9e5b1301354018f92152c1282a922baacfa0e1`
(2026-08-21). At that snapshot the fork is **186 commits ahead and 1,710
commits behind**.

The raw overlap is not the useful conflict number. The fork changed 1,221
paths and upstream changed 880. Their raw intersection is 363 paths, but the
fork deleted 696 paths, including the macOS application, GTK runtime, and
Linux packaging. Removing fork-deleted paths leaves a **165-file live
conflict surface**.

Eight narrow upstream commits were candidate immediate picks. All eight apply
without conflict, but one of them (`997a2aff2afc`) does not compile against the
fork's older `PageList` API and was dropped. The remaining seven apply cleanly,
build, and leave the full test suite at its known baseline (3770/3841 passing,
the one pre-existing `Command: custom env vars` failure). The three
terminal/SIMD picks are certified by those gates. The four renderer/input picks
remain provisional until the required interactive Windows results are recorded.

## Snapshot identity

| Item                              | Value                                                            |
| --------------------------------- | ---------------------------------------------------------------- |
| Fork `HEAD`                       | `d031dc474efc4811e662a3e387e560fb760f0e19`                       |
| Merge base                        | `ba398dfff3e30ff83da07140981ca138410cf608`                       |
| Base date and subject             | 2026-04-05 — `Update VOUCHED list (#12123)`                      |
| Upstream head                     | `ca9e5b1301354018f92152c1282a922baacfa0e1`                       |
| Upstream date and subject         | 2026-08-21 — `terminal/osc: kitty notification parsing feedback` |
| Fork/upstream divergence          | 186 ahead / 1,710 behind                                         |
| Fork paths changed since base     | 1,221                                                            |
| Upstream paths changed since base | 880                                                              |
| Raw path overlap                  | 363                                                              |
| Fork-deleted paths                | 696                                                              |
| Raw-overlap paths deleted by fork | 198                                                              |
| Live overlap                      | **165**                                                          |

`dist/windows/release-metadata.json` records:

```json
{
  "upstreamBaseVersion": "1.3.2",
  "firstForkPatch": 100
}
```

That file is fork release metadata; it did not exist at the merge-base
commit. The exact base is established by `git merge-base`, not by reconstructing
a tag from that JSON value.

The newest actual upstream release tag reachable from `upstream/main` is
`v1.3.1` at `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
(2026-03-13). No `vMAJOR.MINOR.PATCH` tag points into
`base..upstream/main`. Therefore the metadata value `"1.3.2"` means
post-`v1.3.1` main, or **1.3.2-dev**. It is not an upstream `v1.3.2`
release tag.

### Snapshot freshness

`git fetch upstream` was run on 2026-08-22 and left `upstream/main` at
`ca9e5b130135...` (2026-08-21). All figures in this report are against that
snapshot.

## Upstream work since the base

Counts are path-filtered unique commit counts from
`git rev-list --count base..upstream/main -- <paths>`. They include relevant
merge commits. Areas overlap, so the counts must not be summed.

| Area                                              |   Commits | Notable upstream commits                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------- | --------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Terminal / VT core, `src/terminal/**`             |       470 | `727b8a02f873` — `terminal: bound OSC and grapheme allocations`; `997a2aff2afc` — `terminal: preserve pending wrap in VT formatter`; `39ae85f040dd` — `lib-vt: handle DECRQSS`; `88ed6bebf` — `libghostty: much faster wide-character reflow on resize`                                                                                                   |
| Renderer, `src/renderer/**`                       |        35 | `d34b54e9b4ec` — `renderer: hand off state mutex to avoid starving frames`; `446f80f4edd1` — `terminal: render state update optimizations (~2.7x to ~11x less lock hold)`; `9c9cf3e82174` — `renderer: avoid allocating when there are no active links`; `aee7bf347564` — `renderer: drive kitty graphics animation`                                      |
| Font, `src/font/**`                               |        28 | `61fce4d0a` — `font: add Windows font discovery backend`; `dac341cad` — `font/sprite: make cursor height respect adjust-cursor-height`; `ca8868a29` — `font/shaper: eliminate grapheme candidate allocations`; `6f02d9aad` — `font: render glyf directly into output bitmap`                                                                              |
| Config, `src/config/**`                           |        45 | `29b82dd80` — `config: preserve bytes in hex escapes`; `65c48213b` — `config: expose scrollback line limit`; `c6e7e9e4e` — ``config: add `drag-handle` ``; `13ca032b1` — ``config: clear `command-palette-entry` like `keybind` ``                                                                                                                        |
| Input / keybinds, `src/input/**`                  |        20 | `bd647035e97d` — `input: don't emit fallback text on key release`; `aea70a5f7c48` — `core: implement backarrow key mode (DECBKM) - mode 67`; `8cfbaf545ab4` — `config: formatted action should be parsable into the original`                                                                                                                             |
| Shell integration                                 |        11 | `8e8d76b63` — `shell-integration: avoid owning temporary commands`; `484d6ec66` — `cli: add an ssh-wrapping +ssh action`; `283dca130` — `fish: replace ssh wrapper with ghostty +ssh`                                                                                                                                                                     |
| Termio / PTY                                      |        35 | `9566a1a87` — `termio: release initial input resources`; `ae6d97ea7` — `termio: avoid rescanning UTF-8 prefixes`; `6cadad06f468` — `termio: preserve UTF-8 in desktop notification truncation`; `2f0e6659d` — `termio: pipeline pty reads to overlap parsing with draining`; `ef7ecbd3e` — `termio: run Windows shell commands without a cmd.exe wrapper` |
| CLI, `src/cli/**`                                 |        23 | `d320cd7df` — `cli: fix list-themes preview lifecycle`; `a5550a2dc` — `cli: fix readEntries leak and double-free`; `8fca64957` — `cli: report ssh terminfo cache failures`; `69b9abf09` — `cli: version SSH terminfo cache entries`                                                                                                                       |
| GTK + macOS + Linux packaging — removed from fork | 324 union | **Irrelevant:** GTK 72; macOS 202; Linux packaging 34. Counts only; these paths are not merge targets.                                                                                                                                                                                                                                                    |
| Build / dependencies / Nix / CI                   |       161 | `e8525c0fd907` — `Update to Zig 0.16.0`; `1fe1b2d23` — `build: fix static libghostty-vt linking on Windows`; `49fd1ae65` — `build: default dependencies to lib-vt mode`; `619555d1c` — `pkg/wuffs: build without libc`; `29a70bc36` — `ci: publish wasm tip artifacts`                                                                                    |

The removed-platform union uses `src/apprt/gtk*`, `macos/**`,
`dist/macos/**`, `dist/linux/**`, `flatpak/**`, `snap/**`, and their two
packaging workflows. The build/dependency count uses root `build.zig*`,
`pkg/**`, `nix/**`, and GitHub CI workflow/support paths.

## Live conflict surface

Classification:

- **A** — pure rebrand, identifier, or documentation churn.
- **B** — Windows-platform adaptation.
- **C** — genuine divergent logic.

The buckets below are disjoint and total 165 files. Classification is based
on sampled fork diffs, not only filenames or line counts.

| Area                            | Live files | Fork-side class | Fork-side evidence                                                                                                                |
| ------------------------------- | ---------: | --------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Application / apprt / surface   |          5 | B, C            | Semantic-output transport, search generations, Job Object setup, initial PTY sizing, progress state, and automation actions.      |
| Benchmarks / examples / tests   |         13 | A, B            | `ghostty-vt` naming and Darwin-import guards needed for Windows builds.                                                           |
| Build / deps / CI / packaging   |         30 | B, C            | Windows-only build graph, Win32 runtime default, conditional lib-vt/custom shaders, and Windows CI/release jobs.                  |
| CLI                             |         18 | A, B, C         | Noctty naming, Windows console/editor/resource handling, local automation actions, and divergent dispatch/help logic.             |
| Config                          |         10 | A, B, C         | Rebrand plus Win32 defaults, Windows shell behavior, Job Objects, quick-terminal semantics, and removed platform fields.          |
| Docs / repository metadata      |          7 | A               | Project identity, ownership, contribution, and Windows-only policy.                                                               |
| Font                            |         11 | B, C            | Windows FreeType backend, registry discovery, deferred-face loading, and removal/guarding of CoreText/fontconfig paths.           |
| Input / keybinds                |          5 | A, B            | Win32 documentation/identity changes; `key_encode.zig` only removes an unused helper.                                             |
| Public libghostty-vt API        |          1 | A               | One fork documentation-line change; no fork-side ABI change.                                                                      |
| Renderer                        |          8 | B, C            | Win32 presentation/vsync, follow-up pacing, mailbox behavior, search ownership, shader gating, and renderer-wake timestamps.      |
| Shared runtime / OS / utilities |         21 | B, C            | Windows process launch, Job Objects, WSL/cwd behavior, WinMain/console paths, and queue semantics.                                |
| Shell integration               |          7 | A, B, C         | Noctty executable names plus PowerShell detection and injection.                                                                  |
| Terminal / VT core              |         23 | C               | Regex/whole-word search, async generations, semantic-output tracking, committed-codepoint state, and PageList integrity behavior. |
| Termio / PTY                    |          6 | B, C            | Windows shell/WSL/ConPTY launch, renderer wakes, semantic output, Windows OSC 7 conversion, and Job Object lifecycle.             |
| **Total**                       |    **165** |                 |                                                                                                                                   |

### Highest-risk individual files

1. `src/config/Config.zig` — fork churn is 1,925 lines and upstream churn is
   757; both sides change behavior and defaults, not only names.
2. `src/Surface.zig` — fork owns output transport, search generations,
   progress, initial sizing, mailbox lifetime, and Win32 Job Object wiring;
   upstream changed 1,588 lines.
3. `src/apprt/surface.zig` — fork adds fixed-memory output transport and new
   mailbox/search ownership to a shared apprt contract.
4. `src/renderer/Thread.zig` — fork changes mailbox backpressure, render
   follow-up pacing, wake semantics, cursor timing, and stale-search handling;
   upstream adds animation/compression scheduling.
5. `src/renderer/generic.zig` — fork changes Win32 present/vsync, search
   invalidation, shader gating, URL matching, and incremental cell uploads.
6. `src/termio/Termio.zig` — fork rewrites renderer-wake decisions and
   semantic-output capture while upstream changes streaming, Kitty, and
   scrollback behavior.
7. `src/termio/Exec.zig` — fork owns Windows PATH precedence, WSL/cwd,
   ConPTY buffers, PowerShell launch, and Job Objects; upstream changed 874
   lines.
8. `src/termio/stream_handler.zig` — both sides modify the same
   parser/dispatch path for semantic output, OSC/APC, renderer wakes, and
   UTF-8 handling.
9. `src/termio/shell_integration.zig` — fork adds PowerShell injection and
   tests while upstream changes command ownership and global/crash behavior.
10. `src/terminal/search/sliding_window.zig` — fork adds 1,449 lines of regex,
    case, whole-word, and boundary behavior; upstream also changes search and
    compression interactions.
11. `src/terminal/search/Thread.zig` — fork adds query generations/options,
    timer gating, forced refresh, row events, and mailbox semantics.
12. `src/terminal/PageList.zig` — upstream changed 8,834 lines across reflow,
    allocation, compression, and performance; even the fork's small integrity
    hook is in that core.
13. `src/terminal/Terminal.zig` — upstream changed 4,982 lines; the fork adds
    committed-codepoint state consumed by its semantic-output path.
14. `src/Command.zig` — both sides modify process creation, PATH/error
    handling, and cleanup; the fork additionally owns Job Objects and
    WSL-safe launch behavior.
15. `src/font/discovery.zig` — fork replaces discovery with a Windows
    FreeType/registry backend while upstream changes Windows discovery,
    backend interfaces, and warmup.

`build.zig`, `src/build/SharedDeps.zig`, and
`.github/workflows/test.yml` are also policy-led reconciliation points. They
are covered by the build/CI area rather than used to expand the requested
approximately 15-file list.

## Roadmap-named fixes

### Kitty keyboard protocol

`bd647035e97d` — `input: don't emit fallback text on key release` is the
actual Kitty key-release fix. It changes `src/input/key_encode.zig`. The fork
changed that file only by deleting the unused `copyToBuf` helper around a
separate later location; the upstream fallback and test hunks are trivially
non-overlapping.

There is no separate Kitty-flag change in this window:

- `src/input/key.zig` has only the repo-wide `e8525c0fd907` Zig 0.16
  migration.
- `src/terminal/kitty/key.zig` has zero commits in the window.
- The DECBKM series beginning at `aea70a5f7c48` implements xterm backarrow
  mode, not Kitty key release.

### UTF-8 and VT correctness

| Commit         | Subject                                                                   | Files                                                                                            | Fork status / result                                                                                                                                                       |
| -------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cb4c49fbf206` | `terminal: scalar UTF-8 decode consumes partial sequences cut off by ESC` | `src/simd/vt.zig`                                                                                | Fork unchanged, but direct patch fails because it depends on earlier upstream SIMD/libc++ changes.                                                                         |
| `aea63d71fe66` | `libghostty: fix utf-8 grapheme length overflow`                          | `src/terminal/c/render.zig`                                                                      | Fork unchanged; direct patch fails against pre-refactor C render API. Security-relevant and deferred.                                                                      |
| `997a2aff2afc` | `terminal: preserve pending wrap in VT formatter`                         | `src/terminal/formatter.zig`                                                                     | Fork unchanged and the patch applies, but it does not compile: it calls `PageList.Node.page()`, added by later upstream `PageList` work the fork has not merged. Deferred. |
| `6cadad06f468` | `termio: preserve UTF-8 in desktop notification truncation`               | `src/termio/stream_handler.zig`                                                                  | Fork modified the same handler for Win32 paths, semantic output, and wakes; direct patch fails.                                                                            |
| `c992658b2994` | `terminal/osc: decode OSC 52 base64 with the SIMD decoder`                | `src/terminal/stream_terminal.zig`                                                               | Fork unchanged, but the patch depends on the upstream VT/Zig sequence and does not apply.                                                                                  |
| `727b8a02f873` | `terminal: bound OSC and grapheme allocations`                            | `PageList.zig`, `Terminal.zig`, `osc.zig`, two OSC parser files, `page.zig`, `snapshot/grid.zig` | Fork modified the first five listed core paths; direct patch fails. Security hardening and deferred.                                                                       |
| `a8c3ab1915c9` | `simd: fix scalar base64 empty input handling causing a crash`            | `src/simd/base64.zig`                                                                            | Fork unchanged; read-only patch check passes. Crash fix, not a substantiated security fix.                                                                                 |

The July stream fast-path chain (`47e26df60f53`, `1a88f3622b50`,
`253e4f9c3c43`, `300f42c7a970`) begins by changing
`Terminal.zig`, `stream.zig`, `stream_terminal.zig`, and
`stream_handler.zig`. The fork modified `Terminal.zig` and
`stream_handler.zig`. Isolated later patches may apply textually but depend on
that first structural commit; the chain must stay together in the merge
window.

`src/terminal/Parser.zig` has only `0aa71d02ed06` —
`terminal: reduce Parser.Action log formatting code size`; it is not a
correctness fix. `src/unicode/**` has Zig migration/touchups and new lib-vt
width APIs, but no standalone Unicode correctness fix in this window.

### Renderer

| Commit         | Subject                                                                      | Files                                                   | Fork status / result                                                                                                         |
| -------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `ac67a6160c81` | `renderer: fix preedit range width`                                          | `src/renderer/State.zig`                                | Fork adds Win32 wake state before `Preedit`; upstream changes `Preedit.range` and tests. Separate hunks; patch check passes. |
| `9c9cf3e82174` | `renderer: avoid allocating when there are no active links`                  | `src/renderer/link.zig`                                 | Fork adds the built-in URL matcher; upstream adds `Link.active` and an early return. Separate hunks; patch check passes.     |
| `9e6e2ea96458` | `renderer: reset terminal state cleanup counter`                             | `src/renderer/generic.zig`                              | Fork changed the file heavily, but the upstream one-line reset is separate and patch check passes.                           |
| `14d9e600acf2` | `renderer: skip updateFrame when surface is not visible`                     | `src/renderer/Thread.zig`                               | Fork-owned Win32 scheduler path; direct patch fails.                                                                         |
| `d34b54e9b4ec` | `renderer: hand off state mutex to avoid starving frames`                    | `State.zig`, `generic.zig`, `src/termio/Exec.zig`       | All three fork-modified around wake/state/process ownership; direct patch fails.                                             |
| `446f80f4edd1` | `terminal: render state update optimizations (~2.7x to ~11x less lock hold)` | Renderer generic plus terminal/render/C/benchmark paths | Crosses `generic.zig`, `Terminal.zig`, and `render.zig`, all live conflicts.                                                 |
| `aee7bf347564` | `renderer: drive kitty graphics animation`                                   | `Thread.zig`, `generic.zig`, `image.zig`                | All fork-modified, including the Win32 follow-up scheduler and renderer error-propagation seam.                              |

Metal-only `4a22eed6d9e0` changes a renderer file deleted by this Windows fork. It
is irrelevant, not deferred live work.

## Security review

### CVE-2026-26982 is present at the base

The matching upstream fix is
`37e902d90e6c074e15d19e9e8b59036bf6264d18` —
`input: paste encoding replaces unsafe control characters with spaces`.
`git merge-base --is-ancestor` confirms that commit is an ancestor of both
the fork base and upstream `v1.3.0`.

The base version of `src/input/paste.zig` contains the actual fix:

- a strip table for NUL, BS, ENQ, EOT, ESC, DEL, VINTR, VQUIT, VKILL, VSUSP,
  VSTART, VSTOP, VWERASE, VLNEXT, VREPRINT, and VDISCARD;
- a replacement loop that changes those bytes to spaces before bracketed or
  unbracketed paste output; and
- tests for immutable, bracketed, unbracketed, and multiple unsafe bytes.

`Surface.completeClipboardPaste` passes paste data through
`input.paste.encode` and retries with a mutable copy when sanitization is
required. The fork has not modified `src/input/paste.zig` since the base. This
is code evidence, not an inference from the recorded version.

### Security-relevant commits in the window

| Commit(s)                                                                      | Classification                                                                                  | Files / fork status                                                                                                                                              | Disposition                                                                                |
| ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `64dcb91c1f3f` — Kitty graphics loading limits                                 | Security hardening: default-deny limits for file, temporary-file, and shared-memory image media | `Terminal.zig` and `Termio.zig` fork-modified; Kitty files otherwise unchanged                                                                                   | Deferred; prerequisite and core conflicts.                                                 |
| `28f4676b5d89` — renderer mutex before `processLinks`                          | Memory-safety fix; commit body identifies a scrollback-pruning race leading to UAF              | `src/Surface.zig`, fork-modified                                                                                                                                 | Deferred.                                                                                  |
| `ab82b8ab720c` — `Surface.setSelection` UAF                                    | Memory-safety fix                                                                               | `src/Surface.zig`, fork-modified                                                                                                                                 | Deferred.                                                                                  |
| `83027407e66e` — invalid Kitty command parser leak                             | Attacker-controlled resource leak / DoS hardening                                               | `src/terminal/apc.zig`, fork unchanged                                                                                                                           | Candidate slice; patch check passes.                                                       |
| `aea63d71fe66` — UTF-8 grapheme length overflow                                | Memory-corruption fix; ReleaseFast could write past the caller buffer                           | `src/terminal/c/render.zig`, fork unchanged                                                                                                                      | Deferred because the patch does not apply to the pre-refactor API.                         |
| `e44f5cb0fa1a` — zero-capacity `RefCountedSet` lookup                          | OOB-read hardening; upstream notes the case is not production-reachable yet                     | `ref_counted_set.zig`, `style.zig`, both fork unchanged                                                                                                          | Candidate slice; patch check passes.                                                       |
| `727b8a02f873` — bounded OSC and grapheme allocations                          | Resource-exhaustion / easy-DoS hardening                                                        | Five live terminal conflicts, including `Terminal.zig` and `osc.zig`                                                                                             | Deferred.                                                                                  |
| `a508720a89c5` — snapshot grid decode robustness                               | Untrusted-snapshot hardening, not a claimed vulnerability                                       | Snapshot files absent from the fork's older snapshot layout                                                                                                      | Deferred with snapshot feature merge.                                                      |
| `af2faa311a5a`, `e5840bb9bacd`, `ec04900ab957`, `f766f303a7d3`, `590d669c4a72` | Kitty temporary-path, geometry, opened-file, shared-memory-range, and PNG-allocation hardening  | Fork did not modify their surviving files, but every standalone patch fails because the series depends on upstream Kitty refactors; one C wrapper path is absent | Deferred as an ordered Kitty security series.                                              |
| `38e891e6c0bb` — title reports require opt-in                                  | Command-injection fix for libghostty-vt embedders that echo attacker-controlled titles          | C header/terminal/stream files fork unchanged, but direct patch fails                                                                                            | Deferred; it also changes user-visible opt-in behavior, excluded from the immediate slice. |
| `33d34cf5ce7b` — VS15 cursor underflow                                         | Memory-safety fix; ReleaseFast could compute an OOB cell pointer                                | `src/terminal/Terminal.zig`, fork-modified                                                                                                                       | Deferred.                                                                                  |
| `33cda4dc5dbf` — reload pointers after page growth                             | UAF-write fix for stale cell pointers                                                           | `src/terminal/Terminal.zig`, fork-modified                                                                                                                       | Deferred.                                                                                  |
| `77537c8065f3` — untrusted OSC 8 links                                         | Malicious-link handling                                                                         | Crosses fork-modified shared files and removed macOS code                                                                                                        | macOS implementation irrelevant; reassess only shared link-opening semantics.              |

No commit message in `base..upstream/main` contains the CVE identifier. The
CVE fix is pre-base. The table above came from keyword searches plus
inspection of plausible commit bodies and diffs.

The following are crash or correctness fixes, not substantiated security
fixes: `7fa6fffbca80` (resize subtraction panic), `1e63834cdc90`
(search-selection overflow panic), `e89ff37aa8a5` (snapshot encode invariant),
`cbc9f360b1d6` (snapshot decoder-state panic), `e20564791e53`
(mixed-optimization spacer-tail safety), and `a8c3ab1915c9` (empty scalar
base64 crash).

## Recommended immediate cherry-pick slice

### Gated slice — applied in the 2026-08 window

These seven commits meet the content policy for an immediate slice: they are
security-relevant or roadmap-named; none touches `src/apprt/**`; none changes
configuration defaults; and none introduces unrelated user-visible behavior.
The list is ordered chronologically and has no known cross-item dependency.

| Commit         | Subject                                                                    | Files                                                        | Why it is narrow                                                              |
| -------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| `83027407e66e` | `terminal: fix memory leak that could happen with invalid Kitty image cmd` | `src/terminal/apc.zig`                                       | Fork unchanged; self-contained parser cleanup and test.                       |
| `ac67a6160c81` | `renderer: fix preedit range width`                                        | `src/renderer/State.zig`                                     | Fork wake-state additions and upstream preedit hunks are separate.            |
| `e44f5cb0fa1a` | `terminal: guard RefCountedSet lookups against zero-capacity sets`         | `src/terminal/ref_counted_set.zig`, `src/terminal/style.zig` | Both fork unchanged; defensive OOB guard.                                     |
| `9c9cf3e82174` | `renderer: avoid allocating when there are no active links`                | `src/renderer/link.zig`                                      | Fork URL matcher and upstream active-link fast path are separate.             |
| `9e6e2ea96458` | `renderer: reset terminal state cleanup counter`                           | `src/renderer/generic.zig`                                   | One-line reset outside fork Win32-specific hunks.                             |
| `bd647035e97d` | `input: don't emit fallback text on key release`                           | `src/input/key_encode.zig`                                   | Actual roadmap Kitty release fix; fork only deleted a separate unused helper. |
| `a8c3ab1915c9` | `simd: fix scalar base64 empty input handling causing a crash`             | `src/simd/base64.zig`                                        | Fork unchanged; bounded scalar decoder fix and test.                          |

Each of the seven was applied with `git cherry-pick --no-commit -n <sha>` in an
index-writable worktree, inspected, and committed with a
`(cherry picked from upstream <sha>)` trailer. The slice was then gated with
`zig fmt --check src`, `zig build -Demit-exe=true`, and the full
`zig build test -Demit-test-exe=true` suite.

Those gates certify `83027407e66e`, `e44f5cb0fa1a`, and `a8c3ab1915c9`.
The renderer/input picks `ac67a6160c81`, `9c9cf3e82174`, `9e6e2ea96458`, and
`bd647035e97d` are not certified until the Windows 11 composite plus the
affected IME/key-input harness results required by the merge policy are
recorded. The current seven-commit stack therefore remains provisional as a
whole.

`997a2aff2afc` (`terminal: preserve pending wrap in VT formatter`) was the
eighth candidate. It applies without conflict but fails to compile:

```text
src/terminal/formatter.zig:599:37: error: no field or member function named
'page' in 'terminal.PageList.Node'
```

Upstream added `PageList.Node.page()` in later `PageList` work that this fork
has not merged. The pick was dropped rather than adapted, and moved to the
deferred list. This is the general rule: textual applicability is not
sufficient evidence; the build and full suite are the gate.

### DEFERRED TO NEXT MERGE WINDOW

| Group                                      | Commits                                                                                                        | Specific reason                                                                                                                                                                           |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| VT formatter pending-wrap fix              | `997a2aff2afc`                                                                                                 | Applies cleanly but needs `PageList.Node.page()` from unmerged upstream `PageList` work. Merge with the `PageList` slice, or backport the accessor.                                       |
| Critical UTF-8/VT security and correctness | `aea63d71fe66`, `cb4c49fbf206`, `c992658b2994`, `727b8a02f873`, `6cadad06f468`, `7cd2f65f5cb3`                 | Patches fail against upstream-dependent APIs or cross fork-owned `Terminal.zig`, `osc.zig`, `color.zig`, and `stream_handler.zig`. Adapt and test as a coherent core merge.               |
| VT fast-path chain                         | `47e26df60f53`, `1a88f3622b50`, `253e4f9c3c43`, `300f42c7a970`                                                 | Later patches depend on the first commit, which crosses fork-modified `Terminal.zig` and `stream_handler.zig`. Do not cherry-pick isolated optimization fragments.                        |
| Kitty graphics security series             | `64dcb91c1f3f`, `af2faa311a5a`, `e5840bb9bacd`, `ec04900ab957`, `f766f303a7d3`, `590d669c4a72`                 | Standalone patches fail because the fork predates the necessary Kitty refactors; apply in upstream order with protocol tests.                                                             |
| Title-report injection fix                 | `38e891e6c0bb`                                                                                                 | Direct patch fails, and opt-in title reports change user-visible policy. This is explicitly outside the immediate slice.                                                                  |
| Surface UAF fixes                          | `28f4676b5d89`, `ab82b8ab720c`                                                                                 | `src/Surface.zig` is a high-risk fork-owned seam for search, semantic output, renderer state, and Win32 lifetime.                                                                         |
| Terminal pointer/geometry safety           | `33d34cf5ce7b`, `33cda4dc5dbf`, `c5a3c7e2e5b4`                                                                 | Crosses fork-modified `Terminal.zig` or the renderer image error-propagation seam and depends on prior terminal/Kitty work.                                                               |
| Renderer scheduling and state              | `14d9e600acf2`, `25e624569143`, `d34b54e9b4ec`, `446f80f4edd1`, `cde7f93435eb`, `aee7bf347564`, `9490f7134215` | Conflicts with Win32 wake pacing, nonblocking mailbox behavior, dirty-row uploads, vsync/presentation, and error propagation in `Thread.zig`, `generic.zig`, `cell.zig`, and `image.zig`. |
| Kitty placement lifecycle                  | `6760c6482be2`, `d0c516f8f384`, `b5e86a42844e`, `b8222f4a8403`                                                 | Crosses fork-modified `renderer/image.zig` and depends on the upstream Kitty storage/pin model.                                                                                           |
| Zig 0.16 and build/dependency migration    | `e8525c0fd907` and dependent build work                                                                        | Repo-wide structural migration intersects the Windows-only build graph, lib-vt graph, packaging, Nix static validation, and CI. It is not an incremental fix pick.                        |

Nothing touching `src/apprt/**` is proposed. macOS, GTK, Metal-only, and Linux
packaging commits are deliberately left out rather than put in the live
deferred queue.

## Reproduce this analysis

Every figure in this report is pinned to the fork head analyzed on 2026-08-22.
Use that SHA rather than a moving `HEAD`, or the numbers will drift as the
branch advances.

```powershell
$forkHead = 'd031dc474efc4811e662a3e387e560fb760f0e19'
$base = git merge-base $forkHead upstream/main

git show -s --format='%H%x09%cs%x09%s' $base
git show -s --format='%H%x09%cs%x09%s' upstream/main
git rev-list --left-right --count "$forkHead...upstream/main"
Get-Content dist/windows/release-metadata.json

git tag --merged upstream/main --list 'v[0-9]*' `
  --sort=-version:refname
git for-each-ref --contains=$base --merged=upstream/main `
  --format='%(refname:short) %(objectname) %(creatordate:short)' `
  'refs/tags/v*'
```

The live overlap is `(fork ∩ upstream) − fork-deleted`. The maintained
implementation is `scripts/upstream-drift.ps1`; run it for the current head:

```powershell
pwsh -NoProfile -File scripts/upstream-drift.ps1
```

Its three inputs, if you want to recompute the pinned figures by hand:

```powershell
git diff --name-only "$base..$forkHead"                  # 1221 fork paths
git diff --name-only "$base..upstream/main"              # 880 upstream paths
git diff --diff-filter=D --name-only "$base..$forkHead"  # 696 fork deletions
```

Area counts and targeted inspection:

```powershell
$range = "$base..upstream/main"

git rev-list --count $range -- src/terminal
git rev-list --count $range -- src/renderer
git rev-list --count $range -- src/font
git rev-list --count $range -- src/config
git rev-list --count $range -- src/input
git rev-list --count $range -- `
  src/shell-integration src/termio/shell_integration.zig
git rev-list --count $range -- `
  src/termio src/pty.zig src/pty.c `
  ':(exclude)src/termio/shell_integration.zig'
git rev-list --count $range -- src/cli
git rev-list --count $range -- `
  ':(glob)build.zig*' pkg nix .github/workflows .github/scripts `
  .github/dependabot.yml .github/pinact.yml

git log --format='%H%x09%cs%x09%s' $range -- <path>
git show --name-status --stat <sha>
git diff --unified=3 "$base..$forkHead" -- <path>
git cat-file -t <sha>
```

Security search and base sanitization proof:

```powershell
git log $range --no-merges --regexp-ignore-case --extended-regexp `
  --grep='security|CVE|overflow|UAF|use-after-free|OOB|out.of.bounds|bounds|sanitiz|injection|panic|crash' `
  --format='%H%x09%cs%x09%s'

git show "$base`:src/input/paste.zig"
git merge-base --is-ancestor `
  37e902d90e6c074e15d19e9e8b59036bf6264d18 $base
```

Candidate gate and final cleanliness:

```powershell
git cherry-pick --no-commit -n $sha
git status --porcelain=v2 --branch
```

## Deliberate exclusions and residual risk

- No merge commit, no rebase of fork history, and no write to the `upstream`
  remote. The only source changes in the stacked sync branch are the seven
  gated cherry-picks listed above, each as its own commit.
- The `upstream` remote was not pushed and remains treated as read-only.
- Removed macOS/GTK/Linux paths were counted to explain drift, then excluded
  from the 165-file live surface and immediate slice.
- Config-default changes, unrelated user-visible behavior, repo-wide Zig
  migration, and all `src/apprt/**` commits were excluded from the slice.
- A patch applying textually does not prove that it builds. `997a2aff2afc`
  demonstrated exactly this and was dropped at the build gate.
- All seven picks were validated by build and the full test suite. The four
  renderer/input picks remain provisional because they were not validated by
  the required interactive runtime harnesses. In particular,
  `renderer: fix preedit range width` changes IME preedit cell suppression by
  one cell in the shared generic renderer; it is covered by unit tests but was
  not confirmed against a live IME session.
