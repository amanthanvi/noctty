[CmdletBinding()]
param(
    [ValidateSet('all', 'throughput', 'cold-start', 'memory', 'idle', 'conpty-rtt', 'key-to-pixel-proxy')]
    [string] $Metric = 'all',
    [ValidateSet('noctty', 'alacritty', 'windows-terminal', 'tabby', 'wave')]
    [string] $Target = 'noctty',
    [ValidateRange(1, 100)] [int] $Runs = 5,
    [string] $OutputPath,
    [string] $ThresholdPath,
    [switch] $Gate,
    [switch] $Rebuild,
    [switch] $ResetState,
    [ValidateRange(10, 300)] [int] $TimeoutSeconds = 30,
    [ValidateRange(10, 500)] [int] $Rows = 45,
    [ValidateRange(20, 500)] [int] $Cols = 140,
    [ValidateRange(6, 72)] [double] $FontSize = 16,
    [ValidateRange(1048576, 1073741824)] [long] $Bytes = 4194304,
    [ValidateRange(1, [uint32]::MaxValue)] [uint32] $Seed = 121,
    [ValidateRange(10, 300)] [int] $IdleSeconds = 10,
    [ValidateRange(1, 5)] [int] $MemoryCycles = 1,
    [switch] $ProfileThroughput
)

$ErrorActionPreference = 'Stop'

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:NOCTTY_BENCH_WINDOWS_BOOTSTRAPPED) {
    $forwardedArgs = @(
        '-Metric', $Metric,
        '-Target', $Target,
        '-Runs', $Runs.ToString(),
        '-Rows', $Rows.ToString(),
        '-Cols', $Cols.ToString(),
        '-FontSize', $FontSize.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-Bytes', $Bytes.ToString(),
        '-Seed', $Seed.ToString(),
        '-IdleSeconds', $IdleSeconds.ToString(),
        '-MemoryCycles', $MemoryCycles.ToString(),
        '-TimeoutSeconds', $TimeoutSeconds.ToString()
    )
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $forwardedArgs += @('-OutputPath', $OutputPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($ThresholdPath)) {
        $forwardedArgs += @('-ThresholdPath', $ThresholdPath)
    }
    if ($Gate) { $forwardedArgs += '-Gate' }
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }
    if ($ProfileThroughput) { $forwardedArgs += '-ProfileThroughput' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'NOCTTY_BENCH_WINDOWS_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

if ($Gate -and $ProfileThroughput) {
    throw '-ProfileThroughput is diagnostic-only and cannot be combined with -Gate'
}

$script:BenchWindowsReadBufferKib = 64

$harness = Initialize-InteractiveWin11Sandbox `
    -RepoRoot $repoRoot `
    -SandboxName "bench-$Target" `
    -ResetState:$ResetState `
    -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $layout.Logs "bench-$Target.json"
}
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $repoRoot $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

if ([string]::IsNullOrWhiteSpace($ThresholdPath)) {
    $ThresholdPath = Join-Path $PSScriptRoot 'bench-thresholds.json'
}
elseif (-not [IO.Path]::IsPathRooted($ThresholdPath)) {
    $ThresholdPath = Join-Path $repoRoot $ThresholdPath
}
$ThresholdPath = [IO.Path]::GetFullPath($ThresholdPath)
$schemaPath = Join-Path $PSScriptRoot 'bench-evidence.schema.json'

if (-not ('NocttyBenchNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class NocttyBenchNative {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [StructLayout(LayoutKind.Explicit, Size = 220, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [FieldOffset(68)] public ushort dmSize;
        [FieldOffset(172)] public uint dmPelsWidth;
        [FieldOffset(176)] public uint dmPelsHeight;
        [FieldOffset(184)] public uint dmDisplayFrequency;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION U;
    }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder value, int capacity);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam, uint flags, uint timeoutMs, out UIntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint mapType);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(POINT point, uint flags);
    [DllImport("shcore.dll")] private static extern int SetProcessDpiAwareness(int awareness);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettingsW(string device, int mode, ref DEVMODE value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplayDevicesW")] private static extern bool EnumDisplayDevicesRaw(string device, uint index, IntPtr value, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplaySettingsW")] private static extern bool EnumDisplaySettingsRaw(string device, int mode, IntPtr value);
    [DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetLogicalProcessorInformationEx(int relationship, IntPtr buffer, ref uint length);

    private static string ClassName(IntPtr hwnd) {
        StringBuilder value = new StringBuilder(256);
        GetClassNameW(hwnd, value, value.Capacity);
        return value.ToString();
    }

    public static IntPtr FindTopLevelWindow(int processId, string className) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr ignored) {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner == (uint)processId && ClassName(hwnd) == className) {
                result = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static IntPtr FindChildWindow(IntPtr parent, string className) {
        IntPtr result = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr hwnd, IntPtr ignored) {
            if (ClassName(hwnd) == className) {
                result = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static bool ForceForeground(IntPtr hwnd) {
        uint ignored;
        uint targetThread = GetWindowThreadProcessId(hwnd, out ignored);
        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, out ignored);
        uint currentThread = GetCurrentThreadId();
        bool foregroundAttached = foregroundThread != 0 && foregroundThread != currentThread && AttachThreadInput(currentThread, foregroundThread, true);
        bool targetAttached = targetThread != 0 && targetThread != currentThread && AttachThreadInput(currentThread, targetThread, true);
        try {
            ShowWindow(hwnd, 9);
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            return GetForegroundWindow() == hwnd;
        }
        finally {
            if (targetAttached) AttachThreadInput(currentThread, targetThread, false);
            if (foregroundAttached) AttachThreadInput(currentThread, foregroundThread, false);
        }
    }

    public static void SendUnicodeText(string text) {
        const uint INPUT_KEYBOARD = 1;
        const uint KEYEVENTF_KEYUP = 0x0002;
        const uint KEYEVENTF_UNICODE = 0x0004;
        INPUT[] inputs = new INPUT[text.Length * 2];
        for (int i = 0; i < text.Length; i++) {
            KEYBDINPUT down = new KEYBDINPUT { wScan = text[i], dwFlags = KEYEVENTF_UNICODE };
            KEYBDINPUT up = down;
            up.dwFlags |= KEYEVENTF_KEYUP;
            inputs[i * 2] = new INPUT { type = INPUT_KEYBOARD, U = new INPUTUNION { ki = down } };
            inputs[i * 2 + 1] = new INPUT { type = INPUT_KEYBOARD, U = new INPUTUNION { ki = up } };
        }
        uint inserted = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (inserted != inputs.Length) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), String.Format("SendInput inserted {0} of {1} keyboard events", inserted, inputs.Length));
        }
    }

    private static uint Next(ref uint state) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    }

    public static void WritePayload(string path, long length, uint seed, string workload, int rows, int cols) {
        uint state = seed == 0 ? 1u : seed;
        byte[] buffer = new byte[65536];
        long written = 0;
        int column = 0;
        using (FileStream stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, buffer.Length, FileOptions.SequentialScan)) {
            while (written < length) {
                int count = (int)Math.Min(buffer.Length, length - written);
                int offset = 0;
                while (offset < count) {
                    uint random = Next(ref state);
                    if (workload == "alt-screen") {
                        string sequence = String.Format("\x1b[{0};{1}H{2}", 1 + random % (uint)rows, 1 + (random >> 8) % (uint)cols, (char)(33 + (random >> 16) % 94));
                        byte[] bytes = Encoding.ASCII.GetBytes(sequence);
                        int available = Math.Min(bytes.Length, count - offset);
                        Array.Copy(bytes, 0, buffer, offset, available);
                        offset += available;
                    }
                    else if (workload == "scroll" && column >= cols - 1) {
                        buffer[offset++] = 10;
                        column = 0;
                    }
                    else {
                        buffer[offset++] = (byte)(33 + random % 94);
                        column++;
                    }
                }
                stream.Write(buffer, 0, count);
                written += count;
            }
        }
    }

    public static int GetPhysicalCoreCount() {
        const int RelationProcessorCore = 0;
        uint length = 0;
        GetLogicalProcessorInformationEx(RelationProcessorCore, IntPtr.Zero, ref length);
        if (length == 0) return 0;
        IntPtr buffer = Marshal.AllocHGlobal((int)length);
        try {
            if (!GetLogicalProcessorInformationEx(RelationProcessorCore, buffer, ref length)) return 0;
            int count = 0;
            int offset = 0;
            while (offset + 8 <= (int)length) {
                int relationship = Marshal.ReadInt32(buffer, offset);
                int size = Marshal.ReadInt32(buffer, offset + 4);
                if (size < 8 || offset + size > (int)length) return 0;
                if (relationship == RelationProcessorCore) count++;
                offset += size;
            }
            return count;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static uint[] GetPrimaryDisplayMode() {
        const int DeviceSize = 840;
        const int ModeSize = 220;
        const uint PrimaryDevice = 0x00000004;
        string primaryName = null;
        IntPtr device = Marshal.AllocHGlobal(DeviceSize);
        try {
            byte[] emptyDevice = new byte[DeviceSize];
            for (uint index = 0; index < 32; index++) {
                Marshal.Copy(emptyDevice, 0, device, DeviceSize);
                Marshal.WriteInt32(device, 0, DeviceSize);
                if (!EnumDisplayDevicesRaw(null, index, device, 0)) break;
                uint stateFlags = unchecked((uint)Marshal.ReadInt32(device, 324));
                if ((stateFlags & PrimaryDevice) != 0) {
                    primaryName = Marshal.PtrToStringUni(IntPtr.Add(device, 4), 32).TrimEnd('\0');
                    break;
                }
            }
        }
        finally { Marshal.FreeHGlobal(device); }

        IntPtr mode = Marshal.AllocHGlobal(ModeSize);
        try {
            Marshal.Copy(new byte[ModeSize], 0, mode, ModeSize);
            Marshal.WriteInt16(mode, 68, (short)ModeSize);
            if (!EnumDisplaySettingsRaw(primaryName, -1, mode)) return new uint[] { 0, 0, 0 };
            return new uint[] {
                unchecked((uint)Marshal.ReadInt32(mode, 172)),
                unchecked((uint)Marshal.ReadInt32(mode, 176)),
                unchecked((uint)Marshal.ReadInt32(mode, 184))
            };
        }
        finally { Marshal.FreeHGlobal(mode); }
    }

    public static uint GetPrimaryDisplayDpi() {
        SetProcessDpiAwareness(2);
        POINT origin = new POINT { X = 0, Y = 0 };
        IntPtr monitor = MonitorFromPoint(origin, 1);
        uint x;
        uint y;
        if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out x, out y) == 0 && x > 0) return x;
        return GetDpiForSystem();
    }
}
'@
}

function Test-BenchMetricRequested {
    param([Parameter(Mandatory)] [string] $Name)
    return $Metric -eq 'all' -or $Metric -eq $Name
}

function Get-BenchMedian {
    param([Parameter(Mandatory)] [double[]] $Samples)
    if ($Samples.Count -eq 0) { return $null }
    $sorted = @($Samples | Sort-Object)
    $middle = [int] [Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double] $sorted[$middle] }
    return ([double] $sorted[$middle - 1] + [double] $sorted[$middle]) / 2.0
}

function Get-BenchPercentile {
    param(
        [Parameter(Mandatory)] [double[]] $Samples,
        [ValidateRange(0, 100)] [double] $Percentile
    )
    if ($Samples.Count -eq 0) { return $null }
    $sorted = @($Samples | Sort-Object)
    if ($Percentile -eq 0) { return [double] $sorted[0] }
    $rank = [int] [Math]::Ceiling(($Percentile / 100.0) * $sorted.Count)
    return [double] $sorted[[Math]::Max(0, $rank - 1)]
}

function New-BenchMetricRecord {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Unit,
        [double[]] $Samples = @(),
        [ValidateSet('pass', 'fail', 'error', 'skip', 'not-supported')] [string] $Status = 'pass',
        [System.Collections.IDictionary] $Details
    )
    $sampleValues = @($Samples | ForEach-Object { [Math]::Round([double] $_, 6) })
    $record = [ordered]@{
        metric = $Name
        status = $Status
        unit = $Unit
        samples = $sampleValues
        median = if ($sampleValues.Count -eq 0) { $null } else { [Math]::Round((Get-BenchMedian -Samples $sampleValues), 6) }
        p95 = if ($sampleValues.Count -eq 0) { $null } else { [Math]::Round((Get-BenchPercentile -Samples $sampleValues -Percentile 95), 6) }
    }
    if ($null -ne $Details) { $record.details = [pscustomobject] $Details }
    return [pscustomobject] $record
}

function New-BenchAdapterRequiredMetric {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Unit,
        [Parameter(Mandatory)] [string] $Capability
    )

    return New-BenchMetricRecord -Name $Name -Unit $Unit -Status not-supported -Details ([ordered]@{
        adapter_requirement = "$Target requires a terminal-specific $Capability adapter"
        comparability_requirement = 'measurement must end at equivalent causal presentation/process-state evidence; producer-only timing is rejected'
        required_tooling = 'terminal render instrumentation or a validated PresentMon ETW adapter with stable process/window ownership'
    })
}

function Get-BenchJsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [DateTime] $Deadline
    )
    $lastError = 'file has not appeared'
    while ([DateTime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $raw = Get-Content -LiteralPath $Path -Raw
                if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw | ConvertFrom-Json }
            }
            catch { $lastError = $_.Exception.Message }
        }
        Start-Sleep -Milliseconds 20
    }
    throw "Timed out waiting for JSON at $Path (last error: $lastError)"
}

function Test-BenchReadableExe {
    param([Parameter(Mandatory)] [string] $Path)

    try {
        $stream = [IO.File]::OpenRead($Path)
        $stream.Dispose()
        return $true
    }
    catch { return $false }
}

