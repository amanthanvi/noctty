#requires -Version 7.3

[CmdletBinding()]
param(
    [string] $SiteDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'site')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Assert-ReviewedContentSecurityPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $Policy,

        [Parameter(Mandatory)]
        [string[]] $ScriptHashes,

        [Parameter(Mandatory)]
        [string[]] $ScriptAttributeHashes
    )

    $declaredDirectives = [Collections.Generic.Dictionary[
        string,
        string[]
    ]]::new([StringComparer]::Ordinal)
    foreach ($rawDirective in $Policy.Split(';')) {
        $tokens = @(
            $rawDirective.Trim().Split(
                [char[]] " `t",
                [StringSplitOptions]::RemoveEmptyEntries
            )
        )
        if ($tokens.Count -eq 0 -or
            -not $declaredDirectives.TryAdd(
                $tokens[0],
                [string[]] @($tokens | Select-Object -Skip 1)
            )) {
            throw 'Site CSP does not match the independently reviewed directive and source allowlist.'
        }
    }

    $expectedStaticSources = [ordered] @{
        'default-src' = [string[]] @("'self'")
        'base-uri' = [string[]] @("'none'")
        'object-src' = [string[]] @("'none'")
        'frame-ancestors' = [string[]] @("'none'")
        'form-action' = [string[]] @("'self'")
        'style-src' = [string[]] @(
            "'self'",
            'https://fonts.googleapis.com'
        )
        'font-src' = [string[]] @("'self'", 'https://fonts.gstatic.com')
        'connect-src' = [string[]] @("'self'", 'https://api.github.com')
        'img-src' = [string[]] @("'self'", 'data:')
        'frame-src' = [string[]] @("'none'")
        'worker-src' = [string[]] @("'none'")
        'manifest-src' = [string[]] @("'self'")
        'upgrade-insecure-requests' = [string[]] @()
    }
    $derivedHashSets = @($ScriptHashes, $ScriptAttributeHashes)
    foreach ($derivedHashes in $derivedHashSets) {
        $derivedHashSet = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($hash in $derivedHashes) {
            [void] $derivedHashSet.Add($hash)
        }
        if ($derivedHashes.Count -ne $derivedHashSet.Count -or
            @($derivedHashes | Where-Object {
                $_ -cnotmatch '^sha256-[A-Za-z0-9+/]+={0,2}$'
            }).Count -ne 0) {
            throw 'HTML-derived CSP hashes are invalid or duplicated.'
        }
    }
    $dynamicHashDirectives = [ordered] @{
        'script-src' = [string[]] @(
            "'self'"
            $ScriptHashes | ForEach-Object { "'$_'" }
        )
        'script-src-attr' = [string[]] @(
            "'unsafe-hashes'"
            $ScriptAttributeHashes | ForEach-Object { "'$_'" }
        )
    }
    if ($declaredDirectives.Count -ne
        $expectedStaticSources.Count + $dynamicHashDirectives.Count) {
        throw 'Site CSP does not match the independently reviewed directive and source allowlist.'
    }

    foreach ($directiveName in $expectedStaticSources.Keys) {
        if (-not $declaredDirectives.ContainsKey($directiveName)) {
            throw 'Site CSP does not match the independently reviewed directive and source allowlist.'
        }
        [string[]] $actualSources = $declaredDirectives[$directiveName]
        [string[]] $expectedSources = $expectedStaticSources[$directiveName]
        $actualSourceSet = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($source in $actualSources) {
            [void] $actualSourceSet.Add($source)
        }
        if ($actualSources.Count -ne $actualSourceSet.Count -or
            $actualSourceSet.Count -ne $expectedSources.Count -or
            @($expectedSources | Where-Object {
                -not $actualSourceSet.Contains($_)
            }).Count -ne 0) {
            throw 'Site CSP does not match the independently reviewed directive and source allowlist.'
        }
    }

    foreach ($directiveName in $dynamicHashDirectives.Keys) {
        if (-not $declaredDirectives.ContainsKey($directiveName)) {
            throw 'Site CSP does not match the independently reviewed directive and source allowlist.'
        }
        [string[]] $expectedSources = $dynamicHashDirectives[$directiveName]
        [string[]] $actualSources = $declaredDirectives[$directiveName]
        $actualSourceSet = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($source in $actualSources) {
            [void] $actualSourceSet.Add($source)
        }
        if ($actualSources.Count -ne $actualSourceSet.Count -or
            $actualSources.Count -ne $expectedSources.Count -or
            @($expectedSources | Where-Object {
                -not $actualSourceSet.Contains($_)
            }).Count -ne 0) {
            throw 'Site CSP does not match the independently reviewed directive and source allowlist.'
        }
    }
}

