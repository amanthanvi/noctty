$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "windows-build-capabilities.ps1")

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "noctty-build-capabilities-$PID"
$manifestPath = Join-Path $fixtureRoot "noctty-build-capabilities.json"
$runtimeFiles = @(
    "noctty.com",
    "noctty.exe",
    "ghostty-vt.dll"
)

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    foreach ($runtimeFile in $runtimeFiles) {
        Set-Content -LiteralPath (Join-Path $fixtureRoot $runtimeFile) -Value $runtimeFile -Encoding UTF8
    }

    Write-WindowsBuildCapabilitiesManifest `
        -Path $manifestPath `
        -BinPath $fixtureRoot `
        -Version "1.2.3" `
        -Architecture "arm64" `
        -RuntimeFiles $runtimeFiles
    Assert-WindowsBuildCapabilitiesManifest `
        -Path $manifestPath `
        -BinPath $fixtureRoot `
        -Version "1.2.3" `
        -Architecture "arm64" `
        -RuntimeFiles $runtimeFiles

    Add-Content -LiteralPath (Join-Path $fixtureRoot "noctty.exe") -Value "mutated"
    $hashMismatchRejected = $false
    try {
        Assert-WindowsBuildCapabilitiesManifest `
            -Path $manifestPath `
            -BinPath $fixtureRoot `
            -Version "1.2.3" `
            -Architecture "arm64" `
            -RuntimeFiles $runtimeFiles
    }
    catch {
        $hashMismatchRejected = $_.Exception.Message -match "hash mismatch"
    }
    if (-not $hashMismatchRejected) {
        throw "Build capability manifest accepted a mutated runtime artifact."
    }

    $wrongVersionRejected = $false
    try {
        Assert-WindowsBuildCapabilitiesManifest `
            -Path $manifestPath `
            -BinPath $fixtureRoot `
            -Version "1.2.4" `
            -Architecture "arm64" `
            -RuntimeFiles $runtimeFiles
    }
    catch {
        $wrongVersionRejected = $_.Exception.Message -match "does not match"
    }
    if (-not $wrongVersionRejected) {
        throw "Build capability manifest accepted the wrong release version."
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Host "Windows build capability manifest tests passed."
$global:LASTEXITCODE = 0
