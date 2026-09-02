<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="images/noctty-flag.svg" />
    <img src="images/noctty-flag-light.svg" alt="Noctty" width="320" />
  </picture>
</p>

<p align="center">
  <strong>Noctty</strong> is Ghostty's terminal core in a native Windows app.
  <br />
  Tabs, splits, session restore · Win32 and OpenGL · No telemetry
</p>

<p align="center">
  <sub>winghostty was renamed to Noctty in August 2026 after a <a href="https://github.com/amanthanvi/noctty/issues/119">trademark request from the Ghostty team</a>.</sub>
</p>

<p align="center">
  <a href="https://github.com/amanthanvi/noctty/releases">Releases</a>
  ·
  <a href="docs/getting-started.md">Getting started</a>
  ·
  <a href="docs/windows.md">Windows</a>
  ·
  <a href="docs/status.md">Status</a>
  ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <img src="images/noctty-screenshot.png" alt="noctty with two tabs and a vertical split, Dracula theme" width="820" />
</p>

---

noctty is a terminal emulator for Windows. The terminal core comes from
[Ghostty](https://github.com/ghostty-org/ghostty); the Win32 app around it was
written for this fork. You get native tabs, splits, and context menus, session
restore, a command palette, a shell picker for PowerShell, cmd, Git Bash, and
WSL, per-monitor DPI scaling, IME input, and most Ghostty config options and
themes.

The project is young and has one maintainer. It installs as its own app, so
keep your current terminal while you try it. macOS and Linux are not planned.
[docs/status.md](docs/status.md) tracks what works and what is experimental;
[docs/windows-capability-matrix.md](docs/windows-capability-matrix.md)
compares it feature by feature with upstream Ghostty.

## Install

You need Windows 10 or 11, x64 or ARM64, and a GPU driver with OpenGL 4.3 or
newer. Latest release:
[noctty 1.3.124](https://github.com/amanthanvi/noctty/releases/tag/v1.3.124),
published 2026-09-02.

With Scoop (the WinGet package is pending bootstrap):

```powershell
scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty
scoop install noctty/noctty
```

Or download from the release page. The installers add a Start menu entry; the
portable ZIPs run from any folder.

| File                                                                                                                                                     | What it is      |
| -------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| [`noctty-1.3.124-windows-x64-setup.exe`](https://github.com/amanthanvi/noctty/releases/download/v1.3.124/noctty-1.3.124-windows-x64-setup.exe)           | x64 installer   |
| [`noctty-1.3.124-windows-arm64-setup.exe`](https://github.com/amanthanvi/noctty/releases/download/v1.3.124/noctty-1.3.124-windows-arm64-setup.exe)       | ARM64 installer |
| [`noctty-1.3.124-windows-x64-portable.zip`](https://github.com/amanthanvi/noctty/releases/download/v1.3.124/noctty-1.3.124-windows-x64-portable.zip)     | x64 portable    |
| [`noctty-1.3.124-windows-arm64-portable.zip`](https://github.com/amanthanvi/noctty/releases/download/v1.3.124/noctty-1.3.124-windows-arm64-portable.zip) | ARM64 portable  |

Each release also ships signed manifests of the portable ZIP contents
(`noctty-1.3.124-windows-x64-portable.manifest.ps1`,
`noctty-1.3.124-windows-arm64-portable.manifest.ps1`) and checksums
(`SHA256SUMS-windows-x64.txt`, `SHA256SUMS-windows-arm64.txt`, plus
`SHA256SUMS.txt`, an x64 alias kept for older auto-update clients).

Releases are signed with a self-signed certificate, so SmartScreen warns on
first run. Check the download against its checksum file before running it;
[docs/verify-release.md](docs/verify-release.md) covers that and the stronger
checks. Install steps, portable use, and uninstall are in
[docs/getting-started.md](docs/getting-started.md). Guides for moving from
[Windows Terminal](docs/migrate-from-windows-terminal.md) and
[Git Bash/mintty](docs/migrate-from-git-bash.md) are also available.

## Configure

On first launch noctty writes a config template to
`%LOCALAPPDATA%\noctty\config.ghostty`. Defaults live in the binary, so the
template sets nothing. Set `font-family`, `font-size`, and `theme` there and
press `Ctrl+Shift+,` to reload.

`Ctrl+Shift+T` opens a tab, `Ctrl+Shift+\` and `Ctrl+Shift+E` split,
`Alt+Arrow` moves between panes, and `Ctrl+Shift+P` opens the command palette.
The full table and how to rebind are in
[docs/getting-started.md](docs/getting-started.md#keybindings). Scripting
noctty from the CLI is covered in [docs/automation.md](docs/automation.md).

## Updates, crashes, and privacy

noctty sends no telemetry. Its only outbound network activity is the update
check against GitHub Releases, which runs on launch (at most once every 24
hours) unless you set `auto-update = off`. An update is never installed until
you start it. Crash dumps stay under `%LOCALAPPDATA%\noctty\crash` and are
never uploaded; read them with `noctty +crash-report`. If a broken config or
saved session blocks launch, `noctty --safe-mode` starts once with built-in
defaults. Details are in [docs/windows.md](docs/windows.md).

## Build from source

You need Zig 0.15.x (patch 2 or later), Visual Studio 2022 with the MSVC
toolchain on PATH, and Git for Windows.

```powershell
zig build -Demit-exe=true
```

The binary lands at `zig-out\bin\noctty.exe`. [HACKING.md](HACKING.md) covers
the dev shell and tests; [PACKAGING.md](PACKAGING.md) covers building the
installer and portable ZIP.

## Relationship to Ghostty

noctty is a fork of Ghostty and tracks it as the `upstream` Git remote. The
terminal core, fonts, renderer, input, config, shell integration, and
`libghostty-vt` are shared. The Win32 runtime, updater, and Windows packaging
are new here; the macOS and GTK runtimes are removed. Where Windows-native
behavior conflicts with upstream's, this fork picks the Windows-native result.
noctty is not affiliated with the Ghostty project.

## Contributing

Bug reports and focused PRs are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md)
and [AI_POLICY.md](AI_POLICY.md) first. Questions go to
[Discussions](https://github.com/amanthanvi/noctty/discussions); Issues are for
reproducible bugs. Pull requests get automated review from Greptile:

[![Greptile: The War on Bugs](https://www.greptile.com/badge.svg)](https://www.greptile.com/?utm_source=oss_badge&utm_medium=readme&utm_campaign=greptile_for_open_source)

## License

MIT. Copyright © 2024 Mitchell Hashimoto, Ghostty contributors. See
[LICENSE](LICENSE). Fork-specific changes are contributed under the same
license.
