$releasePreflightInvocationStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Release preflight' `
    -Source $releaseWorkflow
$readinessPreflightInvocationStep = Get-YamlStepBlock `
    -Content $readinessWorkflowText `
    -Name 'Validate release configuration' `
    -Source $readinessWorkflow
$releaseCheckoutStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Checkout code' `
    -Source $releaseWorkflow
$releaseX64PackageStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Build and package x64 release artifacts' `
    -Source $releaseWorkflow
$releaseArm64PackageStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Build and package ARM64 release artifacts' `
    -Source $releaseWorkflow
$releaseSubmitWingetStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Submit WinGet manifest update' `
    -Source $releaseWorkflow
$releasePublishScoopStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Publish Scoop manifest' `
    -Source $releaseWorkflow
$releasePreflightAction = Join-Path $repoRoot '.github\actions\release-preflight\action.yml'
$releasePreflightActionText = Get-Content -LiteralPath $releasePreflightAction -Raw
$normalizedReleasePreflightActionText = @(
    $releasePreflightActionText.TrimEnd() -split '\r?\n' |
        ForEach-Object { "  $_" }
) -join "`n"
$releasePreflightStep = Get-YamlStepBlock `
    -Content $normalizedReleasePreflightActionText `
    -Name 'Validate release configuration' `
    -Source $releasePreflightAction
$releaseInteractiveEvidenceStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Require successful Test workflow for release SHA' `
    -Source $releaseWorkflow
$releasePreflightExpected = @{
    Version = '$env:RELEASE_VERSION'
    RequireSigning = '$true'
    RequirePackageManagers =
        '$env:REQUIRE_PACKAGE_MANAGERS -eq ''true'''
}
$releasePreflightScriptSha256 =
    '9b21a7d84e1530309e54d0d33a4ead83e668b68138bead6472a8c4c0302888c0'
$releasePreflightActionStepSha256 =
    '5b73f14d716a39ebb15737ae9e3ec7e00645ffa1822355e1b50d3f5cd1c6a8ea'
$releasePreflightActionSha256 =
    'df0d1ff83a0279bdea87435a84a07c5971d66e1cb4240a28081a97af8ae30c3b'
$releaseInteractiveEvidenceScriptSha256 =
    '2bc265c1052c000e5f8ea599d2f5e2002dec3d3dc893bff0b8ecd72da739bb92'
$releaseInteractiveEvidenceStepSha256 =
    '88a9d8d525eca9bb31327fdad515af39488a63b418222036b82edf94db945b6f'
$releasePreflightStepSha256 =
    'd3af932ec3bf2369351ac7c9d70eac3f94ee4de13110f8277e0aa8e85e992fec'
$readinessPreflightStepSha256 =
    '153aa1d2b13ac09f38ba3269bc78840e57a93c98e54b99168a5d937b8dab7989'
$releaseWorkflowSha256 =
    '908ff971221435538b6e4148507bdc6241b6b4f481d488f1f662337bf62da74a'
$readinessWorkflowSha256 =
    '7c66f756a0219af4e791bccef9824c7373050e41aa753836f6f95577a5a1edc5'
# Full-file pins deliberately make every workflow edit a semantic-review event,
# including triggers, permissions, inherited job metadata, and unprotected steps.
foreach ($workflow in @(
    [pscustomobject] @{
        Context = $releaseWorkflow
        Content = $releaseWorkflowText
    }
    [pscustomobject] @{
        Context = $readinessWorkflow
        Content = $readinessWorkflowText
    }
)) {
    $jobEnvironment = [regex]::Match(
        $workflow.Content,
        '(?ms)^    env:\s*\r?\n(?<body>.*?)^    steps:\s*$'
    )
    if (-not $jobEnvironment.Success -or
        $jobEnvironment.Groups['body'].Value -match
            '(?m)^      (?:SCOOP_BUCKET_TOKEN|WINGETCREATE_TOKEN|WINGET_CREATE_GITHUB_TOKEN|WINDOWS_CODESIGN_PFX_BASE64|WINDOWS_CODESIGN_PFX_PASSWORD):') {
        throw "Sensitive release credentials escaped into job-level env: $($workflow.Context)"
    }
}
$releaseCheckoutCredentialSetting =
    '          persist-credentials: false'
