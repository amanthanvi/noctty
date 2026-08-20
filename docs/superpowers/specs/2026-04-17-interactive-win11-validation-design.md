# Interactive Win11 Validation Environment Design

Date: 2026-04-17
Status: Draft
Scope: Repo-owned local harness for manual interactive Windows validation

## Problem

Agents and contributors can build and unit-test `noctty`, but many worktrees
do not have a repeatable way to launch the app in an isolated Windows runtime
state for manual validation. The common result is a turn-ending caveat like
"interactive Win11 validation in this environment" because the repo provides
build-shell helpers, not an interactive validation harness.

The missing capability is narrower than VM provisioning and broader than
"double-click the exe": we need a repo-owned command that launches the current
worktree's build in a predictable, isolated, resettable Windows sandbox so a
human or agent can manually exercise the app.

## Goals

- Provide a one-command path to launch `noctty` for manual interactive
  validation on Windows 11.
- Isolate app runtime state per worktree so `main` and sibling worktrees do not
  clobber one another's config, cache, MRU, shell-integration payloads, crash
  files, or logs.
- Reuse the repo's existing Windows toolchain bootstrap instead of inventing a
  second environment bootstrap path.
- Make first-run reproduction cheap via a resettable sandbox.
- Keep the implementation repo-local, low-dependency, and understandable by
  contributors who are not using Codex.

## Non-Goals

- Provisioning a VM, Hyper-V guest, remote desktop, or disposable Windows
  image.
- Automating UI interaction or asserting GUI correctness.
- Replacing targeted Zig tests or CI checks.
- Creating a release-packaging workflow. This harness validates the worktree
  build, not the installer.
- Overriding the user's full Windows profile by default.

## User Stories

- As a contributor in a worktree, I can run one script and get an isolated
  `noctty.exe` instance for manual testing.
- As an agent working in a detached worktree, I can launch the app without
  polluting `%LOCALAPPDATA%\noctty` used by another branch.
- As a debugger reproducing a first-run bug, I can wipe only this worktree's
  runtime state and relaunch.
- As a contributor investigating a shell/profile/config issue, I can open a
  shell with the exact same sandbox environment that the launcher uses.

## Proposed Solution

Add a repo-owned interactive validation harness:

- `scripts/interactive-win11.ps1`
- `scripts/interactive-win11.cmd`

The PowerShell script is the real implementation. The `.cmd` file is a thin
wrapper for users who launch from `cmd.exe` or File Explorer.

The harness will:

1. Resolve the current worktree root.
2. Derive a stable sandbox path under:
   `.sandbox/win11/<worktree-id>/`
3. Create the sandbox directory structure.
4. Reuse the existing Windows bootstrap conventions from `scripts/dev-windows.*`
   so toolchain discovery stays consistent.
5. Optionally build `zig-out/bin/noctty.exe` if requested or if the binary
   is missing.
6. Launch `zig-out/bin/noctty.exe` with environment overrides that redirect
   app state into the sandbox.
7. Optionally open an interactive shell with the same environment.

## Sandbox Model

Each worktree gets a stable sandbox rooted at:

```text
<repo>\.sandbox\win11\<worktree-id>\
```

`<worktree-id>` should be deterministic for the current worktree path and safe
for Windows paths. A simple implementation is:

- canonical worktree path
- normalize path separators
- hash that normalized path
- combine a short slug plus a short hash suffix

Example layout:

```text
.sandbox/win11/<worktree-id>/
  appdata/
  localappdata/
  cache/
  state/
  temp/
  logs/
```

Runtime paths within that sandbox:

- `APPDATA` -> `.sandbox/win11/<id>/appdata`
- `LOCALAPPDATA` -> `.sandbox/win11/<id>/localappdata`
- `XDG_CONFIG_HOME` -> `.sandbox/win11/<id>/localappdata`
- `XDG_CACHE_HOME` -> `.sandbox/win11/<id>/cache`
- `XDG_STATE_HOME` -> `.sandbox/win11/<id>/state`
- `TEMP` / `TMP` -> `.sandbox/win11/<id>/temp`

This aligns with existing app behavior:

- config defaults to `$LOCALAPPDATA/noctty/config.ghostty`
- shell integration installs under `%LOCALAPPDATA%\noctty\shell-integration`
- MRU persists under `%LOCALAPPDATA%\noctty\palette-mru.txt`
- crash/state files already follow XDG / local-app-data style resolution

## Deliberate Environment Choice

The harness will **not** override `USERPROFILE`, `HOMEDRIVE`, or `HOMEPATH` by
default.

Reasoning:

- The target is app-state isolation, not full user-profile emulation.
- Keeping the real Windows user profile makes child shells and user-installed
  tools behave normally during manual testing.
- `noctty` already resolves its state/config paths through
  `LOCALAPPDATA` / XDG-style directories, so overriding those variables is
  sufficient for the primary isolation goal.

If full-profile isolation is ever needed later, it should be an explicit opt-in
mode rather than the default.

## CLI Surface

Expected operator entrypoints:

