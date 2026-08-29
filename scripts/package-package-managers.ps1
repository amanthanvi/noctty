[CmdletBinding()]
param(
    # $Version reaches a nuspec, artifact file names, and download URLs. The
    # release workflow already constrains it, but validate at the parameter so
    # manual and test invocations cannot inject path or URL fragments either.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$Tag,

    [string]$Repo = "amanthanvi/noctty",

    [string[]]$Architectures = @("x64"),

    [string]$ArtifactRoot,

    [string]$OutputRoot,

    [string]$UpstreamBaseVersion,

    [int]$FirstForkPatch = 0,

    [string]$WingetPackageIdentifier = "AmanThanvi.noctty",

    [string]$ScoopPackageName = "noctty"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "windows-architecture.ps1")

$Architectures = @($Architectures | ForEach-Object { (Get-WindowsPackageArchitecture -Architecture $_).Name })

$repoRoot = Get-RepoRoot
$tagValue = if ($Tag) { $Tag } else { "v$Version" }
if ($ArtifactRoot -and $Architectures.Count -ne 1) {
    throw "-ArtifactRoot can only be used with one architecture."
}
$primaryArch = if ($Architectures -contains "x64") { "x64" } else { $Architectures[0] }
$primaryArtifactRootPath = if ($ArtifactRoot) {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ArtifactRoot))
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "dist/artifacts/noctty-$Version-windows-$primaryArch"))
}
$outputRootPath = if ($OutputRoot) {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
} else {
    [System.IO.Path]::GetFullPath((Join-Path $primaryArtifactRootPath "package-managers"))
}

$iconName = "noctty-icon.svg"
$iconPath = Join-Path $primaryArtifactRootPath $iconName
$releaseBaseUrl = "https://github.com/$Repo/releases/download/$tagValue"
$projectUrl = "https://github.com/$Repo"
$releaseUrl = "$projectUrl/releases/tag/$tagValue"
$licenseUrl = "$projectUrl/blob/$tagValue/LICENSE"
$iconUrl = "$releaseBaseUrl/$iconName"
$packageDescription = @"
noctty is a Windows terminal emulator that reuses Ghostty's terminal core under a native Win32 front end.
"@.Trim()

function Reset-Directory {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-ChecksumMap {
    param([string]$Path)

    $checksums = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if (-not $line) {
            continue
        }

        if ($line -notmatch '^([0-9a-fA-F]{64}) \*(.+)$') {
            throw "Unsupported checksum line format in ${Path}: $line"
        }

        $checksums[$Matches[2]] = $Matches[1].ToLowerInvariant()
    }

    return $checksums
}

function Get-AssetChecksum {
    param(
        [hashtable]$ChecksumMap,
        [string]$ChecksumsPath,
        [string]$AssetName,
        [string]$AssetPath
    )

    if (-not (Test-Path -LiteralPath $AssetPath)) {
        throw "Expected asset was not found: $AssetPath"
    }

    $checksum = $ChecksumMap[$AssetName]
    if (-not $checksum) {
        throw "Missing checksum entry for $AssetName in $ChecksumsPath"
    }

    $actual = Get-FileSha256Lower -Path $AssetPath
    if ($actual -ne $checksum) {
        throw "Checksum mismatch for $AssetName. Expected $checksum, got $actual."
    }

    return $checksum
}

function Get-VersionLine {
    param([string]$InputVersion)

    if ($InputVersion -match '^(?<major>\d+)\.(?<minor>\d+)\.\d+(?:[.-].+)?$') {
        return "$($Matches.major).$($Matches.minor)"
    }

    throw "Unable to derive a version line from '$InputVersion'."
}

$artifacts = [ordered]@{}
foreach ($arch in $Architectures) {
    $artifactRootPath = if ($ArtifactRoot) {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ArtifactRoot))
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot "dist/artifacts/noctty-$Version-windows-$arch"))
    }

    $checksumsPath = Join-Path $artifactRootPath (New-WindowsPackageArtifactName -Version $Version -Architecture $arch -Kind checksums)
    $setupName = New-WindowsPackageArtifactName -Version $Version -Architecture $arch -Kind setup
    $portableName = New-WindowsPackageArtifactName -Version $Version -Architecture $arch -Kind portable
    $setupPath = Join-Path $artifactRootPath $setupName
    $portablePath = Join-Path $artifactRootPath $portableName

    foreach ($requiredPath in @($checksumsPath, $setupPath, $portablePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Expected packaging input was not found: $requiredPath"
        }
    }

    $checksumMap = Get-ChecksumMap -Path $checksumsPath
    $setupSha256 = Get-AssetChecksum -ChecksumMap $checksumMap -ChecksumsPath $checksumsPath -AssetName $setupName -AssetPath $setupPath
    $portableSha256 = Get-AssetChecksum -ChecksumMap $checksumMap -ChecksumsPath $checksumsPath -AssetName $portableName -AssetPath $portablePath

    $artifacts[$arch] = [ordered]@{
        setupName      = $setupName
        setupPath      = $setupPath
        setupUrl       = "$releaseBaseUrl/$setupName"
        setupSha256    = $setupSha256
        portableName   = $portableName
        portablePath   = $portablePath
        portableUrl    = "$releaseBaseUrl/$portableName"
        portableSha256 = $portableSha256
    }
}

