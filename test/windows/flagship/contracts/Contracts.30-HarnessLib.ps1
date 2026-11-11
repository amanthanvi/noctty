$publishedReleaseVerifierTokens = $null
$publishedReleaseVerifierErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(
    $publishedReleaseVerifierText,
    [ref]$publishedReleaseVerifierTokens,
    [ref]$publishedReleaseVerifierErrors
)
if ($publishedReleaseVerifierErrors.Count -ne 0) {
    throw "Published release verifier does not parse: $($publishedReleaseVerifierErrors[0].Message)"
}

$windowLibTokens = $null
$windowLibErrors = $null
$windowLibAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $interactiveWin11WindowLibText,
    [ref]$windowLibTokens,
    [ref]$windowLibErrors
)
if ($windowLibErrors.Count -ne 0) {
    throw "Interactive Win11 window library does not parse: $($windowLibErrors[0].Message)"
}
$windowLibAddTypes = @(Get-NamedCommands -Ast $windowLibAst -Name 'Add-Type')
$windowLibTypeDefinition = if ($windowLibAddTypes.Count -eq 1) {
    Get-CommandParameterArgument -Command $windowLibAddTypes[0] -Name 'TypeDefinition'
} else {
    $null
}
if ($windowLibTypeDefinition -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
    throw 'Interactive Win11 window library must define its native surface through one literal Add-Type command.'
}
$windowLibCSharp = $windowLibTypeDefinition.Value
$windowNativeClassDefinitions = [regex]::Matches(
    $windowLibCSharp,
    '(?m)^\s*public\s+static\s+class\s+InteractiveWin11WindowNative\s*\{'
)
$forceForegroundDefinitions = [regex]::Matches(
    $windowLibCSharp,
    '(?m)^\s*public\s+static\s+bool\s+ForceForeground\s*\(\s*IntPtr\s+hWnd,\s*bool\s+altTap,\s*bool\s+useSendInputForAltTap\s*\)'
)
if ($windowNativeClassDefinitions.Count -ne 1 -or
    $forceForegroundDefinitions.Count -ne 1) {
    throw 'Interactive Win11 window library must own exactly one native class and one three-argument ForceForeground method.'
}
$forceForegroundOpenBrace = $windowLibCSharp.IndexOf(
    '{',
    $forceForegroundDefinitions[0].Index + $forceForegroundDefinitions[0].Length
)
$forceForegroundEnd = -1
$forceForegroundDepth = 0
if ($forceForegroundOpenBrace -ge 0) {
    for ($index = $forceForegroundOpenBrace; $index -lt $windowLibCSharp.Length; $index++) {
        if ($windowLibCSharp[$index] -eq '{') {
            $forceForegroundDepth++
        } elseif ($windowLibCSharp[$index] -eq '}') {
            $forceForegroundDepth--
            if ($forceForegroundDepth -eq 0) {
                $forceForegroundEnd = $index
                break
            }
        }
    }
}
if ($forceForegroundEnd -lt 0) {
    throw 'ForceForeground must have one balanced method body.'
}
$forceForegroundMethod = $windowLibCSharp.Substring(
    $forceForegroundDefinitions[0].Index,
    $forceForegroundEnd - $forceForegroundDefinitions[0].Index + 1
)
$altTapStrategies = [regex]::Matches(
    $forceForegroundMethod,
    '(?s)if\s*\(\s*altTap\s*\)\s*\{\s*if\s*\(\s*useSendInputForAltTap\s*\)\s*\{(?<sendInput>.*?)\}\s*else\s*\{(?<keybdEvent>.*?)\}\s*\}'
)
$attachInputCalls = [regex]::Matches(
    $forceForegroundMethod,
    'AttachThreadInput\s*\([^;]+,\s*(?<attach>true|false)\s*\)'
)
$attachTrueCalls = @($attachInputCalls | Where-Object { $_.Groups['attach'].Value -ceq 'true' })
$attachFalseCalls = @($attachInputCalls | Where-Object { $_.Groups['attach'].Value -ceq 'false' })
$forceForegroundReturns = [regex]::Matches(
    $forceForegroundMethod,
    '\breturn\b[^;]*;'
)
$forceForegroundHasExactReturn = $forceForegroundReturns.Count -eq 1 -and
    $forceForegroundReturns[0].Value -cmatch
        '^return\s+GetForegroundWindow\s*\(\s*\)\s*==\s*hWnd\s*;$'
if ($altTapStrategies.Count -ne 1 -or
    $altTapStrategies[0].Groups['sendInput'].Value -notmatch '\bSubmitInputs\s*\(' -or
    $altTapStrategies[0].Groups['keybdEvent'].Value -notmatch '\bkeybd_event\s*\(' -or
    $attachTrueCalls.Count -ne 2 -or
    $attachFalseCalls.Count -ne 2 -or
    -not $forceForegroundHasExactReturn -or
    $forceForegroundMethod -notmatch '(?s)\btry\s*\{.*?\bSetForegroundWindow\s*\(\s*hWnd\s*\).*?return\s+GetForegroundWindow\s*\(\s*\)\s*==\s*hWnd\s*;.*?\bfinally\s*\{') {
    throw 'ForceForeground must preserve SendInput and keybd_event Alt-tap strategies plus the paired AttachThreadInput handshake.'
}

$windowLibConsumerSources = @(
    [pscustomobject]@{ Path = $accessibilityHarness; Text = $accessibilityHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $imeCandidateHarness; Text = $imeCandidateHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $keyInputHarness; Text = $keyInputHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $newTabHarness; Text = $newTabHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $shellCommandLiveHarness; Text = $shellCommandLiveHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $statefulWin11Lib; Text = $statefulWin11LibText; DotSource = ". (Join-Path (Split-Path -Parent (Split-Path -Parent `$PSScriptRoot)) 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $undoHarness; Text = $undoHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" }
)
$windowLibConsumerAsts = foreach ($source in $windowLibConsumerSources) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $source.Text,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) {
        throw "Interactive window-library consumer does not parse: $($source.Path) ($($errors[0].Message))"
    }
    $matchingDotSources = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and
            $node.Extent.Text.Trim() -ceq $source.DotSource
    }, $true))
    if ($matchingDotSources.Count -ne 1) {
        throw "Interactive harness must dot-source the shared window library exactly once: $($source.Path)"
    }
    [pscustomobject]@{ Path = $source.Path; Ast = $ast }
}

$forceForegroundCallContracts = @(
    [pscustomobject]@{ Path = $accessibilityHarness; Count = 20; AltTap = 'true'; SendInputAltTap = 'true' },
    [pscustomobject]@{ Path = $keyInputHarness; Count = 5; AltTap = 'false'; SendInputAltTap = 'false' },
    [pscustomobject]@{ Path = $shellCommandLiveHarness; Count = 2; AltTap = 'true'; SendInputAltTap = 'false' },
    [pscustomobject]@{ Path = $statefulWin11Lib; Count = 1; AltTap = 'true'; SendInputAltTap = 'true' }
)
foreach ($contract in $forceForegroundCallContracts) {
    $sourceAst = @($windowLibConsumerAsts | Where-Object { $_.Path -eq $contract.Path })[0].Ast
    $calls = @(Get-NamedMemberExpressions -Ast $sourceAst -Name 'ForceForeground' -InvocationOnly)
    $invalidCalls = @($calls | Where-Object {
        $_.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst] -or
        $_.Expression.TypeName.FullName -cne 'InteractiveWin11WindowNative' -or
        $_.Arguments.Count -ne 3 -or
        $_.Arguments[1] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        $_.Arguments[1].VariablePath.UserPath -cne $contract.AltTap -or
        $_.Arguments[2] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        $_.Arguments[2].VariablePath.UserPath -cne $contract.SendInputAltTap
    })
    if ($calls.Count -ne $contract.Count -or $invalidCalls.Count -ne 0) {
        throw "ForceForeground strategy arguments changed: $($contract.Path) (expected $($contract.Count) calls with `$$($contract.AltTap), `$$($contract.SendInputAltTap))."
    }
}

$windowNativeShadowDefinitions = @(
    foreach ($searchRoot in @(
        (Join-Path $repoRoot 'test\windows'),
        (Join-Path $repoRoot 'scripts')
    )) {
        foreach ($sourceFile in Get-ChildItem -LiteralPath $searchRoot -File -Recurse) {
            if ([string]::Equals(
                    $sourceFile.FullName,
                    $interactiveWin11WindowLib,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                continue
            }
            try {
                $sourceText = Get-Content -LiteralPath $sourceFile.FullName -Raw -ErrorAction Stop
            }
            catch {
                throw "InteractiveWin11WindowNative shadow scan could not read $($sourceFile.FullName): $($_.Exception.Message)"
            }
            $definitionCount = [regex]::Matches(
                $sourceText,
                '(?ims)^\s*(?:(?:public|internal|private|protected|static|sealed|abstract|partial|new|unsafe|readonly|ref)\s+|\[[^\]]+\]\s*)*(?:class|struct)\s+InteractiveWin11WindowNative\b'
            ).Count
            if ($definitionCount -gt 0) {
                [pscustomobject]@{ Path = $sourceFile.FullName; Count = $definitionCount }
            }
        }
    }
)
if ($windowNativeShadowDefinitions.Count -ne 0) {
    throw "InteractiveWin11WindowNative must not be shadowed outside the shared window library: $($windowNativeShadowDefinitions.Path -join ', ')"
}

$resolutionSourceAsts = foreach ($source in @(
    [pscustomobject]@{ Path = $interactiveWin11Lib; Text = $interactiveWin11LibText },
    [pscustomobject]@{ Path = $statefulWin11Lib; Text = $statefulWin11LibText }
)) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source.Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "PowerShell resolution source does not parse: $($source.Path) ($($errors[0].Message))" }
    [pscustomobject]@{ Path = $source.Path; Ast = $ast; Tokens = $tokens }
}
foreach ($source in $resolutionSourceAsts) {
    $expectedDotSources = if ($source.Path -eq $statefulWin11Lib) {
        @(". (Join-Path (Split-Path -Parent (Split-Path -Parent `$PSScriptRoot)) 'scripts\interactive-win11-window-lib.ps1')")
    } else {
        @(". (Join-Path `$PSScriptRoot 'interactive-win11-measure-lib.ps1')")
    }
    $expectedAmpersands = if ($source.Path -eq $interactiveWin11Lib) {
        @(
            '& $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $LauncherPath @ArgumentList',
            '& cmd /c $devWindowsCmd zig build -Demit-exe=true @optimizeArguments',
            '& $Condition',
            '& $Condition'
        )
    } else { @() }
    Assert-CommandResolutionContract -Ast $source.Ast -Tokens $source.Tokens -Context $source.Path -ExpectedDotSources $expectedDotSources -ExpectedAmpersandCommands $expectedAmpersands
    $definitions = @($source.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($name in @('Get-InteractiveWin11MessageTimeoutMs', 'Assert-InteractiveWin11WindowOwner', 'Invoke-InteractiveWin11PostMessage', 'Invoke-StatefulPostedCommand')) {
        $expected = if ($source.Path -eq $interactiveWin11Lib) {
            if ($name -eq 'Invoke-StatefulPostedCommand') { 0 } else { 1 }
        } else {
            if ($name -eq 'Invoke-StatefulPostedCommand') { 1 } else { 0 }
        }
        if (@($definitions | Where-Object { ($_.Name -replace '^(?i)(?:global|script|local|private):', '') -eq $name }).Count -ne $expected) {
            throw "Interactive library has the wrong ownership count for protected function $name`: $($source.Path)"
        }
    }
}
# The window library the stateful library dot-sources is held to the same
# command-resolution rules (no alias, no command-resolution mutation, no dot
# source or call operator), since an alias it defines would outrank the
# stateful library's functions (EVIDENCE-FOREGROUND-01).
Assert-CommandResolutionContract -Ast $windowLibAst -Tokens $windowLibTokens -Context $interactiveWin11WindowLib -ExpectedDotSources @() -ExpectedAmpersandCommands @()
$interactiveWin11LibAst = @($resolutionSourceAsts | Where-Object { $_.Path -eq $interactiveWin11Lib })[0].Ast
$waitUntilFunctions = @($interactiveWin11LibAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Wait-InteractiveWin11Until'
}, $true))
if ($waitUntilFunctions.Count -ne 1) {
    throw 'Interactive harness library must own exactly one Wait-InteractiveWin11Until function.'
}
. ([scriptblock]::Create($waitUntilFunctions[0].Extent.Text))
$waitUntilCurrentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
try {
    & {
        $Process = 'caller-process-sentinel'
        Wait-InteractiveWin11Until `
            -Condition { $Process -ceq 'caller-process-sentinel' } `
            -Description 'caller Process binding contract' `
            -Deadline ([DateTime]::UtcNow.AddSeconds(1)) `
            -PollMilliseconds 1 `
            -ConditionFirst `
            -TimeoutMessage 'Wait-InteractiveWin11Until shadowed the caller Process variable.'
    }
    Wait-InteractiveWin11Until `
        -Condition { $true } `
        -Description 'Process alias binding contract' `
        -Deadline ([DateTime]::UtcNow.AddSeconds(1)) `
        -Process $waitUntilCurrentProcess `
        -ConditionFirst
}
finally {
    $waitUntilCurrentProcess.Dispose()
    Remove-Item -LiteralPath Function:\Wait-InteractiveWin11Until -ErrorAction SilentlyContinue
}

# A wait whose condition read screen pixels records what was on screen when it
# times out; any other wait, including the next one, does not
# (EVIDENCE-PIXEL-DIAG-01). Get-StatefulPixel is what names the window.
$statefulLibAst = @($resolutionSourceAsts | Where-Object { $_.Path -eq $statefulWin11Lib })[0].Ast
$pixelReaders = @($statefulLibAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-StatefulPixel'
}, $true))
if ($pixelReaders.Count -ne 1 -or
    $pixelReaders[0].Body.EndBlock.Statements[0].Extent.Text -cne '$script:InteractiveWin11PixelWindow = $Hwnd') {
    throw 'Get-StatefulPixel must first name the window it reads for the pixel-timeout diagnostic.'
}
. ([scriptblock]::Create($waitUntilFunctions[0].Extent.Text))
$script:pixelDiagnosticCalls = [Collections.Generic.List[string]]::new()
function script:Save-StatefulPixelDiagnostic {
    param([IntPtr] $Hwnd, [string] $Description)
    $script:pixelDiagnosticCalls.Add("$($Hwnd.ToInt64()):$Description")
    'pixel diagnostic: contract'
}
try {
    $pixelTimeoutMessages = foreach ($case in @(
            @{ Description = 'contract pixel wait'; Condition = { $script:InteractiveWin11PixelWindow = [IntPtr]77; $false } },
            @{ Description = 'contract plain wait'; Condition = { $false } }
        )) {
        try {
            # ConditionFirst: the condition runs at least once however late.
            Wait-InteractiveWin11Until -Condition $case.Condition -Description $case.Description `
                -Deadline ([DateTime]::UtcNow.AddMilliseconds(50)) -PollMilliseconds 5 -ConditionFirst
            'no timeout'
        }
        catch { $_.Exception.Message }
    }
    if (($pixelTimeoutMessages -join '|') -cne 'Timed out waiting for contract pixel wait; pixel diagnostic: contract|Timed out waiting for contract plain wait' -or
        ($script:pixelDiagnosticCalls -join '|') -cne '77:contract pixel wait') {
        throw "Pixel-wait timeouts must carry the diagnostic and other timeouts must not: $($pixelTimeoutMessages -join ' | ')"
    }
}
finally {
    Remove-Item -LiteralPath Function:\Wait-InteractiveWin11Until, Function:\Save-StatefulPixelDiagnostic -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name pixelDiagnosticCalls, InteractiveWin11PixelWindow -ErrorAction SilentlyContinue
}

