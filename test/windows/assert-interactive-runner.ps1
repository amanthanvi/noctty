[CmdletBinding()]
param(
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Interactive runner preflight must run inside GitHub Actions.' }
if ($env:RUNNER_OS -ne 'Windows') { throw "Interactive runner OS must be Windows; got '$($env:RUNNER_OS)'." }
if ($env:RUNNER_ARCH -ne 'X64') { throw "Interactive runner architecture must be X64; got '$($env:RUNNER_ARCH)'." }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_NAME)) { throw 'RUNNER_NAME is required for provenance.' }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'RUNNER_TEMP is required for runner version validation.' }

$minimumRunnerVersion = [version]'2.327.1'
$runnerRoot = Split-Path -Parent (Split-Path -Parent $env:RUNNER_TEMP)
$runnerWorkerPath = Join-Path $runnerRoot 'bin\Runner.Worker.exe'
if (-not (Test-Path -LiteralPath $runnerWorkerPath -PathType Leaf)) {
    throw "Runner.Worker.exe was not found at the expected runner root: $runnerWorkerPath"
}
$runnerVersionText = (Get-Item -LiteralPath $runnerWorkerPath).VersionInfo.FileVersion
[version]$runnerVersion = $null
if (-not [version]::TryParse($runnerVersionText, [ref]$runnerVersion)) {
    throw "Runner.Worker.exe has an invalid file version '$runnerVersionText': $runnerWorkerPath"
}
if ($runnerVersion -lt $minimumRunnerVersion) {
    throw "Interactive runner $runnerVersion is older than required version $minimumRunnerVersion."
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class NocttyRunnerNative {
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
$activeSessionRaw = [NocttyRunnerNative]::WTSGetActiveConsoleSessionId()
$activeSession = if ($activeSessionRaw -eq [uint32]::MaxValue) { -1 } else { [int]$activeSessionRaw }
$inputDesktop = [NocttyRunnerNative]::GetInputDesktopName()
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

    $expectedCommit = if ([string]::IsNullOrWhiteSpace($env:NOCTTY_EXPECTED_CHECKOUT_SHA)) {
        $env:GITHUB_SHA
    } else {
        $env:NOCTTY_EXPECTED_CHECKOUT_SHA
    }
    $checkedOutCommit = (& git -C $env:GITHUB_WORKSPACE rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $checkedOutCommit -ne $expectedCommit) {
        throw "Interactive runner checkout $checkedOutCommit does not match expected commit $expectedCommit."
    }

    $explorer = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $processSession)
    if ($explorer.Count -eq 0) { throw "No Explorer shell is running in interactive session $processSession." }

    $evidence = [ordered]@{
        schema_version = 'noctty.interactive-runner-provenance.v1'
        captured_at = [DateTimeOffset]::UtcNow.ToString('o')
        runner_name = $env:RUNNER_NAME
        runner_os = $env:RUNNER_OS
        runner_arch = $env:RUNNER_ARCH
        runner_version = $runnerVersion.ToString()
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
        commit = $expectedCommit
        checked_out_commit = $checkedOutCommit
        github_sha = $env:GITHUB_SHA
    }
    if ($OutputPath) {
        $parent = Split-Path -Parent $OutputPath
        if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
        $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    }
    Write-Host "Interactive runner provenance: PASS ($($env:RUNNER_NAME), runner $runnerVersion, session $processSession, $($identity.Name))"
}
finally {
    $identity.Dispose()
}
