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
- `_redirects` - canonical host redirect for `www` to apex

## Source of truth

Marketing copy in this directory must be checked against:

- [README.md](../README.md)
- [docs/status.md](../docs/status.md)
- [docs/getting-started.md](../docs/getting-started.md)

If those files and the site disagree, tighten the wording until the claim is defensible.

## Guardrails

Run the copy check before shipping site edits:

```powershell
pwsh -File scripts/check-site-copy.ps1
```

The check fails on known bad claims and regressions, including:

- package-manager install commands that are not officially published yet
- DirectX or D3D wording for the shipping Windows renderer
- wrong config-path variants under `%APPDATA%`
- silent-update or signed-release wording
- parity overclaims

React UMD, Google Fonts (Bricolage Grotesque + JetBrains Mono), and the GitHub
Releases version fetch are intentional for the static Pages payload. After JSX
edits, run `node scripts/build-site-bundle.mjs` from the repo root.

## Cloudflare Pages

Project settings for v1:

- Production branch: `main`
- Build command: `exit 0`
- Build output directory: `site`
- Custom domains: `winghostty.com` and `www.winghostty.com`

Recommended follow-up in Pages:

- Keep preview deployments enabled for PRs.
- Set build watch paths to `site/*` so app-only changes do not redeploy the marketing site.
