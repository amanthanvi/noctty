param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 18
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_IME_CANDIDATE_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_IME_CANDIDATE_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win11ImeCandidateNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

}
'@

$CFS_POINT = 0x0002
$CFS_EXCLUDE = 0x0080
$SMTO_ABORTIFHUNG = 0x0002
$SW_RESTORE = 9
$WM_MOUSEMOVE = 0x0200
$WM_IME_STARTCOMPOSITION = 0x010D
$WM_IME_ENDCOMPOSITION = 0x010E
$surfaceClassName = 'winghostty.win32'
$hostClassName = 'winghostty.win32.host'
$poisonX = 7
$poisonY = 11

function New-LParam {
    param(
        [Parameter(Mandatory)] [int] $X,
        [Parameter(Mandatory)] [int] $Y
    )

    return [IntPtr] [int32] (((($Y -band 0xffff) -shl 16) -bor ($X -band 0xffff)) -band 0xffffffff)
}

function Get-WindowClassName {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $builder = [System.Text.StringBuilder]::new(256)
    [void] [Win11ImeCandidateNative]::GetClassNameW($Hwnd, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Find-HostWindow {
    param(
        [Parameter(Mandatory)] [int] $ProcessId
    )

    $script:Win11ImeCandidateTargetProcessId = [uint32] $ProcessId
    $script:Win11ImeCandidateFoundHost = [IntPtr]::Zero
    $callback = [Win11ImeCandidateNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        $windowProcessId = [uint32] 0
        [void] [Win11ImeCandidateNative]::GetWindowThreadProcessId($hwnd, [ref] $windowProcessId)
        if ($windowProcessId -ne $script:Win11ImeCandidateTargetProcessId) {
            return $true
        }

        if ((Get-WindowClassName -Hwnd $hwnd) -eq $hostClassName) {
            $script:Win11ImeCandidateFoundHost = $hwnd
            return $false
        }

        return $true
    }

    [void] [Win11ImeCandidateNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:Win11ImeCandidateFoundHost
}

function Find-SurfaceWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $script:Win11ImeCandidateFoundSurface = [IntPtr]::Zero
    $callback = [Win11ImeCandidateNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if ((Get-WindowClassName -Hwnd $hwnd) -eq $surfaceClassName) {
            $script:Win11ImeCandidateFoundSurface = $hwnd
            return $false
        }

        return $true
    }

    [void] [Win11ImeCandidateNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $script:Win11ImeCandidateFoundSurface
}

function Get-ClientRectObject {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $rect = [Win11ImeCandidateNative+RECT]::new()
    if (-not [Win11ImeCandidateNative]::GetClientRect($Hwnd, [ref] $rect)) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetClientRect failed for hwnd=$Hwnd (error=$lastError)"
    }

    return [pscustomobject]@{
        Left = $rect.Left
        Top = $rect.Top
        Right = $rect.Right
        Bottom = $rect.Bottom
        Width = [Math]::Max(0, $rect.Right - $rect.Left)
        Height = [Math]::Max(0, $rect.Bottom - $rect.Top)
    }
}

function Send-WindowMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint32] $Message,
        [UIntPtr] $WParam = [UIntPtr]::Zero,
        [IntPtr] $LParam = [IntPtr]::Zero,
        [string] $Description = 'window message'
    )

    $result = [UIntPtr]::Zero
    $status = [Win11ImeCandidateNative]::SendMessageTimeoutW(
        $Hwnd,
        $Message,
        $WParam,
        $LParam,
        [uint32] $SMTO_ABORTIFHUNG,
        [uint32] 1000,
        [ref] $result
    )
    if ($status -eq [IntPtr]::Zero) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SendMessageTimeoutW failed for $Description (hwnd=$Hwnd msg=$Message error=$lastError)"
    }
}

function Read-ImeFormTrace {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) {
            return $null
        }

        return $content | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-ScaledImeCoord {
    param(
        [Parameter(Mandatory)] [double] $Value,
        [Parameter(Mandatory)] [double] $Scale
    )

    return [int] [Math]::Truncate($Value * $Scale)
}

