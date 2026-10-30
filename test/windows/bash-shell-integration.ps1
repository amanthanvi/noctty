param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$BashPath = ''
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'bash-shell-integration.ps1'
try {


# Runs src/shell-integration/bash/ghostty.bash in Git for Windows' bash over a
# pipe and reads back what it writes. It covers what the Zig tests cannot reach:
# the status in OSC 133;D, the PATH feature, and the working directory in OSC 7
# as noctty reads it. Nothing here touches the user's bash files: HOME is a
# scratch folder, there is no profile, and history goes to /dev/null.

$ErrorActionPreference = 'Stop'
$script:AssertionCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:AssertionCount++
}

function Find-GitBash {
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $root) { continue }
        $candidate = Join-Path $root 'Git\bin\bash.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $candidate = Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw 'Git for Windows bash.exe not found; pass -BashPath.'
}

if (-not $BashPath) { $BashPath = Find-GitBash }
$script:Integration = Join-Path $RepoRoot 'src\shell-integration\bash\ghostty.bash'
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('noctty-bash-si-' + [guid]::NewGuid().ToString('n'))

# Start bash with the integration as its rcfile, feed it `Stdin`, and return
# what it wrote (stdout and stderr together) as text with the controls kept.
function Invoke-Bash {
    param(
        [string]$Stdin,
        [string]$RcFile = $script:Integration,
        [string]$WorkingDirectory = $script:TempDir,
        [string]$StartPwd = '',
        [hashtable]$ExtraEnv = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $BashPath
    $psi.Arguments = '--noprofile --rcfile "' + $RcFile + '" -i'
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(28591)
    $psi.StandardErrorEncoding = [System.Text.Encoding]::GetEncoding(28591)
    $vars = $psi.EnvironmentVariables
    foreach ($name in @('PROMPT_COMMAND', 'GHOSTTY_BASH_INJECT', 'BASH_ENV', 'ENV', 'OLDPWD')) {
        if ($vars.ContainsKey($name)) { $vars.Remove($name) }
    }
    $vars['HOME'] = Join-Path $script:TempDir 'home'
    $vars['HISTFILE'] = '/dev/null'
    $vars['PS1'] = '$ '
    $vars['GHOSTTY_SHELL_FEATURES'] = 'cursor,path,title'
    $vars['GHOSTTY_BIN_DIR'] = 'C:\Program Files\noctty'
    # noctty exports the starting directory as a Windows path.
    if ($StartPwd) { $vars['PWD'] = $StartPwd }
    foreach ($key in $ExtraEnv.Keys) { $vars[$key] = $ExtraEnv[$key] }

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.NewLine = "`n"
        $process.StandardInput.Write($Stdin)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            throw 'bash did not exit within 60 s'
        }
        return $stdout.Result + $stderr.Result
    } finally {
        $process.Dispose()
    }
}

# The start of what bash wrote, with controls made visible, for failure messages.
function Show-Output {
    param([string]$Output)
    $head = $Output.Substring(0, [Math]::Min($Output.Length, 700))
    return ($head -replace '', '<ESC>' -replace '', '<BEL>' -replace "`r", '<CR>' -replace "`n", '<LF>')
}

function Get-ExitStatuses {
    param([string]$Output)
    return @([regex]::Matches($Output, "\x1b\]133;D;(\d+);") | ForEach-Object { [int]$_.Groups[1].Value })
}

