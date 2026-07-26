export const REDUCED_MOTION_QUERY = '(prefers-reduced-motion: reduce)';

export function subscribeToMediaQuery(mediaQuery, onChange) {
  if (typeof mediaQuery?.addEventListener === 'function') {
    mediaQuery.addEventListener('change', onChange);
    return () => mediaQuery.removeEventListener('change', onChange);
  }
  if (typeof mediaQuery?.addListener === 'function') {
    mediaQuery.addListener(onChange);
    return () => mediaQuery.removeListener(onChange);
  }
  return () => {};
}

export function observeElementVisibility(Observer, element, onChange) {
  if (typeof Observer !== 'function' || !element) return () => {};
  const observer = new Observer(
    ([entry]) => onChange(Boolean(entry?.isIntersecting)),
    { threshold: 0.05 },
  );
  observer.observe(element);
  return () => observer.disconnect();
}
