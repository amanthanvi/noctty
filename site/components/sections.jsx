// Shared page sections: install block, feature cards, why-fork, community, footer.

const { useState: useStateShared, useRef: useRefShared } = React;

function InstallBlock({ theme = 'dark' }) {
  const [copied, setCopied] = useStateShared(false);
  const cmd = 'winget install AmanThanvi.winghostty';
  const copyCmd = 'winget install AmanThanvi.winghostty\r\nscoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty\r\nscoop install winghostty/winghostty';
  const onCopy = () => {
    navigator.clipboard?.writeText(copyCmd).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    });
  };
  const C = theme === 'dark' ? {
    bg: '#111113', border: '#26262a', fg: '#e5e5e5', dim: '#707078', btnBg: '#1c1c20', btnHover: '#26262a',
  } : {
    bg: '#ffffff', border: '#e4e4e2', fg: '#0a0a0a', dim: '#6a6a68', btnBg: '#f3f3f1', btnHover: '#e8e8e6',
  };
  return (
    <div
      className="wg-install"
      style={{
        display: 'inline-flex', alignItems: 'stretch', gap: 0,
        background: C.bg, border: `1px solid ${C.border}`, borderRadius: 10,
        fontFamily: 'var(--mono)', fontSize: 14, overflow: 'hidden',
        height: 46,
      }}>
      <span style={{ display: 'flex', alignItems: 'center', padding: '0 4px 0 16px', color: C.dim, userSelect: 'none' }}>{String.fromCharCode(36)}</span>
      <span style={{ display: 'flex', alignItems: 'center', padding: '0 16px 0 8px', color: C.fg, whiteSpace: 'nowrap' }}>{cmd}</span>
      <button
        onClick={onCopy}
        style={{
          background: C.btnBg, border: 'none', borderLeft: `1px solid ${C.border}`,
          padding: '0 16px', color: C.fg, fontFamily: 'inherit', fontSize: 13,
          cursor: 'pointer', minWidth: 88, transition: 'background 0.12s',
        }}
        onMouseEnter={(e) => (e.currentTarget.style.background = C.btnHover)}
        onMouseLeave={(e) => (e.currentTarget.style.background = C.btnBg)}
      >
        {copied ? '✓ copied' : 'copy'}
      </button>
    </div>
  );
}

// Small ASCII-style glyph for each feature card — monochrome, geometric.
const FEATURE_GLYPHS = {
  gpu: (
    <svg viewBox="0 0 40 40" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.25">
      <rect x="6" y="6" width="28" height="28" rx="1.5" />
      <path d="M11 13 L16 20 L11 27 M18 13 L23 20 L18 27 M25 13 L30 20 L25 27" />
    </svg>
  ),
  native: (
    <svg viewBox="0 0 40 40" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.25">
      <rect x="5" y="5" width="30" height="30" rx="1.5" />
      <path d="M5 11 L35 11" />
      <circle cx="9" cy="8" r="0.9" fill="currentColor" stroke="none" />
      <circle cx="12" cy="8" r="0.9" fill="currentColor" stroke="none" />
      <circle cx="15" cy="8" r="0.9" fill="currentColor" stroke="none" />
    </svg>
  ),
  compat: (
    <svg viewBox="0 0 40 40" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.25">
      <path d="M8 14 L12 20 L8 26" />
      <path d="M16 28 L24 28" />
      <rect x="28" y="10" width="6" height="20" rx="0.6" />
    </svg>
  ),
  config: (
    <svg viewBox="0 0 40 40" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.25">
      <rect x="7" y="7" width="26" height="26" rx="1.5" />
      <path d="M12 14 L22 14 M12 20 L28 20 M12 26 L18 26" />
    </svg>
  ),
  libghostty: (
    <svg viewBox="0 0 40 40" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.25">
      <path d="M20 6 L32 12 L32 24 L20 30 L8 24 L8 12 Z" />
      <path d="M20 6 L20 30 M8 12 L32 12 M8 24 L32 24" strokeOpacity="0.5" />
    </svg>
  ),
  oss: (
    <svg viewBox="0 0 40 40" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.25">
      <circle cx="20" cy="20" r="12" />
      <path d="M8 20 L32 20 M20 8 L20 32 M11 11 L29 29 M29 11 L11 29" strokeOpacity="0.35" />
    </svg>
  ),
};

