$ErrorActionPreference = 'Stop'
$savedMeasureAumid = $env:NOCTTY_INTERACTIVE_MEASURE_AUMID
try {
# The legacy timestamp cases below use synthetic paths, even when the composite
# invokes this self-test with measurement mode inherited.
$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = $null

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
Assert-Equal $launchArgs.Count 6 'launch args should include containment, isolation and cmd overrides'
Assert-True ($launchArgs -contains '--command=cmd.exe') 'shell-agnostic harnesses must not inherit PowerShell history'
Assert-True (@(Get-InteractiveWin11LaunchArguments -Layout $layout -UseConfiguredCommand) -notcontains '--command=cmd.exe') 'shell-specific fixtures must retain their configured command'

# Paths compare canonically (#740's first hosted run: TEMP is C:\Users\RUNNER~1\... there, so a raw TEMP path and the
# same path through GetFullPath differ as strings). The control takes a real 8.3 spelling of a directory, from the
# file system object, and needs both spellings to be the same path, and another directory not to be.
$shortScratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-short-name-control-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $shortScratch 'inner-directory-long-name'))
    $longInner = [IO.Path]::GetFullPath((Join-Path $shortScratch 'inner-directory-long-name'))
    $shortInner = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($longInner).ShortPath
    if ([string]::Equals($shortInner, $longInner, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host 'interactive-win11 short-name control: SKIPPED (this volume keeps no 8.3 names)'
    }
    else {
        Assert-True (Test-InteractiveWin11SamePath $shortInner $longInner) 'an 8.3 spelling and the long spelling of one directory are the same path'
        Assert-True (Test-InteractiveWin11SamePath (Join-Path $shortInner 'not-yet\x.txt') (Join-Path $longInner 'not-yet\x.txt')) 'an 8.3 parent of a path that does not exist yet still compares as the same path'
        Assert-True (Test-InteractiveWin11SamePath $shortInner $longInner.ToUpperInvariant()) 'paths compare without regard to case'
        Assert-True (-not (Test-InteractiveWin11SamePath $shortInner $shortScratch)) 'a different directory is not the same path'
        $shortRepo = Join-Path $shortInner 'repo'
        $shortExe = Join-Path $shortRepo ('.sandbox\interactive-measure\' + ('a' * 40) + '\prefix\bin\noctty.exe')
        Assert-True (Test-InteractiveWin11SamePath (Get-InteractiveWin11MeasureRepoForExe $shortExe) (Join-Path $longInner 'repo')) 'the measurement repository recovered from an 8.3 spelling is the long one'
    }
} finally { Remove-Item -LiteralPath $shortScratch -Recurse -Force -ErrorAction SilentlyContinue }

# Hosted mode (the hidden-desktop suite, design §4.1): the shell is the portable copy's config line, never argv, and
# a hosted leaf never bootstraps nor builds. The functions read the variable when called, so setting it here, after
# the library loaded, tests them without the desktop check the library's load would run.
$savedHostedEnvironment = @{}
foreach ($name in @('NOCTTY_GUI_HIDDEN_DESKTOP', 'NOCTTY_GUI_HIDDEN_EXE', 'NOCTTY_GUI_HIDDEN_RUN', 'GHOSTTY_RESOURCES_DIR')) {
    $savedHostedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$hostedScratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-hosted-selftest-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $hostedScratch)
    $hostedExe = Join-Path $hostedScratch 'noctty.exe'
    $env:NOCTTY_GUI_HIDDEN_DESKTOP = 'WinSta0\noctty-gh-' + ('0' * 32)
    $env:NOCTTY_GUI_HIDDEN_EXE = $hostedExe
    $env:NOCTTY_GUI_HIDDEN_RUN = $hostedScratch
    $hostedLaunchArgs = @(Get-InteractiveWin11LaunchArguments -Layout $layout)
    Assert-Equal $hostedLaunchArgs.Count 5 'hosted launch args keep containment and isolation only'
    Assert-Equal @($hostedLaunchArgs | Where-Object { $_.StartsWith('--command', [StringComparison]::Ordinal) }).Count 0 'hosted launch args carry no --command'
    $hostedCmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    foreach ($leafText in @('', "window-save-state = always`r`nconfirm-close-surface = false`r`n")) {
        $hostedConfigPath = Write-InteractiveWin11HostedConfig -Text $leafText
        Assert-True (Test-InteractiveWin11SamePath $hostedConfigPath (Join-Path $hostedScratch 'config.ghostty')) 'hosted config goes beside the copy'
        $hostedLines = @([IO.File]::ReadAllLines($hostedConfigPath))
        Assert-Equal @($hostedLines | Where-Object { [string]::Equals($_, "command = direct:$hostedCmd /D", [StringComparison]::Ordinal) }).Count 1 'hosted config sets System32 cmd with /D once'
        Assert-Equal @($hostedLines | Where-Object { $_.StartsWith('command', [StringComparison]::Ordinal) }).Count 1 'hosted config sets the shell once'
        foreach ($policyLine in @('clipboard-read = deny', 'clipboard-write = deny', 'copy-on-select = false', 'auto-update = off', 'desktop-notifications = false')) {
            Assert-Equal @($hostedLines | Where-Object { [string]::Equals($_, $policyLine, [StringComparison]::Ordinal) }).Count 1 "hosted config keeps '$policyLine'"
        }
        $saveLines = @($hostedLines | Where-Object { $_.StartsWith('window-save-state', [StringComparison]::Ordinal) })
        $expectedSave = if ($leafText) { 'window-save-state = always' } else { 'window-save-state = never' }
        Assert-Equal ($saveLines -join '|') $expectedSave 'hosted config keeps a leaf''s save state, else never'
    }
    Assert-True (Test-InteractiveWin11SamePath (Get-InteractiveWin11ExePath -RepoRoot $repoRoot) $hostedExe) 'hosted mode routes the executable to the staged copy'
    Assert-True (Test-InteractiveWin11SamePath (Get-InteractiveWin11StateRoot -Layout $layout) $hostedScratch) 'hosted state lives at the portable copy''s root'
    $hostedThrows = { param([scriptblock] $Action) try { & $Action; $false } catch { $true } }
    Assert-True (& $hostedThrows { Get-InteractiveWin11LaunchAction -ExePath $hostedExe }) 'a hosted leaf with its copy missing must throw, not build'
    Set-Content -LiteralPath $hostedExe -Value 'stub'
    Assert-Equal (Get-InteractiveWin11LaunchAction -ExePath $hostedExe) 'launch' 'a hosted leaf launches its staged copy'
    Assert-True (& $hostedThrows { Get-InteractiveWin11LaunchAction -ExePath $hostedExe -Rebuild }) 'a hosted leaf with -Rebuild must throw, not build'
    Assert-True (& $hostedThrows { Invoke-InteractiveWin11Build -RepoRoot $repoRoot }) 'the build tripwire must throw in hosted mode'
    # Against a repository that does not exist, so nothing could build even without the tripwire; the message names it.
    $measureTripwire = $null
    try { Invoke-InteractiveWin11MeasureBuild -RepoRoot (Join-Path $hostedScratch 'no-such-repo') } catch { $measureTripwire = $_.Exception.Message }
    Assert-True ([string]$measureTripwire -like '*a hosted leaf never builds*') 'measure-lib''s build tripwire must throw in hosted mode, before it reads anything'
    Assert-True (& $hostedThrows { Invoke-InteractiveWin11Bootstrap -RepoRoot $repoRoot -LauncherPath $hostedExe -EnvironmentVariable 'NOCTTY_HOSTED_SELFTEST_UNUSED' }) 'the bootstrap tripwire must throw in hosted mode'
    $hostedHarnessMain = Invoke-InteractiveWin11HarnessMain -RepoRoot $repoRoot -LauncherPath $hostedExe -EnvironmentVariable 'NOCTTY_HOSTED_SELFTEST_UNUSED'
    Assert-True ($null -eq $hostedHarnessMain) 'a hosted leaf skips the bootstrap'
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable('NOCTTY_HOSTED_SELFTEST_UNUSED', 'Process')) 'the hosted bypass sets no bootstrap sentinel'
    # The run token (H1 on #740): the hosted sandbox sits under the run directory, named by the token, and its id
    # (so every class built from it) ends in the token; a second run's token gives another sandbox and class.
    $hostedToken = [guid]::NewGuid().ToString('N')
    Set-Content -LiteralPath (Join-Path $hostedScratch 'staged.json') -Value (@{ runToken = $hostedToken } | ConvertTo-Json)
    Assert-Equal (Get-InteractiveWin11HostedRunToken) $hostedToken 'hosted mode reads the run token the runner staged'
    $hostedLayout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName 'smoke'
    Assert-True (Test-InteractiveWin11SamePath $hostedLayout.SandboxRoot (Join-Path $hostedScratch "sandbox-$hostedToken")) 'a hosted sandbox sits under the run directory, named by its token'
    Assert-True ($hostedLayout.SandboxId.EndsWith("-$hostedToken", [StringComparison]::Ordinal)) 'a hosted sandbox id ends in the run token'
    $hostedClassArgs = @(Get-InteractiveWin11LaunchArguments -Layout $hostedLayout)
    Assert-True ($null -eq (Get-InteractiveWin11HostedArgumentRefusal -Arguments $hostedClassArgs -Token $hostedToken)) 'the hosted launch arguments keep the argument rule'
    $hostedSecondToken = [guid]::NewGuid().ToString('N')
    Set-Content -LiteralPath (Join-Path $hostedScratch 'staged.json') -Value (@{ runToken = $hostedSecondToken } | ConvertTo-Json)
    $hostedSecondLayout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName 'smoke'
    Assert-True ($hostedSecondLayout.SandboxRoot -ne $hostedLayout.SandboxRoot -and $hostedSecondLayout.SandboxId -ne $hostedLayout.SandboxId) 'two runs share no sandbox and no class'
    Assert-True ($null -ne (Get-InteractiveWin11HostedArgumentRefusal -Arguments $hostedClassArgs -Token $hostedSecondToken)) 'one run''s class fails another run''s rule'
    Assert-True ($null -ne (Get-InteractiveWin11HostedArgumentRefusal -Arguments @("--class=noctty-interactive-$($hostedLayout.SandboxId)") -Token $hostedToken)) 'an app launch without --single-instance is refused'
    Assert-True (& $hostedThrows { Write-InteractiveWin11HostedConfig -Text "class = noctty-elsewhere`r`n" }) 'a leaf''s config cannot set the class'
    Set-Content -LiteralPath (Join-Path $hostedScratch 'staged.json') -Value '{}'
    Assert-True (& $hostedThrows { Get-InteractiveWin11HostedRunToken }) 'a run without a token is refused'
    Assert-True (& $hostedThrows { ConvertTo-InteractiveWin11HostedCommandLine -FilePath $hostedExe -ArgumentList @('--command=cmd.exe') }) 'the hosted launcher refuses --command in argv'
    Assert-True (& $hostedThrows { ConvertTo-InteractiveWin11HostedCommandLine -FilePath $hostedExe -ArgumentList @('a"b') }) 'the hosted launcher refuses a quote in an argument'
    Assert-Equal (ConvertTo-InteractiveWin11HostedCommandLine -FilePath $hostedExe -ArgumentList @('-e', 'a b', '/D')) ('"' + $hostedExe + '" -e "a b" /D') 'the hosted launcher quotes whitespace only'
} finally {
    foreach ($entry in $savedHostedEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    Remove-Item -LiteralPath $hostedScratch -Recurse -Force -ErrorAction SilentlyContinue
}
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

$moduleScratch = Join-Path $env:TEMP 'noctty-interactive-win11-module-path-test'
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

$conptyScratch = Join-Path $env:TEMP 'noctty-interactive-win11-conpty-preflight-test'
Remove-Item -LiteralPath $conptyScratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $conptyScratch | Out-Null
$conptyExe = Join-Path $conptyScratch 'noctty.exe'
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

$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
Assert-Equal (Get-InteractiveWin11ProcessAumid) 'io.github.amanthanvi.noctty.measure' 'measurement process identity should follow the executable'
Assert-Equal (Get-InteractiveWin11ToastAumid) 'io.github.amanthanvi.noctty' 'measurement mode must retain the product notifier gate'
$measureExe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
Assert-Equal $measureExe (Get-InteractiveWin11MeasureExePath $repoRoot) 'measurement mode should route the executable'
Assert-True (Test-InteractiveWin11SamePath (Get-InteractiveWin11MeasureRepoForExe $measureExe) $repoRoot) 'raw measurement executable should recover its repository'
# Hosted mode routes to the staged portable copy instead (design §4.2), in measurement mode too.
$savedHostedExe = $env:NOCTTY_GUI_HIDDEN_EXE; $savedHostedDesktop = $env:NOCTTY_GUI_HIDDEN_DESKTOP
try {
    $env:NOCTTY_GUI_HIDDEN_DESKTOP = 'WinSta0\noctty-gh-' + ('0' * 32)
    $env:NOCTTY_GUI_HIDDEN_EXE = Join-Path ([IO.Path]::GetTempPath()) 'noctty-hosted-route\noctty.exe'
    Assert-True (Test-InteractiveWin11SamePath (Get-InteractiveWin11ExePath -RepoRoot $repoRoot) $env:NOCTTY_GUI_HIDDEN_EXE) 'hosted measurement mode routes to the staged copy, not the raw prefix'
} finally { $env:NOCTTY_GUI_HIDDEN_EXE = $savedHostedExe; $env:NOCTTY_GUI_HIDDEN_DESKTOP = $savedHostedDesktop }

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
    Assert-True (Test-InteractiveWin11SamePath $RepoRoot $measureRoutingRepo) 'measurement receipt validation should use the executable repository'
    Assert-True (Test-InteractiveWin11SamePath $ExePath $measureRoutingExe) 'measurement receipt validation should use the exact raw executable'
    $script:measureRoutingAssertCount++
    if ($script:measureRoutingRejectReceipt) { throw 'Synthetic invalid measurement receipt.' }
}
$measureRoutingRepo = Join-Path $env:TEMP ('noctty-measure-route-' + [guid]::NewGuid().ToString('N'))
$measureRoutingExe = Get-InteractiveWin11ExePath $measureRoutingRepo
Assert-Equal (Join-Path (Split-Path -Parent $measureRoutingExe) 'noctty.com') (Get-InteractiveWin11MeasureLayout $measureRoutingRepo).Cli 'measurement routing must preserve the sibling CLI shim path'
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
Assert-True (Test-InteractiveWin11SamePath $script:measureRoutingBuild[0] $measureRoutingRepo) 'build routing must preserve repository'
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
    Assert-Equal $env:NOCTTY_INTERACTIVE_MEASURE_AUMID '1' 'sandbox redirection must retain inherited measurement mode'
    Assert-True (-not [IO.File]::Exists((Join-Path (Split-Path -Parent $measureRoutingExe) 'noctty.portable'))) 'measurement routing must not add a shared portable config root'
    # Hosted mode: the resources are the portable copy's own (design §4.2); its config root is the copy (xdg.zig).
    $savedHostedRouting = @($env:NOCTTY_GUI_HIDDEN_DESKTOP, $env:NOCTTY_GUI_HIDDEN_EXE)
    try {
        $env:NOCTTY_GUI_HIDDEN_DESKTOP = 'WinSta0\noctty-gh-' + ('0' * 32)
        $env:NOCTTY_GUI_HIDDEN_EXE = Join-Path ([IO.Path]::GetTempPath()) 'noctty-hosted-route\noctty.exe'
        [void] (Set-InteractiveWin11Environment -Layout $routingLayout -IncludeResourcesDir)
        Assert-Equal $env:GHOSTTY_RESOURCES_DIR (Join-Path (Split-Path -Parent $env:NOCTTY_GUI_HIDDEN_EXE) 'share\ghostty') 'hosted resources must come from the staged copy'
        Assert-True (Test-InteractiveWin11SamePath (Get-InteractiveWin11StateRoot -Layout $routingLayout) (Split-Path -Parent $env:NOCTTY_GUI_HIDDEN_EXE)) 'hosted config and state live at the copy''s root'
    } finally { $env:NOCTTY_GUI_HIDDEN_DESKTOP = $savedHostedRouting[0]; $env:NOCTTY_GUI_HIDDEN_EXE = $savedHostedRouting[1] }
} finally {
    foreach ($entry in $savedRoutingEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
}
$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = $null
Assert-Equal (Get-InteractiveWin11ProcessAumid) 'io.github.amanthanvi.noctty' 'standalone normal mode should retain product process identity'
Assert-Equal (Get-InteractiveWin11ToastAumid) 'io.github.amanthanvi.noctty' 'standalone normal mode should retain product notifier identity'
Write-Host 'interactive-win11 helper tests: PASS'
} finally {
    $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = $savedMeasureAumid
}
