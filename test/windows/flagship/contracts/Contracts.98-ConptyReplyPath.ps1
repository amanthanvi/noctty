# ConPTY reply-path harness contracts (the kitty report's shortlist #0).
#
# hidden-win11-conpty-reply-path.ps1 needs a private desktop and a built noctty,
# so nothing runs it here. Get-ReplyPathProblems pins it instead:
#   - what it may do: every launch on the private desktop and in the run's job,
#     suspended until assigned; keys posted only to a window on that desktop;
#     a portable copy without noctty.ico; case 7's pwsh with -NoProfile and its
#     history read back first; readers d and d-notiming opt-in only, with their
#     ssh client and sshd hardened; the startup-ledger, history, AUMID-key and
#     clipboard comparisons;
#   - what it measures: every binding's bytes, the step plan, the predictions
#     and which rows are positive controls, the verdicts, the reader-state
#     checks and the exit policy, driven by AST extraction on synthetic inputs;
#   - how its result is wired: every exit statement in order, every assignment
#     to a guard, exit or case-7 control variable;
#   - as a closed set, by SHA-256 with LF line ends: the whole harness and the
#     whole reader ($replyPathHarnessPin, $replyPathReaderPin). An edit anywhere
#     in either fails this contract until its pin here is updated in the same
#     change, so the reviewer sees each one. The regions between
#     `# pin-begin:` and `# pin-end:` comments (the reader list, the whole
#     outer phase, case 7, the driver's results) and the functions in
#     $replyPathFunctionPins are pinned again, so a failure also names the
#     block that changed. Not pinned here, since other harnesses share them:
#     console-attach-info.c (case 7's prompt reader),
#     scripts\windows-harness-history.ps1 (its guard decides exit 3's history
#     branch) and scripts\dev-windows.cmd (the helper compile, exit 2).
# The contract then applies the council's mutations from rounds 1-6 (and its
# own) to the harness and the reader. Each must give a problem, and, through
# the pins, the whole-file pin's problem and that of every pinned region or
# function the mutation changes. Unless it is marked PinOnly, a run with the
# pins skipped (-SkipPins) must refuse it too: so each such mutation is shown
# to be refused by some content check, not by a pin alone. That does not show
# every content check is exercised. A PinOnly mutation must get nothing from
# the content checks, so the mark stays true; an entry with Check must be
# refused by the content check whose problem starts with that text.

$replyPathScript = Join-Path $repoRoot 'test\windows\hidden-win11-conpty-reply-path.ps1'
$replyPathReader = Join-Path $repoRoot 'test\windows\console-reply-reader.c'

# The pins, by SHA-256 with LF line ends. A change to the harness or the reader must update its pin
# here, on purpose, in the same change.
$replyPathHarnessPin = '8E0B76D2E8474B69F3E731C7F00AA450DAFDE19D9D02991CFA589C038233AF1C'
$replyPathReaderPin = '58AE918EBB70275F906043F2093E27ECE2410A9A885FD1D8063AB8152FDE1C86'
$replyPathRegionPins = [ordered]@{
    'reader-list' = '9E5CB8938C4BEA431C33149E32A793E92567904865F64FC6FB5933FCE553F942'
    'outer-run' = 'CED0B24BD4A4164538C1C2A293F5A182007C1F34F034DAF0EE4C6A5C2A51E339'
    'case-7' = 'E2C4B68078D36D0F1AC3B2082783F0AC9E9D9FB5481B93173DD9C48EF64FE904'
    'driver-results' = '8398372CF4B302FE3560D39C2C24C6F145ABDD90D2797D7BE83F7238D4CA0B24'
}
$replyPathFunctionPins = [ordered]@{
    'Startup-Fingerprint' = '428312CE8A516CD82051CC64ABFB2400B5270440636283E0940EA1571272E84A'
    'Aumid-Fingerprint' = '72A98C045416F788C4EAA9ACD2E4D3ECA1B0CC0D2A8DCCE0566E04F0FD757220'
    'Get-PlannedSteps' = 'EB0D20B78CD38D490CB6E66580B296ED10C245158E586405BFDCD61CB56476F2'
    'Read-Log' = '042B0B922955FFA1BE38F9B75823A925A7C4AAA22301A66DB4CFD3ABDB522631'
    'Delimiters' = 'FB18706C2359BB0FBEE037A4D4605ABB1D080AE55EF492A56CC23802AA24C95C'
    'Wait-Ready' = '21759327C7C7875427A99456403A0AC7C7DAF622C725C3EE1075638A61B72CF3'
    'Invoke-ReaderSession' = '27E9C4983B9F70DF0F43FEF49FD7A2AE5FB44C362950EB26A441866AF7948F8A'
    'Get-ReaderStateProblems' = '6E518B13B31F4B5FA306499A27A52AFCE7D4B225D740140C83E123682B569D95'
    'Get-Segments' = '6185E4EC4F567726CE54703AC1F5F4CAFC9E3798EA73CD73B22688D6525240B7'
    'Get-Prediction' = 'ADA5A9CACC21FB044994013F9006520E784514E2A9430B41893E872407726A3A'
    'Get-Verdict' = '9C3EA7D71286F1EC81CA0A5CD08974F6E0E01B8DF2A2ABB0056F6C8F4F19DE93'
    'Get-RunExit' = '8EDA51E33F1186A6403BD1359DD2AB071786BE6C8D298A99D5C943BF782C94A7'
}

