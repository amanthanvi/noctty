function Invoke-ReleaseGenerator {
    param([string] $Generator, [hashtable] $Parameters)
    $request = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Parameters | ConvertTo-Json -Compress)))
    $scriptPath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Generator))
    $command = "`$ErrorActionPreference='Stop'; `$PSStyle.OutputRendering='PlainText'; `$p=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$request')) | ConvertFrom-Json -AsHashtable); `$g=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptPath')); & `$g @p; if (-not `$?) { exit 1 }; exit 0"
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment.Clear()
    foreach ($name in @('SystemRoot','WINDIR','SystemDrive','TEMP','TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $start.Environment[$name] = $value }
    }
    # Only OS/runtime/temp locations are inherited. No PATH, user profiles,
    # package configuration or arbitrary runner variables reach candidate code.
    $start.Environment['NO_COLOR'] = '1'
    foreach ($argument in @('-NoProfile','-NonInteractive','-OutputFormat','Text','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $start
    try {
        if (-not $child.Start()) { throw 'Package-manager generator could not start.' }
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $child.WaitForExit()
        [void]$stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($child.ExitCode -ne 0) {
            # At most eight lines/2048 chars; remove terminal controls and
            # recognizable GitHub token forms before emitting diagnostics.
            $tail = (@($errorText -split '\r?\n' | Where-Object { $_.Length }) | Select-Object -Last 8) -join "`n"
            $tail = [regex]::Replace($tail, '[\x00-\x08\x0B-\x1F\x7F]', '')
            $tail = [regex]::Replace($tail, '(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)', '[REDACTED]')
            if ($tail.Length -gt 2048) { $tail = $tail.Substring($tail.Length - 2048) }
            throw "Package-manager generator failed (exit $($child.ExitCode)). Child stderr tail: $tail"
        }
    } finally { $child.Dispose() }
}
