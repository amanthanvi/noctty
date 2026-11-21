. (Join-Path $PSScriptRoot 'interactive-win11-measure-lib.ps1')

# ---- Hosted mode: the hidden-desktop GUI suite (its runner is gui-hidden-runner.ps1 beside the leaves; interactive
# offload PR 1). The runner is named without its path on purpose: ci-scripts.ps1 follows any path-shaped name in a
# file, and this library is read by jobs (the portable smoke) that never run the runner.
# NOCTTY_GUI_HIDDEN_DESKTOP selects it. The runner sets it to the private desktop it created for this leaf,
# `<station>\<desktop>`, with NOCTTY_GUI_HIDDEN_EXE (the leaf's portable copy of the receipt-bound measurement build)
# and NOCTTY_GUI_HIDDEN_RUN (the leaf's run directory). On the default route nothing below compiles or runs.
# NOCTTY_GUI_LAUNCH_POLICY is reserved for the visible core (PR 6); any value refuses here, so a typo cannot fall back.

# The staged app's and CLI's identities, read once per leaf process after both files' SHA-256 match the hashes the
# runner staged them against (<run>\staged.json): every later launch compares identity only, never re-hashing.
function Initialize-InteractiveWin11HostedIdentity {
    if (-not $env:NOCTTY_GUI_HIDDEN_EXE -or -not $env:NOCTTY_GUI_HIDDEN_RUN) {
        throw 'gui-hidden: NOCTTY_GUI_HIDDEN_EXE and NOCTTY_GUI_HIDDEN_RUN must be set with NOCTTY_GUI_HIDDEN_DESKTOP.'
    }
    $staged = [IO.File]::ReadAllText((Join-Path $env:NOCTTY_GUI_HIDDEN_RUN 'staged.json')) | ConvertFrom-Json
    $dir = Split-Path -Parent $env:NOCTTY_GUI_HIDDEN_EXE
    $identity = @{}
    foreach ($entry in @(@{ Key = 'app'; File = 'noctty.exe'; Hash = [string]$staged.exeSha256 }, @{ Key = 'cli'; File = 'noctty.com'; Hash = [string]$staged.cliSha256 })) {
        $path = Join-Path $dir $entry.File
        $before = [InteractiveWin11HostedLaunch]::Identity($path)
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $after = [InteractiveWin11HostedLaunch]::Identity($path)
        if (-not $entry.Hash -or -not [string]::Equals($hash, $entry.Hash, [StringComparison]::Ordinal)) {
            throw "gui-hidden: the staged $($entry.File) is not the receipt's build."
        }
        if (-not $before -or -not [string]::Equals($before, $after, [StringComparison]::Ordinal)) {
            throw "gui-hidden: the staged $($entry.File) changed while it was hashed."
        }
        $identity[$entry.Key] = [pscustomobject]@{ Path = [IO.Path]::GetFullPath($path); Identity = $before }
    }
    return $identity
}

# The leaf's run token: 32 hex digits the runner draws fresh for every leaf it runs (<run>\staged.json). The leaf's
# sandbox lives under its run directory by it and every noctty class it names ends in it, so no two runs, nor a run
# and the legacy route, share a sandbox, a state file or an IPC pipe (`\\.\pipe\noctty.<class>`; ipc_server.zig).
function Get-InteractiveWin11HostedRunToken {
    if (-not $env:NOCTTY_GUI_HIDDEN_RUN) { throw 'gui-hidden: NOCTTY_GUI_HIDDEN_RUN is not set.' }
    $staged = [IO.File]::ReadAllText((Join-Path $env:NOCTTY_GUI_HIDDEN_RUN 'staged.json')) | ConvertFrom-Json
    $token = [string]$staged.runToken
    if ($token -cnotmatch '\A[0-9a-f]{32}\z') { throw 'gui-hidden: the run has no run token.' }
    return $token
}

# The argument rule every hosted noctty launch keeps, checked on the arguments before the launch and on the command
# line read back from the started process (and by the runner on every noctty its job gains): null when the
# arguments may run, else why not. Arguments after `-e` belong to the command and are not read.
# - No `--config-file`, `--config-default-files` or `--gtk-single-instance`: each could set what the rest checks.
# - Every `--class=` value ends in `-<token>`. An app launch, and any action but the local ones, names one: without
#   it the default class's pipe is the product's, which a real noctty serves.
# - An app launch states `--single-instance=` explicitly, its last value `false` or `true` (`true` only for the IPC
#   leaves, whose class keeps their pipe to their own run).
function Get-InteractiveWin11HostedArgumentRefusal {
    param([AllowEmptyCollection()] [string[]] $Arguments = @(), [AllowEmptyString()] [string] $Token = '')

    if ($Token -cnotmatch '\A[0-9a-f]{32}\z') { return 'no run token' }
    # The non-IPC actions a hosted launch may name without a class: each prints and exits, opening no pipe.
    $localActions = @('+help', '+version', '+list-keybinds', '+list-colors', '+list-themes', '+vt-probe')
    $actions = [System.Collections.Generic.List[string]]::new()
    $classes = [System.Collections.Generic.List[string]]::new()
    $single = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $Arguments) {
        if ($null -eq $argument) { return 'a null argument' }
        if ([string]::Equals($argument, '-e', [StringComparison]::Ordinal)) { break }
        if ($argument.StartsWith('+', [StringComparison]::Ordinal)) { $actions.Add($argument); continue }
        if ($argument -cmatch '\A--(config-file|config-default-files|gtk-single-instance)(=|\z)') { return "it names --$($Matches[1])" }
        if ($argument.StartsWith('--class=', [StringComparison]::Ordinal)) { $classes.Add($argument.Substring(8)); continue }
        if ($argument.StartsWith('--single-instance=', [StringComparison]::Ordinal)) { $single.Add($argument.Substring(18)); continue }
        if ($argument -cmatch '\A--(class|single-instance)\z') { return "a bare --$($Matches[1])" }
    }
    if ($actions.Count -gt 1) { return 'more than one action' }
    foreach ($class in $classes) {
        if (-not $class.EndsWith("-$Token", [StringComparison]::Ordinal)) { return 'a --class without this run''s token' }
    }
    if ($actions.Count -eq 1 -and $actions[0] -cin $localActions) { return $null }
    if ($classes.Count -eq 0) { return 'no --class with this run''s token' }
    if ($actions.Count -eq 0) {
        if ($single.Count -eq 0) { return 'no explicit --single-instance' }
        if ($single[$single.Count - 1] -cnotin @('false', 'true')) { return '--single-instance is neither false nor true' }
    }
    return $null
}

# The launcher's per-launch check: null when `FilePath` may start with `ArgumentList`, else why not (design §4.2
# "Each launch, cheaply"). -FileOnly checks the staged file alone, for the existence check before any launch.
function Get-InteractiveWin11HostedLaunchRefusal {
    param([Parameter(Mandatory)] [string] $FilePath, [AllowEmptyCollection()] [string[]] $ArgumentList = @(), [switch] $FileOnly)

    if (-not $env:NOCTTY_GUI_HIDDEN_DESKTOP) { return 'not in hosted mode' }
    if ($env:NOCTTY_INTERACTIVE_MEASURE_AUMID -ne '1') { return 'measurement mode not set' }
    if ($null -eq $script:InteractiveWin11HostedIdentity) { return 'no staged identity' }
    $full = [IO.Path]::GetFullPath($FilePath)
    $match = @($script:InteractiveWin11HostedIdentity.Values | Where-Object { Test-InteractiveWin11SamePath $_.Path $full })
    if ($match.Count -ne 1) { return 'not the staged app or CLI' }
    $dir = Split-Path -Parent $full
    if (-not [IO.File]::Exists((Join-Path $dir 'noctty.portable'))) { return 'not a portable copy' }
    if ([IO.File]::Exists((Join-Path $dir 'noctty.ico'))) { return 'carries noctty.ico' }
    $now = [InteractiveWin11HostedLaunch]::Identity($full)
    if (-not $now -or -not [string]::Equals($now, $match[0].Identity, [StringComparison]::Ordinal)) { return 'changed since staging' }
    if ($FileOnly) { return $null }
    $argumentRefusal = Get-InteractiveWin11HostedArgumentRefusal -Arguments $ArgumentList -Token $script:InteractiveWin11HostedRunToken
    if ($argumentRefusal) { return $argumentRefusal }
    return $null
}

