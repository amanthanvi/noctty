import { WinghosttyWordmark } from '../mark/winghostty-wordmark.jsx';

export function Footer({ theme }) {
  return (
    <footer className="wg-footer">
      <div className="wg-footer__top">
        <WinghosttyWordmark size={20} theme={theme} />
        <div className="wg-footer__links">
          <a href="https://github.com/amanthanvi/winghostty" target="_blank" rel="noopener noreferrer">GitHub</a>
          <a href="https://github.com/amanthanvi/winghostty/releases" target="_blank" rel="noopener noreferrer">Releases</a>
          <a href="https://github.com/amanthanvi/winghostty/issues" target="_blank" rel="noopener noreferrer">Issues</a>
          <a href="https://ghostty.org" target="_blank" rel="noopener noreferrer">Upstream ↗</a>
        </div>
      </div>
      <div className="wg-footer__bottom">
        <span>
          Built on Ghostty&apos;s terminal core by Mitchell Hashimoto &amp; contributors. Win32 runtime by{' '}
          <a href="https://github.com/amanthanvi" target="_blank" rel="noopener noreferrer">@amanthanvi</a>.
        </span>
        <span>MIT · Not affiliated with upstream Ghostty</span>
      </div>
    </footer>
  );
}
