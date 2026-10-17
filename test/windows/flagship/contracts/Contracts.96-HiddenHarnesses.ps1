# The hidden-desktop harnesses added for PKG-76 (profile matrix, -Embedding idle) start real
# copies of noctty on ephemeral hosted runners, and the skip budget decides what CI may skip
# silently. Both are pinned here: the safety rules by what the files may contain, the budget script
# by running it on synthetic logs.
$hiddenLib = Join-Path $repoRoot 'test\windows\hidden-win11-lib.ps1'
$hiddenScripts = @(
    Join-Path $repoRoot 'test\windows\hidden-win11-profile-matrix.ps1'
    Join-Path $repoRoot 'test\windows\hidden-win11-embedding-idle.ps1'
)

# The text of a script without its comments, so a comment cannot satisfy or trip a pattern.
function Remove-PowerShellComments([string] $Text) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'A hidden harness does not parse.' }
    $builder = [Text.StringBuilder]::new($Text)
    foreach ($token in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        [void]$builder.Remove($token.Extent.StartOffset, $token.Extent.EndOffset - $token.Extent.StartOffset)
    }
    return $builder.ToString()
}
$hiddenForbidden = '(?s)\A(?!.*(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|Set-Clipboard|Get-Clipboard|SetClipboardData|Start-Process|Invoke-Item|Register-Default|Remove-Item\s+-Recurse))'
$hiddenLibText = Remove-PowerShellComments (Get-Content -LiteralPath $hiddenLib -Raw)
$hiddenContracts = @(
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = '(?s)function Assert-MeasureAumid.*?io\.github\.amanthanvi\.noctty\.measure.*?throw'
        Kind = 'Text'
        Description = 'a launch is refused unless the binary carries the measurement AUMID, or the caller says it is an ephemeral runner'
    }
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = '(?s)function Start-HiddenNoctty.*?noctty\.portable.*?throw.*?"WinSta0\\\$DesktopName"'
        Kind = 'Text'
        Description = 'every noctty copy is portable and is started on an explicit desktop'
    }
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = $hiddenForbidden
        Kind = 'Text'
        Description = 'the shared hidden-desktop library uses no real input, foreground, clipboard, Start-Process or recursive delete'
    }
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = '(?s)GetClipboardSequenceNumber\(\).*?Clipboard sequence number changed'
        Kind = 'Text'
        Description = 'the clipboard sequence number is compared before and after a run'
    }
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = '(?s)StartupUnchanged.*?HistoryUnchanged.*?throw.*?real startup-attempts\.json changed.*?PowerShell history file changed'
        Kind = 'Text'
        Description = 'the real recovery ledger and PowerShell history are checked after a run'
    }
)
foreach ($script in $hiddenScripts) {
    $text = Remove-PowerShellComments (Get-Content -LiteralPath $script -Raw)
    $name = Split-Path -Leaf $script
    $hiddenContracts += @{
        File = $script
        Content = $text
        Pattern = '(?s)Assert-MeasureAumid.*?Invoke-HiddenDriver'
        Kind = 'Text'
        Description = "$name checks the AUMID before it starts anything"
    }
    $hiddenContracts += @{
        File = $script
        Content = $text
        Pattern = $hiddenForbidden
        Kind = 'Text'
        Description = "$name uses no real input, foreground, clipboard, Start-Process or recursive delete"
    }
    if ($name -eq 'hidden-win11-profile-matrix.ps1') { $hiddenContracts += @{
        File = $script
        Content = $text
        Pattern = "(?s)'--single-instance=false'.*?--class=noctty-test-pkg76"
        Kind = 'Text'
        Description = "$name starts every noctty with single-instance off and a unique class"
    } }
}
Invoke-ContractTable -Contracts $hiddenContracts

# Exercise extracted functions with managed native-call stand-ins, plus bounded native
# observations of this process and an empty job. No child, window, registry write or real state read.
function Get-HiddenFunction([string] $Text, [string] $Name) {
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if (-not $function) { throw "Missing hidden harness function $Name." }
    return $function.Extent.Text
}
$script:mutationControls = 0
function Assert-HiddenMutation([string] $Name, [string] $Original, [string] $Mutated, [scriptblock] $Validate) {
    if ($Original -ceq $Mutated) { throw "Mutation '$Name' changed no code." }
    & $Validate $Original
    $rejected = $false
    try { & $Validate $Mutated } catch { $rejected = $true }
    if (-not $rejected) { throw "Hidden harness contract accepted mutation '$Name'." }
    $script:mutationControls++
}

