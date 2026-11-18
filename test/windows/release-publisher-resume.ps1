[CmdletBinding()]
param([string] $WorkDirectory)
$ErrorActionPreference = 'Stop'
$previousResumeContext = $global:NocttyReleaseResumeFixture
$global:NocttyReleaseResumeFixture = [pscustomobject]@{ Case=$null; Clone=$null; Source=$null; GitCalls=$null }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$createdWorkDirectory = -not $WorkDirectory
if (-not $WorkDirectory) { $WorkDirectory = Join-Path ([IO.Path]::GetTempPath()) ('release-resume-' + [guid]::NewGuid().ToString('N')) }
if (Test-Path -LiteralPath $WorkDirectory) { throw 'Resume fixture directory must be fresh.' }
[void][IO.Directory]::CreateDirectory($WorkDirectory)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/release-submit-winget.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'WinGet publisher does not parse.' }
$function = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-WinGetVersionSubmitted' }, $true))
if ($function.Count -ne 1) { throw 'Expected exactly one WinGet version query.' }
. ([scriptblock]::Create($function[0].Extent.Text))
$PackageIdentifier = 'AmanThanvi.noctty'
$Version = '1.3.136'
$global:NocttyReleaseResumeFixture.Case = ''
function gh {
    $global:LASTEXITCODE = 0
    $case = $global:NocttyReleaseResumeFixture.Case
    if ($case -eq 'unknown') { $global:LASTEXITCODE = 1; return '{}' }
    $endpoint = $args[1]
    if ($endpoint -ceq 'repos/microsoft/winget-pkgs/pulls/123') {
        return (@{changed_files=$(if ($case -in @('files-incomplete','files-paginated')) { 101 } elseif ($case -eq 'merged-retitled') { 3 } else { 1 })} | ConvertTo-Json)
    }
    if ($args -contains 'repos/microsoft/winget-pkgs/commits') {
        if ($case -in @('merged','merged-retitled')) { return (ConvertTo-Json -InputObject @(@{sha='a'*40})) }
        return '[]'
    }
    if ($endpoint -like '*/commits/*/pulls?*') {
        return (ConvertTo-Json -InputObject @(@{number=123;state='closed';merged_at='2026-11-18T00:00:00Z';title='Unrelated retitled text'}))
    }
    $path = switch ($case) {
        'other-package' { 'manifests/o/Other/Package/1.3.136/Other.Package.yaml' }
        'other-version' { 'manifests/a/AmanThanvi/noctty/1.3.1360/AmanThanvi.noctty.yaml' }
        default { 'manifests/a/AmanThanvi/noctty/1.3.136/AmanThanvi.noctty.yaml' }
    }
    if ($endpoint -like '*/files?*') {
        if ($case -eq 'files-incomplete') { return '[{}]' }
        if ($case -eq 'files-paginated' -and $endpoint -like '*page=1') {
            return (ConvertTo-Json -InputObject @(1..100 | ForEach-Object { @{filename="unrelated/$_.yaml";status='added'} }))
        }
        if ($case -eq 'merged-retitled') {
            return (ConvertTo-Json -InputObject @(1..3 | ForEach-Object { @{filename=$path;status='added'} }))
        }
        return (ConvertTo-Json -InputObject @(@{filename=$path;status='added'}))
    }
    if ($endpoint -ceq 'graphql') {
        if ($case -eq 'incomplete') { return '{"errors":[{"message":"Unavailable"}]}' }
        $nodes = @()
        $nextPage = $false
        if ($case -notin @('absent','closed')) {
            $files = @{ nodes=@(@{path=$path;changeType=$(if ($case -eq 'deleted') { 'DELETED' } else { 'ADDED' })}); pageInfo=@{hasNextPage=$false;endCursor=$null} }
            if ($case -in @('files-paginated','files-incomplete')) { $files.nodes=@(); $files.pageInfo.hasNextPage=$true }
            $nodes = @(@{ number=123; files=$files })
            if ($case -in @('paginated','stalled') -and $args -notcontains 'cursor=page2') { $nodes=@(); $nextPage=$true }
        }
        return (@{data=@{repository=@{pullRequests=@{nodes=$nodes;pageInfo=@{hasNextPage=$nextPage;endCursor=$(if ($case -eq 'stalled') { $null } else { 'page2' })}}}}} | ConvertTo-Json -Depth 9)
    }
    throw 'Resume fixture refused an unrecorded API operation.'
}
$savedToken = $env:GH_TOKEN
$savedWinGetToken = $env:WINGET_CREATE_GITHUB_TOKEN
$env:WINGET_CREATE_GITHUB_TOKEN = 'resume-fixture-token'
$cases = [ordered]@{ open = $true; 'open-retitled' = $true; merged = $true; 'merged-retitled' = $true; paginated = $true; 'files-paginated' = $true; deleted = $false; stalled = 'error'; closed = $false; absent = $false; 'other-package' = $false; 'other-version' = $false; unknown = 'error'; incomplete = 'error'; 'files-incomplete' = 'error' }
try {
    foreach ($case in $cases.Keys) {
        $global:NocttyReleaseResumeFixture.Case = $case
        $message = $null; $actual = $null
        try { $actual = Test-WinGetVersionSubmitted } catch { $message = $_.Exception.Message }
        if ($cases[$case] -is [string]) {
            if (-not $message -or $message -notmatch 'Could not determine') { throw "WinGet resume $case did not fail closed." }
        } elseif ($message -or $actual -ne $cases[$case]) { throw "WinGet resume $case returned the wrong state." }
        if ($env:GH_TOKEN -cne $savedToken) { throw 'WinGet query did not restore the GitHub token.' }
        Write-Host "Publisher resume WinGet $case`: PASS"
    }
} finally {
    $env:WINGET_CREATE_GITHUB_TOKEN = $savedWinGetToken
    $env:GH_TOKEN = $savedToken
    Remove-Item Function:\gh
    $global:LASTEXITCODE = 0
}