function Get-ReplyPathProblems {
    param(
        [Parameter(Mandatory)] [string] $Harness,
        [Parameter(Mandatory)] [string] $Reader,
        # For mutations: one static problem is enough, so the evaluated checks are skipped.
        [switch] $StopAtFirst,
        # For mutations: the content checks alone, without the file, region and function pins.
        [switch] $SkipPins
    )
    $problems = [Collections.Generic.List[string]]::new()
    $Harness = $Harness -replace "`r`n", "`n"; $Reader = $Reader -replace "`r`n", "`n"
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Harness, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { $problems.Add("the harness does not parse: $($errors[0].Message)"); return $problems.ToArray() }
    $builder = [Text.StringBuilder]::new($Harness)
    foreach ($token in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        [void]$builder.Remove($token.Extent.StartOffset, $token.Extent.EndOffset - $token.Extent.StartOffset)
    }
    $code = $builder.ToString()
    function Need([string] $Literal, [string] $What) { if (-not $code.Contains($Literal)) { $problems.Add($What) } }
    function NeedCount([string] $Literal, [int] $Count, [string] $What) {
        $found = ([regex]::Matches($code, [regex]::Escape($Literal))).Count
        if ($found -ne $Count) { $problems.Add("$What (found $found, expected $Count)") }
    }

    # No real input, foreground, clipboard access, Start-Process or recursive delete.
    if ($code -match '(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|Set-Clipboard|Get-Clipboard|SetClipboardData|OpenClipboard|GetClipboardData|Start-Process|Stop-Process|taskkill|Invoke-Item|Remove-Item\s+-Recurse)') {
        $problems.Add("forbidden call: $($Matches[0])")
    }

    # Every launch names its desktop and its job; the compiler is the only one without a desktop.
    $launches = @($ast.FindAll({
                param($n)
                $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $n.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                $n.Expression.TypeName.Name -eq 'ReplyPath' -and $n.Member.Value -eq 'Launch'
            }, $true))
    $byDesktop = @{}
    foreach ($launch in $launches) {
        $arguments = @($launch.Arguments)
        if ($arguments.Count -ne 6) { $problems.Add("a Launch call has $($arguments.Count) arguments"); continue }
        $desktop = $arguments[3].Extent.Text; $jobArgument = $arguments[4].Extent.Text
        $byDesktop[$desktop] = 1 + [int]$byDesktop[$desktop]
        switch -CaseSensitive ($desktop) {
            '$null' { if ($arguments[0].Extent.Text -cne '$cmdExe' -or $jobArgument -ne '$compileJob') { $problems.Add('only the compiler may launch without a desktop, in its own job') } }
            '"WinSta0\$desktopName"' { if ($jobArgument -ne '$job') { $problems.Add('the driver launch is not in the run''s job') } }
            '"WinSta0\$driverDesktop"' { if ($jobArgument -ne '$job') { $problems.Add("a driver launch is not in the run's job: $($launch.Extent.Text)") } }
            default { $problems.Add("a launch names another desktop: $desktop") }
        }
    }
    if ([int]$byDesktop['$null'] -ne 1) { $problems.Add("launches without a desktop: $([int]$byDesktop['$null']), expected the compiler's alone") }
    if ([int]$byDesktop['"WinSta0\$desktopName"'] -ne 1) { $problems.Add('the driver is not launched once on the run''s desktop') }
    if ([int]$byDesktop['"WinSta0\$driverDesktop"'] -ne 5) { $problems.Add("launches on the driver's desktop: $([int]$byDesktop['"WinSta0\$driverDesktop"']), expected 5 (sshd, the reader session's noctty, the ssh console probe, case 7's noctty, the screen reader)") }

    # The native launch: suspended, assigned to the job, then resumed; a named desktop; keys only on this desktop.
    Need 'if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,flags|0x4004,IntPtr.Zero,cwd,ref s,out p))' 'the native launch is no longer created suspended (0x4004) without inherited handles'
    Need 'if(!AssignProcessToJobObject(job,p.process)||ResumeThread(p.thread)==0xFFFFFFFF) {' 'the native launch no longer assigns the job before resuming'
    Need 'var s=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 };' 'the native launch no longer passes the desktop hidden'
    if ($code -notmatch 'public static void Keys\(IntPtr h,uint target,Stroke\[\] strokes,int strokeGapMs,int holdMs\) \{\s*if\(!OnCallerDesktop\(h\)\) throw') { $problems.Add('Keys no longer refuses a window off the private desktop') }
    NeedCount 'if(-not [ReplyPath]::OnCallerDesktop($surface)) { throw' 2 'the reader session and case 7 must each check the surface is on the private desktop'
    Need 'if(-not $driverDesktop.StartsWith(''noctty-replypath-'',[StringComparison]::Ordinal)) { throw' 'the driver no longer refuses to run off its private desktop'
    Need 'if(-not (Test-Path -LiteralPath (Join-Path $Bin ''noctty.portable''))) { throw' 'the driver no longer requires the portable marker'
    Need 'throw ''Driver AppData isolation failed.''' 'the driver no longer checks both AppData roots'

    # Persistent state: no icon beside the copy; ledger, history, AUMID key and clipboard compared.
    Need 'Where-Object { $_.Name -ne ''noctty.ico'' }' 'the portable copy may take noctty.ico'
    Need 'if(Test-Path -LiteralPath (Join-Path $Bin ''noctty.ico'')) { throw' 'the driver no longer refuses a copy with noctty.ico'
    Need '$unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified' 'the startup-ledger comparison changed'
    Need 'try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard }' 'the history guard is not asserted'
    Need '$aumidUnchanged=($aumidBefore.Keys -join ''|'') -ceq ($aumidAfter.Keys -join ''|'') -and $aumidBefore.Sha256 -ceq $aumidAfter.Sha256' 'the AUMID key comparison changed'
    Need '$clipboardUnchanged=$clipboardBefore -eq $clipboardAfter' 'the clipboard sequence comparison changed'
    Need '$clipboardBefore=[ReplyPath]::GetClipboardSequenceNumber()' 'the clipboard sequence number is not read before the run'
    Need 'if(-not $keysDeleted -or $links.Count -gt 0 -or ($guardsRead -and ($historyFailure -or -not $unchanged -or -not $aumidUnchanged -or -not $clipboardUnchanged))) {' 'a changed guard no longer stops the run'
    if ($code -notmatch '(?s)-not \$clipboardUnchanged\)\)\) \{\s*\$compared=[^\n]*\n\s*Write-Host \(''ISOLATION GUARD CHANGED:[^\n]*\n\s*exit 3\s*\}') { $problems.Add('a changed guard no longer exits 3') }
    # The ssh keys are made inside the try whose finally deletes them, so every exit path deletes them.
    if ($code -notmatch '(?s)\[uint32\]\$code=2; \$guardsRead=\$false; \$keyHold=\$null\s*try \{\s*if\(\$sshReaders\.Count -gt 0\) \{.*?ssh-keygen\.exe.*?if\(\$Sabotage -eq ''setup''\) \{ throw .*?\} finally \{.*?foreach\(\$name in \$sshSecrets\)') {
        $problems.Add('the ssh keys are no longer made inside the try whose finally deletes them')
    }

    # How the result is wired: every exit statement, in source order.
    $exits = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true) | ForEach-Object { $_.Extent.Text })
    $exitsWanted = @('exit 2', 'exit 2', 'exit 0', 'exit 3', 'exit 2', 'exit 0', 'exit 1', 'exit 2', 'exit $exit.Code')
    if (-not [string]::Equals(($exits -join ' | '), ($exitsWanted -join ' | '), [StringComparison]::Ordinal)) {
        $problems.Add("the exit statements are '$($exits -join ' | ')' where '$($exitsWanted -join ' | ')' are pinned (trap outer, trap driver, compile-only, guards, cleanup, complete, incomplete, infrastructure, driver)")
    }
    Need '    if(-not $Driver) { Write-Host "Infrastructure: $($_.Exception.Message)"; exit 2 }' 'an outer-phase failure no longer exits 2'
    Need '        0 { Write-Host "ConPTY reply-path harness: COMPLETE; see $(Join-Path $Run ''results.md'')."; exit 0 }' 'the outer''s exit 0 branch changed'
    Need '        1 { Write-Host "ConPTY reply-path harness: INCOMPLETE (a reader, case 7 or a positive control failed); see $(Join-Path $Run ''results.md'')."; exit 1 }' 'the outer no longer passes the driver''s 1 on'
    # Every assignment to a guard, exit or case-7 control variable, with what it assigns.
    $pinned = [ordered]@{
        'before' = @('Startup-Fingerprint'); 'after' = @('Startup-Fingerprint')
        'aumidBefore' = @('Aumid-Fingerprint'); 'aumidAfter' = @('Aumid-Fingerprint')
        'clipboardBefore' = @('[ReplyPath]::GetClipboardSequenceNumber()'); 'clipboardAfter' = @('[ReplyPath]::GetClipboardSequenceNumber()')
        'historyGuard' = @('Start-WindowsHarnessHistoryGuard -Harness ''hidden-win11-conpty-reply-path.ps1''')
        'historyFailure' = @('$null', '$_.Exception.Message')
        'unchanged' = @('$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified')
        'aumidUnchanged' = @('($aumidBefore.Keys -join ''|'') -ceq ($aumidAfter.Keys -join ''|'') -and $aumidBefore.Sha256 -ceq $aumidAfter.Sha256')
        'clipboardUnchanged' = @('$clipboardBefore -eq $clipboardAfter')
        'keysDeleted' = @('$true', '$false')
        'links' = @('@(Get-ChildItem -LiteralPath $Run -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($Run.Length) })')
        'guardsRead' = @('$false', '$true')
        'code' = @('2', '2')
        'exit' = @('Get-RunExit $failures $rows $sessions $Readers $case7 (-not $SkipPSReadLine)')
        'verdict' = @('Get-Verdict $prediction $observed $step.Barrier')
        'case7.InjectedReportShown' = @('[bool](@($case7.Steps[0].Prompt) -join '''' -cmatch ''\[\?999;2n$'')')
        'case7.TabSwitched' = @('($surfacesDuring -ge 2 -and -not $visibleDuring -and $visibleAfter)')
        'case7.Complete' = @('$true')
    }
    $assignments = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true))
    foreach ($name in $pinned.Keys) {
        $found = @($assignments | Where-Object {
                $left = $_.Left; if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
                [string]::Equals($left.Extent.Text, "`$$name", [StringComparison]::Ordinal)
            } | ForEach-Object { '{0} {1}' -f $_.Operator, $_.Right.Extent.Text })
        $wanted = @($pinned[$name] | ForEach-Object { "Equals $_" })
        if (-not [string]::Equals(($found -join ' || '), ($wanted -join ' || '), [StringComparison]::Ordinal)) {
            $problems.Add("`$$name is assigned '$($found -join ' || ')' where '$($wanted -join ' || ')' is pinned")
        }
    }
    Need '        $case7=@{Steps=[Collections.Generic.List[object]]::new();Complete=$false;' 'case 7 no longer starts incomplete'
    if (-not $SkipPins) {
        # The blocks that decide or feed an exit or a verdict, by SHA-256 with LF line ends, so a failure
        # names the block. The whole-file pins below close the set.
        $regionPins = $replyPathRegionPins
        $regionsFound = @([regex]::Matches($Harness, '(?m)^[ \t]*# pin-begin: ([a-z0-9-]+)') | ForEach-Object { $_.Groups[1].Value })
        if (-not [string]::Equals(($regionsFound -join ','), (@($regionPins.Keys) -join ','), [StringComparison]::Ordinal)) {
            $problems.Add("the pinned regions are '$($regionsFound -join ',')' where '$(@($regionPins.Keys) -join ',')' are pinned")
        }
        foreach ($name in $regionPins.Keys) {
            $begin = [regex]::Match($Harness, "(?m)^[ \t]*# pin-begin: $([regex]::Escape($name))[^\n]*\n")
            $hash = ''
            if ($begin.Success) {
                $end = [regex]::Match($Harness.Substring($begin.Index), "(?m)^[ \t]*# pin-end: $([regex]::Escape($name))[ \t]*(\n|$)")
                if ($end.Success) { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Harness.Substring($begin.Index, $end.Index + $end.Length)))) }
            }
            if ($hash -cne $regionPins[$name]) { $problems.Add("pinned region $name changed (SHA-256 $(if ($hash) { $hash } else { 'missing' })); review it and update its pin here") }
        }
        $functionPins = $replyPathFunctionPins
        foreach ($name in $functionPins.Keys) {
            $definition = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name }, $true))
            $hash = if ($definition.Count -eq 1) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($definition[0].Extent.Text))) } else { '' }
            if ($hash -cne $functionPins[$name]) { $problems.Add("pinned function $name changed (SHA-256 $(if ($hash) { $hash } else { 'missing' })); review it and update its pin here") }
        }
        # The reader, whole: every line of it decides what a reader records.
        $readerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Reader)))
        if ($readerHash -cne $replyPathReaderPin) { $problems.Add("the reader changed (SHA-256 $readerHash); review it and update its pin here") }
        # The harness, whole: what closes the set. The region and function pins above name the block.
        $harnessHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Harness)))
        if ($harnessHash -cne $replyPathHarnessPin) { $problems.Add("the harness changed (SHA-256 $harnessHash); review it and update its pin here") }
    }

    # Case 7: pwsh without a profile, history read back before anything is typed.
    Need '-e "{3}" -NoLogo -NoProfile -NoExit -Command "{4}"' 'case 7''s pwsh must start -NoLogo -NoProfile -NoExit'
    Need '$historyLiteral=[Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shellHistory)' 'case 7''s history path is no longer escaped as a literal'
    Need '$readyLiteral=[Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shellReady)' 'case 7''s ready path is no longer escaped as a literal'
    Need 'Set-Content -LiteralPath ''$readyLiteral'' -Value ready }"' 'case 7''s ready file no longer takes the escaped path'
    if ($code -match '''\$shell(History|Ready)''') { $problems.Add('a case 7 path goes into the startup unescaped') }
    if ($code -notmatch '(?s)if\(@\(\$shellBefore\.Prompt\)\.Count -ne 1 -or @\(\$afterSwitch\.Prompt\)\.Count -ne 1\) \{ throw ''No PS prompt row before or after the tab switch[^\n]*\n\s*\$case7\.Complete=\$true') {
        $problems.Add('case 7 completes without a prompt row before and after the switch')
    }
    if ($code -notmatch '(?s)Set-PSReadLineOption -HistorySavePath ''\$historyLiteral'' -HistorySaveStyle SaveNothing; if\(\(Get-PSReadLineOption\)\.HistorySaveStyle -eq ''SaveNothing'' -and \(Get-PSReadLineOption\)\.HistorySavePath -ceq ''\$historyLiteral''\).*?did not become ready \(history isolation not confirmed\); nothing typed') {
        $problems.Add('PSReadLine''s history is no longer read back before anything is typed')
    }
    # Every noctty launch: no saved window state, later tabs on System32's cmd.exe /D (no AutoRun), no clipboard.
    $launchLines = [regex]::Matches($code, '--config-file="\{1\}"[^'']*'' -f [^\r\n]*')
    if ($launchLines.Count -ne 3) { $problems.Add("noctty launch command lines: $($launchLines.Count), expected 3") }
    foreach ($line in $launchLines) {
        if (-not $line.Value.Contains('--config-file="{1}" --window-save-state=never "--command=direct:{2} /D" --clipboard-write=deny --clipboard-read=deny -e "{3}"') -or
            -not $line.Value.Contains("' -f `$exe,`$config,`$cmdExe,")) {
            $problems.Add("a noctty launch lacks --window-save-state=never, --command=direct:<System32 cmd.exe> /D or the clipboard denials: $($line.Value)")
        }
    }
    Need '$cmdExe = Join-Path ([Environment]::GetFolderPath(''System'')) ''cmd.exe''' 'cmd.exe is no longer System32''s'
    if ($code -match '--command=cmd\.exe|\$env:ComSpec') { $problems.Add('a cmd.exe is started without /D or from ComSpec, where the user''s AutoRun can run') }
    Need '$links=@(Get-ChildItem -LiteralPath $Run -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($Run.Length) })' 'the run directory is no longer checked for links'
    Need 'finally { if($Mode -eq ''c-inbox'') { Remove-Item Env:NOCTTY_CONPTY } }' 'NOCTTY_CONPTY is not cleared after the in-box launch'
    Need 'if($null -ne [Environment]::GetEnvironmentVariable(''NOCTTY_CONPTY'')) { throw' 'an inherited NOCTTY_CONPTY is no longer refused (it would run the bundled readers on another host)'
    # The run tree: made with a protected DACL for this user, SYSTEM and Administrators, and read back before anything is written to it.
    Need '$runSids=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,''S-1-5-18'',''S-1-5-32-544'')' 'the Run directory''s accounts changed'
    Need '$runAcl=[Security.AccessControl.DirectorySecurity]::new(); $runAcl.SetAccessRuleProtection($true,$false)' 'the Run directory''s DACL is no longer protected'
    Need 'foreach($sid in $runSids) { $runAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),''FullControl'',''ContainerInherit,ObjectInherit'',''None'',''Allow'')) }' 'the Run directory''s rules changed'
    Need '$runOthers=@($runRead.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -ne ''Allow'' -or $runSids -notcontains $_.IdentityReference.Value })' 'the Run directory''s read-back no longer refuses another account''s rule'
    Need 'if(-not $runRead.AreAccessRulesProtected -or $runOthers.Count -gt 0 -or @($runSids[0],''S-1-5-32-544'') -notcontains $runRead.GetOwner([Security.Principal.SecurityIdentifier]).Value) { throw ''The Run directory''''s ACL did not read back as this user''''s alone; nothing runs from it.'' }' 'the Run directory''s ACL is no longer read back and refused unless it is this user''s alone'
    if ($code -notmatch '(?s)\[void\]\[IO\.FileSystemAclExtensions\]::Create\(\[IO\.DirectoryInfo\]::new\(\$Run\),\$runAcl\)\s*if\(\$Sabotage -eq ''acl''\) \{[^\n]*\}\s*\$runRead=\[IO\.FileSystemAclExtensions\]::GetAccessControl\(\[IO\.DirectoryInfo\]::new\(\$Run\)\)\s*\$runOthers=[^\n]*\s*if\(-not \$runRead\.AreAccessRulesProtected [^\n]*\s*\$root=') {
        $problems.Add('the Run directory is no longer made with its ACL and read back before anything is written to it')
    }
    if ($code -match 'New-Item -ItemType Directory -Path \$Run\)') { $problems.Add('the Run directory is made without its ACL') }
    Need 'if($sshReaders.Count -gt 0 -and $Run -cnotmatch ''^[A-Za-z]:\\[A-Za-z0-9_.\\-]*$'') { throw' 'the ssh readers no longer refuse a Run path their far side''s shell could parse'

    # Reader d: off by default, opt-in only, hardened, its keys deleted.
    Need '[string[]] $Readers = @(''a'',''a16'',''b'',''c''),' 'the default readers changed (d and d-notiming must stay opt-in)'
    Need '$sshReaders = @($Readers | Where-Object { $_ -in @(''d'',''d-notiming'') })' 'the ssh readers are no longer recognised'
    if ($code -notmatch 'if\(\$sshReaders\.Count -gt 0 -and -not \$AllowSshFarSideUserProfileAndLocalAppData\) \{\s*throw') { $problems.Add('the ssh readers no longer need -AllowSshFarSideUserProfileAndLocalAppData') }
    Need '$sshArgs=''-tt -a -x -k -F none -p {0} -i "{1}" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ClearAllForwardings=yes -o UserKnownHostsFile="{2}" -o StrictHostKeyChecking=accept-new{3} 127.0.0.1''' 'the ssh client''s isolation flags changed'
    Need '$timing=if($Mode -eq ''d-notiming'') { '' -o ObscureKeystrokeTiming=no'' } else { '''' }' 'd-notiming no longer turns the keystroke-timing obfuscation off'
    Need '@("Port $port",''ListenAddress 127.0.0.1'',"HostKey $(Join-Path $sshDir ''host_ed25519'')","AuthorizedKeysFile $(Join-Path $sshDir ''authorized_keys'')",' 'sshd''s listen and key lines changed'
    Need '''PubkeyAuthentication yes'',''PasswordAuthentication no'',''KbdInteractiveAuthentication no'',''DisableForwarding yes'',''PermitUserRC no'',''StrictModes no'',' 'sshd''s authentication or forwarding lines changed'
    Need '"PidFile $(Join-Path $sshDir ''sshd.pid'')","AllowUsers $user")' 'sshd''s AllowUsers line changed'
    Need '& icacls.exe (Join-Path $sshDir $name) /inheritance:r /grant:r "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):F" | Out-Null' 'the private keys are no longer restricted to this user'
    Need '(''"{0}" -d -f "{1}" -E "{2}"'' -f (Join-Path $openssh ''sshd.exe'')' 'sshd no longer serves one connection (-d) from the run''s config'
    Need 'if($listener.Count -gt 0 -and @($listener | Where-Object { $_.OwningProcess -ne $sshd.pid }).Count -gt 0) { throw' 'ssh no longer waits for the run''s own sshd on the port'
    Need '$sshSecrets=@(''host_ed25519'',''host_ed25519.pub'',''client_ed25519'',''client_ed25519.pub'',''authorized_keys'')' 'the run''s ssh keys are not all listed for deletion'
    Need 'try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $keyFailures.Add(' 'the run''s ssh keys are no longer deleted best effort, each failure recorded'

    # Controls: sabotage off by default and limited to its three uses.
    Need '[ValidateSet(''none'',''delimiter'',''reader'',''control'',''setup'',''key'',''acl'')] [string] $Sabotage = ''none'',' 'sabotage is not off by default'
    NeedCount '$Sabotage -eq' 6 'sabotage must break exactly six things'
    Need 'function Cell($Text) { ([string]$Text).Replace(''|'',''\|'') }' 'results.md no longer escapes a cell''s own pipe'
    NeedCount '(Cell $r.' 6 'a results.md row no longer escapes each of its text cells'
    Need 'LocalAppDataInRun=$(switch($probe[6]) { ''1'' { $true } ''0'' { $false } ''2'' { ''unset'' } default { ''unknown'' } })}' 'the reader''s LOCALAPPDATA answer no longer tells unset from unknown'

    # The run's config, case 7's injections, the split gap, readiness and the reader states.
    Need ("`$configLines=@('shell-integration = none','single-instance = false','window-save-state = never','confirm-close-surface = false',`n" +
        "    'quit-after-last-window-closed = true','keybind = clear','window-width = 100','window-height = 30',`n" +
        "    'keybind = f23=new_tab','keybind = f24=previous_tab')") 'the run''s config changed (keybind = clear, shell-integration = none, no saved state, no close prompt)'
    Need ("foreach(`$inject in @(@{Key='f22';Name='2033 report, hidden (what a tab switch would send with ?2033 stale)'},`n" +
        "                                 @{Key='f17';Name='2033 report, visible'},`n" +
        "                                 @{Key='f18';Name='DECRPM 2033'},`n" +
        "                                 @{Key='f19';Name='multiple-cursors reply'},`n" +
        "                                 @{Key='f8';Name='APC OK'},`n" +
        "                                 @{Key='f20';Name='injected OSC 11 reply'})) {") 'case 7''s injections changed'
    Need 'if(-not $first -and $planned.Gap) { Start-Sleep -Milliseconds $planned.Gap }' 'a split''s two writes are no longer apart'
    Need 'try { $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete);' 'the ready file is no longer read shared'
    Need 'catch [IO.IOException] { $t=$null }' 'a busy ready file no longer retries'
    foreach ($line in @(
            'if (wcscmp(argv[1], L"a") == 0) { wanted = (before & ~0x7u) | 0x200; records = 1; ansi = 1; }',
            'else if (wcscmp(argv[1], L"a16") == 0) { wanted = (before & ~0x7u) | 0x200; records = 1; per_read = 16; }',
            'else if (wcscmp(argv[1], L"b") == 0) { wanted = 0x98; records = 1; }',
            'else if (wcscmp(argv[1], L"c") == 0) { wanted = (before & ~0x7u) | 0x200; }',
            'if (swprintf_s(ready_tmp, MAX_PATH, L"%ls.tmp", argv[3]) < 0) return 8;',
            'if (_wfopen_s(&ready, ready_tmp, L"wb") || !ready) return 8;',
            'if (!MoveFileExW(ready_tmp, argv[3], MOVEFILE_REPLACE_EXISTING)) return 13;',
            'DWORD got = GetEnvironmentVariableW(L"LOCALAPPDATA", value, 32768);',
            'if (got == 0) return GetLastError() == ERROR_ENVVAR_NOT_FOUND ? 2 : 3;',
            'if (got >= 32768) return 3;',
            ('if (GetFileAttributesW(argv[4]) != INVALID_FILE_ATTRIBUTES) fprintf(g_log, "STOP,%lld\n", now_ticks());' + "`n" + '    fclose(g_log);'))) {
        if (-not $Reader.Contains($line)) { $problems.Add("the reader no longer has: $line") }
    }

    # The control bytes: bindings, the reader's commands and the analysis's skip list agree.
    $readerCodes = @([regex]::Matches($Reader, 'case 0x([0-9A-Fa-f]{2}):') | ForEach-Object { [Convert]::ToInt32($_.Groups[1].Value, 16) } | Sort-Object -Unique)
    $bindingCodes = @([regex]::Matches($code, '; Bytes="\$\(\[char\](\d+)\)" \}') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
    $skip = [regex]::Match($code, '\$control=@\(([0-9,]+)\)')
    $skipCodes = if ($skip.Success) { @($skip.Groups[1].Value.Split(',') | ForEach-Object { [int]$_ } | Sort-Object -Unique) } else { @() }
    if (($readerCodes -join ',') -ne '1,2,4,5,6,14,15,16,18' -or ($bindingCodes -join ',') -ne ($readerCodes -join ',') -or ($skipCodes -join ',') -ne ($readerCodes -join ',')) {
        $problems.Add("control bytes disagree: reader $($readerCodes -join ','), bindings $($bindingCodes -join ','), analysis $($skipCodes -join ',')")
    }
    foreach ($query in @('"\x1b[c"', '"\x1b]11;?\x1b\\"', '"\x1b[?9001$p"', '"\x1b[?u"', '"\x1b[>1u"', '"\x1b[<u"', '"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"', '"\x1b_Gi=32,s=2,v=2,a=q,t=d,f=24;AAAA\x1b\\"')) {
        if (-not $Reader.Contains($query)) { $problems.Add("the reader no longer writes $query") }
    }

    if ($StopAtFirst -and $problems.Count -gt 0) { return $problems.ToArray() }

    # The evaluated checks, in a runspace of their own: tables and functions pulled out by AST.
    $assignment = {
        param($Name)
        $found = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$$Name" }, $true))
        if ($found.Count -ne 1) { $problems.Add("expected one assignment to `$$Name, found $($found.Count)"); return '' }
        $found[0].Extent.Text
    }
    $function = {
        param($Name)
        $found = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name }, $true))
        if ($found.Count -ne 1) { $problems.Add("expected one function $Name, found $($found.Count)"); return '' }
        $found[0].Extent.Text
    }
    $definitions = @((& $assignment 'bindings'), (& $assignment 'stepPlan'), (& $function 'Get-PlannedSteps'), (& $function 'Get-Prediction'),
        (& $function 'Get-RunExit'), (& $function 'Get-Segments'), (& $function 'Binding-Line'), (& $function 'Get-Verdict'),
        (& $function 'Get-ReaderStateProblems'))
    if ($problems.Count -gt 0 -and $StopAtFirst) { return $problems.ToArray() }
    $evaluated = @(Invoke-ContractScriptWithDeadline -Script $script:ReplyPathEvaluation -Arguments @(, $definitions) -HangMessage 'The reply-path harness''s tables and functions did not evaluate in time.')
    foreach ($p in $evaluated) { if ($p) { $problems.Add([string]$p) } }
    return $problems.ToArray()
}

