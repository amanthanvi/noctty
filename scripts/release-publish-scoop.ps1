[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $BucketRepository = $env:SCOOP_BUCKET_REPO,

    [string] $BucketBranch = $env:SCOOP_BUCKET_BRANCH,

    [string] $ManifestPath = $env:SCOOP_BUCKET_MANIFEST_PATH,

    [string] $ArtifactRoot,

    [string] $RunnerTemp = $env:RUNNER_TEMP
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $env:GH_TOKEN) {
    Write-Host 'Skipping Scoop publish: SCOOP_BUCKET_TOKEN is not configured.'
    return
}
if ([string]::IsNullOrWhiteSpace($BucketRepository)) {
    Write-Host 'Skipping Scoop publish: SCOOP_BUCKET_REPO is not configured.'
    return
}
if (-not $PSCmdlet.ShouldProcess($BucketRepository, "publish noctty $Version Scoop manifest")) {
    return
}

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repoRoot 'dist/artifacts'
}
if ([string]::IsNullOrWhiteSpace($RunnerTemp)) {
    $RunnerTemp = [System.IO.Path]::GetTempPath()
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
$RunnerTemp = [System.IO.Path]::GetFullPath($RunnerTemp)

$artifactDirectoryX64 = Join-Path $ArtifactRoot "noctty-$Version-windows-x64"
$metadataPath = Join-Path $artifactDirectoryX64 'package-managers/metadata.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$manifestRelativePath = if ($ManifestPath) {
    $ManifestPath
} else {
    'bucket/noctty.json'
}

$bucketDirectory = Join-Path $RunnerTemp 'noctty-scoop-bucket'
if (Test-Path -LiteralPath $bucketDirectory) {
    Remove-Item -LiteralPath $bucketDirectory -Recurse -Force
}

$cloneArgs = @('repo', 'clone', $BucketRepository, $bucketDirectory, '--', '--depth', '1')
if ($BucketBranch) {
    $cloneArgs += @('--branch', $BucketBranch)
}
& gh @cloneArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to clone Scoop bucket repo $BucketRepository."
}

$destinationManifestPath = Join-Path $bucketDirectory $manifestRelativePath
$destinationManifestDirectory = Split-Path -Parent $destinationManifestPath
New-Item -ItemType Directory -Path $destinationManifestDirectory -Force | Out-Null
Copy-Item -LiteralPath $metadata.scoop.manifestPath -Destination $destinationManifestPath -Force

Push-Location $bucketDirectory
try {
    & git remote set-url origin "https://x-access-token:$env:GH_TOKEN@github.com/$BucketRepository.git"
    if ($LASTEXITCODE -ne 0) {
        throw "git remote set-url failed with exit code $LASTEXITCODE"
    }

    & git config user.name 'github-actions[bot]'
    & git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    & git add -- $manifestRelativePath
    & git diff --cached --quiet --exit-code
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Scoop manifest is unchanged; skipping push.'
        return
    }
    if ($LASTEXITCODE -ne 1) {
        throw "git diff --cached failed with exit code $LASTEXITCODE"
    }

    & git commit -m "noctty: update to $Version"
    if ($LASTEXITCODE -ne 0) {
        throw "git commit failed with exit code $LASTEXITCODE"
    }

    & git push origin HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
