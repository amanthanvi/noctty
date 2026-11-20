[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts/release-run-generator.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('release-generator-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$saved=@{}
foreach($name in @('GH_TOKEN','GITHUB_TOKEN','NOCTTY_GENERATOR_SECRET')) {$saved[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,'parent-secret-sentinel')}
$generatorScopeSentinel='parent-only'
$previousWhatIf=$WhatIfPreference
try {
    $probe=Join-Path $root 'probe.ps1'
    [IO.File]::WriteAllText($probe, @'
param([string]$OutputPath,[string[]]$Architectures,[int]$FirstForkPatch)
foreach($name in @('GH_TOKEN','GITHUB_TOKEN','NOCTTY_GENERATOR_SECRET')) { if([Environment]::GetEnvironmentVariable($name)){throw 'EnvironmentLeak'} }
if(Get-Variable generatorScopeSentinel -ErrorAction Ignore){throw 'ScopeLeak'}
if($WhatIfPreference -or -not $env:SystemRoot -or $Architectures.Count -ne 2 -or $FirstForkPatch -ne 100){throw 'GeneratorRuntimeInvalid'}
[IO.File]::WriteAllText($OutputPath,'isolated')
'@)
    $WhatIfPreference=$true
    Invoke-ReleaseGenerator -Generator $probe -Parameters @{OutputPath=(Join-Path $root 'result.txt');Architectures=@('x64','arm64');FirstForkPatch=100}
    $WhatIfPreference=$previousWhatIf
    if([IO.File]::ReadAllText((Join-Path $root 'result.txt')) -cne 'isolated'){throw 'Generator did not execute under outer WhatIf.'}
    [IO.File]::WriteAllText($probe, @'
for($i=0;$i -lt 20;$i++){[Console]::Error.WriteLine("discarded-line-$i")}
Write-Error 'probe failure ghp_synthetic_token_for_redaction'
'@)
    $message=$null
    try {Invoke-ReleaseGenerator -Generator $probe -Parameters @{}}catch{$message=$_.Exception.Message}
    if(-not $message -or $message -notmatch 'probe failure' -or $message -notmatch '\[REDACTED\]' -or $message -match 'ghp_|parent-secret-sentinel|discarded-line-0\b' -or $message.Length -gt 2200){throw 'Generator stderr tail was missing, unbounded or unsanitized.'}
    if ($message -match 'CLIXML|<Objs\b|_x00(?:1B|0D|0A)_' -or $message -notmatch '(?m)^[^\r\n]*probe failure \[REDACTED\][ \t]*$' -or ($message -split '\r?\n').Count -gt 8) {
        throw 'Generator stderr tail was not rendered as bounded plain text.'
    }
    Write-Host 'Generator isolation: PASS (allowlist, parent scope, outer WhatIf, typed parameters, bounded redacted failure reason).'
} finally {
    $WhatIfPreference=$previousWhatIf
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    if([IO.Path]::GetDirectoryName($root) -eq [IO.Path]::GetTempPath().TrimEnd('\','/') -and [IO.Path]::GetFileName($root) -cmatch '\Arelease-generator-[0-9a-f]{32}\z'){Remove-Item -LiteralPath $root -Recurse -Force -WhatIf:$false}
    $global:LASTEXITCODE=0
}
