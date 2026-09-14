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
# parameter always wins over a default-parameter value. -ErrorAction Ignore,
# not SilentlyContinue: both suppress the message, but SilentlyContinue still
# APPENDS the ItemNotFoundException to $Error, so a manual dot-source (where
# the launch variable is legitimately absent) left a record at the top of the
# user's error history. Measured on pwsh 7.6.6 and Windows PowerShell
# 5.1.26100: Ignore leaves $Error.Count at 0 and still yields $null under
# Set-StrictMode -Version Latest.
$ghosttyUtf8Console = Get-Variable -Name '__ghostty_utf8_console' -Scope Local -ValueOnly -ErrorAction Ignore

if ($ghosttyUtf8Console) {
    try {
        if (([Console]::InputEncoding.CodePage -ne 65001) -or
            ([Console]::OutputEncoding.CodePage -ne 65001)) {
            # `ghostty`-prefixed because this sits at the script's own
            # (block) scope, not inside a function: the scope guard in
            # win32_powershell_install.zig allows exactly the load-time
            # locals it knows are consumed before the dot-source returns.
            $ghosttyUtf8Encoding = [System.Text.UTF8Encoding]::new($false)
            [Console]::InputEncoding = $ghosttyUtf8Encoding
            [Console]::OutputEncoding = $ghosttyUtf8Encoding
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
# `Get-Variable -ErrorAction Ignore` yields $null for an unset name instead
# of throwing, on every StrictMode version. Ignore rather than
# SilentlyContinue: the latter suppresses the message but still appends the
# ItemNotFoundException to $Error, and this helper runs several times per
# prompt draw, so a session that had not yet run a native executable
# accumulated a $LASTEXITCODE lookup record per tick. -Scope Global is passed
# explicitly so a profile's $PSDefaultParameterValues['Get-Variable:Scope']
# cannot redirect the lookup: an explicitly passed parameter always wins.
#
# Calling this does NOT disturb $LASTEXITCODE (only native executables and
# scripts write it) but it DOES reset $?, so `prompt` must still capture $?
# as its very first statement.
function global:__ghostty_read_global {
    param([string]$Name)
    return (Get-Variable -Name $Name -Scope Global -ValueOnly -ErrorAction Ignore)
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
        # Ignore, not SilentlyContinue: a miss here is the normal case while
        # walking the candidate list and must not land in the user's $Error.
        $cmd = Get-Command $name -CommandType Application -ErrorAction Ignore | Select-Object -First 1
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

# ── ssh wrapper: install ours, never touch the user's ─────────────────
# This used to be an unconditional
# `Remove-Item -Path Function:\ssh,Function:\global:ssh -ErrorAction SilentlyContinue`
# placed AHEAD of the feature check. Two defects, both measured on pwsh
# 7.6.6 and Windows PowerShell 5.1.26100:
#
#   * It ran on every launch, before we knew whether we were going to
#     install anything at all. A `function ssh { ... }` defined in the
#     user's $PROFILE — which runs BEFORE noctty's injected `-Command` —
#     was therefore deleted even when GHOSTTY_SHELL_FEATURES carried no
#     `ssh-*` feature and nothing replaced it.
#   * `Function:\global:ssh` is not a valid provider path: a scope
#     qualifier belongs on the NAME (`$function:global:ssh`), not inside a
#     Function: drive path. It raised ItemNotFoundException on every
#     launch, and `-ErrorAction SilentlyContinue` suppresses the message
#     but still appends the record to `$Error` — measured `$Error.Count`
#     0 before the line and 2 after it on both hosts, so every session
#     opened with two bogus entries at the top of the user's error history.
#
# So: remove only a wrapper THIS script installed. `__ghostty_ssh_wrapper_installed`
# cannot be set on a first load, which is what makes this a re-source-only
# operation, and the marker in the body distinguishes our wrapper from an
# `ssh` the user defined after we set the flag. Existence is probed with
# Get-Command rather than inferred from Remove-Item's own error, and the
# path is the valid `Function:\ssh`.
function global:__ghostty_ssh_wrapper_is_ours {
    if (-not (__ghostty_read_global '__ghostty_ssh_wrapper_installed')) { return $false }
    $existing = Get-Command -Name 'ssh' -CommandType Function -ErrorAction Ignore |
        Select-Object -First 1
    if ($null -eq $existing) { return $false }
    return ([string]$existing.ScriptBlock).Contains('__ghostty_ssh_wrapper_marker')
}

if (__ghostty_ssh_wrapper_is_ours) {
    Remove-Item -LiteralPath 'Function:\ssh' -Force -ErrorAction Ignore
    $Global:__ghostty_ssh_wrapper_installed = $false
}

if (__ghostty_has_feature_prefix 'ssh-') {
    function global:ssh {
        # __ghostty_ssh_wrapper_marker — `__ghostty_ssh_wrapper_is_ours`
        # looks for this exact string in the installed function's body, so
        # a re-source replaces our own wrapper and leaves any user-defined
        # `ssh` untouched. Do not remove or rename it.
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

    $Global:__ghostty_ssh_wrapper_installed = $true
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

# ── OSC 133 C via PSReadLine's AddToHistoryHandler ────────────────────
# This hung off `Set-PSReadLineOption -CommandValidationHandler` until it was
# measured. PSReadLine invokes CommandValidationHandler from exactly one
# place, its `ValidateAndAcceptLine` function, and the default Enter binding
# on both pwsh 7 and Windows PowerShell 5.1 is `AcceptLine` — so unless the
# user had rebound Enter, PowerShell emitted no OSC 133 C at all and every
# feature that needs a C mark was dead. It also replaced, without chaining
# to, whatever CommandValidationHandler the user's profile had installed.
#
# `AddToHistoryHandler` is the hook PSReadLine runs for every accepted line
# regardless of which accept function Enter is bound to, and it runs BEFORE
# the host executes the line, which is exactly the OSC 133 C contract. Two
# properties of that contract shape the code below:
#
#   * A handler is ALWAYS already installed. PSReadLine 2.4.5 (pwsh 7) and
#     2.0.0 (Windows PowerShell 5.1) both ship a default one: the sensitive-
#     history scrubber that returns `MemoryOnly` for a line that looks like
#     it carries a secret, and `MemoryAndFile` otherwise. Overwriting it
#     without chaining would silently start writing the user's secrets to
#     their history file. We therefore capture whatever is in force, call
#     it, and return ITS result unchanged — bool on an old custom handler,
#     `[Microsoft.PowerShell.AddToHistoryOption]` on the shipped ones (that
#     enum exists on both hosts, including PSReadLine 2.0.0).
#   * The option is typed `Func[string, object]`, not `[scriptblock]`.
#     PowerShell converts our scriptblock at parameter-bind time, so reading
#     the option back yields a delegate whose `ToString()` is just
#     `System.Func`2[System.String,System.Object]` and whose `Target` is a
#     compiler-generated `Closure` holding only `Constants` / `Locals`
#     arrays. There is no script text left to carry a marker, so "is the
#     installed handler ours?" is answered by reference equality against the
#     delegate we read back after installing — measured stable across reads
#     on both hosts. That is what keeps a re-source idempotent: we rebind to
#     the saved original instead of chaining to ourselves and emitting
#     133;C twice per line.
#
#   * PSReadLine 2.0.0 (Windows PowerShell 5.1) calls the handler for every
#     line it REPLAYS from the on-disk history file as well as for lines the
#     user accepts. Measured on a fresh 5.1 session against the real shared
#     `ConsoleHost_history.txt`: 1790 handler invocations before a single key
#     was pressed, matching the file line for line, plus further invocations
#     for lines appended by other live sessions. pwsh 7 / 2.4.5 does not do
#     this. Emitting 133;C for each of those would be a storm of bogus command
#     marks at startup, so `__ghostty_line_is_being_accepted` gates the
#     emission (the chained handler is still called every time -- suppressing
#     the terminal report must not change the history decision).
#
# The handler's return value has to stay a SCALAR. A scriptblock-derived
# `Func[string, object]` returns the block's whole output collection, so one
# stray value on the pipeline turns a `$true` into an `object[]` that
# PSReadLine cannot interpret and silently treats as the default. Every
# statement here is an assignment or a void call for that reason.
# Is PSReadLine handing us the line the user just accepted, or one it is
# replaying out of the history file?
#
# Measured on pwsh 7 / PSReadLine 2.4.5 and Windows PowerShell 5.1 /
# PSReadLine 2.0.0, from inside the handler:
#
#   replay  → GetBufferState yields "" (empty string, not $null), cursor 0
#   accept  → GetBufferState yields the accepted text, cursor == its length,
#             including embedded newlines for a multi-line block
#
# EQUALITY, not "buffer is non-empty": when another live session appends to
# the shared history file, 5.1 replays that foreign line while the user is
# sitting at a prompt with text in the buffer, so a `cursor -gt 0` test emits
# a second, wrong 133;C for it. Ordinal `-ceq` against the line we were handed
# rejects that. (Residual: a foreign line byte-identical to what the user just
# typed still emits once extra. Rare and harmless.)
#
# Fails CLOSED. If a future PSReadLine drops GetBufferState the cost is a
# missing mark, never a storm of them.
function global:__ghostty_line_is_being_accepted {
    param([AllowNull()][string]$Line)
    # PSReadLine short-circuits whitespace-only lines to SkipAdding before it
    # ever calls the handler, so this only pins the shape: an empty line must
    # never match an empty replay buffer.
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    $buffer = $null
    $cursor = 0
    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$buffer, [ref]$cursor)
    } catch {
        return $false
    }
    return ($buffer -ceq $Line)
}

function global:__ghostty_add_to_history {
    param([AllowNull()][string]$Line)

    try {
        if (__ghostty_line_is_being_accepted $Line) {
            # OSC 133 C — mark start of command output. Include the accepted
            # line as URL-encoded metadata so command-finished notifications
            # can show a useful command label when supported.
            $cmdline = __ghostty_encode_osc133_value $Line
            __ghostty_write_osc "${Global:__ghostty_esc}]133;C;aid=${Global:__ghostty_aid};cmdline_url=${cmdline}${Global:__ghostty_bel}"
        }
    } catch {
        # Terminal reporting is a nice-to-have; the user's history is not.
        # Fall through to the chained handler whatever happened here.
    }

    $previous = __ghostty_read_global '__ghostty_addtohistory_original'
    if ($null -eq $previous) { return $true }
    try {
        if ($previous -is [scriptblock]) { return (& $previous $Line) }
        return $previous.Invoke($Line)
    } catch {
        # A predecessor that throws must not cost the user their history
        # either. `$true` is PSReadLine's own "add it" answer.
        return $true
    }
}

function global:__ghostty_install_add_to_history_handler {
    try {
        if ($null -eq (Get-Module -Name PSReadLine -ErrorAction Ignore)) { return }
        $current = (Get-PSReadLineOption).AddToHistoryHandler
        $ours = __ghostty_read_global '__ghostty_addtohistory_handler'
        # Only adopt a new predecessor when the installed handler is not the
        # one we put there. On a plain re-source it is, and the thing to
        # chain to is still the original we saved the first time.
        if ($null -eq $ours -or -not [object]::ReferenceEquals($current, $ours)) {
            $Global:__ghostty_addtohistory_original = $current
        }
        Set-PSReadLineOption -AddToHistoryHandler {
            param([AllowNull()][string]$Line)
            return (__ghostty_add_to_history $Line)
        }
        $Global:__ghostty_addtohistory_handler = (Get-PSReadLineOption).AddToHistoryHandler
    } catch {
        # PSReadLine unavailable or too old — OSC 133 C is simply skipped.
    }
}

__ghostty_install_add_to_history_handler