function Get-Osc7 {
    param([string]$Output)
    return @([regex]::Matches($Output, "\x1b\]7;kitty-shell-cwd://([^/\x07]*)(/[^\x07]*)\x07") |
        ForEach-Object { , @($_.Groups[1].Value, $_.Groups[2].Value) })
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:TempDir 'home') | Out-Null
    $cwd = Join-Path $script:TempDir 'a b#c%d'
    New-Item -ItemType Directory -Force -Path $cwd | Out-Null

    # 133;D carries the command's own status: false -> 1, exit 7 -> 7, true -> 0
    # (the positive control: a constant 0 would pass the last one alone).
    $commands = "false`nsh -c 'exit 7'`ntrue`nexit`n"
    $out = Invoke-Bash -Stdin $commands
    $statuses = Get-ExitStatuses $out
    Assert-True (($statuses -join ',') -eq '1,7,0') "OSC 133;D reported '$($statuses -join ',')', expected '1,7,0' (output: $(Show-Output $out))"

    # An existing scalar PROMPT_COMMAND runs before our hook and must not
    # replace the status ($? is 0 after the assignment alone).
    $out = Invoke-Bash -Stdin $commands -ExtraEnv @{ PROMPT_COMMAND = 'GHOSTTY_TEST_RUNS=1; true' }
    $statuses = Get-ExitStatuses $out
    Assert-True (($statuses -join ',') -eq '1,7,0') "With a scalar PROMPT_COMMAND, OSC 133;D reported '$($statuses -join ',')', expected '1,7,0' (output: $(Show-Output $out))"

    # An exported array PROMPT_COMMAND is declared `-ax`; sourcing twice (a
    # profile that loads the integration again) must hook once.
    $rc = Join-Path $script:TempDir 'array.rc'
    $integration = $script:Integration.Replace('\', '/')
    [System.IO.File]::WriteAllText($rc, "declare -ax PROMPT_COMMAND=(true)`nsource `"$integration`"`nsource `"$integration`"`n")
    $out = Invoke-Bash -Stdin ($commands.Replace("exit`n", "echo HOOKS:`${#PROMPT_COMMAND[@]}:`${PROMPT_COMMAND[*]}`nexit`n")) -RcFile $rc
    $statuses = Get-ExitStatuses $out
    # The echo that reads PROMPT_COMMAND back is a fourth command, and succeeds.
    Assert-True (($statuses -join ',') -eq '1,7,0,0') "With an exported array PROMPT_COMMAND, OSC 133;D reported '$($statuses -join ',')', expected '1,7,0,0'"
    $hooks = [regex]::Match($out, 'HOOKS:(\d+):([^\r\n]*)')
    Assert-True (([regex]::Matches($hooks.Groups[2].Value, '__ghostty_hook')).Count -eq 1) "Sourcing twice installed the hook more than once: '$($hooks.Groups[2].Value)'"
    Assert-True ($hooks.Groups[1].Value -eq '2') "The array PROMPT_COMMAND should hold the user's entry and the hook, held '$($hooks.Groups[1].Value)'."

    # The PATH feature must not split C:\Program Files\noctty at its colon.
    $out = Invoke-Bash -Stdin "echo PATHLIST:`$PATH`nexit`n"
    $entries = ([regex]::Match($out, 'PATHLIST:([^\r\n]*)').Groups[1].Value) -split ':'
    Assert-True ($entries.Count -gt 1) 'Could not read PATH back from bash.'
    Assert-True (-not ($entries -contains 'C')) 'PATH gained a relative "C" entry.'
    Assert-True (-not ($entries | Where-Object { $_ -like '*noctty' })) 'PATH gained a noctty entry from the Windows GHOSTTY_BIN_DIR.'

    # The working directory, starting from the Windows PWD noctty exports, and
    # after cd to a drive mount and to a directory outside any drive.
    $out = Invoke-Bash -StartPwd $cwd -WorkingDirectory $cwd -Stdin "echo PWDNOW:`$PWD`ncd /tmp`ncd /`nexit`n"
    $posix = [regex]::Match($out, 'PWDNOW:([^\r\n]*)').Groups[1].Value
    Assert-True ($posix.StartsWith('/')) "PWD stayed a Windows path: '$posix'"
    $reports = @(Get-Osc7 $out)
    Assert-True ($reports.Count -ge 3) "Expected an OSC 7 for the start and each cd, got $($reports.Count)."
    # Compare the tail only: a runner's TEMP can be an 8.3 name that bash resolves.
    Assert-True ($reports[0][1].EndsWith('/a b#c%d')) "First OSC 7 path was '$($reports[0][1])', expected the start directory"
    Assert-True ($reports[0][0] -ne '') 'OSC 7 lost its host.'
    foreach ($report in $reports) {
        # noctty reads only `/X:/...` as a Windows directory; `/c/...` is a WSL path.
        Assert-True ($report[1] -match '^/[A-Z]:/') "OSC 7 path '$($report[1])' is not in the /X:/... form."
    }

    # A directory name is untrusted text. Git Bash shows the U+F001-U+F01F that
    # a Windows name holds for control bytes as raw bytes in $PWD, so an
    # unstripped BEL and ESC would end the OSC 7 and send an OSC 52. The report
    # must name the real directory, and the host name loses its controls too.
    $sohName = 'z' + [char]0xF001 + 'q'
    $escName = 'x' + [char]0xF007 + [char]0xF01B + ']52;c;SGVsbG8=' + [char]0xF007
    foreach ($name in @($sohName, $escName)) {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:TempDir $name) | Out-Null
    }
    # Git's own prompt from /etc/bash.bashrc prints $PWD raw in its title and
    # is not noctty's, so the first line replaces it. The host name changes
    # only after the SOH directory: its ESC would cut that report short.
    $stdin = "PS1='`$ '`necho PWDNOW:`$PWD`ncd z*`nHOSTNAME=`$'h\e]52;c;SGk=\a'`ncd ../x*`nexit`n"
    $out = Invoke-Bash -StartPwd $script:TempDir -WorkingDirectory $script:TempDir -Stdin $stdin
    # Started from /tmp (where Git Bash mounts TEMP), cd would take the cygpath
    # branch, which never passed the raw bytes on.
    $posix = [regex]::Match($out, 'PWDNOW:([^\r\n]*)').Groups[1].Value
    Assert-True ($posix -match '^/[a-z]/') "The control-byte case did not start on a drive mount: '$posix'"
    Assert-True (-not $out.Contains("$([char]27)]52;")) "A directory or host name sent an OSC 52 (output: $(Show-Output $out))"
    foreach ($body in [regex]::Matches($out, "\x1b\]7;([^\x07\x1b]*)")) {
        Assert-True ($body.Groups[1].Value -notmatch '[\x00-\x1f\x7f]') "An OSC 7 carried a control byte: '$(Show-Output $body.Groups[1].Value)'"
    }
    # bash's output is read as Latin-1, so match the UTF-8 bytes of each name.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $osc7 = @(Get-Osc7 $out)
    foreach ($name in @($sohName, $escName)) {
        $tail = '/' + $latin1.GetString([System.Text.Encoding]::UTF8.GetBytes($name))
        $named = @($osc7 | Where-Object { $_[1].EndsWith($tail) })
        Assert-True ($named.Count -eq 1) "No OSC 7 named the directory '$(Show-Output $tail)' (output: $(Show-Output $out))"
    }
    # `cd ../x*` is the last cd, so the last report is the ESC directory's,
    # sent after the host name changed.
    Assert-True ($osc7[-1][0] -ceq 'h]52;c;SGk=') "OSC 7 host was '$(Show-Output $osc7[-1][0])', expected the host name without its controls"

    # Standalone Cygwin mounts a drive only under /cygdrive and resolves any
    # other absolute path under its own root. A stand-in cygpath models that, so
    # /cygdrive/c/.../z<SOH>q must report the directory that /c/... reported.
    $cygwinBin = Join-Path $script:TempDir 'cygwin-bin'
    New-Item -ItemType Directory -Force -Path $cygwinBin | Out-Null
    $standIn = @(
        '#!/bin/sh'
        'for p; do :; done'
        'case $p in'
        '/cygdrive/?/*) exec /usr/bin/cygpath -m -- "${p#/cygdrive}" ;;'
        '*) echo "C:/cygwin64$p" ;;'
        'esac'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $cygwinBin 'cygpath'), $standIn + "`n")
    $stdin = "PS1='`$ '`nbin=`$PWD/cygwin-bin`ncd z*`nPATH=`$bin:`$PATH PWD=/cygdrive`$PWD`nexit`n"
    $osc7 = @(Get-Osc7 (Invoke-Bash -StartPwd $script:TempDir -WorkingDirectory $script:TempDir -Stdin $stdin))
    Assert-True ($osc7.Count -eq 3 -and $osc7[2][1] -ceq $osc7[1][1]) "A /cygdrive directory with a control byte was not reported as the real one: $(($osc7 | ForEach-Object { Show-Output $_[1] }) -join ' | ')"

    # Normalising the Windows PWD keeps a junction in the path and leaves
    # OLDPWD as it was, set or not.
    $real = Join-Path $script:TempDir 'real'
    New-Item -ItemType Directory -Force -Path (Join-Path $real 'inner') | Out-Null
    $junction = Join-Path $script:TempDir 'jn'
    & cmd.exe /c mklink /J "$junction" "$real" | Out-Null
    Assert-True (Test-Path -LiteralPath $junction) 'Could not create the junction for the PWD case.'
    $start = Join-Path $junction 'inner'
    $probe = "echo PWDNOW:`$PWD OLD:`${OLDPWD-unset}`nexit`n"
    $out = Invoke-Bash -StartPwd $start -WorkingDirectory $start -Stdin $probe
    $line = [regex]::Match($out, 'PWDNOW:(\S*) OLD:(\S*)')
    Assert-True ($line.Groups[1].Value.EndsWith('/jn/inner')) "The junction was resolved: PWD is '$($line.Groups[1].Value)'"
    Assert-True ($line.Groups[2].Value -eq 'unset') "OLDPWD was set to '$($line.Groups[2].Value)' although the shell inherited none."
    $out = Invoke-Bash -StartPwd $start -WorkingDirectory $start -Stdin $probe -ExtraEnv @{ OLDPWD = '/usr/bin' }
    $line = [regex]::Match($out, 'PWDNOW:(\S*) OLD:(\S*)')
    Assert-True ($line.Groups[2].Value -eq '/usr/bin') "The inherited OLDPWD became '$($line.Groups[2].Value)'."

    Write-Output "PASS bash-shell-integration ($script:AssertionCount assertions)"
} finally {
    # Remove the junction itself first, never what it points to.
    $junctionPath = Join-Path $script:TempDir 'jn'
    if (Test-Path -LiteralPath $junctionPath) { [System.IO.Directory]::Delete($junctionPath) }
    if (Test-Path -LiteralPath $script:TempDir) {
        $root = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $target = [System.IO.Path]::GetFullPath($script:TempDir)
        if ($target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path $target -Leaf) -like 'noctty-bash-si-*') {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
