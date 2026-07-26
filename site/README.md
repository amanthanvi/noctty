# winghostty site

This directory is the Cloudflare Pages payload for `winghostty.com`.

The landing page intentionally follows the original `Winghostty Marketing Site.zip`
runtime shape:

- `index.html` - archive-derived page shell
- `bundle.js` - precompiled browser entrypoint used by the landing page
- `build.md` - notes from the original archive about the bundle workflow
- `components/` - archive JSX references kept for design/source parity
- `assets/` - SVG brand assets carried over from the archive
- `404.html`, `styles.css`, `app.js` - standalone static extras already present in this repo
- `_headers` - Cloudflare Pages cache and browser security policy

## Source of truth

Marketing copy in this directory must be checked against:

- [README.md](../README.md)
- [docs/status.md](../docs/status.md)
- [docs/getting-started.md](../docs/getting-started.md)

If those files and the site disagree, tighten the wording until the claim is defensible.

## Guardrails

From the repository root, run the copy checks before shipping site edits:

```powershell
pwsh -File scripts/check-site-copy.ps1
pwsh -File scripts/check-release-copy.ps1
```

The checks fail on known bad claims and regressions, including:

- package-manager install commands that are not officially published yet
- DirectX or D3D wording for the shipping Windows renderer
- wrong config-path variants under `%APPDATA%`
- silent-update wording or stale claims about missing signing
- parity overclaims

React UMD, Google Fonts (Bricolage Grotesque + JetBrains Mono), and the GitHub
Releases version fetch are intentional for the static Pages payload. After JSX
edits, run `node scripts/build-site-bundle.mjs` from the repo root.

## Cloudflare Pages

The existing `winghostty` project remains a Direct Upload Pages project. There
is no `wrangler.toml`, `wrangler.json`, or Git-integrated Pages build.

Production is owned by `.github/workflows/deploy-site.yml`. It runs for every
push to `main`, published stable releases, or an explicit manual dispatch;
pull requests do not deploy. The protected GitHub environment is
`cloudflare-pages-production` and must provide:

- `CLOUDFLARE_API_TOKEN` - a least-privilege token with Account / Cloudflare
  Pages / Edit for this account
- `CLOUDFLARE_ACCOUNT_ID` - the account identifier, stored as a secret so it is
  not copied into logs or provenance

For a push, the workflow checks out the immutable event SHA. Published
prereleases are ignored. For a published stable release, it checks out the
current `main` head and requires its baked-in release copy to match the
published tag and GitHub's public latest release. In both
cases, the resolved SHA must remain the exact clean `origin/main` head before
both deployment phases. Wrangler `4.114.0` installs in an isolated runner-temp
directory. The workflow builds an exact static-file allowlist twice and
requires identical, ordinally sorted SHA-256 manifests. That same payload is
uploaded first to a non-production canary branch and then to `main`; Cloudflare
API metadata, commit provenance, and every served byte are checked after each
upload. The zone-owned `www` redirect is preflighted before production, so
missing zone configuration cannot publish and then fail. Production
verification requires the exact HTML, fallback, static assets, cache policy,
and security headers at the immutable Pages deployment URL. At
`winghostty.com`, it separately verifies Pages API domain attachment, every
non-HTML static asset byte, and the static response cache and security headers.
Cloudflare can replace custom-domain HTML with a managed challenge, so the
provenance records canonical HTML as unverified. Challenge HTML is never
accepted as published site content.

The workflow does not automatically roll back a failed production verification:
the Pages API has no compare-and-swap rollback primitive, so an automated
rollback could overwrite a newer dashboard/API deployment. The failed run
retains redacted evidence for an operator to inspect before selecting a known
production deployment in Cloudflare's rollback UI.

`site/_redirects` is intentionally absent. Cloudflare Pages does not support a
domain-level `www` redirect in that file. Configure the permanent
`https://www.winghostty.com/*` to `https://winghostty.com/:splat` redirect at
the Cloudflare zone level (Bulk Redirect or Redirect Rule), with path and query
preservation. The deployment workflow verifies the zone-level 301.

The Pages custom domain is:

- `winghostty.com`

`site/_headers` keeps every response revalidated, including nested 404
fallbacks. Cloudflare Pages still serves ETags and handles its edge cache,
while browsers cannot retain stale routes or non-content-addressed assets
without validation. Its CSP allowlists the two current inline theme bootstraps and the
font stylesheet `onload` handler by exact SHA-256 hashes. `style-src` and
`style-src-attr` retain `unsafe-inline` because the current React UI emits
inline styles; removing that residual allowance requires a coordinated UI
refactor. Any inline-script or handler edit must update both the CSP hashes and
the flagship contract test.

To build the deploy payload locally:

```powershell
$root = Join-Path $env:TEMP winghostty-site-payload
pwsh -File scripts/build-site-payload.ps1 `
  -OutputDirectory (Join-Path $root payload) `
  -ManifestPath (Join-Path $root payload.sha256)
```

The four deployment-only scripts require PowerShell 7.3 or newer and are
intentionally outside the Windows PowerShell 5.1 harness compatibility scope.
The workflow and this runbook invoke them with `pwsh`.
