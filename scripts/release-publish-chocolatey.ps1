[CmdletBinding(SupportsShouldProcess)]
param(
    # $Version reaches a package file name and a public feed query. \A and \z
    # rather than ^ and $ because .NET's $ also matches before a trailing
    # newline, and [0-9] rather than \d because .NET's \d matches every Unicode
    # decimal digit. Both would otherwise pass a value that is not a koreterm
    # release version.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string] $Version,

    [string] $ArtifactRoot,

    [string] $RunnerTemp = $env:RUNNER_TEMP,

    [string] $PushSource = 'https://push.chocolatey.org/',

    [string] $QuerySource = 'https://community.chocolatey.org/api/v2/',

    # Do everything up to `choco push`: ask the feed, pack, and check that one
    # package came out. It needs no API key and never contacts the push source,
    # which is what the manual Chocolatey Publish workflow's dry run relies on.
    [switch] $PackOnly,

    # Push even though the feed lists this version. The exact-version lookup
    # below also answers 200 for a version still in moderation (measured on
    # 2026-10-17 for Submitted and Ready ones, which FindPackagesById omits), so
    # without this a corrected package for a version in moderation, which
    # Chocolatey wants under the same version, would always be skipped. A failed
    # push is then never counted as complete: the version being listed proves
    # nothing about the bytes the feed holds.
    [switch] $Resubmit
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $PackOnly -and -not $env:CHOCO_API_KEY) {
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
$artifactDirectoryX64 = Join-Path $ArtifactRoot "koreterm-$Version-windows-x64"
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
    if (-not $Resubmit) {
        Write-Host "Chocolatey already has $packageName $Version; nothing to push."
        # A dry run still packs, so it shows what a -Resubmit run would push.
        if (-not $PackOnly) { return }
    }
    else {
        Write-Host "Chocolatey lists $packageName $Version; -Resubmit pushes it again."
    }
}

if (-not $PSCmdlet.ShouldProcess($PushSource, "publish $packageName $Version to Chocolatey")) {
    return
}

$packageOutputDir = Join-Path $RunnerTemp "koreterm-chocolatey-$Version"
if (Test-Path -LiteralPath $packageOutputDir) {
    Remove-Item -LiteralPath $packageOutputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $packageOutputDir -Force | Out-Null

# The key is for the push alone: take it out of this process's environment
# while choco pack runs, so the packing process does not inherit it.
$apiKey = $env:CHOCO_API_KEY
Remove-Item -LiteralPath Env:CHOCO_API_KEY -ErrorAction Ignore
try {
    & choco pack $nuspecPath `
        --output-directory $packageOutputDir `
        --limit-output
    $packExitCode = $LASTEXITCODE
}
finally {
    if ($apiKey) { $env:CHOCO_API_KEY = $apiKey }
}
if ($packExitCode -ne 0) {
    throw "choco pack failed with exit code $packExitCode."
}

$packages = @(Get-ChildItem -LiteralPath $packageOutputDir -Filter '*.nupkg' -File)
if ($packages.Count -ne 1) {
    throw "Expected one Chocolatey package; found $($packages.Count)."
}

if ($PackOnly) {
    Write-Host "Packed $($packages[0].Name) ($($packages[0].Length) bytes, SHA-256 $(Get-FileSha256Lower -Path $packages[0].FullName)); -PackOnly stops here, nothing was pushed."
    return
}

$pushOutput = & choco push $packages[0].FullName `
    --source $PushSource `
    --api-key $env:CHOCO_API_KEY `
    --limit-output 2>&1
$pushExitCode = $LASTEXITCODE
$pushText = ($pushOutput | Out-String)
Write-Host $pushText
if ($pushExitCode -ne 0) {
    # Only "this version is already there" is tolerated, because the intended
    # end state then holds. The status code cannot say that on its own: the
    # feed also answers 409 Conflict for a package that fails its basic
    # validation, so ask the feed again instead of reading the response.
    if (-not $Resubmit -and (Test-ChocolateyVersionPublished `
            -Name $packageName `
            -PackageVersion $Version `
            -Source $QuerySource)) {
        Write-Host "Chocolatey already has $packageName $Version; treating the push as complete."
        # GitHub's pwsh wrapper exits with the last native exit code, which is
        # still the failed push's.
        $global:LASTEXITCODE = 0
        return
    }
    if ($pushText -match '\b403\b') {
        # https://docs.chocolatey.org/en-us/community-repository/maintainers/common-errors/
        throw "choco push was refused with 403. Chocolatey answers 403 for an invalid API key, a package owned by another account, too many versions in moderation, and while a version is in moderation and none has been approved yet, which can last weeks after the first submission (docs/chocolatey-publishing.md)."
    }
    throw "choco push failed with exit code $pushExitCode."
}
