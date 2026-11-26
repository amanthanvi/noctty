# The 1B.5 codemod

The fork's Zig 0.15.2 spellings rewritten to Zig 0.17.1's by rules over Zig's token stream (`ci/zigtok.py`), so the
migration re-runs at every forward merge through 1B.9 (PLAN.md row 1B.5, U7).

- `codemod.py`: the rules and the engine. Every rule is idempotent and rewrites only what the tokens prove safe.
  `--check` reports without writing; `--report` lists each hit and each hand edit. `--fork-lines v1.4.0` rewrites
  only the fork's lines: the `+` records of `git diff -U0 --inter-hunk-context=0 v1.4.0 -- <file>` (never a context
  line a config adds), with the file looked up by `git ls-tree -z` (a non-ASCII name is not quoted into a miss).
- `test_codemod.py`: each rule over its fixture, what it leaves alone, idempotence, and the rules run together.
  `python -I plans/1b/codemod/test_codemod.py`.
- `census.py`: the distinct compile errors of a `zig build` log, by file and by kind, for the waves that follow.
- `residue.tsv`: the hand edits, each with its file and why no rule makes it.

A run: the codemod over the files in scope (Phase 0b files that are not yet on the branch are left out), then
`zig fmt` (0.17's own rewrite of `@intFromEnum` and the other renamed builtins), then the build, whose census decides
the next rule or hand edit.

## What the run leaves to hand edits

The bar is "when in doubt, leave it for a hand edit": a 0.15 shape a rule recognises but cannot prove equivalent is
left as it is and reported, never rewritten and never an abort. Each one prints as
`hand edit<TAB><file><TAB><rule><TAB><line><TAB><why>` (with `--fork-lines`, only when one of its lines is the fork's),
the count follows the rule counts, and `--report` has it as `<file><TAB><rule><TAB><line><TAB>hand edit: <why>`
beside each `rewritten` hit. A hand edit that lands goes into `residue.tsv`.

The engine, for every rule:
- a hit that touches an inherited line, any line from an edit's first to its last, is a hand edit when it also
  touches a fork line (and is upstream's, unreported, when it touches none);
- a hit that would add or drop a line break, or move text across one, is a hand edit: a multi-line empty array list
  initializer (`= .{` and `}` on two lines), or arguments that change places from one line to another.

test-dir-io (also):
- arguments that change places must lie on one line, with no comment between the call's arguments;
- makeOpenPath with options that are not a `.{ ... }` literal;
- readFileAlloc in a test that names `FileTooBig`.
