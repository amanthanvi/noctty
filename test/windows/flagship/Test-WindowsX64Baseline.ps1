#requires -Version 7.3

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$checker = Join-Path $repoRoot 'scripts/check-windows-x64-baseline.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "winghostty-x64-baseline-$([Guid]::NewGuid().ToString('N'))"

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
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [byte[]] $Text
    )

    $path = Join-Path $tempRoot "$Name.exe"
    New-ProbePe -Path $path -Text $Text
    & $checker -Path $path
}

function Assert-BaselineReject {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [byte[]] $Text
    )

    $path = Join-Path $tempRoot "$Name.exe"
    New-ProbePe -Path $path -Text $Text
    try {
        & $checker -Path $path
    }
    catch {
        if ($_.Exception.Message -notmatch 'AMD-only SSE4a EXTRQ/INSERTQ') {
            throw
        }
        return
    }
    throw "CPU baseline checker accepted SSE4a probe '$Name'."
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    # Prefix bytes embedded in another instruction are not SSE4a opcodes.
    Assert-BaselinePass -Name 'insertq-memory-form' -Text ([byte[]](0x90, 0xF2, 0x0F, 0x78, 0x00, 0x90, 0x90))
    Assert-BaselinePass -Name 'extrq-wrong-extension' -Text ([byte[]](0x90, 0x66, 0x0F, 0x78, 0xC8, 0x01, 0x02))
    Assert-BaselinePass -Name 'truncated-immediate' -Text ([byte[]](0x90, 0xF2, 0x0F, 0x78, 0xC1, 0x01))

    Assert-BaselineReject -Name 'extrq-immediate' -Text ([byte[]](0x66, 0x0F, 0x78, 0xC0, 0x01, 0x02))
    Assert-BaselineReject -Name 'extrq-register' -Text ([byte[]](0x66, 0x0F, 0x79, 0xC1))
    Assert-BaselineReject -Name 'insertq-immediate-rex' -Text ([byte[]](0xF2, 0x41, 0x0F, 0x78, 0xC1, 0x01, 0x02))
    Assert-BaselineReject -Name 'insertq-register' -Text ([byte[]](0xF2, 0x0F, 0x79, 0xC1))

    Write-Host 'Windows x64 baseline checker probes: PASS'
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
