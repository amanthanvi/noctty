$ErrorActionPreference = "Stop"

# Seeds the dependency subset used by the Windows build. Generated
# build.zig.zon metadata may still list inactive platform packages.
# Zig 0.17 keeps each seeded package in the global cache's p/ as a tarball
# named by its hash; `zig build` unpacks it from there into the checkout's
# zig-pkg/, hashing it against the manifest's hash, without a download.

$systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
$userHome = if ($env:USERPROFILE) {
    $env:USERPROFILE
} elseif ($env:HOMEDRIVE -and $env:HOMEPATH) {
    "$($env:HOMEDRIVE)$($env:HOMEPATH)"
} elseif ($env:USERNAME) {
    Join-Path $systemDrive "Users\$($env:USERNAME)"
} else {
    Join-Path $systemDrive "Users"
}

$zigExe = if ($env:ZIG_HOME -and (Test-Path (Join-Path $env:ZIG_HOME "zig.exe"))) {
    Join-Path $env:ZIG_HOME "zig.exe"
} else {
    "zig.exe"
}

$globalCacheDir = if ($env:ZIG_GLOBAL_CACHE_DIR) {
    $env:ZIG_GLOBAL_CACHE_DIR
} else {
    Join-Path $userHome "AppData\Local\zig"
}

$downloadDir = Join-Path (Get-Location) ".zig-cache\downloads"
New-Item -ItemType Directory -Force -Path $globalCacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$deps = @(
    @{ Url = "https://deps.files.ghostty.org/libxev-819ffa180ca20e31c7eded74e2e1aceb1eab557f.tar.gz"; File = "libxev-819ffa180ca20e31c7eded74e2e1aceb1eab557f.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/vaxis-6fd944a27fb3d6f596e981076381a3131f2448b4.tar.gz"; File = "vaxis-6fd944a27fb3d6f596e981076381a3131f2448b4.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/z2d-40af3e84a4e15a9f31d126b3f281f23ce6a3dae5.tar.gz"; File = "z2d-40af3e84a4e15a9f31d126b3f281f23ce6a3dae5.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/zig_js-3c23860e47fdcdc5af805efb7fd0bdac5fd3e9bc.tar.gz"; File = "zig_js-3c23860e47fdcdc5af805efb7fd0bdac5fd3e9bc.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/uucode-ea62149739404a73c202b48a33bf6dd2af4bd9b0.tar.gz"; File = "uucode-ea62149739404a73c202b48a33bf6dd2af4bd9b0.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/zf-87153bb86b75d21fbac897b738f316d449f5d0c9.tar.gz"; File = "zf-87153bb86b75d21fbac897b738f316d449f5d0c9.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz"; File = "JetBrainsMono-2.304.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz"; File = "NerdFontsSymbolsOnly-3.4.0.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/ghostty-themes-release-20261019-151001-86a776d.tgz"; File = "ghostty-themes-release-20261019-151001-86a776d.tgz" },
    @{ Url = "https://deps.files.ghostty.org/breakpad-b99f444ba5f6b98cac261cbb391d8766b34a5918.tar.gz"; File = "breakpad-b99f444ba5f6b98cac261cbb391d8766b34a5918.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/DearBindings_v0.17_ImGui_v1.92.5-docking.tar.gz"; File = "DearBindings_v0.17_ImGui_v1.92.5-docking.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/N-V-__8AAEbOfQBnvcFcCX2W5z7tDaN8vaNZGamEQtNOe0UI.tar.gz"; File = "N-V-__8AAEbOfQBnvcFcCX2W5z7tDaN8vaNZGamEQtNOe0UI.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/N-V-__8AAOgqbADacob-q2_DMQlmgaG4xKHRuW-6PJ4oJzMZ.tar.xz"; File = "N-V-__8AAOgqbADacob-q2_DMQlmgaG4xKHRuW-6PJ4oJzMZ.tar.xz" },
    @{ Url = "https://deps.files.ghostty.org/freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz"; File = "freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz"; File = "glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/harfbuzz-11.0.0.tar.xz"; File = "harfbuzz-11.0.0.tar.xz" },
    @{ Url = "https://deps.files.ghostty.org/highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz"; File = "highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/gettext-0.24.tar.gz"; File = "gettext-0.24.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz"; File = "libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/libxml2-2.11.5.tar.gz"; File = "libxml2-2.11.5.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz"; File = "oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/sentry-1220446be831adcca918167647c06c7b825849fa3fba5f22da394667974537a9c77e.tar.gz"; File = "sentry-1220446be831adcca918167647c06c7b825849fa3fba5f22da394667974537a9c77e.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz"; File = "spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/wuffs-7411f488fe2e2c205c3d3b3d28638b7356522930.tar.gz"; File = "wuffs-7411f488fe2e2c205c3d3b3d28638b7356522930.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz"; File = "pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz"; File = "zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz" },
    @{ Url = "https://deps.files.ghostty.org/translate_c-02ff0c523fb92a38939b04d0145c4a9602a74d56.tar.gz"; File = "translate_c-02ff0c523fb92a38939b04d0145c4a9602a74d56.tar.gz" },
    # translate_c's own dependency is a git URL, which zig fetch reads itself.
    @{ Url = "git+https://codeberg.org/ziglang/arocc#d0c8c4d9c55daa7ef6e40cf0f630a5b5e900989b"; File = "aro-d0c8c4d9c55daa7ef6e40cf0f630a5b5e900989b"; Git = $true }
)

function Invoke-Seed {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Dep
    )

    $archive = Join-Path $downloadDir $Dep.File
    $label = $Dep.File
    if ($Dep.Optional) {
        $label = "$label (optional)"
    }
    Write-Host "== $label =="

    if ($Dep.Git) {
        $archive = $Dep.Url
    } elseif (-not (Test-Path $archive)) {
        & bitsadmin /transfer "noctty-$($Dep.File)" /download /priority foreground $Dep.Url $archive
        if ($LASTEXITCODE -ne 0) {
            if ($Dep.Optional) {
                Write-Host "Skipping optional dependency archive: $($Dep.File)"
                return
            }

            throw "bitsadmin failed for $($Dep.Url)"
        }
    }

    & $zigExe fetch $archive
    if ($LASTEXITCODE -ne 0) {
        if ($Dep.Optional) {
            Write-Host "Skipping optional dependency seed: $($Dep.File)"
            return
        }

        throw "zig fetch failed for $archive"
    }
}

# Zig 0.17.1's `zig fetch` refuses --global-cache-dir ("unrecognized
# parameter") and reads the global cache from ZIG_GLOBAL_CACHE_DIR.
$savedGlobalCacheDir = $env:ZIG_GLOBAL_CACHE_DIR
$env:ZIG_GLOBAL_CACHE_DIR = $globalCacheDir
try {
    foreach ($dep in $deps) {
        Invoke-Seed $dep
    }
} finally {
    $env:ZIG_GLOBAL_CACHE_DIR = $savedGlobalCacheDir
}

Write-Host "Seeded Zig cache under `"$globalCacheDir`""
