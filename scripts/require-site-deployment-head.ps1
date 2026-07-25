#requires -Version 7.3

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSha,

    [Parameter(Mandatory)]
    [ValidatePattern('^main$')]
    [string] $DefaultBranch,

    [Parameter(Mandatory)]
    [ValidateSet('canary', 'production')]
    [string] $Phase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:GITHUB_REPOSITORY -cne 'amanthanvi/winghostty') {
    throw 'Site deployment is restricted to amanthanvi/winghostty.'
}
$origin = (git remote get-url origin).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -cnotin @(
    'https://github.com/amanthanvi/winghostty',
    'https://github.com/amanthanvi/winghostty.git'
)) {
    throw 'Unexpected origin remote for production site deployment.'
}
git fetch --force --no-tags origin "refs/heads/${DefaultBranch}:refs/remotes/origin/${DefaultBranch}"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to fetch exact origin/$DefaultBranch."
}
$head = (git rev-parse HEAD).Trim()
$originHead = (git rev-parse "refs/remotes/origin/$DefaultBranch").Trim()
if ($LASTEXITCODE -ne 0 -or
    $head -cne $ExpectedSha -or
    $head -cne $originHead) {
    throw "Resolved deployment SHA is not the exact current origin/$DefaultBranch commit."
}
if (git status --porcelain=v1 --untracked-files=all) {
    throw "Repository became dirty before the $Phase deployment."
}

Write-Host "Verified clean exact origin/$DefaultBranch at $ExpectedSha before $Phase."
