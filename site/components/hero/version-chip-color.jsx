import { ColorDots } from './color-dots.jsx';

const { useEffect, useState } = React;
const DEFAULT_WG_VERSION = '1.3.120';
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
    return normalizeStableSemver(parsed.tag);
  } catch (e) {
    return null;
  }
}

function cacheVersion(tag) {
  try {
    sessionStorage.setItem(CACHE_KEY, JSON.stringify({ tag, ts: Date.now() }));
  } catch (e) {}
}

function normalizeStableSemver(value) {
  const match = String(value || '').match(/^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/);
  if (!match) return null;
  return `${Number(match[1])}.${Number(match[2])}.${Number(match[3])}`;
}

function compareSemver(a, b) {
  const leftVersion = normalizeStableSemver(a);
  const rightVersion = normalizeStableSemver(b);
  if (!leftVersion || !rightVersion) return null;
  const left = leftVersion.split('.').map(Number);
  const right = rightVersion.split('.').map(Number);

  for (let i = 0; i < 3; i += 1) {
    if (left[i] !== right[i]) return left[i] - right[i];
  }
  return 0;
}

function shouldPublishVersion(tag) {
  const normalizedTag = normalizeStableSemver(tag);
  const current = normalizeStableSemver(window.WG_VERSION) || DEFAULT_WG_VERSION;
  const currentBaseline = compareSemver(current, DEFAULT_WG_VERSION) >= 0
    ? current
    : DEFAULT_WG_VERSION;
  return normalizedTag !== null && compareSemver(normalizedTag, currentBaseline) > 0;
}

function publishVersion(tag) {
  const normalizedTag = normalizeStableSemver(tag);
  if (!normalizedTag || !shouldPublishVersion(normalizedTag)) return false;
  window.WG_VERSION = normalizedTag;
  window.dispatchEvent(new CustomEvent('wg-version-updated', { detail: { version: normalizedTag } }));
  return true;
}

async function fetchLatestVersion() {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), RELEASE_FETCH_TIMEOUT_MS);

  try {
    const res = await fetch(`https://api.github.com/repos/${WG_REPO}/releases/latest`, {
      signal: controller.signal,
    });
    if (res.status === 429 || res.status === 403) return;
    if (!res.ok) return;
    const data = await res.json();
    const tag = normalizeStableSemver(data.tag_name);
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
    const current = normalizeStableSemver(window.WG_VERSION) || DEFAULT_WG_VERSION;
    const cachedMatchesCurrent = compareSemver(cached, current) === 0;
    if (publishVersion(cached) || cachedMatchesCurrent) return;
  }

  const idle = window.requestIdleCallback || ((cb) => setTimeout(cb, 1500));
  idle(fetchLatestVersion, { timeout: RELEASE_FETCH_TIMEOUT_MS });
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
      <span className="wg-hero__badge-meta">Win 10/11 · x64 + ARM64</span>
      <span className="wg-hero__badge-sep" aria-hidden="true" />
      <span className="wg-hero__badge-stack">MIT · OpenGL 4.3</span>
    </span>
  );
}
