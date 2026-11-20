# Differential terminal oracle

This implements migration-plan sections 3.3 and 3.4. It captures the active
terminal screen and retained history through `TerminalFormatter` after feeding
the same frozen corpus into each side's `Terminal`: the fork's app profile and upstream's public lib-vt profile. It opens no window or
PTY and uses no clipboard, shell integration, application configuration or user
state.

The gate is **no untriaged differences**. A difference is evidence for review,
not proof of a regression or permission to discard fork behavior.

## Build and freeze inputs

Run the repository's required quiet-window guard before **every** build, test
or harness command below. Use `scripts/dev-windows.cmd` for pre-cutover builds and a VS
developer shell with an explicitly addressed compiler for Zig 0.17.1. Keep build
roots and their Zig global caches on the same drive. Use task-owned scratch
copies and caches; never build in a retained read-only plan tree.

An oracle invocation selects only the `oracle` step. Its argument allowlist is
`-Dvt-api=`, `-Doracle-corpus=`, `-Doracle-scrollback=`, `-Dsimd=`, `-Doptimize=`,
`-Dcpu=`, `-Dcustom-shaders=` (where defined), `--prefix` (or `-p`), `--summary`,
and `-jN` for a positive job limit. Set `ZIG_GLOBAL_CACHE_DIR` for a scratch cache on the source drive.
The guard checks the original Windows Zig driver invocation during each
configuration, before compiling project code or dependencies. It refuses every
`ZIG_*` variable in its environment except `ZIG_GLOBAL_CACHE_DIR`,
`ZIG_LOCAL_CACHE_DIR`, `ZIG_HOME` and `ZIG_VERSION`. The last two are used
by `dev-windows.cmd` to select and check the compiler. Identity is based on
the selected compiler's contents. Zig 0.17.1 uses `ZIG_PROGRESS` for progress reporting
and removes it when spawning the guard. The guard also refuses `CPATH`,
`C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH`, `OBJC_INCLUDE_PATH`, `LIBRARY_PATH`,
`LINK`, `_LINK_` and every `CCC_*` variable, including
`CCC_OVERRIDE_OPTIONS`. Probes on both compilers found no effect from
`INCLUDE`, `EXTERNAL_INCLUDE` and `OBJCPLUS_INCLUDE_PATH` on the tested C
source or from `NIX_CFLAGS_COMPILE` on the tested executable. Separate
cold-build probes with `CL` and `_CL_` produced identical oracle executables.

From the repository root:

```text
scripts\dev-windows.cmd zig build oracle -Dvt-api=fork -Doracle-corpus=true -Dsimd=true -Doptimize=ReleaseFast -Dcpu=baseline -Dcustom-shaders=true --prefix BUILD_DIR --summary all
```

Use a fresh `BUILD_DIR` outside the source tree (or a gitignored prefix), so
build outputs do not dirty the captured checkout. Build the generator only in
the pre-side source copy. Run `BUILD_DIR/bin/oracle-corpus.exe` by its absolute
installed path, with a fresh scratch directory as its working directory. It writes
`synthetic.bin`, using `src/synthetic`'s `Bytes`, `Utf8`, and `Osc` generators:

- Seeds: `0`, `1`, and `0xC0FFEEEEEEEEEEEE`, independently reset per generator.
- Bytes and UTF-8: 4,096 bytes per seed.
- OSC: 16 requests with a 256-byte maximum each, separately with `p_valid=1`
  and `p_valid=0`; all other weights are the generators' defaults.

Run the generator twice in separate directories and compare `synthetic.bin`
byte for byte. Freeze the corpus **once for each migration gate**, before
capturing any of its sides:

```text
python test/differential-oracle/oracle.py prepare --repo PRE_TREE --synthetic SYNTHETIC_BIN --out FROZEN_DIR
```

`prepare` counts the tracked files in `test/fuzz-libghostty/corpus`, requires
4,001 seeds by default (the tracked `sanitize-filenames.sh` is excluded) (`--expect-fuzz` makes a future intentional count explicit),
and freezes their committed blob bytes into JSON. It refuses tracked or untracked changes. It does not strip the stream
fuzzer's mode-selector byte or apply the parser/OSC fuzzers' calling convention.
Preparation and capture refuse explicit non-direct Kitty graphics media so
replaying the corpus cannot load image data from host paths. Direct payloads,
with an omitted medium or `t=d`, remain eligible.
It also freezes all `src/terminal/testdata/replay/*.vt` fixtures consumed by
`src/terminal/resize_replay.zig`. IDs retain corpus subdirectories, even when
two seeds have equal bytes. Source digests and generator seeds are recorded.

