param(
    [Parameter(Mandatory = $true)]
    [string] $Path
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path)) {
    throw "File not found: $Path"
}

$fullPath = (Resolve-Path -LiteralPath $Path).Path
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

        $machine = $reader.ReadUInt16()
        if ($machine -ne 0x8664) {
            Write-Host "CPU baseline check: skipped non-x64 PE $fullPath"
            return
        }
    }
    finally {
        $reader.Dispose()
    }
}
finally {
    $stream.Dispose()
}

$objdumpCommand = Get-Command llvm-objdump -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$objdumpPath = if ($null -ne $objdumpCommand) { $objdumpCommand.Source } else { $null }
if (-not $objdumpPath) {
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles "LLVM\bin\llvm-objdump.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "LLVM\bin\llvm-objdump.exe")
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $objdumpPath = $candidate
            break
        }
    }
}
if (-not $objdumpPath) {
    throw "Windows x64 baseline check requires llvm-objdump on PATH or in the standard LLVM install directory."
}

$objdumpOutput = Join-Path ([System.IO.Path]::GetTempPath()) "winghostty-objdump-$([Guid]::NewGuid().ToString('N')).txt"
try {
    # Native redirection avoids PowerShell object creation for every decoded
    # instruction while keeping the full disassembly out of process memory.
    & $objdumpPath --disassemble --no-show-raw-insn $fullPath > $objdumpOutput 2>&1
    $objdumpExitCode = $LASTEXITCODE
    if ($objdumpExitCode -ne 0) {
        $details = @(Get-Content -LiteralPath $objdumpOutput -Tail 20) -join [Environment]::NewLine
        throw "llvm-objdump failed with exit code $objdumpExitCode while checking $fullPath`:$([Environment]::NewLine)$details"
    }

    $decodedMatches = @(Select-String `
        -LiteralPath $objdumpOutput `
        -Pattern '^\s*[0-9A-Fa-f]+:\s+(extrq|insertq|movntsd|movntss)\b')
    if ($decodedMatches.Count -gt 0) {
        $details = @($decodedMatches | ForEach-Object { $_.Line.Trim() }) -join [Environment]::NewLine
        throw "Windows x64 baseline check failed: found AMD-only SSE4a instructions:$([Environment]::NewLine)$details"
    }
}
finally {
    Remove-Item -LiteralPath $objdumpOutput -Force -ErrorAction SilentlyContinue
}

Write-Host "CPU baseline check: passed for $fullPath"
