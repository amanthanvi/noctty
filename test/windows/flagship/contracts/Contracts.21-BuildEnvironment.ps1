# No build file copies the configurer's environment into a Run step (ZIG017-RUN-ENV-01 in
# docs/agents/log/build-release-ci.md). On Zig 0.17 the first variable a Run step sets clones
# `b.graph.environ_map` into the step, and the configure process writes every step, that copy
# included, into the cached build configuration under `.zig-cache`. A later upstream merge must not
# bring such a call back silently: any mention of these Run members, or a write of a receiver's
# `environ_map`, in the code of a build file fails here. The build files are `build.zig`, every
# `pkg/` build file, and every other Zig file under `src/` or `pkg/` that names `std.Build`, since the
# build script imports them (`src/build/`, `src/differential_oracle_build.zig`,
# `pkg/apple-sdk/native_link.zig`). Reading or editing the graph's own map (`b.graph.environ_map`)
# stays allowed, and so do a host tool's `std.process.run` options field (`.{ .environ_map = &env }`)
# and `@hasField(..., "environ_map")`. The dependencies' own build scripts configure in the same
# process; CI's sentinel step (windows-lib-vt, scripts/check-configure-environment.ps1) covers them
# end to end.

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
# clearEnvironment replaces it), named in any way (a call, a reference called later, `@call`), and a
# write of a receiver's `environ_map` field, however the receiver is spelled (`run.`, `run.*.`,
# `runs[0].`, `maybe.?.`, `@field(run, "environ_map")`).
$script:BuildEnvironmentCopyForms = @(
    @{ Name = 'setEnvironmentVariable'; Pattern = '\bsetEnvironmentVariable\b' }
    @{ Name = 'removeEnvironmentVariable'; Pattern = '\bremoveEnvironmentVariable\b' }
    @{ Name = 'getEnvMap'; Pattern = '\bgetEnvMap\b' }
    @{ Name = 'clearEnvironment'; Pattern = '\bclearEnvironment\b' }
    @{ Name = 'environ_map write'; Pattern = '[\w)\]*?]\s*\.\s*environ_map\s*=(?!=)' }
    @{ Name = 'environ_map write'; Pattern = '@field\s*\([^,()]*,\s*"environ_map"\s*\)\s*=(?!=)'; KeepStrings = $true }
)

function Get-BuildEnvironmentCopyHits([string] $ZigText, [string] $Path) {
    $code = Remove-BuildEnvironmentNonCode $ZigText
    $withStrings = Remove-BuildEnvironmentNonCode $ZigText -KeepStrings
    foreach ($form in $script:BuildEnvironmentCopyForms) {
        $subject = if ($form.KeepStrings) { $withStrings } else { $code }
        foreach ($hit in [regex]::Matches($subject, $form.Pattern)) {
            $line = ($subject.Substring(0, $hit.Index) -split "`n").Count
            "${Path}:${line}: $($form.Name)"
        }
    }
}

function Get-BuildEnvironmentFiles([string] $Root) {
    $files = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $buildZig = Join-Path $Root 'build.zig'
    if (Test-Path -LiteralPath $buildZig -PathType Leaf) { [void]$files.Add($buildZig) }
    foreach ($dir in 'src', 'pkg') {
        $path = Join-Path $Root $dir
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $srcBuild = [System.IO.Path]::Combine($Root, 'src', 'build') + [System.IO.Path]::DirectorySeparatorChar
        foreach ($file in Get-ChildItem -LiteralPath $path -Recurse -File -Filter '*.zig') {
            if ($file.Name -eq 'build.zig' -or $file.FullName.StartsWith($srcBuild, [StringComparison]::OrdinalIgnoreCase) -or
                (Get-Content -LiteralPath $file.FullName -Raw) -match 'std\.Build\b') {
                [void]$files.Add($file.FullName)
            }
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
        '@field(run, "environ_map") = &env;'
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
        'if (run.environ_map == null) return;',
        'const modern = @hasField(@TypeOf(b.graph.*), "environ_map");',
        'const env = &b.graph.environ_map;',
        '_ = env.swapRemove(name);'
    )) {
    if (@(Get-BuildEnvironmentCopyHits -ZigText "fn f() void {`n    $allowed`n}`n" -Path 'control.zig').Count -ne 0) {
        throw "The build environment check flagged an allowed form: $allowed"
    }
    $buildEnvironmentControls++
}

$buildEnvironmentFiles = Assert-NoBuildEnvironmentCopies -Root $repoRoot
Write-Host "Build environment copies: none in $buildEnvironmentFiles build files; $buildEnvironmentControls controls"
