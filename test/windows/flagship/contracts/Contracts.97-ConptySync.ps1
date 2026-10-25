# ConPTY sync harness contracts (PKG-13).
#
# interactive-win11-conpty-sync.ps1 needs a hidden desktop and a built noctty, so
# only the hosted conpty-sync workflow runs it. Two of its functions can be
# driven here with synthetic input, each in a runspace of its own with a
# deadline, after being pulled out of the script by AST: the process walk that
# finds the shell under noctty, and the console dump reader's retry. The third
# check pins how the workflow invokes the harness.

$conptySyncScript = Join-Path $repoRoot 'test\windows\interactive-win11-conpty-sync.ps1'
$conptySyncWorkflow = Join-Path $repoRoot '.github\workflows\conpty-sync.yml'
$conptySyncTokens = $null
$conptySyncErrors = $null
$conptySyncAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $conptySyncScript, [ref]$conptySyncTokens, [ref]$conptySyncErrors)
if ($conptySyncErrors.Count -ne 0) { throw "The ConPTY sync harness does not parse: $($conptySyncErrors[0].Message)" }

function Get-ConptySyncFunctionText {
    param([Parameter(Mandatory)] [string] $Name)

    $found = @($conptySyncAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true))
    if ($found.Count -ne 1) { throw "The ConPTY sync harness must define exactly one $Name, found $($found.Count)." }
    return $found[0].Extent.Text
}

# Runs a script block in a fresh runspace and returns its output, or throws if it
# has not finished by the deadline (the runspace is stopped first).
function Invoke-ConptySyncContractScript {
    param(
        [Parameter(Mandatory)] [scriptblock] $Script,
        [Parameter(Mandatory)] [object[]] $Arguments,
        [Parameter(Mandatory)] [string] $HangMessage,
        [int] $TimeoutSeconds = 20
    )

    $shell = [powershell]::Create()
    try {
        [void]$shell.AddScript($Script.ToString())
        foreach ($argument in $Arguments) { [void]$shell.AddArgument($argument) }
        $pending = $shell.BeginInvoke()
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
            $shell.Stop()
            throw $HangMessage
        }
        $output = $shell.EndInvoke($pending)
        # HadErrors is also set by an exception the script caught on purpose.
        if ($shell.Streams.Error.Count -gt 0) {
            $first = $shell.Streams.Error | Select-Object -First 1
            throw "The runspace reported $($shell.Streams.Error.Count) error(s), the first: $(($first | Out-String).Trim())"
        }
        return @($output)
    }
    finally { $shell.Dispose() }
}

