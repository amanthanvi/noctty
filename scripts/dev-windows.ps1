$ErrorActionPreference = "Stop"

$Architecture = if ($env:DEV_WINDOWS_ARCH) {
    $env:DEV_WINDOWS_ARCH
} elseif ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    "arm64"
} else {
    "x64"
}
if (@("x64", "arm64") -notcontains $Architecture) {
    throw "DEV_WINDOWS_ARCH must be x64 or arm64."
}

$vsDevCmd = $null
$gitCmd = "C:\Program Files\Git\cmd"
$gitUsrBin = "C:\Program Files\Git\usr\bin"
$systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
$userHome = if ($env:USERPROFILE) {
    $env:USERPROFILE
} elseif ($env:HOMEDRIVE -and $env:HOMEPATH) {
    "$($env:HOMEDRIVE)$($env:HOMEPATH)"
} elseif ($env:USERNAME) {
    Join-Path $systemDrive "Users\$($env:USERNAME)"
} else {
    Join-Path $systemDrive "Users"
}
$programFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { Join-Path $systemDrive "Program Files" }
$programFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { Join-Path $systemDrive "Program Files (x86)" }
$appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $userHome "AppData\Roaming" }
$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $userHome "AppData\Local" }
$tempDir = if ($env:TEMP) { $env:TEMP } else { Join-Path $localAppData "Temp" }
$tmpDir = if ($env:TMP) { $env:TMP } else { $tempDir }

# vswhere ships with the Visual Studio Installer at this fixed path and knows every instance (2026 is
# version 18, 2022 is 17), any edition and install directory. It is asked for one with the C++
# tools for this architecture, a release first and then a preview. If it is missing or finds none,
# the default install paths are probed, newest first, and a VsDevCmd.bat counts only beside an MSVC
# toolset with libraries for this architecture (VC\Tools\MSVC\<version>\lib\x64 or lib\arm64): an
# instance left behind by an uninstall can keep its VsDevCmd.bat without the C++ tools, and one can
# have another architecture's.
$vcTools = if ($Architecture -eq "arm64") { "Microsoft.VisualStudio.Component.VC.Tools.ARM64" } else { "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" }
$vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path -LiteralPath $vswhere) {
    foreach ($prerelease in @($false, $true)) {
        $query = @("-latest", "-products", "*") + @(if ($prerelease) { "-prerelease" }) + @("-requires", $vcTools, "-find", "Common7\Tools\VsDevCmd.bat")
        # Windows PowerShell turns native stderr into errors that "Stop" makes terminating.
        $found = & { $ErrorActionPreference = "Continue"; & $vswhere @query 2>$null }
        $vsDevCmd = @($found | Where-Object { $_ }) | Select-Object -First 1
        if ($vsDevCmd) { break }
    }
}
foreach ($version in @("18", "2022")) {
    foreach ($edition in @("BuildTools", "Community", "Professional", "Enterprise")) {
        foreach ($candidateRoot in @($programFiles, $programFilesX86)) {
            $install = Join-Path $candidateRoot "Microsoft Visual Studio\$version\$edition"
            $candidate = Join-Path $install "Common7\Tools\VsDevCmd.bat"
            if ($vsDevCmd -or -not (Test-Path -LiteralPath $candidate)) { continue }
            $toolsets = @(Get-ChildItem -LiteralPath (Join-Path $install "VC\Tools\MSVC") -Directory -ErrorAction Ignore)
            if (@($toolsets | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "lib\$Architecture") }).Count -gt 0) { $vsDevCmd = $candidate }
        }
    }
}

if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $userHome "tools\zig-0.15.2"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}
if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $userHome "tools\zig-aarch64-windows-0.15.2"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}
if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $userHome "tools\zig-x86_64-windows-0.15.2"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}
if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $userHome "tools\zig"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}
if (-not $env:ZIG_HOME) {
    $candidate = Join-Path $programFiles "Zig"
    if (Test-Path (Join-Path $candidate "zig.exe")) {
        $env:ZIG_HOME = $candidate
    }
}
if (-not $env:ZIG_HOME) {
    $zigCommand = Get-Command zig.exe -ErrorAction SilentlyContinue
    if ($zigCommand) {
        $env:ZIG_HOME = Split-Path -Parent $zigCommand.Source
    }
}

