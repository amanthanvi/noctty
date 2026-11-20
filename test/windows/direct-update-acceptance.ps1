#requires -Version 7.3
<#
Runs published portable binaries through their own updater, with a tag API feed.
Every invocation needs a NEW Run directory; downloads have separate empty directories.
Use Expected=Rejected for the old 1.3.136 -> v1.4.100 boundary, or Removed for
the preceding stub-bearing 1.3.x -> v1.4.100 update. Opening the release-page
link itself remains a separate browser check; this harness never opens a browser.

Historical binaries before portable identity isolation (including 1.3.125)
are admitted ONLY on a disposable GitHub-hosted runner. Redirecting profile
directories does not isolate their Shell jump list or AUMID registry writes.
Local guards read the startup-attempts.json hash/mtime, AUMID registration and
history/jump-list metadata; they do not write those files or read clipboard contents.
Raw child logs are local evidence only; upload only the sanitized JSON receipts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Run,
    [ValidatePattern('^1\.[34]\.[0-9]+$')] [string] $FromVersion = '1.3.136',
    [ValidatePattern('^1\.[34]\.[0-9]+$')] [string] $TargetVersion = '1.3.137',
    [ValidateSet('x64','arm64')] [string] $Architecture = 'x64',
    [ValidateSet('Stub','Rejected','Removed')] [string] $Expected = 'Stub',
    [ValidateRange(30,1800)] [int] $TimeoutSeconds = 300,
    [switch] $HostedMesa,
    [switch] $Driver,
    [string] $DesktopName
)
$ErrorActionPreference = 'Stop'
trap {
    if($Driver -and (Test-Path -LiteralPath $Run)){
        try{@{ErrorType=$_.Exception.GetType().Name;Line=$_.InvocationInfo.ScriptLineNumber} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'driver-startup-error.json')}catch{}
    }
    break
}
. (Join-Path $PSScriptRoot 'hidden-win11-lib.ps1')
. (Join-Path $PSScriptRoot '..\..\scripts\ghostty-vt-stub.ps1')
. (Join-Path $PSScriptRoot '..\..\scripts\signing-trust.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'direct-update-ui.cs')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes

function Read-ControlName([IntPtr] $Window,[int] $Id) {
    $control=[DirectUpdateUi]::Child($Window,$Id)
    if($control -eq [IntPtr]::Zero -or -not [HiddenWin]::IsWindowVisible($control)){return ''}
    $text=[DirectUpdateUi]::Text($control)
    if($text.Length){return $text}
    # Owner-drawn banner buttons have no native window text. Their UIA Name
    # includes the action and the notice (e.g. "Install: Update downloaded...").
    return [System.Windows.Automation.AutomationElement]::FromHandle($control).Current.Name
}

function Save-Receipt([string] $Name, $Value) {
    $path=Join-Path $Run $Name
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $json=ConvertTo-Json -InputObject $Value -Depth 12
    [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$path,$true)
}
function Get-RunPath([string] $Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if($full.Length -gt [IO.Path]::GetPathRoot($full).Length){return $full.TrimEnd([char[]]'\/')}
    return $full
}
function New-DriverEnvironment($Parent,[string] $Root) {
    $minimal=@{}
    foreach($name in @('SystemRoot','WINDIR','COMSPEC','PATH','PATHEXT','OS','SystemDrive','ProgramData','ProgramFiles','ProgramFiles(x86)','ProgramW6432','CommonProgramFiles','CommonProgramFiles(x86)','CommonProgramW6432','PROCESSOR_ARCHITECTURE','PROCESSOR_ARCHITEW6432','PROCESSOR_IDENTIFIER','PROCESSOR_LEVEL','PROCESSOR_REVISION','NUMBER_OF_PROCESSORS','COMPUTERNAME','USERNAME','USERDOMAIN','USERDNSDOMAIN','SESSIONNAME','USERPROFILE','HOMEDRIVE','HOMEPATH','HOME','GITHUB_ACTIONS','RUNNER_ENVIRONMENT')){
        foreach($key in $Parent.Keys){
            if([string]::Equals([string]$key,$name,[StringComparison]::OrdinalIgnoreCase)){$minimal[$name]=[string]$Parent[$key];break}
        }
    }
    $minimal.LOCALAPPDATA=Join-Path $Root 'localappdata'; $minimal.APPDATA=Join-Path $Root 'appdata'
    $minimal.TEMP=Join-Path $Root 'temp'; $minimal.TMP=$minimal.TEMP
    return $minimal
}
function Invoke-MinimalDriverEnvironment([scriptblock] $Start) {
    # CreateProcess inherits this explicit whitelist; restore only this controller.
    # Never log the saved environment or its values.
    $parent=[Environment]::GetEnvironmentVariables('Process')
    $minimal=New-DriverEnvironment $parent $Run
    try{
        foreach($name in @($parent.Keys)){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
        foreach($name in $minimal.Keys){[Environment]::SetEnvironmentVariable($name,$minimal[$name],'Process')}
        & $Start
    }finally{
        foreach($name in @([Environment]::GetEnvironmentVariables('Process').Keys)){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
        foreach($name in $parent.Keys){[Environment]::SetEnvironmentVariable($name,[string]$parent[$name],'Process')}
    }
}
function Test-WorkflowCredentialsAbsent($Environment) {
    foreach($name in @('GH_TOKEN','GITHUB_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN')){
        foreach($key in $Environment.Keys){
            if([string]::Equals([string]$key,$name,[StringComparison]::OrdinalIgnoreCase) -and -not [string]::IsNullOrEmpty([string]$Environment[$key])){return $false}
        }
    }
    return $true
}
function Get-UpdaterLogFact([string] $Text) {
    # Export fixed vocabulary only: raw updater messages can include paths/URLs.
    if($Text -cmatch '^(info|warning|warn|error)\((update_github_releases|update_portable_apply)\):'){
        return ('{0}({1}): [message omitted]' -f $Matches[1],$Matches[2])
    }
    return $null
}
function Invoke-ReleaseGh([string[]] $Arguments,[int] $Seconds=$TimeoutSeconds) {
    $info=[Diagnostics.ProcessStartInfo]::new((Get-Command gh -CommandType Application).Source)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
    $child=[Diagnostics.Process]::new(); $child.StartInfo=$info; $started=$false
    try{
        if(-not $child.Start()){throw 'Release request could not start'}
        $started=$true; $ownedPid=$child.Id; $ownedStart=$child.StartTime
        $output=$child.StandardOutput.ReadToEndAsync(); $errors=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit($Seconds*1000)){throw 'Release request timed out'}
        if($child.ExitCode -ne 0){throw 'Release request failed'}
        $null=$errors.GetAwaiter().GetResult()
        return $output.GetAwaiter().GetResult()
    }finally{
        if($started -and -not $child.HasExited){
            if($child.Id -ne $ownedPid -or $child.StartTime -ne $ownedStart){throw 'Release request process identity changed'}
            $child.Kill(); $null=$child.WaitForExit(5000)
        }
        $child.Dispose()
    }
}
function Get-Sha([string] $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-NativeArchitecture($native,$processArchitecture,$Architecture) {
    if ($native -cne $Architecture -or $processArchitecture -cne $Architecture) { throw 'Native OS and process architecture must match the requested test; emulation is not evidence' }
}
function Assert-NewRun([string] $Run) {
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new' }
}
function Assert-DriverProfile([string] $ActualLocal,[string] $ActualRoaming,[string] $Run) {
    $isolated=$ActualLocal -ceq (Join-Path $Run 'localappdata') -and $ActualRoaming -ceq (Join-Path $Run 'appdata')
    if(-not $isolated){throw 'Driver profile isolation failed'}
    return $isolated
}
function Get-DefaultWindowRows($Job) { @([HiddenWin]::DefaultJobWindows($Job)) }
function Assert-NoDefaultWindows($Job) {
    $escaped=@(Get-DefaultWindowRows $Job)
    if ($escaped.Count -ne 0) { throw 'Owned process has a window on Default; blocking further work' }
}
function Assert-ClipboardSequence($clipboardBefore,$clipboardAfter) {
    if($clipboardBefore -ne $clipboardAfter){throw 'Clipboard sequence changed during run; stop launches'}
}
function Add-UpdateSample($state,$states,[string] $Stage) {
    if ($state -and $state.Phase -ceq 'rollback') { throw 'Observed portable rollback' }
    if ($state) { $states.Add(@{ At=[datetime]::UtcNow.ToString('o'); Stage=$Stage; State=$state }) }
}
function Test-FinalizedUpdate($s,$states,[string] $exe,[string] $targetExe) {
    $swapped=$false; $confirmed=$false
    foreach($sample in $states){
        if($sample.State.Phase -ceq 'rollback'){throw 'Observed portable rollback'}
        if($sample.State.Phase -ceq 'swapped'){$swapped=$true}
        if($swapped -and $sample.State.Phase -ceq 'confirmed'){$confirmed=$true}
    }
    try {
        return $s -and $confirmed -and $null -eq $s.Phase -and $null -eq $s.StagedVersion -and (Get-Sha $exe) -ceq (Get-Sha $targetExe)
    } catch [IO.IOException] { return $false } catch [Management.Automation.ItemNotFoundException] { return $false }
}
function Assert-InstalledStub($result,[string] $Path) {
    $result.FinalStub=Get-Stub $Path
    if($result.FinalStub.Sha256 -cne $result.TargetStub.Sha256){throw 'Final stub differs from the verified candidate ZIP'}
}
function Get-StubLoadError([string] $Path) { [DirectUpdateUi]::StubLoadError($Path) }
function Get-SourceSnapshot([string] $Root,$OriginalNames=$null) {
    # Before the first CLI/GUI launch this includes EVERY original file.
    # Later snapshots skip new runtime artifacts BEFORE opening them for hashing.
    $mutable='^(?:(?:config\.ghostty|startup-attempts\.json|update-state\.json|window-state\.json|session-state\.json|jump-list-recents\.json|palette-mru\.txt)(?:\.lock)?|updates[\\/].*|shell-integration[\\/].*|share[\\/]ghostty[\\/]shell-integration[\\/]cmd[\\/]noctty-shell-integration\.lua|share[\\/]terminfo[\\/](?:67[\\/]ghostty|78[\\/]xterm-ghostty))$'
    @(foreach($entry in @(Get-Listing $Root)) {
        if($null -ne $OriginalNames -and $OriginalNames -cnotcontains $entry.Name -and $entry.Name -cmatch $mutable){continue}
        @{ Name=$entry.Name; Sha256=Get-Sha (Join-Path $Root $entry.Name) }
    })
}
function Assert-RejectedCopy($Before,[string] $Root) {
    # Only a genuinely absent journal is clear without a successful parse.
    $State=Get-UpdateState $Root -RequireReadable
    # Runtime exceptions apply only to files absent from the original snapshot.
    $after=@(Get-SourceSnapshot $Root @($Before.Name))
    $difference=@(Compare-Object @($Before | ForEach-Object {"$($_.Name):$($_.Sha256)"}) @($after | ForEach-Object {"$($_.Name):$($_.Sha256)"}))
    if($difference.Count){throw 'Rejected update changed the source copy'}
    if($State -and ($null -ne $State.Phase -or $null -ne $State.StagedVersion)){throw 'Rejected update left a staged transaction'}
}
function Assert-SourceStub([string] $Path) {
    if(-not (Test-Path -LiteralPath $Path)){throw 'Expected source stub before Removed update'}
    return Get-Stub $Path
}
function Get-NocttyJumpList($Entries) {
    @($Entries | Where-Object { [string]::Equals([IO.Path]::GetFileName($_.Path),'c2214d6ebc43ff3f.customDestinations-ms',[StringComparison]::OrdinalIgnoreCase) })
}
function Assert-LocalState($Before,$After,$JumpsBefore,$JumpsAfter) {
    $unchanged=$Before.Exists -eq $After.Exists -and $Before.Hash -eq $After.Hash -and $Before.Modified -eq $After.Modified
    $jumpChanges=@(Compare-Object @('begin'; Get-NocttyJumpList $JumpsBefore | ForEach-Object {"$($_.Path):$($_.Written)"}) @('begin'; Get-NocttyJumpList $JumpsAfter | ForEach-Object {"$($_.Path):$($_.Written)"}))
    if(-not $unchanged -or $jumpChanges.Count){throw 'Real startup or jump-list state changed; stop launches'}
    return $unchanged
}
function Write-IsolationReceipt($historyGuard,$isolation) {
    $historyFailure=$null
    try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure=$_ }
    $isolation.HistoryUnchanged=$null -eq $historyFailure
    Save-Receipt 'isolation.json' $isolation
    if($historyFailure){throw $historyFailure}
}
function Invoke-DefaultOraclePositive([string] $Pwsh) {
    # Hidden STATIC only, never noctty or a terminal shell. An exact owned helper
    # on Default must be detected and refused by the same production oracle.
    $control=Join-Path $Run 'default-oracle-control'
    $null=New-Item -ItemType Directory -Path $control
    $helper=Join-Path $control 'sentinel.ps1'
    $ui=(Join-Path $PSScriptRoot 'direct-update-ui.cs').Replace("'","''")
    $fixture=@'
param([string] $Root)
$ErrorActionPreference='Stop'
Add-Type -Path '__UI__'
$window=[DirectUpdateUi]::CreateSentinel()
try {
    Set-Content -LiteralPath (Join-Path $Root 'ready') -Value ''
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    while(-not (Test-Path -LiteralPath (Join-Path $Root 'release'))){
        if([datetime]::UtcNow -ge $deadline){throw 'Sentinel control timed out'}
        Start-Sleep -Milliseconds 50
    }
}finally{[DirectUpdateUi]::CloseSentinel($window)}
'@
    Set-Content -LiteralPath $helper -Value $fixture.Replace('__UI__',$ui)
    $controlJob=[HiddenWin]::CreateOwnedJob(); $controlLaunch=$null
    try{
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Root "{2}"' -f $Pwsh,$helper,$control
        $controlLaunch=[HiddenWin]::Launch($Pwsh,$line,$Run,'WinSta0\Default',$controlJob,'')
        $deadline=[datetime]::UtcNow.AddSeconds(20)
        while(-not(Test-Path -LiteralPath (Join-Path $control 'ready'))){
            if([datetime]::UtcNow -ge $deadline){throw 'Default oracle positive control timed out'}
            Start-Sleep -Milliseconds 50
        }
        $rows=@(Get-DefaultWindowRows $controlJob)
        $detected=@($rows | Where-Object ProcessId -EQ $controlLaunch.pid).Count -gt 0
        $refused=$false
        try{Assert-NoDefaultWindows $controlJob}catch{$refused=$_.Exception.Message -ceq 'Owned process has a window on Default; blocking further work'}
        if(-not $detected -or -not $refused){throw 'Default oracle positive control failed'}
        Save-Receipt 'default-positive.json' @{ Detected=$detected; Refused=$refused; Windows=$rows; HiddenStaticOnly=$true }
        Set-Content -LiteralPath (Join-Path $control 'release') -Value ''
        if([HiddenWin]::WaitForSingleObject($controlLaunch.process,10000) -ne 0){throw 'Default oracle control did not exit'}
    }finally{$null=[HiddenWin]::StopOwnedJob($controlJob);Close-Launch $controlLaunch}
}
function Invoke-ClipboardPositive([string] $Pwsh,[IntPtr] $Job,[string] $DesktopName) {
    # No native clipboard write is attempted on a developer machine. The hosted
    # helper switches to a fresh unnamed station and checks its identity first.
    if(-not $ephemeral){return @{Supported=$false;FailedApi='HostedOnly';WinSta0WriterNeverInvoked=$true}}
    $helper=Join-Path $Run 'clipboard-control.ps1'
    $code=(Join-Path $PSScriptRoot 'direct-update-clipboard-control.cs').Replace("'","''")
    $fixture=@'
param([string] $Receipt)
$ErrorActionPreference='Stop'
Add-Type -Path '__CODE__'
[DirectUpdateClipboardControl]::Run() | ConvertTo-Json | Set-Content -LiteralPath $Receipt
'@
    Set-Content -LiteralPath $helper -Value $fixture.Replace('__CODE__',$code)
    $receipt=Join-Path $Run 'clipboard-positive.json'
    $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Receipt "{2}"' -f $Pwsh,$helper,$receipt
    $controlLaunch=[HiddenWin]::Launch($Pwsh,$line,$Run,"WinSta0\$DesktopName",$Job,'')
    try{
        if([HiddenWin]::WaitForSingleObject($controlLaunch.process,30000) -ne 0){throw 'Clipboard positive helper timed out'}
        $fact=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
        if(-not $fact.Supported -or -not $fact.IsolatedStation -or -not $fact.SequenceAdvanced){throw 'Clipboard positive control failed'}
        return $fact
    }finally{Close-Launch $controlLaunch}
}
function Assert-HostedClipboardControl($fact,$Before,$After) {
    if(-not $fact.Supported -or -not $fact.HostedWinSta0 -or $Before -eq $After -or $fact.Before -ne $Before -or $fact.After -ne $After){throw 'Hosted WinSta0 clipboard oracle positive failed'}
}
function Invoke-HostedClipboardPositive([string] $Pwsh) {
    if(-not $ephemeral){throw 'WinSta0 clipboard control requires a disposable hosted runner'}
    $name='noctty-hw-'+[guid]::NewGuid().ToString('N')
    $controlDesktop=[HiddenWin]::CreateInheritedDesktop($name)
    $controlJob=[HiddenWin]::CreateOwnedJob(); $controlLaunch=$null
    $helper=Join-Path $Run 'hosted-clipboard-control.ps1'
    $code=(Join-Path $PSScriptRoot 'direct-update-hosted-clipboard-control.cs').Replace("'","''")
    $fixture=@'
param([string] $Receipt)
$ErrorActionPreference='Stop'
Add-Type -Path '__CODE__'
[DirectUpdateHostedClipboardControl]::Run() | ConvertTo-Json | Set-Content -LiteralPath $Receipt
'@
    Set-Content -LiteralPath $helper -Value $fixture.Replace('__CODE__',$code)
    $receipt=Join-Path $Run 'hosted-clipboard-positive.json'
    $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Receipt "{2}"' -f $Pwsh,$helper,$receipt
    try{
        $parentBefore=[HiddenWin]::GetClipboardSequenceNumber()
        $controlLaunch=[HiddenWin]::Launch($Pwsh,$line,$Run,"WinSta0\$name",$controlJob,'')
        if([HiddenWin]::WaitForSingleObject($controlLaunch.process,30000) -ne 0){throw 'Hosted clipboard control timed out'}
        $parentAfter=[HiddenWin]::GetClipboardSequenceNumber()
        $fact=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
        $fact | Add-Member -NotePropertyName ParentBefore -NotePropertyValue $parentBefore
        $fact | Add-Member -NotePropertyName ParentAfter -NotePropertyValue $parentAfter
        Save-Receipt 'hosted-clipboard-positive.json' $fact
        Assert-HostedClipboardControl $fact $parentBefore $parentAfter
        return $fact
    }finally{$null=[HiddenWin]::StopOwnedJob($controlJob);Close-Launch $controlLaunch;$null=[HiddenWin]::CloseDesktop($controlDesktop)}
}
function Get-Listing([string] $Root) {
    @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        @{ Name=[IO.Path]::GetRelativePath($Root,$_.FullName); Bytes=$_.Length }
    })
}
function Add-HostedMesa([string] $Root) {
    # Static llvmpipe build: only this WGL DLL enters the portable folder.
    # Upstream build source: mmozeiko/build-mesa@68725fb5d8e12c25efbb655780747bda417a53c1.
    $pins=@{
        x64='11dc079e356f33ce2ff84aa399c975da1a7bdd4c470f6eef4cf359ad8b9ca80f'
        arm64='067f3aca687fbf5afc8a1f41487bd051487d964d6c1686757a4d8ee6a2d3b901'
    }
    $destination=Join-Path $Run 'mesa-26.3.0'
    if(Test-Path -LiteralPath $destination){throw 'Mesa download directory must be new'}
    $null=New-Item -ItemType Directory -Path $destination
    $asset="mesa-llvmpipe-$Architecture-26.3.0.7z"
    $url="https://github.com/mmozeiko/build-mesa/releases/download/26.3.0/$asset"
    $archive=Join-Path $destination $asset
    $cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $client=[Net.Http.HttpClient]::new()
    try{
        # GetByteArrayAsync includes the response body in the cancellation budget.
        $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
        $bytes=$client.GetByteArrayAsync([Uri]$url,$cancel.Token).GetAwaiter().GetResult()
        [IO.File]::WriteAllBytes($archive,$bytes)
    }finally{$client.Dispose();$cancel.Dispose()}
    if((Get-Sha $archive) -cne $pins[$Architecture]){throw 'Mesa archive SHA-256 mismatch'}
    $expanded=Join-Path $destination 'expanded'
    $null=New-Item -ItemType Directory -Path $expanded
    $seven=(Get-Command 7z.exe -ErrorAction Stop).Source
    & $seven e $archive 'opengl32.dll' "-o$expanded" '-y' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Mesa WGL extraction failed'}
    $dll=Join-Path $expanded 'opengl32.dll'
    $null=Get-PeDataDirectories $dll
    $bytes=[IO.File]::ReadAllBytes($dll)
    $machine=[BitConverter]::ToUInt16($bytes,([BitConverter]::ToInt32($bytes,0x3c)+4))
    $expectedMachine=if($Architecture -ceq 'x64'){0x8664}else{0xaa64}
    if($machine -ne $expectedMachine){throw 'Mesa PE machine mismatch'}
    $injected=Join-Path $Root 'opengl32.dll'
    if(Test-Path -LiteralPath $injected){throw 'Mesa injection would overwrite an existing file'}
    $before=@(Get-Listing $Root)
    Copy-Item -LiteralPath $dll -Destination $injected
    $after=@(Get-Listing $Root)
    $changes=@(Compare-Object @($before | ForEach-Object {"$($_.Name):$($_.Bytes)"}) @($after | ForEach-Object {"$($_.Name):$($_.Bytes)"}))
    if($after.Count -ne $before.Count+1 -or $changes.Count -ne 1 -or $changes[0].SideIndicator -cne '=>' -or $changes[0].InputObject -cnotmatch '^opengl32\.dll:'){throw 'Mesa injection changed more than one extra file'}
    Save-Receipt 'mesa-input.json' @{ Source=$url; Tag='26.3.0'; SourceCommit='68725fb5d8e12c25efbb655780747bda417a53c1'; Architecture=$Architecture; ArchiveSha256=$pins[$Architecture]; VerifiedBeforeExtraction=$true; DllSha256=Get-Sha $injected; DllBytes=$bytes.Length; PeMachine=$machine; AddedFiles=@('opengl32.dll'); BeforeFileCount=$before.Count; AfterFileCount=$after.Count; ManagedEntry=$false }
}
function Get-ReleaseCopy([string] $Version) {
    $destination = Join-Path $Run "download-$Version"
    if (Test-Path -LiteralPath $destination) { throw 'Download destination already exists' }
    $null = New-Item -ItemType Directory -Path $destination
    $metadataText = Invoke-ReleaseGh @('api',"repos/amanthanvi/noctty/releases/tags/v$Version")
    $metadata = $metadataText | ConvertFrom-Json
    $zipName = "noctty-$Version-windows-$Architecture-portable.zip"
    $sumsName = "SHA256SUMS-windows-$Architecture.txt"
    $zipAsset = @($metadata.assets | Where-Object name -CEQ $zipName)
    $sumsAsset = @($metadata.assets | Where-Object name -CEQ $sumsName)
    if ($zipAsset.Count -ne 1 -or $sumsAsset.Count -ne 1) { throw 'Release lacks exact architecture assets' }
    # No overwrite flag: each download is into its own new empty directory.
    $null=Invoke-ReleaseGh @('release','download',"v$Version",'--repo','amanthanvi/noctty','--dir',$destination,'--pattern',$zipName,'--pattern',$sumsName)
    $zip = Join-Path $destination $zipName
    $matches = @(Get-Content -LiteralPath (Join-Path $destination $sumsName) | Where-Object { $_ -match ('^[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($zipName) + '$') })
    if ($matches.Count -ne 1) { throw 'Published checksum entry is absent or ambiguous' }
    $published = $matches[0].Substring(0,64).ToLowerInvariant()
    if ((Get-Sha $zip) -cne $published -or $zipAsset[0].digest -cne "sha256:$published") { throw 'Portable ZIP SHA-256 mismatch' }
    Save-Receipt "$Version-download.json" @{ Tag=$metadata.tag_name; Architecture=$Architecture; Asset=$zipName; Sha256=$published; Bytes=(Get-Item -LiteralPath $zip).Length; VerifiedBeforeExtraction=$true }
    $expanded = Join-Path $destination 'expanded'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip,$expanded)
    $executables = @(Get-ChildItem -LiteralPath $expanded -Filter 'noctty.exe' -File -Recurse)
    if ($executables.Count -ne 1) { throw 'Portable ZIP has ambiguous executable layout' }
    $publishers=@(foreach($name in @('noctty.exe','noctty.com')){
        $binary=Join-Path $executables[0].DirectoryName $name
        $signature=Assert-ReleaseSignature -Path $binary -Label 'Published portable executable' -AllowedPins @(Get-StubPublisherPins) -TrustSelfSigned $true
        @{File=$name;Sha256=Get-Sha $binary;SignerSpkiSha256=$signature.SpkiSha256;CryptographicallyVerified=$true}
    })
    Save-Receipt "$Version-publisher.json" $publishers
    return $executables[0].DirectoryName
}
function Assert-JournalKeys([Text.Json.JsonElement] $Value) {
    if($Value.ValueKind -eq [Text.Json.JsonValueKind]::Object){
        # Also retain the previous refusal of case-colliding field names.
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Value.EnumerateObject()){
            if(-not $names.Add($property.Name)){throw 'Duplicate journal key'}
            Assert-JournalKeys $property.Value
        }
    }elseif($Value.ValueKind -eq [Text.Json.JsonValueKind]::Array){
        foreach($child in $Value.EnumerateArray()){Assert-JournalKeys $child}
    }
}
function Assert-JournalSchema([Text.Json.JsonElement] $Value) {
    # v1.3.136 saveState writes all seventeen keys, including null values.
    foreach($name in @('last_checked_at','last_seen_version','release_feed_url','release_url','dismissed_version','staged_version','staged_kind','staged_installer_path','staged_portable_path','staged_payload_path','staged_sha256','staged_feed_url','staged_at','apply_requested_at','portable_apply_phase','portable_backup_path','portable_confirmation_token')){
        $property=[Text.Json.JsonElement]::new()
        if(-not $Value.TryGetProperty($name,[ref]$property)){throw 'Required journal key absent'}
    }
}
function Get-JournalField([Text.Json.JsonElement] $Value,[string] $Name) {
    $property=[Text.Json.JsonElement]::new()
    if(-not $Value.TryGetProperty($Name,[ref]$property)){return $null}
    switch($property.ValueKind){
        String {return $property.GetString()}
        Null {return $null}
        Number {return $property.GetInt64()}
        default {throw 'Invalid journal field type'}
    }
}
function Get-UpdateState([string] $Root,[switch] $RequireReadable) {
    $path = Join-Path $Root 'update-state.json'
    $document=$null
    try {
        $options=[Text.Json.JsonDocumentOptions]::new()
        $options.AllowTrailingCommas=$false
        $options.CommentHandling=[Text.Json.JsonCommentHandling]::Disallow
        # Decode the bytes directly so BOM detection cannot replace the strict decoder.
        $journal=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path))
        if($journal.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)){$journal=$journal.Substring(1)}
        $document=[Text.Json.JsonDocument]::Parse($journal,$options)
        $value=$document.RootElement
        if($value.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'Journal is not a JSON object'}
        Assert-JournalKeys $value
        if($RequireReadable){Assert-JournalSchema $value}
        # Explicit nonsecret projection while the document is alive.
        $version=Get-JournalField $value 'last_seen_version'
        $observed=if([string]$version -cmatch '^1\.[34]\.[0-9]+$'){[string]$version}else{$null}
        return @{ Phase=Get-JournalField $value 'portable_apply_phase'; StagedVersion=Get-JournalField $value 'staged_version'; StagedKind=Get-JournalField $value 'staged_kind'; LatestVersion=$observed; ApplyRequestedAt=Get-JournalField $value 'apply_requested_at'; FeedMatches=((Get-JournalField $value 'staged_feed_url') -ceq "https://api.github.com/repos/amanthanvi/noctty/releases/tags/v$TargetVersion") }
    } catch [IO.FileNotFoundException] { return $null
    } catch [IO.DirectoryNotFoundException] { return $null
    } catch {
        if($RequireReadable){throw 'Rejected update journal is unreadable or malformed'}
        return $null
    } finally { if($document){$document.Dispose()} }
}
function Wait-Check([string] $Stage,[scriptblock] $Predicate,[int] $Seconds=$TimeoutSeconds) {
    Save-Receipt 'progress.json' @{ Stage=$Stage; At=[datetime]::UtcNow.ToString('o') }
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do {
        $state=Get-UpdateState $script:install
        Add-UpdateSample $state $script:states $Stage
        if (& $Predicate) { return }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timed out: $Stage"
}
function Close-Launch($Launch) {
    if ($Launch) { $null=[HiddenWin]::CloseHandle($Launch.thread); $null=[HiddenWin]::CloseHandle($Launch.process) }
}
function Get-Version([string] $Exe,[string] $Name) {
    $output=Join-Path $Run "$Name-version.txt"
    $cmd=Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    # The console shim waits for the GUI CLI action; cmd does not wait for a GUI exe.
    $console=[IO.Path]::ChangeExtension($Exe,'.com')
    $line='"{0}" /D /S /C ""{1}" +version > "{2}" 2>&1"' -f $cmd,$console,$output
    $launch=[HiddenWin]::Launch($cmd,$line,$Run,"WinSta0\$DesktopName",$script:caseJob,'')
    try {
        if ([HiddenWin]::WaitForSingleObject($launch.process,30000) -ne 0) { throw 'Version action timed out' }
        [uint32]$code=0
        if (-not [HiddenWin]::GetExitCodeProcess($launch.process,[ref]$code) -or $code -ne 0) { throw 'Version action failed' }
        $first=@(Get-Content -LiteralPath $output)[0]
        if ($first -cnotmatch '^noctty [0-9]+\.[0-9]+\.[0-9]+') { throw 'Version action returned an unexpected first line' }
        return $first
    } finally { Close-Launch $launch }
}
function Get-Stub([string] $Path) {
    Assert-GhosttyVtStub -Path $Path
    $pins=@(Get-StubPublisherPins)
    # The published releases use the updater's pinned self-signed publisher.
    # Verify PKCS#7 + file hash and the pin without importing a trust root.
    $signature=Assert-ReleaseSignature -Path $Path -Label 'Portable stub' -AllowedPins $pins -TrustSelfSigned $true
    $errorCode=Get-StubLoadError $Path
    if ($errorCode -ne 1114) { throw 'Stub did not refuse loading with ERROR_DLL_INIT_FAILED' }
    return @{ Sha256=Get-Sha $Path; Bytes=(Get-Item -LiteralPath $Path).Length; Description=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileDescription; Signature=$signature.Status; SignatureCryptographicallyVerified=$true; SignerThumbprint=$signature.Thumbprint; SignerSpkiSha256=$signature.SpkiSha256; ExportDirectory=@(Get-PeDataDirectories $Path)[0]; ImportDirectory=@(Get-PeDataDirectories $Path)[1]; LoadError=$errorCode }
}
function Get-StubPublisherPins { @(Get-UpdaterPublisherSpkiPins -SourcePath (Join-Path $PSScriptRoot '..\..\src\update\github_releases.zig')) }

$native=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$processArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
Assert-NativeArchitecture $native $processArchitecture $Architecture
$ephemeral=$env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted'
if ([version]$FromVersion -lt [version]'1.3.136' -and -not $ephemeral) { throw 'Historical portable identity requires an ephemeral hosted runner' }
if($HostedMesa -and (-not $ephemeral -or $FromVersion -cne '1.3.125' -or $TargetVersion -cne '1.3.137' -or $Expected -cne 'Stub')){throw 'Mesa fixture requires hosted 1.3.125 to 1.3.137 stub acceptance'}
if (-not $Driver) {
    $Run=Get-RunPath $Run
    Assert-NewRun $Run
    if([HiddenWin]::CurrentDesktopName() -cne 'Default'){throw 'Controller must observe the Default desktop'}
    if (-not $ephemeral) {
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\AppUserModelId\io.github.amanthanvi.noctty',$false)
        if ($null -eq $key) { throw 'Product AUMID registration is absent; refusing a portable registration write' }
        $key.Dispose()
        . (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
        $startupBefore=Startup-Fingerprint
        $jumpsBefore=@(Get-NocttyJumpList @(Jump-List-Files))
    }
    $free=[IO.DriveInfo]::new([IO.Path]::GetPathRoot([Environment]::GetFolderPath('LocalApplicationData'))).AvailableFreeSpace
    if ($free -le 20GB) { throw 'System drive has 20 GB or less free' }
    $runFree=[DirectUpdateUi]::AvailableRunSpace($Run)
    if($runFree -le 20GB){throw 'Run volume has 20 GB or less free'}
    $null=New-Item -ItemType Directory -Path $Run
    $source=Get-ReleaseCopy $FromVersion
    $target=Get-ReleaseCopy $TargetVersion
    if($HostedMesa){Add-HostedMesa $source}
    $commit=git -C $PSScriptRoot rev-parse HEAD
    if($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[0-9a-f]{40}$'){throw 'Harness commit provenance unavailable'}
    Save-Receipt 'inputs.json' @{ SourceRelative=[IO.Path]::GetRelativePath($Run,$source); TargetRelative=[IO.Path]::GetRelativePath($Run,$target); NativeArchitecture=$native; EphemeralRunner=$ephemeral; HarnessCommit=$commit; HarnessSha256=Get-Sha $PSCommandPath; UiSha256=Get-Sha (Join-Path $PSScriptRoot 'direct-update-ui.cs'); ContractSha256=Get-Sha (Join-Path $PSScriptRoot 'direct-update-contract.ps1'); ClipboardControlSha256=Get-Sha (Join-Path $PSScriptRoot 'direct-update-clipboard-control.cs'); HostedClipboardControlSha256=Get-Sha (Join-Path $PSScriptRoot 'direct-update-hosted-clipboard-control.cs') }
    foreach ($directory in @('localappdata','appdata','temp')) { $null=New-Item -ItemType Directory -Path (Join-Path $Run $directory) }
    $historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'direct-update-acceptance'
    $clipboardBefore=[HiddenWin]::GetClipboardSequenceNumber()
    $DesktopName='noctty-hw-'+[guid]::NewGuid().ToString('N')
    $desktop=[HiddenWin]::CreateInheritedDesktop($DesktopName)
    $job=[HiddenWin]::CreateOwnedJob()
    $launch=$null; $exitCode=1; $defaultSamples=0; $privateSamples=[Collections.Generic.List[object]]::new(); $profileObserved=$false
    $saved=@{}; foreach($name in @('LOCALAPPDATA','APPDATA','TEMP','TMP')) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
    try {
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'; $env:TEMP=Join-Path $Run 'temp'; $env:TMP=$env:TEMP
        $pwsh=(Get-Process -Id $PID).Path
        Invoke-DefaultOraclePositive $pwsh
        $clipboardPositive=Invoke-ClipboardPositive $pwsh $job $DesktopName
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Run "{2}" -FromVersion {3} -TargetVersion {4} -Architecture {5} -Expected {6} -TimeoutSeconds {7} -DesktopName {8} -Driver' -f $pwsh,$PSCommandPath,$Run,$FromVersion,$TargetVersion,$Architecture,$Expected,$TimeoutSeconds,$DesktopName
        if($HostedMesa){$line+=' -HostedMesa'}
        $launch=Invoke-MinimalDriverEnvironment { [HiddenWin]::Launch($pwsh,$line,$Run,"WinSta0\$DesktopName",$job,(Join-Path $Run 'driver-raw.log')) }
        # Longest branch has five full waits, one <=60s pane wait and bounded
        # version/shutdown/handshake waits. Leave margin for hashing and teardown.
        $deadline=[datetime]::UtcNow.AddSeconds(8*$TimeoutSeconds+300)
        do {
            Assert-NoDefaultWindows $job
            $defaultSamples++
            if(Test-Path -LiteralPath (Join-Path $Run 'driver-ready.json')) {
                $ready=Get-Content -LiteralPath (Join-Path $Run 'driver-ready.json') -Raw | ConvertFrom-Json
                if($ready.ProcessId -ne $launch.pid -or $ready.Desktop -cne $DesktopName -or -not $ready.IsolatedProfile) { throw 'Private driver receipt mismatch' }
                $profileObserved=[bool]$ready.IsolatedProfile
                if(Test-Path -LiteralPath (Join-Path $Run 'driver-done')){
                    Set-Content -LiteralPath (Join-Path $Run 'driver-release') -Value ''
                }else{
                    $private=@([HiddenWin]::PrivateJobWindows($job,$DesktopName))
                    if(@($private | Where-Object ProcessId -EQ $launch.pid).Count -eq 0){throw 'Private driver sentinel was not observed'}
                    $privateSamples.Add(@{ At=[datetime]::UtcNow.ToString('o'); Windows=$private })
                }
                if(-not (Test-Path -LiteralPath (Join-Path $Run 'driver-approved'))) { Set-Content -LiteralPath (Join-Path $Run 'driver-approved') -Value '' }
            }
            if([HiddenWin]::WaitForSingleObject($launch.process,250) -eq 0) { break }
            if([datetime]::UtcNow -ge $deadline) { throw 'Private driver timed out' }
        } while($true)
        [uint32]$code=1; if(-not [HiddenWin]::GetExitCodeProcess($launch.process,[ref]$code)){throw 'Driver exit read failed'}; $exitCode=$code
        if($exitCode -ne 0 -and -not(Test-Path -LiteralPath (Join-Path $Run 'result.json'))){
            $raw=Get-Content -LiteralPath (Join-Path $Run 'driver-raw.log') -Raw
            $plain=$raw -replace '\x1b\[[0-9;]*[A-Za-z]',''
            Save-Receipt 'driver-error-projection.json' @{ Lines=@([regex]::Matches($plain,'(?m)^\s*(\d+)\s*\|') | ForEach-Object {$_.Groups[1].Value}); CannotBind=$plain.Contains('Cannot bind'); CannotFindType=$plain.Contains('Cannot find type'); CannotAddType=$plain.Contains('Cannot add type'); ArgumentError=$plain.Contains('parameter'); AccessDenied=$plain.Contains('Access is denied') }
        }
    } catch {
        Save-Receipt 'controller-error.json' @{ErrorType=$_.Exception.GetType().Name;Line=$_.InvocationInfo.ScriptLineNumber}
        throw
    } finally {
        foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
        $cleanup=$false
        try { $null=[HiddenWin]::StopOwnedJob($job); $cleanup=$true } finally {
            Close-Launch $launch; $null=[HiddenWin]::CloseDesktop($desktop)
            $clipboardAfter=[HiddenWin]::GetClipboardSequenceNumber()
            $localStateUnchanged=$null
            $realStartupChanged=$null
            $localStateFailure=$null
            if(-not $ephemeral){
                $startupAfter=Startup-Fingerprint
                $realStartupChanged=$startupBefore.Exists -ne $startupAfter.Exists -or $startupBefore.Hash -ne $startupAfter.Hash -or $startupBefore.Modified -ne $startupAfter.Modified
                try{$localStateUnchanged=Assert-LocalState $startupBefore $startupAfter $jumpsBefore @(Get-NocttyJumpList @(Jump-List-Files))}catch{$localStateUnchanged=$false;$localStateFailure=$_}
            }
            Save-Receipt 'private-windows.json' @($privateSamples.ToArray())
            $isolation=@{ Desktop=$DesktopName; ExplicitDesktopOnHarnessLaunchesByConstruction=$true; OwnLocalAppData=$profileObserved; OwnAppData=$profileObserved; RealNocttyDirectoryAccessed=$(if($realStartupChanged -eq $true){$true}else{$null}); RealNocttyAccessMeasurement='Startup mutation detected; reads and unchanged writes unobserved'; LocalStateUnchanged=$localStateUnchanged; ClipboardBefore=$clipboardBefore; ClipboardAfter=$clipboardAfter; ClipboardNativePositiveControl=($clipboardPositive.Supported -and $clipboardPositive.SequenceAdvanced); ClipboardControl=$clipboardPositive; DefaultWindowSamples=$defaultSamples; PrivateWindowSamples=$privateSamples.Count; OwnedJobCleanedUp=$cleanup; DriverExit=$exitCode }
            Write-IsolationReceipt $historyGuard $isolation
            Assert-ClipboardSequence $clipboardBefore $clipboardAfter
            if($localStateFailure){throw $localStateFailure}
            if($ephemeral){$isolation.HostedClipboardPositive=Invoke-HostedClipboardPositive $pwsh;Save-Receipt 'isolation.json' $isolation}
        }
    }
    if($exitCode -ne 0){throw 'Acceptance driver failed; read sanitized result.json'}
    Write-Host "direct-update acceptance: PASS ($FromVersion -> $TargetVersion, $Architecture, $Expected); evidence=$Run"
    exit 0
}

$script:states=[Collections.Generic.List[object]]::new()
$script:caseJob=[HiddenWin]::CreateOwnedJob()
$script:install=$null
$app=$null; $relaunch=$null
$finalProcess=$null
$sentinel=[IntPtr]::Zero
$result=@{ Passed=$false; FromVersion=$FromVersion; TargetVersion=$TargetVersion; Architecture=$Architecture; Expected=$Expected; Steps=[Collections.Generic.List[string]]::new() }
try {
    if($DesktopName -cnotmatch '^noctty-hw-[a-f0-9]{32}$' -or [HiddenWin]::CurrentDesktopName() -cne $DesktopName){throw 'Driver is not on its private desktop'}
    $isolated=Assert-DriverProfile $env:LOCALAPPDATA $env:APPDATA $Run
    $credentialsAbsent=Test-WorkflowCredentialsAbsent ([Environment]::GetEnvironmentVariables('Process'))
    if(-not $credentialsAbsent){throw 'Driver workflow credentials were inherited'}
    # EnumDesktopWindows returns false/error 0 on a genuinely empty desktop.
    # This hidden driver-owned window gives the parent's oracle a positive control.
    $sentinel=[DirectUpdateUi]::CreateSentinel()
    Save-Receipt 'driver-ready.json' @{ ProcessId=$PID; Desktop=$DesktopName; IsolatedProfile=$isolated; WorkflowCredentialsAbsent=$credentialsAbsent; SystemRootPresent=(-not [string]::IsNullOrEmpty($env:SystemRoot)); WindirPresent=(-not [string]::IsNullOrEmpty($env:WINDIR)); PathPresent=(-not [string]::IsNullOrEmpty($env:PATH)); ComSpecPresent=(-not [string]::IsNullOrEmpty($env:COMSPEC)) }
    $approvalDeadline=[datetime]::UtcNow.AddSeconds(30)
    while(-not (Test-Path -LiteralPath (Join-Path $Run 'driver-approved'))){if([datetime]::UtcNow -ge $approvalDeadline){throw 'Parent desktop approval timed out'}; Start-Sleep -Milliseconds 100}
    $inputs=Get-Content -LiteralPath (Join-Path $Run 'inputs.json') -Raw | ConvertFrom-Json
    $script:install=Join-Path $Run $inputs.SourceRelative
    $target=Join-Path $Run $inputs.TargetRelative
    $exe=Join-Path $script:install 'noctty.exe'
    if($HostedMesa){$env:GALLIUM_DRIVER='llvmpipe'; $result.Mesa=Get-Content -LiteralPath (Join-Path $Run 'mesa-input.json') -Raw | ConvertFrom-Json}
    Set-Content -LiteralPath (Join-Path $script:install 'noctty.portable') -Value '' -NoNewline
    $sourceSnapshot=@(Get-SourceSnapshot $script:install)
    Save-Receipt 'source-hashes.json' $sourceSnapshot
    if($Expected -ceq 'Removed'){$result.BeforeStub=Assert-SourceStub (Join-Path $script:install 'ghostty-vt.dll')}
    $result.BeforeVersion=Get-Version $exe 'before'
    if($result.BeforeVersion -cne "noctty $FromVersion"){throw 'Wrong source version'}
    $result.BeforeExeSha256=Get-Sha $exe
    Save-Receipt 'before-listing.json' (Get-Listing $script:install)
    if($Expected -ceq 'Stub'){$result.TargetStub=Get-Stub (Join-Path $target 'ghostty-vt.dll')}
    $feed="https://api.github.com/repos/amanthanvi/noctty/releases/tags/v$TargetVersion"
    $class='noctty-update-'+[guid]::NewGuid().ToString('N')
    $env:GHOSTTY_LOG='stderr'
    $shell=Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $line='"{0}" --window-save-state=never "--command=direct:{3} /D" --clipboard-write=deny --clipboard-read=deny --single-instance=false --class={1} --auto-update=download --auto-update-feed-url={2} --confirm-close-surface=false --keybind=f7=check_for_updates' -f $exe,$class,$feed,$shell
    $app=[HiddenWin]::Launch($exe,$line,$script:install,"WinSta0\$DesktopName",$script:caseJob,(Join-Path $Run 'app-raw.log'))
    $script:hostWindow=[IntPtr]::Zero
    Wait-Check 'source window' {
        $windows=@([HiddenWin]::Hosts($app.pid))
        if($windows.Count -eq 1){$script:hostWindow=$windows[0];return $true}
        if([HiddenWin]::WaitForSingleObject($app.process,0) -eq 0){
            [uint32]$startupExit=259; $null=[HiddenWin]::GetExitCodeProcess($app.process,[ref]$startupExit)
            $result.SourceStartupExit=$startupExit
            throw 'Old application exited before a source window'
        }
        return $false
    }
    Wait-Check 'source pane ready' { @([HiddenWin]::Surfaces($script:hostWindow)).Count -eq 1 } ([Math]::Min(60,$TimeoutSeconds))
    $panes=@([HiddenWin]::Surfaces($script:hostWindow))
    $legacyPainted=$FromVersion -ceq '1.3.125'
    if($HostedMesa){
        $ownedProcess=[Diagnostics.Process]::GetProcessById($app.pid)
        try{
            $modules=@($ownedProcess.Modules | Where-Object ModuleName -IEQ 'opengl32.dll')
            if($modules.Count -ne 1 -or $modules[0].FileName -ine (Join-Path $script:install 'opengl32.dll') -or (Get-Sha $modules[0].FileName) -cne $result.Mesa.DllSha256){throw 'Mesa module backing mismatch'}
            $result.Mesa | Add-Member -NotePropertyName LoadedModuleMatches -NotePropertyValue $true
        }finally{$ownedProcess.Dispose()}
    }
    # 1.3.125's manual completion masks its painted update notice with an info
    # banner. Its configured automatic download uses the same pinned tag feed.
    if($legacyPainted){$result.Steps.Add('Automatic check through configured tag feed')}
    else{[DirectUpdateUi]::CheckKey($panes[0]); $result.Steps.Add('Posted F7 check_for_updates')}
    if($Expected -ceq 'Rejected') {
        Wait-Check 'incomplete payload banner' { (Read-ControlName $script:hostWindow 1913) -match 'portable ZIP payload is incomplete' }
        $result.Banner=Read-ControlName $script:hostWindow 1913
        # An error message temporarily covers the underlying update notice.
        [DirectUpdateUi]::Click([DirectUpdateUi]::Child($script:hostWindow,1915))
        Wait-Check 'rejected update notice' { (Read-ControlName $script:hostWindow 1914) -cmatch '^Open Release(?::|$)' }
        $result.NoticeButton=Read-ControlName $script:hostWindow 1914
        if($result.NoticeButton -cnotmatch '^Open Release(?::|$)'){throw 'Rejected update does not offer Open Release'}
        Assert-RejectedCopy $sourceSnapshot $script:install
        $result.SourceCopyIntact=$true
    } else {
        Wait-Check 'verified portable stage' { $s=Get-UpdateState $script:install; $s -and $s.StagedVersion -ceq $TargetVersion -and $s.StagedKind -ceq 'portable' -and $s.FeedMatches -and ($legacyPainted -or (Read-ControlName $script:hostWindow 1914) -cmatch '^Install(?::|$)') }
        if($legacyPainted){
            $result.LegacyInstall=[DirectUpdateUi]::LegacyInstall($script:hostWindow,$panes[0],$app.pid)
            $result.Steps.Add('Posted host-only 1.3.125 painted Install pair')
        }else{
            $result.Banner=Read-ControlName $script:hostWindow 1913
            $result.NoticeButton=Read-ControlName $script:hostWindow 1914
            [DirectUpdateUi]::Click([DirectUpdateUi]::Child($script:hostWindow,1914)); $result.Steps.Add('Posted Install notification')
        }
        # Some historical releases apply immediately; later releases ask first.
        Wait-Check 'pending or confirmation' { ([HiddenWin]::WaitForSingleObject($app.process,0) -eq 0) -or [HiddenWin]::IsWindowVisible([DirectUpdateUi]::Child($script:hostWindow,2003)) }
        if([HiddenWin]::WaitForSingleObject($app.process,0) -ne 0){
            $result.ConfirmButton=Read-ControlName $script:hostWindow 2003
            [DirectUpdateUi]::Click([DirectUpdateUi]::Child($script:hostWindow,2003)); $result.Steps.Add('Posted update confirmation')
        }
        Wait-Check 'old application exited' { [HiddenWin]::WaitForSingleObject($app.process,0) -eq 0 }
        [uint32]$appCode=1; $null=[HiddenWin]::GetExitCodeProcess($app.process,[ref]$appCode); $result.OldAppExit=$appCode
        if($appCode -ne 0){throw 'Old application exited unsuccessfully'}
        $s=Get-UpdateState $script:install
        if(-not $s -or $s.Phase -cne 'pending'){throw 'Install did not record a pending portable apply'}
        $result.Pending=$s
        $relaunch=[HiddenWin]::Launch($exe,$line,$script:install,"WinSta0\$DesktopName",$script:caseJob,(Join-Path $Run 'relaunch-raw.log'))
        Wait-Check 'target confirmed and helper finalized' { Test-FinalizedUpdate (Get-UpdateState $script:install) $script:states $exe (Join-Path $target 'noctty.exe') }
        if($Expected -ceq 'Stub') {
            Assert-InstalledStub $result (Join-Path $script:install 'ghostty-vt.dll')
        } elseif(Test-Path -LiteralPath (Join-Path $script:install 'ghostty-vt.dll')){throw 'Update did not remove the stub'}
    }
    $result.AfterVersion=Get-Version $exe 'after'
    if($HostedMesa){
        if((Get-Sha (Join-Path $script:install 'opengl32.dll')) -cne $result.Mesa.DllSha256){throw 'Mesa extra file was not preserved'}
        $result.Mesa | Add-Member -NotePropertyName PreservedAfterUpdate -NotePropertyValue $true
    }
    $expectedVersion=if($Expected -ceq 'Rejected'){$FromVersion}else{$TargetVersion}
    if($result.AfterVersion -cne "noctty $expectedVersion"){throw 'Wrong final version'}
    $result.FinalState=Get-UpdateState $script:install
    $result.AfterExeSha256=Get-Sha $exe
    Save-Receipt 'after-listing.json' (Get-Listing $script:install)
    $windows=@([HiddenWin]::PrivateJobWindows($script:caseJob,$DesktopName) | Where-Object ClassName -CEQ 'noctty.win32.host')
    if($windows.Count -ne 1){throw 'Final application is not running on the private desktop'}
    $result.FinalWindowProcessId=$windows[0].ProcessId
    if(@([HiddenWin]::JobProcessIds($script:caseJob)) -notcontains $windows[0].ProcessId){throw 'Final application is not in the owned job'}
    $finalProcess=[Diagnostics.Process]::GetProcessById($windows[0].ProcessId)
    $finalHandle=$finalProcess.Handle
    if($finalProcess.MainModule.FileName -ine $exe){throw 'Final application identity does not match the portable copy'}
    $hosts=@([HiddenWin]::Hosts($windows[0].ProcessId))
    foreach($hwnd in $hosts){$null=[HiddenWin]::PostMessageW($hwnd,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)}
    if(-not $finalProcess.WaitForExit(40000)){throw 'Final application did not shut down normally'}
    [uint32]$finalCode=259
    if(-not [HiddenWin]::GetExitCodeProcess($finalHandle,[ref]$finalCode) -or $finalCode -ne 0){throw 'Final application exited unsuccessfully'}
    $result.FinalAppExit=$finalCode
    Wait-Check 'normal final application shutdown' { @([HiddenWin]::JobProcessIds($script:caseJob)).Count -eq 0 } 40
    if($Expected -ceq 'Rejected'){Assert-RejectedCopy $sourceSnapshot $script:install}
    $result.NoRollbackObserved=$true; $result.Passed=$true
} catch {
    # Fixed stage names above and error types only; never export arbitrary native errors/logs.
    $result.ErrorType=$_.Exception.GetType().Name
    $result.ErrorStage=if($_.Exception.Message -cmatch '^(Timed out: |Observed |Wrong |Expected |Driver |Parent |Install did not |Old application |Final application |Rejected update |Update did not |Acceptance |Stub |Owned )'){$_.Exception.Message}else{'Driver operation failed; inspect retained local raw evidence'}
    $result.ErrorLine=$_.InvocationInfo.ScriptLineNumber
    $rawStartup=Join-Path $Run 'app-raw.log'
    if(Test-Path -LiteralPath $rawStartup){
        $startupText=[string](Get-Content -LiteralPath $rawStartup -Raw)
        $result.StartupErrorKinds=@{EnvironmentVariableNotFound=$startupText.Contains('EnvironmentVariableNotFound');FontFailure=($startupText -match '(?i)(font.*(?:fail|error)|(?:fail|error).*font)');RendererFailure=($startupText -match '(?i)(renderer.*(?:fail|error)|(?:fail|error).*renderer)')}
        $result.StartupErrorTags=@('AccessDenied','FileNotFound','PathNotFound','OutOfMemory','SystemResources','FontNotFound','NoFonts','Unexpected','SystemError','EnvironmentVariableNotFound' | Where-Object {$startupText.Contains('error.'+$_)})
        $result.StartupPanicked=$startupText.Contains('panic:') -or $startupText.Contains('reached unreachable code')
    }
    if($app){
        try {
            $result.StartupWindows=@([DirectUpdateUi]::StartupFacts($app.pid) | ForEach-Object {
                @{ ClassName=$_.ClassName; ControlId=$_.ControlId; Visible=$_.Visible;
                    GraphicsDialogText=($_.GraphicsDialogText -replace '(?<![A-Za-z])[A-Za-z]:[\\/][^\s,;]+','[path]') }
            })
        } catch { $result.StartupDiagnosticErrorType=$_.Exception.GetType().Name }
    }
} finally {
    Save-Receipt 'state-timeline.json' @($script:states.ToArray())
    $cleaned=$false
    try{$null=[HiddenWin]::StopOwnedJob($script:caseJob);$cleaned=$true}finally{
        Close-Launch $app; Close-Launch $relaunch; $result.OwnedJobCleanedUp=$cleaned
        if($finalProcess){$finalProcess.Dispose()}
        $lines=[Collections.Generic.List[string]]::new()
        foreach($file in @('app-raw.log','relaunch-raw.log')){
            $path=Join-Path $Run $file
            if(Test-Path -LiteralPath $path){foreach($text in Get-Content -LiteralPath $path){
                $projected=Get-UpdaterLogFact $text
                if($projected){$lines.Add($projected)}
            }}
        }
        $result.RedactedUpdaterLogs=@($lines.ToArray())
        Save-Receipt 'result.json' $result
        Set-Content -LiteralPath (Join-Path $Run 'driver-done') -Value ''
        $releaseDeadline=[datetime]::UtcNow.AddSeconds(10)
        while(-not (Test-Path -LiteralPath (Join-Path $Run 'driver-release'))){if([datetime]::UtcNow -ge $releaseDeadline){throw 'Parent sentinel release timed out'}; Start-Sleep -Milliseconds 100}
        [DirectUpdateUi]::CloseSentinel($sentinel)
    }
}
if(-not $result.Passed){exit 1}
exit 0
