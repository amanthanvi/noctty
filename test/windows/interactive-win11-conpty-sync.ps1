[CmdletBinding()]
param(
    [string[]] $Scenario = @(),
    [switch] $ListScenarios,
    [switch] $Rebuild,
    [switch] $NoBuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 900,
    # Internal: the half of the harness that runs on the hidden desktop.
    [switch] $Inner,
    [string] $RunRoot,
    [string] $ResultPath
)

# Differential harness: does noctty's screen agree with ConPTY's?
#
# ConPTY keeps its own copy of the screen. Console-API programs (cmd's line
# editor, PSReadLine, anything using SetConsoleCursorPosition) draw into that
# copy, and ConPTY forwards the result as VT with ABSOLUTE cursor positions in
# its own coordinates. If noctty's grid disagrees with ConPTY's buffer about
# which line sits on which row, every later absolute write lands on the wrong
# row. A resize is where the two drift apart: ConPTY keeps no scrollback and
# sends nothing after a resize (AGENTS.md, #262), so whatever noctty's
# PageList does on its own side must match what conhost does on its side.
#
# Each scenario starts a fresh portable noctty on a hidden desktop, puts a
# shell into a known state, applies a trigger (resize, search bar, split,
# maximize, ...), and then compares, row by row:
#   * noctty's visible rows, read through the terminal's UIA TextPattern, and
#   * ConPTY's visible rows, read by a helper process that attaches to the
#     shell's console (FreeConsole, AttachConsole, CONOUT$,
#     ReadConsoleOutputW). AttachConsole is process-wide, so it never runs in
#     this process.
# It then types a marker without Enter and compares again: that is the write
# that lands on the wrong row when the views disagree.
#
# Scenarios marked `Expect = 'desync'` reproduce known bugs (F015, F032;
# PKG-14). They pass while they still desync (XFAIL) and FAIL once they stop
# desyncing (XPASS), so the fix has to remove the mark.
#
# Input is window messages to the terminal HWND: no SendInput, no foreground,
# no mouse. Every noctty this runs is a copy with a `noctty.portable` marker in
# the sandbox, with APPDATA and LOCALAPPDATA pointing into the sandbox, and the
# real profile's startup-attempts.json is checked before and after.

$ErrorActionPreference = 'Stop'

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

# ---------------------------------------------------------------------------
# Native helpers shared by both halves.
# ---------------------------------------------------------------------------
if (-not ('NocttyConptySyncNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class NocttyConptySyncNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr devmode, uint flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr CreateJobObjectW(IntPtr sa, string name);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint len);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool TerminateProcess(IntPtr process, uint code);

    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint type);

    public static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }

    public static List<IntPtr> TopWindows(int pid, string cls) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { int p; GetWindowThreadProcessId(h, out p); if (p == pid && ClassOf(h) == cls) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    public static List<IntPtr> VisibleChildren(IntPtr parent, string cls) {
        var list = new List<IntPtr>();
        EnumChildWindows(parent, (h, l) => { if (IsWindowVisible(h) && ClassOf(h) == cls) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    // Kill every process in the job when the last handle closes, so a
    // timed-out run cannot leave an invisible noctty behind on a desktop
    // nobody can see.
    public static IntPtr NewKillOnCloseJob() {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return job;
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)))) {
            CloseHandle(job);
            return IntPtr.Zero;
        }
        return job;
    }
}
'@
}

# The console reader. It is compiled into its own executable because
# AttachConsole changes the console of the whole calling process.
$script:ConptySyncDumpSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class NocttyConptySyncDump {
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct CSBI { public COORD dwSize, dwCursorPosition; public ushort wAttributes; public SMALL_RECT srWindow; public COORD dwMaximumWindowSize; }
    [StructLayout(LayoutKind.Explicit)] struct CHAR_INFO { [FieldOffset(0)] public ushort Char; [FieldOffset(2)] public ushort Attributes; }
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI i);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadConsoleOutputW(IntPtr h, [Out] CHAR_INFO[] b, COORD size, COORD at, ref SMALL_RECT r);

    const ushort TrailingByte = 0x0200; // COMMON_LVB_TRAILING_BYTE

    // conpty-sync-dump <pid> <outfile>
    // Line 1: "BUFFER <w>x<h> WINDOW <left>,<top> <w>x<h> CURSOR <x>,<y>"
    // (cursor relative to the window), then one line per visible row,
    // trailing blanks trimmed, the second half of a wide cell skipped.
    public static int Main(string[] args) {
        if (args.Length < 2) return 2;
        var sb = new StringBuilder();
        int rc = Dump(uint.Parse(args[0]), sb);
        string tmp = args[1] + ".tmp";
        File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
        if (File.Exists(args[1])) File.Delete(args[1]);
        File.Move(tmp, args[1]);
        return rc;
    }

    static int Dump(uint pid, StringBuilder sb) {
        FreeConsole();
        if (!AttachConsole(pid)) { sb.Append("ERROR AttachConsole " + Marshal.GetLastWin32Error()); return 4; }
        IntPtr h = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == new IntPtr(-1)) { sb.Append("ERROR CONOUT$ " + Marshal.GetLastWin32Error()); FreeConsole(); return 5; }
        try {
            CSBI info;
            if (!GetConsoleScreenBufferInfo(h, out info)) { sb.Append("ERROR CSBI " + Marshal.GetLastWin32Error()); return 6; }
            int w = info.srWindow.Right - info.srWindow.Left + 1;
            int ht = info.srWindow.Bottom - info.srWindow.Top + 1;
            sb.AppendFormat("BUFFER {0}x{1} WINDOW {2},{3} {4}x{5} CURSOR {6},{7}\n",
                info.dwSize.X, info.dwSize.Y, info.srWindow.Left, info.srWindow.Top, w, ht,
                info.dwCursorPosition.X - info.srWindow.Left, info.dwCursorPosition.Y - info.srWindow.Top);
            var cells = new CHAR_INFO[w];
            for (int y = 0; y < ht; y++) {
                var region = new SMALL_RECT();
                region.Left = info.srWindow.Left; region.Right = info.srWindow.Right;
                region.Top = (short)(info.srWindow.Top + y); region.Bottom = region.Top;
                var size = new COORD(); size.X = (short)w; size.Y = 1;
                if (!ReadConsoleOutputW(h, cells, size, new COORD(), ref region)) { sb.Append("ERROR ReadConsoleOutputW " + Marshal.GetLastWin32Error()); return 7; }
                var line = new StringBuilder();
                for (int x = 0; x < w; x++) {
                    char c = (char)cells[x].Char;
                    if ((cells[x].Attributes & TrailingByte) != 0) {
                        // A non-BMP character can be split across its two
                        // cells; keep the low surrogate with its pair.
                        if (char.IsLowSurrogate(c) && line.Length > 0 && char.IsHighSurrogate(line[line.Length - 1])) line.Append(c);
                        continue;
                    }
                    line.Append(c == '\0' ? ' ' : c);
                }
                sb.Append(line.ToString().TrimEnd(' ')).Append('\n');
            }
            return 0;
        } finally { CloseHandle(h); FreeConsole(); }
    }
}
'@

