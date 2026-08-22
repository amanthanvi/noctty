# Getting started

Download, install, and set up noctty on Windows. You need Windows 10
or 11 on x64 or ARM64 and a GPU driver with OpenGL 4.3 or newer.

## 1. Install with a package manager

The quickest path. With WinGet:

```powershell
winget install AmanThanvi.noctty
```

Or with Scoop, from the project's own bucket:

```powershell
scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty
scoop install noctty/noctty
```

Both tracks point at the same GitHub Release assets and checksums.
Scoop also puts `noctty` on your PATH; WinGet does not, so the PATH
note at the end of step 2 applies to WinGet installs too. Either way,
you can continue at step 3.

## 2. Or download and install manually

Go to [Releases](https://github.com/amanthanvi/noctty/releases). The
current stable release is `1.3.123`, and `<arch>` is `x64` or `arm64`;
both architectures ship every asset:

- Installer: `noctty-<version>-windows-<arch>-setup.exe`
- Portable ZIP: `noctty-<version>-windows-<arch>-portable.zip`
- Checksums: `SHA256SUMS-windows-<arch>.txt`

The legacy `SHA256SUMS.txt` file remains an x64 compatibility alias.

### Verify a release

Verify every manual download before running or extracting it. These checks are
complementary: the checksum detects changed bytes, Authenticode plus the pinned
publisher key verifies the Windows signer, and the GitHub build-provenance
attestation binds the exact release bytes to this repository's release workflow.

First, download the artifact and its matching
`SHA256SUMS-windows-<arch>.txt`, then run:

```powershell
$artifact = (Resolve-Path '.\noctty-<version>-windows-<arch>-setup.exe').Path # or the portable ZIP
$checksums = (Resolve-Path '.\SHA256SUMS-windows-<arch>.txt').Path
$name = [IO.Path]::GetFileName($artifact)
$matches = @(Get-Content -LiteralPath $checksums | Where-Object {
    $_ -match ('^[0-9a-fA-F]{64} \*' + [regex]::Escape($name) + '$')
})
if ($matches.Count -ne 1) { throw "Expected one checksum for $name; found $($matches.Count)." }
$expected = ($matches[0] -split ' ', 2)[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "SHA-256 mismatch for $name." }
"SHA-256 verified: $actual"
```

If it does not match, stop; delete the artifact and download it again.

For v1.3.124 and later, verify GitHub build provenance for both the artifact and
the checksum file. This covers the portable ZIP container itself, not only the
binaries inside it. GitHub CLI 2.49.0 or later provides `gh attestation`:

```powershell
foreach ($path in @($artifact, $checksums)) {
    gh attestation verify $path --repo amanthanvi/noctty
    if ($LASTEXITCODE -ne 0) { throw "Missing or invalid build provenance for $path." }
}
```

Finally, verify Authenticode and the updater's publisher-key pin. Run this from
a noctty source checkout at the same release tag so the reviewed
`scripts/signing-trust.ps1` helper is available. For the installer, use:

```powershell
$signedFiles = @($artifact)
```

For the portable ZIP, use this instead:

```powershell
$extract = Join-Path ([IO.Path]::GetTempPath()) "noctty-verify-$([guid]::NewGuid().ToString('N'))"
Expand-Archive -LiteralPath $artifact -DestinationPath $extract
$signedFiles = @(
    (Join-Path $extract 'noctty/noctty.com'),
    (Join-Path $extract 'noctty/noctty.exe'),
    (Join-Path $extract 'noctty/ghostty-vt.dll')
)
```

Then run the signature and pin check:

```powershell
. .\scripts\signing-trust.ps1
$expectedPin = '671ec822c41f39b1d79c31d27169b37486333c008c7a038261b4fae53818ce2a'
foreach ($file in $signedFiles) {
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    if (-not $signature.SignerCertificate) { throw "No Authenticode signer: $file" }
    $accepted = $signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid
    if (-not $accepted -and
        $signature.SignerCertificate.Subject -eq $signature.SignerCertificate.Issuer -and
        (Test-SelfSignedTrustStatus -Signature $signature -Path $file)) {
        $accepted = $true
    }
    if (-not $accepted) { throw "Invalid Authenticode signature: $file ($($signature.Status))" }
    $actualPin = Get-CertificateSpkiSha256 -Certificate $signature.SignerCertificate
    if ($actualPin -ne $expectedPin) { throw "Unexpected publisher SPKI: $actualPin" }
}
"Authenticode and publisher SPKI verified for $($signedFiles.Count) file(s)."
```

[ADR 0005](adr/0005-pin-updater-publisher-public-keys.md) is the canonical pin
and rotation policy:

> The current release track pins the SPKI for the self-signed
> `CN=winghostty Local Dev Signing` certificate used from v1.3.117 onward:
> `671ec822c41f39b1d79c31d27169b37486333c008c7a038261b4fae53818ce2a`.

> Certificate renewal with the same key needs no application change. Key
> rotation requires an overlap release that trusts both the current and next
> public keys before release signing moves to the next key; a later release may
> remove the retired key.

### Installer

1. Check the hash first, then double-click
   `noctty-<version>-windows-<arch>-setup.exe`.
2. If SmartScreen says _"Windows protected your PC"_, click **More info**,
   then **Run anyway**. See the note below on why this warning appears.
3. Accept the MIT license and install.
4. Launch **noctty** from the Start menu.

### Portable

1. Extract the ZIP anywhere (for example, `C:\Tools\noctty\`).
2. Run `noctty.exe`. SmartScreen may show the same warning here.

Keep the whole extracted folder together: `noctty.exe` needs the
`share` folder next to it for themes, terminfo, and shell integration.

To keep config, state, and cache in that folder too, create an empty
`noctty.portable` file beside `noctty.exe`; extraction alone does not enable
portable mode. `portable.txt` and an existing `config.ghostty` regular file are
also recognized markers; directories and a bare file named `config` are not.

Neither the installer nor the portable ZIP adds `noctty` to your
PATH. The `noctty +...` commands below assume you've either added
the folder containing `noctty.exe` to PATH or are running them from
that folder.

### Code signing policy and the SmartScreen warning

Every release on the current release track is Authenticode-signed with the same
certificate. The certificate is self-signed, so Windows cannot chain it to a
publicly trusted publisher and SmartScreen warnings are expected. The portable
ZIP and every other published release asset also carry GitHub build-provenance
attestations starting with v1.3.124; provenance complements Authenticode but does
not make a self-signed certificate publicly trusted.

SmartScreen reputation accrues per file hash. Re-signing changes that hash, so
the re-signed binary starts building file-hash reputation again. Extended
Validation (EV) certificates no longer receive instant SmartScreen reputation;
Microsoft removed that behavior in 2024. See Microsoft's factual
[SmartScreen reputation guidance](https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation).

Be precise about what the checksum buys you before you click through. It
confirms the file arrived intact and matches what the release publishes,
which is worth checking every time. It is not proof of authorship: the
checksum file sits next to the installer, so whatever could replace one
could replace the other. The value that doesn't come from the release
page is the publisher key pinned in the updater and recorded in
[ADR 0005](adr/0005-pin-updater-publisher-public-keys.md). In-app
updates are checked against that pin and refuse an installer signed by
anything else, and `scripts/verify-published-release.ps1` checks a
published release the same way.

Moving to a publicly trusted signer is a user decision, not an automated repo
step. The two supported choices are:

- **SignPath Foundation:** free for qualifying open-source projects under its
  [published conditions](https://signpath.org/terms.html). If accepted, replace
  the PFX-based signing stage and `WINDOWS_CODESIGN_PFX_BASE64` secret with the
  SignPath signing-request action and a `SIGNPATH_API_TOKEN` secret; keep the
  returned signed files in the existing verification, packaging, Defender, and
  attestation path.
- **Purchased OV certificate:** if the provider supplies a CI-usable PFX,
  replace `WINDOWS_CODESIGN_PFX_BASE64` and
  `WINDOWS_CODESIGN_PFX_PASSWORD` with the new certificate and password. If the
  key is held by a hardware or cloud signing service, replace the PFX signing
  invocation with that provider's authenticated signing step while preserving
  the same signed-file outputs and downstream checks.

For either choice, follow ADR 0005 in order: first ship the new SPKI as an
overlap pin in a release signed by the current key; only then switch the signing
provider/key; remove the retired pin only after the overlap release is broadly
deployed. Set `WINDOWS_CODESIGN_TRUST_SELF_SIGNED=false`, configure
`WINDOWS_CODESIGN_TIMESTAMP_URL`, and require timestamping for every CA-issued
signature before publishing. Certificate acquisition, SignPath application and
approval, and any provider account setup remain maintainer actions outside this
repository.

## 3. First launch

On first launch, noctty creates `%LOCALAPPDATA%\noctty\` and
writes a config template at `%LOCALAPPDATA%\noctty\config.ghostty`
with inline syntax notes. It then picks a conservative default shell; you
can override that in your config (see step 6).

## 4. Set a font and theme

Open the config file:

```powershell
notepad "$env:LOCALAPPDATA\noctty\config.ghostty"
```

Add a few options:

```ini
font-family = JetBrains Mono
font-size   = 12
# Pick a theme from: noctty +list-themes
# Theme files are config files; only use themes from sources you trust.
theme       = Dracula
```

Save, then reload config without restarting: `Ctrl+Shift+,`

See every option with inline docs:

```powershell
noctty +show-config --default --docs | more
```

## 5. Keybindings

Defaults are Ctrl-based chords, mostly shared with Ghostty's non-macOS
defaults (pane focus on `Alt+Arrow` is a Windows-specific touch). The
ones you'll use daily:

| Action                   | Binding                         |
| ------------------------ | ------------------------------- |
| Copy                     | `Ctrl+Shift+C`                  |
| Paste                    | `Ctrl+Shift+V`                  |
| New tab                  | `Ctrl+Shift+T`                  |
| Close tab                | `Ctrl+Shift+W`                  |
| Next / previous tab      | `Ctrl+Tab` / `Ctrl+Shift+Tab`   |
| Split pane right         | `Ctrl+Shift+\`                  |
| Split pane down          | `Ctrl+Shift+E`                  |
| Move between panes       | `Alt+Arrow`                     |
| Command palette          | `Ctrl+Shift+P`                  |
| Start search             | `Ctrl+Shift+F`                  |
| Increase / decrease font | `Ctrl+=` / `Ctrl+-`             |
| Reload config            | `Ctrl+Shift+,`                  |

Full list:

```powershell
noctty +list-keybinds
```

`Ctrl+Shift+O` also splits right; `Ctrl+Shift+\` is the advertised
default because Narrator can reserve O-based commands.

Rebind anything with `keybind = <trigger>=<action>`:

```ini
keybind = ctrl+t=new_tab
keybind = ctrl+shift+r=reload_config
```

Keybind grammar (chords, `catch_all`, modifiers) is documented inline in
`noctty +show-config --default --docs`.

## 6. Pick your shell

noctty auto-detects installed Windows shells (PowerShell, `cmd`, Git
Bash, and WSL distributions) and exposes them through an in-app profile
picker. To pin a specific shell as your default instead, set it in your
config:

```ini
command = pwsh.exe
```

Any executable name on PATH works the same way. A full path does too,
but if it contains spaces, use the `direct:` form and quote it. A plain
value is handed to `cmd.exe /C`, which would stop reading at the first
space and look for `C:\Program`:

```ini
command = direct:"C:\Program Files\Git\bin\bash.exe"
```

WSL appears in the profile picker, but making it the default requires
an explicit opt-in:

```ini
command = wsl.exe
```

Why WSL is never the implicit default, plus other shell behavior
details, is explained in [windows.md](windows.md#shells).

## 7. Updates

Turn on update checks in your config:

```ini
auto-update = check
```

The updater checks GitHub Releases at most once every 24 hours and never
installs anything without you starting it. `auto-update = download` also
downloads and verifies the installer ahead of time; you still choose
when to install it. Verification details and `download`-mode behavior
are in [windows.md](windows.md#updates).

## 8. If something goes wrong

If configuration or saved session state prevents a normal launch, start
once with built-in defaults and no session restore:

```powershell
noctty --safe-mode
```

Crash dumps, if any, stay local under `%LOCALAPPDATA%\noctty\crash`.
Read them with `noctty +crash-report`. Recovery behavior,
crash-report details, and diagnostic bundles are covered in
[windows.md](windows.md#crash-reports-and-diagnostics).

## 9. Automate it

noctty has a local automation surface: `noctty +list-windows`
reports windows, tabs, and panes as JSON, and
`noctty +perform-action` invokes keybinding actions over IPC. The
full surface, including the actions it blocks, is documented in
[windows.md](windows.md#automation).

## 10. Uninstall

- Installer builds: _Settings → Apps → Installed apps → noctty →
  Uninstall_.
- Portable builds: delete the folder you extracted to.

Your config and any crash logs live under `%LOCALAPPDATA%\noctty\`
and are not removed by either path. Delete that folder manually for a
clean slate.

## Next steps

- [docs/status.md](status.md): what works, what's experimental, known
  caveats
- [docs/windows.md](windows.md): the Windows behavior reference; paths,
  shells, updates, automation, and troubleshooting
- [docs/windows-capability-matrix.md](windows-capability-matrix.md):
  row-by-row mapping against upstream Ghostty docs
- [HACKING.md](../HACKING.md): build, test, and runtime notes for
  developers
- [CONTRIBUTING.md](../CONTRIBUTING.md): how to submit changes
- [Discussions](https://github.com/amanthanvi/noctty/discussions):
  questions and feedback
