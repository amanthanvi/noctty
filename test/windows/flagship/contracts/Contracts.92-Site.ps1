foreach ($siteScript in @(
    $sitePayloadBuilder,
    $siteHeaderContract,
    $siteDeploymentHeadGate,
    $cloudflarePagesVerifier
)) {
    $siteScriptTokens = $null
    $siteScriptErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $siteScript,
        [ref]$siteScriptTokens,
        [ref]$siteScriptErrors
    )
    if ($siteScriptErrors.Count -ne 0) {
        throw "Site deployment script does not parse: $siteScript ($($siteScriptErrors[0].Message))"
    }
        Invoke-ContractTable -Contracts @(
        @{
            File = $siteScript
            Content = {
                (Get-Content -LiteralPath $siteScript -Raw)
            }
            Pattern = '(?m)^#requires -Version 7\.3\s*$'
            Kind = 'Text'
            Description = 'workflow-owned site deployment scripts declare their PowerShell 7.3 floor'
        }
    )
}
$siteCopyChecker = Join-Path $repoRoot 'scripts\check-site-copy.ps1'
$authoredSiteSources = @(
    'site\index.html',
    'site\install.js',
    'site\terminal.js',
    'site\version.js',
    'site\app.js'
)
foreach ($authoredSiteSource in $authoredSiteSources) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $authoredSiteSource) -PathType Leaf)) {
        throw "Authored static site source is missing: $authoredSiteSource"
    }
}
Invoke-ContractTable -Contracts @(
    @{
        File = $siteCopyChecker
        Pattern = '(?ms)\$textFiles = Get-ChildItem -Path \$siteRoot -Recurse -File \| Where-Object \{\s*\$_\.Extension -in @\(\s*"\.html",\s*"\.css",\s*"\.js",\s*"\.jsx",\s*"\.md",\s*"\.txt",\s*"\.svg"\s*\) -or\s*\$_\.Name -in @\(\s*"_redirects"\s*\)\s*\}\s*\$forbiddenRules = @\('
        Kind = 'Workflow'
        Description = 'forbidden-copy assertions recursively scan every authored static source in the complete extension and _redirects allowlist'
    }
    @{
        File = "$testWorkflow :: deterministic site asset check"
        Content = {
            (Get-YamlStepBlock -Content $testWorkflowText -Name 'Deterministic site asset check' -Source $testWorkflow)
        }
        Pattern = '(?ms)node scripts/build-site-assets\.mjs --check.*?LASTEXITCODE'
        Kind = 'Text'
        Description = 'the test workflow checks the deterministic static-site asset graph directly'
    }
    @{
        File = "$testWorkflow :: site unit tests"
        Content = {
            (Get-YamlStepBlock -Content $testWorkflowText -Name 'Site unit tests' -Source $testWorkflow)
        }
        Pattern = '(?ms)node --test site/tests/terminal\.test\.mjs site/tests/build-site-assets\.test\.mjs.*?LASTEXITCODE'
        Kind = 'Text'
        Description = 'the test workflow runs both static-site Node test files directly without package metadata'
    }
)

