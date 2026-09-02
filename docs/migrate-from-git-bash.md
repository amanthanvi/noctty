# Migrate from Git Bash and mintty

Git Bash is a shell distribution. mintty is the terminal window that Git for
Windows normally opens around it. Moving to Noctty replaces the terminal layer
only: Git, Bash, your repositories, and your shell startup files are untouched.

Keep the Git Bash shortcut while you test. Noctty does not remove Git for
Windows and does not modify `.bash_profile`, `.bashrc`, `.inputrc`, or your
shell history.

## 1. Install and verify Noctty

```powershell
winget install AmanThanvi.noctty

# Or:
scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty
scoop install noctty/noctty
```

For a direct installer or portable ZIP, run the checksum and signature checks
on the
[Why Noctty and verification page](https://noctty.com/why-noctty.html#verify).

## 2. Launch the detected Git Bash profile

Press `Ctrl+Shift+P`, search for Git Bash, and select that profile. Noctty finds
the Git for Windows Bash executable and launches it as an interactive login
shell (`--login -i`). Shell integration is automatic for directly launched
Unix-like shells, so prompt marks and working-directory reporting work without
replacing Bash's line editor.

If the profile is missing, confirm Git for Windows is installed, then set the
command explicitly in `%LOCALAPPDATA%\noctty\config.ghostty`. The path contains
spaces, so it needs the `direct:` form:

```ini
command = direct:"C:\Program Files\Git\bin\bash.exe" --login -i
```

Adjust the path if Git is installed elsewhere. Check the file with
`noctty +validate-config`, save it, and press `Ctrl+Shift+,` to reload.

## 3. What stays with the shell

These belong to Git Bash and need no migration at all:

- Git configuration and credentials
- `.bash_profile`, `.bashrc`, aliases, functions, and prompt setup
- Bash history and readline settings
- SSH keys, agent configuration, and `~/.ssh/config`

## 4. Translate `.minttyrc`

Noctty does not read `.minttyrc`. Its config lives at
`%LOCALAPPDATA%\noctty\config.ghostty`. The settings that have a real
equivalent:

| mintty option                          | Noctty                                 | Notes                                                                      |
| -------------------------------------- | -------------------------------------- | -------------------------------------------------------------------------- |
| `Font`                                 | `font-family`                          |                                                                            |
| `FontHeight`                           | `font-size`                            |                                                                            |
| `ThemeFile`                            | `theme`                                | `noctty +list-themes` lists bundled names. mintty themes are not imported. |
| `ForegroundColour`, `BackgroundColour` | `foreground`, `background`             | Noctty uses hex, for example `#1d1f21`.                                    |
| `CursorColour`                         | `cursor-color`                         |                                                                            |
| `CursorType`                           | `cursor-style`                         | `block`, `bar`, `underline`.                                               |
| `CursorBlinks`                         | `cursor-style-blink`                   |                                                                            |
| `Transparency`                         | `background-opacity`                   | mintty uses named levels; Noctty takes a number from 0 to 1.               |
| `ScrollbackLines`                      | `scrollback-limit`                     | Different unit: mintty counts lines, Noctty counts bytes. Default 10 MB.   |
| `CopyOnSelect`                         | `copy-on-select`                       |                                                                            |
| `Columns`, `Rows`                      | `window-width`, `window-height`        | Grid cells. Both must be set or both are ignored.                          |
| `ConfirmExit`                          | `confirm-close-surface`                |                                                                            |
| `Padding`                              | `window-padding-x`, `window-padding-y` |                                                                            |

A short starting config:

```ini
font-family = Cascadia Mono
font-size = 12
theme = Dracula
copy-on-select = clipboard
```

The complete option reference is `noctty +show-config --default --docs`.

## 5. Translate the keyboard

mintty's window shortcuts do not carry over. The Noctty defaults you will use
daily:

| Task              | mintty                     | Noctty default                                    |
| ----------------- | -------------------------- | ------------------------------------------------- |
| Copy              | `Ctrl+Insert`              | `Ctrl+Shift+C`                                    |
| Paste             | `Shift+Insert`             | `Ctrl+Shift+V`                                    |
| New window or tab | `Alt+F2` opens a window    | `Ctrl+Shift+T` opens a tab                        |
| Split             | not supported              | `Ctrl+Shift+\` right, `Ctrl+Shift+E` down         |
| Search            | `Alt+F3`                   | `Ctrl+Shift+F`                                    |
| Font size         | `Ctrl+plus` / `Ctrl+minus` | `Ctrl+=` / `Ctrl+-`                               |
| Command palette   | none                       | `Ctrl+Shift+P`                                    |
| Options           | the right-click menu       | edit `config.ghostty`, reload with `Ctrl+Shift+,` |

mintty's own shortcuts vary with its options file, so compare against yours
rather than this column alone. Rebind anything with
`keybind = <trigger>=<action>` and inspect the effective set with
`noctty +list-keybinds`.

## 6. Check the PTY boundary

This is the part that actually behaves differently. mintty uses the MSYS and
Cygwin PTY model. Noctty runs Git Bash through Windows' ConPTY, so native
Windows console programs launched from Bash can behave differently even though
Bash and its dotfiles are identical.

Before you make Noctty your normal shortcut, test:

1. `git status`, your prompt, completion, and history.
2. A full-screen program such as Vim, Neovim, or `less`.
3. Copy and paste, and Unicode filenames.
4. SSH to a host you use regularly.
5. A native Windows CLI launched from Bash, for example `winget` or `python`.

Do not set `TERM` in a startup file to imitate mintty. Let Noctty and its shell
integration advertise the terminal, and override it only for one compatibility
problem you can reproduce.

## What does not transfer

- `.minttyrc` as a file: colors, font, mouse, and window options
- mintty-only shortcuts and launcher flags
- mintty's terminal-specific escape-sequence extensions
- Cygwin and MSYS PTY behavior, which ConPTY does not reproduce exactly
- Live terminal contents and running child processes

## Honest gaps

Git Bash is a first-class detected profile, but Noctty does not claim
byte-for-byte mintty emulation, and the ConPTY difference above is real rather
than theoretical. Accessibility is also partial: no screen reader has been
measured against a release build, and the per-widget state is recorded in
[the matrix](accessibility-matrix.md).

For the currently tested surface, read [Status](status.md) and the
[Windows capability matrix](windows-capability-matrix.md).
