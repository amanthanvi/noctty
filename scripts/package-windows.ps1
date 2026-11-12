[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Architecture = $null,

    [string]$OutputRoot = "dist/artifacts",

    [switch]$SkipBuild,

    [switch]$RequireInstaller,

    [switch]$RequireSigning,

    [switch]$RequireConPty,

    [switch]$RequireSymbols
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "windows-architecture.ps1")
. (Join-Path $PSScriptRoot "symbols-verification.ps1")
. (Join-Path $PSScriptRoot "signing-trust.ps1")
. (Join-Path $PSScriptRoot "windows-build-capabilities.ps1")
. (Join-Path $PSScriptRoot "conpty-redist.ps1")
. (Join-Path $PSScriptRoot "ghostty-vt-stub.ps1")

$archInfo = Get-WindowsPackageArchitecture -Architecture $(if ($Architecture) { $Architecture } else { Get-DefaultWindowsPackageArchitecture })
$Architecture = $archInfo.Name

$repoRoot = Get-RepoRoot
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
$zigTarget = $archInfo.ZigTarget
$stageBase = Join-Path $outputRootPath "koreterm-$Version-windows-$Architecture"
$portableRoot = Join-Path $stageBase "koreterm"
$zipPath = Join-Path $stageBase (New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind portable)
$manifestPath = Join-Path $stageBase (New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind manifest)
$installerPath = Join-Path $stageBase (New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind setup)
$symbolsPath = Join-Path $stageBase (New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind symbols)
$symbolsRoot = Join-Path $stageBase "symbols"
$checksumsPath = Join-Path $stageBase (New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind checksums)
$releaseIconPath = Join-Path $stageBase "koreterm-icon.svg"
$zigOutBin = Join-Path $repoRoot "zig-out/bin"
$zigOutShare = Join-Path $repoRoot "zig-out/share"
$exePath = Join-Path $zigOutBin "koreterm.exe"
$buildCapabilitiesPath = Join-Path $zigOutBin "koreterm-build-capabilities.json"
# Paths under zig-out\bin; each is staged at the portable root under its leaf
# name.
$runtimeFiles = @(
    "koreterm.com",
    "koreterm.exe",
    # The ghostty-vt.dll placeholder (src/build/GhosttyVtStub.zig), not
    # libghostty-vt: it exports nothing and fails to load. The portable
    # updater of 1.3.125 to 1.3.136 refuses a ZIP without a ghostty-vt.dll.
    # Never stage zig-out\bin\ghostty-vt.dll, the -Demit-lib-vt=true library:
    # portable_zip_carries_legacy_entries in src/update/portable_apply.zig
    # says when the placeholder goes.
    "ghostty-vt-stub\ghostty-vt.dll",
    "koreterm-terminal-handoff-proxy.dll"
)
$licensePath = Join-Path $repoRoot "LICENSE"
$conptyLicensePath = Join-Path $repoRoot "dist/windows/LICENSE-conpty.txt"
$conptyPinPath = Join-Path $repoRoot "dist/windows/conpty-redist.json"
$conptyCacheRoot = Join-Path $localAppData "koreterm/cache/conpty"
$readmePath = Join-Path $repoRoot "README.md"
$configTemplatePath = Join-Path $repoRoot "src/config/config-template"
$innoScriptPath = Join-Path $repoRoot "dist/windows/koreterm.iss"
$iconPath = Join-Path $repoRoot "dist/windows/koreterm.ico"
$releaseIconSourcePath = Join-Path $repoRoot "images/koreterm-flag-light.svg"
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
    "koreterm"
}
$signingUrl = if ($env:WINDOWS_CODESIGN_URL) {
    $env:WINDOWS_CODESIGN_URL
} else {
    "https://github.com/richardsonvix/noctty_terminal"
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

function New-TemporaryPfxFile {
    param([string]$Base64Value)

    try {
        $bytes = [Convert]::FromBase64String($Base64Value)
    }
    catch {
        throw "WINDOWS_CODESIGN_PFX_BASE64 was not valid base64."
    }

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("koreterm-signing-" + [System.Guid]::NewGuid().ToString("N") + ".pfx")
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

# Microsoft.ArtifactSigning.Client, the signtool dlib for Azure Artifact
# Signing. Pinned by version and by the SHA-512 that nuget.org's catalog
# records for it, so the code that receives the signing token cannot change
# under a release.
$artifactSigningClientVersion = "1.0.146"
$artifactSigningClientSha512 = "/G0hG/VDIS6psW23b5t1V/ORIgn0PVAOtGj9w+hkPmAuI4pempfwlW50E2GtHscnz9+5Qz3hbC4mcb7ej2Yn1A=="
# Microsoft documents the dlib as unsupported with older SignTool builds,
# naming the 20348 SDK.
$artifactSigningMinimumSignToolVersion = [version]"10.0.22621.755"

function Remove-ArtifactSigningTemporaryRoot {
    param([string]$Path)

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ([System.IO.Path]::GetDirectoryName($resolved) -ne $tempRoot -or
        [System.IO.Path]::GetFileName($resolved) -notmatch '\Akoreterm-artifact-signing-[0-9a-f]{32}\z') {
        throw "Refusing to remove an unexpected Artifact Signing temporary path: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function Get-ArtifactSigningConfig {
    param([pscustomobject]$Configuration)

    $signToolPath = Find-SignTool -PreferredPath $preferredSignToolPath
    if (-not $signToolPath) {
        throw "signtool.exe was not found. Install the Windows SDK or set WINDOWS_CODESIGN_SIGNTOOL_PATH."
    }
    Assert-PeMachine -PathToCheck $signToolPath -ExpectedArchitecture x64
    $signToolInfo = (Get-Item -LiteralPath $signToolPath).VersionInfo
    $signToolVersion = [version]::new($signToolInfo.FileMajorPart, $signToolInfo.FileMinorPart, $signToolInfo.FileBuildPart, $signToolInfo.FilePrivatePart)
    if ($signToolVersion -lt $artifactSigningMinimumSignToolVersion) {
        throw "Azure Artifact Signing needs signtool.exe $artifactSigningMinimumSignToolVersion or newer; $signToolPath is $signToolVersion."
    }

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("koreterm-artifact-signing-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $temporaryRoot "client.nupkg"
        $clientRoot = Join-Path $temporaryRoot "client"
        Invoke-WebRequest `
            -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.artifactsigning.client/$artifactSigningClientVersion/microsoft.artifactsigning.client.$artifactSigningClientVersion.nupkg" `
            -OutFile $packagePath `
            -UseBasicParsing
        $packageSha512 = [Convert]::ToBase64String(
            [System.Security.Cryptography.SHA512]::HashData([System.IO.File]::ReadAllBytes($packagePath))
        )
        if ($packageSha512 -cne $artifactSigningClientSha512) {
            throw "Microsoft.ArtifactSigning.Client $artifactSigningClientVersion does not match its pinned SHA-512 (got $packageSha512)."
        }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $clientRoot)
        $dlibPath = Join-Path $clientRoot "bin\x64\Azure.CodeSigning.Dlib.dll"
        if (-not (Test-Path -LiteralPath $dlibPath -PathType Leaf)) {
            throw "Microsoft.ArtifactSigning.Client $artifactSigningClientVersion has no x64 dlib at $dlibPath."
        }

        # Only the workload-identity credential may answer: it reads the
        # GitHub OIDC token Invoke-SignFile writes, and nothing else on the
        # runner (an Azure CLI login, a managed identity) can stand in for the
        # release job.
        $metadataPath = Join-Path $temporaryRoot "metadata.json"
        [ordered]@{
            Endpoint = $Configuration.Endpoint
            CodeSigningAccountName = $Configuration.AccountName
            CertificateProfileName = $Configuration.CertificateProfileName
            CorrelationId = "koreterm-$Version-windows-$Architecture"
            ExcludeCredentials = @(
                "EnvironmentCredential",
                "ManagedIdentityCredential",
                "SharedTokenCacheCredential",
                "VisualStudioCredential",
                "VisualStudioCodeCredential",
                "AzureCliCredential",
                "AzurePowerShellCredential",
                "AzureDeveloperCliCredential",
                "InteractiveBrowserCredential"
            )
        } | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding utf8
    }
    catch {
        Remove-ArtifactSigningTemporaryRoot -Path $temporaryRoot
        throw
    }

    return @{
        SignToolPath = $signToolPath
        DlibPath = $dlibPath
        MetadataPath = $metadataPath
        FederatedTokenPath = Join-Path $temporaryRoot "github-oidc.jwt"
        TenantId = $Configuration.TenantId
        ClientId = $Configuration.ClientId
        # Leaf certificates last three days, so the timestamp is what keeps a
        # signature valid; preflight requires WINDOWS_CODESIGN_TIMESTAMP_URL.
        TimestampUrl = $signingTimestampUrl
        Description = $signingDescription
        Url = $signingUrl
        TemporaryRoot = $temporaryRoot
        Label = "Azure Artifact Signing ($($Configuration.AccountName)/$($Configuration.CertificateProfileName))"
    }
}

function Get-SigningConfig {
    $artifactSigning = Get-ArtifactSigningConfiguration
    if ($artifactSigning) {
        return Get-ArtifactSigningConfig -Configuration $artifactSigning
    }

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
        Certificate = $signingCert
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
        "/fd", "SHA256"
    )
    if ($SigningConfig.DlibPath) {
        $signArgs += @("/dlib", $SigningConfig.DlibPath, "/dmdf", $SigningConfig.MetadataPath)
    } else {
        $signArgs += @("/f", $SigningConfig.PfxPath, "/p", $SigningConfig.PfxPassword)
    }

    if (-not [string]::IsNullOrWhiteSpace($SigningConfig.TimestampUrl)) {
        # RFC 3161 timestamp (not legacy Authenticode /t) so the signature
        # stays verifiable after the signing certificate expires.
        $signArgs += @("/tr", $SigningConfig.TimestampUrl, "/td", "SHA256")
    }

    $signArgs += @(
        "/d", $SigningConfig.Description,
        "/du", $SigningConfig.Url,
        $PathToSign
    )

    if (-not $SigningConfig.DlibPath) {
        & $SigningConfig.SignToolPath @signArgs
    } else {
        # A fresh GitHub OIDC token for every call: the dlib exchanges it for
        # an Entra token through the federated credential, and GitHub's tokens
        # expire within minutes while one package step runs for half an hour.
        if (-not $env:ACTIONS_ID_TOKEN_REQUEST_URL -or -not $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
            throw "Azure Artifact Signing signs as the release job's GitHub OIDC identity; run it in a GitHub Actions job with id-token: write."
        }
        $audience = [System.Uri]::EscapeDataString("api://AzureADTokenExchange")
        $oidc = Invoke-RestMethod `
            -Uri "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=$audience" `
            -Headers @{ Authorization = "bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }
        if ([string]::IsNullOrWhiteSpace([string]$oidc.value)) {
            throw "GitHub returned no OIDC token for Azure Artifact Signing."
        }
        $environmentNames = @("AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_FEDERATED_TOKEN_FILE")
        try {
            [System.IO.File]::WriteAllText($SigningConfig.FederatedTokenPath, [string]$oidc.value)
            $env:AZURE_TENANT_ID = $SigningConfig.TenantId
            $env:AZURE_CLIENT_ID = $SigningConfig.ClientId
            $env:AZURE_FEDERATED_TOKEN_FILE = $SigningConfig.FederatedTokenPath
            & $SigningConfig.SignToolPath @signArgs
        }
        finally {
            foreach ($name in $environmentNames) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $SigningConfig.FederatedTokenPath -Force -ErrorAction SilentlyContinue
        }
    }

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

        if (-not (Test-SelfSignedTrustStatus -Signature $signature -Path $PathToCheck)) {
            throw "Expected a self-signed Authenticode signature on $PathToCheck, but got $($signature.Status): $($signature.StatusMessage)"
        }

        return
    }

    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Expected a valid Authenticode signature on $PathToCheck, but got $($signature.Status): $($signature.StatusMessage)"
    }
    if ($SigningConfig -and $SigningConfig.DlibPath -and $null -eq $signature.TimeStamperCertificate) {
        throw "Expected an RFC 3161 timestamp on $PathToCheck; an Artifact Signing certificate expires three days after it is issued."
    }
}

function Write-PortablePayloadManifest {
    param(
        [string]$PayloadRoot,
        [string]$OutputPath
    )

    $managedRootFiles = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in @(
        "koreterm.com",
        "koreterm.exe",
        "ghostty-vt.dll",
        "koreterm-terminal-handoff-proxy.dll",
        "conpty.dll",
        "OpenConsole.exe",
        "LICENSE",
        "LICENSE-conpty.txt",
        "config-template.ghostty",
        "README.md",
        "koreterm.ico",
        "share"
    )) {
        [void]$managedRootFiles.Add($name)
    }

    # Windows PowerShell 5.1 lacks System.IO.Path.GetRelativePath.
    $payloadRootFull = [System.IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar
    $relativePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File -Force)) {
        $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
        if (-not $fullPath.StartsWith($payloadRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Portable payload file resolved outside the payload root: $fullPath"
        }
        $relativePath = $fullPath.Substring($payloadRootFull.Length).Replace("\", "/")
        if (-not $managedRootFiles.Contains($relativePath) -and
            -not $relativePath.StartsWith("share/", [System.StringComparison]::Ordinal)) {
            throw "Portable payload contains an unmanaged file: $relativePath"
        }
        $relativePaths.Add($relativePath)
    }
    $relativePaths.Sort([System.StringComparer]::Ordinal)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# koreterm portable payload manifest")
    foreach ($relativePath in $relativePaths) {
        $payloadPath = Join-Path $PayloadRoot $relativePath.Replace("/", "\")
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $payloadPath).Hash.ToLowerInvariant()
        $lines.Add("$hash *$relativePath")
    }

    $content = [string]::Join("`r`n", $lines) + "`r`n"
    [System.IO.File]::WriteAllText(
        $OutputPath,
        $content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

$signingConfig = $null
$temporarySigningPfxPath = $null
$temporarySigningRoot = $null

try {
    Write-Host "Signing config: loading"
    $signingConfig = Get-SigningConfig
    Write-Host "Signing config: loaded"
    if ($signingConfig) {
        $temporarySigningPfxPath = $signingConfig.TemporaryPfxPath
        $temporarySigningRoot = $signingConfig.TemporaryRoot
        Write-Host "Code signing : enabled$(if ($signingConfig.Label) { " via $($signingConfig.Label)" })"
        if ($signingConfig.TrustSelfSigned) {
            Write-Host "Signing trust: validating self-signed signatures by expected signer thumbprint"
            Write-Host "Timestamping : disabled for self-signed signing (ADR-0005: pin-based verification ignores expiry; public TSA stalled packaging on 2026-04-30)"
        } else {
            Write-Host "Timestamping : RFC 3161 via $($signingConfig.TimestampUrl) (/tr, /td SHA256)"
        }
    } else {
        Write-Host "Code signing : disabled"
    }

    if (-not $SkipBuild) {
        Push-Location $repoRoot
        try {
            Remove-Item -LiteralPath $buildCapabilitiesPath -Force -ErrorAction SilentlyContinue
            # -Dstrip=false keeps the debug info the symbols zip is made from.
            & zig build -Demit-exe=true -Doptimize=ReleaseFast -Dstrip=false "-Dtarget=$zigTarget" -Dcpu=baseline -Dcustom-shaders=true "-Dversion-string=$Version"
            if ($LASTEXITCODE -ne 0) {
                throw "Zig build failed with exit code $LASTEXITCODE."
            }
            Write-WindowsBuildCapabilitiesManifest `
                -Path $buildCapabilitiesPath `
                -BinPath $zigOutBin `
                -Version $Version `
                -Architecture $Architecture `
                -RuntimeFiles $runtimeFiles
        }
        finally {
            Pop-Location
        }
    }

    Assert-WindowsBuildCapabilitiesManifest `
        -Path $buildCapabilitiesPath `
        -BinPath $zigOutBin `
        -Version $Version `
        -Architecture $Architecture `
        -RuntimeFiles $runtimeFiles

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
        if ($Architecture -eq "x64") {
            & (Join-Path $repoRoot "scripts/check-windows-x64-baseline.ps1") -Path $runtimePath
        }
    }

    Write-Host "Packaging phase: stage portable tree"
    Remove-TreeIfPresent -PathToRemove $stageBase
    New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null

    foreach ($runtimeFile in $runtimeFiles) {
        $runtimePath = Join-Path $zigOutBin $runtimeFile
        if (-not (Test-Path -LiteralPath $runtimePath)) {
            throw "Expected runtime artifact was not found: $runtimePath"
        }

        $destinationPath = Join-Path $portableRoot (Split-Path -Leaf $runtimeFile)
        Copy-Item -LiteralPath $runtimePath -Destination $destinationPath -Force

        if ($signingConfig -and @(".com", ".exe", ".dll") -contains [System.IO.Path]::GetExtension($destinationPath)) {
            Invoke-SignFile -SigningConfig $signingConfig -PathToSign $destinationPath
            Assert-ValidSignature -PathToCheck $destinationPath -SigningConfig $signingConfig
        }
    }

    # The portable root's ghostty-vt.dll is the placeholder, never the
    # library: a stub's size, no export or import table, its FileDescription.
    Assert-GhosttyVtStub -Path (Join-Path $portableRoot "ghostty-vt.dll")

    # Portable staging's downgrade guard reads koreterm.exe's fixed PE version.
    # Check both the display string and numeric fields, including the zero
    # fourth component, before producing any release artifacts.
    $stagedVersion = (Get-Item -LiteralPath (Join-Path $portableRoot "koreterm.exe")).VersionInfo
    $numericVersion = "$($stagedVersion.FileMajorPart).$($stagedVersion.FileMinorPart).$($stagedVersion.FileBuildPart)"
    if ($stagedVersion.FileVersion -cne $Version -or $numericVersion -cne $Version -or $stagedVersion.FilePrivatePart -ne 0) {
        throw "Staged koreterm.exe version mismatch: expected '$Version' ($Version.0), got '$($stagedVersion.FileVersion)' ($numericVersion.$($stagedVersion.FilePrivatePart))."
    }

    $conptyStaged = Install-ConPtyRedist `
        -PinPath $conptyPinPath `
        -Architecture $Architecture `
        -Destination $portableRoot `
        -CacheRoot $conptyCacheRoot `
        -RequireConPty:$RequireConPty
    if ($conptyStaged) {
        Write-Host "Staged bundled ConPTY for $Architecture."
        Copy-Item -LiteralPath $conptyLicensePath -Destination (Join-Path $portableRoot "LICENSE-conpty.txt") -Force
    }

    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $portableRoot "LICENSE") -Force
    Copy-Item -LiteralPath $configTemplatePath -Destination (Join-Path $portableRoot "config-template.ghostty") -Force
    Copy-Item -LiteralPath $readmePath -Destination (Join-Path $portableRoot "README.md") -Force
    Copy-Item -LiteralPath $iconPath -Destination (Join-Path $portableRoot "koreterm.ico") -Force
    Copy-Item -LiteralPath $releaseIconSourcePath -Destination $releaseIconPath -Force

    if (Test-Path -LiteralPath $zigOutShare) {
        Copy-Tree -Source $zigOutShare -Destination $portableRoot
    }
    # A -Demit-lib-vt=true build installs libghostty-vt's pkg-config file
    # into zig-out\share, and packaging copies the tree as it finds it, so a
    # warm tree can still hold one. koreterm ships no library for it to
    # describe, and the updater swaps share\ as one directory, so no older
    # updater needs it.
    $libVtPkgConfigDir = Join-Path $portableRoot "share\pkgconfig"
    $libVtPkgConfig = Join-Path $libVtPkgConfigDir "libghostty-vt.pc"
    if (Test-Path -LiteralPath $libVtPkgConfig) {
        Remove-Item -LiteralPath $libVtPkgConfig -Force
    }
    if (Test-Path -LiteralPath $libVtPkgConfig) {
        throw "Staged payload still contains $libVtPkgConfig after its removal."
    }
    if ((Test-Path -LiteralPath $libVtPkgConfigDir) -and -not (Get-ChildItem -LiteralPath $libVtPkgConfigDir -Force)) {
        Remove-Item -LiteralPath $libVtPkgConfigDir -Force
    }

    # The compiled entries for TERM=xterm-ghostty that the build writes on
    # Windows. They mark the resources directory (src/os/resourcesdir.zig)
    # and can be copied or pointed at by hand; koreterm installs the same entry
    # into the user's own terminfo directory at startup.
    foreach ($terminfoEntry in @("share\terminfo\78\xterm-ghostty", "share\terminfo\67\ghostty")) {
        $terminfoPath = Join-Path $portableRoot $terminfoEntry
        if (-not (Test-Path -LiteralPath $terminfoPath -PathType Leaf)) {
            throw "Expected compiled terminfo entry was not staged: $terminfoPath"
        }
    }

    $hostArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($hostArchitecture -eq $Architecture) {
        Write-Host "Packaging phase: verify custom shader capability"
        $portableCommand = Join-Path $portableRoot "koreterm.com"
        $versionText = & $portableCommand +version | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "Packaged koreterm.com +version failed with exit code $LASTEXITCODE."
        }
        if ($versionText -notmatch "custom shaders: enabled") {
            throw "Packaged koreterm.com does not report custom shader support."
        }
    }
    else {
        Write-Host "Packaging phase: custom shader capability verified by hash-bound $Architecture build manifest"
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

    Write-Host "Packaging phase: create portable payload manifest"
    Write-PortablePayloadManifest -PayloadRoot $portableRoot -OutputPath $manifestPath
    if ($signingConfig -and $signingConfig.DlibPath) {
        # No local private key exists for Set-AuthenticodeSignature here;
        # signtool signs the .ps1 through Windows' PowerShell SIP instead.
        Invoke-SignFile -SigningConfig $signingConfig -PathToSign $manifestPath
        Assert-ValidSignature -PathToCheck $manifestPath -SigningConfig $signingConfig
    } elseif ($signingConfig) {
        $manifestSigningParameters = @{
            LiteralPath = $manifestPath
            Certificate = $signingConfig.Certificate
            HashAlgorithm = "SHA256"
            IncludeChain = "NotRoot"
        }
        if (-not [string]::IsNullOrWhiteSpace($signingConfig.TimestampUrl)) {
            $manifestSigningParameters.TimestampServer = $signingConfig.TimestampUrl
        }
        Set-AuthenticodeSignature @manifestSigningParameters | Out-Null
        Assert-ValidSignature -PathToCheck $manifestPath -SigningConfig $signingConfig
    }

    # The PDBs come from the same zig build as the staged binaries and stay
    # out of the portable tree and the installer: they live in a stage
    # directory of their own and ship as one zip.
    Write-Host "Packaging phase: create symbols zip"
    $symbolsProduced = $false
    if ($null -eq (Get-PeCodeViewIdentity -Path (Join-Path $portableRoot "koreterm.exe"))) {
        $symbolsSkipReason = "koreterm.exe has no CodeView record, so this is a stripped build; build with -Dstrip=false."
        if ($RequireSymbols) {
            throw "Symbols are required, but $symbolsSkipReason"
        }
        Write-Warning "Skipping the symbols zip: $symbolsSkipReason"
    }
    else {
        New-Item -ItemType Directory -Path $symbolsRoot -Force | Out-Null
        foreach ($binaryName in (Get-WindowsSymbolBinaryNames)) {
            $identity = Get-PeCodeViewIdentity -Path (Join-Path $portableRoot $binaryName)
            if ($null -eq $identity) { continue }
            # A PDB sits beside the build output its binary was staged from,
            # so the placeholder's ghostty-vt.pdb comes from ghostty-vt-stub\
            # and never from a library build's zig-out\bin\ghostty-vt.pdb.
            $runtimeSource = @($runtimeFiles | Where-Object { (Split-Path -Leaf $_) -ceq $binaryName })
            if ($runtimeSource.Count -ne 1) {
                throw "Expected one runtime file staged as $binaryName, found $($runtimeSource.Count)."
            }
            $pdbSource = Join-Path (Split-Path -Parent (Join-Path $zigOutBin $runtimeSource[0])) $identity.PdbName
            if (-not (Test-Path -LiteralPath $pdbSource -PathType Leaf)) {
                throw "Expected build output was not found: $pdbSource (named by $binaryName)."
            }
            Copy-Item -LiteralPath $pdbSource -Destination (Join-Path $symbolsRoot $identity.PdbName) -Force
        }
        $symbolEvidence = Assert-SymbolsMatchBinaries `
            -SymbolsRoot $symbolsRoot `
            -PayloadRoot $portableRoot `
            -Label "Symbols $Architecture"
        foreach ($item in $symbolEvidence) {
            Write-Host ("Symbols match: {0} <- {1} (GUID {2}, age {3})" -f $item.Binary, $item.Pdb, $item.Guid, $item.Age)
        }
        if (Test-Path -LiteralPath $symbolsPath) {
            Remove-Item -LiteralPath $symbolsPath -Force
        }
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $symbolsRoot,
            $symbolsPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $true
        )
        Remove-TreeIfPresent -PathToRemove $symbolsRoot
        $symbolsProduced = $true
    }

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

    if ($symbolsProduced) {
        $hashTargets += @{
            Name = [System.IO.Path]::GetFileName($symbolsPath)
            Path = $symbolsPath
        }
    }

    $hashLines = foreach ($target in $hashTargets) {
        $hash = Get-FileSha256Lower -Path $target.Path
        "$hash *$($target.Name)"
    }

    Set-Content -LiteralPath $checksumsPath -Value $hashLines

    Write-Host "Portable ZIP: $zipPath"
    Write-Host "Manifest    : $manifestPath"
    if (Test-Path -LiteralPath $installerPath) {
        Write-Host "Installer    : $installerPath"
    }
    if ($symbolsProduced) {
        Write-Host "Symbols      : $symbolsPath"
    }
    Write-Host "Checksums    : $checksumsPath"
}
finally {
    if ($temporarySigningPfxPath -and (Test-Path -LiteralPath $temporarySigningPfxPath)) {
        Remove-Item -LiteralPath $temporarySigningPfxPath -Force
    }
    if ($temporarySigningRoot) {
        Remove-ArtifactSigningTemporaryRoot -Path $temporarySigningRoot
    }
}
