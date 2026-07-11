// Mock terminal window with typewriter animation.

import { TerminalLine } from './terminal/terminal-line.jsx';

const { useEffect, useReducer } = React;

let WG_VERSION = window.WG_VERSION || '1.3.117';
const WG_REPO = 'amanthanvi/winghostty';

function buildScript(v) {
  const scenes = [
    {
      title: 'download setup.exe',
      lines: [
        { kind: 'cmd', text: "$archEnv = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }" },
        { kind: 'cmd', text: "$arch = if ($archEnv -eq 'ARM64') { 'arm64' } else { 'x64' }" },
        { kind: 'cmd', text: `iwr https://github.com/${WG_REPO}/releases/download/v${v}/winghostty-${v}-windows-$arch-setup.exe -OutFile winghostty-setup.exe` },
        { kind: 'cmd', text: '.\\winghostty-setup.exe' },
        { kind: 'out', t: '→ installer build: Start menu entry and standard uninstall path', c: 'dim' },
        { kind: 'out', t: '→ x64 and ARM64 installers are Authenticode-signed.', c: 'dim' },
        { kind: 'out', t: '→ SmartScreen may still warn while reputation builds.', c: 'dim' },
      ],
    },
    {
      title: 'portable (.zip)',
      lines: [
        { kind: 'cmd', text: "$archEnv = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }" },
        { kind: 'cmd', text: "$arch = if ($archEnv -eq 'ARM64') { 'arm64' } else { 'x64' }" },
        { kind: 'cmd', text: `iwr https://github.com/${WG_REPO}/releases/download/v${v}/winghostty-${v}-windows-$arch-portable.zip -OutFile winghostty.zip` },
        { kind: 'cmd', text: 'Expand-Archive winghostty.zip -DestinationPath .\\winghostty' },
        { kind: 'cmd', text: '.\\winghostty\\winghostty.exe' },
        { kind: 'out', t: '→ same signed Win32 runtime, no install step required', c: 'dim' },
      ],
    },
    {
      title: 'make it yours',
      lines: [
        { kind: 'cmd', text: 'winghostty +show-config --default --docs' },
        { kind: 'out', t: '→ config lives at: %LOCALAPPDATA%\\winghostty\\config.ghostty', c: 'dim' },
        { kind: 'out', t: '→ updates stay notify-only and check GitHub at most once every 24 hours', c: 'dim' },
        { kind: 'out', t: '→ profile picker: PowerShell, cmd, Git Bash, and opt-in WSL', c: 'dim' },
      ],
    },
    {
      title: 'launch',
      lines: [
        { kind: 'cmd', text: 'winghostty' },
        { kind: 'out', t: `winghostty ${v} · windows x64/ARM64`, c: 'fg' },
        { kind: 'out', t: '→ native Windows app with tabs, splits, and profiles', c: 'dim' },
        { kind: 'out', t: '→ built on Ghostty\'s terminal core', c: 'dim' },
      ],
    },
  ];

  return scenes.map((scene) => ({
    ...scene,
    lines: scene.lines.map((line, idx) => ({
      ...line,
      id: `${scene.title}:${idx}:${line.kind}:${line.text || line.t || ''}`,
    })),
  }));
}

let TERMINAL_SCRIPT = buildScript(WG_VERSION);
window.WG_VERSION = window.WG_VERSION || WG_VERSION;

function setTerminalVersion(tag) {
  if (!tag || tag === WG_VERSION) return false;
  WG_VERSION = tag;
  window.WG_VERSION = tag;
  TERMINAL_SCRIPT = buildScript(WG_VERSION);
  return true;
}

const PROMPT = 'PS C:\\Users\\dev>';
const scheduleDelay = (...args) => window.setTimeout(...args);

const initialTerminalState = {
  sceneIdx: 0,
  lineIdx: 0,
  typed: '',
};

