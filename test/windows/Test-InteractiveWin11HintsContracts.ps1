$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$harnessPath = Join-Path $repoRoot 'test\windows\interactive-win11-hints.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $harnessPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw ($parseErrors | ForEach-Object Message | Out-String)
}

$scenarioParameters = @($ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -eq 'Scenario'
    })
if ($scenarioParameters.Count -ne 1) {
    throw 'Hints harness must expose exactly one Scenario parameter.'
}
$validateSets = @($scenarioParameters[0].Attributes | Where-Object {
        $_ -is [System.Management.Automation.Language.AttributeAst] -and
            $_.TypeName.FullName -eq 'ValidateSet'
    })
$scenarioValues = if ($validateSets.Count -eq 1) {
    @($validateSets[0].PositionalArguments | ForEach-Object {
            if ($_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                throw 'Hints Scenario values must be static strings.'
            }
            $_.Value
        })
} else { @() }
if ((Compare-Object @('Full', 'UnsafePaste') $scenarioValues -SyncWindow 0)) {
    throw 'Hints Scenario must expose exactly Full and UnsafePaste.'
}

$planFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-HintsScenarioPlan'
        }, $true))
if ($planFunctions.Count -ne 1) {
    throw 'Hints harness must own exactly one scenario-plan function.'
}
try {
    . ([scriptblock]::Create($planFunctions[0].Extent.Text))
    $full = Get-HintsScenarioPlan -Name Full
    $unsafe = Get-HintsScenarioPlan -Name UnsafePaste
    if (-not $full.RunMain -or -not $full.RunUnsafePaste -or
        $full.SandboxName -ne 'hints' -or
        $full.ArtifactName -ne 'interactive-win11-hints.json') {
        throw 'Full scenario plan must retain both acceptance arms and its stable artifact.'
    }
    if ($unsafe.RunMain -or -not $unsafe.RunUnsafePaste -or
        $unsafe.SandboxName -ne 'hints-unsafe-paste' -or
        $unsafe.ArtifactName -ne 'interactive-win11-hints-unsafe-paste.json') {
        throw 'UnsafePaste scenario plan must isolate only the protected-paste arm.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-HintsScenarioPlan -ErrorAction SilentlyContinue
}

$scenarioBranches = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses.Count -eq 1 -and
                $node.Clauses[0].Item1.Extent.Text -match '^\$scenarioPlan\.(RunMain|RunUnsafePaste)$'
        }, $true))
$mainBranches = @($scenarioBranches | Where-Object {
        $_.Clauses[0].Item1.Extent.Text -eq '$scenarioPlan.RunMain'
    })
$unsafeBranches = @($scenarioBranches | Where-Object {
        $_.Clauses[0].Item1.Extent.Text -eq '$scenarioPlan.RunUnsafePaste'
    })
if ($mainBranches.Count -ne 1 -or
    $mainBranches[0].Clauses[0].Item2.Extent.Text -notmatch "Start-HintsScenario -Name 'main'") {
    throw 'RunMain must guard the main quick-select/copy-mode process.'
}
if ($unsafeBranches.Count -ne 1 -or
    $unsafeBranches[0].Clauses[0].Item2.Extent.Text -notmatch "Start-HintsScenario -Name 'unsafe-paste'") {
    throw 'RunUnsafePaste must guard the protected-paste process.'
}

