function New-ReleaseFixtureDirectory {
    param([string] $ParentDirectory)
    if (-not $ParentDirectory) { $ParentDirectory = $env:NOCTTY_RELEASE_FIXTURE_ROOT }
    if (-not $ParentDirectory -and $env:GITHUB_ACTIONS -ceq 'true') { $ParentDirectory = $env:RUNNER_TEMP }
    if (-not $ParentDirectory) { $ParentDirectory = [IO.Path]::GetTempPath() }
    $parent = Get-Item -LiteralPath $ParentDirectory
    if ($parent -isnot [IO.DirectoryInfo]) { throw 'Release fixture parent must be an existing filesystem directory.' }
    $leaf = 'release-fixture-' + [guid]::NewGuid().ToString('N')
    # Use a literal filesystem path even when the parent contains brackets.
    $path = [IO.Path]::Combine($parent.FullName, $leaf)
    if (Test-Path -LiteralPath $path) { throw 'Fixture run path already exists.' }
    return [IO.Directory]::CreateDirectory($path).FullName
}

function Remove-ReleaseFixtureDirectory {
    param([string] $RunDirectory)
    if ([IO.Path]::GetFileName($RunDirectory) -cnotmatch '\Arelease-fixture-[0-9a-f]{32}\z') {
        throw 'Fixture cleanup refused a directory without its generated run name.'
    }
    if (Test-Path -LiteralPath $RunDirectory) {
        $run = Get-Item -LiteralPath $RunDirectory -Force
        if ($run -isnot [IO.DirectoryInfo] -or ($run.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Fixture cleanup refused a non-directory or reparse point.'
        }
        Remove-Item -LiteralPath $RunDirectory -Recurse -Force -WhatIf:$false
    }
}
