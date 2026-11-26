# Agent Development Guide

A file for [guiding coding agents](https://agents.md/) working in this
Windows-only Ghostty fork. Before you change, diagnose or measure code, do the
reading step under [Self-Correction Log](#self-correction-log).

## Commands

- **Build:** `zig build` (also stages the pinned `conpty.dll` and
  `OpenConsole.exe` beside the exe; staging traps: the 2026-10-10 bundled
  ConPTY entry in `docs/agents/log/conpty.md`)
- **Test (Zig):** `zig build test -Demit-test-exe=true --summary all --test-timeout 120s`
  (full suite, ~6.8k tests, several minutes). This is the only invocation that
  is trustworthy on its own, and `--summary all` is part of it: the count is
  the evidence. `--test-timeout 120s` has Zig 0.17.1's build runner report a
  test still running after two minutes as timed out instead of waiting on it
  (CI passes it on every `zig build test` step).
  - `-Dtest-shards=4` runs it as four concurrent processes with the same
    count, about a third of the time (test-harnesses.md: 2026-11-11
    TEST-SHARDS-01).
  - `-Dtest-optimize=ReleaseSafe` builds the test executable in that mode
    (default Debug). `-Doptimize` does not set its mode, and any value but
    Debug breaks its compile. The summary's `compile test ghostty-test <mode>`
    line names the mode (build-release-ci.md: 2026-11-18 TEST-OPTIMIZE-01).
  - Bare `zig build test` errors in this fork.
  - `-Dtest-filter=<token>` (one token: quote it or use a no-space
    substring, or `zig build` reads the rest as step names) runs the tests
    whose fully qualified name (file path, `.test.`, test name) contains the
    token, for quick iteration; it is not evidence on its own. Read the
    count: the `N/M tests passed` line counts the matching tests plus about
    70 unnamed `test { ... }` blocks that no filter excludes, so a token that
    matches nothing still reports about 70 passes, not zero. Use `ConPTY` to
    reach the probe tests in `src/pty_transport_probe.zig`. A filtered build
    compiles the whole tree, about a minute.
    `Build Summary: 41/41 steps succeeded` counts build steps, not tests.
    Filter traps: the 2026-10-06
    entry in `docs/agents/log/test-harnesses.md`.
- **Formatting (Zig):** `zig fmt .`
- **Formatting (other):** `prettier -w .`
- Run `zig build*` through `scripts/dev-windows.cmd` (or an equivalent
  VS-dev + Zig 0.17.1 shell); the ambient shell can miss the native toolchain
  and fail with misleading dependency errors. A build root on another drive
  than the effective Zig global cache (a review clone under `H:\scratch`
  with the default `%LOCALAPPDATA%\zig`) asserts in the build runner: set
  `ZIG_GLOBAL_CACHE_DIR` on the build root's drive first (build-release-ci.md:
  2026-11-13 BUILD-CROSS-DRIVE-CACHE). A direct `zig test <file>`
  misses the build graph's generated modules (`build_options` and others).
  For code that needs those modules, use the full-suite command above or
  `zig build test -Dtest-filter=<token>` for iteration. Pure helpers may use
  a temporary package-root harness. (test-harnesses.md: 2026-04-18
  `scripts/dev-windows.cmd` and raw `zig test`; 2026-05-01 direct
  `zig test src/apprt.zig`.)

## No required interactive tests

- No change, check, review, merge or release requires an interactive or
  visible-desktop test (the maintainer's decision, 2026-11-22). Evidence
  comes from hosted CI, private- and hidden-desktop tests, and multi-agent
  review.
- Never block, defer or fail work for want of a visible run, and never make
  one a prerequisite. A visible run (the interactive composite, a tier-3
  check) is optional: it starts only on the maintainer's explicit go, only
  while the maintainer is away, and never touches their real state; the
  rules below say how.

## Running noctty

- Run noctty on a private desktop (`CreateDesktopW`), and pass
  `lpDesktop = WinSta0\<desktop>` to every process you start. A process
  created on a private desktop by name passes it to the children it starts
  with a null one, but a driver moved there with `SetThreadDesktop` does not:
  its children land on the user's desktop, and noctty takes the foreground
  (test-harnesses.md: 2026-11-20 GUI-HIDDEN-DEFAULT-01). Drive it with
  posted messages (`SendInput` types into whatever window is in front): a
  key as a posted `WM_KEYDOWN`/`WM_KEYUP` pair, since a posted triple types
  it twice and a bare posted `WM_CHAR` types nothing. A posted Alt never reaches
  `GetKeyboardState`, and a pass from posted input is not a pass for real
  input. (window-frame.md: 2026-09-24 `window-decoration = none` trap 1,
  2026-09-23 "Item (b) of the #262 entry" harness notes, 2026-10-16 #285
  window menu; renderer.md: 2026-10-14 LAT-01; input.md: 2026-09-19 #250;
  test-harnesses.md: 2026-09-23 #261 trap 3.) What a private desktop cannot
  show (a D3D11 present, which needs a composed, visible desktop; real input)
  only a visible run shows; such a run is optional and starts only on the
  maintainer's explicit go, once the user is away.
  (search-scrollbar.md: 2026-10-16 D3D11-IFLIP-01; window-frame.md:
  2026-10-16 real DPI drag, last trap.) In a hosted closure (the
  hidden-desktop suite, `test/windows/gui-hidden-runner.ps1`), real-input and
  foreground calls are reached only through
  `scripts/interactive-win11-realinput.ps1` (`InteractiveWin11RealInput`),
  which window-lib loads only outside hosted mode and which throws if loaded
  there; a hosted leaf ends by checking that its type was never loaded.
  Outside the suite's closure, `bench-windows.ps1`, `bench-frame-pacing.ps1`,
  `gui-hosted-probe.ps1` and `interactive-win11-hints.ps1` keep their own
  declarations, as do the leaf-local types until later offload PRs move
  them. Screen capture stays behind `Save-StatefulScreenCapture`
  (test-harnesses.md: 2026-10-25 EVIDENCE-SCREENSHOT-PRIVACY-01). A
  hidden-desktop suite run, local or hosted, starts only a fresh portable
  copy, without `noctty.ico`, of the receipt-bound measurement build, with
  `NOCTTY_INTERACTIVE_MEASURE_AUMID=1`. Other local GUI runs start either
  the raw measurement build (test-harnesses.md: 2026-10-20
  STANDALONE-LEAF-AUMID-01) or a portable copy without `noctty.ico`
  (app-lifecycle.md: 2026-10-16 "A portable copy"), never a non-portable
  `zig-out` build, which writes the product AUMID's jump list and
  registration.
- A GUI check runs in the lowest tier that can make its assertion: (1) a
  private desktop in hosted CI, the default; (2) a private desktop on a local
  machine with a GPU, for OpenGL and custom-shader rendering read back
  offscreen with the test-tools build, and GL-side traces; (3) a visible run,
  for real `SendInput` through the message loop, foreground acquisition,
  pixels as DWM composes them on screen (`CopyFromScreen`, a D3D11 present),
  the production OpenGL path into the window's framebuffer, and any present
  paced by vblank. Tier 2's readback never sees the production framebuffer,
  and a hidden `SwapBuffers` is never vblank-paced (renderer.md: 2026-10-19
  #408 trap (4), 2026-10-14 LAT-01 trap (1)). Every gating GUI check, in any
  tier, has a positive oracle and a negative control that fails it. No
  release, merge or check requires a visible or interactive run (the
  maintainer's decision, 2026-11-22): tier 3 and the interactive composite
  stay available, and a multi-agent council review takes their place.
  (test-harnesses.md: 2026-11-20 GUI-HIDDEN-DEFAULT-01.)
- Run a scratch portable copy (`noctty.portable` beside the exe) with
  `--window-save-state=never` and `LOCALAPPDATA` redirected for that noctty;
  that isolates session and startup state. If a `zig build` runs under the
  redirect, pin `ZIG_GLOBAL_CACHE_DIR` to the real Zig cache (the one under
  the original `LOCALAPPDATA`), or, for a build root on another drive than
  that cache, to a cache on the build root's drive: a build root and its
  effective cache must share a drive (build-release-ci.md: 2026-11-13
  BUILD-CROSS-DRIVE-CACHE). Zig 0.17.1 also unpacks a build's packages into
  `zig-pkg/` in the build root (`ZIG_LOCAL_PKG_DIR` moves it), which the
  redirect does not move: leave `ZIG_LOCAL_PKG_DIR` unset or on the build
  root's drive, since the packages' own build steps then run from it, as they
  ran from the global cache before (inferred from 0.17.1's
  `lib/compiler/Maker/Fetch.zig`, not yet measured). A test that
  reached the real `%LOCALAPPDATA%\noctty` once put the user's launches into
  safe mode. (window-frame.md: 2026-09-23 "Item (b) of the #262 entry";
  test-harnesses.md: 2026-09-23 #261 trap 2.) Give each PowerShell you type
  into a run-local PSReadLine history path or `SaveNothing` before its first
  read: PSReadLine finds its history through a known folder (setting it needs
  `-Command`, which turns off automatic injection: dot-source
  `integration.ps1` as `buildCommandValue` does). Separately, a `-e` fixture
  sets only `initial-command`, so later tabs and splits start `command`, a
  PowerShell by default (pwsh, else Windows PowerShell): set it with a
  `command = direct:<absolute System32 cmd.exe> /D` line in the config file
  the launched copy reads, unless the fixture tests a configured `command`.
  A bare `cmd.exe` runs the user's AutoRun (conpty.md: 2026-11-18
  REPLY-PATH-01 item (6)), and `Start-Process -ArgumentList` joins elements
  with spaces and quotes nothing, so a spaced `--command=… /D` in argv loses
  `/D`; only a harness that builds its own quoted command line (the soak, the
  reply-path harness) may pass it there. Give each `-e` stimulus that starts
  cmd the absolute path and `/D` as separate arguments. Until the interactive
  composite is retired, the shared helper (`Get-InteractiveWin11LaunchArguments`)
  keeps `--command=cmd.exe` on its non-hosted route unless
  `-UseConfiguredCommand` is set, a standalone run of a legacy leaf included.
  Guard the run with
  `scripts/windows-harness-history.ps1`, which only detects a change to the
  real history's size or mtime. (test-harnesses.md: 2026-10-11 PKG-13,
  2026-10-17 PKG-76, 2026-10-19 HARNESS-PWSH-HISTORY-01.)
  Before a portable-identity or baseline comparison, read app-lifecycle.md,
  2026-10-16 "A portable copy": portable mode does not give a copy its own
  AUMID or registry key.
- Test copy, paste and OSC 52 through a unit seam. A private desktop shares
  the user's clipboard (it belongs to the window station). A named
  `CreateWindowStationW` returns `ERROR_ACCESS_DENIED` for this account, but
  a NULL-name call succeeds and gives a noninteractive service station, so a
  private station is possible: check `UOI_NAME` is not `WinSta0`, set every
  child's `lpDesktop` to it, and never assume it starts empty. A run on
  WinSta0 starts nothing that can copy or fall back to a copy, reads nothing
  from the clipboard, and logs `GetClipboardSequenceNumber()` before and
  after. (launch-and-paths.md: 2026-10-15 PKG-42; clipboard.md: 2026-10-15
  OSC 52 request, trap 5, and 2026-10-22 RDPCLIP-1 station trap.)
- A null result needs a positive control before it becomes a causal claim.
  (window-frame.md: 2026-09-14 `background-blur`.)

## Win32 FFI

- An API that returns a `HANDLE` and fails with NULL returns `?HANDLE`
  (`std.os.windows.HANDLE` is non-null). Before mirroring an SDK struct,
  check its packing (`pshpack*.h`) and pin its size and offsets in a test.
  (tooling.md: 2026-05-01 `CreateJobObjectW` and Job Object sizes;
  app-lifecycle.md: 2026-10-09 minidump;
  accessibility.md: 2026-04-16 VARIANT.)

## Logging

- Never write a command, its arguments, an environment value or a working
  directory into a log line: log its kind and size with `src/os/redact.zig`
  (`bytes`, `optionalBytes`, `argv`) or `Command.redacted()`.
  (launch-and-paths.md: 2026-10-25 LIST-PROFILES, trap (2).)

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Demit-lib-vt=true --summary all` (CI's
  `windows-lib-vt` job; the step errors without `-Demit-lib-vt=true` in
  this fork). It is the only step that runs the C API tests in
  `src/terminal/c/`, so a change in a libghostty-vt file runs it as well
  as the full suite above. `-Dtest-filter=<token>` works here as above,
  for iteration only.
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- Win32 application runtime: `src/apprt/win32.zig` holds the forwarding
  aliases for App, Host, and Surface, the native window procedures, shared
  helpers, and the tests that combine owners; `src/apprt/win32/app.zig`,
  `host.zig`, and `terminal_window.zig` hold App, Host, and Surface;
  `src/apprt/win32_theme.zig` owns theme policy; focused modules under
  `src/apprt/win32/` own session capture and restore, the quick terminal host,
  window state, surface presentation, the docked search controls, overlay and
  palette orchestration, the chrome scene, child-control plumbing
  (`child_window.zig`), Win32 constants/externs, input (`input.zig`), what a
  confirm prompt, a tab label and the host overlay say (`confirm_text.zig`,
  `tab_label.zig`, `overlay_view.zig`) and which profile a pick names
  (`profile_pick.zig`), owned and bounded text (`text.zig`), startup/render
  tracing, chrome rectangle math, and GDI paint primitives.
- Windows packaging: `dist/windows/` + `scripts/package-windows.ps1`
- libghostty-vt headers: `include/ghostty/`

This fork ships only the Win32 runtime (`src/apprt/win32*`): it removed the
upstream `macos/` Xcode app and the `src/apprt/gtk` runtime, and they stay
out.

## Issue and PR Guidelines

- Never create an issue; report findings in the conversation or the PR
  instead.
- Never create a PR to the upstream Ghostty repo; only work against this
  fork, `amanthanvi/noctty`.
- If the user asks you to create an issue or PR, confirm the target is this
  fork and refuse any upstream publish request. If publishing is still
  disallowed by the active task contract, offer a local patch summary or
  handoff instead.
- `gh` can resolve upstream `ghostty-org/ghostty` here: pass
  `--repo amanthanvi/noctty` to every `gh` command that takes it (name it
  where the repository is positional, as in `gh repo view amanthanvi/noctty`),
  and push to `origin`. (tooling.md: 2026-05-01 `gh pr view`/`gh repo`
  upstream; 2026-04-20 publish against `origin`.)

## Self-Correction Log

The log records measured traps: what looked true and was not, the evidence,
and the rule now. It lives in [`docs/agents/log/`](docs/agents/log/), one
file per area, dates descending.

Before you change, diagnose or measure anything, read every area file whose
trigger below matches the work, and run `git grep -n <term> docs/agents/log/`
for each symbol you will change, each Win32 API you will newly call, and the
error you are chasing (the error name, such as `AccessDenied`): an entry can
cover a second subject filed elsewhere. Read each file from the top, header
included: a newer-dated entry, or an item under "Corrected in other files",
overrides an older one on the same subject; entries that share a date are
not always newest first, and when they disagree the code decides. A function
an entry calls load-bearing may have lost its callers since, so re-verify
call sites before relying on it. You are done when you can name the entries
that govern each symbol you change, or that none does.

- [conpty.md](docs/agents/log/conpty.md): `src/pty.zig`, the pty reader (and
  its stack size, `os.surfaceThreadSpawnConfig`, and how much of it code
  uses, `stackUse` in `os/main.zig`, including the reparse walk the kitty
  file open runs there: `os/local_path.zig` `walk`, `openRoot`,
  `readLinkTarget`) and write pool in
  `termio/Exec.zig`, `ResizePseudoConsole` and the renderer lock
  `Termio.resize` holds across it, in-box conhost
  versus the bundled `conpty.dll`/`OpenConsole.exe`
  (`scripts/stage-conpty-redist.ps1`), what ConPTY's buffer holds after a
  resize, minimize, clear or undo and the column reflow that has to match it
  (`Screen.resize` and where its prompt redraw starts clearing,
  `promptRedrawStart` and `clearPromptForRedraw`, the replay tests in
  `src/terminal/resize_replay.zig`, the
  sync harness `test/windows/interactive-win11-conpty-sync.ps1`), which
  terminal replies reach a console program through ConPTY's input and in what
  shape (the reply-path harness
  `test/windows/hidden-win11-conpty-reply-path.ps1` and its reader
  `test/windows/console-reply-reader.c`), the
  Ctrl+C-ignore attribute hosted shells inherit
  (`process_shared.enableGuiChildCtrlC` in `src/main_ghostty.zig`).
- [shell-integration.md](docs/agents/log/shell-integration.md): scripts under
  `src/shell-integration/` (PowerShell `integration.ps1`, cmd/Clink, Git
  Bash's `ghostty.bash`, zsh's `ghostty-integration`, Nushell's `ghostty.nu`)
  and their injection (`termio/shell_integration.zig` argv analysis,
  `windows_visual_studio.devShellPrelude`, `win32_powershell_install.zig`):
  the OSC 133 and OSC 7 marks a shell emits and the directory and host names
  in them, Nushell's `@complete external` floor, PSReadLine hooks, execution
  policy, keyboard-mode recovery at the prompt after a TUI leaves Kitty or
  modifyOtherKeys flags set (`CSI <99u`, `CSI >4;0m`).
- [terminal-core.md](docs/agents/log/terminal-core.md): `src/terminal/` (VT
  parser limits, `PageList` and its page serials (`page_serial_epoch`,
  `nodeIsValid`, the source renewal in `PageList.split`), `PageList.Node`'s
  accessors (`page()`, `rows()`, `cols()`, `capacity()`, `Node.Data`, and
  from the stepping-stone merge upstream's `pageIfResident()`,
  `pagePreservingState()`, `pageAssumeResident()`, `storage()` and
  `Node.owned`), the page owner in `destroyNodeExt` and `compact`, the
  Node section of `docs/upstream-merge-policy.md`, and their callers in
  `src/inspector/widgets/pagelist.zig`, `snapshotDocumentWindow` in
  `src/apprt/win32_uia/text.zig` and the session readers in
  `src/apprt/win32/session.zig` (`captureTerminalScrollbackSnapshotAlloc`,
  `terminalScreenIsUnpainted`), OSC parsers,
  OSC 133 exit codes, prompt typeahead
  in `semantic_command.zig` and what drops its last command when rows or
  cells move (`invalidateRange`, `invalidateMarginShift`, from
  `Terminal.scrollUp`), the scrollback search thread and its cached
  results (`ScreenSearch.pruneHistory`, `LiveNodes`), what a search window
  copies at append (`SlidingWindow.append`, `AppendResult`), the regex,
  whole-word and case matcher and its run-time failure latch
  (`search/pattern.zig`: `Pattern`), one query over a terminal and its
  reports (`search/query_search.zig`: `QuerySearch.step`), the selection
  and search-highlight rows of `RenderState` (`render.zig`),
  `TerminalFormatter`/`ScreenFormatter` output for undo snapshots and Copy as
  HTML, Kitty graphics commands, placements and deletes in
  `kitty/graphics_command.zig`, `kitty/graphics_storage.zig` and
  `kitty/graphics_exec.zig`, the file reads of `kitty/graphics_image.zig`
  `readFile`, and tmux control mode in `tmux/`: `control.Parser`,
  `Layout.max_depth`, the `Viewer`), `os/file.zig` `allocTmpDir` and
  `os/TempDir.zig`, OSC 7 and OSC 9;9 cwd reports
  (`termio/stream_handler.zig`, `os.hostname.isLocal`, `os/local_path.zig`
  `pwd`, and the stored-pwd spellings in `os/path.zig`), `src/Surface.zig`
  locking around links (the left release: `linkAtLocked`, `processLinks`,
  `maybePromptClick`, and the hover refresh it runs first, `mouseRefreshLinks`
  with `Mouse.activeLeftClickPin`, and the tracked pins an in-place scroll
  moves: `Screen.cursorScrollRegionUp`, `PageList.eraseRow`,
  `PageList.eraseRowBounded`) and its left-click selection path
  (`Mouse.left_click_pin`, `dragLeftClickTriple`, `selectionScrollTick`;
  not upstream's `SelectionGesture`),
  and `ShellExecute*` calls queued for the message loop
  (`App.deferShellRequest`, `drainDeferredOpens`).
- [renderer.md](docs/agents/log/renderer.md): `src/renderer/` and
  `src/renderer.zig` (OpenGL/WGL,
  the D3D11 beta and GL-to-D3D11 fallback, who frees the config of a failed
  `Renderer.init` in core `Surface.init`, frame pacing, the cursor blink
  and their timers in `Pacer.zig` (`Pacer.turn`, `Pacer.Clock`, the port
  `Thread.Frame`, the test adapter `pacer_sim.zig`),
  `win32_power.renderer_clock` and the pacing timebase
  `src/os/monotonic.zig` (also the wake-notify stamp
  `State.last_render_wakeup_notify_ns`),
  synchronized output, vsync, `RenderPass` viewport, cursor sprites,
  search highlights after a resize, the IME preedit and composition caret in
  `rebuildCells` and `State.Preedit.layout`, the glyph options `addGlyph` and
  `addPreeditCell` pass), the unfocused-split dim
  (`split_dim`, `Host.syncSplitDim`), `win32/pixel_format.zig`, Windows font
  discovery (`src/font/discovery_windows.zig`: the registry scan, variable
  `wght` bounds, bold matching), font fallback and `font-thicken`, renderer
  wakeups from `termio` and typing latency, the libxev IOCP timers the
  renderer arms (`Thread.timerCallback`, a `Canceled` run, the libxev pin in
  `build.zig.zon`), repaint during live resize
  (`win32/surface_presentation.zig`), the line a surface logs once its
  renderer has started, which the hidden-desktop suite reads (`logStarted`
  and its scope `renderer_start` in `src/renderer/Windows.zig`; a new line in
  the `renderer_windows` scope changes the count #738's hosted probe takes),
  which DLLs a CLI action or the D3D11
  backend loads (the OpenGL32 static import), and the renderer-state mutex
  with its runtime thread-role layer (`src/sync/state_mutex.zig`:
  `StateMutex`, the types of its carriers, `assertHeld`, the demand acquire
  `State.lockDemand` forwards to, the panics PN1 to PN7; the roles in
  `src/sync/thread_role.zig`: `enter`, `fixture`, and `assertWindowProc`,
  which every fork window and subclass procedure calls first; the
  pair recorder `src/sync/recorder.zig` and its dump `src/sync/dump.zig`;
  and a site it keys by build mode, `stream_handler.surfaceMessageWriter`'s
  calling convention).
- [window-frame.md](docs/agents/log/window-frame.md): the top-level window:
  `WM_NCCALCSIZE`/`WM_NCHITTEST` (`win32_nc_layout.zig`), integrated titlebar
  and caption buttons, `window-decoration = none`, resize bands, maximize,
  fullscreen and restore placement (one copy per window, `TopLevel` on
  `Host.top_level`, changed by `window_state.perform` and `applyConfig`;
  the `WM_GETMINMAXINFO` reader, `updateMinMaxInfo`; a pane's own metrics,
  `Surface.metrics`; the rect a fullscreen window covers, one pixel past a
  free monitor edge for OpenGL with the tab bar hidden (#598):
  `composedFullscreenRect` in `win32/window_start.zig`,
  `keepsFullscreenComposed` (its decision, `composesFullscreen` over
  `PaneRenderer`), `fullscreenRect` and `MonitorRects` in
  `win32/window_state.zig`;
  the `maximize`/`fullscreen` keys at window start: `Enter` and
  `forRestore` in `win32/window_start.zig`; what a session saves and
  restores of a fullscreen window: `WindowState.fullscreen` and
  `fullscreen_maximized` in `win32_session_state.zig`,
  `window_state.sessionPlacement`, the restore stages of
  `window_state.advance`, and `restoreSessionWindow` in `win32/session.zig`),
  what a new window copies from its source and which forwarded keys it keeps
  (`window_state.begin` and `advance`, with its `Origin` and
  `Host.pending_start`, in `win32/window_state.zig`; the pure `plan`,
  `place` with its `Occupied`, `returnOn` and `Keeps` in
  `win32/window_start.zig`; `Registry.newWindowSource` and
  `windowStartsAt`), `WM_DPICHANGED` and mixed-DPI moves,
  `window-width`/`window-height`, `background-opacity` and DWM backdrop (how
  a window shows it: `TopLevel.shows` in `win32/window_start.zig`; blur-behind,
  the layered fade, the solid child controls and the panes' renderer opacity:
  `applyBackgroundOpacity`, `refreshBackgroundOpacity`,
  `retryBackgroundOpacity`, `releaseBackgroundOpacity`, `childCreated` and
  `solidifies` in `win32/window_state.zig`, with `Host.chrome_alpha` and
  `Host.blur_behind_failed`; when a window shows it again: the `opacity`
  argument of `App.reconfigureTheme`, `App.systemColorSetChanged` (every
  system theme message, `WM_THEMECHANGED`, `WM_SYSCOLORCHANGE` and a
  theme-affecting `WM_SETTINGCHANGE`, with a light/dark change's reload),
  `reconfigureSystemTheme` and its two
  baselines (the rebuild's, `App.system_theme_refresh` and
  `SystemThemeSnapshot`, which `reconfigureTheme` and `App.init` set; the
  retry's, `App.system_inputs` and `window_state.SystemInputs`, which only
  `App.takeSystemInputs`, from `reconfigureSystemTheme` and
  `systemColorSetChanged`, and `App.init` set), `App.endSettingsPreview`
  (and the Settings rollback that ends both previews through it:
  `rollbackPreviews`, the handle's `endPreviews`, and
  `App.settingsEndPreviewsThunk`, which the Settings test fixtures share), the
  window half of a config change (the `.surface` and `.app`
  `config_change` arms, `App.app_wide_config_change`,
  `App.updateCoreConfig`, `App.updatePaneCoreConfig`, and after a failed
  update `App.app_wide_windows_applied`, `App.applyWindowsConfig` and
  `App.reloadKeptConfig`), and
  `Host.closing` in `Host.closeConfirmed` and `App.windowDestroyed`;
  `Surface.setBackgroundOpacity`,
  `rendererSwitchedToOpenGL` and `WM_WINHOSTTY_RENDERER_SWITCHED`; the
  renderer's `background_opacity_override`; how a pane's frame reaches a
  window that composes its alpha: `composesAlpha` and `splitDimPass` in
  `src/renderer/generic.zig`, `OpenGL.composed_alpha`, `presentsComposed`,
  `OpenGL.present`, `presentComposed`, `drawComposed` and
  `composedDimUniform` in `src/renderer/OpenGL.zig`, `Target.Options.sampled`,
  `initSampled` and `Target.composed_dim` in `src/renderer/opengl/Target.zig`,
  `initPresentComposedPipeline` and the `split_dim` pipeline's flags in
  `src/renderer/opengl/shaders.zig`, and
  `src/renderer/shaders/glsl/present_composed.f.glsl`), the
  window menu, a torn-off tab's window (`window_state.Origin.tear_off`,
  `window_start.placeTearOff`), the quick terminal (`win32_quick_terminal.zig`,
  `win32/quick_terminal_host.zig`).
- [chrome-tabs-paint.md](docs/agents/log/chrome-tabs-paint.md): tab buttons
  (`tabButtonProc`, `drawButton`, labels, tooltips, close X and the press it
  needs (`Host.tab_close_press`, `App.takeHeldRelease`), the active tab's
  join to its terminal, `win32_tab_visual.zig`; what a tab's label, tooltip
  and UIA name say and which tabs the strip shows: `win32/tab_label.zig`,
  `key`, `text`, `tooltip`, `uiaName`, `visible`, and `Tab.cachedKey` and
  `Tab.setCachedKey`), `window-show-tab-bar`, chrome theme and system accent
  (`win32_theme.zig`), focus cues (`win32/focus_cue.zig`), `win32_icons.zig`,
  titlebar and tab-row icon fonts (`recreateTitlebarIconFonts`,
  `createIconFontWithGlyphs`, `fontGlyphCoverage`, `drawTitlebarGlyph`),
  chrome child z-order, host paint and invalidation scopes and text caches
  (`win32/chrome_scene.zig`: `paintChrome`, `invalidateChrome*`,
  `repaintTopChrome`, the alpha a translucent window's GDI paint takes:
  `AlphaPaint`, `fillLaneBackground`, `fixAlpha`; `appendOwnedString` in
  `win32/text.zig`), the child
  placement cache (`ChildPlacement`, `applyChromeChildRect` in
  `win32/child_window.zig`), tweens.
- [chrome-overlays.md](docs/agents/log/chrome-overlays.md): the command
  palette (`win32_palette.zig`, `win32/palette_controller.zig`, its live
  theme preview, one window's at a time (`Host.showOverlay`, which closes
  every other window's palette; `Surface.toggleTabOverview`, which closes
  what is open first like every overlay's open; the error
  `showPaletteThemePreview` logs over another window's live preview),
  and how a reload ends it
  (`Host.swapRuntimeConfigFromPalette`, `installRuntimeConfigFromPalette`,
  `showPaletteThemePreview`, `supersedePaletteThemePreview`,
  `App.supersedePaletteThemePreviews`, `detachLivePaletteCatalogConfig`, and
  `App.updateCoreConfig`'s fallback after a failed reload,
  `App.reloadKeptConfig`, which reloads `app.config` in core's light/dark
  state), ranking, MRU
  and its `palette-mru.txt` lines: `writePaletteMruLine`, palette list, the
  catalog's capacities and the installed themes that fit them:
  `palette_catalog_capacity`, `palette_catalog_label_capacity`,
  `appendInstalledThemesToPalette`, the heavy-session test
  `PaletteCapacityTest` in `win32/host.zig` and its theme seam
  `palette_controller.test_installed_themes`, and the
  bundled iTerm2 theme pin in `build.zig.zon` that sets their count), the confirm
  overlay (`win32/overlay_session.zig`: `showConfirm`,
  `invokeConfirmAccept`/`Cancel` lifetime; what each prompt says and its
  preview pane's text: `win32/confirm_text.zig`, `Words`, `preview`), the
  profile overlay, host banners and the update notice, what the overlay
  says and shows in each mode (`win32/overlay_view.zig`: `compose`, its
  hint lane against chrome paint's feedback lane, `shape`, `nextFocus`,
  `bannerLine`; the palette's hint line, `command-palette-hint`, and the
  band's height, `feedbackRow`, `Host.overlayBandHeight`, the bands paint,
  the terminal and the row capacity read (`Host.chromeBands`), and
  `overlayBandChanged`, which `setBanner` and a palette theme's swap
  (`swapRuntimeConfigFromPalette`) call; the one reader of Host state for
  it, `Host.overlayFacts`,
  and the syncs that write its controls, `syncOverlayLabel`,
  `syncOverlayHint` and `syncOverlayButtons`, in
  `win32/overlay_session.zig`), overlay EDIT writes
  (`setOverlayEditText`, and `syncWindowTextUtf8CachedAfterSet` in
  `win32/child_window.zig`).
- [search-scrollbar.md](docs/agents/log/search-scrollbar.md): the docked
  search bar (`win32/docked_search.zig`: `DockedSearch.apply`, its
  `Outcome` and `view`; the adapter `Surface.dockedSearch`,
  `searchEditProc` and the bar's paint and UIA in
  `win32/search_controls.zig`; the order of `Surface.endSearch`'s
  end_search and clears in `src/Surface.zig`; visible Up/Down versus
  core `.next`/`.previous`, debounce and the host's search timer over
  every tab: `Host.refreshSearchTimerState`, `tickSearchBars`, the
  restart after `restoreClosedTabEntryNative` and `redoSplitCreateEntry`,
  the `test_core_steps` seam of `applyDockedSearch`) and the
  layered overlay scrollbar
  (`win32_scrollbar_geometry.zig`, heartbeat, alpha, markers, and the band
  that keeps the mouse beside a split divider:
  `Surface.scrollbarBandAtScreen`).
- [tabs-panes.md](docs/agents/log/tabs-panes.md): tabs, splits and windows as
  a structure: `Surface.init` ordering, `activateSurface`, showing and hiding
  pane surfaces (occlusion, overlapping WGL children), `windowDestroyed`,
  close and close-confirm flows (`Host.closeConfirmed` and its
  `Host.closing`), quit teardown (`destroyAllWindows`,
  `App.destroyPaneOf`, both in `win32/app.zig`; host and surface lookups in
  `win32/registry.zig`), focus after a close, shell reducer effects,
  local and structural undo/redo (`win32_undo.zig`,
  `win32_structural_history.zig`, `undo-timeout`, split undo and redo through
  the shell model: `Host.applyCommittedSplitHistory`), moving a tab to a new
  window or another window (tab tear-off: `App.moveTabToWindow`,
  `App.requestTabMove`, the outer-pump queue `App.pending_tab_moves` and
  `App.drainPendingTabMoves` and the move it runs, `App.runTabMove`,
  and what a declined one says, `App.tabMoveDeclined`,
  its wake `App.noteTabMoveWake`,
  `App.revalidateTabMove` and the entry checks it applies again,
  `App.moveTabAllowed`, `Host.endTabDrag`, a drag's Esc
  (`App.cancelTabDragForKey`, with the IME key resolver it shares with a
  divider drag, `App.keyMessageOriginalKey` and `App.isEscapeKey`, and
  what it asks first, `App.anyTabDragActive` and
  `App.tab_drag_escape_down`),
  the only tab's window move (`Host.beginOnlyTabWindowMove`),
  `Host.prepareGiveTab`,
  `Host.giveTab`, `Host.reparentSurface`, where a torn-off tab's
  pointer lands: `Host.tearOffDrop`, `Host.tearOffDropOn`,
  `Host.restoredClientOffset`, the grab's DPI scaling `Host.scaleByDpi`,
  and the window it lands in,
  `window_start.placeTearOff`,
  `win32/tab_drag.zig`, the shell model's `move_tab_to_window`,
  `move_tab_to_new_window`), split dividers under the mouse
  (`win32/pane_divider.zig`, `Host.handlePaneDividerMessage` and
  the drag behind it, `Host.paneDividerAtScreen`, keys during a drag:
  `App.paneDividerDragKey`, and the loop's routing that hands it a
  message before translation, `App.routeLoopMessage`; global hotkeys
  during a drag: `App.takeGlobalHotkey`), the gaps and slot rounding they find
  (`win32_layout.zig`: `splitSurfacePlacement`, `roundedSlotPixel`), the tree
  identity a drag checks (`SplitTree.generation` in
  `src/datastruct/split_tree.zig`), a ratio of -0 entering the tree as
  +0, every other ratio as given (`SplitTree.canonicalRatio`, which the
  session restore's `buildRestoredSessionSplitTree` also takes), the one
  synchronous paint a drag step makes
  (`surface_presentation.paneDividerStepRepaintMode`) and the keyboard
  `resize_split` they match (`App.resizeSplitFallback`).
- [input.md](docs/agents/log/input.md): `win32/input.zig` and key messages
  (`WM_KEYDOWN`/`WM_CHAR`/`WM_SYSCHAR`, dead keys, `ToUnicode`, non-Latin
  layouts), default Windows keybindings, Win32 input mode (DEC 9001), the
  bytes ConPTY's input parser gets with 9001 off (`windows_legacy` in
  `src/input/key_encode.zig`, the `function_keys.zig` rows it reads), the
  Kitty encoder's alternate keys (`kitty` in the same file, its keypad
  break) and the 16-byte parts a report reaches a program over ssh in, IME
  (the composition string, its caret and target clause:
  `win32_input.imeTargetCodepointRange`, `Surface.imePosAt`), mouse buttons
  (the X buttons: `win32_input.xMouseButton`, and the button codes
  `src/input/mouse_encode.zig` writes), wheel and context-menu input, and
  key binding dispatch and chains (`Surface.maybeHandleBinding`,
  `dispatchLeaf`, `bindingOutcome`, `startLeader`, `performChain`,
  `closeToken`, `closesCaller`, `mayDetachCaller`, the stand-ins'
  `closingAction`, `bindingTags`, `cursorKeyWrite`,
  `GenericLeaf.cloneActions` and `Action.cloneSlice` in `src/input/Binding.zig`, `src/App.zig`'s
  `keyEvent`, `performAllChainedAction`, `performAllOwnedChain`,
  `performChainOnAll`, `performAllAction`, `forEachListed`,
  `receivesAppWideActions` and `hasSurfaceInstance`, Win32's
  `handleGlobalHotkey`, `holdLastWindowQuit`, `releaseLastWindowQuit`,
  `afterLastWindow`, `onTerminalHandoffIdleTimer`, `settingsOnClosedThunk`,
  `Surface.receivesAppWideActions` and `keyEventTogglesCommandPalette`,
  and the inspector's tag-only `Event.binding` in
  `src/inspector/widgets/key.zig`).
- [launch-and-paths.md](docs/agents/log/launch-and-paths.md): which process a
  terminal starts and with what environment: a new pane's launch
  (`src/config/pane_launch.zig` `prepare`, its `Origin` and `Stamp`,
  `defaultApplies`; where `App.createNewTab` and `App.createNewSplit`
  call it against `applySplitWorkingDirectoryFromSource`), the default
  `command` (what a config load decides of
  the launch, in the same file: `finalize`, `default-profile` resolution and
  its problems, the automatic default, the `Ledger` a load keeps in
  `Config._launch` (which layer set `command`, the profile places, what
  `note` records) and why it stays beside `config.origin` with
  `origin.Derivation` at `.automatic`,
  `useRecovery`, the queries `defaultProfile`, `nocttyCommand`,
  `commandLineNamesProfile`, `filesDefine` and `defaultProfileForKey`, and
  `keepSources`), profile
  discovery and user-defined profiles (`src/config/windows_shell.zig`: the
  `profile-*` keys, `default-profile`, `profile-order`, `profile-hidden`,
  `verbatimCommandLine`, `arrangeProfiles`, profile key equality
  `profileKeyEquals`, `storedProfileKeyEquals`, `sshProfileAlias`, and
  which profile the app picks by it, `src/apprt/win32/profile_pick.zig`:
  `byKey`, `pinByKey`, `byTyped`, `preferred`, `quickSlot`; Visual Studio
  developer shells in `src/config/windows_visual_studio.zig`;
  `win32_elevation.RelaunchProfile`), safe mode's
  `cmd.exe /D`, `CreateProcessW` name resolution, Git Bash discovery, WSL
  (`wsl_env.zig`, the terminfo probe and its cache, `TERM`), the terminfo
  install (`win32_terminfo.zig`), `noctty +list-profiles`
  (`src/cli/list_profiles.zig`, which applies the system color scheme through
  `os/color_scheme.zig`), what a log line may print of a command, an
  argument, an environment value or a directory (`os/redact.zig`,
  `Command.redacted()`); path safety (`os.path.isNetworkOrDevicePath`,
  `OBJ_DONT_REPARSE` opens: the bounded local open `os/local_path.zig`
  (`open` and its link walk, `Found.storedName`, `test_links`,
  `test_cloud`) and
  `windows_shell.ntOpenDontReparse`, and the length of a path before either
  converts it) for every program-reported path before it is opened
  (OSC 7/9;9/1337 pwd), and for kitty graphics `t=f`/`t=t` files, which on
  Windows open through `os/local_path.zig` `open` (no share contacted, a
  path that is not drive-absolute refused) and check the opened handle's
  canonical path afterwards (`terminal/kitty/graphics_image.zig` and
  `terminal/kitty/windows.zig`, the `t=t` delete through the opened handle
  in `os/windows.zig` `deleteOpenedFile`, and the length of a path before
  Zig converts it);
  link and quick-select path detection and opening (`os/local_path.zig`
  `linkTarget` and `isLocalShape`; the opener's gate:
  `prepareWin32OpenTarget`, `prepareWin32LocalFile`, `isSafeLinkText`,
  `local_path.Found.storedName`, and its hidden-desktop probe
  `test/windows/link-opener-pathext-probe.ps1`; the link prompt:
  `App.openLink`, `askBeforeOpeningLink`, `confirmedLinkScheme`,
  `linkHandlerName`, `Words.link` in `win32/confirm_text.zig`,
  `Surface.setPendingLinkOpen`/`takePendingLinkOpen`).
- [clipboard.md](docs/agents/log/clipboard.md): clipboard reads and writes,
  CF_HTML (`win32_clipboard_html.zig`), open retries, what a copy puts on the
  clipboard (formats and owner, as Remote Desktop's redirection sees them),
  the Win32 error a failed copy reports (`clipboard_write.writeCapturing`),
  the empty bracketed paste and the paste of copied files
  (`Surface.completeClipboardPasteWithoutText`, `selectClipboardContents`,
  `win32_ole.extractHdrop`), OSC 52 prompts and
  replies, paste protection (`win32_paste_protection.zig`), drag-and-drop
  (`win32_surface_drop*.zig`), pending clipboard confirmations.
- [settings.md](docs/agents/log/settings.md): the Settings window
  (`win32_settings.zig`, `win32_settings_fields.zig`): its controls and when
  they are made (`SettingsWindow.open`, `materializeSection`), dialog
  manager, viewport, live preview (`App.settings_preview`, `App.shownConfig`,
  `App.shownBackgroundOpacity`, and its rollback at a close or Discard:
  `rollbackPreviews` and the handle's `endPreviews`), theming (`SettingsThemeAdapter`,
  `themeChanged`), its own UIA patterns, combo and open traces
  (`NOCTTY_SETTINGS_COMBO_TRACE`, `NOCTTY_SETTINGS_OPEN_TRACE`,
  `win32/bench_trace.zig`), the Default profile row
  (`field_model.Kind.profile`, `AppHandle.profileChoices`, and what the
  load made of the value: `pane_launch.outcome`, `filesDefaultProfile`,
  `asWritten`), the
  changed-from-default marks, Reset buttons and row menu (`syncDefaultMarks`,
  `takeResetButton`, `releaseResetButton`, `resetDraftRow`, `showRowMenu`,
  `field_model.effectiveSettingValue`), Settings search (`formItems`,
  `runSearch`, `suspendViewportRedraw`, `keepFocusShown`, `searchFinds`,
  `revealControl`, `showKeyboardCues`, `placeDiscardButton`, `SearchQuery`),
  where each shown value comes from (`config.origin`,
  `win32_settings_reference.savedOrigin`), the opacity trackbar and the number
  up-downs, the Profiles page (`ReferenceList`, `ListKind.profiles`,
  `win32_settings_profiles.zig`) and the identity patcher that saves it
  (`win32/settings_patch.zig`, `FileEnd`), the config line reader it shares
  with the loader (`cli/args.zig` `LineIterator.takes`, `read_failed`,
  `Config.loadReader`), the keyboard pin in Settings dialog tests
  (`TestingKeyboard.pinNone`), and the save path (`settingsSaveAndReload`,
  `patchOrAppendEdits`, save target, masked values, and the digest re-check
  before the write: `App.settings_check`, `save_target.writeOver`).
- [accessibility.md](docs/agents/log/accessibility.md): new widgets and UI
  events (adding a native widget, or changing its focus, children or
  notifiable properties); UIA providers under `src/apprt/win32_uia/` (COM
  identity and refcounts, BSTR and VARIANT ownership, `events.zig`); terminal
  text (`win32_terminal_accessibility.zig`, TextPattern, ScrollIntoView, the
  echo queue, and the output transport that feeds it:
  `TerminalOutputTransport` in `apprt/surface.zig`; the viewport a range's
  `GetBoundingRectangles` reads: `terminalAccessibilityViewport`'s try-lock in
  `src/apprt/win32.zig`, `handleViewportRefresh`, `providerViewport`), palette and tab-list
  UIA (a tab's name: `uiaName` and `Key.sameUiaName` in
  `win32/tab_label.zig`).
- [config.md](docs/agents/log/config.md): config loading and reload outside
  the Settings window: the config file reader (`cli/args.zig` `LineIterator`,
  `streamDelimiterEnding`, `parseIntoField`, `ProfileMap`,
  `Config.file_read_buffer_len`), Windows environment expansion
  (`src/config/windows_shell.zig` `expandProfileText`), `--config-file` and
  `startup_cwd` on reload, diagnostics shown in the GUI, conditional replay
  (`Replay.Iterator`, `Config.finalize`, `loadTheme`,
  `changeConditionalState`), command-line values put
  back over `config-file` includes (`Config.parseManuallyHook`, and `note`
  and `finalizeCliLaunch` in `src/config/pane_launch.zig`), `newConfig` shallow
  clones, what `Surface.DerivedConfig` must own, `RepeatableCommand.clone`
  and its C mirror (`value_c`, `Command.cval`), UTF-16 themes
  (`Config.textReader`, `_undecodable_theme`), the default config files and
  their paths (`Config.loadDefaultFiles`, `src/config/file_load.zig`), the
  user theme directories (`theme.Location.dir`), and the root a test build
  reads both under (`file_load.test_config_root`, `hasConfigHome`,
  `configHomePath`), `+edit-config` and opening
  the config file, adding config keys.
- [app-lifecycle.md](docs/agents/log/app-lifecycle.md): `App.init` and
  startup stalls, a cold `--launch-layout` (`App.startup_launch_layout`,
  `forgetLaunchLayout`), startup attempts and safe mode, session state
  (capture, restore, owner lock and quarantine: `win32/session.zig`) and
  state-file schemas, IPC and single instance (`win32/ipc_server.zig`), AUMID
  and portable identity, the jump list, toasts and desktop notifications
  (`win32/notifications.zig`: their tab attribution, tags and history
  removal, `Notifications.show`, `seen`, `panesChanged` and `flush`, what a
  click presents, `Notifications.click`, the App's `notificationPanes`
  adapter; the COM activator in `win32_toast_activator.zig`), an installer's
  Restart Manager close and a session end (`App.onQueryEndSession`,
  `App.onEndSession`, `registerInstallerRestart`, the lifecycle window), the
  bell (its title glyph: `title_glyph`, `withTitleGlyph` in
  `win32/tab_label.zig`), taskbar progress and icon, crash minidumps and
  Sentry, the COM apartment, default-terminal handoff, the CLI and the
  `noctty.com` wrapper.
- [build-release-ci.md](docs/agents/log/build-release-ci.md): `build.zig`
  (including the `bench:*` steps' `addBenchCoreImport`, and the test
  executable's mode, `-Dtest-optimize` through `Config.testModule`) and
  resources, Zig 0.17's build graph (the configure process, its cache and
  what a build script reads at configure time; the host-tool steps
  `src/build/ConptyRedist.zig` and `src/build/ThreadRoleTextCheck.zig`;
  module modes, `SharedDeps.assertModuleOptimizeMode` and
  `SharedDeps.uucodeModule`; what a `Run` step hands its child, as
  `src/build/GhosttyPkgConfig.zig` does its generator
  `src/extra/pkg-config.zig`; which files `test-lib-vt` parses and
  compiles), the
  Zig global cache a build uses (`ZIG_GLOBAL_CACHE_DIR`, which
  `scripts/dev-windows.cmd` keeps when set and otherwise sets to
  `%LOCALAPPDATA%\zig`), the Windows target floor (`src/build/Config.zig`,
  `-Dtarget` `win10`/`win10_rs5`, and the std APIs it gates), packaging
  (`scripts/package-windows.ps1`, `dist/windows/noctty.iss`, what Setup's
  `CloseApplications` closes, and what it installs and deletes; the
  runtime staging contract and its controls,
  `Get-RuntimeStagingProblems` and `Assert-StagingControlFails` in
  `Contracts.93-ConPty.ps1`), signing,
  the updater (including `RegisterApplicationRestart` while an installer
  closes noctty, with `stagedInstallerRunning`; the staging lock's and the
  staged-Setup check's path compares, `lockedHandleMatchesPath` and
  `processRunsFromStage`, over `win32/sys.zig`'s
  `getFinalPathNameByHandle`; `pkg/wuffs/src/deflate.zig`,
  the raw DEFLATE decoder for update payloads; the files a portable payload
  must hold and the ones it may drop: `managed_entries`, `retired_entries`,
  `legacy_updater_required_entries`, `portable_zip_carries_legacy_entries`,
  `requirePayloadEntries`, `swapPayload`, `rollback`, `fileMatches`,
  `verifyBackupManifest`, `checkSetupRetiresLibVt` and
  `checkPackagingStagesPlaceholders` in
  `src/update/portable_apply.zig`, `verifyPortablePayload` and
  `verifyInstalledPortablePayloadAgainstManifest` in
  `src/update/github_releases.zig`, and the packaging scripts'
  `$runtimeFiles`), release workflows and package managers
  (WinGet, Scoop, Chocolatey): `scripts/release-publication-state.ps1`
  (`Get-ReleaseByTag`, `Assert-RemoteReleaseTag`, `Get-CreatedReleaseDraft`,
  `Confirm-ReleasePublication`), `scripts/release-evidence.ps1`
  (`Invoke-ReleaseGhJson`, `Assert-ReleaseEvidence`),
  `scripts/release-manifest.ps1` (`Get-ReleasePayloadPaths`, `Write-ReleaseManifest`,
  `Assert-ReleaseManifest`, `Assert-PackageManagerFiles`),
  `scripts/release-write-manifest.ps1`,
  `scripts/release-check-publication.ps1`, `scripts/release-promote.ps1`,
  `scripts/release-publish-github.ps1`,
  `scripts/release-fixture-directory.ps1` (`New-ReleaseFixtureDirectory`,
  `Remove-ReleaseFixtureDirectory`), the release fixtures
  `test/windows/release-promote.ps1` and `test/windows/release-fixture-cleanup.ps1`,
  `scripts/release-package-manager-preflight.ps1` (`Test-ReleasePublisherEnabled`,
  `Assert-PromotionPackageManagers`), `scripts/package-manager-paths.ps1`
  (`Resolve-ArtifactMetadataPath`), `scripts/release-run-generator.ps1`
  (`Invoke-ReleaseGenerator`), `scripts/release-publisher-outcome.ps1`
  (`Set-ReleasePublisherOutcome`), and `scripts/release-submit-winget.ps1`
  (`Test-WinGetVersionSubmitted`); GitHub Actions CI (path filter, caching, runners, the gates
  the `main: CI gates` ruleset requires and their `always()`, Dependabot's
  `.github/dependabot.yml`, the action pins and the workflow digests the
  contracts pin), CRLF and
  `.gitattributes` in shipped files.
- [docs-and-site.md](docs/agents/log/docs-and-site.md): site edits (`site/`,
  including styles, scripts and the generated CSP/asset hashes); changing
  what README.md, PRIVACY.md, PACKAGING.md, `docs/*.md` or install copy
  claims about behaviour.
- [test-harnesses.md](docs/agents/log/test-harnesses.md): writing or running
  `test/windows/` harnesses (hidden desktops, the foreground, sandboxes, the
  interactive composite, the flagship contracts, the renderer parity harness
  `test/windows/renderer/Invoke-RendererParity.ps1`, `bench-windows.ps1`'s
  `ForceForeground` and render-trace snapshots, its per-copy frame-pacing
  harness (`-Metric frame-pacing`, `test/windows/bench-frame-pacing.ps1`,
  and its input watch: the low-level hooks `StartWatch` installs and the gate
  `Test-FramePacingInputGate`), transient captures (a banner,
  the overlay scrollbar) in the visible check `Invoke-VisibleD3D11Check.ps1`,
  the measure-AUMID builds an A/B compares
  (`Invoke-InteractiveWin11MeasureBuild` in
  `scripts/interactive-win11-measure-lib.ps1`), the shared real-state guard
  and its clipboard reading (`scripts/interactive-win11-state-guard.ps1`:
  `Test-InteractiveWin11ClipboardObservable`),
  the PKG-37, LAT-01 and LAT-02 measurement harnesses on the
  `origin/*-measurement-harness` branches), which steps of the optional
  interactive composite job may raise a real toast (the job's order,
  `Get-InteractiveWin11JobPlan`, the composite's `-DeferCommandFinish`,
  `$settingsSaveNotificationArguments` in the accessibility leaf and its
  run-time checks of each saving launch's command line and sandbox,
  `Assert-AccessibilitySaveLaunchQuiet`, `Get-AccessibilitySaveLaunchVerdict`,
  `Get-AccessibilityNotificationSettings` and
  `Assert-AccessibilitySaveSandboxQuiet`, the probe's close prompt button,
  `Get-AccessibilitySettingsCloseActionInvoke`, the leaf's `# pin-begin:`
  regions and their SHA-256 pins, `$saveLeafPins`, the cmdlets they call,
  `$saveRegionCmdlets`, the flow statements its finally blocks may hold,
  `$saveFinallyFlows`, and the toast-source inventory, who may
  name the command-finish leaf and the quiet-save grammar in
  `Contracts.90-Workflows.ps1`), the soak
  (`test/windows/interactive-win11-soak.ps1`, its judge `ci/soak_judge.py`
  with `ci/test_soak_judge.py`, and the slope thresholds
  `ci/soak-thresholds.tsv`), the PKG-23 Ctrl+click harness
  (`test/windows/hidden-win11-pkg23-ctrl-click.ps1`, its contract
  `Contracts.98-Pkg23CtrlClick.ps1`) and the Debug open-URL trace it reads
  (`recordOpenUrlForTest` and `NOCTTY_WIN32_OPEN_URL_TRACE_FILE` in
  `src/apprt/win32.zig`, `dispatchOpenTarget` in `src/apprt/win32/app.zig`),
  the hidden-desktop GUI suite
  (`test/windows/gui-hidden-runner.ps1` and its process audit: `JobWatch`
  and its stop, `NoteStop` and `StopRunJob`; `OpenJoiner`, `GoneBeforeStop`,
  `Pinned`, `ExitedBy` and its termination kinds `ImageReadEnded` and
  `CommandLineReadEnded`; `Get-GuiHiddenProcessVerdict` and the receipt's
  `*Exited` counts; its plan
  `test/windows/gui-hidden-plan.json`, `.github/workflows/gui-hidden.yml`
  and its selection `scripts/ci-gui-selection.ps1` with the script walker
  `scripts/ci-script-closure.ps1` and the fixtures
  `test/windows/gui-hidden-scripts.ps1`, the interactive library's hosted
  mode (`InteractiveWin11HostedDesktop`,
  `Start-InteractiveWin11HostedProcess`,
  `Write-InteractiveWin11HostedConfig`, the argument rule
  `Get-InteractiveWin11HostedArgumentRefusal` and the run token
  `Get-InteractiveWin11HostedRunToken`; the harness's path comparison
  `Test-InteractiveWin11SamePath` and `Get-InteractiveWin11CanonicalPath` in
  `scripts/interactive-win11-measure-lib.ps1`; the struct layout pins,
  `Layout()`, the error publisher
  `test/windows/gui-hidden-publish-error.ps1`, and the log prefixes the
  runner reads, `logPrefix` and its test in `src/process_shared.zig`), the
  real-input module
  `scripts/interactive-win11-realinput.ps1` (`InteractiveWin11RealInput`),
  the measurement record
  `test/windows/flagship/measurements/gui-measurements.json` and the
  contracts `Contracts.99-GuiHidden*.ps1`), CI test steps (the raw
  `zig test src/apprt/win32_compositor_native.zig` step, which confines
  `win32/sys.zig`'s imports to `src/apprt`), the Zig test runner and its
  shards (`src/test_runner.zig`, `src/test_shard.zig`, `-Dtest-shards`,
  `addTestRuns` in `build.zig`, and the names tests share across processes), the
  test runner's probe children and thread tests (`src/pty_transport_probe.zig`,
  `std.Progress.lockStdErr`, the search-thread tests in
  `src/terminal/search/Thread.zig`), the test exe's isolated children and
  their dispatch (`src/sync/isolated.zig`: `runChildIfRequested`, `run`,
  `expectPanic`, `expectOffTable`, `expectShapes`, the name rule
  `symbolise.names_checked`; `src/main.zig`'s first test), the layer's
  acceptance tests there and in `src/sync/state_mutex.zig`, acceptance
  test 9's checker `ci/thread_role_points.py` (its `Resolver`) with its
  controls `ci/test_thread_role_points.py`, the
  thread-role dumps' symboliser and the in-process compare
  (`src/sync/symbolise.zig`, DbgHelp's `SymFromAddrW`; `src/sync/compare.zig`;
  the table they read, `ci/lock-inventory-threads.tsv`, what its static
  gate reads as a caller edge, and what its inventory reads as a
  renderer-state site, by a receiver's last name), the relock tests and
  their IO thread (`termio.Thread.drainForTest`, its `DrainHook` in
  `drainMailbox`; `RelockSurface` and `expectRecordedPairs` in
  `src/Surface.zig`; the reader-side fill test in
  `src/termio/stream_handler.zig`) and where a
  test's helper thread enters its role, the shared Win32 test
  fixtures
  (`win32/test_support.zig`, `TestSession`, the private-desktop runners
  `runOnHiddenDesktop` and `host.zig` `runOnPrivateDesktop`, the empty
  keyboard they pin and the window probe that checks their role,
  `RoleProbeWindow`), process-wide state a test leaves for the later tests
  in its shard (the OpenGL startup diagnostics `App.createGLContext`
  starts: `gl_startup.beginOpenGLStartupDiagnostics`,
  `clearOpenGLStartupFailure`) and the process's handle count a test
  compares (`GetProcessHandleCount`, which the IPC handle test in
  `src/apprt/win32/ipc_server.zig`, `testProcessHandleCount`, reads in an
  isolated child), PSReadLine history isolation
  (`scripts/windows-harness-history.ps1`), the shell a fixture starts (the
  config line `Get-InteractiveWin11HostedPolicyConfig` writes, the shared
  helper's legacy `--command=cmd.exe`), a bash
  probe's `HISTFILE`, a failing test's error name (the installed test
  executable), the skip budget (`scripts/check-test-skips.ps1`,
  `test/windows/test-skip-budget.json`) and the nightly per-test log it reads
  (`scripts/ci-test-timing.ps1`), the list of the tests that ran and its
  compare (`scripts/capture-test-ran-list.ps1`,
  `scripts/compare-test-ran-list.ps1`, the approved skips
  `test/windows/ran-list-approved-skips.tsv` and the parser fixtures
  `test/windows/ran-list-fixtures/`), and a test count or result that
  contradicts the code.
- [tooling.md](docs/agents/log/tooling.md): declaring `extern` functions or
  structs, casting Win32 handles and `LPARAM`/`LRESULT` (`@intCast`,
  `@bitCast`, `@ptrFromInt`), passing `[:0]u16` to text APIs, renaming or moving
  Zig declarations (the `src/apprt/win32.zig` split into `win32/*.zig`),
  dropping `pub` from a declaration another file probes by name
  (`@hasDecl(apprt.Surface, ...)` in `src/Surface.zig` and
  `src/renderer/Thread.zig`, the runtime hooks such as
  `noteRendererFollowupCallback`) or its own file probes (on Zig 0.17,
  `Minimums` in `src/font/Metrics.zig`),
  adding a name to `src/apprt/win32.zig` or to one of its `*_runtime` bags
  (the budget in `win32/facade_budget.zig`, and the facade importer list in
  `Contracts.20-Zig.ps1`), `union(enum)` tests, PowerShell language traps
  (and the GUI script walk's models of command lookup: `Get-CiScriptPathLookup`,
  `Find-CiScriptLookupFiles` and `Test-CiScriptShippedCmdlet` in
  `scripts/ci-script-closure.ps1`), and `gh`, git and codex commands.

A comment that cites AGENTS.md (by date, issue number, symbol or an old line
number such as `AGENTS.md:75`) means a log entry. Run
`git grep -n "^- <date>" docs/agents/log/` (several entries share a date, so
match the subject too), or grep the issue or the symbol the comment names,
then read that file's header: an item there may correct the entry.

### How to add a Self-Correction Log entry

When work uncovers a trap a later agent could not cheaply rediscover, add one
bullet, `- YYYY-MM-DD: ...`, to the area file whose trigger names the code the
rule governs, at its place in date order (first in the list, below the header
blocks, unless an existing entry is newer); one file per entry, continuation
lines indented, no blank lines inside the list. State the trap (what looked
true and was not), the evidence (what was measured, on what, with what result,
and what is only inferred), and the rule (what to do now, naming files and
symbols). The entry is done when:

- you have run `git grep -n` across `docs/agents/log/` for every symbol it
  names and read the hits, and the entry names each earlier entry it corrects
  or qualifies by date, subject and file;
- each corrected entry in another area file has a line in that file's
  "Corrected in other files";
- when its rule also governs code another area's trigger names, that area
  file's "See also" names the entry by date, subject (and ID, if any) and
  file;
- a path or symbol the entry governs that its area's trigger does not name is
  added to that trigger; the corresponding source paths are covered by the
  file's `scope` globs; a pointer to another file's entry goes in a header
  "See also", never in the index;
- a new area file (only when no trigger fits) has the heading
  `# Self-Correction Log: <area>`, a blank line, the pointer line every area
  file has, a blank line, then any `Corrected in other files:` or
  `See also:` block (each item a `- ` line naming its entry by date, subject
  and file; each block ended by a blank line); an index line above whose
  trigger names paths and symbols;
  and a `.greptile/files.json` item with `scope` globs;
- in the same change, any trigger, `scope` glob or header item naming a path
  or symbol the work renamed or removed is updated, and a header item whose
  entry no longer holds is removed.