$script:SYNC_WM_KEYDOWN = 0x0100
$script:SYNC_WM_KEYUP = 0x0101
$script:SYNC_WM_CHAR = 0x0102
$script:SYNC_VK_PACKET = 0xE7
# Keybinds the scenarios install, on keys nobody types.
$script:SYNC_KEYBINDS = [ordered]@{
    start_search = 0x7C       # F13
    end_search = 0x7D         # F14
    'new_split:down' = 0x7E   # F15
    'new_split:right' = 0x7F  # F16
    close_surface = 0x80      # F17
}
$script:SYNC_KEYBIND_NAMES = @{ 0x7C = 'f13'; 0x7D = 'f14'; 0x7E = 'f15'; 0x7F = 'f16'; 0x80 = 'f17' }

function Get-ConptySyncRealStartupAttempts {
    # SHGetKnownFolderPath ignores the sandboxed LOCALAPPDATA variable.
    $real = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $path = Join-Path $real 'noctty\startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "absent:$path" }
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    return '{0} {1} {2}' -f $path, $hash, $item.LastWriteTimeUtc.ToString('o')
}

# PSReadLine's history file lives in the real roaming profile whatever APPDATA
# says. The scenarios redirect it; this looks for the sandbox path, which every
# PowerShell scenario types, in the real file. A count rather than a hash, so
# the user's own sessions writing to it at the same time do not trip it.
function Get-ConptySyncRealPSReadLineLeaks([string] $Token) {
    $real = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $path = Join-Path $real 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
    return @(Select-String -LiteralPath $path -SimpleMatch -Pattern $Token).Count
}

