// The copy buttons copy constants from install.js, not the text on the page,
// so nothing else notices when the two drift apart. Pin every button to the
// command shown beside it.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { INSTALL_COMMANDS, VERIFY_COMMANDS } from "../install.js";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const indexHtml = readFileSync(join(siteDir, "index.html"), "utf8");
const aboutHtml = readFileSync(join(siteDir, "why-noctty.html"), "utf8");

const shownText = (html) =>
  html
    .replace(/<wbr\s*\/?>/g, "")
    .replace(/<[^>]+>/g, "")
    .replace(/&gt;/g, ">")
    .replace(/&lt;/g, "<")
    .replace(/&amp;/g, "&")
    .trim();

test("every copy button copies the command shown beside it", () => {
  const pairs = [
    ...indexHtml.matchAll(
      /<div class="nc-cmd">[\s\S]*?<code>([\s\S]*?)<\/code>\s*<button[^>]*data-nc-copy="([^"]+)"/g,
    ),
  ];
  assert.ok(
    pairs.length >= 4,
    `expected the hero and install copy buttons, found ${pairs.length}`,
  );
  const used = new Set();
  for (const [, code, key] of pairs) {
    assert.ok(
      key in INSTALL_COMMANDS,
      `no install command for data-nc-copy="${key}"`,
    );
    assert.equal(
      shownText(code),
      INSTALL_COMMANDS[key],
      `the ${key} button copies something else`,
    );
    used.add(key);
  }
  assert.deepEqual([...used].sort(), Object.keys(INSTALL_COMMANDS).sort());
});

test("every copy button sits next to a command", () => {
  // Landing: the button follows its command. About: the button sits in the
  // bar over its command block.
  const landingButtons = [...indexHtml.matchAll(/data-nc-copy="([^"]+)"/g)].length;
  const landingPaired = [
    ...indexHtml.matchAll(/<code>[\s\S]*?<\/code>\s*<button[^>]*data-nc-copy=/g),
  ].length;
  assert.equal(landingPaired, landingButtons);
  const aboutButtons = [...aboutHtml.matchAll(/data-nc-copy="([^"]+)"/g)].length;
  assert.equal(proofBlocks().length, aboutButtons);
});

// One About verification block: the bar's copy button, then the code.
function proofBlocks() {
  return [
    ...aboutHtml.matchAll(
      /<div class="nc-proof">\s*<div class="nc-proof__bar">[\s\S]*?<button[^>]*data-nc-copy="([^"]+)"[\s\S]*?<\/button>\s*<\/div>\s*<pre class="nc-proof-code"[^>]*><code>([\s\S]*?)<\/code><\/pre>/g,
    ),
  ].map(([, key, code]) => ({ key, code }));
}

// The About page shows each verification command on its own line (one
// block per line, so a long one wraps under itself; spans inside a line keep
// a flag or a file name whole); its copy button copies those lines joined by
// newlines.
test("every About copy button copies the commands shown in its block", () => {
  const blocks = proofBlocks();
  assert.equal(blocks.length, Object.keys(VERIFY_COMMANDS).length);
  for (const { key, code } of blocks) {
    assert.ok(key in VERIFY_COMMANDS, `no command for data-nc-copy="${key}"`);
    const lines = code
      .split(/<span class="nc-proof-line(?: [^"]*)?">/)
      .slice(1)
      .map((line) => shownText(line));
    assert.ok(lines.length > 0, `the ${key} block has no lines`);
    assert.equal(
      lines.join("\n"),
      VERIFY_COMMANDS[key],
      `the ${key} button copies something else`,
    );
  }
});

test("a page with copy buttons has the status region they announce in", () => {
  for (const html of [indexHtml, aboutHtml]) {
    assert.match(html, /aria-live="polite" id="nc-copy-status"/);
    assert.match(html, /src="\/?install\.js\?v=/);
  }
});
