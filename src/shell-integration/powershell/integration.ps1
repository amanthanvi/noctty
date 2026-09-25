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

# ── Reading the head of $Error safely ──────────────────────────────────
# $Error itself always exists, so an unset-variable read is not the hazard
# here; the index is. Under StrictMode 3.0+ (which `-Version Latest` selects)
# an out-of-range index is an error, so `$Error[0]` on an EMPTY $Error throws
# ArgumentOutOfRangeException on both hosts — and the throw is itself
# recorded in $Error, so even swallowing it leaves a record where the user
# had none. Without StrictMode the same expression quietly yields $null.
# Guard on .Count and the behaviour is the same either way.
#
# We keep the head RECORD, never the count. $Error is capped at
# $MaximumErrorCount (256 on Windows PowerShell 5.1), so past the cap the
# count stops growing while the head keeps changing; and the user may run
# `$Error.Clear()`, which drops the count back to 0 while nothing failed.
# An ErrorRecord is a fresh object per failure, so reference identity of the
# head is the reliable "did anything new get recorded" signal.
function global:__ghostty_error_head {
    try {
        if ($Error.Count -gt 0) { return $Error[0] }
    } catch {
        # A host that reshapes $Error is not evidence of an error.
    }
    return $null
}

# ── Telling a native failure from a PowerShell-level one ────────────────
# Records that a NATIVE command pushed onto $Error, which must not be read
# as "a cmdlet/script failed". Two known producers, both measured:
#
#   * pwsh 7.4+ with $PSNativeCommandUseErrorActionPreference $true (it is
#     $false by default, including on 7.6) records a nonzero exit as
#     NativeCommandExitException / `ProgramExitedWithNonZeroCode`.
#   * Windows PowerShell 5.1 turns a native command's redirected stderr
#     into a `NativeCommandError` record (its exception is a
#     RemoteException). pwsh 7 does not.
#
# Matched by FullyQualifiedErrorId, plus NativeCommandExitException by type
# NAME rather than by type identity — that type does not exist on Windows
# PowerShell 5.1, where a `[NativeCommandExitException]` literal parses and
# dot-sources fine but throws `Unable to find type` every time the function
# is CALLED, i.e. on every prompt draw.
#
# Deliberately NOT matched: RemoteException on its own. It is the exception
# of the 5.1 stderr record above, but it is also what every failure
# deserialized out of a job or a remote session carries, keeping its own
# error id — `Start-Job { throw 'x' } | Receive-Job` yields a
# RemotingErrorRecord whose exception is a RemoteException and whose
# FullyQualifiedErrorId is `jobfail`, on both hosts. Treating that as native
# would report a stale native code for a PowerShell-level failure. The
# `NativeCommandError` id already covers the case that matters.
function global:__ghostty_is_native_error {
    param($Record)
    if ($null -eq $Record) { return $false }
    # $Error does not hold only ErrorRecords, and the two other shapes that
    # turn up want opposite answers:
    #
    #   * A parse error typed at the prompt is stored as a bare
    #     ParseException (both hosts) — a PowerShell-level failure.
    #   * Under `$ErrorActionPreference = 'Stop'` PowerShell pushes an
    #     ActionPreferenceStopException AHEAD of the record it stopped on.
    #     With $PSNativeCommandUseErrorActionPreference also $true, that
    #     wrapper hides a perfectly good ProgramExitedWithNonZeroCode and a
    #     repeated native failure got mis-reported as 1.
    #
    # Unwrap one level through `.ErrorRecord`, which both shapes inherit
    # from RuntimeException, and classify what comes out — a ParseException
    # unwraps to a non-native record, so it still reads as a PowerShell
    # failure. `$x.PSObject.Properties[...]` yields $null for an absent
    # property instead of throwing under StrictMode.
    if (-not ($Record -is [System.Management.Automation.ErrorRecord])) {
        $unwrapped = $null
        try {
            if ($null -ne $Record.PSObject.Properties['ErrorRecord']) {
                $unwrapped = $Record.ErrorRecord
            }
        } catch {
            $unwrapped = $null
        }
        if (-not ($unwrapped -is [System.Management.Automation.ErrorRecord])) {
            return $false
        }
        $Record = $unwrapped
    }
    try {
        $fqid = [string]$Record.FullyQualifiedErrorId
        if ($fqid -eq 'ProgramExitedWithNonZeroCode' -or
            $fqid -eq 'NativeCommandError' -or
            $fqid -eq 'NativeCommandErrorMessage' -or
            $fqid -eq 'NativeCommandFailed') {
            return $true
        }
        $exception = $Record.Exception
        if ($null -ne $exception -and
            $exception.GetType().Name -eq 'NativeCommandExitException') {
            return $true
        }
    } catch {
        # An unexpected record shape is not evidence of a native failure.
        return $false
    }
    return $false
}

