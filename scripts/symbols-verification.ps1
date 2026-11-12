# Debug-symbol identity checks shared by the packager, the pre-publish
# verifier and the published-release verifier. A debugger accepts a PDB for a
# module only when the PDB's GUID and age equal the ones in the module's
# CodeView record, so that equality is what "these symbols match the shipped
# binary" means. Plain .NET only (no dbghelp, no LLVM), and Windows
# PowerShell 5.1 compatible like package-windows.ps1.

function Get-WindowsSymbolBinaryNames {
    # The koreterm-built PEs that ship in the portable ZIP, by file name.
    return @(
        Get-WindowsSignedRuntimePayloads |
            ForEach-Object { $_.Substring($_.LastIndexOf('/') + 1) }
    )
}

function Read-SymbolsFileBytes {
    param(
        [Parameter(Mandatory)] [System.IO.Stream]$Stream,
        [Parameter(Mandatory)] [long]$Offset,
        [Parameter(Mandatory)] [int]$Count
    )

    if ($Offset -lt 0 -or $Count -lt 0 -or $Offset + $Count -gt $Stream.Length) {
        throw "Read of $Count bytes at offset $Offset is outside the file ($($Stream.Length) bytes)."
    }
    $buffer = New-Object byte[] $Count
    [void]$Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $done = 0
    while ($done -lt $Count) {
        $read = $Stream.Read($buffer, $done, $Count - $done)
        if ($read -le 0) { throw "Unexpected end of file at offset $($Offset + $done)." }
        $done += $read
    }
    return , $buffer
}