if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Expected packaging input was not found: $iconPath"
}

$primaryArtifact = $artifacts[$primaryArch]
$versionLine = Get-VersionLine -InputVersion $Version

if ($UpstreamBaseVersion) {
    $upstreamLine = Get-VersionLine -InputVersion $UpstreamBaseVersion
    if ($upstreamLine -ne $versionLine) {
        throw "Release version '$Version' is on line $versionLine but UpstreamBaseVersion '$UpstreamBaseVersion' is on line $upstreamLine."
    }
}

Reset-Directory -Path $outputRootPath

$scoopRoot = Join-Path $outputRootPath "scoop"
$chocolateyRoot = Join-Path $outputRootPath "chocolatey"
$chocolateyToolsRoot = Join-Path $chocolateyRoot "tools"
$metadataPath = Join-Path $outputRootPath "metadata.json"
$scoopManifestPath = Join-Path $scoopRoot "$ScoopPackageName.json"
$chocolateyNuspecPath = Join-Path $chocolateyRoot "noctty.nuspec"
$chocolateyInstallPath = Join-Path $chocolateyToolsRoot "chocolateyInstall.ps1"

New-Item -ItemType Directory -Path $scoopRoot -Force | Out-Null
New-Item -ItemType Directory -Path $chocolateyToolsRoot -Force | Out-Null

$scoopManifest = [ordered]@{
    version      = $Version
    description  = $packageDescription
    homepage     = $projectUrl
    license      = "MIT"
    architecture = [ordered]@{}
    extract_dir  = "noctty"
    bin          = "noctty.exe"
}
foreach ($arch in $Architectures) {
    $scoopArch = (Get-WindowsPackageArchitecture -Architecture $arch).ScoopArchitecture
    $scoopManifest.architecture[$scoopArch] = [ordered]@{
        url  = $artifacts[$arch].portableUrl
        hash = $artifacts[$arch].portableSha256
    }
}
Set-Content -LiteralPath $scoopManifestPath -Value ($scoopManifest | ConvertTo-Json -Depth 5)

$escapedDescription = [System.Security.SecurityElement]::Escape($packageDescription)
$chocolateyNuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>noctty</id>
    <version>$Version</version>
    <title>noctty</title>
    <authors>Aman Thanvi</authors>
    <owners>Aman Thanvi</owners>
    <projectUrl>$projectUrl</projectUrl>
    <licenseUrl>$licenseUrl</licenseUrl>
    <iconUrl>$iconUrl</iconUrl>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <summary>$escapedDescription</summary>
    <description>$escapedDescription</description>
    <releaseNotes>$releaseUrl</releaseNotes>
    <copyright>Copyright Aman Thanvi</copyright>
    <tags>noctty terminal emulator windows ghostty</tags>
  </metadata>
  <files>
    <file src="tools\**" target="tools" />
  </files>
</package>
"@
Set-Content -LiteralPath $chocolateyNuspecPath -Value $chocolateyNuspec -Encoding utf8

$x64SetupUrl = if ($artifacts.Contains("x64")) { $artifacts["x64"].setupUrl } else { "" }
$x64SetupSha256 = if ($artifacts.Contains("x64")) { $artifacts["x64"].setupSha256 } else { "" }
$arm64SetupUrl = if ($artifacts.Contains("arm64")) { $artifacts["arm64"].setupUrl } else { "" }
$arm64SetupSha256 = if ($artifacts.Contains("arm64")) { $artifacts["arm64"].setupSha256 } else { "" }
$chocolateyInstall = @'
$ErrorActionPreference = 'Stop'

$machineArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$installers = @{
    x64 = @{
        url = '__X64_SETUP_URL__'
        checksum = '__X64_SETUP_SHA256__'
    }
    arm64 = @{
        url = '__ARM64_SETUP_URL__'
        checksum = '__ARM64_SETUP_SHA256__'
    }
}

if ($machineArchitecture -notin @('x64', 'arm64')) {
    throw "Unsupported Windows architecture for noctty: $machineArchitecture"
}

$installer = $installers[$machineArchitecture]
if ([string]::IsNullOrWhiteSpace($installer.url) -or [string]::IsNullOrWhiteSpace($installer.checksum)) {
    throw "The noctty Chocolatey package does not include a $machineArchitecture installer."
}

$packageArgs = @{
    packageName = 'noctty'
    fileType = 'exe'
    url = $installer.url
    checksum = $installer.checksum
    checksumType = 'sha256'
    silentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS'
    validExitCodes = @(0, 1641, 3010)
}

Install-ChocolateyPackage @packageArgs
'@
$chocolateyInstall = $chocolateyInstall.
    Replace("__X64_SETUP_URL__", $x64SetupUrl).
    Replace("__X64_SETUP_SHA256__", $x64SetupSha256).
    Replace("__ARM64_SETUP_URL__", $arm64SetupUrl).
    Replace("__ARM64_SETUP_SHA256__", $arm64SetupSha256)
Set-Content -LiteralPath $chocolateyInstallPath -Value $chocolateyInstall -Encoding utf8

$metadataArchitectures = [ordered]@{}
foreach ($arch in $Architectures) {
    $metadataArchitectures[$arch] = [ordered]@{
        installer = [ordered]@{
            name   = $artifacts[$arch].setupName
            path   = $artifacts[$arch].setupPath
            url    = $artifacts[$arch].setupUrl
            sha256 = $artifacts[$arch].setupSha256
        }
        portable  = [ordered]@{
            name   = $artifacts[$arch].portableName
            path   = $artifacts[$arch].portablePath
            url    = $artifacts[$arch].portableUrl
            sha256 = $artifacts[$arch].portableSha256
        }
    }
}

$metadata = [ordered]@{
    version     = $Version
    tag         = $tagValue
    repository  = $Repo
    versioning  = [ordered]@{
        scheme = "major.minor follow the Ghostty upstream line; patch is the noctty release number on that line"
        line   = $versionLine
    }
    release     = [ordered]@{
        baseUrl    = $releaseBaseUrl
        projectUrl = $projectUrl
        releaseUrl = $releaseUrl
        iconUrl    = $iconUrl
    }
    assets      = [ordered]@{
        installer = [ordered]@{
            name   = $primaryArtifact.setupName
            path   = $primaryArtifact.setupPath
            url    = $primaryArtifact.setupUrl
            sha256 = $primaryArtifact.setupSha256
        }
        portable  = [ordered]@{
            name   = $primaryArtifact.portableName
            path   = $primaryArtifact.portablePath
            url    = $primaryArtifact.portableUrl
            sha256 = $primaryArtifact.portableSha256
        }
        architectures = $metadataArchitectures
    }
    winget      = [ordered]@{
        packageIdentifier = $WingetPackageIdentifier
        version           = $Version
        installerUrl      = $primaryArtifact.setupUrl
        installerUrls     = @($Architectures | ForEach-Object { $artifacts[$_].setupUrl })
        # wingetcreate update documents URL architecture overrides as "<url>|<arch>".
        installerUrlArgs  = @($Architectures | ForEach-Object { "{0}|{1}" -f $artifacts[$_].setupUrl, $_ })
    }
    scoop      = [ordered]@{
        packageName   = $ScoopPackageName
        manifestPath  = $scoopManifestPath
        manifestRelPath = "$ScoopPackageName.json"
    }
    chocolatey = [ordered]@{
        packageName     = "noctty"
        nuspecPath      = $chocolateyNuspecPath
        packageDirectory = $chocolateyRoot
    }
}

if ($UpstreamBaseVersion) {
    $metadata.upstream = [ordered]@{
        baseVersion = $UpstreamBaseVersion
    }
}

if ($FirstForkPatch -gt 0) {
    $metadata.versioning.firstForkPatch = $FirstForkPatch
}

Set-Content -LiteralPath $metadataPath -Value ($metadata | ConvertTo-Json -Depth 8)

Write-Host "Scoop manifest         : $scoopManifestPath"
Write-Host "Chocolatey nuspec      : $chocolateyNuspecPath"
Write-Host "Metadata               : $metadataPath"
