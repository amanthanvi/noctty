#requires -Version 7.3

[CmdletBinding()]
param(
    [string] $SiteDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'site')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$siteRoot = [IO.Path]::GetFullPath($SiteDirectory).TrimEnd('\', '/')
$headersPath = Join-Path $siteRoot '_headers'
if (-not (Test-Path -LiteralPath $headersPath -PathType Leaf)) {
    throw 'Site header contract is missing _headers.'
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

foreach ($requiredPath in @('/*', '/', '/bundle.js')) {
    if (-not $blocks.ContainsKey($requiredPath)) {
        throw "Site header contract is missing $requiredPath."
    }
}
$security = $blocks['/*']
$root = $blocks['/']
$bundle = $blocks['/bundle.js']
foreach ($requiredHeader in @(
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
if (-not $root.ContainsKey('Cache-Control') -or
    -not $bundle.ContainsKey('Cache-Control')) {
    throw 'Root or bundle site header contract is missing Cache-Control.'
}
if ($security.ContainsKey('Cache-Control')) {
    throw 'Catch-all security headers cannot overlap path-specific cache policy.'
}
if ($root['Cache-Control'] -cne 'public, max-age=0, must-revalidate' -or
    $bundle['Cache-Control'] -cne 'public, max-age=3600, must-revalidate' -or
    $security['X-Content-Type-Options'] -cne 'nosniff' -or
    $security['X-Frame-Options'] -cne 'DENY' -or
    $security['Referrer-Policy'] -cne 'strict-origin-when-cross-origin') {
    throw 'Site cache or browser security header contract changed unexpectedly.'
}

$permissions = $security['Permissions-Policy']
foreach ($permission in @(
    'camera=()',
    'geolocation=()',
    'microphone=()',
    'payment=()',
    'usb=()'
)) {
    if (-not $permissions.Contains($permission, [StringComparison]::Ordinal)) {
        throw "Site permissions policy is missing $permission."
    }
}

function Get-CspSha256Source {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    return 'sha256-' + [Convert]::ToBase64String(
        [Security.Cryptography.SHA256]::HashData($bytes)
    )
}

$expectedHashes = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($htmlName in @('index.html', '404.html')) {
    $htmlPath = Join-Path $siteRoot $htmlName
    if (-not (Test-Path -LiteralPath $htmlPath -PathType Leaf)) {
        throw "Site header contract is missing $htmlName."
    }
    $html = [IO.File]::ReadAllText(
        $htmlPath,
        [Text.UTF8Encoding]::new($false)
    )
    $inlineScripts = @(
        [regex]::Matches($html, '(?is)<script(?<attrs>[^>]*)>(?<body>.*?)</script>') |
            Where-Object { $_.Groups['attrs'].Value -notmatch '\bsrc\s*=' }
    )
    if ($inlineScripts.Count -ne 1) {
        throw "Expected exactly one CSP-hashed inline script in $htmlName."
    }
    [void]$expectedHashes.Add(
        (Get-CspSha256Source -Value $inlineScripts[0].Groups['body'].Value)
    )
}
[void]$expectedHashes.Add((Get-CspSha256Source -Value "this.media='all'"))

$csp = $security['Content-Security-Policy']
if ($csp.Contains("script-src 'self' 'unsafe-inline'", [StringComparison]::Ordinal)) {
    throw 'Site CSP cannot broadly allow inline scripts.'
}
foreach ($token in @(
    "default-src 'self'",
    "base-uri 'none'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "script-src 'self'",
    "script-src-attr 'unsafe-hashes'",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com",
    "connect-src 'self' https://api.github.com"
)) {
    if (-not $csp.Contains($token, [StringComparison]::Ordinal)) {
        throw "Site CSP is missing: $token"
    }
}
$declaredHashes = @(
    [regex]::Matches($csp, "'(?<hash>sha256-[A-Za-z0-9+/]+=*)'") |
        ForEach-Object { $_.Groups['hash'].Value }
)
if ($declaredHashes.Count -ne $expectedHashes.Count -or
    @($declaredHashes | Where-Object {
        -not $expectedHashes.Contains($_)
    }).Count -ne 0) {
    throw 'Site CSP hashes do not exactly match the inline HTML scripts and handlers.'
}

[ordered]@{
    root = [ordered]@{
        cache_control = $root['Cache-Control']
        content_security_policy = $csp
        x_content_type_options = $security['X-Content-Type-Options']
        x_frame_options = $security['X-Frame-Options']
        referrer_policy = $security['Referrer-Policy']
        permissions_policy = $permissions
    }
    bundle = [ordered]@{
        cache_control = $bundle['Cache-Control']
    }
} | ConvertTo-Json -Depth 4 -Compress
