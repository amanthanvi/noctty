$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts/release-fixture-directory.ps1')

$parent = New-ReleaseFixtureDirectory
$previousWhatIf = $WhatIfPreference
try {
    $sentinel = Join-Path $parent 'keep.txt'
    [IO.File]::WriteAllText($sentinel, 'caller-owned')
    function Assert-CleanParent {
        if (@(Get-ChildItem -LiteralPath $parent -Force).Count -ne 1 -or
            [IO.File]::ReadAllText($sentinel) -cne 'caller-owned') {
            throw 'Release fixture retained work or removed a caller-owned file.'
        }
    }
    function gh {
        if ($args[0] -cne 'api' -or $args[-1] -cne '--include') { throw 'Unexpected historical fixture GitHub call.' }
        $draft = '{"id":136,"tag_name":"v1.3.136","prerelease":false}'
        $json = switch -CaseSensitive ($args[1]) {
            'repos/amanthanvi/noctty/releases?per_page=100&page=1' { "[$draft]" }
            'repos/amanthanvi/noctty/releases/136' { $draft }
            default { throw 'Unexpected historical fixture GitHub endpoint.' }
        }
        $global:LASTEXITCODE = 0
        'HTTP/2 200'
        ''
        $json
    }
    function git {
        if ($args[0] -cne 'clone') { throw 'Unexpected historical fixture Git call.' }
        $candidate = [IO.Path]::GetFullPath($args[-1])
        if (-not $candidate.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Historical fixture clone escaped its caller-supplied parent.'
        }
        [void][IO.Directory]::CreateDirectory($candidate)
        [IO.File]::WriteAllText((Join-Path $candidate 'partial.txt'), 'clone stopped midway')
        $global:LASTEXITCODE = 1
    }

    $WhatIfPreference = $true
    $failure = $null
    try { & (Join-Path $repoRoot 'scripts/release-promote.ps1') -Fixture historical -WorkDirectory $parent -WhatIf 6>$null }
    catch { $failure = $_ }
    if ($failure.Exception.Message -cne 'Historical candidate checkout failed.') {
        throw "Fixture A did not reach the injected clone failure: $failure"
    }
    Assert-CleanParent

    $failure = $null
    try { & (Join-Path $PSScriptRoot 'release-promote.ps1') -WorkDirectory $parent -AssetDirectory $sentinel }
    catch { $failure = $_ }
    if ($failure.Exception.InnerException -isnot [IO.IOException]) {
        throw "Fixture B did not reach the injected asset-directory failure: $failure"
    }
    Assert-CleanParent
    Write-Host 'Release fixture cleanup: PASS (historical clone and recorded asset-directory failures under outer WhatIf).'
} finally {
    $WhatIfPreference = $previousWhatIf
    Remove-ReleaseFixtureDirectory -RunDirectory $parent
    $global:LASTEXITCODE = 0
}
