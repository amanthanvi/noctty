// Hero demo: a scripted noctty window, drawn from captures of the app, that
// plays three steps (the palette, a split, a close and reopen). It pauses
// off-screen and in hidden tabs, sits on a still frame under reduced motion,
// and the step buttons always switch steps. The palette rows, their order
// and the status line are what the app showed for "split" in the captures;
// tests pin each row's title, description and action, the shortcut on the
// rows that show one, and the status format to src/input/command.zig, the
// Windows default keybindings and src/apprt/win32/overlay_view.zig. The
// order and the match count come only from the capture.

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
  // A batch can hold several crossings; the last one is the current state.
  const observer = new Observer(
    (entries) => onChange(Boolean(entries[entries.length - 1]?.isIntersecting)),
    { threshold: 0.05 },
  );
  observer.observe(element);
  return () => observer.disconnect();
}

export const PROMPT = 'PS C:\\dev\\aurora> ';

// Keys the step chips show, with the default action each is bound to.
// Enter is the palette's own key ("Enter activates" in its status line),
// not a binding.
export const DEMO_KEYS = {
  palette: { keys: 'Ctrl+Shift+P', action: 'toggle_command_palette' },
  focus: { keys: 'Alt+Left', action: 'goto_split:left' },
};
export const PALETTE_KEYS = ['Enter'];

// The palette for the query "split", as the app lists it: command title,
// description, and the default shortcut where one exists. "api" is the
// current tab, which the palette also matches.
export const PALETTE_QUERY = 'split';
export const PALETTE_MATCH_COUNT = 46;
export const PALETTE_RESULTS = [
  { title: 'Split Up', description: 'Split the terminal up.', keys: '', action: 'new_split:up' },
  { title: 'Split Down', description: 'Split the terminal down.', keys: 'ctrl+shift+e', action: 'new_split:down' },
  { title: 'Split Left', description: 'Split the terminal to the left.', keys: '', action: 'new_split:left' },
  { title: 'Split Right', description: 'Split the terminal to the right.', keys: 'ctrl+shift+backslash', action: 'new_split:right' },
  { title: 'api', description: 'api', keys: '', tab: true },
  { title: 'Focus Split: Right', description: 'Focus the split to the right, if it exists.', keys: '', action: 'goto_split:right' },
  { title: 'Focus Split: Left', description: 'Focus the split to the left, if it exists.', keys: '', action: 'goto_split:left' },
];
export const PALETTE_PICK = 'Split Right';

// overlay_view.zig: "{d} matches. Selected: {s} — {s}{s} Up/Down selects;
// Enter activates.", where the last {s} is sentenceStop: a period unless the
// description already ends in one.
export function paletteStatus(count, entry) {
  const stop = /[.!?]$/.test(entry.description) ? '' : '.';
  return `${count} matches. Selected: ${entry.title} — ${entry.description}${stop} Up/Down selects; Enter activates.`;
}

// Lines are lists of [text, kind] runs; kind names a color class, or null.
const cmd = (...tokens) => [[PROMPT, null], ...tokens];
export const LEFT_HISTORY = [
  cmd(['git', 'command'], [' ', null], ['log', 'arg'], [' ', null], ['--oneline -n', 'dim'], [' ', null], ['6', 'num']),
  [['ad9957b (', 'yellow'], ['HEAD -> ', 'cyan'], ['main', 'green'], [')', 'yellow'], [' add health check endpoint', null]],
  [['979af40', 'yellow'], [' parse config from env', null]],
  [['2e2cee1', 'yellow'], [' fix off-by-one in pager', null]],
  [['5843869', 'yellow'], [' rename session store', null]],
  [['9f8c4f1', 'yellow'], [' bump deps', null]],
  [['e75d257', 'yellow'], [' initial commit', null]],
  cmd(['git', 'command'], [' ', null], ['status', 'arg']),
  [['On branch main', null]],
  [['nothing to commit, working tree clean', null]],
];
export const RIGHT_COMMAND = [['ls', 'command'], [' ', null], ['-Name', 'dim']];
export const RIGHT_OUTPUT = ['src', '.gitignore', 'package.json', 'README.md'];

if (typeof document !== 'undefined') {
  initDemo(document.querySelector('[data-nc-demo]'));
}

