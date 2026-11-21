#requires -Version 7.0
<#
.SYNOPSIS
The script-closure walker: which files a set of PowerShell entry points can run, read from the syntax tree.

.DESCRIPTION
Dot-source this file. `Get-ScriptClosure` walks from repo-relative entry scripts, through every edge, to the files
they reach, in the working tree or at a git ref (`git show <ref>:<path>`), so the hidden-desktop GUI suite's
selection (scripts/ci-gui-selection.ps1) can walk both sides of a pull request, and its contract
(Contracts.99-GuiHiddenSelection.ps1) can scan exactly what a hosted leaf loads.

An edge (design v7 §4.3, "What the walker counts as an edge"):
  * a `.` or `&` whose target is, or may be, a .ps1, .psm1, .cmd or .bat file;
  * a `-File` or `-Command` argument to powershell or pwsh (a splatted argument counts as one that may be);
  * `cmd /c` or `/k` with a script argument;
  * an `Add-Type -Path` source (a C# file: a member, not walked further);
  * a command line built as a string that runs `-File`, which no other edge shows.
A target resolves when it is a constant path composition: a literal, `$PSScriptRoot`, `Join-Path`, `Split-Path
-Parent`, string concatenation or an expandable string over those, or a variable assigned once (or always the same
value) from such a composition. A resolved .ps1/.psm1 target is walked; a .cmd/.bat target is a member and not
walked.
Not edges:
  * a variable typed or assigned only as [scriptblock] (a callback): its body is part of the file and so scanned;
  * an inline scriptblock;
  * a native executable: a target that resolves to, or is assigned from, an .exe or .com path, a `*ExePath`/`*CliPath`
    helper, or `Get-Command ...).Source`; it is a launch, not a script;
  * `-File` on any other command (`Get-ChildItem -File`).
An edge whose target does not resolve fails the walk unless the legacy-only list below names it, with its guard.
#>

# Edges no static walk can resolve, each kept by a guard that stops it in hosted mode. An entry names its file and
# an anchor: the edge command's own text, whitespace collapsed (or, for a string-built command line, a substring of
# the string). A listed file that is in the closure but no longer holds its anchor fails the walk, so the list
# cannot go stale. Never identify an entry by a line number.
$script:CiScriptClosureLegacyEdges = @(
    [pscustomobject]@{
        File = 'scripts/interactive-win11-lib.ps1'
        Anchor = '& $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $LauncherPath @ArgumentList'
        Guard = 'The bootstrap re-launch through dev-windows.cmd. Hosted mode skips it at both entry points (Invoke-InteractiveWin11HarnessMain and vt-probe''s own condition), and Invoke-InteractiveWin11Bootstrap throws when NOCTTY_GUI_HIDDEN_DESKTOP is set.'
    }
    [pscustomobject]@{
        File = 'scripts/interactive-win11-lib.ps1'
        Anchor = '& cmd /c $devWindowsCmd zig build -Demit-exe=true @optimizeArguments'
        Guard = 'The leaf build. Invoke-InteractiveWin11Build throws when NOCTTY_GUI_HIDDEN_DESKTOP is set; the runner stages a prepared build.'
    }
    [pscustomobject]@{
        File = 'test/windows/vt-probe-win32-conformance.ps1'
        Anchor = '& powershell.exe @scriptArgs'
        Guard = 'The -Runtime children (interactive-win11-command-finish.ps1, interactive-win11-progress.ps1). vt-probe refuses -Runtime when NOCTTY_GUI_HIDDEN_DESKTOP is set, before it builds the child''s arguments, and the plan runs it without -Runtime.'
    }
    [pscustomobject]@{
        File = 'test/windows/hidden-win11-lib.ps1'
        Anchor = '-NoProfile -NonInteractive -File "{1}"'
        Guard = 'A command line hidden-win11-lib.ps1 builds as a string for CreateProcessW (its own hosted driver). The runner does not call it.'
    }
    [pscustomobject]@{
        File = 'test/windows/hidden-win11-local-lib.ps1'
        Anchor = '-NoProfile -NonInteractive -File "{1}"'
        Guard = 'Invoke-LocalHiddenDriver runs its caller''s own -Script again as the driver. Its target is the caller, which is already an entry of the walk.'
    }
)

function ConvertTo-CiScriptRepoPath {
    # A Windows or POSIX path, absolute under $RepoRoot or relative to it, as a repo-relative '/' path with `.` and
    # `..` collapsed; $null when it leaves the repository.
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $Path)
    $root = $RepoRoot.Replace('/', '\').TrimEnd('\')
    $value = $Path.Replace('/', '\')
    if ($value.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { $value = $value.Substring($root.Length + 1) }
    elseif ([IO.Path]::IsPathRooted($value)) { return $null }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $value.Split('\')) {
        if ($part -eq '' -or $part -eq '.') { continue }
        if ($part -eq '..') {
            if ($parts.Count -eq 0) { return $null }
            $parts.RemoveAt($parts.Count - 1); continue
        }
        $parts.Add($part)
    }
    if ($parts.Count -eq 0) { return $null }
    return ($parts -join '/')
}

function New-CiScriptFileReader {
    # A reader: param([string] $RepoPath) returns the file's text, or $null when it does not exist. With -Ref it reads
    # `git show <ref>:<path>` in $RepoRoot; otherwise the working tree.
    param([Parameter(Mandatory)] [string] $RepoRoot, [string] $Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) {
        return {
            param([string] $RepoPath)
            $full = Join-Path $RepoRoot ($RepoPath.Replace('/', '\'))
            if (-not [IO.File]::Exists($full)) { return $null }
            return [IO.File]::ReadAllText($full)
        }.GetNewClosure()
    }
    return {
        param([string] $RepoPath)
        $lines = & git -C $RepoRoot show "${Ref}:$RepoPath" 2>$null
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($code -ne 0) { return $null }
        return (@($lines) -join "`n")
    }.GetNewClosure()
}

function Get-CiScriptCommandName {
    # The name a command element calls by, lower-case, for a bare word; $null otherwise.
    param($Element)
    if ($Element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $Element.Value.ToLowerInvariant() }
    return $null
}

function Test-CiScriptPowerShellName {
    param([string] $Name)
    if (-not $Name) { return $false }
    $leaf = ($Name -split '[\\/]')[-1]
    return $leaf -in @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe')
}

function Test-CiScriptTargetKind {
    # 'script' for .ps1/.psm1, 'batch' for .cmd/.bat, 'native' for .exe/.com, else 'other'.
    param([string] $Path)
    if (-not $Path) { return 'other' }
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.ps1', '.psm1')) { return 'script' }
    if ($extension -in @('.cmd', '.bat')) { return 'batch' }
    if ($extension -in @('.exe', '.com')) { return 'native' }
    return 'other'
}

# The resolver. Each call returns @{ Kind = 'path'|'scriptblock'|'native'|'unresolved'; Value = <string> }.
function Resolve-CiScriptValue {
    param(
        [Parameter(Mandatory)] $Node,
        [Parameter(Mandatory)] [hashtable] $Context,
        [int] $Depth = 0
    )
    $unresolved = @{ Kind = 'unresolved'; Value = $null }
    if ($Depth -gt 12 -or $null -eq $Node) { return $unresolved }
    switch ($Node) {
        { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } { return @{ Kind = 'path'; Value = $_.Value } }
        { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } { return @{ Kind = 'scriptblock'; Value = $null } }
        { $_ -is [System.Management.Automation.Language.ParenExpressionAst] } { return Resolve-CiScriptValue $_.Pipeline $Context ($Depth + 1) }
        { $_ -is [System.Management.Automation.Language.SubExpressionAst] } {
            if ($_.SubExpression.Statements.Count -eq 1) { return Resolve-CiScriptValue $_.SubExpression.Statements[0] $Context ($Depth + 1) }
            return $unresolved
        }
        { $_ -is [System.Management.Automation.Language.PipelineAst] } {
            if ($_.PipelineElements.Count -ne 1) { return $unresolved }
            return Resolve-CiScriptValue $_.PipelineElements[0] $Context ($Depth + 1)
        }
        { $_ -is [System.Management.Automation.Language.CommandExpressionAst] } { return Resolve-CiScriptValue $_.Expression $Context ($Depth + 1) }
        { $_ -is [System.Management.Automation.Language.ConvertExpressionAst] } {
            if ($_.Type.TypeName.Name -in @('scriptblock', 'System.Management.Automation.ScriptBlock')) { return @{ Kind = 'scriptblock'; Value = $null } }
            return Resolve-CiScriptValue $_.Child $Context ($Depth + 1)
        }
        { $_ -is [System.Management.Automation.Language.BinaryExpressionAst] } {
            if ($_.Operator -ne [System.Management.Automation.Language.TokenKind]::Plus) { return $unresolved }
            $left = Resolve-CiScriptValue $_.Left $Context ($Depth + 1)
            $right = Resolve-CiScriptValue $_.Right $Context ($Depth + 1)
            if ($left.Kind -eq 'path' -and $right.Kind -eq 'path') { return @{ Kind = 'path'; Value = $left.Value + $right.Value } }
            return $unresolved
        }
        { $_ -is [System.Management.Automation.Language.ExpandableStringExpressionAst] } {
            # Replace each nested expression, last first, by its resolved value.
            $nested = @($_.NestedExpressions | Sort-Object { $_.Extent.StartOffset } -Descending)
            $result = $_.Extent.Text
            if ($result.Length -lt 2) { return $unresolved }
            $result = $result.Substring(1, $result.Length - 2)
            $base = $_.Extent.StartOffset + 1
            foreach ($inner in $nested) {
                $value = Resolve-CiScriptValue $inner $Context ($Depth + 1)
                if ($value.Kind -ne 'path') { return $unresolved }
                $start = $inner.Extent.StartOffset - $base
                $result = $result.Substring(0, $start) + $value.Value + $result.Substring($start + $inner.Extent.Text.Length)
            }
            if ($result.Contains('`')) { return $unresolved }
            return @{ Kind = 'path'; Value = $result }
        }
        { $_ -is [System.Management.Automation.Language.MemberExpressionAst] } {
            if ($_.Static -or $_.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $unresolved }
            $member = $_.Member.Value
            # (Get-Command pwsh.exe).Source and the like: a native executable.
            if ($member -ieq 'Source' -and $_.Expression.Extent.Text -match '(?i)Get-Command') { return @{ Kind = 'native'; Value = $null } }
            # The harness libraries' normalized repository root (Initialize-InteractiveWin11Sandbox's .RepoRoot, a
            # layout's .RepoRoot): the repository root.
            if ($member -ceq 'RepoRoot') { return @{ Kind = 'path'; Value = $Context.RepoRoot } }
            # A property of a hashtable this file builds (`@{ Reader = $reader }`, read as `$x.Reader`): every value
            # the file gives that key, which must agree.
            $values = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($table in @($Context.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
                foreach ($pair in $table.KeyValuePairs) {
                    if ($pair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $pair.Item1.Value -ieq $member) {
                        $values.Add((Resolve-CiScriptValue $pair.Item2 $Context ($Depth + 1)))
                    }
                }
            }
            if ($values.Count -eq 0) { return $unresolved }
            foreach ($kind in @('scriptblock', 'native')) {
                if (@($values | Where-Object { $_.Kind -ne $kind }).Count -eq 0) { return @{ Kind = $kind; Value = $null } }
            }
            $paths = @($values | Where-Object { $_.Kind -eq 'path' } | ForEach-Object { $_.Value } | Sort-Object -Unique)
            if ($paths.Count -eq 1 -and @($values | Where-Object { $_.Kind -ne 'path' }).Count -eq 0) { return @{ Kind = 'path'; Value = $paths[0] } }
            return $unresolved
        }
        { $_ -is [System.Management.Automation.Language.VariableExpressionAst] } {
            $name = $_.VariablePath.UserPath
            if ($name -ieq 'PSScriptRoot') { return @{ Kind = 'path'; Value = $Context.Directory } }
            if ($name -ieq 'PSCommandPath') { return @{ Kind = 'path'; Value = $Context.FilePath } }
            return Resolve-CiScriptVariable $name $_ $Context ($Depth + 1)
        }
        { $_ -is [System.Management.Automation.Language.CommandAst] } {
            $elements = $_.CommandElements
            $name = Get-CiScriptCommandName $elements[0]
            if (-not $name) { return $unresolved }
            if ($name -match '(?i)^get-[a-z0-9-]*(exepath|clipath)$') { return @{ Kind = 'native'; Value = $null } }
            if ($name -ieq 'join-path') {
                $positional = [System.Collections.Generic.List[object]]::new()
                $named = @{}
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $argument = $element.Argument
                        if ($null -eq $argument -and $i + 1 -lt $elements.Count) { $i++; $argument = $elements[$i] }
                        $named[$element.ParameterName.ToLowerInvariant()] = $argument
                    } else { $positional.Add($element) }
                }
                $pathNode = $(if ($named.ContainsKey('path')) { $named['path'] } elseif ($positional.Count -ge 1) { $positional[0] } else { $null })
                $childNode = $(if ($named.ContainsKey('childpath')) { $named['childpath'] } elseif ($positional.Count -ge 2) { $positional[$(if ($named.ContainsKey('path')) { 0 } else { 1 })] } else { $null })
                if ($null -eq $pathNode -or $null -eq $childNode) { return $unresolved }
                $left = Resolve-CiScriptValue $pathNode $Context ($Depth + 1)
                $right = Resolve-CiScriptValue $childNode $Context ($Depth + 1)
                # `Join-Path <anything> 'noctty.com'`: a native executable, whatever directory it is in.
                if ($right.Kind -eq 'path' -and (Test-CiScriptTargetKind $right.Value) -eq 'native') { return @{ Kind = 'native'; Value = $null } }
                if ($left.Kind -ne 'path' -or $right.Kind -ne 'path') { return $unresolved }
                return @{ Kind = 'path'; Value = ($left.Value.TrimEnd('\', '/') + '\' + $right.Value.TrimStart('\', '/')) }
            }
            if ($name -ieq 'split-path') {
                $parent = $false; $target = $null
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ($element.ParameterName -ieq 'Parent') { $parent = $true; continue }
                        if ($element.ParameterName -in @('Path', 'LiteralPath')) {
                            $target = $(if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $i++; $elements[$i] })
                            continue
                        }
                        return $unresolved
                    }
                    $target = $element
                }
                if (-not $parent -or $null -eq $target) { return $unresolved }
                $value = Resolve-CiScriptValue $target $Context ($Depth + 1)
                if ($value.Kind -ne 'path') { return $unresolved }
                $trimmed = $value.Value.TrimEnd('\', '/')
                $cut = $trimmed.LastIndexOfAny([char[]]@('\', '/'))
                if ($cut -le 0) { return $unresolved }
                return @{ Kind = 'path'; Value = $trimmed.Substring(0, $cut) }
            }
            return $unresolved
        }
        { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] } { return Resolve-CiScriptValue $_.Right $Context ($Depth + 1) }
    }
    return $unresolved
}

function Get-CiScriptFunctionOf {
    # The innermost function definition around a node, or $null at script level.
    param($Node)
    $walk = $Node.Parent
    while ($null -ne $walk) {
        if ($walk -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $walk }
        $walk = $walk.Parent
    }
    return $null
}

function Resolve-CiScriptVariable {
    # The value a variable holds where it is read ($Use). Flow-sensitive, as far as a straight-line harness needs:
    #   * in the same function as the read (or at script level for a script-level read), the last assignment before
    #     the read decides; a parameter of that function, typed [scriptblock] or with a default, decides when no
    #     assignment precedes the read;
    #   * a read in a function that assigns nothing before it sees the script-level variable: every script-level
    #     assignment must agree;
    #   * a foreach variable is unresolved.
    # A scriptblock when the deciding values are all scriptblocks, native when they are all native executables.
    param([string] $Name, $Use, [hashtable] $Context, [int] $Depth)
    $unresolved = @{ Kind = 'unresolved'; Value = $null }
    $key = $Name.ToLowerInvariant() + '@' + $Use.Extent.StartOffset
    if ($Context.Resolving.Contains($key)) { return $unresolved }
    [void]$Context.Resolving.Add($key)
    try {
        $useOffset = $Use.Extent.StartOffset
        $useFunction = Get-CiScriptFunctionOf $Use
        $sameScope = { param($node) [object]::ReferenceEquals((Get-CiScriptFunctionOf $node), $useFunction) }
        foreach ($loop in @($Context.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))) {
            if ($loop.Variable.VariablePath.UserPath -ieq $Name -and (& $sameScope $loop.Variable)) { return $unresolved }
        }
        $assignments = [System.Collections.Generic.List[object]]::new()
        foreach ($assignment in @($Context.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
            $left = $assignment.Left
            $typedScriptblock = $false
            if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                $typedScriptblock = $left.Type.TypeName.Name -in @('scriptblock', 'System.Management.Automation.ScriptBlock')
                $left = $left.Child
            }
            if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            if ($left.VariablePath.UserPath -ine $Name) { continue }
            $assignments.Add([pscustomobject]@{ Node = $assignment; TypedScriptblock = $typedScriptblock })
        }
        $valueOf = {
            param($entry)
            if ($entry.TypedScriptblock) { return @{ Kind = 'scriptblock'; Value = $null } }
            return Resolve-CiScriptValue $entry.Node.Right $Context ($Depth + 1)
        }
        $preceding = @($assignments | Where-Object { $_.Node.Extent.EndOffset -le $useOffset -and (& $sameScope $_.Node) } |
            Sort-Object { $_.Node.Extent.StartOffset })
        if ($preceding.Count -gt 0) { return & $valueOf $preceding[-1] }
        # A parameter of the read's own function (or of the script).
        $owner = $(if ($useFunction) { $useFunction } else { $Context.Ast })
        foreach ($parameter in @($owner.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true))) {
            if ($parameter.Name.VariablePath.UserPath -ine $Name) { continue }
            if (-not [object]::ReferenceEquals((Get-CiScriptFunctionOf $parameter), $useFunction)) { continue }
            $typed = @($parameter.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.TypeConstraintAst] -and
                $_.TypeName.Name -in @('scriptblock', 'System.Management.Automation.ScriptBlock')
            })
            if ($typed.Count -gt 0) { return @{ Kind = 'scriptblock'; Value = $null } }
            if ($parameter.DefaultValue) { return Resolve-CiScriptValue $parameter.DefaultValue $Context ($Depth + 1) }
            return $unresolved
        }
        if (-not $useFunction) { return $unresolved }
        # A function's read of a script-level variable: every script-level assignment must agree.
        $scriptLevel = @($assignments | Where-Object { $null -eq (Get-CiScriptFunctionOf $_.Node) })
        if ($scriptLevel.Count -eq 0) { return $unresolved }
        $values = @($scriptLevel | ForEach-Object { & $valueOf $_ })
        foreach ($kind in @('scriptblock', 'native')) {
            if (@($values | Where-Object { $_.Kind -ne $kind }).Count -eq 0) { return @{ Kind = $kind; Value = $null } }
        }
        $paths = @($values | Where-Object { $_.Kind -eq 'path' } | ForEach-Object { $_.Value } | Sort-Object -Unique)
        if ($paths.Count -eq 1 -and @($values | Where-Object { $_.Kind -ne 'path' }).Count -eq 0) { return @{ Kind = 'path'; Value = $paths[0] } }
        return $unresolved
    }
    finally { [void]$Context.Resolving.Remove($key) }
}

function ConvertTo-CiScriptAnchor {
    param([string] $Text)
    return ($Text -replace '\s+', ' ').Trim()
}

# The edges of one parsed file: @{ Targets = list of repo paths (resolved); Unresolved = list of anchors;
# CSharp = list of repo paths (Add-Type -Path) }.
function Get-CiScriptFileEdges {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $Text
    )
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$RepoPath does not parse: $($errors[0].Message)" }
    $fullPath = Join-Path $RepoRoot ($RepoPath.Replace('/', '\'))
    $context = @{
        RepoRoot = $RepoRoot
        Ast = $ast
        FilePath = $fullPath
        Directory = Split-Path -Parent $fullPath
        Resolving = [System.Collections.Generic.HashSet[string]]::new()
    }
    $targets = [System.Collections.Generic.List[string]]::new()
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $csharp = [System.Collections.Generic.List[string]]::new()

    $addTarget = {
        param($Node, [string] $Why)
        $value = Resolve-CiScriptValue $Node $context
        if ($value.Kind -eq 'scriptblock' -or $value.Kind -eq 'native') { return }
        if ($value.Kind -eq 'path') {
            $kind = Test-CiScriptTargetKind $value.Value
            if ($kind -eq 'native') { return }
            # A bare word that names a command (`cmd`, `git`): not a script. A path with no script, batch or
            # native extension may still run a script (PowerShell resolves one), so it stays unresolved below.
            if ($kind -eq 'other' -and $value.Value -notmatch '[\\/]') { return }
            if ($kind -eq 'script' -or $kind -eq 'batch') {
                $repo = ConvertTo-CiScriptRepoPath -RepoRoot $RepoRoot -Path $(if ([IO.Path]::IsPathRooted($value.Value)) { $value.Value } else { Join-Path $context.Directory $value.Value })
                if ($repo) { $targets.Add($repo); return }
            }
        }
        $unresolved.Add($Why)
    }

    foreach ($command in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $elements = $command.CommandElements
        $anchor = ConvertTo-CiScriptAnchor $command.Extent.Text
        $operator = $command.InvocationOperator
        $first = $elements[0]
        $name = Get-CiScriptCommandName $first
        if ($operator -eq [System.Management.Automation.Language.TokenKind]::Dot -or $operator -eq [System.Management.Automation.Language.TokenKind]::Ampersand) {
            if ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            # `& cmd /c <script>` and `& powershell -File <script>` are judged by their arguments below.
            if ($name -and ($name -in @('cmd', 'cmd.exe') -or (Test-CiScriptPowerShellName $name))) {
                # fall through to the argument checks
            } else {
                $before = $targets.Count + $unresolved.Count
                & $addTarget $first $anchor
                # A script or batch target whose arguments also run PowerShell -File is one edge (the anchor).
                if ($targets.Count + $unresolved.Count -gt $before) { continue }
                if ($name -and -not (Test-CiScriptPowerShellName $name)) { continue }
            }
        }
        if (-not $name -and $operator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
            $first -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $resolved = Resolve-CiScriptValue $first $context
            if ($resolved.Kind -eq 'native') { continue }
        }
        if (-not $name) { continue }
        if ($name -ieq 'add-type') {
            for ($i = 1; $i -lt $elements.Count; $i++) {
                $element = $elements[$i]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -in @('Path', 'LiteralPath')) {
                    $argument = $(if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] })
                    $value = Resolve-CiScriptValue $argument $context
                    $repo = $(if ($value.Kind -eq 'path') { ConvertTo-CiScriptRepoPath -RepoRoot $RepoRoot -Path $(if ([IO.Path]::IsPathRooted($value.Value)) { $value.Value } else { Join-Path $context.Directory $value.Value }) })
                    if ($repo) { $csharp.Add($repo) } else { $unresolved.Add($anchor) }
                }
            }
            continue
        }
        if (Test-CiScriptPowerShellName $name) {
            for ($i = 1; $i -lt $elements.Count; $i++) {
                $element = $elements[$i]
                if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) { $unresolved.Add($anchor); break }
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -in @('File', 'Command', 'f', 'c')) {
                    $argument = $(if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] })
                    if ($element.ParameterName -in @('Command', 'c')) { $unresolved.Add($anchor) } else { & $addTarget $argument $anchor }
                    break
                }
            }
            continue
        }
        if ($name -in @('cmd', 'cmd.exe')) {
            for ($i = 1; $i -lt $elements.Count - 1; $i++) {
                $element = $elements[$i]
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $element.Value -match '^(?i)/[ck]$') {
                    & $addTarget $elements[$i + 1] $anchor
                    break
                }
            }
            continue
        }
    }

    # A command line built as a string that runs -File: no AST edge shows its target.
    foreach ($string in @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))) {
        $value = $string.Value
        if ($value -match '(?i)(?:^|\s)-File\s+(?:"|''|\{\d+\}|\$)') { $unresolved.Add((ConvertTo-CiScriptAnchor $value)) }
    }
    return @{ Targets = $targets; Unresolved = $unresolved; CSharp = $csharp }
}

