// ===== mark.jsx =====
// Winghostty mark — real icon with Microsoft 4-color flag and terminal-glyph eyes.
// Theme-aware: inner ghost fill is white on dark bg, near-black on light bg.
// Inner-face / outline / glyph use CSS color transitions so the mark animates
// smoothly when theme flips.

function WinghosttyMark({
  size = 28,
  theme = 'dark',
  animated = false
}) {
  const ghostFill = theme === 'dark' ? '#ffffff' : '#0a0a0a';
  const outline = theme === 'dark' ? '#0a0a0a' : '#ffffff';
  const glyph = theme === 'dark' ? '#0a0a0a' : '#ffffff';
  const transition = animated ? 'fill 0.5s cubic-bezier(0.45, 0, 0.15, 1)' : undefined;
  return /*#__PURE__*/React.createElement("svg", {
    width: size,
    height: size * 32 / 27,
    viewBox: "0 0 27 32",
    fill: "none",
    "aria-hidden": "true"
  }, /*#__PURE__*/React.createElement("defs", null, /*#__PURE__*/React.createElement("clipPath", {
    id: `wg-tl-${size}`
  }, /*#__PURE__*/React.createElement("rect", {
    x: "0",
    y: "0",
    width: "13.36",
    height: "16"
  })), /*#__PURE__*/React.createElement("clipPath", {
    id: `wg-tr-${size}`
  }, /*#__PURE__*/React.createElement("rect", {
    x: "13.36",
    y: "0",
    width: "13.64",
    height: "16"
  })), /*#__PURE__*/React.createElement("clipPath", {
    id: `wg-bl-${size}`
  }, /*#__PURE__*/React.createElement("rect", {
    x: "0",
    y: "16",
    width: "13.36",
    height: "16"
  })), /*#__PURE__*/React.createElement("clipPath", {
    id: `wg-br-${size}`
  }, /*#__PURE__*/React.createElement("rect", {
    x: "13.36",
    y: "16",
    width: "13.64",
    height: "16"
  }))), /*#__PURE__*/React.createElement("path", {
    d: "M20.3955 32C19.1436 32 17.9152 31.6249 16.879 30.9333C15.8428 31.6249 14.6121 32 13.3625 32C12.113 32 10.8822 31.6249 9.84606 30.9333C8.8169 31.6249 7.62598 31.9906 6.37177 32H6.33426C4.63228 32 3.0358 31.3225 1.83316 30.0941C0.64928 28.8844 -0.00244141 27.2926 -0.00244141 25.6117V13.3626C-9.70841e-05 5.99443 5.99433 0 13.3625 0C20.7307 0 26.7252 5.99443 26.7252 13.3626V25.6164C26.7252 29.0086 24.0995 31.8078 20.7472 31.9906C20.6299 31.9977 20.5127 32 20.3955 32Z",
    fill: "#F25022",
    clipPath: `url(#wg-tl-${size})`
  }), /*#__PURE__*/React.createElement("path", {
    d: "M20.3955 32C19.1436 32 17.9152 31.6249 16.879 30.9333C15.8428 31.6249 14.6121 32 13.3625 32C12.113 32 10.8822 31.6249 9.84606 30.9333C8.8169 31.6249 7.62598 31.9906 6.37177 32H6.33426C4.63228 32 3.0358 31.3225 1.83316 30.0941C0.64928 28.8844 -0.00244141 27.2926 -0.00244141 25.6117V13.3626C-9.70841e-05 5.99443 5.99433 0 13.3625 0C20.7307 0 26.7252 5.99443 26.7252 13.3626V25.6164C26.7252 29.0086 24.0995 31.8078 20.7472 31.9906C20.6299 31.9977 20.5127 32 20.3955 32Z",
    fill: "#7FBA00",
    clipPath: `url(#wg-tr-${size})`
  }), /*#__PURE__*/React.createElement("path", {
    d: "M20.3955 32C19.1436 32 17.9152 31.6249 16.879 30.9333C15.8428 31.6249 14.6121 32 13.3625 32C12.113 32 10.8822 31.6249 9.84606 30.9333C8.8169 31.6249 7.62598 31.9906 6.37177 32H6.33426C4.63228 32 3.0358 31.3225 1.83316 30.0941C0.64928 28.8844 -0.00244141 27.2926 -0.00244141 25.6117V13.3626C-9.70841e-05 5.99443 5.99433 0 13.3625 0C20.7307 0 26.7252 5.99443 26.7252 13.3626V25.6164C26.7252 29.0086 24.0995 31.8078 20.7472 31.9906C20.6299 31.9977 20.5127 32 20.3955 32Z",
    fill: "#00A4EF",
    clipPath: `url(#wg-bl-${size})`
  }), /*#__PURE__*/React.createElement("path", {
    d: "M20.3955 32C19.1436 32 17.9152 31.6249 16.879 30.9333C15.8428 31.6249 14.6121 32 13.3625 32C12.113 32 10.8822 31.6249 9.84606 30.9333C8.8169 31.6249 7.62598 31.9906 6.37177 32H6.33426C4.63228 32 3.0358 31.3225 1.83316 30.0941C0.64928 28.8844 -0.00244141 27.2926 -0.00244141 25.6117V13.3626C-9.70841e-05 5.99443 5.99433 0 13.3625 0C20.7307 0 26.7252 5.99443 26.7252 13.3626V25.6164C26.7252 29.0086 24.0995 31.8078 20.7472 31.9906C20.6299 31.9977 20.5127 32 20.3955 32Z",
    fill: "#FFB900",
    clipPath: `url(#wg-br-${size})`
  }), /*#__PURE__*/React.createElement("path", {
    style: {
      transition
    },
    d: "M20.3955 30.5934C19.2773 30.5934 18.1848 30.209 17.3151 29.5104C17.165 29.3884 17.0033 29.365 16.8954 29.365C16.7243 29.365 16.5508 29.426 16.4078 29.5408C15.5451 30.2207 14.4644 30.5958 13.3625 30.5958C12.2607 30.5958 11.18 30.2207 10.3173 29.5408C10.1789 29.4306 10.0148 29.3744 9.84605 29.3744C9.67726 29.3744 9.51316 29.433 9.37485 29.5408C8.50979 30.223 7.46891 30.5864 6.36474 30.5958H6.33192C5.01675 30.5958 3.7766 30.0706 2.84122 29.1142C1.91756 28.1694 1.40649 26.9269 1.40649 25.6164V13.3673C1.40649 6.77043 6.7703 1.40662 13.3625 1.40662C19.9548 1.40662 25.3186 6.77043 25.3186 13.3627V25.6164C25.3186 28.2608 23.2767 30.4434 20.6698 30.5864C20.5784 30.5911 20.4869 30.5934 20.3955 30.5934Z",
    fill: outline
  }), /*#__PURE__*/React.createElement("path", {
    style: {
      transition
    },
    d: "M23.9119 13.3627V25.6165C23.9119 27.4919 22.4654 29.079 20.5923 29.1822C19.6827 29.2314 18.8435 28.936 18.1941 28.4132C17.4158 27.7873 16.321 27.8154 15.5356 28.4343C14.9378 28.9055 14.183 29.1869 13.3601 29.1869C12.5372 29.1869 11.7847 28.9055 11.1869 28.4343C10.3922 27.8084 9.29738 27.8084 8.50266 28.4343C7.90954 28.9009 7.16405 29.1822 6.35291 29.1869C4.40478 29.2009 2.81299 27.5599 2.81299 25.6118V13.3627C2.81299 7.53704 7.5368 2.81323 13.3624 2.81323C19.1881 2.81323 23.9119 7.53704 23.9119 13.3627Z",
    fill: ghostFill
  }), /*#__PURE__*/React.createElement("path", {
    style: {
      transition
    },
    d: "M11.2808 12.4366L7.3494 10.1673C6.83833 9.87192 6.18192 10.0477 5.88654 10.5588C5.59115 11.0699 5.76698 11.7263 6.27804 12.0217L8.60361 13.365L6.27804 14.7083C5.76698 15.0036 5.59115 15.6577 5.88654 16.1711C6.18192 16.6822 6.83599 16.858 7.3494 16.5626L11.2808 14.2933C11.9935 13.8807 11.9935 12.8516 11.2808 12.4389V12.4366Z",
    fill: glyph
  }), /*#__PURE__*/React.createElement("path", {
    style: {
      transition
    },
    d: "M20.1822 12.2913H15.0176C14.4269 12.2913 13.9463 12.7695 13.9463 13.3626C13.9463 13.9557 14.4245 14.434 15.0176 14.434H20.1822C20.773 14.434 21.2535 13.9557 21.2535 13.3626C21.2535 12.7695 20.7753 12.2913 20.1822 12.2913Z",
    fill: glyph
  }));
}

