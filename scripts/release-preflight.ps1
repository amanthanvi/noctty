[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [switch]$RequireSigning,

    [switch]$RequirePackageManagers
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$releaseMetaPath = Join-Path $repoRoot "dist/windows/release-metadata.json"

function Get-EnvValue {
    param([string]$Name)

    $item = Get-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }

    return [string]$item.Value
}

function Test-EnvPresent {
    param([string]$Name)

    return -not [string]::IsNullOrWhiteSpace((Get-EnvValue -Name $Name))
}

function Assert-EnvPresent {
    param([string]$Name)

    if (-not (Test-EnvPresent -Name $Name)) {
        throw "Required environment variable was not set: $Name"
    }
}

function Write-Status {
    param(
        [string]$Label,
        [string]$Value
    )

    Write-Host ("{0,-24} {1}" -f "${Label}:", $Value)
}

function Write-PresenceStatus {
    param(
        [string]$Label,
        [string]$Name,
        [string]$MissingMessage,
        [switch]$RedactValue,
        [switch]$Required
    )

    if (Test-EnvPresent -Name $Name) {
        $value = if ($RedactValue) { "present" } else { Get-EnvValue -Name $Name }
        Write-Status -Label $Label -Value $value
        return
    }

    if ($Required) {
        throw "Required environment variable was not set: $Name"
    }

    Write-Status -Label $Label -Value $MissingMessage
}

$versionMatch = [regex]::Match($Version, '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$')
if (-not $versionMatch.Success) {
    throw "Unsupported release version format '$Version'. winghostty releases must use plain semver <major>.<minor>.<patch>."
}

if (-not (Test-Path -LiteralPath $releaseMetaPath)) {
    throw "Release metadata file not found: $releaseMetaPath"
}

$releaseMeta = Get-Content -LiteralPath $releaseMetaPath -Raw | ConvertFrom-Json
$upstreamBaseVersion = [string]$releaseMeta.upstreamBaseVersion
$firstForkPatch = [int]$releaseMeta.firstForkPatch
$upstreamMatch = [regex]::Match($upstreamBaseVersion, '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$')
if (-not $upstreamMatch.Success) {
    throw "dist/windows/release-metadata.json must declare a plain semver upstreamBaseVersion."
}

$versionLine = "$($versionMatch.Groups['major'].Value).$($versionMatch.Groups['minor'].Value)"
$upstreamLine = "$($upstreamMatch.Groups['major'].Value).$($upstreamMatch.Groups['minor'].Value)"
if ($versionLine -ne $upstreamLine) {
    throw "Release version '$Version' is on line $versionLine but upstreamBaseVersion '$upstreamBaseVersion' is on line $upstreamLine."
}

$patch = [int]$versionMatch.Groups['patch'].Value
if ($patch -lt $firstForkPatch) {
    throw "Release patch '$patch' is below the configured firstForkPatch '$firstForkPatch'. winghostty fork releases on line $versionLine must start at $versionLine.$firstForkPatch or later."
}

$timestampUrl = if (Test-EnvPresent -Name "WINDOWS_CODESIGN_TIMESTAMP_URL") {
    Get-EnvValue -Name "WINDOWS_CODESIGN_TIMESTAMP_URL"
} else {
    "http://timestamp.digicert.com"
}

Write-Status -Label "Version" -Value $Version
Write-Status -Label "Version line" -Value $versionLine
Write-Status -Label "Upstream base" -Value $upstreamBaseVersion
Write-Status -Label "First fork patch" -Value $firstForkPatch

if ($RequireSigning) {
    Assert-EnvPresent -Name "WINDOWS_CODESIGN_PFX_BASE64"
    Assert-EnvPresent -Name "WINDOWS_CODESIGN_PFX_PASSWORD"
    Write-Status -Label "Code signing" -Value "enabled"
    Write-Status -Label "Timestamp URL" -Value $timestampUrl
} else {
    Write-Status -Label "Code signing" -Value "not required"
}

Write-PresenceStatus -Label "WinGet package id" -Name "WINGET_PACKAGE_IDENTIFIER" -MissingMessage "missing (submit step will skip)" -Required:$RequirePackageManagers
Write-PresenceStatus -Label "Scoop repo" -Name "SCOOP_BUCKET_REPO" -MissingMessage "missing (publish step will skip)" -Required:$RequirePackageManagers
Write-PresenceStatus -Label "Scoop token" -Name "SCOOP_BUCKET_TOKEN" -MissingMessage "missing (publish step will skip)" -RedactValue
Write-PresenceStatus -Label "WinGet token" -Name "WINGETCREATE_TOKEN" -MissingMessage "missing (submit step will skip)" -RedactValue

Write-Host "Release preflight passed."
