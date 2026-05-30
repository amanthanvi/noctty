const COLOR_DOT_KEYS = ['red', 'green', 'blue', 'yellow'];
const { useState } = React;

export function ColorDots() {
  const [hoveredColor, setHoveredColor] = useState(null);

  return (
    <span className={`wg-color-dots${hoveredColor ? ` is-hovering-${hoveredColor}` : ''}`} aria-hidden="true">
      {COLOR_DOT_KEYS.map((key) => (
        <span
          key={key}
          className={`wg-color-dot wg-color-dot--${key}`}
          onPointerEnter={() => setHoveredColor(key)}
          onPointerLeave={() => setHoveredColor(null)}
        >
          <span className="wg-color-dot__bob">
            <span className="wg-color-dot__chip" />
          </span>
        </span>
      ))}
    </span>
  );
}
