[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

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
$stageBase = Join-Path $outputRootPath "winghostty-$Version-windows-x64"
$portableRoot = Join-Path $stageBase "winghostty"
$zipPath = Join-Path $stageBase "winghostty-$Version-windows-x64-portable.zip"
$installerPath = Join-Path $stageBase "winghostty-$Version-windows-x64-setup.exe"
$checksumsPath = Join-Path $stageBase "SHA256SUMS.txt"
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

    return @{
        SignToolPath = $signToolPath
        PfxPath = $resolvedPfxPath
        PfxPassword = $signingPfxPassword
        TimestampUrl = $signingTimestampUrl
        Description = $signingDescription
        Url = $signingUrl
        TemporaryPfxPath = if ($hasBase64) { $resolvedPfxPath } else { $null }
    }
}

function Invoke-SignFile {
    param(
        [hashtable]$SigningConfig,
        [string]$PathToSign
    )

    & $SigningConfig.SignToolPath sign `
        /fd SHA256 `
        /f $SigningConfig.PfxPath `
        /p $SigningConfig.PfxPassword `
        /t $SigningConfig.TimestampUrl `
        /d $SigningConfig.Description `
        /du $SigningConfig.Url `
        $PathToSign

    if ($LASTEXITCODE -ne 0) {
        throw "signtool.exe failed for $PathToSign with exit code $LASTEXITCODE."
    }
}

function Assert-ValidSignature {
    param([string]$PathToCheck)

    $signature = Get-AuthenticodeSignature -LiteralPath $PathToCheck
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Expected a valid Authenticode signature on $PathToCheck, but got $($signature.Status): $($signature.StatusMessage)"
    }
}

$signingConfig = $null
$temporarySigningPfxPath = $null

try {
    $signingConfig = Get-SigningConfig
    if ($signingConfig) {
        $temporarySigningPfxPath = $signingConfig.TemporaryPfxPath
        Write-Host "Code signing : enabled"
    } else {
        Write-Host "Code signing : disabled"
    }

    if (-not $SkipBuild) {
        Push-Location $repoRoot
        try {
            & zig build -Demit-exe=true -Demit-lib-vt=true "-Dversion-string=$Version"
        }
        finally {
            Pop-Location
        }
    }

    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Expected build output was not found: $exePath"
    }

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
            Assert-ValidSignature -PathToCheck $destinationPath
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

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $portableRoot,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true
    )

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
        Assert-ValidSignature -PathToCheck $installerPath
    }
    elseif ($signingConfig -and $RequireInstaller) {
        throw "Signing was enabled, but the installer artifact was not produced."
    }

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