// Wordmark: icon + "Winghostty" text, theme-aware.
function WinghosttyWordmark({
  size = 28,
  theme = 'dark'
}) {
  const textColor = theme === 'dark' ? '#ffffff' : '#0a0a0a';
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 10
    }
  }, /*#__PURE__*/React.createElement(WinghosttyMark, {
    size: size,
    theme: theme
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      color: textColor,
      fontWeight: 700,
      fontSize: size * 0.78,
      letterSpacing: '-0.02em',
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, system-ui, sans-serif'
    }
  }, "Winghostty"));
}

// Animated theme toggle — uses the real Winghostty ghost silhouette (same
// path as the brand mark) but rendered in a minimal black & white style
// specific to this control. The terminal-glyph "eyes" (< and =) squeeze
// vertically to blink; theme flips at the closed-eye midpoint.
function WinghosttyToggle({
  theme,
  onToggle,
  size = 22
}) {
  const [blinking, setBlinking] = React.useState(false);
  const [hover, setHover] = React.useState(false);
  const C = theme === 'dark' ? {
    bg: '#101012',
    bgHover: '#17171a',
    border: '#26262a',
    ghost: '#e5e5e5',
    glyph: '#0a0a0b'
  } : {
    bg: '#ffffff',
    bgHover: '#f3f3f1',
    border: '#d8d8d6',
    ghost: '#0a0a0a',
    glyph: '#fafaf9'
  };
  const triggerBlink = () => {
    if (blinking) return;
    setBlinking(true);
    onToggle();
    setTimeout(() => setBlinking(false), 220);
  };
  return /*#__PURE__*/React.createElement("button", {
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    onClick: triggerBlink,
    "aria-label": `Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`,
    title: `Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`,
    style: {
      width: 36,
      height: 36,
      borderRadius: 9,
      background: hover ? C.bgHover : C.bg,
      border: `1px solid ${C.border}`,
      cursor: 'pointer',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      padding: 0,
      transition: 'background 0.18s, border-color 0.18s'
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: size,
    height: size * 32 / 27,
    viewBox: "0 0 27 32",
    fill: "none",
    "aria-hidden": "true"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M20.3955 30.5934C19.2773 30.5934 18.1848 30.209 17.3151 29.5104C17.165 29.3884 17.0033 29.365 16.8954 29.365C16.7243 29.365 16.5508 29.426 16.4078 29.5408C15.5451 30.2207 14.4644 30.5958 13.3625 30.5958C12.2607 30.5958 11.18 30.2207 10.3173 29.5408C10.1789 29.4306 10.0148 29.3744 9.84605 29.3744C9.67726 29.3744 9.51316 29.433 9.37485 29.5408C8.50979 30.223 7.46891 30.5864 6.36474 30.5958H6.33192C5.01675 30.5958 3.7766 30.0706 2.84122 29.1142C1.91756 28.1694 1.40649 26.9269 1.40649 25.6164V13.3673C1.40649 6.77043 6.7703 1.40662 13.3625 1.40662C19.9548 1.40662 25.3186 6.77043 25.3186 13.3627V25.6164C25.3186 28.2608 23.2767 30.4434 20.6698 30.5864C20.5784 30.5911 20.4869 30.5934 20.3955 30.5934Z",
    fill: C.ghost,
    style: {
      transition: 'fill 0.2s ease'
    }
  }), /*#__PURE__*/React.createElement("g", {
    style: {
      transform: blinking ? 'scaleY(0.06)' : 'scaleY(1)',
      transformOrigin: '13.36px 13.36px',
      transition: 'transform 0.14s cubic-bezier(0.45, 0, 0.55, 1)'
    }
  }, /*#__PURE__*/React.createElement("path", {
    d: "M11.2808 12.4366L7.3494 10.1673C6.83833 9.87192 6.18192 10.0477 5.88654 10.5588C5.59115 11.0699 5.76698 11.7263 6.27804 12.0217L8.60361 13.365L6.27804 14.7083C5.76698 15.0036 5.59115 15.6577 5.88654 16.1711C6.18192 16.6822 6.83599 16.858 7.3494 16.5626L11.2808 14.2933C11.9935 13.8807 11.9935 12.8516 11.2808 12.4389V12.4366Z",
    fill: C.glyph,
    style: {
      transition: 'fill 0.2s ease'
    }
  }), /*#__PURE__*/React.createElement("path", {
    d: "M20.1822 12.2913H15.0176C14.4269 12.2913 13.9463 12.7695 13.9463 13.3626C13.9463 13.9557 14.4245 14.434 15.0176 14.434H20.1822C20.773 14.434 21.2535 13.9557 21.2535 13.3626C21.2535 12.7695 20.7753 12.2913 20.1822 12.2913Z",
    fill: C.glyph,
    style: {
      transition: 'fill 0.2s ease'
    }
  }))));
}
Object.assign(window, {
  WinghosttyMark,
  WinghosttyWordmark,
  WinghosttyToggle
});

