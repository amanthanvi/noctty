<#
.SYNOPSIS
    SETFORM guarded hidden-desktop form validation; uses an already staged build.
.DESCRIPTION
    Reuses #455's runner controller, Native launcher, guard snapshots and fixture
    lifecycle by parsing named functions/blocks. Fails closed if those seams move.
    All children use its explicit lpDesktop + CREATE_NO_WINDOW + owned handles/job.
    No builds, global input, foreground changes, editor invocation or Save occur.
    The separate #455 full operation harness remains REQUIRED for operation,
    disabled HRESULT, dirty-close, Save, surgical persistence and fresh reload.

    Requires the lead's verified measurement AUMID / no-HKCU-registration portable
    stage and SHA-256. OutputDirectory must be NEW and inside wt-setform-run.
    Native GetNextDlgTabItem/GetNextDlgGroupItem check traversal without focusing
    or injecting keys, including both arrow directions at the labeled checkbox.
    Tab traversal starts at the active rail button and covers the entire Settings
    dialog cycle, including enabled footer actions, before filtering form rows.
    Bounded traces retain ordered native steps and root/viewport/anchor state,
    window ownership and NULL-return error codes, without window titles. This
    checks native dialog order; it does not inject Tab or call app accelerators.
    Cue reads use only a fixed remote allocation in the retained fixture process;
    an unconfirmed send stops that exact fixture before buffer reclamation.
    Labeled rows require immediate native STATIC predecessor; other checkboxes
    label themselves through their existing caption. Existing labels/names/IDs
    and section order are deliberately independent of product descriptors.
.EXAMPLE
    ./settings-generated-form-run.ps1 -CompileOnly
.EXAMPLE
    ./settings-generated-form-run.ps1 -PortableExe C:/task/measure-stage/noctty.exe `
        -ExpectedExeSha256 <verified-sha256> `
        -OutputDirectory C:/Users/amant/.t3/worktrees/winghostty/wt-setform-run/generated-01
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $PortableExe,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedExeSha256,
    [string] $OutputDirectory,
    [switch] $CompileOnly,
    [Parameter(DontShow)][string] $WorkerDesktop
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The reused #455 guard controller starts and checks this history guard under this runner's name.
. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$client = Join-Path $PSScriptRoot 'settings-generated-form.ps1'
$SetFormRunner = $PSCommandPath
$existingRunner = Join-Path $PSScriptRoot 'settings-uia-patterns-run.ps1'
& $client -CompileOnly
& $existingRunner -CompileOnly | Out-Null

