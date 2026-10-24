[CmdletBinding()]
param(
    # $Version reaches a nuspec, artifact file names, and download URLs. The
    # release workflow already constrains it, but validate at the parameter so
    # manual and test invocations cannot inject path or URL fragments either.
    # \A and \z rather than ^ and $ because .NET's $ also matches before a
    # trailing newline, and [0-9] rather than \d because .NET's \d matches every
    # Unicode decimal digit. Both would otherwise pass a value that is not a
    # noctty release version.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string]$Version,

    [string]$Tag,

    [string]$Repo = "amanthanvi/noctty",

    [string[]]$Architectures = @("x64"),

    [string]$ArtifactRoot,

    # Where the per-architecture artifact folders are read from when -ArtifactRoot is not given.
    [string]$ArtifactBase = "dist/artifacts",

    [string]$OutputRoot,

    [string]$UpstreamBaseVersion,

    [int]$FirstForkPatch = 0,

    [string]$WingetPackageIdentifier = "AmanThanvi.noctty",

    [string]$ScoopPackageName = "noctty",

    # The revision of this script the Chocolatey package names as its source.
    # A release packs with the script at its own tag; a moderation fix repacks
    # an older version with a newer script and must name that commit.
    [ValidatePattern('\A[0-9A-Za-z][0-9A-Za-z._/-]*\z')]
    [string]$PackageSourceRef
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
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "$ArtifactBase/noctty-$Version-windows-$primaryArch"))
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
# Chocolatey's validator rejects an icon served from GitHub (CPMR0076), so the
# package points at the website's copy of the square mark
# (site/assets/favicon.svg) instead of the release asset.
$chocolateyIconUrl = "https://noctty.com/assets/favicon.svg"
$packageDescription = @"
noctty is a Windows terminal emulator that reuses Ghostty's terminal core under a native Win32 front end.
"@.Trim()
# The Chocolatey page shows the description as Markdown, so it carries the notes a
# user needs before installing: the signing certificate, PATH and updates.
$chocolateyDescription = @'
noctty is a Windows terminal emulator that reuses Ghostty's terminal core under a native Win32 front end. It requires Windows 10 version 1809 or later, or Windows 11, on __ARCHITECTURES__.

### Features

* Tabs and splits, with session restore of windows, tabs, splits and working directories (running programs are not restored)
* A shell picker for PowerShell, cmd, Git Bash, and WSL distributions
* A command palette
* Most Ghostty options and themes work as they are
* No telemetry; noctty uploads no crash reports (Windows Error Reporting follows your Windows settings)

### Package Notes

* The installer is signed with a self-signed certificate rather than one from a public certificate authority. This package checks each download against the SHA-256 published with the release.
* The installer does not add noctty to PATH.
* noctty checks GitHub Releases for updates and never installs one on its own: by default its notice opens the release page. Update with `choco upgrade noctty`, run from a terminal other than noctty, so Chocolatey's version record stays right. Set `auto-update = off` in the config to turn the check off.
'@.Trim()
# Name only the architectures this package carries installers for.
$chocolateyDescription = $chocolateyDescription.Replace('__ARCHITECTURES__', (($Architectures | ForEach-Object { if ($_ -eq 'arm64') { 'ARM64' } else { $_ } }) -join ' or '))

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
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot "$ArtifactBase/noctty-$Version-windows-$arch"))
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

# Scoop deletes the folder, and a default-terminal registration made from this
# copy points into it: every console launch would then fail to activate and
# fall back to conhost. The hook therefore runs `+unregister-default-terminal`
# through noctty.com, the console-subsystem shim, so Scoop waits for it. Four
# things keep it from doing harm:
# - Only `scoop uninstall`. Scoop sets $cmd to the subcommand that is running,
#   which can be `update` for the old version's hook, and an update must not
#   drop the user's registration.
# - Only a registration made from this app's Scoop folder. The action checks
#   the CLSID, not the path, so without this a Scoop uninstall would also drop
#   the selection of an installed or portable copy elsewhere (the installer
#   guards the same way in OwnsDefaultTerminalRegistration). Any version folder
#   counts, not just $dir: `scoop update` keeps the old folders, the
#   registration stays on the one it was made from (the registered path is the
#   resolved image path, so never the `current` junction), and uninstall
#   deletes them all.
# - Not while a copy is running. Scoop runs this hook before it checks for
#   running processes and then refuses to uninstall, which would leave noctty
#   installed with its registration gone (typing `scoop uninstall noctty` in a
#   noctty tab is the likeliest way to get here).
# - A failure is reported and swallowed; it never blocks the uninstall.
$scoopPreUninstall = @'
if ($cmd -eq 'uninstall') {
    $apps = [IO.Path]::GetFullPath((Split-Path -Parent $dir)) + '\'
    $noctty = Join-Path $dir 'noctty.com'
    $running = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($apps, [StringComparison]::OrdinalIgnoreCase) })
    $key = Get-Item -LiteralPath 'HKCU:\Software\Classes\CLSID\{33368C6F-D328-410C-B225-26DC9F12C728}\LocalServer32' -ErrorAction Ignore
    $registered = if ($key) { $key.GetValue('') }
    $registeredPath = if ($registered) { try { [IO.Path]::GetFullPath($registered.Trim('"')) } catch { '' } }
    $mine = $registeredPath -and $registeredPath.StartsWith($apps, [StringComparison]::OrdinalIgnoreCase)
    if ($running.Count -eq 0 -and $mine -and (Test-Path -LiteralPath $noctty -PathType Leaf)) {
        try {
            & $noctty '+unregister-default-terminal' | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host "noctty: could not unregister the default terminal (exit code $LASTEXITCODE)" }
        } catch { Write-Host "noctty: could not unregister the default terminal ($($_.Exception.Message))" }
    }
}
'@ -split "`r?`n"

