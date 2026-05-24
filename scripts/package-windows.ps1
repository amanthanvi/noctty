[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [ValidateSet("x64", "arm64")]
    [string]$Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }),

    [string]$OutputRoot = "dist/artifacts",

    [switch]$SkipBuild,

    [switch]$RequireInstaller,

    [switch]$RequireSigning
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$outputRootPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
$userHome = if ($env:USERPROFILE) {
    $env:USERPROFILE
} elseif ($env:HOMEDRIVE -and $env:HOMEPATH) {
    "$($env:HOMEDRIVE)$($env:HOMEPATH)"
} else {
    Join-Path "C:" "Users"
}
$localAppData = if ($env:LOCALAPPDATA) {
    $env:LOCALAPPDATA
} else {
    Join-Path $userHome "AppData\Local"
}
$zigTarget = switch ($Architecture) {
    "x64" { "x86_64-windows-msvc" }
    "arm64" { "aarch64-windows-msvc" }
}
$stageBase = Join-Path $outputRootPath "winghostty-$Version-windows-$Architecture"
$portableRoot = Join-Path $stageBase "winghostty"
$zipPath = Join-Path $stageBase "winghostty-$Version-windows-$Architecture-portable.zip"
$installerPath = Join-Path $stageBase "winghostty-$Version-windows-$Architecture-setup.exe"
$checksumsPath = Join-Path $stageBase "SHA256SUMS-windows-$Architecture.txt"
$releaseIconPath = Join-Path $stageBase "winghostty-icon.svg"
$zigOutBin = Join-Path $repoRoot "zig-out/bin"
$zigOutShare = Join-Path $repoRoot "zig-out/share"
$exePath = Join-Path $zigOutBin "winghostty.exe"
$runtimeFiles = @(
    "winghostty.com",
    "winghostty.exe",
    "ghostty-vt.dll"
)
$licensePath = Join-Path $repoRoot "LICENSE"
$readmePath = Join-Path $repoRoot "README.md"
$configTemplatePath = Join-Path $repoRoot "src/config/config-template"
$innoScriptPath = Join-Path $repoRoot "dist/windows/winghostty.iss"
$iconPath = Join-Path $repoRoot "dist/windows/winghostty.ico"
$releaseIconSourcePath = Join-Path $repoRoot "images/winghostty-flag-light.svg"
$signingPfxPath = if ($env:WINDOWS_CODESIGN_PFX_PATH) {
    $env:WINDOWS_CODESIGN_PFX_PATH
} else {
    $null
}
$signingPfxBase64 = if ($env:WINDOWS_CODESIGN_PFX_BASE64) {
    $env:WINDOWS_CODESIGN_PFX_BASE64
} else {
    $null
}
$signingPfxPassword = if ($env:WINDOWS_CODESIGN_PFX_PASSWORD) {
    $env:WINDOWS_CODESIGN_PFX_PASSWORD
} else {
    $null
}
$signingTimestampUrl = if ($env:WINDOWS_CODESIGN_TIMESTAMP_URL) {
    $env:WINDOWS_CODESIGN_TIMESTAMP_URL
} else {
    "http://timestamp.digicert.com"
}
$signingDescription = if ($env:WINDOWS_CODESIGN_DESCRIPTION) {
    $env:WINDOWS_CODESIGN_DESCRIPTION
} else {
    "winghostty"
}
$signingUrl = if ($env:WINDOWS_CODESIGN_URL) {
    $env:WINDOWS_CODESIGN_URL
} else {
    "https://github.com/amanthanvi/winghostty"
}
$trustSelfSignedSigningCert = if ($env:WINDOWS_CODESIGN_TRUST_SELF_SIGNED) {
    $env:WINDOWS_CODESIGN_TRUST_SELF_SIGNED
} else {
    $null
}
$preferredSignToolPath = if ($env:WINDOWS_CODESIGN_SIGNTOOL_PATH) {
    $env:WINDOWS_CODESIGN_SIGNTOOL_PATH
} else {
    $null
}

if (-not $env:ZIG_LOCAL_CACHE_DIR) {
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $repoRoot ".zig-cache"
}
if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $localAppData "zig"
}

New-Item -ItemType Directory -Path $env:ZIG_LOCAL_CACHE_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $env:ZIG_GLOBAL_CACHE_DIR -Force | Out-Null

