import { FEATURE_GLYPHS } from './feature-glyphs.jsx';

export function FeatureCard({ feature }) {
  return (
    <article className="wg-feature-card">
      <div className="wg-feature-card__glyph">{FEATURE_GLYPHS[feature.k]}</div>
      <h2>{feature.title}</h2>
      <p>{feature.body}</p>
    </article>
  );
}
