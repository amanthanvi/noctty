# Product file opens keep 0.15's refusal of a directory (ZIG017-OPENFILE-DIR-01 in docs/agents/log/tooling.md;
# council F3 and H1). Zig 0.17.1's `std.Io.Dir.openFile` and `openFileAbsolute` open a directory unless
# `.allow_directory = false`, where 0.15.2's Windows open refused one with `error.IsDir`, and no compile error
# shows the difference. Every read-mode open outside test code under `src/` must pass `.allow_directory = false`,
# but the reviewed sites below: each keeps 0.17's default on purpose, by file and function, with a count, as the
# residue list's "checked, left" rows and the lead's QF3 ruling give them (keep upstream's line where a kind check
# follows the open; such a site names its check, and holds only while the check follows the open in the same
# block: council W2). A write-mode open refuses a directory anyway. The fork's own `win32_sys.openFile` opens files
# only by default and is not this API. A new open, or one that loses the option, fails here.

# Blanks comments, multi-line-string lines and string and character literals, keeping the length.
function Remove-OpenFileNonCode([string] $Text) {
    $pattern = '''(?:\\.|[^''\\\n])''|"(?:\\.|[^"\\\n])*"|//[^\n]*|\\\\[^\n]*'
    return [regex]::Replace($Text, $pattern, { param($m) ' ' * $m.Length })
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
    if (-not $ZigText.Contains('openFile')) { return }
    $code = Remove-OpenFileNonCode $ZigText
    $calls = [regex]::Matches($code, '\.\s*(openFile|openFileAbsolute)\s*\(')
    if ($calls.Count -eq 0) { return }
    $spans = @(Get-OpenFileTestSpans $code)
    $functions = [regex]::Matches($code, '\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
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
        if ($callArgs -match '\ballow_directory\s*=\s*false\b') { continue }
        if ($callArgs -match '\.mode\s*=\s*\.(?:write_only|read_write)\b') { continue }
        $name = '(top level)'
        foreach ($function in $functions) { if ($function.Index -lt $call.Index) { $name = $function.Groups[1].Value } else { break } }
        # A site reviewed for the kind check that follows its open holds only while that check is still there,
        # after the open and in the block that holds it (council W2).
        $site = "${Path}:${name}"
        $reviewed = @($script:OpenFileDirectoryReviewed | Where-Object { $_['Site'] -ceq $site -and $_['Check'] })
        if ($reviewed.Length -eq 1 -and -not (Test-OpenFileKindCheck -Code $code -After $callEnd -Check $reviewed[0]['Check'])) {
            $site += " (no $($reviewed[0]['Check']) after the open)"
        }
        $site
    }
}

# Whether `$Check` (its spaces read as any whitespace) appears in `$Code` after offset `$After` and before the
# end of the block that holds it.
function Test-OpenFileKindCheck([string] $Code, [int] $After, [string] $Check) {
    $end = $Code.Length
    $depth = 0
    foreach ($brace in [regex]::new('[{}]').Matches($Code, $After)) {
        if ($brace.Value -eq '{') { $depth++ } elseif ($depth -eq 0) { $end = $brace.Index; break } else { $depth-- }
    }
    $pattern = '(?<![\w.])' + [regex]::Escape($Check).Replace('\ ', '\s*')
    return [regex]::new($pattern).Match($Code.Substring($After, $end - $After)).Success
}

# The reviewed read-mode opens that keep 0.17's default, each `path:function` with how many it holds and why.
$script:OpenFileDirectoryReviewed = @(
    # A kind check follows the open (the lead's QF3 ruling: keep upstream's line), named as `Check`: the site
    # holds only while that check follows its open (council W2).
    @{ Site = 'src/os/path.zig:expand'; Opens = 1; Check = 'stat.kind != .directory'; Why = 'QF3-1: its stat skips a directory and the search goes on' }
    @{ Site = 'src/config/file_load.zig:open'; Opens = 1; Check = 'switch (stat.kind)'; Why = 'QF3-2: its stat gives NotAFile, which loadFile logs and skips' }
    @{ Site = 'src/config/Config.zig:loadRecursiveFiles'; Opens = 1; Check = 'switch (stat.kind)'; Why = 'its stat reports the file type and skips it' }
    # Not Windows code (residue: checked, left).
    @{ Site = 'src/os/cgroup.zig:current'; Opens = 1; Why = 'a Linux /proc read, where 0.15 opened a directory too' }
    @{ Site = 'src/os/kernel_info.zig:getKernelInfo'; Opens = 1; Why = 'a Linux /proc read' }
    @{ Site = 'src/os/systemd.zig:launchedBySystemd'; Opens = 1; Why = 'a Linux /proc read' }
    @{ Site = 'src/terminal/kitty/graphics_image.zig:readFile'; Opens = 1; Why = 'the non-Windows branch; on Windows the open goes through local_path.open' }
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
    )) {
    $kindPath = $kindControl['Path']
    $kindText = Get-Content -LiteralPath (Join-Path $repoRoot $kindPath) -Raw
    $kindMutant = & $kindControl['Mutate'] $kindText
    if ([string]::Equals($kindMutant, $kindText, [StringComparison]::Ordinal)) { throw "The kind-check control changed nothing in $kindPath." }
    $kindHits = @{} + $openFileHits
    $kindHits[$kindPath] = @(Get-OpenFileDirectoryHits -ZigText $kindMutant -Path $kindPath)
    $site = @($script:OpenFileDirectoryReviewed | Where-Object { $_['Site'] -ceq "${kindPath}:$($kindControl['Function'])" })[0]
    $want = "$($site['Site']) (no $($site['Check']) after the open) opens without .allow_directory = false (1, reviewed 0)"
    if ((Get-OpenFileDirectoryProblems -HitsByFile $kindHits) -cnotcontains $want) {
        throw "The open-file directory check kept $($site['Site']) reviewed after its kind check was removed."
    }
    $openFileControls++
}
foreach ($sample in @(
        @{ Text = "test `"t`" {`n    const f = try dir.openFile(io, `"x`", .{});`n}`n"; Hits = 0 }
        @{ Text = "fn w() !void {`n    const f = try dir.openFile(io, `"x`", .{ .mode = .write_only });`n}`n"; Hits = 0 }
        @{ Text = "fn s() !void {`n    const h = try win32_sys.openFile(name, .{});`n}`n"; Hits = 0 }
        @{ Text = "fn r() !void {`n    // dir.openFile(io, `"x`", .{})`n    const f = try dir.openFile(io, `"x`", .{ .mode = .read_only });`n}`n"; Hits = 1 }
    )) {
    if (@(Get-OpenFileDirectoryHits -ZigText $sample.Text -Path 'control.zig').Count -ne $sample.Hits) {
        throw "The open-file directory check miscounted a control: $($sample.Text)"
    }
    $openFileControls++
}
Write-Host "Product file opens: every read-mode open refuses a directory but $(@($script:OpenFileDirectoryReviewed).Length) reviewed sites; $openFileControls controls"
