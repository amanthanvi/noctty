# No build file copies the configurer's environment into a Run step (ZIG017-RUN-ENV-01 in
# docs/agents/log/build-release-ci.md). On Zig 0.17 the first variable a Run step sets clones
# `b.graph.environ_map` into the step, and the configure process writes every step, that copy
# included, into the cached build configuration under `.zig-cache`. A later upstream merge must not
# bring such a call back silently: any mention of these Run members, or any other mention of an
# `environ_map` field, in the code of a build file fails here. The build files are `build.zig`, every
# `pkg/` build file, every file their local `@import` graph reaches (council F1: a helper the build
# script imports, however it names std), and every other Zig file under `src/` or `pkg/` that names
# `std.Build` (`src/build/`, `src/differential_oracle_build.zig`, `pkg/apple-sdk/native_link.zig`).
# Allowed, and nothing else (council F10): the graph's own map (`b.graph.environ_map`), an options
# field in a struct literal (`.{ .environ_map = &env }`, a host tool's `std.process.run`), the name in
# `@hasField(..., "environ_map")`, and a host tool's own process environment (`init.environ_map` in a
# file whose `main` takes `init: std.process.Init`, inside that `main`). The dependencies' own build
# scripts configure in the same process; CI's sentinel step (windows-lib-vt,
# scripts/check-configure-environment.ps1) covers them end to end.
#
# A known limit (council H3): a whole Run written as a struct literal, `run.* = .{ ..., .environ_map =
# &env }`, reads as an options field and passes. Nothing in the tree writes a step that way.

# Blanks every Zig comment, multi-line-string line, string literal and character literal, keeping
# the length, so a hit is code. A quoted identifier (`@"name"`) keeps its name, so
# `run.@"setEnvironmentVariable"(...)` is still seen.
function Remove-BuildEnvironmentNonCode([string] $Text, [switch] $KeepStrings) {
    $named = [regex]::Replace($Text, '@"([A-Za-z_][A-Za-z0-9_]*)"', { param($m) ' ' + $m.Groups[1].Value + '  ' })
    # One pass over the literals and the comments, so a `//` inside a string is the string's (council G2:
    # an `@import` after a URL string on the same line was blanked as a comment). With -KeepStrings the
    # string and character literals stay as written.
    $pattern = '(?<literal>''(?:\\.|[^''\\\n])''|"(?:\\.|[^"\\\n])*")|//[^\n]*|\\\\[^\n]*'
    $keep = [bool]$KeepStrings
    return [regex]::Replace($named, $pattern, {
            param($m)
            if ($keep -and $m.Groups['literal'].Success) { return $m.Value }
            return ' ' * $m.Length
        })
}

# The Run step members that reach the step's environment map (`lib/std/Build/Step/Run.zig`:
# setEnvironmentVariable, removeEnvironmentVariable and getEnvMap clone the graph's map,
# clearEnvironment replaces it), named in any way (a call, a reference called later, `@call`, or a
# string, as `@field(Run, "setEnvironmentVariable")` names one: council H3, so these read the
# strings-kept text); any mention of an `environ_map` field but the allowed ones, however the receiver
# is spelled (a write, a read, an address taken for a later write or a swap); the field named as a
# string, but in `@hasField`; and a `@field` write whose field name is not a literal, which could be
# `environ_map`.
$script:BuildEnvironmentCopyForms = @(
    @{ Name = 'setEnvironmentVariable'; Pattern = '\bsetEnvironmentVariable\b'; KeepStrings = $true }
    @{ Name = 'removeEnvironmentVariable'; Pattern = '\bremoveEnvironmentVariable\b'; KeepStrings = $true }
    @{ Name = 'getEnvMap'; Pattern = '\bgetEnvMap\b'; KeepStrings = $true }
    @{ Name = 'clearEnvironment'; Pattern = '\bclearEnvironment\b'; KeepStrings = $true }
    # An options field in a struct literal (`{` or `,` before it, an `=` after it, not `==`) passes; a
    # `setField(run, .environ_map, &env)` argument does not (council H3).
    @{ Name = 'environ_map mention'; Pattern = '(?<!\bgraph\s*)\.\s*environ_map\b(?!\s*:)'; HostInit = $true; OptionsField = $true }
    @{ Name = 'environ_map named'; Pattern = '(?<!@hasField\s*\([^()]*(?:\([^()]*\))?[^()]*,\s*)"environ_map"'; KeepStrings = $true }
    # In every file the check reads (council G1: an imported `anytype` helper could write a step's field by
    # a computed name), but the reviewed sites below.
    @{ Name = 'computed @field write'; Pattern = '@field\s*\((?:[^()]|\([^()]*\))*,\s*[A-Za-z_][A-Za-z0-9_.]*\s*\)\s*=(?!=)'; Reviewed = $true }
)

