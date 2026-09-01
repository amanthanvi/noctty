#requires -Version 7.3

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Deployment', 'Redirect')]
    [string] $Mode,

    [ValidatePattern('^noctty$')]
    [string] $ProjectName = 'noctty',

    [ValidatePattern('^main$')]
    [string] $ProductionBranch = 'main',

    [string] $DeploymentId,
    [string] $ExpectedEnvironment,
    [string] $ExpectedBranch,
    [string] $ExpectedCommit,
    [string] $BaseUrl,
    [string] $CanonicalBaseUrl,
    [string] $PayloadDirectory,
    [string] $ManifestPath,
    [string] $ProvenancePath,
    [switch] $RequireCanonical,
    [switch] $VerifyWwwRedirect,

    [string] $ApiToken = $env:CLOUDFLARE_API_TOKEN,
    [string] $AccountId = $env:CLOUDFLARE_ACCOUNT_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if ([string]::IsNullOrWhiteSpace($ApiToken)) {
    throw 'CLOUDFLARE_API_TOKEN is required.'
}
if ($AccountId -cnotmatch '^[0-9a-f]{32}$') {
    throw 'CLOUDFLARE_ACCOUNT_ID must be a 32-character lowercase hexadecimal identifier.'
}

function Assert-DeploymentId {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $Label
    )

    if ($Value -cnotmatch '^[0-9A-Za-z-]{8,64}$') {
        throw "$Label has an invalid format."
    }
}

function Write-RedactedJson {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Value
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if ($parent) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $json = (($Value | ConvertTo-Json -Depth 12) -replace "`r`n", "`n").
        TrimEnd([char[]]"`n") + "`n"
    if ($json.Contains($ApiToken, [StringComparison]::Ordinal) -or
        $json.Contains($AccountId, [StringComparison]::Ordinal)) {
        throw 'Refusing to write provenance containing Cloudflare credentials or account identifiers.'
    }
    [IO.File]::WriteAllText($fullPath, $json, [Text.UTF8Encoding]::new($false))
}

$apiHandler = [Net.Http.HttpClientHandler]::new()
$apiHandler.AllowAutoRedirect = $false
$apiClient = [Net.Http.HttpClient]::new($apiHandler)
$apiClient.Timeout = [TimeSpan]::FromSeconds(30)
$apiClient.DefaultRequestHeaders.Authorization =
    [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $ApiToken)
$apiClient.DefaultRequestHeaders.UserAgent.ParseAdd('noctty-site-verifier/1')
$apiRoot = 'https://api.cloudflare.com/client/v4/accounts/' +
    [Uri]::EscapeDataString($AccountId) +
    '/pages/projects/' +
    [Uri]::EscapeDataString($ProjectName)

