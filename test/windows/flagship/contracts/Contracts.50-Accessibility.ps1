$accessibilityTokens = $null
$accessibilityErrors = $null
$accessibilityAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $accessibilityHarnessText,
    [ref]$accessibilityTokens,
    [ref]$accessibilityErrors
)
$accessibilityHarnessAst = $accessibilityAst
$accessibilityUIntPtrConversions = @($accessibilityAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ConvertExpressionAst] -and
        $node.Type.TypeName.FullName -eq 'UIntPtr'
}, $true))
if ($accessibilityErrors.Count -ne 0 -or $accessibilityUIntPtrConversions.Count -ne 0) {
    throw 'Accessibility harness must parse and construct nonzero WPARAM values through UIntPtr::new([uint64] ...).'
}
$textRangeEndpointReferences = @($accessibilityHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $node.Static -and
        (Get-MemberExpressionName -Node $node) -in @('Start', 'End') -and
        $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $node.Expression.TypeName.FullName -eq
            'System.Windows.Automation.Text.TextPatternRangeEndpoint'
}, $true))
$wrongTextRangeEndpointReferences = @($accessibilityHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $node.Static -and
        (Get-MemberExpressionName -Node $node) -in @('Start', 'End') -and
        $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $node.Expression.TypeName.Name -eq 'TextPatternRangeEndpoint' -and
        $node.Expression.TypeName.FullName -ne
            'System.Windows.Automation.Text.TextPatternRangeEndpoint'
}, $true))
if ($textRangeEndpointReferences.Count -lt 1 -or
    $wrongTextRangeEndpointReferences.Count -ne 0) {
    throw 'Accessibility caret assertions must use the installed UIAutomation Text.TextPatternRangeEndpoint type.'
}
$unicodeKeyDownAdds = [regex]::Matches(
    $accessibilityHarnessText,
    'inputs\.Add\(Key\(0, value, KEYEVENTF_UNICODE\)\);'
)
$accessibilityHarnessAst = $accessibilityAst
$unicodeKeyUpAdds = [regex]::Matches(
    $accessibilityHarnessText,
    'inputs\.Add\(Key\(0, value, KEYEVENTF_UNICODE \| KEYEVENTF_KEYUP\)\);'
)
if ($accessibilityHarnessText -match 'VkKeyScanW|SendAsciiText' -or
    $accessibilityHarnessText -notmatch 'private const uint KEYEVENTF_UNICODE = 0x0004;' -or
    $unicodeKeyDownAdds.Count -lt 1 -or
    $unicodeKeyUpAdds.Count -lt 1) {
    throw 'Accessibility text injection must use layout-independent KEYEVENTF_UNICODE key down/up pairs.'
}
# Exact helper/call ownership is the invariant: both targeted and full paths must
# exercise one shared High Contrast proof implementation.

$highContrastFunctions = @(
    Get-NamedFunctionDefinitions `
        -Ast $accessibilityHarnessAst `
        -Name 'Invoke-AccessibilityHighContrastProof'
)
$highContrastCalls = @(
    Get-NamedCommands `
        -Ast $accessibilityHarnessAst `
        -Name 'Invoke-AccessibilityHighContrastProof'
)
if ($highContrastFunctions.Count -ne 1 -or $highContrastCalls.Count -ne 2) {
    throw 'Targeted and full accessibility evidence must share one High Contrast proof helper.'
}
# The internal restoration-budget local and diagnostic field are deliberately not
# pinned. The harness's bounded deadline and executed reset diagnostic enforce the
# observable convergence/fail-closed contract without freezing local names.

Assert-NoUnreachableStatements `
    -Ast $highContrastFunctions[0].Body `
    -Context 'Invoke-AccessibilityHighContrastProof'
$highContrastRecoveryTries = @($highContrastFunctions[0].Body.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.TryStatementAst] -or
        $null -eq $node.Finally) {
        return $false
    }
    $commands = @($node.Finally.FindAll({
        param($child)
        $child -is [System.Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetCommandName() })
    return $commands -contains 'Set-HighContrastState' -and
        $commands -contains 'Get-HighContrastState' -and
        $commands -contains 'Write-HighContrastRestoreDiagnostic' -and
        $commands -contains 'Wait-AccessibilityCondition'
}, $true))
if ($highContrastRecoveryTries.Count -ne 1) {
    throw 'High Contrast proof must have one fail-closed finally block that restores exact SPI state, verifies recovery boundedly, and writes diagnostics.'
}
$dwmHighContrastDiagnosticFunctions = @(
    Get-NamedFunctionDefinitions `
        -Ast $highContrastFunctions[0].Body `
        -Name 'Get-DwmHighContrastResetDiagnostic'
)
if ($dwmHighContrastDiagnosticFunctions.Count -ne 1) {
    throw 'High Contrast proof must define one pure DWM reset diagnostic.'
}
Assert-NoUnreachableStatements `
    -Ast $dwmHighContrastDiagnosticFunctions[0].Body `
    -Context 'Get-DwmHighContrastResetDiagnostic'
