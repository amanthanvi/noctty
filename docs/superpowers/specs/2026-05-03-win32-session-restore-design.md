# Win32 Window Save State Session Restore Design

Date: 2026-05-03
Status: Draft
Scope: make `window-save-state` functional on Win32 before implementation work

## Problem

`window-save-state` already exists in config, but the Windows-only fork still
treats it as a compatibility no-op in `src/config/Config.zig`. At the same
time, the repo already contains a partial Win32 session schema in
`src/apprt/win32_session_state.zig`, plus runtime state in `src/apprt/win32.zig`
for geometry, focused tabs, focused panes, split trees, profile selection,
title overrides, and cached cwd/title metadata.

The gap is wiring these pieces into one deliberate Windows restore flow:

- clear config semantics for `default | never | always`
- a stable persistence location
- a schema contract that matches the current Win32 host/tab/split model
- geometry restore that survives monitor and DPI changes
- privacy boundaries for cwd/title-derived metadata
- failure behavior that never blocks startup

## Relevant Existing Code

- `src/config/Config.zig`
  - `window-save-state` exists and is documented as a compatibility no-op today.
  - `WindowSaveState` already defines `default`, `never`, and `always`.
- `src/apprt/win32_session_state.zig`
  - already defines JSON encode/parse/validate helpers for Win32 session state.
  - current schema is strict about unknown fields and schema version.
  - current payload already models `windows -> tabs -> layout -> panes` with
    pane `cwd`, `profile`, `title_override`, and `tab_title_override`.
- `src/apprt/win32.zig`
  - `Surface.restore_rect`, `Surface.restore_maximized`, and host
    `current_dpi` already track the window-side state a restore flow needs.
  - `MonitorFromWindow`, `GetMonitorInfoW`, `GetDpiForWindow`, and
    `WM_DPICHANGED` handling already exist.
  - `Surface.setPwd`, `Surface.setTitle`, `Surface.setTitleOverride`, and
    `Surface.setTabTitleOverride` already cache pane/session metadata.
  - split cwd inheritance already has Win32/WSL-specific fallback logic.
  - local undo snapshots already prove title/pwd metadata can be captured and
    restored in-memory without round-tripping full process state.
  - `ReplaceFileW` is already declared and documented for crash-safe replace.
- `src/os/xdg.zig`
  - `state()` already resolves `XDG_STATE_HOME`, with Windows fallback to
    `LOCALAPPDATA` and then the known-folder API.
- `scripts/interactive-win11.ps1` and `scripts/interactive-win11-lib.ps1`
  - already sandbox `XDG_STATE_HOME`, `LOCALAPPDATA`, and related paths, so the
    restore flow can be validated without touching the real user profile.
- shell integration emitters
  - `src/shell-integration/powershell/integration.ps1` emits OSC 7 cwd updates.
  - `src/shell-integration/bash/ghostty.bash` and
    `src/shell-integration/zsh/ghostty-integration` emit OSC 7 cwd updates and
    OSC 2 title updates when the `title` feature is enabled.

## Goals

- Make `window-save-state` live on Win32 for normal app launches.
- Restore ordinary Win32 windows, tab order, split layout, selected tab,
  selected pane, zoomed pane, launch profile, and explicit title overrides.
- Restore pane cwd when shell integration or another cwd-reporting path
  populated it before exit.
- Persist session metadata in the normal app state location, not in config or
  cache.
- Soft-fail on missing monitors, schema mismatch, corrupt JSON, or partial save
  data without blocking startup.
- Keep the first implementation metadata-only: no scrollback, no VT replay, no
  process resurrection.

## Non-Goals

- Persisting terminal contents, scrollback, alternate-screen state, command
  history, search state, command palette state, taskbar progress, or undo/redo
  history.
- Recreating running shells, child PIDs, environment variables, or network
  sessions.
- Restoring minimized state.
- Restoring quick-terminal-only, overlay-only, or other transient UI state.
- Persisting raw terminal titles emitted by OSC 2 / shell integration.
- Adding upstream-only behavior or non-Windows runtimes back into the fork.

## Config Semantics

Win32 should stop treating `window-save-state` as a compatibility placeholder
and define concrete behavior:

| Value | Startup behavior | Exit behavior |
| --- | --- | --- |
| `default` | Attempt restore on ordinary app startup. | Save session on clean app exit. |
| `always` | Same as `default` in the first Win32 implementation. | Same as `default` in the first Win32 implementation. |
| `never` | Never load persisted session state. | Never write persisted session state; remove stale state files/markers on clean exit. |

