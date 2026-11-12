# Privacy policy

Last updated: 16 October 2026

This policy covers Koreterm, the Windows terminal published by Richardson at
[github.com/richardsonvix/noctty_terminal](https://github.com/richardsonvix/noctty_terminal): the app
(installer, portable ZIP, and the `koreterm` command-line actions) and the
[koreterm.com](https://github.com/richardsonvix/noctty_terminal) website. Package managers that install the
published release files, such as Scoop or WinGet, install the same app.

## In short

- Koreterm has no telemetry, analytics, advertising, or accounts. It sends
  nothing to the maintainer, and the maintainer collects no personal data
  from it.
- The only server Koreterm contacts on its own is GitHub (or an update feed you
  set), to check for updates. You can turn that off.
- What Koreterm stores, such as your settings, your restorable session, recent
  folders, and crash dumps, stays on your PC. Koreterm uploads none of it.

## Network connections

### Update checks (on by default)

- When Koreterm starts, it asks the GitHub API for the latest stable release,
  unless a check succeeded in the last 24 hours. While a window stays open it
  tries again about every six hours, and still sends no request if a check
  succeeded in the last 24 hours. A failed check is retried at the next of
  those attempts or at the next start. Pre-release builds do not check on
  their own.
- **Check for Updates** in the command palette asks right away, even with
  automatic checks off. In a pre-release build it opens the releases page in
  your browser instead.
- The request carries no account, identifier, or information about your PC
  or how you use Koreterm. It sends standard HTTP headers, including a single
  user-agent value, `koreterm-updater`. As with any web request, GitHub sees
  your IP address.
- With `auto-update = download`, Koreterm also downloads the new release's
  checksum file and installer (for a portable copy, its ZIP and file
  manifest). The file names show your PC's architecture (x64 or ARM64) and
  whether the copy is portable. While Koreterm verifies a download's
  signatures, Windows may contact the certificate issuers named in them to
  check for revoked certificates.
- `auto-update = off` stops the automatic check. The `auto-update-feed-url`
  setting or the `KORETERM_UPDATE_FEED_URL` environment variable sends checks
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
- **SSH entries.** Koreterm reads the `Host` aliases in
  `%USERPROFILE%\.ssh\config` (and files it includes) and lists them as
  profiles. It uses nothing else from those files, never reads your keys,
  and never writes there. Opening an entry runs `ssh.exe` with that alias:
  the first `ssh.exe` on your `PATH`, otherwise Windows' OpenSSH. Set
  `ssh-config-hosts = false` to stop Koreterm reading the file.
- **Programs you run.** Shells, `ssh`, `git`, WSL, and other programs in
  Koreterm make their own connections. Koreterm does not see, filter, or record
  their network traffic.
- **Paths from programs.** A program can report its working directory. New
  tabs and splits, and your next session, start there if it is a folder on a
  drive letter, and in your home folder otherwise. A program can also ask
  Koreterm to display an image file, and a relative link you Ctrl+click is
  looked up in the reported directory. Koreterm refuses a working directory or
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

- `ssh-env`: when you run `ssh` from a shell with Koreterm's shell integration,
  it passes `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` (your
  Koreterm version) to the remote host, which keeps them only if its SSH server
  allows it.
- `ssh-terminfo`: in bash, zsh, fish, elvish, and nushell, when you connect to
  a host that is not in Koreterm's local SSH host cache, the `ssh` wrapper first
  opens a separate SSH connection to install Koreterm's terminal description in
  your account on that host (normally in `~/.terminfo`). If that works, it
  adds the host to the cache (see below); if not, it tries again next time.
  Each attempt leaves a small `ghostty-ssh-*` folder in your shell's temp
  directory. The PowerShell wrapper installs nothing on remote hosts.

### What Koreterm does not do

- It sends no telemetry, usage statistics, or crash reports. Its crash dumps
  stay on your PC; Windows Error Reporting follows your Windows settings.
- It has no accounts, sign-in, or cloud sync.
- Its notifications are local Windows notifications; it uses no push service.
- Apart from updates, it downloads nothing: no fonts, themes, or other
  content.
- It does not sell or share personal data, because it collects none.

## Data stored on your PC

Unless noted, these files live in `%LOCALAPPDATA%\koreterm`. In portable mode
they live next to `koreterm.exe` instead. If you set `XDG_CONFIG_HOME`, your
config goes there; if you set `XDG_STATE_HOME`, the update files, crash
dumps, and SSH host cache go there.

- **Config:** `config.ghostty`. If Koreterm finds no config at all, it creates
  a template here, with a comment giving the file's own path, which usually
  includes your Windows user name. The Settings window saves your changes
  here. Koreterm also reads `ghostty\config`, beside the `koreterm` folder, if it
  exists and, when it finds no other config, `winghostty\config.ghostty` left
  by an older version. Koreterm does not read `ghostty\config.ghostty`. If you
  have no Koreterm config file, the Settings window saves to one of the older
  files Koreterm does read, `ghostty\config` or `winghostty\config.ghostty`, if
  one exists, rather than creating a new Koreterm config.
- **Session restore:** `session-state.json`, saved when Koreterm closes, when
  you sign out or shut down, when the display configuration changes, and
  one second after a burst of window, tab or pane structural changes settles, by
  the one Koreterm process that owns it: one started normally, which holds
  `session-state.json.lock` while it runs. Other Koreterm processes (a second
  instance, an "Open koreterm here" window, a default terminal handoff) never
  write it. It is not saved in safe mode, when Koreterm runs as administrator
  through UAC, when it was started to run one command (`-e` or
  `initial-command`), without an initial window (`initial-window = false`),
  or from its startup profile picker, or
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
  timestamps. Koreterm builds the taskbar jump list from it and from the
  profiles it detects, which can include SSH aliases from your SSH config.
  Windows keeps its own copy of the jump list. From 1.3.133 a portable copy
  builds no jump list and writes no `jump-list-recents.json`; earlier portable
  copies did both.
- **Command palette history:** `palette-mru.txt` holds the last 5 commands you
  ran from the command palette, including any arguments you typed.
- **Updates:** `update-state.json` records when Koreterm last checked, the feed
  it used, the latest version it saw, the release page address, any version
  you dismissed, and the location and checksums of downloaded updates.
  Downloaded updates, and the installer log of an update you apply, go in
  `updates\`.
- **Startup record:** `startup-attempts.json` holds the times, error codes and
  Koreterm version of up to 16 recent launches, and when each began restoring
  the saved session and whether it finished, so Koreterm can start in safe mode
  after repeated failed starts. From 1.3.133 a launch that ended because OpenGL
  could not start also records when, and does not count toward safe mode.
- **Crash dumps:** `crash\`, written only when Koreterm crashes. A dump is a
  snapshot of parts of Koreterm's memory and can include fragments of what was
  on screen, file paths, and other text. `koreterm +crash-report` lists them.
- **Shell integration:** a copy of Koreterm's PowerShell integration script in
  `shell-integration\powershell\`. Koreterm does not edit your shell profiles.
- **Terminal description:** outside portable mode, Koreterm writes its terminfo
  entries, `78\xterm-ghostty` and `67\ghostty`, and a `.koreterm-installed`
  record to the `.terminfo` folder in your home directory, so Git for
  Windows' tools recognize it.
- **SSH host cache:** with `ssh-terminfo` only,
  `ssh_cache` lists each `user@host` that received the terminal description,
  with a date. It lives in `%LOCALAPPDATA%\koreterm` (or `koreterm` under
  `XDG_STATE_HOME`), and directly next to `koreterm.exe` in portable mode.
  Older versions used a `ghostty\ssh_cache` file; Koreterm leaves that file
  alone and rebuilds its new cache as needed.
- **Screen files:** the write-screen-to-file actions
  (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>J</kbd> and its variants) write the
  terminal's contents, including scrollback, or the selection to a new folder
  in your temp directory and leave it there.
- **Diagnostic bundle:** `koreterm +diagnostic-bundle` writes a folder in the
  current directory, or where `--output` says, with the Koreterm version and
  build settings, Windows version and build, build and native architectures,
  emulation status, install kind, the embedded PowerShell integration script's
  SHA-256, ConPTY source and fallback reason, and a crash-report count.
  It also lists recognized config key names written directly in the default
  config files, when readable. It collects no config values or paths and does
  not expand includes, themes, or command-line overrides. It includes no
  terminal text, command lines, working directories, or environment values.
  Crash dumps are included only if you add `--include-crash-dumps`; those
  dumps can contain sensitive process memory. Nothing is uploaded. An
  existing output directory is refused, so older dumps are never mixed into
  a new bundle.
- **Opt-in traces:** setting `KORETERM_HANDOFF_TRACE` writes `handoff.log`
  (always in `%LOCALAPPDATA%\koreterm`), and the `KORETERM_*_TRACE_FILE`
  environment variables write diagnostic traces to the files you name.
- **Housekeeping:** `.lock` files beside some of these, a `.corrupt` copy of
  any session or layout file Koreterm could not read, a `.restore-failed`
  copy of a saved session that repeatedly stopped Koreterm while restoring it,
  and a `.restore-ended` copy of a restored session whose programs all ended
  by themselves before anyone used it (up to five copies of each; older
  `.restore-failed` and `.restore-ended` copies are never replaced).

Koreterm writes these registry entries:

- **App identity:**
  `HKCU\Software\Classes\AppUserModelId\io.github.richardsonvix.koreterm` holds
  the app's name, the path of its icon, and a flag that lists it in Windows'
  notification settings. An installed Koreterm writes it at every start. From
  1.3.133 a portable copy writes it only if the key does not exist yet (and the
  copy has its `koreterm.ico` beside it), and never changes an existing one;
  earlier portable copies write it at every start like an installed one. A
  portable start that is cut off at the wrong moment can leave a
  `io.github.richardsonvix.koreterm.pending-<hex>` key beside it.
- **Installer:** Start menu (and optional desktop) shortcuts, the "Open koreterm
  here" Explorer menu, the default-terminal handoff classes, and its uninstall
  entry. The uninstaller removes them.
- **Explorer menu for portable copies:** `koreterm +register-shell-menu` adds
  "Open koreterm here" for your account; `+unregister-shell-menu` removes it.
- **Default terminal:** `koreterm +register-default-terminal` makes Koreterm the
  terminal Windows opens for console programs in your account. It writes
  per-user COM and console registry entries and saves the previous setting.
  `+unregister-default-terminal` restores that setting and removes Koreterm's
  entries, though it can leave empty `Interface` keys behind.

Windows keeps its own copies of some things Koreterm shows: notifications stay
in the notification center (they can contain text that programs in the
terminal send), and text you copy goes to Windows clipboard history, or your
other devices, if you have turned those on.

Koreterm does not keep a log file by default, a record of the commands you run
in the terminal, your keystrokes, or your clipboard. Apart from the cases
listed above, it does not save terminal text.

## Removing your data

Uninstalling removes the app, its shortcuts, and the registry entries the
installer created. It does not remove your data. To remove everything:

1. Before you uninstall:
   - Remove the entries from Koreterm's taskbar jump list by right-clicking
     them. Koreterm never deletes the list Windows keeps; after uninstalling,
     it stays in a `.customDestinations-ms` file in
     `%APPDATA%\Microsoft\Windows\Recent\CustomDestinations`.
   - If you used them, run `koreterm +unregister-default-terminal`,
     `koreterm +unregister-shell-menu`, and `koreterm +ssh-cache --clear`.
2. Close Koreterm and delete `%LOCALAPPDATA%\koreterm` (in portable mode, the files
   next to `koreterm.exe`), and the `koreterm` folders in `XDG_CONFIG_HOME` and
   `XDG_STATE_HOME` if you set them. Delete the `ghostty` and `winghostty`
   folders in the same places too if Koreterm is the only program that used
   them.
3. Delete the registry key
   `HKCU\Software\Classes\AppUserModelId\io.github.richardsonvix.koreterm`, and
   any `io.github.richardsonvix.koreterm.pending-<hex>` key beside it.
   Windows may also keep Koreterm's notification settings under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\io.github.richardsonvix.koreterm`.
4. In the `.terminfo` folder in your home directory, delete
   `78\xterm-ghostty`, `67\ghostty`, and `.koreterm-installed`. Other programs
   may use that folder, so do not delete it whole.
5. Delete any screen files and `ghostty-ssh-*` folders left in your temp
   directory.

If you used `ssh-terminfo`, the terminal description stays on the remote
hosts it was installed on.

## Website

koreterm.com contains no analytics, advertising, or tracking, its own code
sets no cookies, and it loads no third-party scripts or fonts. Its content
security policy blocks them.

- It is hosted on Cloudflare Pages. Like any web host, Cloudflare receives
  your IP address and browser details when you load a page, and handles them
  under the [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/).
- To show the current version, your browser asks the GitHub API for the
  latest release, so GitHub sees your IP address and that the request came
  from koreterm.com. The answer is kept in your browser's session storage and
  reused for 30 minutes.
- Your light or dark theme choice is kept in your browser's local storage.

## Changes and contact

Changes to this policy are made in this file, so its history shows every
change. Ask questions about it in
[Discussions](https://github.com/richardsonvix/noctty_terminal/discussions), and report a
privacy problem on the [issue tracker](https://github.com/richardsonvix/noctty_terminal/issues).
Report security vulnerabilities privately, as described in
[SECURITY.md](SECURITY.md).
