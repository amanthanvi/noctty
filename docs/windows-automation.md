# Automation surface (C25)

Staged. Verb design waits for upstream 1.4 scriptability (via C33)
so the contract is not designed twice.

## Current verbs

| Verb | What it does |
| --- | --- |
| `+list-windows` | Read-only JSON snapshot (`winghostty.windows.v2`) |
| `+perform-action <action>` | Allowlisted keybind action over single-instance IPC |
| `+new-window` | Open a window; forwards remaining argv |
| `--apply-layout=<name>` | Materialize `%LOCALAPPDATA%\winghostty\layouts\<name>.json` |
| `--working-directory=<path>` | New window/tab cwd |

PowerShell examples:

```powershell
winghostty +list-windows
winghostty +perform-action new_tab
winghostty +perform-action apply_layout:dev
winghostty +perform-action open_elevated_window
winghostty +perform-action toggle_copy_mode
winghostty +perform-action select_hint
```

Rejected on purpose: `text`, `csi`, `esc`, `paste_from_clipboard`,
`write_screen_file`, `crash`. New actions stay denied until
allowlisted.

## Planned (after 1.4 shape is visible)

Stable verbs for open/split/launch-profile/query-state/run-named-layout
that do not invent a second contract next to upstream scriptability.