Replay inputs retain `send` and expanded `seq` bytes, the ConPTY no-pull flag,
and all subsequent absolute `resize` dimensions. Each starts at **80x24** and
**132x43** instead of the fixture's original `size`; that original size is
recorded. Later resizes are not scaled. The final size may therefore differ
from the initial-size label. `expect` and `cursor` directives remain assertions
of the existing replay tests; this tool does not evaluate them. These captures
compare terminal semantics under the recorded operations, not ConPTY runtime
or the original fixture's golden expectations.

## Capture each tree

For fork, stone and the eventual 1B app, the root `oracle` step inherits the
app module's generated Terminal options, imports, include paths, C macros and
link dependencies. After the guard passes, the oracle adds a private C/C++
macro throughout its linked module graph. Its value is the SHA-256 of the
actual Zig executable, computed during configuration. The hash keys the
oracle's own C/C++ objects through the macro and its Zig code through the
embedded build identity. Zig's global `compiler_rt` cache identifies the
compiler by version string alone. Different binaries reporting the same
version can share `compiler_rt` when the target and lib sources match, so
use a separate `ZIG_GLOBAL_CACHE_DIR` for each binary when comparing them.
Oniguruma, Kitty graphics and tmux control mode remain selected by that
tree's own app build.

The upstream side is **v1.4.0's public lib-vt module**, exactly as section 3.4 names it.
Staging `--api v140` connects the harness to that module and its own generated
option module. Its measured Windows defaults disable Oniguruma and tmux, while
**Kitty graphics remains enabled**; every other public feature default is also
preserved. Do not substitute app options or disable features to make profiles
match. The v1.4.0 app graph unconditionally includes POSIX `pwd.h` and cannot
build on Windows; that blocker belongs to the **1B Windows app port**.

Both paths record target, CPU model and named features, optimization, and all
generated Terminal options, including artifact and version fields. Equivalent
optimization levels use the same profile names across the API lines. Compare
refuses undeclared profile differences; each actual difference must be named
with a reason as described below. Dependency failures stop that side rather
than selecting another profile.

Select the Terminal API explicitly with `-Dvt-api=fork|stone|stone_flag|v140|v140_fork`.
The choice never depends on compiler version or std-origin feature detection.
`fork` and `stone` use the legacy IO adapter, with positional and structured
resize respectively; `stone_flag` is structured resize **with** the ConPTY flag
(the trial-theirs 1A API shape); `v140` and `v140_fork` use the modern IO adapter with
structured and positional resize respectively. Stone has no ConPTY no-pull
flag, so that flag is not emulated: record this limit when reviewing replays.

For a clean task-owned copy without the harness, run:

```text
python test/differential-oracle/stage.py SOURCE_TREE --api stone
```

Stage applies only instrumentation, retaining the original production revision
and exact root-build delta in `staged-source.json`. It also adds the Git
configuration flags to the four version queries. Commit that overlay locally
before prepare/capture. Capture verifies the clean tree and both build-file deltas.
Manifest provenance distinguishes production and instrumented commits. Build
with that side's compiler, explicit API, SIMD on, ReleaseFast and baseline CPU.
Only the fork accepts `-Dcustom-shaders=true`; read the other side's own app
build options. The generator is needed only on the pre side.

At **1A**, if the resolved Terminal API takes structured resize options,
change the CI oracle step from `-Dvt-api=fork` to **`-Dvt-api=stone_flag`** when
it retains `resize_pull_scrollback`, or **`-Dvt-api=stone`** when that flag is absent.
Keep the legacy IO adapter until 1B.

At the **1A tip**, before the 1B cutover deletes the legacy generator, build and
run that tip's generator twice, freeze its corpus, and record its SHA-256.
Keep the frozen `corpus.json` and both generator outputs outside the source
trees in a retained gate directory, for example `EVIDENCE_ROOT/1b-corpus/`.
Use that exact `corpus.json` for the 1A-tip, 1B and v1.4.0 captures and pass its
recorded hash as `--expected-corpus` on every 1B gate comparison. Do not silently
reuse Phase 0's `synthetic.bin`; generate the 1A-tip inputs before deletion.

