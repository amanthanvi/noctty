#!/usr/bin/env node
/**
 * Bundle site/main.jsx and emit deterministic site assets and headers.
 * Run: node scripts/build-site-bundle.mjs
 */
import fs from "node:fs";
import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const checkOnly = process.argv.includes("--check");
const printHeaderContract = process.argv.includes("--print-header-contract");
const siteDirectoryArgument = process.argv.find((argument) =>
  argument.startsWith("--site-directory="),
);
const siteRoot = siteDirectoryArgument
  ? path.resolve(siteDirectoryArgument.slice("--site-directory=".length))
  : path.join(root, "site");
const entryFile = path.join(siteRoot, "main.jsx");
const outFile = path.join(siteRoot, "bundle.js");
const headersFile = path.join(siteRoot, "_headers");
const esbuildFile = path.join(root, "site", "node_modules", "esbuild", "bin", "esbuild");
const tempDir = printHeaderContract
  ? null
  : fs.mkdtempSync(path.join(os.tmpdir(), "winghostty-site-"));
const bundleSourceDir = tempDir ? path.join(tempDir, "source") : null;
const generatedOutFile = tempDir ? path.join(tempDir, "bundle.js") : null;

const normalizeLf = (text) => text.replace(/\r\n?/g, "\n");
const sha256 = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const cspSha256 = (value) =>
  `sha256-${crypto.createHash("sha256").update(value, "utf8").digest("base64")}`;
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function decodeHtmlAttribute(value) {
  const namedEntities = new Map([
    ["amp", "&"],
    ["apos", "'"],
    ["gt", ">"],
    ["lt", "<"],
    ["quot", '"'],
  ]);
  return value
    .replace(/&#x([0-9a-f]+);/gi, (_match, code) =>
      String.fromCodePoint(Number.parseInt(code, 16)),
    )
    .replace(/&#(\d+);/g, (_match, code) =>
      String.fromCodePoint(Number.parseInt(code, 10)),
    )
    .replace(/&(amp|apos|gt|lt|quot);/g, (_match, name) =>
      namedEntities.get(name),
    );
}

