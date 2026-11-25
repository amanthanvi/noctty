# 1A drift report: stepping stone → `main`

- **Report date:** 2026-11-25

## Identity

| Item                                  | Value                                                                                                                                                   |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Upstream base (the stepping stone)    | `74d0c72fd9318ad3ab95bfb56f6c2d995e267e2e` (2026-07-20)                                                                                                 |
| `main` before the landing             | `358ce0f6a`                                                                                                                                             |
| Gated tip (`stone-1a`, frozen)        | `f0a5dc507ad335ba08292a9e8202ea53bcfd1dee`                                                                                                              |
| Landing merge (`main` after)          | `f739b4c7bc2404ef1fe8837c425dc4090f542af7` (merged 2026-11-25 06:37:08Z), a merge commit of #748: first parent `358ce0f6a`, second parent the gated tip |
| Tree                                  | `2a50ea83a7b1567e5a77d5d3aabb6fce3379de6d`, equal to the gated tip's tree                                                                               |
| Upstream merge base after the landing | `74d0c72fd`; the next forward step (1B) moves the base to v1.4.0                                                                                        |

Below, `main` in a comparison (the accepted differences and the soak pairs) means `358ce0f6a`, the base
before the landing. P8-3 ran after the merge, but its `main` copies are the same `358ce0f6a` packages as P8-2's.

## What landed

- **1A.1:** the stepping-stone merge. 202 conflicted paths: 381 hunks in 81 content files, one row each in
  `plans/stone-1a/resolution-ledger.tsv`, and 121 modify/delete paths, counted in its header.
- **1A.2:** the review of the clean-merged files and clean hunks, and the thread-role layer's log entries and routing.
- **1A.3:** page serials and generations.
- **1A.4:** the post-stone audit of 244 upstream commits (`plans/stone-1a/post-stone-audit.tsv`), with the
  1A-relevant fixes forward-ported.
- **1A.5:** the thread-role checks and the thread-gate self-test split.
- **1A.6:** the gate batch:
  - the ledgers;
  - the ran-test floor;
  - the differential corpus;
  - path kinds;
  - the soak on the shared launcher;
  - the PKG-23 harness;
  - the test-config guard;
  - the click-pin fix.
- **lib-vt packaging:** unchanged by the landing; the portable ZIP keeps #688's signed `ghostty-vt.dll` stub
  (decision 35, `62e49dd8d`, already on `main`).
- **One forward merge of `main`,** through #747.

## Accepted differences from `main` (maintainer, 2026-11-23)

These are the five click-pin leftovers, recorded in `docs/agents/log/terminal-core.md` CLICK-PIN-01. The maintainer
accepted all five for 1A. The landing seats checked that each matches the code; they weren't asked to judge them (TD
C9, D83).

1. **After a scroll clear on a screen without scrollback** (ED 22 on either screen, or ED 2 at a marked prompt on
   the primary): a top-row selection or search highlight starts on
   the pre-clear history row. A Ctrl+click there opens the link under the pointer, as on `main`.
2. **A region below the top whose top row is page row 0:** the pressed column is kept, where `main` resets it to 0.
3. **A scroll region below the top with an SGR background:** pins move with their rows, so a Ctrl+click during
   output opens nothing. `main` doesn't move them.
4. **A top-anchored region above a status line:** the top-row pin stays on row 0, where `main` moves it into history.
   The click outcome is the same on both.
5. **libghostty-vt tracked grid refs and `SelectionGesture.left_click_pin`:** no `main` baseline.

## Plan deltas in force

The plan's Phase 0a delta, items 15–22, and the 1A gate's own deltas:

- 15: no interactive or visible test requirements;
- 16: the self-test split;
- 17: the debug-suite role run;
- 18: the pre-flight rulings and the floor's named exceptions;
- 19: the decision-25 rehearsal and the EvidenceMissing amendment;
- 20: the corpus;
- 21: the real-profile touches and the guard;
- 22: the no-bypass hold, and the landing by explicit merge commit with the squash and rebase settings left enabled;
- the paired soak gate (P8, TD D99-D108) and the lone-touch guard clause (D107).

