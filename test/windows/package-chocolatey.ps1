[CmdletBinding()]
param(
    [string] $Version = '0.0.1',
    [string] $Architecture = $null,
    [switch] $ShowGeneratedFiles
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\windows-architecture.ps1')
$Architecture = (Get-WindowsPackageArchitecture -Architecture $(if ($Architecture) { $Architecture } else { Get-DefaultWindowsPackageArchitecture })).Name
$packageScript = Join-Path $repoRoot 'scripts\package-package-managers.ps1'
$scratchName = 'package-chocolatey-{0}' -f [guid]::NewGuid().ToString('N')
$scratchRelative = Join-Path 'dist' $scratchName
$scratchRoot = Join-Path $repoRoot $scratchRelative
$artifactRelative = Join-Path $scratchRelative 'artifacts'
$artifactRoot = Join-Path $repoRoot $artifactRelative
$outputRelative = Join-Path $scratchRelative 'output'
$outputRoot = Join-Path $repoRoot $outputRelative
$packRoot = Join-Path ([System.IO.Path]::GetTempPath()) $scratchName
# Release version used only for the multi-architecture installer-choice check below.
$dualVersion = '0.0.2'

try {
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

    $setupName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind setup
    $portableName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind portable
    $checksumsName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind checksums
    $setupPath = Join-Path $artifactRoot $setupName
    $portablePath = Join-Path $artifactRoot $portableName
    $checksumsPath = Join-Path $artifactRoot $checksumsName
    $iconPath = Join-Path $artifactRoot 'noctty-icon.svg'

    Set-Content -LiteralPath $setupPath -Value "fake signed setup for $Architecture" -NoNewline
    Set-Content -LiteralPath $portablePath -Value "fake portable archive for $Architecture" -NoNewline
    Set-Content -LiteralPath $iconPath -Value '<svg xmlns="http://www.w3.org/2000/svg" />' -NoNewline
    $setupSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLowerInvariant()
    $portableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $portablePath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $checksumsPath -Value @(
        "$setupSha256 *$setupName"
        "$portableSha256 *$portableName"
    )

    & $packageScript `
        -Version $Version `
        -Architectures @($Architecture) `
        -ArtifactRoot $artifactRelative `
        -OutputRoot $outputRelative

    $nuspecPath = Join-Path $outputRoot 'chocolatey\noctty.nuspec'
    $installScriptPath = Join-Path $outputRoot 'chocolatey\tools\chocolateyInstall.ps1'
    $metadataPath = Join-Path $outputRoot 'metadata.json'
    foreach ($path in @($nuspecPath, $installScriptPath, $metadataPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing generated Chocolatey path: $path"
        }
    }

    $nuspec = [System.Xml.XmlDocument]::new()
    $nuspec.Load($nuspecPath)
    $nuspecNamespace = 'http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd'
    if ($nuspec.DocumentElement.LocalName -cne 'package' -or $nuspec.DocumentElement.NamespaceURI -cne $nuspecNamespace) {
        throw 'Generated nuspec does not use the expected NuGet package schema shape.'
    }

    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($nuspec.NameTable)
    $namespaceManager.AddNamespace('n', $nuspecNamespace)
    $metadataNode = $nuspec.SelectSingleNode('/n:package/n:metadata', $namespaceManager)
    if ($null -eq $metadataNode) {
        throw 'Generated nuspec is missing its metadata element.'
    }

    $requiredMetadata = @(
        'id',
        'version',
        'packageSourceUrl',
        'title',
        'authors',
        'owners',
        'projectUrl',
        'projectSourceUrl',
        'docsUrl',
        'bugTrackerUrl',
        'licenseUrl',
        'iconUrl',
        'requireLicenseAcceptance',
        'summary',
        'description',
        'releaseNotes',
        'copyright',
        'tags'
    )
    foreach ($elementName in $requiredMetadata) {
        $element = $metadataNode.SelectSingleNode("n:$elementName", $namespaceManager)
        if ($null -eq $element -or [string]::IsNullOrWhiteSpace($element.InnerText)) {
            throw "Generated nuspec is missing required metadata: $elementName"
        }
    }

    if ($metadataNode.SelectSingleNode('n:id', $namespaceManager).InnerText -cne 'noctty') {
        throw 'Generated nuspec package id is not noctty.'
    }
    if ($metadataNode.SelectSingleNode('n:version', $namespaceManager).InnerText -cne $Version) {
        throw "Generated nuspec version does not match requested version $Version."
    }
    if ($metadataNode.SelectSingleNode('n:requireLicenseAcceptance', $namespaceManager).InnerText -cne 'false') {
        throw 'Generated nuspec must not require license acceptance.'
    }

    # Chocolatey package-validator rules a first submission must pass:
    # CPMR0076 (an icon from GitHub is a Requirement failure), CPMR0050 (title
    # equal to the id), CPMR0041 (project source URL equal to the project URL).
    $iconUri = [Uri] $metadataNode.SelectSingleNode('n:iconUrl', $namespaceManager).InnerText
    if ($iconUri.Host -match '(?i)(^|\.)(github\.com|githubusercontent\.com|rawgit\.com)$') {
        throw "Generated nuspec iconUrl must not be served from GitHub: $iconUri"
    }
    if ($iconUri.AbsoluteUri -ceq 'https://noctty.com/assets/favicon.svg' -and
        -not (Test-Path -LiteralPath (Join-Path $repoRoot 'site/assets/favicon.svg') -PathType Leaf)) {
        throw 'Generated nuspec iconUrl names site/assets/favicon.svg, which the site no longer ships.'
    }
    $releaseSourceUrl = "https://github.com/amanthanvi/noctty/blob/v$Version/scripts/package-package-managers.ps1"
    if ($metadataNode.SelectSingleNode('n:packageSourceUrl', $namespaceManager).InnerText -cne $releaseSourceUrl) {
        throw "Generated nuspec packageSourceUrl must name the release tag's generator: $releaseSourceUrl"
    }
    if ($metadataNode.SelectSingleNode('n:title', $namespaceManager).InnerText -ceq 'noctty') {
        throw 'Generated nuspec title must not equal the package id.'
    }
    if ($metadataNode.SelectSingleNode('n:projectSourceUrl', $namespaceManager).InnerText -ceq
        $metadataNode.SelectSingleNode('n:projectUrl', $namespaceManager).InnerText) {
        throw 'Generated nuspec projectSourceUrl must differ from projectUrl.'
    }
    $licenseCopyright = (Get-Content -LiteralPath (Join-Path $repoRoot 'LICENSE') | Where-Object { $_ -like 'Copyright*' } | Select-Object -First 1)
    if ($metadataNode.SelectSingleNode('n:copyright', $namespaceManager).InnerText -cne $licenseCopyright) {
        throw "Generated nuspec copyright must match the LICENSE: $licenseCopyright"
    }

    # The Chocolatey description is its own text, and it names only the packaged architectures.
    $description = $metadataNode.SelectSingleNode('n:description', $namespaceManager).InnerText
    if ($description -ceq $metadataNode.SelectSingleNode('n:summary', $namespaceManager).InnerText) {
        throw 'Generated nuspec description must differ from the summary.'
    }
    $architectureText = if ($Architecture -eq 'arm64') { ', on ARM64.' } else { ', on x64.' }
    if (-not $description.Contains($architectureText, [StringComparison]::Ordinal)) {
        throw "Generated nuspec description must name only the packaged architecture ($Architecture)."
    }

    $installScript = Get-Content -LiteralPath $installScriptPath -Raw
    $expectedSetupUrl = "https://github.com/amanthanvi/noctty/releases/download/v$Version/$setupName"
    foreach ($expectedText in @(
        $setupSha256,
        $expectedSetupUrl,
        "checksumType = 'sha256'",
        '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS',
        'Install-ChocolateyPackage @packageArgs'
    )) {
        if (-not $installScript.Contains($expectedText, [StringComparison]::Ordinal)) {
            throw "Generated install script is missing expected content: $expectedText"
        }
    }
    foreach ($expectedArchitecture in @('x64', 'arm64')) {
        if (-not $installScript.Contains($expectedArchitecture, [StringComparison]::Ordinal)) {
            throw "Generated install script is missing architecture selection for $expectedArchitecture."
        }
    }

    # The installer is chosen at install time from the CPU. Chocolatey runs as an emulated x64
    # process on ARM64 Windows, so OSArchitecture alone says x64 there: run the generated script
    # against a stubbed CPU query and check which installer it picks.
    # More than one architecture reads each one's artifacts from a per-architecture folder;
    # keep them under this run's scratch root so nothing outside it is written or deleted.
    $dualArtifactBaseRelative = Join-Path $scratchRelative 'dual-artifacts'
    $dualArtifactDirs = @{}
    foreach ($dualArchitecture in @('x64', 'arm64')) {
        $dualArtifactDirs[$dualArchitecture] = Join-Path $repoRoot (Join-Path $dualArtifactBaseRelative "noctty-$dualVersion-windows-$dualArchitecture")
        New-Item -ItemType Directory -Path $dualArtifactDirs[$dualArchitecture] -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $dualArtifactDirs['x64'] 'noctty-icon.svg') -Value '<svg xmlns="http://www.w3.org/2000/svg" />' -NoNewline
    $dualInstallers = @{}
    foreach ($dualArchitecture in @('x64', 'arm64')) {
        $dualSetupName = New-WindowsPackageArtifactName -Version $dualVersion -Architecture $dualArchitecture -Kind setup
        $dualPortableName = New-WindowsPackageArtifactName -Version $dualVersion -Architecture $dualArchitecture -Kind portable
        $dualSetupPath = Join-Path $dualArtifactDirs[$dualArchitecture] $dualSetupName
        $dualPortablePath = Join-Path $dualArtifactDirs[$dualArchitecture] $dualPortableName
        Set-Content -LiteralPath $dualSetupPath -Value "fake signed setup for $dualArchitecture" -NoNewline
        Set-Content -LiteralPath $dualPortablePath -Value "fake portable archive for $dualArchitecture" -NoNewline
        $dualSetupSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $dualSetupPath).Hash.ToLowerInvariant()
        $dualPortableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $dualPortablePath).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $dualArtifactDirs[$dualArchitecture] (New-WindowsPackageArtifactName -Version $dualVersion -Architecture $dualArchitecture -Kind checksums)) -Value @(
            "$dualSetupSha256 *$dualSetupName"
            "$dualPortableSha256 *$dualPortableName"
        )
        $dualInstallers[$dualArchitecture] = @{
            Url = "https://github.com/amanthanvi/noctty/releases/download/v$dualVersion/$dualSetupName"
            Checksum = $dualSetupSha256
        }
    }
    $dualOutputRelative = Join-Path $scratchRelative 'dual-output'
    & $packageScript `
        -Version $dualVersion `
        -Architectures @('x64', 'arm64') `
        -ArtifactBase $dualArtifactBaseRelative `
        -OutputRoot $dualOutputRelative | Out-Null
    $dualInstallScript = Get-Content -LiteralPath (Join-Path $repoRoot (Join-Path $dualOutputRelative 'chocolatey\tools\chocolateyInstall.ps1')) -Raw

    # A package that carries both installers says so on its Chocolatey page.
    $dualNuspec = [System.Xml.XmlDocument]::new()
    $dualNuspec.Load((Join-Path $repoRoot (Join-Path $dualOutputRelative 'chocolatey\noctty.nuspec')))
    $dualNamespaces = [System.Xml.XmlNamespaceManager]::new($dualNuspec.NameTable)
    $dualNamespaces.AddNamespace('n', $nuspecNamespace)
    $dualDescription = $dualNuspec.SelectSingleNode('/n:package/n:metadata/n:description', $dualNamespaces).InnerText
    if (-not $dualDescription.Contains(', on x64 or ARM64.', [StringComparison]::Ordinal)) {
        throw 'Generated nuspec description for the two-architecture package must say ", on x64 or ARM64.".'
    }

    # The process tree the generated script sees: this process first, then each ancestor in turn,
    # as executable paths. 'throw' makes the process query fail.
    $shellChain = @('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', 'C:\Windows\explorer.exe')
    $nocttyClsid = '{33368C6F-D328-410C-B225-26DC9F12C728}'
    $baseTime = [datetime] '2026-10-23T12:00:00'

    # What the generated script finds on the machine about noctty. By default noctty is not running,
    # so the guard has nothing to do. Registry values are the install location under HKLM and HKCU
    # and the default terminal; Embedding lists the running noctty.exe COM servers; WindowClass is the
    # class of this process's console window ($null = no console window); Created gives the start
    # time of each process in the chain (default: each ancestor an hour older than its child).
    function New-NocttyScenario {
        param([hashtable[]] $Override = @())
        $scenario = @{
            Running = $false; InstallLocation = $null; InstallLocationUser = $null; DelegationTerminal = $null
            Embedding = @(); WindowClass = $null; AddTypeFails = $false; Created = $null
        }
        foreach ($layer in $Override) { foreach ($key in $layer.Keys) { $scenario[$key] = $layer[$key] } }
        return $scenario
    }

    function Get-GeneratedInstallerChoice {
        param([string] $InstallScript, [AllowNull()] $CpuArchitecture, $ProcessChain = $shellChain, $Noctty = (New-NocttyScenario))

        $script:chosenInstaller = $null
        # Every call that installs or stops something, so a refusal can be shown to have done neither.
        $script:ops = @()
        # The generated script must never touch the host's processes or registry.
        function Get-Process {
            [CmdletBinding()]
            param([string] $Name)
            if ($Noctty.Running) { [pscustomobject] @{ Name = 'noctty' } }
        }
        function Stop-Process { $script:ops += 'Stop-Process'; throw 'The generated install script must not call Stop-Process.' }
        function Wait-Process { $script:ops += 'Wait-Process'; throw 'The generated install script must not call Wait-Process.' }
        function Get-ItemProperty {
            [CmdletBinding()]
            param([string] $Path, [string] $LiteralPath, [string[]] $Name)
            if ($Path -like 'HKLM:*winghostty_is1') {
                if ($Noctty.InstallLocation) { [pscustomobject] @{ InstallLocation = $Noctty.InstallLocation } }
            }
            elseif ($Path -like 'HKCU:*winghostty_is1') {
                if ($Noctty.InstallLocationUser) { [pscustomobject] @{ InstallLocation = $Noctty.InstallLocationUser } }
            }
            elseif ($LiteralPath -eq 'HKCU:\Console\%%Startup') {
                if ($Noctty.DelegationTerminal) { [pscustomobject] @{ DelegationTerminal = $Noctty.DelegationTerminal } }
            }
            else { throw "Unexpected registry read: $Path$LiteralPath" }
        }
        # Stands in for the console-window probe: the fake type is defined once per session and
        # takes the window class of the current scenario ($null = no console window).
        function Add-Type {
            [CmdletBinding()]
            param($Namespace, $Name, $MemberDefinition)
            if ($Noctty.AddTypeFails) { throw 'Add-Type is unavailable' }
            if (-not ('NocttyGuard.Native' -as [type])) {
                Microsoft.PowerShell.Utility\Add-Type -TypeDefinition 'namespace NocttyGuard { public static class Native { public static string WindowClass; public static System.IntPtr GetConsoleWindow() { return WindowClass == null ? System.IntPtr.Zero : new System.IntPtr(1); } public static int GetClassName(System.IntPtr window, System.Text.StringBuilder name, int maxCount) { name.Append(WindowClass); return name.Length; } } }'
            }
            [NocttyGuard.Native]::WindowClass = $Noctty.WindowClass
        }
        function Get-CimInstance {
            [CmdletBinding()]
            param([Parameter(Position = 0)] [string] $ClassName, [string] $Filter, [string[]] $Property, [int] $OperationTimeoutSec)
            if ($ClassName -eq 'Win32_Process') {
                # A hung WMI service must not hang the install, so every query needs a timeout.
                if ($OperationTimeoutSec -le 0) { $script:ops += 'Win32_Process query without -OperationTimeoutSec' }
                if ($Filter -like "Name = *") { return $Noctty.Embedding }
                if ("$ProcessChain" -eq 'throw') { throw 'process list unavailable' }
                $processId = [int] ($Filter -replace '\D', '')
                $index = if ($processId -eq $PID) { 0 } else { $processId - 1000 }
                if ($index -ge $ProcessChain.Count) { return }
                $created = if ($Noctty.Created) { $Noctty.Created[$index] } else { $baseTime.AddHours(-$index) }
                [pscustomobject] @{ ProcessId = $processId; ParentProcessId = 1001 + $index; ExecutablePath = $ProcessChain[$index]; CreationDate = $created }
                return
            }
            if ("$CpuArchitecture" -eq 'throw') { throw 'CPU query unavailable' }
            if ($null -ne $CpuArchitecture) { [pscustomobject] @{ Architecture = $CpuArchitecture } }
        }
        function Install-ChocolateyPackage {
            [CmdletBinding()]
            param($packageName, $fileType, $url, $checksum, $checksumType, $silentArgs, $validExitCodes)
            $script:ops += 'Install-ChocolateyPackage'
            $script:chosenInstaller = @{ Url = $url; Checksum = $checksum }
        }
        & ([scriptblock]::Create($InstallScript))
        return $script:chosenInstaller
    }

    $osInstaller = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $installerCases = @(
        @{ Name = 'CPU reports ARM64 (12) while the process reports x64'; Cpu = 12; Expected = 'arm64' },
        @{ Name = 'CPU reports x64 (9)'; Cpu = 9; Expected = $osInstaller },
        @{ Name = 'CPU query returns nothing'; Cpu = $null; Expected = $osInstaller },
        @{ Name = 'CPU query raises an error'; Cpu = 'throw'; Expected = $osInstaller }
    )
    foreach ($case in $installerCases) {
        $choice = Get-GeneratedInstallerChoice -InstallScript $dualInstallScript -CpuArchitecture $case.Cpu
        $want = $dualInstallers[$case.Expected]
        if ($null -eq $choice -or $choice.Url -cne $want.Url -or $choice.Checksum -cne $want.Checksum) {
            throw "Generated install script chose the wrong installer when the $($case.Name): expected $($case.Expected), got $($choice.Url)."
        }
    }

    # A package without an ARM64 installer must keep the x64 installer on an ARM64 CPU (Windows 11
    # on ARM runs it under emulation) instead of failing for the missing ARM64 one.
    if ($Architecture -eq 'x64' -and $osInstaller -eq 'x64') {
        $x64OnlyChoice = Get-GeneratedInstallerChoice -InstallScript $installScript -CpuArchitecture 12
        if ($null -eq $x64OnlyChoice -or $x64OnlyChoice.Url -cne $expectedSetupUrl -or $x64OnlyChoice.Checksum -cne $setupSha256) {
            throw "Generated x64-only install script did not keep the x64 installer on an ARM64 CPU: got $($x64OnlyChoice.Url)."
        }
    }

    # Run from inside a noctty window the upgrade must refuse before anything happens; from any
    # other terminal (including a sibling folder that merely shares the name prefix) it proceeds.
    # A refusal has to be the guard's own message: any other error fails the case.
    $nocttyDir = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) 'noctty'
    $nocttyExe = Join-Path $nocttyDir 'noctty.exe'
    $customDir = 'D:\Apps\noctty'
    $customExe = Join-Path $customDir 'noctty.exe'
    $insideMessage = '*cannot be upgraded from one of its own windows*'
    $unreadableMessage = '*the process list could not be read*'
    $comServer = [pscustomobject] @{ ExecutablePath = $nocttyExe; CommandLine = "`"$nocttyExe`" -Embedding" }
    $strayServer = [pscustomobject] @{ ExecutablePath = Join-Path "$nocttyDir-portable" 'noctty.exe'; CommandLine = '"noctty.exe" -Embedding' }
    # COM appends -Embedding to every server it starts, the toast activator included.
    $toastServer = [pscustomobject] @{ ExecutablePath = $nocttyExe; CommandLine = "`"$nocttyExe`" -ToastActivated -Embedding" }
    $plainInstance = [pscustomobject] @{ ExecutablePath = $nocttyExe; CommandLine = "`"$nocttyExe`"" }
    $ownWindow = @($shellChain[0], $nocttyExe, $shellChain[1])
    # The default-terminal handoff: noctty is the default terminal, its COM server runs, and this
    # console is a pseudo console. Each case below removes one of those conditions.
    $handoff = @{ Running = $true; DelegationTerminal = $nocttyClsid; Embedding = @($comServer); WindowClass = 'PseudoConsoleWindow' }
    $guardCases = @(
        @{ Name = 'noctty is not running (nothing to close, so no process query, even if it would fail)'; Chain = 'throw'; Noctty = @{}; Message = $null },
        @{ Name = 'noctty.exe is an ancestor'; Chain = $ownWindow; Noctty = @{ Running = $true }; Message = $insideMessage },
        @{ Name = 'the process list cannot be read while noctty runs'; Chain = 'throw'; Noctty = @{ Running = $true }; Message = $unreadableMessage },
        @{ Name = 'a sibling folder shares the name prefix'; Chain = @($shellChain[0], (Join-Path "$nocttyDir-portable" 'noctty.exe')); Noctty = @{ Running = $true }; Message = $null },
        @{ Name = 'an ordinary terminal runs it'; Chain = $shellChain; Noctty = @{ Running = $true }; Message = $null },
        @{ Name = 'noctty is installed in a custom directory (machine-wide)'; Chain = @($shellChain[0], $customExe, $shellChain[1]); Noctty = @{ Running = $true; InstallLocation = "$customDir\" }; Message = $insideMessage },
        @{ Name = 'noctty is installed in a custom directory (this user only)'; Chain = @($shellChain[0], $customExe, $shellChain[1]); Noctty = @{ Running = $true; InstallLocationUser = $customDir }; Message = $insideMessage },
        @{ Name = 'the registered install is elsewhere than the default directory'; Chain = $ownWindow; Noctty = @{ Running = $true; InstallLocation = $customDir }; Message = $null },
        @{ Name = 'the machine-wide install location wins over the user one'; Chain = @($shellChain[0], 'E:\Other\noctty\noctty.exe', $shellChain[1]); Noctty = @{ Running = $true; InstallLocation = $customDir; InstallLocationUser = 'E:\Other\noctty' }; Message = $null },
        @{ Name = 'a parent process ID has been reused by a newer process'; Chain = $ownWindow; Noctty = @{ Running = $true; Created = @($baseTime, $baseTime.AddHours(1), $baseTime.AddHours(-2)) }; Message = $null },
        @{ Name = 'a parent started at the same moment as its child'; Chain = $ownWindow; Noctty = @{ Running = $true; Created = @($baseTime, $baseTime, $baseTime.AddHours(-2)) }; Message = $null },
        @{ Name = 'noctty hosts the console as the default terminal'; Chain = $shellChain; Noctty = $handoff; Message = $insideMessage },
        @{ Name = 'another application is the default terminal'; Chain = $shellChain; Noctty = @($handoff, @{ DelegationTerminal = '{00000000-0000-0000-0000-000000000000}' }); Message = $null },
        @{ Name = 'no default terminal is set'; Chain = $shellChain; Noctty = @($handoff, @{ DelegationTerminal = $null }); Message = $null },
        @{ Name = 'the noctty COM server is not running'; Chain = $shellChain; Noctty = @($handoff, @{ Embedding = @() }); Message = $null },
        @{ Name = 'the COM server running is a copy outside the install directory'; Chain = $shellChain; Noctty = @($handoff, @{ Embedding = @($strayServer) }); Message = $null },
        @{ Name = 'the process in the install directory is the toast activator, not a handoff server'; Chain = $shellChain; Noctty = @($handoff, @{ Embedding = @($toastServer) }); Message = $null },
        @{ Name = 'the process in the install directory was not started by COM'; Chain = $shellChain; Noctty = @($handoff, @{ Embedding = @($plainInstance) }); Message = $null },
        @{ Name = 'this is an ordinary console window'; Chain = $shellChain; Noctty = @($handoff, @{ WindowClass = 'ConsoleWindowClass' }); Message = $null },
        @{ Name = 'this process has no console window'; Chain = $shellChain; Noctty = @($handoff, @{ WindowClass = $null }); Message = $null },
        @{ Name = 'the console-window probe cannot run'; Chain = $shellChain; Noctty = @($handoff, @{ AddTypeFails = $true }); Message = $null }
    )
    foreach ($case in $guardCases) {
        $message = $null
        $choice = $null
        try {
            $choice = Get-GeneratedInstallerChoice -InstallScript $dualInstallScript -CpuArchitecture 9 -ProcessChain $case.Chain -Noctty (New-NocttyScenario @($case.Noctty))
        }
        catch {
            $message = $_.Exception.Message
        }
        if ($case.Message) {
            if ($null -eq $message -or $message -notlike $case.Message) {
                throw "Generated install script did not refuse as expected when $($case.Name): wanted '$($case.Message)', got '$message'."
            }
            if ($script:ops.Count -ne 0 -or $null -ne $script:chosenInstaller) {
                throw "Generated install script did something before refusing when $($case.Name): $($script:ops -join ', ')."
            }
        }
        else {
            if ($null -ne $message) {
                throw "Generated install script failed when $($case.Name): $message"
            }
            if ($null -eq $choice) {
                throw "Generated install script did not reach the installer when $($case.Name)."
            }
            # Proceeding means installing and nothing else: no stopped process, no untimed query.
            if (($script:ops -join ',') -cne 'Install-ChocolateyPackage') {
                throw "Generated install script did more than install when $($case.Name): $($script:ops -join ', ')."
            }
        }
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($metadata.chocolatey.packageName -cne 'noctty' -or
        $metadata.chocolatey.nuspecPath -cne $nuspecPath -or
        $metadata.chocolatey.packageDirectory -cne (Split-Path -Parent $nuspecPath)) {
        throw 'metadata.json has an invalid Chocolatey block.'
    }

    $uninstallScriptPath = Join-Path $outputRoot 'chocolatey\tools\chocolateyUninstall.ps1'
    if (Test-Path -LiteralPath $uninstallScriptPath) {
        throw 'The Inno package should rely on Chocolatey auto-uninstall, not ship an uninstall script.'
    }

    if ($ShowGeneratedFiles) {
        Write-Host '--- generated noctty.nuspec ---'
        Get-Content -LiteralPath $nuspecPath
        Write-Host '--- generated chocolateyInstall.ps1 ---'
        Get-Content -LiteralPath $installScriptPath
    }

    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($null -eq $choco) {
        Write-Host 'Skipping choco pack: choco is not on PATH.'
    }
    else {
        New-Item -ItemType Directory -Path $packRoot -Force | Out-Null
        & $choco.Source pack $nuspecPath "--output-directory=$packRoot" --limit-output
        if ($LASTEXITCODE -ne 0) {
            throw "choco pack failed with exit code $LASTEXITCODE."
        }

        $packages = @(Get-ChildItem -LiteralPath $packRoot -Filter '*.nupkg' -File)
        if ($packages.Count -ne 1) {
            throw "Expected one .nupkg from choco pack; found $($packages.Count)."
        }
        Write-Host "choco pack produced: $($packages[0].FullName)"
    }

    # A moderation fix repacks a published version with a newer generator, and
    # the package must then name that generator's commit, not the release tag.
    $resubmitOutputRelative = Join-Path $scratchRelative 'resubmit'
    & $packageScript `
        -Version $Version `
        -Architectures @($Architecture) `
        -ArtifactRoot $artifactRelative `
        -OutputRoot $resubmitOutputRelative `
        -PackageSourceRef '0123456789abcdef0123456789abcdef01234567' | Out-Null
    $resubmitNuspec = [System.Xml.XmlDocument]::new()
    $resubmitNuspec.Load((Join-Path $repoRoot (Join-Path $resubmitOutputRelative 'chocolatey\noctty.nuspec')))
    $resubmitNamespaces = [System.Xml.XmlNamespaceManager]::new($resubmitNuspec.NameTable)
    $resubmitNamespaces.AddNamespace('n', $nuspecNamespace)
    $resubmitSourceUrl = $resubmitNuspec.SelectSingleNode('/n:package/n:metadata/n:packageSourceUrl', $resubmitNamespaces).InnerText
    if ($resubmitSourceUrl -cne 'https://github.com/amanthanvi/noctty/blob/0123456789abcdef0123456789abcdef01234567/scripts/package-package-managers.ps1') {
        throw "A repacked nuspec must name the generator commit it was built with, got: $resubmitSourceUrl"
    }
    if ($resubmitNuspec.SelectSingleNode('/n:package/n:metadata/n:releaseNotes', $resubmitNamespaces).InnerText -cne
        "https://github.com/amanthanvi/noctty/releases/tag/v$Version") {
        throw 'A repacked nuspec must keep pointing at the original release.'
    }

    # The scripts behind the manual Chocolatey Publish workflow (the publish
    # script is also the Release step's), against fake tools and a loopback feed.
    & (Join-Path $PSScriptRoot 'release-stage-published.ps1')
    & (Join-Path $PSScriptRoot 'release-publish-chocolatey.ps1')

    Write-Host "Chocolatey package validation: PASS (version=$Version, architecture=$Architecture)"
    $global:LASTEXITCODE = 0
}
finally {
    if (Test-Path -LiteralPath $packRoot) {
        Remove-Item -LiteralPath $packRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}
