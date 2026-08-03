<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="images/winghostty-flag.svg" />
    <img src="images/winghostty-flag-light.svg" alt="Winghostty" width="320" />
  </picture>
</p>

<p align="center">
  <em>A Windows terminal emulator that reuses Ghostty's terminal core under a native Win32 front end.</em>
  <br />
  Native Win32 runtime · OpenGL renderer · Shared terminal core with Ghostty
</p>

<p align="center">
  <a href="https://github.com/amanthanvi/winghostty/releases">Releases</a>
  ·
  <a href="docs/getting-started.md">Getting started</a>
  ·
  <a href="docs/windows.md">Windows</a>
  ·
  <a href="docs/status.md">Status</a>
  ·
  <a href="docs/windows-capability-matrix.md">Windows capability matrix</a>
  ·
  <a href="HACKING.md">Hacking</a>
  ·
  <a href="CONTRIBUTING.md">Contributing</a>
  ·
  <a href="SECURITY.md">Security</a>
</p>

---

## What is winghostty?

winghostty is a terminal emulator for Windows. It pairs the **Ghostty
terminal core** — VT parser, screen and scrollback, font pipeline, and
renderer, forked from
[ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) — with a
**native Win32 application runtime** written for this fork: a real Windows
tab bar, splits, per-monitor DPI scaling, DWM dark title bar, IME,
drag-and-drop, native context menus, and a WSL-aware shell picker.

It also ships `libghostty-vt`, the Ghostty VT library, as a retained
deliverable for Zig and C consumers.

It's built for developers who are comfortable editing a plain-text config
file and clicking through a SmartScreen warning on first install.

## Status, honestly

winghostty is a young, single-maintainer fork (first fork commit 2026-04-06,
first public release 2026-04-16). It supports Windows 10 and 11 on x64 and
ARM64, and it runs as its own top-level app window — installing it alongside
Windows Terminal, WezTerm, or Alacritty is fine. macOS and Linux app runtimes
are not shipped from this repo and are not planned.

What works today, what's experimental, and what's out of scope is tracked
precisely in **[docs/status.md](docs/status.md)**; for a row-by-row mapping
against official Ghostty docs, see
**[docs/windows-capability-matrix.md](docs/windows-capability-matrix.md)**.