. ([scriptblock]::Create($dwmHighContrastDiagnosticFunctions[0].Extent.Text))
$dwmNames = @(
    'immersive_dark_20',
    'immersive_dark_19',
    'caption_color',
    'text_color',
    'backdrop_type'
)
$dwmBeforeFixture = [ordered]@{}
$dwmDuringSuccessFixture = [ordered]@{}
$dwmDuringFailureFixture = [ordered]@{}
for ($dwmIndex = 0; $dwmIndex -lt $dwmNames.Count; $dwmIndex++) {
    $dwmName = $dwmNames[$dwmIndex]
    $dwmExpected = [uint32]($dwmIndex + 10)
    $dwmBeforeFixture[$dwmName] = [pscustomobject]@{
        attribute = $dwmIndex + 19
        supported = $true
        hresult = '0x00000000'
        value = [uint32]0
        expected_high_contrast = $dwmExpected
    }
    $dwmDuringSuccessFixture[$dwmName] = [pscustomobject]@{
        attribute = $dwmIndex + 19
        supported = $true
        hresult = '0x00000000'
        value = $dwmExpected
        expected_high_contrast = $dwmExpected
    }
    $dwmDuringFailureFixture[$dwmName] = [pscustomobject]@{
        attribute = $dwmIndex + 19
        supported = $true
        hresult = '0x00000000'
        value = if ($dwmName -eq 'caption_color') {
            [uint32]($dwmExpected + 1)
        } else {
            $dwmExpected
        }
        expected_high_contrast = $dwmExpected
    }
}
$dwmSuccessOutputs = @(
    Get-DwmHighContrastResetDiagnostic `
        -Before $dwmBeforeFixture `
        -During $dwmDuringSuccessFixture
)
$dwmFailureOutputs = @(
    Get-DwmHighContrastResetDiagnostic `
        -Before $dwmBeforeFixture `
        -During $dwmDuringFailureFixture
)
if ($dwmSuccessOutputs.Count -ne 1 -or
    $dwmSuccessOutputs[0].exact -ne $true -or
    @($dwmSuccessOutputs[0].failures).Count -ne 0 -or
    $dwmFailureOutputs.Count -ne 1 -or
    $dwmFailureOutputs[0].exact -ne $false -or
    @($dwmFailureOutputs[0].failures).Count -ne 1 -or
    [string]::IsNullOrWhiteSpace([string]$dwmFailureOutputs[0].failures[0])) {
    throw 'High Contrast DWM diagnostic must emit one exact success or one shaped failure without stray output.'
}
$openSettingsLoops = @($accessibilityHarnessAst.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.DoWhileStatementAst]) {
        return $false
    }
    $settingsClassReferences = @($node.Body.FindAll({
        param($child)
        $child -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $child.Value -eq 'noctty.win32.settings'
    }, $true))
    return $settingsClassReferences.Count -gt 0 -and
        (Get-NamedMemberExpressions `
            -Ast $node.Body `
            -Name 'TopLevelWindowsForProcess' `
            -InvocationOnly).Count -ge 2 -and
        (Get-NamedMemberExpressions `
            -Ast $node.Body `
            -Name 'VisibleTerminalChildren' `
            -InvocationOnly).Count -ge 1 -and
        (Get-NamedMemberExpressions `
            -Ast $node.Body `
            -Name 'SendChord' `
            -InvocationOnly).Count -ge 1
}, $true))
if ($openSettingsLoops.Count -ne 1) {
    throw 'Settings open recovery must have one owned bounded discovery/recovery loop.'
}
$openSettingsLoop = $openSettingsLoops[0]
$openSettingsFunction = $openSettingsLoop
while ($null -ne $openSettingsFunction -and
    $openSettingsFunction -isnot
        [System.Management.Automation.Language.FunctionDefinitionAst]) {
    $openSettingsFunction = $openSettingsFunction.Parent
}
if ($null -eq $openSettingsFunction) {
    throw 'Settings open recovery loop must be owned by a function.'
}
Assert-NoUnreachableStatements `
    -Ast $openSettingsFunction.Body `
    -Context 'Settings open recovery'
$openSettingsTopLevelQueries = @(
    Get-NamedMemberExpressions -Ast $openSettingsLoop.Body -Name 'TopLevelWindowsForProcess' -InvocationOnly
)
$openSettingsIsWindowCalls = @(
    Get-NamedMemberExpressions -Ast $openSettingsLoop.Body -Name 'IsWindow' -InvocationOnly
)
$openSettingsSendChordCalls = @(
    Get-NamedMemberExpressions -Ast $openSettingsLoop.Body -Name 'SendChord' -InvocationOnly
)
$openSettingsSetFocusCalls = @(
    Get-NamedMemberExpressions -Ast $openSettingsLoop.Body -Name 'SetFocus' -InvocationOnly
)
$openSettingsReturns = @($openSettingsLoop.Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ReturnStatementAst]
}, $true))
$openSettingsRecoveryBranches = @($openSettingsLoop.Body.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.IfStatementAst]) {
        return $false
    }
    return (Get-NamedMemberExpressions -Ast $node -Name 'VisibleTerminalChildren' -InvocationOnly).Count -ge 1 -and
        (Get-NamedMemberExpressions -Ast $node -Name 'SendChord' -InvocationOnly).Count -ge 1
}, $true))
if ($openSettingsTopLevelQueries.Count -lt 2 -or
    $openSettingsIsWindowCalls.Count -lt 2 -or
    (Get-NamedMemberExpressions -Ast $openSettingsLoop.Body -Name 'FindAll' -InvocationOnly).Count -lt 1 -or
    (Get-NamedMemberExpressions -Ast $openSettingsLoop.Body -Name 'FocusedWindowFor' -InvocationOnly).Count -lt 2 -or
    $openSettingsSetFocusCalls.Count -lt 1 -or
    $openSettingsSendChordCalls.Count -lt 1 -or
    $openSettingsReturns.Count -lt 1 -or
    $openSettingsRecoveryBranches.Count -lt 1 -or
    (Get-NamedCommands -Ast $openSettingsLoop.Body -Name 'Start-Sleep').Count -lt 1) {
    throw 'Settings open recovery must use bounded discovery, stable HWND/UIA/section validation, terminal focus recovery, and a retry delay.'
}
# Statement order is not pinned: the real settings-open scenario only succeeds
# after stable discovery and terminal-focus recovery, so its returned evidence is
# the observable sequencing contract.

$forbiddenThemeApiPattern = '\b(?:DwmSetWindowAttribute|SetWindowTheme)\s*\('
$themeApiLeaks = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src\apprt') -Filter '*.zig' -File -Recurse |
        Where-Object { $_.FullName -ne $win32Theme } |
        ForEach-Object {
            if ((Get-Content -LiteralPath $_.FullName -Raw) -match $forbiddenThemeApiPattern) {
                $_.FullName
            }
        }
)
if ($themeApiLeaks.Count -ne 0) {
    throw "DWM and native-control theme APIs must remain private to win32_theme.zig: $($themeApiLeaks -join ', ')"
}
if ($win32RuntimeText -notmatch '\bwin32_theme\.WindowThemeAdapter\.applyHost\s*\(' -or
    $win32SettingsText -notmatch '\bwin32_theme\.WindowThemeAdapter\.applySettings\s*\(' -or
    $win32SettingsText -notmatch '\bwin32_theme\.WindowThemeAdapter\.applyNativeControl\s*\(') {
    throw 'Win32 host and Settings callers must use the shared WindowThemeAdapter interface.'
}
$queryOnlyMarkerCommands = @(
    Get-NamedCommands -Ast $accessibilityHarnessAst -Name 'Send-AccessibilityOutputMarker' |
        Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value 'query-only TextPattern marker'
        }
)
if ($queryOnlyMarkerCommands.Count -ne 1) {
    throw 'Accessibility query-only contract must have one marker scenario.'
}
$queryOnlyOwner = Get-ContainingStatementBlock -Node $queryOnlyMarkerCommands[0]
$queryOnlyColdCalls = @(
    Get-NamedCommands -Ast $queryOnlyOwner -Name 'Invoke-AccessibilityColdFirstReadProof' |
        Where-Object {
            [object]::ReferenceEquals((Get-ContainingStatementBlock -Node $_), $queryOnlyOwner) -and
                (Test-CommandHasStringArgument -Command $_ -Value 'cold first-read TextPattern marker')
        }
)
$queryOnlyInactiveCalls = @(
    Get-NamedCommands -Ast $queryOnlyOwner -Name 'Invoke-AccessibilityInactiveTabFirstReadProof' |
        Where-Object {
            [object]::ReferenceEquals((Get-ContainingStatementBlock -Node $_), $queryOnlyOwner)
        }
)
$queryOnlyRemoveHandlers = @($queryOnlyOwner.FindAll({
    param($node)
    Test-TextChangedHandlerOperation -Node $node -Operation 'Remove'
}, $true))
$queryOnlyAddHandlers = @($queryOnlyOwner.FindAll({
    param($node)
    Test-TextChangedHandlerOperation -Node $node -Operation 'Add'
}, $true))
$queryOnlyDocumentRanges = @(
    Get-NamedMemberExpressions -Ast $queryOnlyOwner -Name 'DocumentRange'
)
$queryOnlyTextReads = @(
    Get-NamedMemberExpressions -Ast $queryOnlyOwner -Name 'GetText' -InvocationOnly
)
if ($null -ne $queryOnlyOwner) {
    Assert-NoUnreachableStatements -Ast $queryOnlyOwner -Context 'query-only TextChanged handler ownership'
}
if ($null -eq $queryOnlyOwner -or
    $queryOnlyColdCalls.Count -ne 1 -or
    $queryOnlyInactiveCalls.Count -ne 1 -or
    $queryOnlyRemoveHandlers.Count -lt 1 -or
    $queryOnlyAddHandlers.Count -lt 1 -or
    $queryOnlyDocumentRanges.Count -lt 2 -or
    $queryOnlyTextReads.Count -lt 2) {
    throw 'Accessibility query-only evidence must own cold/inactive first-read scenarios, detach and restore TextChanged capture, and compare retained/current TextPattern ranges.'
}
# The previous offset ladder protected no independent invariant: the executed
# query-only scenario already asserts zero TextChanged events, a stale retained
# range, a refreshed current range, and successful cold/inactive first reads.

$outputMarkerFunctions = @(
    Get-NamedFunctionDefinitions -Ast $accessibilityHarnessAst -Name 'Send-AccessibilityOutputMarker'
)
if ($outputMarkerFunctions.Count -ne 1) {
    throw 'Accessibility evidence must define exactly one output-marker input helper.'
}
$outputMarkerFunction = $outputMarkerFunctions[0]
Assert-NoUnreachableStatements -Ast $outputMarkerFunction.Body -Context 'Send-AccessibilityOutputMarker'
$outputMarkerRequirements = @(
    @{ Kind = 'Command'; Name = 'New-AccessibilityTempCmdLauncher'; Minimum = 1 },
    @{ Kind = 'Command'; Name = 'Assert-AccessibilityInputOwner'; Minimum = 1 },
    @{ Kind = 'Member'; Name = 'SendUnicodeText'; Minimum = 1 },
    @{ Kind = 'Command'; Name = 'Wait-AccessibilityTerminalCommandEcho'; Minimum = 1 },
    @{ Kind = 'Member'; Name = 'GetText'; Minimum = 1 },
    @{ Kind = 'Command'; Name = 'Send-AccessibilityChord'; Minimum = 1 },
    @{ Kind = 'Command'; Name = 'Wait-AccessibilityCondition'; Minimum = 1 },
    @{ Kind = 'Member'; Name = 'Delete'; Minimum = 1 }
)
foreach ($requirement in $outputMarkerRequirements) {
    $operationMatches = if ($requirement.Kind -eq 'Command') {
        @(Get-NamedCommands -Ast $outputMarkerFunction.Body -Name $requirement.Name)
    } else {
        @(Get-NamedMemberExpressions -Ast $outputMarkerFunction.Body -Name $requirement.Name -InvocationOnly)
    }
    if ($operationMatches.Count -lt $requirement.Minimum) {
        throw "Accessibility output-marker helper must retain observable operation '$($requirement.Name)'."
    }
}
$outputMarkerOwnerAssertions = @(
    Get-NamedCommands `
        -Ast $outputMarkerFunction.Body `
        -Name 'Assert-AccessibilityInputOwner'
)
if ($outputMarkerOwnerAssertions.Count -ne 2) {
    throw 'Accessibility output-marker input ownership must be checked exactly twice around command entry and Enter dispatch.'
}

if (-not ('FlagshipAccessibilityNativeProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class FlagshipAccessibilityNativeProbe {
    public static Action<string> Recorder;
    public static bool SendShouldSucceed = true;
    public static IntPtr ForegroundHwnd = IntPtr.Zero;
    public static IntPtr FocusedHwnd = IntPtr.Zero;
    public static int LastSendInputRequested = 17;
    public static int LastSendInputReturned = 17;
    public static int NotificationCount = 1;
    public static object[] NotificationHistorySnapshot = Array.Empty<object>();
    private static void Record(string value) { Recorder?.Invoke(value); }
    public static bool SendUnicodeText(string text) {
        Record("native-send:" + text);
        return SendShouldSucceed;
    }
    public static IntPtr GetForegroundWindow() {
        Record("native-foreground");
        return ForegroundHwnd;
    }
    public static IntPtr FocusedWindowFor(IntPtr hwnd) {
        Record("native-focus:" + hwnd.ToInt64());
        return FocusedHwnd;
    }
    public static void ResetNotificationCount() { Record("native-reset-capture"); }
    public static void StartNotificationCapture(IntPtr hwnd) { Record("native-start-capture:" + hwnd.ToInt64()); }
    public static void StopNotificationCapture() { Record("native-stop-capture"); }
}
'@
}
$outputMarkerProbeSource = $outputMarkerFunction.Extent.Text.Replace(
    '[NocttyAccessibilityNative]',
    '[FlagshipAccessibilityNativeProbe]'
)
. ([scriptblock]::Create($outputMarkerProbeSource))
$script:outputMarkerOperationLog = [Collections.Generic.List[string]]::new()
$script:outputMarkerOwnerCalls = [Collections.Generic.List[object]]::new()
$script:outputMarkerLauncherPaths = [Collections.Generic.List[string]]::new()
$script:outputMarkerVisible = $false
[FlagshipAccessibilityNativeProbe]::Recorder = [Action[string]] {
    param([string] $entry)
    $script:outputMarkerOperationLog.Add($entry)
}
function New-AccessibilityTempCmdLauncher {
    param([string[]] $Lines, [string] $Description)
    $path = Join-Path ([IO.Path]::GetTempPath()) (
        'noctty-output-marker-' + [Guid]::NewGuid().ToString('N') + '.cmd'
    )
    [IO.File]::WriteAllText($path, '@echo contract launcher')
    $script:outputMarkerLauncherPaths.Add($path)
    $script:outputMarkerOperationLog.Add("launcher:$Description")
    [pscustomobject]@{
        path = $path
        command = 'call contract-output-launcher.cmd'
        command_length = 33
    }
}
function Assert-AccessibilityInputOwner {
    param($Process, [string] $Description, [IntPtr] $ExpectedFocusedHwnd)
    $script:outputMarkerOperationLog.Add("owner:$Description")
    $script:outputMarkerOwnerCalls.Add([pscustomobject]@{
        Process = $Process
        Description = $Description
        ExpectedFocusedHwnd = $ExpectedFocusedHwnd
    })
}
function Wait-AccessibilityTerminalCommandEcho {
    param(
        $Process,
        $TextPattern,
        [string] $Command,
        [string] $Description,
        [IntPtr] $ExpectedFocusedHwnd,
        $SendInputRequested,
        $SendInputReturned
    )
    $script:outputMarkerOperationLog.Add("echo:$Description")
    [pscustomobject]@{ observed = $true; command = $Command }
}
function Send-AccessibilityChord {
    param([uint16[]] $Keys, [string] $Description, $Process, [IntPtr] $ExpectedFocusedHwnd)
    $script:outputMarkerOperationLog.Add("chord:${Description}:$($Keys -join ',')")
    $script:outputMarkerVisible = $true
}
function Wait-AccessibilityCondition {
    param([DateTime] $Deadline, [string] $Description, [scriptblock] $Condition)
    $script:outputMarkerOperationLog.Add("wait:$Description")
    if (-not (& $Condition)) {
        throw "Controlled accessibility condition failed: $Description"
    }
}
$outputMarkerRange = [pscustomobject]@{}
$outputMarkerRange | Add-Member -MemberType ScriptMethod -Name GetText -Value {
    param($MaximumLength)
    $script:outputMarkerOperationLog.Add("gettext:$MaximumLength")
    if ($script:outputMarkerVisible) {
        return "prompt VALIDMARKER_01"
    }
    return 'prompt'
}
$outputMarkerTextPattern = [pscustomobject]@{
    DocumentRange = $outputMarkerRange
}
$outputMarkerProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$outputMarkerExpectedFocus = [IntPtr]77
[FlagshipAccessibilityNativeProbe]::ForegroundHwnd =
    $outputMarkerProcess.MainWindowHandle
[FlagshipAccessibilityNativeProbe]::FocusedHwnd = $outputMarkerExpectedFocus
try {
    $outputMarkerResult = Send-AccessibilityOutputMarker `
        -Process $outputMarkerProcess `
        -TextPattern $outputMarkerTextPattern `
        -Marker 'VALIDMARKER_01' `
        -Description 'contract marker' `
        -ExpectedFocusedHwnd $outputMarkerExpectedFocus
    $expectedOutputMarkerOperations = @(
        'launcher:contract marker',
        'owner:contract marker text',
        'native-send:call contract-output-launcher.cmd',
        'echo:contract marker',
        'gettext:-1',
        'native-foreground',
        "native-focus:$($outputMarkerProcess.MainWindowHandle.ToInt64())",
        'owner:contract marker pre-Enter',
        'native-foreground',
        "native-focus:$($outputMarkerProcess.MainWindowHandle.ToInt64())",
        'chord:contract marker Enter:13',
        'wait:contract marker launcher output',
        'gettext:-1'
    )
    if (($script:outputMarkerOperationLog -join '|') -cne
            ($expectedOutputMarkerOperations -join '|') -or
        $script:outputMarkerOwnerCalls.Count -ne 2 -or
        @($script:outputMarkerOwnerCalls | Where-Object {
            -not [object]::ReferenceEquals($_.Process, $outputMarkerProcess) -or
                $_.ExpectedFocusedHwnd -ne $outputMarkerExpectedFocus
        }).Count -ne 0 -or
        $outputMarkerResult.short_command -cne
            'call contract-output-launcher.cmd' -or
        -not $outputMarkerResult.marker_visible_before_launcher_cleanup -or
        [IO.File]::Exists($script:outputMarkerLauncherPaths[0])) {
        throw 'Valid output-marker behavior must preserve operation order, process/focus identity, command identity, final read, and cleanup.'
    }

    $script:outputMarkerOperationLog.Clear()
    $script:outputMarkerOwnerCalls.Clear()
    $script:outputMarkerVisible = $false
    [FlagshipAccessibilityNativeProbe]::SendShouldSucceed = $false
    $outputMarkerFailure = ''
    try {
        Send-AccessibilityOutputMarker `
            -Process $outputMarkerProcess `
            -TextPattern $outputMarkerTextPattern `
            -Marker 'VALIDMARKER_02' `
            -Description 'contract marker failure' `
            -ExpectedFocusedHwnd $outputMarkerExpectedFocus | Out-Null
    }
    catch { $outputMarkerFailure = $_.Exception.Message }
    $failureLauncherPath = $script:outputMarkerLauncherPaths[-1]
    if ($outputMarkerFailure -notlike
            'SendInput failed for contract marker failure:*' -or
        [IO.File]::Exists($failureLauncherPath) -or
        ($script:outputMarkerOperationLog -join '|') -cne
            'launcher:contract marker failure|owner:contract marker failure text|native-send:call contract-output-launcher.cmd') {
        throw 'Output-marker failure must propagate the send defect and delete its launcher in finally.'
    }
}
finally {
    [FlagshipAccessibilityNativeProbe]::SendShouldSucceed = $true
    [FlagshipAccessibilityNativeProbe]::Recorder = $null
    foreach ($name in @(
        'Send-AccessibilityOutputMarker',
        'New-AccessibilityTempCmdLauncher',
        'Assert-AccessibilityInputOwner',
        'Wait-AccessibilityTerminalCommandEcho',
        'Send-AccessibilityChord',
        'Wait-AccessibilityCondition'
    )) {
        Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
    }
    foreach ($path in @($script:outputMarkerLauncherPaths)) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    Remove-Variable -Scope Script -Name outputMarkerOperationLog, outputMarkerOwnerCalls, outputMarkerLauncherPaths, outputMarkerVisible -ErrorAction SilentlyContinue
}

$notificationDiagnosticFunctions = @(
    Get-NamedFunctionDefinitions `
        -Ast $accessibilityHarnessAst `
        -Name 'Get-AccessibilityOutputNotificationDiagnostic'
)
if ($notificationDiagnosticFunctions.Count -ne 1) {
    throw 'Accessibility output notification evidence must define one pure diagnostic.'
}
Assert-NoUnreachableStatements `
    -Ast $notificationDiagnosticFunctions[0].Body `
    -Context 'Get-AccessibilityOutputNotificationDiagnostic'
. ([scriptblock]::Create($notificationDiagnosticFunctions[0].Extent.Text))
$notificationRawSuccessFixture = @()
$notificationRawSuccessFixture += ,([object[]]@(
    'Other',
    'ignored',
    0,
    'OtherActivity'
))
$notificationRawSuccessFixture += ,([object[]]@(
    'ActionCompleted',
    'prefix-',
    2,
    'TerminalTextOutput'
))
$notificationRawSuccessFixture += ,([object[]]@(
    'ActionCompleted',
    'MARKER',
    2,
    'TerminalTextOutput'
))
$notificationSuccessOutputs = @(
    Get-AccessibilityOutputNotificationDiagnostic `
        -RawNotificationHistory $notificationRawSuccessFixture `
        -Marker 'MARKER' `
        -FocusMismatchPolls 2 `
        -FocusRecoveryCount 1 `
        -StolenForegroundHwnds @(41, 42) `
        -LastForegroundHwnd 43 `
        -LastFocusedHwnd 44
)
$notificationRawFailureFixture = @()
$notificationRawFailureFixture += ,([object[]]@(
    'ActionCompleted',
    'different',
    2,
    'TerminalTextOutput'
))
$notificationRawFailureFixture += ,([object[]]@(
    'Other',
    'MARKER',
    0,
    'OtherActivity'
))
$notificationFailureOutputs = @(
    Get-AccessibilityOutputNotificationDiagnostic `
        -RawNotificationHistory $notificationRawFailureFixture `
        -Marker 'MARKER'
)
$notificationRequiredProperties = @(
    'raw_notification_history',
    'notification_history',
    'notification_text',
    'matched',
    'history',
    'text',
    'count',
    'focus_mismatch_polls',
    'focus_recovery_count',
    'stolen_foreground_hwnds',
    'last_foreground_hwnd',
    'last_focused_hwnd'
)
if ($notificationSuccessOutputs.Count -ne 1 -or
    @($notificationRequiredProperties | Where-Object {
        $notificationSuccessOutputs[0].PSObject.Properties.Name -notcontains $_
    }).Count -ne 0 -or
    @($notificationSuccessOutputs[0].raw_notification_history).Count -ne 3 -or
    @($notificationSuccessOutputs[0].notification_history).Count -ne 2 -or
    $notificationSuccessOutputs[0].notification_text -cne 'prefix-MARKER' -or
    $notificationSuccessOutputs[0].matched -ne $true -or
    @($notificationSuccessOutputs[0].history).Count -ne 2 -or
    $notificationSuccessOutputs[0].text -cne 'prefix-MARKER' -or
    $notificationSuccessOutputs[0].count -ne 2 -or
    $notificationSuccessOutputs[0].focus_mismatch_polls -ne 2 -or
    $notificationSuccessOutputs[0].focus_recovery_count -ne 1 -or
    @($notificationSuccessOutputs[0].stolen_foreground_hwnds).Count -ne 2 -or
    $notificationSuccessOutputs[0].last_foreground_hwnd -ne 43 -or
    $notificationSuccessOutputs[0].last_focused_hwnd -ne 44 -or
    $notificationFailureOutputs.Count -ne 1 -or
    @($notificationFailureOutputs[0].raw_notification_history).Count -ne 2 -or
    @($notificationFailureOutputs[0].notification_history).Count -ne 1 -or
    $notificationFailureOutputs[0].notification_text -cne 'different' -or
    $notificationFailureOutputs[0].matched -ne $false) {
    throw 'Accessibility output notification diagnostic must atomically shape raw, matching, text, focus, success, and failure evidence without stray output.'
}
$ownedWarmNotificationFunctions = @(
    Get-NamedFunctionDefinitions `
        -Ast $accessibilityHarnessAst `
        -Name 'Wait-AccessibilityOwnedOutputNotification'
)
$ownedWarmNotificationCalls = @(
    Get-NamedCommands `
        -Ast $accessibilityHarnessAst `
        -Name 'Wait-AccessibilityOwnedOutputNotification'
)
$coldFirstReadFunctions = @(
    Get-NamedFunctionDefinitions `
        -Ast $accessibilityHarnessAst `
        -Name 'Invoke-AccessibilityColdFirstReadProof'
)
$coldFirstReadCalls = @(
    Get-NamedCommands `
        -Ast $accessibilityHarnessAst `
        -Name 'Invoke-AccessibilityColdFirstReadProof'
)
$coldOwnedNotificationCalls = if ($coldFirstReadFunctions.Count -eq 1) {
    @($coldFirstReadFunctions[0].Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Wait-AccessibilityOwnedOutputNotification'
    }, $true))
} else {
    @()
}
$coldCleanupTries = if ($coldFirstReadFunctions.Count -eq 1) {
    @($coldFirstReadFunctions[0].Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst] -and
            $null -ne $node.Finally
    }, $true))
} else {
    @()
}
if ($ownedWarmNotificationFunctions.Count -ne 1 -or
    $ownedWarmNotificationCalls.Count -ne 3 -or
    $coldFirstReadFunctions.Count -ne 1 -or
    $coldFirstReadCalls.Count -ne 2 -or
    $coldOwnedNotificationCalls.Count -ne 1 -or
    $coldCleanupTries.Count -lt 1) {
    throw 'Warm and cold accessibility evidence must share one owner-aware notification wait, one cold proof, and fail-closed cleanup.'
}
. ([scriptblock]::Create($ownedWarmNotificationFunctions[0].Extent.Text))
function Wait-AccessibilityCondition {
    param(
        $Deadline,
        [string] $Description,
        [scriptblock] $Condition
    )
}
try {
    $notificationWaitFixtureProcess =
        [System.Diagnostics.Process]::GetCurrentProcess()
    $notificationWaitWithoutDiagnostic = @(
        Wait-AccessibilityOwnedOutputNotification `
            -Process $notificationWaitFixtureProcess `
            -ExpectedFocusedHwnd ([IntPtr]::Zero) `
            -Marker 'MARKER' `
            -Description 'optional diagnostic omitted fixture'
    )
    $notificationWaitDiagnosticValue = $null
    $notificationWaitWithDiagnostic = @(
        Wait-AccessibilityOwnedOutputNotification `
            -Process $notificationWaitFixtureProcess `
            -ExpectedFocusedHwnd ([IntPtr]::Zero) `
            -Marker 'MARKER' `
            -Description 'optional diagnostic reference fixture' `
            -Diagnostic ([ref] $notificationWaitDiagnosticValue)
    )
    $notificationWaitRejectedScalar = $false
    try {
        $null = Wait-AccessibilityOwnedOutputNotification `
            -Process $notificationWaitFixtureProcess `
            -ExpectedFocusedHwnd ([IntPtr]::Zero) `
            -Marker 'MARKER' `
            -Description 'invalid diagnostic scalar fixture' `
            -Diagnostic 'not-a-reference'
    }
    catch {
        if ($_.Exception.Message -cne
            'Diagnostic must be a [ref] value when supplied.') {
            throw
        }
        $notificationWaitRejectedScalar = $true
    }
    if ($notificationWaitWithoutDiagnostic.Count -ne 1 -or
        $notificationWaitWithoutDiagnostic[0].matched -ne $false -or
        $notificationWaitWithDiagnostic.Count -ne 1 -or
        $notificationWaitWithDiagnostic[0].matched -ne $false -or
        $null -eq $notificationWaitDiagnosticValue -or
        $notificationWaitDiagnosticValue.matched -ne $false -or
        -not $notificationWaitRejectedScalar) {
        throw 'Owner-aware notification wait must support omitted and [ref] diagnostics while rejecting scalar diagnostics.'
    }
}
finally {
    Remove-Item `
        -LiteralPath Function:\Wait-AccessibilityOwnedOutputNotification `
        -ErrorAction SilentlyContinue
    Remove-Item `
        -LiteralPath Function:\Wait-AccessibilityCondition `
        -ErrorAction SilentlyContinue
}
Assert-NoUnreachableStatements `
    -Ast $ownedWarmNotificationFunctions[0].Body `
    -Context 'Wait-AccessibilityOwnedOutputNotification'
