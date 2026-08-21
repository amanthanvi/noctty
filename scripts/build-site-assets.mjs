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
const printHeaderContract = process.argv.includes("--print-header-contract");
const siteDirectoryArgument = process.argv.find((argument) =>
  argument.startsWith("--site-directory="),
);
const siteRoot = siteDirectoryArgument
  ? path.resolve(siteDirectoryArgument.slice("--site-directory=".length))
  : path.join(root, "site");

const sha256Hex = (text) => crypto.createHash("sha256").update(text, "utf8").digest("hex");
const sha256Base64 = (text) => crypto.createHash("sha256").update(text, "utf8").digest("base64");
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Browsers execute the HTML-decoded attribute value, so an encoded handler
// like onload="this.media=&#39;all&#39;" must hash the same as its literal form.
// This builder owns that decoded hash for both _headers generation and the
// PowerShell header verifier. This is deliberately not a full HTML decoder: any
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
  const text = fs.readFileSync(path.join(siteRoot, relativePath), "utf8");
  if (/\r/.test(text)) {
    throw new Error(`site/${relativePath} must be LF-normalized (found CR bytes).`);
  }
  return text;
}

function getInlineScriptContract() {
  let sharedScript;
  let sharedOnload;

  for (const htmlName of ["index.html", "404.html"]) {
    const html = readSiteFile(htmlName);
    const inlineScripts = [
      ...html.matchAll(/<script(?<attrs>[^>]*)>(?<body>.*?)<\/script>/gis),
    ].filter((match) => !/\bsrc\s*=/.test(match.groups.attrs));
    if (inlineScripts.length !== 1) {
      throw new Error(`Expected exactly one CSP-hashed inline script in site/${htmlName}.`);
    }
    const script = inlineScripts[0].groups.body;

    const eventAttributeCount = [
      ...html.matchAll(/\s+on[a-z][a-z0-9_-]*\s*=/gis),
    ].length;
    const eventHandlers = [
      ...html.matchAll(
        /\s+on[a-z][a-z0-9_-]*\s*=\s*(?<quote>["'])(?<body>.*?)\k<quote>/gis,
      ),
    ];
    if (eventAttributeCount !== 1 || eventHandlers.length !== 1) {
      throw new Error(`Expected exactly one quoted CSP-hashed event handler in site/${htmlName}.`);
    }
    const onload = decodeHtmlEntities(eventHandlers[0].groups.body);

    if (sharedScript !== undefined && script !== sharedScript) {
      throw new Error("site/index.html and site/404.html inline bootstrap scripts differ; they must be byte-identical.");
    }
    if (sharedOnload !== undefined && onload !== sharedOnload) {
      throw new Error("site/index.html and site/404.html onload handlers differ; they must be identical.");
    }
    sharedScript = script;
    sharedOnload = onload;
  }

  return {
    scriptHashes: [`sha256-${sha256Base64(sharedScript)}`],
    scriptAttributeHashes: [`sha256-${sha256Base64(sharedOnload)}`],
  };
}

export function getHeaderContract() {
  const { scriptHashes, scriptAttributeHashes } = getInlineScriptContract();
  const cspDirectives = [
    ["default-src", ["'self'"]],
    ["base-uri", ["'none'"]],
    ["object-src", ["'none'"]],
    ["frame-ancestors", ["'none'"]],
    ["form-action", ["'self'"]],
    ["script-src", ["'self'", ...scriptHashes.map((hash) => `'${hash}'`)]],
    [
      "script-src-attr",
      ["'unsafe-hashes'", ...scriptAttributeHashes.map((hash) => `'${hash}'`)],
    ],
    ["style-src", ["'self'", "https://fonts.googleapis.com"]],
    ["font-src", ["'self'", "https://fonts.gstatic.com"]],
    ["connect-src", ["'self'", "https://api.github.com"]],
    ["img-src", ["'self'", "data:"]],
    ["frame-src", ["'none'"]],
    ["worker-src", ["'none'"]],
    ["manifest-src", ["'self'"]],
    ["upgrade-insecure-requests", []],
  ];
  const contentSecurityPolicy = cspDirectives
    .map(([name, sources]) => `${name}${sources.length > 0 ? ` ${sources.join(" ")}` : ""}`)
    .join("; ");
  const cacheControl = "public, max-age=0, must-revalidate";
  const permissionsPolicy =
    "accelerometer=(), autoplay=(), camera=(), geolocation=(), gyroscope=(), " +
    "magnetometer=(), microphone=(), payment=(), usb=()";
  const headersText = [
    "/*",
    `  Content-Security-Policy: ${contentSecurityPolicy}`,
    "  X-Content-Type-Options: nosniff",
    "  X-Frame-Options: DENY",
    "  Referrer-Policy: strict-origin-when-cross-origin",
    `  Permissions-Policy: ${permissionsPolicy}`,
    `  Cache-Control: ${cacheControl}`,
    "",
  ].join("\n");

  return {
    generated_headers_base64: Buffer.from(headersText, "utf8").toString("base64"),
    script_hashes: scriptHashes,
    script_attribute_hashes: scriptAttributeHashes,
    root: {
      cache_control: cacheControl,
      content_security_policy: contentSecurityPolicy,
      x_content_type_options: "nosniff",
      x_frame_options: "DENY",
      referrer_policy: "strict-origin-when-cross-origin",
      permissions_policy: permissionsPolicy,
    },
    not_found: { cache_control: "no-store" },
  };
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
      fs.writeFileSync(path.join(siteRoot, relativePath), expected, "utf8");
      console.log(`Updated site/${relativePath}`);
    }
  }

  const indexHtml = readSiteFile("index.html");
  const notFoundHtml = readSiteFile("404.html");
  const headerContract = getHeaderContract();

  const assetHashes = {};
  for (const asset of ["styles.css", "app.js", "version.js", "install.js", "terminal.js"]) {
    assetHashes[asset] = sha256Hex(readSiteFile(asset));
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

  const headers = readSiteFile("_headers");
  const expectedHeaders = Buffer.from(
    headerContract.generated_headers_base64,
    "base64",
  ).toString("utf8");

  updateOrCheck("index.html", expectedIndex, indexHtml);
  updateOrCheck("404.html", expectedNotFound, notFoundHtml);
  updateOrCheck("_headers", expectedHeaders, headers);

  if (failures.length > 0) {
    throw new Error(`Deterministic site asset check failed:\n - ${failures.join("\n - ")}\nRun: node scripts/build-site-assets.mjs`);
  }

  console.log(checkOnly
    ? "Site CSP hashes and SHA-256 asset cache keys are current."
    : `Site assets current (script ${headerContract.script_hashes[0]}).`);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (checkOnly && printHeaderContract) {
    throw new Error("Use only one of --check or --print-header-contract.");
  }
  if (printHeaderContract) {
    process.stdout.write(`${JSON.stringify(getHeaderContract())}\n`);
  } else {
    main();
  }
}