$source = Get-Content -LiteralPath $harnessPath -Raw
if ($source -notmatch '''-Scenario'', \$Scenario' -or
    $source -notmatch '-SandboxName \$scenarioPlan\.SandboxName' -or
    $source -notmatch 'Join-Path \$layout\.Logs \$scenarioPlan\.ArtifactName') {
    throw 'Scenario selection must cross bootstrap, sandbox, and artifact boundaries.'
}
if (@([regex]::Matches($source, 'Write-HintsQuickSelectFailureDiagnostics')).Count -ne 3) {
    throw 'Both main quick-select waits must retain failure-only focus/key diagnostics.'
}

$inputFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-HintsInputEvents'
        }, $true))
if ($inputFunctions.Count -ne 1) {
    throw 'Hints harness must own exactly one input-event reader.'
}
$inputReaderSource = $inputFunctions[0].Extent.Text
if ($inputReaderSource -match '\bGet-Content\b' -or
    $inputReaderSource -notmatch '\[IO\.FileStream\]::new' -or
    $inputReaderSource -notmatch '\[IO\.FileShare\]::ReadWrite' -or
    $inputReaderSource -notmatch '\[IO\.FileShare\]::Delete') {
    throw 'Hints input reader must use a shared FileStream snapshot instead of Get-Content.'
}

if (-not ('HintsHeldInputWriterProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class HintsHeldInputWriterProbe : IDisposable {
    public sealed class ExclusiveLease {
        public readonly ManualResetEventSlim Ready = new ManualResetEventSlim(false);
        public Task Completion;
    }

    readonly FileStream stream;

    HintsHeldInputWriterProbe(FileStream stream) { this.stream = stream; }

    public static HintsHeldInputWriterProbe OpenShared(string path) {
        return new HintsHeldInputWriterProbe(new FileStream(
            path,
            FileMode.Create,
            FileAccess.Write,
            FileShare.ReadWrite | FileShare.Delete));
    }

    public static ExclusiveLease HoldExclusiveThenClose(string path, string text, int milliseconds) {
        ExclusiveLease lease = new ExclusiveLease();
        lease.Completion = Task.Run(() => {
            using (FileStream held = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None)) {
                byte[] bytes = new UTF8Encoding(false).GetBytes(text);
                held.Write(bytes, 0, bytes.Length);
                held.Flush(true);
                lease.Ready.Set();
                Thread.Sleep(milliseconds);
            }
        });
        return lease;
    }

    public void Write(string text) {
        byte[] bytes = new UTF8Encoding(false).GetBytes(text);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush(true);
    }

    public void Dispose() { stream.Dispose(); }
}
'@
}

$inputRoot = Join-Path ([IO.Path]::GetTempPath()) ('noctty-hints-input-contract-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $inputRoot)
$lease = $null
$sharedWriter = $null
try {
    . ([scriptblock]::Create($inputFunctions[0].Extent.Text))
    $inputPath = Join-Path $inputRoot 'events.jsonl'
    $eventA = '{"char":65,"key":"A","modifiers":""}'
    $lease = [HintsHeldInputWriterProbe]::HoldExclusiveThenClose($inputPath, "$eventA`r`n", 120)
    if (-not $lease.Ready.Wait(2000)) { throw 'Exclusive writer probe did not become ready.' }
    $events = @(Get-HintsInputEvents -Path $inputPath)
    $lease.Completion.Wait()
    if ($events.Count -ne 1 -or $events[0].char -ne 65) {
        throw 'Input reader must retry a transient writer-held sharing violation.'
    }

    $eventB = '{"char":66,"key":"B","modifiers":""}'
    $sharedWriter = [HintsHeldInputWriterProbe]::OpenShared($inputPath)
    $sharedWriter.Write("$eventA`r`n" + $eventB.Substring(0, 9))
    $events = @(Get-HintsInputEvents -Path $inputPath -MaxAttempts 3 -RetryDelayMilliseconds 5)
    if ($events.Count -ne 1 -or $events[0].char -ne 65) {
        throw 'Input reader must retain completed records while ignoring a bounded incomplete tail.'
    }
    $sharedWriter.Write($eventB.Substring(9) + "`r`n")
    $events = @(Get-HintsInputEvents -Path $inputPath)
    if ($events.Count -ne 2 -or $events[1].char -ne 66) {
        throw 'Input reader must observe a trailing record once its held writer completes it.'
    }
    $sharedWriter.Dispose()
    $sharedWriter = $null

    [IO.File]::WriteAllText(
        $inputPath,
        "$eventA`r`n{not-json}`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    $malformedFailed = $false
    try { [void](Get-HintsInputEvents -Path $inputPath) }
    catch {
        $malformedFailed = $_.Exception.Message -match 'Malformed completed hints input JSON at line 2'
    }
    if (-not $malformedFailed) {
        throw 'Input reader must fail hard on malformed completed JSONL records.'
    }
}
finally {
    if ($null -ne $lease) { $lease.Completion.Wait() }
    if ($null -ne $sharedWriter) { $sharedWriter.Dispose() }
    Remove-Item -LiteralPath Function:\Get-HintsInputEvents -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $inputRoot) {
        Remove-Item -LiteralPath $inputRoot -Recurse -Force
    }
}

Write-Host 'interactive-win11 hints static contracts: PASS'