# Execute the actual Scoop publisher through its unchanged-target return.
# A stand-in clone contains exactly the generated bytes; any commit/push fails.
$artifactRoot = Join-Path $WorkDirectory 'artifacts'
$primary = Join-Path $artifactRoot 'noctty-1.3.136-windows-x64'
$source = Join-Path $primary 'package-managers/scoop/noctty.json'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $source))
[IO.File]::WriteAllText($source, '{"version":"1.3.136"}')
[IO.File]::WriteAllText((Join-Path $primary 'package-managers/metadata.json'), '{"schemaVersion":2,"scoop":{"manifestPath":"package-managers/scoop/noctty.json"}}')
$global:NocttyReleaseResumeFixture.Clone = Join-Path $WorkDirectory 'noctty-scoop-bucket'
$global:NocttyReleaseResumeFixture.Source = $source
$global:NocttyReleaseResumeFixture.GitCalls = [Collections.Generic.List[string]]::new()
function git {
    $global:LASTEXITCODE = 0
    if ($args -contains 'clone') {
        [void][IO.Directory]::CreateDirectory((Join-Path $global:NocttyReleaseResumeFixture.Clone 'bucket'))
        Copy-Item -LiteralPath $global:NocttyReleaseResumeFixture.Source -Destination (Join-Path $global:NocttyReleaseResumeFixture.Clone 'bucket/noctty.json')
    } elseif ($args -contains 'commit' -or $args -contains 'push') { throw 'Unchanged Scoop manifest must not commit or push.' }
    $global:NocttyReleaseResumeFixture.GitCalls.Add(($args -join ' '))
}
try {
    $env:GH_TOKEN = 'resume-fixture-token'
    & (Join-Path $repoRoot 'scripts/release-publish-scoop.ps1') -Version 1.3.136 -ArtifactRoot $artifactRoot -RunnerTemp $WorkDirectory -BucketRepository fixture/bucket
    if (@($global:NocttyReleaseResumeFixture.GitCalls | Where-Object { $_ -ceq 'diff --cached --quiet --exit-code' }).Count -ne 1) { throw 'Scoop did not test whether the staged manifest was equal.' }
} finally {
    $env:GH_TOKEN = $savedToken
    Remove-Item Function:\git
    $global:LASTEXITCODE = 0
}
Write-Host "Publisher resume: PASS ($($cases.Count) WinGet cases and unchanged Scoop with relative metadata)."

$global:NocttyReleaseResumeFixture = $previousResumeContext

if ($createdWorkDirectory -and [IO.Path]::GetFileName($WorkDirectory) -cmatch '\Arelease-resume-[0-9a-f]{32}\z' -and [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($WorkDirectory)) -eq [IO.Path]::GetTempPath().TrimEnd('\','/')) { Remove-Item -LiteralPath $WorkDirectory -Recurse -Force }