# Show-StatefulHost takes the foreground back from another application with
# ForceForeground, and only then (EVIDENCE-FOREGROUND-01). Its one call, on
# $HostHwnd, sits in the body of an `if` whose whole condition re-reads the
# foreground's process (the recheck below), and that `if` sits in the body of
# one whose whole condition is the Test-StatefulForeignForeground call below:
# no negation, no other operand, the arguments in order, no other clause. The
# host's process id comes from $HostHwnd and the foreground's from
# Get-StatefulForegroundProcessId, which reads GetForegroundWindow; and each
# name comes from Get-StatefulProcessName on its own id. Show-StatefulHost is
# also pinned statement for statement, like its two helpers, so any other edit
# to its code (another write to one of its variables in any form, a removed
# sleep, an early return, a trap or clean block) fails here until the pinned
# copy below is updated with it. The decision's answers are table-tested, and
# the behaviour run below checks what the function does. The controls below
# must each parse and be refused.
# PowerShell resolves function names without regard to case or a scope prefix
# (`script:`, `global:` ...), so a second definition spelled either way counts
# as a second one (controls below); depending on where the library is loaded,
# that copy can be the one that runs. The pinned code calls its cmdlets
# module-qualified, which no plain-named function or alias can stand in for.
# PowerShell would still accept a function named with the qualified name
# itself (`function Microsoft.PowerShell.Management\Get-Process {}`), and
# $PSDefaultParameterValues or $InformationPreference set at a library's top
# level would reach the pinned calls (the latter set to Ignore silences the
# pinned Write-Host), so none of the libraries the pinned code is loaded with
# (this one, the window library it dot-sources, and the interactive, measure
# and history libraries its calling harnesses dot-source first) may define a
# function whose name contains `\`, or name either variable anywhere (as a
# variable or as the -Name of Set-Variable, sv, New-Variable or Get-Variable).
# Deliberately obfuscated definitions (a function drive path built from a
# string, a wildcard variable name) are out of reach of these text checks.
$statefulFunctionName = { param([string] $Name) $Name -replace '^(?i)(?:global|script|local|private):', '' }
$libraryRewiring = {
    param($Ast)
    $qualifiedDefinitions = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and (& $statefulFunctionName $node.Name).Contains('\')
    }, $true) | ForEach-Object { "function $($_.Name)" })
    # The names anywhere in the text, not only as variables: Set-Variable, sv,
    # New-Variable and Get-Variable reach them by name too.
    $preferences = @('PSDefaultParameterValues', 'InformationPreference' | Where-Object { $Ast.Extent.Text -match "(?i)$_" })
    @($qualifiedDefinitions) + @($preferences)
}
# The harnesses that call Show-StatefulHost (palette-theme, shaders), like
# every harness that loads the stateful library, dot-source
# scripts/windows-harness-history.ps1 and scripts/interactive-win11-lib.ps1
# (which dot-sources the measure library) first, so those three are held to the
# same refusals. The interactive library is already under the command-resolution
# contract above; the measure and history libraries are put under it here (no
# alias, no command-resolution mutation, no dot source or call operator), since
# an alias either defines would outrank the stateful library's functions
# whatever the load order (CodeRabbit).
$siblingLibraries = foreach ($sibling in @(@{ Name = 'measure'; File = 'interactive-win11-measure-lib.ps1' }, @{ Name = 'history'; File = 'windows-harness-history.ps1' })) {
    $siblingPath = Join-Path $repoRoot "scripts\$($sibling.File)"
    $siblingTokens = $null
    $siblingErrors = $null
    $siblingAst = [System.Management.Automation.Language.Parser]::ParseFile($siblingPath, [ref]$siblingTokens, [ref]$siblingErrors)
    if ($siblingErrors.Count -ne 0) { throw "scripts\$($sibling.File) does not parse: $($siblingErrors[0].Message)" }
    Assert-CommandResolutionContract -Ast $siblingAst -Tokens $siblingTokens -Context $siblingPath -ExpectedDotSources @() -ExpectedAmpersandCommands @()
    foreach ($resolutionControl in @(
            'Set-Alias -Name Get-StatefulForegroundProcessId -Value Get-Date',
            'New-Alias Test-StatefulForeignForeground Get-Date',
            '${function:global:Microsoft.PowerShell.Utility\Start-Sleep} = { }',
            '[scriptblock]${function:global:Microsoft.PowerShell.Utility\Start-Sleep} = { param($Milliseconds) }',
            "Set-Item 'function:Microsoft.PowerShell.Management\Get-Process' { }",
            'New-Module -Name Microsoft.PowerShell.Utility { function Write-Host { } } | Import-Module')) {
        $resolutionTokens = $null
        $resolutionErrors = $null
        $resolutionAst = [System.Management.Automation.Language.Parser]::ParseInput("$($siblingAst.Extent.Text)`n$resolutionControl`n", [ref]$resolutionTokens, [ref]$resolutionErrors)
        if ($resolutionErrors.Count -ne 0) { throw "Command-resolution control '$resolutionControl' does not parse with scripts\$($sibling.File)." }
        $resolutionRefused = $false
        try { Assert-CommandResolutionContract -Ast $resolutionAst -Tokens $resolutionTokens -Context "control: $resolutionControl" -ExpectedDotSources @() -ExpectedAmpersandCommands @() } catch { $resolutionRefused = $true }
        if (-not $resolutionRefused) { throw "The command-resolution contract accepted '$resolutionControl' in scripts\$($sibling.File)." }
    }
    @{ Name = $sibling.Name; Ast = $siblingAst }
}
foreach ($library in @(
        @{ Name = 'stateful'; Ast = $statefulLibAst },
        @{ Name = 'window'; Ast = $windowLibAst },
        @{ Name = 'interactive'; Ast = $interactiveWin11LibAst }) + @($siblingLibraries)) {
    $rewiring = @(& $libraryRewiring $library.Ast)
    if ($rewiring.Count -ne 0) {
        throw "The $($library.Name) library must not define a function named with a module-qualified name, or name `$PSDefaultParameterValues or `$InformationPreference anywhere, comments included (found $($rewiring -join ', '))."
    }
}
foreach ($rewiringControl in @(
        @{ Base = $statefulWin11LibText; Add = 'function Microsoft.PowerShell.Management\Get-Process { }' },
        @{ Base = $statefulWin11LibText; Add = 'function script:Microsoft.PowerShell.Utility\Start-Sleep { }' },
        @{ Base = $interactiveWin11WindowLibText; Add = 'function Microsoft.PowerShell.Utility\Write-Host { }' },
        @{ Base = $statefulWin11LibText; Add = "`$PSDefaultParameterValues['Write-Host:InformationAction'] = 'Ignore'" },
        @{ Base = $interactiveWin11WindowLibText; Add = "`$global:PSDefaultParameterValues['Get-Process:IncludeUserName'] = `$true" },
        @{ Base = $statefulWin11LibText; Add = "Set-Variable -Name PSDefaultParameterValues -Value @{ 'Get-Process:Module' = `$true }" },
        @{ Base = $interactiveWin11WindowLibText; Add = "sv PSDefaultParameterValues @{ 'Write-Host:InformationAction' = 'Ignore' }" },
        @{ Base = $statefulWin11LibText; Add = "(Get-Variable PSDefaultParameterValues -ValueOnly)['Write-Host:InformationAction'] = 'Ignore'" },
        @{ Base = $interactiveWin11LibText; Add = "`$PSDefaultParameterValues['*:InformationAction'] = 'Ignore'" },
        @{ Base = $interactiveWin11LibText; Add = 'function Microsoft.PowerShell.Utility\Start-Sleep { }' },
        @{ Base = $statefulWin11LibText; Add = "`$InformationPreference = 'Ignore'" },
        @{ Base = $interactiveWin11LibText; Add = "Set-Variable -Name InformationPreference -Value 'Ignore' -Scope Global" }
    )) {
    $rewiringTokens = $null
    $rewiringErrors = $null
    $rewiringAst = [System.Management.Automation.Language.Parser]::ParseInput("$($rewiringControl.Base)`n$($rewiringControl.Add)`n", [ref]$rewiringTokens, [ref]$rewiringErrors)
    if ($rewiringErrors.Count -ne 0) { throw "Library rewiring control '$($rewiringControl.Add)' does not parse." }
    if (@(& $libraryRewiring $rewiringAst).Count -eq 0) { throw "The library rewiring check accepted '$($rewiringControl.Add)'." }
}
$statefulDefinitions = {
    param($Ast, [string] $Name)
    @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and (& $statefulFunctionName $node.Name) -eq $Name
    }, $true))
}
$statefulFunction = { param([string] $Name) & $statefulDefinitions $statefulLibAst $Name }
$showHostFunctions = @(& $statefulFunction 'Show-StatefulHost')
$foreignForegroundFunctions = @(& $statefulFunction 'Test-StatefulForeignForeground')
$foregroundProcessIdFunctions = @(& $statefulFunction 'Get-StatefulForegroundProcessId')
$processNameFunctions = @(& $statefulFunction 'Get-StatefulProcessName')
if ($showHostFunctions.Count -ne 1 -or $foreignForegroundFunctions.Count -ne 1 -or $foregroundProcessIdFunctions.Count -ne 1 -or $processNameFunctions.Count -ne 1) {
    throw 'The stateful library must define Show-StatefulHost, Test-StatefulForeignForeground, Get-StatefulForegroundProcessId and Get-StatefulProcessName once each.'
}
foreach ($protectedName in @('Show-StatefulHost', 'Test-StatefulForeignForeground', 'Get-StatefulForegroundProcessId', 'Get-StatefulProcessName')) {
    foreach ($spelling in @("script:$protectedName", "global:$protectedName", "local:$protectedName", "private:$protectedName", $protectedName.ToLowerInvariant())) {
        $duplicateTokens = $null
        $duplicateErrors = $null
        $duplicateAst = [System.Management.Automation.Language.Parser]::ParseInput("$statefulWin11LibText`nfunction $spelling { }`n", [ref]$duplicateTokens, [ref]$duplicateErrors)
        if ($duplicateErrors.Count -ne 0 -or @(& $statefulDefinitions $duplicateAst $protectedName).Count -ne 2) {
            throw "The once-each check must count a second definition spelled 'function $spelling'."
        }
    }
}
# Show-StatefulHost and both helpers are pinned statement for statement (line
# endings aside; comments between top-level statements are free), with no
# trap, no other named block and the parameters as given, so no code can be
# added, removed or rewritten in them without updating this copy.
$showHostPinnedIf = @'
if (Test-StatefulForeignForeground $hostProcessId $hostProcessName $foregroundProcessId $foregroundProcessName) {
        # Reading the names takes a moment: send nothing if the foreground has
        # moved to another process since. ForceForeground sends its Alt tap
        # before it reads the foreground again, so a change in the few
        # milliseconds between this check and the tap is not covered.
        if ((Get-StatefulForegroundProcessId) -eq $foregroundProcessId) {
            $taken = [InteractiveWin11WindowNative]::ForceForeground($HostHwnd, $true, $true)
            [void][InteractiveWin11WindowNative]::SetWindowPos($HostHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0043)
            $outcome = if ($taken) { 'took it back' } else { 'did not take it back' }
            Microsoft.PowerShell.Utility\Write-Host "Show-StatefulHost: process '$foregroundProcessName' held the foreground; ForceForeground $outcome."
        }
    }
