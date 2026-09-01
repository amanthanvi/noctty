function Get-InteractiveWin11NormalizedPath {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $full = [System.IO.Path]::GetFullPath($Path).Replace('/', '\')
    $root = [System.IO.Path]::GetPathRoot($full).Replace('/', '\')

    if ($full.Length -gt $root.Length) {
        return $full.TrimEnd('\')
    }

    return $full
}

function Get-InteractiveWin11WorktreeId {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    $normalized = Get-InteractiveWin11NormalizedPath -Path $RepoRoot
    $leaf = Split-Path -Path $normalized -Leaf
    $parentLeaf = Split-Path -Path (Split-Path -Path $normalized -Parent) -Leaf
    $slugSource = "$parentLeaf-$leaf".ToLowerInvariant()
    $slug = ($slugSource -replace '[^a-z0-9.-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'worktree'
    }
    if ($slug.Length -gt 32) {
        $slug = $slug.Substring(0, 32).TrimEnd('-')
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized.ToLowerInvariant())
        $hash = [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    return '{0}-{1}' -f $slug, $hash.Substring(0, 12)
}

function Get-InteractiveWin11SandboxName {
    param(
        [string] $SandboxName = 'default'
    )

    $value = $SandboxName.Trim().ToLowerInvariant()
    $slug = ($value -replace '[^a-z0-9.-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'default'
    }
    if ($slug.Length -gt 24) {
        $slug = $slug.Substring(0, 24).TrimEnd('-')
    }

    return $slug
}

function Get-InteractiveWin11SandboxLayout {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $SandboxName = 'default'
    )

    $normalizedRepoRoot = Get-InteractiveWin11NormalizedPath -Path $RepoRoot
    $worktreeId = Get-InteractiveWin11WorktreeId -RepoRoot $normalizedRepoRoot
    $sandboxSlug = Get-InteractiveWin11SandboxName -SandboxName $SandboxName
    $sandboxId = '{0}-{1}' -f $worktreeId, $sandboxSlug
    $sandboxRoot = Join-Path $normalizedRepoRoot ".sandbox\win11\$worktreeId\$sandboxSlug"
    $localAppData = Join-Path $sandboxRoot 'localappdata'

    return [ordered]@{
        RepoRoot      = $normalizedRepoRoot
        WorktreeId    = $worktreeId
        SandboxName   = $sandboxSlug
        SandboxId     = $sandboxId
        SandboxRoot   = $sandboxRoot
        AppData       = Join-Path $sandboxRoot 'appdata'
        LocalAppData  = $localAppData
        XdgConfigHome = $localAppData
        XdgCacheHome  = Join-Path $sandboxRoot 'cache'
        XdgStateHome  = Join-Path $sandboxRoot 'state'
        Temp          = Join-Path $sandboxRoot 'temp'
        Logs          = Join-Path $sandboxRoot 'logs'
    }
}

function New-InteractiveWin11Sandbox {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    foreach ($path in @(
        $Layout.SandboxRoot,
        $Layout.AppData,
        $Layout.LocalAppData,
        $Layout.XdgCacheHome,
        $Layout.XdgStateHome,
        $Layout.Temp,
        $Layout.Logs
    )) {
        New-Item -ItemType Directory -Force -Path $path -ErrorAction Stop | Out-Null
    }
}

function Get-InteractiveWin11Environment {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    return [ordered]@{
        APPDATA         = $Layout.AppData
        LOCALAPPDATA    = $Layout.LocalAppData
        XDG_CONFIG_HOME = $Layout.XdgConfigHome
        XDG_CACHE_HOME  = $Layout.XdgCacheHome
        XDG_STATE_HOME  = $Layout.XdgStateHome
        TEMP            = $Layout.Temp
        TMP             = $Layout.Temp
    }
}

if (-not ('InteractiveWin11MessageNativeV2' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class InteractiveWin11MessageNativeV2 {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    public static uint GetWindowThreadProcessIdWithError(IntPtr hwnd, out uint processId, out int lastError) {
        SetLastError(0);
        uint result = GetWindowThreadProcessId(hwnd, out processId);
        lastError = Marshal.GetLastWin32Error();
        return result;
    }
    [DllImport("kernel32.dll")] private static extern void SetLastError(uint errorCode);

    public static IntPtr SendMessageTimeoutWithError(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result, out int lastError) {
        SetLastError(0);
        IntPtr status = SendMessageTimeoutW(hwnd, message, wparam, lparam, flags, timeout, out result);
        lastError = Marshal.GetLastWin32Error();
        return status;
    }
    public static bool PostMessageWithError(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, out int lastError) {
        SetLastError(0);
        bool status = PostMessageW(hwnd, message, wparam, lparam);
        lastError = Marshal.GetLastWin32Error();
        return status;
    }
}
'@
}

$script:InteractiveWin11SmtoNormal = [uint32]0
$script:InteractiveWin11SmtoBlock = [uint32]0x0001
$script:InteractiveWin11ErrorSuccess = 0
$script:InteractiveWin11ErrorInvalidWindowHandle = 1400
$script:InteractiveWin11ErrorTimeout = 1460

function Get-InteractiveWin11MessageTimeoutMs {
    param(
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [string] $Description
    )

    $remainingMs = ($Deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($remainingMs -le 0) {
        throw "Deadline elapsed before sending $Description."
    }

    return [uint32][Math]::Min([double][uint32]::MaxValue, [Math]::Ceiling($remainingMs))
}

function Assert-InteractiveWin11WindowOwner {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [ValidateSet('send', 'post')] [string] $Verb,
        [int[]] $ToleratedErrors = @(),
        [ref] $ObservedToleratedError
    )

    $windowProcessId = [uint32]0
    $windowLastError = 0
    $windowThreadId = [InteractiveWin11MessageNativeV2]::GetWindowThreadProcessIdWithError($Hwnd, [ref] $windowProcessId, [ref] $windowLastError)
    if ($windowThreadId -eq 0) {
        if ($windowLastError -in $ToleratedErrors) {
            if ($null -eq $ObservedToleratedError) { throw 'ToleratedErrors requires an ObservedToleratedError output reference.' }
            $ObservedToleratedError.Value = $windowLastError
            Write-Warning "GetWindowThreadProcessId returned tolerated Win32 error $windowLastError for $Description hwnd=$Hwnd."
            return $false
        }
        $detail = if ($windowLastError -eq 0) { 'without a Win32 error' } else { "with Win32 error $windowLastError" }
        throw "Refusing to $Verb $Description to invalid hwnd=$Hwnd $detail."
    }
    if ($windowProcessId -ne [uint32]$Process.Id) {
        throw "Refusing to $Verb $Description to hwnd=$Hwnd because owner pid=$windowProcessId does not match expected pid=$($Process.Id)."
    }

    return $true
}

function Invoke-InteractiveWin11Message {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint32] $Message,
        [UIntPtr] $WParam = [UIntPtr]::Zero,
        [IntPtr] $LParam = [IntPtr]::Zero,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [string] $Description,
        [uint32] $Flags = $script:InteractiveWin11SmtoNormal,
        [int[]] $ToleratedErrors = @(),
        [ref] $ObservedToleratedError,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    if ($ToleratedErrors.Count -gt 0) {
        if ($null -eq $ObservedToleratedError) { throw 'ToleratedErrors requires an ObservedToleratedError output reference.' }
        $ObservedToleratedError.Value = 0
    }

    $Process.Refresh()
    if ($Process.HasExited) {
        throw "Refusing to send $Description because noctty already exited (exit code $($Process.ExitCode))."
    }

    $sendTimeoutMs = Get-InteractiveWin11MessageTimeoutMs -Deadline $Deadline -Description "$Description hwnd=$Hwnd"
    # Keep ownership validation immediately adjacent to the send so lengthy
    # phase work cannot turn a stale HWND into a cross-process message.
    $ownershipArgs = @{
        Hwnd = $Hwnd
        Process = $Process
        Description = $Description
        Verb = 'send'
        ToleratedErrors = $ToleratedErrors
    }
    if ($null -ne $ObservedToleratedError) {
        $ownershipArgs.ObservedToleratedError = $ObservedToleratedError
    }
    if (-not (Assert-InteractiveWin11WindowOwner @ownershipArgs)) {
        return [UIntPtr]::Zero
    }

    $sendResult = [UIntPtr]::Zero
    $lastError = 0
    $sendStatus = [InteractiveWin11MessageNativeV2]::SendMessageTimeoutWithError(
        $Hwnd,
        $Message,
        $WParam,
        $LParam,
        $Flags,
        $sendTimeoutMs,
        [ref] $sendResult,
        [ref] $lastError
    )
    if ($sendStatus -eq [IntPtr]::Zero) {
        if ($lastError -eq $script:InteractiveWin11ErrorTimeout) {
            throw "SendMessageTimeoutW timed out for $Description hwnd=$Hwnd error=$lastError"
        }
        if ($lastError -in $ToleratedErrors) {
            $ObservedToleratedError.Value = $lastError
            Write-Warning "SendMessageTimeoutW returned tolerated Win32 error $lastError for $Description hwnd=$Hwnd."
            return $sendResult
        }
        $detail = if ($lastError -eq $script:InteractiveWin11ErrorSuccess) { 'generic failure without a Win32 error' } else { "Win32 error $lastError" }
        throw "SendMessageTimeoutW failed for $Description hwnd=$Hwnd ($detail)."
    }

    return $sendResult
}

function Invoke-InteractiveWin11PostMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint32] $Message,
        [UIntPtr] $WParam = [UIntPtr]::Zero,
        [IntPtr] $LParam = [IntPtr]::Zero,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    $Process.Refresh()
    if ($Process.HasExited) {
        throw "Refusing to post $Description because noctty already exited (exit code $($Process.ExitCode))."
    }

    [void](Assert-InteractiveWin11WindowOwner -Hwnd $Hwnd -Process $Process -Description $Description -Verb 'post')
    $lastError = 0
    if ($Deadline -le [DateTime]::UtcNow) { throw "Timed out waiting for $Description." }
    if (-not [InteractiveWin11MessageNativeV2]::PostMessageWithError($Hwnd, $Message, $WParam, $LParam, [ref] $lastError)) {
        $detail = if ($lastError -eq 0) { 'without a Win32 error' } else { "with Win32 error $lastError" }
        throw "PostMessageW failed for $Description hwnd=$Hwnd $detail."
    }
}

function Get-InteractiveWin11ContainmentArguments {
    return @(
        '--linux-cgroup=always'
        '--linux-cgroup-hard-fail=true'
        '--windows-job-object-kill-on-close=true'
    )
}

function Get-InteractiveWin11LaunchArguments {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    return @(
        Get-InteractiveWin11ContainmentArguments
        '--single-instance=false'
        "--class=noctty-interactive-$($Layout.SandboxId)"
    )
}

function Invoke-InteractiveWin11Bootstrap {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $LauncherPath,
        [Parameter(Mandatory)] [string] $EnvironmentVariable,
        [string[]] $ArgumentList = @(),
        [System.Management.Automation.PSReference] $ExitCode
    )

    $bootstrapCmd = Join-Path $RepoRoot 'scripts\dev-windows.cmd'
    $childExitCode = 0
    [System.Environment]::SetEnvironmentVariable($EnvironmentVariable, '1', 'Process')

    Push-Location $RepoRoot
    try {
        & $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $LauncherPath @ArgumentList
        if ($null -ne $LASTEXITCODE) {
            $childExitCode = $LASTEXITCODE
        }
    }
    finally {
        Pop-Location
        [System.Environment]::SetEnvironmentVariable(
            $EnvironmentVariable,
            $null,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    if ($null -ne $ExitCode) {
        $ExitCode.Value = $childExitCode
    }
}

function Invoke-InteractiveWin11HarnessMain {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $LauncherPath,
        [Parameter(Mandatory)] [string] $EnvironmentVariable,
        [string[]] $ArgumentList = @()
    )

    $bootstrapSentinel = [System.Environment]::GetEnvironmentVariable(
        $EnvironmentVariable,
        [System.EnvironmentVariableTarget]::Process
    )
    if (-not [string]::IsNullOrEmpty($bootstrapSentinel)) {
        return
    }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $RepoRoot `
        -LauncherPath $LauncherPath `
        -EnvironmentVariable $EnvironmentVariable `
        -ArgumentList $ArgumentList `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

function Set-InteractiveWin11Environment {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout,
        [switch] $IncludeResourcesDir
    )

    $sandboxEnv = Get-InteractiveWin11Environment -Layout $Layout
    foreach ($entry in $sandboxEnv.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable([string] $entry.Key, [string] $entry.Value, 'Process')
    }

    if ($IncludeResourcesDir) {
        $builtResourcesDir = Join-Path $Layout.RepoRoot 'zig-out\share\ghostty'
        $resourcesDir = if (Test-Path -LiteralPath $builtResourcesDir -PathType Container) {
            $builtResourcesDir
        }
        else {
            Join-Path $Layout.RepoRoot 'src'
        }
        [System.Environment]::SetEnvironmentVariable(
            'GHOSTTY_RESOURCES_DIR',
            $resourcesDir,
            'Process'
        )
    }
    else {
        [System.Environment]::SetEnvironmentVariable(
            'GHOSTTY_RESOURCES_DIR',
            $null,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    return $sandboxEnv
}

function Initialize-InteractiveWin11Sandbox {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $SandboxName = 'default',
        [switch] $ResetState,
        [switch] $IncludeResourcesDir
    )

    $normalizedRepoRoot = Get-InteractiveWin11NormalizedPath -Path $RepoRoot
    $layout = Get-InteractiveWin11SandboxLayout -RepoRoot $normalizedRepoRoot -SandboxName $SandboxName

    if ($ResetState) {
        Reset-InteractiveWin11Sandbox -Layout $layout
    }

    New-InteractiveWin11Sandbox -Layout $layout
    $sandboxEnv = Set-InteractiveWin11Environment -Layout $layout -IncludeResourcesDir:$IncludeResourcesDir

    return [ordered]@{
        RepoRoot    = $normalizedRepoRoot
        Layout      = $layout
        Environment = $sandboxEnv
    }
}

function Get-InteractiveWin11DefaultBuildInputs {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    return @(
        (Join-Path $RepoRoot 'build.zig'),
        (Join-Path $RepoRoot 'build.zig.zon'),
        (Join-Path $RepoRoot 'src')
    )
}

function Get-InteractiveWin11ExePath {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    return Get-InteractiveWin11NormalizedPath -Path (Join-Path $RepoRoot 'zig-out\bin\noctty.exe')
}

function Invoke-InteractiveWin11Build {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')] [string] $Optimize
    )

    $devWindowsCmd = Join-Path $RepoRoot 'scripts\dev-windows.cmd'
    $repoSandboxRoot = Get-InteractiveWin11NormalizedPath -Path (Join-Path $RepoRoot '.sandbox\win11')
    $savedLocalAppData = $env:LOCALAPPDATA
    $restoreLocalAppData = $false
    if (-not [string]::IsNullOrWhiteSpace($savedLocalAppData)) {
        $normalizedLocalAppData = Get-InteractiveWin11NormalizedPath -Path $savedLocalAppData
        $sandboxPrefix = '{0}\' -f $repoSandboxRoot
        if (
            $normalizedLocalAppData.Equals($repoSandboxRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedLocalAppData.StartsWith($sandboxPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $hostLocalAppData = [System.Environment]::GetFolderPath(
                [System.Environment+SpecialFolder]::LocalApplicationData
            )
            if ([string]::IsNullOrWhiteSpace($hostLocalAppData)) {
                $userProfilePath = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                    [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
                }
                else {
                    $env:USERPROFILE
                }

                if (-not [string]::IsNullOrWhiteSpace($userProfilePath)) {
                    $hostLocalAppData = Join-Path $userProfilePath 'AppData\Local'
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($hostLocalAppData)) {
                $env:LOCALAPPDATA = Get-InteractiveWin11NormalizedPath -Path $hostLocalAppData
                $restoreLocalAppData = $true
            }
        }
    }

    Push-Location $RepoRoot
    try {
        $optimizeArguments = @()
        if (-not [string]::IsNullOrWhiteSpace($Optimize)) {
            $optimizeArguments += "-Doptimize=$Optimize"
        }
        & cmd /c $devWindowsCmd zig build -Demit-exe=true @optimizeArguments
        if ($LASTEXITCODE -ne 0) {
            $buildDescription = @('zig', 'build', '-Demit-exe=true') + $optimizeArguments
            throw "$($buildDescription -join ' ') failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
        if ($restoreLocalAppData) {
            $env:LOCALAPPDATA = $savedLocalAppData
        }
    }
}

function Assert-InteractiveWin11ExeExists {
    param(
        [Parameter(Mandatory)] [string] $ExePath
    )

    if (-not [System.IO.File]::Exists($ExePath)) {
        throw "Missing noctty.exe at $ExePath"
    }
}

function Get-InteractiveWin11TextFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Default = ''
    )

    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw
    }

    return $Default
}

function Get-InteractiveWin11TextFileTail {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $LineCount = 40,
        [string] $Default = '<stderr log missing>'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Default
    }

    return (Get-Content -LiteralPath $Path | Select-Object -Last $LineCount) -join [Environment]::NewLine
}

function Get-InteractiveWin11RequiredJsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing expected trace/state file: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Show-InteractiveWin11Window {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [type] $NativeType,
        [int] $ShowCode = 9,
        [switch] $SetForeground
    )

    [void] $NativeType::ShowWindow($Hwnd, $ShowCode)
    if ($SetForeground) {
        [void] $NativeType::SetForegroundWindow($Hwnd)
    }
}