// ===== terminal.jsx =====
// Mock terminal window with typewriter animation
// Uses React hooks. Exposes WinghosttyTerminal to window.

const {
  useState,
  useEffect,
  useRef,
  useMemo
} = React;

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
    lines: [{
      kind: 'cmd',
      text: `iwr https://github.com/${WG_REPO}/releases/download/v${v}/winghostty-${v}-windows-x64-setup.exe -OutFile winghostty-setup.exe`
    }, {
      kind: 'cmd',
      text: '.\\winghostty-setup.exe'
    }, {
      kind: 'out',
      t: '→ installer build: Start menu entry and standard uninstall path',
      c: 'dim'
    }, {
      kind: 'out',
      t: '→ SmartScreen may warn while reputation is new. Click More info → Run anyway if you trust the release.',
      c: 'dim'
    }]
  },
  // SCENE 2 — Portable ZIP
  {
    title: 'portable (.zip)',
    lines: [{
      kind: 'cmd',
      text: `iwr https://github.com/${WG_REPO}/releases/download/v${v}/winghostty-${v}-windows-x64-portable.zip -OutFile winghostty.zip`
    }, {
      kind: 'cmd',
      text: 'Expand-Archive winghostty.zip -DestinationPath .\\winghostty'
    }, {
      kind: 'cmd',
      text: '.\\winghostty\\winghostty.exe'
    }, {
      kind: 'out',
      t: '→ same Win32 runtime, no install step required',
      c: 'dim'
    }]
  },
  // SCENE 3 — Config docs
  {
    title: 'make it yours',
    lines: [{
      kind: 'cmd',
      text: 'winghostty +show-config --default --docs'
    }, {
      kind: 'out',
      t: '→ config lives at: %LOCALAPPDATA%\\winghostty\\config.ghostty',
      c: 'dim'
    }, {
      kind: 'out',
      t: '→ updates stay notify-only and check GitHub at most once every 24 hours',
      c: 'dim'
    }, {
      kind: 'out',
      t: '→ profile picker: PowerShell, cmd, Git Bash, and opt-in WSL',
      c: 'dim'
    }]
  },
  // SCENE 4 — launch
  {
    title: 'launch',
    lines: [{
      kind: 'cmd',
      text: 'winghostty'
    }, {
      kind: 'out',
      t: `winghostty ${v} · windows-x64`,
      c: 'fg'
    }, {
      kind: 'out',
      t: '→ native Windows app with tabs, splits, and profiles',
      c: 'dim'
    }, {
      kind: 'out',
      t: '→ built on Ghostty\'s terminal core',
      c: 'dim'
    }]
  }];
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
      if (tag && Date.now() - ts < CACHE_TTL) { apply(tag); return; }
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
function TerminalLine({
  prompt,
  text,
  cursor,
  promptColor,
  textColor
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 8,
      minHeight: 22,
      flexWrap: 'wrap',
      alignItems: 'flex-start'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: promptColor,
      flexShrink: 0,
      userSelect: 'none'
    }
  }, prompt), /*#__PURE__*/React.createElement("span", {
    style: {
      color: textColor,
      whiteSpace: 'pre-wrap',
      wordBreak: 'break-all',
      minWidth: 0,
      flex: 1
    }
  }, text, cursor && /*#__PURE__*/React.createElement("span", {
    className: "wg-caret"
  }, "\u258B")));
}
function WinghosttyTerminal({
  autoplay = true,
  theme = 'dark',
  height = 440,
  compact = false,
  script: initialScript
}) {
  // Use the live TERMINAL_SCRIPT (re-read on every render so async version
  // updates from GitHub flow through).
  const [, force] = useState(0);
  useEffect(() => {
    const onUpdate = () => force(n => n + 1);
    window.addEventListener('wg-version-updated', onUpdate);
    return () => window.removeEventListener('wg-version-updated', onUpdate);
  }, []);
  const script = initialScript || TERMINAL_SCRIPT;
  const PROMPT = 'PS C:\\Users\\dev>';
  const [sceneIdx, setSceneIdx] = useState(0); // which scene
  const [lineIdx, setLineIdx] = useState(0); // which line within scene
  const [typed, setTyped] = useState(''); // typed chars of current cmd line
  const [phase, setPhase] = useState('typing'); // typing | reveal | scene-done

  const scene = script[sceneIdx];
  const line = scene?.lines[lineIdx];
  const C = theme === 'dark' ? {
    bg: '#0b0b0c',
    chrome: '#17171a',
    border: '#26262a',
    fg: '#e5e5e5',
    dim: '#707078',
    prompt: '#a5a5ad',
    accent: '#ffffff',
    ok: '#d1d5db',
    dot: '#3b3b42'
  } : {
    bg: '#fafafa',
    chrome: '#f0f0ef',
    border: '#d4d4d2',
    fg: '#1a1a1a',
    dim: '#7a7a78',
    prompt: '#52525b',
    accent: '#0a0a0a',
    ok: '#3f3f46',
    dot: '#c4c4c0'
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
          setLineIdx(i => i + 1);
          setTyped('');
        }, 360);
        return () => clearTimeout(t);
      }
    } else {
      // output line — reveal then advance
      const t = setTimeout(() => {
        setLineIdx(i => i + 1);
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
      visible.push({
        kind: 'cmd',
        text: '',
        cursor: true
      });
    } else {
      for (let i = 0; i < lineIdx && i < scene.lines.length; i++) {
        visible.push(scene.lines[i]);
      }
      if (line && line.kind === 'cmd') {
        // currently typing
        visible.push({
          kind: 'cmd',
          text: typed,
          cursor: true
        });
      } else if (lineIdx >= scene.lines.length) {
        // scene complete — show idle prompt with cursor
        visible.push({
          kind: 'cmd',
          text: '',
          cursor: true
        });
      }
    }
  }
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: C.bg,
      border: `1px solid ${C.border}`,
      borderRadius: 10,
      overflow: 'hidden',
      boxShadow: theme === 'dark' ? '0 40px 120px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,255,255,0.04)' : '0 40px 120px rgba(0,0,0,0.12), 0 0 0 1px rgba(0,0,0,0.02)',
      display: 'flex',
      flexDirection: 'column',
      width: '100%',
      maxWidth: '100%'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      height: 36,
      background: C.chrome,
      borderBottom: `1px solid ${C.border}`,
      display: 'flex',
      alignItems: 'center',
      padding: '0 12px',
      gap: 10
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 10,
      height: 10,
      borderRadius: 2,
      background: C.dot
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      width: 10,
      height: 10,
      borderRadius: 2,
      background: C.dot
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      width: 10,
      height: 10,
      borderRadius: 2,
      background: C.dot
    }
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      textAlign: 'center',
      fontSize: 11,
      color: C.dim,
      fontFamily: 'var(--mono)',
      letterSpacing: '0.02em'
    }
  }, "winghostty \u2014 PowerShell \u2014 ", scene?.title || 'idle'), /*#__PURE__*/React.createElement("div", {
    style: {
      width: 44
    }
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      height,
      padding: compact ? '16px 18px' : '22px 24px',
      fontFamily: 'var(--mono)',
      fontSize: compact ? 12 : 13,
      lineHeight: 1.65,
      color: C.fg,
      overflow: 'auto',
      textAlign: 'left'
    }
  }, visible.map((l, i) => {
    if (l.kind === 'cmd') {
      return /*#__PURE__*/React.createElement(TerminalLine, {
        key: `${sceneIdx}-${i}`,
        prompt: PROMPT,
        text: l.text,
        cursor: l.cursor,
        promptColor: C.prompt,
        textColor: C.fg
      });
    }
    const color = l.c === 'dim' ? C.dim : l.c === 'accent' ? C.accent : l.c === 'ok' ? C.ok : C.fg;
    return /*#__PURE__*/React.createElement("div", {
      key: `${sceneIdx}-${i}`,
      style: {
        color,
        whiteSpace: 'pre-wrap',
        wordBreak: 'break-all',
        minHeight: 22
      }
    }, l.t);
  })));
}
Object.assign(window, {
  WinghosttyTerminal,
  WG_REPO
});

