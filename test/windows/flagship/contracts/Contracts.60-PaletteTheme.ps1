$paletteThemeTokens = $null
$paletteThemeErrors = $null
$paletteThemeAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $paletteThemeHarnessText,
    [ref]$paletteThemeTokens,
    [ref]$paletteThemeErrors
)
if ($paletteThemeErrors.Count -ne 0) {
    throw "Palette theme harness does not parse: $($paletteThemeErrors[0].Message)"
}

$paletteThemeHelperNames = @(
    'Open-ThemeQuery',
    'Write-SuppressedPreviewDiagnostic',
    'Test-ThemePaletteDismissed',
    'Invoke-PostHighContrastPresentationCanary'
)
$paletteThemeFunctions = @(
    $paletteThemeAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in $paletteThemeHelperNames
    }, $true)
)
# Exact-one per name is a genuine ownership invariant: the targeted and full
# paths must execute the same helper implementation.
foreach ($helperName in $paletteThemeHelperNames) {
    $definitions = @($paletteThemeFunctions | Where-Object { $_.Name -eq $helperName })
    if ($definitions.Count -ne 1 -or
        -not [object]::ReferenceEquals($definitions[0].Parent, $paletteThemeAst.EndBlock)) {
        throw "Palette theme harness must own one top-level $helperName helper."
    }
    Assert-NoUnreachableStatements `
        -Ast $definitions[0].Body `
        -Context $helperName
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

$script:paletteOpenLog = [Collections.Generic.List[string]]::new()
$script:paletteOpenPostedCalls = 0
$script:paletteOpenWaitCalls = 0
$script:paletteOpenChildrenCalls = 0
$script:paletteOpenEditCalls = 0
function script:Invoke-StatefulPostedCommand {
    param([IntPtr] $HostHwnd, [int] $Id, [DateTime] $Deadline, $Process)
    $script:paletteOpenPostedCalls++
    $script:paletteOpenLog.Add("post:$($HostHwnd.ToInt64()):$Id")
}
function script:Get-StatefulChildren {
    param([IntPtr] $HostHwnd)
    $script:paletteOpenChildrenCalls++
    $script:paletteOpenLog.Add("children:$($HostHwnd.ToInt64())")
    [pscustomobject]@{ Id = 2002; Hwnd = [IntPtr]202 }
}
function script:Wait-InteractiveWin11Until {
    param(
        [DateTime] $Deadline,
        [string] $Description,
        $Process,
        [scriptblock] $Condition
    )
    $script:paletteOpenWaitCalls++
    $script:paletteOpenLog.Add("wait:$Description")
    if (-not (& $Condition)) {
        throw 'Palette open condition mock did not observe the query edit.'
    }
}
function script:Set-StatefulEditText {
    param(
        [IntPtr] $HostHwnd,
        [IntPtr] $Hwnd,
        [string] $Text,
        [DateTime] $Deadline,
        $Process
    )
    $script:paletteOpenEditCalls++
    $script:paletteOpenLog.Add("edit:$($HostHwnd.ToInt64()):$($Hwnd.ToInt64()):$Text")
}
try {
    $openResult = Open-ThemeQuery `
        -HostHwnd ([IntPtr]101) `
        -Query 'Dracula' `
        -Deadline ([DateTime]::UtcNow.AddSeconds(1)) `
        -Process ([pscustomobject]@{ Id = 7 })
    $expectedOpenLog = @(
        'post:101:1901',
        'wait:palette query edit',
        'children:101',
        'children:101',
        'edit:101:202:Dracula'
    )
    if ($openResult -ne [IntPtr]202 -or
        ($script:paletteOpenLog -join '|') -ne ($expectedOpenLog -join '|') -or
        $script:paletteOpenPostedCalls -ne 1 -or
        $script:paletteOpenWaitCalls -ne 1 -or
        $script:paletteOpenChildrenCalls -ne 2 -or
        $script:paletteOpenEditCalls -ne 1) {
        throw 'Palette query helper did not post, wait, resolve, edit, and return the observable edit HWND.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Invoke-StatefulPostedCommand -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-StatefulChildren -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Wait-InteractiveWin11Until -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Set-StatefulEditText -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name PaletteThemeHost, paletteOpenLog, paletteOpenPostedCalls, paletteOpenWaitCalls, paletteOpenChildrenCalls, paletteOpenEditCalls -ErrorAction SilentlyContinue
}

$script:paletteDismissChildrenCalls = 0
$script:paletteDismissChildren = @()
function script:Get-StatefulChildren {
    param([IntPtr] $HostHwnd)
    $script:paletteDismissChildrenCalls++
    $script:paletteDismissChildren
}
try {
    $script:paletteDismissChildren = @(
        [pscustomobject]@{ Id = 1999 },
        [pscustomobject]@{ Id = 2007 }
    )
    $dismissed = Test-ThemePaletteDismissed -HostHwnd ([IntPtr]303)
    $script:paletteDismissChildren = @([pscustomobject]@{ Id = 2004 })
    $stillVisible = Test-ThemePaletteDismissed -HostHwnd ([IntPtr]303)
    if (-not $dismissed -or $stillVisible -or $script:paletteDismissChildrenCalls -ne 2) {
        throw 'Palette dismissal predicate did not distinguish absent and live palette controls.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-StatefulChildren -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name paletteDismissChildrenCalls, paletteDismissChildren -ErrorAction SilentlyContinue
}

$suppressedDiagnostic = @(
    Write-SuppressedPreviewDiagnostic `
        -BaselinePixel 0x123456 `
        -Preview ([pscustomobject]@{ Pixel = 0xabcdef; TransitionCount = 3 }) 6>&1
)
if ($suppressedDiagnostic.Count -ne 1 -or
    [string]$suppressedDiagnostic[0] -ne
        'High Contrast preview framebuffer: baseline=123456, settled-or-last=abcdef, transitions=3') {
    throw 'Palette suppressed-preview diagnostic format changed at its observable output boundary.'
}

$paletteOriginalLayout = Get-Variable -Name layout -ValueOnly -ErrorAction SilentlyContinue
$paletteOriginalExe = Get-Variable -Name exe -ValueOnly -ErrorAction SilentlyContinue
$paletteOriginalTimeout = Get-Variable -Name TimeoutSeconds -ValueOnly -ErrorAction SilentlyContinue
$paletteOriginalRuns = Get-Variable -Name runs -ValueOnly -ErrorAction SilentlyContinue
$layout = [pscustomobject]@{ SandboxId = 'contract' }
$exe = 'contract-noctty.exe'
$TimeoutSeconds = 3
$runs = [Collections.Generic.List[object]]::new()
$script:paletteCanaryMode = 'retry-then-pass'
$script:paletteCanaryAttempt = 0
$script:paletteCanaryStartCalls = 0
$script:paletteCanaryHostCalls = 0
$script:paletteCanaryWaitCalls = 0
$script:paletteCanarySurfaceCalls = 0
$script:paletteCanaryShowCalls = 0
$script:paletteCanaryCloseCalls = 0
$script:paletteCanaryStopCalls = 0
$script:paletteCanaryWarningCalls = 0
$script:paletteCanaryPixelCalls = 0
$script:paletteCanaryPixelSample = 0
$script:paletteCanaryLog = [Collections.Generic.List[string]]::new()

function script:Start-StatefulApp {
    param($Layout, [string] $Exe, [string] $RepoRoot, [string] $Name)
    $script:paletteCanaryAttempt++
    $script:paletteCanaryStartCalls++
    $script:paletteCanaryLog.Add("start:$($script:paletteCanaryAttempt):$Name")
    [pscustomobject]@{
        Attempt = $script:paletteCanaryAttempt
        Process = [pscustomobject]@{ HasExited = $false; Id = $script:paletteCanaryAttempt }
    }
}
function script:Wait-StatefulHost {
    param($Run, [DateTime] $Deadline)
    $script:paletteCanaryHostCalls++
    $script:paletteCanaryLog.Add("host:$($Run.Attempt)")
    if ($script:paletteCanaryMode -eq 'retry-then-pass' -and $Run.Attempt -eq 1) {
        throw 'simulated first canary stall'
    }
    [IntPtr](400 + $Run.Attempt)
}
function script:Wait-InteractiveWin11Until {
    param(
        [DateTime] $Deadline,
        [string] $Description,
        $Process,
        [scriptblock] $Condition
    )
    $script:paletteCanaryWaitCalls++
    $script:paletteCanaryLog.Add("wait:$($Process.Id):$Description")
    if ($Description -eq 'post-High-Contrast canary tab') {
        if (-not (& $Condition)) {
            throw 'Post-High-Contrast tab condition rejected the controlled tab fixture.'
        }
        return
    }
    if ($Description -ne 'post-High-Contrast canary framebuffer') {
        throw "Unexpected post-High-Contrast canary wait: $Description"
    }
    $script:paletteCanaryPixelSample = 0
    if (& $Condition) {
        throw 'Post-High-Contrast framebuffer accepted the initial wrong RGB sample.'
    }
    if ($script:paletteCanaryMode -eq 'wrong-rgb') {
        if (& $Condition) {
            throw 'Post-High-Contrast framebuffer accepted a repeated wrong RGB sample.'
        }
        throw 'simulated framebuffer timeout on wrong RGB'
    }
    if (& $Condition) {
        throw 'Post-High-Contrast framebuffer skipped the two-second stability window.'
    }
    [Threading.Thread]::Sleep(2100)
    if (-not (& $Condition)) {
        throw 'Post-High-Contrast framebuffer did not accept a stable expected RGB after two seconds.'
    }
}
function script:Get-StatefulTabCount {
    param([IntPtr] $HostHwnd)
    1
}
function script:Get-StatefulPixel {
    param([IntPtr] $Hwnd)
    $script:paletteCanaryPixelCalls++
    $script:paletteCanaryPixelSample++
    if ($script:paletteCanaryMode -eq 'wrong-rgb' -or
        $script:paletteCanaryPixelSample -eq 1) {
        return 0x654321
    }
    0x123456
}
function script:Wait-StatefulSurface {
    param([IntPtr] $HostHwnd, $Run, [DateTime] $Deadline)
    $script:paletteCanarySurfaceCalls++
    $script:paletteCanaryLog.Add("surface:$($Run.Attempt)")
    [pscustomobject]@{ Hwnd = [IntPtr](500 + $Run.Attempt) }
}
function script:Show-StatefulHost {
    param([IntPtr] $HostHwnd)
    $script:paletteCanaryShowCalls++
    $script:paletteCanaryLog.Add("show:$($HostHwnd.ToInt64())")
}
function script:Close-StatefulHost {
    param([IntPtr] $HostHwnd, $Run, [DateTime] $Deadline)
    $script:paletteCanaryCloseCalls++
    $script:paletteCanaryLog.Add("close:$($Run.Attempt)")
    if ($script:paletteCanaryMode -eq 'close-fails-after-proof') {
        throw 'simulated graceful close failure'
    }
}
function script:Stop-InteractiveWin11Process {
    param($Process, [switch] $Contained)
    $script:paletteCanaryStopCalls++
    $script:paletteCanaryLog.Add("stop:$($Process.Id):$($Contained.IsPresent)")
}
function script:Write-Warning {
    param([string] $Message)
    $script:paletteCanaryWarningCalls++
    $script:paletteCanaryLog.Add("warning:$Message")
}

try {
    Invoke-PostHighContrastPresentationCanary `
        -Name 'contract-canary' `
        -ExpectedRgb 0x123456
    $retryLog = @($script:paletteCanaryLog)
    $retryOrder = @(
        'start:1:contract-canary-1',
        'host:1',
        'stop:1:True',
        'start:2:contract-canary-2',
        'host:2',
        'wait:2:post-High-Contrast canary tab',
        'surface:2',
        'show:402',
        'wait:2:post-High-Contrast canary framebuffer',
        'close:2'
    )
    $cursor = -1
    foreach ($expectedEvent in $retryOrder) {
        $next = [Array]::IndexOf($retryLog, $expectedEvent, $cursor + 1)
        if ($next -lt 0) {
            throw "Post-High-Contrast retry behavior missed '$expectedEvent': $($retryLog -join ', ')"
        }
        $cursor = $next
    }
    if ($script:paletteCanaryStartCalls -ne 2 -or
        $script:paletteCanaryHostCalls -ne 2 -or
        $script:paletteCanaryWaitCalls -ne 2 -or
        $script:paletteCanarySurfaceCalls -ne 1 -or
        $script:paletteCanaryShowCalls -ne 1 -or
        $script:paletteCanaryCloseCalls -ne 1 -or
        $script:paletteCanaryStopCalls -ne 1 -or
        $script:paletteCanaryWarningCalls -ne 1) {
        throw 'Post-High-Contrast canary retry probes were not all invoked with the expected lifecycle counts.'
    }

    $script:paletteCanaryMode = 'wrong-rgb'
    $script:paletteCanaryAttempt = 0
    $wrongRgbStartBefore = $script:paletteCanaryStartCalls
    $wrongRgbStopBefore = $script:paletteCanaryStopCalls
    $wrongRgbFailure = ''
    try {
        Invoke-PostHighContrastPresentationCanary `
            -Name 'contract-wrong-rgb' `
            -ExpectedRgb 0x123456
    }
    catch {
        $wrongRgbFailure = $_.Exception.Message
    }
    if ($wrongRgbFailure -notlike
            'Post-High-Contrast presentation did not recover after two fresh processes:*wrong RGB*' -or
        ($script:paletteCanaryStartCalls - $wrongRgbStartBefore) -ne 2 -or
        ($script:paletteCanaryStopCalls - $wrongRgbStopBefore) -ne 2) {
        throw 'Post-High-Contrast canary must reject a wrong RGB on both bounded fresh-process attempts.'
    }

    $script:paletteCanaryMode = 'close-fails-after-proof'
    $script:paletteCanaryAttempt = 0
    $startBeforeCloseFailure = $script:paletteCanaryStartCalls
    $stopBeforeCloseFailure = $script:paletteCanaryStopCalls
    $closeBeforeCloseFailure = $script:paletteCanaryCloseCalls
    Invoke-PostHighContrastPresentationCanary `
        -Name 'contract-proven-canary' `
        -ExpectedRgb 0x123456
    if (($script:paletteCanaryStartCalls - $startBeforeCloseFailure) -ne 1 -or
        ($script:paletteCanaryStopCalls - $stopBeforeCloseFailure) -ne 1 -or
        ($script:paletteCanaryCloseCalls - $closeBeforeCloseFailure) -ne 1) {
        throw 'Post-High-Contrast canary did not preserve proven presentation while containing a graceful-close failure.'
    }
}
finally {
    foreach ($name in @(
        'Start-StatefulApp',
        'Wait-StatefulHost',
        'Wait-InteractiveWin11Until',
        'Get-StatefulTabCount',
        'Get-StatefulPixel',
        'Wait-StatefulSurface',
        'Show-StatefulHost',
        'Close-StatefulHost',
        'Stop-InteractiveWin11Process',
        'Write-Warning',
        'Open-ThemeQuery',
        'Write-SuppressedPreviewDiagnostic',
        'Test-ThemePaletteDismissed',
        'Invoke-PostHighContrastPresentationCanary'
    )) {
        Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Scope Script -Name paletteCanaryMode, paletteCanaryAttempt, paletteCanaryStartCalls, paletteCanaryHostCalls, paletteCanaryWaitCalls, paletteCanarySurfaceCalls, paletteCanaryShowCalls, paletteCanaryCloseCalls, paletteCanaryStopCalls, paletteCanaryWarningCalls, paletteCanaryPixelCalls, paletteCanaryPixelSample, paletteCanaryLog -ErrorAction SilentlyContinue
    $layout = $paletteOriginalLayout
    $exe = $paletteOriginalExe
    $TimeoutSeconds = $paletteOriginalTimeout
    $runs = $paletteOriginalRuns
}

$paletteMainTries = @($paletteThemeAst.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.TryStatementAst] -and
        $null -ne $_.Finally
})
if ($paletteMainTries.Count -ne 1) {
    throw 'Palette theme harness must own one top-level fail-closed cleanup try/finally.'
}
$paletteMainTry = $paletteMainTries[0]
$presentationReadyAssignments = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        (Get-VariableExpressionName -Node $node.Left) -eq 'hcPresentationReady'
}, $true))
$presentationReadyFalse = @($presentationReadyAssignments | Where-Object {
    $_.Right.Extent.Text.Trim() -ceq '$false'
})
$presentationReadyTrue = @($presentationReadyAssignments | Where-Object {
    $_.Right.Extent.Text.Trim() -ceq '$true'
})
$presentationReadyMutationCommands = @($paletteThemeAst.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
        $node.Extent.Text -notmatch '(?i)hcPresentationReady') {
        return $false
    }
    $name = $node.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    return (($name -split '\\')[-1]) -match
        '^(?i)(?:(?:Set|New|Remove|Clear)-Variable|sv|nv|rv|clv)$'
}, $true))
$hcRestoredIfs = @($paletteMainTry.Finally.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Clauses.Count -eq 1 -and
        $_.Clauses[0].Item1.Extent.Text.Trim() -ceq '$hcRestored'
})
$hcPresentationReadyIfs = @($paletteMainTry.Finally.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Clauses.Count -eq 1 -and
        $_.Clauses[0].Item1.Extent.Text.Trim() -ceq '$hcPresentationReady'
})
$restoreCanaryCalls = @(Get-NamedCommands `
    -Ast $paletteMainTry.Finally `
    -Name 'Invoke-PostHighContrastPresentationCanary' |
    Where-Object {
        Test-CommandHasStringArgument `
            -Command $_ `
            -Value 'palette-theme-restore-canary'
    })
