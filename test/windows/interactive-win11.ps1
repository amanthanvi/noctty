$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Match {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Value -notmatch $Pattern) {
        throw "$Message`nPattern: $Pattern`nValue:   $Value"
    }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
$callerErrorActionPreference = 'Continue'
$ErrorActionPreference = $callerErrorActionPreference
. $libPath
Assert-Equal $ErrorActionPreference $callerErrorActionPreference 'dot-sourcing the helper library should not overwrite caller ErrorActionPreference'
$ErrorActionPreference = 'Stop'

$pathScratch = Join-Path $env:TEMP 'noctty-interactive-win11-path-test'
$samePathA = Join-Path $pathScratch 'worktrees\feature-a\repo'
$samePathB = '{0}\' -f ($samePathA.Replace('\', '/'))
$otherPath = Join-Path $pathScratch 'worktrees\feature-b\repo'
$driveRoot = [System.IO.Path]::GetPathRoot((Get-Location).Path)

$idA = Get-InteractiveWin11WorktreeId -RepoRoot $samePathA
$idB = Get-InteractiveWin11WorktreeId -RepoRoot $samePathB
$idC = Get-InteractiveWin11WorktreeId -RepoRoot $otherPath
$sandboxNameA = Get-InteractiveWin11SandboxName -SandboxName 'Command Finish'
$sandboxNameB = Get-InteractiveWin11SandboxName -SandboxName 'progress'

