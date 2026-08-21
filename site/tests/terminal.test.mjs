import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildScenes,
  observeElementVisibility,
  subscribeToMediaQuery,
} from '../terminal.js';

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

test('demo scenes keep the release-copy guardrail needles', () => {
  const scenes = buildScenes('9.9.9');
  const text = scenes
    .flatMap((scene) => scene.lines.map((line) => line.text))
    .join('\n');

  assert.match(text, /PROCESSOR_ARCHITEW6432/);
  assert.match(text, /windows-\$arch-setup\.exe/);
  assert.match(text, /windows-\$arch-portable\.zip/);
  assert.match(text, /x64 and ARM64/);
  assert.match(text, /SmartScreen may still warn while reputation builds\./);
  assert.match(text, /%LOCALAPPDATA%\\noctty\\config\.ghostty/);
  assert.match(text, /noctty-9\.9\.9-windows-\$arch-setup\.exe/);
});
