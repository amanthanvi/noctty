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
        $sectionCount = $reader.ReadUInt16()
        $stream.Position = $peOffset + 20
        $optionalHeaderSize = $reader.ReadUInt16()
        $sectionTable = $peOffset + 24 + $optionalHeaderSize

        if ($machine -ne 0x8664) {
            Write-Host "CPU baseline check: skipped non-x64 PE $fullPath"
            return
        }

        $textSection = $null
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $stream.Position = $sectionTable + ($i * 40)
            $nameBytes = $reader.ReadBytes(8)
            $name = [System.Text.Encoding]::ASCII.GetString($nameBytes).TrimEnd([char]0)
            $virtualSize = $reader.ReadUInt32()
            $virtualAddress = $reader.ReadUInt32()
            $rawSize = $reader.ReadUInt32()
            $rawPointer = $reader.ReadUInt32()
            if ($name -eq ".text") {
                $textSection = [pscustomobject]@{
                    VirtualSize = $virtualSize
                    VirtualAddress = $virtualAddress
                    RawSize = $rawSize
                    RawPointer = $rawPointer
                }
                break
            }
        }

        if ($null -eq $textSection) {
            throw "Missing .text section: $fullPath"
        }

        $stream.Position = $textSection.RawPointer
        $text = $reader.ReadBytes($textSection.RawSize)
        $matches = [System.Collections.Generic.List[string]]::new()

        for ($i = 0; $i -le $text.Length - 3; $i++) {
            $prefix = $text[$i]
            if (($prefix -ne 0x66) -and ($prefix -ne 0xF2)) {
                continue
            }

            if (($text[$i + 1] -eq 0x0F) -and
                (($text[$i + 2] -eq 0x78) -or ($text[$i + 2] -eq 0x79))) {
                $rva = $textSection.VirtualAddress + $i
                $fileOffset = $textSection.RawPointer + $i
                $opcode = "{0:X2} {1:X2} {2:X2}" -f $text[$i], $text[$i + 1], $text[$i + 2]
                $matches.Add(("RVA 0x{0:X8}, file offset 0x{1:X8}, opcode {2}" -f $rva, $fileOffset, $opcode))
            }
        }

        if ($matches.Count -gt 0) {
            $details = $matches -join [Environment]::NewLine
            throw "Windows x64 baseline check failed: found AMD-only SSE4a EXTRQ/INSERTQ opcodes in .text:$([Environment]::NewLine)$details"
        }

        Write-Host "CPU baseline check: passed for $fullPath"
    }
    finally {
        $reader.Dispose()
    }
}
finally {
    $stream.Dispose()
}