function Invoke-CloudflareApi {
    param(
        [Parameter(Mandatory)] [Net.Http.HttpMethod] $Method,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $RelativePath
    )

    $request = [Net.Http.HttpRequestMessage]::new(
        $Method,
        "$apiRoot$RelativePath"
    )
    $response = $null
    try {
        try {
            $response = $apiClient.SendAsync($request).GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        catch {
            throw 'Cloudflare API transport failed.'
        }
        if (-not $response.IsSuccessStatusCode) {
            throw "Cloudflare API request failed with HTTP $([int]$response.StatusCode)."
        }
        try {
            $envelope = ConvertFrom-Json -InputObject $body -Depth 64 -NoEnumerate
        }
        catch {
            throw 'Cloudflare API returned invalid JSON.'
        }
        if ($envelope.GetType() -ne [Management.Automation.PSCustomObject] -or
            $envelope.success -ne $true -or
            $null -eq $envelope.result) {
            throw 'Cloudflare API rejected the request.'
        }
        return $envelope.result
    }
    finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Get-Project {
    Invoke-CloudflareApi -Method ([Net.Http.HttpMethod]::Get) -RelativePath ''
}

function Get-Deployment {
    param([Parameter(Mandatory)] [string] $Id)

    Assert-DeploymentId -Value $Id -Label 'Deployment ID'
    Invoke-CloudflareApi `
        -Method ([Net.Http.HttpMethod]::Get) `
        -RelativePath "/deployments/$([Uri]::EscapeDataString($Id))"
}

function Assert-ProjectContract {
    param([Parameter(Mandatory)] [object] $Project)

    if ([string]$Project.name -cne $ProjectName) {
        throw 'Cloudflare Pages project identity mismatch.'
    }
    if ([string]$Project.production_branch -cne $ProductionBranch) {
        throw 'Cloudflare Pages production branch is not main.'
    }
}

function Assert-DeploymentContract {
    param(
        [Parameter(Mandatory)] [object] $Deployment,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $Branch,
        [Parameter(Mandatory)] [string] $Commit
    )

    if ($Commit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Expected commit must be a full lowercase Git SHA.'
    }
    if ([string]$Deployment.id -cne $Id -or
        [string]$Deployment.project_name -cne $ProjectName) {
        throw 'Cloudflare deployment identity mismatch.'
    }
    if ([string]$Deployment.environment -cne $Environment) {
        throw 'Cloudflare deployment environment mismatch.'
    }
    if ($Deployment.is_skipped -eq $true -or
        [string]$Deployment.latest_stage.status -cne 'success') {
        throw 'Cloudflare deployment did not complete successfully.'
    }
    $metadata = $Deployment.deployment_trigger.metadata
    if ([string]$metadata.branch -cne $Branch -or
        [string]$metadata.commit_hash -cne $Commit -or
        $metadata.commit_dirty -ne $false) {
        throw 'Cloudflare deployment provenance does not match the clean exact commit.'
    }
}

function Get-CanonicalDeploymentId {
    param([Parameter(Mandatory)] [object] $Project)

    if ($null -eq $Project.canonical_deployment) { return '' }
    return [string]$Project.canonical_deployment.id
}

function Wait-CanonicalDeployment {
    param([Parameter(Mandatory)] [string] $ExpectedId)

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $project = Get-Project
        }
        catch {
            if ($attempt -eq 10) {
                throw 'Cloudflare canonical deployment polling failed after bounded retries.'
            }
            Start-Sleep -Seconds 2
            continue
        }
        Assert-ProjectContract -Project $project
        if ((Get-CanonicalDeploymentId -Project $project) -ceq $ExpectedId) {
            return $project
        }
        if ($attempt -lt 10) { Start-Sleep -Seconds 2 }
    }
    throw 'Cloudflare canonical deployment did not converge to the expected deployment.'
}

function Get-ManifestEntries {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $PayloadRoot
    )

    $manifestFullPath = [IO.Path]::GetFullPath($Path)
    $payloadFullPath = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $payloadFullPath -PathType Container)) {
        throw 'Site payload or SHA-256 manifest is missing.'
    }
    $payloadPrefix = "$payloadFullPath$([IO.Path]::DirectorySeparatorChar)"
    $pathComparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    $entries = [Collections.Generic.List[object]]::new()
    $previousPath = $null
    foreach ($line in [IO.File]::ReadAllLines($manifestFullPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw 'Site payload manifest cannot contain blank lines.'
        }
        $match = [regex]::Match(
            $line,
            '^(?<hash>[0-9a-f]{64})  (?<path>_headers|[A-Za-z0-9][A-Za-z0-9._/-]*)$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        if (-not $match.Success) {
            throw 'Site payload manifest has an invalid line.'
        }
        $relativePath = $match.Groups['path'].Value
        $segments = $relativePath.Split('/')
        if ($relativePath.Contains('\') -or
            $segments -contains '.' -or
            $segments -contains '..' -or
            ($null -ne $previousPath -and
                [StringComparer]::Ordinal.Compare($previousPath, $relativePath) -ge 0)) {
            throw 'Site payload manifest paths must be unique, safe, and ordinally sorted.'
        }
        $localPath = [IO.Path]::GetFullPath(
            (Join-Path $payloadFullPath (
                $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
            ))
        )
        if (-not $localPath.StartsWith($payloadPrefix, $pathComparison) -or
            -not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            throw 'Site payload manifest references a missing or unsafe local file.'
        }
        $actualHash = Get-FileSha256Lower -Path $localPath
        if ($actualHash -cne $match.Groups['hash'].Value) {
            throw 'Local site payload does not match its SHA-256 manifest.'
        }
        [void]$entries.Add([pscustomobject]@{
            Hash = $actualHash
            Path = $relativePath
        })
        $previousPath = $relativePath
    }
    if ($entries.Count -eq 0) {
        throw 'Site payload manifest is empty.'
    }
    return $entries
}

