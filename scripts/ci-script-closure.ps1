#requires -Version 7.0
<#
.SYNOPSIS
The script-closure walker: which files a set of PowerShell entry points can run, read from the syntax tree.

.DESCRIPTION
Dot-source this file. `Get-ScriptClosure` walks from repo-relative entry scripts, through every edge, to the files
they reach, in the working tree or at a git ref (New-CiScriptFileReader), so the hidden-desktop GUI suite's
selection (scripts/ci-gui-selection.ps1) can walk both sides of a pull request, and its contract
(Contracts.99-GuiHiddenSelection.ps1) can scan exactly what a hosted leaf loads.

An edge (design v7 §4.3, "What the walker counts as an edge"):
  * a `.` or `&`, or a bare path called without one (PowerShell's implicit `&`), whose target is, or may be, a
    .ps1, .psm1, .cmd or .bat file;
  * the script a PowerShell executable runs: its -File, its first positional argument (pwsh's -File), and anything
    -Command, -EncodedCommand, Windows PowerShell's positional or a splat may run; the executable may be named,
    a path, or reached through a variable or Get-Command (Test-CiScriptPowerShellName);
  * `cmd /c`, `/k` or `/r` with a script or a PowerShell command line;
  * Start-Process of a script, or of PowerShell or cmd with such arguments (-ArgumentList read element by element);
  * Start-Job, Start-ThreadJob or Invoke-Command -FilePath, and Import-Module of a script module by path;
  * Invoke-Expression, [scriptblock]::Create, InvokeScript and NewScriptBlock: a literal's own edges, and any other
    argument unresolved;
  * an `Add-Type -Path` source (a C# file: a member, not walked further);
  * a command line built as a string that runs `-File`, which no other edge shows.
A target resolves when it is a constant path composition anchored to the script or the repository: a literal,
`$PSScriptRoot`, `Join-Path`, `Split-Path`, string concatenation or an expandable string over those, a variable
every value of which (Resolve-CiScriptVariable) is such a composition, or a local function whose body is one. A
relative path resolves at run time against the current location and stays unresolved. A resolved .ps1/.psm1
target is walked; a .cmd/.bat target is a member and not walked.
Not edges:
  * a variable typed or assigned only as [scriptblock] (a callback): its body is part of the file and so scanned;
  * an inline scriptblock;
  * a native executable other than PowerShell and cmd: a target that resolves to an .exe or .com path, a
    `*ExePath`/`*CliPath` helper (unless the file defines it), or `Get-Command <name>` of one; it is a launch, not a
    script. An executable whose name the walker cannot read (`Get-Command $name`) is unresolved when its arguments
    may run a script;
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
        File = 'test/windows/interactive-win11-stateful-lib.ps1'
        Anchor = 'Start-Process -FilePath $Exe -ArgumentList $arguments'
        Guard = 'Start-StatefulApp''s legacy launch of its caller''s executable ($Exe is a parameter). It sits in the else of if ($env:NOCTTY_GUI_HIDDEN_DESKTOP), whose then-branch starts the copy through Start-InteractiveWin11HostedProcess; Contracts.99-GuiHiddenLaunch pins that every launch in the file sits on such a branch.'
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
            # (Get-Command pwsh.exe).Source and the like: the executable Get-Command names.
            if ($member -in @('Source', 'Path', 'Definition')) {
                # Through parentheses, and a pipeline that only selects from Get-Command's output.
                $command = $inner
                while ($command -is [System.Management.Automation.Language.ParenExpressionAst] -or $command -is [System.Management.Automation.Language.PipelineAst]) {
                    if ($command -is [System.Management.Automation.Language.ParenExpressionAst]) { $command = $command.Pipeline; continue }
                    $rest = @($command.PipelineElements | Select-Object -Skip 1 | Where-Object { -not ($_ -is [System.Management.Automation.Language.CommandAst] -and (Get-CiScriptCommandName $_.CommandElements[0]) -in @('select-object', 'select')) })
                    if ($rest.Count -ne 0) { return $unresolved }
                    $command = $command.PipelineElements[0]
                }
                if ($command -is [System.Management.Automation.Language.CommandAst] -and (Get-CiScriptCommandName $command.CommandElements[0]) -in @('get-command', 'gcm')) {
                    return Resolve-CiScriptValue $command $Context ($Depth + 1)
                }
            }
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
            # A function this file defines: the value of its body when that is one expression or one return
            # (Opus on #740: a local `Get-*ExePath` that returned a .ps1 was trusted by its name).
            $local = @((Get-CiScriptNodes $Context FunctionDefinitionAst) | Where-Object { $_.Name -ieq $name })
            if ($local.Count -gt 0) {
                $body = $local[0].Body
                $statements = @($body.EndBlock.Statements)
                if ($local.Count -ne 1 -or $body.BeginBlock -or $body.ProcessBlock -or $body.DynamicParamBlock -or $statements.Count -ne 1) { return $unresolved }
                $only = $statements[0]
                if ($only -is [System.Management.Automation.Language.ReturnStatementAst]) { $only = $only.Pipeline }
                return Resolve-CiScriptValue $only $Context ($Depth + 1)
            }
            # Get-Command <name>: that executable (a script's name is unresolved: Get-Command finds it on PATH).
            if ($name -in @('get-command', 'gcm')) {
                # Its -Name, or its first positional argument (a parameter's own argument skipped).
                $nameNode = $null
                for ($i = 1; $i -lt $elements.Count -and $null -eq $nameNode; $i++) {
                    $element = $elements[$i]
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { $nameNode = $element; break }
                    if ($element.ParameterName -ieq 'Name') { $nameNode = $(if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] }); break }
                    if (-not $element.Argument -and $element.ParameterName -notin @('All', 'ListImported', 'Syntax', 'ShowCommandInfo', 'UseFuzzyMatching', 'UseAbbreviationExpansion')) { $i++ }
                }
                if ($nameNode -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return @{ Kind = 'native'; Value = $null } }
                $target = $nameNode.Value
                if ((Test-CiScriptTargetKind $target) -in @('script', 'batch')) { return $unresolved }
                return @{ Kind = 'native'; Value = ($target -split '[\\/]')[-1].ToLowerInvariant() }
            }
            # A harness helper that names an executable by convention (Get-InteractiveWin11ExePath): native, named by
            # the helper. One named for PowerShell is an executable the walker cannot name.
            if ($name -match '(?i)^get-[a-z0-9-]*(exepath|clipath)$') {
                return @{ Kind = 'native'; Value = $(if ($name -match 'pwsh|powershell') { $null } else { $name }) }
            }
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

function New-CiScriptContext {
    # What Resolve-CiScriptValue reads about one parsed file: the repository root, the AST, the file's full path and
    # directory, and its caches. A contract that judges a value in a file (Contracts.99-GuiHiddenLaunch's launch ban)
    # makes one here rather than copying its shape.
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $RepoPath, [Parameter(Mandatory)] $Ast)
    $fullPath = Join-Path $RepoRoot ($RepoPath.Replace('/', '\'))
    return @{
        RepoRoot = $RepoRoot
        Ast = $Ast
        FilePath = $fullPath
        Directory = Split-Path -Parent $fullPath
        Resolving = [System.Collections.Generic.HashSet[string]]::new()
        Nodes = @{}
    }
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
    $context = New-CiScriptContext -RepoRoot $RepoRoot -RepoPath $RepoPath -Ast $ast
    $targets = [System.Collections.Generic.List[string]]::new()
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $csharp = [System.Collections.Generic.List[string]]::new()

    $unresolvedValue = @{ Kind = 'unresolved'; Value = $null }
    # An argument, from the syntax tree or from a literal argument list split into words: a parameter (its name, and
    # an argument attached to it), a splat, or a value (a node to resolve, or a value already known).
    $toEntry = {
        param($Node)
        if ($Node -is [System.Management.Automation.Language.CommandParameterAst]) {
            return [pscustomobject]@{ Param = $Node.ParameterName.TrimStart('-').ToLowerInvariant(); Attached = $(if ($Node.Argument) { & $toEntry $Node.Argument }); Splat = $false; Node = $Node; Value = $null }
        }
        if ($Node -is [System.Management.Automation.Language.VariableExpressionAst] -and $Node.Splatted) {
            return [pscustomobject]@{ Param = $null; Attached = $null; Splat = $true; Node = $Node; Value = $null }
        }
        if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $Node.Value -match '\A(?:--?|/)([A-Za-z][A-Za-z0-9]*)\z') {
            return [pscustomobject]@{ Param = $Matches[1].ToLowerInvariant(); Attached = $null; Splat = $false; Node = $Node; Value = $null }
        }
        return [pscustomobject]@{ Param = $null; Attached = $null; Splat = $false; Node = $Node; Value = $null }
    }
    $wordEntry = {
        param([string] $Word)
        if ($Word -match '\A(?:--?|/)([A-Za-z][A-Za-z0-9]*)\z') { return [pscustomobject]@{ Param = $Matches[1].ToLowerInvariant(); Attached = $null; Splat = $false; Node = $null; Value = $null } }
        # A quoted word may hold spaces the split broke: its value is unknown.
        $value = $(if ($Word -match '["'']') { $unresolvedValue } else { @{ Kind = 'path'; Value = $Word } })
        return [pscustomobject]@{ Param = $null; Attached = $null; Splat = $false; Node = $null; Value = $value }
    }
    $valueOf = { param($Entry) if ($Entry.Value) { return $Entry.Value } if ($Entry.Node) { return Resolve-CiScriptValue $Entry.Node $context } return $unresolvedValue }
    # The entries of an argument list given as one expression (Start-Process -ArgumentList): an array's elements, or a
    # literal string's words; $null when the walker cannot list them (a variable, a command's output).
    $listEntries = {
        param($Node)
        while ($Node -is [System.Management.Automation.Language.ParenExpressionAst] -or
            ($Node -is [System.Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) -or
            $Node -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $Node = $(if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) { $Node.Pipeline } elseif ($Node -is [System.Management.Automation.Language.PipelineAst]) { $Node.PipelineElements[0] } else { $Node.Expression })
        }
        if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) { return , @($Node.Elements | ForEach-Object { & $toEntry $_ }) }
        if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
            $entries = [System.Collections.Generic.List[object]]::new()
            foreach ($statement in $Node.SubExpression.Statements) {
                $inner = $statement
                if ($inner -is [System.Management.Automation.Language.PipelineAst] -and $inner.PipelineElements.Count -eq 1 -and $inner.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $expression = $inner.PipelineElements[0].Expression
                    if ($expression -is [System.Management.Automation.Language.ArrayLiteralAst]) { foreach ($element in $expression.Elements) { $entries.Add((& $toEntry $element)) } }
                    else { $entries.Add((& $toEntry $expression)) }
                    continue
                }
                return $null
            }
            return , $entries.ToArray()
        }
        $value = Resolve-CiScriptValue $Node $context
        if ($value.Kind -ne 'path') { return $null }
        return , @($value.Value -split '\s+' | Where-Object { $_ } | ForEach-Object { & $wordEntry $_ })
    }
    # A PowerShell command-line parameter (pwsh's own matching: a unique prefix): what it does to the walk.
    $powershellParameter = {
        param([string] $Name, [bool] $Pwsh)
        if ($Name -match '\Af(i(l(e)?)?)?\z') { return 'file' }
        if ($Name.Length -gt 'encoded'.Length -and 'encodedarguments'.StartsWith($Name)) { return 'value' }
        if ($Name -ceq 'ea') { return 'value' }
        foreach ($valued in @(@('configurationname', 6), @('configurationfile', 14), @('custompipename', 3), @('executionpolicy', 2), @('inputformat', 2), @('outputformat', 1),
                @('settingsfile', 8), @('windowstyle', 1), @('workingdirectory', 2), @('psconsolefile', 3))) {
            if ($Name.Length -ge $valued[1] -and $valued[0].StartsWith($Name)) { return 'value' }
        }
        if ($Name -in @('ep', 'ex', 'if', 'of', 'wd', 'config')) { return 'value' }
        if ($Name -ceq 'ec' -or 'command'.StartsWith($Name) -or 'encodedcommand'.StartsWith($Name)) { return 'command' }
        # Windows PowerShell's -Version takes a version; pwsh's prints its own.
        if (-not $Pwsh -and 'version'.StartsWith($Name)) { return 'value' }
        return 'switch'
    }
    # A script target that must resolve: a rooted .ps1, .psm1, .cmd or .bat path; anything else is unresolved.
    $scriptTarget = {
        param($Value, [string] $Why)
        if ($Value.Kind -eq 'path' -and (Test-CiScriptTargetKind $Value.Value) -in @('script', 'batch')) {
            $repo = ConvertTo-CiScriptTargetPath -RepoRoot $RepoRoot -Value $Value.Value
            if ($repo) { $targets.Add($repo); return }
        }
        $unresolved.Add($Why)
    }
    # What a PowerShell executable's arguments run (Sol and CodeRabbit on #740: a pwsh reached through a variable
    # with -File was taken for an ordinary executable and its child dropped).
    $powershellArguments = {
        param([object[]] $Entries, [bool] $Pwsh, [string] $Why)
        for ($i = 0; $i -lt $Entries.Count; $i++) {
            $entry = $Entries[$i]
            if ($entry.Splat) { $unresolved.Add($Why); return }
            if ($entry.Param) {
                switch (& $powershellParameter $entry.Param $Pwsh) {
                    'file' {
                        $argument = $(if ($entry.Attached) { $entry.Attached } elseif ($i + 1 -lt $Entries.Count -and -not $Entries[$i + 1].Param) { $Entries[$i + 1] })
                        if ($null -eq $argument -or $argument.Splat) { $unresolved.Add($Why) } else { & $scriptTarget (& $valueOf $argument) $Why }
                        return
                    }
                    'command' { $unresolved.Add($Why); return }
                    'value' { if (-not $entry.Attached) { $i++ } }
                }
                continue
            }
            # pwsh runs a first positional argument as -File; Windows PowerShell runs it as -Command.
            if ($Pwsh) { & $scriptTarget (& $valueOf $entry) $Why } else { $unresolved.Add($Why) }
            return
        }
    }
    # Whether arguments may run a script, for an executable the walker cannot name.
    $mayRunScript = {
        param([object[]] $Entries)
        foreach ($entry in $Entries) {
            if ($entry.Splat) { return $true }
            if ($entry.Param -and (& $powershellParameter $entry.Param $true) -in @('file', 'command')) { return $true }
            $value = $(if ($entry.Attached) { & $valueOf $entry.Attached } elseif (-not $entry.Param) { & $valueOf $entry })
            if ($null -eq $value) { continue }
            if ($value.Kind -eq 'unresolved') { return $true }
            if ($value.Kind -eq 'path' -and $value.Value -match '(?i)\.(ps1|psm1|psd1|cmd|bat)\b|\b(pwsh|powershell)\b') { return $true }
        }
        return $false
    }
    # What a callee is: @{ Is = 'script' (Value: its path) | 'powershell' (Pwsh) | 'cmd' | 'native' | 'command'
    # (Value: a command name) | 'maybe' (an executable the walker cannot name) | 'unresolved' | 'none' }.
    $classify = {
        param($Value)
        switch ($Value.Kind) {
            'scriptblock' { return @{ Is = 'none' } }
            'native' {
                if (-not $Value.Value) { return @{ Is = 'maybe' } }
                $leaf = ($Value.Value -split '[\\/]')[-1].ToLowerInvariant()
                if (Test-CiScriptPowerShellName $leaf) { return @{ Is = 'powershell'; Pwsh = $leaf.StartsWith('pwsh') } }
                if ($leaf -in @('cmd', 'cmd.exe')) { return @{ Is = 'cmd' } }
                return @{ Is = 'native' }
            }
            'path' {
                $kind = Test-CiScriptTargetKind $Value.Value
                if ($kind -in @('script', 'batch')) { return @{ Is = 'script'; Value = $Value } }
                $leaf = ($Value.Value -split '[\\/]')[-1].ToLowerInvariant()
                if (Test-CiScriptPowerShellName $leaf) { return @{ Is = 'powershell'; Pwsh = $leaf.StartsWith('pwsh') } }
                if ($leaf -in @('cmd', 'cmd.exe')) { return @{ Is = 'cmd' } }
                if ($kind -eq 'native') { return @{ Is = 'native' } }
                # A bare word names a command; a path with no script, batch or native extension may still run a
                # script (PowerShell resolves one).
                if ($Value.Value -notmatch '[\\/]') { return @{ Is = 'command'; Value = $leaf } }
                return @{ Is = 'unresolved' }
            }
        }
        return @{ Is = 'unresolved' }
    }
    # cmd's arguments: what /C, /K or /R runs.
    $cmdArguments = {
        param([object[]] $Entries, [string] $Why)
        $at = -1
        for ($i = 0; $i -lt $Entries.Count; $i++) {
            if ($Entries[$i].Splat) { $unresolved.Add($Why); return }
            if ($Entries[$i].Param -in @('c', 'k', 'r')) { $at = $i; break }
        }
        if ($at -lt 0 -or $at + 1 -ge $Entries.Count) { return }
        $rest = @($Entries[($at + 1)..($Entries.Count - 1)])
        & $runs $rest $Why
    }
    # What a command line runs, given as entries whose first is the command (cmd's /C, `call`).
    $runs = {
        param([object[]] $Entries, [string] $Why)
        $value = & $valueOf $Entries[0]
        # A whole command line in one string: refused when it may name a script or PowerShell.
        if ($value.Kind -eq 'path' -and $value.Value -match '\s') {
            if ($value.Value -match '(?i)\.(ps1|psm1|cmd|bat)\b|\b(pwsh|powershell|call|start)\b') { $unresolved.Add($Why) }
            return
        }
        $after = @($(if ($Entries.Count -gt 1) { $Entries[1..($Entries.Count - 1)] }))
        $callee = & $classify $value
        if ($callee.Is -ceq 'command' -and $callee.Value -ceq 'call' -and $after.Count -gt 0) { & $runs $after $Why; return }
        if ($callee.Is -ceq 'command' -or $callee.Is -ceq 'maybe') { if (& $mayRunScript $after) { $unresolved.Add($Why) }; return }
        & $invoke $callee $after $Why
    }
    # Run a classified callee with its argument entries.
    $invoke = {
        param($Callee, [object[]] $Entries, [string] $Why)
        switch ($Callee.Is) {
            'script' { & $scriptTarget $Callee.Value $Why }
            'powershell' { & $powershellArguments $Entries $Callee.Pwsh $Why }
            'cmd' { & $cmdArguments $Entries $Why }
            'maybe' { if (& $mayRunScript $Entries) { $unresolved.Add($Why) } }
            'unresolved' { $unresolved.Add($Why) }
        }
    }
    # A cmdlet's parameter by PowerShell's rule (a unique prefix, or an alias): its class from $Table, or $null.
    $cmdletParameter = {
        param([string] $Name, [hashtable] $Table)
        if ($Table.ContainsKey($Name)) { return $Table[$Name] }
        $found = @($Table.Keys | Where-Object { $_.StartsWith($Name, [StringComparison]::Ordinal) })
        if ($found.Count -eq 1) { return $Table[$found[0]] }
        return $null
    }
    # A cmdlet's arguments as @{ Named = name class -> entry; Positional = entries }; $null when one is unknown.
    $bindCmdlet = {
        param([object[]] $Entries, [hashtable] $Table)
        $named = @{}
        $positional = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $Entries.Count; $i++) {
            $entry = $Entries[$i]
            if ($entry.Splat) { return $null }
            if (-not $entry.Param -or $entry.Node -isnot [System.Management.Automation.Language.CommandParameterAst]) { $positional.Add($entry); continue }
            $class = & $cmdletParameter $entry.Param $Table
            if ($null -eq $class) { return $null }
            if ($class -ceq 'switch') { continue }
            $argument = $(if ($entry.Attached) { $entry.Attached } elseif ($i + 1 -lt $Entries.Count) { $i++; $Entries[$i] })
            if ($null -eq $argument) { return $null }
            $named[$class] = $argument
        }
        return @{ Named = $named; Positional = $positional }
    }
    $startProcessParameters = @{
        filepath = 'file'; pspath = 'file'; path = 'file'; argumentlist = 'args'; args = 'args'
        verb = 'other'; workingdirectory = 'other'; credential = 'other'; windowstyle = 'other'; environment = 'other'
        redirectstandarderror = 'other'; redirectstandardinput = 'other'; redirectstandardoutput = 'other'
        passthru = 'switch'; wait = 'switch'; nonewwindow = 'switch'; usenewenvironment = 'switch'; loaduserprofile = 'switch'
    }
    # Literal code run as a script (Invoke-Expression, [scriptblock]::Create): its own edges; anything else unresolved.
    $codeEdges = {
        param($Node, [string] $Why)
        $value = $(if ($Node) { Resolve-CiScriptValue $Node $context } else { $unresolvedValue })
        if ($value.Kind -ne 'path') { $unresolved.Add($Why); return }
        try { $inner = Get-CiScriptFileEdges -RepoRoot $RepoRoot -RepoPath $RepoPath -Text $value.Value }
        catch { $unresolved.Add($Why); return }
        foreach ($target in $inner.Targets) { $targets.Add($target) }
        foreach ($source in $inner.CSharp) { $csharp.Add($source) }
        if ($inner.Unresolved.Count -gt 0) { $unresolved.Add($Why) }
    }

    # The commands that may run a script by name: PowerShell, cmd and the cmdlets above.
    $edgeCommands = @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe', 'cmd', 'cmd.exe', 'add-type', 'start-process', 'saps', 'start',
        'start-job', 'sajb', 'start-threadjob', 'invoke-command', 'icm', 'invoke-expression', 'iex', 'import-module', 'ipmo')
    foreach ($command in (Get-CiScriptNodes $context CommandAst)) {
        $elements = $command.CommandElements
        $anchor = ConvertTo-CiScriptAnchor $command.Extent.Text
        $operator = $command.InvocationOperator
        $first = $elements[0]
        $invoked = $operator -eq [System.Management.Automation.Language.TokenKind]::Dot -or $operator -eq [System.Management.Automation.Language.TokenKind]::Ampersand
        # A bare path called without `&` is PowerShell's implicit `&` (Opus on #740); a module-qualified command
        # (Microsoft.PowerShell.Utility\Write-Host) is not a path.
        $barePath = -not $invoked -and $first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $first.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::BareWord -and
            ($first.Value -match '[\\/]' -or (Test-CiScriptTargetKind $first.Value) -ne 'other') -and
            $first.Value -notmatch '\A[A-Za-z][\w.]*\\[A-Za-z]+-[A-Za-z]\w*\z'
        if (-not $invoked -and -not $barePath -and (Get-CiScriptCommandName $first) -notin $edgeCommands) { continue }
        $entries = @($elements | Select-Object -Skip 1 | ForEach-Object { & $toEntry $_ })
        if ($invoked -or $barePath) {
            if ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            $callee = & $classify (Resolve-CiScriptValue $first $context)
            if ($callee.Is -cne 'command') { & $invoke $callee $entries $anchor; continue }
            $name = $callee.Value
        } else {
            $name = Get-CiScriptCommandName $first
            if (-not $name) { continue }
            $callee = & $classify @{ Kind = 'path'; Value = $name }
            if ($callee.Is -in @('powershell', 'cmd')) { & $invoke $callee $entries $anchor; continue }
        }
        switch ($name) {
            'add-type' {
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    if ($entries[$i].Param -notin @('path', 'literalpath')) { continue }
                    $argument = $(if ($entries[$i].Attached) { $entries[$i].Attached } elseif ($i + 1 -lt $entries.Count) { $entries[$i + 1] })
                    $value = $(if ($argument) { & $valueOf $argument } else { $unresolvedValue })
                    $repo = $(if ($value.Kind -eq 'path') { ConvertTo-CiScriptTargetPath -RepoRoot $RepoRoot -Value $value.Value })
                    if ($repo) { $csharp.Add($repo) } else { $unresolved.Add($anchor) }
                }
            }
            { $_ -in @('start-process', 'saps', 'start') } {
                $bound = & $bindCmdlet $entries $startProcessParameters
                if ($null -eq $bound) { $unresolved.Add($anchor); break }
                $file = $(if ($bound.Named.ContainsKey('file')) { $bound.Named['file'] } elseif ($bound.Positional.Count -ge 1) { $bound.Positional[0] })
                $list = $(if ($bound.Named.ContainsKey('args')) { $bound.Named['args'] } elseif ($bound.Positional.Count -ge 2 -and -not $bound.Named.ContainsKey('file')) { $bound.Positional[1] } elseif ($bound.Named.ContainsKey('file') -and $bound.Positional.Count -ge 1) { $bound.Positional[0] })
                if ($null -eq $file) { $unresolved.Add($anchor); break }
                $callee = & $classify (& $valueOf $file)
                if ($callee.Is -in @('none', 'native', 'command')) { break }
                if ($callee.Is -in @('script', 'unresolved')) { & $invoke $callee @() $anchor; break }
                if ($null -eq $list) { if ($callee.Is -cne 'maybe') { & $invoke $callee @() $anchor }; break }
                $listed = $(if ($list.Node) { & $listEntries $list.Node } elseif ($list.Value) { , @($list.Value.Value -split '\s+' | Where-Object { $_ } | ForEach-Object { & $wordEntry $_ }) })
                if ($null -eq $listed) { $unresolved.Add($anchor); break }
                & $invoke $callee $listed $anchor
            }
            { $_ -in @('start-job', 'sajb', 'start-threadjob', 'invoke-command', 'icm') } {
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    $entry = $entries[$i]
                    if ($entry.Splat) { $unresolved.Add($anchor); break }
                    if ($entry.Param -and $entry.Node -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $isFile = ($entry.Param.Length -ge 1 -and 'filepath'.StartsWith($entry.Param)) -or ($entry.Param.Length -ge 2 -and 'literalpath'.StartsWith($entry.Param)) -or $entry.Param -ceq 'pspath'
                        if ($isFile) {
                            $argument = $(if ($entry.Attached) { $entry.Attached } elseif ($i + 1 -lt $entries.Count) { $entries[$i + 1] })
                            if ($argument) { & $scriptTarget (& $valueOf $argument) $anchor } else { $unresolved.Add($anchor) }
                            break
                        }
                        if (-not $entry.Attached -and $i + 1 -lt $entries.Count -and -not $entries[$i + 1].Param) { $i++ }
                        continue
                    }
                    # Invoke-Command's -FilePath may also come by position, after -ComputerName.
                    $value = & $valueOf $entry
                    if ($value.Kind -eq 'path' -and (Test-CiScriptTargetKind $value.Value) -in @('script', 'batch')) { & $scriptTarget $value $anchor }
                }
            }
            { $_ -in @('invoke-expression', 'iex') } {
                # The code: -Command or the first positional argument. With neither it comes down the pipeline, which
                # the walker cannot read.
                $node = $null
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    $entry = $entries[$i]
                    if ($entry.Param -and $entry.Node -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ('command'.StartsWith($entry.Param, [StringComparison]::Ordinal)) { $node = $(if ($entry.Attached) { $entry.Attached.Node } elseif ($i + 1 -lt $entries.Count) { $entries[$i + 1].Node }); break }
                        continue
                    }
                    $node = $entry.Node; break
                }
                & $codeEdges $node $anchor
            }
            { $_ -in @('import-module', 'ipmo') } {
                $module = $null
                for ($i = 0; $i -lt $entries.Count -and $null -eq $module; $i++) {
                    $entry = $entries[$i]
                    if ($entry.Splat) { break }
                    if (-not $entry.Param -or $entry.Node -isnot [System.Management.Automation.Language.CommandParameterAst]) { $module = $entry; break }
                    if ($entry.Param -in @('name', 'n')) { $module = $(if ($entry.Attached) { $entry.Attached } elseif ($i + 1 -lt $entries.Count) { $entries[$i + 1] }); break }
                    if ($entry.Param -in @('force', 'global', 'passthru', 'ascustomobject', 'disablenamechecking', 'noclobber', 'skipeditioncheck', 'usewindowspowershell')) { continue }
                    if (-not $entry.Attached) { $i++ }
                }
                $value = $(if ($module) { & $valueOf $module } else { $unresolvedValue })
                if ($value.Kind -eq 'path') {
                    $extension = [IO.Path]::GetExtension($value.Value).ToLowerInvariant()
                    if ($extension -in @('.ps1', '.psm1')) { & $scriptTarget $value $anchor; break }
                    if ($extension -eq '.dll') { break }
                    # A module by name, from PSModulePath (a dotted name such as Microsoft.PowerShell.Utility included).
                    if ($value.Value -notmatch '[\\/]' -and $extension -notin @('.psd1', '.cdxml', '.xaml')) { break }
                }
                $unresolved.Add($anchor)
            }
        }
    }

    # Code built from a string at run time: [scriptblock]::Create, InvokeScript and NewScriptBlock.
    foreach ($call in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
        if ($call.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $method = $call.Member.Value
        $create = $call.Static -and $method -ieq 'Create' -and $call.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $call.Expression.TypeName.Name -in @('scriptblock', 'System.Management.Automation.ScriptBlock')
        if (-not $create -and $method -notin @('InvokeScript', 'NewScriptBlock')) { continue }
        & $codeEdges $(if (@($call.Arguments).Count -ge 1) { @($call.Arguments)[0] }) (ConvertTo-CiScriptAnchor $call.Extent.Text)
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
