# Scratch-only controls. This script never launches koreterm or reads real state.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\interactive-win11-state-guard.ps1')

function Assert-Control {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('koreterm-state-guard-contract-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$passed = 0
function New-Control {
    param([string] $Name, [scriptblock] $Reader = { [uint32] 17 })
    $root = Join-Path $scratch $Name
    $local = Join-Path $root 'local'
    $roaming = Join-Path $root 'roaming'
    $logs = Join-Path $root 'logs'
    $destinations = Join-Path $roaming 'Microsoft\Windows\Recent\CustomDestinations'
    New-Item -ItemType Directory -Force -Path (Join-Path $local 'koreterm'), $destinations, $logs | Out-Null
    $startup = Join-Path $local 'koreterm\startup-attempts.json'
    $product = Join-Path $destinations 'c2214d6ebc43ff3f.customDestinations-ms'
    [IO.File]::WriteAllText($startup, 'synthetic-startup')
    [IO.File]::WriteAllText($product, 'synthetic-product')
    return [pscustomobject]@{
        Root = $root; Local = $local; Roaming = $roaming; Logs = $logs
        Startup = $startup; Product = $product; Destinations = $destinations; Reader = $Reader
        Measure = Join-Path $destinations '251fcb42973017e3.customDestinations-ms'
    }
}
function Start-Control {
    param($Control)
    return Start-InteractiveWin11StateGuard -Harness 'scratch-state-control' -ReceiptDirectory $Control.Logs -LocalAppDataRoot $Control.Local -RoamingAppDataRoot $Control.Roaming -ClipboardSequenceReader $Control.Reader
}
function Assert-GuardFails {
    param($Guard, [string] $Expected)
    $message = ''
    try { Assert-InteractiveWin11StateGuard -Guard $Guard } catch { $message = $_.Exception.Message }
    Assert-Control ($message -like "*$Expected*") "Expected guard failure: $Expected"
}
try {
    $case = New-Control 'noop'
    $guard = Start-Control $case
    Assert-InteractiveWin11StateGuard $guard
    $receipt = Get-Content -LiteralPath (Join-Path $case.Logs 'state-after.json') -Raw | ConvertFrom-Json
    Assert-Control ($receipt.ClipboardBefore -eq 17 -and $receipt.ClipboardAfter -eq 17) 'No-op receipt lacks clipboard counters.'
    Assert-Control (Test-Path -LiteralPath (Join-Path $case.Logs 'state-before.json')) 'No-op lacks before receipt.'
    $passed++

    foreach ($name in @('Startup', 'Product')) {
        foreach ($kind in @('size', 'mtime')) {
            $case = New-Control "$name-$kind"
            $guard = Start-Control $case
            $path = $case.$name
            if ($kind -eq 'size') {
                $oldTime = [IO.File]::GetLastWriteTimeUtc($path)
                [IO.File]::AppendAllText($path, '-size-control')
                [IO.File]::SetLastWriteTimeUtc($path, $oldTime)
            } else {
                [IO.File]::SetLastWriteTimeUtc($path, [IO.File]::GetLastWriteTimeUtc($path).AddSeconds(-30))
            }
            $expected = if ($name -eq 'Product') { 'ProductJumpList metadata changed' } else { 'Startup metadata changed' }
            Assert-GuardFails $guard $expected
            $passed++
        }
    }

    $sequence = [pscustomobject]@{ Value = [uint32] 70 }
    $reader = { $sequence.Value }.GetNewClosure()
    $case = New-Control 'clipboard' $reader
    $guard = Start-Control $case
    $sequence.Value = [uint32] 71
    Assert-GuardFails $guard 'Clipboard sequence changed'
    $receipt = Get-Content -LiteralPath (Join-Path $case.Logs 'state-after.json') -Raw | ConvertFrom-Json
    Assert-Control ($receipt.ClipboardBefore -eq 70 -and $receipt.ClipboardAfter -eq 71) 'Changed clipboard counters not retained.'
    $passed++

    $case = New-Control 'created'
    $unrelated = Join-Path $case.Destinations 'unrelated.customDestinations-ms'
    $guard = Start-Control $case
    [IO.File]::WriteAllText($case.Measure, 'synthetic-measure')
    [IO.File]::WriteAllText($unrelated, 'synthetic-unrelated')
    Assert-InteractiveWin11StateGuard $guard
    Assert-Control (-not (Test-Path -LiteralPath $case.Measure)) 'Batch-created measurement file was not removed.'
    Assert-Control (Test-Path -LiteralPath $unrelated) 'An unrelated file was removed.'
    $receipt = Get-Content -LiteralPath (Join-Path $case.Logs 'state-after.json') -Raw | ConvertFrom-Json
    Assert-Control ($receipt.MeasureCleanup -eq 'removed-batch-created' -and $receipt.After.MeasureJumpList.CreationTimeUtc) 'Cleanup receipt lacks creation UTC.'
    $passed++

    $case = New-Control 'invariant-time'
    $guard = Start-Control $case
    [IO.File]::WriteAllText($case.Measure, 'synthetic-measure')
    $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ar-SA')
        Assert-InteractiveWin11StateGuard $guard
        Assert-Control (-not (Test-Path -LiteralPath $case.Measure)) 'Invariant timestamp cleanup failed under ar-SA.'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
    $passed++

    $case = New-Control 'preexisting'
    [IO.File]::WriteAllText($case.Measure, 'preexisting')
    $guard = Start-Control $case
    [IO.File]::AppendAllText($case.Measure, '-written-during-batch')
    Assert-InteractiveWin11StateGuard $guard
    Assert-Control (Test-Path -LiteralPath $case.Measure) 'Preexisting measurement file was removed.'
    $passed++

    foreach ($kind in @('creation', 'write')) {
        $case = New-Control "outside-$kind"
        $guard = Start-Control $case
        [IO.File]::WriteAllText($case.Measure, 'outside-interval')
        if ($kind -eq 'creation') { [IO.File]::SetCreationTimeUtc($case.Measure, [DateTime]::UtcNow.AddMinutes(-5)) }
        else { [IO.File]::SetLastWriteTimeUtc($case.Measure, [DateTime]::UtcNow.AddMinutes(-5)) }
        Assert-GuardFails $guard 'cleanup ownership is uncertain'
        Assert-Control (Test-Path -LiteralPath $case.Measure) 'Outside-interval measurement file was removed.'
        $passed++
    }

    # A finalizer failure must not skip the second protected file or clipboard.
    $case = New-Control 'multiple-failures'
    $guard = Start-Control $case
    [IO.File]::AppendAllText($case.Startup, 'changed')
    [IO.File]::AppendAllText($case.Product, 'changed')
    Assert-GuardFails $guard 'Startup metadata changed*ProductJumpList metadata changed'
    $passed++

    $case = New-Control 'reparse'
    $target = Join-Path $case.Root 'junction-target'
    $link = Join-Path $case.Local 'linked'
    New-Item -ItemType Directory -Path $target | Out-Null
    $junctionCreated = $false
    try { New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null; $junctionCreated = $true }
    catch { Write-Host 'state guard reparse control: SKIP (junction creation unavailable)' }
    if ($junctionCreated) {
        try {
            $message = ''
            try { Get-InteractiveWin11StateMetadata (Join-Path $link 'absent.json') | Out-Null } catch { $message = $_.Exception.Message }
            Assert-Control ($message -like '*reparse point*') 'Ancestor reparse path was accepted.'
            $passed++
        } finally { [IO.Directory]::Delete($link) }

        $guard = Start-Control $case
        New-Item -ItemType Junction -Path $case.Measure -Target $target -ErrorAction Stop | Out-Null
        try {
            Assert-GuardFails $guard 'MeasureJumpList metadata inspection failed*reparse point'
            Assert-Control (Test-Path -LiteralPath $case.Measure) 'Reparse measurement path was deleted.'
            Assert-Control (Test-Path -LiteralPath $target) 'Reparse target was deleted.'
            $passed++
        } finally { [IO.Directory]::Delete($case.Measure) }
    }

    # Execute only the composite's extracted finally block, with local stubs.
    # Parsing the composite does not execute its launch/build statements.
    $composite = Join-Path $PSScriptRoot 'interactive-win11-validate.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($composite, [ref]$tokens, [ref]$parseErrors)
    Assert-Control ($parseErrors.Count -eq 0) 'Composite parser errors.'
    $outer = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    Assert-Control ($outer.Count -eq 1) 'Expected one outer composite try/finally.'
    $body = $outer[0].Finally.Extent.Text
    $finalizer = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
    function Invoke-FinalizerControl {
        $windowsHarnessStateGuard = [pscustomobject]@{}
        $windowsHarnessHistoryGuard = [pscustomobject]@{}
        $originalMeasureAumid = $env:KORETERM_INTERACTIVE_MEASURE_AUMID
        $savedMeasureAumid = 'state-control-original'
        $env:KORETERM_INTERACTIVE_MEASURE_AUMID = '1'
        $called = [Collections.Generic.List[string]]::new()
        function Assert-InteractiveWin11StateGuard { param($Guard) $called.Add('state'); throw 'state-control-failure' }
        function Assert-WindowsHarnessHistoryGuard { param($Guard) $called.Add('history'); throw 'history-control-failure' }
        $message = ''
        try {
            try { & $finalizer } catch { $message = $_.Exception.Message }
            Assert-Control (($called -join ',') -eq 'state,history') 'Composite skipped a guard after a failure.'
            Assert-Control ($message -like '*state-control-failure*history-control-failure*') 'Composite lost a guard failure.'
            Assert-Control ($env:KORETERM_INTERACTIVE_MEASURE_AUMID -ceq $savedMeasureAumid) 'Composite did not restore measure environment.'
        } finally { $env:KORETERM_INTERACTIVE_MEASURE_AUMID = $originalMeasureAumid }
    }
    Invoke-FinalizerControl
    $passed++

    # The release job's driver: define its functions from the parsed file and
    # run them with every step replaced by a stub. Its main statement, the
    # composite and the leaves never run here: nothing is built or launched.
    $jobDriver = Join-Path $PSScriptRoot 'interactive-win11-job.ps1'
    $jobAst = [Management.Automation.Language.Parser]::ParseFile($jobDriver, [ref]$tokens, [ref]$parseErrors)
    Assert-Control ($parseErrors.Count -eq 0) 'Job driver parser errors.'
    foreach ($jobFunction in @('Get-InteractiveWin11JobPlan', 'Invoke-InteractiveWin11Job')) {
        $definitions = @($jobAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $jobFunction
        }, $true))
        Assert-Control ($definitions.Count -eq 1) "Job driver must define $jobFunction once."
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $plan = @(Get-InteractiveWin11JobPlan)
    Assert-Control ($plan.Count -ge 2 -and $plan[0].Script -ceq 'test\windows\flagship\Invoke-InteractiveWin11.ps1' -and
        $plan[0].Arguments.Rebuild -eq $true) 'The composite must build the measurement generation first.'
    foreach ($step in $plan) {
        Assert-Control (Test-Path -LiteralPath (Join-Path $repo $step.Script) -PathType Leaf) "Job step is missing: $($step.Script)"
        Assert-Control ([object]::ReferenceEquals($step, $plan[0]) -or -not $step.Arguments.ContainsKey('Rebuild')) "A leaf must reuse the composite's measurement build: $($step.Script)"
    }
    $passed++

    function Invoke-JobControl {
        param([string] $Name, [scriptblock[]] $Steps, [scriptblock] $Reader = { [uint32] 17 })
        $control = New-Control $Name $Reader
        $receiptPath = Join-Path $control.Root 'build.json'
        $seen = [Collections.Generic.List[string]]::new()
        function Get-InteractiveWin11MeasureLayout { param($RepoRoot) [pscustomobject]@{ Receipt = $receiptPath; Exe = (Join-Path $control.Root 'koreterm.exe') } }
        function Assert-InteractiveWin11MeasureBuild { param($RepoRoot, $ExePath) }
        function Invoke-InteractiveWin11JobStep {
            param($RepoRoot, $Step)
            $seen.Add([string] $env:KORETERM_INTERACTIVE_MEASURE_AUMID)
            & $Step.Action $control $receiptPath
        }
        $stepObjects = @($Steps | ForEach-Object { [pscustomobject]@{ Script = 'synthetic'; Arguments = @{}; Action = $_ } })
        $originalMeasureAumid = $env:KORETERM_INTERACTIVE_MEASURE_AUMID
        $env:KORETERM_INTERACTIVE_MEASURE_AUMID = 'job-control-original'
        $message = ''
        try {
            try {
                Invoke-InteractiveWin11Job -RepoRoot $control.Root -Plan $stepObjects -ReceiptDirectory $control.Logs -StateGuardArguments @{
                    LocalAppDataRoot = $control.Local; RoamingAppDataRoot = $control.Roaming; ClipboardSequenceReader = $control.Reader
                } | Out-Null
            } catch { $message = $_.Exception.Message }
            Assert-Control ($env:KORETERM_INTERACTIVE_MEASURE_AUMID -ceq 'job-control-original') "Job $Name did not restore the measure environment."
        } finally { $env:KORETERM_INTERACTIVE_MEASURE_AUMID = $originalMeasureAumid }
        Assert-Control (@($seen | Where-Object { $_ -cne '1' }).Count -eq 0) "Job $Name ran a step outside measurement mode."
        Assert-Control (Test-Path -LiteralPath (Join-Path $control.Logs 'state-after.json')) "Job $Name skipped its state guard."
        return [pscustomobject]@{ Message = $message; Steps = $seen.Count }
    }
    $writeGeneration = {
        param($Control, $ReceiptPath)
        [IO.File]::WriteAllText($ReceiptPath, (@{ Head = 'h'; ExeSHA256 = 'e'; CliSHA256 = 'c'; SourceReceiptSHA256 = 's'; BuildArguments = 'b' } | ConvertTo-Json))
    }
    $leaf = { param($Control, $ReceiptPath) }
    $result = Invoke-JobControl 'job-pass' @($writeGeneration, $leaf, $leaf)
    Assert-Control ($result.Message -eq '' -and $result.Steps -eq 3) "A clean job failed: $($result.Message)"
    $passed++

    # A leaf on a product-AUMID build rewrites the product jump list: the job fails.
    $result = Invoke-JobControl 'job-product-jump-list' @($writeGeneration, { param($Control, $ReceiptPath) [IO.File]::AppendAllText($Control.Product, '-leaf') }, $leaf)
    Assert-Control ($result.Message -like '*ProductJumpList metadata changed*' -and $result.Steps -eq 3) 'A product jump-list change did not fail the job.'
    $passed++

    # A failing leaf still runs the guard, and both failures are reported.
    $result = Invoke-JobControl 'job-leaf-failure' @($writeGeneration, { param($Control, $ReceiptPath) [IO.File]::AppendAllText($Control.Product, '-leaf'); throw 'leaf-control-failure' }, $leaf)
    Assert-Control ($result.Message -like '*leaf-control-failure*ProductJumpList metadata changed*' -and $result.Steps -eq 2) 'A failing leaf skipped the job guard or lost a failure.'
    $passed++

    # A leaf that rebuilt the measurement generation is not the composite's build.
    $result = Invoke-JobControl 'job-rebuilt' @($writeGeneration, { param($Control, $ReceiptPath) [IO.File]::WriteAllText($ReceiptPath, (@{ Head = 'h'; ExeSHA256 = 'other'; CliSHA256 = 'c'; SourceReceiptSHA256 = 's'; BuildArguments = 'b' } | ConvertTo-Json)) })
    Assert-Control ($result.Message -like '*measurement build changed after the composite (ExeSHA256)*') 'A rebuilt measurement generation was accepted.'
    $passed++

    # The real step runner against scratch leaves. A leaf reports failure the way
    # Invoke-InteractiveWin11HarnessMain does, with `exit` from a function of a
    # dot-sourced library: that sets $LASTEXITCODE and throws nothing, so the
    # step must turn it into a failure, and must not inherit an earlier code.
    $stepDefinitions = @($jobAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-InteractiveWin11JobStep'
    }, $true))
    Assert-Control ($stepDefinitions.Count -eq 1) 'Job driver must define Invoke-InteractiveWin11JobStep once.'
    $leafRoot = Join-Path $scratch 'job-step'
    New-Item -ItemType Directory -Path $leafRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $leafRoot 'leaf-lib.ps1'), 'function Invoke-LeafMain([int] $Code) { if ($Code -ne 0) { exit $Code } }')
    [IO.File]::WriteAllText((Join-Path $leafRoot 'leaf.ps1'), "param([int] `$Code = 0)`n. (Join-Path `$PSScriptRoot 'leaf-lib.ps1')`nInvoke-LeafMain `$Code`n")
    & {
        . ([scriptblock]::Create($stepDefinitions[0].Extent.Text))
        $outcomes = foreach ($stepCase in @(
                @{ Arguments = @{ Code = 3 }; Before = 0 }
                @{ Arguments = @{ Code = 0 }; Before = 7 }
                @{ Arguments = @{}; Before = 5 }
            )) {
            $global:LASTEXITCODE = $stepCase.Before
            try {
                Invoke-InteractiveWin11JobStep -RepoRoot $leafRoot -Step ([pscustomobject]@{ Script = 'leaf.ps1'; Arguments = $stepCase.Arguments })
                'pass'
            }
            catch { $_.Exception.Message }
        }
        $global:LASTEXITCODE = 0
        Assert-Control (($outcomes -join '|') -ceq 'leaf.ps1 failed with exit code 3.|pass|pass') "The job step runner lost a leaf's exit code: $($outcomes -join ' | ')"
    }
    $passed++
    Write-Host "interactive-win11 state guard contracts: PASS ($passed controls; scratch-only)"
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -cne $expectedParent -or [IO.Path]::GetFileName($resolved) -notlike 'koreterm-state-guard-contract-*') {
        throw 'Refusing unexpected scratch cleanup root.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