```powershell
scripts/interactive-win11.ps1
scripts/interactive-win11.ps1 -Rebuild
scripts/interactive-win11.ps1 -ResetState
scripts/interactive-win11.ps1 -OpenShell
scripts/interactive-win11.ps1 -NoBuild
```

Semantics:

- default: launch the app in the sandbox, building only if needed
- `-Rebuild`: force `zig build -Demit-exe=true` before launch
- `-ResetState`: remove this worktree's sandbox state before continuing
- `-OpenShell`: open a Windows shell with the same sandbox env instead of
  launching the app directly
- `-NoBuild`: fail if the binary is missing instead of building it

The `.cmd` wrapper should forward arguments to the PowerShell script.

## Implementation Outline

### `scripts/interactive-win11.ps1`

Core responsibilities:

- resolve repo root from the script location
- compute `worktree-id`
- create sandbox directories
- assemble the sandbox environment block
- validate prerequisites using the same conventions as `dev-windows`
- launch one of:
  - `zig build -Demit-exe=true`
  - `zig-out/bin/noctty.exe`
  - an interactive shell in sandbox mode

Implementation should prefer:

- explicit parameters
- narrow helper functions
- logging the effective sandbox paths before launch
- `Start-Process` for GUI launch so the calling shell is not tied to the app

### `scripts/interactive-win11.cmd`

Responsibilities:

- locate the PowerShell script next to itself
- invoke it with `-ExecutionPolicy Bypass`
- forward all arguments unchanged

### Docs

Update:

- `HACKING.md` with a new "Interactive Win11 Validation" section

Add:

- brief dedicated doc if needed, but prefer keeping the first implementation
  documented in `HACKING.md` unless that file becomes noisy

## Build And Launch Policy

The harness should not always rebuild.

Default policy:

- if `zig-out/bin/noctty.exe` exists, launch it
- if missing, build it with `zig build -Demit-exe=true`
- if `-Rebuild` is set, always rebuild first
- if `-NoBuild` is set and the binary is missing, fail with an actionable error

This keeps the manual loop fast while still giving contributors a one-command
happy path from a fresh worktree.

## Reset Semantics

`-ResetState` removes only:

```text
.sandbox/win11/<worktree-id>/
```

It must not touch:

- the global `%LOCALAPPDATA%\noctty`
- sibling worktree sandboxes
- `.zig-cache`
- `zig-out`

The purpose is clean runtime-state reproduction, not full build cleanup.

## Logging

The launcher should print:

- repo root
- resolved sandbox root
- effective `LOCALAPPDATA`
- effective `APPDATA`
- whether it is building, launching, or opening a shell

Optional follow-up: persist a small launcher log under:

```text
.sandbox/win11/<worktree-id>/logs/
```

This is useful but not required in the first pass if console output is already
clear.

## Failure Handling

Expected failures should be actionable:

- missing Visual Studio dev shell bootstrap
- missing Git for Windows runtime
- missing Zig
- failed `zig build`
- missing `noctty.exe` when `-NoBuild` is used

Failure messages should tell the operator exactly which path or tool is
missing and what command to run next.

## Testing Strategy

This feature is primarily an operator harness, so tests should focus on
deterministic helper logic rather than GUI automation.

Recommended coverage:

- path-to-worktree-id normalization and stability
- sandbox path construction
- argument-surface behavior for conflicting flags
- reset target confinement to the current worktree sandbox

Manual verification checklist for the first implementation:

1. Run the launcher from a fresh worktree with no existing sandbox.
2. Confirm the script creates `.sandbox/win11/<id>/...`.
3. Confirm first launch writes config under the sandboxed `LOCALAPPDATA`, not
   the user's global `%LOCALAPPDATA%\noctty`.
4. Confirm `-ResetState` recreates a clean first-run experience.
5. Confirm `-OpenShell` exposes the same sandbox env variables.
6. Confirm sibling worktrees produce different sandbox roots.

## Acceptance Criteria

- A contributor on Windows can launch `noctty` for manual testing with one
  repo-owned command.
- The launched app uses a stable per-worktree sandbox under
  `.sandbox/win11/<worktree-id>/`.
- Runtime state from one worktree does not overwrite runtime state from another
  worktree.
- The harness supports clean-state reproduction without deleting global app
  state.
- Repo docs point future agents and contributors to this harness as the default
  path for interactive Win11 validation.

## Risks

- Some downstream child processes may still consult non-overridden user-profile
  locations. This is acceptable for v1 because the requirement is app-state
  isolation, not total system emulation.
- A poor `worktree-id` scheme could create collisions or unreadable paths.
  The implementation should keep the human-readable slug short and rely on a
  hash suffix for uniqueness.
- Reusing `dev-windows` logic by copy-paste could create drift. Prefer shared
  conventions and minimal duplication.

## Recommendation

Implement the harness as a PowerShell-first repo script with a `.cmd` wrapper,
per-worktree sandboxing under `.sandbox/win11/<worktree-id>/`, and explicit
support for launch, rebuild, reset, and sandbox-shell workflows.

This is the smallest change that closes the real workflow gap: future agents
and contributors get a concrete, documented, repeatable way to interactively
validate the Windows app from any worktree without trampling shared state.