// ===== sections.jsx =====
// Shared page sections: install block, feature cards, why-fork, community, footer.

const {
  useState: useStateShared,
  useRef: useRefShared
} = React;
function InstallBlock({
  theme = 'dark'
}) {
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
    bg: '#111113',
    border: '#26262a',
    fg: '#e5e5e5',
    dim: '#707078',
    btnBg: '#1c1c20',
    btnHover: '#26262a'
  } : {
    bg: '#ffffff',
    border: '#e4e4e2',
    fg: '#0a0a0a',
    dim: '#6a6a68',
    btnBg: '#f3f3f1',
    btnHover: '#e8e8e6'
  };
  return /*#__PURE__*/React.createElement("div", {
    className: "wg-install",
    style: {
      display: 'inline-flex',
      alignItems: 'stretch',
      gap: 0,
      background: C.bg,
      border: `1px solid ${C.border}`,
      borderRadius: 10,
      fontFamily: 'var(--mono)',
      fontSize: 14,
      overflow: 'hidden',
      height: 46
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'flex',
      alignItems: 'center',
      padding: '0 4px 0 16px',
      color: C.dim,
      userSelect: 'none'
    }
  }, String.fromCharCode(36)), /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'flex',
      alignItems: 'center',
      padding: '0 16px 0 8px',
      color: C.fg,
      whiteSpace: 'nowrap'
    }
  }, cmd), /*#__PURE__*/React.createElement("button", {
    onClick: onCopy,
    style: {
      background: C.btnBg,
      border: 'none',
      borderLeft: `1px solid ${C.border}`,
      padding: '0 16px',
      color: C.fg,
      fontFamily: 'inherit',
      fontSize: 13,
      cursor: 'pointer',
      minWidth: 88,
      transition: 'background 0.12s'
    },
    onMouseEnter: e => e.currentTarget.style.background = C.btnHover,
    onMouseLeave: e => e.currentTarget.style.background = C.btnBg
  }, copied ? '✓ copied' : 'copy'));
}