$releaseCheckoutWithBlock = [regex]::Match(
    (ConvertTo-CanonicalText -Text $releaseCheckoutStep),
    '(?ms)^        with:\s*\n(?<body>(?:^          .*?(?:\n|$))+)'
)
if (-not $releaseCheckoutWithBlock.Success -or
    @([regex]::Matches(
        $releaseCheckoutWithBlock.Groups['body'].Value,
        '(?m)^' + [regex]::Escape($releaseCheckoutCredentialSetting) + '$'
    )).Count -ne 1) {
    throw "Release checkout must disable persisted GitHub credentials: $releaseWorkflow"
}
$signingSecretMappings = [ordered] @{
    WINDOWS_CODESIGN_PFX_BASE64 =
        '          WINDOWS_CODESIGN_PFX_BASE64: ${{ secrets.WINDOWS_CODESIGN_PFX_BASE64 }}'
    WINDOWS_CODESIGN_PFX_PASSWORD =
        '          WINDOWS_CODESIGN_PFX_PASSWORD: ${{ secrets.WINDOWS_CODESIGN_PFX_PASSWORD }}'
}
$signingSecretConsumerSpecs = @(
    [pscustomobject] @{
        Context = "$releaseWorkflow :: Release preflight"
        StepText = $releasePreflightInvocationStep
    }
    [pscustomobject] @{
        Context = "$readinessWorkflow :: Validate release configuration"
        StepText = $readinessPreflightInvocationStep
    }
    [pscustomobject] @{
        Context = "$releaseWorkflow :: Build and package x64 release artifacts"
        StepText = $releaseX64PackageStep
    }
    [pscustomobject] @{
        Context = "$releaseWorkflow :: Build and package ARM64 release artifacts"
        StepText = $releaseArm64PackageStep
    }
)
foreach ($consumer in $signingSecretConsumerSpecs) {
    $canonicalStep = ConvertTo-CanonicalText -Text $consumer.StepText
    $stepEnvironment = [regex]::Match(
        $canonicalStep,
        '(?ms)^        env:\s*\n(?<body>(?:^          .*?(?:\n|$))+)'
    )
    if (-not $stepEnvironment.Success) {
        throw "Signing secret env block is missing: $($consumer.Context)"
    }
    foreach ($mapping in $signingSecretMappings.Values) {
        if (@([regex]::Matches(
            $stepEnvironment.Groups['body'].Value,
            '(?m)^' + [regex]::Escape($mapping) + '$'
        )).Count -ne 1) {
            throw "Signing secret mapping is missing or redirected: $($consumer.Context)"
        }
    }
}
foreach ($workflow in @(
    [pscustomobject] @{
        Context = $releaseWorkflow
        Content = $releaseWorkflowText
        ExpectedConsumers = 3
    }
    [pscustomobject] @{
        Context = $readinessWorkflow
        Content = $readinessWorkflowText
        ExpectedConsumers = 1
    }
)) {
    foreach ($secretName in $signingSecretMappings.Keys) {
        $mapping = $signingSecretMappings[$secretName]
        $mappingPattern =
            '(?m)^' + [regex]::Escape($mapping) + '\r?$'
        if (@([regex]::Matches(
            $workflow.Content,
            $mappingPattern
        )).Count -ne $workflow.ExpectedConsumers) {
            throw "Signing secret consumer count changed: $($workflow.Context) :: $secretName"
        }
        $contentWithoutExpectedMappings = [regex]::Replace(
            $workflow.Content,
            $mappingPattern,
            ''
        )
        if ($contentWithoutExpectedMappings -match
            [regex]::Escape($secretName)) {
            throw "Signing secret escaped an approved consumer: $($workflow.Context) :: $secretName"
        }
    }
}
$commonWorkflowBoundaryMutations = @(
    @{
        Label = 'WinGet package redirect'
        Target = '      WINGET_PACKAGE_IDENTIFIER: ${{ vars.WINGET_PACKAGE_IDENTIFIER }}'
        Replacement = '      WINGET_PACKAGE_IDENTIFIER: attacker.forged.package'
    },
    @{
        Label = 'Scoop repository redirect'
        Target = '      SCOOP_BUCKET_REPO: ${{ vars.SCOOP_BUCKET_REPO }}'
        Replacement = '      SCOOP_BUCKET_REPO: attacker/forged-bucket'
    },
    @{
        Label = 'Scoop branch redirect'
        Target = '      SCOOP_BUCKET_BRANCH: ${{ vars.SCOOP_BUCKET_BRANCH }}'
        Replacement = '      SCOOP_BUCKET_BRANCH: forged-release'
    },
    @{
        Label = 'runner redirect'
        Target = '    runs-on: windows-latest'
        Replacement = '    runs-on: [self-hosted, forged-release]'
    },
    @{
        Label = 'environment redirect'
        Target = '    environment: release'
        Replacement = '    environment: forged-release'
    }
)
$protectedWorkflowSpecs = @(
    [pscustomobject]@{
        Context = $releaseWorkflow
        Content = $releaseWorkflowText
        ExpectedSha256 = $releaseWorkflowSha256
        ProtectedSteps = @(
            @{
                Name = 'Require successful Test workflow for release SHA'
                StepSha256 = $releaseInteractiveEvidenceStepSha256
                BodySha256 = $releaseInteractiveEvidenceScriptSha256
            },
            @{
                Name = 'Release preflight'
                StepSha256 = $releasePreflightStepSha256
                BodySha256 = $null
            }
        )
        Mutations = @($commonWorkflowBoundaryMutations) + @(
            @{
                Label = 'release permission reduction'
                Target = '  contents: write'
                Replacement = '  contents: read'
            }
        )
    },
    [pscustomobject]@{
        Context = $readinessWorkflow
        Content = $readinessWorkflowText
        ExpectedSha256 = $readinessWorkflowSha256
        ProtectedSteps = @(
            @{
                Name = 'Validate release configuration'
                StepSha256 = $readinessPreflightStepSha256
                BodySha256 = $null
            }
        )
        Mutations = @($commonWorkflowBoundaryMutations) + @(
            @{
                Label = 'readiness permission escalation'
                Target = '  contents: read'
                Replacement = '  contents: write'
            }
        )
    }
)
foreach ($spec in $protectedWorkflowSpecs) {
    if ((Get-CanonicalTextSha256 -Text $spec.Content) -cne
        $spec.ExpectedSha256) {
        throw "Protected workflow changed: $($spec.Context)"
    }
    $canonicalWorkflow = ConvertTo-CanonicalText -Text $spec.Content
    foreach ($mutation in $spec.Mutations) {
        if (@([regex]::Matches(
            $canonicalWorkflow,
            [regex]::Escape($mutation.Target)
        )).Count -ne 1) {
            throw "Protected workflow mutation target is not unique: $($spec.Context) :: $($mutation.Label)"
        }
        $mutantWorkflow = $canonicalWorkflow.Replace(
            $mutation.Target,
            $mutation.Replacement
        )
        if ((Get-CanonicalTextSha256 -Text $mutantWorkflow) -ceq
            $spec.ExpectedSha256) {
            throw "Protected workflow accepted full-file mutation: $($spec.Context) :: $($mutation.Label)"
        }
        foreach ($protectedStep in $spec.ProtectedSteps) {
            $mutantStep = Get-YamlStepBlock `
                -Content $mutantWorkflow `
                -Name $protectedStep.Name `
                -Source "$($spec.Context) :: $($mutation.Label)"
            $mutantBody = if ($null -ne $protectedStep.BodySha256) {
                Get-YamlLiteralRunScript `
                    -Content $mutantStep `
                    -Source "$($spec.Context) :: $($mutation.Label) :: $($protectedStep.Name)"
            }
            if ((Get-CanonicalTextSha256 -Text $mutantStep) -cne
                    $protectedStep.StepSha256 -or
                ($null -ne $protectedStep.BodySha256 -and
                    (Get-CanonicalTextSha256 -Text $mutantBody) -cne
                        $protectedStep.BodySha256)) {
                throw "Full-file mutation unexpectedly changed a protected step: $($spec.Context) :: $($mutation.Label)"
            }
        }
    }
}
if ((Get-CanonicalTextSha256 -Text $releasePreflightActionText) -cne
    $releasePreflightActionSha256 -or
    (Get-CanonicalTextSha256 -Text $releasePreflightStep) -cne
    $releasePreflightActionStepSha256) {
    throw "Protected release preflight action changed: $releasePreflightAction"
}
$protectedStepEnvelopeSpecs = @(
    [pscustomobject]@{
        Name = 'Require successful Test workflow for release SHA'
        Context = "$releaseWorkflow :: Require successful Test workflow for release SHA"
        StepText = $releaseInteractiveEvidenceStep
        ExpectedSha256 = $releaseInteractiveEvidenceStepSha256
        Mutations = @(
            @{
                Label = 'GH_REPOSITORY redirect'
                Target = '          GH_REPOSITORY: ${{ github.repository }}'
                Replacement = '          GH_REPOSITORY: attacker/forged-evidence'
            },
            @{
                Label = 'GH_TOKEN redirect'
                Target = '          GH_TOKEN: ${{ github.token }}'
                Replacement = '          GH_TOKEN: ${{ secrets.FORGED_GH_TOKEN }}'
            }
        )
    },
    [pscustomobject]@{
        Name = 'Release preflight'
        Context = "$releaseWorkflow :: Release preflight"
        StepText = $releasePreflightInvocationStep
        ExpectedSha256 = $releasePreflightStepSha256
        Mutations = @(
            @{
                Label = 'release prerelease override'
                Target = '          prerelease: ${{ steps.meta.outputs.prerelease }}'
                Replacement = '          prerelease: true'
            },
            @{
                Label = 'release version override'
                Target = '          version: ${{ steps.meta.outputs.version }}'
                Replacement = '          version: 0.0.0'
            },
            @{
                Label = 'release GitHub token redirect'
                Target = '          github-token: ${{ github.token }}'
                Replacement = '          github-token: ${{ secrets.FORGED_GH_TOKEN }}'
            },
            @{
                Label = 'release Scoop token redirect'
                Target = '          scoop-bucket-token: ${{ secrets.SCOOP_BUCKET_TOKEN }}'
                Replacement = '          scoop-bucket-token: ${{ secrets.FORGED_SCOOP_TOKEN }}'
            },
            @{
                Label = 'release WinGet token redirect'
                Target = '          wingetcreate-token: ${{ secrets.WINGETCREATE_TOKEN }}'
                Replacement = '          wingetcreate-token: ${{ secrets.FORGED_WINGET_TOKEN }}'
            },
            @{
                Label = 'release PFX payload redirect'
                Target = '          WINDOWS_CODESIGN_PFX_BASE64: ${{ secrets.WINDOWS_CODESIGN_PFX_BASE64 }}'
                Replacement = '          WINDOWS_CODESIGN_PFX_BASE64: ${{ secrets.FORGED_PFX_BASE64 }}'
            },
            @{
                Label = 'release PFX password redirect'
                Target = '          WINDOWS_CODESIGN_PFX_PASSWORD: ${{ secrets.WINDOWS_CODESIGN_PFX_PASSWORD }}'
                Replacement = '          WINDOWS_CODESIGN_PFX_PASSWORD: ${{ secrets.FORGED_PFX_PASSWORD }}'
            }
        )
    },
    [pscustomobject]@{
        Name = 'Validate release configuration'
        Context = "$readinessWorkflow :: Validate release configuration"
        StepText = $readinessPreflightInvocationStep
        ExpectedSha256 = $readinessPreflightStepSha256
        Mutations = @(
            @{
                Label = 'readiness version override'
                Target = '          version: ${{ inputs.version }}'
                Replacement = '          version: 0.0.0'
            },
            @{
                Label = 'readiness package-manager override'
                Target = '          require-package-managers: ${{ inputs.require_package_managers }}'
                Replacement = '          require-package-managers: false'
            },
            @{
                Label = 'readiness GitHub token redirect'
                Target = '          github-token: ${{ github.token }}'
                Replacement = '          github-token: ${{ secrets.FORGED_GH_TOKEN }}'
            },
            @{
                Label = 'readiness Scoop token redirect'
                Target = '          scoop-bucket-token: ${{ secrets.SCOOP_BUCKET_TOKEN }}'
                Replacement = '          scoop-bucket-token: ${{ secrets.FORGED_SCOOP_TOKEN }}'
            },
            @{
                Label = 'readiness WinGet token redirect'
                Target = '          wingetcreate-token: ${{ secrets.WINGETCREATE_TOKEN }}'
                Replacement = '          wingetcreate-token: ${{ secrets.FORGED_WINGET_TOKEN }}'
            },
            @{
                Label = 'readiness PFX payload redirect'
                Target = '          WINDOWS_CODESIGN_PFX_BASE64: ${{ secrets.WINDOWS_CODESIGN_PFX_BASE64 }}'
                Replacement = '          WINDOWS_CODESIGN_PFX_BASE64: ${{ secrets.FORGED_PFX_BASE64 }}'
            },
            @{
                Label = 'readiness PFX password redirect'
                Target = '          WINDOWS_CODESIGN_PFX_PASSWORD: ${{ secrets.WINDOWS_CODESIGN_PFX_PASSWORD }}'
                Replacement = '          WINDOWS_CODESIGN_PFX_PASSWORD: ${{ secrets.FORGED_PFX_PASSWORD }}'
            }
        )
    }
)
foreach ($spec in $protectedStepEnvelopeSpecs) {
    if (-not (Test-YamlStepEnvelopeDigest `
        -StepText $spec.StepText `
        -ExpectedSha256 $spec.ExpectedSha256)) {
        throw "Protected workflow step envelope changed: $($spec.Context)"
    }
    $canonicalStep = ConvertTo-CanonicalText -Text $spec.StepText
    $nameLine = "      - name: $($spec.Name)"
    $mutations = @(
        @{
            Label = 'continue-on-error'
            Target = $nameLine
            Replacement = "$nameLine`n        continue-on-error: true"
        },
        @{
            Label = 'if false'
            Target = $nameLine
            Replacement = "$nameLine`n        if: `${{ false }}"
        }
    ) + @($spec.Mutations)
    foreach ($mutation in $mutations) {
        if (@([regex]::Matches(
            $canonicalStep,
            [regex]::Escape($mutation.Target)
        )).Count -ne 1) {
            throw "Protected step envelope mutation target is not unique: $($spec.Context) :: $($mutation.Label)"
        }
        $mutantStep = $canonicalStep.Replace(
            $mutation.Target,
            $mutation.Replacement
        )
        if (Test-YamlStepEnvelopeDigest `
                -StepText $mutantStep `
                -ExpectedSha256 $spec.ExpectedSha256) {
            throw "Protected workflow step envelope accepted metadata mutation: $($spec.Context) :: $($mutation.Label)"
        }
    }
}
Assert-NamedReleasePreflightSplat `
    -StepText $releasePreflightStep `
    -ExpectedExpressions $releasePreflightExpected `
    -ExpectedScriptSha256 $releasePreflightScriptSha256 `
    -Context "$releasePreflightAction :: Validate release configuration"

$releasePreflightScript = Get-YamlLiteralRunScript `
    -Content $releasePreflightStep `
    -Source "$releasePreflightAction :: Validate release configuration"