function Remove-TreeIfPresent {
    param([string]$PathToRemove)

    if (-not (Test-Path -LiteralPath $PathToRemove)) {
        return
    }

    $resolved = [System.IO.Path]::GetFullPath($PathToRemove)
    if (-not $resolved.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside repo root: $resolved"
    }

    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Copy-Tree {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

function Get-PeMachine {
    param([string]$PathToCheck)

    $fullPath = (Resolve-Path -LiteralPath $PathToCheck).Path
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        try {
            if ($reader.ReadUInt16() -ne 0x5A4D) {
                throw "Not a PE file: $fullPath"
            }

            $stream.Position = 0x3C
            $peOffset = $reader.ReadUInt32()
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) {
                throw "Missing PE signature: $fullPath"
            }

            return $reader.ReadUInt16()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-PeMachine {
    param(
        [string]$PathToCheck,
        [string]$ExpectedArchitecture
    )

    $expectedMachine = switch ($ExpectedArchitecture) {
        "x64" { 0x8664 }
        "arm64" { 0xAA64 }
    }
    $actualMachine = Get-PeMachine -PathToCheck $PathToCheck
    if ($actualMachine -ne $expectedMachine) {
        throw ("Expected {0} to be {1} PE machine 0x{2:X4}, got 0x{3:X4}." -f $PathToCheck, $ExpectedArchitecture, $expectedMachine, $actualMachine)
    }
}

function Find-SignTool {
    param([string]$PreferredPath)

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        if (-not (Test-Path -LiteralPath $PreferredPath)) {
            throw "Configured signtool.exe path was not found: $PreferredPath"
        }

        return [System.IO.Path]::GetFullPath($PreferredPath)
    }

    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $sdkRoots = @(
        "C:\Program Files (x86)\Windows Kits\10\bin",
        "C:\Program Files\Windows Kits\10\bin"
    )

    foreach ($sdkRoot in $sdkRoots) {
        if (-not (Test-Path -LiteralPath $sdkRoot)) {
            continue
        }

        $sdkVersions = Get-ChildItem -LiteralPath $sdkRoot -Directory | Sort-Object Name -Descending
        foreach ($sdkVersion in $sdkVersions) {
            $candidate = Join-Path $sdkVersion.FullName "x64\signtool.exe"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    return $null
}

function ConvertTo-Boolean {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "off" { return $false }
        default {
            throw "Expected WINDOWS_CODESIGN_TRUST_SELF_SIGNED to be one of: true, false, 1, 0, yes, no, on, off."
        }
    }
}

function Test-SelfSignedTrustStatus {
    param([System.Management.Automation.Signature]$Signature)

    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) {
        return $true
    }

    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::NotTrusted) {
        return $true
    }

    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::UnknownError) {
        return $false
    }

    $message = if ($Signature.StatusMessage) { $Signature.StatusMessage } else { "" }
    return $message -match "root certificate.*not trusted|self-signed|not trusted by the trust provider"
}

function New-TemporaryPfxFile {
    param([string]$Base64Value)

    try {
        $bytes = [Convert]::FromBase64String($Base64Value)
    }
    catch {
        throw "WINDOWS_CODESIGN_PFX_BASE64 was not valid base64."
    }

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-signing-" + [System.Guid]::NewGuid().ToString("N") + ".pfx")
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

function Get-SigningConfig {
    $hasPath = -not [string]::IsNullOrWhiteSpace($signingPfxPath)
    $hasBase64 = -not [string]::IsNullOrWhiteSpace($signingPfxBase64)

    if ($hasPath -and $hasBase64) {
        throw "Set only one of WINDOWS_CODESIGN_PFX_PATH or WINDOWS_CODESIGN_PFX_BASE64."
    }

    if (-not $hasPath -and -not $hasBase64) {
        if ($RequireSigning) {
            throw "Release signing is required, but no code-signing certificate was configured."
        }

        return $null
    }

    if ([string]::IsNullOrWhiteSpace($signingPfxPassword)) {
        throw "WINDOWS_CODESIGN_PFX_PASSWORD must be set when release signing is enabled."
    }

    $signToolPath = Find-SignTool -PreferredPath $preferredSignToolPath
    if (-not $signToolPath) {
        throw "signtool.exe was not found. Install the Windows SDK or set WINDOWS_CODESIGN_SIGNTOOL_PATH."
    }

    $resolvedPfxPath = if ($hasBase64) {
        New-TemporaryPfxFile -Base64Value $signingPfxBase64
    } else {
        [System.IO.Path]::GetFullPath($signingPfxPath)
    }

    if (-not (Test-Path -LiteralPath $resolvedPfxPath)) {
        throw "Configured code-signing certificate was not found: $resolvedPfxPath"
    }

    $trustSelfSigned = ConvertTo-Boolean -Value $trustSelfSignedSigningCert
    $signingCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $resolvedPfxPath,
        $signingPfxPassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    )
    $isSelfSigned = $signingCert.Subject -eq $signingCert.Issuer

    if ($trustSelfSigned -and -not $isSelfSigned) {
        throw "WINDOWS_CODESIGN_TRUST_SELF_SIGNED=true is only supported for a self-signed PFX."
    }

    return @{
        SignToolPath = $signToolPath
        PfxPath = $resolvedPfxPath
        PfxPassword = $signingPfxPassword
        TimestampUrl = if ($trustSelfSigned) { $null } else { $signingTimestampUrl }
        Description = $signingDescription
        Url = $signingUrl
        TemporaryPfxPath = if ($hasBase64) { $resolvedPfxPath } else { $null }
        CertificateThumbprint = $signingCert.Thumbprint
        IsSelfSigned = $isSelfSigned
        TrustSelfSigned = $trustSelfSigned
    }
}

