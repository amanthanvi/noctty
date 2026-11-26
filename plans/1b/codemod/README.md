# The 1B.5 codemod

The fork's Zig 0.15.2 spellings rewritten to Zig 0.17.1's by rules over Zig's token stream (`ci/zigtok.py`), so the
migration re-runs at every forward merge through 1B.9 (PLAN.md row 1B.5, U7).

- `codemod.py`: the rules and the engine. Every rule is idempotent and rewrites only what the tokens prove safe.
  `--check` reports without writing; `--report` lists each hit.
- `test_codemod.py`: each rule over its fixture, what it leaves alone, idempotence, and the rules run together.
  `python -I plans/1b/codemod/test_codemod.py`.
- `census.py`: the distinct compile errors of a `zig build` log, by file and by kind, for the waves that follow.
- `residue.tsv`: the hand edits, each with its file and why no rule makes it.

A run: the codemod over the files in scope (Phase 0b files that are not yet on the branch are left out), then
`zig fmt` (0.17's own rewrite of `@intFromEnum` and the other renamed builtins), then the build, whose census decides
the next rule or hand edit.