$siteRoot = [IO.Path]::GetFullPath($SiteDirectory).TrimEnd('\', '/')
$headersPath = Join-Path $siteRoot '_headers'
if (-not (Test-Path -LiteralPath $headersPath -PathType Leaf)) {
    throw 'Site header contract is missing _headers.'
}

$headerBuilder = Join-Path (Get-RepoRoot) 'scripts/build-site-assets.mjs'
$derivedHeaderJson = & node $headerBuilder `
    --print-header-contract `
    "--site-directory=$siteRoot"
if ($LASTEXITCODE -ne 0) {
    throw "Could not derive the site header contract (exit $LASTEXITCODE)."
}
$derivedHeaderContract = $derivedHeaderJson | ConvertFrom-Json -Depth 6
$expectedHeaderBytes = [Convert]::FromBase64String(
    [string] $derivedHeaderContract.generated_headers_base64
)
$actualHeaderBytes = [IO.File]::ReadAllBytes($headersPath)
if (-not [Linq.Enumerable]::SequenceEqual[byte](
        $actualHeaderBytes,
        $expectedHeaderBytes
    )) {
    throw 'Site _headers does not byte-match the HTML-derived header contract. Run node scripts/build-site-assets.mjs.'
}

$blocks = [Collections.Generic.Dictionary[
    string,
    Collections.Generic.Dictionary[string, string]
]]::new([StringComparer]::Ordinal)
$currentPath = $null
foreach ($line in [IO.File]::ReadAllLines($headersPath)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
        continue
    }
    if (-not [char]::IsWhiteSpace($line[0])) {
        $currentPath = $line.Trim()
        if (-not $blocks.TryAdd(
            $currentPath,
            [Collections.Generic.Dictionary[string, string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
        )) {
            throw "Duplicate site header path: $currentPath"
        }
        continue
    }
    if ($null -eq $currentPath) {
        throw 'Site header appears before a path block.'
    }
    $separator = $line.IndexOf(':')
    if ($separator -le 0) {
        throw "Malformed site header in ${currentPath}: $line"
    }
    $name = $line.Substring(0, $separator).Trim()
    $value = $line.Substring($separator + 1).Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or
        [string]::IsNullOrWhiteSpace($value) -or
        -not $blocks[$currentPath].TryAdd($name, $value)) {
        throw "Invalid or duplicate site header in ${currentPath}: $name"
    }
}

if ($blocks.Count -ne 1 -or -not $blocks.ContainsKey('/*')) {
    throw 'Site header contract must use one catch-all response policy.'
}
$security = $blocks['/*']
foreach ($requiredHeader in @(
    'Cache-Control',
    'Content-Security-Policy',
    'X-Content-Type-Options',
    'X-Frame-Options',
    'Referrer-Policy',
    'Permissions-Policy'
)) {
    if (-not $security.ContainsKey($requiredHeader)) {
        throw "Catch-all site security contract is missing $requiredHeader."
    }
}
if ($security['Cache-Control'] -cne 'public, max-age=0, must-revalidate' -or
    $security['X-Content-Type-Options'] -cne 'nosniff' -or
    $security['X-Frame-Options'] -cne 'DENY' -or
    $security['Referrer-Policy'] -cne 'strict-origin-when-cross-origin') {
    throw 'Site cache or browser security header contract changed unexpectedly.'
}

$permissions = $security['Permissions-Policy']
$expectedPermissions = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($permission in @(
    'accelerometer=()',
    'autoplay=()',
    'camera=()',
    'geolocation=()',
    'gyroscope=()',
    'magnetometer=()',
    'microphone=()',
    'payment=()',
    'usb=()'
)) {
    [void]$expectedPermissions.Add($permission)
}
$declaredPermissionTokens = @(
    $permissions.Split(',') | ForEach-Object { $_.Trim() }
)
$declaredPermissions = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($permission in $declaredPermissionTokens) {
    if (-not $permission) {
        throw 'Site permissions policy contains an empty directive.'
    }
    [void]$declaredPermissions.Add($permission)
}
if ($declaredPermissionTokens.Count -ne $declaredPermissions.Count -or
    $declaredPermissions.Count -ne $expectedPermissions.Count -or
    @($expectedPermissions | Where-Object {
        -not $declaredPermissions.Contains($_)
    }).Count -ne 0) {
    throw 'Site permissions policy does not exactly match the denylist contract.'
}

$csp = $security['Content-Security-Policy']
Assert-ReviewedContentSecurityPolicy `
    -Policy $csp `
    -ScriptHashes @($derivedHeaderContract.script_hashes) `
    -ScriptAttributeHashes @($derivedHeaderContract.script_attribute_hashes)
if ($csp -cne [string] $derivedHeaderContract.root.content_security_policy) {
    throw 'Tracked site CSP differs from the HTML-derived source of truth.'
}

[ordered]@{
    root = [ordered]@{
        cache_control = $derivedHeaderContract.root.cache_control
        content_security_policy = $derivedHeaderContract.root.content_security_policy
        x_content_type_options = $derivedHeaderContract.root.x_content_type_options
        x_frame_options = $derivedHeaderContract.root.x_frame_options
        referrer_policy = $derivedHeaderContract.root.referrer_policy
        permissions_policy = $derivedHeaderContract.root.permissions_policy
    }
    not_found = [ordered]@{
        cache_control = $derivedHeaderContract.not_found.cache_control
    }
} | ConvertTo-Json -Depth 4 -Compress
