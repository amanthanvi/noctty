# Migrate from Windows Terminal

Noctty and Windows Terminal install side by side. Installing Noctty does not
replace Windows Terminal, modify its `settings.json`, or change your default
terminal application. Keep Windows Terminal until your shells, font, colors, and
keybindings behave the way you expect.

There is no `settings.json` importer, and there is no plan for one. The two
programs use different profile and configuration models, so this guide
translates the settings that affect a normal session and names the ones that
have no equivalent.

## 1. Record the settings you use

In Windows Terminal, open Settings and note your default profile, its command
line and starting directory, the font, the color scheme, opacity and padding,
and any keybinding you changed from the default. Leave `settings.json` where it
is; Noctty never reads it.

## 2. Install and verify Noctty

```powershell
scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty
scoop install noctty/noctty
```

Or install with WinGet: `winget install --id AmanThanvi.noctty -e`.

The installer does not add `noctty` to `PATH`. To run the `noctty +...` commands
below from a shell, add the install folder to `PATH` or run `.\noctty.com`
from that folder.

For a direct download, run the checksum and signature checks on the
[Why Noctty and verification page](https://noctty.com/why-noctty.html#verify).
The release signing certificate is self-signed, so SmartScreen warns even when
every check passes.

## 3. Translate the settings

Noctty's config is a plain key/value file at
`%LOCALAPPDATA%\noctty\config.ghostty`. One setting per line, no JSON, no
profile inheritance. Copy only the lines you need.

| Windows Terminal             | Noctty                                 | Notes                                                                               |
| ---------------------------- | -------------------------------------- | ----------------------------------------------------------------------------------- |
| `commandline`                | `command`                              | Quote a path containing spaces with the `direct:` form.                             |
| `startingDirectory`          | `working-directory`                    |                                                                                     |
| `font.face`                  | `font-family`                          |                                                                                     |
| `font.size`                  | `font-size`                            |                                                                                     |
| `colorScheme`                | `theme`                                | Bundled names come from `noctty +list-themes`. A WT scheme is not imported.         |
| `opacity`                    | `background-opacity`                   | Divide the Windows Terminal percentage by 100: `50` becomes `0.5`; `1.0` is opaque. |
| `useAcrylic`                 | `background-blur`                      | Accepted but inert on Windows; translucency is evenly tinted, never blurred.        |
| `padding`                    | `window-padding-x`, `window-padding-y` | Noctty splits horizontal and vertical padding.                                      |
| `copyOnSelect`               | `copy-on-select`                       |                                                                                     |
| `cursorShape`                | `cursor-style`                         |                                                                                     |
| `historySize`                | `scrollback-limit`                     | Different unit: WT counts lines, Noctty counts bytes. The default is 10 MB.         |
| `initialCols`, `initialRows` | `window-width`, `window-height`        | Grid cells, as in WT. Both must be set or both are ignored.                         |
| `backgroundImage`            | `background-image`                     |                                                                                     |
| `bellStyle`, `bellSound`     | `bell-features`, `bell-audio-path`     | See [The bell](#the-bell) below.                                                    |

### The bell

`bell-features` is a comma-separated list, and a feature with a `no-` prefix is
off. Unspecified features keep their defaults, so the mappings below explicitly
turn off noctty's title glyph. These are the closest equivalents for Windows
Terminal's `bellStyle`:

| `bellStyle` | `bell-features`                |
| ----------- | ------------------------------ |
| `audible`   | `system,no-attention,no-title` |
| `window`    | `attention,no-title`           |
| `taskbar`   | `attention,no-title`           |
| `all`       | `system,attention,no-title`    |
| `none`      | `false`                        |

The `window` mapping substitutes a taskbar flash for Windows Terminal's window flash.

`system` plays the Windows system sound, `attention` flashes the window's
taskbar button until the window is in front, and `bellSound` is `audio` with
`bell-audio-path` (and `bell-audio-volume`, which Windows Terminal has no
equivalent for). Windows Terminal also accepts an array of sound files and picks
one at random; noctty accepts one path. Windows Terminal's default is `audible`; noctty's default is
`attention,title`, which plays nothing and, for a terminal you are not looking
at, flashes the taskbar button and puts a bell glyph on the tab and the window
caption until you focus or type into it. Set
`bell-features = system,no-attention,no-title` to keep Windows Terminal's behaviour. See
[the capability matrix](windows-capability-matrix.md#notifications-and-progress)
for the details.

A short starting config:

```ini
font-family = Cascadia Mono
font-size = 12
theme = Dracula
background-opacity = 0.95
window-padding-x = 8
window-padding-y = 6
working-directory = C:\Users\you\source
copy-on-select = clipboard
```

Theme files are configuration files, so only load theme files from a source you
trust. The full option reference is `noctty +show-config --default --docs`.

## 4. Translate the keybindings

Windows Terminal has changed its defaults across versions, so check yours under
Settings, Actions rather than trusting memory. Against current Noctty defaults:

| Action              | Windows Terminal default      | Noctty default                            |
| ------------------- | ----------------------------- | ----------------------------------------- |
| Copy                | `Ctrl+C` with selection       | `Ctrl+Shift+C`                            |
| Paste               | `Ctrl+V`                      | `Ctrl+Shift+V`                            |
| New tab             | `Ctrl+Shift+T`                | `Ctrl+Shift+T`                            |
| Close tab           | `Ctrl+Shift+W`                | `Ctrl+Shift+W`                            |
| Next / previous tab | `Ctrl+Tab` / `Ctrl+Shift+Tab` | `Ctrl+Tab` / `Ctrl+Shift+Tab`             |
| Split pane          | `Alt+Shift+D` duplicates      | `Ctrl+Shift+\` right, `Ctrl+Shift+E` down |
| Move between panes  | `Alt+Arrow`                   | `Alt+Arrow`                               |
| Command palette     | `Ctrl+Shift+P`                | `Ctrl+Shift+P`                            |
| Find                | `Ctrl+Shift+F`                | `Ctrl+Shift+F`                            |
| Full screen         | `F11` or `Alt+Enter`          | `F11` (`Alt+Enter` goes to the program)   |
| Font size           | `Ctrl+=` / `Ctrl+-`           | `Ctrl+=` / `Ctrl+-`                       |

Most of the daily set already matches. Copy, paste, and splitting are the three
that will trip you up. Rebind anything you would rather keep:

```ini
keybind = ctrl+t=new_tab
keybind = ctrl+shift+c=copy_to_clipboard
keybind = performable:ctrl+v=paste_from_clipboard
```

Unbound, Ctrl+V reaches the program as a key. Bound as above, it pastes the
way Windows Terminal's does: text as text, files copied in Explorer as their
paths, and an image as the empty bracketed paste that tells a program such as
Claude Code, opencode or herdr to read the image off the clipboard itself (see
[Clipboard and paste](windows.md#clipboard-and-paste)). Claude Code, for one,
reads an image on Alt+V and ignores a bare Ctrl+V key, so a clipboard manager
that pastes by sending Ctrl+V attaches nothing until Ctrl+V is bound.
`performable:` hands the key back to the program when there is nothing to
paste. Whenever the paste does happen, the program never sees Ctrl+V, so
Vim's visual-block Ctrl+V needs Ctrl+Q instead, as in Windows Terminal.

`noctty +list-keybinds` prints the effective set, including anything not listed
above.

## 5. Start the same shell

Noctty detects PowerShell 7, Windows PowerShell, Command Prompt, Git Bash, and
installed WSL distributions, and offers them in the profile picker at
`Ctrl+Shift+P`. Try each one there before changing your default.

To pin one shell for every new terminal, set a single command:

```ini
# PowerShell 7
command = pwsh.exe

# Or opt in to the default WSL distribution
# command = wsl.exe
```

WSL is never selected as the implicit default, because `wsl.exe --status` can
report a healthy installation even when launching a session would fail. See
[Windows shell behavior](windows.md#shells) for the selection order and the WSL
working-directory rules.

## 6. Validate before switching habits

```powershell
noctty +validate-config
noctty +version
```

Then run one real session of each shell you use:

1. Open a new tab and a split.
2. Confirm the prompt starts in the expected directory.
3. Copy and paste multiline text.
4. Run a full-screen TUI and any SSH workflow you depend on.
5. Close Noctty normally, reopen it, and confirm windows, tabs, splits,
   profiles, and working directories restore. Child processes and live terminal
   contents are not restored.

Leave Windows Terminal set as your default terminal application during the
evaluation. Launch Noctty from the Start menu or its executable until the
workflows above hold up.

## What does not transfer

- `settings.json` itself: profile GUIDs, fragments, and JSON inheritance
- Windows Terminal actions and command-palette entries, which have their own
  vocabulary
- Acrylic and Mica materials; Noctty accepts `background-blur` but opts into
  no DWM transparency mechanism, so translucent windows are evenly tinted
  rather than blurred
- The retro terminal effect and other WT-specific rendering experiments
- Live tab contents and running child processes

## Honest gaps

Accessibility on Windows is partial: UI Automation covers the terminal text and
most chrome, but no screen reader has been measured against a release build. If
you rely on Narrator, NVDA, or JAWS today, stay on Windows Terminal and follow
[the matrix](accessibility-matrix.md).

For the current feature boundary, read [Status](status.md) and the
[Windows capability matrix](windows-capability-matrix.md) rather than assuming
upstream Ghostty or Windows Terminal documentation applies.