Assert-Equal $idA $idB 'worktree id should normalize slash direction and trailing slash'
Assert-Match $idA '^[a-z0-9.-]+-[0-9a-f]{12}$' 'worktree id should include slug and hash suffix'
Assert-True ($idA -ne $idC) 'different worktree paths should produce different ids'
Assert-Equal (Get-InteractiveWin11NormalizedPath -Path $driveRoot) ([System.IO.Path]::GetFullPath($driveRoot).Replace('/', '\')) 'normalization should preserve rooted drive paths'
Assert-Equal $sandboxNameA 'command-finish' 'sandbox names should normalize spaces and case'
Assert-Equal (Get-InteractiveWin11SandboxName -SandboxName ' / ') 'default' 'blank sandbox names should fall back to default'

$layout = Get-InteractiveWin11SandboxLayout -RepoRoot $samePathA
$otherLayout = Get-InteractiveWin11SandboxLayout -RepoRoot $samePathA -SandboxName $sandboxNameB

Assert-Equal $layout.RepoRoot (Get-InteractiveWin11NormalizedPath -Path $samePathA) 'layout should preserve normalized repo root'
Assert-True ($layout.SandboxRoot.StartsWith((Join-Path $layout.RepoRoot '.sandbox\win11\'), [System.StringComparison]::OrdinalIgnoreCase)) 'sandbox root should live under repo-local .sandbox\win11'
Assert-Equal $layout.SandboxName 'default' 'default layout should use the default sandbox name'
Assert-Equal $layout.SandboxId "$($layout.WorktreeId)-default" 'default layout should publish a sandbox id'
Assert-True ($layout.SandboxRoot.EndsWith("\$($layout.WorktreeId)\default", [System.StringComparison]::OrdinalIgnoreCase)) 'default sandbox root should include worktree and sandbox segments'
Assert-Equal $layout.XdgConfigHome $layout.LocalAppData 'config home should reuse localappdata'
Assert-Equal $layout.Temp (Join-Path $layout.SandboxRoot 'temp') 'temp path should be rooted in sandbox'
Assert-True ($layout.SandboxRoot -ne $otherLayout.SandboxRoot) 'different sandbox names should produce isolated sandbox roots'
Assert-True ($layout.SandboxId -ne $otherLayout.SandboxId) 'different sandbox names should produce unique sandbox ids'

$launchArgs = @(Get-InteractiveWin11LaunchArguments -Layout $layout)
Assert-Equal $launchArgs.Count 5 'launch args should include containment and isolation overrides'
Assert-True ($launchArgs -contains '--linux-cgroup=always') 'launch args should enable Windows Job Object containment'
Assert-True ($launchArgs -contains '--linux-cgroup-hard-fail=true') 'launch args should fail when Job Object attachment fails'
Assert-True ($launchArgs -contains '--windows-job-object-kill-on-close=true') 'launch args should terminate contained descendants when the host exits'
Assert-True ($launchArgs -contains '--single-instance=false') 'launch args should disable single-instance forwarding'
Assert-True ($launchArgs -contains "--class=noctty-interactive-$($layout.SandboxId)") 'launch args should include a sandbox-unique class'

$defaultBuildInputs = @(Get-InteractiveWin11DefaultBuildInputs -RepoRoot $layout.RepoRoot)
Assert-Equal $defaultBuildInputs.Count 3 'default build inputs should track build files and src'
Assert-Equal $defaultBuildInputs[0] (Join-Path $layout.RepoRoot 'build.zig') 'default build inputs should include build.zig'
Assert-Equal $defaultBuildInputs[1] (Join-Path $layout.RepoRoot 'build.zig.zon') 'default build inputs should include build.zig.zon'
Assert-Equal $defaultBuildInputs[2] (Join-Path $layout.RepoRoot 'src') 'default build inputs should include src'
Assert-Equal (Get-InteractiveWin11ExePath -RepoRoot $layout.RepoRoot) (Get-InteractiveWin11NormalizedPath -Path (Join-Path $layout.RepoRoot 'zig-out\bin\noctty.exe')) 'exe path helper should normalize the expected build output path'

$scratchRepo = Join-Path $env:TEMP 'noctty-interactive-win11-test'
$scratchLayout = Get-InteractiveWin11SandboxLayout -RepoRoot $scratchRepo
New-Item -ItemType Directory -Force -Path $scratchLayout.Temp | Out-Null
Set-Content -Path (Join-Path $scratchLayout.Temp 'marker.txt') -Value 'ok'

$textFile = Join-Path $scratchLayout.Temp 'text.log'
Set-Content -Path $textFile -Value @('one', 'two', 'three')
Assert-Match (Get-InteractiveWin11TextFile -Path $textFile) 'one' 'text-file helper should read existing files'
Assert-Equal (Get-InteractiveWin11TextFile -Path (Join-Path $scratchLayout.Temp 'missing.log') -Default 'fallback') 'fallback' 'text-file helper should return default for missing files'
Assert-Equal (Get-InteractiveWin11TextFileTail -Path $textFile -LineCount 2) (('two', 'three') -join [Environment]::NewLine) 'text-file tail helper should return the requested trailing lines'

Reset-InteractiveWin11Sandbox -Layout $scratchLayout
Assert-True (-not (Test-Path $scratchLayout.SandboxRoot)) 'reset should remove only the current worktree sandbox'

$escapeRoot = Join-Path $scratchRepo '.sandbox\win11-escape'
New-Item -ItemType Directory -Force -Path $escapeRoot | Out-Null
Set-Content -Path (Join-Path $escapeRoot 'marker.txt') -Value 'keep'

$escapeLayout = [ordered]@{
    RepoRoot    = $scratchRepo
    SandboxRoot = $escapeRoot
}

$resetBlocked = $false
try {
    Reset-InteractiveWin11Sandbox -Layout $escapeLayout
}
catch {
    $resetBlocked = $true
    Assert-True ($_.Exception.Message -like '*Refusing to reset sandbox outside*') 'out-of-sandbox reset should mention refusal'
}

Assert-True $resetBlocked 'prefix-collision sandbox target should be refused'
Assert-True (Test-Path $escapeRoot) 'refused sandbox target should not be deleted'

$launchScratch = Join-Path $env:TEMP 'noctty-interactive-win11-launch-test'
Remove-Item -LiteralPath $launchScratch -Recurse -Force -ErrorAction SilentlyContinue

$missingExe = Join-Path $launchScratch 'zig-out\bin\noctty.exe'
$existingExe = Join-Path $launchScratch 'ready\zig-out\bin\noctty.exe'
$directoryExe = Join-Path $launchScratch 'dir\zig-out\bin\noctty.exe'
$staleInputDir = Join-Path $launchScratch 'stale\src'
$staleInputFile = Join-Path $staleInputDir 'win32.zig'
$metadataInputDir = Join-Path $launchScratch 'metadata\src'
$freshInputDir = Join-Path $launchScratch 'fresh\src'
$freshInputFile = Join-Path $freshInputDir 'win32.zig'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $existingExe) | Out-Null
Set-Content -Path $existingExe -Value 'stub'
New-Item -ItemType Directory -Force -Path $directoryExe | Out-Null
New-Item -ItemType Directory -Force -Path $staleInputDir, $metadataInputDir, $freshInputDir | Out-Null
Set-Content -Path $staleInputFile -Value 'newer source'
Set-Content -Path $freshInputFile -Value 'older source'

$exeInfo = Get-Item -LiteralPath $existingExe
$olderTime = [DateTime]::UtcNow.AddMinutes(-10)
$newerTime = [DateTime]::UtcNow.AddMinutes(10)
$exeInfo.LastWriteTimeUtc = $olderTime
(Get-Item -LiteralPath $staleInputDir).LastWriteTimeUtc = $newerTime
(Get-Item -LiteralPath $staleInputFile).LastWriteTimeUtc = $newerTime
(Get-Item -LiteralPath $metadataInputDir).LastWriteTimeUtc = $newerTime
(Get-Item -LiteralPath $freshInputDir).LastWriteTimeUtc = $olderTime
(Get-Item -LiteralPath $freshInputFile).LastWriteTimeUtc = $olderTime

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $missingExe
) 'build' 'missing binary without flags should build'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $existingExe -Rebuild
) 'build' 'rebuild flag should force build even when binary exists'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $existingExe
) 'launch' 'existing binary without rebuild should launch'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $existingExe -BuildInputs $staleInputDir
) 'build' 'newer source inputs should force rebuild even when the binary exists'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $existingExe -BuildInputs $metadataInputDir
) 'build' 'newer source directory metadata should force rebuild even without child files'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $existingExe -BuildInputs $freshInputDir
) 'launch' 'older source inputs should reuse the existing binary'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $directoryExe
) 'build' 'directory at exe path should not count as launchable'