function Get-BenchWindowsTerminalCandidate {
    $packages = @(
        Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending
    )
    foreach ($package in $packages) {
        if ([string]::IsNullOrWhiteSpace($package.InstallLocation)) { continue }
        $candidate = Join-Path $package.InstallLocation 'WindowsTerminal.exe'
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-BenchReadableExe -Path $candidate)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-BenchTargetAdapter {
    param([Parameter(Mandatory)] [string] $Name)

    $candidates = switch ($Name) {
        'noctty' { @(Get-InteractiveWin11ExePath -RepoRoot $repoRoot) }
        'alacritty' { @('C:\Program Files\Alacritty\alacritty.exe') }
        'windows-terminal' { @((Get-BenchWindowsTerminalCandidate), 'wt.exe') }
        'tabby' { @('tabby.exe', (Join-Path $env:LOCALAPPDATA 'Programs\Tabby\Tabby.exe')) }
        'wave' { @('wave.exe', (Join-Path $env:LOCALAPPDATA 'Programs\Wave\Wave.exe')) }
    }
    $resolved = $null
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ([IO.Path]::IsPathRooted($candidate)) {
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-BenchReadableExe -Path $candidate)) {
                $resolved = [IO.Path]::GetFullPath($candidate)
                break
            }
        }
        else {
            $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command -and (Test-Path -LiteralPath $command.Source -PathType Leaf) -and (Test-BenchReadableExe -Path $command.Source)) {
                $resolved = $command.Source
                break
            }
        }
    }

    if ($null -eq $resolved -and $Name -eq 'noctty') {
        $resolved = [IO.Path]::GetFullPath($candidates[0])
    }
    if ($null -eq $resolved) {
        return [pscustomobject]@{ Name = $Name; Installed = $false; ExePath = $null; Version = $null }
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        return [pscustomobject]@{ Name = $Name; Installed = $false; ExePath = $resolved; Version = $null }
    }
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($resolved)
    $version = if (-not [string]::IsNullOrWhiteSpace($versionInfo.ProductVersion)) {
        $versionInfo.ProductVersion
    }
    elseif (-not [string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
        $versionInfo.FileVersion
    }
    else { $null }
    if ($Name -eq 'noctty' -and [string]::IsNullOrWhiteSpace($version)) {
        $cliPath = Join-Path (Split-Path -Parent $resolved) 'noctty.com'
        if (Test-Path -LiteralPath $cliPath -PathType Leaf) {
            $versionLine = @(& $cliPath '+version' 2>$null) | Select-Object -First 1
            if ($LASTEXITCODE -eq 0 -and $versionLine -match '^noctty\s+(.+)$') {
                $version = $Matches[1]
            }
        }
    }
    elseif ($Name -eq 'alacritty' -and [string]::IsNullOrWhiteSpace($version)) {
        $stdoutPath = Join-Path $layout.Temp 'alacritty-version-stdout.log'
        $stderrPath = Join-Path $layout.Temp 'alacritty-version-stderr.log'
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
        $versionProcess = Start-Process -FilePath $resolved -ArgumentList '--version' -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
        $versionHandle = $versionProcess.Handle
        if (-not $versionProcess.WaitForExit(5000)) {
            Stop-InteractiveWin11Process -Process $versionProcess -RequireLiveRoot
            throw 'alacritty --version did not exit within 5 seconds'
        }
        $versionProcess.Refresh()
        $versionExitCode = Get-InteractiveWin11ProcessExitCode -Process $versionProcess -ProcessHandle $versionHandle
        $versionLine = @(Get-Content -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
        if ($versionExitCode -eq 0 -and $versionLine -match '^alacritty\s+(.+)$') {
            $version = $Matches[1]
        }
    }
    return [pscustomobject]@{ Name = $Name; Installed = $true; ExePath = $resolved; Version = $version }
}

function Get-BenchTargetArguments {
    param(
        [Parameter(Mandatory)] [string[]] $ChildArguments,
        [Parameter(Mandatory)] [string] $RunName,
        [switch] $EnableAutomation
    )

    switch ($Target) {
        'noctty' {
            $targetArguments = @((Get-InteractiveWin11ContainmentArguments))
            $targetArguments += if ($EnableAutomation) { '--single-instance=true' } else { '--single-instance=false' }
            $targetArguments += @(
                "--class=$script:instanceClass"
                "--config-file=$script:nocttyConfigPath"
            )
            if ($EnableAutomation) { return $targetArguments }
            return $targetArguments + @('-e', 'powershell.exe') + $ChildArguments
        }
        'alacritty' {
            return @('--config-file', $script:alacrittyConfigPath, '-e', 'powershell.exe') + $ChildArguments
        }
        'windows-terminal' {
            return @('-w', "noctty-bench-$RunName", '--size', "$Cols,$Rows", 'new-tab', 'powershell.exe') + $ChildArguments
        }
        'tabby' {
            return @('run', 'powershell.exe') + $ChildArguments
        }
        'wave' {
            return @('-e', 'powershell.exe') + $ChildArguments
        }
    }
}

$processRecords = [Collections.Generic.List[object]]::new()

function Start-BenchTarget {
    param(
        [Parameter(Mandatory)] [string] $RunName,
        [Parameter(Mandatory)] [string] $ChildScript,
        [string[]] $ChildScriptArguments = @(),
        [string] $TracePath,
        [string] $TermioTracePath,
        [string] $MemoryTracePath,
        [string] $AltEndMarker,
        [switch] $LiveTrace,
        [switch] $EnableAutomation
    )

    $stdoutPath = Join-Path $layout.Logs "$RunName-stdout.log"
    $stderrPath = Join-Path $layout.Logs "$RunName-stderr.log"
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($TracePath)) {
        [IO.File]::WriteAllText($TracePath, '', [Text.UTF8Encoding]::new($false))
    }
    if (-not [string]::IsNullOrWhiteSpace($MemoryTracePath)) {
        [IO.File]::WriteAllText($MemoryTracePath, '', [Text.UTF8Encoding]::new($false))
    }
    $childArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ChildScript) + $ChildScriptArguments
    $arguments = @(Get-BenchTargetArguments -ChildArguments $childArguments -RunName $RunName -EnableAutomation:$EnableAutomation)
    $savedTracePath = $env:NOCTTY_RENDER_TRACE_FILE
    $savedTraceLive = $env:NOCTTY_RENDER_TRACE_LIVE
    $savedTermioTracePath = $env:NOCTTY_TERMIO_TRACE_FILE
    $savedMemoryTracePath = $env:NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE
    $savedAltEndMarker = $env:NOCTTY_BENCH_ALT_END_MARKER
    if ($Target -eq 'noctty' -and -not [string]::IsNullOrWhiteSpace($TracePath)) {
        $env:NOCTTY_RENDER_TRACE_FILE = $TracePath
        if ($LiveTrace) { $env:NOCTTY_RENDER_TRACE_LIVE = '1' }
        else { Remove-Item Env:NOCTTY_RENDER_TRACE_LIVE -ErrorAction SilentlyContinue }
    }
    else {
        Remove-Item Env:NOCTTY_RENDER_TRACE_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:NOCTTY_RENDER_TRACE_LIVE -ErrorAction SilentlyContinue
    }
    if ($Target -eq 'noctty') {
        if (-not [string]::IsNullOrWhiteSpace($AltEndMarker)) {
            $env:NOCTTY_BENCH_ALT_END_MARKER = $AltEndMarker
        }
        else { Remove-Item Env:NOCTTY_BENCH_ALT_END_MARKER -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($TermioTracePath)) {
            $env:NOCTTY_TERMIO_TRACE_FILE = $TermioTracePath
        }
        else { Remove-Item Env:NOCTTY_TERMIO_TRACE_FILE -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($MemoryTracePath)) {
            $env:NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE = $MemoryTracePath
        }
        else { Remove-Item Env:NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE -ErrorAction SilentlyContinue }
    }
    else {
        Remove-Item Env:NOCTTY_TERMIO_TRACE_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:NOCTTY_BENCH_ALT_END_MARKER -ErrorAction SilentlyContinue
    }

    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = Start-Process `
            -FilePath $script:adapter.ExePath `
            -ArgumentList $arguments `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
    }
    finally {
        if ($null -eq $savedTracePath) { Remove-Item Env:NOCTTY_RENDER_TRACE_FILE -ErrorAction SilentlyContinue }
        else { $env:NOCTTY_RENDER_TRACE_FILE = $savedTracePath }
        if ($null -eq $savedTraceLive) { Remove-Item Env:NOCTTY_RENDER_TRACE_LIVE -ErrorAction SilentlyContinue }
        else { $env:NOCTTY_RENDER_TRACE_LIVE = $savedTraceLive }
        if ($null -eq $savedTermioTracePath) { Remove-Item Env:NOCTTY_TERMIO_TRACE_FILE -ErrorAction SilentlyContinue }
        else { $env:NOCTTY_TERMIO_TRACE_FILE = $savedTermioTracePath }
        if ($null -eq $savedMemoryTracePath) { Remove-Item Env:NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE -ErrorAction SilentlyContinue }
        else { $env:NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE = $savedMemoryTracePath }        if ($null -eq $savedAltEndMarker) { Remove-Item Env:NOCTTY_BENCH_ALT_END_MARKER -ErrorAction SilentlyContinue }
        else { $env:NOCTTY_BENCH_ALT_END_MARKER = $savedAltEndMarker }
    }
    $startedAt = [DateTime]::UtcNow
    try { $startedAt = $process.StartTime.ToUniversalTime() } catch {}
    $processRecord = [pscustomobject][ordered]@{
        run_name = $RunName
        process_id = [int] $process.Id
        started_at = $startedAt.ToString('o')
        exe_path = [IO.Path]::GetFullPath($script:adapter.ExePath)
        cleanup_method = if ($Target -eq 'noctty') { 'job-contained exact root' } else { 'exact root' }
        exit_confirmed = $false
        exited_at = $null
    }
    $processRecords.Add($processRecord)
    $processHandle = $process.Handle
    return [pscustomobject]@{
        Process = $process
        ProcessRecord = $processRecord
        ProcessHandle = $processHandle
        Stopwatch = $watch
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        TracePath = $TracePath
        TermioTracePath = $TermioTracePath
        MemoryTracePath = $MemoryTracePath
    }
}

function Stop-BenchTarget {
    param([Parameter(Mandatory)] $Run)
    try {
        if ($Target -eq 'noctty') {
            Stop-InteractiveWin11Process -Process $Run.Process -Contained
            return
        }
        $Run.Process.Refresh()
        if ($Run.Process.HasExited) { return }
        try {
            Stop-InteractiveWin11Process -Process $Run.Process -RequireLiveRoot
        }
        catch {
            $Run.Process.Refresh()
            if ($Run.Process.HasExited) { return }
            throw
        }
    }
    finally {
        $Run.Process.Refresh()
        $Run.ProcessRecord.exit_confirmed = [bool] $Run.Process.HasExited
        if ($Run.ProcessRecord.exit_confirmed) {
            $Run.ProcessRecord.exited_at = [DateTime]::UtcNow.ToString('o')
        }
    }
}

function Wait-BenchFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] [string] $Description
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        $Run.Process.Refresh()
        if ($Run.Process.HasExited) {
            throw "$($Run.Process.ProcessName) exited before $Description was observed"
        }
        Start-Sleep -Milliseconds 20
    }
    throw "Timed out waiting for $Description at $Path"
}

function Wait-BenchNocttyWindow {
    param([Parameter(Mandatory)] $Run)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'noctty benchmark host window' -Process $Run.Process -Condition {
        [NocttyBenchNative]::FindTopLevelWindow($Run.Process.Id, 'noctty.win32.host') -ne [IntPtr]::Zero
    }
    return [NocttyBenchNative]::FindTopLevelWindow($Run.Process.Id, 'noctty.win32.host')
}

function New-BenchKeyLParam {
    param(
        [Parameter(Mandatory)] [uint16] $ScanCode,
        [switch] $KeyUp
    )
    [int32] $bits = 1 -bor (($ScanCode -band 0xffff) -shl 16)
    if ($KeyUp) { $bits = $bits -bor (-1073741824) }
    return [IntPtr] $bits
}

function Send-BenchVirtualKeyMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint16] $VirtualKey,
        [Parameter(Mandatory)] [uint16] $CharCode,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [Diagnostics.Process] $Process
    )
    $scanCode = [NocttyBenchNative]::MapVirtualKeyW([uint32] $VirtualKey, 0)
    if ($scanCode -eq 0) { throw "MapVirtualKeyW returned 0 for VK=$VirtualKey" }
    [void](Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message 0x0100 -WParam ([UIntPtr]([uint64] $VirtualKey)) -LParam (New-BenchKeyLParam -ScanCode ([uint16] $scanCode)) -Deadline $Deadline -Process $Process -Description "WM_KEYDOWN vk=$VirtualKey")
    [void](Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message 0x0102 -WParam ([UIntPtr]([uint64] $CharCode)) -LParam (New-BenchKeyLParam -ScanCode ([uint16] $scanCode)) -Deadline $Deadline -Process $Process -Description "WM_CHAR char=$CharCode")
    [void](Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message 0x0101 -WParam ([UIntPtr]([uint64] $VirtualKey)) -LParam (New-BenchKeyLParam -ScanCode ([uint16] $scanCode) -KeyUp) -Deadline $Deadline -Process $Process -Description "WM_KEYUP vk=$VirtualKey")
}

function Invoke-NocttyCli {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    $stdoutPath = Join-Path $layout.Logs "$Name-stdout.log"
    $stderrPath = Join-Path $layout.Logs "$Name-stderr.log"
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
    $cliPath = Join-Path (Split-Path -Parent $script:adapter.ExePath) 'noctty.com'
    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        throw "noctty CLI shim was not found: $cliPath"
    }
    $process = Start-Process -FilePath $cliPath -ArgumentList $Arguments -WorkingDirectory $repoRoot -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $handle = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-InteractiveWin11Process -Process $process -RequireLiveRoot
        throw "noctty CLI $Name timed out"
    }
    $process.Refresh()
    $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $handle
    if ($exitCode -ne 0) {
        throw "noctty CLI $Name failed with exit $exitCode`: $(Get-InteractiveWin11TextFile -Path $stderrPath)"
    }
    return Get-InteractiveWin11TextFile -Path $stdoutPath
}

function Get-NocttyAutomationSnapshot {
    param([Parameter(Mandatory)] [string] $Name)
    $raw = Invoke-NocttyCli -Name $Name -Arguments @('+list-windows', "--class=$script:instanceClass")
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'noctty +list-windows returned empty stdout' }
    return $raw | ConvertFrom-Json
}

function Get-BenchSnapshotSurfaceIds {
    param([Parameter(Mandatory)] $Snapshot)

    return @(
        $Snapshot.windows[0].tabs |
            ForEach-Object { $_.panes } |
            ForEach-Object { [uint64] $_.surface_id }
    )
}

function Assert-BenchExactSurfaceSet {
    param(
        [Parameter(Mandatory)] [uint64[]] $ExpectedSurfaceIds,
        [Parameter(Mandatory)] [uint64[]] $ActualSurfaceIds,
        [Parameter(Mandatory)] [string] $Context
    )

    $expected = @($ExpectedSurfaceIds | Sort-Object -Unique)
    $actual = @($ActualSurfaceIds | Sort-Object -Unique)
    if ($expected.Count -ne $ExpectedSurfaceIds.Count -or $actual.Count -ne $ActualSurfaceIds.Count) {
        throw "$Context surface identity mismatch: duplicate ID in expected or actual set"
    }
    $difference = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual)
    if ($difference.Count -ne 0) {
        throw "$Context surface identity mismatch: expected [$($expected -join ',')], got [$($actual -join ',')]"
    }
}

