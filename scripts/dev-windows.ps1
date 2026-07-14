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

foreach ($candidateRoot in @($programFilesX86, $programFiles)) {
    foreach ($edition in @("BuildTools", "Community", "Professional", "Enterprise")) {
        $candidate = Join-Path $candidateRoot "Microsoft Visual Studio\2022\$edition\Common7\Tools\VsDevCmd.bat"
        if (Test-Path -LiteralPath $candidate) {
            $vsDevCmd = $candidate
            break
        }
    }
    if ($vsDevCmd) { break }
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
    throw "Missing VS Dev shell bootstrap. Install Visual Studio 2022 Build Tools with the C++ workload."
}
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

$bootstrap = @"
call "$vsDevCmd" -arch=$Architecture || exit /b 1
set "PATH=$gitCmd;$gitUsrBin;$env:ZIG_HOME;%PATH%"
set "APPDATA=$env:APPDATA"
set "LOCALAPPDATA=$env:LOCALAPPDATA"
set "TEMP=$env:TEMP"
set "TMP=$env:TMP"
set "ZIG_GLOBAL_CACHE_DIR=$env:ZIG_GLOBAL_CACHE_DIR"
set "ZIG_LOCAL_CACHE_DIR=$env:ZIG_LOCAL_CACHE_DIR"
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
"@

cmd.exe /d /c $bootstrap