// Small ASCII-style glyph for each feature card — monochrome, geometric.
const FEATURE_GLYPHS = {
  gpu: /*#__PURE__*/React.createElement("svg", {
    viewBox: "0 0 40 40",
    width: "32",
    height: "32",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: "1.25"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "6",
    y: "6",
    width: "28",
    height: "28",
    rx: "1.5"
  }), /*#__PURE__*/React.createElement("path", {
    d: "M11 13 L16 20 L11 27 M18 13 L23 20 L18 27 M25 13 L30 20 L25 27"
  })),
  native: /*#__PURE__*/React.createElement("svg", {
    viewBox: "0 0 40 40",
    width: "32",
    height: "32",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: "1.25"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "5",
    y: "5",
    width: "30",
    height: "30",
    rx: "1.5"
  }), /*#__PURE__*/React.createElement("path", {
    d: "M5 11 L35 11"
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "9",
    cy: "8",
    r: "0.9",
    fill: "currentColor",
    stroke: "none"
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "12",
    cy: "8",
    r: "0.9",
    fill: "currentColor",
    stroke: "none"
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "15",
    cy: "8",
    r: "0.9",
    fill: "currentColor",
    stroke: "none"
  })),
  compat: /*#__PURE__*/React.createElement("svg", {
    viewBox: "0 0 40 40",
    width: "32",
    height: "32",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: "1.25"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M8 14 L12 20 L8 26"
  }), /*#__PURE__*/React.createElement("path", {
    d: "M16 28 L24 28"
  }), /*#__PURE__*/React.createElement("rect", {
    x: "28",
    y: "10",
    width: "6",
    height: "20",
    rx: "0.6"
  })),
  config: /*#__PURE__*/React.createElement("svg", {
    viewBox: "0 0 40 40",
    width: "32",
    height: "32",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: "1.25"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "7",
    y: "7",
    width: "26",
    height: "26",
    rx: "1.5"
  }), /*#__PURE__*/React.createElement("path", {
    d: "M12 14 L22 14 M12 20 L28 20 M12 26 L18 26"
  })),
  libghostty: /*#__PURE__*/React.createElement("svg", {
    viewBox: "0 0 40 40",
    width: "32",
    height: "32",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: "1.25"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M20 6 L32 12 L32 24 L20 30 L8 24 L8 12 Z"
  }), /*#__PURE__*/React.createElement("path", {
    d: "M20 6 L20 30 M8 12 L32 12 M8 24 L32 24",
    strokeOpacity: "0.5"
  })),
  oss: /*#__PURE__*/React.createElement("svg", {
    viewBox: "0 0 40 40",
    width: "32",
    height: "32",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: "1.25"
  }, /*#__PURE__*/React.createElement("circle", {
    cx: "20",
    cy: "20",
    r: "12"
  }), /*#__PURE__*/React.createElement("path", {
    d: "M8 20 L32 20 M20 8 L20 32 M11 11 L29 29 M29 11 L11 29",
    strokeOpacity: "0.35"
  }))
};
const FEATURES = [{
  k: 'gpu',
  title: 'Smooth and GPU-accelerated',
  body: 'Fast, crisp terminal rendering in the Windows app shipping today.'
}, {
  k: 'native',
  title: 'Feels native on Windows',
  body: 'Tabs, splits, IME, drag-and-drop, and the details that make it feel like a real Windows app.'
}, {
  k: 'compat',
  title: 'Built on Ghostty',
  body: 'Winghostty keeps Ghostty\'s terminal core, then adds the Windows-native app layer around it.'
}, {
  k: 'config',
  title: 'Easy to make your own',
  body: 'Edit %LOCALAPPDATA%\\winghostty\\config.ghostty, reload changes live, and make Winghostty feel like yours.'
}, {
  k: 'libghostty',
  title: 'Your shells, ready to go',
  body: 'PowerShell, cmd, Git Bash, and opt-in WSL are easy to launch from the built-in profile picker.'
}, {
  k: 'oss',
  title: 'Open source, local-first',
  body: 'MIT-licensed, no telemetry, and updates stay notify-only instead of replacing binaries in the background.'
}];
function FeatureCard({
  feature,
  theme
}) {
  const [hover, setHover] = useStateShared(false);
  const C = theme === 'dark' ? {
    bg: hover ? '#141416' : '#101012',
    border: hover ? '#36363c' : '#1e1e22',
    fg: '#e5e5e5',
    dim: '#8a8a92',
    glyph: '#d4d4d8'
  } : {
    bg: hover ? '#ffffff' : '#fafaf9',
    border: hover ? '#c8c8c6' : '#e4e4e2',
    fg: '#0a0a0a',
    dim: '#6a6a68',
    glyph: '#1a1a1a'
  };
  return /*#__PURE__*/React.createElement("div", {
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      background: C.bg,
      border: `1px solid ${C.border}`,
      borderRadius: 10,
      padding: '22px 22px 24px',
      transition: 'background 0.18s, border-color 0.18s, transform 0.18s',
      transform: hover ? 'translateY(-2px)' : 'translateY(0)',
      cursor: 'default'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      color: C.glyph,
      marginBottom: 14,
      transition: 'color 0.18s'
    }
  }, FEATURE_GLYPHS[feature.k]), /*#__PURE__*/React.createElement("div", {
    style: {
      color: C.fg,
      fontSize: 15,
      fontWeight: 500,
      marginBottom: 6,
      letterSpacing: '-0.01em'
    }
  }, feature.title), /*#__PURE__*/React.createElement("div", {
    style: {
      color: C.dim,
      fontSize: 13.5,
      lineHeight: 1.5
    }
  }, feature.body));
}
function FeatureGrid({
  theme
}) {
  return /*#__PURE__*/React.createElement("div", {
    className: "wg-feature-grid"
  }, FEATURES.map(f => /*#__PURE__*/React.createElement(FeatureCard, {
    key: f.k,
    feature: f,
    theme: theme
  })));
}

// Why Windows? — a two-column block with a small Q&A pattern.
const WHY_ITEMS = [{
  q: 'Why a fork instead of upstream?',
  a: 'Ghostty does not ship a Windows app today. Winghostty keeps the Ghostty core and builds the Windows-native experience around it.'
}, {
  q: 'How close is it to Ghostty?',
  a: 'Close where it matters: the terminal core is shared, while the app layer around it is purpose-built for Windows.'
}, {
  q: 'Is it ready to use?',
  a: 'Winghostty is young, with first public releases on April 16, 2026, but it is already usable if you are comfortable running a fast-moving project.'
}, {
  q: 'What platforms is this for?',
  a: 'Windows 10 and Windows 11 on x64. This fork is focused on shipping a native Windows app.'
}, {
  q: 'Anything to know before installing?',
  a: 'Yes. Releases are signed, but Windows SmartScreen can still warn while publisher reputation is new.'
}, {
  q: 'Does it phone home?',
  a: 'No telemetry or analytics. The updater only checks GitHub for new releases and stays notify-only.'
}];
function WhyFork({
  theme
}) {
  const C = theme === 'dark' ? {
    fg: '#e5e5e5',
    dim: '#8a8a92',
    rule: '#1e1e22',
    label: '#707078'
  } : {
    fg: '#0a0a0a',
    dim: '#4a4a48',
    rule: '#d8d8d6',
    label: '#6a6a68'
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gridTemplateColumns: 'repeat(2, minmax(0, 1fr))',
      gap: '14px 28px',
      borderTop: `1px solid ${C.rule}`,
      paddingTop: 18
    },
    className: "wg-why-grid"
  }, WHY_ITEMS.map((item, i) => /*#__PURE__*/React.createElement("div", {
    key: i,
    style: {
      display: 'flex',
      gap: 14,
      alignItems: 'baseline',
      padding: '2px 0'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--mono)',
      fontSize: 11,
      color: C.label,
      letterSpacing: '0.12em',
      flexShrink: 0,
      paddingTop: 2
    }
  }, String(i + 1).padStart(2, '0')), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    style: {
      color: C.fg,
      fontSize: 15,
      fontWeight: 500,
      letterSpacing: '-0.005em',
      marginBottom: 2
    }
  }, item.q), /*#__PURE__*/React.createElement("div", {
    style: {
      color: C.dim,
      fontSize: 13.5,
      lineHeight: 1.5
    }
  }, item.a)))));
}