function ConvertTo-PublicBaseUri {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [ValidateSet('pages', 'canonical')] [string] $Kind
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or
        $uri.AbsolutePath -cne '/') {
        throw 'Deployment verification URL must be an HTTPS origin.'
    }
    if ($Kind -eq 'pages' -and
        $uri.DnsSafeHost -cnotmatch '^[0-9a-f]{8}\.noctty\.pages\.dev$') {
        throw 'Deployment URL is not an immutable noctty Pages origin.'
    }
    if ($Kind -eq 'canonical' -and $uri.DnsSafeHost -cne 'noctty.com') {
        throw 'Canonical URL must be https://noctty.com/.'
    }
    return $uri
}

function Assert-ImmutablePagesDeploymentOrigin {
    param(
        [Parameter(Mandatory)] [Uri] $Origin,
        [Parameter(Mandatory)] [string] $DeploymentId
    )

    $idMatch = [regex]::Match($DeploymentId, '^(?<label>[0-9a-f]{8})-')
    if (-not $idMatch.Success -or
        $Origin.DnsSafeHost -cne
            "$($idMatch.Groups['label'].Value).noctty.pages.dev") {
        throw 'Immutable Pages origin does not match the deployment ID.'
    }
}

function New-PublicAssetUri {
    param(
        [Parameter(Mandatory)] [Uri] $Origin,
        [Parameter(Mandatory)] [string] $RelativePath,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Commit
    )

    if ($RelativePath -ceq 'index.html') {
        $path = '/'
    } elseif ($RelativePath -ceq '404.html') {
        $path = "/__noctty_missing_$($Commit.Substring(0, 12))/nested/page"
    } else {
        $escapedSegments = $RelativePath.Split('/') |
            ForEach-Object { [Uri]::EscapeDataString($_) }
        $path = '/' + ($escapedSegments -join '/')
    }
    $builder = [UriBuilder]::new($Origin)
    $builder.Path = $path
    $builder.Query = 'noctty_deployment=' + [Uri]::EscapeDataString($Id)
    return $builder.Uri
}

function Get-Sha256 {
    param([Parameter(Mandatory)] [byte[]] $Bytes)

    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).
        ToLowerInvariant()
}

$publicHandler = [Net.Http.HttpClientHandler]::new()
$publicHandler.AllowAutoRedirect = $false
$publicHandler.AutomaticDecompression = [Net.DecompressionMethods]::None
$publicClient = [Net.Http.HttpClient]::new($publicHandler)
$publicClient.Timeout = [TimeSpan]::FromSeconds(30)
$publicClient.DefaultRequestHeaders.UserAgent.ParseAdd('noctty-site-verifier/1')
$publicClient.DefaultRequestHeaders.CacheControl =
    [Net.Http.Headers.CacheControlHeaderValue]::new()
$publicClient.DefaultRequestHeaders.CacheControl.NoCache = $true
$publicClient.DefaultRequestHeaders.Pragma.ParseAdd('no-cache')

function Test-PublicPayloadOnce {
    param(
        [Parameter(Mandatory)] [Uri] $Origin,
        [Parameter(Mandatory)] [object[]] $Entries,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Commit,
        [switch] $StaticOnly
    )

    foreach ($entry in $Entries) {
        if ($entry.Path -ceq '_headers') {
            # Pages consumes this control file; it is not a public static asset.
            continue
        }
        if ($StaticOnly -and
            [IO.Path]::GetExtension([string]$entry.Path) -cin @('.html', '.htm')) {
            # A custom-domain challenge can replace HTML. The immutable Pages
            # deployment remains the authoritative full-payload verification.
            continue
        }
        $uri = New-PublicAssetUri `
            -Origin $Origin `
            -RelativePath $entry.Path `
            -Id $Id `
            -Commit $Commit
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $uri)
        $response = $null
        try {
            $response = $publicClient.SendAsync($request).GetAwaiter().GetResult()
            $expectedStatus = if ($entry.Path -ceq '404.html') { 404 } else { 200 }
            if ([int]$response.StatusCode -ne $expectedStatus) {
                return 'failed'
            }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ((Get-Sha256 -Bytes $bytes) -cne $entry.Hash) { return 'failed' }
        }
        catch {
            return 'failed'
        }
        finally {
            if ($response) { $response.Dispose() }
            $request.Dispose()
        }
    }
    return 'verified'
}

