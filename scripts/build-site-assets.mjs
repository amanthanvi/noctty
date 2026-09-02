#!/usr/bin/env node
/**
 * Refresh the static site's integrity metadata:
 *  - the CSP inline-script hash in site/_headers (every page must carry a
 *    byte-identical inline theme bootstrap, so exactly one hash is pinned)
 *  - the CSP prohibition on inline event handlers (fonts are self-hosted)
 *  - SHA-256 cache keys (?v=...) on local asset references in every page
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

// Every authored page, with the local assets whose ?v= cache keys it carries.
// index.html is the reference page for the shared inline theme bootstrap.
const SITE_PAGES = new Map([
  [
    "index.html",
    ["styles.css", "app.js", "version.js", "install.js", "terminal.js"],
  ],
  ["404.html", ["styles.css", "app.js"]],
  ["why-noctty.html", ["styles.css", "app.js", "version.js"]],
]);

const sha256Hex = (text) =>
  crypto.createHash("sha256").update(text, "utf8").digest("hex");
const sha256Base64 = (text) =>
  crypto.createHash("sha256").update(text, "utf8").digest("base64");
const siteOrigin = "https://noctty.com";

function readSiteFile(relativePath, directory = siteRoot) {
  const text = fs.readFileSync(path.join(directory, relativePath), "utf8");
  if (/\r/.test(text)) {
    throw new Error(
      `site/${relativePath} must be LF-normalized (found CR bytes).`,
    );
  }
  return text;
}

function getInlineScriptContract(directory = siteRoot) {
  let sharedScript;

  for (const htmlName of SITE_PAGES.keys()) {
    const html = readSiteFile(htmlName, directory);
    const inlineScripts = [
      ...html.matchAll(/<script(?<attrs>[^>]*)>(?<body>.*?)<\/script>/gis),
    ].filter((match) => !/\bsrc\s*=/.test(match.groups.attrs));
    if (inlineScripts.length !== 1) {
      throw new Error(
        `Expected exactly one CSP-hashed inline script in site/${htmlName}.`,
      );
    }
    const script = inlineScripts[0].groups.body;

    const markupWithoutScripts = html.replace(
      /<script[^>]*>.*?<\/script>/gis,
      "",
    );
    const eventAttributeCount = [
      ...markupWithoutScripts.matchAll(/\s+on[a-z][a-z0-9_-]*\s*=/gis),
    ].length;
    if (eventAttributeCount !== 0) {
      throw new Error(
        `Expected no inline event handler attributes in site/${htmlName}; found ${eventAttributeCount}. The CSP pins script-src-attr 'none'.`,
      );
    }

    if (sharedScript !== undefined && script !== sharedScript) {
      throw new Error(
        `site/index.html and site/${htmlName} inline bootstrap scripts differ; they must be byte-identical.`,
      );
    }
    sharedScript = script;
  }

  return {
    scriptHashes: [`sha256-${sha256Base64(sharedScript)}`],
  };
}

export function getHeaderContract(directory = siteRoot) {
  const { scriptHashes } = getInlineScriptContract(directory);
  const cspDirectives = [
    ["default-src", ["'self'"]],
    ["base-uri", ["'none'"]],
    ["object-src", ["'none'"]],
    ["frame-ancestors", ["'none'"]],
    ["form-action", ["'self'"]],
    ["script-src", ["'self'", ...scriptHashes.map((hash) => `'${hash}'`)]],
    ["script-src-attr", ["'none'"]],
    ["style-src", ["'self'"]],
    ["font-src", ["'self'"]],
    ["connect-src", ["'self'", "https://api.github.com"]],
    ["img-src", ["'self'", "data:"]],
    ["frame-src", ["'none'"]],
    ["worker-src", ["'none'"]],
    ["manifest-src", ["'self'"]],
    ["upgrade-insecure-requests", []],
  ];
  const contentSecurityPolicy = cspDirectives
    .map(
      ([name, sources]) =>
        `${name}${sources.length > 0 ? ` ${sources.join(" ")}` : ""}`,
    )
    .join("; ");
  const cacheControl = "public, max-age=0, must-revalidate";
  // Cloudflare Pages overrides custom 404 responses with this stricter policy.
  const notFoundCacheControl = "no-store";
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
    generated_headers_base64: Buffer.from(headersText, "utf8").toString(
      "base64",
    ),
    script_hashes: scriptHashes,
    root: {
      cache_control: cacheControl,
      content_security_policy: contentSecurityPolicy,
      x_content_type_options: "nosniff",
      x_frame_options: "DENY",
      referrer_policy: "strict-origin-when-cross-origin",
      permissions_policy: permissionsPolicy,
    },
    not_found: { cache_control: notFoundCacheControl },
  };
}

// Local <script src> and <link rel="stylesheet"> targets a page actually
// carries. The declared SITE_PAGES array must match this exactly: a reference
// the registry does not know about would ship unversioned behind a
// cache key check that still reported everything current.
// One attribute value in any of the three forms HTML permits: double-quoted,
// single-quoted, and unquoted. Reading only double-quoted values would let
// src='/install.js' stay invisible to discovery and ship without a cache key
// while every check still reported the site current.
function attributeValue(attrs, name) {
  const match = new RegExp(
    `\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'\`=<>]+))`,
    "i",
  ).exec(attrs);
  if (!match) return null;
  return match[1] ?? match[2] ?? match[3] ?? null;
}

function localAssetPath(raw, htmlName) {
  if (!raw) return null;
  let pathname = raw.split(/[?#]/, 1)[0];
  if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(raw)) {
    const target = new URL(raw, siteOrigin);
    if (target.origin !== siteOrigin) return null;
    pathname = target.pathname;
  }
  const normalized = pathname.startsWith("/")
    ? path.posix.normalize(pathname.slice(1))
    : path.posix.normalize(
        path.posix.join(path.posix.dirname(htmlName), pathname),
      );
  if (normalized === ".." || normalized.startsWith("../")) {
    throw new Error(
      `site/${htmlName} references an asset outside site/: ${raw}`,
    );
  }
  return normalized === "." ? null : normalized;
}

export function referencedLocalAssets(html, htmlName = "index.html") {
  const referenced = new Set();
  const add = (raw) => {
    const normalized = localAssetPath(raw, htmlName);
    if (normalized) referenced.add(normalized);
  };
  for (const [, attrs] of html.matchAll(/<script\b([^>]*)>/gi)) {
    add(attributeValue(attrs, "src"));
  }
  for (const [, attrs] of html.matchAll(/<link\b([^>]*)>/gi)) {
    const rel = attributeValue(attrs, "rel");
    if (!rel || !/\bstylesheet\b/i.test(rel)) continue;
    add(attributeValue(attrs, "href"));
  }
  return referenced;
}

// The filesystem, not either list, is the source of truth for what pages
// exist. SITE_PAGES here and the deploy allowlist in
// scripts/build-site-payload.ps1 are checked against it independently, so a
// new page cannot be half-registered in one of them.
// Discovery is recursive and has no directory exemptions, matching the deploy
// allowlist check in scripts/build-site-payload.ps1 exactly. A page authored at
// site/guides/setup.html is otherwise invisible to both registries and to this
// drift check, and 404s in production.
function authoredPageNames(directory = siteRoot) {
  const found = [];
  const walk = (current, prefix) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        walk(path.join(current, entry.name), relativePath);
      } else if (entry.isFile() && /\.html?$/i.test(entry.name)) {
        found.push(relativePath);
      }
    }
  };
  walk(directory, "");
  return found.sort();
}

function assertPageRegistryCoversSite() {
  const authored = authoredPageNames();
  const unregistered = authored.filter((name) => !SITE_PAGES.has(name));
  const missing = [...SITE_PAGES.keys()].filter(
    (name) => !authored.includes(name),
  );
  if (unregistered.length > 0 || missing.length > 0) {
    throw new Error(
      [
        "SITE_PAGES does not match the authored pages in site/.",
        unregistered.length > 0
          ? `  Authored but unregistered: ${unregistered.join(", ")}`
          : null,
        missing.length > 0
          ? `  Registered but absent from disk: ${missing.join(", ")}`
          : null,
        "Add the page to SITE_PAGES here and to the allowlist in scripts/build-site-payload.ps1.",
      ]
        .filter(Boolean)
        .join("\n"),
    );
  }
}

function assertDeclaredAssetsAreComplete(htmlName, html, assets) {
  const declared = new Set(assets);
  const undeclared = [...referencedLocalAssets(html, htmlName)].filter(
    (asset) => !declared.has(asset),
  );
  if (undeclared.length > 0) {
    throw new Error(
      `site/${htmlName} references local assets missing from its SITE_PAGES entry: ${undeclared.join(", ")}. ` +
        "Undeclared references never receive a ?v= cache key.",
    );
  }
}

function withVersionedAttribute(attrs, name, htmlName, assets, referenced) {
  const pattern = new RegExp(
    `(\\s${name}\\s*=\\s*)(?:"([^"]*)"|'([^']*)'|([^\\s"'\`=<>]+))`,
    "i",
  );
  return attrs.replace(pattern, (match, prefix, double, single, unquoted) => {
    const raw = double ?? single ?? unquoted;
    const asset = localAssetPath(raw, htmlName);
    if (!asset || !Object.hasOwn(assets, asset)) return match;
    referenced.add(asset);
    const versioned = `${raw.split(/[?#]/, 1)[0]}?v=${assets[asset]}`;
    if (double !== undefined) return `${prefix}"${versioned}"`;
    if (single !== undefined) return `${prefix}'${versioned}'`;
    return `${prefix}${versioned}`;
  });
}

export function withAssetCacheKeys(html, htmlName, assets) {
  const referenced = new Set();
  let result = html.replace(/<script\b([^>]*)>/gi, (tag, attrs) =>
    tag.replace(
      attrs,
      withVersionedAttribute(attrs, "src", htmlName, assets, referenced),
    ),
  );
  result = result.replace(/<link\b([^>]*)>/gi, (tag, attrs) => {
    const rel = attributeValue(attrs, "rel");
    if (!rel || !/\bstylesheet\b/i.test(rel)) return tag;
    return tag.replace(
      attrs,
      withVersionedAttribute(attrs, "href", htmlName, assets, referenced),
    );
  });
  for (const asset of Object.keys(assets)) {
    if (!referenced.has(asset)) {
      throw new Error(
        `site/${htmlName} does not reference required local asset ${asset}.`,
      );
    }
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

  assertPageRegistryCoversSite();
  const pages = new Map(
    [...SITE_PAGES.keys()].map((htmlName) => [
      htmlName,
      readSiteFile(htmlName),
    ]),
  );
  const headerContract = getHeaderContract();

  const assetHashes = {};
  for (const asset of new Set([...SITE_PAGES.values()].flat())) {
    assetHashes[asset] = sha256Hex(readSiteFile(asset));
  }

  const expectedPages = new Map();
  for (const [htmlName, assets] of SITE_PAGES) {
    assertDeclaredAssetsAreComplete(htmlName, pages.get(htmlName), assets);
    expectedPages.set(
      htmlName,
      withAssetCacheKeys(
        pages.get(htmlName),
        htmlName,
        Object.fromEntries(assets.map((asset) => [asset, assetHashes[asset]])),
      ),
    );
  }

  const headers = readSiteFile("_headers");
  const expectedHeaders = Buffer.from(
    headerContract.generated_headers_base64,
    "base64",
  ).toString("utf8");

  for (const [htmlName, expected] of expectedPages) {
    updateOrCheck(htmlName, expected, pages.get(htmlName));
  }
  updateOrCheck("_headers", expectedHeaders, headers);

  if (failures.length > 0) {
    throw new Error(
      `Deterministic site asset check failed:\n - ${failures.join("\n - ")}\nRun: node scripts/build-site-assets.mjs`,
    );
  }

  console.log(
    checkOnly
      ? "Site CSP hashes and SHA-256 asset cache keys are current."
      : `Site assets current (script ${headerContract.script_hashes[0]}).`,
  );
}

if (
  process.argv[1] &&
  pathToFileURL(process.argv[1]).href === import.meta.url
) {
  if (checkOnly && printHeaderContract) {
    throw new Error("Use only one of --check or --print-header-contract.");
  }
  if (printHeaderContract) {
    process.stdout.write(`${JSON.stringify(getHeaderContract())}\n`);
  } else {
    main();
  }
}
