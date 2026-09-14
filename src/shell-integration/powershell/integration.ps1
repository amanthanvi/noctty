# Noctty shell integration for PowerShell 5.1+ / pwsh 7+
# Emits OSC 133 (command marking) and OSC 7 (current working directory) sequences.
#
# ── Scope contract ───────────────────────────────────────────────────────
# noctty dot-sources this file from INSIDE a `& { ... }` script block:
#
#   pwsh -NoExit -Command "& { $__ghostty_utf8_console = $false; . '<path>' }"
#
# That block is deliberate, not incidental. The block's child scope is the
# only way to force the per-launch `$__ghostty_utf8_console` decision onto a
# session whose profile already defined a variable of that name: a child
# scope SHADOWS an outer variable even when the outer one is ReadOnly or
# Constant, whereas a plain global assignment fails outright and leaves the
# profile's value in force. See `src/apprt/win32_powershell_install.zig`.
#
# The cost is that the block scope is torn down the moment the dot-source
# returns. Anything defined here that must outlive load — every helper
# function, every variable the prompt interpolates — MUST be written with an
# explicit `global:` / `$Global:` qualifier, or it dies with the block and
# `prompt` throws CommandNotFoundException on its first draw (issue #231).
# `src/apprt/win32_powershell_install.zig` pins that contract in a test.
#
# Corollary: do not introduce unqualified top-level names, and keep globals
# under the `__ghostty_` prefix so this script never clobbers a profile's own
# variables (the unprefixed escape/bell character variables this script used
# to define did exactly that).

# Per-launch UTF-8 console request. noctty sets $__ghostty_utf8_console in the
# scope that dot-sources this script, never in the environment: profiles run
# before our -Command does, so an environment variable would already have been
# inherited by anything a profile spawned. Get-Variable keeps this safe under
# Set-StrictMode when the variable is absent (manual dot-sourcing). -Scope Local
# is explicit so a profile's $PSDefaultParameterValues['Get-Variable:Scope']
# cannot redirect the lookup to a global of the same name: an explicitly passed
# parameter always wins over a default-parameter value.
$ghosttyUtf8Console = Get-Variable -Name '__ghostty_utf8_console' -Scope Local -ValueOnly -ErrorAction SilentlyContinue

if ($ghosttyUtf8Console) {
    try {
        if (([Console]::InputEncoding.CodePage -ne 65001) -or
            ([Console]::OutputEncoding.CodePage -ne 65001)) {
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            [Console]::InputEncoding = $utf8
            [Console]::OutputEncoding = $utf8
        }
    } catch {
        # Keep the rest of shell integration available if the host does not
        # expose mutable console encodings.
    }
}

$Global:__ghostty_esc = [char]27
$Global:__ghostty_bel = [char]7

# ── Reading a possibly-unset global ──────────────────────────────────────
# `Set-StrictMode -Version 2.0` or later turns a read of an undefined
# variable into a terminating error. Both our own state globals and the
# built-in $LASTEXITCODE are legitimately unset at times — on the very first
# prompt draw, and in any session that has not yet run a native executable.
# Under a profile that enables StrictMode, reading them directly killed the
# whole prompt function, so PowerShell fell back to `PS C:\...>` and the
# user's prompt vanished: the #231 symptom, from a different cause.
#
# `Get-Variable -ErrorAction SilentlyContinue` yields $null for an unset name
# instead of throwing, on every StrictMode version. -Scope Global is passed
# explicitly so a profile's $PSDefaultParameterValues['Get-Variable:Scope']
# cannot redirect the lookup: an explicitly passed parameter always wins.
#
# Calling this does NOT disturb $LASTEXITCODE (only native executables and
# scripts write it) but it DOES reset $?, so `prompt` must still capture $?
# as its very first statement.
function global:__ghostty_read_global {
    param([string]$Name)
    return (Get-Variable -Name $Name -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
}

# ── Idempotent guard: save original prompt once ──────────────────────────
if ($null -eq (__ghostty_read_global '__ghostty_aid')) {
    $Global:__ghostty_aid = [string]$PID
}

if ($null -eq (__ghostty_read_global '__ghostty_original_prompt')) {
    $Global:__ghostty_original_prompt = $function:global:prompt
    # Previous-prompt snapshot of $LASTEXITCODE. We compare against this
    # each prompt tick so a stale native exit code from an earlier
    # pipeline can't masquerade as the current command's exit status.
    $Global:__ghostty_prev_exitcode = __ghostty_read_global 'LASTEXITCODE'
}

function global:__ghostty_write_osc {
    param([string]$Sequence)
    try {
        [Console]::Write($Sequence)
    } catch {
        Write-Host -NoNewline $Sequence
    }
}

function global:__ghostty_encode_osc133_value {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return ([uri]::EscapeDataString($Value)).Replace("'", "%27")
}

function global:__ghostty_has_feature {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($env:GHOSTTY_SHELL_FEATURES)) { return $false }
    foreach ($feature in ($env:GHOSTTY_SHELL_FEATURES -split ',')) {
        $feature = $feature.Trim()
        if ($feature -eq $Name) { return $true }
    }
    return $false
}