function Assert-PublicPayload {
    param(
        [Parameter(Mandatory)] [Uri] $Origin,
        [Parameter(Mandatory)] [object[]] $Entries,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Commit,
        [switch] $StaticOnly
    )

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $status = Test-PublicPayloadOnce `
                -Origin $Origin `
                -Entries $Entries `
                -Id $Id `
                -Commit $Commit `
                -StaticOnly:$StaticOnly
        if ($status -cne 'failed') {
            return $status
        }
        if ($attempt -lt 6) { Start-Sleep -Seconds 2 }
    }
    throw "Published site bytes did not match the manifest at $($Origin.DnsSafeHost)."
}

function Get-ResponseHeaderText {
    param(
        [Parameter(Mandatory)] [Net.Http.HttpResponseMessage] $Response,
        [Parameter(Mandatory)] [string] $Name
    )

    $values = $null
    if ($Response.Headers.TryGetValues($Name, [ref]$values) -or
        $Response.Content.Headers.TryGetValues($Name, [ref]$values)) {
        return (@($values) -join ', ')
    }
    return ''
}

function Test-EquivalentCacheControl {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Actual,
        [Parameter(Mandatory)] [string] $Expected
    )

    $actualTokens = @($Actual.Split(',') | ForEach-Object { $_.Trim() })
    $expectedTokens = @($Expected.Split(',') | ForEach-Object { $_.Trim() })
    $actualSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $expectedSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($token in $actualTokens) {
        if (-not $token -or -not $actualSet.Add($token)) { return $false }
    }
    foreach ($token in $expectedTokens) {
        if (-not $token -or -not $expectedSet.Add($token)) { return $false }
    }
    return $actualSet.Count -eq $expectedSet.Count -and
        @($expectedSet | Where-Object { -not $actualSet.Contains($_) }).Count -eq 0
}

function Test-PublicHeaderContractOnce {
    param(
        [Parameter(Mandatory)] [Uri] $Origin,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [object] $Contract,
        [switch] $StaticOnly
    )

    $probes = @()
    if (-not $StaticOnly) {
        $probes += [pscustomobject]@{
            Path = '/'
            ExpectedStatus = 200
            ExpectedCache = [string]$Contract.root.cache_control
        }
    }
    $probes += [pscustomobject]@{
        Path = '/styles.css'
        ExpectedStatus = 200
        ExpectedCache = [string]$Contract.root.cache_control
    }
    if (-not $StaticOnly) {
        $probes += [pscustomobject]@{
            Path = '/__noctty_header_contract_' +
                [Uri]::EscapeDataString($Id) + '/nested/page'
            ExpectedStatus = 404
            ExpectedCache = [string]$Contract.not_found.cache_control
        }
    }
    foreach ($probe in $probes) {
        $builder = [UriBuilder]::new($Origin)
        $builder.Path = $probe.Path
        $builder.Query = 'noctty_deployment=' + [Uri]::EscapeDataString($Id)
        $request =
            [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $builder.Uri)
        $response = $null
        try {
            $response = $publicClient.SendAsync($request).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -ne $probe.ExpectedStatus) {
                return $false
            }
            $cacheControl = Get-ResponseHeaderText `
                -Response $response `
                -Name 'Cache-Control'
            if (-not (Test-EquivalentCacheControl `
                    -Actual $cacheControl `
                    -Expected $probe.ExpectedCache)) {
                return $false
            }
            if ((Get-ResponseHeaderText -Response $response -Name 'X-Content-Type-Options') -cne
                    [string]$Contract.root.x_content_type_options -or
                (Get-ResponseHeaderText -Response $response -Name 'X-Frame-Options') -cne
                    [string]$Contract.root.x_frame_options -or
                (Get-ResponseHeaderText -Response $response -Name 'Referrer-Policy') -cne
                    [string]$Contract.root.referrer_policy -or
                (Get-ResponseHeaderText -Response $response -Name 'Permissions-Policy') -cne
                    [string]$Contract.root.permissions_policy -or
                (Get-ResponseHeaderText -Response $response -Name 'Content-Security-Policy') -cne
                    [string]$Contract.root.content_security_policy) {
                return $false
            }
        }
        catch {
            return $false
        }
        finally {
            if ($response) { $response.Dispose() }
            $request.Dispose()
        }
    }
    return $true
}

function Assert-PublicHeaderContract {
    param(
        [Parameter(Mandatory)] [Uri] $Origin,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [object] $Contract,
        [switch] $StaticOnly
    )

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        if (Test-PublicHeaderContractOnce `
                -Origin $Origin `
                -Id $Id `
                -Contract $Contract `
                -StaticOnly:$StaticOnly) {
            return
        }
        if ($attempt -lt 6) { Start-Sleep -Seconds 2 }
    }
    throw "Published response headers did not converge at $($Origin.DnsSafeHost)."
}

function Assert-WwwRedirectContract {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Commit
    )

    $suffix = "/__noctty_redirect_$($Commit.Substring(0, 12))" +
        "?noctty_deployment=$([Uri]::EscapeDataString($Id))"
    $source = [Uri]::new("https://www.noctty.com$suffix")
    $expected = [Uri]::new("https://noctty.com$suffix")
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $source)
    $response = $null
    try {
        $response = $publicClient.SendAsync($request).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 301 -or
            $null -eq $response.Headers.Location) {
            throw 'www.noctty.com is not configured with the required zone-level 301 redirect.'
        }
        $location = if ($response.Headers.Location.IsAbsoluteUri) {
            $response.Headers.Location
        } else {
            [Uri]::new($source, $response.Headers.Location)
        }
        if ($location.AbsoluteUri -cne $expected.AbsoluteUri) {
            throw 'www.noctty.com redirect does not preserve the path and query at the apex.'
        }
    }
    catch {
        if ($_.Exception.Message -like 'www.noctty.com*') { throw }
        throw 'Unable to verify the www zone-level redirect.'
    }
    finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
    }
}

try {
    switch ($Mode) {
        'Redirect' {
            if ([string]::IsNullOrWhiteSpace($DeploymentId) -or
                [string]::IsNullOrWhiteSpace($ExpectedCommit)) {
                throw 'Redirect mode requires DeploymentId and ExpectedCommit.'
            }
            Assert-DeploymentId -Value $DeploymentId -Label 'Deployment ID'
            if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') {
                throw 'Expected commit must be a full lowercase Git SHA.'
            }
            Assert-WwwRedirectContract -Id $DeploymentId -Commit $ExpectedCommit
            Write-Host 'Verified the zone-owned www redirect before production.'
        }

        'Deployment' {
            foreach ($requiredValue in @(
                $DeploymentId,
                $ExpectedEnvironment,
                $ExpectedBranch,
                $ExpectedCommit,
                $BaseUrl,
                $PayloadDirectory,
                $ManifestPath,
                $ProvenancePath
            )) {
                if ([string]::IsNullOrWhiteSpace($requiredValue)) {
                    throw 'Deployment mode is missing a required argument.'
                }
            }
            if ($ExpectedEnvironment -cnotin @('preview', 'production')) {
                throw 'ExpectedEnvironment must be preview or production.'
            }
            if ($ExpectedEnvironment -eq 'production' -and
                $ExpectedBranch -cne $ProductionBranch) {
                throw 'Production deployment branch must be main.'
            }
            if ($ExpectedEnvironment -eq 'preview' -and
                $ExpectedBranch -ceq $ProductionBranch) {
                throw 'Canary deployment cannot use the production branch.'
            }
            Assert-DeploymentId -Value $DeploymentId -Label 'Deployment ID'
            $deployment = Get-Deployment -Id $DeploymentId
            Assert-DeploymentContract `
                -Deployment $deployment `
                -Id $DeploymentId `
                -Environment $ExpectedEnvironment `
                -Branch $ExpectedBranch `
                -Commit $ExpectedCommit

            if ($RequireCanonical) {
                if ($ExpectedEnvironment -cne 'production') {
                    throw 'Only a production deployment can be canonical.'
                }
                $project = Wait-CanonicalDeployment -ExpectedId $DeploymentId
            } else {
                $project = Get-Project
                Assert-ProjectContract -Project $project
            }

            $pagesOrigin = ConvertTo-PublicBaseUri -Value $BaseUrl -Kind pages
            $apiOrigin = ConvertTo-PublicBaseUri -Value ([string]$deployment.url) -Kind pages
            if ($pagesOrigin.AbsoluteUri.TrimEnd('/') -cne
                $apiOrigin.AbsoluteUri.TrimEnd('/')) {
                throw 'Wrangler deployment URL does not match Cloudflare API provenance.'
            }
            Assert-ImmutablePagesDeploymentOrigin `
                -Origin $pagesOrigin `
                -DeploymentId $DeploymentId
            $entries = @(Get-ManifestEntries `
                -Path $ManifestPath `
                -PayloadRoot $PayloadDirectory)
            $headerContract = (
                & (Join-Path $PSScriptRoot 'get-site-header-contract.ps1') `
                    -SiteDirectory $PayloadDirectory
            ) | ConvertFrom-Json -Depth 6
            [void](Assert-PublicPayload `
                -Origin $pagesOrigin `
                -Entries $entries `
                -Id $DeploymentId `
                -Commit $ExpectedCommit)
            [void](Assert-PublicHeaderContract `
                -Origin $pagesOrigin `
                -Id $DeploymentId `
                -Contract $headerContract)

            $verifiedHosts = [Collections.Generic.List[string]]::new()
            [void]$verifiedHosts.Add($pagesOrigin.DnsSafeHost)
            if (-not [string]::IsNullOrWhiteSpace($CanonicalBaseUrl)) {
                if (-not $RequireCanonical -or $ExpectedEnvironment -cne 'production') {
                    throw 'Canonical byte verification requires the canonical production deployment.'
                }
                $canonicalOrigin =
                    ConvertTo-PublicBaseUri -Value $CanonicalBaseUrl -Kind canonical
                if (@($project.domains) -cnotcontains $canonicalOrigin.DnsSafeHost) {
                    throw 'The apex custom domain is not attached to the Pages project.'
                }
                [void](Assert-PublicPayload `
                    -Origin $canonicalOrigin `
                    -Entries $entries `
                    -Id $DeploymentId `
                    -Commit $ExpectedCommit `
                    -StaticOnly)
                [void](Assert-PublicHeaderContract `
                    -Origin $canonicalOrigin `
                    -Id $DeploymentId `
                    -Contract $headerContract `
                    -StaticOnly)
                [void]$verifiedHosts.Add($canonicalOrigin.DnsSafeHost)
            }
            if ($VerifyWwwRedirect) {
                if ([string]::IsNullOrWhiteSpace($CanonicalBaseUrl)) {
                    throw 'www redirect verification requires CanonicalBaseUrl.'
                }
                Assert-WwwRedirectContract -Id $DeploymentId -Commit $ExpectedCommit
                [void]$verifiedHosts.Add('www.noctty.com')
            }

            $manifestHash = Get-FileSha256Lower `
                -Path ([IO.Path]::GetFullPath($ManifestPath))
            Write-RedactedJson -Path $ProvenancePath -Value ([ordered]@{
                schema_version = 'noctty.cloudflare-pages-provenance.v2'
                verified_at = [DateTimeOffset]::UtcNow.ToString('o')
                project_name = $ProjectName
                deployment_id = $DeploymentId
                environment = $ExpectedEnvironment
                branch = $ExpectedBranch
                commit_hash = $ExpectedCommit
                commit_dirty = $false
                stage_status = 'success'
                deployment_host = $pagesOrigin.DnsSafeHost
                canonical = [bool]$RequireCanonical
                manifest_sha256 = $manifestHash
                file_count = $entries.Count
                verified_hosts = [string[]]$verifiedHosts
                immutable_html_verified = $true
                canonical_static_assets_verified =
                    -not [string]::IsNullOrWhiteSpace($CanonicalBaseUrl)
                canonical_html_verified = $false
                github_repository = $env:GITHUB_REPOSITORY
                github_run_id = $env:GITHUB_RUN_ID
                github_run_attempt = $env:GITHUB_RUN_ATTEMPT
            })
            Write-Host "Verified $ExpectedEnvironment deployment provenance and bytes."
        }

    }
}
finally {
    $publicClient.Dispose()
    $publicHandler.Dispose()
    $apiClient.Dispose()
    $apiHandler.Dispose()
}