function Assert-BenchMemoryLifecycleEvidence {
    param(
        [Parameter(Mandatory)] [object[]] $LifecycleSamples,
        [Parameter(Mandatory)] [int] $ExpectedRuns,
        [Parameter(Mandatory)] [int] $MemoryCycles,
        [Parameter(Mandatory)] [int] $AdditionalPanes
    )

    $expectedLifecycleCount = $ExpectedRuns * $MemoryCycles
    if ($LifecycleSamples.Count -ne $expectedLifecycleCount) {
        throw "memory lifecycle expected $expectedLifecycleCount run/cycle records, got $($LifecycleSamples.Count)"
    }
    $expectedCycleKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($runNumber in 1..$ExpectedRuns) {
        foreach ($cycleNumber in 1..$MemoryCycles) {
            [void] $expectedCycleKeys.Add("$runNumber/$cycleNumber")
        }
    }
    $surfaceIdsByRun = @{}
    foreach ($sample in $LifecycleSamples) {
        $cycleKey = "$([int] $sample.run)/$([int] $sample.cycle)"
        if (-not $expectedCycleKeys.Remove($cycleKey)) {
            throw "memory lifecycle contains unexpected or duplicate run/cycle $cycleKey"
        }
        foreach ($propertyName in @(
            'private_bytes_after_each_pane',
            'marginal_private_bytes',
            'created_surface_ids',
            'pane_count_after_each_create',
            'pane_count_after_each_close',
            'survivor_surface_ids_after_each_close'
        )) {
            $values = @($sample.$propertyName)
            if ($values.Count -ne $AdditionalPanes) {
                throw "memory lifecycle $cycleKey '$propertyName' expected exactly $AdditionalPanes entries, got $($values.Count)"
            }
        }
        $runKey = ([int] $sample.run).ToString()
        if (-not $surfaceIdsByRun.ContainsKey($runKey)) {
            $surfaceIdsByRun[$runKey] = [Collections.Generic.HashSet[uint64]]::new()
        }
        foreach ($surfaceId in @($sample.created_surface_ids)) {
            if (-not $surfaceIdsByRun[$runKey].Add([uint64] $surfaceId)) {
                throw "memory lifecycle run $runKey contains duplicate surface ID $surfaceId"
            }
        }
    }
    if ($expectedCycleKeys.Count -ne 0) {
        throw "memory lifecycle is missing expected run/cycle keys: $(@($expectedCycleKeys | Sort-Object) -join ',')"
    }
}

function Get-BenchPrivateBytes {
    param([Parameter(Mandatory)] [Diagnostics.Process] $Process)
    $values = @()
    foreach ($sample in 1..5) {
        $Process.Refresh()
        $values += [double] $Process.PrivateMemorySize64
        Start-Sleep -Milliseconds 200
    }
    return Get-BenchMedian -Samples $values
}

function Test-BenchIntegralNumber {
    param([AllowNull()] [object] $Value)

    return $Value -is [sbyte] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
}

function Get-BenchMemoryStageSamples {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [uint64[]] $CreatedSurfaceIds
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "memory stage trace was not created: $Path"
    }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $records.Add(($line | ConvertFrom-Json))
    }
    if ($records.Count -eq 0) { throw "memory stage trace was empty: $Path" }

    $firstSwapStage = 'first_successful_swap'
    $requiredStages = @(
        'surface_begin'
        'child_hwnd_created'
        'gl_context_created'
        'opengl_functions_loaded'
        'renderer_initialized'
        'terminal_initialized'
        'renderer_thread_spawned'
        'io_thread_spawned'
        'threads_started'
        'io_reader_spawned'
        $firstSwapStage
        'destroy_begin'
        'core_deinit_complete'
        'wgl_context_unbound'
        'wgl_context_deleted'
        'dc_released'
        'surface_destroy_complete'
    )
    $result = [Collections.Generic.List[object]]::new()
    $currentCycleTokens = [Collections.Generic.HashSet[uint64]]::new()
    foreach ($surfaceId in $CreatedSurfaceIds) {
        $idRecords = @($records | Where-Object {
            $null -ne $_.surface_id -and [uint64] $_.surface_id -eq $surfaceId
        })
        $surfaceTokens = @($idRecords | ForEach-Object { [uint64] $_.surface_token } | Sort-Object -Unique)
        if ($surfaceTokens.Count -ne 1) {
            throw "surface $surfaceId expected one memory trace token, got $($surfaceTokens.Count)"
        }
        $surfaceToken = [uint64] $surfaceTokens[0]
        if (-not $currentCycleTokens.Add($surfaceToken)) {
            throw "memory trace token $surfaceToken ambiguously identifies multiple surfaces in the current lifecycle cycle"
        }

        # The token is a process-local allocation address, not a durable
        # identity. Partition its serialized records at surface_begin so a
        # later Surface may reuse the address only after the prior incarnation.
        $tokenIncarnations = [Collections.Generic.List[object]]::new()
        $currentIncarnation = $null
        foreach ($record in $records) {
            if ([uint64] $record.surface_token -ne $surfaceToken) { continue }
            if ([string] $record.stage -ceq 'surface_begin') {
                if ($null -ne $currentIncarnation) {
                    $tokenIncarnations.Add([pscustomobject]@{ records = $currentIncarnation.ToArray() })
                }
                $currentIncarnation = [Collections.Generic.List[object]]::new()
            }
            elseif ($null -eq $currentIncarnation) {
                throw "memory trace token $surfaceToken emitted '$($record.stage)' before surface_begin"
            }
            $currentIncarnation.Add($record)
        }
        if ($null -ne $currentIncarnation) {
            $tokenIncarnations.Add([pscustomobject]@{ records = $currentIncarnation.ToArray() })
        }

        $matchingIncarnations = [Collections.Generic.List[object]]::new()
        foreach ($incarnation in $tokenIncarnations) {
            $incarnationSurfaceIds = @($incarnation.records | Where-Object {
                $null -ne $_.surface_id
            } | ForEach-Object { [uint64] $_.surface_id } | Sort-Object -Unique)
            if ($incarnationSurfaceIds.Count -gt 1) {
                throw "memory trace token $surfaceToken incarnation mixed surface IDs $($incarnationSurfaceIds -join ', ')"
            }
            if ($incarnationSurfaceIds.Count -eq 1 -and [uint64] $incarnationSurfaceIds[0] -eq $surfaceId) {
                $matchingIncarnations.Add($incarnation)
            }
        }
        if ($matchingIncarnations.Count -ne 1) {
            throw "surface $surfaceId expected one memory trace token $surfaceToken incarnation, got $($matchingIncarnations.Count)"
        }
        $surfaceRecords = @($matchingIncarnations[0].records)
        foreach ($stage in $requiredStages) {
            $stageCount = @($surfaceRecords | Where-Object { [string] $_.stage -ceq $stage }).Count
            if ($stageCount -ne 1) {
                throw "surface $surfaceId expected one '$stage' memory snapshot, got $stageCount"
            }
        }

        $traceSequences = [Collections.Generic.List[uint64]]::new()
        foreach ($record in $surfaceRecords) {
            foreach ($propertyName in @(
                'trace_sequence',
                'surface_width_px',
                'surface_height_px',
                'cell_width_px',
                'cell_height_px',
                'columns',
                'rows',
                'wgl_pixel_format_index',
                'wgl_color_bits',
                'wgl_alpha_bits',
                'wgl_depth_bits',
                'wgl_stencil_bits',
                'wgl_double_buffer',
                'wgl_stereo',
                'wgl_accum_bits',
                'wgl_aux_buffers',
                'wgl_selection_source',
                'wgl_srgb_capable',
                'wgl_multisample_query_supported',
                'wgl_sample_buffers',
                'wgl_samples',
                'wgl_total_format_count',
                'wgl_candidate_count'
            )) {
                if ($record.PSObject.Properties.Name -notcontains $propertyName) {
                    throw "surface $surfaceId memory snapshot '$($record.stage)' omitted '$propertyName'"
                }
            }
            if ($null -eq $record.trace_sequence -or [uint64] $record.trace_sequence -eq 0) {
                throw "surface $surfaceId memory snapshot '$($record.stage)' has invalid trace_sequence"
            }
            $traceSequences.Add([uint64] $record.trace_sequence)
        }
        if (@($traceSequences | Sort-Object -Unique).Count -ne $surfaceRecords.Count) {
            throw "surface $surfaceId memory snapshots contain duplicate trace_sequence values"
        }

        $begin = @($surfaceRecords | Where-Object { [string] $_.stage -ceq 'surface_begin' })[0]
        $beginPrivateBytes = [uint64] $begin.private_bytes
        foreach ($stage in $requiredStages) {
            $record = @($surfaceRecords | Where-Object { [string] $_.stage -ceq $stage })[0]
            $requiresWglPixelFormat = $stage -notin @(
                'surface_begin',
                'child_hwnd_created'
            )
            if ($requiresWglPixelFormat) {
                $validPixelFormat =
                    (Test-BenchIntegralNumber -Value $record.wgl_pixel_format_index) -and
                    [uint64] $record.wgl_pixel_format_index -gt 0 -and
                    (Test-BenchIntegralNumber -Value $record.wgl_color_bits) -and
                    [uint64] $record.wgl_color_bits -ge 32 -and
                    [uint64] $record.wgl_color_bits -le 255 -and
                    (Test-BenchIntegralNumber -Value $record.wgl_alpha_bits) -and
                    [uint64] $record.wgl_alpha_bits -ge 8 -and
                    [uint64] $record.wgl_alpha_bits -le 255 -and
                    (Test-BenchIntegralNumber -Value $record.wgl_depth_bits) -and
                    [uint64] $record.wgl_depth_bits -le 255 -and
                    (Test-BenchIntegralNumber -Value $record.wgl_stencil_bits) -and
                    [uint64] $record.wgl_stencil_bits -le 255 -and
                    $record.wgl_double_buffer -is [System.Boolean] -and
                    $record.wgl_double_buffer -and
                    $record.wgl_stereo -is [System.Boolean] -and
                    -not $record.wgl_stereo -and
                    (Test-BenchIntegralNumber -Value $record.wgl_accum_bits) -and
                    [uint64] $record.wgl_accum_bits -le 255 -and
                    (Test-BenchIntegralNumber -Value $record.wgl_aux_buffers) -and
                    [uint64] $record.wgl_aux_buffers -le 255 -and
                    $record.wgl_selection_source -is [string] -and
                    $record.wgl_selection_source -cin @('classic', 'ext_srgb', 'arb_ext_colorspace_srgb', 'arb_srgb') -and
                    $record.wgl_srgb_capable -is [System.Boolean] -and
                    $record.wgl_multisample_query_supported -is [System.Boolean]
                if (-not $validPixelFormat) {
                    throw "surface $surfaceId memory snapshot '$stage' has invalid selected WGL pixel format provenance"
                }
                if ($record.wgl_selection_source -cin @('ext_srgb', 'arb_ext_colorspace_srgb', 'arb_srgb')) {
                    $validExtendedProvenance =
                        $record.wgl_srgb_capable -and
                        (Test-BenchIntegralNumber -Value $record.wgl_total_format_count) -and
                        [uint64] $record.wgl_total_format_count -gt 0 -and
                        (Test-BenchIntegralNumber -Value $record.wgl_candidate_count) -and
                        [uint64] $record.wgl_candidate_count -gt 0 -and
                        [uint64] $record.wgl_candidate_count -le [uint64] $record.wgl_total_format_count
                    if (-not $validExtendedProvenance) {
                        throw "surface $surfaceId memory snapshot '$stage' has invalid WGL sRGB selection provenance"
                    }
                }
                elseif ($record.wgl_srgb_capable -or
                    $null -ne $record.wgl_total_format_count -or
                    $null -ne $record.wgl_candidate_count) {
                    throw "surface $surfaceId memory snapshot '$stage' has contradictory classic WGL selection provenance"
                }
                if ($record.wgl_multisample_query_supported) {
                    if (-not (Test-BenchIntegralNumber -Value $record.wgl_sample_buffers) -or
                        [uint64] $record.wgl_sample_buffers -ne 0 -or
                        -not (Test-BenchIntegralNumber -Value $record.wgl_samples) -or
                        [uint64] $record.wgl_samples -ne 0) {
                        throw "surface $surfaceId memory snapshot '$stage' has invalid multisample exclusion provenance"
                    }
                }
                elseif ($null -ne $record.wgl_sample_buffers -or $null -ne $record.wgl_samples) {
                    throw "surface $surfaceId memory snapshot '$stage' has multisample values without query support"
                }
            }
            if ($stage -in @(
                'terminal_initialized',
                'renderer_thread_spawned',
                'io_thread_spawned',
                'threads_started',
                'io_reader_spawned',
                'first_successful_swap',
                'destroy_begin',
                'core_deinit_complete',
                'wgl_context_unbound',
                'wgl_context_deleted',
                'dc_released',
                'surface_destroy_complete'
            )) {
                if ($null -eq $record.surface_id -or [uint64] $record.surface_id -ne $surfaceId) {
                    throw "surface $surfaceId memory snapshot '$stage' omitted its exact surface identity"
                }
                foreach ($propertyName in @(
                    'surface_width_px',
                    'surface_height_px',
                    'cell_width_px',
                    'cell_height_px',
                    'columns',
                    'rows'
                )) {
                    if ($null -eq $record.$propertyName -or [uint64] $record.$propertyName -eq 0) {
                        throw "surface $surfaceId memory snapshot '$stage' has invalid '$propertyName' geometry"
                    }
                }
            }
            $tick = [uint64] $record.tick_ms
            $privateBytes = [uint64] $record.private_bytes
            $result.Add([pscustomobject][ordered]@{
                stage = $stage
                surface_token = $surfaceToken
                surface_id = if ($null -eq $record.surface_id) { $null } else { [uint64] $record.surface_id }
                private_bytes = $privateBytes
                delta_private_bytes_from_surface_begin = [int64] $privateBytes - [int64] $beginPrivateBytes
                tick_ms = $tick
                trace_sequence = [uint64] $record.trace_sequence
                surface_width_px = if ($null -eq $record.surface_width_px) { $null } else { [uint64] $record.surface_width_px }
                surface_height_px = if ($null -eq $record.surface_height_px) { $null } else { [uint64] $record.surface_height_px }
                cell_width_px = if ($null -eq $record.cell_width_px) { $null } else { [uint64] $record.cell_width_px }
                cell_height_px = if ($null -eq $record.cell_height_px) { $null } else { [uint64] $record.cell_height_px }
                columns = if ($null -eq $record.columns) { $null } else { [uint64] $record.columns }
                rows = if ($null -eq $record.rows) { $null } else { [uint64] $record.rows }
                wgl_pixel_format_index = if ($null -eq $record.wgl_pixel_format_index) { $null } else { [uint64] $record.wgl_pixel_format_index }
                wgl_color_bits = if ($null -eq $record.wgl_color_bits) { $null } else { [uint64] $record.wgl_color_bits }
                wgl_alpha_bits = if ($null -eq $record.wgl_alpha_bits) { $null } else { [uint64] $record.wgl_alpha_bits }
                wgl_depth_bits = if ($null -eq $record.wgl_depth_bits) { $null } else { [uint64] $record.wgl_depth_bits }
                wgl_stencil_bits = if ($null -eq $record.wgl_stencil_bits) { $null } else { [uint64] $record.wgl_stencil_bits }
                wgl_double_buffer = if ($null -eq $record.wgl_double_buffer) { $null } else { [bool] $record.wgl_double_buffer }
                wgl_stereo = if ($null -eq $record.wgl_stereo) { $null } else { [bool] $record.wgl_stereo }
                wgl_accum_bits = if ($null -eq $record.wgl_accum_bits) { $null } else { [uint64] $record.wgl_accum_bits }
                wgl_aux_buffers = if ($null -eq $record.wgl_aux_buffers) { $null } else { [uint64] $record.wgl_aux_buffers }
                wgl_selection_source = if ($null -eq $record.wgl_selection_source) { $null } else { [string] $record.wgl_selection_source }
                wgl_srgb_capable = if ($null -eq $record.wgl_srgb_capable) { $null } else { [bool] $record.wgl_srgb_capable }
                wgl_multisample_query_supported = if ($null -eq $record.wgl_multisample_query_supported) { $null } else { [bool] $record.wgl_multisample_query_supported }
                wgl_sample_buffers = if ($null -eq $record.wgl_sample_buffers) { $null } else { [uint64] $record.wgl_sample_buffers }
                wgl_samples = if ($null -eq $record.wgl_samples) { $null } else { [uint64] $record.wgl_samples }
                wgl_total_format_count = if ($null -eq $record.wgl_total_format_count) { $null } else { [uint64] $record.wgl_total_format_count }
                wgl_candidate_count = if ($null -eq $record.wgl_candidate_count) { $null } else { [uint64] $record.wgl_candidate_count }
            })
        }
    }
    return $result.ToArray()
}