# ── Idempotent guard: take the first snapshots once ─────────────────────
if ($null -eq (__ghostty_read_global '__ghostty_aid')) {
    $Global:__ghostty_aid = [string]$PID
}

# The "before the command" snapshots `__ghostty_prompt_body` compares
# against, re-taken at the end of every prompt and again when a line is
# accepted. $LASTEXITCODE is compared so a stale native exit code from an
# earlier pipeline can't masquerade as the current command's exit status; the
# head of $Error is compared so a repeated native failure can be told apart
# from a cmdlet failure that left $LASTEXITCODE untouched. See
# `__ghostty_prompt_body` for why one signal alone is not enough. Taken only
# on the first load, so a re-source does not move the baseline of the command
# that re-sourced us.
if ($null -eq (Get-Variable -Name '__ghostty_prev_exitcode' -Scope Global -ErrorAction Ignore)) {
    $Global:__ghostty_prev_exitcode = __ghostty_read_global 'LASTEXITCODE'
    $Global:__ghostty_prev_error = __ghostty_error_head
}

# Write a sequence straight to the console. ConstrainedLanguage refuses
# `[Console]::Write` (a method on a type outside its core set), and the
# refusal, even caught, lands in $Error on every prompt, so that mode goes
# to Write-Host directly. The property read is allowed in every mode.
function global:__ghostty_write_osc {
    param([string]$Sequence)
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Host -NoNewline $Sequence
        return
    }
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
    Remove-Item -LiteralPath 'Function:\ssh' -Force -ErrorAction Ignore -Confirm:$false -WhatIf:$false
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

# ── How the prompt and the line reader are hooked ─────────────────────
#
#   prompt                 a generated FUNCTION, one per prompt we wrap
#   PSConsoleHostReadLine  a global ALIAS -> __ghostty_readline
#
# The prompt: `function prompt` becomes a one-line function that captures $?
# and calls `__ghostty_prompt_body <id>`; `<id>` indexes the prompt it wraps
# in `$__ghostty_prompts`. Because the id lives in the function's own TEXT,
# every copy of it still wraps the same prompt: a venv's `Activate.ps1` copies
# the current prompt aside with Copy-Item and `deactivate` copies it back,
# and a tool that captures `$function:prompt` or `(Get-Command
# prompt).ScriptBlock` to chain to calls it by value. `Get-Command prompt`
# stays a Function, as about_Prompts documents, and PSReadLine, which reads
# the prompt function once to decide whether to repaint part of the prompt on
# a parse error, sees a function that calls a command and leaves the prompt
# alone, as it always has under noctty.
#
# A prompt replaced after startup (`. $PROFILE`, an oh-my-posh or Starship
# re-init, a venv) is wrapped again by `__ghostty_readline` before the next
# line is read. The ONE prompt drawn before that, by the user's own function,
# gets OSC 7, a P mark and B from `__ghostty_readline` instead, and lacks only
# its D. Hooking
# `prompt` through an alias instead catches that one too, since an alias
# resolves before a function of the same name, but it was measured to cost
# more than it saves: `Get-Command prompt` then returns the alias, whose
# missing `.ScriptBlock` breaks a profile that chains to the prompt that way on
# every later `. $PROFILE` (the prompt turns into `PS>` plus an error per
# draw), and PSReadLine then sees the user's own prompt, derives a PromptText
# such as `> ` from a plain one like PowerShell's default, and repaints it
# AFTER our B mark on every parse error, so the terminal takes those prompt
# cells for input and `insert_last_command` recovers `> Get-Date`.
#
# The line reader: the console host reads each line by running the command
# `PSConsoleHostReadLine`, and only when a FUNCTION (or cmdlet) of that name
# exists, which PSReadLine defines on import. An alias resolves before that
# function, so ours wraps whatever function is current: PSReadLine's own, a
# profile's wrapper of it, or a re-imported PSReadLine's. With PSReadLine
# absent or removed the host finds no function and reads the line itself, and
# the alias is idle; measured on both hosts, `Remove-Module PSReadLine` leaves
# `$Error` empty and `Import-Module PSReadLine` makes the alias live again.
# Nothing a profile does reaches PSConsoleHostReadLine through Get-Command in
# practice (VS Code's integration, for one, reads `$function:`).
#
# All measured on pwsh 7.6.6 / PSReadLine 2.4.5 and Windows PowerShell
# 5.1.26100 / PSReadLine 2.0.0.