function Show-InteractiveWin11ProcessMainWindow {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [type] $NativeType,
        [int] $ShowCode = 9,
        [switch] $SetForeground,
        [int] $ReadyTimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            Show-InteractiveWin11Window `
                -Hwnd $Process.MainWindowHandle `
                -NativeType $NativeType `
                -ShowCode $ShowCode `
                -SetForeground:$SetForeground
            return
        }

        if ($Process.HasExited) {
            return
        }

        Start-Sleep -Milliseconds 100
    }
}

function Wait-InteractiveWin11Until {
    param(
        [Parameter(Mandatory)] [scriptblock] $Condition,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Alias('Process')] [System.Diagnostics.Process] $WatchProcess,
        [ValidateRange(1, [int]::MaxValue)] [int] $PollMilliseconds = 100,
        [string] $TimeoutMessage,
        [switch] $ConditionFirst
    )

    if ($ConditionFirst) {
        while ($true) {
            if ($null -ne $WatchProcess -and $WatchProcess.HasExited) {
                throw "noctty exited while waiting for ${Description} (exit code $($WatchProcess.ExitCode))"
            }

            if (& $Condition) {
                return
            }

            Start-Sleep -Milliseconds $PollMilliseconds
            if ([DateTime]::UtcNow -ge $Deadline) {
                break
            }
        }
    }
    else {
    while ($true) {
        if ($null -ne $WatchProcess -and $WatchProcess.HasExited) {
            throw "noctty exited while waiting for ${Description} (exit code $($WatchProcess.ExitCode))"
        }

        if ([DateTime]::UtcNow -ge $Deadline) {
            break
        }

        if (& $Condition) {
            return
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
    }

    if ([string]::IsNullOrEmpty($TimeoutMessage)) {
        throw "Timed out waiting for $Description"
    }
    throw $TimeoutMessage
}

function Get-InteractiveWin11ProcessTreeSnapshot {
    param(
        [Parameter(Mandatory)] [int] $RootProcessId,
        [Parameter(Mandatory)] [datetime] $RootStartedAt
    )

    $processes = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
    if ($processes.Count -eq 0) {
        throw 'Win32_Process returned no processes while snapshotting interactive cleanup.'
    }

    $processById = @{}
    $childrenByParent = @{}
    foreach ($process in $processes) {
        $processId = [int]$process.ProcessId
        $parentProcessId = [int]$process.ParentProcessId
        $processById[$processId] = $process
        if (-not $childrenByParent.ContainsKey($parentProcessId)) {
            $childrenByParent[$parentProcessId] = [Collections.Generic.List[object]]::new()
        }
        [void]$childrenByParent[$parentProcessId].Add($process)
    }
    if (-not $processById.ContainsKey($RootProcessId)) {
        throw "Interactive Win11 root process $RootProcessId was absent from the process-table snapshot."
    }
    $observedRootStartedAt = ([datetime]$processById[$RootProcessId].CreationDate).ToUniversalTime()
    $expectedRootStartedAt = $RootStartedAt.ToUniversalTime()
    if ([math]::Abs(($observedRootStartedAt - $expectedRootStartedAt).TotalMilliseconds) -gt 10) {
        throw "Interactive Win11 root process $RootProcessId identity changed before process-tree cleanup."
    }

    $snapshot = [Collections.Generic.List[object]]::new()
    $queue = [Collections.Generic.Queue[int]]::new()
    $seen = [Collections.Generic.HashSet[int]]::new()
    $queue.Enqueue($RootProcessId)
    [void]$seen.Add($RootProcessId)

    while ($queue.Count -gt 0) {
        $processId = $queue.Dequeue()
        $process = $processById[$processId]
        $processStartedAt = ([datetime]$process.CreationDate).ToUniversalTime()
        [void]$snapshot.Add([pscustomobject]@{
            ProcessId    = [int]$process.ProcessId
            CreationDate = $processStartedAt
        })
        if ($childrenByParent.ContainsKey($processId)) {
            foreach ($child in $childrenByParent[$processId]) {
                $childProcessId = [int]$child.ProcessId
                $childStartedAt = ([datetime]$child.CreationDate).ToUniversalTime()
                if ($childStartedAt -lt $processStartedAt) {
                    continue
                }
                if ($seen.Add($childProcessId)) {
                    $queue.Enqueue($childProcessId)
                }
            }
        }
    }

    return @($snapshot)
}

function Test-InteractiveWin11ProcessTreeSnapshotExited {
    param(
        [Parameter(Mandatory)] [object[]] $Snapshot,
        [ValidateRange(1, 5)] [uint32] $OperationTimeoutSec = 5
    )

    if ($Snapshot.Count -eq 0) {
        throw 'Interactive Win11 process-tree verification requires a non-empty snapshot.'
    }

    $processes = @(Get-CimInstance `
            -ClassName Win32_Process `
            -OperationTimeoutSec $OperationTimeoutSec `
            -ErrorAction Stop)
    if ($processes.Count -eq 0) {
        throw 'Win32_Process returned no processes while verifying interactive cleanup.'
    }

    $liveById = @{}
    foreach ($process in $processes) {
        $liveById[[int]$process.ProcessId] = $process
    }

    $capturedProcessIds = [Collections.Generic.HashSet[int]]::new()
    $capturedStartedAtById = @{}
    foreach ($entry in $Snapshot) {
        $processId = [int]$entry.ProcessId
        [void]$capturedProcessIds.Add($processId)
        $capturedStartedAtById[$processId] = ([datetime]$entry.CreationDate).ToUniversalTime()
        $live = $liveById[$processId]
        if ($null -ne $live -and
            ([datetime]$live.CreationDate).ToUniversalTime().Ticks -eq
            ([datetime]$entry.CreationDate).ToUniversalTime().Ticks) {
            return $false
        }
    }

    # Fail closed if a child appeared after the last snapshot. ParentProcessId
    # remains useful after its parent exits; compare against the captured parent
    # identity so stale children from reused PIDs do not poison cleanup.
    foreach ($process in $processes) {
        $parentProcessId = [int]$process.ParentProcessId
        if ($capturedProcessIds.Contains($parentProcessId) -and
            ([datetime]$process.CreationDate).ToUniversalTime() -ge $capturedStartedAtById[$parentProcessId]) {
            return $false
        }
    }

    return $true
}

function Stop-InteractiveWin11RootHandle {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [IntPtr] $RootProcessHandle,
        [Parameter(Mandatory)] [datetime] $RootStartedAt
    )

    try {
        $Process.Refresh()
        if ($Process.HasExited -or $Process.StartTime -ne $RootStartedAt) {
            return
        }
    }
    catch [System.InvalidOperationException] {
        return
    }

    Initialize-InteractiveWin11ProcessNative
    $terminationRequested = [InteractiveWin11ProcessNative]::TerminateProcess($RootProcessHandle, 1)
    $terminationError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    # TerminateProcess is asynchronous. High Contrast and other system-wide UI
    # transitions can keep teardown pending beyond the ordinary five-second
    # harness cadence, so retain a bounded but transition-tolerant exit wait.
    $waitResult = [InteractiveWin11ProcessNative]::WaitForSingleObject($RootProcessHandle, 15000)
    if (-not $terminationRequested -and $waitResult -ne 0) {
        throw "root handle termination failed with Win32 error $terminationError; the root remained live after 15 seconds"
    }
    if ($waitResult -eq 258) {
        throw 'root handle termination did not stop the process within 15 seconds'
    }
    if ($waitResult -eq [uint32]::MaxValue) {
        $waitError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "root handle exit wait failed with Win32 error $waitError"
    }
    if ($waitResult -ne 0) {
        throw "root handle exit wait returned unexpected status $waitResult"
    }
}

function Wait-InteractiveWin11ProcessTreeSnapshotExited {
    param(
        [Parameter(Mandatory)] [object[]] $Snapshot,
        [ValidateRange(1, 30)] [uint32] $TimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $remainingSeconds = ($deadline - [DateTime]::UtcNow).TotalSeconds
        if ($remainingSeconds -le 0) {
            return $false
        }
        $operationTimeoutSec = [uint32][math]::Max(1, [math]::Min(5, [math]::Ceiling($remainingSeconds)))
        if (Test-InteractiveWin11ProcessTreeSnapshotExited `
                -Snapshot $Snapshot `
                -OperationTimeoutSec $operationTimeoutSec) {
            return $true
        }
        $remainingMilliseconds = [math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMilliseconds -gt 0) {
            Start-Sleep -Milliseconds ([int][math]::Min(100, $remainingMilliseconds))
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Stop-InteractiveWin11Process {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [switch] $RequireLiveRoot,
        [switch] $Contained,
        [switch] $AllowAlreadyExited
    )

    $lifecycleModeCount = @($RequireLiveRoot, $Contained, $AllowAlreadyExited).Where({ $_.IsPresent }).Count
    if ($lifecycleModeCount -gt 1) {
        throw 'RequireLiveRoot, Contained, and AllowAlreadyExited are mutually exclusive.'
    }

    $rootProcessId = $Process.Id
    $rootProcessHandle = [IntPtr]::Zero
    $rootStartedAt = $null
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $rootProcessHandle = $Process.Handle
            $rootStartedAt = $Process.StartTime
        }
    }
    catch [System.InvalidOperationException] {
        # The root exited while its handle identity was being captured.
    }
    if ($null -eq $rootStartedAt) {
        if ($RequireLiveRoot) {
            throw "Interactive Win11 process $rootProcessId exited before its process tree could be verified."
        }
        if ($Contained) {
            # The terminated host owned every terminal-child Job handle, so its
            # exit closed those jobs and killed their contained descendants.
            return
        }
        if ($AllowAlreadyExited) {
            # This is reserved for short-lived, uncontained probes that cannot
            # create persistent descendants and are expected to exit normally.
            return
        }
        throw "Uncontained interactive Win11 process $rootProcessId exited before its process tree could be verified."
    }

    $processTreeSnapshot = @()
    $snapshotError = $null
    try {
        $processTreeSnapshot = @(Get-InteractiveWin11ProcessTreeSnapshot `
                -RootProcessId $rootProcessId `
                -RootStartedAt $rootStartedAt)
    }
    catch {
        $snapshotError = $_.Exception.Message
    }

    $taskkillError = $null
    $taskkillCleanupError = $null
    if (-not $Contained) {
        # Keep RootProcessHandle open through taskkill. Windows cannot reuse a
        # process ID until all handles to that process object are closed, so
        # the numeric tree-kill target remains bound to the captured identity.
        $taskkill = $null
        try {
            $Process.Refresh()
            if (-not $Process.HasExited -and $Process.StartTime -eq $rootStartedAt) {
                $taskkillStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
                $taskkillStartInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
                $taskkillStartInfo.UseShellExecute = $false
                $taskkillStartInfo.CreateNoWindow = $true
                $taskkillStartInfo.Arguments = "/PID $rootProcessId /T /F"
                $taskkill = [System.Diagnostics.Process]::Start($taskkillStartInfo)
                if (-not $taskkill.WaitForExit(10000)) {
                    try {
                        $taskkill.Kill()
                        if (-not $taskkill.WaitForExit(5000)) {
                            $taskkillCleanupError = 'taskkill could not be stopped within 5 seconds'
                        }
                        else {
                            $taskkillError = 'taskkill exceeded 10 seconds'
                        }
                    }
                    catch {
                        $taskkillCleanupError = "taskkill could not be stopped: $($_.Exception.Message)"
                    }
                }
                elseif ($taskkill.ExitCode -ne 0) {
                    $taskkillError = "taskkill exited with code $($taskkill.ExitCode)"
                }
            }
        }
        catch {
            $taskkillError = $_.Exception.Message
        }
        finally {
            if ($null -ne $taskkill) { $taskkill.Dispose() }
        }
    }

    $terminationError = $null
    try {
        Stop-InteractiveWin11RootHandle `
            -Process $Process `
            -RootProcessHandle $rootProcessHandle `
            -RootStartedAt $rootStartedAt
    }
    catch {
        $terminationError = $_.Exception.Message
    }

    if ($null -ne $terminationError) {
        throw "Failed to clean interactive Win11 process tree $rootProcessId (taskkill='$taskkillError', root='$terminationError')."
    }
    if ($null -ne $taskkillCleanupError) {
        throw "Failed to reap taskkill while cleaning interactive Win11 process tree $rootProcessId`: $taskkillCleanupError"
    }
    if ($Contained -and $null -ne $snapshotError) {
        if ($VerbosePreference -eq 'Continue') {
            Write-Verbose "Contained interactive Win11 process $rootProcessId cleanup skipped CIM verification: $snapshotError"
        }
        return
    }
    if ($AllowAlreadyExited -and $null -ne $snapshotError) {
        if ($VerbosePreference -eq 'Continue') {
            Write-Verbose "Already-exited interactive Win11 process $rootProcessId cleanup skipped process-tree verification: $snapshotError"
        }
        return
    }
    if ($null -ne $snapshotError) {
        throw "Failed to verify uncontained interactive Win11 process tree $rootProcessId after termination: $snapshotError"
    }

    $verificationError = $null
    $processTreeExited = $false
    try {
        $processTreeExited = Wait-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $processTreeSnapshot
    }
    catch {
        $verificationError = $_.Exception.Message
    }
    if ($null -ne $verificationError) {
        if ($Contained) {
            if ($VerbosePreference -eq 'Continue') {
                Write-Verbose "Contained interactive Win11 process $rootProcessId cleanup could not query post-exit process state: $verificationError"
            }
            return
        }
        throw "Failed to verify cleanup of interactive Win11 process tree $rootProcessId after root termination: $verificationError"
    }
    if (-not $processTreeExited) {
        throw "Failed to verify cleanup of interactive Win11 process tree $rootProcessId after root termination: captured descendants remained live"
    }
    if ($null -ne $taskkillError -and $VerbosePreference -eq 'Continue') {
        Write-Verbose "Uncontained process tree $rootProcessId required root fallback after taskkill: $taskkillError"
    }
}

function Test-InteractiveWin11InputNewerThanBinary {
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        [string[]] $BuildInputs = @()
    )

    $resolvedExePath = Get-InteractiveWin11NormalizedPath -Path $ExePath
    if (-not [System.IO.File]::Exists($resolvedExePath)) {
        return $true
    }

    $exeTimestamp = [System.IO.File]::GetLastWriteTimeUtc($resolvedExePath)
    foreach ($inputPath in $BuildInputs) {
        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            continue
        }

        $resolvedInputPath = Get-InteractiveWin11NormalizedPath -Path $inputPath
        if ([System.IO.File]::Exists($resolvedInputPath)) {
            if ([System.IO.File]::GetLastWriteTimeUtc($resolvedInputPath) -gt $exeTimestamp) {
                return $true
            }
            continue
        }

        if (-not (Test-Path -LiteralPath $resolvedInputPath -PathType Container)) {
            continue
        }

        $newerInput = @(
            Get-Item -LiteralPath $resolvedInputPath -ErrorAction Stop
            Get-ChildItem -LiteralPath $resolvedInputPath -Recurse -Force -ErrorAction Stop
        ) |
            Where-Object { $_.LastWriteTimeUtc -gt $exeTimestamp } |
            Select-Object -First 1
        if ($null -ne $newerInput) {
            return $true
        }
    }

    return $false
}

