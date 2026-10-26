# Raw measurement builds only. No portable staging, config changes, or app launches.
# Source is exactly HEAD plus apply_aumid_isolate.py. The explicit product
# toast notifier stays unchanged to retain the command-finish release gate.
# Generations are keyed by HEAD; stale/failed trees and old evidence are preserved.

function Get-InteractiveWin11MeasureLayout {
    param([Parameter(Mandatory)] [string] $RepoRoot, [string] $Head)

    $repo = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($Head)) { $Head = Get-InteractiveWin11MeasureHead $repo }
    if ($Head -notmatch '^[0-9a-f]{40,64}$') { throw 'Invalid measurement generation HEAD.' }
    $root = Join-Path $repo ".sandbox\interactive-measure\$Head"
    [pscustomobject]@{
        Repo = $repo
        Head = $Head
        Root = $root
        Source = Join-Path $root 'source'
        Archive = Join-Path $root 'head.zip'
        SourceReceipt = Join-Path $root 'source.json'
        Receipt = Join-Path $root 'build.json'
        Prefix = Join-Path $root 'prefix'
        Cache = Join-Path $root '.zig-cache'
        Exe = Join-Path $root 'prefix\bin\noctty.exe'
        Cli = Join-Path $root 'prefix\bin\noctty.com'
    }
}

function Get-InteractiveWin11MeasureExePath {
    param([Parameter(Mandatory)] [string] $RepoRoot)

    return (Get-InteractiveWin11MeasureLayout -RepoRoot $RepoRoot).Exe
}

function Get-InteractiveWin11MeasureBuildArguments {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Optimize)

    # Custom shaders, as every release ships: the job's shader leaves run this
    # build too, so they never fall back to a product-AUMID build of their own.
    return @('-Demit-exe=true', '-Dcustom-shaders=true', "-Doptimize=$Optimize")
}

function Assert-InteractiveWin11MeasurePlainPath {
    param([Parameter(Mandatory)] [string] $Path)

    # Check ancestors too: a junction at .sandbox must not redirect writes.
    $itemPath = [IO.Path]::GetFullPath($Path)
    while ($itemPath) {
        if (Test-Path -LiteralPath $itemPath) {
            $item = Get-Item -LiteralPath $itemPath -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Measurement paths must not contain reparse points.'
            }
        }
        $itemPath = [IO.Path]::GetDirectoryName($itemPath)
    }
}