At **1B.3/1B.5**, delete these whole files:

- `src/differential_oracle_adapter_legacy.zig`
- `src/differential_oracle_corpus.zig`

In `.github/workflows/test.yml`, change the **Build app-profile differential
oracle (no capture)** step from `-Dvt-api=fork` to **`-Dvt-api=v140_fork`** for
the retained positional-resize 1B API. If the resolved 1B API uses structured
resize, use `-Dvt-api=v140` instead. Reuse the retained **1A-tip frozen corpus**; stop building the
legacy generator. The build rejects legacy API/generator selection on a modern
compiler with a clear error. For a modern **app** build, the always-run identity
step also refuses either retained legacy file by checking its actual presence,
even if its comment is edited or its code is unreferenced. The upstream public
module can retain the canonical source bundle; it is not a post-cutover app.
These executable contracts do not rely on doc comments. Also run
`residue_gate17.py` on the cutover tree.

```text
python test/differential-oracle/oracle.py capture --corpus FROZEN_DIR/corpus.json --exe ORACLE_EXE --source-root SOURCE_TREE --out DUMPS_DIR --work RUN_DIR
```

Both output directories must be fresh. `capture` requires a completely clean source,
records production/instrumented revisions, executable and harness source hashes, and runs the executable twice in
separate working directories. No previous outputs are reused. Binary requests,
responses and diagnostics stay under `RUN_DIR`; their stdout/stderr are not
echoed. A failure, crash or timeout fails capture and preserves partial evidence.
The timeout defaults to 900 seconds **per run**, not a performance criterion.
The build embeds the build tree's Git HEAD and dirty flag through an always-run
identity generator whose working directory is the actual build root. Build,
staging and capture Git queries use an explicit source root and a subprocess
environment with all `GIT_*` entries removed. The queries set
`-c core.ignoreStat=false -c core.fsmonitor=false`. Build identity and capture
require the source root to equal Git's worktree top-level. They refuse
tracked entries marked assume-unchanged or skip-worktree. Python
must be available for this optional build step. Capture requires that identity
to match the clean `--source-root` HEAD, validates API/ConPTY policy, and checks
that the source and executable remain unchanged during both runs. A stale exe,
wrong tree or dirty build is invalid evidence. Compare also refuses one exe
hash attributed to different production or instrumented revisions.
The identity also includes SHA-256 for the actual Zig driver executable and
for a deterministic path-and-content manifest of its effective lib directory,
including std, libc headers and compiler runtime sources. The hashes are
recomputed on every build. Capture and comparison require both hashes.
Recapture older evidence that lacks them before using it for admission.
Identity generation verifies the paths and pinned hashes of the packages the
**build graph actually resolved**, on both compilers, including the global
cache. Oracle builds refuse `ZIG_LOCAL_PKG_DIR` and options
outside the allowlist, including `--pkg-dir`, `--search-prefix`, `--sysroot`,
`--libc`, `--system`, and `-fsys=PACKAGE`. They compute Zig's SHA-256
package tree hash read-only, without `zig fetch` copies, archives or temporary
package directories. Hashes are checked against build-graph pins, not directory
names. Extra files or unsupported reparse points fail closed. Unhashed local
package wrappers must be inside the authenticated source tree. Git ignores
cached dependencies; their edits must not masquerade as a clean build.

Git can report LF-pinned files that retain CRLF as clean, and the reviewed
cases preserve dump content. The scrollback limit belongs only to the
comparison profile, and both the profile and the build identity omit the
host MSVC and Windows SDK versions.

The request and response have checked versioned headers, counts, lengths,
ordered record indices and exact EOF. For each input/initial size, both plain
and VT output are saved without newline conversion. Formatting keeps soft
wraps and trailing spaces (`unwrap=false`, `trim=false`); plain uses no extras
and VT uses `TerminalFormatter.Extra.all`. Scrollback is explicitly limited to
the app's shipped **10,000,000-byte (10 MB)** default on both API versions.
The full corpus measured 58,899,721 dump bytes per run at this limit, below the
1 GB budget. `-Doracle-scrollback=BYTES` is an explicit experimental override;
it is recorded and needs a shipped-profile mismatch declaration on fork sides. The formatter covers only the active screen,
including its history, as the API documents; it is not a complete terminal
state serialization (for example, it does not dump inactive-screen contents).

