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
# until the history-handler section below imports the module itself.
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

    # ── The prompt: D / OSC 7 / A written directly, B in the returned text ─
    #
    # The host draws the string `prompt` returns only AFTER it returns, so a
    # B written directly lands ahead of the whole visible prompt and the
    # terminal records the prompt's cells as input. B rides at the end of the
    # returned string instead.
    function Invoke-TestPrompt {
        # Returns what the host would draw, and what went straight to the
        # console while it ran.
        $capture = [System.IO.StringWriter]::new()
        [Console]::SetOut($capture)
        try {
            $text = prompt
        } finally {
            [Console]::Out.Flush()
            [Console]::SetOut($script:OriginalOut)
        }
        return [pscustomobject]@{ Text = $text; Osc = $capture.ToString() }
    }
    $B = "$([char]27)]133;B$([char]7)"
    $A = "]133;A;cl=line;aid=$PID;redraw=0"

    $drawn = Invoke-TestPrompt
    # A generated function, not an alias: `Get-Command prompt` stays a
    # Function as about_Prompts documents, and PSReadLine sees a prompt that
    # calls a command, so it derives no PromptText to repaint after B.
    Assert-True ((Get-Command prompt).CommandType -eq 'Function') "prompt is not a function: $((Get-Command prompt).CommandType)"
    Assert-True (__ghostty_prompt_is_ours $function:global:prompt) "The integration did not wrap the prompt"
    Assert-True ($drawn.Osc.Contains("]133;D;0;aid=$PID")) "Prompt output missing OSC 133 D aid metadata"
    Assert-True ($drawn.Osc.Contains(']7;file://')) "Prompt output missing OSC 7 cwd"
    Assert-True ($drawn.Osc.Contains($A)) "Prompt output missing OSC 133 A prompt metadata (redraw=0)"
    Assert-True (-not $drawn.Osc.Contains(']133;B')) "OSC 133 B was written directly, ahead of the prompt text: $($drawn.Osc -replace [char]27, '<ESC>')"
    Assert-True ($drawn.Text -ceq "NOCTTYPROBE> $B") "The returned prompt is not the user's text followed by B: $($drawn.Text -replace [char]27, '<ESC>')"

    $savedPrompt = $function:global:prompt
    try {
        # What the host draws for the odd returns, measured on both hosts:
        # only the first object, and `PS>` for an empty string or no output
        # at all. B has to follow exactly that text. `__ghostty_wrap_prompt`
        # is what the line reader runs before each line, so a prompt defined
        # here is wrapped the way a prompt defined at the command line would
        # be.
        #
        # A prompt that returns several objects passes through untouched and
        # gets B written directly instead: PSReadLine's InvokePrompt (Ctrl+L,
        # transient prompts) draws `PS>` for it, so a B appended to the first
        # object would never reach the screen after a repaint.
        function global:prompt { 'first> '; 'second> ' }
        __ghostty_wrap_prompt
        $multiDrawn = Invoke-TestPrompt
        $multi = @($multiDrawn.Text)
        Assert-True ($multi.Count -eq 2 -and $multi[0] -ceq 'first> ' -and $multi[1] -ceq 'second> ') "A multi-object prompt was reshaped: $($multi -join '|')"
        Assert-True ($multiDrawn.Osc.Contains(']133;B')) "A multi-object prompt got no B written directly: $($multiDrawn.Osc -replace [char]27, '<ESC>')"

        function global:prompt { '' }
        __ghostty_wrap_prompt
        Assert-True ((Invoke-TestPrompt).Text -ceq "PS>$B") "An empty prompt did not become the host's PS> followed by B"

        function global:prompt { }
        __ghostty_wrap_prompt
        Assert-True ((Invoke-TestPrompt).Text -ceq "PS>$B") "A prompt with no output did not become the host's PS> followed by B"

        # A non-string is drawn with its own ToString(); leave it alone and
        # write B directly, as before.
        function global:prompt { 42 }
        __ghostty_wrap_prompt
        $numeric = Invoke-TestPrompt
        Assert-True ($numeric.Text -is [int] -and $numeric.Text -eq 42) "A non-string prompt was reshaped: $($numeric.Text)"
        Assert-True ($numeric.Osc.EndsWith($B)) "A non-string prompt got no B"

        # A ReadOnly prompt cannot be wrapped. The line reader tries before
        # every line, and it must neither put an error in $Error each time
        # nor use up a wrapper id per attempt.
        Microsoft.PowerShell.Management\Set-Item -Path 'function:prompt' -Value { 'LOCKED> ' } -Options ReadOnly -Force
        try {
            # Set-Item on the function drive changes the existing global prompt
            # in place rather than shadowing it in script scope; make sure.
            Assert-True ((& ${function:global:prompt}) -ceq 'LOCKED> ') "The ReadOnly test prompt is not the global prompt"
            $countBefore = $Global:__ghostty_prompt_count
            $errorsBefore = $Error.Count
            __ghostty_wrap_prompt
            __ghostty_wrap_prompt
            $lockedErrors = $Error.Count - $errorsBefore
            $lockedIds = $Global:__ghostty_prompt_count - $countBefore
            $lockedText = (Invoke-TestPrompt).Text
        } finally {
            Microsoft.PowerShell.Management\Remove-Item -Path 'function:prompt' -Force
        }
        Assert-True ($lockedErrors -eq 0) "Wrapping a ReadOnly prompt added $lockedErrors record(s) to `$Error"
        Assert-True ($lockedIds -eq 0) "Wrapping a ReadOnly prompt used up $lockedIds wrapper id(s)"
        Assert-True ($lockedText -ceq 'LOCKED> ') "A ReadOnly prompt was not left as it is: $lockedText"

        # A prompt replaced after load (`. $PROFILE`, a theme re-init) is
        # drawn once as it is, then wrapped again before the next line.
        function global:prompt { 'REPLACED> ' }
        $unwrapped = Invoke-TestPrompt
        Assert-True ($unwrapped.Text -ceq 'REPLACED> ' -and $unwrapped.Osc.Length -eq 0) "A replaced prompt was not drawn as-is"
        __ghostty_wrap_prompt
        $rewrapped = Invoke-TestPrompt
        Assert-True ($rewrapped.Text -ceq "REPLACED> $B") "A replaced prompt was not wrapped again: $($rewrapped.Text -replace [char]27, '<ESC>')"
        Assert-True ($rewrapped.Osc.Contains($A)) "A re-wrapped prompt lost the A mark"
        $sameWrapper = $function:global:prompt
        __ghostty_wrap_prompt
        Assert-True ([object]::ReferenceEquals($sameWrapper, $function:global:prompt)) "Wrapping an already wrapped prompt replaced it again"

        # Chaining to the prompt by value, the way about_Prompts shows how to
        # get it, and the way a venv's Activate.ps1 saves and restores it:
        # the copy of our wrapper runs nested inside the new wrapper and
        # passes straight through, so exactly one D / A pair is written.
        function global:prompt { 'BASE> ' }
        __ghostty_wrap_prompt
        $Global:__noctty_test_chained = (Get-Command prompt).ScriptBlock
        function global:prompt { 'W:' + (& $Global:__noctty_test_chained) }
        __ghostty_wrap_prompt
        $chained = Invoke-TestPrompt
        Assert-True ($chained.Text -ceq "W:BASE> $B") "A prompt chained through Get-Command was drawn wrong: $($chained.Text -replace [char]27, '<ESC>')"
        Assert-True ([regex]::Matches($chained.Osc, [regex]::Escape($A)).Count -eq 1) "A chained prompt wrote the A mark more than once"

        function global:_OLD_VIRTUAL_PROMPT { '' }
        Copy-Item -Path function:prompt -Destination function:_OLD_VIRTUAL_PROMPT
        function global:prompt { '(venv) ' + (_OLD_VIRTUAL_PROMPT) }
        __ghostty_wrap_prompt
        $venv = Invoke-TestPrompt
        Assert-True ($venv.Text -ceq "(venv) W:BASE> $B") "An activated venv prompt was drawn wrong: $($venv.Text -replace [char]27, '<ESC>')"
        Assert-True ([regex]::Matches($venv.Osc, [regex]::Escape($A)).Count -eq 1) "An activated venv prompt wrote the A mark more than once"
        Copy-Item -Path function:_OLD_VIRTUAL_PROMPT -Destination function:prompt
        __ghostty_wrap_prompt
        Assert-True ((Invoke-TestPrompt).Text -ceq "W:BASE> $B") "Deactivating the venv did not restore the prompt"
        Remove-Item -LiteralPath 'Function:\_OLD_VIRTUAL_PROMPT' -Force

        # The user's prompt sees the $? their command left, not ours:
        # Starship and oh-my-posh read it first thing for their status.
        function global:prompt { "Q=$?> " }
        __ghostty_wrap_prompt
        [Console]::SetOut([System.IO.StringWriter]::new())
        Get-Item -LiteralPath (Join-Path $script:TempDir 'nope-not-here') -ErrorAction SilentlyContinue
        $afterFailure = prompt
        Get-Date | Out-Null
        $afterSuccess = prompt
        [Console]::SetOut($script:OriginalOut)
        Assert-True ($afterFailure -ceq "Q=False> $B") "The user's prompt did not see `$? false after a failure: $afterFailure"
        Assert-True ($afterSuccess -ceq "Q=True> $B") "The user's prompt did not see `$? true after a success: $afterSuccess"
    } finally {
        [Console]::SetOut($script:OriginalOut)
        Remove-Variable -Name '__noctty_test_chained' -Scope Global -ErrorAction Ignore
        $function:global:prompt = $savedPrompt
    }

    # ── B and C come from the line reader ────────────────────────────────
    #
    # The console host reads each line by running the command
    # `PSConsoleHostReadLine`, which PSReadLine defines. The integration's
    # alias of that name calls whatever function is there. Before it does, the
    # host has drawn the prompt, so it writes B there, where input really
    # begins; once the line is accepted it writes C. That covers a line equal
    # to the previous history entry, which PSReadLine keeps away from
    # AddToHistoryHandler (the hook C used to ride on), and never fires for
    # history replay.
    #
    # A non-interactive host cannot run PSReadLine's real ReadLine, so a
    # stand-in function of that name returns the line. What PSReadLine does
    # with a live console is covered by the pseudo-console recordings.
    Assert-True ((Get-Command PSConsoleHostReadLine -ErrorAction SilentlyContinue).CommandType -eq 'Alias') "PSConsoleHostReadLine is not hooked through an alias"
    $Global:__noctty_test_status = New-Object System.Collections.ArrayList
    $Global:__noctty_test_repaint = $null
    function global:PSConsoleHostReadLine {
        [void]$Global:__noctty_test_status.Add($?)
        # Stands in for PSReadLine's InvokePrompt (Ctrl+L, a transient
        # prompt), which runs `prompt` while the line is being read.
        if ($Global:__noctty_test_repaint) { $Global:__noctty_test_repaint = prompt }
        return $Global:__noctty_test_next_line
    }
    function Invoke-TestReadLine {
        # -AsHost: the host runs the reader with nothing else on the call
        # stack (one frame per nested prompt level on top), which is how the
        # reader tells the host's read from a script calling it. This call
        # sits under this script and this function, so raise the level to
        # match; without the switch it is a script calling the reader.
        param([string]$Line, [switch]$AfterFailure, [switch]$Repaint, [switch]$AsHost)
        $Global:__noctty_test_next_line = $Line
        $Global:__noctty_test_repaint = [bool]$Repaint
        $savedLevel = $global:NestedPromptLevel
        $capture = [System.IO.StringWriter]::new()
        [Console]::SetOut($capture)
        try {
            if ($AsHost) { $global:NestedPromptLevel = @(Get-PSCallStack).Count }
            if ($AfterFailure) {
                Get-Item -LiteralPath (Join-Path $script:TempDir 'nope-not-here') -ErrorAction SilentlyContinue
            }
            $returned = PSConsoleHostReadLine
        } finally {
            $global:NestedPromptLevel = $savedLevel
            [Console]::Out.Flush()
            [Console]::SetOut($script:OriginalOut)
        }
        return [pscustomobject]@{ Returned = $returned; Osc = $capture.ToString() }
    }
    $C = "$([char]27)]133;C;aid=$PID"

    # With a line reader to hook, the prompt returns exactly the user's
    # text: a transcript records that string, so B stays out of it. The
    # reader then writes B after the drawn prompt, and nothing else when the
    # prompt was ours.
    $drawn = Invoke-TestPrompt
    Assert-True ($drawn.Text -ceq 'NOCTTYPROBE> ') "The prompt returned more than the user's text: $($drawn.Text -replace [char]27, '<ESC>')"
    Assert-True ($drawn.Osc.Contains($A) -and -not $drawn.Osc.Contains(']133;B')) "The prompt wrote B itself: $($drawn.Osc -replace [char]27, '<ESC>')"
    $read = Invoke-TestReadLine "Get-ChildItem 'a;b'"
    Assert-True ($read.Returned -ceq "Get-ChildItem 'a;b'") "The line reader changed the line: $($read.Returned)"
    Assert-True ($read.Osc -ceq "$B${C};cmdline_url=Get-ChildItem%20%27a%3Bb%27$([char]7)") "The line reader did not write exactly B, then one C: $($read.Osc -replace [char]27, '<ESC>')"

    # A prompt that is not ours was drawn without D, cwd or A. The reader
    # gives it OSC 7 and a P mark with redraw=0 before its B (P does not
    # fresh-line, so the cursor stays where the prompt ended), and wraps it
    # for the next prompt.
    function global:prompt { 'REPLACED> ' }
    [void](Invoke-TestPrompt)
    # A script that calls the reader itself gets no reader marks for an
    # unmarked prompt: written into its running command, a B would end it
    # and make the answer typed at the script the terminal's last command.
    $direct = Invoke-TestReadLine 'answer'
    Assert-True (-not ($direct.Osc -match '\]133;[PB]|\]7;')) "A script's own call to the reader got prompt marks: $($direct.Osc -replace [char]27, '<ESC>')"
    Assert-True ($direct.Osc.Contains(']133;C;')) "A script's own call to the reader lost its C"
    # The prompt is ours again now (that read wrapped it); replace it anew.
    function global:prompt { 'REPLACED> ' }
    [void](Invoke-TestPrompt)
    $unmarked = Invoke-TestReadLine 'Get-Date' -AsHost
    Assert-True ($unmarked.Osc -match "^$([char]27)\]7;file://[^$([char]7)]+$([char]7)$([char]27)\]133;P;k=i;redraw=0$([char]7)$([regex]::Escape($B))$([regex]::Escape($C))") "An unmarked prompt did not get OSC 7, P and B: $($unmarked.Osc -replace [char]27, '<ESC>')"
    Assert-True (__ghostty_prompt_is_ours $function:global:prompt) "The line reader did not wrap a replaced prompt"
    [void](Invoke-TestPrompt)
    $marked = Invoke-TestReadLine 'Get-Date'
    Assert-True ($marked.Osc.StartsWith("$B$C")) "A re-wrapped prompt still got a P mark: $($marked.Osc -replace [char]27, '<ESC>')"

    # A prompt drawn while the line is read is PSReadLine repainting it, and
    # nothing writes B after that repaint but the prompt itself. Afterwards
    # the next prompt is back to plain text.
    [void](Invoke-TestPrompt)
    $repainted = Invoke-TestReadLine 'Get-Date' -Repaint
    Assert-True ($Global:__noctty_test_repaint -ceq "REPLACED> $B") "A repaint did not carry its own B: $($Global:__noctty_test_repaint -replace [char]27, '<ESC>')"
    Assert-True ([regex]::Matches($repainted.Osc, '\]133;P').Count -eq 0) "A repaint turned the next line into an unmarked one"
    Assert-True ((Invoke-TestPrompt).Text -ceq 'REPLACED> ') "After a repaint the prompt still carries B"
    function global:prompt { 'NOCTTYPROBE> ' }
    __ghostty_wrap_prompt
    [void](Invoke-TestPrompt)

    $again = Invoke-TestReadLine "Get-ChildItem 'a;b'"
    Assert-True ($again.Osc.Contains(']133;C;')) "A repeated line got no OSC 133 C"
    foreach ($blank in @('', '   ', "`t")) {
        $none = Invoke-TestReadLine $blank
        Assert-True ($none.Returned -ceq $blank) "The line reader changed a blank line"
        Assert-True (-not $none.Osc.Contains(']133;C')) "A blank line emitted OSC 133 C: $($none.Osc -replace [char]27, '<ESC>')"
    }
    $multiLine = Invoke-TestReadLine "if (`$true) {`n  'x'`n}"
    Assert-True ($multiLine.Osc.Contains('cmdline_url=if%20%28%24true%29%20%7B%0A%20%20%27x%27%0A%7D') -or
        $multiLine.Osc.Contains('cmdline_url=if%20(%24true)%20%7B%0A%20%20%27x%27%0A%7D')) "A multi-line command did not produce one C with the whole line: $($multiLine.Osc -replace [char]27, '<ESC>')"
    # The terminal drops an OSC 133 mark longer than its 2048-byte buffer
    # whole, so a label that would not fit is left off and C still goes out.
    $quoted = Invoke-TestReadLine ('"' * 800)
    Assert-True ($quoted.Osc.EndsWith("$C$([char]7)")) "A line whose label would not fit did not get a bare C: $($quoted.Osc.Substring(0, [Math]::Min(80, $quoted.Osc.Length)))"
    $huge = Invoke-TestReadLine ('x' * 40000)
    Assert-True ($huge.Osc.EndsWith("$C$([char]7)")) "An oversized line did not get a C without its label: $($huge.Osc.Substring(0, [Math]::Min(80, $huge.Osc.Length)))"

    # PSReadLine's own PSConsoleHostReadLine reads $? first and hands it to
    # predictors as the previous command's status; ours must pass it on.
    $Global:__noctty_test_status.Clear()
    [void](Invoke-TestReadLine 'Get-Date')
    [void](Invoke-TestReadLine 'Get-Date' -AfterFailure)
    Assert-True (($Global:__noctty_test_status -join ',') -eq 'True,False') "The line reader did not pass `$? through: $($Global:__noctty_test_status -join ',')"

    # With no function of that name the host reads the line itself; called
    # by hand, the alias must produce nothing rather than an error. The
    # prompt then carries B itself, as in the checks further up.
    Remove-Item -LiteralPath 'Function:\PSConsoleHostReadLine' -Force
    $errorsBefore = $Error.Count
    $orphan = @(PSConsoleHostReadLine)
    Assert-True ($orphan.Count -eq 0 -and $Error.Count -eq $errorsBefore) "The line reader without PSConsoleHostReadLine produced output or an error"
    Assert-True ((Invoke-TestPrompt).Text -ceq "NOCTTYPROBE> $B") "Without a line reader the prompt did not carry B"

    # ── The user's history handler is not ours to touch ─────────────────
    #
    # PSReadLine is not auto-loaded in a non-interactive host, so import it.
    # Both 2.4.x and 2.0.x ship a default AddToHistoryHandler that keeps
    # credential-shaped lines out of the history file; loading the
    # integration must leave it, or any handler a profile set, as it was.
    if ($null -ne (Get-Module PSReadLine -ListAvailable | Select-Object -First 1)) {
        Import-Module PSReadLine -ErrorAction Stop
        $script:PSReadLineImported = $true
        $script:OriginalAddToHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler

        . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
        Assert-True ([object]::ReferenceEquals((Get-PSReadLineOption).AddToHistoryHandler, $script:OriginalAddToHistoryHandler)) "Loading the integration replaced PSReadLine's default AddToHistoryHandler"

        Set-PSReadLineOption -AddToHistoryHandler {
            param([string]$Line)
            return [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly
        }
        $userHandler = (Get-PSReadLineOption).AddToHistoryHandler
        . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
        Assert-True ([object]::ReferenceEquals((Get-PSReadLineOption).AddToHistoryHandler, $userHandler)) "Loading the integration replaced the profile's AddToHistoryHandler"

        # ── A session that already ran the previous version ─────────────
        #
        # That version replaced `function prompt` with a wrapper holding the
        # user's prompt in `$__ghostty_original_prompt`, and installed an
        # AddToHistoryHandler of its own. Loading this version over it must
        # put both back, or every mark would be doubled.
        $Global:__ghostty_original_prompt = { 'LEGACY-USER> ' }
        function global:prompt { & $Global:__ghostty_original_prompt }
        Set-PSReadLineOption -AddToHistoryHandler {
            param([string]$Line)
            return $true
        }
        $Global:__ghostty_addtohistory_handler = (Get-PSReadLineOption).AddToHistoryHandler
        $Global:__ghostty_addtohistory_original = $userHandler
        $errorsBefore = $Error.Count
        . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')
        Assert-True ($Error.Count -eq $errorsBefore) "Retiring the previous version's hooks pushed records into `$Error"
        Assert-True ([object]::ReferenceEquals((Get-PSReadLineOption).AddToHistoryHandler, $userHandler)) "The previous version's AddToHistoryHandler was not replaced by the one it had chained to"
        Assert-True (-not ([string]$function:global:prompt).Contains('__ghostty_original_prompt')) "The previous version's prompt wrapper was left in place"
        Assert-True (__ghostty_prompt_is_ours $function:global:prompt) "The user's prompt was not wrapped after retiring the previous version"
        foreach ($name in @('__ghostty_original_prompt', '__ghostty_addtohistory_handler', '__ghostty_addtohistory_original')) {
            Assert-True ($null -eq (Get-Variable -Name $name -Scope Global -ErrorAction Ignore)) "The previous version's `$$name was left behind"
        }
        [Console]::SetOut([System.IO.StringWriter]::new())
        $legacyPrompt = prompt
        [Console]::SetOut($script:OriginalOut)
        # PSReadLine is loaded here, so its PSConsoleHostReadLine is what
        # writes B; the prompt returns the user's text alone.
        Assert-True ($legacyPrompt -ceq 'LEGACY-USER> ') "The prompt after retiring the previous version is wrong: $($legacyPrompt -replace [char]27, '<ESC>')"
        $function:global:prompt = { 'NOCTTYPROBE> ' }
        __ghostty_wrap_prompt
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
        # The host drew the returned prompt, so B follows its text.
        Assert-True ($childOut -match "\]133;A;cl=line;aid=\d+;redraw=0$([char]7)NOCTTYPROBE> $([char]27)\]133;B$([char]7)") "$where The prompt was not drawn as A, prompt text, B: $shown"
    }

    # A prompt replaced after startup, the way `. $PROFILE` or a theme's
    # re-init does it, is drawn once as it is and wrapped again when the
    # next line is read. The host still calls the line reader with stdin
    # piped (PSReadLine then fails inside it and the host reads the pipe).
    $replacedOut = Invoke-NocttyInjectedChild -Lines @(
        "function global:prompt { 'RE' + 'PLACED> ' }",
        "'fil' + 'ler'",
        'exit'
    )
    $replacedShown = $replacedOut -replace [char]27, '<ESC>'
    $wrappedReplaced = [regex]::Matches($replacedOut, "\]133;A;cl=line;aid=\d+;redraw=0$([char]7)REPLACED> $([char]27)\]133;B$([char]7)").Count
    $allReplaced = [regex]::Matches($replacedOut, 'REPLACED> ').Count
    Assert-True ($allReplaced -eq 2 -and $wrappedReplaced -eq 1) "A prompt replaced after startup was not wrapped again from the next prompt (wrapped $wrappedReplaced of $allReplaced): $replacedShown"

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
    # The integration's hooks are global aliases; do not leave them behind in
    # a session that ran this harness, nor the stand-in line reader.
    foreach ($alias in @('prompt', 'PSConsoleHostReadLine')) {
        $installed = Get-Alias -Name $alias -Scope Global -ErrorAction Ignore
        if ($null -ne $installed -and $installed.Definition -like '__ghostty_*') {
            Remove-Item -LiteralPath "Alias:\$alias" -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Variable -Name '__noctty_test_status', '__noctty_test_next_line' -Scope Global -ErrorAction Ignore
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
