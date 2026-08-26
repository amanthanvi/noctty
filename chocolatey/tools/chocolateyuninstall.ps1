$ErrorActionPreference = 'Stop'
$packageArgs = @{
    packageName    = 'winghostty'
    fileType       = 'exe'
    silentArgs     = '/VERYSILENT /NORESTART /SP-'
    validExitCodes = @(0)
}
Uninstall-ChocolateyPackage @packageArgs
