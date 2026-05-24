# Shell Integration Code

This is the shell-specific shell-integration code that is
used for the shell-integration feature set that winghostty
supports.

This README is meant as developer documentation and not as
user documentation. For user documentation, see the main
README or the public winghostty repository documentation

## Implementation Details

### Support matrix

| Shell | Automatic injection | Prompt / cwd marks | `ssh-env` | `ssh-terminfo` |
| --- | --- | --- | --- | --- |
| Bash | Yes, via POSIX `ENV` wrapper | Yes | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `winghostty +ssh-cache` |
| Zsh | Yes, via temporary `ZDOTDIR` | Yes | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `winghostty +ssh-cache` |
| Fish | Yes, via `XDG_DATA_DIRS` vendor config | Yes | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `winghostty +ssh-cache` |
| Nushell | Yes, via `XDG_DATA_DIRS` vendor autoload plus `use ghostty *` | Shell-native where available | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `winghostty +ssh-cache` |
| Elvish | Available as distributed module | Shell-native where available | Yes | Installs remote `xterm-ghostty` terminfo with local `infocmp`, remote `tic`, and `winghostty +ssh-cache` |
| PowerShell | Yes on Windows for interactive `powershell.exe` / `pwsh.exe` | OSC 7 + OSC 133 | Yes | Cache-aware only: uses `xterm-ghostty` for hosts already present in `winghostty +ssh-cache`, otherwise falls back to `xterm-256color` |
| cmd.exe | No | No | No | No |

### Bash

Automatic [Bash](https://www.gnu.org/software/bash/) shell integration works by
starting Bash in POSIX mode and using the `ENV` environment variable to load
our integration script (`bash/ghostty.bash`). This prevents Bash from loading
its normal startup files, which becomes our script's responsibility (along with
disabling POSIX mode).

Bash shell integration can also be sourced manually from `bash/ghostty.bash`.
This also works for older versions of Bash.

```bash
# winghostty shell integration for Bash. This must be at the top of your bashrc!
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

winghostty launches Elvish, passing the environment with `XDG_DATA_DIRS` prepended
with `$GHOSTTY_RESOURCES_DIR/src/shell-integration`. It contains
`./elvish/lib/ghostty-integration.elv`. The user can then import it
by `use ghostty-integration` every time after shell startup or
autostart integration in `$XDG_CONFIG_HOME/elvish/rc.elv`,
which will run the integration routines.

If you decide to autostart `ghostty-integration` with `rc.elv`, you should
detect whether the terminal is winghostty or not. To do this, add this to the end
of your `rc.elv` file:

```elvish
if (eq $E:TERM "xterm-ghostty") {
  try { use ghostty-integration } catch { }
}
```

The [Elvish](https://elv.sh) shell integration is supported by
the community and is not officially supported by winghostty. We distribute
it for ease of access and use but do not provide support for it.
If you experience issues with the Elvish shell integration, I welcome
any contributions to fix them. Thank you!

### Fish

For [Fish](https://fishshell.com/), winghostty prepends to the
`XDG_DATA_DIRS` directory. Fish automatically loads configuration
files in `<XDG_DATA_DIR>/fish/vendor_conf.d/*.fish` on startup,
allowing us to automatically integrate with the shell. For details
on the Fish startup process, see the
[Fish documentation](https://fishshell.com/docs/current/language.html).

### Nushell

For [Nushell](https://www.nushell.sh/), winghostty prepends to the
`XDG_DATA_DIRS` directory, making the `ghostty` module available through
Nushell's vendor autoload mechanism. winghostty then automatically imports
the module using the `-e "use ghostty *"` flag when starting Nushell.

Nushell provides many shell features itself, such as `title` and `cursor`,
so our integration focuses on winghostty-specific features like `sudo`,
`ssh-env`, and `ssh-terminfo`.

The shell integration is automatically enabled when running Nushell in winghostty,
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
override winghostty's `ZDOTDIR` value, preventing the shell integration from being
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
. '<path>' }"` while preserving the existing prefix flags such as
`-NoProfile`, `-ExecutionPolicy`, or `-WorkingDirectory`.

Explicit command / script entrypoints such as `-Command`,
`-CommandWithArgs`, `-EncodedCommand`, `-File`, help/version flags, and
`-NonInteractive` are intentionally left untouched because appending our
own `-Command` would change exit behavior or corrupt the user payload.

For the manual fallback, the Win32 runtime also installs a copy of
`integration.ps1` to
`%LOCALAPPDATA%\winghostty\shell-integration\powershell\integration.ps1`
so users can source it from `$PROFILE` if automatic injection is
disabled or the command shape is unsupported.

The PowerShell script emits OSC 7 as a full `file://` URI with each path
segment percent-encoded. It also emits OSC 133 prompt marks with a stable
`aid=$PID` and, when PSReadLine exposes the accepted buffer, URL-encoded
`cmdline_url` metadata on the command-start mark.

When `GHOSTTY_SHELL_FEATURES` contains `ssh-env` or `ssh-terminfo`, PowerShell
wraps `ssh` and runs the remote session with `TERM=xterm-256color` by default.
`ssh-env` also sends `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION`
and sets `COLORTERM=truecolor` for the SSH process. When `ssh-terminfo` is
enabled, the wrapper checks `winghostty +ssh-cache` for the resolved
`user@hostname` from `ssh -G`; cached hosts use `TERM=xterm-ghostty`.

PowerShell intentionally does not auto-install remote terminfo. The POSIX
scripts can pipe `infocmp` through SSH and reuse a control socket for the final
connection. On Windows PowerShell that path is not portable enough to run
silently, so uncached hosts remain on `xterm-256color` until the terminfo is
installed by another shell integration path or manually added to the SSH cache.

`cmd.exe` is intentionally not auto-integrated. Command Prompt has no reliable
prompt/pre-exec hook equivalent, so the Windows profile picker surfaces it as a
plain fallback shell without OSC 7 cwd tracking, prompt marks, or command-finish
notifications.

### SSH terminfo cache

When `shell-integration-features` includes `ssh-terminfo`, the Bash integration
wraps `ssh` to install the `xterm-ghostty` terminfo entry on remote hosts using
local `infocmp` plus remote `tic`. Successful installs are cached through
`winghostty +ssh-cache`, preferring `$GHOSTTY_BIN_DIR/winghostty` and falling
back to a `winghostty` found on `PATH`. If the cache helper is unavailable, SSH
still attempts installation but may repeat it on later connections.