function initDemo(win) {
  if (!win) return;
  const section = win.closest('.nc-demo');
  const panes = win.querySelector('[data-nc-panes]');
  const left = win.querySelector('[data-nc-pane="left"]');
  const right = win.querySelector('[data-nc-pane="right"]');
  const tabLabel = win.querySelector('[data-nc-tab-label]');
  const bar = win.querySelector('[data-nc-palette]');
  const query = win.querySelector('[data-nc-query]');
  const count = win.querySelector('[data-nc-count]');
  const status = win.querySelector('[data-nc-status]');
  const results = win.querySelector('[data-nc-results]');
  const stepButtons = [...section.querySelectorAll('[data-nc-step]')];
  const motionButton = section.querySelector('[data-nc-motion]');
  // Phones show the selected step's explanation under the step row. The
  // caption holds a copy of every step's explanation, stacked in one cell so
  // it is always as tall as the longest, and shows the selected one; it is
  // hidden from screen readers, which read each button's own text.
  const caption = section.querySelector('[data-nc-caption]');
  const captionItems = caption
    ? stepButtons.map((button) => {
        const item = document.createElement('span');
        const body = button.querySelector?.('.nc-step__body');
        if (body) item.append(...[...body.childNodes].map((node) => node.cloneNode(true)));
        return item;
      })
    : [];
  if (caption) caption.replaceChildren(...captionItems);
  // The step buttons' own chips; the caption's copies are pressed alongside.
  const keyChips = new Map(
    [...section.querySelectorAll('[data-nc-key]')]
      .filter((chip) => !chip.closest?.('[data-nc-caption]'))
      .map((chip) => [chip.dataset.ncKey, chip]),
  );
  if (!panes || !left || !right || !bar || !results || !motionButton) return;

  let step = 0;
  // 'auto' follows the reduced-motion preference; 'playing' and 'paused'
  // are explicit choices made with the button and override it.
  let motionMode = 'auto';
  let documentActive = !document.hidden;
  let inViewport = true;
  let reducedMotion = window.matchMedia?.(REDUCED_MOTION_QUERY).matches ?? false;
  let run = 0;
  let running = false;

  // A clock that only advances while the demo plays, so pausing holds a
  // typed line mid-word instead of skipping ahead.
  let pending = null;

  function shouldAnimate() {
    if (!documentActive || !inViewport) return false;
    if (motionMode === 'playing') return true;
    if (motionMode === 'paused') return false;
    return !reducedMotion;
  }

  function sleep(ms, token) {
    return new Promise((resolve, reject) => {
      if (token !== run) {
        reject(new Error('cancelled'));
        return;
      }
      pending = { remaining: ms, resolve, reject, timer: null, started: 0 };
      if (shouldAnimate()) startPending();
    });
  }

  function startPending() {
    if (!pending || pending.timer !== null) return;
    pending.started = performance.now();
    pending.timer = window.setTimeout(() => {
      const done = pending;
      pending = null;
      done.resolve();
    }, pending.remaining);
  }

  function holdPending() {
    if (!pending || pending.timer === null) return;
    window.clearTimeout(pending.timer);
    pending.timer = null;
    pending.remaining = Math.max(0, pending.remaining - (performance.now() - pending.started));
  }

  function cancelPending() {
    if (!pending) return;
    if (pending.timer !== null) window.clearTimeout(pending.timer);
    const cancelled = pending;
    pending = null;
    cancelled.reject(new Error('cancelled'));
  }

  // drawing

  function span(text, kind) {
    if (!kind) return document.createTextNode(text);
    const el = document.createElement('span');
    el.className = `nc-term__${kind}`;
    el.textContent = text;
    return el;
  }

  function line(runs) {
    const div = document.createElement('div');
    div.className = 'nc-term__line';
    for (const [text, kind] of runs) div.append(span(text, kind));
    return div;
  }

  function cursor() {
    const el = document.createElement('span');
    el.className = 'nc-term__cursor';
    return el;
  }

  function promptLine(withCursor = true) {
    const div = line([[PROMPT, null]]);
    if (withCursor) div.append(cursor());
    return div;
  }

  function setSplit(split) {
    panes.classList.toggle('is-split', split);
    right.hidden = !split;
    if (tabLabel) tabLabel.textContent = split ? '* 1: api (2)' : '* 1: api';
  }

  function setFocus(which) {
    left.classList.toggle('is-focused', which === 'left');
    right.classList.toggle('is-focused', which === 'right');
  }

  function drawLeftHistory() {
    left.replaceChildren(...LEFT_HISTORY.map(line), promptLine());
  }

  function drawRightListing() {
    right.replaceChildren(
      line(cmdRuns(RIGHT_COMMAND)),
      ...RIGHT_OUTPUT.map((name) => line([[name, null]])),
      promptLine(),
    );
  }

  function cmdRuns(tokens) {
    return [[PROMPT, null], ...tokens];
  }

  function drawResults(selectedTitle) {
    const selected = PALETTE_RESULTS.find((entry) => entry.title === selectedTitle) ?? PALETTE_RESULTS[0];
    results.replaceChildren(
      ...PALETTE_RESULTS.map((entry) => {
        const li = document.createElement('li');
        if (entry === selected) li.className = 'is-selected';
        for (const text of [entry.title, entry.description, entry.keys]) {
          const cell = document.createElement('span');
          cell.textContent = text;
          li.append(cell);
        }
        return li;
      }),
    );
    results.hidden = false;
    status.textContent = paletteStatus(PALETTE_MATCH_COUNT, selected);
    count.textContent = String(PALETTE_MATCH_COUNT);
  }

  function openBar(text = '') {
    bar.hidden = false;
    query.textContent = text;
    count.textContent = '';
    status.textContent = '';
    results.hidden = true;
  }

  function closeBar() {
    bar.hidden = true;
    results.hidden = true;
  }

  function pressKey(name, pressed) {
    keyChips.get(name)?.classList.toggle('is-pressed', pressed);
    for (const chip of caption?.querySelectorAll(`[data-nc-key="${name}"]`) ?? []) chip.classList.toggle('is-pressed', pressed);
  }

  function releaseKeys() {
    for (const chip of keyChips.values()) chip.classList.remove('is-pressed');
    for (const chip of caption?.querySelectorAll('[data-nc-key]') ?? []) chip.classList.remove('is-pressed');
  }

  function showCaption(index) {
    captionItems.forEach((item, i) => item.classList.toggle('is-active', i === index));
  }

  // Still frames: where the demo starts, and where each step ends.

  function drawStart() {
    releaseKeys();
    win.classList.remove('is-closed');
    closeBar();
    setSplit(false);
    setFocus('left');
    drawLeftHistory();
  }

  function drawEnd(index) {
    releaseKeys();
    win.classList.remove('is-closed');
    if (index === 0) {
      setSplit(false);
      setFocus('left');
      drawLeftHistory();
      openBar(PALETTE_QUERY);
      drawResults(PALETTE_PICK);
    } else if (index === 1) {
      closeBar();
      setSplit(true);
      setFocus('left');
      drawLeftHistory();
      drawRightListing();
    } else {
      closeBar();
      setSplit(true);
      setFocus('left');
      left.replaceChildren(promptLine());
      right.replaceChildren(promptLine());
    }
  }

  // scripts

  async function typeRuns(target, tokens, token) {
    for (const [text, kind] of tokens) {
      const node = span('', kind);
      target.append(node);
      for (const ch of text) {
        await sleep(55 + Math.random() * 45, token);
        node.textContent += ch;
      }
    }
  }

  async function playPalette(token) {
    drawStart();
    await sleep(900, token);
    pressKey('palette', true);
    await sleep(220, token);
    openBar();
    pressKey('palette', false);
    await sleep(450, token);
    for (const ch of PALETTE_QUERY) {
      await sleep(90 + Math.random() * 60, token);
      query.textContent += ch;
    }
    await sleep(160, token);
    drawResults(PALETTE_RESULTS[0].title);
    await sleep(1000, token);
    const pickIndex = PALETTE_RESULTS.findIndex((entry) => entry.title === PALETTE_PICK);
    for (let i = 1; i <= pickIndex; i += 1) {
      await sleep(320, token);
      drawResults(PALETTE_RESULTS[i].title);
    }
    await sleep(1500, token);
  }

  async function playSplit(token) {
    drawEnd(0);
    await sleep(500, token);
    pressKey('enter', true);
    await sleep(200, token);
    pressKey('enter', false);
    closeBar();
    setSplit(true);
    setFocus('right');
    right.replaceChildren(promptLine());
    await sleep(800, token);
    right.replaceChildren();
    const typing = line([[PROMPT, null]]);
    const caret = cursor();
    right.append(typing);
    typing.append(caret);
    const typed = document.createElement('span');
    typing.insertBefore(typed, caret);
    await typeRuns(typed, RIGHT_COMMAND, token);
    await sleep(300, token);
    caret.remove();
    for (const name of RIGHT_OUTPUT) right.append(line([[name, null]]));
    right.append(promptLine());
    await sleep(1100, token);
    pressKey('focus', true);
    await sleep(200, token);
    setFocus('left');
    pressKey('focus', false);
    await sleep(1600, token);
  }

  async function playRestore(token) {
    drawEnd(1);
    await sleep(900, token);
    win.classList.add('is-closed');
    await sleep(1300, token);
    left.replaceChildren(promptLine());
    right.replaceChildren(promptLine());
    setFocus('left');
    win.classList.remove('is-closed');
    await sleep(3200, token);
  }

  const SCRIPTS = [playPalette, playSplit, playRestore];
  // Each script's length with average typing, used only to pace the step
  // underline; the underline pauses with the script's clock.
  const STEP_MS = [5800, 5300, 5400];

  function markStep(index) {
    step = index;
    for (const button of stepButtons) button.setAttribute('aria-pressed', 'false');
    section.style.setProperty('--nc-step-ms', `${STEP_MS[index]}ms`);
    // Restart the underline even when the same step plays again.
    void section.offsetWidth;
    stepButtons[index]?.setAttribute('aria-pressed', 'true');
    showCaption(index);
  }

  async function playFrom(index) {
    const token = ++run;
    running = true;
    let current = index;
    try {
      for (;;) {
        markStep(current);
        await SCRIPTS[current](token);
        if (token !== run) return;
        current = (current + 1) % SCRIPTS.length;
      }
    } catch {
      // A newer run or a step switch cancelled this one.
    } finally {
      if (token === run) running = false;
    }
  }

  function stopRun() {
    run += 1;
    running = false;
    cancelPending();
  }

  function showStill(index) {
    stopRun();
    markStep(index);
    drawEnd(index);
  }

  function applyMotionState() {
    const animating = shouldAnimate();
    // 'paused' holds a step mid-way; 'still' is a finished frame.
    section.setAttribute('data-motion', animating ? 'playing' : running ? 'paused' : 'still');
    const label = animating ? 'Pause the demo' : 'Play the demo';
    motionButton.textContent = animating ? 'Pause' : 'Play';
    motionButton.setAttribute('aria-label', label);
    motionButton.setAttribute('title', label);
    if (animating) {
      if (!running) playFrom(step);
      else startPending();
    } else {
      holdPending();
    }
  }

  stepButtons.forEach((button, index) => {
    button.addEventListener('click', () => {
      if (shouldAnimate()) {
        stopRun();
        playFrom(index);
        applyMotionState();
      } else {
        showStill(index);
        applyMotionState();
      }
    });
  });

  motionButton.addEventListener('click', () => {
    const animating = shouldAnimate();
    motionMode = animating ? 'paused' : 'playing';
    // Resuming from a still frame replays the current step from its start.
    if (!animating && !running) stopRun();
    applyMotionState();
  });

  document.addEventListener('visibilitychange', () => {
    documentActive = !document.hidden;
    applyMotionState();
  });

  observeElementVisibility(window.IntersectionObserver, win, (visible) => {
    inViewport = visible;
    applyMotionState();
  });

  if (window.matchMedia) {
    subscribeToMediaQuery(window.matchMedia(REDUCED_MOTION_QUERY), (event) => {
      reducedMotion = event.matches;
      // Only the automatic mode follows the preference; a visitor's own
      // pause or play stands.
      if (motionMode === 'auto' && !shouldAnimate()) showStill(step);
      applyMotionState();
    });
  }

  // The markup ships the split frame for visitors without JS. With JS, start
  // on the first step: animated when motion is allowed, else its still frame.
  if (shouldAnimate()) {
    markStep(0);
    applyMotionState();
  } else {
    showStill(0);
    applyMotionState();
  }
}