if ($null -eq (__ghostty_read_global '__ghostty_prompts')) {
    $Global:__ghostty_prompts = @{}
    $Global:__ghostty_prompt_count = 0
}

# Reference identity, which the $Error-head comparison and the prompt checks
# need. ConstrainedLanguage refuses `[object]::ReferenceEquals`; `-eq` is the
# same test for these types (ScriptBlock, ErrorRecord and exceptions do not
# override Equals) and works in every language mode.
function global:__ghostty_same_object {
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) {
        return ($null -eq $Left -and $null -eq $Right)
    }
    if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') {
        return [object]::ReferenceEquals($Left, $Right)
    }
    return ($Left -eq $Right)
}

# Is this prompt function one of ours (or a copy of one)? Only the exact text
# we generate counts: a profile that built its prompt by pasting our text
# after its own is not ours, gets wrapped, and its copy of our call is then
# a nested one that passes straight through.
function global:__ghostty_prompt_is_ours {
    param($Prompt)
    if ($null -eq $Prompt) { return $false }
    return (([string]$Prompt).Trim() -match '^\$__ghostty_ok = \$\?; __ghostty_prompt_body \$__ghostty_ok \d+$')
}

# Wrap whatever `function prompt` is now, unless it is already ours. At load
# a missing prompt function is wrapped too, as the previous version did, and
# draws PowerShell's default text; later, a prompt the user deleted is left
# deleted. -WhatIf / -Confirm do not apply to a `$function:` assignment.
function global:__ghostty_wrap_prompt {
    param([switch]$EvenIfMissing)
    $current = ${function:global:prompt}
    if (__ghostty_same_object $current (__ghostty_read_global '__ghostty_prompt_installed')) { return }
    if (__ghostty_prompt_is_ours $current) {
        $Global:__ghostty_prompt_installed = $current
        return
    }
    if ($null -eq $current -and -not $EvenIfMissing) { return }
    if ($null -ne $current) {
        # A ReadOnly or Constant prompt cannot be replaced, and trying puts
        # an error in $Error on every line. Leave it unwrapped. The provider
        # path takes no scope qualifier (`function:global:prompt` finds
        # nothing), and from this global function `function:prompt` is the
        # global one. String interpolation, not a type reference, so this
        # also runs under ConstrainedLanguage.
        $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath 'function:prompt' -ErrorAction Ignore
        if ($null -ne $item -and "$($item.Options)" -match 'ReadOnly|Constant') { return }
    }
    $id = [int](__ghostty_read_global '__ghostty_prompt_count') + 1
    $function:global:prompt = '$__ghostty_ok = $?; __ghostty_prompt_body $__ghostty_ok ' + $id
    # Only once the assignment has taken.
    $Global:__ghostty_prompt_count = $id
    $Global:__ghostty_prompts[$id] = $current
    $Global:__ghostty_prompt_installed = ${function:global:prompt}
}

