import { FEATURE_GLYPHS } from './feature-glyphs.jsx';

export function FeatureCard({ feature }) {
  const glyph = FEATURE_GLYPHS[feature.k] || FEATURE_GLYPHS.compat;

  return (
    <article className="wg-feature-card">
      <div className="wg-feature-card__glyph">{glyph}</div>
      <h2>{feature.title}</h2>
      <p>{feature.body}</p>
    </article>
  );
}
