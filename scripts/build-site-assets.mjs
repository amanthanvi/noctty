#!/usr/bin/env node
/**
 * Refresh the static site's integrity metadata:
 *  - the CSP inline-script hash in site/_headers (both pages must carry a
 *    byte-identical inline theme bootstrap, so exactly one hash is pinned)
 *  - the CSP event-handler hash for the font stylesheet onload attribute
 *    (hashed from the HTML-decoded value the browser actually executes)
 *  - SHA-256 cache keys (?v=...) on local asset references in both pages
 *
 * Run: node scripts/build-site-assets.mjs [--check]
 * --check fails without writing when anything on disk is stale.
 */
import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const checkOnly = process.argv.includes("--check");

const sha256Hex = (text) => crypto.createHash("sha256").update(text, "utf8").digest("hex");
const sha256Base64 = (text) => crypto.createHash("sha256").update(text, "utf8").digest("base64");
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Browsers execute the HTML-decoded attribute value, and the header contract
// (scripts/get-site-header-contract.ps1) HtmlDecodes before hashing — so an
// encoded handler like onload="this.media=&#39;all&#39;" must hash the same
// as its literal form. This is deliberately not a full HTML decoder: any
// reference outside the small supported set fails the build instead of
// risking a hash the browser would disagree with (named references beyond
// these five, out-of-range or surrogate code points, and the 0x80-0x9F range
// browsers remap via windows-1252 all decode differently across parsers).
const NAMED_ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

export function decodeHtmlEntities(text) {
  return text.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/g, (match, body) => {
    if (body[0] === "#") {
      const codePoint = body[1] === "x" || body[1] === "X"
        ? Number.parseInt(body.slice(2), 16)
        : Number.parseInt(body.slice(1), 10);
      if (Number.isNaN(codePoint) ||
          codePoint > 0x10ffff ||
          (codePoint >= 0xd800 && codePoint <= 0xdfff) ||
          (codePoint >= 0x80 && codePoint <= 0x9f)) {
        throw new Error(`Unsupported HTML character reference "${match}"; use a literal character or one of the plain numeric forms.`);
      }
      return String.fromCodePoint(codePoint);
    }
    if (!Object.hasOwn(NAMED_ENTITIES, body)) {
      throw new Error(`Unsupported HTML named reference "${match}"; only ${Object.keys(NAMED_ENTITIES).map((name) => `&${name};`).join(" ")} are recognized.`);
    }
    return NAMED_ENTITIES[body];
  });
}

function readSiteFile(relativePath) {
  const text = fs.readFileSync(path.join(root, relativePath), "utf8");
  if (/\r/.test(text)) {
    throw new Error(`${relativePath} must be LF-normalized (found CR bytes).`);
  }
  return text;
}

function extractSingleMatch(text, pattern, relativePath, what) {
  const matches = [...text.matchAll(pattern)];
  if (matches.length !== 1) {
    throw new Error(`${relativePath} must contain exactly one ${what}; found ${matches.length}.`);
  }
  return matches[0][1];
}

function withAssetCacheKeys(html, htmlPath, assets) {
  let result = html;
  for (const [asset, digest] of Object.entries(assets)) {
    const pattern = new RegExp(`(["'])(/?)${escapeRegExp(asset)}(?:\\?v=[^"']*)?\\1`, "g");
    if (!pattern.test(result)) {
      throw new Error(`${htmlPath} does not reference required local asset ${asset}.`);
    }
    pattern.lastIndex = 0;
    result = result.replace(
      pattern,
      (_match, quote, rootPrefix) => `${quote}${rootPrefix}${asset}?v=${digest}${quote}`,
    );
  }
  return result;
}

function main() {
  const failures = [];

  function updateOrCheck(relativePath, expected, current) {
    if (current === expected) return;
    if (checkOnly) {
      failures.push(`${relativePath} is stale.`);
    } else {
      fs.writeFileSync(path.join(root, relativePath), expected, "utf8");
      console.log(`Updated ${relativePath}`);
    }
  }

  const indexHtml = readSiteFile("site/index.html");
  const notFoundHtml = readSiteFile("site/404.html");

  // The inline theme bootstrap must be byte-identical across pages so the CSP
  // pins exactly one script hash.
  const inlineScriptPattern = /<script>([\s\S]*?)<\/script>/g;
  const indexScript = extractSingleMatch(indexHtml, inlineScriptPattern, "site/index.html", "inline <script> block");
  const notFoundScript = extractSingleMatch(notFoundHtml, inlineScriptPattern, "site/404.html", "inline <script> block");
  if (indexScript !== notFoundScript) {
    throw new Error("site/index.html and site/404.html inline bootstrap scripts differ; they must be byte-identical.");
  }

  // The font stylesheet's onload handler is the single allowed event handler.
  const onloadPattern = /onload="([^"]*)"/g;
  const indexOnload = decodeHtmlEntities(
    extractSingleMatch(indexHtml, onloadPattern, "site/index.html", "onload attribute"),
  );
  const notFoundOnload = decodeHtmlEntities(
    extractSingleMatch(notFoundHtml, onloadPattern, "site/404.html", "onload attribute"),
  );
  if (indexOnload !== notFoundOnload) {
    throw new Error("site/index.html and site/404.html onload handlers differ; they must be identical.");
  }

  const scriptHash = sha256Base64(indexScript);
  const handlerHash = sha256Base64(indexOnload);

  const assetHashes = {};
  for (const asset of ["styles.css", "app.js", "version.js", "install.js", "terminal.js"]) {
    assetHashes[asset] = sha256Hex(readSiteFile(`site/${asset}`));
  }

  const expectedIndex = withAssetCacheKeys(indexHtml, "site/index.html", {
    "styles.css": assetHashes["styles.css"],
    "app.js": assetHashes["app.js"],
    "version.js": assetHashes["version.js"],
    "install.js": assetHashes["install.js"],
    "terminal.js": assetHashes["terminal.js"],
  });
  const expectedNotFound = withAssetCacheKeys(notFoundHtml, "site/404.html", {
    "styles.css": assetHashes["styles.css"],
    "app.js": assetHashes["app.js"],
  });

  const headers = readSiteFile("site/_headers");
  let expectedHeaders = headers.replace(
    /script-src 'self'[^;]*/,
    `script-src 'self' 'sha256-${scriptHash}'`,
  );
  expectedHeaders = expectedHeaders.replace(
    /script-src-attr[^;]*/,
    `script-src-attr 'unsafe-hashes' 'sha256-${handlerHash}'`,
  );
  if (!expectedHeaders.includes(scriptHash) || !expectedHeaders.includes(handlerHash)) {
    throw new Error("site/_headers is missing the script-src or script-src-attr directive to rewrite.");
  }

  updateOrCheck("site/index.html", expectedIndex, indexHtml);
  updateOrCheck("site/404.html", expectedNotFound, notFoundHtml);
  updateOrCheck("site/_headers", expectedHeaders, headers);

  if (failures.length > 0) {
    throw new Error(`Deterministic site asset check failed:\n - ${failures.join("\n - ")}\nRun: node scripts/build-site-assets.mjs`);
  }

  console.log(checkOnly
    ? "Site CSP hashes and SHA-256 asset cache keys are current."
    : `Site assets current (script sha256-${scriptHash}).`);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main();
}