# One command line, built here and never by Start-Process (which joins arguments unquoted): an argument with
# whitespace is quoted; one holding a quote or ending in a backslash is refused, as the soak's launcher does; and
# `--command` never travels in argv (the shell is the copy's config line).
function ConvertTo-InteractiveWin11HostedCommandLine {
    param([Parameter(Mandatory)] [string] $FilePath, [AllowEmptyCollection()] [string[]] $ArgumentList = @())

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('"' + $FilePath + '"')
    foreach ($argument in $ArgumentList) {
        if ($argument.Contains('"') -or $argument.EndsWith('\')) { throw 'gui-hidden: a launch argument cannot hold a quote or end in a backslash.' }
        if ($argument.StartsWith('--command', [StringComparison]::Ordinal)) { throw 'gui-hidden: --command never travels in argv; the copy''s config sets the shell.' }
        if ($argument.Length -eq 0 -or $argument -match '\s') { $parts.Add('"' + $argument + '"') } else { $parts.Add($argument) }
    }
    return $parts -join ' '
}

# The hosted launcher: starts the staged app or CLI on the runner's desktop, by name, with its own command line, after
# the per-launch check and the desktop check; records its PID and creation time before it runs (the runner fails any
# noctty process its job gains that this record lacks); returns a Process whose handle is already open, so its exit
# code stays readable after it exits.
function Start-InteractiveWin11HostedProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [AllowEmptyCollection()] [string[]] $ArgumentList = @(),
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [string] $RedirectStandardOutput,
        [string] $RedirectStandardError
    )

    $refusal = Get-InteractiveWin11HostedLaunchRefusal -FilePath $FilePath -ArgumentList $ArgumentList
    if ($refusal) { throw "gui-hidden: the launcher refused the start: $refusal." }
    [InteractiveWin11HostedDesktop]::Assert($env:NOCTTY_GUI_HIDDEN_DESKTOP)
    $line = ConvertTo-InteractiveWin11HostedCommandLine -FilePath $FilePath -ArgumentList $ArgumentList
    $pi = [InteractiveWin11HostedLaunch]::Start($FilePath, $line, $WorkingDirectory, $env:NOCTTY_GUI_HIDDEN_DESKTOP, $RedirectStandardOutput, $RedirectStandardError)
    $started = $false
    try {
        # The command line the suspended process really holds, read through the handle CreateProcess returned (so no
        # reused PID can answer) and split as the process will split it: it must be exactly the arguments checked
        # above, and pass the argument rule again (H1 on #740; hidden-win11-working-set.ps1 reads its copy the same way).
        $readBack = [InteractiveWin11HostedLaunch]::Argv($pi.process)
        $expected = @($FilePath) + @($ArgumentList)
        if ($null -eq $readBack -or $readBack.Count -ne $expected.Count) { throw 'gui-hidden: the started process''s command line is not the launcher''s.' }
        for ($index = 0; $index -lt $expected.Count; $index++) {
            if (-not [string]::Equals($readBack[$index], $expected[$index], [StringComparison]::Ordinal)) { throw 'gui-hidden: the started process''s command line is not the launcher''s.' }
        }
        $readBackRefusal = Get-InteractiveWin11HostedArgumentRefusal -Arguments @($readBack | Select-Object -Skip 1) -Token $script:InteractiveWin11HostedRunToken
        if ($readBackRefusal) { throw "gui-hidden: the started process's command line breaks the argument rule: $readBackRefusal." }
        $process = [System.Diagnostics.Process]::GetProcessById($pi.pid)
        [void]$process.Handle
        $record = '{0} {1}' -f $pi.pid, [InteractiveWin11HostedLaunch]::CreationTime($pi.process)
        [IO.File]::AppendAllText((Join-Path $env:NOCTTY_GUI_HIDDEN_RUN 'launcher-pids.txt'), $record + "`n")
        if ([InteractiveWin11HostedLaunch]::ResumeThread($pi.thread) -eq [uint32]::MaxValue) { throw 'gui-hidden: resuming the launched process failed.' }
        $started = $true
        return $process
    }
    finally {
        if (-not $started) { [void][InteractiveWin11HostedLaunch]::TerminateProcess($pi.process, 1) }
        [void][InteractiveWin11HostedLaunch]::CloseHandle($pi.thread)
        [void][InteractiveWin11HostedLaunch]::CloseHandle($pi.process)
    }
}

# Runs the staged CLI through the hosted launcher and waits for it, for a leaf that would run it with `& $cli`:
# its standard output as lines (UTF-8), its exit code, its standard error left in `StandardErrorPath`.
function Invoke-InteractiveWin11HostedProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [AllowEmptyCollection()] [string[]] $ArgumentList = @(),
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string] $StandardErrorPath,
        [int] $TimeoutSeconds = 60
    )

    $stdout = Join-Path $env:NOCTTY_GUI_HIDDEN_RUN ('cli-stdout-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    $process = Start-InteractiveWin11HostedProcess -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput $stdout -RedirectStandardError $StandardErrorPath
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw "gui-hidden: the CLI did not exit within ${TimeoutSeconds}s." }
        $text = [IO.File]::ReadAllText($stdout, [Text.UTF8Encoding]::new($false))
        $lines = @($text -split "`r?`n")
        if ($lines.Count -gt 0 -and $lines[-1].Length -eq 0) { $lines = @($lines | Select-Object -SkipLast 1) }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $lines }
    }
    finally {
        $process.Dispose()
        Remove-Item -LiteralPath $stdout -ErrorAction SilentlyContinue
    }
}

# The launch policy's config lines (design §4.1), appended after a leaf's own: the shell (a config line keeps its
# space; an argv element through Start-Process would be split and lose /D), the clipboard denied, no copy on select,
# no update check and no desktop notification.
function Get-InteractiveWin11HostedPolicyConfig {
    $cmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    return @(
        "command = direct:$cmd /D"
        'clipboard-read = deny'
        'clipboard-write = deny'
        'copy-on-select = false'
        'auto-update = off'
        'desktop-notifications = false'
    )
}

# Writes the leaf's config into its portable copy (portable mode reads <copy>\config.ghostty; xdg.zig): the leaf's
# text, then the policy lines, then `window-save-state = never` unless the leaf's text sets the key.
function Write-InteractiveWin11HostedConfig {
    param([AllowEmptyString()] [string] $Text = '')

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($Text -split "`r?`n")) {
        # The keys the argument rule governs, and includes, never come from a leaf's config.
        if ($line -match '\A\s*(class|single-instance|gtk-single-instance|config-file|config-default-files)\s*=') { throw "gui-hidden: a leaf's config cannot set $($Matches[1])." }
        if ($line.Length -gt 0) { $lines.Add($line) }
    }
    foreach ($line in Get-InteractiveWin11HostedPolicyConfig) { $lines.Add($line) }
    if (-not @($lines | Where-Object { $_ -match '\A\s*window-save-state\s*=' }).Count) { $lines.Add('window-save-state = never') }
    $path = Join-Path (Split-Path -Parent $env:NOCTTY_GUI_HIDDEN_EXE) 'config.ghostty'
    [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
    return $path
}

# Where a leaf's noctty keeps its config and state: the portable copy's root in hosted mode (it takes precedence over
# LOCALAPPDATA; src/os/xdg.zig portablePath), else the sandbox's LOCALAPPDATA\noctty.
function Get-InteractiveWin11StateRoot {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Layout)

    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) { return Split-Path -Parent $env:NOCTTY_GUI_HIDDEN_EXE }
    return Join-Path $Layout.LocalAppData 'noctty'
}

if ($env:NOCTTY_GUI_LAUNCH_POLICY) {
    throw 'NOCTTY_GUI_LAUNCH_POLICY is reserved for the visible core and takes no value yet.'
}
if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
    if (-not ('InteractiveWin11HostedDesktop' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

// The hosted-desktop check: one C# method, so no PowerShell alias or function can stand in for it.
public static class InteractiveWin11HostedDesktop {
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder value, int length, out int needed);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);

    static string NameOf(IntPtr handle) {
        if (handle == IntPtr.Zero) return null;
        var value = new StringBuilder(256);
        int needed;
        return GetUserObjectInformationW(handle, 2, value, 512, out needed) ? value.ToString() : null; // UOI_NAME
    }

    // Null when the caller may proceed, else why not. `expected` is the runner's `<station>\<desktop>`; a null name
    // or empty name means it could not be read (PowerShell passes $null to a string parameter as "").
    public static string Decide(string station, string desktop, string inputDesktop, string expected) {
        if (string.IsNullOrEmpty(expected)) return "no expected desktop";
        int slash = expected.IndexOf('\\');
        if (slash <= 0 || slash != expected.LastIndexOf('\\')) return "the expected desktop is not <station>\\<desktop>";
        string expectedStation = expected.Substring(0, slash), expectedDesktop = expected.Substring(slash + 1);
        if (!Regex.IsMatch(expectedDesktop, "\\Anoctty-gh-[0-9a-f]{32}\\z")) return "the expected desktop is not a runner's";
        if (string.IsNullOrEmpty(station)) return "window station unreadable";
        if (!string.Equals(station, expectedStation, StringComparison.Ordinal)) return "wrong window station";
        if (string.IsNullOrEmpty(desktop)) return "thread desktop unreadable";
        if (!string.Equals(desktop, expectedDesktop, StringComparison.Ordinal)) return "wrong desktop";
        if (string.IsNullOrEmpty(inputDesktop)) return "input desktop unreadable; is the workstation locked?";
        if (string.Equals(inputDesktop, expectedDesktop, StringComparison.OrdinalIgnoreCase)) return "on the input desktop";
        return null;
    }

    public static void Assert(string expected) {
        string station = NameOf(GetProcessWindowStation());
        string desktop = NameOf(GetThreadDesktop(GetCurrentThreadId()));
        string inputName = null;
        IntPtr input = OpenInputDesktop(0, false, 0x0001); // DESKTOP_READOBJECTS
        if (input != IntPtr.Zero) {
            try { inputName = NameOf(input); } finally { CloseDesktop(input); }
        }
        string reason = Decide(station, desktop, inputName, expected);
        if (reason != null) throw new InvalidOperationException("gui-hidden: refused: " + reason + ".");
    }
}