# ── The prompt ───────────────────────────────────────────────────────────
function global:__ghostty_prompt_body {
    # `$ok` is the $? the user's command left. The generated `prompt`
    # captures it as its very first statement and passes it here, because
    # every statement resets $?.
    param([bool]$ok, $id)

    $user_prompt = $null
    try {
        $prompts = __ghostty_read_global '__ghostty_prompts'
        if ($null -ne $prompts) { $user_prompt = $prompts[$id] }
    } catch {
        $user_prompt = $null
    }

    # Nested: this wrapper is running inside another one, because a prompt
    # we wrapped calls a copy of an earlier wrapper (a venv's saved prompt,
    # a profile that chained to `$function:prompt`). The outer call writes
    # the marks; this one only hands back the prompt it wraps.
    if (__ghostty_read_global '__ghostty_in_prompt') {
        if ($null -eq $user_prompt) { return "PS $($PWD.Path)> " }
        if (-not $ok) {
            Microsoft.PowerShell.Utility\Write-Error -Message '' -ErrorAction Ignore
        }
        return (& $user_prompt)
    }

    $Global:__ghostty_in_prompt = $true
    try {
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
        # Comparing $LASTEXITCODE against the value snapshotted before the
        # command ran separates a fresh code from a stale one — but only
        # when the code CHANGED. Two native commands failing with the same
        # code are indistinguishable from a cmdlet failing after a native
        # one on that signal alone: both leave $? false and $LASTEXITCODE
        # untouched, so `cmd /c exit 5` twice reported 5 and then 1 (#237).
        #
        # $Error breaks the tie. A cmdlet / script / `throw` / `Write-Error`
        # failure always pushes an ErrorRecord; a native command's nonzero
        # exit does not (measured on Windows PowerShell 5.1 and on pwsh 7.6,
        # whose $PSNativeCommandUseErrorActionPreference defaults to
        # $false), and the records native commands DO push are recognised
        # by __ghostty_is_native_error. So when $? is false:
        #
        #   * head of $Error is a new, non-native record → PowerShell-level
        #     failure: report $LASTEXITCODE only if it changed and is
        #     nonzero, else 1.
        #   * otherwise → native failure: report $LASTEXITCODE whenever it
        #     is nonzero, changed or not.
        #
        # And when $? is true, a new bare ParseException at the head is a
        # line that did not parse: PowerShell leaves $? true for it (measured
        # on both hosts), so it would otherwise read as a success.
        #
        # Two measured limits, both of which report a stale-but-real native
        # code where the old rule reported a synthetic 1, so the mark still
        # reads as a failure either way:
        #
        #   * A command silenced with `-ErrorAction Ignore` leaves $? false
        #     and pushes nothing, so it lands in the native arm.
        #   * PowerShell does not reset $? for an EMPTY command line, so
        #     pressing Enter after any failure re-reports the last native
        #     code (or 1). No C mark precedes that D (see
        #     `__ghostty_readline`), so the terminal attaches it to no
        #     command.
        #
        # Resetting $LASTEXITCODE here to remove the ambiguity is not an
        # option: users read it.
        #
        # Everything below reads through __ghostty_read_global so a
        # profile's Set-StrictMode cannot turn "no native command has run
        # yet" into a terminating error that costs the user their prompt.
        $code = 0
        try {
            # Read the head FIRST, before any other helper. This used to be
            # load-bearing: __ghostty_read_global asked for -ErrorAction
            # SilentlyContinue, which still APPENDS to $Error, and
            # $LASTEXITCODE is legitimately unset in a session that has run
            # no native command — so our own VariableNotFound record landed
            # on top of the user's and every native failure read as a
            # PowerShell one. That helper now uses -ErrorAction Ignore, but
            # keeping this read first means no later change over there can
            # silently do it again.
            $error_head = __ghostty_error_head
            $prev_error = __ghostty_read_global '__ghostty_prev_error'
            $last_exitcode = __ghostty_read_global 'LASTEXITCODE'
            $exit_changed = ($last_exitcode -ne (__ghostty_read_global '__ghostty_prev_exitcode'))
            # A null head means $Error is empty, so no record survived and
            # there is no new PowerShell-level failure to report. That is
            # also how a user's `$Error.Clear()` between prompts lands here.
            $new_error = ($null -ne $error_head) -and
                (-not (__ghostty_same_object $error_head $prev_error))
            $ps_error = $new_error -and (-not (__ghostty_is_native_error $error_head))
            $code = if ($ok) {
                if ($new_error -and ($error_head -is [System.Management.Automation.ParseException])) {
                    1
                } elseif ($exit_changed -and $null -ne $last_exitcode) {
                    $last_exitcode
                } else { 0 }
            } elseif ($ps_error) {
                # Cmdlet / script-block / `throw` failure. Honour a fresh
                # native exit code from the same pipeline; otherwise
                # synthesise 1 so OSC 133 D carries the failure signal.
                if ($exit_changed -and $null -ne $last_exitcode -and $last_exitcode -ne 0) {
                    $last_exitcode
                } else { 1 }
            } else {
                # Native failure. The code is authoritative even when it
                # repeats the previous command's, which is the whole point
                # of consulting $Error: `$exit_changed` is false for the
                # second of two `cmd /c exit 5`.
                if ($null -ne $last_exitcode -and $last_exitcode -ne 0) {
                    $last_exitcode
                } else { 1 }
            }
        } catch {
            # Report an unknown status rather than losing the prompt.
            $code = 0
        }

        # Everything terminal-reporting lives inside try/catch, and the
        # user's own prompt is invoked OUTSIDE it. Shell integration is a
        # nice-to-have; the user's prompt is not. If any of our helpers
        # throws, PowerShell discards the whole prompt function and silently
        # substitutes its built-in `PS C:\...>` — which is exactly how #231
        # presented, and it looks to the user like noctty deleted their
        # starship / oh-my-posh configuration. Degrading to "no OSC marks
        # this tick" is always the better failure. The harness asserts the
        # marks ARE emitted, so this cannot quietly swallow a real
        # regression.
        #
        # A throw from the USER's own prompt is deliberately not caught:
        # that is their bug to see. The `finally` below only clears the
        # nesting flag on the way out.
        try {
            # OSC 133 D — report previous command's exit code
            __ghostty_write_osc "${Global:__ghostty_esc}]133;D;${code};aid=${Global:__ghostty_aid}${Global:__ghostty_bel}"

            # OSC 7 — current working directory (full file:// URI)
            $cwd_uri = __ghostty_encode_cwd_uri
            __ghostty_write_osc "${Global:__ghostty_esc}]7;${cwd_uri}${Global:__ghostty_bel}"

            # OSC 133 A — mark prompt start (jump-to-prompt anchor).
            # `redraw=0`: PowerShell never re-runs `prompt` after a resize,
            # so the terminal must not clear the prompt rows expecting it to.
            __ghostty_write_osc "${Global:__ghostty_esc}]133;A;cl=line;aid=${Global:__ghostty_aid};redraw=0${Global:__ghostty_bel}"
        } catch {
            # Deliberately silent: writing an error here would corrupt the
            # prompt line we are about to draw.
        }
        # Tells `__ghostty_readline` this prompt was ours; see there.
        $Global:__ghostty_prompt_marked = $true

        # Delegate to the user's prompt. This can internally run native
        # helpers (git-aware prompts are the common case) which overwrite
        # $LASTEXITCODE — so we MUST snapshot AFTER the prompt returns,
        # not before. Taking the snapshot pre-prompt caused the next
        # user-typed cmdlet to inherit the prompt-helper's exit code as
        # its "fresh native" baseline, falsely reporting e.g. `7` for a
        # successful `Get-Date` when the prompt had run `cmd /c exit 7`.
        # If there is no prompt function at all, emit what PowerShell's
        # own default prompt would have: returning a sane string beats
        # throwing, which costs the user the prompt line AND spills an
        # error into it.
        if ($null -eq $user_prompt) {
            $out = "PS $($PWD.Path)> "
        } else {
            # Hand the user's prompt the $? their command left, not ours.
            # Every statement above reset it to $true, so a prompt that
            # reads it -- Starship and oh-my-posh read `$?` first thing --
            # showed every failed command as a success (measured on both
            # hosts: $? read `True` inside the wrapped prompt after a failed
            # `Get-Item`). `Write-Error -ErrorAction Ignore` is the one
            # side-effect-free way to make $? false: it records nothing in
            # $Error (measured, both hosts), and it must stay the last
            # statement before the call.
            if (-not $ok) {
                Microsoft.PowerShell.Utility\Write-Error -Message '' -ErrorAction Ignore
            }
            $out = & $user_prompt
        }

        # Re-snapshot AFTER the wrapped prompt completes so the next
        # prompt tick can distinguish "the user's command wrote
        # $LASTEXITCODE" from "the prompt helpers wrote it".
        try {
            $Global:__ghostty_prev_exitcode = __ghostty_read_global 'LASTEXITCODE'
        } catch {
            # See below: never let our bookkeeping eat the user's prompt.
        }

        # OSC 133 B — end of prompt, start of user input. It must follow
        # the prompt TEXT, which is not on screen yet: the host draws the
        # string this function returns after it returns. `__ghostty_readline`
        # writes B once the host has drawn it and before the line is read,
        # so the returned string stays exactly the user's (a transcript
        # records it) and B lands after whatever the host drew. B rides at
        # the end of the returned string only where no line read follows a
        # host draw: a PSReadLine repaint (Ctrl+L, a transient prompt), which
        # runs this INSIDE the line reader, and a session with no
        # PSConsoleHostReadLine function to hook, where the host reads the
        # line itself.
        try {
            $reader_marks_input = (-not (__ghostty_read_global '__ghostty_in_readline')) -and
                ($null -ne ${function:global:PSConsoleHostReadLine}) -and
                (${alias:PSConsoleHostReadLine} -eq '__ghostty_readline')
            if (-not $reader_marks_input) { $out = __ghostty_append_input_mark $out }
        } catch {
            # See above: never let a reporting failure eat the user's prompt.
        }

        # Re-snapshot the head of $Error LAST — after the user's prompt and
        # after every one of our own guards. A caught exception is still
        # recorded in $Error, so a snapshot taken any earlier would leave
        # one of OUR records, or one the user's own prompt caused, looking
        # like the user's next failure. `__ghostty_readline` takes it again
        # once a line is accepted, which also covers anything a key handler
        # did in between.
        try {
            $Global:__ghostty_prev_error = __ghostty_error_head
        } catch {
            # See above: never let our bookkeeping eat the user's prompt.
        }

        return $out
    } finally {
        $Global:__ghostty_in_prompt = $false
    }
}

