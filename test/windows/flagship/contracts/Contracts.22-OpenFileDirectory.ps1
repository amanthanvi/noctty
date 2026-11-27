# Product file opens keep 0.15's refusal of a directory (ZIG017-OPENFILE-DIR-01 in docs/agents/log/tooling.md;
# council F3 and H1). Zig 0.17.1's `std.Io.Dir.openFile` and `openFileAbsolute` open a directory unless
# `.allow_directory = false`, where 0.15.2's Windows open refused one with `error.IsDir`, and no compile error
# shows the difference. Every read-mode open outside test code under `src/` must pass `.allow_directory = false`,
# but the reviewed sites below: each keeps 0.17's default on purpose, by file and function, with a count, as the
# residue list's "checked, left" rows and the lead's QF3 ruling give them (keep upstream's line where a kind check
# follows the open; such a site pins its check's whole text, and holds only while that text follows the open in
# the same block: council W2 and Y1). The text is matched, not what the check does: a check moved into dead code,
# or made weaker in meaning without a change of text, is code review's. A write-mode open refuses a directory
# anyway. The fork's own `win32_sys.openFile` opens files only by default and is not this API. Only the options
# argument, the call's last, is read (council W3), and it must be one plain struct literal whose top level sets
# `.allow_directory = false` or a write `.mode`, exactly (council Y2): a computed, conditional or unparsed form
# fails, and a real site in one is reviewed below. Any other mention of either name outside test code and `sys.`
# (a quoted identifier, the name as a string or a multi-line string line, a reference without a call) fails too
# (council Y5, AC2), and so does, outside test code, any `\xNN` or `\u{...}` escape that decodes to an identifier
# character (`[A-Za-z0-9_]`), in any literal, quoted identifier or multi-line string line (council AA5, AC2):
# refused, not decoded, and read context free, in the file's own order of literals. A terminal escape such as
# `\x1b` passes. Not refused: a name built at comptime, as `"open" ++ "File"` in an `@field`, which is code
# review's. A new open, or one that loses the option, fails here.

# Blanks comments, multi-line-string lines and string and character literals, keeping the length. With
# -KeepStrings the string and character literals stay as written (a pinned check's text holds its strings).
function Remove-OpenFileNonCode([string] $Text, [switch] $KeepStrings) {
    $pattern = '(?<literal>''(?:\\.|[^''\\\n])''|"(?:\\.|[^"\\\n])*")|//[^\n]*|\\\\[^\n]*'
    $keep = [bool]$KeepStrings
    return [regex]::Replace($Text, $pattern, {
            param($m)
            if ($keep -and $m.Groups['literal'].Success) { return $m.Value }
            return ' ' * $m.Length
        })
}

# The spans of `test` blocks in `$Code`, as start and end offsets.
function Get-OpenFileTestSpans([string] $Code) {
    foreach ($head in [regex]::Matches($Code, '(?m)^[ \t]*test\b[^{\n]*\{')) {
        $depth = 1
        $start = $head.Index + $head.Length
        foreach ($brace in [regex]::new('[{}]').Matches($Code, $start)) {
            if ($brace.Value -eq '{') { $depth++ } else { $depth-- }
            if ($depth -eq 0) { , @($head.Index, $brace.Index); break }
        }
    }
}

