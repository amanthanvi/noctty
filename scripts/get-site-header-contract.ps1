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

function Get-CspSha256Source {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    return 'sha256-' + [Convert]::ToBase64String(
        [Security.Cryptography.SHA256]::HashData($bytes)
    )
}

$expectedScriptHashes = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$expectedScriptAttributeHashes = [Collections.Generic.HashSet[string]]::new(
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
    [void]$expectedScriptHashes.Add(
        (Get-CspSha256Source -Value $inlineScripts[0].Groups['body'].Value)
    )
    $eventAttributeCount = [regex]::Matches(
        $html,
        '(?is)\s+on[a-z][a-z0-9_-]*\s*='
    ).Count
    $eventHandlers = @([regex]::Matches(
        $html,
        '(?is)\s+on[a-z][a-z0-9_-]*\s*=\s*(?<quote>["''])(?<body>.*?)\k<quote>'
    ))
    if ($eventAttributeCount -ne 1 -or $eventHandlers.Count -ne 1) {
        throw "Expected exactly one quoted CSP-hashed event handler in $htmlName."
    }
    $decodedEventHandler = [Net.WebUtility]::HtmlDecode(
        $eventHandlers[0].Groups['body'].Value
    )
    [void]$expectedScriptAttributeHashes.Add(
        (Get-CspSha256Source -Value $decodedEventHandler)
    )
}

$csp = $security['Content-Security-Policy']
function Get-CspDirectiveSources {
    param(
        [Parameter(Mandatory)] [string] $Policy,
        [Parameter(Mandatory)] [string] $DirectiveName
    )

    $matches = @(
        $Policy.Split(';') |
            ForEach-Object { $_.Trim() } |
            Where-Object {
                $_ -match ('^' + [regex]::Escape($DirectiveName) + '(?:\s|$)')
            }
    )
    if ($matches.Count -ne 1) {
        throw "Site CSP must declare $DirectiveName exactly once."
    }
    return @([regex]::Split($matches[0], '\s+') | Select-Object -Skip 1)
}

function Assert-ExactCspDirectiveSources {
    param(
        [Parameter(Mandatory)] [string] $DirectiveName,
        [Parameter(Mandatory)] [AllowEmptyCollection()]
        [string[]] $Expected
    )

    $declaredTokens = @(
        Get-CspDirectiveSources -Policy $csp -DirectiveName $DirectiveName
    )
    $declared = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $expectedSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($token in $declaredTokens) {
        [void]$declared.Add($token)
    }
    foreach ($token in $Expected) {
        [void]$expectedSet.Add($token)
    }
    if ($declaredTokens.Count -ne $declared.Count -or
        $Expected.Count -ne $expectedSet.Count -or
        $declared.Count -ne $expectedSet.Count -or
        @($expectedSet | Where-Object { -not $declared.Contains($_) }).Count -ne 0) {
        throw "Site CSP $DirectiveName sources do not exactly match the site contract."
    }
}

$expectedScriptSources = @("'self'") + @(
    $expectedScriptHashes | ForEach-Object { "'$_'" }
)
$expectedScriptAttributeSources = @("'unsafe-hashes'") + @(
    $expectedScriptAttributeHashes | ForEach-Object { "'$_'" }
)
$expectedCspDirectives = [ordered]@{
    'default-src' = @("'self'")
    'base-uri' = @("'none'")
    'object-src' = @("'none'")
    'frame-ancestors' = @("'none'")
    'form-action' = @("'self'")
    'script-src' = $expectedScriptSources
    'script-src-attr' = $expectedScriptAttributeSources
    'style-src' = @(
        "'self'",
        "'unsafe-inline'",
        'https://fonts.googleapis.com'
    )
    'style-src-attr' = @("'unsafe-inline'")
    'font-src' = @("'self'", 'https://fonts.gstatic.com')
    'connect-src' = @("'self'", 'https://api.github.com')
    'img-src' = @("'self'", 'data:')
    'frame-src' = @("'none'")
    'worker-src' = @("'none'")
    'manifest-src' = @("'self'")
    'upgrade-insecure-requests' = @()
}
$declaredDirectiveNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($directive in $csp.Split(';')) {
    $directive = $directive.Trim()
    if (-not $directive) { continue }
    $directiveName = [regex]::Split($directive, '\s+')[0]
    if (-not $declaredDirectiveNames.Add($directiveName)) {
        throw "Site CSP declares duplicate directive $directiveName."
    }
}
if ($declaredDirectiveNames.Count -ne $expectedCspDirectives.Count -or
    @($declaredDirectiveNames | Where-Object {
        -not $expectedCspDirectives.Contains($_)
    }).Count -ne 0) {
    throw 'Site CSP does not declare the exact expected directive set.'
}
foreach ($directiveName in $expectedCspDirectives.Keys) {
    Assert-ExactCspDirectiveSources `
        -DirectiveName $directiveName `
        -Expected $expectedCspDirectives[$directiveName]
}

$expectedHashes = [Collections.Generic.HashSet[string]]::new(
    $expectedScriptHashes,
    [StringComparer]::Ordinal
)
$expectedHashes.UnionWith($expectedScriptAttributeHashes)
$declaredHashes = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($match in [regex]::Matches(
    $csp,
    "'(?<hash>sha256-[A-Za-z0-9+/]+=*)'"
)) {
    [void]$declaredHashes.Add($match.Groups['hash'].Value)
}
if ($declaredHashes.Count -ne $expectedHashes.Count -or
    @($expectedHashes | Where-Object {
        -not $declaredHashes.Contains($_)
    }).Count -ne 0) {
    throw 'Site CSP declares hashes outside the exact HTML source contract.'
}

[ordered]@{
    root = [ordered]@{
        cache_control = $security['Cache-Control']
        content_security_policy = $csp
        x_content_type_options = $security['X-Content-Type-Options']
        x_frame_options = $security['X-Frame-Options']
        referrer_policy = $security['Referrer-Policy']
        permissions_policy = $permissions
    }
    bundle = [ordered]@{
        cache_control = $security['Cache-Control']
    }
} | ConvertTo-Json -Depth 4 -Compress
