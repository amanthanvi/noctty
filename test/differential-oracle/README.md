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

From the repository root:

```text
scripts\dev-windows.cmd zig build oracle -Dvt-api=fork -Doracle-corpus=true -Dsimd=true -Doptimize=ReleaseFast -Dcpu=baseline -Dcustom-shaders=true --prefix BUILD_DIR --summary all
```

Run `build/bin/oracle-corpus.exe` in a fresh scratch directory. It writes
`synthetic.bin`, using `src/synthetic`'s `Bytes`, `Utf8`, and `Osc` generators:

- Seeds: `0`, `1`, and `0xC0FFEEEEEEEEEEEE`, independently reset per generator.
- Bytes and UTF-8: 4,096 bytes per seed.
- OSC: 16 requests with a 256-byte maximum each, separately with `p_valid=1`
  and `p_valid=0`; all other weights are the generators' defaults.

Run the generator twice in separate directories and compare `synthetic.bin`
byte for byte. Freeze the corpus **once on the pre side**:

```text
python test/differential-oracle/oracle.py prepare --repo PRE_TREE --synthetic SYNTHETIC_BIN --out FROZEN_DIR
```

`prepare` counts the tracked files in `test/fuzz-libghostty/corpus`, requires
4,001 seeds by default (the tracked `sanitize-filenames.sh` is excluded) (`--expect-fuzz` makes a future intentional count explicit),
and freezes their committed blob bytes into JSON. It refuses tracked or untracked changes. It does not strip the stream
fuzzer's mode-selector byte or apply the parser/OSC fuzzers' calling convention.
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
link dependencies. Oniguruma, Kitty graphics and tmux control mode remain
selected by that tree's own app build.

The upstream side is **v1.4.0's public lib-vt module**, exactly as §3.4 names it.
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

Select the Terminal API explicitly with `-Dvt-api=fork|stone|v140|v140_fork`.
The choice never depends on compiler version or std-origin feature detection.
`fork` and `stone` use the legacy IO adapter, with positional and structured
resize respectively; `v140` and `v140_fork` use the modern IO adapter with
structured and positional resize respectively. Stone has no ConPTY no-pull
flag, so that flag is not emulated: record this limit when reviewing replays.

For a clean task-owned copy without the harness, run:

```text
python test/differential-oracle/stage.py SOURCE_TREE --api stone
```

Stage applies only instrumentation, retaining the original production revision
and exact root-build delta in `staged-source.json`. Commit that overlay locally
before prepare/capture. Capture verifies the clean tree and permitted delta;
manifest provenance distinguishes production and instrumented commits. Build
with that side's compiler, explicit API, SIMD on, ReleaseFast and baseline CPU.
Only the fork accepts `-Dcustom-shaders=true`; read the other side's own app
build options. The generator is needed only on the pre side.

At **1B.3/1B.5**, delete `differential_oracle_adapter_legacy.zig` and
`differential_oracle_corpus.zig` whole. Select a modern API and reuse the frozen
corpus. The retained modern adapter and build helper need no compiler-selected
shim or residue allowance. Check the cutover with `residue_gate17.py`.

```text
python test/differential-oracle/oracle.py capture --corpus FROZEN_DIR/corpus.json --exe ORACLE_EXE --source-root SOURCE_TREE --out DUMPS_DIR --work RUN_DIR
```

Both output directories must be fresh. `capture` requires a completely clean source,
records production/instrumented revisions, executable and harness source hashes, and runs the executable twice in
separate working directories. No previous outputs are reused. Binary requests,
responses and diagnostics stay under `RUN_DIR`; their stdout/stderr are not
echoed. A failure, crash or timeout fails capture and preserves partial evidence.
The timeout defaults to 900 seconds **per run**, not a performance criterion.

