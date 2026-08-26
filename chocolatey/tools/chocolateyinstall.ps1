$ErrorActionPreference = 'Stop'
$packageName = 'winghostty'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Version and URLs are replaced by the release pipeline.
$url64 = 'https://github.com/amanthanvi/winghostty/releases/download/v0.0.0/winghostty-0.0.0-windows-x64-setup.exe'
$checksum64 = '0000000000000000000000000000000000000000000000000000000000000000'

$packageArgs = @{
    packageName    = $packageName
    fileType       = 'exe'
    url64bit       = $url64
    checksum64     = $checksum64
    checksumType64 = 'sha256'
    silentArgs     = '/VERYSILENT /NORESTART /SP-'
    validExitCodes = @(0)
}

Install-ChocolateyPackage @packageArgs
