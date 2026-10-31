import os
"""MEASUREMENT ONLY: derive harness/runner-load.ps1 from harness/runner-stall2.ps1 (exact replacements)."""
import pathlib

H = pathlib.Path(os.path.join(os.environ["TEMP"], r"w14\pacing-stall2\harness"))
s = (H / "runner-stall2.ps1").read_text(encoding="utf-8")


def rep(a, b):
    global s
    assert s.count(a) == 1, (a, s.count(a))
    s = s.replace(a, b)


rep(r"""Runs go to pacing-stall2\runs\<Name> (probe.ps1 copy here refuses anything else).
#>""", r"""Runs go to pacing-stall2\runs\<Name> (probe.ps1 copy here refuses anything else).

runner-load.ps1 (injected-load batch) = runner-stall2.ps1 plus:
  4. probe-load.ps1 (probe.ps1 plus an 'Idle' choice: driver BelowNormal outside
     noctty's job, noctty's job limited to IDLE_PRIORITY_CLASS 0x40).
  5. After the gate opens and before the probe starts, -LoadExe runs as `load`
     (one spinning thread per logical processor, busy -BusyMs / idle -IdleMs,
     BELOW_NORMAL_PRIORITY_CLASS, CREATE_NO_WINDOW, lpDesktop = a private
     desktop, in a kill-on-close job owned by this runner). Its bursts go to
     <side>-p<k>.load\bursts.txt (QPC). When the probe ends: stop file, then, if
     it has not exited within 5 s, TerminateProcess on the exact handle this
     runner created (PID and creation time logged).
  6. During key playback: base and current priority of every thread of the
     driver, noctty, the load and the watchdog (Snap, NtQuerySystemInformation)
     and each one's priority class, into <side>-p<k>.load\prio.txt.
  The probe runs through Start-Process (stdout + stderr into the same
  <side>-p<k>.probe.txt afterwards) so the runner can sample priorities.
#>""")
rep("""    [ValidateSet('BelowNormal','Normal','AboveNormal')] [string] $Priority = 'BelowNormal',""",
    """    [ValidateSet('BelowNormal','Normal','AboveNormal','Idle')] [string] $Priority = 'Idle',
    [Parameter(Mandatory)] [string] $LoadExe,
    [int] $BusyMs = 2000,
    [int] $IdleMs = 4000,""")
rep("""$probe = Join-Path $here 'probe.ps1'""", """$probe = Join-Path $here 'probe-load.ps1'""")
rep("""    Validation=$false; Priority=$Priority;""", """    Validation=$false; Priority=$Priority; LoadExe=$LoadExe; BusyMs=$BusyMs; IdleMs=$IdleMs;""")

