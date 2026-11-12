param([Parameter(Mandatory)][string] $BinDirectory)
$ErrorActionPreference = 'Stop'

# Inspect the emitted PE import descriptors, without executing either image.
foreach ($name in @('koreterm.exe', 'koreterm.com')) {
    $path = Join-Path $BinDirectory $name
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $path))
    function U16([int] $offset) { [BitConverter]::ToUInt16($bytes, $offset) }
    function U32([int] $offset) { [BitConverter]::ToUInt32($bytes, $offset) }
    if ((U16 0) -ne 0x5a4d) { throw "Invalid DOS header: $name" }
    $pe = U32 0x3c
    if ((U32 $pe) -ne 0x4550) { throw "Invalid PE header: $name" }
    $optional = $pe + 24
    $directories = switch (U16 $optional) {
        0x20b { $optional + 112 }
        0x10b { $optional + 96 }
        default { throw "Invalid optional header: $name" }
    }
    $sections = $optional + (U16 ($pe + 20))
    function FileOffset([uint32] $rva) {
        for ($i = 0; $i -lt (U16 ($pe + 6)); $i++) {
            $section = $sections + 40 * $i
            $start = U32 ($section + 12)
            $size = [Math]::Max((U32 ($section + 8)), (U32 ($section + 16)))
            if ($rva -ge $start -and $rva -lt $start + $size) {
                return [int]($rva - $start + (U32 ($section + 20)))
            }
        }
        throw "Unmapped import RVA in $name"
    }
    $rva = U32 ($directories + 8)
    $imports = @()
    if ($rva) {
        $descriptor = FileOffset $rva
        while ($dll = U32 ($descriptor + 12)) {
            $offset = FileOffset $dll
            $end = $offset
            while ($bytes[$end]) { $end++ }
            $imports += [Text.Encoding]::ASCII.GetString($bytes, $offset, $end - $offset)
            $descriptor += 20
        }
    }
    if ($imports -inotcontains 'kernel32.dll') { throw "$name import table not parsed" }
    if ($imports -icontains 'opengl32.dll') { throw "$name eagerly imports OPENGL32.dll" }
    Write-Host "$name imports no OPENGL32.dll ($($imports.Count) import descriptors checked)"
}