The request and response have checked versioned headers, counts, lengths,
ordered record indices and exact EOF. For each input/initial size, both plain
and VT output are saved without newline conversion. Formatting keeps soft
wraps and trailing spaces (`unwrap=false`, `trim=false`); plain uses no extras
and VT uses `TerminalFormatter.Extra.all`. Scrollback is explicitly limited to
10,000 bytes on both API versions. The formatter covers only the active screen,
including its history, as the API documents; it is not a complete terminal
state serialization (for example, it does not dump inactive-screen contents).

`run-1/manifest.json` and `run-2/manifest.json` map readable input IDs, sizes
and formats to safe numbered filenames, lengths and SHA-256 hashes. The driver
requires every saved dump and both manifests to be **byte-identical**, then
writes `determinism.json` and finally `completion.json`. The completion record
binds both identical manifests, the corpus, harness sources, full profile,
executable and source provenance. Failed or nondeterministic runs retain partial
evidence but receive no completion record. Compare and native-controls recheck
both runs and refuse missing, corrupt or mismatched completion with exit 2.

Admission also compares the captured harness hashes with the running tool's
sources. To declare an intentional instrument change explicitly, pass
`--declare-harness-change OLD:CURRENT` to compare/native-controls; each value is
the SHA-256 of `json.dumps(harness_sources, sort_keys=True).encode()`.
Declarations do not bypass profile, corpus, provenance, determinism or dump checks.
Use `--expected-corpus SHA256` on compare to pin the real baseline corpus. Keep large dumps and their frozen corpus outside the
repository.

## Compare and triage

```text
python test/differential-oracle/oracle.py compare PRE/run-1 BRANCH/run-1 --report PAIR.json
python test/differential-oracle/oracle.py compare PRE/run-1 BRANCH/run-1 UPSTREAM/run-1 --report TRIAGE.json
```

An intentional profile difference requires `--declare-profile-differences
DECLARATIONS.json`. The file is a JSON array; each row contains exactly `side`,
`option` and a nonempty `reason`. `side` is `branch` or `upstream`, compared with
`pre`; `option` is a dotted path in the recorded profile. For example:

```json
[
  {
    "side": "upstream",
    "option": "terminal_options.oniguruma",
    "reason": "v1.4.0 public lib-vt disables Oniguruma"
  },
  {
    "side": "upstream",
    "option": "terminal_options.tmux_control_mode",
    "reason": "v1.4.0 public lib-vt derives tmux support from Oniguruma"
  }
]
```

The example covers only those two differences. A real declaration must name
**every** measured difference, including artifact, version fields and options
present on only one side. Kitty graphics is not a difference when enabled on
both sides. Missing, extra, duplicate, unchanged or wrong-side option names and
empty reasons are errors. The comparison report retains the complete profiles
and every accepted declaration with the measured values and presence on each
side. It still lists and requires triage for every dump difference; declaring a
profile difference does not disposition behavior. Harness-change declarations
remain separate and do not authorize profile changes.

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

## Controls

```text
python test/differential-oracle/oracle.py controls --out CONTROL_DIR
```

This saves synthetic dump sets and checks all five partitions of three-way
equality, both pair outcomes, complete difference listing, hash-bound triage,
required ledger references, and corrupt, absent, duplicate and mismatched
evidence. `controls.json` names every passed check. `corpus.json` supplies
native positive controls (`text`, `sgr`, `reset`, `resize`) for `capture`: each plain dump
must equal `oracle-control`, text/reset VT dumps must match, and SGR VT must
differ. This separately proves that the runner interprets input and that both
formatter choices reach saved output. The resize control also executes both
resize APIs. Stone cannot apply the absent ConPTY no-pull flag. Run it on each API adapter.

```text
python test/differential-oracle/oracle.py native-controls NATIVE_DUMPS/run-1 --report NATIVE_CONTROLS.json
```

The binary protocol is intentionally internal. Reuse the saved corpus and
the same harness sources across comparisons. Do not regenerate synthetic data
on a compared tree, normalize dump bytes, excuse missing inputs, or interpret
source/build evidence as runtime acceptance of noctty or ConPTY.