ADD_TYPE = r"""Add-Type -Path $dll.FullName
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class W14Load {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Startup {
        public int cb; public string reserved, desktop, title; public int x, y, xs, ys, xc, yc, fill, flags; public short show, r2; public IntPtr r3, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime, jobTime; public uint flags; public UIntPtr minWorking, maxWorking;
        public uint activeProcesses; public UIntPtr affinity; public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits { public BasicLimits basic; public IoCounters io; public UIntPtr pm, jm, ppm, pjm; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr mode, uint flags, uint access, IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a, string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int t, ref JobLimits l, uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern uint GetPriorityClass(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] public static extern bool GetProcessTimes(IntPtr h, out long c, out long e, out long k, out long u);
    public static IntPtr KillOnCloseJob() {
        var j = CreateJobObjectW(IntPtr.Zero, null); if (j == IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var l = new JobLimits(); l.basic.flags = 0x2000;
        if (!SetInformationJobObject(j, 9, ref l, (uint)Marshal.SizeOf(typeof(JobLimits)))) { CloseHandle(j); throw new Exception("job limit failed"); }
        return j;
    }
    // CREATE_SUSPENDED, assigned to the job, then resumed; lpDesktop must be WinSta0\<private>.
    public static ProcessInfo Launch(string exe, string args, string desktop, IntPtr job, uint flags) {
        if (String.IsNullOrEmpty(desktop) || !desktop.StartsWith("WinSta0\\")) throw new Exception("explicit WinSta0\\<desktop> required");
        var s = new Startup(); s.cb = Marshal.SizeOf(typeof(Startup)); s.desktop = desktop; s.flags = 1; s.show = 0; ProcessInfo p;
        if (!CreateProcessW(exe, new StringBuilder("\"" + exe + "\" " + args), IntPtr.Zero, IntPtr.Zero, false, flags | 0x4, IntPtr.Zero, null, ref s, out p))
            throw new Exception("CreateProcess failed " + Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(job, p.process) || ResumeThread(p.thread) == 0xFFFFFFFF) { TerminateProcess(p.process, 1); CloseHandle(p.thread); CloseHandle(p.process); throw new Exception("assign/resume failed"); }
        return p;
    }
    public static long Created(IntPtr h) { long c, e, k, u; return GetProcessTimes(h, out c, out e, out k, out u) ? c : 0; }
    public static string ClassOf(uint pid) {
        IntPtr h = OpenProcess(0x1000, false, pid); if (h == IntPtr.Zero) return "?";
        try { uint c = GetPriorityClass(h); return "0x" + c.ToString("X"); } finally { CloseHandle(h); }
    }
}
'@
function Prio-Line([string]$role, [uint32]$procId) {
    if (-not $procId) { return "$role pid=? (not found)" }
    $sn = [W14Stall.Snap]::Take($procId); $pr = $sn.P[$procId]
    if (-not $pr -or -not $pr.Threads) { return "$role pid=$procId gone" }
    $hist = $pr.Threads | Group-Object BasePrio | Sort-Object { [int]$_.Name } -Descending | ForEach-Object { '{0}x{1}' -f $_.Name, $_.Count }
    $cur = $pr.Threads | Group-Object Prio | Sort-Object { [int]$_.Name } -Descending | ForEach-Object { '{0}x{1}' -f $_.Name, $_.Count }
    return ('{0} {1}:{2} class={3} threads={4} base_prio[{5}] cur_prio[{6}]' -f $role, $pr.Name, $procId, [W14Load]::ClassOf($procId), $pr.Threads.Count, ($hist -join ' '), ($cur -join ' '))
}
if (-not (Test-Path -LiteralPath $LoadExe)) { throw "no load exe $LoadExe" }
"""
rep("""Add-Type -Path $dll.FullName
""", ADD_TYPE)