const FEATURES = [
  { k: 'gpu', title: 'Smooth and GPU-accelerated', body: 'Fast, crisp terminal rendering in the Windows app shipping today.' },
  { k: 'native', title: 'Feels native on Windows', body: 'Tabs, splits, IME, drag-and-drop, and the details that make it feel like a real Windows app.' },
  { k: 'compat', title: 'Built on Ghostty', body: 'Winghostty keeps Ghostty\'s terminal core, then adds the Windows-native app layer around it.' },
  { k: 'config', title: 'Easy to make your own', body: 'Edit %LOCALAPPDATA%\\winghostty\\config.ghostty, reload changes live, and make Winghostty feel like yours.' },
  { k: 'libghostty', title: 'Your shells, ready to go', body: 'PowerShell, cmd, Git Bash, and opt-in WSL are easy to launch from the built-in profile picker.' },
  { k: 'oss', title: 'Open source, local-first', body: 'MIT-licensed, no telemetry, and updates stay notify-only instead of replacing binaries in the background.' },
];

function FeatureCard({ feature, theme }) {
  const [hover, setHover] = useStateShared(false);
  const C = theme === 'dark' ? {
    bg: hover ? '#141416' : '#101012',
    border: hover ? '#36363c' : '#1e1e22',
    fg: '#e5e5e5', dim: '#8a8a92', glyph: '#d4d4d8',
  } : {
    bg: hover ? '#ffffff' : '#fafaf9',
    border: hover ? '#c8c8c6' : '#e4e4e2',
    fg: '#0a0a0a', dim: '#6a6a68', glyph: '#1a1a1a',
  };
  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        background: C.bg, border: `1px solid ${C.border}`, borderRadius: 10,
        padding: '22px 22px 24px', transition: 'background 0.18s, border-color 0.18s, transform 0.18s',
        transform: hover ? 'translateY(-2px)' : 'translateY(0)',
        cursor: 'default',
      }}>
      <div style={{ color: C.glyph, marginBottom: 14, transition: 'color 0.18s' }}>
        {FEATURE_GLYPHS[feature.k]}
      </div>
      <div style={{ color: C.fg, fontSize: 15, fontWeight: 500, marginBottom: 6, letterSpacing: '-0.01em' }}>
        {feature.title}
      </div>
      <div style={{ color: C.dim, fontSize: 13.5, lineHeight: 1.5 }}>
        {feature.body}
      </div>
    </div>
  );
}

function FeatureGrid({ theme }) {
  return (
    <div className="wg-feature-grid">
      {FEATURES.map((f) => <FeatureCard key={f.k} feature={f} theme={theme} />)}
    </div>
  );
}

// Why Windows? — a two-column block with a small Q&A pattern.
const WHY_ITEMS = [
  {
    q: 'Why a fork instead of upstream?',
    a: 'Ghostty does not ship a Windows app today. Winghostty keeps the Ghostty core and builds the Windows-native experience around it.',
  },
  {
    q: 'How close is it to Ghostty?',
    a: 'Close where it matters: the terminal core is shared, while the app layer around it is purpose-built for Windows.',
  },
  {
    q: 'Is it ready to use?',
    a: 'Winghostty is young, with first public releases on April 16, 2026, but it is already usable if you are comfortable running a fast-moving project.',
  },
  {
    q: 'What platforms is this for?',
    a: 'Windows 10 and Windows 11 on x64. This fork is focused on shipping a native Windows app.',
  },
  {
    q: 'Anything to know before installing?',
    a: 'Yes. Releases are signed, but Windows SmartScreen can still warn while publisher reputation is new.',
  },
  {
    q: 'Does it phone home?',
    a: 'No telemetry or analytics. The updater only checks GitHub for new releases and stays notify-only.',
  },
];