function Get-BenchFileSha256 {
    param([Parameter(Mandatory)] [string] $Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            return [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        }
        finally { $sha256.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Test-BenchUiText {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Text
    )
    try {
        $root = [Windows.Automation.AutomationElement]::FromHandle($Hwnd)
        if ($null -eq $root) { return $false }
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::IsTextPatternAvailableProperty,
            $true
        )
        $elements = @($root.FindAll([Windows.Automation.TreeScope]::Subtree, $condition))
        foreach ($element in $elements) {
            $patternObject = $null
            if ($element.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref] $patternObject)) {
                $value = ([Windows.Automation.TextPattern] $patternObject).DocumentRange.GetText(-1)
                if ($value.Contains($Text)) { return $true }
            }
        }
    }
    catch { return $false }
    return $false
}

function Request-BenchRenderTraceSnapshot {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [uint64] $AfterSequence,
        [Parameter(Mandatory)] [DateTime] $Deadline
    )

    $message = [uint32] (0x8000 + 7)
    [UIntPtr] $messageResult = [UIntPtr]::Zero
    $sent = [NocttyBenchNative]::SendMessageTimeoutW(
        $Hwnd,
        $message,
        [UIntPtr]::Zero,
        [IntPtr]::Zero,
        2,
        5000,
        [ref] $messageResult
    )
    if ($sent -eq [IntPtr]::Zero) {
        throw "failed to request render-trace snapshot synchronously (win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    while ([DateTime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $raw = Get-Content -LiteralPath $Path -Raw
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $snapshot = $raw | ConvertFrom-Json
                    if ([uint64] $snapshot.snapshot_sequence -gt $AfterSequence) { return $snapshot }
                }
            }
            catch {}
        }
        Start-Sleep -Milliseconds 1
    }
    throw "Timed out waiting for a fresh requested render-trace snapshot at $Path"
}

function Wait-BenchSteadyCursorSnapshot {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [uint64] $AfterSequence,
        [Parameter(Mandatory)] [DateTime] $Deadline
    )

    $sequence = $AfterSequence
    do {
        $snapshot = Request-BenchRenderTraceSnapshot -Hwnd $Hwnd -Path $Path -AfterSequence $sequence -Deadline $Deadline
        if ($snapshot.renderer_cursor_blinking -isnot [System.Boolean]) {
            throw 'render trace omitted Boolean renderer_cursor_blinking provenance'
        }
        if (-not $snapshot.renderer_cursor_blinking) { return $snapshot }
        $sequence = [uint64] $snapshot.snapshot_sequence
        Start-Sleep -Milliseconds 20
    } while ([DateTime]::UtcNow -lt $Deadline)

    throw 'renderer snapshot did not observe the requested steady cursor before the deadline'
}

function Wait-BenchIdleQuiescence {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [uint64] $AfterSequence,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [string[]] $CounterNames,
        [ValidateRange(1, 10000)] [int] $QuietMilliseconds = 1500
    )

    $sequence = $AfterSequence
    $previous = $null
    $probeCount = 0
    $settleWatch = [Diagnostics.Stopwatch]::StartNew()
    $quietWatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $snapshot = Request-BenchRenderTraceSnapshot -Hwnd $Hwnd -Path $Path -AfterSequence $sequence -Deadline $Deadline
        $sequence = [uint64] $snapshot.snapshot_sequence
        $probeCount++
        if ($snapshot.renderer_cursor_blinking -isnot [System.Boolean]) {
            throw 'render trace omitted Boolean renderer_cursor_blinking provenance'
        }

        $stable = $null -ne $previous -and -not $snapshot.renderer_cursor_blinking
        foreach ($counterName in $CounterNames) {
            if ($null -eq $snapshot.$counterName -or ($null -ne $previous -and $null -eq $previous.$counterName)) {
                throw "render trace omitted idle quiescence counter $counterName"
            }
            if ($null -eq $previous -or [uint64] $snapshot.$counterName -ne [uint64] $previous.$counterName) {
                $stable = $false
            }
        }
        foreach ($outputName in @('last_swap_process_output_generation', 'last_swap_process_output_bytes')) {
            if ($null -eq $snapshot.$outputName -or ($null -ne $previous -and $null -eq $previous.$outputName)) {
                throw "render trace omitted idle quiescence output field $outputName"
            }
            if ($null -eq $previous -or [uint64] $snapshot.$outputName -ne [uint64] $previous.$outputName) {
                $stable = $false
            }
        }

        if (-not $stable) {
            $quietWatch.Restart()
        }
        elseif ($quietWatch.ElapsedMilliseconds -ge $QuietMilliseconds) {
            $settleWatch.Stop()
            $snapshot | Add-Member -NotePropertyName idle_quiescence_settle_duration_ms -NotePropertyValue ([uint64] $settleWatch.ElapsedMilliseconds)
            $snapshot | Add-Member -NotePropertyName idle_quiescence_probe_count -NotePropertyValue $probeCount
            return $snapshot
        }

        $previous = $snapshot
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $Deadline)

    throw "renderer did not remain quiescent with a steady cursor for $QuietMilliseconds ms before the idle deadline"
}

function Set-BenchRenderTraceTarget {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint64] $OutputBytes
    )

    $message = [uint32] (0x8000 + 8)
    [UIntPtr] $messageResult = [UIntPtr]::Zero
    $sent = [NocttyBenchNative]::SendMessageTimeoutW(
        $Hwnd,
        $message,
        [UIntPtr] $OutputBytes,
        [IntPtr]::Zero,
        2,
        5000,
        [ref] $messageResult
    )
    if ($sent -eq [IntPtr]::Zero) {
        throw "failed to arm render-trace output target synchronously (win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
}

function Wait-BenchUiText {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [Diagnostics.Process] $Process
    )

    while ([DateTime]::UtcNow -lt $Deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { throw "noctty exited before UIA-observable text '$Text'" }
        if (Test-BenchUiText -Hwnd $Hwnd -Text $Text) { return }
        Start-Sleep -Milliseconds 5
    }
    throw "Timed out waiting for UIA-observable text '$Text'"
}

function Invoke-BenchEchoRun {
    param(
        [Parameter(Mandatory)] [string] $RunName,
        [switch] $NeedProxy
    )
    if ($Target -ne 'noctty') { throw "$RunName currently requires noctty's stable Win32 surface/UIA and render-trace contracts" }
    $readyPath = Join-Path $layout.Temp "$RunName-ready.txt"
    $resultPath = Join-Path $layout.Temp "$RunName-result.json"
    $tracePath = Join-Path $layout.Temp "$RunName-render-trace.json"
    Remove-Item -LiteralPath $readyPath, $resultPath, $tracePath -ErrorAction SilentlyContinue
    $nonce = "noctty-bench-$([Guid]::NewGuid().ToString('N'))"
    $run = Start-BenchTarget -RunName $RunName -ChildScript $script:echoScriptPath -ChildScriptArguments @('-ReadyPath', $readyPath, '-ResultPath', $resultPath, '-Nonce', $nonce) -TracePath $tracePath -LiveTrace
    try {
        Wait-BenchFile -Path $readyPath -Run $run -Description 'benchmark echo child readiness'
        $hostHwnd = Wait-BenchNocttyWindow -Run $run
        $surfaceHwnd = [NocttyBenchNative]::FindChildWindow($hostHwnd, 'noctty.win32')
        if ($surfaceHwnd -eq [IntPtr]::Zero) { throw 'noctty surface HWND was not found' }
        $firstTrace = Get-BenchJsonFile -Path $tracePath -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
        if ([uint64] $firstTrace.swap_buffers_count -lt 1) { throw 'initial render trace did not contain a successful swap' }
        $traceSequence = [uint64] $firstTrace.snapshot_sequence
        $baselineSwapCount = [uint64] $firstTrace.swap_buffers_count
        $baselineOutputGeneration = [uint64] $firstTrace.last_swap_process_output_generation
        $baselineOutputBytes = [uint64] $firstTrace.last_swap_process_output_bytes
        $expectedEchoBytes = $baselineOutputBytes + [uint64] [Text.Encoding]::UTF8.GetByteCount($nonce)
        if ($NeedProxy) {
            if (-not [NocttyBenchNative]::ForceForeground($hostHwnd)) { throw 'failed to foreground noctty before SendInput' }
            $foregroundTrace = Request-BenchRenderTraceSnapshot -Hwnd $surfaceHwnd -Path $tracePath -AfterSequence $traceSequence -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
            $traceSequence = [uint64] $foregroundTrace.snapshot_sequence
            $baselineSwapCount = [uint64] $foregroundTrace.swap_buffers_count
            $baselineOutputGeneration = [uint64] $foregroundTrace.last_swap_process_output_generation
            $baselineOutputBytes = [uint64] $foregroundTrace.last_swap_process_output_bytes
            $expectedEchoBytes = $baselineOutputBytes + [uint64] [Text.Encoding]::UTF8.GetByteCount($nonce)
        }

        Set-BenchRenderTraceTarget -Hwnd $surfaceHwnd -OutputBytes $expectedEchoBytes
        $inputTickMs = [NocttyBenchNative]::GetTickCount64()
        $inputQpcTicks = [Diagnostics.Stopwatch]::GetTimestamp()
        if ($NeedProxy) {
            [NocttyBenchNative]::SendUnicodeText('x')
        }
        else {
            Send-BenchVirtualKeyMessage -Hwnd $surfaceHwnd -VirtualKey 0x58 -CharCode 0x78 -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds)) -Process $run.Process
        }
        Wait-BenchFile -Path $resultPath -Run $run -Description 'benchmark echo child result'
        $proxyElapsedMs = $null
        $conptyRttMs = $null
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $liveTrace = Request-BenchRenderTraceSnapshot -Hwnd $surfaceHwnd -Path $tracePath -AfterSequence $traceSequence -Deadline $deadline
            $traceSequence = [uint64] $liveTrace.snapshot_sequence
            if ([uint64] $liveTrace.swap_buffers_count -gt $baselineSwapCount -and
                [uint64] $liveTrace.target_process_output_bytes -eq $expectedEchoBytes -and
                [uint64] $liveTrace.first_target_swap_process_output_generation -gt $baselineOutputGeneration -and
                [uint64] $liveTrace.first_target_swap_process_output_bytes -ge $expectedEchoBytes) {
                $outputTickMs = [uint64] $liveTrace.first_target_swap_process_output_tick_ms
                if ($outputTickMs -lt $inputTickMs) { throw 'causal output generation predates the benchmark input timestamp' }
                $conptyRttMs = [double] ($outputTickMs - $inputTickMs)
                if ($NeedProxy) {
                    $frequency = [uint64] $liveTrace.qpc_frequency
                    if ($frequency -ne [uint64] [Diagnostics.Stopwatch]::Frequency) { throw 'render trace QPC frequency differs from System.Diagnostics.Stopwatch' }
                    $swapQpcTicks = [uint64] $liveTrace.first_target_swap_qpc_ticks
                    if ($swapQpcTicks -lt $inputQpcTicks) { throw 'causal swap predates the benchmark input timestamp' }
                    $proxyElapsedMs = (($swapQpcTicks - $inputQpcTicks) * 1000.0) / $frequency
                }
                break
            }
            $run.Process.Refresh()
            if ($run.Process.HasExited) { throw 'noctty exited before a swap consumed the controlled echo output' }
            Start-Sleep -Milliseconds 5
        }
        if ($null -eq $conptyRttMs) { throw 'render trace did not report a swap that consumed the controlled echo output' }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        Wait-BenchUiText -Hwnd $surfaceHwnd -Text $nonce -Deadline $deadline -Process $run.Process
    }
    finally {
        Stop-BenchTarget -Run $run
    }
    $result = [ordered]@{ ConptyRttMs = $conptyRttMs; ProxyMs = $null; TracePath = $tracePath }
    if ($NeedProxy) {
        $result.ProxyMs = $proxyElapsedMs
    }
    return [pscustomobject] $result
}

function Get-BenchFingerprint {
    $osBuild = $null
    $cpuModel = $null
    $physicalCores = 0
    $logicalCores = [Environment]::ProcessorCount
    $gpuName = $null
    $gpuDriverVersion = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop
        $cpu = Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 1
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        $gpu = $gpus | Sort-Object AdapterRAM -Descending | Select-Object -First 1
        $osBuild = [string] $os.BuildNumber
        $cpuModel = ([string] $cpu.Name).Trim()
        $physicalCores = [int] $cpu.NumberOfCores
        $logicalCores = [int] $cpu.NumberOfLogicalProcessors
        if ($null -ne $gpu) {
            $gpuName = [string] $gpu.Name
            $gpuDriverVersion = [string] $gpu.DriverVersion
        }
    }
    catch {
        $windowsVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $processorKey = Get-Item 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
        $osBuild = if ($null -ne $windowsVersion.UBR) {
            "$($windowsVersion.CurrentBuildNumber).$([int] $windowsVersion.UBR)"
        }
        else { [string] $windowsVersion.CurrentBuildNumber }
        $cpuModel = ([string] $processorKey.GetValue('ProcessorNameString')).Trim()
        $physicalCores = [NocttyBenchNative]::GetPhysicalCoreCount()
        $nvidiaSmi = Get-Command nvidia-smi.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $nvidiaSmi) {
            $nvidiaLine = @(& $nvidiaSmi.Source '--query-gpu=name,driver_version' '--format=csv,noheader' 2>$null) | Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($nvidiaLine)) {
                $nvidiaParts = $nvidiaLine -split ',', 2
                $gpuName = $nvidiaParts[0].Trim()
                if ($nvidiaParts.Count -gt 1) { $gpuDriverVersion = $nvidiaParts[1].Trim() }
            }
        }
        if ([string]::IsNullOrWhiteSpace($gpuName) -or [string]::IsNullOrWhiteSpace($gpuDriverVersion)) {
            $videoKeys = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Video' -ErrorAction SilentlyContinue | ForEach-Object {
                $key = Get-Item (Join-Path $_.PSPath '0000') -ErrorAction SilentlyContinue
                if ($null -ne $key) {
                    [pscustomobject]@{ DriverDesc = $key.GetValue('DriverDesc'); DriverVersion = $key.GetValue('DriverVersion') }
                }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DriverDesc) })
            $video = $videoKeys | Where-Object { $_.DriverDesc -notmatch 'Microsoft.*(Basic|Remote)' } | Select-Object -First 1
            if ($null -ne $video) {
                if ([string]::IsNullOrWhiteSpace($gpuName)) { $gpuName = [string] $video.DriverDesc }
                if ([string]::IsNullOrWhiteSpace($gpuDriverVersion)) { $gpuDriverVersion = [string] $video.DriverVersion }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($osBuild)) { throw 'Unable to resolve the Windows build number' }
    if ([string]::IsNullOrWhiteSpace($cpuModel) -or $physicalCores -le 0 -or $logicalCores -le 0) { throw 'Unable to resolve the CPU model and core counts' }
    if ([string]::IsNullOrWhiteSpace($gpuName) -or [string]::IsNullOrWhiteSpace($gpuDriverVersion)) { throw 'Unable to resolve the GPU name and driver version' }
    $mode = [NocttyBenchNative+DEVMODE]::new()
    $mode.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type] [NocttyBenchNative+DEVMODE])
    [void] [NocttyBenchNative]::EnumDisplaySettingsW($null, -1, [ref] $mode)
    $primaryMode = [NocttyBenchNative]::GetPrimaryDisplayMode()
    if ($primaryMode[0] -gt 0) { $mode.dmPelsWidth = $primaryMode[0] }
    if ($primaryMode[1] -gt 0) { $mode.dmPelsHeight = $primaryMode[1] }
    if ($primaryMode[2] -gt 0) { $mode.dmDisplayFrequency = $primaryMode[2] }
    $power = [NocttyBenchNative+SYSTEM_POWER_STATUS]::new()
    $powerState = if ([NocttyBenchNative]::GetSystemPowerStatus([ref] $power)) {
        switch ($power.ACLineStatus) { 0 { 'battery' } 1 { 'ac' } default { 'unknown' } }
    }
    else { 'unknown' }
    if ($mode.dmDisplayFrequency -le 0) {
        throw 'Unable to resolve a positive primary-display refresh rate'
    }
    return [pscustomobject][ordered]@{
        os_build = $osBuild
        cpu_model = $cpuModel
        physical_cores = $physicalCores
        logical_cores = $logicalCores
        gpu_name = $gpuName
        gpu_driver_version = $gpuDriverVersion
        display = [pscustomobject][ordered]@{
            width_px = if ($mode.dmPelsWidth -gt 0) { [int] $mode.dmPelsWidth } else { [NocttyBenchNative]::GetSystemMetrics(0) }
            height_px = if ($mode.dmPelsHeight -gt 0) { [int] $mode.dmPelsHeight } else { [NocttyBenchNative]::GetSystemMetrics(1) }
            refresh_hz = [double] $mode.dmDisplayFrequency
            dpi_scale_percent = [Math]::Round(([NocttyBenchNative]::GetPrimaryDisplayDpi() / 96.0) * 100.0, 2)
        }
        power_state = $powerState
    }
}

