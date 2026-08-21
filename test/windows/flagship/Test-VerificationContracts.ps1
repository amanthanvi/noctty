#requires -Version 7.3

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $root))
$contractsRoot = Join-Path $root 'contracts'

. (Join-Path $contractsRoot 'ContractHelpers.ps1')
Initialize-ContractFailureCollection
$script:FlagshipScenarioIds = $null

$fragments = @(Get-ChildItem -LiteralPath $contractsRoot -Filter 'Contracts.*.ps1' |
    Sort-Object Name)
if ($fragments.Count -eq 0) {
    Add-ContractFailure `
        -Description 'No verification contract fragments were found.' `
        -SourceFragment 'Test-VerificationContracts.ps1'
}

foreach ($fragment in $fragments) {
    $script:CurrentContractFragment = $fragment.Name
    try {
        . $fragment.FullName
    }
    catch {
        $detail = $_.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($_.InvocationInfo.PositionMessage)) {
            $detail += "`n$($_.InvocationInfo.PositionMessage.Trim())"
        }
        Add-ContractFailure `
            -Description $_.Exception.Message `
            -SourceFragment $fragment.Name `
            -Detail $detail
    }
}

if ($null -eq $script:FlagshipScenarioIds) {
    Add-ContractFailure `
        -Description 'Foundation contract did not publish FlagshipScenarioIds.' `
        -SourceFragment 'Test-VerificationContracts.ps1'
}

if ($script:ContractFailures.Count -gt 0) {
    foreach ($failure in $script:ContractFailures) {
        [Console]::Error.WriteLine(
            "CONTRACT FAILURE [$($failure.SourceFragment)] $($failure.Description)"
        )
        if (-not [string]::IsNullOrWhiteSpace($failure.Detail)) {
            [Console]::Error.WriteLine("  $($failure.Detail)")
        }
    }
    [Console]::Error.WriteLine(
        "flagship verification contracts: FAIL ($($script:ContractFailures.Count) failures)"
    )
    exit 1
}

Write-Host "flagship verification contracts: PASS ($($script:FlagshipScenarioIds.Count) scenarios)"
exit 0