'@
$showHostPin = @{ Function = $showHostFunctions[0]; Parameters = '[IntPtr] $HostHwnd'; Statements = @(
    '[void][InteractiveWin11WindowNative]::ShowWindow($HostHwnd, 9)',
    '[void][InteractiveWin11WindowNative]::SetWindowPos($HostHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0043)',
    '[void][InteractiveWin11WindowNative]::SetForegroundWindow($HostHwnd)',
    '$hostProcessId = [uint32]0',
    '[void][InteractiveWin11WindowNative]::GetWindowThreadProcessId($HostHwnd, [ref]$hostProcessId)',
    '$foregroundProcessId = Get-StatefulForegroundProcessId',
    '$hostProcessName = Get-StatefulProcessName $hostProcessId',
    '$foregroundProcessName = Get-StatefulProcessName $foregroundProcessId',
    $showHostPinnedIf,
    'Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $script:STATEFUL_HOST_SETTLE_MS') }
$pinnedFunctions = @(
    @{ Function = $foregroundProcessIdFunctions[0]; Parameters = $null; Statements = @(
        '$processId = [uint32]0',
        '[void][InteractiveWin11WindowNative]::GetWindowThreadProcessId([InteractiveWin11WindowNative]::GetForegroundWindow(), [ref]$processId)',
        'return $processId') },
    @{ Function = $processNameFunctions[0]; Parameters = '[uint32] $ProcessId'; Statements = @(
        'if ($ProcessId -eq 0) { return $null }',
        'try { return (Microsoft.PowerShell.Management\Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName } catch { return $null }') },
    $showHostPin
)
$matchesPin = {
    param([System.Management.Automation.Language.FunctionDefinitionAst] $Function, $Pin)
    $body = $Function.Body
    $parameters = if ($null -eq $Function.Parameters) { $null } else { ($Function.Parameters | ForEach-Object { $_.Extent.Text }) -join ', ' }
    $statements = (($body.EndBlock.Statements | ForEach-Object { $_.Extent.Text }) -join "`n") -replace "`r`n", "`n"
    # A trap body sits in NamedBlockAst.Traps, not in Statements, and PowerShell
    # 7.3 added a clean block; none of the pinned functions has either.
    $cleanBlock = if ($body.PSObject.Properties['CleanBlock']) { $body.CleanBlock } else { $null }
    return (@($body.EndBlock.Traps).Where({ $null -ne $_ }).Count -eq 0 -and $null -eq $cleanBlock -and
        $null -eq $body.ParamBlock -and $null -eq $body.BeginBlock -and $null -eq $body.ProcessBlock -and $null -eq $body.DynamicParamBlock -and
        $parameters -ceq $Pin.Parameters -and $statements -ceq (($Pin.Statements -join "`n") -replace "`r`n", "`n"))
}
foreach ($pin in $pinnedFunctions) {
    if (-not (& $matchesPin $pin.Function $pin)) {
        # Name the first statement, and the first line in it, that differs, so a
        # maintainer need not diff by hand.
        $endStatements = if ($null -eq $pin.Function.Body.EndBlock) { @() } else { @($pin.Function.Body.EndBlock.Statements) }
        $actualStatements = @($endStatements | Where-Object { $null -ne $_ } | ForEach-Object { $_.Extent.Text -replace "`r`n", "`n" })
        $pinnedStatements = @($pin.Statements | ForEach-Object { $_ -replace "`r`n", "`n" })
        $index = 0
        while ($index -lt $actualStatements.Count -and $index -lt $pinnedStatements.Count -and $actualStatements[$index] -ceq $pinnedStatements[$index]) { $index++ }
        $where = if ($index -lt $actualStatements.Count -or $index -lt $pinnedStatements.Count) {
            # @() around the whole if: assigning an if's output unwraps a
            # one-line statement into a string, which then indexes by character.
            $actualLines = @(if ($index -lt $actualStatements.Count) { $actualStatements[$index] -split "`n" })
            $pinnedLines = @(if ($index -lt $pinnedStatements.Count) { $pinnedStatements[$index] -split "`n" })
            $line = 0
            while ($line -lt $actualLines.Count -and $line -lt $pinnedLines.Count -and $actualLines[$line] -ceq $pinnedLines[$line]) { $line++ }
            $actualLine = if ($line -lt $actualLines.Count) { $actualLines[$line].Trim() } else { '(none)' }
            $pinnedLine = if ($line -lt $pinnedLines.Count) { $pinnedLines[$line].Trim() } else { '(none)' }
            "statement $($index + 1), line $($line + 1) of it, is '$actualLine', pinned '$pinnedLine'"
        } else {
            'the statements match, so a trap, another named block or the parameters differ'
        }
        throw "$($pin.Function.Name) must match its pinned copy in Contracts.30-HarnessLib.ps1 statement for statement ($where); update the copy with any intended change."
    }
}
# The name helper also runs: id 0, this process, and an id no process has.
. ([scriptblock]::Create($processNameFunctions[0].Extent.Text))
try {
    $currentProcessName = [Diagnostics.Process]::GetCurrentProcess().ProcessName
    if ($null -ne (Get-StatefulProcessName 0) -or (Get-StatefulProcessName ([uint32]$PID)) -cne $currentProcessName -or
        $null -ne (Get-StatefulProcessName ([uint32]::MaxValue - 3))) {
        throw 'Get-StatefulProcessName must answer $null for 0 and for an id no process has, and the name for a live process.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-StatefulProcessName -ErrorAction SilentlyContinue
}
$showHostGuardCall = 'Test-StatefulForeignForeground $hostProcessId $hostProcessName $foregroundProcessId $foregroundProcessName'
$showHostRecheck = '(Get-StatefulForegroundProcessId) -eq $foregroundProcessId'
$showHostHostRead = '[void][InteractiveWin11WindowNative]::GetWindowThreadProcessId($HostHwnd, [ref]$hostProcessId)'
$showHostForegroundRead = '$foregroundProcessId = Get-StatefulForegroundProcessId'
$showHostHostNameRead = '$hostProcessName = Get-StatefulProcessName $hostProcessId'
$showHostForegroundNameRead = '$foregroundProcessName = Get-StatefulProcessName $foregroundProcessId'
$testShowHostGuard = {
    param([System.Management.Automation.Language.FunctionDefinitionAst] $Function)
    $text = $Function.Extent.Text
    foreach ($required in @($showHostHostRead, $showHostForegroundRead, $showHostHostNameRead, $showHostForegroundNameRead)) {
        if (([regex]::Matches($text, [regex]::Escape($required))).Count -ne 1) { return $false }
    }
    # A quick check that each of the four has one plain `=` write; the pin above
    # is what refuses every other form of write.
    foreach ($variable in @('hostProcessId', 'hostProcessName', 'foregroundProcessId', 'foregroundProcessName')) {
        if (([regex]::Matches($text, "\`$$variable\s*=(?!=)")).Count -ne 1) { return $false }
    }
    if (([regex]::Matches($text, '\[ref\]\$hostProcessId')).Count -ne 1) { return $false }
    $calls = @(Get-NamedMemberExpressions -Ast $Function.Body -Name 'ForceForeground' -InvocationOnly)
    if ($calls.Count -ne 1 -or $calls[0].Arguments.Count -ne 3 -or
        $calls[0].Arguments[0] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        $calls[0].Arguments[0].VariablePath.UserPath -cne 'HostHwnd') { return $false }
    # Innermost first: the recheck, then the guard.
    $inner = $calls[0]
    foreach ($expected in @(@{ Text = $showHostRecheck; Command = $false }, @{ Text = $showHostGuardCall; Command = $true })) {
        $if = $inner.Parent
        while ($null -ne $if -and $if -isnot [System.Management.Automation.Language.IfStatementAst]) { $if = $if.Parent }
        if ($null -eq $if -or $if.Clauses.Count -ne 1 -or $null -ne $if.ElseClause) { return $false }
        $condition = $if.Clauses[0].Item1
        if ($condition -isnot [System.Management.Automation.Language.PipelineAst] -or $condition.PipelineElements.Count -ne 1 -or
            $condition.PipelineElements[0].Extent.Text -cne $expected.Text -or
            ($expected.Command -and $condition.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandAst])) { return $false }
        $inBody = $false
        for ($node = $inner; $null -ne $node; $node = $node.Parent) {
            if ([object]::ReferenceEquals($node, $if.Clauses[0].Item2)) { $inBody = $true; break }
        }
        if (-not $inBody) { return $false }
        $inner = $if
    }
    return $true
}
if (-not (& $testShowHostGuard $showHostFunctions[0])) {
    throw 'Show-StatefulHost must call ForceForeground once, on $HostHwnd, only under the foreground recheck inside an if whose whole condition is Test-StatefulForeignForeground, with both process ids and both names read once from their sources.'
}
$showHostText = $showHostFunctions[0].Extent.Text
$showHostGuardLine = "if ($showHostGuardCall) {"
$showHostRecheckLine = "if ($showHostRecheck) {"
$showHostForceLine = '$taken = [InteractiveWin11WindowNative]::ForceForeground($HostHwnd, $true, $true)'
foreach ($control in @(
        @{ Name = 'an always-true guard'; Edits = @(, @($showHostGuardLine, 'if ($true) {')) },
        @{ Name = 'a negated guard'; Edits = @(, @($showHostGuardLine, "if (-not ($showHostGuardCall)) {")) },
        @{ Name = 'a guard with another operand'; Edits = @(, @($showHostGuardLine, "if (($showHostGuardCall) -or `$true) {")) },
        @{ Name = 'swapped arguments'; Edits = @(, @($showHostGuardLine, 'if (Test-StatefulForeignForeground $foregroundProcessId $foregroundProcessName $hostProcessId $hostProcessName) {')) },
        @{ Name = 'a second clause'; Edits = @(, @($showHostGuardLine, "if (`$false) { } elseif ($showHostGuardCall) {")) },
        @{ Name = 'the recheck removed'; Edits = @(, @($showHostRecheckLine, 'if ($true) {')) },
        @{ Name = 'the recheck negated'; Edits = @(, @($showHostRecheckLine, "if (-not ($showHostRecheck)) {")) },
        @{ Name = 'the foreground id read from the host'; Edits = @(, @($showHostForegroundRead, '$foregroundProcessId = $hostProcessId')) },
        @{ Name = 'the host id read from the foreground'; Edits = @(, @($showHostHostRead, '$hostProcessId = Get-StatefulForegroundProcessId')) },
        @{ Name = 'the host name read from the foreground id'; Edits = @(, @($showHostHostNameRead, '$hostProcessName = Get-StatefulProcessName $foregroundProcessId')) },
        @{ Name = 'the foreground name read from the host id'; Edits = @(, @($showHostForegroundNameRead, '$foregroundProcessName = Get-StatefulProcessName $hostProcessId')) },
        @{ Name = 'the host id overwritten'; Edits = @(, @($showHostForegroundRead, "$showHostForegroundRead; `$hostProcessId = `$foregroundProcessId")) },
        @{ Name = 'the host name overwritten'; Edits = @(, @($showHostGuardLine, "`$hostProcessName = `$foregroundProcessName; $showHostGuardLine")) },
        @{ Name = 'a null target'; Edits = @(, @($showHostForceLine, '$taken = [InteractiveWin11WindowNative]::ForceForeground([IntPtr]::Zero, $true, $true)')) },
        @{ Name = 'the call moved out of the ifs'; Edits = @(@($showHostForceLine, '$taken = $false'), @($showHostGuardLine, "$showHostForceLine; $showHostGuardLine")) }
    )) {
    $controlText = $showHostText
    foreach ($edit in $control.Edits) {
        if (([regex]::Matches($controlText, [regex]::Escape($edit[0]))).Count -ne 1) {
            throw "Show-StatefulHost guard control '$($control.Name)' lost its anchor."
        }
        $controlText = $controlText.Replace($edit[0], $edit[1])
    }
    $controlTokens = $null
    $controlErrors = $null
    $controlAst = [System.Management.Automation.Language.Parser]::ParseInput($controlText, [ref]$controlTokens, [ref]$controlErrors)
    $controlFunction = @($controlAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    if ($controlErrors.Count -ne 0 -or $controlFunction.Count -ne 1) {
        throw "Show-StatefulHost guard control '$($control.Name)' does not parse."
    }
    if (& $testShowHostGuard $controlFunction[0]) {
        throw "The Show-StatefulHost guard check accepted $($control.Name)."
    }
}
# What the guard check above does not look at, the pin refuses: each of these
# must parse and fail the pin (and the unchanged text must pass it).
$showHostSleepLine = 'Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $script:STATEFUL_HOST_SETTLE_MS'
$showHostForegroundLine = '[void][InteractiveWin11WindowNative]::SetForegroundWindow($HostHwnd)'
$parseShowHost = {
    param([string] $Text, [string] $Name)
    $tokens = $null
    $errors = $null
    $parsed = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $functions = @($parsed.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    if ($errors.Count -ne 0 -or $functions.Count -ne 1) { throw "Show-StatefulHost pin control '$Name' does not parse." }
    $functions[0]
}
if (-not (& $matchesPin (& $parseShowHost $showHostText 'unchanged') $showHostPin)) {
    throw 'The Show-StatefulHost pin must accept the function reparsed from its own text.'
}
foreach ($control in @(
        @{ Name = 'the host name appended to'; Edits = @(, @($showHostGuardLine, "`$hostProcessName += 'x'; $showHostGuardLine")) },
        @{ Name = 'the host id incremented'; Edits = @(, @($showHostGuardLine, "`$hostProcessId++; $showHostGuardLine")) },
        @{ Name = 'the foreground id decremented'; Edits = @(, @($showHostGuardLine, "--`$foregroundProcessId; $showHostGuardLine")) },
        @{ Name = 'the host name cast and overwritten'; Edits = @(, @($showHostGuardLine, "[string]`$hostProcessName = 'x'; $showHostGuardLine")) },
        @{ Name = 'the names swapped by one assignment'; Edits = @(, @($showHostGuardLine, "`$hostProcessName, `$foregroundProcessName = `$foregroundProcessName, `$hostProcessName; $showHostGuardLine")) },
        @{ Name = 'the foreground name set by Set-Variable'; Edits = @(, @($showHostGuardLine, "Set-Variable -Name foregroundProcessName -Value `$null; $showHostGuardLine")) },
        @{ Name = 'the foreground name set by the sv alias'; Edits = @(, @($showHostGuardLine, "sv foregroundProcessName `$hostProcessName; $showHostGuardLine")) },
        @{ Name = 'the foreground name written through [ref]'; Edits = @(, @($showHostGuardLine, "([ref]`${foregroundProcessName}).Value = `$hostProcessName; $showHostGuardLine")) },
        @{ Name = 'the host name read replaced, a commented-out copy left'; Edits = @(, @($showHostHostNameRead, "# $showHostHostNameRead`n    `$hostProcessName = Get-StatefulProcessName `$foregroundProcessId")) },
        @{ Name = 'the settle sleep removed'; Edits = @(, @($showHostSleepLine, '')) },
        @{ Name = 'a top-level trap added'; Edits = @(, @($showHostSleepLine, "trap { Set-Variable hostProcessName 'x'; continue }`n    $showHostSleepLine")) },
        @{ Name = 'the body moved into end {} beside a clean block'; Edits = @(
                @('function Show-StatefulHost([IntPtr] $HostHwnd) {', "function Show-StatefulHost([IntPtr] `$HostHwnd) {`n    end {"),
                @($showHostSleepLine, "$showHostSleepLine`n    }`n    clean { `$script:STATEFUL_HOST_SETTLE_MS = 0 }")) },
        @{ Name = 'a return once SetForegroundWindow succeeds'; Edits = @(, @($showHostForegroundLine, "if ([InteractiveWin11WindowNative]::SetForegroundWindow(`$HostHwnd)) { return }")) }
    )) {
    $controlText = $showHostText
    foreach ($edit in $control.Edits) {
        if (([regex]::Matches($controlText, [regex]::Escape($edit[0]))).Count -ne 1) {
            throw "Show-StatefulHost pin control '$($control.Name)' lost its anchor."
        }
        $controlText = $controlText.Replace($edit[0], $edit[1])
    }
    if (& $matchesPin (& $parseShowHost $controlText $control.Name) $showHostPin) {
        throw "The Show-StatefulHost pin accepted $($control.Name)."
    }
}
. ([scriptblock]::Create($foreignForegroundFunctions[0].Extent.Text))
try {
    $foreignForegroundCases = @(
        @{ Case = 'nothing in the foreground'; Args = @(100, 'noctty', 0, $null); Expected = $false },
        @{ Case = 'no foreground window, whatever the name'; Args = @(100, 'noctty', 0, 'explorer'); Expected = $false },
        @{ Case = 'the host itself'; Args = @(100, 'noctty', 100, 'noctty'); Expected = $false },
        @{ Case = "the host's process, whatever the name"; Args = @(100, 'noctty', 100, 'explorer'); Expected = $false },
        @{ Case = 'another noctty process'; Args = @(100, 'noctty', 200, 'noctty'); Expected = $false },
        @{ Case = 'another noctty, other case'; Args = @(100, 'noctty', 200, 'NOCTTY'); Expected = $false },
        @{ Case = 'another application'; Args = @(100, 'noctty', 300, 'T3 Code (Nightly)'); Expected = $true },
        @{ Case = 'a process whose name cannot be read'; Args = @(100, 'noctty', 300, $null); Expected = $false },
        @{ Case = "a host whose name cannot be read"; Args = @(100, $null, 300, 'chrome'); Expected = $false }
    )
    foreach ($case in $foreignForegroundCases) {
        $answer = Test-StatefulForeignForeground $case.Args[0] $case.Args[1] $case.Args[2] $case.Args[3]
        if ($answer -isnot [bool] -or $answer -ne $case.Expected) {
            throw "Test-StatefulForeignForeground answered $answer for $($case.Case); expected $($case.Expected)."
        }
    }
}
finally {
    Remove-Item -LiteralPath Function:\Test-StatefulForeignForeground -ErrorAction SilentlyContinue
}

# Behavior, with no desktop: the real Show-StatefulHost and its helpers run with
# InteractiveWin11WindowNative swapped for a recording stand-in (the foreground
# window is handle 2; it can change process between the first read and the
# recheck) and Get-Process for a table of names, so nothing touches a window,
# the foreground or input.
if (-not ('StatefulHostContractNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class StatefulHostContractNative {
    public static uint HostPid, ForegroundPid, ForegroundPidLater;
    public static int ForegroundReads;
    public static bool ForceResult;
    public static List<string> Calls = new List<string>();
    public static void Reset(uint hostPid, uint foregroundPid, uint foregroundPidLater, bool forceResult) {
        HostPid = hostPid; ForegroundPid = foregroundPid; ForegroundPidLater = foregroundPidLater;
        ForegroundReads = 0; ForceResult = forceResult; Calls.Clear();
    }
    public static bool ShowWindow(IntPtr hwnd, int command) { Calls.Add("ShowWindow:" + hwnd + ":" + command); return true; }
    public static bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags) { Calls.Add("SetWindowPos:" + hwnd + ":" + after + ":" + flags); return true; }
    public static bool SetForegroundWindow(IntPtr hwnd) { Calls.Add("SetForegroundWindow:" + hwnd); return false; }
    public static IntPtr GetForegroundWindow() { Calls.Add("GetForegroundWindow"); return new IntPtr(2); }
    public static uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId) {
        Calls.Add("GetWindowThreadProcessId:" + hwnd);
        if (hwnd == new IntPtr(2)) { ForegroundReads++; processId = ForegroundReads == 1 ? ForegroundPid : ForegroundPidLater; }
        else { processId = hwnd == IntPtr.Zero ? 0u : HostPid; }
        return processId == 0 ? 0u : 1u;
    }
    public static bool ForceForeground(IntPtr hwnd, bool altTap, bool useSendInputForAltTap) {
        Calls.Add("ForceForeground:" + hwnd + ":" + altTap + ":" + useSendInputForAltTap); return ForceResult;
    }
}
'@
}
$script:statefulContractNames = @{ 100 = 'noctty'; 200 = 'noctty'; 300 = 'T3 Code (Nightly)'; 301 = 'explorer' }
function script:Get-Process {
    [CmdletBinding()]
    param([int] $Id)
    if (-not $script:statefulContractNames.ContainsKey($Id)) { throw "no process $Id" }
    [pscustomobject]@{ ProcessName = $script:statefulContractNames[$Id] }
}
$statefulBehaviorFunctions = @($showHostFunctions[0], $foregroundProcessIdFunctions[0], $processNameFunctions[0], $foreignForegroundFunctions[0])
$savedSettle = $script:STATEFUL_HOST_SETTLE_MS
$script:STATEFUL_HOST_SETTLE_MS = 0
try {
    foreach ($function in $statefulBehaviorFunctions) {
        # The stand-in replaces the native class, and the Get-Process table
        # replaces the module-qualified cmdlet the name helper calls.
        . ([scriptblock]::Create($function.Extent.Text.Replace('[InteractiveWin11WindowNative]', '[StatefulHostContractNative]').Replace('Microsoft.PowerShell.Management\Get-Process', 'Get-Process')))
    }
    function script:Invoke-StatefulContractShowHost {
        [CmdletBinding()]
        param([IntPtr] $Hwnd)
        Show-StatefulHost $Hwnd
    }
    # Every native call is recorded, the reads included, in order.
    $plain = 'ShowWindow:10:9|SetWindowPos:10:-1:67|SetForegroundWindow:10|GetWindowThreadProcessId:10|GetForegroundWindow|GetWindowThreadProcessId:2'
    $rechecked = "$plain|GetForegroundWindow|GetWindowThreadProcessId:2"
    $forced = "$rechecked|ForceForeground:10:True:True|SetWindowPos:10:-1:67"
    $took = "Show-StatefulHost: process '{0}' held the foreground; ForceForeground took it back."
    foreach ($case in @(
            @{ Case = 'nothing in the foreground'; Host = 10; Foreground = 0; Later = 0; Expected = $plain },
            @{ Case = 'the host in the foreground'; Host = 10; Foreground = 100; Later = 100; Expected = $plain },
            @{ Case = 'another noctty in the foreground'; Host = 10; Foreground = 200; Later = 200; Expected = $plain },
            @{ Case = 'a process whose name cannot be read'; Host = 10; Foreground = 400; Later = 400; Expected = $plain },
            @{ Case = 'another application'; Host = 10; Foreground = 300; Later = 300; Expected = $forced; Log = ($took -f 'T3 Code (Nightly)') },
            @{ Case = 'explorer'; Host = 10; Foreground = 301; Later = 301; Expected = $forced; Log = ($took -f 'explorer') },
            @{ Case = 'another application, take-back failed'; Host = 10; Foreground = 300; Later = 300; Force = $false; Expected = $forced; Log = "Show-StatefulHost: process 'T3 Code (Nightly)' held the foreground; ForceForeground did not take it back." },
            @{ Case = 'another application, then the host'; Host = 10; Foreground = 300; Later = 100; Expected = $rechecked },
            @{ Case = 'another application, then another'; Host = 10; Foreground = 300; Later = 301; Expected = $rechecked },
            @{ Case = 'a null host window'; Host = 0; Foreground = 300; Later = 300; Expected = 'ShowWindow:0:9|SetWindowPos:0:-1:67|SetForegroundWindow:0|GetWindowThreadProcessId:0|GetForegroundWindow|GetWindowThreadProcessId:2' },
            @{ Case = 'a host whose name cannot be read'; Host = 10; HostPid = 500; Foreground = 300; Later = 300; Expected = $plain }
        )) {
        $forceResult = if ($case.ContainsKey('Force')) { $case.Force } else { $true }
        $hostPid = if ($case.ContainsKey('HostPid')) { [uint32]$case.HostPid } else { [uint32]100 }
        [StatefulHostContractNative]::Reset($hostPid, [uint32]$case.Foreground, [uint32]$case.Later, $forceResult)
        # The success stream and the information stream, captured apart: an
        # advanced wrapper's -InformationVariable collects Write-Host's records
        # (tagged PSHOST), and what the wrapper returns is the success stream
        # alone, which must stay empty (a record redirected into it with 6>&1
        # lands there). 6>$null keeps the records out of the contract run's own
        # log, where the line would otherwise read like a real take-back. A
        # Write-Host given -InformationAction Ignore shows nothing yet is still
        # collected here; the pin refuses that edit in the function's text, and
        # the rewiring check above refuses it through $PSDefaultParameterValues
        # or $InformationPreference.
        $hostRecords = $null
        $successOutput = @(Invoke-StatefulContractShowHost -Hwnd ([IntPtr]$case.Host) -InformationVariable hostRecords 6>$null)
        $hostRecords = @($hostRecords)
        $logged = ($hostRecords | ForEach-Object { "$($_.MessageData)" }) -join "`n"
        $expectedLines = if ($case.ContainsKey('Log')) { 1 } else { 0 }
        $calls = [StatefulHostContractNative]::Calls -join '|'
        if ($calls -cne $case.Expected -or $successOutput.Count -ne 0 -or $hostRecords.Count -ne $expectedLines -or
            @($hostRecords | Where-Object { $_.Tags -notcontains 'PSHOST' }).Count -ne 0 -or
            ($case.ContainsKey('Log') -and $logged -cne $case.Log)) {
            throw "Show-StatefulHost with $($case.Case): calls '$calls', host output '$logged', success output $($successOutput.Count); expected calls '$($case.Expected)'."
        }
    }
    [StatefulHostContractNative]::Reset(100, 300, 300, $true)
    $foregroundIds = @(Get-StatefulForegroundProcessId)
    if ($foregroundIds.Count -ne 1 -or $foregroundIds[0] -isnot [uint32] -or $foregroundIds[0] -ne 300) {
        throw "Get-StatefulForegroundProcessId must return the foreground's process id as one [uint32]; it returned '$($foregroundIds -join ',')'."
    }
}
finally {
    $script:STATEFUL_HOST_SETTLE_MS = $savedSettle
    foreach ($behaviorFunctionName in @('Show-StatefulHost', 'Get-StatefulForegroundProcessId', 'Get-StatefulProcessName', 'Test-StatefulForeignForeground', 'Get-Process', 'Invoke-StatefulContractShowHost')) {
        Remove-Item -LiteralPath "Function:\$behaviorFunctionName" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Scope Script -Name statefulContractNames -ErrorAction SilentlyContinue
}

# Harness screenshots go to the uploaded artifacts of a public repository, so
# they may show noctty only (EVIDENCE-PIXEL-DIAG-01, EVIDENCE-SCREENSHOT-PRIVACY-01):
# the decision is table-tested from facts, and Save-StatefulScreenCapture, the
# one place that saves a screen capture, is run with its screen read
# (Read-StatefulScreenArea) and its recheck substituted, so no desktop is needed.
# PowerShell matches members, commands and parameters case-insensitively and
# takes any unique prefix of a parameter name, so these checks do too.
$diagnosticFunctions = @{}
foreach ($name in @('Get-StatefulScreenshotDecision', 'Read-StatefulScreenArea', 'Save-StatefulScreenCapture', 'Save-StatefulPixelDiagnostic')) {
    $diagnosticFound = @($statefulLibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($diagnosticFound.Count -ne 1) { throw "The stateful library must define $name once." }
    $diagnosticFunctions[$name] = $diagnosticFound[0]
}
# Any use of the member, called or not (`.CopyFromScreen.Invoke(...)`), quoted or not.
$findMembers = {
    param($Ast, [string] $Member)
    @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Member.Value -eq $Member
    }, $true))
}
$findCommands = {
    param($Ast, [string] $Name)
    @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $Name
    }, $true))
}
$underIf = {
    param($Node, [string] $Condition)
    for ($gate = $Node.Parent; $null -ne $gate; $gate = $gate.Parent) {
        if ($gate -is [System.Management.Automation.Language.IfStatementAst] -and $gate.Clauses[0].Item1.Extent.Text -cmatch $Condition) { return $true }
    }
    return $false
}
$owningFunction = {
    param($Node)
    for ($owner = $Node.Parent; $null -ne $owner; $owner = $owner.Parent) {
        if ($owner -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $owner }
    }
    return $null
}
$saveCapture = $diagnosticFunctions['Save-StatefulScreenCapture']
$captureParameters = @(@($saveCapture.Parameters) + @($saveCapture.Body.ParamBlock.Parameters) |
    Where-Object { $null -ne $_ } | ForEach-Object { $_.Name.VariablePath.UserPath })