function global:__ghostty_has_feature_prefix {
    param([string]$Prefix)
    if ([string]::IsNullOrEmpty($env:GHOSTTY_SHELL_FEATURES)) { return $false }
    foreach ($feature in ($env:GHOSTTY_SHELL_FEATURES -split ',')) {
        $feature = $feature.Trim()
        if ($feature.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function global:__ghostty_find_command_application {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { return $cmd.Source }
    }
    return $null
}

function global:__ghostty_find_noctty {
    if (-not [string]::IsNullOrEmpty($env:GHOSTTY_BIN_DIR)) {
        foreach ($name in @('noctty.com', 'noctty.exe', 'noctty')) {
            $candidate = Join-Path $env:GHOSTTY_BIN_DIR $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    return __ghostty_find_command_application @('noctty.com', 'noctty.exe', 'noctty')
}

function global:__ghostty_ssh_cache {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)

    $noctty = __ghostty_find_noctty
    if ($null -eq $noctty) { return $false }

    try {
        & $noctty '+ssh-cache' @Arguments *> $null
        # Read through the helper: if the invocation never reached the
        # executable, $LASTEXITCODE can still be unset and a direct read
        # would be a terminating error under Set-StrictMode.
        return ((__ghostty_read_global 'LASTEXITCODE') -eq 0)
    } catch {
        return $false
    }
}

function global:__ghostty_ssh_target_from_config {
    param([string[]]$ConfigLines)

    $ssh_user = $null
    $ssh_hostname = $null

    foreach ($line in $ConfigLines) {
        if ($line -match '^user\s+(.+)$') {
            $ssh_user = $Matches[1]
        } elseif ($line -match '^hostname\s+(.+)$') {
            $ssh_hostname = $Matches[1]
        }

        if (-not [string]::IsNullOrEmpty($ssh_user) -and -not [string]::IsNullOrEmpty($ssh_hostname)) {
            break
        }
    }

    if ([string]::IsNullOrEmpty($ssh_hostname)) { return $null }

    $target = $ssh_hostname
    if (-not [string]::IsNullOrEmpty($ssh_user)) {
        $target = "$ssh_user@$ssh_hostname"
    }

    return [pscustomobject]@{
        User = $ssh_user
        Hostname = $ssh_hostname
        Target = $target
    }
}

function global:__ghostty_build_ssh_invocation {
    param(
        [string[]]$Arguments,
        [string[]]$ConfigLines,
        [scriptblock]$CacheProbe
    )

    [string[]]$ssh_opts = @()
    $ssh_term = 'xterm-256color'

    if (__ghostty_has_feature 'ssh-env') {
        $ssh_opts += @('-o', 'SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION')
    }

    if (__ghostty_has_feature 'ssh-terminfo') {
        $ssh_target = __ghostty_ssh_target_from_config $ConfigLines
        if ($null -ne $ssh_target -and $null -ne $CacheProbe) {
            $is_cached = $false
            try {
                $is_cached = [bool](& $CacheProbe $ssh_target.Target)
            } catch {
                $is_cached = $false
            }
            if ($is_cached) {
                $ssh_term = 'xterm-ghostty'
            }
        }
    }

    return [pscustomobject]@{
        Term = $ssh_term
        Options = $ssh_opts
        Arguments = $Arguments
    }
}

Remove-Item -Path Function:\ssh,Function:\global:ssh -ErrorAction SilentlyContinue

if (__ghostty_has_feature_prefix 'ssh-') {
    function global:ssh {
        param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)

        $ssh_command = __ghostty_find_command_application @('ssh.exe', 'ssh')
        if ($null -eq $ssh_command) {
            throw 'noctty PowerShell SSH integration could not find ssh'
        }

        [string[]]$ssh_config = @()
        if (__ghostty_has_feature 'ssh-terminfo') {
            try {
                $ssh_config = @(& $ssh_command '-G' @Arguments 2>$null)
            } catch {
                $ssh_config = @()
            }
        }

        $invocation = __ghostty_build_ssh_invocation `
            -Arguments $Arguments `
            -ConfigLines $ssh_config `
            -CacheProbe { param([string]$Target) __ghostty_ssh_cache "--host=$Target" }

        $had_term = Test-Path Env:TERM
        $had_colorterm = Test-Path Env:COLORTERM
        $old_term = $env:TERM
        $old_colorterm = $env:COLORTERM
        $set_colorterm = __ghostty_has_feature 'ssh-env'

        try {
            $env:TERM = $invocation.Term
            if ($set_colorterm) { $env:COLORTERM = 'truecolor' }
            [string[]]$ssh_argv = @($invocation.Options) + @($invocation.Arguments)
            & $ssh_command @ssh_argv
        } finally {
            if ($had_term) { $env:TERM = $old_term } else { Remove-Item Env:TERM -ErrorAction SilentlyContinue }
            if ($had_colorterm) { $env:COLORTERM = $old_colorterm } else { Remove-Item Env:COLORTERM -ErrorAction SilentlyContinue }
        }
    }
}

# ── Helper: build full file:// URI for OSC 7 ────────────────────────────
# Returns the complete URI including `file:` scheme + authority so the
# caller can emit it verbatim. Handles two path shapes:
#
#   * Regular drive path (`C:\Users\amant\project`) →
#     `file://<host>/C:/Users/amant/project` with each segment
#     percent-encoded via EscapeDataString.
#   * UNC path (`\\server\share\dir`) →
#     `file://server/share/dir` (server becomes the authority; the
#     local-host name is omitted per RFC 8089).
#
# Using EscapeDataString PER SEGMENT is critical: EscapeUriString
# preserves URI separators as literals, which produces malformed
# file:// URIs for paths containing `#`, `?`, `%`, `&`, `+`, or
# spaces. For example `C:\Users\amant\project#v1` previously emitted
# `file://HOST/C:/Users/amant/project#v1` where the `#` starts a URL
# fragment in any RFC-compliant parser.
function global:__ghostty_encode_cwd_uri {
    $path = $PWD.Path
    if ($path.StartsWith('\\')) {
        # UNC — split `\\server\share\rest\...`; authority = server,
        # rest goes in the path.
        $rest = $path.Substring(2) -replace '\\', '/'
        $segments = $rest -split '/'
        if ($segments.Length -eq 1) {
            $server = [uri]::EscapeDataString($segments[0])
            return "file://$server/"
        } elseif ($segments.Length -gt 1) {
            $server = [uri]::EscapeDataString($segments[0])
            $tail_segments = $segments[1..($segments.Length-1)]
            $tail = ($tail_segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            return "file://$server/$tail"
        }
        return "file://"
    }
    $host_name = $env:COMPUTERNAME
    $segments = ($path -replace '\\', '/') -split '/'
    $encoded = ($segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    return "file://$host_name/$encoded"
}

# ── Replacement prompt ───────────────────────────────────────────────────
function global:prompt {
    # Capture previous-command status.
    #
    # PowerShell updates $LASTEXITCODE only for native executables and
    # explicit scripts. Cmdlet / function / `throw` failures leave it
    # null or stale while flipping $? to $false. Naively trusting
    # $LASTEXITCODE after a cmdlet failure therefore reports whichever
    # native exit code happened to be lying around from an earlier
    # pipeline — e.g. `cmd /c exit 5; Get-Item missing` would double-
    # emit OSC 133;D;5.
    #
    # The fix is to compare $LASTEXITCODE against the value we snapshot
    # at the END of the previous prompt. If it didn't change, the slot
    # is stale and must be ignored.
    #
    # $? MUST stay the first statement: every later call resets it.
    # Everything after it reads through __ghostty_read_global so a
    # profile's Set-StrictMode cannot turn "no native command has run
    # yet" into a terminating error that costs the user their prompt.
    $ok = $?
    $code = 0
    $original_prompt = $null
    try {
        $original_prompt = __ghostty_read_global '__ghostty_original_prompt'
        $last_exitcode = __ghostty_read_global 'LASTEXITCODE'
        $exit_changed = ($last_exitcode -ne (__ghostty_read_global '__ghostty_prev_exitcode'))
        $code = if (-not $ok) {
            # Cmdlet / script-block / `throw` failure. Honour a fresh
            # native exit code from the same pipeline; otherwise
            # synthesise 1 so OSC 133 D carries the failure signal.
            if ($exit_changed -and $null -ne $last_exitcode -and $last_exitcode -ne 0) {
                $last_exitcode
            } else { 1 }
        } elseif ($exit_changed -and $null -ne $last_exitcode) {
            $last_exitcode
        } else { 0 }
    } catch {
        # Report an unknown status rather than losing the prompt.
        $code = 0
    }

    # Everything terminal-reporting lives inside try/catch, and the user's
    # own prompt is invoked OUTSIDE it. Shell integration is a nice-to-have;
    # the user's prompt is not. If any of our helpers throws, PowerShell
    # discards the whole prompt function and silently substitutes its
    # built-in `PS C:\...>` — which is exactly how #231 presented, and it
    # looks to the user like noctty deleted their starship / oh-my-posh
    # configuration. Degrading to "no OSC marks this tick" is always the
    # better failure. The harness asserts the marks ARE emitted, so this
    # cannot quietly swallow a real regression.
    #
    # Every statement in this function except `$ok = $?` and the delegation
    # itself is inside one of these guards, and the delegation target is
    # resolved inside a guard with a fallback. A throw from the USER's own
    # prompt is deliberately not caught: that is their bug to see.
    try {
        # OSC 133 D — report previous command's exit code
        __ghostty_write_osc "${Global:__ghostty_esc}]133;D;${code};aid=${Global:__ghostty_aid}${Global:__ghostty_bel}"

        # OSC 7 — current working directory (full file:// URI)
        $cwd_uri = __ghostty_encode_cwd_uri
        __ghostty_write_osc "${Global:__ghostty_esc}]7;${cwd_uri}${Global:__ghostty_bel}"

        # OSC 133 A — mark prompt start (jump-to-prompt anchor)
        __ghostty_write_osc "${Global:__ghostty_esc}]133;A;cl=line;aid=${Global:__ghostty_aid}${Global:__ghostty_bel}"
    } catch {
        # Deliberately silent: writing an error here would corrupt the
        # prompt line we are about to draw.
    }

    # Delegate to original prompt. This can internally run native
    # helpers (git-aware prompts are the common case) which overwrite
    # $LASTEXITCODE — so we MUST snapshot AFTER the prompt returns,
    # not before. Taking the snapshot pre-prompt caused the next
    # user-typed cmdlet to inherit the prompt-helper's exit code as
    # its "fresh native" baseline, falsely reporting e.g. `7` for a
    # successful `Get-Date` when the prompt had run `cmd /c exit 7`.
    # Resolved above, inside the guard. If it is somehow gone, emit what
    # PowerShell's own default prompt would have: returning a sane string
    # beats throwing, which costs the user the prompt line AND spills an
    # error into it.
    $out = if ($null -ne $original_prompt) {
        & $original_prompt
    } else {
        "PS $($PWD.Path)> "
    }

    # Re-snapshot AFTER the wrapped prompt completes so the next
    # prompt tick can distinguish "the user's command wrote
    # $LASTEXITCODE" from "the prompt helpers wrote it".
    try {
        $Global:__ghostty_prev_exitcode = __ghostty_read_global 'LASTEXITCODE'
    } catch {
        # See below: never let our bookkeeping eat the user's prompt.
    }

    # OSC 133 B — mark end of prompt / start of user input
    try {
        __ghostty_write_osc "${Global:__ghostty_esc}]133;B${Global:__ghostty_bel}"
    } catch {
        # See above: never let a reporting failure eat the user's prompt.
    }

    return $out
}

# ── OSC 133 C via PSReadLine (pre-execution marker) ─────────────────────
# CommandValidationHandler fires right before the command line is accepted,
# giving us the "command is about to execute" signal.
#
# Caveat: PSReadLine calls this handler only from its ValidateAndAcceptLine
# function. The default Enter binding on both pwsh 7 and Windows PowerShell
# 5.1 is AcceptLine, so unless the user has run
# `Set-PSReadLineKeyHandler -Chord Enter -Function ValidateAndAcceptLine`
# (or uses Emacs edit mode, where Ctrl+M is bound to it) this never fires and
# PowerShell reports no OSC 133 C. Registering it is still worthwhile: it
# costs nothing and works for users who do rebind. Note the handler receives
# one CommandAst PER COMMAND, so a two-command pipeline produces two C marks.
#
# Known gap, not addressed here: this overwrites a CommandValidationHandler
# the user's profile may have installed, without chaining to it.
try {
    if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
        Set-PSReadLineOption -CommandValidationHandler {
            param([string]$line)
            # OSC 133 C — mark start of command output. Include the
            # PSReadLine buffer as URL-encoded metadata so command-finished
            # notifications can show a useful command label when supported.
            $cmdline = __ghostty_encode_osc133_value $line
            __ghostty_write_osc "${Global:__ghostty_esc}]133;C;aid=${Global:__ghostty_aid};cmdline_url=${cmdline}${Global:__ghostty_bel}"
            # Return $true to let the command proceed
            return $true
        }
    }
} catch {
    # PSReadLine unavailable or too old — OSC 133 C is simply skipped.
}