// Community section
function Community({
  theme
}) {
  const C = theme === 'dark' ? {
    fg: '#e5e5e5',
    dim: '#8a8a92',
    border: '#26262a',
    bg: '#101012',
    hover: '#141416'
  } : {
    fg: '#0a0a0a',
    dim: '#6a6a68',
    border: '#e4e4e2',
    bg: '#fafaf9',
    hover: '#ffffff'
  };
  const items = [{
    label: 'Source and releases',
    sub: 'code, downloads, release notes',
    href: 'https://github.com/amanthanvi/winghostty'
  }, {
    label: 'Report a bug',
    sub: 'issues are for reproducible problems',
    href: 'https://github.com/amanthanvi/winghostty/issues'
  }, {
    label: 'Upstream Ghostty',
    sub: 'the project this fork builds on',
    href: 'https://ghostty.org'
  }, {
    label: 'Contribute',
    sub: 'docs, patches, and ways to help',
    href: 'https://github.com/amanthanvi/winghostty#contributing'
  }];
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))',
      gap: 16
    }
  }, items.map((it, i) => /*#__PURE__*/React.createElement("a", {
    key: i,
    href: it.href,
    target: "_blank",
    rel: "noreferrer",
    className: "wg-community-card",
    style: {
      display: 'block',
      padding: '24px 24px',
      background: C.bg,
      border: `1px solid ${C.border}`,
      borderRadius: 10,
      textDecoration: 'none',
      transition: 'background 0.18s, transform 0.18s, border-color 0.18s'
    },
    onMouseEnter: e => {
      e.currentTarget.style.background = C.hover;
      e.currentTarget.style.transform = 'translateY(-2px)';
    },
    onMouseLeave: e => {
      e.currentTarget.style.background = C.bg;
      e.currentTarget.style.transform = 'translateY(0)';
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'baseline',
      marginBottom: 10
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      color: C.fg,
      fontSize: 16,
      fontWeight: 500
    }
  }, it.label), /*#__PURE__*/React.createElement("div", {
    style: {
      color: C.dim,
      fontSize: 14
    }
  }, "\u2197")), /*#__PURE__*/React.createElement("div", {
    style: {
      color: C.dim,
      fontFamily: 'var(--mono)',
      fontSize: 12
    }
  }, it.sub))));
}
function Footer({
  theme
}) {
  const C = theme === 'dark' ? {
    fg: '#e5e5e5',
    dim: '#707078',
    rule: '#1e1e22'
  } : {
    fg: '#0a0a0a',
    dim: '#6a6a68',
    rule: '#d8d8d6'
  };
  return /*#__PURE__*/React.createElement("footer", {
    style: {
      borderTop: `1px solid ${C.rule}`,
      paddingTop: 28,
      paddingBottom: 40,
      marginTop: 32
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      justifyContent: 'space-between',
      flexWrap: 'wrap',
      gap: 20,
      alignItems: 'center'
    }
  }, /*#__PURE__*/React.createElement(WinghosttyWordmark, {
    size: 20,
    theme: theme
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 22,
      flexWrap: 'wrap',
      fontFamily: 'var(--mono)',
      fontSize: 12
    }
  }, /*#__PURE__*/React.createElement("a", {
    href: "https://github.com/amanthanvi/winghostty",
    target: "_blank",
    rel: "noreferrer",
    style: {
      color: C.fg,
      textDecoration: 'none'
    }
  }, "GitHub"), /*#__PURE__*/React.createElement("a", {
    href: "https://github.com/amanthanvi/winghostty/releases",
    target: "_blank",
    rel: "noreferrer",
    style: {
      color: C.fg,
      textDecoration: 'none'
    }
  }, "Releases"), /*#__PURE__*/React.createElement("a", {
    href: "https://github.com/amanthanvi/winghostty/issues",
    target: "_blank",
    rel: "noreferrer",
    style: {
      color: C.fg,
      textDecoration: 'none'
    }
  }, "Issues"), /*#__PURE__*/React.createElement("a", {
    href: "https://ghostty.org",
    target: "_blank",
    rel: "noreferrer",
    style: {
      color: C.fg,
      textDecoration: 'none'
    }
  }, "Upstream \u2197"))), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 22,
      display: 'flex',
      justifyContent: 'space-between',
      flexWrap: 'wrap',
      gap: 12,
      color: C.dim,
      fontFamily: 'var(--mono)',
      fontSize: 11
    }
  }, /*#__PURE__*/React.createElement("span", null, "Built on Ghostty's terminal core by Mitchell Hashimoto & contributors. Win32 runtime by ", /*#__PURE__*/React.createElement("a", {
    href: "https://github.com/amanthanvi",
    style: {
      color: C.fg,
      textDecoration: 'none'
    }
  }, "@amanthanvi"), "."), /*#__PURE__*/React.createElement("span", null, "MIT \xB7 Not affiliated with upstream Ghostty")));
}
function FooterCol() {
  return null;
} // legacy stub, no longer used

Object.assign(window, {
  InstallBlock,
  FeatureGrid,
  FeatureCard,
  WhyFork,
  Community,
  Footer
});

// ===== heroes.jsx =====
// Hero — Color Pop (centered + 4-color accents). Canonical, only variant.
// Shared bits: VersionChipColor (live), ColorDots, Kbd, WG_COLORS.

const {
  useEffect: useEffectHero,
  useState: useStateHero
} = React;

// MS flag colors (from the logo)
const WG_COLORS = {
  red: '#F25022',
  green: '#7FBA00',
  blue: '#00A4EF',
  yellow: '#FFB900'
};

