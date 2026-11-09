# Symbols zip: every release ships the PDBs of its binaries, and they must be
# the ones those binaries ask for (same GUID and age). The text contracts pin
# where the zip is built, listed, attested, published and verified; the
# executed ones run the real verification helpers on a synthetic PE and PDB,
# so they need no build.
$symbolsVerification = Join-Path $repoRoot 'scripts\symbols-verification.ps1'
$symbolsVerificationText = Get-Content -LiteralPath $symbolsVerification -Raw
$windowsPackager82 = Join-Path $repoRoot 'scripts\package-windows.ps1'
$windowsPackagerText82 = Get-Content -LiteralPath $windowsPackager82 -Raw
$windowsPackageBuilder82 = Join-Path $repoRoot 'scripts\build-package-windows.ps1'
$windowsPackageBuilderText82 = Get-Content -LiteralPath $windowsPackageBuilder82 -Raw
$releaseWorkflow82 = Join-Path $repoRoot '.github\workflows\release.yml'
$releaseWorkflowText82 = Get-Content -LiteralPath $releaseWorkflow82 -Raw
$armWorkflow82 = Join-Path $repoRoot '.github\workflows\windows-arm64.yml'
$armWorkflowText82 = Get-Content -LiteralPath $armWorkflow82 -Raw
$githubPublisher82 = Join-Path $repoRoot 'scripts\release-publish-github.ps1'
$githubPublisherText82 = Get-Content -LiteralPath $githubPublisher82 -Raw
$ghosttyExe82 = Join-Path $repoRoot 'src\build\GhosttyExe.zig'
$ghosttyExeText82 = Get-Content -LiteralPath $ghosttyExe82 -Raw
$proxyBuild82 = Join-Path $repoRoot 'src\build\TerminalHandoffProxy.zig'
$proxyBuildText82 = Get-Content -LiteralPath $proxyBuild82 -Raw
$vtStubBuild82 = Join-Path $repoRoot 'src\build\GhosttyVtStub.zig'
$vtStubBuildText82 = Get-Content -LiteralPath $vtStubBuild82 -Raw
$buildConfig82 = Join-Path $repoRoot 'src\build\Config.zig'
$buildConfigText82 = Get-Content -LiteralPath $buildConfig82 -Raw
$buildZig82 = Join-Path $repoRoot 'build.zig'
$buildZigText82 = Get-Content -LiteralPath $buildZig82 -Raw
$processShared82 = Join-Path $repoRoot 'src\process_shared.zig'
$processSharedText82 = Get-Content -LiteralPath $processShared82 -Raw
$mainZig82 = Join-Path $repoRoot 'src\main.zig'
$mainZigText82 = Get-Content -LiteralPath $mainZig82 -Raw
$mainCommandZig82 = Join-Path $repoRoot 'src\main_noctty_command.zig'
$mainCommandZigText82 = Get-Content -LiteralPath $mainCommandZig82 -Raw

