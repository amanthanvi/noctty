# ConPTY reply-path harness contracts (the kitty report's shortlist #0).
#
# hidden-win11-conpty-reply-path.ps1 needs a private desktop and a built noctty,
# so nothing runs it here. Pinned instead: what it may do (private desktop,
# portable copy, pinned command, isolated PSReadLine history, a loopback-only
# one-connection sshd), that its control bytes agree with the reader's, and
# its analysis, driven with synthetic reader logs after being pulled out of
# the script by AST.

$replyPathScript = Join-Path $repoRoot 'test\windows\hidden-win11-conpty-reply-path.ps1'
$replyPathReader = Join-Path $repoRoot 'test\windows\console-reply-reader.c'
$replyPathTokens = $null
$replyPathErrors = $null
$replyPathAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $replyPathScript, [ref]$replyPathTokens, [ref]$replyPathErrors)
if ($replyPathErrors.Count -ne 0) { throw "The ConPTY reply-path harness does not parse: $($replyPathErrors[0].Message)" }

# The script without its comments, so a comment cannot satisfy or trip a pattern.
$replyPathBuilder = [Text.StringBuilder]::new((Get-Content -LiteralPath $replyPathScript -Raw))
foreach ($replyPathToken in @($replyPathTokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    [void]$replyPathBuilder.Remove($replyPathToken.Extent.StartOffset, $replyPathToken.Extent.EndOffset - $replyPathToken.Extent.StartOffset)
}
$replyPathCode = $replyPathBuilder.ToString()

function Get-ReplyPathFunctionText {
    param([Parameter(Mandatory)] [string] $Name)

    $found = @($replyPathAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true))
    if ($found.Count -ne 1) { throw "The ConPTY reply-path harness must define exactly one $Name, found $($found.Count)." }
    return $found[0].Extent.Text
}

$replyPathContracts = @(
    @{
        File = $replyPathScript
        Content = { $replyPathCode }
        Pattern = '(?s)\A(?!.*(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|Set-Clipboard|Get-Clipboard|SetClipboardData|OpenClipboard|Start-Process|Invoke-Item|Remove-Item\s+-Recurse))'
        Kind = 'Text'
        Description = 'the reply-path harness uses no real input, foreground, clipboard, Start-Process or recursive delete'
    }
    @{
        File = $replyPathScript
        Content = { $replyPathCode }
        Pattern = '(?s)\$driverDesktop\.StartsWith\(''noctty-replypath-''.*?throw.*?noctty\.portable.*?throw.*?AppData isolation failed'
        Kind = 'Text'
        Description = 'the driver refuses to run off its private desktop, without the portable marker or without both AppData roots inside the run'
    }
    @{
        File = $replyPathScript
        Content = { $replyPathCode }
        Pattern = '(?s)Start-WindowsHarnessHistoryGuard.*?Assert-WindowsHarnessHistoryGuard.*?Real startup state changed'
        Kind = 'Text'
        Description = 'the real PowerShell history and startup ledger are checked after the run'
    }
    @{
        File = $replyPathScript
        Content = { $replyPathCode }
        Pattern = '(?s)Set-PSReadLineOption -HistorySavePath ''\$shellHistory'' -HistorySaveStyle SaveNothing; if\(\(Get-PSReadLineOption\)\.HistorySaveStyle -eq ''SaveNothing'' -and \(Get-PSReadLineOption\)\.HistorySavePath -ceq ''\$shellHistory''\).*?\$shellReady.*?did not become ready \(history isolation not confirmed\); nothing typed'
        Kind = 'Text'
        Description = 'PSReadLine reads back SaveNothing and the run-local history path before the harness types anything'
    }
    @{
        File = $replyPathScript
        Content = { $replyPathCode }
        Pattern = '(?s)''ListenAddress 127\.0\.0\.1''.*?''PasswordAuthentication no''.*?sshd\.exe''\),\(''"\{0\}" -d -f'
        Kind = 'Text'
        Description = 'reader d''s sshd listens on loopback only, takes keys only, and serves one connection (-d)'
    }
)
Invoke-ContractTable -Contracts $replyPathContracts

# Every noctty launch pins the shell for later tabs and never saves window state.
$replyPathLaunches = [regex]::Matches($replyPathCode, '--config-file="\{1\}"[^'']*')
if ($replyPathLaunches.Count -lt 3) { throw "Expected at least three noctty launch command lines in the reply-path harness, found $($replyPathLaunches.Count)." }
foreach ($replyPathLaunch in $replyPathLaunches) {
    if ($replyPathLaunch.Value -notmatch '--window-save-state=never --command=cmd\.exe') {
        throw "A reply-path noctty launch lacks --window-save-state=never --command=cmd.exe: $($replyPathLaunch.Value)"
    }
}

