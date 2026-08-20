function Write-WindowsBuildCapabilitiesManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $BinPath,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [ValidateSet("x64", "arm64")]
        [string] $Architecture,

        [Parameter(Mandatory = $true)]
        [string[]] $RuntimeFiles
    )

    $artifactHashes = [ordered] @{}
    foreach ($runtimeFile in $RuntimeFiles) {
        $runtimePath = Join-Path $BinPath $runtimeFile
        if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
            throw "Cannot record build capability for missing runtime artifact: $runtimePath"
        }

        $artifactHashes[$runtimeFile] = (
            Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }

    [ordered] @{
        schema_version = "noctty.windows-build-capabilities.v1"
        version = $Version
        architecture = $Architecture
        custom_shaders = $true
        artifacts = $artifactHashes
    } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Assert-WindowsBuildCapabilitiesManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $BinPath,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [ValidateSet("x64", "arm64")]
        [string] $Architecture,

        [Parameter(Mandatory = $true)]
        [string[]] $RuntimeFiles
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing hash-bound build capability manifest: $Path"
    }

    try {
        $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Invalid build capability manifest $Path`: $($_.Exception.Message)"
    }

    if ($manifest.schema_version -cne "noctty.windows-build-capabilities.v1" -or
        $manifest.version -cne $Version -or
        $manifest.architecture -cne $Architecture -or
        $manifest.custom_shaders -ne $true) {
        throw "Build capability manifest does not match shader-enabled $Architecture version $Version."
    }

    foreach ($runtimeFile in $RuntimeFiles) {
        $runtimePath = Join-Path $BinPath $runtimeFile
        if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
            throw "Build capability manifest references missing runtime artifact: $runtimePath"
        }

        $hashProperty = $manifest.artifacts.PSObject.Properties[$runtimeFile]
        if ($null -eq $hashProperty -or [string]::IsNullOrWhiteSpace([string] $hashProperty.Value)) {
            throw "Build capability manifest has no hash for $runtimeFile."
        }

        $actualHash = (
            Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($actualHash -cne [string] $hashProperty.Value) {
            throw "Build capability manifest hash mismatch for $runtimeFile."
        }
    }
}
