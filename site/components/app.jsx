// Main app — theme, layout, page sections.

import { HeroColorPop } from './heroes.jsx';
import { SectionLabel } from './layout/section-label.jsx';
import { TopBar } from './layout/top-bar.jsx';
import { FeatureGrid, Footer, WhyFork } from './sections.jsx';

const { useEffect, useState } = React;

export function App() {
  const [theme, setTheme] = useState(() => localStorage.getItem('wg-theme') || 'dark');

  useEffect(() => {
    localStorage.setItem('wg-theme', theme);
  }, [theme]);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    document.body.dataset.theme = theme;
  }, [theme]);

  useEffect(() => {
    const allowedOrigin = window.location.origin;
    const onMessage = (e) => {
      if (e.origin !== allowedOrigin) return;
      const d = e.data || {};
      if (d.type === '__activate_edit_mode') document.body.dataset.editMode = 'on';
      if (d.type === '__deactivate_edit_mode') document.body.dataset.editMode = 'off';
    };
    window.addEventListener('message', onMessage);
    if (window.parent !== window) {
      window.parent.postMessage({ type: '__edit_mode_available' }, allowedOrigin);
    }
    return () => window.removeEventListener('message', onMessage);
  }, []);

  return (
    <>
      <a className="wg-skip-link" href="#main-content">Skip to content</a>
      <TopBar theme={theme} setTheme={setTheme} />
      <main id="main-content">
        <div className="wg-container wg-section wg-section--lead">
          <HeroColorPop />
        </div>

        <div
          className="wg-container wg-section wg-section--follow"
          data-accent="blue"
          style={{ contentVisibility: 'auto', containIntrinsicSize: '640px' }}
        >
          <SectionLabel num="01" title="What you get" />
          <FeatureGrid />
        </div>

        <div
          className="wg-container wg-section"
          data-accent="yellow"
          style={{ paddingTop: 32, paddingBottom: 48, contentVisibility: 'auto', containIntrinsicSize: '540px' }}
        >
          <SectionLabel num="02" title="Why a fork?" />
          <WhyFork />
        </div>

        <div className="wg-container" style={{ contentVisibility: 'auto', containIntrinsicSize: '220px' }}>
          <Footer theme={theme} />
        </div>
      </main>
    </>
  );
}
