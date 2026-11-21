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
    .ps1 or .psm1 file;
  * the script a PowerShell executable runs: its -File, its first positional argument (pwsh's -File), and anything
    -Command, -EncodedCommand, Windows PowerShell's positional or a splat may run; the executable may be named,
    a path, or reached through a variable or Get-Command (Test-CiScriptPowerShellName);
  * cmd, and a .cmd or .bat file, in any form: unresolved, never read (the lead on #740: each review round found a
    new silent hole in reading cmd and batch semantics, and no real member runs a resolvable cmd or batch line), save
    the anchored legacy-only lines ($script:CiScriptClosureLegacyEdges);
  * Start-Process of a script; Start-Process of PowerShell is refused (unresolved), since it joins its arguments
    without quoting and PowerShell tokenizes them again;
  * Start-Job, Start-ThreadJob or Invoke-Command -FilePath, and Import-Module of a script module by path;
  * Invoke-Expression, [scriptblock]::Create, InvokeScript, NewScriptBlock and a PowerShell object's AddScript: a
    literal's own edges, and any other argument unresolved;
  * a command a name stands for: an alias (Set-Alias, New-Alias, `$alias:` and Import-Alias) and a PowerShell
    object's AddCommand. A script it names is an edge; a native program or a cmdlet the walker does not read by name
    is none; anything else is unresolved (a value it cannot read, PowerShell or cmd, whose arguments the later calls
    give, and a command it reads by name, such as Start-Process: the walker does not follow an alias to its calls);
  * an `Add-Type -Path` source (a C# file: a member, not walked further);
  * a command line built as a string that runs `-File`, which no other edge shows.
A cmdlet is the same edge under its module-qualified name (Microsoft.PowerShell.Utility\Add-Type), and its
arguments are bound as PowerShell binds them, common parameters and aliases included, before the walker reads its
file or code ($bindCmdlet); arguments it cannot bind leave the edge unresolved. A PowerShell executable's own
parameters are bound by that executable's rule ($powershellParameter).
A target resolves when it is a constant path composition anchored to the script or the repository: a literal,
`$PSScriptRoot`, `Join-Path`, `Split-Path`, string concatenation or an expandable string over those, a variable
every value of which (Resolve-CiScriptVariable) is such a composition, or a local function whose body is one. A
relative path resolves at run time against the current location and stays unresolved. A resolved .ps1/.psm1
target is walked; a .cmd/.bat target is refused (unresolved), as every cmd and batch invocation is.
Not edges:
  * a variable typed or assigned only as [scriptblock] (a callback): its body is part of the file and so scanned;
  * an inline scriptblock;
  * a native executable other than PowerShell and cmd: a target that resolves to an .exe or .com path, a
    `*ExePath`/`*CliPath` helper (unless the file defines it, or its name is a shell's or a batch file's), or
    `Get-Command <name>` of one; it is a launch, not a script. A name or a target path is compared and recorded
    with its trailing spaces trimmed, as Windows runs it. An executable the walker cannot name (several possible programs, or a helper named for a
    shell) is unresolved, whatever its arguments, since it may be cmd, PowerShell or a batch file. A bare literal
    Start-Process FilePath beside -WorkingDirectory, other than a system program ($script:CiScriptSystemPrograms),
    is unresolved. Get-Command of a name the walker cannot read at all (`Get-Command $name`) may find a script, so it
    is unresolved; of a script path, it is that script;
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

# The shape of a cmdlet qualified by a module PowerShell ships (Microsoft.PowerShell.Core\Import-Module). Only the
# Verb-Noun shape: PowerShell resolves no qualified alias (`Microsoft.PowerShell.Utility\iex` is not a command,
# measured on pwsh 7.6.10). The shape alone is not enough (Test-CiScriptShippedCmdlet), and any other word with a
# separator, `<word>\<Verb-Noun>` included, is a path, which PowerShell looks up as one when no module matches (Sol
# and Opus on #740: `fixtures\cmd` ran `fixtures\cmd.ps1`, `sub\Run-Child` ran `sub\Run-Child.ps1`).
$script:CiScriptBuiltinQualifiedName = '\AMicrosoft\.PowerShell\.[A-Za-z.]+\\(?<name>[A-Za-z]+-[A-Za-z]\w*)\z'
# The system programs a bare Start-Process FilePath may name beside -WorkingDirectory: found in System32 or on PATH,
# never in that directory. Any other bare name there is unresolved (Opus on #740). Shells are not among them.
$script:CiScriptSystemPrograms = @('git', 'git.exe', 'where', 'where.exe', 'sort', 'sort.exe', 'findstr', 'findstr.exe', 'tasklist', 'tasklist.exe', 'whoami', 'whoami.exe')

# Whether a name is a cmdlet: the shipped-module shape, and this session's module exports exactly that command (Sol
# on #740: `Microsoft.PowerShell.Utility\Run-Child` ran `Microsoft.PowerShell.Utility\Run-Child.ps1` from the current
# location, since the module has no Run-Child, and an invented `Microsoft.PowerShell.SolFixture\Run-Child` did the
# same). Otherwise the name is a relative path. Cached per name.
$script:CiScriptShippedCmdlets = @{}
function Test-CiScriptShippedCmdlet {
    param([string] $Name)
    if ($Name -notmatch $script:CiScriptBuiltinQualifiedName) { return $false }
    $key = $Name.ToLowerInvariant()
    if (-not $script:CiScriptShippedCmdlets.ContainsKey($key)) {
        $module, $command = $Name -split '\\', 2
        $found = @(Get-Command -Module $module -Name $command -CommandType Cmdlet, Function -ErrorAction Ignore)
        $script:CiScriptShippedCmdlets[$key] = $found.Count -eq 1 -and [string]::Equals($found[0].Name, $command, [StringComparison]::OrdinalIgnoreCase)
    }
    return $script:CiScriptShippedCmdlets[$key]
}

# A path lookup: a path with no extension, which PowerShell looks up by `.ps1` and then by each PATHEXT extension,
# in any form and under any -CommandType (Sol on #740: `-CommandType ExternalScript` found `<path>.ps1` and
# `-CommandType Application` found `<path>.cmd` beside it). Returns the path for a lookup, else $null (an extension
# the walk does not know is unresolved). It resolves only to a `.ps1` that is the one file Find-CiScriptLookupFiles
# finds (Get-ScriptClosure); anything else is unresolved.
function Get-CiScriptPathLookup {
    param([string] $Path)
    if ([IO.Path]::GetExtension($Path).Length -ne 0) { return $null }
    return $Path
}

# The extensions a path lookup tries: `.ps1`, then the Windows default PATHEXT and this session's PATHEXT, lower-case.
function Get-CiScriptLookupExtensions {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($extension in @('.ps1', '.com', '.exe', '.bat', '.cmd', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.msc', '.cpl') + @("$env:PATHEXT" -split ';')) {
        $value = $extension.Trim().ToLowerInvariant()
        if ($value -match '\A\.[a-z0-9]{1,8}\z' -and -not $list.Contains($value)) { $list.Add($value) }
    }
    return , $list.ToArray()
}

# The files a path lookup of $Base (a repo path with no extension) may find: every sibling whose name is $Base's leaf
# and a lookup extension, compared case-insensitively, as the tree spells it. With a reader that lists its
# directories (a `Lister` note, as New-CiScriptFileReader's have), from the listing; otherwise each extension is
# tried in every letter case. Emitted one by one. The closure resolves the lookup only when the one file found is a
# `.ps1`: a native or batch sibling may be what runs, with arguments the walk would not read (Greptile on #740:
# keeping a `pwsh.exe` sibling as a file dropped the `-File` child its arguments named), and none finds nothing.
function Find-CiScriptLookupFiles {
    param([Parameter(Mandatory)] [scriptblock] $Reader, [Parameter(Mandatory)] [string] $Base)
    $cut = $Base.LastIndexOf('/')
    $directory = $(if ($cut -ge 0) { $Base.Substring(0, $cut) } else { '' })
    $leaf = $Base.Substring($cut + 1)
    $extensions = Get-CiScriptLookupExtensions
    $found = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $lister = $Reader.PSObject.Properties['Lister']
    if ($lister) {
        foreach ($path in @(& $lister.Value $directory)) {
            $name = $path.Substring($path.LastIndexOf('/') + 1)
            foreach ($extension in $extensions) {
                if ([string]::Equals($name, $leaf + $extension, [StringComparison]::OrdinalIgnoreCase)) { [void]$found.Add($path) }
            }
        }
    }
    else {
        # A reader may answer every letter case for one file (the working tree's), so variants of one name count once:
        # the first, lower-case one tried.
        $found = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($extension in $extensions) {
            $letters = $extension.Substring(1)
            for ($mask = 0; $mask -lt (1 -shl $letters.Length); $mask++) {
                $variant = -join @(for ($i = 0; $i -lt $letters.Length; $i++) {
                        $(if (($mask -shr $i) -band 1) { [char]::ToUpperInvariant($letters[$i]) } else { $letters[$i] })
                    })
                $candidate = "$Base.$variant"
                if ($null -ne (& $Reader $candidate)) { [void]$found.Add($candidate) }
            }
        }
    }
    foreach ($path in $found) { $path }
}


# The parameters of the cmdlets whose arguments the walker binds, from their metadata on pwsh 7.6.10
# ((Get-Command <name>).Parameters): a word names a parameter that takes a value, `:s` marks a switch, and `=` lists
# its aliases. Each cmdlet also takes the common parameters. A parameter missing here makes a command that names it
# unresolved, never misread.
$script:CiScriptCommonParameters = 'debug:s=db erroraction=ea errorvariable=ev informationaction=infa informationvariable=iv outbuffer=ob outvariable=ov pipelinevariable=pv progressaction=proga verbose:s=vb warningaction=wa warningvariable=wv'
$script:CiScriptCmdletParameters = @{
    'invoke-expression' = 'command'
    'add-type' = 'assemblyname=an compileroptions ignorewarnings:s language literalpath=pspath,lp memberdefinition name namespace=ns outputassembly=oa outputtype=ot passthru:s path referencedassemblies=ra typedefinition usingnamespace=using'
    'start-process' = 'argumentlist=args confirm:s=cf credential=runas environment filepath=pspath,path loaduserprofile:s=lup nonewwindow:s=nnw passthru:s redirectstandarderror=rse redirectstandardinput=rsi redirectstandardoutput=rso usenewenvironment:s verb wait:s whatif:s=wi windowstyle workingdirectory'
    'start-job' = 'argumentlist=args authentication connectingtimeout credential definitionname definitionpath filepath initializationscript inputobject literalpath=pspath,lp name options psversion runas32:s scriptblock=command type workingdirectory'
    'start-threadjob' = 'argumentlist filepath initializationscript inputobject name scriptblock streaminghost throttlelimit'
    'invoke-command' = 'allowredirection:s applicationname argumentlist=args asjob:s authentication certificatethumbprint computername=cn configurationname connectingtimeout connectionuri=uri,cu containerid credential enablenetworkaccess:s filepath=pspath hidecomputername:s=hcn hostname indisconnectedsession:s=disconnected inputobject jobname keyfilepath=identityfilepath nonewscope:s options port remotedebug:s runasadministrator:s scriptblock=command session sessionname sessionoption sshconnection sshtransport:s subsystem throttlelimit username usessl:s vmid=vmguid vmname'
    'import-module' = 'alias argumentlist=args ascustomobject:s assembly cimnamespace cimresourceuri cimsession cmdlet disablenamechecking:s force:s fullyqualifiedname function global:s maximumversion minimumversion=version moduleinfo name noclobber:s=nooverwrite passthru:s prefix pssession requiredversion scope skipeditioncheck:s usewindowspowershell:s=usewinps variable'
    # Set-Alias and New-Alias have the same parameters: -Name at position 0, -Value at 1.
    'set-alias' = 'confirm:s=cf description force:s name option passthru:s scope value whatif:s=wi'
}

function Get-CiScriptParameterTable {
    # One cmdlet's parameters from the tables above: @{ Switch = name -> whether it is a switch; Aliases = alias ->
    # name }, keys without case as PowerShell matches them.
    param([Parameter(Mandatory)] [string] $Cmdlet)
    $switches = @{}
    $aliases = @{}
    foreach ($word in (($script:CiScriptCmdletParameters[$Cmdlet] + ' ' + $script:CiScriptCommonParameters) -split ' ' | Where-Object { $_ })) {
        $spec, $aliasList = $word -split '=', 2
        $name, $kind = $spec -split ':', 2
        $switches[$name] = $kind -ceq 's'
        if ($aliasList) { foreach ($alias in $aliasList -split ',') { $aliases[$alias] = $name } }
    }
    return @{ Switch = $switches; Aliases = $aliases }
}

function Resolve-CiScriptParameterName {
    # The parameter a written name binds, by PowerShell's rule: a name or alias exactly, else a prefix of names and
    # aliases that all belong to one parameter (`Get-ChildItem -ps` binds -LiteralPath through its alias PSPath, and
    # Invoke-Expression's `-v` binds -Verbose, though the alias vb also starts with v: measured on pwsh 7.6.10). $null
    # when none does or the prefix is ambiguous (`-e`: -ErrorAction or -ErrorVariable).
    param([string] $Given, [Parameter(Mandatory)] [hashtable] $Table)
    if (-not $Given) { return $null }
    if ($Table.Switch.ContainsKey($Given)) { return $Given.ToLowerInvariant() }
    if ($Table.Aliases.ContainsKey($Given)) { return $Table.Aliases[$Given] }
    $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Table.Switch.Keys) { if ($name.StartsWith($Given, [StringComparison]::OrdinalIgnoreCase)) { [void]$found.Add($name) } }
    foreach ($alias in $Table.Aliases.Keys) { if ($alias.StartsWith($Given, [StringComparison]::OrdinalIgnoreCase)) { [void]$found.Add($Table.Aliases[$alias]) } }
    if ($found.Count -eq 1) { return @($found)[0] }
    return $null
}

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
    # The reader carries a `Lister` note: param([string] $RepoDirectory) emits the repo paths of the files directly in
    # that directory, matched case-insensitively and spelled as the tree spells them (Find-CiScriptLookupFiles).
    param([Parameter(Mandatory)] [string] $RepoRoot, [string] $Ref, [scriptblock] $Git)
    if ([string]::IsNullOrWhiteSpace($Ref)) {
        $workingReader = {
            param([string] $RepoPath)
            $full = Join-Path $RepoRoot ($RepoPath.Replace('/', '\'))
            if (-not [IO.File]::Exists($full)) { return $null }
            return [IO.File]::ReadAllText($full)
        }.GetNewClosure()
        # Each directory of the path is spelled as the tree spells it, not as the caller did (Sol on #740: `Fixtures\x`
        # listed `Fixtures/x.cmd` where the tree holds `fixtures/x.cmd`, and an ordinal match then missed it).
        $workingLister = {
            param([string] $RepoDirectory)
            $full = $RepoRoot
            $spelled = [System.Collections.Generic.List[string]]::new()
            foreach ($component in @($RepoDirectory -split '/' | Where-Object { $_ })) {
                $matched = @([IO.Directory]::GetDirectories($full) | Where-Object { [string]::Equals([IO.Path]::GetFileName($_), $component, [StringComparison]::OrdinalIgnoreCase) })
                if ($matched.Count -ne 1) { return }
                $full = $matched[0]
                $spelled.Add([IO.Path]::GetFileName($matched[0]))
            }
            $prefix = $spelled -join '/'
            foreach ($file in [IO.Directory]::GetFiles($full)) {
                $name = [IO.Path]::GetFileName($file)
                $(if ($prefix) { "$prefix/$name" } else { $name })
            }
        }.GetNewClosure()
        $workingReader.PSObject.Properties.Add([psnoteproperty]::new('Lister', $workingLister))
        return $workingReader
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
    $treeReader = {
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
    $treeLister = {
        param([string] $RepoDirectory)
        foreach ($key in @($entries.Keys)) {
            if ($entries[$key][1] -cne 'blob') { continue }
            $cut = $key.LastIndexOf('/')
            $parent = $(if ($cut -ge 0) { $key.Substring(0, $cut) } else { '' })
            if ([string]::Equals($parent, $RepoDirectory, [StringComparison]::OrdinalIgnoreCase)) { $key }
        }
    }.GetNewClosure()
    $treeReader.PSObject.Properties.Add([psnoteproperty]::new('Lister', $treeLister))
    return $treeReader
}

function Get-CiScriptCommandName {
    # The name a command element calls by, lower-case, for a bare word; $null otherwise. A module-qualified cmdlet runs
    # what its bare name runs, so its module goes (CodeRabbit on #740: a qualified Add-Type -Path was skipped, its C#
    # file left the closure, and a qualified Set-Variable was no write).
    # Only a module PowerShell ships qualifies a cmdlet here: any other `<word>\<Verb-Noun>` may be a relative path,
    # which PowerShell runs as a script when one is there (Opus on #740: `sub\Run-Child` ran `sub\Run-Child.ps1`).
    param($Element)
    if ($Element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
    # Trailing spaces trimmed, as Windows does when it runs a name (Opus on #740: `& 'cmd '` ran cmd).
    $text = $Element.Value.TrimEnd(' ')
    if (Test-CiScriptShippedCmdlet $text) { return ($text -split '\\', 2)[1].ToLowerInvariant() }
    return $text.ToLowerInvariant()
}

function Test-CiScriptPowerShellName {
    param([string] $Name)
    if (-not $Name) { return $false }
    $leaf = ($Name.TrimEnd(' ') -split '[\\/]')[-1]
    return $leaf -in @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe')
}

function Test-CiScriptTargetKind {
    # 'script' for .ps1/.psm1, 'batch' for .cmd/.bat, 'native' for .exe/.com, else 'other'.
    param([string] $Path)
    if (-not $Path) { return 'other' }
    $extension = [IO.Path]::GetExtension($Path.TrimEnd(' ')).ToLowerInvariant()
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
            # A quoted string loses its quotes; a bare word in argument mode (`cmd /c $PSScriptRoot\x.cmd`) has none.
            $result = $_.Extent.Text
            $base = $_.Extent.StartOffset
            if ($_.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::BareWord) {
                if ($result.Length -lt 2) { return $unresolved }
                $result = $result.Substring(1, $result.Length - 2)
                $base++
            }
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
            # (Opus on #740: a local `Get-*ExePath` that returned a .ps1 was trusted by its name). A module-qualified
            # name calls the module's command, never the file's function.
            $local = @((Get-CiScriptNodes $Context FunctionDefinitionAst) | Where-Object { $_.Name -ieq $elements[0].Value })
            if ($local.Count -gt 0) {
                $body = $local[0].Body
                $statements = @($body.EndBlock.Statements)
                if ($local.Count -ne 1 -or $body.BeginBlock -or $body.ProcessBlock -or $body.DynamicParamBlock -or $statements.Count -ne 1) { return $unresolved }
                $only = $statements[0]
                if ($only -is [System.Management.Automation.Language.ReturnStatementAst]) { $only = $only.Pipeline }
                return Resolve-CiScriptValue $only $Context ($Depth + 1)
            }
            # Get-Command <name>: that executable, or the script it names.
            if ($name -in @('get-command', 'gcm')) {
                # Its -Name, or its first positional argument (a parameter's own argument skipped).
                $nameNode = $null
                for ($i = 1; $i -lt $elements.Count -and $null -eq $nameNode; $i++) {
                    $element = $elements[$i]
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { $nameNode = $element; break }
                    if ($element.ParameterName -ieq 'Name') { $nameNode = $(if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] }); break }
                    if (-not $element.Argument -and $element.ParameterName -notin @('All', 'ListImported', 'Syntax', 'ShowCommandInfo', 'UseFuzzyMatching', 'UseAbbreviationExpansion')) { $i++ }
                }
                # A name that is not a literal is read like any other value (Opus on #740:
                # `$c = Get-Command (Join-Path $PSScriptRoot 'x.ps1'); & $c` read as a native program with no name, and
                # x.ps1 dropped out of the closure without a problem). A name the walker cannot read may be a script's,
                # so the lookup is unresolved; a native program it names stays that program.
                if ($null -eq $nameNode) { return $unresolved }
                $nameValue = Resolve-CiScriptValue $nameNode $Context ($Depth + 1)
                if ($nameValue.Kind -eq 'native') { return $nameValue }
                if ($nameValue.Kind -ne 'path') { return $unresolved }
                $target = $nameValue.Value.TrimEnd(' ')
                # A wildcard name (`pwsh*`, `pwsh.ex?`, `[p]wsh.exe`, `<dir>\chil*`) or a fuzzy lookup finds a command
                # the walker cannot name, a script among them, whatever -CommandType says: unresolved (Sol on #740:
                # `(Get-Command "pwsh.ex?").Source` read as a known program, then
                # `Get-Command <dir>\chil* -CommandType ExternalScript` as an unknown one, and each dropped its child
                # without a problem).
                $vague = [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($target) -or
                    @($elements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -in @('UseFuzzyMatching', 'UseAbbreviationExpansion') }).Count -gt 0
                if ($vague) { return $unresolved }
                # A script or batch file: its path, judged as any edge target is. A rooted one resolves; a bare name,
                # which Get-Command looks up on PATH, and a relative one, found from the current location, do not.
                $kind = Test-CiScriptTargetKind $target
                if ($kind -in @('script', 'batch')) { return @{ Kind = 'path'; Value = $target } }
                # A name with a separator is a path lookup, not a command name (Sol and Opus on #740): an executable
                # by its extension, a cmdlet qualified by a module PowerShell ships, else the script
                # Get-CiScriptPathLookup names (`<dir>\cmd` and `<dir>\pwsh` included), or unresolved. A bare name is
                # a command on PATH.
                $leaf = ($target -split '[\\/]')[-1].ToLowerInvariant()
                if ($target -match '[\\/]' -and $kind -ne 'native' -and -not (Test-CiScriptShippedCmdlet $target)) {
                    $lookup = Get-CiScriptPathLookup $target
                    if ($null -eq $lookup) { return $unresolved }
                    return @{ Kind = 'path'; Value = $lookup; Lookup = $true }
                }
                return @{ Kind = 'native'; Value = $leaf }
            }
            # A harness helper that names an executable by convention (Get-InteractiveWin11ExePath): native, named by
            # the helper. One named for PowerShell is an executable the walker cannot name.
            if ($name -match '(?i)^get-[a-z0-9-]*(exepath|clipath)$') {
                return @{ Kind = 'native'; Value = $(if ($name -match 'pwsh|powershell|cmd|bat') { $null } else { $name }) }
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
    # A common -*Variable parameter by its alias or by any prefix PowerShell can bind to it: the shortest prefix that
    # no other common parameter shares (a cmdlet's own parameters can only make a prefix longer). A name that is not a
    # literal is a write of a variable the walker cannot name.
    $variableParameters = @(@('outvariable', 4), @('pipelinevariable', 2), @('errorvariable', 6), @('warningvariable', 8), @('informationvariable', 12))
    foreach ($parameter in (Get-CiScriptNodes $Context CommandParameterAst)) {
        $given = $parameter.ParameterName.ToLowerInvariant()
        $writes = @('ov', 'pv', 'ev', 'wv', 'iv').Contains($given) -or @($variableParameters | Where-Object { $given.Length -ge $_[1] -and $_[0].StartsWith($given, [StringComparison]::Ordinal) }).Count -gt 0
        if (-not $writes) { continue }
        $elements = @($parameter.Parent.CommandElements)
        $argument = $(if ($parameter.Argument) { $parameter.Argument } else { $at = [array]::IndexOf($elements, $parameter); if ($at -ge 0 -and $at + 1 -lt $elements.Count) { $elements[$at + 1] } })
        if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$names.Add($argument.Value.TrimStart('+')) } else { $unknown = $true }
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
    #   * at script level, which variable a name is depends on how the file runs, which the walker cannot see
    #     (measured on pwsh 7.6.10 and Windows PowerShell 5.1.26100). A -File entry runs in the global scope (it has
    #     no parent scope), so an unqualified, a `$script:` and a `$global:` write are one variable; a script run
    #     with & has its own script scope, apart from the global one; a file dot-sourced in a function writes its
    #     unqualified names in that function's scope, apart from its caller's script scope (which is the global one
    #     when the caller is a -File entry). A read looks through the scopes of each way from its own out, and stops
    #     at a write that dominates it, or at the script's parameter, which is a variable of the file's own scope
    #     from the start. Every way's values count (Opus on #740: `$c = <a>; $global:c = <b>; & $c` reads b under
    #     -File and a under &, and the walk took b alone). A `$script:` or `$global:` write in a function may run at
    #     any time, so it adds a value wherever its scope is looked through.
    # A read with a scope qualifier (`$global:c`) names no variable the walker matches, so it is unresolved.
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
                # The scope a qualifier names: global, script, or the write's own (unqualified, local:, private:).
                Scope = $(if ($path.IsGlobal) { 'global' } elseif ($path.IsScript) { 'script' } else { 'local' })
                Value = $value
            })
        }
        $writes = @($writes | Sort-Object { $_.Node.Extent.StartOffset })
        # Each write's value, resolved once: the script-level ways below read the same writes again.
        $resolvedWrites = @{}
        $valueOf = {
            param($write)
            if ($null -ne $write.Value) { return $write.Value }
            $at = $write.Node.Extent.StartOffset
            if (-not $resolvedWrites.ContainsKey($at)) { $resolvedWrites[$at] = Resolve-CiScriptValue $write.Node.Right $Context ($Depth + 1) }
            return $resolvedWrites[$at]
        }
        $values = [System.Collections.Generic.List[hashtable]]::new()
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
        # The values one variable's writes ($Set, in source order) give the read, and whether one of them dominates it.
        # The writes inside the read's scriptblock (or its whole scope), the last that dominates the read, and the
        # loops between that write and the read: a write anywhere in one of those reaches the read on a later pass.
        # A read in a scriptblock that no write inside dominates may run after any later write of the scope; the last
        # write that dominates the scriptblock's definition replaces everything before it.
        $flow = {
            param([object[]] $Set)
            $found = [System.Collections.Generic.List[hashtable]]::new()
            $inner = @($Set | Where-Object { $null -eq $scriptblock -or (& $inside $_.Node $scriptblock) })
            $dominant = @($inner | Where-Object { & $dominates $_ $Use $useOffset } | Select-Object -Last 1)
            $carry = @($loops | Where-Object { $dominant.Count -eq 0 -or (& $inside $_ $dominant[0].Node.Parent) } | Select-Object -Last 1)
            $reaching = @($inner | Where-Object {
                ($dominant.Count -eq 0 -or $_.Node.Extent.StartOffset -ge $dominant[0].Node.Extent.StartOffset) -and
                    ($_.Node.Extent.EndOffset -le $useOffset -or ($carry.Count -eq 1 -and (& $inside $_.Node $carry[0])))
            })
            foreach ($write in $reaching) { $found.Add((& $valueOf $write)) }
            if ($dominant.Count -eq 0 -and $scriptblock) {
                $outer = @($Set | Where-Object { -not (& $inside $_.Node $scriptblock) })
                $outerDominant = @($outer | Where-Object { & $dominates $_ $scriptblock $scriptblock.Extent.StartOffset } | Select-Object -Last 1)
                foreach ($write in $outer) {
                    if ($outerDominant.Count -eq 0 -or $write.Node.Extent.StartOffset -ge $outerDominant[0].Node.Extent.StartOffset) { $found.Add((& $valueOf $write)) }
                }
                if ($outerDominant.Count -eq 1) { $dominant = $outerDominant }
            }
            return @{ Values = $found; Dominated = $dominant.Count -gt 0 }
        }
        if ($useFunction) {
            # The function's own writes.
            $result = & $flow @($writes | Where-Object { [object]::ReferenceEquals($_.Function, $useFunction) -and -not $_.Outer })
            foreach ($value in $result.Values) { $values.Add($value) }
            if (-not $result.Dominated) {
                # The value the function starts with.
                $parameter = Get-CiScriptParameterOf $useFunction $Name
                if ($parameter) { $values.Add((Resolve-CiScriptParameter $parameter)) }
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
            return Merge-CiScriptValues $values
        }
        # At script level, each way the file can run: its scopes, in the order the read looks through them, each naming
        # the write scopes that land in it (-File; &; dot-sourced in a function under a -File caller; dot-sourced in a
        # function under an & caller).
        $top = @($writes | Where-Object { $null -eq $_.Function })
        $inFunctions = @($writes | Where-Object { $null -ne $_.Function -and $_.Outer })
        $scriptParameter = Get-CiScriptParameterOf $ast $Name
        foreach ($way in @('local script global', 'local script|global', 'local|script global', 'local|script|global')) {
            $scopes = @($way -split '\|')
            $settled = $false
            for ($i = 0; $i -lt $scopes.Count -and -not $settled; $i++) {
                $lands = @($scopes[$i] -split ' ')
                $result = & $flow @($top | Where-Object { $lands -ccontains $_.Scope })
                foreach ($value in $result.Values) { $values.Add($value) }
                foreach ($write in @($inFunctions | Where-Object { $lands -ccontains $_.Scope })) { $values.Add((& $valueOf $write)) }
                $settled = $result.Dominated
                if (-not $settled -and $scriptParameter -and $lands -ccontains 'local') { $values.Add((Resolve-CiScriptParameter $scriptParameter)); $settled = $true }
            }
            # The scope's start: what a caller that dot-sources the file gave it, which the walker cannot see.
            if (-not $settled) { $values.Add($unresolved) }
        }
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

# The edges of one parsed file: @{ Targets = list of repo paths (resolved); Lookups = list of repo paths with no
# extension, path lookups (Find-CiScriptLookupFiles); Unresolved = list of anchors; CSharp = list of repo paths
# (Add-Type -Path) }.
function Get-CiScriptFileEdges {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $RepoPath,
        # An empty file has no edges; '' is its text, and the reader's $null (no file) never reaches here (CodeRabbit
        # on #740: without AllowEmptyString a zero-byte helper failed the walk on a binding error).
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$RepoPath does not parse: $($errors[0].Message)" }
    $context = New-CiScriptContext -RepoRoot $RepoRoot -RepoPath $RepoPath -Ast $ast
    $targets = [System.Collections.Generic.List[string]]::new()
    $lookups = [System.Collections.Generic.List[string]]::new()
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
    # A PowerShell command-line parameter (the executable's own matching: a unique prefix): what it does to the walk.
    # Checked against each host's own parser (CommandLineParameterParser, called in process on every prefix of every
    # parameter, pwsh 7.6.10 and Windows PowerShell 5.1.26100): pwsh reads `-in` as -Interactive, so its next word is
    # the script, and needs `-inp` for -InputFormat, which Windows PowerShell takes from `-in`; -Token and
    # -UTCTimestamp take a value; and Windows PowerShell, which lacks -ConfigurationFile, -CustomPipeName and
    # -SettingsFile, runs the rest of its line as code after one of them.
    $powershellParameter = {
        param([string] $Name, [bool] $Pwsh)
        if ($Name -match '\Af(i(l(e)?)?)?\z') { return 'file' }
        if ($Name.Length -gt 'encoded'.Length -and 'encodedarguments'.StartsWith($Name)) { return 'value' }
        if ($Name -ceq 'ea') { return 'value' }
        foreach ($pwshOnly in @(@('configurationfile', 14), @('custompipename', 3), @('settingsfile', 8))) {
            if ($Name.Length -ge $pwshOnly[1] -and $pwshOnly[0].StartsWith($Name)) { return $(if ($Pwsh) { 'value' } else { 'command' }) }
        }
        if ($Name.Length -ge $(if ($Pwsh) { 3 } else { 2 }) -and 'inputformat'.StartsWith($Name)) { return 'value' }
        foreach ($valued in @(@('configurationname', 6), @('executionpolicy', 2), @('outputformat', 1), @('windowstyle', 1), @('workingdirectory', 2), @('psconsolefile', 3),
                @('token', 2), @('utctimestamp', 3))) {
            if ($Name.Length -ge $valued[1] -and $valued[0].StartsWith($Name)) { return 'value' }
        }
        if ($Name -in @('ep', 'ex', 'if', 'of', 'wd', 'config')) { return 'value' }
        if ($Name -ceq 'ec' -or 'command'.StartsWith($Name) -or 'encodedcommand'.StartsWith($Name)) { return 'command' }
        # Windows PowerShell's -Version takes a version; pwsh's prints its own.
        if (-not $Pwsh -and 'version'.StartsWith($Name)) { return 'value' }
        return 'switch'
    }
    # A script target that must resolve: a rooted .ps1 or .psm1 path, or a path lookup (Find-CiScriptLookupFiles);
    # anything else is unresolved, a .cmd or .bat path included (cmd and batch files are refused).
    $scriptTarget = {
        param($Value, [string] $Why)
        # Trailing spaces trimmed before the member is recorded, as Windows runs the path (Opus on #740:
        # `-File "<dir>\child.ps1 "` ran child.ps1 and was listed misspelled).
        if ($Value.Kind -eq 'path' -and $Value.Value -is [string] -and $Value.Value -ne $Value.Value.TrimEnd(' ')) {
            $Value = @{ Kind = 'path'; Value = $Value.Value.TrimEnd(' '); Lookup = $Value.Lookup }
        }
        # A path lookup's files are found when the closure reads the tree (Find-CiScriptLookupFiles).
        if ($Value.Kind -eq 'path' -and $Value.Lookup) {
            $repo = ConvertTo-CiScriptTargetPath -RepoRoot $RepoRoot -Value $Value.Value
            if ($repo) { $lookups.Add($repo); return }
            $unresolved.Add($Why); return
        }
        # A batch file is unresolved, never a target: the walk does not read cmd or batch semantics.
        if ($Value.Kind -eq 'path' -and (Test-CiScriptTargetKind $Value.Value) -ceq 'script') {
            $repo = ConvertTo-CiScriptTargetPath -RepoRoot $RepoRoot -Value $Value.Value
            if ($repo) { $targets.Add($repo); return }
        }
        $unresolved.Add($Why)
    }
    # Whether an argument is one known string: a literal, an expandable string (one argument however it expands), a
    # number, or a value the walker resolves to one string; not a splat, an array or a value it cannot read.
    $scalarArgument = {
        param($Entry)
        if ($Entry.Splat) { return $false }
        if ($Entry.Param) { return $true }
        $node = $Entry.Node
        if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
            ($node -is [System.Management.Automation.Language.ConstantExpressionAst])) { return $true }
        $value = & $valueOf $Entry
        return $value.Kind -eq 'path' -and -not $value.Lookup -and $value.Value -is [string]
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
                    'value' {
                        # The value slot is read, not skipped (Opus on #740): PowerShell quotes a scalar argument but
                        # expands an array into several, so a variable or computed value passes only as one known
                        # string; a literal passes.
                        $valueEntry = $(if ($entry.Attached) { $entry.Attached } elseif ($i + 1 -lt $Entries.Count) { $Entries[$i + 1] })
                        if ($null -ne $valueEntry -and -not (& $scalarArgument $valueEntry)) { $unresolved.Add($Why); return }
                        if (-not $entry.Attached) { $i++ }
                    }
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
            if ($value.Kind -eq 'unresolved' -or $value.Lookup) { return $true }
            if ($value.Kind -eq 'path' -and $value.Value -match '(?i)\.(ps1|psm1|psd1|cmd|bat)\b|\b(pwsh|powershell)\b') { return $true }
        }
        return $false
    }
    # What a callee is: @{ Is = 'script' (Value: its path) | 'powershell' (Pwsh) | 'cmd' | 'native' | 'command'
    # (Value: a command name) | 'maybe' (an executable the walker cannot name) | 'unresolved' | 'none' }.
    $classify = {
        param($Value)
        # Trailing spaces trimmed from a name or path, as Windows runs it (Opus on #740: `& 'cmd '` and
        # `Start-Process 'CMD.EXE  '` ran cmd).
        if ($Value.Kind -in @('path', 'native') -and $Value.Value -is [string] -and $Value.Value -ne $Value.Value.TrimEnd(' ')) {
            $Value = @{ Kind = $Value.Kind; Value = $Value.Value.TrimEnd(' '); Lookup = $Value.Lookup }
        }
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
                if ($Value.Lookup) { return @{ Is = 'script'; Value = $Value } }
                $kind = Test-CiScriptTargetKind $Value.Value
                if ($kind -in @('script', 'batch')) { return @{ Is = 'script'; Value = $Value } }
                $leaf = ($Value.Value -split '[\\/]')[-1].ToLowerInvariant()
                # A path with no extension is a path lookup, whatever its leaf (Sol on #740:
                # `& (Join-Path $PSScriptRoot 'fixtures\cmd')` ran `fixtures\cmd.ps1`, not cmd).
                if ($Value.Value -match '[\\/]' -and $kind -ne 'native' -and -not (Test-CiScriptShippedCmdlet $Value.Value)) {
                    $lookup = Get-CiScriptPathLookup $Value.Value
                    if ($null -ne $lookup) { return @{ Is = 'script'; Value = @{ Kind = 'path'; Value = $lookup; Lookup = $true } } }
                }
                # Only a bare name, or a path whose extension names an executable (`$PSHOME\pwsh.exe`), reaches here:
                # a script, batch or extensionless path was classified above, before its leaf is read.
                if (Test-CiScriptPowerShellName $leaf) { return @{ Is = 'powershell'; Pwsh = $leaf.StartsWith('pwsh') } }
                if ($leaf -in @('cmd', 'cmd.exe')) { return @{ Is = 'cmd' } }
                if ($kind -eq 'native') { return @{ Is = 'native' } }
                # A bare word names a command, and so does a cmdlet qualified by a module PowerShell ships; any other
                # path with an extension the walk does not know is unresolved.
                if ($Value.Value -notmatch '[\\/]') { return @{ Is = 'command'; Value = $leaf } }
                if (Test-CiScriptShippedCmdlet $Value.Value) { return @{ Is = 'command'; Value = ($Value.Value -split '\\', 2)[1].ToLowerInvariant() } }
                return @{ Is = 'unresolved' }
            }
        }
        return @{ Is = 'unresolved' }
    }
    # Run a classified callee with its argument entries.
    $invoke = {
        param($Callee, [object[]] $Entries, [string] $Why)
        switch ($Callee.Is) {
            'script' { & $scriptTarget $Callee.Value $Why }
            'powershell' { & $powershellArguments $Entries $Callee.Pwsh $Why }
            # cmd is never read (the header's edge list): unresolved, with any arguments.
            'cmd' { $unresolved.Add($Why) }
            # An executable the walker cannot name may be cmd, PowerShell or a batch file, whose arguments PowerShell
            # rules do not read (Opus on #740): unresolved, whatever its arguments.
            'maybe' { $unresolved.Add($Why) }
            'unresolved' { $unresolved.Add($Why) }
        }
    }
    # A cmdlet's arguments bound as PowerShell binds them: @{ Named = parameter name -> its argument entry (a switch's
    # own entry); Positional = entries }. Before the walker picks a file or code it must know which words a parameter
    # took, common parameters included (CodeRabbit on #740: `Invoke-Expression -ErrorAction Stop -Command <code>`
    # scanned `Stop` as the code). A switch takes no next word; `--` ends the parameters. $null when the walker cannot
    # bind them, and the caller then reports the edge unresolved: a splat, a name the cmdlet does not have or that is
    # ambiguous, a parameter given twice, or one with no argument.
    $parameterTables = @{}
    $bindCmdlet = {
        param([object[]] $Entries, [string] $Cmdlet)
        if (-not $parameterTables.ContainsKey($Cmdlet)) { $parameterTables[$Cmdlet] = Get-CiScriptParameterTable -Cmdlet $Cmdlet }
        $table = $parameterTables[$Cmdlet]
        $named = @{}
        $positional = [System.Collections.Generic.List[object]]::new()
        $ended = $false
        for ($i = 0; $i -lt $Entries.Count; $i++) {
            $entry = $Entries[$i]
            if ($entry.Splat) { return $null }
            if ($ended -or $entry.Node -isnot [System.Management.Automation.Language.CommandParameterAst]) { $positional.Add($entry); continue }
            if ($entry.Node.ParameterName -ceq '-') { $ended = $true; continue }
            $name = Resolve-CiScriptParameterName -Given $entry.Param -Table $table
            if ($null -eq $name -or $named.ContainsKey($name)) { return $null }
            if ($table.Switch[$name]) { $named[$name] = $entry; continue }
            $argument = $entry.Attached
            if ($null -eq $argument) {
                if ($i + 1 -ge $Entries.Count -or $Entries[$i + 1].Splat -or $Entries[$i + 1].Node -is [System.Management.Automation.Language.CommandParameterAst]) { return $null }
                $i++
                $argument = $Entries[$i]
            }
            $named[$name] = $argument
        }
        return @{ Named = $named; Positional = $positional }
    }
    # Literal code run as a script (Invoke-Expression, [scriptblock]::Create): its own edges; anything else unresolved.
    $codeEdges = {
        param($Node, [string] $Why)
        $value = $(if ($Node) { Resolve-CiScriptValue $Node $context } else { $unresolvedValue })
        if ($value.Kind -ne 'path') { $unresolved.Add($Why); return }
        try { $inner = Get-CiScriptFileEdges -RepoRoot $RepoRoot -RepoPath $RepoPath -Text $value.Value }
        catch { $unresolved.Add($Why); return }
        foreach ($target in $inner.Targets) { $targets.Add($target) }
        foreach ($lookup in $inner.Lookups) { $lookups.Add($lookup) }
        foreach ($source in $inner.CSharp) { $csharp.Add($source) }
        if ($inner.Unresolved.Count -gt 0) { $unresolved.Add($Why) }
    }

    # The commands that may run a script by name: PowerShell, cmd and the cmdlets above, and those that define an alias
    # (Set-Alias, New-Alias, Import-Alias, and Set-Item or New-Item of an alias: item).
    $edgeCommands = @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe', 'cmd', 'cmd.exe', 'add-type', 'start-process', 'saps', 'start',
        'start-job', 'sajb', 'start-threadjob', 'invoke-command', 'icm', 'invoke-expression', 'iex', 'import-module', 'ipmo',
        'set-alias', 'sal', 'new-alias', 'nal', 'import-alias', 'ipal', 'set-item', 'si', 'new-item', 'ni')
    # The commands the walker reads by name: those, and the variable writes it cannot read as a value
    # (Get-CiScriptDynamicWrites). Another name for one of them hides what the walker would read.
    $readByName = [System.Collections.Generic.HashSet[string]]::new([string[]]@($edgeCommands + @('set-variable', 'sv', 'new-variable', 'nv')), [StringComparer]::OrdinalIgnoreCase)
    # A command a name stands for (an alias's value, a PowerShell object's AddCommand argument; Opus on #740: both
    # dropped their script without a problem). A script it names is an edge, judged as any target is. A native program,
    # or a cmdlet or program the walker does not read by name, is none. Anything else is unresolved: a value the walker
    # cannot read, PowerShell, cmd or an unknown executable (whose arguments come with each later call, or through
    # AddParameter and AddArgument, none of which it follows), and a command it reads by name.
    $namedCommand = {
        param($Value, [string] $Why)
        $callee = & $classify $Value
        if ($callee.Is -ceq 'script') { & $scriptTarget $callee.Value $Why; return }
        if ($callee.Is -ceq 'native' -or ($callee.Is -ceq 'command' -and -not $readByName.Contains($callee.Value))) { return }
        $unresolved.Add($Why)
    }
    foreach ($command in (Get-CiScriptNodes $context CommandAst)) {
        $elements = $command.CommandElements
        $anchor = ConvertTo-CiScriptAnchor $command.Extent.Text
        $operator = $command.InvocationOperator
        $first = $elements[0]
        $invoked = $operator -eq [System.Management.Automation.Language.TokenKind]::Dot -or $operator -eq [System.Management.Automation.Language.TokenKind]::Ampersand
        # A bare path called without `&` is PowerShell's implicit `&` (Opus on #740); a cmdlet qualified by a module
        # PowerShell ships (Microsoft.PowerShell.Utility\Write-Host) is not a path, and Get-CiScriptCommandName names
        # its cmdlet. Any other name with a separator (`sub\Run-Child`) is a path lookup.
        $barePath = -not $invoked -and $first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $first.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::BareWord -and
            ($first.Value -match '[\\/]' -or (Test-CiScriptTargetKind $first.Value) -ne 'other') -and
            -not (Test-CiScriptShippedCmdlet $first.Value)
        if (-not $invoked -and -not $barePath -and (Get-CiScriptCommandName $first) -notin $edgeCommands) { continue }
        $entries = @($elements | Select-Object -Skip 1 | ForEach-Object { & $toEntry $_ })
        # A shell later in a pipeline reads its commands from its input, which the walk does not read (Opus on #740).
        $piped = $command.Parent -is [System.Management.Automation.Language.PipelineAst] -and $command.Parent.PipelineElements.IndexOf($command) -gt 0
        if ($invoked -or $barePath) {
            if ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            $callee = & $classify (Resolve-CiScriptValue $first $context)
            if ($piped -and $callee.Is -in @('powershell', 'cmd')) { $unresolved.Add($anchor); continue }
            if ($callee.Is -cne 'command') { & $invoke $callee $entries $anchor; continue }
            $name = $callee.Value
        } else {
            $name = Get-CiScriptCommandName $first
            if (-not $name) { continue }
            $callee = & $classify @{ Kind = 'path'; Value = $name }
            if ($piped -and $callee.Is -in @('powershell', 'cmd')) { $unresolved.Add($anchor); continue }
            if ($callee.Is -in @('powershell', 'cmd')) { & $invoke $callee $entries $anchor; continue }
        }
        switch ($name) {
            'add-type' {
                # -Path or -LiteralPath (its aliases PSPath and LP, or a prefix) names a source file. A positional
                # argument is source text: it binds -TypeDefinition, the default set's, or -Name.
                $bound = & $bindCmdlet $entries 'add-type'
                if ($null -eq $bound) { $unresolved.Add($anchor); break }
                foreach ($parameter in @('path', 'literalpath')) {
                    if (-not $bound.Named.ContainsKey($parameter)) { continue }
                    $value = & $valueOf $bound.Named[$parameter]
                    $repo = $(if ($value.Kind -eq 'path') { ConvertTo-CiScriptTargetPath -RepoRoot $RepoRoot -Value $value.Value })
                    if ($repo) { $csharp.Add($repo) } else { $unresolved.Add($anchor) }
                }
            }
            { $_ -in @('start-process', 'saps', 'start') } {
                $bound = & $bindCmdlet $entries 'start-process'
                if ($null -eq $bound) { $unresolved.Add($anchor); break }
                $file = $(if ($bound.Named.ContainsKey('filepath')) { $bound.Named['filepath'] } elseif ($bound.Positional.Count -ge 1) { $bound.Positional[0] })
                $list = $(if ($bound.Named.ContainsKey('argumentlist')) { $bound.Named['argumentlist'] } elseif ($bound.Positional.Count -ge 2 -and -not $bound.Named.ContainsKey('filepath')) { $bound.Positional[1] } elseif ($bound.Named.ContainsKey('filepath') -and $bound.Positional.Count -ge 1) { $bound.Positional[0] })
                if ($null -eq $file) { $unresolved.Add($anchor); break }
                $callee = & $classify (& $valueOf $file)
                # Start-Process joins its arguments without quoting and the shell tokenizes them again, so no element
                # rule can be sound (Sol, Opus, Greptile and CodeRabbit on #740: a variable, a parenthesized string,
                # `-f`, `+`, `$( )` or a `u{20} escape in a value slot carried -Command through). Start-Process of
                # PowerShell is refused, as cmd and batch files are; no GUI member starts PowerShell that way.
                if ($callee.Is -ceq 'powershell') { $unresolved.Add($anchor); break }
                # A bare name may be found in -WorkingDirectory (Opus on #740): unresolved, save a system program. A
                # FilePath variable there is not checked: a known gap (README).
                if ($bound.Named.ContainsKey('workingdirectory') -and $file.Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $file.Node.Value.TrimEnd(' ') -notmatch '[\\/]' -and $file.Node.Value.TrimEnd(' ').ToLowerInvariant() -notin $script:CiScriptSystemPrograms) { $unresolved.Add($anchor); break }
                if ($callee.Is -in @('none', 'native', 'command')) { break }
                # A shell given -RedirectStandardInput reads its commands from that file (Opus on #740), and so may an
                # executable the walker cannot name (CodeRabbit on #740: one of cmd.exe or sort.exe); a known
                # non-shell executable returned above.
                if ($callee.Is -in @('powershell', 'cmd', 'maybe') -and $bound.Named.ContainsKey('redirectstandardinput')) { $unresolved.Add($anchor); break }
                # A script (a batch file is unresolved there), cmd and an unresolved file take no argument reading.
                if ($callee.Is -in @('script', 'cmd', 'unresolved')) { & $invoke $callee @() $anchor; break }
                if ($null -eq $list) { & $invoke $callee @() $anchor; break }
                $listed = $(if ($list.Node) { & $listEntries $list.Node } elseif ($list.Value) { , @($list.Value.Value -split '\s+' | Where-Object { $_ } | ForEach-Object { & $wordEntry $_ }) })
                if ($null -eq $listed) { $unresolved.Add($anchor); break }
                & $invoke $callee $listed $anchor
            }
            { $_ -in @('start-job', 'sajb', 'start-threadjob', 'invoke-command', 'icm') } {
                $cmdlet = $(if ($_ -in @('start-job', 'sajb')) { 'start-job' } elseif ($_ -ceq 'start-threadjob') { 'start-threadjob' } else { 'invoke-command' })
                $bound = & $bindCmdlet $entries $cmdlet
                if ($null -eq $bound) { $unresolved.Add($anchor); break }
                $file = $(if ($bound.Named.ContainsKey('filepath')) { $bound.Named['filepath'] } elseif ($bound.Named.ContainsKey('literalpath')) { $bound.Named['literalpath'] })
                if ($null -ne $file) { & $scriptTarget (& $valueOf $file) $anchor; break }
                # A -ScriptBlock, named or by position, or Start-Job's -DefinitionName, puts the command in a parameter
                # set without -FilePath. Otherwise a positional argument may be the -FilePath (Start-Job's and
                # Start-ThreadJob's first, Invoke-Command's after its -ComputerName, -Session or -ConnectionUri): a
                # script it names is an edge, one the walker cannot read is unresolved, and another literal (a computer
                # name) is none.
                if ($bound.Named.ContainsKey('scriptblock') -or $bound.Named.ContainsKey('definitionname')) { break }
                $values = @(foreach ($entry in $bound.Positional) { & $valueOf $entry })
                if ($cmdlet -cne 'invoke-command') {
                    # Start-Job's and Start-ThreadJob's first positional is -FilePath in its parameter set and
                    # -ScriptBlock in the other; the second is -InitializationScript in both, so a block there hides
                    # nothing (CodeRabbit on #740: `Start-Job (Join-Path $PSScriptRoot 'child.ps1') { 1 }` runs the
                    # file). The first decides: a block is an inline job, a script is an edge, anything else at the
                    # file's position is unresolved.
                    if ($values.Count -eq 0 -or $values[0].Kind -eq 'scriptblock') { break }
                    if ($values[0].Kind -eq 'path' -and (Test-CiScriptTargetKind $values[0].Value) -in @('script', 'batch')) { & $scriptTarget $values[0] $anchor }
                    else { $unresolved.Add($anchor) }
                    break
                }
                if (@($values | Where-Object { $_.Kind -eq 'scriptblock' }).Count -gt 0) { break }
                if (@($values | Where-Object { $_.Kind -eq 'unresolved' }).Count -gt 0) { $unresolved.Add($anchor); break }
                foreach ($value in $values) {
                    if ($value.Kind -eq 'path' -and (Test-CiScriptTargetKind $value.Value) -in @('script', 'batch')) { & $scriptTarget $value $anchor }
                }
            }
            { $_ -in @('invoke-expression', 'iex') } {
                # The code: -Command or the one positional argument. With neither it comes down the pipeline, which the
                # walker cannot read; with both, PowerShell refuses the command.
                $bound = & $bindCmdlet $entries 'invoke-expression'
                if ($null -eq $bound) { $unresolved.Add($anchor); break }
                $code = @(@($(if ($bound.Named.ContainsKey('command')) { $bound.Named['command'] })) + @($bound.Positional))
                & $codeEdges $(if ($code.Count -eq 1) { $code[0].Node }) $anchor
            }
            { $_ -in @('import-module', 'ipmo') } {
                # The module: -Name or the one positional argument. -FullyQualifiedName (a specification that may hold a
                # path), -Assembly and -ModuleInfo load what the walker cannot name.
                $bound = & $bindCmdlet $entries 'import-module'
                $module = $null
                if ($null -ne $bound -and -not ($bound.Named.ContainsKey('fullyqualifiedname') -or $bound.Named.ContainsKey('assembly') -or $bound.Named.ContainsKey('moduleinfo'))) {
                    if ($bound.Named.ContainsKey('name')) { if ($bound.Positional.Count -eq 0) { $module = $bound.Named['name'] } }
                    elseif ($bound.Positional.Count -eq 1) { $module = $bound.Positional[0] }
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
            { $_ -in @('set-alias', 'sal', 'new-alias', 'nal') } {
                # The alias's value (-Value, or the positional after -Name) is the command its name stands for. The edge
                # is the definition, so an alias a dot-sourcing caller calls is covered as well as one this file calls.
                $bound = & $bindCmdlet $entries 'set-alias'
                if ($null -eq $bound) { $unresolved.Add($anchor); break }
                $expected = 2 - [int]$bound.Named.ContainsKey('name') - [int]$bound.Named.ContainsKey('value')
                if ($bound.Positional.Count -ne $expected) { $unresolved.Add($anchor); break }
                & $namedCommand (& $valueOf $(if ($bound.Named.ContainsKey('value')) { $bound.Named['value'] } else { $bound.Positional[$expected - 1] })) $anchor
            }
            # Aliases read from a file the walker does not parse.
            { $_ -in @('import-alias', 'ipal') } { $unresolved.Add($anchor) }
            { $_ -in @('set-item', 'si', 'new-item', 'ni') } {
                # An alias defined as an item of the alias: drive, named by a value the walker reads: unresolved (it does
                # not bind these cmdlets' paths and values). Any other item is no edge.
                foreach ($entry in $entries) {
                    $value = $(if ($entry.Attached) { & $valueOf $entry.Attached } elseif (-not $entry.Param -and -not $entry.Splat) { & $valueOf $entry })
                    if ($value.Kind -eq 'path' -and $value.Value -match '(?i)\A\s*alias:') { $unresolved.Add($anchor); break }
                }
            }
        }
    }

    # An alias assigned through its drive (`$alias:go = <value>`, `${alias:go} = ...`): the command it stands for.
    foreach ($assignment in (Get-CiScriptNodes $context AssignmentStatementAst)) {
        $left = $assignment.Left
        while ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
            -not [string]::Equals($left.VariablePath.DriveName, 'alias', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $anchor = ConvertTo-CiScriptAnchor $assignment.Extent.Text
        if ($assignment.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { $unresolved.Add($anchor); continue }
        & $namedCommand (Resolve-CiScriptValue $assignment.Right $context) $anchor
    }

    # Code built from a string at run time: [scriptblock]::Create, InvokeScript, NewScriptBlock, and a PowerShell
    # object's AddScript ([PowerShell]::Create().AddScript(<text>)); and the command a PowerShell object's AddCommand
    # runs. Both are matched by method name on any object, since the walker cannot type a variable that holds one; the
    # PSCommand and pipeline Commands objects' methods of those names run code the same way.
    foreach ($call in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
        if ($call.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $method = $call.Member.Value
        $first = $(if (@($call.Arguments).Count -ge 1) { @($call.Arguments)[0] })
        $callAnchor = ConvertTo-CiScriptAnchor $call.Extent.Text
        if ([string]::Equals($method, 'AddCommand', [StringComparison]::OrdinalIgnoreCase)) {
            & $namedCommand $(if ($first) { Resolve-CiScriptValue $first $context } else { $unresolvedValue }) $callAnchor
            continue
        }
        $create = $call.Static -and $method -ieq 'Create' -and $call.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $call.Expression.TypeName.Name -in @('scriptblock', 'System.Management.Automation.ScriptBlock')
        if (-not $create -and $method -notin @('InvokeScript', 'NewScriptBlock', 'AddScript')) { continue }
        & $codeEdges $first $callAnchor
    }

    # A command line built as a string that runs -File: no AST edge shows its target.
    foreach ($string in @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))) {
        $value = $string.Value
        if ($value -match '(?i)(?:^|\s)-File\s+(?:"|''|\{\d+\}|\$)') { $unresolved.Add((ConvertTo-CiScriptAnchor $value)) }
    }
    return @{ Targets = $targets; Lookups = $lookups; Unresolved = $unresolved; CSharp = $csharp }
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
        # Each target and C# source spelled as the tree spells it, through a listing reader (Opus and CodeRabbit on
        # #740: `Fixtures\x.ps1` and an `Add-Type -Path` source named members the changed paths did not match). A
        # path the listing lacks keeps its spelling.
        foreach ($target in @($found.Targets) + @($found.CSharp)) {
            $spelled = $target
            $lister = $Reader.PSObject.Properties['Lister']
            if ($lister) {
                $cut = $target.LastIndexOf('/')
                $listed = @(& $lister.Value $(if ($cut -ge 0) { $target.Substring(0, $cut) } else { '' }) | Where-Object { [string]::Equals($_, $target, [StringComparison]::OrdinalIgnoreCase) })
                if ($listed.Count -eq 1) { $spelled = $listed[0] }
            }
            $edges.Add([pscustomobject]@{ From = $path; To = $spelled }); $queue.Enqueue($spelled)
        }
        # A path lookup resolves only to a `.ps1` that is the one file it may find; any other lookup fails the walk:
        # a native or batch sibling, with or without a `.ps1`, or none (Find-CiScriptLookupFiles).
        foreach ($base in $found.Lookups) {
            $files = @(Find-CiScriptLookupFiles -Reader $Reader -Base $base)
            if ($files.Count -eq 1 -and [string]::Equals([IO.Path]::GetExtension($files[0]), '.ps1', [StringComparison]::OrdinalIgnoreCase)) {
                $edges.Add([pscustomobject]@{ From = $path; To = $files[0] }); $queue.Enqueue($files[0]); continue
            }
            $detail = $(if ($files.Count -eq 0) { 'finds no .ps1 or PATHEXT file' } else { "may find $($files -join ', ')" })
            $unresolved.Add([pscustomobject]@{ File = $path; Anchor = "path lookup $base" })
            $problems.Add("unresolved path lookup in ${path}: $base ($detail)")
        }
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
