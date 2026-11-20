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
    if($Text -match '(?i)\b(?:Start-Process|Invoke-Item|Invoke-Expression|iex|Set-Clipboard|Get-Clipboard|Import-Certificate|Set-AuthenticodeSignature)\b|--clobber|gh\s+release\s+(?:create|edit|upload)|Remove-Item|\[System\.Windows\.Forms\.Clipboard\]'){ $problems.Add('ForbiddenOperation') }
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
    $functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    Need FunctionDefinitions (@($functions | Where-Object {-not [object]::ReferenceEquals($_.Parent,$ast.EndBlock)}).Count -eq 0 -and @($functions | Group-Object { $_.Name -replace '^(?i:global|script|local|private):','' } | Where-Object Count -GT 1).Count -eq 0)
    $traps=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.TrapStatementAst]},$true))
    Need TrapExit ($traps.Count -eq 1 -and [object]::ReferenceEquals($traps[0].Parent,$ast.EndBlock) -and (Same $traps[0].Body.Statements[-1] 'break') -and @($traps[0].FindAll({param($n) $n -is [Management.Automation.Language.ContinueStatementAst] -or $n -is [Management.Automation.Language.ReturnStatementAst] -or $n -is [Management.Automation.Language.ExitStatementAst]},$true)).Count -eq 0)
    Need RejectedJournal (Direct (Function-Statements 'Assert-RejectedCopy') '$State=Get-UpdateState $Root -RequireReadable')
    $clipboardTry=@((Function-Statements 'Invoke-ClipboardPositive') | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    Need ClipboardSupported (Direct $clipboardTry.Body.Statements "if(-not `$fact.Supported -or -not `$fact.IsolatedStation -or -not `$fact.SequenceAdvanced){throw 'Clipboard positive control failed'}")
    $node=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'New-DriverEnvironment'})
    Need MinimalEnvironmentPolicy ($node.Count -eq 1 -and (Same $node[0].Body '{ $minimal=@{} foreach($name in @(''SystemRoot'',''WINDIR'',''COMSPEC'',''PATH'',''PATHEXT'',''OS'',''SystemDrive'',''ProgramData'',''ProgramFiles'',''ProgramFiles(x86)'',''ProgramW6432'',''CommonProgramFiles'',''CommonProgramFiles(x86)'',''CommonProgramW6432'',''PROCESSOR_ARCHITECTURE'',''PROCESSOR_ARCHITEW6432'',''PROCESSOR_IDENTIFIER'',''PROCESSOR_LEVEL'',''PROCESSOR_REVISION'',''NUMBER_OF_PROCESSORS'',''COMPUTERNAME'',''USERNAME'',''USERDOMAIN'',''USERDNSDOMAIN'',''SESSIONNAME'',''USERPROFILE'',''HOMEDRIVE'',''HOMEPATH'',''HOME'',''GITHUB_ACTIONS'',''RUNNER_ENVIRONMENT'')){ foreach($key in $Parent.Keys){ if([string]::Equals([string]$key,$name,[StringComparison]::OrdinalIgnoreCase)){$minimal[$name]=[string]$Parent[$key];break} } } $minimal.LOCALAPPDATA=Join-Path $Root ''localappdata''; $minimal.APPDATA=Join-Path $Root ''appdata'' $minimal.TEMP=Join-Path $Root ''temp''; $minimal.TMP=$minimal.TEMP return $minimal }'))
    $node=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Invoke-MinimalDriverEnvironment'})
    Need MinimalEnvironmentScope ($node.Count -eq 1 -and (Same $node[0].Body '{ # CreateProcess inherits this explicit whitelist; restore only this controller. # Never log the saved environment or its values. $parent=[Environment]::GetEnvironmentVariables(''Process'') $minimal=New-DriverEnvironment $parent $Run try{ foreach($name in @($parent.Keys)){[Environment]::SetEnvironmentVariable($name,$null,''Process'')} foreach($name in $minimal.Keys){[Environment]::SetEnvironmentVariable($name,$minimal[$name],''Process'')} & $Start }finally{ foreach($name in @([Environment]::GetEnvironmentVariables(''Process'').Keys)){[Environment]::SetEnvironmentVariable($name,$null,''Process'')} foreach($name in $parent.Keys){[Environment]::SetEnvironmentVariable($name,[string]$parent[$name],''Process'')} } }'))
    Need PublisherVerification (Direct (Function-Statements 'Get-ReleaseCopy') '$publishers=@(foreach($name in @(''noctty.exe'',''noctty.com'')){ $binary=Join-Path $executables[0].DirectoryName $name $signature=Assert-ReleaseSignature -Path $binary -Label ''Published portable executable'' -AllowedPins @(Get-StubPublisherPins) -TrustSelfSigned $true @{File=$name;Sha256=Get-Sha $binary;SignerSpkiSha256=$signature.SpkiSha256;CryptographicallyVerified=$true} })')
    $releaseStatements=@(Function-Statements 'Get-ReleaseCopy')
    $returns=@($releaseStatements | Where-Object {$_ -is [Management.Automation.Language.ReturnStatementAst]})
    $publisher=@($releaseStatements | Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$publishers'})
    $published=@($releaseStatements | Where-Object {Same $_ 'Save-Receipt "$Version-publisher.json" $publishers'})
    Need PublisherOrder ($returns.Count -eq 1 -and $publisher.Count -eq 1 -and $published.Count -eq 1 -and (Same $releaseStatements[-1] 'return $executables[0].DirectoryName') -and $publisher[0].Extent.EndOffset -lt $published[0].Extent.StartOffset -and $published[0].Extent.EndOffset -lt $returns[0].Extent.StartOffset)
    Need MesaPins (Direct (Function-Statements 'Add-HostedMesa') '$pins=@{ x64=''11dc079e356f33ce2ff84aa399c975da1a7bdd4c470f6eef4cf359ad8b9ca80f'' arm64=''067f3aca687fbf5afc8a1f41487bd051487d964d6c1686757a4d8ee6a2d3b901'' }')
    $mesaParameter=@($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -ieq 'HostedMesa'})
    Need MesaOptIn ($mesaParameter.Count -eq 1 -and $null -eq $mesaParameter[0].DefaultValue -and @($mesaParameter[0].Attributes | Where-Object {$_.TypeName.FullName -ieq 'switch'}).Count -eq 1)
    $definitions=@($ast.FindAll({param($n)
        ($n -is [Management.Automation.Language.AssignmentStatementAst] -and @($n.Left.FindAll({param($v) $v -is [Management.Automation.Language.VariableExpressionAst] -and $v.VariablePath.UserPath -imatch '(^|:)ephemeral$'},$true)).Count -gt 0) -or
        ($n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -imatch '(^|:)ephemeral$') -or
        ($n -is [Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -imatch '(^|:)ephemeral$') -or
        ($n -is [Management.Automation.Language.UnaryExpressionAst] -and $n.TokenKind -in @('PostfixPlusPlus','PostfixMinusMinus','PlusPlus','MinusMinus') -and $n.Child.Extent.Text -imatch 'ephemeral')
    },$true))
    Need EphemeralDefinition ($definitions.Count -eq 1 -and [object]::ReferenceEquals($definitions[0].Parent,$ast.EndBlock) -and (Same $definitions[0] "`$ephemeral=`$env:GITHUB_ACTIONS -ceq 'true' -and `$env:RUNNER_ENVIRONMENT -ceq 'github-hosted'"))
    # The harness has no variable-mutator cmdlets/provider or PSVariable/ref use.
    # Refuse these indirect write mechanisms rather than guessing their arguments.
    $references=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.ConvertExpressionAst] -and $n.Type.TypeName.FullName -ieq 'ref' -and @($n.Child.FindAll({param($v) $v -is [Management.Automation.Language.VariableExpressionAst] -and $v.VariablePath.UserPath -imatch '(^|:)ephemeral$'},$true)).Count -gt 0},$true))
    Need EphemeralWrites ($references.Count -eq 0 -and $code -inotmatch '\b(?:Get|Set|New|Clear|Remove)-Variable\b|\b(?:gv|sv|set|nv|clv|rv)\s+|\bPSVariable\b|variable:' -and @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -imatch '^(?:OutVariable|PipelineVariable|ErrorVariable|WarningVariable|InformationVariable|ov|pv|ev|wv|iv)$'},$true)).Count -eq 0)
    function OutputBindingName([string] $Name){ -not [string]::IsNullOrEmpty($Name) -and ('OutVariable'.StartsWith($Name,[StringComparison]::OrdinalIgnoreCase) -or $Name -ieq 'ov') }
    $bindings=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandParameterAst] -and (OutputBindingName $n.ParameterName)},$true))
    $splatBindings=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst] -and @($n.KeyValuePairs | Where-Object {$_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and (OutputBindingName $_.Item1.Value)}).Count -gt 0},$true))
    Need OutputVariableBinding ($bindings.Count -eq 0 -and $splatBindings.Count -eq 0)
    Need LegacyStatement (Direct $ast.EndBlock.Statements "if ([version]`$FromVersion -lt [version]'1.3.136' -and -not `$ephemeral) { throw 'Historical portable identity requires an ephemeral hosted runner' }")
    Need MesaStatement (Direct $ast.EndBlock.Statements "if(`$HostedMesa -and (-not `$ephemeral -or `$FromVersion -cne '1.3.125' -or `$TargetVersion -cne '1.3.137' -or `$Expected -cne 'Stub')){throw 'Mesa fixture requires hosted 1.3.125 to 1.3.137 stub acceptance'}")
    Need NativeStatement (Direct (Function-Statements 'Assert-NativeArchitecture') "if (`$native -cne `$Architecture -or `$processArchitecture -cne `$Architecture) { throw 'Native OS and process architecture must match the requested test; emulation is not evidence' }")
    $controller=Find-If $ast.EndBlock.Statements '-not $Driver'
    Need ControllerExit (Same $controller.Clauses[0].Item2.Statements[-1] 'exit 0')
    $failure=@($controller.Clauses[0].Item2.Statements | Where-Object {Same $_ 'if($exitCode -ne 0){throw ''Acceptance driver failed; read sanitized result.json''}'})
    $success=@($controller.Clauses[0].Item2.Statements | Where-Object {Same $_ 'Write-Host "direct-update acceptance: PASS ($FromVersion -> $TargetVersion, $Architecture, $Expected); evidence=$Run"'})
    Need ControllerFailure ($failure.Count -eq 1 -and $success.Count -eq 1 -and $failure[0].Extent.EndOffset -lt $success[0].Extent.StartOffset -and $success[0].Extent.EndOffset -lt $controller.Clauses[0].Item2.Statements[-1].Extent.StartOffset)
    Need DriverExit ((Same $ast.EndBlock.Statements[-2] 'if(-not $result.Passed){exit 1}') -and (Same $ast.EndBlock.Statements[-1] 'exit 0'))
    Need RunPathCall (Direct $controller.Clauses[0].Item2.Statements '$Run=Get-RunPath $Run')
    Need ParentDesktop (Direct $controller.Clauses[0].Item2.Statements "if([HiddenWin]::CurrentDesktopName() -cne 'Default'){throw 'Controller must observe the Default desktop'}")
    Need RunVolume (Direct $controller.Clauses[0].Item2.Statements "if(`$runFree -le 20GB){throw 'Run volume has 20 GB or less free'}")
    Need ResolvedRunVolume (Direct $controller.Clauses[0].Item2.Statements '$runFree=[DirectUpdateUi]::AvailableRunSpace($Run)')
    Need HistoryStart (Direct $controller.Clauses[0].Item2.Statements "`$historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'direct-update-acceptance'")
    $controllerTry=@($controller.Clauses[0].Item2.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    # Bind the tested status to the driver's process handle and its out parameter.
    $controllerTryStatements=@($controllerTry.Body.Statements)
    $exitRead=@($controllerTryStatements | Where-Object {Same $_ 'if(-not [HiddenWin]::GetExitCodeProcess($launch.process,[ref]$code)){throw ''Driver exit read failed''}'})
    $exitReadIndex=-1
    if($exitRead.Count -eq 1){$exitReadIndex=[Array]::IndexOf($controllerTryStatements,$exitRead[0])}
    $controllerWait=if($exitReadIndex -ge 2){$controllerTryStatements[$exitReadIndex-2]}
    # The controller must read the signaled driver's status or fail at the deadline.
    Need ControllerWaitBreak ($controllerWait -is [Management.Automation.Language.DoWhileStatementAst] -and
        (Same $controllerWait.Condition '$true') -and
        (Direct $controllerWait.Body.Statements 'if([HiddenWin]::WaitForSingleObject($launch.process,250) -eq 0) { break }') -and
        (Direct $controllerWait.Body.Statements 'if([datetime]::UtcNow -ge $deadline) { throw ''Private driver timed out'' }') -and
        @($controllerWait.Body.FindAll({param($n) $n -is [Management.Automation.Language.ReturnStatementAst] -or $n -is [Management.Automation.Language.ExitStatementAst]},$true)).Count -eq 0)
    $exitWrites=@($controller.FindAll({param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        @($node.Left.FindAll({param($target) $target -is [Management.Automation.Language.VariableExpressionAst] -and $target.VariablePath.UserPath -imatch '(^|:)exitCode$'},$true)).Count -gt 0
    },$true))
    Need ControllerExitSource ($exitReadIndex -ge 2 -and $exitReadIndex+1 -lt $controllerTryStatements.Count -and
        $controllerWait -is [Management.Automation.Language.DoWhileStatementAst] -and
        (Same $controllerTryStatements[$exitReadIndex-1] '[uint32]$code=1') -and
        $exitWrites.Count -eq 2 -and (Same $exitWrites[0] '$exitCode=1') -and (Same $exitWrites[1] '$exitCode=$code') -and
        [object]::ReferenceEquals($exitWrites[1],$controllerTryStatements[$exitReadIndex+1]))
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
    Need MesaCancellation (Direct (Function-Statements 'Add-HostedMesa') '$cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))')
    $mesaTry=@((Function-Statements 'Add-HostedMesa') | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}) | Select-Object -First 1
    Need MesaTimeout ((Direct $mesaTry.Body.Statements '$client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)') -and (Direct $mesaTry.Body.Statements '$bytes=$client.GetByteArrayAsync([Uri]$url,$cancel.Token).GetAwaiter().GetResult()'))
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
    Need CredentialPredicate (Direct $driver.Body.Statements '$credentialsAbsent=Test-WorkflowCredentialsAbsent ([Environment]::GetEnvironmentVariables(''Process''))')
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
    if($structure -match '\bEntryPoint\s*='){$problems.Add('NativeAlias')}
    return @($problems.ToArray())
}
function Invoke-DirectUpdateVerdicts([string] $Text,[string] $Root) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Behavioural fixture must parse'}
    $names=@('Get-RunPath','New-DriverEnvironment','Test-WorkflowCredentialsAbsent','Get-UpdaterLogFact','Save-Receipt','Get-Sha','Get-Listing','Get-Stub','Assert-NativeArchitecture','Assert-NewRun','Assert-DriverProfile','Assert-NoDefaultWindows','Assert-ClipboardSequence','Add-UpdateSample','Test-FinalizedUpdate','Assert-InstalledStub','Get-SourceSnapshot','Assert-JournalKeys','Assert-JournalSchema','Get-JournalField','Get-UpdateState','Assert-RejectedCopy','Assert-SourceStub','Get-NocttyJumpList','Assert-LocalState','Write-IsolationReceipt','Assert-HostedClipboardControl')
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

        $caseSensitive=[Collections.Hashtable]::new([StringComparer]::Ordinal)
        $caseSensitive.Add('Path','fixture-path'); $caseSensitive.Add('windir','fixture-windir'); $caseSensitive.Add('ComSpec','fixture-comspec')
        $caseSensitive.Add('gh_token','fixture-secret')
        $windowsNames=New-DriverEnvironment $caseSensitive $Root
        if($windowsNames.PATH -cne 'fixture-path' -or $windowsNames.WINDIR -cne 'fixture-windir' -or $windowsNames.COMSPEC -cne 'fixture-comspec' -or $windowsNames.Contains('GH_TOKEN')){$failures.Add('WindowsEnvironmentNames')}
        if(-not (Test-WorkflowCredentialsAbsent @{}) -or -not (Test-WorkflowCredentialsAbsent @{GH_TOKEN=''})){$failures.Add('CredentialsEmpty')}
        foreach($name in @('GH_TOKEN','GITHUB_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN','gh_token')){
            if(Test-WorkflowCredentialsAbsent @{$name='fixture-token'}){$failures.Add('CredentialsPresent')}
        }
        foreach($scope in @('update_github_releases','update_portable_apply')){
            $fact=Get-UpdaterLogFact ('info('+ $scope +'): fixture path C:\private token=fixture')
            if(-not [string]::Equals($fact,('info('+ $scope +'): [message omitted]'),[StringComparison]::Ordinal)){$failures.Add('UpdaterLogScope')}
        }
        if($null -ne (Get-UpdaterLogFact 'info(win32): unrelated')){$failures.Add('UpdaterLogOther')}
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
        Assert-RejectedCopy $before $good
        $runtime=[IO.File]::Open((Join-Path $good 'update-state.json.lock'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{try{Assert-RejectedCopy $before $good}catch{$failures.Add('RuntimeHashRead')}}finally{$runtime.Dispose()}
        Refuses MissingSidecar {Assert-RejectedCopy $before $missing}
        Refuses ChangedSidecar {Assert-RejectedCopy $before $changed}
        $journal=Join-Path $good 'update-state.json'
        $clearJournal=[ordered]@{
            last_checked_at=0; last_seen_version=$null; release_feed_url=$null; release_url=$null; dismissed_version=$null
            staged_version=$null; staged_kind=$null; staged_installer_path=$null; staged_portable_path=$null; staged_payload_path=$null; staged_sha256=$null; staged_feed_url=$null
            staged_at=0; apply_requested_at=0; portable_apply_phase=$null; portable_backup_path=$null; portable_confirmation_token=$null
        }
        $clearJson=ConvertTo-Json -InputObject $clearJournal -Compress
        $pendingJson=$clearJson.Replace('"portable_apply_phase":null','"portable_apply_phase":"pending"').Replace('"staged_version":null','"staged_version":"1.4.100"')
        [IO.File]::WriteAllText($journal,$pendingJson)
        Refuses RejectedStage {Assert-RejectedCopy $before $good}
        $locked=[IO.File]::Open($journal,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{Refuses RejectedLocked {Assert-RejectedCopy $before $good}}finally{$locked.Dispose()}
        $writer=[IO.File]::Open($journal,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
        try{Refuses RejectedWriterOpen {Assert-RejectedCopy $before $good}}finally{$writer.Dispose()}
        $originalAcl=Get-Acl -LiteralPath $journal
        $deniedAcl=Get-Acl -LiteralPath $journal
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $deniedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::ReadData,[Security.AccessControl.AccessControlType]::Deny))
        try{
            Set-Acl -LiteralPath $journal -AclObject $deniedAcl
            Refuses DeniedReadPositive {[IO.File]::ReadAllText($journal) | Out-Null}
            Refuses RejectedDeniedRead {Assert-RejectedCopy $before $good}
        }finally{Set-Acl -LiteralPath $journal -AclObject $originalAcl}
        $badJournals=[ordered]@{
            Malformed='{ malformed'; Truncated='{"portable_apply_phase":"pending"'; TrailingGarbage=($pendingJson+'garbage'); Empty=''; Whitespace=" `t`n"
            Null='null'; EmptyArray='[]'; ObjectArray='[{}]'; Scalar='"scalar"'; Number='42'; Boolean='true'; PendingArray=('['+$pendingJson+']')
            CaseDuplicate=($clearJson.TrimEnd('}')+',"Portable_apply_phase":null}')
            TrailingComma=($clearJson.TrimEnd('}')+',}')
            UnquotedKey=$clearJson.Replace('"portable_apply_phase":','portable_apply_phase:')
            Comment=('/* invalid JSON */'+$clearJson)
            DuplicateLaterNull=($pendingJson.TrimEnd('}')+',"portable_apply_phase":null,"staged_version":null}')
            EmptyObject='{}'
            NestedDuplicate=($clearJson.TrimEnd('}')+',"extra":{"same":1,"same":2}}')
            NestedArrayDuplicate=($clearJson.TrimEnd('}')+',"extra":[{"same":1,"same":2}]}')
        }
        foreach($bad in $badJournals.GetEnumerator()){
            [IO.File]::WriteAllText($journal,$bad.Value)
            Refuses ('Rejected'+$bad.Key) {Assert-RejectedCopy $before $good}
        }
        foreach($encoding in @([Text.UTF8Encoding]::new($true),[Text.UnicodeEncoding]::new($false,$true),[Text.UnicodeEncoding]::new($false,$false))){
            [IO.File]::WriteAllText($journal,$pendingJson,$encoding)
            Refuses RejectedEncodedPending {Assert-RejectedCopy $before $good}
        }
        [IO.File]::WriteAllText($journal,$clearJson.Replace('"portable_apply_phase":null','"portable_apply_phase":""'))
        Refuses RejectedEmptyPhase {Assert-RejectedCopy $before $good}
        foreach($missingKey in @($clearJournal.Keys)){
            $partial=[ordered]@{}; foreach($key in $clearJournal.Keys){if($key -cne $missingKey){$partial[$key]=$clearJournal[$key]}}
            [IO.File]::WriteAllText($journal,(ConvertTo-Json -InputObject $partial -Compress))
            Refuses RejectedMissingKey {Assert-RejectedCopy $before $good}
        }
        [IO.File]::Delete($journal); $null=New-Item -ItemType Directory -Path $journal
        try{Refuses RejectedDirectory {Assert-RejectedCopy $before $good}}finally{[IO.Directory]::Delete($journal)}
        [IO.File]::WriteAllText($journal,$clearJson)
        try{Assert-RejectedCopy $before $good}catch{$failures.Add('RejectedClearPositive')}
        # Corruption in an unused field must fail decoding, not become U+FFFD.
        $withUrl=$clearJson.Replace('"release_url":null','"release_url":"fixture"')
        $offset=$withUrl.IndexOf('fixture',[StringComparison]::Ordinal)
        if($offset -lt 0){throw 'Invalid UTF-8 fixture anchor absent'}
        $validUtf8=[Text.Encoding]::UTF8.GetBytes($withUrl)
        [byte[]]$utf8Bom=0xef,0xbb,0xbf
        [IO.File]::WriteAllBytes($journal,[byte[]]($utf8Bom+$validUtf8))
        try{Assert-RejectedCopy $before $good}catch{$failures.Add('RejectedUtf8BomPositive')}
        $invalidUtf8=[byte[]]$validUtf8.Clone(); $invalidUtf8[$offset]=0xff
        [IO.File]::WriteAllBytes($journal,$invalidUtf8)
        Refuses RejectedInvalidUtf8 {Assert-RejectedCopy $before $good}
        [IO.File]::WriteAllBytes($journal,[byte[]]($utf8Bom+$invalidUtf8))
        Refuses RejectedInvalidUtf8Bom {Assert-RejectedCopy $before $good}
        # A clear transaction isolates encoding refusal from pending-state refusal.
        $otherEncodings=[ordered]@{
            RejectedUtf16LE=[Text.UnicodeEncoding]::new($false,$true)
            RejectedUtf16BE=[Text.UnicodeEncoding]::new($true,$true)
            RejectedUtf32LE=[Text.UTF32Encoding]::new($false,$true)
            RejectedUtf32BE=[Text.UTF32Encoding]::new($true,$true)
        }
        foreach($entry in $otherEncodings.GetEnumerator()){
            $encoding=$entry.Value
            [IO.File]::WriteAllBytes($journal,[byte[]]($encoding.GetPreamble()+$encoding.GetBytes($clearJson)))
            Refuses $entry.Key {Assert-RejectedCopy $before $good}
        }
        [IO.File]::WriteAllBytes($journal,[byte[]]($utf8Bom+$utf8Bom+[Text.Encoding]::UTF8.GetBytes($clearJson)))
        Refuses RejectedDoubleUtf8Bom {Assert-RejectedCopy $before $good}
        [IO.File]::WriteAllText($journal,$clearJson)
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
    ControllerWaitBreak=@('if([HiddenWin]::WaitForSingleObject($launch.process,250) -eq 0) { break }','if([HiddenWin]::WaitForSingleObject($launch.process,250) -eq 0) { return }')
    ControllerFailure=@('if($exitCode -ne 0){throw ''Acceptance driver failed; read sanitized result.json''}','')
    ControllerExit=@("    exit 0`n}","}")
    DriverExit=@('if(-not $result.Passed){exit 1}','if(-not $result.Passed){exit 0}')
    TrapExit=@("    break`n}","    continue`n}")
    RejectedJournal=@('$State=Get-UpdateState $Root -RequireReadable','$State=Get-UpdateState $Root')
    ResolvedRunVolume=@('$runFree=[DirectUpdateUi]::AvailableRunSpace($Run)','$runFree=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($Run)).AvailableFreeSpace')
    CredentialPredicate=@('$credentialsAbsent=Test-WorkflowCredentialsAbsent ([Environment]::GetEnvironmentVariables(''Process''))','$credentialsAbsent=$true')
    MesaCancellation=@('$cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))','$cancel=[Threading.CancellationTokenSource]::new()')
    MesaTimeout=@('$client.GetByteArrayAsync([Uri]$url,$cancel.Token)','$client.GetByteArrayAsync([Uri]$url)')
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
$controllerGuard=$sites.ControllerFailure[0]
$controllerPass='Write-Host "direct-update acceptance: PASS ($FromVersion -> $TargetVersion, $Architecture, $Expected); evidence=$Run"'
$shapeControls.ControllerGuardAfterPass=@(($controllerGuard+"`n    "+$controllerPass),($controllerPass+"`n    "+$controllerGuard),'ControllerFailure')
$shapeControls.ControllerGuardDisabled=@($controllerGuard,('if($false){'+$controllerGuard+'}'),'ControllerFailure')
$shapeControls.ControllerGuardCommented=@($controllerGuard,('# '+$controllerGuard),'ControllerFailure')
$shapeControls.ControllerGuardWarning=@($controllerGuard,$controllerGuard.Replace('throw ','Write-Warning '),'ControllerFailure')
$shapeControls.ControllerAmbientExitCode=@('$exitCode=$code','$exitCode=$LASTEXITCODE','ControllerExitSource')
$shapeControls.ControllerConstantExitCode=@('$exitCode=$code','$exitCode = 0','ControllerExitSource')
$shapeControls.ControllerDeadlineReturn=@('throw ''Private driver timed out''','return','ControllerWaitBreak')
$shapeControls.ControllerReceiptReturn=@('throw ''Private driver receipt mismatch''','return','ControllerWaitBreak')
$waitBreak=$sites.ControllerWaitBreak[0]
$shapeControls.ControllerLoopReturn=@($waitBreak,('return'+"`n            "+$waitBreak),'ControllerWaitBreak')
$ephemeralLine=@($source -split "`r?`n" | Where-Object {$_ -like '$ephemeral=*'})
$shapeControls.EphemeralReassignment=@($ephemeralLine[0],($ephemeralLine[0]+"`n`$ephemeral=`$true"),'EphemeralDefinition')
foreach($item in @(
    @('OutVariableAbbreviation','Write-Output $true -OutV ephemeral | Out-Null','OutputVariableBinding'),
    @('OutVariableSplat','$o=@{OutVariable=''ephemeral''}; Write-Output $true @o | Out-Null','OutputVariableBinding'),
    @('GetVariableValue','(Get-Variable ephemeral).Value=$true','EphemeralWrites'),
    @('Reference','$r=[ref]$ephemeral; $r.Value=$true','EphemeralWrites'),
    @('BracedReference','$r=[ref]${ephemeral}; $r.Value=$true','EphemeralWrites'),
    @('InvokeExpression','Invoke-Expression ''$ephemeral=$true''','ForbiddenOperation'),
    @('InvokeExpressionAlias','iex ''Write-Output fixture''','ForbiddenOperation')
)){$shapeControls[$item[0]]=@($ephemeralLine[0],($ephemeralLine[0]+"`n"+$item[1]),$item[2])}
foreach($exit in @('return','exit 0')){
    $shapeControls[('Trap'+$exit.Replace(' ',''))]=@("    break`n}",("    "+$exit+"`n    break`n}"),'TrapExit')
}
foreach($write in ([ordered]@{
    Typed='[bool] $ephemeral=$true'; Multiple='$unused,$ephemeral=0,$true'; Foreach='foreach($ephemeral in @($true)){}'; Increment='$ephemeral++'
    SetVariable='Set-Variable ephemeral $true'; NewVariable='New-Variable ephemeral $true'; ClearVariable='Clear-Variable ephemeral'; RemoveVariable='Remove-Variable ephemeral'
    VariableProvider='Set-Item variable:ephemeral $true'; PSVariable='$ExecutionContext.SessionState.PSVariable.Set(''ephemeral'',$true)'
}).GetEnumerator()){
    $key=if($write.Key -in @('Typed','Multiple','Foreach','Increment')){'EphemeralDefinition'}else{'EphemeralWrites'}
    $shapeControls[('Ephemeral'+$write.Key)]=@($ephemeralLine[0],($ephemeralLine[0]+"`n"+$write.Value),$key)
}
$shapeControls.NestedDefinition=@('function Get-ReleaseCopy([string] $Version) {','function Get-ReleaseCopy([string] $Version) { function Assert-NativeArchitecture {}','FunctionDefinitions')
$shapeControls.DuplicateDefinition=@($ephemeralLine[0],($ephemeralLine[0]+"`nfunction Get-ReleaseCopy {}"),'FunctionDefinitions')
$publisherBlock=[regex]::Match($source,'(?s)    \$publishers=@\(foreach.*?    Save-Receipt "\$Version-publisher.json" \$publishers\r?\n    return \$executables\[0\].DirectoryName').Value
if(-not $publisherBlock){throw 'Publisher order anchor absent'}
$publisherOnly=$publisherBlock.Substring(0,$publisherBlock.LastIndexOf('    return '))
$shapeControls.PublisherAfterReturn=@($publisherBlock,("    return `$executables[0].DirectoryName`n"+$publisherOnly),'PublisherOrder')
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
    JournalUtf8Replacement=@('[Text.UTF8Encoding]::new($false,$true)','[Text.UTF8Encoding]::new($false,$false)')
    JournalUtf8BomFallback=@('[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path))','[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))')
    JournalUtf8PreambleFallback=@('[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path))','[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($true,$true))')
    JournalDuplicateKeys=@('        Assert-JournalKeys $value','')
    JournalSchema=@('if($RequireReadable){Assert-JournalSchema $value}','')
    JournalTrailingComma=@('$options.AllowTrailingCommas=$false','$options.AllowTrailingCommas=$true')
    JournalComments=@('$options.CommentHandling=[Text.Json.JsonCommentHandling]::Disallow','$options.CommentHandling=[Text.Json.JsonCommentHandling]::Skip')
    JournalFailOpen=@("if(`$RequireReadable){throw 'Rejected update journal is unreadable or malformed'}",'')
    JournalNotStrict=@('$State=Get-UpdateState $Root -RequireReadable','$State=Get-UpdateState $Root')
    CredentialAlwaysAbsent=@("if([string]::Equals([string]`$key,`$name,[StringComparison]::OrdinalIgnoreCase) -and -not [string]::IsNullOrEmpty([string]`$Environment[`$key])){return `$false}",'')
    DeadUpdaterLogScopes=@('update_github_releases|update_portable_apply','update|win32')
    WindowsEnvironmentNames=@('OrdinalIgnoreCase)){$minimal[$name]', 'Ordinal)){$minimal[$name]')
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
    if($mutant.Key -ceq 'JournalUtf8PreambleFallback'){
        foreach($reason in @('RejectedUtf16LE','RejectedUtf16BE','RejectedUtf32LE','RejectedUtf32BE','RejectedDoubleUtf8Bom')){
            if($issues -cnotcontains $reason){throw "JournalUtf8PreambleFallback did not exercise $reason"}
        }
    }
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
    $alias=$text.Replace('public static Fact Run() {','[DllImport("user32.dll", EntryPoint="OpenClipboard")] static extern bool Oc(IntPtr h); public static Fact Run() { Oc(IntPtr.Zero);')
    if([string]::Equals($alias,$text,[StringComparison]::Ordinal)){throw 'Native alias anchor absent'}
    if(@(Get-ClipboardHelperProblems $alias -Hosted:($kind -ceq 'hosted')) -cnotcontains 'NativeAlias'){throw 'Native alias escaped'}
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
Add-Type -Path (Join-Path $PSScriptRoot 'direct-update-ui.cs')
$volumeTarget=Join-Path $fixtures 'volume-target'; $null=New-Item -ItemType Directory -Path $volumeTarget
$volumeLink=Join-Path $fixtures 'volume-junction'
$null=New-Item -ItemType Junction -Path $volumeLink -Target $volumeTarget
try{
    $throughLink=[DirectUpdateUi]::ExistingRunDirectory((Join-Path $volumeLink 'new\run'))
    $direct=[DirectUpdateUi]::ExistingRunDirectory($volumeTarget)
    if(-not [string]::Equals($throughLink,$direct,[StringComparison]::OrdinalIgnoreCase)){throw 'Run volume did not resolve its junction ancestor'}
    if([DirectUpdateUi]::AvailableRunSpace((Join-Path $volumeLink 'new\run')) -le 0){throw 'Resolved run volume query failed'}
}finally{[IO.Directory]::Delete($volumeLink)}
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $owned=[IO.Path]::GetFullPath($fixtures)
    if(-not $owned.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($owned) -cnotmatch '^direct-update-contract-[a-f0-9]{32}$'){throw 'Refusing fixture cleanup outside the owned temp root'}
    [IO.Directory]::Delete($owned,$true)
    if(Test-Path -LiteralPath $owned){throw 'Contract fixture cleanup failed'}
}
Write-Host "direct-update admission contracts: PASS (1 static + 1 behavioural baseline, $($controls.Count) static, $($sites.Count) call-site, $($inert.Count) inert-copy, $($shapeControls.Count) syntax-shape, $($mutants.Count) behavioural, $($privateControls.Count+$hostedControls.Count+8) native clipboard controls, forbidden-operation negatives, resolved-volume fixture, native API boundary; fixtures removed)"
$global:LASTEXITCODE=0
