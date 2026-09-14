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
    Assert-True ($null -ne (Get-Command ssh -CommandType Function -ErrorAction SilentlyContinue)) "ssh wrapper was not installed"

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
    Assert-True ($osc.Contains("]133;A;cl=line;aid=$PID")) "Prompt output missing OSC 133 A prompt metadata"
    Assert-True ($osc.Contains(']133;B')) "Prompt output missing OSC 133 B marker"
    Assert-True ($promptText.Contains('NOCTTYPROBE> ')) "Wrapped prompt dropped the user's prompt text: $promptText"

    [Console]::SetOut($script:OriginalOut)

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
    $childPayload = "function global:prompt { 'NOCTTYPROBE> ' }; " +
        "& { `$__ghostty_utf8_console = `$false; . '$childQuotedPath' }"
    # The child echoes each stdin line back, so the success token must be
    # assembled at runtime; a literal would match its own echo and the
    # assertion would pass even when the helper is gone.
    $childInput = @(
        'if (Get-Command __ghostty_write_osc -ErrorAction SilentlyContinue) { "HELPER" + "-RESOLVED" }',
        'exit'
    )
    # `2>&1` on a native command produces ErrorRecords. Under Windows
    # PowerShell 5.1 with $ErrorActionPreference = 'Stop' (set at the top of
    # this file) that throws a RemoteException instead of landing in
    # $childOut, which would turn any child stderr — exactly the diagnostic
    # we want to read — into an unrelated crash. pwsh 7 does not do this.
    $childErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $childOut = ($childInput | & $psHost -NoProfile -NoExit -Command $childPayload 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $childErrorAction
    }

    Assert-True ($childOut.Contains('HELPER-RESOLVED')) "Helper functions did not survive the injected & { } block: $($childOut -replace [char]27, '<ESC>')"
    Assert-True ($childOut.Contains('NOCTTYPROBE> ')) "Injected block replaced the user's prompt: $($childOut -replace [char]27, '<ESC>')"
    # Load-time failures only. PowerShell swallows a throw from `prompt`
    # without writing anything, so this cannot see a prompt-draw failure —
    # the marker and OSC assertions are what cover that. pwsh 7 says "as a
    # name of a cmdlet", 5.1 says "as the name of a cmdlet"; match the
    # common prefix.
    Assert-True (-not ($childOut -match 'is not recognized as')) "Injected block raised CommandNotFoundException while loading: $($childOut -replace [char]27, '<ESC>')"
    foreach ($marker in @(']133;A;cl=line;aid=', ']133;B', ']133;D;', ']7;file://')) {
        Assert-True ($childOut.Contains($marker)) "Injected block emitted no $marker : $($childOut -replace [char]27, '<ESC>')"
    }

    Write-Output 'PASS powershell shell integration'
} finally {
    [Console]::SetOut($script:OriginalOut)
    Pop-Location -ErrorAction SilentlyContinue
    $function:global:prompt = $script:OriginalPrompt
    if ($null -eq $script:OriginalFeatures) {
        Remove-Item Env:GHOSTTY_SHELL_FEATURES -ErrorAction SilentlyContinue
    } else {
        $env:GHOSTTY_SHELL_FEATURES = $script:OriginalFeatures
    }
    Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
