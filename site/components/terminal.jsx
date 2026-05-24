// Mock terminal window with typewriter animation
// Uses React hooks. Exposes WinghosttyTerminal to window.

const { useState, useEffect, useRef, useMemo } = React;

// Latest release version — single source of truth.
// Default value is overridden at runtime by fetching GitHub Releases (see below).
let WG_VERSION = '1.3.106';
const WG_REPO = 'amanthanvi/winghostty';
const WG_RELEASE_URL = () => `https://github.com/${WG_REPO}/releases/tag/v${WG_VERSION}`;

// Build the cycling script for a given version. Each entry is a SCENE — a
// distinct "command run" that clears the terminal before playing.
function buildScript(v) {
  return [
    // SCENE 1 — Installer (.exe)
    {
      title: 'download setup.exe',
      lines: [
        { kind: 'cmd', text: `iwr https://github.com/${WG_REPO}/releases/download/v${v}/winghostty-${v}-windows-x64-setup.exe -OutFile winghostty-setup.exe` },
        { kind: 'cmd', text: '.\\winghostty-setup.exe' },
        { kind: 'out', t: '→ installer build: Start menu entry and standard uninstall path', c: 'dim' },
        { kind: 'out', t: '→ SmartScreen may warn while reputation is new. Click More info → Run anyway if you trust the release.', c: 'dim' },
      ],
    },
    // SCENE 2 — Portable ZIP
    {
      title: 'portable (.zip)',
      lines: [
        { kind: 'cmd', text: `iwr https://github.com/${WG_REPO}/releases/download/v${v}/winghostty-${v}-windows-x64-portable.zip -OutFile winghostty.zip` },
        { kind: 'cmd', text: 'Expand-Archive winghostty.zip -DestinationPath .\\winghostty' },
        { kind: 'cmd', text: '.\\winghostty\\winghostty.exe' },
        { kind: 'out', t: '→ same Win32 runtime, no install step required', c: 'dim' },
      ],
    },
    // SCENE 3 — Config docs
    {
      title: 'make it yours',
      lines: [
        { kind: 'cmd', text: 'winghostty +show-config --default --docs' },
        { kind: 'out', t: '→ config lives at: %LOCALAPPDATA%\\winghostty\\config.ghostty', c: 'dim' },
        { kind: 'out', t: '→ updates stay notify-only and check GitHub at most once every 24 hours', c: 'dim' },
        { kind: 'out', t: '→ profile picker: PowerShell, cmd, Git Bash, and opt-in WSL', c: 'dim' },
      ],
    },
    // SCENE 4 — launch
    {
      title: 'launch',
      lines: [
        { kind: 'cmd', text: 'winghostty' },
        { kind: 'out', t: `winghostty ${v} · windows-x64`, c: 'fg' },
        { kind: 'out', t: '→ native Windows app with tabs, splits, and profiles', c: 'dim' },
        { kind: 'out', t: '→ built on Ghostty\'s terminal core', c: 'dim' },
      ],
    },
  ];
}

// Initial script (will be regenerated when version is fetched).
let TERMINAL_SCRIPT = buildScript(WG_VERSION);
window.WG_VERSION = WG_VERSION;

// Try to fetch the actual latest release tag from GitHub. If it works,
// dispatch a custom event so the page can re-render with the new version.
// Defer to idle + cache in sessionStorage so we only hit the API once per tab session.
(function fetchLatestVersionDeferred() {
  const CACHE_KEY = 'wg-latest-version';
  const CACHE_TTL = 1000 * 60 * 30; // 30 min
  const apply = (tag) => {
    if (!tag || tag === WG_VERSION) return;
    WG_VERSION = tag;
    window.WG_VERSION = tag;
    TERMINAL_SCRIPT = buildScript(WG_VERSION);
    window.dispatchEvent(new CustomEvent('wg-version-updated', { detail: { version: tag } }));
  };

  try {
    const cached = sessionStorage.getItem(CACHE_KEY);
    if (cached) {
      const { tag, ts } = JSON.parse(cached);
      if (tag && Date.now() - ts < CACHE_TTL) {
        apply(tag);
        return;
      }
    }
  } catch (e) {}

  const run = async () => {
    try {
      const res = await fetch(`https://api.github.com/repos/${WG_REPO}/releases/latest`);
      if (!res.ok) return;
      const data = await res.json();
      const tag = (data.tag_name || '').replace(/^v/, '');
      if (tag) {
        try { sessionStorage.setItem(CACHE_KEY, JSON.stringify({ tag, ts: Date.now() })); } catch (e) {}
        apply(tag);
      }
    } catch (e) {}
  };

  const idle = window.requestIdleCallback || ((cb) => setTimeout(cb, 1500));
  idle(run, { timeout: 4000 });
})();

function TerminalLine({ prompt, text, cursor, promptColor, textColor }) {
  return (
    <div style={{ display: 'flex', gap: 8, minHeight: 22 }}>
      <span style={{ color: promptColor, flexShrink: 0, userSelect: 'none' }}>{prompt}</span>
      <span style={{ color: textColor, whiteSpace: 'pre' }}>
        {text}
        {cursor && <span className="wg-caret">▋</span>}
      </span>
    </div>
  );
}

