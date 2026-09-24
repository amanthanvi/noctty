# Shell Integration Code

This is the shell-specific shell-integration code that is
used for the shell-integration feature set that noctty
supports.

This README is meant as developer documentation and not as
user documentation. For user documentation, see the main
README or the public noctty repository documentation

## Implementation Details

### Support matrix

| Shell | Automatic injection | Prompt / cwd marks | `ssh-env` | `ssh-terminfo` |
| --- | --- | --- | --- | --- |
| Bash | Yes, via POSIX `ENV` wrapper | Yes | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `noctty +ssh-cache` |
| Zsh | Yes, via temporary `ZDOTDIR` | Yes | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `noctty +ssh-cache` |
| Fish | Yes, via `XDG_DATA_DIRS` vendor config | Yes | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `noctty +ssh-cache` |
| Nushell | Yes, via `XDG_DATA_DIRS` vendor autoload plus `use ghostty *` | Shell-native where available | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `noctty +ssh-cache` |
| Elvish | Available as distributed module | Shell-native where available | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `noctty +ssh-cache` |
| PowerShell | Yes on Windows for interactive `powershell.exe` / `pwsh.exe` | OSC 7 + OSC 133 | Yes | Cache-aware only: uses `xterm-ghostty` for hosts already present in `noctty +ssh-cache`, otherwise falls back to `xterm-256color` |
| cmd.exe | Yes on Windows for interactive launches via `PROMPT`; `CLINK_PATH` exposes the optional script to active Clink | OSC 9;9 + OSC 133 A/B; active Clink adds OSC 133 C/D | No | No |

### Bash

Automatic [Bash](https://www.gnu.org/software/bash/) shell integration works by
starting Bash in POSIX mode and using the `ENV` environment variable to load
our integration script (`bash/ghostty.bash`). This prevents Bash from loading
its normal startup files, which becomes our script's responsibility (along with
disabling POSIX mode).

Bash shell integration can also be sourced manually from `bash/ghostty.bash`.
This also works for older versions of Bash.

```bash
# noctty shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${GHOSTTY_RESOURCES_DIR}" ]; then
    builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"
fi
```

> [!NOTE]
>
> The version of Bash distributed with macOS (`/bin/bash`) does not support
> automatic shell integration. You'll need to manually source the shell
> integration script (as shown above). You can also install a standard
> version of Bash from Homebrew or elsewhere and set it as your shell.

### Elvish

