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
if ([string]::IsNullOrWhiteSpace($RunnerTemp)) {
    $RunnerTemp = [System.IO.Path]::GetTempPath()
}
$RunnerTemp = [System.IO.Path]::GetFullPath($RunnerTemp)
$bucketDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $RunnerTemp 'noctty-scoop-bucket')
)
$bucketRelativePath = [System.IO.Path]::GetRelativePath(
    $RunnerTemp,
    $bucketDirectory
)
if ($bucketRelativePath -cne 'noctty-scoop-bucket') {
    throw "Refusing to use unexpected Scoop clone path: $bucketDirectory"
}

$manifestRelativePath = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    'bucket/noctty.json'
} else {
    $ManifestPath
}
if ([System.IO.Path]::IsPathRooted($manifestRelativePath)) {
    throw "Scoop manifest path must be relative to the bucket clone: $manifestRelativePath"
}
$manifestPathSegments = @($manifestRelativePath -split '[\\/]')
if (@($manifestPathSegments | Where-Object { $_ -ceq '..' }).Count -ne 0) {
    throw "Scoop manifest path must not contain parent traversal: $manifestRelativePath"
}
if ([string]::IsNullOrWhiteSpace(
        [System.IO.Path]::GetFileName($manifestRelativePath)
    )) {
    throw "Scoop manifest path must name a file: $manifestRelativePath"
}
try {
    $destinationManifestPath = [System.IO.Path]::GetFullPath(
        (Join-Path $bucketDirectory $manifestRelativePath)
    )
}
catch {
    throw "Scoop manifest path is invalid: $manifestRelativePath"
}
$bucketDirectoryPrefix = $bucketDirectory.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
if (-not $destinationManifestPath.StartsWith(
        $bucketDirectoryPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Scoop manifest path escapes the bucket clone: $manifestRelativePath"
}
$manifestRelativePath = [System.IO.Path]::GetRelativePath(
    $bucketDirectory,
    $destinationManifestPath
)

function Remove-ValidatedScoopClone {
    try {
        $cloneItem = Get-Item -LiteralPath $bucketDirectory -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return
    }
    if (-not $cloneItem.PSIsContainer) {
        throw "Scoop clone path is not a directory; refusing recursive cleanup: $bucketDirectory"
    }
    if (($cloneItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Scoop clone path is a reparse point; refusing recursive cleanup: $bucketDirectory"
    }
    Remove-Item -LiteralPath $bucketDirectory -Recurse -Force
}

if (-not $PSCmdlet.ShouldProcess($BucketRepository, "publish noctty $Version Scoop manifest")) {
    return
}

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repoRoot 'dist/artifacts'
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
$artifactDirectoryX64 = Join-Path $ArtifactRoot "noctty-$Version-windows-x64"
$metadataPath = Join-Path $artifactDirectoryX64 'package-managers/metadata.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json

Remove-ValidatedScoopClone

$gitNetworkBoundArgs = @(
    '-c',
    'http.lowSpeedLimit=1',
    '-c',
    'http.lowSpeedTime=60'
)
$credentialHelperArgs = @(
    '-c',
    'credential.helper=',
    '-c',
    'credential.helper=!gh auth git-credential'
)
$cloneArgs = @(
    'clone',
    '--depth',
    '1'
)
if ($BucketBranch) {
    $cloneArgs += @('--branch', $BucketBranch)
}
$cloneArgs += @(
    "https://github.com/$BucketRepository.git",
    $bucketDirectory
)

try {
    & git @gitNetworkBoundArgs @credentialHelperArgs @cloneArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone Scoop bucket repo $BucketRepository."
    }

    $destinationManifestDirectory = Split-Path -Parent $destinationManifestPath
    $relativeManifestDirectory = [System.IO.Path]::GetRelativePath(
        $bucketDirectory,
        $destinationManifestDirectory
    )
    $currentManifestDirectory = $bucketDirectory
    foreach ($segment in @($relativeManifestDirectory -split '[\\/]')) {
        if ($segment -ceq '.') { continue }
        $currentManifestDirectory = Join-Path $currentManifestDirectory $segment
        if (Test-Path -LiteralPath $currentManifestDirectory) {
            $directoryItem = Get-Item -LiteralPath $currentManifestDirectory -Force
            if (-not $directoryItem.PSIsContainer -or
                ($directoryItem.Attributes -band
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Scoop manifest path crosses a non-directory or reparse point: $manifestRelativePath"
            }
        }
    }
    if (Test-Path -LiteralPath $destinationManifestPath) {
        $destinationItem = Get-Item -LiteralPath $destinationManifestPath -Force
        if ($destinationItem.PSIsContainer) {
            throw "Scoop manifest path names a directory: $manifestRelativePath"
        }
        if (($destinationItem.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Scoop manifest path names a reparse point: $manifestRelativePath"
        }
    }
    New-Item -ItemType Directory -Path $destinationManifestDirectory -Force | Out-Null
    Copy-Item -LiteralPath $metadata.scoop.manifestPath -Destination $destinationManifestPath -Force

    Push-Location $bucketDirectory
    try {
        & git config user.name 'github-actions[bot]'
        if ($LASTEXITCODE -ne 0) {
            throw "git config user.name failed with exit code $LASTEXITCODE"
        }
        & git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
        if ($LASTEXITCODE -ne 0) {
            throw "git config user.email failed with exit code $LASTEXITCODE"
        }
        & git add -- $manifestRelativePath
        if ($LASTEXITCODE -ne 0) {
            throw "git add failed with exit code $LASTEXITCODE"
        }
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

        & git @gitNetworkBoundArgs -c 'credential.helper=' -c 'credential.helper=!gh auth git-credential' push origin HEAD
        if ($LASTEXITCODE -ne 0) {
            throw "git push failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    Remove-ValidatedScoopClone
}