function Get-ScriptClosure {
    <#
    .SYNOPSIS
    The files the entries can run. Returns Members (sorted repo paths), Edges, Unresolved (file + anchor, not on the
    legacy list), Legacy (listed edges met), Stale (listed edges whose file is a member but whose anchor is gone),
    Missing (resolved targets or entries that do not exist) and Problems (all failures as text). The walk passes when
    Problems is empty.
    #>
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string[]] $Entries,
        [string] $Ref,
        [scriptblock] $Reader,
        [object[]] $LegacyEdges = $script:CiScriptClosureLegacyEdges
    )
    if (-not $Reader) { $Reader = New-CiScriptFileReader -RepoRoot $RepoRoot -Ref $Ref }
    $members = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $edges = [System.Collections.Generic.List[object]]::new()
    $unresolved = [System.Collections.Generic.List[object]]::new()
    $legacyMet = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    $anchorsByFile = @{}
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($entry in $Entries) {
        $repo = ConvertTo-CiScriptRepoPath -RepoRoot $RepoRoot -Path $entry
        if (-not $repo) { $problems.Add("entry outside the repository: $entry"); continue }
        $queue.Enqueue($repo)
    }
    while ($queue.Count -gt 0) {
        $path = $queue.Dequeue()
        if ($members.Contains($path)) { continue }
        $text = & $Reader $path
        if ($null -eq $text) { $missing.Add($path); $problems.Add("missing: $path"); continue }
        [void]$members.Add($path)
        if ((Test-CiScriptTargetKind $path) -ne 'script') { continue }
        try { $found = Get-CiScriptFileEdges -RepoRoot $RepoRoot -RepoPath $path -Text $text }
        catch { $problems.Add($_.Exception.Message); continue }
        $anchorsByFile[$path] = @($found.Unresolved)
        foreach ($target in $found.Targets) { $edges.Add([pscustomobject]@{ From = $path; To = $target }); $queue.Enqueue($target) }
        foreach ($source in $found.CSharp) { $edges.Add([pscustomobject]@{ From = $path; To = $source }); $queue.Enqueue($source) }
        foreach ($anchor in $found.Unresolved) {
            $listed = @($LegacyEdges | Where-Object {
                [string]::Equals($_.File, $path, [StringComparison]::Ordinal) -and
                ([string]::Equals($anchor, $_.Anchor, [StringComparison]::Ordinal) -or $anchor.Contains($_.Anchor))
            })
            if ($listed.Count -gt 0) { $legacyMet.Add([pscustomobject]@{ File = $path; Anchor = $listed[0].Anchor; Guard = $listed[0].Guard }) }
            else {
                $unresolved.Add([pscustomobject]@{ File = $path; Anchor = $anchor })
                $problems.Add("unresolved edge in ${path}: $anchor")
            }
        }
    }
    $stale = [System.Collections.Generic.List[object]]::new()
    foreach ($listed in $LegacyEdges) {
        if (-not $members.Contains($listed.File)) { continue }
        $met = @($legacyMet | Where-Object { $_.File -ceq $listed.File -and $_.Anchor -ceq $listed.Anchor })
        if ($met.Count -eq 0) { $stale.Add($listed); $problems.Add("legacy-only edge no longer in $($listed.File): $($listed.Anchor)") }
    }
    return [pscustomobject]@{
        Members = [string[]]@($members)
        Edges = $edges.ToArray()
        Unresolved = $unresolved.ToArray()
        Legacy = $legacyMet.ToArray()
        Stale = $stale.ToArray()
        Missing = $missing.ToArray()
        Problems = $problems.ToArray()
    }
}
