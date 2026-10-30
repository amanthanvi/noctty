# Agent Development Guide

A file for [guiding coding agents](https://agents.md/) working in this
Windows-only Ghostty fork. Before you change, diagnose or measure code, do the
reading step under [Self-Correction Log](#self-correction-log).

## Commands

- **Build:** `zig build` (also stages the pinned `conpty.dll` and
  `OpenConsole.exe` beside the exe; staging traps: the 2026-10-10 bundled
  ConPTY entry in `docs/agents/log/conpty.md`)
- **Test (Zig):** `zig build test -Demit-test-exe=true --summary all`
  (full suite, ~4.5k tests, about a minute). This is the only invocation that
  is trustworthy on its own, and `--summary all` is part of it: the count is
  the evidence.
  - Bare `zig build test` errors in this fork.
  - `-Dtest-filter=<token>` (one token: quote it or use a no-space
    substring, or `zig build` reads the rest as step names) runs the tests
    whose fully qualified name (file path, `.test.`, test name) contains the
    token, for quick iteration; it is not evidence on its own. Read the
    count: the `N/M tests passed` line counts the matching tests plus about
    70 unnamed `test { ... }` blocks that no filter excludes, so a token that
    matches nothing still reports about 70 passes, not zero. Use `ConPTY` to
    reach the probe tests in `src/pty_transport_probe.zig`. A filtered build
    compiles the whole tree, about a minute. `Build Summary: 41/41 steps
    succeeded` counts build steps, not tests. Filter traps: the 2026-10-06
    entry in `docs/agents/log/test-harnesses.md`.
- **Formatting (Zig):** `zig fmt .`
- **Formatting (other):** `prettier -w .`
- Run `zig build*` through `scripts/dev-windows.cmd` (or an equivalent
  VS-dev + Zig 0.15.2 shell); the ambient shell can miss the native toolchain
  and fail with misleading dependency errors. A direct `zig test <file>`
  misses the build graph's generated modules (`build_options` and others).
  For code that needs those modules, use the full-suite command above or
  `zig build test -Dtest-filter=<token>` for iteration. Pure helpers may use
  a temporary package-root harness. (test-harnesses.md: 2026-04-18
  `scripts/dev-windows.cmd` and raw `zig test`; 2026-05-01 direct
  `zig test src/apprt.zig`.)

## Running noctty

- Run noctty on a private desktop (`CreateDesktopW`), and pass
  `lpDesktop = WinSta0\<desktop>` to every process you start: a driver on a
  private desktop that passes a null one puts the child on the user's
  desktop, and noctty takes the foreground. Drive it with posted messages
  (`SendInput` types into whatever window is in front): a key as a posted
  `WM_KEYDOWN`/`WM_KEYUP` pair, since a posted triple types it twice and a
  bare posted `WM_CHAR` types nothing. A posted Alt never reaches
  `GetKeyboardState`, and a pass from posted input is not a pass for real
  input. (window-frame.md: 2026-09-24 `window-decoration = none` trap 1,
  2026-09-23 "Item (b) of the #262 entry" harness notes, 2026-10-16 #285
  window menu; renderer.md: 2026-10-14 LAT-01; input.md: 2026-09-19 #250;
  test-harnesses.md: 2026-09-23 #261 trap 3.) What a private desktop cannot
  show (a D3D11 present, which needs a composed, visible desktop; real input)
  needs a visible run, and a visible run starts only once the user is away.
  (search-scrollbar.md: 2026-10-16 D3D11-IFLIP-01; window-frame.md:
  2026-10-16 real DPI drag, last trap.)
- Run a scratch portable copy (`noctty.portable` beside the exe) with
  `--window-save-state=never` and `LOCALAPPDATA` redirected for that noctty;
  that isolates session and startup state. If a `zig build` runs under the
  redirect, pin `ZIG_GLOBAL_CACHE_DIR` to the real Zig cache. A test that
  reached the real `%LOCALAPPDATA%\noctty` once put the user's launches into
  safe mode. (window-frame.md: 2026-09-23 "Item (b) of the #262 entry";
  test-harnesses.md: 2026-09-23 #261 trap 2.) Give each PowerShell you type
  into a run-local PSReadLine history path or `SaveNothing` before its first
  read: PSReadLine finds its history through a known folder (setting it needs
  `-Command`, which turns off automatic injection: dot-source
  `integration.ps1` as `buildCommandValue` does). Separately, a `-e` fixture
  sets only `initial-command`, so later tabs and splits start `command`, a
  PowerShell by default (pwsh, else Windows PowerShell): pin
  `--command=cmd.exe` unless the fixture tests a
  configured `command`, and guard the run with
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

## Directory Structure

- Shared Zig core: `src/`
- Win32 application runtime: `src/apprt/win32.zig` holds the forwarding
  aliases for App, Host, and Surface, the native window procedures, shared
  helpers, and the tests that combine owners; `src/apprt/win32/app.zig`,
  `host.zig`, and `terminal_window.zig` hold App, Host, and Surface;
  `src/apprt/win32_theme.zig` owns theme policy; focused modules under
  `src/apprt/win32/` own session capture and restore, the quick terminal host,
  window state, surface presentation, the docked search controls, overlay and
  palette orchestration, the chrome scene, Win32 constants/externs,
  labels/input, startup/render tracing, chrome rectangle math, and GDI paint
  primitives.
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
  its stack size, `os.surfaceThreadSpawnConfig`) and write pool in
  `termio/Exec.zig`, `ResizePseudoConsole` and the renderer lock
  `Termio.resize` holds across it, in-box conhost
  versus the bundled `conpty.dll`/`OpenConsole.exe`
  (`scripts/stage-conpty-redist.ps1`), what ConPTY's buffer holds after a
  resize, minimize, clear or undo and the column reflow that has to match it
  (`Screen.resize`, the replay tests in `src/terminal/resize_replay.zig`, the
  sync harness `test/windows/interactive-win11-conpty-sync.ps1`), the
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
  parser limits, `PageList` and its page serials (`page_serial_min`,
  `nodeIsValid`, the source renewal in `PageList.split`), `PageList.Node`'s
  accessors (`page()`, `rows()`, `cols()`, `capacity()`, `Node.Data`), the
  owner inference in `destroyNodeExt`, and their callers in
  `src/inspector/widgets/pagelist.zig`, OSC parsers,
  OSC 133 exit codes, prompt typeahead
  in `semantic_command.zig`, the scrollback search thread and its cached
  results (`ScreenSearch.pruneHistory`, `LiveNodes`), the selection and
  search-highlight rows of `RenderState` (`render.zig`),
  `TerminalFormatter`/`ScreenFormatter` output for undo snapshots and Copy as
  HTML, Kitty graphics commands, placements and deletes in
  `kitty/graphics_command.zig`, `kitty/graphics_storage.zig` and
  `kitty/graphics_exec.zig`, the file reads of `kitty/graphics_image.zig`
  `readFile`, and tmux control mode in `tmux/`: `control.Parser`,
  `Layout.max_depth`, the `Viewer`), `os/file.zig` `allocTmpDir` and
  `os/TempDir.zig`, OSC 7 and OSC 9;9 cwd reports
  (`termio/stream_handler.zig`, `os.hostname.isLocal`,
  `windows_shell.conemuPathToLocal`), `src/Surface.zig` locking around links,
  and `ShellExecute*` calls queued for the message loop
  (`App.deferShellRequest`, `drainDeferredOpens`).
- [renderer.md](docs/agents/log/renderer.md): `src/renderer/` and
  `src/renderer.zig` (OpenGL/WGL,
  the D3D11 beta and GL-to-D3D11 fallback, who frees the config of a failed
  `Renderer.init` in core `Surface.init`, `Thread.zig` pacing and follow-up
  timers, synchronized output, vsync, `RenderPass` viewport, cursor sprites,
  search highlights after a resize, the IME preedit and composition caret in
  `rebuildCells` and `State.Preedit.layout`, the glyph options `addGlyph` and
  `addPreeditCell` pass), the unfocused-split dim
  (`split_dim`, `Host.syncSplitDim`), `win32/pixel_format.zig`, Windows font
  discovery (`src/font/discovery_windows.zig`: the registry scan, variable
  `wght` bounds, bold matching), font fallback and `font-thicken`, renderer
  wakeups from `termio` and typing latency, repaint during live resize
  (`win32/surface_presentation.zig`), and which DLLs a CLI action or the D3D11
  backend loads (the OpenGL32 static import).
- [window-frame.md](docs/agents/log/window-frame.md): the top-level window:
  `WM_NCCALCSIZE`/`WM_NCHITTEST` (`win32_nc_layout.zig`), integrated titlebar
  and caption buttons, `window-decoration = none`, resize bands, maximize,
  fullscreen and restore placement (the `maximize`/`fullscreen` keys at
  window start: `Surface.applyWindowStart` in `win32/window_state.zig`; what a
  session saves and restores of a fullscreen window: `WindowState.fullscreen`
  and `fullscreen_maximized` in `win32_session_state.zig`,
  `sessionWindowPlacementOn` and `restoreSessionWindow` in
  `win32/session.zig`), what a new window copies from its source and which
  forwarded keys it keeps (`inheritWindowStateFrom`, `WindowKeeps`, both in
  `win32/window_state.zig`), `WM_DPICHANGED` and mixed-DPI moves,
  `window-width`/`window-height`, `background-opacity` and DWM backdrop, the
  window menu, the quick terminal (`win32_quick_terminal.zig`,
  `win32/quick_terminal_host.zig`).
- [chrome-tabs-paint.md](docs/agents/log/chrome-tabs-paint.md): tab buttons
  (`tabButtonProc`, `drawButton`, labels, tooltips, close X, the active tab's
  join to its terminal, `win32_tab_visual.zig`), `window-show-tab-bar`,
  chrome theme and system accent (`win32_theme.zig`), focus cues
  (`win32/focus_cue.zig`), `win32_icons.zig`, titlebar and tab-row icon fonts
  (`recreateTitlebarIconFonts`, `createIconFontWithGlyphs`,
  `fontGlyphCoverage`, `drawTitlebarGlyph`), chrome child z-order, host paint
  and invalidation scopes and text caches (`win32/chrome_scene.zig`:
  `paintChrome`, `invalidateChrome*`, `repaintTopChrome`; `appendOwnedString`),
  tweens.
- [chrome-overlays.md](docs/agents/log/chrome-overlays.md): the command
  palette (`win32_palette.zig`, `win32/palette_controller.zig`, ranking, MRU
  and its `palette-mru.txt` lines: `writePaletteMruLine`, palette list, the
  catalog's capacity and the installed themes that fit it:
  `palette_catalog_capacity`, `appendInstalledThemesToPalette`, and the
  bundled iTerm2 theme pin in `build.zig.zon` that sets their count), the confirm
  overlay (`win32/overlay_session.zig`: `showConfirm`,
  `invokeConfirmAccept`/`Cancel` lifetime; its paint text in
  `labels.buildOverlayPaintLabelText`), the profile
  overlay, host banners and the update notice, overlay EDIT writes
  (`setOverlayEditText`).
- [search-scrollbar.md](docs/agents/log/search-scrollbar.md): the docked
  search bar (`win32_search_bar.zig`, `searchEditProc` in
  `win32/search_controls.zig`, visible Up/Down versus
  core `.next`/`.previous`, debounce) and the layered overlay scrollbar
  (`win32_scrollbar_geometry.zig`, heartbeat, alpha, markers).
- [tabs-panes.md](docs/agents/log/tabs-panes.md): tabs, splits and windows as
  a structure: `Surface.init` ordering, `activateSurface`, showing and hiding
  pane surfaces (occlusion, overlapping WGL children), `windowDestroyed`,
  close and close-confirm flows, quit teardown (`destroyAllWindows`,
  `App.destroyPaneOf`), focus after a close, shell reducer effects,
  local and structural undo/redo (`win32_undo.zig`,
  `win32_structural_history.zig`, `undo-timeout`, split undo and redo through
  the shell model: `Host.applyCommittedSplitHistory`).
- [input.md](docs/agents/log/input.md): `win32/input.zig` and key messages
  (`WM_KEYDOWN`/`WM_CHAR`/`WM_SYSCHAR`, dead keys, `ToUnicode`, non-Latin
  layouts), default Windows keybindings, Win32 input mode (DEC 9001), the
  bytes ConPTY's input parser gets with 9001 off (`windows_legacy` in
  `src/input/key_encode.zig`, the `function_keys.zig` rows it reads), IME
  (the composition string, its caret and target clause:
  `win32_input.imeTargetCodepointRange`, `Surface.imePosAt`), mouse buttons
  (the X buttons: `win32_input.xMouseButton`, and the button codes
  `src/input/mouse_encode.zig` writes), wheel and context-menu input.
- [launch-and-paths.md](docs/agents/log/launch-and-paths.md): which process a
  terminal starts and with what environment: the default `command`, profile
  discovery and user-defined profiles (`src/config/windows_shell.zig`: the
  `profile-*` keys, `default-profile`, `profile-order`, `profile-hidden`,
  `verbatimCommandLine`, `arrangeProfiles`; Visual Studio developer shells in
  `src/config/windows_visual_studio.zig`; `win32_elevation.RelaunchProfile`),
  safe mode's
  `cmd.exe /D`, `CreateProcessW` name resolution, Git Bash discovery, WSL
  (`wsl_env.zig`, the terminfo probe and its cache, `TERM`), the terminfo
  install (`win32_terminfo.zig`), `noctty +list-profiles`
  (`src/cli/list_profiles.zig`, which applies the system color scheme through
  `os/color_scheme.zig`), what a log line may print of a command, an
  argument, an environment value or a directory (`os/redact.zig`,
  `Command.redacted()`); path safety (`os.path.isNetworkOrDevicePath`,
  `OBJ_DONT_REPARSE`) for every program-reported path before it is opened
  (OSC 7/9;9/1337 pwd), and for kitty graphics `t=f`/`t=t` files, which use
  an ordinary open whose canonical path is checked afterwards, so the open
  itself can still reach a share (`terminal/kitty/graphics_image.zig` and
  `terminal/kitty/windows.zig`, the `t=t` delete through the opened handle
  in `os/windows.zig` `deleteOpenedFile`, and the length of a path before
  Zig converts it);
  link and quick-select path detection and opening (the opener's gate:
  `prepareWin32OpenTarget`, `prepareWin32LocalFile`, `isSafeLinkText`,
  `local_target.entryName`, and its hidden-desktop probe
  `test/windows/link-opener-pathext-probe.ps1`; the link prompt:
  `App.openLink`, `askBeforeOpeningLink`, `confirmedLinkScheme`,
  `linkHandlerName`, `labels.linkPromptBody`,
  `Surface.setPendingLinkOpen`/`takePendingLinkOpen`).
- [clipboard.md](docs/agents/log/clipboard.md): clipboard reads and writes,
  CF_HTML (`win32_clipboard_html.zig`), open retries, what a copy puts on the
  clipboard (formats and owner, as Remote Desktop's redirection sees them),
  the empty bracketed paste and the paste of copied files
  (`Surface.completeClipboardPasteWithoutText`, `selectClipboardContents`,
  `win32_ole.extractHdrop`), OSC 52 prompts and
  replies, paste protection (`win32_paste_protection.zig`), drag-and-drop
  (`win32_surface_drop*.zig`), pending clipboard confirmations.
- [settings.md](docs/agents/log/settings.md): the Settings window
  (`win32_settings.zig`, `win32_settings_fields.zig`): its controls and when
  they are made (`SettingsWindow.open`, `materializeSection`), dialog
  manager, viewport, live preview (`App.settings_preview`, `App.shownConfig`,
  `App.shownBackgroundOpacity`), theming (`SettingsThemeAdapter`,
  `themeChanged`), its own UIA patterns, combo and open traces
  (`NOCTTY_SETTINGS_COMBO_TRACE`, `NOCTTY_SETTINGS_OPEN_TRACE`,
  `win32/bench_trace.zig`), the Default profile row
  (`field_model.Kind.profile`, `AppHandle.profileChoices`), the
  changed-from-default marks, Reset buttons and row menu (`syncDefaultMarks`,
  `takeResetButton`, `releaseResetButton`, `resetDraftRow`, `showRowMenu`,
  `field_model.effectiveSettingValue`), Settings search (`formItems`,
  `runSearch`, `suspendViewportRedraw`, `keepFocusShown`, `searchFinds`,
  `revealControl`, `showKeyboardCues`, `placeDiscardButton`, `SearchQuery`),
  and the save path (`settingsSaveAndReload`, `patchOrAppendEdits`, save
  target, masked values).
- [accessibility.md](docs/agents/log/accessibility.md): new widgets and UI
  events (adding a native widget, or changing its focus, children or
  notifiable properties); UIA providers under `src/apprt/win32_uia/` (COM
  identity and refcounts, BSTR and VARIANT ownership, `events.zig`); terminal
  text (`win32_terminal_accessibility.zig`, TextPattern, ScrollIntoView, the
  echo queue), palette and tab-list UIA.
- [config.md](docs/agents/log/config.md): config loading and reload outside
  the Settings window: the config file reader (`cli/args.zig` `LineIterator`,
  `streamDelimiterEnding`, `parseIntoField`, `ProfileMap`,
  `Config.file_read_buffer_len`), Windows environment expansion
  (`src/config/windows_shell.zig` `expandProfileText`), `--config-file` and
  `startup_cwd` on reload, diagnostics shown in the GUI, conditional replay
  (`Replay.Iterator`, `Config.finalize`, `loadTheme`,
  `changeConditionalState`), command-line values put
  back over `config-file` includes (`Config.parseManuallyHook`,
  `finalizeCliLaunch`), `newConfig` shallow
  clones, what `Surface.DerivedConfig` must own, `RepeatableCommand.clone`
  and its C mirror (`value_c`, `Command.cval`), `+edit-config` and opening
  the config file, adding config keys.
- [app-lifecycle.md](docs/agents/log/app-lifecycle.md): `App.init` and
  startup stalls, a cold `--launch-layout` (`App.startup_launch_layout`,
  `forgetLaunchLayout`), startup attempts and safe mode, session state
  (capture, restore, owner lock and quarantine: `win32/session.zig`) and
  state-file schemas, IPC and single instance (`win32/ipc_server.zig`), AUMID
  and portable identity, the jump list, toasts and desktop notifications
  (their tab attribution, tags and history removal, `App.showToast`, the COM
  activator in `win32_toast_activator.zig`), an installer's Restart Manager
  close and a session end (`App.onQueryEndSession`, `App.onEndSession`,
  `registerInstallerRestart`, the lifecycle window), the bell, taskbar
  progress and icon, crash minidumps and Sentry, the COM apartment,
  default-terminal handoff, the CLI and the `noctty.com` wrapper.
- [build-release-ci.md](docs/agents/log/build-release-ci.md): `build.zig`
  (including the `bench:*` steps' `addBenchCoreImport`)
  and resources, the Windows target floor (`src/build/Config.zig`,
  `-Dtarget` `win10`/`win10_rs5`, and the std APIs it gates), packaging
  (`scripts/package-windows.ps1`, `dist/windows/noctty.iss`, what Setup's
  `CloseApplications` closes), signing, the updater (including
  `RegisterApplicationRestart` while an installer closes noctty, with
  `stagedInstallerRunning`; `pkg/wuffs/src/deflate.zig`, the raw DEFLATE
  decoder for update payloads), release workflows
  and package managers (WinGet, Scoop,
  Chocolatey), GitHub Actions CI (path filter, caching, runners), CRLF and
  `.gitattributes` in shipped files.
- [docs-and-site.md](docs/agents/log/docs-and-site.md): site edits (`site/`,
  including styles, scripts and the generated CSP/asset hashes); changing
  what README.md, PRIVACY.md, PACKAGING.md, `docs/*.md` or install copy
  claims about behaviour.
- [test-harnesses.md](docs/agents/log/test-harnesses.md): writing or running
  `test/windows/` harnesses (hidden desktops, the foreground, sandboxes, the
  interactive composite, the flagship contracts, the renderer parity harness
  `test/windows/renderer/Invoke-RendererParity.ps1`), CI test steps (the raw
  `zig test src/apprt/win32_compositor_native.zig` step, which confines
  `win32/sys.zig`'s imports to `src/apprt`), the Zig
  test runner's probe children and thread tests (`src/pty_transport_probe.zig`,
  `std.Progress.lockStdErr`, the search-thread tests in
  `src/terminal/search/Thread.zig`), the shared Win32 test fixtures
  (`win32/test_support.zig`, `TestSession`), PSReadLine history isolation
  (`scripts/windows-harness-history.ps1`, `--command=cmd.exe` pins), a bash
  probe's `HISTFILE`, and a test count or result that contradicts the code.
- [tooling.md](docs/agents/log/tooling.md): declaring `extern` functions or
  structs, casting Win32 handles and `LPARAM`/`LRESULT` (`@intCast`,
  `@bitCast`, `@ptrFromInt`), passing `[:0]u16` to text APIs, renaming or moving
  Zig declarations (the `src/apprt/win32.zig` split into `win32/*.zig`),
  `union(enum)` tests, PowerShell language traps, and `gh`,
  git and codex commands.

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