# The control bytes: the bindings' single C0 bytes, the reader's command codes
# and the analysis's skip list are one set.
$replyPathC = Get-Content -LiteralPath $replyPathReader -Raw
$replyPathReaderCodes = @([regex]::Matches($replyPathC, 'case 0x([0-9A-Fa-f]{2}):') | ForEach-Object { [Convert]::ToInt32($_.Groups[1].Value, 16) } | Sort-Object -Unique)
$replyPathBindingCodes = @([regex]::Matches($replyPathCode, 'Bytes="\$\(\[char\](\d+)\)"') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
$replyPathSkipMatch = [regex]::Match($replyPathCode, '\$control=@\(([0-9,]+)\)')
if (-not $replyPathSkipMatch.Success) { throw 'The reply-path analysis has no control-unit list.' }
$replyPathSkipCodes = @($replyPathSkipMatch.Groups[1].Value.Split(',') | ForEach-Object { [int]$_ } | Sort-Object -Unique)
if (($replyPathReaderCodes -join ',') -ne ($replyPathBindingCodes -join ',') -or ($replyPathReaderCodes -join ',') -ne ($replyPathSkipCodes -join ',')) {
    throw "Reply-path control bytes disagree: reader $($replyPathReaderCodes -join ','), bindings $($replyPathBindingCodes -join ','), analysis $($replyPathSkipCodes -join ',')."
}

# The analysis, on synthetic logs: a record reader (b, VT input off) whose
# APC came back as Alt+\ and a byte reader (c) whose split APC lost its ESC.
$replyPathAnalysis = {
    param($Functions)
    foreach ($text in $Functions) { . ([scriptblock]::Create($text)) }
    $replyPathEsc = [char]27
    $line = Binding-Line 'f9' "${replyPathEsc}_Gi=31;E:x y${replyPathEsc}\"
    $records = @{ Mode = 'b'; Log = @(
            'READ,1,4', 'KEY,1,1,17,29,0,8', 'KEY,1,1,66,48,2,8', 'KEY,0,1,66,48,2,8', 'KEY,0,1,17,29,0,0', 'CMD,2,02,',
            'READ,3,4', 'KEY,1,1,18,56,0,2', 'KEY,1,1,220,43,92,2', 'KEY,0,1,220,43,92,2', 'KEY,0,1,18,56,0,0',
            'READ,4,1', 'KEY,1,1,66,48,2,8', 'CMD,5,02,') }
    $bytes = @{ Mode = 'c'; Log = @('PEEK,1,1', 'BYTES,1,1,04', 'CMD,1,04,1b5b63', 'PEEK,2,11', 'BYTES,2,11,5f47693d33313b4f4b1b5c', 'PEEK,3,1', 'BYTES,3,1,02', 'CMD,3,02,') }
    $recordSegments = Get-Segments $records
    $byteSegments = Get-Segments $bytes
    [pscustomobject]@{
        Line = $line
        RecordSegments = $recordSegments.Count
        RecordSecond = $recordSegments[1].Units.ToString()
        ByteFirst = $byteSegments[0].Units.ToString()
        ByteCommands = $byteSegments[0].Commands.Count
        PredictB = (Get-Prediction 'case 1: APC OK, one write' 'b' "${replyPathEsc}_Gi=31;OK${replyPathEsc}\").Exact
        PredictSplit = (Get-Prediction 'case 1: APC OK, split ESC|_' 'c' "${replyPathEsc}_Gi=31;OK${replyPathEsc}\").Exact
        PredictCsiB = (Get-Prediction 'case 3: 2033 report, visible' 'b' "${replyPathEsc}[?999;1n").Text
        PredictInboxOsc = (Get-Prediction 'case 6: OSC 11 (before)' 'd' '').Exact
    }
}
$replyPathResult = @(Invoke-ContractScriptWithDeadline `
        -Script $replyPathAnalysis `
        -Arguments @(, @((Get-ReplyPathFunctionText 'Binding-Line'), (Get-ReplyPathFunctionText 'Get-Segments'), (Get-ReplyPathFunctionText 'Get-Prediction'))) `
        -HangMessage 'The reply-path analysis did not return for a synthetic log.')[0]
$replyPathEsc = [char]27
if ($replyPathResult.Line -cne 'keybind = f9=text:\x1b\x5f\x47\x69\x3d\x33\x31\x3b\x45\x3a\x78\x20\x79\x1b\x5c') {
    throw "Binding-Line must write every reply byte as \xNN; it wrote '$($replyPathResult.Line)'."
}
if ($replyPathResult.RecordSegments -ne 2 -or $replyPathResult.RecordSecond -cne '\') {
    throw "Get-Segments must split a record log at its delimiters and keep only key-down characters other than the controls; it found $($replyPathResult.RecordSegments) segments and '$($replyPathResult.RecordSecond)'."
}
if ($replyPathResult.ByteFirst -cne "_Gi=31;OK${replyPathEsc}\" -or $replyPathResult.ByteCommands -ne 1) {
    throw 'Get-Segments must keep a byte reader''s bytes, without its control bytes, and record the command it ran.'
}
if ($replyPathResult.PredictB -cne '\' -or $replyPathResult.PredictSplit -cne "_Gi=31;OK${replyPathEsc}\" -or
    $replyPathResult.PredictCsiB -cne 'whole, as typed text' -or $replyPathResult.PredictInboxOsc -cne '') {
    throw 'Get-Prediction no longer states the kitty report''s source predictions (APC on b, the ESC|_ split, CSI on b, OSC 11 behind the in-box conhost).'
}
