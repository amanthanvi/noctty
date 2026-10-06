# Privacy policy

Last updated: 6 October 2026

This policy covers Noctty, the Windows terminal published by Aman Thanvi at
[github.com/amanthanvi/noctty](https://github.com/amanthanvi/noctty): the app
(installer, portable ZIP, and the `noctty` command-line actions) and the
[noctty.com](https://noctty.com) website. Package managers that install the
published release files, such as Scoop or WinGet, install the same app.

## In short

- Noctty has no telemetry, analytics, advertising, or accounts. It sends
  nothing to the maintainer, and the maintainer collects no personal data
  from it.
- The only server Noctty contacts on its own is GitHub (or an update feed you
  set), to check for updates. You can turn that off.
- What Noctty stores, such as your settings, your restorable session, recent
  folders, and crash dumps, stays on your PC. Noctty uploads none of it.

## Network connections

### Update checks (on by default)

- When Noctty starts, it asks the GitHub API for the latest stable release,
  unless a check succeeded in the last 24 hours. A failed check is retried at
  the next start. It does not check again while it keeps running.
  Pre-release builds do not check on their own.
- **Check for Updates** in the command palette asks right away, even with
  automatic checks off. In a pre-release build it opens the releases page in
  your browser instead.
- The request carries no account, identifier, or information about your PC
  or how you use Noctty. It sends standard HTTP headers, including two
  user-agent values: `noctty-updater` and the default of the Zig HTTP library
  it uses, `zig/<version> (std.http)`. As with any web request, GitHub sees
  your IP address.
- With `auto-update = download`, Noctty also downloads the new release's
  checksum file and installer (for a portable copy, its ZIP and file
  manifest). The file names show your PC's architecture (x64 or ARM64) and
  whether the copy is portable. While Noctty verifies a download's
  signatures, Windows may contact the certificate issuers named in them to
  check for revoked certificates.
- `auto-update = off` stops the automatic check. The `auto-update-feed-url`
  setting or the `NOCTTY_UPDATE_FEED_URL` environment variable sends checks
  to a feed you choose instead of GitHub, and downloads to the addresses that
  feed lists.
- GitHub handles these requests under the
  [GitHub General Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
  GitHub counts downloads of release files and shows the totals publicly.
  Those counts identify no one.

### Connections you or your programs start

- **Links.** Opening a link, such as a URL you click in the terminal or the
  update notice, hands it to your default browser or the app registered for
  that kind of link.
- **SSH entries.** Noctty reads the `Host` aliases in
  `%USERPROFILE%\.ssh\config` (and files it includes) and lists them as
  profiles. It uses nothing else from those files, never reads your keys,
  and never writes there. Opening an entry runs `ssh.exe` with that alias:
  the first `ssh.exe` on your `PATH`, otherwise Windows' OpenSSH. Set
  `ssh-config-hosts = false` to stop Noctty reading the file.
- **Programs you run.** Shells, `ssh`, `git`, WSL, and other programs in
  Noctty make their own connections. Noctty does not see, filter, or record
  their network traffic.
- **Paths from programs.** A program can report its working directory. New
  tabs and splits, and your next session, start there if it is a folder on a
  drive letter, and in your home folder otherwise. A program can also ask
  Noctty to display an image file, and a relative link you Ctrl+click is
  looked up in the reported directory. Noctty refuses a working directory or
  image file on a network share or device path (`\\server\share`,
  `\\?\UNC\...`, `\\.\pipe\...`), so such a path never makes Windows connect
  to a share. A share you mapped to a drive letter is an ordinary drive to
  Windows and is treated as one.
- **Clipboard.** Programs, including ones on a remote host you reach over
  SSH, can put text on your clipboard. They can read it only after you allow
  it. Change this with `clipboard-write` and `clipboard-read`.
- **Terminal identity.** Programs, and through SSH the hosts you connect to,
  can see that the terminal is Ghostty-compatible and its version, through
  the `TERM` variable and standard terminal queries.

### Optional SSH features (off by default)

These apply only if you add them to `shell-integration-features`, or set it
to `true`:

- `ssh-env`: when you run `ssh` from a shell with Noctty's shell integration,
  it passes `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` (your
  Noctty version) to the remote host, which keeps them only if its SSH server
  allows it.
- `ssh-terminfo`: in bash, zsh, fish, elvish, and nushell, when you connect to
  a host that is not in Noctty's local SSH host cache, the `ssh` wrapper first
  opens a separate SSH connection to install Noctty's terminal description in
  your account on that host (normally in `~/.terminfo`). If that works, it
  adds the host to the cache (see below); if not, it tries again next time.
  Each attempt leaves a small `ghostty-ssh-*` folder in your shell's temp
  directory. The PowerShell wrapper installs nothing on remote hosts.

### What Noctty does not do

- It sends no telemetry, usage statistics, or crash reports. Its crash dumps
  stay on your PC; Windows Error Reporting follows your Windows settings.
- It has no accounts, sign-in, or cloud sync.
- Its notifications are local Windows notifications; it uses no push service.
- Apart from updates, it downloads nothing: no fonts, themes, or other
  content.
- It does not sell or share personal data, because it collects none.

## Data stored on your PC

Unless noted, these files live in `%LOCALAPPDATA%\noctty`. In portable mode
they live next to `noctty.exe` instead. If you set `XDG_CONFIG_HOME`, your
config goes there; if you set `XDG_STATE_HOME`, the update files, crash
dumps, and SSH host cache go there.

- **Config:** `config.ghostty`. If Noctty finds no config at all, it creates
  a template here, with a comment giving the file's own path, which usually
  includes your Windows user name. The Settings window saves your changes
  here. Noctty also reads `ghostty\config`, beside the `noctty` folder, if it
  exists and, when it finds no other config, `winghostty\config.ghostty` left
  by an older version. If you have no Noctty config, the Settings window can
  save to one of these older files or to `ghostty\config.ghostty`.
- **Session restore:** `session-state.json`, saved when Noctty closes, except
  in safe mode, when Noctty runs as administrator through UAC, when it was
  started to run one command (`-e` or `initial-command`), without an initial
  window (`initial-window = false`), or from its startup profile picker, or
  if you set `window-save-state = never`. It holds window positions and sizes,
  tabs and splits, each pane's shell profile and last working directory as
  reported by the shell, and titles you gave tabs or panes. It holds terminal
  text only if you set `window-save-state-scrollback` above 0 (the default is
  0). For SSH panes it keeps no working directory or profile, but it still
  saves their terminal text if you turned that on.
- **Named layouts:** `layouts\<name>.json`, only when you save a layout. Same
  contents as a session, without terminal text or window positions.
- **Recent folders:** `jump-list-recents.json` holds the 10 most recent
  working directories your shells reported, folders you removed from the
  jump list, and the profiles you launched, including SSH host aliases, with
  timestamps. Noctty builds the taskbar jump list from it and from the
  profiles it detects, which can include SSH aliases from your SSH config.
  Windows keeps its own copy of the jump list.
- **Command palette history:** `palette-mru.txt` holds the last 5 commands you
  ran from the command palette, including any arguments you typed.
- **Updates:** `update-state.json` records when Noctty last checked, the feed
  it used, the latest version it saw, the release page address, any version
  you dismissed, and the location and checksums of downloaded updates.
  Downloaded updates, and the installer log of an update you apply, go in
  `updates\`.
- **Startup record:** `startup-attempts.json` holds the times and error codes
  of up to 16 recent launches, so Noctty can start in safe mode after repeated
  failed starts.
- **Crash dumps:** `crash\`, written only when Noctty crashes. A dump is a
  snapshot of parts of Noctty's memory and can include fragments of what was
  on screen, file paths, and other text. `noctty +crash-report` lists them.
- **Shell integration:** a copy of Noctty's PowerShell integration script in
  `shell-integration\powershell\`. Noctty does not edit your shell profiles.
- **Terminal description:** outside portable mode, Noctty writes its terminfo
  entries, `78\xterm-ghostty` and `67\ghostty`, and a `.noctty-installed`
  record to the `.terminfo` folder in your home directory, so Git for
  Windows' tools recognize it.
- **SSH host cache:** with `ssh-terminfo` only,
  `%LOCALAPPDATA%\ghostty\ssh_cache` (in portable mode, `ghostty\ssh_cache`
  next to `noctty.exe`) lists each `user@host` that received the terminal
  description, with a date.
- **Screen files:** the write-screen-to-file actions
  (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>J</kbd> and its variants) write the
  terminal's contents, including scrollback, or the selection to a new folder
  in your temp directory and leave it there.
- **Diagnostic bundle:** `noctty +diagnostic-bundle` writes a folder in the
  current directory, or where `--output` says, with the Noctty version and
  platform. It includes crash dumps only if you add `--include-crash-dumps`.
- **Opt-in traces:** setting `NOCTTY_HANDOFF_TRACE` writes `handoff.log`
  (always in `%LOCALAPPDATA%\noctty`), and the `NOCTTY_*_TRACE_FILE`
  environment variables write diagnostic traces to the files you name.
- **Housekeeping:** `.lock` files beside some of these, and a `.corrupt` copy
  of any session or layout file Noctty could not read.

Noctty writes these registry entries:

- **App identity:**
  `HKCU\Software\Classes\AppUserModelId\io.github.amanthanvi.noctty` holds
  the app's name, the path of its icon, and a flag that lists it in Windows'
  notification settings. Noctty writes it at every start, including in
  portable mode.
- **Installer:** Start menu (and optional desktop) shortcuts, the "Open noctty
  here" Explorer menu, the default-terminal handoff classes, and its uninstall
  entry. The uninstaller removes them.
- **Explorer menu for portable copies:** `noctty +register-shell-menu` adds
  "Open noctty here" for your account; `+unregister-shell-menu` removes it.
- **Default terminal:** `noctty +register-default-terminal` makes Noctty the
  terminal Windows opens for console programs in your account. It writes
  per-user COM and console registry entries and saves the previous setting.
  `+unregister-default-terminal` restores that setting and removes Noctty's
  entries, though it can leave empty `Interface` keys behind.

Windows keeps its own copies of some things Noctty shows: notifications stay
in the notification center (they can contain text that programs in the
terminal send), and text you copy goes to Windows clipboard history, or your
other devices, if you have turned those on.

Noctty does not keep a log file by default, a record of the commands you run
in the terminal, your keystrokes, or your clipboard. Apart from the cases
listed above, it does not save terminal text.

## Removing your data

Uninstalling removes the app, its shortcuts, and the registry entries the
installer created. It does not remove your data. To remove everything:

1. Before you uninstall:
   - Remove the entries from Noctty's taskbar jump list by right-clicking
     them. Noctty never deletes the list Windows keeps; after uninstalling,
     it stays in a `.customDestinations-ms` file in
     `%APPDATA%\Microsoft\Windows\Recent\CustomDestinations`.
   - If you used them, run `noctty +unregister-default-terminal`,
     `noctty +unregister-shell-menu`, and `noctty +ssh-cache --clear`.
2. Close Noctty and delete `%LOCALAPPDATA%\noctty` (in portable mode, the files
   next to `noctty.exe`), and the `noctty` folders in `XDG_CONFIG_HOME` and
   `XDG_STATE_HOME` if you set them. Delete the `ghostty` and `winghostty`
   folders in the same places too if Noctty is the only program that used
   them.
3. Delete the registry key
   `HKCU\Software\Classes\AppUserModelId\io.github.amanthanvi.noctty`.
   Windows may also keep Noctty's notification settings under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\io.github.amanthanvi.noctty`.
4. In the `.terminfo` folder in your home directory, delete
   `78\xterm-ghostty`, `67\ghostty`, and `.noctty-installed`. Other programs
   may use that folder, so do not delete it whole.
5. Delete any screen files and `ghostty-ssh-*` folders left in your temp
   directory.

If you used `ssh-terminfo`, the terminal description stays on the remote
hosts it was installed on.

## Website

noctty.com contains no analytics, advertising, or tracking, its own code
sets no cookies, and it loads no third-party scripts or fonts. Its content
security policy blocks them.

- It is hosted on Cloudflare Pages. Like any web host, Cloudflare receives
  your IP address and browser details when you load a page, and handles them
  under the [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/).
- To show the current version, your browser asks the GitHub API for the
  latest release, so GitHub sees your IP address and that the request came
  from noctty.com. The answer is kept in your browser's session storage and
  reused for 30 minutes.
- Your light or dark theme choice is kept in your browser's local storage.

## Changes and contact

Changes to this policy are made in this file, so its history shows every
change. Ask questions about it in
[Discussions](https://github.com/amanthanvi/noctty/discussions), and report a
privacy problem on the [issue tracker](https://github.com/amanthanvi/noctty/issues).
Report security vulnerabilities privately, as described in
[SECURITY.md](SECURITY.md).
