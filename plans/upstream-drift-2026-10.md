# Upstream drift analysis — October 2026

- **Analysis date:** 2026-10-30
- **Fork:** `amanthanvi/noctty`
- **Issue:** #141, C33 — upstream merge cadence and published merge policy
- **Scope:** the 2026-10 merge window for Ghostty v1.4.0: drift analysis,
  security review, ten subsystem sync PRs, and the deferred list

## Conclusion

Ghostty v1.4.0 (tag `v1.4.0` = `83fb95624b04`, 2026-10-27) is the first tagged
upstream release past the fork's base. The base does not move:
`ba398dfff3e3` (2026-04-05). v1.4.0's `build.zig.zon` declares
`minimum_zig_version = "0.17.0"`, and the fork is pinned to Zig 0.15.2, so the
tag can be neither merged nor rebased onto. This window is cherry-picks and
hand ports only. At `main` `11895f36e` the fork is **602 commits ahead and
2,734 behind** v1.4.0, on a **273-file live conflict surface** (192 in the
2026-09 window).

The window shipped as ten sync PRs, one per subsystem: tmux (#619), Kitty
graphics (#624), shell integration (#616), links (#625), terminal core
(#623), VT (#621), search and selection (#622), input (#618), misc (#620) and
render (#617). Each passes the full suite with zero failures on its own head.
All ten merged together on the local integration branch `w14/integration`
pass with **6132 passed, 74 skipped, 0 failed**, run before the links
round-2 fix joined that branch; #625's own run covers that fix (see
"Validation gates").

Fourteen advisories were reviewed: the 13 published with 1.4.0 and
GHSA-4jxv-xgrp-5m3r from March. Six reached fork code: the Kitty graphics
advisory (three of its five sub-issues), both tmux advisories, the OSC 7
directory-name injection, the `Capacity.adjust` row overflow and, by analog,
the 1-row line-limit use-after-free (the same cursor-page prune, reached
through tmux control mode and `cursorScrollAbove`). The two link advisories
are macOS flaws, but their Windows analog (an 8.3 alias of a dot-named file
passing the Win32 link gate) was likely reachable. This window fixes all of
them. Three were already fixed before the window (4jxv by upstream's fix at
the base, 4hwh by #163, w9q4 by #314), and three do not apply to a Windows
build. Details are under "Security review".

**Certified:** the renderer and input picks passed the interactive Windows 11
runs the policy names (the composite, the key-input harness and the
IME-candidate harness) on a visible desktop, on the local integration branch
(see "Interactive certification"): the Kitty renderer hunks of
`52190a5d8da4` and `c5a3c7e2e5b4` (#624), the `render.zig` picks
`4af7e19c7165` and `c9ad708ef77a` (#622), the key-encoding picks #12226,
#14508, #14144 and #14145 with their `windows_legacy` adaptations (#618), and
the preedit pick `5beb94c1620e` (#617). Two keypad fixes went into #618 after
those runs, after review; their re-run on `main` is pending (see "Merge
record").

## Snapshot identity

| Item                            | Value                                                                 |
| ------------------------------- | --------------------------------------------------------------------- |
| Fork head at triage             | `81acf0532d5b0dea92bbad6eba30bb9dfbdd9624` (`main`, #611)             |
| Fork head pinned for figures    | `11895f36e712ccc3e7ade45fda877971c889e6bc` (`main` after #614)        |
| Upstream head analyzed          | `83fb95624b0439ee660c2679b43b38c8b63769cd` (tag `v1.4.0`, 2026-10-27) |
| Previous window's upstream head | `09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8` (2026-09-03)               |
| Merge base (unchanged)          | `ba398dfff3e30ff83da07140981ca138410cf608` (2026-04-05)               |
| Ahead / behind                  | 602 / 2734 at `11895f36e` (600 / 2734 at `81acf0532`)                 |
| Newest upstream tag in range    | `v1.4.0`                                                              |
| Recorded `upstreamBaseVersion`  | `1.3.2` (unchanged; v1.4.0 needs Zig 0.17, the fork is on Zig 0.15.2) |

The triage ran against `81acf0532`. The slices were cut from a local commit,
`81acf0532` plus the SSH-config test-budget commit, then rebased onto
`11895f36e`, which is that commit squash-merged as #614 after the #613 log
batch. Every count below is pinned to `11895f36e` and `v1.4.0`.

The merge base did not move: no merge commit, no rebase of fork history.
`dist/windows/release-metadata.json` keeps `upstreamBaseVersion` at `1.3.2`
and `firstForkPatch` at `100`. A window can advance the base only after the
fork moves to the Zig version upstream requires.

### Snapshot freshness

The read-only `upstream` remote (push URL `DISABLED`) was fetched on
2026-10-30. `v1.4.0` is a tag, so the upstream side of every figure is stable.
`upstream/main` has moved past the tag. One port in this window comes from
after it: the viewer half of `7e4cc4fae011` (#619), which fixes a leak in code
the window ported.

## Upstream work since the base

Commit counts over `base..v1.4.0` by area, from
`git rev-list --count <base>..v1.4.0 -- <paths>`. As in the 2026-09 report,
the counts include merge commits, and areas overlap, so they do not sum.

| Area                                                              | Commits |
| ----------------------------------------------------------------- | ------- |
| `src/terminal`                                                    | 726     |
| build / dependencies / CI (`build.zig*`, `pkg`, `nix`, `.github`) | 504     |
| `libghostty-vt` (`lib_vt.zig`, `terminal/c`, `include/ghostty`)   | 258     |
| `src/renderer`                                                    | 81      |
| `src/termio`, `src/termio.zig`, `src/pty.*`                       | 77      |
| `src/config`                                                      | 71      |
| `src/font`                                                        | 52      |
| `src/cli`                                                         | 45      |
| `src/input`                                                       | 40      |
| `src/shell-integration`                                           | 15      |
| `src/simd`                                                        | 11      |
| GTK, macOS and Linux packaging (never merged)                     | 510     |

The range holds 2,734 commits (1,871 non-merge). 758 are new since the 2026-09
window's head (527 non-merge), and 223 of those non-merge commits touch an
eligible path. Most of v1.4.0's headline work is feature series and the Zig
0.16 and 0.17 migration: page compression and scrollback line limits, the
Kitty clipboard, drag-and-drop, animation and glyph protocols, the formatter
and parser speedups, and the `+ssh` action.

The triage started from the 1,871 non-merge commits. Those on eligible or
fork-relevant paths were split into 14 overlapping area lists (825 distinct
commits), reviewed by 15 agents (the VT list was split between two). Six
security groups covered twelve of the advisories, an adversarial verifier
re-derived each group's verdicts, and a completeness critic checked the
result against the release notes. It produced 306 candidates: 72 port
now, 87 port with adaptation, 82 defer and 65 skip.

## Live conflict surface

Raw path counts, computed with the policy's commands pinned to the two heads:

| Input                  | Count |
| ---------------------- | ----- |
| Fork-changed paths     | 1626  |
| Upstream-changed paths | 1178  |
| Raw intersection       | 512   |
| Fork deletions         | 733   |
| **Live overlap**       | 273   |

The live overlap is `(fork ∩ upstream) − fork-deleted`; 239 paths of the raw
intersection are fork deletions. It grew from 192 to 273. Holding either side
at its 2026-09 head gives 231 both ways: the fork's 359 new commits and
upstream's 758 each add 39 paths, and the two together add 81. By area:
`src/terminal` 55, `example` 24, `src/cli` 21, `src/renderer` 17, top-level
`src/*.zig` 15, `src/os` 14, `src/font` 14, `src/config` 11, `src/build` 11,
`src/input` 9, `pkg` 8, `src/termio` 7, `src/benchmark` 7,
`src/shell-integration` 6, `include` 5, `src/apprt` 4, and 45 elsewhere.

### Highest-risk individual files

Changed-line counts (added plus deleted) on each side since the base:

| File                                     | Fork | Upstream |
| ---------------------------------------- | ---- | -------- |
| `src/terminal/PageList.zig`              | 1005 | 9861     |
| `src/terminal/Terminal.zig`              | 1610 | 6572     |
| `src/terminal/render.zig`                | 7    | 5121     |
| `src/terminal/stream.zig`                | 231  | 4141     |
| `src/terminal/Screen.zig`                | 2760 | 4083     |
| `src/terminal/formatter.zig`             | 334  | 3042     |
| `src/Surface.zig`                        | 4347 | 2508     |
| `src/config/Config.zig`                  | 6165 | 1208     |
| `src/termio/Exec.zig`                    | 1972 | 992      |
| `src/renderer/generic.zig`               | 974  | 897      |
| `src/termio/stream_handler.zig`          | 1443 | 869      |
| `src/renderer/Thread.zig`                | 1253 | 378      |
| `src/terminal/search/sliding_window.zig` | 1449 | 226      |

`PageList.zig` is still the dominant seam: upstream rebuilt it around page
compression and line limits, and the fork's `Node` is still `data: Page`. The
`render.zig`, `stream.zig` and `formatter.zig` rows are upstream rewrites
(#13227, the parser fast paths, #13587) that this window defers.

## Security review

Every advisory published with v1.4.0, plus GHSA-4jxv-xgrp-5m3r from March.
Verdicts for twelve come from the triage's security groups, each checked by an
adversarial verifier that re-derived it from the fork's code, and from the
slice that acted on it. Where the verifier disagreed, its verdict stands and
the table says so. Two had no security group of their own, and no verifier
checked them: GHSA-3r5j comes from the Kitty area's triage, and GHSA-4jxv
rests on the paste group's code reading of #163's paste audit. An independent
GPT-6.1 Sol
(xhigh) applicability review agreed on the fixes ported here, but called the
link policy already handled and the line-limit use-after-free not applicable
(feature absent); the verifiers found the analogs behind both (GHSA-cw69,
GHSA-mfw9 and GHSA-qjfx below). Sol also raised the tmux layout recursion
depth and the TMP-only temp directory, both fixed here (#619, #624), and the
confirm-preview control characters, deferred with the GHSA-mxqx hardening.

| Advisory (upstream fix)                                                                                                                               | Fork verdict and evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Disposition                                                                                                                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GHSA-4jxv-xgrp-5m3r, CVE-2026-26982: control characters in paste and drop (`37e902d90e6c`)                                                            | Not vulnerable, by code reading (no security group of its own, no verifier). The fix is an ancestor of the base (`git merge-base --is-ancestor` exits 0), and the fork's paste-path audit kept and extended the strip table in `src/input/paste.zig`.                                                                                                                                                                                                                                                                                                      | Already fixed at the base; kept by #163 (`3b8c12ba5`).                                                                                                                                                                                                                                 |
| GHSA-4hwh-wx3w-3fqg: paste protection ignores CR (`5c9a3d8a9059`)                                                                                     | Not vulnerable. `input.paste.isSafe` has rejected a lone `\r` since `3b8c12ba5` (#163, 2026-09-03), with a regression test, and every paste route (Ctrl+V, menus, middle-click, drops, copied files, quick select, automation, insert-last-command) reaches that gate.                                                                                                                                                                                                                                                                                     | Already fixed by #163. Upstream's patch is not merged: its libghostty-vt paste API halves are absent and conflict.                                                                                                                                                                     |
| GHSA-mhff-mv4q-fp63: Kitty graphics, five sub-issues (`af2faa311a5a`, `e5840bb9bacd`, `ec04900ab957`, `f766f303a7d3`, `590d669c4a72`, `0b54463649ee`) | Three sub-issues vulnerable. (1) Temp path: `isPathInTempDir` compared byte prefixes, so a `%TMP%` sibling such as `...\TempX\` passed, and a `t=t` file there was read and deleted. (3) Opened file: the path was resolved, opened a second time and deleted by string, so a junction race, a symlink or a mapped drive could swap the target. (5) PNG: a ~100-byte PNG made the decoder request ~4 GiB before the size check. (2) Geometry was already ported between windows; (4) shared memory is compiled out on Windows (`error.UnsupportedMedium`). | Ported in #624: `af2faa311a5a`, `ec04900ab957`, `0b54463649ee`, `abd77067def1`, `590d669c4a72`, `8b90efd913ce`. Geometry: KITTY2 part 1 (#510), now with `afb61e1b6292`'s cursor bound. Shared memory: not applicable.                                                                 |
| GHSA-hcr9-7hcr-mjm8: tmux pane-state scroll region (`1a93d5395071`)                                                                                   | Vulnerable. tmux control mode is compiled into the app and entered from output (`DCS 1000 p`), with no gate. A forged region past the pane crashed a Debug test at `Screen.cursorDown`'s assert (measured); ReleaseFast has undefined behaviour.                                                                                                                                                                                                                                                                                                           | Ported in #619, with a fork boundary test.                                                                                                                                                                                                                                             |
| GHSA-hp9c-qp4q-cpw3: tmux zero or oversized panes (`1851e121baec`)                                                                                    | Vulnerable. A zero-size pane panicked in `PageList.initPages`, and a 70000-wide one at `initLayout`'s `@intCast` (measured, Debug).                                                                                                                                                                                                                                                                                                                                                                                                                        | Ported in #619; the zero guard is the first statement of `Terminal.init`. Fork-only analogs in the same PR: a layout nesting cap and control ids that overflow `usize`. The list-windows leak on rejection is upstream's post-tag fix `7e4cc4fae011` (viewer half), ported in #619.    |
| GHSA-w9q4-5jvv-mcv4: scroll clear keeps a pruned page's style IDs (`e257bb45e6d4`)                                                                    | Not vulnerable at this head. Fork `4beb2374b` (#314, PKG-03, 2026-10-10) fixed it 16 days before upstream, by releasing and re-adding the cursor's style and hyperlink around the prune.                                                                                                                                                                                                                                                                                                                                                                   | Already fixed by #314. #623 adapts only `e257bb45e6d4`'s garbage-flag clear, with a split-page regression test.                                                                                                                                                                        |
| GHSA-qjfx-r533-6vx3: 1-row line-limit use-after-free (`65ff54c67df3`)                                                                                 | Vulnerable by analog until `1a93d5395071`: the verifier corrected the triage's "not applicable". The exact flaw needs scrollback line limits (`5b2d3b7df184`), which the fork lacks; under byte limits the line-feed cursor is always on the last page, which is never pruned. But tmux control mode reached the same cursor-page prune: a pane-state scroll region drove `cursorScrollAbove` into it.                                                                                                                                                     | Analog closed by #619 (`1a93d5395071`). `65ff54c67df3` is deferred with scrollback line limits and must land with them. A fork-only `cursorScrollAbove` hardening is deferred too (see the deferred table).                                                                            |
| GHSA-2r63-vmw6-3m3c: OSC 7 directory-name injection (`6eb24a0f0f38`)                                                                                  | Vulnerable. Measured end to end in Git Bash: MSYS turns the U+F001-U+F01F characters of a Windows name back into raw C0 bytes in `$PWD`, so a checked-out directory ended the OSC 7 early and sent a real OSC 52. zsh by code reading (no zsh here or in CI).                                                                                                                                                                                                                                                                                              | Ported in #616; the bash hunk is adapted to the fork's Git Bash OSC 7 block. Residual: Git for Windows' own prompt (see "Maintainer decisions").                                                                                                                                       |
| GHSA-jqr7-69mm-v35h: `Capacity.adjust` row overflow (`84983d060db8`, merged as `0af5c9e55c5b`)                                                        | Vulnerable. The triage said "partially" (no snapshot API); the verifier showed output reaches it through tmux control mode plus DECCOLM. Three tests panicked with "integer does not fit in destination type" (measured).                                                                                                                                                                                                                                                                                                                                  | Hand-ported in #623, with a fork DECCOLM test.                                                                                                                                                                                                                                         |
| GHSA-3r5j-c6rj-xq2v: OSC 5522 `walias` memory (`44c4c8f55d49`)                                                                                        | Not applicable, from the Kitty area's triage (no security group, no verifier). The fork has only the OSC 5522 parser, not the Kitty clipboard protocol.                                                                                                                                                                                                                                                                                                                                                                                                    | Deferred: must ride with any future OSC 5522 port.                                                                                                                                                                                                                                     |
| GHSA-cw69-wm67-5pv8: OSC 8 targets opened on macOS (`77537c8065f3`, `f9e8ef02d7d2`)                                                                   | The macOS flaw is absent: every open goes through the Win32 gate `prepareWin32OpenTarget` (scheme allowlist, local-file policy; #163, #315). The verifier found a likely Windows analog: a dot-named file (`.cmd`, `.lnk`, `.url`) reached by its extensionless 8.3 alias (`CMD~1`) passed the gate. 17 such aliases were measured allowed; dispatch is inferred (one measured `CMD~1` dispatch started `OpenWith.exe`). Sol's independent review called the link policy already handled; the verifier's alias analog (likely vulnerable) stands.          | Fork-only hardening in #625, which fixes the alias analog (long-name screen, space and quote refusal, hidden-Unicode and host rules, four more blocked file types), plus the shared-core ports `77537c8065f3` (`link-osc8`, the `osc8` kind) and `f9e8ef02d7d2` (no generic fallback). |
| GHSA-mfw9-xcr3-7gfp: matcher links opened on macOS (`f9e8ef02d7d2`)                                                                                   | Same as GHSA-cw69: the fork never trusted matcher links, and a printed relative `.\CMD~1` was the easier Windows route to the same alias gap. Sol called the link policy already handled; the verifier found this alias analog (likely vulnerable).                                                                                                                                                                                                                                                                                                        | #625 fixes the alias analog, as above, plus `85dc4b184279` (links stop at prompt boundaries).                                                                                                                                                                                          |
| GHSA-v8cw-fg4j-jcc4: dropped text skips paste protection on macOS (`5580df6022d5`)                                                                    | Not vulnerable. Every Win32 drop format (CF_HDROP, CF_UNICODETEXT, CF_HTML, ShellURL, `WM_DROPFILES`) reaches `pasteFilePayload`, which applies the fork's paste-protection verdict and then the core gate.                                                                                                                                                                                                                                                                                                                                                | None.                                                                                                                                                                                                                                                                                  |
| GHSA-mxqx-236q-wrv7: macOS opens a file whose path hides control characters (`0c234a04d86f`)                                                          | Not applicable. No Windows path types a file path as input; the verifier overruled the triage's "partially". The nearest analog, a crafted CF_HDROP whose path holds C0 controls, is not this flaw.                                                                                                                                                                                                                                                                                                                                                        | Optional fork hardening (refuse such paths, show C0 in the confirm preview) is deferred.                                                                                                                                                                                               |

## The window's PRs

Each slice was implemented by an agent in its own worktree and reviewed by two
internal reviewers (correctness and simplicity), then by GPT-6.1 Sol with
sol-loop until Sol approved. Every port records its upstream commit
(`(cherry picked from commit ...)` for picks, an "adapted from upstream
commit" note for hand ports). Every fix has a test that fails without it,
unless its row says otherwise. The actual merge order is in "Merge record".
Slice-branch commit SHAs are not given: the branches were rebased and
squash-merged into their PRs.

### tmux (#619)

| Upstream                                  | Subject                                           | Adaptation                                                               | Tests                                   |
| ----------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------- |
| `a41248013194`, `9a4ba7d5480f` (#14262)   | list-windows action use-after-free                | Clean picks                                                              | "session changed resets state"          |
| `1ca2858d042f` (#14425)                   | pane mouse flags follow tmux's selectors          | Clean                                                                    | two-pane flow                           |
| `e8b858cc6697` (#14503)                   | unstored bytes do not count against `max_bytes`   | Clean; fork test for the `%` path                                        | 3 tests (OutOfMemory before)            |
| `968b2bf195c7` (#14671)                   | restore the active screen from pane state         | Tests without `io`                                                       | raw startup selects primary             |
| `8a7a91fbd6c8` (#14676)                   | parser state survives output notifications        | Tests without `io`                                                       | split CSI                               |
| `1a93d5395071` (#14680, GHSA-hcr9)        | ignore out-of-bounds pane scroll regions          | Production as is; fork boundary test                                     | upstream and fork tests; crash measured |
| `1851e121baec` (#14858, GHSA-hp9c)        | reject zero-sized and oversized panes             | `io` dropped; zero guard first in `Terminal.init`; snapshot hunk dropped | 4 layout tests; panics measured         |
| `7e4cc4fae011`, viewer half (post-v1.4.0) | free parsed layouts when list-windows is rejected | Hand port; upstream's test made to allocate                              | two leak tests                          |

Fork-only: `Layout.max_depth = 256` (4096 nested splits overflowed the 1 MiB
pty-reader stack, measured), and eight control-notification ids that overflow
`usize` are dropped instead of reaching `catch unreachable` (upstream main
still has these sites).

### Kitty graphics (#624)

| Upstream                                                                       | Subject                                                                       | Adaptation                                                                        | Tests                                         |
| ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------- |
| `1ae27f95b43e` (#12397), `8b90efd913ce` (#12469)                               | temp dir: trim separators; `GetTempPathW`                                     | POSIX hunk clean; no `randomTmpPath`                                              | TMP/TEMP seam test                            |
| `af2faa311a5a`, `ec04900ab957`, `590d669c4a72` (#13630)                        | temp file inside the temp dir; validate the opened file; PNG allocation limit | `TMP` seam instead of upstream's `Limits`; `std.os.getFdPath`; `LimitedAllocator` | sibling dir, swapped symlink, 32768x32767 PNG |
| `0b54463649ee` (#14189)                                                        | Windows path rules (UNC, device, reserved names, drive-absolute)              | `checkPath` calls `os.path.isNetworkOrDevicePath`, the one predicate              | UNC and symlink-to-share tests                |
| `a65e11cc928f` (#13389), `8524cb593c5f` (#13652)                               | transient hint; `d=p`/`d=c` cell containment                                  | KITTY2 eviction rules kept                                                        | each failed before                            |
| `afb61e1b6292` (#13887)                                                        | `C=0` cursor placement like Kitty                                             | Reverses KITTY2's "not taken"; fork keeps its rows-above-region count             | 6 tests                                       |
| `83145c0a3748`, `52190a5d8da4`, `c5a3c7e2e5b4`, `abd77067def1` (#13889-#13892) | `i=` with `I=`; source rect before sizing; offsets clamped; exact `S=`        | Renderer hunks in `prepKittyPlacement` (certified by the composite)               | each failed before                            |
| `e5747cf0b603`, `cfc5a96501d7`, `86d94f150a2c`, `306a169033cd` (#13893-#13898) | chunked-load lifecycle, `a=q`, response ids, unmatched `d=I`                  | Without `io`                                                                      | each failed before                            |
| `f8b40a02356f`, `f7d29b19e801` (#13895, #13932)                                | delete semantics to spec (ED 2); empty ranges are a no-op                     | Reverse KITTY2's "not taken"                                                      | 9 and 3 tests                                 |
| `242723223f3e`, `6b23c584cab5` (#13933, #13934)                                | unknown `f=` is EINVAL; auto ids never collide                                | `Image.implicit_id`                                                               | 13 and 4 tests                                |
| `3079a4396693`                                                                 | a non-direct transmit ends a chunked load                                     | Image arm only (no `a=f` in the fork)                                             | failed before                                 |

Fork-only: a `t=f`/`t=t` path longer than Zig 0.15.2's 32767-unit
`sliceToPrefixedFileW` buffer is refused before conversion (the Debug test
binary panicked; ReleaseFast writes past a stack buffer, inferred); `O=` now
seeks the reader (Zig's positional `File.Reader` ignored `seekTo`); a `t=t`
file is deleted through its validated handle (`os/windows.zig`
`deleteOpenedFile`), not by path; and, from Sol's first round, a drive-root
`TMP` keeps its separator. This PR reverses three "not taken" decisions of the
2026-10-20 KITTY2 ports recorded in the 2026-09 report: `afb61e1b6292`'s
cursor change, `f8b40a02356f` and `f7d29b19e801`.

### Shell integration (#616)

| Upstream                                | Subject                                       | Adaptation                                                                                                               | Tests                                                                                  |
| --------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| `6eb24a0f0f38` (#14859, GHSA-2r63)      | directory names cannot inject escapes         | zsh hunk as is; bash hunk by hand: strip at the final printf, control-byte drive paths go through `cygpath -m -- "$PWD"` | new `bash-shell-integration.ps1` case; pre-port, no-strip and no-routing variants fail |
| `7fa43764b0c6`, `71522c31143d` (#13310) | Nushell `@complete external` on `ssh`, `sudo` | Hand port onto the fork's wrappers; floor Nushell 0.108 documented                                                       | `nu --lsp` completion on 0.108.0 and 0.116.1 (manual)                                  |

No fork-only production fix.

### Links (#625)

| Upstream                                | Subject                                        | Adaptation                                                             | Tests                                    |
| --------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------- |
| `85dc4b184279`, `c4a671ba5a5c` (#12435) | links respect semantic prompt boundaries       | The PR's net one-line change; fork test                                | prompt run into command fails without it |
| `77537c8065f3` (#13634), core part      | `link-osc8` and the `osc8` link kind           | macOS Swift and header dropped; the key's doc names its two exceptions | OSC 8 link found with the gate removed   |
| `f9e8ef02d7d2` (#14683)                 | untrusted kinds get no generic opener fallback | Refusal unconditional: the generic opener exists only on Windows       | predicate test, never spawns             |

Fork-only, from the security group: the gate screens the name the folder
stores (`local_target.entryName`), so an 8.3 alias is classified by its long
name; a space or `"` in a non-file target is refused (it would split the
handler's command line); `.search-ms`, `.wsb`, `.ica` and `.wcx` are blocked.
From Sol's first round: targets with C0/C1, bidi, zero-width, line-separator
or BOM characters or invalid UTF-8 are refused (raw and in a decoded `file:`
path), `http(s)` needs a host and `mailto:` an address.

### Terminal core (#623)

| Upstream                                                                                                                         | Subject                                                                                 | Adaptation                                                                                                   | Tests                               |
| -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------------------- |
| `76b9bdb19993` (#12894)                                                                                                          | `Screen.select` frees existing pins (test)                                              | Clean                                                                                                        | old code: expected 4, found 6       |
| `cee35cabf69d`, `8d663a76e935` (#13220, #13226)                                                                                  | style ref-count work per run                                                            | Clean; performance                                                                                           | existing tests                      |
| `8307349ec5ff` (#13244), `c442eb4b3083`                                                                                          | capacity growth from zero; pool zeroing invariant                                       | Tests grow the page first (fork `compact` skips std-size pages)                                              | 2 tests                             |
| `0ff4e41b22b4` (#13275); `c753fe4a4f58`, `afbf5ba1564a`, `0cb004734eeb`, `a55850c981f2`, `b287f6d1ab98`, `04810273afc2` (#13278) | pin wrap, minimum deltas, empty clears, page widths, grapheme breaks, hyperlink id wrap | `node.data` spellings                                                                                        | each panicked before                |
| `7e14347c130c`, `65f953e8e82f`, `fedd42e8d66b` (#13294)                                                                          | page maps: bounded probes, backward-shift deletion                                      | Bench registration adapted                                                                                   | hash-map oracle tests, full suite   |
| `ee9d5b352f1b` (#13397)                                                                                                          | page capacity errors in `eraseRow`                                                      | `forCloneError` at every clone site; helper refactor not taken                                               | 2 failed before; 2 retry tests      |
| `b61fd5fbb683` (#13525), `5f5495826c7a` (#14081)                                                                                 | `RefCountedSet` iterator; living over-count                                             | Clean                                                                                                        | expected 2, found 3                 |
| `60b4a358548a` (#13515)                                                                                                          | CircBuf metadata after shrinking                                                        | Clean                                                                                                        | 3 tests                             |
| `727b8a02f873` (#13633), grapheme half                                                                                           | cap grapheme codepoints at 64                                                           | OSC half already in PKG-24                                                                                   | 3 tests                             |
| `a573781c6c2b` (#14449); `b10ba7ea2650`, `6dae79db9271` (#14552)                                                                 | Kitty placeholder flag; graphemes across widening wraps                                 | `lookupGrapheme` for `Pin.grapheme`; cursor reload after compaction                                          | panic and wrong slice before        |
| `a6a1a4664237` (#14838)                                                                                                          | pins on erased history rows are garbage                                                 | Adds `fixupViewport`'s flag clear from `5b2d3b7df`; #622 carries the search test flip (it rebased onto #623) | 2 tests                             |
| `84983d060db8` (#14856, GHSA-jqr7)                                                                                               | cap rows computed by `Capacity.adjust`                                                  | `@min` on the fork's bit arithmetic                                                                          | 3 panics before, incl. fork DECCOLM |
| `e257bb45e6d4` (#14857, GHSA-w9q4)                                                                                               | scroll clear: cursor pin flag                                                           | Flag clear only (#314 already fixed the advisory)                                                            | fork split-page test                |
| `4144f6dea4db` (#14631)                                                                                                          | demote a capacity log line                                                              | Clean                                                                                                        | none (log level)                    |

### VT (#621)

| Upstream                                                                                                                                                  | Subject                                                            | Adaptation                                                    | Tests                      |
| --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------- | -------------------------- |
| `c092b2bcf514`, `f1ca88da3731`, `7bb37580084b` (#12660); `9dc0d974e62d` (#14236); `3beb6d717ac3` (#14237); `d432b01a3e10`, `b21f82c0eaeb` (#14672)        | DECRQM: ANSI form, 16-bit modes, permanently reset                 | `inline for` test loops made runtime (comptime quota)         | lib-vt and termio tests    |
| `ff779564c61d` (#14668)                                                                                                                                   | ED 2 at a prompt skips blank rows                                  | Clean                                                         | failed before              |
| `6c6865092080` (#12487), `bb1f5908f8ba` (#13649)                                                                                                          | terminfo `Se`, `Smol`/`Rmol`                                       | Fork test checks the compiled entry                           | failed before              |
| `5dfb672986b5`, `6674aa3ba88e`, `3a766ccf501c`, `0fb6d29404aa` (#14128)                                                                                   | OSC 22 pointer shape after modifier overrides                      | Clean                                                         | fork `.pointer` test       |
| `53fb05c6eba4` (#14761), `42a65647b0ea` (#14652)                                                                                                          | CUB and BS stop at the left margin; DECAWM off clears pending wrap | Tests without `io`                                            | failed before              |
| `fbda61b873da` (#14673), `6104c78f1a12` (#14633)                                                                                                          | DECXCPR; CSI 19 t                                                  | Fork termio tests                                             | no reply before            |
| `1d5b6f90e527`, `fdd255c78201`, `a14a619ceb5d`, `dace6d1c6d4a`, `91f0cf67d51c`, `3d08161b5053` (#13278); `5caf20e3e580` (#13465); `ac4dc12056c1` (#13600) | title and pwd NUL reserve and aliasing; tab stops                  | Fork `FailingAllocator` test (upstream's passes with the bug) | panics and segfault before |
| `cb2fef39027b` (#13470), `f973bd53ba90` (#13653)                                                                                                          | DECRQSS keeps underline style, reports overline                    | `dcs.zig` test hunks dropped; termio test                     | failed before              |
| `f473f310979d`, `5169c473aa99` (#14538), `0df8c48688a1` (#14643)                                                                                          | DECSTR soft reset                                                  | Hand port; no XTCHECKSUM state; cursor style stays in termio  | dispatch and termio tests  |
| `0aaedf4360ff` (#13275), `82df0be2c752` (#14762), `d0c0d4008b0b` (#14644)                                                                                 | origin saturation; CHA/VPA/HPR/VPR origin-relative; TBC no param   | Arms hand-merged around fork lines                            | failed before              |
| `14c82988309b` (#13239, `osc.zig` hunk), `0aa71d02ed06` (#13715), `b5053153f409` (#13226)                                                                 | OSC color request leak; smaller log formatting; log once           | Leak hunk only                                                | leak test                  |
| `75a7606c3f19` (#14812), `b537282411ae` (#13702, `ApcEnd` part)                                                                                           | discard cancelled APCs                                             | Termio honours `ApcEnd.terminated` too (upstream's does not)  | lib-vt and termio tests    |
| `b7207b2ef6aa` (#14630), `dcaf6984ed54` (#14793)                                                                                                          | OSC 7501 revision 0.4 reply; limits on raw values                  | Termio answers with the 0.4 reply                             | failed before              |
| `73768913b478`, `500040d3b065` (#14417)                                                                                                                   | no digit separators or signs in OSC integers                       | `src/lib/parse_int.zig` with the Zig 0.15 body                | 7 parser tests             |
| `3263ce512248`, `97777cf5a32f`, `fd882c67cc3d` (#12953), `5170b06f6117` (#14416)                                                                          | OSC 133 `click_events=2`, prompt-relative rows                     | Clean chain                                                   | failed before              |

Fork-only: Clear Screen at a prompt above blank rows erased the scrollback
and then scrolled the screen back into it, because the ED 2 port scrolls
there (upstream v1.4.0 has the same order); `clear_screen` now erases the
scrollback again after its ED 2.

### Search and selection (#622)

| Upstream                                                                                                                                                                  | Subject                                                                                                             | Adaptation                                                                            | Tests                                    |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------- |
| `7b49d1f12928` (#12794), `bd365e1aa961` (#12936), `627518447395` (#13274)                                                                                                 | reset serial floor; selection drop; reset after resize                                                              | Resize reset also at the fork's matcher seam                                          | failed before (except the invariant pin) |
| `fa8cae88b25f`, `a9f5b7eba26e`, `6071606577d8`, `b6f34be44f8e`, `0c299000f805` (#13278)                                                                                   | mixed-width selection clamps; aliased pins                                                                          | Spellings                                                                             | each panicked before                     |
| `d239f9805666`, `5d8eb78b73c1`, `86e1f7b8b53e` (#13278)                                                                                                                   | drop pruned selections; reset pins; reject replaced pages                                                           | `pruneHistory` validates through one `LiveNodes` map per call, not per chunk (PKG-36) | panics and index tests                   |
| `83aada2056a5`, `f1a5fab45264`, `a89c6133c5be`, `89eca063e9f5`, `c243d89bdf78`, `c9ad708ef77a`, `91a63e5287c0` (#13282); `9659167ecd17` (#13307); `bc8bb6c0f030` (#13311) | page serials as generations; validate before reload; viewport fingerprints; flattened highlights; split source refs | Remaining renewals deferred; `c9ad708ef77a` in the fork's per-row loop (certified)    | integrity panics before                  |
| `a6a1a4664237` (test hunk)                                                                                                                                                | erased-history selection pins are garbage                                                                           | Carried here: #622 rebased onto #623, which merged first                              | assertion flipped                        |
| `f024d21fc46a`, `75302feda446` (#13543)                                                                                                                                   | no superfluous newline in HTML copy                                                                                 | Clean                                                                                 | expected 22, found 23                    |
| `c4f15c884a71` (#14354), `a3e80a685ed6` (#14391), `13b5ab2041fe` (#14553)                                                                                                 | word selection at hard breaks and wide chars; line selection at prompts                                             | Upstream's line test replaced (the fork selects blanks, PKG-52 G060)                  | failed before                            |
| `8d8b1ce00c5f` (#14632), `4af7e19c7165` (#14651)                                                                                                                          | wide char wrapped onto the next page: copy and render                                                               | Render hunk on the fork's whole-viewport loop (certified)                             | failed before                            |

### Input (#618)

| Upstream                                                                                         | Subject                                                       | Adaptation                                                                                  | Tests                                   |
| ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------- |
| `33111db3175e` (#14759), `157c44f643c9` (#14532)                                                 | `click_state` holds every button; UTF-8 in 1005               | Clean                                                                                       | failed before                           |
| `aea70a5f7c48`, `203895e3f76a`, `de4992c2b273`, `3a9ae7a0f` (#12226)                             | DECBKM (mode 67)                                              | `windows_legacy` Backspace keeps ignoring DECBKM: ConPTY applies it (read in its source)    | upstream tests plus a fork Windows test |
| `e55c687a4bdf` (#14508), `f4309055fbb8` (#13871)                                                 | Ctrl+Alt+Shift+Backspace; Kitty Alt+Backspace test            | macOS files dropped                                                                         | failed before; test pins behaviour      |
| `4406cea3e9fd` (#14144); `636a2f35b4a3`, `e7bdda9918a8`, `37e3cdd2d281`, `cc3fd8a77330` (#14145) | modifyOtherKeys 2: Ctrl keys, keypad, F25, Alt+Esc, Help/Menu | On `windows_legacy` a numpad key's layout text wins over the keypad row                     | failed before                           |
| `8cfbaf545ab4`, `b67f8ef51d80` (#13609)                                                          | formatted actions parse back                                  | Quoted through `std.zig.fmtString`; `palette-mru.txt` lines escaped, older lines still read | 3 tests                                 |
| `248df8e7aade`, `b1b01741f6c0`, `df44c6dd8344`, `5874ce633c8e` (#12579)                          | action parameter docs                                         | Values checked against the fork                                                             | docs only                               |
| `9689532cfff1` (#14710)                                                                          | report the release of a tracked click at a prompt             | Guard reads `left_click_count` (no `selection_gesture`)                                     | fork test                               |

Fork-only: the Win32 X buttons were mapped to buttons 4 and 5, which encode as
the wheel, so Back and Forward scrolled a program with mouse reporting; they
are now buttons 8 and 9 (measured before and after on a private desktop).

### Misc: config, CLI, termio, Surface (#620)

| Upstream                                                                                                                      | Subject                                                      | Adaptation                                                          | Tests                             |
| ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------- | --------------------------------- |
| `29b82dd80c46` (#13862), `13ca032b1de4` (#12682)                                                                              | `\xNN` escapes are bytes; `command-palette-entry = clear`    | Fork clone test uses `clear`                                        | failed before                     |
| `a181c386ca93`, `85083d23cd12`                                                                                                | config doc fixes                                             | Clean                                                               | docs only                         |
| `c5f4f00ed3e7` (#13938), part                                                                                                 | Valgrind-found test fixes                                    | `stream_terminal.zig` and `formatter_file.zig` only                 | no fail-first (dead stack reads)  |
| `a5550a2dcb8c` (#12811), `ac69942cdcc2` (#12814), part                                                                        | `+ssh-cache`: leak, double free, OOM slot, age overflow      | Fork `add` signature kept                                           | double free and panics before     |
| `297507f498ef` (#14834)                                                                                                       | config change writes the color-scheme report directly        | Before the Kitty limit loop; fork test drives `Termio.changeConfig` | 3 mutants fail                    |
| `05b46924ea4d`, `1e9b06f601d6`, `d7ea6284a620` (#14715)                                                                       | `Surface.init` frees renderer and termio configs on failure  | `renderer/Windows.zig` no longer frees it too (double free)         | env test; Surface by reading only |
| `c11fe5486f7c`, `f1d225020ae6`, `fb4c56159fe8`, `a9f7f6d212a0`, `5a8921ecb5bc`                                                | Surface allocation trims                                     | One comment-only conflict                                           | full suite                        |
| `f2571a3ec1ee` (#14706)                                                                                                       | pty and terminal resize together                             | Under the renderer lock, keeping PKG-14's catch-and-log             | conpty-sync 19/19 with Clink      |
| `c6e7e9e4e2fa`, `5ea45919d709`, `b5f5ca07892f`, `b9bc79de252c`, `b327d8d8eb68`, `f781b42db0f0`, `0fb89f4ffeba` (declarations) | accept `drag-handle`, two GTK keys, `scrollback-compression` | Declared with no effect, for configs shared with macOS and Linux    | failed before                     |

### Render (#617)

| Upstream                                         | Subject                                         | Adaptation                            | Tests                                                     |
| ------------------------------------------------ | ----------------------------------------------- | ------------------------------------- | --------------------------------------------------------- |
| `f3276131f10d` (#14300), `b15fe2eea007` (#14301) | glyph and codepoint cache keys as packed `u64`  | Clean                                 | A/B bench: 14.75 to 10.13 and 16.01 to 9.04 ns per lookup |
| `ca8868a2956d` (#13584)                          | no grapheme candidate allocations in the shaper | Test without `io`                     | behaviour pin                                             |
| `a3f3331d4df6` (#14420)                          | Nerd Font constraints in a 3-level table        | `Constraint` imported from `face.zig` | equal to the old switch over every `u21`                  |
| `5beb94c1620e` (#14230)                          | `font-thicken` reaches IME preedit text         | Clean (certified)                     | private-desktop pixel probe, with and without the hunk    |

Fork-only: `.gitattributes` marked the hand-written `nerd_font_attributes.zig`
as generated; it now marks the generated `nerd_font_tables.zig` (upstream
v1.4.0 has the same stale line).

## DEFERRED TO NEXT MERGE WINDOW

Slice deferrals, the lead's window-level deferrals, and triage deferrals that
no slice took. Upstream SHAs are abbreviated.

| Group                                                      | Commits                                                                                                                                                                                                                                                                                                                              | Specific reason                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Parser performance chain (window-level)                    | `47e26df60f53`, `1a88f3622b50`, `253e4f9c3c43`, `300f42c7a970`, `5b70f208bc68`, `a4f0d9f4a4cd`, `3d9b2b483cd8`, `f6f79acce6c2`, `8c523ed03919`, `afb351f8385d`, `f719af00c2f4`, `5ce1fe1ff9d5`, `8c5bc3d29f17`, `e51de8b58fab`, `cb4c49fbf206`, `083d9709be0d`, `c992658b2994`                                                       | CSI fast paths, bulk APC and OSC, the UTF-8 decoder rewrite, `printSlice` and the SIMD OSC 52 decode all rewrite `stream.zig`, `osc.zig` and the parser, which the VT slice changed this window, and the fork's `print()` differs in about 20 hunks. Take them as one parser slice, with Windows throughput numbers.                                                                                                                                                                                                                                                         |
| Reflow resize performance (window-level)                   | `4a88cc594829`, `c5ca2db1b6ef`, `c249b9de3496`, `179161c08119`, `46276d046ced`, `d4e446c4803d`, `ec5b369611ae`, `88ed6bebf4ab`                                                                                                                                                                                                       | Large, and needs `page.zig`'s `Mask` helper, which arrives with the deferred #13227.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Formatter speedup and the formatter fixes built on it      | #13587 (`b11d60818a8b`, `85b1dd0dd9a3`, `8838c37f4c60`, `79aa256fa26c`, `2ed67cadd1c5`); `510b253dbc52`, `152bdbc68075`, `bd1c9cc8cb2c`; `997a2aff2afc`, `bae1c01fc919`                                                                                                                                                              | The fork's formatter carries undo snapshots, Copy as HTML and PKG-53's final cursor pass. `152bdbc68075` changes which rows count as blank, which `terminalUndoTrailingBlankRows` must match. The pending-wrap fix means moving every screen extra into one final pass; the one-line `&node.data` spelling the 2026-09 report kept open is wrong (the reprinted cell would follow the restored pen and charset). One formatter slice.                                                                                                                                        |
| Selection text into string maps without a copy             | `f1948d50544c` (#13923)                                                                                                                                                                                                                                                                                                              | Performance only: it removes one allocation and copy in regex link detection. It conflicts in `Screen.zig` and crosses the `Surface.zig` link path that PKG-23 rewrote (`processLinks` under the renderer mutex).                                                                                                                                                                                                                                                                                                                                                            |
| Renderer state lock and mutex handoff                      | `446f80f4edd1` (#13227); `4f53b846bc19`, `d34b54e9b4ec` (#13265)                                                                                                                                                                                                                                                                     | Renderer-thread changes beside fork-owned `generic.zig` guards (`drawn_undirtied`, the search-highlight dims guard), conflicting in `generic.zig`, `State.zig` and `Exec.zig`. They need the composite, and #13265 first needs a Windows starvation measurement: PKG-38 found none, at startup only.                                                                                                                                                                                                                                                                         |
| Render-state `endUpdate` and C API reads                   | `e3056658d05b`, `74a233b5439c` (#13818, #13825)                                                                                                                                                                                                                                                                                      | Mostly libghostty-vt C API and wasm work. The Zig-side piece (`endUpdate` skips unchanged style runs) exists only after #13227 (row above), and `74a233b5439c`'s palette vectorisation works around Zig 0.16 turning off LLVM's loop vectorizer, which does not apply to 0.15.2. Reconsider after the renderer state lock.                                                                                                                                                                                                                                                   |
| Serial renewals for rows moved in place                    | `a804e3ac78b2`, `dd956f37cc81`, `0bad91adb84e`, `f6d9a582e415`, `d0a26d1460cf`                                                                                                                                                                                                                                                       | They change `cursorScrollAbove`, `insertLines` and `deleteLines` (KITTY2 margins, PKG-03 retries, `row_generation`), and the epoch rename reaches UIA `RowNumbering`, which needs reconciling. The one route that shrank a page under a cached chunk, a capacity split, is closed by `91a63e5287c0`. `d0a26d1460cf` is compression bookkeeping.                                                                                                                                                                                                                              |
| Scrollback line limits and the `scrollback-limit` rename   | `5b2d3b7df184`, `86f81fb5b1e4`, `10bc43420cef`, `f4c68d65e500`, `65c48213b6eb`, `1092204df19b`, `659a60ae53e9`, `65ff54c67df3`                                                                                                                                                                                                       | About 1,000 lines of `PageList.zig` on upstream's compression-era page model, plus Settings field-model and alias-aware save work. `65ff54c67df3` (GHSA-qjfx) must come with it.                                                                                                                                                                                                                                                                                                                                                                                             |
| Fork-only `cursorScrollAbove` hardening (GHSA-qjfx analog) | none (fork option)                                                                                                                                                                                                                                                                                                                   | The verifier asked for it. Its one input route, the tmux viewer's unchecked pane-state region, is closed by `1a93d5395071` (#619); DECSTBM rejects top >= bottom, and with the cursor at y >= 1 the prune guard keeps the cursor's page. It would guard a state no input reaches once #619 lands, so its value depends on the tmux slice.                                                                                                                                                                                                                                    |
| Page compression, page pool and memory reclaim             | `421fe8dabe58`, `0d015b2fcea5`, `25e624569143`, `0fb89f4ffeba` (its key is declared in #620); the `e01e75bbb228` series; `896aca499001`, `60b43068c5fc`                                                                                                                                                                              | Built on `Node.data` as a resident/compressed union and `src/terminal/mem.zig`, which the fork lacks. The Windows reclaim (`DiscardVirtualMemory`) would be a new fork-native decommit path and needs a before/after working-set measurement.                                                                                                                                                                                                                                                                                                                                |
| Copy-on-select values and `middle-click-action`            | `50e8ebaf6025`, `12ac19939c36`, `dfccdb2d4dfd`, `e80ce2ed4cc6`                                                                                                                                                                                                                                                                       | Crosses `Config.zig` and `Surface.zig` and needs Settings field-model changes. It would add `middle-click-action = ignore` and accept upstream's `none` and `both`, which the fork rejects today.                                                                                                                                                                                                                                                                                                                                                                            |
| Noto emoji refresh                                         | `28b5bf905986`                                                                                                                                                                                                                                                                                                                       | The embedded Noto fonts are the Windows emoji fallback. It adds about 0.8 MB and needs a glyph-rendering check on a visible run.                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Visibility reports (mode 2033)                             | `6c8c07981d7b`                                                                                                                                                                                                                                                                                                                       | A protocol feature that needs a Win32 visibility signal through `Surface`, termio and the renderer thread, all fork-owned seams, and Zig 0.16 APIs.                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `+ssh` and the port in the terminfo cache key              | `484d6ec66b0c`, `fff9f62f38cf`, `69b9abf09eba`, `b97e42691c44`, `2d112059a7e8`, `283dca130e02`, `e5378107eb8f`, `ac103b8f75f5`; `6fbb560cd3bf`, `dfd7bafcd3a0`; `c9d2285f63fc`, `13ada38ac45c`; the rest of `ac69942cdcc2`                                                                                                           | Needs a Windows design. The fork builds the cache key in six per-shell wrappers, and v1.4.0's `ssh.zig` uses `std.Io`. The port bug is real: two sshds on one address share a key.                                                                                                                                                                                                                                                                                                                                                                                           |
| bash-preexec 0.7.0                                         | `5d6615fc43ce`                                                                                                                                                                                                                                                                                                                       | Inert here: the fork sources it only for bash below 4.4, and every bash it injects on Windows is 5.x.                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Bundled theme refresh                                      | `59e565ea0be6` (#14835)                                                                                                                                                                                                                                                                                                              | 819 themes against 486. The palette catalog holds 768 items, of which themes get roughly 600, so about 200 would drop out of the palette without a message. Raise `palette_catalog_capacity` in the same change; the `.nix` mirror's hash needs a nix run.                                                                                                                                                                                                                                                                                                                   |
| Kitty: `OBJ_DONT_REPARSE` for `t=f`/`t=t`                  | none (fork option)                                                                                                                                                                                                                                                                                                                   | Would stop the SMB contact before the check, which upstream does not do either. Needs `apprt/win32/local_target.zig` moved out of apprt (terminal code cannot import it).                                                                                                                                                                                                                                                                                                                                                                                                    |
| Kitty: upload copy, loading limits, untaken tests          | `169213cd2924`, `b17abd96df2e`; `6a99c248d0c2`, `64dcb91c1f3f`, `306acc494128`; tests of `0b54463649ee`, `590d669c4a72`, `3079a4396693`                                                                                                                                                                                              | The copy fusion is performance only and changes upload ownership in both backends (needs the composite). Loading limits are embedder surface; termio sets `.all`. The tests need hooks or features the fork lacks.                                                                                                                                                                                                                                                                                                                                                           |
| Kitty feature series                                       | OSC 5522 (`e03475c0cc52` through `70f006575942`, `44c4c8f55d49`, `5350d4a5f597`, `a5bb22e235e6`); drag-and-drop and glyph protocol (`7c845e8af5b2`, `91c87e2cf324`, `d3775d1ed0a2`); OSC 99; animation and relative placements (`aee7bf347564`, `9490f7134215`); render state and generation stamps (`bdc0b6c19c95`, `17bc3e94a77e`) | Features, not fixes. OSC 5522 changes clipboard permission policy and needs Win32 multi-format clipboard work; GHSA-3r5j's fix rides with it. The renderer parts land in fork-owned `Thread.zig`, `generic.zig` and the D3D11 image path.                                                                                                                                                                                                                                                                                                                                    |
| tmux leftovers                                             | `1851e121baec` snapshot hunk; `7e4cc4fae011` control half; `7e7968826`, `c2d93620e`, `9a9208188`, `2ddcda8e8`, `cd00d09c6`                                                                                                                                                                                                           | No snapshot module. The control half rewrites notifications (`%window-close`) that arrived after v1.4.0. The rest is post-tag feature work.                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Core leftovers                                             | `ee9d5b352f1b` helper; `e257bb45e6d4` rewrite; snapshot hunks of `727b8a02f873` and `84983d060db8`; `d2ff6d77a05d`                                                                                                                                                                                                                   | The `clonePartialRowGrowCapacity` helper is a refactor (the fork's sites use `forCloneError` now). #314 covers the scroll-clear rewrite. No snapshot API. The trim loop needs upstream's cache-line layout.                                                                                                                                                                                                                                                                                                                                                                  |
| Resize failure safety                                      | `dde3d4d6b053` (#13367) and its `Terminal.zig` sibling `a3c1caba545e`                                                                                                                                                                                                                                                                | OOM-only robustness. `dde3d4d6b053` rewrites the error handling of `Screen.resize` (4 conflicting hunks, about 400 lines), which the fork has heavily changed: PKG-14's `keepRowActive` and `pull_scrollback`, CLINK-RESIZE-01's prompt-mark unmarking, the pending-wrap repairs and the saved-cursor ConPTY policy.                                                                                                                                                                                                                                                         |
| #13278 mixed-width remainder                               | `30b42f42a3b3`, `d6e24d985672`, `e727a36589df`, `cfce1cd56c33`, `9b466e9c5567`                                                                                                                                                                                                                                                       | Unreachable in the fork today: mixed-width pages exist only after an OOM-interrupted reflow, which the fork does not make failure-safe (row above); no production caller passes the current selection back to `Screen.select` or the current hyperlink to `startHyperlink`; `PageIterator`'s count limit has no production user; `30b42f42a3b3` needs more than 2^32 rows. Every one conflicts in production code. Take them with resize failure safety; #622 took `fa8cae88b25f`, `6071606577d8` and `0c299000f805` from the same group.                                    |
| VT leftovers                                               | `3822aa01d23d` and `73768913b478`'s `context_signal.zig` hunk; `73768913b478`'s `kitty_desktop_notification.zig` hunk; the rest of `14c82988309b` and `b537282411ae`; `f973bd53ba90` test hunks; `5169c473aa99`                                                                                                                      | A refactor of a parser that already checks digits (upstream v1.4.0 deletes `context_signal.zig`); a parser the fork lacks; libghostty-vt features (OSC color replies, unknown APC reports); tests that need `39ae85f040dd`; state the fork lacks (DECRQCRA, terminal-level cursor defaults).                                                                                                                                                                                                                                                                                 |
| VT features                                                | `714fe9b90373` (CSI 8 t); `9272a2f7c24a`, `00a19db51aee` (DECRQCRA/XTCHECKSUM); `77190bd02301`; `d1cd56a56c42`; `079502e23e2c`                                                                                                                                                                                                       | Off-by-default features that need Win32 window sizing or config keys in fork-owned seams; scroll-region and palette micro-optimizations that cross the KITTY2 margin port and termio.                                                                                                                                                                                                                                                                                                                                                                                        |
| Input leftovers                                            | `4406cea3e9fd`'s Win32 fallback; `587e08f3f` (#14146), `bd647035e` not evaluated                                                                                                                                                                                                                                                     | Under modifyOtherKeys 2 a real Ctrl+P still sends 0x10, because the Win32 runtime drops control text; that path runs only with mode 9001 off, which ConPTY turns on. The two others were seen and not evaluated.                                                                                                                                                                                                                                                                                                                                                             |
| Links leftovers                                            | macOS halves of `77537c8065f3` and `f9e8ef02d7d2`; the Surface half of the verifier's alias route test                                                                                                                                                                                                                               | Removed platform and an absent header. The route test's Surface half needs a Surface with a pane directory and the apprt; it would add only `existingPath`'s join, which keeps the alias spelling (read, not tested), and the apprt half is taken. Also left: the renderer's Ctrl+hover gates for `link-osc8` and at a prompt (renderer picks; upstream behaves the same), HTML copy anchors under `link-osc8 = false` (documented), a Settings row for `link-osc8`, a display sanitizer (no Windows hover preview), the symlink final-name policy, and `x.{CLSID}` folders. |
| Misc leftovers                                             | the rest of `c5f4f00ed3e7`                                                                                                                                                                                                                                                                                                           | Valgrind CI flags and suppressions (the fork's CI runs no Valgrind), and hunks written against `node.page()` and absent compression files.                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Shell leftovers                                            | none                                                                                                                                                                                                                                                                                                                                 | bash's `\w` title gap does not hold on bash 5.2 and later (caret text, measured in bytes). Strips for `COMPUTERNAME`, Clink's cwd, elvish and fish have no reachable input. A zsh harness would always skip (no zsh here or in CI).                                                                                                                                                                                                                                                                                                                                          |
| GHSA-mxqx Windows hardening                                | none (fork option)                                                                                                                                                                                                                                                                                                                   | Refusing control characters in dropped CF_HDROP paths and showing C0 in the confirm preview is optional hardening beyond upstream, not this advisory's fix.                                                                                                                                                                                                                                                                                                                                                                                                                  |
| libghostty-vt fixes no slice took                          | `38e891e6c0bb`; `82ae67b9f41a`, `d930c74c4d82`, `9a4787d90c03`, `a743c4e53ed6`; `dd2edd760da6`; `07af4612ba17`, `5b9a77f20386`; `b771a3d4f1a2`; `84254a9d8cb7`                                                                                                                                                                       | Embedder-only (`ghostty-vt.dll`): the app gates CSI 21 t behind `title-report` and uses none of these C paths. The title-report opt-in is the one security fix among them; it conflicts in the C header and `stream_terminal.zig`.                                                                                                                                                                                                                                                                                                                                           |
| libghostty-vt search and paste C API                       | `149c9f562af3`, `32601cd79a23`, `f0c918fc4b72`, `f9202919f719`, `76d9fcefef59`, `06178eeaad76`, `60a1ae2df755`, `da27e6c90827`                                                                                                                                                                                                       | As in 2026-09: they depend on `src/terminal/search/terminal.zig`, absent from the fork, and cross the fork-owned search seam; the fork's search `Thread.zig` keeps its own orchestration, which `149c9f562af3` extracts upstream.                                                                                                                                                                                                                                                                                                                                            |
| `+list-themes` TUI fixes                                   | `987f44260d10`, `d320cd7df28e`, `54ba7b1dd98d`, `7f1219fd7014`, `10f6eb4603a3`                                                                                                                                                                                                                                                       | Triaged "skip", which the completeness critic disputed: the fork's `+list-themes` still underflows on End with an empty search and indexes unguarded on Enter. No slice owned it; it needs its own small CLI change.                                                                                                                                                                                                                                                                                                                                                         |
| Apprt-bound features                                       | `25b2d8a38568` (move tab to new window), `8b7c57c75611`, `0a183c923bfc`, `ad96613a8c04`, `c4e16970a803`, `cde7f93435eb`, `c4e1ab8883ac`; the selection gesture (`d86ff37a58f7`)                                                                                                                                                      | Each does nothing without new Win32 code (tab tear-off, title prompt, inspector export) or collides with fork-owned seams (renderer cell storage, copy mode, UIA selection events).                                                                                                                                                                                                                                                                                                                                                                                          |
| Zig 0.16 and 0.17 line                                     | `e8525c0fd907` and the Zig 0.17 migration; `12542b392310` (Unicode 18); `d0e72a3ab654` (z2d 0.12); esctest (`438d584f0669`); `2f0e6659dd5f` (pipelined reader)                                                                                                                                                                       | Need the newer Zig, or are POSIX-only. esctest also needs a POSIX pty.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

Nothing touching `src/apprt/**` upstream is proposed. GTK, macOS and Linux
packaging commits are excluded rather than queued.

### Rows of the 2026-09 deferred table this window resolves

| 2026-09 row                                | Now                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| VT formatter pending-wrap fix              | `997a2aff2afc` re-evaluated in #622 and deferred again with a new reason: the residual one-line option is wrong (see the formatter row above).                                                                                                                                                                                                                                   |
| Renderer scheduling and state              | `14d9e600acf2` is superseded by fork code: `renderOnce` already returns before `updateFrame` for a hidden surface (#184's visibility-aware pacing). `446f80f4edd1` and `d34b54e9b4ec` are deferred again (#617). `25e624569143` waits for compression, `cde7f93435eb` for a wholesale renderer merge, and `aee7bf347564` and `9490f7134215` for the Kitty animation series.      |
| Input encoding and Surface lifetime        | Closed: adapted between windows on 2026-10-11 (2026-09 report).                                                                                                                                                                                                                                                                                                                  |
| RefCountedSet living-count fix             | `5f5495826c7a` ported in #623, with the iterator `b61fd5fbb683` its test needs.                                                                                                                                                                                                                                                                                                  |
| Scroll-clear cursor and hyperlink state    | `9313d580c6b0` was already carried by `4beb2374b` (#314, PKG-03).                                                                                                                                                                                                                                                                                                                |
| Row-storage recycling and page pool        | `b31fbc846474` was adapted in PKG-24 (`547bd5f72`) as `Page.resetRow`. `e01e75bbb228` stays with the page-pool row. `028af92ce387` only clarifies a libghostty-vt allocator fallback: skipped.                                                                                                                                                                                   |
| VT ground-state and OSC stream work        | `0f35043c9ac5` and `40a40f848dfc` are already in the fork (PKG-24). `8c5bc3d29f17` moves to the parser performance chain.                                                                                                                                                                                                                                                        |
| VT fast-path chain                         | Deferred again, in the parser performance chain.                                                                                                                                                                                                                                                                                                                                 |
| Critical UTF-8/VT security and correctness | `727b8a02f873` resolved: OSC half in PKG-24 (`547bd5f72`), grapheme half in #623. `6cadad06f468` was already adapted (PKG-27, `StreamHandler.utf8Prefix`). `aea63d71fe66` does not apply: the vulnerable getter came with `3cf01e84453c`, absent here. `c992658b2994` is a speedup, not a fix, and `cb4c49fbf206` belongs to the decoder rewrite: both move to the parser chain. |
| Kitty graphics security series             | `af2faa311a5a`, `ec04900ab957` and `590d669c4a72` ported in #624. `f766f303a7d3` and `090fca451d2c` do not apply (shared memory is compiled out). `64dcb91c1f3f` (loading limits) stays deferred as embedder surface.                                                                                                                                                            |
| Kitty clipboard, drag and drop             | Deferred again, with the Kitty feature series.                                                                                                                                                                                                                                                                                                                                   |
| libghostty-vt search and paste C API       | Deferred again, for the same reason (deferred table above).                                                                                                                                                                                                                                                                                                                      |
| Title-report injection fix                 | `38e891e6c0bb` deferred again: libghostty-vt embedders only, since the app gates CSI 21 t behind `title-report`.                                                                                                                                                                                                                                                                 |
| Terminal pointer and geometry safety       | `c5a3c7e2e5b4` and `52190a5d8da4` ported in #624 (renderer hunks certified by the composite). `33cda4dc5dbf` was already carried by `4beb2374b` (#314).                                                                                                                                                                                                                          |
| Kitty placement lifecycle                  | Unchanged: `6760c6482be2`'s pending payloads serve the snapshot API the fork lacks.                                                                                                                                                                                                                                                                                              |
| Zig 0.16 and build migration               | Deferred again; v1.4.0 now needs Zig 0.17.                                                                                                                                                                                                                                                                                                                                       |
| Vendored shell-integration upgrade         | `5d6615fc43ce` deferred again: inert for every bash the fork injects.                                                                                                                                                                                                                                                                                                            |
| Upstream issue #12600 changes              | `dfccdb2d4dfd` belongs to the copy-on-select and `middle-click-action` row.                                                                                                                                                                                                                                                                                                      |
| Font asset refresh                         | `28b5bf905986` deferred again.                                                                                                                                                                                                                                                                                                                                                   |

The 2026-09 report's "Adapted between windows" tables record that KITTY2 did
not take `afb61e1b6292`'s cursor change, `f8b40a02356f` or `f7d29b19e801`;
#624 takes all three. The 2026-08 report's security table left `77537c8065f3`
to "reassess only shared" code; #625 takes its shared-core part.

## Maintainer decisions

- **tmux control mode in the Win32 build: kept.** `tmux_control_mode` is
  compiled in and entered from program output, but no Win32 UI reads the
  viewer. The maintainer kept it, for a future tmux UI. In
  answer to spoofed output it writes fixed tmux commands (`list-windows`,
  `capture-pane` and others) to the child's stdin, and one crash it can reach
  stays open as upstream has it: a forged history reply trips
  `receivedPaneHistory`'s `runtime_safety` assert (measured in Debug;
  compiled out of ReleaseFast). Dropping the feature from the app build
  would remove all of it.
- **A per-pane cell cap for tmux: taken in #627.** A 65535x65535 pane
  passed upstream's checks and allocated about 34.4 GB up front (measured
  with production page sizes). #627 rejects a pane over tmux's own
  `WINDOW_MAXIMUM`, 10000 x 10000 cells, which goes beyond upstream. Within
  the cap a pane can still allocate about 1.0 to 1.7 GB up front, and a
  session can hold many such panes; a per-session limit is not taken.
- **Custom-scheme link policy: confirm.** Allowed schemes other than
  http, https and mailto (`ssh:`, `git:`, `tel:`, `magnet:`, `ipfs:`,
  `ipns:`, `gemini:`, `gopher:`, `news:`, `ftp:`) opened with one Ctrl+click
  when the window closed. The maintainer chose upstream's macOS policy: show
  the target and its handler, and open only after a confirm. It is
  implemented in its own PR after this window.
- **Git for Windows' `git-prompt.sh` title.** noctty's Git Bash injection
  sources `/etc/bash.bashrc`, which loads Git's prompt, whose title expands
  `$PWD` raw; a probe sent a complete OSC 52 through it. #616 closes only
  noctty's own emitter. Filtering or replacing that title means editing a
  user's `PS1`.

Smaller choices left to the maintainer: whether `link-osc8 = false` should also
drop OSC 8 anchors from HTML copies (#625 documents the exception), and the
four no-effect config keys that #620 adds to the All settings page.

## Validation gates

Every slice ran the policy's gates on its final head
(`scripts/check-zig-format.ps1`, `zig build -Demit-exe=true`,
`zig build test -Demit-test-exe=true --summary all`,
`scripts/check-source-format.ps1`), with every `zig build` through
`scripts/dev-windows.cmd`. The base, `main` `81acf0532` on an idle machine,
gave 5855 passed, 74 skipped, 0 failed.

| PR          | Full suite: passed / total, skipped, failed | Other evidence                                                                                                               |
| ----------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| #619 tmux   | 5876 / 5950, 74, 0 (no leaks)               | Fail-first per pick; crash and stack-overflow probes                                                                         |
| #624 Kitty  | 5936 / 6010, 74, 0                          | Fail-first per pick; Sol's second round approved the drive-root `TMP` fix                                                    |
| #616 shell  | 5855 / 5929, 74, 0                          | `bash-shell-integration.ps1`, 28 assertions, on pwsh 7.6.9 and Windows PowerShell 5.1; `Test-VerificationContracts.ps1` PASS |
| #625 links  | 5861 / 5935, 74, 0                          | `link-opener-pathext-probe.ps1` on a private desktop, 71/72 with 1 skipped                                                   |
| #623 core   | 5897 / 5971, 74, 0                          | Fail-first per pick                                                                                                          |
| #621 VT     | 5916 / 5990, 74, 0                          | First run on the same head: 1 load flake (below)                                                                             |
| #622 search | 5890 / 5964, 74, 0                          | `hidden-win11-docked-search.ps1` PASS on a private desktop                                                                   |
| #618 input  | 5878 / 5952, 74, 0                          | First run: 1 load flake (below); `hidden-win11-console-key-records.ps1` 36/36; `interactive-win11-mouse-input.ps1` PASS      |
| #620 misc   | 5863 / 5937, 74, 0                          | `interactive-win11-conpty-sync.ps1 -Clink` 19/19 in sync; `Test-VerificationContracts.ps1` PASS                              |
| #617 render | 5857 / 5931, 74, 0                          | Private-desktop preedit pixel probe; `Invoke-RendererParity.ps1 -PreeditCaretOnly` PASS                                      |

**Integration.** The local integration branch `w14/integration` merges all
ten slices; its commits are not cited, because the branch is local only. The
gates ran on three of its heads:

- The first merge of all ten: `scripts/check-zig-format.ps1` (765 tracked
  sources), the exe build and `scripts/check-source-format.ps1` passed. The
  full suite failed one test, search's "select after partial history erase
  drops a pruned selection": core's `a6a1a4664237` marks those pins garbage,
  so the test must expect that, as upstream's own test hunk does.
- That head plus the search test flip and Kitty's drive-root `TMP` fix: the
  full suite gave **6132 passed, 74 skipped, 0 failed** of 6206, and the
  standalone key-input and IME-candidate runs passed.
- That head plus the links round-2 fix: the composite passed (see
  "Interactive certification"). The round-2 fix's suite run is #625's own.

#622 carries the flip: it rebased onto #623, which merged first. "Merge
record" compares the integration branch's `src` tree with `main`'s.

**Known load flakes**, each passing on an immediate re-run with no change:
`config.windows_ssh_hosts` (a 50 ms read budget; seven failures on a loaded
`main`, fixed by #614), and the `apprt.win32_settings` test "settings shows
no light control in dark mode, and no dark one in light mode, at 100, 150,
200 and 300% DPI" (from #611). The latter failed once each in the VT and
input runs while about ten builds shared the machine; its own comment records
stale pixels in long runs.

Filtered `-Dtest-filter` runs served iteration and fail-first only; none
counts as evidence.

## Interactive certification

The policy certifies renderer and input picks only through the interactive
Windows 11 runs on a visible desktop. They ran on the visible desktop while
the maintainer was away (input idle for more than three hours), on heads of
the local integration branch described under "Validation gates". Logs are
the lead's local `/tmp/w14/cert/` files.

| Run                                                                                | Covers                                                                                                            | Tree                                                                                       | Result                                                                                                                                                                                                                                                                                                      |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `interactive-win11-validate.ps1 -ResetState` (composite)                           | Kitty renderer hunks (#624), `render.zig` picks (#622), preedit (#617); its key-input and IME leaves (#618, #617) | Integration head with all ten slices (links with its round-2 fix) and the search test flip | PASS, 369 s: smoke, first-frame, configured-size, shell-command, VT conformance (metadata), 9 key-input scenarios (all but `space`, which the composite does not run), IME candidate, new-tab, CLI automation, resize, undo, command-finish, progress; clipboard sequence 519 -> 519 (`composite-int2.log`) |
| The same composite, A/B control                                                    | The same leaves without the window's picks                                                                        | A tree whose code equals `main` `11895f36e`                                                | PASS, 370 s (`composite-main.log`)                                                                                                                                                                                                                                                                          |
| `interactive-win11-key-input.ps1 -ResetState`, all 10 `-Key` scenarios, standalone | DECBKM, #14508, #14144, #14145 and the `windows_legacy` adaptations (#618)                                        | Earlier integration head (before the links round-2 fix)                                    | PASS (`summary.txt`)                                                                                                                                                                                                                                                                                        |
| `interactive-win11-ime-candidate.ps1`, standalone                                  | `font-thicken` in preedit (#617)                                                                                  | Earlier integration head                                                                   | PASS (`summary.txt`)                                                                                                                                                                                                                                                                                        |

The first composite run, on the earlier integration head, failed one leaf:
`interactive-win11-key-input-classic-a` timed out after 20 s with no output
while another slice's full test suite loaded the machine. It did not recur:
the standalone `classic-a` run on that head and both later composites passed
it.

## Reproduce this analysis

Pin both heads; a moving `HEAD` or `upstream/main` drifts the numbers.

```powershell
$forkHead = '11895f36e712ccc3e7ade45fda877971c889e6bc'
$upstreamHead = 'v1.4.0'   # 83fb95624b0439ee660c2679b43b38c8b63769cd
$prevUpstream = '09ff85b2ac7b4204bbc48b5c7010adf0bdfb36d8'
$base = git merge-base $forkHead $upstreamHead

git show -s --format='%H%x09%cs%x09%s' $base
git rev-list --left-right --count "$forkHead...$upstreamHead"   # 602 2734
git show "$forkHead`:dist/windows/release-metadata.json"
git show "$upstreamHead`:build.zig.zon" | Select-String minimum_zig_version
```

Path inputs behind the live overlap:

```powershell
git diff --name-only "$base..$forkHead"                  # 1626
git diff --name-only "$base..$upstreamHead"              # 1178
git diff --diff-filter=D --name-only "$base..$forkHead"  # 733
```

Area counts, for example:

```powershell
git rev-list --count "$base..$upstreamHead" -- src/terminal   # 726
git rev-list --count "$base..$upstreamHead" -- `
  src/lib_vt.zig src/terminal/c include/ghostty               # 258
```

New-range triage and the security search:

```powershell
$range = "$prevUpstream..$upstreamHead"
git rev-list --count $range                              # 758
git rev-list --count --no-merges $range                  # 527

git log --no-merges --format='%H' $range -- `
  src/terminal src/simd src/font src/config src/config.zig `
  src/input src/input.zig src/shell-integration src/termio `
  src/termio.zig src/pty.zig src/pty.c src/cli src/cli.zig `
  src/lib_vt.zig include/ghostty src/renderer src/renderer.zig  # 223

git log $range --no-merges --regexp-ignore-case --extended-regexp `
  --grep='security|CVE|GHSA|overflow|UAF|use-after-free|OOB|bounds|sanitiz|injection|panic|crash|leak' `
  --format='%H'                                          # 25
```

The advisory texts are GitHub security advisories on `ghostty-org/ghostty`
(`gh api repos/ghostty-org/ghostty/security-advisories/<GHSA-id>`).

## Deliberate exclusions and residual risk

- No merge commit, no rebase of fork history, and no write to the `upstream`
  remote, whose push URL stays `DISABLED`. The base cannot move until the
  fork reaches Zig 0.17; `upstreamBaseVersion` stays `1.3.2`.
- The interactive certification ran on the local integration branch, not on
  `main`; it carries over only as far as the tree comparison under "Merge
  record" shows the same `src`.
- Some fixes rest on code reading, not a test: `Surface.init`'s config
  ownership and the `Windows.init` contract (#620), and every ReleaseFast
  consequence marked "inferred" above. Every fail-first result comes from a
  Debug test build.
- Picks that change what users see: ED 2 at a mid-screen prompt now scrolls
  into scrollback; DECSTR resets palette, margins and modes when a program
  sends `CSI ! p`; Kitty `d=A` and ED 2 keep scrollback images, auto ids start
  at 1, and `q>2`, `C=2`, `U=2` and `f=0` are accepted; unquoted `\xNN`
  config escapes are bytes; Back and Forward reach console-record programs as
  nothing (ConPTY 1.24 drops buttons 8 and 9); link targets with a raw space
  or quote are refused; Nushell older than 0.108 no longer loads the
  integration.
- Conformance replies (DECRQM's ANSI form, DECXCPR, CSI 19 t) reach a Windows
  program only where the bundled ConPTY forwards the query; in-box conhost
  answers some itself. Not measured through a live pseudo console.
- Upstream's page-map rewrite (#13294) changes every page's layout, and the
  search slice allocates a node-to-serial map on each 24 ms refresh of a
  complete search. Both rest on the full suite; neither was benchmarked on
  Windows.
- Rows shifted in place (other than a split's source) keep their page serial
  until the deferred renewals land, so a stale trailing search chunk can
  highlight shifted text until the search resets.
- Kitty `t=f`/`t=t` still contacts a share before refusing it, as upstream
  does; the deferred `OBJ_DONT_REPARSE` open would stop that.
- Since the window, the path-policy series closes that on Windows and
  diverges from upstream there: `readFile` opens through
  `os/local_path.zig` `open`, which refuses a share behind a link or a
  mapped drive before any SMB contact, and refuses a path that is not
  drive-absolute (relative, rooted or drive-relative), which upstream
  resolves against the process's current directory. The same open also
  refuses an alternate data stream (`C:\x\img.data:s`), a drive whose
  DOS name is not a direct volume device (a SUBST drive), and, behind a
  link, a name with a reparse tag that is no link and no cloud
  placeholder (WOF, dedup); upstream's open loads all three. The
  maintainer approved these three as fail-closed on 2026-10-30, matching
  the link opener's measured SUBST refusal (the 2026-10-30 PATH-POLICY
  part 5 entry in docs/agents/log/terminal-core.md). The next window's
  report should carry this divergence.
- Of the maintainer decisions above, Git's prompt title stays an open risk,
  and the custom-scheme confirm is open until its PR lands.

## Merge record

Every PR was squash-merged after its CI went green on a branch up to date with
`main`. The table is in merge order.

| PR   | Slice                                    | Squash commit | Merged (UTC)     |
| ---- | ---------------------------------------- | ------------- | ---------------- |
| #614 | SSH config tests' read budget (pre-work) | `11895f36e`   | 2026-10-30 09:39 |
| #616 | Shell integration                        | `15d7520eb`   | 2026-10-30 12:22 |
| #619 | tmux                                     | `10e496b05`   | 2026-10-30 13:20 |
| #620 | Misc: config, CLI, termio, Surface       | `cc2f4aaa0`   | 2026-10-30 13:46 |
| #623 | Terminal core                            | `51db2ed5f`   | 2026-10-30 14:17 |
| #621 | VT                                       | `69cd3a059`   | 2026-10-30 14:45 |
| #622 | Search and selection                     | `51e2024dd`   | 2026-10-30 15:18 |
| #624 | Kitty graphics                           | `30d5da909`   | 2026-10-30 16:21 |
| #617 | Render                                   | `f1158e2e9`   | 2026-10-30 16:55 |
| #627 | tmux pane cell cap (maintainer decision) | `c8f078dfd`   | 2026-10-30 17:32 |
| #618 | Input                                    | `d165457ae`   | 2026-10-30 18:10 |
| #625 | Links                                    | `06d74d256`   | 2026-10-30 18:37 |

Final `main` after the window's last code merge: `06d74d256`.

Merges between slices needed three hand resolutions, the same ones the
integration branch needed:

- #621: `Terminal.zig` kept both #619's zero-size test and #621's tab-stop
  test.
- #622: `Screen.zig` kept both #623's and #622's selection tests. #622 also
  carries upstream `a6a1a4664237`'s test flip, because #623 landed first.
- #618: `Surface.zig` kept both #621's `promptClickRelativeRow` and #618's
  prompt-click test.

**`src` tree compared with the certified integration branch.** `main`'s `src`
differs from the integration head the composite certified in six files only.
All six differences are fixes made after review, each with a fail-first test:

- `terminal/kitty/graphics_image.zig`, `graphics_storage.zig`: refuse an `S=`
  larger than the file before allocating, and free the images of pruned
  placements on ED 2 (Greptile on #624).
- `input/key_encode.zig`: the numpad layout text under modifyOtherKeys 2, and
  Alt's ESC prefix on the ConPTY path (Greptile and Sol on #618).
- `apprt/win32/palette_controller.zig`: keep the spaces at the ends of a palette
  MRU key, and a line whose last backslash would escape the closing quote
  (CodeRabbit on #618).
- `terminal/tmux/layout.zig`, `viewer.zig`: the 10000 × 10000 pane cap (#627).

`input/key_encode.zig` is key encoding, which the policy certifies through the
interactive run. A re-run of the composite and the key-input harness on `main`
is **pending**: it needs the visible desktop while the maintainer is away, and
the maintainer was at the machine when the window closed.

## Follow-ups from review

Review bots (CodeRabbit, Greptile, Sourcery) and the sol-loop reviewer raised
these points. Each was checked against the code and declined in its PR with a
written reason, mostly because the fork's code is identical to upstream
v1.4.0's. They are recorded here so the next window, or an upstream report,
can pick them up.

| Area     | Point                                                                                                                                                                                                                | Raised on | Why not here                                                              |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ------------------------------------------------------------------------- |
| Config   | `RepeatableCommand.formatEntry` writes an empty value for a cleared `command-palette-entry`, which now restores the defaults on reload; emit `clear` first                                                           | #620      | Upstream-identical; changes `+show-config` output for every config        |
| PageList | `cloneRowGrowCapacity` grows capacity mid-shift and `increaseCapacity`'s deferred `assertIntegrity` can fire (Debug only, pinned viewport)                                                                           | #623      | Upstream-identical; needs its own reproducing test                        |
| Screen   | Selection endpoints that `eraseHistory` marks garbage are neither dropped nor clamped                                                                                                                                | #623      | Upstream behaviour; the pins stay in live pages                           |
| CircBuf  | `empty()` is false for a buffer resized to zero                                                                                                                                                                      | #623      | Upstream-identical; no production caller resizes to zero                  |
| Bench    | `HyperlinkMap` benchmark: `--entries` 16 or 32 cannot hold one link, and 32768 overflows a u16 cast                                                                                                                  | #623      | Benchmark-only, upstream-identical                                        |
| OSC 133  | `click_events=2` should use a secondary prompt (`k=s`) at or above the click as the relative-row origin, as Kitty does                                                                                               | #621      | Upstream-identical; changes reported rows                                 |
| Parser   | `Action.format` at depth 1 hides CSI params and intermediates in the unimplemented-action log                                                                                                                        | #621      | Upstream's deliberate binary-size trade-off (#13715)                      |
| Tests    | `stream: invalid CSI t` still sends `19t`, which #14633 made valid                                                                                                                                                   | #621      | Upstream-identical test                                                   |
| Kitty    | POSIX `allocTmpDir` trims `TMPDIR=/` to an empty path                                                                                                                                                                | #624      | Never compiled into the Windows app; Windows' `C:\` case is fixed in #624 |
| Input    | A palette action holding a NUL collapses to the same C-string MRU key as its prefix                                                                                                                                  | #618      | Upstream contract; user-config input only                                 |
| Input    | DECBKM has no Alt+Backspace alternative in the function-key table                                                                                                                                                    | #618      | Upstream table; a protocol choice for upstream                            |
| Input    | Ctrl+numpad digit with text goes through `ctrlSeq` on the ConPTY path and sends a C0 byte                                                                                                                            | #618      | Unchanged from before the window; needs a live conhost comparison         |
| Links    | `local_target.entryName` needs `FILE_LIST_DIRECTORY`, so a document in a folder that denies listing is refused; find a stored-name query that needs neither listing nor symlink resolution (`FILE_NAME_INFORMATION`) | #625      | Fail-closed by design; a typed-name fallback reopens `setshortname`       |
| Shell    | Nushell's `@complete external` sets a 0.108 floor                                                                                                                                                                    | #616      | Upstream v1.4.0 ships the same floor; documented                          |
| Palette  | `appendInstalledThemesToPalette` silently drops themes past the 768-slot catalog; raise it before the bundled-theme refresh                                                                                          | #620      | Found while deferring the theme refresh                                   |