RUN = r"""            Check-Builds ([W14Stall.Snap]::Take(0)) "before:$m $side-p$p"
            # --- injected load: start after the gate, before the probe (so before the first key) ---
            $ldDir = Join-Path $mdir "$side-p$p.load"; [void](New-Item -ItemType Directory -Force -Path $ldDir)
            $prioFile = Join-Path $ldDir 'prio.txt'; $ldStop = Join-Path $ldDir 'stop'
            $ldDeskName = 'w14-load-' + [guid]::NewGuid().ToString('N')
            $ldDesk = [W14Load]::CreateDesktopW($ldDeskName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
            if ($ldDesk -eq [IntPtr]::Zero) { throw 'load CreateDesktop failed' }
            $ldJob = [W14Load]::KillOnCloseJob()
            $ldArgs = ('load "{0}" "{1}" 180 {2} {3}' -f (Join-Path $ldDir 'bursts.txt'), $ldStop, $BusyMs, $IdleMs)
            # BELOW_NORMAL_PRIORITY_CLASS | CREATE_NO_WINDOW
            $ld = [W14Load]::Launch($LoadExe, $ldArgs, "WinSta0\$ldDeskName", $ldJob, [uint32]0x08004000)
            $ldCreated = [W14Load]::Created($ld.process)
            $ldLine = ('load pid={0} name={1} created={2:o} class=0x{3:X} desktop={4}' -f $ld.pid, (Split-Path -Leaf $LoadExe), [datetime]::FromFileTime($ldCreated), [W14Load]::GetPriorityClass($ld.process), $ldDeskName)
            Set-Content -LiteralPath $prioFile -Value ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $ldLine)
            $t0 = Get-Date
            $probeOutFile = Join-Path $mdir "$side-p$p.probe.txt"
            $pp = Start-Process -FilePath $pwshExe -ArgumentList $probeArgs -NoNewWindow -PassThru -RedirectStandardOutput $probeOutFile -RedirectStandardError (Join-Path $mdir "$side-p$p.probe.err.txt")
            $ppHandle = $pp.Handle
            $prioDone = 0; $surfaceAt = $null
            while (-not $pp.WaitForExit(250)) {
                if ($prioDone -ge 2) { continue }
                $drvLog = Join-Path $run 'driver.log'
                if (-not $surfaceAt -and (Test-Path -LiteralPath $drvLog) -and (Select-String -LiteralPath $drvLog -Pattern 'surface=0x' -Quiet)) { $surfaceAt = Get-Date }
                # keys start ~3 s after the surface; sample at +6 s and +16 s (inside playback)
                $due = if ($surfaceAt) { $surfaceAt.AddSeconds($(if ($prioDone -eq 0) { 6 } else { 16 })) } else { $null }
                if ($due -and (Get-Date) -ge $due) {
                    $drvPid = 0; $nocPid = 0
                    $om = [regex]::Match((Get-Content -LiteralPath (Join-Path $run 'outer.log') -Raw -ErrorAction SilentlyContinue), 'driver pid=(\d+)'); if ($om.Success) { $drvPid = [uint32]$om.Groups[1].Value }
                    $dm = [regex]::Match((Get-Content -LiteralPath $drvLog -Raw -ErrorAction SilentlyContinue), 'noctty pid=(\d+)'); if ($dm.Success) { $nocPid = [uint32]$dm.Groups[1].Value }
                    $lines = @(("{0:HH:mm:ss.fff} sample {1} (surface+{2} s) qpc={3}" -f (Get-Date), ($prioDone + 1), $(if ($prioDone -eq 0) { 6 } else { 16 }), [Diagnostics.Stopwatch]::GetTimestamp()),
                        (Prio-Line 'driver' $drvPid), (Prio-Line 'noctty' $nocPid), (Prio-Line 'load' ([uint32]$ld.pid)), (Prio-Line 'watchdog' $(if ($wd) { [uint32]$wd.Id } else { [uint32]0 })))
                    Add-Content -LiteralPath $prioFile -Value $lines
                    $prioDone++
                }
            }
            $pp.WaitForExit()
            $rc = $pp.ExitCode
            # --- stop the load: stop file, then the exact handle created above ---
            Set-Content -LiteralPath $ldStop -Value 'stop'
            if ([W14Load]::WaitForSingleObject($ld.process, 5000) -eq 0) { Add-Content -LiteralPath $prioFile -Value ("{0:HH:mm:ss.fff} load pid={1} exited on stop file" -f (Get-Date), $ld.pid) }
            else {
                $same = ([W14Load]::Created($ld.process) -eq $ldCreated)
                if ($same) { [void][W14Load]::TerminateProcess($ld.process, 1); [void][W14Load]::WaitForSingleObject($ld.process, 5000) }
                Add-Content -LiteralPath $prioFile -Value ("{0:HH:mm:ss.fff} load pid={1} did not exit in 5 s; identity_same={2}; terminated exact handle" -f (Get-Date), $ld.pid, $same)
            }
            [void][W14Load]::CloseHandle($ld.thread); [void][W14Load]::CloseHandle($ld.process); [void][W14Load]::CloseHandle($ldJob); [void][W14Load]::CloseDesktop($ldDesk)
            Get-Content -LiteralPath (Join-Path $mdir "$side-p$p.probe.err.txt") -ErrorAction SilentlyContinue | Add-Content -LiteralPath $probeOutFile
"""
rep("""            Check-Builds ([W14Stall.Snap]::Take(0)) "before:$m $side-p$p"
            $t0 = Get-Date
            & $pwshExe @probeArgs 2>&1 | Out-File -LiteralPath (Join-Path $mdir "$side-p$p.probe.txt")
            $rc = $LASTEXITCODE
""", RUN)
(H / "runner-load.ps1").write_text(s, encoding="utf-8")
print("ok")