Invoke-ContractTable -Contracts @(
    @{
        File = $siteDeployWorkflow
        Content = {
            $siteDeployWorkflowText
        }
        Pattern = '(?ms)^on:\s+push:\s+branches:\s+- main\s+release:\s+types:\s+- published\s+workflow_dispatch:\s*$'
        Kind = 'Text'
        Description = 'site deployment catches every main advance plus published releases and manual dispatch'
    }
    @{
        File = $siteDeployWorkflow
        Pattern = '(?m)^\s+paths(?:-ignore)?:'
        Kind = 'WorkflowAbsent'
        Description = 'site deployment cannot strand a site change behind a later path-filtered main advance'
    }
    @{
        File = $siteDeployWorkflow
        Pattern = '(?m)^\s*(?:pull_request|pull_request_target):'
        Kind = 'WorkflowAbsent'
        Description = 'site deployment never runs for pull requests'
    }
    @{
        File = $siteDeployWorkflow
        Content = {
            $siteDeployWorkflowText
        }
        Pattern = '(?ms)^permissions:\s+contents: read\s+deployments: write\s+.*?^concurrency:\s+group: cloudflare-pages-production\s+cancel-in-progress: false\s*$'
        Kind = 'Text'
        Description = 'site deployment uses minimum repository permissions and serialized non-canceling production concurrency'
    }
    @{
        File = "$siteDeployWorkflow :: deploy"
        Content = {
            (Get-YamlJobText -Content $siteDeployWorkflowText -Name 'deploy' -Source $siteDeployWorkflow)
        }
        Pattern = '(?m)^\s+environment: cloudflare-pages-production\s*$'
        Kind = 'Text'
        Description = 'site deployment is protected by the production environment'
    }
    @{
        File = "$siteDeployWorkflow :: deploy"
        Content = {
            (Get-YamlJobText -Content $siteDeployWorkflowText -Name 'deploy' -Source $siteDeployWorkflow)
        }
        Pattern = "(?m)^\s+if: github\.event_name != 'release' \|\| github\.event\.release\.prerelease == false\s*$"
        Kind = 'Text'
        Description = 'stable site publication ignores prerelease events'
    }
    @{
        File = "$siteDeployWorkflow :: checkout"
        Content = {
            (Get-YamlStepBlock -Content $siteDeployWorkflowText -Name 'Checkout exact event commit' -Source $siteDeployWorkflow)
        }
        Pattern = '(?ms)uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd.*?ref: \$\{\{ github\.event_name == ''release'' && github\.event\.repository\.default_branch \|\| github\.sha \}\}.*?persist-credentials: false'
        Kind = 'Text'
        Description = 'site checkout uses exact event commits for pushes and current main for release publication'
    }
    @{
        File = "$siteDeployWorkflow :: source"
        Content = {
            (Get-YamlStepBlock -Content $siteDeployWorkflowText -Name 'Resolve exact deployment commit' -Source $siteDeployWorkflow)
        }
        Pattern = '(?ms)id: source.*?\$sha = git rev-parse HEAD.*?\$LASTEXITCODE -ne 0.*?\$sha = \(\[string\]\(\$sha -join "`n"\)\)\.Trim\(\).*?\^\[0-9a-f\]\{40\}\$.*?"sha=\$sha" >> \$env:GITHUB_OUTPUT'
        Kind = 'Text'
        Description = 'site deployment fails closed before recording the full resolved source SHA'
    }
    @{
        File = "$siteDeployWorkflow :: site validation"
        Content = {
            (Get-YamlStepBlock -Content $siteDeployWorkflowText -Name 'Validate committed site bundle and copy' -Source $siteDeployWorkflow)
        }
        Pattern = '(?ms)GH_TOKEN:.*?github\.token.*?RELEASE_TAG:.*?github\.event\.release\.tag_name.*?check-site-copy\.ps1.*?node scripts/build-site-assets\.mjs --check.*?get-site-header-contract\.ps1.*?GITHUB_EVENT_NAME -eq ''release''.*?RELEASE_TAG -cnotmatch ''\^v\(\?<version>\\d\+\\\.\\d\+\\\.\\d\+\)\$''.*?check-release-copy\.ps1.*?-ExpectedVersion \$Matches\.version.*?-CheckRemoteLatest.*?else \{.*?check-release-copy\.ps1 -CheckRemoteLatest.*?LASTEXITCODE'
        Kind = 'Text'
        Description = 'site copy is checked before the deterministic asset gate and release copy binds to the published semver tag'
    }
)
$siteActionUses = [regex]::Matches(
    $siteDeployWorkflowText,
    '(?m)^\s*uses:\s+(?<action>[^\s@]+)@(?<ref>[^\s#]+)'
)
if ($siteActionUses.Count -ne 4 -or
    @($siteActionUses | Where-Object {
        $_.Groups['ref'].Value -cnotmatch '^[0-9a-f]{40}$'
    }).Count -ne 0) {
    throw 'Every site deployment action must use a full immutable commit SHA.'
}
$wranglerUses = @($siteActionUses | Where-Object {
    $_.Groups['action'].Value -ceq 'cloudflare/wrangler-action'
})
if ($wranglerUses.Count -ne 2 -or
    @($wranglerUses | Where-Object {
        $_.Groups['ref'].Value -cne 'ebbaa1584979971c8614a24965b4405ff95890e0'
    }).Count -ne 0) {
    throw 'Canary and production must use the pinned official Wrangler action v4 commit.'
}
foreach ($deployStepName in @(
    'Deploy exact payload to canary',
    'Deploy identical payload to production'
)) {
    $deployStep = Get-YamlStepBlock `
        -Content $siteDeployWorkflowText `
        -Name $deployStepName `
        -Source $siteDeployWorkflow
        Invoke-ContractTable -Contracts @(
        @{
            File = "$siteDeployWorkflow :: $deployStepName"
            Content = {
                $deployStep
            }
            Pattern = '(?ms)wranglerVersion: 4\.114\.0.*?workingDirectory: \$\{\{ steps\.payload\.outputs\.wrangler_directory \}\}.*?pages deploy "\$\{\{ steps\.payload\.outputs\.directory \}\}".*?--project-name=noctty.*?--commit-hash="\$\{\{ steps\.source\.outputs\.sha \}\}".*?--commit-dirty=false'
            Kind = 'Text'
            Description = 'isolated Wrangler deploys the same clean exact-commit payload with the required version and visible diagnostics'
        }
    )
    if ($deployStep -match '(?m)^\s*quiet:') {
        throw "Cloudflare deployment diagnostics must remain visible ($siteDeployWorkflow :: $deployStepName)"
    }
}
foreach ($phase in @('canary', 'production')) {
        Invoke-ContractTable -Contracts @(
        @{
            File = "$siteDeployWorkflow :: $phase head gate"
            Content = {
                (Get-YamlStepBlock -Content $siteDeployWorkflowText -Name "Require exact origin main before $phase" -Source $siteDeployWorkflow)
            }
            Pattern = "(?ms)require-site-deployment-head\.ps1.*?-ExpectedSha \`$env:DEPLOY_SHA.*?-DefaultBranch \`$env:DEFAULT_BRANCH.*?-Phase $phase"
            Kind = 'Text'
            Description = "site deployment invokes the shared exact-main gate before $phase"
        }
    )
}
Invoke-ContractTable -Contracts @(
    @{
        File = $siteDeploymentHeadGate
        Content = {
            (Get-Content -LiteralPath $siteDeploymentHeadGate -Raw)
        }
        Pattern = '(?ms)GITHUB_REPOSITORY -cne ''amanthanvi/noctty''.*?git remote get-url origin.*?git fetch --force --no-tags origin.*?git rev-parse HEAD.*?refs/remotes/origin/\$DefaultBranch.*?\$head -cne \$ExpectedSha.*?git status --porcelain=v1 --untracked-files=all'
        Kind = 'Text'
        Description = 'the shared site gate binds both phases to a clean exact fork-local main head'
    }
    @{
        File = $siteDeploymentHeadGate
        Content = {
            (Get-Content -LiteralPath $siteDeploymentHeadGate -Raw)
        }
        Pattern = '(?ms)\$originOutput = git remote get-url origin.*?\$LASTEXITCODE -ne 0.*?\$headOutput = git rev-parse HEAD.*?\$LASTEXITCODE -ne 0.*?\$originHeadOutput = git rev-parse.*?\$LASTEXITCODE -ne 0.*?\$status = @\(git status.*?\$LASTEXITCODE -ne 0.*?\$status\.Count -ne 0'
        Kind = 'Text'
        Description = 'every deployment gate git query checks its own exit status before consuming output'
    }
)
$sitePayloadStep = Get-YamlStepBlock `
    -Content $siteDeployWorkflowText `
    -Name 'Build deterministic deploy payload twice' `
    -Source $siteDeployWorkflow
Invoke-ContractTable -Contracts @(
    @{
        File = "$siteDeployWorkflow :: payload"
        Content = {
            $sitePayloadStep
        }
        Pattern = '(?ms)build-site-payload\.ps1.*?build-site-payload\.ps1.*?SequenceEqual\[byte\].*?different sorted SHA-256 manifests'
        Kind = 'Text'
        Description = 'site payload is built twice and compared by its sorted SHA-256 manifest'
    }
    @{
        File = "$siteDeployWorkflow :: payload"
        Content = {
            $sitePayloadStep
        }
        Pattern = '(?ms)noctty-wrangler-.*?New-Item -ItemType Directory -Path \$wrangler.*?wrangler_directory='
        Kind = 'Text'
        Description = 'Wrangler installs in a runner-temporary directory outside the checkout'
    }
    @{
        File = "$siteDeployWorkflow :: canary verification"
        Content = {
            (Get-YamlStepBlock -Content $siteDeployWorkflowText -Name 'Verify canary provenance and bytes' -Source $siteDeployWorkflow)
        }
        Pattern = '(?ms)DEPLOY_SHA: \$\{\{ steps\.source\.outputs\.sha \}\}.*?-ExpectedEnvironment preview.*?-ExpectedBranch \$env:CANARY_BRANCH.*?-ExpectedCommit \$env:DEPLOY_SHA.*?-ManifestPath \$env:PAYLOAD_MANIFEST'
        Kind = 'Text'
        Description = 'canary verification binds API provenance and payload bytes to the exact commit'
    }
    @{
        File = "$siteDeployWorkflow :: redirect preflight"
        Content = {
            (Get-YamlStepBlock -Content $siteDeployWorkflowText -Name 'Require the zone-owned www redirect before production' -Source $siteDeployWorkflow)
        }
        Pattern = '(?ms)DEPLOY_SHA: \$\{\{ steps\.source\.outputs\.sha \}\}.*?-Mode Redirect.*?-DeploymentId \$env:DEPLOYMENT_ID.*?-ExpectedCommit \$env:DEPLOY_SHA'
        Kind = 'Text'
        Description = 'the zone-owned www redirect is verified before the production write'
    }
    @{
        File = "$siteDeployWorkflow :: production verification"
        Content = {
            (Get-YamlStepBlock -Content $siteDeployWorkflowText -Name 'Verify production provenance, domain, and bytes' -Source $siteDeployWorkflow)
        }
        Pattern = '(?ms)DEPLOY_SHA: \$\{\{ steps\.source\.outputs\.sha \}\}.*?-ExpectedEnvironment production.*?-ExpectedBranch main.*?-ExpectedCommit \$env:DEPLOY_SHA.*?-CanonicalBaseUrl ''https://noctty\.com/''.*?-RequireCanonical.*?-VerifyWwwRedirect'
        Kind = 'Text'
        Description = 'production verification binds the canonical domain and zone redirect'
    }
    @{
        File = "$siteDeployWorkflow :: canary metadata"
        Content = {
            (Get-YamlStepBlock -Content $siteDeployWorkflowText -Name 'Resolve canary branch' -Source $siteDeployWorkflow)
        }
        Pattern = '(?ms)DEPLOY_SHA: \$\{\{ steps\.source\.outputs\.sha \}\}.*?\$sha = \$env:DEPLOY_SHA'
        Kind = 'Text'
        Description = 'canary metadata receives the validated SHA through the environment'
    }
    @{
        File = $siteDeployWorkflow
        Pattern = '(?m)^\s+(?:\$sha\s*=\s*''\$\{\{ steps\.source\.outputs\.sha \}\}''|-ExpectedCommit\s+''\$\{\{ steps\.source\.outputs\.sha \}\}'')'
        Kind = 'WorkflowAbsent'
        Description = 'validated action outputs are never interpolated directly into PowerShell source'
    }
    @{
        File = $siteDeployWorkflow
        Pattern = '(?i)rollback|previous\.outputs\.deployment_id'
        Kind = 'WorkflowAbsent'
        Description = 'production verification cannot race an automatic Pages rollback'
    }
    @{
        File = $cloudflarePagesVerifier
        Pattern = '(?i)/rollback|Mode Rollback|RollbackDeploymentId'
        Kind = 'WorkflowAbsent'
        Description = 'the verifier exposes no non-atomic automatic rollback path'
    }
    @{
        File = $site404
        Content = {
            $site404Text
        }
        Pattern = '(?ms)href="/assets/favicon\.svg".*?href="/styles\.css\?v=[0-9a-f]{64}".*?src="/app\.js\?v=[0-9a-f]{64}"'
        Kind = 'Text'
        Description = 'the nested 404 fallback resolves all local assets from the site root'
    }
    @{
        File = $cloudflarePagesVerifier
        Content = {
            $cloudflarePagesVerifierText
        }
        Pattern = '"/__noctty_missing_\$\(\$Commit\.Substring\(0, 12\)\)/nested/page"'
        Kind = 'Text'
        Description = 'deployment verification exercises the 404 fallback below a multi-segment path'
    }
    @{
        File = $siteIndex
        Content = {
            $siteIndexText
        }
        Pattern = '(?ms)property="og:image" content="https://noctty\.com/assets/noctty-social\.png".*?property="og:image:type" content="image/png".*?property="og:image:width" content="1200".*?property="og:image:height" content="630".*?name="twitter:card" content="summary_large_image".*?name="twitter:image" content="https://noctty\.com/assets/noctty-social\.png"'
        Kind = 'Text'
        Description = 'social previews use a current raster large-image card with explicit dimensions'
    }
    @{
        File = $sitePayloadBuilder
        Content = {
            $sitePayloadBuilderText
        }
        Pattern = "'assets/noctty-social\.png'"
        Kind = 'Text'
        Description = 'the deterministic Cloudflare payload includes the social preview image'
    }
    @{
        File = $siteGitattributes
        Content = {
            $siteGitattributesText
        }
        Pattern = '(?ms)^site/\*\.html text eol=lf\r?$.*?^site/\*\.css text eol=lf\r?$.*?^site/\*\.js text eol=lf\r?$.*?^site/_headers text eol=lf\r?$.*?^site/assets/\*\.svg text eol=lf\r?$.*?^site/tests/\*\.mjs text eol=lf\r?$.*?^scripts/build-site-assets\.mjs text eol=lf\r?$'
        Kind = 'Text'
        Description = 'every text file in the site payload and its source graph has a deterministic LF checkout rule'
    }
    @{
        File = $siteAssetBuilder
        Content = {
            $siteAssetBuilderText
        }
        Pattern = '(?ms)const checkOnly = process\.argv\.includes\("--check"\).*?if \(/\\r/\.test\(text\)\) \{.*?must be LF-normalized'
        Kind = 'Text'
        Description = 'the asset builder has a --check mode and rejects CR bytes so hashes bind to clean LF checkouts'
    }
    @{
        File = $siteAssetBuilder
        Content = {
            $siteAssetBuilderText
        }
        Pattern = '(?ms)function getInlineScriptContract.*?\["index\.html", "404\.html"\].*?inlineScripts\.length !== 1.*?sharedScript !== undefined.*?must be byte-identical'
        Kind = 'Text'
        Description = 'both pages must carry one byte-identical inline bootstrap so the CSP pins exactly one script hash'
    }
    @{
        File = $siteAssetBuilder
        Content = {
            $siteAssetBuilderText
        }
        Pattern = '(?ms)scriptHashes: \[`sha256-\$\{sha256Base64\(sharedScript\)\}`\].*?scriptAttributeHashes: \[`sha256-\$\{sha256Base64\(sharedOnload\)\}`\].*?script-src.*?scriptHashes.*?script-src-attr.*?scriptAttributeHashes'
        Kind = 'Text'
        Description = 'the asset builder derives both CSP hashes from the live HTML sources'
    }
    @{
        File = $siteAssetBuilder
        Content = {
            $siteAssetBuilderText
        }
        Pattern = '(?ms)for \(const asset of \["styles\.css", "app\.js", "version\.js", "install\.js", "terminal\.js"\]\).*?withAssetCacheKeys\(indexHtml.*?withAssetCacheKeys\(notFoundHtml, "site/404\.html", \{\s*"styles\.css": assetHashes\["styles\.css"\],\s*"app\.js": assetHashes\["app\.js"\],\s*\}\)'
        Kind = 'Text'
        Description = 'SHA-256 cache keys cover every local script and stylesheet referenced by each page'
    }
    @{
        File = $siteAssetBuilder
        Content = {
            $siteAssetBuilderText
        }
        Pattern = '(?ms)if \(failures\.length > 0\) \{\s*throw new Error\(`Deterministic site asset check failed'
        Kind = 'Text'
        Description = 'the deterministic asset check fails closed when committed hashes or cache keys are stale'
    }
    @{
        File = $cloudflarePagesVerifier
        Content = {
            $cloudflarePagesVerifierText
        }
        Pattern = '(?ms)latest_stage\.status.*?commit_hash -cne \$Commit.*?commit_dirty -ne \$false.*?Get-ManifestEntries.*?Get-Sha256 -Bytes.*?get-site-header-contract\.ps1.*?Assert-PublicHeaderContract'
        Kind = 'Text'
        Description = 'Pages verification checks exact clean commit provenance, manifest bytes, and response controls'
    }
)
$cloudflareApiTokens = $null
$cloudflareApiErrors = $null
$cloudflareApiAst = [System.Management.Automation.Language.Parser]::ParseInput(
    (Get-PowerShellBlockText `
        -Content $cloudflarePagesVerifierText `
        -HeaderPattern '^function\s+Invoke-CloudflareApi(?=\s|\{)'),
    [ref] $cloudflareApiTokens,
    [ref] $cloudflareApiErrors
)
if ($cloudflareApiErrors.Count -ne 0) {
    throw 'Cloudflare API verifier function must parse for semantic contract checks.'
}
$cloudflareApiFunctions = @(
    Get-NamedFunctionDefinitions -Ast $cloudflareApiAst -Name 'Invoke-CloudflareApi'
)
if ($cloudflareApiFunctions.Count -ne 1) {
    throw 'Pages verifier must define exactly one Invoke-CloudflareApi function.'
}
$cloudflareApiFunction = $cloudflareApiFunctions[0]
$relativePathParameters = @(
    $cloudflareApiFunction.Body.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -ceq 'RelativePath' }
)
$relativePathAttributes = @(
    $relativePathParameters.Attributes |
        Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] }
)
if ($relativePathParameters.Count -ne 1 -or
    $relativePathAttributes.Count -ne 2 -or
    @($relativePathAttributes | Where-Object {
            $_.TypeName.FullName -cin @('Parameter', 'AllowEmptyString')
        }).Count -ne 2) {
    throw 'Pages project-root relative path must be mandatory, allow empty input, and have no conflicting validation.'
}
$requestConstructors = @(
    $cloudflareApiFunction.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $node.Expression.TypeName.FullName -ceq 'Net.Http.HttpRequestMessage' -and
            $node.Member.Value -ceq 'new'
    }, $true)
)
$sendRequests = @(
    Get-NamedMemberExpressions `
        -Ast $cloudflareApiFunction `
        -Name 'SendAsync' `
        -InvocationOnly
)
if ($requestConstructors.Count -ne 1 -or
    $requestConstructors[0].Arguments.Count -ne 2 -or
    $requestConstructors[0].Arguments[0] -isnot
        [System.Management.Automation.Language.VariableExpressionAst] -or
    $requestConstructors[0].Arguments[0].VariablePath.UserPath -cne 'Method' -or
    $requestConstructors[0].Arguments[1] -isnot
        [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
    $requestConstructors[0].Arguments[1].Value -cne '$apiRoot$RelativePath' -or
    @($requestConstructors[0].Arguments[1].NestedExpressions).Count -ne 2 -or
    $requestConstructors[0].Arguments[1].NestedExpressions[0].VariablePath.UserPath -cne 'apiRoot' -or
    $requestConstructors[0].Arguments[1].NestedExpressions[1].VariablePath.UserPath -cne 'RelativePath' -or
    $requestConstructors[0].Parent.Parent -isnot
        [System.Management.Automation.Language.AssignmentStatementAst] -or
    $requestConstructors[0].Parent.Parent.Left.VariablePath.UserPath -cne 'request' -or
    $sendRequests.Count -ne 1 -or
    $sendRequests[0].Expression.VariablePath.UserPath -cne 'apiClient' -or
    $sendRequests[0].Arguments.Count -ne 1 -or
    $sendRequests[0].Arguments[0].VariablePath.UserPath -cne 'request') {
    throw 'Pages project-root URI must be the exact API root plus relative path used by the sent HTTP request.'
}
Invoke-ContractTable -Contracts @(
    @{
        File = "$cloudflarePagesVerifier :: Wait-CanonicalDeployment"
        Content = {
            (Get-PowerShellBlockText -Content $cloudflarePagesVerifierText -HeaderPattern '^function\s+Wait-CanonicalDeployment(?=\s|\{)')
        }
        Pattern = '(?ms)for \(\$attempt = 1; \$attempt -le 10; \$attempt\+\+\).*?try \{\s*\$project = Get-Project.*?catch \{.*?\$attempt -eq 10.*?failed after bounded retries.*?Start-Sleep -Seconds 2.*?continue.*?Assert-ProjectContract.*?Get-CanonicalDeploymentId'
        Kind = 'Text'
        Description = 'canonical promotion tolerates bounded transient project API failures but still validates project identity'
    }
    @{
        File = $cloudflarePagesVerifier
        Pattern = '(?i)cf-mitigated|AllowMitigatedHtml|mitigated-challenge|challenged_hosts|canonical_html_status'
        Kind = 'WorkflowAbsent'
        Description = 'custom-domain verification cannot accept substituted challenge HTML'
    }
)
$publicBaseUriFunctionText = Get-PowerShellBlockText `
    -Content $cloudflarePagesVerifierText `
    -HeaderPattern '^function\s+ConvertTo-PublicBaseUri(?=\s|\{)'
. ([scriptblock]::Create($publicBaseUriFunctionText))
$immutablePagesOrigin = ConvertTo-PublicBaseUri `
    -Value 'https://69cd5628.noctty.pages.dev/' `
    -Kind pages
if ($immutablePagesOrigin.DnsSafeHost -cne
    '69cd5628.noctty.pages.dev') {
    throw 'Immutable Pages deployment origin was not preserved.'
}
foreach ($mutablePagesUrl in @(
    'https://noctty.pages.dev/',
    'https://main.noctty.pages.dev/'
)) {
    $mutablePagesOriginRejected = $false
    try {
        [void](ConvertTo-PublicBaseUri `
            -Value $mutablePagesUrl `
            -Kind pages)
    } catch {
        $mutablePagesOriginRejected = $true
    }
    if (-not $mutablePagesOriginRejected) {
        throw "Mutable Pages origin passed immutable validation: $mutablePagesUrl"
    }
}
$immutableOriginBindingFunctionText = Get-PowerShellBlockText `
    -Content $cloudflarePagesVerifierText `
    -HeaderPattern '^function\s+Assert-ImmutablePagesDeploymentOrigin(?=\s|\{)'
. ([scriptblock]::Create($immutableOriginBindingFunctionText))
Assert-ImmutablePagesDeploymentOrigin `
    -Origin $immutablePagesOrigin `
    -DeploymentId '69cd5628-1d01-4095-9774-6f8cfe7d7d1e'
$mismatchedDeploymentIdRejected = $false
try {
    Assert-ImmutablePagesDeploymentOrigin `
        -Origin $immutablePagesOrigin `
        -DeploymentId 'deadbeef-1d01-4095-9774-6f8cfe7d7d1e'
} catch {
    $mismatchedDeploymentIdRejected = $true
}
if (-not $mismatchedDeploymentIdRejected) {
    throw 'Immutable Pages origin was not bound to its deployment ID.'
}
$cloudflareVerifierTokens = $null
$cloudflareVerifierErrors = $null
$cloudflareVerifierAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $cloudflarePagesVerifierText,
    [ref]$cloudflareVerifierTokens,
    [ref]$cloudflareVerifierErrors
)
if ($cloudflareVerifierErrors.Count -ne 0) {
    throw 'Cloudflare verifier must parse for public-verification call checks.'
}
$immutableOriginBindingCalls = @($cloudflareVerifierAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Assert-ImmutablePagesDeploymentOrigin'
}, $true))
$urlIdentityChecks = @($cloudflareVerifierAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains(
            'Wrangler deployment URL does not match Cloudflare API provenance.'
        )
}, $true))
if ($immutableOriginBindingCalls.Count -ne 1 -or
    $urlIdentityChecks.Count -ne 1) {
    throw 'Deployment flow must contain one URL identity check and origin binding.'
}
$originBindingElements = @($immutableOriginBindingCalls[0].CommandElements)
if ($originBindingElements.Count -ne 5 -or
    $originBindingElements[1] -isnot [System.Management.Automation.Language.CommandParameterAst] -or
    $originBindingElements[1].ParameterName -cne 'Origin' -or
    $originBindingElements[3] -isnot [System.Management.Automation.Language.CommandParameterAst] -or
    $originBindingElements[3].ParameterName -cne 'DeploymentId') {
    throw 'Deployment flow must pass its Pages origin and deployment ID to the immutable-origin binding.'
}
$deploymentFlowOwner = Get-ContainingStatementBlock -Node $urlIdentityChecks[0]
$originBindingStatement = Get-DirectStatementBlockChild -Node $immutableOriginBindingCalls[0] -StatementBlock $deploymentFlowOwner
$urlIdentityStatement = Get-DirectStatementBlockChild -Node $urlIdentityChecks[0] -StatementBlock $deploymentFlowOwner
$deploymentFlowStatements = @($deploymentFlowOwner.Statements)
$urlIdentityStatementIndex = -1
$originBindingStatementIndex = -1
for ($statementIndex = 0; $statementIndex -lt $deploymentFlowStatements.Count; $statementIndex++) {
    if ([object]::ReferenceEquals($deploymentFlowStatements[$statementIndex], $urlIdentityStatement)) {
        $urlIdentityStatementIndex = $statementIndex
    }
    if ([object]::ReferenceEquals($deploymentFlowStatements[$statementIndex], $originBindingStatement)) {
        $originBindingStatementIndex = $statementIndex
    }
}
if ($urlIdentityStatementIndex -lt 0 -or $originBindingStatementIndex -lt 0) {
    throw 'Unable to isolate deployment URL identity and origin-binding behavior.'
}
$deploymentSliceStart = [Math]::Min($urlIdentityStatementIndex, $originBindingStatementIndex)
$deploymentSliceEnd = [Math]::Max($urlIdentityStatementIndex, $originBindingStatementIndex)
$deploymentSliceText = (
    $deploymentFlowStatements[$deploymentSliceStart..$deploymentSliceEnd] |
        ForEach-Object { $_.Extent.Text }
) -join [Environment]::NewLine
$priorOriginBindingFunction = Get-Item Function:\Assert-ImmutablePagesDeploymentOrigin -ErrorAction SilentlyContinue
$script:originBindingProbeCalls = 0
$script:originBindingProbeOrigin = $null
$script:originBindingProbeDeploymentId = $null
function Assert-ImmutablePagesDeploymentOrigin {
    param([Uri] $Origin, [string] $DeploymentId)
    $script:originBindingProbeCalls++
    $script:originBindingProbeOrigin = $Origin
    $script:originBindingProbeDeploymentId = $DeploymentId
}
try {
    $pagesOrigin = [Uri]'https://11111111.noctty.pages.dev/'
    $apiOrigin = [Uri]'https://22222222.noctty.pages.dev/'
    $DeploymentId = '11111111-1d01-4095-9774-6f8cfe7d7d1e'
    $mismatchMessage = $null
    try {
        & ([scriptblock]::Create($deploymentSliceText))
    }
    catch {
        $mismatchMessage = $_.Exception.Message
    }
    if ($mismatchMessage -ne 'Wrangler deployment URL does not match Cloudflare API provenance.' -or
        $script:originBindingProbeCalls -ne 0) {
        throw 'Deployment URL mismatch must fail before immutable-origin binding is invoked.'
    }

    $apiOrigin = $pagesOrigin
    & ([scriptblock]::Create($deploymentSliceText))
    if ($script:originBindingProbeCalls -ne 1 -or
        $script:originBindingProbeOrigin.AbsoluteUri -ne $pagesOrigin.AbsoluteUri -or
        $script:originBindingProbeDeploymentId -ne $DeploymentId) {
        throw 'Matching deployment provenance must invoke immutable-origin binding exactly once with the observed origin and deployment ID.'
    }
}
finally {
    Remove-Item Function:\Assert-ImmutablePagesDeploymentOrigin -ErrorAction SilentlyContinue
    if ($null -ne $priorOriginBindingFunction) {
        Set-Item Function:\Assert-ImmutablePagesDeploymentOrigin -Value $priorOriginBindingFunction.ScriptBlock
    }
    Remove-Variable -Scope Script -Name originBindingProbeCalls, originBindingProbeOrigin, originBindingProbeDeploymentId -ErrorAction SilentlyContinue
}
$publicVerificationCalls = @($cloudflareVerifierAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -cin @(
            'Assert-PublicPayload',
            'Assert-PublicHeaderContract'
        )
}, $true))
$expectedPublicVerificationCalls = @(
    [pscustomobject]@{
        Command = 'Assert-PublicPayload'
        Origin = 'pagesOrigin'
        StaticOnly = $false
    }
    [pscustomobject]@{
        Command = 'Assert-PublicHeaderContract'
        Origin = 'pagesOrigin'
        StaticOnly = $false
    }
    [pscustomobject]@{
        Command = 'Assert-PublicPayload'
        Origin = 'canonicalOrigin'
        StaticOnly = $true
    }
    [pscustomobject]@{
        Command = 'Assert-PublicHeaderContract'
        Origin = 'canonicalOrigin'
        StaticOnly = $true
    }
)
foreach ($expectedCall in $expectedPublicVerificationCalls) {
    $matchingCalls = @($publicVerificationCalls | Where-Object {
        $elements = @($_.CommandElements)
        $originIndex = [Array]::FindIndex(
            [object[]]$elements,
            [Predicate[object]] { param($element) $element.Extent.Text -ceq '-Origin' }
        )
        $originIndex -ge 0 -and
            $originIndex + 1 -lt $elements.Count -and
            $elements[$originIndex + 1] -is
                [System.Management.Automation.Language.VariableExpressionAst] -and
            $elements[$originIndex + 1].VariablePath.UserPath -ceq
                $expectedCall.Origin -and
            $_.GetCommandName() -ceq $expectedCall.Command -and
            (@($elements | Where-Object {
                $_.Extent.Text -ceq '-StaticOnly'
            }).Count -eq 1) -eq $expectedCall.StaticOnly
    })
    if ($matchingCalls.Count -ne 1) {
        throw "Expected exactly one $($expectedCall.Command) call for " +
            "$($expectedCall.Origin) with StaticOnly=$($expectedCall.StaticOnly)."
    }
}
if ($publicVerificationCalls.Count -ne $expectedPublicVerificationCalls.Count) {
    throw 'Unexpected public-verification call bypasses the immutable/canonical policy.'
}
$expectedPublicVerificationWrappers = @(
    [pscustomobject]@{
        Wrapper = 'Assert-PublicPayload'
        Inner = 'Test-PublicPayloadOnce'
    }
    [pscustomobject]@{
        Wrapper = 'Assert-PublicHeaderContract'
        Inner = 'Test-PublicHeaderContractOnce'
    }
)
foreach ($expectedWrapper in $expectedPublicVerificationWrappers) {
    $wrapperDefinitions = @(
        Get-NamedFunctionDefinitions `
            -Ast $cloudflareVerifierAst `
            -Name $expectedWrapper.Wrapper
    )
    if ($wrapperDefinitions.Count -ne 1) {
        throw "Expected exactly one $($expectedWrapper.Wrapper) function."
    }
    $staticOnlyParameters = @(
        $wrapperDefinitions[0].Body.ParamBlock.Parameters |
            Where-Object {
                $_.Name.VariablePath.UserPath -ceq 'StaticOnly'
            }
    )
    $innerCalls = @($wrapperDefinitions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq $expectedWrapper.Inner
    }, $true))
    $forwardedSwitches = @(
        if ($innerCalls.Count -eq 1) {
            $innerCalls[0].CommandElements |
                Where-Object {
                    $_ -is
                        [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -ceq 'StaticOnly' -and
                    $_.Argument -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $_.Argument.VariablePath.UserPath -ceq 'StaticOnly'
                }
        }
    )
    if ($staticOnlyParameters.Count -ne 1 -or
        $staticOnlyParameters[0].StaticType -ne [switch] -or
        $innerCalls.Count -ne 1 -or
        $forwardedSwitches.Count -ne 1) {
        throw "$($expectedWrapper.Wrapper) must forward exactly " +
            "-StaticOnly:`$StaticOnly to $($expectedWrapper.Inner)."
    }
}
Invoke-ContractTable -Contracts @(
    @{
        File = "$cloudflarePagesVerifier :: Test-PublicPayloadOnce"
        Content = {
            (Get-PowerShellBlockText -Content $cloudflarePagesVerifierText -HeaderPattern '^function\s+Test-PublicPayloadOnce(?=\s|\{)')
        }
        Pattern = '(?ms)\[switch\]\s+\$StaticOnly.*?\$entry\.Path -ceq ''_headers''.*?\$StaticOnly -and \$entry\.Path -cin @\(''index\.html'', ''404\.html''\).*?continue.*?New-PublicAssetUri'
        Kind = 'Text'
        Description = 'static-only payload verification excludes only Pages control and HTML documents before hashing remaining assets'
    }
    @{
        File = "$cloudflarePagesVerifier :: Test-PublicHeaderContractOnce"
        Content = {
            (Get-PowerShellBlockText -Content $cloudflarePagesVerifierText -HeaderPattern '^function\s+Test-PublicHeaderContractOnce(?=\s|\{)')
        }
        Pattern = '(?ms)\[switch\]\s+\$StaticOnly.*?if \(-not \$StaticOnly\) \{.*?Path = ''/''.*?\}.*?Path = ''/styles\.css''.*?if \(-not \$StaticOnly\) \{.*?Path = ''/__noctty_header_contract_'''
        Kind = 'Text'
        Description = 'static-only response verification always checks stylesheet asset controls and excludes HTML route probes'
    }
    @{
        File = $cloudflarePagesVerifier
        Content = {
            $cloudflarePagesVerifierText
        }
        Pattern = '(?ms)schema_version\s*=\s*''noctty\.cloudflare-pages-provenance\.v2''.*?immutable_html_verified\s*=\s*\$true.*?canonical_static_assets_verified\s*=\s*-not \[string\]::IsNullOrWhiteSpace\(\$CanonicalBaseUrl\).*?canonical_html_verified\s*=\s*\$false'
        Kind = 'Text'
        Description = 'deployment provenance distinguishes immutable HTML, canonical static assets, and unverified canonical HTML'
    }
    @{
        File = $cloudflarePagesVerifier
        Content = {
            $cloudflarePagesVerifierText
        }
        Pattern = '(?ms)\$json\.Contains\(\$ApiToken.*?\$json\.Contains\(\$AccountId.*?Refusing to write provenance containing Cloudflare credentials'
        Kind = 'Text'
        Description = 'deployment provenance fails closed if credentials or account identifiers enter the artifact'
    }
    @{
        File = $siteDeployWorkflow
        Pattern = '(?i)wrangler\.(?:toml|json|jsonc)'
        Kind = 'WorkflowAbsent'
        Description = 'Direct Upload does not introduce Wrangler configuration'
    }
)
if (Test-Path -LiteralPath (Join-Path $repoRoot 'site\_redirects')) {
    throw 'Unsupported domain-level Pages _redirects file must remain absent.'
}
Invoke-ContractTable -Contracts @(
    @{
        File = $siteReadme
        Content = {
            $siteReadmeText
        }
        Pattern = '(?ms)Direct Upload.*?every\s+push to `main`.*?pull requests do not deploy.*?zone-owned `www` redirect\s+is preflighted.*?does not automatically roll back.*?zone level.*?workflow verifies the zone-level 301.*?deployment-only scripts require PowerShell 7\.3 or newer.*?outside the Windows PowerShell 5\.1 harness compatibility scope'
        Kind = 'Text'
        Description = 'site operations document deployment triggers, Direct Upload scope, runtime floor, and the zone-owned redirect'
    }
    @{
        File = $siteHeaders
        Content = {
            $siteHeadersText
        }
        Pattern = '(?ms)^/\*\s+Content-Security-Policy:.*?X-Content-Type-Options: nosniff.*?X-Frame-Options: DENY.*?Referrer-Policy: strict-origin-when-cross-origin.*?Permissions-Policy:.*?Cache-Control: public, max-age=0, must-revalidate\s*$'
        Kind = 'Text'
        Description = 'Pages uses one catch-all browser security and revalidation policy'
    }
    @{
        File = $siteHeaders
        Pattern = '(?m)^/(?!\*)'
        Kind = 'WorkflowAbsent'
        Description = 'path-specific cache rules cannot overlap the catch-all response policy'
    }
    @{
        File = $siteHeaders
        Content = {
            $siteHeadersText
        }
        Pattern = "(?ms)script-src 'self' 'sha256-[^']+'; script-src-attr 'unsafe-hashes' 'sha256-[^']+';"
        Kind = 'Text'
        Description = 'the single shared inline bootstrap and the font load handler each use one narrow CSP hash'
    }
    @{
        File = $siteHeaders
        Content = {
            $siteHeadersText
        }
        Pattern = "style-src 'self' https://fonts\.googleapis\.com;"
        Kind = 'Text'
        Description = 'stylesheet sources are pinned to self plus Google Fonts without inline styles'
    }
    @{
        File = $siteHeaders
        Pattern = "(?i)'unsafe-inline'|style-src-attr"
        Kind = 'WorkflowAbsent'
        Description = 'the site CSP declares no unsafe-inline source and no style-src-attr directive'
    }
)
$siteHeaderContractJson = & $siteHeaderContract `
    -SiteDirectory (Join-Path $repoRoot 'site')
$siteHeaderContractObject = $siteHeaderContractJson | ConvertFrom-Json -Depth 6
if ([string]$siteHeaderContractObject.root.content_security_policy -cne
        [string](
            [regex]::Match(
                $siteHeadersText,
                '(?m)^\s+Content-Security-Policy:\s*(?<value>.+)$'
            ).Groups['value'].Value.Trim()
        )) {
    throw 'Central site header contract did not return the tracked CSP.'
}
if ([string]$siteHeaderContractObject.not_found.cache_control -cne 'no-store') {
    throw 'Central site header contract must require generated 404 responses not to be cached.'
}
Invoke-ContractTable -Contracts @(
    @{
        File = $siteAssetBuilder
        Content = {
            $siteAssetBuilderText
        }
        Pattern = '(?ms)--print-header-contract.*?generated_headers_base64.*?script_hashes.*?script_attribute_hashes'
        Kind = 'Text'
        Description = 'the site asset builder exposes its generated _headers and derived CSP hashes as one machine-readable contract'
    }
    @{
        File = $siteAssetBuilder
        Content = {
            $siteAssetBuilderText
        }
        Pattern = '(?ms)function getHeaderContract.*?default-src.*?script-src.*?script-src-attr.*?upgrade-insecure-requests.*?contentSecurityPolicy.*?generated_headers_base64.*?content_security_policy: contentSecurityPolicy'
        Kind = 'Text'
        Description = 'one builder-owned directive table emits the exact CSP and generated _headers byte contract'
    }
    @{
        File = $siteAssetBuilder
        Content = {
            $siteAssetBuilderText
        }
        Pattern = '(?ms)function updateOrCheck.*?checkOnly.*?failures\.push.*?fs\.writeFileSync.*?expectedHeaders = Buffer\.from.*?generated_headers_base64.*?updateOrCheck\("_headers", expectedHeaders, headers\)'
        Kind = 'Text'
        Description = 'normal builds generate _headers and check mode requires byte-exact generated output'
    }
    @{
        File = $siteHeaderContract
        Content = {
            (Get-Content -LiteralPath $siteHeaderContract -Raw)
        }
        Pattern = '(?ms)build-site-assets\.mjs.*?--print-header-contract.*?--site-directory.*?generated_headers_base64.*?SequenceEqual\[byte\].*?does not byte-match.*?derivedHeaderContract\.root\.content_security_policy.*?ConvertTo-Json'
        Kind = 'Text'
        Description = 'the PowerShell header contract consumes and byte-verifies the builder-derived source of truth'
    }
    @{
        File = $siteHeaderContract
        Content = {
            (Get-Content -LiteralPath $siteHeaderContract -Raw)
        }
        Pattern = '(?ms)function Assert-ReviewedContentSecurityPolicy.*?ScriptHashes.*?ScriptAttributeHashes.*?base-uri.*?''none''.*?object-src.*?''none''.*?frame-ancestors.*?''none''.*?style-src.*?https://fonts\.googleapis\.com.*?font-src.*?https://fonts\.gstatic\.com.*?connect-src.*?https://api\.github\.com.*?declaredDirectives\.Count.*?dynamicHashDirectives\.Count.*?Assert-ReviewedContentSecurityPolicy.*?-Policy \$csp.*?-ScriptHashes @\(\$derivedHeaderContract\.script_hashes\).*?-ScriptAttributeHashes @\(\$derivedHeaderContract\.script_attribute_hashes\)'
        Kind = 'Text'
        Description = 'the verifier independently pins the CSP directives and origins while accepting only builder-derived SHA-256 slots'
    }
    @{
        File = $siteHeaderContract
        Content = {
            (Get-Content -LiteralPath $siteHeaderContract -Raw)
        }
        Pattern = '(?ms)expectedPermissions.*?accelerometer=\(\).*?autoplay=\(\).*?gyroscope=\(\).*?magnetometer=\(\).*?declaredPermissionTokens.*?declaredPermissions.*?expectedPermissions\.Count.*?denylist contract'
        Kind = 'Text'
        Description = 'permissions policy retains an exact duplicate-free denylist after generated-byte verification'
    }
)

$siteCspFixtureRoot = Join-Path (
    [IO.Path]::GetTempPath()
) "noctty-site-csp-contract-$PID-$([Guid]::NewGuid().ToString('N'))"
$siteCspFixtureRoot = [IO.Path]::GetFullPath($siteCspFixtureRoot)
$siteCspTempPrefix = [IO.Path]::GetFullPath(
    [IO.Path]::GetTempPath()
).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $siteCspFixtureRoot.StartsWith(
        $siteCspTempPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Refusing unsafe CSP fixture path: $siteCspFixtureRoot"
}
[IO.Directory]::CreateDirectory($siteCspFixtureRoot) | Out-Null
try {
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'site') |
        Copy-Item `
            -Destination $siteCspFixtureRoot `
            -Recurse `
            -Force
    $fixtureHeadersPath = Join-Path $siteCspFixtureRoot '_headers'
    $fixtureHeadersText = [IO.File]::ReadAllText($fixtureHeadersPath)
    $missingGitHubOriginHeaders = $fixtureHeadersText.Replace(
        ' https://api.github.com',
        ''
    )
    if ($missingGitHubOriginHeaders -ceq $fixtureHeadersText) {
        throw 'Required-origin CSP mutation target is missing.'
    }
    [IO.File]::WriteAllText(
        $fixtureHeadersPath,
        $missingGitHubOriginHeaders,
        [Text.UTF8Encoding]::new($false)
    )
    $missingGitHubOriginRejected = $false
    try {
        & $siteHeaderContract -SiteDirectory $siteCspFixtureRoot | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch
            'does not byte-match|independently reviewed|connect-src sources do not exactly match') {
            throw
        }
        $missingGitHubOriginRejected = $true
    }
    if (-not $missingGitHubOriginRejected) {
        throw 'Site CSP contract accepted removal of the required GitHub API origin.'
    }
    [IO.File]::WriteAllText(
        $fixtureHeadersPath,
        $fixtureHeadersText,
        [Text.UTF8Encoding]::new($false)
    )
    $scriptHash = [regex]::Match(
        $fixtureHeadersText,
        "script-src 'self' '(?<hash>sha256-[^']+)'"
    ).Groups['hash'].Value
    $attributeHash = [regex]::Match(
        $fixtureHeadersText,
        "script-src-attr 'unsafe-hashes' '(?<hash>sha256-[^']+)'"
    ).Groups['hash'].Value
    if ([string]::IsNullOrWhiteSpace($scriptHash) -or
        [string]::IsNullOrWhiteSpace($attributeHash)) {
        throw 'Could not identify CSP hashes for the directive-swap regression.'
    }
    $swappedHeaders = $fixtureHeadersText.Replace(
        "'$scriptHash'",
        "'__NOCTTY_SCRIPT_HASH__'"
    ).Replace(
        "'$attributeHash'",
        "'$scriptHash'"
    ).Replace(
        "'__NOCTTY_SCRIPT_HASH__'",
        "'$attributeHash'"
    )
    [IO.File]::WriteAllText(
        $fixtureHeadersPath,
        $swappedHeaders,
        [Text.UTF8Encoding]::new($false)
    )
    $directiveSwapRejected = $false
    try {
        & $siteHeaderContract -SiteDirectory $siteCspFixtureRoot | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch
            'HTML-derived header contract') {
            throw
        }
        $directiveSwapRejected = $true
    }
    if (-not $directiveSwapRejected) {
        throw 'Site CSP contract accepted hashes swapped between script directives.'
    }

    $reusedHashHeaders = $fixtureHeadersText.Replace(
        "style-src 'self'",
        "script-src-elem '$attributeHash'; style-src 'self'"
    )
    [IO.File]::WriteAllText(
        $fixtureHeadersPath,
        $reusedHashHeaders,
        [Text.UTF8Encoding]::new($false)
    )
    $unvalidatedDirectiveRejected = $false
    try {
        & $siteHeaderContract -SiteDirectory $siteCspFixtureRoot | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch
            'HTML-derived header contract') {
            throw
        }
        $unvalidatedDirectiveRejected = $true
    }
    if (-not $unvalidatedDirectiveRejected) {
        throw 'Site CSP contract accepted a reused hash in script-src-elem.'
    }

    $unsafeOverrideHeaders = $fixtureHeadersText.Replace(
        "style-src 'self'",
        "script-src-elem 'unsafe-inline'; style-src 'self'"
    )
    [IO.File]::WriteAllText(
        $fixtureHeadersPath,
        $unsafeOverrideHeaders,
        [Text.UTF8Encoding]::new($false)
    )
    $unsafeOverrideRejected = $false
    try {
        & $siteHeaderContract -SiteDirectory $siteCspFixtureRoot | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch
            'HTML-derived header contract') {
            throw
        }
        $unsafeOverrideRejected = $true
    }
    if (-not $unsafeOverrideRejected) {
        throw 'Site CSP contract accepted an unsafe script-src-elem override.'
    }

    $sha384OverrideHeaders = $fixtureHeadersText.Replace(
        "style-src 'self'",
        "script-src-elem 'sha384-YWJjZA=='; style-src 'self'"
    )
    [IO.File]::WriteAllText(
        $fixtureHeadersPath,
        $sha384OverrideHeaders,
        [Text.UTF8Encoding]::new($false)
    )
    $sha384OverrideRejected = $false
    try {
        & $siteHeaderContract -SiteDirectory $siteCspFixtureRoot | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch 'HTML-derived header contract') {
            throw
        }
        $sha384OverrideRejected = $true
    }
    if (-not $sha384OverrideRejected) {
        throw 'Site CSP contract accepted a SHA-384 script-src-elem override.'
    }

    [IO.File]::WriteAllText(
        $fixtureHeadersPath,
        $fixtureHeadersText,
        [Text.UTF8Encoding]::new($false)
    )
    $fixtureIndexPath = Join-Path $siteCspFixtureRoot 'index.html'
    $fixtureIndexText = [IO.File]::ReadAllText($fixtureIndexPath)
    [IO.File]::WriteAllText(
        $fixtureIndexPath,
        $fixtureIndexText.Replace(
            "onload=`"this.media='all'`"",
            "onload=`"this.media='screen'`""
        ),
        [Text.UTF8Encoding]::new($false)
    )
    $editedHandlerRejected = $false
    try {
        & $siteHeaderContract -SiteDirectory $siteCspFixtureRoot | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch
            'Could not derive the site header contract') {
            throw
        }
        $editedHandlerRejected = $true
    }
    if (-not $editedHandlerRejected) {
        throw 'Site CSP contract accepted an untracked event-handler edit.'
    }

    [IO.File]::WriteAllText(
        $fixtureIndexPath,
        $fixtureIndexText.Replace(
            "onload=`"this.media='all'`"",
            'onload="this.media=&#39;all&#39;"'
        ),
        [Text.UTF8Encoding]::new($false)
    )
    try {
        & $siteHeaderContract -SiteDirectory $siteCspFixtureRoot | Out-Null
    }
    catch {
        throw 'Site CSP contract did not hash the browser-decoded handler text.'
    }

    [IO.File]::WriteAllText(
        $fixtureIndexPath,
        $fixtureIndexText,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        $fixtureHeadersPath,
        $fixtureHeadersText.Replace('accelerometer=()', 'accelerometer=(self)'),
        [Text.UTF8Encoding]::new($false)
    )
    $weakenedPermissionRejected = $false
    try {
        & $siteHeaderContract -SiteDirectory $siteCspFixtureRoot | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch
            'HTML-derived header contract') {
            throw
        }
        $weakenedPermissionRejected = $true
    }
    if (-not $weakenedPermissionRejected) {
        throw 'Site header contract accepted a weakened permissions policy.'
    }
}
finally {
    if ([IO.Directory]::Exists($siteCspFixtureRoot)) {
        [IO.Directory]::Delete($siteCspFixtureRoot, $true)
    }
}
Invoke-ContractTable -Contracts @(
    @{
        File = "$cloudflarePagesVerifier :: Test-PublicHeaderContractOnce"
        Content = {
            (Get-PowerShellBlockText -Content $cloudflarePagesVerifierText -HeaderPattern '^function\s+Test-PublicHeaderContractOnce(?=\s|\{)')
        }
        Pattern = "(?ms)Path = '/'.*?ExpectedStatus = 200.*?Path = '/styles\.css'.*?ExpectedStatus = 200.*?__noctty_header_contract_.*?nested/page'.*?ExpectedStatus = 404.*?Cache-Control"
        Kind = 'Text'
        Description = 'public header verification covers canonical HTML, an asset, and a nested 404 fallback'
    }
)
$cacheControlContract = Get-PowerShellBlockText `
    -Content $cloudflarePagesVerifierText `
    -HeaderPattern '^function\s+Test-EquivalentCacheControl(?=\s|\{)'
. ([scriptblock]::Create($cacheControlContract))
if (-not (Test-EquivalentCacheControl `
        -Actual 'PUBLIC, must-revalidate, max-age=0' `
        -Expected 'public, max-age=0, must-revalidate') -or
    -not (Test-EquivalentCacheControl -Actual 'no-store' -Expected 'no-store') -or
    (Test-EquivalentCacheControl `
        -Actual 'public, max-age=0' `
        -Expected 'public, max-age=0, must-revalidate') -or
    (Test-EquivalentCacheControl `
        -Actual 'public, max-age=0, must-revalidate, immutable' `
        -Expected 'public, max-age=0, must-revalidate') -or
    (Test-EquivalentCacheControl `
        -Actual 'public, public, max-age=0, must-revalidate' `
        -Expected 'public, max-age=0, must-revalidate') -or
    (Test-EquivalentCacheControl `
        -Actual '' `
        -Expected 'public, max-age=0, must-revalidate')) {
    throw 'Published cache-control verification must ignore order and case but reject missing, extra, or duplicate directives.'
}
Invoke-ContractTable -Contracts @(
    @{
        File = "$cloudflarePagesVerifier :: Test-PublicHeaderContractOnce"
        Content = {
            (Get-PowerShellBlockText -Content $cloudflarePagesVerifierText -HeaderPattern '^function\s+Test-PublicHeaderContractOnce(?=\s|\{)')
        }
        Pattern = '(?ms)ExpectedStatus = 404.*?ExpectedCache = \[string\]\$Contract\.not_found\.cache_control.*?Test-EquivalentCacheControl.*?-Actual \$cacheControl.*?-Expected \$probe\.ExpectedCache'
        Kind = 'Text'
        Description = 'published headers compare exact cache directive sets and require no-store for generated 404 responses'
    }
    @{
        File = "$cloudflarePagesVerifier :: Assert-PublicHeaderContract"
        Content = {
            (Get-PowerShellBlockText -Content $cloudflarePagesVerifierText -HeaderPattern '^function\s+Assert-PublicHeaderContract(?=\s|\{)')
        }
        Pattern = '(?ms)for \(\$attempt = 1; \$attempt -le 6; \$attempt\+\+\).*?Test-PublicHeaderContractOnce.*?Start-Sleep -Seconds 2.*?did not converge'
        Kind = 'Text'
        Description = 'public header verification tolerates bounded edge propagation before failing closed'
    }
)

$sitePayloadFixtureRoot = Join-Path (
    [IO.Path]::GetTempPath()
) "noctty-site-payload-contract-$PID-$([Guid]::NewGuid().ToString('N'))"
$sitePayloadFixtureRoot = [IO.Path]::GetFullPath($sitePayloadFixtureRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
if (-not $sitePayloadFixtureRoot.StartsWith(
        $tempPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Site payload contract fixture escaped the system temp directory.'
}
try {
    $firstPayload = Join-Path $sitePayloadFixtureRoot 'first'
    $secondPayload = Join-Path $sitePayloadFixtureRoot 'second'
    $firstManifest = Join-Path $sitePayloadFixtureRoot 'first.sha256'
    $secondManifest = Join-Path $sitePayloadFixtureRoot 'second.sha256'
    & $sitePayloadBuilder `
        -OutputDirectory $firstPayload `
        -ManifestPath $firstManifest
    & $sitePayloadBuilder `
        -OutputDirectory $secondPayload `
        -ManifestPath $secondManifest
    $firstManifestBytes = [IO.File]::ReadAllBytes($firstManifest)
    $secondManifestBytes = [IO.File]::ReadAllBytes($secondManifest)
    if (-not [Linq.Enumerable]::SequenceEqual[byte](
            $firstManifestBytes,
            $secondManifestBytes
        )) {
        throw 'Site payload builder is not byte-for-byte deterministic.'
    }
    $manifestPaths = @(
        [IO.File]::ReadAllLines($firstManifest) |
            ForEach-Object {
                $match = [regex]::Match(
                    $_,
                    '^[0-9a-f]{64}  (?<path>_headers|[A-Za-z0-9][A-Za-z0-9._/-]*)$'
                )
                if (-not $match.Success) {
                    throw 'Site payload manifest line does not use the strict SHA-256 format.'
                }
                $match.Groups['path'].Value
            }
    )
    $sortedManifestPaths = [string[]]$manifestPaths.Clone()
    [Array]::Sort($sortedManifestPaths, [StringComparer]::Ordinal)
    if (-not [Linq.Enumerable]::SequenceEqual[string](
            [string[]]$manifestPaths,
            $sortedManifestPaths
        ) -or
        $manifestPaths -notcontains '_headers' -or
        $manifestPaths -contains '_redirects' -or
        $manifestPaths -contains 'README.md' -or
        @($manifestPaths | Where-Object { $_ -like 'tests/*' }).Count -ne 0) {
        throw 'Site deploy manifest escaped the clean sorted static allowlist.'
    }
    foreach ($requiredPayloadPath in @(
        'index.html',
        '404.html',
        'styles.css',
        'app.js',
        'version.js',
        'install.js',
        'terminal.js'
    )) {
        if ($manifestPaths -cnotcontains $requiredPayloadPath) {
            throw "Site deploy manifest is missing $requiredPayloadPath."
        }
    }
    $payloadAssetPaths = @($manifestPaths | Where-Object { $_ -like 'assets/*' })
    if ($payloadAssetPaths.Count -ne 2 -or
        $payloadAssetPaths -cnotcontains 'assets/favicon.svg' -or
        $payloadAssetPaths -cnotcontains 'assets/noctty-social.png') {
        throw 'Site deploy manifest assets escaped the favicon and social-preview allowlist.'
    }
}
finally {
    if (Test-Path -LiteralPath $sitePayloadFixtureRoot) {
        Remove-Item -LiteralPath $sitePayloadFixtureRoot -Recurse -Force
    }
}
