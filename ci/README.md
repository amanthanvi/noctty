# Migration diff lints

These implement migration PLAN sections 4.1 and 4.2. Run each Python entry
point with Python 3.13 and `-I`. Local imports come only from the script's own
directory; there are no third-party Python dependencies or upstream CI fetches.

```powershell
python -I ci/test_lints.py
python -I ci/zig017_lint.py --base origin/main --head HEAD
python -I ci/win32_ident_lint.py --base origin/main --head HEAD --mode enforce
```

The `checks` job runs the controls and both lints on every change. The Zig lint
fails added code using `**`, `@Type`, `@cImport`, `std.heap.stackFallback`, or an
`errdefer` capture. It reports the plan's review forms as warnings and in the
GitHub job summary. `@hasDecl` on an unresolved target also needs review: this
lexical lint cannot prove an imported or computed target's visibility. A local
literal struct's explicitly public member discharges that warning.

Both lints tokenize complete files before intersecting matches with added diff
lines. Comments and string/character literals are opaque. A multiline match
counts when any of its participating code tokens is on an added line. The
tokenizer is the plan's measured `zigtok.py`, copied without changes.

The Win32 lint resolves the inventory's namespace binding paths and local const
aliases, with block scope, literal imports, quoted identifiers, and alias chains.
It follows `internal_os.windows` through the current head's public re-exports.
Calls re-homed to the fork's declarations pass. Arbitrarily computed namespace
values and complete Zig type inference are outside this lexical lint's scope.
The 124-name list is the plan's measured inventory at `31796f5d0`, checked
against both compiler std trees. It is not the whole removed std declaration
universe. The retained `win_idents3.py` reference has only its Git reads batched
through `lint_common.py`; its original inventory rules and output are retained.

The fork-added file set is computed at each head, by subtracting
`upstream-paths.txt` from its tree. That list includes upstream rename sources.
New or renamed head paths absent from the list are covered immediately,
including Phase 1A adaptation files; the Phase 0b allow-list does not restrict
this lint.

**Phase 0b switch:** in `.github/workflows/test.yml`, change only
`run: python -I ci/run_lints.py --win32-mode report` to
`run: python -I ci/run_lints.py --win32-mode enforce`. The Zig lint already
enforces. Report mode still reports Win32 violations, and input/tool errors
still fail. The workflow contract accepts either switch position.

## Diff bases

- Pull request: the event's exact base SHA and head SHA, not the synthetic merge.
- Push to main: `github.event.before` through `github.sha`, covering every
  commit in a multi-commit push. A missing/zero/unavailable base fails closed.
- Scheduled or manual run: the checked-out head against its first parent. A
  schedule uses main; a dispatch uses its selected ref. This rechecks one commit
  without treating all legacy source as additions.

Checkout has full history. A missing revision, source, generated list, or
malformed baseline is an error, never an empty successful check. Diagnostics
print locations and rule names, not source lines or Git's command/stderr.

## Occurrence-bound baseline

`zig017-lint-baseline.txt` is empty in Phase 0a. At 1A.6, generate it from the
reviewed result and regenerate at the gated tip:

```powershell
python -I ci/generate_zig017_baseline.py . <fork-parent> <reviewed-result> ci/zig017-lint-baseline.txt
```

Rows use the reference `lint_baseline_counts.py` format:
`path<TAB>form<TAB>allowance<TAB>stripped exact source line`. Form names are
`**`, `@Type`, `@cImport`, `stackFallback`, and `errdefer-capture`. As in that
tool, one matching line counts once per form, even if it contains two uses.
The installed generator shares the lint's tokenizer and adds a
`# fork-parent: <full SHA>` header, needed to recover the fork-parent counts.
Do not feed raw legacy TSV without that header to a nonempty baseline.

For each `(path, form, line)`, let `F`, `B`, and `H` be its occurrence counts
at the fork parent, PR base, and PR head, and `A` its allowance. The remaining
allowance is `max(0, A - max(0, B - F))`. An added matching line passes only
when it has that baseline entry and `H <= B + remaining`. A different path or
line/form has no allowance. A second identical copy exhausts the same entry.
Removing and later re-adding within the original allowance passes. Only the
reviewed upstream import updates the baseline; fork changes never add entries.

## Regenerate upstream inputs

Pass read-only checkouts containing these exact commits, in order:

- Merge base: `ba398dfff3e30ff83da07140981ca138410cf608`.
- Stepping stone: `74d0c72fd9318ad3ab95bfb56f6c2d995e267e2e`.
- v1.4.0: `83fb95624b0439ee660c2679b43b38c8b63769cd`.

```powershell
python -I ci/generate_upstream_paths.py <base-repo> <stone-repo> <v140-repo> ci/upstream-paths.txt
python -I ci/generate_win32_identifiers.py . <std-0.17.1> <std-0.15.2> ci/win32-removed-identifiers.txt
```

Each std argument is its compiler's `lib/std` directory. The identifier
generator uses the reference inventory at its fixed revision and checks every
name exists in 0.15.2 and is absent in 0.17.1. It needs the already-extracted
compiler sources, not a download. The path generator unions all three trees
and rename sources, writes only the supplied output, and is deterministic.

The controls retain their temporary Git repositories and print their location,
so failed cases can be inspected. Set `TEMP`/`TMP` to a task-owned scratch root
when running locally and clean that root using the approved local cleanup tool.

For a bounded history sanity check, run
`python -I ci/audit_lints.py --since YYYY-MM-DD --output <report.json>`.
It checks each first-parent commit of `origin/main` against its parent, retains
findings and timings after every commit, and writes a separate summary JSON.