# Intentional protected-step edits require semantic review plus body/envelope
# digest updates; formatting changes are contract changes too.
$releasePreflightWhitespaceMutant = $releasePreflightScript.Replace(
    '$preflightArgs = @{',
    '$preflightArgs  = @{'
)
if ($releasePreflightWhitespaceMutant -ceq $releasePreflightScript -or
    (Test-NamedReleasePreflightSplat `
        -ScriptText $releasePreflightWhitespaceMutant `
        -ExpectedExpressions $releasePreflightExpected `
        -ExpectedScriptSha256 $releasePreflightScriptSha256)) {
    throw 'Release-preflight script digest accepted a whitespace mutation.'
}
$releasePreflightInvocationTarget =
    './scripts/release-preflight.ps1 @preflightArgs'
if (-not $releasePreflightScript.Contains($releasePreflightInvocationTarget)) {
    throw 'Release-preflight mutation insertion target is missing.'
}
$invalidSplatMutants = @{
    'later signing mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$preflightArgs.RequireSigning = $false
./scripts/release-preflight.ps1 @preflightArgs
'@
    'flat argument array' = @'
$preflightArgs = @('-Version', $env:RELEASE_VERSION, '-RequireSigning', '-RequirePackageManagers')
./scripts/release-preflight.ps1 @preflightArgs
'@
    'extra invocation argument' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
./scripts/release-preflight.ps1 @preflightArgs -RequireSigning
'@
    'missing key' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
}
./scripts/release-preflight.ps1 @preflightArgs
'@
    'extra key' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
    RequireAccessibilityEvidence = $true
}
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Set-Variable mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
Set-Variable -Name preflightArgs -Value @{}
./scripts/release-preflight.ps1 @preflightArgs
'@
    'stored provider path Set-Item mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$providerPath = 'variable:preflightArgs'
Set-Item -Path $providerPath -Value @{}
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Set-Item alias mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
si -Path variable:preflightArgs -Value @{}
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Copy-Item alias mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
cpi -Path variable:preflightArgs -Destination variable:shadow
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Move-Item alias mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
mv -Path variable:preflightArgs -Destination variable:shadow
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Rename-Item alias mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
rni -Path variable:preflightArgs -NewName shadow
./scripts/release-preflight.ps1 @preflightArgs
'@
    'New-Item alias mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
ni -Path variable:preflightArgs -Value @{} -Force
./scripts/release-preflight.ps1 @preflightArgs
'@
    'module-qualified New-Item stored provider path' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$providerPath = 'variable:preflightArgs'
Microsoft.PowerShell.Management\New-Item -Path $providerPath -Value @{} -Force
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Get-ChildItem alias stored provider mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$providerPath = 'variable:preflightArgs'
$providerItem = gci -Path $providerPath
$providerItem.Value = @{}
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Get-Content stored provider mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$providerPath = 'variable:preflightArgs'
$providerItem = Get-Content -Path $providerPath
$providerItem.Value = @{}
./scripts/release-preflight.ps1 @preflightArgs
'@
    'wrapped ExecutionContext mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$ec = @($ExecutionContext)[0]
$ec.SessionState.PSVariable.Set('preflightArgs', @{})
./scripts/release-preflight.ps1 @preflightArgs
'@
    'SessionState PSVariable mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$ExecutionContext.SessionState.PSVariable.Set('preflightArgs', @{})
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Invoke-Expression mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
iex '$preflightArgs = @{}'
./scripts/release-preflight.ps1 @preflightArgs
'@
    'dynamic call mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$mutator = 'Set-Variable'
& $mutator -Name preflightArgs -Value @{}
./scripts/release-preflight.ps1 @preflightArgs
'@
    'static dot-source mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
. ./scripts/replace-release-evidence.ps1
./scripts/release-preflight.ps1 @preflightArgs
'@
    'static call-operator mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
& Write-Output harmless
./scripts/release-preflight.ps1 @preflightArgs
'@
    'stored reflection mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
$scriptBlockType = {}.GetType()
$createMethod = $scriptBlockType.GetMethod('Create', [type[]]@([string]))
$payload = $createMethod.Invoke($null, @('Set-Variable -Scope 1 -Name preflightArgs -Value @{}'))
$payload.Invoke()
./scripts/release-preflight.ps1 @preflightArgs
'@
    'DefaultRunspace state proxy mutation' = @'
$preflightArgs = @{
    Version = $env:RELEASE_VERSION
    RequireSigning = $true
    RequirePackageManagers = $true
}
[runspace]::DefaultRunspace.SessionStateProxy.SetVariable('preflightArgs', @{})
./scripts/release-preflight.ps1 @preflightArgs
'@
    'Tee-Object variable mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "Write-Output @{} | Tee-Object -Variable preflightArgs | Out-Null`n$releasePreflightInvocationTarget"
    )
    'OutVariable mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "Write-Output @{} -OutVariable preflightArgs | Out-Null`n$releasePreflightInvocationTarget"
    )
    'OutVariable prefix mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "Write-Output @{} -OutV preflightArgs | Out-Null`n$releasePreflightInvocationTarget"
    )
    'PipelineVariable mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "Write-Output @{} -PipelineVariable preflightArgs | Out-Null`n$releasePreflightInvocationTarget"
    )
    'PipelineVariable prefix mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "Write-Output @{} -PipelineV preflightArgs | Out-Null`n$releasePreflightInvocationTarget"
    )
    'ErrorVariable mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "Write-Error forged -ErrorVariable preflightArgs -ErrorAction SilentlyContinue`n$releasePreflightInvocationTarget"
    )
    'PSObject member dispatch mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "`$dispatch = [pscustomobject]@{ mutate = { Set-Variable -Scope 1 -Name preflightArgs -Value @{} } }`n`$dispatch.PSObject.Properties['mutate'].Value.Invoke()`n$releasePreflightInvocationTarget"
    )
    'Add-Type static method mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "Add-Type -TypeDefinition 'public static class PreflightMutator { public static void Set() {} }'`n[PreflightMutator]::Set()`n$releasePreflightInvocationTarget"
    )
    'Assembly Load mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "[Reflection.Assembly]::Load([Convert]::FromBase64String('AA=='))`n$releasePreflightInvocationTarget"
    )
    'ForEach-Object MemberName dispatch mutation' =
        $releasePreflightScript.Replace(
            $releasePreflightInvocationTarget,
            "[PSObject].Assembly | ForEach-Object -MemberName ('Get' + 'Type') -ArgumentList 'System.Management.Automation.ScriptBlock'`n$releasePreflightInvocationTarget"
        )
    'PSCmdlet session-state mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "function Invoke-PreflightMutation { [CmdletBinding()] param(); `$PSCmdlet.SessionState.PSVariable.Set('script:preflightArgs', @{}) }; Invoke-PreflightMutation`n$releasePreflightInvocationTarget"
    )
    'splatted PipelineVariable mutation' = $releasePreflightScript.Replace(
        $releasePreflightInvocationTarget,
        "`$writeParams = @{ PipelineVariable = 'preflightArgs' }; Write-Output @{} @writeParams`n$releasePreflightInvocationTarget"
    )
}
foreach ($mutant in $invalidSplatMutants.GetEnumerator()) {
    if (Test-NamedReleasePreflightSplat `
        -ScriptText $mutant.Value `
        -ExpectedExpressions $releasePreflightExpected `
        -ExpectedScriptSha256 $releasePreflightScriptSha256) {
        throw "Named release-preflight splat contract accepted mutant: $($mutant.Key)"
    }
}

$releaseInteractiveEvidenceScript = Get-YamlLiteralRunScript `
    -Content $releaseInteractiveEvidenceStep `
    -Source "$releaseWorkflow :: Require successful Test workflow for release SHA"
if (-not (Test-ReleaseInteractiveResultSelectionContract `
    -ScriptText $releaseInteractiveEvidenceScript)) {
    throw 'Release interactive evidence must select one composite result without arbitrary first-match fallback.'
}
$countGateText = 'if ($resultFiles.Count -ne 1) { continue }'
$countGateIndex = $releaseInteractiveEvidenceScript.IndexOf(
    $countGateText,
    [StringComparison]::Ordinal
)
if ($countGateIndex -lt 0) {
    throw 'Release result-selection count gate mutation target is missing.'
}
$countBeforeFilterScript = $releaseInteractiveEvidenceScript.Remove(
    $countGateIndex,
    $countGateText.Length
)
$resultFilterIndex = $countBeforeFilterScript.IndexOf(
    '$resultFiles = @(',
    [StringComparison]::Ordinal
)
if ($resultFilterIndex -lt 0) {
    throw 'Release result-selection filter mutation target is missing.'
}
$countBeforeFilterScript = $countBeforeFilterScript.Insert(
    $resultFilterIndex,
    "$countGateText`n"
)
$filterAfterCountScript = @'
$resultFiles = @(
    Get-ChildItem -LiteralPath $artifactRoot -Filter result.json -File -Recurse
)
if ($resultFiles.Count -ne 1) { continue }
$resultFiles = @(
    $resultFiles | Where-Object {
        try {
            (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).scenario_id -eq 'windows.interactive-win11.composite'
        }
        catch { $false }
    }
)
$resultPath = $resultFiles[0].FullName
$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
'@
$noCatchScript = [regex]::Replace(
    $releaseInteractiveEvidenceScript,
    '(?ms)try\s*\{\s*(?<predicate>\(Get-Content -LiteralPath \$_\.FullName -Raw \| ConvertFrom-Json\)\.scenario_id -eq ''windows\.interactive-win11\.composite'')\s*\}\s*catch\s*\{\s*\$false\s*\}',
    '${predicate}'
)
$invalidResultSelectionMutants = @{
    'zero-only count' = $releaseInteractiveEvidenceScript.Replace(
        '$resultFiles.Count -ne 1',
        '$resultFiles.Count -eq 0'
    )
    'wrong scenario' = $releaseInteractiveEvidenceScript.Replace(
        'windows.interactive-win11.composite',
        'windows.interactive-win11.other'
    )
    # A disconnected Select-Object statement has no effect on result selection;
    # the executed fixture below rejects actual non-unique selection behavior.
    'count before filter' = $countBeforeFilterScript
    'filter after count' = $filterAfterCountScript
    'missing catch' = $noCatchScript
    'fail-open catch' = $releaseInteractiveEvidenceScript.Replace(
        'catch { $false }',
        'catch { $true }'
    )
    'nested count gate' = $releaseInteractiveEvidenceScript.Replace(
        'if ($resultFiles.Count -ne 1) { continue }',
        'if ($false) { if ($resultFiles.Count -ne 1) { continue } }'
    )
    'nested result path' = $releaseInteractiveEvidenceScript.Replace(
        '$resultPath = $resultFiles[0].FullName',
        'if ($false) { $resultPath = $resultFiles[0].FullName }'
    )
    'nested result parse' = $releaseInteractiveEvidenceScript.Replace(
        '$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json',
        'if ($false) { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json }'
    )
}
foreach ($mutant in $invalidResultSelectionMutants.GetEnumerator()) {
    if (Test-ReleaseInteractiveResultSelectionContract -ScriptText $mutant.Value) {
        throw "Release result-selection contract accepted mutant: $($mutant.Key)"
    }
}
if (-not (Test-ReleaseInteractiveSuccessPredicates `
    -ScriptText $releaseInteractiveEvidenceScript `
    -ExpectedScriptSha256 $releaseInteractiveEvidenceScriptSha256)) {
    throw 'Release interactive evidence must require successful exact-head candidates and a passing result.'
}
$runsSourceTarget = '$runs = @($runsJson | ConvertFrom-Json)'
$otherJsonSourceScript = $releaseInteractiveEvidenceScript.Replace(
    $runsSourceTarget,
    '$runs = @($otherJson | ConvertFrom-Json)'
)
$matchingSourceTarget = '$matching = @($runs | Where-Object {'
$otherRunsSourceScript = $releaseInteractiveEvidenceScript.Replace(
    $matchingSourceTarget,
    '$matching = @($otherRuns | Where-Object {'
)
$matchingCountTarget = 'if ($matching.Count -eq 0) {'
$shaAssignmentTarget = '$sha = (git rev-parse HEAD).Trim()'
$resultAssignmentTarget =
    '$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json'
