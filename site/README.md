# noctty.com

Static site for `noctty.com`, deployed to Cloudflare Pages. Hand-written
HTML, one stylesheet, four small ES modules, no framework and no npm
dependencies.

| File              | Purpose                                                 |
| ----------------- | ------------------------------------------------------- |
| `index.html`      | Landing page                                            |
| `why-noctty.html` | Trust page: identity, measurements, verification        |
| `404.html`        | Not-found page                                          |
| `styles.css`      | Whole stylesheet, `nc-` prefixed classes                |
| `app.js`          | Theme toggle                                            |
| `version.js`      | Latest-release fetch for the version text               |
| `install.js`      | Clipboard copy for the install command                  |
| `terminal.js`     | Scripted terminal demo (also imported by the tests)     |
| `assets/`         | Favicon, self-hosted fonts, hero image, capture, social |
| `tests/`          | `node --test` units                                     |
| `_headers`        | Cloudflare Pages cache and security headers             |

## Editing

1. Edit the HTML, CSS, or JS.
2. Run `node scripts/build-site-assets.mjs` from the repo root. It rewrites
   the `?v=` cache keys and the CSP hash for the shared inline theme
   bootstrap, which must stay byte-identical on every page.
3. Run the checks:

```powershell
node --test site/tests/*.test.mjs
pwsh -File scripts/check-site-copy.ps1
pwsh -File scripts/check-release-copy.ps1
```

The copy checks fail on claims the project cannot back: package-manager
commands that are not published yet, DirectX wording for the terminal
renderer, wrong config paths, silent-update wording, parity claims, and any
cross-terminal performance claim. `tests/trust.test.mjs` pins the
trust page's stated limits so they cannot be softened by accident. Marketing
copy is checked against `README.md`, `docs/status.md`,
`docs/getting-started.md`, `docs/verify-release.md`, and the two migration
guides; when they disagree, tighten the site until the claim holds.

The CSP allows no inline event handlers and no third-party origins. Fonts
are self-hosted. The only outbound request is the GitHub Releases version
fetch.

## Design

Dark by default, because the use scene is a terminal at night; light is a
first-class state. Ink-indigo surfaces, moonlight-cream text, one periwinkle
accent, aurora green reserved for verified states. Space Grotesk for display,
Segoe UI Variable for body, JetBrains Mono for commands and keys. Both web
fonts are OFL-licensed, subsetted to Latin, and ship with their licenses.

Motion is limited to the terminal demo and one entrance on the trust page
hero; both stop under `prefers-reduced-motion`. `hero-sky.webp` and the
social card are generated images, cropped and darkened locally.
`app-window.webp` is a real capture of the app.

## Deployment

`.github/workflows/deploy-site.yml` owns production. It runs on every push
to `main`, on published stable releases, and on manual dispatch. Pull
requests never deploy. The workflow:

1. Runs the copy checks and the asset determinism check.
2. Builds the payload twice from an exact file allowlist
   (`scripts/build-site-payload.ps1`) and requires identical SHA-256
   manifests.
3. Deploys the payload to a canary branch, verifies Cloudflare's metadata,
   commit provenance, and every served byte, and checks the zone-level
   `www` redirect.
4. Deploys the same payload to `main` and verifies it again at the
   deployment URL and at `noctty.com`.

It needs the `cloudflare-pages-production` environment with
`CLOUDFLARE_API_TOKEN` (Account / Cloudflare Pages / Edit) and
`CLOUDFLARE_ACCOUNT_ID`. The Pages project is a Direct Upload project; there
is no `wrangler.toml`. The `www` to apex redirect is a zone-level rule, not a
`_redirects` file, because Pages cannot express a domain-level redirect there.

A failed production verification is not rolled back automatically, because
the Pages API has no compare-and-swap rollback. The run keeps redacted
evidence as an artifact; pick a known-good deployment in the Cloudflare
dashboard.

To build the payload locally:

```powershell
$root = Join-Path $env:TEMP noctty-site-payload
pwsh -File scripts/build-site-payload.ps1 `
  -OutputDirectory (Join-Path $root payload) `
  -ManifestPath (Join-Path $root payload.sha256)
```

The deployment scripts require PowerShell 7.3 or newer.
