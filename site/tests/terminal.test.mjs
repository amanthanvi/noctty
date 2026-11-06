import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  DEMO_KEYS,
  PALETTE_KEYS,
  PALETTE_MATCH_COUNT,
  PALETTE_PICK,
  PALETTE_RESULTS,
  observeElementVisibility,
  paletteStatus,
  subscribeToMediaQuery,
} from '../terminal.js';

const siteDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const repoDir = join(siteDir, '..');
const indexHtml = readFileSync(join(siteDir, 'index.html'), 'utf8');
const commandTitles = readFileSync(join(repoDir, 'src/input/command.zig'), 'utf8');
const windowsKeybinds = readFileSync(
  join(repoDir, 'src/cli/testdata/default_keybinds_windows.txt'),
  'utf8',
);
const windowsDocs = readFileSync(join(repoDir, 'docs/windows.md'), 'utf8');
const win32OverlayView = readFileSync(join(repoDir, 'src/apprt/win32/overlay_view.zig'), 'utf8');

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// "Ctrl+Shift+\" as the site writes it, "ctrl+shift+backslash" as the
// keybind fixture does.
const KEY_NAMES = { '\\': 'backslash', left: 'arrow_left', right: 'arrow_right' };
function fixtureTrigger(label) {
  return label
    .split('+')
    .map((part) => {
      const lower = part.toLowerCase();
      return KEY_NAMES[lower] ?? lower;
    })
    .join('+');
}

// trigger -> action, from the shipped Windows defaults.
const defaultBindings = new Map(
  [...windowsKeybinds.matchAll(/^keybind = (.+?)=([^=\n]+)$/gm)].map((match) => [
    match[1],
    match[2].trim(),
  ]),
);


test('media query subscription uses only the modern API when available', () => {
  const calls = [];
  const listener = () => {};
  const mediaQuery = {
    addEventListener: (...args) => calls.push(['addEventListener', ...args]),
    removeEventListener: (...args) => calls.push(['removeEventListener', ...args]),
    addListener: (...args) => calls.push(['addListener', ...args]),
    removeListener: (...args) => calls.push(['removeListener', ...args]),
  };

  const unsubscribe = subscribeToMediaQuery(mediaQuery, listener);
  unsubscribe();

  assert.deepEqual(calls, [
    ['addEventListener', 'change', listener],
    ['removeEventListener', 'change', listener],
  ]);
});

test('media query subscription falls back to the legacy API', () => {
  const calls = [];
  const listener = () => {};
  const mediaQuery = {
    addListener: (...args) => calls.push(['addListener', ...args]),
    removeListener: (...args) => calls.push(['removeListener', ...args]),
  };

  const unsubscribe = subscribeToMediaQuery(mediaQuery, listener);
  unsubscribe();

  assert.deepEqual(calls, [
    ['addListener', listener],
    ['removeListener', listener],
  ]);
});

test('viewport observation forwards visibility and disconnects', () => {
  const element = {};
  const visibility = [];
  let observed;
  let disconnected = false;
  class Observer {
    constructor(callback, options) {
      this.callback = callback;
      assert.deepEqual(options, { threshold: 0.05 });
    }

    observe(value) {
      observed = value;
      this.callback([{ isIntersecting: true }]);
    }

    disconnect() {
      disconnected = true;
    }
  }

  const stop = observeElementVisibility(Observer, element, (value) => visibility.push(value));
  stop();

  assert.equal(observed, element);
  assert.deepEqual(visibility, [true]);
  assert.equal(disconnected, true);
});

test('viewport observation takes the last crossing in a batch', () => {
  const visibility = [];
  class Observer {
    constructor(callback) {
      this.callback = callback;
    }

    observe() {
      // Scrolled in and back out before the callback ran.
      this.callback([{ isIntersecting: true }, { isIntersecting: false }]);
    }

    disconnect() {}
  }

  observeElementVisibility(Observer, {}, (value) => visibility.push(value));
  assert.deepEqual(visibility, [false]);
});


test('every key the demo presses is a shipped Windows default for that action', () => {
  for (const [name, { keys, action }] of Object.entries(DEMO_KEYS)) {
    assert.equal(
      defaultBindings.get(fixtureTrigger(keys)),
      action,
      `${name}: ${keys} is not bound to ${action} by default`,
    );
  }
});