$restoreProofTry = if ($presentationReadyTrue.Count -eq 1) {
    $ancestor = $presentationReadyTrue[0].Parent
    while ($null -ne $ancestor -and
        $ancestor -isnot [System.Management.Automation.Language.TryStatementAst]) {
        $ancestor = $ancestor.Parent
    }
    $ancestor
} else {
    $null
}
$restoreProofStatements = if ($null -ne $restoreProofTry) {
    @($restoreProofTry.Body.Statements)
} else {
    @()
}
$restoreCanaryStatement = if ($restoreCanaryCalls.Count -eq 1 -and
    $null -ne $restoreProofTry) {
    Get-DirectStatementBlockChild `
        -Node $restoreCanaryCalls[0] `
        -StatementBlock $restoreProofTry.Body
} else {
    $null
}
$restoreCanaryIndex = [Array]::IndexOf(
    $restoreProofStatements,
    $restoreCanaryStatement
)
$presentationReadyIndex = if ($presentationReadyTrue.Count -eq 1) {
    [Array]::IndexOf($restoreProofStatements, $presentationReadyTrue[0])
} else {
    -1
}
$markerRemoveCommands = @(Get-NamedCommands `
    -Ast $paletteThemeAst `
    -Name 'Remove-Item' |
    Where-Object {
        $pathArgument = Get-CommandParameterArgument `
            -Command $_ `
            -Name 'LiteralPath'
        (Get-VariableExpressionName -Node $pathArgument) -eq 'hcRecoveryPath'
    })
