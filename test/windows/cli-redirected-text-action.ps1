param(
    [Parameter(Mandatory = $true)]
    [string] $Action,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedText,

    [int] $TimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
$exePath = Join-Path $repoRoot 'zig-out\bin\winghostty.exe'
$scratchDir = Join-Path $repoRoot 'zig-out\cli-redirected'
$actionSlug = $Action.TrimStart('+')
$actionSlug = $actionSlug -replace '[\\/:*?"<>|]', '_'
$actionSlug = $actionSlug.TrimEnd(' ', '.')
if ([string]::IsNullOrWhiteSpace($actionSlug)) {
    $actionSlug = 'action'
}
$stdoutPath = Join-Path $scratchDir "$actionSlug.stdout.txt"
$stderrPath = Join-Path $scratchDir "$actionSlug.stderr.txt"

if (-not (Test-Path $exePath)) {
    throw "Missing built executable: $exePath. Run `zig build -Demit-exe=true` first."
}

New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $Action `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "Redirected CLI action did not exit within ${TimeoutSeconds}s. A dialog or hung child likely blocked completion."
    }

    $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $process.Handle
    if ($exitCode -ne 0) {
        throw "Redirected CLI action should exit with code 0, got $exitCode."
    }

    $stdoutText = if (Test-Path $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { '' }
    $stderrText = if (Test-Path $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { '' }

    if (-not $stdoutText.Contains($ExpectedText)) {
        throw "Redirected CLI action stdout did not contain expected text '$ExpectedText'."
    }

    if ($stderrText.Length -ne 0) {
        throw "Redirected CLI action stderr should be empty, got: $stderrText"
    }
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}

Write-Host "redirected CLI action validation: PASS (action=$Action, expected=$ExpectedText)"