function Get-InteractiveWin11MeasureHash {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-InteractiveWin11MeasureGit {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    # Native argument quoting, never shell interpretation (also works on PS 5.1).
    $quoted = foreach ($arg in (@('-C', $RepoRoot) + $Arguments)) {
        '"' + ([regex]::Replace([regex]::Replace($arg, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $info.Arguments = $quoted -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $buffer = New-Object IO.MemoryStream
    try {
        [void] $process.Start()
        $process.StandardInput.Close()
        $errorRead = $process.StandardError.ReadToEndAsync()
        $process.StandardOutput.BaseStream.CopyTo($buffer)
        $process.WaitForExit()
        [void] $errorRead.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            # Do not emit arbitrary git diagnostics or configuration.
            throw "Measurement git operation failed (exit $($process.ExitCode))."
        }
        return ,$buffer.ToArray()
    }
    finally { $buffer.Dispose(); $process.Dispose() }
}

function Get-InteractiveWin11MeasureHead {
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $head = [Text.Encoding]::UTF8.GetString((Invoke-InteractiveWin11MeasureGit $RepoRoot @('rev-parse', '--verify', 'HEAD'))).Trim()
    if ($head -notmatch '^[0-9a-f]{40,64}$') { throw 'Invalid measurement HEAD.' }
    return $head
}

function Assert-InteractiveWin11MeasureOriginal {
    param([Parameter(Mandatory)] $Layout, [Parameter(Mandatory)] [string] $Head)

    if ((Get-InteractiveWin11MeasureHead $Layout.Repo) -cne $Head) { throw 'Measurement HEAD changed; preserve this tree and use a fresh task directory.' }
    $status = Invoke-InteractiveWin11MeasureGit $Layout.Repo @('status', '--porcelain=v1', '--untracked-files=all')
    if ($status.Length -ne 0) { throw 'Measurement provenance requires a clean checkout at HEAD (including untracked files).' }
    foreach ($relativePath in @('src/apprt/win32_aumid.zig', 'src/apprt/win32/app.zig')) {
        $originalPath = Join-Path $Layout.Repo $relativePath
        Assert-InteractiveWin11MeasurePlainPath $originalPath
        $original = [IO.File]::ReadAllBytes($originalPath)
        $committed = Invoke-InteractiveWin11MeasureGit $Layout.Repo @('show', "${Head}:$relativePath")
        if ((Get-InteractiveWin11MeasureHash $original) -cne (Get-InteractiveWin11MeasureHash $committed)) {
            throw "Original identity source is not byte-identical to HEAD: $relativePath"
        }
    }
}

function Assert-InteractiveWin11MeasureProductNotifierSource {
    param([Parameter(Mandatory)] [byte[]] $Original)

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $text = $utf8.GetString($Original)
    $anchor = 'const aumid_utf16 = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");'
    if ([regex]::Matches($text, [regex]::Escape($anchor)).Count -ne 1) { throw 'Measurement toast notifier anchor changed.' }
    $call = 'win32_toast_winrt.WinrtToast.init(core_app.alloc, aumid_utf16)'
    if ([regex]::Matches($text, [regex]::Escape($call)).Count -ne 1) { throw 'Product toast notifier call changed.' }
}

function Get-InteractiveWin11MeasurePatchedBytes {
    param([Parameter(Mandatory)] [byte[]] $Original)

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $text = $utf8.GetString($Original)
    $old = 'pub const aumid_utf8 = "io.github.amanthanvi.noctty";'
    $oldWide = 'utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");'
    foreach ($anchor in @($old, $oldWide)) {
        if ([regex]::Matches($text, [regex]::Escape($anchor)).Count -ne 1) { throw 'Measurement AUMID constant anchor changed.' }
    }
    $signature = 'pub fn registerAumidDisplayName\(alloc: std\.mem\.Allocator(?:, portable: bool)?\) void \{\n'
    if ([regex]::Matches($text, $signature).Count -ne 1) { throw 'Measurement registration signature changed.' }
    $text = $text.Replace($old, 'pub const aumid_utf8 = "io.github.amanthanvi.noctty.measure";')
    $text = $text.Replace($oldWide, 'utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty.measure");')
    $text = [regex]::Replace($text, $signature, ('$0' + "    if (true) return; // MEASUREMENT ONLY`n"))
    return ,$utf8.GetBytes($text)
}

function Get-InteractiveWin11MeasureFiles {
    param([Parameter(Mandatory)] [string] $Root)

    # The caller checks Root and its ancestors. Enumerate each directory only
    # after checking its attributes; recursive enumeration could follow a link.
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = [IO.DirectoryInfo]::new($pending.Pop())
        foreach ($item in $directory.EnumerateFileSystemInfos()) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Measurement tree contains a reparse point.' }
            if ($item.Attributes -band [IO.FileAttributes]::Directory) { $pending.Push($item.FullName) }
            else { $item.FullName }
        }
    }
}

function Assert-InteractiveWin11MeasureSource {
    param([Parameter(Mandatory)] $Layout, [Parameter(Mandatory)] [string] $Head)

    Assert-InteractiveWin11MeasurePlainPath $Layout.Root
    Assert-InteractiveWin11MeasurePlainPath $Layout.Source
    Assert-InteractiveWin11MeasurePlainPath $Layout.SourceReceipt
    Assert-InteractiveWin11MeasurePlainPath $Layout.Archive
    $sourceReceipt = Get-Content -LiteralPath $Layout.SourceReceipt -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($sourceReceipt.Schema -ne 2 -or $sourceReceipt.Head -cne $Head -or
        $sourceReceipt.Patch -cne 'aumid-isolate-product-toast-v2' -or $sourceReceipt.NotifierAumid -cne 'io.github.amanthanvi.noctty') {
        throw 'Stale or unrecognized measurement source receipt; use a fresh task directory.'
    }
    # Recreate the archive from the live git object, so a modified manifest or
    # archive cannot bless a changed file. Hash every extracted source file.
    $archiveBytes = Invoke-InteractiveWin11MeasureGit $Layout.Repo @('archive', '--format=zip', $Head)
    $archiveHash = Get-InteractiveWin11MeasureHash $archiveBytes
    if ($sourceReceipt.ArchiveSHA256 -cne $archiveHash -or
        (Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($Layout.Archive))) -cne $archiveHash) {
        throw 'Measurement archive does not match current HEAD.'
    }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $stream = New-Object IO.MemoryStream(,$archiveBytes)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
    # Validate every source descendant before opening any source file. The
    # complete set also detects missing and unexpected files without repeating
    # the provider/ancestor walk for each of several thousand archived files.
    $remaining = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $expected = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $sha = [Security.Cryptography.SHA256]::Create()
    $sourcePrefix = $Layout.Source + [IO.Path]::DirectorySeparatorChar
    $originalHash = $null
    $patchedHash = $null
    $originalNotifierHash = $null
    $measuredNotifierHash = $null
    try {
        foreach ($file in (Get-InteractiveWin11MeasureFiles $Layout.Source)) { [void] $remaining.Add($file) }
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $path = [IO.Path]::GetFullPath([IO.Path]::Combine($Layout.Source, $entry.FullName))
            if (-not $path.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase) -or -not $expected.Add($path)) {
                throw 'Invalid or duplicate measurement archive path.'
            }
            if (-not $remaining.Remove($path)) { throw "Missing measurement source file: $($entry.FullName)" }
            $entryStream = $entry.Open()
            try {
                if ($entry.FullName -ceq 'src/apprt/win32_aumid.zig' -or $entry.FullName -ceq 'src/apprt/win32/app.zig') {
                    $bytes = [IO.MemoryStream]::new()
                    try { $entryStream.CopyTo($bytes); $wanted = $bytes.ToArray() }
                    finally { $bytes.Dispose() }
                    if ($entry.FullName -ceq 'src/apprt/win32_aumid.zig') {
                        $originalHash = Get-InteractiveWin11MeasureHash $wanted
                        $wanted = Get-InteractiveWin11MeasurePatchedBytes $wanted
                        $patchedHash = Get-InteractiveWin11MeasureHash $wanted
                    }
                    else {
                        $originalNotifierHash = Get-InteractiveWin11MeasureHash $wanted
                        Assert-InteractiveWin11MeasureProductNotifierSource $wanted
                        $measuredNotifierHash = $originalNotifierHash
                    }
                    $wantedHash = [Convert]::ToBase64String($sha.ComputeHash($wanted))
                }
                else { $wantedHash = [Convert]::ToBase64String($sha.ComputeHash($entryStream)) }
            }
            finally { $entryStream.Dispose() }
            $actualStream = [IO.File]::OpenRead($path)
            try { $actualHash = [Convert]::ToBase64String($sha.ComputeHash($actualStream)) }
            finally { $actualStream.Dispose() }
            if ($actualHash -cne $wantedHash) {
                throw "Measurement source differs from the expected HEAD plus AUMID patch: $($entry.FullName)"
            }
        }
        if ($remaining.Count -ne 0) { throw 'Unexpected file in measurement source tree.' }
        if (-not $originalHash -or -not $originalNotifierHash -or
            $sourceReceipt.OriginalAumidSHA256 -cne $originalHash -or $sourceReceipt.PatchedAumidSHA256 -cne $patchedHash -or
            $sourceReceipt.OriginalNotifierSHA256 -cne $originalNotifierHash -or $sourceReceipt.MeasuredNotifierSHA256 -cne $measuredNotifierHash) {
            throw 'Measurement source patch hashes do not match HEAD.'
        }
    }
    finally { $sha.Dispose(); $zip.Dispose(); $stream.Dispose() }
    return $sourceReceipt
}

