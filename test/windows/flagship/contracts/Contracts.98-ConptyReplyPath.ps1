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
#     and which rows are positive controls, and the exit policy, driven by AST
#     extraction on synthetic inputs.
# The contract then applies the council's round-1 mutations (and its own) to
# the harness and the reader, and each one must give at least one problem.

$replyPathScript = Join-Path $repoRoot 'test\windows\hidden-win11-conpty-reply-path.ps1'
$replyPathReader = Join-Path $repoRoot 'test\windows\console-reply-reader.c'

function Get-ReplyPathProblems {
    param(
        [Parameter(Mandatory)] [string] $Harness,
        [Parameter(Mandatory)] [string] $Reader,
        # For mutations: one static problem is enough, so the evaluated checks are skipped.
        [switch] $StopAtFirst
    )
    $problems = [Collections.Generic.List[string]]::new()
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
    if ($code -match '(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|Set-Clipboard|Get-Clipboard|SetClipboardData|OpenClipboard|GetClipboardData|Start-Process|Invoke-Item|Remove-Item\s+-Recurse)') {
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
    Need 'if($historyFailure -or -not $unchanged -or -not $aumidUnchanged -or -not $clipboardUnchanged -or -not $keysDeleted -or $links.Count -gt 0) {' 'a changed guard no longer stops the run'
    if ($code -notmatch '(?s)\$links\.Count -gt 0\) \{.*?exit 3') { $problems.Add('a changed guard no longer exits 3') }

    # Case 7: pwsh without a profile, history read back before anything is typed.
    Need '-e "{3}" -NoLogo -NoProfile -NoExit -Command "{4}"' 'case 7''s pwsh must start -NoLogo -NoProfile -NoExit'
    if ($code -notmatch '(?s)Set-PSReadLineOption -HistorySavePath ''\$shellHistory'' -HistorySaveStyle SaveNothing; if\(\(Get-PSReadLineOption\)\.HistorySaveStyle -eq ''SaveNothing'' -and \(Get-PSReadLineOption\)\.HistorySavePath -ceq ''\$shellHistory''\).*?did not become ready \(history isolation not confirmed\); nothing typed') {
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
    Need '-or -not $keysDeleted -or $links.Count -gt 0) {' 'a link left in the run no longer stops the run'
    Need 'finally { if($Mode -eq ''c-inbox'') { Remove-Item Env:NOCTTY_CONPTY } }' 'NOCTTY_CONPTY is not cleared after the in-box launch'
    # Verdicts compare ordinally: -ceq ignores control characters in pwsh 7 (ICU), so "ESC[A" -ceq "[A" is true.
    Need 'else { $verdict=if([string]::Equals($observed,[string]$prediction.Exact,[StringComparison]::Ordinal)) {' 'the verdict no longer compares bytes ordinally'

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
    Need 'foreach($name in $sshSecrets) { $path=Join-Path $sshDir $name; if(Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force;' 'the run''s ssh keys are no longer deleted'

    # Controls: sabotage off by default and limited to its three uses.
    Need '[ValidateSet(''none'',''delimiter'',''reader'',''control'')] [string] $Sabotage = ''none'',' 'sabotage is not off by default'
    NeedCount '$Sabotage -eq' 3 'sabotage must break exactly three things'

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
        (& $function 'Get-RunExit'), (& $function 'Get-Segments'), (& $function 'Binding-Line'))
    if ($problems.Count -gt 0 -and $StopAtFirst) { return $problems.ToArray() }
    $evaluated = @(Invoke-ContractScriptWithDeadline -Script $script:ReplyPathEvaluation -Arguments @(, $definitions) -HangMessage 'The reply-path harness''s tables and functions did not evaluate in time.')
    foreach ($p in $evaluated) { if ($p) { $problems.Add([string]$p) } }
    return $problems.ToArray()
}

# Runs in a fresh runspace: defines the harness's tables and functions, then
# checks them against what the kitty report's cases and the round-1 council
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

# Every mutation the round-1 council ran (Sol's 3, Opus's 22, Muse's 8; the
# duplicates kept once) and the contract's own: each must give a problem.
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
    @{ Name = 'round 2b: links in the run not checked'; Old = '-or -not $keysDeleted -or $links.Count -gt 0) {'; New = '-or -not $keysDeleted) {' }
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
    @{ Name = 'round 2: the ssh keys kept'; Old = 'Remove-Item -LiteralPath $path -Force;'; New = '$null=$path;' }
    @{ Name = 'round 2: sabotage on by default'; Old = '[string] $Sabotage = ''none'','; New = '[string] $Sabotage = ''control'',' }
    @{ Name = 'round 2: Keys posts to any window'; Old = 'if(!OnCallerDesktop(h)) throw new Exception("Refusing to post keys to a window that is not on this private desktop");'; New = '' }
    @{ Name = 'round 2: verdicts compared with -ceq'; Old = 'else { $verdict=if([string]::Equals($observed,[string]$prediction.Exact,[StringComparison]::Ordinal)) {'; New = 'else { $verdict=if($observed -ceq $prediction.Exact) {' }
    @{ Name = 'round 2: the in-box DA1 control dropped'; Old = 'if($inbox) { return @{Text=''the in-box conhost''''s own DA1'';Regex=''^\x1b\[\?61;[0-9;]+c$'';Control=$true} }'; New = 'if($inbox) { return @{Text=''the in-box conhost''''s own DA1'';Regex=''^\x1b\[\?61;[0-9;]+c$''} }' }
)
$replyPathMissed = [Collections.Generic.List[string]]::new()
foreach ($mutation in $replyPathMutations) {
    $isReader = $mutation.File -eq 'reader'
    $text = if ($isReader) { $replyPathReaderText } else { $replyPathHarnessText }
    $at = $text.IndexOf($mutation.Old, [StringComparison]::Ordinal)
    if ($at -lt 0 -or $text.IndexOf($mutation.Old, $at + 1, [StringComparison]::Ordinal) -ge 0) { $replyPathMissed.Add("$($mutation.Name): its text is not in the file exactly once"); continue }
    $mutated = $text.Substring(0, $at) + $mutation.New + $text.Substring($at + $mutation.Old.Length)
    $found = if ($isReader) { @(Get-ReplyPathProblems -Harness $replyPathHarnessText -Reader $mutated -StopAtFirst) } else { @(Get-ReplyPathProblems -Harness $mutated -Reader $replyPathReaderText -StopAtFirst) }
    if ($found.Count -eq 0) { $replyPathMissed.Add("$($mutation.Name): not refused") }
}
if ($replyPathMissed.Count -gt 0) { throw "The reply-path contract lets mutations through: $($replyPathMissed -join '; ')" }