function getInlineScriptContract() {
  const scriptHashes = new Set();
  const scriptAttributeHashes = new Set();
  for (const htmlName of ["index.html", "404.html"]) {
    const htmlPath = path.join(siteRoot, htmlName);
    if (!fs.existsSync(htmlPath)) throw new Error(`Missing ${htmlPath}`);
    const html = fs.readFileSync(htmlPath, "utf8");
    const inlineScripts = [...html.matchAll(/<script(?<attrs>[^>]*)>(?<body>.*?)<\/script>/gis)]
      .filter((match) => !/\bsrc\s*=/.test(match.groups.attrs));
    if (inlineScripts.length !== 1) {
      throw new Error(`Expected exactly one CSP-hashed inline script in ${htmlName}.`);
    }
    scriptHashes.add(cspSha256(inlineScripts[0].groups.body));

    const eventAttributeCount = [...html.matchAll(/\s+on[a-z][a-z0-9_-]*\s*=/gis)].length;
    const eventHandlers = [...html.matchAll(
      /\s+on[a-z][a-z0-9_-]*\s*=\s*(?<quote>["'])(?<body>.*?)\k<quote>/gis,
    )];
    if (eventAttributeCount !== 1 || eventHandlers.length !== 1) {
      throw new Error(`Expected exactly one quoted CSP-hashed event handler in ${htmlName}.`);
    }
    scriptAttributeHashes.add(cspSha256(decodeHtmlAttribute(eventHandlers[0].groups.body)));
  }
  return {
    scriptHashes: [...scriptHashes],
    scriptAttributeHashes: [...scriptAttributeHashes],
  };
}

function getHeaderContract() {
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
    ["style-src", ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"]],
    ["style-src-attr", ["'unsafe-inline'"]],
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
    bundle: { cache_control: cacheControl },
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

function updateOrCheckHtml(htmlName, assets, failures) {
  const htmlPath = path.join(siteRoot, htmlName);
  const current = fs.readFileSync(htmlPath, "utf8");
  const expected = withAssetCacheKeys(current, `site/${htmlName}`, assets);
  if (checkOnly) {
    if (current !== expected) failures.push(`site/${htmlName} has stale SHA-256 asset cache keys.`);
  } else if (current !== expected) {
    fs.writeFileSync(htmlPath, expected, "utf8");
    console.log(`Updated ${htmlPath}`);
  }
}

if (checkOnly && printHeaderContract) {
  throw new Error("Use only one of --check or --print-header-contract.");
}
if (printHeaderContract) {
  process.stdout.write(`${JSON.stringify(getHeaderContract())}\n`);
  process.exit(0);
}
if (!fs.existsSync(entryFile)) throw new Error(`Missing ${entryFile}`);
if (!fs.existsSync(esbuildFile)) {
  throw new Error("Missing site/node_modules/esbuild. Run npm install --prefix site first.");
}

const failures = [];

try {
  fs.mkdirSync(bundleSourceDir);
  fs.copyFileSync(entryFile, path.join(bundleSourceDir, "main.jsx"));
  fs.cpSync(path.join(siteRoot, "components"), path.join(bundleSourceDir, "components"), {
    recursive: true,
  });
  execFileSync(process.execPath, [
    esbuildFile,
    "./main.jsx",
    "--bundle",
    "--loader:.jsx=jsx",
    "--format=iife",
    "--platform=browser",
    "--minify",
    `--outfile=${generatedOutFile}`,
  ], { cwd: bundleSourceDir, stdio: "inherit" });

  const generatedBundle = normalizeLf(fs.readFileSync(generatedOutFile, "utf8"));
  if (checkOnly) {
    const currentBundle = fs.readFileSync(outFile, "utf8");
    if (currentBundle !== generatedBundle) {
      failures.push("site/bundle.js is stale or is not LF-normalized.");
    }
  } else {
    fs.writeFileSync(outFile, generatedBundle, "utf8");
  }

  const assetHashes = {
    "bundle.js": sha256(Buffer.from(generatedBundle, "utf8")),
    "styles.css": sha256(Buffer.from(
      normalizeLf(fs.readFileSync(path.join(siteRoot, "styles.css"), "utf8")),
      "utf8",
    )),
    "app.js": sha256(Buffer.from(
      normalizeLf(fs.readFileSync(path.join(siteRoot, "app.js"), "utf8")),
      "utf8",
    )),
  };

  updateOrCheckHtml("index.html", {
    "bundle.js": assetHashes["bundle.js"],
    "styles.css": assetHashes["styles.css"],
  }, failures);
  updateOrCheckHtml("404.html", {
    "styles.css": assetHashes["styles.css"],
    "app.js": assetHashes["app.js"],
  }, failures);

  const headerContract = getHeaderContract();
  const expectedHeaders = Buffer.from(headerContract.generated_headers_base64, "base64");
  if (checkOnly) {
    if (!fs.existsSync(headersFile) || !fs.readFileSync(headersFile).equals(expectedHeaders)) {
      failures.push("site/_headers is stale or does not match the derived HTML CSP contract.");
    }
  } else if (!fs.existsSync(headersFile) || !fs.readFileSync(headersFile).equals(expectedHeaders)) {
    fs.writeFileSync(headersFile, expectedHeaders);
    console.log(`Updated ${headersFile}`);
  }

  if (failures.length > 0) {
    throw new Error(`Deterministic site build check failed:\n - ${failures.join("\n - ")}`);
  }

  if (checkOnly) {
    console.log("Site bundle, headers, LF normalization, and SHA-256 cache keys are current.");
  } else {
    const stat = fs.statSync(outFile);
    console.log(`Wrote ${outFile} (${(stat.size / 1024).toFixed(1)} KiB)`);
  }
} finally {
  if (tempDir) fs.rmSync(tempDir, { recursive: true, force: true });
}
