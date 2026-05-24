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

function Get-WingetManifestPath {
    param([string]$PackageIdentifier)

    $segments = $PackageIdentifier.Split('.')
    if ($segments.Count -lt 2) {
        throw "WINGET_PACKAGE_IDENTIFIER must contain at least publisher and package segments."
    }

    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            throw "WINGET_PACKAGE_IDENTIFIER contains an empty segment: $PackageIdentifier"
        }
    }

    return "manifests/{0}/{1}" -f `
        $segments[0].Substring(0, 1).ToLowerInvariant(), `
        ($segments -join '/')
}

function Test-GitHubContentPath {
    param(
        [string]$Repository,
        [string]$Path,
        [string]$Label,
        [string]$Ref
    )

    $apiPath = ($Path -replace '\\', '/').TrimStart('/')
    $uri = "https://api.github.com/repos/$Repository/contents/$apiPath"
    if (-not [string]::IsNullOrWhiteSpace($Ref)) {
        $uri = "$uri`?ref=$([System.Uri]::EscapeDataString($Ref))"
    }

    try {
        Invoke-WebRequest `
            -Uri $uri `
            -Headers @{ "User-Agent" = "winghostty-release-preflight" } `
            -UseBasicParsing `
            -ErrorAction Stop | Out-Null
        Write-Status -Label $Label -Value "found ($apiPath)"
        return $true
    }
    catch {
        $statusCode = if ($_.Exception.Response) {
            [int]$_.Exception.Response.StatusCode
        } else {
            $null
        }

        if ($statusCode -eq 404) {
            Write-Status -Label $Label -Value "missing ($apiPath)"
            return $false
        }

        throw
    }
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
Write-PresenceStatus -Label "Scoop token" -Name "SCOOP_BUCKET_TOKEN" -MissingMessage "missing (publish step will skip)" -RedactValue -Required:$RequirePackageManagers
Write-PresenceStatus -Label "WinGet token" -Name "WINGETCREATE_TOKEN" -MissingMessage "missing (submit step will skip)" -RedactValue -Required:$RequirePackageManagers

if ($RequirePackageManagers) {
    $scoopManifestPath = if (Test-EnvPresent -Name "SCOOP_BUCKET_MANIFEST_PATH") {
        Get-EnvValue -Name "SCOOP_BUCKET_MANIFEST_PATH"
    } else {
        "bucket/winghostty.json"
    }
    $wingetManifestPath = Get-WingetManifestPath -PackageIdentifier (Get-EnvValue -Name "WINGET_PACKAGE_IDENTIFIER")

    $scoopReady = Test-GitHubContentPath `
        -Repository (Get-EnvValue -Name "SCOOP_BUCKET_REPO") `
        -Path $scoopManifestPath `
        -Label "Scoop manifest" `
        -Ref (Get-EnvValue -Name "SCOOP_BUCKET_BRANCH")
    $wingetReady = Test-GitHubContentPath `
        -Repository "microsoft/winget-pkgs" `
        -Path $wingetManifestPath `
        -Label "WinGet manifest"

    if (-not $scoopReady) {
        throw "RequirePackageManagers was set, but the configured Scoop manifest does not exist."
    }
    if (-not $wingetReady) {
        throw "RequirePackageManagers was set, but $($env:WINGET_PACKAGE_IDENTIFIER) is not bootstrapped in microsoft/winget-pkgs."
    }
}

Write-Host "Release preflight passed."
