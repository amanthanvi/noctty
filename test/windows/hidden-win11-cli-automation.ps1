#requires -Version 7.0
<#
.SYNOPSIS
Exercise the SSH cache CLI and quick-terminal instance selection on a private desktop.
.DESCRIPTION
Supply a clean checkout with a completed measurement build and a new run directory.
The SSH fixture never connects to a host. The toggle fixture owns both IPC servers.
#>
[CmdletBinding()]
param(
    [string] $MeasureRepo,
    [Parameter(Mandatory)] [string] $Run,
    [ValidateSet('ssh-cache', 'quick-terminal')] [string] $Check,
    [string] $Bin,
    [string] $DesktopName,
    [switch] $Driver
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
$desktopPrefix = 'noctty-cli-live-'
if (-not $Check) { throw 'Select -Check ssh-cache or quick-terminal.' }
if (-not $Driver) {
    . (Join-Path $PSScriptRoot '..\..\scripts\interactive-win11-measure-lib.ps1')
    $exe = Get-InteractiveWin11MeasureExePath -RepoRoot $MeasureRepo
    Assert-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo -ExePath $exe
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin (Split-Path -Parent $exe) -Run $Run `
        -DesktopPrefix $desktopPrefix -TimeoutSeconds 150 -Label $Check -PassDesktopName -GuardClipboard -OmitIcon `
        -DriverArguments @('-Check', $Check)
    exit
}

Assert-LocalHiddenFixture $Bin $Run $DesktopName $desktopPrefix
# cmd is only a capture shell for the CLI. Fixed arguments and these literal paths
# are its entire input. /D comes before /C, so the user's AutoRun is never reached.
if ($Run -match '[\x00-\x1f"%!^&|<>]') { throw 'Unsupported cmd metacharacter in run path.' }
$cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
$desktop = "WinSta0\$DesktopName"
$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
$env:XDG_STATE_HOME = $env:LOCALAPPDATA
$env:XDG_CONFIG_HOME = $env:LOCALAPPDATA
$env:XDG_CACHE_HOME = $env:LOCALAPPDATA
$env:USERPROFILE = $Run
$env:HOME = $Run
$script:checks = [Collections.Generic.List[object]]::new()

function Invoke-FixtureCli([string] $Name, [string] $Arguments) {
    $stdout = Join-Path $Run "$Name.stdout.txt"
    $stderr = Join-Path $Run "$Name.stderr.txt"
    $cli = Join-Path $Bin 'noctty.com'
    $line = '"{0}" /d /s /c ""{1}" {2} >"{3}" 2>"{4}""' -f $cmd, $cli, $Arguments, $stdout, $stderr
    $pi = [HiddenLocal]::Spawn($cmd, $line, $Bin, $desktop)
    try {
        [uint32] $code = 0
        if ([HiddenLocal]::WaitForSingleObject($pi.process, 15000) -ne 0 -or
            -not [HiddenLocal]::GetExitCodeProcess($pi.process, [ref]$code)) {
            throw 'CLI exit was not observed. The outer job owns cleanup.'
        }
        return @{ Exit = $code; Out = [IO.File]::ReadAllText($stdout); Err = [IO.File]::ReadAllText($stderr) }
    } finally {
        [void] [HiddenLocal]::CloseHandle($pi.thread)
        [void] [HiddenLocal]::CloseHandle($pi.process)
    }
}

function Test-SshCache {
    $destination = 'fixture@cache.invalid'
    $cache = Join-Path $Bin 'ssh_cache'
    if (Test-Path -LiteralPath $cache) { throw 'The cache fixture must start empty.' }
    $miss = Invoke-FixtureCli 'miss' "+ssh-cache $destination"
    Check 'positional miss is silent' ($miss.Exit -eq 1 -and -not $miss.Out -and -not $miss.Err) 1 `
        @{ Exit = $miss.Exit; OutChars = $miss.Out.Length; ErrChars = $miss.Err.Length }
    $add = Invoke-FixtureCli 'add' "+ssh-cache --add=$destination"
    Check 'add writes to the portable cache' ($add.Exit -eq 0 -and (Test-Path -LiteralPath $cache -PathType Leaf)) 0 $add.Exit
    $hit = Invoke-FixtureCli 'hit' "+ssh-cache $destination"
    $matchesDestination = $hit.Out -cmatch ('\A' + [regex]::Escape($destination) + '[ \t]+\S[^\r\n]*\r?\n\z')
    Check 'positional hit prints the saved destination' ($hit.Exit -eq 0 -and $matchesDestination -and -not $hit.Err) 0 `
        @{ Exit = $hit.Exit; DestinationMatched = $matchesDestination; ErrChars = $hit.Err.Length }
}

function Start-FixtureInstance([string] $Label, [string] $Class) {
    $copy = Join-Path $Run "$Label\bin"
    [void] [IO.Directory]::CreateDirectory((Split-Path -Parent $copy))
    Copy-Portable $Bin $copy -OmitIcon
    @(
        "command = direct:$cmd /D", "working-directory = $Run", 'shell-integration = none', 'clipboard-read = deny',
        'clipboard-write = deny', 'copy-on-select = false', 'confirm-close-surface = false',
        'auto-update = off', 'desktop-notifications = false', 'quick-terminal-autohide = false',
        'quick-terminal-animation-duration = 0'
    ) | Set-Content -LiteralPath (Join-Path $copy 'config.ghostty')
    $exe = Join-Path $copy 'noctty.exe'
    # SW_SHOWNOACTIVATE gives the normal host a visible baseline on its own,
    # never-switched desktop. The generic driver's SW_HIDE has no such oracle.
    return [HiddenLocal]::Spawn($exe, ('"{0}" --single-instance=true --class={1} --window-save-state=never' -f $exe, $Class), $copy, $desktop, 4)
}

function Get-VisibleHosts($Instance) {
    if ([HiddenLocal]::WaitForSingleObject($Instance.process, 0) -ne 258) { throw 'The fixture instance stopped.' }
    foreach ($hostWindow in [HiddenLocal]::Hosts($Instance.pid)) {
        if ([HiddenLocal]::WindowDesktop($hostWindow) -cne $DesktopName) { throw 'Unexpected host desktop.' }
        if ([HiddenLocal]::IsWindowVisible($hostWindow)) { $hostWindow }
    }
}

function Test-ToggleClass {
    $token = [guid]::NewGuid().ToString('N')
    $classA = "noctty-live-a-$token"
    $classB = "noctty-live-b-$token"
    $instanceA = $null
    $instanceB = $null
    try {
        $instanceA = Start-FixtureInstance 'a' $classA
        $instanceB = Start-FixtureInstance 'b' $classB
        if (-not (Wait-Until { @(Get-VisibleHosts $instanceA).Count -eq 1 -and @(Get-VisibleHosts $instanceB).Count -eq 1 } 30)) {
            throw 'Both instances must start with one visible normal host.'
        }
        $mainA = @(Get-VisibleHosts $instanceA)[0]
        $mainB = @(Get-VisibleHosts $instanceB)[0]
        foreach ($target in @('a', 'hide-a', 'b')) {
            $class = if ($target -eq 'b') { $classB } else { $classA }
            $result = Invoke-FixtureCli $target "+toggle-quick-terminal --class=$class"
            $expectedA = [int] ($target -eq 'a')
            $expectedB = [int] ($target -eq 'b')
            $landed = $result.Exit -eq 0 -and (Wait-Until {
                $a = @(Get-VisibleHosts $instanceA)
                $b = @(Get-VisibleHosts $instanceB)
                $a -contains $mainA -and $b -contains $mainB -and
                    $a.Count -eq (1 + $expectedA) -and $b.Count -eq (1 + $expectedB)
            } 10)
            $actualA = @(Get-VisibleHosts $instanceA | Where-Object { $_ -ne $mainA }).Count
            $actualB = @(Get-VisibleHosts $instanceB | Where-Object { $_ -ne $mainB }).Count
            Check "toggle $target selects only its class" ($landed -and $actualA -eq $expectedA -and $actualB -eq $expectedB) `
                @{ A = $expectedA; B = $expectedB } @{ Exit = $result.Exit; A = $actualA; B = $actualB }
        }
    } finally {
        # Each handle pins its process through the last PID observation.
        # The outer driver stops the owned job and verifies that it is empty.
        foreach ($instance in @($instanceA, $instanceB)) {
            if ($null -eq $instance) { continue }
            [void] [HiddenLocal]::CloseHandle($instance.thread)
            [void] [HiddenLocal]::CloseHandle($instance.process)
        }
    }
}

$failure = $null
try {
    if ($Check -eq 'ssh-cache') { Test-SshCache } else { Test-ToggleClass }
} catch {
    $failure = @{ Type = $_.Exception.GetType().Name; Line = $_.InvocationInfo.ScriptLineNumber }
}
$passed = $null -eq $failure -and @($script:checks | Where-Object { -not $_.Passed }).Count -eq 0
@{ Check = $Check; Passed = $passed; Checks = $script:checks.ToArray(); Failure = $failure } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Run 'checks.json')
if (-not $passed) { exit 1 }
