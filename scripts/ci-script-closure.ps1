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
    [pscustomobject]@{
        File = 'test/windows/gui-hidden-runner.ps1'
        Anchor = '-NoProfile -NonInteractive -File "{1}"'
        Guard = 'The runner starts each plan leaf as its own pwsh, a command line built as a string for CreateProcessW. Every plan leaf is an entry of the walk.'
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

function ConvertTo-CiScriptTargetPath {
    # The repo path a resolved edge target names, or $null. Only a rooted value counts. A relative one (`./helper.ps1`,
    # `..\x.ps1`, a bare `helper.ps1`) resolves at run time against the current location, for `.` and `&`, a child's
    # -File, cmd /c and Add-Type -Path alike, not beside the script, and no walk can know that location, so it stays
    # unresolved (CodeRabbit on #740: with a helper.ps1 both beside the script and in the working directory, the walk
    # took the wrong one). $PSScriptRoot, $PSCommandPath and a script-level $MyInvocation.MyCommand.Path anchor a value
    # to the script's own directory, and a harness layout's RepoRoot to the repository.
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $Value)
    if (-not [IO.Path]::IsPathRooted($Value)) { return $null }
    return ConvertTo-CiScriptRepoPath -RepoRoot $RepoRoot -Path $Value
}

function Test-CiScriptAtScriptLevel {
    # True when a node runs in the script's own scope: inside no function and no scriptblock.
    param($Node)
    for ($walk = $Node.Parent; $null -ne $walk; $walk = $walk.Parent) {
        if ($walk -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
            ($walk -is [System.Management.Automation.Language.ScriptBlockAst] -and $null -ne $walk.Parent)) { return $false }
    }
    return $true
}