function WinghosttyTerminal({
  autoplay = true,
  theme = 'dark',
  height = 440,
  compact = false,
  script: initialScript,
}) {
  // Use the live TERMINAL_SCRIPT (re-read on every render so async version
  // updates from GitHub flow through).
  const [, force] = useState(0);
  useEffect(() => {
    const onUpdate = () => force((n) => n + 1);
    window.addEventListener('wg-version-updated', onUpdate);
    return () => window.removeEventListener('wg-version-updated', onUpdate);
  }, []);
  const script = initialScript || TERMINAL_SCRIPT;

  const PROMPT = 'PS C:\\Users\\dev>';

  const [sceneIdx, setSceneIdx] = useState(0);   // which scene
  const [lineIdx, setLineIdx] = useState(0);     // which line within scene
  const [typed, setTyped] = useState('');        // typed chars of current cmd line
  const [phase, setPhase] = useState('typing');  // typing | reveal | scene-done

  const scene = script[sceneIdx];
  const line = scene?.lines[lineIdx];

  const C = theme === 'dark' ? {
    bg: '#0b0b0c', chrome: '#17171a', border: '#26262a', fg: '#e5e5e5',
    dim: '#707078', prompt: '#a5a5ad', accent: '#ffffff', ok: '#d1d5db', dot: '#3b3b42',
  } : {
    bg: '#fafafa', chrome: '#f0f0ef', border: '#d4d4d2', fg: '#1a1a1a',
    dim: '#7a7a78', prompt: '#52525b', accent: '#0a0a0a', ok: '#3f3f46', dot: '#c4c4c0',
  };

  // Drive the next step
  useEffect(() => {
    if (!autoplay || !scene) return;

    // End of scene → pause, then clear & advance
    if (lineIdx >= scene.lines.length) {
      const t = setTimeout(() => {
        const next = (sceneIdx + 1) % script.length;
        setSceneIdx(next);
        setLineIdx(0);
        setTyped('');
        setPhase('typing');
      }, 1800);
      return () => clearTimeout(t);
    }

    if (!line) return;

    if (line.kind === 'cmd') {
      if (phase === 'typing') {
        if (typed.length < line.text.length) {
          const t = setTimeout(() => {
            setTyped(line.text.slice(0, typed.length + 1));
          }, 32 + Math.random() * 48);
          return () => clearTimeout(t);
        }
        // finished typing → wait a beat, then advance
        const t = setTimeout(() => {
          setLineIdx((i) => i + 1);
          setTyped('');
        }, 360);
        return () => clearTimeout(t);
      }
    } else {
      // output line — reveal then advance
      const t = setTimeout(() => {
        setLineIdx((i) => i + 1);
      }, 220);
      return () => clearTimeout(t);
    }
  }, [autoplay, scene, line, lineIdx, sceneIdx, phase, typed, script.length]);

  // Build the visible buffer: only lines from THIS scene up to lineIdx,
  // plus the currently-typing command if applicable.
  const visible = [];
  if (scene) {
    if (!autoplay) {
      visible.push(...scene.lines);
      visible.push({ kind: 'cmd', text: '', cursor: true });
    } else {
      for (let i = 0; i < lineIdx && i < scene.lines.length; i++) {
        visible.push(scene.lines[i]);
      }
      if (line && line.kind === 'cmd') {
        // currently typing
        visible.push({ kind: 'cmd', text: typed, cursor: true });
      } else if (lineIdx >= scene.lines.length) {
        // scene complete — show idle prompt with cursor
        visible.push({ kind: 'cmd', text: '', cursor: true });
      }
    }
  }

  return (
    <div style={{
      background: C.bg, border: `1px solid ${C.border}`, borderRadius: 10, overflow: 'hidden',
      boxShadow: theme === 'dark'
        ? '0 40px 120px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,255,255,0.04)'
        : '0 40px 120px rgba(0,0,0,0.12), 0 0 0 1px rgba(0,0,0,0.02)',
      display: 'flex', flexDirection: 'column', width: '100%', maxWidth: '100%',
    }}>
      {/* chrome */}
      <div style={{
        height: 36, background: C.chrome, borderBottom: `1px solid ${C.border}`,
        display: 'flex', alignItems: 'center', padding: '0 12px', gap: 10,
      }}>
        <div style={{ display: 'flex', gap: 6 }}>
          <div style={{ width: 10, height: 10, borderRadius: 2, background: C.dot }} />
          <div style={{ width: 10, height: 10, borderRadius: 2, background: C.dot }} />
          <div style={{ width: 10, height: 10, borderRadius: 2, background: C.dot }} />
        </div>
        <div style={{ flex: 1, textAlign: 'center', fontSize: 11, color: C.dim, fontFamily: 'var(--mono)', letterSpacing: '0.02em' }}>
          winghostty — PowerShell — {scene?.title || 'idle'}
        </div>
        <div style={{ width: 44 }} />
      </div>
      {/* body */}
      <div style={{
        flex: 1, height,
        padding: compact ? '16px 18px' : '22px 24px',
        fontFamily: 'var(--mono)',
        fontSize: compact ? 12 : 13,
        lineHeight: 1.65, color: C.fg, overflow: 'hidden', textAlign: 'left',
      }}>
        {visible.map((l, i) => {
          if (l.kind === 'cmd') {
            return (
              <TerminalLine
                key={`${sceneIdx}-${i}`}
                prompt={PROMPT}
                text={l.text}
                cursor={l.cursor}
                promptColor={C.prompt}
                textColor={C.fg}
              />
            );
          }
          const color = l.c === 'dim' ? C.dim : l.c === 'accent' ? C.accent : l.c === 'ok' ? C.ok : C.fg;
          return (
            <div key={`${sceneIdx}-${i}`} style={{ color, whiteSpace: 'pre', minHeight: 22 }}>
              {l.t}
            </div>
          );
        })}
      </div>
    </div>
  );
}

Object.assign(window, { WinghosttyTerminal, WG_REPO });