if ('PassThru' -notin $captureParameters) { throw 'Save-StatefulScreenCapture must take a -PassThru switch.' }
# Whether a call asks for the ungated bitmap: -PassThru by any unique prefix,
# or a splatted call, which can carry it unseen.
$asksPassThru = {
    param($Call)
    foreach ($element in $Call.CommandElements) {
        if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) { return $true }
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $named = @($captureParameters | Where-Object { $_.StartsWith($element.ParameterName, [StringComparison]::OrdinalIgnoreCase) })
            if ($element.ParameterName -eq 'PassThru' -or ($named.Count -eq 1 -and $named[0] -eq 'PassThru')) { return $true }
        }
    }
    return $false
}
$readArea = $diagnosticFunctions['Read-StatefulScreenArea']
$captureSaves = @(& $findMembers $saveCapture 'Save')
if (@(& $findMembers $readArea 'CopyFromScreen').Count -ne 1 -or @(& $findMembers $readArea 'Save').Count -ne 0 -or
    @(& $findMembers $saveCapture 'CopyFromScreen').Count -ne 0 -or
    @(& $findCommands $saveCapture 'Read-StatefulScreenArea').Count -ne 1 -or
    @(& $findCommands $saveCapture 'Get-StatefulScreenshotDecision').Count -ne 2 -or
    $captureSaves.Count -ne 1 -or -not (& $underIf $captureSaves[0] '^\$decision\.Capture$') -or
    -not (& $underIf $captureSaves[0] '^\$recheck\.Capture -and ')) {
    throw 'Save-StatefulScreenCapture must read the screen once, through Read-StatefulScreenArea, and save only when Get-StatefulScreenshotDecision allows it before and after the read.'
}
$saveDiagnostic = $diagnosticFunctions['Save-StatefulPixelDiagnostic']
$diagnosticShots = @(& $findCommands $saveDiagnostic 'Save-StatefulScreenCapture')
if (@(& $findMembers $saveDiagnostic 'CopyFromScreen').Count -ne 0 -or $diagnosticShots.Count -ne 1 -or
    (& $asksPassThru $diagnosticShots[0])) {
    throw 'Save-StatefulPixelDiagnostic must take its screenshot through Save-StatefulScreenCapture, without -PassThru.'
}
. ([scriptblock]::Create($diagnosticFunctions['Get-StatefulScreenshotDecision'].Extent.Text))
try {
    $ownProcess = [pscustomobject]@{ ProcessId = [uint32]40; ProcessName = 'noctty'; Class = 'noctty.win32.host' }
    $otherProcess = [pscustomobject]@{ ProcessId = [uint32]41; ProcessName = 'other'; Class = 'Other' }
    $screenshotFacts = {
        param([hashtable] $Change)
        $facts = [ordered]@{
            Rect = [pscustomobject]@{ Left = 100; Top = 100; Right = 500; Bottom = 400 }
            Root = $ownProcess
            WindowVisible = $true; RootVisible = $true; RootMinimized = $false; RootCloaked = [long]0; RootOpaque = $true
            CaptureBounds = [pscustomobject]@{ Left = 50; Top = 90; Right = 450; Bottom = 800 }
            Samples = @(1..16 | ForEach-Object { [pscustomobject]@{ Root = $ownProcess } })
            WindowsAbove = @()
        }
        foreach ($key in $Change.Keys) { $facts[$key] = $Change[$key] }
        return [pscustomobject]$facts
    }
    $screenshotAbove = { param($Process, [long] $Cloaked) $Process | Select-Object * | Add-Member -PassThru -NotePropertyName Cloaked -NotePropertyValue $Cloaked }
    $oneForeignSample = @(1..15 | ForEach-Object { [pscustomobject]@{ Root = $ownProcess } }) + @([pscustomobject]@{ Root = $otherProcess })
    $noWindowSample = @(1..15 | ForEach-Object { [pscustomobject]@{ Root = $ownProcess } }) + @([pscustomobject]@{ Root = $null })
    $screenshotCases = @(
        @{ Name = 'noctty shown and alone'; Change = @{}; Expected = 'capture 100,100,450,400 occluders=0' }
        @{ Name = 'a window of noctty above'; Change = @{ WindowsAbove = @(& $screenshotAbove $ownProcess 0) }; Expected = 'capture 100,100,450,400 occluders=0' }
        @{ Name = 'a cloaked window of another process above'; Change = @{ WindowsAbove = @(& $screenshotAbove $otherProcess 1) }; Expected = 'capture 100,100,450,400 occluders=0' }
        @{ Name = 'a window of another process above'; Change = @{ WindowsAbove = @(& $screenshotAbove $otherProcess 0) }; Expected = 'withheld: 1 window(s) of other processes overlap the sampled rect occluders=1' }
        @{ Name = 'another process above, cloak unknown'; Change = @{ WindowsAbove = @(& $screenshotAbove $otherProcess -1) }; Expected = 'withheld: 1 window(s) of other processes overlap the sampled rect occluders=1' }
        @{ Name = 'noctty hidden'; Change = @{ RootVisible = $false }; Expected = "withheld: noctty's window is hidden occluders=0" }
        @{ Name = 'sampled window hidden'; Change = @{ WindowVisible = $false }; Expected = "withheld: noctty's window is hidden occluders=0" }
        @{ Name = 'noctty cloaked'; Change = @{ RootCloaked = [long]2 }; Expected = "withheld: noctty's window is cloaked (2) occluders=0" }
        @{ Name = 'noctty cloak unknown'; Change = @{ RootCloaked = [long]-1 }; Expected = "withheld: DWM could not say whether noctty's window is cloaked occluders=0" }
        @{ Name = 'noctty minimized'; Change = @{ RootMinimized = $true }; Expected = "withheld: noctty's window is minimized occluders=0" }
        @{ Name = 'noctty see-through'; Change = @{ RootOpaque = $false }; Expected = "withheld: noctty's window is see-through (layered) occluders=0" }
        @{ Name = 'a sample on another process'; Change = @{ Samples = $oneForeignSample }; Expected = 'withheld: 1 sample point(s) lie on windows of other processes occluders=0' }
        @{ Name = 'a sample on no window'; Change = @{ Samples = $noWindowSample }; Expected = 'withheld: 1 sample point(s) lie on windows of other processes occluders=0' }
        @{ Name = 'no top-level window'; Change = @{ Root = $null; WindowsAbove = @(& $screenshotAbove $ownProcess 0) }; Expected = "withheld: noctty's top-level window could not be found occluders=1" }
        @{ Name = 'no rect'; Change = @{ Rect = $null }; Expected = 'not taken: the window rect could not be read occluders=0' }
        @{ Name = 'no client area'; Change = @{ CaptureBounds = $null }; Expected = "withheld: noctty's client area could not be read occluders=0" }
        @{ Name = 'rect outside the client area'; Change = @{ CaptureBounds = [pscustomobject]@{ Left = 600; Top = 90; Right = 700; Bottom = 800 } }; Expected = "withheld: the sampled rect lies outside noctty's client area occluders=0" }
    )
    foreach ($screenshotCase in $screenshotCases) {
        $screenshotDecision = Get-StatefulScreenshotDecision (& $screenshotFacts $screenshotCase.Change)
        $screenshotActual = if ($screenshotDecision.Capture) {
            $screenshotArea = $screenshotDecision.CaptureRect
            "capture $($screenshotArea.Left),$($screenshotArea.Top),$($screenshotArea.Right),$($screenshotArea.Bottom)"
        } else { $screenshotDecision.Note }
        $screenshotActual += " occluders=$(@($screenshotDecision.Occluders).Count)"
        if ($screenshotActual -cne $screenshotCase.Expected) {
            throw "Pixel diagnostic screenshot decision ($($screenshotCase.Name)): expected '$($screenshotCase.Expected)', got '$screenshotActual'."
        }
    }
    # Save-StatefulScreenCapture with a substituted screen read, whose bitmap
    # logs its save and disposal, and a substituted recheck: each case names
    # every read, recheck, save and disposal it must make, and what it returns.
    Add-Type -AssemblyName System.Drawing
    . ([scriptblock]::Create($diagnosticFunctions['Save-StatefulScreenCapture'].Extent.Text))
    $script:captureLog = [Collections.Generic.List[string]]::new()
    $script:recheckFacts = $null
    function script:Read-StatefulScreenArea($Area) {
        $script:captureLog.Add("read $($Area.Left),$($Area.Top),$($Area.Right),$($Area.Bottom)")
        $fakeBitmap = [pscustomobject]@{}
        $fakeBitmap | Add-Member -MemberType ScriptMethod -Name Save -Value { param($Path, $Format) $script:captureLog.Add("save $Path $Format") }
        $fakeBitmap | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:captureLog.Add('dispose') }
        return $fakeBitmap
    }
    function script:Get-StatefulScreenFacts($Hwnd) {
        $script:captureLog.Add('recheck')
        if ($null -eq $script:recheckFacts) { throw 'Save-StatefulScreenCapture read the screen facts again where it had nothing to save.' }
        return $script:recheckFacts
    }
    $coveredChange = @{ WindowsAbove = @(& $screenshotAbove $otherProcess 0) }
    $movedChange = @{ Rect = [pscustomobject]@{ Left = 101; Top = 100; Right = 501; Bottom = 400 } }
    $covered = 'withheld: 1 window(s) of other processes overlap the sampled rect'
    foreach ($captureCase in @(
            @{ Name = 'allowed and unchanged'; Change = @{}; Recheck = @{}; PassThru = $false
                Expected = 'read 100,100,450,400|recheck|save C:\contract\capture.png Png|dispose; path=C:\contract\capture.png; bitmap=False; note=' }
            @{ Name = 'covered during the read'; Change = @{}; Recheck = $coveredChange; PassThru = $false
                Expected = "read 100,100,450,400|recheck|dispose; path=; bitmap=False; note=discarded: the screen changed during the capture ($covered)" }
            @{ Name = 'moved during the read'; Change = @{}; Recheck = $movedChange; PassThru = $false
                Expected = 'read 100,100,450,400|recheck|dispose; path=; bitmap=False; note=discarded: the screen changed during the capture (the window moved)' }
            @{ Name = 'allowed, -PassThru'; Change = @{}; Recheck = @{}; PassThru = $true
                Expected = 'read 100,100,450,400|recheck|save C:\contract\capture.png Png; path=C:\contract\capture.png; bitmap=True; note=' }
            @{ Name = 'withheld'; Change = $coveredChange; Recheck = $null; PassThru = $false
                Expected = "; path=; bitmap=False; note=$covered" }
            @{ Name = 'withheld, -PassThru'; Change = $coveredChange; Recheck = $null; PassThru = $true
                Expected = "read 100,100,450,400; path=; bitmap=True; note=$covered" }
            @{ Name = 'no capture area, -PassThru'; Change = @{ Root = $null; CaptureBounds = $null }; Recheck = $null; PassThru = $true
                Expected = "; path=; bitmap=False; note=withheld: noctty's top-level window could not be found" }
        )) {
        $script:captureLog.Clear()
        $script:recheckFacts = if ($null -ne $captureCase.Recheck) { & $screenshotFacts $captureCase.Recheck } else { $null }
        $captureShot = Save-StatefulScreenCapture -Hwnd ([IntPtr]::Zero) -Path 'C:\contract\capture.png' -PassThru:$captureCase.PassThru -Facts (& $screenshotFacts $captureCase.Change)
        $captureActual = "$($script:captureLog -join '|'); path=$($captureShot.Path); bitmap=$($null -ne $captureShot.Bitmap); note=$($captureShot.Note)"
        if ($captureActual -cne $captureCase.Expected) {
            throw "Save-StatefulScreenCapture ($($captureCase.Name)): expected '$($captureCase.Expected)', got '$captureActual'."
        }
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-StatefulScreenshotDecision, Function:\Save-StatefulScreenCapture,
        Function:\Read-StatefulScreenArea, Function:\Get-StatefulScreenFacts -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name captureLog, recheckFacts -ErrorAction SilentlyContinue
}

