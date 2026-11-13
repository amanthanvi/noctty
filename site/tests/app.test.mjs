// app.js runs as a plain script on every page: the theme toggle, following
// the system theme until the visitor picks one, and the 404 page's
// requested-path text. Run the real file against small stubs.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(siteDir, "app.js"), "utf8");

function runApp({
  theme = "dark",
  stored = null,
  storageThrows = false,
  pathname = "/",
  lostSlots = 0,
} = {}) {
  const attributes = new Map([["data-theme", theme]]);
  const store = new Map(stored ? [["nc-theme", stored]] : []);
  const listeners = { media: [], toggle: [] };
  const toggle = {
    setAttribute() {},
    addEventListener: (type, fn) => listeners.toggle.push(fn),
  };
  const slots = Array.from({ length: lostSlots }, () => ({ textContent: "" }));
  const context = {
    document: {
      documentElement: {
        getAttribute: (key) => attributes.get(key) ?? null,
        setAttribute: (key, value) => attributes.set(key, value),
      },
      getElementById: (id) => (id === "theme-toggle" ? toggle : null),
      // Only the 404 page's path slots; no page in these tests has a
      // sideways-scrolling capture or command block ([data-nc-pan]).
      querySelectorAll: (selector) =>
        selector === "[data-nc-lost-path]" ? slots : [],
    },
    window: {
      location: { pathname },
      matchMedia: () => ({
        matches: false,
        addEventListener: (type, fn) => listeners.media.push(fn),
      }),
    },
    localStorage: {
      getItem: (key) => {
        if (storageThrows) throw new Error("blocked");
        return store.get(key) ?? null;
      },
      setItem: (key, value) => {
        if (storageThrows) throw new Error("blocked");
        store.set(key, value);
      },
    },
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  return {
    theme: () => attributes.get("data-theme"),
    systemChanges: (prefersLight) =>
      listeners.media.forEach((fn) => fn({ matches: prefersLight })),
    clickToggle: () => listeners.toggle.forEach((fn) => fn()),
    slots,
  };
}

test("the page follows the system theme until the visitor picks one", () => {
  const page = runApp();
  page.systemChanges(true);
  assert.equal(page.theme(), "light");
  page.clickToggle();
  assert.equal(page.theme(), "dark");
  page.systemChanges(true);
  assert.equal(page.theme(), "dark", "a choice made with the toggle stands");
});

test("a stored choice outranks the system theme", () => {
  const page = runApp({ stored: "dark" });
  page.systemChanges(true);
  assert.equal(page.theme(), "dark");
});

test("a toggle choice holds when storage is blocked", () => {
  const page = runApp({ storageThrows: true });
  page.clickToggle();
  assert.equal(page.theme(), "light");
  page.systemChanges(false);
  assert.equal(page.theme(), "light");
});

test("the 404 path text cannot draw extra lines or reorder text", () => {
  const page = runApp({
    pathname: "/a%0APS%20C:%5C%3E%20irm%20evil%7Ciex%E2%80%AEtxt.exe",
    lostSlots: 2,
  });
  for (const slot of page.slots) {
    assert.doesNotMatch(slot.textContent, /[\n\r\u202e\u2028\u2029]/u);
    assert.equal(slot.textContent, "\\aPS C:\\> irm evil|iextxt.exe");
  }
});

test("the 404 path text is capped by code point", () => {
  const page = runApp({ pathname: `/${"\u{1F600}".repeat(80)}`, lostSlots: 1 });
  const text = page.slots[0].textContent;
  assert.equal(Array.from(text).length, 64);
  assert.ok(text.endsWith("…"));
  assert.doesNotMatch(
    text,
    /[\uD800-\uDBFF](?![\uDC00-\uDFFF])/u,
    "no split surrogate pair",
  );
});