### Why `default` equals `always` in v1

The Windows-only fork has no separate OS session manager to defer to, and the
existing config comments already describe `default` as potentially restorable
when compatibility files exist. Treating `default` as Win32's normal restore
policy is the least surprising behavior and keeps room for a future divergence
if the fork later adds a platform-specific default.

### Restore eligibility

Restore should only run for an ordinary "open the terminal" launch. It should
be bypassed when startup explicitly requests a fresh or targeted session, for
example:

- explicit command execution (`-e ...`)
- explicit CLI action / command-palette style automation launch
- quick terminal style launches
- other future launch modes that already define their own initial window

When restore is bypassed, the session file remains untouched unless the config
is `never`.

## Persistence Path

Session restore state should live under the XDG state directory already used by
the repo on Windows:

```text
${XDG_STATE_HOME}/noctty/window-state.json
```

On a default Windows install, this resolves to:

```text
%LOCALAPPDATA%\noctty\window-state.json
```

Supporting files:

```text
${XDG_STATE_HOME}/noctty/window-state.next.json
${XDG_STATE_HOME}/noctty/window-state.dirty
${XDG_STATE_HOME}/noctty/window-state.corrupt-<timestamp>.json
```

Rationale:

- `src/os/xdg.zig` already provides the correct Win32 resolution order.
- `LOCALAPPDATA\noctty\...` already houses adjacent runtime artifacts such
  as PowerShell shell integration and palette MRU data.
- `scripts/interactive-win11-lib.ps1` already redirects `XDG_STATE_HOME` into a
  per-worktree sandbox, which gives the restore flow an isolated validation
  target for free.

## Schema And Versioning

The existing `src/apprt/win32_session_state.zig` file should remain the schema
home. The implementation should bump the on-disk schema from `1` to `2`.

### Why bump to v2

The checked-in schema is already strict:

- it rejects unsupported schema versions
- it rejects unknown fields
- its tests encode the current contract

Even though no shipped Win32 restore flow writes v1 yet, mutating the checked-in
shape in place would make the tests and schema history misleading. A version
bump keeps the contract honest.

### Proposed v2 shape

Conceptual structure:

```text
SessionState
  schema_version: 2
  selected_window: usize
  windows: []Window

Window
  selected_tab: usize
  placement:
    restore_rect_px: Rect
    maximized: bool
  monitor:
    device_name: []const u8
    work_area_px: Rect
    dpi: u32
  tabs: []Tab

Tab
  selected_leaf: usize
  zoomed_leaf: ?usize
  layout: LayoutTree

Pane
  cwd: ?[]const u8
  profile: ?[]const u8
  title_override: ?[]const u8
  tab_title_override: ?[]const u8
```

The exact JSON field/union encoding should continue to be owned by
`src/apprt/win32_session_state.zig` and its `std.json` tests.

### Structural decisions

- `selected_window` is new at the session root so multi-window restore can
  reactivate the previously frontmost host.
- per-window `placement` and `monitor` are new and carry geometry metadata that
  the current schema lacks.
- `zoomed_leaf` is new per tab because runtime zoom state is currently pointer /
  handle based and cannot survive across launches.
- `Pane` continues to carry:
  - `cwd`
  - `profile`
  - `title_override`
  - `tab_title_override`
- `Pane` deliberately does not gain a raw `title` field in v2.

### Strictness policy

- parse remains strict for the active schema version
- corrupt JSON quarantines on startup
- unsupported newer versions are ignored, but left in place, so a later newer
  build can still consume them

## Geometry, Monitor, And DPI Handling

### What to save

Per restorable window:

- the normal restore rect in physical pixels
- whether the window was maximized
- the saved monitor device name
- the saved monitor work area in physical pixels
- the saved window DPI

The saved rect should be the window's normal restore bounds, not the transient
fullscreen or minimized bounds.

### What not to save in v1

- minimized state
- fullscreen state
- topmost / floating state
- transient overlay / palette / search bar geometry

Those states exist in `src/apprt/win32.zig`, but persisting them in the first
restore pass would widen the surface without meaningfully improving session
continuity.

### Restore algorithm

For each saved window:

1. Resolve the target monitor.
2. Match by saved `device_name` first.
3. If the monitor is gone, fall back to the normal Win32 window-placement
   policy already used for new windows instead of inventing a restore-only
   monitor policy.
4. Scale the saved normal rect by `target_dpi / saved_dpi`.
5. Re-anchor the rect relative to the saved monitor work area, not absolute
   virtual-screen coordinates. This prevents odd jumps when monitor topology
   changes.
6. Clamp the final rect into the target monitor work area.
7. Create/show the window with the clamped normal rect.
8. Apply `maximized` after creation so a later "restore down" returns to the
   correct normal bounds.

### Clamp rules

- maintain at least the app's minimum visible size
- ensure some caption / drag area remains on-screen
- if the saved rect is larger than the target work area after DPI scaling,
  shrink to fit

### Why this matches the current runtime

`src/apprt/win32.zig` already tracks:

- `Surface.restore_rect`
- `Surface.restore_maximized`
- host `current_dpi`
- monitor queries through `MonitorFromWindow` and `GetMonitorInfoW`
- per-monitor DPI changes through `WM_DPICHANGED`

The restore implementation should reuse that model rather than layering a second
window-geometry concept beside it.

## Tabs, Splits, Zoom, And Active State

### Tab and split serialization

Serialize tabs in current UI order. Reuse the existing `LayoutTree` node model
from `src/apprt/win32_session_state.zig`:

- `root`
- `nodes`
- split `axis`
- split `ratio`
- split child node indexes

### Focus and zoom

Persist focus using stable leaf ordinals, not pointer values:

- `selected_tab` already identifies the active tab
- `selected_leaf` identifies the focused pane within that tab
- `zoomed_leaf` should identify the zoomed pane, if any

Leaf ordinals should be derived from the same DFS leaf walk used by schema
validation, so encode and decode share one stable ordering rule.

### Restore order

To avoid focus and zoom races:

1. create all windows
2. create all tabs
3. create all panes / split trees
4. apply selected leaf per tab
5. apply selected tab per window
6. apply selected window at session root
7. apply zoom last

Applying zoom last ensures the target pane already exists and can become the
visible zoom target cleanly.

## CWD And Title Preservation

### CWD

Pane cwd should be restored when known, using the existing optional `Pane.cwd`
field.

Data sources already exist:

- `Surface.pwd` cache in `src/apprt/win32.zig`
- live terminal cwd through `Surface.core().pwd(...)`
- shell integration OSC 7 emitters in PowerShell, Bash, Zsh, Fish, and Elvish

Restore behavior:

- if a saved `cwd` exists, use it for the pane startup config
- if it is missing, invalid, or not representable for the selected profile,
  fall back to the existing working-directory/profile behavior
- reuse the current Win32 split cwd fallback and WSL translation rules instead
  of inventing session-restore-specific path heuristics

### Title

Persist only explicit user-controlled title overrides:

- `title_override`
- `tab_title_override`

Do not persist raw terminal titles in v1.

Rationale:

- the existing schema already models only override fields
- Bash/Zsh shell integration title features can emit the active command text
  before prompt return
- persisting raw `Surface.title` would capture more sensitive data with little
  structural value

This keeps the privacy boundary tight while still preserving deliberate user
renames entered through the Win32 rename overlay paths.

## Save And Restore Lifecycle

### Startup

1. Load config.
2. If `window-save-state = never`, skip restore and clear stale dirty/temp
   markers.
3. If launch arguments imply a fresh session, bypass restore.
4. Resolve the state file path.
5. If `window-state.dirty` exists, note that the previous session ended
   unexpectedly.
6. If `window-state.json` exists:
   - parse/validate it
   - quarantine corrupt payloads
   - ignore unsupported newer versions
   - restore windows if valid
7. Create the new dirty marker for the current run once startup commits to the
   normal session path.

### Clean exit

1. Gather current restorable windows.
2. Encode session JSON.
3. Write `window-state.next.json`.
4. Atomically replace `window-state.json` using `ReplaceFileW` when the primary
   file already exists.
5. Delete `window-state.next.json` on success if the replace path leaves it
   behind.
6. Remove `window-state.dirty`.

### Crash / forced termination

If the process dies before the clean-exit write completes:

- the old `window-state.json` remains the last known-good session
- `window-state.dirty` remains as evidence of an unclean end
- the next startup may restore the last clean snapshot, but should log or show
  a lightweight warning that the most recent session was not fully saved

