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
Write-Host "direct-update admission contracts: PASS (1 baseline, $($controls.Count) parse-checked refusal controls, native API boundary)"
$global:LASTEXITCODE=0