if (-not ('SetForm.Layout' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace SetForm
{
    public static class Layout
    {
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint relation);
        [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll", EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetNextDlgTabItem(IntPtr dialog, IntPtr control, bool previous);
        [DllImport("user32.dll", SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")] static extern IntPtr GetNextDlgGroupItem(IntPtr dialog, IntPtr control, bool previous);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)]
        static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int length);
        [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")]
        static extern IntPtr ReadText(IntPtr hwnd, uint message, IntPtr w, StringBuilder text,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW", SetLastError=true)]
        static extern IntPtr ReadCue(IntPtr hwnd, uint message, IntPtr text, IntPtr length,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetProcessId(IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr process,
            IntPtr address, UIntPtr bytes, uint allocationType, uint protection);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool VirtualFreeEx(IntPtr process,
            IntPtr address, UIntPtr bytes, uint freeType);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr process,
            IntPtr address, [Out] byte[] buffer, UIntPtr bytes, out UIntPtr bytesRead);
        static string Class(IntPtr hwnd)
        { var text = new StringBuilder(128); GetClassNameW(hwnd, text, text.Capacity); return text.ToString(); }
        static string StaticText(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero || Class(hwnd) != "Static") return null;
            var text = new StringBuilder(4096); IntPtr result;
            if (ReadText(hwnd, 13, (IntPtr)text.Capacity, text, 2, 2000, out result) == IntPtr.Zero)
                throw new InvalidOperationException("Fixture label read timed out");
            return text.ToString();
        }
        public sealed class Row
        {
            public long Hwnd;
            public int Id, Top, Left;
            public string ClassName, PreviousLabel;
            public bool Visible, Enabled, TabStop;
        }
        public static Row[] Rows(IntPtr viewport)
        {
            var result = new List<Row>(); int budget = 256;
            for (IntPtr child = GetWindow(viewport, 5); child != IntPtr.Zero; child = GetWindow(child, 2)) {
                if (--budget == 0) throw new InvalidOperationException("Native child traversal bound exceeded");
                Rect rect; if (!GetWindowRect(child, out rect)) throw new InvalidOperationException("No fixture geometry");
                result.Add(new Row { Hwnd = child.ToInt64(), Id = GetDlgCtrlID(child), Top = rect.Top, Left = rect.Left,
                    ClassName = Class(child), PreviousLabel = StaticText(GetWindow(child, 3)),
                    Visible = IsWindowVisible(child), Enabled = IsWindowEnabled(child),
                    TabStop = (GetWindowLong(child, -16) & 0x10000) != 0 });
            }
            return result.ToArray();
        }
        public sealed class TabStep
        {
            public long Hwnd, Parent, NextHwnd;
            public int Id;
            public uint ThreadId, ProcessId;
            public int? OwnerError, NextError;
            public bool Form, Visible, Enabled, TabStop, NextQueried;
        }
        public sealed class TabTrace
        {
            public TabStep Root, Viewport, Anchor;
            public List<TabStep> Steps = new List<TabStep>();
            public bool Complete, Reverse;
            public int Calls;
            public long ClosureHwnd;
            public string Error;
        }
        static TabStep TabState(IntPtr hwnd, IntPtr viewport)
        {
            var step = new TabStep { Hwnd = hwnd.ToInt64() };
            if (hwnd == IntPtr.Zero) return step;
            uint processId;
            step.ThreadId = GetWindowThreadProcessId(hwnd, out processId);
            if (step.ThreadId == 0) step.OwnerError = Marshal.GetLastWin32Error();
            step.ProcessId = processId;
            IntPtr parent = GetParent(hwnd);
            step.Parent = parent.ToInt64(); step.Form = parent == viewport;
            step.Id = GetDlgCtrlID(hwnd);
            step.Visible = IsWindowVisible(hwnd); step.Enabled = IsWindowEnabled(hwnd);
            step.TabStop = (GetWindowLong(hwnd, -16) & 0x10000) != 0;
            return step;
        }
        public static TabTrace TabOrder(IntPtr dialog, IntPtr viewport, IntPtr start, bool reverse)
        {
            var trace = new TabTrace { Reverse = reverse }; var visited = new HashSet<IntPtr>();
            try {
                // State-only diagnostics: no titles, focus changes or input.
                trace.Root = TabState(dialog, viewport);
                trace.Viewport = TabState(viewport, viewport);
                trace.Anchor = TabState(start, viewport);
                if (dialog == IntPtr.Zero || viewport == IntPtr.Zero || start == IntPtr.Zero ||
                    trace.Viewport.Parent != dialog.ToInt64() || trace.Anchor.Parent != dialog.ToInt64())
                    throw new InvalidOperationException("Tab traversal requires the Settings root, its viewport and a nonzero rail anchor");
                if (!trace.Root.Visible || !trace.Root.Enabled || !trace.Viewport.Visible || !trace.Viewport.Enabled ||
                    trace.Root.ThreadId == 0 || trace.Viewport.ThreadId != trace.Root.ThreadId || trace.Anchor.ThreadId != trace.Root.ThreadId)
                    throw new InvalidOperationException("Tab root/viewport/anchor is unavailable or belongs to a different window thread");
                // GetNextDlgTabItem documents NULL hCtl as failure, not a request
                // for the first control. Keep hDlg at Settings: the control-parent
                // viewport participates in its parent's rail/form/footer cycle.
                IntPtr child = start;
                for (int i = 0; i < 256; i++) {
                    if (child == IntPtr.Zero)
                        throw new InvalidOperationException("GetNextDlgTabItem returned NULL before returning to the rail anchor");
                    if (!visited.Add(child)) {
                        trace.ClosureHwnd = child.ToInt64();
                        if (child != start)
                            throw new InvalidOperationException("Dialog tab traversal cycled without returning to the rail anchor");
                        trace.Complete = true;
                        return trace;
                    }
                    var step = TabState(child, viewport);
                    trace.Steps.Add(step);
                    if ((step.Parent != dialog.ToInt64() && step.Parent != viewport.ToInt64()) ||
                        step.ThreadId != trace.Root.ThreadId || step.ProcessId != trace.Root.ProcessId)
                        throw new InvalidOperationException("Dialog tab traversal escaped the Settings rail/form/footer");
                    if (!step.Visible || !step.Enabled || !step.TabStop)
                        throw new InvalidOperationException("Tab visits a hidden, disabled or non-tab-stop control");
                    child = GetNextDlgTabItem(dialog, child, reverse);
                    step.NextQueried = true; step.NextHwnd = child.ToInt64(); trace.Calls++;
                    if (child == IntPtr.Zero) step.NextError = Marshal.GetLastWin32Error();
                }
                throw new InvalidOperationException("Dialog tab traversal failed to cycle within 256 steps");
            } catch (Exception failure) {
                // Preserve every partial observation for the caller's receipt.
                trace.Error = failure.Message;
                return trace;
            }
        }
        public static long Prose(IntPtr viewport, string marker)
        {
            long found = 0;
            foreach (var row in Rows(viewport)) {
                if (!row.Visible || row.ClassName != "Static") continue;
                string text = StaticText((IntPtr)row.Hwnd);
                if (text != null && text.Contains(marker)) {
                    if (found != 0) throw new InvalidOperationException("Ambiguous fixture prose row");
                    found = row.Hwnd;
                }
            }
            if (found == 0) throw new InvalidOperationException("Read-only fixture prose row missing");
            return found;
        }
        public static int ArrowTarget(IntPtr dialog, IntPtr viewport, IntPtr control, bool reverse)
        {
            IntPtr target = GetNextDlgGroupItem(dialog, control, reverse);
            if (target == IntPtr.Zero || GetParent(target) != viewport ||
                !IsWindowVisible(target) || !IsWindowEnabled(target) ||
                (GetWindowLong(target, -16) & 0x10000) == 0 || Class(target) == "Static")
                throw new InvalidOperationException("Labeled checkbox arrow traversal visits a label, hidden/disabled control or escapes the form");
            return GetDlgCtrlID(target);
        }
        public sealed class CueRead
        {
            public int ControlId;
            public long GetterResult;
            public uint ProcessId, ThreadId;
            public bool GetterSucceeded, AllocationFreed;
            public string Text;
        }
        static uint CueOwner(IntPtr edit, IntPtr process, uint expectedPid)
        {
            if (process == IntPtr.Zero || expectedPid == 0 || GetProcessId(process) != expectedPid ||
                WaitForSingleObject(process, 0) != 258)
                throw new InvalidOperationException("Cue read requires the retained live owned fixture handle");
            uint owner;
            uint thread = GetWindowThreadProcessId(edit, out owner);
            if (thread == 0 || owner != expectedPid || Class(edit) != "Edit")
                throw new InvalidOperationException("Cue edit does not belong to the retained fixture process");
            return thread;
        }
        public static CueRead Cue(IntPtr edit, IntPtr process, uint expectedPid)
        {
            const int characters = 256, bytes = characters * 2;
            var observed = new CueRead { ControlId = GetDlgCtrlID(edit), ProcessId = expectedPid,
                ThreadId = CueOwner(edit, process, expectedPid) };
            // EM_GETCUEBANNER is above WM_USER: user32 does not marshal wParam.
            // The only remotely read memory is this new zero-initialized buffer.
            IntPtr remote = VirtualAllocEx(process, IntPtr.Zero, new UIntPtr((uint)bytes), 0x3000, 0x04);
            if (remote == IntPtr.Zero)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Cue VirtualAllocEx");
            bool sendAttempted = false, sendCompleted = false;
            try {
                CueOwner(edit, process, expectedPid);
                IntPtr result;
                sendAttempted = true;
                IntPtr sent = ReadCue(edit, 0x1502, remote, (IntPtr)characters,
                    0x23, 2000, out result); // BLOCK | ABORTIFHUNG | ERRORONEXIT
                int sendError = Marshal.GetLastWin32Error();
                sendCompleted = sent != IntPtr.Zero;
                if (!sendCompleted)
                    throw new System.ComponentModel.Win32Exception(sendError, "Cue SendMessageTimeoutW error=" + sendError);
                CueOwner(edit, process, expectedPid);
                var buffer = new byte[bytes]; UIntPtr read;
                if (!ReadProcessMemory(process, remote, buffer, new UIntPtr((uint)bytes), out read))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Cue ReadProcessMemory owned buffer");
                if (read.ToUInt64() != (ulong)bytes)
                    throw new InvalidOperationException("Cue owned-buffer read was incomplete");
                int end = 0;
                while (end < bytes && (buffer[end] != 0 || buffer[end + 1] != 0)) end += 2;
                if (end == bytes) throw new InvalidOperationException("Cue exceeded the fixed buffer or lacked its terminator");
                observed.GetterSucceeded = result != IntPtr.Zero;
                observed.GetterResult = result.ToInt64();
                observed.Text = Encoding.Unicode.GetString(buffer, 0, end);
                if (!observed.GetterSucceeded && observed.Text.Length != 0)
                    throw new InvalidOperationException("Failed cue getter returned inconsistent nonempty text");
                return observed;
            } finally {
                uint state = WaitForSingleObject(process, 0);
                if (sendAttempted && !sendCompleted && state == 258) {
                    // A timed-out send may still be processing its pointer.
                    // Retire this exact retained fixture before reclamation;
                    // never free live storage that the receiver may still use.
                    if (GetProcessId(process) != expectedPid || !TerminateProcess(process, 1))
                        throw new InvalidOperationException("Cue send failed; owned fixture could not be stopped. Allocation retained for outer cleanup");
                    state = WaitForSingleObject(process, 5000);
                }
                if (state == 0) {
                    observed.AllocationFreed = true; // Process exit reclaimed it.
                } else if (state != 258 || (sendAttempted && !sendCompleted)) {
                    throw new InvalidOperationException("Cue cleanup could not confirm fixture quiescence. Allocation retained for outer cleanup");
                } else {
                    if (!VirtualFreeEx(process, remote, UIntPtr.Zero, 0x8000)) // MEM_RELEASE, exact allocation
                        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Cue VirtualFreeEx");
                    observed.AllocationFreed = true;
                }
            }
        }
    }
}
'@
}

# Import only existing named helpers. No existing runner top-level runtime code
# executes here; CompileOnly above only compiles its interop/client.
$tokens = $null; $errors = $null
$runnerAst = [Management.Automation.Language.Parser]::ParseFile($existingRunner, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'The #455 runner does not parse.' }
foreach ($name in @('Write-Json', 'Assert-Contract', 'Wait-For', 'Ctl', 'Click', 'Get-GuardSnapshot',
        'Assert-ClipboardGuard', 'Start-Fixture', 'Stop-Fixture')) {
    $definitions = @($runnerAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true))
    if ($definitions.Count -ne 1) { throw "Expected exactly one #455 function: $name" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$controllers = @($runnerAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -ceq '-not $WorkerDesktop'
})
Assert-Contract ($controllers.Count -eq 1) 'Expected exactly one #455 guard controller.'
if ($CompileOnly) {
    'SETFORM + reused #455 client/launcher/guards: compile-only PASS; runtime NOT RUN'
    return
}
Assert-Contract ([bool]$PortableExe -and [bool]$ExpectedExeSha256 -and [bool]$OutputDirectory) `
    'PortableExe, verified ExpectedExeSha256 and a NEW OutputDirectory are required.'
$scratchRoot = 'C:\Users\amant\.t3\worktrees\winghostty\wt-setform-run\'
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
Assert-Contract ($OutputDirectory.StartsWith($scratchRoot, [StringComparison]::OrdinalIgnoreCase)) `
    'OutputDirectory must be a new child of wt-setform-run.'
if (-not $WorkerDesktop) {
    # Preserve the guard controller; redirect ONLY its self-launch to this runner.
    $controller = $controllers[0].Extent.Text
    Assert-Contract ($controller.Contains('$PSCommandPath')) 'The #455 self-launch seam moved.'
    $controller = $controller.Replace('$PSCommandPath', '$SetFormRunner')
    & ([scriptblock]::Create($controller)) | Out-Null
    $summary = Get-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Raw | ConvertFrom-Json
    Assert-Contract $summary.pass 'SETFORM worker or real-profile guard failed; inspect retained artifacts.'
    'SETFORM PASS: 26 editable projections + 2 editor rows + 2 read-only prose rows; native order and UIA verified.'
    return
}

[Set91.Native]::AssertDesktop([IntPtr]::Zero, $WorkerDesktop)
[void][Set91.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
Assert-Contract ((Get-FileHash -LiteralPath $PortableExe).Hash -eq $ExpectedExeSha256) 'Worker exe identity mismatch.'
Assert-Contract ($env:LOCALAPPDATA -eq (Join-Path $OutputDirectory 'local')) 'Worker LOCALAPPDATA mismatch.'
Assert-Contract ($env:APPDATA -eq (Join-Path $OutputDirectory 'roam')) 'Worker APPDATA mismatch.'
$fixture = Split-Path -Parent $PortableExe
$config = Join-Path $fixture 'config.ghostty'
$clip = [Set91.Native]::GetClipboardSequenceNumber()
$batchInput = [Set91.Native]::ReadInput()
$clipObserved = $clip
$process = $null; $settings = [IntPtr]::Zero; $hostWindow = [IntPtr]::Zero
$cleanupFailed = $false
$clippedChecks = 0; $visibleChecks = 0; $cueChecks = 0; $absentCueChecks = 0
$results = [Collections.Generic.List[object]]::new()

# Frozen independent native/UIA compatibility expectations from main 09b79314d.
# Section, ID, kind, accessible name, immediately preceding label (null for
# self-captioned checkbox), saved-apply policy. These are NOT read from Zig.
$cases = @(
    @(201, 412, 'Edit', 'Font family fallbacks', 'Font family fallbacks (comma-separated)', 'save'),
    @(201, 402, 'Edit', 'Font size', 'Font size (pt)', 'save'),
    @(201, 413, 'Edit', 'Terminal theme', 'Terminal theme name, absolute path, or light/dark pair', 'save'),
    @(201, 408, 'Edit', 'Background opacity', 'Background opacity (0.0 .. 1.0)', 'save'),
    @(201, 405, 'ComboBox', 'Window theme', 'Window theme', 'save'),
    @(201, 409, 'ComboBox', 'Cursor style', 'Cursor style', 'save'),
    @(201, 415, 'Edit', 'Window padding X', 'Window padding X (left/right or single value)', 'new terminal'),
    @(201, 416, 'Edit', 'Window padding Y', 'Window padding Y (top/bottom or single value)', 'new terminal'),
    @(201, 411, 'ComboBox', 'Window padding balance', 'Window padding balance', 'new terminal'),
    @(201, 426, 'CheckBox', 'Follow Windows accent color', $null, 'save'),
    @(201, 410, 'CheckBox', 'Background blur (not supported on Windows)', $null, 'save'),
    @(202, 401, 'Edit', 'Scrollback limit', 'Scrollback limit (bytes; 0 = off; new terminals only)', 'new terminal'),
    @(202, 403, 'ComboBox', 'Close confirmation', 'Close confirmation', 'save'),
    @(202, 404, 'ComboBox', 'Copy on select', 'Copy on select', 'save'),
    @(202, 407, 'CheckBox', 'Clipboard trimming', $null, 'save'),
    @(203, 414, 'Edit', 'Default command', 'Default command (blank = auto-detect)', 'new terminal'),
    @(203, 406, 'ComboBox', 'Shell integration', 'Shell integration', 'new terminal'),
    @(206, 422, 'ComboBox', 'OSC 52 clipboard read requests', 'OSC 52 clipboard read requests', 'save'),
    @(206, 423, 'ComboBox', 'OSC 52 clipboard write requests', 'OSC 52 clipboard write requests', 'save'),
    @(206, 424, 'ComboBox', 'Clickable URL opening', 'Clickable URL opening', 'save'),
    @(206, 425, 'ComboBox', 'Link preview popups (not supported on Windows)', 'Link preview popups (not supported on Windows)', 'save'),
    @(206, 417, 'CheckBox', 'Terminal notifications', 'Notifications', 'save'),
    @(206, 418, 'CheckBox', 'Clipboard-copy notification', $null, 'save'),
    @(206, 419, 'CheckBox', 'Config-reload notification', $null, 'save'),
    @(207, 420, 'ComboBox', 'Auto-update mode', 'Auto-update mode', 'save'),
    @(207, 421, 'ComboBox', 'Auto-update channel', 'Auto-update channel', 'save'),
    @(204, 302, 'Button', 'Keybind configuration', 'Keybind configuration', $null),
    @(205, 101, 'Button', 'Full config editor', 'Full config editor', $null)
)
$ownedCues = @{ 412 = 'Default font'; 413 = 'Default theme'; 414 = 'Automatic shell'; 401 = '' }
# Check meaning-bearing unit/range promises without freezing the whole sentence.
$helpPromises = @{
    401 = @('bytes', 'zero|0', 'positive integer')
    402 = @('pt|points', '6\s*\.\.\s*72')
    408 = @('opacity', '0\s*\.\.\s*1', 'visibility floor')
    415 = @('pt|points', '0\s*\.\.\s*200', 'pair')
    416 = @('pt|points', '0\s*\.\.\s*200', 'pair')
    412 = @('comma', 'default')
    413 = @('absolute path', 'light/dark', 'default')
    414 = @('automatic.*shell|shell.*detect|detect.*shell')
}
Assert-Contract ($cases.Count -eq 28 -and @($cases | Where-Object { $_[2] -ne 'Button' }).Count -eq 26) `
    'Independent projection manifest is incomplete.'
function Read-Probe([IntPtr] $Handle, [string] $Kind, [string] $Name, [string] $Tag) {
    Assert-ClipboardGuard
    [Set91.Native]::AssertDesktop($Handle, $WorkerDesktop)
    $path = Join-Path $OutputDirectory "$Tag.json"
    $argsForClient = @('-NoProfile', '-NonInteractive', '-File', $client,
        '-Hwnd', $Handle.ToInt64().ToString(), '-Desktop', $WorkerDesktop,
        '-Kind', $Kind, '-OutputPath', $path)
    if ($Name) { $argsForClient += @('-ExpectedName', $Name) }
    $probe = [Set91.Native]::Launch((Join-Path $PSHOME 'pwsh.exe'), $argsForClient,
        $WorkerDesktop, $OutputDirectory, [IntPtr]::Zero)
    try {
        Assert-Contract ([Set91.Native]::WaitForSingleObject($probe.Handle, 45000) -eq 0) 'SETFORM UIA client timed out.'
        Assert-Contract (Test-Path -LiteralPath $path) 'SETFORM UIA client produced no artifact.'
        $observed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-Contract (($probe.ExitCode() -eq 0) -eq [bool]$observed.pass) 'Client exit/result mismatch.'
        Assert-Contract $observed.pass "UIA contract failed: $Tag"
        return $observed
    } finally { $probe.Dispose() }
}
try {
    $seed = @('# SETFORM unrelated sentinel must remain byte-for-byte', 'font-size = 12',
        'command = cmd.exe /d /q', 'renderer = d3d11', 'window-save-state = never',
        'confirm-close-surface = false', 'auto-update = off', 'auto-update-channel = tip',
        'desktop-notifications = false', 'app-notifications = no-clipboard-copy,no-config-reload',
        'copy-on-select = false', 'clipboard-read = deny', 'clipboard-write = deny',
        'windows-job-object-kill-on-close = true', 'keybind = f9=open_config') -join "`n"
    [IO.File]::WriteAllText($config, $seed + "`n", [Text.UTF8Encoding]::new($false))
    $configHash = (Get-FileHash -LiteralPath $config).Hash
    Start-Fixture
    $viewport = [Set91.Native]::Child($settings, -1, 'noctty.win32.settings.viewport')
    Assert-Contract ($viewport -ne [IntPtr]::Zero) 'Missing Settings viewport.'
    [Set91.Native]::AssertDesktop($viewport, $WorkerDesktop)
    foreach ($section in @(201, 202, 203, 206, 207, 204, 205)) {
        $record = [ordered]@{ section = $section; pass = $false }
        try {
            Click (Ctl $settings $section)
            [void][Set91.Native]::Send($viewport, 0x115, 6, 0) # SB_TOP
            $sectionCases = @($cases | Where-Object { $_[0] -eq $section })
            $rows = @([SetForm.Layout]::Rows($viewport))
            Write-Json (Join-Path $OutputDirectory "section-$section-native.json") $rows
            $visual = @($rows | Where-Object { $_.Visible -and $_.TabStop } | Sort-Object Top, Left)
            Assert-Contract (($visual.Id -join ',') -ceq (($sectionCases | ForEach-Object { $_[1] }) -join ',')) `
                "Visible controls differ from the frozen section order: $section"
            $enabledIds = @($visual | Where-Object Enabled | ForEach-Object Id)
            $rootRows = @([SetForm.Layout]::Rows($settings))
            Write-Json (Join-Path $OutputDirectory "section-$section-dialog-native.json") $rootRows
            $rootTabRows = @($rootRows | Where-Object { $_.Visible -and $_.Enabled -and $_.TabStop })
            $railIds = @($rootTabRows | Where-Object { $_.Id -in 201..207 } | ForEach-Object Id)
            # Fixed footer IDs/order, filtered by current native eligibility.
            # Inspection keeps Save disabled; hidden/disabled actions must never
            # be visited. Including eligible actions preserves the real cycle.
            $footerOrder = @(303, 304, 307, 301, 305, 306, 2)
            $footerIds = @($rootTabRows | Where-Object { $_.Id -in $footerOrder } | Sort-Object Top, Left | ForEach-Object Id)
            $expectedFooterIds = @($footerOrder | Where-Object { $_ -in $footerIds })
            $anchor = Ctl $settings $section
            $forwardTrace = [SetForm.Layout]::TabOrder($settings, $viewport, $anchor, $false)
            Write-Json (Join-Path $OutputDirectory "section-$section-tab-forward.json") $forwardTrace
            $record.forwardGlobalTabIds = @($forwardTrace.Steps | ForEach-Object Id)
            $reverseTrace = [SetForm.Layout]::TabOrder($settings, $viewport, $anchor, $true)
            Write-Json (Join-Path $OutputDirectory "section-$section-tab-reverse.json") $reverseTrace
            $record.reverseGlobalTabIds = @($reverseTrace.Steps | ForEach-Object Id)
            # Retain both directions before rejecting either one; failures are
            # diagnostics, never accepted as empty or partial successful walks.
            Assert-Contract $forwardTrace.Complete "Forward tab traversal failed: $($forwardTrace.Error)"
            Assert-Contract $reverseTrace.Complete "Reverse tab traversal failed: $($reverseTrace.Error)"
            Assert-Contract (($railIds -join ',') -ceq [string]$section) "Active section must be the rail's only tab stop: $section"
            Assert-Contract (($footerIds -join ',') -ceq ($expectedFooterIds -join ',')) "Footer visual order changed: $section"
            $forward = @($forwardTrace.Steps | Where-Object Form | ForEach-Object Id)
            $reverse = @($reverseTrace.Steps | Where-Object Form | ForEach-Object Id)
            $reversedIds = @($enabledIds); [array]::Reverse($reversedIds)
            $record.forwardTabIds = $forward; $record.reverseTabIds = $reverse
            Assert-Contract (($forward -join ',') -ceq ($enabledIds -join ',')) "Tab order differs from visual order: $section"
            Assert-Contract (($reverse -join ',') -ceq ($reversedIds -join ',')) "Reverse Tab order differs from visual order: $section"
            $tailIds = @($enabledIds) + @($footerIds)
            $expectedGlobal = @($section) + $tailIds
            [array]::Reverse($tailIds)
            $expectedReverseGlobal = @($section) + $tailIds
            Assert-Contract (($record.forwardGlobalTabIds -join ',') -ceq ($expectedGlobal -join ',')) `
                "Forward tab traversal differs from rail/form/footer order: $section"
            Assert-Contract (($record.reverseGlobalTabIds -join ',') -ceq ($expectedReverseGlobal -join ',')) `
                "Reverse tab traversal differs from rail/footer/form order: $section"
            if ($section -eq 206) {
                # ID 417 has an immediately preceding STATIC Notifications label.
                # The native dialog-manager query catches a label being eligible
                # for arrows even when Tab order and label adjacency both pass.
                $labeledCheckbox = Ctl $settings 417
                $arrowPrevious = [SetForm.Layout]::ArrowTarget($settings, $viewport, $labeledCheckbox, $true)
                $arrowNext = [SetForm.Layout]::ArrowTarget($settings, $viewport, $labeledCheckbox, $false)
                $record.labeledCheckboxArrowIds = @($arrowPrevious, $arrowNext)
                Assert-Contract ($arrowPrevious -in $enabledIds -and $arrowNext -in $enabledIds) `
                    'Labeled checkbox arrow traversal leaves the enabled Privacy form rows.'
            }
            foreach ($case in $sectionCases) {
                $row = @($rows | Where-Object Id -eq $case[1])
                Assert-Contract ($row.Count -eq 1) "Missing or duplicate native control $($case[1])"
                if ($null -ne $case[4]) {
                    Assert-Contract ($row[0].PreviousLabel -ceq $case[4]) "Label is not the immediate native predecessor of $($case[1])"
                }
                $hwnd = Ctl $settings $case[1]
                if ($ownedCues.ContainsKey($case[1])) {
                    [Set91.Native]::AssertDesktop($hwnd, $WorkerDesktop)
                    $cue = [SetForm.Layout]::Cue($hwnd, $process.Handle, [uint32]$process.Pid)
                    Write-Json (Join-Path $OutputDirectory "control-$($case[1])-cue.json") $cue
                    Assert-Contract $cue.AllocationFreed "Owned cue buffer was not reclaimed: $($case[1])"
                    if ($ownedCues[$case[1]].Length -gt 0) {
                        Assert-Contract $cue.GetterSucceeded "Owned edit cue getter failed: $($case[1])"
                    }
                    # Preserve FALSE separately from the text observation; it
                    # never satisfies a positive cue expectation. Edit 401 must
                    # leave the completed read's owned buffer empty.
                    Assert-Contract ($cue.Text -ceq $ownedCues[$case[1]]) "Owned edit cue missing, unexpected or changed: $($case[1])"
                    $cueChecks++
                    if ($case[1] -eq 401) { $absentCueChecks++ }
                }
                $disabled = $case[1] -in 410, 425
                Assert-Contract ([Set91.Native]::IsWindowEnabled($hwnd) -eq (-not $disabled)) "Wrong native enablement: $($case[1])"
                [void][Set91.Native]::Send($viewport, 0x115, 6, 0)
                if ([Set91.Native]::FullyClipped($hwnd, $viewport)) {
                    $clipped = Read-Probe $hwnd $case[2] $case[3] "control-$($case[1])-clipped"
                    Assert-Contract ([bool]$clipped.offscreen) "Fully clipped control reports on-screen: $($case[1])"
                    $clippedChecks++
                }
                for ($step = 0; $step -lt 100 -and [Set91.Native]::FullyClipped($hwnd, $viewport); $step++) {
                    [void][Set91.Native]::Send($viewport, 0x115, 1, 0)
                }
                Assert-Contract (-not [Set91.Native]::FullyClipped($hwnd, $viewport)) "Could not reveal control $($case[1])"
                $observed = Read-Probe $hwnd $case[2] $case[3] "control-$($case[1])-visible"
                Assert-Contract (-not $observed.offscreen) "Visible control reports offscreen: $($case[1])"
                Assert-Contract ([bool]$observed.enabled -eq (-not $disabled)) "UIA enablement differs: $($case[1])"
                if ($case[2] -ne 'Button') {
                    Assert-Contract (-not [string]::IsNullOrWhiteSpace([string]$observed.helpText)) "Descriptor HelpText missing: $($case[1])"
                    Assert-Contract ($observed.helpText.Length -gt 30) "Descriptor HelpText lacks field explanation: $($case[1])"
                    if ($disabled) {
                        Assert-Contract ($observed.helpText -match 'not supported on Windows') "Unsupported reason absent from HelpText: $($case[1])"
                    } else {
                        Assert-Contract ($observed.helpText -match [regex]::Escape($case[5])) "Saved-apply policy absent from HelpText: $($case[1])"
                    }
                    if ($helpPromises.ContainsKey($case[1])) {
                        foreach ($promise in $helpPromises[$case[1]]) {
                            Assert-Contract ($observed.helpText -match $promise) "Unit/range/help promise absent: $($case[1]) / $promise"
                        }
                    }
                }
                $visibleChecks++
            }
            if ($section -in 204, 205) {
                $marker = if ($section -eq 204) { 'Commands to run in a terminal:' } else { 'Settings saves to ' }
                $textHwnd = [IntPtr][SetForm.Layout]::Prose($viewport, $marker)
                [void][Set91.Native]::Send($viewport, 0x115, 6, 0)
                $prose = Read-Probe $textHwnd 'Text' '' "section-$section-prose"
                $promises = if ($section -eq 204) {
                    @('Commands to run in a terminal:', '+explain-config --keybind=<action>', '+list-actions --docs',
                        '+list-keybinds --default', '+list-keybinds --docs', 'keybind = ctrl+shift+c=copy_to_clipboard',
                        'keybind = ctrl+a>n=new_window', 'keybind = chain=goto_split:left')
                } else { @('Settings saves to ', 'No problems were found when the config was last loaded.', 'No changes waiting to be saved.') }
                foreach ($promise in $promises) {
                    Assert-Contract ($prose.name.Contains($promise)) "Read-only help promise lost: section $section"
                }
                Assert-Contract (-not $prose.offscreen) "Visible prose reports offscreen: $section"
                $record.readOnlyProse = $true
            }
            Assert-Contract (-not [Set91.Native]::IsWindowEnabled((Ctl $settings 301))) 'Inspection dirtied pending config.'
            Assert-Contract ((Get-FileHash -LiteralPath $config).Hash -ceq $configHash) 'Inspection wrote portable config.'
            $record.pass = $true
        } catch { $record.error = $_.Exception.Message; throw }
        finally {
            $results.Add($record)
            Write-Json (Join-Path $OutputDirectory 'form-cases.json') @($results.ToArray())
        }
        Assert-ClipboardGuard
    }
    Assert-Contract ($clippedChecks -gt 0) 'No fully clipped control observed; clipping coverage is absent.'
    Assert-Contract ($visibleChecks -eq 28) 'Incomplete form control coverage.'
    Assert-Contract ($cueChecks -eq 4 -and $absentCueChecks -eq 1) 'Incomplete positive/absent owned edit cue coverage.'
} finally {
    try { Stop-Fixture }
    finally {
        Write-Json (Join-Path $OutputDirectory 'form-coverage.json') ([ordered]@{
            expectedEditableProjections = 26; expectedEditorRows = 2; expectedReadOnlyProseRows = 2
            visibleControlChecks = $visibleChecks; clippedControlChecks = $clippedChecks
            expectedCueChecks = 4; cueChecks = $cueChecks; absentCueChecks = $absentCueChecks
            completedSections = $results.Count; passedSections = @($results | Where-Object { $_.pass }).Count
            separate455OperationHarnessRequired = $true
            runtimeScope = 'read-only patterns, native ordering, native tab/arrow traversal, clipping, prose promises'
        })
    }
}
