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
        Pattern = '(?ms)Assert-WindowsBuildCapabilitiesManifest.*?Packaging arch.*?\$hostArchitecture -eq \$Architecture.*?noctty\.com.*?\+version.*?custom shaders: enabled.*?hash-bound \$Architecture build manifest'
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
        File = $releaseWorkflow
        Pattern = '(?ms)- name: Publish Chocolatey package\r?\n\s+if: steps\.meta\.outputs\.prerelease != ''true'''
        Kind = 'Workflow'
        Description = 'a prerelease never reaches the public Chocolatey feed'
    }
    @{
        File = (Join-Path $repoRoot 'scripts\release-publish-chocolatey.ps1')
        Pattern = '(?ms)Test-ChocolateyVersionPublished.*?nothing to push.*?choco push.*?\$pushExitCode -ne 0.*?already exists.*?treating the push as complete.*?throw "choco push failed'
        Kind = 'Workflow'
        Description = 'Chocolatey publishing is rerun-safe and tolerates only the duplicate-version response'
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
