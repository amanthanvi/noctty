$script:WindowsPackageArchitectures = [ordered]@{
    x64 = [ordered]@{
        Name = "x64"
        ZigTarget = "x86_64-windows-msvc"
        PeMachine = 0x8664
        ScoopArchitecture = "64bit"
    }
    arm64 = [ordered]@{
        Name = "arm64"
        ZigTarget = "aarch64-windows-msvc"
        PeMachine = 0xAA64
        ScoopArchitecture = "arm64"
    }
}

function Get-DefaultWindowsPackageArchitecture {
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        return "arm64"
    }

    return "x64"
}

function Get-WindowsPackageArchitectures {
    return @($script:WindowsPackageArchitectures.Keys)
}

function Get-WindowsPackageArchitecture {
    param([string]$Architecture)

    $normalized = ([string]$Architecture).ToLowerInvariant()
    $info = $script:WindowsPackageArchitectures[$normalized]
    if (-not $info) {
        throw "Unknown architecture '$Architecture'. Supported architectures are: $((Get-WindowsPackageArchitectures) -join ', ')."
    }

    return [pscustomobject]$info
}

function New-WindowsPackageArtifactName {
    param(
        [string]$Version,
        [string]$Architecture,
        [ValidateSet("portable", "manifest", "setup", "checksums", "legacy-checksums")]
        [string]$Kind
    )

    $arch = (Get-WindowsPackageArchitecture -Architecture $Architecture).Name
    switch ($Kind) {
        "portable" { return "noctty-$Version-windows-$arch-portable.zip" }
        "manifest" { return "noctty-$Version-windows-$arch-portable.manifest.ps1" }
        "setup" { return "noctty-$Version-windows-$arch-setup.exe" }
        "checksums" { return "SHA256SUMS-windows-$arch.txt" }
        "legacy-checksums" { return "SHA256SUMS.txt" }
    }
}
