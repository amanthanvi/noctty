# Deep dive: wintty

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

What are wintty's (deblasis/wintty — C# WinUI 3 shell over libghostty,
DirectX 12, daily-rebased soft fork of Ghostty) strengths, weaknesses,
and blind-spot lessons for winghostty, per [rubric](../rubric.md)?
This is the direct rival — the other "Ghostty for Windows" — so go
deepest here: its soft-fork-with-daily-rebase model vs. our hard fork,
its WinUI 3 + DX12 architecture vs. our Win32 + OpenGL, and its
completed-feature list (command palette, settings UI, session
persistence, backdrops, jump lists) vs. docs/status.md deserve explicit
head-to-head treatment. Report: `research/wintty.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/wintty.md`](../research/wintty.md).

Wintty is the direct rival "Ghostty for Windows": a solo, daily-rebased soft fork wrapping libghostty.dll in a C# WinUI 3 shell with a DX12/DirectComposition renderer, shipping in ~5 months a broad native surface (quake terminal, frecency palette, vertical tabs, jump lists, backdrops, toasts, Kitty images via a bundled newer OpenConsole conpty.dll) and best-in-class empirical ConPTY/VT documentation. Its fatal weaknesses are distribution and trust: zero releases, signed installer and auto-update gated behind GitHub Sponsors, GitHub Actions and Discussions disabled, x64-only, bus factor 1, ~45 stars — and its own maintainer spiked a pure-Win32/no-.NET escape hatch (<200ms first frame target) that validates winghostty's architecture. winghostty should adopt wintty's ConPTY workarounds and measurement culture while exploiting its installability, CI, and ARM64 lead; note that winghostty's status.md undersells the code (quick terminal, toasts, taskbar progress already exist).