function Get-InteractiveWin11LaunchAction {
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        [string[]] $BuildInputs = @(),
        [switch] $Rebuild,
        [switch] $NoBuild
    )

    $resolvedExePath = Get-InteractiveWin11NormalizedPath -Path $ExePath
    if ($Rebuild -and $NoBuild) {
        throw 'Cannot use -Rebuild with -NoBuild together.'
    }

    if ($Rebuild) {
        return 'build'
    }

    if ([System.IO.File]::Exists($resolvedExePath)) {
        if (Test-InteractiveWin11InputNewerThanBinary -ExePath $resolvedExePath -BuildInputs $BuildInputs) {
            if ($NoBuild) {
                throw "noctty.exe at $resolvedExePath is older than the requested build inputs; rerun without -NoBuild or pass -Rebuild."
            }
            return 'build'
        }
        return 'launch'
    }

    if ($NoBuild) {
        throw "Missing noctty.exe at $resolvedExePath"
    }

    return 'build'
}

function Initialize-InteractiveWin11ProcessNative {
    if (-not ('InteractiveWin11ProcessNative' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class InteractiveWin11ProcessNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
}
"@
    }
}

function Get-InteractiveWin11ProcessExitCode {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [IntPtr] $ProcessHandle
    )

    Initialize-InteractiveWin11ProcessNative

    try {
        $Process.Refresh()
        if ($Process.HasExited) {
            $managedExitCode = $Process.ExitCode
            # PowerShell can surface a blank ExitCode for an exited GUI child;
            # retain the native handle fallback for that adapter edge case.
            if ($null -ne $managedExitCode) { return [int] $managedExitCode }
        }
    }
    catch {
        Write-Verbose "Managed exit-code fast path failed for pid=$($Process.Id); falling back to native GetExitCodeProcess: $($_.Exception.Message)"
    }

    [uint32] $nativeExitCode = 0
    if (-not [InteractiveWin11ProcessNative]::GetExitCodeProcess($ProcessHandle, [ref] $nativeExitCode)) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Exit code could not be read for pid=$($Process.Id): $lastError"
    }

    $Process.Refresh()
    if ($nativeExitCode -eq 259) {
        if (-not $Process.HasExited) {
            throw "Process has not exited yet for pid=$($Process.Id)"
        }

        if (-not [InteractiveWin11ProcessNative]::GetExitCodeProcess($ProcessHandle, [ref] $nativeExitCode)) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Exit code could not be re-read for pid=$($Process.Id): $lastError"
        }
    }

    return [BitConverter]::ToInt32([BitConverter]::GetBytes($nativeExitCode), 0)
}