$artifactFloorTarget =
    'if (@($result.artifacts).Count -eq 0) { continue }'
$hashAcceptanceTarget = 'if ($result.status -eq ''pass'' -and'
$evidenceGuardTarget = 'if (-not $evidenceRun) {'
$resultDirAssignmentTarget =
    '$resultDir = Split-Path -Parent $resultPath'
$resultDirJoinTarget =
    'Join-Path $resultDir ([string]$artifact.path)'
$evidenceWriteTarget =
    'Write-Host "Release SHA $sha is covered by interactive Test run $($evidenceRun.databaseId)."'
$missingMetadataGuardTarget =
    'if (-not $artifact.sha256 -or -not $artifact.path) {'
$containmentGuardTarget =
    'if (-not $artifactPath.StartsWith($artifactRootFull, [StringComparison]::OrdinalIgnoreCase) -or' +
        "`n" +
        '        -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {'
$hashMismatchGuardTarget =
    'if ($actualHash -ne ([string]$artifact.sha256).ToLowerInvariant()) {'
if ($otherJsonSourceScript -ceq $releaseInteractiveEvidenceScript -or
    $otherRunsSourceScript -ceq $releaseInteractiveEvidenceScript -or
    -not $releaseInteractiveEvidenceScript.Contains($matchingCountTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($shaAssignmentTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($resultAssignmentTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($artifactFloorTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($hashAcceptanceTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($evidenceGuardTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($resultDirAssignmentTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($resultDirJoinTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($evidenceWriteTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($missingMetadataGuardTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($containmentGuardTarget) -or
    -not $releaseInteractiveEvidenceScript.Contains($hashMismatchGuardTarget)) {
    throw 'Release success-predicate source-binding mutation target is missing.'
}
$addTypeEvidenceMutation =
    "Add-Type -TypeDefinition 'public static class EvidenceMutator { public static void Set() {} }'`n[EvidenceMutator]::Set()"
$memberDispatchEvidenceMutation =
    "[PSObject].Assembly | ForEach-Object -MemberName ('Get' + 'Type') -ArgumentList 'System.Management.Automation.ScriptBlock'"
$invalidSuccessSourceMutants = @{
    'runs JSON source substitution' = $otherJsonSourceScript
    'runs JSON source comment decoy' =
        $otherJsonSourceScript + "`n# $runsSourceTarget"
    'runs JSON source dead-code decoy' =
        $otherJsonSourceScript +
            "`n" +
            'if ($false) { $runs = @($runsJson | ConvertFrom-Json) }'
    'matching source substitution' = $otherRunsSourceScript
    'matching source comment decoy' =
        $otherRunsSourceScript + "`n# $matchingSourceTarget"
    'matching source dead-code decoy' =
        $otherRunsSourceScript +
            "`n" +
            'if ($false) { $matching = @($runs | Where-Object { $_.headSha -eq $sha -and $_.status -eq "completed" -and $_.conclusion -eq "success" }) }'
    'live nested runs JSON reassignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "if (`$true) { `$runsJson = `$otherJson }`n$runsSourceTarget"
        )
    'dead nested runs JSON reassignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "if (`$false) { `$runsJson = `$otherJson }`n$runsSourceTarget"
        )
    'live nested runs reassignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "$runsSourceTarget`nif (`$true) { `$runs = @(`$otherJson | ConvertFrom-Json) }"
        )
    'dead nested runs reassignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "$runsSourceTarget`nif (`$false) { `$runs = @(`$otherJson | ConvertFrom-Json) }"
        )
    'live nested matching reassignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "if (`$true) { `$matching = @(`$otherRuns) }`n$matchingCountTarget"
        )
    'dead nested matching reassignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "if (`$false) { `$matching = @(`$otherRuns) }`n$matchingCountTarget"
        )
    'indexed runs JSON mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "`$runsJson[0] = 'x'`n$runsSourceTarget"
        )
    'indexed runs mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "$runsSourceTarget`n`$runs[0] = `$otherRun"
        )
    'indexed matching mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$matching[0] = `$otherRun`n$matchingCountTarget"
        )
    'runs method mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "$runsSourceTarget`n`$runs.Clear()"
        )
    'matching member decoy' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$null = `$matching.Count`n$matchingCountTarget"
        )
    'runs JSON unexpected read' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "`$null = `$runsJson`n$runsSourceTarget"
        )
    'Set-Variable runs mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "$runsSourceTarget`nSet-Variable -Name runs -Value @(`$otherRun)"
        )
    'SessionState PSVariable runs mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $runsSourceTarget,
            "$runsSourceTarget`n`$ExecutionContext.SessionState.PSVariable.Set('runs', @(`$otherRun))"
        )
    'qualified Set-Variable mutation' =
        $releaseInteractiveEvidenceScript +
            "`nMicrosoft.PowerShell.Utility\Set-Variable -Name runs -Value @(`$otherRun)"
    'Set-Variable alias mutation' =
        $releaseInteractiveEvidenceScript +
            "`nsv -Name runs -Value @(`$otherRun)"
    'Set-Variable set alias mutation' =
        $releaseInteractiveEvidenceScript +
            "`nset -Name runs -Value @(`$otherRun)"
    'New-Variable mutation' =
        $releaseInteractiveEvidenceScript +
            "`nNew-Variable -Name runs -Value @(`$otherRun)"
    'New-Variable alias mutation' =
        $releaseInteractiveEvidenceScript +
            "`nnv -Name runs -Value @(`$otherRun)"
    'Remove-Variable mutation' =
        $releaseInteractiveEvidenceScript +
            "`nRemove-Variable -Name runs"
    'Remove-Variable alias mutation' =
        $releaseInteractiveEvidenceScript +
            "`nrv -Name runs"
    'Clear-Variable mutation' =
        $releaseInteractiveEvidenceScript +
            "`nClear-Variable -Name runs"
    'Clear-Variable alias mutation' =
        $releaseInteractiveEvidenceScript +
            "`nclv -Name runs"
    'Invoke-Expression mutation' =
        $releaseInteractiveEvidenceScript +
            "`niex '`$runs = @(`$otherRun)'"
    'ScriptBlock Create mutation' =
        $releaseInteractiveEvidenceScript +
            "`n[ScriptBlock]::Create('`$runs = @(`$otherRun)').Invoke()"
    'dynamic Set-Variable call mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$mutator = 'Set-Variable'`n& `$mutator -Name matching -Value @(`$otherRun)`n$matchingCountTarget"
        )
    'Get-Command call mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "& (Get-Command Set-Variable) -Name matching -Value @(`$otherRun)`n$matchingCountTarget"
        )
    'module-qualified stored command mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$mutator = 'Microsoft.PowerShell.Utility\Set-Variable'`n& `$mutator -Name matching -Value @(`$otherRun)`n$matchingCountTarget"
        )
    'static dot-source mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            ". ./scripts/replace-release-evidence.ps1`n$matchingCountTarget"
        )
    'static call-operator mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "& Write-Output harmless`n$matchingCountTarget"
        )
    'stored reflection mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$scriptBlockType = {}.GetType()`n`$createMethod = `$scriptBlockType.GetMethod('Create', [type[]]@([string]))`n`$payload = `$createMethod.Invoke(`$null, @('Set-Variable -Scope 1 -Name matching -Value @()'))`n`$payload.Invoke()`n$matchingCountTarget"
        )
    'DefaultRunspace state proxy mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "[runspace]::DefaultRunspace.SessionStateProxy.SetVariable('matching', @(`$otherRun))`n$matchingCountTarget"
        )
    'Tee-Object variable mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "Write-Output ([pscustomobject]@{ databaseId = 4242 }) | Tee-Object -Variable matching | Out-Null`n$matchingCountTarget"
        )
    'OutVariable mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "Write-Output ([pscustomobject]@{ databaseId = 4242 }) -OutVariable matching | Out-Null`n$matchingCountTarget"
        )
    'OutVariable prefix mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "Write-Output ([pscustomobject]@{ databaseId = 4242 }) -OutV matching | Out-Null`n$matchingCountTarget"
        )
    'PipelineVariable mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "Write-Output ([pscustomobject]@{ databaseId = 4242 }) -PipelineVariable matching | Out-Null`n$matchingCountTarget"
        )
    'PipelineVariable prefix mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "Write-Output ([pscustomobject]@{ databaseId = 4242 }) -PipelineV matching | Out-Null`n$matchingCountTarget"
        )
    'ErrorVariable mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "Write-Error forged -ErrorVariable matching -ErrorAction SilentlyContinue`n$matchingCountTarget"
        )
    'PSObject member dispatch mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$dispatch = [pscustomobject]@{ mutate = { Set-Variable -Scope 1 -Name matching -Value @() } }`n`$dispatch.PSObject.Properties['mutate'].Value.Invoke()`n$matchingCountTarget"
        )
    'Add-Type static method mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            $addTypeEvidenceMutation + "`n" + $matchingCountTarget
        )
    'Assembly Load mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "[Reflection.Assembly]::Load([Convert]::FromBase64String('AA=='))`n$matchingCountTarget"
        )
    'ForEach-Object MemberName dispatch mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            $memberDispatchEvidenceMutation + "`n" + $matchingCountTarget
        )
    'PSCmdlet session-state mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "function Invoke-EvidenceMutation {`n    [CmdletBinding()]`n    param()`n    `$PSCmdlet.SessionState.PSVariable.Set('script:matching', @())`n}`nInvoke-EvidenceMutation`n$matchingCountTarget"
        )
    'splatted OutVariable mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$writeParams = @{ OutVariable = 'matching' }`nWrite-Output ([pscustomobject]@{ databaseId = 4242 }) @writeParams`n$matchingCountTarget"
        )
    'stored provider path Set-Item mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$providerPath = 'variable:matching'`nSet-Item -Path `$providerPath -Value @(`$otherRun)`n$matchingCountTarget"
        )
    'stored provider path Get-Item access' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$providerPath = 'variable:matching'`n`$providerItem = Get-Item -Path `$providerPath`n$matchingCountTarget"
        )
    'Clear-Item alias mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "cli -Path variable:matching`n$matchingCountTarget"
        )
    'Remove-Item alias mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "ri -Path variable:matching`n$matchingCountTarget"
        )
    'Copy-Item alias mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "cpi -Path variable:matching -Destination variable:other`n$matchingCountTarget"
        )
    'Move-Item alias mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "mv -Path variable:matching -Destination variable:other`n$matchingCountTarget"
        )
    'Rename-Item alias mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "rni -Path variable:matching -NewName other`n$matchingCountTarget"
        )
    'ItemProperty alias mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "sp -Path variable:matching -Name Value -Value @(`$otherRun)`n$matchingCountTarget"
        )
    'Content alias mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "sc -Path variable:matching -Value 'forged'`n$matchingCountTarget"
        )
    'extra New-Item alias mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "ni -Path variable:matching -Value @(`$otherRun) -Force`n$matchingCountTarget"
        )
    'module-qualified New-Item stored provider path' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$providerPath = 'variable:matching'`nMicrosoft.PowerShell.Management\New-Item -Path `$providerPath -Value @(`$otherRun) -Force`n$matchingCountTarget"
        )
    'Get-ChildItem alias stored provider mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$providerPath = 'variable:matching'`n`$providerItem = gci -Path `$providerPath`n`$providerItem.Value = @(`$otherRun)`n$matchingCountTarget"
        )
    'Get-Content stored provider mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$providerPath = 'variable:matching'`n`$providerItem = Get-Content -Path `$providerPath`n`$providerItem.Value = @(`$otherRun)`n$matchingCountTarget"
        )
    'wrapped ExecutionContext mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $matchingCountTarget,
            "`$ec = @(`$ExecutionContext)[0]`n`$ec.SessionState.PSVariable.Set('matching', @(`$otherRun))`n$matchingCountTarget"
        )
    'count-preserving evidenceRun ref substitution' =
        $releaseInteractiveEvidenceScript.Replace(
            $evidenceWriteTarget,
            "`$evidenceRunRef = [ref]`$evidenceRun`nWrite-Host `"Release SHA `$sha is covered by an interactive Test run.`""
        )
    'count-preserving resultDir ref substitution' =
        $releaseInteractiveEvidenceScript.Replace(
            $resultDirAssignmentTarget,
            "$resultDirAssignmentTarget`n`$resultDirRef = [ref]`$resultDir"
        ).Replace(
            $resultDirJoinTarget,
            'Join-Path $artifactRoot ([string]$artifact.path)'
        )
    'missing metadata guard neutralized' =
        $releaseInteractiveEvidenceScript.Replace(
            $missingMetadataGuardTarget,
            'if ($false) {'
        )
    'containment guard neutralized' =
        $releaseInteractiveEvidenceScript.Replace(
            $containmentGuardTarget,
            'if ($false) {'
        )
    'hash mismatch guard neutralized' =
        $releaseInteractiveEvidenceScript.Replace(
            $hashMismatchGuardTarget,
            'if ($false) {'
        )
    'forged result assignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $resultAssignmentTarget,
            "$resultAssignmentTarget`nif (`$true) { `$result = [pscustomobject]@{ status = 'pass'; implementation_commit = `$sha; workflow_run_id = `$run.databaseId; artifacts = @() } }"
        )
    'forged SHA assignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $shaAssignmentTarget,
            "$shaAssignmentTarget`nif (`$true) { `$sha = 'forged' }"
        )
    'forged hashes-bound assignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $hashAcceptanceTarget,
            "if (`$true) { `$hashesBound = `$true }`n$hashAcceptanceTarget"
        )
    'forged evidence-run assignment' =
        $releaseInteractiveEvidenceScript.Replace(
            $evidenceGuardTarget,
            "if (`$true) { `$evidenceRun = [pscustomobject]@{ databaseId = 1 } }`n$evidenceGuardTarget"
        )
    'result member mutation' =
        $releaseInteractiveEvidenceScript.Replace(
            $resultAssignmentTarget,
            "$resultAssignmentTarget`n`$result.status = 'pass'"
        )
    'vacuous artifact floor' =
        $releaseInteractiveEvidenceScript.Replace(
            $artifactFloorTarget,
            'if (@($result.artifacts).Count -lt 0) { continue }'
        )
}
foreach ($mutant in $invalidSuccessSourceMutants.GetEnumerator()) {
    if (Test-ReleaseInteractiveSuccessPredicates `
        -ScriptText $mutant.Value `
        -ExpectedScriptSha256 $releaseInteractiveEvidenceScriptSha256) {
        throw "Release success-predicate contract accepted source mutant: $($mutant.Key)"
    }
}
$successPredicateMutationSpecs = @(
    [pscustomobject]@{
        Label = 'GitHub success filter'
        Active = '--status success'
        Removed = '--status queued'
        Inverted = '--status failure'
        Dead = 'if ($false) { ''--status success'' }'
    },
    [pscustomobject]@{
        Label = 'exact candidate head'
        Active = '$_.headSha -eq $sha'
        Removed = '$true'
        Inverted = '$_.headSha -ne $sha'
        Dead = 'if ($false) { $_.headSha -eq $sha }'
    },
    [pscustomobject]@{
        Label = 'completed candidate'
        Active = '$_.status -eq "completed"'
        Removed = '$true'
        Inverted = '$_.status -ne "completed"'
        Dead = 'if ($false) { $_.status -eq "completed" }'
    },
    [pscustomobject]@{
        Label = 'successful candidate'
        Active = '$_.conclusion -eq "success"'
        Removed = '$true'
        Inverted = '$_.conclusion -ne "success"'
        Dead = 'if ($false) { $_.conclusion -eq "success" }'
    },
    [pscustomobject]@{
        Label = 'passing result'
        Active = '$result.status -eq ''pass'''
        Removed = '$true'
        Inverted = '$result.status -ne ''pass'''
        Dead = 'if ($false) { $result.status -eq ''pass'' }'
    },
    [pscustomobject]@{
        Label = 'evidence implementation SHA'
        Active = '$result.implementation_commit -eq $sha'
        Removed = '$true'
        Inverted = '$result.implementation_commit -ne $sha'
        Dead = 'if ($false) { $result.implementation_commit -eq $sha }'
    },
    [pscustomobject]@{
        Label = 'evidence workflow run'
        Active =
            '[string]$result.workflow_run_id -eq [string]$run.databaseId'
        Removed = '$true'
        Inverted =
            '[string]$result.workflow_run_id -ne [string]$run.databaseId'
        Dead =
            'if ($false) { [string]$result.workflow_run_id -eq [string]$run.databaseId }'
    },
    [pscustomobject]@{
        Label = 'evidence artifact hashes'
        Active = '$hashesBound'
        Removed = '$true'
        Inverted = '-not $hashesBound'
        Dead = 'if ($false) { $hashesBound }'
    }
)
foreach ($spec in $successPredicateMutationSpecs) {
    $targetIndex = $releaseInteractiveEvidenceScript.LastIndexOf(
        $spec.Active,
        [StringComparison]::Ordinal
    )
    if ($targetIndex -lt 0) {
        throw "Release success-predicate mutation target is missing: $($spec.Label)"
    }
    $prefix = $releaseInteractiveEvidenceScript.Substring(0, $targetIndex)
    $suffix = $releaseInteractiveEvidenceScript.Substring(
        $targetIndex + $spec.Active.Length
    )
    $removedScript = $prefix + $spec.Removed + $suffix
    $invertedScript = $prefix + $spec.Inverted + $suffix
    $mutants = @(
        [pscustomobject]@{
            Label = "$($spec.Label) inversion"
            Script = $invertedScript
        },
        [pscustomobject]@{
            Label = "$($spec.Label) comment decoy"
            Script = $removedScript + "`n# $($spec.Active)"
        },
        [pscustomobject]@{
            Label = "$($spec.Label) dead-code decoy"
            Script = $removedScript + "`n$($spec.Dead)"
        }
    )
    foreach ($mutant in $mutants) {
        if (Test-ReleaseInteractiveSuccessPredicates `
            -ScriptText $mutant.Script `
            -ExpectedScriptSha256 $releaseInteractiveEvidenceScriptSha256) {
            throw "Release success-predicate contract accepted mutant: $($mutant.Label)"
        }
    }
}
Invoke-ContractTable -Contracts @(
    @{
        File = "$releaseWorkflow :: Require successful Test workflow for release SHA"
        Content = {
            $releaseInteractiveEvidenceStep
        }
        Pattern = '(?ms)gh run list.*?--workflow Test.*?--commit \$sha.*?\$_\.name -eq ''Windows 11 Interactive Composite''.*?\$_\.conclusion -eq ''success''.*?\$artifact\.sha256.*?\$artifact\.path.*?Get-FileHash.*?\$result\.implementation_commit -eq \$sha.*?\$result\.workflow_run_id.*?\$hashesBound.*?exact-SHA, hash-bound evidence'
        Kind = 'Text'
        Description = 'release remains gated on successful exact-SHA hash-bound interactive evidence'
    }
    @{
        File = "$releaseWorkflow :: Release preflight"
        Content = {
            $releasePreflightInvocationStep
        }
        Pattern = '(?ms)uses: \./\.github/actions/release-preflight.*?version: \$\{\{ steps\.meta\.outputs\.version \}\}.*?prerelease: \$\{\{ steps\.meta\.outputs\.prerelease \}\}.*?require-package-managers: "true".*?github-token: \$\{\{ github\.token \}\}.*?scoop-bucket-token: \$\{\{ secrets\.SCOOP_BUCKET_TOKEN \}\}.*?wingetcreate-token: \$\{\{ secrets\.WINGETCREATE_TOKEN \}\}'
        Kind = 'Text'
        Description = 'release workflow pins the shared preflight action and exact release inputs'
    }
    @{
        File = "$readinessWorkflow :: Validate release configuration"
        Content = {
            $readinessPreflightInvocationStep
        }
        Pattern = '(?ms)uses: \./\.github/actions/release-preflight.*?version: \$\{\{ inputs\.version \}\}.*?prerelease: "false".*?require-package-managers: \$\{\{ inputs\.require_package_managers \}\}.*?github-token: \$\{\{ github\.token \}\}.*?scoop-bucket-token: \$\{\{ secrets\.SCOOP_BUCKET_TOKEN \}\}.*?wingetcreate-token: \$\{\{ secrets\.WINGETCREATE_TOKEN \}\}'
        Kind = 'Text'
        Description = 'readiness workflow pins the shared preflight action and exact dispatch inputs'
    }
    @{
        File = "$releasePreflightAction :: Validate release configuration"
        Content = {
            $releasePreflightStep
        }
        Pattern = '(?ms)GH_TOKEN: \$\{\{ inputs\.github-token \}\}.*?SCOOP_BUCKET_TOKEN: \$\{\{ inputs\.scoop-bucket-token \}\}.*?WINGETCREATE_TOKEN: \$\{\{ inputs\.wingetcreate-token \}\}.*?check-release-copy\.ps1 -ExpectedVersion.*?\r?\n\s+if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}.*?release-preflight\.ps1 @preflightArgs'
        Kind = 'Text'
        Description = 'shared preflight propagates release-copy failures before exact release validation'
    }
    @{
        File = "$releaseWorkflow :: Verify published release copy and assets"
        Content = {
            (Get-YamlStepBlock -Content $releaseWorkflowText -Name 'Verify published release copy and assets' -Source $releaseWorkflow)
        }
        Pattern = '(?ms)env:\s+GH_TOKEN: \$\{\{ github\.token \}\}.*?CheckRemoteLatest.*?if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}.*?verify-published-release\.ps1 -Version \$env:RELEASE_VERSION.*?if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}'
        Kind = 'Text'
        Description = 'post-publish remote verification authenticates gh and fails closed on copy and byte/signature checks'
    }
    @{
        File = "$releaseWorkflow :: Publish GitHub Release"
        Content = {
            (Get-YamlStepBlock -Content $releaseWorkflowText -Name 'Publish GitHub Release' -Source $releaseWorkflow)
        }
        Pattern = '(?ms)GH_REPO: \$\{\{ github\.repository \}\}.*?RELEASE_TAG: \$\{\{ steps\.meta\.outputs\.tag \}\}.*?RELEASE_PRERELEASE: \$\{\{ steps\.meta\.outputs\.prerelease \}\}.*?release-publish-github\.ps1.*?-Tag \$env:RELEASE_TAG.*?-Version \$env:RELEASE_VERSION.*?-Prerelease \$env:RELEASE_PRERELEASE'
        Kind = 'Text'
        Description = 'GitHub release publication passes exact metadata through environment-bound script parameters'
    }
)

$releaseAttestationStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Attest published release artifacts' `
    -Source $releaseWorkflow
$expectedAttestationSubjects = @(
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-x64/noctty-${{ steps.meta.outputs.version }}-windows-x64-setup.exe',
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-x64/noctty-${{ steps.meta.outputs.version }}-windows-x64-portable.zip',
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-x64/noctty-${{ steps.meta.outputs.version }}-windows-x64-portable.manifest.ps1',
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-x64/SHA256SUMS-windows-x64.txt',
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-arm64/noctty-${{ steps.meta.outputs.version }}-windows-arm64-setup.exe',
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-arm64/noctty-${{ steps.meta.outputs.version }}-windows-arm64-portable.zip',
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-arm64/noctty-${{ steps.meta.outputs.version }}-windows-arm64-portable.manifest.ps1',
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-arm64/SHA256SUMS-windows-arm64.txt',
    'dist/artifacts/noctty-${{ steps.meta.outputs.version }}-windows-x64/SHA256SUMS.txt'
)
$attestationSubjectBlock = [regex]::Match(
    $releaseAttestationStep,
    '(?ms)^        with:\s*\r?\n          subject-path: \|\s*\r?\n(?<body>(?:^            .+\r?\n)+)'
)
if (-not $attestationSubjectBlock.Success) {
    throw 'Release attestation step must declare with.subject-path.'
}
$actualAttestationSubjects = @(
    $attestationSubjectBlock.Groups['body'].Value -split '\r?\n' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($actualAttestationSubjects.Count -ne 9 -or
    @($expectedAttestationSubjects | Where-Object { $_ -notin $actualAttestationSubjects }).Count -gt 0 -or
    @($actualAttestationSubjects | Where-Object { $_ -notin $expectedAttestationSubjects }).Count -gt 0 -or
    $releaseAttestationStep.Contains('noctty-icon.svg', [StringComparison]::Ordinal)) {
    throw 'Release attestation subjects must be exactly the nine non-icon published assets.'
}
$releaseGithubPublisher = Join-Path $repoRoot 'scripts\release-publish-github.ps1'
$releaseGithubPublisherText = Get-Content -LiteralPath $releaseGithubPublisher -Raw
$releaseScoopPublisher = Join-Path $repoRoot 'scripts\release-publish-scoop.ps1'
$releaseScoopPublisherText = Get-Content -LiteralPath $releaseScoopPublisher -Raw
$releaseWingetSubmitter = Join-Path $repoRoot 'scripts\release-submit-winget.ps1'
$releaseWingetSubmitterText = Get-Content -LiteralPath $releaseWingetSubmitter -Raw
$releaseArtifactVerifier = Join-Path $repoRoot 'scripts\release-verify-artifacts.ps1'
$releaseArtifactVerifierText = Get-Content -LiteralPath $releaseArtifactVerifier -Raw
$releaseDefenderScanner = Join-Path $repoRoot 'scripts\release-scan-defender.ps1'
$releaseDefenderScannerText = Get-Content -LiteralPath $releaseDefenderScanner -Raw
$releaseCommon = Join-Path $repoRoot 'scripts\common.ps1'
$releaseCommonText = Get-Content -LiteralPath $releaseCommon -Raw
$protectedReleaseScriptSpecs = @(
    [pscustomobject] @{
        Context = $releaseCommon
        Content = $releaseCommonText
        ExpectedSha256 =
            'bf8499f8548de2a84484dc04309aae481e694b5a39a9c6e84b05c4e5408f63c6'
        CriticalStatement =
            "    return [System.IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '..'))"
    }
    [pscustomobject] @{
        Context = $releaseDefenderScanner
        Content = $releaseDefenderScannerText
        ExpectedSha256 =
            'bf322937fcadd765ed7f32358bb496c38edc6f081a87da97fdbfb4e2e0e2b3e8'
        CriticalStatement = '& $scanner -SignatureUpdate'
    }
    [pscustomobject] @{
        Context = $releaseGithubPublisher
        Content = $releaseGithubPublisherText
        ExpectedSha256 =
            'bdd1d01feac86ee799f2d0292e342dfc00e87e95a07ff6eb25f87e0e1c68efb6'
        CriticalStatement = '& gh release view $Tag --repo $Repository *> $null'
    }
    [pscustomobject] @{
        Context = $releaseScoopPublisher
        Content = $releaseScoopPublisherText
        ExpectedSha256 =
            'fface463353e30d293c0a77d02a0e2a45b085b29ef08c0077760c86f89320432'
        CriticalStatement =
            "        & git @gitNetworkBoundArgs -c 'credential.helper=' -c 'credential.helper=!gh auth git-credential' push origin HEAD"
    }
    [pscustomobject] @{
        Context = $releaseWingetSubmitter
        Content = $releaseWingetSubmitterText
        ExpectedSha256 =
            'cd0024dd1c5d178d9884c7fcbeaeadc94db03096e64ac7579dffa2fa6a2376f5'
        CriticalStatement =
            '$result = Invoke-WinGetCreateUpdate -InstallerUrlArgs $installerUrlArgs'
    }
)
foreach ($spec in $protectedReleaseScriptSpecs) {
    $canonicalScript = ConvertTo-CanonicalText -Text $spec.Content
    if ((Get-CanonicalTextSha256 -Text $canonicalScript) -cne
        $spec.ExpectedSha256) {
        throw "Protected release script changed: $($spec.Context)"
    }
    if (@([regex]::Matches(
        $canonicalScript,
        [regex]::Escape($spec.CriticalStatement)
    )).Count -ne 1) {
        throw "Protected release-script mutation target is not unique: $($spec.Context)"
    }
    $indent = [regex]::Match(
        $spec.CriticalStatement,
        '^\s*'
    ).Value
    $statement = $spec.CriticalStatement.Substring($indent.Length)
    $sideEffect = "${indent}Set-Content -LiteralPath " +
        "([IO.Path]::Combine([IO.Path]::GetTempPath(), " +
        "'noctty-release-pin-mutant')) -Value 'mutated'"
    $mutants = [ordered] @{
        'injected early return' = $canonicalScript.Replace(
            $spec.CriticalStatement,
            (@("${indent}return", $spec.CriticalStatement) -join "`n")
        )
        'dead-code wrapping' = $canonicalScript.Replace(
            $spec.CriticalStatement,
            (@(
                "${indent}if (`$false) {",
                "${indent}    $statement",
                "${indent}}"
            ) -join "`n")
        )
        'added side effect' = $canonicalScript.Replace(
            $spec.CriticalStatement,
            (@(
                $sideEffect,
                $spec.CriticalStatement
            ) -join "`n")
        )
    }
    foreach ($mutation in $mutants.GetEnumerator()) {
        $mutationTokens = $null
        $mutationErrors = $null
        [void] [Management.Automation.Language.Parser]::ParseInput(
            $mutation.Value,
            [ref] $mutationTokens,
            [ref] $mutationErrors
        )
        if ($mutationErrors.Count -ne 0) {
            throw "Protected release-script mutation does not parse: $($spec.Context) :: $($mutation.Key)"
        }
        if ((Get-CanonicalTextSha256 -Text $mutation.Value) -ceq
            $spec.ExpectedSha256) {
            throw "Protected release script accepted full-file mutation: $($spec.Context) :: $($mutation.Key)"
        }
    }
}
$scoopCredentialHelperPush =
    "        & git @gitNetworkBoundArgs -c 'credential.helper=' -c 'credential.helper=!gh auth git-credential' push origin HEAD"
if ($releaseScoopPublisherText -match '(?i)x-access-token|git\s+remote\s+set-url' -or
    @([regex]::Matches(
        (ConvertTo-CanonicalText -Text $releaseScoopPublisherText),
        [regex]::Escape($scoopCredentialHelperPush)
    )).Count -ne 1 -or
    $releaseScoopPublisherText -notmatch
        '(?ms)GetRelativePath\(\s*\$RunnerTemp,\s*\$bucketDirectory\s*\).*?finally\s*\{\s*Remove-ValidatedScoopClone\s*\}') {
    throw 'Scoop publisher must use an ephemeral gh credential helper and finally-clean only its validated temp clone.'
}
if ($releaseScoopPublisherText -notmatch
        '(?ms)\$gitNetworkBoundArgs = @\(.*?''http\.lowSpeedLimit=1''.*?''http\.lowSpeedTime=60''.*?& git @gitNetworkBoundArgs @credentialHelperArgs @cloneArgs.*?& git @gitNetworkBoundArgs -c ''credential\.helper=''.*?push origin HEAD') {
    throw 'Scoop clone and push must both retain narrow Git low-speed transport bounds.'
}
if ($releaseScoopPublisherText -notmatch
        '(?ms)\$manifestRelativePath = if \(\[string\]::IsNullOrWhiteSpace\(\$ManifestPath\)\) \{\s*''bucket/noctty\.json''') {
    throw 'Scoop publisher must map absent, empty, and whitespace manifest configuration to the safe default.'
}
$scoopTokens = $null
$scoopParseErrors = $null
$scoopAst = [Management.Automation.Language.Parser]::ParseInput(
    $releaseScoopPublisherText,
    [ref] $scoopTokens,
    [ref] $scoopParseErrors
)
if ($scoopParseErrors.Count -ne 0) {
    throw "Scoop publisher does not parse: $releaseScoopPublisher"
}
$scoopCleanupFunctions = @($scoopAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Remove-ValidatedScoopClone'
}, $true))
if ($scoopCleanupFunctions.Count -ne 1 -or
    $scoopCleanupFunctions[0].Extent.Text -notmatch
        '(?ms)Get-Item -LiteralPath \$bucketDirectory -Force -ErrorAction Stop.*?-not \$cloneItem\.PSIsContainer.*?FileAttributes\]::ReparsePoint.*?Remove-Item -LiteralPath \$bucketDirectory -Recurse -Force' -or
    @([regex]::Matches(
        $releaseScoopPublisherText,
        '(?m)^\s*Remove-ValidatedScoopClone\s*$'
    )).Count -ne 2 -or
    @([regex]::Matches(
        $releaseScoopPublisherText,
        'Remove-Item -LiteralPath \$bucketDirectory -Recurse -Force'
    )).Count -ne 1) {
    throw 'Scoop clone cleanup must be factored through one directory/reparse-refusing function at both cleanup sites.'
}
$scoopCleanupProbeRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('noctty-scoop-cleanup-contract-' + [guid]::NewGuid().ToString('N'))
$scoopCleanupArtifactRoot = Join-Path $scoopCleanupProbeRoot 'artifacts'
$scoopCleanupMetadataDirectory = Join-Path `
    $scoopCleanupArtifactRoot `
    'noctty-1.3.999-windows-x64\package-managers'
