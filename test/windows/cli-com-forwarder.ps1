#requires -Version 7.0
<#
PKG-74 / D20 baseline and replacement regression harness (x64 and ARM64).
Requires a measure-AUMID portable directory with noctty.com, noctty.exe,
noctty.portable and share/ghostty, plus the windowless desktop fixture built
from test/windows/cli-com-fixture.zig. Does not build anything.
Run: ./test/windows/cli-com-forwarder.ps1 -BinDir <portable> -OutputDir <new-dir> [-DesktopFixture <exe>] [-ThinForwarder] [-ExerciseInheritedCtrlCIgnore]
Alternatively -ExePath <portable/noctty.com>. Evidence is retained in OutputDir.
-DesktopFixture defaults to <repo>/zig-out/cli-com-fixture.exe and must exist.
The no-action GUI case writes gui-close.json on every run: StageMs holds the
milliseconds from just before its launch to the end of each stage it finished,
and a failure also keeps its stage and, on an exit timeout, close diagnostics.

Everything runs on ONE new hidden desktop of the current window station
(WinSta0\noctty-pkg74-<guid>, never switched to, inheritable handle). Every
harness-created child names it through an explicit lpDesktop. Console helpers
use CREATE_NO_WINDOW; Ctrl+C uses a console event. No profiles, typed shell
commands, clipboard operations or real registration.

The first cases are a mandatory setup gate that runs a windowless fixture in
place of noctty.exe: no real GUI window or failure dialog is created until the
gate has shown that the launcher keeps the hidden desktop. -ProveDesktopOnly
stops after the gate. -ThinForwarder adds the fixture cases that only hold for
the thin CreateProcessW forwarder (raw command line, stdin, full DWORD exit
code, -e classification, no-action pipe EOF, no show-flag propagation); the old
in-process shim runs actions itself, so those cases do not apply to it.
-InheritHiddenDesktop is accepted for compatibility and is now the only mode.