Invoke-ContractTable -Contracts @(
    @{
        File = $windowsPackager82
        Content = { $windowsPackagerText82 }
        Pattern = '(?s)\[switch\]\$RequireSymbols.*?& zig build [^\r\n]*-Doptimize=ReleaseFast -Dstrip=false [^\r\n]*.*?Get-PeCodeViewIdentity -Path \(Join-Path \$portableRoot "noctty\.exe"\).*?if \(\$RequireSymbols\) \{\s*throw "Symbols are required.*?Assert-SymbolsMatchBinaries\s*`\s*-SymbolsRoot \$symbolsRoot\s*`\s*-PayloadRoot \$portableRoot.*?CreateFromDirectory\(\s*\$symbolsRoot,\s*\$symbolsPath.*?if \(\$symbolsProduced\) \{\s*\$hashTargets \+= @\{'
        Kind = 'Text'
        Description = 'packager keeps debug info, refuses a required-but-missing symbols zip, verifies GUID and age against the staged binaries, zips outside the portable tree and checksums it'
    }
    @{
        File = $windowsPackager82
        Content = { $windowsPackagerText82 }
        Pattern = '(?s)\$symbolsRoot = Join-Path \$stageBase "symbols".*?Packaging phase: create portable zip.*?Packaging phase: create symbols zip.*?Packaging phase: build installer'
        Kind = 'Text'
        Description = 'symbols are staged in a folder of their own, after the portable zip and before the installer, so neither contains a PDB'
    }
    @{
        File = $windowsPackageBuilder82
        Content = { $windowsPackageBuilderText82 }
        Pattern = '(?s)"-Dstrip=false".*?if \(\$RequireSymbols\) \{\s*\$packageArgs\.RequireSymbols = \$true\s*\}'
        Kind = 'Text'
        Description = 'build wrapper builds with debug info and forwards required symbols mode to the packager'
    }
    @{
        File = $releaseWorkflow82
        Content = { $releaseWorkflowText82 }
        Pattern = '(?s)Build and package x64 release artifacts.*?-Architecture x64.*?-RequireSigning\s+-RequireConPty\s+-RequireSymbols.*?Build and package ARM64 release artifacts.*?-Architecture arm64.*?-RequireSigning\s+-RequireConPty\s+-RequireSymbols'
        Kind = 'Text'
        Description = 'release packages both architectures with symbols required'
    }
    @{
        File = $armWorkflow82
        Content = { $armWorkflowText82 }
        Pattern = '(?s)build-package-windows\.ps1\s+-Version \$env:NOCTTY_CI_VERSION\s+-Architecture arm64\s+-Optimize ReleaseFast\s+-RequireSymbols'
        Kind = 'Text'
        Description = 'ARM64 CI exercises the symbols path on a native runner'
    }
    @{
        File = $githubPublisher82
        Content = { $githubPublisherText82 }
        Pattern = '(?s)Kind manifest\)\),\s*\(Join-Path \$artifactDirectory \(New-WindowsPackageArtifactName -Version \$Version -Architecture \$architecture -Kind symbols\)\),\s*\(Join-Path \$artifactDirectory \(New-WindowsPackageArtifactName -Version \$Version -Architecture \$architecture -Kind checksums\)\)'
        Kind = 'Text'
        Description = 'GitHub publisher uploads each architecture''s symbols zip'
    }
    @{
        File = $ghosttyExe82
        Content = { $ghosttyExeText82 }
        Pattern = '(?s)\.omit_frame_pointer = cfg\.omit_frame_pointer.*?\.omit_frame_pointer = cfg\.omit_frame_pointer.*?command\.producesPdbFile\(\).*?addInstallBinFile\(command\.getEmittedPdb\(\), "noctty-command\.pdb"\)'
        Kind = 'Text'
        Description = 'noctty.exe and noctty.com keep release codegen without strip, and noctty-command.pdb is installed beside them'
    }
    @{
        File = $buildConfig82
        Content = { $buildConfigText82 }
        Pattern = '(?s)config\.omit_frame_pointer = switch \(optimize\) \{\s*\.Debug, \.ReleaseSafe => false,\s*\.ReleaseFast, \.ReleaseSmall => true,'
        Kind = 'Text'
        Description = 'frame-pointer omission follows the optimize mode, not -Dstrip, so the shipped PDB describes release codegen'
    }
    @{
        File = $buildZig82
        Content = { $buildZigText82 }
        Pattern = '(?s)if \(config\.release_symbols\) \{\s*const inherited = b\.graph\.env_map\.get\("_LINK_"\).*?b\.graph\.env_map\.put\("_LINK_", b\.fmt\("\{s\} -OPT:REF", \.\{inherited\}\)\)'
        Kind = 'Text'
        Description = 'a Windows release build that keeps its PDB links with /OPT:REF, which lld-link drops once /DEBUG is on'
    }
    @{
        File = $buildConfig82
        Content = { $buildConfigText82 }
        Pattern = '(?s)config\.release_symbols = config\.omit_frame_pointer and\s+!config\.strip and\s+config\.target\.result\.os\.tag == \.windows;.*?step\.addOption\(bool, "release_symbols", self\.release_symbols\);'
        Kind = 'Text'
        Description = 'the /OPT:REF condition is also a build option, so a cached link without the flag is never reused'
    }
    @{
        File = $processShared82
        Content = { $processSharedText82 }
        Pattern = '(?s)pub const panic = switch \(builtin\.mode\) \{\s*\.Debug, \.ReleaseSafe => std\.debug\.FullPanic\(std\.debug\.defaultPanic\),\s*\.ReleaseFast, \.ReleaseSmall => std\.debug\.FullPanic\(releasePanic\),\s*\};.*?fn releasePanic\(msg: \[\]const u8, _: \?usize\) noreturn \{.*?@trap\(\);'
        Kind = 'Text'
        Description = 'release panics print the message and trap instead of linking std.debug''s symbolizer into an image that keeps debug info'
    }
    @{
        File = $mainZig82
        Content = { $mainZigText82 }
        Pattern = '(?s)pub const panic = if \(build_config\.exe_entrypoint == \.ghostty\)\s+@import\("process_shared\.zig"\)\.panic'
        Kind = 'Text'
        Description = 'noctty.exe uses the shared release panic'
    }
    @{
        File = $mainCommandZig82
        Content = { $mainCommandZigText82 }
        Pattern = 'pub const panic = std\.debug\.no_panic;'
        Kind = 'Text'
        Description = 'the thin noctty.com forwarder does not link a panic symbolizer'
    }
    @{
        File = $proxyBuild82
        Content = { $proxyBuildText82 }
        Pattern = '(?s)library\.producesPdbFile\(\).*?addInstallBinFile\(library\.getEmittedPdb\(\), name \+\+ "\.pdb"\)'
        Kind = 'Text'
        Description = 'the handoff proxy DLL''s PDB is installed beside it'
    }
    @{
        File = $proxyBuild82
        Content = { $proxyBuildText82 }
        Pattern = 'module\.addCMacro\("NOCTTY_RELEASE_SYMBOLS", if \(cfg\.release_symbols\) "1" else "0"\);'
        Kind = 'Text'
        Description = 'the handoff proxy (C only, blind to build options) hashes release_symbols, so a DLL linked without /OPT:REF is not reused'
    }
    @{
        File = $vtStubBuild82
        Content = { $vtStubBuildText82 }
        Pattern = '(?s)\.strip = cfg\.strip,.*?module\.addCMacro\("NOCTTY_RELEASE_SYMBOLS", if \(cfg\.release_symbols\) "1" else "0"\);.*?library\.producesPdbFile\(\).*?addInstallFileWithDir\(\s*library\.getEmittedPdb\(\),\s*\.\{ \.custom = "bin/" \+\+ install_dir \},\s*name \+\+ "\.pdb",'
        Kind = 'Text'
        Description = 'the ghostty-vt.dll placeholder keeps debug info with the exe, hashes release_symbols and installs ghostty-vt.pdb beside itself in zig-out\bin\ghostty-vt-stub'
    }
    @{
        File = $windowsPackager82
        Content = { $windowsPackagerText82 }
        Pattern = '(?s)foreach \(\$binaryName in \(Get-WindowsSymbolBinaryNames\)\).*?\$runtimeSource = @\(\$runtimeFiles \| Where-Object \{ \(Split-Path -Leaf \$_\) -ceq \$binaryName \}\).*?\$pdbSource = Join-Path \(Split-Path -Parent \(Join-Path \$zigOutBin \$runtimeSource\[0\]\)\) \$identity\.PdbName'
        Kind = 'Text'
        Description = 'a PDB is taken from beside the build output its binary was staged from, so ghostty-vt.pdb is the placeholder''s and never a lib-vt build''s'
    }
)