function Assert-InteractiveWin11MeasureBuildCore {
    param([Parameter(Mandatory)] $Layout, [Parameter(Mandatory)] [string] $ExePath)

    if (-not ([IO.Path]::GetFullPath($ExePath)).Equals($Layout.Exe, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Measurement validation requires the raw measurement prefix executable.'
    }
    $head = Get-InteractiveWin11MeasureHead $Layout.Repo
    if ($Layout.Head -cne $head) { throw 'Measurement generation does not match current HEAD.' }
    Assert-InteractiveWin11MeasureOriginal $Layout $head
    $source = Assert-InteractiveWin11MeasureSource $Layout $head
    Assert-InteractiveWin11MeasurePlainPath $Layout.Receipt
    Assert-InteractiveWin11MeasurePlainPath $Layout.Exe
    Assert-InteractiveWin11MeasurePlainPath $Layout.Cli
    $receipt = Get-Content -LiteralPath $Layout.Receipt -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($receipt.Schema -ne 3 -or $receipt.State -cne 'complete' -or $receipt.Head -cne $head -or
        $receipt.BuildArguments -cne ((Get-InteractiveWin11MeasureBuildArguments ([string] $receipt.Optimize)) -join ' ') -or
        $receipt.Aumid -cne 'io.github.amanthanvi.noctty.measure' -or $receipt.Patch -cne $source.Patch -or
        $receipt.NotifierAumid -cne $source.NotifierAumid -or
        $receipt.ArchiveSHA256 -cne $source.ArchiveSHA256 -or
        $receipt.OriginalAumidSHA256 -cne $source.OriginalAumidSHA256 -or
        $receipt.PatchedAumidSHA256 -cne $source.PatchedAumidSHA256 -or
        $receipt.OriginalNotifierSHA256 -cne $source.OriginalNotifierSHA256 -or
        $receipt.MeasuredNotifierSHA256 -cne $source.MeasuredNotifierSHA256 -or
        $receipt.SourceReceiptSHA256 -cne (Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($Layout.SourceReceipt))) -or
        $receipt.RepoRoot -cne $Layout.Repo -or $receipt.ExePath -cne $Layout.Exe -or
        $receipt.CliPath -cne $Layout.Cli -or
        $receipt.CliSHA256 -cne (Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($Layout.Cli))) -or
        $receipt.ExeSHA256 -cne (Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($Layout.Exe)))) {
        throw 'Measurement build receipt does not match HEAD, source patch, or executable.'
    }
    Assert-InteractiveWin11MeasureOriginal $Layout $head
}

