param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$script:OriginalPrompt = $function:global:prompt
$script:OriginalOut = [Console]::Out
$script:OriginalFeatures = $env:GHOSTTY_SHELL_FEATURES
# PSReadLine is not auto-loaded in a non-interactive host, so this is $null
# until the AddToHistoryHandler section below imports the module itself.
$script:PSReadLineImported = $false
$script:OriginalAddToHistoryHandler = $null
$script:IntegrationPath = Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1'
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-ps-si-" + [guid]::NewGuid().ToString('n'))

try {
    New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
    $specialDir = Join-Path $script:TempDir 'a b#c%d&e+f'
    New-Item -ItemType Directory -Force -Path $specialDir | Out-Null
    Push-Location $specialDir

    # Deliberately NOT 'PS> ': that is the string PowerShell's built-in prompt
    # produces when our wrapper throws, so a fixture spelled that way cannot
    # tell "the user's prompt was preserved" apart from "the user's prompt was
    # lost and PowerShell fell back" (issue #231).
    function global:prompt { 'NOCTTYPROBE> ' }

    # The UTF-8 console decision must never travel in the child environment.
    # A PowerShell profile runs before noctty's injected -Command, so an
    # environment variable would already have leaked to anything the profile
    # spawned by the time this script could clear it.
    $integrationSource = Get-Content -LiteralPath $script:IntegrationPath -Raw
    Assert-True (-not ($integrationSource -match 'env:GHOSTTY_UTF8_CONSOLE')) "UTF-8 console decision must not travel through a child environment variable"
    Assert-True ($integrationSource -match '__ghostty_utf8_console') "UTF-8 console decision must be read from the injected launch variable"

    # Dot-sourcing without the launch variable set is the manual-integration
    # path: Get-Variable must resolve to nothing instead of erroring.
    . $script:IntegrationPath
    Assert-True ($null -eq (Get-Variable -Name '__ghostty_utf8_console' -ValueOnly -ErrorAction SilentlyContinue)) "Manual dot-sourcing must not define the launch variable"

    $cwdUri = __ghostty_encode_cwd_uri
    Assert-True ($cwdUri.StartsWith('file://')) "OSC 7 cwd URI must include file:// scheme"
    foreach ($encoded in @('%20', '%23', '%25', '%26', '%2B')) {
        Assert-True ($cwdUri.Contains($encoded)) "OSC 7 cwd URI missing encoded segment token $encoded in $cwdUri"
    }

    $encodedCommand = __ghostty_encode_osc133_value "Get-ChildItem 'a;b'"
    Assert-True ($encodedCommand -eq 'Get-ChildItem%20%27a%3Bb%27') "OSC 133 command metadata was not URL encoded: $encodedCommand"

    $env:GHOSTTY_SHELL_FEATURES = 'ssh-env, ssh-terminfo'
    Assert-True (__ghostty_has_feature 'ssh-env') "ssh-env feature was not detected"
    Assert-True (__ghostty_has_feature 'ssh-terminfo') "ssh-terminfo feature with whitespace was not detected"
    Assert-True (__ghostty_has_feature_prefix 'ssh-') "ssh-* feature prefix was not detected"

    $cachedProbe = { param([string]$Target) return ($Target -eq 'alice@example.com') }
    $cachedInvocation = __ghostty_build_ssh_invocation `
        -Arguments @('example-alias') `
        -ConfigLines @('user alice', 'hostname example.com') `
        -CacheProbe $cachedProbe
    Assert-True ($cachedInvocation.Term -eq 'xterm-ghostty') "Cached SSH terminfo target should use xterm-ghostty"
    Assert-True (($cachedInvocation.Options -join '|') -eq '-o|SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION') "ssh-env did not add SendEnv options"
    Assert-True (($cachedInvocation.Arguments -join '|') -eq 'example-alias') "SSH positional arguments changed"

    $uncachedInvocation = __ghostty_build_ssh_invocation `
        -Arguments @('uncached') `
        -ConfigLines @('user bob', 'hostname example.net') `
        -CacheProbe $cachedProbe
    Assert-True ($uncachedInvocation.Term -eq 'xterm-256color') "Uncached SSH terminfo target should fall back to xterm-256color"

    $env:GHOSTTY_SHELL_FEATURES = ''
    $plainInvocation = __ghostty_build_ssh_invocation `
        -Arguments @('plain') `
        -ConfigLines @('hostname example.org') `
        -CacheProbe $cachedProbe
    Assert-True ($plainInvocation.Term -eq 'xterm-256color') "Plain SSH invocation should use xterm-256color"
    Assert-True ($plainInvocation.Options.Count -eq 0) "Plain SSH invocation should not add options"

    $fakeSsh = Join-Path $script:TempDir 'fake-ssh.cmd'
    $fakeCapture = Join-Path $script:TempDir 'fake-ssh.txt'
    Set-Content -LiteralPath $fakeSsh -Encoding ASCII -Value @(
        '@echo off',
        '(',
        'echo TERM=%TERM%',
        'echo COLORTERM=%COLORTERM%',
        'echo ARGS=%*',
        ') > "%FAKE_SSH_CAPTURE%"',
        'exit /b 0'
    )

    $script:FakeSsh = $fakeSsh
    $env:FAKE_SSH_CAPTURE = $fakeCapture
    $env:GHOSTTY_SHELL_FEATURES = 'ssh-env'
    . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
    $installedSsh = Get-Command ssh -CommandType Function -ErrorAction SilentlyContinue
    Assert-True ($null -ne $installedSsh) "ssh wrapper was not installed"
    # The marker is what lets a re-source tell our wrapper apart from a
    # user-defined `ssh`; without it the removal below is a no-op and the
    # wrapper would stack.
    Assert-True (([string]$installedSsh.ScriptBlock).Contains('__ghostty_ssh_wrapper_marker')) "ssh wrapper is missing the ownership marker"
    Assert-True ([bool]$Global:__ghostty_ssh_wrapper_installed) "ssh wrapper install flag was not set"
    Assert-True (__ghostty_ssh_wrapper_is_ours) "__ghostty_ssh_wrapper_is_ours did not recognise our own wrapper"

    # Re-sourcing with the feature still on must REPLACE our wrapper, not
    # stack a second one on top of it.
    $errorsBeforeResource = $Error.Count
    . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
    Assert-True ($Error.Count -eq $errorsBeforeResource) "Re-sourcing the integration script pushed records into `$Error"
    Assert-True (@(Get-Command ssh -CommandType Function -ErrorAction SilentlyContinue).Count -eq 1) "Re-sourcing stacked more than one ssh wrapper"
    Assert-True (__ghostty_ssh_wrapper_is_ours) "Re-sourced ssh wrapper lost the ownership marker"

    function __ghostty_find_command_application {
        param([string[]]$Names)
        return $script:FakeSsh
    }

    $env:TERM = 'original-term'
    $env:COLORTERM = 'original-color'
    ssh 'example.com' '-p' '22'
    Assert-True ($env:TERM -eq 'original-term') "ssh wrapper did not restore TERM"
    Assert-True ($env:COLORTERM -eq 'original-color') "ssh wrapper did not restore COLORTERM"
    $fakeOutput = Get-Content -LiteralPath $fakeCapture -Raw
    Assert-True ($fakeOutput.Contains('TERM=xterm-256color')) "ssh wrapper did not set TERM for child process"
    Assert-True ($fakeOutput.Contains('COLORTERM=truecolor')) "ssh-env wrapper did not set COLORTERM for child process"
    Assert-True ($fakeOutput.Contains('ARGS=-o "SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION" example.com -p 22')) "ssh wrapper argv was not forwarded correctly: $fakeOutput"

    Remove-Item Env:TERM -ErrorAction SilentlyContinue
    Remove-Item Env:COLORTERM -ErrorAction SilentlyContinue
    ssh 'example.org'
    Assert-True (-not (Test-Path Env:TERM)) "ssh wrapper did not remove TERM after child process"
    Assert-True (-not (Test-Path Env:COLORTERM)) "ssh wrapper did not remove COLORTERM after child process"

    $env:GHOSTTY_SHELL_FEATURES = ''
    . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
    Assert-True ($null -eq (Get-Command ssh -CommandType Function -ErrorAction SilentlyContinue)) "ssh wrapper was not removed when ssh features were disabled"

    $capture = [System.IO.StringWriter]::new()
    [Console]::SetOut($capture)
    $promptText = (prompt | Out-String)
    [Console]::Out.Flush()
    $osc = $capture.ToString()

    Assert-True ($osc.Contains("]133;D;0;aid=$PID")) "Prompt output missing OSC 133 D aid metadata"
    Assert-True ($osc.Contains(']7;file://')) "Prompt output missing OSC 7 cwd"
    Assert-True ($osc.Contains("]133;A;cl=line;aid=$PID;redraw=0")) "Prompt output missing OSC 133 A prompt metadata (redraw=0)"
    Assert-True ($osc.Contains(']133;B')) "Prompt output missing OSC 133 B marker"
    Assert-True ($promptText.Contains('NOCTTYPROBE> ')) "Wrapped prompt dropped the user's prompt text: $promptText"

    [Console]::SetOut($script:OriginalOut)

    # ── OSC 133 C rides on PSReadLine's AddToHistoryHandler ──────────────
    #
    # It used to ride on `CommandValidationHandler`, which PSReadLine invokes
    # only from its `ValidateAndAcceptLine` function. The default Enter
    # binding on both pwsh 7 and Windows PowerShell 5.1 is `AcceptLine`, so
    # that hook never fired for a user who had not rebound Enter and no OSC
    # 133 C was emitted at all. `AddToHistoryHandler` runs for every accepted
    # line whatever Enter is bound to, and runs before the host executes it.
    #
    # PSReadLine is not auto-loaded in a non-interactive host, so the module
    # has to be imported explicitly here; that is also why every dot-source
    # above installed no handler. Driving a real Enter keypress needs a real
    # console, so this exercises the registered handler object directly --
    # `(Get-PSReadLineOption).AddToHistoryHandler` is exactly what PSReadLine
    # itself calls.
    if ($null -ne (Get-Module PSReadLine -ListAvailable | Select-Object -First 1)) {
        Import-Module PSReadLine -ErrorAction Stop
        $script:PSReadLineImported = $true
        $script:OriginalAddToHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler

        # PSReadLine ships its own handler (the sensitive-history scrubber) on
        # both 2.0.x and 2.4.x, so there is always something to chain to and
        # an unchained override would silently start writing secrets to the
        # history file.
        Assert-True ($null -ne $script:OriginalAddToHistoryHandler) "PSReadLine was expected to ship a default AddToHistoryHandler"

        # Stand in for a profile that installed its own handler.
        $Global:__noctty_test_handler_lines = New-Object System.Collections.ArrayList
        Set-PSReadLineOption -AddToHistoryHandler {
            param([string]$Line)
            [void]$Global:__noctty_test_handler_lines.Add($Line)
            return [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly
        }
        $userHandler = (Get-PSReadLineOption).AddToHistoryHandler
        Assert-True ($null -ne $userHandler) "Test handler was not registered"

        . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
        $nocttyHandler = (Get-PSReadLineOption).AddToHistoryHandler
        Assert-True (-not [object]::ReferenceEquals($nocttyHandler, $userHandler)) "Integration did not install its own AddToHistoryHandler"

        # ── Replayed history line ───────────────────────────────────────
        #
        # PSReadLine 2.0.0 (Windows PowerShell 5.1) calls AddToHistoryHandler
        # for every line it replays out of the on-disk history file, not only
        # for lines the user accepts -- measured at 1790 invocations before a
        # keypress on a fresh session, plus lines other live sessions append.
        # Those must produce no OSC 133 C, and must still reach the chained
        # handler: suppressing the terminal report may not change the history
        # decision. A non-interactive host has an empty PSReadLine buffer, so
        # this invocation IS the replay shape.
        $replayCapture = [System.IO.StringWriter]::new()
        [Console]::SetOut($replayCapture)
        $replayResult = $nocttyHandler.Invoke('Get-Date')
        [Console]::Out.Flush()
        [Console]::SetOut($script:OriginalOut)
        $replayOsc = $replayCapture.ToString()

        Assert-True (-not $replayOsc.Contains(']133;C')) "A replayed history line emitted OSC 133 C: $($replayOsc -replace [char]27, '<ESC>')"
        Assert-True ($Global:__noctty_test_handler_lines.Count -eq 1) "A replayed history line did not reach the chained handler"
        Assert-True ($replayResult -eq [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly) "A replayed history line did not return the chained result: $replayResult"

        # The discriminator itself: PSReadLine's buffer must equal the line.
        Assert-True (-not (__ghostty_line_is_being_accepted 'Get-Date')) "Discriminator accepted a line that is not in PSReadLine's buffer"
        Assert-True (-not (__ghostty_line_is_being_accepted '')) "Discriminator matched an empty line against an empty buffer"

        # ── Accepted line ───────────────────────────────────────────────
        #
        # A non-interactive host cannot put text in PSReadLine's buffer --
        # `[Microsoft.PowerShell.PSConsoleReadLine]::Insert` throws
        # NullReferenceException with no console attached, on both hosts -- so
        # the accept shape is produced by overriding the discriminator. The
        # real one is exercised directly above; everything below is about what
        # the handler does once it has decided a line was accepted.
        function global:__ghostty_line_is_being_accepted {
            param([AllowNull()][string]$Line)
            return $true
        }

        $handlerCapture = [System.IO.StringWriter]::new()
        [Console]::SetOut($handlerCapture)
        $handlerResult = $nocttyHandler.Invoke("Get-ChildItem 'a;b'")
        [Console]::Out.Flush()
        [Console]::SetOut($script:OriginalOut)
        $handlerOsc = $handlerCapture.ToString()

        Assert-True ($handlerOsc.Contains("]133;C;aid=$PID;cmdline_url=Get-ChildItem%20%27a%3Bb%27")) "AddToHistoryHandler did not emit OSC 133 C with URL-encoded cmdline: $($handlerOsc -replace [char]27, '<ESC>')"
        Assert-True ($Global:__noctty_test_handler_lines.Count -eq 2) "Pre-existing AddToHistoryHandler was not chained"
        Assert-True ($Global:__noctty_test_handler_lines[1] -eq "Get-ChildItem 'a;b'") "Chained handler received the wrong line: $($Global:__noctty_test_handler_lines[1])"
        # The chained handler's answer must reach PSReadLine unchanged, or the
        # user's history policy silently changes -- PSReadLine's own default
        # handler is the sensitive-history scrubber. A scriptblock-derived
        # Func[string, object] returns the block's whole output collection, so
        # this also catches a stray value on our handler's pipeline.
        Assert-True ($handlerResult -is [Microsoft.PowerShell.AddToHistoryOption]) "Chained handler result was reshaped: $($handlerResult.GetType().FullName)"
        Assert-True ($handlerResult -eq [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly) "Chained handler result was not returned unchanged: $handlerResult"

        # ── Re-source ───────────────────────────────────────────────────
        #
        # We must rebind to the SAVED original rather than chain to ourselves,
        # or every accepted line would emit 133;C once per source.
        . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
        $resourcedHandler = (Get-PSReadLineOption).AddToHistoryHandler
        function global:__ghostty_line_is_being_accepted {
            param([AllowNull()][string]$Line)
            return $true
        }

        $resourceCapture = [System.IO.StringWriter]::new()
        [Console]::SetOut($resourceCapture)
        $resourcedResult = $resourcedHandler.Invoke('Get-Date')
        [Console]::Out.Flush()
        [Console]::SetOut($script:OriginalOut)
        $resourcedOsc = $resourceCapture.ToString()

        $cMarks = [regex]::Matches($resourcedOsc, [regex]::Escape(']133;C')).Count
        Assert-True ($cMarks -eq 1) "Re-sourcing stacked the AddToHistoryHandler: $cMarks OSC 133 C marks for one line"
        Assert-True ($Global:__noctty_test_handler_lines.Count -eq 3) "Re-sourced handler called the chained handler $($Global:__noctty_test_handler_lines.Count - 2) times for one line"
        Assert-True ($Global:__noctty_test_handler_lines[2] -eq 'Get-Date') "Re-sourced handler passed the wrong line on: $($Global:__noctty_test_handler_lines[2])"
        Assert-True ($resourcedResult -eq [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly) "Re-sourced handler did not return the chained result unchanged: $resourcedResult"

        # ── A predecessor that throws must fail CLOSED ──────────────────
        #
        # The predecessor is PSReadLine's sensitive-history scrubber unless a
        # profile replaced it, so answering `$true` (== MemoryAndFile) when it
        # throws would write to the on-disk history file a line it may have
        # been about to hold back. MemoryOnly keeps the line usable in the
        # session without persisting it.
        Set-PSReadLineOption -AddToHistoryHandler {
            param([string]$Line)
            throw 'predecessor exploded'
        }
        . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
        $throwingChainHandler = (Get-PSReadLineOption).AddToHistoryHandler
        function global:__ghostty_line_is_being_accepted {
            param([AllowNull()][string]$Line)
            return $true
        }

        $throwCapture = [System.IO.StringWriter]::new()
        [Console]::SetOut($throwCapture)
        $throwResult = $throwingChainHandler.Invoke('Connect-Thing -Token hunter2')
        [Console]::Out.Flush()
        [Console]::SetOut($script:OriginalOut)

        Assert-True ($throwResult -eq [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly) "A throwing chained handler must fail closed to MemoryOnly, got: $throwResult"
        Assert-True ($throwCapture.ToString().Contains(']133;C')) "A throwing chained handler suppressed the OSC 133 C mark"


        Remove-Variable -Name '__noctty_test_handler_lines' -Scope Global -ErrorAction SilentlyContinue
    }

    # ── Injected-block scope contract (issue #231) ───────────────────────
    #
    # Everything above dot-sources integration.ps1 at THIS script's scope,
    # where unqualified top-level definitions survive. noctty does not: it
    # runs `-NoExit -Command "& { $__ghostty_utf8_console = $false; . <path> }"`,
    # and that block's child scope is torn down when the dot-source returns.
    # The helpers therefore have to be `global:`-qualified or every prompt
    # draw throws CommandNotFoundException, PowerShell silently substitutes
    # its built-in prompt, and no OSC is emitted at all.
    #
    # The block is intentional and stays: a child scope shadows a
    # profile-defined `$__ghostty_utf8_console` even when the profile marked
    # it ReadOnly/Constant, which a global assignment cannot do. So this must
    # be verified against a real child process running the real argv.
    $psHost = (Get-Process -Id $PID).Path
    Assert-True (-not [string]::IsNullOrEmpty($psHost)) "Could not resolve the current PowerShell host path"

    $childQuotedPath = $script:IntegrationPath.Replace("'", "''")
    # The child echoes each stdin line back, so the success token must be
    # assembled at runtime; a literal would match its own echo and the
    # assertion would pass even when the helper is gone.
    $childInput = @(
        'if (Get-Command __ghostty_write_osc -ErrorAction SilentlyContinue) { "HELPER" + "-RESOLVED" }',
        'exit'
    )

    function Invoke-NocttyInjectedChild {
        param(
            [string]$Preamble,
            [string]$Postamble,
            [string[]]$Lines = $null,
            [switch]$WithoutPSReadLine
        )

        if ($null -eq $Lines) { $Lines = $script:ChildInput }
        # PSReadLine's ReadLine is unsupported when stdin is a pipe rather
        # than a console, and PowerShell records that failure in $Error once
        # per prompt. Children that read $Error have to drop it; see the
        # OSC 133 D cases below. `Ignore` rather than `SilentlyContinue` so
        # a child without PSReadLine does not start with a record of its own
        # in $Error.
        $prefix = if ($WithoutPSReadLine) {
            'Remove-Module PSReadLine -Force -ErrorAction Ignore; '
        } else { '' }
        $payload = $prefix + $Preamble +
            "function global:prompt { 'NOCTTYPROBE> ' }; " +
            "& { `$__ghostty_utf8_console = `$false; . '$childQuotedPath' }" +
            $Postamble
        # `2>&1` on a native command produces ErrorRecords. Under Windows
        # PowerShell 5.1 with $ErrorActionPreference = 'Stop' (set at the top
        # of this file) that throws a RemoteException instead of landing in
        # the captured output, which would turn any child stderr — exactly
        # the diagnostic we want to read — into an unrelated crash. pwsh 7
        # does not do this.
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            return ($Lines | & $script:PsHost -NoProfile -NoExit -Command $payload 2>&1 | Out-String)
        } finally {
            $ErrorActionPreference = $saved
        }
    }

    $script:PsHost = $psHost
    $script:ChildInput = $childInput

    # Case 1: the plain injected launch.
    # Case 2: the same launch under a profile that enabled Set-StrictMode.
    # StrictMode turns a read of an unset variable into a TERMINATING error,
    # and both our own state globals and the built-in $LASTEXITCODE are
    # legitimately unset on the first draw — which killed `prompt` outright
    # and reproduced the #231 symptom from a second, independent cause.
    foreach ($case in @(
        @{ Name = 'plain'; Preamble = '' }
        @{ Name = 'Set-StrictMode -Version Latest'; Preamble = 'Set-StrictMode -Version Latest; ' }
    )) {
        $childOut = Invoke-NocttyInjectedChild -Preamble $case.Preamble
        $shown = $childOut -replace [char]27, '<ESC>'
        $where = "[$($case.Name)]"

        Assert-True ($childOut.Contains('HELPER-RESOLVED')) "$where Helper functions did not survive the injected & { } block: $shown"
        Assert-True ($childOut.Contains('NOCTTYPROBE> ')) "$where Injected block replaced the user's prompt: $shown"
        # PowerShell swallows a throw from `prompt` without writing anything,
        # so these error patterns only catch load-time and StrictMode
        # failures; the marker and OSC assertions cover a prompt-draw
        # failure. pwsh 7 says "as a name of a cmdlet", 5.1 says "as the
        # name of a cmdlet"; match the common prefix.
        Assert-True (-not ($childOut -match 'is not recognized as')) "$where Injected block raised CommandNotFoundException: $shown"
        Assert-True (-not ($childOut -match 'cannot be retrieved because it has not been set')) "$where Injected block read an unset variable: $shown"
        foreach ($marker in @(']133;A;cl=line;aid=', ']133;B', ']133;D;', ']7;file://')) {
            Assert-True ($childOut.Contains($marker)) "$where Injected block emitted no $marker : $shown"
        }
    }

    # The exit-status logic must survive the StrictMode rewrite: a fresh
    # native exit code still has to reach OSC 133;D, and a clean draw must
    # still report 0. Reading $LASTEXITCODE through Get-Variable is the part
    # that could silently have broken this.
    $nativeOut = Invoke-NocttyInjectedChild `
        -Preamble 'Set-StrictMode -Version Latest; ' `
        -Lines @('cmd /c exit 7', 'exit')
    $nativeShown = $nativeOut -replace [char]27, '<ESC>'
    Assert-True ($nativeOut.Contains(']133;D;0;')) "First prompt draw did not report exit 0 under StrictMode: $nativeShown"
    Assert-True ($nativeOut.Contains(']133;D;7;')) "Native exit code did not reach OSC 133 D under StrictMode: $nativeShown"

    # ── A user's own `ssh` must survive a launch that installs no wrapper ──
    #
    # The profile runs BEFORE noctty's injected -Command, so a
    # `function ssh { ... }` the user defined there is already in the global
    # scope when we load. The old unconditional
    # `Remove-Item -Path Function:\ssh,Function:\global:ssh` deleted it on
    # every launch, feature or not, and `Function:\global:ssh` is not a valid
    # provider path so the same line pushed two ItemNotFoundException records
    # into `$Error` (measured: `$Error.Count` 0 -> 2 on both hosts).
    #
    # Run in a real child so the preamble's `ssh` is a genuine pre-existing
    # global rather than a leftover of this harness's own state.
    # `$Error.Count` is sampled in the postamble, immediately after the
    # dot-source returns. Sampling it from a stdin line instead would also
    # count the host's own `PSConsoleReadLine::ReadLine ... Specified method is
    # not supported` record, which this harness provokes by piping stdin into
    # an interactive host and which has nothing to do with the script.
    $userSshOut = Invoke-NocttyInjectedChild `
        -Preamble 'function global:ssh { ''USER-SSH-PRESERVED'' }; $Error.Clear(); ' `
        -Postamble '; $Global:__noctty_load_errors = $Error.Count' `
        -Lines @(
            '"ERR" + "COUNT=" + $Global:__noctty_load_errors',
            'if ((ssh) -eq "USER-SSH-PRESERVED") { "USER" + "-SSH-SURVIVED" }',
            'exit'
        )
    $userSshShown = $userSshOut -replace [char]27, '<ESC>'
    Assert-True ($userSshOut.Contains('USER-SSH-SURVIVED')) "Loading with no ssh-* feature destroyed the user's own ssh function: $userSshShown"
    Assert-True ($userSshOut.Contains('ERRCOUNT=0')) "Loading polluted `$Error: $userSshShown"

    # With the feature on we DO install a wrapper, and it must be ours rather
    # than the user's function left in place.
    $wrapperOut = Invoke-NocttyInjectedChild `
        -Preamble "`$env:GHOSTTY_SHELL_FEATURES = 'ssh-env'; `$Error.Clear(); " `
        -Postamble '; $Global:__noctty_load_errors = $Error.Count' `
        -Lines @(
            '"ERR" + "COUNT=" + $Global:__noctty_load_errors',
            'if (([string](Get-Command ssh -CommandType Function).ScriptBlock).Contains("__ghostty_ssh_wrapper_marker")) { "WRAPPER" + "-INSTALLED" }',
            'exit'
        )
    $wrapperShown = $wrapperOut -replace [char]27, '<ESC>'
    Assert-True ($wrapperOut.Contains('WRAPPER-INSTALLED')) "ssh-env did not install the noctty ssh wrapper in a real child: $wrapperShown"
    Assert-True ($wrapperOut.Contains('ERRCOUNT=0')) "Installing the ssh wrapper polluted `$Error: $wrapperShown"

    # ── OSC 133 D disambiguation (CodeRabbit on #237) ────────────────────
    #
    # Comparing $LASTEXITCODE against the previous prompt's snapshot cannot
    # tell a repeated native failure from a cmdlet failure that followed a
    # native one: both leave $? false and $LASTEXITCODE untouched. `cmd /c
    # exit 5` run twice used to mark D;5 and then D;1. `prompt` now also
    # consults the head of $Error, and each case below pins one arm of that
    # decision on the real injected argv.
    #
    # PSReadLine must be unloaded in these children, and only in these. Its
    # ReadLine throws NotSupportedException when stdin is a pipe instead of
    # a console, and PowerShell records that MethodInvocationException in
    # $Error once PER PROMPT — landing between our end-of-prompt snapshot
    # and the user's next command, which is exactly the window the signal
    # reads. A real noctty session is a ConPTY, where PSReadLine reads fine
    # and records nothing; measured through a live pseudo console on both
    # hosts, every sequence below holds with PSReadLine loaded. Asserting
    # the piped-stdin behaviour instead would pin an artifact of the rig.
    foreach ($case in @(
        # The regression: the second failure must still report 5, not 1.
        @{ Name = 'repeated native failure'
           Pre = ''
           Lines = @('cmd /c exit 5', 'cmd /c exit 5')
           Expect = @(0, 5, 5) }
        # The behaviour that forced the old stale-code rule: a cmdlet
        # failure must not inherit the native code lying around.
        @{ Name = 'cmdlet failure after native failure'
           Pre = ''
           Lines = @('cmd /c exit 5', 'Get-Item C:\nope')
           Expect = @(0, 5, 1) }
        @{ Name = 'native success after native failure'
           Pre = ''
           Lines = @('cmd /c exit 5', 'cmd /c exit 0')
           Expect = @(0, 5, 0) }
        @{ Name = 'throw after native failure'
           Pre = ''
           Lines = @('cmd /c exit 5', "throw 'x'")
           Expect = @(0, 5, 1) }
        @{ Name = 'successful cmdlet after native failure'
           Pre = ''
           Lines = @('cmd /c exit 5', 'Get-Date | Out-Null')
           Expect = @(0, 5, 0) }
        # Reading $Error and indexing it must stay StrictMode-safe.
        @{ Name = 'native failure under StrictMode'
           Pre = 'Set-StrictMode -Version Latest; '
           Lines = @('cmd /c exit 7')
           Expect = @(0, 7) }
        # `$Error.Clear()` empties the ArrayList, so the head goes null
        # rather than changing. That is "nothing new failed", not "a
        # PowerShell error happened", and `$Error[0]` must not be indexed.
        @{ Name = 'repeated native failure across $Error.Clear()'
           Pre = ''
           Lines = @('cmd /c exit 5', '$Error.Clear()', 'cmd /c exit 5')
           Expect = @(0, 5, 0, 5) }
        # A failure deserialized out of a job carries a RemoteException,
        # which is also the exception on the `NativeCommandError` record
        # Windows PowerShell 5.1 makes from a native command's redirected
        # stderr. Classifying by exception type alone therefore called this
        # native and re-reported 5; the FullyQualifiedErrorId here is the
        # job's own (`x`), so it must stay a PowerShell-level failure.
        @{ Name = 'job failure after native failure'
           Pre = ''
           Lines = @('cmd /c exit 5', "Start-Job { throw 'x' } | Wait-Job | Receive-Job")
           Expect = @(0, 5, 1) }
        # `$ErrorActionPreference = 'Stop'` makes PowerShell push an
        # ActionPreferenceStopException AHEAD of the record it stopped on,
        # and it is not an ErrorRecord. With
        # $PSNativeCommandUseErrorActionPreference also on, that wrapper is
        # what hides the ProgramExitedWithNonZeroCode underneath it, so the
        # classifier has to unwrap `.ErrorRecord` or a repeated native
        # failure reports 1 again. (5.1 has no such preference; the
        # assignment is inert there and the case still exercises `Stop`.)
        @{ Name = 'repeated native failure under ErrorActionPreference Stop'
           Pre = '$PSNativeCommandUseErrorActionPreference = $true; $ErrorActionPreference = ''Stop''; '
           Lines = @('cmd /c exit 5', 'cmd /c exit 5')
           Expect = @(0, 5, 5) }
        # StrictMode AND an empty $Error at the same time: `$Error[0]` is an
        # out-of-range ArrayList index there, which StrictMode 3.0+ turns
        # into a terminating error. `__ghostty_error_head` catches it, so
        # the marks alone cannot see the missing `.Count` guard — but the
        # caught exception is itself recorded, so the count can. The last
        # line reports what the user would see; the token is assembled at
        # runtime so it cannot match the child's echo of the line itself.
        @{ Name = 'prompt leaves $Error alone under StrictMode'
           Pre = 'Set-StrictMode -Version Latest; '
           Lines = @('cmd /c exit 5', '$Error.Clear()', 'cmd /c exit 5',
                     '("ERR" + "COUNT=") + $Error.Count')
           Expect = @(0, 5, 0, 5, 0)
           ErrorCount = 0 }
    )) {
        $childOut = Invoke-NocttyInjectedChild `
            -Preamble $case.Pre `
            -Lines (@($case.Lines) + @('exit')) `
            -WithoutPSReadLine
        $shown = $childOut -replace [char]27, '<ESC>'
        $marks = @([regex]::Matches($childOut, ']133;D;(\d+);') |
            ForEach-Object { [int]$_.Groups[1].Value })
        $where = "[$($case.Name)]"
        Assert-True ((($marks) -join ',') -eq (($case.Expect) -join ',')) `
            "$where OSC 133 D sequence was $($marks -join ','), expected $($case.Expect -join ','): $shown"
        Assert-True ($childOut.Contains('NOCTTYPROBE> ')) "$where Injected block replaced the user's prompt: $shown"
        if ($case.ContainsKey('ErrorCount')) {
            $counted = [regex]::Match($childOut, 'ERRCOUNT=(\d+)')
            Assert-True ($counted.Success) "$where Child never reported the error count: $shown"
            Assert-True ([int]$counted.Groups[1].Value -eq $case.ErrorCount) `
                "$where Prompt left $($counted.Groups[1].Value) record(s) in the child's error list, expected $($case.ErrorCount): $shown"
        }
    }

    Write-Output 'PASS powershell shell integration'
} finally {
    [Console]::SetOut($script:OriginalOut)
    Pop-Location -ErrorAction SilentlyContinue
    $function:global:prompt = $script:OriginalPrompt
    if ($script:PSReadLineImported) {
        Set-PSReadLineOption -AddToHistoryHandler $script:OriginalAddToHistoryHandler
    }
    if ($null -eq $script:OriginalFeatures) {
        Remove-Item Env:GHOSTTY_SHELL_FEATURES -ErrorAction SilentlyContinue
    } else {
        $env:GHOSTTY_SHELL_FEATURES = $script:OriginalFeatures
    }
    Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
