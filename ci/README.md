# Migration diff lints

These implement migration PLAN sections 4.1 and 4.2. Run each Python entry
point with Python 3.13 and `-I`. Local imports come only from the script's own
directory; there are no third-party Python dependencies or upstream CI fetches.
The checkout needs main history and `origin/main`. Controls verify that every
SHA literal in test/control scripts is an ancestor of `origin/main`; fixtures
must never depend on temporary PR branch commits. The upstream path generator's
three source pins are separate regeneration inputs, retained by upstream tags,
and are not loaded by the control suite or CI lints.

```powershell
python -I ci/test_lints.py
python -I ci/zig017_lint.py --base origin/main --head HEAD
python -I ci/win32_ident_lint.py --base origin/main --head HEAD --mode enforce
```

For the approved 1A proxy and extra-occurrence twin, supply a read-only repo
containing the old fork pin and `trial-hybrid`, plus a fresh output directory:

```powershell
python -I ci/test_lints.py --proxy-repo <read-only-repo> --proxy-ref trial-hybrid --proxy-output <fresh-output>
```

This also runs the ordinary controls. It generates the proxy baseline and
retains the twin in a separate fixture repo; it never writes to the input repo.

The two-compiler controls are optional locally, using existing toolchains:

```powershell
python -I ci/test_lints.py --compiler-output <fresh-output> --zig017 <zig-0.17.1-exe> --pause-script <quiet-window-guard.ps1>
```

They compile the pointer-expression matrix on both compilers, compile the
binary-repeat twins on 0.15.2 and verify their rejection on 0.17.1, and check
every generated removed name by native reflection on both versions. They use
the repository's dev-windows wrapper and caches in the supplied output directory.
They also run the Windows 0.15.2 import-spelling matrix: eight spellings compile
and seven malformed/unaccepted variants fail for their import paths.
**Layout warning:** a single trailing directory dot (`../../os./windows.zig`)
is excluded from that matrix's accepted set. Zig 0.15.2 accepts it when it opens
the fixture by an absolute path outside its cwd, but rejects it in cwd-relative
layouts and a real `zig build`. The lint still recognizes it conservatively;
that recognition does not establish native build acceptance. The remaining
matrix supports output directories both inside and outside the checkout.
Compiler arguments are quoted for CMD, including paths with spaces and `&`.
Embedded quotes, line breaks, `%` expansion and `!` delayed expansion are
rejected before launch. Temporary Git repositories disable commit signing
locally, independently of the developer's signing defaults.

The `checks` job runs the controls and both lints on every change. The Zig lint
fails new occurrences of binary array-repeat `**`, `@Type`, `@cImport`,
`std.heap.stackFallback` (including literal imports and const aliases), or an
`errdefer` capture. It reports the plan's review forms as warnings and in the
GitHub job summary. `@hasDecl` on an unresolved target also needs review: this
lexical lint cannot prove an imported or computed target's visibility. A local
literal struct's explicitly public member discharges that warning.

The repeat classifier tracks whether the next token must begin an operand.
Balanced token frames distinguish control-flow headers, function parameter
lists and type attributes from completed calls/groups and indexing. Declaration
names, break labels and payload captures do not complete operands. `**` in an
operand position is a pointer prefix; after a completed operand it is binary
repeat. This uses grammatical token context, without evaluating whether a
value represents a type or enumerating preceding-prefix exceptions.
Binary-repeat spans include the enclosing delimiter-separated expression,
including both operands, while the diagnostic and allowance key stay on the
operator line. Thus an operand-only edit cannot turn an untouched pointer
prefix into an undetected repeat.

Both lints tokenize complete files before intersecting matches with added diff
lines. Comments and string/character literals are opaque. A multiline match
counts when any of its participating code tokens is on an added line. The
tokenizer is the plan's measured `zigtok.py`, copied without changes.
The separate span helper indexes brackets once, peels nested groups without
repeated suffix scans, and keeps overlapping line spans compact. Malformed
unclosed `@hasDecl` calls remain review flags; syntax validation belongs to Zig.
Parameter discovery also uses indexed bracket jumps, including labeled
return-type blocks before the true body. Per-name scope intervals replace
expanded token ranges. The timed control bounds both lints on 8,000 unclosed
function starts and balanced nested functions to 5.5 seconds per case, about
three times the measured 1.8-second baseline for the 8,000-line specimen.