# Every screen capture a harness can save goes through Save-StatefulScreenCapture
# (EVIDENCE-SCREENSHOT-PRIVACY-01). Allowed elsewhere: one-pixel color reads;
# the shell-command-live harness, which keeps its captures in the sandbox temp
# that no workflow uploads; and the maintainer's opt-in visible D3D11 check,
# which asks before it saves one. Its -PassThru bitmap is ungated, so only the
# resize harness may ask for it, and that harness saves no image itself.
$screenReadAllowed = @(
    'test\windows\interactive-win11-shell-command-live.ps1'
    'test\windows\renderer\Invoke-VisibleD3D11Check.ps1 (embedded)'
)
$passThruAllowed = @('test\windows\interactive-win11-resize.ps1')
# What one script does outside the gate: a CopyFromScreen that is neither one
# pixel nor inside Read-StatefulScreenArea; a Read-StatefulScreenArea call
# outside Save-StatefulScreenCapture; source text that names CopyFromScreen
# (C# for Add-Type); and a -PassThru call outside the resize harness or in a
# file that saves an image.
$findScreenReads = {
    param($Ast, [string] $Relative, [bool] $IsLibrary)
    foreach ($read in @(& $findMembers $Ast 'CopyFromScreen')) {
        $owner = & $owningFunction $read
        $onePixel = $read -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $read.Arguments.Count -gt 0 -and $read.Arguments[-1].Extent.Text -eq '[Drawing.Size]::new(1, 1)'
        $gated = $IsLibrary -and $null -ne $owner -and $owner.Name -eq 'Read-StatefulScreenArea'
        if (-not $onePixel -and -not $gated) { $Relative }
    }
    foreach ($call in @(& $findCommands $Ast 'Read-StatefulScreenArea')) {
        $owner = & $owningFunction $call
        if (-not ($IsLibrary -and $null -ne $owner -and $owner.Name -eq 'Save-StatefulScreenCapture')) { "$Relative (Read-StatefulScreenArea)" }
    }
    $embedded = @($Ast.FindAll({
        param($node)
        # A string other than a member name, such as C# source for Add-Type.
        (($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -ne 'BareWord' -and
                -not ($node.Parent -is [System.Management.Automation.Language.MemberExpressionAst] -and [object]::ReferenceEquals($node.Parent.Member, $node))) -or
            $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and $node.Value -match 'CopyFromScreen'
    }, $true))
    if ($embedded.Count -ne 0) { "$Relative (embedded)" }
    $passThruCalls = @(& $findCommands $Ast 'Save-StatefulScreenCapture' | Where-Object { & $asksPassThru $_ })
    if ($passThruCalls.Count -ne 0 -and ($Relative -notin $passThruAllowed -or @(& $findMembers $Ast 'Save').Count -ne 0)) {
        "$Relative (-PassThru)"
    }
}
# The spellings a check like this misses unless it matches as PowerShell does,
# and the allowed forms, which must report nothing.
$control = 'test\windows\control.ps1'
$resizeControl = $passThruAllowed[0]
foreach ($screenControl in @(
        @{ Name = 'lower-case member'; File = $control; Text = '$g.copyfromscreen(0, 0, 0, 0, $size)'; Expected = $control }
        @{ Name = 'quoted member'; File = $control; Text = "`$g.'CopyFromScreen'(0, 0, 0, 0, `$size)"; Expected = $control }
        @{ Name = 'member not called'; File = $control; Text = '$g.CopyFromScreen.Invoke(0, 0, 0, 0, $size)'; Expected = $control }
        @{ Name = 'C# source'; File = $control; Text = "Add-Type 'public static class C { public static void M(System.Drawing.Graphics g) { g.CopyFromScreen(0, 0, 0, 0, new System.Drawing.Size(9, 9)); } }'"; Expected = "$control (embedded)" }
        @{ Name = 'the read called directly'; File = $control; Text = 'read-statefulscreenarea $area'; Expected = "$control (Read-StatefulScreenArea)" }
        @{ Name = 'abbreviated -PassThru'; File = $control; Text = 'Save-StatefulScreenCapture -Hwnd $h -Path x.png -PassT'; Expected = "$control (-PassThru)" }
        @{ Name = 'shortest unique prefix, lower case'; File = $control; Text = 'save-statefulscreencapture -hwnd $h -pas'; Expected = "$control (-PassThru)" }
        @{ Name = 'splatted call'; File = $control; Text = 'Save-StatefulScreenCapture @captureArguments'; Expected = "$control (-PassThru)" }
        @{ Name = 'resize saving with -PassThru'; File = $resizeControl; Text = "Save-StatefulScreenCapture -PassT; `$shot.Bitmap.save('x.png')"; Expected = "$resizeControl (-PassThru)" }
        @{ Name = 'one-pixel read'; File = $control; Text = '$g.CopyFromScreen($x, $y, 0, 0, [Drawing.Size]::new(1, 1))'; Expected = '' }
        @{ Name = 'gated call'; File = $control; Text = 'Save-StatefulScreenCapture -Hwnd $h -Path x.png -Pa'; Expected = '' }
        @{ Name = 'resize asking for -PassThru'; File = $resizeControl; Text = 'Save-StatefulScreenCapture -Hwnd $h -Path x.png -PassThru'; Expected = '' }
    )) {
    $controlTokens = $null
    $controlErrors = $null
    $controlAst = [System.Management.Automation.Language.Parser]::ParseInput($screenControl.Text, [ref]$controlTokens, [ref]$controlErrors)
    $controlActual = (@(& $findScreenReads $controlAst $screenControl.File $false) | Sort-Object -Unique) -join ', '
    if ($controlActual -cne $screenControl.Expected) {
        throw "Screen-capture scan control ($($screenControl.Name)): expected '$($screenControl.Expected)', got '$controlActual'."
    }
}
$screenReads = foreach ($screenScript in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'test\windows'), (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -Recurse -File) {
    $relative = [IO.Path]::GetRelativePath($repoRoot, $screenScript.FullName)
    if ($relative -like 'test\windows\flagship\contracts\*') { continue }
    $screenTokens = $null
    $screenErrors = $null
    $screenAst = [System.Management.Automation.Language.Parser]::ParseFile($screenScript.FullName, [ref]$screenTokens, [ref]$screenErrors)
    & $findScreenReads $screenAst $relative ($screenScript.FullName -eq $statefulWin11Lib)
}
$screenReads = @($screenReads) + @(Get-ChildItem -LiteralPath (Join-Path $repoRoot '.github\workflows') -Filter '*.yml' -File |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'CopyFromScreen' } |
    ForEach-Object { [IO.Path]::GetRelativePath($repoRoot, $_.FullName) })
