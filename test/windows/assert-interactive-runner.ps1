[CmdletBinding()]
param(
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Interactive runner preflight must run inside GitHub Actions.' }
if ($env:RUNNER_OS -ne 'Windows') { throw "Interactive runner OS must be Windows; got '$($env:RUNNER_OS)'." }
if ($env:RUNNER_ARCH -ne 'X64') { throw "Interactive runner architecture must be X64; got '$($env:RUNNER_ARCH)'." }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_NAME)) { throw 'RUNNER_NAME is required for provenance.' }

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class WinghosttyRunnerNative {
    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder value, int length, ref int needed);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseDesktop(IntPtr desktop);

    public static string GetInputDesktopName() {
        const uint DesktopReadObjects = 0x0001;
        const int UoiName = 2;
        IntPtr desktop = OpenInputDesktop(0, false, DesktopReadObjects);
        if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            int needed = 0;
            GetUserObjectInformationW(desktop, UoiName, null, 0, ref needed);
            var value = new StringBuilder(Math.Max(needed / 2, 32));
            if (!GetUserObjectInformationW(desktop, UoiName, value, value.Capacity * 2, ref needed)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return value.ToString();
        } finally {
            CloseDesktop(desktop);
        }
    }
}
'@

$processSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
$activeSession = [int][WinghosttyRunnerNative]::WTSGetActiveConsoleSessionId()
$inputDesktop = [WinghosttyRunnerNative]::GetInputDesktopName()
$windowsBuild = [Environment]::OSVersion.Version.Build
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if ($windowsBuild -lt 22000) { throw "Interactive runner must run Windows 11; build is $windowsBuild." }
    if ($processSession -le 0) { throw "Interactive runner is in non-interactive session $processSession." }
    if ($processSession -ne $activeSession) {
        throw "Interactive runner session $processSession is not the active console session $activeSession."
    }
    if ($identity.IsSystem) { throw 'Interactive runner must not run as LocalSystem.' }
    if ($inputDesktop -ne 'Default') { throw "Interactive runner input desktop must be Default; got '$inputDesktop'." }

    $checkedOutCommit = (& git -C $env:GITHUB_WORKSPACE rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $checkedOutCommit -ne $env:GITHUB_SHA) {
        throw "Interactive runner checkout $checkedOutCommit does not match GITHUB_SHA $($env:GITHUB_SHA)."
    }

    $explorer = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $processSession)
    if ($explorer.Count -eq 0) { throw "No Explorer shell is running in interactive session $processSession." }

    $evidence = [ordered]@{
        schema_version = 'winghostty.interactive-runner-provenance.v1'
        captured_at = [DateTimeOffset]::UtcNow.ToString('o')
        runner_name = $env:RUNNER_NAME
        runner_os = $env:RUNNER_OS
        runner_arch = $env:RUNNER_ARCH
        windows_build = $windowsBuild
        input_desktop = $inputDesktop
        runner_environment = $env:RUNNER_ENVIRONMENT
        machine_name = [Environment]::MachineName
        user = $identity.Name
        process_session_id = $processSession
        active_console_session_id = $activeSession
        repository = $env:GITHUB_REPOSITORY
        workflow = $env:GITHUB_WORKFLOW
        run_id = $env:GITHUB_RUN_ID
        run_attempt = $env:GITHUB_RUN_ATTEMPT
        commit = $env:GITHUB_SHA
    }
    if ($OutputPath) {
        $parent = Split-Path -Parent $OutputPath
        if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
        $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    }
    Write-Host "Interactive runner provenance: PASS ($($env:RUNNER_NAME), session $processSession, $($identity.Name))"
}
finally {
    $identity.Dispose()
}