`run-1/manifest.json` and `run-2/manifest.json` map readable input IDs, sizes
and formats to safe numbered filenames, lengths and SHA-256 hashes. The driver
requires every saved dump and both manifests to be **byte-identical**, then
writes `determinism.json` and finally `completion.json`. The completion record
binds both identical manifests, the corpus, harness sources, full profile,
executable and source provenance. Failed or nondeterministic runs retain partial
evidence but receive no completion record. Compare and native-controls recheck
both runs and hash **both raw manifest files**, refusing byte-only rewrites as
well as missing, corrupt or mismatched completion with exit 2.

Admission also compares the captured harness hashes with the running tool's
sources. To declare an intentional instrument change explicitly, pass
`--declare-harness-change OLD:CURRENT` to compare/native-controls; each value is
the SHA-256 of `json.dumps(harness_sources, sort_keys=True).encode()`.
Declarations do not bypass profile, corpus, provenance, determinism or dump checks.
Every comparison requires `--expected-corpus SHA256` to pin the baseline corpus. Keep large dumps and their frozen corpus outside the
repository.

Compare pins corpus **content**, independently of its origin revision. A pre
capture from a later authenticated revision (including the 1A tip for a 1B
comparison) is accepted when it used the same pinned corpus. `source_revision`
records where the inputs originated; it does not restrict which revision can
occupy the pre slot. Pre and post must have distinct production revisions; the
branch's own capture cannot serve as its pre baseline, even with a different exe
or instrumented commit. The required `--expected-corpus` must be a nonempty
64-digit SHA-256 and match the admitted corpus bytes. Compare records
`corpus_sha256` and `expected_corpus` in the report. Report
manifest/completion hashes describe the exact bytes used during admission,
including when a run is reached through a junction alias.

## Compare and triage

```text
python test/differential-oracle/oracle.py compare PRE/run-1 BRANCH/run-1 --expected-corpus CORPUS_SHA256 --report PAIR.json
python test/differential-oracle/oracle.py compare PRE/run-1 BRANCH/run-1 UPSTREAM/run-1 --expected-corpus CORPUS_SHA256 --report TRIAGE.json
```

An intentional profile difference requires `--declare-profile-differences
DECLARATIONS.json`. The file is a JSON array; each row contains exactly `side`,
`option`, `old`, `new` and a nonempty `reason`. `side` is `branch` or `upstream`, compared with
`pre`; `option` is a dotted path in the recorded profile. For example:

```json
[
  {
    "side": "upstream",
    "option": "terminal_options.oniguruma",
    "old": { "present": true, "value": true },
    "new": { "present": true, "value": false },
    "reason": "v1.4.0 public lib-vt disables Oniguruma"
  },
  {
    "side": "upstream",
    "option": "terminal_options.tmux_control_mode",
    "old": { "present": true, "value": true },
    "new": { "present": true, "value": false },
    "reason": "v1.4.0 public lib-vt derives tmux support from Oniguruma"
  }
]
```

The example covers only those two differences. A real declaration must name
**every** measured difference, including artifact, version fields and options
present on only one side. Compiler content differences use
`build_identity.zig_exe_sha256` and `build_identity.zig_lib_sha256` as option
names. Each changed hash needs its own declaration, even when both sides
report the same compiler version. Kitty graphics is not a difference when enabled on
both sides. Missing, extra, duplicate, unchanged or wrong-side option names and
empty reasons are errors. Values are mandatory and must match exactly, including
their types and presence. Use `{ "present": false }` for an absent field, which
is distinct from a present `null`. Stale values or reversed directions fail. The comparison report retains the complete profiles
and every accepted declaration with the measured values and presence on each
side. It still lists and requires triage for every dump difference; declaring a
profile difference does not disposition behavior. Harness-change declarations
remain separate and do not authorize profile changes.

Capture records an independent `shipped_profile` assessment against the app defaults:
SIMD on, ReleaseFast, the compiler's baseline CPU/model/features, Windows MSVC,
all app Terminal features, ConPTY no-pull support and 10 MB scrollback. App
version fields and host provenance remain recorded separately from these
settings. Even **two equal non-shipped fork profiles** are refused by compare.
An intentional experiment needs `--declare-shipped-mismatches FILE`, using the
same value-bound schema for **every** mismatch on each affected `pre`, `branch`
or `upstream` app side: `old` is the shipped expectation and `new` the measured
value. This declaration is separate from cross-profile differences. The `pre` and `branch` slots require shipped settings even if the executable
uses the public module. Put a genuine public-library endpoint in the third
`upstream` slot (the pre/post pair must still use distinct production revisions), or explicitly
declare its shipped mismatches as well. Public metadata cannot silently exempt
a fork slot. The upstream public profile still records that it differs from
the shipped app; only that upstream role is exempt from enforcement.