# Computed-name `@field` writes read and kept, each by file, its code text and its count: anything else,
# another site or another of these, fails.
$script:BuildEnvironmentReviewedFieldWrites = @(
    # `Options.parse`'s feature list fills its own `Features` struct, by the names `@typeInfo(Features)` gives
    # it (`inline for`), "all" and each named one: no step, no environment.
    @{ Path = 'src/terminal/build_options.zig'; Text = '@field(result, field)'; Count = 2 }
)

# The body of `main` when it takes a `std.process.Init` (a host tool's entry point): its start and end
# offsets in `$Code`, or $null.
function Get-BuildEnvironmentHostMain([string] $Code) {
    $head = [regex]::Match($Code, '\bfn\s+main\s*\(\s*init\s*:\s*std\.process\.Init\b[^{]*\{')
    if (-not $head.Success) { return $null }
    $start = $head.Index + $head.Length
    $depth = 1
    foreach ($brace in [regex]::new('[{}]').Matches($Code, $start)) {
        if ($brace.Value -eq '{') { $depth++ } else { $depth-- }
        if ($depth -eq 0) { return @($start, $brace.Index) }
    }
    return $null
}

function Get-BuildEnvironmentCopyHits([string] $ZigText, [string] $Path) {
    $code = Remove-BuildEnvironmentNonCode $ZigText
    $withStrings = Remove-BuildEnvironmentNonCode $ZigText -KeepStrings
    # A host tool's own process environment: `init.environ_map` inside the body of the `main` that takes
    # the std.process.Init, and nowhere else in the file (council G1: ConptyRedist's configure-time
    # `install` sits beside its host `main`).
    $hostMain = Get-BuildEnvironmentHostMain $code
    foreach ($form in $script:BuildEnvironmentCopyForms) {
        $subject = if ($form['KeepStrings']) { $withStrings } else { $code }
        $reviewed = @{}
        foreach ($hit in [regex]::Matches($subject, $form.Pattern)) {
            if ($form['HostInit'] -and $null -ne $hostMain -and $hit.Index -gt $hostMain[0] -and $hit.Index -lt $hostMain[1] -and
                $subject.Substring(0, $hit.Index) -match '\binit\s*$') { continue }
            if ($form['OptionsField'] -and $subject.Substring([Math]::Max(0, $hit.Index - 64), [Math]::Min(64, $hit.Index)) -match '[{,]\s*$' -and
                $subject.Substring($hit.Index + $hit.Length) -match '^\s*=(?!=)') { continue }
            if ($form['Reviewed']) {
                $text = [regex]::Replace($hit.Value, '\s*=$', '')
                $site = @($script:BuildEnvironmentReviewedFieldWrites | Where-Object { $_.Path -ceq $Path -and $_.Text -ceq $text })
                if ($site.Count -eq 1) {
                    $reviewed[$text] = 1 + $(if ($reviewed.ContainsKey($text)) { $reviewed[$text] } else { 0 })
                    if ($reviewed[$text] -le $site[0]['Count']) { continue }
                }
            }
            $line = ($subject.Substring(0, $hit.Index) -split "`n").Count
            "${Path}:${line}: $($form.Name)"
        }
    }
}

# The files `$From` names with `@import("<relative>.zig")`, resolved against its folder, that exist under $Root.
function Get-BuildEnvironmentImports([string] $Root, [string] $From) {
    $code = Remove-BuildEnvironmentNonCode (Get-Content -LiteralPath $From -Raw) -KeepStrings
    $dir = Split-Path -Parent $From
    foreach ($m in [regex]::Matches($code, '@import\s*\(\s*"([^"\\]+\.zig)"\s*\)')) {
        $target = [System.IO.Path]::GetFullPath((Join-Path $dir $m.Groups[1].Value))
        if ($target.StartsWith([System.IO.Path]::GetFullPath($Root), [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $target -PathType Leaf)) { $target }
    }
}

function Get-BuildEnvironmentFiles([string] $Root) {
    $files = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $roots = [System.Collections.Generic.List[string]]::new()
    $buildZig = Join-Path $Root 'build.zig'
    if (Test-Path -LiteralPath $buildZig -PathType Leaf) { $roots.Add([System.IO.Path]::GetFullPath($buildZig)) }
    foreach ($dir in 'src', 'pkg') {
        $path = Join-Path $Root $dir
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $srcBuild = [System.IO.Path]::Combine($Root, 'src', 'build') + [System.IO.Path]::DirectorySeparatorChar
        foreach ($file in Get-ChildItem -LiteralPath $path -Recurse -File -Filter '*.zig') {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($file.Name -eq 'build.zig') { $roots.Add($file.FullName) }
            elseif ($file.FullName.StartsWith($srcBuild, [StringComparison]::OrdinalIgnoreCase) -or
                $text -match 'std\.Build\b|@import\s*\(\s*"std"\s*\)\s*\.\s*Build\b') {
                [void]$files.Add($file.FullName)
            }
        }
    }
    # The build runner's own module: what `build.zig` and the `pkg/` build files import, and
    # what those import, local `.zig` paths only (council F1). Not walked from `src/build/`'s
    # host tools (mdgen, webgen, helpgen), whose imports run in the tool's child process.
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $walked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $roots) { if ($walked.Add($r)) { $pending.Enqueue($r) } }
    while ($pending.Count -gt 0) {
        $from = $pending.Dequeue()
        [void]$files.Add($from)
        foreach ($next in @(Get-BuildEnvironmentImports $Root $from)) {
            if ($walked.Add($next)) { $pending.Enqueue($next) }
        }
    }
    return , @($files)
}

