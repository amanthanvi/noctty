[CmdletBinding()]
param()

# The Test workflow's windows-interactive job, the release evidence: the
# composite, then the standalone leaves. Every launch in the job runs the
# measure-AUMID build the composite makes (#492), because the Shell keeps a
# jump list per AUMID in the real profile, which a redirected APPDATA does not
# move: a product-AUMID build rewrote the maintainer's jump list on every
# evidence run. One state guard spans the whole job, so a change to the
# product jump list, the real startup-attempts.json or the clipboard sequence
# fails it (STANDALONE-LEAF-AUMID-01).

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'interactive-win11-job.ps1'
try {

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-measure-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-state-guard.ps1')

function Get-InteractiveWin11JobPlan {
    # The composite builds the measurement generation of HEAD; every leaf after
    # it reuses that build, so none of them passes -Rebuild.
    return @(
        [pscustomobject]@{ Script = 'test\windows\flagship\Invoke-InteractiveWin11.ps1'; Arguments = @{ Rebuild = $true; ResetState = $true; IncludeForegroundHarness = $true } }
        [pscustomobject]@{ Script = 'test\windows\interactive-win11-shaders.ps1'; Arguments = @{ ResetState = $true } }
        [pscustomobject]@{ Script = 'test\windows\interactive-win11-shader-pacing.ps1'; Arguments = @{ ResetState = $true } }
        [pscustomobject]@{ Script = 'test\windows\interactive-win11-accessibility.ps1'; Arguments = @{ ResetState = $true; TimeoutSeconds = 120; IdleSoakSeconds = 600 } }
        [pscustomobject]@{ Script = 'test\windows\interactive-win11-palette-theme.ps1'; Arguments = @{ ResetState = $true; ExerciseHighContrast = $true } }
        [pscustomobject]@{ Script = 'test\windows\interactive-win11-session-restore.ps1'; Arguments = @{ ResetState = $true } }
    )
}

function Invoke-InteractiveWin11JobStep {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] $Step)

    $arguments = $Step.Arguments
    $global:LASTEXITCODE = 0
    & (Join-Path $RepoRoot $Step.Script) @arguments
    if ($LASTEXITCODE -ne 0) { throw "$($Step.Script) failed with exit code $LASTEXITCODE." }
}

function Invoke-InteractiveWin11Job {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [object[]] $Plan,
        [Parameter(Mandatory)] [string] $ReceiptDirectory,
        # Scratch-only seams for the nonlaunching contract. Production omits them.
        [hashtable] $StateGuardArguments = @{}
    )

    $savedMeasureAumid = $env:KORETERM_INTERACTIVE_MEASURE_AUMID
    $stateGuard = $null
    $failures = [Collections.Generic.List[string]]::new()
    try {
        # Inherited by every leaf and its bootstrap, as in the composite.
        $env:KORETERM_INTERACTIVE_MEASURE_AUMID = '1'
        [void] [IO.Directory]::CreateDirectory($ReceiptDirectory)
        $stateGuard = Start-InteractiveWin11StateGuard -Harness 'interactive-win11-job.ps1' -ReceiptDirectory $ReceiptDirectory @StateGuardArguments
        $layout = Get-InteractiveWin11MeasureLayout $RepoRoot
        $generation = $null
        foreach ($step in $Plan) {
            Invoke-InteractiveWin11JobStep -RepoRoot $RepoRoot -Step $step
            if ($null -eq $generation) { $generation = Get-Content -LiteralPath $layout.Receipt -Raw | ConvertFrom-Json }
        }
        # Each leaf validated the receipt when it started; this proves they all
        # ran the generation the composite built and checked.
        Assert-InteractiveWin11MeasureBuild -RepoRoot $RepoRoot -ExePath $layout.Exe
        $final = Get-Content -LiteralPath $layout.Receipt -Raw | ConvertFrom-Json
        foreach ($name in @('Head', 'ExeSHA256', 'CliSHA256', 'SourceReceiptSHA256', 'BuildArguments')) {
            if ($final.$name -cne $generation.$name) { throw "The measurement build changed after the composite ($name)." }
        }
        Write-Host "interactive-win11 job: $($Plan.Count) steps on measurement build $($final.ExeSHA256) (HEAD $($final.Head); $($final.BuildArguments))"
    }
    catch { $failures.Add($_.Exception.Message) }
    finally {
        $env:KORETERM_INTERACTIVE_MEASURE_AUMID = $savedMeasureAumid
        if ($null -ne $stateGuard) {
            try { Assert-InteractiveWin11StateGuard -Guard $stateGuard }
            catch { $failures.Add($_.Exception.Message) }
        }
    }
    if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
}

Invoke-InteractiveWin11Job `
    -RepoRoot $repoRoot `
    -Plan (Get-InteractiveWin11JobPlan) `
    -ReceiptDirectory (Join-Path $repoRoot 'test\windows\flagship\artifacts\interactive-win11\job-state')
Write-Host 'interactive-win11 job: PASS'

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