// The hosted launcher's native half: a process started suspended on a named desktop, its standard output and error
// (when given) going to files that are the only handles it inherits (PROC_THREAD_ATTRIBUTE_HANDLE_LIST, as
// gui-hosted-probe.ps1's Start does), and a file's identity for the per-launch check.
public static class InteractiveWin11HostedLaunch {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Startup {
        public int cb; public string reserved, desktop, title;
        public int x, y, cx, cy, charsX, charsY, fill, flags; public short show, reservedBytes;
        public IntPtr reservedPointer, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup info; public IntPtr attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
    [StructLayout(LayoutKind.Sequential)] struct FileTime { public uint low, high; }
    [StructLayout(LayoutKind.Sequential)] struct FileInfo {
        public uint attributes; public FileTime created, accessed, written;
        public uint volumeSerial, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref StartupEx startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, ref SecurityAttributes sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(IntPtr file, out FileInfo info);
    // Every struct this type mirrors, as its marshalled size and each field's offset (AGENTS.md "Win32 FFI"): the
    // library refuses hosted mode unless this equals its pinned literal ($script:InteractiveWin11HostedLaunchLayout).
    static string LayoutOf(Type type, params string[] fields) {
        var parts = new System.Collections.Generic.List<string> { type.Name + "=" + Marshal.SizeOf(type) };
        foreach (string field in fields) parts.Add(field + "@" + Marshal.OffsetOf(type, field));
        return string.Join(" ", parts);
    }
    public static string Layout() {
        return string.Join("; ", new[] {
            LayoutOf(typeof(FileInfo), "attributes", "created", "accessed", "written", "volumeSerial", "sizeHigh", "sizeLow", "links", "indexHigh", "indexLow"),
            LayoutOf(typeof(FileTime), "low", "high"),
            LayoutOf(typeof(Startup), "cb", "reserved", "desktop", "title", "x", "y", "cx", "cy", "charsX", "charsY", "fill", "flags",
                "show", "reservedBytes", "reservedPointer", "input", "output", "error"),
            LayoutOf(typeof(StartupEx), "info", "attributes"),
            LayoutOf(typeof(ProcessInfo), "process", "thread", "pid", "tid"),
            LayoutOf(typeof(SecurityAttributes), "length", "descriptor", "inherit") });
    }

    public delegate bool EnumWindow(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder name, int length);

    // The noctty host windows of `pid` on the caller's desktop, by class. On a private desktop a process's
    // MainWindowHandle can be the system's input-indicator overlay (UAC_InputIndicatorOverlayWnd), not the host:
    // a WM_CLOSE sent there closes nothing (measured, interactive offload PR 1).
    public static IntPtr[] HostWindows(int pid) {
        var found = new System.Collections.Generic.List<IntPtr>();
        EnumWindows((w, p) => {
            int owner; GetWindowThreadProcessId(w, out owner);
            if (owner == pid) {
                var name = new StringBuilder(64); GetClassNameW(w, name, 64);
                if (name.ToString() == "noctty.win32.host") found.Add(w);
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    static IntPtr OpenLog(string path) {
        var sa = new SecurityAttributes { length = Marshal.SizeOf(typeof(SecurityAttributes)), inherit = 1 };
        IntPtr handle = CreateFileW(path, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero); // GENERIC_WRITE, share read/write, CREATE_ALWAYS
        if (handle == new IntPtr(-1)) throw new Exception("Creating a launch log failed: " + Marshal.GetLastWin32Error());
        return handle;
    }

    // Started suspended (the caller records it, then resumes it). NORMAL_PRIORITY_CLASS | CREATE_SUSPENDED |
    // CREATE_NO_WINDOW: a console child (the CLI) gets no console window; a GUI child ignores the flag.
    public static ProcessInfo Start(string app, string command, string cwd, string desktop, string stdoutPath, string stderrPath) {
        if (string.IsNullOrEmpty(desktop)) throw new ArgumentException("The hosted launcher always names its desktop.");
        if (string.IsNullOrEmpty(stdoutPath)) stdoutPath = null;
        if (string.IsNullOrEmpty(stderrPath)) stderrPath = null;
        IntPtr output = IntPtr.Zero, error = IntPtr.Zero, list = IntPtr.Zero, handles = IntPtr.Zero;
        try {
            var si = new StartupEx();
            si.info.cb = Marshal.SizeOf(typeof(StartupEx));
            si.info.desktop = desktop;
            uint flags = 0x20 | 0x4 | 0x08000000;
            bool inherit = false;
            if (stdoutPath != null || stderrPath != null) {
                if (stdoutPath != null) output = OpenLog(stdoutPath);
                if (stderrPath != null) error = OpenLog(stderrPath);
                int count = (output != IntPtr.Zero ? 1 : 0) + (error != IntPtr.Zero ? 1 : 0);
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                list = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) { Marshal.FreeHGlobal(list); list = IntPtr.Zero; throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error()); }
                handles = Marshal.AllocHGlobal(IntPtr.Size * count);
                int slot = 0;
                if (output != IntPtr.Zero) { Marshal.WriteIntPtr(handles, IntPtr.Size * slot, output); slot++; }
                if (error != IntPtr.Zero) { Marshal.WriteIntPtr(handles, IntPtr.Size * slot, error); slot++; }
                if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x20002), handles, new IntPtr(IntPtr.Size * count), IntPtr.Zero, IntPtr.Zero))
                    throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
                si.info.flags = 0x100; // STARTF_USESTDHANDLES
                si.info.output = output; si.info.error = error;
                si.attributes = list;
                flags |= 0x00080000; // EXTENDED_STARTUPINFO_PRESENT
                inherit = true;
            }
            ProcessInfo pi;
            if (!CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, inherit, flags, IntPtr.Zero, cwd, ref si, out pi))
                throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
            return pi;
        } finally {
            if (list != IntPtr.Zero) { DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); }
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if (output != IntPtr.Zero) CloseHandle(output);
            if (error != IntPtr.Zero) CloseHandle(error);
        }
    }

    public static long CreationTime(IntPtr process) {
        long created, exited, kernel, user;
        return GetProcessTimes(process, out created, out exited, out kernel, out user) ? created : 0;
    }

    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int infoClass, IntPtr info, int length, out int returned);
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CommandLineToArgvW(string line, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);

    // The process's command line (ProcessCommandLineInformation, read by its handle) split by CommandLineToArgvW, as
    // the process's own C runtime splits it; null when unreadable. The caller compares it and keeps nothing.
    public static string[] Argv(IntPtr process) {
        int length;
        NtQueryInformationProcess(process, 60, IntPtr.Zero, 0, out length);
        if (length <= 16 || length > (1 << 20)) return null;
        IntPtr buffer = Marshal.AllocHGlobal(length);
        string line;
        try {
            if (NtQueryInformationProcess(process, 60, buffer, length, out length) != 0) return null;
            int bytes = (ushort)Marshal.ReadInt16(buffer);
            IntPtr text = Marshal.ReadIntPtr(buffer, 8); // UNICODE_STRING x64: Length, MaximumLength, padding, Buffer
            if (bytes == 0 || text == IntPtr.Zero) return null;
            line = Marshal.PtrToStringUni(text, bytes / 2);
        } finally { Marshal.FreeHGlobal(buffer); }
        int count;
        IntPtr argv = CommandLineToArgvW(line, out count);
        if (argv == IntPtr.Zero) return null;
        try {
            var result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        } finally { LocalFree(argv); }
    }

    // The volume serial, file index, size and last-write time of `path`, read from one handle; null when unreadable.
    public static string Identity(string path) {
        IntPtr file = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x80, IntPtr.Zero); // FILE_READ_ATTRIBUTES, share all, OPEN_EXISTING
        if (file == new IntPtr(-1)) return null;
        try {
            FileInfo info;
            if (!GetFileInformationByHandle(file, out info)) return null;
            return string.Format("{0:x8}:{1:x8}{2:x8}:{3:x8}{4:x8}:{5:x8}{6:x8}", info.volumeSerial, info.indexHigh, info.indexLow,
                info.sizeHigh, info.sizeLow, info.written.high, info.written.low);
        } finally { CloseHandle(file); }
    }
}
'@
    }
    # The launcher's structs as the x64 SDK lays them out (BY_HANDLE_FILE_INFORMATION with FILETIMEs of two DWORDs, 52
    # bytes; STARTUPINFOW 104, STARTUPINFOEXW 112, PROCESS_INFORMATION 24, SECURITY_ATTRIBUTES 24).
    $script:InteractiveWin11HostedLaunchLayout = 'FileInfo=52 attributes@0 created@4 accessed@12 written@20 volumeSerial@28 sizeHigh@32 sizeLow@36 links@40 indexHigh@44 indexLow@48; ' +
        'FileTime=8 low@0 high@4; Startup=104 cb@0 reserved@8 desktop@16 title@24 x@32 y@36 cx@40 cy@44 charsX@48 charsY@52 fill@56 flags@60 show@64 reservedBytes@66 reservedPointer@72 input@80 output@88 error@96; ' +
        'StartupEx=112 info@0 attributes@104; ProcessInfo=24 process@0 thread@8 pid@16 tid@20; SecurityAttributes=24 length@0 descriptor@8 inherit@16'
    if (-not [string]::Equals([InteractiveWin11HostedLaunch]::Layout(), $script:InteractiveWin11HostedLaunchLayout, [StringComparison]::Ordinal)) {
        throw 'gui-hidden: the hosted launcher''s structs are not laid out as the SDK''s.'
    }
    [InteractiveWin11HostedDesktop]::Assert($env:NOCTTY_GUI_HIDDEN_DESKTOP)
    $script:InteractiveWin11HostedIdentity = Initialize-InteractiveWin11HostedIdentity
    $script:InteractiveWin11HostedRunToken = Get-InteractiveWin11HostedRunToken
    # The leaf's receipt, written when its PowerShell exits, however it exits (a leaf reports failure through `exit`):
    # whether the real-input module's type was ever loaded in this process (design §4.3's run-time check). The runner
    # fails a leaf whose receipt is missing or says it was. The path travels in a closure: PowerShell.Exiting's
    # $Event.MessageData reads empty (measured, pwsh 7.6), and an empty path would write `.tmp` in the working directory.
    $interactiveWin11HostedReceiptPath = Join-Path $env:NOCTTY_GUI_HIDDEN_RUN 'leaf-receipt.json'
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action ({
        # `-as [type]` resolves a type by name across every assembly loaded in the process, Add-Type's included.
        $loaded = $null -ne ('InteractiveWin11RealInput' -as [type])
        $receipt = [ordered]@{
            schemaVersion = 1
            realInputLoaded = $loaded
            psEdition = [string]$PSVersionTable.PSEdition
            psVersion = '{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor
        }
        [IO.File]::WriteAllText("$interactiveWin11HostedReceiptPath.tmp", ($receipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move("$interactiveWin11HostedReceiptPath.tmp", $interactiveWin11HostedReceiptPath, $true)
    }.GetNewClosure())
}

function Test-InteractiveWin11MeasureMode {
    return $env:NOCTTY_INTERACTIVE_MEASURE_AUMID -eq '1'
}

function Get-InteractiveWin11ProcessAumid {
    if (Test-InteractiveWin11MeasureMode) { return 'io.github.amanthanvi.noctty.measure' }
    return 'io.github.amanthanvi.noctty'
}

function Get-InteractiveWin11ToastAumid {
    # CreateToastNotifierWithId uses this explicit identity in App.init, even
    # when the process/jump-list identity is isolated. Keep the release gate's
    # product notifier and product notification setting; do not substitute a
    # potentially unregistered measurement notifier or accept its fallback.
    return 'io.github.amanthanvi.noctty'
}

function Get-InteractiveWin11MeasureRepoForExe {
    param([Parameter(Mandatory)] [string] $ExePath)

    $path = Get-InteractiveWin11NormalizedPath $ExePath
    $match = [regex]::Match($path, '^(?<repo>.+)\\\.sandbox\\interactive-measure\\[0-9a-f]{40,64}\\prefix\\bin\\noctty\.exe$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw 'Measurement mode requires the raw measurement prefix executable.'
    }
    return $match.Groups['repo'].Value
}

function Get-InteractiveWin11NormalizedPath {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $full = [System.IO.Path]::GetFullPath($Path).Replace('/', '\')
    $root = [System.IO.Path]::GetPathRoot($full).Replace('/', '\')

    if ($full.Length -gt $root.Length) {
        return $full.TrimEnd('\')
    }

    return $full
}

function Get-InteractiveWin11WorktreeId {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    $normalized = Get-InteractiveWin11NormalizedPath -Path $RepoRoot
    $leaf = Split-Path -Path $normalized -Leaf
    $parentLeaf = Split-Path -Path (Split-Path -Path $normalized -Parent) -Leaf
    $slugSource = "$parentLeaf-$leaf".ToLowerInvariant()
    $slug = ($slugSource -replace '[^a-z0-9.-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'worktree'
    }
    if ($slug.Length -gt 32) {
        $slug = $slug.Substring(0, 32).TrimEnd('-')
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized.ToLowerInvariant())
        $hash = [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    return '{0}-{1}' -f $slug, $hash.Substring(0, 12)
}

function Get-InteractiveWin11SandboxName {
    param(
        [string] $SandboxName = 'default'
    )

    $value = $SandboxName.Trim().ToLowerInvariant()
    $slug = ($value -replace '[^a-z0-9.-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'default'
    }
    if ($slug.Length -gt 24) {
        $slug = $slug.Substring(0, 24).TrimEnd('-')
    }

    return $slug
}

function Get-InteractiveWin11SandboxLayout {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $SandboxName = 'default'
    )

    $normalizedRepoRoot = Get-InteractiveWin11NormalizedPath -Path $RepoRoot
    $worktreeId = Get-InteractiveWin11WorktreeId -RepoRoot $normalizedRepoRoot
    $sandboxSlug = Get-InteractiveWin11SandboxName -SandboxName $SandboxName
    $sandboxId = '{0}-{1}' -f $worktreeId, $sandboxSlug
    $sandboxRoot = Join-Path $normalizedRepoRoot ".sandbox\win11\$worktreeId\$sandboxSlug"
    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        # Hosted: under the leaf's run directory, named by its run token, and the id (so every class built from it)
        # ends in the token (Get-InteractiveWin11HostedRunToken). A checkout-derived root would be shared by every run
        # of the leaf from this checkout, the legacy route's included (H1 on #740).
        $token = Get-InteractiveWin11HostedRunToken
        $sandboxId = '{0}-{1}' -f $sandboxSlug, $token
        $sandboxRoot = Join-Path (Get-InteractiveWin11NormalizedPath -Path $env:NOCTTY_GUI_HIDDEN_RUN) "sandbox-$token"
    }
    $localAppData = Join-Path $sandboxRoot 'localappdata'

    return [ordered]@{
        RepoRoot      = $normalizedRepoRoot
        WorktreeId    = $worktreeId
        SandboxName   = $sandboxSlug
        SandboxId     = $sandboxId
        SandboxRoot   = $sandboxRoot
        AppData       = Join-Path $sandboxRoot 'appdata'
        LocalAppData  = $localAppData
        XdgConfigHome = $localAppData
        XdgCacheHome  = Join-Path $sandboxRoot 'cache'
        XdgStateHome  = Join-Path $sandboxRoot 'state'
        Temp          = Join-Path $sandboxRoot 'temp'
        Logs          = Join-Path $sandboxRoot 'logs'
    }
}

function New-InteractiveWin11Sandbox {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    foreach ($path in @(
        $Layout.SandboxRoot,
        $Layout.AppData,
        $Layout.LocalAppData,
        $Layout.XdgCacheHome,
        $Layout.XdgStateHome,
        $Layout.Temp,
        $Layout.Logs
    )) {
        New-Item -ItemType Directory -Force -Path $path -ErrorAction Stop | Out-Null
    }
}

function Get-InteractiveWin11Environment {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    return [ordered]@{
        APPDATA         = $Layout.AppData
        LOCALAPPDATA    = $Layout.LocalAppData
        XDG_CONFIG_HOME = $Layout.XdgConfigHome
        XDG_CACHE_HOME  = $Layout.XdgCacheHome
        XDG_STATE_HOME  = $Layout.XdgStateHome
        TEMP            = $Layout.Temp
        TMP             = $Layout.Temp
    }
}

if (-not ('InteractiveWin11MessageNativeV2' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class InteractiveWin11MessageNativeV2 {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    public static uint GetWindowThreadProcessIdWithError(IntPtr hwnd, out uint processId, out int lastError) {
        SetLastError(0);
        uint result = GetWindowThreadProcessId(hwnd, out processId);
        lastError = Marshal.GetLastWin32Error();
        return result;
    }
    [DllImport("kernel32.dll")] private static extern void SetLastError(uint errorCode);

    public static IntPtr SendMessageTimeoutWithError(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result, out int lastError) {
        SetLastError(0);
        IntPtr status = SendMessageTimeoutW(hwnd, message, wparam, lparam, flags, timeout, out result);
        lastError = Marshal.GetLastWin32Error();
        return status;
    }
    public static bool PostMessageWithError(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, out int lastError) {
        SetLastError(0);
        bool status = PostMessageW(hwnd, message, wparam, lparam);
        lastError = Marshal.GetLastWin32Error();
        return status;
    }
}
'@
}

$script:InteractiveWin11SmtoNormal = [uint32]0
$script:InteractiveWin11SmtoBlock = [uint32]0x0001
$script:InteractiveWin11ErrorSuccess = 0
$script:InteractiveWin11ErrorInvalidWindowHandle = 1400
$script:InteractiveWin11ErrorTimeout = 1460

function Get-InteractiveWin11MessageTimeoutMs {
    param(
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [string] $Description
    )

    $remainingMs = ($Deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($remainingMs -le 0) {
        throw "Deadline elapsed before sending $Description."
    }

    return [uint32][Math]::Min([double][uint32]::MaxValue, [Math]::Ceiling($remainingMs))
}

function Assert-InteractiveWin11WindowOwner {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [ValidateSet('send', 'post')] [string] $Verb,
        [int[]] $ToleratedErrors = @(),
        [ref] $ObservedToleratedError
    )

    $windowProcessId = [uint32]0
    $windowLastError = 0
    $windowThreadId = [InteractiveWin11MessageNativeV2]::GetWindowThreadProcessIdWithError($Hwnd, [ref] $windowProcessId, [ref] $windowLastError)
    if ($windowThreadId -eq 0) {
        if ($windowLastError -in $ToleratedErrors) {
            if ($null -eq $ObservedToleratedError) { throw 'ToleratedErrors requires an ObservedToleratedError output reference.' }
            $ObservedToleratedError.Value = $windowLastError
            Write-Warning "GetWindowThreadProcessId returned tolerated Win32 error $windowLastError for $Description hwnd=$Hwnd."
            return $false
        }
        $detail = if ($windowLastError -eq 0) { 'without a Win32 error' } else { "with Win32 error $windowLastError" }
        throw "Refusing to $Verb $Description to invalid hwnd=$Hwnd $detail."
    }
    if ($windowProcessId -ne [uint32]$Process.Id) {
        throw "Refusing to $Verb $Description to hwnd=$Hwnd because owner pid=$windowProcessId does not match expected pid=$($Process.Id)."
    }

    return $true
}

function Invoke-InteractiveWin11Message {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint32] $Message,
        [UIntPtr] $WParam = [UIntPtr]::Zero,
        [IntPtr] $LParam = [IntPtr]::Zero,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [string] $Description,
        [uint32] $Flags = $script:InteractiveWin11SmtoNormal,
        [int[]] $ToleratedErrors = @(),
        [ref] $ObservedToleratedError,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    if ($ToleratedErrors.Count -gt 0) {
        if ($null -eq $ObservedToleratedError) { throw 'ToleratedErrors requires an ObservedToleratedError output reference.' }
        $ObservedToleratedError.Value = 0
    }

    $Process.Refresh()
    if ($Process.HasExited) {
        throw "Refusing to send $Description because noctty already exited (exit code $($Process.ExitCode))."
    }

    $sendTimeoutMs = Get-InteractiveWin11MessageTimeoutMs -Deadline $Deadline -Description "$Description hwnd=$Hwnd"
    # Keep ownership validation immediately adjacent to the send so lengthy
    # phase work cannot turn a stale HWND into a cross-process message.
    $ownershipArgs = @{
        Hwnd = $Hwnd
        Process = $Process
        Description = $Description
        Verb = 'send'
        ToleratedErrors = $ToleratedErrors
    }
    if ($null -ne $ObservedToleratedError) {
        $ownershipArgs.ObservedToleratedError = $ObservedToleratedError
    }
    if (-not (Assert-InteractiveWin11WindowOwner @ownershipArgs)) {
        return [UIntPtr]::Zero
    }

    $sendResult = [UIntPtr]::Zero
    $lastError = 0
    $sendStatus = [InteractiveWin11MessageNativeV2]::SendMessageTimeoutWithError(
        $Hwnd,
        $Message,
        $WParam,
        $LParam,
        $Flags,
        $sendTimeoutMs,
        [ref] $sendResult,
        [ref] $lastError
    )
    if ($sendStatus -eq [IntPtr]::Zero) {
        if ($lastError -eq $script:InteractiveWin11ErrorTimeout) {
            throw "SendMessageTimeoutW timed out for $Description hwnd=$Hwnd error=$lastError"
        }
        if ($lastError -in $ToleratedErrors) {
            $ObservedToleratedError.Value = $lastError
            Write-Warning "SendMessageTimeoutW returned tolerated Win32 error $lastError for $Description hwnd=$Hwnd."
            return $sendResult
        }
        $detail = if ($lastError -eq $script:InteractiveWin11ErrorSuccess) { 'generic failure without a Win32 error' } else { "Win32 error $lastError" }
        throw "SendMessageTimeoutW failed for $Description hwnd=$Hwnd ($detail)."
    }

    return $sendResult
}

function Invoke-InteractiveWin11PostMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint32] $Message,
        [UIntPtr] $WParam = [UIntPtr]::Zero,
        [IntPtr] $LParam = [IntPtr]::Zero,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    $Process.Refresh()
    if ($Process.HasExited) {
        throw "Refusing to post $Description because noctty already exited (exit code $($Process.ExitCode))."
    }

    [void](Assert-InteractiveWin11WindowOwner -Hwnd $Hwnd -Process $Process -Description $Description -Verb 'post')
    $lastError = 0
    if ($Deadline -le [DateTime]::UtcNow) { throw "Timed out waiting for $Description." }
    if (-not [InteractiveWin11MessageNativeV2]::PostMessageWithError($Hwnd, $Message, $WParam, $LParam, [ref] $lastError)) {
        $detail = if ($lastError -eq 0) { 'without a Win32 error' } else { "with Win32 error $lastError" }
        throw "PostMessageW failed for $Description hwnd=$Hwnd $detail."
    }
}

function Get-InteractiveWin11ContainmentArguments {
    return @(
        '--linux-cgroup=always'
        '--linux-cgroup-hard-fail=true'
        '--windows-job-object-kill-on-close=true'
    )
}

function Get-InteractiveWin11LaunchArguments {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout,
        [switch] $UseConfiguredCommand
    )

    # Hosted mode sets the shell in the copy's config file (Get-InteractiveWin11HostedPolicyConfig), never in argv.
    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        return @(
            Get-InteractiveWin11ContainmentArguments
            '--single-instance=false'
            "--class=noctty-interactive-$($Layout.SandboxId)"
        )
    }
    return @(
        Get-InteractiveWin11ContainmentArguments
        '--single-instance=false'
        "--class=noctty-interactive-$($Layout.SandboxId)"
        # Most harnesses type cmd syntax or only need a prompt. PowerShell's
        # default history ignores APPDATA, so never inherit the product default.
        if (-not $UseConfiguredCommand) { '--command=cmd.exe' }
    )
}