# Put OSC 133 B at the end of the prompt text about to be drawn, for the two
# cases where `__ghostty_readline` cannot write it (see the caller).
#
# Measured on both hosts: the host draws only the FIRST object a prompt
# outputs (`'A> '; 'B> '` draws `A> `) and draws `PS>` for an empty string or
# no output at all; PSReadLine's InvokePrompt draws the prompt only when there
# is exactly one object, else `PS>`. So an empty prompt becomes that same
# `PS>` with B after it. Anything but a single string is left alone and B is
# written directly: its drawn text is not ours to reproduce.
#
# Without PSReadLine a transcript records this B with the prompt; a
# PSReadLine repaint is not transcribed.
function global:__ghostty_append_input_mark {
    param($Output)
    $mark = "${Global:__ghostty_esc}]133;B${Global:__ghostty_bel}"
    $items = @($Output)
    $first = if ($items.Count -gt 0) { $items[0] } else { $null }
    # A non-string, or more than one object: write B directly, before the
    # text, as before this was appended to the prompt. PSReadLine's
    # InvokePrompt (Ctrl+L, transient prompts) draws `PS>` for a prompt that
    # returns several objects, so a B appended to the first one would never
    # reach the screen after such a repaint.
    if ($items.Count -gt 1 -or ($null -ne $first -and -not ($first -is [string]))) {
        __ghostty_write_osc $mark
        return $Output
    }
    $text = [string]$first
    if ($text.Length -eq 0) { $text = 'PS>' }
    return ($text + $mark)
}

