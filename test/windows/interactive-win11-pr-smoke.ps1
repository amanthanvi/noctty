#requires -Version 7.0

[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($Rebuild) {
    $originalZigGlobalCache = $env:ZIG_GLOBAL_CACHE_DIR
    $originalZigLocalCache = $env:ZIG_LOCAL_CACHE_DIR
    try {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if ($attempt -eq 2 -and $env:RUNNER_TEMP) {
                $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $env:RUNNER_TEMP "zig-global-cache-pr-smoke-retry-$PID"
                $env:ZIG_LOCAL_CACHE_DIR = Join-Path $env:RUNNER_TEMP "zig-local-cache-pr-smoke-retry-$PID"
            }

            $buildOutput = @(& (Join-Path $repoRoot 'scripts\dev-windows.cmd') zig build -Demit-exe=true 2>&1)
            $buildExitCode = $LASTEXITCODE
            $buildOutput | ForEach-Object { Write-Host $_ }
            if ($buildExitCode -eq 0) { break }

            $buildText = $buildOutput -join "`n"
            $cacheHydrationMiss = $buildText -match 'FileNotFound' -and $buildText -match 'zig-global-cache'
            if ($attempt -eq 2 -or -not $cacheHydrationMiss) {
                throw "PR smoke build failed with exit code $buildExitCode."
            }
            Write-Warning 'PR smoke build hit a transient Zig package-cache miss; retrying once with fresh temp cache directories.'
        }
    }
    finally {
        $env:ZIG_GLOBAL_CACHE_DIR = $originalZigGlobalCache
        $env:ZIG_LOCAL_CACHE_DIR = $originalZigLocalCache
    }
}

$childPowerShell = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
if (-not $childPowerShell) {
    $childPowerShell = (Get-Process -Id $PID).Path
}

foreach ($harness in @(
    'interactive-win11-smoke.ps1',
    'interactive-win11-key-input.ps1',
    'interactive-win11-new-tab.ps1',
    'interactive-win11-resize.ps1',
    'interactive-win11-undo.ps1',
    'interactive-win11-accessibility.ps1',
    'interactive-win11-palette-theme.ps1',
    'interactive-win11-session-restore.ps1'
)) {
    $harnessArgs = @(
        '-NoLogo'
        '-NoProfile'
        '-File'
        (Join-Path $PSScriptRoot $harness)
    )
    if ($ResetState) { $harnessArgs += '-ResetState' }
    if ($harness -eq 'interactive-win11-undo.ps1') {
        $harnessArgs += @('-TimeoutSeconds', '35')
    }

    & $childPowerShell @harnessArgs
    if ($LASTEXITCODE -ne 0) { throw "$harness failed with exit code $LASTEXITCODE." }
}

Write-Host 'interactive Win11 PR smoke: PASS' -ForegroundColor Green