function Reset-InteractiveWin11Sandbox {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    $sandboxBase = Get-InteractiveWin11NormalizedPath -Path (Join-Path $Layout.RepoRoot '.sandbox\win11')
    $target = Get-InteractiveWin11NormalizedPath -Path $Layout.SandboxRoot
    $sandboxPrefix = '{0}\' -f $sandboxBase

    if (-not $target.StartsWith($sandboxPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset sandbox outside ${sandboxBase}: $target"
    }

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if (-not (Test-Path -LiteralPath $target -ErrorAction Stop)) {
            return
        }

        try {
            # Remove-Item -Recurse can race on Zig cache sentinel files
            # named ._.; Directory.Delete handles those paths reliably.
            [System.IO.Directory]::Delete($target, $true)
            return
        }
        catch {
            if (-not (Test-Path -LiteralPath $target)) {
                return
            }
            Start-Sleep -Milliseconds (100 * ($attempt + 1))
        }
    }

    $pendingName = '.delete-pending-{0}-{1}' -f (
        [System.IO.Path]::GetFileName($target),
        [System.Guid]::NewGuid().ToString('N')
    )
    $pending = Join-Path $sandboxBase $pendingName
    Move-Item -LiteralPath $target -Destination $pending -Force -ErrorAction Stop

    try {
        [System.IO.Directory]::Delete($pending, $true)
    }
    catch {
        Write-Warning "Moved stale sandbox to ${pending}; deferred cleanup failed: $($_.Exception.Message)"
    }
}
