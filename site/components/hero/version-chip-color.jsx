import { ColorDots } from './color-dots.jsx';

const { useEffect, useState } = React;
const DEFAULT_WG_VERSION = '1.3.106';
const WG_REPO = 'amanthanvi/winghostty';
const CACHE_KEY = 'wg-latest-release-v1';
const CACHE_TTL_MS = 30 * 60 * 1000;
const RELEASE_FETCH_TIMEOUT_MS = 4000;

function readCachedVersion() {
  try {
    const cached = sessionStorage.getItem(CACHE_KEY);
    if (!cached) return null;
    const parsed = JSON.parse(cached);
    if (!parsed?.tag || Date.now() - parsed.ts > CACHE_TTL_MS) return null;
    return parsed.tag;
  } catch (e) {
    return null;
  }
}

function cacheVersion(tag) {
  try {
    sessionStorage.setItem(CACHE_KEY, JSON.stringify({ tag, ts: Date.now() }));
  } catch (e) {}
}

function publishVersion(tag) {
  if (!tag || tag === window.WG_VERSION) return;
  window.WG_VERSION = tag;
  window.dispatchEvent(new CustomEvent('wg-version-updated', { detail: { version: tag } }));
}

async function fetchLatestVersion() {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), RELEASE_FETCH_TIMEOUT_MS);

  try {
    const res = await fetch(`https://api.github.com/repos/${WG_REPO}/releases/latest`, {
      signal: controller.signal,
    });
    if (!res.ok) return;
    const data = await res.json();
    const tag = String(data.tag_name || '').replace(/^v/, '');
    if (!tag) return;
    cacheVersion(tag);
    publishVersion(tag);
  } catch (e) {
  } finally {
    clearTimeout(timeoutId);
  }
}

function scheduleLatestVersionFetch() {
  const cached = readCachedVersion();
  if (cached) {
    publishVersion(cached);
    return;
  }

  const idle = window.requestIdleCallback || ((cb) => setTimeout(cb, 1500));
  idle(fetchLatestVersion);
}

if (typeof window !== 'undefined') {
  window.WG_VERSION = window.WG_VERSION || DEFAULT_WG_VERSION;
  scheduleLatestVersionFetch();
}

function useLiveVersion() {
  const [v, setV] = useState(() => (typeof window !== 'undefined' && window.WG_VERSION) || DEFAULT_WG_VERSION);

  useEffect(() => {
    const onUpdate = (e) => {
      const newV = e?.detail?.version || window.WG_VERSION || DEFAULT_WG_VERSION;
      setV(newV);
    };
    window.addEventListener('wg-version-updated', onUpdate);
    return () => window.removeEventListener('wg-version-updated', onUpdate);
  }, []);

  return v;
}

export function VersionChipColor() {
  const v = useLiveVersion();
  return (
    <span className="wg-hero__badge">
      <ColorDots />
      <span className="wg-hero__badge-version">{`v${v}`}</span>
      <span className="wg-hero__badge-latest">latest</span>
      <span className="wg-hero__badge-sep" aria-hidden="true" />
      <span className="wg-hero__badge-meta">Win 10/11 · x64 · ARM64</span>
      <span className="wg-hero__badge-sep" aria-hidden="true" />
      <span className="wg-hero__badge-stack">MIT · OpenGL 4.3</span>
    </span>
  );
}
