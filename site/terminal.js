// Terminal demo: a scripted typewriter that stays polite — it pauses
// off-screen and in hidden tabs, sits still under reduced motion, and
// hands control to the Play/Pause button.

export const REDUCED_MOTION_QUERY = '(prefers-reduced-motion: reduce)';

export function subscribeToMediaQuery(mediaQuery, onChange) {
  if (typeof mediaQuery?.addEventListener === 'function') {
    mediaQuery.addEventListener('change', onChange);
    return () => mediaQuery.removeEventListener('change', onChange);
  }
  if (typeof mediaQuery?.addListener === 'function') {
    mediaQuery.addListener(onChange);
    return () => mediaQuery.removeListener(onChange);
  }
  return () => {};
}

export function observeElementVisibility(Observer, element, onChange) {
  if (typeof Observer !== 'function' || !element) return () => {};
  const observer = new Observer(
    ([entry]) => onChange(Boolean(entry?.isIntersecting)),
    { threshold: 0.05 },
  );
  observer.observe(element);
  return () => observer.disconnect();
}

const NC_REPO = 'amanthanvi/noctty';
const PROMPT = 'PS C:\\Users\\dev>';

let NC_VERSION = (typeof window !== 'undefined' && window.NC_VERSION) || '1.3.123';

export function buildScenes(v) {
  return [
    {
      title: 'download setup.exe',
      lines: [
        { kind: 'cmd', text: "$archEnv = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }" },
        { kind: 'cmd', text: "$arch = if ($archEnv -eq 'ARM64') { 'arm64' } else { 'x64' }" },
        { kind: 'cmd', text: `iwr https://github.com/${NC_REPO}/releases/download/v${v}/noctty-${v}-windows-$arch-setup.exe -OutFile noctty-setup.exe` },
        { kind: 'cmd', text: '.\\noctty-setup.exe' },
        { kind: 'out', text: '→ installer build: Start menu entry and standard uninstall path' },
        { kind: 'out', text: '→ x64 and ARM64 installers are Authenticode-signed.' },
        { kind: 'out', text: '→ SmartScreen may still warn: the certificate is self-signed.' },
      ],
    },
    {
      title: 'portable (.zip)',
      lines: [
        { kind: 'cmd', text: "$archEnv = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }" },
        { kind: 'cmd', text: "$arch = if ($archEnv -eq 'ARM64') { 'arm64' } else { 'x64' }" },
        { kind: 'cmd', text: `iwr https://github.com/${NC_REPO}/releases/download/v${v}/noctty-${v}-windows-$arch-portable.zip -OutFile noctty.zip` },
        { kind: 'cmd', text: 'Expand-Archive noctty.zip -DestinationPath .' },
        { kind: 'cmd', text: '.\\noctty\\noctty.exe' },
        { kind: 'out', text: '→ same signed Win32 runtime, no install step required' },
      ],
    },
    {
      title: 'make it yours',
      lines: [
        { kind: 'cmd', text: 'noctty +show-config --default --docs' },
        { kind: 'out', text: '→ config lives at: %LOCALAPPDATA%\\noctty\\config.ghostty' },
        { kind: 'out', text: '→ download mode stages a verified signed installer; you choose when to run it' },
        { kind: 'out', text: '→ profile picker: PowerShell, cmd, Git Bash, and opt-in WSL' },
      ],
    },
  ];
}

if (typeof document !== 'undefined') {
  initTerminalDemo(document.querySelector('[data-nc-terminal]'));
}

