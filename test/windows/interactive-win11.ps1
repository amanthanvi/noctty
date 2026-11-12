$ErrorActionPreference = 'Stop'
$savedMeasureAumid = $env:KORETERM_INTERACTIVE_MEASURE_AUMID
try {
# The legacy timestamp cases below use synthetic paths, even when the composite
# invokes this self-test with measurement mode inherited.
$env:KORETERM_INTERACTIVE_MEASURE_AUMID = $null

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

$pathScratch = Join-Path $env:TEMP 'koreterm-interactive-win11-path-test'
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
Assert-Equal $launchArgs.Count 6 'launch args should include containment, isolation and cmd overrides'
Assert-True ($launchArgs -contains '--command=cmd.exe') 'shell-agnostic harnesses must not inherit PowerShell history'
Assert-True (@(Get-InteractiveWin11LaunchArguments -Layout $layout -UseConfiguredCommand) -notcontains '--command=cmd.exe') 'shell-specific fixtures must retain their configured command'
Assert-True ($launchArgs -contains '--linux-cgroup=always') 'launch args should enable Windows Job Object containment'
Assert-True ($launchArgs -contains '--linux-cgroup-hard-fail=true') 'launch args should fail when Job Object attachment fails'
Assert-True ($launchArgs -contains '--windows-job-object-kill-on-close=true') 'launch args should terminate contained descendants when the host exits'
Assert-True ($launchArgs -contains '--single-instance=false') 'launch args should disable single-instance forwarding'
Assert-True ($launchArgs -contains "--class=koreterm-interactive-$($layout.SandboxId)") 'launch args should include a sandbox-unique class'

$defaultBuildInputs = @(Get-InteractiveWin11DefaultBuildInputs -RepoRoot $layout.RepoRoot)
Assert-Equal $defaultBuildInputs.Count 3 'default build inputs should track build files and src'
Assert-Equal $defaultBuildInputs[0] (Join-Path $layout.RepoRoot 'build.zig') 'default build inputs should include build.zig'
Assert-Equal $defaultBuildInputs[1] (Join-Path $layout.RepoRoot 'build.zig.zon') 'default build inputs should include build.zig.zon'
Assert-Equal $defaultBuildInputs[2] (Join-Path $layout.RepoRoot 'src') 'default build inputs should include src'
Assert-Equal (Get-InteractiveWin11ExePath -RepoRoot $layout.RepoRoot) (Get-InteractiveWin11NormalizedPath -Path (Join-Path $layout.RepoRoot 'zig-out\bin\koreterm.exe')) 'exe path helper should normalize the expected build output path'

$scratchRepo = Join-Path $env:TEMP 'koreterm-interactive-win11-test'
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

$launchScratch = Join-Path $env:TEMP 'koreterm-interactive-win11-launch-test'
Remove-Item -LiteralPath $launchScratch -Recurse -Force -ErrorAction SilentlyContinue

$missingExe = Join-Path $launchScratch 'zig-out\bin\koreterm.exe'
$existingExe = Join-Path $launchScratch 'ready\zig-out\bin\koreterm.exe'
$directoryExe = Join-Path $launchScratch 'dir\zig-out\bin\koreterm.exe'
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
    Assert-True ($_.Exception.Message -like '*koreterm.exe*') 'missing binary with no-build should mention koreterm.exe'
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

$moduleScratch = Join-Path $env:TEMP 'koreterm-interactive-win11-module-path-test'
Remove-Item -LiteralPath $moduleScratch -Recurse -Force -ErrorAction SilentlyContinue
$fakePwshHome = Join-Path $moduleScratch 'PowerShell\7'
New-Item -ItemType Directory -Force -Path (Join-Path $fakePwshHome 'Modules') | Out-Null
Set-Content -Path (Join-Path $fakePwshHome 'pwsh.exe') -Value 'stub'
$windowsPowerShellModules = @(
    (Join-Path $moduleScratch 'WindowsPowerShell\Modules'),
    (Join-Path $moduleScratch 'system32\WindowsPowerShell\v1.0\Modules')
)
$inheritedModulePath = @(
    (Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'),
    ((Join-Path $env:ProgramFiles 'PowerShell\Modules') + '\'),
    (Join-Path $fakePwshHome 'Modules').ToLowerInvariant(),
    '',
    $windowsPowerShellModules[0],
    $windowsPowerShellModules[1]
) -join ';'
Assert-Equal (
    Get-InteractiveWin11WindowsPowerShellModulePath -ModulePath $inheritedModulePath
) ($windowsPowerShellModules -join ';') 'Windows PowerShell children should not inherit PowerShell 7 module folders'
Assert-Equal (
    Get-InteractiveWin11WindowsPowerShellModulePath -ModulePath ($windowsPowerShellModules -join ';')
) ($windowsPowerShellModules -join ';') 'a Windows PowerShell module path should pass through unchanged'
Remove-Item -LiteralPath $moduleScratch -Recurse -Force -ErrorAction SilentlyContinue

$conptyScratch = Join-Path $env:TEMP 'koreterm-interactive-win11-conpty-preflight-test'
Remove-Item -LiteralPath $conptyScratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $conptyScratch | Out-Null
$conptyExe = Join-Path $conptyScratch 'koreterm.exe'
Set-Content -Path $conptyExe -Value 'stub'
Assert-InteractiveWin11ExeExists -ExePath $conptyExe -AllowInboxConPty
foreach ($missing in @('conpty.dll', 'OpenConsole.exe')) {
    $missingBlocked = $false
    try {
        Assert-InteractiveWin11ExeExists -ExePath $conptyExe
    }
    catch {
        $missingBlocked = $true
        Assert-True ($_.Exception.Message -like "*$missing*") "a missing $missing should be named"
    }
    Assert-True $missingBlocked "an exe without $missing beside it should be refused"
    Set-Content -Path (Join-Path $conptyScratch $missing) -Value 'stub'
}
Assert-InteractiveWin11ExeExists -ExePath $conptyExe
Remove-Item -LiteralPath $conptyScratch -Recurse -Force -ErrorAction SilentlyContinue

$env:KORETERM_INTERACTIVE_MEASURE_AUMID = '1'
Assert-Equal (Get-InteractiveWin11ProcessAumid) 'io.github.amanthanvi.koreterm.measure' 'measurement process identity should follow the executable'
Assert-Equal (Get-InteractiveWin11ToastAumid) 'io.github.amanthanvi.koreterm' 'measurement mode must retain the product notifier gate'
$measureExe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
Assert-Equal $measureExe (Get-InteractiveWin11MeasureExePath $repoRoot) 'measurement mode should route the executable'
Assert-Equal (Get-InteractiveWin11MeasureRepoForExe $measureExe) $repoRoot 'raw measurement executable should recover its repository'

# Mock only the build/receipt boundary. These checks must never run a compiler
# or require a real measurement executable in the helper self-test.
$script:measureRoutingBuild = $null
$script:measureRoutingAssertCount = 0
function Invoke-InteractiveWin11MeasureBuild {
    param([string] $RepoRoot, [string] $Optimize)
    $script:measureRoutingBuild = @($RepoRoot, $Optimize)
}
function Get-InteractiveWin11MeasureHead {
    param([string] $RepoRoot)
    return '1234567890123456789012345678901234567890'
}
function Assert-InteractiveWin11MeasureBuild {
    param([string] $RepoRoot, [string] $ExePath)
    Assert-Equal $RepoRoot $measureRoutingRepo 'measurement receipt validation should use the executable repository'
    Assert-Equal $ExePath $measureRoutingExe 'measurement receipt validation should use the exact raw executable'
    $script:measureRoutingAssertCount++
    if ($script:measureRoutingRejectReceipt) { throw 'Synthetic invalid measurement receipt.' }
}
$measureRoutingRepo = Join-Path $env:TEMP ('koreterm-measure-route-' + [guid]::NewGuid().ToString('N'))
$measureRoutingExe = Get-InteractiveWin11ExePath $measureRoutingRepo
Assert-Equal (Join-Path (Split-Path -Parent $measureRoutingExe) 'koreterm.com') (Get-InteractiveWin11MeasureLayout $measureRoutingRepo).Cli 'measurement routing must preserve the sibling CLI shim path'
Assert-Equal (Get-InteractiveWin11LaunchAction -ExePath $measureRoutingExe) 'build' 'missing measurement binary should request a build'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $measureRoutingExe) | Out-Null
Set-Content -LiteralPath $measureRoutingExe -Value 'synthetic executable'
$script:measureRoutingRejectReceipt = $false
Assert-Equal (Get-InteractiveWin11LaunchAction -ExePath $measureRoutingExe -NoBuild) 'launch' 'valid measurement receipt should permit reuse'
Assert-Equal $script:measureRoutingAssertCount 0 'action selection must defer full validation to admission'
Assert-InteractiveWin11ExeExists -ExePath $measureRoutingExe -AllowInboxConPty
Assert-Equal $script:measureRoutingAssertCount 1 'the final executable preflight must validate the receipt exactly once'
$script:measureRoutingRejectReceipt = $true
$rejected = $false
try { Assert-InteractiveWin11ExeExists -ExePath $measureRoutingExe -AllowInboxConPty } catch { $rejected = $true }
Assert-True $rejected 'an invalid measurement receipt must fail rather than fall back to timestamps or a product build'
$foreignRejected = $false
try { Get-InteractiveWin11LaunchAction -ExePath $existingExe | Out-Null } catch { $foreignRejected = $true }
Assert-True $foreignRejected 'measurement mode must reject product executable paths'
Invoke-InteractiveWin11Build -RepoRoot $measureRoutingRepo -Optimize ReleaseFast
Assert-Equal $script:measureRoutingBuild[0] $measureRoutingRepo 'build routing must preserve repository'
Assert-Equal $script:measureRoutingBuild[1] 'ReleaseFast' 'build routing must preserve optimization'
Invoke-InteractiveWin11Build -RepoRoot $measureRoutingRepo
Assert-Equal $script:measureRoutingBuild[1] '' 'unspecified optimization must leave the measurement builder default intact'
$savedRoutingEnvironment = @{}
foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'TEMP', 'TMP', 'GHOSTTY_RESOURCES_DIR')) {
    $savedRoutingEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $routingLayout = Get-InteractiveWin11SandboxLayout $measureRoutingRepo -SandboxName 'config-probe'
    [void] (Set-InteractiveWin11Environment -Layout $routingLayout -IncludeResourcesDir)
    Assert-Equal $env:LOCALAPPDATA $routingLayout.LocalAppData 'measurement mode must retain per-harness LOCALAPPDATA config semantics'
    Assert-Equal $env:XDG_CONFIG_HOME $routingLayout.LocalAppData 'measurement mode must retain per-harness config root'
    Assert-Equal $env:GHOSTTY_RESOURCES_DIR (Join-Path (Get-InteractiveWin11MeasureLayout $measureRoutingRepo).Prefix 'share\ghostty') 'measurement resources must come from the same generation prefix'
    Assert-Equal $env:KORETERM_INTERACTIVE_MEASURE_AUMID '1' 'sandbox redirection must retain inherited measurement mode'
    Assert-True (-not [IO.File]::Exists((Join-Path (Split-Path -Parent $measureRoutingExe) 'koreterm.portable'))) 'measurement routing must not add a shared portable config root'
} finally {
    foreach ($entry in $savedRoutingEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
}
$env:KORETERM_INTERACTIVE_MEASURE_AUMID = $null
Assert-Equal (Get-InteractiveWin11ProcessAumid) 'io.github.amanthanvi.koreterm' 'standalone normal mode should retain product process identity'
Assert-Equal (Get-InteractiveWin11ToastAumid) 'io.github.amanthanvi.koreterm' 'standalone normal mode should retain product notifier identity'
Write-Host 'interactive-win11 helper tests: PASS'
} finally {
    $env:KORETERM_INTERACTIVE_MEASURE_AUMID = $savedMeasureAumid
}