$script:adapter = Get-BenchTargetAdapter -Name $Target
$script:instanceClass = "noctty-bench-$($layout.SandboxId)"
$script:nocttyConfigPath = Join-Path $layout.Temp 'bench-noctty.conf'
$script:alacrittyConfigPath = Join-Path $layout.Temp 'bench-alacritty.toml'
$script:throughputScriptPath = Join-Path $layout.Temp 'bench-throughput-child.ps1'
$script:holdScriptPath = Join-Path $layout.Temp 'bench-hold-child.ps1'
$script:echoScriptPath = Join-Path $layout.Temp 'bench-echo-child.ps1'
$resolvedFont = 'Consolas'
$fontRegistry = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction Stop
if (-not ($fontRegistry.PSObject.Properties.Name -match '^Consolas .*TrueType')) {
    throw 'Required benchmark font face Consolas is not installed'
}

$nocttyConfig = @"
window-width = $Cols
window-height = $Rows
confirm-close-surface = false
font-family = $resolvedFont
font-size = $($FontSize.ToString([Globalization.CultureInfo]::InvariantCulture))
cursor-style-blink = false
undo-timeout = 5s
"@ -replace "`n", "`r`n"
[IO.File]::WriteAllText($script:nocttyConfigPath, $nocttyConfig, [Text.UTF8Encoding]::new($false))
$alacrittyConfig = @"
[window]
dimensions = { columns = $Cols, lines = $Rows }
[font]
size = $($FontSize.ToString([Globalization.CultureInfo]::InvariantCulture))
normal = { family = "$resolvedFont", style = "Regular" }
"@ -replace "`n", "`r`n"
[IO.File]::WriteAllText($script:alacrittyConfigPath, $alacrittyConfig, [Text.UTF8Encoding]::new($false))

$throughputChild = @'
param(
    [Parameter(Mandatory)] [string] $PayloadPath,
    [Parameter(Mandatory)] [string] $ResultPath,
    [Parameter(Mandatory)] [string] $ReadyPath,
    [Parameter(Mandatory)] [string] $GoPath,
    [Parameter(Mandatory)] [string] $ReleasePath,
    [Parameter(Mandatory)] [string] $Workload,
    [string] $EndMarker = ''
)
$output = [Console]::OpenStandardOutput()
$prefix = if ($Workload -eq 'alt-screen') { [Text.Encoding]::ASCII.GetBytes(([char]27) + '[?1049h') } else { [byte[]]@() }
$suffix = if ($Workload -eq 'alt-screen') { [Text.Encoding]::ASCII.GetBytes(([char]27) + '[?1049l') } else { [byte[]]@() }
$marker = if ([string]::IsNullOrWhiteSpace($EndMarker)) { [byte[]]@() } else { [Text.Encoding]::ASCII.GetBytes($EndMarker) }
$markerFrame = if ($marker.Length -gt 0) { [Text.Encoding]::ASCII.GetBytes(([char]27) + '[0m' + ([char]27) + '[1;1H' + ([char]27) + '[2K') } else { [byte[]]@() }
'ready' | Set-Content -LiteralPath $ReadyPath -Encoding ASCII
while (-not (Test-Path -LiteralPath $GoPath -PathType Leaf)) { Start-Sleep -Milliseconds 1 }
$frequency = [Diagnostics.Stopwatch]::Frequency
$started = [Diagnostics.Stopwatch]::GetTimestamp()
if ($prefix.Length -gt 0) { $output.Write($prefix, 0, $prefix.Length) }
try {
    $input = [IO.File]::OpenRead($PayloadPath)
    try { $input.CopyTo($output, 65536) } finally { $input.Dispose() }
    if ($marker.Length -gt 0) {
        $output.Write($markerFrame, 0, $markerFrame.Length)
        $output.Write($marker, 0, $marker.Length)
    }
    $output.Flush()
    $ended = [Diagnostics.Stopwatch]::GetTimestamp()
    [ordered]@{ start_marker_ticks = $started; end_marker_ticks = $ended; frequency = $frequency; elapsed_ms = (($ended - $started) * 1000.0 / $frequency) } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -Encoding ASCII
    while (-not (Test-Path -LiteralPath $ReleasePath -PathType Leaf)) { Start-Sleep -Milliseconds 1 }
}
finally {
    if ($suffix.Length -gt 0) {
        $output.Write($suffix, 0, $suffix.Length)
        $output.Flush()
    }
}
'@
[IO.File]::WriteAllText($script:throughputScriptPath, $throughputChild, [Text.UTF8Encoding]::new($false))

$holdChild = @'
param([Parameter(Mandatory)] [string] $ReadyPath, [switch] $SteadyCursor)
if ($SteadyCursor) {
    $esc = [char]27
    [Console]::Write("$esc[2 q")
    [Console]::Out.Flush()
}
'ready' | Set-Content -LiteralPath $ReadyPath -Encoding ASCII
Start-Sleep -Seconds 300
'@
[IO.File]::WriteAllText($script:holdScriptPath, $holdChild, [Text.UTF8Encoding]::new($false))

$echoChild = @'
param([Parameter(Mandatory)] [string] $ReadyPath, [Parameter(Mandatory)] [string] $ResultPath, [Parameter(Mandatory)] [string] $Nonce)
'ready' | Set-Content -LiteralPath $ReadyPath -Encoding ASCII
$key = [Console]::ReadKey($true)
[Console]::Write($Nonce)
[Console]::Out.Flush()
[ordered]@{ key_char_code = [int][char]$key.KeyChar; nonce = $Nonce } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -Encoding ASCII
Start-Sleep -Seconds 300
'@
[IO.File]::WriteAllText($script:echoScriptPath, $echoChild, [Text.UTF8Encoding]::new($false))

$machine = Get-BenchFingerprint
$commitSha = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commitSha)) { throw 'git rev-parse HEAD failed' }

if ($Target -eq 'noctty') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot -Optimize ReleaseFast
    Assert-InteractiveWin11ExeExists -ExePath $script:adapter.ExePath
    $script:adapter = Get-BenchTargetAdapter -Name $Target
}

$metrics = [Collections.Generic.List[object]]::new()
$measurementErrors = [Collections.Generic.List[string]]::new()

