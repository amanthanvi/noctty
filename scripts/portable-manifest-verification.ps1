function Assert-PortableManifestMatchesPayload {
    param(
        [Parameter(Mandatory)] [string]$ManifestPath,
        [Parameter(Mandatory)] [string]$PayloadRoot,
        [Parameter(Mandatory)] [string]$Label
    )

    $managedRootFiles = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in @(
        'noctty.com',
        'noctty.exe',
        'ghostty-vt.dll',
        'noctty-terminal-handoff-proxy.dll',
        'conpty.dll',
        'OpenConsole.exe',
        'LICENSE',
        'LICENSE-conpty.txt',
        'config-template.ghostty',
        'README.md',
        'noctty.ico',
        'share'
    )) {
        [void]$managedRootFiles.Add($name)
    }

    $entries = [System.Collections.Generic.Dictionary[string,string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($rawLine in [System.IO.File]::ReadAllLines($ManifestPath)) {
        $line = $rawLine.Trim([char[]]" `t`r")
        $match = [regex]::Match($line, '^(?<hash>[0-9a-fA-F]{64})[ \t]+\*?(?<name>.+)$')
        if (-not $match.Success) { continue }
        $name = $match.Groups['name'].Value
        if (-not $managedRootFiles.Contains($name) -and
            -not $name.StartsWith('share/', [System.StringComparison]::Ordinal)) {
            throw "$Label contains an unmanaged payload path: $name"
        }
        if ($entries.ContainsKey($name)) {
            throw "$Label contains duplicate payload path: $name"
        }
        $entries.Add($name, $match.Groups['hash'].Value.ToLowerInvariant())
    }

    $payloadFiles = [System.Collections.Generic.Dictionary[string,string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($file in @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File -Force)) {
        $name = [System.IO.Path]::GetRelativePath($PayloadRoot, $file.FullName).Replace('\', '/')
        if (-not $managedRootFiles.Contains($name) -and
            -not $name.StartsWith('share/', [System.StringComparison]::Ordinal)) {
            throw "$Label payload contains an unmanaged file: $name"
        }
        $payloadFiles.Add(
            $name,
            (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        )
    }

    $missing = @($payloadFiles.Keys | Where-Object { -not $entries.ContainsKey($_) })
    $unexpected = @($entries.Keys | Where-Object { -not $payloadFiles.ContainsKey($_) })
    if ($entries.Count -ne $payloadFiles.Count -or
        $missing.Count -gt 0 -or
        $unexpected.Count -gt 0) {
        throw "$Label file set mismatch. Missing: $($missing -join ', '); unexpected: $($unexpected -join ', ')."
    }
    foreach ($name in $payloadFiles.Keys) {
        if ($entries[$name] -ne $payloadFiles[$name]) {
            throw "$Label hash mismatch for $name."
        }
    }
}
