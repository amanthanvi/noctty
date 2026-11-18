function Invoke-ReleaseGenerator {
    param([string] $Generator, [hashtable] $Parameters)
    $request = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Parameters | ConvertTo-Json -Compress)))
    $scriptPath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Generator))
    $command = "`$ErrorActionPreference='Stop'; `$p=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$request')) | ConvertFrom-Json -AsHashtable); `$g=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptPath')); & `$g @p; if (-not `$?) { exit 1 }; exit 0"
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($name in @('GH_TOKEN','GITHUB_TOKEN','SCOOP_BUCKET_TOKEN','WINGET_CREATE_GITHUB_TOKEN','WINGETCREATE_TOKEN','CHOCO_API_KEY')) {
        [void]$start.Environment.Remove($name)
    }
    foreach ($argument in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $start
    try {
        if (-not $child.Start()) { throw 'Package-manager generator could not start.' }
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $child.WaitForExit()
        # Candidate output is deliberately not printed: it is untrusted and may
        # contain inherited noncredential environment data or filesystem paths.
        [void]$stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($child.ExitCode -ne 0) { throw "Package-manager generator failed (exit $($child.ExitCode))." }
    } finally { $child.Dispose() }
}