function Get-InteractiveWin11WindowsPowerShellModulePath {
    param(
        [AllowEmptyString()] [string] $ModulePath
    )

    # PowerShell 7 puts its own module folders on PSModulePath and strips them
    # only when it starts powershell.exe itself. The bootstrap starts Windows
    # PowerShell through cmd.exe (dev-windows.cmd), so 5.1 inherits them and
    # imports PowerShell 7's Microsoft.PowerShell.Utility, which has no
    # Get-FileHash: the harness then fails with CommandNotFoundException.
    $sharedPaths = @(
        foreach ($base in @([System.Environment]::GetFolderPath('MyDocuments'), $env:ProgramFiles)) {
            if (-not [string]::IsNullOrWhiteSpace($base)) { (Join-Path $base 'PowerShell\Modules').TrimEnd('\') }
        }
    )

    $kept = foreach ($entry in @($ModulePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $trimmed = $entry.Trim().TrimEnd('\')
        if (@($sharedPaths | Where-Object { $_.Equals($trimmed, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        if ((Split-Path -Leaf $trimmed) -ieq 'Modules') {
            $parent = Split-Path -Parent $trimmed
            if ($parent -and (Test-Path -LiteralPath (Join-Path $parent 'pwsh.exe') -PathType Leaf)) { continue }
        }
        $entry
    }

    return (@($kept) -join ';')
}

function Invoke-InteractiveWin11Bootstrap {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $LauncherPath,
        [Parameter(Mandatory)] [string] $EnvironmentVariable,
        [string[]] $ArgumentList = @(),
        [System.Management.Automation.PSReference] $ExitCode
    )

    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        throw 'gui-hidden: a hosted leaf never bootstraps; it runs in the runner''s pwsh.'
    }
    $bootstrapCmd = Join-Path $RepoRoot 'scripts\dev-windows.cmd'
    $childExitCode = 0
    [System.Environment]::SetEnvironmentVariable($EnvironmentVariable, '1', 'Process')
    $savedModulePath = $env:PSModulePath

    Push-Location $RepoRoot
    try {
        $env:PSModulePath = Get-InteractiveWin11WindowsPowerShellModulePath -ModulePath $savedModulePath
        & $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $LauncherPath @ArgumentList
        if ($null -ne $LASTEXITCODE) {
            $childExitCode = $LASTEXITCODE
        }
    }
    finally {
        Pop-Location
        $env:PSModulePath = $savedModulePath
        [System.Environment]::SetEnvironmentVariable(
            $EnvironmentVariable,
            $null,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    if ($null -ne $ExitCode) {
        $ExitCode.Value = $childExitCode
    }
}

function Invoke-InteractiveWin11HarnessMain {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $LauncherPath,
        [Parameter(Mandatory)] [string] $EnvironmentVariable,
        [string[]] $ArgumentList = @()
    )

    # A hosted leaf already runs where it should, in the runner's pwsh; the bootstrap's tripwire is the backstop.
    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        return
    }
    $bootstrapSentinel = [System.Environment]::GetEnvironmentVariable(
        $EnvironmentVariable,
        [System.EnvironmentVariableTarget]::Process
    )
    if (-not [string]::IsNullOrEmpty($bootstrapSentinel)) {
        return
    }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $RepoRoot `
        -LauncherPath $LauncherPath `
        -EnvironmentVariable $EnvironmentVariable `
        -ArgumentList $ArgumentList `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

function Set-InteractiveWin11Environment {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout,
        [switch] $IncludeResourcesDir
    )

    $sandboxEnv = Get-InteractiveWin11Environment -Layout $Layout
    foreach ($entry in $sandboxEnv.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable([string] $entry.Key, [string] $entry.Value, 'Process')
    }

    if ($IncludeResourcesDir) {
        $builtResourcesDir = Join-Path $Layout.RepoRoot 'zig-out\share\ghostty'
        $resourcesDir = if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
            # The portable copy's own resources (an override takes precedence in optimized builds; resourcesdir.zig).
            Join-Path (Split-Path -Parent $env:NOCTTY_GUI_HIDDEN_EXE) 'share\ghostty'
        }
        elseif (Test-InteractiveWin11MeasureMode) {
            # Keep resources with the archived build, even before its first
            # build. Never fall back to a different checkout's resource tree.
            Join-Path (Get-InteractiveWin11MeasureLayout $Layout.RepoRoot).Prefix 'share\ghostty'
        }
        elseif (Test-Path -LiteralPath $builtResourcesDir -PathType Container) {
            $builtResourcesDir
        }
        else {
            Join-Path $Layout.RepoRoot 'src'
        }
        [System.Environment]::SetEnvironmentVariable(
            'GHOSTTY_RESOURCES_DIR',
            $resourcesDir,
            'Process'
        )
    }
    else {
        [System.Environment]::SetEnvironmentVariable(
            'GHOSTTY_RESOURCES_DIR',
            $null,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    return $sandboxEnv
}

function Initialize-InteractiveWin11Sandbox {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $SandboxName = 'default',
        [switch] $ResetState,
        [switch] $IncludeResourcesDir
    )

    $normalizedRepoRoot = Get-InteractiveWin11NormalizedPath -Path $RepoRoot
    $layout = Get-InteractiveWin11SandboxLayout -RepoRoot $normalizedRepoRoot -SandboxName $SandboxName

    if ($ResetState) {
        Reset-InteractiveWin11Sandbox -Layout $layout
    }

    New-InteractiveWin11Sandbox -Layout $layout
    $sandboxEnv = Set-InteractiveWin11Environment -Layout $layout -IncludeResourcesDir:$IncludeResourcesDir

    return [ordered]@{
        RepoRoot    = $normalizedRepoRoot
        Layout      = $layout
        Environment = $sandboxEnv
    }
}

function Get-InteractiveWin11DefaultBuildInputs {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    return @(
        (Join-Path $RepoRoot 'build.zig'),
        (Join-Path $RepoRoot 'build.zig.zon'),
        (Join-Path $RepoRoot 'src')
    )
}

function Get-InteractiveWin11ExePath {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) { return [IO.Path]::GetFullPath($env:NOCTTY_GUI_HIDDEN_EXE) }
    if (Test-InteractiveWin11MeasureMode) { return Get-InteractiveWin11MeasureExePath -RepoRoot $RepoRoot }
    return Get-InteractiveWin11NormalizedPath -Path (Join-Path $RepoRoot 'zig-out\bin\noctty.exe')
}

function Invoke-InteractiveWin11Build {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')] [string] $Optimize
    )

    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        throw 'gui-hidden: a hosted leaf never builds; the runner stages the receipt-bound measurement build.'
    }
    if (Test-InteractiveWin11MeasureMode) {
        $measureArguments = @{ RepoRoot = $RepoRoot }
        if (-not [string]::IsNullOrWhiteSpace($Optimize)) { $measureArguments.Optimize = $Optimize }
        Invoke-InteractiveWin11MeasureBuild @measureArguments
        return
    }
    $devWindowsCmd = Join-Path $RepoRoot 'scripts\dev-windows.cmd'
    $repoSandboxRoot = Get-InteractiveWin11NormalizedPath -Path (Join-Path $RepoRoot '.sandbox\win11')
    $savedLocalAppData = $env:LOCALAPPDATA
    $restoreLocalAppData = $false
    if (-not [string]::IsNullOrWhiteSpace($savedLocalAppData)) {
        $normalizedLocalAppData = Get-InteractiveWin11NormalizedPath -Path $savedLocalAppData
        $sandboxPrefix = '{0}\' -f $repoSandboxRoot
        if (
            $normalizedLocalAppData.Equals($repoSandboxRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedLocalAppData.StartsWith($sandboxPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $hostLocalAppData = [System.Environment]::GetFolderPath(
                [System.Environment+SpecialFolder]::LocalApplicationData
            )
            if ([string]::IsNullOrWhiteSpace($hostLocalAppData)) {
                $userProfilePath = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                    [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
                }
                else {
                    $env:USERPROFILE
                }

                if (-not [string]::IsNullOrWhiteSpace($userProfilePath)) {
                    $hostLocalAppData = Join-Path $userProfilePath 'AppData\Local'
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($hostLocalAppData)) {
                $env:LOCALAPPDATA = Get-InteractiveWin11NormalizedPath -Path $hostLocalAppData
                $restoreLocalAppData = $true
            }
        }
    }

    Push-Location $RepoRoot
    try {
        $optimizeArguments = @()
        if (-not [string]::IsNullOrWhiteSpace($Optimize)) {
            $optimizeArguments += "-Doptimize=$Optimize"
        }
        & cmd /c $devWindowsCmd zig build -Demit-exe=true @optimizeArguments
        if ($LASTEXITCODE -ne 0) {
            $buildDescription = @('zig', 'build', '-Demit-exe=true') + $optimizeArguments
            throw "$($buildDescription -join ' ') failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
        if ($restoreLocalAppData) {
            $env:LOCALAPPDATA = $savedLocalAppData
        }
    }
}

function Assert-InteractiveWin11ExeExists {
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        # For callers that never open a terminal window (vt-probe) or that
        # measure whichever backend the binary has (bench).
        [switch] $AllowInboxConPty
    )

    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        # The runner validated the raw generation; this is the per-launch check on the staged copy.
        $refusal = Get-InteractiveWin11HostedLaunchRefusal -FilePath $ExePath -FileOnly
        if ($refusal) { throw "gui-hidden: the staged copy is refused: $refusal." }
    }
    elseif (Test-InteractiveWin11MeasureMode) {
        $measureRepo = Get-InteractiveWin11MeasureRepoForExe $ExePath
        Assert-InteractiveWin11MeasureBuild -RepoRoot $measureRepo -ExePath $ExePath
    }
    if (-not [System.IO.File]::Exists($ExePath)) {
        throw "Missing noctty.exe at $ExePath"
    }
    if ($AllowInboxConPty) { return }
    # A build that could not stage the bundled ConPTY still succeeds, and
    # noctty then falls back to the in-box conhost behind an error banner.
    # That banner is a focus region and changes the output stream, so every
    # check below would measure a different app.
    $binDir = [System.IO.Path]::GetDirectoryName($ExePath)
    foreach ($name in @('conpty.dll', 'OpenConsole.exe')) {
        if (-not [System.IO.File]::Exists((Join-Path $binDir $name))) {
            throw "Missing $name beside $ExePath; the build did not stage the bundled ConPTY (see its warning), so noctty would fall back to the in-box conhost."
        }
    }
}

function Get-InteractiveWin11TextFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Default = ''
    )

    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw
    }

    return $Default
}

function Get-InteractiveWin11TextFileTail {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $LineCount = 40,
        [string] $Default = '<stderr log missing>'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Default
    }

    return (Get-Content -LiteralPath $Path | Select-Object -Last $LineCount) -join [Environment]::NewLine
}

function Get-InteractiveWin11RequiredJsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing expected trace/state file: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Wait-InteractiveWin11Until {
    param(
        [Parameter(Mandatory)] [scriptblock] $Condition,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Alias('Process')] [System.Diagnostics.Process] $WatchProcess,
        [ValidateRange(1, [int]::MaxValue)] [int] $PollMilliseconds = 100,
        [string] $TimeoutMessage,
        [switch] $ConditionFirst
    )

    # A condition that reads screen pixels (Get-StatefulPixel) names its window
    # here, so a timeout can say what was on screen instead of only a color.
    $script:InteractiveWin11PixelWindow = [IntPtr]::Zero
    if ($ConditionFirst) {
        while ($true) {
            if ($null -ne $WatchProcess -and $WatchProcess.HasExited) {
                throw "noctty exited while waiting for ${Description} (exit code $($WatchProcess.ExitCode))"
            }

            if (& $Condition) {
                return
            }

            Start-Sleep -Milliseconds $PollMilliseconds
            if ([DateTime]::UtcNow -ge $Deadline) {
                break
            }
        }
    }
    else {
    while ($true) {
        if ($null -ne $WatchProcess -and $WatchProcess.HasExited) {
            throw "noctty exited while waiting for ${Description} (exit code $($WatchProcess.ExitCode))"
        }

        if ([DateTime]::UtcNow -ge $Deadline) {
            break
        }

        if (& $Condition) {
            return
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
    }

    $message = if ([string]::IsNullOrEmpty($TimeoutMessage)) { "Timed out waiting for $Description" } else { $TimeoutMessage }
    if ($script:InteractiveWin11PixelWindow -ne [IntPtr]::Zero) {
        try { $message += "; $(Save-StatefulPixelDiagnostic -Hwnd $script:InteractiveWin11PixelWindow -Description $Description)" }
        catch { $message += "; pixel diagnostic failed: $($_.Exception.Message)" }
    }
    throw $message
}

function Get-InteractiveWin11ProcessTreeSnapshot {
    param(
        [Parameter(Mandatory)] [int] $RootProcessId,
        [Parameter(Mandatory)] [datetime] $RootStartedAt
    )

    $processes = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
    if ($processes.Count -eq 0) {
        throw 'Win32_Process returned no processes while snapshotting interactive cleanup.'
    }

    $processById = @{}
    $childrenByParent = @{}
    foreach ($process in $processes) {
        $processId = [int]$process.ProcessId
        $parentProcessId = [int]$process.ParentProcessId
        $processById[$processId] = $process
        if (-not $childrenByParent.ContainsKey($parentProcessId)) {
            $childrenByParent[$parentProcessId] = [Collections.Generic.List[object]]::new()
        }
        [void]$childrenByParent[$parentProcessId].Add($process)
    }
    if (-not $processById.ContainsKey($RootProcessId)) {
        throw "Interactive Win11 root process $RootProcessId was absent from the process-table snapshot."
    }
    $observedRootStartedAt = ([datetime]$processById[$RootProcessId].CreationDate).ToUniversalTime()
    $expectedRootStartedAt = $RootStartedAt.ToUniversalTime()
    if ([math]::Abs(($observedRootStartedAt - $expectedRootStartedAt).TotalMilliseconds) -gt 10) {
        throw "Interactive Win11 root process $RootProcessId identity changed before process-tree cleanup."
    }

    $snapshot = [Collections.Generic.List[object]]::new()
    $queue = [Collections.Generic.Queue[int]]::new()
    $seen = [Collections.Generic.HashSet[int]]::new()
    $queue.Enqueue($RootProcessId)
    [void]$seen.Add($RootProcessId)

    while ($queue.Count -gt 0) {
        $processId = $queue.Dequeue()
        $process = $processById[$processId]
        $processStartedAt = ([datetime]$process.CreationDate).ToUniversalTime()
        [void]$snapshot.Add([pscustomobject]@{
            ProcessId    = [int]$process.ProcessId
            CreationDate = $processStartedAt
        })
        if ($childrenByParent.ContainsKey($processId)) {
            foreach ($child in $childrenByParent[$processId]) {
                $childProcessId = [int]$child.ProcessId
                $childStartedAt = ([datetime]$child.CreationDate).ToUniversalTime()
                if ($childStartedAt -lt $processStartedAt) {
                    continue
                }
                if ($seen.Add($childProcessId)) {
                    $queue.Enqueue($childProcessId)
                }
            }
        }
    }

    return @($snapshot)
}

function Test-InteractiveWin11ProcessTreeSnapshotExited {
    param(
        [Parameter(Mandatory)] [object[]] $Snapshot,
        [ValidateRange(1, 5)] [uint32] $OperationTimeoutSec = 5
    )

    if ($Snapshot.Count -eq 0) {
        throw 'Interactive Win11 process-tree verification requires a non-empty snapshot.'
    }

    $processes = @(Get-CimInstance `
            -ClassName Win32_Process `
            -OperationTimeoutSec $OperationTimeoutSec `
            -ErrorAction Stop)
    if ($processes.Count -eq 0) {
        throw 'Win32_Process returned no processes while verifying interactive cleanup.'
    }

    $liveById = @{}
    foreach ($process in $processes) {
        $liveById[[int]$process.ProcessId] = $process
    }

    $capturedProcessIds = [Collections.Generic.HashSet[int]]::new()
    $capturedStartedAtById = @{}
    foreach ($entry in $Snapshot) {
        $processId = [int]$entry.ProcessId
        [void]$capturedProcessIds.Add($processId)
        $capturedStartedAtById[$processId] = ([datetime]$entry.CreationDate).ToUniversalTime()
        $live = $liveById[$processId]
        if ($null -ne $live -and
            ([datetime]$live.CreationDate).ToUniversalTime().Ticks -eq
            ([datetime]$entry.CreationDate).ToUniversalTime().Ticks) {
            return $false
        }
    }

    # Fail closed if a child appeared after the last snapshot. ParentProcessId
    # remains useful after its parent exits; compare against the captured parent
    # identity so stale children from reused PIDs do not poison cleanup.
    foreach ($process in $processes) {
        $parentProcessId = [int]$process.ParentProcessId
        if ($capturedProcessIds.Contains($parentProcessId) -and
            ([datetime]$process.CreationDate).ToUniversalTime() -ge $capturedStartedAtById[$parentProcessId]) {
            return $false
        }
    }

    return $true
}

function Stop-InteractiveWin11RootHandle {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [IntPtr] $RootProcessHandle,
        [Parameter(Mandatory)] [datetime] $RootStartedAt
    )

    try {
        $Process.Refresh()
        if ($Process.HasExited -or $Process.StartTime -ne $RootStartedAt) {
            return
        }
    }
    catch [System.InvalidOperationException] {
        return
    }

    Initialize-InteractiveWin11ProcessNative
    $terminationRequested = [InteractiveWin11ProcessNative]::TerminateProcess($RootProcessHandle, 1)
    $terminationError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    # TerminateProcess is asynchronous. High Contrast and other system-wide UI
    # transitions can keep teardown pending beyond the ordinary five-second
    # harness cadence, so retain a bounded but transition-tolerant exit wait.
    $waitResult = [InteractiveWin11ProcessNative]::WaitForSingleObject($RootProcessHandle, 15000)
    if (-not $terminationRequested -and $waitResult -ne 0) {
        throw "root handle termination failed with Win32 error $terminationError; the root remained live after 15 seconds"
    }
    if ($waitResult -eq 258) {
        throw 'root handle termination did not stop the process within 15 seconds'
    }
    if ($waitResult -eq [uint32]::MaxValue) {
        $waitError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "root handle exit wait failed with Win32 error $waitError"
    }
    if ($waitResult -ne 0) {
        throw "root handle exit wait returned unexpected status $waitResult"
    }
}

function Wait-InteractiveWin11ProcessTreeSnapshotExited {
    param(
        [Parameter(Mandatory)] [object[]] $Snapshot,
        [ValidateRange(1, 30)] [uint32] $TimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $remainingSeconds = ($deadline - [DateTime]::UtcNow).TotalSeconds
        if ($remainingSeconds -le 0) {
            return $false
        }
        $operationTimeoutSec = [uint32][math]::Max(1, [math]::Min(5, [math]::Ceiling($remainingSeconds)))
        if (Test-InteractiveWin11ProcessTreeSnapshotExited `
                -Snapshot $Snapshot `
                -OperationTimeoutSec $operationTimeoutSec) {
            return $true
        }
        $remainingMilliseconds = [math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMilliseconds -gt 0) {
            Start-Sleep -Milliseconds ([int][math]::Min(100, $remainingMilliseconds))
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Stop-InteractiveWin11Process {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [switch] $RequireLiveRoot,
        [switch] $Contained,
        [switch] $AllowAlreadyExited
    )

    $lifecycleModeCount = @($RequireLiveRoot, $Contained, $AllowAlreadyExited).Where({ $_.IsPresent }).Count
    if ($lifecycleModeCount -gt 1) {
        throw 'RequireLiveRoot, Contained, and AllowAlreadyExited are mutually exclusive.'
    }

    $rootProcessId = $Process.Id
    $rootProcessHandle = [IntPtr]::Zero
    $rootStartedAt = $null
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $rootProcessHandle = $Process.Handle
            $rootStartedAt = $Process.StartTime
        }
    }
    catch [System.InvalidOperationException] {
        # The root exited while its handle identity was being captured.
    }
    if ($null -eq $rootStartedAt) {
        if ($RequireLiveRoot) {
            throw "Interactive Win11 process $rootProcessId exited before its process tree could be verified."
        }
        if ($Contained) {
            # The terminated host owned every terminal-child Job handle, so its
            # exit closed those jobs and killed their contained descendants.
            return
        }
        if ($AllowAlreadyExited) {
            # This is reserved for short-lived, uncontained probes that cannot
            # create persistent descendants and are expected to exit normally.
            return
        }
        throw "Uncontained interactive Win11 process $rootProcessId exited before its process tree could be verified."
    }

    $processTreeSnapshot = @()
    $snapshotError = $null
    try {
        $processTreeSnapshot = @(Get-InteractiveWin11ProcessTreeSnapshot `
                -RootProcessId $rootProcessId `
                -RootStartedAt $rootStartedAt)
    }
    catch {
        $snapshotError = $_.Exception.Message
    }

    $taskkillError = $null
    $taskkillCleanupError = $null
    if (-not $Contained) {
        # Keep RootProcessHandle open through taskkill. Windows cannot reuse a
        # process ID until all handles to that process object are closed, so
        # the numeric tree-kill target remains bound to the captured identity.
        $taskkill = $null
        try {
            $Process.Refresh()
            if (-not $Process.HasExited -and $Process.StartTime -eq $rootStartedAt) {
                $taskkillStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
                $taskkillStartInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
                $taskkillStartInfo.UseShellExecute = $false
                $taskkillStartInfo.CreateNoWindow = $true
                $taskkillStartInfo.Arguments = "/PID $rootProcessId /T /F"
                $taskkill = [System.Diagnostics.Process]::Start($taskkillStartInfo)
                if (-not $taskkill.WaitForExit(10000)) {
                    try {
                        $taskkill.Kill()
                        if (-not $taskkill.WaitForExit(5000)) {
                            $taskkillCleanupError = 'taskkill could not be stopped within 5 seconds'
                        }
                        else {
                            $taskkillError = 'taskkill exceeded 10 seconds'
                        }
                    }
                    catch {
                        $taskkillCleanupError = "taskkill could not be stopped: $($_.Exception.Message)"
                    }
                }
                elseif ($taskkill.ExitCode -ne 0) {
                    $taskkillError = "taskkill exited with code $($taskkill.ExitCode)"
                }
            }
        }
        catch {
            $taskkillError = $_.Exception.Message
        }
        finally {
            if ($null -ne $taskkill) { $taskkill.Dispose() }
        }
    }

    $terminationError = $null
    try {
        Stop-InteractiveWin11RootHandle `
            -Process $Process `
            -RootProcessHandle $rootProcessHandle `
            -RootStartedAt $rootStartedAt
    }
    catch {
        $terminationError = $_.Exception.Message
    }

    if ($null -ne $terminationError) {
        throw "Failed to clean interactive Win11 process tree $rootProcessId (taskkill='$taskkillError', root='$terminationError')."
    }
    if ($null -ne $taskkillCleanupError) {
        throw "Failed to reap taskkill while cleaning interactive Win11 process tree $rootProcessId`: $taskkillCleanupError"
    }
    if ($Contained -and $null -ne $snapshotError) {
        if ($VerbosePreference -eq 'Continue') {
            Write-Verbose "Contained interactive Win11 process $rootProcessId cleanup skipped CIM verification: $snapshotError"
        }
        return
    }
    if ($AllowAlreadyExited -and $null -ne $snapshotError) {
        if ($VerbosePreference -eq 'Continue') {
            Write-Verbose "Already-exited interactive Win11 process $rootProcessId cleanup skipped process-tree verification: $snapshotError"
        }
        return
    }
    if ($null -ne $snapshotError) {
        throw "Failed to verify uncontained interactive Win11 process tree $rootProcessId after termination: $snapshotError"
    }

    $verificationError = $null
    $processTreeExited = $false
    try {
        $processTreeExited = Wait-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $processTreeSnapshot
    }
    catch {
        $verificationError = $_.Exception.Message
    }
    if ($null -ne $verificationError) {
        if ($Contained) {
            if ($VerbosePreference -eq 'Continue') {
                Write-Verbose "Contained interactive Win11 process $rootProcessId cleanup could not query post-exit process state: $verificationError"
            }
            return
        }
        throw "Failed to verify cleanup of interactive Win11 process tree $rootProcessId after root termination: $verificationError"
    }
    if (-not $processTreeExited) {
        throw "Failed to verify cleanup of interactive Win11 process tree $rootProcessId after root termination: captured descendants remained live"
    }
    if ($null -ne $taskkillError -and $VerbosePreference -eq 'Continue') {
        Write-Verbose "Uncontained process tree $rootProcessId required root fallback after taskkill: $taskkillError"
    }
}

function Test-InteractiveWin11InputNewerThanBinary {
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        [string[]] $BuildInputs = @()
    )

    $resolvedExePath = Get-InteractiveWin11NormalizedPath -Path $ExePath
    if (-not [System.IO.File]::Exists($resolvedExePath)) {
        return $true
    }

    $exeTimestamp = [System.IO.File]::GetLastWriteTimeUtc($resolvedExePath)
    foreach ($inputPath in $BuildInputs) {
        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            continue
        }

        $resolvedInputPath = Get-InteractiveWin11NormalizedPath -Path $inputPath
        if ([System.IO.File]::Exists($resolvedInputPath)) {
            if ([System.IO.File]::GetLastWriteTimeUtc($resolvedInputPath) -gt $exeTimestamp) {
                return $true
            }
            continue
        }

        if (-not (Test-Path -LiteralPath $resolvedInputPath -PathType Container)) {
            continue
        }

        $newerInput = @(
            Get-Item -LiteralPath $resolvedInputPath -ErrorAction Stop
            Get-ChildItem -LiteralPath $resolvedInputPath -Recurse -Force -ErrorAction Stop
        ) |
            Where-Object { $_.LastWriteTimeUtc -gt $exeTimestamp } |
            Select-Object -First 1
        if ($null -ne $newerInput) {
            return $true
        }
    }

    return $false
}

