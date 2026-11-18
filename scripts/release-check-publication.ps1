[CmdletBinding()]
param([Parameter(Mandatory)] [ValidatePattern('\Av[0-9]+\.[0-9]+\.[0-9]+\z')] [string] $Tag)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-publication-state.ps1')
$release = Invoke-ReleaseGhJson @('api', "repos/amanthanvi/noctty/releases/tags/$Tag")
Assert-ReleasePublicationState -Release $release -Repository amanthanvi/noctty -Tag $Tag
