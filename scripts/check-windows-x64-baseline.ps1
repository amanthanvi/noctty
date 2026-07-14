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
$objdumpError = Join-Path ([System.IO.Path]::GetTempPath()) "winghostty-objdump-$([Guid]::NewGuid().ToString('N')).err"
$objdumpTimeoutMs = 120000
try {
    # Copy native streams directly to disk. PowerShell 5.1 otherwise creates
    # one object per decoded line and wraps native stderr in ErrorRecords.
    $processStart = [System.Diagnostics.ProcessStartInfo]::new()
    $processStart.UseShellExecute = $false
    $processStart.CreateNoWindow = $true
    $processStart.RedirectStandardOutput = $true
    $processStart.RedirectStandardError = $true
    if ([System.IO.Path]::GetExtension($objdumpPath) -in @('.cmd', '.bat')) {
        # The regression fixture supplies a command shim; production resolves
        # the real llvm-objdump executable.
        $processStart.FileName = $env:ComSpec
        $processStart.Arguments = "/d /s /c `"`"$objdumpPath`" --disassemble --no-show-raw-insn `"$fullPath`"`""
    }
    else {
        $processStart.FileName = $objdumpPath
        $processStart.Arguments = "--disassemble --no-show-raw-insn `"$fullPath`""
    }

    $objdumpProcess = [System.Diagnostics.Process]::new()
    $objdumpProcess.StartInfo = $processStart
    $stdoutStream = [System.IO.File]::Open($objdumpOutput, 'Create', 'Write', 'None')
    $stderrStream = [System.IO.File]::Open($objdumpError, 'Create', 'Write', 'None')
    try {
        if (-not $objdumpProcess.Start()) {
            throw "Failed to start llvm-objdump while checking $fullPath."
        }
        $stdoutCopy = $objdumpProcess.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrCopy = $objdumpProcess.StandardError.BaseStream.CopyToAsync($stderrStream)
        $objdumpCompleted = $objdumpProcess.WaitForExit($objdumpTimeoutMs)
        if (-not $objdumpCompleted) {
            $objdumpProcess.Kill()
            $objdumpProcess.WaitForExit()
        }
        [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdoutCopy, $stderrCopy))
        if (-not $objdumpCompleted) {
            throw "llvm-objdump timed out after $objdumpTimeoutMs ms while checking $fullPath."
        }
        $objdumpExitCode = $objdumpProcess.ExitCode
    }
    finally {
        $stdoutStream.Dispose()
        $stderrStream.Dispose()
        $objdumpProcess.Dispose()
    }
    if ($objdumpExitCode -ne 0) {
        $details = @(
            Get-Content -LiteralPath $objdumpError -Tail 20
            Get-Content -LiteralPath $objdumpOutput -Tail 20
        ) -join [Environment]::NewLine
        throw "llvm-objdump failed with exit code $objdumpExitCode while checking $fullPath`:$([Environment]::NewLine)$details"
    }

    # The PE contract marks executable sections as code. Treat any decoded
    # SSE4a there as a build failure; embedded constants belong in a
    # non-executable section and must not be hidden behind a byte allowlist.
    $decodedMatches = @(Select-String `
        -LiteralPath $objdumpOutput `
        -Pattern '^\s*[0-9A-Fa-f]+:\s+(extrq|insertq|movntsd|movntss)\b')
    if ($decodedMatches.Count -gt 0) {
        $details = @($decodedMatches | ForEach-Object { $_.Line.Trim() }) -join [Environment]::NewLine
        throw "Windows x64 baseline check failed: found decoded AMD-only SSE4a instructions in executable sections. Move intentional data to a non-executable section; do not allowlist instruction bytes.$([Environment]::NewLine)$details"
    }
}
finally {
    Remove-Item -LiteralPath $objdumpOutput -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $objdumpError -Force -ErrorAction SilentlyContinue
}

Write-Host "CPU baseline check: passed for $fullPath"