$scoopCleanupManifestSource = Join-Path `
    $scoopCleanupProbeRoot `
    'noctty.json'
$scoopCleanupClonePath = Join-Path `
    $scoopCleanupProbeRoot `
    'noctty-scoop-bucket'
$previousScoopCleanupToken = $env:GH_TOKEN
try {
    [void] (New-Item `
        -ItemType Directory `
        -Path $scoopCleanupMetadataDirectory `
        -Force)
    Set-Content -LiteralPath $scoopCleanupManifestSource -Value '{}'
    @{
        scoop = @{
            manifestPath = $scoopCleanupManifestSource
        }
    } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath (
            Join-Path $scoopCleanupMetadataDirectory 'metadata.json'
        )
    Set-Content -LiteralPath $scoopCleanupClonePath -Value 'must survive'
    $env:GH_TOKEN = 'noctty-cleanup-contract-token'
    function git {
        throw 'Scoop cleanup contract unexpectedly reached git.'
    }
    $cleanupRejected = $false
    try {
        & $releaseScoopPublisher `
            -Version 1.3.999 `
            -BucketRepository 'owner/repository' `
            -ArtifactRoot $scoopCleanupArtifactRoot `
            -RunnerTemp $scoopCleanupProbeRoot `
            -ManifestPath 'bucket/noctty.json' 6> $null
    }
    catch {
        if ($_.Exception.Message -notmatch
            'Scoop clone path is not a directory') {
            throw "Scoop cleanup refusal probe returned the wrong failure: $($_.Exception.Message)"
        }
        $cleanupRejected = $true
    }
    if (-not $cleanupRejected -or
        -not (Test-Path -LiteralPath $scoopCleanupClonePath -PathType Leaf)) {
        throw 'Scoop cleanup refusal probe deleted or accepted a non-directory clone path.'
    }
}
finally {
    $env:GH_TOKEN = $previousScoopCleanupToken
    Remove-Item Function:\git -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $scoopCleanupClonePath -PathType Leaf) {
        Remove-Item -LiteralPath $scoopCleanupClonePath -Force
    }
    if (Test-Path -LiteralPath $scoopCleanupProbeRoot) {
        $cleanupProbeItem = Get-Item `
            -LiteralPath $scoopCleanupProbeRoot `
            -Force
        if (-not $cleanupProbeItem.PSIsContainer -or
            ($cleanupProbeItem.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Scoop cleanup contract temp root became unsafe to remove.'
        }
        Remove-Item `
            -LiteralPath $scoopCleanupProbeRoot `
            -Recurse `
            -Force
    }
}
$scoopManifestValidationIndex = $releaseScoopPublisherText.IndexOf(
    '[System.IO.Path]::IsPathRooted($manifestRelativePath)',
    [StringComparison]::Ordinal
)
$scoopManifestNormalizationIndex = $releaseScoopPublisherText.IndexOf(
    '$destinationManifestPath = [System.IO.Path]::GetFullPath(',
    [StringComparison]::Ordinal
)
$scoopManifestContainmentIndex = $releaseScoopPublisherText.IndexOf(
    '$destinationManifestPath.StartsWith(',
    [StringComparison]::Ordinal
)
$scoopManifestReparseIndex = $releaseScoopPublisherText.IndexOf(
    '[System.IO.FileAttributes]::ReparsePoint',
    [StringComparison]::Ordinal
)
$scoopManifestCreateIndex = $releaseScoopPublisherText.IndexOf(
    'New-Item -ItemType Directory -Path $destinationManifestDirectory',
    [StringComparison]::Ordinal
)
$scoopManifestCopyIndex = $releaseScoopPublisherText.IndexOf(
    'Copy-Item -LiteralPath $metadata.scoop.manifestPath',
    [StringComparison]::Ordinal
)
$scoopManifestAddIndex = $releaseScoopPublisherText.IndexOf(
    '& git add -- $manifestRelativePath',
    [StringComparison]::Ordinal
)
if ($releaseScoopPublisherText -notmatch
        '(?ms)\$manifestPathSegments.*?-ceq ''\.\.''.*?Scoop manifest path must not contain parent traversal' -or
    $scoopManifestValidationIndex -lt 0 -or
    $scoopManifestNormalizationIndex -le $scoopManifestValidationIndex -or
    $scoopManifestContainmentIndex -le $scoopManifestNormalizationIndex -or
    $scoopManifestReparseIndex -le $scoopManifestContainmentIndex -or
    $scoopManifestCreateIndex -le $scoopManifestReparseIndex -or
    $scoopManifestCopyIndex -le $scoopManifestCreateIndex -or
    $scoopManifestAddIndex -le $scoopManifestCopyIndex) {
    throw 'Scoop manifest destination must be normalized, clone-confined, and reparse-checked before write or git add.'
}
$scoopManifestPathProbeRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    'noctty-scoop-manifest-path-contract'
$invalidScoopManifestPaths = @(
    [pscustomobject] @{
        Label = 'rooted path'
        Value = Join-Path $scoopManifestPathProbeRoot 'outside.json'
    }
    [pscustomobject] @{
        Label = 'parent traversal'
        Value = '..\outside.json'
    }
    [pscustomobject] @{
        Label = 'nested parent traversal'
        Value = 'bucket\..\outside.json'
    }
    [pscustomobject] @{
        Label = 'forward-slash parent traversal'
        Value = 'bucket/../../outside.json'
    }
    [pscustomobject] @{
        Label = 'directory-like path'
        Value = 'bucket\'
    }
)
$previousScoopProbeToken = $env:GH_TOKEN
try {
    $env:GH_TOKEN = 'noctty-contract-probe-token'
    foreach ($case in $invalidScoopManifestPaths) {
        $rejected = $false
        try {
            & $releaseScoopPublisher `
                -Version 1.3.999 `
                -BucketRepository 'owner/repository' `
                -ManifestPath $case.Value `
                -RunnerTemp $scoopManifestPathProbeRoot `
                -WhatIf 6> $null
        }
        catch {
            if ($_.Exception.Message -notmatch 'Scoop manifest path') {
                throw "Scoop manifest path probe returned the wrong failure: $($case.Label) :: $($_.Exception.Message)"
            }
            $rejected = $true
        }
        if (-not $rejected) {
            throw "Scoop manifest path probe accepted $($case.Label)."
        }
    }
    foreach ($defaultPath in @('', '   ')) {
        & $releaseScoopPublisher `
            -Version 1.3.999 `
            -BucketRepository 'owner/repository' `
            -ManifestPath $defaultPath `
            -RunnerTemp $scoopManifestPathProbeRoot `
            -WhatIf 6> $null
    }
    & $releaseScoopPublisher `
        -Version 1.3.999 `
        -BucketRepository 'owner/repository' `
        -RunnerTemp $scoopManifestPathProbeRoot `
        -WhatIf 6> $null
    & $releaseScoopPublisher `
        -Version 1.3.999 `
        -BucketRepository 'owner/repository' `
        -ManifestPath 'bucket\.\noctty.json' `
        -RunnerTemp $scoopManifestPathProbeRoot `
        -WhatIf 6> $null
}
finally {
    $env:GH_TOKEN = $previousScoopProbeToken
}
$checksumMembershipGuard =
    '$checksumEntries.Count -ne $expectedChecksumNames.Count'