$unexpectedScreenReads = @($screenReads | Sort-Object -Unique | Where-Object { $_ -notin $screenReadAllowed })
if ($unexpectedScreenReads.Count -ne 0) {
    throw "Screen captures must go through Save-StatefulScreenCapture: $($unexpectedScreenReads -join ', ')"
}
if ((Get-Content -LiteralPath (Join-Path $repoRoot $screenReadAllowed[0]) -Raw) -match "Join-Path \`$layout\.Logs '[^']*\.png'") {
    throw 'interactive-win11-shell-command-live.ps1 must keep its screen captures out of the uploaded sandbox logs.'
}
$harnessMainFunctions = @($interactiveWin11LibAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-InteractiveWin11HarnessMain'
}, $true))
if ($harnessMainFunctions.Count -ne 1 -or
    -not [object]::ReferenceEquals($harnessMainFunctions[0].Parent, $interactiveWin11LibAst.EndBlock)) {
    throw 'Interactive harness main helper must remain one top-level definition.'
}
# Exact-one is the invariant here: callers must resolve one shared top-level
# bootstrap gate. Its private statement layout is deliberately not pinned.
$harnessMainSource = $harnessMainFunctions[0].Extent.Text
$harnessMainProbeEnvironment =
    'NOCTTY_HARNESS_MAIN_CONTRACT_' + [Guid]::NewGuid().ToString('N')
