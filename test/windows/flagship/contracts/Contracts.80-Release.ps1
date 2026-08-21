$releasePreflightInvocationStep = Get-YamlStepBlock `
    -Content $releaseWorkflowText `
    -Name 'Release preflight' `
    -Source $releaseWorkflow
$readinessPreflightInvocationStep = Get-YamlStepBlock `
    -Content $readinessWorkflowText `
    -Name 'Validate release configuration' `
    -Source $readinessWorkflow
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
    'df670c151c2bfc75bba3ad85039c5125a2d8a039dcaf2a7456bc18e9ba9f6072'
$readinessPreflightStepSha256 =
    '3b5844aeba60eab87f3caa862ac7f4d470cd0bbdbefa1e407a7ee5bb9209f814'
$releaseWorkflowSha256 =
    'e63220b5e18787fea830ed45238208f2d838318e5da56a53dbb6cd49b588a88c'
$readinessWorkflowSha256 =
    '6a50b670cedf6296eff1587358e4a2410396440bf57382745ecb766906e8e370'
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
            '(?m)^      (?:SCOOP_BUCKET_TOKEN|WINGETCREATE_TOKEN):') {
        throw "Publish-capable package-manager tokens escaped into job-level env: $($workflow.Context)"
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
$releaseGithubPublisher = Join-Path $repoRoot 'scripts\release-publish-github.ps1'
$releaseGithubPublisherText = Get-Content -LiteralPath $releaseGithubPublisher -Raw
$releaseScoopPublisher = Join-Path $repoRoot 'scripts\release-publish-scoop.ps1'
$releaseScoopPublisherText = Get-Content -LiteralPath $releaseScoopPublisher -Raw
$releaseWingetSubmitter = Join-Path $repoRoot 'scripts\release-submit-winget.ps1'
$releaseWingetSubmitterText = Get-Content -LiteralPath $releaseWingetSubmitter -Raw
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
            'a4020fbf4a1941caaf0857e81b2ded5a824231db913b40776e84dd74ba9581f5'
        CriticalStatement = '& $scanner -SignatureUpdate'
    }
    [pscustomobject] @{
        Context = $releaseGithubPublisher
        Content = $releaseGithubPublisherText
        ExpectedSha256 =
            '23fc5139f29e80735dac8c03229b52eec5cdc6600e97fa2622685d3e2c8db93c'
        CriticalStatement = '& gh release view $Tag --repo $Repository *> $null'
    }
    [pscustomobject] @{
        Context = $releaseScoopPublisher
        Content = $releaseScoopPublisherText
        ExpectedSha256 =
            '4ee4a29f7be2d5b55480b34b1158e5c7bd26e4c09bd5bf3cd63d8d92b2399e04'
        CriticalStatement = '    & git push origin HEAD'
    }
    [pscustomobject] @{
        Context = $releaseWingetSubmitter
        Content = $releaseWingetSubmitterText
        ExpectedSha256 =
            '7193cec016685320908631c1eaaba2f4fd7659445fe501ce84f2352813564c5d'
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
        "'winghostty-release-pin-mutant')) -Value 'mutated'"
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
Invoke-ContractTable -Contracts @(
    @{
        File = $releaseGithubPublisher
        Content = { $releaseGithubPublisherText }
        Pattern = '(?ms)SupportsShouldProcess.*?Get-WindowsPackageArchitectures.*?legacy-checksums.*?winghostty-icon\.svg.*?gh release view \$Tag --repo \$Repository.*?gh release create \$Tag --repo \$Repository.*?Failed to create.*?gh release edit \$Tag --repo \$Repository.*?Failed to edit.*?gh release upload \$Tag --repo \$Repository.*?Failed to upload'
        Kind = 'Text'
        Description = 'GitHub publisher preserves both-architecture assets, legacy alias, fork pinning, prerelease support, and fail-closed mutation paths'
    }
    @{
        File = $releaseScoopPublisher
        Content = { $releaseScoopPublisherText }
        Pattern = '(?ms)SupportsShouldProcess.*?Skipping Scoop publish: SCOOP_BUCKET_TOKEN.*?Skipping Scoop publish: SCOOP_BUCKET_REPO.*?package-managers/metadata\.json.*?repo.*?clone.*?--depth.*?--branch.*?x-access-token:\$env:GH_TOKEN.*?git diff --cached --quiet --exit-code.*?manifest is unchanged.*?git commit.*?git push origin HEAD.*?Pop-Location'
        Kind = 'Text'
        Description = 'Scoop publisher keeps credential/config skips, branch-aware shallow clone, authenticated push, unchanged no-op, and fail-closed git operations'
    }
    @{
        File = $releaseWingetSubmitter
        Content = { $releaseWingetSubmitterText }
        Pattern = '(?ms)SupportsShouldProcess.*?Skipping WinGet submit: WINGETCREATE_TOKEN.*?Initial WinGet bootstrap is still manual.*?api\.github\.com/repos/microsoft/winget-pkgs.*?\$statusCode -eq 404.*?is not bootstrapped.*?Microsoft\.VCLibs\.x64\.14\.00\.Desktop\.appx.*?0x80073D06.*?higher version of this package is already installed.*?arm64.*?x64.*?installerUrlArgs\.Count -ne 2.*?wingetcreate update.*?--submit.*?--no-open.*?--token \$env:WINGETCREATE_TOKEN.*?ExitCode -ne 0'
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
        Pattern = '(?ms)Get-MpComputerStatus -ErrorAction Stop.*?AMServiceEnabled.*?AntivirusEnabled.*?AMRunningMode -ne ''Normal''.*?-replace ''-\\d\+\$'', ''''.*?-as \[version\].*?Sort-Object Version -Descending.*?MpCmdRun\.exe.*?-SignatureUpdate.*?if \(\$LASTEXITCODE -ne 0\).*?winghostty/winghostty\.com.*?winghostty/winghostty\.exe.*?winghostty/ghostty-vt\.dll.*?Get-WindowsPackageArchitectures.*?-Kind setup.*?winghostty-release-verify-\$architecture.*?scanPaths\.Count -ne 8.*?-Scan -ScanType 3 -File \$scanPath -DisableRemediation -ReturnHR.*?if \(\$LASTEXITCODE -ne 0\)'
        Kind = 'Text'
        Description = 'release scans installers and portable PE payloads with active current Microsoft Defender and fails closed'
    }
)
$signedArtifactStepIndex = $releaseWorkflowText.IndexOf('      - name: Verify signed release artifacts')
$defenderScanStepIndex = $releaseWorkflowText.IndexOf('      - name: Scan Windows release artifacts with Microsoft Defender')
$publishReleaseStepIndex = $releaseWorkflowText.IndexOf('      - name: Publish GitHub Release')
if ($signedArtifactStepIndex -lt 0 -or
    $defenderScanStepIndex -le $signedArtifactStepIndex -or
    $publishReleaseStepIndex -le $defenderScanStepIndex) {
    throw 'Microsoft Defender scanning must run after artifact verification and before release publication.'
}
