#requires -Version 7.0
<#
Hidden-desktop check of `noctty +list-profiles` (LIST-PROFILES) against a real portable build: that the
command reads the configuration and the environment it is given, lists the profiles with the order and
the hidden state that configuration asks for (the picker's rules, `arrangeProfiles`, are unit-tested in
windows_shell.zig), and never prints a command line, an environment value or a working directory.
Run with -Bin <directory holding noctty.exe and noctty.com> and -Run <new evidence directory>.

Fixture, all inside -Run:
  * a portable copy (`noctty.portable`) with a `config.ghostty` of three user profiles, one hidden, a
    `profile-order` that moves two of them to the front, `visual-studio-profiles = none`, so the
    result does not depend on this machine's Visual Studio, and `default-profile` naming the profile
    that is checked for secrets, with an explicit `working-directory = home`, which together reach the
    log lines that name a command. That profile has a command line, a variable and a working directory
    made of marker words;
  * a PATH of one folder holding copies of cmd.exe named pwsh.exe and ssh.exe (found, never run) and no
    wsl.exe, so discovery never starts WSL; cmd.exe and powershell.exe come from the system folder;
  * a USERPROFILE (a folder named with a marker word) with a `.ssh\config` of two hosts.
Git Bash is listed when this machine has Git for Windows (the registry says so), and is not required.

Checks: exit codes; four tab-separated fields per line when stdout is a file; the order and the fields of
the profiles; `--plain` equal to the redirected default; `--format=json` parsed and equal in order to the
text; no marker word, and no decimal or hex form of one (how a byte string prints as a list of numbers),
in stdout or stderr of any run; no WSL profile; bad arguments exit 1 with nothing on stdout. One run has
`GHOSTTY_LOG=stderr`, which turns on the log that actions switch off: its stderr must hold the log lines
that prove the command was resolved (`shell src=config value=`), say how big the command was and not
what it was, and the list on stdout must be the same. A last run has a `theme = light:A,dark:B` whose files
hide different shells: the command must list the one for the scheme Windows reports for apps (the registry
value is read here, never written; the app applies that scheme before its first window, and this machine's
scheme decides which half the check covers). The aligned table needs a console and is covered by the unit
tests.

A CLI action returns before the app creates a window, an AUMID or a jump list, so any build works here.
Every process starts on a private desktop named in STARTUPINFO, inside a job this script owns, with
LOCALAPPDATA and APPDATA redirected into the run directory. Nothing is typed and nothing can copy; the
clipboard sequence number, the real startup-attempts.json and the real PSReadLine history files'
metadata are checked before and after.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')

if (-not $Driver) {
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -DesktopPrefix 'noctty-lp-' `
        -TimeoutSeconds 180 -Label 'Hidden list-profiles' -PassDesktopName -GuardClipboard `
        -ExpectedStartupHash $ExpectedStartupHash -ExpectedStartupModified $ExpectedStartupModified
    exit
}

