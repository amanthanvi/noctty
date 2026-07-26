import {
  observeElementVisibility,
  REDUCED_MOTION_QUERY,
  subscribeToMediaQuery,
} from './activity.js';

const { useEffect, useState } = React;

export function usePrefersReducedMotion() {
  const [reducedMotion, setReducedMotion] = useState(
    () => window.matchMedia?.(REDUCED_MOTION_QUERY).matches ?? false,
  );

  useEffect(() => {
    if (!window.matchMedia) return undefined;
    const mediaQuery = window.matchMedia(REDUCED_MOTION_QUERY);
    const onChange = (event) => setReducedMotion(event.matches);
    return subscribeToMediaQuery(mediaQuery, onChange);
  }, []);

  return reducedMotion;
}

export function useDemoActivity(terminalRef) {
  const [documentActive, setDocumentActive] = useState(() => !document.hidden);
  const [inViewport, setInViewport] = useState(true);

  useEffect(() => {
    const onVisibilityChange = () => setDocumentActive(!document.hidden);
    document.addEventListener('visibilitychange', onVisibilityChange);
    return () => document.removeEventListener('visibilitychange', onVisibilityChange);
  }, []);

  useEffect(
    () => observeElementVisibility(
      window.IntersectionObserver,
      terminalRef.current,
      setInViewport,
    ),
    [terminalRef],
  );

  return documentActive && inViewport;
}
