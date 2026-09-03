[CmdletBinding(SupportsShouldProcess)]
param(
    # $Version reaches a package file name and a public feed query. \A and \z
    # rather than ^ and $ because .NET's $ also matches before a trailing
    # newline, and [0-9] rather than \d because .NET's \d matches every Unicode
    # decimal digit. Both would otherwise pass a value that is not a noctty
    # release version.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string] $Version,

    [string] $ArtifactRoot,

    [string] $RunnerTemp = $env:RUNNER_TEMP,

    [string] $PushSource = 'https://push.chocolatey.org/',

    [string] $QuerySource = 'https://community.chocolatey.org/api/v2/'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $env:CHOCO_API_KEY) {
    Write-Host 'Skipping Chocolatey publish: CHOCO_API_KEY is not configured.'
    return
}

if ([string]::IsNullOrWhiteSpace($RunnerTemp)) {
    $RunnerTemp = [System.IO.Path]::GetTempPath()
}
$RunnerTemp = [System.IO.Path]::GetFullPath($RunnerTemp)

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repoRoot 'dist/artifacts'
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
$artifactDirectoryX64 = Join-Path $ArtifactRoot "noctty-$Version-windows-x64"
$metadataPath = Join-Path $artifactDirectoryX64 'package-managers/metadata.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json

$packageName = $metadata.chocolatey.packageName
if ([string]::IsNullOrWhiteSpace($packageName)) {
    throw 'metadata.json does not name the Chocolatey package.'
}
$nuspecPath = $metadata.chocolatey.nuspecPath
if ([string]::IsNullOrWhiteSpace($nuspecPath)) {
    throw 'metadata.json does not record the Chocolatey nuspec path.'
}
$packageDirectory = $metadata.chocolatey.packageDirectory
if ([string]::IsNullOrWhiteSpace($packageDirectory)) {
    throw 'metadata.json does not record the Chocolatey package directory.'
}
# The nuspec has to be the one inside the package directory the same run
# generated; a mismatch means the metadata describes a different build.
$nuspecParent = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetDirectoryName($nuspecPath)
)
if ($nuspecParent -ne [System.IO.Path]::GetFullPath($packageDirectory)) {
    throw "Chocolatey nuspec is outside its package directory: $nuspecPath"
}

# A Chocolatey package version is immutable. Republishing one is a hard error
# from the feed, which would otherwise stop a rerun before it reaches the
# WinGet step, so ask the feed first and treat "already there" as done.
function Test-ChocolateyVersionPublished {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $PackageVersion,
        [Parameter(Mandatory)] [string] $Source
    )

    $uri = "$($Source.TrimEnd('/'))/Packages(Id='$Name',Version='$PackageVersion')"
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 404) { return $false }
        # Anything other than a clean "not found" leaves publication state
        # unknown. Say so instead of guessing in either direction.
        throw "Could not determine whether $Name $PackageVersion is already published: $($_.Exception.Message)"
    }
    return $response.StatusCode -eq 200
}

if (Test-ChocolateyVersionPublished `
        -Name $packageName `
        -PackageVersion $Version `
        -Source $QuerySource) {
    Write-Host "Chocolatey already has $packageName $Version; nothing to push."
    return
}

if (-not $PSCmdlet.ShouldProcess($PushSource, "publish $packageName $Version to Chocolatey")) {
    return
}

$packageOutputDir = Join-Path $RunnerTemp "noctty-chocolatey-$Version"
if (Test-Path -LiteralPath $packageOutputDir) {
    Remove-Item -LiteralPath $packageOutputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $packageOutputDir -Force | Out-Null

& choco pack $nuspecPath `
    --output-directory $packageOutputDir `
    --limit-output
if ($LASTEXITCODE -ne 0) {
    throw "choco pack failed with exit code $LASTEXITCODE."
}

$packages = @(Get-ChildItem -LiteralPath $packageOutputDir -Filter '*.nupkg' -File)
if ($packages.Count -ne 1) {
    throw "Expected one Chocolatey package; found $($packages.Count)."
}

$pushOutput = & choco push $packages[0].FullName `
    --source $PushSource `
    --api-key $env:CHOCO_API_KEY `
    --limit-output 2>&1
$pushExitCode = $LASTEXITCODE
$pushText = ($pushOutput | Out-String)
Write-Host $pushText
if ($pushExitCode -ne 0) {
    # Only the duplicate-version response is tolerated, and only because it
    # means the intended end state already holds. Every other failure stays a
    # failure.
    if ($pushText -match 'already exists' -or
        $pushText -match 'A package with the ID.*and version.*already exists' -or
        $pushText -match '409') {
        Write-Host "Chocolatey reported $packageName $Version as already published; treating the push as complete."
        return
    }
    throw "choco push failed with exit code $pushExitCode."
}