# Runs in a fresh runspace: defines the harness's tables and functions, then
# checks them against what the kitty report's cases and the council's rounds
# require. Returns a list of problems.
$script:ReplyPathEvaluation = {
    param($Definitions)
    $out = [Collections.Generic.List[string]]::new()
    $esc = [char]27; $Sabotage = 'none'
    try { foreach ($text in $Definitions) { . ([scriptblock]::Create($text)) } }
    catch { return @("the harness's tables or functions do not evaluate: $($_.Exception.Message)") }
    $e = [char]27
    # Every binding's bytes, exactly.
    $expected = [ordered]@{
        f1 = "$([char]2)"; f2 = "$([char]1)"; f3 = "$([char]15)"; f4 = "$([char]4)"; f5 = "$([char]5)"; f6 = "$([char]6)"; f7 = "$([char]14)"
        f8 = "${e}_Gi=31;OK${e}\"; f9 = "${e}_Gi=31;ENOENT:No such file${e}\"
        f10 = "${e}_Gi=31;O"; f11 = "K${e}\"; f12 = "$e"; f13 = "_Gi=31;OK${e}\"; f14 = "${e}_Gi=31;OK${e}"; f15 = '\'
        insert = "${e}_Gi=31;ENOENT:"; home = "No such file${e}\"; end = "_Gi=31;ENOENT:No such file${e}\"
        f16 = "${e}_Gi=31,e=T,U=1;OK${e}\"; f17 = "${e}[?999;1n"; f18 = "${e}[?2033;2`$y"; f19 = "${e}[>1;2;3;29;30;40;100;101 q"
        f20 = "${e}]11;rgb:1e1e/1e1e/1e1e${e}\"; print_screen = "${e}]4;1;rgb:cdcd/0000/0000${e}\"; f21 = "${e}[?62;22c"; f22 = "${e}[?999;2n"
        pause = "$([char]16)"; scroll_lock = "$([char]18)"
    }
    $keys = @($bindings.Keys); $wanted = @($expected.Keys)
    if (($keys -join ',') -cne ($wanted -join ',')) { $out.Add("the bindings are $($keys -join ',') where $($wanted -join ',') are pinned") }
    foreach ($k in $wanted) { if ($bindings.Contains($k) -and -not [string]::Equals([string]$bindings[$k].Bytes, $expected[$k], [StringComparison]::Ordinal)) { $out.Add("binding $k writes other bytes than the case pins") } }
    if ((Binding-Line 'f9' "${e}_Gi=31;E:x y${e}\") -cne 'keybind = f9=text:\x1b\x5f\x47\x69\x3d\x33\x31\x3b\x45\x3a\x78\x20\x79\x1b\x5c') { $out.Add('Binding-Line no longer writes every byte as \xNN') }
    # The step plan, exactly: name | keys | gap | typed keys (+ for Shift) | Kitty-only.
    $plan = @($stepPlan | ForEach-Object {
            '{0}|{1}|{2}|{3}|{4}' -f $_.Name, (@($_.Keys) -join ','), [int]$_.Gap, (@($_.Typed | ForEach-Object { '{0}{1}' -f $_.Vk, $(if ($_.Shift) { '+' } else { '' }) }) -join ','), $(if ($_.Kitty) { 'K' } else { '' }) })
    $planWanted = @(
        'typed: Shift tap, h, i (9001 records)||0|16+,72,73|'
        'mode 9001: DECRQM|pause|0||'
        'push Kitty flags (CSI > 1 u)|f2|0||K'
        'Kitty flags: CSI ? u|scroll_lock|0||K'
        'typed after the push: Shift tap, h||0|16+,72|K'
        'case 6: DA1 (before)|f4|0||'
        'case 6: OSC 11 (before)|f5|0||'
        'case 1: noctty kitty reply, OK|f6|0||'
        'case 1: noctty kitty reply, error|f7|0||'
        'case 1: APC OK, one write|f8|0||'
        'case 1: APC error, one write|f9|0||'
        'case 1: APC OK, split mid-body|f10,f11|300||'
        'case 1: APC OK, split ESC|_|f12,f13|300||'
        'case 1: APC OK, split ESC|\|f14,f15|300||'
        'case 1: APC error, split mid-body|insert,home|300||'
        'case 1: APC error, split ESC|_|f12,end|300||'
        'case 2: APC feature-shaped|f16|0||'
        'case 3: 2033 report, visible|f17|0||'
        'case 3: DECRPM 2033|f18|0||'
        'case 4: multiple-cursors reply|f19|0||'
        'case 6: injected OSC 11 reply|f20|0||'
        'case 6: injected OSC 4 reply|print_screen|0||'
        'case 6: injected DA1 reply|f21|0||'
        'case 7 shape: 2033 report, hidden|f22|0||'
        'case 6: DA1 (after)|f4|0||'
        'case 6: OSC 11 (after)|f5|0||'
        'pop Kitty flags (CSI < u)|f3|0||K'
    )
    if (-not [string]::Equals(($plan -join "`n"), ($planWanted -join "`n"), [StringComparison]::Ordinal)) { $out.Add('the step plan differs from the pinned cases') }
    if (@(Get-PlannedSteps 'a').Count -ne 27 -or @(Get-PlannedSteps 'b').Count -ne 23 -or @(Get-PlannedSteps 'd-notiming').Count -ne 23) { $out.Add('Get-PlannedSteps no longer gives a and a16 the Kitty steps alone') }
    # Predictions, behaviourally: what each must accept and refuse, and which are positive controls.
    $ok = "${e}_Gi=31;OK${e}\"; $err = "${e}_Gi=31;ENOENT:No such file${e}\"; $cursors = "${e}[>1;2;3;29;30;40;100;101 q"
    $osc11 = "${e}]11;rgb:1e1e/1e1e/1e1e${e}\"; $da1 = "${e}[?62;22c"
    $cases = @(
        ,@('mode 9001: DECRQM', 'a', '', "${e}[?9001;1`$y", $true, $true)
        ,@('mode 9001: DECRQM', 'b', '', "${e}[?9001;2`$y", $false, $true)
        ,@('mode 9001: DECRQM', 'c', '', '', $false, $true)
        ,@('mode 9001: DECRQM', 'd', '', "${e}[?9001;2`$y", $true, $true)
        ,@('Kitty flags: CSI ? u', 'a16', '', "${e}[?1u", $true, $true)
        ,@('Kitty flags: CSI ? u', 'a', '', "${e}[?0u", $false, $true)
        ,@('case 6: DA1 (before)', 'c', '', "${e}[?62;22;52c", $true, $true)
        ,@('case 6: DA1 (after)', 'b', '', "${e}[?61;6;7c", $false, $true)
        ,@('case 6: DA1 (before)', 'a', '', '', $false, $true)
        ,@('case 6: DA1 (after)', 'd', '', "${e}[?61;6;7;21;22c", $true, $true)
        ,@('case 6: DA1 (before)', 'c-inbox', '', "${e}[?62;22;52c", $false, $true)
        ,@('case 6: OSC 11 (before)', 'b', '', "${e}]11;rgb:2828/2c2c/3434${e}\", $true, $true)
        ,@('case 6: OSC 11 (after)', 'a', '', '', $false, $true)
        ,@('case 6: OSC 11 (before)', 'd', '', '', $true, $false)
        ,@('case 1: noctty kitty reply, OK', 'a', '', $ok, $true, $false)
        ,@('case 1: noctty kitty reply, OK', 'b', '', '\', $true, $false)
        ,@('case 1: noctty kitty reply, error', 'c', '', "${e}_Gi=32;EINVAL: invalid data${e}\", $true, $false)
        ,@('case 1: noctty kitty reply, OK', 'c-inbox', '', '', $true, $false)
        ,@('case 1: APC OK, one write', 'b', $ok, '\', $true, $false)
        ,@('case 1: APC OK, one write', 'b', $ok, $ok, $false, $false)
        ,@('case 1: APC OK, one write', 'a', $ok, $ok, $true, $false)
        ,@('case 1: APC error, split mid-body', 'c', $err, $err, $true, $false)
        ,@('case 1: APC OK, split ESC|_', 'c', $ok, $ok.Substring(1), $true, $false)
        ,@('case 1: APC error, split ESC|_', 'a16', $err, $err, $false, $false)
        ,@('case 1: APC error, one write', 'd-notiming', $err, $err.Substring(16), $true, $false)
        ,@('case 1: APC error, one write', 'd', $err, $err, $true, $false)
        ,@('case 4: multiple-cursors reply', 'b', $cursors, $cursors, $true, $false)
        ,@('case 4: multiple-cursors reply', 'd-notiming', $cursors, $cursors.Substring(16), $true, $false)
        ,@('case 6: injected OSC 11 reply', 'a', $osc11, $osc11, $true, $true)
        ,@('case 6: injected OSC 11 reply', 'c-inbox', $osc11, $osc11, $true, $false)
        ,@('case 6: injected DA1 reply', 'd', $da1, $da1, $true, $true)
        ,@('case 6: injected DA1 reply', 'b', $da1, '', $false, $true)
        ,@('case 7 shape: 2033 report, hidden', 'b', "${e}[?999;2n", "${e}[?999;2n", $true, $false)
    )
    foreach ($c in $cases) {
        $p = Get-Prediction $c[0] $c[1] $c[2]
        if (-not $p) { $out.Add("no prediction for $($c[0]) on $($c[1])"); continue }
        $match = if ($p.Regex) { $c[3] -cmatch $p.Regex } else { [string]::Equals([string]$c[3], [string]$p.Exact, [StringComparison]::Ordinal) }
        if ($match -ne $c[4]) { $out.Add("the prediction for $($c[0]) on $($c[1]) $(if ($c[4]) { 'refuses' } else { 'accepts' }) the sample") }
        if ([bool]$p.Control -ne $c[5]) { $out.Add("$($c[0]) on $($c[1]) is $(if ($c[5]) { 'no longer' } else { 'now' }) a positive control") }
    }
    # Verdicts: ordinal bytes, and a step that never finished is INCOMPLETE whatever it observed.
    $verdicts = @(
        ,@(@{ Exact = "${e}_A" }, '_A', 'OK', 'DIFFERS')
        ,@(@{ Exact = "${e}_A" }, "${e}_A", 'OK', 'as predicted')
        ,@(@{ Exact = '' }, '', 'TIMEOUT', 'INCOMPLETE')
        ,@(@{ Regex = '^\x1b\[\?1u$' }, "${e}[?1u", 'OK', 'as predicted')
        ,@(@{ Regex = '^\x1b\[\?1u$' }, '[?1u', 'OK', 'DIFFERS')
        ,@($null, 'x', 'OK', '-')
        ,@($null, '', 'TIMEOUT', 'INCOMPLETE')
    )
    foreach ($v in $verdicts) {
        $got = Get-Verdict $v[0] $v[1] $v[2]
        if ($got -cne $v[3]) { $out.Add("Get-Verdict gives '$got' where '$($v[3])' is right ($($v[2]))") }
    }
    # Reader states: the input mode each reader is named for, the record readers' read sizes, and a clean stop.
    $state = { param($Mode, $Mode0, $Mode1, $Reads, $Done = 1, $Stop = 1) @{ Mode = $Mode; Ready = @{ InputModeBefore = $Mode0; InputMode = $Mode1 }; Log = @(@($Reads | ForEach-Object { "READ,1,$_" }) + @(if ($Stop) { 'STOP,1' })); Planned = 1; Steps = @(1..1 | Where-Object { $Done } | ForEach-Object { @{ Barrier = 'OK' } }) } }
    $states = @(
        ,@((& $state 'a16' '0x1f7' '0x3f0' @(1, 16, 9)), 0)
        ,@((& $state 'a16' '0x1f7' '0x3f0' @(1, 30)), 1)
        ,@((& $state 'a16' '0x1f7' '0x3f0' @(1, 9)), 1)
        ,@((& $state 'a' '0x1f7' '0x3f0' @(1, 30)), 0)
        ,@((& $state 'a' '0x1f7' '0x3f0' @(1, 12)), 1)
        ,@((& $state 'b' '0x1f7' '0x98' @(4, 25)), 0)
        ,@((& $state 'b' '0x1f7' '0x298' @(4, 25)), 1)
        ,@((& $state 'c' '0x1f7' '0x3f0' @()), 0)
        ,@((& $state 'c' '0x1f7' '0x3f7' @()), 1)
        ,@((& $state 'a16' '0x1f7' '0x3f0' @(1, 9) 0), 0)
        ,@((& $state 'b' '0x1f7' '0x98' @(4) 0), 0)
        ,@((& $state 'b' '0x1f7' '0x298' @(4) 0), 1)
        ,@((& $state 'b' '0x1f7' '0x98' @(4, 25) 1 0), 1)
        ,@((& $state 'c' '0x1f7' '0x3f0' @() 1 0), 1)
        ,@((& $state 'b' '0x1f7' '0x98' @(4) 0 0), 0)
    )
    foreach ($x in $states) {
        $got = @(Get-ReaderStateProblems $x[0]).Count
        if ($got -ne $x[1]) { $out.Add("Get-ReaderStateProblems finds $got problem(s) for reader $($x[0].Mode) (mode $($x[0].Ready.InputMode), reads $(@($x[0].Log) -join ' ')), expected $($x[1])") }
    }
    # The exit policy: incomplete runs and failed controls exit 1, infrastructure 2, a complete run 0.
    $mk = { param($Mode, $Done, $Planned) @{ Mode = $Mode; Planned = $Planned; Steps = @(1..$Done | ForEach-Object { @{ Barrier = 'OK' } }) } }
    $full = @((& $mk 'a' 27 27), (& $mk 'b' 23 23)); $c7 = @{ Complete = $true; InjectedReportShown = $true; TabSwitched = $true }
    $rowOk = @(@{ Control = $true; Verdict = 'as predicted'; Reader = 'a'; Step = 'x' }, @{ Control = $false; Verdict = 'DIFFERS'; Reader = 'c-inbox'; Step = 'y' })
    $exits = @(
        ,@('complete', 0, @(), $rowOk, $full, @('a', 'b'), $c7, $true)
        ,@('a measurement that differs', 0, @(), @(@{ Control = $false; Verdict = 'DIFFERS' }), $full, @('a', 'b'), $c7, $true)
        ,@('case 7 skipped', 0, @(), $rowOk, $full, @('a', 'b'), $null, $false)
        ,@('a reader failure', 1, @('reader b: Delimiter after ''x'' never reached the reader (b).'), $rowOk, $full, @('a', 'b'), $c7, $true)
        ,@('a missing reader', 1, @(), $rowOk, @($full[0]), @('a', 'b'), $c7, $true)
        ,@('a reader that stopped early', 1, @(), $rowOk, @((& $mk 'a' 27 27), (& $mk 'b' 2 23)), @('a', 'b'), $c7, $true)
        ,@('a failed positive control', 1, @(), @(@{ Control = $true; Verdict = 'DIFFERS'; Reader = 'b'; Step = 'case 6: DA1 (before)' }), $full, @('a', 'b'), $c7, $true)
        ,@('a case 7 failure', 1, @('case 7: pwsh inside noctty did not become ready'), $rowOk, $full, @('a', 'b'), @{ Complete = $false }, $true)
        ,@('case 7 not run', 1, @(), $rowOk, $full, @('a', 'b'), $null, $true)
        ,@('case 7 without its report', 1, @(), $rowOk, $full, @('a', 'b'), @{ Complete = $true; InjectedReportShown = $false; TabSwitched = $true }, $true)
        ,@('case 7 without the tab switch', 1, @(), $rowOk, $full, @('a', 'b'), @{ Complete = $true; InjectedReportShown = $true; TabSwitched = $false }, $true)
        ,@('infrastructure', 2, @('infrastructure: boom'), $rowOk, $full, @('a', 'b'), $c7, $true)
        ,@('a reader in the wrong state', 1, @(), $rowOk, @((& $mk 'a' 27 27), ((& $mk 'b' 23 23) + @{ StateProblems = @('reader b: input mode 0x298, expected 0x98') })), @('a', 'b'), $c7, $true)
    )
    foreach ($x in $exits) {
        $got = (Get-RunExit $x[2] $x[3] $x[4] $x[5] $x[6] $x[7]).Code
        if ($got -ne $x[1]) { $out.Add("the run exits $got for $($x[0]), expected $($x[1])") }
    }
    # The analysis, on synthetic logs: a record reader whose APC came back as Alt+\, a byte reader whose split APC lost its ESC.
    $records = @{ Mode = 'b'; Log = @('READ,1,4', 'KEY,1,1,17,29,0,8', 'KEY,1,1,66,48,2,8', 'KEY,0,1,66,48,2,8', 'KEY,0,1,17,29,0,0', 'CMD,2,02,',
            'READ,3,4', 'KEY,1,1,18,56,0,2', 'KEY,1,1,220,43,92,2', 'KEY,0,1,220,43,92,2', 'KEY,0,1,18,56,0,0', 'READ,4,1', 'KEY,1,1,66,48,2,8', 'CMD,5,02,') }
    $bytes = @{ Mode = 'd-notiming'; Log = @('PEEK,1,1', 'BYTES,1,1,04', 'CMD,1,04,1b5b63', 'PEEK,2,11', 'BYTES,2,11,5f47693d33313b4f4b1b5c', 'PEEK,3,1', 'BYTES,3,1,02', 'CMD,3,02,') }
    $r = Get-Segments $records; $b = Get-Segments $bytes
    if ($r.Count -ne 2 -or -not [string]::Equals($r[1].Units.ToString(), '\', [StringComparison]::Ordinal)) { $out.Add('Get-Segments no longer splits a record log at its delimiters, keeping key-down characters other than the controls') }
    if (-not [string]::Equals($b[0].Units.ToString(), "_Gi=31;OK${e}\", [StringComparison]::Ordinal) -or $b[0].Commands.Count -ne 1) { $out.Add('Get-Segments no longer keeps a byte reader''s bytes without the controls') }
    return $out.ToArray()
}

$replyPathHarnessText = Get-Content -LiteralPath $replyPathScript -Raw
$replyPathReaderText = Get-Content -LiteralPath $replyPathReader -Raw
$replyPathProblems = @(Get-ReplyPathProblems -Harness $replyPathHarnessText -Reader $replyPathReaderText)
if ($replyPathProblems.Count -gt 0) { throw "The ConPTY reply-path harness breaks its contract: $($replyPathProblems -join '; ')" }

# Every mutation the council ran (round 1: Sol's 3, Opus's 22, Muse's 8, the
# duplicates kept once; round 2: Opus's 25, those it did not name rebuilt and
# marked so; round 3: Opus's survivors and his reader-a read, Sol's discarded
# result; round 4: Opus's probes and Sol's five, one shared; round 5: the
# bots' threads and Opus's Lows; round 6: Opus's two unreached checks and
# Sol's escaped pipe) and the contract's own. An entry has Old and New, or
# Edits for several; PinOnly marks one only a pin can see, and Check names the
# content check that must refuse it.
$replyPathMutations = @(
    @{ Name = 'Sol 1 / Opus 1: the reader session''s noctty on a null desktop'; Old = '$terminal=[ReplyPath]::Launch($exe,$command,$Bin,"WinSta0\$driverDesktop",$job,0x08000000)'; New = '$terminal=[ReplyPath]::Launch($exe,$command,$Bin,$null,$job,0x08000000)' }
    @{ Name = 'Sol 2: no job assignment before resume'; Old = 'if(!AssignProcessToJobObject(job,p.process)||ResumeThread(p.thread)==0xFFFFFFFF) {'; New = 'if(ResumeThread(p.thread)==0xFFFFFFFF) {' }
    @{ Name = 'Sol 3: the APC OK body'; Old = 'f8  = @{ Name=''APC OK''; Bytes="${esc}_Gi=31;OK${esc}\" }'; New = 'f8  = @{ Name=''APC OK''; Bytes="${esc}_Gi=31;BROKEN${esc}\" }' }
    @{ Name = 'Opus 2: sshd on a null desktop'; Old = '(Join-Path $sshDir "sshd-debug-$Mode.log")),$sshDir,"WinSta0\$driverDesktop",$job,0x08000000)'; New = '(Join-Path $sshDir "sshd-debug-$Mode.log")),$sshDir,$null,$job,0x08000000)' }
    @{ Name = 'Opus 3 / Muse 8: no surface desktop check in the reader session'; Old = 'if(-not [ReplyPath]::OnCallerDesktop($surface)) { throw ''The noctty surface is not on the private desktop; nothing is posted to it.'' }'; New = '' }
    @{ Name = 'Opus 4: case 7''s pwsh with its profile'; Old = '-NoLogo -NoProfile -NoExit -Command'; New = '-NoLogo -NoExit -Command' }
    @{ Name = 'Opus 5 / Muse 6: d in the default readers'; Old = '[string[]] $Readers = @(''a'',''a16'',''b'',''c''),'; New = '[string[]] $Readers = @(''a'',''a16'',''b'',''c'',''d''),' }
    @{ Name = 'Opus 6: ssh without -F none'; Old = '-tt -a -x -k -F none -p {0}'; New = '-tt -a -x -k -p {0}' }
    @{ Name = 'Opus 7: ssh without its own known_hosts'; Old = ' -o UserKnownHostsFile="{2}"'; New = '' }
    @{ Name = 'Opus 8: ssh with the user''s agent'; Old = ' -o IdentityAgent=none'; New = '' }
    @{ Name = 'Opus 9: no AllowUsers'; Old = ',"AllowUsers $user")'; New = ')' }
    @{ Name = 'Opus 10: keyboard-interactive allowed'; Old = '''KbdInteractiveAuthentication no'','; New = '' }
    @{ Name = 'Opus 11: private keys not restricted'; Old = '& icacls.exe (Join-Path $sshDir $name) /inheritance:r /grant:r "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):F" | Out-Null'; New = '$null = 1' }
    @{ Name = 'Opus 12: no startup-ledger comparison'; Old = '$unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified'; New = '$unchanged=$true' }
    @{ Name = 'Opus 13: NOCTTY_CONPTY left set'; Old = 'finally { if($Mode -eq ''c-inbox'') { Remove-Item Env:NOCTTY_CONPTY } }'; New = 'finally { }' }
    @{ Name = 'Opus 14: the bundled DECRQM 9001 control loosened'; Old = 'Regex=''^\x1b\[\?9001;1\$y$'';Control=$true}'; New = 'Regex=''^\x1b\[\?9001;[0-9]\$y$'';Control=$true}' }
    @{ Name = 'Opus 15: the DA1 control loosened'; Old = 'Regex=''^\x1b\[\?62;[0-9;]+c$'';Control=$true}'; New = 'Regex=''^\x1b\[\?[0-9;]*c?$'';Control=$true}' }
    @{ Name = 'Opus 16: no typed 9001 step'; Old = '    @{ Name=''typed: Shift tap, h, i (9001 records)''; Keys=@(); Typed=@(@{Vk=0x10;Shift=$true},@{Vk=0x48},@{Vk=0x49}) }'; New = '' }
    @{ Name = 'Opus 17: no Kitty push'; Old = '    @{ Name=''push Kitty flags (CSI > 1 u)''; Keys=@(''f2''); Kitty=$true }'; New = '' }
    @{ Name = 'Opus 18: the ESC|_ split as one write'; Old = '@{ Name=''case 1: APC OK, split ESC|_''; Keys=@(''f12'',''f13''); Gap=300 }'; New = '@{ Name=''case 1: APC OK, split ESC|_''; Keys=@(''f8'') }' }
    @{ Name = 'Opus 19 / Muse 2: sshd on every interface'; Old = '''ListenAddress 127.0.0.1'''; New = '''ListenAddress 0.0.0.0''' }
    @{ Name = 'Opus 20: no history assertion'; Old = 'try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard }'; New = 'try { $null = $historyGuard }' }
    @{ Name = 'Opus 21: password authentication allowed'; Old = '''PasswordAuthentication no'','; New = '' }
    @{ Name = 'Opus 22: ssh may prompt'; Old = ' -o BatchMode=yes'; New = '' }
    @{ Name = 'Muse 1: the reader''s error-query code'; File = 'reader'; Old = 'case 0x0E:'; New = 'case 0x0D:' }
    @{ Name = 'Muse 3: a launch without the pinned later-tab command'; Old = '--window-save-state=never "--command=direct:{2} /D" --clipboard-write=deny --clipboard-read=deny -e "{3}" {4}'' -f $exe,$config,$cmdExe,$reader,$readerArgs'; New = '--window-save-state=never --clipboard-write=deny --clipboard-read=deny -e "{2}" {3}'' -f $exe,$config,$reader,$readerArgs' }
    @{ Name = 'round 2b: a launch with --command=cmd.exe (AutoRun)'; Old = '"--command=direct:{2} /D" --clipboard-write=deny --clipboard-read=deny -e "{3}" -NoLogo'; New = '--command=cmd.exe --clipboard-write=deny --clipboard-read=deny -e "{3}" -NoLogo' }
    @{ Name = 'round 2b: case 7''s later tab without /D'; Old = '"--command=direct:{2} /D" --clipboard-write=deny --clipboard-read=deny -e "{3}" -NoLogo'; New = '"--command=direct:{2}" --clipboard-write=deny --clipboard-read=deny -e "{3}" -NoLogo' }
    @{ Name = 'round 2b: cmd.exe from PATH'; Old = '$cmdExe = Join-Path ([Environment]::GetFolderPath(''System'')) ''cmd.exe'''; New = '$cmdExe = ''cmd.exe''' }
    @{ Name = 'round 2b: the compiler through ComSpec'; Old = '[ReplyPath]::Launch($cmdExe,(''"{0}" /d /c ""{1}""'' -f $cmdExe,$compile)'; New = '[ReplyPath]::Launch($env:ComSpec,(''"{0}" /d /c ""{1}""'' -f $env:ComSpec,$compile)' }
    @{ Name = 'round 2b: clipboard writes allowed'; Old = '--clipboard-write=deny --clipboard-read=deny -e "{3}" {4} {5} {6}'; New = '--clipboard-read=deny -e "{3}" {4} {5} {6}' }
    @{ Name = 'round 2b: clipboard reads allowed'; Old = '--clipboard-read=deny -e "{3}" {4}'' -f'; New = '-e "{3}" {4}'' -f' }
    @{ Name = 'round 2b: links in the run not checked'; Old = 'if(-not $keysDeleted -or $links.Count -gt 0 -or ($guardsRead'; New = 'if(-not $keysDeleted -or ($guardsRead' }
    @{ Name = 'Opus r2 N1: the AUMID fingerprint matches no key'; PinOnly = $true; Old = 'Where-Object { $_.PSChildName -like ''io.github.amanthanvi.noctty*'' }'; New = 'Where-Object { $_.PSChildName -like ''no-such-key*'' }' }
    @{ Name = 'Opus r2 N2: the startup-ledger path changed'; PinOnly = $true; Old = '''noctty\startup-attempts.json'''; New = '''noctty\no-such-ledger.json''' }
    @{ Name = 'Opus r2 N3: the clipboard read after the run fed the one before'; Old = '$clipboardAfter=[ReplyPath]::GetClipboardSequenceNumber()'; New = '$clipboardAfter=$clipboardBefore' }
    @{ Name = 'Opus r2 N4: an incomplete run exits 0 in the outer'; Old = 'or a positive control failed); see $(Join-Path $Run ''results.md'')."; exit 1 }'; New = 'or a positive control failed); see $(Join-Path $Run ''results.md'')."; exit 0 }' }
    @{ Name = 'Opus r2 N5: the driver exits 0'; Old = 'exit $exit.Code'; New = 'exit 0' }
    @{ Name = 'Opus r2 N6: the driver trap exits 0'; Old = '-f $_.Exception.Message,$_.InvocationInfo.PositionMessage); exit 2'; New = '-f $_.Exception.Message,$_.InvocationInfo.PositionMessage); exit 0' }
    @{ Name = 'Opus r2 N7: case 7''s controls not required'; Old = '$exit=Get-RunExit $failures $rows $sessions $Readers $case7 (-not $SkipPSReadLine)'; New = '$exit=Get-RunExit $failures $rows $sessions $Readers $case7 $false' }
    @{ Name = 'Opus r2 N8 (reconstructed): no requested reader checked'; Old = '$exit=Get-RunExit $failures $rows $sessions $Readers $case7'; New = '$exit=Get-RunExit $failures $rows $sessions @() $case7' }
    @{ Name = 'Opus r2 N9 (reconstructed): case 7 starts complete'; Old = 'Complete=$false;NotMeasured='; New = 'Complete=$true;NotMeasured=' }
    @{ Name = 'Opus r2 N10: the injected-report control forced true'; Old = '$case7.InjectedReportShown=[bool](@($case7.Steps[0].Prompt) -join '''' -cmatch ''\[\?999;2n$'')'; New = '$case7.InjectedReportShown=$true' }
    @{ Name = 'Opus r2 N11: the tab-switch control forced true'; Old = '$case7.TabSwitched=($surfacesDuring -ge 2 -and -not $visibleDuring -and $visibleAfter)'; New = '$case7.TabSwitched=$true' }
    @{ Name = 'Opus r2 N12 (reconstructed): the ledger read after the run fed the one before'; Old = '$after=Startup-Fingerprint'; New = '$after=$before' }
    @{ Name = 'Opus r2 N13 (reconstructed): the AUMID read after the run fed the one before'; Old = '$aumidAfter=Aumid-Fingerprint'; New = '$aumidAfter=$aumidBefore' }
    @{ Name = 'Opus r2 N14: a changed guard exits 0'; Old = 'stop launches.'' -f $compared,$keysDeleted,$links.Count)' + "`n" + '        exit 3'; New = 'stop launches.'' -f $compared,$keysDeleted,$links.Count)' + "`n" + '        exit 0' }
    @{ Name = 'Opus r2 N15 (reconstructed): an infrastructure exit from the driver passes as 0'; Old = 'inspect results.json and driver-error.txt in Run."; exit 2 }'; New = 'inspect results.json and driver-error.txt in Run."; exit 0 }' }
    @{ Name = 'Opus r2 N16 (reconstructed): a cleanup failure exits 0'; Old = 'if($cleanupError) { Write-Host "Infrastructure: $cleanupError"; exit 2 }'; New = 'if($cleanupError) { Write-Host "Infrastructure: $cleanupError"; exit 0 }' }
    @{ Name = 'Opus r2 N17: a kept key counts as deleted'; Old = 'if(Test-Path -LiteralPath $path) { $keysDeleted=$false }'; New = 'if(Test-Path -LiteralPath $path) { $keysDeleted=$true }' }
    @{ Name = 'Opus r2 N18: a16 reads 64 records'; File = 'reader'; Old = 'records = 1; per_read = 16; }'; New = 'records = 1; per_read = 64; }' }
    @{ Name = 'Opus r2 N19: b with VT input'; File = 'reader'; Old = '{ wanted = 0x98; records = 1; }'; New = '{ wanted = 0x298; records = 1; }' }
    @{ Name = 'Opus r2 N20: a without ReadConsoleInputA'; File = 'reader'; Old = 'records = 1; ansi = 1; }'; New = 'records = 1; }' }
    @{ Name = 'Opus r2 N21: keybind = clear dropped'; Old = '''keybind = clear'','; New = '' }
    @{ Name = 'Opus r2 N22: shell-integration = none dropped'; Old = '$configLines=@(''shell-integration = none'','; New = '$configLines=@(' }
    @{ Name = 'Opus r2 N23: case 7''s cursors injection dropped'; Old = '@{Key=''f19'';Name=''multiple-cursors reply''},'; New = '' }
    @{ Name = 'Opus r2 N24: a split''s writes not apart'; Old = 'if(-not $first -and $planned.Gap) { Start-Sleep -Milliseconds $planned.Gap }'; New = '' }
    @{ Name = 'Opus r2 N25: the dead-reader control kills by name'; Old = '[ReplyPath]::KillExact($session.Ready.Pid)'; New = 'Stop-Process -Name console-reply-reader -Force' }
    @{ Name = 'round 3: the history guard watches nothing'; Old = '$historyGuard=Start-WindowsHarnessHistoryGuard -Harness ''hidden-win11-conpty-reply-path.ps1'''; New = '$historyGuard=Start-WindowsHarnessHistoryGuard -Harness ''hidden-win11-conpty-reply-path.ps1'' -Paths @(''nul'')' }
    @{ Name = 'round 3: the link listing fed a constant'; Old = '$links=@(Get-ChildItem -LiteralPath $Run -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($Run.Length) })'; New = '$links=@()' }
    @{ Name = 'round 3: an outer failure falls through to pwsh''s 1'; Old = '    if(-not $Driver) { Write-Host "Infrastructure: $($_.Exception.Message)"; exit 2 }'; New = '    if(-not $Driver) { break }' }
    @{ Name = 'round 3: the ssh keys made before the try'; Old = '[uint32]$code=2; $guardsRead=$false; $keyHold=$null' + "`n" + '    try {' + "`n" + '        if($sshReaders.Count -gt 0) {'; New = '[uint32]$code=2; $guardsRead=$false; $keyHold=$null' + "`n" + '    if($true) {' + "`n" + '        if($sshReaders.Count -gt 0) {' }
    @{ Name = 'round 3: the ready file read unshared'; Old = 'try { $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete);'; New = 'try { $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);' }
    @{ Name = 'round 3: the reader writes ready.txt in place'; File = 'reader'; Old = 'if (_wfopen_s(&ready, ready_tmp, L"wb") || !ready) return 8;'; New = 'if (_wfopen_s(&ready, argv[3], L"wb") || !ready) return 8;' }
    @{ Name = 'round 3: an unfinished step judged'; Old = 'if($Barrier -ne ''OK'') { return ''INCOMPLETE'' }'; New = 'if($false) { return ''INCOMPLETE'' }' }
    @{ Name = 'round 3: reader states not checked'; Old = 'foreach($s in $Sessions) { foreach($q in @($s.StateProblems)) { if($q) { $why.Add($q) } } }'; New = '' }
    @{ Name = 'round 3: a16''s read size not checked'; Old = 'if($Session.Mode -eq ''a16'' -and $largest -ne 16)'; New = 'if($false)' }
    @{ Name = 'round 3: the guards compared without their first reading'; Old = '        $guardsRead=$true' + "`n"; New = '' }
    @{ Name = 'Opus r3 P1: no row is a control'; PinOnly = $true; Old = 'Control=[bool]($prediction -and $prediction.Control)'; New = 'Control=$false' }
    @{ Name = 'Opus r3 P4: the reader-state result replaced'; PinOnly = $true; Old = '$session.StateProblems=@(Get-ReaderStateProblems $session)'; New = '$session.StateProblems=@()' }
    @{ Name = 'Sol r3: the reader-state result discarded'; PinOnly = $true; Old = '$session.StateProblems=@(Get-ReaderStateProblems $session)'; New = '$null=@(Get-ReaderStateProblems $session)' }
    @{ Name = 'Opus r3 P5: case 7 always skipped'; PinOnly = $true; Old = 'if($SkipPSReadLine) { $command+='' -SkipPSReadLine'' }'; New = '$command+='' -SkipPSReadLine''' }
    @{ Name = 'Opus r3 P6: the driver told one reader'; PinOnly = $true; Old = '$Run,($Readers -join '',''),$Sabotage'; New = '$Run,$Readers[0],$Sabotage' }
    @{ Name = 'Opus r3 P7: the outer exit switch on a constant'; PinOnly = $true; Old = '    switch($code) {'; New = '    switch(0) {' }
    @{ Name = 'Opus r3 P22: the tab-switch inputs forced'; PinOnly = $true; Old = '$surfacesDuring=@([ReplyPath]::Surfaces($shell.pid)).Count; $visibleDuring=[ReplyPath]::IsWindowVisible($surface)'; New = '$surfacesDuring=2; $visibleDuring=$false' }
    @{ Name = 'Opus r3 P29a: every run stops after the compile'; PinOnly = $true; Old = 'if($CompileOnly) { Write-Host ''ConPTY reply-path harness C/C# compilation: PASS; no launches.''; exit 0 }'; New = 'if($true) { Write-Host ''ConPTY reply-path harness C/C# compilation: PASS; no launches.''; exit 0 }' }
    @{ Name = 'Opus r3 L2: reader a reads W records'; PinOnly = $true; File = 'reader'; Old = 'BOOL ok = ansi ? ReadConsoleInputA(in, batch, per_read, &count) : ReadConsoleInputW(in, batch, per_read, &count);'; New = 'BOOL ok = ReadConsoleInputW(in, batch, per_read, &count);' }
    @{ Name = 'Opus r3 P2: no row has a prediction'; PinOnly = $true; Old = '$prediction=Get-Prediction $step.Name $session.Mode $written'; New = '$prediction=$null' }
    @{ Name = 'Opus r3 P3: no row is built'; PinOnly = $true; Old = 'for($i=0;$i -lt $session.Steps.Count;$i++) {'; New = 'for($i=0;$i -lt 0;$i++) {' }
    @{ Name = 'Opus r3 P23: case 7''s prompt record forced'; PinOnly = $true; Old = '$case7.Steps.Add(@{Name=$inject.Name;Written=(Show $bindings[$inject.Key].Bytes);Prompt=$screen.Prompt;'; New = '$case7.Steps.Add(@{Name=$inject.Name;Written=(Show $bindings[$inject.Key].Bytes);Prompt=''PS> [?999;2n'';' }
    @{ Name = 'Opus r3 P28: the reader list cut to one'; PinOnly = $true; Old = '$Readers = @($Readers | ForEach-Object { $_ -split '','' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })'; New = '$Readers = @($Readers | ForEach-Object { $_ -split '','' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)' }
    @{ Name = 'Opus r4 Q4: the driver''s exit code read as 0'; PinOnly = $true; Old = '[DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr p,out uint code);'; New = 'public static bool GetExitCodeProcess(IntPtr p,out uint code) { code=0; return true; }' }
    @{ Name = 'Opus r4 Q1: the exit forced after the results'; PinOnly = $true; Old = '# pin-end: driver-results' + "`n"; New = '# pin-end: driver-results' + "`n" + '$exit.Code=0' + "`n" }
    @{ Name = 'Opus r4 Q23: the results region never runs'; PinOnly = $true; Edits = @(@{ Old = '# pin-begin: driver-results'; New = 'if($false) {' + "`n" + '# pin-begin: driver-results' }, @{ Old = '# pin-end: driver-results' + "`n"; New = '# pin-end: driver-results' + "`n" + '}' + "`n" }) }
    @{ Name = 'Opus r4 Q24: Get-Verdict aliased to a stub'; PinOnly = $true; Old = '# pin-begin: driver-results'; New = 'function Get-VerdictStub { ''as predicted'' }; Set-Alias Get-Verdict Get-VerdictStub' + "`n" + '# pin-begin: driver-results' }
    @{ Name = 'Opus r4 Q12: Get-RunExit replaced at run time'; PinOnly = $true; Old = 'try {' + "`n" + '    foreach($mode in $Readers) { Invoke-ReaderSession $mode }'; New = '${function:Get-RunExit}={ @{Code=0;Why=@()} }' + "`n" + 'try {' + "`n" + '    foreach($mode in $Readers) { Invoke-ReaderSession $mode }' }
    @{ Name = 'Opus r4 Q22: case 7''s controls set by index'; PinOnly = $true; Old = '# pin-begin: driver-results'; New = 'if($case7) { $case7[''Complete'']=$true; $case7[''InjectedReportShown'']=$true; $case7[''TabSwitched'']=$true }' + "`n" + '# pin-begin: driver-results' }
    @{ Name = 'Opus r4 Q14: the failures cleared before the results'; PinOnly = $true; Old = '# pin-begin: driver-results'; New = '$failures.Clear()' + "`n" + '# pin-begin: driver-results' }
    @{ Name = 'Opus r4 Q2 (r3 P10): the driver''s infrastructure failure dropped'; PinOnly = $true; Old = '    $failures.Add("infrastructure: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)")'; New = '    $null=1' }
    @{ Name = 'Opus r4 Q3 (r3 P9): the driver''s cleanup failure dropped'; PinOnly = $true; Old = 'catch { $failures.Add("owned job cleanup: $($_.Exception.Message)") }'; New = 'catch { }' }
    @{ Name = 'Opus r4 Q3b: the driver''s cleanup failure filed elsewhere'; PinOnly = $true; Old = '$failures.Add("owned job cleanup:'; New = '$sessions.Add("owned job cleanup:' }
    @{ Name = 'Sol r4 4: the driver''s cleanup failure discarded'; PinOnly = $true; Old = '$failures.Add("owned job cleanup: $($_.Exception.Message)")'; New = '$null = "owned job cleanup: $($_.Exception.Message)"' }
    @{ Name = 'Opus r4 Q6: a stuck owned process passes'; PinOnly = $true; Old = 'throw new Exception("Owned job cleanup exceeded five seconds");'; New = 'return 0;' }
    @{ Name = 'Opus r4 Q6b / Sol r4 5: the cleanup always complete'; PinOnly = $true; Old = 'if(a.activeProcesses==0) return a.totalProcesses;'; New = 'if(a.activeProcesses>=0) return a.totalProcesses;' }
    @{ Name = 'Opus r4 Q5: the clipboard sequence a constant'; PinOnly = $true; Old = '[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();'; New = 'public static uint GetClipboardSequenceNumber() { return 1; }' }
    @{ Name = 'Opus r4 Q7: every window on the private desktop'; PinOnly = $true; Old = 'bool found=false;'; New = 'bool found=true;' }
    @{ Name = 'Opus r4 Q8: the delimiter sabotage a real delimiter'; PinOnly = $true; Old = 'if($Sabotage -eq ''delimiter'') { $bindings.f1.Bytes="$([char]23)" }'; New = 'if($Sabotage -eq ''delimiter'') { $bindings.f1.Bytes="$([char]2)" }' }
    @{ Name = 'Opus r4 Q9: the control sabotage a real DA1'; PinOnly = $true; Old = 'if($Sabotage -eq ''control'') { $bindings.f4.Bytes="$([char]23)" }'; New = 'if($Sabotage -eq ''control'') { $bindings.f4.Bytes="$([char]4)" }' }
    @{ Name = 'Opus r4 Q11: a case''s bytes changed after the table'; PinOnly = $true; Old = 'if($Sabotage -eq ''control'') { $bindings.f4.Bytes="$([char]23)" }'; New = 'if($Sabotage -eq ''control'') { $bindings.f4.Bytes="$([char]23)" }' + "`n" + '$bindings.f8.Bytes=''x''' }
    @{ Name = 'Sol r4 1: CompileOnly on by default'; PinOnly = $true; Old = '[switch] $CompileOnly,'; New = '[switch] $CompileOnly=$true,' }
    @{ Name = 'Sol r4 2: SkipPSReadLine on by default'; PinOnly = $true; Old = '[switch] $SkipPSReadLine,'; New = '[switch] $SkipPSReadLine=$true,' }
    @{ Name = 'Sol r4 3: the escape byte a SUB'; PinOnly = $true; Old = '$esc = [char]27'; New = '$esc = [char]26' }
    @{ Name = 'r5 Opus L3: an inherited NOCTTY_CONPTY not refused'; Old = 'if($null -ne [Environment]::GetEnvironmentVariable(''NOCTTY_CONPTY'')) { throw'; New = 'if($false) { throw' }
    @{ Name = 'r5 Sourcery: the Run directory''s DACL not protected'; Old = '$runAcl.SetAccessRuleProtection($true,$false)'; New = '$runAcl.SetAccessRuleProtection($false,$true)' }
    @{ Name = 'r5 Sourcery: the Run directory made without its ACL'; Old = '[void][IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Run),$runAcl)'; New = '[void](New-Item -ItemType Directory -Path $Run)' }
    @{ Name = 'r5 Sourcery: the ACL read-back refuses nothing'; Old = '{ throw ''The Run directory''''s ACL did not read back as this user''''s alone; nothing runs from it.'' }'; New = '{ }' }
    @{ Name = 'r5 Sourcery: another account''s rule accepted'; Old = 'Where-Object { $_.AccessControlType -ne ''Allow'' -or $runSids -notcontains $_.IdentityReference.Value }'; New = 'Where-Object { $_.AccessControlType -ne ''Allow'' }' }
    @{ Name = 'r5 Sourcery: Everyone among the run''s accounts'; Old = '$runSids=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,''S-1-5-18'',''S-1-5-32-544'')'; New = '$runSids=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,''S-1-5-18'',''S-1-5-32-544'',''S-1-1-0'')' }
    @{ Name = 'r5 Sourcery / CodeRabbit: the history path unescaped'; Old = '-HistorySavePath ''$historyLiteral'' -HistorySaveStyle'; New = '-HistorySavePath ''$shellHistory'' -HistorySaveStyle' }
    @{ Name = 'r5 CodeRabbit: the ready path unescaped'; Old = 'Set-Content -LiteralPath ''$readyLiteral'' -Value ready'; New = 'Set-Content -LiteralPath ''$shellReady'' -Value ready' }
    @{ Name = 'r5: the history escape a no-op'; Old = '$historyLiteral=[Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shellHistory)'; New = '$historyLiteral=$shellHistory' }
    @{ Name = 'r5 CodeRabbit: case 7 complete without prompt evidence'; Old = 'if(@($shellBefore.Prompt).Count -ne 1 -or @($afterSwitch.Prompt).Count -ne 1) { throw'; New = 'if($false) { throw' }
    @{ Name = 'r5 CodeRabbit: a prompt before the switch is enough'; Old = 'if(@($shellBefore.Prompt).Count -ne 1 -or @($afterSwitch.Prompt).Count -ne 1)'; New = 'if(@($shellBefore.Prompt).Count -ne 1)' }
    @{ Name = 'r5 CodeRabbit: no clean stop needed'; Old = 'if($finished -and -not @($Session.Log | Where-Object { $_ -like ''STOP,*'' }).Count) {'; New = 'if($false) {' }
    @{ Name = 'r5 CodeRabbit: the reader writes no STOP'; File = 'reader'; Old = 'if (GetFileAttributesW(argv[4]) != INVALID_FILE_ATTRIBUTES) fprintf(g_log, "STOP,%lld\n", now_ticks());'; New = '' }
    @{ Name = 'r5 CodeRabbit: the reader writes STOP on every exit'; File = 'reader'; Old = 'if (GetFileAttributesW(argv[4]) != INVALID_FILE_ATTRIBUTES) fprintf(g_log, "STOP'; New = 'fprintf(g_log, "STOP' }
    @{ Name = 'r5 CodeRabbit: a long LOCALAPPDATA reported unset'; File = 'reader'; Old = 'if (got >= 32768) return 3;'; New = 'if (got >= 32768) return 2;' }
    @{ Name = 'r5: a failed LOCALAPPDATA read reported unset'; File = 'reader'; Old = 'if (got == 0) return GetLastError() == ERROR_ENVVAR_NOT_FOUND ? 2 : 3;'; New = 'if (got == 0) return 2;' }
    @{ Name = 'r5: an unknown LOCALAPPDATA published as unset'; Old = '''2'' { ''unset'' } default { ''unknown'' }'; New = 'default { ''unset'' }' }
    @{ Name = 'r5: the ssh readers take a Run with shell syntax'; Old = '$Run -cnotmatch ''^[A-Za-z]:\\[A-Za-z0-9_.\\-]*$'''; New = '$Run -match ''\s''' }
    @{ Name = 'r5: the ACL sabotage always on'; Old = 'if($Sabotage -eq ''acl'') {'; New = 'if($true) {' }
    @{ Name = 'r6 Opus L2: the ready escape a no-op'; Check = 'case 7''s ready path is no longer escaped as a literal'; Old = '$readyLiteral=[Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shellReady)'; New = '$readyLiteral=$shellReady' }
    @{ Name = 'r6 Opus L2: the Run rules read and execute only'; Check = 'the Run directory''s rules changed'; Old = '[Security.Principal.SecurityIdentifier]::new($sid),''FullControl'''; New = '[Security.Principal.SecurityIdentifier]::new($sid),''ReadAndExecute''' }
    @{ Name = 'r6 Sol L2: a cell''s pipe left bare'; Check = 'results.md no longer escapes a cell''s own pipe'; Old = 'function Cell($Text) { ([string]$Text).Replace(''|'',''\|'') }'; New = 'function Cell($Text) { [string]$Text }' }
    @{ Name = 'r6 Sol L2: the step cell unescaped'; Check = 'a results.md row no longer escapes each of its text cells'; Old = '(Cell $r.Step)'; New = '$r.Step' }
    @{ Name = 'round 4: a held key ends the cleanup'; Old = 'try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $keyFailures.Add((''{0}: {1}'' -f $name,$_.Exception.GetType().Name)) }'; New = 'Remove-Item -LiteralPath $path -Force' }
    @{ Name = 'round 4: the kept-key hold never released'; PinOnly = $true; Old = 'if($keyHold) { $keyHold.Dispose() }'; New = '' }
    @{ Name = 'round 4: read sizes judged on an unfinished run'; Old = '$finished=@($Session.Steps | Where-Object { $_.Barrier -eq ''OK'' }).Count -eq $Session.Planned'; New = '$finished=$true' }
    @{ Name = 'round 4: case 7''s pin markers removed'; PinOnly = $true; Old = '    # pin-end: case-7' + "`n"; New = '' }
    @{ Name = 'round 4: any command counted as a delimiter'; PinOnly = $true; Old = 'Where-Object { $_ -like ''CMD,*,02,*'' }'; New = 'Where-Object { $_ -like ''CMD,*'' }' }
    @{ Name = 'Muse 4: the APC-on-b prediction'; Old = 'if(-not $vtInput) { $prediction=@{Text=''lone \'';Exact=''\''} }'; New = 'if(-not $vtInput) { $prediction=@{Text=''lone \'';Exact=''''} }' }
    @{ Name = 'Muse 5: case 4 without its space'; Old = 'Bytes="${esc}[>1;2;3;29;30;40;100;101 q"'; New = 'Bytes="${esc}[>1;2;3;29;30;40;100;101q"' }
    @{ Name = 'Muse 7: no case 2 step'; Old = '    @{ Name=''case 2: APC feature-shaped''; Keys=@(''f16'') }'; New = '' }
    @{ Name = 'round 2: noctty.ico copied'; Old = ' | Where-Object { $_.Name -ne ''noctty.ico'' }'; New = '' }
    @{ Name = 'round 2: no AUMID comparison'; Old = '$aumidUnchanged=($aumidBefore.Keys -join ''|'') -ceq ($aumidAfter.Keys -join ''|'') -and $aumidBefore.Sha256 -ceq $aumidAfter.Sha256'; New = '$aumidUnchanged=$true' }
    @{ Name = 'round 2: no clipboard comparison'; Old = '$clipboardUnchanged=$clipboardBefore -eq $clipboardAfter'; New = '$clipboardUnchanged=$true' }
    @{ Name = 'round 2: a reader failure exits 0'; Old = 'foreach($f in $Failures) { $why.Add($f) }'; New = '' }
    @{ Name = 'round 2: a failed control exits 0'; Old = 'foreach($r in @($Rows | Where-Object { $_.Control -and $_.Verdict -ne ''as predicted'' })) { $why.Add("control failed: $($r.Reader) / $($r.Step)") }'; New = '' }
    @{ Name = 'round 2: d-notiming with the obfuscation on'; Old = '{ '' -o ObscureKeystrokeTiming=no'' }'; New = '{ '''' }' }
    @{ Name = 'round 2: ssh with agent forwarding'; Old = '-tt -a -x -k -F none'; New = '-tt -x -k -F none' }
    @{ Name = 'round 2: sshd with forwarding'; Old = '''DisableForwarding yes'','; New = '' }
    @{ Name = 'round 2: no listener PID check'; Old = 'if($listener.Count -gt 0 -and @($listener | Where-Object { $_.OwningProcess -ne $sshd.pid }).Count -gt 0) { throw ''Another process listens on the run''''s sshd port; nothing connects.'' }'; New = '' }
    @{ Name = 'round 2: ssh readers without the opt-in'; Old = 'if($sshReaders.Count -gt 0 -and -not $AllowSshFarSideUserProfileAndLocalAppData) {'; New = 'if($false) {' }
    @{ Name = 'round 2: the APC error split dropped'; Old = '    @{ Name=''case 1: APC error, split mid-body''; Keys=@(''insert'',''home''); Gap=300 }'; New = '' }
    @{ Name = 'round 2: the ssh keys kept'; Old = 'try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }'; New = 'try { $null=$path }' }
    @{ Name = 'round 2: sabotage on by default'; Old = '[string] $Sabotage = ''none'','; New = '[string] $Sabotage = ''control'',' }
    @{ Name = 'round 2: Keys posts to any window'; Old = 'if(!OnCallerDesktop(h)) throw new Exception("Refusing to post keys to a window that is not on this private desktop");'; New = '' }
    @{ Name = 'round 2: verdicts compared with -ceq'; Old = 'if([string]::Equals($Observed,[string]$Prediction.Exact,[StringComparison]::Ordinal)) { return ''as predicted'' }'; New = 'if($Observed -ceq $Prediction.Exact) { return ''as predicted'' }' }
    @{ Name = 'round 2: the in-box DA1 control dropped'; Old = 'if($inbox) { return @{Text=''the in-box conhost''''s own DA1'';Regex=''^\x1b\[\?61;[0-9;]+c$'';Control=$true} }'; New = 'if($inbox) { return @{Text=''the in-box conhost''''s own DA1'';Regex=''^\x1b\[\?61;[0-9;]+c$''} }' }
)
$replyPathMissed = [Collections.Generic.List[string]]::new()
# Where each pinned region and function lies in the harness, so a mutation must also trip the pin of
# every pinned block it changes.
$replyPathHarnessLf = $replyPathHarnessText -replace "`r`n", "`n"
$replyPathReaderLf = $replyPathReaderText -replace "`r`n", "`n"
$replyPathSpans = [Collections.Generic.List[object]]::new()
foreach ($begin in [regex]::Matches($replyPathHarnessLf, '(?m)^[ \t]*# pin-begin: ([a-z0-9-]+)[^\n]*\n')) {
    $name = $begin.Groups[1].Value
    $end = [regex]::Match($replyPathHarnessLf.Substring($begin.Index), "(?m)^[ \t]*# pin-end: $([regex]::Escape($name))[ \t]*(\n|$)")
    $replyPathSpans.Add(@{ Problem = "pinned region $name changed"; Start = $begin.Index; End = $begin.Index + $end.Index + $end.Length })
}
$replyPathSpanTokens = $null; $replyPathSpanErrors = $null
$replyPathSpanAst = [Management.Automation.Language.Parser]::ParseInput($replyPathHarnessLf, [ref]$replyPathSpanTokens, [ref]$replyPathSpanErrors)
foreach ($name in $replyPathFunctionPins.Keys) {
    $definition = @($replyPathSpanAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name }, $true))[0]
    $replyPathSpans.Add(@{ Problem = "pinned function $name changed"; Start = $definition.Extent.StartOffset; End = $definition.Extent.EndOffset })
}
foreach ($mutation in $replyPathMutations) {
    $isReader = $mutation.File -eq 'reader'
    $original = if ($isReader) { $replyPathReaderLf } else { $replyPathHarnessLf }
    $edits = if ($mutation.Edits) { @($mutation.Edits) } else { @(@{ Old = $mutation.Old; New = $mutation.New }) }
    $mutated = $original; $applies = $true
    $expected = [Collections.Generic.List[string]]::new()
    $expected.Add($(if ($isReader) { 'the reader changed' } else { 'the harness changed' }))
    foreach ($edit in $edits) {
        $old = $edit.Old -replace "`r`n", "`n"; $new = $edit.New -replace "`r`n", "`n"
        $at = $original.IndexOf($old, [StringComparison]::Ordinal)
        $here = $mutated.IndexOf($old, [StringComparison]::Ordinal)
        if ($at -lt 0 -or $original.IndexOf($old, $at + 1, [StringComparison]::Ordinal) -ge 0 -or
            $here -lt 0 -or $mutated.IndexOf($old, $here + 1, [StringComparison]::Ordinal) -ge 0) { $applies = $false; break }
        $mutated = $mutated.Substring(0, $here) + $new + $mutated.Substring($here + $old.Length)
        if (-not $isReader) {
            # The changed span in the original text: what differs once the common prefix and suffix are set aside.
            $prefix = 0; while ($prefix -lt $old.Length -and $prefix -lt $new.Length -and $old[$prefix] -ceq $new[$prefix]) { $prefix++ }
            $suffix = 0; while ($suffix -lt ($old.Length - $prefix) -and $suffix -lt ($new.Length - $prefix) -and $old[$old.Length - 1 - $suffix] -ceq $new[$new.Length - 1 - $suffix]) { $suffix++ }
            $from = $at + $prefix; $to = $at + $old.Length - $suffix
            foreach ($span in $replyPathSpans) {
                $inside = if ($from -eq $to) { $from -gt $span.Start -and $from -lt $span.End } else { $from -lt $span.End -and $to -gt $span.Start }
                if ($inside -and -not $expected.Contains($span.Problem)) { $expected.Add($span.Problem) }
            }
        }
    }
    if (-not $applies) { $replyPathMissed.Add("$($mutation.Name): its text is not in the file exactly once"); continue }
    $found = if ($isReader) { @(Get-ReplyPathProblems -Harness $replyPathHarnessLf -Reader $mutated -StopAtFirst) } else { @(Get-ReplyPathProblems -Harness $mutated -Reader $replyPathReaderLf -StopAtFirst) }
    if ($found.Count -eq 0) { $replyPathMissed.Add("$($mutation.Name): not refused"); continue }
    foreach ($want in $expected) {
        if (-not @($found | Where-Object { $_.StartsWith($want, [StringComparison]::Ordinal) }).Count) { $replyPathMissed.Add("$($mutation.Name): refused, but not by '$want'") }
    }
    # The content checks alone must refuse it too, unless only a pin can see it: so each such mutation is shown to be
    # refused by a content check, not that every check is exercised.
    $content = if ($isReader) { @(Get-ReplyPathProblems -Harness $replyPathHarnessLf -Reader $mutated -StopAtFirst -SkipPins) } else { @(Get-ReplyPathProblems -Harness $mutated -Reader $replyPathReaderLf -StopAtFirst -SkipPins) }
    if ($mutation.PinOnly -and $content.Count -gt 0) { $replyPathMissed.Add("$($mutation.Name): marked PinOnly, but a content check refuses it ('$($content[0])'); drop the mark") }
    elseif (-not $mutation.PinOnly -and $content.Count -eq 0) { $replyPathMissed.Add("$($mutation.Name): only a pin refuses it; a content check must too, or mark it PinOnly") }
    if ($mutation.Check -and -not @($content | Where-Object { $_.StartsWith($mutation.Check, [StringComparison]::Ordinal) }).Count) { $replyPathMissed.Add("$($mutation.Name): not refused by its own check, '$($mutation.Check)'") }
}
if ($replyPathMissed.Count -gt 0) { throw "The reply-path contract lets mutations through: $($replyPathMissed -join '; ')" }
