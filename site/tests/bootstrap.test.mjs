// The inline theme bootstrap is hashed into the CSP, which proves the bytes
// were not tampered with but says nothing about whether they work. A build once
// shipped `/\bnc-no-js\b/` with literal U+0008 backspace bytes in place of the
// escapes: the hash was happily recomputed, and the class swap silently stopped
// running, leaving every JS-only control hidden by `.nc-no-js` rules. These
// tests execute the real bootstrap instead of trusting its hash.

import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const siteDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const PAGES = ['index.html', '404.html'];

function inlineBootstrap(page) {
  const html = readFileSync(join(siteDir, page), 'utf8');
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  assert.equal(scripts.length, 1, `${page} must carry exactly one inline script`);
  return scripts[0];
}

function runBootstrap(source, { stored = null, legacy = null } = {}) {
  const store = new Map();
  if (stored !== null) store.set('nc-theme', stored);
  if (legacy !== null) store.set('wg-theme', legacy);

  const classes = new Set(['nc-no-js']);
  const attributes = new Map();
  const root = {
    classList: {
      add: (c) => classes.add(c),
      remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
    },
    get className() {
      return [...classes].join(' ');
    },
    set className(value) {
      classes.clear();
      for (const c of String(value).split(/\s+/).filter(Boolean)) classes.add(c);
    },
    setAttribute: (k, v) => attributes.set(k, v),
    getAttribute: (k) => attributes.get(k) ?? null,
  };

  const context = {
    document: { documentElement: root },
    localStorage: {
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => store.set(k, String(v)),
      removeItem: (k) => store.delete(k),
    },
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  return { classes, attributes, store };
}

for (const page of PAGES) {
  test(`${page}: bootstrap marks the document as script-enabled`, () => {
    const { classes } = runBootstrap(inlineBootstrap(page));
    assert.equal(classes.has('nc-js'), true, 'nc-js must be added');
    assert.equal(
      classes.has('nc-no-js'),
      false,
      'nc-no-js must be removed, otherwise the JS-only controls stay hidden',
    );
  });

  test(`${page}: bootstrap contains no control characters`, () => {
    const source = inlineBootstrap(page);
    const bad = [...source].filter((c) => {
      const code = c.codePointAt(0);
      return code < 0x20 && c !== '\n' && c !== '\r' && c !== '\t';
    });
    assert.deepEqual(bad, [], 'escape sequences must survive as text, not as control bytes');
  });
}

test('bootstrap defaults to the dark theme', () => {
  const { attributes } = runBootstrap(inlineBootstrap('index.html'));
  assert.equal(attributes.get('data-theme'), 'dark');
});

test('bootstrap honours an already-migrated preference', () => {
  const { attributes, store } = runBootstrap(inlineBootstrap('index.html'), { stored: 'light' });
  assert.equal(attributes.get('data-theme'), 'light');
  assert.equal(store.get('nc-theme'), 'light');
});

test('bootstrap migrates the pre-rebrand wg-theme key', () => {
  const { attributes, store } = runBootstrap(inlineBootstrap('index.html'), { legacy: 'light' });
  assert.equal(attributes.get('data-theme'), 'light', 'a returning visitor keeps light mode');
  assert.equal(store.get('nc-theme'), 'light', 'the value moves to the current key');
  assert.equal(store.has('wg-theme'), false, 'the legacy key is cleared');
});

test('both pages ship the byte-identical bootstrap the CSP pins', () => {
  const [index, notFound] = PAGES.map(inlineBootstrap);
  assert.equal(index, notFound);
});