The Ctrl+C case needs a driver that does not ignore Ctrl+C. The ignore attribute
is inherited (cmd's `start /b`, CREATE_NEW_PROCESS_GROUP and several agent shells
set it), and every process of the CLI under test then ignores the CTRL_C_EVENT
it is sent, so the case failed with "Ctrl+C did not end the CLI action." only
when the harness was started that way. The driver now clears the attribute with
SetConsoleCtrlHandler(NULL, FALSE) before it starts any child
(CLIFWD-CTRLC-HARNESS-01, after #477). -ExerciseInheritedCtrlCIgnore is the
positive control: this script starts the driver (the process `$controller`
holds) under CREATE_NEW_PROCESS_GROUP, and the driver asserts that it really
arrived ignoring Ctrl+C and that the reset cleared it. The reset belongs in the
driver, not in the pwsh session running this script.
Removing the reset fails that check at once; removing the check as well fails
the Ctrl+C case with its original message.
#>
[CmdletBinding()]
param(
    [string] $BinDir,
    [string] $ExePath,
    [Parameter(Mandatory)] [string] $OutputDir,
    [ValidateRange(5,120)] [int] $TimeoutSeconds = 20,
    [ValidateRange(10,100)] [int] $VersionIterations = 10,
    [string] $DesktopFixture,
    [switch] $ThinForwarder,
    [switch] $ProveDesktopOnly,
    [switch] $InheritHiddenDesktop,
    [switch] $ExerciseInheritedCtrlCIgnore,
    [switch] $Driver,
    [string] $DesktopName,
    [switch] $DetachedOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'cli-com-native.cs')

function Get-StateMetadata([string] $Path, [switch] $MetadataOnly) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Exists = $false } }
    $item = Get-Item -LiteralPath $Path
    $result = @{ Exists = $true; Bytes = $item.Length; ModifiedUtc = $item.LastWriteTimeUtc.ToString('o') }
    if (-not $MetadataOnly) { $result.Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $result
}
function Assert-Condition([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Wait-Condition([scriptblock] $Condition, [string] $Description) {
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 25
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timeout: $Description"
}

if (-not $Driver) {
    if (-not $DesktopFixture) { $DesktopFixture = Join-Path $PSScriptRoot '../../zig-out/cli-com-fixture.exe' }
    Assert-Condition (Test-Path -LiteralPath $DesktopFixture -PathType Leaf) "Missing windowless desktop fixture '$DesktopFixture'. Build test/windows/cli-com-fixture.zig (see .github/workflows/cli-forwarder.yml) and pass -DesktopFixture."
    $DesktopFixture = (Resolve-Path -LiteralPath $DesktopFixture).Path
    if ($ExePath) {
        Assert-Condition ([IO.Path]::GetFileName($ExePath) -eq 'noctty.com') 'ExePath must name noctty.com.'
        $BinDir = Split-Path -Parent (Resolve-Path -LiteralPath $ExePath).Path
    }
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($BinDir)) 'Specify BinDir or ExePath.'
    $BinDir = (Resolve-Path -LiteralPath $BinDir).Path
    foreach ($required in @('noctty.com', 'noctty.exe', 'noctty.portable')) {
        Assert-Condition (Test-Path -LiteralPath (Join-Path $BinDir $required)) "Missing portable input: $required"
    }
    $sourceShare = Join-Path $BinDir 'share'
    if (-not (Test-Path -LiteralPath (Join-Path $sourceShare 'ghostty/themes'))) {
        $sourceShare = Join-Path (Split-Path -Parent $BinDir) 'share'
    }
    Assert-Condition (Test-Path -LiteralPath (Join-Path $sourceShare 'ghostty/themes')) 'Missing portable share/ghostty/themes tree.'
    $OutputDir = [IO.Path]::GetFullPath($OutputDir)
    Assert-Condition (-not (Test-Path -LiteralPath $OutputDir)) 'OutputDir must be new; evidence is never reset.'
    [void](New-Item -ItemType Directory -Path $OutputDir)
    $portable = Join-Path $OutputDir 'portable'
    Copy-Item -LiteralPath $BinDir -Destination $portable -Recurse
    if (-not (Test-Path -LiteralPath (Join-Path $portable 'share'))) {
        Copy-Item -LiteralPath $sourceShare -Destination (Join-Path $portable 'share') -Recurse
    }
    foreach ($name in @('appdata', 'localappdata', 'home')) {
        [void](New-Item -ItemType Directory -Path (Join-Path $OutputDir $name))
    }
    $class = 'noctty-test-pkg74-' + [guid]::NewGuid().ToString('N')
    # Isolated config supplies identity even for actions whose own options reject
    # GUI flags. Explicit flags are also supplied on the no-action GUI invocation.
    @(
        'single-instance = false'
        "class = $class"
        'renderer = d3d11-warp'
        'auto-update = off'
        'confirm-close-surface = false'
        'window-save-state = never'
        'shell-integration = none'
        'command = C:\Windows\System32\cmd.exe /d /q'
    ) | Set-Content -LiteralPath (Join-Path $portable 'config.ghostty') -Encoding utf8NoBOM
    $startupPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty/startup-attempts.json'
    $startupBefore = Get-StateMetadata $startupPath
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'cli-com-forwarder.ps1'
    $clipboardBefore = [ComCliNative]::GetClipboardSequenceNumber()
    $batchStarted = [datetime]::UtcNow
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $DesktopName = 'noctty-pkg74-' + [guid]::NewGuid().ToString('N')
    $desktopHandle = $null
    $controller = $null
    $saved = @{}
    $failure = $null
    try {
        $desktopHandle = [ComCliNative]::HiddenDesktop($DesktopName)
        foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'HOME', 'USERPROFILE', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'GHOSTTY_RESOURCES_DIR')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            $value = switch ($name) {
                APPDATA { Join-Path $OutputDir 'appdata' }
                LOCALAPPDATA { Join-Path $OutputDir 'localappdata' }
                GHOSTTY_RESOURCES_DIR { Join-Path $portable 'share/ghostty' }
                default { Join-Path $OutputDir 'home' }
            }
            [Environment]::SetEnvironmentVariable($name, $value)
        }
        $pwsh = (Get-Process -Id $PID).Path
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-BinDir', $portable,
            '-OutputDir', $OutputDir, '-Driver', '-DesktopName', $DesktopName, '-DesktopFixture', $DesktopFixture,
            '-TimeoutSeconds', "$TimeoutSeconds", '-VersionIterations', "$VersionIterations")
        if ($ThinForwarder) { $arguments += '-ThinForwarder' }
        if ($ProveDesktopOnly) { $arguments += '-ProveDesktopOnly' }
        if ($ExerciseInheritedCtrlCIgnore) { $arguments += '-ExerciseInheritedCtrlCIgnore' }
        $raw = ($arguments | ForEach-Object { [ComCliNative]::Quote($_) }) -join ' '
        # CREATE_NO_WINDOW, plus CREATE_NEW_PROCESS_GROUP (0x200) to seed the inherited Ctrl+C ignore.
        $driverFlags = if ($ExerciseInheritedCtrlCIgnore) { 0x08000200 } else { 0x08000000 }
        $controller = [ComCliNative]::Launch($pwsh, $raw, $OutputDir, "WinSta0\$DesktopName", 'files', $null,
            (Join-Path $OutputDir 'controller.stdout.txt'), (Join-Path $OutputDir 'controller.stderr.txt'), $driverFlags)
        Assert-Condition ($controller.Wait(($TimeoutSeconds * 16 + $VersionIterations * 5) * 1000)) 'Hidden-desktop controller timed out.'
        Assert-Condition ($controller.ExitCode -eq 0) 'Hidden-desktop controller failed; inspect bounded per-case results.json and the controller capture.'
        if (-not $ProveDesktopOnly) {
            # A pass must leave the GUI case's stage timings, so a slow close can be
            # told apart from a slow startup without a failure.
            $closeReceipt = [IO.File]::ReadAllText((Join-Path $OutputDir 'gui-close.json')) | ConvertFrom-Json
            $stages = @($closeReceipt.StageMs.PSObject.Properties)
            $ordered = $stages[0].Value -ge 0
            for ($i = 1; $i -lt $stages.Count; $i++) { $ordered = $ordered -and $stages[$i].Value -ge $stages[$i - 1].Value }
            Assert-Condition ($closeReceipt.Stage -ceq 'passed' -and $ordered -and
                ($stages.Name -join ',') -ceq 'LauncherReturn,HostWindow,Title,Visible,Post,ProcessExit,JobEmpty') 'gui-close.json lacks the passing GUI case''s stage timings.'
            $stageSummary = ($stages | ForEach-Object { "$($_.Name)=$([math]::Round($_.Value))" }) -join ' '
        }
    } catch { $failure = $_ }
    finally {
        if ($controller) { $controller.Dispose() }
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        if ($desktopHandle) { [void][ComCliNative]::CloseDesktop($desktopHandle) }
        $clock.Stop()
        $startupAfter = Get-StateMetadata $startupPath
        $historyFailure = $null
        try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure = $_ }
        $clipboardAfter = [ComCliNative]::GetClipboardSequenceNumber()
        $receipt = [ordered]@{
            StartedUtc = $batchStarted.ToString('o'); FinishedUtc = [datetime]::UtcNow.ToString('o'); ElapsedMs = $clock.Elapsed.TotalMilliseconds
            Architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
            Desktop = "WinSta0\$DesktopName"
            StartupBefore = $startupBefore; StartupAfter = $startupAfter
            HistoryPaths = $historyGuard.Paths; HistoryBefore = $historyGuard.Before
            ClipboardBefore = $clipboardBefore; ClipboardAfter = $clipboardAfter
            ClipboardUnchanged = $clipboardBefore -eq $clipboardAfter
            StartupUnchanged = ($startupBefore | ConvertTo-Json -Compress) -ceq ($startupAfter | ConvertTo-Json -Compress)
            HistoryUnchanged = $null -eq $historyFailure
            ComBytes = (Get-Item -LiteralPath (Join-Path $portable 'noctty.com')).Length
            ComSha256 = (Get-FileHash -LiteralPath (Join-Path $portable 'noctty.com')).Hash
            Status = if ($failure) { 'Failed' } else { 'Passed' }
            Failure = if ($failure) { $failure.Exception.Message } else { $null }
            NativeErrorCode = if ($failure -and $failure.Exception.InnerException -is [ComponentModel.Win32Exception]) { $failure.Exception.InnerException.NativeErrorCode } else { $null }
            Coverage = if ($ProveDesktopOnly) { 'Windowless fixture setup gate only; product coverage owed' } elseif ($ThinForwarder) { 'Full + thin forwarder fixture cases' } else { 'Full' }
        }
        $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir 'isolation.json') -Encoding utf8NoBOM
        if ($historyFailure) { throw $historyFailure }
        Assert-Condition $receipt.StartupUnchanged 'Real state metadata changed; stop launches and report.'
        Assert-Condition $receipt.ClipboardUnchanged 'WinSta0 clipboard sequence changed; stop launches and report.'
    }
    if ($failure) { throw $failure }
    Write-Host "COM CLI regression: $(if ($ProveDesktopOnly) { 'DESKTOP SETUP GATE PASSED; product coverage owed' } else { "PASS; GUI stage ms since launch: $stageSummary" }); evidence=$OutputDir"
    return
}

