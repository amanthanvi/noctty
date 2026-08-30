# Automation

noctty exposes a local, current-user command-line automation surface over
the running Windows instance. It provides versioned JSON state, explicit
targets, and stable exit codes for PowerShell and other scripts.

## PowerShell quick start

```powershell
noctty +list-windows | ConvertFrom-Json

$state = noctty +list-windows --class=work | ConvertFrom-Json
$pane = $state.windows[0].tabs[0].panes[0]
noctty +focus --class=work --surface-id=$($pane.surface_id)
noctty +send-text --class=work --surface-id=$($pane.surface_id) 'git status'
```

`+send-text` does not append Enter. Check `$LASTEXITCODE` after a command
when failure handling matters.

## Verbs

Every verb accepts `--class=<name>` and `--timeout=<ms>`. The class selects
an instance namespace. The timeout is only the response timeout, accepts
`0..10000`, and defaults to `10000` milliseconds; it does not extend the
server's fixed 10-second wait or change connection and wire I/O limits.

| Verb | Target and arguments | Exit codes |
| --- | --- | --- |
| `+new-window` | No target. Existing forwarded window arguments remain subject to the receiver policy described below. | 0, 1, 5 |
| `+list-windows` | `--format=json`; JSON is the default and only accepted format. | 0, 1, 2, 5 |
| `+perform-action` | Optional `--surface-id=<id>` and exactly one action string. Omission targets the focused surface for surface-scoped actions or the app for app-scoped actions. | 0, 1, 2, 3, 4, 5 |
| `+new-tab` | Optional `--window-id=<id>` (default: focused window) and optional `--working-directory=<dir>`. | 0, 1, 2, 3, 4, 5 |
| `+new-split` | Optional `--surface-id=<id>` (default: focused pane), optional `--direction=left\|right\|up\|down` (default: `right`), and optional `--working-directory=<dir>`. | 0, 1, 2, 3, 4, 5 |
| `+focus` | Exactly one required `--surface-id=<id>` or `--window-id=<id>`. Foreground activation is best-effort under Windows foreground-lock rules. | 0, 1, 2, 3, 5 |
| `+send-text` | Required `--surface-id=<id>` and exactly one text argument. | 0, 1, 2, 3, 4, 5 |

Explicit IDs are opaque, nonzero decimal unsigned integers. Window IDs must
fit `u32`; surface IDs must fit `u64`. An unknown ID in a live instance is a
target-not-found failure, never a request to use the focused target.

`--working-directory` is the only launch override. Accepted values are
`home`, `inherit`, `~`, paths beginning `~/` or `~\`, and local drive-letter
absolute paths such as `C:\src`. Relative, drive-relative, and UNC/device
paths such as `\\host\share`, `//host/share`, `\\?\`, and `\\.\` are
refused. `+new-tab` and `+new-split` inherit the source pane's command; no
verb can choose a program to run. There is no `-e`, `--command`, or `--title`
override for those verbs.

## JSON schema v3

`+list-windows` always emits one JSON document with this shape:

```json
{
  "schema": "noctty.windows.v3",
  "api_version": 3,
  "instance": {
    "pid": 1234,
    "version": "1.3.123",
    "class": "work"
  },
  "windows": [
    {
      "window_id": 17,
      "title": "PowerShell",
      "focused": true,
      "active_tab_id": 4,
      "tab_count": 1,
      "pane_count": 1,
      "tabs": [
        {
          "tab_id": 4,
          "active": true,
          "focused_surface_id": 702,
          "pane_count": 1,
          "panes": [
            {
              "surface_id": 702,
              "title": null,
              "working_directory": null,
              "focused": true,
              "active": true
            }
          ]
        }
      ]
    }
  ]
}
```

- `instance.pid` is the running noctty process ID, `instance.version` is its
  build version, and `instance.class` is the effective sanitized pipe
  namespace captured when the server starts. That class can be passed back
  to `--class`.
- `window.title` is the cached host caption. It is non-null, although it can
  be empty; the read-only query never changes the native window to refresh it.
- Window, tab, and surface IDs are the opaque targets used by the verbs.
  Counts match the corresponding arrays; `window.focused` reports host focus.
- `active_tab_id` and `focused_surface_id` are nullable IDs. `active` marks
  the active tab and the globally active pane; pane `focused` is tab-local.
- Pane `title` is nullable and uses runtime precedence: tab override, surface
  override, then terminal title. It is `null` before any title exists.
- Pane `working_directory` is the last-known cwd, seeded from the launch cwd
  and refreshed by OSC 7. It is `null` when unknown.
- Nullable fields are emitted as JSON `null`, never omitted. Retained hosts
  with no tabs are omitted from `windows`.

Pane-level child PIDs are deliberately not exposed: they are not available
on the app thread, and the direct ConPTY child is often a wrapper on Windows.

Scripts should check both `schema` and `api_version`. Field names,
nullability, and semantics are stable within v3; an incompatible change will
use a new schema suffix and API version. JSON is the sole output contract;
there is no text format.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Usage or argument error. |
| 2 | No matching running instance. |
| 3 | Live instance, but the requested target was not found. |
| 4 | Refused by automation policy. |
| 5 | IPC transport failure or response timeout; for `+new-window`, also fallback process-launch failure. |

`+new-window` retains its process-launch fallback and therefore never returns
2. New verbs used against an older server that does not know their request
kinds fail generically with 5; there is no capability negotiation.

## Automation policy

For `+perform-action`, “safe” means allowed by automation policy, not
harmless. Allowed actions can include destructive UI operations such as
reset, close, quit, undo, and redo. Unknown action variants and actions that
inject terminal input, read arbitrary files, or select code to run are
denied until explicitly reviewed; a policy denial returns 4.

`+send-text` accepts non-empty valid UTF-8 up to 16 KiB. It refuses every
Unicode `Cc` control character, including NUL, TAB, CR, LF, ESC, DEL, and C1
controls, and also applies noctty's unsafe-paste inspection. Refused control
text returns 4 and never reaches IPC; malformed or oversized input is a usage
error. Printable shell metacharacters and mixed printable content remain
allowed.

Delivery uses the protected paste path. Automation cannot transmit Enter,
newline, or control input and never raises a paste-confirm prompt. This is a
narrow guarantee: printable text can still affect a TUI or a pending
confirmation prompt. There is no raw or bypass mode.

## Trust and privacy

The channel protections land in PR #185, and this automation work depends on
that PR merging first. They are a current-user DACL,
`PIPE_REJECT_REMOTE_CLIENTS`, a `NO_WRITE_UP` mandatory-integrity label when
elevated, and a deny-by-default allowlist for forwarded `+new-window`
arguments. This work does not duplicate or widen those protections.

The pipe is not a privilege boundary against code already running as your
user. No verb can select a program to run. `--working-directory` is the only
launch override and is restricted to the local, non-UNC forms documented
above; receiver-side validation prevents a direct pipe client from bypassing
that policy.

Terminal grid text, scrollback, selection, clipboard contents, and pending
shell input are never included in the JSON payload. noctty intentionally
exposes this metadata over a local, current-user automation channel.

Wire request kind 8 is reserved for the planned `launch_layout` work in issue
#133. There is no `+launch-layout` verb today.
