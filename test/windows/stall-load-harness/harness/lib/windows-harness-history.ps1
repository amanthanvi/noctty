# PSReadLine resolves its default through the Windows known folder, not APPDATA.
# Inspect metadata only: never open, hash, print, or restore the user's history.
function Get-WindowsHarnessHistoryPaths {
    $roaming = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($roaming)) { throw 'Cannot resolve the real history known folder.' }
    return @(
        (Join-Path $roaming 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt')
        (Join-Path $roaming 'Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt')
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\PSReadLine\ConsoleHost_history.txt')
    )
}

function Get-WindowsHarnessHistoryMetadata {
    param([Parameter(Mandatory)] [string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -ErrorVariable metadataError
    if ($null -eq $item) {
        if ($metadataError -and $metadataError[0].CategoryInfo.Category -ne 'ObjectNotFound') {
            throw 'Cannot inspect PowerShell history metadata.'
        }
        return 'absent'
    }
    if ($item.PSIsContainer) { throw 'PowerShell history path is a directory.' }
    return '{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
}

function Start-WindowsHarnessHistoryGuard {
    param(
        [Parameter(Mandatory)] [string] $Harness,
        # Explicit injection is for scratch-file controls; production callers omit it.
        [string[]] $Paths = (Get-WindowsHarnessHistoryPaths)
    )
    if ($Paths.Count -eq 0) { throw 'A history guard needs at least one path.' }
    return [pscustomobject]@{
        Harness = $Harness
        Paths = $Paths
        Before = @($Paths | ForEach-Object { Get-WindowsHarnessHistoryMetadata -Path $_ })
    }
}

function Assert-WindowsHarnessHistoryGuard {
    param([Parameter(Mandatory)] $Guard)
    $after = @($Guard.Paths | ForEach-Object { Get-WindowsHarnessHistoryMetadata -Path $_ })
    for ($index = 0; $index -lt $Guard.Paths.Count; $index++) {
        if ($Guard.Before[$index] -cne $after[$index]) {
            throw "$($Guard.Harness): real PowerShell history metadata changed during the run (file $index, $($Guard.Before[$index]) -> $($after[$index])). Stop launches and report it."
        }
    }
    Write-Verbose "$($Guard.Harness): PowerShell history metadata unchanged."
}
