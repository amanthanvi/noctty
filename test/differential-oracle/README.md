# Differential terminal oracle

This implements migration-plan sections 3.3 and 3.4. It captures the active
terminal screen and retained history through `TerminalFormatter` after feeding
the same frozen corpus into the `ghostty-vt` Zig module. It opens no window or
PTY and uses no clipboard, shell integration, application configuration or user
state.

The gate is **no untriaged differences**. A difference is evidence for review,
not proof of a regression or permission to discard fork behavior.

## Build and freeze inputs

Run the repository's required quiet-window guard before **every** build, test
or harness command below. Use `scripts/dev-windows.cmd` for Zig 0.15.2 and a VS
developer shell with an explicitly addressed compiler for Zig 0.17.1. Keep build
roots and their Zig global caches on the same drive. Use task-owned scratch
copies and caches; never build in a retained read-only plan tree.

From the repository root:

```text
scripts\dev-windows.cmd zig build --build-file test/differential-oracle/build.zig -Dcorpus=true -Doptimize=ReleaseSafe --prefix H:\scratch\oracle\build
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
4,002 by default (`--expect-fuzz` makes a future intentional count explicit),
and copies their full bytes into the frozen JSON. It does not strip the stream
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

Build the same harness files on the pre tree, 1A, upstream v1.4.0 and 1B. To
use a tree that does not yet contain this tool, copy these **new** files into a
scratch copy of that revision:

```text
src/differential_oracle.zig
src/differential_oracle_adapter.zig
test/differential-oracle/build.zig
test/differential-oracle/build.zig.zon
```

Build without `-Dcorpus=true`. All terminal/allocator/IO version differences
are isolated in `differential_oracle_adapter.zig`. The standalone build imports
the tree's own `ghostty-vt` module with SIMD disabled. It forwards target and
optimization to the dependency. The generator is only built on the pre side;
it is not needed on upstream or 1B.

```text
python test/differential-oracle/oracle.py capture --corpus FROZEN_DIR/corpus.json --exe ORACLE_EXE --source-root SOURCE_TREE --out DUMPS_DIR --work RUN_DIR
```

Both output directories must be fresh. `capture` rejects tracked source edits,
records the source HEAD and executable hash, and runs the executable twice in
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
writes `determinism.json`. Keep large dumps and their frozen corpus outside the
repository.

## Compare and triage

```text
python test/differential-oracle/oracle.py compare PRE/run-1 BRANCH/run-1 --report PAIR.json
python test/differential-oracle/oracle.py compare PRE/run-1 BRANCH/run-1 UPSTREAM/run-1 --report TRIAGE.json
```

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
each differing report row plus a nonempty `reason` and, for either fork class,
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
resize APIs with ConPTY's no-pull policy. Run it on each compiler adapter.

```text
python test/differential-oracle/oracle.py native-controls NATIVE_DUMPS/run-1 --report NATIVE_CONTROLS.json
```

The binary protocol is intentionally internal. Reuse the saved corpus and
the same harness sources across comparisons. Do not regenerate synthetic data
on a compared tree, normalize dump bytes, excuse missing inputs, or interpret
source/build evidence as runtime acceptance of noctty or ConPTY.
