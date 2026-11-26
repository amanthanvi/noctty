# No build file copies the configurer's environment into a Run step (ZIG017-RUN-ENV-01 in
# docs/agents/log/build-release-ci.md). On Zig 0.17 the first variable a Run step sets clones
# `b.graph.environ_map` into the step, and the configure process writes every step, that copy
# included, into the cached build configuration under `.zig-cache`. A later upstream merge must not
# bring such a call back silently: any of these in `build.zig`, `src/build/` or a `pkg/` build
# file fails here. Reading the graph's map (`b.graph.environ_map.get`) stays allowed, and so does a
# host tool's own `std.process.run` options field (`.{ .environ_map = &env }`), which no step keeps.

# Blanks every Zig comment, multi-line-string line, string literal and character literal, keeping
# the length, so a hit is code.
function Remove-BuildEnvironmentNonCode([string] $Text) {
    return [regex]::Replace($Text, '//[^\n]*|\\\\[^\n]*|''(?:\\.|[^''\\\n])''|"(?:\\.|[^"\\\n])*"', { param($m) ' ' * $m.Length })
}

# The Run step calls that reach the step's environment map (`lib/std/Build/Step/Run.zig`:
# setEnvironmentVariable, removeEnvironmentVariable and getEnvMap clone the graph's map,
# clearEnvironment replaces it) and a direct write of a receiver's `environ_map` field.
$script:BuildEnvironmentCopyForms = @(
    @{ Name = 'setEnvironmentVariable'; Pattern = '\.\s*setEnvironmentVariable\s*\(' }
    @{ Name = 'removeEnvironmentVariable'; Pattern = '\.\s*removeEnvironmentVariable\s*\(' }
    @{ Name = 'getEnvMap'; Pattern = '\.\s*getEnvMap\s*\(' }
    @{ Name = 'clearEnvironment'; Pattern = '\.\s*clearEnvironment\s*\(' }
    @{ Name = 'environ_map write'; Pattern = '[A-Za-z_][\w.]*\.\s*environ_map\s*=(?!=)' }
)

function Get-BuildEnvironmentCopyHits([string] $ZigText, [string] $Path) {
    $code = Remove-BuildEnvironmentNonCode $ZigText
    foreach ($form in $script:BuildEnvironmentCopyForms) {
        foreach ($hit in [regex]::Matches($code, $form.Pattern)) {
            $line = ($code.Substring(0, $hit.Index) -split "`n").Count
            "${Path}:${line}: $($form.Name)"
        }
    }
}

function Get-BuildEnvironmentFiles([string] $Root) {
    $files = [System.Collections.Generic.List[string]]::new()
    $buildZig = Join-Path $Root 'build.zig'
    if (Test-Path -LiteralPath $buildZig -PathType Leaf) { $files.Add($buildZig) }
    $srcBuild = Join-Path $Root 'src\build'
    if (Test-Path -LiteralPath $srcBuild -PathType Container) {
        Get-ChildItem -LiteralPath $srcBuild -Recurse -File -Filter '*.zig' | ForEach-Object { $files.Add($_.FullName) }
    }
    $pkg = Join-Path $Root 'pkg'
    if (Test-Path -LiteralPath $pkg -PathType Container) {
        Get-ChildItem -LiteralPath $pkg -Recurse -File -Filter 'build.zig' | ForEach-Object { $files.Add($_.FullName) }
    }
    return , $files.ToArray()
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

# Controls: each form is caught in code, none in a comment or a string, and the allowed reads pass.
$buildEnvironmentControls = 0
foreach ($form in $script:BuildEnvironmentCopyForms) {
    $sample = switch ($form.Name) {
        'setEnvironmentVariable' { 'run.setEnvironmentVariable("IS_STATIC", "1");' }
        'removeEnvironmentVariable' { 'run.removeEnvironmentVariable("PATH");' }
        'getEnvMap' { 'const env = run.getEnvMap();' }
        'clearEnvironment' { 'run.clearEnvironment();' }
        'environ_map write' { 'run.environ_map = &env;' }
    }
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
        'if (run.environ_map == null) return;'
    )) {
    if (@(Get-BuildEnvironmentCopyHits -ZigText "fn f() void {`n    $allowed`n}`n" -Path 'control.zig').Count -ne 0) {
        throw "The build environment check flagged an allowed form: $allowed"
    }
    $buildEnvironmentControls++
}

$buildEnvironmentFiles = Assert-NoBuildEnvironmentCopies -Root $repoRoot
Write-Host "Build environment copies: none in $buildEnvironmentFiles build files; $buildEnvironmentControls controls"
