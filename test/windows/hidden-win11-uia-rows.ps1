#requires -Version 7.0
<#
.SYNOPSIS
Read the terminal's UIA TextPattern from its private desktop through a scroll,
history erasure, and an append across page boundaries.
.DESCRIPTION
The client posts only a navigation key to the owned surface. The fixture shell
generates the VT output. The UIA client only reads ranges and their geometry.
#>
[CmdletBinding()]
param(
    [string] $MeasureRepo,
    [Parameter(Mandatory)] [string] $Run,
    [string] $Bin,
    [string] $DesktopName,
    [switch] $Driver
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
$desktopPrefix = 'noctty-uia-rows-'
if (-not $Driver) {
    . (Join-Path $PSScriptRoot '..\..\scripts\interactive-win11-measure-lib.ps1')
    $exe = Get-InteractiveWin11MeasureExePath -RepoRoot $MeasureRepo
    Assert-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo -ExePath $exe
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin (Split-Path -Parent $exe) -Run $Run `
        -DesktopPrefix $desktopPrefix -TimeoutSeconds 150 -Label 'UIA rows' -PassDesktopName -GuardClipboard -OmitIcon
    exit
}

Assert-LocalHiddenFixture $Bin $Run $DesktopName $desktopPrefix
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
$env:XDG_STATE_HOME = $env:LOCALAPPDATA
$env:XDG_CONFIG_HOME = $env:LOCALAPPDATA
$env:XDG_CACHE_HOME = $env:LOCALAPPDATA
$env:USERPROFILE = $Run
$env:HOME = $Run
$cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$producer = Join-Path $Run 'rows.ps1'
$exe = Join-Path $Bin 'noctty.exe'
$desktop = "WinSta0\$DesktopName"
$beforeLast = 96
# With at least 80 columns at the configured 100-column window size, both
# baseline pages hold fewer than 600 rows (215 * 215 / 80 is an upper bound
# for the standard grid capacity). This append cannot remain on one page.
$afterLast = 1200
$script:checks = [Collections.Generic.List[object]]::new()
$samples = [ordered]@{}

@'
param([int] $BeforeLast, [int] $AfterLast)
$ErrorActionPreference = 'Stop'
function Wait-Step([string] $Name) {
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    $path = Join-Path $PSScriptRoot "$Name.go"
    while (-not [IO.File]::Exists($path)) {
        if ([datetime]::UtcNow -ge $deadline) { exit 3 }
        Start-Sleep -Milliseconds 20
    }
}
function Write-Rows([string] $Label, [int] $Count) {
    $text = (1..$Count | ForEach-Object { 'ROW {0:D4} {1}' -f $_, $Label }) -join "`r`n"
    [Console]::Write($text)
}
Write-Rows 'before' $BeforeLast
Wait-Step 'erase'
[Console]::Write("`e[3J|erased")
Wait-Step 'append'
[Console]::Write("`r`n")
Write-Rows 'after' $AfterLast
Wait-Step 'stop'
'@ | Set-Content -LiteralPath $producer

@(
    "command = direct:$cmd /D", "working-directory = $Run", 'shell-integration = none', 'clipboard-read = deny',
    'clipboard-write = deny', 'copy-on-select = false', 'confirm-close-surface = false',
    'auto-update = off', 'desktop-notifications = false', 'window-width = 100', 'window-height = 16',
    'scroll-to-bottom = output', 'scrollback-limit = 8388608', 'keybind = clear',
    'keybind = f8=scroll_page_lines:-5'
) | Set-Content -LiteralPath (Join-Path $Bin 'config.ghostty')

function Get-FixtureRows([string] $Text, [string] $Label, [switch] $Erased) {
    $lines = @($Text.TrimEnd("`r", "`n") -split '\r?\n')
    $numbers = [Collections.Generic.List[int]]::new()
    foreach ($line in $lines) {
        $pattern = '\AROW ([0-9]{4}) ' + $Label + $(if ($Erased) { '(?:\|erased)?' } else { '' }) + '\z'
        $match = [regex]::Match($line.TrimEnd(' '), $pattern)
        if (-not $match.Success) { return $null }
        $number = [int] $match.Groups[1].Value
        if ($numbers.Count -gt 0 -and $number -ne (1 + $numbers[-1])) { return $null }
        $numbers.Add($number)
    }
    return @{ First = $numbers[0]; Last = $numbers[-1]; Count = $numbers.Count }
}

function Get-VisibleTextRange($Pattern) {
    $ranges = @($Pattern.GetVisibleRanges())
    if ($ranges.Count -eq 1) { return $ranges[0] }
}

$pi = $null
$stage = 'start'
$failure = $null
try {
    $line = '"{0}" --single-instance=false --window-save-state=never -e "{1}" -NoLogo -NoProfile -NonInteractive -File "{2}" {3} {4}' -f `
        $exe, $pwsh, $producer, $beforeLast, $afterLast
    $pi = [HiddenLocal]::Spawn($exe, $line, $Run, $desktop)
    if (-not (Wait-Until { @([HiddenLocal]::Hosts($pi.pid)).Count -eq 1 } 30)) { throw 'Expected one owned host.' }
    $hostWindow = @([HiddenLocal]::Hosts($pi.pid))[0]
    if ([HiddenLocal]::WindowDesktop($hostWindow) -cne $DesktopName) { throw 'Unexpected host desktop.' }
    if (-not (Wait-Until { @([HiddenLocal]::Surfaces($hostWindow)).Count -eq 1 } 15)) { throw 'Expected one owned surface.' }
    $pane = @([HiddenLocal]::Surfaces($hostWindow))[0]
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($pane)
    $pattern = $null
    if ($element.Current.ProcessId -ne $pi.pid -or
        -not $element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
        throw 'The owned surface did not expose TextPattern.'
    }

    $stage = 'before'
    if (-not (Wait-Until {
        $script:lastText = $pattern.DocumentRange.GetText(-1)
        $script:lastRows = Get-FixtureRows $script:lastText 'before'
        $script:lastRows.First -eq 1 -and $script:lastRows.Last -eq $beforeLast
    } 25)) { throw 'Initial document did not contain the complete fixture.' }
    $samples.BeforeDocument = $script:lastRows
    $before = Get-FixtureRows ((Get-VisibleTextRange $pattern).GetText(-1)) 'before'
    if ($before.Last -ne $beforeLast -or $before.First -le 6) { throw 'Initial viewport did not end at the fixture tail.' }
    $samples.BeforeVisible = $before

    $stage = 'scroll'
    [HiddenLocal]::PostSurfaceKey($pane, $pi.pid, $DesktopName, 119) # F8
    if (-not (Wait-Until {
        $script:held = Get-VisibleTextRange $pattern
        $script:lastRows = Get-FixtureRows ($script:held.GetText(-1)) 'before'
        $script:lastRows.First -eq ($before.First - 5) -and $script:lastRows.Last -eq ($before.Last - 5)
    } 10)) { throw 'The viewport did not move up five fixture rows.' }
    $samples.ScrolledVisible = $script:lastRows
    $sameDocument = Get-FixtureRows ($pattern.DocumentRange.GetText(-1)) 'before'
    Check 'viewport motion preserves document numbering' ($sameDocument.First -eq 1 -and $sameDocument.Last -eq $beforeLast) $samples.BeforeDocument $sameDocument
    $initialRectangles = @($script:held.GetBoundingRectangles()).Count
    Check 'fresh visible range has geometry' ($initialRectangles -gt 0) 'nonempty' $initialRectangles

    $stage = 'erase'
    [IO.File]::WriteAllText((Join-Path $Run 'erase.go'), '')
    if (-not (Wait-Until {
        $script:lastText = $pattern.DocumentRange.GetText(-1)
        $script:lastRows = Get-FixtureRows $script:lastText 'before' -Erased
        $script:lastText.Contains('|erased') -and $script:lastRows.First -eq $before.First -and $script:lastRows.Last -eq $beforeLast
    } 10)) { throw 'History erase did not leave exactly the active numbered rows.' }
    $samples.ErasedDocument = $script:lastRows
    $staleRectangles = @($script:held.GetBoundingRectangles()).Count
    Check 'range over erased history loses geometry' ($staleRectangles -eq 0) 0 $staleRectangles

    $stage = 'append'
    [IO.File]::WriteAllText((Join-Path $Run 'append.go'), '')
    $afterFirstVisible = $afterLast - $before.Count + 1
    if (-not (Wait-Until {
        $script:lastText = $pattern.DocumentRange.GetText(-1)
        $script:lastRows = Get-FixtureRows $script:lastText 'after'
        $script:lastRows.Last -eq $afterLast -and $script:lastRows.Count -gt $before.Count
    } 25)) { throw 'The document did not expose a contiguous suffix of the appended rows.' }
    $samples.AppendedDocument = $script:lastRows
    $freshRange = Get-VisibleTextRange $pattern
    $fresh = Get-FixtureRows ($freshRange.GetText(-1)) 'after'
    $samples.AppendedVisible = $fresh
    Check 'fresh viewport maps to the appended tail' ($fresh.First -eq $afterFirstVisible -and $fresh.Last -eq $afterLast) `
        @{ First = $afterFirstVisible; Last = $afterLast } $fresh
    $freshRectangles = @($freshRange.GetBoundingRectangles()).Count
    Check 'fresh appended range has geometry' ($freshRectangles -gt 0) 'nonempty' $freshRectangles
    # Feed the held snapshot through the same post-append oracle. A stale
    # read cannot pass merely because it is still nonempty or has valid text.
    $stale = Get-FixtureRows ($script:held.GetText(-1)) 'after'
    Check 'stale control fails the fresh row oracle' (-not ($stale.First -eq $afterFirstVisible -and $stale.Last -eq $afterLast)) `
        'rejected' $stale
    [IO.File]::WriteAllText((Join-Path $Run 'stop.go'), '')
} catch {
    $failure = @{ Stage = $stage; Type = $_.Exception.GetType().Name; Line = $_.InvocationInfo.ScriptLineNumber }
} finally {
    if ($null -ne $pi) {
        [void] [HiddenLocal]::CloseHandle($pi.thread)
        [void] [HiddenLocal]::CloseHandle($pi.process)
    }
}
$passed = $null -eq $failure -and @($script:checks | Where-Object { -not $_.Passed }).Count -eq 0
@{ Passed = $passed; Checks = $script:checks.ToArray(); Samples = $samples; Failure = $failure } |
    ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $Run 'checks.json')
if (-not $passed) { exit 1 }