# `path:function` for each read-mode open without `.allow_directory = false` outside test code.
function Get-OpenFileDirectoryHits([string] $ZigText, [string] $Path) {
    $mayEscape = $ZigText.Contains('\x') -or $ZigText.Contains('\u{')
    if (-not $ZigText.Contains('openFile') -and -not $mayEscape) { return }
    $code = Remove-OpenFileNonCode $ZigText
    $spans = @(Get-OpenFileTestSpans $code)
    $functions = [regex]::Matches($code, '\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
    $withStrings = $null
    # Every literal in the file's own order (character, string, quoted identifier, multi-line string line), comments
    # skipped, so no earlier text can hide one.
    $literals = [regex]::Matches($ZigText, '''(?:\\(?:x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f]+\}|.)|[^''\\\n])''|"(?:\\.|[^"\\\n])*"|(?<multi>\\\\[^\n]*)|//[^\n]*')
    # Council AA5 and AC2, context free: outside test code, a `\xNN` or `\u{...}` escape that decodes to an
    # identifier character (`[A-Za-z0-9_]`) fails in any literal, a quoted identifier or a multi-line string line
    # included: it could spell either name, and it is refused, not decoded. A terminal escape such as `\x1b`
    # decodes to a control character and passes.
    if ($mayEscape) {
        foreach ($literal in $literals) {
            if ($literal.Value.StartsWith('//')) { continue }
            $spells = $false
            # Every hex digit of a `\u{...}`, as Zig's parser reads them (`lib/std/zig/string_literal.zig:201`), its
            # leading zeros stripped before the bounded conversion (council AD1): `\u{00000041}` is `A`.
            foreach ($e in [regex]::Matches($literal.Value, '(?<!\\)(?:\\\\)*\\(?:x(?<x>[0-9A-Fa-f]{2})|u\{(?<u>[0-9A-Fa-f]+)\})')) {
                $hex = if ($e.Groups['x'].Success) { $e.Groups['x'].Value } else { $e.Groups['u'].Value.TrimStart('0') }
                if ($hex.Length -eq 0) { $hex = '0' }
                if ($hex.Length -gt 6) { continue }
                $cp = [Convert]::ToInt32($hex, 16)
                if ($cp -le 0x7f -and [string][char]$cp -cmatch '^[A-Za-z0-9_]$') { $spells = $true; break }
            }
            if (-not $spells) { continue }
            $inTest = $false
            foreach ($span in $spans) { if ($literal.Index -gt $span[0] -and $literal.Index -lt $span[1]) { $inTest = $true; break } }
            if ($inTest) { continue }
            $name = '(top level)'
            foreach ($function in $functions) { if ($function.Index -lt $literal.Index) { $name = $function.Groups[1].Value } else { break } }
            "${Path}:${name} (an escaped identifier character)"
        }
    }
    if (-not $ZigText.Contains('openFile')) { return }
    # Council Y5: any other mention of either name outside test code and `sys.` (a quoted identifier, the name
    # as a string, a multi-line string line holding it (council AC2), or a reference without a call) is an open the
    # guard cannot read, and fails.
    $mentions = @(
        foreach ($m in [regex]::Matches($code, '\b(openFile|openFileAbsolute)\b(?!\s*\()')) { $m.Index }
        foreach ($literal in $literals) {
            if ($literal.Value -cmatch '^"(?:openFile|openFileAbsolute)"$' -or $literal.Value -cmatch '^\\\\(?:openFile|openFileAbsolute)$') { $literal.Index }
        }
    )
    foreach ($at in $mentions) {
        $lead = $code.Substring([Math]::Max(0, $at - 16), [Math]::Min(16, $at))
        if ($lead -match '\b(?:win32_)?sys\s*\.\s*@?$') { continue }
        $inTest = $false
        foreach ($span in $spans) { if ($at -gt $span[0] -and $at -lt $span[1]) { $inTest = $true; break } }
        if ($inTest) { continue }
        $name = '(top level)'
        foreach ($function in $functions) { if ($function.Index -lt $at) { $name = $function.Groups[1].Value } else { break } }
        "${Path}:${name} (a mention that is no direct call)"
    }
    $calls = [regex]::Matches($code, '\.\s*(openFile|openFileAbsolute)\s*\(')
    if ($calls.Count -eq 0) { return }
    foreach ($call in $calls) {
        $lead = $code.Substring([Math]::Max(0, $call.Index - 16), [Math]::Min(16, $call.Index))
        if ($lead -match '\b(?:win32_)?sys\s*$') { continue }
        $inTest = $false
        foreach ($span in $spans) { if ($call.Index -gt $span[0] -and $call.Index -lt $span[1]) { $inTest = $true; break } }
        if ($inTest) { continue }
        # The call's arguments, to its closing parenthesis.
        $depth = 1
        $open = $call.Index + $call.Length
        $callArgs = $null
        $callEnd = -1
        foreach ($paren in [regex]::new('[()]').Matches($code, $open)) {
            if ($paren.Value -eq '(') { $depth++ } else { $depth--; if ($depth -eq 0) { $callArgs = $code.Substring($open, $paren.Index - $open); $callEnd = $paren.Index; break } }
        }
        if ($null -eq $callArgs) { continue }
        # Only the last top-level argument, the options, counts: a struct inside the path argument says
        # nothing about the open (council W3).
        $options = Get-OpenFileLastArgument $callArgs
        if (Test-OpenFileOptionsRefuseDirectory $options) { continue }
        $name = '(top level)'
        $nameAt = 0
        foreach ($function in $functions) { if ($function.Index -lt $call.Index) { $name = $function.Groups[1].Value; $nameAt = $function.Index } else { break } }
        # A site reviewed for the kind check that follows its open holds only while that check's whole pinned
        # text is still there, after the open and in the block that holds it (council W2 and Y1).
        $site = "${Path}:${name}"
        $reviewed = @($script:OpenFileDirectoryReviewed | Where-Object { $_['Site'] -ceq $site -and $_['Check'] })
        if ($reviewed.Length -eq 1) {
            if ($null -eq $withStrings) { $withStrings = Remove-OpenFileNonCode $ZigText -KeepStrings }
            if (-not (Test-OpenFileKindCheck -Code $withStrings -After $callEnd -Check $reviewed[0]['Check'])) {
                $site += ' (its pinned kind check is not after the open)'
            }
        }
        # A site reviewed for the branch that comes before its open holds only while that branch's whole pinned
        # text ends at the open, in the same function (council AB1).
        $before = @($script:OpenFileDirectoryReviewed | Where-Object { $_['Site'] -ceq $site -and $_['Before'] })
        if ($before.Length -eq 1) {
            if ($null -eq $withStrings) { $withStrings = Remove-OpenFileNonCode $ZigText -KeepStrings }
            if (-not (Test-OpenFilePinnedText -Code $withStrings -Blank $code -Start $nameAt -End $call.Index -Text $before[0]['Before'] -AtEnd)) {
                $site += ' (its pinned branch is not before the open)'
            }
        }
        $site
    }
}

# The last top-level argument of `$CallArgs` (a call's arguments, strings blanked), a trailing comma skipped.
function Get-OpenFileLastArgument([string] $CallArgs) {
    $depth = 0
    $starts = [System.Collections.Generic.List[int]]::new()
    $starts.Add(0)
    foreach ($d in [regex]::new('[()\[\]{},]').Matches($CallArgs)) {
        $c = $d.Value
        if ($c -eq ',') { if ($depth -eq 0) { $starts.Add($d.Index + 1) } }
        elseif ($c -eq '(' -or $c -eq '[' -or $c -eq '{') { $depth++ }
        else { $depth-- }
    }
    for ($i = $starts.Count - 1; $i -ge 0; $i--) {
        $end = if ($i + 1 -lt $starts.Count) { $starts[$i + 1] - 1 } else { $CallArgs.Length }
        $piece = $CallArgs.Substring($starts[$i], $end - $starts[$i])
        if ($piece.Trim().Length -gt 0) { return $piece }
    }
    return ''
}

# Whether `$Options`, an open's options argument (strings blanked), is one plain struct literal, `.{ ... }`, whose
# top level holds `.allow_directory = false` or `.mode` set to a write mode, each value exactly that. Anything
# else reads as an open that may accept a directory (council Y2): a computed or conditional value or argument,
# `. {`, a field the guard cannot parse, or the field inside a nested literal. A real site in such a form is
# reviewed below.
function Test-OpenFileOptionsRefuseDirectory([string] $Options) {
    $text = $Options.Trim()
    if (-not $text.StartsWith('.{') -or -not $text.EndsWith('}')) { return $false }
    # The literal's own brace must close at its end: `.{ } orelse .{ ... }` is two expressions.
    $depth = 0
    foreach ($d in [regex]::new('[()\[\]{}]').Matches($text, 1)) {
        if ('([{'.Contains($d.Value)) { $depth++ } else { $depth--; if ($depth -eq 0 -and $d.Index -ne $text.Length - 1) { return $false } }
    }
    $inner = $text.Substring(2, $text.Length - 3)
    $fields = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    $start = 0
    foreach ($d in [regex]::new('[()\[\]{},]').Matches($inner)) {
        $c = $d.Value
        if ($c -eq ',') { if ($depth -eq 0) { $fields.Add($inner.Substring($start, $d.Index - $start)); $start = $d.Index + 1 } }
        elseif ('([{'.Contains($c)) { $depth++ }
        else { $depth-- }
    }
    $fields.Add($inner.Substring($start))
    $refuses = $false
    foreach ($field in $fields) {
        if ($field.Trim().Length -eq 0) { continue }
        $m = [regex]::Match($field, '^\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\S(?:.*\S)?)\s*$', 'Singleline')
        if (-not $m.Success) { return $false }
        $value = [regex]::Replace($m.Groups[2].Value, '\s+', ' ')
        if ($m.Groups[1].Value -ceq 'allow_directory' -and $value -ceq 'false') { $refuses = $true }
        if ($m.Groups[1].Value -ceq 'mode' -and ($value -ceq '.write_only' -or $value -ceq '.read_write')) { $refuses = $true }
    }
    return $refuses
}

# Whether `$Check`, a check's whole text with its whitespace normalized (each run one space), appears in `$Code`
# (comments blanked, strings kept) after offset `$After` and before the end of the block that holds it, its
# whitespace normalized the same way: the text is matched, not what the check does (council Y1).
function Test-OpenFileKindCheck([string] $Code, [int] $After, [string] $Check) {
    $end = $Code.Length
    $depth = 0
    $blank = Remove-OpenFileNonCode $Code
    foreach ($brace in [regex]::new('[{}]').Matches($blank, $After)) {
        if ($brace.Value -eq '{') { $depth++ } elseif ($depth -eq 0) { $end = $brace.Index; break } else { $depth-- }
    }
    return Test-OpenFilePinnedText -Code $Code -Blank $blank -Start $After -End $end -Text $Check
}

# Whether `$Text`, a pinned text with its whitespace normalized (each space matching any run of whitespace), is in
# `$Code` (comments blanked, strings kept) between `$Start` and `$End`, starting at a code token: its first token
# must be there in `$Blank` (strings blanked too), so the same text inside a string does not count (council AA3).
function Test-OpenFilePinnedText([string] $Code, [string] $Blank, [int] $Start, [int] $End, [string] $Text, [switch] $AtEnd) {
    # With -AtEnd the text must end where the region does, at the open itself (council AB1).
    $pattern = '(?<![\w.])' + [regex]::Escape($Text).Replace('\ ', '\s+') + $(if ($AtEnd) { '\s*$' } else { '' })
    $lead = [regex]::Match($Text, '^\S+').Value.Length
    foreach ($m in [regex]::new($pattern).Matches($Code.Substring($Start, $End - $Start))) {
        $at = $Start + $m.Index
        if ([string]::Equals($Blank.Substring($at, $lead), $Code.Substring($at, $lead), [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

# The reviewed read-mode opens that keep 0.17's default, each `path:function` with how many it holds and why.
$script:OpenFileDirectoryReviewed = @(
    # A kind check follows the open (the lead's QF3 ruling: keep upstream's line), pinned as `Check`, its whole
    # text with whitespace normalized: the site holds only while that text follows its open (council W2, Y1).
    @{ Site = 'src/os/path.zig:expand'; Opens = 1; Why = 'QF3-1: its stat skips a directory and the search goes on'
        Check = 'if (stat.kind != .directory and isExecutable(stat.permissions)) {' }
    @{ Site = 'src/config/file_load.zig:open'; Opens = 1; Why = 'QF3-2: its stat gives NotAFile, which loadFile logs and skips'
        Check = 'switch (stat.kind) { .file => {}, else => return OpenFileError.NotAFile, }' }
    @{ Site = 'src/config/Config.zig:loadRecursiveFiles'; Opens = 1; Why = 'its stat reports the file type and skips it'
        Check = 'switch (stat.kind) { .file => {}, else => |kind| { const diag: cli.Diagnostic = .{ .message = try arena_alloc.printSentinel( "config-file {s}: not reading because file type is {s}", .{ path, @tagName(kind) }, 0, ), }; try self._diagnostics.append(arena_alloc, diag); try self._replay_steps.append(arena_alloc, .{ .diagnostic = diag }); continue; }, }' }
    # Not Windows code (residue: checked, left).
    @{ Site = 'src/os/cgroup.zig:current'; Opens = 1; Why = 'a Linux /proc read, where 0.15 opened a directory too' }
    @{ Site = 'src/os/kernel_info.zig:getKernelInfo'; Opens = 1; Why = 'a Linux /proc read' }
    @{ Site = 'src/os/systemd.zig:launchedBySystemd'; Opens = 1; Why = 'a Linux /proc read' }
    # The Windows branch that keeps Windows off this open is pinned as `Before`, its whole text ending at the open
    # (council AB1).
    @{ Site = 'src/terminal/kitty/graphics_image.zig:readFile'; Opens = 1; Why = 'the non-Windows branch; on Windows the open goes through local_path.open'
        Before = 'if (comptime builtin.target.os.tag == .windows) switch (try local_path.open(alloc, path, .{ .data = true })) { .found => |found| hit: { alloc.free(found.path); break :hit found.file; }, else => |opened| { log.warn("failed to open image file: {t}", .{opened}); return error.InvalidData; }, } else std.Io.Dir.cwd()' }
    # An escaped identifier character in product code (council AC2), the tree's only one: test_wsl_cases' raw
    # UTF-16LE bytes "\x41\x41\x0A", test data at the top level that only tests read. Its site names the function
    # before it in the file, as the line heuristic does.
    @{ Site = 'src/config/windows_shell.zig:testOneRegistered (an escaped identifier character)'; Opens = 1; Why = 'test_wsl_cases raw bytes, read only by tests' }
    # Test-only helpers outside a `test` block (they open with std.testing.io or only tests call them).
    @{ Site = 'src/apprt/win32/app.zig:read'; Opens = 1; Why = 'a test fixture struct''s reader (std.testing.io)' }
    @{ Site = 'src/apprt/win32/sys.zig:expectFinalPathAsOpened'; Opens = 1; Why = 'the final-path test''s helper' }
    @{ Site = 'src/font/glyf_rasterize_png_test.zig:diffAtlas'; Opens = 2; Why = 'a test file''s atlas comparison' }
    @{ Site = 'src/font/sprite/Face.zig:testDiffAtlas'; Opens = 2; Why = 'the sprite tests'' atlas comparison' }
)

# Every `src/` file's hits, read once: `path` to its `path:function` list.
function Get-OpenFileDirectoryAllHits([string] $Root) {
    $all = @{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Recurse -File -Filter '*.zig') {
        $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace([char]92, [char]47)
        $all[$relative] = @(Get-OpenFileDirectoryHits -ZigText ([System.IO.File]::ReadAllText($file.FullName)) -Path $relative)
    }
    return $all
}

function Get-OpenFileDirectoryProblems([hashtable] $HitsByFile) {
    $counts = @{}
    foreach ($hits in $HitsByFile.Values) {
        foreach ($hit in $hits) { $counts[$hit] = 1 + $(if ($counts.ContainsKey($hit)) { $counts[$hit] } else { 0 }) }
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    # A reviewed site that no longer holds its count is stale: the list stays exact.
    foreach ($reviewed in $script:OpenFileDirectoryReviewed) {
        $held = if ($counts.ContainsKey($reviewed['Site'])) { $counts[$reviewed['Site']] } else { 0 }
        if ($held -lt $reviewed['Opens']) { $problems.Add("$($reviewed['Site']) is reviewed for $($reviewed['Opens']) opens and holds $held") }
    }
    foreach ($site in @($counts.Keys | Sort-Object)) {
        $reviewed = @($script:OpenFileDirectoryReviewed | Where-Object { $_['Site'] -ceq $site })
        $allowed = if ($reviewed.Length -eq 1) { $reviewed[0]['Opens'] } else { 0 }
        if ($counts[$site] -gt $allowed) { $problems.Add("$site opens without .allow_directory = false ($($counts[$site]), reviewed $allowed)") }
    }
    return , $problems.ToArray()
}

$openFileHits = Get-OpenFileDirectoryAllHits -Root $repoRoot
$openFileProblems = Get-OpenFileDirectoryProblems -HitsByFile $openFileHits
if ($openFileProblems.Length -ne 0) {
    throw "A product file open accepts a directory (ZIG017-OPENFILE-DIR-01: pass .allow_directory = false, or review it here): $($openFileProblems -join '; ')"
}

# Controls: the option removed from one product site fails; a test block's open, a write-mode open and the
# fork's own win32_sys.openFile do not.
$openFileControls = 0
$ptyPath = 'src/pty.zig'
$ptyText = Get-Content -LiteralPath (Join-Path $repoRoot $ptyPath) -Raw
$ptyMutant = $ptyText.Replace('var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false });', 'var file = try std.Io.Dir.openFileAbsolute(io, path, .{});')
if ([string]::Equals($ptyMutant, $ptyText, [StringComparison]::Ordinal)) { throw 'The open-file directory control changed nothing in pty.zig.' }
$mutantHits = @{} + $openFileHits
$mutantHits[$ptyPath] = @(Get-OpenFileDirectoryHits -ZigText $ptyMutant -Path $ptyPath)
$mutantProblems = Get-OpenFileDirectoryProblems -HitsByFile $mutantHits
if ($mutantProblems -cnotcontains 'src/pty.zig:openConsoleMatchesArchitecture opens without .allow_directory = false (1, reviewed 0)') {
    throw 'The open-file directory check passed a product open that lost .allow_directory = false.'
}
$openFileControls++
# Council W2: each kind-check site, its check removed, fails.
function Remove-OpenFileSwitch([string] $Text, [string] $Function) {
    $at = $Text.IndexOf('switch (stat.kind) {', $Text.IndexOf("fn $Function("))
    if ($at -lt 0) { return $Text }
    $depth = 0
    foreach ($brace in [regex]::new('[{}]').Matches($Text, $at)) {
        if ($brace.Value -eq '{') { $depth++ } else { $depth--; if ($depth -eq 0) { return $Text.Remove($at, $brace.Index + 1 - $at) } }
    }
    return $Text
}
foreach ($kindControl in @(
        @{ Path = 'src/os/path.zig'; Function = 'expand'; Mutate = { param($t) $t.Replace('if (stat.kind != .directory and isExecutable(stat.permissions)) {', 'if (isExecutable(stat.permissions)) {') } }
        @{ Path = 'src/config/file_load.zig'; Function = 'open'; Mutate = { param($t) Remove-OpenFileSwitch $t 'open' } }
        @{ Path = 'src/config/Config.zig'; Function = 'loadRecursiveFiles'; Mutate = { param($t) Remove-OpenFileSwitch $t 'loadRecursiveFiles' } }
        # Council AA3: the real check removed, its old text kept in a string after the open.
        @{ Path = 'src/os/path.zig'; Function = 'expand'; Mutate = { param($t) $t.Replace('if (stat.kind != .directory and isExecutable(stat.permissions)) {', 'const old = "if (stat.kind != .directory and isExecutable(stat.permissions)) {"; _ = old; if (isExecutable(stat.permissions)) {') } }
        # Council Y1: each check weakened in its text.
        @{ Path = 'src/os/path.zig'; Function = 'expand'; Mutate = { param($t) $t.Replace('if (stat.kind != .directory and isExecutable(stat.permissions)) {', 'if (stat.kind != .directory or isExecutable(stat.permissions)) {') } }
        @{ Path = 'src/config/file_load.zig'; Function = 'open'; Mutate = { param($t) $t.Replace("    switch (stat.kind) {`n        .file => {},`n", "    switch (stat.kind) {`n        .file => {},`n        .directory => {},`n") } }
        @{ Path = 'src/config/Config.zig'; Function = 'loadRecursiveFiles'; Mutate = { param($t) $t.Replace("        switch (stat.kind) {`n            .file => {},`n            else => |kind| {", "        switch (stat.kind) {`n            .file, .directory => {},`n            else => |kind| {") } }
    )) {
    $kindPath = $kindControl['Path']
    $kindText = (Get-Content -LiteralPath (Join-Path $repoRoot $kindPath) -Raw).Replace("`r`n", "`n")
    $kindMutant = & $kindControl['Mutate'] $kindText
    if ([string]::Equals($kindMutant, $kindText, [StringComparison]::Ordinal)) { throw "The kind-check control changed nothing in $kindPath." }
    $kindHits = @{} + $openFileHits
    $kindHits[$kindPath] = @(Get-OpenFileDirectoryHits -ZigText $kindMutant -Path $kindPath)
    $site = @($script:OpenFileDirectoryReviewed | Where-Object { $_['Site'] -ceq "${kindPath}:$($kindControl['Function'])" })[0]
    $want = "$($site['Site']) (its pinned kind check is not after the open) opens without .allow_directory = false (1, reviewed 0)"
    if ((Get-OpenFileDirectoryProblems -HitsByFile $kindHits) -cnotcontains $want) {
        throw "The open-file directory check kept $($site['Site']) reviewed after its kind check was removed or weakened."
    }
    $openFileControls++
}
# Council AB1: the kitty open's Windows branch removed, so the plain open runs on Windows too, fails.
$kittyPath = 'src/terminal/kitty/graphics_image.zig'
$kittyText = (Get-Content -LiteralPath (Join-Path $repoRoot $kittyPath) -Raw).Replace("`r`n", "`n")
$kittyMutant = [regex]::new('(?s)if \(comptime builtin\.target\.os\.tag == \.windows\) switch \(try local_path\.open\(.*?\} else (std\.Io\.Dir\.cwd\(\)\.openFile\()').Replace($kittyText, '$1', 1)
if ([string]::Equals($kittyMutant, $kittyText, [StringComparison]::Ordinal)) { throw 'The kitty branch control changed nothing.' }
$kittyHits = @{} + $openFileHits
$kittyHits[$kittyPath] = @(Get-OpenFileDirectoryHits -ZigText $kittyMutant -Path $kittyPath)
if ((Get-OpenFileDirectoryProblems -HitsByFile $kittyHits) -cnotcontains "${kittyPath}:readFile (its pinned branch is not before the open) opens without .allow_directory = false (1, reviewed 0)") {
    throw 'The open-file directory check kept the kitty open reviewed after its Windows branch was removed.'
}
$openFileControls++
# Council AC3: the pinned open takes .allow_directory = false and a plain open follows it in readFile; the pinned
# branch ends at the first open, not the second, so the second is refused (-AtEnd).
$kittyOpen = "        } else std.Io.Dir.cwd().openFile(`n            io,`n            path,`n            .{},`n        ) catch |err| {`n            log.warn(`"failed to open image file: {}`", .{err});`n            return error.InvalidData;`n        };`n"
$kittyFollowed = $kittyOpen.Replace("            .{},`n", "            .{ .allow_directory = false },`n") + "        var plain = try std.Io.Dir.cwd().openFile(io, path, .{});`n        plain.close(io);`n"
$kittyAtEnd = $kittyText.Replace($kittyOpen, $kittyFollowed)
if ([string]::Equals($kittyAtEnd, $kittyText, [StringComparison]::Ordinal)) { throw 'The kitty -AtEnd control changed nothing.' }
$kittyHits = @{} + $openFileHits
$kittyHits[$kittyPath] = @(Get-OpenFileDirectoryHits -ZigText $kittyAtEnd -Path $kittyPath)
if ((Get-OpenFileDirectoryProblems -HitsByFile $kittyHits) -cnotcontains "${kittyPath}:readFile (its pinned branch is not before the open) opens without .allow_directory = false (1, reviewed 0)") {
    throw 'The open-file directory check let a plain open after the kitty open pass on its pinned branch.'
}
$openFileControls++
foreach ($sample in @(
        @{ Text = "test `"t`" {`n    const f = try dir.openFile(io, `"x`", .{});`n}`n"; Hits = 0 }
        @{ Text = "fn w() !void {`n    const f = try dir.openFile(io, `"x`", .{ .mode = .write_only });`n}`n"; Hits = 0 }
        @{ Text = "fn s() !void {`n    const h = try win32_sys.openFile(name, .{});`n}`n"; Hits = 0 }
        @{ Text = "fn r() !void {`n    // dir.openFile(io, `"x`", .{})`n    const f = try dir.openFile(io, `"x`", .{ .mode = .read_only });`n}`n"; Hits = 1 }
        # Council W3: a misleading field inside the path argument; the options still decide, trailing comma or not.
        @{ Text = "fn m() !void {`n    const f = try dir.openFile(io, pick(.{ .mode = .read_write }), .{});`n}`n"; Hits = 1 }
        @{ Text = "fn a() !void {`n    const f = try dir.openFile(io, pick(.{ .allow_directory = false }), .{});`n}`n"; Hits = 1 }
        @{ Text = "fn t() !void {`n    const f = try dir.openFile(`n        io,`n        pick(.{ .x = 1 }),`n        .{ .allow_directory = false },`n    );`n}`n"; Hits = 0 }
        # Council Y2: options the guard cannot read as refusing a directory fail; a plain literal passes.
        @{ Text = "fn c() !void {`n    const f = try dir.openFile(io, `"x`", .{ .allow_directory = false or x });`n}`n"; Hits = 1 }
        @{ Text = "fn k() !void {`n    const f = try dir.openFile(io, `"x`", if (c) .{ .mode = .read_write } else .{});`n}`n"; Hits = 1 }
        @{ Text = "fn s() !void {`n    const f = try dir.openFile(io, `"x`", . { .allow_directory = false });`n}`n"; Hits = 1 }
        @{ Text = "fn n() !void {`n    const f = try dir.openFile(io, `"x`", .{ .lock = .{ .allow_directory = false } });`n}`n"; Hits = 1 }
        @{ Text = "fn u() !void {`n    const f = try dir.openFile(io, `"x`", .{ .allow_directory = false, extra });`n}`n"; Hits = 1 }
        @{ Text = "fn v() !void {`n    const f = try dir.openFile(io, `"x`", options);`n}`n"; Hits = 1 }
        @{ Text = "fn p() !void {`n    const f = try dir.openFile(io, `"x`", .{ .mode = .read_only, .allow_directory = false });`n}`n"; Hits = 0 }
        # Council Y5: a quoted identifier, the name as a string and a reference without a call each fail; the
        # fork's sys reference and a test block's do not.
        @{ Text = "fn q() !void {`n    const f = try dir.@`"openFile`"(io, `"x`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn r() !void {`n    const f = try @field(std.Io.Dir, `"openFile`")(dir, io, `"x`", .{});`n}`n"; Hits = 1 }
        @{ Text = "const open = std.Io.Dir.openFileAbsolute;`n"; Hits = 1 }
        @{ Text = "const open = win32_sys.openFile;`n"; Hits = 0 }
        @{ Text = "test `"t`" {`n    const open = std.Io.Dir.openFile;`n}`n"; Hits = 0 }
        # Council AA5 and AC2: an escape that decodes to an identifier character fails in any literal outside test
        # code; a terminal escape, or one in a test block, does not.
        @{ Text = "fn e1() !void {`n    const f = try dir.@`"open\x46ile`"(io, `"x`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn e2() !void {`n    const f = try dir.@`"open\u{46}ile`"(io, `"x`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn e3() !void {`n    const f = try @field(std.Io.Dir, `"open\x46ile`")(dir, io, `"x`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn e4() void {`n    log.info(`"\x41`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn e5() void {`n    log.info(`"\x1b[0m`", .{});`n}`n"; Hits = 0 }
        @{ Text = "test `"t`" {`n    const f = try dir.@`"open\x46ile`"(io, `"x`", .{});`n}`n"; Hits = 0 }
        # Council AC2: deeper nesting in @field's first argument, an earlier "@" string on the line, a multi-line
        # string as @field's name, and a parenthesized name.
        @{ Text = "fn n1() !void {`n    const f = try @field(@TypeOf(std.Io.Dir.cwd()), `"open\x46ile`")(dir, io, `"x`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn n2() !void {`n    const marker = `"@`"; const f = try dir.@`"open\x46ile`"(io, `"x`", .{}); _ = marker;`n}`n"; Hits = 1 }
        @{ Text = "fn n3() !void {`n    const f = try @field(std.Io.Dir,`n        \\openFile`n    )(dir, io, `"x`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn n4() !void {`n    const f = try @field(std.Io.Dir, (`"openFile`"))(dir, io, `"x`", .{});`n}`n"; Hits = 1 }
        # Council AD1: a \u{...} with more than six hex digits, leading zeros, still decodes; an escaped backslash
        # and a terminal control character in that form pass.
        @{ Text = "fn z1() void {`n    log.info(`"\u{00000041}`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn z2() !void {`n    const f = try dir.@`"open\u{0000046}ile`"(io, `"x`", .{});`n}`n"; Hits = 1 }
        @{ Text = "fn z3() void {`n    log.info(`"\\u{00000041}`", .{});`n}`n"; Hits = 0 }
        @{ Text = "fn z4() void {`n    log.info(`"\u{0000001b}`", .{});`n}`n"; Hits = 0 }
    )) {
    if (@(Get-OpenFileDirectoryHits -ZigText $sample.Text -Path 'control.zig').Count -ne $sample.Hits) {
        throw "The open-file directory check miscounted a control: $($sample.Text)"
    }
    $openFileControls++
}
Write-Host "Product file opens: every read-mode open refuses a directory but $(@($script:OpenFileDirectoryReviewed).Length) reviewed sites; $openFileControls controls"