$harnessMainProbePrevious = [Environment]::GetEnvironmentVariable(
    $harnessMainProbeEnvironment,
    [EnvironmentVariableTarget]::Process
)
try {
    [Environment]::SetEnvironmentVariable(
        $harnessMainProbeEnvironment,
        'already-bootstrapped',
        [EnvironmentVariableTarget]::Process
    )
    $sentinelProbe = @"
$harnessMainSource
function Invoke-InteractiveWin11Bootstrap { throw 'bootstrap mock must not run' }
Invoke-InteractiveWin11HarnessMain -RepoRoot 'repo-probe' -LauncherPath 'launcher-probe' -EnvironmentVariable '$harnessMainProbeEnvironment' -ArgumentList @('one', 'two')
Write-Output 'HARNESS-MAIN-RETURNED'
"@
    $sentinelOutput = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -Command $sentinelProbe 2>&1)
    $sentinelExitCode = $LASTEXITCODE
    if ($sentinelExitCode -ne 0 -or
        $sentinelOutput -notcontains 'HARNESS-MAIN-RETURNED' -or
        $sentinelOutput -match 'bootstrap mock') {
        throw 'Interactive harness main did not return without bootstrapping when its process sentinel was set.'
    }

    [Environment]::SetEnvironmentVariable(
        $harnessMainProbeEnvironment,
        $null,
        [EnvironmentVariableTarget]::Process
    )
    $bootstrapProbe = @"
$harnessMainSource
function Invoke-InteractiveWin11Bootstrap {
    param(
        [string] `$RepoRoot,
        [string] `$LauncherPath,
        [string] `$EnvironmentVariable,
        [string[]] `$ArgumentList,
        [System.Management.Automation.PSReference] `$ExitCode
    )
    Write-Output ('BOOTSTRAP-CALLED|' + `$RepoRoot + '|' + `$LauncherPath + '|' + `$EnvironmentVariable + '|' + (`$ArgumentList -join ','))
    `$ExitCode.Value = 37
}
Invoke-InteractiveWin11HarnessMain -RepoRoot 'repo-probe' -LauncherPath 'launcher-probe' -EnvironmentVariable '$harnessMainProbeEnvironment' -ArgumentList @('one', 'two')
Write-Output 'UNREACHABLE-AFTER-HARNESS-MAIN'
"@
    $bootstrapOutput = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -Command $bootstrapProbe 2>&1)
    $bootstrapExitCode = $LASTEXITCODE
    $bootstrapCalls = @($bootstrapOutput | Where-Object {
        $_ -eq "BOOTSTRAP-CALLED|repo-probe|launcher-probe|$harnessMainProbeEnvironment|one,two"
    })
    if ($bootstrapCalls.Count -ne 1 -or
        $bootstrapExitCode -ne 37 -or
        $bootstrapOutput -contains 'UNREACHABLE-AFTER-HARNESS-MAIN') {
        throw 'Interactive harness main did not invoke its bootstrap mock once, forward arguments, and propagate exit code 37.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        $harnessMainProbeEnvironment,
        $harnessMainProbePrevious,
        [EnvironmentVariableTarget]::Process
    )
}
$stopProcessFunctions = @($interactiveWin11LibAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Stop-InteractiveWin11Process'
}, $true))
$processTreeSnapshotFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InteractiveWin11ProcessTreeSnapshot'
    }, $true))
$processTreeExitedFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-InteractiveWin11ProcessTreeSnapshotExited'
    }, $true))
$waitProcessTreeExitedFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-InteractiveWin11ProcessTreeSnapshotExited'
    }, $true))
$stopRootHandleFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-InteractiveWin11RootHandle'
    }, $true))
# Exact-one top-level definitions are genuine ownership invariants: cleanup
# callers must all resolve the same lifecycle implementation.
$stopProcessMandatoryAttributes = @(
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Attributes |
        Where-Object {
            $_ -is [System.Management.Automation.Language.AttributeAst] -and
                $_.TypeName.Name -eq 'Parameter' -and
                $_.NamedArguments.ArgumentName -contains 'Mandatory'
        }
)
if ($stopProcessFunctions.Count -ne 1 -or
    $processTreeSnapshotFunctions.Count -ne 1 -or
    $processTreeExitedFunctions.Count -ne 1 -or
    $waitProcessTreeExitedFunctions.Count -ne 1 -or
    $stopRootHandleFunctions.Count -ne 1 -or
    -not [object]::ReferenceEquals($stopProcessFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    -not [object]::ReferenceEquals($processTreeSnapshotFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    -not [object]::ReferenceEquals($processTreeExitedFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    -not [object]::ReferenceEquals($waitProcessTreeExitedFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    -not [object]::ReferenceEquals($stopRootHandleFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.TrapStatementAst]
    }, $true)).Count -ne 0 -or
    $null -ne $stopProcessFunctions[0].Body.BeginBlock -or
    $null -ne $stopProcessFunctions[0].Body.ProcessBlock -or
    $null -ne $stopProcessFunctions[0].Body.DynamicParamBlock -or
    $null -ne $stopProcessFunctions[0].Body.CleanBlock -or
    $null -eq $stopProcessFunctions[0].Body.ParamBlock -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters.Count -ne 4 -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Name.VariablePath.UserPath -ne 'Process' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].StaticType -ne [System.Diagnostics.Process] -or
    $stopProcessMandatoryAttributes.Count -ne 1 -or
    $null -ne $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].DefaultValue -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].Name.VariablePath.UserPath -ne 'RequireLiveRoot' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].StaticType -ne [switch] -or
    $null -ne $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].DefaultValue -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[2].Name.VariablePath.UserPath -ne 'Contained' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[2].StaticType -ne [switch] -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[3].Name.VariablePath.UserPath -ne 'AllowAlreadyExited' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[3].StaticType -ne [switch]) {
    throw 'Interactive process cleanup must expose explicit contained, live-root, and already-exited contracts.'
}
$rootTerminateCalls = @(
    Get-NamedMemberExpressions `
        -Ast $stopRootHandleFunctions[0].Body `
        -Name 'TerminateProcess' `
        -InvocationOnly
)
$rootWaitCalls = @(
    Get-NamedMemberExpressions `
        -Ast $stopRootHandleFunctions[0].Body `
        -Name 'WaitForSingleObject' `
        -InvocationOnly
)
if ($rootTerminateCalls.Count -ne 1 -or
    $rootTerminateCalls[0].Arguments.Count -ne 2 -or
    (Get-VariableExpressionName -Node $rootTerminateCalls[0].Arguments[0]) -ne
        'RootProcessHandle' -or
    $rootTerminateCalls[0].Arguments[1].Extent.Text.Trim() -cne '1' -or
    $rootWaitCalls.Count -ne 1 -or
    $rootWaitCalls[0].Arguments.Count -ne 2 -or
    (Get-VariableExpressionName -Node $rootWaitCalls[0].Arguments[0]) -ne
        'RootProcessHandle' -or
    $rootWaitCalls[0].Arguments[1].Extent.Text.Trim() -cne '15000') {
    throw 'Root fallback must terminate and wait on the captured process HANDLE with exit code 1 and a 15000 ms budget.'
}
if ($waitProcessTreeExitedFunctions[0].Body.Extent.Text -notmatch
        '(?s)\$deadline\s*=\s*\[DateTime\]::UtcNow\.AddSeconds\(\$TimeoutSeconds\).*?do\s*\{.*?Test-InteractiveWin11ProcessTreeSnapshotExited.*?-OperationTimeoutSec\s+\$operationTimeoutSec.*?Start-Sleep\s+-Milliseconds.*?\}\s*while\s*\(\[DateTime\]::UtcNow\s+-lt\s+\$deadline\)') {
    throw 'Process-tree verification must poll with per-query bounds until one explicit deadline.'
}