function Get-InteractiveWin11LaunchAction {
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        [string[]] $BuildInputs = @(),
        [switch] $Rebuild,
        [switch] $NoBuild
    )

    $resolvedExePath = Get-InteractiveWin11NormalizedPath -Path $ExePath
    if ($Rebuild -and $NoBuild) {
        throw 'Cannot use -Rebuild with -NoBuild together.'
    }

    # A hosted leaf never builds: -Rebuild or a missing copy is an error, and no build starts.
    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        if ($Rebuild) { throw 'gui-hidden: a hosted leaf takes no -Rebuild.' }
        if (-not [IO.File]::Exists($resolvedExePath)) { throw 'gui-hidden: the staged copy is missing.' }
        return 'launch'
    }

    if ($Rebuild) {
        return 'build'
    }

    if (Test-InteractiveWin11MeasureMode) {
        [void] (Get-InteractiveWin11MeasureRepoForExe $resolvedExePath)
        if ([IO.File]::Exists($resolvedExePath)) {
            # This selects build versus reuse only. Every caller then runs
            # Assert-InteractiveWin11ExeExists at admission, which validates
            # HEAD/source/binary receipts once, including with -NoBuild.
            # Do not duplicate that full source walk inside leaf budgets.
            return 'launch'
        }
        if ($NoBuild) { throw "Missing measurement noctty.exe at $resolvedExePath (-NoBuild)." }
        return 'build'
    }

    if ([System.IO.File]::Exists($resolvedExePath)) {
        if (Test-InteractiveWin11InputNewerThanBinary -ExePath $resolvedExePath -BuildInputs $BuildInputs) {
            if ($NoBuild) {
                throw "noctty.exe at $resolvedExePath is older than the requested build inputs; rerun without -NoBuild or pass -Rebuild."
            }
            return 'build'
        }
        return 'launch'
    }

    if ($NoBuild) {
        throw "Missing noctty.exe at $resolvedExePath"
    }

    return 'build'
}

