# Developing noctty

This fork is Windows-only. The native app target is Win32, the default
build is `noctty.exe`, and the retained secondary deliverable is
`libghostty-vt`.

If you plan to change code here, read [CONTRIBUTING.md](CONTRIBUTING.md)
first; it owns the contribution rules and the scope guard. For the
product direction and visual contract behind UX decisions, read
[PRODUCT.md](PRODUCT.md) and [DESIGN.md](DESIGN.md) before proposing UI
or interaction changes.

## Build and test

Use the standard Zig workflow from the repository root:

| Command                                             | Description                                    |
| --------------------------------------------------- | ---------------------------------------------- |
| `zig build`                                         | Build the Win32 app and bundled resources      |
| `zig build -Demit-exe=true`                         | Force-install `zig-out/bin/noctty.exe`         |
| `zig build test -Demit-test-exe=true --summary all` | Run the full test suite (about 4,500 tests)    |
| `zig build test -Dtest-filter=<name> --summary all` | Run matching tests while iterating (see below) |
| `zig build -Demit-lib-vt`                           | Build the retained `libghostty-vt` library     |

Bare `zig build test` errors in this fork; pass `-Demit-test-exe=true` or
`-Dtest-filter=<name>` (enforced in `build.zig`).

`zig build` also stages Microsoft's pinned ConPTY pair, `conpty.dll` and
`OpenConsole.exe`, beside the exe, so a source build takes the terminal path a
release takes. The first build downloads the package (about 1.7 MB) with
Windows PowerShell into the Zig global cache; later builds only re-hash the
installed pair. If the download cannot happen (no network, `zig build
--system`), the build prints a warning and the exe falls back to Windows'
in-box conhost, which re-renders output and drops colour-query replies;
`noctty +version` and an in-app banner name the reason. A package that does
not match the pin fails the build. Pass `-Dbundled-conpty=false` to skip the
download, for example where policy blocks PowerShell scripts.

The full suite is the only test run to trust on its own, and `--summary all`
is part of it: read the `N/M tests passed` line. `Build Summary: 41/41 steps
succeeded` counts build steps, not tests.

`-Dtest-filter=<name>` runs the tests whose fully qualified name (file path,
`.test.`, test name) contains `<name>`; it is a local convenience, not
evidence. Repeat the flag to match several names. The `N/M tests passed` line
counts the matching tests plus about 70 unnamed `test { ... }` blocks that no
filter excludes, so a name that matches nothing still reports about 70
passes. Subtract that baseline before you trust the number, and expect a
filtered build to compile the whole tree (about a minute). Then run the full
suite and `zig build` before you finish.

A `run test ghostty-test cached` line has no count. Zig prints it when it
reuses an earlier test run instead of running the tests again: under
`zig build --watch`, or when you pin `zig build --seed` and repeat an
identical run. A plain `zig build` picks a new seed and reruns the tests. A
cached result repeats the earlier run's outcome without running anything, so
rerun without `--seed` or `--watch` when you need the count.

## Toolchain

This fork requires a Zig 0.15.x release with patch ≥ 2. The check is
enforced at compile time in `src/build/zig.zig::requireZig`: any 0.14.x,
0.16.x, or 0.15.0 / 0.15.1 toolchain fails with a `@compileError` before
user code runs; 0.15.2 and any later 0.15 patch compile. CI uses 0.15.2
exactly. If you have multiple Zig versions installed locally, check which
one is on your `PATH` before debugging build issues.

If Zig fails before compilation because the dependency cache is empty or
cannot be hydrated automatically for Windows builds, seed it first from
the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-zig-deps.ps1
```

The repo also ships `scripts/dev-windows.ps1` and
`scripts/dev-windows.cmd` to open a Windows-native shell with the
expected Visual Studio and Zig cache environment already configured.

## Manual validation

For manual app validation on Windows, use:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/interactive-win11.ps1
```

This launches the worktree executable with repo-local runtime state under
`.sandbox/win11/<worktree-id>/` instead of global
`%LOCALAPPDATA%\noctty`. Pass `-Rebuild` when you need a fresh
executable after source edits, `-ResetState` for clean first-run repros,
and `-OpenShell` to open a shell with the same sandbox environment.

For a mechanical smoke check that the launched app can start its initial
terminal under the same sandboxed environment:

```powershell
powershell -ExecutionPolicy Bypass -File test/windows/interactive-win11-smoke.ps1
```

If your change touches input, rendering, chrome, or startup behavior,
manually verify:

1. Wheel mouse scrolling in a long buffer.
2. Precision touchpad scrolling, if available.
3. Fast sustained scrolling for flicker, title churn, or dropped repaint.
4. Keybindings affected by the change.
5. Launch `scripts/interactive-win11.ps1 -Rebuild`; add `-ResetState`
   when validating first-run behavior.
6. For UI or chrome changes, also check the accessibility targets in
   [DESIGN.md](DESIGN.md#accessibility-targets): keyboard traversal, High
   Contrast, reduced motion, DPI scaling, and a Narrator or NVDA
   spot-check.

## Runtime notes

- The application runtime is Win32.
- The renderer backend is OpenGL on Windows.
- The repo still retains `libghostty-vt` for Zig and C consumers.

## Project layout (quick map)

- `src/apprt/win32.zig`: Win32 application runtime coordinator containing the
  coupled App, Host, and Surface behavior.
- `src/apprt/win32_theme.zig`: theme tokens, DWM integration, accent
  helpers, HC handling (extracted from `win32.zig` in `a759eb6`).
- `src/apprt/win32/`: focused runtime support modules for constants/externs,
  labels and input, startup/render tracing, native chrome rectangle math, and
  Host-independent GDI paint primitives.
- `src/update/github_releases.zig`: release checks plus verified
  installer staging for user-initiated updates.
- `src/renderer/OpenGL.zig`: WGL + OpenGL 4.3 renderer backend.
- `src/config/Config.zig`: single source of config options and defaults.
- `dist/windows/`: Inno Setup script, icon, manifest, RC file.
- `scripts/`: Windows packaging, dep-cache bootstrap, dev-shell helpers.

Upstream-derived areas intentionally left alone in day-to-day fork work
include `src/terminal/`, `src/font/`, `src/input/`, `src/termio/`,
`src/shell-integration/`, `src/crash/`, and `libghostty-vt` surfaces.

Before importing changes from those areas, read the
[upstream merge policy](docs/upstream-merge-policy.md).

## Logging

Logging to `stderr` is always available. Debug builds also emit
additional diagnostic output.

Win32-specific local traces used during bring-up may also write to
`noctty-win32.log` in the current working directory.

## Formatting

- Zig: `zig fmt .`
- Other docs/resources: `prettier -w .`

## Scope guard

This fork does not preserve the upstream macOS/GTK app surface; when
Windows-native behavior conflicts with upstream cross-platform behavior,
prefer the Windows-native result. The full list of what must not be
reintroduced is in [CONTRIBUTING.md](CONTRIBUTING.md#scope-guard).
