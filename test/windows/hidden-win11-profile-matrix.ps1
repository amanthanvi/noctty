#requires -Version 7.0
<#
Profile matrix (PKG-76, G032): launches each shell profile noctty detects through a restored session
on a hidden desktop and checks what the profile really started, with no hook into the terminal core:

  * the spawn command line, read from the process tree under noctty (reduced to a redacted shape);
  * that automatic shell integration was injected (the PowerShell script on the command line);
  * the working directory the shell reports back with OSC 7, read from the session-state.json noctty
    saves when its window closes (a pane's last-known directory is seeded from the launch directory
    and refreshed by OSC 7, see automation.md);
  * that the profile key and directory round trip through that file.

cmd and Git Bash are also sent `pushd` / `cd` as posted keys, so the directory the file ends up with
can only have come from the shell. PowerShell panes are never typed into: a pwsh in a test pane
loads PSReadLine. The run-owned integration copy sets a run-local history path and SaveNothing
before the first read, and the harness checks the real history's fingerprint without reading it.
Their directory is checked from the first prompt alone, by seeding the session with a path that has
a trailing separator, which a shell reporting its own directory does not.

A control case runs cmd.exe with `shell-integration = none` and expects the seed to survive, so the
directory checks above cannot pass by accident. No interactive WSL/SSH profile is launched;
startup discovery may probe WSL. A profile that is not installed is reported as skipped, never as a pass.

Run with -Bin <directory holding noctty.exe, conpty.dll, OpenConsole.exe> -Run <new evidence
directory>. The binary must carry the measurement AUMID unless -AllowProductAumid is given (an
ephemeral CI runner). Exit 1 when a check fails. It never uses SendInput, takes the foreground or
copies anything; the clipboard sequence number is logged before and after.
Launches currently require an ephemeral GitHub-hosted runner. Metadata receipts check every
observed job thread's desktop, including shell/discovery and ConPTY host processes; they do not
prove placement of short-lived processes between samples or arbitrary external brokers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [switch] $AllowProductAumid,
    # CI knows all four profiles are installed; missing detection must fail rather than skip.
    [switch] $RequireAll,
    [string[]] $Profile = @('cmd.exe', 'powershell.exe', 'pwsh.exe', 'git-bash'),
    # A machine without an OpenGL 4.3 driver (a hosted runner, a VM) needs `d3d11-warp` to open a window.
    [string] $Renderer = '',
    [ValidateRange(30, 1800)] [int] $DriverTimeoutSeconds = 420
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-lib.ps1')
Assert-HiddenRunner

if (-not $Driver) {
    Assert-MeasureAumid (Join-Path (Resolve-Path -LiteralPath $Bin).Path 'noctty.exe') -AllowProductAumid:$AllowProductAumid
    $extra = @('-Profile', ($Profile -join ','))
    if ($Renderer) { $extra += @('-Renderer', $Renderer) }
    if ($AllowProductAumid) { $extra += '-AllowProductAumid' }
    if ($RequireAll) { $extra += '-RequireAll' }
    Invoke-HiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds -ExtraArguments $extra -Label 'Hidden profile matrix'
    exit
}

# The driver and noctty share the inherited desktop handle. Observe their job
# threads as well: ConPTY's explicit handle list does not propagate that handle.
$Profile = @($Profile | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$desktopName = [HiddenWin]::CurrentDesktopName()
if (-not $desktopName.StartsWith('noctty-hw-')) { throw "Driver is not on its own desktop (found '$desktopName')." }
$sentinel = [HiddenWin]::CreateDriverSentinel()
$driverFailure = $null; $job = [IntPtr]::Zero; $driverApproved = $false
try {
Wait-HiddenDriverApproval -Run $Run -DesktopName $desktopName
$driverApproved = $true
$job = [HiddenWin]::CreateOwnedJob()
$desktopReceipt = Join-Path $Run 'profile-desktops.jsonl'
$checks = [Collections.Generic.List[object]]::new()
$cases = [Collections.Generic.List[object]]::new()
function Check([string] $Case, [string] $Name, [bool] $Passed, $Expected, $Actual) {
    $checks.Add(@{ Case = $Case; Name = $Name; Passed = $Passed; Expected = $Expected; Actual = $Actual })
}
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)

# Mirror windows_shell.lookupGitBash: PATH git's install, HKCU/HKLM install roots, then a
# non-WSL PATH bash. Never execute a candidate or probe a network/device PATH component.
function Test-LocalShellFile([string] $Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { return $false }
    try {
        if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path)).DriveType -eq [IO.DriveType]::Network) { return $false }
        return Test-Path -LiteralPath $Path -PathType Leaf
    } catch { return $false }
}