function Assert-InteractiveWin11MeasureBuild {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $ExePath)

    $layout = Get-InteractiveWin11MeasureLayout $RepoRoot
    Assert-InteractiveWin11MeasurePlainPath $layout.Root
    Assert-InteractiveWin11MeasurePlainPath (Join-Path $layout.Root 'build.lock')
    # Readers may validate the same generation concurrently. A builder holds
    # this file exclusively until the final receipt is valid, excluding both
    # readers and other builders in either acquisition order.
    $lock = [IO.File]::Open((Join-Path $layout.Root 'build.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Assert-InteractiveWin11MeasureBuildCore $layout $ExePath }
    finally { $lock.Dispose() }
}

function Invoke-InteractiveWin11MeasureBuild {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')] [string] $Optimize = 'Debug'
    )

    $layout = Get-InteractiveWin11MeasureLayout $RepoRoot
    # These paths enter a cmd wrapper. Reject shell syntax rather than attempt
    # several layers of escaping, including percent/delayed expansion.
    if ($layout.Root -match '[\x00-\x1f"%!^&|<>]') { throw 'Unsupported cmd metacharacter in measurement repository path.' }
    Assert-InteractiveWin11MeasurePlainPath $layout.Root
    foreach ($path in @($layout.Archive, $layout.SourceReceipt, $layout.Receipt, (Join-Path $layout.Root 'build.lock'))) {
        Assert-InteractiveWin11MeasurePlainPath $path
    }
    $head = $layout.Head
    Assert-InteractiveWin11MeasureOriginal $layout $head
    [void] [IO.Directory]::CreateDirectory($layout.Root)
    $lock = [IO.File]::Open((Join-Path $layout.Root 'build.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if (-not (Test-Path -LiteralPath $layout.SourceReceipt)) {
            if ((Test-Path -LiteralPath $layout.Source) -or (Test-Path -LiteralPath $layout.Archive)) {
                throw 'Incomplete measurement extraction exists; preserve it and use a fresh task directory.'
            }
            $archive = Invoke-InteractiveWin11MeasureGit $layout.Repo @('archive', '--format=zip', $head)
            [IO.File]::WriteAllBytes($layout.Archive, $archive)
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [IO.Compression.ZipFile]::ExtractToDirectory($layout.Archive, $layout.Source)
            $sourcePath = Join-Path $layout.Source 'src\apprt\win32_aumid.zig'
            $original = [IO.File]::ReadAllBytes($sourcePath)
            $patched = Get-InteractiveWin11MeasurePatchedBytes $original
            [IO.File]::WriteAllBytes($sourcePath, $patched)
            $notifierPath = Join-Path $layout.Source 'src\apprt\win32\app.zig'
            $originalNotifier = [IO.File]::ReadAllBytes($notifierPath)
            Assert-InteractiveWin11MeasureProductNotifierSource $originalNotifier
            $sourceReceipt = [ordered]@{
                Schema = 2; Head = $head; Patch = 'aumid-isolate-product-toast-v2'
                NotifierAumid = 'io.github.amanthanvi.noctty'
                ArchiveSHA256 = Get-InteractiveWin11MeasureHash $archive
                OriginalAumidSHA256 = Get-InteractiveWin11MeasureHash $original
                PatchedAumidSHA256 = Get-InteractiveWin11MeasureHash $patched
                OriginalNotifierSHA256 = Get-InteractiveWin11MeasureHash $originalNotifier
                MeasuredNotifierSHA256 = Get-InteractiveWin11MeasureHash $originalNotifier
            }
            [IO.File]::WriteAllText($layout.SourceReceipt, ($sourceReceipt | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        }
        $source = Assert-InteractiveWin11MeasureSource $layout $head
        # Invalidate a prior success before a rebuild can fail or be interrupted.
        [IO.File]::WriteAllText($layout.Receipt, '{"Schema":3,"State":"building"}')
        $runPath = Join-Path $layout.Root 'run-build.cmd'
        $launchPath = Join-Path $layout.Root 'launch-build.cmd'
        $logPath = Join-Path $layout.Root 'build.log'
        foreach ($path in @($layout.Prefix, $layout.Cache, $runPath, $launchPath, $logPath)) { Assert-InteractiveWin11MeasurePlainPath $path }
        $buildArguments = (Get-InteractiveWin11MeasureBuildArguments $Optimize) -join ' '
        $run = @"
@echo off
cd /d "$($layout.Source)" || exit /b 1
call "$($layout.Source)\scripts\dev-windows.cmd" zig build $buildArguments --prefix "$($layout.Prefix)" <NUL
exit /b %errorlevel%
"@
        $launch = @"
@echo off
start "" /belownormal /b /wait "%SystemRoot%\System32\cmd.exe" /d /c ""$runPath"" <NUL >"$logPath" 2>&1
exit /b %errorlevel%
"@
        [IO.File]::WriteAllText($runPath, $run.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::Default)
        [IO.File]::WriteAllText($launchPath, $launch.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::Default)
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'cmd.exe'
        $info.Arguments = '/d /s /c ""' + $launchPath + '""'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.EnvironmentVariables['ZIG_LOCAL_CACHE_DIR'] = $layout.Cache
        # A redirected LOCALAPPDATA must never relocate the global Zig cache.
        if ([string]::IsNullOrWhiteSpace($info.EnvironmentVariables['ZIG_GLOBAL_CACHE_DIR'])) {
            $info.EnvironmentVariables['ZIG_GLOBAL_CACHE_DIR'] = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'zig'
        }
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        try {
            [void] $process.Start()
            $process.StandardInput.Close()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) { throw "Measurement build failed (exit $($process.ExitCode)); receipt remains invalid. Build log: $logPath" }
        }
        finally { $process.Dispose() }
        Assert-InteractiveWin11MeasureOriginal $layout $head
        [void] (Assert-InteractiveWin11MeasureSource $layout $head)
        Assert-InteractiveWin11MeasurePlainPath $layout.Exe
        Assert-InteractiveWin11MeasurePlainPath $layout.Cli
        $receipt = [ordered]@{
            Schema = 3; State = 'complete'; Head = $head; RepoRoot = $layout.Repo
            BuildArguments = $buildArguments
            Aumid = 'io.github.amanthanvi.noctty.measure'; Patch = $source.Patch
            NotifierAumid = $source.NotifierAumid
            ArchiveSHA256 = $source.ArchiveSHA256
            OriginalAumidSHA256 = $source.OriginalAumidSHA256
            PatchedAumidSHA256 = $source.PatchedAumidSHA256
            OriginalNotifierSHA256 = $source.OriginalNotifierSHA256
            MeasuredNotifierSHA256 = $source.MeasuredNotifierSHA256
            SourceReceiptSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.SourceReceipt))
            Optimize = $Optimize; ExePath = $layout.Exe
            ExeSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.Exe))
            CliPath = $layout.Cli
            CliSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.Cli))
            BuiltAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText($layout.Receipt, ($receipt | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        Assert-InteractiveWin11MeasureBuildCore $layout $layout.Exe
    }
    finally { $lock.Dispose() }
}
