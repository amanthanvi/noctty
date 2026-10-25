param([Parameter(Mandatory)] [string] $Script, [int] $TimeoutSeconds = 6)
# Scratch test: Get-SyncDescendants against a process table with a recycled-PID cycle.
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "parse errors: $($errors[0].Message)" }
$fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-SyncDescendants' }, $true))
if ($fn.Count -ne 1) { throw "expected one Get-SyncDescendants, found $($fn.Count)" }

$t0 = [datetime]'2026-10-25T02:00:00'
$table = @(
    # the noctty under test (pid 100); its real parent, pid 600, is old
    [pscustomobject]@{ ProcessId = 100; ParentProcessId = 600; Name = 'noctty.exe'; CreationDate = $t0 }
    [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = 'cmd.exe'; CreationDate = $t0.AddSeconds(1) }
    [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; Name = 'conhost.exe'; CreationDate = $t0.AddSeconds(2) }
    # an older process whose recorded parent number (100) was recycled by noctty, and a second one under it
    [pscustomobject]@{ ProcessId = 500; ParentProcessId = 100; Name = 'stale-a.exe'; CreationDate = $t0.AddHours(-1) }
    [pscustomobject]@{ ProcessId = 600; ParentProcessId = 500; Name = 'stale-b.exe'; CreationDate = $t0.AddHours(-1).AddSeconds(1) }
    [pscustomobject]@{ ProcessId = 700; ParentProcessId = 4; Name = 'other.exe'; CreationDate = $t0.AddHours(-2) }
)

$ps = [powershell]::Create()
[void]$ps.AddScript({
    param($Table, $FunctionText)
    function Get-CimInstance { param($ClassName, $OperationTimeoutSec) $Table }
    . ([scriptblock]::Create($FunctionText))
    ,@(Get-SyncDescendants 100 | ForEach-Object { [int]$_.ProcessId })
}).AddArgument($table).AddArgument($fn[0].Extent.Text)
$async = $ps.BeginInvoke()
if ($async.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
    $out = $ps.EndInvoke($async)
    $ids = @($out | ForEach-Object { $_ } | ForEach-Object { $_ }) | Sort-Object
    "returned: $($ids -join ',')"
    if (($ids -join ',') -ne '101,102') { throw "wrong descendants: $($ids -join ',')" }
    "OK on PowerShell $($PSVersionTable.PSVersion)"
}
else {
    $ps.Stop()
    "HUNG: no result after $TimeoutSeconds s (the walk is cycling) on PowerShell $($PSVersionTable.PSVersion)"
    exit 3
}
$ps.Dispose()
