#requires -Version 7.0
<#
Portable, hidden-desktop check of the split dividers under the mouse
(`Host.handlePaneDividerMessage`, `Host.paneDividerAtScreen`,
`App.paneDividerDragKey`): the hit zone each pane leaves to the host, the
hover cursor's WM_SETCURSOR answer, a drag that resizes live and reflows
both shells (their ConPTY columns, read with AttachConsole from a helper
process), Esc, a capture loss, a double-click, a zoomed tab and a nested
split. Run with -Bin <source bin directory> -Run <new evidence directory>.
The run directory must not already exist.

Never switches desktops, injects real input or touches the clipboard: every
action is a posted or sent window message to a scratch portable copy on a
private desktop, with LOCALAPPDATA and APPDATA redirected
(hidden-win11-local-lib.ps1), `window-save-state = never`, and every pane
running cmd.exe with AutoRun off. GetClipboardSequenceNumber, the real
startup-attempts.json and the real PSReadLine history files are checked
before and after. A posted-message pass is not a real-input pass: the
system's own routing of a click through HTTRANSPARENT, the cursor shape the
user sees, and real Alt+Tab are not exercised. Results contain only window
geometry, hit-test codes, console sizes, process IDs and assertions. It
exits 1 when a check fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 300,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Pd {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiThreadInfo {
        public int cbSize, flags; public IntPtr active, focus, capture, menuOwner, moveSize, caret; public Rect caretRect;
    }
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref Point p);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref Point p);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int show);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(int thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(int from, int to, bool attach);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll")] static extern int GetCurrentThreadId();
    // Clears the keyboard state of the UI thread that owns `h`, so a posted
    // key reads no modifier the person at the real keyboard holds: this
    // thread joins that thread's input queue for the call, no input is sent.
    public static void ClearKeys(IntPtr h) {
        int pid; int tid = GetWindowThreadProcessId(h, out pid); int me = GetCurrentThreadId();
        if (!AttachThreadInput(me, tid, true)) throw new Exception("AttachThreadInput failed");
        try { if (!SetKeyboardState(new byte[256])) throw new Exception("SetKeyboardState failed"); }
        finally { AttachThreadInput(me, tid, false); }
    }
    // Whether Shift, Ctrl or Alt is down at the real keyboard now.
    public static bool RealModifierDown() {
        return (GetAsyncKeyState(0x10) & 0x8000) != 0 || (GetAsyncKeyState(0x11) & 0x8000) != 0 || (GetAsyncKeyState(0x12) & 0x8000) != 0;
    }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    public static uint Dpi(IntPtr h) { return GetDpiForWindow(h); }
    static IntPtr Pos(int x, int y) { return new IntPtr(((y & 0xFFFF) << 16) | (x & 0xFFFF)); }
    // `h`'s window rect in `host`'s client coordinates (per-monitor aware).
    public static Rect ClientRectIn(IntPtr host, IntPtr h) {
        var old = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect r; if (!GetWindowRect(h, out r)) throw new Exception("Window measurement failed");
            var a = new Point { X = r.Left, Y = r.Top }; var b = new Point { X = r.Right, Y = r.Bottom };
            ScreenToClient(host, ref a); ScreenToClient(host, ref b);
            return new Rect { Left = a.X, Top = a.Y, Right = b.X, Bottom = b.Y };
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static Point ToScreen(IntPtr host, int x, int y) {
        var old = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { var p = new Point { X = x, Y = y }; ClientToScreen(host, ref p); return p; }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    static long Send(IntPtr h, uint m, IntPtr w, IntPtr l) {
        IntPtr result;
        if (SendMessageTimeoutW(h, m, w, l, 0x2, 3000, out result) == IntPtr.Zero) throw new Exception("SendMessageTimeout failed");
        return result.ToInt64();
    }
    // `h`'s WM_NCHITTEST answer at host client point (x, y), as a sign-extended code.
    public static int HitTest(IntPtr host, IntPtr h, int x, int y) {
        var p = ToScreen(host, x, y);
        return (int)Send(h, 0x84, IntPtr.Zero, Pos(p.X, p.Y));
    }
    // What real input would reach first at host client point (x, y): the
    // deepest window, then up through each HTTRANSPARENT answer.
    public static IntPtr Under(IntPtr host, int x, int y) {
        var p = ToScreen(host, x, y);
        var old = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { return WindowFromPoint(p); } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static long SetCursor(IntPtr host) {
        return Send(host, 0x20, host, new IntPtr((0x200 << 16) | 1)); // HTCLIENT, WM_MOUSEMOVE
    }
    public static void Post(IntPtr h, uint m, int w, int x, int y) {
        if (!PostMessageW(h, m, new IntPtr(w), Pos(x, y))) throw new Exception("Post failed");
    }
    public static void Key(IntPtr h, int key) {
        if (!PostMessageW(h, 0x100, new IntPtr(key), new IntPtr(1))) throw new Exception("Key-down post failed");
        if (!PostMessageW(h, 0x101, new IntPtr(key), new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    static GuiThreadInfo Info(IntPtr h) {
        int pid; int tid = GetWindowThreadProcessId(h, out pid);
        var info = new GuiThreadInfo(); info.cbSize = Marshal.SizeOf<GuiThreadInfo>();
        if (!GetGUIThreadInfo(tid, ref info)) throw new Exception("GetGUIThreadInfo failed");
        return info;
    }
    public static IntPtr CaptureOf(IntPtr h) { return Info(h).capture; }
    public static IntPtr FocusOf(IntPtr h) { return Info(h).focus; }
}
'@

# The console reader runs in its own process: AttachConsole changes the
# console of the whole calling process. It writes "<columns> <rows>" of the
# shell's visible window, or with "input" the number of Esc key records waiting
# in its console (read, never taken), nothing of the screen's contents.
$script:ConsoleSizeSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class PaneDividerConsoleSize {
    // Public so the harness can pin their layout against the SDK.
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct CSBI { public COORD dwSize, dwCursorPosition; public ushort wAttributes; public SMALL_RECT srWindow; public COORD dwMaximumWindowSize; }
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI i);
    [StructLayout(LayoutKind.Sequential)] public struct KEY_EVENT_RECORD { public int bKeyDown; public ushort wRepeatCount, wVirtualKeyCode, wVirtualScanCode, UnicodeChar; public uint dwControlKeyState; }
    // The SDK's Event is a union of 4-byte-aligned records, the largest 16 bytes.
    [StructLayout(LayoutKind.Explicit, Size = 20)] public struct INPUT_RECORD { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool PeekConsoleInputW(IntPtr h, [Out] INPUT_RECORD[] buffer, uint length, out uint read);
    public static int Main(string[] args) {
        string text; int rc = 0;
        FreeConsole();
        if (!AttachConsole(uint.Parse(args[0]))) { text = "ERROR attach " + Marshal.GetLastWin32Error(); rc = 4; }
        else if (args.Length > 2 && args[2] == "input") {
            // The input records waiting in the console, which a program that
            // does not read its input (ping) leaves there. Read, never taken.
            IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            // Only Esc key records count: a resize or a focus change queues
            // records of its own.
            var records = new INPUT_RECORD[4096]; uint n;
            if (h == new IntPtr(-1)) { text = "ERROR conin " + Marshal.GetLastWin32Error(); rc = 5; }
            else if (!PeekConsoleInputW(h, records, (uint)records.Length, out n)) { text = "ERROR peek " + Marshal.GetLastWin32Error(); rc = 6; CloseHandle(h); }
            else {
                int escapes = 0;
                for (int i = 0; i < n; i++) if (records[i].EventType == 1 && records[i].KeyEvent.wVirtualKeyCode == 0x1B) escapes++;
                text = escapes.ToString(); CloseHandle(h);
            }
            FreeConsole();
        }
        else {
            IntPtr h = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            CSBI info;
            if (h == new IntPtr(-1)) { text = "ERROR conout " + Marshal.GetLastWin32Error(); rc = 5; }
            else if (!GetConsoleScreenBufferInfo(h, out info)) { text = "ERROR csbi " + Marshal.GetLastWin32Error(); rc = 6; CloseHandle(h); }
            else { text = (info.srWindow.Right - info.srWindow.Left + 1) + " " + (info.srWindow.Bottom - info.srWindow.Top + 1); CloseHandle(h); }
            FreeConsole();
        }
        File.WriteAllText(args[1], text);
        return rc;
    }
}
'@

if (-not $Driver) {
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds `
        -ExpectedStartupHash $ExpectedStartupHash -ExpectedStartupModified $ExpectedStartupModified `
        -DesktopPrefix 'noctty-panediv-' -Label 'Hidden pane divider' -PassDesktopName -GuardClipboard
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Pd]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks = [Collections.Generic.List[object]]::new()
$script:samples = [Collections.Generic.List[object]]::new()
$script:processes = [Collections.Generic.List[object]]::new()
$script:interfered = [Collections.Generic.List[int]]::new()
$desktopPath = "WinSta0\$DesktopName"
$runClass = 'noctty-test-panediv-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$tools = Join-Path $Run 'tools'; [void](New-Item -ItemType Directory -Path $tools)
$sizeExe = Join-Path $tools 'pane-divider-console-size.exe'
# PowerShell 7's Add-Type cannot write a console executable; Windows
# PowerShell 5.1 can. It runs hidden, with no console window of its own.
# The paths reach it as arguments of a script, never inside a command
# string, so a quote in the run directory cannot break the command.
$sizeSource = Join-Path $tools 'pane-divider-console-size.cs'
[IO.File]::WriteAllText($sizeSource, $script:ConsoleSizeSource)
$compileScript = Join-Path $tools 'pane-divider-compile.ps1'
[IO.File]::WriteAllText($compileScript, (@(
    'param([string] $Source, [string] $Output)'
    'Add-Type -TypeDefinition ([IO.File]::ReadAllText($Source)) -OutputAssembly $Output -OutputType ConsoleApplication'
) -join "`r`n"))
$compile = [Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'))
foreach ($arg in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $compileScript, $sizeSource, $sizeExe)) { $compile.ArgumentList.Add($arg) }
$compile.UseShellExecute = $false; $compile.CreateNoWindow = $true
$compile.RedirectStandardOutput = $true; $compile.RedirectStandardError = $true
$compiler = [Diagnostics.Process]::Start($compile)
if (-not $compiler.WaitForExit(60000) -or -not (Test-Path -LiteralPath $sizeExe)) { throw 'Console size reader did not compile.' }
# The struct mirrors above, pinned against the Windows SDK before any is
# used (AGENTS.md, Win32 FFI): the marshaler's sizes and field offsets, from
# winuser.h (GUITHREADINFO, RECT, POINT) and wincontypes.h (COORD,
# SMALL_RECT, CONSOLE_SCREEN_BUFFER_INFO, KEY_EVENT_RECORD, INPUT_RECORD).
# 64-bit (x64 and arm64 lay them out alike) and 32-bit values.
Add-Type -TypeDefinition $script:ConsoleSizeSource
$pointer = [IntPtr]::Size
$layouts = @(
    @{ Type = [Pd+GuiThreadInfo]; Size = $(if ($pointer -eq 8) { 72 } else { 48 }); Offsets = $(if ($pointer -eq 8) {
        @{ cbSize = 0; flags = 4; active = 8; focus = 16; capture = 24; menuOwner = 32; moveSize = 40; caret = 48; caretRect = 56 } } else {
        @{ cbSize = 0; flags = 4; active = 8; focus = 12; capture = 16; menuOwner = 20; moveSize = 24; caret = 28; caretRect = 32 } }) }
    @{ Type = [Pd+Rect]; Size = 16; Offsets = @{ Left = 0; Top = 4; Right = 8; Bottom = 12 } }
    @{ Type = [Pd+Point]; Size = 8; Offsets = @{ X = 0; Y = 4 } }
    @{ Type = [PaneDividerConsoleSize+COORD]; Size = 4; Offsets = @{ X = 0; Y = 2 } }
    @{ Type = [PaneDividerConsoleSize+SMALL_RECT]; Size = 8; Offsets = @{ Left = 0; Top = 2; Right = 4; Bottom = 6 } }
    @{ Type = [PaneDividerConsoleSize+CSBI]; Size = 22; Offsets = @{ dwSize = 0; dwCursorPosition = 4; wAttributes = 8; srWindow = 10; dwMaximumWindowSize = 18 } }
    @{ Type = [PaneDividerConsoleSize+KEY_EVENT_RECORD]; Size = 16; Offsets = @{ bKeyDown = 0; wRepeatCount = 4; wVirtualKeyCode = 6; wVirtualScanCode = 8; UnicodeChar = 10; dwControlKeyState = 12 } }
    @{ Type = [PaneDividerConsoleSize+INPUT_RECORD]; Size = 20; Offsets = @{ EventType = 0; KeyEvent = 4 } }
)
foreach ($layout in $layouts) {
    $measured = @{ Size = [Runtime.InteropServices.Marshal]::SizeOf([type]$layout.Type) }
    foreach ($field in $layout.Offsets.Keys) { $measured[$field] = [int][Runtime.InteropServices.Marshal]::OffsetOf([type]$layout.Type, $field) }
    $wrong = @($layout.Offsets.Keys | Where-Object { $measured[$_] -ne $layout.Offsets[$_] })
    Check ("layout: {0} matches the SDK ({1}-bit)" -f $layout.Type.Name, (8 * $pointer)) ($measured.Size -eq $layout.Size -and $wrong.Count -eq 0) (@{ Size = $layout.Size } + $layout.Offsets) $measured
}
$WM = @{ MouseMove = 0x200; LDown = 0x201; LUp = 0x202; CancelMode = 0x1F; KeyDown = 0x100; KeyUp = 0x101 }
$HTTRANSPARENT = -1; $HTCLIENT = 1
# Keybinds on keys nobody types (a posted Ctrl is invisible to GetKeyboardState).
$Keys = @{ SplitRight = 0x7C; SplitDown = 0x7D; Zoom = 0x7E }   # F13, F14, F15

function Scaled([int]$base,[uint32]$dpi) { if ($dpi -le 96) { return $base }; return [int][Math]::Truncate($base * $dpi / 96.0) }
function Panes($h) {
    @([HiddenLocal]::Surfaces($h) | Where-Object { [Pd]::Visible($_) } | ForEach-Object {
        $r = [Pd]::ClientRectIn($h, $_); [pscustomobject]@{ Hwnd = $_; Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom; Width = $r.Right - $r.Left; Height = $r.Bottom - $r.Top }
    } | Sort-Object Left, Top)
}
function Rect-Of($p) { return @{ Left = $p.Left; Top = $p.Top; Right = $p.Right; Bottom = $p.Bottom } }
# The shells of the case, oldest first: the first pane's, then each split's.
function Shells([int]$NocttyPid) {
    @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $NocttyPid" -OperationTimeoutSec 10 |
        Where-Object { $_.Name -eq 'cmd.exe' } | Sort-Object CreationDate | ForEach-Object { [int]$_.ProcessId })
}
function Console-Size([int]$ShellPid) {
    $out = Join-Path $tools ("size-{0}-{1}.txt" -f $ShellPid, [guid]::NewGuid().ToString('N').Substring(0,6))
    $psi = [Diagnostics.ProcessStartInfo]::new($sizeExe)
    $psi.ArgumentList.Add([string]$ShellPid); $psi.ArgumentList.Add($out)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(10000)) { throw 'Console size reader timed out.' }
    $text = [IO.File]::ReadAllText($out)
    if ($text -notmatch '^(\d+) (\d+)$') { throw "Console size reader failed: $text" }
    return @{ Columns = [int]$Matches[1]; Rows = [int]$Matches[2] }
}
function Console-Input([int]$ShellPid) {
    $out = Join-Path $tools ("input-{0}-{1}.txt" -f $ShellPid, [guid]::NewGuid().ToString('N').Substring(0,6))
    $psi = [Diagnostics.ProcessStartInfo]::new($sizeExe)
    foreach ($arg in @([string]$ShellPid, $out, 'input')) { $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(10000)) { throw 'Console input reader timed out.' }
    $text = [IO.File]::ReadAllText($out)
    if ($text -notmatch '^(\d+)$') { throw "Console input reader failed: $text" }
    return [int]$Matches[1]
}
# A posted key, with the target's keyboard state cleared first; a modifier
# held at the real keyboard is recorded, since it marks the step interfered.
function Post-Key($target, [int]$Key) {
    [Pd]::ClearKeys($target)
    if ([Pd]::RealModifierDown()) { $script:interfered.Add($Key) }
    [Pd]::Key($target, $Key)
}
function Wait-Panes($h, [int]$Count) {
    if (-not (Wait-Until { (Panes $h).Count -eq $Count } 15)) { throw "Expected $Count visible panes." }
    Start-Sleep -Milliseconds 1200
}
function Settle { Start-Sleep -Milliseconds 700 }
function Capture-Held($h) { return [Pd]::CaptureOf($h) -eq $h }
function Near([int]$a, [int]$b, [int]$tolerance = 3) { return [Math]::Abs($a - $b) -le $tolerance }
# The pane with the keyboard focus, for a keybinding; a pane when none has it
# (a posted message to a null window would go to this thread's own queue).
function Key-Target($h) {
    $focus = [Pd]::FocusOf($h)
    if ($focus -ne [IntPtr]::Zero) { return $focus }
    return (Panes $h)[0].Hwnd
}

$exe = $null; $pi = $null
try {
    $dir = Join-Path $Run 'case\bin'; Copy-Portable $Bin $dir
    $cmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $config = Join-Path $dir 'case.ghostty'
    @("working-directory = $dir", 'single-instance = false', 'window-save-state = never',
      'copy-on-select = false', 'clipboard-read = deny', 'clipboard-write = deny',
      "initial-command = direct:$cmd /D /K for /L %i in (1,1,150) do @echo scrollback line %i",
      "command = direct:$cmd /D /C $(Join-Path ([Environment]::GetFolderPath('System')) 'PING.EXE') -n 3600 127.0.0.1",
      'shell-integration = none', 'confirm-close-surface = false',
      'window-width = 140', 'window-height = 40',
      'keybind = f13=new_split:right', 'keybind = f14=new_split:down', 'keybind = f15=toggle_split_zoom') | Set-Content -LiteralPath $config
    $exe = Join-Path $dir 'noctty.exe'
    $pi = [HiddenLocal]::Spawn($exe, ('"{0}" --config-file="{1}" --single-instance=false --window-save-state=never --class={2}' -f $exe, $config, $runClass), $dir, $desktopPath)
    $script:processes.Add(@{ Pid = $pi.pid })
    if (-not (Wait-Until { @([HiddenLocal]::Hosts($pi.pid)).Count -gt 0 -and @([HiddenLocal]::Surfaces(@([HiddenLocal]::Hosts($pi.pid))[0])).Count -gt 0 } 25)) { throw 'Window startup failed.' }
    $h = @([HiddenLocal]::Hosts($pi.pid))[0]
    Check 'the window is on the private desktop' ([HiddenLocal]::WindowDesktop($h) -eq $DesktopName) $DesktopName ([HiddenLocal]::WindowDesktop($h))
    [void][Pd]::ShowWindow($h, 4)
    Wait-Panes $h 1
    $dpi = [Pd]::Dpi($h); $margin = Scaled 3 $dpi; $min = Scaled 40 $dpi
    $script:samples.Add(@{ Step = 'start'; Dpi = $dpi; Margin = $margin; MinPane = $min })

    # Two panes side by side.
    Post-Key (Key-Target $h) $Keys.SplitRight
    Wait-Panes $h 2
    $p = Panes $h; $left = $p[0]; $right = $p[1]
    $gap = $right.Left - $left.Right
    $d = $right.Left - 1                       # the divider's position: the second slot's start
    $y = [int](($left.Top + $left.Bottom) / 2)
    $script:samples.Add(@{ Step = 'split'; Left = Rect-Of $left; Right = Rect-Of $right; Gap = $gap })
    Check 'split: a 2 px gap between the panes' ($gap -eq 2) 2 $gap
    $shells = Shells $pi.pid
    Check 'split: one shell per pane' ($shells.Count -eq 2) 2 $shells.Count

    # The hit zone. Inside it the pane answers HTTRANSPARENT, and the host,
    # asked next as real input would, answers HTCLIENT; outside it the pane
    # keeps the mouse. The left pane has 150 lines of scrollback, so its
    # overlay scrollbar's band (10 DIP at its right edge) keeps the mouse
    # even inside the divider's zone; the right pane has none at its left.
    $inRight = $right.Left + $margin - 1; $pastRight = $right.Left + $margin
    $inLeft = $left.Right - $margin; $pastLeft = $left.Right - $margin - 1
    $codes = @{
        RightIn = [Pd]::HitTest($h, $right.Hwnd, $inRight, $y); RightPast = [Pd]::HitTest($h, $right.Hwnd, $pastRight, $y)
        LeftIn = [Pd]::HitTest($h, $left.Hwnd, $inLeft, $y); LeftPast = [Pd]::HitTest($h, $left.Hwnd, $pastLeft, $y)
        Center = [Pd]::HitTest($h, $right.Hwnd, [int](($right.Left + $right.Right) / 2), $y)
        HostIn = [Pd]::HitTest($h, $h, $inRight, $y)
    }
    $script:samples.Add(@{ Step = 'hit-zone'; Codes = $codes; Under = @{ Gap = [int64][Pd]::Under($h, $d, $y); RightIn = [int64][Pd]::Under($h, $inRight, $y); Center = [int64][Pd]::Under($h, $right.Left + 100, $y) } })
    Check 'hit zone: the right pane leaves its first margin columns to the host' ($codes.RightIn -eq $HTTRANSPARENT) $HTTRANSPARENT $codes.RightIn
    Check 'hit zone: the right pane keeps the column past the margin' ($codes.RightPast -eq $HTCLIENT) $HTCLIENT $codes.RightPast
    Check 'hit zone: the left pane''s scrollbar band keeps its columns inside the zone' ($codes.LeftIn -eq $HTCLIENT) $HTCLIENT $codes.LeftIn
    Check 'hit zone: the left pane keeps the column past the margin' ($codes.LeftPast -eq $HTCLIENT) $HTCLIENT $codes.LeftPast
    Check 'hit zone: a pane keeps its middle' ($codes.Center -eq $HTCLIENT) $HTCLIENT $codes.Center
    Check 'hit zone: the host answers HTCLIENT where a pane gave way' ($codes.HostIn -eq $HTCLIENT) $HTCLIENT $codes.HostIn

    # Hover: the host's WM_SETCURSOR is the divider's after a move over it.
    # GetCursorPos fails on a private desktop, so the host falls back to the
    # divider its last WM_MOUSEMOVE was over.
    [Pd]::Post($h, $WM.MouseMove, 0, $d, $y); Start-Sleep -Milliseconds 300
    $onDivider = [Pd]::SetCursor($h)
    [Pd]::Post($h, $WM.MouseMove, 0, 4, 4); Start-Sleep -Milliseconds 300
    $offDivider = [Pd]::SetCursor($h)
    $script:samples.Add(@{ Step = 'hover'; SetCursorOnDivider = $onDivider; SetCursorOffDivider = $offDivider })
    Check 'hover: the host sets the cursor over a divider' ($onDivider -eq 1) 1 $onDivider
    Check 'hover: off a divider the host leaves the cursor to DefWindowProc' ($offDivider -eq 0) 0 $offDivider

    # Drag 200 px left: live while the button is down, kept after the release,
    # and both shells reflow to their new widths.
    $before = @{ Left = Console-Size $shells[0]; Right = Console-Size $shells[1] }
    [Pd]::Post($h, $WM.MouseMove, 0, $d, $y)
    [Pd]::Post($h, $WM.LDown, 1, $d, $y); Start-Sleep -Milliseconds 300
    $held = Capture-Held $h
    [Pd]::Post($h, $WM.MouseMove, 1, $d - 200, $y); Settle
    $live = Panes $h
    [Pd]::Post($h, $WM.LUp, 0, $d - 200, $y); Settle
    $released = -not (Capture-Held $h)
    $after = Panes $h
    Start-Sleep -Milliseconds 800
    $afterSize = @{ Left = Console-Size $shells[0]; Right = Console-Size $shells[1] }
    $script:samples.Add(@{ Step = 'drag'; Live = @($live | ForEach-Object { Rect-Of $_ }); After = @($after | ForEach-Object { Rect-Of $_ }); ConsoleBefore = $before; ConsoleAfter = $afterSize })
    Check 'drag: the press takes the capture' $held $true $held
    Check 'drag: the panes follow the pointer while the button is down' (Near $live[0].Right ($left.Right - 200)) ($left.Right - 200) $live[0].Right
    Check 'drag: the release lets the capture go' $released $true $released
    Check 'drag: the left pane is 200 px narrower' (Near $after[0].Width ($left.Width - 200)) ($left.Width - 200) $after[0].Width
    Check 'drag: the right pane is 200 px wider' (Near $after[1].Width ($right.Width + 200)) ($right.Width + 200) $after[1].Width
    Check 'drag: the gap stays 2 px' (($after[1].Left - $after[0].Right) -eq 2) 2 ($after[1].Left - $after[0].Right)
    Check 'drag: the left shell has fewer columns' ($afterSize.Left.Columns -lt $before.Left.Columns) "< $($before.Left.Columns)" $afterSize.Left.Columns
    Check 'drag: the right shell has more columns' ($afterSize.Right.Columns -gt $before.Right.Columns) "> $($before.Right.Columns)" $afterSize.Right.Columns
    Check 'drag: the columns the left lost, the right gained (within one)' ([Math]::Abs(($before.Left.Columns - $afterSize.Left.Columns) - ($afterSize.Right.Columns - $before.Right.Columns)) -le 1) 'equal' @{ Lost = $before.Left.Columns - $afterSize.Left.Columns; Gained = $afterSize.Right.Columns - $before.Right.Columns }

    # Esc during a drag puts the divider back where the drag started, keeps
    # the button the host's until its release, and never reaches a program:
    # it is posted to the right pane, whose cmd waits on ping, which reads no
    # input, so a key that got through would wait in its console.
    $d2 = $after[1].Left - 1; $start = $after
    $inputBefore = Console-Input $shells[1]
    [Pd]::Post($h, $WM.LDown, 1, $d2, $y); Start-Sleep -Milliseconds 300
    [Pd]::Post($h, $WM.MouseMove, 1, $d2 + 150, $y); Settle
    $moved = Panes $h
    $focus = $start[1].Hwnd
    Post-Key $focus 0x1B; Settle
    $cancelled = Panes $h
    $escHeld = Capture-Held $h
    [Pd]::Post($h, $WM.LUp, 0, $d2 + 150, $y); Settle
    $escReleased = -not (Capture-Held $h)
    $afterEscUp = Panes $h
    $escSize = Console-Size $shells[0]
    Start-Sleep -Milliseconds 500
    $inputAfter = Console-Input $shells[1]
    # The positive control: the same key, with no drag, does arrive.
    Post-Key $focus 0x1B
    $controlArrived = Wait-Until { (Console-Input $shells[1]) -gt $inputAfter } 5
    $inputControl = Console-Input $shells[1]
    $script:samples.Add(@{ Step = 'esc'; Moved = @($moved | ForEach-Object { Rect-Of $_ }); Cancelled = @($cancelled | ForEach-Object { Rect-Of $_ }); AfterUp = @($afterEscUp | ForEach-Object { Rect-Of $_ }); LeftConsole = $escSize; InputBefore = $inputBefore; InputAfter = $inputAfter; InputControl = $inputControl })
    Check 'esc: the drag moved the divider first' (Near $moved[0].Right ($start[0].Right + 150)) ($start[0].Right + 150) $moved[0].Right
    Check 'esc: Esc puts the divider back' (Near $cancelled[0].Right $start[0].Right 1) $start[0].Right $cancelled[0].Right
    Check 'esc: the host keeps the button after Esc, until its release' $escHeld $true $escHeld
    Check 'esc: the release lets the capture go' $escReleased $true $escReleased
    Check 'esc: no Esc reached the program in the pane' ($inputAfter -eq $inputBefore) $inputBefore $inputAfter
    Check 'esc: the same Esc with no drag reaches it (control)' $controlArrived $true @{ Before = $inputAfter; After = $inputControl }
    Check 'esc: the release after Esc moves nothing' ($afterEscUp[0].Right -eq $cancelled[0].Right) $cancelled[0].Right $afterEscUp[0].Right
    Check 'esc: the left shell is back at its width' ($escSize.Columns -eq $afterSize.Left.Columns) $afterSize.Left.Columns $escSize.Columns

    # A capture loss (WM_CANCELMODE, as a system modal loop sends) ends the
    # drag where it is.
    [Pd]::Post($h, $WM.LDown, 1, $d2, $y); Start-Sleep -Milliseconds 300
    [Pd]::Post($h, $WM.MouseMove, 1, $d2 - 100, $y); Settle
    [Pd]::Post($h, $WM.CancelMode, 0, 0, 0); Settle
    $lost = Panes $h
    $lostReleased = -not (Capture-Held $h)
    [Pd]::Post($h, $WM.MouseMove, 0, $d2 + 100, $y); Settle
    $afterLost = Panes $h
    $script:samples.Add(@{ Step = 'capture-loss'; Lost = @($lost | ForEach-Object { Rect-Of $_ }); After = @($afterLost | ForEach-Object { Rect-Of $_ }) })
    Check 'capture loss: the divider stays where the drag left it' (Near $lost[0].Right ($start[0].Right - 100)) ($start[0].Right - 100) $lost[0].Right
    Check 'capture loss: the capture is gone' $lostReleased $true $lostReleased
    Check 'capture loss: a later move does not drag' ($afterLost[0].Right -eq $lost[0].Right) $lost[0].Right $afterLost[0].Right

    # A double-click equalizes the split, and the host holds the capture
    # while the second press is down, so its release (the divider may have
    # moved from under it) reaches no terminal.
    $d3 = $lost[1].Left - 1
    foreach ($m in @($WM.LDown, $WM.LUp, $WM.LDown)) { [Pd]::Post($h, $m, $(if ($m -eq $WM.LDown) { 1 } else { 0 }), $d3, $y) }
    Settle
    $secondHeld = Capture-Held $h
    $even = Panes $h
    [Pd]::Post($h, $WM.LUp, 0, $d3, $y); Settle
    $secondReleased = -not (Capture-Held $h)
    $script:samples.Add(@{ Step = 'double-click'; After = @($even | ForEach-Object { Rect-Of $_ }); CaptureDuringSecondPress = $secondHeld })
    Check 'double-click: the two panes are equal' (Near $even[0].Width $even[1].Width 2) $even[0].Width $even[1].Width
    Check 'double-click: the host holds the capture while the second press is down' $secondHeld $true $secondHeld
    Check 'double-click: its release lets the capture go' $secondReleased $true $secondReleased

    # A zoomed pane shows no divider: the old gap takes no press.
    $d4 = $even[1].Left - 1
    Post-Key (Key-Target $h) $Keys.Zoom
    Wait-Panes $h 1
    $zoomed = Panes $h
    [Pd]::Post($h, $WM.LDown, 1, $d4, $y); Start-Sleep -Milliseconds 300
    $zoomHeld = Capture-Held $h
    [Pd]::Post($h, $WM.MouseMove, 1, $d4 - 150, $y)
    [Pd]::Post($h, $WM.LUp, 0, $d4 - 150, $y); Settle
    $zoomCode = [Pd]::HitTest($h, $zoomed[0].Hwnd, $d4 + 1, $y)
    $script:samples.Add(@{ Step = 'zoom'; Zoomed = Rect-Of $zoomed[0]; PaneCodeAtOldGap = $zoomCode })
    Check 'zoom: the old gap takes no capture' (-not $zoomHeld) $false $zoomHeld
    Check 'zoom: the zoomed pane keeps the old hit zone' ($zoomCode -eq $HTCLIENT) $HTCLIENT $zoomCode
    Post-Key (Key-Target $h) $Keys.Zoom
    Wait-Panes $h 2
    $unzoomed = Panes $h
    Check 'zoom: the split is as it was' (Near $unzoomed[0].Width $even[0].Width 1) $even[0].Width $unzoomed[0].Width

    # A nested split: the focused pane splits down. Dragging the stack's line
    # moves only that split, and so does a press where the stack's line meets
    # the line beside it, inside both grab zones: the innermost divider wins.
    Post-Key (Key-Target $h) $Keys.SplitDown
    Wait-Panes $h 3
    $three = Panes $h
    $columns = @($three | Group-Object Left)
    $stack = @(($columns | Where-Object { $_.Count -eq 2 } | Select-Object -First 1).Group | Sort-Object Top)
    $solo = ($columns | Where-Object { $_.Count -eq 1 } | Select-Object -First 1).Group[0]
    Check 'nested: one pane beside a stack of two' ($stack.Count -eq 2 -and $null -ne $solo) 'stack of 2 and 1' @($columns | ForEach-Object { $_.Count })
    $stackTop = $stack[0]; $stackBottom = $stack[1]
    $stackOnRight = $stackTop.Left -gt $solo.Left
    $x = [int](($stackTop.Left + $stackTop.Right) / 2); $ly = $stackBottom.Top - 1
    [Pd]::Post($h, $WM.LDown, 1, $x, $ly); Start-Sleep -Milliseconds 300
    [Pd]::Post($h, $WM.MouseMove, 1, $x, $ly + 100)
    [Pd]::Post($h, $WM.LUp, 0, $x, $ly + 100); Settle
    $nested = Panes $h
    $nTop = $nested | Where-Object { $_.Hwnd -eq $stackTop.Hwnd }; $nSolo = $nested | Where-Object { $_.Hwnd -eq $solo.Hwnd }
    # The junction: the stack's column next to the outer line, on the stack's line.
    $jx = if ($stackOnRight) { $stackTop.Left } else { $stackTop.Right - 1 }
    $jy = ($nested | Where-Object { $_.Hwnd -eq $stackBottom.Hwnd }).Top - 1
    $junctionCode = [Pd]::HitTest($h, $nTop.Hwnd, $jx, $jy - 2)
    $rowCode = [Pd]::HitTest($h, $nTop.Hwnd, $x, $nTop.Bottom - 1)
    [Pd]::Post($h, $WM.LDown, 1, $jx, $jy); Start-Sleep -Milliseconds 300
    [Pd]::Post($h, $WM.MouseMove, 1, $jx, $jy - 50)
    [Pd]::Post($h, $WM.LUp, 0, $jx, $jy - 50); Settle
    $junction = Panes $h
    $jTop = $junction | Where-Object { $_.Hwnd -eq $stackTop.Hwnd }; $jSolo = $junction | Where-Object { $_.Hwnd -eq $solo.Hwnd }
    $script:samples.Add(@{ Step = 'nested'; StackOnRight = $stackOnRight; Before = @($three | ForEach-Object { Rect-Of $_ }); After = @($nested | ForEach-Object { Rect-Of $_ }); Junction = @($junction | ForEach-Object { Rect-Of $_ }); StackTopCodeAtJunction = $junctionCode })
    Check 'nested: the stack line moves 100 px' (Near $nTop.Height ($stackTop.Height + 100)) ($stackTop.Height + 100) $nTop.Height
    Check 'nested: the pane beside the stack does not move' ($nSolo.Width -eq $solo.Width -and $nSolo.Height -eq $solo.Height) (Rect-Of $solo) (Rect-Of $nSolo)
    Check 'nested: the stack top gives way at the junction' ($junctionCode -eq $HTTRANSPARENT) $HTTRANSPARENT $junctionCode
    Check 'nested: the stack top gives way along its bottom row' ($rowCode -eq $HTTRANSPARENT) $HTTRANSPARENT $rowCode
    Check 'nested: a press at the junction moves the stack line' (Near $jTop.Height ($nTop.Height - 50)) ($nTop.Height - 50) $jTop.Height
    Check 'nested: a press at the junction leaves the outer line' ($jSolo.Width -eq $nSolo.Width) $nSolo.Width $jSolo.Width

    # The minimum pane: a drag far past the edge stops at it.
    $ly2 = ($junction | Where-Object { $_.Hwnd -eq $stackBottom.Hwnd }).Top - 1
    [Pd]::Post($h, $WM.LDown, 1, $x, $ly2); Start-Sleep -Milliseconds 300
    [Pd]::Post($h, $WM.MouseMove, 1, $x, 30000)
    [Pd]::Post($h, $WM.LUp, 0, $x, 30000); Settle
    $floor = Panes $h | Where-Object { $_.Hwnd -eq $stackBottom.Hwnd }
    $script:samples.Add(@{ Step = 'minimum'; StackBottom = Rect-Of $floor })
    # The slot is at least the minimum; the pane is 1 px short of its slot (the gap).
    Check 'minimum: the bottom pane keeps the minimum' ($floor.Height -ge ($min - 2) -and $floor.Height -le ($min + 2)) $min $floor.Height
} catch {
    $script:checks.Add(@{ Name = 'Harness execution'; Passed = $false; Error = $_.Exception.Message; Line = $_.InvocationInfo.ScriptLineNumber })
} finally {
    if ($pi) {
        foreach ($window in [HiddenLocal]::Hosts($pi.pid)) { [void][Pd]::PostMessageW($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
        if ([HiddenLocal]::WaitForSingleObject($pi.process, 5000) -eq 258) {
            # The handle is this launch's own process: no name or pattern match.
            [void][HiddenLocal]::TerminateProcess($pi.process, 1)
            [void][HiddenLocal]::WaitForSingleObject($pi.process, 5000)
        }
        [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process)
    }
    $remaining = @($script:processes | Where-Object { Get-Process -Id $_.Pid -ErrorAction SilentlyContinue })
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{ Checks = $script:checks; Samples = $script:samples; Processes = $script:processes; InterferedKeys = $script:interfered; Limit = 'Posted and sent window messages on a never-switched private desktop; the system routing a real click through HTTRANSPARENT, the cursor shape on screen, real Alt+Tab, real double-click timing, mixed-DPI drags and visual composition are not exercised.' } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'pane-divider-results.json')
}
$failed = @($script:checks | Where-Object { -not $_.Passed })
if ($failed.Count) { $failed | ForEach-Object { Write-Host ("FAIL: " + $_.Name) }; exit 1 }
Write-Host ("PASS: {0} checks" -f $script:checks.Count)
