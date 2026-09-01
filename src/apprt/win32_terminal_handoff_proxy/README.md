# Terminal handoff proxy/stub

`ITerminalHandoff.idl` is copied from Microsoft Terminal commit
`20588130d8ef2ba40eb56bdae88e04cce7fc5b5d` at
`src/host/proxy/ITerminalHandoff.idl` under that repository's MIT license.

The checked-in `x64/` and `arm64/` C sources are generated with Windows SDK
10.0.26100.0. MIDL is not part of the noctty build. To regenerate them from a
PowerShell prompt at the repository root:

```powershell
$sdk = 'C:\Program Files (x86)\Windows Kits\10'
$version = '10.0.26100.0'
$source = 'src\apprt\win32_terminal_handoff_proxy\ITerminalHandoff.idl'
foreach ($arch in @('x64', 'arm64')) {
    $output = "src\apprt\win32_terminal_handoff_proxy\$arch"
    & "$sdk\bin\$version\x64\midl.exe" /nologo /env $arch /target NT100 /robust `
        /I "$sdk\Include\$version\shared" /I "$sdk\Include\$version\um" `
        /out $output /h ITerminalHandoff.h /iid ITerminalHandoff_i.c `
        /proxy ITerminalHandoff_p.c /dlldata dlldata.c $source
    if ($LASTEXITCODE -ne 0) { throw "MIDL failed for $arch" }
}
```

All eight generated files carry a `Mon Jan 18 22:14:07 2038` MIDL timestamp.
That is `INT32_MAX` seconds interpreted in UTC-5, it is identical across every
file, and it is a property of the generator rather than a sign of tampering.

The permanent noctty proxy CLSID is supplied by `src/build/TerminalHandoffProxy.zig` as
`{1D349824-21FB-46C7-ACF3-746EDC991D52}`. Never regenerate it. `exports.c` is
the single source of the five DLL exports, expressed as linker pragmas because
Zig 0.15.2 does not accept a module-definition file as a link input. It carries
the same exports as Microsoft's `OpenConsoleProxy.def`; no parallel `.def` is
kept here, so the two lists cannot drift.