# A process table in which Windows reused a number. noctty (100) took the number
# of an older process, so two older processes still name 100 as their parent
# (500 directly, 600 through 500), and noctty's own real parent is 600: the
# parent links form a cycle 100 -> 500 -> 600 -> 100. The real descendants are
# its cmd.exe (101) and that cmd.exe's conhost.exe (102). A walk that follows
# ParentProcessId alone spins forever; this is what hung 3 hosted runs.
$conptySyncStarted = [datetime]'2026-10-25T02:00:00Z'
$conptySyncProcessTable = @(
    [pscustomobject]@{ ProcessId = 100; ParentProcessId = 600; Name = 'noctty.exe'; CreationDate = $conptySyncStarted },
    [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = 'cmd.exe'; CreationDate = $conptySyncStarted.AddSeconds(1) },
    [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; Name = 'conhost.exe'; CreationDate = $conptySyncStarted.AddSeconds(2) },
    [pscustomobject]@{ ProcessId = 500; ParentProcessId = 100; Name = 'stale-a.exe'; CreationDate = $conptySyncStarted.AddHours(-1) },
    [pscustomobject]@{ ProcessId = 600; ParentProcessId = 500; Name = 'stale-b.exe'; CreationDate = $conptySyncStarted.AddHours(-1).AddSeconds(1) },
    [pscustomobject]@{ ProcessId = 700; ParentProcessId = 4; Name = 'other.exe'; CreationDate = $conptySyncStarted.AddHours(-2) }
)
$conptySyncWalk = {
    param($Table, $FunctionText)
    function Get-CimInstance { param($ClassName) $Table }
    . ([scriptblock]::Create($FunctionText))
    , @(Get-SyncDescendants 100 | ForEach-Object { [int]$_.ProcessId })
}
$conptySyncWalkText = Get-ConptySyncFunctionText 'Get-SyncDescendants'
$conptySyncIds = @(Invoke-ConptySyncContractScript `
        -Script $conptySyncWalk `
        -Arguments @($conptySyncProcessTable, $conptySyncWalkText) `
        -HangMessage 'Get-SyncDescendants did not return for a process table with a recycled parent PID: it cycles.' |
    ForEach-Object { $_ } | ForEach-Object { $_ } | Sort-Object)
if (($conptySyncIds -join ',') -ne '101,102') {
    throw "Get-SyncDescendants returned '$($conptySyncIds -join ',')' for a process table with a recycled parent PID; the real descendants are 101,102."
}

# The same cycle among processes that all carry one timestamp: the age rule
# cannot break it, so only visiting each process once ends the walk.
$conptySyncTiedTable = @(
    [pscustomobject]@{ ProcessId = 100; ParentProcessId = 600; Name = 'a.exe'; CreationDate = $conptySyncStarted },
    [pscustomobject]@{ ProcessId = 500; ParentProcessId = 100; Name = 'b.exe'; CreationDate = $conptySyncStarted },
    [pscustomobject]@{ ProcessId = 600; ParentProcessId = 500; Name = 'c.exe'; CreationDate = $conptySyncStarted }
)
$conptySyncTiedIds = @(Invoke-ConptySyncContractScript `
        -Script $conptySyncWalk `
        -Arguments @($conptySyncTiedTable, $conptySyncWalkText) `
        -HangMessage 'Get-SyncDescendants did not return for a parent cycle among processes with equal start times.' |
    ForEach-Object { $_ } | ForEach-Object { $_ } | Sort-Object)
if (($conptySyncTiedIds -join ',') -ne '500,600') {
    throw "Get-SyncDescendants returned '$($conptySyncTiedIds -join ',')' for a parent cycle among processes with equal start times; expected 500,600."
}