test('the demo palette rows are real commands with their real defaults', () => {
  for (const entry of PALETTE_RESULTS) {
    if (entry.tab) continue;
    // command.zig lists each entry as action, title, description in order.
    const [name, arg] = entry.action.split(':');
    const pattern = new RegExp(
      `\\.action = \\.\\{ \\.${name} = \\.${arg} \\},\\s*` +
        `\\.title = "${escapeRegExp(entry.title)}",\\s*` +
        `\\.description = "${escapeRegExp(entry.description)}"`,
    );
    assert.match(commandTitles, pattern, `no command ${entry.title} with that action and description`);
    if (entry.keys) {
      assert.equal(
        defaultBindings.get(entry.keys),
        entry.action,
        `${entry.title}: ${entry.keys} is not bound to ${entry.action} by default`,
      );
    }
  }
  assert.ok(PALETTE_RESULTS.some((entry) => entry.title === PALETTE_PICK));
});

test('the demo palette status line uses the app format', () => {
  assert.ok(
    win32OverlayView.includes('"{d} matches. Selected: {s} — {s}{s} Up/Down selects; Enter activates."'),
    'overlay_view.zig no longer carries the status format the demo copies',
  );
  const pick = PALETTE_RESULTS.find((entry) => entry.title === PALETTE_PICK);
  assert.equal(
    paletteStatus(PALETTE_MATCH_COUNT, pick),
    `${PALETTE_MATCH_COUNT} matches. Selected: Split Right — Split the terminal to the right. Up/Down selects; Enter activates.`,
  );
});

test('every key chip on the landing page is a shipped Windows default', () => {
  // The palette's own keys are not bindings; its status line names them.
  for (const key of PALETTE_KEYS) {
    assert.ok(win32OverlayView.includes(`${key} activates`), `overlay_view.zig no longer says "${key} activates"`);
  }
  const chips = [
    ...indexHtml.matchAll(/<(?:kbd|span class="nc-kbd"[^>]*)>([^<]+)<\/(?:kbd|span)>/g),
  ].map((match) => match[1].replace(/&gt;/g, '>').replace(/&lt;/g, '<').trim());
  assert.ok(chips.length >= 6, `expected the landing page key chips, found ${chips.length}`);
  for (const label of chips) {
    if (PALETTE_KEYS.includes(label)) continue;
    assert.ok(
      defaultBindings.has(fixtureTrigger(label)),
      `${label} is not a default Windows binding`,
    );
  }
});

test('the restart step promises only what session restore keeps', () => {
  // docs/windows.md: windows, tabs, split layout, profiles, working
  // directories and explicit titles return; child processes do not, and
  // terminal contents only with window-save-state-scrollback.
  assert.match(windowsDocs, /Session restore persists host windows, tabs, split layout/);
  assert.match(windowsDocs, /It does not restore\s+child process state/);
  // Only explicit titles are saved, and a window started with -e or an
  // explicit directory (Explorer's entry) neither restores nor saves.
  assert.match(indexHtml, /any title you set/);
  assert.match(
    indexHtml,
    /opened from Explorer, the jump list, or with\s+<code>-e<\/code>\s+stays out of the saved session/,
  );
  assert.match(windowsDocs, /an SSH pane comes back as the default shell/);
  assert.match(indexHtml, /SSH panes reopen as your default shell/);
  assert.match(indexHtml, /Programs start fresh/);
  assert.match(indexHtml, /window-save-state-scrollback/);
  assert.doesNotMatch(indexHtml, /(?:processes|programs|shells) (?:survive|keep running|come back)/i);
});

test('each demo key chip shows the key its step presses', () => {
  const chips = [...indexHtml.matchAll(/<span class="nc-kbd" data-nc-key="([^"]+)">([^<]+)<\/span>/g)];
  assert.ok(chips.length >= 3, `expected the demo step chips, found ${chips.length}`);
  for (const [, name, text] of chips) {
    const expected = DEMO_KEYS[name]?.keys ?? PALETTE_KEYS.find((key) => key.toLowerCase() === name);
    assert.equal(text, expected, `the ${name} chip says ${text}`);
  }
});

test('the demo status line adds a full stop only where the app does', () => {
  const tab = PALETTE_RESULTS.find((entry) => entry.tab);
  assert.equal(
    paletteStatus(PALETTE_MATCH_COUNT, tab),
    `${PALETTE_MATCH_COUNT} matches. Selected: api — api. Up/Down selects; Enter activates.`,
  );
  assert.match(win32OverlayView, /fn sentenceStop\(text: \[\]const u8\) \[\]const u8 \{[\s\S]*?'\.', '!', '\?' => "",\s*else => "\.",/);
});