function terminalReducer(state, action) {
  switch (action.type) {
    case 'type':
      return { ...state, typed: action.text };
    case 'next-line':
      return { ...state, lineIdx: state.lineIdx + 1, typed: '' };
    case 'next-output':
      return { ...state, lineIdx: state.lineIdx + 1 };
    case 'next-scene':
      return {
        sceneIdx: (state.sceneIdx + 1) % action.scriptLength,
        lineIdx: 0,
        typed: '',
      };
    default:
      return state;
  }
}

export function WinghosttyTerminal({
  autoplay = true,
  theme = 'dark',
  height = 440,
  script: initialScript,
}) {
  const [, forceVersion] = useReducer((n) => n + 1, 0);
  useEffect(() => {
    setTerminalVersion(window.WG_VERSION || WG_VERSION);
    forceVersion();

    const onUpdate = (e) => {
      setTerminalVersion(e?.detail?.version || window.WG_VERSION || WG_VERSION);
      forceVersion();
    };
    window.addEventListener('wg-version-updated', onUpdate);
    return () => window.removeEventListener('wg-version-updated', onUpdate);
  }, []);
  const script = initialScript || TERMINAL_SCRIPT;

  const [{ sceneIdx, lineIdx, typed }, dispatch] = useReducer(terminalReducer, initialTerminalState);
  const scene = script[sceneIdx];
  const line = scene?.lines[lineIdx];

  useEffect(() => {
    if (!autoplay || !scene) return;

    if (lineIdx >= scene.lines.length) {
      const t = scheduleDelay(() => {
        dispatch({ type: 'next-scene', scriptLength: script.length });
      }, 1800);
      return () => clearTimeout(t);
    }

    if (!line) return;

    if (line.kind === 'cmd') {
      if (typed.length < line.text.length) {
        const t = scheduleDelay(() => {
          dispatch({ type: 'type', text: line.text.slice(0, typed.length + 1) });
        }, 32 + Math.random() * 48);
        return () => clearTimeout(t);
      }
      const t = scheduleDelay(() => {
        dispatch({ type: 'next-line' });
      }, 360);
      return () => clearTimeout(t);
    }

    const t = scheduleDelay(() => {
      dispatch({ type: 'next-output' });
    }, 220);
    return () => clearTimeout(t);
  }, [autoplay, scene, line, lineIdx, sceneIdx, typed, script]);

  const visible = [];
  if (scene) {
    if (!autoplay) {
      scene.lines.forEach((entry) => visible.push({ key: entry.id, line: entry }));
      visible.push({ key: `${scene.title}:cursor`, line: { kind: 'cmd', text: '', cursor: true } });
    } else {
      scene.lines
        .slice(0, lineIdx)
        .forEach((entry) => visible.push({ key: entry.id, line: entry }));
      if (line && line.kind === 'cmd') {
        visible.push({ key: `${line.id}:typing`, line: { kind: 'cmd', text: typed, cursor: true } });
      } else if (lineIdx >= scene.lines.length) {
        visible.push({ key: `${scene.title}:idle`, line: { kind: 'cmd', text: '', cursor: true } });
      }
    }
  }

  const bodyStyle = height == null ? undefined : { minHeight: height };

  return (
    <div className="wg-terminal" data-theme={theme}>
      <div className="wg-terminal__chrome">
        <div className="wg-terminal__title">
          winghostty · PowerShell · {scene?.title || 'idle'}
        </div>
        <div className="wg-terminal__caption" aria-hidden="true">
          <span className="wg-terminal__caption-btn" />
          <span className="wg-terminal__caption-btn" />
          <span className="wg-terminal__caption-btn wg-terminal__caption-btn--close" />
        </div>
      </div>
      <div className="wg-terminal__body" style={bodyStyle}>
        {visible.map(({ key, line: l }) => {
          if (l.kind === 'cmd') {
            return (
              <TerminalLine
                key={key}
                prompt={PROMPT}
                text={l.text}
                cursor={l.cursor}
              />
            );
          }
          const className = l.c === 'dim' ? 'wg-terminal__line wg-terminal__line--dim' : 'wg-terminal__line';
          return (
            <div key={key} className={className}>
              {l.t}
            </div>
          );
        })}
      </div>
    </div>
  );
}