function Invoke-SignFile {
    param(
        [hashtable]$SigningConfig,
        [string]$PathToSign
    )

    $signArgs = @(
        "sign",
        "/fd", "SHA256",
        "/f", $SigningConfig.PfxPath,
        "/p", $SigningConfig.PfxPassword
    )

    if (-not [string]::IsNullOrWhiteSpace($SigningConfig.TimestampUrl)) {
        $signArgs += @("/t", $SigningConfig.TimestampUrl)
    }

    $signArgs += @(
        "/d", $SigningConfig.Description,
        "/du", $SigningConfig.Url,
        $PathToSign
    )

    & $SigningConfig.SignToolPath @signArgs

    if ($LASTEXITCODE -ne 0) {
        throw "signtool.exe failed for $PathToSign with exit code $LASTEXITCODE."
    }
}

function Assert-ValidSignature {
    param(
        [string]$PathToCheck,
        [hashtable]$SigningConfig
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $PathToCheck
    if ($SigningConfig -and $SigningConfig.TrustSelfSigned) {
        if (-not $signature.SignerCertificate) {
            throw "Expected a self-signed Authenticode signature on $PathToCheck, but no signer certificate was present."
        }

        if ($signature.SignerCertificate.Thumbprint -ne $SigningConfig.CertificateThumbprint) {
            throw "Expected signer thumbprint $($SigningConfig.CertificateThumbprint) on $PathToCheck, but got $($signature.SignerCertificate.Thumbprint)."
        }

        if (-not (Test-SelfSignedTrustStatus -Signature $signature)) {
            throw "Expected a self-signed Authenticode signature on $PathToCheck, but got $($signature.Status): $($signature.StatusMessage)"
        }

        return
    }

    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Expected a valid Authenticode signature on $PathToCheck, but got $($signature.Status): $($signature.StatusMessage)"
    }
}

$signingConfig = $null
$temporarySigningPfxPath = $null