# ── The line reader: OSC 133 C ───────────────────────────────────────────
# OSC 133 C ("command started") goes out when the host's line reader
# returns an accepted line, just before the host runs it.
#
# It used to ride on PSReadLine's `AddToHistoryHandler`, which PSReadLine
# does not call for every accepted line: `GetAddToHistoryOption` skips a
# line identical to the previous history entry under the default
# `HistoryNoDuplicates`, and a whitespace-only line, before any handler
# runs. So running the same command twice got no C the second time, and a
# shell nested from a repeated `wsl` inherited PowerShell's `redraw=0`. The
# handler also had to be chained to PSReadLine's sensitive-history filter,
# and PSReadLine 2.0.0 (Windows PowerShell 5.1) calls it for every line it
# replays out of the history file, so it needed a buffer-state gate as well.
# None of that applies here: this runs once per ReadLine return, never for
# replayed history, and noctty no longer touches the AddToHistoryHandler at
# all. (CommandValidationHandler, the hook before that, only fires for
# `ValidateAndAcceptLine`, which Enter is not bound to by default.)
#
# An empty or whitespace-only line gets no C: PowerShell runs nothing for
# it, and a C there would make it the terminal's "last command", so
# `insert_last_command` and `copy_last_command_output` would lose the real
# one. That matches noctty's clink integration, zsh and bash.
function global:__ghostty_readline {
    # $? FIRST, for the same reason as in the generated prompt: PSReadLine's
    # own PSConsoleHostReadLine reads $? as its first statement and hands it
    # to predictors as the status of the previous command line.
    $ok = $?
    $read_line = ${function:global:PSConsoleHostReadLine}
    if (__ghostty_same_object $read_line ${function:global:__ghostty_readline}) {
        $read_line = $null
    }
    # The host only calls us when that function exists, so this is someone
    # invoking the alias by hand (or a PSConsoleHostReadLine that is this
    # wrapper copied over, which would recurse). No output makes the host
    # read the line itself, which is also what it does when it finds no
    # such function.
    if ($null -eq $read_line) { return }

    # Did our wrapper draw the prompt on screen? Not when the command that
    # just ran replaced `function prompt` (`. $PROFILE`, a theme re-init), or
    # when a prompt is ReadOnly and cannot be wrapped at all.
    $marked = [bool](__ghostty_read_global '__ghostty_prompt_marked')

    # Wrap a replaced prompt so the next one carries all of our marks.
    # Costs a reference comparison when nothing changed.
    try {
        __ghostty_wrap_prompt
    } catch {
        # The snapshot at the end of this function covers any record this
        # left; a missed re-wrap only costs marks.
    }

    # OSC 133 B, where input really begins: the host has drawn the prompt,
    # whatever it returned, and PSReadLine has not started. An unmarked
    # prompt first gets OSC 7 and a P mark in place of its missing A, with
    # `redraw=0` for the same reason A carries it. P does not fresh-line the
    # way A does, so the cursor stays put after the drawn text. Its D is
    # lost, which costs the replacing command its command-finished
    # notification and exit status; the next C restarts the command timer.
    #
    # Only the host's own read of a prompt line gets marks or consumes the
    # flag. A script that calls PSConsoleHostReadLine itself is not that
    # read: the host's sits alone on the call stack (one frame, one more per
    # nested prompt; measured on both hosts), and marks written into a
    # running command would end it early. That includes a prompt function
    # calling the reader, which runs after our wrapper has set the flag, so
    # the flag cannot vouch for the caller. And under Enter-PSSession the
    # prompt on screen is the remote one, drawn remotely: a P and B there
    # would be dated with this machine's directory and turn remote prompts
    # into local ones. The check costs 10-70 microseconds a line (measured
    # on both hosts).
    $from_host = $false
    try {
        $from_host = (-not $Host.IsRunspacePushed) -and
            (@(Get-PSCallStack).Count -le (1 + $NestedPromptLevel))
        if ($from_host) {
            $Global:__ghostty_prompt_marked = $false
            if (-not $marked) {
                $cwd_uri = __ghostty_encode_cwd_uri
                __ghostty_write_osc "${Global:__ghostty_esc}]7;${cwd_uri}${Global:__ghostty_bel}"
                __ghostty_write_osc "${Global:__ghostty_esc}]133;P;k=i;redraw=0${Global:__ghostty_bel}"
            }
            __ghostty_write_osc "${Global:__ghostty_esc}]133;B${Global:__ghostty_bel}"
        }
    } catch {
        # A missing mark costs the terminal a prompt boundary, never a line.
    }

    # A prompt drawn while the line is being read is PSReadLine's repaint
    # (Ctrl+L, a transient prompt): the prompt then carries its own B.
    #
    # No try/finally around the call. PSReadLine throws when stdin is
    # redirected. As written, the wrapper runs on past the throw, clears the
    # flags, and the host goes on to read the line itself. With the call
    # inside `try { } finally { }` the host instead took the wrapper's return
    # for end of input and the session exited after its first prompt.
    # Measured on both hosts; why the host tells the two apart is not
    # established.
    $Global:__ghostty_in_readline = $true
    # Hand on the $? the command left, as the last statement before the
    # call; see __ghostty_prompt_body.
    if (-not $ok) {
        Microsoft.PowerShell.Utility\Write-Error -Message '' -ErrorAction Ignore
    }
    $line = & $read_line
    $Global:__ghostty_in_readline = $false
    if ($from_host) { $Global:__ghostty_prompt_marked = $false }

    try {
        if ($line -is [string] -and -not [string]::IsNullOrWhiteSpace($line)) {
            # OSC 133 C — mark start of command output, with the accepted
            # line as URL-encoded metadata so command-finished notifications
            # can show a useful label. The terminal reads OSC 133 into a
            # 2048-byte buffer and drops a longer mark WHOLE, so a label that
            # would not fit is left off rather than costing the C mark; so is
            # the encoding of a line that long, which on Windows PowerShell
            # throws past 32766 characters, and a caught exception would
            # still land in $Error.
            $cmdline = ''
            if ($line.Length -le 2000) {
                $encoded = __ghostty_encode_osc133_value $line
                if ($encoded.Length -le 2000) { $cmdline = ';cmdline_url=' + $encoded }
            }
            __ghostty_write_osc "${Global:__ghostty_esc}]133;C;aid=${Global:__ghostty_aid}${cmdline}${Global:__ghostty_bel}"
        }
        # This is the last moment before the command runs, so it is the
        # truest "before" for the D-mark comparison: a key handler that ran
        # a native tool (a fuzzy finder, say) since the prompt was drawn no
        # longer looks like the command's own exit code.
        $Global:__ghostty_prev_exitcode = __ghostty_read_global 'LASTEXITCODE'
        $Global:__ghostty_prev_error = __ghostty_error_head
    } catch {
        # The line is the user's; a reporting failure must not cost it.
    }

    return $line
}