// --- Live version hook ---
function useLiveVersion() {
  const initial = typeof window !== 'undefined' && window.WG_VERSION || '1.3.106';
  const [v, setV] = useStateHero(initial);
  useEffectHero(() => {
    const onUpdate = e => {
      const newV = e?.detail?.version || window.WG_VERSION || initial;
      setV(newV);
    };
    window.addEventListener('wg-version-updated', onUpdate);
    if (window.WG_VERSION && window.WG_VERSION !== initial) setV(window.WG_VERSION);
    return () => window.removeEventListener('wg-version-updated', onUpdate);
  }, []);
  return v;
}
function ColorDots({
  size = 8,
  gap = 6
}) {
  const cs = [WG_COLORS.red, WG_COLORS.green, WG_COLORS.blue, WG_COLORS.yellow];
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      gap,
      alignItems: 'center'
    }
  }, cs.map(c => /*#__PURE__*/React.createElement("span", {
    key: c,
    style: {
      width: size,
      height: size,
      borderRadius: 2,
      background: c,
      display: 'inline-block'
    }
  })));
}
function VersionChipColor({
  theme,
  meta
}) {
  const v = useLiveVersion();
  const C = theme === 'dark' ? {
    bg: '#101012',
    border: '#26262a',
    fg: '#c4c4c8',
    dim: '#707078',
    sep: '#2e2e34'
  } : {
    bg: '#ffffff',
    border: '#d8d8d6',
    fg: '#3a3a38',
    dim: '#7a7a78',
    sep: '#dcdcda'
  };
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 10,
      padding: '6px 14px 6px 10px',
      borderRadius: 999,
      background: C.bg,
      border: `1px solid ${C.border}`,
      fontFamily: 'var(--mono)',
      fontSize: 11,
      color: C.fg,
      letterSpacing: '0.04em'
    }
  }, /*#__PURE__*/React.createElement(ColorDots, {
    size: 7,
    gap: 4
  }), /*#__PURE__*/React.createElement("span", null, `v${v} · latest release`), meta && /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 1,
      height: 12,
      background: C.sep,
      display: 'inline-block'
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      color: C.dim
    }
  }, meta)));
}
function Kbd({
  children,
  theme
}) {
  const C = theme === 'dark' ? {
    bg: '#1c1c20',
    fg: '#d4d4d8',
    border: '#2e2e34'
  } : {
    bg: '#f3f3f1',
    fg: '#1a1a1a',
    border: '#d8d8d6'
  };
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-block',
      padding: '2px 8px',
      borderRadius: 4,
      background: C.bg,
      color: C.fg,
      border: `1px solid ${C.border}`,
      fontFamily: 'var(--mono)',
      fontSize: 11,
      lineHeight: 1.4
    }
  }, children);
}

// =========================================================
// HERO — Color Pop (canonical)
// =========================================================
function HeroColorPop({
  theme
}) {
  const C = theme === 'dark' ? {
    fg: '#e5e5e5',
    dim: '#8a8a92',
    rule: '#1e1e22'
  } : {
    fg: '#0a0a0a',
    dim: '#4a4a48',
    rule: '#d8d8d6'
  };
  const glowBg = theme === 'dark' ? `radial-gradient(ellipse 60% 50% at 15% 30%, ${WG_COLORS.red}22, transparent 60%),
       radial-gradient(ellipse 50% 40% at 85% 25%, ${WG_COLORS.green}1f, transparent 60%),
       radial-gradient(ellipse 55% 45% at 20% 80%, ${WG_COLORS.blue}22, transparent 60%),
       radial-gradient(ellipse 50% 45% at 85% 80%, ${WG_COLORS.yellow}1e, transparent 60%)` : `radial-gradient(ellipse 60% 50% at 15% 30%, ${WG_COLORS.red}14, transparent 60%),
       radial-gradient(ellipse 50% 40% at 85% 25%, ${WG_COLORS.green}12, transparent 60%),
       radial-gradient(ellipse 55% 45% at 20% 80%, ${WG_COLORS.blue}14, transparent 60%),
       radial-gradient(ellipse 50% 45% at 85% 80%, ${WG_COLORS.yellow}12, transparent 60%)`;
  return /*#__PURE__*/React.createElement("section", {
    style: {
      padding: '8px 0 0',
      textAlign: 'center'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      justifyContent: 'center',
      marginBottom: 22
    }
  }, /*#__PURE__*/React.createElement(VersionChipColor, {
    theme: theme,
    meta: "MIT \xB7 Windows 10 / 11 \xB7 x64"
  })), /*#__PURE__*/React.createElement("h1", {
    style: {
      fontSize: 'clamp(56px, 9vw, 132px)',
      lineHeight: 0.95,
      letterSpacing: '-0.045em',
      fontWeight: 500,
      color: C.fg,
      margin: '0 auto 26px',
      maxWidth: 1100
    }
  }, "Ghostty", /*#__PURE__*/React.createElement("span", {
    style: {
      color: WG_COLORS.red
    }
  }, ","), " finally", /*#__PURE__*/React.createElement("br", null), "on Windows", /*#__PURE__*/React.createElement("span", {
    style: {
      color: WG_COLORS.blue
    }
  }, ".")), /*#__PURE__*/React.createElement("p", {
    style: {
      color: C.dim,
      fontSize: 18,
      lineHeight: 1.5,
      maxWidth: 540,
      margin: '0 auto 28px',
      textWrap: 'pretty'
    }
  }, "The Ghostty you know and love, now on Windows. Winghostty is a Windows-native fork that brings Ghostty's terminal core into a real Windows app, with tabs, splits, profiles, and plain-text configuration."), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 10,
      justifyContent: 'center',
      flexWrap: 'wrap',
      marginBottom: 40,
      alignItems: 'center'
    }
  }, /*#__PURE__*/React.createElement(InstallBlock, {
    theme: theme
  }), /*#__PURE__*/React.createElement("a", {
    href: "https://github.com/amanthanvi/winghostty/releases/latest",
    target: "_blank",
    rel: "noreferrer",
    style: {
      height: 46,
      padding: '0 18px',
      borderRadius: 10,
      textDecoration: 'none',
      color: C.fg,
      border: `1px solid ${C.rule}`,
      fontSize: 14,
      display: 'inline-flex',
      alignItems: 'center',
      gap: 8,
      fontFamily: 'var(--mono)',
      boxSizing: 'border-box',
      transition: 'opacity 0.15s'
    },
    onMouseEnter: e => e.currentTarget.style.opacity = '0.7',
    onMouseLeave: e => e.currentTarget.style.opacity = '1'
  }, "Download \u2197")), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      maxWidth: 1000,
      margin: '0 auto'
    }
  }, /*#__PURE__*/React.createElement("div", {
    "aria-hidden": "true",
    style: {
      position: 'absolute',
      inset: '-80px -40px',
      background: glowBg,
      filter: 'blur(24px)',
      pointerEvents: 'none',
      zIndex: 0
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 1
    }
  }, /*#__PURE__*/React.createElement(WinghosttyTerminal, {
    theme: theme,
    height: 420,
    autoplay: false
  }))));
}
Object.assign(window, {
  HeroColorPop,
  VersionChipColor,
  ColorDots,
  Kbd,
  WG_COLORS
});

