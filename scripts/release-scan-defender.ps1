[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $ArtifactRoot,

    [string] $ExtractionRoot = $env:RUNNER_TEMP,

    [switch] $ValidateParameters
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repoRoot 'dist/artifacts'
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
if ([string]::IsNullOrWhiteSpace($ExtractionRoot)) {
    $ExtractionRoot = [System.IO.Path]::GetTempPath()
}
$ExtractionRoot = [System.IO.Path]::GetFullPath($ExtractionRoot)

if ($ValidateParameters) {
    Write-Host "Microsoft Defender scan parameters: PASS ($Version)" -ForegroundColor Green
    return
}

$status = Get-MpComputerStatus -ErrorAction Stop
if (-not $status.AMServiceEnabled -or
    -not $status.AntivirusEnabled -or
    $status.AMRunningMode -ne 'Normal') {
    throw 'Microsoft Defender Antivirus must be active in Normal mode before release publication.'
}

$scannerCandidates = @(
    (Join-Path $env:ProgramFiles 'Windows Defender/MpCmdRun.exe')
)
$platformRoot = Join-Path $env:ProgramData 'Microsoft/Windows Defender/Platform'
if (Test-Path -LiteralPath $platformRoot) {
    $scannerCandidates = @(
        Get-ChildItem -LiteralPath $platformRoot -Directory |
            ForEach-Object {
                $platformVersion = ($_.Name -replace '-\d+$', '') -as [version]
                if ($null -ne $platformVersion) {
                    [pscustomobject]@{
                        Version = $platformVersion
                        Path = Join-Path $_.FullName 'MpCmdRun.exe'
                    }
                }
            } |
            Sort-Object Version -Descending |
            ForEach-Object { $_.Path }
    ) + $scannerCandidates
}
$scanner = $scannerCandidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if (-not $scanner) {
    throw 'MpCmdRun.exe was not found.'
}

& $scanner -SignatureUpdate
if ($LASTEXITCODE -ne 0) {
    throw "Microsoft Defender signature update failed with exit code $LASTEXITCODE."
}

$portablePayloads = @(
    'noctty/noctty.com',
    'noctty/noctty.exe',
    'noctty/ghostty-vt.dll'
)
$scanPaths = @(
    foreach ($architecture in (Get-WindowsPackageArchitectures)) {
        $artifactDirectory = Join-Path $ArtifactRoot "noctty-$Version-windows-$architecture"
        $setupName = New-WindowsPackageArtifactName `
            -Version $Version `
            -Architecture $architecture `
            -Kind setup
        $setupPath = Join-Path $artifactDirectory $setupName
        if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
            throw "Missing Defender scan input: $setupPath"
        }
        $setupPath

        $extractDirectory = Join-Path $ExtractionRoot "noctty-release-verify-$architecture"
        foreach ($relativePath in $portablePayloads) {
            $payloadPath = Join-Path $extractDirectory $relativePath
            if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
                throw "Missing Defender scan input: $payloadPath"
            }
            $payloadPath
        }
    }
)
if ($scanPaths.Count -ne 8) {
    throw "Expected exactly eight release artifacts for Defender scanning; found $($scanPaths.Count)."
}

foreach ($scanPath in $scanPaths) {
    & $scanner -Scan -ScanType 3 -File $scanPath -DisableRemediation -ReturnHR
    if ($LASTEXITCODE -ne 0) {
        throw "Microsoft Defender rejected $scanPath with exit code $LASTEXITCODE."
    }
}

Write-Host "Microsoft Defender release scan: PASS ($Version, $($scanPaths.Count) files)" -ForegroundColor Green
