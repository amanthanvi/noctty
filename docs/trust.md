# Why winghostty, and how to verify it (C27)

winghostty is a Windows-only Ghostty fork. It is not the upstream
macOS/Linux app and it is not the other Ghostty-for-Windows experiments
in the field. This page is the identity and trust record.

## How we differ from the fork field

- Native Zig + raw Win32. No Electron, no WinUI/.NET shell.
- Signed Windows installers and PE binaries; winget (`AmanThanvi.winghostty`)
  and Scoop ship from this repo's release pipeline.
- Session restore, tabs, splits, quick terminal, WinRT toasts, and a
  native settings window already ship. See [status.md](status.md).
- Local-only. No accounts, no telemetry, no hosted AI.

## What we will never do

These are standing non-goals, each backed by a competitor failure:

1. No cloud coupling — no accounts, telemetry, or hosted services.
2. No AI-first pivot or bundled chatbot.
3. No feature breadth before performance and reliability.
4. No re-platforming onto Electron or fashionable UI frameworks.
5. No workspace/widget drift (embedded browsers, DB clients, file managers).
6. No forced or silent auto-update.
7. No in-process plugin runtime or hosted sync.
8. No DLL injection or undocumented hooks.
9. No daily-rebase soft-fork conversion.
10. No shell-editor interception or proprietary output protocol.
11. No chrome-only differentiation.

## Verify a binary

1. Download from [GitHub Releases](https://github.com/amanthanvi/winghostty/releases)
   only. Checksums live in `SHA256SUMS-windows-<arch>.txt`.
2. `Get-FileHash -Algorithm SHA256 winghostty-*-setup.exe` must match.
3. `Get-AuthenticodeSignature winghostty.exe` should show a signed
   publisher. SmartScreen can still warn for a new file hash; that is
   reputation accrual (C28), not an unsigned build.
4. The portable ZIP container is checksummed. Individual PE files inside
   are Authenticode-signed; the ZIP itself is not a signed catalog yet.

See [windows.md](windows.md#updates) and
[getting-started.md](getting-started.md#about-the-smartscreen-warning).

## Migration

- [Migrate from Windows Terminal](migrate-from-windows-terminal.md)
- [Migrate from Git Bash / mintty](migrate-from-git-bash.md)

## Accessibility

Screen-reader coverage is partial and published in
[windows-accessibility.md](windows-accessibility.md).
