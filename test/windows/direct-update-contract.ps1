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
    foreach($token in @($tokens | Where-Object Kind -EQ 'Comment' | Sort-Object { $_.Extent.StartOffset } -Descending)){
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
    }
    $problems=[Collections.Generic.List[string]]::new()
    foreach($entry in $requirements.GetEnumerator()){if($code -cnotmatch $entry.Value){$problems.Add($entry.Key)}}
    if($code -match '(?i)\b(?:Start-Process|Invoke-Item|Set-Clipboard|Get-Clipboard|Import-Certificate|Set-AuthenticodeSignature)\b|--clobber|gh\s+release\s+(?:create|edit|upload)|Remove-Item|\[System\.Windows\.Forms\.Clipboard\]'){ $problems.Add('ForbiddenOperation') }
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    foreach($name in @('Assert-NativeArchitecture','Assert-NewRun','Assert-DriverProfile','Assert-NoDefaultWindows','Assert-ClipboardSequence','Add-UpdateSample','Test-FinalizedUpdate','Assert-InstalledStub','Assert-RejectedCopy','Assert-SourceStub','Assert-LocalState')){
        if(@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $name},$true)).Count -eq 0){$problems.Add("MissingCall:$name")}
    }
    return @($problems.ToArray())
}
function Invoke-DirectUpdateVerdicts([string] $Text,[string] $Root) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Behavioural fixture must parse'}
    $names=@('Get-Sha','Get-Listing','Get-Stub','Assert-NativeArchitecture','Assert-NewRun','Assert-DriverProfile','Assert-NoDefaultWindows','Assert-ClipboardSequence','Add-UpdateSample','Test-FinalizedUpdate','Assert-InstalledStub','Get-SourceSnapshot','Assert-RejectedCopy','Assert-SourceStub','Assert-LocalState')
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
        function Assert-ReleaseSignature($Path,$Label,$AllowedPins,$TrustSelfSigned){@{Status='fixture';Thumbprint='fixture';SpkiSha256='fixture'}}
        function Get-PeDataDirectories($Path){@(@{Rva=0;Size=0},@{Rva=0;Size=0})}
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
        $good=Join-Path $Root 'good'; $missing=Join-Path $Root 'missing'; $changed=Join-Path $Root 'changed'
        foreach($directory in @($good,$missing,$changed)){
            $null=New-Item -ItemType Directory -Path $directory
            [IO.File]::WriteAllText((Join-Path $directory 'noctty.exe'),'same-exe')
        }
        [IO.File]::WriteAllText((Join-Path $good 'ghostty-vt.dll'),'same-stub')
        [IO.File]::WriteAllText((Join-Path $changed 'ghostty-vt.dll'),'changed-stub')
        $before=@(Get-SourceSnapshot $good)
        Assert-RejectedCopy $before $good $clear
        Refuses MissingSidecar {Assert-RejectedCopy $before $missing $clear}
        Refuses ChangedSidecar {Assert-RejectedCopy $before $changed $clear}
        Refuses RejectedStage {Assert-RejectedCopy $before $good @{Phase='pending';StagedVersion='1.4.100'}}
        $fingerprint=@{Exists=$true;Hash='a';Modified='t'}
        $null=Assert-LocalState $fingerprint $fingerprint @() @()
        Refuses Startup {Assert-LocalState $fingerprint @{Exists=$true;Hash='b';Modified='t'} @() @()}
        Refuses JumpList {Assert-LocalState $fingerprint $fingerprint @(@{Path='fixture';Written='a'}) @(@{Path='fixture';Written='b'})}
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
}
$fixtures=Join-Path ([IO.Path]::GetTempPath()) ('direct-update-contract-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixtures
$baseline=Join-Path $fixtures 'baseline'; $null=New-Item -ItemType Directory -Path $baseline
$issues=@(Invoke-DirectUpdateVerdicts $source $baseline)
if($issues.Count){throw "Behavioural baseline failed: $($issues -join ', ')"}
$mutants=[ordered]@{
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
$native=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'direct-update-ui.cs') -Raw
if($native -match '\b(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|OpenClipboard|GetClipboardData|SetClipboardData)\s*\('){throw 'UI seam contains a forbidden real-input or clipboard operation'}
if($native -cnotmatch 'ClassName\(host\) != "noctty.win32.host"' -or $native -cnotmatch 'ClassName\(pane\) != "noctty.win32"' -or $native -cnotmatch 'PostMessageW\(host, 0x0201' -or $native -cnotmatch 'PostMessageW\(host, 0x0202' -or $native -cmatch 'PostMessageW\(pane, 0x020[12]'){throw 'Legacy Install must post only to its owned host'}
Write-Host "direct-update admission contracts: PASS (1 static + 1 behavioural baseline, $($controls.Count) parse-checked refusal controls, $($mutants.Count) behavioural mutants, Forms clipboard negative, native API boundary)"
$global:LASTEXITCODE=0