For [Elvish](https://elv.sh), `$GHOSTTY_RESOURCES_DIR/src/shell-integration`
contains an `./elvish/lib/ghostty-integration.elv` file.

Elvish, on startup, searches for paths defined in `XDG_DATA_DIRS`
variable for `./elvish/lib/*.elv` files and imports them. They are thus
made available for use as modules by way of `use <filename>`.

noctty launches Elvish, passing the environment with `XDG_DATA_DIRS` prepended
with `$GHOSTTY_RESOURCES_DIR/src/shell-integration`. It contains
`./elvish/lib/ghostty-integration.elv`. The user can then import it
by `use ghostty-integration` every time after shell startup or
autostart integration in `$XDG_CONFIG_HOME/elvish/rc.elv`,
which will run the integration routines.

If you decide to autostart `ghostty-integration` with `rc.elv`, you should
detect whether the terminal is noctty or not. To do this, add this to the end
of your `rc.elv` file:

```elvish
if (eq $E:TERM "xterm-ghostty") {
  try { use ghostty-integration } catch { }
}
```

The [Elvish](https://elv.sh) shell integration is supported by
the community and is not officially supported by noctty. We distribute
it for ease of access and use but do not provide support for it.
If you experience issues with the Elvish shell integration, I welcome
any contributions to fix them. Thank you!

### Fish

For [Fish](https://fishshell.com/), noctty prepends to the
`XDG_DATA_DIRS` directory. Fish automatically loads configuration
files in `<XDG_DATA_DIR>/fish/vendor_conf.d/*.fish` on startup,
allowing us to automatically integrate with the shell. For details
on the Fish startup process, see the
[Fish documentation](https://fishshell.com/docs/current/language.html).

### Nushell

For [Nushell](https://www.nushell.sh/), noctty prepends to the
`XDG_DATA_DIRS` directory, making the `ghostty` module available through
Nushell's vendor autoload mechanism. noctty then automatically imports
the module using the `-e "use ghostty *"` flag when starting Nushell.

Nushell provides many shell features itself, such as `title` and `cursor`,
so our integration focuses on noctty-specific features like `sudo`,
`ssh-env`, and `ssh-terminfo`.

The shell integration is automatically enabled when running Nushell in noctty,
but you can also load it manually is shell integration is disabled:

```nushell
source $GHOSTTY_RESOURCES_DIR/shell-integration/nushell/vendor/autoload/ghostty.nu
use ghostty *
```

### Zsh

Automatic [Zsh](https://www.zsh.org/) integration works by temporarily setting
`ZDOTDIR` to our `zsh` directory. An existing `ZDOTDIR` environment variable
value will be retained and restored after our shell integration scripts are
run.

However, if `ZDOTDIR` is set in a system-wide file like `/etc/zshenv`, it will
override noctty's `ZDOTDIR` value, preventing the shell integration from being
loaded. In this case, the shell integration needs to be loaded manually.

To load the Zsh shell integration manually:

```zsh
if [[ -n $GHOSTTY_RESOURCES_DIR ]]; then
  source "$GHOSTTY_RESOURCES_DIR"/shell-integration/zsh/ghostty-integration
fi
```

Shell integration requires Zsh 5.1+.

### PowerShell

Automatic PowerShell integration on Windows applies to both Windows
PowerShell 5.1 (`powershell.exe`) and PowerShell 7+ (`pwsh.exe`).
Interactive launches are wrapped by appending `-NoExit -Command "& {
$__ghostty_utf8_console = $true|$false; . '<path>' }"` while preserving the
existing prefix flags such as `-NoProfile`, `-ExecutionPolicy`, or
`-WorkingDirectory`.

The `& { ... }` block is load-bearing: its child scope is what lets the
per-launch `$__ghostty_utf8_console` decision shadow a same-named variable a
profile may have declared `ReadOnly` or `Constant`, which a plain global
assignment cannot overwrite. The price is that the block scope dies with the
dot-source, so every top-level name in `integration.ps1` that must outlive
load carries an explicit `global:` / `$Global:` qualifier. A compile-time test
in `src/apprt/win32_powershell_install.zig` enforces that.

Explicit command / script entrypoints such as `-Command`,
`-CommandWithArgs`, `-EncodedCommand`, `-File`, help/version flags, and
`-NonInteractive` are intentionally left untouched because appending our
own `-Command` would change exit behavior or corrupt the user payload.

For the manual fallback, the Win32 runtime also installs a copy of
`integration.ps1` to
`%LOCALAPPDATA%\noctty\shell-integration\powershell\integration.ps1`
so users can source it from `$PROFILE` if automatic injection is
disabled or the command shape is unsupported.

The PowerShell script emits OSC 7 as a full `file://` URI with each path
segment percent-encoded, and OSC 133 A / B / D prompt marks with a stable
`aid=$PID`, around whatever `prompt` the profile installed. D, OSC 7 and
`A;redraw=0` are written while the prompt function runs, so anything the
user's prompt writes itself lands after A. B is written by the line reader
(below), after the host has drawn the prompt and before PSReadLine starts, so
it lands where input begins whatever the prompt returned, and the returned
string stays exactly the user's: a transcript, including one the "Turn on
PowerShell Transcription" group policy starts, records the prompt without it.
A B written from inside the prompt function would land ahead of the visible
prompt, because the host draws the returned string only after the function
returns, and the prompt's cells would be taken for input. Two cases have no
line read after the host's draw, and there the prompt appends B to its own
string: a PSReadLine repaint (Ctrl+L, a transient prompt), which is not
transcribed, and a session without PSReadLine, whose transcript does record
it.

The prompt hook is a generated `function prompt` of one line: it captures
`$?` and calls `__ghostty_prompt_body` with the id of the prompt it wraps. The
id is part of the function's text, so a copy of it (a venv's `Activate.ps1`
saving the prompt with `Copy-Item`, a profile chaining to `$function:prompt` or
`(Get-Command prompt).ScriptBlock`) still wraps the same prompt, and a copy
called from inside a newer wrapper passes straight through without a second
set of marks. A prompt replaced after startup (`. $PROFILE`, an oh-my-posh or
Starship re-init, a venv) is wrapped again by the line reader before the next
line is read. The one prompt drawn before that, by the user's own function,
gets its marks from the line reader instead: OSC 7 and `133;P;k=i;redraw=0`
in place of its missing A (P does not fresh-line, so the cursor stays where
the prompt ended), then B. A `ReadOnly` prompt, which cannot be wrapped, gets
the same on every line. What that prompt still lacks is its D, which would
have closed the command that replaced the prompt: that command's
command-finished notification and exit status are lost (the next C restarts
the command timer, so nothing else is thrown off). Its text also arrives
before any prompt mark, so the terminal records it as the previous command's
output, and copying the output of the next command returns that prompt text.
(For a venv that one prompt is `(venv) ` followed by the saved copy of our
wrapper, so its marks land after `(venv) ` instead of before it.) All of this
needs PSReadLine; without it a replaced prompt stays unwrapped, as before.

Hooking `prompt` through a global alias instead, which PowerShell resolves
before a function of the same name, would catch that one prompt too. It was
tried and measured, and it costs more than it saves: `Get-Command prompt` then
returns the alias, whose missing `ScriptBlock` breaks a profile that chains to
the prompt that way on every later `. $PROFILE`, and PSReadLine then sees the
user's own prompt, derives a `PromptText` such as `> ` from a plain prompt like
PowerShell's default, and repaints it after the B mark on every parse error, so
the terminal takes those cells for input.

The line reader is hooked through a global alias, `PSConsoleHostReadLine` ->
`__ghostty_readline`. The console host reads each line by running that
command, but only when a function (or cmdlet) of that name exists, which
PSReadLine defines. The alias wraps whatever function is current: PSReadLine's
own, a profile's wrapper of it, or a re-imported PSReadLine's; without
PSReadLine the host reads the line itself and the alias is idle.

The command-start mark (OSC 133 C, with URL-encoded `cmdline_url` metadata)
goes out when the host's line reader returns an accepted line, just before the
host runs it: once per line, including a line equal to the previous history
entry, and never for lines PSReadLine 2.0.x replays from the history file. An
empty or whitespace-only line gets no C, as with the clink, zsh and bash
integrations, so it does not replace the command that `insert_last_command`
and copying the last command output work on. The host only calls
`PSConsoleHostReadLine` when PSReadLine (or a profile) defines that function,
so without PSReadLine there is no C and nothing else changes.

Earlier versions hung C off PSReadLine's `AddToHistoryHandler`, which
PSReadLine skips for a line equal to the previous history entry under the
default `HistoryNoDuplicates`, and for whitespace-only lines, so running the
same command twice got no C the second time. noctty no longer touches the
`AddToHistoryHandler` at all: the user's handler, and PSReadLine's default one
that keeps credential-shaped lines out of the history file, stay exactly as
they were. Loading the script into a session that already ran an older copy
puts back the prompt function and history handler that copy replaced.

Both wrappers hand `$?` on: the user's prompt sees the status their command
left, which Starship and oh-my-posh read for their error indicator (under the
old wrapper it always read `True`), and PSReadLine's `PSConsoleHostReadLine`
gets the same value it passes to predictors. Nothing the script installs asks
for confirmation or honours `-WhatIf`, so a profile's `$ConfirmPreference` or
`$WhatIfPreference` cannot stop the launch or disable the hooks.

The C mark's `cmdline_url` label is left off when it would not fit the
terminal's 2048-byte OSC buffer, which drops a longer mark whole.

Side effects and edge cases of the line-reader alias, measured on both
hosts:

- When PSReadLine repaints a prompt that returns more than one object, or a
  non-string, B is written directly, before its text: PSReadLine's
  `InvokePrompt` (Ctrl+L, transient prompts) draws `PS>` for a prompt that
  returns several objects, so a B appended to the first one would be lost.
  Prompts the host draws get B from the line reader, after their text.
- `PSConsoleHostReadLine` is a global alias, so `Get-Command
  PSConsoleHostReadLine` reports the alias, and `Export-Alias -As Script` or
  `Import-Alias -Force` can copy it into a profile. A session without this
  script that loads such a profile cannot resolve the alias's target, and the
  host silently falls back to its own line reader, without PSReadLine. Remove
  the `PSConsoleHostReadLine` line from an exported alias file.
- If the user already has an alias named `PSConsoleHostReadLine`, it is left
  alone, no C marks are emitted, and B rides in the prompt string as it does
  without PSReadLine.
- A `ReadOnly` or `Constant` prompt function cannot be wrapped and is left as
  it is. It gets OSC 7, P and B from the line reader, but no D.
- The user's prompt runs inside the wrapper, so it can read the wrapper's
  local variables through PowerShell's dynamic scoping, as it could before.

The `ssh` wrapper below is installed only when an `ssh-*` feature is enabled,
and only a wrapper this script installed is ever removed — a `function ssh`
defined in the user's `$PROFILE` (which runs before noctty's injected
`-Command`) is left alone.

The exit code carried by OSC 133 D is derived without ever writing to
`$LASTEXITCODE`, which users read. PowerShell only updates that variable for
native executables and scripts and never clears it, while `$?` goes false for
any failure, so the prompt combines three readings taken at the top of each
draw: `$?`, `$LASTEXITCODE` against the value snapshotted when the previous
line was accepted (at the end of the previous draw without PSReadLine), and
the head of `$Error` against its own snapshot.

When `$?` is true, a changed `$LASTEXITCODE` is reported and an unchanged one
means `0`. When `$?` is false and `$LASTEXITCODE` changed to a nonzero value,
the new code is reported. When `$?` is false and `$LASTEXITCODE` either did
not change or changed to `0`, `$Error` decides: a new record that is not native-sourced means a cmdlet, script,
`throw` or `Write-Error` failure and the mark is `1`, while no new record
means the native command failed again with the same code and that code is
reported. A failure with no nonzero code to report anywhere is marked `1`.

"Native-sourced" is decided by `FullyQualifiedErrorId`:
`ProgramExitedWithNonZeroCode` (a nonzero exit under
`$PSNativeCommandUseErrorActionPreference` on PowerShell 7.4+),
`NativeCommandError` / `NativeCommandErrorMessage` / `NativeCommandFailed`
(Windows PowerShell 5.1 turning a native command's redirected stderr into a
record). Deliberately not by exception type: the 5.1 stderr record's exception
is a `RemoteException`, which is also what every failure deserialized out of a
job or a remote session carries. Entries that are not `ErrorRecord`s are
unwrapped one level through `.ErrorRecord` first, because
`$ErrorActionPreference = 'Stop'` pushes an `ActionPreferenceStopException`
ahead of the record it stopped on.

Known limits, all measured on both hosts. Where the mark is wrong it is wrong
in the direction of repeating the previous command's real exit code, so it
still reads as a failure:

- A command silenced with `-ErrorAction Ignore` records nothing anywhere, so
  it is reported with the stale native code rather than `1`.
- PowerShell does not reset `$?` for an empty command line, so pressing Enter
  after a failed native command re-reports its code. No C precedes that D, so
  the terminal attaches it to no command.
- Ctrl-C at the prompt is not distinguished from the previous failure, with
  the same effect.
- A line that does not parse leaves `$?` true, so it is recognised by a new
  bare `ParseException` at the head of `$Error` and marked `1`.
- `$?` does not propagate out of a function, `& { }`, `. { }` or
  `Invoke-Expression`, and Windows PowerShell 5.1 leaves it true for a parse
  error, so `function f { cmd /c exit 5 }; f` marks `0`. These take the
  `$?`-true path, where `$Error` is not consulted at all.

When `GHOSTTY_SHELL_FEATURES` contains `ssh-env` or `ssh-terminfo`, PowerShell
wraps `ssh` and runs the remote session with `TERM=xterm-256color` by default.
`ssh-env` also sends `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION`
and sets `COLORTERM=truecolor` for the SSH process. When `ssh-terminfo` is
enabled, the wrapper checks `noctty +ssh-cache` for the resolved
`user@hostname` from `ssh -G`; cached hosts use `TERM=xterm-ghostty`.

PowerShell intentionally does not auto-install remote terminfo. The POSIX
scripts can pipe `infocmp` through SSH and reuse a control socket for the final
connection. On Windows PowerShell that path is not portable enough to run
silently, so uncached hosts remain on `xterm-256color` until the terminfo is
installed by another shell integration path or manually added to the SSH cache.

Interactive `cmd.exe` launches are auto-integrated by wrapping the inherited
`PROMPT` (or cmd's `$P$G` default) with OSC 133 A/B prompt marks and OSC 9;9 cwd
reports. When Clink is detected, noctty prepends the shipped cmd Lua directory
to `CLINK_PATH`, but does not activate Clink. An already-active Clink discovers
the script and adds OSC 133 C/D command boundaries; without it, prompt/cwd marks
remain available. See [windows.md](../../docs/windows.md#shells) for configured
`PROMPT` precedence and Clink exit-code details.

### SSH terminfo cache

When `shell-integration-features` includes `ssh-terminfo`, the Bash integration
wraps `ssh` to install the `xterm-ghostty` terminfo entry on remote hosts using
local `infocmp` plus remote `tic`. Successful installs are cached through
`noctty +ssh-cache`, preferring `$GHOSTTY_BIN_DIR/noctty` and falling
back to a `noctty` found on `PATH`. If the cache helper is unavailable, SSH
still attempts installation but may repeat it on later connections.
