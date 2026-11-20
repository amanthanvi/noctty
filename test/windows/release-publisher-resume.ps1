[CmdletBinding()]
param([string] $WorkDirectory)
$ErrorActionPreference = 'Stop'
$previousResumeContext = $global:NocttyReleaseResumeFixture
$global:NocttyReleaseResumeFixture = [pscustomobject]@{ Case=$null; Clone=$null; Source=$null; GitCalls=$null; Calls=$null; Failures=0; Delays=$null }
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
function Start-Sleep {
    param([int]$Milliseconds,[int]$Seconds)
    $global:NocttyReleaseResumeFixture.Delays.Add($(if($Seconds){$Seconds*1000}else{$Milliseconds}))
}
function gh {
    $global:LASTEXITCODE=0
    $case=$global:NocttyReleaseResumeFixture.Case
    if ($args[0] -cne 'api' -or $args -notcontains 'GET' -or $args -contains 'graphql') { throw 'WinGet fixture refused a non-REST-GET operation.' }
    $endpoint=@($args|Where-Object {$_ -like 'repos/*' -or $_ -eq 'user' -or $_ -eq 'search/issues'})[0]
    $global:NocttyReleaseResumeFixture.Calls.Add($endpoint)
    $status=200;$data=$null
    if ($case -in @('connection-exhausted','connection-once') -and ($case -eq 'connection-exhausted' -or $global:NocttyReleaseResumeFixture.Failures -eq 0)) { $global:NocttyReleaseResumeFixture.Failures++; $global:LASTEXITCODE=1; return }
    if ($case -eq 'unknown') { $status=401;$data=@{message='Unauthorized'} }
    elseif ($endpoint -ceq 'repos/microsoft/winget-pkgs') { $data=@{default_branch='master'} }
    elseif ($endpoint -like '*/contents/*') {
        if ($args -notcontains 'ref=master') { throw 'Default branch was not explicitly checked.' }
        if ($case -in @('merged','merged-retitled','default-branch')) { $data=@(@{type='file';name='AmanThanvi.noctty.yaml';path='manifests/a/AmanThanvi/noctty/1.3.136/AmanThanvi.noctty.yaml'}) }
        else { $status=404;$data=@{message='Not Found'} }
    }
    elseif ($endpoint -ceq 'user') { $data=@{login='fixture-author'} }
    elseif ($endpoint -ceq 'search/issues') {
        $query=@($args|Where-Object {$_ -like 'q=*'})[0]
        if ($args -notcontains 'per_page=100' -or $query -cne 'q=repo:microsoft/winget-pkgs is:pr is:open in:title,body "amanthanvi.noctty"') { throw 'Search must use identifier alone across title/body, with an open-PR bound.' }
        if ($case -eq 'query-error') { $global:LASTEXITCODE=1; 'HTTP/2.0 422'; ''; '{"message":"Invalid query"}'; return }
        if ($case -eq 'retry-exhausted' -or ($case -eq 'transient-502' -and $global:NocttyReleaseResumeFixture.Failures -eq 0)) {
            $status=502;$data=@{message='Bad Gateway'};$global:NocttyReleaseResumeFixture.Failures++
        } else {
            $items=@()
            if ($case -notin @('absent','large-population','incomplete','transient-502','connection-once','identifier-omitted')) { $items=@(@{number=123;title='Unrelated retitled text';body='AmanThanvi.noctty identifier retained without version';user=@{login='another-account'}}) }
            $data=@{items=$items;total_count=$items.Count;incomplete_results=($case -eq 'incomplete')}
            if ($case -eq 'too-broad') { $data.total_count=101 }
            if ($case -eq 'bound-100') { $data.items=@(1..100|ForEach-Object {@{number=$_+1000;title='Identifier retained but version omitted'}});$data.total_count=100 }
        }
    }
    elseif ($endpoint -match '\Arepos/microsoft/winget-pkgs/pulls/[0-9]+\z') {
        $data=@{state=$(if($case -eq 'closed'){'closed'}else{'open'});merged_at=$null;changed_files=$(if($case -in @('files-incomplete','files-paginated')){101}elseif($case -eq 'multiple-files'){3}else{1})}
    }
    elseif ($endpoint -like '*/pulls/*/files?*') {
        $path=switch($case){'other-package'{'manifests/o/Other/Package/1.3.136/Other.Package.yaml'} 'other-version'{'manifests/a/AmanThanvi/noctty/1.3.1360/AmanThanvi.noctty.yaml'} default{'manifests/a/AmanThanvi/noctty/1.3.136/AmanThanvi.noctty.yaml'}}
        if ($case -eq 'bound-100' -and $endpoint -notlike '*/pulls/1100/files?*') { $path='unrelated/file.yaml' }
        $data=@(@{filename=$path;status=$(if($case -eq 'deleted'){'removed'}else{'added'})})
        if ($case -eq 'files-incomplete') { $data=@(@{filename='unrelated/file.yaml';status='added'}) }
        if ($case -eq 'files-paginated' -and $endpoint -like '*page=1') { $data=@(1..100|ForEach-Object {@{filename="unrelated/$_.yaml";status='added'}}) }
        if ($case -eq 'multiple-files') { $data=@(1..3|ForEach-Object {@{filename=$path;status='added'}}) }
    }
    else { throw 'Resume fixture refused an unrecorded endpoint.' }
    "HTTP/2.0 $status";'';(ConvertTo-Json -Depth 8 -InputObject $data)
    $global:LASTEXITCODE=if($status -eq 200){0}else{1}
}
$savedToken = $env:GH_TOKEN
$savedWinGetToken = $env:WINGET_CREATE_GITHUB_TOKEN
$env:WINGET_CREATE_GITHUB_TOKEN = 'resume-fixture-token'
$cases = [ordered]@{ open=$true; 'open-retitled'=$true; merged=$true; 'merged-retitled'=$true; 'default-branch'=$true; 'multiple-files'=$true; 'files-paginated'=$true; deleted=$false; closed=$false; absent=$false; 'other-package'=$false; 'other-version'=$false; unknown='error'; incomplete='error'; 'files-incomplete'='error'; 'large-population'=$false; 'transient-502'=$false; 'retry-exhausted'='error'; 'too-broad'='WinGetCandidateSetIncomplete'; 'connection-once'=$false; 'connection-exhausted'='error'; 'other-account-retitled'=$true; 'identifier-omitted'=$false; 'query-error'='WinGetQueryFailed'; 'bound-100'=$true }
try {
    foreach ($case in $cases.Keys) {
        $global:NocttyReleaseResumeFixture.Case = $case
        $global:NocttyReleaseResumeFixture.Calls=[Collections.Generic.List[string]]::new()
        $global:NocttyReleaseResumeFixture.Delays=[Collections.Generic.List[int]]::new()
        $global:NocttyReleaseResumeFixture.Failures=0
        $message = $null; $actual = $null
        try {
            $observed=@(Test-WinGetVersionSubmitted 6>&1)
            $values=@($observed | Where-Object { $_ -is [bool] })
            if($values.Count -ne 1){throw 'Expected one bounded lookup result.'}
            $actual=$values[0]
            if(-not $actual -and @($observed | Where-Object { [string]$_ -like '*absent within the stated limit*PRs from any account*both fields are excluded*' }).Count -ne 1){throw 'A miss lacked the author-independent stated-limit qualification.'}
        } catch { $message = $_.Exception.Message }
        if ($cases[$case] -is [string]) {
            if (-not $message -or $message -notmatch $(if($cases[$case] -eq 'error'){'WinGetQueryFailed|WinGetCandidateSetIncomplete'}else{$cases[$case]})) { throw "WinGet resume $case did not fail closed." }
        } elseif ($message -or $actual -ne $cases[$case]) { throw "WinGet resume $case returned the wrong state." }
        if ($env:GH_TOKEN -cne $savedToken) { throw 'WinGet query did not restore the GitHub token.' }
        if ($case -eq 'retry-exhausted' -and ($global:NocttyReleaseResumeFixture.Failures -ne 3 -or -not $global:NocttyReleaseResumeFixture.Delays.Contains(2000) -or -not $global:NocttyReleaseResumeFixture.Delays.Contains(4000))) { throw '5xx retries were not bounded with backoff.' }
        if ($case -eq 'connection-exhausted' -and $global:NocttyReleaseResumeFixture.Failures -ne 3) { throw 'Connection retries were not bounded.' }
        if ($case -eq 'transient-502' -and $global:NocttyReleaseResumeFixture.Failures -ne 1) { throw 'Transient 502 was not exercised.' }
        if ($case -eq 'large-population' -and $global:NocttyReleaseResumeFixture.Calls.Count -ne 3) { throw 'Fresh version scanned unrelated PRs.' }
        if ($case -eq 'bound-100' -and $global:NocttyReleaseResumeFixture.Calls.Count -ne 203) { throw 'The complete 100-candidate bound was not checked by paths.' }
        Write-Host "Publisher resume WinGet $case`: PASS"
    }
} finally {
    $env:WINGET_CREATE_GITHUB_TOKEN = $savedWinGetToken
    $env:GH_TOKEN = $savedToken
    Remove-Item Function:\gh,Function:\Start-Sleep
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
