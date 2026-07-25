import { WinghosttyWordmark } from '../mark/winghostty-wordmark.jsx';

export function Footer({ theme }) {
  return (
    <footer className="wg-footer">
      <div className="wg-footer__top">
        <WinghosttyWordmark size={20} theme={theme} />
        <nav className="wg-footer__links" aria-label="Project links">
          <a href="https://github.com/amanthanvi/winghostty" target="_blank" rel="noopener noreferrer">GitHub</a>
          <a href="https://github.com/amanthanvi/winghostty/releases" target="_blank" rel="noopener noreferrer">Releases</a>
          <a href="https://github.com/amanthanvi/winghostty/discussions" target="_blank" rel="noopener noreferrer">Discussions</a>
          <a href="https://github.com/amanthanvi/winghostty/issues/new?template=bug_report.yml" target="_blank" rel="noopener noreferrer">Report bug</a>
          <a href="https://github.com/amanthanvi/winghostty/blob/main/docs/status.md" target="_blank" rel="noopener noreferrer">Status</a>
          <a href="https://github.com/amanthanvi/winghostty/blob/main/docs/getting-started.md" target="_blank" rel="noopener noreferrer">Getting started</a>
        </nav>
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