$missingBinaryBlocked = $false
try {
    Get-InteractiveWin11LaunchAction -ExePath $missingExe -NoBuild | Out-Null
}
catch {
    $missingBinaryBlocked = $true
    Assert-True ($_.Exception.Message -like '*noctty.exe*') 'missing binary with no-build should mention noctty.exe'
}

Assert-True $missingBinaryBlocked 'missing binary with no-build should throw'

$staleBinaryBlocked = $false
try {
    Get-InteractiveWin11LaunchAction -ExePath $existingExe -BuildInputs $staleInputDir -NoBuild | Out-Null
}
catch {
    $staleBinaryBlocked = $true
    Assert-True ($_.Exception.Message -like '*older than the requested build inputs*') 'stale binary with no-build should mention input freshness'
    Assert-True ($_.Exception.Message -like '*-NoBuild*') 'stale binary with no-build should mention -NoBuild'
}

Assert-True $staleBinaryBlocked 'stale binary with no-build should throw'

$conflictingFlagsBlocked = $false
try {
    Get-InteractiveWin11LaunchAction -ExePath $existingExe -Rebuild -NoBuild | Out-Null
}
catch {
    $conflictingFlagsBlocked = $true
    Assert-True ($_.Exception.Message -like '*-Rebuild*') 'conflicting flags should mention -Rebuild'
    Assert-True ($_.Exception.Message -like '*-NoBuild*') 'conflicting flags should mention -NoBuild'
}

Assert-True $conflictingFlagsBlocked 'rebuild and no-build together should throw'

Write-Host 'interactive-win11 helper tests: PASS'
