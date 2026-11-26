# The 1B.5 codemod

The fork's Zig 0.15.2 spellings rewritten to Zig 0.17.1's by rules over Zig's token stream (`ci/zigtok.py`), so the
migration re-runs at every forward merge through 1B.9 (PLAN.md row 1B.5, U7).

- `codemod.py`: the rules and the engine. Every rule is idempotent and rewrites only what the tokens prove safe.
  `--check` reports without writing; `--report` lists each hit. `--fork-lines v1.4.0` rewrites only the fork's
  lines: the `+` records of `git diff -U0 --inter-hunk-context=0 v1.4.0 -- <file>` (never a context line a config
  adds), with the file looked up by `git ls-tree -z` (a non-ASCII name is not quoted into a miss).
- `test_codemod.py`: each rule over its fixture, what it leaves alone, idempotence, and the rules run together.
  `python -I plans/1b/codemod/test_codemod.py`.
- `census.py`: the distinct compile errors of a `zig build` log, by file and by kind, for the waves that follow.
- `residue.tsv`: the hand edits, each with its file and why no rule makes it.

A run: the codemod over the files in scope (Phase 0b files that are not yet on the branch are left out), then
`zig fmt` (0.17's own rewrite of `@intFromEnum` and the other renamed builtins), then the build, whose census decides
the next rule or hand edit.
