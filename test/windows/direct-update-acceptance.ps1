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
The harness never reads the real noctty directory or any clipboard contents.
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
    [switch] $Driver,
    [string] $DesktopName
)
$ErrorActionPreference = 'Stop'
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
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run $Name) -Encoding utf8
}
function Get-Sha([string] $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-Listing([string] $Root) {
    @(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
        @{ Name=[IO.Path]::GetRelativePath($Root,$_.FullName); Bytes=$_.Length }
    })
}
function Get-ReleaseCopy([string] $Version) {
    $destination = Join-Path $Run "download-$Version"
    if (Test-Path -LiteralPath $destination) { throw 'Download destination already exists' }
    $null = New-Item -ItemType Directory -Path $destination
    $metadataText = gh api "repos/amanthanvi/noctty/releases/tags/v$Version"
    if ($LASTEXITCODE -ne 0) { throw 'Release metadata request failed' }
    $metadata = $metadataText | ConvertFrom-Json
    $zipName = "noctty-$Version-windows-$Architecture-portable.zip"
    $sumsName = "SHA256SUMS-windows-$Architecture.txt"
    $zipAsset = @($metadata.assets | Where-Object name -CEQ $zipName)
    $sumsAsset = @($metadata.assets | Where-Object name -CEQ $sumsName)
    if ($zipAsset.Count -ne 1 -or $sumsAsset.Count -ne 1) { throw 'Release lacks exact architecture assets' }
    # No overwrite flag: each download is into its own new empty directory.
    gh release download "v$Version" --repo amanthanvi/noctty --dir $destination --pattern $zipName --pattern $sumsName
    if ($LASTEXITCODE -ne 0) { throw 'Release asset download failed' }
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
    return $executables[0].DirectoryName
}
function Get-UpdateState([string] $Root) {
    $path = Join-Path $Root 'update-state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
    # Explicit nonsecret projection: never export confirmation tokens or arbitrary paths.
    return @{ Phase=$value.portable_apply_phase; StagedVersion=$value.staged_version; StagedKind=$value.staged_kind; LatestVersion=$value.latest_version; ApplyRequestedAt=$value.apply_requested_at; FeedMatches=($value.staged_feed_url -ceq "https://api.github.com/repos/amanthanvi/noctty/releases/tags/v$TargetVersion") }
}
function Wait-Check([string] $Stage,[scriptblock] $Predicate,[int] $Seconds=$TimeoutSeconds) {
    Save-Receipt 'progress.json' @{ Stage=$Stage; At=[datetime]::UtcNow.ToString('o') }
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do {
        $state=Get-UpdateState $script:install
        if ($state -and $state.Phase -ceq 'rollback') { throw 'Observed portable rollback' }
        if ($state) { $script:states.Add(@{ At=[datetime]::UtcNow.ToString('o'); Stage=$Stage; State=$state }) }
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
    $pins=@(Get-UpdaterPublisherSpkiPins -SourcePath (Join-Path $PSScriptRoot '..\..\src\update\github_releases.zig'))
    # The published releases use the updater's pinned self-signed publisher.
    # Verify PKCS#7 + file hash and the pin without importing a trust root.
    $signature=Assert-ReleaseSignature -Path $Path -Label 'Portable stub' -AllowedPins $pins -TrustSelfSigned $true
    $errorCode=[DirectUpdateUi]::StubLoadError($Path)
    if ($errorCode -ne 1114) { throw 'Stub did not refuse loading with ERROR_DLL_INIT_FAILED' }
    return @{ Sha256=Get-Sha $Path; Bytes=(Get-Item -LiteralPath $Path).Length; Description=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileDescription; Signature=$signature.Status; SignatureCryptographicallyVerified=$true; SignerThumbprint=$signature.Thumbprint; SignerSpkiSha256=$signature.SpkiSha256; ExportDirectory=@(Get-PeDataDirectories $Path)[0]; ImportDirectory=@(Get-PeDataDirectories $Path)[1]; LoadError=$errorCode }
}

$native=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$processArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ($native -cne $Architecture -or $processArchitecture -cne $Architecture) { throw 'Native OS and process architecture must match the requested test; emulation is not evidence' }
$ephemeral=$env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted'
if ([version]$FromVersion -lt [version]'1.3.136' -and -not $ephemeral) { throw 'Historical portable identity requires an ephemeral hosted runner' }
if (-not $Driver) {
    $Run=[IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new' }
    if (-not $ephemeral) {
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\AppUserModelId\io.github.amanthanvi.noctty',$false)
        if ($null -eq $key) { throw 'Product AUMID registration is absent; refusing a portable registration write' }
        $key.Dispose()
    }
    $free=[IO.DriveInfo]::new([IO.Path]::GetPathRoot([Environment]::GetFolderPath('LocalApplicationData'))).AvailableFreeSpace
    if ($free -le 20GB) { throw 'System drive has 20 GB or less free' }
    $null=New-Item -ItemType Directory -Path $Run
    $source=Get-ReleaseCopy $FromVersion
    $target=Get-ReleaseCopy $TargetVersion
    Save-Receipt 'inputs.json' @{ SourceRelative=[IO.Path]::GetRelativePath($Run,$source); TargetRelative=[IO.Path]::GetRelativePath($Run,$target); NativeArchitecture=$native; EphemeralRunner=$ephemeral }
    foreach ($directory in @('localappdata','appdata','temp')) { $null=New-Item -ItemType Directory -Path (Join-Path $Run $directory) }
    $historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'direct-update-acceptance'
    $clipboardBefore=[HiddenWin]::GetClipboardSequenceNumber()
    $DesktopName='noctty-hw-'+[guid]::NewGuid().ToString('N')
    $desktop=[HiddenWin]::CreateInheritedDesktop($DesktopName)
    $job=[HiddenWin]::CreateOwnedJob()
    $launch=$null; $exitCode=1; $defaultSamples=0; $privateSamples=0
    $saved=@{}; foreach($name in @('LOCALAPPDATA','APPDATA','TEMP','TMP')) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
    try {
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'; $env:TEMP=Join-Path $Run 'temp'; $env:TMP=$env:TEMP
        $pwsh=(Get-Process -Id $PID).Path
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Run "{2}" -FromVersion {3} -TargetVersion {4} -Architecture {5} -Expected {6} -TimeoutSeconds {7} -DesktopName {8} -Driver' -f $pwsh,$PSCommandPath,$Run,$FromVersion,$TargetVersion,$Architecture,$Expected,$TimeoutSeconds,$DesktopName
        $launch=[HiddenWin]::Launch($pwsh,$line,$Run,"WinSta0\$DesktopName",$job,(Join-Path $Run 'driver-raw.log'))
        $deadline=[datetime]::UtcNow.AddSeconds(3*$TimeoutSeconds+120)
        do {
            $escaped=@([HiddenWin]::DefaultJobWindows($job))
            $defaultSamples++
            if ($escaped.Count -ne 0) { throw 'Owned process has a window on Default; blocking further work' }
            if(Test-Path -LiteralPath (Join-Path $Run 'driver-ready.json')) {
                $ready=Get-Content -LiteralPath (Join-Path $Run 'driver-ready.json') -Raw | ConvertFrom-Json
                if($ready.ProcessId -ne $launch.pid -or $ready.Desktop -cne $DesktopName -or -not $ready.IsolatedProfile) { throw 'Private driver receipt mismatch' }
                if(Test-Path -LiteralPath (Join-Path $Run 'driver-done')){
                    Set-Content -LiteralPath (Join-Path $Run 'driver-release') -Value ''
                }else{
                    $private=@([HiddenWin]::PrivateJobWindows($job,$DesktopName)); $privateSamples++
                }
                if(-not (Test-Path -LiteralPath (Join-Path $Run 'driver-approved'))) { Set-Content -LiteralPath (Join-Path $Run 'driver-approved') -Value '' }
            }
            if([HiddenWin]::WaitForSingleObject($launch.process,250) -eq 0) { break }
            if([datetime]::UtcNow -ge $deadline) { throw 'Private driver timed out' }
        } while($true)
        [uint32]$code=1; if(-not [HiddenWin]::GetExitCodeProcess($launch.process,[ref]$code)){throw 'Driver exit read failed'}; $exitCode=$code
    } finally {
        foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
        $cleanup=$false
        try { $null=[HiddenWin]::StopOwnedJob($job); $cleanup=$true } finally {
            Close-Launch $launch; $null=[HiddenWin]::CloseDesktop($desktop)
            $clipboardAfter=[HiddenWin]::GetClipboardSequenceNumber()
            Assert-WindowsHarnessHistoryGuard -Guard $historyGuard
            Save-Receipt 'isolation.json' @{ Desktop=$DesktopName; ExplicitDesktopOnHarnessLaunches=$true; OwnLocalAppData=$true; OwnAppData=$true; RealNocttyDirectoryAccessed=$false; HistoryUnchanged=$true; ClipboardBefore=$clipboardBefore; ClipboardAfter=$clipboardAfter; DefaultWindowSamples=$defaultSamples; PrivateWindowSamples=$privateSamples; OwnedJobCleanedUp=$cleanup; DriverExit=$exitCode }
            if($clipboardBefore -ne $clipboardAfter){throw 'Clipboard sequence changed during run; stop launches'}
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
    $isolated=$env:LOCALAPPDATA -ceq (Join-Path $Run 'localappdata') -and $env:APPDATA -ceq (Join-Path $Run 'appdata')
    if(-not $isolated){throw 'Driver profile isolation failed'}
    # EnumDesktopWindows returns false/error 0 on a genuinely empty desktop.
    # This hidden driver-owned window gives the parent's oracle a positive control.
    $sentinel=[DirectUpdateUi]::CreateSentinel()
    Save-Receipt 'driver-ready.json' @{ ProcessId=$PID; Desktop=$DesktopName; IsolatedProfile=$isolated }
    $approvalDeadline=[datetime]::UtcNow.AddSeconds(30)
    while(-not (Test-Path -LiteralPath (Join-Path $Run 'driver-approved'))){if([datetime]::UtcNow -ge $approvalDeadline){throw 'Parent desktop approval timed out'}; Start-Sleep -Milliseconds 100}
    $inputs=Get-Content -LiteralPath (Join-Path $Run 'inputs.json') -Raw | ConvertFrom-Json
    $script:install=Join-Path $Run $inputs.SourceRelative
    $target=Join-Path $Run $inputs.TargetRelative
    $exe=Join-Path $script:install 'noctty.exe'
    Set-Content -LiteralPath (Join-Path $script:install 'noctty.portable') -Value '' -NoNewline
    $result.BeforeVersion=Get-Version $exe 'before'
    if($result.BeforeVersion -cne "noctty $FromVersion"){throw 'Wrong source version'}
    $result.BeforeExeSha256=Get-Sha $exe
    Save-Receipt 'before-listing.json' (Get-Listing $script:install)
    if($Expected -ceq 'Stub'){$result.TargetStub=Get-Stub (Join-Path $target 'ghostty-vt.dll')}
    $feed="https://api.github.com/repos/amanthanvi/noctty/releases/tags/v$TargetVersion"
    $class='noctty-update-'+[guid]::NewGuid().ToString('N')
    $env:GHOSTTY_LOG='stderr'
    $line='"{0}" --window-save-state=never --command=cmd.exe --single-instance=false --class={1} --auto-update=download --auto-update-feed-url={2} --confirm-close-surface=false --keybind=f7=check_for_updates' -f $exe,$class,$feed
    $app=[HiddenWin]::Launch($exe,$line,$script:install,"WinSta0\$DesktopName",$script:caseJob,(Join-Path $Run 'app-raw.log'))
    $script:hostWindow=[IntPtr]::Zero
    Wait-Check 'source window' { $windows=@([HiddenWin]::Hosts($app.pid)); if($windows.Count -eq 1){$script:hostWindow=$windows[0];return $true};return $false }
    Wait-Check 'source pane ready' { @([HiddenWin]::Surfaces($script:hostWindow)).Count -eq 1 } ([Math]::Min(60,$TimeoutSeconds))
    $panes=@([HiddenWin]::Surfaces($script:hostWindow))
    # Force the check through the old app's normal binding dispatch.
    [DirectUpdateUi]::CheckKey($panes[0]); $result.Steps.Add('Posted F7 check_for_updates')
    if($Expected -ceq 'Rejected') {
        Wait-Check 'incomplete payload banner' { (Read-ControlName $script:hostWindow 1913) -match 'portable ZIP payload is incomplete' }
        $result.Banner=Read-ControlName $script:hostWindow 1913
        # An error message temporarily covers the underlying update notice.
        [DirectUpdateUi]::Click([DirectUpdateUi]::Child($script:hostWindow,1915))
        Wait-Check 'rejected update notice' { (Read-ControlName $script:hostWindow 1914) -cmatch '^Open Release(?::|$)' }
        $result.NoticeButton=Read-ControlName $script:hostWindow 1914
        if($result.NoticeButton -cnotmatch '^Open Release(?::|$)'){throw 'Rejected update does not offer Open Release'}
        if((Get-Sha $exe) -cne $result.BeforeExeSha256){throw 'Rejected update changed the source executable'}
    } else {
        Wait-Check 'verified portable stage' { $s=Get-UpdateState $script:install; $s -and $s.StagedVersion -ceq $TargetVersion -and $s.StagedKind -ceq 'portable' -and $s.FeedMatches -and (Read-ControlName $script:hostWindow 1914) -cmatch '^Install(?::|$)' }
        $result.Banner=Read-ControlName $script:hostWindow 1913
        $result.NoticeButton=Read-ControlName $script:hostWindow 1914
        [DirectUpdateUi]::Click([DirectUpdateUi]::Child($script:hostWindow,1914)); $result.Steps.Add('Posted Install notification')
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
        Wait-Check 'target confirmed and helper finalized' { $s=Get-UpdateState $script:install; $s -and $null -eq $s.Phase -and $null -eq $s.StagedVersion -and (Get-Sha $exe) -ceq (Get-Sha (Join-Path $target 'noctty.exe')) }
        if($Expected -ceq 'Stub') {
            $result.FinalStub=Get-Stub (Join-Path $script:install 'ghostty-vt.dll')
            if($result.FinalStub.Sha256 -cne $result.TargetStub.Sha256){throw 'Final stub differs from the verified candidate ZIP'}
        } elseif(Test-Path -LiteralPath (Join-Path $script:install 'ghostty-vt.dll')){throw 'Update did not remove the stub'}
    }
    $result.AfterVersion=Get-Version $exe 'after'
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
    $result.NoRollbackObserved=$true; $result.Passed=$true
} catch {
    # Fixed stage names above and error types only; never export arbitrary native errors/logs.
    $result.ErrorType=$_.Exception.GetType().Name
    $result.ErrorStage=if($_.Exception.Message -cmatch '^(Timed out: |Observed |Wrong |Expected |Driver |Parent |Install did not |Old application |Final application |Rejected update |Update did not |Acceptance |Stub |Owned )'){$_.Exception.Message}else{'Driver operation failed; inspect retained local raw evidence'}
    $result.ErrorLine=$_.InvocationInfo.ScriptLineNumber
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
                if($text -match '^(?:info|warning|warn|error)\((?:update|win32)\):.*\b(?:update|portable)\b.*\b(?:check|staged|staging|payload|confirmed|confirmation|rollback|failed|verified|pending|downloaded)\b'){
                    $sanitized=$text -replace '[A-Za-z]:[\\/][^\s,;]+','[path]' -replace '(?i)(token|authorization|secret|password)=[^\s,;]+','$1=[redacted]'
                    $lines.Add($sanitized.Substring(0,[Math]::Min(500,$sanitized.Length)))
                }
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