No crash-time snapshotting is proposed for v1.

## Corruption And Compatibility Behavior

### Corrupt or invalid JSON

- rename to `window-state.corrupt-<timestamp>.json`
- log the parse/validation error
- continue with a fresh startup

### Unsupported newer schema

- do not delete or rewrite the file
- log that the file is from a newer build
- continue with a fresh startup

Leaving newer files in place makes downgrade/upgrade testing less destructive.

### Missing profile or invalid cwd

- missing profile key: fall back to the default launch profile for that pane
- invalid/unusable cwd: fall back to current working-directory rules
- these are soft restore degradations, not startup blockers

## Privacy And Security

The state file is plain JSON stored in the user's state directory. It will
contain:

- window geometry
- monitor identifiers
- pane cwd paths
- profile keys
- explicit title/tab-title overrides

It must not contain:

- terminal contents or scrollback
- command lines
- shell history
- environment variables
- raw terminal titles emitted by shells/programs
- clipboard contents

Implications:

- cwd paths can still reveal project names, usernames, hostnames, or remote
  mounts
- users who do not want any of that persisted must be able to use
  `window-save-state = never`
- no special ACL work is required in v1 beyond the normal user-profile
  protections of `%LOCALAPPDATA%` / `XDG_STATE_HOME`

## Tests And Harness Plan

### Unit tests

Extend `src/apprt/win32_session_state.zig` tests to cover:

- v2 round-trip with `selected_window`, geometry, monitor metadata, and
  `zoomed_leaf`
- invalid `selected_window`
- invalid `zoomed_leaf`
- strict unknown-field rejection for v2
- unsupported-version behavior

Add targeted Win32 runtime/helper tests for:

- monitor-match fallback
- DPI scaling and work-area clamping
- leaf-ordinal mapping for focused vs zoomed panes
- profile fallback when a saved key is missing
- cwd fallback when a saved path is unusable

### Interactive harness validation

Use the existing sandboxed launcher:

```powershell
scripts/interactive-win11.ps1 -ResetState -Rebuild
```

Validation scenarios:

1. Create multiple windows, tabs, and splits; rename a tab; use multiple shell
   profiles; exit cleanly; verify restore.
2. Maximize a window, move it to another monitor if available, relaunch, and
   verify clamp/placement behavior.
3. Launch under sandbox, verify the session file lands under the sandboxed
   `XDG_STATE_HOME`, not the real `%LOCALAPPDATA%`.
4. Kill the process after layout changes but before clean exit; confirm the next
   launch restores only the last clean snapshot and reports the unclean end.
5. Manually corrupt `window-state.json`; confirm quarantine and fresh startup.

### Harness follow-up

After the core implementation lands, add a restore-focused Win11 harness script
that automates the above scenarios inside the existing interactive sandbox
environment instead of depending only on manual validation.

## Staged Implementation Milestones

### Milestone 1: Config + path plumbing

- make `window-save-state` live in Win32 startup/exit policy
- add state-path helpers rooted in `src/os/xdg.zig`
- wire `never` cleanup semantics

### Milestone 2: Schema v2

- extend `src/apprt/win32_session_state.zig` with root/window metadata and
  `zoomed_leaf`
- keep strict validation
- add unit coverage before runtime wiring

### Milestone 3: Save path

- serialize live Win32 host/tab/surface state into schema v2
- write through `window-state.next.json`
- atomically replace the primary file
- add dirty-marker lifecycle

### Milestone 4: Restore path

- gate restore on startup eligibility
- rebuild windows/tabs/splits from schema
- restore selected window/tab/pane and zoom state
- apply geometry/monitor/DPI placement rules

### Milestone 5: Hardening

- corruption quarantine
- unsupported-version handling
- harness coverage for sandboxed validation
- user-facing docs/config notes for privacy and fallback behavior

## Recommendation

Implement Win32 session restore as a metadata-only, strict-schema, crash-safe
state file under `XDG_STATE_HOME` / `%LOCALAPPDATA%`, reusing the existing
`win32_session_state.zig` schema home and current Win32 geometry/cwd plumbing.

The key design boundary is deliberate:

- restore structure, geometry, focus, zoom, profile, cwd, and explicit renames
- do not restore terminal contents or raw command-derived titles

That boundary is small enough to ship safely, but large enough to make
`window-save-state` real on Windows.
