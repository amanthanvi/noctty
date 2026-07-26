const COLOR_DOT_KEYS = ['red', 'green', 'blue', 'yellow'];

export function ColorDots() {
  return (
    <span className="wg-color-dots" aria-hidden="true">
      {COLOR_DOT_KEYS.map((key) => (
        <span key={key} className={`wg-color-dot wg-color-dot--${key}`}>
          <span className="wg-color-dot__chip" />
        </span>
      ))}
    </span>
  );
}