$presentationMarkerRemovals = if ($hcPresentationReadyIfs.Count -eq 1) {
    @(Get-NamedCommands `
        -Ast $hcPresentationReadyIfs[0].Clauses[0].Item2 `
        -Name 'Remove-Item' |
        Where-Object {
            $pathArgument = Get-CommandParameterArgument `
                -Command $_ `
                -Name 'LiteralPath'
            (Get-VariableExpressionName -Node $pathArgument) -eq 'hcRecoveryPath'
        })
} else {
    @()
}
if ($presentationReadyAssignments.Count -ne 2 -or
    $presentationReadyFalse.Count -ne 1 -or
    $presentationReadyTrue.Count -ne 1 -or
    $presentationReadyMutationCommands.Count -ne 0 -or
    $hcRestoredIfs.Count -ne 1 -or
    $hcPresentationReadyIfs.Count -ne 1 -or
    $restoreCanaryCalls.Count -ne 1 -or
    $null -eq $restoreProofTry -or
    $restoreCanaryIndex -lt 0 -or
    $presentationReadyIndex -ne ($restoreCanaryIndex + 1) -or
    $markerRemoveCommands.Count -ne 2 -or
    $presentationMarkerRemovals.Count -ne 1) {
    throw 'High Contrast recovery-marker cleanup must be gated exclusively by a direct successful presentation proof, without variable-command alias indirection.'
}

