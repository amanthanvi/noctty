import { FeatureCard } from './feature-card.jsx';

const FEATURES = [
  { k: 'gpu', title: 'Fast terminal rendering', body: 'Ghostty’s terminal core renders through OpenGL 4.3+ via WGL, with native Windows chrome kept on a separate pipeline.' },
  { k: 'native', title: 'A native Windows workspace', body: 'Tabs, horizontal and vertical splits, IME, drag-and-drop, profiles, and Windows conventions on x64 and ARM64.' },
  { k: 'compat', title: 'Session restoration', body: 'Bring back windows, tabs, split layouts, profiles, working directories, and explicit titles after a restart.' },
  { k: 'config', title: 'Native settings', body: 'Stage and save changes across Appearance, Terminal, Shell, Privacy, Updates, Keybindings, and Advanced without rewriting unrelated config text.' },
  { k: 'libghostty', title: 'Universal palette', body: 'Find actions, tabs, panes, profiles, themes, and native settings from one fuzzy-searched, keyboard-driven list.' },
  { k: 'oss', title: 'Signed, user-controlled updates', body: 'Download mode stages installer releases only after SHA-256 and Authenticode verification. You choose when to install.' },
];

export function FeatureGrid() {
  return (
    <div className="wg-feature-grid">
      {FEATURES.map((feature) => <FeatureCard key={feature.k} feature={feature} />)}
    </div>
  );
}