$desktopPath = "WinSta0\$DesktopName"
if ($DetachedOnly) { [void][ComCliNative]::FreeConsole() }
$desktopHandle = [ComCliNative]::DriverDesktop($DesktopName)
# Clear an inherited Ctrl+C-ignore attribute before this driver starts any child,
# or the Ctrl+C case below has no process to interrupt (see the header note).
$ctrlCIgnoredOnEntry = [ComCliNative]::CtrlCIgnored()
[ComCliNative]::EnableCtrlC()
$ctrlCIgnoredAfterReset = [ComCliNative]::CtrlCIgnored()
@{ Pid = $PID; DetachedOnly = $DetachedOnly.IsPresent; HasConsole = [ComCliNative]::HasConsole(); Desktop = $DesktopName; CtrlCIgnoredOnEntry = $ctrlCIgnoredOnEntry; CtrlCIgnoredAfterReset = $ctrlCIgnoredAfterReset } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir "driver-$($DetachedOnly.IsPresent).json") -Encoding utf8NoBOM
Assert-Condition ($ctrlCIgnoredOnEntry -or -not $ExerciseInheritedCtrlCIgnore) 'The seeded driver did not inherit the Ctrl+C ignore attribute, so the positive control proves nothing.'
Assert-Condition (-not $ctrlCIgnoredAfterReset) 'Enabling Ctrl+C did not clear the driver''s ignore attribute.'
$com = Join-Path $BinDir 'noctty.com'
$gui = Join-Path $BinDir 'noctty.exe'
$results = [Collections.Generic.List[object]]::new()
$versionTimes = [Collections.Generic.List[double]]::new()
$script:caseIndex = 0
$script:fixtureIndex = 0
$script:found = $null
function Test-Case([string] $Name, [scriptblock] $Test) {
    $started = [datetime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $entry = [ordered]@{ Name = $Name; StartedUtc = $started.ToString('o'); Status = 'Failed'; Passed = $false; ElapsedMs = 0; Detail = $null }
    try { & $Test; $entry.Passed = $true; $entry.Status = 'Passed' }
    catch { $entry.Detail = $_.Exception.Message; throw }
    finally {
        $watch.Stop(); $entry.ElapsedMs = $watch.Elapsed.TotalMilliseconds
        $results.Add([pscustomobject]$entry)
        @{ Cases = @($results); Coverage = if ($ProveDesktopOnly) { 'SetupGateOnly' } elseif ($DetachedOnly) { 'DetachedOnly' } elseif ($ThinForwarder) { 'FullThin' } else { 'Full' }; VersionIterations = $versionTimes.Count; VersionMedianMs = if ($versionTimes.Count) { ($versionTimes | Sort-Object)[[int][math]::Floor($versionTimes.Count / 2)] } else { $null } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir $(if ($DetachedOnly) { 'detached-results.json' } else { 'results.json' })) -Encoding utf8NoBOM
    }
}
# Everything a case started must be gone before its Dispose: a wrapper that
# dies while its action child lives on would otherwise be hidden by the job's
# kill-on-close cleanup.
function Assert-JobEmpty($Child, [string] $What) {
    Wait-Condition { [ComCliNative]::ActiveProcesses($Child) -eq 0 } "no process left in the owned job after $What"
}
function Invoke-Cli([string] $Raw, [string] $Mode = 'pipes', [string] $InputPath, [uint32] $Flags = 0x08000000) {
    $script:caseIndex++
    $out = Join-Path $OutputDir "case-$script:caseIndex.stdout.txt"
    $err = Join-Path $OutputDir "case-$script:caseIndex.stderr.txt"
    $processClock = [Diagnostics.Stopwatch]::StartNew()
    $child = [ComCliNative]::Launch($com, $Raw, $BinDir, $desktopPath, $Mode, $InputPath, $out, $err, $Flags)
    try {
        Assert-Condition ($child.Wait($TimeoutSeconds * 1000)) 'CLI timed out.'
        $processClock.Stop()
        $stdout = if ($child.Output) { $child.ReadOutput(5000) } else { [ComCliNative]::ReadCapture($out) }
        $stderr = if ($child.Error) { $child.ReadError(5000) } else { [ComCliNative]::ReadCapture($err) }
        $code = $child.ExitCode
        Assert-JobEmpty $child "'$Raw'"
        return @{ Code = $code; Out = $stdout; Err = $stderr; ProcessElapsedMs = $processClock.Elapsed.TotalMilliseconds }
    } finally { $child.Dispose() }
}
function Assert-Version($Result) {
    Assert-Condition ($Result.Code -eq 0 -and $Result.Out.Contains('Build Config') -and $Result.Out.Contains('- channel:') -and $Result.Err.Length -eq 0) 'Version output/status mismatch.'
}
function Test-NoHandles {
    Assert-Condition (-not [ComCliNative]::HasConsole()) 'No-handle test controller must have no console.'
    $title = 'noctty CLI action failed'
    $child = [ComCliNative]::Launch($com, '+version', $BinDir, $desktopPath, 'none', $null, $null, $null, 8)
    try {
        $script:found = $null
        Wait-Condition {
            $script:found = @([ComCliNative]::Windows($desktopHandle, '#32770') | Where-Object { [ComCliNative]::Title($_) -eq $title })[0]
            $null -ne $script:found
        } 'detached failure dialog (the action must report its failure visibly)'
        $dialog = $script:found
        Assert-Condition (-not $child.Exited) 'Detached CLI exited although its failure dialog is still open.'
        [ComCliNative]::AssertOwned($child, [ComCliNative]::WindowPid($dialog))
        Assert-Condition ([ComCliNative]::PostMessageW($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) 'Failure dialog close failed.'
        if (-not $child.Wait(2000)) {
            Assert-Condition ([ComCliNative]::PostMessageW($dialog, 0x0111, [IntPtr]1, [IntPtr]::Zero)) 'Failure dialog IDOK failed.'
        }
        Assert-Condition ($child.Wait($TimeoutSeconds * 1000)) 'Detached CLI did not return after closing its dialog.'
        Assert-Condition ($child.ExitCode -eq 1) "Detached CLI failure exit mismatch: $($child.ExitCode)."
        Assert-JobEmpty $child 'the detached failure'
    } finally { $child.Dispose() }
}

# Fixture cases: a copy of the launcher next to a windowless stand-in for
# noctty.exe. Returns the launcher child; the caller disposes it.
$fixtureBin = Join-Path $OutputDir 'fixture-bin'
$fixtureExe = Join-Path $fixtureBin 'noctty.exe'
$fixtureCom = Join-Path $fixtureBin 'noctty.com'
function Initialize-FixtureBin {
    [void](New-Item -ItemType Directory -Path $fixtureBin)
    Copy-Item -LiteralPath $com -Destination $fixtureCom
    Copy-Item -LiteralPath $DesktopFixture -Destination $fixtureExe
    [IO.File]::WriteAllText((Join-Path $fixtureBin 'noctty.portable'), '')
}
function Start-Fixture([string] $Raw, [hashtable] $Knobs = @{}, [string] $Mode = 'files', [string] $InputPath, [switch] $RawCommandLine) {
    $script:fixtureIndex++
    $receiptPath = Join-Path $OutputDir "fixture-$script:fixtureIndex.json"
    $variables = @{ NOCTTY_COM_FIXTURE_RECEIPT = $receiptPath; NOCTTY_COM_FIXTURE_HOLD_MS = '0' }
    foreach ($key in $Knobs.Keys) { $variables["NOCTTY_COM_FIXTURE_$key"] = [string] $Knobs[$key] }
    $previous = @{}
    foreach ($key in $variables.Keys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, $variables[$key]) }
    try {
        $child = [ComCliNative]::Launch($fixtureCom, $Raw, $fixtureBin, $desktopPath, $Mode, $InputPath,
            (Join-Path $OutputDir "fixture-$script:fixtureIndex.stdout.txt"), (Join-Path $OutputDir "fixture-$script:fixtureIndex.stderr.txt"), 0x08000000, 0, $RawCommandLine.IsPresent)
    } finally { foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) } }
    return @{ Child = $child; Receipt = $receiptPath; Index = $script:fixtureIndex }
}
function Read-FixtureReceipt($Run) {
    $script:found = $null
    Wait-Condition {
        try { $script:found = [IO.File]::ReadAllText($Run.Receipt) | ConvertFrom-Json; $true } catch { $false }
    } 'fixture receipt'
    return $script:found
}
function Assert-FixtureDesktop($Receipt) {
    Assert-Condition ($Receipt.station -ceq 'WinSta0' -and $Receipt.desktop -ceq $DesktopName) "Fixture left the hidden desktop: $($Receipt.station)\$($Receipt.desktop)."
    Assert-Condition (@([ComCliNative]::Windows($desktopHandle, 'noctty.win32.host')).Count -eq 0) 'A GUI window exists during the windowless setup gate.'
}
$useStdHandles = 0x100
$useShowWindow = 0x1

