Invoke-ContractTable -Contracts @(
    @{
        File = $releaseCopyChecker
        Pattern = '\$global:LASTEXITCODE\s*=\s*0\s*$'
        Kind = 'Workflow'
        Description = 'release-copy success explicitly clears native exit state'
    }
    @{
        File = $releasePreflight
        Pattern = '\$minimumValidityDays -lt 180(?!\d)'
        Kind = 'Workflow'
        Description = 'signer-validity overrides cannot lower the 180-day floor'
    }
    @{
        File = $windowsPackager
        Pattern = '(?ms)& zig build .*?\r?\n\s+if \(\$LASTEXITCODE -ne 0\) \{\s*throw "Zig build failed with exit code \$LASTEXITCODE\."'
        Kind = 'Workflow'
        Description = 'Windows packaging fails closed when its native Zig build fails'
    }
    @{
        File = $windowsPackager
        Pattern = '(?ms)foreach \(\$runtimeFile in \$runtimeFiles\).*?Assert-PeMachine.*?if \(\$Architecture -eq "x64"\).*?check-windows-x64-baseline\.ps1.*?-Path \$runtimePath'
        Kind = 'Workflow'
        Description = 'Windows packaging checks every x64 runtime PE for baseline compatibility'
    }
    @{
        File = $windowsPackager
        Pattern = '(?ms)Assert-WindowsBuildCapabilitiesManifest.*?Packaging arch.*?\$hostArchitecture -eq \$Architecture.*?koreterm\.com.*?\+version.*?custom shaders: enabled.*?hash-bound \$Architecture build manifest'
        Kind = 'Workflow'
        Description = 'Windows packaging verifies hash-bound shader capability for every target and executes native packages'
    }
    @{
        File = $windowsBuildCapabilities
        Pattern = '(?ms)Get-FileSha256Lower.*?custom_shaders = \$true.*?custom_shaders -ne \$true.*?Get-FileSha256Lower.*?\$actualHash -cne \[string\] \$hashProperty\.Value'
        Kind = 'Workflow'
        Description = 'build capability manifests bind shader support to every runtime artifact hash'
    }
    @{
        File = (Join-Path $repoRoot 'scripts\check-windows-x64-baseline.ps1')
        Pattern = '(?ms)Get-Command llvm-objdump\.exe.*?\$objdumpTimeoutMs = 120000.*?\$objdumpKillTimeoutMs = 5000.*?\$streamCopyTimeoutMs = 30000.*?WaitForExit\(\$objdumpTimeoutMs\).*?\$objdumpProcess\.Kill\(\).*?WaitForExit\(\$objdumpKillTimeoutMs\).*?llvm-objdump did not exit after termination.*?WaitAll\(.*?\$streamCopyTimeoutMs.*?llvm-objdump stream cleanup timed out'
        Kind = 'Workflow'
        Description = 'Windows x64 baseline disassembly is time-bounded and kills a timed-out tool'
    }
    @{
        File = (Join-Path $repoRoot 'scripts\release-publish-chocolatey.ps1')
        Pattern = '(?ms)Test-ChocolateyVersionPublished.*?nothing to push.*?choco push.*?\$pushExitCode -ne 0\) \{\s*(?:#[^\n]*\n\s*)*if \(-not \$Resubmit -and \(Test-ChocolateyVersionPublished.*?treating the push as complete.*?\$global:LASTEXITCODE = 0\s*return\s*\}.*?throw "choco push failed'
        Kind = 'Workflow'
        Description = 'Chocolatey publishing is rerun-safe and tolerates a failed push only when the feed then holds the version and the run is not a deliberate resubmission (409 also means a failed validation)'
    }
    @{
        File = $releaseWorkflow
        Pattern = '(?ms)- name: Submit WinGet manifest update\r?\n.*?- name: Publish Chocolatey package\r?\n(?:(?!- name:).)*\z'
        Kind = 'Workflow'
        Description = 'Chocolatey publishes last, so a moderation 403 cannot keep WinGet from the release'
    }
    @{
        File = "$releasePreflight :: Assert-WingetArchitectureCoverage"
        Content = {
            (Get-PowerShellBlockText -Content (Get-Content -LiteralPath $releasePreflight -Raw) -HeaderPattern '^function\s+Assert-WingetArchitectureCoverage(?=\s|\{)')
        }
        Pattern = '(?ms)Assert-WingetArchitectureCoverage.*?Architecture:.*?arm64,x64'
        Kind = 'Text'
        Description = 'stable preflight requires public WinGet x64 and arm64 bootstrap'
    }
    @{
        File = "$releasePreflight :: RequirePackageManagers"
        Content = {
            (Get-PowerShellBlockText -Content (Get-Content -LiteralPath $releasePreflight -Raw) -HeaderPattern '^if \(\$RequirePackageManagers\)')
        }
        Pattern = '(?ms)Assert-WingetArchitectureCoverage\s+`\r?\n\s+-ManifestPath'
        Kind = 'Text'
        Description = 'package-manager preflight invokes the WinGet architecture gate'
    }
)
if (Test-Path -LiteralPath (Join-Path $repoRoot 'src\build\docker\debian')) {
    throw 'The unreferenced GTK application Docker residue must remain deleted from the Windows-only fork.'
}