$checksumMembershipIndex = $releaseArtifactVerifierText.IndexOf(
    $checksumMembershipGuard,
    [StringComparison]::Ordinal
)
$checksumHashLoopIndex = $releaseArtifactVerifierText.IndexOf(
    'foreach ($path in @($setup, $portable))',
    [StringComparison]::Ordinal
)
if ($releaseArtifactVerifierText -notmatch
        '(?ms)\$expectedChecksumNames = @\(.*?GetFileName\(\$setup\).*?GetFileName\(\$portable\).*?\$checksumEntries\.Count -ne \$expectedChecksumNames\.Count.*?Where-Object\s*\{\s*-not \$checksumEntries\.Contains\(\$_\)' -or
    $checksumMembershipIndex -lt 0 -or
    $checksumHashLoopIndex -le $checksumMembershipIndex) {
    throw 'Local artifact verification must require exactly the setup and portable checksum entries before comparing hashes.'
}
if ($releaseGithubPublisherText -notmatch
        '(?m)^\s*& gh release edit \$Tag --repo \$Repository --title \$Title "--prerelease=\$Prerelease"\s*$') {
    throw 'Existing GitHub releases must explicitly reconcile prerelease true and false.'
}
$wingetTokens = $null
$wingetParseErrors = $null
$wingetAst = [Management.Automation.Language.Parser]::ParseInput(
    $releaseWingetSubmitterText,
    [ref] $wingetTokens,
    [ref] $wingetParseErrors
)
if ($wingetParseErrors.Count -ne 0) {
    throw "WinGet submitter does not parse: $releaseWingetSubmitter"
}
$wingetWebRequests = @($wingetAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-WebRequest'
}, $true))
if ($wingetWebRequests.Count -ne 3 -or
    @($wingetWebRequests | Where-Object {
        @($_.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -ceq 'TimeoutSec'
        }).Count -ne 1
    }).Count -ne 0) {
    throw 'Every WinGet network request must have exactly one bounded TimeoutSec parameter.'
}
if ($releaseWingetSubmitterText -notmatch
        '(?ms)ProcessStartInfo.*?\.ArgumentList\.Add\(.*?ReadToEndAsync\(\).*?WaitForExit\(\$WinGetCreateTimeoutSeconds \* 1000\).*?\.Kill\(\$true\).*?WaitForExit\(\$ProcessTerminationTimeoutSeconds \* 1000\).*?\.Dispose\(\)' -or
    $releaseWingetSubmitterText -match
        '(?m)^\s*&\s+wingetcreate\b|\bStart-Process\b|\.Arguments\s*=|WINGETCREATE_TOKEN|''--token''' -or
    $releaseWingetSubmitterText -notmatch
        '(?m)^if \(-not \$env:WINGET_CREATE_GITHUB_TOKEN\) \{' -or
    $releaseWingetSubmitterText -notmatch
        '(?ms)\$output = \$output\.Replace\(\$env:WINGET_CREATE_GITHUB_TOKEN, ''\[REDACTED\]''\).*?Write-Host \$_') {
    throw 'WinGet submit must use a recorded, asynchronously drained, bounded process without joined command strings.'
}
foreach ($stablePublisher in @(
    [pscustomobject]@{ Name = 'Scoop'; Step = $releasePublishScoopStep },
    [pscustomobject]@{ Name = 'WinGet'; Step = $releaseSubmitWingetStep }
)) {
    if ($stablePublisher.Step -notmatch
        '(?m)^        if: steps\.meta\.outputs\.prerelease != ''true''\s*$') {
        throw "$($stablePublisher.Name) publication must be gated to stable releases."
    }
}
if ($releaseSubmitWingetStep -notmatch
        '(?m)^          WINGET_CREATE_GITHUB_TOKEN: \$\{\{ secrets\.WINGETCREATE_TOKEN \}\}\s*$' -or
    $releaseSubmitWingetStep -match
        '(?m)^          WINGETCREATE_TOKEN:') {
    throw 'The WinGet secret must reach wingetcreate only through its recognized environment variable.'
}
if ($releaseSubmitWingetStep -notmatch '(?m)^        timeout-minutes: 15\s*$') {
    throw 'The WinGet workflow step must retain a 15-minute second timeout guard.'
}
if ($releasePublishScoopStep -notmatch '(?m)^        timeout-minutes: 10\s*$') {
    throw 'The Scoop workflow step must retain a 10-minute second timeout guard.'
}
Invoke-ContractTable -Contracts @(
    @{
        File = $releaseGithubPublisher
        Content = { $releaseGithubPublisherText }
        Pattern = '(?ms)SupportsShouldProcess.*?Get-WindowsPackageArchitectures.*?legacy-checksums.*?noctty-icon\.svg.*?gh release view \$Tag --repo \$Repository.*?gh release create \$Tag --repo \$Repository.*?Failed to create.*?gh release edit \$Tag --repo \$Repository --title \$Title "--prerelease=\$Prerelease".*?Failed to edit.*?gh release upload \$Tag --repo \$Repository.*?Failed to upload'
        Kind = 'Text'
        Description = 'GitHub publisher preserves both-architecture assets, legacy alias, fork pinning, prerelease support, and fail-closed mutation paths'
    }
    @{
        File = $releaseScoopPublisher
        Content = { $releaseScoopPublisherText }
        Pattern = '(?ms)SupportsShouldProcess.*?Skipping Scoop publish: SCOOP_BUCKET_TOKEN.*?Skipping Scoop publish: SCOOP_BUCKET_REPO.*?GetRelativePath\(\s*\$RunnerTemp,\s*\$bucketDirectory\s*\).*?IsPathRooted\(\$manifestRelativePath\).*?\$destinationManifestPath\.StartsWith.*?Remove-ValidatedScoopClone.*?package-managers/metadata\.json.*?gitNetworkBoundArgs.*?http\.lowSpeedLimit=1.*?http\.lowSpeedTime=60.*?credentialHelperArgs.*?clone.*?--depth.*?--branch.*?git diff --cached --quiet --exit-code.*?manifest is unchanged.*?git commit.*?credential\.helper=!gh auth git-credential.*?git push failed.*?Pop-Location.*?finally.*?Remove-ValidatedScoopClone'
        Kind = 'Text'
        Description = 'Scoop publisher confines the manifest and keeps bounded authenticated clone/push, unchanged no-op, and fail-closed git operations'
    }
    @{
        File = $releaseWingetSubmitter
        Content = { $releaseWingetSubmitterText }
        Pattern = '(?ms)SupportsShouldProcess.*?Skipping WinGet submit: WINGET_CREATE_GITHUB_TOKEN.*?Initial WinGet bootstrap is still manual.*?api\.github\.com/repos/microsoft/winget-pkgs.*?TimeoutSec \$NetworkTimeoutSeconds.*?\$statusCode -eq 404.*?is not bootstrapped.*?Microsoft\.VCLibs\.x64\.14\.00\.Desktop\.appx.*?0x80073D06.*?higher version of this package is already installed.*?aka\.ms/Microsoft\.VCLibs\.x64\.14\.00\.Desktop\.appx.*?TimeoutSec \$NetworkTimeoutSeconds.*?wingetcreate/latest/msixbundle.*?TimeoutSec \$NetworkTimeoutSeconds.*?arm64.*?x64.*?installerUrlArgs\.Count -ne 2.*?ProcessStartInfo.*?''update''.*?''--submit''.*?''--no-open''.*?ArgumentList.*?ReadToEndAsync.*?WaitForExit.*?Kill\(\$true\).*?Dispose.*?ExitCode -ne 0'
        Kind = 'Text'
        Description = 'WinGet submitter preserves bootstrap skip, VCLibs newer-version tolerance, exact dual architecture URLs, authenticated noninteractive submit, and fail-closed exit handling'
    }
)
$defenderScanStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Scan Windows release artifacts with Microsoft Defender' `
    -Source $releaseWorkflow