# Driver: runs only on the private desktop, inside the owned job.
$script:checks = [Collections.Generic.List[object]]::new()
function Check([string] $Case, [string] $Name, [bool] $Passed, $Expected, $Actual) {
    $script:checks.Add(@{ Case = $Case; Name = $Name; Passed = $Passed; Expected = $Expected; Actual = $Actual })
}
$desktop = "WinSta0\$DesktopName"
$fixture = Join-Path $Run 'fixture'
$fakeBin = Join-Path $fixture 'bin'
$fakeHome = Join-Path $fixture 'secret-home'
[void](New-Item -ItemType Directory -Path $fakeBin, (Join-Path $fakeHome '.ssh'))
foreach ($name in 'pwsh.exe', 'ssh.exe') { Copy-Item -LiteralPath $env:ComSpec -Destination (Join-Path $fakeBin $name) }
[IO.File]::WriteAllText((Join-Path $fakeHome '.ssh\config'), "Host build-01 prod`nHost *`n  User nobody`n")
$markers = @('secret-dir', 'secret-arg', 'SECRET_KEY', 'secret-value', 'secret-home')
[IO.File]::WriteAllText((Join-Path $Bin 'config.ghostty'), @'
working-directory = home
default-profile = py312
profile-command = py312: C:\secret-dir\py.exe --secret-arg
profile-name = py312: Python 3.12
profile-working-directory = py312: C:\secret-dir\work
profile-env = py312: SECRET_KEY=secret-value
profile-command = hid: cmd.exe /k echo hidden
profile-name = hid: Hidden Thing
profile-command = tail: cmd.exe /k echo tail
profile-name = tail: Caf{E9}
profile-hidden = hid
profile-order = tail
profile-order = py312
visual-studio-profiles = none

'@.Replace('{E9}', [string][char]0xE9))
$label = 'Caf' + [char]0xE9
$env:PATH = $fakeBin
$env:USERPROFILE = $fakeHome

$results = @{}
# `-Log` is the GHOSTTY_LOG value for this run. Without it the variable is removed, so one inherited from
# the caller cannot put log lines on stderr in the other runs.
function Invoke-ListProfiles([string] $Name, [string] $Arguments, [string] $Log = '') {
    $out = Join-Path $Run "$Name.out.txt"
    $err = Join-Path $Run "$Name.err.txt"
    if ($Log) { $env:GHOSTTY_LOG = $Log } else { Remove-Item -LiteralPath Env:GHOSTTY_LOG -ErrorAction Ignore }
    $line = '"{0}" /d /c ""{1}" +list-profiles {2} > "{3}" 2> "{4}""' -f $env:ComSpec, (Join-Path $Bin 'noctty.com'), $Arguments, $out, $err
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $pi = [HiddenLocal]::Spawn($env:ComSpec, $line, $Run, $desktop)
    $wait = [HiddenLocal]::WaitForSingleObject($pi.process, 60000)
    [uint32]$code = 99999; [void][HiddenLocal]::GetExitCodeProcess($pi.process, [ref]$code)
    if ($wait -ne 0) { [void][HiddenLocal]::TerminateProcess($pi.process, 1) }
    [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process)
    $clock.Stop()
    $result = [ordered]@{
        Name = $Name; Exit = [int]$code; Milliseconds = [int]$clock.ElapsedMilliseconds; TimedOut = ($wait -ne 0)
        Stdout = [IO.File]::ReadAllText($out); Stderr = [IO.File]::ReadAllText($err)
    }
    $script:results[$Name] = $result
    return $result
}

# A word as text, and as a byte string printed as a list of numbers: decimal and hex, separated by commas,
# spaces or nothing, as `{}` of a Zig slice or a hex dump would print it.
function Get-Forms([string] $Word) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Word)
    $decimal = @($bytes | ForEach-Object { [string]$_ })
    $hex = @($bytes | ForEach-Object { $_.ToString('x2') })
    $forms = @($Word)
    foreach ($separator in ', ', ',', ' ', '') {
        $forms += $decimal -join $separator
        $forms += $hex -join $separator
        $forms += ($hex -join $separator).ToUpperInvariant()
        $forms += ($hex | ForEach-Object { "0x$_" }) -join $separator
    }
    return $forms | Select-Object -Unique
}
$markerForms = @{}
foreach ($marker in $markers) { $markerForms[$marker] = Get-Forms $marker }

function Test-NoMarkers([string] $Name, $Result) {
    $leaked = @(foreach ($marker in $markers) {
        foreach ($form in $markerForms[$marker]) {
            if ($Result.Stdout.Contains($form) -or $Result.Stderr.Contains($form)) { "$marker as '$form'" }
        }
    })
    Check $Name 'no command line, variable or directory in the output, as text or as numbers' ($leaked.Count -eq 0) @() $leaked
}

