# Path kinds (PLAN.md r46a §2.5): what the tree may contain after the upstream merges.
#
# The must-be-empty kind: no tracked file under these paths, in 1A and in 1B. Upstream
# carries them (v1.4.0 has macos/ 271, src/apprt/gtk 79, po/ 37 files) and the fork has
# none; the stone merge (ab950cd81) deleted every one it brought, by the 1A delete list
# (generated 2026-11-20 from git objects only). The pathspecs below are §2.5's groups; the
# explicit paths are the delete list's clean-delete and lead-delete rows and the
# must-be-empty rows no group pattern covers. The three Apple build steps GhosttyLibVt.zig
# once referenced (LipoStep.zig, LibtoolStep.zig, XCFrameworkStep.zig) are here too: the
# stepping stone stripped them (plans/stone-1a/drift-decisions.tsv, row Qg11-1;
# docs/upstream-merge-policy.md). The keep-fork and track-upstream kinds are reviewed
# diffs, not this check.

$pathKindsMustBeEmpty = @(
    # §2.5's groups
    ':(glob)macos/**', ':(glob)dist/macos/**', ':(glob)dist/linux/**', ':(glob)flatpak/**', ':(glob)snap/**',
    ':(glob)po/**', ':(glob)src/apprt/gtk*', ':(glob)src/apprt/gtk*/**',
    'src/apprt/embedded.zig', 'include/ghostty.h', 'src/main_c.zig', 'src/config/CApi.zig',
    ':(glob)src/renderer/metal/**', 'src/renderer/Metal.zig', 'src/renderer/Dmabuf.zig', 'src/renderer/DisplayLink.zig',
    ':(glob)src/font/face/coretext*', ':(glob)src/font/shaper/coretext*', ':(glob)**/LibsystemOverride*',
    'nix/package.nix', 'nix/tests.nix', ':(glob)nix/vm/**', 'nix/patches/zig-0.17-ios-process-replace.patch',
    ':(glob)pkg/gtk4-layer-shell/**', ':(glob)example/swift-vt-xcframework/**', ':(glob)test/esctest/**',
    '.github/VOUCHED.td', ':(glob).github/DISCUSSION_TEMPLATE/**', ':(glob).github/scripts/**',
    '.github/issue-unvouched-message',
    # The delete list's rows no group covers: the Apple and i18n build step, upstream-only workflows,
    # the clean deletes (highway's old layout, utfcpp) and the lead's deletes.
    'src/build/GhosttyXCFramework.zig',
    'src/build/LipoStep.zig', 'src/build/LibtoolStep.zig', 'src/build/XCFrameworkStep.zig',
    '.github/workflows/flatpak.yml', '.github/workflows/nix.yml', '.github/workflows/release-tag.yml',
    '.github/workflows/release-tip.yml', '.github/workflows/snap.yml', '.github/workflows/update-colorschemes.yml',
    '.github/workflows/vouch-check-issue.yml', '.github/workflows/vouch-check-pr.yml',
    '.github/workflows/vouch-manage-by-discussion.yml', '.github/workflows/vouch-manage-by-issue.yml',
    '.github/workflows/vouch-sync-codeowners.yml',
    'pkg/highway/bridge.cpp', 'pkg/highway/main.zig', ':(glob)pkg/utfcpp/**',
    'CLAUDE.md', ':(glob)images/Ghostty.icon/**', 'nix/test-src/test_libghostty_vt.c', 'src/build/GhosttyLib.zig'
)

# Every tracked path any must-be-empty pathspec matches, in the repository at $Root.
function Get-PathKindsViolations([string] $Root) {
    $tracked = @(& git -C $Root -c core.quotepath=false ls-files -z -- @pathKindsMustBeEmpty)
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $Root." }
    return @(($tracked -join '') -split "`0" | Where-Object { $_ })
}

$pathKindsFound = Get-PathKindsViolations $repoRoot
if ($pathKindsFound.Count -ne 0) {
    throw ("Must-be-empty paths (PLAN §2.5) are tracked: " + (($pathKindsFound | Select-Object -First 5) -join ', '))
}

# Negative control: the same check, in a scratch repository with planted files, one under a
# group pattern, one an explicit delete-list path, one an Apple build step, one a nested gtk
# file, and one that is allowed (a fork file beside them), must find exactly the four planted
# ones. The scratch
# repository sits under the checkout's git-ignored .zig-cache, where the contracts' Zig
# fixture batch already installs (.zig-cache\flagship-fixtures), not under %TEMP%, and is
# removed again whatever the control found.
$pathKindsScratchParent = Join-Path $repoRoot '.zig-cache\flagship-contracts'
$pathKindsScratch = Join-Path $pathKindsScratchParent ('pathkinds-' + [Guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Force -Path $pathKindsScratchParent)
    [void](New-Item -ItemType Directory -Path $pathKindsScratch)
    & git -C $pathKindsScratch -c init.templateDir= init -q
    if ($LASTEXITCODE -ne 0) { throw 'git init failed for the path-kinds control.' }
    $planted = @('macos/Planted.swift', 'src/build/GhosttyLib.zig', 'src/build/LipoStep.zig', 'src/apprt/gtk/Planted.zig', 'src/apprt/win32.zig')
    foreach ($p in $planted) {
        $full = Join-Path $pathKindsScratch $p
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full))
        [IO.File]::WriteAllText($full, "planted`n")
    }
    & git -C $pathKindsScratch -c core.autocrlf=false -c core.safecrlf=false add -- @planted
    if ($LASTEXITCODE -ne 0) { throw 'git add failed for the path-kinds control.' }
    $controlFound = @(Get-PathKindsViolations $pathKindsScratch | Sort-Object)
    $expected = @('macos/Planted.swift', 'src/apprt/gtk/Planted.zig', 'src/build/GhosttyLib.zig', 'src/build/LipoStep.zig')
    if (($controlFound -join '|') -cne ($expected -join '|')) {
        throw ("The path-kinds negative control found '" + ($controlFound -join ', ') + "', expected '" + ($expected -join ', ') + "'.")
    }
}
finally {
    if (Test-Path -LiteralPath $pathKindsScratch) { Remove-Item -LiteralPath $pathKindsScratch -Recurse -Force }
}
Write-Host "Path kinds (PLAN section 2.5): $($pathKindsMustBeEmpty.Count) must-be-empty pathspecs, 0 tracked; negative control found its 4 planted paths and passed the allowed one"
