[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$names=@('GITHUB_OUTPUT','GH_TOKEN','WINGET_CREATE_GITHUB_TOKEN','CHOCO_API_KEY','SCOOP_PUBLISH','WINGET_PUBLISH','CHOCOLATEY_PUBLISH')
$saved=@{}
foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$output=Join-Path ([IO.Path]::GetTempPath()) ('publisher-outcomes-'+[guid]::NewGuid().ToString('N')+'.txt')
try {
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$null)}
    $env:GITHUB_OUTPUT=$output
    foreach($script in @('release-publish-scoop.ps1','release-submit-winget.ps1','release-publish-chocolatey.ps1')) {
        [IO.File]::WriteAllText($output,'')
        $global:LASTEXITCODE=73
        & (Join-Path $root "scripts/$script") -Version 1.3.136
        if (([IO.File]::ReadAllText($output).Trim()) -cne 'outcome=skipped-unconfigured' -or $LASTEXITCODE -ne 0) { throw 'Missing credentials must report an incomplete outcome and a clean script exit.' }
    }
    Write-Host 'Publisher outcomes: PASS (3 missing-credential paths).'
} finally {
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    if(Test-Path -LiteralPath $output){Remove-Item -LiteralPath $output}
    $global:LASTEXITCODE=0
}
