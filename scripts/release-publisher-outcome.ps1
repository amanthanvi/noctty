function Set-ReleasePublisherOutcome {
    param([ValidateSet('published','already-present','skipped-unconfigured','skipped-disabled','what-if','packed')] [string] $Outcome)
    Write-Host "Publisher outcome: $Outcome"
    if ($env:GITHUB_OUTPUT) {
        "outcome=$Outcome" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    $global:LASTEXITCODE = 0
}
