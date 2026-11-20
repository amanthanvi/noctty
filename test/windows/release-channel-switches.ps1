[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts/release-package-manager-preflight.ps1')
$releaseMeta=Get-Content (Join-Path $repoRoot 'dist/windows/release-metadata.json') -Raw | ConvertFrom-Json
$line=[version]$releaseMeta.upstreamBaseVersion
$fixtureVersion="$($line.Major).$($line.Minor).$($releaseMeta.firstForkPatch)"
$saved=@{}
foreach($name in @('SCOOP_PUBLISH','WINGET_PUBLISH','CHOCOLATEY_PUBLISH','SCOOP_BUCKET_TOKEN','SCOOP_BUCKET_REPO','WINGETCREATE_TOKEN','WINGET_CREATE_GITHUB_TOKEN','WINGET_PACKAGE_IDENTIFIER','CHOCO_API_KEY')) {
    $saved[$name]=[Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name,$null)
}
function gh { throw 'Channel switches fixture must not contact GitHub.' }
function Invoke-WebRequest { throw 'Channel switches fixture must not contact a feed.' }
try {
    foreach($setting in @('off','Off','OFF','oFf')) {
        foreach($channel in @('SCOOP','WINGET','CHOCOLATEY')) {
            [Environment]::SetEnvironmentVariable($channel+'_PUBLISH',$setting)
            if(Test-ReleasePublisherEnabled $channel) { throw 'Channel switch case comparison differs.' }
        }
        $output=@(& (Join-Path $repoRoot 'scripts/release-preflight.ps1') -Version $fixtureVersion -RequirePackageManagers 6>&1)
        if(@($output|Where-Object {[string]$_ -ceq 'Release preflight passed.'}).Count -ne 1) { throw 'Build preflight ignored disabled channels.' }
        foreach($script in @('release-publish-scoop.ps1','release-submit-winget.ps1','release-publish-chocolatey.ps1')) {
            $output=@(& (Join-Path $repoRoot "scripts/$script") -Version $fixtureVersion 6>&1)
            if(($output -join ' ') -notmatch 'explicitly disabled') { throw 'Direct publisher ignored its off switch.' }
        }
    }
    $env:WINGET_PUBLISH=''
    $message=$null
    try { & (Join-Path $repoRoot 'scripts/release-preflight.ps1') -Version $fixtureVersion -RequirePackageManagers *> $null } catch { $message=$_.Exception.Message }
    if($message -notmatch 'WINGET_PACKAGE_IDENTIFIER') { throw 'Enabled unconfigured channel passed build preflight.' }
    Write-Host 'Release channel switches: PASS (4 case variants and enabled-missing twin).'
} finally {
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    Remove-Item Function:\gh,Function:\Invoke-WebRequest
    $global:LASTEXITCODE=0
}