Assert-NoUnreachableStatements `
    -Ast $coldFirstReadFunctions[0].Body `
    -Context 'Invoke-AccessibilityColdFirstReadProof'
$coldRequirements = @(
    @{ Kind = 'Command'; Name = 'Wait-AccessibilityCondition' },
    @{ Kind = 'Command'; Name = 'Start-Sleep' },
    @{ Kind = 'Member'; Name = 'StartNotificationCapture' },
    @{ Kind = 'Member'; Name = 'StopNotificationCapture' },
    @{ Kind = 'Member'; Name = 'WriteAllText' },
    @{ Kind = 'Command'; Name = 'Wait-AccessibilityOwnedOutputNotification' },
    @{ Kind = 'Member'; Name = 'GetText' },
    @{ Kind = 'Member'; Name = 'Delete' }
)
foreach ($requirement in $coldRequirements) {
    $operationMatches = if ($requirement.Kind -eq 'Command') {
        @(Get-NamedCommands -Ast $coldFirstReadFunctions[0].Body -Name $requirement.Name)
    } else {
        @(Get-NamedMemberExpressions -Ast $coldFirstReadFunctions[0].Body -Name $requirement.Name -InvocationOnly)
    }
    if ($operationMatches.Count -lt 1) {
        throw "Cold first-read proof must retain observable operation '$($requirement.Name)'."
    }
}
$coldFinalReads = @(
    Get-NamedMemberExpressions `
        -Ast $coldFirstReadFunctions[0].Body `
        -Name 'GetText' `
        -InvocationOnly
)
if ($coldFinalReads.Count -ne 1 -or
    (Get-ExpressionRootVariableName -Node $coldFinalReads[0].Expression) -ne
        'TextPattern') {
    throw 'Cold output proof must perform exactly one final TextPattern GetText call.'
}

$coldProbeSource = $coldFirstReadFunctions[0].Extent.Text.Replace(
    '[NocttyAccessibilityNative]',
    '[FlagshipAccessibilityNativeProbe]'
)
. ([scriptblock]::Create($coldProbeSource))
$coldProbeRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'noctty-cold-proof-' + [Guid]::NewGuid().ToString('N')
)
[IO.Directory]::CreateDirectory($coldProbeRoot) | Out-Null
$script:coldProbeLog = [Collections.Generic.List[string]]::new()
$script:coldProbeOwnerCalls = [Collections.Generic.List[object]]::new()
$script:coldProbeMarker = 'COLDMARKER_001'
$script:coldProbeFailure = $false
[FlagshipAccessibilityNativeProbe]::Recorder = [Action[string]] {
    param([string] $entry)
    $script:coldProbeLog.Add($entry)
}
function New-AccessibilityTempCmdLauncher {
    param([string[]] $Lines, [string] $Description)
    $launcherPath = Join-Path $coldProbeRoot (
        'launcher-' + [Guid]::NewGuid().ToString('N') + '.cmd'
    )
    [IO.File]::WriteAllText($launcherPath, ($Lines -join "`r`n"))
    $script:coldProbeLog.Add("launcher:$Description")
    [pscustomobject]@{
        path = $launcherPath
        command = 'call contract-cold-launcher.cmd'
        command_length = 31
    }
}
function Assert-AccessibilityInputOwner {
    param($Process, [string] $Description, [IntPtr] $ExpectedFocusedHwnd)
    $script:coldProbeLog.Add("owner:$Description")
    $script:coldProbeOwnerCalls.Add([pscustomobject]@{
        Process = $Process
        Description = $Description
        ExpectedFocusedHwnd = $ExpectedFocusedHwnd
    })
}
function Wait-AccessibilityTerminalCommandEcho {
    param(
        $Process,
        $TextPattern,
        [string] $Command,
        [string] $Description,
        [IntPtr] $ExpectedFocusedHwnd,
        $SendInputRequested,
        $SendInputReturned
    )
    $script:coldProbeLog.Add("echo:$Description")
    [pscustomobject]@{ observed = $true; command = $Command }
}
function Send-AccessibilityChord {
    param([uint16[]] $Keys, [string] $Description, $Process, [IntPtr] $ExpectedFocusedHwnd)
    $script:coldProbeLog.Add("chord:${Description}:$($Keys -join ',')")
}
function Wait-AccessibilityCondition {
    param([DateTime] $Deadline, [string] $Description, [scriptblock] $Condition)
    $script:coldProbeLog.Add("condition:$Description")
    $helperPath = @(Get-ChildItem -LiteralPath $coldProbeRoot -Filter 'cold-output-*.ps1')[0].FullName
    $readyPath = [IO.Path]::ChangeExtension($helperPath, '.ready')
    [IO.File]::WriteAllText($readyPath, 'ready')
    if (-not (& $Condition)) {
        throw "Cold proof condition did not observe its controlled ready file: $Description"
    }
}
function Start-Sleep {
    param([int] $Milliseconds)
    $script:coldProbeLog.Add("sleep:$Milliseconds")
}
function Wait-AccessibilityOwnedOutputNotification {
    param(
        $Process,
        [IntPtr] $ExpectedFocusedHwnd,
        [string] $Marker,
        [string] $Description,
        [System.Management.Automation.PSReference] $Diagnostic
    )
    $script:coldProbeLog.Add("notification:${Description}:$Marker")
    $helperPath = @(Get-ChildItem -LiteralPath $coldProbeRoot -Filter 'cold-output-*.ps1')[0].FullName
    $ackPath = [IO.Path]::ChangeExtension($helperPath, '.ack')
    [IO.File]::WriteAllText($ackPath, 'ack')
    $value = [pscustomobject]@{
        raw_notification_history = @('raw')
        notification_history = @('matched')
        notification_text = $Marker
        text = $Marker
        count = 1
        matched = $true
        focus_mismatch_polls = 0
        focus_recovery_count = 0
        stolen_foreground_hwnds = @()
    }
    $Diagnostic.Value = $value
    if ($script:coldProbeFailure) {
        throw 'injected cold notification failure'
    }
    $value
}
$coldProbeRange = [pscustomobject]@{}
$coldProbeRange | Add-Member -MemberType ScriptMethod -Name GetText -Value {
    param($MaximumLength)
    $script:coldProbeLog.Add("gettext:$MaximumLength")
    "prompt $($script:coldProbeMarker)"
}
$coldProbeTextPattern = [pscustomobject]@{ DocumentRange = $coldProbeRange }
$coldProbeProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$coldProbeExpectedFocus = [IntPtr]88
[FlagshipAccessibilityNativeProbe]::ForegroundHwnd =
    $coldProbeProcess.MainWindowHandle
[FlagshipAccessibilityNativeProbe]::FocusedHwnd = $coldProbeExpectedFocus
try {
    $coldProbeResult = Invoke-AccessibilityColdFirstReadProof `
        -Process $coldProbeProcess `
        -TextPattern $coldProbeTextPattern `
        -Marker $script:coldProbeMarker `
        -Description 'contract cold marker' `
        -ExpectedFocusedHwnd $coldProbeExpectedFocus `
        -HelperDirectory $coldProbeRoot
    $expectedColdOperations = @(
        'launcher:contract cold marker',
        'native-reset-capture',
        'native-start-capture:88',
        'owner:contract cold marker text',
        'native-send:call contract-cold-launcher.cmd',
        'echo:contract cold marker',
        'owner:contract cold marker pre-Enter',
        'chord:contract cold marker Enter:13',
        'condition:contract cold marker helper ready file',
        'sleep:1200',
        'native-foreground',
        "native-focus:$($coldProbeProcess.MainWindowHandle.ToInt64())",
        'owner:contract cold marker pre-trigger owner',
        'native-foreground',
        "native-focus:$($coldProbeProcess.MainWindowHandle.ToInt64())",
        'native-reset-capture',
        'notification:contract cold marker direct output notification:COLDMARKER_001',
        'gettext:-1',
        'native-stop-capture'
    )
    if (($script:coldProbeLog -join '|') -cne
            ($expectedColdOperations -join '|') -or
        $script:coldProbeOwnerCalls.Count -ne 3 -or
        @($script:coldProbeOwnerCalls | Where-Object {
            -not [object]::ReferenceEquals($_.Process, $coldProbeProcess) -or
                $_.ExpectedFocusedHwnd -ne $coldProbeExpectedFocus
        }).Count -ne 0 -or
        $coldProbeResult.final_text_pattern_reads -ne 1 -or
        -not $coldProbeResult.marker_visible -or
        -not $coldProbeResult.output_ack_observed -or
        @(Get-ChildItem -LiteralPath $coldProbeRoot -Force).Count -ne 0) {
        throw 'Valid cold first-read behavior must preserve operation/argument identity, one final read, owned notification evidence, and cleanup.'
    }

    $script:coldProbeLog.Clear()
    $script:coldProbeOwnerCalls.Clear()
    $script:coldProbeMarker = 'COLDMARKER_002'
    $script:coldProbeFailure = $true
    $coldProbeFailureMessage = ''
    try {
        Invoke-AccessibilityColdFirstReadProof `
            -Process $coldProbeProcess `
            -TextPattern $coldProbeTextPattern `
            -Marker $script:coldProbeMarker `
            -Description 'contract cold failure' `
            -ExpectedFocusedHwnd $coldProbeExpectedFocus `
            -HelperDirectory $coldProbeRoot | Out-Null
    }
    catch { $coldProbeFailureMessage = $_.Exception.Message }
    if ($coldProbeFailureMessage -notlike
            'injected cold notification failure*Diagnostic=*' -or
        $script:coldProbeLog[-1] -cne 'native-stop-capture' -or
        @(Get-ChildItem -LiteralPath $coldProbeRoot -Force).Count -ne 0) {
        throw 'Cold first-read injected failure must propagate diagnostic context and stop capture/delete files in finally.'
    }
}
finally {
    [FlagshipAccessibilityNativeProbe]::Recorder = $null
    foreach ($name in @(
        'Invoke-AccessibilityColdFirstReadProof',
        'New-AccessibilityTempCmdLauncher',
        'Assert-AccessibilityInputOwner',
        'Wait-AccessibilityTerminalCommandEcho',
        'Send-AccessibilityChord',
        'Wait-AccessibilityCondition',
        'Start-Sleep',
        'Wait-AccessibilityOwnedOutputNotification'
    )) {
        Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
    }
    if ([IO.Directory]::Exists($coldProbeRoot)) {
        [IO.Directory]::Delete($coldProbeRoot, $true)
    }
    Remove-Variable -Scope Script -Name coldProbeLog, coldProbeOwnerCalls, coldProbeMarker, coldProbeFailure -ErrorAction SilentlyContinue
}

$ownedDiagnosticCalls = @(
    Get-NamedCommands `
        -Ast $ownedWarmNotificationFunctions[0].Body `
        -Name 'Get-AccessibilityOutputNotificationDiagnostic'
)
$ownedRawHistorySnapshots = @(
    Get-NamedMemberExpressions `
        -Ast $ownedWarmNotificationFunctions[0].Body `
        -Name 'NotificationHistorySnapshot'
)
$ownedDiagnosticValueAssignments = @(
    Get-NamedMemberExpressions `
        -Ast $ownedWarmNotificationFunctions[0].Body `
        -Name 'Value' |
        Where-Object {
            (Get-ExpressionRootVariableName -Node $_) -eq 'diagnosticState' -and
            $_.Parent -is
                [System.Management.Automation.Language.AssignmentStatementAst] -and
            [object]::ReferenceEquals($_.Parent.Left, $_)
        }
)
if ($ownedDiagnosticCalls.Count -ne 3 -or
    $ownedRawHistorySnapshots.Count -ne 2 -or
    $ownedDiagnosticValueAssignments.Count -ne 2 -or
    (Get-NamedCommands -Ast $ownedWarmNotificationFunctions[0].Body -Name 'Wait-AccessibilityCondition').Count -ne 1 -or
    (Get-NamedCommands -Ast $ownedWarmNotificationFunctions[0].Body -Name 'Where-Object').Count -ne 0) {
    throw 'Owner-aware output notification wait must recompute one atomic diagnostic from raw capture history on every poll and failure.'
}
$inactiveTabFunctions = @(
    Get-NamedFunctionDefinitions `
        -Ast $accessibilityHarnessAst `
        -Name 'Invoke-AccessibilityInactiveTabFirstReadProof'
)
$inactiveTabCalls = @(
    Get-NamedCommands `
        -Ast $accessibilityHarnessAst `
        -Name 'Invoke-AccessibilityInactiveTabFirstReadProof'
)
$inactiveCleanupTries = if ($inactiveTabFunctions.Count -eq 1) {
    @($inactiveTabFunctions[0].Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst] -and
            $null -ne $node.Finally
    }, $true))
} else {
    @()
}
if ($inactiveTabFunctions.Count -ne 1 -or
    $inactiveTabCalls.Count -ne 2 -or
    $inactiveCleanupTries.Count -lt 1) {
    throw 'Targeted and full evidence must share one inactive-tab proof with fail-closed cleanup.'
}
Assert-NoUnreachableStatements `
    -Ast $inactiveTabFunctions[0].Body `
    -Context 'Invoke-AccessibilityInactiveTabFirstReadProof'
$inactiveAckWaits = @(
    Get-NamedCommands -Ast $inactiveTabFunctions[0].Body -Name 'Wait-AccessibilityCondition' |
        Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value 'inactive-output external ack'
        }
)
$inactiveQuietLoops = @($inactiveTabFunctions[0].Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.DoWhileStatementAst] -and
        (Get-NamedMemberExpressions -Ast $node.Body -Name 'IsWindowResponsive' -InvocationOnly).Count -ge 1 -and
        (Get-NamedCommands -Ast $node.Body -Name 'Get-AccessibilityOutputNotificationDiagnostic').Count -ge 1
}, $true))
$inactiveQuietBody = if ($inactiveQuietLoops.Count -eq 1) {
    $inactiveQuietLoops[0].Body
} else {
    $null
}
$inactiveTextReads = @(
    Get-NamedMemberExpressions `
        -Ast $inactiveTabFunctions[0].Body `
        -Name 'GetText' `
        -InvocationOnly
)
$inactiveCaptureStops = @(
    Get-NamedMemberExpressions `
        -Ast $inactiveTabFunctions[0].Body `
        -Name 'StopNotificationCapture' `
        -InvocationOnly
)
$inactiveProcessRefreshes = if ($null -ne $inactiveQuietBody) {
    @(
        Get-NamedMemberExpressions `
            -Ast $inactiveQuietBody `
            -Name 'Refresh' `
            -InvocationOnly |
            Where-Object {
                (Get-ExpressionRootVariableName -Node $_.Expression) -eq 'Process'
            }
    )
} else {
    @()
}
$inactiveRequirements = @(
    @{ Kind = 'Member'; Name = 'StartNotificationCapture' },
    @{ Kind = 'Member'; Name = 'StopNotificationCapture' },
    @{ Kind = 'Member'; Name = 'NotificationHistorySnapshot' },
    @{ Kind = 'Member'; Name = 'FocusedWindowFor' },
    @{ Kind = 'Command'; Name = 'Get-AccessibilityOutputNotificationDiagnostic' },
    @{ Kind = 'Member'; Name = 'GetText' }
)
foreach ($requirement in $inactiveRequirements) {
    $operationMatches = if ($requirement.Kind -eq 'Command') {
        @(Get-NamedCommands -Ast $inactiveTabFunctions[0].Body -Name $requirement.Name)
    } elseif ($requirement.Name -eq 'NotificationHistorySnapshot') {
        @(Get-NamedMemberExpressions -Ast $inactiveTabFunctions[0].Body -Name $requirement.Name)
    } else {
        @(Get-NamedMemberExpressions -Ast $inactiveTabFunctions[0].Body -Name $requirement.Name -InvocationOnly)
    }
    if ($operationMatches.Count -lt 1) {
        throw "Inactive-tab proof must retain observable operation '$($requirement.Name)'."
    }
}
if ($inactiveAckWaits.Count -ne 1 -or
    $inactiveQuietLoops.Count -ne 1 -or
    $inactiveProcessRefreshes.Count -ne 1 -or
    (Get-NamedMemberExpressions -Ast $inactiveQuietBody -Name 'GetText' -InvocationOnly).Count -ne 0 -or
    (Get-NamedMemberExpressions -Ast $inactiveQuietBody -Name 'DocumentRange').Count -ne 0 -or
    (Get-NamedCommands -Ast $inactiveQuietBody -Name 'Start-Sleep').Count -lt 1 -or
    $inactiveTextReads.Count -ne 1 -or
    (Get-ExpressionRootVariableName -Node $inactiveTextReads[0].Expression) -ne
        'inactiveTabTextPattern' -or
    $inactiveCaptureStops.Count -ne 2) {
    throw 'Inactive-tab proof must own one external-ACK scenario, refresh the process in its bounded quiet loop, make exactly one first TextPattern read, and stop capture exactly twice across success/finally cleanup.'
}
$inactiveOuterTry = $inactiveCleanupTries[0]
$inactiveTryStatements = @($inactiveOuterTry.Body.Statements)
$inactiveFinalSnapshotAssignments = @(
    $inactiveTryStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            (Get-VariableExpressionName -Node $_.Left) -eq
                'inactiveFinalNotificationDiagnostic' -and
            (Get-NamedCommands `
                -Ast $_.Right `
                -Name 'Get-AccessibilityOutputNotificationDiagnostic').Count -eq 1 -and
            (Get-NamedMemberExpressions `
                -Ast $_.Right `
                -Name 'NotificationHistorySnapshot').Count -eq 1
    }
)
$inactiveFinalSnapshotGuards = @(
    $inactiveTryStatements | Where-Object {
        $matchedMembers = @(Get-NamedMemberExpressions -Ast $_ -Name 'matched')
        $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $matchedMembers.Count -eq 1 -and
            (Get-ExpressionRootVariableName -Node $matchedMembers[0].Expression) -eq
                'inactiveFinalNotificationDiagnostic' -and
            @($_.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ThrowStatementAst]
            }, $true)).Count -eq 1
    }
)
$inactiveSuccessStops = @(
    $inactiveCaptureStops | Where-Object {
        [object]::ReferenceEquals(
            (Get-ContainingStatementBlock -Node $_),
            $inactiveOuterTry.Body
        )
    }
)
$inactiveSuccessStopStatement = if ($inactiveSuccessStops.Count -eq 1) {
    $node = $inactiveSuccessStops[0]
    while ($null -ne $node.Parent -and
        -not [object]::ReferenceEquals($node.Parent, $inactiveOuterTry.Body)) {
        $node = $node.Parent
    }
    $node
} else {
    $null
}
$inactiveSnapshotIndex = if ($inactiveFinalSnapshotAssignments.Count -eq 1) {
    [array]::IndexOf($inactiveTryStatements, $inactiveFinalSnapshotAssignments[0])
} else { -1 }
$inactiveGuardIndex = if ($inactiveFinalSnapshotGuards.Count -eq 1) {
    [array]::IndexOf($inactiveTryStatements, $inactiveFinalSnapshotGuards[0])
} else { -1 }
$inactiveStopIndex = if ($null -ne $inactiveSuccessStopStatement) {
    [array]::IndexOf($inactiveTryStatements, $inactiveSuccessStopStatement)
} else { -1 }
if ($inactiveSnapshotIndex -lt 0 -or
    $inactiveGuardIndex -ne ($inactiveSnapshotIndex + 1) -or
    $inactiveStopIndex -ne ($inactiveGuardIndex + 1)) {
    throw 'Inactive-tab proof must reject one final fresh notification snapshot immediately before stopping capture.'
}

