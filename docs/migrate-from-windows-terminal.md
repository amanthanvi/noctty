# Migrate from Windows Terminal

winghostty is a local-only GPU terminal. It does not import
`settings.json`. Recreate the pieces that matter:

1. **Shells.** The profile picker already detects PowerShell 7, Windows
   PowerShell, `cmd`, Git Bash, and WSL distros. Pin a default with
   `command = pwsh.exe` (or `wsl.exe`) in
   `%LOCALAPPDATA%\winghostty\config.ghostty`.
2. **Working directory.** `working-directory` and jump-list recent
   folders replace WT's startingDirectory + jump lists.
3. **Keybinds.** `+list-keybinds` dumps the current map. WT chords such
   as `ctrl+shift+t` (new tab) and `alt+arrow` (pane focus) already have
   Ghostty equivalents.
4. **Default terminal.** Windows Terminal owns `ITerminalHandoff` today.
   winghostty advertises the COM class but does not set
   `DelegationTerminal` until pipe-attach lands (C11). Keep WT as the
   OS default until then.
5. **Elevation.** Use **Open Elevated Window** from the palette. Mixed
   elevation tabs are intentionally out; that is a separate process,
   matching WT's documented model.
6. **Quake / dropdown.** `toggle_quick_terminal` plus
   `quick-terminal-*` config.
7. **Uninstall WT later.** winghostty does not require WT to be
   uninstalled. Side-by-side is the expected path.
