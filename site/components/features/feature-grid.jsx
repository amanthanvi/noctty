import { FeatureCard } from './feature-card.jsx';

const FEATURES = [
  { k: 'gpu', title: 'Smooth and GPU-accelerated', body: 'Fast, crisp terminal rendering in the Windows app shipping today.' },
  { k: 'native', title: 'Feels native on Windows', body: 'Tabs, splits, IME, drag-and-drop, and the details that make it feel like a real Windows app.' },
  { k: 'compat', title: 'Built on Ghostty', body: 'Winghostty keeps Ghostty\'s terminal core, then adds the Windows-native app layer around it.' },
  { k: 'config', title: 'Easy to make your own', body: 'Edit %LOCALAPPDATA%\\winghostty\\config.ghostty, reload changes live, and make Winghostty feel like yours.' },
  { k: 'libghostty', title: 'Your shells, ready to go', body: 'PowerShell, cmd, Git Bash, and opt-in WSL are easy to launch from the built-in profile picker.' },
  { k: 'oss', title: 'Open source, local-first', body: 'MIT-licensed, no telemetry, and updates stay notify-only instead of replacing binaries in the background.' },
];

export function FeatureGrid() {
  return (
    <div className="wg-feature-grid">
      {FEATURES.map((feature) => <FeatureCard key={feature.k} feature={feature} />)}
    </div>
  );
}
