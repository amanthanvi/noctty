[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$paths = @('build.zig') + @(& git -C $repoRoot ls-files --cached --others --exclude-standard -- 'src/*.zig' 'src/**/*.zig' 'pkg/*.zig' 'pkg/**/*.zig')
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed while collecting Zig sources.' }
$paths = @($paths | Where-Object { $_ -ne 'src/build/uucode_tables.zig' } | Sort-Object -Unique)

Push-Location $repoRoot
try {
    for ($offset = 0; $offset -lt $paths.Count; $offset += 100) {
        $end = [Math]::Min($offset + 99, $paths.Count - 1)
        & zig fmt --check @($paths[$offset..$end])
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
finally {
    Pop-Location
}
Write-Host "Zig formatting checks passed ($($paths.Count) tracked sources)." -ForegroundColor Green