function initTerminalDemo(root) {
  if (!root) return;
  const body = root.querySelector('.nc-terminal__body');
  const motionButton = root.querySelector('[data-nc-motion]');
  if (!body || !motionButton) return;

  let scenes = buildScenes(NC_VERSION);
  let sceneIdx = 0;
  let lineIdx = 0;
  let typed = 0;
  let timer = null;
  let liveText = null;
  // 'auto' follows the reduced-motion preference; 'playing'/'paused' are
  // explicit user choices made through the button and override it.
  let motionMode = 'auto';
  let documentActive = !document.hidden;
  let inViewport = true;
  let reducedMotion = window.matchMedia?.(REDUCED_MOTION_QUERY).matches ?? false;

  function shouldAnimate() {
    if (!documentActive || !inViewport) return false;
    if (motionMode === 'playing') return true;
    if (motionMode === 'paused') return false;
    return !reducedMotion;
  }

  function clearTimer() {
    if (timer === null) return;
    window.clearTimeout(timer);
    timer = null;
  }

  function schedule(callback, delay) {
    clearTimer();
    timer = window.setTimeout(() => {
      timer = null;
      callback();
    }, delay);
  }

  function makeCaret() {
    const caret = document.createElement('span');
    caret.className = 'nc-caret';
    caret.setAttribute('aria-hidden', 'true');
    caret.textContent = '▋';
    return caret;
  }

  function appendCommandLine(text, withCaret) {
    const p = document.createElement('p');
    const prompt = document.createElement('span');
    prompt.className = 'nc-terminal__prompt';
    prompt.textContent = PROMPT;
    const live = document.createElement('span');
    live.className = 'nc-terminal__live';
    const textNode = document.createTextNode(text);
    live.append(textNode);
    if (withCaret) live.append(makeCaret());
    p.append(prompt, live);
    body.append(p);
    return textNode;
  }

  function appendOutputLine(text) {
    const div = document.createElement('div');
    div.className = 'nc-terminal__line nc-terminal__line--dim';
    div.textContent = text;
    body.append(div);
  }

  function renderCompletedScene() {
    const scene = scenes[sceneIdx];
    body.textContent = '';
    for (const line of scene.lines) {
      if (line.kind === 'cmd') appendCommandLine(line.text, false);
      else appendOutputLine(line.text);
    }
    appendCommandLine('', true);
    lineIdx = scene.lines.length;
    typed = 0;
    liveText = null;
    body.scrollTop = 0;
  }

  function resetScene() {
    body.textContent = '';
    lineIdx = 0;
    typed = 0;
    liveText = null;
  }

  function step() {
    const scene = scenes[sceneIdx];
    const line = scene.lines[lineIdx];

    if (!line) {
      if (!body.querySelector('.nc-caret')) appendCommandLine('', true);
      schedule(() => {
        sceneIdx = (sceneIdx + 1) % scenes.length;
        resetScene();
        step();
      }, 1800);
      return;
    }

    if (line.kind === 'cmd') {
      if (liveText === null) liveText = appendCommandLine('', true);
      if (typed < line.text.length) {
        schedule(() => {
          typed += 1;
          liveText.nodeValue = line.text.slice(0, typed);
          body.scrollTop = body.scrollHeight;
          step();
        }, 32 + Math.random() * 48);
      } else {
        schedule(() => {
          liveText.parentNode.querySelector('.nc-caret')?.remove();
          liveText = null;
          typed = 0;
          lineIdx += 1;
          step();
        }, 360);
      }
      return;
    }

    schedule(() => {
      appendOutputLine(line.text);
      body.scrollTop = body.scrollHeight;
      lineIdx += 1;
      step();
    }, 220);
  }

  function applyMotionState() {
    const animating = shouldAnimate();
    root.setAttribute('data-motion', animating ? 'playing' : 'paused');
    const label = animating ? 'Pause terminal demo' : 'Play terminal demo';
    motionButton.textContent = animating ? 'Pause' : 'Play';
    motionButton.setAttribute('aria-label', label);
    motionButton.setAttribute('title', label);
    if (animating) {
      if (timer === null) step();
    } else {
      clearTimer();
    }
  }

  motionButton.addEventListener('click', () => {
    const animating = shouldAnimate();
    motionMode = animating ? 'paused' : 'playing';
    // A static completed scene has no in-flight line to resume; restart it.
    if (!animating && liveText === null && lineIdx >= scenes[sceneIdx].lines.length) {
      resetScene();
    }
    applyMotionState();
  });

  document.addEventListener('visibilitychange', () => {
    documentActive = !document.hidden;
    applyMotionState();
  });

  observeElementVisibility(window.IntersectionObserver, root, (visible) => {
    inViewport = visible;
    applyMotionState();
  });

  if (window.matchMedia) {
    subscribeToMediaQuery(window.matchMedia(REDUCED_MOTION_QUERY), (event) => {
      reducedMotion = event.matches;
      applyMotionState();
    });
  }

  window.addEventListener('nc-version-updated', (event) => {
    const next = event?.detail?.version || window.NC_VERSION;
    if (!next || next === NC_VERSION) return;
    NC_VERSION = next;
    window.NC_VERSION = next;
    scenes = buildScenes(NC_VERSION);
    if (shouldAnimate()) {
      resetScene();
      clearTimer();
      step();
    } else {
      renderCompletedScene();
    }
  });

  // The markup ships with scene one pre-rendered for no-JS visitors. With
  // JS running, a non-animating start re-renders that scene from the current
  // data: version.js may have published a cached release before this module's
  // listener existed, and the markup hardcodes the compiled version.
  if (shouldAnimate()) {
    resetScene();
    applyMotionState();
  } else {
    renderCompletedScene();
    applyMotionState();
  }
}
