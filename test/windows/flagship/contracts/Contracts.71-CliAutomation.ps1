$cliAutomationHarness = Join-Path $repoRoot 'test\windows\cli-automation.ps1'
if (-not (Test-Path -LiteralPath $cliAutomationHarness -PathType Leaf)) {
    throw "CLI automation harness is missing: $cliAutomationHarness"
}
$cliAutomationText = Get-Content -LiteralPath $cliAutomationHarness -Raw
$cliAutomationTokens = $null
$cliAutomationErrors = $null
$cliAutomationAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $cliAutomationText,
    [ref]$cliAutomationTokens,
    [ref]$cliAutomationErrors
)
if ($cliAutomationErrors.Count -ne 0) {
    throw "CLI automation harness does not parse: $($cliAutomationErrors[0].Message)"
}

foreach ($requiredText in @(
        'NOCTTY_CLI_AUTOMATION_BOOTSTRAPPED',
        'noctty.windows.v3',
        'ConvertFrom-Json',
        '$serverPid = $server.Id',
        '$State.instance.pid -ne $ServerPid',
        '+new-window',
        '+list-windows',
        '+perform-action',
        '+new-tab',
        '+new-split',
        '+focus',
        '+send-text',
        'Description ''second window''',
        'Description ''new tab''',
        'Description ''new split''',
        'Description ''exact focused surface''',
        'Description ''+send-text newline refusal'' -Result $result -Expected 4',
        'Description ''+send-text printable text'' -Result $result -Expected 0',
        'Description ''+list-windows unused class'' -Result $result -Expected 2',
        'blocked`nline',
        'Stop-InteractiveWin11Process -Process $server -Contained',
        # The harness bootstraps into Windows PowerShell 5.1, where a native
        # command writing to stderr terminates the script while the preference
        # is 'Stop'. The first `+list-windows` poll does exactly that before the
        # server listens, so the CLI invocation must relax and restore the
        # preference around itself or the harness cannot pass.
        '$ErrorActionPreference = ''Continue''',
        '$ErrorActionPreference = $originalErrorActionPreference'
    )) {
    if (-not $cliAutomationText.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "CLI automation harness contract is missing: $requiredText"
    }
}
if ($cliAutomationText -match '(?i)\b(?:Stop-Process|taskkill(?:\.exe)?)\b') {
    throw 'CLI automation cleanup must stop only its recorded process through the shared helper.'
}

$registrationPattern = "(?m)^Invoke-HarnessWithPassSentinel -ScriptName 'cli-automation\.ps1' -TimeoutSeconds 35$"
if ([regex]::Matches($interactiveValidatorText, $registrationPattern).Count -ne 1) {
    throw 'Interactive validation must register the CLI automation harness exactly once with its contract timeout.'
}
