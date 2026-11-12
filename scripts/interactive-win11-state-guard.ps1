# Metadata only. Known folders deliberately bypass redirected APPDATA/LOCALAPPDATA.
# No profile, jump-list, history, or clipboard contents are opened by this guard.
function Get-InteractiveWin11ClipboardSequence {
    if (-not ('InteractiveWin11StateNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class InteractiveWin11StateNative {
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
}
'@
    }
    return [InteractiveWin11StateNative]::GetClipboardSequenceNumber()
}

function Assert-InteractiveWin11StatePath {
    param([Parameter(Mandatory)] [string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full -cne $Path) {
        throw 'State guard requires an exact absolute local path.'
    }
    # Check ancestors from the drive down so even an intermediate junction is
    # refused before looking up a child through it. Missing ancestors are fine.
    $cursor = [IO.Path]::GetPathRoot($full)
    $parts = $full.Substring($cursor.Length).Split('\')
    foreach ($part in @('') + $parts) {
        if ($part) { $cursor = Join-Path $cursor $part }
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue -ErrorVariable pathError
        if ($null -eq $item) {
            if ($pathError -and $pathError[0].CategoryInfo.Category -ne 'ObjectNotFound') {
                throw 'Cannot inspect state guard path metadata.'
            }
            break
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'State guard refuses a reparse point in its path.'
        }
    }
}

function Get-InteractiveWin11StateMetadata {
    param([Parameter(Mandatory)] [string] $Path)
    Assert-InteractiveWin11StatePath -Path $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -ErrorVariable metadataError
    if ($null -eq $item) {
        if ($metadataError -and $metadataError[0].CategoryInfo.Category -ne 'ObjectNotFound') {
            throw 'Cannot inspect state file metadata.'
        }
        return [pscustomobject]@{ Exists = $false; Length = $null; LastWriteTimeUtc = $null; CreationTimeUtc = $null }
    }
    if ($item.PSIsContainer) { throw 'State guard file path is a directory.' }
    return [pscustomobject]@{
        Exists = $true
        Length = $item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        CreationTimeUtc = $item.CreationTimeUtc.ToString('o')
    }
}

function Write-InteractiveWin11StateReceipt {
    param([string] $Path, $Receipt)
    Assert-InteractiveWin11StatePath -Path $Path
    [IO.File]::WriteAllText($Path, ($Receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Start-InteractiveWin11StateGuard {
    param(
        [Parameter(Mandatory)] [string] $Harness,
        [Parameter(Mandatory)] [string] $ReceiptDirectory,
        # Explicit seams for scratch-only contract controls. Production omits them.
        [string] $LocalAppDataRoot = ([Environment]::GetFolderPath('LocalApplicationData')),
        [string] $RoamingAppDataRoot = ([Environment]::GetFolderPath('ApplicationData')),
        [scriptblock] $ClipboardSequenceReader = { Get-InteractiveWin11ClipboardSequence }
    )
    if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot) -or [string]::IsNullOrWhiteSpace($RoamingAppDataRoot)) {
        throw 'Cannot resolve real state known folders.'
    }
    $destinations = Join-Path $RoamingAppDataRoot 'Microsoft\Windows\Recent\CustomDestinations'
    $paths = [ordered]@{
        Startup = Join-Path $LocalAppDataRoot 'koreterm\startup-attempts.json'
        ProductJumpList = Join-Path $destinations 'c2214d6ebc43ff3f.customDestinations-ms'
        # Observed for io.github.richardsonvix.koreterm.measure in PR #393's
        # private-desktop batches (PR body, Validation). This exact file was
        # created and removed after those batches; never glob this directory.
        MeasureJumpList = Join-Path $destinations '251fcb42973017e3.customDestinations-ms'
    }
    $before = [ordered]@{}
    foreach ($name in $paths.Keys) { $before[$name] = Get-InteractiveWin11StateMetadata -Path $paths[$name] }
    $guard = [pscustomobject]@{
        Harness = $Harness
        Paths = $paths
        Before = $before
        ClipboardBefore = [uint32](& $ClipboardSequenceReader)
        ClipboardSequenceReader = $ClipboardSequenceReader
        StartedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        ReceiptDirectory = $ReceiptDirectory
    }
    Write-InteractiveWin11StateReceipt -Path (Join-Path $ReceiptDirectory 'state-before.json') -Receipt ([ordered]@{
        Harness = $Harness; StartedAtUtc = $guard.StartedAtUtc; Paths = $paths
        Metadata = $before; ClipboardSequence = $guard.ClipboardBefore
    })
    Write-Host "$Harness state guard: clipboard sequence before=$($guard.ClipboardBefore) receipt=$ReceiptDirectory"
    return $guard
}

function Assert-InteractiveWin11StateGuard {
    param([Parameter(Mandatory)] $Guard)
    $failures = [Collections.Generic.List[string]]::new()
    $after = [ordered]@{}
    foreach ($name in $Guard.Paths.Keys) {
        try { $after[$name] = Get-InteractiveWin11StateMetadata -Path $Guard.Paths[$name] }
        catch { $failures.Add("$name metadata inspection failed: $($_.Exception.Message)") }
    }
    $clipboardAfter = $null
    try {
        $clipboardAfter = [uint32](& $Guard.ClipboardSequenceReader)
        if ($Guard.ClipboardBefore -ne $clipboardAfter) { $failures.Add('Clipboard sequence changed during the batch; report before further launches.') }
    } catch { $failures.Add("Clipboard sequence inspection failed: $($_.Exception.Message)") }
    $finished = [DateTimeOffset]::UtcNow
    foreach ($name in @('Startup', 'ProductJumpList')) {
        if (-not $after.Contains($name)) { continue }
        $old = $Guard.Before[$name]
        $new = $after[$name]
        if ($old.Exists -ne $new.Exists -or $old.Length -ne $new.Length -or $old.LastWriteTimeUtc -cne $new.LastWriteTimeUtc) {
            $failures.Add("$name metadata changed during the batch; report before further launches.")
        }
    }
    $cleanup = if ($after.Contains('MeasureJumpList')) { 'not-present' } else { 'preserved-metadata-unavailable' }
    if ($Guard.Before.MeasureJumpList.Exists) { $cleanup = 'preserved-preexisting' }
    elseif ($after.Contains('MeasureJumpList') -and $after.MeasureJumpList.Exists) {
        $cleanup = 'preserved-uncertain-timestamps'
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $styles = [Globalization.DateTimeStyles]::None
        $created = [DateTimeOffset]::ParseExact($after.MeasureJumpList.CreationTimeUtc, 'o', $culture, $styles)
        $written = [DateTimeOffset]::ParseExact($after.MeasureJumpList.LastWriteTimeUtc, 'o', $culture, $styles)
        $started = [DateTimeOffset]::ParseExact($Guard.StartedAtUtc, 'o', $culture, $styles)
        # NTFS tunnelling may retain an old creation time for this exact name.
        # Record it and preserve that uncertain file rather than relax deletion.
        if ($created -ge $started -and $created -le $finished -and $written -ge $started -and $written -le $finished) {
            try {
                $path = $Guard.Paths.MeasureJumpList
                if ([IO.Path]::GetFileName($path) -cne '251fcb42973017e3.customDestinations-ms') { throw 'Unexpected measurement file name.' }
                $current = Get-InteractiveWin11StateMetadata -Path $path
                if (($current | ConvertTo-Json -Compress) -cne ($after.MeasureJumpList | ConvertTo-Json -Compress)) {
                    throw 'Measurement metadata changed before cleanup.'
                }
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                $cleanup = 'removed-batch-created'
            } catch { $cleanup = 'preserved-cleanup-failed'; $failures.Add("Measurement cleanup failed: $($_.Exception.Message)") }
        } else {
            $failures.Add('Measurement jump list preserved: creation/write UTC is outside the batch (possibly NTFS tunnelling); cleanup ownership is uncertain.')
        }
    }
    $receipt = [ordered]@{
        Harness = $Guard.Harness; StartedAtUtc = $Guard.StartedAtUtc; FinishedAtUtc = $finished.ToString('o')
        Paths = $Guard.Paths; Before = $Guard.Before; After = $after
        ClipboardBefore = $Guard.ClipboardBefore; ClipboardAfter = $clipboardAfter
        MeasureCleanup = $cleanup; Failures = @($failures.ToArray())
    }
    Write-InteractiveWin11StateReceipt -Path (Join-Path $Guard.ReceiptDirectory 'state-after.json') -Receipt $receipt
    Write-Host "$($Guard.Harness) state guard: clipboard sequence before=$($Guard.ClipboardBefore) after=$clipboardAfter; measure cleanup=$cleanup"
    if ($failures.Count) { throw "$($Guard.Harness): $($failures -join ' ')" }
}