function Get-PeCodeViewIdentity {
    # The RSDS record of a PE's debug directory: the GUID and age a debugger
    # looks for, and the PDB file name it asks the symbol path for. Returns
    # $null for a PE with no CodeView record. Authenticode signing appends to
    # the file but leaves the debug directory alone, so a signed PE reads the
    # same as the build output.
    param([Parameter(Mandatory)] [string]$Path)

    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $stream = [System.IO.File]::Open(
        $fullPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $dos = Read-SymbolsFileBytes -Stream $stream -Offset 0 -Count 64
        if ($dos[0] -ne 0x4D -or $dos[1] -ne 0x5A) { throw "Not a PE file: $fullPath" }
        $peOffset = [BitConverter]::ToUInt32($dos, 0x3C)

        $header = Read-SymbolsFileBytes -Stream $stream -Offset $peOffset -Count 24
        if ([BitConverter]::ToUInt32($header, 0) -ne 0x00004550) { throw "Missing PE signature: $fullPath" }
        $sectionCount = [BitConverter]::ToUInt16($header, 6)
        $optionalSize = [BitConverter]::ToUInt16($header, 20)

        $optionalOffset = [long]$peOffset + 24
        $optional = Read-SymbolsFileBytes -Stream $stream -Offset $optionalOffset -Count $optionalSize
        $magic = [BitConverter]::ToUInt16($optional, 0)
        # PE32 has 96 bytes before the data directories, PE32+ has 112.
        $directoriesOffset = if ($magic -eq 0x20B) { 112 } elseif ($magic -eq 0x10B) { 96 } else { throw "Unknown PE optional header magic 0x$($magic.ToString('X')): $fullPath" }
        $directoryCount = [BitConverter]::ToUInt32($optional, $directoriesOffset - 4)
        $debugDirectory = 6
        if ($directoryCount -le $debugDirectory) { return $null }
        $debugRva = [BitConverter]::ToUInt32($optional, $directoriesOffset + 8 * $debugDirectory)
        $debugSize = [BitConverter]::ToUInt32($optional, $directoriesOffset + 8 * $debugDirectory + 4)
        if ($debugRva -eq 0 -or $debugSize -eq 0) { return $null }

        $sections = Read-SymbolsFileBytes -Stream $stream -Offset ($optionalOffset + $optionalSize) -Count (40 * $sectionCount)
        $debugOffset = $null
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $virtualSize = [BitConverter]::ToUInt32($sections, 40 * $i + 8)
            $virtualAddress = [BitConverter]::ToUInt32($sections, 40 * $i + 12)
            $rawSize = [BitConverter]::ToUInt32($sections, 40 * $i + 16)
            $rawPointer = [BitConverter]::ToUInt32($sections, 40 * $i + 20)
            $extent = [Math]::Max([long]$virtualSize, [long]$rawSize)
            if ($debugRva -ge $virtualAddress -and $debugRva -lt [long]$virtualAddress + $extent) {
                $debugOffset = [long]$rawPointer + ($debugRva - $virtualAddress)
                break
            }
        }
        if ($null -eq $debugOffset) { throw "Debug directory RVA 0x$($debugRva.ToString('X')) is in no section: $fullPath" }

        $entries = Read-SymbolsFileBytes -Stream $stream -Offset $debugOffset -Count ([int]($debugSize - ($debugSize % 28)))
        $found = @()
        for ($i = 0; $i + 28 -le $entries.Length; $i += 28) {
            $type = [BitConverter]::ToUInt32($entries, $i + 12)
            if ($type -ne 2) { continue }   # IMAGE_DEBUG_TYPE_CODEVIEW
            $dataSize = [BitConverter]::ToUInt32($entries, $i + 16)
            $dataPointer = [BitConverter]::ToUInt32($entries, $i + 24)
            if ($dataSize -lt 25 -or $dataSize -gt 4096) { throw "Implausible CodeView record size ${dataSize}: $fullPath" }
            $record = Read-SymbolsFileBytes -Stream $stream -Offset $dataPointer -Count ([int]$dataSize)
            if ([System.Text.Encoding]::ASCII.GetString($record, 0, 4) -cne 'RSDS') { continue }
            $guidBytes = New-Object byte[] 16
            [Array]::Copy($record, 4, $guidBytes, 0, 16)
            $nameLength = [Array]::IndexOf($record, [byte]0, 24)
            if ($nameLength -lt 0) { throw "Unterminated CodeView PDB path: $fullPath" }
            $pdbPath = [System.Text.Encoding]::UTF8.GetString($record, 24, $nameLength - 24)
            $found += [pscustomobject]@{
                Guid = [guid]::new($guidBytes)
                Age = [BitConverter]::ToUInt32($record, 20)
                PdbPath = $pdbPath
                PdbName = $pdbPath.Substring([Math]::Max($pdbPath.LastIndexOf('\'), $pdbPath.LastIndexOf('/')) + 1)
            }
        }
        if ($found.Count -gt 1) { throw "More than one CodeView record: $fullPath" }
        if ($found.Count -eq 0) { return $null }
        return $found[0]
    }
    finally {
        $stream.Dispose()
    }
}

function Get-PdbIdentity {
    # The GUID and age in the PDB info stream (stream 1) of an MSF 7.00
    # container, which is what lld writes and dbghelp checks.
    param([Parameter(Mandatory)] [string]$Path)

    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $stream = [System.IO.File]::Open(
        $fullPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $expectedMagic = [System.Text.Encoding]::ASCII.GetBytes("Microsoft C/C++ MSF 7.00`r`n") +
            [byte[]](0x1A, 0x44, 0x53, 0, 0, 0)
        $super = Read-SymbolsFileBytes -Stream $stream -Offset 0 -Count 56
        for ($i = 0; $i -lt $expectedMagic.Length; $i++) {
            if ($super[$i] -ne $expectedMagic[$i]) { throw "Not an MSF 7.00 PDB: $fullPath" }
        }
        $blockSize = [long][BitConverter]::ToUInt32($super, 32)
        $blockCount = [long][BitConverter]::ToUInt32($super, 40)
        $directoryBytes = [long][BitConverter]::ToUInt32($super, 44)
        $blockMapAddress = [long][BitConverter]::ToUInt32($super, 52)
        if ($blockSize -lt 512 -or $blockSize -gt 65536 -or ($blockSize -band ($blockSize - 1)) -ne 0) {
            throw "Implausible PDB block size ${blockSize}: $fullPath"
        }
        if ($blockCount * $blockSize -gt $stream.Length) { throw "PDB is truncated: $fullPath" }
        if ($directoryBytes -le 0 -or $directoryBytes -gt 64MB) { throw "Implausible PDB stream directory size ${directoryBytes}: $fullPath" }

        $directoryBlockCount = [int][Math]::Ceiling($directoryBytes / $blockSize)
        $blockMap = Read-SymbolsFileBytes -Stream $stream -Offset ($blockMapAddress * $blockSize) -Count (4 * $directoryBlockCount)
        $directory = New-Object byte[] ($directoryBlockCount * $blockSize)
        for ($i = 0; $i -lt $directoryBlockCount; $i++) {
            $block = [long][BitConverter]::ToUInt32($blockMap, 4 * $i)
            $bytes = Read-SymbolsFileBytes -Stream $stream -Offset ($block * $blockSize) -Count ([int]$blockSize)
            [Array]::Copy($bytes, 0, $directory, $i * $blockSize, $blockSize)
        }

        $streamCount = [BitConverter]::ToUInt32($directory, 0)
        if ($streamCount -lt 2 -or 4 + 4 * [long]$streamCount -gt $directoryBytes) { throw "PDB has no info stream: $fullPath" }
        $sizes = for ($i = 0; $i -lt $streamCount; $i++) {
            $size = [BitConverter]::ToUInt32($directory, 4 + 4 * $i)
            if ($size -eq [uint32]::MaxValue) { 0 } else { [long]$size }
        }
        $infoSize = $sizes[1]
        if ($infoSize -lt 28) { throw "PDB info stream is too small ($infoSize bytes): $fullPath" }
        # Stream 0 (the old directory) precedes it in the block-index list.
        $skipBlocks = [long][Math]::Ceiling($sizes[0] / $blockSize)
        $indexOffset = 4 + 4 * [long]$streamCount + 4 * $skipBlocks
        if ($indexOffset + 4 -gt $directoryBytes) { throw "PDB stream directory is truncated: $fullPath" }
        $infoBlock = [long][BitConverter]::ToUInt32($directory, [int]$indexOffset)
        $info = Read-SymbolsFileBytes -Stream $stream -Offset ($infoBlock * $blockSize) -Count 28
        $guidBytes = New-Object byte[] 16
        [Array]::Copy($info, 12, $guidBytes, 0, 16)
        return [pscustomobject]@{
            Guid = [guid]::new($guidBytes)
            Age = [BitConverter]::ToUInt32($info, 8)
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-SymbolsArchiveMatchesPortable {
    # The shipped symbols zip, extracted into the empty directory $ExtractRoot,
    # is one `symbols` folder whose PDBs match the PEs of the extracted
    # portable payload.
    param(
        [Parameter(Mandatory)] [string]$SymbolsZip,
        [Parameter(Mandatory)] [string]$PayloadRoot,
        [Parameter(Mandatory)] [string]$ExtractRoot,
        [Parameter(Mandatory)] [string]$Label
    )

    Expand-Archive -LiteralPath $SymbolsZip -DestinationPath $ExtractRoot
    $top = @(Get-ChildItem -LiteralPath $ExtractRoot -Force)
    if ($top.Count -ne 1 -or -not $top[0].PSIsContainer -or $top[0].Name -cne 'symbols') {
        throw "$Label must contain exactly one top-level symbols folder."
    }
    return Assert-SymbolsMatchBinaries `
        -SymbolsRoot $top[0].FullName `
        -PayloadRoot $PayloadRoot `
        -Label $Label
}

function Assert-SymbolsMatchBinaries {
    # Every koreterm-built PE under $PayloadRoot with a CodeView record has the
    # PDB it names in $SymbolsRoot with the same GUID and age, and the symbols
    # directory holds nothing else. koreterm.exe and koreterm.com must have one.
    param(
        [Parameter(Mandatory)] [string]$SymbolsRoot,
        [Parameter(Mandatory)] [string]$PayloadRoot,
        [Parameter(Mandatory)] [string]$Label
    )

    $required = @('koreterm.exe', 'koreterm.com')
    $expectedPdbs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $evidence = @()
    foreach ($binaryName in (Get-WindowsSymbolBinaryNames)) {
        $binaryPath = Join-Path $PayloadRoot $binaryName
        if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
            throw "$Label is missing $binaryName."
        }
        $identity = Get-PeCodeViewIdentity -Path $binaryPath
        if ($null -eq $identity) {
            if ($binaryName -in $required) { throw "$Label $binaryName carries no CodeView record, so it has no symbols to match." }
            continue
        }
        if ($identity.PdbName -notmatch '^[A-Za-z0-9._-]+\.pdb$') {
            throw "$Label $binaryName names an unexpected PDB file: $($identity.PdbName)"
        }
        $pdbPath = Join-Path $SymbolsRoot $identity.PdbName
        if (-not (Test-Path -LiteralPath $pdbPath -PathType Leaf)) {
            throw "$Label has no $($identity.PdbName) for $binaryName."
        }
        $pdb = Get-PdbIdentity -Path $pdbPath
        if ($pdb.Guid -ne $identity.Guid -or $pdb.Age -ne $identity.Age) {
            throw "$Label $($identity.PdbName) does not match $binaryName (binary $($identity.Guid) age $($identity.Age), PDB $($pdb.Guid) age $($pdb.Age))."
        }
        [void]$expectedPdbs.Add($identity.PdbName)
        $evidence += [pscustomobject]@{
            Binary = $binaryName
            Pdb = $identity.PdbName
            Guid = $identity.Guid
            Age = $identity.Age
        }
    }

    $actualPdbs = @(Get-ChildItem -LiteralPath $SymbolsRoot -Recurse -Force | ForEach-Object { $_.FullName.Substring($SymbolsRoot.TrimEnd('\').Length + 1) })
    $unexpected = @($actualPdbs | Where-Object { -not $expectedPdbs.Contains($_) })
    if ($unexpected.Count -gt 0) {
        throw "$Label holds files that match no shipped binary: $($unexpected -join ', ')."
    }
    return $evidence
}