## Evidence

**Carried by tree identity from the gated tip `f0a5dc507`** (the evidence index and the pre-flight table):

- **Suites:**
  - Debug suite: 7212/7289 passed, 0 failed.
  - ReleaseSafe suite: 7209/7289 passed, 0 failed.
  - lib-vt: 6086/6200 passed in final3, and 6084/6200 in the ran-list capture.
- **The ran-list compare, the ledger:**
  - The ran-list compare passes: 11 added, none removed.
  - The ledger regenerated against the tip matches the committed one.
- **The corpus, contracts and self-tests:**
  - The corpus classes are unchanged.
  - The flagship contracts pass.
  - The appending self-test passes 172/172. D26's 894/894 carries, because `ci/` changed only in README.md.
- **Hidden checks and PKG-23:**
  - The hidden checks pass.
  - PKG-23: 300/300 at col0, 300/300 at col3 on the alternate screen, and 30/30 at col3 on the primary at scrollback 0.
- **Working set and throughput:**
  - Working set: +0.6%.
  - Throughput: 15/16 on the first sample. The lock-wait metric passed D82's single rerun; the same binary moved +44%
    between sessions, so the band can't resolve that metric.
- **Packaging and the soaks:**
  - The packaged builds: ReleaseFast 0.0.3 and ReleaseSafe 0.0.4.
  - The two 8-hour soaks: night1 is the absolute soak of record (480 minutes each): ReleaseFast PASS, private
    slope +4.00 MB/h with a lower bound of +3.14 under the 4.19 floor; ReleaseSafe FAIL SLOPE, +6.48 with a lower
    bound of +5.33.
    - **Plan delta (TD D99-D108):** chain-2 showed the same churn-driven growth on `main` (+51.6 against the tip's
      +52.6 MB/h over 4 h, non-heap, on the OpenGL path), so the gate became paired: tip minus `main`, side by side
      for 8 hours.
    - **P8-2** (rule sha256 `c55b35b6f3164e50`, undisturbed): ReleaseSafe PASS, paired -0.20 MB/h with an upper bound
      of +0.14. ReleaseFast FAIL, +29.98 with an upper bound of +58.27. `main`'s ReleaseFast copy levelled off at
      about 215 MiB, the tip's at about 370, and `main`'s own ReleaseSafe copy at about 368. All four were flat over
      minutes 361-480.
    - **The maintainer waived the ReleaseFast failure for landing** (2026-11-25, D108 option A).
    - **P8-3** (ReleaseFast, the tip x2 and `main` x2, rule sha256 `9c3f44fee16f33e3`, undisturbed): PASS. The
      ceiling rule R1: the tip's minute 421-480 medians are 289.6 and 178.5 MiB against `main`'s 289.6 and 258.3,
      so neither tip copy sits above both `main` copies. The bounded rule R2: both tip copies are flat over
      minutes 361-480 (+0.65 and +0.90 MB/h, lower bounds -1.44 and -1.27).
    - **Observed:** across P8-2 and P8-3 the tip's three ReleaseFast ceilings are 370, 289.6 and 178.5 MiB, a
      192 MiB spread within one build, larger than the 155 MiB difference P8-2 failed on; `main`'s three are 215,
      289.6 and 258.3. Inferred: the ceiling is set per copy, not per build. Not shown: that there is no build
      effect smaller than that spread, with three copies per build.
- **Hosted runs at the tip:**
  - the PR-event runs, including Test 45173017558 and GUI Hidden Desktop 45173017745;
  - Windows 10 branches 45175879544, with the windows-2022 skip budget passing;
  - the Test dispatch 45179936394: attempt 2 passed, including the windows-2025 skip budget.

**Redone on the merge SHA:**

