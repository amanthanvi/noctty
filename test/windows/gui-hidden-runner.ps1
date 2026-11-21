#requires -Version 7.0
<#
.SYNOPSIS
The hidden-desktop GUI suite's runner (interactive offload PR 1). Skeleton: the full runner lands in this PR.
#>
[CmdletBinding()]
param(
    [string] $MeasureRepo,
    [string] $Work,
    [string] $Out,
    [switch] $Build,
    [string[]] $Leaves = @(),
    [switch] $KeepFailedCopies
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-state-guard.ps1')

throw 'gui-hidden-runner.ps1 is a skeleton in this commit.'
