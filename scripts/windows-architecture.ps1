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

            if ($stream.Length -lt 0x40) {
                throw "PE file is too small to contain a header offset: $fullPath"
            }
            $stream.Position = 0x3C
            $peOffset = $reader.ReadUInt32()
            if ($peOffset + 6 -gt $stream.Length) {
                throw "PE header offset is outside the file bounds: $fullPath"
            }
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

    $expectedMachine = (Get-WindowsPackageArchitecture -Architecture $ExpectedArchitecture).PeMachine
    $actualMachine = Get-PeMachine -PathToCheck $PathToCheck
    if ($actualMachine -ne $expectedMachine) {
        throw ("Expected {0} to be {1} PE machine 0x{2:X4}, got 0x{3:X4}." -f $PathToCheck, $ExpectedArchitecture, $expectedMachine, $actualMachine)
    }
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