The profile also records the actual Zig compiler version and the host's
Highway and simdutf dispatch names. The oracle-only probe uses `vt.cpp`'s exact
C++ flags and runtime dispatch; it does not force a target. Scalar builds are
marked explicitly. Different compiler/host paths require normal value-bound
profile declarations. Reports identify each side's revisions, build identity,
exe hash, both manifest hashes, completion hash and every declaration actually
used. Unused or duplicate harness, profile or shipped declarations are errors.

CI's build-only step measured **3m30s on the hosted runner**. Keep it under the
existing Zig-path job filter: terminal dependencies and API drift span the Zig
tree, so a narrower path filter could miss breakage. Documentation-only changes
under the filter's explicit documentation rules skip compiled jobs. This README
is outside those exemptions and still takes the default Zig rule; `identity.py`
must also stay on that rule.

The pair report lists every differing `(input, cols, rows, format)`. Three-way
comparison implements the plan's table exactly:

| Result                     | Classification         | Required disposition       |
| -------------------------- | ---------------------- | -------------------------- |
| Branch = upstream = pre    | no change              | none                       |
| Branch = upstream != pre   | fork behaviour removed | dropped-delta ledger entry |
| Branch = pre != upstream   | fork-owned semantics   | residual-ledger entry      |
| Any other equality pattern | bug candidate          | investigate and explain    |

Exit status is `0` when all differences are triaged (or there are none), `1`
when differences remain untriaged, and `2` for invalid evidence or execution.
Missing files, duplicate items, unmanifested files, incomplete size/format
coverage, corrupt content or unequal corpus/request identities are errors.
Manifests detect accidental corruption; they are not signed attestations.

To supply dispositions, pass `--triage ENTRIES.json`, a JSON array containing
each differing report row plus a nonempty `reason` and, for pair differences or either fork class,
a nonempty `ledger` reference. The classification and ordered SHA-256 list must
match current bytes; stale, duplicate and unused entries fail. This verifies
the recorded reference, not the truth or completeness of the external ledger.
Choose a fresh `--report` path for each invocation, including a rerun after
adding triage: report writes are exclusive and preserve previous evidence.

## Controls

```text
python test/differential-oracle/oracle.py controls --out CONTROL_DIR --source-revision PRE_PRODUCTION_SHA
```

This saves synthetic dump sets and checks all five partitions of three-way
equality, both pair outcomes, complete difference listing, hash-bound triage,
required ledger references, and corrupt, absent, duplicate and mismatched
evidence. `controls.json` names every passed check. `corpus.json` supplies
native positive controls (`text`, `sgr`, `reset`, `resize`, `conpty-on`,
`conpty-off`) for `capture`. Text/reset/SGR plain dumps equal `oracle-control`;
text/reset VT dumps match and SGR VT differs. Resize must wrap a 60-byte line
into three 20-column rows. The paired ConPTY cases create history, grow the
screen and write at an absolute cursor position; exact expected dumps
distinguish applying the no-pull flag from ignoring it. Stone explicitly checks
the pull result for both cases because that API lacks the flag. Run all six
sentinels on every adapter. `--source-revision` identifies the pre production
revision in this native-only corpus; it defaults to the running tool's HEAD.
Native controls first require the canonical request digest for all six cases;
sending the expected text without resize/no-pull operations is refused.
Positive control checks remain active under Python optimization and check each
item's class label, including both fork classes, in addition to total counts.

```text
python test/differential-oracle/oracle.py native-controls NATIVE_DUMPS/run-1 --report NATIVE_CONTROLS.json
```

The binary protocol is intentionally internal. Reuse the saved corpus and
the same harness sources across comparisons. Do not regenerate synthetic data
on a compared tree, normalize dump bytes, excuse missing inputs, or interpret
source/build evidence as runtime acceptance of noctty or ConPTY.

Replay `pty conpty` uses one ASCII separator space and, when present, must be
the first directive after `size` in both readers. Staging preflights write access to every destination
and its existing directory, including the tracked `build.zig`, before copying
any overlay bytes. A read-only target leaves the source copy unchanged.