# Scoop, WinGet and Chocolatey name the setup and portable assets and nothing
# else, so a symbols zip in the release cannot reach them.
foreach ($consumerScript in @(
    'scripts\package-package-managers.ps1',
    'scripts\release-publish-scoop.ps1',
    'scripts\release-submit-winget.ps1',
    'scripts\release-publish-chocolatey.ps1'
)) {
    $consumerText = Get-Content -LiteralPath (Join-Path $repoRoot $consumerScript) -Raw
    if ($consumerText -match '(?i)symbols') {
        throw "Package-manager path must not handle the symbols zip: $consumerScript"
    }
}
$packageManagerMetadataText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\package-package-managers.ps1') -Raw
if ($packageManagerMetadataText -notmatch
        '(?s)-Kind portable.*?Get-AssetChecksum.*?\$setupName.*?Get-AssetChecksum.*?\$portableName') {
    throw 'Package-manager metadata must look the setup and portable checksums up by name.'
}

# Executed contracts: the helpers against a synthetic PE and PDB.
. (Join-Path $repoRoot 'scripts\common.ps1')
. $symbolsVerification

function New-SymbolsTestPe {
    # A minimal PE32+ whose only content is a debug directory with one RSDS
    # record, or no debug directory at all when $PdbPath is empty.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $PdbPath,
        [guid] $Guid = [guid]::Empty,
        [uint32] $Age = 1
    )

    $file = New-Object byte[] 0x400
    $file[0] = 0x4D; $file[1] = 0x5A
    [BitConverter]::GetBytes([uint32]0x40).CopyTo($file, 0x3C)
    $pe = 0x40
    [Text.Encoding]::ASCII.GetBytes("PE`0`0").CopyTo($file, $pe)
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($file, $pe + 4)   # machine
    [BitConverter]::GetBytes([uint16]1).CopyTo($file, $pe + 6)        # sections
    [BitConverter]::GetBytes([uint16]240).CopyTo($file, $pe + 20)     # optional header size
    $optional = $pe + 24
    [BitConverter]::GetBytes([uint16]0x20B).CopyTo($file, $optional)
    [BitConverter]::GetBytes([uint32]16).CopyTo($file, $optional + 108)   # data directories
    $section = $optional + 240
    [Text.Encoding]::ASCII.GetBytes(".rdata").CopyTo($file, $section)
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($file, $section + 8)   # virtual size
    [BitConverter]::GetBytes([uint32]0x1000).CopyTo($file, $section + 12) # virtual address
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($file, $section + 16)  # raw size
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($file, $section + 20)  # raw pointer
    if ($PdbPath) {
        $record = New-Object System.Collections.Generic.List[byte]
        $record.AddRange([Text.Encoding]::ASCII.GetBytes('RSDS'))
        $record.AddRange($Guid.ToByteArray())
        $record.AddRange([BitConverter]::GetBytes($Age))
        $record.AddRange([Text.Encoding]::UTF8.GetBytes($PdbPath))
        $record.Add(0)
        $directory = $optional + 112 + 8 * 6
        [BitConverter]::GetBytes([uint32]0x1000).CopyTo($file, $directory)
        [BitConverter]::GetBytes([uint32]28).CopyTo($file, $directory + 4)
        $entry = 0x200
        [BitConverter]::GetBytes([uint32]2).CopyTo($file, $entry + 12)             # CODEVIEW
        [BitConverter]::GetBytes([uint32]$record.Count).CopyTo($file, $entry + 16)
        [BitConverter]::GetBytes([uint32]0x1040).CopyTo($file, $entry + 20)
        [BitConverter]::GetBytes([uint32]0x240).CopyTo($file, $entry + 24)
        $record.ToArray().CopyTo($file, 0x240)
    }
    [IO.File]::WriteAllBytes($Path, $file)
}

