# Self-Correction Log: Zig, PowerShell and Win32 FFI traps; git, gh and agent tooling

Dates descend; entries that share a date are not always newest first. A newer-dated entry, or an item under "Corrected in other files", overrides an older one on the same subject; when same-date entries disagree, the code decides. [AGENTS.md](../../../AGENTS.md) indexes the area files and says how to add an entry.

See also:
- PowerShell traps filed where they were found: a one-element array from `if`/`switch` unrolls to a scalar (item 6 of the 2026-10-17 "The manual Chocolatey Publish workflow" entry in build-release-ci.md); `@($a + 1, $b)` parses as `$a + (1, $b)` (the 2026-10-16 "The real-input check of #285" entry in window-frame.md, harness traps).
- A struct argument or a `const` copy of an aggregate can alias a list element: the 2026-10-19 `closeWindow` aliasing entry in tabs-panes.md.
- Mirroring a WinRT vtable (check every method order against `winrt/*.h`; `get_History` is on `IToastNotificationManagerStatics2`): trap (1) of the 2026-10-23 NOTIFY-2 entry in app-lifecycle.md.
- Zig's `OpenFile` maps `STATUS_SHARING_VIOLATION` to `error.AccessDenied`: trap (5) of the 2026-10-23 RMCLOSE-3 entry in build-release-ci.md. Copying a `std.heap.ArenaAllocator` into a struct literal and then allocating through it loses nodes, and `.?` in a shared test helper exits the test binary with code 3 so later tests read as passed: items (6) and (7) of the 2026-10-23 PROFILES part 2 entry in launch-and-paths.md. `ImmGetCompositionStringW` needs an untyped buffer for attribute bytes: trap (1) of the 2026-10-23 IME conversion target clause entry in input.md.

- 2026-05-02: Lowercasing Zig type aliases to satisfy naming review can collide with same-named declarations or locals in Zig's shared declaration namespace; check for helper/local name conflicts before committing mechanical renames.
- 2026-05-01: In this fork, with both `origin` and `upstream` remotes configured, bare `gh pr view <n>` can resolve the upstream Ghostty PR number; use `-R amanthanvi/noctty` for fork-local PR review/checks.
- 2026-05-01: In Zig Win32 FFI, `std.os.windows.HANDLE` is non-null; APIs like `CreateJobObjectW` that signal failure with `NULL` must use `?HANDLE` in extern declarations or future callers cannot model failure correctly.
- 2026-05-01: On Win32 x64, `JOBOBJECT_BASIC_LIMIT_INFORMATION` is 64 bytes, not 56; `SIZE_T`/`Affinity` padding also shifts `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` to 144 bytes with `JobMemoryLimit` at offset 120. Keep ABI tests on real offsets before wiring Job Object FFI.
- 2026-05-01: In this repo's worktrees, plain `gh repo` / `gh pr` commands can resolve to upstream `ghostty-org/ghostty` despite `origin=amanthanvi/noctty`; pin review ops with `--repo amanthanvi/noctty`.
- 2026-05-01: In this fork, plain `gh pr view <n>` can resolve the upstream Ghostty repo instead of `amanthanvi/noctty`; pass `--repo amanthanvi/noctty` or verify the target before trusting PR metadata.
- 2026-05-01: In Zig `union(enum)` tests, `Type.tag` names the tag enum, not a union value; cast to `Type` before calling union methods in assertions.
- 2026-04-30: Cross-thread ChatGPT URLs can stall behind Cloudflare verify-human; use `codex exec resume <thread-id> <prompt>` for coordination, and do not discard a completed streamed answer just because Codex ends with a trailing `thread ... not found` rollout-record error.
- 2026-04-22: Zig sentinel slices exclude the trailing sentinel from `.len`; never pass `len - 1` to Win32 `TextOutW` / `DrawTextW` for `[:0]u16` UI caches. Empty overlay strings then underflow in Safe builds, and non-empty strings lose their final character.
- 2026-04-20: Publish branches and PRs for this fork against `origin` / `amanthanvi/noctty`, never `upstream` / `ghostty-org/ghostty`. Verify the target repo explicitly before `git push` and `gh pr create`.
- 2026-04-18: In PowerShell interpolated strings, wrap a variable in `${...}` before a literal colon (`:`); `"$path: $value"` parses `$path:` as a scoped variable and fails.
- 2026-04-18: In Win32 `WM_COMMAND`, `lParam == 0` is valid for menu/accelerator dispatch. Never `@ptrFromInt(lParam)` unconditionally there; decode to `?HWND` first or command actions like search toggle can panic with "cast causes pointer to be null".
- 2026-04-12: GDI brush handles (HBRUSH) returned from `WM_CTLCOLOR*` handlers must use `@bitCast` not `@intCast` to convert to LRESULT; GDI handles can have the high bit set on x64, causing `@intCast` to panic.
