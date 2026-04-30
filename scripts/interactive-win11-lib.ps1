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

function Get-InteractiveWin11LaunchArguments {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    return @(
        '--single-instance=false'
        "--class=winghostty-interactive-$($Layout.SandboxId)"
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
    $exitCode = 0
    [System.Environment]::SetEnvironmentVariable($EnvironmentVariable, '1', 'Process')

    Push-Location $RepoRoot
    try {
        & $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $LauncherPath @ArgumentList
        if ($null -ne $LASTEXITCODE) {
            $exitCode = $LASTEXITCODE
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
        $ExitCode.Value = $exitCode
    }
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

    return Get-InteractiveWin11NormalizedPath -Path (Join-Path $RepoRoot 'zig-out\bin\winghostty.exe')
}

function Invoke-InteractiveWin11Build {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
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
        & cmd /c $devWindowsCmd zig build -Demit-exe=true
        if ($LASTEXITCODE -ne 0) {
            throw "zig build -Demit-exe=true failed with exit code $LASTEXITCODE"
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
        throw "Missing winghostty.exe at $ExePath"
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
        [Parameter(Mandatory)] [string] $NativeTypeName,
        [int] $ShowCode = 9,
        [switch] $SetForeground
    )

    $nativeType = $NativeTypeName -as [type]
    if ($null -eq $nativeType) {
        throw "Missing native helper type: $NativeTypeName"
    }

    [void] $nativeType::ShowWindow($Hwnd, $ShowCode)
    if ($SetForeground) {
        [void] $nativeType::SetForegroundWindow($Hwnd)
    }
}

function Show-InteractiveWin11ProcessMainWindow {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [string] $NativeTypeName,
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
                -NativeTypeName $NativeTypeName `
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
        [System.Diagnostics.Process] $Process
    )

    while ([DateTime]::UtcNow -lt $Deadline) {
        if ($null -ne $Process -and $Process.HasExited) {
            throw "winghostty exited while waiting for ${Description} (exit code $($Process.ExitCode))"
        }

        if (& $Condition) {
            return
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Timed out waiting for $Description"
}

function Stop-InteractiveWin11Process {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    if (-not $Process.HasExited) {
        & taskkill.exe /PID $Process.Id /T /F *> $null
        try {
            $Process.Refresh()
        }
        catch {
            Write-Warning "Process refresh failed during interactive Win11 cleanup: $($_.Exception.Message)"
        }
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $Process.WaitForExit()
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
                throw "winghostty.exe at $resolvedExePath is older than the requested build inputs; rerun without -NoBuild or pass -Rebuild."
            }
            return 'build'
        }
        return 'launch'
    }

    if ($NoBuild) {
        throw "Missing winghostty.exe at $resolvedExePath"
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
            return [int] $Process.ExitCode
        }
    }
    catch {
    }

    [uint32] $nativeExitCode = 0
    if (-not [InteractiveWin11ProcessNative]::GetExitCodeProcess($ProcessHandle, [ref] $nativeExitCode)) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Exit code could not be read for pid=$($Process.Id): $lastError"
    }

    if ($nativeExitCode -eq 259) {
        throw "Process has not exited yet for pid=$($Process.Id)"
    }

    return [int] $nativeExitCode
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