function New-SymbolsTestPdb {
    # A minimal MSF 7.00 container (512-byte blocks) with an empty stream 0 and
    # a PDB info stream carrying the GUID and age.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [guid] $Guid,
        [uint32] $Age = 1
    )

    $blockSize = 512
    $file = New-Object byte[] (7 * $blockSize)
    $magic = [Text.Encoding]::ASCII.GetBytes("Microsoft C/C++ MSF 7.00`r`n") + [byte[]](0x1A, 0x44, 0x53, 0, 0, 0)
    $magic.CopyTo($file, 0)
    foreach ($field in @(
        @{ At = 32; Value = $blockSize },   # block size
        @{ At = 36; Value = 1 },            # free block map
        @{ At = 40; Value = 7 },            # block count
        @{ At = 44; Value = 16 },           # stream directory bytes
        @{ At = 52; Value = 3 }             # block map address
    )) {
        [BitConverter]::GetBytes([uint32]$field.Value).CopyTo($file, $field.At)
    }
    [BitConverter]::GetBytes([uint32]4).CopyTo($file, 3 * $blockSize)          # block map: directory is block 4
    $directory = 4 * $blockSize
    [BitConverter]::GetBytes([uint32]2).CopyTo($file, $directory)              # two streams
    [BitConverter]::GetBytes([uint32]0).CopyTo($file, $directory + 4)          # stream 0 is empty
    [BitConverter]::GetBytes([uint32]28).CopyTo($file, $directory + 8)         # stream 1 is the info stream
    [BitConverter]::GetBytes([uint32]6).CopyTo($file, $directory + 12)         # ... in block 6
    $info = 6 * $blockSize
    [BitConverter]::GetBytes([uint32]20000404).CopyTo($file, $info)
    [BitConverter]::GetBytes([uint32]1).CopyTo($file, $info + 4)
    [BitConverter]::GetBytes($Age).CopyTo($file, $info + 8)
    $Guid.ToByteArray().CopyTo($file, $info + 12)
    [IO.File]::WriteAllBytes($Path, $file)
}

