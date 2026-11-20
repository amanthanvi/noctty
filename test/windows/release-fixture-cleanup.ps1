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
    function Get-RetainedFixtureEvidence {
        param([string] $FixtureParent)
        $runs = @(Get-ChildItem -LiteralPath $FixtureParent -Directory -Force)
        if ($runs.Count -ne 1) { throw 'Failed Fixture B did not retain one run directory.' }
        $evidence = @(Get-ChildItem -LiteralPath $runs[0].FullName -Force)
        if ($evidence.Count -ne 1 -or $evidence[0].Name -cne 'results.json' -or $evidence[0].PSIsContainer) {
            throw 'Failed Fixture B did not retain just its available text evidence.'
        }
        $record = [IO.File]::ReadAllText($evidence[0].FullName) | ConvertFrom-Json
        if ($record.result -cne 'fail') { throw 'Fixture B failure record is missing.' }
        return $runs[0].FullName
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
    try { & (Join-Path $PSScriptRoot 'release-promote.ps1') -WorkDirectory $parent -AssetDirectory $sentinel -WarningAction SilentlyContinue }
    catch { $failure = $_ }
    if ($failure.Exception.InnerException -isnot [IO.IOException]) {
        throw "Fixture B did not reach the injected asset-directory failure: $failure"
    }
    Remove-ReleaseFixtureDirectory -RunDirectory (Get-RetainedFixtureEvidence -FixtureParent $parent)
    Assert-CleanParent

    # Exercise the actual system-temp fallback without creating work outside
    # the test's owned parent. Restore the caller's configuration afterward.
    $scratchTemp = [IO.Directory]::CreateDirectory([IO.Path]::Combine($parent, 'fallback')).FullName
    $override = [IO.Directory]::CreateDirectory([IO.Path]::Combine($parent, 'override')).FullName
    $environment = @{}
    foreach ($name in @('TEMP','TMP','NOCTTY_RELEASE_FIXTURE_ROOT','GITHUB_ACTIONS','RUNNER_TEMP')) {
        $environment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
        $env:TEMP = $scratchTemp
        $env:TMP = $scratchTemp
        $env:NOCTTY_RELEASE_FIXTURE_ROOT = $null
        $env:GITHUB_ACTIONS = $null
        $env:RUNNER_TEMP = $null
        $fallbackRun = New-ReleaseFixtureDirectory
        if ([IO.Path]::GetDirectoryName($fallbackRun) -cne $scratchTemp) { throw 'Unconfigured fixtures must use the system temp path.' }
        Remove-ReleaseFixtureDirectory -RunDirectory $fallbackRun
        if (@(Get-ChildItem -LiteralPath $scratchTemp -Force).Count) { throw 'Temp fallback retained a run child.' }

        $env:NOCTTY_RELEASE_FIXTURE_ROOT = $override
        $overrideRun = New-ReleaseFixtureDirectory
        if ([IO.Path]::GetDirectoryName($overrideRun) -cne $override) { throw 'Fixture root override was ignored.' }
        Remove-ReleaseFixtureDirectory -RunDirectory $overrideRun
        if (@(Get-ChildItem -LiteralPath $override -Force).Count) { throw 'Root override retained a run child.' }
    } finally {
        foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $environment[$name]) }
    }

    $bracketed = [IO.Directory]::CreateDirectory([IO.Path]::Combine($parent, 'fixture-[ab]')).FullName
    $siblingA = [IO.Directory]::CreateDirectory([IO.Path]::Combine($parent, 'fixture-a')).FullName
    $siblingB = [IO.Directory]::CreateDirectory([IO.Path]::Combine($parent, 'fixture-b')).FullName
    $literalRun = @(New-ReleaseFixtureDirectory -ParentDirectory $bracketed)
    if ($literalRun.Count -ne 1 -or [IO.Path]::GetDirectoryName($literalRun[0]) -cne $bracketed -or
        @(Get-ChildItem -LiteralPath $siblingA,$siblingB -Force).Count) {
        throw 'Fixture path was not created under the literal bracketed parent.'
    }
    Remove-ReleaseFixtureDirectory -RunDirectory $literalRun[0]

    # Stop at the first download after recording its default destination.
    # No network access or real asset setup is needed for this control.
    function Invoke-WebRequest {
        param([string] $Uri, [string] $OutFile, [int] $MaximumRetryCount)
        $assets = [IO.FileInfo]::new($OutFile).Directory
        if ($assets.Name -cne 'assets' -or $assets.Parent.Name -cne 'bulk' -or
            $assets.Parent.Parent.Parent.FullName -cne $bracketed) {
            throw 'Default Fixture B asset directory escaped its owned bulk tree.'
        }
        [IO.File]::WriteAllText($OutFile, 'incomplete asset')
        throw 'InjectedFixtureBDownloadFailure'
    }
    $failure = $null
    try { & (Join-Path $PSScriptRoot 'release-promote.ps1') -WorkDirectory $bracketed -WarningAction SilentlyContinue }
    catch { $failure = $_ }
    if ($failure.Exception.Message -cne 'InjectedFixtureBDownloadFailure') {
        throw "Fixture B did not use the expected default asset directory: $failure"
    }
    Remove-ReleaseFixtureDirectory -RunDirectory (Get-RetainedFixtureEvidence -FixtureParent $bracketed)
    Write-Host 'Release fixture cleanup: PASS (temp fallback, root override, literal brackets, default assets and failure evidence under outer WhatIf).'
} finally {
    $WhatIfPreference = $previousWhatIf
    Remove-ReleaseFixtureDirectory -RunDirectory $parent
    $global:LASTEXITCODE = 0
}
