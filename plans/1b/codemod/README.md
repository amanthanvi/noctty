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
- an open and the closes of what it opened, when the open's name is bound more than once in the test (sibling
  blocks, a capture `|f|`, a parameter `f: T`, a ported open): a close paired by name alone could take the wrong
  open. The pairing reads one test block at a time, so the same name in another test is another binding and pairs
  within that test. Likewise a `tmp` receiver bound to a temporary directory and also to something else;
- arguments that change places must lie on one line, with no comment between the call's arguments;
- makeOpenPath with any options but the two exact translations: `.{}` stays, `.{ .no_follow = true }` becomes
  `.{ .open_options = .{ .follow_symlinks = false } }` (0.17 renamed the field and inverted it);
- realpathAlloc anywhere but the whole initializer of an untyped `const` (`const p = try tmp.dir.realpathAlloc(..);`):
  0.17's result is a `[:0]u8`, so a `[]u8` binding, a field, an argument or a `var` could drop the sentinel and a
  later free would get the wrong size. An untyped `const` keeps the type, and `free(p)` frees the sentinel too; a
  copy of `p` coerced elsewhere to `[]u8` and freed through that copy is not traced;
- openFile outside a test. 0.15.2's Windows openFile refused a directory (`error.IsDir`, `std.os.windows.OpenFile`'s
  `.file_only`), and 0.17.1's opens one unless `.allow_directory = false` (both measured). The rule rewrites only test
  blocks, since product code has no `std.testing.io` and needs a reader to thread its caller's Io; so the product
  choice is the bail-out, and the hand edit that threads the Io adds `.allow_directory = false`. A 0.15 openFile on
  `std.fs.cwd()`, and `std.fs.openFileAbsolute`, outside a test are reported as such (another receiver, whose type the
  tokens do not show, is not). An openFile inside a test keeps 0.17's default: a test opens the path it just made,
  and the report notes each one (`rewritten; 0.17's openFile opens a directory ...`);
- readFileAlloc's bound `n` becomes `.limited(n + 1)`: 0.15 read a file of exactly `n` bytes and 0.17's `Io.Limit`
  refuses a file that reaches it (measured on both toolchains). Only a literal or a simple name takes the `+ 1`;
  any other bound is a hand edit (`1 << 20 + 1` is `1 << 21`; `maxInt(usize) + 1` overflows). A name whose value
  is `maxInt(usize)` would overflow too, which a comptime value turns into a compile error;
- every readFileAlloc in a file that names `FileTooBig` anywhere (code, string or comment): 0.17's oversize error
  is `StreamTooLong`, and a helper outside the test may consume the old name.