function Assert-NoBuildEnvironmentCopies([string] $Root) {
    $files = Get-BuildEnvironmentFiles $Root
    if ($files.Count -lt 3) { throw "The build environment check found only $($files.Count) build files under $Root." }
    $hits = @(foreach ($file in $files) {
            $relative = [System.IO.Path]::GetRelativePath($Root, $file).Replace('\', '/')
            Get-BuildEnvironmentCopyHits -ZigText (Get-Content -LiteralPath $file -Raw) -Path $relative
        })
    if ($hits.Count -gt 0) {
        throw "A build file copies the environment into a Run step (ZIG017-RUN-ENV-01; pass the value as an argument): $($hits -join '; ')"
    }
    return $files.Count
}

# Controls: each form is caught in code, none in a comment or a string, and the allowed forms pass.
$buildEnvironmentControls = 0
foreach ($sample in @(
        'run.setEnvironmentVariable("IS_STATIC", "1");',
        'run.removeEnvironmentVariable("PATH");',
        'const env = run.getEnvMap();',
        'run.clearEnvironment();',
        'run.@"setEnvironmentVariable"("IS_STATIC", "1");',
        'const set = std.Build.Step.Run.setEnvironmentVariable;',
        '@call(.auto, std.Build.Step.Run.setEnvironmentVariable, .{ run, "IS_STATIC", "1" });',
        'run.environ_map = &env;',
        'run.*.environ_map = &env;',
        'runs[0].environ_map = &env;',
        'maybe.?.environ_map = &env;',
        '@field(run, "environ_map") = &env;',
        # Council F10's four, and a read.
        'const p = &run.environ_map;',
        'std.mem.swap(?*std.process.Environ.Map, &run.environ_map, &other);',
        '@field(steps.get(0), "environ_map") = &env;',
        'const run = b.addSystemCommand(&.{ "tool" }); @field(run, name) = &env;',
        'if (run.environ_map == null) return;',
        # Council G1: with no Run constructor in sight, as an imported anytype helper writes it.
        '@field(run, name) = &env;',
        # Council H3: a member named as a string, and an environ_map argument that is no options field.
        '@field(Run, "setEnvironmentVariable")(run, "IS_STATIC", "1");',
        '_ = @call(.auto, @field(Run, "getEnvMap"), .{run});',
        'setField(run, .environ_map, &env);'
    )) {
    if (@(Get-BuildEnvironmentCopyHits -ZigText "fn f() void {`n    $sample`n}`n" -Path 'control.zig').Count -ne 1) {
        throw "The build environment check missed a control: $sample"
    }
    # A comment never counts; a string counts only where it names a Run member (council H3).
    $inString = if ($sample -match '\b(?:setEnvironmentVariable|removeEnvironmentVariable|getEnvMap|clearEnvironment)\b') { 1 } else { 0 }
    if (@(Get-BuildEnvironmentCopyHits -ZigText "// $sample`n" -Path 'control.zig').Count -ne 0 -or
        @(Get-BuildEnvironmentCopyHits -ZigText "const s = `"$($sample.Replace('"', ''))`";`n" -Path 'control.zig').Count -ne $inString) {
        throw "The build environment check miscounted a comment or string: $sample"
    }
    $buildEnvironmentControls += 2
}
foreach ($allowed in @(
        'const link_env = b.graph.environ_map.get("_LINK_") orelse "";',
        'const result = std.process.run(arena, io, .{ .environ_map = &env, .argv = argv });',
        'const result = std.process.run(arena, io, .{ .argv = argv, .environ_map = &env });',
        'const modern = @hasField(@TypeOf(b.graph.*), "environ_map");',
        'const env = &b.graph.environ_map;',
        '_ = env.swapRemove(name);'
    )) {
    if (@(Get-BuildEnvironmentCopyHits -ZigText "fn f() void {`n    $allowed`n}`n" -Path 'control.zig').Count -ne 0) {
        throw "The build environment check flagged an allowed form: $allowed"
    }
    $buildEnvironmentControls++
}
# A host tool's own environment passes only in a file whose main takes a std.process.Init.
$hostToolText = "pub fn main(init: std.process.Init) !void {`n    var env = try init.environ_map.clone(arena);`n}`n"
if (@(Get-BuildEnvironmentCopyHits -ZigText $hostToolText -Path 'control.zig').Count -ne 0) { throw 'The build environment check flagged a host tool''s own environment.' }
if (@(Get-BuildEnvironmentCopyHits -ZigText $hostToolText.Replace('init: std.process.Init', 'init: Options') -Path 'control.zig').Count -ne 1) {
    throw 'The build environment check passed init.environ_map outside a host tool.'
}
$buildEnvironmentControls += 2
# Council G1: only inside that main's body; the same file's other function is refused.
$hostToolBeside = $hostToolText + "pub fn install(init: anytype) void {`n    _ = init.environ_map;`n}`n"
if (@(Get-BuildEnvironmentCopyHits -ZigText $hostToolBeside -Path 'control.zig').Count -ne 1) {
    throw 'The build environment check passed init.environ_map outside the host main''s body.'
}
# The reviewed computed-name writes pass only in their file, and only as many as were read.
$reviewedWrite = "fn parse() void {`n    @field(result, field) = enable;`n    @field(result, field) = enable;`n}`n"
if (@(Get-BuildEnvironmentCopyHits -ZigText $reviewedWrite -Path 'src/terminal/build_options.zig').Count -ne 0) { throw 'The build environment check flagged a reviewed @field write.' }
if (@(Get-BuildEnvironmentCopyHits -ZigText $reviewedWrite -Path 'src/build/Other.zig').Count -ne 2) { throw 'The build environment check passed a reviewed @field write in another file.' }
if (@(Get-BuildEnvironmentCopyHits -ZigText ($reviewedWrite + "fn more() void {`n    @field(result, field) = enable;`n}`n") -Path 'src/terminal/build_options.zig').Count -ne 1) {
    throw 'The build environment check passed a third computed @field write in build_options.zig.'
}
$buildEnvironmentControls += 4

# Discovery controls (council F1): a helper the build script imports, which names std only as
# `@import("std").Build`, is read, and so is one it reaches through another import.
$discoveryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('noctty-c21-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $discoveryRoot 'src\tools') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $discoveryRoot 'pkg\x') -Force)
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'build.zig') -NoNewline -Value "const helper = @import(`"src/tools/helper.zig`");`npub fn build(b: *std.Build) void { _ = b; }`n"
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'pkg\x\build.zig') -NoNewline -Value "pub fn build(b: *std.Build) void { _ = b; }`n"
    # Council G2: an import after a URL string on the same line is still read.
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'src\tools\helper.zig') -NoNewline -Value "const B = @import(`"std`").Build;`nconst deep = @import(`"deep.zig`");`nconst url = `"https://example.invalid/x`"; const more = @import(`"more.zig`");`n"
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'src\tools\more.zig') -NoNewline -Value "pub fn add(run: anytype) void {`n    run.clearEnvironment();`n}`n"
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'src\tools\deep.zig') -NoNewline -Value "pub fn add(run: anytype) void {`n    run.setEnvironmentVariable(`"X`", `"1`");`n}`n"
    $discovered = Get-BuildEnvironmentFiles $discoveryRoot
    $found = @($discovered | ForEach-Object { [System.IO.Path]::GetRelativePath($discoveryRoot, $_).Replace('\', '/') })
    foreach ($want in 'build.zig', 'pkg/x/build.zig', 'src/tools/helper.zig', 'src/tools/deep.zig', 'src/tools/more.zig') {
        if ($found -cnotcontains $want) { throw "The build environment discovery missed $want (found: $($found -join ', '))." }
    }
    $failed = $false
    try { [void](Assert-NoBuildEnvironmentCopies -Root $discoveryRoot) } catch {
        $failed = ($_.Exception.Message -match 'src/tools/deep\.zig:2: setEnvironmentVariable') -and ($_.Exception.Message -match 'src/tools/more\.zig:2: clearEnvironment')
    }
    if (-not $failed) { throw 'The build environment check passed a forbidden call in an imported helper.' }
    $buildEnvironmentControls += 2
} finally {
    if (Test-Path -LiteralPath $discoveryRoot) { [IO.Directory]::Delete($discoveryRoot, $true) }
}

$buildEnvironmentFiles = Assert-NoBuildEnvironmentCopies -Root $repoRoot
Write-Host "Build environment copies: none in $buildEnvironmentFiles build files; $buildEnvironmentControls controls"
