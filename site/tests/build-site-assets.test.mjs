import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  getHeaderContract,
  referencedLocalAssets,
  withAssetCacheKeys,
} from "../../scripts/build-site-assets.mjs";

const bootstrap = 'document.documentElement.dataset.theme = "dark";';

function htmlWithInlineScripts(scripts, bodyAttributes = "") {
  return `<html><body${bodyAttributes}>${scripts.map((script) => `<script>${script}</script>`).join("")}</body></html>`;
}

function createSiteFixture(
  t,
  indexHtml,
  notFoundHtml = htmlWithInlineScripts([bootstrap]),
) {
  const siteRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "noctty-site-contract-"),
  );
  t.after(() => fs.rmSync(siteRoot, { recursive: true, force: true }));
  fs.writeFileSync(path.join(siteRoot, "index.html"), indexHtml, "utf8");
  fs.writeFileSync(path.join(siteRoot, "404.html"), notFoundHtml, "utf8");
  // The trust page always matches index.html here, so each fixture below
  // isolates the divergence it is actually testing.
  fs.writeFileSync(path.join(siteRoot, "why-noctty.html"), indexHtml, "utf8");
  return siteRoot;
}

test("the generated CSP derives one live script hash and forbids event handlers", () => {
  const contract = getHeaderContract();
  assert.equal(contract.script_hashes.length, 1);
  assert.match(contract.script_hashes[0], /^sha256-[A-Za-z0-9+/]+={0,2}$/);
  assert.deepEqual(Object.keys(contract), [
    "generated_headers_base64",
    "script_hashes",
    "root",
    "not_found",
  ]);
  assert.match(
    contract.root.content_security_policy,
    /script-src 'self' 'sha256-[^']+';/,
  );
  assert.match(
    contract.root.content_security_policy,
    /script-src-attr 'none';/,
  );
});

test("the generated CSP keeps stylesheet and font origins self-only", () => {
  const policy = getHeaderContract().root.content_security_policy;
  assert.match(policy, /style-src 'self'; font-src 'self';/);
});

test("the generated catch-all cache policy covers root and not-found responses", () => {
  const contract = getHeaderContract();
  assert.equal(
    contract.root.cache_control,
    "public, max-age=0, must-revalidate",
  );
  assert.equal(contract.not_found.cache_control, contract.root.cache_control);
});

for (const [name, scripts] of [
  ["zero", []],
  ["multiple", [bootstrap, bootstrap]],
]) {
  test(`the generated CSP rejects ${name} inline scripts`, (t) => {
    const siteRoot = createSiteFixture(t, htmlWithInlineScripts(scripts));
    assert.throws(
      () => getHeaderContract(siteRoot),
      /Expected exactly one CSP-hashed inline script in site\/index\.html\./,
    );
  });
}

test("the generated CSP rejects inline event handler attributes", (t) => {
  const siteRoot = createSiteFixture(
    t,
    htmlWithInlineScripts([bootstrap], ' onload="alert(1)"'),
  );
  assert.throws(
    () => getHeaderContract(siteRoot),
    /Expected no inline event handler attributes in site\/index\.html; found 1\./,
  );
});

test("the generated CSP ignores JavaScript on-property assignments", (t) => {
  const script = "window.onerror = () => {};";
  const siteRoot = createSiteFixture(
    t,
    htmlWithInlineScripts([script]),
    htmlWithInlineScripts([script]),
  );
  assert.equal(getHeaderContract(siteRoot).script_hashes.length, 1);
});

test("the generated CSP rejects divergent index and not-found bootstraps", (t) => {
  const siteRoot = createSiteFixture(
    t,
    htmlWithInlineScripts([bootstrap]),
    htmlWithInlineScripts([
      'document.documentElement.dataset.theme = "light";',
    ]),
  );
  assert.throws(
    () => getHeaderContract(siteRoot),
    /site\/index\.html and site\/404\.html inline bootstrap scripts differ/,
  );
});

test("same-origin absolute assets are local and receive cache keys", () => {
  const html = [
    '<script src="https://noctty.com/install.js"></script>',
    '<script src="https://example.com/external.js"></script>',
  ].join("");
  assert.deepEqual([...referencedLocalAssets(html)], ["install.js"]);
  assert.equal(
    withAssetCacheKeys(html, "test.html", { "install.js": "digest" }),
    [
      '<script src="https://noctty.com/install.js?v=digest"></script>',
      '<script src="https://example.com/external.js"></script>',
    ].join(""),
  );
});

test("nested-page assets resolve relative to their authored page", () => {
  const html = '<link rel="stylesheet" href="../styles.css">';
  assert.deepEqual(
    [...referencedLocalAssets(html, "guides/setup.html")],
    ["styles.css"],
  );
  assert.equal(
    withAssetCacheKeys(html, "guides/setup.html", { "styles.css": "digest" }),
    '<link rel="stylesheet" href="../styles.css?v=digest">',
  );
  assert.deepEqual(
    [
      ...referencedLocalAssets(
        '<script src="setup.js"></script>',
        "guides/setup.html",
      ),
    ],
    ["guides/setup.js"],
  );
});
