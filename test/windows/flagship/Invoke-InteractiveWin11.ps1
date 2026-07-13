[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'artifacts\interactive-win11'),
    [switch] $Rebuild,
    [switch] $ResetState,
    [switch] $IncludeForegroundHarness
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
$transcriptPath = Join-Path $outputPath 'transcript.log'
$rawTranscriptPath = Join-Path $outputPath 'transcript.raw.log'
$resultPath = Join-Path $outputPath 'result.json'
$started = [DateTimeOffset]::UtcNow
$status = 'error'
$failure = $null
$commit = $null
$measurements = [ordered]@{}
$performanceHash = $null
$oldForeground = $env:WINGHOSTTY_INTERACTIVE_RUN_FOREGROUND_HARNESS

if (-not ('Winghostty.Flagship.DesktopProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Winghostty.Flagship {
    public static class DesktopProbe {
        [StructLayout(LayoutKind.Sequential)]
        private struct USEROBJECTFLAGS {
            public int fInherit;
            public int fReserved;
            public uint dwFlags;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetProcessWindowStation();

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool GetUserObjectInformation(
            IntPtr hObj, int nIndex, out USEROBJECTFLAGS pvInfo,
            int nLength, out int lpnLengthNeeded);

        public static bool HasVisibleWindowStation() {
            const int UOI_FLAGS = 1;
            const uint WSF_VISIBLE = 0x0001;
            USEROBJECTFLAGS flags;
            int needed;
            IntPtr station = GetProcessWindowStation();
            return station != IntPtr.Zero &&
                GetUserObjectInformation(station, UOI_FLAGS, out flags,
                    Marshal.SizeOf(typeof(USEROBJECTFLAGS)), out needed) &&
                (flags.dwFlags & WSF_VISIBLE) != 0;
        }
    }
}
'@
}
$interactiveDesktop = [Environment]::UserInteractive -and [Winghostty.Flagship.DesktopProbe]::HasVisibleWindowStation()

try {
    if (-not $interactiveDesktop) {
        throw 'Interactive Win11 verification requires a visible interactive window station.'
    }
    $dirty = @(& git -C $repoRoot status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to establish verification provenance.' }
    if ($dirty.Count -ne 0) { throw 'Refusing provenance-bearing verification for a dirty worktree.' }
    $commit = (& git -C $repoRoot rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    if ($IncludeForegroundHarness) {
        $env:WINGHOSTTY_INTERACTIVE_RUN_FOREGROUND_HARNESS = '1'
    }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $repoRoot 'test\windows\interactive-win11-validate.ps1')
    )
    if ($Rebuild) { $arguments += '-Rebuild' }
    if ($ResetState) { $arguments += '-ResetState' }

    & powershell.exe @arguments *> $rawTranscriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "Interactive Win11 composite exited with code $LASTEXITCODE."
    }
    $status = 'pass'
}
catch {
    $failure = [ordered]@{ message = $_.Exception.Message; type = $_.Exception.GetType().FullName }
}
finally {
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    $env:WINGHOSTTY_INTERACTIVE_RUN_FOREGROUND_HARNESS = $oldForeground
    if ($commit -and (Test-Path -LiteralPath $rawTranscriptPath)) {
        $redacted = Get-Content -LiteralPath $rawTranscriptPath -Raw
        foreach ($replacement in @(
            [pscustomobject]@{ Value = $repoRoot; Token = '<REPO>' }
            [pscustomobject]@{ Value = $env:USERPROFILE; Token = '<USERPROFILE>' }
            [pscustomobject]@{ Value = $env:TEMP; Token = '<TEMP>' }
        )) {
            if ($replacement.Value) { $redacted = $redacted.Replace([string]$replacement.Value, [string]$replacement.Token) }
        }
        Set-Content -LiteralPath $transcriptPath -Value $redacted -Encoding utf8
        Remove-Item -LiteralPath $rawTranscriptPath -Force
    }
    if ($status -eq 'pass') {
        . (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
        $perfLayout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName 'boo-performance'
        $render = Get-Content -LiteralPath (Join-Path $perfLayout.Temp 'interactive-win11-boo-performance-render.json') -Raw | ConvertFrom-Json
        $termio = Get-Content -LiteralPath (Join-Path $perfLayout.Temp 'interactive-win11-boo-performance-termio.json') -Raw | ConvertFrom-Json
        $boo = Get-Content -LiteralPath (Join-Path $perfLayout.Temp 'interactive-win11-boo-performance-boo.json') -Raw | ConvertFrom-Json
        $measurements = [ordered]@{
            paint_draw_count = [long]$render.paint_draw_count
            startup_window_ms = [long]$render.startup_window_ms
            startup_paint_gap_ceiling_ms = [long]$render.startup_paint_gap_ceiling_ms
            paint_gap_limit_ms = [long]$render.paint_gap_limit_ms
            paint_gap_over_limit_count = [long]$render.paint_gap_over_limit_count
            max_paint_gap_ms = [long]$render.max_paint_gap_ms
            max_sustained_paint_gap_ms = [long]$render.max_sustained_paint_gap_ms
            max_paint_draw_duration_ms = [long]$render.max_paint_draw_duration_ms
            process_output_count = [long]$termio.process_output_count
            max_process_output_gap_ms = [long]$termio.max_process_output_gap_ms
            frame_change_count = [long]$boo.frame_change_count
            rendered_byte_count = [long]$boo.rendered_byte_count
        }
        $performancePath = Join-Path $outputPath 'boo-performance.json'
        $measurements | ConvertTo-Json | Set-Content -LiteralPath $performancePath -Encoding utf8
        $performanceHash = (Get-FileHash -LiteralPath $performancePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $finished = [DateTimeOffset]::UtcNow
    $logHash = if ($commit -and (Test-Path -LiteralPath $transcriptPath)) {
        (Get-FileHash -LiteralPath $transcriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { $null }

    $result = [ordered]@{
        schema_version = 'winghostty.verification.result.v1'
        scenario_id = 'windows.interactive-win11.composite'
        status = $status
        started_at = $started.ToString('o')
        finished_at = $finished.ToString('o')
        duration_ms = [Math]::Max(0, [long]($finished - $started).TotalMilliseconds)
        baseline_commit = $null
        implementation_commit = $commit
        workflow_run_id = $(if ($env:GITHUB_RUN_ID) { [string]$env:GITHUB_RUN_ID } else { $null })
        workflow_run_attempt = $(if ($env:GITHUB_RUN_ATTEMPT) { [int]$env:GITHUB_RUN_ATTEMPT } else { $null })
        environment = [ordered]@{
            os = [System.Environment]::OSVersion.VersionString
            architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            ci = [bool]$env:CI
            interactive_desktop = $interactiveDesktop
            runner_name = $(if ($env:RUNNER_NAME) { [string]$env:RUNNER_NAME } else { $null })
            runner_environment = $(if ($env:RUNNER_ENVIRONMENT) { [string]$env:RUNNER_ENVIRONMENT } else { $null })
            runner_session_id = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        }
        measurements = $measurements
        assertions = @([ordered]@{
            id = 'composite-pass'
            status = $(if ($status -eq 'pass') { 'pass' } else { 'fail' })
            message = $(if ($failure) { $failure.message } else { $null })
        })
        artifacts = @(
            [ordered]@{ kind = 'log'; path = 'transcript.log'; sha256 = $logHash }
            [ordered]@{ kind = 'trace'; path = 'boo-performance.json'; sha256 = $performanceHash }
        )
        failure = $failure
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
    $resultJson = Get-Content -LiteralPath $resultPath -Raw
    if (-not ($resultJson | Test-Json -SchemaFile (Join-Path $PSScriptRoot 'result.schema.json'))) {
        throw 'Interactive suite emitted an invalid result contract.'
    }
    $scenario = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scenarios\interactive-win11.json') -Raw | ConvertFrom-Json
    $declaredAssertions = @($scenario.assertions | ForEach-Object id | Sort-Object)
    $emittedAssertions = @($result.assertions | ForEach-Object id | Sort-Object)
    if (($declaredAssertions -join "`n") -ne ($emittedAssertions -join "`n")) {
        throw 'Interactive result assertion set differs from the scenario contract.'
    }
    $declaredArtifacts = @($scenario.artifacts | Where-Object kind -ne 'result' | ForEach-Object { "$($_.kind)|$($_.path)" } | Sort-Object)
    $emittedArtifacts = @($result.artifacts | ForEach-Object { "$($_.kind)|$($_.path)" } | Sort-Object)
    if (($declaredArtifacts -join "`n") -ne ($emittedArtifacts -join "`n")) {
        throw 'Interactive result artifact set differs from the scenario contract.'
    }
}

if ($status -ne 'pass') {
    Get-Content -LiteralPath $transcriptPath -ErrorAction SilentlyContinue | Write-Host
    throw $failure.message
}

Get-Content -LiteralPath $transcriptPath | Write-Host
Write-Host "flagship interactive Win11 composite: PASS (artifacts=$outputPath)"