$launch = [regex]::Match($hiddenLibText, '(?ms)^    public static ProcessInfo Launch\(.*?^    }').Value
$createDesktop = [regex]::Match($hiddenLibText, '(?ms)^    public static IntPtr CreateInheritedDesktop\(.*?^    }').Value
$threadDesktop = [regex]::Match($hiddenLibText, '(?ms)^    public static string ThreadDesktopName\(.*?^    }').Value
$currentDesktop = [regex]::Match($hiddenLibText, '(?ms)^    public static string CurrentDesktopName\(.*?^    }').Value
$jobWindows = [regex]::Match($hiddenLibText, '(?ms)^    public static DesktopWindowObservation\[\] DefaultJobWindows\(.*?^    }').Value
$windowObservation = [regex]::Match($hiddenLibText, '(?ms)^    public sealed class DesktopWindowObservation.*?^    }').Value
$visibleWindows = [regex]::Match($hiddenLibText, '(?ms)^    public static string\[\] VisibleTopLevelClasses\(.*?^    }').Value
if (-not $launch -or -not $createDesktop -or -not $threadDesktop -or -not $visibleWindows) { throw 'The hidden native launch/desktop/window methods were not found.' }
function Test-HiddenNativeCode([string] $Methods) {
    $typeName = 'HiddenNativeContract' + [guid]::NewGuid().ToString('N')
    $support = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class TYPE_NAME {
    [StructLayout(LayoutKind.Sequential)] public struct Startup { public int cb, flags; public string desktop; public IntPtr error; }
    public struct ProcessInfo { public IntPtr process, thread; }
    public struct SecurityAttributes { public int length; public bool inherit; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    public static string Desktop; public static uint Flags; public static bool Inherit, DesktopInherit, Assigned, Resumed, AssignedBeforeResume, ThreadQueryFails, NameQueryFails;
    public static int CreatedDesktops;
    public static int ThreadError;
    public static bool EnumFails;
    static IntPtr CreateDesktopW(string n, IntPtr d, IntPtr m, int f, uint a, ref SecurityAttributes sa) { CreatedDesktops++; DesktopInherit = sa.inherit; return new IntPtr(9); }
    static void SetLastError(uint error) { Marshal.SetLastPInvokeError((int)error); }
    static IntPtr GetThreadDesktop(uint threadId) { if (ThreadQueryFails) { if (ThreadError != 0) SetLastError((uint)ThreadError); return IntPtr.Zero; } return new IntPtr(9); }
    static uint GetCurrentThreadId() { return 42; }
    static IntPtr GetDesktopWindow() { ThreadQueryFails = false; return new IntPtr(9); }
    static int[] JobProcessIds(IntPtr job) { return new int[] { 41, 42 }; }
    static bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed) { needed = 20; name.Append("contract-private"); if (NameQueryFails) SetLastError(122); return !NameQueryFails; }
    static IntPtr CreateFileW(string p, uint a, uint s, ref SecurityAttributes sa, uint d, uint f, IntPtr t) { return new IntPtr(3); }
    static bool CloseHandle(IntPtr h) { return true; }
    static bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi) {
        Desktop = si.desktop; Flags = flags; Inherit = inherit; pi = new ProcessInfo { process = new IntPtr(1), thread = new IntPtr(2) }; return true;
    }
    static bool AssignProcessToJobObject(IntPtr job, IntPtr process) { Assigned = job == new IntPtr(7) && process == new IntPtr(1); return Assigned; }
    static uint ResumeThread(IntPtr thread) { AssignedBeforeResume = Assigned; Resumed = true; return 1; }
    static bool TerminateProcess(IntPtr process, uint code) { return true; }
    static bool EnumWindows(EnumWindow cb, IntPtr p) { if (EnumFails) return false; for (int i = 1; i <= 4; i++) cb(new IntPtr(i), p); return true; }
    static int GetWindowThreadProcessId(IntPtr h, out int pid) { pid = h.ToInt32() == 4 ? 99 : 42; return 1; }
    static string Class(IntPtr h) { return h.ToInt32() == 1 ? "noctty.win32.host" : "#32770"; }
    static bool IsWindowVisible(IntPtr h) { return h.ToInt32() == 2 || h.ToInt32() == 4; }
METHODS
}
'@
    $type = Add-Type -TypeDefinition ($support.Replace('TYPE_NAME', $typeName).Replace('METHODS', $Methods)) -PassThru | Where-Object Name -eq $typeName
    $null = $type::CreateInheritedDesktop('contract-private')
    if ($type::CreatedDesktops -ne 1 -or -not $type::DesktopInherit) { throw 'Harness must create exactly one inheritable desktop handle.' }
    foreach ($stderr in @('', 'unused-stderr')) {
        $type::Assigned = $type::Resumed = $type::AssignedBeforeResume = $false
        $null = $type::Launch('unused.exe', 'unused', 'unused', 'WinSta0\contract-private', [IntPtr]7, $stderr)
        if ($type::Desktop -cne 'WinSta0\contract-private' -or -not $type::Inherit -or ($type::Flags -band 0x08000004) -ne 0x08000004 -or
            -not $type::Assigned -or -not $type::Resumed -or -not $type::AssignedBeforeResume) { throw 'Native launch lost desktop inheritance, explicit desktop, no-window/suspended flags or assign-before-resume.' }
    }
    if ($type::ThreadDesktopName(42) -cne 'contract-private') { throw 'Thread desktop name query failed.' }
    $type::ThreadQueryFails = $true
    [Runtime.InteropServices.Marshal]::SetLastPInvokeError(123)
    if ($null -ne $type::ThreadDesktopName(42)) { throw 'NULL/error-zero must mean unconnected, even after a stale error.' }
    if ($type::CurrentDesktopName() -cne 'contract-private') { throw 'Current thread was not connected before resolving its desktop.' }
    $type::ThreadError = 5
    foreach ($failure in @('ThreadQueryFails', 'NameQueryFails')) {
        $type.GetField($failure).SetValue($null, $true)
        $rejected = $false
        try { $null = $type::ThreadDesktopName(42) } catch {
            $rejected = $true
            $nativeError = $_.Exception.InnerException
            $api = if ($failure -eq 'ThreadQueryFails') { 'GetThreadDesktop' } else { 'GetUserObjectInformationW' }
            $code = if ($failure -eq 'ThreadQueryFails') { 5 } else { 122 }
            if ($nativeError -isnot [ComponentModel.Win32Exception] -or $nativeError.Message -cne $api -or $nativeError.NativeErrorCode -ne $code) {
                throw 'Desktop query failure lost its sanitized API stage or numeric error.'
            }
        }
        $type.GetField($failure).SetValue($null, $false)
        if (-not $rejected) { throw 'Desktop query error was silently accepted.' }
    }
    $classes = @($type::VisibleTopLevelClasses(42))
    if ($classes.Count -ne 1 -or $classes[0] -cne '#32770') { throw 'Visible-window enumeration lost the process/visibility filter or omitted a dialog.' }
    $windows = @($type::DefaultJobWindows([IntPtr]7))
    if ($windows.Count -ne 3 -or @($windows | Where-Object ProcessId -ne 42).Count) { throw 'Default-desktop oracle must keep every owned-job window, including invisible windows and dialogs.' }
    $type::EnumFails = $true
    $rejected = $false
    try { $null = $type::DefaultJobWindows([IntPtr]7) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Default-desktop window enumeration errors must fail closed.' }
}
$nativeCode = $launch + "`n" + $createDesktop + "`n" + $threadDesktop + "`n" + $currentDesktop + "`n" + $visibleWindows + "`n" + $windowObservation + "`n" + $jobWindows
Assert-HiddenMutation 'null native desktop' $nativeCode ($nativeCode.Replace('desktop = desktop', 'desktop = null')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'wrong native desktop' $nativeCode ($nativeCode.Replace('desktop = desktop', 'desktop = "Default"')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'child handle inheritance disabled' $nativeCode ($nativeCode.Replace('IntPtr.Zero, IntPtr.Zero, true, 0x08004004', 'IntPtr.Zero, IntPtr.Zero, false, 0x08004004')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'desktop handle not inheritable' $nativeCode ($nativeCode.Replace('inherit = true', 'inherit = false')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'desktop name query errors ignored' $nativeCode ($nativeCode.Replace('throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "GetUserObjectInformationW")', 'return "contract-private"')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'thread desktop error code lost' $nativeCode ($nativeCode.Replace('Win32Exception(error, "GetThreadDesktop")', 'Win32Exception(0, "GetThreadDesktop")')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'desktop name error stage lost' $nativeCode ($nativeCode.Replace('Win32Exception(Marshal.GetLastWin32Error(), "GetUserObjectInformationW")', 'Win32Exception(Marshal.GetLastWin32Error(), "GetThreadDesktop")')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'missing job assignment' $nativeCode ($nativeCode.Replace('!AssignProcessToJobObject(job, pi.process) || ', '')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'missing no-window flag' $nativeCode ($nativeCode.Replace('0x08004004', '0x00004004')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'hidden windows counted as UI' $nativeCode ($nativeCode.Replace(' && IsWindowVisible(h)', '')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'visible dialogs omitted' $nativeCode ($nativeCode.Replace('id == pid && IsWindowVisible(h)', 'id == pid && IsWindowVisible(h) && Class(h) == "noctty.win32.host"')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'stale thread last error retained' $nativeCode ($nativeCode.Replace('SetLastError(0);', '')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'unconnected native thread rejected' $nativeCode ($nativeCode.Replace('if (error == 0) return null;', 'if (error == 0) throw new Exception("unconnected");')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'current desktop never connected' $nativeCode ($nativeCode.Replace('if (GetDesktopWindow() == IntPtr.Zero)', 'if (false)')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'unrelated default window counted' $nativeCode ($nativeCode.Replace('if (ids.Contains(id))', 'if (true)')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'invisible default job window omitted' $nativeCode ($nativeCode.Replace('if (ids.Contains(id))', 'if (ids.Contains(id) && IsWindowVisible(h))')) ${function:Test-HiddenNativeCode}

$sentinelMethods = ([regex]::Matches($hiddenLibText, '(?ms)^    public static (?:IntPtr CreateDriverSentinel|void DestroyDriverSentinel)\(.*?^    }') | ForEach-Object Value) -join "`n"
function Test-DriverSentinelNative([string] $Methods) {
    $typeName = 'DriverSentinelContract' + [guid]::NewGuid().ToString('N')
    $support = @'
using System;
using System.Runtime.InteropServices;
public static class TYPE_NAME {
    public static bool CreateFails, DestroyFails, RunnerDenied;
    static class Environment { public static string GetEnvironmentVariable(string name) { return RunnerDenied ? "denied" : name == "GITHUB_ACTIONS" ? "true" : "github-hosted"; } }
    public static int Creates, Destroys;
    static IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter) {
        Creates++;
        if (ex != 0x08000080 || cls != "STATIC" || title != "" || style != 0x80000000 || x != 0 || y != 0 || width != 1 || height != 1 || parent != IntPtr.Zero) throw new Exception("Sentinel must be hidden, nonactivating, top-level and tiny");
        Marshal.SetLastPInvokeError(5); return CreateFails ? IntPtr.Zero : new IntPtr(8);
    }
    static bool DestroyWindow(IntPtr hwnd) { if (hwnd != new IntPtr(8)) throw new Exception("Wrong sentinel"); Destroys++; Marshal.SetLastPInvokeError(1400); return !DestroyFails; }
METHODS
}
'@
    $type = Add-Type -TypeDefinition ($support.Replace('TYPE_NAME', $typeName).Replace('METHODS', $Methods)) -PassThru | Where-Object Name -eq $typeName
    foreach ($fixture in @(@{}, @{ RunnerDenied = $true; Api = 'Driver sentinel requires an ephemeral GitHub-hosted runner' }, @{ CreateFails = $true; Api = 'Create driver sentinel'; Code = 5 }, @{ DestroyFails = $true; Api = 'Destroy driver sentinel'; Code = 1400 })) {
        $type::Creates = $type::Destroys = 0; $type::CreateFails = [bool]$fixture.CreateFails; $type::DestroyFails = [bool]$fixture.DestroyFails; $type::RunnerDenied = [bool]$fixture.RunnerDenied
        $failure = $null
        try { $hwnd = $type::CreateDriverSentinel(); $type::DestroyDriverSentinel($hwnd) } catch { $failure = $_.Exception.InnerException }
        if ([bool]$failure -ne [bool]$fixture.Api -or ($failure -and ($failure.Message -cne $fixture.Api -or $failure.NativeErrorCode -ne $fixture.Code)) -or $type::Creates -ne [int](-not $fixture.RunnerDenied) -or $type::Destroys -ne [int](-not ($fixture.CreateFails -or $fixture.RunnerDenied))) { throw 'Sentinel create/destroy lifecycle or native failure evidence changed.' }
    }
}
Assert-HiddenMutation 'driver sentinel made visible' $sentinelMethods ($sentinelMethods.Replace('0x80000000', '0x90000000')) ${function:Test-DriverSentinelNative}
Assert-HiddenMutation 'driver sentinel can activate' $sentinelMethods ($sentinelMethods.Replace('0x08000080', '0x00000080')) ${function:Test-DriverSentinelNative}
Assert-HiddenMutation 'driver sentinel destruction omitted' $sentinelMethods ($sentinelMethods.Replace('!DestroyWindow(hwnd)', 'false')) ${function:Test-DriverSentinelNative}
Assert-HiddenMutation 'driver sentinel native runner guard omitted' $sentinelMethods ($sentinelMethods.Replace('Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted"', 'false')) ${function:Test-DriverSentinelNative}

# Compile the real named-desktop oracle against callable Win32 seams.
$privateWindows = [regex]::Match($hiddenLibText, '(?ms)^    public static DesktopWindowObservation\[\] PrivateJobWindows\(.*?^    }').Value
function Test-PrivateWindowNative([string] $Method) {
    $typeName = 'PrivateWindowContract' + [guid]::NewGuid().ToString('N')
    $support = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class TYPE_NAME {
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    public class DesktopWindowObservation { public int ProcessId, ThreadId; public bool CompletedAttempt; }
    public static bool OpenFails, EnumFails, OwnerFails, CloseFails;
    public static int Opens, Enums, Closes;
    static int[] JobProcessIds(IntPtr job) { if (job != new IntPtr(7)) throw new Exception("wrong job"); return new[] { 41, 42 }; }
    static IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access) {
        if (name != "actual-private" || flags != 0 || inherit || access != 1) throw new Exception("wrong desktop/access");
        Opens++; Marshal.SetLastPInvokeError(5); return OpenFails ? IntPtr.Zero : new IntPtr(8);
    }
    static void SetLastError(uint error) { Marshal.SetLastPInvokeError((int)error); }
    static bool EnumDesktopWindows(IntPtr desktop, EnumWindow cb, IntPtr state) {
        if (desktop != new IntPtr(8)) throw new Exception("wrong handle"); Enums++;
        if (EnumFails) { Marshal.SetLastPInvokeError(170); return false; }
        for (int i = 1; i <= 3; i++) if (!cb(new IntPtr(i), state)) return false;
        return true;
    }
    static int GetWindowThreadProcessId(IntPtr hwnd, out int pid) { pid = hwnd.ToInt32() == 3 ? 99 : 42; if (OwnerFails) { Marshal.SetLastPInvokeError(1400); return 0; } return 123; }
    static bool CloseDesktop(IntPtr desktop) { Closes++; if (CloseFails) Marshal.SetLastPInvokeError(6); return !CloseFails; }
METHOD
}
'@
    $type = Add-Type -TypeDefinition ($support.Replace('TYPE_NAME', $typeName).Replace('METHOD', $Method)) -PassThru | Where-Object Name -eq $typeName
    foreach ($fixture in @(@{}, @{ OpenFails = $true; Api = 'OpenDesktopW'; Code = 5 }, @{ EnumFails = $true; Api = 'EnumDesktopWindows'; Code = 170 },
        @{ OwnerFails = $true; Api = 'GetWindowThreadProcessId'; Code = 1400 }, @{ CloseFails = $true; Api = 'CloseDesktop'; Code = 6 },
        @{ EnumFails = $true; CloseFails = $true; Api = 'EnumDesktopWindows'; Code = 170; Cleanup = $true })) {
        foreach ($field in @('OpenFails', 'EnumFails', 'OwnerFails', 'CloseFails')) { $type.GetField($field).SetValue($null, [bool]$fixture[$field]) }
        $type::Opens = $type::Enums = $type::Closes = 0
        $failure = $null; $rows = @()
        try { $rows = @($type::PrivateJobWindows([IntPtr]7, 'actual-private')) } catch { $failure = $_.Exception.InnerException }
        if ([bool]$failure -ne [bool]$fixture.Api -or ($failure -and ($failure.Message -cne $fixture.Api -or $failure.NativeErrorCode -ne $fixture.Code))) { throw 'Private desktop API failure changed or was accepted.' }
        if ($type::Opens -ne 1 -or $type::Closes -ne [int](-not $fixture.OpenFails)) { throw 'Private desktop read handle was leaked.' }
        if (-not $failure -and ($type::Enums -ne 1 -or $rows.Count -ne 2 -or @($rows | Where-Object { $_.ProcessId -ne 42 -or -not $_.CompletedAttempt }).Count)) { throw 'Private desktop oracle omitted actual windows or accepted wrong PID.' }
        if ($fixture.Cleanup -and ($failure.Data['CleanupApi'] -cne 'CloseDesktop' -or $failure.Data['CleanupCode'] -ne 6)) { throw 'Private desktop oracle lost secondary cleanup error.' }
    }
}
Assert-HiddenMutation 'private native wrong PID included' $privateWindows ($privateWindows.Replace('if (ids.Contains(id))', 'if (true)')) ${function:Test-PrivateWindowNative}
Assert-HiddenMutation 'private native read handle inheritable' $privateWindows ($privateWindows.Replace('OpenDesktopW(desktopName, 0, false, 0x0001)', 'OpenDesktopW(desktopName, 0, true, 0x0001)')) ${function:Test-PrivateWindowNative}
Assert-HiddenMutation 'private native errors ignored' $privateWindows ($privateWindows.Replace('throw failure;', '')) ${function:Test-PrivateWindowNative}
Assert-HiddenMutation 'private native cleanup masks failure' $privateWindows ($privateWindows.Replace('throw failure;', 'if (cleanupFailure != null) throw cleanupFailure; throw failure;')) ${function:Test-PrivateWindowNative}

$retryMethods = $windowObservation + "`n" + $jobWindows + "`n" + $privateWindows
function Test-WindowEnumerationRetry([string] $Methods) {
    $typeName = 'WindowRetryContract' + [guid]::NewGuid().ToString('N')
    $support = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class TYPE_NAME {
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    public static int Calls, FailuresLeft, ErrorCode;
    public static bool OwnerFailure, RetainObservation, CurrentObservation;
    static int[] JobProcessIds(IntPtr job) { return new[] { 42 }; }
    static void SetLastError(uint code) { Marshal.SetLastPInvokeError((int)code); }
    static IntPtr OpenDesktopW(string n, uint flags, bool inherit, uint access) { return new IntPtr(8); }
    static bool CloseDesktop(IntPtr h) { return true; }
    static int GetWindowThreadProcessId(IntPtr h, out int pid) {
        pid = 42;
        if (h == new IntPtr(2)) { Marshal.SetLastPInvokeError(ErrorCode); return 0; }
        return 123;
    }
    static bool RunEnum(EnumWindow cb, IntPtr state) {
        Calls++;
        if (RetainObservation && Calls == 1 && !cb(new IntPtr(1), state)) return false;
        if (FailuresLeft-- > 0) {
            if (OwnerFailure) { cb(new IntPtr(2), state); return false; }
            Marshal.SetLastPInvokeError(ErrorCode); return false;
        }
        if (CurrentObservation) cb(new IntPtr(1), state);
        return true;
    }
    static bool EnumWindows(EnumWindow cb, IntPtr state) { return RunEnum(cb, state); }
    static bool EnumDesktopWindows(IntPtr h, EnumWindow cb, IntPtr state) { return RunEnum(cb, state); }
METHODS
}
'@
    $type = Add-Type -TypeDefinition ($support.Replace('TYPE_NAME', $typeName).Replace('METHODS', $Methods)) -PassThru | Where-Object Name -eq $typeName
    foreach ($mode in @('Default', 'Private')) { foreach ($owner in @($false, $true)) { foreach ($fixture in @(
        @{ Failures = 0; Code = 0; Calls = 1 }, @{ Failures = 0; Code = 0; Calls = 1; Current = $true }
        @{ Failures = 1; Code = 1400; Calls = 2; Retain = $true; Current = $true }, @{ Failures = 1; Code = 1400; Calls = 2; Retain = $true }
        @{ Failures = 2; Code = 1400; Calls = 3; Retain = $true }, @{ Failures = 9; Code = 1400; Calls = 3; Retain = $true; Blocked = $true }
        @{ Failures = 1; Code = 5; Calls = 1; Retain = $true; Blocked = $true }, @{ Failures = 1; Code = 0; Calls = 1; Retain = $true; Blocked = $true }
    )) {
        $type::Calls = 0; $type::FailuresLeft = $fixture.Failures; $type::ErrorCode = $fixture.Code; $type::OwnerFailure = $owner; $type::RetainObservation = [bool]$fixture.Retain
        $type::CurrentObservation = [bool]$fixture.Current
        $failure = $null; $rows = @()
        try { $rows = @(if ($mode -eq 'Default') { $type::DefaultJobWindows([IntPtr]7) } else { $type::PrivateJobWindows([IntPtr]7, 'private') }) } catch { $failure = $_.Exception.InnerException }
        if ([bool]$failure -ne [bool]$fixture.Blocked -or $type::Calls -ne $fixture.Calls -or ($failure -and $failure.NativeErrorCode -ne $fixture.Code)) { throw 'Desktop enumeration lost exact 1400 retry bounds or accepted an unknown error.' }
        $observed = if ($failure) { @($failure.Data['ObservedWindows']) } else { $rows }
        if ($observed.Count -ne ([int][bool]$fixture.Retain + [int][bool]$fixture.Current) -or @($observed | Where-Object { $_.ProcessId -ne 42 -or $_.ThreadId -ne 123 }).Count) { throw 'Desktop enumeration discarded a previously observed owned window during retry/failure.' }
        if (@($observed | Where-Object CompletedAttempt).Count -ne [int][bool]$fixture.Current) { throw 'Desktop enumeration accepted a retained failed-attempt observation as current.' }
    } } }
}
Assert-HiddenMutation 'window retry accepts arbitrary errors' $retryMethods ($retryMethods.Replace('error == 1400 && attempt < 2', 'attempt < 2')) ${function:Test-WindowEnumerationRetry}
Assert-HiddenMutation 'window retry exceeds three attempts' $retryMethods ($retryMethods.Replace('attempt < 3', 'attempt < 4').Replace('attempt < 2', 'attempt < 3')) ${function:Test-WindowEnumerationRetry}
Assert-HiddenMutation 'window retry loses observed failure evidence' $retryMethods ($retryMethods.Replace('failure.Data["ObservedWindows"] = rows.ToArray();', '').Replace('queryFailure.Data["ObservedWindows"] = rows.ToArray();', '')) ${function:Test-WindowEnumerationRetry}
Assert-HiddenMutation 'window retry marks stale observations current' $retryMethods ($retryMethods.Replace('int i = attemptStart;', 'int i = 0;')) ${function:Test-WindowEnumerationRetry}

# Compile the real observer against a managed process/thread snapshot seam. Query
# failures only excuse a TID conclusively absent after refreshing the retained process.
$observerCode = ([regex]::Matches($hiddenLibText, '(?ms)^    (?:public sealed class DesktopObservation\b|static bool Conclusively(?:Thread)?Exited\(|public static DesktopObservation\[\] ObserveDesktopThreads\()[^\r\n]*\r?\n.*?^    }') |
    ForEach-Object Value) -join "`n"
function Test-HiddenThreadRace([string] $Methods) {
    $typeName = 'HiddenThreadRace' + [guid]::NewGuid().ToString('N')
    $support = @'
using System;
using System.Collections.Generic;
public static class TYPE_NAME {
    public static bool QueryFails, Vanished, RefreshFails, ProcessExited, NameQueryFails, UnknownFailure;
    public static int Lookups, Refreshes;
    public sealed class ProcessThread { public int Id; }
    public sealed class Process : IDisposable {
        bool retained, refreshed;
        public static Process GetProcessById(int id) { Lookups++; return new Process(); }
        public IntPtr Handle { get { retained = true; return new IntPtr(7); } }
        public string ProcessName { get { return "fixture"; } }
        public bool HasExited { get { return ProcessExited; } }
        public List<ProcessThread> Threads { get {
            if (!retained) throw new Exception("Process handle not retained");
            var threads = new List<ProcessThread>();
            if (!refreshed || !Vanished) threads.Add(new ProcessThread { Id = 11 });
            threads.Add(new ProcessThread { Id = 12 }); return threads;
        } }
        public void Refresh() { Refreshes++; if (RefreshFails) throw new Exception("Refresh failed"); refreshed = true; }
        public void Dispose() { }
    }
    static string ThreadDesktopName(uint tid) {
        if (tid == 11 && QueryFails) {
            if (UnknownFailure) throw new Exception("fixture secret must never reach receipt");
            throw new System.ComponentModel.Win32Exception(NameQueryFails ? 122 : 5, NameQueryFails ? "GetUserObjectInformationW" : "GetThreadDesktop");
        }
        return "private";
    }
METHODS
}
'@
    $type = Add-Type -TypeDefinition ($support.Replace('TYPE_NAME', $typeName).Replace('METHODS', $Methods)) -PassThru | Where-Object Name -eq $typeName
    foreach ($fixture in @(
        @{ QueryFails = $false; Vanished = $false; Error = $false; ThreadExited = $false }
        @{ QueryFails = $true; Vanished = $true; Error = $false; ThreadExited = $true }
        @{ QueryFails = $true; Vanished = $false; Error = $true; ThreadExited = $false }
        @{ QueryFails = $true; Vanished = $true; RefreshFails = $true; Error = $true; ThreadExited = $false }
        @{ QueryFails = $true; ProcessExited = $true; Error = $false; ThreadExited = $false }
        @{ QueryFails = $true; NameQueryFails = $true; Error = $true; ThreadExited = $false }
        @{ QueryFails = $true; UnknownFailure = $true; Error = $true; ThreadExited = $false }
    )) {
        foreach ($field in @('QueryFails', 'Vanished', 'RefreshFails', 'ProcessExited', 'NameQueryFails', 'UnknownFailure')) { $type.GetField($field).SetValue($null, [bool]$fixture[$field]) }
        $type::Lookups = $type::Refreshes = 0
        $rows = @($type::ObserveDesktopThreads([int[]]@(41)))
        if ($rows.Count -ne 2 -or $type::Lookups -ne 1 -or [bool]$rows[0].Error -ne $fixture.Error -or
            $rows[0].ThreadExited -ne $fixture.ThreadExited -or $rows[0].Exited -ne [bool]$fixture.ProcessExited -or $rows[1].Desktop -cne 'private') {
            throw 'Observer lost the vanished/live/unexplained thread-query distinction.'
        }
        if ($fixture.QueryFails -and -not $fixture.ProcessExited -and $type::Refreshes -ne 1) { throw 'Thread disappearance requires a fresh retained-process enumeration.' }
        $api = if ($fixture.QueryFails -and -not $fixture.UnknownFailure) { if ($fixture.NameQueryFails) { 'GetUserObjectInformationW' } else { 'GetThreadDesktop' } } else { $null }
        $code = if ($api) { if ($fixture.NameQueryFails) { 122 } else { 5 } } else { $null }
        if ($rows[0].ErrorApi -cne $api -or $rows[0].ErrorCode -ne $code -or
            ($fixture.Error -and $rows[0].Error -cne $(if ($api) { "$api failed" } else { 'Thread desktop query failed' }))) {
            throw 'Observer lost sanitized API/error evidence or leaked an arbitrary exception message.'
        }
    }
}
Assert-HiddenMutation 'thread snapshot not refreshed' $observerCode ($observerCode.Replace('process.Refresh();', '')) ${function:Test-HiddenThreadRace}
Assert-HiddenMutation 'live failed thread accepted as exited' $observerCode ($observerCode.Replace('if (thread.Id == threadId) return false;', 'if (thread.Id == threadId) return true;')) ${function:Test-HiddenThreadRace}
Assert-HiddenMutation 'native error receipt code omitted' $observerCode ($observerCode.Replace('row.ErrorCode = nativeError.NativeErrorCode;', '')) ${function:Test-HiddenThreadRace}
Assert-HiddenMutation 'native error receipt stage omitted' $observerCode ($observerCode.Replace('row.ErrorApi = nativeError.Message;', '')) ${function:Test-HiddenThreadRace}

if (-not ('HiddenStartContract' -as [type])) {
    Add-Type @'
using System;
public class HiddenStartContract {
    public static int Launches;
    public DateTime StartTime = DateTime.UtcNow;
    public struct ProcessInfo { public int pid; public IntPtr thread, process; }
    public static ProcessInfo Launch(string a, string c, string w, string d, IntPtr j, string e) { Launches++; return new ProcessInfo { pid = 42 }; }
    public static HiddenStartContract GetProcessById(int pid) { return new HiddenStartContract(); }
    public static bool CloseHandle(IntPtr p) { return true; }
}
'@
}
$startFunction = (Get-HiddenFunction $hiddenLibText 'Start-HiddenNoctty').Replace('[HiddenWin]', '[HiddenStartContract]').Replace('[Diagnostics.Process]', '[HiddenStartContract]')
function Test-HiddenPrelaunchMetadata([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($fail in @($false, $true)) {
        $script:prelaunchMetadataCalls = 0; $script:prelaunchRunnerCalls = 0; [HiddenStartContract]::Launches = 0
        function Assert-HiddenRunner { $script:prelaunchRunnerCalls++ }
        function Assert-HiddenDesktop {
            $script:prelaunchMetadataCalls++
            if ([HiddenStartContract]::Launches -ne 0) { throw 'Metadata ran after launch.' }
            if ($fail) { throw 'fixture prelaunch metadata failure' }
        }
        function Test-Path { return $true }
        $blocked = $false
        try { $null = Start-HiddenNoctty -Dir 'C:\fixture' -Arguments @('unused') -DesktopName 'private' -Job ([IntPtr]7) }
        catch { $blocked = $_.Exception.Message -ceq 'fixture prelaunch metadata failure' }
        if ($blocked -ne $fail -or $script:prelaunchMetadataCalls -ne 1 -or $script:prelaunchRunnerCalls -ne 1 -or
            [HiddenStartContract]::Launches -ne [int](-not $fail)) { throw 'Prelaunch metadata must execute before and block a failed launch.' }
    }
}
Assert-HiddenMutation 'prelaunch metadata removed' $startFunction ($startFunction -replace '(?m)^\s+Assert-HiddenDesktop[^\r\n]*', '') ${function:Test-HiddenPrelaunchMetadata}
$prelaunchCall = [regex]::Match($startFunction, '(?m)^    Assert-HiddenDesktop[^\r\n]*').Value
$lateMetadata = ($startFunction.Replace($prelaunchCall, '')).Replace('    $process =', "$prelaunchCall`n    `$process =")
Assert-HiddenMutation 'prelaunch metadata moved after launch' $startFunction $lateMetadata ${function:Test-HiddenPrelaunchMetadata}

if (-not ('HiddenDriverContract' -as [type])) {
    Add-Type @'
using System;
public static class HiddenDriverContract {
    public static string Local, Roaming, Desktop;
    public static int Waits, Stops, ExitReads;
    public static uint ExitCode;
    public static bool ExitQueryFails;
    public struct ProcessInfo { public int pid; public IntPtr thread, process; }
    public static uint GetClipboardSequenceNumber() { return 0; }
    public static IntPtr CreateInheritedDesktop(string n) { return new IntPtr(1); }
    public static IntPtr CreateOwnedJob() { return new IntPtr(2); }
    public static string CurrentDesktopName() { return "Default"; }
    public static ProcessInfo Launch(string a, string c, string w, string desktop, IntPtr j, string e) {
        Local = Environment.GetEnvironmentVariable("LOCALAPPDATA"); Roaming = Environment.GetEnvironmentVariable("APPDATA"); Desktop = desktop;
        return new ProcessInfo { pid = 1 };
    }
    public static uint WaitForSingleObject(IntPtr p, uint ms) { return Waits++ == 0 ? 258u : 0u; }
    public static bool GetExitCodeProcess(IntPtr p, out uint code) { ExitReads++; code = ExitCode; return !ExitQueryFails; }
    public static uint StopOwnedJob(IntPtr j) { Stops++; return 0; }
    public static bool CloseHandle(IntPtr p) { return true; }
    public static bool CloseDesktop(IntPtr d) { return true; }
}
'@
}
$driverFunction = (Get-HiddenFunction $hiddenLibText 'Invoke-HiddenDriver').Replace('[HiddenWin]', '[HiddenDriverContract]')
function Test-HiddenDriverCode([string] $Code) {
    . ([scriptblock]::Create($Code))
    $script:driverRunnerGuardCalled = $false
    function Assert-HiddenRunner { $script:driverRunnerGuardCalled = $true }
    function Get-RealStateFingerprints { return @{ Startup = @{}; History = @{} } }
    function Get-FileFingerprint { return @{ Exists = $true; Hash = 'managed fixture' } }
    function Test-SameFingerprint { return $true }
    function Copy-PortableBin { }
    $script:defaultOracleCalls = 0; $script:metadataCalls = 0; $script:oracleThrows = $false
    function Assert-HiddenDefaultDesktop { $script:defaultOracleCalls++; if ($script:oracleThrows) { throw 'Hidden desktop fixture visible default window' } }
    function Assert-HiddenDesktop { $script:metadataCalls++ }
    function Approve-HiddenDriver { param($Job, $Run); Set-Content -LiteralPath (Join-Path $Run 'driver-desktop-release-requested') -Value ''; return $true }
    [HiddenDriverContract]::Waits = [HiddenDriverContract]::Stops = [HiddenDriverContract]::ExitReads = 0
    [HiddenDriverContract]::ExitCode = 0; [HiddenDriverContract]::ExitQueryFails = $false
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('noctty-hidden-contract-' + [guid]::NewGuid().ToString('N'))
    $savedLocal = $env:LOCALAPPDATA; $savedRoaming = $env:APPDATA
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'bin')
        Set-Content -LiteralPath (Join-Path $fixture 'bin\noctty.exe') -Value ''
        $runPath = Join-Path $fixture 'run'
        Invoke-HiddenDriver -Script 'unused.ps1' -Bin (Join-Path $fixture 'bin') -Run $runPath -TimeoutSeconds 1 -Label 'managed isolation fixture' 6>$null
        if (-not $script:driverRunnerGuardCalled) { throw 'Driver lost the hosted-runner gate.' }
        if ($script:defaultOracleCalls -ne 2) { throw 'Outer default-desktop oracle must run during polling and after driver exit.' }
        if ($script:metadataCalls -lt 1) { throw 'Outer polling must collect thread desktop metadata.' }
        if ([HiddenDriverContract]::Local -cne (Join-Path $runPath 'localappdata') -or
            [HiddenDriverContract]::Roaming -cne (Join-Path $runPath 'appdata') -or
            [HiddenDriverContract]::Desktop -notmatch '^WinSta0\\noctty-hw-[0-9a-f]{32}$') { throw 'Driver launch lost run-scoped app data or explicit desktop.' }
        if ($env:LOCALAPPDATA -cne $savedLocal -or $env:APPDATA -cne $savedRoaming) { throw 'Driver did not restore its environment.' }
        if ([HiddenDriverContract]::Stops -ne 1) { throw 'Driver must clean up its owned job.' }
        if (-not (Test-Path -LiteralPath (Join-Path $runPath 'driver-desktop-released'))) { throw 'Parent omitted sentinel release acknowledgment after private observation.' }
        $script:defaultOracleCalls = 0; $script:metadataCalls = 0; $script:oracleThrows = $true
        [HiddenDriverContract]::Waits = [HiddenDriverContract]::Stops = [HiddenDriverContract]::ExitReads = 0
        $blocked = $false
        try {
            Invoke-HiddenDriver -Script 'unused.ps1' -Bin (Join-Path $fixture 'bin') -Run (Join-Path $fixture 'run-failure') -TimeoutSeconds 1 -Label 'managed oracle failure fixture' 6>$null
        } catch { $blocked = $_.Exception.Message -ceq 'Hidden desktop fixture visible default window' }
        if (-not $blocked -or [HiddenDriverContract]::Stops -ne 1 -or [HiddenDriverContract]::Waits -ne 1 -or
            [HiddenDriverContract]::ExitReads -ne 0 -or $script:metadataCalls -ne 0 -or $script:defaultOracleCalls -ne 1) {
            throw 'Default-desktop failure must immediately clean up the owned job without continuing driver polling/metadata/exit checks.'
        }
        if ($env:LOCALAPPDATA -cne $savedLocal -or $env:APPDATA -cne $savedRoaming) { throw 'Oracle failure did not restore the driver environment.' }
        $script:oracleThrows = $false
        foreach ($failure in @('nonzero', 'query-failure')) {
            [HiddenDriverContract]::ExitCode = $(if ($failure -eq 'nonzero') { 7 } else { 0 })
            [HiddenDriverContract]::ExitQueryFails = $failure -eq 'query-failure'
            [HiddenDriverContract]::Waits = [HiddenDriverContract]::Stops = [HiddenDriverContract]::ExitReads = 0
            $blocked = $false
            try {
                Invoke-HiddenDriver -Script 'unused.ps1' -Bin (Join-Path $fixture 'bin') -Run (Join-Path $fixture $failure) -TimeoutSeconds 1 -Label 'managed exit failure fixture' 6>$null
            } catch {
                $expected = if ($failure -eq 'nonzero') { 'Hidden driver failed with exit 7;' } else { 'Hidden driver exit code query failed.' }
                $blocked = $_.Exception.Message.StartsWith($expected, [StringComparison]::Ordinal)
            }
            if (-not $blocked -or [HiddenDriverContract]::Stops -ne 1 -or [HiddenDriverContract]::ExitReads -ne 1) { throw 'Driver exit failures must reject success and clean the owned job.' }
            if ($env:LOCALAPPDATA -cne $savedLocal -or $env:APPDATA -cne $savedRoaming) { throw 'Exit failure did not restore the driver environment.' }
        }
    } finally {
        $env:LOCALAPPDATA = $savedLocal; $env:APPDATA = $savedRoaming
        if ([IO.Path]::GetDirectoryName($fixture) -eq [IO.Path]::GetTempPath().TrimEnd('\', '/') -and
            (Split-Path -Leaf $fixture) -match '^noctty-hidden-contract-[0-9a-f]{32}$') { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
}
Assert-HiddenMutation 'driver desktop null' $driverFunction ($driverFunction.Replace('"WinSta0\$desktopName"', '$null')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'driver runner gate removed' $driverFunction ($driverFunction.Replace('    Assert-HiddenRunner', '')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'outer window oracle removed' $driverFunction ($driverFunction -replace '(?m)^\s+Assert-HiddenDefaultDesktop[^\r\n]*', '') ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'outer private window sampling removed' $driverFunction ($driverFunction -replace '(?m)^\s+Assert-HiddenDesktop[^\r\n]*', '') ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'nonzero driver exit accepted' $driverFunction ($driverFunction.Replace('if ($code -ne 0)', 'if ($false)')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'driver exit API failure accepted' $driverFunction ($driverFunction.Replace("throw 'Hidden driver exit code query failed.'", '$null = 0')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'owned driver job cleanup removed' $driverFunction ($driverFunction.Replace('$ownedProcessCount = [HiddenDriverContract]::StopOwnedJob($job)', '$ownedProcessCount = 0')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'original LOCALAPPDATA inherited' $driverFunction ($driverFunction.Replace("Join-Path `$Run 'localappdata';", '$oldLocal;')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'original APPDATA inherited' $driverFunction ($driverFunction.Replace("Join-Path `$Run 'appdata'", '$oldRoaming')) ${function:Test-HiddenDriverCode}

$runnerGuard = Get-HiddenFunction $hiddenLibText 'Assert-HiddenRunner'
function Test-HiddenRunnerGuard([string] $Code) {
    . ([scriptblock]::Create($Code))
    $savedActions = $env:GITHUB_ACTIONS; $savedRunner = $env:RUNNER_ENVIRONMENT
    try {
        foreach ($fixture in @(@('true', 'github-hosted', $false), @('true', 'self-hosted', $true), @('', '', $true), @('', 'github-hosted', $true))) {
            $env:GITHUB_ACTIONS = $fixture[0]; $env:RUNNER_ENVIRONMENT = $fixture[1]
            $blocked = $false
            try { Assert-HiddenRunner } catch { $blocked = $true }
            if ($blocked -ne $fixture[2]) { throw 'Runner gate accepted a local/self-hosted launch or refused the hosted fixture.' }
        }
    } finally { $env:GITHUB_ACTIONS = $savedActions; $env:RUNNER_ENVIRONMENT = $savedRunner }
}
Assert-HiddenMutation 'self-hosted runner allowed' $runnerGuard ($runnerGuard.Replace("'github-hosted'", "'self-hosted'")) ${function:Test-HiddenRunnerGuard}
foreach ($script in $hiddenScripts) {
    $text = Remove-PowerShellComments (Get-Content -LiteralPath $script -Raw)
    if ($text -notmatch "(?m)^\. \(Join-Path .+ 'hidden-win11-lib.ps1'\)\r?\nAssert-HiddenRunner\r?\n" -or
        $text -notmatch '(?m)^\s+Assert-HiddenDesktop -Job \$job -DesktopName \$desktopName -ReceiptPath') {
        throw 'Hidden harness lost its entry runner gate or observed-thread desktop checks.'
    }
}

if (-not ('HiddenDesktopContract' -as [type])) {
    Add-Type @"
using System;
public static class HiddenDesktopContract {
    public static object[] Rows;
    public static Exception Failure;
    public static bool QueryFails;
    public static string Current;
    public static int[] JobProcessIds(IntPtr job) { if (QueryFails) throw new Exception("unknown fixture API secret"); return new int[] { 41, 42 }; }
    public static object[] PrivateJobWindows(IntPtr job, string name) { if (Failure != null) throw Failure; return Rows; }
    public static string CurrentDesktopName() { return Current; }
}
"@
}
$desktopAssertion = (Get-HiddenFunction $hiddenLibText 'Assert-HiddenDesktop').Replace('[HiddenWin]', '[HiddenDesktopContract]')
function Test-HiddenDesktopAssertion([string] $Code) {
    . ([scriptblock]::Create($Code))
    $name = 'noctty-hw-' + ('a' * 32)
    foreach ($fixture in @(
        @{}, @{ Required = 42 }, @{ Empty = $true }, @{ Empty = $true; Required = 42; Blocked = $true }
        @{ Required = 99; Blocked = $true }, @{ WrongPid = $true; Blocked = $true }
        @{ ZeroTid = $true; Blocked = $true }, @{ QueryFails = $true; Blocked = $true }
        @{ WrongCurrent = $true; Blocked = $true }, @{ BadName = $true; Blocked = $true }
        @{ NoWindows = $true; Blocked = $true }, @{ Empty = $true; NoWindows = $true }
        @{ Stale = $true }, @{ Stale = $true; Required = 42; Blocked = $true }, @{ Stale = $true; NoWindows = $true; Blocked = $true }
        @{ Native = 'OpenDesktopW'; Code = 5; Blocked = $true }
        @{ Native = 'EnumDesktopWindows'; Code = 170; Blocked = $true }
        @{ Native = 'GetWindowThreadProcessId'; Code = 1400; Blocked = $true }
        @{ Native = 'CloseDesktop'; Code = 6; Blocked = $true }
        @{ Native = 'GetThreadDesktop'; Code = 5; Blocked = $true }
        @{ Native = 'GetUserObjectInformationW'; Code = 122; Blocked = $true }
        @{ Native = 'EnumDesktopWindows'; Code = 170; Cleanup = 'CloseDesktop'; CleanupCode = 6; Observed = $true; Blocked = $true }
        @{ Native = 'OpenDesktopW secret'; Code = 5; Cleanup = 'CloseDesktop secret'; CleanupCode = 6; Blocked = $true }
        @{ Native = 'EnumDesktopWindows'; Code = 170; Cleanup = 'CloseDesktop'; CleanupCode = '6'; Blocked = $true }
        @{ Fixed = 'Job process query failed'; Blocked = $true }
        @{ Fixed = 'Job process query failed secret'; Blocked = $true }
    )) {
        $receipts = [Collections.Generic.List[string]]::new()
        function Add-Content { param([Parameter(ValueFromPipeline)] [string] $Value, [string] $LiteralPath); process { $receipts.Add($Value) } }
        [HiddenDesktopContract]::QueryFails = [bool]$fixture.QueryFails
        [HiddenDesktopContract]::Failure = $null
        if ($fixture.Native) { [HiddenDesktopContract]::Failure = [ComponentModel.Win32Exception]::new($fixture.Code, $fixture.Native) }
        elseif ($fixture.Fixed) { [HiddenDesktopContract]::Failure = [Exception]::new($fixture.Fixed) }
        if ($fixture.Cleanup) {
            [HiddenDesktopContract]::Failure.Data['CleanupApi'] = $fixture.Cleanup
            [HiddenDesktopContract]::Failure.Data['CleanupCode'] = $fixture.CleanupCode
        }
        if ($fixture.Observed) { [HiddenDesktopContract]::Failure.Data['ObservedWindows'] = @(@{ ProcessId = 42; ThreadId = 123 }, @{ ProcessId = 'secret'; ThreadId = 'secret' }) }
        [HiddenDesktopContract]::Current = if ($fixture.WrongCurrent) { 'Default' } else { $name }
        [HiddenDesktopContract]::Rows = @(if (-not $fixture.Empty) { @{ ProcessId = $(if ($fixture.WrongPid) { 99 } else { 42 }); ThreadId = $(if ($fixture.ZeroTid) { 0 } else { 123 }); CompletedAttempt = -not $fixture.Stale } })
        $blocked = $false
        try { Assert-HiddenDesktop -Job ([IntPtr]7) -DesktopName $(if ($fixture.BadName) { 'Default' } else { $name }) -ReceiptPath 'unused.jsonl' -RequiredWindowPid ([int]$fixture.Required) -NoWindows:([bool]$fixture.NoWindows) } catch { $blocked = $true; if ($fixture.Required -and $_.Exception.Message.StartsWith('Hidden desktop')) { throw 'Missing readiness window must remain an ordinary startup failure.' } }
        if ($blocked -ne [bool]$fixture.Blocked -or $receipts.Count -ne 1 -or $receipts[0].Contains('secret')) { throw 'Private desktop oracle lost failure rejection or sanitized receipt.' }
        $receipt = $receipts[0] | ConvertFrom-Json
        if ($receipt.Error) {
            $expectedApi = if ($fixture.Native -and -not $fixture.Native.Contains('secret')) { $fixture.Native } else { $null }
            $expectedStage = if ($expectedApi) { $expectedApi } elseif ($fixture.Fixed -and -not $fixture.Fixed.Contains('secret')) { $fixture.Fixed }
                elseif ($fixture.WrongPid -or $fixture.ZeroTid) { 'Invalid window owner' } elseif ($fixture.WrongCurrent) { 'Wrong driver desktop' } elseif ($fixture.BadName) { 'Invalid desktop name' } else { $null }
            $expectedCode = if ($expectedApi) { $fixture.Code } else { $null }
            $expectedCleanup = $fixture.Cleanup -ceq 'CloseDesktop' -and $fixture.CleanupCode -is [int]
            if ($receipt.ErrorStage -cne $expectedStage -or $receipt.ErrorApi -cne $expectedApi -or $receipt.ErrorCode -ne $expectedCode -or
                $receipt.CleanupErrorApi -cne $(if ($expectedCleanup) { 'CloseDesktop' } else { $null }) -or
                $receipt.CleanupErrorCode -ne $(if ($expectedCleanup) { $fixture.CleanupCode } else { $null })) { throw 'Private desktop failure receipt lost allowlisted stage/primary/cleanup codes or disclosed unknown values.' }
            if ($receipt.Windows.Count -ne [int][bool]$fixture.Observed -or ($fixture.Observed -and ($receipt.Windows[0].ProcessId -ne 42 -or $receipt.Windows[0].ThreadId -ne 123))) { throw 'Private desktop failure receipt lost sanitized prior window observations.' }
        }
        if (-not $blocked) {
            $receipt = $receipts[0] | ConvertFrom-Json
            if ($receipt.Oracle -cne 'EnumDesktopWindows' -or $receipt.ExpectedDesktop -cne $name -or $receipt.Windows.Count -ne [int](-not $fixture.Empty)) { throw 'Private desktop oracle lost actual PID/window evidence.' }
        }
    }
}
Assert-HiddenMutation 'private wrong PID accepted' $desktopAssertion ($desktopAssertion.Replace('$ids -notcontains $row.ProcessId', '$false')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private wrong self desktop accepted' $desktopAssertion ($desktopAssertion.Replace('[HiddenDesktopContract]::CurrentDesktopName() -cne $DesktopName', '$false')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private missing ready window accepted' $desktopAssertion ($desktopAssertion.Replace('$RequiredWindowPid -gt 0 -and', '$false -and')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private stale ready window accepted' $desktopAssertion ($desktopAssertion.Replace(' -and $_.CompletedAttempt -eq $true', '')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private idle window accepted' $desktopAssertion ($desktopAssertion.Replace('$NoWindows -and $rows.Count', '$false')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'desktop receipt removed' $desktopAssertion ($desktopAssertion.Replace('Add-Content -LiteralPath $ReceiptPath', 'Out-Null')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private native receipt code lost' $desktopAssertion ($desktopAssertion.Replace('$errorCode = $failure.NativeErrorCode', '$errorCode = $null')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private arbitrary native label disclosed' $desktopAssertion ($desktopAssertion.Replace('$nativeStages -ccontains $failure.Message', '$true')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private arbitrary fixed label disclosed' $desktopAssertion ($desktopAssertion.Replace('$fixedStages -ccontains $failure.Message', '$true')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private arbitrary cleanup label accepted' $desktopAssertion ($desktopAssertion.Replace("`$failure.Data['CleanupApi'] -ceq 'CloseDesktop'", '$true')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'private nonnumeric cleanup code accepted' $desktopAssertion ($desktopAssertion.Replace("`$failure.Data['CleanupCode'] -is [int]", '$true')) ${function:Test-HiddenDesktopAssertion}
if (-not ('HiddenApprovalContract' -as [type])) {
    Add-Type @'
using System;
public static class HiddenApprovalContract {
    public static bool MissingMember;
    public static int[] JobProcessIds(IntPtr job) { return MissingMember ? new[] { 99 } : new[] { 41 }; }
    public static string CurrentWindowStationName() { return "fixture-station"; }
}
'@
}
$approval = (Get-HiddenFunction $hiddenLibText 'Approve-HiddenDriver').Replace('[HiddenWin]', '[HiddenApprovalContract]').Replace('[Diagnostics.Process]::GetCurrentProcess().SessionId', '42')
function Test-HiddenApproval([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($fixture in @(@{}, @{ Missing = $true }, @{ Incomplete = $true }, @{ MissingWindow = $true; Blocked = $true }, @{ WrongPid = $true; Blocked = $true }, @{ WrongDesktop = $true; Blocked = $true },
        @{ WrongStation = $true; Blocked = $true }, @{ WrongSession = $true; Blocked = $true }, @{ MissingMember = $true; Blocked = $true })) {
        $name = 'noctty-hw-' + ('a' * 32); $script:approvalWrites = 0; $script:approvalWindowChecks = 0
        [HiddenApprovalContract]::MissingMember = [bool]$fixture.MissingMember
        function Test-Path { return -not $fixture.Missing }
        function Get-Content {
            if ($fixture.Incomplete) { return '{' }
            @{ ProcessId = $(if ($fixture.WrongPid) { 99 } else { 41 }); Desktop = $(if ($fixture.WrongDesktop) { 'Default' } else { $name })
                WindowStation = $(if ($fixture.WrongStation) { 'wrong' } else { 'fixture-station' }); SessionId = $(if ($fixture.WrongSession) { 99 } else { 42 }) } | ConvertTo-Json
        }
        function Set-Content { param($LiteralPath, $Value); if ($LiteralPath -cne 'C:\fixture\driver-desktop-approved') { throw 'Wrong approval path' }; $script:approvalWrites++ }
        function Assert-HiddenDesktop {
            param($Job, $DesktopName, $DriverPid, $RequiredWindowPid, $ReceiptPath)
            $script:approvalWindowChecks++
            if ($script:approvalWrites -or $DriverPid -ne 41 -or $RequiredWindowPid -ne 41 -or $DesktopName -cne $name -or $fixture.MissingWindow) { throw 'Driver sentinel was not independently observed before approval' }
        }
        $blocked = $false; $approved = $false
        try { $approved = Approve-HiddenDriver -Job ([IntPtr]7) -Run 'C:\fixture' -DesktopName $name -DriverPid 41 } catch { $blocked = $true }
        $expected = -not ($fixture.Blocked -or $fixture.Missing -or $fixture.Incomplete)
        if ($blocked -ne [bool]$fixture.Blocked -or $approved -ne $expected -or $script:approvalWrites -ne [int]$expected) { throw 'Driver approval accepted missing/wrong identity or omitted the exact approval handshake.' }
        if ($script:approvalWindowChecks -ne [int]($expected -or $fixture.MissingWindow)) { throw 'Parent must enumerate the sentinel only after a complete correct self-receipt.' }
    }
}
Assert-HiddenMutation 'driver receipt wrong PID approved' $approval ($approval.Replace('$receipt.ProcessId -ne $DriverPid', '$false')) ${function:Test-HiddenApproval}
Assert-HiddenMutation 'driver receipt wrong desktop approved' $approval ($approval.Replace('$receipt.Desktop -cne $DesktopName', '$false')) ${function:Test-HiddenApproval}
Assert-HiddenMutation 'driver receipt wrong station approved' $approval ($approval.Replace('$receipt.WindowStation -cne [HiddenApprovalContract]::CurrentWindowStationName()', '$false')) ${function:Test-HiddenApproval}
Assert-HiddenMutation 'driver receipt wrong session approved' $approval ($approval.Replace('$receipt.SessionId -ne 42', '$false')) ${function:Test-HiddenApproval}
Assert-HiddenMutation 'driver sentinel proof before approval omitted' $approval ($approval -replace '(?m)^    Assert-HiddenDesktop[^\r\n]*', '') ${function:Test-HiddenApproval}

if (-not ('SentinelCloseContract' -as [type])) {
    Add-Type @'
using System;
public static class SentinelCloseContract {
    public static DateTime UtcNow;
    public static int Stops, Destroys;
    public static bool StopFails, DestroyFails;
    public static uint StopOwnedJob(IntPtr job) { if (job != new IntPtr(7)) throw new Exception("wrong job"); Stops++; if (StopFails) throw new Exception("fixture cleanup secret"); return 1; }
    public static void DestroyDriverSentinel(IntPtr hwnd) { if (hwnd != new IntPtr(8)) throw new Exception("wrong sentinel"); Destroys++; if (DestroyFails) throw new Exception("fixture destroy secret"); }
}
'@
}
$sentinelClose = (Get-HiddenFunction $hiddenLibText 'Close-HiddenDriverSentinel').Replace('[HiddenWin]', '[SentinelCloseContract]').Replace('[datetime]::UtcNow', '[SentinelCloseContract]::UtcNow')
function Test-SentinelReleaseCleanup([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($fixture in @(@{}, @{ Wait = $true; Owned = $true }, @{ Wait = $true; Owned = $true; Delay = $true },
        @{ Wait = $true; MissingRelease = $true; Blocked = $true }, @{ Wait = $true; MissingRelease = $true; Primary = $true },
        @{ Wait = $true; Owned = $true; StopFails = $true; Blocked = $true }, @{ Wait = $true; Owned = $true; StopFails = $true; Primary = $true },
        @{ DestroyFails = $true; Blocked = $true }, @{ DestroyFails = $true; Primary = $true })) {
        [SentinelCloseContract]::UtcNow = [datetime]'2026-01-01T00:00:00Z'; [SentinelCloseContract]::Stops = [SentinelCloseContract]::Destroys = 0
        [SentinelCloseContract]::StopFails = [bool]$fixture.StopFails; [SentinelCloseContract]::DestroyFails = [bool]$fixture.DestroyFails
        $script:releaseSleeps = 0; $writes = @{}
        function Start-Sleep { param($Milliseconds); $script:releaseSleeps++; [SentinelCloseContract]::UtcNow = [SentinelCloseContract]::UtcNow.AddMilliseconds($Milliseconds) }
        function Test-Path { return -not $fixture.MissingRelease -and (-not $fixture.Delay -or $script:releaseSleeps -ge 3) }
        function Set-Content {
            param([Parameter(ValueFromPipeline)]$Value, $LiteralPath)
            process {
                if ($LiteralPath.EndsWith('driver-desktop-release-requested') -and ([SentinelCloseContract]::Destroys -or ($fixture.Owned -and [SentinelCloseContract]::Stops -ne 1))) { throw 'Release preceded app-owned job cleanup or sentinel lifetime ended early.' }
                $writes[(Split-Path -Leaf $LiteralPath)] = $Value
            }
        }
        $primary = if ($fixture.Primary) { [Exception]::new('primary secret') } else { $null }; $blocked = $false
        try { Close-HiddenDriverSentinel -Sentinel ([IntPtr]8) -Run 'C:\fixture' -WaitForParent:([bool]$fixture.Wait) -PrimaryFailure $primary -OwnedJob $(if ($fixture.Owned) { [IntPtr]7 } else { [IntPtr]::Zero }) } catch { $blocked = $true }
        if ($blocked -ne [bool]$fixture.Blocked -or [SentinelCloseContract]::Destroys -ne 1 -or [SentinelCloseContract]::Stops -ne [int][bool]$fixture.Owned -or $script:releaseSleeps -gt 300 -or
            ($fixture.Delay -and $script:releaseSleeps -ne 3)) { throw 'Sentinel release lost bounded cleanup or masked a primary body failure.' }
        $receiptText = $writes['driver-sentinel-cleanup.json']; $receipt = $receiptText | ConvertFrom-Json
        if (-not $receipt -or $receiptText.Contains('secret') -or $receipt.Destroyed -ne (-not [bool]$fixture.DestroyFails) -or $receipt.OwnedJobCleanedUp -eq [bool]$fixture.StopFails -or
            $receipt.PrimaryFailurePreserved -ne [bool]$fixture.Primary -or $receipt.CleanupFailed -ne [bool]($fixture.StopFails -or $fixture.DestroyFails -or $fixture.MissingRelease)) { throw 'Sentinel cleanup lost sanitized success/failure/provenance evidence.' }
        if ($fixture.StopFails -and $writes.ContainsKey('driver-desktop-release-requested')) { throw 'Failed app cleanup must not request sentinel release.' }
    }
}
Assert-HiddenMutation 'sentinel destroy omitted after release' $sentinelClose ($sentinelClose.Replace('[SentinelCloseContract]::DestroyDriverSentinel($Sentinel);', '')) ${function:Test-SentinelReleaseCleanup}
Assert-HiddenMutation 'sentinel release wait exceeds fifteen seconds' $sentinelClose ($sentinelClose.Replace('::UtcNow.AddSeconds(15)', '::UtcNow.AddSeconds(16)')) ${function:Test-SentinelReleaseCleanup}
Assert-HiddenMutation 'sentinel cleanup masks primary failure' $sentinelClose ($sentinelClose.Replace('$failure -and $null -eq $PrimaryFailure', '$failure')) ${function:Test-SentinelReleaseCleanup}

# Run the real approval initialization, wait, success assignment and cleanup clauses.
# Replace only the app body with a marker; neither a sentinel nor an app is created.
function Test-DriverApprovalLifecycle([string] $Code) {
    $ast = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
    $lifecycle = $ast.Find({ param($n) $n -is [Management.Automation.Language.TryStatementAst] -and
        $n.Finally -and $n.Finally.Extent.Text.Contains('Close-HiddenDriverSentinel') }, $true)
    if (-not $lifecycle -or $lifecycle.Body.Statements.Count -lt 2) { throw 'Driver approval lifecycle was not found.' }
    $initialization = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Extent.StartOffset -lt $lifecycle.Extent.StartOffset -and $_.Left.VariablePath.UserPath -in @('driverApproved', 'driverFailure', 'job')
    } | ForEach-Object { $_.Extent.Text }) -join "`n"
    $body = @($lifecycle.Body.Statements[0..1] | ForEach-Object { $_.Extent.Text }) -join "`n"
    $clauses = @($lifecycle.CatchClauses | ForEach-Object { $_.Extent.Text }) -join ' '
    $fixtureCode = $initialization + "`ntry {`n" + $body + "`n`$script:approvalContinued = `$true`n} " + $clauses + ' finally ' + $lifecycle.Finally.Extent.Text
    foreach ($fails in @($false, $true)) {
        $script:approvalContinued = $false; $script:approvalCleanup = $null
        function Wait-HiddenDriverApproval { param($Run, $DesktopName); if ($fails) { throw 'fixture approval failure' } }
        function Close-HiddenDriverSentinel {
            param($Sentinel, $Run, [switch]$WaitForParent, $PrimaryFailure, $OwnedJob)
            $script:approvalCleanup = @{ Wait = [bool]$WaitForParent; Primary = $null -ne $PrimaryFailure }
        }
        $sentinel = [IntPtr]8; $Run = 'C:\fixture'; $desktopName = 'fixture'; $blocked = $false
        try { & ([scriptblock]::Create($fixtureCode)) } catch { $blocked = $true }
        if ($blocked -ne $fails -or $script:approvalContinued -eq $fails -or $null -eq $script:approvalCleanup -or
            $script:approvalCleanup.Wait -eq $fails -or $script:approvalCleanup.Primary -ne $fails) { throw 'Unapproved driver waited for parent release or lost its primary approval failure.' }
    }
}
foreach ($scriptPath in $hiddenScripts) {
    $driverLifecycle = Remove-PowerShellComments (Get-Content -LiteralPath $scriptPath -Raw)
    Assert-HiddenMutation 'driver release before approval' $driverLifecycle ($driverLifecycle.Replace('-WaitForParent:$driverApproved', '-WaitForParent')) ${function:Test-DriverApprovalLifecycle}
    Assert-HiddenMutation 'driver marked approved before wait returns' $driverLifecycle ($driverLifecycle.Replace('$driverApproved = $false', '$driverApproved = $true')) ${function:Test-DriverApprovalLifecycle}
}

if (-not ('HiddenDefaultDesktopContract' -as [type])) {
    Add-Type @'
using System;
public static class HiddenDefaultDesktopContract {
    public static object[] Windows;
    public static bool QueryFails;
    public static Exception Failure;
    public static object[] DefaultJobWindows(IntPtr job) { if (Failure != null) throw Failure; if (job != new IntPtr(7) || QueryFails) throw new Exception("fixture query failure"); return Windows; }
}
'@
}
$defaultAssertion = (Get-HiddenFunction $hiddenLibText 'Assert-HiddenDefaultDesktop').Replace('[HiddenWin]', '[HiddenDefaultDesktopContract]')
function Test-HiddenDefaultDesktopAssertion([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($fixture in @(@{ WindowCount = 0 }, @{ WindowCount = 1; Blocked = $true }, @{ QueryFails = $true; Blocked = $true }, @{ Native = $true; Blocked = $true }, @{ Native = $true; Unknown = $true; Blocked = $true })) {
        $receipts = [Collections.Generic.List[string]]::new()
        function Add-Content {
            param([Parameter(ValueFromPipeline)] [string] $Value, [string] $LiteralPath)
            process { $receipts.Add($Value) }
        }
        [HiddenDefaultDesktopContract]::QueryFails = [bool]$fixture.QueryFails
        [HiddenDefaultDesktopContract]::Failure = $null
        if ($fixture.Native) {
            [HiddenDefaultDesktopContract]::Failure = [ComponentModel.Win32Exception]::new(1400, $(if ($fixture.Unknown) { 'GetWindowThreadProcessId secret' } else { 'GetWindowThreadProcessId' }))
            [HiddenDefaultDesktopContract]::Failure.Data['ObservedWindows'] = @(@{ ProcessId = 42; ThreadId = 123 }, @{ ProcessId = 'secret'; ThreadId = 'secret' })
        }
        [HiddenDefaultDesktopContract]::Windows = @(if ($fixture.WindowCount) { @{ ProcessId = 42; ThreadId = 123 } })
        $blocked = $false
        try { Assert-HiddenDefaultDesktop -Job ([IntPtr]7) -ReceiptPath 'unused.jsonl' } catch { $blocked = $true }
        if ($blocked -ne [bool]$fixture.Blocked -or $receipts.Count -ne [int][bool]$fixture.Blocked) { throw 'Default-desktop job-window oracle lost rejection or failure evidence.' }
        if ($fixture.Native) {
            $receipt = $receipts[0] | ConvertFrom-Json
            if ($receipts[0].Contains('secret') -or $receipt.Windows.Count -ne [int](-not $fixture.Unknown) -or
                (-not $fixture.Unknown -and ($receipt.ErrorApi -cne 'GetWindowThreadProcessId' -or $receipt.ErrorCode -ne 1400 -or $receipt.Windows[0].ProcessId -ne 42))) { throw 'Default desktop query failure discarded owned observations or disclosed unknown values.' }
        }
    }
}
Assert-HiddenMutation 'visible default job window accepted' $defaultAssertion ($defaultAssertion.Replace('if ($windows.Count)', 'if ($false)')) ${function:Test-HiddenDefaultDesktopAssertion}

# Real native observation only: no process/window is created and no existing job is touched.
. $hiddenLib
$closeImport = [HiddenWin].GetMethod('CloseDesktop').GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false)
if ($closeImport.Count -ne 1 -or -not $closeImport[0].SetLastError) { throw 'CloseDesktop must preserve the native error consumed by observer cleanup diagnostics.' }
$ownerImport = [HiddenWin].GetMethod('GetWindowThreadProcessId', [Reflection.BindingFlags]'Static,NonPublic').GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false)
if ($ownerImport.Count -ne 1 -or -not $ownerImport[0].SetLastError) { throw 'GetWindowThreadProcessId must preserve its native failure code.' }
$nativeRows = @([HiddenWin]::ObserveDesktopThreads([int[]]@($PID)))
if (-not $nativeRows.Count -or @($nativeRows | Where-Object { $_.Error -or (-not $_.Desktop -and -not $_.Unconnected -and -not $_.Exited -and -not $_.ThreadExited) }).Count) {
    throw 'Native observation of this PowerShell process produced query error rows.'
}
if (-not [HiddenWin]::CurrentDesktopName()) { throw 'Native current-desktop connection did not resolve.' }
$callingDesktop = [HiddenWin]::CurrentDesktopName()
if (-not [HiddenWin]::CurrentWindowStationName()) { throw 'Native window station query did not resolve.' }
$emptyJob = [HiddenWin]::CreateOwnedJob()
try {
    if (@([HiddenWin]::JobProcessIds($emptyJob)).Count -or @([HiddenWin]::DefaultJobWindows($emptyJob)).Count -or @([HiddenWin]::PrivateJobWindows($emptyJob, $callingDesktop)).Count) { throw 'A new owned job must have no process or visible job window.' }
} finally { $null = [HiddenWin]::StopOwnedJob($emptyJob) }
Write-Host "Native no-launch desktop checks: $($nativeRows.Count) own-process threads ($(@($nativeRows | Where-Object Desktop).Count) connected, $(@($nativeRows | Where-Object Unconnected).Count) unconnected) without errors; empty job/process/window queries passed"

# The live Default-window control is hosted-only. Here its real functions run with
# managed Win32 and filesystem seams; the window C# is compiled, never invoked.
$controlPath = Join-Path $repoRoot 'test\windows\hidden-win11-desktop-control.ps1'
$controlText = Remove-PowerShellComments (Get-Content -LiteralPath $controlPath -Raw)
function Test-DesktopControlStructure([string] $Code) {
    if ($Code -notmatch "(?m)^\. \(Join-Path .+ 'hidden-win11-lib.ps1'\)\r?\nAssert-HiddenRunner\r?\n" -or
        $Code -notmatch "(?s)switch \(\`$Mode\).*?'Parent' \{ Invoke-DesktopControlParent -Run \`$Run; Invoke-PrivateDesktopControlParent -Run \(Join-Path \`$Run 'private-desktop'\) \}.*?'Nested' \{ Invoke-DesktopControlNested -Run \`$Run \}.*?'Window' \{ Invoke-DesktopControlWindow \}.*?'PrivateDriver' \{ Invoke-PrivateDesktopControlDriver -Run \`$Run -DesktopName \`$DesktopName \}" -or
        $Code -notmatch $hiddenForbidden) { throw 'Desktop control lost its entry gate, mode dispatch or prohibited-operation boundary.' }
}
Assert-HiddenMutation 'desktop control entry gate removed' $controlText ($controlText.Replace("Assert-HiddenRunner`n`$controlScript", "`$controlScript")) ${function:Test-DesktopControlStructure}
$controlFunctions = (@('Start-DesktopControlHelper', 'Invoke-DesktopControlNested', 'Invoke-DesktopControlParent', 'Invoke-DesktopControlWindow') |
    ForEach-Object { Get-HiddenFunction $controlText $_ }) -join "`n"
$controlAst = [Management.Automation.Language.Parser]::ParseInput($controlText, [ref]$null, [ref]$null)
$windowCode = $controlAst.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $n.Value.StartsWith("using System;`n") -and $n.Value.Contains('class HiddenDesktopControlWindow') }, $true).Value
if (-not $windowCode) { throw 'Desktop control window C# was not found.' }
if ($windowCode -notmatch 'CreateWindowExW\(0x08000080, "STATIC", "", 0x80000000,') { throw 'Default positive control must use an invisible noactivate tool window.' }
if (-not ('HiddenDesktopControlWindow' -as [type])) { Add-Type -TypeDefinition $windowCode }
if (-not ('HiddenControlContract' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
public static class HiddenControlContract {
    public static int Gates, Creates, Launches, Waits, Runs, CleanupPolls;
    public static bool WrongWindow, MissingMember, OracleFails, StopFails, CleanupLeak, DelayedCleanup, NestedExited;
    public static string StderrPath;
    public static DateTime UtcNow;
    public static List<long> Stopped = new List<long>();
    public struct ProcessInfo { public int pid; public IntPtr process, thread; }
    public static string CurrentDesktopName() { return "Default"; }
    public static IntPtr CreateOwnedJob() { Creates++; return new IntPtr(7); }
    public static ProcessInfo Launch(string a, string c, string w, string d, IntPtr j, string e) {
        if (Gates == 0 || d != "WinSta0\\Default" || j != new IntPtr(7)) throw new Exception("Invalid control launch");
        StderrPath = e; Launches++; return new ProcessInfo { pid = c.EndsWith("Window") ? 42 : 41, process = new IntPtr(9) };
    }
    public static int[] JobProcessIds(IntPtr j) {
        if (NestedExited) {
            CleanupPolls++;
            return CleanupLeak || (DelayedCleanup && CleanupPolls <= 2) ? new int[] { 41, 42 } : new int[] { 41 };
        }
        return MissingMember ? new int[] { 41 } : new int[] { 41, 42 };
    }
    public class Window { public int ProcessId; }
    public static Window[] DefaultJobWindows(IntPtr j) {
        if (OracleFails) throw new Exception("fixture oracle failure");
        return new Window[] { new Window { ProcessId = WrongWindow ? 99 : 42 } };
    }
    public static uint WaitForSingleObject(IntPtr p, uint ms) { return ms == 10000 || Waits++ > 0 ? 0u : 258u; }
    public static bool GetExitCodeProcess(IntPtr p, out uint code) { NestedExited = true; code = 0; return true; }
    public static uint StopOwnedJob(IntPtr j) { Stopped.Add(j.ToInt64()); if (StopFails) throw new Exception("fixture stop failure"); return 1; }
    public static bool CloseHandle(IntPtr p) { return true; }
    public static void Run() { Runs++; }
}
'@
}
$controlFunctions = $controlFunctions.Replace('[HiddenWin]', '[HiddenControlContract]').Replace('[HiddenDesktopControlWindow]::Run()', '[HiddenControlContract]::Run()')
# Advance only the extracted control functions' clock in managed polling fixtures.
$controlFunctions = $controlFunctions.Replace('[datetime]::UtcNow', '[HiddenControlContract]::UtcNow')
function Test-DesktopControlFunctions([string] $Code) {
    . ([scriptblock]::Create($Code))
    $controlScript = 'C:\fixture\control.ps1'
    # Replace Add-Type only for the extracted window function. Its C# compiled above.
    function Add-Type { }
    foreach ($fixture in @(
        @{ Mode = 'Parent' }, @{ Mode = 'Nested' }, @{ Mode = 'Window' }
        @{ Mode = 'Parent'; DelayedCleanup = $true }
        @{ Mode = 'Parent'; CleanupLeak = $true; Blocked = $true }
        @{ Mode = 'Parent'; WrongWindow = $true; Blocked = $true }
        @{ Mode = 'Parent'; MissingMember = $true; Blocked = $true }
        @{ Mode = 'Nested'; MissingMember = $true; Blocked = $true }
        @{ Mode = 'Parent'; OracleFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; StopFails = $true; Blocked = $true }
        @{ Mode = 'Nested'; StopFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; Existing = $true; Blocked = $true }
        @{ Mode = 'Parent'; GateFails = $true; Blocked = $true }
        @{ Mode = 'Nested'; GateFails = $true; Blocked = $true }
        @{ Mode = 'Window'; GateFails = $true; Blocked = $true }
        @{ Mode = 'Helper'; GateFails = $true; Blocked = $true }
    )) {
        [HiddenControlContract]::Gates = [HiddenControlContract]::Creates = [HiddenControlContract]::Launches = [HiddenControlContract]::Waits = [HiddenControlContract]::Runs = 0
        [HiddenControlContract]::CleanupPolls = 0; [HiddenControlContract]::NestedExited = $false; [HiddenControlContract]::StderrPath = ''
        [HiddenControlContract]::UtcNow = [datetime]'2026-01-01T00:00:00Z'
        [HiddenControlContract]::Stopped.Clear()
        foreach ($field in @('WrongWindow', 'MissingMember', 'OracleFails', 'StopFails', 'CleanupLeak', 'DelayedCleanup')) { [HiddenControlContract].GetField($field).SetValue($null, [bool]$fixture[$field]) }
        $writes = @{}
        function Start-Sleep {
            param([int]$Milliseconds)
            $script:controlPollSleeps++
            if ($Milliseconds -ne 50 -or $script:controlPollSleeps -gt 40) { throw 'Managed cleanup poll exceeded two seconds.' }
            [HiddenControlContract]::UtcNow = [HiddenControlContract]::UtcNow.AddMilliseconds($Milliseconds)
        }
        $script:controlPollSleeps = 0; $script:controlCleanupReceiptReads = 0
        function Assert-HiddenRunner { [HiddenControlContract]::Gates++; if ($fixture.GateFails) { throw 'fixture runner gate' } }
        function Test-Path {
            param([string]$LiteralPath)
            if ($LiteralPath -eq 'C:\fixture\run') { return [bool]$fixture.Existing }
            return $true
        }
        function New-Item { }
        function Set-Content {
            param([Parameter(ValueFromPipeline)]$Value, [string]$LiteralPath)
            process {
                $writes[(Split-Path -Leaf $LiteralPath)] = $Value
            }
        }
        function Get-Content {
            param([string]$LiteralPath, [switch]$Raw)
            if ($LiteralPath.EndsWith('window-helper.json')) { return '{"WindowPid":42,"InnerMember":true}' }
            $script:controlCleanupReceiptReads++
            return '{"InnerJobCleanedUp":true,"OwnedProcessCount":1}'
        }
        $blocked = $false
        try {
            switch ($fixture.Mode) {
                'Parent' { Invoke-DesktopControlParent -Run 'C:\fixture\run' 6>$null }
                'Nested' { Invoke-DesktopControlNested -Run 'C:\fixture\run' }
                'Window' { Invoke-DesktopControlWindow }
                'Helper' { $null = Start-DesktopControlHelper -Job ([IntPtr]7) -Run 'C:\fixture\run' -HelperMode 'Nested' }
            }
        } catch {
            $blocked = $true
            if ($fixture.CleanupLeak -and $_.Exception.Message -cne 'Window helper remained in outer job after nested cleanup.') { throw 'Leaked helper must fail at the independent bounded membership check.' }
        }
        if ($blocked -ne [bool]$fixture.Blocked) { throw "Desktop control fixture $($fixture | ConvertTo-Json -Compress) lost its expected result." }
        if ($fixture.GateFails -or $fixture.Existing) {
            if ([HiddenControlContract]::Launches -or [HiddenControlContract]::Creates -or [HiddenControlContract]::Runs -or $writes.Count) { throw 'Blocked control must not launch, create jobs/windows or write receipts.' }
            continue
        }
        if ($fixture.Mode -eq 'Window') {
            if ([HiddenControlContract]::Gates -ne 2 -or [HiddenControlContract]::Runs -ne 1) { throw 'Window mode lost its entry/pre-window runner gate.' }
            continue
        }
        if ([HiddenControlContract]::Gates -ne 2 -or [HiddenControlContract]::Creates -ne 1 -or [HiddenControlContract]::Launches -ne 1 -or
            [HiddenControlContract]::Stopped.Count -ne 1 -or [HiddenControlContract]::Stopped[0] -ne 7) { throw 'Parent/nested control lost gate, owned job, helper launch or exact-job cleanup.' }
        $helperMode = if ($fixture.Mode -eq 'Parent') { 'Nested' } else { 'Window' }
        if ([HiddenControlContract]::StderrPath -cne (Join-Path 'C:\fixture\run' "$helperMode-stderr.log")) { throw 'Helper launch lost its mode-specific stderr artifact.' }
        if ($fixture.Mode -eq 'Parent') {
            if ($fixture.CleanupLeak -and ([HiddenControlContract]::CleanupPolls -ne 41 -or $script:controlPollSleeps -ne 40 -or $script:controlCleanupReceiptReads -ne 0)) {
                throw 'Cleanup leak must exhaust the two-second poll before reading the inner receipt.'
            }
            if (-not $fixture.Blocked -and ([HiddenControlContract]::CleanupPolls -ne $(if ($fixture.DelayedCleanup) { 3 } else { 1 }) -or
                $script:controlPollSleeps -ne $(if ($fixture.DelayedCleanup) { 2 } else { 0 }) -or $script:controlCleanupReceiptReads -ne 1)) { throw 'Successful cleanup must independently observe the helper disappear before accepting its receipt.' }
            $receipt = $writes['desktop-control-results.json'] | ConvertFrom-Json
            if (-not $receipt -or $receipt.Passed -ne (-not [bool]$fixture.Blocked) -or
                ($receipt.Passed -and ($receipt.WindowPid -ne 42 -or -not $receipt.DefaultOracleDetectedWindow -or -not $receipt.OuterJobContainsNestedWindow -or
                    -not $receipt.WindowHelperExitedBeforeOuterCleanup -or -not $receipt.InnerJobCleanedUp -or -not $receipt.OuterJobCleanedUp)) -or
                ($fixture.CleanupLeak -and ($receipt.WindowHelperExitedBeforeOuterCleanup -or $receipt.InnerJobCleanedUp -or -not $receipt.OuterJobCleanedUp))) { throw 'Parent control lost its sanitized result/cleanup receipt.' }
        } else {
            $receipt = $writes['nested-cleanup.json'] | ConvertFrom-Json
            if (-not $receipt -or $receipt.InnerJobCleanedUp -eq [bool]$fixture.StopFails) { throw 'Nested cleanup receipt lost success/failure evidence.' }
        }
    }
}
Assert-HiddenMutation 'desktop control mode gates removed' $controlFunctions ($controlFunctions -replace '(?m)^\s+Assert-HiddenRunner[^\r\n]*', '') ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control inner job removed' $controlFunctions ($controlFunctions.Replace('$inner = [HiddenControlContract]::CreateOwnedJob()', '$inner = [IntPtr]::Zero')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control outer membership ignored' $controlFunctions ($controlFunctions.Replace('$outerIds -contains $windowPid', '$true')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control default oracle removed' $controlFunctions ($controlFunctions.Replace('@([HiddenControlContract]::DefaultJobWindows($outer))', '@()')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control known window PID ignored' $controlFunctions ($controlFunctions.Replace('Where-Object ProcessId -eq $windowPid', 'Where-Object ProcessId -ne $windowPid')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control owned cleanup removed' $controlFunctions ($controlFunctions.Replace('[HiddenControlContract]::StopOwnedJob($inner)', '0').Replace('[HiddenControlContract]::StopOwnedJob($outer)', '0')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control existing directory allowed' $controlFunctions ($controlFunctions.Replace("if (Test-Path -LiteralPath `$Run) { throw 'Run directory must be new.' }", '')) ${function:Test-DesktopControlFunctions}
$cleanupPoll = [regex]::Match($controlFunctions, '(?ms)^        while \(@\(\[HiddenControlContract\]::JobProcessIds\(\$outer\)\) -contains \$windowPid\) \{.*?^        }').Value
if (-not $cleanupPoll) { throw 'Desktop control cleanup membership poll was not found.' }
Assert-HiddenMutation 'desktop control cleanup leak accepted' $controlFunctions ($controlFunctions.Replace($cleanupPoll, '')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control cleanup poll exceeds two seconds' $controlFunctions ($controlFunctions.Replace('::UtcNow.AddSeconds(2)', '::UtcNow.AddSeconds(3)')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control helper stderr omitted' $controlFunctions ($controlFunctions.Replace('(Join-Path $Run "$HelperMode-stderr.log")', "''")) ${function:Test-DesktopControlFunctions}

# Execute the private cross-process probe with managed launch, observer, clock and
# filesystem seams. The real hosted control alone starts its private helper.
if (-not ('PrivateDesktopContract' -as [type])) {
    Add-Type @'
using System;
public static class PrivateDesktopContract {
    public static string Desktop, Current;
    public static int Gates, Creates, Launches, Stops, Closes, StartupSamples, ReadySamples, DefaultSamples, AttachedSamples, SentinelCreates, SentinelDestroys;
    public static bool DriverExited, StopTimeout, ExitFails, CleanupFails, AttachedFails, AttachedNative, AttachedCleanup;
    public static string AttachedStage;
    public static DateTime UtcNow;
    public struct ProcessInfo { public int pid, tid; public IntPtr process, thread; }
    public static string CurrentDesktopName() { return Current; }
    public static IntPtr CreateDriverSentinel() { SentinelCreates++; return new IntPtr(12); }
    public static void DestroyDriverSentinel(IntPtr h) { if (h != new IntPtr(12)) throw new Exception("Wrong sentinel"); SentinelDestroys++; }
    public static string CurrentWindowStationName() { return "fixture-station"; }
    public static int[] JobProcessIds(IntPtr j) { return new[] { 41, 42 }; }
    public static IntPtr CreateInheritedDesktop(string n) { Desktop = n; Creates++; return new IntPtr(8); }
    public static IntPtr CreateOwnedJob() { return new IntPtr(7); }
    public static ProcessInfo Launch(string a, string c, string w, string d, IntPtr j, string e) {
        if (Gates == 0 || j != new IntPtr(7) || d != "WinSta0\\" + Desktop ||
            !System.IO.Path.IsPathFullyQualified(w) || !c.Contains("-Run \"" + w + "\"") ||
            !c.EndsWith("-Mode PrivateDriver -DesktopName " + Desktop) || e != System.IO.Path.Combine(w, "private-driver-stderr.log")) throw new Exception("Invalid private launch");
        Launches++; return new ProcessInfo { pid = 41, tid = 11, process = new IntPtr(9), thread = new IntPtr(10) };
    }
    public static uint WaitForSingleObject(IntPtr p, uint ms) {
        UtcNow = UtcNow.AddMilliseconds(ms);
        return ms == 5000 ? (StopTimeout ? 258u : 0u) : (DriverExited ? 0u : 258u);
    }
    public static bool GetExitCodeProcess(IntPtr p, out uint code) { code = ExitFails ? 1u : 0u; return true; }
    public static uint StopOwnedJob(IntPtr j) { if (j != new IntPtr(7)) throw new Exception("Wrong job"); Stops++; if (CleanupFails) throw new Exception("Fixture cleanup"); return 2; }
    public static bool CloseHandle(IntPtr h) { if (h != new IntPtr(9) && h != new IntPtr(10)) throw new Exception("Wrong handle"); Closes++; return true; }
    public static bool CloseDesktop(IntPtr d) { if (d != new IntPtr(8)) throw new Exception("Wrong desktop"); Closes++; return true; }
}
'@
}
$privateFunctions = ((@('Invoke-PrivateDesktopControlParent', 'Invoke-PrivateDesktopControlDriver') |
    ForEach-Object { Get-HiddenFunction $controlText $_ }) -join "`n").Replace('[HiddenWin]', '[PrivateDesktopContract]').Replace('[datetime]::UtcNow', '[PrivateDesktopContract]::UtcNow')
function Test-PrivateDesktopControl([string] $Code) {
    . ([scriptblock]::Create($Code))
    $controlScript = 'C:\fixture\control.ps1'
    foreach ($fixture in @(
        @{ Mode = 'Parent' }, @{ Mode = 'Driver' }
        @{ Mode = 'Parent'; Relative = $true }
        @{ Mode = 'Parent'; ReadyFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; WrongReadyPid = $true; Blocked = $true }
        @{ Mode = 'Parent'; WrongReadyDesktop = $true; Blocked = $true }
        @{ Mode = 'Parent'; MissingReady = $true; Blocked = $true }
        @{ Mode = 'Parent'; DriverExited = $true; Blocked = $true }
        @{ Mode = 'Parent'; OracleFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; StopTimeout = $true; Blocked = $true }
        @{ Mode = 'Parent'; ExitFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; CleanupFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; Existing = $true; Blocked = $true }
        @{ Mode = 'Parent'; GateFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; WrongCurrent = $true; Blocked = $true }
        @{ Mode = 'Driver'; GateFails = $true; Blocked = $true }
        @{ Mode = 'Driver'; WrongCurrent = $true; Blocked = $true }
        @{ Mode = 'Driver'; InvalidDesktop = $true; Blocked = $true }
        @{ Mode = 'Driver'; MissingStop = $true; Blocked = $true }
    )) {
        foreach ($field in @('Gates', 'Creates', 'Launches', 'Stops', 'Closes', 'StartupSamples', 'ReadySamples', 'DefaultSamples', 'AttachedSamples', 'SentinelCreates', 'SentinelDestroys')) { [PrivateDesktopContract].GetField($field).SetValue($null, 0) }
        foreach ($field in @('DriverExited', 'StopTimeout', 'ExitFails', 'CleanupFails', 'AttachedFails', 'AttachedNative', 'AttachedCleanup')) { [PrivateDesktopContract].GetField($field).SetValue($null, [bool]$fixture[$field]) }
        [PrivateDesktopContract]::AttachedStage = $fixture.AttachedStage
        [PrivateDesktopContract]::UtcNow = [datetime]'2026-01-01T00:00:00Z'
        $requestedRun = if ($fixture.Relative) { '.\fixture-private' } else { 'C:\fixture\private' }
        $expectedRun = [IO.Path]::GetFullPath($requestedRun)
        $expectedDesktop = 'noctty-hw-' + ('a' * 32)
        [PrivateDesktopContract]::Current = if ($fixture.WrongCurrent) { 'wrong' } elseif ($fixture.Mode -eq 'Driver') { $expectedDesktop } else { 'Default' }
        $writes = @{}
        function Assert-HiddenRunner { [PrivateDesktopContract]::Gates++; if ($fixture.GateFails) { throw 'Fixture gate' } }
        function Close-HiddenDriverSentinel { param($Sentinel, $Run, $PrimaryFailure); [PrivateDesktopContract]::DestroyDriverSentinel($Sentinel) }
        function New-Item { }
        function Test-Path {
            param([string]$LiteralPath)
            if ($LiteralPath -eq $expectedRun) { return [bool]$fixture.Existing }
            if ($LiteralPath.EndsWith('stop-private-control')) { return -not $fixture.MissingStop }
            return -not $fixture.MissingReady
        }
        function Set-Content {
            param([Parameter(ValueFromPipeline)]$Value, [string]$LiteralPath)
            process {
                if ($LiteralPath.EndsWith('private-driver-ready.json') -and ([PrivateDesktopContract]::SentinelCreates -ne 1 -or [PrivateDesktopContract]::SentinelDestroys -ne 0)) { throw 'Private control readiness must follow sentinel creation and precede its destruction.' }
                $writes[(Split-Path -Leaf $LiteralPath)] = $Value
            }
        }
        function Get-Content {
            param([string]$LiteralPath, [switch]$Raw)
            @{ ProcessId = $(if ($fixture.WrongReadyPid) { 99 } else { 41 }); Connected = $true
                Desktop = $(if ($fixture.WrongReadyDesktop) { 'Default' } else { [PrivateDesktopContract]::Desktop }); WindowStation = 'fixture-station'; SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId } | ConvertTo-Json
        }
        function Assert-HiddenDefaultDesktop { param($Job, $ReceiptPath); [PrivateDesktopContract]::DefaultSamples++; if ($fixture.OracleFails) { throw 'Fixture default oracle' } }
        function Assert-HiddenDesktop {
            param($Job, $DesktopName, $DriverPid, $ReceiptPath, [int]$RequiredWindowPid)
            if ($Job -ne [IntPtr]7 -or $DesktopName -cne [PrivateDesktopContract]::Desktop -or $DriverPid -ne 41 -or $RequiredWindowPid -ne 41 -or -not (Test-Path -LiteralPath (Join-Path $expectedRun 'private-driver-ready.json'))) { throw 'Wrong private observer arguments' }
            if ($ReceiptPath.EndsWith('private-ready-desktops.jsonl')) {
                [PrivateDesktopContract]::ReadySamples++; if ($fixture.ReadyFails) { throw 'Fixture ready metadata failure' }
            } else { [PrivateDesktopContract]::StartupSamples++; if ($fixture.StartupFails) { throw 'Fixture startup metadata failure' } }
        }
        function Start-Sleep { param([int]$Milliseconds); [PrivateDesktopContract]::UtcNow = [PrivateDesktopContract]::UtcNow.AddMilliseconds($Milliseconds) }
        $blocked = $false
        try {
            if ($fixture.Mode -eq 'Parent') { Invoke-PrivateDesktopControlParent -Run $requestedRun 6>$null }
            else { Invoke-PrivateDesktopControlDriver -Run 'C:\fixture\private' -DesktopName $(if ($fixture.InvalidDesktop) { 'Default' } else { $expectedDesktop }) }
        } catch { $blocked = $true }
        if ($blocked -ne [bool]$fixture.Blocked) { throw "Private control fixture $($fixture | ConvertTo-Json -Compress) lost its expected result." }
        if ($fixture.GateFails -or $fixture.Existing -or $fixture.WrongCurrent -or $fixture.InvalidDesktop) {
            if ([PrivateDesktopContract]::Creates -or [PrivateDesktopContract]::Launches -or [PrivateDesktopContract]::SentinelCreates -or $writes.Count) { throw 'Rejected private control had side effects.' }
            continue
        }
        if ($fixture.Mode -eq 'Driver') {
            $ready = $writes['private-driver-ready.json'] | ConvertFrom-Json
            if ([PrivateDesktopContract]::SentinelCreates -ne 1 -or [PrivateDesktopContract]::SentinelDestroys -ne 1 -or -not $ready.Connected -or $ready.Desktop -cne $expectedDesktop -or $ready.ProcessId -ne $PID) { throw 'Private driver lost its self-connection receipt.' }
            continue
        }
        if ([PrivateDesktopContract]::Launches -ne 1 -or [PrivateDesktopContract]::Creates -ne 1 -or [PrivateDesktopContract]::Stops -ne 1 -or [PrivateDesktopContract]::Closes -ne 3) { throw 'Private control lost bounded owned cleanup.' }
        $receipt = $writes['private-desktop-control-results.json'] | ConvertFrom-Json
        if (-not $receipt -or $receipt.Passed -ne (-not [bool]$fixture.Blocked) -or $receipt.DriverPid -ne 41 -or $receipt.MainThreadId -ne 11 -or
            $receipt.OwnedJobCleanedUp -eq [bool]$fixture.CleanupFails) { throw 'Private control lost its success/failure/cleanup evidence.' }
        if (-not $fixture.Blocked -and ([PrivateDesktopContract]::StartupSamples -ne 0 -or [PrivateDesktopContract]::ReadySamples -ne 1 -or [PrivateDesktopContract]::DefaultSamples -lt 1)) { throw 'Private control must wait for readiness before private enumeration while keeping Default active.' }
    }
}
Assert-HiddenMutation 'private control relative run not normalized' $privateFunctions ($privateFunctions.Replace('$Run = [IO.Path]::GetFullPath($Run)', '')) ${function:Test-PrivateDesktopControl}
Assert-HiddenMutation 'private control ready PID ignored' $privateFunctions ($privateFunctions.Replace(' -and $ready.ProcessId -eq $driver.pid', '')) ${function:Test-PrivateDesktopControl}
Assert-HiddenMutation 'private control ready desktop ignored' $privateFunctions ($privateFunctions.Replace(' -and $ready.Desktop -ceq $desktopName', '')) ${function:Test-PrivateDesktopControl}
Assert-HiddenMutation 'private control ready observer omitted' $privateFunctions ($privateFunctions -replace '(?m)^\s+Assert-HiddenDesktop[^\r\n]+private-ready-desktops.jsonl[^\r\n]*', '') ${function:Test-PrivateDesktopControl}
Assert-HiddenMutation 'private control default oracle omitted' $privateFunctions ($privateFunctions -replace '(?m)^\s+Assert-HiddenDefaultDesktop[^\r\n]*', '') ${function:Test-PrivateDesktopControl}
Assert-HiddenMutation 'private control owned cleanup omitted' $privateFunctions ($privateFunctions.Replace('$count = [PrivateDesktopContract]::StopOwnedJob($job)', '$count = 0')) ${function:Test-PrivateDesktopControl}
Assert-HiddenMutation 'private driver self-connection unchecked' $privateFunctions ($privateFunctions.Replace("if (`$actual -cne `$DesktopName) { throw 'Private control driver is on the wrong desktop.' }", '')) ${function:Test-PrivateDesktopControl}

$embeddingText = Remove-PowerShellComments (Get-Content -LiteralPath $hiddenScripts[1] -Raw)
$embeddingAst = [Management.Automation.Language.Parser]::ParseInput($embeddingText, [ref]$null, [ref]$null)
$embeddingPoll = $embeddingAst.Find({ param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Statements[0] -is [Management.Automation.Language.WhileStatementAst] -and $n.Extent.Text.Contains('FatalDesktopObservation') }, $true).Extent.Text
if (-not $embeddingPoll) { throw 'Embedding desktop failure evidence path was not found.' }
if (-not ('EmbeddingAbortContract' -as [type])) { Add-Type 'public static class EmbeddingAbortContract { public static string[] VisibleTopLevelClasses(int pid) { return new string[0]; } }' }
$embeddingPoll = $embeddingPoll.Replace('[HiddenWin]', '[EmbeddingAbortContract]')
function Test-EmbeddingAbortEvidence([string] $Code) {
    foreach ($fixture in @(@{}, @{ PrivateWindow = $true; Blocked = $true }, @{ QueryFails = $true; Blocked = $true }, @{ Negative = $true })) {
        $Run = 'C:\fixture'; $desktopName = 'noctty-hw-fixture'; $job = [IntPtr]7; $NegativeControl = [bool]$fixture.Negative
        $started = @{ Process = @{ HasExited = $false }; Pid = 42 }; $closed = $false
        $sw = @{ Elapsed = @{ TotalSeconds = 0 } }; $script:embeddingAbortSleeps = 0
        $classes = [Collections.Generic.HashSet[string]]::new(); $checks = [Collections.Generic.List[object]]::new(); $receipts = [Collections.Generic.List[string]]::new()
        function Assert-HiddenDesktop {
            param($Job, $DesktopName, $ReceiptPath, [switch]$NoWindows)
            if ($fixture.QueryFails -or ($NoWindows -and $fixture.PrivateWindow)) { throw 'Hidden desktop fixture observation failed' }
        }
        function Check { param($Name, $Passed, $Expected, $Actual); $checks.Add(@{ Name = $Name; Passed = $Passed; Expected = $Expected; Actual = $Actual }) }
        function Start-Sleep { $script:embeddingAbortSleeps++; $sw.Elapsed.TotalSeconds = 41 }
        function Set-Content { param([Parameter(ValueFromPipeline)] $Value, $LiteralPath); process { if ($LiteralPath -cne 'C:\fixture\embedding-results.json') { throw 'Wrong embedding abort receipt path' }; $receipts.Add($Value) } }
        $blocked = $false
        try { & ([scriptblock]::Create($Code)) } catch { $blocked = $true }
        if ($blocked -ne [bool]$fixture.Blocked -or $receipts.Count -ne [int][bool]$fixture.Blocked -or $script:embeddingAbortSleeps -ne [int](-not $fixture.Blocked)) { throw 'Embedding confinement failure must write a result and immediately rethrow without further polling.' }
        if ($fixture.Blocked) {
            $receipt = $receipts[0] | ConvertFrom-Json
            if (-not $receipt.FatalDesktopObservation -or $receipt.Checks.Count -ne 1 -or $receipt.Checks[0].Passed -ne $false -or $receipt.Limit -notlike 'Aborted*') { throw 'Embedding abort lost its failed result or incomplete-lifecycle limit.' }
        }
    }
}
Assert-HiddenMutation 'embedding desktop failure result omitted' $embeddingPoll ($embeddingPoll.Replace('Set-Content -LiteralPath', 'Out-Null # Set-Content -LiteralPath')) ${function:Test-EmbeddingAbortEvidence}
Assert-HiddenMutation 'embedding desktop failure swallowed' $embeddingPoll ($embeddingPoll -replace '(?m)^    throw\r?$', '') ${function:Test-EmbeddingAbortEvidence}
Assert-HiddenMutation 'embedding private window bypassed' $embeddingPoll ($embeddingPoll.Replace('if (-not $NegativeControl)', 'if ($false)')) ${function:Test-EmbeddingAbortEvidence}
$embeddingArguments = [regex]::Match($embeddingText, '(?ms)^\$uniqueClass =.*?(?=^Assert-EmbeddingDelegationSafe|^\$started =)').Value
function Test-EmbeddingArguments([string] $Code) {
    if (-not $Code) { throw 'Embedding argument construction missing.' }
    foreach ($control in @($false, $true)) {
        & {
            $NegativeControl = $control
            . ([scriptblock]::Create($Code))
            $marker = [array]::IndexOf($launchArguments, '-Embedding')
            if ($launchArguments[0] -cne '--single-instance=false' -or $launchArguments[1] -notmatch '^--class=noctty-test-pkg76-embedding-[0-9a-f]{8}$' -or
                ($control -and $marker -ne -1) -or (-not $control -and ($marker -ne 2 -or $launchArguments.Count -ne 3))) { throw 'Embedding isolation must precede the stop marker.' }
        }
    }
}
Assert-HiddenMutation 'embedding stop marker before isolation' $embeddingArguments ($embeddingArguments.Replace("`$launchArguments += '-Embedding'", "`$launchArguments = @('-Embedding') + `$launchArguments")) ${function:Test-EmbeddingArguments}
$embeddingAst = [Management.Automation.Language.Parser]::ParseInput($embeddingText, [ref]$null, [ref]$null)
$oracle = $embeddingAst.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Check' -and $node.CommandElements[1].Extent.Text -eq "'it opens no visible top-level window'" }, $true).Extent.Text
function Test-EmbeddingOracle([string] $Code) {
    if (-not $Code) { throw 'Embedding visible UI oracle missing.' }
    foreach ($class in @('', 'noctty.win32.host', '#32770')) {
        & {
            $classes = [Collections.Generic.HashSet[string]]::new()
            if ($class) { [void]$classes.Add($class) }
            function Check([string] $Name, [bool] $Passed, $Expected, $Actual) {
                if ($Passed -ne (-not [bool]$class)) { throw 'Embedding oracle accepted unexpected process UI.' }
            }
            . ([scriptblock]::Create($Code))
        }
    }
}
Assert-HiddenMutation 'host-only embedding oracle misses dialog' $oracle ($oracle.Replace('$classes.Count -eq 0', "-not `$classes.Contains('noctty.win32.host')")) ${function:Test-EmbeddingOracle}

$profileText = Remove-PowerShellComments (Get-Content -LiteralPath $hiddenScripts[0] -Raw)
$powerShellProbe = Get-HiddenFunction $profileText 'Install-HiddenPowerShellProbe'
function Test-PowerShellProbe([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($emitOsc in @($false, $true)) {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) ('noctty-prompt-contract-' + [guid]::NewGuid().ToString('N'))
        $path = Join-Path $fixture 'share\ghostty\shell-integration\powershell\integration.ps1'
        $savedPrompt = $function:global:prompt; $savedWriter = $function:global:__ghostty_write_osc
        $savedGlobals = @{}
        foreach ($name in @('__noctty_test_original_prompt', '__noctty_test_original_write_osc', '__noctty_test_cwd_written')) {
            $variable = Get-Variable -Name $name -Scope Global -ErrorAction Ignore
            $savedGlobals[$name] = @{ Exists = $null -ne $variable; Value = $variable.Value }
        }
        try {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path)
            $original = @'
if ($script:probeOptions.HistorySaveStyle -cne 'SaveNothing' -or $script:probeOptions.HistorySavePath -cne (Join-Path $script:probeRoot 'history.txt')) { throw 'History isolation did not precede script load.' }
function global:__ghostty_write_osc { param([string]$Sequence); $script:probeForwarded.Add($Sequence) }
function global:prompt {
    $script:probePromptCalls++
    if ($script:probeEmitOsc) { __ghostty_write_osc $script:probeOsc }
    return 'fixture prompt>'
}
'@
            [IO.File]::WriteAllText($path, $original, [Text.UTF8Encoding]::new($false))
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            Install-HiddenPowerShellProbe -CaseRoot $fixture
            if ((Get-FileHash -LiteralPath (Join-Path $fixture 'integration.original.ps1') -Algorithm SHA256).Hash -cne $hash) { throw 'Probe did not preserve original integration bytes.' }
            $provenance = Get-Content -LiteralPath (Join-Path $fixture 'integration-instrumentation.json') -Raw | ConvertFrom-Json
            if ($provenance.OriginalSha256 -cne $hash -or $provenance.InstrumentedSha256 -cne (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -or $provenance.OriginalSha256 -ceq $provenance.InstrumentedSha256) { throw 'Probe lost original/instrumented provenance.' }
            $script:probeOptions = @{ HistorySavePath = 'foreign'; HistorySaveStyle = 'SaveIncrementally' }
            $script:probeRoot = $fixture; $script:probePromptCalls = 0; $script:probeEmitOsc = $emitOsc
            $script:probeOsc = ([string][char]27) + ']7;file:///C:/fixture' + [char]7
            $script:probeForwarded = [Collections.Generic.List[string]]::new()
            & {
                function Import-Module { param($Name, $ErrorAction); if ($Name -cne 'PSReadLine') { throw 'Wrong module' } }
                function Set-PSReadLineOption { param($HistorySavePath, $HistorySaveStyle, $ErrorAction); $script:probeOptions = @{ HistorySavePath = $HistorySavePath; HistorySaveStyle = $HistorySaveStyle } }
                function Get-PSReadLineOption { return $script:probeOptions }
                . $path
                $result = & $function:global:prompt
                if ($result -cne 'fixture prompt>') { throw 'Probe changed actual prompt output.' }
            }
            $readyPath = Join-Path $fixture 'powershell-prompt-ready.json'
            if ($script:probePromptCalls -ne 1 -or (Test-Path -LiteralPath $readyPath) -ne $emitOsc -or $script:probeForwarded.Count -ne [int]$emitOsc -or
                ($emitOsc -and $script:probeForwarded[0] -cne $script:probeOsc)) { throw 'Probe readiness preceded real OSC/prompt or changed forwarded OSC.' }
            if ($emitOsc) {
                $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
                if ($ready.ProcessId -ne $PID -or -not $ready.PromptReturned -or -not $ready.CwdOscForwarded -or $ready.HistorySaveStyle -cne 'SaveNothing') { throw 'Probe lost readiness/history evidence.' }
            }
        } finally {
            $function:global:prompt = $savedPrompt
            if ($null -eq $savedWriter) { Remove-Item -LiteralPath Function:\global:__ghostty_write_osc -ErrorAction Ignore } else { $function:global:__ghostty_write_osc = $savedWriter }
            foreach ($name in $savedGlobals.Keys) {
                if ($savedGlobals[$name].Exists) { Set-Variable -Name $name -Value $savedGlobals[$name].Value -Scope Global } else { Remove-Variable -Name $name -Scope Global -ErrorAction Ignore }
            }
            if ([IO.Path]::GetDirectoryName($fixture) -eq [IO.Path]::GetTempPath().TrimEnd('\', '/') -and
                (Split-Path -Leaf $fixture) -match '^noctty-prompt-contract-[0-9a-f]{32}$') { Remove-Item -LiteralPath $fixture -Recurse -Force }
        }
    }
}
Assert-HiddenMutation 'PowerShell history saving left enabled' $powerShellProbe ($powerShellProbe.Replace('-HistorySaveStyle SaveNothing', '-HistorySaveStyle SaveIncrementally')) ${function:Test-PowerShellProbe}
Assert-HiddenMutation 'PowerShell readiness without OSC' $powerShellProbe ($powerShellProbe.Replace('if ($Global:__noctty_test_cwd_written)', 'if ($true)')) ${function:Test-PowerShellProbe}
Assert-HiddenMutation 'PowerShell actual prompt omitted' $powerShellProbe ($powerShellProbe.Replace('$result = & $Global:__noctty_test_original_prompt', '$result = "fixture prompt>"')) ${function:Test-PowerShellProbe}

if (-not ('HiddenPromptClock' -as [type])) { Add-Type 'public static class HiddenPromptClock { public static System.DateTime UtcNow; }' }
$promptWait = (Get-HiddenFunction $profileText 'Wait-HiddenPowerShellPrompt').Replace('[datetime]::UtcNow', '[HiddenPromptClock]::UtcNow')
function Test-PowerShellPromptWait([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($fixture in @(@{}, @{ Delay = $true }, @{ WrongPid = $true; Blocked = $true }, @{ NoOsc = $true; Blocked = $true },
        @{ BadStyle = $true; Blocked = $true }, @{ Missing = $true; Blocked = $true }, @{ OracleFails = $true; Blocked = $true })) {
        [HiddenPromptClock]::UtcNow = [datetime]'2026-01-01T00:00:00Z'; $script:promptSleeps = 0; $script:promptOracles = 0
        $job = [IntPtr]7; $desktopName = 'noctty-hw-fixture'; $desktopReceipt = 'unused'
        function Start-Sleep { param($Milliseconds); $script:promptSleeps++; [HiddenPromptClock]::UtcNow = [HiddenPromptClock]::UtcNow.AddMilliseconds($Milliseconds) }
        function Test-Path { return -not $fixture.Missing -and (-not $fixture.Delay -or $script:promptSleeps -ge 5) }
        function Get-Content { @{ ProcessId = $(if ($fixture.WrongPid) { 99 } else { 41 }); PromptReturned = $true; CwdOscForwarded = -not $fixture.NoOsc; HistorySaveStyle = $(if ($fixture.BadStyle) { 'SaveIncrementally' } else { 'SaveNothing' }) } | ConvertTo-Json }
        function Assert-HiddenDesktop { param($Job, $DesktopName, $ReceiptPath, $RequiredWindowPid); $script:promptOracles++; if ($RequiredWindowPid -ne 42 -or $fixture.OracleFails) { throw 'Fixture private oracle failure' } }
        $blocked = $false
        try { Wait-HiddenPowerShellPrompt -Case @{ Dir = 'C:\fixture\bin' } -ProcessId 42 -ShellPid 41 } catch { $blocked = $true }
        if ($blocked -ne [bool]$fixture.Blocked -or $script:promptSleeps -gt 300 -or $script:promptOracles -ne ($script:promptSleeps + [int](-not $blocked -or $fixture.OracleFails)) -or
            ($fixture.Delay -and $script:promptSleeps -ne 5)) { throw 'PowerShell prompt wait lost bounded readiness, identity or private-window checks.' }
    }
}
Assert-HiddenMutation 'PowerShell wrong readiness PID accepted' $promptWait ($promptWait.Replace('$ready.ProcessId -eq $ShellPid', '$true')) ${function:Test-PowerShellPromptWait}
Assert-HiddenMutation 'PowerShell readiness without forwarded OSC accepted' $promptWait ($promptWait.Replace('$ready.CwdOscForwarded -eq $true', '$true')) ${function:Test-PowerShellPromptWait}
Assert-HiddenMutation 'PowerShell readiness without history isolation accepted' $promptWait ($promptWait.Replace("`$ready.HistorySaveStyle -ceq 'SaveNothing'", '$true')) ${function:Test-PowerShellPromptWait}

$delegationGuard = Get-HiddenFunction $hiddenLibText 'Assert-EmbeddingDelegationSafe'
function Test-EmbeddingDelegationGuard([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($value in @($null, '', '{11111111-1111-1111-1111-111111111111}', '{33368c6f-d328-410c-b225-26dc9f12c728}', '33368C6F-D328-410C-B225-26DC9F12C728', 'missing-key', 'unreadable')) {
        function Get-ItemProperty {
            param($LiteralPath, $ErrorAction)
            if ($LiteralPath -cne 'HKCU:\Console\%%Startup' -or $ErrorAction -cne 'Stop') { throw 'Wrong delegation registry read.' }
            if ($value -eq 'missing-key') { throw [Management.Automation.ItemNotFoundException]::new('Fixture missing key') }
            if ($value -eq 'unreadable') { throw [UnauthorizedAccessException]::new('Fixture unreadable key') }
            return @{ DelegationTerminal = $value }
        }
        $blocked = $false
        try { Assert-EmbeddingDelegationSafe } catch { $blocked = $true }
        $expected = $value -like '*33368*-d328-410c-b225-26dc9f12c728*' -or $value -eq 'unreadable'
        if ($blocked -ne $expected) { throw 'Delegation guard failed to distinguish absent/unrelated selection from noctty or unreadable state.' }
    }
}
Assert-HiddenMutation 'real COM handoff CLSID unguarded' $delegationGuard ($delegationGuard.Replace('33368C6F-D328-410C-B225-26DC9F12C728', '11111111-1111-1111-1111-111111111111')) ${function:Test-EmbeddingDelegationGuard}
# Check the actual call sites as well as the callable guard; comments are already removed.
function Test-EmbeddingGuardCalls([string] $Code) {
    if ($Code -notmatch '(?m)^Assert-EmbeddingDelegationSafe\r?\n\s*if \(-not \$Driver\)' -or
        $Code -notmatch '(?m)^Assert-EmbeddingDelegationSafe\r?\n\$started = Start-HiddenNoctty') { throw 'Embedding launch lost the entry/prelaunch delegation guard.' }
}
Assert-HiddenMutation 'delegation guard call removed' $embeddingText ($embeddingText -replace '(?m)^Assert-EmbeddingDelegationSafe\r?\n', '') ${function:Test-EmbeddingGuardCalls}

$requiredProfileLoop = [regex]::Match($profileText, '(?ms)^foreach \(\$key in \$Profile\).*?^}').Value
$requiredProfileForwarding = [regex]::Match($profileText, '(?m)^    if \(\$RequireAll\)[^\r\n]*').Value
function Test-RequiredProfile([string] $Code) {
    foreach ($required in @($false, $true)) {
        & {
            $RequireAll = $required; $extra = @(); $Profile = @('missing.exe')
            $expectations = @{ 'missing.exe' = @{} }; $cases = [Collections.Generic.List[object]]::new()
            $script:requiredFailures = 0
            function Test-Available { return $false }
            function Check($Case, $Name, $Passed, $Expected, $Actual) { if (-not $Passed) { $script:requiredFailures++ } }
            function Invoke-Case { throw 'Unavailable profile must never launch.' }
            . ([scriptblock]::Create($Code))
            if (($extra -contains '-RequireAll') -ne $required -or $script:requiredFailures -ne [int]$required -or
                $cases.Count -ne 1 -or $cases[0].Result -cne 'skipped') { throw 'Required profile forwarding or missing-profile failure was lost.' }
        }
    }
}
$requiredProfileCode = $requiredProfileForwarding + "`n" + $requiredProfileLoop
Assert-HiddenMutation 'required-profile skip passes' $requiredProfileCode ($requiredProfileCode.Replace("Check `$key 'required profile is installed and detected' `$false", "Check `$key 'required profile is installed and detected' `$true")) ${function:Test-RequiredProfile}
Assert-HiddenMutation 'required-profile switch not forwarded' $requiredProfileCode ($requiredProfileCode.Replace("`$extra += '-RequireAll'", '$extra += ""')) ${function:Test-RequiredProfile}

# The negative control must forward its renderer and seed it before the stop marker.
$embeddingForwarding = [regex]::Match($embeddingText, '(?ms)^    \$extra = @\(\);.*?(?=^    Invoke-HiddenDriver)').Value
function Test-EmbeddingRendererForwarding([string] $Code) {
    $AllowProductAumid = $false; $NegativeControl = $true; $Renderer = 'd3d11-warp'
    . ([scriptblock]::Create($Code))
    $marker = [array]::IndexOf($extra, '-Renderer')
    if ($marker -lt 0 -or $extra[$marker + 1] -cne $Renderer -or $extra -notcontains '-NegativeControl') { throw 'Embedding negative control must forward its renderer.' }
}
Assert-HiddenMutation 'embedding renderer not forwarded' $embeddingForwarding ($embeddingForwarding.Replace("@('-Renderer', `$Renderer)", '@()')) ${function:Test-EmbeddingRendererForwarding}
$embeddingConfig = [regex]::Match($embeddingText, '(?m)^    ''config\.ghostty''\s*= (.*)$').Groups[1].Value
& {
    $Renderer = 'd3d11-warp'
    if ((& ([scriptblock]::Create($embeddingConfig))) -notmatch '(?m)^renderer = d3d11-warp$') { throw 'Embedding negative control config must select its renderer.' }
}

$gitFunctions = (Get-HiddenFunction $profileText 'Get-AvailableGitBash') + "`n" + (Get-HiddenFunction $profileText 'Test-Available')
function Test-GitBashDiscovery([string] $Code) {
    . ([scriptblock]::Create($Code))
    $savedRoot = $env:SystemRoot
    try {
        $env:SystemRoot = 'C:\Windows'
        $fixtures = @(
            @{ Git = 'C:\Custom\cmd\git.exe'; Files = @('C:\Custom\bin\bash.exe'); Expected = 'C:\Custom\bin\bash.exe' }
            @{ Git = 'C:\Custom\bin\git.exe'; Files = @('C:\Custom\bin\bash.exe'); Expected = 'C:\Custom\bin\bash.exe' }
            @{ Git = 'C:\Custom\mingw64\bin\git.exe'; Files = @('C:\Custom\bin\bash.exe'); Expected = 'C:\Custom\bin\bash.exe' }
            @{ Git = 'C:\Custom\ucrt64\bin\git.exe'; Files = @('C:\Custom\bin\bash.exe'); Expected = 'C:\Custom\bin\bash.exe' }
            @{ User = 'C:\PerUser'; Machine = 'C:\Machine'; Files = @('C:\PerUser\bin\bash.exe', 'C:\Machine\bin\bash.exe'); Expected = 'C:\PerUser\bin\bash.exe' }
            @{ User = 'C:\Removed'; Machine = 'C:\Machine'; Files = @('C:\Machine\bin\bash.exe'); Expected = 'C:\Machine\bin\bash.exe' }
            @{ Bash = 'C:\Cygwin\bin\bash.exe'; Expected = 'C:\Cygwin\bin\bash.exe' }
            @{ Bash = 'c:/WINDOWS/Sysnative/bash.exe'; Expected = $null }
            @{ Bash = 'C:\Users\fixture\WindowsApps\bash.exe'; Expected = $null }
            @{ Git = 'C:\Shim\git.exe'; Bash = 'C:\Windows\System32\bash.exe'; Expected = $null }
            @{ Expected = $null }
        )
        foreach ($fixture in $fixtures) {
            function Find-LocalShellOnPath([string] $Name) { if ($Name -eq 'git.exe') { return $fixture.Git }; return $fixture.Bash }
            function Get-GitInstallRoot($Hive) { if ($Hive -eq [Microsoft.Win32.RegistryHive]::CurrentUser) { return $fixture.User }; return $fixture.Machine }
            function Test-LocalShellFile([string] $Path) { return $fixture.Files -icontains $Path }
            if ((Get-AvailableGitBash) -ine $fixture.Expected -or (Test-Available 'git-bash') -ne [bool]$fixture.Expected) { throw 'Git Bash availability disagrees with supported app discovery.' }
        }
    } finally { $env:SystemRoot = $savedRoot }
}
Assert-HiddenMutation 'PATH git install ignored' $gitFunctions ($gitFunctions.Replace("Find-LocalShellOnPath 'git.exe'", '$null')) ${function:Test-GitBashDiscovery}
Assert-HiddenMutation 'per-user Git install ignored' $gitFunctions ($gitFunctions.Replace('[Microsoft.Win32.RegistryHive]::CurrentUser, ', '')) ${function:Test-GitBashDiscovery}
Assert-HiddenMutation 'WSL bash accepted' $gitFunctions ($gitFunctions.Replace('return $null }', 'return $bash }')) ${function:Test-GitBashDiscovery}
# The filesystem probe must reject unsafe shapes before it can query a path.
& {
    . ([scriptblock]::Create((Get-HiddenFunction $profileText 'Test-LocalShellFile')))
    $probes = [Collections.Generic.List[string]]::new()
    function Test-Path { $probes.Add('queried'); return $false }
    foreach ($path in @('\\server\share\bash.exe', '\??\UNC\server\bash.exe', '//server/share/bash.exe', 'relative\bash.exe', 'C:bash.exe')) {
        if (Test-LocalShellFile $path) { throw 'Unsafe Git Bash path was accepted.' }
    }
    if ($probes.Count -ne 0) { throw 'Unsafe Git Bash path reached the filesystem probe.' }
}
& {
    . ([scriptblock]::Create((Get-HiddenFunction $profileText 'Find-LocalShellOnPath')))
    $probes = [Collections.Generic.List[string]]::new()
    function Test-LocalShellFile([string] $Path) { $probes.Add($Path); return $Path -ieq 'C:\PKG76\last\git.exe' }
    $savedPath = $env:PATH
    try {
        $env:PATH = 'relative;\\server\share;"C:\PKG76\bin";C:\PKG76\last'
        if ((Find-LocalShellOnPath 'git.exe') -ine 'C:\PKG76\last\git.exe' -or $probes.Count -ne 2 -or
            $probes[0] -ine 'C:\PKG76\bin\git.exe') { throw 'Local PATH lookup lost quoting/order or queried an unsafe component.' }
    } finally { $env:PATH = $savedPath }
}

# Pin the actual executable workflow line, so a comment or reporting-only invocation cannot pass.
$skipWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\windows10-branches.yml') -Raw
function Test-HiddenWorkflowCoverage([string] $Code) {
    $profileCommand = [regex]::Match($Code, '(?m)^        run: (\./test/windows/hidden-win11-profile-matrix\.ps1[^\r\n]*)$').Groups[1].Value
    $controlCommand = [regex]::Matches($Code, '(?m)^        run: (\./test/windows/hidden-win11-embedding-idle\.ps1[^\r\n]*)$') |
        ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match ' -NegativeControl(?: |$)' }
    if ($profileCommand -notmatch ' -RequireAll(?: |$)' -or @($controlCommand).Count -ne 1 -or $controlCommand -notmatch ' -Renderer d3d11-warp(?: |$)') {
        throw 'Hosted workflow must require all profiles and run the embedding window negative control with WARP.'
    }
    foreach ($exclude in @('!hidden-evidence/**/*.exe', '!hidden-evidence/**/*.dll', '!hidden-evidence/**/*.pdb', '!hidden-evidence/**/share/**')) {
        if ($Code -notmatch ('(?m)^            ' + [regex]::Escape($exclude) + '\r?$')) { throw 'Hidden evidence upload must exclude copied binaries and resources.' }
    }
}
Assert-HiddenMutation 'workflow missing-profile coverage optional' $skipWorkflow ($skipWorkflow.Replace(' -RequireAll', '')) ${function:Test-HiddenWorkflowCoverage}
Assert-HiddenMutation 'workflow embedding negative control lost' $skipWorkflow ($skipWorkflow.Replace(' -NegativeControl', '')) ${function:Test-HiddenWorkflowCoverage}
Assert-HiddenMutation 'workflow binaries uploaded' $skipWorkflow ($skipWorkflow.Replace('!hidden-evidence/**/*.exe', 'hidden-evidence/**/*.exe')) ${function:Test-HiddenWorkflowCoverage}
function Test-SkipWorkflow([string] $Code) {
    $command = [regex]::Match($Code, '(?m)^        run: (\./scripts/check-test-skips\.ps1[^\r\n]*)$').Groups[1].Value
    if ($command -cne './scripts/check-test-skips.ps1 -TestLog ghostty-test.log -Runner windows-2022') { throw 'Windows 2022 workflow must enforce its skip budget.' }
}
Assert-HiddenMutation 'workflow reporting only' $skipWorkflow ($skipWorkflow.Replace('-Runner windows-2022', '-Runner windows-2022 -Report')) ${function:Test-SkipWorkflow}

# The skip budget, run on synthetic output of the test executable.
$skipScript = Join-Path $repoRoot 'scripts\check-test-skips.ps1'
$skipBudget = Join-Path $repoRoot 'test\windows\test-skip-budget.json'
$budget = Get-Content -LiteralPath $skipBudget -Raw | ConvertFrom-Json
if ($budget.schema_version -ne 1 -or -not $budget.familyPrefix) { throw 'test-skip-budget.json lost its schema version or family prefix.' }
if (-not $budget.runners.'windows-2022') { throw 'The enforcing Windows 2022 workflow needs a measured runner budget.' }
foreach ($runner in $budget.runners.PSObject.Properties) {
    $limits = $runner.Value
    if ([int]$limits.maxTotalSkipped -lt @($limits.allowedSkips).Count) {
        throw "Budget for $($runner.Name) has a bad maxTotalSkipped."
    }
    $names = @($limits.allowedSkips)
    if (@($names | Select-Object -Unique).Count -ne $names.Count) { throw "Budget for $($runner.Name) lists a test twice." }
    foreach ($n in $names) {
        if (-not $n.StartsWith($budget.familyPrefix, [StringComparison]::Ordinal)) { throw "Budget for $($runner.Name) lists '$n', outside '$($budget.familyPrefix)'." }
    }
}
$skipTemp = Join-Path ([IO.Path]::GetTempPath()) ('noctty-skip-budget-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $skipTemp | Out-Null
try {
    $fixtureBudget = Join-Path $skipTemp 'budget.json'
    @{
        schema_version = 1; familyPrefix = 'font.'
        runners = @{ r = @{ maxTotalSkipped = 3; allowedSkips = @('font.a.test.allowed skip') } }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fixtureBudget
    function Invoke-SkipFixture([string] $Name, [string[]] $Lines, [string] $Runner = 'r', [switch] $Report) {
        $log = Join-Path $skipTemp "$Name.log"
        Set-Content -LiteralPath $log -Value $Lines
        $reportArguments = @(); if ($Report) { $reportArguments += '-Report' }
        $output = & pwsh -NoProfile -File $skipScript -TestLog $log -Runner $Runner -BudgetFile $fixtureBudget @reportArguments 2>&1 | Out-String
        return @{ Exit = $LASTEXITCODE; Output = $output }
    }
    $okRun = @('1/4 font.a.test.allowed skip...SKIP', '2/4 font.b.test.runs...OK', '3/4 other.test.skips...SKIP', '4/4 font.c.test.runs...OK', '2 passed; 2 skipped; 0 failed.')
    $skipCases = @(
        @{ Name = 'an allowed skip within budget'; Lines = $okRun; Exit = 0; Match = 'PASS' }
        @{ Name = 'a result printed after log output'; Exit = 0; Match = 'PASS'
           Lines = @('1/3 font.a.test.allowed skip...[font] (warn): some log', '[font] (warn): another', 'SKIP', '2/3 font.b.test.runs...OK', '3/3 other.test...OK', '2 passed; 1 skipped; 0 failed.') }
        @{ Name = 'a font test that starts skipping'; Exit = 1; Match = 'not on the .r. allowlist: font\.b\.test\.runs'
           Lines = @('1/3 font.a.test.allowed skip...SKIP', '2/3 font.b.test.runs...SKIP', '3/3 other.test...OK', '1 passed; 2 skipped; 0 failed.') }
        @{ Name = 'a total above the budget'; Exit = 1; Match = '4 tests skipped; the .r. budget is 3'
           Lines = @('1/5 font.a.test.allowed skip...SKIP', '2/5 x.one...SKIP', '3/5 x.two...SKIP', '4/5 x.three...SKIP', '5/5 x.four...OK', '1 passed; 4 skipped; 0 failed.') }
        @{ Name = 'a run that died before its closing line'; Exit = 1; Match = 'did not finish'
           Lines = @('1/4 font.a.test.allowed skip...SKIP', '2/4 font.b.test.runs...OK') }
        @{ Name = 'counts that disagree'; Exit = 1; Match = 'inconsistent'
           Lines = @('1/2 font.b.test.runs...OK', '2/2 font.c.test.runs...OK', '5 passed; 0 skipped; 0 failed.') }
        @{ Name = 'no per-test lines at all'; Exit = 1; Match = 'no per-test lines'
           Lines = @('some other output') }
        @{ Name = 'all tests passed summary'; Exit = 0; Match = 'PASS'; Lines = @('1/1 font.b.test.runs...OK', 'All 1 tests passed.') }
        @{ Name = 'reporting an unknown runner'; Exit = 0; Match = 'font.a.test.allowed skip'; Runner = 'nowhere'; Report = $true; Lines = $okRun }
        @{ Name = 'reporting an incomplete log'; Exit = 1; Match = 'did not finish'; Report = $true; Lines = @('1/2 x...OK') }
        @{ Name = 'reporting malformed counts'; Exit = 1; Match = 'inconsistent'; Report = $true; Lines = @('1/1 x...OK', '2 passed; 0 skipped; 0 failed.') }
        @{ Name = 'reporting without tests'; Exit = 1; Match = 'no per-test lines'; Report = $true; Lines = @('some other output') }
        @{ Name = 'changing announced totals'; Exit = 1; Match = 'announced totals changed'; Lines = @('1/3 x...OK', '2/2 y...OK', 'All 2 tests passed.') }
        @{ Name = 'duplicate test index'; Exit = 1; Match = 'not sequential'; Lines = @('1/2 x...OK', '1/2 y...OK', 'All 2 tests passed.') }
        @{ Name = 'missing test result before header'; Exit = 1; Match = 'no result before'; Lines = @('1/2 x...some log', '2/2 y...OK', 'All 2 tests passed.') }
        @{ Name = 'missing result before summary'; Exit = 1; Match = 'no result before'; Lines = @('1/1 x...some log', 'All 1 tests passed.', 'OK') }
        @{ Name = 'test after summary'; Exit = 1; Match = 'follows the closing'; Lines = @('1/2 x...OK', 'All 2 tests passed.', '2/2 y...OK') }
        @{ Name = 'duplicate summary'; Exit = 1; Match = 'more than one closing'; Lines = @('1/1 x...OK', 'All 1 tests passed.', 'All 1 tests passed.') }
        @{ Name = 'failed test disguised by summary'; Exit = 1; Match = 'Parsed 0 Passed|Parsed 1 Failed'; Lines = @('1/1 x...FAIL (TestUnexpectedResult)', 'All 1 tests passed.') }
        @{ Name = 'complete failed run in report mode'; Exit = 1; Match = 'contains failed tests'; Report = $true; Lines = @('1/1 x...FAIL (TestUnexpectedResult)', '0 passed; 0 skipped; 1 failed.') }
        @{ Name = 'result without pending test'; Exit = 1; Match = 'result without a pending'; Lines = @('1/1 x...OK', 'SKIP', 'All 1 tests passed.') }
        @{ Name = 'malformed extra header'; Exit = 1; Match = 'Malformed per-test header'; Lines = @('1/1 x...OK', '2/1 missing result marker', 'All 1 tests passed.') }
    )
    foreach ($case in $skipCases) {
        $runner = if ($case.Runner) { $case.Runner } else { 'r' }
        $result = Invoke-SkipFixture ($case.Name -replace '\W', '-') $case.Lines -Runner $runner -Report:([bool]$case.Report)
        if ($result.Exit -ne $case.Exit -or $result.Output -notmatch $case.Match) {
            throw "Skip budget fixture '$($case.Name)': expected exit $($case.Exit) matching /$($case.Match)/, got exit $($result.Exit): $($result.Output)"
        }
    }
    $unknown = Invoke-SkipFixture 'unknown-runner' $okRun 'nowhere'
    if ($unknown.Exit -eq 0 -or $unknown.Output -notmatch 'No budget for runner') { throw 'The skip budget accepted a runner it has no entry for.' }
}
finally {
    # The root was made above from the temp directory and a GUID: assert that before a recursive delete.
    if ($skipTemp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $skipTemp) -match '^noctty-skip-budget-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $skipTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Hidden harness and skip budget contracts: $($hiddenContracts.Count) static checks, $script:mutationControls mutation controls, $($skipCases.Count + 1) skip budget fixtures"