Questions and feedback go to
[Discussions](https://github.com/amanthanvi/winghostty/discussions) — GitHub
Issues are reserved for reproducible bugs.

## Install

Latest stable release:
**[winghostty 1.3.122](https://github.com/amanthanvi/winghostty/releases/tag/v1.3.122)**,
published 2026-08-03.

Download directly from **[Releases](https://github.com/amanthanvi/winghostty/releases)**:

| File                                                                                                                                                                 | Use when                                                 |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| [`winghostty-1.3.122-windows-x64-setup.exe`](https://github.com/amanthanvi/winghostty/releases/download/v1.3.122/winghostty-1.3.122-windows-x64-setup.exe)           | You want a normal x64 install with a Start menu entry.   |
| [`winghostty-1.3.122-windows-arm64-setup.exe`](https://github.com/amanthanvi/winghostty/releases/download/v1.3.122/winghostty-1.3.122-windows-arm64-setup.exe)       | You want a normal ARM64 install with a Start menu entry. |
| [`winghostty-1.3.122-windows-x64-portable.zip`](https://github.com/amanthanvi/winghostty/releases/download/v1.3.122/winghostty-1.3.122-windows-x64-portable.zip)     | You want to run x64 without installing.                  |
| [`winghostty-1.3.122-windows-arm64-portable.zip`](https://github.com/amanthanvi/winghostty/releases/download/v1.3.122/winghostty-1.3.122-windows-arm64-portable.zip) | You want to run ARM64 without installing.                |
| [`SHA256SUMS-windows-x64.txt`](https://github.com/amanthanvi/winghostty/releases/download/v1.3.122/SHA256SUMS-windows-x64.txt)                                       | Verifying x64 downloads.                                 |
| [`SHA256SUMS-windows-arm64.txt`](https://github.com/amanthanvi/winghostty/releases/download/v1.3.122/SHA256SUMS-windows-arm64.txt)                                   | Verifying ARM64 downloads.                               |

The legacy [`SHA256SUMS.txt`](https://github.com/amanthanvi/winghostty/releases/download/v1.3.122/SHA256SUMS.txt)
file remains an x64 auto-update compatibility alias.

WinGet users can install the official manifest:

```powershell
winget install AmanThanvi.winghostty
```

Scoop users can install from the fork-owned bucket:

```powershell
scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty
scoop install winghostty/winghostty
```

Release installers and the Windows binaries inside the portable ZIP are
Authenticode-signed (the ZIP container itself is checksummed, not signed),
but SmartScreen may still warn on first run while publisher reputation
builds. The full walkthrough — installer, portable, SmartScreen, uninstall —
is in **[docs/getting-started.md](docs/getting-started.md)**.

## First run

On first launch, winghostty writes a config template to
`%LOCALAPPDATA%\winghostty\config.ghostty`. The template sets no options —
defaults live in the binary. A minimal config:

```ini
font-family = JetBrains Mono
font-size   = 12
# Pick a theme from: winghostty +list-themes
# Theme files are config files; only use themes from sources you trust.
theme       = Dracula
```

Reload config without restarting: **Ctrl + Shift + ,**

A few keybindings to get moving — `Ctrl+Shift+T` for a new tab,
`Ctrl+Shift+Backslash` / `Ctrl+Shift+E` to split, `Alt+Arrow` to move between
panes, and `Ctrl+Shift+C` / `Ctrl+Shift+V` for copy and paste. The full table,
plus the rebind grammar, is in
**[docs/getting-started.md](docs/getting-started.md#5-keybindings)**.

## Privacy, updates, and crashes

winghostty sends no telemetry and no analytics. The only outbound network
call is the GitHub Releases updater (when you enable `auto-update`), which
checks at most once every 24 hours and never replaces binaries silently.
Update installation remains user-initiated.

Crash reports are never uploaded — dumps stay local under
`%LOCALAPPDATA%\winghostty\crash`, readable with `winghostty +crash-report`.
If a broken config or session state blocks launch, `winghostty --safe-mode`
starts once with built-in defaults.

Updater verification, crash-report details, and diagnostic bundles are
documented in **[docs/windows.md](docs/windows.md)**.

## Build from source

Most users should install from Releases. Building needs Windows 10/11 on x64
or ARM64, **Zig 0.15.x (patch ≥ 2)**, Visual Studio 2022 with the MSVC
toolchain on PATH, and Git for Windows:

```powershell
zig build -Demit-exe=true
```

Output lands at `zig-out\bin\winghostty.exe`. Toolchain details, dependency
cache seeding, the pre-configured dev shell, and test commands are in
**[HACKING.md](HACKING.md)**. Building the installer and portable ZIP
yourself is covered in **[PACKAGING.md](PACKAGING.md)**.

## Relationship to Ghostty

winghostty is a fork, not a re-implementation. Upstream is tracked as the
`upstream` Git remote, and the fork relationship is visible in full Git
history.

**Shared with upstream Ghostty**

- `src/terminal/` — VT parsing, screen state, scrollback, search, Kitty
  graphics protocol, OSC handling
- `src/font/` — font discovery and rasterization (HarfBuzz, FreeType)
- `src/renderer/` — OpenGL cell/image/shader pipeline
- `src/input/`, `src/config/`, `src/termio/`, `src/crash/`,
  `src/shell-integration/`, `src/inspector/`, `libghostty-vt`

**New in this fork**

- `src/apprt/win32.zig` — Win32 application runtime
- `src/apprt/win32_theme.zig` — theme tokens, DWM integration, accent
  helpers, high-contrast handling
- `src/update/github_releases.zig` — updater
- `dist/windows/` and `scripts/package-windows.ps1` — Windows packaging

**Removed from this fork**

- Upstream `macos/` Xcode project
- Upstream `src/apprt/gtk/` runtime
- Flatpak / Snap / Linux desktop packaging

Because the terminal core is shared, most Ghostty configuration options,
themes, and shell-integration behavior apply here directly. When
Windows-native behavior conflicts with upstream cross-platform behavior,
this fork prefers the Windows-native result.

## Contributing

Bug reports, reproducible issues, and focused PRs are welcome. Read
**[CONTRIBUTING.md](CONTRIBUTING.md)** and **[AI_POLICY.md](AI_POLICY.md)**
first. For usage questions and design discussion, use
**[Discussions](https://github.com/amanthanvi/winghostty/discussions)**.

## License

MIT. Copyright © 2024 Mitchell Hashimoto, Ghostty contributors. See
**[LICENSE](LICENSE)**.

Fork-specific changes are contributed under the same license by the fork's
maintainer and contributors.