if ($script:adapter.Installed) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    if ($Target -ne 'noctty') {
        if (Test-BenchMetricRequested -Name 'throughput') {
            foreach ($name in @('throughput_mb_s', 'throughput_alt_screen_mb_s', 'scroll_mb_s')) {
                $metrics.Add((New-BenchAdapterRequiredMetric -Name $name -Unit 'MB/s' -Capability 'causal full-consumption successful-present'))
            }
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'frame_time_p95_ms' -Unit 'ms' -Capability 'workload-scoped successful-present interval'))
        }
        if (Test-BenchMetricRequested -Name 'cold-start') {
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'cold_start_harness_ms' -Unit 'ms' -Capability 'first-present'))
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'cold_start_app_ms' -Unit 'ms' -Capability 'process-origin to first-present'))
        }
        if (Test-BenchMetricRequested -Name 'memory') {
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'memory_bytes_per_additional_pane' -Unit 'bytes' -Capability 'pane creation and stable process-tree ownership'))
        }
        if (Test-BenchMetricRequested -Name 'idle') {
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'idle_cpu_percent' -Unit 'percent' -Capability 'stable process-tree ownership'))
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'idle_gpu_percent' -Unit 'percent' -Capability 'stable GPU-engine process ownership'))
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'idle_swap_count_delta' -Unit 'count' -Capability 'successful-present counter'))
        }
        if (Test-BenchMetricRequested -Name 'conpty-rtt') {
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'conpty_rtt_ms' -Unit 'ms' -Capability 'causal terminal-parser acknowledgement'))
        }
        if (Test-BenchMetricRequested -Name 'key-to-pixel-proxy') {
            $metrics.Add((New-BenchAdapterRequiredMetric -Name 'key_to_first_swap_ms_proxy' -Unit 'ms' -Capability 'controlled-echo successful-present acknowledgement'))
        }
    }
    else {
    if (Test-BenchMetricRequested -Name 'throughput') {
        $frameTimeSamples = [Collections.Generic.List[double]]::new()
        $streamWorkloadComplete = $false
        $workloads = @(
            [pscustomobject]@{ Workload = 'stream'; Metric = 'throughput_mb_s' },
            [pscustomobject]@{ Workload = 'alt-screen'; Metric = 'throughput_alt_screen_mb_s' },
            [pscustomobject]@{ Workload = 'scroll'; Metric = 'scroll_mb_s' }
        )
        foreach ($workload in $workloads) {
            $isTransformedAltScreen = $workload.Workload -eq 'alt-screen'
            $completionSignal = if ($isTransformedAltScreen) { 'unique final visible marker parsed and committed by the terminal' } else { 'absolute ConPTY output byte count at baseline plus payload size' }
            $endpoint = if ($isTransformedAltScreen) { 'atomically latched first successful SwapBuffers whose renderer snapshot includes the committed final-marker generation' } else { 'atomically latched first successful SwapBuffers at or above an armed baseline-plus-payload output-byte target' }
            $presentationTarget = if ($isTransformedAltScreen) { 'committed visible end marker' } else { 'full payload byte target' }
            $payloadPath = Join-Path $layout.Temp "bench-$($workload.Workload)-$Bytes-$Seed.bin"
            [NocttyBenchNative]::WritePayload($payloadPath, $Bytes, $Seed, $workload.Workload, $Rows, $Cols)
            $samples = [Collections.Generic.List[double]]::new()
            $diagnosticProfiles = [Collections.Generic.List[object]]::new()
            try {
                if ($Target -ne 'noctty') { throw 'causal consumed-and-presented throughput endpoint is currently available only for noctty' }
                foreach ($runNumber in 1..$Runs) {
                    $name = "$($workload.Workload)-$runNumber"
                    $resultPath = Join-Path $layout.Temp "$name-result.json"
                    $readyPath = Join-Path $layout.Temp "$name-ready.txt"
                    $goPath = Join-Path $layout.Temp "$name-go.txt"
                    $releasePath = Join-Path $layout.Temp "$name-release.txt"
                    $tracePath = Join-Path $layout.Temp "$name-render-trace.json"
                    $termioTracePath = if ($ProfileThroughput) { Join-Path $layout.Temp "$name-termio-trace.json" } else { $null }
                    $endMarker = if ($isTransformedAltScreen) { "NB$([Guid]::NewGuid().ToString('N').Substring(0, 16))" } else { '' }
                    Remove-Item -LiteralPath $resultPath, $readyPath, $goPath, $releasePath, $tracePath -ErrorAction SilentlyContinue
                    if ($null -ne $termioTracePath) { Remove-Item -LiteralPath $termioTracePath -ErrorAction SilentlyContinue }
                    $childScriptArguments = @('-PayloadPath', $payloadPath, '-ResultPath', $resultPath, '-ReadyPath', $readyPath, '-GoPath', $goPath, '-ReleasePath', $releasePath, '-Workload', $workload.Workload)
                    if ($isTransformedAltScreen) { $childScriptArguments += @('-EndMarker', $endMarker) }
                    $run = Start-BenchTarget -RunName $name -ChildScript $script:throughputScriptPath -ChildScriptArguments $childScriptArguments -TracePath $tracePath -TermioTracePath $termioTracePath -AltEndMarker $endMarker -LiveTrace
                    try {
                        Wait-BenchFile -Path $readyPath -Run $run -Description "$($workload.Workload) throughput child readiness"
                        $hostHwnd = Wait-BenchNocttyWindow -Run $run
                        $surfaceHwnd = [NocttyBenchNative]::FindChildWindow($hostHwnd, 'noctty.win32')
                        if ($surfaceHwnd -eq [IntPtr]::Zero) { throw 'noctty surface HWND was not found' }
                        $firstTrace = Get-BenchJsonFile -Path $tracePath -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
                        $initialTrace = Request-BenchRenderTraceSnapshot -Hwnd $surfaceHwnd -Path $tracePath -AfterSequence ([uint64] $firstTrace.snapshot_sequence) -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
                        $traceSequence = [uint64] $initialTrace.snapshot_sequence
                        $baselineOutputBytes = [uint64] $initialTrace.last_swap_process_output_bytes
                        $expectedOutputBytes = if ($isTransformedAltScreen) { [uint64] 0 } else { $baselineOutputBytes + [uint64] $Bytes }
                        Set-BenchRenderTraceTarget -Hwnd $surfaceHwnd -OutputBytes $expectedOutputBytes
                        [IO.File]::WriteAllText($goPath, 'go', [Text.Encoding]::ASCII)
                        Wait-BenchFile -Path $resultPath -Run $run -Description "$($workload.Workload) throughput end marker"
                        $result = Get-BenchJsonFile -Path $resultPath -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
                        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                        $presentedTrace = $null
                        Start-Sleep -Milliseconds 50
                        while ([DateTime]::UtcNow -lt $deadline) {
                            $candidate = Request-BenchRenderTraceSnapshot -Hwnd $surfaceHwnd -Path $tracePath -AfterSequence $traceSequence -Deadline $deadline
                            $traceSequence = [uint64] $candidate.snapshot_sequence
                            $targetPresented = if ($isTransformedAltScreen) {
                                [uint64] $candidate.target_process_output_bytes -eq 0 -and
                                [uint64] $candidate.first_target_swap_benchmark_end_marker_generation -gt 0 -and
                                [uint64] $candidate.first_target_swap_benchmark_end_marker_output_bytes -gt 0
                            }
                            else {
                                [uint64] $candidate.target_process_output_bytes -eq $expectedOutputBytes -and
                                [uint64] $candidate.first_target_swap_process_output_bytes -ge $expectedOutputBytes
                            }
                            if ($targetPresented -and [uint64] $candidate.first_target_swap_qpc_ticks -gt 0) {
                                $presentedTrace = $candidate
                                break
                            }
                            $run.Process.Refresh()
                            if ($run.Process.HasExited) { throw "$name exited before presenting the $presentationTarget" }
                            Start-Sleep -Milliseconds 50
                        }
                        if ($null -eq $presentedTrace) { throw "$name did not report a swap that presented the $presentationTarget" }
                        $frequency = [uint64] $result.frequency
                        if ($frequency -ne [uint64] $presentedTrace.qpc_frequency) { throw "$name child and render trace QPC frequencies differ" }
                        if ($workload.Workload -eq 'stream') {
                            if ([uint64] $presentedTrace.target_swap_interval_overflow_count -ne 0) {
                                throw "$name overflowed the successful-swap interval trace"
                            }
                            $intervals = @($presentedTrace.target_swap_interval_qpc_ticks)
                            if ($intervals.Count -eq 0) { throw "$name did not present two successful swaps inside the armed workload window" }
                            foreach ($intervalTicks in $intervals) {
                                $frameTimeSamples.Add(([double] $intervalTicks * 1000.0 / [double] $frequency))
                            }
                        }
                        $elapsedTicks = [uint64] $presentedTrace.first_target_swap_qpc_ticks - [uint64] $result.start_marker_ticks
                        $elapsedSeconds = [double] $elapsedTicks / [double] $frequency
                        if ($elapsedSeconds -le 0) { throw "$name reported a nonpositive elapsed time" }
                        $samples.Add(($Bytes / 1000000.0) / $elapsedSeconds)
                        [IO.File]::WriteAllText($releasePath, 'release', [Text.Encoding]::ASCII)
                        if ($ProfileThroughput) {
                            Wait-BenchFile -Path $termioTracePath -Run $run -Description "$($workload.Workload) termio diagnostic trace"
                            $termioTrace = Get-BenchJsonFile -Path $termioTracePath -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
                            $diagnosticProfiles.Add([pscustomobject][ordered]@{
                                windows_pty_read_buffer_bytes = [uint64] $termioTrace.windows_pty_read_buffer_bytes
                                windows_pty_read_count = [uint64] $termioTrace.windows_pty_read_count
                                windows_pty_read_bytes = [uint64] $termioTrace.windows_pty_read_bytes
                                windows_pty_read_le_4k_count = [uint64] $termioTrace.windows_pty_read_le_4k_count
                                windows_pty_read_le_16k_count = [uint64] $termioTrace.windows_pty_read_le_16k_count
                                windows_pty_read_le_64k_count = [uint64] $termioTrace.windows_pty_read_le_64k_count
                                windows_pty_read_gt_64k_count = [uint64] $termioTrace.windows_pty_read_gt_64k_count
                                windows_read_file_total_ns = [uint64] $termioTrace.windows_read_file_total_ns
                                windows_read_file_max_ns = [uint64] $termioTrace.windows_read_file_max_ns
                                windows_process_output_total_ns = [uint64] $termioTrace.windows_process_output_total_ns
                                windows_process_output_max_ns = [uint64] $termioTrace.windows_process_output_max_ns
                                renderer_mutex_wait_total_ns = [uint64] $termioTrace.renderer_mutex_wait_total_ns
                                renderer_mutex_wait_max_ns = [uint64] $termioTrace.renderer_mutex_wait_max_ns
                                renderer_mutex_hold_total_ns = [uint64] $termioTrace.renderer_mutex_hold_total_ns
                                renderer_mutex_hold_max_ns = [uint64] $termioTrace.renderer_mutex_hold_max_ns
                                })
                        }
                    }
                    finally {
                        try {
                            if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
                                [IO.File]::WriteAllText($releasePath, 'release', [Text.Encoding]::ASCII)
                            }
                        }
                        finally { Stop-BenchTarget -Run $run }
                    }
                }
                $throughputDetails = [ordered]@{ workload = $workload.Workload; bytes = $Bytes; producer = 'PowerShell FileStream.CopyTo(Console.OpenStandardOutput)'; process_startup_included = $false; endpoint = $endpoint; completion_signal = $completionSignal; conpty_original_input_bytes_expected_to_be_preserved = -not $isTransformedAltScreen; downstream_backpressure_included = $true; render_trace_snapshot_request_observer_included = $false; render_trace_target_observer_included = $true; terminal_visible_marker_observer_included = [bool] $isTransformedAltScreen; termio_trace_observer_included = [bool] $ProfileThroughput; windows_read_buffer_kib = $script:BenchWindowsReadBufferKib; diagnostic_profile_scope = $(if ($ProfileThroughput) { 'process lifetime; ReadFile duration includes blocking before the producer go marker' } else { $null }) }
                if ($ProfileThroughput) { $throughputDetails.diagnostic_profiles = $diagnosticProfiles.ToArray() }
                $metrics.Add((New-BenchMetricRecord -Name $workload.Metric -Unit 'MB/s' -Samples $samples.ToArray() -Details $throughputDetails))
                if ($workload.Workload -eq 'stream') { $streamWorkloadComplete = $true }
            }
            catch {
                $measurementErrors.Add("$($workload.Metric): $($_.Exception.Message)")
                $metrics.Add((New-BenchMetricRecord -Name $workload.Metric -Unit 'MB/s' -Status error -Details ([ordered]@{ workload = $workload.Workload; bytes = $Bytes; producer = 'PowerShell FileStream.CopyTo(Console.OpenStandardOutput)'; process_startup_included = $false; endpoint = $endpoint; completion_signal = $completionSignal; conpty_original_input_bytes_expected_to_be_preserved = -not $isTransformedAltScreen; downstream_backpressure_included = $true; render_trace_snapshot_request_observer_included = $false; render_trace_target_observer_included = $true; terminal_visible_marker_observer_included = [bool] $isTransformedAltScreen; termio_trace_observer_included = [bool] $ProfileThroughput; windows_read_buffer_kib = $script:BenchWindowsReadBufferKib; diagnostic_profile_scope = $(if ($ProfileThroughput) { 'process lifetime; ReadFile duration includes blocking before the producer go marker' } else { $null }); error = $_.Exception.Message })))
            }
        }
        if ($streamWorkloadComplete -and $frameTimeSamples.Count -gt 0) {
            $metrics.Add((New-BenchMetricRecord -Name 'frame_time_p95_ms' -Unit 'ms' -Samples $frameTimeSamples.ToArray() -Details ([ordered]@{ workload = 'stream'; endpoint = 'interval between consecutive successful SwapBuffers after target arm and through the first full-consumption swap'; clock = 'QueryPerformanceCounter'; aggregation = 'nearest-rank p95 over pooled workload-window intervals'; software_observation = $true; compositor_scanout_included = $false; photon_measurement = $false; render_trace_snapshot_request_observer_included = $false })))
        }
        else {
            $frameTimeError = if (-not $streamWorkloadComplete) { 'stream workload did not complete all requested runs' } else { 'stream workload did not produce frame interval samples' }
            $metrics.Add((New-BenchMetricRecord -Name 'frame_time_p95_ms' -Unit 'ms' -Status error -Details ([ordered]@{ workload = 'stream'; endpoint = 'interval between consecutive successful SwapBuffers after target arm and through the first full-consumption swap'; clock = 'QueryPerformanceCounter'; aggregation = 'nearest-rank p95 over pooled workload-window intervals'; software_observation = $true; compositor_scanout_included = $false; photon_measurement = $false; render_trace_snapshot_request_observer_included = $false; error = $frameTimeError })))
        }
    }

    if (Test-BenchMetricRequested -Name 'cold-start') {
        $harnessSamples = [Collections.Generic.List[double]]::new()
        $appSamples = [Collections.Generic.List[double]]::new()
        try {
            if ($Target -ne 'noctty') { throw 'app-side cold-start trace is available only for noctty' }
            foreach ($runNumber in 1..$Runs) {
                $name = "cold-start-$runNumber"
                $readyPath = Join-Path $layout.Temp "$name-ready.txt"
                $tracePath = Join-Path $layout.Temp "$name-render-trace.json"
                Remove-Item -LiteralPath $readyPath, $tracePath -ErrorAction SilentlyContinue
                $run = Start-BenchTarget -RunName $name -ChildScript $script:holdScriptPath -ChildScriptArguments @('-ReadyPath', $readyPath) -TracePath $tracePath
                try {
                    $trace = Get-BenchJsonFile -Path $tracePath -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
                    $harnessSamples.Add($run.Stopwatch.Elapsed.TotalMilliseconds)
                    if ($null -eq $trace.process_start_to_first_swap_ms -or [double] $trace.process_start_to_first_swap_ms -le 0) {
                        throw 'render trace omitted a positive process_start_to_first_swap_ms'
                    }
                    $appSamples.Add([double] $trace.process_start_to_first_swap_ms)
                }
                finally { Stop-BenchTarget -Run $run }
            }
            $metrics.Add((New-BenchMetricRecord -Name 'cold_start_harness_ms' -Unit 'ms' -Samples $harnessSamples.ToArray() -Details ([ordered]@{ process_creation_overhead_included = $true; trace_file_polling_included = $true })))
            $metrics.Add((New-BenchMetricRecord -Name 'cold_start_app_ms' -Unit 'ms' -Samples $appSamples.ToArray() -Details ([ordered]@{ app_trace_field = 'process_start_to_first_swap_ms'; clock_origin = 'main entry before global initialization; excludes pre-main OS loader time' })))
        }
        catch {
            $measurementErrors.Add("cold-start: $($_.Exception.Message)")
            $metrics.Add((New-BenchMetricRecord -Name 'cold_start_harness_ms' -Unit 'ms' -Status error -Details ([ordered]@{ process_creation_overhead_included = $true; trace_file_polling_included = $true; error = $_.Exception.Message })))
            $metrics.Add((New-BenchMetricRecord -Name 'cold_start_app_ms' -Unit 'ms' -Status error -Details ([ordered]@{ app_trace_field = 'process_start_to_first_swap_ms'; clock_origin = 'main entry before global initialization; excludes pre-main OS loader time'; error = $_.Exception.Message })))
        }
    }

    if (Test-BenchMetricRequested -Name 'memory') {
        $samples = [Collections.Generic.List[double]]::new()
        $paneLifecycleSamples = [Collections.Generic.List[object]]::new()
        $additionalPanes = 3
        $destroySettleSeconds = 7
        try {
            if ($Target -ne 'noctty') { throw 'memory-per-pane split automation is currently available only for noctty' }
            foreach ($runNumber in 1..$Runs) {
                $name = "memory-$runNumber"
                $readyPath = Join-Path $layout.Temp "$name-ready.txt"
                $memoryTracePath = Join-Path $layout.Temp "$name-memory-stage-trace.jsonl"
                Remove-Item -LiteralPath $readyPath, $memoryTracePath -ErrorAction SilentlyContinue
                $run = Start-BenchTarget -RunName $name -ChildScript $script:holdScriptPath -ChildScriptArguments @('-ReadyPath', $readyPath) -MemoryTracePath $memoryTracePath -EnableAutomation
                try {
                    $memoryHostHwnd = Wait-BenchNocttyWindow -Run $run
                    $memorySurfaceHwnd = [NocttyBenchNative]::FindChildWindow($memoryHostHwnd, 'noctty.win32')
                    if ($memorySurfaceHwnd -eq [IntPtr]::Zero) { throw 'noctty baseline surface HWND was not found' }
                    Start-Sleep -Seconds 2
                    $allCreatedSurfaceIds = [Collections.Generic.HashSet[uint64]]::new()
                    foreach ($cycleNumber in 1..$MemoryCycles) {
                        $cycleName = "$name-cycle-$cycleNumber"
                        $baselineSnapshot = Get-NocttyAutomationSnapshot -Name "$cycleName-list-baseline"
                        if ([int] $baselineSnapshot.windows[0].pane_count -ne 1) {
                            throw "memory cycle $cycleNumber baseline expected one pane, got $($baselineSnapshot.windows[0].pane_count)"
                        }
                        $baselineSurfaceIds = @(Get-BenchSnapshotSurfaceIds -Snapshot $baselineSnapshot)
                        if ($baselineSurfaceIds.Count -ne 1) {
                            throw "memory cycle $cycleNumber baseline expected one exact surface ID, got $($baselineSurfaceIds.Count)"
                        }
                        $baseline = Get-BenchPrivateBytes -Process $run.Process
                        $previousPrivateBytes = $baseline
                        $privateBytesAfterEachPane = [Collections.Generic.List[double]]::new()
                        $marginalPrivateBytes = [Collections.Generic.List[double]]::new()
                        $paneCountAfterEachCreate = [Collections.Generic.List[int]]::new()
                        $paneCountAfterEachClose = [Collections.Generic.List[int]]::new()
                        $survivorSurfaceIdsAfterEachClose = [Collections.Generic.List[object]]::new()
                        $createdSurfaceIds = [Collections.Generic.List[uint64]]::new()
                        foreach ($paneNumber in 1..$additionalPanes) {
                            $snapshot = Get-NocttyAutomationSnapshot -Name "$cycleName-list-$paneNumber"
                            $surface = $snapshot.windows[0].tabs | ForEach-Object { $_.panes } | Where-Object { $_.focused } | Select-Object -First 1
                            if ($null -eq $surface) { throw 'no focused surface was returned by +list-windows' }
                            $beforeSurfaceIds = @($snapshot.windows[0].tabs | ForEach-Object { $_.panes } | ForEach-Object { [uint64] $_.surface_id })
                            [void](Invoke-NocttyCli -Name "$cycleName-split-$paneNumber" -Arguments @('+perform-action', "--class=$script:instanceClass", "--surface-id=$($surface.surface_id)", 'new_split:right'))
                            $expected = $paneNumber + 1
                            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                            Wait-InteractiveWin11Until -Deadline $deadline -Description "memory cycle $cycleNumber pane count $expected" -Process $run.Process -Condition {
                                try { [int](Get-NocttyAutomationSnapshot -Name "$cycleName-wait-$expected").windows[0].pane_count -eq $expected } catch { $false }
                            }
                            $afterSplitSnapshot = Get-NocttyAutomationSnapshot -Name "$cycleName-list-after-$paneNumber"
                            $afterSplitPaneCount = [int] $afterSplitSnapshot.windows[0].pane_count
                            if ($afterSplitPaneCount -ne $expected) {
                                throw "memory cycle $cycleNumber split $paneNumber expected pane count $expected, got $afterSplitPaneCount"
                            }
                            $paneCountAfterEachCreate.Add($afterSplitPaneCount)
                            $newSurfaces = @($afterSplitSnapshot.windows[0].tabs | ForEach-Object { $_.panes } | Where-Object { [uint64] $_.surface_id -notin $beforeSurfaceIds })
                            if ($newSurfaces.Count -ne 1) {
                                throw "memory cycle $cycleNumber split $paneNumber expected exactly one new surface, got $($newSurfaces.Count)"
                            }
                            $newSurfaceId = [uint64] $newSurfaces[0].surface_id
                            if (-not $allCreatedSurfaceIds.Add($newSurfaceId)) {
                                throw "memory cycle $cycleNumber produced duplicate surface ID $newSurfaceId"
                            }
                            $createdSurfaceIds.Add($newSurfaceId)
                            Start-Sleep -Seconds 2
                            $privateBytes = Get-BenchPrivateBytes -Process $run.Process
                            $privateBytesAfterEachPane.Add($privateBytes)
                            $marginalPrivateBytes.Add($privateBytes - $previousPrivateBytes)
                            $previousPrivateBytes = $privateBytes
                        }
                        $after = $privateBytesAfterEachPane[$privateBytesAfterEachPane.Count - 1]
                        $samples.Add(($after - $baseline) / $additionalPanes)
                        for ($createdIndex = $createdSurfaceIds.Count - 1; $createdIndex -ge 0; $createdIndex--) {
                            $surfaceId = $createdSurfaceIds[$createdIndex]
                            [void](Invoke-NocttyCli -Name "$cycleName-close-$createdIndex" -Arguments @('+perform-action', "--class=$script:instanceClass", "--surface-id=$surfaceId", 'close_surface'))
                            $expected = $createdIndex + 1
                            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                            Wait-InteractiveWin11Until -Deadline $deadline -Description "memory cycle $cycleNumber pane count after close $expected" -Process $run.Process -Condition {
                                try { [int](Get-NocttyAutomationSnapshot -Name "$cycleName-wait-close-$expected").windows[0].pane_count -eq $expected } catch { $false }
                            }
                            $afterCloseSnapshot = Get-NocttyAutomationSnapshot -Name "$cycleName-list-after-close-$expected"
                            $afterClosePaneCount = [int] $afterCloseSnapshot.windows[0].pane_count
                            if ($afterClosePaneCount -ne $expected) {
                                throw "memory cycle $cycleNumber cleanup expected pane count $expected, got $afterClosePaneCount"
                            }
                            $paneCountAfterEachClose.Add($afterClosePaneCount)
                            $remainingCreatedSurfaceIds = @($createdSurfaceIds.ToArray() | Select-Object -First $createdIndex)
                            $expectedSurvivorSurfaceIds = [uint64[]] (@($baselineSurfaceIds) + $remainingCreatedSurfaceIds)
                            $actualSurvivorSurfaceIds = [uint64[]] @(Get-BenchSnapshotSurfaceIds -Snapshot $afterCloseSnapshot)
                            Assert-BenchExactSurfaceSet `
                                -ExpectedSurfaceIds $expectedSurvivorSurfaceIds `
                                -ActualSurfaceIds $actualSurvivorSurfaceIds `
                                -Context "memory cycle $cycleNumber close $createdIndex"
                            $survivorSurfaceIdsAfterEachClose.Add($actualSurvivorSurfaceIds)
                        }
                        $privateBytesAfterLogicalClose = Get-BenchPrivateBytes -Process $run.Process
                        Start-Sleep -Seconds $destroySettleSeconds
                        $afterDestroySettleSnapshot = Get-NocttyAutomationSnapshot -Name "$cycleName-list-after-destroy-settle"
                        if ([int] $afterDestroySettleSnapshot.windows[0].pane_count -ne 1) {
                            throw "memory cycle $cycleNumber lifecycle expected pane count 1 after destroy settle, got $($afterDestroySettleSnapshot.windows[0].pane_count)"
                        }
                        $survivorSurfaceIdsAfterDestroySettle = [uint64[]] @(Get-BenchSnapshotSurfaceIds -Snapshot $afterDestroySettleSnapshot)
                        Assert-BenchExactSurfaceSet `
                            -ExpectedSurfaceIds ([uint64[]] $baselineSurfaceIds) `
                            -ActualSurfaceIds $survivorSurfaceIdsAfterDestroySettle `
                            -Context "memory cycle $cycleNumber destroy settle"
                        $privateBytesAfterDestroySettle = Get-BenchPrivateBytes -Process $run.Process
                        $memoryStageSamples = @(Get-BenchMemoryStageSamples -Path $memoryTracePath -CreatedSurfaceIds ($createdSurfaceIds.ToArray()))
                        $paneLifecycleSamples.Add([pscustomobject][ordered]@{
                            run = $runNumber
                            cycle = $cycleNumber
                            baseline_private_bytes = $baseline
                            live_private_bytes = $after
                            private_bytes_after_each_pane = $privateBytesAfterEachPane.ToArray()
                            marginal_private_bytes = $marginalPrivateBytes.ToArray()
                            private_bytes_after_logical_close = $privateBytesAfterLogicalClose
                            private_bytes_after_destroy_settle = $privateBytesAfterDestroySettle
                            reclaimed_private_bytes_after_destroy_settle = $after - $privateBytesAfterDestroySettle
                            retained_private_bytes_above_baseline_after_destroy_settle = $privateBytesAfterDestroySettle - $baseline
                            created_surface_ids = $createdSurfaceIds.ToArray()
                            pane_count_at_baseline = 1
                            pane_count_after_each_create = $paneCountAfterEachCreate.ToArray()
                            pane_count_after_each_close = $paneCountAfterEachClose.ToArray()
                            pane_count_after_close = 1
                            pane_count_after_destroy_settle = 1
                            destroy_settle_seconds = $destroySettleSeconds
                            baseline_surface_ids = [uint64[]] $baselineSurfaceIds
                            survivor_surface_ids_after_each_close = $survivorSurfaceIdsAfterEachClose.ToArray()
                            survivor_surface_ids_after_destroy_settle = $survivorSurfaceIdsAfterDestroySettle
                            created_surface_count = $createdSurfaceIds.Count
                            memory_stage_samples = $memoryStageSamples
                        })
                    }
                }
                finally { Stop-BenchTarget -Run $run }
            }
            Assert-BenchMemoryLifecycleEvidence `
                -LifecycleSamples $paneLifecycleSamples.ToArray() `
                -ExpectedRuns $Runs `
                -MemoryCycles $MemoryCycles `
                -AdditionalPanes $additionalPanes
            $metrics.Add((New-BenchMetricRecord -Name 'memory_bytes_per_additional_pane' -Unit 'bytes' -Samples $samples.ToArray() -Details ([ordered]@{
                shell_child_memory_included = $false
                additional_panes = $additionalPanes
                memory_cycle_count = $MemoryCycles
                memory_diagnostic_only = [bool] ($MemoryCycles -ne 1)
                memory_trace_token_scope = 'surface_begin_incarnation'
                private_memory_scope = 'main process PrivateMemorySize64; includes terminal, renderer, native heap, and WGL/OpenGL driver private commit'
                graphics_context_model = 'each Surface selection creates and deletes one short-lived display-local WGL bootstrap HGLRC before creating its persistent Surface HGLRC; PrivateMemorySize64 may include retained driver allocation/cache effects from both and cannot apportion the combined pane delta among components'
                memory_stage_observer_included = $true
                memory_stage_observation_scope = 'in-process K32GetProcessMemoryInfo PrivateUsage sampled before each stage trace write; trace path allocation and file serialization observer are included only in memory attribution runs; repeated cycles share one process and therefore include prior-cycle allocator and driver cache state'
                pane_close_action = 'targeted close_surface synchronously clears structural history and destroys each native Surface; the later sample is a post-destroy allocator/driver settle observation'
                destroy_settle_seconds = $destroySettleSeconds
                pane_lifecycle_samples = $paneLifecycleSamples.ToArray()
            })))
        }
        catch {
            $measurementErrors.Add("memory: $($_.Exception.Message)")
            $metrics.Add((New-BenchMetricRecord -Name 'memory_bytes_per_additional_pane' -Unit 'bytes' -Status error -Details ([ordered]@{
                shell_child_memory_included = $false
                additional_panes = $additionalPanes
                memory_cycle_count = $MemoryCycles
                memory_diagnostic_only = [bool] ($MemoryCycles -ne 1)
                memory_trace_token_scope = 'surface_begin_incarnation'
                error = $_.Exception.Message
            })))
        }
    }

    if (Test-BenchMetricRequested -Name 'idle') {
        $cpuSamples = [Collections.Generic.List[double]]::new()
        $gpuSamples = [Collections.Generic.List[double]]::new()
        $swapSamples = [Collections.Generic.List[double]]::new()
        $renderTraceCounterDeltas = [Collections.Generic.List[object]]::new()
        $idleContaminationErrors = [Collections.Generic.List[string]]::new()
        $idleCounterNames = @(
            'renderer_update_frame_count',
            'renderer_draw_request_count',
            'renderer_core_wakeup_notify_count',
            'surface_focus_change_count',
            'cursor_timer_wakeup_count',
            'renderer_repaint_retry_wakeup_count',
            'resize_settle_wakeup_count',
            'paint_retry_wakeup_count',
            'health_recovery_wakeup_count',
            'paint_pending_wakeup_count',
            'wakeup_callback_count',
            'render_callback_count',
            'renderer_repaint_accept_count',
            'renderer_repaint_coalesced_count',
            'queue_paint_count',
            'queue_paint_update_now_count',
            'force_paint_now_count',
            'paint_draw_count',
            'paint_retry_count',
            'swap_buffers_count'
        )
        try {
            if ($Target -ne 'noctty') { throw 'render-trace idle swap assertion is currently available only for noctty' }
            foreach ($runNumber in 1..$Runs) {
                $name = "idle-$runNumber"
                $readyPath = Join-Path $layout.Temp "$name-ready.txt"
                $tracePath = Join-Path $layout.Temp "$name-render-trace.json"
                Remove-Item -LiteralPath $readyPath, $tracePath -ErrorAction SilentlyContinue
                $run = Start-BenchTarget -RunName $name -ChildScript $script:holdScriptPath -ChildScriptArguments @('-ReadyPath', $readyPath, '-SteadyCursor') -TracePath $tracePath -LiveTrace
                try {
                    Wait-BenchFile -Path $readyPath -Run $run -Description 'idle child readiness'
                    $hostHwnd = Wait-BenchNocttyWindow -Run $run
                    $surfaceHwnd = [NocttyBenchNative]::FindChildWindow($hostHwnd, 'noctty.win32')
                    if ($surfaceHwnd -eq [IntPtr]::Zero) { throw 'noctty surface HWND was not found' }
                    if (-not [NocttyBenchNative]::ForceForeground($hostHwnd)) {
                        throw "idle run $runNumber could not establish foreground ownership before quiescence"
                    }
                    $firstTrace = Get-BenchJsonFile -Path $tracePath -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
                    $initialTrace = Wait-BenchIdleQuiescence -Hwnd $surfaceHwnd -Path $tracePath -AfterSequence ([uint64] $firstTrace.snapshot_sequence) -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds)) -CounterNames $idleCounterNames
                    if ($initialTrace.surface_focused -isnot [System.Boolean] -or -not $initialTrace.surface_focused) {
                        throw "idle run $runNumber did not have stable surface focus at the measurement baseline"
                    }
                    $run.Process.Refresh()
                    $cpuBefore = $run.Process.TotalProcessorTime
                    $idleWatch = [Diagnostics.Stopwatch]::StartNew()
                    $counter = Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples $IdleSeconds -ErrorAction Stop
                    $idleWatch.Stop()
                    $run.Process.Refresh()
                    $cpuAfter = $run.Process.TotalProcessorTime
                    $cpuPercent = (($cpuAfter - $cpuBefore).TotalSeconds / ($idleWatch.Elapsed.TotalSeconds * $machine.logical_cores)) * 100.0
                    $pidPattern = "^pid_$($run.Process.Id)(_.*)?$"
                    $gpuByTimestamp = @($counter.CounterSamples | Where-Object { $_.InstanceName -match $pidPattern } | Group-Object Timestamp)
                    $gpuValues = @($gpuByTimestamp | ForEach-Object { ($_.Group | Measure-Object -Property CookedValue -Sum).Sum })
                    if ($gpuValues.Count -eq 0) {
                        throw "GPU Engine returned no pid_$($run.Process.Id) samples during the idle interval"
                    }
                    $gpuPercent = ($gpuValues | Measure-Object -Average).Average
                    $afterIdleTrace = Request-BenchRenderTraceSnapshot -Hwnd $surfaceHwnd -Path $tracePath -AfterSequence ([uint64] $initialTrace.snapshot_sequence) -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
                    if ($afterIdleTrace.renderer_cursor_blinking -isnot [System.Boolean] -or $afterIdleTrace.renderer_cursor_blinking) {
                        throw 'renderer cursor became blinking during the idle measurement interval'
                    }
                    if ($afterIdleTrace.surface_focused -isnot [System.Boolean]) {
                        throw 'render trace omitted Boolean surface_focused provenance'
                    }
                    $counterDelta = [ordered]@{
                        run = $runNumber
                        settle_duration_ms = [uint64] $initialTrace.idle_quiescence_settle_duration_ms
                        settle_probe_count = [int] $initialTrace.idle_quiescence_probe_count
                        surface_focused_before = [bool] $initialTrace.surface_focused
                        surface_focused_after = [bool] $afterIdleTrace.surface_focused
                    }
                    foreach ($counterName in $idleCounterNames) {
                        if ($null -eq $initialTrace.$counterName -or $null -eq $afterIdleTrace.$counterName) {
                            throw "render trace omitted idle counter $counterName"
                        }
                        $counterDelta[$counterName] = [double] $afterIdleTrace.$counterName - [double] $initialTrace.$counterName
                    }
                    $counterDelta.process_output_generation_delta = [double] $afterIdleTrace.last_swap_process_output_generation - [double] $initialTrace.last_swap_process_output_generation
                    $counterDelta.process_output_bytes_delta = [double] $afterIdleTrace.last_swap_process_output_bytes - [double] $initialTrace.last_swap_process_output_bytes
                    $renderTraceCounterDeltas.Add([pscustomobject] $counterDelta)
                    $swapDelta = [double] $counterDelta.swap_buffers_count
                    if ([double] $counterDelta.surface_focus_change_count -ne 0 -or
                        -not [bool] $counterDelta.surface_focused_before -or
                        -not [bool] $counterDelta.surface_focused_after) {
                        $idleContaminationErrors.Add("run $runNumber focus changed $($counterDelta.surface_focus_change_count) times (before=$($counterDelta.surface_focused_before), after=$($counterDelta.surface_focused_after))")
                    }
                }
                finally { Stop-BenchTarget -Run $run }
                $cpuSamples.Add($cpuPercent)
                $gpuSamples.Add($gpuPercent)
                $swapSamples.Add($swapDelta)
            }
            $idleStatus = if ($idleContaminationErrors.Count -eq 0) { 'pass' } else { 'error' }
            $swapStatus = if ($idleStatus -eq 'error') {
                'error'
            } elseif (@($swapSamples | Where-Object { $_ -ne 0 }).Count -eq 0) {
                'pass'
            } else {
                'fail'
            }
            $idleError = if ($idleContaminationErrors.Count -eq 0) { $null } else { "environmental focus contamination: $($idleContaminationErrors -join '; ')" }
            if ($null -ne $idleError) { $measurementErrors.Add("idle: $idleError") }
            if ($swapStatus -eq 'fail') { $measurementErrors.Add("idle render-trace swap counter climbed: samples=$($swapSamples -join ',')") }
            $idleObservation = 'render-trace atomics after foreground acquisition and 1500 ms counter quiescence; focus transitions invalidate the sample; JSON snapshots requested before and after timing'
            $cpuDetails = [ordered]@{ idle_interval_seconds = $IdleSeconds; idle_quiescence_requirement_ms = 1500; observation_method = $idleObservation; cursor_blinking = $false; render_trace_counter_deltas = $renderTraceCounterDeltas.ToArray() }
            $gpuDetails = [ordered]@{ idle_interval_seconds = $IdleSeconds; idle_quiescence_requirement_ms = 1500; observation_method = $idleObservation; cursor_blinking = $false; render_trace_counter_deltas = $renderTraceCounterDeltas.ToArray() }
            $swapDetails = [ordered]@{ idle_interval_seconds = $IdleSeconds; idle_quiescence_requirement_ms = 1500; observation_method = $idleObservation; cursor_blinking = $false; render_trace_counter_deltas = $renderTraceCounterDeltas.ToArray() }
            if ($null -ne $idleError) {
                $cpuDetails.error = $idleError
                $gpuDetails.error = $idleError
                $swapDetails.error = $idleError
            }
            $metrics.Add((New-BenchMetricRecord -Name 'idle_cpu_percent' -Unit 'percent' -Samples $cpuSamples.ToArray() -Status $idleStatus -Details $cpuDetails))
            $metrics.Add((New-BenchMetricRecord -Name 'idle_gpu_percent' -Unit 'percent' -Samples $gpuSamples.ToArray() -Status $idleStatus -Details $gpuDetails))
            $metrics.Add((New-BenchMetricRecord -Name 'idle_swap_count_delta' -Unit 'count' -Samples $swapSamples.ToArray() -Status $swapStatus -Details $swapDetails))
        }
        catch {
            $measurementErrors.Add("idle: $($_.Exception.Message)")
            foreach ($name in @('idle_cpu_percent', 'idle_gpu_percent', 'idle_swap_count_delta')) {
                $unit = if ($name -eq 'idle_swap_count_delta') { 'count' } else { 'percent' }
                $metrics.Add((New-BenchMetricRecord -Name $name -Unit $unit -Status error -Details ([ordered]@{ idle_interval_seconds = $IdleSeconds; observation_method = 'swap atomics during timed interval; JSON snapshots requested before and after timing'; error = $_.Exception.Message })))
            }
        }
    }

    if (Test-BenchMetricRequested -Name 'conpty-rtt') {
        $samples = [Collections.Generic.List[double]]::new()
        try {
            foreach ($runNumber in 1..$Runs) {
                $result = Invoke-BenchEchoRun -RunName "conpty-rtt-$runNumber"
                $samples.Add($result.ConptyRttMs)
            }
            $metrics.Add((New-BenchMetricRecord -Name 'conpty_rtt_ms' -Unit 'ms' -Samples $samples.ToArray() -Details ([ordered]@{ endpoint = 'controlled echo bytes parsed by the terminal'; clock = 'cross-process GetTickCount64'; uia_nonce_validation = $true; render_trace_snapshot_request_observer_included = $true })))
        }
        catch {
            $measurementErrors.Add("conpty-rtt: $($_.Exception.Message)")
            $metrics.Add((New-BenchMetricRecord -Name 'conpty_rtt_ms' -Unit 'ms' -Status error -Details ([ordered]@{ endpoint = 'controlled echo bytes parsed by the terminal'; clock = 'cross-process GetTickCount64'; uia_nonce_validation = $true; render_trace_snapshot_request_observer_included = $true; error = $_.Exception.Message })))
        }
    }

    if (Test-BenchMetricRequested -Name 'key-to-pixel-proxy') {
        $samples = [Collections.Generic.List[double]]::new()
        $lastTracePath = $null
        try {
            foreach ($runNumber in 1..$Runs) {
                $result = Invoke-BenchEchoRun -RunName "key-proxy-$runNumber" -NeedProxy
                $samples.Add($result.ProxyMs)
                $lastTracePath = $result.TracePath
            }
            $metrics.Add((New-BenchMetricRecord -Name 'key_to_first_swap_ms_proxy' -Unit 'ms' -Samples $samples.ToArray() -Details ([ordered]@{ proxy_kind = 'software SendInput-to-successful-SwapBuffers proxy; accepted swap must consume the controlled echo output generation'; clock = 'cross-process QueryPerformanceCounter'; excludes_post_swap_trace_observation_delay = $true; render_trace_snapshot_request_observer_included = $true; render_trace_target_observer_included = $true; photon_measurement = $false; render_trace_path = $lastTracePath })))
        }
        catch {
            $measurementErrors.Add("key-to-pixel-proxy: $($_.Exception.Message)")
            $metrics.Add((New-BenchMetricRecord -Name 'key_to_first_swap_ms_proxy' -Unit 'ms' -Status error -Details ([ordered]@{ proxy_kind = 'software SendInput-to-successful-SwapBuffers proxy; accepted swap must consume the controlled echo output generation'; clock = 'cross-process QueryPerformanceCounter'; excludes_post_swap_trace_observation_delay = $true; render_trace_snapshot_request_observer_included = $true; render_trace_target_observer_included = $true; photon_measurement = $false; render_trace_path = $lastTracePath; error = $_.Exception.Message })))
        }
    }
    }
}