# Read-SyncConpty with a fake dump helper whose exit codes are scripted.
$conptySyncReadText = (Get-ConptySyncFunctionText 'Read-SyncConpty').Replace('[NocttyConptySyncNative]', '[ConptySyncContractDump]')
if ($conptySyncReadText -ceq (Get-ConptySyncFunctionText 'Read-SyncConpty')) {
    throw 'Read-SyncConpty no longer reaches the dump helper through [NocttyConptySyncNative]; update this contract.'
}
if (-not ('ConptySyncContractDump' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
public class ConptySyncContractProc {
    public int ExitCode;
    public bool WaitForExit(int ms) { return true; }
    public void Kill() { }
}
public static class ConptySyncContractDump {
    public static Queue<int> Codes = new Queue<int>();
    public static int Calls = 0;
    public static ConptySyncContractProc StartOnDesktop(string exe, string args, string cwd, string desktop) {
        Calls++;
        var path = Regex.Match(args, "\"([^\"]+)\"").Groups[1].Value;
        int code = Codes.Dequeue();
        File.WriteAllText(path, code == 0
            ? "BUFFER 80x20 WINDOW 0,0 80x20 CURSOR 1,2\nrow one\nrow two\n"
            : "BUFFER 80x11 WINDOW 0,0 80x11 CURSOR 5,10\nL1\nERROR ReadConsoleOutputW 1");
        return new ConptySyncContractProc { ExitCode = code };
    }
}
'@
}
$conptySyncRead = {
    param($FunctionText)
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('conpty-sync-contract-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $script:Work)
    $script:DumpExe = 'fake.exe'
    $DesktopName = 'fake'
    $script:Logged = New-Object System.Collections.Generic.List[string]
    function Write-SyncLog([string] $Message) { $script:Logged.Add($Message) }
    . ([scriptblock]::Create($FunctionText))
    $results = [ordered]@{}
    foreach ($case in @(
            @{ Name = 'clean'; Codes = @(0) }
            @{ Name = 'race twice'; Codes = @(7, 7, 0) }
            @{ Name = 'race forever'; Codes = @(7, 7, 7, 7, 7) }
            @{ Name = 'snapshot failure'; Codes = @(6, 0) }
            @{ Name = 'attach failure'; Codes = @(4, 0) }
            @{ Name = 'console failure'; Codes = @(5, 0) })) {
        [ConptySyncContractDump]::Codes.Clear()
        foreach ($code in $case.Codes) { [ConptySyncContractDump]::Codes.Enqueue($code) }
        [ConptySyncContractDump]::Calls = 0
        $script:Logged.Clear()
        $ok = $true
        $message = ''
        try { [void](Read-SyncConpty 1234) } catch { $ok = $false; $message = $_.Exception.Message }
        $results[$case.Name] = [pscustomobject]@{ Ok = $ok; Calls = [ConptySyncContractDump]::Calls; Logged = $script:Logged.Count; Message = $message }
    }
    Remove-Item -LiteralPath $script:Work -Recurse -Force
    $results
}
# @() keeps the one ordered dictionary from being indexed by position.
$conptySyncReadResults = @(Invoke-ConptySyncContractScript `
        -Script $conptySyncRead `
        -Arguments @($conptySyncReadText) `
        -HangMessage 'Read-SyncConpty did not return for a scripted dump helper.')[0]
$conptySyncExpected = [ordered]@{
    'clean'            = @{ Ok = $true; Calls = 1; Logged = 0 }
    'race twice'       = @{ Ok = $true; Calls = 3; Logged = 2 }
    'race forever'     = @{ Ok = $false; Calls = 4; Logged = 3 }
    'snapshot failure' = @{ Ok = $false; Calls = 1; Logged = 0 }
    'attach failure'   = @{ Ok = $false; Calls = 1; Logged = 0 }
    'console failure'  = @{ Ok = $false; Calls = 1; Logged = 0 }
}
foreach ($name in $conptySyncExpected.Keys) {
    $want = $conptySyncExpected[$name]
    $got = $conptySyncReadResults[$name]
    if ($got.Ok -ne $want.Ok -or $got.Calls -ne $want.Calls -or $got.Logged -ne $want.Logged) {
        throw "Read-SyncConpty '$name': expected ok=$($want.Ok) calls=$($want.Calls) logged=$($want.Logged), got ok=$($got.Ok) calls=$($got.Calls) logged=$($got.Logged) ($($got.Message))."
    }
}
if ($conptySyncReadResults['race forever'].Message -notmatch 'failed with 7 \(attempt 4\)') {
    throw 'Read-SyncConpty did not report the exit code and attempt number of a persistent failure.'
}

$conptySyncScriptText = Get-Content -LiteralPath $conptySyncScript -Raw
$conptySyncWorkflowText = Get-Content -LiteralPath $conptySyncWorkflow -Raw
Invoke-ContractTable -Contracts @(
    @{
        File = $conptySyncWorkflow
        Content = { $conptySyncWorkflowText }
        Pattern = '(?s)NOCTTY_INTERACTIVE_WIN11_CONPTY_SYNC_BOOTSTRAPPED: ''1''.*?interactive-win11-conpty-sync\.ps1 -NoBuild -RequireAll\b'
        Kind = 'Text'
        Description = 'the ConPTY sync workflow skips the dev-shell relaunch and fails a skipped scenario'
    }
    @{
        File = $conptySyncScript
        Content = { $conptySyncScriptText }
        Pattern = '(?s)\[switch\] \$RequireAll.*?if \(\$RequireAll\) \{ \$forwardedArgs \+= ''-RequireAll'' \}.*?elseif \(\$RequireAll -and \$r\.Status -eq ''SKIP''\)'
        Kind = 'Text'
        Description = 'the ConPTY sync harness forwards -RequireAll through its relaunch and fails a skipped scenario with it'
    }
)
