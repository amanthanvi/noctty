import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const siteDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const PAGES = ['index.html', 'why-noctty.html', '404.html'];

const pages = new Map(
  PAGES.map((page) => [page, readFileSync(join(siteDir, page), 'utf8')]),
);

function idsOf(html) {
  return new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
}

// A link to a fragment that no element carries goes to the top of the page
// without a word, which is how a "#universal_palette" guess looked like a
// dead link on the landing page.
test('every fragment link on a page resolves to an id on its target page', () => {
  for (const [page, html] of pages) {
    for (const [, href] of html.matchAll(/\shref="([^"]*#[^"]*)"/g)) {
      if (/^[a-z][a-z0-9+.-]*:/i.test(href)) continue;
      const [path, fragment] = href.split('#');
      const target = path === ''
        ? page
        : path === '/' ? 'index.html' : path.replace(/^\//, '');
      const html2 = pages.get(target);
      assert.ok(html2, `${page}: ${href} points at a page the test does not know`);
      assert.ok(
        idsOf(html2).has(fragment),
        `${page}: ${href} has no matching id in ${target}`,
      );
    }
  }
});

test('the landing page palette feature has a stable id of its own', () => {
  // The element that the "Universal palette" heading labels, whatever its
  // other attributes or their order.
  const opening = pages
    .get('index.html')
    .match(/<[a-z][a-z0-9-]*\s[^>]*\baria-labelledby="palette-title"[^>]*>/i);
  assert.ok(opening, 'no element is labelled by palette-title');
  assert.match(opening[0], /\sid="universal-palette"/);
});