$uncontainedKillBranches = @($stopProcessFunctions[0].Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -eq 1 -and
        $node.Clauses[0].Item1.Extent.Text.Trim() -ceq '-not $Contained'
}, $true))
$taskkillArgumentAssignments = if ($uncontainedKillBranches.Count -eq 1) {
    @($uncontainedKillBranches[0].Clauses[0].Item2.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and
            (Get-ExpressionRootVariableName -Node $node.Left) -eq
                'taskkillStartInfo' -and
            (Get-MemberExpressionName -Node $node.Left) -eq 'Arguments'
    }, $true))
} else {
    @()
}
$taskkillWaitCalls = if ($uncontainedKillBranches.Count -eq 1) {
    @(Get-NamedMemberExpressions `
        -Ast $uncontainedKillBranches[0].Clauses[0].Item2 `
        -Name 'WaitForExit' `
        -InvocationOnly)
} else {
    @()
}
$taskkillWaitBudgets = @($taskkillWaitCalls | ForEach-Object {
    if ($_.Arguments.Count -eq 1) { $_.Arguments[0].Extent.Text.Trim() }
})
$taskkillCleanupRethrows = @($stopProcessFunctions[0].Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -eq 1 -and
        $node.Clauses[0].Item1.Extent.Text -match
            '\$null\s+-ne\s+\$taskkillCleanupError' -and
        @($node.Clauses[0].Item2.FindAll({
            param($child)
            $child -is [System.Management.Automation.Language.ThrowStatementAst] -and
                $child.Extent.Text -match 'Failed to reap taskkill'
        }, $true)).Count -eq 1
}, $true))
if ($uncontainedKillBranches.Count -ne 1 -or
    $taskkillArgumentAssignments.Count -ne 1 -or
    $taskkillArgumentAssignments[0].Right.Extent.Text -notmatch
        '/PID\s+\$rootProcessId\s+/T\s+/F' -or
    $taskkillWaitCalls.Count -ne 2 -or
    $taskkillWaitBudgets -notcontains '10000' -or
    $taskkillWaitBudgets -notcontains '5000' -or
    $taskkillCleanupRethrows.Count -ne 1) {
    throw 'Uncontained cleanup must taskkill the captured PID tree with /T /F, bound taskkill/reap waits to 10000/5000 ms, and rethrow cleanup failure.'
}

# The executed probes below cover query bounds, snapshot-before-stop behavior,
# identity matching, fail-closed verification, contained fallback, and mutually
# exclusive lifecycle modes.

. ([scriptblock]::Create($processTreeSnapshotFunctions[0].Extent.Text))
. ([scriptblock]::Create($processTreeExitedFunctions[0].Extent.Text))
$script:verificationCimProcesses = @()
$script:verificationCimFailure = $null
$script:verificationCimCalls = 0
function script:Get-CimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ClassName,
        [string] $Filter,
        [uint32] $OperationTimeoutSec
    )

    $script:verificationCimCalls++
    if ($ClassName -ne 'Win32_Process' -or
        $PSBoundParameters.ContainsKey('Filter') -or
        $OperationTimeoutSec -lt 1 -or
        $OperationTimeoutSec -gt 5) {
        throw 'Verification mock requires one bounded, unfiltered Win32_Process query.'
    }
    if ($null -ne $script:verificationCimFailure) {
        throw $script:verificationCimFailure
    }
    $script:verificationCimProcesses
}

try {
    $rootCreated = [datetime]'2026-07-14T15:00:00Z'
    $childCreated = $rootCreated.AddSeconds(1)
    $grandchildCreated = $rootCreated.AddSeconds(2)
    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 4; CreationDate = $rootCreated },
        [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; CreationDate = $childCreated },
        [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CreationDate = $grandchildCreated },
        [pscustomobject]@{ ProcessId = 103; ParentProcessId = 100; CreationDate = $rootCreated.AddMinutes(-1) },
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 4; CreationDate = $rootCreated }
    )
    $snapshot = @(Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated)
    if ((@($snapshot.ProcessId | Sort-Object) -join ',') -ne '100,101,102') {
        throw 'Interactive process snapshot did not close over the full descendant tree.'
    }
    if (Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot) {
        throw 'Interactive process verification accepted captured identities that were still live.'
    }

    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 4; CreationDate = $rootCreated.AddMinutes(1) },
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 4; CreationDate = $rootCreated }
    )
    if (-not (Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot)) {
        throw 'Interactive process verification confused a reused PID with a captured identity.'
    }

    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 201; ParentProcessId = 100; CreationDate = $rootCreated.AddMinutes(2) }
    )
    if (Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot) {
        throw 'Interactive process verification missed a child created after the snapshot.'
    }
    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 201; ParentProcessId = 100; CreationDate = $rootCreated.AddMinutes(-1) }
    )
    if (-not (Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot)) {
        throw 'Interactive process verification confused a stale child from a reused parent PID with a live descendant.'
    }

    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 4; CreationDate = $rootCreated }
    )
    $missingRootRejected = $false
    $missingRootMessage = ''
    try { [void](Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated) } catch {
        $missingRootRejected = $true
        $missingRootMessage = $_.Exception.Message
    }
    if (-not $missingRootRejected -or
        $missingRootMessage -notlike 'Interactive Win11 root process 100 was absent*') {
        throw 'Interactive process snapshot accepted a missing root identity.'
    }

    $emptySnapshotRejected = $false
    $emptySnapshotMessage = ''
    try { [void](Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot @()) } catch {
        $emptySnapshotRejected = $true
        $emptySnapshotMessage = $_.Exception.Message
    }
    if (-not $emptySnapshotRejected -or
        [string]::IsNullOrWhiteSpace($emptySnapshotMessage)) {
        throw 'Interactive process verification accepted a vacuous empty snapshot.'
    }

    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 4; CreationDate = $rootCreated.AddMinutes(1) }
    )
    $reusedRootRejected = $false
    try { [void](Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated) } catch { $reusedRootRejected = $true }
    if (-not $reusedRootRejected) {
        throw 'Interactive process snapshot accepted a reused root PID.'
    }

    $script:verificationCimFailure = 'simulated CIM failure'
    $snapshotFailureRejected = $false
    try { [void](Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated) } catch { $snapshotFailureRejected = $true }
    $verificationFailureRejected = $false
    try { [void](Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot) } catch { $verificationFailureRejected = $true }
    if (-not $snapshotFailureRejected -or -not $verificationFailureRejected) {
        throw 'Interactive process cleanup treated a CIM failure as proof of exit.'
    }
    if ($script:verificationCimCalls -lt 8) {
        throw 'Interactive process-tree behavior probes did not invoke the bounded CIM mock.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name verificationCimProcesses, verificationCimFailure, verificationCimCalls -ErrorAction SilentlyContinue
}

. ([scriptblock]::Create($stopProcessFunctions[0].Extent.Text))
$script:cleanupSnapshotFailure = $false
$script:cleanupVerificationFailure = $false
$script:cleanupVerificationExited = $true
$script:cleanupSnapshotCalls = 0
$script:cleanupRootStopCalls = 0
$script:cleanupVerificationCalls = 0
$script:cleanupLog = [Collections.Generic.List[string]]::new()
function script:Get-InteractiveWin11ProcessTreeSnapshot {
    param([int] $RootProcessId, [datetime] $RootStartedAt)
    $script:cleanupSnapshotCalls++
    $script:cleanupLog.Add('snapshot')
    if ($script:cleanupSnapshotFailure) { throw 'simulated snapshot failure' }
    @([pscustomobject]@{ ProcessId = $RootProcessId; CreationDate = $RootStartedAt })
}
function script:Stop-InteractiveWin11RootHandle {
    param(
        [System.Diagnostics.Process] $Process,
        [IntPtr] $RootProcessHandle,
        [datetime] $RootStartedAt
    )
    $script:cleanupRootStopCalls++
    $script:cleanupLog.Add('stop')
    $Process.Kill()
    if (-not $Process.WaitForExit(5000)) { throw 'mock root process did not exit' }
}
function script:Wait-InteractiveWin11ProcessTreeSnapshotExited {
    param([object[]] $Snapshot)
    $script:cleanupVerificationCalls++
    $script:cleanupLog.Add('verify')
    if ($script:cleanupVerificationFailure) { throw 'simulated verification query failure' }
    $script:cleanupVerificationExited
}
function script:Start-CleanupContractProcess {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-Command')
    $startInfo.ArgumentList.Add('Start-Sleep -Seconds 30')
    [System.Diagnostics.Process]::Start($startInfo)
}
try {
    $process = Start-CleanupContractProcess
    $script:cleanupVerificationFailure = $true
    Stop-InteractiveWin11Process -Process $process -Contained
    if (-not $process.HasExited -or
        ($script:cleanupLog -join '|') -cne 'snapshot|stop|verify') {
        throw 'Contained cleanup must snapshot, stop the captured root handle, then verify descendants in that order.'
    }
    $script:cleanupLog.Clear()
    $process.Dispose()
    $process = $null

    $process = Start-CleanupContractProcess
    $script:cleanupVerificationFailure = $false
    $script:cleanupVerificationExited = $false
    $liveDescendantRejected = $false
    try { Stop-InteractiveWin11Process -Process $process -Contained } catch { $liveDescendantRejected = $true }
    if (-not $liveDescendantRejected -or -not $process.HasExited) {
        throw 'Contained cleanup accepted a successful verification query that reported live descendants.'
    }
    $process.Dispose()
    $process = $null

    $process = Start-CleanupContractProcess
    $script:cleanupSnapshotFailure = $true
    $script:cleanupVerificationExited = $true
    Stop-InteractiveWin11Process -Process $process -Contained
    if (-not $process.HasExited) {
        throw 'Contained cleanup did not terminate the root after initial snapshot failure.'
    }
    $process.Dispose()
    $process = $null

    $process = Start-CleanupContractProcess
    $script:cleanupSnapshotFailure = $true
    Stop-InteractiveWin11Process -Process $process -AllowAlreadyExited
    if (-not $process.HasExited) {
        throw 'Already-exited cleanup did not terminate the root after a snapshot race.'
    }
    $process.Dispose()
    $process = $null

    $conflictingModesRejected = $false
    try {
        Stop-InteractiveWin11Process `
            -Process ([System.Diagnostics.Process]::GetCurrentProcess()) `
            -Contained `
            -RequireLiveRoot
    }
    catch { $conflictingModesRejected = $true }
    if (-not $conflictingModesRejected) {
        throw 'Interactive cleanup accepted conflicting lifecycle modes.'
    }
    if ($script:cleanupSnapshotCalls -lt 1 -or
        $script:cleanupRootStopCalls -lt 1 -or
        $script:cleanupVerificationCalls -lt 1) {
        throw 'Interactive cleanup behavior probes did not invoke every lifecycle mock.'
    }
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
    Remove-Item -LiteralPath Function:\Get-InteractiveWin11ProcessTreeSnapshot -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Stop-InteractiveWin11RootHandle -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Wait-InteractiveWin11ProcessTreeSnapshotExited -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Start-CleanupContractProcess -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Stop-InteractiveWin11Process -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name cleanupSnapshotFailure, cleanupVerificationFailure, cleanupVerificationExited, cleanupSnapshotCalls, cleanupRootStopCalls, cleanupVerificationCalls, cleanupLog -ErrorAction SilentlyContinue
}

$containmentFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InteractiveWin11ContainmentArguments'
    }, $true))
$launchArgumentFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InteractiveWin11LaunchArguments'
    }, $true))
# Exact-one is a single-source-of-truth invariant for launch policy ownership.
if ($containmentFunctions.Count -ne 1 -or
    $launchArgumentFunctions.Count -ne 1) {
    throw 'Interactive Win11 launch policy must have one containment owner and one launch composer.'
}
. ([scriptblock]::Create($containmentFunctions[0].Extent.Text))
. ([scriptblock]::Create($launchArgumentFunctions[0].Extent.Text))
try {
    $containmentArguments = @(Get-InteractiveWin11ContainmentArguments)
    if (($containmentArguments -join '|') -ne
        '--linux-cgroup=always|--linux-cgroup-hard-fail=true|--windows-job-object-kill-on-close=true') {
        throw 'Interactive containment behavior did not return the three required hard-fail arguments.'
    }

    $script:containmentForwardCalls = 0
    function script:Get-InteractiveWin11ContainmentArguments {
        $script:containmentForwardCalls++
        '--contract-containment-probe'
    }
    $launchArguments = @(
        Get-InteractiveWin11LaunchArguments -Layout ([ordered]@{ SandboxId = 'contract-sandbox' })
    )
    if ($script:containmentForwardCalls -ne 1 -or
        ($launchArguments -join '|') -ne
            '--contract-containment-probe|--single-instance=false|--class=noctty-interactive-contract-sandbox|--command=cmd.exe') {
        throw 'Interactive launch composition did not invoke containment policy once and append isolation arguments.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-InteractiveWin11ContainmentArguments -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-InteractiveWin11LaunchArguments -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name containmentForwardCalls -ErrorAction SilentlyContinue
}
$interactiveHarnessFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'test\windows') -Filter 'interactive-win11-*.ps1' -File
)
$launchContainmentViolations = [Collections.Generic.List[string]]::new()
$forbiddenConfigOverrides = [Collections.Generic.List[string]]::new()
foreach ($file in @($interactiveHarnessFiles) + @(Get-Item -LiteralPath $interactiveWin11Lib)) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in [regex]::Matches($content, '[''"]--single-instance=false[''"]')) {
        $prefixStart = [math]::Max(0, $match.Index - 512)
        $prefix = $content.Substring($prefixStart, $match.Index - $prefixStart)
        if ($prefix -notmatch '\bGet-InteractiveWin11(?:Launch|Containment)Arguments\b') {
            [void]$launchContainmentViolations.Add("$($file.Name):$($match.Index)")
        }
    }
    if ($file.FullName -ne $interactiveWin11Lib -and
        $content -match '(?im)^\s*(?:linux-cgroup|linux-cgroup-hard-fail|windows-job-object-kill-on-close)\s*=') {
        [void]$forbiddenConfigOverrides.Add($file.Name)
    }
}
if ($launchContainmentViolations.Count -ne 0) {
    throw "Interactive launch arguments bypass Job Object containment: $($launchContainmentViolations -join ', ')"
}
if ($forbiddenConfigOverrides.Count -ne 0) {
    throw "Interactive harness config overrides CLI containment: $($forbiddenConfigOverrides -join ', ')"
}

$cleanupContractViolations = [Collections.Generic.List[string]]::new()
$verificationContractsRunner = Join-Path $root 'Test-VerificationContracts.ps1'
$verificationContractsDirectory = Join-Path $root 'contracts'
$cleanupScriptFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'test\windows') -Filter '*.ps1' -File -Recurse |
        Where-Object {
            $_.FullName -ne $verificationContractsRunner -and
                -not $_.FullName.StartsWith(
                    $verificationContractsDirectory + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase
                )
        }
)
foreach ($file in $cleanupScriptFiles) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "PowerShell parser errors while checking cleanup contract: $($file.FullName)"
    }
    foreach ($command in @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Stop-InteractiveWin11Process'
            }, $true))) {
        $text = $command.Extent.Text
        $modeCount = @(
            $text -match '(?i)(?:^|\s)-Contained(?:\s|$)'
            $text -match '(?i)(?:^|\s)-RequireLiveRoot(?:\s|$)'
            $text -match '(?i)(?:^|\s)-AllowAlreadyExited(?:\s|$)'
        ).Where({ $_ }).Count
        if ($modeCount -ne 1 -or
            ($text -match '(?i)(?:^|\s)-AllowAlreadyExited(?:\s|$)' -and $file.Name -ne 'vt-probe-win32-conformance.ps1')) {
            [void]$cleanupContractViolations.Add("$($file.Name):$($command.Extent.StartLineNumber): $text")
        }
    }
}
if ($cleanupContractViolations.Count -ne 0) {
    throw "Interactive cleanup calls lack exactly one explicit lifecycle contract:`n$($cleanupContractViolations -join "`n")"
}
$jobObjectSource = Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32_job_object.zig') -Raw
$commandSource = Get-Content -LiteralPath (Join-Path $repoRoot 'src\Command.zig') -Raw
if ($jobObjectSource -notmatch 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE' -or
    $jobObjectSource -notmatch 'kill_on_close' -or
    $commandSource -notmatch '(?s)CREATE_SUSPENDED.*?AssignProcessToJobObject.*?ResumeThread') {
    throw 'Windows child containment must assign the suspended process to a kill-on-close Job Object before resume.'
}

# Native entry-point signatures are genuine FFI structure; private cleanup
# names and error strings are covered by the executed lifecycle probes above.
Invoke-ContractTable -Contracts @(
    @{
        File = $interactiveWin11Lib
        Content = {
            $interactiveWin11LibText
        }
        Pattern = ([regex]::Escape('public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);'))
        Kind = 'Text'
        Description = 'native root fallback termination declaration'
    }
    @{
        File = $interactiveWin11Lib
        Content = {
            $interactiveWin11LibText
        }
        Pattern = ([regex]::Escape('public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);'))
        Kind = 'Text'
        Description = 'native root termination wait declaration'
    }
)