$recoveryCanaryCalls = @(Get-NamedCommands `
    -Ast $paletteMainTry.Body `
    -Name 'Invoke-PostHighContrastPresentationCanary' |
    Where-Object {
        Test-CommandHasStringArgument `
            -Command $_ `
            -Value 'palette-theme-recovery-canary'
    })
$recoveryMarkerRemovals = @($markerRemoveCommands | Where-Object {
    $presentationMarkerRemovals -notcontains $_
})
$recoveryBlock = if ($recoveryCanaryCalls.Count -eq 1) {
    Get-ContainingStatementBlock -Node $recoveryCanaryCalls[0]
} else {
    $null
}
$recoveryStatements = if ($null -ne $recoveryBlock) {
    @($recoveryBlock.Statements)
} else {
    @()
}
$recoveryCanaryStatement = if ($null -ne $recoveryBlock -and
    $recoveryCanaryCalls.Count -eq 1) {
    Get-DirectStatementBlockChild `
        -Node $recoveryCanaryCalls[0] `
        -StatementBlock $recoveryBlock
} else {
    $null
}
$recoveryRemoveStatement = if ($null -ne $recoveryBlock -and
    $recoveryMarkerRemovals.Count -eq 1) {
    Get-DirectStatementBlockChild `
        -Node $recoveryMarkerRemovals[0] `
        -StatementBlock $recoveryBlock
} else {
    $null
}
if ($recoveryCanaryCalls.Count -ne 1 -or
    $recoveryMarkerRemovals.Count -ne 1 -or
    [Array]::IndexOf($recoveryStatements, $recoveryRemoveStatement) -ne
        ([Array]::IndexOf($recoveryStatements, $recoveryCanaryStatement) + 1)) {
    throw 'Interrupted High Contrast recovery must retain its marker until the fresh-process presentation canary succeeds.'
}