$tempLauncherFunctions = @(
    Get-NamedFunctionDefinitions `
        -Ast $accessibilityHarnessAst `
        -Name 'New-AccessibilityTempCmdLauncher'
)
$tempLauncherCalls = @(
    Get-NamedCommands `
        -Ast $accessibilityHarnessAst `
        -Name 'New-AccessibilityTempCmdLauncher'
)
if ($tempLauncherFunctions.Count -ne 1 -or $tempLauncherCalls.Count -ne 3) {
    throw 'Warm, cold, and inactive evidence must share one temporary CMD launcher factory.'
}
$commandEchoFunctions = @(
    Get-NamedFunctionDefinitions -Ast $accessibilityHarnessAst -Name 'Wait-AccessibilityTerminalCommandEcho'
)
if ($commandEchoFunctions.Count -ne 1) {
    throw 'Terminal command echo gating must define one helper.'
}
$commandEchoFunction = $commandEchoFunctions[0]
Assert-NoUnreachableStatements -Ast $commandEchoFunction.Body -Context 'Wait-AccessibilityTerminalCommandEcho'
$commandEchoLoops = @($commandEchoFunction.Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.DoWhileStatementAst]
}, $true))
$commandEchoLoopTextReads = if ($commandEchoLoops.Count -eq 1) {
    @(Get-NamedMemberExpressions -Ast $commandEchoLoops[0].Body -Name 'GetText' -InvocationOnly)
} else {
    @()
}
$commandEchoForbiddenInputCalls = @(
    @(Get-NamedMemberExpressions -Ast $commandEchoFunction.Body -Name 'SendUnicodeText' -InvocationOnly) +
    @(Get-NamedMemberExpressions -Ast $commandEchoFunction.Body -Name 'SendChord' -InvocationOnly) +
    @(Get-NamedCommands -Ast $commandEchoFunction.Body -Name 'Send-AccessibilityChord')
)
if ($commandEchoLoops.Count -ne 1 -or
    $commandEchoLoopTextReads.Count -lt 1 -or
    (Get-NamedMemberExpressions -Ast $commandEchoFunction.Body -Name 'GetForegroundWindow' -InvocationOnly).Count -lt 1 -or
    (Get-NamedMemberExpressions -Ast $commandEchoFunction.Body -Name 'FocusedWindowFor' -InvocationOnly).Count -lt 1 -or
    (Get-NamedMemberExpressions -Ast $commandEchoFunction.Body -Name 'ForceForeground' -InvocationOnly).Count -lt 1 -or
    (Get-NamedMemberExpressions -Ast $commandEchoFunction.Body -Name 'SetFocus' -InvocationOnly).Count -lt 1 -or
    (Get-NamedMemberExpressions -Ast $commandEchoFunction.Body -Name 'TryGetCurrentPattern' -InvocationOnly).Count -lt 1 -or
    (Get-NamedMemberExpressions -Ast $commandEchoFunction.Body -Name 'Contains' -InvocationOnly).Count -lt 1 -or
    (Get-NamedCommands -Ast $commandEchoFunction.Body -Name 'Get-AccessibilityExceptionHResults').Count -lt 1 -or
    (Get-NamedCommands -Ast $commandEchoFunction.Body -Name 'Test-AccessibilityTransientHResult').Count -lt 1 -or
    $commandEchoForbiddenInputCalls.Count -ne 0) {
    throw 'Terminal command echo gating must poll TextPattern for command visibility, recover exact focus, handle transient providers, and never resend input.'
}
# The read's AST offset and private variable name are intentionally unpinned.
# Membership in the polling loop plus the executed echo scenario enforce the
# observable full-command gate.

