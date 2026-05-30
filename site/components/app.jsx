// Main app — theme, layout, page sections.

import { HeroColorPop } from './heroes.jsx';
import { SectionLabel } from './layout/section-label.jsx';
import { TopBar } from './layout/top-bar.jsx';
import { FeatureGrid, Footer, WhyFork } from './sections.jsx';

const { useEffect, useState } = React;
const EDIT_MODE_MESSAGE_TYPES = new Set(['__activate_edit_mode', '__deactivate_edit_mode']);

function getStoredTheme() {
  try {
    return localStorage.getItem('wg-theme') || 'dark';
  } catch (e) {
    return 'dark';
  }
}

function setStoredTheme(theme) {
  try {
    localStorage.setItem('wg-theme', theme);
  } catch (e) {}
}

function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
}

function getParentOrigin() {
  try {
    if (!document.referrer) return null;
    return new URL(document.referrer).origin;
  } catch (e) {
    return null;
  }
}

export function App() {
  const [theme, setTheme] = useState(getStoredTheme);

  const updateTheme = (nextTheme) => {
    setStoredTheme(nextTheme);
    applyTheme(nextTheme);
    setTheme(nextTheme);
  };

  useEffect(() => {
    const parentOrigin = getParentOrigin();
    const targetOrigin = parentOrigin || '*';
    const allowedOrigins = new Set([window.location.origin]);
    if (parentOrigin) allowedOrigins.add(parentOrigin);

    const onMessage = (e) => {
      const d = e.data || {};
      if (!EDIT_MODE_MESSAGE_TYPES.has(d.type)) return;
      if (!allowedOrigins.has(e.origin)) return;
      document.body.dataset.editMode = d.type === '__activate_edit_mode' ? 'on' : 'off';
    };
    window.addEventListener('message', onMessage);
    if (window.parent !== window) {
      window.parent.postMessage({ type: '__edit_mode_available' }, targetOrigin);
    }
    return () => window.removeEventListener('message', onMessage);
  }, []);

  return (
    <>
      <a className="wg-skip-link" href="#main-content">Skip to content</a>
      <TopBar theme={theme} setTheme={updateTheme} />
      <main id="main-content">
        <div className="wg-container wg-section wg-section--lead">
          <HeroColorPop />
        </div>

        <div
          className="wg-container wg-section wg-section--follow"
          data-accent="blue"
          style={{ contentVisibility: 'auto', containIntrinsicSize: 'auto 640px' }}
        >
          <SectionLabel num="01" title="What you get" />
          <FeatureGrid />
        </div>

        <div
          className="wg-container wg-section"
          data-accent="yellow"
          style={{ paddingTop: 32, paddingBottom: 48, contentVisibility: 'auto', containIntrinsicSize: 'auto 540px' }}
        >
          <SectionLabel num="02" title="Why a fork?" />
          <WhyFork />
        </div>

        <div className="wg-container" style={{ contentVisibility: 'auto', containIntrinsicSize: 'auto 220px' }}>
          <Footer theme={theme} />
        </div>
      </main>
    </>
  );
}
