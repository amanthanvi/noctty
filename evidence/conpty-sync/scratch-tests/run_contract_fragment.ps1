#requires -Version 7.3
param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $Fragment, [string] $HarnessOverride)
# Scratch: run one verification-contract fragment through the real helpers.
$ErrorActionPreference = 'Stop'
$contractsRoot = Join-Path $RepoRoot 'test\windows\flagship\contracts'
. (Join-Path $contractsRoot 'ContractHelpers.ps1')
Initialize-ContractFailureCollection
$repoRoot = $RepoRoot
$script:CurrentContractFragment = Split-Path -Leaf $Fragment
if ($HarnessOverride) {
    # Stage a copy of the repo layout the fragment reads, with another harness in place.
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('frag-' + [guid]::NewGuid().ToString('N'))
    foreach ($rel in 'test\windows', '.github\workflows') { [void](New-Item -ItemType Directory -Path (Join-Path $stage $rel) -Force) }
    Copy-Item -LiteralPath $HarnessOverride -Destination (Join-Path $stage 'test\windows\interactive-win11-conpty-sync.ps1')
    Copy-Item -LiteralPath (Join-Path $RepoRoot '.github\workflows\conpty-sync.yml') -Destination (Join-Path $stage '.github\workflows\conpty-sync.yml')
    $repoRoot = $stage
}
try { . $Fragment }
catch { Add-ContractFailure -Description $_.Exception.Message -SourceFragment $script:CurrentContractFragment -Detail '' }
if ($script:ContractFailures.Count -gt 0) {
    foreach ($f in $script:ContractFailures) { "CONTRACT FAILURE [$($f.SourceFragment)] $($f.Description)" }
    exit 1
}
"fragment OK"
