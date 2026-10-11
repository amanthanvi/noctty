[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DefaultBinary,
    [Parameter(Mandatory)][string]$OpenGLOnlyBinary,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$Driver,
    [string]$DesktopName,
    [string]$RealProfile
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Native.ps1')
$DefaultBinary=[IO.Path]::GetFullPath($DefaultBinary)
$OpenGLOnlyBinary=[IO.Path]::GetFullPath($OpenGLOnlyBinary)
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if (!$RealProfile) {$RealProfile=Join-Path $env:LOCALAPPDATA 'noctty\startup-attempts.json'}
function Receipt {
    if(Test-Path -LiteralPath $RealProfile){return @{exists=$true;hash=(Get-FileHash -LiteralPath $RealProfile).Hash;mtime=(Get-Item -LiteralPath $RealProfile).LastWriteTimeUtc.ToString('o')}}
    return @{exists=$false}
}
$before=Receipt
function CheckProfile {
    $after=Receipt
    if($after.exists -ne $before.exists -or $after.hash -ne $before.hash -or $after.mtime -ne $before.mtime){throw 'Real startup-attempts.json changed; stop launches.'}
}
if(!$Driver){
    if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a fresh evidence directory.'}
    [void](New-Item -ItemType Directory -Path $OutputDirectory)
    $DesktopName='renderer-test-'+[guid]::NewGuid().ToString('N')
    $desktop=[RendererNative]::CreateDesktopW($DesktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if($desktop -eq [IntPtr]::Zero){throw 'CreateDesktop failed.'}
    $pi=New-Object RendererNative+PI
    try{
        $si=New-Object RendererNative+SI;$si.cb=[Runtime.InteropServices.Marshal]::SizeOf([type][RendererNative+SI]);$si.desktop='WinSta0\'+$DesktopName;$si.flags=1;$si.show=0
        $exe=(Get-Command pwsh).Source
        foreach($p in @($PSCommandPath,$DefaultBinary,$OpenGLOnlyBinary,$OutputDirectory,$RealProfile)){if($p.Contains('"')){throw 'Invalid quote in path.'}}
        $cmd='"'+$exe+'" -NoProfile -File "'+$PSCommandPath+'" -Driver -DefaultBinary "'+$DefaultBinary+'" -OpenGLOnlyBinary "'+$OpenGLOnlyBinary+'" -OutputDirectory "'+$OutputDirectory+'" -RealProfile "'+$RealProfile+'" -DesktopName '+$DesktopName
        if(![RendererNative]::CreateProcessW($exe,[Text.StringBuilder]::new($cmd),[IntPtr]::Zero,[IntPtr]::Zero,$false,0x08004000,[IntPtr]::Zero,$PSScriptRoot,[ref]$si,[ref]$pi)){throw 'Hidden driver failed.'}
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while([RendererNative]::WaitForSingleObject($pi.process,1000) -eq 258){if($timer.Elapsed.TotalMinutes -gt 5){throw "Inspect exact driver PID=$($pi.pid); timed out."}}
        $code=0;[void][RendererNative]::GetExitCodeProcess($pi.process,[ref]$code)
        Get-Content -LiteralPath (Join-Path $OutputDirectory 'result.json')
        if($code -ne 0){throw 'OpenGL scheduling comparison failed.'}
    }finally{
        if($pi.thread -ne [IntPtr]::Zero){[void][RendererNative]::CloseHandle($pi.thread)}
        if($pi.process -ne [IntPtr]::Zero){[void][RendererNative]::CloseHandle($pi.process)}
        [void][RendererNative]::CloseDesktop($desktop);CheckProfile
    }
    return
}
if([RendererNative]::DesktopName() -ne $DesktopName -or !$DesktopName.StartsWith('renderer-test-')){throw 'Driver is not on verified private desktop.'}
(Get-Process -Id $PID).PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
[void][RendererNative]::SetThreadDpiAwarenessContext([IntPtr]-4)
$result=[ordered]@{status='incomplete';profileBefore=$before;desktop=$DesktopName;runs=@()}
function Snapshot([IntPtr]$Window,[string]$Path){
    $reply=[IntPtr]::Zero
    if([RendererNative]::SendMessageTimeoutW($Window,0x8008,[IntPtr]::Zero,[IntPtr]::Zero,2,5000,[ref]$reply) -eq [IntPtr]::Zero){throw 'Trace snapshot timed out.'}
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Case([string]$Name,[string]$Binary){
    CheckProfile
    $run=Join-Path $OutputDirectory $Name;$bin=Join-Path $run 'bin'
    [void](New-Item -ItemType Directory -Path $bin)
    Copy-Item -LiteralPath $Binary -Destination (Join-Path $bin 'noctty.exe')
    $hash=(Get-FileHash -LiteralPath $Binary).Hash
    if((Get-FileHash -LiteralPath (Join-Path $bin 'noctty.exe')).Hash -ne $hash){throw 'Copied executable differs.'}
    Set-Content -LiteralPath (Join-Path $bin 'noctty.portable') -Value 'isolated OpenGL stream/resize comparison'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Fixture.ps1') -Destination $bin
    $share=Join-Path (Split-Path (Split-Path $Binary)) 'share'
    if(Test-Path -LiteralPath $share){Copy-Item -LiteralPath $share -Destination $run -Recurse}
    $command='command=direct:"'+(Get-Command pwsh).Source+'" -NoProfile -File "'+(Join-Path $bin 'Fixture.ps1')+'" -Stream -IntervalMs 1'
    Set-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value @('renderer=opengl','auto-update=off','confirm-close-surface=false','window-save-state=never','single-instance=false','shell-integration=none','window-vsync=false','window-width=96','window-height=28','windows-job-object-kill-on-close=true',$command)
    $envForRun=@{LOCALAPPDATA=(Join-Path $run 'LocalAppData');APPDATA=(Join-Path $run 'AppData');NOCTTY_RENDERER_READY_PATH=(Join-Path $run 'ready.txt');NOCTTY_RENDER_TRACE_FILE=(Join-Path $run 'trace.json');NOCTTY_RENDER_TRACE_LIVE='1'}
    [void](New-Item -ItemType Directory -Path $envForRun.LOCALAPPDATA,$envForRun.APPDATA)
    $proc=$null;$hostWindow=[IntPtr]::Zero
    try{
        $proc=Start-Process -FilePath (Join-Path $bin 'noctty.exe') -WorkingDirectory $bin -WindowStyle Hidden -Environment $envForRun -PassThru -RedirectStandardError (Join-Path $run 'stderr.txt')
        $identity=$proc.StartTime;$timer=[Diagnostics.Stopwatch]::StartNew();$surface=[IntPtr]::Zero
        while($timer.Elapsed.TotalSeconds -lt 40){$proc.Refresh();if($proc.HasExited){throw 'App exited before fixture.'};$hostWindow=[RendererNative]::Host($proc.Id);if($hostWindow -ne [IntPtr]::Zero){[void][RendererNative]::ShowWindow($hostWindow,4);$surface=[RendererNative]::Surface($hostWindow)};if($surface -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $envForRun.NOCTTY_RENDERER_READY_PATH)){break};Start-Sleep -Milliseconds 25}
        if($surface -eq [IntPtr]::Zero){throw 'No fixture surface.'}
        Start-Sleep -Milliseconds 2500
        $initial=Snapshot $surface $envForRun.NOCTTY_RENDER_TRACE_FILE
        $rect=New-Object RendererNative+RECT;[void][RendererNative]::GetWindowRect($hostWindow,[ref]$rect)
        $w=$rect.r-$rect.l;$h=$rect.b-$rect.t;$latencies=@()
        $reply=[IntPtr]::Zero
        [void][RendererNative]::SendMessageTimeoutW($hostWindow,0x0231,[IntPtr]::Zero,[IntPtr]::Zero,2,5000,[ref]$reply)
        for($i=0;$i -lt 80;$i++){
            $clock=[Diagnostics.Stopwatch]::StartNew()
            if(![RendererNative]::Resize($hostWindow,$w-($i%2)*90,$h-($i%2)*50)){throw 'Resize failed.'}
            $sample=Snapshot $surface $envForRun.NOCTTY_RENDER_TRACE_FILE
            $latencies+=$clock.Elapsed.TotalMilliseconds
            Start-Sleep -Milliseconds 20
        }
        [void][RendererNative]::SendMessageTimeoutW($hostWindow,0x0232,[IntPtr]::Zero,[IntPtr]::Zero,2,5000,[ref]$reply)
        [void][RendererNative]::Resize($hostWindow,$w,$h)
        Start-Sleep -Milliseconds 350
        $final=Snapshot $surface $envForRun.NOCTTY_RENDER_TRACE_FILE
        $sorted=@($latencies | Sort-Object)
        $record=@{label=$Name;binarySHA256=$hash;resizeSamples=$latencies.Count;resizeAndSnapshotP50Ms=[math]::Round($sorted[40],2);resizeAndSnapshotP95Ms=[math]::Round($sorted[76],2);resizeAndSnapshotMaxMs=[math]::Round($sorted[-1],2);frameUpdates=([uint64]$final.renderer_update_frame_count-[uint64]$initial.renderer_update_frame_count);swapBuffers=([uint64]$final.swap_buffers_count-[uint64]$initial.swap_buffers_count);presentedOutputBytes=([uint64]$final.last_swap_process_output_bytes-[uint64]$initial.last_swap_process_output_bytes)}
        if($record.frameUpdates -lt 1 -or $record.presentedOutputBytes -lt 1000){throw 'Streaming stopped during resize.'}
        return $record
    }finally{
        if($proc){$proc.Refresh();if(!$proc.HasExited){[void][RendererNative]::PostMessageW($hostWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);[void]$proc.WaitForExit(5000)};if(!$proc.HasExited){$live=Get-Process -Id $proc.Id;if($live.StartTime -ne $identity -or $live.Path -ne (Join-Path $bin 'noctty.exe')){throw 'Process identity changed.'};Stop-Process -Id $proc.Id;throw 'Graceful teardown failed.'}}
        CheckProfile
    }
}
try{$result.runs+=Case 'default' $DefaultBinary;$result.runs+=Case 'opengl-only' $OpenGLOnlyBinary;$result.status='pass'}catch{$result.failure=$_.Exception.Message}
finally{CheckProfile;$result.profileAfter=Receipt;$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json')}
if($result.status -ne 'pass'){exit 1}