if (-not $vsDevCmd) {
    throw "Missing VS Dev shell bootstrap. Install Visual Studio 2026 or 2022 Build Tools with the C++ workload for $Architecture."
}
Write-Host "VS Dev shell: `"$vsDevCmd`""
if (-not (Test-Path (Join-Path $gitCmd "git.exe"))) {
    throw "Missing Git executable under $gitCmd"
}
if (-not (Test-Path (Join-Path $gitUsrBin "sh.exe"))) {
    throw "Missing Git runtime under $gitUsrBin"
}
if (-not $env:ZIG_HOME) {
    throw "Zig 0.15.2+ not found. Set ZIG_HOME or install Zig under $userHome\tools\zig or $programFiles\Zig."
}
if (-not (Test-Path (Join-Path $env:ZIG_HOME "zig.exe"))) {
    throw "Missing zig.exe under $env:ZIG_HOME"
}
$env:APPDATA = $appData
$env:LOCALAPPDATA = $localAppData
$env:TEMP = $tempDir
$env:TMP = $tmpDir
$env:USERPROFILE = $userHome
$env:HOMEDRIVE = [System.IO.Path]::GetPathRoot($userHome).TrimEnd('\')
$env:HOMEPATH = $userHome.Substring($env:HOMEDRIVE.Length)
$env:SystemDrive = $systemDrive
New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
if ([string]::IsNullOrWhiteSpace($env:ZIG_GLOBAL_CACHE_DIR)) {
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $env:LOCALAPPDATA "zig"
}
if ([string]::IsNullOrWhiteSpace($env:ZIG_LOCAL_CACHE_DIR)) {
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path (Get-Location) ".zig-cache"
}

# A batch file, because `cmd /c` runs only the first line of a multi-line string. It is plain ASCII,
# whatever the code page: every path reaches it through the environment the child inherits (the
# variables set above, and the three below).
$bootstrap = @'
@echo off
echo Bootstrap: "%~f0"
call "%NOCTTY_DEV_VSDEVCMD%" -arch=%NOCTTY_DEV_ARCH% || exit /b 1
set "PATH=%NOCTTY_DEV_PATH%;%PATH%"
echo == Versions ==
where git || exit /b 1
where cl || exit /b 1
where link || exit /b 1
where rc || exit /b 1
where zig || exit /b 1
git --version || exit /b 1
zig version || exit /b 1
cl 2>&1 | findstr /c:"Version" || exit /b 1
echo == WSL ==
if "%DEV_WINDOWS_CHECK_WSL%"=="1" (
wsl.exe --status || exit /b 1
wsl.exe -l -v || exit /b 1
) else (
echo skipped ^(set DEV_WINDOWS_CHECK_WSL=1 to probe WSL^)
)
'@

$bootstrapPath = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-dev-windows-" + [guid]::NewGuid().ToString("N") + ".cmd")
$env:NOCTTY_DEV_VSDEVCMD = $vsDevCmd
$env:NOCTTY_DEV_ARCH = $Architecture
$env:NOCTTY_DEV_PATH = "$gitCmd;$gitUsrBin;$env:ZIG_HOME"
try {
    [System.IO.File]::WriteAllText($bootstrapPath, $bootstrap.Replace("`r`n", "`n").Replace("`n", "`r`n"), [System.Text.Encoding]::ASCII)
    # A raw argument string, not PowerShell's native-argument quoting: 5.1 and 7 quote
    # differently, and both leave a path without spaces unquoted, so an `&` in it (a
    # profile named A&B) started a new command, which could even exit 0. With /s, cmd
    # removes only the outer pair of quotes and reads the path inside its own, where
    # &, ^, parentheses and spaces are literal. No `call`: it expands % a second time.
    $cmdInfo = New-Object System.Diagnostics.ProcessStartInfo
    $cmdInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $cmdInfo.Arguments = '/d /s /c ""' + $bootstrapPath + '""'
    $cmdInfo.UseShellExecute = $false
    $cmdProcess = [System.Diagnostics.Process]::Start($cmdInfo)
    $cmdProcess.WaitForExit()
    $bootstrapExit = $cmdProcess.ExitCode
    $cmdProcess.Dispose()
} finally {
    Remove-Item -LiteralPath $bootstrapPath -Force -ErrorAction Ignore
    Remove-Item -LiteralPath Env:NOCTTY_DEV_VSDEVCMD, Env:NOCTTY_DEV_ARCH, Env:NOCTTY_DEV_PATH -ErrorAction Ignore
}
# A script run with -File exits 0 when it ends normally, whatever its last native command returned.
if ($bootstrapExit -ne 0) { throw "The Visual Studio developer shell bootstrap failed with exit code $bootstrapExit." }