$thresholdBreaches = [Collections.Generic.List[string]]::new()
$gateContractFailures = [Collections.Generic.List[string]]::new()
$activeThresholdCount = 0
# Threshold provenance is part of the evidence contract for every measured
# metric, not just for gated runs: the methodology doc directs baseline
# collection to run without -Gate and still promises that the evidence
# records threshold provenance and that inactive thresholds appear with
# `passed: null`. So thresholds are always loaded, validated and attached;
# -Gate only decides whether a breach turns into a failing status and a
# nonzero exit.
if (-not (Test-Path -LiteralPath $ThresholdPath -PathType Leaf)) { throw "Threshold file not found: $ThresholdPath" }
$parsedThresholds = Get-Content -LiteralPath $ThresholdPath -Raw | ConvertFrom-Json
$thresholds = @($parsedThresholds | ForEach-Object { $_ })
$thresholdByMetric = @{}
foreach ($threshold in $thresholds) {
    foreach ($requiredProperty in @('metric', 'direction', 'value', 'active', 'provisional', 'source')) {
        if ($null -eq $threshold.PSObject.Properties[$requiredProperty]) {
            throw "Threshold entry is missing required property '$requiredProperty': $($threshold | ConvertTo-Json -Compress)"
        }
    }
    $thresholdMetric = [string] $threshold.metric
    if ([string]::IsNullOrWhiteSpace($thresholdMetric)) { throw 'Threshold metric must be nonempty' }
    if ($thresholdByMetric.ContainsKey($thresholdMetric)) { throw "Threshold metric '$thresholdMetric' is duplicated" }
    if ([string] $threshold.direction -notmatch '^(min|minimum|at-least|max|maximum|at-most)$') {
        throw "Unknown threshold direction '$($threshold.direction)' for metric $thresholdMetric"
    }
    if ($threshold.active -isnot [System.Boolean]) {
        throw "Threshold active for metric '$thresholdMetric' must be a JSON boolean"
    }
    if ($threshold.provisional -isnot [System.Boolean]) {
        throw "Threshold provisional for metric '$thresholdMetric' must be a JSON boolean"
    }
    if ($threshold.active -and $threshold.provisional) {
        throw "Threshold metric '$thresholdMetric' cannot be both active and provisional"
    }
    $thresholdValue = [double] $threshold.value
    if ([double]::IsNaN($thresholdValue) -or [double]::IsInfinity($thresholdValue)) { throw "Threshold value for metric '$thresholdMetric' must be finite" }
    if ([string]::IsNullOrWhiteSpace([string] $threshold.source)) { throw "Threshold source for metric '$thresholdMetric' must be nonempty" }
    $thresholdByMetric[$thresholdMetric] = $threshold
}
foreach ($record in $metrics) {
    if ($record.status -ne 'pass' -and $record.status -ne 'fail') { continue }
    $measurementField = if ($record.metric -eq 'frame_time_p95_ms') { 'p95' } else { 'median' }
    if ($null -eq $record.$measurementField) { continue }
    if (-not $thresholdByMetric.ContainsKey([string] $record.metric)) {
        throw "Threshold file has no entry for measured metric '$($record.metric)'"
    }
    $threshold = $thresholdByMetric[[string] $record.metric]
    $measured = [double] $record.$measurementField
    $value = [double] $threshold.value
    $active = $threshold.active
    if ($active) { $activeThresholdCount++ }
    # `passed` is the comparison result, independent of -Gate. An inactive
    # threshold is always `null`, so it can never read as a silent pass or
    # a silent failure.
    $passed = if ($active) {
        switch -Regex ([string] $threshold.direction) {
            '^(min|minimum|at-least)$' { $measured -ge $value; break }
            '^(max|maximum|at-most)$' { $measured -le $value; break }
            default { throw "Unknown threshold direction '$($threshold.direction)' for metric $($threshold.metric)" }
        }
    }
    else { $null }
    $record | Add-Member -NotePropertyName threshold -NotePropertyValue ([pscustomobject][ordered]@{
        direction = [string] $threshold.direction
        value = $value
        active = $active
        provisional = $threshold.provisional
        source = [string] $threshold.source
        passed = $passed
    })
    # Enforcement is the one thing -Gate owns.
    if ($Gate -and $active -and -not $passed) {
        $record.status = 'fail'
        $thresholdBreaches.Add("$($record.metric) $measurementField $measured $($record.unit) breached $($threshold.direction) threshold $value $($record.unit)")
    }
}

