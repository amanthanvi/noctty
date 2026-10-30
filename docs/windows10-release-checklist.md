# Windows 10 pre-release checklist

A manual pass on Windows 10 22H2 before each release. Windows 10 1809 (build 17763) and newer is a supported floor (see [status.md](status.md#supported-platform)),
but no per-PR job or interactive harness runs on a Windows 10 desktop, and every
chrome, input and startup change is measured on Windows 11 only. This list is how
a release gets Windows 10 evidence. It is a release step, not a PR gate.

The scheduled [Windows 10 branches](../.github/workflows/windows10-branches.yml)
workflow covers the part a hosted runner can reach; [what the workflow covers](#what-the-workflow-covers)
says which rows that is. Everything else here needs a person and a Windows 10
desktop.

## When to run it

- Before every release, with the release candidate's artifacts (see the
  [release runbook](../PACKAGING.md#release-runbook)).
- Produce the candidate from the exact intended source SHA with the
  [local packaging procedure](../PACKAGING.md#local-packaging), passing
  `-RequireConPty` and with Inno Setup available for the installed rows. Local
  builds are unsigned unless signing is configured; record that limit.
  **Release Readiness** produces no candidate artifacts. Record the candidate's
  source SHA and hashes. Stable publication rebuilds assets, so the pass binds
  to the source SHA; record shipped hashes separately. A later source change
  needs a new candidate and the affected rows repeated before publication.
- A release whose diff since the last Windows 10 pass touches none of the files in
  the [gate inventory](#gate-inventory) and no chrome, input or startup code may
  run only the rows marked **Core**. Say in the release notes which pass was run.
- Record the outcome in the [results table](#results). A failed row blocks the
  release unless the release notes list it as a known Windows 10 limit.

## The machine

- A Windows 10 22H2 x64 VM or PC, build 19045, fully updated. Record
  `winver` and `[Environment]::OSVersion.Version`. The default-terminal rows need
  build 19045.3031 or newer (KB5026435), the first update with that setting; see
  [Windows Terminal installation](https://learn.microsoft.com/en-us/windows/terminal/install#set-your-default-terminal-application)
  (Microsoft Learn, updated 2025-11-12).
- A snapshot taken before any noctty is installed. Revert to it between the
  portable pass and the installed pass, and after the default-terminal rows.
- Display scaling 100% to start; rows that need another scale say so.
- A VM without GPU acceleration has no OpenGL 4.3 driver. Put
  `renderer = d3d11-warp` in `config.ghostty` beside `noctty.exe` first (see
  [Starting without OpenGL](windows.md#starting-without-opengl)) and record that
  you did; the rows below do not depend on the renderer.
- The release candidate's portable ZIP, checked against its `SHA256SUMS` file
  ([verify-release.md](verify-release.md)), unpacked into a new folder. Rows
  marked **installed** also need the installer on a clean snapshot.
- A second machine at build 17763 is optional and used for one row (W10-02).

Do not change input, display or lock settings beyond what a row says. Do not
register noctty as the default terminal on a machine you cannot restore.

## What the workflow covers

[Windows 10 branches](../.github/workflows/windows10-branches.yml) runs weekly and
on demand on the `windows-2022` hosted image, Windows Server 2022 build 20348. It
is below build 22000, so every `os_build >= 22000` gate takes its Windows 10
branch. GitHub offers no Windows 10 image: `windows-2019` was retired on
2025-06-30 ([runner-images#12045](https://github.com/actions/runner-images/issues/12045)),
and the image list shows Windows Server 2025, Windows Server 2022 and Windows 11
Arm64 ([runner-images README](https://github.com/actions/runner-images)).

It exercises: the full unit suite, a `noctty +version` smoke, and a hidden-desktop
launch of the real binary (the WARP lifecycle smoke) whose log is checked for
`win32 os_build=<below 22000> integrated_titlebar=false`. It does not exercise a
Windows 10 desktop shell, the taskbar, toasts, the jump list, Explorer, a real
mouse or keyboard, the caption and font set of a Windows 10 desktop, or the
default-terminal setting.
Those rows say **manual** below. The runner image is a Server edition, so a green
run is evidence about the branches, not about Windows 10 22H2 as users have it.

## Gate inventory

Every place the code decides by Windows build, with the rows that check it. Add a
row here and below when a new gate appears; the verification contract fails when a
gate function named in the source is missing from this page.

| Gate (symbol, file)                                                        | Rule                                                                                                                                                         | Rows                     |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------ |
| `probeWindowsBuild` (`win32.zig`), `App.os_build`                          | `RtlGetVersion` build, cached; a failed probe reads 0 and takes the Windows 10 path                                                                          | W10-01                   |
| `shouldUseIntegratedTitlebar` (`win32.zig`), `App.use_integrated_titlebar` | Build 22000 (`OS_BUILD_WIN11_21H2`) and `window-show-tab-bar` not `never`                                                                                    | W10-03, W10-04, W10-05   |
| `tabsFlushWithTop` (`win32/host.zig`)                                      | Build 22000, ordinary host and visible strip: maximized app-owned top edge or fullscreen tabs extend upward; Windows 10 and quick terminals retain the inset | W10-03, W10-06 to W10-10 |
| `undecoratedKeepsFrame` (`win32/window_state.zig`)                         | Build 22000 and not the quick terminal: `window-decoration = none` keeps the frame                                                                           | W10-06 to W10-10         |
| `supportsDwmSystemBackdropAttribute` (`win32.zig`)                         | Build 22621 (`OS_BUILD_WIN11_22H2`) for `DWMWA_SYSTEMBACKDROP_TYPE`                                                                                          | W10-12                   |
| `OS_BUILD_WIN10_22H2` (`win32/consts.zig`)                                 | 19045, used only by tests that stand in for this machine                                                                                                     | W10-01                   |
| DWM attributes 20 and 19, 34 to 36 (`win32_theme.zig`)                     | Dark caption tries 20, then 19; border, caption and text colour need build 22000                                                                             | W10-11, W10-12           |
| Titlebar icon font chain (`createTitlebarIconFont`, `win32/host.zig`)      | Segoe Fluent Icons, then Segoe MDL2 Assets, by glyph table; else `win32_icons`                                                                               | W10-16                   |
| Chrome and Settings fonts (`createChromeFont`, `recreateUiFont`)           | Segoe UI Variable Text where present, else Segoe UI                                                                                                          | W10-15                   |
| `GUID_ENERGY_SAVER_STATUS` (`win32_power.zig`)                             | Windows 11 Energy Saver; the registration may fail elsewhere and is not a warning                                                                            | W10-26                   |
| ConPTY source (`pty.zig`)                                                  | Bundled `conpty.dll` and `OpenConsole.exe`, else the in-box conhost                                                                                          | W10-19, W10-02           |
| Default-terminal delegation (`win32_terminal_handoff.zig`)                 | Needs the console-delegation setting the OS provides                                                                                                         | W10-22                   |
| Toasts, AUMID, jump list, Explorer verbs                                   | Shell features that look different on Windows 10                                                                                                             | W10-23 to W10-25         |
| `directVolumePath`, `directVolumeDeviceName` (`os/windows.zig`)            | Any build: maps the DOS drive alias before a guarded open; Windows 10 may reject it                                                                          | W10-27, W10-28           |

## Rows

Each row names the setting, the exact action and the expected result. "Expected"
is what the code and the docs promise; where the promise comes from Windows 11
measurements, the row says so, and a different result on Windows 10 is a finding
to record, not necessarily a bug.

Save the child's log first for the rows that read it. A GUI launch has no
console, so start the executable with its stderr redirected:

```powershell
Start-Process .\noctty.exe -ArgumentList '--single-instance=false' -RedirectStandardError .\err.txt
```

`noctty.com` starts the executable with stderr discarded, so use the `.exe`
here. The noctty log is at info level in release builds.

### Startup and identity

**W10-01 Build probe (Core).** Gate: `probeWindowsBuild`. Start as above, close
it, and open `err.txt`. Expected: one line `win32 os_build=19045
integrated_titlebar=false`. Any other `os_build` means the probe or the VM is not
what the record says; `os_build=0` means `RtlGetVersion` failed and every gate
fell to its Windows 10 default.

**W10-02 Loads at all (optional, build 17763 machine).** `CreatePseudoConsole`
is a static `kernel32` import, so 1809 is the hard floor ([windows.md](windows.md#supported-systems)).
On the 1809 machine run `noctty.com +version`, then start `noctty.exe`. Expected:
no "entry point not found" dialog; a terminal opens. The bundled ConPTY may not
load on 1809; then the banner names the reason and the in-box conhost serves the
shell (W10-19).

### Frame and tab strip

**W10-03 Stock caption with a separate tab row (Core).** Gate:
`shouldUseIntegratedTitlebar`. Default config. Expected: Windows draws the title
bar and its minimise, maximise and close buttons; the tab strip is a separate row
below it (32 DIP tall at 100%, not the 40 DIP integrated row); noctty draws no
caption buttons of its own. Open two tabs, maximise, restore, double-click the
caption, then run `toggle_fullscreen` and leave fullscreen. Repeat at 150%
scaling (Settings > Display, then start a fresh noctty): the row scales and nothing
clips. The separate tab row keeps its 3 DIP top
inset when maximized and fullscreen; the flush top edge is a Windows 11 change.

**W10-04 `window-show-tab-bar = never`.** Expected: no strip and no one-pixel
remnants of tab buttons across the top of the client area (#244, #245), with two
or more tabs open; switching tabs with `Ctrl+Tab` works; the stock caption stays.
Reload the config to `auto` (`Ctrl+Shift+,`): the strip returns without a restart.

**W10-05 No Snap Layouts flyout.** Hover the maximise button for two seconds, and
press `Win+Z`. Expected: Windows 10 has no layouts flyout, so nothing appears and
nothing throws; dragging the title bar to a screen edge, and `Win+Left`, snap the
window as for any application.

### Undecorated and quick-terminal windows

Gate for W10-06 to W10-09: `undecoratedKeepsFrame`. On Windows 10 an undecorated
window is frameless (see [Windows, tabs, and splits](windows.md#windows-tabs-and-splits)).

**W10-06 First window with `window-decoration = none` (Core).** Set it in
`config.ghostty`, close every noctty, start one. Expected: no title bar at all
(#270: `CreateWindowEx` adds `WS_CAPTION` to an overlapped style with no frame
bits, and the host removes it again before the first tab), no border, no shadow.
The cursor stays an arrow at every window edge (no resize border). `Alt+Space`
opens no window menu. Dragging the tab strip does not move the window. The
separate tab row keeps its 3 DIP top inset, including at 150% scaling.

**W10-07 Maximise covers the taskbar.** Run the palette action `toggle_maximize`
(`Ctrl+Shift+P`) on the undecorated window. Expected, as documented: it covers the
taskbar. If the window instead stops at the work area, the documentation line is
out of date; record it. The tab buttons retain their 3 DIP top inset when
maximized; they do not extend to the client area's top edge as on Windows 11.

**W10-08 Decoration toggle round trip.** From a decorated window run the palette
action `toggle_window_decorations`, then again. Expected: the caption disappears
and returns. The style change preserves the outer window rectangle; the client
area changes as the caption and frame are removed and restored. Record both
rectangles during the round trip from a normal window. This expectation comes
from the `SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED` path, not a Windows 10
measurement. A maximised window is a separate observation:
the Windows 10 path rewrites the window style without `WS_MAXIMIZE`
(`docs/agents/log/window-frame.md`, 2026-09-24 entry, trap 4), so toggling
while maximised is expected to leave an un-maximised window inside the maximised rectangle. Record what you
see; neither outcome is a pass or a fail. The separate tab row keeps its 3 DIP
top inset on both sides of the decoration toggle.

**W10-09 Fullscreen round trip.** Maximise, then `toggle_fullscreen`, leave
fullscreen, then restore from maximised. Expected: the window returns to its
normal size and place, not to the maximised rectangle (the 2026-10-06 fullscreen
entry in `docs/agents/log/window-frame.md` describes the Windows 11 failure this
guards). While fullscreen with tabs shown, the tab buttons retain their 3 DIP
top inset; after leaving fullscreen, check the same inset when maximized and
after restoring.

**W10-10 Quick terminal.** There is no default key for it. Put `quick-terminal-position
= top` and `keybind = global:ctrl+alt+q=toggle_quick_terminal` in the config, reload
with `Ctrl+Shift+,`, and press `Ctrl+Alt+Q`. Expected: frameless on both Windows
versions, flush with the top edge, full width, no gap and no shadow.
The host's outer edge is flush with the screen; its tab buttons keep their
3 DIP inset from the top of the client area, as quick terminals do on Windows 11.

### Theme and DWM

**W10-11 Dark caption (Core).** Set Windows app mode to light, then `window-theme
= dark`. Expected: the caption turns dark. noctty tries `DWMWA_USE_IMMERSIVE_DARK_MODE`
(20) and, when DWM answers `E_INVALIDARG`, attribute 19. Microsoft documents
attribute 20 from Windows 11 build 22000 ([DWMWINDOWATTRIBUTE](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute),
page dated 2026-03-09); Windows 10 acceptance of 20 or 19 is observed behaviour, so
record which of the two worked. Then `window-theme = light` and `system`: the
caption follows the setting live. Also check the settings window's caption.

**W10-12 Caption colours, border and backdrop are ignored.** Gate:
`supportsDwmSystemBackdropAttribute` and the Windows 11 attributes
`DWMWA_CAPTION_COLOR`, `DWMWA_TEXT_COLOR` and `DWMWA_BORDER_COLOR`, which Microsoft
lists from build 22000 (backdrop type from 22621). Set `window-theme = ghostty` and
`window-titlebar-background = #204060`. Expected: the stock caption does not take
the colour, nothing is logged as an error, and the separate tab row keeps the
theme's own colours. `background-opacity = 0.8` fades the whole window (layered
alpha, independent of the build); `background-blur = true` changes nothing, as on
Windows 11.

**W10-13 Active tab (Core).** Open three tabs. Expected: the active tab takes
the terminal's background and runs on into the terminal below it, with no border,
underline or strip above the tab row in any accent colour; its label starts with
`* `. Picking another Windows accent (Settings > Personalization > Colors)
changes nothing in the tab row. A config that still sets `accent-follow-system`
loads without an error.

**W10-14 High Contrast.** Turn on a High Contrast theme (Settings > Ease of
Access), then off. Expected: chrome switches to system colours with a visible
focus mark, then back, live, with no restart. Windows 11 has the same behaviour
under `-ExerciseHighContrast` in the palette-theme harness; this row is the Windows
10 desktop's own theme path.

### Fonts and icons

**W10-15 Chrome and Settings fonts.** Open Settings (`Ctrl+,`). Expected: text in
Segoe UI (Windows 10 has no Segoe UI Variable), no clipped labels at 100%, 150% and
200%. The tab titles, palette and banner use the system message font, Segoe UI.

**W10-16 Tab-row `+` and `▾` glyphs (Core).** Gate: `createTitlebarIconFont`. In the
separate tab row, look at the new-tab and dropdown buttons, at 100% and 150%.
Expected: a plus and a chevron, never a hollow box. Microsoft does not ship
Segoe Fluent Icons with Windows 10 ([Segoe Fluent Icons font](https://learn.microsoft.com/en-us/windows/apps/design/style/segoe-fluent-icons-font)),
and `CreateFontIndirectW` returns a substitute for a missing face, which draws a
hollow box for every icon (measured on build 26300 with a face that is not
installed). So the code takes the first of Segoe Fluent Icons and Segoe MDL2 Assets
whose glyph table has every titlebar icon, and draws the built-in vector icons when
neither has; on Windows 10 that should be Segoe MDL2 Assets. A box or an empty
button is a defect: record it with a screenshot.

**W10-17 Search bar icons.** Open the search bar (`Ctrl+Shift+F`). Expected: six
buttons, previous, next, regex, case, whole word and close, drawn from the embedded
Codicons font, none empty. If the font cannot register, the shapes come from the
built-in vector icons and `err.txt` holds one warning; never empty boxes.

**W10-18 Fallback fonts.** Print `😀`, `漢字` and `देवनागरी`. Expected: glyphs from the
fonts Windows picks (#280), no `?` boxes where Windows 10 has a font. Record any
script whose box remains and the fonts that Windows 10 lacks.

### ConPTY and shells

**W10-19 ConPTY source (Core).** Close all noctty windows before each case and
start each test instance with `--single-instance=false` so an existing instance
cannot consume the launch with a different environment or ConPTY source.
(a) Run `.\noctty.com +version`. Expected: `ConPTY :
bundled (<path>)`. Open `cmd`, run `cls` and `dir`, then start a full-screen
program (for example `more` on a long file). (b) Set `NOCTTY_CONPTY=inbox` in the
environment and run `.\noctty.com +version` and a new instance. Expected: `+version` reads
`ConPTY : inbox (NOCTTY_CONPTY=inbox is set)`, `err.txt` holds the warning
`NOCTTY_CONPTY=inbox is set; using the in-box conhost`, there is no banner (a forced
choice is the user's own, `pty.zig`), and the shell works. (c) Without the variable,
copy the folder, delete `conpty.dll` from the copy and start it. Expected: a banner
that begins "Using Windows' in-box console host because conpty.dll is not next to
noctty.exe", and a working shell. [windows.md](windows.md#keyboard) says the in-box
conhost of build 19045 was not measured for key encoding; record anything that looks
wrong in the in-box path as such.

**W10-20 Alt chords do not beep.** In the shell press `Alt+F`, `Alt+B`, `Alt+Left`.
Expected: the terminal gets the chords and Windows plays no sound (#250, #252,
measured on Windows 11 only). `Alt+Space` on a decorated window opens the window menu
and `Esc` closes it.

**W10-21 Windows PowerShell 5.1 first tab (Core).** On a Windows 10 machine without
PowerShell 7 the shipped shell is Windows PowerShell 5.1, and with no execution policy
set in any scope the effective policy is `Restricted`, the default for Windows
clients ([about_Execution_Policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies),
PowerShell 7.6 view updated 2026-09-01). Check with `Get-ExecutionPolicy -List`. Open a tab with `command = powershell.exe`.
Expected: no red error text at the first prompt, the prompt shows, `cd` to another
folder and open a new tab (`Ctrl+Shift+T`) to see it start in that folder (OSC 7),
and `jump_to_prompt` finds the previous prompt (OSC 133).

### Windows integrations

**W10-22 Default terminal (installed, throwaway snapshot only).** Gate:
`win32_terminal_handoff.zig`. (a) With Windows Terminal not installed, run
`.\noctty.com +register-default-terminal`. Expected, per
[Default terminal](windows.md#default-terminal): it refuses when `DelegationConsole`
is missing, empty or the inbox console host, printing "Cannot register noctty as the
default terminal: HKCU\Console\%%Startup\DelegationConsole is missing or selects
the inbox console host", and writes nothing. Check that key is unchanged. (b) Install Windows Terminal 1.24 or newer, open its
Settings > Startup and choose "Windows Terminal" as the default terminal application
(installing it does not select it; registration needs that selection for the console
half). Note `DelegationConsole` and `DelegationTerminal` under that key. Run
`.\noctty.com +register-default-terminal`. Expected: it succeeds. Start `cmd.exe` from the
Run dialog. Expected: a visible noctty window adopts the console (a separate
`-Embedding` process, see [Default terminal](windows.md#default-terminal)). (c) Run
`.\noctty.com +unregister-default-terminal` and start `cmd.exe` again. Expected: the two
values are back to what (b) recorded, and the console opens in Windows Terminal.
Revert to the snapshot afterwards.

**W10-23 Toasts (installed).** Install with the installer so the Start Menu shortcut
carries the AppUserModelID. Set `notify-on-command-finish = always` and
`notify-on-command-finish-action = notify`, run `Start-Sleep 12` and switch to
another window. Expected: a toast named "noctty" with the noctty
icon whose last line reads `Tab 1: <tab title>`, in Action Center afterwards;
clicking its popup focuses the pane. Run it twice more without looking at the
tab: Action Center holds one entry for the pane, the newest. Switch to the tab:
the entry leaves Action Center. The next two checks test closing and
quitting, so nothing may count as seeing the tab first: from the moment the
toast is shown until the close or the quit, stay in the noctty window with
the pane focused. Do not switch windows, open Action Center or click the
popup in between: bringing noctty forward or focusing the pane counts as
seeing the tab and removes the entry by itself. With `always` the toast shows
while the pane is focused. Press `Ctrl+Shift+T`, run `Start-Sleep 12` in the
new tab, wait for the popup (if none appears, the check does not count), then
type `exit` there so its pane closes. Open Action Center: the entry is gone.
Close Action Center, run `Start-Sleep 12` in the remaining tab, wait for the
popup, then press `Ctrl+Shift+Q` without leaving the window. At an idle prompt
no confirmation appears; if one does, the check does not count, so run it
again. Open Action Center: the entry is gone. Start noctty again, turn Focus
Assist to "Alarms only" and repeat the first toast.
Expected: either the toast (record whether it pops up or only reaches Action
Center) or an in-app banner ending in the same tab line; never nothing. Turn
Focus Assist off again. Action Center clicks: open a second tab, run
`Start-Sleep 12` in the first, switch to the second tab, minimize noctty and
wait until the popup is gone. Click the entry in Action Center. Expected:
noctty restores, shows the first tab with its pane focused, and comes to the
foreground (record whether it did or only flashed its taskbar button). Click
a fresh toast's popup once: the pane is focused once. With
`quit-after-last-window-closed = false`, close every window while a toast is
in Action Center and click it: one window opens and comes forward. Start a
portable copy while no installed noctty runs, so that it is the
single-instance noctty, minimize it, and click one of its entries in Action
Center: the installed activator hands the click over and the portable window
restores and comes to the foreground (record whether it only flashed its
taskbar button); close it. Then end noctty's
process in Task Manager while one of its toasts is in Action Center, and click
that entry: one noctty window opens (with the session restored if that is
on) and comes forward. Uninstall, then check that
`HKCU\Software\Classes\AppUserModelId\io.github.amanthanvi.noctty` has no
`CustomActivator` value and `Software\Classes\CLSID\{3E21F05E-C82D-4E45-AA7D-2EC361AD6C3E}`
exists under neither HKLM nor HKCU. Then revert to the clean snapshot and repeat with the portable copy only:
it creates the AppUserModelID registration where none exists
([App identity](windows.md#app-identity)). Portable toast delivery has not been
confirmed: record whether the toast appears, its icon and Action Center entry,
and any banner, rather than treating registration alone as proof of delivery.
A portable copy registers no toast activator: its popup click focuses the
pane, and a click on its Action Center entry does nothing.

**W10-24 Jump list (installed).** After `cd` in a few folders, right-click the taskbar
button. Expected: "Recent" lists the folders, "Profiles" lists the detected shells;
choosing an entry opens noctty in that folder or profile. A portable copy builds no
jump list ([Taskbar jump list](windows.md#taskbar-jump-list)).

**W10-25 Explorer verb and taskbar progress.** Run `.\noctty.com +register-shell-menu`, then
right-click a folder in Explorer. Expected: "Open noctty here" is in the main context
menu (Windows 11 puts it under "Show more options"); it opens a new instance in that
folder. Run `.\noctty.com +unregister-shell-menu` afterwards. Then, in a tab, print
`printf '\e]9;4;1;50\a'` from Git Bash or `[Console]::Write("$([char]27)]9;4;1;50$([char]7)")`
from PowerShell. Expected: a progress bar on the taskbar button; `OSC 9;4;0` clears
it.

**W10-26 Power notifications.** Start noctty and read `err.txt`. Expected: no
`AC/DC power notifications unavailable` and no `battery-saver notifications
unavailable` warning (Energy Saver registration may fail on Windows 10; that is
logged at debug level only and is not a warning). On a laptop, turn on Battery Saver
with `power-saver-rendering = auto` and watch a streaming command: output is paced
near 30 fps.

### Default shell and file links

Both rows check the change in #450, which resolves the DOS drive alias (`C:`)
to its direct volume path before a file is opened with `OBJ_DONT_REPARSE`:
in shell detection (whose guarded open came with #443), in the link opener and
in the WSL safety probe. The rows exercise the first two; no row here reaches
the WSL probe. It was written because an upstream report
(openai/codex#46290) has Windows 10 22H2 build 19045.6456 rejecting the alias
itself under that flag. That the same happens to noctty is inferred, and
neither row has been run on Windows 10. Record the build number with the
result.

**W10-27 Default shell with `command` unset (Core).** Gate: `directVolumePath`
(`os/windows.zig`), used by shell detection in `windows_shell.zig`. Install
PowerShell 7 so that `pwsh.exe` is on `PATH`, for example with the MSI or
`winget install Microsoft.PowerShell`, after W10-21, which needs the machine
without it. Open a new console afterwards (a session started before the
install keeps the old `PATH`, which noctty would inherit) and check that
`Get-Command pwsh.exe` finds it. Start the portable copy from that console
with `--single-instance=false` and a
`config.ghostty` that sets neither `command` nor `default-profile`. In the
first tab run `$PSVersionTable.PSVersion` and `(Get-Process -Id $PID).Path`.
Expected: PowerShell 7.x, and a path ending in `pwsh.exe`
([windows.md](windows.md#shells) gives the order: `pwsh.exe` on `PATH`, then
Windows PowerShell, then `cmd.exe`). Windows PowerShell 5.1 or Command Prompt
in that tab, with `pwsh.exe` on `PATH`, is a finding: shell detection opens
each candidate with `OBJ_DONT_REPARSE`, and a rejected `pwsh.exe` falls through
to the next shell.

**W10-28 Ctrl+click on a local file path (Core).** Gate: `directVolumePath` and
`directVolumeDeviceName` (`os/windows.zig`), used by the link opener
(`os/local_path.zig`). Create a text file on a local drive with
`Set-Content "$env:TEMP\noctty-link.txt" hello`, print its path with
`"$env:TEMP\noctty-link.txt"`, and Ctrl+click the printed path. Expected: the
file opens in the application registered for `.txt` (Notepad on a clean image).
Then print `C:\no-such-folder\noctty-link.txt` and Ctrl+click it. Expected:
nothing opens. Nothing opening for the existing file is a finding: the opener
checks the file with `OBJ_DONT_REPARSE`, and refuses the link if that open
fails.

## Results

Copy this table into the release notes' validation section or the release PR.

| Row               | Result (pass, fail, n/a) | Build | Evidence (screenshot, log line, note)        |
| ----------------- | ------------------------ | ----- | -------------------------------------------- |
| W10-01            |                          |       |                                              |
| W10-02            |                          |       |                                              |
| W10-03            |                          |       |                                              |
| W10-04            |                          |       |                                              |
| W10-05            |                          |       |                                              |
| W10-06            |                          |       |                                              |
| W10-07            |                          |       |                                              |
| W10-08            |                          |       |                                              |
| W10-09            |                          |       |                                              |
| W10-10            |                          |       |                                              |
| W10-11            |                          |       |                                              |
| W10-12            |                          |       |                                              |
| W10-13            |                          |       |                                              |
| W10-14            |                          |       |                                              |
| W10-15            |                          |       |                                              |
| W10-16            |                          |       |                                              |
| W10-17            |                          |       |                                              |
| W10-18            |                          |       |                                              |
| W10-19            |                          |       |                                              |
| W10-20            |                          |       |                                              |
| W10-21            |                          |       |                                              |
| W10-22            |                          |       |                                              |
| W10-23            |                          |       |                                              |
| W10-24            |                          |       |                                              |
| W10-25            |                          |       |                                              |
| W10-26            |                          |       |                                              |
| W10-27            |                          |       |                                              |
| W10-28            |                          |       |                                              |
| Machine and image |                          |       | `winver`, VM type, display scaling           |
| Artifact          |                          |       | source SHA, version, SHA-256 of ZIP or setup |
| Date and tester   |                          |       |                                              |