try {
    if (-not $DetachedOnly) {
        Initialize-FixtureBin
        # Setup gate 1 (always, before any real GUI or dialog): a no-action
        # launch passes the hidden desktop to a detached, windowless noctty.exe
        # and returns at once without waiting for it.
        Test-Case 'gate: no-action launch keeps the hidden desktop and does not wait' {
            $run = Start-Fixture '--single-instance=false --class=noctty-test-pkg74-fixture' @{ HOLD_MS = 3000 }
            $fixtureChild = $null
            try {
                Assert-Condition ($run.Child.Wait(5000) -and $run.Child.ExitCode -eq 0) "Fixture no-action launcher failed to return promptly (exit=$($run.Child.ExitCode))."
                $receipt = Read-FixtureReceipt $run
                Assert-FixtureDesktop $receipt
                $fixtureChild = [ComCliNative]::OwnedProcess([uint32]$receipt.pid, $fixtureExe, $run.Child)
                Assert-Condition (-not $fixtureChild.Exited) 'Fixture did not outlive the returning launcher.'
                if ($ThinForwarder) {
                    Assert-Condition (($receipt.startup_flags -band $useStdHandles) -eq 0) 'The no-action child was handed standard handles.'
                    Assert-Condition (-not $receipt.console) 'The no-action child is attached to a console.'
                }
                Assert-Condition ($fixtureChild.Wait(5000) -and $fixtureChild.ExitCode -eq 0) 'Windowless fixture did not exit naturally.'
                Assert-JobEmpty $run.Child 'the no-action fixture'
            } finally { if ($fixtureChild) { $fixtureChild.Dispose() }; $run.Child.Dispose() }
        }
        # Setup gate 2 (thin forwarder): an action reaches noctty.exe on the same
        # desktop with inherited standard handles and its exit code comes back.
        if ($ThinForwarder) {
            Test-Case 'gate: forwarded action keeps the hidden desktop, stdio and exit code' {
                $run = Start-Fixture '+version' @{ EXIT = 7; OUT = 1 } 'pipes'
                try {
                    Assert-Condition ($run.Child.Wait($TimeoutSeconds * 1000)) 'Fixture action launcher timed out.'
                    Assert-Condition ($run.Child.ExitCode -eq 7) "Fixture action exit code mismatch: $($run.Child.ExitCode)."
                    $receipt = Read-FixtureReceipt $run
                    Assert-FixtureDesktop $receipt
                    Assert-Condition (($receipt.startup_flags -band $useStdHandles) -ne 0 -and $receipt.console) 'The forwarded action did not inherit stdio/console.'
                    Assert-Condition ($run.Child.ReadOutput(5000).Contains('fixture-out') -and $run.Child.ReadError(5000).Contains('fixture-err')) 'Forwarded stdout/stderr did not arrive.'
                    Assert-JobEmpty $run.Child 'the forwarded fixture action'
                } finally { $run.Child.Dispose() }
            }
        }
        if ($ProveDesktopOnly) { return }
    }
    if ($DetachedOnly) { Test-Case 'detached no-console/no-standard-handles' { Test-NoHandles }; return }
    Test-Case 'detached with stdout/stderr pipes' { Assert-Version (Invoke-Cli '+version' 'pipes' -Flags 8) }
    Test-Case 'detached no-console/no-standard-handles' {
        $pwsh = (Get-Process -Id $PID).Path
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-BinDir', $BinDir,
            '-OutputDir', $OutputDir, '-Driver', '-DesktopName', $DesktopName, '-DetachedOnly', '-TimeoutSeconds', "$TimeoutSeconds")
        $raw = ($arguments | ForEach-Object { [ComCliNative]::Quote($_) }) -join ' '
        $subcontroller = [ComCliNative]::Launch($pwsh, $raw, $OutputDir, $desktopPath, 'files', $null,
            (Join-Path $OutputDir 'detached-controller.stdout.txt'), (Join-Path $OutputDir 'detached-controller.stderr.txt'), 0x08000000)
        try {
            Assert-Condition ($subcontroller.Wait(($TimeoutSeconds + 10) * 1000) -and $subcontroller.ExitCode -eq 0) 'Console-less no-handle subcontroller failed.'
            $detachedReceipt = Join-Path $OutputDir 'detached-results.json'
            Assert-Condition (Test-Path -LiteralPath $detachedReceipt) 'Console-less subcontroller did not produce its required receipt.'
            $detachedResult = [IO.File]::ReadAllText($detachedReceipt) | ConvertFrom-Json
            Assert-Condition ($detachedResult.Cases.Count -eq 1 -and $detachedResult.Cases[0].Passed) 'Console-less subcontroller did not validate the no-handle case.'
        }
        finally { $subcontroller.Dispose() }
    }
    Test-Case 'stdout file and success exit code' { Assert-Version (Invoke-Cli '+version' 'files') }
    Test-Case 'version alias and action delimiter' {
        Assert-Version (Invoke-Cli '--version')
        Assert-Version (Invoke-Cli '+version -- +pkg74-invalid-action')
    }
    Test-Case 'help fallback and multiple-action diagnostics' {
        $help = Invoke-Cli '--help'
        Assert-Condition ($help.Code -eq 0 -and $help.Out.Contains('Usage:')) 'Help fallback mismatch.'
        $invalid = Invoke-Cli '+version +list-themes'
        Assert-Condition ($invalid.Code -eq 1 -and $invalid.Err.Contains('multiple CLI actions')) 'Multiple-action diagnostic mismatch.'
    }
    foreach ($mode in @('pipes', 'files')) {
        Test-Case "stderr $mode and failure exit code" {
            $result = Invoke-Cli '+pkg74-invalid-action' $mode
            Assert-Condition ($result.Code -eq 1 -and $result.Out.Length -eq 0 -and $result.Err.Contains('unknown CLI action')) 'Invalid-action stderr/status mismatch.'
        }
    }
    Test-Case 'stdin redirected to file' {
        $input = Join-Path $OutputDir 'stdin.txt'
        [IO.File]::WriteAllText($input, "stdin must not become argv or terminal input`n")
        Assert-Version (Invoke-Cli '+version' 'pipes' $input)
    }
    Test-Case 'Unicode and spaced config-file argument' {
        $config = Join-Path $OutputDir 'config 空間 😀.ghostty'
        [IO.File]::WriteAllText($config, "pkg74-invalid-field = true`n", [Text.UTF8Encoding]::new($false))
        $result = Invoke-Cli ('+validate-config ' + [ComCliNative]::Quote("--config-file=$config"))
        Assert-Condition ($result.Code -eq 1 -and $result.Out.Contains('pkg74-invalid-field') -and $result.Out.Contains('config 空間 😀.ghostty')) 'Unicode path did not reach real config validation.'
    }
    Test-Case 'list-themes with redirected stdout' {
        $result = Invoke-Cli '+list-themes'
        Assert-Condition ($result.Code -eq 0 -and $result.Out.Contains('0x96f (resources)') -and $result.Err.Length -eq 0) 'Plain theme listing mismatch.'
    }
    Test-Case 'list-themes with console stdout stays plain on Windows' {
        $result = Invoke-Cli '+list-themes' 'console' -Flags 0
        Assert-Condition ($result.Code -eq 0 -and [ComCliNative]::ConsoleText().Contains('0x96f (resources)')) 'Console theme listing compatibility mismatch.'
    }
    Test-Case 'Ctrl+C console event interrupts an action blocked on stdout' {
        $child = [ComCliNative]::Launch($com, '+show-config --default --docs --no-pager', $BinDir, $desktopPath, 'blocked', $null, $null, $null, 0)
        try {
            Wait-Condition { -not $child.Exited -and [ComCliNative]::Buffered($child) -ge 4096 } 'real config output fills stdout pipe'
            [ComCliNative]::CtrlC($child)
            Assert-Condition ($child.Wait($TimeoutSeconds * 1000)) 'Ctrl+C did not end the CLI action.'
            Assert-Condition ($child.ExitCode -eq 0xC000013Au) 'Ctrl+C exit code was not STATUS_CONTROL_C_EXIT.'
            # A wrapper that died alone would leave the action child running.
            Assert-JobEmpty $child 'Ctrl+C'
        } finally { $child.Dispose() }
    }
    if ($ThinForwarder) {
        Test-Case 'thin: actions work inside an outer job with UI restrictions' {
            Assert-Version (Invoke-Cli '+version' 'restricted')
        }
        Test-Case 'thin: terminating the wrapper ends its blocked action child' {
            $child = [ComCliNative]::Launch($com, '+show-config --default --docs --no-pager', $BinDir, $desktopPath, 'blocked', $null, $null, $null, 0)
            try {
                Wait-Condition { -not $child.Exited -and [ComCliNative]::Buffered($child) -ge 4096 } 'action output fills stdout before wrapper termination'
                Assert-Condition ([ComCliNative]::ActiveProcesses($child) -ge 2) 'The probe did not observe a live wrapper and action child.'
                [ComCliNative]::TerminateOwned($child, 0xD20)
                Assert-Condition ($child.Wait($TimeoutSeconds * 1000)) 'Terminated wrapper did not exit.'
                Assert-JobEmpty $child 'terminating the wrapper without closing the harness job'
            } finally { $child.Dispose() }
        }
        Test-Case 'thin: raw command line, stdin, stdout/stderr and full DWORD exit code' {
            $bytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(70000)
            $stdinPath = Join-Path $OutputDir 'fixture-stdin.bin'
            [IO.File]::WriteAllBytes($stdinPath, $bytes)
            $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            $raw = '+version "a ""b"" c" \\"d\" tail\\ 空間 😀 %PATH% ^& *'
            foreach ($code in @('7', '2147500037', '3221226505', '4294967295')) {
                $run = Start-Fixture $raw @{ EXIT = $code; STDIN = 1; OUT = 1 } 'pipes' $stdinPath
                try {
                    Assert-Condition ($run.Child.Wait($TimeoutSeconds * 1000)) 'Fixture action timed out.'
                    Assert-Condition ($run.Child.ExitCode -eq [uint32] $code) "Exit code $code was not returned unchanged ($($run.Child.ExitCode))."
                    $receipt = Read-FixtureReceipt $run
                    Assert-Condition ($receipt.command_line -ceq ([ComCliNative]::Quote($fixtureCom) + ' ' + $raw)) "Raw command line changed: $($receipt.command_line)"
                    Assert-Condition ($receipt.stdin_bytes -eq $bytes.Length -and $receipt.stdin_sha256 -ceq $expectedHash) 'Redirected stdin did not arrive intact.'
                    Assert-Condition ($run.Child.ReadOutput(5000) -ceq "fixture-out`n" -and $run.Child.ReadError(5000) -ceq "fixture-err`n") 'Redirected stdout/stderr mismatch.'
                    Assert-JobEmpty $run.Child "fixture exit $code"
                } finally { $run.Child.Dispose() }
            }
        }
        # -e, -- and --help decide wait versus detach exactly like the old shim.
        Test-Case 'thin: -e and -- stay detached; actions, --help and detection errors wait' {
            foreach ($case in @(
                @{ Raw = '-e +version'; Waits = $false }
                @{ Raw = '-- +version'; Waits = $false }
                @{ Raw = '+version -e x'; Waits = $true }
                @{ Raw = '--help'; Waits = $true }
                @{ Raw = '+pkg74-invalid-action'; Waits = $true }
            )) {
                $run = Start-Fixture $case.Raw @{ EXIT = 77; HOLD_MS = $(if ($case.Waits) { 0 } else { 3000 }) }
                try {
                    if ($case.Waits) {
                        Assert-Condition ($run.Child.Wait($TimeoutSeconds * 1000) -and $run.Child.ExitCode -eq 77) "'$($case.Raw)' did not wait for and return the child's exit code."
                        Assert-Condition (((Read-FixtureReceipt $run).startup_flags -band $useStdHandles) -ne 0) "'$($case.Raw)' did not inherit stdio."
                        Assert-JobEmpty $run.Child "'$($case.Raw)'"
                    } else {
                        Assert-Condition ($run.Child.Wait(2000) -and $run.Child.ExitCode -eq 0) "'$($case.Raw)' waited for the GUI instead of returning at once."
                        $receipt = Read-FixtureReceipt $run
                        Assert-Condition (($receipt.startup_flags -band ($useStdHandles -bor $useShowWindow)) -eq 0) "'$($case.Raw)' propagated std-handle or show-window startup flags."
                        $fixtureChild = [ComCliNative]::OwnedProcess([uint32]$receipt.pid, $fixtureExe, $run.Child)
                        try { Assert-Condition (-not $fixtureChild.Exited) "'$($case.Raw)' child did not outlive the launcher." } finally { $fixtureChild.Dispose() }
                    }
                } finally { $run.Child.Dispose() }
            }
        }
        Test-Case 'thin: no-action launch closes redirected pipes and tolerates an empty command line' {
            $run = Start-Fixture '--single-instance=false --class=noctty-test-pkg74-fixture' @{ HOLD_MS = 6000 } 'pipes'
            try {
                Assert-Condition ($run.Child.Wait(2000) -and $run.Child.ExitCode -eq 0) 'No-action launcher did not return promptly.'
                $receipt = Read-FixtureReceipt $run
                $fixtureChild = [ComCliNative]::OwnedProcess([uint32]$receipt.pid, $fixtureExe, $run.Child)
                try {
                    Assert-Condition ($run.Child.OutputClosed(1500) -and $run.Child.ErrorClosed(1500)) 'The detached no-action child kept the caller''s stdout/stderr pipes open.'
                    Assert-Condition (-not $fixtureChild.Exited) 'Pipes closed only because the no-action child exited.'
                } finally { $fixtureChild.Dispose() }
            } finally { $run.Child.Dispose() }
            foreach ($raw in @('', " `t ")) {
                $run = Start-Fixture $raw @{ HOLD_MS = 3000 } 'files' -RawCommandLine
                try {
                    Assert-Condition ($run.Child.Wait(2000) -and $run.Child.ExitCode -eq 0) 'Blank-command-line launcher did not return promptly.'
                    # Windows normalizes a non-null empty buffer to the launcher
                    # path. Whitespace survives CreateProcessW and exercises the
                    # wrapper's blank-line fallback to the quoted sibling path.
                    $expected = if ($raw.Length -eq 0) { $fixtureCom } else { $fixtureExe }
                    Assert-Condition ((Read-FixtureReceipt $run).command_line -ceq [ComCliNative]::Quote($expected)) 'Blank command line did not become the exact quoted executable path.'
                } finally { $run.Child.Dispose() }
            }
        }
    }
    for ($iteration = 0; $iteration -lt $VersionIterations; $iteration++) {
        Test-Case "version timing $iteration" {
            $result = Invoke-Cli '+version'
            Assert-Version $result
            # Measure through wrapper exit; pipe draining and asynchronous job
            # accounting are controller cleanup, not application startup.
            $versionTimes.Add($result.ProcessElapsedMs)
        }
    }
    Test-Case 'no-action raw quotes and Unicode title opens GUI and returns promptly' {
        $config = [IO.File]::ReadAllText((Join-Path $BinDir 'config.ghostty'))
        $class = [regex]::Match($config, '(?m)^class = (.+)$').Groups[1].Value.Trim()
        $raw = '--single-instance=false --class=' + $class + ' --title="D20 ""quoted"" 空間 😀"'
        # The detached GUI does not inherit these captures or the launcher's show flag.
        $stageClock = [Diagnostics.Stopwatch]::StartNew()
        $child = [ComCliNative]::Launch($com, $raw, $BinDir, $desktopPath, 'files', $null, (Join-Path $OutputDir 'gui.stdout.txt'), (Join-Path $OutputDir 'gui.stderr.txt'), 0x08000000, 1, $false)
        $guiChild = $null
        # StageMs: ms since just before the launch, read as each stage ends.
        $close = [ordered]@{ Stage = 'launcher'; StageMs = [ordered]@{}; PostedUtc = $null; PostMs = $null; StartupAtTimeout = $null; JobActiveProcesses = $null; Diagnostics = $null; WaitChains = $null }
        $closePath = Join-Path $OutputDir 'gui-close.json'
        function Save-CloseReceipt {
            try { $close | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $closePath -Encoding utf8NoBOM }
            catch { Write-Warning ('Close receipt write failed: ' + $_.Exception.GetType().FullName) }
        }
        function Read-StartupPhase {
            try {
                # The ready marker replaces this file. Never deny delete sharing.
                $stream = [IO.FileStream]::new((Join-Path $BinDir 'startup-attempts.json'), [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                try { $reader = [IO.StreamReader]::new($stream); try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() } }
                finally { $stream.Dispose() }
                $ledger = $text | ConvertFrom-Json
                $attempt = @($ledger.attempts)[-1]
                return @{ SampledUtc = [datetime]::UtcNow.ToString('o'); Phase = $attempt.phase; StartedUnixMs = $attempt.started_at_unix_ms; ReadyUnixMs = $attempt.ready_at_unix_ms; LastWin32Error = $attempt.last_win32_error; AttemptCount = @($ledger.attempts).Count; UnresolvedCount = @($ledger.attempts | Where-Object { $null -eq $_.ready_at_unix_ms -and $null -eq $_.opengl_unavailable_at_unix_ms }).Count }
            } catch { return @{ ErrorType = $_.Exception.GetType().FullName } }
        }
        try {
            Assert-Condition ($child.Wait(5000)) 'No-action launcher did not return within 5 seconds.'
            Assert-Condition ($child.ExitCode -eq 0) 'No-action launcher returned nonzero.'
            $close.StageMs.LauncherReturn = $stageClock.Elapsed.TotalMilliseconds
            $close.Stage = 'host-window'
            Wait-Condition { @([ComCliNative]::Windows($desktopHandle, 'noctty.win32.host')).Count -eq 1 } 'GUI host on the hidden desktop'
            $window = @([ComCliNative]::Windows($desktopHandle, 'noctty.win32.host'))[0]
            $guiChild = [ComCliNative]::WindowProcess($window, $gui, $child)
            $close.StageMs.HostWindow = $stageClock.Elapsed.TotalMilliseconds
            $close.Stage = 'title'
            Wait-Condition { [ComCliNative]::Title($window).Contains('D20 "quoted" 空間 😀') } 'Unicode/doubled-quote title readback'
            $close.StageMs.Title = $stageClock.Elapsed.TotalMilliseconds
            $close.Stage = 'visibility'
            Wait-Condition { [ComCliNative]::IsWindowVisible($window) } 'GUI host window visible'
            $close.StageMs.Visible = $stageClock.Elapsed.TotalMilliseconds
            $close.Stage = 'gui-alive'
            Assert-Condition (-not $guiChild.Exited) 'GUI exited together with the launcher.'
            $close.Stage = 'post-close'
            $close.PostedUtc = [datetime]::UtcNow.ToString('o')
            $closeClock = [Diagnostics.Stopwatch]::StartNew()
            Assert-Condition ([ComCliNative]::PostMessageW($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) 'WM_CLOSE failed.'
            $close.PostMs = $closeClock.Elapsed.TotalMilliseconds
            $close.StageMs.Post = $stageClock.Elapsed.TotalMilliseconds
            $close.Stage = 'process-exit'
            $exited = $guiChild.Wait($TimeoutSeconds * 1000)
            if (-not $exited) {
                $close.Stage = 'close-timeout'
                $close.StartupAtTimeout = Read-StartupPhase
                Save-CloseReceipt
                try { $close.JobActiveProcesses = [ComCliNative]::ActiveProcesses($child) }
                catch { $close.JobActiveProcesses = @{ ErrorType = $_.Exception.GetType().FullName } }
                try { $close.Diagnostics = [ComCliNative]::CloseDiagnostics($guiChild, $desktopHandle, $window) }
                catch { $close.Diagnostics = @{ ErrorType = $_.Exception.GetType().FullName } }
                Save-CloseReceipt
                try { $close.WaitChains = [ComCliNative]::CloseWaitChains($guiChild, 5000) }
                catch { $close.WaitChains = @{ ErrorType = $_.Exception.GetType().FullName } }
            }
            Assert-Condition $exited 'Owned GUI did not close; see gui-close.json for startup, host state and bounded thread wait chains.'
            $close.StageMs.ProcessExit = $stageClock.Elapsed.TotalMilliseconds
            $close.Stage = 'job-empty'
            Assert-JobEmpty $child 'closing the GUI'
            $close.StageMs.JobEmpty = $stageClock.Elapsed.TotalMilliseconds
            $close.Stage = 'passed'
        } finally {
            Save-CloseReceipt
            if ($guiChild) { $guiChild.Dispose() }; $child.Dispose()
        }
    }
} finally {
    [void][ComCliNative]::CloseDesktop($desktopHandle)
}
