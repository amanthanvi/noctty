#Requires -Version 7.0
<#
.SYNOPSIS
Packs the portable build in dist\artifacts as update.zip, which a running
noctty finds beside its executable and offers to install
(src/apprt/win32/local_update.zig).

.DESCRIPTION
Run after scripts\package-windows.ps1 -Version <Version>. The ZIP holds the
portable program files (no noctty.portable: the folder being updated has its
own), version.txt and whats-new.txt; the two text files are stored
uncompressed, because noctty reads them without inflating.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    # What the update dialog shows: the text, or a file holding it.
    [string]$Notes = "",
    [string]$NotesFile = "",

    [string]$OutputRoot = "dist/artifacts"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $repoRoot (Join-Path $OutputRoot "noctty-$Version-windows-x64")
$source = Join-Path $stage "noctty"
if (-not (Test-Path -LiteralPath (Join-Path $source "noctty.exe"))) {
    throw "No portable build at $source; run scripts\package-windows.ps1 -Version $Version first."
}
if ($NotesFile) { $Notes = Get-Content -LiteralPath $NotesFile -Raw }
if (-not $Notes) { $Notes = "noctty $Version" }

$zipPath = Join-Path $stage "update.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$utf8 = [System.Text.UTF8Encoding]::new($false)
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($text in @(@{ Name = "version.txt"; Body = $Version }, @{ Name = "whats-new.txt"; Body = $Notes })) {
        $entry = $zip.CreateEntry($text.Name, [System.IO.Compression.CompressionLevel]::NoCompression)
        $stream = $entry.Open()
        try {
            $bytes = $utf8.GetBytes($text.Body)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    }
    $root = (Resolve-Path -LiteralPath $source).Path.TrimEnd('\') + '\'
    Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object { $_.Name -ne "noctty.portable" } | ForEach-Object {
        $relative = $_.FullName.Substring($root.Length).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $relative, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $zip.Dispose()
}

Write-Host "Update ZIP: $zipPath"