- **Test, push 45561987484: success** (every job that ran), with its artifact `flagship-portable-x64-45561987484`.
- **GUI Hidden Desktop, push 45561987608: failed twice** (attempt 2 was D92(e)'s one rerun) on one leaf,
  `cli-automation`, and only on its process audit. The other 6 leaves passed both times.
  - Attempt 1: 52 of 54 job processes read (1 not opened, 1 with its image unread); 26 noctty processes, 1 with
    its argv unread.
  - Attempt 2: 54 of 54 read; 27 noctty processes, 1 with its argv unread.
  - Both: 4/4 shells pass, 0 unaccounted, 0 outside the copy, 0 refused arguments, exit 0, no timeout.
  - The PR run 45173017745 at the identical tree, on the same image (win25-vs2026 20261116.315.1), passed it
    with every argv read.
  - The audit fails the leaf on any noctty process with no argv, and on any process it can't open or whose image it
    can't read
    (`gui-hidden-runner.ps1`). The second kind had already failed on `main` before the merge: push run
    44997457453 at `358ce0f6a` (2026-11-22), "session-restore FAIL (processes)", with 1 of 38 processes not
    opened and every noctty argv read, while three scheduled runs there passed.
  - Inferred, not shown: a short-lived noctty process exits while the audit reads it. TD D112: recorded, and the
    landing proceeds; `release.yml` needs only the Test run.

**Not required** (maintainer, 2026-11-22): the packaged Win11 composite. Typing latency (LAT-01/02) and frame-interval
p95 are therefore unmeasured for 1A.

## Recorded incidents

- **Flake:** `win32 IPC server start and stop cycles leak no handles` failed once in 45179936394 attempt 1, on
  windows-2025 (expected 340 handles, found 474), and passed on the rerun.
  - The same job passed on the PR-event run, on the same image. No cause was traced.
  - The test counts the whole process's handles. Isolating it is follow-up PR 2.
- **Foreign activity during the measurement windows:** an MSVC `link`/`vctip` process at 12:11Z on 2026-11-23,
  during the D82 rerun, from an unknown source.
  - No RDP or Chrome Remote Desktop connection was logged. Whether another remote-access tool was in use is
    unsettled.
- **Idle checks:** they see RDP sessions only. For the clicks, the direct evidence is the unchanged guards.

## Promotion gate (TD D108, D109, D111, D112, D114)

The gate added for the soak waiver is met:

- ~~a P8-3 pass~~: PASS (2026-11-25 16:12Z; see the soaks above);
- ~~the redone T-RS role compare~~: closed by TD D111 (ADVISORY, exactly night1's 12 pairs outside the table);
- ~~a passing GUI Hidden Desktop run on `main` at or after the merge~~ (TD D112): closed by the scheduled run
  45570413518 at `f739b4c7b` (2026-11-25 07:43Z, success).

Promotion still waits on the plan's prerelease soak: v1.3.139 was published on 2026-11-25 at 07:59Z, so the
window ends on 2026-12-02 at the earliest and 2026-12-09 at the latest. The go condition is no unexplained
regression in the 1A areas; shortening the window is the maintainer's call. The soak counts only for copies that
run 1.3.139, because the updater doesn't offer prereleases. At promotion, the stable-copy PR lands first, then
the release workflow's promote mode with the recorded candidate and manifest.

## Follow-ups (TD D95), after the hold is deleted

1. **A records PR** (no compiled code):
   - this report, under `plans/stone-1a/`;
   - the policy's base paragraph;
   - CLICK-PIN-01's wording;
   - the generator's `TIP` constant (the dropped-delta header stays at `5c7a99a13`: 24 of its 330 `tip:` ranges
     cover different text at `f0a5dc507`);
   - the PKG-23 README lines;
   - the plan deltas.
2. **A test-hygiene PR (#752):**
   - the IPC handle test counts only its own handles;
   - the PathKinds negative-control scratch moves out of `%TEMP%`, under the checkout's ignored `.zig-cache`;
   - the GUI process audit tells a process that exited before its argv was read from a live one it can't read,
     with a negative control that still fails the live case (TD D112);
   - the click-pin comments: `eraseRowBounded`'s "(main parity)" label in `PageList.zig`, the two "here"s in
     `Screen.cursorScrollRegionUp`, and the "leftover 2" test comment in `Terminal.zig`.

   It takes the full suite and a seat review.
