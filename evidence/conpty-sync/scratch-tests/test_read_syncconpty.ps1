param([Parameter(Mandatory)] [string] $Script)
# Scratch test: Read-SyncConpty's retry, with a fake dump helper. Runs under pwsh 7 and powershell.exe 5.1.
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "parse errors: $($errors[0].Message)" }
$fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-SyncConpty' }, $true))
if ($fn.Count -ne 1) { throw "expected one Read-SyncConpty, found $($fn.Count)" }

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.IO; using System.Text.RegularExpressions;
public class FakeProc { public int ExitCode; public bool WaitForExit(int ms) { return true; } public void Kill() { } }
public static class NocttyConptySyncNative {
    public static Queue<int> Codes = new Queue<int>();
    public static int Calls = 0;
    public static FakeProc StartOnDesktop(string exe, string args, string cwd, string desktop) {
        Calls++;
        var m = Regex.Match(args, "\"([^\"]+)\"");
        int code = Codes.Dequeue();
        File.WriteAllText(m.Groups[1].Value, code == 0 ? "BUFFER 80x20 WINDOW 0,0 80x20 CURSOR 1,2\nrow one\nrow two\n" : "BUFFER 80x11 WINDOW 0,0 80x11 CURSOR 5,10\nL1\nERROR ReadConsoleOutputW 1");
        return new FakeProc { ExitCode = code };
    }
}
'@
$script:Work = Join-Path ([IO.Path]::GetTempPath()) ('rsc-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Work | Out-Null
$script:DumpExe = 'fake.exe'
$script:Logged = New-Object System.Collections.Generic.List[string]
function Write-SyncLog([string] $Message) { $script:Logged.Add($Message) }
$DesktopName = 'fake'
. ([scriptblock]::Create($fn[0].Extent.Text))

function Run-Case([int[]] $codes) {
    [NocttyConptySyncNative]::Codes.Clear()
    foreach ($c in $codes) { [NocttyConptySyncNative]::Codes.Enqueue($c) }
    [NocttyConptySyncNative]::Calls = 0
    $script:Logged.Clear()
    try { $r = Read-SyncConpty 1234; return @{ Ok = $true; Calls = [NocttyConptySyncNative]::Calls; Lines = $r.Lines.Count; Cursor = "$($r.CursorX),$($r.CursorY)"; Logged = $script:Logged.Count } }
    catch { return @{ Ok = $false; Calls = [NocttyConptySyncNative]::Calls; Message = $_.Exception.Message; Logged = $script:Logged.Count } }
}

$results = [ordered]@{}
$results['clean read'] = Run-Case @(0)
$results['7,7 then ok'] = Run-Case @(7, 7, 0)
$results['7 forever'] = Run-Case @(7, 7, 7, 7, 7)
$results['snapshot failure (6) is not retried'] = Run-Case @(6, 0)
$results['attach failure (4) is not retried'] = Run-Case @(4, 0)
$results['CONOUT$ failure (5) is not retried'] = Run-Case @(5, 0)
foreach ($k in $results.Keys) { $v = $results[$k]; "{0,-38} ok={1} calls={2} logged={3} {4}" -f $k, $v.Ok, $v.Calls, $v.Logged, $(if ($v.Ok) { "lines=$($v.Lines) cursor=$($v.Cursor)" } else { $v.Message.Substring(0, [Math]::Min(60, $v.Message.Length)) }) }
$bad = @()
if (-not ($results['clean read'].Ok -and $results['clean read'].Calls -eq 1 -and $results['clean read'].Logged -eq 0)) { $bad += 'clean' }
if (-not ($results['7,7 then ok'].Ok -and $results['7,7 then ok'].Calls -eq 3 -and $results['7,7 then ok'].Logged -eq 2)) { $bad += 'retry7-and-log' }
if (-not (-not $results['7 forever'].Ok -and $results['7 forever'].Calls -eq 4 -and $results['7 forever'].Logged -eq 3 -and $results['7 forever'].Message -match 'failed with 7 \(attempt 4\)')) { $bad += 'bounded' }
foreach ($k in 'snapshot failure (6) is not retried', 'attach failure (4) is not retried', 'CONOUT$ failure (5) is not retried') {
    if (-not (-not $results[$k].Ok -and $results[$k].Calls -eq 1 -and $results[$k].Logged -eq 0)) { $bad += "no-retry: $k" }
}
Remove-Item -LiteralPath $script:Work -Recurse -Force
if ($bad.Count) { throw "FAILED: $($bad -join ', ')" }
"ALL OK on PowerShell $($PSVersionTable.PSVersion)"
