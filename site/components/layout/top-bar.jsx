import { WinghosttyToggle } from '../mark/winghostty-toggle.jsx';
import { WinghosttyWordmark } from '../mark/winghostty-wordmark.jsx';

export function TopBar({ theme, setTheme }) {
  return (
    <header className="wg-topbar">
      <div className="wg-container wg-topbar__inner">
        <a href="/" className="wg-wordmark-link" aria-label="Winghostty home">
          <WinghosttyWordmark size={24} theme={theme} />
        </a>
        <WinghosttyToggle theme={theme} onToggle={() => setTheme(theme === 'dark' ? 'light' : 'dark')} />
      </div>
    </header>
  );
}
