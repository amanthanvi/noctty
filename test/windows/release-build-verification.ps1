[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'flagship/contracts/ContractHelpers.ps1')
$workflow=Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/release.yml') -Raw
$step=Get-YamlStepBlock -Content $workflow -Name 'Verify published release copy and assets' -Source 'build verification control'
$body=Get-YamlLiteralRunScript -Content $step -Source 'build verification control'
if($body -match 'if \(\$LASTEXITCODE'){throw 'Build verification must consume explicit script results.'}
$body=$body.Replace('./scripts/check-release-copy.ps1','Test-BuildCopy').Replace('./scripts/verify-published-release.ps1','Test-BuildVerifier')
$calls=[Collections.Generic.List[string]]::new()
function Test-BuildCopy {
    param([string]$ExpectedVersion,[switch]$CheckRemoteLatest,[switch]$PassThru)
    $calls.Add('copy');$global:LASTEXITCODE=73
    if(-not $PassThru){throw 'Copy result was not requested.'}
    if($case -ne 'copy-failed'){[pscustomobject]@{Verified=$true}}
}
function Test-BuildVerifier {
    param([string]$Version,[string]$ManifestSha256,[switch]$PassThru)
    $calls.Add('verifier');$global:LASTEXITCODE=74
    if(-not $PassThru){throw 'Verifier result was not requested.'}
    [pscustomobject]@{Verified=($case -ne 'verifier-failed')}
}
foreach($case in @('stale-native-success','copy-failed','verifier-failed')) {
    $calls.Clear();$failure=$null
    try {& ([scriptblock]::Create($body))}catch{$failure=$_.Exception.Message}
    if($case -eq 'stale-native-success') {
        if($failure -or $LASTEXITCODE -ne 0 -or $calls.Count -ne 2){throw 'Successful explicit results must clear the runner trailer status.'}
    } elseif(-not $failure -or ($case -eq 'copy-failed' -and $calls.Contains('verifier'))) {throw 'Build verification failed to stop at an unproven result.'}
}
$global:LASTEXITCODE=0
Write-Host 'Build verification results: PASS (stale native status, failed copy, failed verifier).'