$plain = Invoke-ListProfiles 'default' ''
Check 'default' 'exits 0 inside the time limit' ($plain.Exit -eq 0 -and -not $plain.TimedOut) 0 $plain.Exit
Check 'default' 'stderr is empty' ($plain.Stderr -eq '') '' $plain.Stderr
$rows = @($plain.Stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { , ($_ -split "`t") })
Check 'default' 'every line has four tab-separated fields' (($rows | Where-Object { $_.Count -ne 4 }).Count -eq 0 -and $rows.Count -gt 0) 4 ($rows | ForEach-Object { $_.Count })
$keys = @($rows | ForEach-Object { $_[0] })
Check 'default' 'profile-order puts its two profiles first, in its order' ($keys.Count -ge 2 -and $keys[0] -eq 'user:tail' -and $keys[1] -eq 'user:py312') 'user:tail, user:py312' ($keys[0..1] -join ', ')
Check 'default' 'the hidden profile is last and hidden' ($keys[-1] -eq 'user:hid' -and $rows[-1][3] -eq 'hidden') 'user:hid hidden' ($rows[-1] -join ' | ')
Check 'default' 'no other profile is hidden' (@($rows | Where-Object { $_[3] -eq 'hidden' }).Count -eq 1) 1 (@($rows | Where-Object { $_[3] -eq 'hidden' }).Count)
$detected = @('pwsh.exe', 'powershell.exe', 'cmd.exe', 'ssh:build-01', 'ssh:prod')
$positions = @($detected | ForEach-Object { [array]::IndexOf($keys, $_) })
Check 'default' 'the detected profiles are listed in discovery order' (-not ($positions -contains -1) -and (($positions | Sort-Object) -join ',') -eq ($positions -join ',')) ($detected -join ', ') ($keys -join ', ')
Check 'default' 'no WSL profile, because PATH has no wsl.exe' (@($keys | Where-Object { $_ -like 'wsl*' }).Count -eq 0) 0 (@($keys | Where-Object { $_ -like 'wsl*' }) -join ', ')
function Get-Row([string] $Key) { foreach ($row in $rows) { if ($row[0] -eq $Key) { return , $row } } }
Check 'default' 'user profiles say config, detected ones say detected' (
    ((Get-Row 'user:py312') -join '|') -eq 'user:py312|Python 3.12|config|shown' -and
    ((Get-Row 'user:tail') -join '|') -eq "user:tail|$label|config|shown" -and
    ((Get-Row 'pwsh.exe') -join '|') -eq 'pwsh.exe|PowerShell|detected|shown' -and
    ((Get-Row 'ssh:prod') -join '|') -eq 'ssh:prod|SSH: prod|detected|shown') 'three rows' ($rows | ForEach-Object { $_ -join '|' })
Test-NoMarkers 'default' $plain

$explicit = Invoke-ListProfiles 'plain' '--plain'
Check 'plain' '--plain prints what the redirected default prints' ($explicit.Exit -eq 0 -and $explicit.Stdout -eq $plain.Stdout) $plain.Stdout $explicit.Stdout

$json = Invoke-ListProfiles 'json' '--format=json'
Check 'json' 'exits 0 with an empty stderr' ($json.Exit -eq 0 -and $json.Stderr -eq '') '0' "$($json.Exit) $($json.Stderr)"
$document = $json.Stdout | ConvertFrom-Json
Check 'json' 'schema, completeness and the profiles in the order of the text' (
    $document.schema -eq 'noctty.profiles.v1' -and $document.complete -is [bool] -and
    (@($document.profiles | ForEach-Object key) -join ',') -eq ($keys -join ',')) ($keys -join ',') (@($document.profiles | ForEach-Object key) -join ',')
Check 'json' 'the hidden flag follows the text state' (
    (@($document.profiles | Where-Object hidden | ForEach-Object key) -join ',') -eq 'user:hid') 'user:hid' (@($document.profiles | Where-Object hidden | ForEach-Object key) -join ',')
Check 'json' 'the output is ASCII and its non-ASCII label still reads back' (
    -not ([Text.Encoding]::UTF8.GetBytes($json.Stdout) | Where-Object { $_ -ge 0x80 }) -and
    ($document.profiles | Where-Object key -eq 'user:tail').label -ceq $label) $label (($document.profiles | Where-Object key -eq 'user:tail').label)
Check 'json' 'every profile has exactly key, label, source and hidden' (
    @($document.profiles | Where-Object { (($_.PSObject.Properties.Name | Sort-Object) -join ',') -ne 'hidden,key,label,source' }).Count -eq 0) 'hidden,key,label,source' ''
