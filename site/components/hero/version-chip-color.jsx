import { ColorDots } from './color-dots.jsx';

const { useEffect, useState } = React;
const DEFAULT_WG_VERSION = '1.3.106';

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
