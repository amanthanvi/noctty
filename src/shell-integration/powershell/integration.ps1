# Winghostty shell integration for PowerShell 5.1+ / pwsh 7+
# Emits OSC 133 (command marking) and OSC 7 (current working directory) sequences.

$ESC = [char]27
$BEL = [char]7

# ── Idempotent guard: save original prompt once ──────────────────────────
if ($null -eq $Global:__ghostty_aid) {
    $Global:__ghostty_aid = [string]$PID
}

if ($null -eq $Global:__ghostty_original_prompt) {
    $Global:__ghostty_original_prompt = $function:global:prompt
    # Previous-prompt snapshot of $LASTEXITCODE. We compare against this
    # each prompt tick so a stale native exit code from an earlier
    # pipeline can't masquerade as the current command's exit status.
    $Global:__ghostty_prev_exitcode = $LASTEXITCODE
}

function __ghostty_write_osc {
    param([string]$Sequence)
    try {
        [Console]::Write($Sequence)
    } catch {
        Write-Host -NoNewline $Sequence
    }
}

function __ghostty_encode_osc133_value {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return [uri]::EscapeDataString($Value)
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
function __ghostty_encode_cwd_uri {
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
    $ok = $?
    $exit_changed = ($LASTEXITCODE -ne $Global:__ghostty_prev_exitcode)
    $code = if (-not $ok) {
        # Cmdlet / script-block / `throw` failure. Honour a fresh
        # native exit code from the same pipeline; otherwise
        # synthesise 1 so OSC 133 D carries the failure signal.
        if ($exit_changed -and $null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            $LASTEXITCODE
        } else { 1 }
    } elseif ($exit_changed -and $null -ne $LASTEXITCODE) {
        $LASTEXITCODE
    } else { 0 }

    # OSC 133 D — report previous command's exit code
    __ghostty_write_osc "${ESC}]133;D;${code};aid=${Global:__ghostty_aid}${BEL}"

    # OSC 7 — current working directory (full file:// URI)
    $cwd_uri = __ghostty_encode_cwd_uri
    __ghostty_write_osc "${ESC}]7;${cwd_uri}${BEL}"

    # OSC 133 A — mark prompt start (jump-to-prompt anchor)
    __ghostty_write_osc "${ESC}]133;A;cl=line;aid=${Global:__ghostty_aid}${BEL}"

    # Delegate to original prompt. This can internally run native
    # helpers (git-aware prompts are the common case) which overwrite
    # $LASTEXITCODE — so we MUST snapshot AFTER the prompt returns,
    # not before. Taking the snapshot pre-prompt caused the next
    # user-typed cmdlet to inherit the prompt-helper's exit code as
    # its "fresh native" baseline, falsely reporting e.g. `7` for a
    # successful `Get-Date` when the prompt had run `cmd /c exit 7`.
    $out = & $Global:__ghostty_original_prompt

    # Re-snapshot AFTER the wrapped prompt completes so the next
    # prompt tick can distinguish "the user's command wrote
    # $LASTEXITCODE" from "the prompt helpers wrote it".
    $Global:__ghostty_prev_exitcode = $LASTEXITCODE

    # OSC 133 B — mark end of prompt / start of user input
    __ghostty_write_osc "${ESC}]133;B${BEL}"

    return $out
}

# ── OSC 133 C via PSReadLine (pre-execution marker) ─────────────────────
# CommandValidationHandler fires right before the command line is accepted,
# giving us the "command is about to execute" signal.
try {
    if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
        Set-PSReadLineOption -CommandValidationHandler {
            param([string]$line)
            # OSC 133 C — mark start of command output. Include the
            # PSReadLine buffer as URL-encoded metadata so command-finished
            # notifications can show a useful command label when supported.
            $cmdline = __ghostty_encode_osc133_value $line
            __ghostty_write_osc "${ESC}]133;C;aid=${Global:__ghostty_aid};cmdline_url=${cmdline}${BEL}"
            # Return $true to let the command proceed
            return $true
        }
    }
} catch {
    # PSReadLine unavailable or too old — OSC 133 C is simply skipped.
}
