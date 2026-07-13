[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [switch]$RequireSigning,

    [switch]$RequirePackageManagers,

    [switch]$RequireAccessibilityEvidence
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$releaseMetaPath = Join-Path $repoRoot "dist/windows/release-metadata.json"
. (Join-Path $PSScriptRoot 'signing-trust.ps1')

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

function Get-OptionalEnvValue {
    param([string]$Name)

    if (Test-EnvPresent -Name $Name) {
        return Get-EnvValue -Name $Name
    }

    return $null
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

function Get-GitHubApiToken {
    param([string[]]$Names)

    foreach ($name in $Names) {
        if (Test-EnvPresent -Name $name) {
            return Get-EnvValue -Name $name
        }
    }

    return $null
}

function Get-GitHubResponseText {
    param($Response)

    if ($null -eq $Response) {
        return $null
    }

    try {
        if ($Response.Content -and $Response.Content.GetType().GetMethod("ReadAsStringAsync")) {
            return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }

        $stream = $Response.GetResponseStream()
        if ($null -eq $stream) {
            return $null
        }

        $reader = [System.IO.StreamReader]::new($stream)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Test-GitHubContentPath {
    param(
        [string]$Repository,
        [string]$Path,
        [string]$Label,
        [string]$Ref,
        [string]$Token
    )

    $apiPath = ($Path -replace '\\', '/').TrimStart('/')
    $uri = "https://api.github.com/repos/$Repository/contents/$apiPath"
    if (-not [string]::IsNullOrWhiteSpace($Ref)) {
        $uri = "$uri`?ref=$([System.Uri]::EscapeDataString($Ref))"
    }

    $headers = @{
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "winghostty-release-preflight"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers["Authorization"] = "Bearer $Token"
    }

    $requestParams = @{
        Uri = $uri
        Headers = $headers
        ErrorAction = "Stop"
    }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
        $requestParams["UseBasicParsing"] = $true
    }

    try {
        Invoke-WebRequest @requestParams | Out-Null
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

        $responseText = if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            [string]$_.ErrorDetails.Message
        } else {
            Get-GitHubResponseText -Response $_.Exception.Response
        }
        $apiMessage = $null
        if (-not [string]::IsNullOrWhiteSpace($responseText)) {
            try {
                $apiMessage = [string](($responseText | ConvertFrom-Json).message)
            }
            catch {
                $apiMessage = $responseText.Trim()
            }
        }

        $detail = "GitHub Contents API probe failed for $Repository/$apiPath"
        if ($statusCode) {
            $detail = "$detail (HTTP $statusCode)"
        }
        if (-not [string]::IsNullOrWhiteSpace($apiMessage)) {
            $detail = "${detail}: $apiMessage"
        }
        if ($statusCode -eq 403) {
            $detail = "$detail. Check token permissions, private repository access, and GitHub API rate limits."
        }
        elseif ($statusCode) {
            $detail = "$detail. Check repository/path/ref configuration and token access."
        }

        throw $detail
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

if ($RequireAccessibilityEvidence) {
    & (Join-Path $PSScriptRoot 'check-accessibility-evidence.ps1') -Version $Version
    if (-not $?) { throw 'Accessibility evidence validation failed.' }
}

function Assert-WingetArchitectureCoverage {
    param(
        [string]$ManifestPath,
        [string]$Token
    )

    $headers = @{
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "winghostty-release-preflight"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers["Authorization"] = "Bearer $Token"
    }

    $apiRoot = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$ManifestPath"
    $versionListing = Invoke-RestMethod -Uri $apiRoot -Headers $headers -ErrorAction Stop
    $versions = @($versionListing | ForEach-Object {
        if ($_.type -eq 'dir') {
            $parsed = [version]::new()
            if (-not [version]::TryParse([string]$_.name, [ref]$parsed)) {
                throw "WinGet manifest directory is not a version: $($_.name)"
            }
            [pscustomobject]@{ Name = [string]$_.name; Version = $parsed }
        }
    })
    $latest = $versions | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $latest) {
        throw "No versioned WinGet manifests were found at $ManifestPath."
    }

    $versionFiles = Invoke-RestMethod -Uri "$apiRoot/$($latest.Name)" -Headers $headers -ErrorAction Stop
    $installerFiles = @($versionFiles | Where-Object { $_.name -like '*.installer.yaml' })
    if ($installerFiles.Count -ne 1) {
        throw "Expected exactly one WinGet installer manifest for $($latest.Name), found $($installerFiles.Count)."
    }

    $manifestResponse = Invoke-RestMethod -Uri $installerFiles[0].url -Headers $headers -ErrorAction Stop
    $manifestText = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String(([string]$manifestResponse.content -replace '\s', ''))
    )
    $architectures = @([regex]::Matches($manifestText, '(?im)^\s*-\s*Architecture:\s*(?<architecture>[A-Za-z0-9]+)\s*$') |
        ForEach-Object { $_.Groups['architecture'].Value.ToLowerInvariant() } |
        Sort-Object -Unique)
    if (($architectures -join ',') -ne 'arm64,x64') {
        throw "Latest public WinGet manifest $($latest.Name) must contain exactly x64 and arm64 before a stable release (found: $($architectures -join ', '))."
    }

    Write-Status -Label 'WinGet architectures' -Value "x64 + arm64 ($($latest.Name))"
}

if ($RequireSigning) {
    $hasPfxBase64 = Test-EnvPresent -Name "WINDOWS_CODESIGN_PFX_BASE64"
    $hasPfxPath = Test-EnvPresent -Name "WINDOWS_CODESIGN_PFX_PATH"
    if ($hasPfxBase64 -and $hasPfxPath) {
        throw "Set only one of WINDOWS_CODESIGN_PFX_BASE64 or WINDOWS_CODESIGN_PFX_PATH."
    }
    if (-not $hasPfxBase64 -and -not $hasPfxPath) {
        throw "Required code-signing certificate was not configured: set WINDOWS_CODESIGN_PFX_BASE64 or WINDOWS_CODESIGN_PFX_PATH."
    }
    if ($hasPfxPath) {
        $pfxPath = Get-EnvValue -Name "WINDOWS_CODESIGN_PFX_PATH"
        if (-not (Test-Path -LiteralPath $pfxPath)) {
            throw "WINDOWS_CODESIGN_PFX_PATH does not exist: $pfxPath"
        }
    }
    Assert-EnvPresent -Name "WINDOWS_CODESIGN_PFX_PASSWORD"
    $minimumValidityDays = 180
    if (Test-EnvPresent -Name 'WINDOWS_CODESIGN_MIN_VALIDITY_DAYS') {
        if (-not [int]::TryParse((Get-EnvValue -Name 'WINDOWS_CODESIGN_MIN_VALIDITY_DAYS'), [ref]$minimumValidityDays) -or $minimumValidityDays -lt 180) {
            throw 'WINDOWS_CODESIGN_MIN_VALIDITY_DAYS must be an integer of at least 180.'
        }
    }
    $certificate = Import-CodeSigningCertificate `
        -PfxBase64 $(if ($hasPfxBase64) { Get-EnvValue -Name 'WINDOWS_CODESIGN_PFX_BASE64' } else { $null }) `
        -PfxPath $(if ($hasPfxPath) { Get-EnvValue -Name 'WINDOWS_CODESIGN_PFX_PATH' } else { $null }) `
        -Password (Get-EnvValue -Name 'WINDOWS_CODESIGN_PFX_PASSWORD')
    try {
        $signingPolicy = Assert-CodeSigningCertificatePolicy `
            -Certificate $certificate `
            -UpdaterSourcePath (Join-Path $repoRoot 'src/update/github_releases.zig') `
            -MinimumValidityDays $minimumValidityDays
    }
    finally {
        $certificate.Dispose()
    }
    Write-Status -Label "Code signing" -Value "enabled"
    Write-Status -Label "Signing source" -Value $(if ($hasPfxBase64) { "base64 secret" } else { "PFX path" })
    Write-Status -Label "Signer SPKI SHA-256" -Value $signingPolicy.SpkiSha256
    Write-Status -Label "Signer expires" -Value $signingPolicy.NotAfter.ToString('o')
    Write-Status -Label "Signer validity left" -Value "$($signingPolicy.RemainingValidityDays) days"
    Write-Status -Label "Signer identity" -Value $(if ($signingPolicy.SelfSigned) { 'self-signed; updater-pin constrained' } else { 'CA-issued; updater-pin constrained' })
    Write-Status -Label "Timestamp URL" -Value $timestampUrl
} else {
    Write-Status -Label "Code signing" -Value "not required"
}

Write-PresenceStatus -Label "WinGet package id" -Name "WINGET_PACKAGE_IDENTIFIER" -MissingMessage "missing (submit step will skip)" -Required:$RequirePackageManagers
Write-PresenceStatus -Label "Scoop repo" -Name "SCOOP_BUCKET_REPO" -MissingMessage "missing (publish step will skip)" -Required:$RequirePackageManagers
Write-PresenceStatus -Label "Scoop token" -Name "SCOOP_BUCKET_TOKEN" -MissingMessage "missing" -RedactValue -Required:$RequirePackageManagers
Write-PresenceStatus -Label "WinGet token" -Name "WINGETCREATE_TOKEN" -MissingMessage "missing" -RedactValue -Required:$RequirePackageManagers

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
        -Ref (Get-OptionalEnvValue -Name "SCOOP_BUCKET_BRANCH") `
        -Token (Get-GitHubApiToken -Names @("SCOOP_BUCKET_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"))
    $wingetReady = Test-GitHubContentPath `
        -Repository "microsoft/winget-pkgs" `
        -Path $wingetManifestPath `
        -Label "WinGet manifest" `
        -Token (Get-GitHubApiToken -Names @("WINGETCREATE_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"))

    if (-not $scoopReady) {
        throw "RequirePackageManagers was set, but the configured Scoop manifest does not exist."
    }
    if (-not $wingetReady) {
        throw "RequirePackageManagers was set, but $($env:WINGET_PACKAGE_IDENTIFIER) is not bootstrapped in microsoft/winget-pkgs."
    }
    Assert-WingetArchitectureCoverage `
        -ManifestPath $wingetManifestPath `
        -Token (Get-GitHubApiToken -Names @("WINGETCREATE_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"))
}

Write-Host "Release preflight passed."
