# Build notes

The site ships **precompiled JSX** as `bundle.js` so the browser doesn't have to
load Babel-standalone (~1MB) and transpile at runtime. This is the single biggest
performance win.

## Source layout

- `main.jsx` — browser entrypoint for React.
- `components/**/*.jsx` — editable JSX source.
- `bundle.js` — esbuild output. **This is what the browser loads.**
- `index.html` — references `bundle.js` directly.

## When to rebuild

Whenever you change `main.jsx` or anything in `components/**/*.jsx`, regenerate
`bundle.js`. `bundle.js` is the shipped runtime, and the JSX source should stay
in sync with it.

## How to rebuild from `components/*.jsx`

From the repo root:

```powershell
node scripts/build-site-bundle.mjs
```

This bundles `site/main.jsx` and its imported JSX modules via the pinned local
esbuild dependency. Bump the `bundle.js?v=...` and `styles.css?v=...` queries in
`index.html` when you want to bust CDN/browser caches.

## Legacy: rebuild from inline JSX in the browser

If you want to author in JSX again, paste your JSX into a temporary
`<script type="text/babel">` block and run this in `run_script`:

```js
const html = await readFile('index.html');
const m = html.match(/<script type="text\/babel"[^>]*>([\s\S]*?)<\/script>/);
const jsx = m[1];

await new Promise((resolve, reject) => {
  const s = document.createElement('script');
  s.src = 'https://unpkg.com/@babel/standalone@7.29.0/babel.min.js';
  s.onload = resolve; s.onerror = reject;
  document.head.appendChild(s);
});

const out = window.Babel.transform(jsx, {
  presets: [['react', { development: false }]],
}).code;

await saveFile('bundle.js', out);
```

## Other perf tweaks already in place

- **React production builds** (UMD `.production.min.js`).
- **Deferred scripts** so HTML parses first, then JS runs in order.
- **Lazy + cached GitHub fetch** — version check runs in `requestIdleCallback`,
  cached in `sessionStorage` for 30 minutes.
- **Font subset** — only weights actually used (display 500/600/700, mono 400/500).
- **Non-blocking font load** via `media="print"` swap, with a `<noscript>` fallback.
- **Inline theme bootstrap** in `<head>` to prevent FOUC on theme flip.