function Initialize-InteractiveWin11ProcessNative {
    if (-not ('InteractiveWin11ProcessNative' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class InteractiveWin11ProcessNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
}
"@
    }
}

function Get-InteractiveWin11ProcessExitCode {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [IntPtr] $ProcessHandle
    )

    Initialize-InteractiveWin11ProcessNative

    try {
        $Process.Refresh()
        if ($Process.HasExited) {
            $managedExitCode = $Process.ExitCode
            # PowerShell can surface a blank ExitCode for an exited GUI child;
            # retain the native handle fallback for that adapter edge case.
            if ($null -ne $managedExitCode) { return [int] $managedExitCode }
        }
    }
    catch {
        Write-Verbose "Managed exit-code fast path failed for pid=$($Process.Id); falling back to native GetExitCodeProcess: $($_.Exception.Message)"
    }

    [uint32] $nativeExitCode = 0
    if (-not [InteractiveWin11ProcessNative]::GetExitCodeProcess($ProcessHandle, [ref] $nativeExitCode)) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Exit code could not be read for pid=$($Process.Id): $lastError"
    }

    $Process.Refresh()
    if ($nativeExitCode -eq 259) {
        if (-not $Process.HasExited) {
            throw "Process has not exited yet for pid=$($Process.Id)"
        }

        if (-not [InteractiveWin11ProcessNative]::GetExitCodeProcess($ProcessHandle, [ref] $nativeExitCode)) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Exit code could not be re-read for pid=$($Process.Id): $lastError"
        }
    }

    return [BitConverter]::ToInt32([BitConverter]::GetBytes($nativeExitCode), 0)
}

