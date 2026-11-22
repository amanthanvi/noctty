[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Tag,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [ValidatePattern('\A[0-9a-f]{40}\z')] [string] $CandidateSha,
    [Parameter(Mandatory)] [ValidatePattern('\A[0-9]+\z')] [string] $TestRunId,
    [Parameter(Mandatory)] [ValidatePattern('\A[0-9]+\z')] [string] $ReleaseRunId,
    [string] $ArtifactRoot,
    [string] $CandidateDirectory = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-manifest.ps1')
if (-not $ArtifactRoot) { $ArtifactRoot = Join-Path (Get-RepoRoot) 'dist/artifacts' }
if ($Tag -cne "v$Version") { throw 'Release tag and version differ.' }
Write-ReleaseManifest -Tag $Tag -Version $Version -CandidateSha $CandidateSha -TestRunId $TestRunId -ReleaseRunId $ReleaseRunId -ArtifactRoot $ArtifactRoot -CandidateDirectory $CandidateDirectory