# The Release workflow's Chocolatey push runs for every stable release unless
# the repository variable CHOCOLATEY_PUBLISH is 'off', the switch for while
# chocolatey.org refuses the push (docs/chocolatey-publishing.md). An unset
# variable still pushes, a prerelease never does, the key stays mapped, and
# nothing else may skip the step or hide its failure.
$releaseChocolateyCondition = 'if: steps.meta.outputs.prerelease != ''true'' && vars.CHOCOLATEY_PUBLISH != ''off'''
function Test-ReleaseChocolateyStep {
    param([Parameter(Mandatory)] [string] $Text)

    $problems = [System.Collections.Generic.List[string]]::new()
    $step = ConvertTo-CanonicalText -Text (Get-YamlStepBlock -Content $Text -Name 'Publish Chocolatey package' -Source $releaseWorkflow)
    $settings = @([regex]::Matches($step, '(?m)^        [''"]?(?:if|continue-on-error)[''"]?[ \t]*:.*$') | ForEach-Object { $_.Value.Trim() })
    if ($settings.Count -ne 1 -or $settings[0] -cne $releaseChocolateyCondition) {
        $problems.Add("its only condition must be: $releaseChocolateyCondition")
    }
    foreach ($required in @(
            '          CHOCO_API_KEY: ${{ secrets.CHOCO_API_KEY }}',
            '        run: ./scripts/release-publish-chocolatey.ps1 -Version $env:RELEASE_VERSION'
        )) {
        if ($step -cnotmatch ('(?m)^' + [regex]::Escape($required) + '$')) {
            $problems.Add("it lost: $($required.Trim())")
        }
    }
    return $problems.ToArray()
}

$releaseChocolateyProblems = @(Test-ReleaseChocolateyStep -Text $releaseWorkflowText)
if ($releaseChocolateyProblems.Count -ne 0) {
    throw "Release workflow Chocolatey step contract failed: $($releaseChocolateyProblems -join '; ')"
}
$releaseChocolateyCanonical = ConvertTo-CanonicalText -Text $releaseWorkflowText
$releaseChocolateyMutants = @(
    @{ Label = 'no publish switch'; Target = $releaseChocolateyCondition; Replacement = 'if: steps.meta.outputs.prerelease != ''true''' },
    @{ Label = 'prerelease gate dropped'; Target = $releaseChocolateyCondition; Replacement = 'if: vars.CHOCOLATEY_PUBLISH != ''off''' },
    @{ Label = 'either gate is enough'; Target = $releaseChocolateyCondition; Replacement = $releaseChocolateyCondition.Replace('&&', '||') },
    @{ Label = 'off unless set'; Target = $releaseChocolateyCondition; Replacement = $releaseChocolateyCondition.Replace('!= ''off''', '== ''on''') },
    @{ Label = 'ignored failure'; Target = $releaseChocolateyCondition; Replacement = "$releaseChocolateyCondition`n        continue-on-error: true" },
    @{ Label = 'quoted ignored failure'; Target = $releaseChocolateyCondition; Replacement = "$releaseChocolateyCondition`n        'continue-on-error': true" },
    @{ Label = 'condition with a trailing decoy'; Target = $releaseChocolateyCondition; Replacement = "if: `${{ false }} # $releaseChocolateyCondition" },
    @{ Label = 'key removed'; Target = "`n          CHOCO_API_KEY: `${{ secrets.CHOCO_API_KEY }}"; Replacement = '' }
)
foreach ($mutant in $releaseChocolateyMutants) {
    if (@([regex]::Matches($releaseChocolateyCanonical, [regex]::Escape($mutant.Target))).Count -ne 1) {
        throw "Release workflow Chocolatey mutation target is not unique: $($mutant.Label)"
    }
    $mutantText = $releaseChocolateyCanonical.Replace($mutant.Target, $mutant.Replacement)
    if (@(Test-ReleaseChocolateyStep -Text $mutantText).Count -eq 0) {
        throw "Release workflow Chocolatey step contract accepted mutant: $($mutant.Label)"
    }
}