# ===========================================================================
# Inner half: runs on the hidden desktop.
# ===========================================================================
if ($Inner) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    [void][NocttyConptySyncNative]::SetThreadDpiAwarenessContext([IntPtr](-4))

    $script:Exe = Join-Path $RunRoot 'bin\noctty.exe'
    $script:DumpExe = Join-Path $RunRoot 'tools\conpty-sync-dump.exe'
    $script:Evidence = Join-Path $RunRoot 'evidence'
    $script:Work = Join-Path $RunRoot 'work'
    $script:LogPath = Join-Path $script:Evidence 'inner.log'
    New-Item -ItemType Directory -Force -Path $script:Evidence, $script:Work | Out-Null

    function Write-SyncLog([string] $Text) {
        $line = '{0} {1}' -f (Get-Date).ToString('HH:mm:ss.fff'), $Text
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }

    function Send-SyncMessage([IntPtr] $Hwnd, [int] $Message, [int64] $WParam, [int64] $LParam) {
        $result = [IntPtr]::Zero
        $ok = [NocttyConptySyncNative]::SendMessageTimeoutW($Hwnd, [uint32]$Message, [IntPtr]$WParam, [IntPtr]$LParam, 2, 5000, [ref]$result)
        if ($ok -eq [IntPtr]::Zero) { throw ('SendMessageTimeout 0x{0:X} to 0x{1:X} failed or timed out' -f $Message, $Hwnd.ToInt64()) }
    }

    # A key as TranslateMessage would deliver it: the surface drops a WM_CHAR
    # that no WM_KEYDOWN announced (AGENTS.md, DeferredCharState).
    function Send-SyncKey([IntPtr] $Hwnd, [int] $Vk, [int] $Char = 0, [switch] $MayDestroy) {
        $scan = [NocttyConptySyncNative]::MapVirtualKeyW([uint32]$Vk, 0)
        $down = [int64](1 -bor ([int64]$scan -shl 16))
        $up = $down -bor 0xC0000000L
        Send-SyncMessage $Hwnd $script:SYNC_WM_KEYDOWN $Vk $down
        if ($Char -ne 0) { Send-SyncMessage $Hwnd $script:SYNC_WM_CHAR $Char $down }
        if ($MayDestroy) {
            # The key may have closed this window (close_surface).
            [void][NocttyConptySyncNative]::PostMessageW($Hwnd, $script:SYNC_WM_KEYUP, [IntPtr]$Vk, [IntPtr]$up)
        }
        else { Send-SyncMessage $Hwnd $script:SYNC_WM_KEYUP $Vk $up }
    }

    # Letters, digits and space go as their own keys; everything else as
    # VK_PACKET so no modifier state has to be faked for punctuation.
    function Send-SyncText([IntPtr] $Hwnd, [string] $Text) {
        foreach ($ch in $Text.ToCharArray()) {
            $code = [int]$ch
            if ($code -eq 13) { Send-SyncKey $Hwnd 0x0D 13 }
            elseif (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x61 -and $code -le 0x7A) -or $code -eq 0x20) {
                Send-SyncKey $Hwnd ([int][char]::ToUpperInvariant($ch)) $code
            }
            else {
                Send-SyncMessage $Hwnd $script:SYNC_WM_KEYDOWN $script:SYNC_VK_PACKET 1
                Send-SyncMessage $Hwnd $script:SYNC_WM_CHAR $code 1
                Send-SyncMessage $Hwnd $script:SYNC_WM_KEYUP $script:SYNC_VK_PACKET 0xC0000001L
            }
            Start-Sleep -Milliseconds 10
        }
    }

    function Get-SyncSurfaces($Ctx) { @([NocttyConptySyncNative]::VisibleChildren($Ctx.Host, 'noctty.win32')) }

    function Get-SyncDescendants([int] $RootPid) {
        $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CreationDate)
        $result = @()
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($RootPid)
        while ($queue.Count -gt 0) {
            $parent = $queue.Dequeue()
            foreach ($child in @($all | Where-Object { $_.ParentProcessId -eq $parent })) {
                $result += $child
                $queue.Enqueue($child.ProcessId)
            }
        }
        return $result
    }

    function Get-SyncShellPids($Ctx) {
        @(Get-SyncDescendants $Ctx.Process.Id |
            Where-Object { $_.Name -ieq $Ctx.ShellExe } |
            Sort-Object CreationDate |
            ForEach-Object { [int]$_.ProcessId })
    }

    function Read-SyncNoctty([IntPtr] $Surface) {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($Surface)
        $pattern = $null
        if (-not $element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
            throw 'terminal surface exposes no UIA TextPattern'
        }
        $ranges = $pattern.GetVisibleRanges()
        if ($ranges.Length -ne 1) { throw "expected one visible range, got $($ranges.Length)" }
        return @($ranges[0].GetText(-1) -split "`r?`n")
    }

    function Read-SyncConpty([int] $ShellPid) {
        $path = Join-Path $script:Work ('dump-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:DumpExe
        $psi.Arguments = '{0} "{1}"' -f $ShellPid, $path
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(10000)) { $proc.Kill(); throw 'console dump timed out' }
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        Remove-Item -LiteralPath $path -Force
        # A read can fail after the header was written, so the exit code,
        # not the first line, says whether the rows are real.
        if ($proc.ExitCode -ne 0) { throw "console dump failed with $($proc.ExitCode): $raw" }
        $lines = @($raw.TrimEnd("`n") -split "`n")
        $header = $lines[0]
        if ($header -notmatch '^BUFFER (\d+)x(\d+) WINDOW (\d+),(\d+) (\d+)x(\d+) CURSOR (-?\d+),(-?\d+)$') { throw "bad dump header: $header" }
        return [pscustomobject]@{
            Header = $header
            Cols = [int]$Matches[5]
            Rows = [int]$Matches[6]
            CursorX = [int]$Matches[7]
            CursorY = [int]$Matches[8]
            Lines = @($lines | Select-Object -Skip 1)
        }
    }

    # Cells the two sides cannot spell the same way: conhost holds one UTF-16
    # unit per cell and no grapheme clusters (it shows U+FFFD for a non-BMP
    # character or a VS16 sequence), noctty holds whole clusters. A cluster
    # that is more than one UTF-16 unit, or is U+FFFD or a lone surrogate,
    # compares as one placeholder.
    $script:SyncCluster = New-Object System.Text.RegularExpressions.Regex (
        '(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|.)(?:[\u0300-\u036F\u20E3\uFE0E\uFE0F]|\u200D(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|.))*')
    $script:SyncClusterEvaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $v = $m.Value
        if ($v.Length -gt 1 -or $v -eq [string][char]0xFFFD -or [char]::IsSurrogate($v[0])) { return '?' }
        return $v
    }
    function Get-SyncNormalized([string] $Text) {
        return $script:SyncCluster.Replace($Text.TrimEnd(), $script:SyncClusterEvaluator)
    }

    function Compare-SyncViews([string[]] $Noctty, $Conpty) {
        $rows = [Math]::Max($Noctty.Count, $Conpty.Lines.Count)
        $diff = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $rows; $i++) {
            $a = if ($i -lt $Noctty.Count) { $Noctty[$i] } else { '' }
            $b = if ($i -lt $Conpty.Lines.Count) { $Conpty.Lines[$i] } else { '' }
            if ((Get-SyncNormalized $a) -cne (Get-SyncNormalized $b)) {
                $diff.Add(('row {0,2} noctty: {1}' -f $i, $a.TrimEnd()))
                $diff.Add(('row {0,2} conpty: {1}' -f $i, $b.TrimEnd()))
            }
        }
        return [pscustomobject]@{ Rows = [int]($diff.Count / 2); Lines = $diff.ToArray() }
    }

    # Sample both views until they hold still, then compare. UIA may hand
    # back a cached snapshot while the renderer holds its lock, and ConPTY
    # repaints asynchronously, so one sample is not evidence.
    function Get-SyncComparison($Ctx, [string] $Label, [int] $SettleMs = 600, [int] $MaxMs = 8000, [bool] $RequireSettled = $true) {
        $deadline = (Get-Date).AddMilliseconds($MaxMs)
        $previous = $null
        $stableSince = $null
        $settled = $false
        while ($true) {
            $noctty = Read-SyncNoctty $Ctx.Surface
            $conpty = Read-SyncConpty $Ctx.ShellPid
            $key = ($noctty -join "`n") + "`n--`n" + $conpty.Header + "`n" + ($conpty.Lines -join "`n")
            $now = Get-Date
            if ($key -ceq $previous) {
                if ($null -eq $stableSince) { $stableSince = $now }
                if (($now - $stableSince).TotalMilliseconds -ge $SettleMs) { $settled = $true; break }
            }
            else { $stableSince = $null }
            $previous = $key
            if ($now -gt $deadline) { break }
            Start-Sleep -Milliseconds 150
        }
        $cmp = Compare-SyncViews $noctty $conpty
        $file = Join-Path $script:Evidence ('{0}-{1}.txt' -f $Ctx.Name, $Label)
        $body = @("conpty: $($conpty.Header)", "diff rows=$($cmp.Rows) settled=$settled") + $cmp.Lines +
            @('--- noctty ---') + $noctty + @('--- conpty ---') + $conpty.Lines
        Set-Content -LiteralPath $file -Value $body -Encoding UTF8
        Write-SyncLog ('{0} {1}: {2} diff rows={3} settled={4}' -f $Ctx.Name, $Label, $conpty.Header, $cmp.Rows, $settled)
        # A difference that is still moving says nothing about the trigger,
        # so it must not count as the known desync either.
        if ($RequireSettled -and -not $settled) { throw "the views did not hold still for $SettleMs ms within $MaxMs ms ($file)" }
        return [pscustomobject]@{ Diff = $cmp.Rows; Lines = $cmp.Lines; Conpty = $conpty; Noctty = $noctty; File = $file }
    }

    # Conditions are plain script blocks: they run in a child of this call,
    # so they see the caller's variables through PowerShell's dynamic scope.
    function Wait-SyncCondition([scriptblock] $Condition, [string] $Description, [int] $TimeoutMs = 20000) {
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ((Get-Date) -lt $deadline) {
            if (& $Condition) { return }
            Start-Sleep -Milliseconds 150
        }
        throw "timed out waiting for $Description"
    }

    function Wait-SyncText($Ctx, [string] $Needle, [int] $TimeoutMs = 20000) {
        Wait-SyncCondition -Description "'$Needle' on screen" -TimeoutMs $TimeoutMs -Condition {
            ((Read-SyncNoctty $Ctx.Surface) -join "`n").Contains($Needle)
        }
    }

    # PSReadLine keeps its history in the REAL roaming profile: it asks for
    # the known folder, so the sandboxed APPDATA does not move it. Every
    # PowerShell here therefore points PSReadLine at a sandbox file before
    # its first prompt reads or writes one. That needs `-Command`, which
    # turns off noctty's automatic injection, so the integration is
    # dot-sourced here the way noctty's own launch wrapper does it.
    function Get-SyncPowerShellCommand([string] $Exe, [string] $Name, [string] $ExtraOptions, [string[]] $History) {
        # History a scenario needs is read from the redirected file.
        $historyPath = Join-Path $script:Work "$Name-psreadline-history.txt"
        [IO.File]::WriteAllLines($historyPath, [string[]]@($History), (New-Object System.Text.UTF8Encoding $false))
        $integration = Join-Path $RunRoot 'tools\integration.ps1'
        return ('{0} -NoLogo -NoProfile -NoExit -Command "Set-PSReadLineOption -HistorySavePath ''{1}'' -HistorySaveStyle SaveAtExit {2}; & {{ $__ghostty_utf8_console = $false; . ''{3}'' }}"' -f
            $Exe, $historyPath, $ExtraOptions, $integration)
    }

    function Start-SyncNoctty([string] $Name, [string] $Shell, [string] $PSReadLineOptions = '', [string[]] $History = @(), [int] $Cols = 80, [int] $Rows = 22) {
        $shellCommand = switch ($Shell) {
            'cmd' { 'cmd.exe' }
            'powershell' { Get-SyncPowerShellCommand 'powershell.exe' $Name $PSReadLineOptions $History }
            'pwsh' { Get-SyncPowerShellCommand 'pwsh.exe' $Name $PSReadLineOptions $History }
            default { throw "unknown shell $Shell" }
        }
        $shellExe = "$Shell.exe"
        # A config file rather than flags: the PowerShell command line holds
        # quotes that do not survive another round of argv quoting.
        $config = @(
            'window-save-state = never'
            'confirm-close-surface = false'
            'quit-after-last-window-closed = true'
            'auto-update = off'
            'font-size = 12'
            "window-width = $Cols"
            "window-height = $Rows"
            'working-directory = C:\'
            "command = $shellCommand"
        )
        foreach ($entry in $script:SYNC_KEYBINDS.GetEnumerator()) {
            $config += ('keybind = {0}={1}' -f $script:SYNC_KEYBIND_NAMES[[int]$entry.Value], $entry.Key)
        }
        $configPath = Join-Path $script:Work "$Name.conf"
        [IO.File]::WriteAllLines($configPath, [string[]]$config, (New-Object System.Text.UTF8Encoding $false))
        # The shared composer adds the Job Object containment, a private
        # single-instance class per scenario, and nothing else.
        $arguments = @(Get-InteractiveWin11LaunchArguments -Layout ([ordered]@{ SandboxId = "conpty-sync-$Name" })) +
            @("`"--config-file=$configPath`"")
        $process = Start-Process -FilePath $script:Exe -ArgumentList $arguments -WorkingDirectory $script:Work -PassThru
        $ctx = [pscustomobject]@{
            Name = $Name; Shell = $Shell; ShellExe = $shellExe; Process = $process
            Host = [IntPtr]::Zero; Surface = [IntPtr]::Zero; ShellPid = 0
        }
        Wait-SyncCondition -Description 'noctty host window' -Condition {
            if ($process.HasExited) { throw "noctty exited early with $($process.ExitCode)" }
            $hosts = @([NocttyConptySyncNative]::TopWindows($process.Id, 'noctty.win32.host') |
                Where-Object { [NocttyConptySyncNative]::IsWindowVisible($_) })
            if ($hosts.Count -eq 0) { return $false }
            $ctx.Host = $hosts[0]
            $surfaces = @(Get-SyncSurfaces $ctx)
            if ($surfaces.Count -ne 1) { return $false }
            $ctx.Surface = $surfaces[0]
            return $true
        }
        Wait-SyncCondition -Description "$shellExe under noctty" -Condition {
            $pids = @(Get-SyncShellPids $ctx)
            if ($pids.Count -eq 0) { return $false }
            $ctx.ShellPid = $pids[0]
            return $true
        }
        Wait-SyncCondition -Description 'first prompt' -Condition {
            ((Read-SyncNoctty $ctx.Surface) -join "`n").Contains('>')
        }
        if ($Shell -ne 'cmd') {
            # The scenarios mean nothing without the integration's prompt
            # marks (redraw=0), so prove it loaded.
            Send-SyncText $ctx.Surface ("if ((Get-Command __ghostty_write_osc -ErrorAction Ignore) -and (Get-PSReadLineOption).HistorySavePath.StartsWith('$($script:Work)')) { 'integration=' + 'on' } else { 'integration=' + 'off' }`r")
            Wait-SyncCondition -Description 'integration check' -Condition {
                $text = (Read-SyncNoctty $ctx.Surface) -join "`n"
                if ($text.Contains('integration=off')) { throw 'the PowerShell integration did not load, or PSReadLine history is not redirected' }
                $text.Contains('integration=on')
            }
        }
        Write-SyncLog ('{0}: noctty pid={1} shell pid={2} host=0x{3:X}' -f $Name, $process.Id, $ctx.ShellPid, $ctx.Host.ToInt64())
        return $ctx
    }

    function Stop-SyncNoctty($Ctx) {
        if ($null -eq $Ctx) { return }
        $process = $Ctx.Process
        if ($process.HasExited) { return }
        foreach ($h in [NocttyConptySyncNative]::TopWindows($process.Id, 'noctty.win32.host')) {
            [void][NocttyConptySyncNative]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        }
        if (-not $process.WaitForExit(10000)) {
            # Exact process we started; the job object takes its children.
            Write-SyncLog "$($Ctx.Name): noctty pid=$($process.Id) did not close, terminating it"
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
    }

    function Get-SyncHostRect($Ctx) {
        $r = New-Object NocttyConptySyncNative+RECT
        [void][NocttyConptySyncNative]::GetWindowRect($Ctx.Host, [ref]$r)
        return $r
    }

    # SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
    function Set-SyncHostSize($Ctx, [int] $Width, [int] $Height) {
        [void][NocttyConptySyncNative]::SetWindowPos($Ctx.Host, [IntPtr]::Zero, 0, 0, $Width, $Height, 0x0016)
    }

    function Resize-SyncHost($Ctx, [double] $WidthFactor, [double] $HeightFactor) {
        $r = Get-SyncHostRect $Ctx
        Set-SyncHostSize $Ctx ([int](($r.Right - $r.Left) * $WidthFactor)) ([int](($r.Bottom - $r.Top) * $HeightFactor))
    }

    function Send-SyncBinding($Ctx, [string] $Action, [IntPtr] $Target = [IntPtr]::Zero) {
        if ($Target -eq [IntPtr]::Zero) { $Target = $Ctx.Surface }
        Send-SyncKey $Target ([int]$script:SYNC_KEYBINDS[$Action]) -MayDestroy:($Action -eq 'close_surface')
    }

    # Wait until ConPTY reports a grid the predicate accepts, so a trigger
    # that silently did nothing cannot pass as "in sync".
    function Wait-SyncGrid($Ctx, [scriptblock] $Predicate, [string] $Description) {
        $script:SyncLastGrid = $null
        Wait-SyncCondition -Description $Description -TimeoutMs 10000 -Condition {
            $dump = Read-SyncConpty $Ctx.ShellPid
            $script:SyncLastGrid = $dump
            & $Predicate $dump
        }
        Write-SyncLog "$($Ctx.Name): $Description -> $($script:SyncLastGrid.Header)"
        return $script:SyncLastGrid
    }

    # -- shell setups ---------------------------------------------------------

    function Invoke-SyncFill($Ctx, [int] $Count = 40) {
        $command = switch ($Ctx.Shell) {
            'cmd' { "for /L %i in (1,1,$Count) do @echo L%i" }
            default { "1..$Count | % { 'L' + `$_ }" }
        }
        Send-SyncText $Ctx.Surface ($command + "`r")
        Wait-SyncText $Ctx ("L$Count")
    }

    # Rows R01..R20 with the cursor parked on R06 by the console API, and a
    # key read that then writes <W1> at the cursor without moving it: the
    # shape of a TUI footer, or PSReadLine's ListView, below the cursor.
    function Invoke-SyncParkCursor($Ctx, [int] $Width = 0) {
        $line = if ($Width -gt 0) { "('R{0:D2} ' + 'x' * $($Width - 4))" } else { "'R{0:D2}'" }
        $script = "1..20 | % { $line -f `$_ }; [Console]::SetCursorPosition(0, [Console]::CursorTop - 15); [void][Console]::ReadKey(`$true); [Console]::Write('<W' + '1>'); [void][Console]::ReadKey(`$true)"
        Send-SyncText $Ctx.Surface ("cls; " + $script + "`r")
        Wait-SyncText $Ctx 'R20'
    }

    function Get-SyncVim {
        $vim = Get-Command vim.exe -ErrorAction Ignore | Select-Object -First 1
        if ($vim) { return $vim.Source }
        $git = Join-Path $env:ProgramFiles 'Git\usr\bin\vim.exe'
        if (Test-Path -LiteralPath $git -PathType Leaf) { return $git }
        return $null
    }

    # -- scenarios ------------------------------------------------------------
    # Each returns after its trigger; the runner then compares, types the
    # marker and compares again.

    $script:Scenarios = @(
        [pscustomobject]@{
            Name = 'baseline-cmd'; Shell = 'cmd'; Expect = 'sync'; Finding = 'control'
            Description = '40 lines of cmd output, no trigger'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = { param($c) }
        }
        [pscustomobject]@{
            Name = 'minimize-restore-cmd'; Shell = 'cmd'; Expect = 'sync'; Finding = '#262'
            Description = 'minimize and restore with the prompt at the bottom'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                [void][NocttyConptySyncNative]::ShowWindow($c.Host, 7) # SW_SHOWMINNOACTIVE
                Wait-SyncCondition -Description 'minimized' -Condition { [NocttyConptySyncNative]::IsIconic($c.Host) }
                Start-Sleep -Milliseconds 500
                [void][NocttyConptySyncNative]::ShowWindow($c.Host, 4) # SW_SHOWNOACTIVATE
                Wait-SyncCondition -Description 'restored' -Condition { -not [NocttyConptySyncNative]::IsIconic($c.Host) }
            }
        }
        [pscustomobject]@{
            Name = 'shrink-rows-bottom-cmd'; Shell = 'cmd'; Expect = 'sync'; Finding = 'control'
            Description = 'rows shrink with the prompt on the bottom row'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Resize-SyncHost $c 1.0 0.6
                [void](Wait-SyncGrid $c { param($d) $d.Rows -lt $before.Rows } 'rows shrink')
            }
        }
        [pscustomobject]@{
            Name = 'grow-rows-cursor-top-cmd'; Shell = 'cmd'; Expect = 'sync'; Finding = 'control'
            Description = 'rows grow after cls, cursor near the top'
            Setup = {
                param($c)
                Invoke-SyncFill $c
                Send-SyncText $c.Surface "cls`r"
                Wait-SyncCondition -Description 'cleared' -Condition { -not (((Read-SyncNoctty $c.Surface) -join "`n").Contains('L40')) }
            }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Resize-SyncHost $c 1.0 1.4
                [void](Wait-SyncGrid $c { param($d) $d.Rows -gt $before.Rows } 'rows grow')
            }
        }
        [pscustomobject]@{
            Name = 'unicode-powershell'; Shell = 'powershell'; Expect = 'sync'; Finding = 'normalisation'
            Description = 'wide, surrogate-pair and VS16 cells compare equal'
            Setup = {
                param($c)
                $text = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; 'wide:' + [char]0x4E2D + [char]0x6587 + ' pair:' + [char]::ConvertFromUtf32(0x1F600) + ' vs16:' + [char]0x2764 + [char]0xFE0F + ' end'"
                Send-SyncText $c.Surface ($text + "`r")
                Wait-SyncText $c ('wide:' + [char]0x4E2D + [char]0x6587)
            }
            Trigger = { param($c) }
        }
        [pscustomobject]@{
            Name = 'grow-rows-cmd'; Shell = 'cmd'; Expect = 'desync'; Finding = 'F015'
            Description = 'enlarge the window with the prompt at the bottom'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Resize-SyncHost $c 1.0 1.4
                [void](Wait-SyncGrid $c { param($d) $d.Rows -gt $before.Rows } 'rows grow')
            }
        }
        [pscustomobject]@{
            Name = 'search-bar-cmd'; Shell = 'cmd'; Expect = 'desync'; Finding = 'F015'
            Description = 'open and close the search bar with the prompt at the bottom'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Send-SyncBinding $c 'start_search'
                [void](Wait-SyncGrid $c { param($d) $d.Rows -lt $before.Rows } 'search bar takes rows')
                Send-SyncBinding $c 'end_search'
                [void](Wait-SyncGrid $c { param($d) $d.Rows -eq $before.Rows } 'search bar gives rows back')
            }
        }
        [pscustomobject]@{
            Name = 'split-cmd'; Shell = 'cmd'; Expect = 'desync'; Finding = 'F015'
            Description = 'open a split below and close it again'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Send-SyncBinding $c 'new_split:down'
                Wait-SyncCondition -Description 'second pane' -Condition { @(Get-SyncSurfaces $c).Count -eq 2 }
                [void](Wait-SyncGrid $c { param($d) $d.Rows -lt $before.Rows } 'split takes rows')
                $other = @(Get-SyncSurfaces $c | Where-Object { $_ -ne $c.Surface })[0]
                Wait-SyncCondition -Description 'second shell' -Condition { @(Get-SyncShellPids $c).Count -eq 2 }
                Start-Sleep -Milliseconds 500
                Send-SyncBinding $c 'close_surface' $other
                Wait-SyncCondition -Description 'second pane closed' -Condition { @(Get-SyncSurfaces $c).Count -eq 1 }
                [void](Wait-SyncGrid $c { param($d) $d.Rows -eq $before.Rows } 'rows back')
            }
        }
        [pscustomobject]@{
            Name = 'maximize-cmd'; Shell = 'cmd'; Expect = 'desync'; Finding = 'F015'
            Description = 'maximize with the prompt at the bottom'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                [void][NocttyConptySyncNative]::ShowWindow($c.Host, 3) # SW_MAXIMIZE
                [void](Wait-SyncGrid $c { param($d) $d.Rows -gt $before.Rows } 'maximized grid')
            }
        }
        [pscustomobject]@{
            Name = 'maximize-restore-cmd'; Shell = 'cmd'; Expect = 'sync'; Finding = 'round trip'
            Description = 'maximize and restore with the prompt at the bottom (in sync only as a round trip: the restore undoes what the maximize pulled)'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                [void][NocttyConptySyncNative]::ShowWindow($c.Host, 3) # SW_MAXIMIZE
                [void](Wait-SyncGrid $c { param($d) $d.Rows -gt $before.Rows } 'maximized grid')
                Start-Sleep -Milliseconds 500
                [void][NocttyConptySyncNative]::ShowWindow($c.Host, 9) # SW_RESTORE
                [void](Wait-SyncGrid $c { param($d) $d.Rows -eq $before.Rows } 'restored grid')
            }
        }
        [pscustomobject]@{
            Name = 'listview-split-pwsh'; Shell = 'pwsh'; Expect = 'sync'; Finding = 'control'
            Description = 'PSReadLine ListView open below the prompt, open a split below and close it'
            Requires = { if (-not (Get-Command pwsh.exe -ErrorAction Ignore)) { 'pwsh.exe is not installed' } }
            PSReadLine = '-PredictionSource History -PredictionViewStyle ListView'
            History = @('Get-Help about_Profiles', 'Get-Help about_Prompts', 'Get-Help about_Parsing', 'Get-Help about_Pipelines', 'Get-Help about_Providers')
            Setup = {
                param($c)
                Invoke-SyncFill $c
                Send-SyncText $c.Surface 'Get-Help about_P'
                Wait-SyncText $c 'about_Providers'
            }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Send-SyncBinding $c 'new_split:down'
                Wait-SyncCondition -Description 'second pane' -Condition { @(Get-SyncSurfaces $c).Count -eq 2 }
                [void](Wait-SyncGrid $c { param($d) $d.Rows -lt $before.Rows } 'split takes rows')
                $other = @(Get-SyncSurfaces $c | Where-Object { $_ -ne $c.Surface })[0]
                Wait-SyncCondition -Description 'second shell' -Condition { @(Get-SyncShellPids $c).Count -eq 2 }
                Start-Sleep -Milliseconds 500
                Send-SyncBinding $c 'close_surface' $other
                Wait-SyncCondition -Description 'second pane closed' -Condition { @(Get-SyncSurfaces $c).Count -eq 1 }
                [void](Wait-SyncGrid $c { param($d) $d.Rows -eq $before.Rows } 'rows back')
            }
        }
        [pscustomobject]@{
            Name = 'listview-narrow-pwsh'; Shell = 'pwsh'; Expect = 'sync'; Finding = 'control'
            Description = 'PSReadLine ListView open below the prompt, narrow the window until its rows wrap'
            Requires = { if (-not (Get-Command pwsh.exe -ErrorAction Ignore)) { 'pwsh.exe is not installed' } }
            PSReadLine = '-PredictionSource History -PredictionViewStyle ListView'
            History = @('Get-Help about_Profiles', 'Get-Help about_Prompts', 'Get-Help about_Parsing', 'Get-Help about_Pipelines', 'Get-Help about_Providers')
            Setup = {
                param($c)
                Invoke-SyncFill $c
                Send-SyncText $c.Surface 'Get-Help about_P'
                Wait-SyncText $c 'about_Providers'
            }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Resize-SyncHost $c 0.6 1.0
                [void](Wait-SyncGrid $c { param($d) $d.Cols -lt $before.Cols } 'narrower')
            }
        }
        [pscustomobject]@{
            Name = 'vim-maximize-powershell'; Shell = 'powershell'; Expect = 'desync'; Finding = 'F015'
            Description = 'run vim, maximize, quit vim'
            Requires = { if (-not (Get-SyncVim)) { 'vim.exe (Git for Windows) is not installed' } }
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Send-SyncText $c.Surface ("& '$(Get-SyncVim)' -u NONE -N -i NONE -n`r")
                Wait-SyncCondition -Description 'vim running' -Condition { @(Get-SyncDescendants $c.ShellPid | Where-Object Name -ieq 'vim.exe').Count -gt 0 }
                Wait-SyncText $c 'Vi IMproved'
                [void][NocttyConptySyncNative]::ShowWindow($c.Host, 3) # SW_MAXIMIZE
                [void](Wait-SyncGrid $c { param($d) $d.Rows -gt $before.Rows } 'maximized grid')
                # vim can drop keys typed while it redraws for the new size,
                # so ask again until it is gone.
                for ($attempt = 1; ; $attempt++) {
                    Start-Sleep -Milliseconds 500
                    Send-SyncKey $c.Surface 0x1B 27
                    Send-SyncText $c.Surface ":q`r"
                    try {
                        Wait-SyncCondition -Description 'vim exited' -TimeoutMs 4000 -Condition { @(Get-SyncDescendants $c.ShellPid | Where-Object Name -ieq 'vim.exe').Count -eq 0 }
                        break
                    }
                    catch { if ($attempt -ge 3) { throw } }
                }
            }
        }
        [pscustomobject]@{
            Name = 'narrow-widen-powershell'; Shell = 'powershell'; Expect = 'desync'; Finding = 'F015'
            Description = 'narrow until lines wrap, then widen back, prompt at the bottom'
            Setup = {
                param($c)
                Send-SyncText $c.Surface ("1..40 | % { 'L{0:D2} ' -f `$_ + 'w' * 60 }`r")
                Wait-SyncText $c 'L40 '
            }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                $rect = Get-SyncHostRect $c
                Resize-SyncHost $c 0.6 1.0
                [void](Wait-SyncGrid $c { param($d) $d.Cols -lt $before.Cols } 'narrower')
                Start-Sleep -Milliseconds 500
                Set-SyncHostSize $c ($rect.Right - $rect.Left) ($rect.Bottom - $rect.Top)
                [void](Wait-SyncGrid $c { param($d) $d.Cols -eq $before.Cols } 'wide again')
            }
        }
        [pscustomobject]@{
            Name = 'altscreen-maximize-powershell'; Shell = 'powershell'; Expect = 'desync'; Finding = 'F015'
            Description = 'maximize while a full-screen program runs, then leave it (the vim exit case)'
            Setup = { param($c) Invoke-SyncFill $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                $app = "[Console]::Write([char]27 + '[?1049h' + [char]27 + '[HALT' + ' SCREEN'); [void][Console]::ReadKey(`$true); [Console]::Write([char]27 + '[?1049l')"
                Send-SyncText $c.Surface ($app + "`r")
                Wait-SyncText $c 'ALT SCREEN'
                [void][NocttyConptySyncNative]::ShowWindow($c.Host, 3) # SW_MAXIMIZE
                [void](Wait-SyncGrid $c { param($d) $d.Rows -gt $before.Rows } 'maximized grid')
                Start-Sleep -Milliseconds 500
                Send-SyncKey $c.Surface 0x51 ([int][char]'q')
                Wait-SyncCondition -Description 'left the alternate screen' -Condition { -not (((Read-SyncNoctty $c.Surface) -join "`n").Contains('ALT SCREEN')) }
            }
        }
        [pscustomobject]@{
            Name = 'shrink-rows-below-cursor-powershell'; Shell = 'powershell'; Expect = 'desync'; Finding = 'F032'
            Description = 'rows shrink with 15 rows of content below the cursor'
            Setup = { param($c) Invoke-SyncParkCursor $c }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Resize-SyncHost $c 1.0 0.5
                [void](Wait-SyncGrid $c { param($d) $d.Rows -lt $before.Rows } 'rows shrink')
                Start-Sleep -Milliseconds 300
                Send-SyncKey $c.Surface 0x20 32
                Wait-SyncText $c '<W1>'
            }
            NoMarker = $true
        }
        [pscustomobject]@{
            Name = 'shrink-cols-below-cursor-powershell'; Shell = 'powershell'; Expect = 'desync'; Finding = 'F032'
            Description = 'columns shrink so the 60-column rows below the cursor wrap'
            Setup = { param($c) Invoke-SyncParkCursor $c 60 }
            Trigger = {
                param($c)
                $before = Read-SyncConpty $c.ShellPid
                Resize-SyncHost $c 0.55 1.0
                [void](Wait-SyncGrid $c { param($d) $d.Cols -lt $before.Cols } 'columns shrink')
                Start-Sleep -Milliseconds 300
                Send-SyncKey $c.Surface 0x20 32
                Wait-SyncText $c '<W1>'
            }
            NoMarker = $true
        }
    )

    # `-Scenario a,b` reaches a -File child as one string (AGENTS.md).
    $Scenario = @($Scenario | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $selected = @($script:Scenarios)
    if ($Scenario.Count -gt 0) {
        $selected = @($script:Scenarios | Where-Object { $Scenario -contains $_.Name })
        $unknown = @($Scenario | Where-Object { $script:Scenarios.Name -notcontains $_ })
        if ($unknown.Count -gt 0) { throw "unknown scenario(s): $($unknown -join ', ')" }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($s in $selected) {
        $ctx = $null
        $result = [ordered]@{
            Name = $s.Name; Expect = $s.Expect; Finding = $s.Finding; Status = 'ERROR'
            Before = $null; After = $null; Marker = $null; Detail = ''
        }
        try {
            Write-SyncLog "=== $($s.Name): $($s.Description)"
            $missing = if ($s.Requires) { & $s.Requires } else { $null }
            if ($missing) {
                $result.Status = 'SKIP'
                $result.Detail = $missing
                $results.Add([pscustomobject]$result)
                Write-SyncLog "$($s.Name): SKIP $missing"
                continue
            }
            $ctx = Start-SyncNoctty $s.Name $s.Shell $s.PSReadLine @($s.History)
            & $s.Setup $ctx
            $before = Get-SyncComparison $ctx 'before'
            $result.Before = $before.Diff
            if ($before.Diff -ne 0) {
                $result.Status = 'FAIL'
                $result.Detail = "views differ before the trigger ($($before.File)); the scenario cannot judge the trigger"
            }
            else {
                & $s.Trigger $ctx
                $after = Get-SyncComparison $ctx 'after'
                $result.After = $after.Diff
                $markerDiff = 0
                if (-not $s.NoMarker) {
                    Send-SyncText $ctx.Surface 'echo synced'
                    Wait-SyncText $ctx 'echo synced'
                    $marker = Get-SyncComparison $ctx 'marker'
                    $markerDiff = $marker.Diff
                    $result.Marker = $marker.Diff
                }
                $desynced = ($after.Diff -gt 0) -or ($markerDiff -gt 0)
                if ($s.Expect -eq 'sync') {
                    $result.Status = if ($desynced) { 'FAIL' } else { 'PASS' }
                }
                else {
                    $result.Status = if ($desynced) { 'XFAIL' } else { 'XPASS' }
                }
                $result.Detail = $after.File
            }
        }
        catch {
            $result.Status = 'ERROR'
            $result.Detail = "$($_.Exception.Message) $($_.ScriptStackTrace -replace "`r?`n", ' | ')"
            if ($null -ne $ctx -and $ctx.ShellPid -ne 0) {
                try { [void](Get-SyncComparison $ctx 'error' -SettleMs 0 -MaxMs 0 -RequireSettled $false) } catch { Write-SyncLog "no error snapshot: $($_.Exception.Message)" }
            }
        }
        finally {
            try { Stop-SyncNoctty $ctx } catch { Write-SyncLog "stop failed: $($_.Exception.Message)" }
        }
        Write-SyncLog ('{0}: {1} before={2} after={3} marker={4} {5}' -f $result.Name, $result.Status, $result.Before, $result.After, $result.Marker, $result.Detail)
        $results.Add([pscustomobject]$result)
    }
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 0
}

# ===========================================================================
# Outer half: build, stage, run the inner half on a hidden desktop, report.
# ===========================================================================
if ($ListScenarios) {
    Get-Content -LiteralPath $launcherPath | Select-String -Pattern "^\s+Name = '([^']+)'; Shell = '([^']+)'; Expect = '([^']+)'; Finding = '([^']+)'" |
        ForEach-Object { '{0,-38} {1,-11} expect={2,-7} {3}' -f $_.Matches[0].Groups[1].Value, $_.Matches[0].Groups[2].Value, $_.Matches[0].Groups[3].Value, $_.Matches[0].Groups[4].Value }
    exit 0
}
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be greater than 0.' }

$forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
if ($Scenario.Count -gt 0) { $forwardedArgs += @('-Scenario', ($Scenario -join ',')) }
if ($Rebuild) { $forwardedArgs += '-Rebuild' }
if ($NoBuild) { $forwardedArgs += '-NoBuild' }
if ($ResetState) { $forwardedArgs += '-ResetState' }
Invoke-InteractiveWin11HarnessMain `
    -RepoRoot $repoRoot `
    -LauncherPath $launcherPath `
    -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_CONPTY_SYNC_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

# `-Scenario a,b` reaches a bootstrapped child as one string (AGENTS.md).
$Scenario = @($Scenario | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'conpty-sync' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$action = Get-InteractiveWin11LaunchAction -ExePath $exePath -BuildInputs (Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot) -Rebuild:$Rebuild -NoBuild:$NoBuild
if ($action -eq 'build') { Invoke-InteractiveWin11Build -RepoRoot $repoRoot -Optimize ReleaseFast }
Assert-InteractiveWin11ExeExists -ExePath $exePath

$realStartupBefore = Get-ConptySyncRealStartupAttempts

# Stage a portable copy. noctty only ever runs from here.
$runRoot = Join-Path $layout.SandboxRoot 'run'
$sandboxPrefix = (Get-InteractiveWin11NormalizedPath -Path $layout.SandboxRoot) + '\'
$normalizedRunRoot = Get-InteractiveWin11NormalizedPath -Path $runRoot
if (-not $normalizedRunRoot.StartsWith($sandboxPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "refusing to stage outside the sandbox: $normalizedRunRoot" }
if (Test-Path -LiteralPath $normalizedRunRoot) { [System.IO.Directory]::Delete($normalizedRunRoot, $true) }
$zigOut = Join-Path $repoRoot 'zig-out'
New-Item -ItemType Directory -Force -Path (Join-Path $runRoot 'bin'), (Join-Path $runRoot 'tools') | Out-Null
foreach ($file in @('noctty.exe', 'conpty.dll', 'OpenConsole.exe')) {
    $source = Join-Path $zigOut "bin\$file"
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "missing $source (the bundled ConPTY is part of every build since #313)" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $runRoot 'bin')
}
Copy-Item -LiteralPath (Join-Path $zigOut 'share') -Destination (Join-Path $runRoot 'share') -Recurse
Set-Content -LiteralPath (Join-Path $runRoot 'bin\noctty.portable') -Value 'conpty-sync harness' -Encoding ASCII
Copy-Item -LiteralPath (Join-Path $repoRoot 'src\shell-integration\powershell\integration.ps1') -Destination (Join-Path $runRoot 'tools')
Add-Type -TypeDefinition $script:ConptySyncDumpSource -OutputAssembly (Join-Path $runRoot 'tools\conpty-sync-dump.exe') -OutputType ConsoleApplication

$historyLeaksBefore = Get-ConptySyncRealPSReadLineLeaks (Join-Path $runRoot 'work')

# A short prompt keeps cmd's line from wrapping; the integration keeps it.
$env:PROMPT = 'sync$G'
$resultPath = Join-Path $layout.Logs 'conpty-sync-results.json'
if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }

$desktopName = 'noctty-conpty-sync-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$desktop = [NocttyConptySyncNative]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
if ($desktop -eq [IntPtr]::Zero) { throw "CreateDesktopW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$job = [NocttyConptySyncNative]::NewKillOnCloseJob()
if ($job -eq [IntPtr]::Zero) { [void][NocttyConptySyncNative]::CloseDesktop($desktop); throw 'could not create the cleanup job object' }
$innerExit = $null
try {
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $innerArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$launcherPath`"", '-Inner',
        '-RunRoot', "`"$runRoot`"", '-ResultPath', "`"$resultPath`"")
    if ($Scenario.Count -gt 0) { $innerArgs += @('-Scenario', ($Scenario -join ',')) }
    $commandLine = New-Object System.Text.StringBuilder ("`"$powershell`" " + ($innerArgs -join ' '))
    $si = New-Object NocttyConptySyncNative+STARTUPINFO
    $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][NocttyConptySyncNative+STARTUPINFO])
    $si.lpDesktop = "WinSta0\$desktopName"
    $si.lpReserved = [NullString]::Value
    $si.lpTitle = [NullString]::Value
    $pi = New-Object NocttyConptySyncNative+PROCESS_INFORMATION
    # CREATE_SUSPENDED | CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS:
    # suspended so it is in the job before it can start anything.
    if (-not [NocttyConptySyncNative]::CreateProcessW([NullString]::Value, $commandLine, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0x08004004, [IntPtr]::Zero, $repoRoot, [ref]$si, [ref]$pi)) {
        throw "CreateProcessW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    try {
        if (-not [NocttyConptySyncNative]::AssignProcessToJobObject($job, $pi.hProcess)) {
            $assignError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            # It is still suspended and outside the job: end this exact
            # process before its handle goes.
            [void][NocttyConptySyncNative]::TerminateProcess($pi.hProcess, 1)
            throw "AssignProcessToJobObject failed: $assignError"
        }
        [void][NocttyConptySyncNative]::ResumeThread($pi.hThread)
        $wait = [NocttyConptySyncNative]::WaitForSingleObject($pi.hProcess, [uint32]($TimeoutSeconds * 1000))
        if ($wait -eq 0) {
            $code = [uint32]0
            [void][NocttyConptySyncNative]::GetExitCodeProcess($pi.hProcess, [ref]$code)
            $innerExit = [int]$code
        }
    }
    finally {
        [void][NocttyConptySyncNative]::CloseHandle($pi.hThread)
        [void][NocttyConptySyncNative]::CloseHandle($pi.hProcess)
    }
}
finally {
    # Closing the job ends anything the inner half left running.
    [void][NocttyConptySyncNative]::CloseHandle($job)
    [void][NocttyConptySyncNative]::CloseDesktop($desktop)
}

$innerLog = Join-Path $runRoot 'evidence\inner.log'
if (Test-Path -LiteralPath $innerLog) { Get-Content -LiteralPath $innerLog | ForEach-Object { Write-Host $_ } }

$realStartupAfter = Get-ConptySyncRealStartupAttempts
if ($realStartupAfter -ne $realStartupBefore) {
    throw "the real profile's startup-attempts.json changed during the run: before=$realStartupBefore after=$realStartupAfter"
}
$historyToken = Join-Path $runRoot 'work'
if ((Get-ConptySyncRealPSReadLineLeaks $historyToken) -gt $historyLeaksBefore) {
    throw "a scenario command reached the real PSReadLine history (lines containing $historyToken)"
}
if ($null -eq $innerExit) { throw "the hidden-desktop driver did not finish within $TimeoutSeconds s (evidence: $runRoot\evidence)" }
if ($innerExit -ne 0) { throw "the hidden-desktop driver exited with $innerExit (evidence: $runRoot\evidence)" }
if (-not (Test-Path -LiteralPath $resultPath)) { throw "no results at $resultPath" }

# Windows PowerShell's ConvertFrom-Json emits a JSON array as one object.
$results = @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$bad = @()
foreach ($r in $results) {
    Write-Host ('{0,-6} {1,-38} expect={2,-7} {3,-13} before={4} after={5} marker={6}' -f $r.Status, $r.Name, $r.Expect, $r.Finding, $r.Before, $r.After, $r.Marker)
    if ($r.Status -eq 'XPASS') {
        Write-Host "       $($r.Name) no longer desyncs: remove its Expect = 'desync' mark."
    }
    if ($r.Status -notin @('PASS', 'XFAIL', 'SKIP')) {
        Write-Host "       $($r.Detail)"
        $bad += $r.Name
    }
}
if ($bad.Count -gt 0) {
    throw "interactive-win11 conpty-sync validation failed: $($bad -join ', ') (evidence: $runRoot\evidence)"
}
$passCount = @($results | Where-Object Status -eq 'PASS').Count
$xfailCount = @($results | Where-Object Status -eq 'XFAIL').Count
$skipCount = @($results | Where-Object Status -eq 'SKIP').Count
Write-Host ("interactive-win11 conpty-sync validation: PASS (scenarios={0}, in-sync={1}, known-desync={2}, skipped={3}, evidence={4})" -f $results.Count, $passCount, $xfailCount, $skipCount, (Join-Path $runRoot 'evidence'))
