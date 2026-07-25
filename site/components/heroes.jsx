// Hero — download-focused lead block.

import { InstallBlock } from './install/install-block.jsx';
import { VersionChipColor } from './hero/version-chip-color.jsx';
import { WinghosttyTerminal } from './terminal.jsx';

export function HeroColorPop() {
  return (
    <section className="wg-hero" id="download" aria-labelledby="hero-title">
      <div className="wg-hero-copy">
        <VersionChipColor />

        <div className="wg-hero__intro">
          <h1 className="wg-hero__title" id="hero-title">
            Ghostty<span className="wg-accent-red">,</span>
            <br className="wg-hero__mobile-break" /> finally
            <br />{' '}
            on Windows<span className="wg-accent-blue">.</span>
          </h1>
          <p className="wg-hero__caption">
            Winghostty pairs Ghostty&apos;s terminal core with a native Win32 app for tabs, splits,
            profiles, session restoration, native settings, and a keyboard-driven universal palette.
          </p>
        </div>

        <div className="wg-hero__actions">
          <a
            className="wg-button wg-button--primary"
            href="https://github.com/amanthanvi/winghostty/releases/latest"
            target="_blank"
            rel="noreferrer"
          >
            Download latest ↗
          </a>
          <InstallBlock />
        </div>

        <div className="wg-hero__terminal">
          <WinghosttyTerminal height={null} />
        </div>
      </div>
    </section>
  );
}