// ===== app.jsx =====
// Main app — orchestrates theme, hero variant switching, and lays out page sections.

const {
  useState: useAppState,
  useEffect: useAppEffect
} = React;
function TopBar({
  theme,
  setTheme
}) {
  const C = theme === 'dark' ? {
    fg: '#e5e5e5',
    dim: '#8a8a92',
    border: '#1e1e22',
    chip: '#101012',
    chipActive: '#26262a',
    chipBorder: '#26262a'
  } : {
    fg: '#0a0a0a',
    dim: '#4a4a48',
    border: '#e4e4e2',
    chip: '#ffffff',
    chipActive: '#e8e8e6',
    chipBorder: '#d8d8d6'
  };
  return /*#__PURE__*/React.createElement("header", {
    style: {
      position: 'sticky',
      top: 0,
      zIndex: 50,
      background: theme === 'dark' ? 'rgba(10,10,11,0.9)' : 'rgba(250,250,249,0.94)',
      borderBottom: `1px solid ${C.border}`
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "wg-container",
    style: {
      display: 'flex',
      alignItems: 'center',
      height: 60,
      gap: 16
    }
  }, /*#__PURE__*/React.createElement(WinghosttyWordmark, {
    size: 24,
    theme: theme
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement(WinghosttyToggle, {
    theme: theme,
    onToggle: () => setTheme(theme === 'dark' ? 'light' : 'dark')
  }), /*#__PURE__*/React.createElement("a", {
    href: "https://github.com/amanthanvi/winghostty",
    target: "_blank",
    rel: "noreferrer",
    style: {
      height: 36,
      padding: '0 14px',
      borderRadius: 9,
      background: C.chip,
      border: `1px solid ${C.chipBorder}`,
      color: C.fg,
      textDecoration: 'none',
      fontFamily: 'var(--mono)',
      fontSize: 12,
      display: 'inline-flex',
      alignItems: 'center',
      gap: 8
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "14",
    height: "14",
    viewBox: "0 0 16 16",
    fill: "currentColor"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z"
  })), "GitHub")));
}
function App() {
  const [theme, setTheme] = useAppState(() => localStorage.getItem('wg-theme') || 'dark');
  useAppEffect(() => {
    localStorage.setItem('wg-theme', theme);
  }, [theme]);

  // apply theme tokens to body
  useAppEffect(() => {
    document.body.dataset.theme = theme;
    document.body.style.background = theme === 'dark' ? '#0a0a0b' : '#fafaf9';
    document.body.style.color = theme === 'dark' ? '#e5e5e5' : '#0a0a0a';
  }, [theme]);

  // Edit-mode (tweaks) wiring — listen first, then announce.
  useAppEffect(() => {
    const onMessage = e => {
      const d = e.data || {};
      if (d.type === '__activate_edit_mode') document.body.dataset.editMode = 'on';
      if (d.type === '__deactivate_edit_mode') document.body.dataset.editMode = 'off';
    };
    window.addEventListener('message', onMessage);
    window.parent?.postMessage({
      type: '__edit_mode_available'
    }, '*');
    return () => window.removeEventListener('message', onMessage);
  }, []);
  const C = theme === 'dark' ? {
    fg: '#e5e5e5',
    dim: '#8a8a92',
    rule: '#1e1e22',
    label: '#707078'
  } : {
    fg: '#0a0a0a',
    dim: '#4a4a48',
    rule: '#d8d8d6',
    label: '#6a6a68'
  };
  const Hero = HeroColorPop;
  const SectionLabel = ({
    num,
    title
  }) => /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'baseline',
      gap: 12,
      marginBottom: 24
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'var(--mono)',
      fontSize: 11,
      color: C.label,
      letterSpacing: '0.14em',
      textTransform: 'uppercase'
    }
  }, num), /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: 22,
      fontWeight: 500,
      color: C.fg,
      letterSpacing: '-0.02em'
    }
  }, title));
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(TopBar, {
    theme: theme,
    setTheme: setTheme
  }), /*#__PURE__*/React.createElement("main", null, /*#__PURE__*/React.createElement("div", {
    className: "wg-container",
    style: {
      paddingTop: 40,
      paddingBottom: 56
    }
  }, /*#__PURE__*/React.createElement(Hero, {
    theme: theme
  })), /*#__PURE__*/React.createElement("div", {
    className: "wg-container",
    style: {
      paddingTop: 40,
      paddingBottom: 56,
      contentVisibility: 'auto',
      containIntrinsicSize: '760px'
    }
  }, /*#__PURE__*/React.createElement(SectionLabel, {
    num: "01",
    title: "What you get"
  }), /*#__PURE__*/React.createElement(FeatureGrid, {
    theme: theme
  })), /*#__PURE__*/React.createElement("div", {
    className: "wg-container",
    style: {
      paddingTop: 32,
      paddingBottom: 48,
      contentVisibility: 'auto',
      containIntrinsicSize: '540px'
    }
  }, /*#__PURE__*/React.createElement(SectionLabel, {
    num: "02",
    title: "Why a fork?"
  }), /*#__PURE__*/React.createElement(WhyFork, {
    theme: theme
  })), /*#__PURE__*/React.createElement("div", {
    className: "wg-container",
    style: {
      contentVisibility: 'auto',
      containIntrinsicSize: '220px'
    }
  }, /*#__PURE__*/React.createElement(Footer, {
    theme: theme
  }))));
}
ReactDOM.createRoot(document.getElementById('root')).render(/*#__PURE__*/React.createElement(App, null));