function Assert-SymbolsCheckRejects {
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [scriptblock] $Check
    )

    $message = $null
    try { & $Check | Out-Null } catch { $message = $_.Exception.Message }
    if ($null -eq $message) { throw "Symbols check accepted: $Label" }
    if ($message -notmatch $Pattern) { throw "Symbols check rejected '$Label' for the wrong reason: $message" }
}

$symbolsProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('noctty-symbols-contract-' + [Guid]::NewGuid().ToString('N'))
try {
    $payload = Join-Path $symbolsProbeRoot 'noctty'
    $symbols = Join-Path $symbolsProbeRoot 'symbols'
    [void][IO.Directory]::CreateDirectory($payload)
    [void][IO.Directory]::CreateDirectory($symbols)

    $guids = @{
        'noctty.pdb' = [guid]'5d6c9221-c4d6-a0f5-4c4c-44205044422e'
        'noctty-command.pdb' = [guid]'70e653e4-9f2a-4622-4c4c-44205044422e'
        'ghostty-vt.pdb' = [guid]'41a76387-36f3-935c-4c4c-44205044422e'
    }
    # The CodeView record carries the build machine's absolute path; only the
    # file name is looked up. ghostty-vt.dll stands for the placeholder the
    # portable ZIP carries (src/build/GhosttyVtStub.zig), whose CodeView
    # record names ghostty-vt.pdb; the doc comment on
    # portable_zip_carries_legacy_entries says what changes here when it goes.
    New-SymbolsTestPe -Path (Join-Path $payload 'noctty.exe') -PdbPath 'D:\a\noctty\.zig-cache\o\x\noctty.pdb' -Guid $guids['noctty.pdb'] -Age 1
    New-SymbolsTestPe -Path (Join-Path $payload 'noctty.com') -PdbPath 'D:\a\noctty\.zig-cache\o\y\noctty-command.pdb' -Guid $guids['noctty-command.pdb'] -Age 1
    New-SymbolsTestPe -Path (Join-Path $payload 'ghostty-vt.dll') -PdbPath 'ghostty-vt.pdb' -Guid $guids['ghostty-vt.pdb'] -Age 3
    New-SymbolsTestPe -Path (Join-Path $payload 'noctty-terminal-handoff-proxy.dll')   # no CodeView record
    foreach ($name in $guids.Keys) {
        New-SymbolsTestPdb -Path (Join-Path $symbols $name) -Guid $guids[$name] -Age $(if ($name -eq 'ghostty-vt.pdb') { 3 } else { 1 })
    }

    # Identity readers return exactly what was written.
    $exeIdentity = Get-PeCodeViewIdentity -Path (Join-Path $payload 'noctty.exe')
    if ($exeIdentity.Guid -ne $guids['noctty.pdb'] -or $exeIdentity.Age -ne 1 -or $exeIdentity.PdbName -cne 'noctty.pdb') {
        throw 'Get-PeCodeViewIdentity must return the GUID, age and PDB file name of the RSDS record.'
    }
    if ($null -ne (Get-PeCodeViewIdentity -Path (Join-Path $payload 'noctty-terminal-handoff-proxy.dll'))) {
        throw 'Get-PeCodeViewIdentity must return $null for a PE with no CodeView record.'
    }
    $pdbIdentity = Get-PdbIdentity -Path (Join-Path $symbols 'ghostty-vt.pdb')
    if ($pdbIdentity.Guid -ne $guids['ghostty-vt.pdb'] -or $pdbIdentity.Age -ne 3) {
        throw 'Get-PdbIdentity must return the GUID and age of the PDB info stream.'
    }
    # A real, Authenticode-signed system DLL: the reader works on shipped binaries, not just fixtures.
    $systemIdentity = Get-PeCodeViewIdentity -Path (Join-Path $env:SystemRoot 'System32\kernel32.dll')
    if ($null -eq $systemIdentity -or $systemIdentity.PdbName -notmatch '^kernel32\.pdb$' -or $systemIdentity.Guid -eq [guid]::Empty) {
        throw 'Get-PeCodeViewIdentity must read the CodeView record of a real Windows DLL.'
    }

    # Matching symbols are accepted and reported.
    $evidence = @(Assert-SymbolsMatchBinaries -SymbolsRoot $symbols -PayloadRoot $payload -Label 'Symbols test')
    if ($evidence.Count -ne 3 -or
        @($evidence | Where-Object { $_.Binary -ceq 'noctty.com' -and $_.Pdb -ceq 'noctty-command.pdb' }).Count -ne 1) {
        throw 'Matching symbols must be reported per binary, with noctty.com mapped to noctty-command.pdb.'
    }

    # Anything that is not a match is rejected.
    Assert-SymbolsCheckRejects -Label 'GUID mismatch' -Pattern 'does not match noctty\.exe' -Check {
        $other = Join-Path $symbolsProbeRoot 'other-guid'
        [void][IO.Directory]::CreateDirectory($other)
        foreach ($file in Get-ChildItem -LiteralPath $symbols) { Copy-Item -LiteralPath $file.FullName -Destination $other }
        New-SymbolsTestPdb -Path (Join-Path $other 'noctty.pdb') -Guid ([guid]'00000000-0000-0000-0000-000000000001') -Age 1
        Assert-SymbolsMatchBinaries -SymbolsRoot $other -PayloadRoot $payload -Label 'Symbols test'
    }
    Assert-SymbolsCheckRejects -Label 'age mismatch' -Pattern 'does not match ghostty-vt\.dll' -Check {
        $other = Join-Path $symbolsProbeRoot 'other-age'
        [void][IO.Directory]::CreateDirectory($other)
        foreach ($file in Get-ChildItem -LiteralPath $symbols) { Copy-Item -LiteralPath $file.FullName -Destination $other }
        New-SymbolsTestPdb -Path (Join-Path $other 'ghostty-vt.pdb') -Guid $guids['ghostty-vt.pdb'] -Age 2
        Assert-SymbolsMatchBinaries -SymbolsRoot $other -PayloadRoot $payload -Label 'Symbols test'
    }
    Assert-SymbolsCheckRejects -Label 'missing PDB' -Pattern 'has no noctty-command\.pdb' -Check {
        $other = Join-Path $symbolsProbeRoot 'missing'
        [void][IO.Directory]::CreateDirectory($other)
        foreach ($file in Get-ChildItem -LiteralPath $symbols | Where-Object { $_.Name -cne 'noctty-command.pdb' }) {
            Copy-Item -LiteralPath $file.FullName -Destination $other
        }
        Assert-SymbolsMatchBinaries -SymbolsRoot $other -PayloadRoot $payload -Label 'Symbols test'
    }
    Assert-SymbolsCheckRejects -Label 'extra file' -Pattern 'match no shipped binary: .*stray\.pdb' -Check {
        $other = Join-Path $symbolsProbeRoot 'extra'
        [void][IO.Directory]::CreateDirectory($other)
        foreach ($file in Get-ChildItem -LiteralPath $symbols) { Copy-Item -LiteralPath $file.FullName -Destination $other }
        New-SymbolsTestPdb -Path (Join-Path $other 'stray.pdb') -Guid ([guid]::NewGuid()) -Age 1
        Assert-SymbolsMatchBinaries -SymbolsRoot $other -PayloadRoot $payload -Label 'Symbols test'
    }
    Assert-SymbolsCheckRejects -Label 'stripped noctty.exe' -Pattern 'noctty\.exe carries no CodeView record' -Check {
        $other = Join-Path $symbolsProbeRoot 'stripped'
        [void][IO.Directory]::CreateDirectory($other)
        Copy-Item -LiteralPath $payload -Destination $other -Recurse
        New-SymbolsTestPe -Path (Join-Path $other 'noctty\noctty.exe')
        Assert-SymbolsMatchBinaries -SymbolsRoot $symbols -PayloadRoot (Join-Path $other 'noctty') -Label 'Symbols test'
    }
    Assert-SymbolsCheckRejects -Label 'PDB that is not an MSF container' -Pattern 'Not an MSF 7\.00 PDB' -Check {
        $junk = Join-Path $symbolsProbeRoot 'junk.pdb'
        [IO.File]::WriteAllBytes($junk, (New-Object byte[] 4096))
        Get-PdbIdentity -Path $junk
    }
    Assert-SymbolsCheckRejects -Label 'a PDB file name outside the allowed characters' -Pattern 'unexpected PDB file' -Check {
        $other = Join-Path $symbolsProbeRoot 'odd-name'
        [void][IO.Directory]::CreateDirectory($other)
        Copy-Item -LiteralPath $payload -Destination $other -Recurse
        New-SymbolsTestPe -Path (Join-Path $other 'noctty\noctty.exe') -PdbPath 'dir\evil name$.pdb' -Guid ([guid]::NewGuid())
        Assert-SymbolsMatchBinaries -SymbolsRoot $symbols -PayloadRoot (Join-Path $other 'noctty') -Label 'Symbols test'
    }

    # The shipped zip layout: one `symbols` folder, nothing beside it.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $goodZip = Join-Path $symbolsProbeRoot 'good-symbols.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($symbols, $goodZip, [IO.Compression.CompressionLevel]::Optimal, $true)
    $zipEvidence = @(Assert-SymbolsArchiveMatchesPortable `
        -SymbolsZip $goodZip `
        -PayloadRoot $payload `
        -ExtractRoot (Join-Path $symbolsProbeRoot 'unzip-good') `
        -Label 'Symbols zip test')
    if ($zipEvidence.Count -ne 3) { throw 'A well-formed symbols zip must verify against the portable payload.' }
    $flatZip = Join-Path $symbolsProbeRoot 'flat-symbols.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($symbols, $flatZip, [IO.Compression.CompressionLevel]::Optimal, $false)
    Assert-SymbolsCheckRejects -Label 'zip without the symbols folder' -Pattern 'exactly one top-level symbols folder' -Check {
        Assert-SymbolsArchiveMatchesPortable `
            -SymbolsZip $flatZip `
            -PayloadRoot $payload `
            -ExtractRoot (Join-Path $symbolsProbeRoot 'unzip-flat') `
            -Label 'Symbols zip test'
    }
}
finally {
    if ([IO.Directory]::Exists($symbolsProbeRoot)) {
        [IO.Directory]::Delete($symbolsProbeRoot, $true)
    }
}

# The runtime list the symbols check walks is the signed-PE list, so a newly
# shipped binary is covered by adding it once.
if ($symbolsVerificationText -notmatch '(?s)function Get-WindowsSymbolBinaryNames.*?Get-WindowsSignedRuntimePayloads') {
    throw 'The symbols check must derive its binary list from Get-WindowsSignedRuntimePayloads.'
}
