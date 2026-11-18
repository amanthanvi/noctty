# Focused promotion preflight: candidate metadata is independent of main's
# release line/signing setup. Credentials are never printed.
function Test-ReleasePublisherEnabled {
    param([string] $Channel)
    -not [string]::Equals([Environment]::GetEnvironmentVariable($Channel + '_PUBLISH'), 'off', [StringComparison]::OrdinalIgnoreCase)
}
function Assert-PromotionPackageManagers {
    $enabled = @{}
    foreach ($channel in @('SCOOP', 'WINGET', 'CHOCOLATEY')) {
        $enabled[$channel] = Test-ReleasePublisherEnabled $channel
    }
    $required = @{
        SCOOP = @('SCOOP_BUCKET_REPO', 'SCOOP_BUCKET_TOKEN')
        WINGET = @('WINGET_PACKAGE_IDENTIFIER', 'WINGET_CREATE_GITHUB_TOKEN')
        # Presence comes from a workflow expression; the key remains confined
        # to the final publishing step.
        CHOCOLATEY = @('PROMOTE_CHOCOLATEY_KEY_PRESENT')
    }
    foreach ($channel in $required.Keys) {
        if (-not $enabled[$channel]) { Write-Host "$channel explicitly disabled."; continue }
        foreach ($name in $required[$channel]) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ([string]::IsNullOrWhiteSpace($value) -or ($channel -ceq 'CHOCOLATEY' -and $value -cne 'true')) {
                throw "PackageManagerNotReady: $channel requires $name, or explicitly set ${channel}_PUBLISH=off before promotion."
            }
        }
    }
    $savedToken = $env:GH_TOKEN
    try {
        if ($enabled.SCOOP) {
            $env:GH_TOKEN = $env:SCOOP_BUCKET_TOKEN
            $path = if ([string]::IsNullOrWhiteSpace($env:SCOOP_BUCKET_MANIFEST_PATH)) { 'bucket/noctty.json' } else { $env:SCOOP_BUCKET_MANIFEST_PATH }
            $arguments = @('api', '--method', 'GET', "repos/$env:SCOOP_BUCKET_REPO/contents/$path")
            if ($env:SCOOP_BUCKET_BRANCH) { $arguments += @('-f', "ref=$env:SCOOP_BUCKET_BRANCH") }
            & gh @arguments *> $null
            if ($LASTEXITCODE -ne 0) { throw 'PackageManagerNotReady: configured Scoop manifest is unavailable.' }
        }
        if ($enabled.WINGET) {
            $env:GH_TOKEN = $env:WINGET_CREATE_GITHUB_TOKEN
            $segments = $env:WINGET_PACKAGE_IDENTIFIER.Split('.')
            $path = 'manifests/{0}/{1}' -f $segments[0].Substring(0, 1).ToLowerInvariant(), ($segments -join '/')
            & gh api --method GET "repos/microsoft/winget-pkgs/contents/$path" *> $null
            if ($LASTEXITCODE -ne 0) { throw 'PackageManagerNotReady: WinGet package is not bootstrapped or cannot be read.' }
        }
    } finally { $env:GH_TOKEN = $savedToken }
    return $enabled
}
