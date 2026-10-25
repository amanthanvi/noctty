# Metadata only: boot time, seconds since the last input, the clipboard counter. No clipboard contents, no window titles.
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Attr {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    public static double IdleSeconds() { var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)); GetLastInputInfo(ref i); return (Environment.TickCount - (int)i.dwTime) / 1000.0; }
}
'@
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
"now:               " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
"last boot:         " + $boot.ToString('yyyy-MM-dd HH:mm:ss')
"idle seconds:      " + [math]::Round([Attr]::IdleSeconds(), 1)
"clipboard counter: " + [Attr]::GetClipboardSequenceNumber()
$history = Get-Item -LiteralPath (Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt')
"history file:      {0} bytes, modified {1}" -f $history.Length, $history.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
$fg = Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);' -Name FG -Namespace Attr2 -PassThru
$pidOut = [uint32]0
[void]$fg::GetWindowThreadProcessId($fg::GetForegroundWindow(), [ref]$pidOut)
"foreground process name: " + $(try { (Get-Process -Id $pidOut -ErrorAction Stop).ProcessName } catch { 'unreadable' })
