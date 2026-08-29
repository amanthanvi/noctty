function Get-RepoRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-FileSha256Lower {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-WindowsSignedRuntimePayloads {
    # Portable-ZIP-relative paths of every PE that noctty builds and signs.
    # This is the single list behind release Authenticode re-verification,
    # published-release verification, and the Defender scan, so a newly
    # shipped binary becomes covered by all three by being added here once.
    # Microsoft's bundled ConPTY pair is deliberately absent: it is not
    # re-signed by us and is verified against its own pinned hashes and
    # Microsoft's signature instead.
    return @(
        'noctty/noctty.com',
        'noctty/noctty.exe',
        'noctty/ghostty-vt.dll',
        'noctty/noctty-terminal-handoff-proxy.dll'
    )
}
