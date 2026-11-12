# The ghostty-vt.dll placeholder the portable ZIP carries in place of the
# retired libghostty-vt library (src/ghostty_vt_stub/, built by
# src/build/GhosttyVtStub.zig). Dot-sourced by scripts/package-windows.ps1 and
# test/windows/package-portable-cli.ps1.

# The FileDescription in src/ghostty_vt_stub/ghostty_vt_stub.rc.
$script:GhosttyVtStubDescription = 'koreterm placeholder for the retired ghostty-vt.dll; not libghostty-vt'
# The stub is a few KB; libghostty-vt is megabytes. A bound well above the
# first and far below the second.
$script:GhosttyVtStubMaxBytes = 64KB

function Get-PeDataDirectories {
    # The (RVA, size) pairs of a PE image's optional-header data directories,
    # indexed as in the PE/COFF specification (0 export, 1 import, 2 resource).
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "$Path is not a PE image (no MZ header)."
    }
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or $peOffset + 24 -gt $bytes.Length -or
        [System.BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550) {
        throw "$Path is not a PE image (no PE signature)."
    }
    $optionalHeader = $peOffset + 24
    $optionalHeaderSize = [System.BitConverter]::ToUInt16($bytes, $peOffset + 20)
    $magic = [System.BitConverter]::ToUInt16($bytes, $optionalHeader)
    $countOffset = switch ($magic) {
        0x10B { 92 }
        0x20B { 108 }
        default { throw "$Path has an unknown optional header magic 0x$($magic.ToString('x'))." }
    }
    $count = [System.BitConverter]::ToUInt32($bytes, $optionalHeader + $countOffset)
    $first = $optionalHeader + $countOffset + 4
    if ($countOffset + 4 + 8 * $count -gt $optionalHeaderSize -or $first + 8 * $count -gt $bytes.Length) {
        throw "$Path has a truncated data directory table."
    }
    $directories = @()
    for ($i = 0; $i -lt $count; $i++) {
        $directories += [pscustomobject] @{
            Rva = [System.BitConverter]::ToUInt32($bytes, $first + 8 * $i)
            Size = [System.BitConverter]::ToUInt32($bytes, $first + 8 * $i + 4)
        }
    }
    return $directories
}

function Assert-GhosttyVtStub {
    # Throws unless the file at Path is the placeholder and not the library:
    # no export or import table, the stub's FileDescription, and a stub's size.
    # Loading it is the job of test/windows/test_dll_init.c; this never runs it.
    param([Parameter(Mandatory)] [string] $Path)

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -gt $script:GhosttyVtStubMaxBytes) {
        throw "$Path is $length bytes, not the ghostty-vt.dll placeholder (at most $($script:GhosttyVtStubMaxBytes)); is it libghostty-vt?"
    }
    $directories = @(Get-PeDataDirectories -Path $Path)
    if ($directories.Count -lt 2) {
        throw "$Path has no export or import directory entry."
    }
    if ($directories[0].Rva -ne 0 -or $directories[0].Size -ne 0) {
        throw "$Path has an export table; the ghostty-vt.dll placeholder exports nothing."
    }
    if ($directories[1].Rva -ne 0 -or $directories[1].Size -ne 0) {
        throw "$Path has an import table; the ghostty-vt.dll placeholder imports nothing."
    }
    $description = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileDescription
    if ($description -cne $script:GhosttyVtStubDescription) {
        throw "$Path has FileDescription '$description', not the ghostty-vt.dll placeholder's."
    }
}