if ($Gate) {
    if (-not $script:adapter.Installed) {
        $gateContractFailures.Add("target '$Target' is not installed")
    }
    foreach ($record in @($metrics | Where-Object { $_.status -in @('not-supported', 'error', 'skip') })) {
        $gateContractFailures.Add("metric '$($record.metric)' has status=$($record.status)")
    }
    if ($activeThresholdCount -eq 0) {
        $gateContractFailures.Add("selection target=$Target metric=$Metric has no applicable active threshold")
    }
}

$topStatus = if (-not $script:adapter.Installed) {
    'not-installed'
}
elseif ($metrics.Count -gt 0 -and @($metrics | Where-Object { $_.status -ne 'not-supported' }).Count -eq 0) {
    'not-supported'
}
elseif ($thresholdBreaches.Count -gt 0 -or @($metrics | Where-Object { $_.status -eq 'fail' }).Count -gt 0) {
    'fail'
}
elseif ($measurementErrors.Count -gt 0 -or @($metrics | Where-Object { $_.status -eq 'error' }).Count -gt 0) {
    'error'
}
else { 'pass' }

$exeHash = if ($script:adapter.Installed) { Get-BenchFileSha256 -Path $script:adapter.ExePath } else { $null }
$evidence = [pscustomobject][ordered]@{
    schema_version = 'io.github.amanthanvi.noctty.bench-evidence.v1'
    generated_at = [DateTime]::UtcNow.ToString('o')
    status = $topStatus
    machine = $machine
    configuration = [pscustomobject][ordered]@{
        font_family = $resolvedFont
        font_size_pt = $FontSize
        rows = $Rows
        cols = $Cols
        build_mode = if ($Target -eq 'noctty') { 'ReleaseFast' } else { $null }
    }
    target = [pscustomobject][ordered]@{
        name = $Target
        version = $script:adapter.Version
        exe_path = $script:adapter.ExePath
        exe_sha256 = $exeHash
        commit_sha = if ($Target -eq 'noctty') { $commitSha } else { $null }
    }
    run_count = $Runs
    processes = @($processRecords.ToArray())
    metrics = @($metrics.ToArray())
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
}
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Benchmark evidence schema is missing; refusing to emit unchecked evidence: $schemaPath"
}
$json = ($evidence | ConvertTo-Json -Depth 12) -replace "`r`n", "`n"
$outputTempPath = "$OutputPath.validation-$PID-$([Guid]::NewGuid().ToString('N')).tmp"
[IO.File]::WriteAllText($outputTempPath, $json + "`n", [Text.UTF8Encoding]::new($false))
try {
    $testJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if ($null -ne $testJson) {
        if (-not ($json | Test-Json -SchemaFile $schemaPath)) {
            throw "Benchmark output failed schema validation: $schemaPath"
        }
    }
    else {
        $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($null -eq $pwsh) {
            throw 'Benchmark schema validation requires Test-Json or pwsh.exe; refusing to emit unchecked evidence'
        }
        $validatorPath = Join-Path $layout.Temp 'bench-schema-validator.ps1'
        $validator = @'
param([Parameter(Mandatory)] [string] $JsonPath, [Parameter(Mandatory)] [string] $SchemaPath)
$raw = Get-Content -LiteralPath $JsonPath -Raw
if (-not ($raw | Test-Json -SchemaFile $SchemaPath)) { exit 1 }
'@
        [IO.File]::WriteAllText($validatorPath, $validator, [Text.UTF8Encoding]::new($false))
        try {
            & $pwsh.Source -NoLogo -NoProfile -File $validatorPath -JsonPath $outputTempPath -SchemaPath $schemaPath
            if ($LASTEXITCODE -ne 0) { throw "Benchmark output failed schema validation: $schemaPath" }
        }
        finally { Remove-Item -LiteralPath $validatorPath -ErrorAction SilentlyContinue }
    }
    Move-Item -LiteralPath $outputTempPath -Destination $OutputPath -Force
}
finally { Remove-Item -LiteralPath $outputTempPath -ErrorAction SilentlyContinue }

if ($Gate -and $gateContractFailures.Count -gt 0) {
    Write-Host ("benchmark gate rejected: " + ($gateContractFailures -join '; '))
    exit 1
}
if (-not $script:adapter.Installed) {
    Write-Host "benchmark target '$Target' is not installed; recorded status=not-installed at $OutputPath"
    exit 0
}
if ($topStatus -eq 'not-supported') {
    Write-Host "benchmark target '$Target' requires metric-specific comparability adapters; recorded status=not-supported at $OutputPath"
    exit 0
}
if ($thresholdBreaches.Count -gt 0) {
    Write-Host ("benchmark gate failed: " + ($thresholdBreaches -join '; '))
    exit 1
}
if ($measurementErrors.Count -gt 0) {
    Write-Host ("benchmark collection failed: " + ($measurementErrors -join '; '))
    exit 1
}
Write-Host "Windows benchmark: PASS (target=$Target, metric=$Metric, runs=$Runs, evidence=$OutputPath)"
