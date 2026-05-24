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
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-ps-si-" + [guid]::NewGuid().ToString('n'))

try {
    New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
    $specialDir = Join-Path $script:TempDir 'a b#c%d&e+f'
    New-Item -ItemType Directory -Force -Path $specialDir | Out-Null
    Push-Location $specialDir

    function global:prompt { 'PS> ' }

    . (Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1')

    $cwdUri = __ghostty_encode_cwd_uri
    Assert-True ($cwdUri.StartsWith('file://')) "OSC 7 cwd URI must include file:// scheme"
    foreach ($encoded in @('%20', '%23', '%25', '%26', '%2B')) {
        Assert-True ($cwdUri.Contains($encoded)) "OSC 7 cwd URI missing encoded segment token $encoded in $cwdUri"
    }

    $encodedCommand = __ghostty_encode_osc133_value "Get-ChildItem 'a;b'"
    Assert-True ($encodedCommand -eq 'Get-ChildItem%20%27a%3Bb%27') "OSC 133 command metadata was not URL encoded: $encodedCommand"

    $env:GHOSTTY_SHELL_FEATURES = 'ssh-env,ssh-terminfo'
    Assert-True (__ghostty_has_feature 'ssh-env') "ssh-env feature was not detected"
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

    $capture = [System.IO.StringWriter]::new()
    [Console]::SetOut($capture)
    prompt | Out-Null
    [Console]::Out.Flush()
    $osc = $capture.ToString()

    Assert-True ($osc.Contains("]133;D;0;aid=$PID")) "Prompt output missing OSC 133 D aid metadata"
    Assert-True ($osc.Contains(']7;file://')) "Prompt output missing OSC 7 cwd"
    Assert-True ($osc.Contains("]133;A;cl=line;aid=$PID")) "Prompt output missing OSC 133 A prompt metadata"
    Assert-True ($osc.Contains(']133;B')) "Prompt output missing OSC 133 B marker"

    [Console]::SetOut($script:OriginalOut)
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