Invoke-ContractTable -Contracts @(
    @{
        File = "$releaseWorkflow :: Scan Windows release artifacts with Microsoft Defender"
        Content = {
            $defenderScanStep
        }
        Pattern = '(?ms)RELEASE_VERSION: \$\{\{ steps\.meta\.outputs\.version \}\}.*?release-scan-defender\.ps1 -Version \$env:RELEASE_VERSION'
        Kind = 'Text'
        Description = 'Defender workflow step passes the exact release version to the extracted scanner'
    }
    @{
        File = $releaseDefenderScanner
        Content = { $releaseDefenderScannerText }
        Pattern = '(?ms)Get-MpComputerStatus -ErrorAction Stop.*?AMServiceEnabled.*?AntivirusEnabled.*?AMRunningMode -ne ''Normal''.*?-replace ''-\\d\+\$'', ''''.*?-as \[version\].*?Sort-Object Version -Descending.*?MpCmdRun\.exe.*?-SignatureUpdate.*?if \(\$LASTEXITCODE -ne 0\).*?noctty/noctty\.com.*?noctty/noctty\.exe.*?noctty/ghostty-vt\.dll.*?noctty/noctty-terminal-handoff-proxy\.dll.*?\$architectures = @\(Get-WindowsPackageArchitectures\).*?\$expectedScanCount = \$architectures\.Count \* \(1 \+ \$portablePayloads\.Count\).*?-Kind setup.*?noctty-release-verify-\$architecture.*?scanPaths\.Count -ne \$expectedScanCount.*?-Scan -ScanType 3 -File \$scanPath -DisableRemediation -ReturnHR.*?if \(\$LASTEXITCODE -ne 0\)'
        Kind = 'Text'
        Description = 'release scans installers and portable PE payloads with active current Microsoft Defender and fails closed'
    }
)
$signedArtifactStepIndex = $releaseWorkflowText.IndexOf('      - name: Verify signed release artifacts')
$defenderScanStepIndex = $releaseWorkflowText.IndexOf('      - name: Scan Windows release artifacts with Microsoft Defender')
$attestationGuardStepIndex = $releaseWorkflowText.IndexOf('      - name: Prepare build provenance attestation')
$attestationStepIndex = $releaseWorkflowText.IndexOf('      - name: Attest published release artifacts')
$publishReleaseStepIndex = $releaseWorkflowText.IndexOf('      - name: Publish GitHub Release')
if ($signedArtifactStepIndex -lt 0 -or
    $defenderScanStepIndex -le $signedArtifactStepIndex -or
    $attestationGuardStepIndex -le $defenderScanStepIndex -or
    $attestationStepIndex -le $attestationGuardStepIndex -or
    $publishReleaseStepIndex -le $attestationStepIndex) {
    throw 'Artifact verification, Defender scanning, provenance attestation, and publication are ordered incorrectly.'
}

Invoke-ContractTable -Contracts @(
    @{
        File = $releaseWorkflow
        Content = { $releaseWorkflowText }
        Pattern = '(?ms)^    permissions:.*?contents: write.*?actions: read.*?id-token: write.*?attestations: write.*?Prepare build provenance attestation.*?ATTEST_REPOSITORY.*?amanthanvi/noctty.*?ACTIONS_ID_TOKEN_REQUEST_URL.*?ACTIONS_ID_TOKEN_REQUEST_TOKEN.*?Attest published release artifacts.*?actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8.*?portable\.manifest\.ps1.*?SHA256SUMS\.txt'
        Kind = 'Text'
        Description = 'release provenance is job-scoped, canonical-repository guarded, pinned, and covers the nine non-icon assets'
    }
)
