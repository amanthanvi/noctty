[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$root = Join-Path ([IO.Path]::GetTempPath()) ('release-stager-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $root 'scripts'
[void][IO.Directory]::CreateDirectory($scripts)
foreach ($name in @('release-stage-published.ps1', 'common.ps1', 'windows-architecture.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "scripts/$name") -Destination (Join-Path $scripts $name)
}
[IO.File]::WriteAllText((Join-Path $scripts 'verify-published-release.ps1'), @'
param([string] $Version, [string] $DownloadDirectory, [string] $CandidateDirectory, [string] $ManifestSha256)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'arguments.json'), ($PSBoundParameters | ConvertTo-Json))
throw 'StagerFixtureStop'
'@)
function gh { throw 'Stager fixture must never reach GitHub.' }
foreach ($mode in @('historical', 'manifest')) {
    $parameters = @{ Version = '1.3.136'; DownloadDirectory = (Join-Path $root "download-$mode") }
    if ($mode -eq 'manifest') {
        $parameters.ManifestSha256 = 'a' * 64
        $parameters.CandidateDirectory = Join-Path $root 'candidate'
    }
    $message = $null
    try { & (Join-Path $scripts 'release-stage-published.ps1') @parameters } catch { $message = $_.Exception.Message }
    if ($message -cne 'StagerFixtureStop') { throw "Stager fixture did not reach its verifier: $message" }
    $received = Get-Content -LiteralPath (Join-Path $scripts 'arguments.json') -Raw | ConvertFrom-Json
    if ($received.Version -cne $parameters.Version -or $received.DownloadDirectory -cne $parameters.DownloadDirectory) { throw 'Stager lost its version or download directory.' }
    if ($mode -eq 'manifest') {
        if ($received.ManifestSha256 -cne $parameters.ManifestSha256 -or $received.CandidateDirectory -cne $parameters.CandidateDirectory) { throw 'Stager lost the candidate data or trust anchor.' }
    } elseif ($received.PSObject.Properties.Name -contains 'ManifestSha256' -or $received.PSObject.Properties.Name -contains 'CandidateDirectory') { throw 'Historical staging gained required manifest inputs.' }
}
$global:LASTEXITCODE = 0
Write-Host 'Published release stager: PASS (2 verifier argument cases; no GitHub calls).'
