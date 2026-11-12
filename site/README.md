# noctty.com

Static site for `noctty.com`, deployed to Cloudflare Pages. Hand-written
HTML, one stylesheet, four small ES modules, no framework and no npm
dependencies.

| File              | Purpose                                               |
| ----------------- | ----------------------------------------------------- |
| `index.html`      | Landing page                                          |
| `why-noctty.html` | About page: identity, measurements, verification      |
| `404.html`        | Not-found page                                        |
| `styles.css`      | Whole stylesheet, `nc-` prefixed classes              |
| `app.js`          | Theme toggle; 404 path text; sideways-scroll tracks   |
| `version.js`      | Latest-release fetch for the version text             |
| `install.js`      | Clipboard copy for install and verification commands  |
| `terminal.js`     | Scripted hero demo (also imported by the tests)       |
| `assets/`         | Favicon, self-hosted fonts, app captures, social card |
| `tests/`          | `node --test` units                                   |
| `_headers`        | Cloudflare Pages cache and security headers           |

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

The CSP allows no inline event handlers, and its only third-party origin is
`https://api.github.com` for the GitHub Releases version fetch, which is the
only outbound request. Fonts and images are self-hosted.

## Design

The page is chrome and the terminal is the content. Everything outside a
terminal window uses the shadcn zinc scale: the tokens at the top of
`styles.css` carry a light and a dark value through `light-dark()`. The only
color on the site is inside terminal windows, taken from noctty's default
colors (dark) and the GitHub Light Default theme (light). Light and dark
follow the visitor's system until they press the toggle, which then sticks.

Geist sets all text and JetBrains Mono sets commands and terminals. Both are
self-hosted, OFL-licensed, and ship with their licenses. `geist.woff2` is
`Geist-Variable` from the `geist` npm package 1.8.1, instanced to weights
400 to 600 and subset to Latin with fontTools, keeping its name records.
`OFL-Geist.txt` is `OFL.txt` from `vercel/geist-font`, whose copyright notice
is the one in the font; the npm package's own `LICENSE.txt` carries an older
notice.

Only the hero demo moves. It pauses off-screen and in hidden tabs, and under
`prefers-reduced-motion` it shows still frames that the step buttons switch
between. Its palette rows, their order and the status line copy what the app
showed for "split" in the captures. `tests/terminal.test.mjs` checks each
row's title, description, action and shown shortcut, the status format, and
every key chip on the landing page against `src/input/command.zig`,
`src/cli/testdata/default_keybinds_windows.txt` and
`src/apprt/win32/overlay_view.zig`; `tests/demo.test.mjs` runs the demo itself
against a fake DOM and a hand-advanced clock (pause, resume, step switches,
a hidden page, reduced motion); `tests/install.test.mjs` checks that each copy
button, on the landing page and in About's verification blocks, copies the
command shown beside it.

The demo window scales with its column down to a 12 px terminal font; below a
900 px column it holds that size at a fixed height (11 px under a 520 px
column, so a phone's split panes keep a usable width), its chrome text stays
at 12 px, and on a phone the step buttons sit under it as tabs with the
selected step explained below. Below a 980 px viewport the captures keep a 900 px width
(about 12 px text) and scroll sideways. Anything that scrolls sideways, a
capture or a command block, gets a 2 px track from `app.js` showing the part in
view, and is a tab stop only while it scrolls.

Commands read character for character: no ligatures outside terminal windows,
and they wrap only at spaces and `<wbr>`, with flags and file names kept whole
by `.nc-nobr` spans. A token wider than a phone line scrolls inside its block.

The `shot-*.webp` files are real captures of the app, one per theme, from a
build with renderer test tools on a private desktop: the panes come from the
app's own readback and the chrome from `PrintWindow`. The restored-session
shots come from a real restart of that copy with
`window-save-state-scrollback` set, each pane scrolled to the top. The
terminal content is staged (a demo repository with a placeholder author), and
the terminal shots are cropped to their top 600 rows. The social card,
`noctty-social.jpg`, is rendered from HTML around one of the captures.

## Deployment

The Pages project is a Direct Upload project: there is no `wrangler.toml`
and no Git-integrated build. `.github/workflows/deploy-site.yml` owns
production. It runs on every push to `main`, on published stable releases,
when a Release run completes, and on manual dispatch; pull requests do not
deploy.

Production takes a release copy only once GitHub has published that release,
because the site links the release's downloads. While `README.md` names a
version newer than the latest GitHub release (the release-copy merge, before
its Release run publishes), the run holds the deploy and says so in a notice
and in the job summary; the Release run's completion then deploys it. The
Release workflow publishes with `GITHUB_TOKEN`, and an event made with
`GITHUB_TOKEN` starts no workflow run, so `release: published` fires only for
a release a person publishes. The workflow:

1. Runs the site copy checks, the asset determinism check, the header
   contract, and the release copy check against the latest GitHub release,
   each in its own step.
2. Builds the payload twice from an exact file allowlist
   (`scripts/build-site-payload.ps1`) and requires identical SHA-256
   manifests.
3. Deploys the payload to a canary branch and verifies Cloudflare's
   metadata, commit provenance, and every served byte. The
   zone-owned `www` redirect is preflighted here, before anything reaches
   production.
4. Deploys the same payload to `main` and verifies it again at the
   deployment URL and at `noctty.com`.

It needs the `cloudflare-pages-production` environment with
`CLOUDFLARE_API_TOKEN` (Account / Cloudflare Pages / Edit) and
`CLOUDFLARE_ACCOUNT_ID`.

A failed production verification does not automatically roll back, because
the Pages API has no compare-and-swap rollback and an automated one could
overwrite a newer deployment. The run keeps redacted evidence as an
artifact; pick a known-good deployment in the Cloudflare dashboard.

The `www` to apex redirect is configured at the zone level (a Bulk Redirect
or Redirect Rule with path and query preserved), not in a `_redirects` file,
because Pages cannot express a domain-level redirect there. The
workflow verifies the zone-level 301.

To build the payload locally:

```powershell
$root = Join-Path $env:TEMP noctty-site-payload
pwsh -File scripts/build-site-payload.ps1 `
  -OutputDirectory (Join-Path $root payload) `
  -ManifestPath (Join-Path $root payload.sha256)
```

The deployment-only scripts require PowerShell 7.3 or newer and are
outside the Windows PowerShell 5.1 harness compatibility scope.