function Assert-ImeCandidateAnchoredToCaret {
    param(
        [Parameter(Mandatory)] $Forms,
        [Parameter(Mandatory)] $ImePos,
        [Parameter(Mandatory)] $ContentScale,
        [Parameter(Mandatory)] $SurfaceClientRect
    )

    $composition = $Forms.Composition
    $candidate = $Forms.Candidate
    $expectedCaretHeight = [Math]::Max(1, (Get-ScaledImeCoord -Value $ImePos.height -Scale $ContentScale.y))
    $expectedRectTop = $candidate.rcArea.Bottom - $expectedCaretHeight

    if ($composition.dwStyle -ne $CFS_POINT) {
        throw "composition form style was $($composition.dwStyle), expected CFS_POINT"
    }
    if ($candidate.dwIndex -ne 0) {
        throw "candidate form index was $($candidate.dwIndex), expected 0"
    }
    if ($candidate.dwStyle -ne $CFS_EXCLUDE) {
        throw "candidate form style was $($candidate.dwStyle), expected CFS_EXCLUDE"
    }
    if ($candidate.ptCurrentPos.X -ne $composition.ptCurrentPos.X -or
        $candidate.ptCurrentPos.Y -ne $composition.ptCurrentPos.Y) {
        throw "composition and candidate points diverged: composition=$($composition.ptCurrentPos.X),$($composition.ptCurrentPos.Y) candidate=$($candidate.ptCurrentPos.X),$($candidate.ptCurrentPos.Y)"
    }

    if ($candidate.rcArea.Left -ne $candidate.ptCurrentPos.X -or
        $candidate.rcArea.Right -ne ($candidate.ptCurrentPos.X + 1) -or
        $candidate.rcArea.Bottom -ne $candidate.ptCurrentPos.Y -or
        $candidate.rcArea.Top -ne $expectedRectTop) {
        throw "candidate exclusion rect is not caret-shaped: point=$($candidate.ptCurrentPos.X),$($candidate.ptCurrentPos.Y) rect=$($candidate.rcArea.Left),$($candidate.rcArea.Top),$($candidate.rcArea.Right),$($candidate.rcArea.Bottom) expected-top=$expectedRectTop caret-height=$expectedCaretHeight"
    }

    if ($candidate.ptCurrentPos.X -lt 120 -or $candidate.ptCurrentPos.Y -lt 120) {
        throw "candidate point stayed near the surface origin instead of the scripted caret: point=$($candidate.ptCurrentPos.X),$($candidate.ptCurrentPos.Y)"
    }

    $poisonRadius = 40
    if ([Math]::Abs($candidate.ptCurrentPos.X - $poisonX) -le $poisonRadius -and
        [Math]::Abs($candidate.ptCurrentPos.Y - $poisonY) -le $poisonRadius) {
        throw "candidate point followed the poisoned mouse coordinate: point=$($candidate.ptCurrentPos.X),$($candidate.ptCurrentPos.Y) poison=$poisonX,$poisonY"
    }

    $outerSlop = 4
    if ($candidate.ptCurrentPos.X -lt (-$outerSlop) -or
        $candidate.ptCurrentPos.Y -lt (-$outerSlop) -or
        $candidate.ptCurrentPos.X -gt ($SurfaceClientRect.Width + $outerSlop) -or
        $candidate.ptCurrentPos.Y -gt ($SurfaceClientRect.Height + $outerSlop)) {
        throw "candidate point is outside the surface client rect: point=$($candidate.ptCurrentPos.X),$($candidate.ptCurrentPos.Y) surface=$($SurfaceClientRect.Width)x$($SurfaceClientRect.Height)"
    }
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'ime-candidate' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-ime-candidate-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-ime-candidate-stderr.log'
$configPath = Join-Path $layout.Temp 'interactive-win11-ime-candidate.conf'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-ime-candidate-payload.ps1'
$readyPath = Join-Path $layout.Temp 'interactive-win11-ime-candidate-ready.txt'
$tracePath = Join-Path $layout.Temp 'interactive-win11-ime-candidate-trace.json'
$resultPath = Join-Path $layout.Temp 'interactive-win11-ime-candidate-result.json'
$instanceClass = "winghostty-ime-candidate-$($layout.SandboxId)"

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

@"
window-width = 100
window-height = 30
confirm-close-surface = false
font-size = 16
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

$readyPathLiteral = $readyPath.Replace("'", "''")
@"
`$esc = [char] 27
[Console]::Write("`$esc[2J`$esc[H")
for (`$row = 1; `$row -le 16; `$row++) {
    [Console]::Write(("ime anchor row {0:D2} 0123456789012345678901234567890123456789`r`n" -f `$row))
}
[Console]::Write("`$esc[12;30H")
'ready' | Set-Content -LiteralPath '$readyPathLiteral' -Encoding ASCII
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $readyPath, $tracePath, $resultPath -ErrorAction SilentlyContinue

$launchArgs = @(
    '--single-instance=false'
    "--class=$instanceClass"
    "--config-file=$configPath"
    '-e'
    'powershell.exe'
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $payloadPath
)

$previousImeTraceFile = $env:WINGHOSTTY_WIN32_IME_FORM_TRACE_FILE
$env:WINGHOSTTY_WIN32_IME_FORM_TRACE_FILE = $tracePath

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$successPattern = 'started subcommand path='
$runtimeFailurePattern = 'paint redraw failed|InvalidValue|surface closed|panic: reached unreachable code|error starting IO thread:'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$forms = $null
$surfaceRect = $null
$surfaceHwnd = [IntPtr]::Zero

try {
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'host window' -Process $process -Condition {
        (Find-HostWindow -ProcessId $process.Id) -ne [IntPtr]::Zero
    }

    $hostHwnd = Find-HostWindow -ProcessId $process.Id
    [void] [Win11ImeCandidateNative]::ShowWindow($hostHwnd, $SW_RESTORE)
    [void] [Win11ImeCandidateNative]::SetForegroundWindow($hostHwnd)

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'surface child window' -Process $process -Condition {
        (Find-SurfaceWindow -Parent $hostHwnd) -ne [IntPtr]::Zero
    }

    $surfaceHwnd = Find-SurfaceWindow -Parent $hostHwnd
    [void] [Win11ImeCandidateNative]::SetFocus($surfaceHwnd)

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'scripted caret readiness' -Process $process -Condition {
        $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
        if ($stderr -match $runtimeFailurePattern) {
            throw "unexpected runtime failure reported before IME probe:`n$stderr"
        }

        $stderr.Contains($successPattern) -and (Test-Path -LiteralPath $readyPath)
    }

    Start-Sleep -Milliseconds 700
    $surfaceRect = Get-ClientRectObject -Hwnd $surfaceHwnd
    if ($surfaceRect.Width -lt 360 -or $surfaceRect.Height -lt 240) {
        throw "surface is too small for stable IME anchor validation: $($surfaceRect.Width)x$($surfaceRect.Height)"
    }

    Send-WindowMessage `
        -Hwnd $surfaceHwnd `
        -Message $WM_MOUSEMOVE `
        -LParam (New-LParam -X $poisonX -Y $poisonY) `
        -Description "poison WM_MOUSEMOVE at $poisonX,$poisonY"

    Send-WindowMessage `
        -Hwnd $surfaceHwnd `
        -Message $WM_IME_STARTCOMPOSITION `
        -Description 'WM_IME_STARTCOMPOSITION'

    $script:Win11ImeCandidateTrace = $null
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'IME form trace' -Process $process -Condition {
        $trace = Read-ImeFormTrace -Path $tracePath
        if ($null -eq $trace) {
            return $false
        }

        $script:Win11ImeCandidateTrace = $trace
        return $true
    }

    $trace = $script:Win11ImeCandidateTrace
    $forms = [pscustomobject]@{
        Composition = $trace.composition
        Candidate = $trace.candidate
    }
    Assert-ImeCandidateAnchoredToCaret `
        -Forms $forms `
        -ImePos $trace.ime_pos `
        -ContentScale $trace.content_scale `
        -SurfaceClientRect $surfaceRect

    $result = [ordered]@{
        surface = @{
            width = $surfaceRect.Width
            height = $surfaceRect.Height
        }
        poison = @{
            x = $poisonX
            y = $poisonY
        }
        imePos = @{
            x = $trace.ime_pos.x
            y = $trace.ime_pos.y
            width = $trace.ime_pos.width
            height = $trace.ime_pos.height
        }
        contentScale = @{
            x = $trace.content_scale.x
            y = $trace.content_scale.y
        }
        composition = @{
            style = $forms.Composition.dwStyle
            x = $forms.Composition.ptCurrentPos.X
            y = $forms.Composition.ptCurrentPos.Y
        }
        candidate = @{
            index = $forms.Candidate.dwIndex
            style = $forms.Candidate.dwStyle
            x = $forms.Candidate.ptCurrentPos.X
            y = $forms.Candidate.ptCurrentPos.Y
            left = $forms.Candidate.rcArea.Left
            top = $forms.Candidate.rcArea.Top
            right = $forms.Candidate.rcArea.Right
            bottom = $forms.Candidate.rcArea.Bottom
        }
    }
    $result | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $resultPath -Encoding ASCII

    [string] $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match $runtimeFailurePattern) {
        throw "unexpected runtime failure reported after IME probe:`n$stderr"
    }
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        try {
            if ($surfaceHwnd -ne [IntPtr]::Zero) {
                Send-WindowMessage `
                    -Hwnd $surfaceHwnd `
                    -Message $WM_IME_ENDCOMPOSITION `
                    -Description 'WM_IME_ENDCOMPOSITION'
            }
        }
        catch {
        }
    }

    Stop-InteractiveWin11Process -Process $process
    if ($null -eq $previousImeTraceFile) {
        Remove-Item Env:WINGHOSTTY_WIN32_IME_FORM_TRACE_FILE -ErrorAction SilentlyContinue
    }
    else {
        $env:WINGHOSTTY_WIN32_IME_FORM_TRACE_FILE = $previousImeTraceFile
    }
}

Write-Host ("interactive-win11 IME candidate validation: PASS (surface={0}x{1}, poison={2},{3}, ime-pos={4},{5},{6},{7}, composition={8},{9}, candidate={10},{11}, exclude={12},{13},{14},{15}, trace={16}, result={17}, stderr={18})" -f $surfaceRect.Width, $surfaceRect.Height, $poisonX, $poisonY, $trace.ime_pos.x, $trace.ime_pos.y, $trace.ime_pos.width, $trace.ime_pos.height, $forms.Composition.ptCurrentPos.X, $forms.Composition.ptCurrentPos.Y, $forms.Candidate.ptCurrentPos.X, $forms.Candidate.ptCurrentPos.Y, $forms.Candidate.rcArea.Left, $forms.Candidate.rcArea.Top, $forms.Candidate.rcArea.Right, $forms.Candidate.rcArea.Bottom, $tracePath, $resultPath, $stderrPath)