function WhyFork({ theme }) {
  const C = theme === 'dark' ? {
    fg: '#e5e5e5', dim: '#8a8a92', rule: '#1e1e22', label: '#707078',
  } : {
    fg: '#0a0a0a', dim: '#4a4a48', rule: '#d8d8d6', label: '#6a6a68',
  };
  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: 'repeat(2, minmax(0, 1fr))',
      gap: '14px 28px',
      borderTop: `1px solid ${C.rule}`,
      paddingTop: 18,
    }}
    className="wg-why-grid">
      {WHY_ITEMS.map((item, i) => (
        <div key={i} style={{
          display: 'flex', gap: 14, alignItems: 'baseline',
          padding: '2px 0',
        }}>
          <span style={{
            fontFamily: 'var(--mono)', fontSize: 11, color: C.label,
            letterSpacing: '0.12em', flexShrink: 0, paddingTop: 2,
          }}>
            {String(i + 1).padStart(2, '0')}
          </span>
          <div>
            <div style={{ color: C.fg, fontSize: 15, fontWeight: 500, letterSpacing: '-0.005em', marginBottom: 2 }}>
              {item.q}
            </div>
            <div style={{ color: C.dim, fontSize: 13.5, lineHeight: 1.5 }}>
              {item.a}
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}

// Community section
function Community({ theme }) {
  const C = theme === 'dark' ? {
    fg: '#e5e5e5', dim: '#8a8a92', border: '#26262a', bg: '#101012', hover: '#141416',
  } : {
    fg: '#0a0a0a', dim: '#6a6a68', border: '#e4e4e2', bg: '#fafaf9', hover: '#ffffff',
  };
  const items = [
    { label: 'Source and releases', sub: 'code, downloads, release notes', href: 'https://github.com/amanthanvi/winghostty' },
    { label: 'Report a bug', sub: 'issues are for reproducible problems', href: 'https://github.com/amanthanvi/winghostty/issues' },
    { label: 'Upstream Ghostty', sub: 'the project this fork builds on', href: 'https://ghostty.org' },
    { label: 'Contribute', sub: 'docs, patches, and ways to help', href: 'https://github.com/amanthanvi/winghostty#contributing' },
  ];
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 16,
    }}>
      {items.map((it, i) => (
        <a key={i} href={it.href} target="_blank" rel="noreferrer"
          className="wg-community-card"
          style={{
            display: 'block', padding: '24px 24px', background: C.bg,
            border: `1px solid ${C.border}`, borderRadius: 10, textDecoration: 'none',
            transition: 'background 0.18s, transform 0.18s, border-color 0.18s',
          }}
          onMouseEnter={(e) => { e.currentTarget.style.background = C.hover; e.currentTarget.style.transform = 'translateY(-2px)'; }}
          onMouseLeave={(e) => { e.currentTarget.style.background = C.bg; e.currentTarget.style.transform = 'translateY(0)'; }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 10 }}>
            <div style={{ color: C.fg, fontSize: 16, fontWeight: 500 }}>{it.label}</div>
            <div style={{ color: C.dim, fontSize: 14 }}>↗</div>
          </div>
          <div style={{ color: C.dim, fontFamily: 'var(--mono)', fontSize: 12 }}>{it.sub}</div>
        </a>
      ))}
    </div>
  );
}

function Footer({ theme }) {
  const C = theme === 'dark' ? {
    fg: '#e5e5e5', dim: '#707078', rule: '#1e1e22',
  } : {
    fg: '#0a0a0a', dim: '#6a6a68', rule: '#d8d8d6',
  };
  return (
    <footer style={{ borderTop: `1px solid ${C.rule}`, paddingTop: 28, paddingBottom: 40, marginTop: 32 }}>
      <div style={{
        display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: 20, alignItems: 'center',
      }}>
        <WinghosttyWordmark size={20} theme={theme} />
        <div style={{ display: 'flex', gap: 22, flexWrap: 'wrap', fontFamily: 'var(--mono)', fontSize: 12 }}>
          <a href="https://github.com/amanthanvi/winghostty" target="_blank" rel="noreferrer" style={{ color: C.fg, textDecoration: 'none' }}>GitHub</a>
          <a href="https://github.com/amanthanvi/winghostty/releases" target="_blank" rel="noreferrer" style={{ color: C.fg, textDecoration: 'none' }}>Releases</a>
          <a href="https://github.com/amanthanvi/winghostty/issues" target="_blank" rel="noreferrer" style={{ color: C.fg, textDecoration: 'none' }}>Issues</a>
          <a href="https://ghostty.org" target="_blank" rel="noreferrer" style={{ color: C.fg, textDecoration: 'none' }}>Upstream ↗</a>
        </div>
      </div>
      <div style={{
        marginTop: 22, display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12,
        color: C.dim, fontFamily: 'var(--mono)', fontSize: 11,
      }}>
        <span>Built on Ghostty's terminal core by Mitchell Hashimoto &amp; contributors. Win32 runtime by <a href="https://github.com/amanthanvi" style={{ color: C.fg, textDecoration: 'none' }}>@amanthanvi</a>.</span>
        <span>MIT · Not affiliated with upstream Ghostty</span>
      </div>
    </footer>
  );
}

function FooterCol() { return null; } // legacy stub, no longer used

Object.assign(window, {
  InstallBlock, FeatureGrid, FeatureCard, WhyFork, Community, Footer,
});
