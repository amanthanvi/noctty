#requires -Version 7.3

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$checker = Join-Path $repoRoot 'scripts/check-windows-x64-baseline.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "winghostty-x64-baseline-$([Guid]::NewGuid().ToString('N'))"
$originalPath = $env:PATH

function New-ProbePe {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [byte[]] $Text
    )

    $peOffset = 0x80
    $sectionTable = $peOffset + 24
    $rawPointer = 0x200
    $rawSize = [Math]::Max(0x20, $Text.Length)
    $bytes = [byte[]]::new($rawPointer + $rawSize)
    $writer = [IO.BinaryWriter]::new([IO.MemoryStream]::new($bytes))
    try {
        $writer.Write([uint16]0x5A4D)
        $writer.BaseStream.Position = 0x3C
        $writer.Write([uint32]$peOffset)
        $writer.BaseStream.Position = $peOffset
        $writer.Write([uint32]0x00004550)
        $writer.Write([uint16]0x8664)
        $writer.Write([uint16]1)
        $writer.BaseStream.Position = $peOffset + 20
        $writer.Write([uint16]0)
        $writer.BaseStream.Position = $sectionTable
        $writer.Write([Text.Encoding]::ASCII.GetBytes(".text`0`0`0"))
        $writer.Write([uint32]$Text.Length)
        $writer.Write([uint32]0x1000)
        $writer.Write([uint32]$rawSize)
        $writer.Write([uint32]$rawPointer)
        $writer.BaseStream.Position = $rawPointer
        $writer.Write($Text)
    }
    finally {
        $writer.Dispose()
    }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Assert-BaselinePass {
    param([Parameter(Mandatory)] [string] $Name)

    $path = Join-Path $tempRoot "$Name.exe"
    # These bytes resemble EXTRQ inside .text. The fake disassembler reports
    # only a decoded NOP, proving raw data is not treated as an instruction.
    New-ProbePe -Path $path -Text ([byte[]](0x66, 0x0F, 0x78, 0xC0, 0x01, 0x02))
    $output = @(& $checker -Path $path 6>&1)
    if (($output -join "`n") -notmatch 'CPU baseline check: passed') {
        throw "CPU baseline checker did not report its PASS sentinel for '$Name'."
    }
}

function Assert-BaselineReject {
    param([Parameter(Mandatory)] [string] $Name)

    $path = Join-Path $tempRoot "$Name.exe"
    New-ProbePe -Path $path -Text ([byte[]](0x90))
    try {
        & $checker -Path $path
    }
    catch {
        if ($_.Exception.Message -notmatch 'AMD-only SSE4a instructions') {
            throw
        }
        return
    }
    throw "CPU baseline checker accepted decoded SSE4a probe '$Name'."
}

function Assert-ObjdumpFailure {
    $path = Join-Path $tempRoot 'tool-failure.exe'
    New-ProbePe -Path $path -Text ([byte[]](0x90))
    try {
        & $checker -Path $path
    }
    catch {
        if ($_.Exception.Message -notmatch 'llvm-objdump failed with exit code 7') {
            throw
        }
        return
    }
    throw 'CPU baseline checker ignored an llvm-objdump failure.'
}

function Assert-WindowsPowerShellObjdumpFailure {
    $windowsPowerShell = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if (-not $windowsPowerShell) { return }

    $path = Join-Path $tempRoot 'tool-failure.exe'
    $outputPath = Join-Path $tempRoot 'windows-powershell-failure.log'
    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checker -Path $path *> $outputPath
    $exitCode = $LASTEXITCODE
    $output = Get-Content -LiteralPath $outputPath -Raw
    if ($exitCode -eq 0 -or $output -notmatch 'llvm-objdump failed with exit code 7') {
        throw "Windows PowerShell did not preserve the llvm-objdump failure (exit=$exitCode):$([Environment]::NewLine)$output"
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $windowsPowerShell = Get-Command powershell.exe -CommandType Application -ErrorAction Stop |
        Select-Object -First 1 -ExpandProperty Source
    $fakeSource = Join-Path $tempRoot 'llvm-objdump.cs'
    $fakeObjdump = Join-Path $tempRoot 'llvm-objdump.exe'
    [IO.File]::WriteAllText($fakeSource, @'
using System;
using System.IO;

public static class Program {
    public static int Main(string[] args) {
        string target = Path.GetFileName(args[args.Length - 1]);
        if (target.Equals("tool-failure.exe", StringComparison.OrdinalIgnoreCase)) {
            Console.Error.WriteLine("synthetic llvm-objdump failure");
            return 7;
        }
        foreach (string mnemonic in new[] { "extrq", "insertq", "movntsd", "movntss" }) {
            if (target.Equals(mnemonic + ".exe", StringComparison.OrdinalIgnoreCase)) {
                Console.WriteLine("140001000:        " + mnemonic);
                return 0;
            }
        }
        Console.WriteLine("140001000:        nop");
        return 0;
    }
}
'@)
    $compileCommand = "Add-Type -LiteralPath '$($fakeSource.Replace("'", "''"))' -OutputAssembly '$($fakeObjdump.Replace("'", "''"))' -OutputType ConsoleApplication"
    & $windowsPowerShell -NoLogo -NoProfile -Command $compileCommand
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeObjdump -PathType Leaf)) {
        throw "Failed to compile the llvm-objdump fixture (exit=$LASTEXITCODE)."
    }
    $env:PATH = "$tempRoot;$originalPath"

    Assert-BaselinePass -Name 'raw-sse4a-looking-data'
    foreach ($mnemonic in @('extrq', 'insertq', 'movntsd', 'movntss')) {
        Assert-BaselineReject -Name $mnemonic
    }
    Assert-ObjdumpFailure
    Assert-WindowsPowerShellObjdumpFailure

    Write-Host 'Windows x64 baseline checker probes: PASS'
}
finally {
    $env:PATH = $originalPath
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
