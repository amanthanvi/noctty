import assert from 'node:assert/strict';
import test from 'node:test';

import { decodeHtmlEntities } from '../../scripts/build-site-assets.mjs';

test('encoded and literal onload handlers decode to the same value', () => {
  assert.equal(decodeHtmlEntities("this.media=&#39;all&#39;"), "this.media='all'");
  assert.equal(decodeHtmlEntities("this.media='all'"), "this.media='all'");
});

test('named and numeric character references decode', () => {
  assert.equal(decodeHtmlEntities('a &amp;&amp; b'), 'a && b');
  assert.equal(decodeHtmlEntities('&lt;x&gt; &quot;q&quot; &apos;a&apos;'), `<x> "q" 'a'`);
  assert.equal(decodeHtmlEntities('&#x27;hex&#X27; &#39;dec&#39;'), "'hex' 'dec'");
});

test('text without character references passes through untouched', () => {
  const literal = "this.media='all'; window.x = 1 & 2";
  assert.equal(decodeHtmlEntities(literal), literal);
});

test('unknown or malformed references are left as-is', () => {
  assert.equal(decodeHtmlEntities('&unknown; &#zz; & plain'), '&unknown; &#zz; & plain');
});
