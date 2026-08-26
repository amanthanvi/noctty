# Ghostty 1.3-surface Win32 wiring audit (C08)

Audited against the 1.3.2-dev baseline on 2026-08-19. These are inherited
core features that must not silently no-op on Windows.

| Feature | Win32 result | Evidence |
| --- | --- | --- |
| Kitty keyboard protocol | Wired | Win32 input path forwards key events into the shared kitty-keyboard encoder; WT 1.25 makes this table stakes |
| `scrollbar` | Partial | Overlay scrollbar + `window-scrollbar` was not reintroduced as a silent knob; geometry lives in `win32_scrollbar_geometry.zig` |
| Notify-on-command-finish | Wired | OSC 133 D / command-finished → WinRT toast + banner (`win32_toast_winrt.zig`) |
| `key-remap` | Wired | Shared `Config` key-remap applies before Win32 key dispatch |
| clipboard-codepoint-map | Wired | Shared config; Win32 clipboard write uses the mapped text |
| Scrollback search | Wired | Docked per-pane search bar |
| Key tables | Wired | `activate_key_table` works; copy mode uses `toggle_copy_mode` |
| OSC 9;4 progress | Wired | `ITaskbarList3` |
| Quick terminal | Wired | `win32_quick_terminal.zig` + `RegisterHotKey` |

Rows that stay `partial` are capability-matrix honest: the feature
runs, but Windows chrome differs from macOS docs.
