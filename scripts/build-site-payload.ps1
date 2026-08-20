#requires -Version 7.3

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $OutputDirectory,

    [Parameter(Mandatory)]
    [string] $ManifestPath,

    [string] $SourceDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'site')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\', '/')
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
$manifestFullPath = [IO.Path]::GetFullPath($ManifestPath)
$pathComparison = if ($IsWindows) {
    [StringComparison]::OrdinalIgnoreCase
} else {
    [StringComparison]::Ordinal
}
$separator = [IO.Path]::DirectorySeparatorChar
$sourcePrefix = "$sourceRoot$separator"
$outputPrefix = "$outputRoot$separator"

if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Site source directory does not exist: $sourceRoot"
}
[void](& (Join-Path $PSScriptRoot 'get-site-header-contract.ps1') `
    -SiteDirectory $sourceRoot)
if ($outputRoot.Equals($sourceRoot, $pathComparison) -or
    $outputRoot.StartsWith($sourcePrefix, $pathComparison) -or
    $sourceRoot.StartsWith($outputPrefix, $pathComparison)) {
    throw 'Payload output must be outside the site source tree and cannot contain it.'
}
$outputDriveRoot = [IO.Path]::GetPathRoot($outputRoot).TrimEnd('\', '/')
if ($outputRoot.Equals($outputDriveRoot, $pathComparison) -or
    $outputRoot.Length -le ($outputDriveRoot.Length + 8)) {
    throw 'Refusing to clean an unsafe payload output path.'
}
if ($manifestFullPath.StartsWith($outputPrefix, $pathComparison) -or
    $manifestFullPath.Equals($outputRoot, $pathComparison)) {
    throw 'The SHA-256 manifest must be outside the deploy payload.'
}

# Deliberately exact: build notes and local tooling cannot silently become
# production files.
$allowlist = [string[]] @(
    '404.html'
    '_headers'
    'app.js'
    'assets/app-window.webp'
    'assets/favicon.svg'
    'assets/fonts/jetbrains-mono.woff2'
    'assets/fonts/space-grotesk.woff2'
    'assets/hero-sky.webp'
    'assets/noctty-social.jpg'
    'index.html'
    'install.js'
    'styles.css'
    'terminal.js'
    'version.js'
)
[Array]::Sort($allowlist, [StringComparer]::Ordinal)

$sourceFiles = [Collections.Generic.List[object]]::new()
foreach ($relativePath in $allowlist) {
    if ($relativePath.Contains('\')) {
        throw "Payload allowlist paths must use forward slashes: $relativePath"
    }
    $sourcePath = [IO.Path]::GetFullPath(
        (Join-Path $sourceRoot ($relativePath.Replace('/', $separator)))
    )
    if (-not $sourcePath.StartsWith($sourcePrefix, $pathComparison)) {
        throw "Payload allowlist path escapes the source directory: $relativePath"
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required site payload file is missing: $relativePath"
    }
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Site payload cannot contain a reparse point: $relativePath"
    }
    [void]$sourceFiles.Add([pscustomobject]@{
        RelativePath = $relativePath
        SourcePath = $sourcePath
    })
}

if (Test-Path -LiteralPath $outputRoot) {
    $outputItem = Get-Item -LiteralPath $outputRoot -Force
    if (($outputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to clean a payload output directory that is a reparse point.'
    }
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $outputRoot)

$manifestLines = [Collections.Generic.List[string]]::new()
foreach ($sourceFile in $sourceFiles) {
    $destinationPath = Join-Path $outputRoot (
        $sourceFile.RelativePath.Replace('/', $separator)
    )
    $destinationParent = Split-Path -Parent $destinationPath
    [void](New-Item -ItemType Directory -Path $destinationParent -Force)
    [IO.File]::Copy($sourceFile.SourcePath, $destinationPath, $false)
    $hash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).
        Hash.ToLowerInvariant()
    [void]$manifestLines.Add("$hash  $($sourceFile.RelativePath)")
}

$actualRelativePaths = [string[]] @(
    Get-ChildItem -LiteralPath $outputRoot -File -Recurse -Force |
        ForEach-Object {
            $_.FullName.Substring($outputPrefix.Length).Replace('\', '/')
        }
)
[Array]::Sort($actualRelativePaths, [StringComparer]::Ordinal)
if ($actualRelativePaths.Count -ne $allowlist.Count) {
    throw 'Payload output contains an unexpected number of files.'
}
for ($index = 0; $index -lt $allowlist.Count; $index++) {
    if ($actualRelativePaths[$index] -cne $allowlist[$index]) {
        throw "Payload output escaped the allowlist: $($actualRelativePaths[$index])"
    }
}

$manifestParent = Split-Path -Parent $manifestFullPath
if ($manifestParent) {
    [void](New-Item -ItemType Directory -Path $manifestParent -Force)
}
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
    $manifestFullPath,
    (($manifestLines -join "`n") + "`n"),
    $utf8NoBom
)

Write-Host "Built deterministic site payload: $($allowlist.Count) files."
