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
# file whose `main` takes `init: std.process.Init`). The dependencies' own build scripts configure in
# the same process; CI's sentinel step (windows-lib-vt, scripts/check-configure-environment.ps1)
# covers them end to end.

# Blanks every Zig comment, multi-line-string line, string literal and character literal, keeping
# the length, so a hit is code. A quoted identifier (`@"name"`) keeps its name, so
# `run.@"setEnvironmentVariable"(...)` is still seen.
function Remove-BuildEnvironmentNonCode([string] $Text, [switch] $KeepStrings) {
    $named = [regex]::Replace($Text, '@"([A-Za-z_][A-Za-z0-9_]*)"', { param($m) ' ' + $m.Groups[1].Value + '  ' })
    $pattern = if ($KeepStrings) { '//[^\n]*|\\\\[^\n]*' } else { '//[^\n]*|\\\\[^\n]*|''(?:\\.|[^''\\\n])''|"(?:\\.|[^"\\\n])*"' }
    return [regex]::Replace($named, $pattern, { param($m) ' ' * $m.Length })
}

# The Run step members that reach the step's environment map (`lib/std/Build/Step/Run.zig`:
# setEnvironmentVariable, removeEnvironmentVariable and getEnvMap clone the graph's map,
# clearEnvironment replaces it), named in any way (a call, a reference called later, `@call`); any
# mention of an `environ_map` field but the allowed ones, however the receiver is spelled (a write, a
# read, an address taken for a later write or a swap); the field named as a string, but in
# `@hasField`; and a `@field` write whose field name is not a literal, which could be `environ_map`.
$script:BuildEnvironmentCopyForms = @(
    @{ Name = 'setEnvironmentVariable'; Pattern = '\bsetEnvironmentVariable\b' }
    @{ Name = 'removeEnvironmentVariable'; Pattern = '\bremoveEnvironmentVariable\b' }
    @{ Name = 'getEnvMap'; Pattern = '\bgetEnvMap\b' }
    @{ Name = 'clearEnvironment'; Pattern = '\bclearEnvironment\b' }
    @{ Name = 'environ_map mention'; Pattern = '(?<!\bgraph\s*)(?<![{,]\s*)\.\s*environ_map\b(?!\s*:)'; HostInit = $true }
    @{ Name = 'environ_map named'; Pattern = '(?<!@hasField\s*\([^()]*(?:\([^()]*\))?[^()]*,\s*)"environ_map"'; KeepStrings = $true }
    # In a file that makes or takes a Run step only: an options struct filled by name
    # (`terminal/build_options.zig`) is no step.
    @{ Name = 'computed @field write'; Pattern = '@field\s*\((?:[^()]|\([^()]*\))*,\s*[A-Za-z_][A-Za-z0-9_.]*\s*\)\s*=(?!=)'; RunFile = $true }
)

function Get-BuildEnvironmentCopyHits([string] $ZigText, [string] $Path) {
    $code = Remove-BuildEnvironmentNonCode $ZigText
    $withStrings = Remove-BuildEnvironmentNonCode $ZigText -KeepStrings
    # A host tool's own process environment: `init.environ_map` where `main` takes a std.process.Init.
    $hostTool = $code -match '\bfn\s+main\s*\(\s*init\s*:\s*std\.process\.Init\b'
    $runFile = $code -match '\bStep\s*\.\s*Run\b|\baddRunArtifact\b|\baddSystemCommand\b'
    foreach ($form in $script:BuildEnvironmentCopyForms) {
        if ($form['RunFile'] -and -not $runFile) { continue }
        $subject = if ($form['KeepStrings']) { $withStrings } else { $code }
        foreach ($hit in [regex]::Matches($subject, $form.Pattern)) {
            if ($form['HostInit'] -and $hostTool -and $subject.Substring(0, $hit.Index) -match '\binit\s*$') { continue }
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
        'if (run.environ_map == null) return;'
    )) {
    if (@(Get-BuildEnvironmentCopyHits -ZigText "fn f() void {`n    $sample`n}`n" -Path 'control.zig').Count -ne 1) {
        throw "The build environment check missed a control: $sample"
    }
    if (@(Get-BuildEnvironmentCopyHits -ZigText "// $sample`nconst s = `"$($sample.Replace('"', ''))`";`n" -Path 'control.zig').Count -ne 0) {
        throw "The build environment check flagged a comment or string: $sample"
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

# Discovery controls (council F1): a helper the build script imports, which names std only as
# `@import("std").Build`, is read, and so is one it reaches through another import.
$discoveryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('noctty-c21-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $discoveryRoot 'src\tools') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $discoveryRoot 'pkg\x') -Force)
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'build.zig') -NoNewline -Value "const helper = @import(`"src/tools/helper.zig`");`npub fn build(b: *std.Build) void { _ = b; }`n"
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'pkg\x\build.zig') -NoNewline -Value "pub fn build(b: *std.Build) void { _ = b; }`n"
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'src\tools\helper.zig') -NoNewline -Value "const B = @import(`"std`").Build;`nconst deep = @import(`"deep.zig`");`n"
    Set-Content -LiteralPath (Join-Path $discoveryRoot 'src\tools\deep.zig') -NoNewline -Value "pub fn add(run: anytype) void {`n    run.setEnvironmentVariable(`"X`", `"1`");`n}`n"
    $discovered = Get-BuildEnvironmentFiles $discoveryRoot
    $found = @($discovered | ForEach-Object { [System.IO.Path]::GetRelativePath($discoveryRoot, $_).Replace('\', '/') })
    foreach ($want in 'build.zig', 'pkg/x/build.zig', 'src/tools/helper.zig', 'src/tools/deep.zig') {
        if ($found -cnotcontains $want) { throw "The build environment discovery missed $want (found: $($found -join ', '))." }
    }
    $failed = $false
    try { [void](Assert-NoBuildEnvironmentCopies -Root $discoveryRoot) } catch { $failed = $_.Exception.Message -match 'src/tools/deep\.zig:2: setEnvironmentVariable' }
    if (-not $failed) { throw 'The build environment check passed a forbidden call in an imported helper.' }
    $buildEnvironmentControls += 2
} finally {
    if (Test-Path -LiteralPath $discoveryRoot) { [IO.Directory]::Delete($discoveryRoot, $true) }
}

$buildEnvironmentFiles = Assert-NoBuildEnvironmentCopies -Root $repoRoot
Write-Host "Build environment copies: none in $buildEnvironmentFiles build files; $buildEnvironmentControls controls"
