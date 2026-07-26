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
$originOutput = git remote get-url origin
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to read the origin remote for production site deployment.'
}
$origin = ([string]($originOutput -join "`n")).Trim()
if ($origin -cnotin @(
    'https://github.com/amanthanvi/winghostty',
    'https://github.com/amanthanvi/winghostty.git'
)) {
    throw 'Unexpected origin remote for production site deployment.'
}
git fetch --force --no-tags origin "refs/heads/${DefaultBranch}:refs/remotes/origin/${DefaultBranch}"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to fetch exact origin/$DefaultBranch."
}
$headOutput = git rev-parse HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to resolve the checked-out deployment commit.'
}
$head = ([string]($headOutput -join "`n")).Trim()
$originHeadOutput = git rev-parse "refs/remotes/origin/$DefaultBranch"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve exact origin/$DefaultBranch."
}
$originHead = ([string]($originHeadOutput -join "`n")).Trim()
if ($head -cne $ExpectedSha -or
    $head -cne $originHead) {
    throw "Resolved deployment SHA is not the exact current origin/$DefaultBranch commit."
}
$status = @(git status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw "Failed to inspect the working tree before the $Phase deployment."
}
if ($status.Count -ne 0) {
    throw "Repository became dirty before the $Phase deployment."
}

Write-Host "Verified clean exact origin/$DefaultBranch at $ExpectedSha before $Phase."
