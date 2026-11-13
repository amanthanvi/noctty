# The manual Chocolatey Publish workflow pushes the one release secret nothing
# else uses (CHOCO_API_KEY) from a runner, so it is pinned the way the release
# workflow is. The whole file carries a digest (any edit is a review event, which
# also catches what a pattern cannot, such as a decoy in a comment), and a
# function states the properties that matter and must reject each mutant.
$chocolateyPublishWorkflowSha256 = '9be80e619aa588840a85fb24aab4020ca7f93a2077dcde0626ce14be5d4988f8'
$chocolateyPublishWorkflow = Join-Path $repoRoot '.github\workflows\chocolatey-publish.yml'
$chocolateyPublisherScript = Join-Path $repoRoot 'scripts\release-publish-chocolatey.ps1'
$chocolateyStagerScript = Join-Path $repoRoot 'scripts\release-stage-published.ps1'
$chocolateyPublishingDoc = Join-Path $repoRoot 'docs\chocolatey-publishing.md'

function Test-ChocolateyPublishWorkflow {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [switch] $SkipDigest
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $canonical = ConvertTo-CanonicalText -Text $Text
    if (-not $SkipDigest -and (Get-CanonicalTextSha256 -Text $Text) -cne $chocolateyPublishWorkflowSha256) {
        $problems.Add('the workflow differs from its pinned digest: review the change, then update the digest')
    }
    $pushStepName = 'Push to Chocolatey'
    $expectedSteps = @(
        'Checkout code',
        'Check the version and the workflow commit',
        'Show the Chocolatey version',
        'Verify the published release and build the package',
        'Pack the package (dry run)',
        $pushStepName
    )

    $onBlock = [regex]::Match($canonical, '(?ms)^on:\s*\n(?<body>(?:[ \t]+[^\n]*\n|\n)+)')
    $events = @(if ($onBlock.Success) {
        @([regex]::Matches($onBlock.Groups['body'].Value, '(?m)^  (\S[^:\n]*):') | ForEach-Object { $_.Groups[1].Value })
    }
    else { @() })
    if ($events.Count -ne 1 -or $events[0] -cne 'workflow_dispatch') {
        $problems.Add('the only trigger must be workflow_dispatch')
    }
    foreach ($inputSpec in @(
            @{ Name = 'version'; Required = @('required: true', 'type: string') },
            @{ Name = 'push'; Required = @('default: false', 'type: boolean') },
            @{ Name = 'resubmit'; Required = @('default: false', 'type: boolean') }
        )) {
        $inputBlock = [regex]::Match($canonical, '(?ms)^      ' + $inputSpec.Name + ':\s*\n(?<body>(?:        [^\n]*\n)+)')
        if (-not $inputBlock.Success) {
            $problems.Add("input $($inputSpec.Name) is missing")
            continue
        }
        foreach ($line in $inputSpec.Required) {
            if ($inputBlock.Groups['body'].Value -notmatch ('(?m)^        ' + [regex]::Escape($line) + '\s*$')) {
                $problems.Add("input $($inputSpec.Name) must declare $line")
            }
        }
    }
    if ($canonical -notmatch '(?m)^permissions: \{\}\s*$') {
        $problems.Add('the workflow must start from no token permissions')
    }
    if ($canonical -match '(?i)continue-on-error') {
        $problems.Add('no step may ignore its own failure')
    }

    $job = $null
    try {
        $job = Get-YamlJobText -Content $canonical -Name 'chocolatey-publish' -Source $chocolateyPublishWorkflow
    }
    catch {
        $problems.Add($_.Exception.Message)
    }
    if ($null -eq $job) { return $problems.ToArray() }
    $jobsSection = $canonical.Substring($canonical.IndexOf("`njobs:`n", [StringComparison]::Ordinal) + 1)
    if (@([regex]::Matches($jobsSection, '(?m)^  [A-Za-z0-9_-]+:\s*$')).Count -ne 1) {
        $problems.Add('the workflow must have exactly one job')
    }
    if ($job -notmatch '(?m)^    runs-on: windows-latest\s*$') {
        $problems.Add('the job must run on the GitHub-hosted windows-latest runner')
    }
    if ($job -notmatch '(?m)^    environment: release\s*$') {
        $problems.Add('the job must run in the release environment')
    }
    $jobPermissions = [regex]::Match($job, '(?ms)^    permissions:\s*\n(?<body>(?:      [^\n]*\n)+)')
    $permissionLines = @(if ($jobPermissions.Success) {
        @($jobPermissions.Groups['body'].Value -split '\n' | Where-Object { $_.Trim() })
    }
    else { @() })
    if ($permissionLines.Count -ne 2 -or
        $permissionLines[0].Trim() -cne 'contents: read' -or
        $permissionLines[1].Trim() -cne 'attestations: read') {
        $problems.Add('the job token may only read contents and attestations')
    }
    foreach ($use in [regex]::Matches($canonical, '(?m)^\s*(?:- )?uses:\s*(\S+)')) {
        if ($use.Groups[1].Value -notmatch '@[0-9a-f]{40}$') {
            $problems.Add("action is not pinned by commit SHA: $($use.Groups[1].Value)")
        }
    }

    $stepNames = @([regex]::Matches($job, '(?m)^      - name:[ \t]+(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
    if (($stepNames -join '|') -cne ($expectedSteps -join '|')) {
        $problems.Add("steps must be exactly, in order: $($expectedSteps -join ' / ')")
        return $problems.ToArray()
    }
    $steps = @{}
    foreach ($name in $expectedSteps) {
        $steps[$name] = Get-YamlStepBlock -Content $job -Name $name -Source $chocolateyPublishWorkflow
    }

    if ($steps['Checkout code'] -notmatch '(?m)^          persist-credentials: false\s*$') {
        $problems.Add('checkout must not persist credentials')
    }
    foreach ($name in $expectedSteps | Where-Object { $_ -cne 'Pack the package (dry run)' -and $_ -cne $pushStepName }) {
        if ($steps[$name] -match '(?m)^        if:') {
            $problems.Add("step runs conditionally: $name")
        }
    }
    $metaStep = $steps['Check the version and the workflow commit']
    foreach ($required in @(
            "if (`$env:GH_REPOSITORY -cne 'amanthanvi/noctty')",
            'if ($env:WORKFLOW_REF -cne "refs/heads/$env:DEFAULT_BRANCH")',
            "if (`$env:VERSION_INPUT -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z')",
            'if ($head -ne $env:WORKFLOW_SHA -or $head -ne $defaultHead)',
            'VERSION_INPUT: ${{ inputs.version }}'
        )) {
        if (-not $metaStep.Contains($required, [StringComparison]::Ordinal)) {
            $problems.Add("the check step lost: $required")
        }
    }
    $stageStep = $steps['Verify the published release and build the package']
    foreach ($required in @(
            './scripts/release-stage-published.ps1',
            '-Version $env:RELEASE_VERSION',
            '-PackageSourceRef $env:PACKAGE_SOURCE_REF',
            'PACKAGE_SOURCE_REF: ${{ github.sha }}',
            'GH_TOKEN: ${{ github.token }}',
            'WINDOWS_CODESIGN_TRUST_SELF_SIGNED: ${{ vars.WINDOWS_CODESIGN_TRUST_SELF_SIGNED }}'
        )) {
        if (-not $stageStep.Contains($required, [StringComparison]::Ordinal)) {
            $problems.Add("the verify and build step lost: $required")
        }
    }
    $packStep = $steps['Pack the package (dry run)']
    if ($packStep -notmatch '(?m)^        if: \$\{\{ !inputs\.push \}\}\s*$' -or
        -not $packStep.Contains('./scripts/release-publish-chocolatey.ps1 -Version $env:RELEASE_VERSION -PackOnly', [StringComparison]::Ordinal)) {
        $problems.Add('the dry run must run exactly when push is off, and must pass -PackOnly')
    }
    $pushStep = $steps[$pushStepName]
    if ($pushStep -notmatch '(?m)^        if: \$\{\{ inputs\.push \}\}\s*$' -or
        -not $pushStep.Contains('CHOCO_API_KEY: ${{ secrets.CHOCO_API_KEY }}', [StringComparison]::Ordinal) -or
        -not $pushStep.Contains('RESUBMIT: ${{ inputs.resubmit }}', [StringComparison]::Ordinal) -or
        -not $pushStep.Contains('$publishArguments = @{ Version = $env:RELEASE_VERSION; Resubmit = ($env:RESUBMIT -ceq ''true'') }', [StringComparison]::Ordinal) -or
        -not $pushStep.Contains('./scripts/release-publish-chocolatey.ps1 @publishArguments', [StringComparison]::Ordinal) -or
        $pushStep -match '-PackOnly' -or
        $pushStep -notmatch "IsNullOrWhiteSpace\(\`$env:CHOCO_API_KEY\)[^\n]*\{\s*\n\s*throw ") {
        $problems.Add('the push step must run only when push is on, fail without the key, pass resubmit only from its input, and not pass -PackOnly')
    }

    $withoutPushStep = $canonical.Replace($pushStep, '')
    if ($withoutPushStep -match 'CHOCO_API_KEY' -or $withoutPushStep -match 'secrets\.') {
        $problems.Add('no secret may be readable outside the push step')
    }
    if (@([regex]::Matches($canonical, 'secrets\.')).Count -ne 1) {
        $problems.Add('the push step must read exactly one secret')
    }
    foreach ($line in ($canonical -split '\n')) {
        if ($line -match '\$\{\{\s*inputs\.' -and $line -notmatch '^\s+(?:VERSION_INPUT: |RESUBMIT: |if: )') {
            $problems.Add("a workflow input is used outside an env value or condition: $($line.Trim())")
        }
    }
    return $problems.ToArray()
}

$chocolateyPublishWorkflowText = Get-Content -LiteralPath $chocolateyPublishWorkflow -Raw
$chocolateyPublishProblems = @(Test-ChocolateyPublishWorkflow -Text $chocolateyPublishWorkflowText)
if ($chocolateyPublishProblems.Count -ne 0) {
    throw "Chocolatey Publish workflow contract failed: $($chocolateyPublishProblems -join '; ')"
}
$chocolateyPublishCanonical = ConvertTo-CanonicalText -Text $chocolateyPublishWorkflowText
# Each mutant must break a stated property, checked without the digest so that
# the digest cannot be what rejects it.
$chocolateyPublishMutants = @(
    @{ Label = 'extra push trigger'; Target = "on:`n  workflow_dispatch:"; Replacement = "on:`n  push:`n    branches: [main]`n  workflow_dispatch:" },
    # The pin as the workflow has it now, so a Dependabot bump of checkout
    # does not leave this mutant without a target.
    @{ Label = 'unpinned checkout'; Target = [regex]::Match($chocolateyPublishWorkflowText, 'actions/checkout@[0-9a-f]{40} # v[0-9.]+').Value; Replacement = 'actions/checkout@v7' },
    @{ Label = 'unconditional push'; Target = 'if: ${{ inputs.push }}'; Replacement = 'if: ${{ true }}' },
    @{ Label = 'dry run that pushes'; Target = '-Version $env:RELEASE_VERSION -PackOnly'; Replacement = '-Version $env:RELEASE_VERSION' },
    @{ Label = 'key readable while building'; Target = '          GH_TOKEN: ${{ github.token }}'; Replacement = "          GH_TOKEN: `${{ github.token }}`n          CHOCO_API_KEY: `${{ secrets.CHOCO_API_KEY }}" },
    @{ Label = 'input spliced into a script'; Target = '-Version $env:RELEASE_VERSION -PackOnly'; Replacement = '-Version ${{ inputs.version }} -PackOnly' },
    @{ Label = 'write token'; Target = '      contents: read'; Replacement = '      contents: write' },
    @{ Label = 'other environment'; Target = '    environment: release'; Replacement = '    environment: forged-release' },
    @{ Label = 'self-hosted runner'; Target = '    runs-on: windows-latest'; Replacement = '    runs-on: [self-hosted, forged]' },
    @{ Label = 'no default-branch check'; Target = 'if ($env:WORKFLOW_REF -cne "refs/heads/$env:DEFAULT_BRANCH")'; Replacement = 'if ($false)' },
    @{ Label = 'ignored failure'; Target = '        timeout-minutes: 10'; Replacement = "        timeout-minutes: 10`n        continue-on-error: true" },
    @{ Label = 'no token baseline'; Target = 'permissions: {}'; Replacement = 'permissions: write-all' },
    @{ Label = 'missing key guard'; Target = 'throw ''The release environment has no CHOCO_API_KEY secret.'''; Replacement = 'Write-Host ''no key''' },
    @{ Label = 'condition with a trailing decoy'; Target = 'if: ${{ inputs.push }}'; Replacement = 'if: ${{ true }} # if: ${{ inputs.push }}' },
    @{ Label = 'condition added to the build step'; Target = '        timeout-minutes: 15'; Replacement = "        timeout-minutes: 15`n        if: `${{ false }}" }
)
# What only the digest can see: a guard whose throw became a message, the
# verifier wrapped in a dead branch, a decoy of the old condition in a comment.
$chocolateyPublishDigestOnlyMutants = @(
    @{ Label = 'guard that no longer throws'; Target = "throw ""Run this workflow from `$env:DEFAULT_BRANCH, not `$env:WORKFLOW_REF."""; Replacement = 'Write-Host "not main"' },
    @{ Label = 'verifier in a dead branch'; Target = '          ./scripts/release-stage-published.ps1 `'; Replacement = '          if ($false) { ./scripts/release-stage-published.ps1 `' },
    @{ Label = 'comment decoy'; Target = '      - name: Show the Chocolatey version'; Replacement = "      # if: `${{ inputs.push }}`n      - name: Show the Chocolatey version" }
)
foreach ($mutant in $chocolateyPublishMutants + $chocolateyPublishDigestOnlyMutants) {
    if (@([regex]::Matches($chocolateyPublishCanonical, [regex]::Escape($mutant.Target))).Count -ne 1) {
        throw "Chocolatey Publish mutation target is not unique: $($mutant.Label)"
    }
    $mutantText = $chocolateyPublishCanonical.Replace($mutant.Target, $mutant.Replacement)
    $skipDigest = $mutant -notin $chocolateyPublishDigestOnlyMutants
    if (@(Test-ChocolateyPublishWorkflow -Text $mutantText -SkipDigest:$skipDigest).Count -eq 0) {
        throw "Chocolatey Publish workflow contract accepted mutant: $($mutant.Label)"
    }
}

$chocolateyPublisherText = Get-Content -LiteralPath $chocolateyPublisherScript -Raw
$chocolateyStagerText = Get-Content -LiteralPath $chocolateyStagerScript -Raw
$chocolateyPublishingDocText = Get-Content -LiteralPath $chocolateyPublishingDoc -Raw
Invoke-ContractTable -Contracts @(
    @{
        File = $chocolateyPublisherScript
        Content = { $chocolateyPublisherText }
        Pattern = '(?ms)\[switch\] \$PackOnly.*?if \(-not \$PackOnly -and -not \$env:CHOCO_API_KEY\) \{.*?& choco pack.*?if \(\$PackOnly\) \{[^}]*return\s*\}.*?& choco push'
        Kind = 'Text'
        Description = '-PackOnly needs no API key, packs, and returns before choco push'
    }
    @{
        File = $chocolateyPublisherScript
        Content = { $chocolateyPublisherText }
        Pattern = '(?ms)\$apiKey = \$env:CHOCO_API_KEY\s+Remove-Item -LiteralPath Env:CHOCO_API_KEY.*?& choco pack.*?finally \{\s*if \(\$apiKey\) \{ \$env:CHOCO_API_KEY = \$apiKey \}\s*\}'
        Kind = 'Text'
        Description = 'choco pack runs without the API key in its environment'
    }
    @{
        File = $chocolateyStagerScript
        Content = { $chocolateyStagerText }
        Pattern = '(?ms)verify-published-release\.ps1.*?gh attestation verify \$setupPath.*?--source-digest \$tagCommit.*?throw "The \$architecture installer was not built from the commit'
        Kind = 'Text'
        Description = 'the installers are verified against the release tag''s commit before they are staged'
    }
    @{
        File = $chocolateyStagerScript
        Content = { $chocolateyStagerText }
        Pattern = '(?ms)\[ValidatePattern\(''\\A\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\\z''\)\].*?verify-published-release\.ps1.*?-DownloadDirectory \$DownloadDirectory.*?Copy-Item.*?package-package-managers\.ps1'
        Kind = 'Text'
        Description = 'the published release is verified before its installers are copied into a package'
    }
    @{
        File = $chocolateyPublishingDoc
        Content = { $chocolateyPublishingDocText }
        Pattern = '(?ms)Chocolatey Publish.*?chocolatey-publish\.yml.*?-f push=true'
        Kind = 'Text'
        Description = 'the maintainer path is to run the Chocolatey Publish workflow'
    }
)