$stressBoundaryContract = [regex]::Match(
    $accessibilityHarnessText,
    '(?s)\$stressLineCount = 150.*?\$stressFirstMarker = "\$\{stressPrefix\}_1".*?\$stressFinalMarker = "\$\{stressPrefix\}_150".*?for /L %i in \(1,1,\$stressLineCount\) do @echo \$\{stressPrefix\}_%i.*?\$stressCommand\.Contains\(\$stressFirstMarker\).*?\$stressCommand\.Contains\(\$stressFinalMarker\)'
)
if (-not $stressBoundaryContract.Success -or
    $accessibilityHarnessText -match 'echo\s+\$stressFirstMarker') {
    throw 'Sustained-output evidence must generate 150 indexed lines and must not type or echo the first observed boundary marker directly.'
}
$antiForgeryScenarioBans = @(
    @{
        Pattern = "(?s)'settings conservative dirty-close focus'.{0,1400}?(ForceForeground|SetFocus)\("
        Description = 'settings conservative dirty-close focus'
    },
    @{
        Pattern = "(?s)'command palette unavailable no-match notification'.{0,2200}?\$paletteFocused\.SetFocus\("
        Description = 'palette unavailable focus recovery'
    },
    @{
        Pattern = "(?s)'command palette query global UIA focus'.{0,1800}?\$paletteFocused\.SetFocus\("
        Description = 'palette query focus recovery'
    },
    @{
        Pattern = "(?s)'command palette native List recovery after zero matches'.{0,2200}?\$paletteFocused\.SetFocus\("
        Description = 'palette list recovery'
    },
    @{
        Pattern = "(?s)'docked search query UIA focus'.{0,1600}?\$searchQueryEdit\.SetFocus\("
        Description = 'search query focus recovery'
    },
    @{
        Pattern = "(?s)'settings destruction and terminal focus restoration after idle soak'.{0,1400}?ForceForeground\("
        Description = 'settings idle-soak focus restoration'
    }
)
foreach ($ban in $antiForgeryScenarioBans) {
    if ($accessibilityHarnessText -match $ban.Pattern) {
        throw "Accessibility anti-forgery invariant failed: $($ban.Description) must be restored by the product, not forced by the harness."
    }
}
$settingsFocusWaits = @(
    Get-NamedCommands -Ast $accessibilityHarnessAst -Name 'Wait-AccessibilityCondition' |
        Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value 'settings section focus and selection ownership'
        }
)
$settingsFocusContract = $false
if ($settingsFocusWaits.Count -eq 1) {
    $settingsFocusCondition = Get-CommandParameterArgument -Command $settingsFocusWaits[0] -Name 'Condition'
    if ($settingsFocusCondition -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        $settingsFocusBody = $settingsFocusCondition.ScriptBlock.EndBlock
        $settingsFocusContract =
            (Get-NamedMemberExpressions -Ast $settingsFocusBody -Name 'GetForegroundWindow' -InvocationOnly).Count -ge 1 -and
            (Get-NamedMemberExpressions -Ast $settingsFocusBody -Name 'ForceForeground' -InvocationOnly).Count -ge 1 -and
            (Get-NamedMemberExpressions -Ast $settingsFocusBody -Name 'SetFocus' -InvocationOnly).Count -ge 1 -and
            (Get-NamedMemberExpressions -Ast $settingsFocusBody -Name 'Select' -InvocationOnly).Count -ge 1 -and
            (Get-NamedMemberExpressions -Ast $settingsFocusBody -Name 'FocusedWindowFor' -InvocationOnly).Count -ge 1 -and
            @($settingsFocusBody.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ReturnStatementAst]
            }, $true)).Count -ge 1
    }
}
$matchesAssignments = @($accessibilityHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        (Get-VariableExpressionName -Node $node.Left) -eq 'matches'
}, $true))
if (-not $settingsFocusContract -or
    $matchesAssignments.Count -ne 0 -or
    $accessibilityHarnessText -notmatch 'settings conservative dirty-close focus' -or
    $accessibilityHarnessText -notmatch 'settings destruction and terminal focus restoration after idle soak') {
    throw 'Accessibility settings focus evidence must retry foreground/focus/selection, observe conservative close restoration, and preserve the automatic $matches variable.'
}
# UIA focus calls are retry mechanics, not an order API. The real wait condition
# returns success only after foreground, section focus/selection, and native focus
# postconditions all hold; the close scenario observes product-restored focus.