Test-NoMarkers 'json' $json

$both = Invoke-ListProfiles 'json-plain' '--plain --format=json'
Check 'json-plain' '--plain does not turn JSON off' ($both.Exit -eq 0 -and $both.Stdout -eq $json.Stdout) $json.Stdout $both.Stdout

$bad = Invoke-ListProfiles 'bad-format' '--format=xml'
Check 'bad-format' 'a bad value exits 1 with nothing on stdout' ($bad.Exit -eq 1 -and $bad.Stdout -eq '' -and $bad.Stderr.StartsWith('Error parsing +list-profiles arguments:')) '1' "$($bad.Exit) $($bad.Stderr)"

$help = Invoke-ListProfiles 'help' '--help'
Check 'help' '--help prints the action help and exits 0' ($help.Exit -eq 0 -and $help.Stdout.Contains('never prints') -and $help.Stdout.Contains('--format=json')) '0' $help.Exit
Test-NoMarkers 'help' $help

# Actions switch the log off; GHOSTTY_LOG=stderr switches it back on. With a default profile and an explicit
# `working-directory = home`, `Config.finalize` logs the command it resolved.
$logged = Invoke-ListProfiles 'log' '' 'stderr'
Check 'log' 'exits 0 and lists what the run without the log lists' ($logged.Exit -eq 0 -and $logged.Stdout -eq $plain.Stdout) $plain.Stdout $logged.Stdout
Check 'log' 'the log is on, and says it resolved the default profile and its command' (
    $logged.Stderr.Contains('default shell src=default-profile key=user:py312') -and
    $logged.Stderr -match 'shell src=config value=direct <\d+ args, \d+ bytes>') 'both log lines' $logged.Stderr
Test-NoMarkers 'log' $logged

# `Config.load` leaves the config in the light conditional state, and the app applies the scheme Windows reports
# for apps before it lists anything; a theme can set profile keys, so the command has to as well. The scheme is read
# here on its own (read-only; this script never writes it), and the two theme files hide different shells. The light
# state would hide cmd.exe on a dark desktop.
$appsUseLight = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Ignore).AppsUseLightTheme
$scheme = if ($appsUseLight -is [int] -and $appsUseLight -ne 0) { 'light' } else { 'dark' }
$lightTheme = Join-Path $fixture 'theme-light.conf'
$darkTheme = Join-Path $fixture 'theme-dark.conf'
[IO.File]::WriteAllText($lightTheme, "profile-hidden = cmd.exe`n")
[IO.File]::WriteAllText($darkTheme, "profile-hidden = powershell.exe`n")
[IO.File]::WriteAllText((Join-Path $Bin 'config.ghostty'), "theme = light:$lightTheme,dark:$darkTheme`nvisual-studio-profiles = none`nssh-config-hosts = false`n")
$themed = Invoke-ListProfiles 'theme' ''
$themedRows = @($themed.Stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { , ($_ -split "`t") })
$themedHidden = @($themedRows | Where-Object { $_[3] -eq 'hidden' } | ForEach-Object { $_[0] })
$themedExpected = if ($scheme -eq 'dark') { 'powershell.exe' } else { 'cmd.exe' }
Check 'theme' "lists the $scheme theme's profile settings, the scheme Windows reports for apps" ($themed.Exit -eq 0 -and ($themedHidden -join ',') -eq $themedExpected) $themedExpected ($themedHidden -join ',')

$failed = @($script:checks | Where-Object { -not $_.Passed })
[ordered]@{ Checks = $script:checks; Runs = ($results.Values | ForEach-Object { [ordered]@{ Name = $_.Name; Exit = $_.Exit; Milliseconds = $_.Milliseconds } }) } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Run 'results.json')
foreach ($check in $script:checks) { '{0} {1}: {2}' -f ($(if ($check.Passed) { 'PASS' } else { 'FAIL' })), $check.Case, $check.Name | Add-Content -LiteralPath (Join-Path $Run 'checks.txt') }
if ($failed.Count) { exit 1 }
