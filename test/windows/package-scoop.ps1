[CmdletBinding()]
param(
    [string] $Version = '0.0.1',
    [string] $Architecture = $null
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'package-scoop.ps1'
try {


# Contract for the generated Scoop manifest. Today that is the pre_uninstall
# hook: Scoop deletes the folder a portable default-terminal registration
# points into, so the hook has to unregister it, on uninstall only, only for a
# registration this copy owns, not while a copy runs, and never fail the
# uninstall.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\windows-architecture.ps1')
$Architecture = (Get-WindowsPackageArchitecture -Architecture $(if ($Architecture) { $Architecture } else { Get-DefaultWindowsPackageArchitecture })).Name
$packageScript = Join-Path $repoRoot 'scripts\package-package-managers.ps1'
$scratchName = 'package-scoop-{0}' -f [guid]::NewGuid().ToString('N')
$scratchRelative = Join-Path 'dist' $scratchName
$scratchRoot = Join-Path $repoRoot $scratchRelative
$artifactRelative = Join-Path $scratchRelative 'artifacts'
$artifactRoot = Join-Path $repoRoot $artifactRelative
$outputRelative = Join-Path $scratchRelative 'output'
$outputRoot = Join-Path $repoRoot $outputRelative
$appRoot = Join-Path ([System.IO.Path]::GetTempPath()) $scratchName

try {
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

    $setupName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind setup
    $portableName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind portable
    $checksumsName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind checksums
    $setupPath = Join-Path $artifactRoot $setupName
    $portablePath = Join-Path $artifactRoot $portableName
    Set-Content -LiteralPath $setupPath -Value "fake signed setup for $Architecture" -NoNewline
    Set-Content -LiteralPath $portablePath -Value "fake portable archive for $Architecture" -NoNewline
    Set-Content -LiteralPath (Join-Path $artifactRoot 'koreterm-icon.svg') -Value '<svg xmlns="http://www.w3.org/2000/svg" />' -NoNewline
    $setupSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLowerInvariant()
    $portableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $portablePath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $artifactRoot $checksumsName) -Value @(
        "$setupSha256 *$setupName"
        "$portableSha256 *$portableName"
    )

    & $packageScript `
        -Version $Version `
        -Architectures @($Architecture) `
        -ArtifactRoot $artifactRelative `
        -OutputRoot $outputRelative

    $manifestPath = Join-Path $outputRoot 'scoop\koreterm.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing generated Scoop manifest: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    # What the manifest already promised stays.
    if ($manifest.version -cne $Version) { throw 'Scoop manifest version does not match.' }
    if ($manifest.bin -cne 'koreterm.exe') { throw 'Scoop manifest bin must stay koreterm.exe.' }

    $hookLines = @($manifest.pre_uninstall)
    if ($null -eq $manifest.pre_uninstall -or $hookLines.Count -eq 0) {
        throw 'The Scoop manifest has no pre_uninstall hook, so a Scoop uninstall leaves the default terminal registered to a folder that is gone.'
    }
    $hook = $hookLines -join "`n"
    foreach ($expected in @("`$cmd -eq 'uninstall'", 'koreterm.com', '+unregister-default-terminal', 'catch', '{33368C6F-D328-410C-B225-26DC9F12C728}', 'Get-Process')) {
        if (-not $hook.Contains($expected, [StringComparison]::Ordinal)) {
            throw "pre_uninstall is missing expected content: $expected"
        }
    }
    # The hook calls the console-subsystem shim: the GUI exe returns at once
    # and Scoop would delete the folder under the running unregister.
    if (-not $hook.Contains("Join-Path `$dir 'koreterm.com'", [StringComparison]::Ordinal)) {
        throw 'pre_uninstall must call koreterm.com, not the GUI koreterm.exe.'
    }

    # Run the hook the way Scoop does, as a script block that sees $cmd and
    # $dir. Nothing real is read or started: the registry value and the
    # process list come from stand-ins for Get-Item and Get-Process (functions
    # shadow cmdlets for the script block that runs below them), and the
    # koreterm.com that the hook would run is a text file, so reaching the call
    # shows as one failure line and not reaching it leaves the output empty.
    $appsDir = Join-Path $appRoot 'apps\koreterm'
    $versionDir = Join-Path $appsDir '1.0.0'
    $emptyVersionDir = Join-Path $appsDir '0.9.0'
    New-Item -ItemType Directory -Path $versionDir, $emptyVersionDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $versionDir 'koreterm.com') -Value 'not an executable' -NoNewline

    $block = [scriptblock]::Create($hook)
    function Invoke-Hook {
        param(
            [string] $Command,
            [string] $Dir,
            [AllowNull()] [string] $Registered,
            [string[]] $RunningPaths = @()
        )
        $cmd = $Command
        $dir = $Dir
        function Get-Process {
            foreach ($path in $RunningPaths) { [pscustomobject]@{ Path = $path } }
        }
        function Get-Item {
            [CmdletBinding()]
            param([string] $LiteralPath)
            if ($null -eq $Registered) { return $null }
            # GetNewClosure sees only this scope, so copy the value in first.
            $value = $Registered
            $key = [pscustomobject]@{}
            Add-Member -InputObject $key -MemberType ScriptMethod -Name GetValue -Value { param($name) $value }.GetNewClosure()
            return $key
        }
        return (& $block *>&1 | Out-String)
    }
    function Assert-Reaches([string] $Label, [string] $Out) {
        if ($Out -notmatch 'could not unregister the default terminal') {
            throw "${Label}: the hook should have run the unregister (and swallowed its failure), got: '$Out'"
        }
    }
    function Assert-Silent([string] $Label, [string] $Out) {
        if ($Out.Trim()) { throw "${Label}: the hook should have done nothing, got: $Out" }
    }

    $owned = '"{0}\koreterm.exe"' -f $versionDir
    # `scoop update` keeps the old version folder and the registration stays on
    # it; the uninstall that follows runs the hook for the newer folder.
    $ownedByOlderVersion = '"{0}\koreterm.exe"' -f $emptyVersionDir
    $elsewhere = '"C:\Program Files\koreterm\koreterm.exe"'
    $lookalike = '"{0}2\1.0.0\koreterm.exe"' -f $appsDir

    Assert-Reaches 'uninstall of the registered copy' (Invoke-Hook -Command 'uninstall' -Dir $versionDir -Registered $owned)
    Assert-Reaches 'uninstall after an update, registration on an older version folder' (Invoke-Hook -Command 'uninstall' -Dir $versionDir -Registered $ownedByOlderVersion)
    Assert-Silent 'a registration in a sibling app folder' (Invoke-Hook -Command 'uninstall' -Dir $versionDir -Registered $lookalike)
    Assert-Reaches 'a running process elsewhere' (Invoke-Hook -Command 'uninstall' -Dir $versionDir -Registered $owned -RunningPaths @('C:\Windows\explorer.exe'))
    Assert-Silent 'scoop update' (Invoke-Hook -Command 'update' -Dir $versionDir -Registered $owned)
    Assert-Silent 'a registration of another copy' (Invoke-Hook -Command 'uninstall' -Dir $versionDir -Registered $elsewhere)
    Assert-Silent 'no registration' (Invoke-Hook -Command 'uninstall' -Dir $versionDir -Registered $null)
    Assert-Silent 'a copy still running (Scoop refuses the uninstall after this hook)' (Invoke-Hook -Command 'uninstall' -Dir $versionDir -Registered $owned -RunningPaths @((Join-Path $appsDir 'current\koreterm.exe')))
    Assert-Silent 'a version folder without koreterm.com' (Invoke-Hook -Command 'uninstall' -Dir $emptyVersionDir -Registered ('"{0}\koreterm.exe"' -f $emptyVersionDir))

    Write-Host "Scoop manifest validation: PASS (version=$Version, architecture=$Architecture)"
}
finally {
    if (Test-Path -LiteralPath $appRoot) {
        Remove-Item -LiteralPath $appRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
