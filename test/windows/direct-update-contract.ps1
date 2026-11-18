#requires -Version 7.3
# Static admission controls for a harness that runs historical signed releases.
# No application, download, trust-store import or real-profile read occurs here.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Get-DirectUpdateProblems([string] $Text) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The acceptance harness does not parse'}
    $active=[Text.StringBuilder]::new($Text)
    foreach($token in @($tokens | Where-Object { $_.Kind -in @('Comment','HereStringLiteral','HereStringExpandable') } | Sort-Object { $_.Extent.StartOffset } -Descending)){
        $null=$active.Remove($token.Extent.StartOffset,$token.Extent.EndOffset-$token.Extent.StartOffset)
    }
    $code=$active.ToString()
    $requirements=[ordered]@{
        Native='\$native -cne \$Architecture -or \$processArchitecture -cne \$Architecture'
        Legacy="\[version\]\`$FromVersion -lt \[version\]'1\.3\.136' -and -not \`$ephemeral"
        NewRun="if \(Test-Path -LiteralPath \`$Run\) \{ throw 'Run directory must be new' \}"
        NewDownload="if \(Test-Path -LiteralPath \`$destination\) \{ throw 'Download destination already exists' \}"
        PublishedHash='(?s)if \(\(Get-Sha \$zip\) -cne \$published -or \$zipAsset\[0\]\.digest -cne "sha256:\$published"\) \{ throw.*?\[IO\.Compression\.ZipFile\]::ExtractToDirectory'
        DriverDesktop='\[HiddenWin\]::CurrentDesktopName\(\) -cne \$DesktopName'
        Profile='if\(-not \$isolated\)\{throw'
        DefaultOracle='if \(\$escaped\.Count -ne 0\) \{ throw'
        StubHash='\$result\.FinalStub\.Sha256 -cne \$result\.TargetStub\.Sha256'
        Rollback="\`$state.Phase -ceq 'rollback'\) \{ throw"
        CryptographicSignature='Assert-ReleaseSignature -Path \$Path -Label .Portable stub. -AllowedPins \$pins -TrustSelfSigned \$true'
        StubLoad='if \(\$errorCode -ne 1114\) \{ throw'
        FinalExit='if\(-not \[HiddenWin\]::GetExitCodeProcess\(\$finalHandle,\[ref\]\$finalCode\) -or \$finalCode -ne 0\)\{throw'
        MesaOptIn='(?m)^\s*\[switch\] \$HostedMesa,'
        MesaScope="if\(\`$HostedMesa -and \(-not \`$ephemeral -or \`$FromVersion -cne '1\.3\.125' -or \`$TargetVersion -cne '1\.3\.137' -or \`$Expected -cne 'Stub'\)\)\{throw"
        MesaNewDownload="if\(Test-Path -LiteralPath \`$destination\)\{throw 'Mesa download directory must be new'\}"
        MesaX64Pin="x64='11dc079e356f33ce2ff84aa399c975da1a7bdd4c470f6eef4cf359ad8b9ca80f'"
        MesaArm64Pin="arm64='067f3aca687fbf5afc8a1f41487bd051487d964d6c1686757a4d8ee6a2d3b901'"
        MesaHashBeforeExtraction='(?s)if\(\(Get-Sha \$archive\) -cne \$pins\[\$Architecture\]\)\{throw.*?& \$seven e \$archive .opengl32\.dll.'
        MesaSingleFile='if\(\$after\.Count -ne \$before\.Count\+1 -or \$changes\.Count -ne 1 -or \$changes\[0\]\.SideIndicator -cne .=>. -or \$changes\[0\]\.InputObject -cnotmatch .\^opengl32'
        MesaBacking='\$modules\.Count -ne 1 -or \$modules\[0\]\.FileName -ine \(Join-Path \$script:install .opengl32\.dll.\) -or \(Get-Sha \$modules\[0\]\.FileName\) -cne \$result\.Mesa\.DllSha256'
        MesaPreserved='if\(\(Get-Sha \(Join-Path \$script:install .opengl32\.dll.\)\) -cne \$result\.Mesa\.DllSha256\)\{throw'
        LegacyDispatch="\`$legacyPainted=\`$FromVersion -ceq '1\.3\.125'"
        Shell='--command=direct:\{3\} /D.*--clipboard-write=deny --clipboard-read=deny'
        ShellSystem="\`$shell=Join-Path \(\[Environment\]::GetFolderPath\('System'\)\) 'cmd\.exe'"
        StubLoadApi='function Get-StubLoadError\(\[string\] \$Path\) \{ \[DirectUpdateUi\]::StubLoadError\(\$Path\) \}'
        ClipboardHosted='function Invoke-ClipboardPositive\(\[string\] \$Pwsh,\[IntPtr\] \$Job,\[string\] \$DesktopName\) \{\s*if\(-not \$ephemeral\)\{return'
        HostedWinSta0='function Invoke-HostedClipboardPositive\(\[string\] \$Pwsh\) \{\s*if\(-not \$ephemeral\)\{throw'
        ClipboardSupported='if\(-not \$fact.Supported -or -not \$fact.IsolatedStation -or -not \$fact.SequenceAdvanced\)\{throw'
    }
    $problems=[Collections.Generic.List[string]]::new()
    foreach($entry in $requirements.GetEnumerator()){if($code -cnotmatch $entry.Value){$problems.Add($entry.Key)}}
    # Fixture here-strings are later written as scripts: scan ALL original text.
    if($Text -match '(?i)\b(?:Start-Process|Invoke-Item|Set-Clipboard|Get-Clipboard|Import-Certificate|Set-AuthenticodeSignature)\b|--clobber|gh\s+release\s+(?:create|edit|upload)|Remove-Item|\[System\.Windows\.Forms\.Clipboard\]'){ $problems.Add('ForbiddenOperation') }
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    function Shape($Node) {
        if($null -eq $Node){return ''}
        return [regex]::Replace($Node.Extent.Text,'[ \t\r\n]+',' ').Trim([char[]]" `t`r`n")
    }
    function Same($Node,[string] $Expected){[string]::Equals((Shape $Node),$Expected,[StringComparison]::Ordinal)}
    function Direct($Statements,[string] $Expected){@($Statements | Where-Object {Same $_ $Expected}).Count -eq 1}
    function Find-If($Statements,[string] $Condition){@($Statements | Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and (Same $_.Clauses[0].Item1 $Condition)}) | Select-Object -First 1}
    function OutsideFunction($Node){for($p=$Node.Parent;$p;$p=$p.Parent){if($p -is [Management.Automation.Language.FunctionDefinitionAst]){return $false}};return $true}
    function InFinally($Pipeline){$block=$Pipeline.Parent;return $block -is [Management.Automation.Language.StatementBlockAst] -and $block.Parent -is [Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($block,$block.Parent.Finally)}
    function Need([string] $Key,[bool] $Present){if(-not $Present){$problems.Add($Key)}}
    function Function-Statements([string] $Name){
        $nodes=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ieq $Name})
        if($nodes.Count -eq 1){return @($nodes[0].Body.EndBlock.Statements)}
        return @()
    }
    # Canonical executable statements: quoted copies and disabled wrappers cannot satisfy these.
    $guardStatements=[ordered]@{
        Native=@('Assert-NativeArchitecture','if ($native -cne $Architecture -or $processArchitecture -cne $Architecture) { throw ''Native OS and process architecture must match the requested test; emulation is not evidence'' }')
        NewRun=@('Assert-NewRun','if (Test-Path -LiteralPath $Run) { throw ''Run directory must be new'' }')
        NewDownload=@('Get-ReleaseCopy','if (Test-Path -LiteralPath $destination) { throw ''Download destination already exists'' }')
        PublishedHash=@('Get-ReleaseCopy','if ((Get-Sha $zip) -cne $published -or $zipAsset[0].digest -cne "sha256:$published") { throw ''Portable ZIP SHA-256 mismatch'' }')
        Profile=@('Assert-DriverProfile','if(-not $isolated){throw ''Driver profile isolation failed''}')
        DefaultOracle=@('Assert-NoDefaultWindows','if ($escaped.Count -ne 0) { throw ''Owned process has a window on Default; blocking further work'' }')
        StubHash=@('Assert-InstalledStub','if($result.FinalStub.Sha256 -cne $result.TargetStub.Sha256){throw ''Final stub differs from the verified candidate ZIP''}')
        Rollback=@('Add-UpdateSample','if ($state -and $state.Phase -ceq ''rollback'') { throw ''Observed portable rollback'' }')
        CryptographicSignature=@('Get-Stub','$signature=Assert-ReleaseSignature -Path $Path -Label ''Portable stub'' -AllowedPins $pins -TrustSelfSigned $true')
        StubLoad=@('Get-Stub','if ($errorCode -ne 1114) { throw ''Stub did not refuse loading with ERROR_DLL_INIT_FAILED'' }')
        MesaNewDownload=@('Add-HostedMesa','if(Test-Path -LiteralPath $destination){throw ''Mesa download directory must be new''}')
        MesaHashBeforeExtraction=@('Add-HostedMesa','if((Get-Sha $archive) -cne $pins[$Architecture]){throw ''Mesa archive SHA-256 mismatch''}')
        MesaSingleFile=@('Add-HostedMesa','if($after.Count -ne $before.Count+1 -or $changes.Count -ne 1 -or $changes[0].SideIndicator -cne ''=>'' -or $changes[0].InputObject -cnotmatch ''^opengl32\.dll:''){throw ''Mesa injection changed more than one extra file''}')
        ClipboardHosted=@('Invoke-ClipboardPositive','if(-not $ephemeral){return @{Supported=$false;FailedApi=''HostedOnly'';WinSta0WriterNeverInvoked=$true}}')
        HostedWinSta0=@('Invoke-HostedClipboardPositive','if(-not $ephemeral){throw ''WinSta0 clipboard control requires a disposable hosted runner''}')
        ReceiptArray=@('Save-Receipt','$json=ConvertTo-Json -InputObject $Value -Depth 12')
        ReceiptPublication=@('Save-Receipt','[IO.File]::Move($temporary,$path,$true)')
        StubLoadApi=@('Get-StubLoadError','[DirectUpdateUi]::StubLoadError($Path)')
    }
    foreach($entry in $guardStatements.GetEnumerator()){Need $entry.Key (Direct (Function-Statements $entry.Value[0]) $entry.Value[1])}
    $clipboardTry=@((Function-Statements 'Invoke-ClipboardPositive') | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    Need ClipboardSupported (Direct $clipboardTry.Body.Statements "if(-not `$fact.Supported -or -not `$fact.IsolatedStation -or -not `$fact.SequenceAdvanced){throw 'Clipboard positive control failed'}")
    $node=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'New-DriverEnvironment'})
    Need MinimalEnvironmentPolicy ($node.Count -eq 1 -and (Same $node[0].Body '{ $minimal=@{} foreach($name in @(''SystemRoot'',''WINDIR'',''COMSPEC'',''PATH'',''PATHEXT'',''GITHUB_ACTIONS'',''RUNNER_ENVIRONMENT'')){ if($Parent.Contains($name)){$minimal[$name]=[string]$Parent[$name]} } $minimal.LOCALAPPDATA=Join-Path $Root ''localappdata''; $minimal.APPDATA=Join-Path $Root ''appdata'' $minimal.TEMP=Join-Path $Root ''temp''; $minimal.TMP=$minimal.TEMP $minimal.USERPROFILE=Join-Path $Root ''profile'' return $minimal }'))
    $node=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Invoke-MinimalDriverEnvironment'})
    Need MinimalEnvironmentScope ($node.Count -eq 1 -and (Same $node[0].Body '{ # CreateProcess inherits this explicit whitelist; restore only this controller. # Never log the saved environment or its values. $parent=[Environment]::GetEnvironmentVariables(''Process'') $minimal=New-DriverEnvironment $parent $Run try{ foreach($name in @($parent.Keys)){[Environment]::SetEnvironmentVariable($name,$null,''Process'')} foreach($name in $minimal.Keys){[Environment]::SetEnvironmentVariable($name,$minimal[$name],''Process'')} & $Start }finally{ foreach($name in @([Environment]::GetEnvironmentVariables(''Process'').Keys)){[Environment]::SetEnvironmentVariable($name,$null,''Process'')} foreach($name in $parent.Keys){[Environment]::SetEnvironmentVariable($name,[string]$parent[$name],''Process'')} } }'))
    Need PublisherVerification (Direct (Function-Statements 'Get-ReleaseCopy') '$publishers=@(foreach($name in @(''noctty.exe'',''noctty.com'')){ $binary=Join-Path $executables[0].DirectoryName $name $signature=Assert-ReleaseSignature -Path $binary -Label ''Published portable executable'' -AllowedPins @(Get-StubPublisherPins) -TrustSelfSigned $true @{File=$name;Sha256=Get-Sha $binary;SignerSpkiSha256=$signature.SpkiSha256;CryptographicallyVerified=$true} })')
    Need MesaPins (Direct (Function-Statements 'Add-HostedMesa') '$pins=@{ x64=''11dc079e356f33ce2ff84aa399c975da1a7bdd4c470f6eef4cf359ad8b9ca80f'' arm64=''067f3aca687fbf5afc8a1f41487bd051487d964d6c1686757a4d8ee6a2d3b901'' }')
    $mesaParameter=@($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -ieq 'HostedMesa'})
    Need MesaOptIn ($mesaParameter.Count -eq 1 -and $null -eq $mesaParameter[0].DefaultValue -and @($mesaParameter[0].Attributes | Where-Object {$_.TypeName.FullName -ieq 'switch'}).Count -eq 1)
    $definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -imatch '(^|:)ephemeral$'},$true))
    Need EphemeralDefinition ($definitions.Count -eq 1 -and [object]::ReferenceEquals($definitions[0].Parent,$ast.EndBlock) -and (Same $definitions[0] "`$ephemeral=`$env:GITHUB_ACTIONS -ceq 'true' -and `$env:RUNNER_ENVIRONMENT -ceq 'github-hosted'"))
    Need LegacyStatement (Direct $ast.EndBlock.Statements "if ([version]`$FromVersion -lt [version]'1.3.136' -and -not `$ephemeral) { throw 'Historical portable identity requires an ephemeral hosted runner' }")
    Need MesaStatement (Direct $ast.EndBlock.Statements "if(`$HostedMesa -and (-not `$ephemeral -or `$FromVersion -cne '1.3.125' -or `$TargetVersion -cne '1.3.137' -or `$Expected -cne 'Stub')){throw 'Mesa fixture requires hosted 1.3.125 to 1.3.137 stub acceptance'}")
    Need NativeStatement (Direct (Function-Statements 'Assert-NativeArchitecture') "if (`$native -cne `$Architecture -or `$processArchitecture -cne `$Architecture) { throw 'Native OS and process architecture must match the requested test; emulation is not evidence' }")
    $controller=Find-If $ast.EndBlock.Statements '-not $Driver'
    Need RunPathCall (Direct $controller.Clauses[0].Item2.Statements '$Run=Get-RunPath $Run')
    Need ParentDesktop (Direct $controller.Clauses[0].Item2.Statements "if([HiddenWin]::CurrentDesktopName() -cne 'Default'){throw 'Controller must observe the Default desktop'}")
    Need RunVolume (Direct $controller.Clauses[0].Item2.Statements "if(`$runFree -le 20GB){throw 'Run volume has 20 GB or less free'}")
    Need HistoryStart (Direct $controller.Clauses[0].Item2.Statements "`$historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'direct-update-acceptance'")
    $controllerTry=@($controller.Clauses[0].Item2.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    $positive=@($controllerTry.Body.Statements | Where-Object {Same $_ 'Invoke-DefaultOraclePositive $pwsh'})
    $launches=@($controllerTry.Body.Statements | Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$launch'})
    Need DefaultPositiveCall ($positive.Count -eq 1 -and $launches.Count -eq 1 -and $positive[0].Extent.StartOffset -lt $launches[0].Extent.StartOffset)
    $positiveTry=@((Function-Statements 'Invoke-DefaultOraclePositive') | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    Need DefaultPositiveVerdict (Direct $positiveTry.Body.Statements "if(-not `$detected -or -not `$refused){throw 'Default oracle positive control failed'}")
    Need MinimalEnvironmentCall (Direct $controllerTry.Body.Statements "`$launch=Invoke-MinimalDriverEnvironment { [HiddenWin]::Launch(`$pwsh,`$line,`$Run,`"WinSta0\`$DesktopName`",`$job,(Join-Path `$Run 'driver-raw.log')) }")
    Need PrivateClipboardCall (Direct $controllerTry.Body.Statements '$clipboardPositive=Invoke-ClipboardPositive $pwsh $job $DesktopName')
    Need DriverBudget (Direct $controllerTry.Body.Statements '$deadline=[datetime]::UtcNow.AddSeconds(8*$TimeoutSeconds+300)')
    $networkTry=@((Function-Statements 'Invoke-ReleaseGh') | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    Need NetworkTimeout (Direct $networkTry.Body.Statements "if(-not `$child.WaitForExit(`$Seconds*1000)){throw 'Release request timed out'}")
    Need NetworkHidden (Direct (Function-Statements 'Invoke-ReleaseGh') '$info.CreateNoWindow=$true')
    $loops=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.DoWhileStatementAst] -and (OutsideFunction $n)},$true))
    $loop=if($loops.Count -eq 1){$loops[0]}else{$null}
    Need DefaultCall ($null -ne $loop -and (Same $loop.Body.Statements[0] 'Assert-NoDefaultWindows $job'))
    $ready=Find-If $loop.Body.Statements "Test-Path -LiteralPath (Join-Path `$Run 'driver-ready.json')"
    $done=Find-If $ready.Clauses[0].Item2.Statements "Test-Path -LiteralPath (Join-Path `$Run 'driver-done')"
    Need PrivateSentinel (Direct $done.ElseClause.Statements "if(@(`$private | Where-Object ProcessId -EQ `$launch.pid).Count -eq 0){throw 'Private driver sentinel was not observed'}")
    $driver=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    Need DriverDesktopStatement (Direct $driver.Body.Statements 'if($DesktopName -cnotmatch ''^noctty-hw-[a-f0-9]{32}$'' -or [HiddenWin]::CurrentDesktopName() -cne $DesktopName){throw ''Driver is not on its private desktop''}')
    Need FinalExit (Direct $driver.Body.Statements 'if(-not [HiddenWin]::GetExitCodeProcess($finalHandle,[ref]$finalCode) -or $finalCode -ne 0){throw ''Final application exited unsuccessfully''}')
    Need LegacyDispatch (Direct $driver.Body.Statements '$legacyPainted=$FromVersion -ceq ''1.3.125''')
    Need Shell (Direct $driver.Body.Statements '$line=''"{0}" --window-save-state=never "--command=direct:{3} /D" --clipboard-write=deny --clipboard-read=deny --single-instance=false --class={1} --auto-update=download --auto-update-feed-url={2} --confirm-close-surface=false --keybind=f7=check_for_updates'' -f $exe,$class,$feed,$shell')
    Need ShellSystem (Direct $driver.Body.Statements '$shell=Join-Path ([Environment]::GetFolderPath(''System'')) ''cmd.exe''')
    $mesaBodies=@($driver.Body.Statements | Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and (Same $_.Clauses[0].Item1 '$HostedMesa')} | ForEach-Object {$_.Clauses[0].Item2})
    $moduleTries=@($mesaBodies | ForEach-Object {$_.Statements} | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
    Need MesaBacking ($moduleTries.Count -eq 1 -and (Direct $moduleTries[0].Body.Statements 'if($modules.Count -ne 1 -or $modules[0].FileName -ine (Join-Path $script:install ''opengl32.dll'') -or (Get-Sha $modules[0].FileName) -cne $result.Mesa.DllSha256){throw ''Mesa module backing mismatch''}'))
    Need MesaPreserved (@($mesaBodies | Where-Object {Direct $_.Statements 'if((Get-Sha (Join-Path $script:install ''opengl32.dll'')) -cne $result.Mesa.DllSha256){throw ''Mesa extra file was not preserved''}'}).Count -eq 1)
    Need DriverProfileCall (Direct $driver.Body.Statements '$isolated=Assert-DriverProfile $env:LOCALAPPDATA $env:APPDATA $Run')
    Need DriverCredentials (Direct $driver.Body.Statements "if(-not `$credentialsAbsent){throw 'Driver workflow credentials were inherited'}")
    $removed=Find-If $driver.Body.Statements "`$Expected -ceq 'Removed'"
    Need SourceStubCall (Direct $removed.Clauses[0].Item2.Statements "`$result.BeforeStub=Assert-SourceStub (Join-Path `$script:install 'ghostty-vt.dll')")
    $rejected=Find-If $driver.Body.Statements "`$Expected -ceq 'Rejected'"
    Need FinalizeCall (Direct $rejected.ElseClause.Statements "Wait-Check 'target confirmed and helper finalized' { Test-FinalizedUpdate (Get-UpdateState `$script:install) `$script:states `$exe (Join-Path `$target 'noctty.exe') }")
    $stub=Find-If $rejected.ElseClause.Statements "`$Expected -ceq 'Stub'"
    Need InstalledStubCall (Direct $stub.Clauses[0].Item2.Statements "Assert-InstalledStub `$result (Join-Path `$script:install 'ghostty-vt.dll')")
    $clipboardCalls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Assert-ClipboardSequence' -and (OutsideFunction $n)},$true))
    Need ClipboardCall ($clipboardCalls.Count -eq 1 -and (Same $clipboardCalls[0] 'Assert-ClipboardSequence $clipboardBefore $clipboardAfter') -and (InFinally $clipboardCalls[0].Parent))
    $receiptCalls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Write-IsolationReceipt' -and (OutsideFunction $n)},$true))
    Need HistoryReceiptCall ($receiptCalls.Count -eq 1 -and (Same $receiptCalls[0] 'Write-IsolationReceipt $historyGuard $isolation') -and (InFinally $receiptCalls[0].Parent))
    $writer=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-IsolationReceipt'},$true)) | Select-Object -First 1
    Need HistoryCall (Direct $writer.Body.EndBlock.Statements 'try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure=$_ }')
    $hostedIfs=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and (Same $n.Clauses[0].Item1 '$ephemeral') -and (OutsideFunction $n)},$true))
    $hostedIf=if($hostedIfs.Count -eq 1){$hostedIfs[0]}else{$null}
    Need HostedWinSta0Call ($null -ne $hostedIf -and (InFinally $hostedIf) -and (Direct $hostedIf.Clauses[0].Item2.Statements '$isolation.HostedClipboardPositive=Invoke-HostedClipboardPositive $pwsh'))
    $hostedFunction=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-HostedClipboardPositive'},$true)) | Select-Object -First 1
    $hostedTry=@($hostedFunction.Body.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    Need HostedParentReader ((Direct $hostedTry.Body.Statements '$parentBefore=[HiddenWin]::GetClipboardSequenceNumber()') -and (Direct $hostedTry.Body.Statements '$parentAfter=[HiddenWin]::GetClipboardSequenceNumber()'))
    Need HostedVerdictCall (Direct $hostedTry.Body.Statements 'Assert-HostedClipboardControl $fact $parentBefore $parentAfter')
    foreach($name in @('Assert-NativeArchitecture','Assert-NewRun','Assert-DriverProfile','Assert-NoDefaultWindows','Assert-ClipboardSequence','Add-UpdateSample','Test-FinalizedUpdate','Assert-InstalledStub','Assert-RejectedCopy','Assert-SourceStub','Assert-LocalState')){
        if(@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $name},$true)).Count -eq 0){$problems.Add("MissingCall:$name")}
    }
    return @($problems.ToArray())
}
function Get-ClipboardHelperProblems([string] $Text,[switch] $Hosted) {
    # Preserve offsets while masking C# comments and literals. A string containing
    # a guarded call is data, and preprocessor branches are never admitted here.
    $lex='(?s)/\*.*?\*/|//[^\r\n]*|@"(?:""|[^"])*"|"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*'''
    $structure=[regex]::Replace($Text,$lex,{param($m) [regex]::Replace($m.Value,'[^\r\n]',' ')})
    $code=[regex]::Replace($Text,$lex,{param($m) if($m.Value.StartsWith('//') -or $m.Value.StartsWith('/*')){[regex]::Replace($m.Value,'[^\r\n]',' ')}else{$m.Value}})
    $requirements=if($Hosted){[ordered]@{
        HostedEnvironment='if\(!String.Equals\(Environment.GetEnvironmentVariable\("GITHUB_ACTIONS"\),"true",StringComparison.Ordinal\) \|\|\s*!String.Equals\(Environment.GetEnvironmentVariable\("RUNNER_ENVIRONMENT"\),"github-hosted",StringComparison.Ordinal\)\)\s*throw'
        HostedStation='!String.Equals\(ObjectName\(GetProcessWindowStation\(\)\),"WinSta0",StringComparison.OrdinalIgnoreCase\)'
        HostedDesktop='!desktop.StartsWith\("noctty-hw-",StringComparison.Ordinal\) \|\| !Guid.TryParseExact'
        HostedOpen='RequireHostedWinSta0\(\); if\(!OpenClipboard\(window\)\)'
        HostedEmpty='RequireHostedWinSta0\(\); if\(!EmptyClipboard\(\)\)'
        HostedSet='RequireHostedWinSta0\(\); if\(SetClipboardData\(13,memory\)==IntPtr.Zero\)'
        HostedClose='memory=IntPtr.Zero; RequireHostedWinSta0\(\); CloseClipboard\(\);'
        HostedFinallyClose='if\(opened\)\{RequireHostedWinSta0\(\);CloseClipboard\(\);\}'
        HostedBefore='RequireHostedWinSta0\(\); fact.Before=GetClipboardSequenceNumber\(\);'
        HostedAfter='RequireHostedWinSta0\(\); fact.After=GetClipboardSequenceNumber\(\);'
    }}else{[ordered]@{
        FreshStation='station=CreateWindowStationW\(null,0,0x000F037F,IntPtr.Zero\);'
        StationIdentity='GetProcessWindowStation\(\) != station'
        NotWinSta0='String.Equals\(name.ToString\(\), "WinSta0", StringComparison.OrdinalIgnoreCase\)'
        NonemptyStation='name.Length == 0'
        StationSwitch='if\(!SetProcessWindowStation\(station\)\) throw'
        ThreadSwitch='if\(!SetThreadDesktop\(desktop\)\) throw'
        PrivateOpen='RequirePrivate\(station\); if\(!OpenClipboard\(window\)\)'
        PrivateEmpty='RequirePrivate\(station\); if\(!EmptyClipboard\(\)\)'
        PrivateSet='RequirePrivate\(station\); if\(SetClipboardData\(13,memory\)==IntPtr.Zero\)'
        PrivateClose='memory=IntPtr.Zero; RequirePrivate\(station\); CloseClipboard\(\);'
        PrivateFinallyClose='if\(opened\) \{ RequirePrivate\(station\); CloseClipboard\(\); \}'
        PrivateBefore='RequirePrivate\(station\); fact.Before=GetClipboardSequenceNumber\(\);'
        PrivateAfter='RequirePrivate\(station\); fact.After=GetClipboardSequenceNumber\(\);'
    }}
    $problems=[Collections.Generic.List[string]]::new()
    $gatePattern=if($Hosted){'(?s)static void RequireHostedWinSta0\(\) \{.*?\n    \}'}else{'(?s)static void RequirePrivate\(IntPtr station\) \{.*?\n    \}'}
    $expectedGate=if($Hosted){
        'static void RequireHostedWinSta0() { if(!String.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"),"true",StringComparison.Ordinal) || !String.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"),"github-hosted",StringComparison.Ordinal)) throw new Exception("Hosted-only clipboard control"); string desktop=ObjectName(GetThreadDesktop(GetCurrentThreadId())); Guid id; if(!String.Equals(ObjectName(GetProcessWindowStation()),"WinSta0",StringComparison.OrdinalIgnoreCase) || !desktop.StartsWith("noctty-hw-",StringComparison.Ordinal) || !Guid.TryParseExact(desktop.Substring(10),"N",out id)) throw new Exception("Hosted private desktop identity check failed"); }'
    }else{
        'static void RequirePrivate(IntPtr station) { var name=new StringBuilder(256); int needed; if (station == IntPtr.Zero || GetProcessWindowStation() != station || !GetUserObjectInformationW(station, 2, name, 512, out needed) || name.Length == 0 || String.Equals(name.ToString(), "WinSta0", StringComparison.OrdinalIgnoreCase)) throw new Exception("Private station identity check failed"); }'
    }
    $gates=[regex]::Matches($structure,$gatePattern)
    $gate=if($gates.Count -eq 1){$code.Substring($gates[0].Index,$gates[0].Length)}else{''}
    foreach($entry in $requirements.GetEnumerator()){
        $scope=if($entry.Key -in @('HostedEnvironment','HostedStation','HostedDesktop','StationIdentity','NotWinSta0','NonemptyStation')){$gate}else{$structure}
        if($scope -cnotmatch $entry.Value){$problems.Add($entry.Key)}
    }
    if($gates.Count -ne 1 -or -not [string]::Equals([regex]::Replace($gate,'[ \t\r\n]+',' '),$expectedGate,[StringComparison]::Ordinal)){$problems.Add('CompleteStationGate')}
    if($structure -match '(?m)^\s*#\s*(?:if|define)\b'){$problems.Add('Preprocessor')}
    if($Text -match '\$@?"|@\$"|"""'){$problems.Add('UnsupportedLiteral')}
    foreach($entry in (@{OpenClipboard=2;EmptyClipboard=2;SetClipboardData=2;CloseClipboard=3;GetClipboardSequenceNumber=3}).GetEnumerator()){
        if([regex]::Matches($structure,('\b'+$entry.Key+'\s*\(')).Count -ne $entry.Value){$problems.Add('ClipboardCallCount')}
    }
    if($structure -match '\b(?:GetClipboardData|EnumClipboardFormats)\s*\('){$problems.Add('ClipboardContentRead')}
    return @($problems.ToArray())
}
function Invoke-DirectUpdateVerdicts([string] $Text,[string] $Root) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Behavioural fixture must parse'}
    $names=@('Get-RunPath','New-DriverEnvironment','Save-Receipt','Get-Sha','Get-Listing','Get-Stub','Assert-NativeArchitecture','Assert-NewRun','Assert-DriverProfile','Assert-NoDefaultWindows','Assert-ClipboardSequence','Add-UpdateSample','Test-FinalizedUpdate','Assert-InstalledStub','Get-SourceSnapshot','Assert-RejectedCopy','Assert-SourceStub','Get-NocttyJumpList','Assert-LocalState','Write-IsolationReceipt','Assert-HostedClipboardControl')
    $definitions=foreach($name in $names){
        $found=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
        if($found.Count -ne 1){throw "Verdict definition is absent or ambiguous: $name"}
        $found[0].Extent.Text
    }
    # Only actual FunctionDefinitionAst nodes are loaded, never the harness body,
    # string literals containing a guard, downloads, Add-Type or app launches.
    & {
        param($Definitions,$Root)
        . ([scriptblock]::Create($Definitions -join "`n"))
        $failures=[Collections.Generic.List[string]]::new()
        function Refuses($Name,[scriptblock] $Body){$threw=$false;try{& $Body}catch{$threw=$true};if(-not $threw){$failures.Add($Name)}}
        function Get-DefaultWindowRows($Job){@($script:fakeRows)}
        function Get-StubLoadError($Path){$script:fakeLoadError}
        function Assert-GhosttyVtStub($Path){}
        function Get-UpdaterPublisherSpkiPins($SourcePath){'fixture-pin'}
        function Get-StubPublisherPins {'fixture-pin'}
        function Assert-ReleaseSignature($Path,$Label,$AllowedPins,$TrustSelfSigned){@{Status='fixture';Thumbprint='fixture';SpkiSha256='fixture'}}
        function Get-PeDataDirectories($Path){@(@{Rva=0;Size=0},@{Rva=0;Size=0})}
        $receiptWriter=${function:Save-Receipt}
        function Save-Receipt($Name,$Value){$script:savedIsolation=$Value}
        function Assert-WindowsHarnessHistoryGuard($Guard){if($script:historyShouldFail){throw 'Fixture history changed'}}

        $Run=Join-Path $Root 'receipts'; $null=New-Item -ItemType Directory -Path $Run
        & $receiptWriter -Name 'one.json' -Value @(@{Phase='fixture'})
        $one=Get-Content -LiteralPath (Join-Path $Run 'one.json') -Raw
        if(-not $one.TrimStart().StartsWith('[') -or @(ConvertFrom-Json -InputObject $one).Count -ne 1){$failures.Add('ReceiptArray')}
        if(@(Get-ChildItem -LiteralPath $Run -Filter '*.tmp').Count){$failures.Add('ReceiptPublication')}
        if(-not [string]::Equals((Get-RunPath ($Root+'\')),$Root,[StringComparison]::OrdinalIgnoreCase)){$failures.Add('RunPath')}
        $driveRoot=[IO.Path]::GetPathRoot($Root)
        if(-not [string]::Equals((Get-RunPath $driveRoot),$driveRoot,[StringComparison]::OrdinalIgnoreCase)){$failures.Add('RunRoot')}
        $minimal=New-DriverEnvironment @{PATH='fixture';GH_TOKEN='fixture-secret';GITHUB_TOKEN='fixture-secret';UNRELATED_SECRET='fixture-secret';GITHUB_ACTIONS='true'} $Root
        if($minimal.Contains('GH_TOKEN') -or $minimal.Contains('GITHUB_TOKEN') -or $minimal.Contains('UNRELATED_SECRET') -or $minimal.PATH -cne 'fixture' -or $minimal.LOCALAPPDATA -cne (Join-Path $Root 'localappdata')){$failures.Add('MinimalEnvironment')}

        Assert-NativeArchitecture x64 x64 x64
        Refuses Native {Assert-NativeArchitecture arm64 x64 x64}
        Refuses NewRun {Assert-NewRun $Root}
        Assert-NewRun (Join-Path $Root 'absent')
        $null=Assert-DriverProfile (Join-Path $Root 'localappdata') (Join-Path $Root 'appdata') $Root
        Refuses Profile {Assert-DriverProfile 'wrong' (Join-Path $Root 'appdata') $Root}
        $script:fakeRows=@(); Assert-NoDefaultWindows 0
        $script:fakeRows=@(@{ProcessId=1}); Refuses DefaultOracle {Assert-NoDefaultWindows 0}
        Assert-ClipboardSequence 0 0
        Refuses Clipboard {Assert-ClipboardSequence 0 1}
        $states=[Collections.Generic.List[object]]::new()
        Add-UpdateSample @{Phase='swapped'} $states fixture
        Refuses Rollback {Add-UpdateSample @{Phase='rollback'} $states fixture}
        # A refused rollback may have appended under a mutant; use fresh positive data.
        $states=@(@{State=@{Phase='swapped'}},@{State=@{Phase='confirmed'}})
        $exe=Join-Path $Root 'noctty.exe'; $other=Join-Path $Root 'other.exe'
        [IO.File]::WriteAllText($exe,'fixture-exe'); [IO.File]::WriteAllText($other,'different-exe')
        $clear=@{Phase=$null;StagedVersion=$null}
        if(-not (Test-FinalizedUpdate $clear $states $exe $exe)){$failures.Add('FinalizedPositive')}
        if(Test-FinalizedUpdate $clear $states $exe $other){$failures.Add('FinalExe')}
        if(Test-FinalizedUpdate $clear @(@{State=@{Phase='swapped'}}) $exe $exe){$failures.Add('Confirmed')}
        if(Test-FinalizedUpdate $clear @(@{State=@{Phase='confirmed'}},@{State=@{Phase='swapped'}}) $exe $exe){$failures.Add('ConfirmationOrder')}
        $locked=[IO.File]::Open($exe,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{try{if(Test-FinalizedUpdate $clear $states $exe $other){$failures.Add('TransientHash')}}catch{$failures.Add('TransientHash')}}finally{$locked.Dispose()}
        $script:fakeLoadError=1114
        $null=Get-Stub $exe
        $script:fakeLoadError=0
        Refuses StubLoad {Get-Stub $exe}
        function Get-Stub($Path){@{Sha256=$script:fixtureStubHash}}
        $script:fixtureStubHash='target'; $result=@{TargetStub=@{Sha256='target'}}
        Assert-InstalledStub $result $exe
        $script:fixtureStubHash='wrong'
        Refuses StubHash {Assert-InstalledStub $result $exe}
        Refuses SourceStub {Assert-SourceStub (Join-Path $Root 'missing-stub.dll')}
        $null=Assert-SourceStub $exe
        $good=Join-Path $Root 'good'; $missing=Join-Path $Root 'missing'; $changed=Join-Path $Root 'changed'
        foreach($directory in @($good,$missing,$changed)){
            $null=New-Item -ItemType Directory -Path $directory
            [IO.File]::WriteAllText((Join-Path $directory 'noctty.exe'),'same-exe')
        }
        [IO.File]::WriteAllText((Join-Path $good 'ghostty-vt.dll'),'same-stub')
        [IO.File]::WriteAllText((Join-Path $changed 'ghostty-vt.dll'),'changed-stub')

        $hiddenFile=Join-Path $good 'hidden-original'; [IO.File]::WriteAllText($hiddenFile,'hidden')
        [IO.File]::SetAttributes($hiddenFile,[IO.FileAttributes]::Hidden)
        $hiddenDir=Join-Path $good 'hidden-directory'; $null=New-Item -ItemType Directory -Path $hiddenDir
        [IO.File]::SetAttributes($hiddenDir,[IO.FileAttributes]::Hidden)
        [IO.File]::WriteAllText((Join-Path $hiddenDir 'nested'),'hidden-child')
        $hiddenNames=@(Get-SourceSnapshot $good).Name
        if($hiddenNames -cnotcontains 'hidden-original' -or $hiddenNames -cnotcontains (Join-Path 'hidden-directory' 'nested')){$failures.Add('HiddenInventory')}
        [IO.File]::SetAttributes($hiddenFile,[IO.FileAttributes]::Normal)
        [IO.File]::SetAttributes($hiddenDir,[IO.FileAttributes]::Directory)
        [IO.File]::Delete($hiddenFile); [IO.File]::Delete((Join-Path $hiddenDir 'nested')); [IO.Directory]::Delete($hiddenDir)

        $before=@(Get-SourceSnapshot $good)
        Assert-RejectedCopy $before $good $clear
        $runtime=[IO.File]::Open((Join-Path $good 'update-state.json.lock'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{try{Assert-RejectedCopy $before $good $clear}catch{$failures.Add('RuntimeHashRead')}}finally{$runtime.Dispose()}
        Refuses MissingSidecar {Assert-RejectedCopy $before $missing $clear}
        Refuses ChangedSidecar {Assert-RejectedCopy $before $changed $clear}
        Refuses RejectedStage {Assert-RejectedCopy $before $good @{Phase='pending';StagedVersion='1.4.100'}}
        $fingerprint=@{Exists=$true;Hash='a';Modified='t'}
        $null=Assert-LocalState $fingerprint $fingerprint @() @()
        Refuses Startup {Assert-LocalState $fingerprint @{Exists=$true;Hash='b';Modified='t'} @() @()}
        Refuses JumpList {Assert-LocalState $fingerprint $fingerprint @(@{Path='c2214d6ebc43ff3f.customDestinations-ms';Written='a'}) @(@{Path='c2214d6ebc43ff3f.customDestinations-ms';Written='b'})}
        try{$null=Assert-LocalState $fingerprint $fingerprint @(@{Path='another-app.customDestinations-ms';Written='a'}) @(@{Path='another-app.customDestinations-ms';Written='b'})}catch{$failures.Add('UnrelatedJumpList')}
        $script:historyShouldFail=$false; $script:savedIsolation=$null
        Write-IsolationReceipt @{} @{}
        if($script:savedIsolation.HistoryUnchanged -ne $true){$failures.Add('HistoryPositive')}
        $script:historyShouldFail=$true; $script:savedIsolation=$null
        Refuses HistoryFailure {Write-IsolationReceipt @{} @{}}
        if($null -eq $script:savedIsolation -or $script:savedIsolation.HistoryUnchanged -ne $false){$failures.Add('HistoryFailureReceipt')}
        Assert-HostedClipboardControl @{Supported=$true;HostedWinSta0=$true;Before=1;After=2} 1 2
        Refuses HostedUnsupported {Assert-HostedClipboardControl @{Supported=$false;HostedWinSta0=$true} 1 2}
        Refuses HostedDeadReader {Assert-HostedClipboardControl @{Supported=$true;HostedWinSta0=$true;Before=1;After=2} 1 1}
        Refuses HostedCounterMismatch {Assert-HostedClipboardControl @{Supported=$true;HostedWinSta0=$true;Before=7;After=8} 1 2}
        return @($failures.ToArray())
    } $definitions $Root
}
$source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'direct-update-acceptance.ps1') -Raw
$issues=@(Get-DirectUpdateProblems $source)
if($issues.Count){throw "Direct update admission failed: $($issues -join ', ')"}
$controls=[ordered]@{
    Native=@('$native -cne $Architecture -or $processArchitecture -cne $Architecture','$false')
    Legacy=@("[version]`$FromVersion -lt [version]'1.3.136' -and -not `$ephemeral",'$false')
    NewRun=@("if (Test-Path -LiteralPath `$Run) { throw 'Run directory must be new' }","# if (Test-Path -LiteralPath `$Run) { throw 'Run directory must be new' }")
    NewDownload=@("if (Test-Path -LiteralPath `$destination) { throw 'Download destination already exists' }",'')
    PublishedHash=@('(Get-Sha $zip) -cne $published -or $zipAsset[0].digest -cne "sha256:$published"','$false')
    DriverDesktop=@('[HiddenWin]::CurrentDesktopName() -cne $DesktopName','$false')
    Profile=@('if(-not $isolated){throw','if($false){throw')
    DefaultOracle=@('if ($escaped.Count -ne 0) { throw','if ($false) { throw')
    StubHash=@('$result.FinalStub.Sha256 -cne $result.TargetStub.Sha256','$false')
    Rollback=@("`$state.Phase -ceq 'rollback') { throw","`$state.Phase -ceq 'ignored') { throw")
    CryptographicSignature=@('Assert-ReleaseSignature -Path $Path -Label ''Portable stub'' -AllowedPins $pins -TrustSelfSigned $true','Get-AuthenticodeSignature -LiteralPath $Path')
    StubLoad=@('if ($errorCode -ne 1114) { throw','if ($false) { throw')
    FinalExit=@('if(-not [HiddenWin]::GetExitCodeProcess($finalHandle,[ref]$finalCode) -or $finalCode -ne 0){throw','if($false){throw')
    MesaOptIn=@('[switch] $HostedMesa,','[switch] $HostedMesa = $true,')
    MesaScope=@("if(`$HostedMesa -and (-not `$ephemeral -or `$FromVersion -cne '1.3.125' -or `$TargetVersion -cne '1.3.137' -or `$Expected -cne 'Stub')){throw",'if($false){throw')
    MesaNewDownload=@("if(Test-Path -LiteralPath `$destination){throw 'Mesa download directory must be new'}",'')
    MesaX64Pin=@("x64='11dc079e356f33ce2ff84aa399c975da1a7bdd4c470f6eef4cf359ad8b9ca80f'","x64='unverified'")
    MesaArm64Pin=@("arm64='067f3aca687fbf5afc8a1f41487bd051487d964d6c1686757a4d8ee6a2d3b901'","arm64='unverified'")
    MesaHashBeforeExtraction=@('(Get-Sha $archive) -cne $pins[$Architecture]','$false')
    MesaSingleFile=@('$after.Count -ne $before.Count+1 -or $changes.Count -ne 1 -or $changes[0].SideIndicator -cne ''=>'' -or $changes[0].InputObject -cnotmatch ''^opengl32\.dll:''','$false')
    MesaBacking=@('$modules.Count -ne 1 -or $modules[0].FileName -ine (Join-Path $script:install ''opengl32.dll'') -or (Get-Sha $modules[0].FileName) -cne $result.Mesa.DllSha256','$false')
    MesaPreserved=@('(Get-Sha (Join-Path $script:install ''opengl32.dll'')) -cne $result.Mesa.DllSha256','$false')
    LegacyDispatch=@("`$legacyPainted=`$FromVersion -ceq '1.3.125'",'$legacyPainted=$true')
    Shell=@('--command=direct:{3} /D','--command=cmd.exe')
    ShellSystem=@("`$shell=Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'","`$shell='cmd.exe'")
    StubLoadApi=@('[DirectUpdateUi]::StubLoadError($Path)','1114')
    ForbiddenOperation=@("`$ErrorActionPreference = 'Stop'","`$ErrorActionPreference = 'Stop'; Set-Clipboard fixture")
    ClipboardHosted=@("if(-not `$ephemeral){return @{Supported=`$false;FailedApi='HostedOnly';WinSta0WriterNeverInvoked=`$true}}",'')
    HostedWinSta0=@("if(-not `$ephemeral){throw 'WinSta0 clipboard control requires a disposable hosted runner'}",'')
    ClipboardSupported=@('if(-not $fact.Supported -or -not $fact.IsolatedStation -or -not $fact.SequenceAdvanced){throw','if($false){throw')
}
$sites=[ordered]@{
    RunPathCall=@('$Run=Get-RunPath $Run','$Run=[IO.Path]::GetFullPath($Run)')
    ParentDesktop=@("if([HiddenWin]::CurrentDesktopName() -cne 'Default'){throw 'Controller must observe the Default desktop'}",'')
    RunVolume=@("if(`$runFree -le 20GB){throw 'Run volume has 20 GB or less free'}",'')
    DriverBudget=@('$deadline=[datetime]::UtcNow.AddSeconds(8*$TimeoutSeconds+300)','$deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)')
    NetworkTimeout=@("if(-not `$child.WaitForExit(`$Seconds*1000)){throw 'Release request timed out'}",'')
    NetworkHidden=@('$info.CreateNoWindow=$true','$info.CreateNoWindow=$false')
    DriverCredentials=@("if(-not `$credentialsAbsent){throw 'Driver workflow credentials were inherited'}",'')
    EphemeralDefinition=@('$ephemeral=$env:GITHUB_ACTIONS -ceq ''true'' -and $env:RUNNER_ENVIRONMENT -ceq ''github-hosted''','$ephemeral=$true')
    DefaultPositiveCall=@('Invoke-DefaultOraclePositive $pwsh','')
    DefaultPositiveVerdict=@('if(-not $detected -or -not $refused){throw ''Default oracle positive control failed''}','')
    MinimalEnvironmentCall=@('$launch=Invoke-MinimalDriverEnvironment {','$launch=& {')
    ReceiptArray=@('$json=ConvertTo-Json -InputObject $Value -Depth 12','$json=$Value | ConvertTo-Json -Depth 12')
    ReceiptPublication=@('[IO.File]::Move($temporary,$path,$true)','')
    PublisherVerification=@('-Label ''Published portable executable''','-Label ''Unpinned portable executable''')
    DefaultCall=@('Assert-NoDefaultWindows $job','')
    ClipboardCall=@('Assert-ClipboardSequence $clipboardBefore $clipboardAfter','Assert-ClipboardSequence $clipboardBefore $clipboardBefore')
    HistoryCall=@('Assert-WindowsHarnessHistoryGuard -Guard $historyGuard','')
    HistoryStart=@("`$historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'direct-update-acceptance'",'$historyGuard=$null')
    DriverProfileCall=@('$isolated=Assert-DriverProfile $env:LOCALAPPDATA $env:APPDATA $Run','$isolated=Assert-DriverProfile (Join-Path $Run ''localappdata'') (Join-Path $Run ''appdata'') $Run')
    PrivateSentinel=@("{throw 'Private driver sentinel was not observed'}",'{}')
    FinalizeCall=@('{ Test-FinalizedUpdate (','{ $true; Test-FinalizedUpdate (')
    InstalledStubCall=@("Assert-InstalledStub `$result (Join-Path `$script:install 'ghostty-vt.dll')","if(`$false){Assert-InstalledStub `$result (Join-Path `$script:install 'ghostty-vt.dll')}")
    SourceStubCall=@("`$result.BeforeStub=Assert-SourceStub (Join-Path `$script:install 'ghostty-vt.dll')","if(`$false){`$result.BeforeStub=Assert-SourceStub (Join-Path `$script:install 'ghostty-vt.dll')}")
    HistoryReceiptCall=@('Write-IsolationReceipt $historyGuard $isolation','if($false){Write-IsolationReceipt $historyGuard $isolation}')
    PrivateClipboardCall=@('$clipboardPositive=Invoke-ClipboardPositive $pwsh $job $DesktopName','if($false){$clipboardPositive=Invoke-ClipboardPositive $pwsh $job $DesktopName}')
    HostedWinSta0Call=@('if($ephemeral){$isolation.HostedClipboardPositive=','if($false){$isolation.HostedClipboardPositive=')
    HostedParentReader=@('$parentAfter=[HiddenWin]::GetClipboardSequenceNumber()','$parentAfter=$parentBefore')
    HostedVerdictCall=@('Assert-HostedClipboardControl $fact $parentBefore $parentAfter','Assert-HostedClipboardControl $fact $parentBefore $parentBefore')
}
$inert=[ordered]@{}
$legacy=@($source -split "`r?`n" | Where-Object {$_ -match "^if \(\[version\].*Historical portable identity"})
$shell=@($source -split "`r?`n" | Where-Object {$_ -match '--window-save-state=never.*--command=direct:'})
$desktop=@($source -split "`r?`n" | Where-Object {$_ -match "CurrentDesktopName\(\).*Driver is not on its private desktop"})
$load=@($source -split "`r?`n" | Where-Object {$_ -match '^function Get-StubLoadError'})
if($legacy.Count -ne 1 -or $shell.Count -ne 1 -or $desktop.Count -ne 1 -or $load.Count -ne 1){throw 'Inert-copy anchors are not unique'}
foreach($entry in ([ordered]@{Legacy=($legacy -join '');Shell=($shell -join '');DriverDesktop=($desktop -join '');StubLoadApi=($load -join '')}).GetEnumerator()){
    $anchor=[string]$entry.Value
    $replacement="`$unused = @'`n"+$anchor+"`n'@"
    if($entry.Key -ceq 'Shell'){$replacement+="`n"+$anchor.Replace('--command=direct:{3} /D','--command=cmd.exe').Replace('--clipboard-write=deny --clipboard-read=deny','')}
    if($entry.Key -ceq 'StubLoadApi'){$replacement+="`nfunction Get-StubLoadError([string] `$Path) { return 1114 }"}
    $inert[$entry.Key]=@($anchor,$replacement)
}
$inert.LegacyExpandable=@([string]$legacy[0],("`$unused = @`"`n"+[string]$legacy[0]+"`n`"@"))
foreach($control in $sites.GetEnumerator()){
    if(([regex]::Matches($source,[regex]::Escape($control.Value[0]))).Count -ne 1){throw "Call-site anchor is not unique: $($control.Key)"}
    $issues=@(Get-DirectUpdateProblems ($source.Replace($control.Value[0],$control.Value[1])))
    if($issues -cnotcontains $control.Key){throw "Call-site mutant escaped: $($control.Key)"}
}
foreach($control in $inert.GetEnumerator()){
    $expected=if($control.Key -ceq 'LegacyExpandable'){'Legacy'}else{$control.Key}
    $issues=@(Get-DirectUpdateProblems ($source.Replace($control.Value[0],$control.Value[1])))
    if($issues -cnotcontains $expected){throw "Inert-copy mutant escaped: $($control.Key)"}
}

# Ordinary strings and disabled executable guards must fail, too.
$shapeControls=[ordered]@{}
$ephemeralLine=@($source -split "`r?`n" | Where-Object {$_ -like '$ephemeral=*'})
$shapeControls.EphemeralReassignment=@($ephemeralLine[0],($ephemeralLine[0]+"`n`$ephemeral=`$true"),'EphemeralDefinition')
foreach($item in @(@('Legacy','LegacyStatement'),@('Mesa','MesaStatement'),@('Desktop','DriverDesktopStatement'))){
    $needle=switch($item[0]){Legacy{'Historical portable identity requires'} Mesa{'Mesa fixture requires hosted'} Desktop{'Driver is not on its private desktop'}}
    $anchor=@($source -split "`r?`n" | Where-Object {$_.Contains($needle)})[0]
    $shapeControls[($item[0]+'Disabled')]=@($anchor,('if($false){'+$anchor+'}'),$item[1])
    $shapeControls[($item[0]+'Quoted')]=@($anchor,('$unused="'+$anchor.Replace('`','``').Replace('$','`$').Replace('"','`"')+'"'),$item[1])
}
$legacyLine=@($source -split "`r?`n" | Where-Object {$_.Contains('Historical portable identity requires')})[0]
$shapeControls.LegacyFalseClause=@($legacyLine,$legacyLine.Replace('-and -not $ephemeral)','-and -not $ephemeral -and $false)'),'LegacyStatement')
$nativeLine=@($source -split "`r?`n" | Where-Object {$_.Contains('Native OS and process architecture must match')})[0]
$shapeControls.NativeQuoted=@($nativeLine,('$unused='''+$nativeLine.Replace("'","''")+''''+"`n"+$nativeLine.Replace('$native -cne $Architecture -or $processArchitecture -cne $Architecture','$false')),'NativeStatement')
foreach($control in $shapeControls.GetEnumerator()){
    if([regex]::Matches($source,[regex]::Escape($control.Value[0])).Count -ne 1){throw "Shape anchor not unique: $($control.Key)"}
    if(@(Get-DirectUpdateProblems ($source.Replace($control.Value[0],$control.Value[1]))) -cnotcontains $control.Value[2]){throw "Shape mutant escaped: $($control.Key)"}
}

$fixtures=Join-Path ([IO.Path]::GetTempPath()) ('direct-update-contract-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixtures
try {
$baseline=Join-Path $fixtures 'baseline'; $null=New-Item -ItemType Directory -Path $baseline
$issues=@(Invoke-DirectUpdateVerdicts $source $baseline)
if($issues.Count){throw "Behavioural baseline failed: $($issues -join ', ')"}
$mutants=[ordered]@{
    HiddenInventory=@('-File -Recurse -Force','-File -Recurse')
    MinimalEnvironment=@("'PATH','PATHEXT'","'PATH','GH_TOKEN','PATHEXT'")
    StubAlias=@('$result.FinalStub=Get-Stub $Path','$result.FinalStub=$result.TargetStub')
    StubConsequence=@("{throw 'Final stub differs from the verified candidate ZIP'}",'{}')
    Hardcoded1114=@('$errorCode=Get-StubLoadError $Path','$errorCode=1114')
    DeadRollback=@("`$state -and `$state.Phase -ceq 'rollback'","`$false -and `$state.Phase -ceq 'rollback'")
    NativeConsequence=@("{ throw 'Native OS and process architecture must match the requested test; emulation is not evidence' }",'{}')
    EmptyDefault=@('$escaped=@(Get-DefaultWindowRows $Job)','$escaped=@()')
    ClipboardConsequence=@("{throw 'Clipboard sequence changed during run; stop launches'}",'{}')
    MissingExeClause=@(' -and (Get-Sha $exe) -ceq (Get-Sha $targetExe)','')
    ProfileTrue=@("`$isolated=`$ActualLocal -ceq (Join-Path `$Run 'localappdata') -and `$ActualRoaming -ceq (Join-Path `$Run 'appdata')",'$isolated=$true')
    Abandoned=@('$s -and $confirmed -and','$s -and')
    HistorySave=@("    Save-Receipt 'isolation.json' `$isolation",'')
    RuntimeFilter=@('if($null -ne $OriginalNames -and','if($false -and $null -ne $OriginalNames -and')
    BroadJumpList=@("[string]::Equals([IO.Path]::GetFileName(`$_.Path),'c2214d6ebc43ff3f.customDestinations-ms',[StringComparison]::OrdinalIgnoreCase)",'$true')
}
foreach($guard in @(
    @('NativeHereString',"if (`$native -cne `$Architecture -or `$processArchitecture -cne `$Architecture) { throw 'Native OS and process architecture must match the requested test; emulation is not evidence' }"),
    @('ProfileHereString',"if(-not `$isolated){throw 'Driver profile isolation failed'}"),
    @('NewRunHereString',"if (Test-Path -LiteralPath `$Run) { throw 'Run directory must be new' }"),
    @('StubHereString',"if(`$result.FinalStub.Sha256 -cne `$result.TargetStub.Sha256){throw 'Final stub differs from the verified candidate ZIP'}")
)){$mutants[$guard[0]]=@($guard[1],("`$unused = @'`n"+$guard[1]+"`n'@"))}
foreach($mutant in $mutants.GetEnumerator()){
    if(([regex]::Matches($source,[regex]::Escape($mutant.Value[0]))).Count -ne 1){throw "Behavioural mutant anchor is not unique: $($mutant.Key)"}
    $text=$source.Replace($mutant.Value[0],$mutant.Value[1])
    $root=Join-Path $fixtures $mutant.Key; $null=New-Item -ItemType Directory -Path $root
    $issues=@(Invoke-DirectUpdateVerdicts $text $root)
    if($issues.Count -eq 0){throw "Behavioural mutant escaped: $($mutant.Key)"}
}
$forms=$source+"`n[System.Windows.Forms.Clipboard]::SetText('fixture')"
if(@(Get-DirectUpdateProblems $forms) -cnotcontains 'ForbiddenOperation'){throw 'Forms clipboard mutant escaped'}
$profileBypass=$source.Replace('$isolated=Assert-DriverProfile $env:LOCALAPPDATA $env:APPDATA $Run','$isolated=$true')
if(@(Get-DirectUpdateProblems $profileBypass) -cnotcontains 'MissingCall:Assert-DriverProfile'){throw 'Driver profile bypass escaped'}
foreach($control in $controls.GetEnumerator()){
    $anchor=$control.Value[0]
    if(([regex]::Matches($source,[regex]::Escape($anchor))).Count -ne 1){throw "Control anchor is not unique: $($control.Key)"}
    $mutant=$source.Replace($anchor,$control.Value[1])
    $failures=@(Get-DirectUpdateProblems $mutant)
    if($failures -cnotcontains $control.Key){throw "Control did not fail its own admission check: $($control.Key)"}
}
$fixtureWriter=$source+"`n`$writer = @'`nSet-Clipboard fixture`n'@"
if(@(Get-DirectUpdateProblems $fixtureWriter) -cnotcontains 'ForbiddenOperation'){throw 'Here-string writer escaped full-text scan'}
$privateSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'direct-update-clipboard-control.cs') -Raw
$hostedSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'direct-update-hosted-clipboard-control.cs') -Raw
$privateIssues=@(Get-ClipboardHelperProblems $privateSource)
$hostedIssues=@(Get-ClipboardHelperProblems $hostedSource -Hosted)
if($privateIssues.Count -or $hostedIssues.Count){throw "Clipboard helper baseline admission failed: private=$($privateIssues -join ','); hosted=$($hostedIssues -join ',')"}
$privateControls=[ordered]@{
    FreshStation=@('station=CreateWindowStationW(null,0,0x000F037F,IntPtr.Zero);','station=GetProcessWindowStation();')
    StationIdentity=@('GetProcessWindowStation() != station','false')
    NotWinSta0=@('String.Equals(name.ToString(), "WinSta0", StringComparison.OrdinalIgnoreCase)','false')
    NonemptyStation=@('name.Length == 0','false')
    StationSwitch=@('if(!SetProcessWindowStation(station)) throw','if(false) throw')
    ThreadSwitch=@('if(!SetThreadDesktop(desktop)) throw','if(false) throw')
    PrivateOpen=@('RequirePrivate(station); if(!OpenClipboard(window))','if(!OpenClipboard(window))')
    PrivateEmpty=@('RequirePrivate(station); if(!EmptyClipboard())','if(!EmptyClipboard())')
    PrivateSet=@('RequirePrivate(station); if(SetClipboardData(13,memory)==IntPtr.Zero)','if(SetClipboardData(13,memory)==IntPtr.Zero)')
    PrivateClose=@('memory=IntPtr.Zero; RequirePrivate(station); CloseClipboard();','memory=IntPtr.Zero; CloseClipboard();')
    PrivateFinallyClose=@('if(opened) { RequirePrivate(station); CloseClipboard(); }','if(opened) { CloseClipboard(); }')
    PrivateBefore=@('RequirePrivate(station); fact.Before=GetClipboardSequenceNumber();','fact.Before=GetClipboardSequenceNumber();')
    PrivateAfter=@('RequirePrivate(station); fact.After=GetClipboardSequenceNumber();','fact.After=GetClipboardSequenceNumber();')
    CompleteStationGate=@('station == IntPtr.Zero ||','false && station == IntPtr.Zero ||')
}
$hostedControls=[ordered]@{
    HostedEnvironment=@('if(!String.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"),"true",StringComparison.Ordinal) ||','if(false ||')
    HostedStation=@('!String.Equals(ObjectName(GetProcessWindowStation()),"WinSta0",StringComparison.OrdinalIgnoreCase)','false')
    HostedDesktop=@('!desktop.StartsWith("noctty-hw-",StringComparison.Ordinal)','false')
    HostedOpen=@('RequireHostedWinSta0(); if(!OpenClipboard(window))','if(!OpenClipboard(window))')
    HostedEmpty=@('RequireHostedWinSta0(); if(!EmptyClipboard())','if(!EmptyClipboard())')
    HostedSet=@('RequireHostedWinSta0(); if(SetClipboardData(13,memory)==IntPtr.Zero)','if(SetClipboardData(13,memory)==IntPtr.Zero)')
    HostedClose=@('memory=IntPtr.Zero; RequireHostedWinSta0(); CloseClipboard();','memory=IntPtr.Zero; CloseClipboard();')
    HostedFinallyClose=@('if(opened){RequireHostedWinSta0();CloseClipboard();}','if(opened){CloseClipboard();}')
    HostedBefore=@('RequireHostedWinSta0(); fact.Before=GetClipboardSequenceNumber();','fact.Before=GetClipboardSequenceNumber();')
    HostedAfter=@('RequireHostedWinSta0(); fact.After=GetClipboardSequenceNumber();','fact.After=GetClipboardSequenceNumber();')
}
foreach($kind in @('private','hosted')){
    $text=if($kind -ceq 'private'){$privateSource}else{$hostedSource}
    $cases=if($kind -ceq 'private'){$privateControls}else{$hostedControls}

    $gate=if($kind -ceq 'private'){'RequirePrivate(station);'}else{'RequireHostedWinSta0();'}
    $anchor=$gate+' if(!OpenClipboard(window))'
    $unguarded='if(!OpenClipboard(window))'
    $extra=$text.Replace('public static Fact Run() {', 'public static Fact Run() { OpenClipboard(IntPtr.Zero); EmptyClipboard(); CloseClipboard();')
    $disabled=$text.Replace($anchor,("`n#if NEVER`n"+$anchor+"`n#endif`n"+$unguarded))
    $literal=$text.Replace($anchor,('string inert="'+$anchor+'"; '+$unguarded))
    foreach($case in @(@('ExtraCalls',$extra,'ClipboardCallCount'),@('DeadPreprocessor',$disabled,'Preprocessor'),@('StringCopy',$literal,$(if($kind -ceq 'private'){'PrivateOpen'}else{'HostedOpen'})))){
        if(@(Get-ClipboardHelperProblems $case[1] -Hosted:($kind -ceq 'hosted')) -cnotcontains $case[2]){throw "Native inert/extra control escaped: $kind/$($case[0])"}
    }

    foreach($control in $cases.GetEnumerator()){
        if(([regex]::Matches($text,[regex]::Escape($control.Value[0]))).Count -ne 1){throw "Native clipboard control anchor is not unique: $($control.Key)"}
        $issues=@(Get-ClipboardHelperProblems ($text.Replace($control.Value[0],$control.Value[1])) -Hosted:($kind -ceq 'hosted'))
        if($issues -cnotcontains $control.Key){throw "Native clipboard control escaped: $($control.Key)"}
    }
}
$native=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'direct-update-ui.cs') -Raw
if($native -match '\b(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|OpenClipboard|GetClipboardData|SetClipboardData)\s*\('){throw 'UI seam contains a forbidden real-input or clipboard operation'}
if($native -cnotmatch 'ClassName\(host\) != "noctty.win32.host"' -or $native -cnotmatch 'ClassName\(pane\) != "noctty.win32"' -or $native -cnotmatch 'PostMessageW\(host, 0x0201' -or $native -cnotmatch 'PostMessageW\(host, 0x0202' -or $native -cmatch 'PostMessageW\(pane, 0x020[12]'){throw 'Legacy Install must post only to its owned host'}
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $owned=[IO.Path]::GetFullPath($fixtures)
    if(-not $owned.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($owned) -cnotmatch '^direct-update-contract-[a-f0-9]{32}$'){throw 'Refusing fixture cleanup outside the owned temp root'}
    [IO.Directory]::Delete($owned,$true)
    if(Test-Path -LiteralPath $owned){throw 'Contract fixture cleanup failed'}
}
Write-Host "direct-update admission contracts: PASS (1 static + 1 behavioural baseline, $($controls.Count) static, $($sites.Count) call-site, $($inert.Count) inert-copy, $($shapeControls.Count) syntax-shape, $($mutants.Count) behavioural, $($privateControls.Count+$hostedControls.Count+6) native clipboard controls, forbidden-operation negatives, native API boundary; fixtures removed)"
$global:LASTEXITCODE=0