# Deleted the viewport helper-name pin: native settings geometry/content-extent
# tests and the executed clipping evidence own the observable viewport contract.
Invoke-ContractTable -Contracts @(
    @{
        File = $win32Settings
        Pattern = '(?i)MessageBoxW|MB_YESNOCANCEL|MB_DEFBUTTON3'
        Kind = 'WorkflowAbsent'
        Description = 'settings dirty close never falls back to an inaccessible modal message box'
    }
)
# Deleted implementation-order regexes, one rationale per covered invariant:
# - Section focus/click/event order: native click-focus tests plus Settings focus evidence.
# - Inline dirty-close dispatch: native dirty-close, reopen, save-dispatch, and prompt-text tests.
# - Prompt geometry/save focus: native geometry/content-extent tests plus interactive clipping/focus evidence.
# - Overlay edit bounds/confirm visibility: interactive overlay layout and focus evidence.
# - Destructive palette color precedence: reviewed native source digest plus palette screenshot evidence.
# - Keep-editing/discard/focus events: executed Settings close-action evidence.
# - Save-and-close persistence/restoration: executed same-sandbox relaunch and byte-restore evidence.
$themePersistenceFunctionNames = @(
    'Get-AccessibilityThemeProbe',
    'Set-AccessibilityThemeIndex',
    'Get-AccessibilityDwmUInt'
)
foreach ($functionName in $themePersistenceFunctionNames) {
    if (@(Get-NamedFunctionDefinitions `
        -Ast $accessibilityHarnessAst `
        -Name $functionName).Count -ne 1) {
        throw "Theme persistence evidence must define exactly one $functionName helper."
    }
}
$themePersistenceVerifierCalls = @(
    Get-NamedCommands `
        -Ast $accessibilityHarnessAst `
        -Name 'Get-AccessibilityThemeProbe' |
        Where-Object {
            Test-CommandHasStringArgument `
                -Command $_ `
                -Value 'settings persistence verifier'
        }
)
$themePersistenceSelectionCalls = @(
    Get-NamedCommands `
        -Ast $accessibilityHarnessAst `
        -Name 'Set-AccessibilityThemeIndex' |
        Where-Object {
            Test-CommandHasStringArgument `
                -Command $_ `
                -Value 'settings save probe Dark selection'
        }
)
$themePersistenceDwmCalls = @(
    Get-NamedCommands `
        -Ast $accessibilityHarnessAst `
        -Name 'Get-AccessibilityDwmUInt' |
        Where-Object {
            $description = Get-CommandParameterArgument `
                -Command $_ `
                -Name 'Description'
            $description -is
                    [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $description.Value -in @('fresh Dark host', 'fresh Dark Settings')
        }
)
$themePersistenceDwmAttributes = @(
    $themePersistenceDwmCalls |
        ForEach-Object {
            $argument = Get-CommandParameterArgument -Command $_ -Name 'Attribute'
            if ($argument -isnot
                [System.Management.Automation.Language.ConstantExpressionAst]) {
                throw 'Fresh Dark DWM persistence attributes must be static integers.'
            }
            [int]$argument.Value
        } |
        Sort-Object
)
$themePersistenceStringValues = @(
    $accessibilityHarnessAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true) |
        ForEach-Object { $_.Value }
)
$themePersistenceEvidenceKeys = @(
    'persistence_theme_config_dark',
    'persistence_theme_fresh_process_index',
    'persistence_theme_dark_settings_pixel',
    'persistence_theme_dark_host_pixel',
    'persistence_theme_host_dwm_dark',
    'persistence_theme_settings_dwm_dark',
    'persistence_theme_host_backdrop',
    'persistence_theme_settings_backdrop',
    'persistence_theme_restored'
)
$themeSelectionIndex = if ($themePersistenceSelectionCalls.Count -eq 1) {
    Get-CommandParameterArgument `
        -Command $themePersistenceSelectionCalls[0] `
        -Name 'Index'
}
if ($themePersistenceVerifierCalls.Count -ne 1 -or
    $themePersistenceSelectionCalls.Count -ne 1 -or
    $themeSelectionIndex -isnot
        [System.Management.Automation.Language.ConstantExpressionAst] -or
    [int]$themeSelectionIndex.Value -ne 3 -or
    $themePersistenceDwmCalls.Count -ne 4 -or
    (Compare-Object `
        -ReferenceObject @(20, 20, 38, 38) `
        -DifferenceObject $themePersistenceDwmAttributes `
        -SyncWindow 0).Count -ne 0 -or
    $themePersistenceStringValues -notcontains
        '(?m)^window-theme\s*=\s*dark\s*$' -or
    @($themePersistenceEvidenceKeys | Where-Object {
        $themePersistenceStringValues -notcontains $_
    }).Count -ne 0) {
    throw 'Theme persistence evidence must save Dark, relaunch, verify exact visual/DWM state, and restore its baseline.'
}
$startWithEnvironmentFunctions = @(
    Get-NamedFunctionDefinitions -Ast $accessibilityHarnessAst -Name 'Start-AccessibilityProcessWithEnvironment'
)
if ($startWithEnvironmentFunctions.Count -ne 1) {
    throw 'Accessibility evidence must define one process-environment isolation helper.'
}
. ([scriptblock]::Create($startWithEnvironmentFunctions[0].Extent.Text))
$environmentProbeName = 'NOCTTY_FLAGSHIP_ENV_' + [Guid]::NewGuid().ToString('N')
$environmentProbeOriginal = 'original'
[System.Environment]::SetEnvironmentVariable($environmentProbeName, $environmentProbeOriginal, 'Process')
$script:environmentStartCalls = 0
$script:environmentObservedValues = @()
$script:environmentStartShouldThrow = $false
function Start-Process {
    param(
        [string] $FilePath,
        [object[]] $ArgumentList,
        [string] $WorkingDirectory,
        [string] $RedirectStandardOutput,
        [string] $RedirectStandardError,
        [switch] $PassThru
    )
    $script:environmentStartCalls++
    $script:environmentObservedValues += [System.Environment]::GetEnvironmentVariable($environmentProbeName, 'Process')
    if ($script:environmentStartShouldThrow) { throw 'simulated start failure' }
    return [pscustomobject]@{
        FilePath = $FilePath
        ArgumentList = @($ArgumentList)
        WorkingDirectory = $WorkingDirectory
        RedirectStandardOutput = $RedirectStandardOutput
        RedirectStandardError = $RedirectStandardError
        PassThru = $PassThru.IsPresent
    }
}
try {
    $environmentProbeResult = Start-AccessibilityProcessWithEnvironment -FilePath 'probe.exe' -ArgumentList @('one', 'two') -WorkingDirectory $repoRoot -EnvironmentVariables @{ $environmentProbeName = 'scoped' } -RedirectStandardOutput 'out.log' -RedirectStandardError 'err.log'
    $environmentRestoredAfterSuccess = [System.Environment]::GetEnvironmentVariable($environmentProbeName, 'Process')
    $script:environmentStartShouldThrow = $true
    $environmentFailureMessage = $null
    try {
        Start-AccessibilityProcessWithEnvironment -FilePath 'probe.exe' -ArgumentList @('failure') -WorkingDirectory $repoRoot -EnvironmentVariables @{ $environmentProbeName = 'scoped-failure' } -RedirectStandardOutput 'out.log' -RedirectStandardError 'err.log'
    }
    catch {
        $environmentFailureMessage = $_.Exception.Message
    }
    $environmentRestoredAfterFailure = [System.Environment]::GetEnvironmentVariable($environmentProbeName, 'Process')
    if ($script:environmentStartCalls -ne 2 -or
        @($script:environmentObservedValues).Count -ne 2 -or
        $script:environmentObservedValues[0] -ne 'scoped' -or
        $script:environmentObservedValues[1] -ne 'scoped-failure' -or
        $environmentProbeResult.FilePath -ne 'probe.exe' -or
        @($environmentProbeResult.ArgumentList).Count -ne 2 -or
        -not $environmentProbeResult.PassThru -or
        $environmentRestoredAfterSuccess -ne $environmentProbeOriginal -or
        $environmentFailureMessage -ne 'simulated start failure' -or
        $environmentRestoredAfterFailure -ne $environmentProbeOriginal) {
        throw 'Accessibility process-environment helper must expose scoped values only during Start-Process and restore them after success or failure.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Start-AccessibilityProcessWithEnvironment -ErrorAction SilentlyContinue
    [System.Environment]::SetEnvironmentVariable($environmentProbeName, $null, 'Process')
    Remove-Variable -Scope Script -Name environmentStartCalls, environmentObservedValues, environmentStartShouldThrow -ErrorAction SilentlyContinue
}
# Dedicated-sandbox value derivation and success/failure config restoration are
# observed by the persistence scenario. Private local names and source order are
# intentionally not frozen; the byte-exact restoration helper is executed below.

$restoreBaselineFunctions = @($accessibilityHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Restore-AccessibilityConfigBaseline'
}, $true))
if ($restoreBaselineFunctions.Count -ne 1) {
    throw "Expected exactly one Restore-AccessibilityConfigBaseline definition; found $($restoreBaselineFunctions.Count)."
}
. ([scriptblock]::Create($restoreBaselineFunctions[0].Extent.Text))
$restoreProbeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('noctty-config-restore-' + [Guid]::NewGuid().ToString('N'))
$restoreProbePath = Join-Path $restoreProbeDirectory 'config.ghostty'
[System.IO.Directory]::CreateDirectory($restoreProbeDirectory) | Out-Null
try {
    [System.IO.File]::WriteAllBytes($restoreProbePath, [byte[]](1, 2, 3))
    Restore-AccessibilityConfigBaseline -Path $restoreProbePath -Existed $false -Bytes ([byte[]]@())
    if ([System.IO.File]::Exists($restoreProbePath)) {
        throw 'Accessibility baseline helper did not restore an absent file.'
    }

    [System.IO.File]::WriteAllBytes($restoreProbePath, [byte[]](1, 2, 3))
    [byte[]]$restoreProbeEmptyBytes = @()
    Restore-AccessibilityConfigBaseline -Path $restoreProbePath -Existed $true -Bytes $restoreProbeEmptyBytes
    if (-not [System.IO.File]::Exists($restoreProbePath) -or [System.IO.File]::ReadAllBytes($restoreProbePath).Length -ne 0) {
        throw 'Accessibility baseline helper did not restore a zero-byte file.'
    }

    $restoreProbeBytes = [byte[]](0, 1, 127, 128, 255)
    [System.IO.File]::WriteAllBytes($restoreProbePath, [byte[]](9, 9, 9))
    Restore-AccessibilityConfigBaseline -Path $restoreProbePath -Existed $true -Bytes $restoreProbeBytes
    if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($restoreProbePath)) -cne
        [Convert]::ToBase64String($restoreProbeBytes)) {
        throw 'Accessibility baseline helper did not restore nonempty bytes exactly.'
    }
}
finally {
    if ([System.IO.File]::Exists($restoreProbePath)) { [System.IO.File]::Delete($restoreProbePath) }
    if ([System.IO.Directory]::Exists($restoreProbeDirectory)) { [System.IO.Directory]::Delete($restoreProbeDirectory) }
}
# Deleted palette relayout source-order pin: the zero-match UIA scenario observes
# the structure notification, visible-List/edit fallback, and post-relayout focus.
# Deleted palette-paint helper-order pin: executed narrow/high-DPI palette evidence
# observes row bounds, visibility, title/subtitle layout, border, and edit-frame fit.
# Palette-provider reacquisition is exercised by the interactive zero-match
# scenario. Its internal temporary names and retry-branch source order are not
# pinned; the pure exception-chain and HRESULT classifier are executed below.

$accessibilityHresultFunctions = @($accessibilityHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @('Get-AccessibilityExceptionHResults', 'Test-AccessibilityTransientHResult')
}, $true))
if ($accessibilityHresultFunctions.Count -ne 2) {
    throw 'Accessibility harness must define exactly one exception-chain helper and one transient-HRESULT classifier.'
}
foreach ($function in $accessibilityHresultFunctions) {
    . ([scriptblock]::Create($function.Extent.Text))
}
foreach ($knownHresult in @([int]0x80010001, [int]0x8001010A, [int]0x80040201)) {
    $knownException = [Runtime.InteropServices.COMException]::new('known transient', $knownHresult)
    $directChain = @(Get-AccessibilityExceptionHResults -Exception $knownException)
    $wrappedChain = @(Get-AccessibilityExceptionHResults -Exception ([Exception]::new('wrapper', $knownException)))
    if ($directChain.Count -ne 1 -or $directChain[0] -ne $knownHresult -or
        $wrappedChain.Count -ne 2 -or $wrappedChain[-1] -ne $knownHresult -or
        -not (Test-AccessibilityTransientHResult -HResult $directChain[0]) -or
        -not (Test-AccessibilityTransientHResult -HResult $wrappedChain[-1])) {
        throw ('Accessibility transient HRESULT semantics failed for 0x{0:X8}.' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($knownHresult), 0))
    }
}
if (Test-AccessibilityTransientHResult -HResult ([int]0x80131501)) {
    throw 'Accessibility transient HRESULT classifier must reject the generic .NET wrapper result 0x80131501.'
}
if ($accessibilityHarnessText -notmatch 'ExpectedFocusedHwnd' -or
    $accessibilityHarnessText -notmatch 'sustained output command'' -ExpectedFocusedHwnd \$leftPane\.Hwnd' -or
    $accessibilityHarnessText -notmatch 'failed to remove terminal TextChanged handler') {
    throw 'Accessibility input ownership and UIA cleanup must remain exact and fail closed.'
}
$idleSoakStartCommands = @(
    Get-NamedCommands -Ast $accessibilityHarnessAst -Name 'Assert-AccessibilityInputOwner' |
        Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value 'settings-open idle soak'
        }
)
$idleSoakHighContrastCalls = @(
    Get-NamedCommands -Ast $accessibilityHarnessAst -Name 'Invoke-AccessibilityHighContrastProof'
)
if ($idleSoakStartCommands.Count -ne 1 -or
    $idleSoakHighContrastCalls.Count -ne 2 -or
    $accessibilityHarnessText -notmatch 'settings destruction and terminal focus restoration after idle soak') {
    throw 'Accessibility idle-soak evidence must own its input check, shared High Contrast proof, and observable terminal-focus restoration scenario.'
}
# The former offset window and cached-HWND local-name pins duplicated the scenario:
# its final evidence reports the restored foreground/focused HWNDs and fails if a
# refreshed Process object redirects recovery to the independent Settings window.

$settingsSourcePins = @(
    @{
        Pattern = 'const settings_header_control_count = 6;'
        Description = 'settings clipped-control header cardinality'
    },
    @{
        Pattern = 'const settings_clipped_control_count = settings_control_count - settings_header_control_count;'
        Description = 'settings clipped-control count derivation'
    },
    @{
        Pattern = 'for \(0\.\.settings_clipped_control_count\) \|index\|'
        Description = 'settings clipped-control traversal uses the named count'
    },
    @{
        Pattern = '(?s)fn syncClosePromptText\(self: \*SettingsWindow.*?setWindowTextUtf8\(text, closePromptText\(self\.save_in_flight\)\).*?fn closePromptText\(save_in_flight: bool\) \[\]const u8.*?fn closePromptMeasuredHeight\(self: \*SettingsWindow.*?utf8ToW\(&text_w, closePromptText\(self\.save_in_flight\)\)'
        Description = 'close prompt display and measurement share closePromptText'
    },
    @{
        Pattern = '(?s)clickedButton\(id, notify, BTN_SAVE\).*?IsWindowEnabled\(button\).*?IsWindowVisible\(button\).*?saveCommandCanDispatch\(\s*o\.close_prompt_visible,\s*o\.save_in_flight,\s*o\.close_posted,\s*button_enabled,\s*button_visible,\s*\).*?o\.save\(\)'
        Description = 'save dispatch revalidates the live prompt and button state'
    },
    @{
        Pattern = '(?s)fn validatedSectionClickFocusTarget\(source: \?HWND, expected: \?HWND\).*?source_hwnd == expected_hwnd.*?if \(clickedSection\(id, notify\)\) \|section\|.*?validatedSectionClickFocusTarget\(.*?o\.sectionButton\(section\).*?_ = SetFocus\(button\);.*?o\.setActiveSection\(section\);'
        Description = 'section clicks validate their focus target before selection'
    }
)
foreach ($pin in $settingsSourcePins) {
    if ($win32SettingsText -notmatch $pin.Pattern) {
        throw "Settings source invariant missing: $($pin.Description)."
    }
}
if ($win32SettingsText -match 'for\s*\(0\.\.27\)') {
    throw 'Settings clipped-control traversal must use settings_header_control_count, never the stale 0..27 magic number.'
}
if ($win32UiaWidgetsText -match 'UiaRaiseAutomationEvent\(') {
    throw 'Settings selection/focus events must route through the typed UIA event helpers, not raw UiaRaiseAutomationEvent.'
}
$selectionItemRoutes = [regex]::Matches(
    $win32UiaWidgetsText,
    'events\.raiseSelectionItemSelected\('
)
if ($selectionItemRoutes.Count -ne 2 -or
    $win32UiaWidgetsText -notmatch 'events\.raiseSelectionItemSelected\(&row\.base\);' -or
    $win32UiaWidgetsText -notmatch 'events\.raiseSelectionItemSelected\(&self\.base\);') {
    throw 'UIA selection-item-selected routing must have exactly the palette-row and settings-section helper calls.'
}
$boundedSelectionDispatch = '(?s)fn sendButtonClicked\(hwnd: com\.HWND\).*?SendMessageTimeoutW\(\s*parent,\s*WM_COMMAND,\s*@intCast\(control_id\),\s*@bitCast\(@intFromPtr\(hwnd\)\),\s*SMTO_BLOCK \| SMTO_ABORTIFHUNG,\s*settings_selection_timeout_ms,\s*&ignored'
if ($win32UiaWidgetsText -notmatch $boundedSelectionDispatch) {
    throw 'Settings UIA selection dispatch must synchronously use bounded SendMessageTimeoutW with SMTO_BLOCK, SMTO_ABORTIFHUNG, the selection timeout, and the child HWND payload.'
}
$focusProviderPins = @(
    @{
        Pattern = '(?s)pub fn raiseFocusChanged\(self: \*SettingsControlProvider\) void.*?events\.raiseFocusChanged\(&self\.base\);'
        Description = 'SettingsControlProvider focus-event publishing'
    },
    @{
        Pattern = '(?s)pub fn raiseFocusChanged\(self: \*SettingsSectionProvider\) void.*?events\.raiseFocusChanged\(&self\.base\);'
        Description = 'SettingsSectionProvider focus-event publishing'
    },
    @{
        Pattern = '(?s)const SettingsControlProvider = struct.*?constants\.UIA_HasKeyboardFocusPropertyId => out\.\* = com\.VARIANT\.fromBool\(\s*self\.role != \.text and hwndHasKeyboardFocus\(self\.hwnd\)'
        Description = 'SettingsControlProvider HasKeyboardFocus property reporting'
    },
    @{
        Pattern = '(?s)const SettingsSectionProvider = struct.*?constants\.UIA_HasKeyboardFocusPropertyId => out\.\* = com\.VARIANT\.fromBool\(hwndHasKeyboardFocus\(self\.hwnd\)\)'
        Description = 'SettingsSectionProvider HasKeyboardFocus property reporting'
    }
)
foreach ($pin in $focusProviderPins) {
    if ($win32UiaWidgetsText -notmatch $pin.Pattern) {
        throw "Settings UIA focus invariant missing: $($pin.Description)."
    }
}

$timeoutFunctions = @($resolutionSourceAsts[0].Ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-InteractiveWin11MessageTimeoutMs'
}, $true))
if ($timeoutFunctions.Count -ne 1) {
    throw 'Interactive message support must define one timeout helper.'
}
. ([scriptblock]::Create($timeoutFunctions[0].Extent.Text))
$timeoutProbeInvocations = 0
$timeoutFutureOutputs = @(
    $timeoutProbeInvocations++
    Get-InteractiveWin11MessageTimeoutMs -Deadline ([DateTime]::UtcNow.AddMilliseconds(750)) -Description 'contract future'
)
$timeoutExpiredMessage = $null
try {
    $timeoutProbeInvocations++
    Get-InteractiveWin11MessageTimeoutMs -Deadline ([DateTime]::UtcNow.AddMilliseconds(-1)) -Description 'contract timeout'
}
catch {
    $timeoutExpiredMessage = $_.Exception.Message
}
if ($timeoutProbeInvocations -ne 2 -or
    $timeoutFutureOutputs.Count -ne 1 -or
    [uint64]$timeoutFutureOutputs[0] -lt 1 -or
    [uint64]$timeoutFutureOutputs[0] -gt 1000 -or
    $timeoutExpiredMessage -ne 'Deadline elapsed before sending contract timeout.') {
    throw 'Message timeout behavior must return one bounded remaining duration and reject elapsed deadlines with the runner-visible diagnostic.'
}

$postMessageWrapperText = Get-PowerShellBlockText -Content $interactiveWin11LibText -HeaderPattern '^function Invoke-InteractiveWin11PostMessage'
$postWrapperTokens = $null
$postWrapperErrors = $null
$postWrapperAst = [System.Management.Automation.Language.Parser]::ParseInput($postMessageWrapperText, [ref]$postWrapperTokens, [ref]$postWrapperErrors)
$postWrapperFunctions = @($postWrapperAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
if ($postWrapperErrors.Count -ne 0 -or
    $postWrapperFunctions.Count -ne 1 -or
    $postWrapperFunctions[0].Name -ne 'Invoke-InteractiveWin11PostMessage') {
    throw 'Posted-message support must define one parseable wrapper.'
}
if (-not ('FlagshipPostMessageProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class FlagshipPostMessageProbe {
    public static bool Succeed = true;
    public static int ErrorToReturn = 0;
    public static int CallCount = 0;
    public static IntPtr LastHwnd = IntPtr.Zero;
    public static uint LastMessage = 0;
    public static UIntPtr LastWParam = UIntPtr.Zero;
    public static IntPtr LastLParam = IntPtr.Zero;
    public static bool PostMessageWithError(
        IntPtr hwnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        ref int lastError
    ) {
        CallCount++;
        LastHwnd = hwnd;
        LastMessage = message;
        LastWParam = wParam;
        LastLParam = lParam;
        lastError = ErrorToReturn;
        return Succeed;
    }
}
'@
}
$postWrapperProbeSource = $postWrapperFunctions[0].Extent.Text.Replace(
    '[InteractiveWin11MessageNativeV2]',
    '[FlagshipPostMessageProbe]'
)
. ([scriptblock]::Create($postWrapperProbeSource))
$script:postOwnerProbeCalls = [Collections.Generic.List[object]]::new()
function Assert-InteractiveWin11WindowOwner {
    param(
        [IntPtr] $Hwnd,
        [System.Diagnostics.Process] $Process,
        [string] $Description,
        [string] $Verb
    )
    $script:postOwnerProbeCalls.Add([pscustomobject]@{
        Hwnd = $Hwnd
        Process = $Process
        Description = $Description
        Verb = $Verb
    })
    return $true
}
$postWrapperInvocations = 0
$postLiveFailureMessage = $null
$postExitedMessage = $null
$postDeadlineMessage = $null
$exitedProbeProcess = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-Command', 'exit 19') -PassThru -Wait
try {
    $liveProbeProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $liveDeadline = [DateTime]::UtcNow.AddSeconds(5)
    $postWrapperInvocations++
    Invoke-InteractiveWin11PostMessage `
        -Hwnd ([IntPtr]41) `
        -Message 0x0111 `
        -WParam ([UIntPtr]73) `
        -LParam ([IntPtr]99) `
        -Deadline $liveDeadline `
        -Description 'contract live post' `
        -Process $liveProbeProcess
    if ([FlagshipPostMessageProbe]::CallCount -ne 1 -or
        [FlagshipPostMessageProbe]::LastHwnd -ne [IntPtr]41 -or
        [FlagshipPostMessageProbe]::LastMessage -ne [uint32]0x0111 -or
        [FlagshipPostMessageProbe]::LastWParam.ToUInt64() -ne [uint64]73 -or
        [FlagshipPostMessageProbe]::LastLParam -ne [IntPtr]99) {
        throw 'Live posted-message behavior must pass the exact HWND, message, WParam, and LParam to PostMessageWithError.'
    }

    [FlagshipPostMessageProbe]::Succeed = $false
    [FlagshipPostMessageProbe]::ErrorToReturn = 87
    try {
        $postWrapperInvocations++
        Invoke-InteractiveWin11PostMessage `
            -Hwnd ([IntPtr]42) `
            -Message 0x0401 `
            -WParam ([UIntPtr]74) `
            -LParam ([IntPtr]100) `
            -Deadline $liveDeadline `
            -Description 'contract native failure' `
            -Process $liveProbeProcess
    }
    catch {
        $postLiveFailureMessage = $_.Exception.Message
    }
    try {
        $postWrapperInvocations++
        Invoke-InteractiveWin11PostMessage -Hwnd ([IntPtr]1) -Message 0x0111 -Deadline ([DateTime]::UtcNow.AddSeconds(1)) -Description 'contract exited' -Process $exitedProbeProcess
    }
    catch {
        $postExitedMessage = $_.Exception.Message
    }
    try {
        $postWrapperInvocations++
        Invoke-InteractiveWin11PostMessage -Hwnd ([IntPtr]1) -Message 0x0111 -Deadline ([DateTime]::UtcNow.AddMilliseconds(-1)) -Description 'contract deadline' -Process ([System.Diagnostics.Process]::GetCurrentProcess())
    }
    catch {
        $postDeadlineMessage = $_.Exception.Message
    }
    if ($postWrapperInvocations -ne 4 -or
        $script:postOwnerProbeCalls.Count -ne 3 -or
        -not [object]::ReferenceEquals(
            $script:postOwnerProbeCalls[0].Process,
            $liveProbeProcess
        ) -or
        -not [object]::ReferenceEquals(
            $script:postOwnerProbeCalls[1].Process,
            $liveProbeProcess
        ) -or
        $script:postOwnerProbeCalls[2].Process.Id -ne $liveProbeProcess.Id -or
        @($script:postOwnerProbeCalls | Where-Object { $_.Verb -cne 'post' }).Count -ne 0 -or
        $script:postOwnerProbeCalls[0].Hwnd -ne [IntPtr]41 -or
        $script:postOwnerProbeCalls[0].Description -cne 'contract live post' -or
        $script:postOwnerProbeCalls[1].Hwnd -ne [IntPtr]42 -or
        $script:postOwnerProbeCalls[1].Description -cne 'contract native failure' -or
        $script:postOwnerProbeCalls[2].Hwnd -ne [IntPtr]1 -or
        $script:postOwnerProbeCalls[2].Description -cne 'contract deadline' -or
        $postLiveFailureMessage -cne
            'PostMessageW failed for contract native failure hwnd=42 with Win32 error 87.' -or
        [FlagshipPostMessageProbe]::CallCount -ne 2 -or
        [FlagshipPostMessageProbe]::LastHwnd -ne [IntPtr]42 -or
        [FlagshipPostMessageProbe]::LastMessage -ne [uint32]0x0401 -or
        [FlagshipPostMessageProbe]::LastWParam.ToUInt64() -ne [uint64]74 -or
        [FlagshipPostMessageProbe]::LastLParam -ne [IntPtr]100 -or
        $postExitedMessage -notlike 'Refusing to post contract exited because noctty already exited*' -or
        $postDeadlineMessage -ne 'Timed out waiting for contract deadline.') {
        $postDiagnostic = [ordered]@{
            invocations = $postWrapperInvocations
            owner_calls = $script:postOwnerProbeCalls.Count
            native_calls = [FlagshipPostMessageProbe]::CallCount
            hwnd = [FlagshipPostMessageProbe]::LastHwnd.ToInt64()
            message = [FlagshipPostMessageProbe]::LastMessage
            wparam = [FlagshipPostMessageProbe]::LastWParam.ToUInt64()
            lparam = [FlagshipPostMessageProbe]::LastLParam.ToInt64()
            native_failure = $postLiveFailureMessage
            exited = $postExitedMessage
            deadline = $postDeadlineMessage
        } | ConvertTo-Json -Compress
        throw "Posted-message behavior must preserve exact native arguments/ref last-error binding, fail closed on native failure, refuse exited processes, and reject elapsed deadlines before the native post. Diagnostic=$postDiagnostic"
    }
}
finally {
    [FlagshipPostMessageProbe]::Succeed = $true
    [FlagshipPostMessageProbe]::ErrorToReturn = 0
    [FlagshipPostMessageProbe]::CallCount = 0
    if ($null -ne $exitedProbeProcess) { $exitedProbeProcess.Dispose() }
    Remove-Item -LiteralPath Function:\Assert-InteractiveWin11WindowOwner -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Invoke-InteractiveWin11PostMessage -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name postOwnerProbeCalls -ErrorAction SilentlyContinue
}

$statefulPostedCommandText = Get-PowerShellBlockText -Content $statefulWin11LibText -HeaderPattern '^function Invoke-StatefulPostedCommand'
$statefulPostTokens = $null
$statefulPostErrors = $null
$statefulPostAst = [System.Management.Automation.Language.Parser]::ParseInput($statefulPostedCommandText, [ref]$statefulPostTokens, [ref]$statefulPostErrors)
$statefulPostFunctions = @($statefulPostAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
if ($statefulPostErrors.Count -ne 0 -or
    $statefulPostFunctions.Count -ne 1 -or
    $statefulPostFunctions[0].Name -ne 'Invoke-StatefulPostedCommand') {
    throw 'Stateful posted-command support must define one parseable wrapper.'
}
. ([scriptblock]::Create($statefulPostFunctions[0].Extent.Text))
$script:statefulPostProbeCalls = 0
$script:statefulPostProbe = $null
function Invoke-InteractiveWin11PostMessage {
    param(
        [IntPtr] $Hwnd,
        [uint32] $Message,
        [UIntPtr] $WParam = [UIntPtr]::Zero,
        [IntPtr] $LParam = [IntPtr]::Zero,
        [DateTime] $Deadline,
        [string] $Description,
        [System.Diagnostics.Process] $Process
    )
    $script:statefulPostProbeCalls++
    $script:statefulPostProbe = [pscustomobject]@{
        Hwnd = $Hwnd
        Message = $Message
        WParam = $WParam
        LParam = $LParam
        Deadline = $Deadline
        Description = $Description
        Process = $Process
    }
}
$statefulDeadline = [DateTime]::UtcNow.AddSeconds(5)
$statefulProcess = [System.Diagnostics.Process]::GetCurrentProcess()
try {
    Invoke-StatefulPostedCommand -Hwnd ([IntPtr]41) -Id 73 -Deadline $statefulDeadline -Process $statefulProcess
    if ($script:statefulPostProbeCalls -ne 1 -or
        $script:statefulPostProbe.Hwnd -ne [IntPtr]41 -or
        $script:statefulPostProbe.Message -ne [uint32]0x0111 -or
        $script:statefulPostProbe.WParam.ToUInt64() -ne [uint64]73 -or
        $script:statefulPostProbe.LParam -ne [IntPtr]::Zero -or
        $script:statefulPostProbe.Deadline -ne $statefulDeadline -or
        $script:statefulPostProbe.Description -ne 'WM_COMMAND id=73' -or
        $script:statefulPostProbe.Process.Id -ne $statefulProcess.Id) {
        throw 'Stateful posted-command behavior must forward the exact WM_COMMAND payload, deadline, description, and process once.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Invoke-StatefulPostedCommand -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Invoke-InteractiveWin11PostMessage -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-InteractiveWin11MessageTimeoutMs -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name statefulPostProbeCalls, statefulPostProbe -ErrorAction SilentlyContinue
}