if ($paletteThemeHarnessText -notmatch
        [regex]::Escape('SystemParametersInfo(0x42, $activeHc.cbSize, [ref]$activeHc, 0)') -or
    $paletteThemeHarnessText -notmatch
        [regex]::Escape('($activeHc.dwFlags -band 1) -eq 0')) {
    throw 'Suppressed theme preview must verify OS-level High Contrast with SPI_GETHIGHCONTRAST and the active dwFlags bit.'
}
if ($paletteThemeHarnessText -notmatch
        '(?s)Invoke-StatefulButton \$hostHwnd 2004 \$deadline \$run\.Process.*?-Description ''theme palette dismissal after preview''.*?Test-ThemePaletteDismissed \$hostHwnd.*?-Description ''Dracula preview rollback''.*?Dismissal changed persisted theme instead of reverting preview') {
    throw 'Theme preview dismissal must click the real close control, disappear, restore the Dracula framebuffer, and retain the persisted theme.'
}

$paletteOpenCalls = @(
    Get-NamedCommands `
        -Ast $paletteThemeAst.EndBlock `
        -Name 'Open-ThemeQuery'
)
# Three opens are the scenario matrix: preview, commit, and High Contrast.
if ($paletteOpenCalls.Count -ne 3 -or
    @($paletteOpenCalls | Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value '0x96f'
        }).Count -ne 2 -or
    @($paletteOpenCalls | Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value 'Dracula'
        }).Count -ne 1) {
    throw 'Palette theme story must retain two 0x96f paths and one High Contrast Dracula path.'
}

$paletteThemeDiagnostics = @(
    $paletteThemeAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true) | ForEach-Object { $_.Value }
)
$requiredPaletteDiagnostics = @(
    'theme palette dismissal after preview',
    'theme config persistence',
    'stable High Contrast framebuffer',
    'suppressed High Contrast theme preview',
    'High Contrast palette dismissal'
)
if (@($requiredPaletteDiagnostics | Where-Object {
            $paletteThemeDiagnostics -notcontains $_
        }).Count -ne 0) {
    throw 'Palette theme story is missing an observable scenario diagnostic.'
}
