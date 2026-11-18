#requires -Version 7.3
# Static admission controls for a harness that runs historical signed releases.
# No application, download, trust-store import or real-profile read occurs here.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Get-DirectUpdateProblems([string] $Text) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The acceptance harness does not parse'}
    $active=[Text.StringBuilder]::new($Text)
    foreach($token in @($tokens | Where-Object Kind -EQ 'Comment' | Sort-Object { $_.Extent.StartOffset } -Descending)){
        $null=$active.Remove($token.Extent.StartOffset,$token.Extent.EndOffset-$token.Extent.StartOffset)
    }
    $code=$active.ToString()
    $requirements=[ordered]@{
        Native='\$native -cne \$Architecture -or \$processArchitecture -cne \$Architecture'
        Legacy="\[version\]\`$FromVersion -lt \[version\]'1\.3\.136' -and -not \`$ephemeral"
        NewRun="if \(Test-Path -LiteralPath \`$Run\) \{ throw 'Run directory must be new' \}"
        NewDownload="if \(Test-Path -LiteralPath \`$destination\) \{ throw 'Download destination already exists' \}"
        PublishedHash='(?s)if \(\(Get-Sha \$zip\) -cne \$published -or \$zipAsset\[0\]\.digest -cne "sha256:\$published"\) \{ throw.*?\[IO\.Compression\.ZipFile\]::ExtractToDirectory'
        DriverDesktop='\[HiddenWin\]::CurrentDesktopName\(\) -cne \$DesktopName'
        Profile='if\(-not \$isolated\)\{throw'
        DefaultOracle='if \(\$escaped\.Count -ne 0\) \{ throw'
        StubHash='\$result\.FinalStub\.Sha256 -cne \$result\.TargetStub\.Sha256'
        Rollback="\`$state.Phase -ceq 'rollback'\) \{ throw"
        CryptographicSignature='Assert-ReleaseSignature -Path \$Path -Label .Portable stub. -AllowedPins \$pins -TrustSelfSigned \$true'
        StubLoad='if \(\$errorCode -ne 1114\) \{ throw'
        FinalExit='if\(-not \[HiddenWin\]::GetExitCodeProcess\(\$finalHandle,\[ref\]\$finalCode\) -or \$finalCode -ne 0\)\{throw'
        MesaOptIn='(?m)^\s*\[switch\] \$HostedMesa,'
        MesaScope="if\(\`$HostedMesa -and \(-not \`$ephemeral -or \`$FromVersion -cne '1\.3\.125' -or \`$TargetVersion -cne '1\.3\.137' -or \`$Expected -cne 'Stub'\)\)\{throw"
        MesaNewDownload="if\(Test-Path -LiteralPath \`$destination\)\{throw 'Mesa download directory must be new'\}"
        MesaX64Pin="x64='11dc079e356f33ce2ff84aa399c975da1a7bdd4c470f6eef4cf359ad8b9ca80f'"
        MesaArm64Pin="arm64='067f3aca687fbf5afc8a1f41487bd051487d964d6c1686757a4d8ee6a2d3b901'"
        MesaHashBeforeExtraction='(?s)if\(\(Get-Sha \$archive\) -cne \$pins\[\$Architecture\]\)\{throw.*?& \$seven e \$archive .opengl32\.dll.'
        MesaSingleFile='if\(\$after\.Count -ne \$before\.Count\+1 -or \$changes\.Count -ne 1 -or \$changes\[0\]\.SideIndicator -cne .=>. -or \$changes\[0\]\.InputObject -cnotmatch .\^opengl32'
        MesaBacking='\$modules\.Count -ne 1 -or \$modules\[0\]\.FileName -ine \(Join-Path \$script:install .opengl32\.dll.\) -or \(Get-Sha \$modules\[0\]\.FileName\) -cne \$result\.Mesa\.DllSha256'
        MesaPreserved='if\(\(Get-Sha \(Join-Path \$script:install .opengl32\.dll.\)\) -cne \$result\.Mesa\.DllSha256\)\{throw'
        LegacyDispatch="\`$legacyPainted=\`$FromVersion -ceq '1\.3\.125'"
    }
    $problems=[Collections.Generic.List[string]]::new()
    foreach($entry in $requirements.GetEnumerator()){if($code -cnotmatch $entry.Value){$problems.Add($entry.Key)}}
    if($code -match '(?i)\b(?:Start-Process|Invoke-Item|Set-Clipboard|Get-Clipboard|Import-Certificate|Set-AuthenticodeSignature)\b|--clobber|gh\s+release\s+(?:create|edit|upload)|Remove-Item'){ $problems.Add('ForbiddenOperation') }
    return @($problems.ToArray())
}
$source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'direct-update-acceptance.ps1') -Raw
$issues=@(Get-DirectUpdateProblems $source)
if($issues.Count){throw "Direct update admission failed: $($issues -join ', ')"}
$controls=[ordered]@{
    Native=@('$native -cne $Architecture -or $processArchitecture -cne $Architecture','$false')
    Legacy=@("[version]`$FromVersion -lt [version]'1.3.136' -and -not `$ephemeral",'$false')
    NewRun=@("if (Test-Path -LiteralPath `$Run) { throw 'Run directory must be new' }","# if (Test-Path -LiteralPath `$Run) { throw 'Run directory must be new' }")
    NewDownload=@("if (Test-Path -LiteralPath `$destination) { throw 'Download destination already exists' }",'')
    PublishedHash=@('(Get-Sha $zip) -cne $published -or $zipAsset[0].digest -cne "sha256:$published"','$false')
    DriverDesktop=@('[HiddenWin]::CurrentDesktopName() -cne $DesktopName','$false')
    Profile=@('if(-not $isolated){throw','if($false){throw')
    DefaultOracle=@('if ($escaped.Count -ne 0) { throw','if ($false) { throw')
    StubHash=@('$result.FinalStub.Sha256 -cne $result.TargetStub.Sha256','$false')
    Rollback=@("`$state.Phase -ceq 'rollback') { throw","`$state.Phase -ceq 'ignored') { throw")
    CryptographicSignature=@('Assert-ReleaseSignature -Path $Path -Label ''Portable stub'' -AllowedPins $pins -TrustSelfSigned $true','Get-AuthenticodeSignature -LiteralPath $Path')
    StubLoad=@('if ($errorCode -ne 1114) { throw','if ($false) { throw')
    FinalExit=@('if(-not [HiddenWin]::GetExitCodeProcess($finalHandle,[ref]$finalCode) -or $finalCode -ne 0){throw','if($false){throw')
    MesaOptIn=@('[switch] $HostedMesa,','[switch] $HostedMesa = $true,')
    MesaScope=@("if(`$HostedMesa -and (-not `$ephemeral -or `$FromVersion -cne '1.3.125' -or `$TargetVersion -cne '1.3.137' -or `$Expected -cne 'Stub')){throw",'if($false){throw')
    MesaNewDownload=@("if(Test-Path -LiteralPath `$destination){throw 'Mesa download directory must be new'}",'')
    MesaX64Pin=@("x64='11dc079e356f33ce2ff84aa399c975da1a7bdd4c470f6eef4cf359ad8b9ca80f'","x64='unverified'")
    MesaArm64Pin=@("arm64='067f3aca687fbf5afc8a1f41487bd051487d964d6c1686757a4d8ee6a2d3b901'","arm64='unverified'")
    MesaHashBeforeExtraction=@('(Get-Sha $archive) -cne $pins[$Architecture]','$false')
    MesaSingleFile=@('$after.Count -ne $before.Count+1 -or $changes.Count -ne 1 -or $changes[0].SideIndicator -cne ''=>'' -or $changes[0].InputObject -cnotmatch ''^opengl32\.dll:''','$false')
    MesaBacking=@('$modules.Count -ne 1 -or $modules[0].FileName -ine (Join-Path $script:install ''opengl32.dll'') -or (Get-Sha $modules[0].FileName) -cne $result.Mesa.DllSha256','$false')
    MesaPreserved=@('(Get-Sha (Join-Path $script:install ''opengl32.dll'')) -cne $result.Mesa.DllSha256','$false')
    LegacyDispatch=@("`$legacyPainted=`$FromVersion -ceq '1.3.125'",'$legacyPainted=$true')
}
foreach($control in $controls.GetEnumerator()){
    $anchor=$control.Value[0]
    if(([regex]::Matches($source,[regex]::Escape($anchor))).Count -ne 1){throw "Control anchor is not unique: $($control.Key)"}
    $mutant=$source.Replace($anchor,$control.Value[1])
    $failures=@(Get-DirectUpdateProblems $mutant)
    if($failures -cnotcontains $control.Key){throw "Control did not fail its own admission check: $($control.Key)"}
}
$native=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'direct-update-ui.cs') -Raw
if($native -match '\b(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|OpenClipboard|GetClipboardData|SetClipboardData)\s*\('){throw 'UI seam contains a forbidden real-input or clipboard operation'}
if($native -cnotmatch 'ClassName\(host\) != "noctty.win32.host"' -or $native -cnotmatch 'ClassName\(pane\) != "noctty.win32"' -or $native -cnotmatch 'PostMessageW\(host, 0x0201' -or $native -cnotmatch 'PostMessageW\(host, 0x0202' -or $native -cmatch 'PostMessageW\(pane, 0x020[12]'){throw 'Legacy Install must post only to its owned host'}
Write-Host "direct-update admission contracts: PASS (1 baseline, $($controls.Count) parse-checked refusal controls, native API boundary)"
$global:LASTEXITCODE=0