function New-CiScriptFileReader {
    # A reader: param([string] $RepoPath) returns the file's text, or $null when the tree has no such file. With -Ref
    # it reads that ref's tree in $RepoRoot; otherwise the working tree.
    # Absent and unreadable are different answers, and only absence may let selection skip a side: a failed read taken
    # for "no file here" would let a base tree whose plan git could not read look like one without a plan (CodeRabbit
    # on #740). So a ref that does not name a readable tree throws here, the tree's listing decides absence, and a file
    # the tree lists that git cannot read (a missing object, a blobless clone offline) throws when it is read.
    # -Git replaces the git executable for the tests: param([string[]] $GitArguments), output on the pipeline, and it
    # sets $LASTEXITCODE.
    param([Parameter(Mandatory)] [string] $RepoRoot, [string] $Ref, [scriptblock] $Git)
    if ([string]::IsNullOrWhiteSpace($Ref)) {
        return {
            param([string] $RepoPath)
            $full = Join-Path $RepoRoot ($RepoPath.Replace('/', '\'))
            if (-not [IO.File]::Exists($full)) { return $null }
            return [IO.File]::ReadAllText($full)
        }.GetNewClosure()
    }
    if (-not $Git) { $Git = { param([string[]] $GitArguments) & git @GitArguments 2>$null } }
    $runGit = {
        param([string[]] $GitArguments)
        $output = & $Git (@('-C', $RepoRoot) + $GitArguments)
        $code = $LASTEXITCODE
        # A handled failure must not leave Actions' implicit `exit $LASTEXITCODE` failing the step (PKG-65).
        $global:LASTEXITCODE = 0
        if ($code -ne 0) { throw "git $($GitArguments[0]) for $Ref failed with exit code $code." }
        return , @($output)
    }.GetNewClosure()
    # Assigned, never wrapped in @(): $runGit returns its output as one array object.
    $tree = & $runGit @('rev-parse', '--verify', '--quiet', "$Ref^{tree}")
    if ($tree.Count -ne 1 -or [string]$tree[0] -cnotmatch '\A[0-9a-f]{40,64}\z') { throw "$Ref does not name a tree." }
    $treeId = [string]$tree[0]
    # The whole tree, listed once: path -> mode, type and object. -z keeps unusual names unquoted.
    $entries = [System.Collections.Generic.Dictionary[string, string[]]]::new([StringComparer]::Ordinal)
    $listing = & $runGit @('ls-tree', '-r', '-z', '--full-tree', $treeId)
    foreach ($record in (($listing -join "`n").Split([char]0))) {
        if ($record.Length -eq 0) { continue }
        $tab = $record.IndexOf([char]"`t")
        $meta = $(if ($tab -gt 0) { $record.Substring(0, $tab).Split(' ') } else { @() })
        if ($meta.Count -ne 3) { throw "git ls-tree for $Ref wrote a record it does not document." }
        $entries[$record.Substring($tab + 1)] = $meta
    }
    $texts = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    return {
        param([string] $RepoPath)
        $entry = $null
        if (-not $entries.TryGetValue($RepoPath, [ref]$entry) -or $entry[1] -cne 'blob') { return $null }
        if ($entry[0] -ceq '120000') { throw "$RepoPath is a symbolic link in $Ref." }
        $text = $null
        if (-not $texts.TryGetValue($RepoPath, [ref]$text)) {
            $text = (& $runGit @('cat-file', 'blob', $entry[2])) -join "`n"
            $texts[$RepoPath] = $text
        }
        return $text
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
            # $MyInvocation.MyCommand.Path in the script's own scope: this file (in a function or a scriptblock it
            # names that command instead).
            $inner = $_.Expression
            if ($member -in @('Path', 'Definition', 'Source') -and $inner -is [System.Management.Automation.Language.MemberExpressionAst] -and
                -not $inner.Static -and $inner.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $inner.Member.Value -ieq 'MyCommand' -and
                $inner.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $inner.Expression.VariablePath.UserPath -ieq 'MyInvocation') {
                if (Test-CiScriptAtScriptLevel $_) { return @{ Kind = 'path'; Value = $Context.FilePath } }
                return $unresolved
            }
            # (Get-Command pwsh.exe).Source and the like: a native executable.
            if ($member -ieq 'Source' -and $_.Expression.Extent.Text -match '(?i)Get-Command') { return @{ Kind = 'native'; Value = $null } }
            # The harness libraries' normalized repository root (Initialize-InteractiveWin11Sandbox's .RepoRoot, a
            # layout's .RepoRoot): the repository root.
            if ($member -ceq 'RepoRoot') { return @{ Kind = 'path'; Value = $Context.RepoRoot } }
            # A property of a hashtable this file builds (`@{ Reader = $reader }`, read as `$x.Reader`): every value
            # the file gives that key, in a hashtable or by assignment (`$x.Reader = ...`, `$x['Reader'] = ...`),
            # which must agree.
            $values = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($table in (Get-CiScriptNodes $Context HashtableAst)) {
                foreach ($pair in $table.KeyValuePairs) {
                    if ($pair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $pair.Item1.Value -ieq $member) {
                        $values.Add((Resolve-CiScriptValue $pair.Item2 $Context ($Depth + 1)))
                    }
                }
            }
            foreach ($assignment in (Get-CiScriptNodes $Context AssignmentStatementAst)) {
                $left = $assignment.Left
                $key = $(if ($left -is [System.Management.Automation.Language.MemberExpressionAst]) { $left.Member } elseif ($left -is [System.Management.Automation.Language.IndexExpressionAst]) { $left.Index })
                if ($key -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or $key.Value -ine $member) { continue }
                if ($assignment.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { $values.Add($unresolved); continue }
                $values.Add((Resolve-CiScriptValue $assignment.Right $Context ($Depth + 1)))
            }
            return Merge-CiScriptValues $values
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
                # Join-Path [-Path] <parent> [-ChildPath] <child> [<more children>...]: a named -Path or -ChildPath
                # takes its own place and the positionals fill the others in order, so `Join-Path -Path $root 'x'`
                # joins its one positional as the child (CodeRabbit on #740). Any other parameter (an abbreviation,
                # -Resolve's wildcards) is unresolved.
                $named = @{}
                $positional = [System.Collections.Generic.List[object]]::new()
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $parameter = $element.ParameterName.ToLowerInvariant()
                        if ($parameter -ceq 'pspath') { $parameter = 'path' }
                        if ($parameter -notin @('path', 'childpath', 'additionalchildpath') -or $named.ContainsKey($parameter)) { return $unresolved }
                        $argument = $element.Argument
                        if ($null -eq $argument) {
                            if ($i + 1 -ge $elements.Count) { return $unresolved }
                            $i++; $argument = $elements[$i]
                        }
                        $named[$parameter] = $argument
                    } else { $positional.Add($element) }
                }
                $parts = [System.Collections.Generic.List[object]]::new()
                $next = 0
                foreach ($slot in @('path', 'childpath')) {
                    if ($named.ContainsKey($slot)) { $parts.Add($named[$slot]) }
                    elseif ($next -lt $positional.Count) { $parts.Add($positional[$next]); $next++ }
                    else { return $unresolved }
                }
                while ($next -lt $positional.Count) { $parts.Add($positional[$next]); $next++ }
                if ($named.ContainsKey('additionalchildpath')) { $parts.Add($named['additionalchildpath']) }
                $values = @(foreach ($part in $parts) { Resolve-CiScriptValue $part $Context ($Depth + 1) })
                $last = $values[-1]
                # `Join-Path <anything> 'noctty.com'`: a native executable, whatever directory it is in.
                if ($last.Kind -eq 'path' -and (Test-CiScriptTargetKind $last.Value) -eq 'native') {
                    return @{ Kind = 'native'; Value = (Split-Path -Leaf $last.Value).ToLowerInvariant() }
                }
                if (@($values | Where-Object { $_.Kind -ne 'path' }).Count -ne 0) { return $unresolved }
                $joined = $values[0].Value
                foreach ($value in $values[1..($values.Count - 1)]) { $joined = $joined.TrimEnd('\', '/') + '\' + $value.Value.TrimStart('\', '/') }
                return @{ Kind = 'path'; Value = $joined }
            }
            if ($name -ieq 'split-path') {
                $target = $null
                for ($i = 1; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ($element.ParameterName -ieq 'Parent') { continue }
                        if ($element.ParameterName -in @('Path', 'LiteralPath')) {
                            $target = $(if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $i++; $elements[$i] })
                            continue
                        }
                        return $unresolved
                    }
                    $target = $element
                }
                # Without a switch, Split-Path gives the parent, as -Parent does.
                if ($null -eq $target) { return $unresolved }
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

function Get-CiScriptNodes {
    # Every node of one AST type in the file (a type name under System.Management.Automation.Language), found once per
    # file: the resolver asks for the same sets at every read.
    param([Parameter(Mandatory)] [hashtable] $Context, [Parameter(Mandatory)] [string] $Type)
    if (-not $Context.Nodes.ContainsKey($Type)) {
        $class = [type]"System.Management.Automation.Language.$Type"
        $Context.Nodes[$Type] = @($Context.Ast.FindAll({ param($n) $class.IsInstanceOfType($n) }.GetNewClosure(), $true))
    }
    return , $Context.Nodes[$Type]
}

function Get-CiScriptVariableName {
    # A variable reference's name without its scope qualifier (script:, global:, local:, private:, variable:,
    # using:), or $null for a provider path ($env:x, ${function:f}).
    param($Path)
    $user = $Path.UserPath
    if ($Path.IsUnqualified) { return $user }
    if ($Path.DriveName) { return $null }
    $colon = $user.IndexOf(':')
    if ($colon -lt 0) { return $user }
    if ($user.Substring(0, $colon) -notin @('script', 'global', 'local', 'private', 'variable', 'using')) { return $null }
    return $user.Substring($colon + 1)
}

function Get-CiScriptDynamicWrites {
    # The variables the file writes in ways the resolver cannot read as a value, found once per file: Set-Variable or
    # New-Variable (Unknown when the name is not a literal), a common -*Variable parameter, and [ref].
    param([Parameter(Mandatory)] [hashtable] $Context)
    if ($Context.ContainsKey('Dynamic')) { return $Context.Dynamic }
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $unknown = $false
    foreach ($command in (Get-CiScriptNodes $Context CommandAst)) {
        if ((Get-CiScriptCommandName $command.CommandElements[0]) -notin @('set-variable', 'sv', 'new-variable', 'nv')) { continue }
        $target = $null
        for ($i = 1; $i -lt $command.CommandElements.Count -and $null -eq $target; $i++) {
            $element = $command.CommandElements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { $target = $element }
            elseif ($element.ParameterName -ieq 'Name') { $target = $(if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $command.CommandElements.Count) { $command.CommandElements[$i + 1] }) }
            elseif (-not $element.Argument) { $i++ }
        }
        if ($target -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$names.Add($target.Value) } else { $unknown = $true }
    }
    foreach ($parameter in (Get-CiScriptNodes $Context CommandParameterAst)) {
        if ($parameter.ParameterName -notmatch '(?i)\A(OutVariable|ov|PipelineVariable|pv|ErrorVariable|ev|WarningVariable|wv|InformationVariable|iv)\z') { continue }
        $elements = @($parameter.Parent.CommandElements)
        $argument = $(if ($parameter.Argument) { $parameter.Argument } else { $at = [array]::IndexOf($elements, $parameter); if ($at -ge 0 -and $at + 1 -lt $elements.Count) { $elements[$at + 1] } })
        if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$names.Add($argument.Value.TrimStart('+')) }
    }
    foreach ($reference in (Get-CiScriptNodes $Context ConvertExpressionAst)) {
        if ($reference.Type.TypeName.Name -ieq 'ref' -and $reference.Child -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $referenced = Get-CiScriptVariableName $reference.Child.VariablePath
            if ($referenced) { [void]$names.Add($referenced) }
        }
    }
    $Context.Dynamic = @{ Names = $names; Unknown = $unknown }
    return $Context.Dynamic
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

function Merge-CiScriptValues {
    # One value for a set of values a read may see: unresolved when the set is empty, any member is unresolved or
    # they disagree; a scriptblock when all are; native when all are (its executable named when they all name the
    # same one); a path when all are the same path.
    param([object[]] $Values)
    $unresolved = @{ Kind = 'unresolved'; Value = $null }
    $all = @($Values | Where-Object { $null -ne $_ })
    if ($all.Count -eq 0) { return $unresolved }
    $kinds = @($all | ForEach-Object { [string]$_.Kind } | Sort-Object -Unique)
    if ($kinds.Count -ne 1 -or $kinds[0] -ceq 'unresolved') { return $unresolved }
    if ($kinds[0] -ceq 'scriptblock') { return @{ Kind = 'scriptblock'; Value = $null } }
    $first = [string]$all[0].Value
    $same = @($all | Where-Object { [string]::Equals([string]$_.Value, $first, [StringComparison]::OrdinalIgnoreCase) }).Count -eq $all.Count
    if ($kinds[0] -ceq 'native') { return @{ Kind = 'native'; Value = $(if ($same -and $first) { $first } else { $null }) } }
    if ($same -and $first) { return @{ Kind = 'path'; Value = $all[0].Value } }
    return $unresolved
}

function Resolve-CiScriptParameter {
    # A parameter holds what its callers pass, which the walker cannot see: a callback when it is typed
    # [scriptblock], else unresolved. A default is only the value of a call that passes none, so it does not decide.
    param($Parameter)
    $typed = @($Parameter.Attributes | Where-Object {
        $_ -is [System.Management.Automation.Language.TypeConstraintAst] -and
        $_.TypeName.Name -in @('scriptblock', 'System.Management.Automation.ScriptBlock')
    })
    if ($typed.Count -gt 0) { return @{ Kind = 'scriptblock'; Value = $null } }
    return @{ Kind = 'unresolved'; Value = $null }
}

function Get-CiScriptParameterOf {
    # The parameter named $Name that $Owner (a function definition, a scriptblock expression or the script's own
    # ScriptBlockAst) declares, inline or in its param block; $null when it declares none.
    param($Owner, [string] $Name)
    $parameters = @()
    if ($Owner -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        $parameters = @($Owner.Parameters) + @($(if ($Owner.Body.ParamBlock) { $Owner.Body.ParamBlock.Parameters }))
    } elseif ($Owner -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        $parameters = @($(if ($Owner.ScriptBlock.ParamBlock) { $Owner.ScriptBlock.ParamBlock.Parameters }))
    } elseif ($Owner.ParamBlock) {
        $parameters = @($Owner.ParamBlock.Parameters)
    }
    foreach ($parameter in $parameters) {
        if ($null -ne $parameter -and $parameter.Name.VariablePath.UserPath -ieq $Name) { return $parameter }
    }
    return $null
}

function Resolve-CiScriptVariable {
    # The value a variable may hold where it is read ($Use): every value some run can give it there must agree,
    # or the read is unresolved (fails closed). Taking only the last assignment in source order would drop a script
    # that an earlier value or another branch loads, and the closure would miss it: selection and the module
    # contract would then fail open (Greptile and CodeRabbit on #740). The values a read may see:
    #   * the writes of its own scope (its function, or the script) that can run before it: those before it in
    #     source order, and those anywhere in a loop around it (a pass runs them before the next read);
    #   * of those, the last one that dominates the read (it ends before the read in a statement list that also
    #     holds the read, so it ran whenever the read runs) replaces everything earlier: the fast path for an
    #     unconditional reassignment. A write in a branch, loop, try or switch the read is not in only adds a value;
    #   * a read in a scriptblock may run after any later write of the scope: unless a write inside the scriptblock
    #     dominates it, every write from the last one that dominates the scriptblock's definition on is possible;
    #   * with no dominating write, the value the scope starts with is possible too: a scriptblock's or the
    #     function's (or script's) own parameter (Resolve-CiScriptParameter); for a function without one, any write
    #     or same-named parameter outside it (PowerShell scopes are dynamic: a caller's variable is visible); for the
    #     script, nothing the walker can see (a caller that dot-sources it), so unresolved;
    #   * at script level, a `$script:`/`$global:` write in any function adds a value.
    # A foreach variable, a `+=` or multiple assignment, `[ref]`, Set-Variable or New-Variable naming it, or a
    # common -*Variable parameter naming it, is unresolved.
    param([string] $Name, $Use, [hashtable] $Context, [int] $Depth)
    $unresolved = @{ Kind = 'unresolved'; Value = $null }
    $key = $Name.ToLowerInvariant() + '@' + $Use.Extent.StartOffset
    if ($Context.Resolving.Contains($key)) { return $unresolved }
    [void]$Context.Resolving.Add($key)
    try {
        $ast = $Context.Ast
        $useOffset = $Use.Extent.StartOffset
        $useFunction = Get-CiScriptFunctionOf $Use
        foreach ($loop in (Get-CiScriptNodes $Context ForEachStatementAst)) {
            if ((Get-CiScriptVariableName $loop.Variable.VariablePath) -ieq $Name -and
                [object]::ReferenceEquals((Get-CiScriptFunctionOf $loop.Variable), $useFunction)) { return $unresolved }
        }
        $dynamic = Get-CiScriptDynamicWrites $Context
        if ($dynamic.Unknown -or $dynamic.Names.Contains($Name)) { return $unresolved }
        # Every assignment to the name: its scope, its scope qualifier and its value.
        $writes = [System.Collections.Generic.List[object]]::new()
        foreach ($assignment in (Get-CiScriptNodes $Context AssignmentStatementAst)) {
            $left = $assignment.Left
            $typedScriptblock = $false
            if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                $typedScriptblock = $left.Type.TypeName.Name -in @('scriptblock', 'System.Management.Automation.ScriptBlock')
                $left = $left.Child
            }
            $multiple = $false
            if ($left -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                $left = @($left.Elements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and (Get-CiScriptVariableName $_.VariablePath) -ieq $Name })[0]
                $multiple = $true
            }
            if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $path = $left.VariablePath
            if ((Get-CiScriptVariableName $path) -ine $Name) { continue }
            $value = $(if ($multiple -or $assignment.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { $unresolved }
                elseif ($typedScriptblock) { @{ Kind = 'scriptblock'; Value = $null } }
                else { $null })
            $writes.Add([pscustomobject]@{
                Node = $assignment
                Function = Get-CiScriptFunctionOf $assignment
                Outer = [bool]($path.IsScript -or $path.IsGlobal)
                Value = $value
            })
        }
        $valueOf = {
            param($write)
            if ($null -ne $write.Value) { return $write.Value }
            return Resolve-CiScriptValue $write.Node.Right $Context ($Depth + 1)
        }
        $values = [System.Collections.Generic.List[hashtable]]::new()
        # The read's own scope: a function's local writes, or the script's writes at script level.
        $local = @($writes | Where-Object { [object]::ReferenceEquals($_.Function, $useFunction) -and ($null -eq $useFunction -or -not $_.Outer) } |
            Sort-Object { $_.Node.Extent.StartOffset })
        # Where the read runs: in the innermost scriptblock around it (which may run at any later point), if any, and
        # inside which loops (which repeat it after later writes).
        $scriptblock = $null; $parameterOwner = $null
        $loops = [System.Collections.Generic.List[object]]::new()
        for ($walk = $Use.Parent; $null -ne $walk -and $walk -isnot [System.Management.Automation.Language.FunctionDefinitionAst]; $walk = $walk.Parent) {
            if ($walk -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                if ($null -eq $scriptblock) { $scriptblock = $walk }
                if ($null -eq $parameterOwner -and $null -ne (Get-CiScriptParameterOf $walk $Name)) { $parameterOwner = $walk }
            }
            if ($walk -is [System.Management.Automation.Language.LoopStatementAst] -and $null -eq $scriptblock) { $loops.Add($walk) }
        }
        if ($parameterOwner) { return Resolve-CiScriptParameter (Get-CiScriptParameterOf $parameterOwner $Name) }
        $inside = { param($node, $outer) $null -ne $outer -and $node.Extent.StartOffset -ge $outer.Extent.StartOffset -and $node.Extent.EndOffset -le $outer.Extent.EndOffset }
        # A write dominates a point when it ends before it in a statement list that also holds the point: whenever
        # the point runs, that write ran just before, in the same pass.
        $dominates = { param($write, $point, [int] $before)
            $block = $write.Node.Parent
            ($block -is [System.Management.Automation.Language.NamedBlockAst] -or $block -is [System.Management.Automation.Language.StatementBlockAst]) -and
                $write.Node.Extent.EndOffset -le $before -and (& $inside $point $block)
        }
        # The writes inside the read's scriptblock (or its whole scope), the last that dominates the read, and the
        # loops between that write and the read: a write anywhere in one of those reaches the read on a later pass.
        $inner = @($local | Where-Object { $null -eq $scriptblock -or (& $inside $_.Node $scriptblock) })
        $dominant = @($inner | Where-Object { & $dominates $_ $Use $useOffset } | Select-Object -Last 1)
        $carry = @($loops | Where-Object { $dominant.Count -eq 0 -or (& $inside $_ $dominant[0].Node.Parent) } | Select-Object -Last 1)
        $reaching = @($inner | Where-Object {
            ($dominant.Count -eq 0 -or $_.Node.Extent.StartOffset -ge $dominant[0].Node.Extent.StartOffset) -and
                ($_.Node.Extent.EndOffset -le $useOffset -or ($carry.Count -eq 1 -and (& $inside $_.Node $carry[0])))
        })
        foreach ($write in $reaching) { $values.Add((& $valueOf $write)) }
        if ($dominant.Count -eq 0 -and $scriptblock) {
            # The scriptblock may run after any later write of the scope; the last write that dominates its
            # definition replaces everything before it.
            $outerDominant = @($local | Where-Object { -not (& $inside $_.Node $scriptblock) -and (& $dominates $_ $scriptblock $scriptblock.Extent.StartOffset) } | Select-Object -Last 1)
            foreach ($write in @($local | Where-Object { -not (& $inside $_.Node $scriptblock) })) {
                if ($outerDominant.Count -eq 0 -or $write.Node.Extent.StartOffset -ge $outerDominant[0].Node.Extent.StartOffset) { $values.Add((& $valueOf $write)) }
            }
            if ($outerDominant.Count -eq 1) { $dominant = $outerDominant }
        }
        if ($dominant.Count -eq 0) {
            # The value the scope starts with.
            $owner = $(if ($useFunction) { $useFunction } else { $ast })
            $parameter = Get-CiScriptParameterOf $owner $Name
            if ($parameter) { $values.Add((Resolve-CiScriptParameter $parameter)) }
            elseif (-not $useFunction) { $values.Add($unresolved) }
            else {
                $outside = @($writes | Where-Object { -not [object]::ReferenceEquals($_.Function, $useFunction) -or $_.Outer })
                if ($outside.Count -eq 0) { $values.Add($unresolved) }
                foreach ($write in $outside) { $values.Add((& $valueOf $write)) }
                foreach ($function in (Get-CiScriptNodes $Context FunctionDefinitionAst)) {
                    if ([object]::ReferenceEquals($function, $useFunction)) { continue }
                    $other = Get-CiScriptParameterOf $function $Name
                    if ($other) { $values.Add((Resolve-CiScriptParameter $other)) }
                }
            }
        }
        # At script level, a function's `$script:`/`$global:` write may run before the read.
        if (-not $useFunction) { foreach ($write in @($writes | Where-Object { $_.Outer -and $null -ne $_.Function })) { $values.Add((& $valueOf $write)) } }
        return Merge-CiScriptValues $values
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
        Nodes = @{}
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
                $repo = ConvertTo-CiScriptTargetPath -RepoRoot $RepoRoot -Value $value.Value
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
                    $repo = $(if ($value.Kind -eq 'path') { ConvertTo-CiScriptTargetPath -RepoRoot $RepoRoot -Value $value.Value })
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