$scoopManifest = [ordered]@{
    version       = $Version
    description   = $packageDescription
    homepage      = $projectUrl
    license       = "MIT"
    architecture  = [ordered]@{}
    extract_dir   = "noctty"
    bin           = "noctty.exe"
    pre_uninstall = $scoopPreUninstall
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
$escapedChocolateyDescription = [System.Security.SecurityElement]::Escape($chocolateyDescription)
$chocolateyNuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>noctty</id>
    <version>$Version</version>
    <packageSourceUrl>$projectUrl/blob/$(if ($PackageSourceRef) { $PackageSourceRef } else { $tagValue })/scripts/package-package-managers.ps1</packageSourceUrl>
    <title>Noctty</title>
    <authors>Aman Thanvi</authors>
    <owners>Aman Thanvi</owners>
    <projectUrl>$projectUrl</projectUrl>
    <projectSourceUrl>$projectUrl/tree/$tagValue</projectSourceUrl>
    <docsUrl>$projectUrl/blob/$tagValue/docs/getting-started.md</docsUrl>
    <bugTrackerUrl>$projectUrl/issues</bugTrackerUrl>
    <licenseUrl>$licenseUrl</licenseUrl>
    <iconUrl>$chocolateyIconUrl</iconUrl>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <summary>$escapedDescription</summary>
    <description>$escapedChocolateyDescription</description>
    <releaseNotes>$releaseUrl</releaseNotes>
    <copyright>Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors</copyright>
    <tags>noctty terminal terminal-emulator emulator console windows ghostty foss</tags>
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

# Setup closes a running noctty, and noctty declines to close while a pane runs a program. Run
# from inside a noctty window, Chocolatey is that program, so Setup would stop with exit 5. Refuse
# up front with a clear message instead, before the installer is downloaded. Nothing is stopped here:
# closing noctty is Setup's job, through Restart Manager.
function Open-NocttyRegistryBaseKey([Microsoft.Win32.RegistryHive] $Hive, [Microsoft.Win32.RegistryView] $View) {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
}

function Get-NocttyInstallDirectory {
    # Setup reuses the previous directory, so a custom location is recorded in its uninstall key.
    # Setup installs in 64-bit mode, so the machine-wide key is in the 64-bit registry view, which
    # the HKLM: drive of a 32-bit PowerShell does not show. HKCU\SOFTWARE is the same in both views.
    $uninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\io.github.amanthanvi.winghostty_is1'
    $location = $null
    try {
        $machine = Open-NocttyRegistryBaseKey -Hive LocalMachine -View Registry64
        try {
            $entry = $machine.OpenSubKey($uninstallKey)
            if ($entry) {
                try { $location = $entry.GetValue('InstallLocation') } finally { $entry.Close() }
            }
        } finally { $machine.Close() }
    } catch {
        $location = $null
    }
    if (-not $location) {
        $entry = Get-ItemProperty -Path "HKCU:\$uninstallKey" -Name InstallLocation -ErrorAction SilentlyContinue
        if ($entry) { $location = $entry.InstallLocation }
    }
    if ($location) { return ([string] $location).TrimEnd('\') }
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    Join-Path $programFiles 'noctty'
}

function Assert-NotInsideNoctty {
    # With no noctty running there is nothing for Setup to close, and nothing to query.
    if (-not (Get-Process -Name 'noctty' -ErrorAction SilentlyContinue)) { return }

    $insideMessage = 'noctty cannot be upgraded from one of its own windows: Setup has to close noctty, and noctty cannot close while Chocolatey is running in it. Run this from another terminal.'
    $installPrefix = (Get-NocttyInstallDirectory) + [IO.Path]::DirectorySeparatorChar

    # Walk this process's ancestors and refuse when one of them runs from the install directory.
    $seen = @()
    $current = $PID
    $childStarted = $null
    while ($current -and $seen -notcontains $current) {
        $seen += $current
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $current" -OperationTimeoutSec 15 -ErrorAction Stop
        } catch {
            throw 'noctty is running, but the process list could not be read, so it cannot be checked whether Chocolatey is running inside a noctty window. Close noctty and run the upgrade again.'
        }
        if (-not $proc) { break }
        # A parent that is not older than its child is a reused process ID: the real chain has ended.
        if ($childStarted -and $proc.CreationDate -and $proc.CreationDate -ge $childStarted) { break }
        if ($proc.ExecutablePath -and $proc.ExecutablePath.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw $insideMessage
        }
        $childStarted = $proc.CreationDate
        $current = $proc.ParentProcessId
    }

    # A console that noctty hosts as the default terminal has no noctty ancestor: its host is
    # Windows Terminal's OpenConsole and noctty runs as a separate COM server (noctty.exe -Embedding;
    # COM adds -Embedding to the toast activator too, which has -ToastActivated and hosts nothing).
    # Refuse when noctty is the default terminal, that server is running and this console is a pseudo
    # console. Every pseudo console qualifies, a Windows Terminal tab included, so the message cannot
    # say that this window is noctty's; it says which windows to close and where to run the upgrade.
    # The server hosts the tabs and windows opened from its windows too, and exits a few seconds
    # after its last one closes.
    # This is best effort and can refuse when closing noctty would not end the console; if it cannot
    # be evaluated, Restart Manager still makes the upgrade fail safely.
    $handoffMessage = 'noctty is your default terminal and is hosting console windows, and this window may be one of them. Close the console windows noctty opened as the default terminal, and any tabs or windows opened from them, and wait a few seconds. Then run the upgrade again from a terminal app such as Windows Terminal: while noctty is the default terminal, new console windows open in noctty too.'
    $handedOff = $false
    try {
        $startup = Get-ItemProperty -LiteralPath 'HKCU:\Console\%%Startup' -Name DelegationTerminal -ErrorAction SilentlyContinue
        if ($startup -and $startup.DelegationTerminal -eq '{33368C6F-D328-410C-B225-26DC9F12C728}') {
            # Like noctty itself, read the switches after the executable and before -e, after which
            # everything belongs to the command a pane runs.
            $server = @(Get-CimInstance Win32_Process -Filter "Name = 'noctty.exe'" -OperationTimeoutSec 15 -ErrorAction Stop) |
                Where-Object {
                    $switches = (($_.CommandLine -replace '^\s*(?:"[^"]*"|\S+)', '') -csplit '\s-e(?:\s|$)', 2)[0]
                    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase) -and $switches -match '(^|\s)-Embedding(\s|$)' -and $switches -notmatch '(^|\s)-ToastActivated(\s|$)'
                }
            if ($server) {
                Add-Type -Namespace NocttyGuard -Name Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int maxCount);'
                $window = [NocttyGuard.Native]::GetConsoleWindow()
                if ($window -ne [IntPtr]::Zero) {
                    $className = New-Object System.Text.StringBuilder 256
                    [void][NocttyGuard.Native]::GetClassName($window, $className, $className.Capacity)
                    $handedOff = $className.ToString() -eq 'PseudoConsoleWindow'
                }
            }
        }
    } catch {
        $handedOff = $false
    }
    if ($handedOff) { throw $handoffMessage }
}
Assert-NotInsideNoctty

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

# Chocolatey runs as an emulated x64 process on ARM64 Windows, so OSArchitecture reports x64 there.
# Ask the CPU itself (Win32_Processor.Architecture 12 = ARM64) so ARM64 machines get the ARM64 installer
# when this package carries one. Without one, the x64 choice stands: emulated x64 runs there.
$machineArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if (-not [string]::IsNullOrWhiteSpace($installers.arm64.url)) {
    try {
        if ((Get-CimInstance Win32_Processor -Property Architecture -OperationTimeoutSec 10 -ErrorAction SilentlyContinue | Select-Object -First 1).Architecture -eq 12) {
            $machineArchitecture = 'arm64'
        }
    }
    catch {
        # Keep the OSArchitecture result if the CPU cannot be queried.
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
