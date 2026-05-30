import { WinghosttyMark } from '../mark.jsx';

export function WinghosttyWordmark({ size = 28, theme = 'dark' }) {
  return (
    <span className="wg-wordmark">
      <WinghosttyMark size={size} theme={theme} />
      <span className="wg-wordmark__text" style={{ fontSize: size * 0.78 }}>Winghostty</span>
    </span>
  );
}