# ── Retiring hooks an older copy of this script installed ─────────────────
# A session that loaded an earlier noctty and then sources this one (a
# `. $PROFILE` that dot-sources the installed copy after an upgrade) still
# has the old hooks: `function prompt` replaced by a wrapper that saved the
# user's prompt in `$__ghostty_original_prompt`, and an AddToHistoryHandler
# that emits its own C. Left alone, every mark would be doubled, so put back
# what the old copy replaced, and only where it is still the old copy's hook.
# -Confirm / -WhatIf are pinned off: a profile's `$ConfirmPreference = 'Low'`
# would otherwise stop the launch at a prompt, and `$WhatIfPreference` would
# make these a no-op.
function global:__ghostty_retire_legacy_hooks {
    try {
        $saved_prompt = __ghostty_read_global '__ghostty_original_prompt'
        $current_prompt = ${function:global:prompt}
        if ($null -ne $saved_prompt -and $null -ne $current_prompt -and
            ([string]$current_prompt).Contains('__ghostty_original_prompt')) {
            $function:global:prompt = $saved_prompt
        }
        Remove-Variable -Name '__ghostty_original_prompt' -Scope Global -ErrorAction Ignore -Confirm:$false -WhatIf:$false

        $old_handler = __ghostty_read_global '__ghostty_addtohistory_handler'
        if ($null -ne $old_handler -and $null -ne (Get-Module -Name PSReadLine -ErrorAction Ignore)) {
            $current_handler = (Get-PSReadLineOption).AddToHistoryHandler
            if (__ghostty_same_object $current_handler $old_handler) {
                Set-PSReadLineOption -AddToHistoryHandler (__ghostty_read_global '__ghostty_addtohistory_original')
            }
        }
        Remove-Variable -Name '__ghostty_addtohistory_handler' -Scope Global -ErrorAction Ignore -Confirm:$false -WhatIf:$false
        Remove-Variable -Name '__ghostty_addtohistory_original' -Scope Global -ErrorAction Ignore -Confirm:$false -WhatIf:$false
    } catch {
        # Best effort: a failure here leaves doubled marks, not a broken shell.
    }
}

# Point `Name` at our wrapper unless the user already has an alias of that
# name for something else, which we leave alone (the integration then stays
# off for that hook). -ErrorAction Ignore: a Constant alias must not leave a
# record in the user's $Error. -Confirm / -WhatIf / -Verbose pinned off for
# the reason above: Set-Alias is a Medium-impact ShouldProcess cmdlet.
function global:__ghostty_install_alias {
    param([string]$Name, [string]$Target)
    $existing = Get-Alias -Name $Name -Scope Global -ErrorAction Ignore
    if ($null -ne $existing -and $existing.Definition -ne $Target) { return }
    Set-Alias -Name $Name -Value $Target -Scope Global -Force -ErrorAction Ignore -Confirm:$false -WhatIf:$false -Verbose:$false
}

__ghostty_retire_legacy_hooks
__ghostty_wrap_prompt -EvenIfMissing
__ghostty_install_alias 'PSConsoleHostReadLine' '__ghostty_readline'
