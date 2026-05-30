const { useEffect, useRef, useState } = React;

export function WinghosttyToggle({ theme, onToggle, size = 22 }) {
  const [blinking, setBlinking] = useState(false);
  const blinkTimerRef = useRef(null);

  useEffect(() => () => {
    if (blinkTimerRef.current) clearTimeout(blinkTimerRef.current);
  }, []);

  const triggerBlink = () => {
    onToggle();
    if (blinking) return;
    setBlinking(true);
    if (blinkTimerRef.current) clearTimeout(blinkTimerRef.current);
    blinkTimerRef.current = setTimeout(() => {
      setBlinking(false);
      blinkTimerRef.current = null;
    }, 220);
  };

  return (
    <button
      type="button"
      className={`wg-theme-toggle${blinking ? ' is-blinking' : ''}`}
      onClick={triggerBlink}
      aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
      title={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
    >
      <svg width={size} height={(size * 32) / 27} viewBox="0 0 27 32" fill="none" aria-hidden="true">
        <path
          className="wg-theme-toggle__ghost"
          d="M20.4 30.59C19.28 30.59 18.18 30.21 17.32 29.51C17.16 29.39 17 29.36 16.9 29.36C16.72 29.36 16.55 29.43 16.41 29.54C15.55 30.22 14.46 30.6 13.36 30.6C12.26 30.6 11.18 30.22 10.32 29.54C10.18 29.43 10.01 29.37 9.85 29.37C9.68 29.37 9.51 29.43 9.37 29.54C8.51 30.22 7.47 30.59 6.36 30.6H6.33C5.02 30.6 3.78 30.07 2.84 29.11C1.92 28.17 1.41 26.93 1.41 25.62V13.37C1.41 6.77 6.77 1.41 13.36 1.41C19.95 1.41 25.32 6.77 25.32 13.36V25.62C25.32 28.26 23.28 30.44 20.67 30.59C20.58 30.59 20.49 30.59 20.4 30.59Z"
          fill="currentColor"
        />
        <g className="wg-theme-toggle__glyphs">
          <path
            className="wg-theme-toggle__glyph"
            d="M11.28 12.44L7.35 10.17C6.84 9.87 6.18 10.05 5.89 10.56C5.59 11.07 5.77 11.73 6.28 12.02L8.6 13.37L6.28 14.71C5.77 15 5.59 15.66 5.89 16.17C6.18 16.68 6.84 16.86 7.35 16.56L11.28 14.29C11.99 13.88 11.99 12.85 11.28 12.44V12.44Z"
            fill="var(--bg)"
          />
          <path
            className="wg-theme-toggle__glyph"
            d="M20.18 12.29H15.02C14.43 12.29 13.95 12.77 13.95 13.36C13.95 13.96 14.42 14.43 15.02 14.43H20.18C20.77 14.43 21.25 13.96 21.25 13.36C21.25 12.77 20.78 12.29 20.18 12.29Z"
            fill="var(--bg)"
          />
        </g>
      </svg>
    </button>
  );
}