function Find-LocalShellOnPath([string] $Name) {
    foreach ($entry in ($env:PATH -split ';')) {
        $dir = $entry.Trim().Trim('"')
        if ($dir -notmatch '^[A-Za-z]:[\\/]') { continue }
        try { $candidate = Join-Path $dir $Name } catch { continue }
        if (Test-LocalShellFile $candidate) { return $candidate }
    }
    return $null
}

function Get-GitInstallRoot([Microsoft.Win32.RegistryHive] $Hive) {
    $base = $null; $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Default)
        $key = $base.OpenSubKey('SOFTWARE\GitForWindows', $false)
        if ($key -and $key.GetValueKind('InstallPath') -eq [Microsoft.Win32.RegistryValueKind]::String) {
            return [string]$key.GetValue('InstallPath')
        }
    } catch { return $null }
    finally { if ($key) { $key.Dispose() }; if ($base) { $base.Dispose() } }
    return $null
}

function Get-AvailableGitBash {
    $git = Find-LocalShellOnPath 'git.exe'
    if ($git) {
        $dir = Split-Path -Parent $git
        $leaf = Split-Path -Leaf $dir
        $root = Split-Path -Parent $dir
        if ($leaf -ieq 'bin') {
            $environment = Split-Path -Leaf $root
            if ($environment -match '^(?i:mingw.*|ucrt64|clang64|clangarm64)$') { $root = Split-Path -Parent $root }
        }
        if ($leaf -iin @('cmd', 'bin')) {
            $candidate = Join-Path $root 'bin\bash.exe'
            if (Test-LocalShellFile $candidate) { return $candidate }
        }
    }
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
        $root = Get-GitInstallRoot $hive
        if ($root -match '^[A-Za-z]:[\\/]') {
            try { $candidate = Join-Path $root 'bin\bash.exe' } catch { continue }
            if (Test-LocalShellFile $candidate) { return $candidate }
        }
    }
    $bash = Find-LocalShellOnPath 'bash.exe'
    if (-not $bash) { return $null }
    $normalized = $bash.Replace('/', '\')
    $systemRoot = if ($env:SystemRoot) { $env:SystemRoot.Replace('/', '\').TrimEnd('\') } else { 'C:\Windows' }
    if ($normalized.StartsWith($systemRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        ($normalized -split '\\') -icontains 'WindowsApps') { return $null }
    return $bash
}

function Test-Available([string] $Key) {
    switch ($Key) {
        'cmd.exe' { return [bool]$env:ComSpec -and (Test-Path -LiteralPath $env:ComSpec) }
        'powershell.exe' { return Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
        'pwsh.exe' { return [bool](Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue) }
        'git-bash' { return [bool](Get-AvailableGitBash) }
        default { return $false }
    }
}
# Each profile (a session pane's `profile` is the key noctty lists it under): the process that must
# appear under noctty, the flags its command line must carry, and for a shell it is safe to type into
# the command that changes directory. `pushd` rather than `cd /d`: a user's AutoRun can define a `cd`
# macro that rejects /d, and this harness runs on machines that have one.
$expectations = @{
    'cmd.exe'        = @{ Name = 'cmd.exe'; Probe = 'echo ready> ready.txt'; Cd = 'pushd "{0}"'; Tokens = @() }
    'powershell.exe' = @{ Name = 'powershell.exe'; Cd = $null; Tokens = @('-NoExit', '-Command', 'integration.ps1') }
    'pwsh.exe'       = @{ Name = 'pwsh.exe'; Cd = $null; Tokens = @('-NoExit', '-Command', 'integration.ps1') }
    'git-bash'       = @{ Name = 'bash.exe'; Probe = 'echo ready> ready.txt'; Cd = "cd '{0}'"; Tokens = @('--login', '-i') }
}

# Instrument only the run-owned copy. Automatic injection and its argv stay intact.
function Install-HiddenPowerShellProbe([string] $CaseRoot) {
    $path = Join-Path $CaseRoot 'share\ghostty\shell-integration\powershell\integration.ps1'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Run-owned PowerShell integration script is missing.' }
    $original = [IO.File]::ReadAllBytes($path)
    $originalHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $history = (Join-Path $CaseRoot 'history.txt').Replace("'", "''")
    $ready = (Join-Path $CaseRoot 'powershell-prompt-ready.json').Replace("'", "''")
    $prelude = @'
Import-Module PSReadLine -ErrorAction Stop
Set-PSReadLineOption -HistorySavePath '__HISTORY__' -HistorySaveStyle SaveNothing -ErrorAction Stop
if ((Get-PSReadLineOption).HistorySaveStyle -ne 'SaveNothing' -or (Get-PSReadLineOption).HistorySavePath -cne '__HISTORY__') { throw 'Test history isolation failed.' }
'@
    $epilogue = @'
$Global:__noctty_test_cwd_written = $false
$Global:__noctty_test_original_write_osc = $function:global:__ghostty_write_osc
function global:__ghostty_write_osc {
    param([string]$Sequence)
    & $Global:__noctty_test_original_write_osc $Sequence
    if ($Sequence.StartsWith(([string][char]27) + ']7;')) { $Global:__noctty_test_cwd_written = $true }
}
$Global:__noctty_test_original_prompt = $function:global:prompt
function global:prompt {
    $result = & $Global:__noctty_test_original_prompt
    $option = Get-PSReadLineOption
    if ($option.HistorySaveStyle -ne 'SaveNothing' -or $option.HistorySavePath -cne '__HISTORY__') { throw 'Test history isolation changed.' }
    if ($Global:__noctty_test_cwd_written) {
        @{ ProcessId = $PID; PromptReturned = $true; CwdOscForwarded = $true; HistorySaveStyle = [string]$option.HistorySaveStyle } | ConvertTo-Json | Set-Content -LiteralPath '__READY__'
    }
    return $result
}
'@
    [IO.File]::WriteAllBytes((Join-Path $CaseRoot 'integration.original.ps1'), $original)
    $body = [IO.File]::ReadAllText($path)
    $instrumented = $prelude.Replace('__HISTORY__', $history) + "`n" + $body + "`n" + $epilogue.Replace('__HISTORY__', $history).Replace('__READY__', $ready)
    [IO.File]::WriteAllText($path, $instrumented, [Text.UTF8Encoding]::new($true))
    @{ OriginalSha256 = $originalHash; InstrumentedSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Limit = 'Run-owned integration instrumented before first read for history isolation and after the real prompt for readiness. No OSC or cwd is synthesized.' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $CaseRoot 'integration-instrumentation.json')
}

function Wait-HiddenPowerShellPrompt($Case, [int] $ProcessId, [int] $ShellPid) {
    $path = Join-Path (Split-Path -Parent $Case.Dir) 'powershell-prompt-ready.json'
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while ([datetime]::UtcNow -lt $deadline) {
        Assert-HiddenDesktop -Job $job -DesktopName $desktopName -ReceiptPath $desktopReceipt -RequiredWindowPid $ProcessId
        if (Test-Path -LiteralPath $path) {
            try { $ready = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $ready = $null }
            if ($ready -and $ready.ProcessId -eq $ShellPid -and $ShellPid -gt 0 -and $ready.PromptReturned -eq $true -and $ready.CwdOscForwarded -eq $true -and $ready.HistorySaveStyle -ceq 'SaveNothing') { return }
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'PowerShell integrated prompt readiness exceeded thirty seconds.'
}

function Start-Case([string] $Key, [string] $Suffix, [string[]] $ExtraConfig) {
    $name = ($Key -replace '[^A-Za-z0-9]', '_') + $Suffix
    $dir = Join-Path $Run "$name\bin"; Copy-PortableBin $Bin $dir
    if ($Key -cin @('powershell.exe', 'pwsh.exe')) { Install-HiddenPowerShellProbe -CaseRoot (Split-Path -Parent $dir) }
    $work = Join-Path $Run "$name\work"
    # The seed spells the directory with a trailing separator. A shell that reports its own directory
    # drops it, so the saved path differs from the seed only if OSC 7 reached noctty.
    $cwdA = Join-Path $work 'a'; $cwdB = Join-Path $work 'b'
    [void](New-Item -ItemType Directory -Force -Path $cwdA, $cwdB, (Join-Path $Run "$name\home"))
    $seed = $cwdA + '\'
    $node = @{ pane = @{ cwd = $seed; profile = $Key } }
    $session = @{ schema_version = 1; windows = @(@{ selected_tab = 0; tabs = @(@{ selected_leaf = 0; layout = @{ root = 0; nodes = @($node) } }) }) }
    Set-Content -LiteralPath (Join-Path $dir 'session-state.json') -Value ($session | ConvertTo-Json -Depth 12 -Compress) -NoNewline -Encoding utf8NoBOM
    $config = Join-Path $dir 'matrix.ghostty'
    (@('window-save-state = always', 'confirm-close-surface = false', 'single-instance = false', 'auto-update = off', 'window-width = 100', 'window-height = 30') + $(if ($Renderer) { @("renderer = $Renderer") } else { @() }) + $ExtraConfig) | Set-Content -LiteralPath $config
    return @{ Key = $Key; Name = $name; Dir = $dir; Cwd = @{ A = $cwdA; B = $cwdB; Seed = $seed }; Config = $config; Home = (Join-Path $Run "$name\home") }
}

function Wait-Ready($Case, $Process) {
    $ledger = Join-Path $Case.Dir 'startup-attempts.json'
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while ([datetime]::UtcNow -lt $deadline -and -not $Process.HasExited) {
        Assert-HiddenDesktop -Job $job -DesktopName $desktopName -ReceiptPath $desktopReceipt
        $hosts = @([HiddenWin]::Hosts($Process.Id))
        $ready = $false
        if (Test-Path -LiteralPath $ledger) {
            try {
                $attempts = (Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $ready = $attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready' -and $null -ne $attempts[-1].ready_at_unix_ms
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if ($ready -and $hosts.Count) {
            $surfaces = @([HiddenWin]::Surfaces($hosts[0]))
            if ($surfaces.Count -gt 0) { Assert-HiddenDesktop -Job $job -DesktopName $desktopName -ReceiptPath $desktopReceipt -RequiredWindowPid $Process.Id; return @{ Host = $hosts[0]; Surface = $surfaces[0] } }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Window startup failed for $($Case.Key)."
}

# One launch. `Control` runs without shell integration and expects the seeded directory to survive.
function Invoke-Case([string] $Key, [switch] $Control) {
    $suffix = if ($Control) { '_control' } else { '' }
    $label = if ($Control) { "$Key (control)" } else { $Key }
    $case = Start-Case $Key $suffix $(if ($Control) { @('shell-integration = none') } else { @() })
    $expected = $expectations[$Key]
    $savedHome = $env:HOME; $savedHistfile = $env:HISTFILE
    # Git Bash takes its home from HOME: keep ~/.bash_history and its profile inside the run.
    $env:HOME = $case.Home; $env:HISTFILE = Join-Path $case.Home '.bash_history'
    $started = $null
    try {
        $started = Start-HiddenNoctty -Dir $case.Dir -DesktopName $desktopName -Job $job -StderrPath (Join-Path $Run "$($case.Name)\stderr.txt") -Arguments @(
            "--config-file=`"$($case.Config)`"", '--single-instance=false', "--class=noctty-test-pkg76-$runId-$($case.Name)")
        $ready = Wait-Ready $case $started.Process
        # The profile's own process appears under noctty (through ConPTY's host).
        $shell = $null; $deadline = [datetime]::UtcNow.AddSeconds(20)
        while ([datetime]::UtcNow -lt $deadline -and -not $shell) {
            Assert-HiddenDesktop -Job $job -DesktopName $desktopName -ReceiptPath $desktopReceipt
            $shell = Get-Descendants $started.Pid | Where-Object { $_.Name -ieq $expected.Name } | Select-Object -First 1
            if (-not $shell) { Start-Sleep -Milliseconds 200 }
        }
        Check $label "starts $($expected.Name) under noctty" ($null -ne $shell) $expected.Name ($(if ($shell) { $shell.Name } else { $null }))
        $full = if ($shell) { Get-RedactedCommandLine $shell.CommandLine @($Run) -MaxArgumentLength 4000 -MaxArguments 40 } else { '' }
        $shape = if ($shell) { Get-RedactedCommandLine $shell.CommandLine @($Run) } else { '' }
        if (-not $Control) {
            foreach ($token in $expected.Tokens) { Check $label "command line carries $token" ($full -like "*$token*") $token $shape }
        }
        Check $label 'command line has no -File or /c payload' (($full -notmatch '(^|\s)-File(\s|$)') -and ($full -notmatch '(^|\s)/c(\s|$)')) 'neither' $shape
        if ($Key -cin @('powershell.exe', 'pwsh.exe')) { Wait-HiddenPowerShellPrompt -Case $case -ProcessId $started.Pid -ShellPid ([int]$shell.ProcessId) }
        else { Start-Sleep -Milliseconds 2500 }
        Assert-HiddenDesktop -Job $job -DesktopName $desktopName -ReceiptPath $desktopReceipt
        if ($expected.Cd -and -not $Control) {
            # A command typed before the shell reads input can be lost, so prove the shell is reading
            # first: it must create a marker before the real commands go in.
            $probe = Join-Path $case.Cwd.A 'ready.txt'
            $deadline = [datetime]::UtcNow.AddSeconds(30)
            while ([datetime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $probe)) {
                Send-Text $ready.Surface $expected.Probe
                Send-Key $ready.Surface 0x0D 13
                Start-Sleep -Milliseconds 1500
            }
            Check $label 'the shell reads typed input' (Test-Path -LiteralPath $probe) 'ready.txt' ''
            Send-Text $ready.Surface ($expected.Cd -f $case.Cwd.B)
            Send-Key $ready.Surface 0x0D 13
            Start-Sleep -Milliseconds 1000
            Send-Text $ready.Surface 'echo ok> typed.txt'
            Send-Key $ready.Surface 0x0D 13
            Start-Sleep -Milliseconds 2000
            Check $label 'the typed command ran in the new directory' (Test-Path -LiteralPath (Join-Path $case.Cwd.B 'typed.txt')) 'typed.txt in b' (@(Get-ChildItem -LiteralPath $case.Cwd.B -Name) -join ',')
        }
        foreach ($h in [HiddenWin]::Hosts($started.Pid)) { [void][HiddenWin]::PostMessageW($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
        if (-not $started.Process.WaitForExit(15000)) { throw "noctty ($label) did not exit after WM_CLOSE" }
        $saved = Get-Content -LiteralPath (Join-Path $case.Dir 'session-state.json') -Raw | ConvertFrom-Json
        $pane = $saved.windows[0].tabs[0].layout.nodes[0].pane
        Check $label 'the profile key survives a close and save' ($pane.profile -eq $Key) $Key $pane.profile
        if ($Control) {
            Check $label 'without shell integration nothing refreshes the seeded directory' ($pane.cwd -ceq $case.Cwd.Seed) $case.Cwd.Seed $pane.cwd
        } else {
            $want = if ($expected.Cd) { $case.Cwd.B } else { $case.Cwd.A }
            Check $label 'the saved working directory is the one the shell reported' ($pane.cwd -ieq $want) $want $pane.cwd
        }
        $cases.Add(@{ Profile = $label; Result = 'ran'; Shape = $shape })
    } catch {
        Check $label 'harness execution' $false 'no error' $_.Exception.Message
        if ($_.Exception.Message -like 'Hidden desktop*') { throw }
    } finally {
        $env:HOME = $savedHome; $env:HISTFILE = $savedHistfile
        if ($started -and -not $started.Process.HasExited) {
            $p = Get-Process -Id $started.Pid -ErrorAction SilentlyContinue
            if ($p -and $p.StartTime -eq $started.StartTime) { Stop-Process -Id $p.Id -Force }
        }
    }
}

foreach ($key in $Profile) {
    if (-not $expectations.ContainsKey($key)) { throw "Unknown profile '$key'." }
    if (-not (Test-Available $key)) {
        $cases.Add(@{ Profile = $key; Result = 'skipped'; Reason = 'not installed on this machine' })
        if ($RequireAll) { Check $key 'required profile is installed and detected' $false 'available' 'not detected' }
        continue
    }
    Invoke-Case $key
}
if ($Profile -contains 'cmd.exe') { Invoke-Case 'cmd.exe' -Control }
$anyRan = @($cases | Where-Object { $_.Result -eq 'ran' }).Count
Check 'matrix' 'at least one profile ran' ($anyRan -gt 0) '>= 1' $anyRan
@{ Checks = $checks; Cases = $cases; Limit = 'Hidden desktop, posted keys only. WSL, SSH and PowerShell panes are not typed into; the directory of a PowerShell pane is checked from its first prompt.' } |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'profile-matrix-results.json')
$failed = @($checks | Where-Object { -not $_.Passed })
if ($failed.Count) { exit 1 }
} catch { $driverFailure = $_; throw } finally { Close-HiddenDriverSentinel -Sentinel $sentinel -Run $Run -WaitForParent:$driverApproved -PrimaryFailure $driverFailure -OwnedJob $job }
