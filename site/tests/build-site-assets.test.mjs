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

test('bare ampersands and non-reference text are left as-is', () => {
  assert.equal(decodeHtmlEntities('a & b &#zz; &; &'), 'a & b &#zz; &; &');
});

test('references beyond the supported set fail the build instead of hashing wrong', () => {
  assert.throws(() => decodeHtmlEntities('this.media=&nbsp;'), /Unsupported HTML named reference "&nbsp;"/);
  assert.throws(() => decodeHtmlEntities('&#x110000;'), /Unsupported HTML character reference/);
  assert.throws(() => decodeHtmlEntities('&#55296;'), /Unsupported HTML character reference/); // lone surrogate
  assert.throws(() => decodeHtmlEntities('&#150;'), /Unsupported HTML character reference/); // windows-1252 remap range
});