function Reset-InteractiveWin11Sandbox {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    $sandboxBase = Get-InteractiveWin11NormalizedPath -Path (Join-Path $Layout.RepoRoot '.sandbox\win11')
    $target = Get-InteractiveWin11NormalizedPath -Path $Layout.SandboxRoot
    $sandboxPrefix = '{0}\' -f $sandboxBase
    if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        # Hosted: a reset stays inside the leaf's own run directory, on its token's sandbox.
        $sandboxBase = Get-InteractiveWin11NormalizedPath -Path $env:NOCTTY_GUI_HIDDEN_RUN
        $sandboxPrefix = '{0}\sandbox-' -f $sandboxBase
    }

    if (-not $target.StartsWith($sandboxPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset sandbox outside ${sandboxBase}: $target"
    }

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if (-not (Test-Path -LiteralPath $target -ErrorAction Stop)) {
            return
        }

        try {
            # Remove-Item -Recurse can race on Zig cache sentinel files
            # named ._.; Directory.Delete handles those paths reliably.
            [System.IO.Directory]::Delete($target, $true)
            return
        }
        catch {
            if (-not (Test-Path -LiteralPath $target)) {
                return
            }
            Start-Sleep -Milliseconds (100 * ($attempt + 1))
        }
    }

    $pendingName = '.delete-pending-{0}-{1}' -f (
        [System.IO.Path]::GetFileName($target),
        [System.Guid]::NewGuid().ToString('N')
    )
    $pending = Join-Path $sandboxBase $pendingName
    Move-Item -LiteralPath $target -Destination $pending -Force -ErrorAction Stop

    try {
        [System.IO.Directory]::Delete($pending, $true)
    }
    catch {
        Write-Warning "Moved stale sandbox to ${pending}; deferred cleanup failed: $($_.Exception.Message)"
    }
}