The Win32 lint resolves the inventory's namespace binding paths and local const
aliases, with block scope, literal imports, quoted identifiers, and alias chains.
It follows `internal_os.windows` through the current head's public re-exports,
resolved through the same literal bindings regardless of their alias/import
spelling. Re-export definition changes recheck dependent uses throughout
the head's fork-added Zig files, including files without a diff. Changes to
their literal alias dependencies propagate through those exports too.
Inline `@import("std").os.windows` and relative imports of `src/os/windows.zig`
are recognized. Decoded file paths normalize `/` and Windows `\` separators,
`.`/`..` segments and repeated separators before resolution. Windows file-case
variants are also recognized. A single trailing directory dot is recognized
conservatively despite the native layout limit described above.
Filename suffix dots/spaces, directory spaces and repeated
trailing dots were rejected in those controls. Uses behind pointer/slice qualifiers and bare aliases of leaf
types (for example `HRESULT`) count. Calls re-homed to fork declarations pass.
The real-path `win32/sys.zig` and `win32_types.zig` controls assert a native
origin and a public target declaration. A separate token control asserts the
native `win32.sys` route; `sys` is private in the facade, so this does not claim
that other compiled modules may access it. Function parameters
mask implicit namespace names in their signatures and bodies, so a parameter named `std` is
not mistaken for the std module.

Win32 selection uses only the head file and the merge-base diff's hunks:

- A reference is checked when one of its own lines is added.
- An alias definition is changed when its head span, from its first modifier
  or declaration token through the terminating semicolon, contains an added
  line. Git marks a replacement line as added, so edits on any of these lines
  count. Deletions count only between two lines of the definition. For a
  definition on lines `first..last`, gap `p` between head lines `p` and
  `p+1` counts when `first <= p < last`.
- Every alias and reference that resolves through a changed alias is rechecked,
  transitively. The same rule applies to literal public exports and their
  dependencies in `src/os/windows.zig`.
- An edit wholly outside the definition leaves its unchanged references alone.
  This includes deleting the blank line after an alias and renaming a function
  whose header is on the next line after a file-level alias. A reference on a
  changed line is still checked under the added-line rule.

A deletion-only definition change remains covered when its owner is renamed.
The generated list covers **1,534 removed names**: the 1,485 root/file-namespace
names plus 49 nested declarations (including `REG.*`, `ws2_32.SOCK.*` and
`ws2_32.MSG.ERRQUEUE`), checked against both compiler std trees. The plan's 124 is
the reached subset at `31796f5d0`; all 124 remain in the full set. The retained
`win_idents3.py` preserves its historical inventory matching rules, with
batched Git reads and strict UTF-8 decoding instead of replacement decoding.

This remains a literal-binding lint, not Zig type inference. Computed forms
such as `@field`, `comptime` or `if` aliases, destructuring, `(namespace).member`,
and access through another container (`S.k.Sleep`) are a known limit shared
with the reference tool. These computed forms also limit re-export resolution;
the cross-file recheck is bounded to resolved literal exports of
`src/os/windows.zig`, not arbitrary module evaluation. They are not evaluated
by this lint.

**Known conservative over-report:** a touched definition rechecks its uses
even if the final origin stayed the same. Moving, re-spelling or editing a
comment on an alias's definition line can therefore report unchanged legacy
uses. Introducing an intermediate
alias (for example `const os = std.os; const windows = os.windows;`), or routing
an existing std alias through the fork's re-exports, can recheck uses whose final
binding stayed the same. This may report existing removed uses even though that
edit changed no call's meaning. The real IPC fixture retains the measured
40/40/32 reports for these cases. The definition-span rule can therefore
report a legacy use whose binding stayed the same.

The fork-added file set is computed at each head, by subtracting
`upstream-paths.txt` from its tree. That list includes upstream rename sources.
New or renamed head paths absent from the list are covered immediately,
including Phase 1A adaptation files; the Phase 0b allow-list does not restrict
this lint.

**Phase 0b switch:** in `.github/workflows/test.yml`, change only
`run: python -I ci/run_lints.py --win32-mode report` to
`run: python -I ci/run_lints.py --win32-mode enforce`. The Zig lint already
enforces. Report mode still reports Win32 violations, and input/tool errors
still fail. **Land this single-token flip as its own small PR immediately
before the first Phase 0b PR.** Section 5 excludes `test.yml` from 0b membership.
The workflow contract accepts both positions now and tests its weakening
mutations in both positions. The activation PR can then require `enforce` for
subsequent changes.

## Diff bases

- Pull request: added lines come from the merge base of the event's base/head
  through the head, so changes made only on main cannot appear as PR additions.
- Push to main: `github.event.before` through `github.sha`, covering every
  commit in a multi-commit push. A missing/zero/unavailable base fails closed.
- Scheduled or manual run: the checked-out head against its first parent. A
  schedule uses main; a dispatch uses its selected ref. This rechecks one commit
  without treating all legacy source as additions.

Checkout has full history. A missing revision, source, generated list, or
malformed baseline is an error, never an empty successful check. Diagnostics
print locations and rule names, not source lines or Git's command/stderr.
Diffs force text, disable external diff/textconv/color/renames, and override
user diff formatting/algorithm options. All `GIT_*` environment overrides are
removed for local Git commands, including pathspec, repository-selection,
config-injection and diff variables; the explicit repo and arguments own each
read. Binary
attributes and NUL detection cannot hide added lines. A changed head blob with
no hunk fails closed; deletions and mode-only changes remain valid.
PR edits to the lints' code, data, workflow or workflow contract are flagged
for review in the job summary. This is a review flag, not a self-protection seal.
Generated allowances and inventories must be reviewed with those flags: reading
only the base copy would prevent the approved 1A.6 baseline regeneration and
inventory updates from taking effect. Summary paths are opaque Markdown code
spans, including paths containing backticks or image syntax.

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
allowance is `max(0, A - max(0, B - F))`. Every matching line, including one with
no baseline entry (`A = 0`), passes while `H <= B + remaining`. Moving or
retaining a line cannot fail. A different path or line/form has zero allowance;
an additional copy must fit the same occurrence budget.
For a stale PR, let `M` be the merge-base count and `B` the current base-tip
count. Its projected count is `B + H - M`, so consuming an allowance on main
also counts before another branch adds a copy. Added-line selection still
uses the merge base.
Removing and later re-adding within the original allowance passes. Only the
reviewed upstream import updates the baseline; fork changes never add entries.

## Regenerate upstream inputs

Pass read-only checkouts containing these exact commits, in order:

- Merge base: `ba398dfff3e30ff83da07140981ca138410cf608`.
- Stepping stone: `74d0c72fd9318ad3ab95bfb56f6c2d995e267e2e`.
- v1.4.0: `83fb95624b0439ee660c2679b43b38c8b63769cd`.

```powershell
python -I ci/generate_upstream_paths.py <base-repo> <stone-repo> <v140-repo> ci/upstream-paths.txt
python -I ci/generate_win32_identifiers.py <std-0.17.1> <std-0.15.2> ci/win32-removed-identifiers.txt
```

Each std argument is its compiler's `lib/std` directory. The identifier
generator follows public declarations recursively through literal containers,
relative imports and namespace aliases, and keeps names present in 0.15.2 and
absent in 0.17.1. Private aliases may be intermediate routes; fields, function
evaluation and computed namespaces are not expanded. Cycles stop at the first
repeated source scope rather than generating infinitely repeated alias paths.
It needs the already-extracted
compiler sources, not a download. The path generator unions all three trees
and rename sources, writes only the supplied output, and is deterministic.

The ordinary controls automatically remove their temporary fixtures and Git
repositories with unittest cleanup callbacks, including after failed cases.
Set `TEMP`/`TMP` to a task-owned scratch root when running locally so creation
also stays on the intended drive. Keep compiler/proxy outputs there, preserve
only text evidence, and clean the run root with the approved local cleanup tool.

For a bounded history sanity check, run
`python -I ci/audit_lints.py --since YYYY-MM-DD --output <report.json>`.
It checks each first-parent commit of `origin/main` against its parent, retains
findings and timings after every commit, and writes a separate summary JSON.