try {
    Write-Host "Signing config: loading"
    $signingConfig = Get-SigningConfig
    Write-Host "Signing config: loaded"
    if ($signingConfig) {
        $temporarySigningPfxPath = $signingConfig.TemporaryPfxPath
        Write-Host "Code signing : enabled"
        if ($signingConfig.TrustSelfSigned) {
            Write-Host "Signing trust: validating self-signed signatures by expected signer thumbprint"
            Write-Host "Timestamping : disabled for self-signed signing"
        }
    } else {
        Write-Host "Code signing : disabled"
    }

    if (-not $SkipBuild) {
        Push-Location $repoRoot
        try {
            & zig build -Demit-exe=true -Demit-lib-vt=true -Doptimize=ReleaseFast "-Dtarget=$zigTarget" -Dcpu=baseline "-Dversion-string=$Version"
        }
        finally {
            Pop-Location
        }
    }

    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Expected build output was not found: $exePath"
    }

    Write-Host "Packaging arch : $Architecture ($zigTarget)"
    foreach ($runtimeFile in $runtimeFiles) {
        $runtimePath = Join-Path $zigOutBin $runtimeFile
        if (-not (Test-Path -LiteralPath $runtimePath)) {
            throw "Expected build output was not found: $runtimePath"
        }
        Assert-PeMachine -PathToCheck $runtimePath -ExpectedArchitecture $Architecture
    }
    if ($Architecture -eq "x64") {
        & (Join-Path $repoRoot "scripts/check-windows-x64-baseline.ps1") -Path $exePath
    }

    Write-Host "Packaging phase: stage portable tree"
    Remove-TreeIfPresent -PathToRemove $stageBase
    New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null

    foreach ($runtimeFile in $runtimeFiles) {
        $runtimePath = Join-Path $zigOutBin $runtimeFile
        if (-not (Test-Path -LiteralPath $runtimePath)) {
            throw "Expected runtime artifact was not found: $runtimePath"
        }

        $destinationPath = Join-Path $portableRoot $runtimeFile
        Copy-Item -LiteralPath $runtimePath -Destination $destinationPath -Force

        if ($signingConfig -and @(".exe", ".dll") -contains [System.IO.Path]::GetExtension($destinationPath)) {
            Invoke-SignFile -SigningConfig $signingConfig -PathToSign $destinationPath
            Assert-ValidSignature -PathToCheck $destinationPath -SigningConfig $signingConfig
        }
    }

    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $portableRoot "LICENSE") -Force
    Copy-Item -LiteralPath $configTemplatePath -Destination (Join-Path $portableRoot "config-template.ghostty") -Force
    Copy-Item -LiteralPath $readmePath -Destination (Join-Path $portableRoot "README.md") -Force
    Copy-Item -LiteralPath $iconPath -Destination (Join-Path $portableRoot "winghostty.ico") -Force
    Copy-Item -LiteralPath $releaseIconSourcePath -Destination $releaseIconPath -Force

    if (Test-Path -LiteralPath $zigOutShare) {
        Copy-Tree -Source $zigOutShare -Destination $portableRoot
    }

    Write-Host "Packaging phase: create portable zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $portableRoot,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true
    )

    Write-Host "Packaging phase: build installer"
    $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if (-not $iscc) {
        $candidates = @(
            (Join-Path $localAppData "Programs\Inno Setup 6\ISCC.exe"),
            "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
            "C:\Program Files\Inno Setup 6\ISCC.exe"
        )
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) {
                $iscc = @{ Source = $candidate }
                break
            }
        }
    }

    if ($iscc) {
        & $iscc.Source `
            "/DMyAppVersion=$Version" `
            "/DPackageArch=$Architecture" `
            "/DStageDir=$portableRoot" `
            "/DOutputDir=$stageBase" `
            "/DSourceDir=$repoRoot" `
            $innoScriptPath

        if ($LASTEXITCODE -ne 0) {
            throw "ISCC.exe failed with exit code $LASTEXITCODE."
        }
    }
    elseif ($RequireInstaller) {
        throw "Inno Setup compiler (ISCC.exe) was not found."
    }
    else {
        Write-Warning "ISCC.exe not found. Skipping installer build."
    }

    if ($signingConfig -and (Test-Path -LiteralPath $installerPath)) {
        Invoke-SignFile -SigningConfig $signingConfig -PathToSign $installerPath
        Assert-ValidSignature -PathToCheck $installerPath -SigningConfig $signingConfig
    }
    elseif ($signingConfig -and $RequireInstaller) {
        throw "Signing was enabled, but the installer artifact was not produced."
    }

    Write-Host "Packaging phase: write checksums"
    $hashTargets = @(
        @{
            Name = [System.IO.Path]::GetFileName($zipPath)
            Path = $zipPath
        }
    )

    if (Test-Path -LiteralPath $installerPath) {
        $hashTargets += @{
            Name = [System.IO.Path]::GetFileName($installerPath)
            Path = $installerPath
        }
    }

    $hashLines = foreach ($target in $hashTargets) {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target.Path).Hash.ToLowerInvariant()
        "$hash *$($target.Name)"
    }

    Set-Content -LiteralPath $checksumsPath -Value $hashLines

    Write-Host "Portable ZIP: $zipPath"
    if (Test-Path -LiteralPath $installerPath) {
        Write-Host "Installer    : $installerPath"
    }
    Write-Host "Checksums    : $checksumsPath"
}
finally {
    if ($temporarySigningPfxPath -and (Test-Path -LiteralPath $temporarySigningPfxPath)) {
        Remove-Item -LiteralPath $temporarySigningPfxPath -Force
    }
}
