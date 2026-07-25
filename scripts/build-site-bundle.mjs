#!/usr/bin/env node
/**
 * Bundle site/main.jsx and emit precompiled site/bundle.js via esbuild.
 * Run: node scripts/build-site-bundle.mjs
 */
import fs from "node:fs";
import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const entryFile = path.join(root, "site", "main.jsx");
const outFile = path.join(root, "site", "bundle.js");
const esbuildFile = path.join(root, "site", "node_modules", "esbuild", "bin", "esbuild");
const checkOnly = process.argv.includes("--check");
const tempDir = checkOnly ? fs.mkdtempSync(path.join(os.tmpdir(), "winghostty-site-")) : null;
const generatedOutFile = tempDir ? path.join(tempDir, "bundle.js") : outFile;

if (!fs.existsSync(entryFile)) throw new Error(`Missing ${entryFile}`);
if (!fs.existsSync(esbuildFile)) {
  throw new Error("Missing site/node_modules/esbuild. Run npm install --prefix site first.");
}

const normalizeLf = (text) => text.replace(/\r\n?/g, "\n");
const sha256 = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

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

function updateOrCheckHtml(relativePath, assets, failures) {
  const htmlPath = path.join(root, relativePath);
  const current = fs.readFileSync(htmlPath, "utf8");
  const expected = withAssetCacheKeys(current, relativePath, assets);
  if (checkOnly) {
    if (current !== expected) failures.push(`${relativePath} has stale SHA-256 asset cache keys.`);
  } else if (current !== expected) {
    fs.writeFileSync(htmlPath, expected, "utf8");
    console.log(`Updated ${htmlPath}`);
  }
}

const failures = [];

try {
  execFileSync(process.execPath, [
    esbuildFile,
    entryFile,
    "--bundle",
    "--loader:.jsx=jsx",
    "--format=iife",
    "--platform=browser",
    "--minify",
    `--outfile=${generatedOutFile}`,
  ], { cwd: root, stdio: "inherit" });

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
      normalizeLf(fs.readFileSync(path.join(root, "site", "styles.css"), "utf8")),
      "utf8",
    )),
    "app.js": sha256(Buffer.from(
      normalizeLf(fs.readFileSync(path.join(root, "site", "app.js"), "utf8")),
      "utf8",
    )),
  };

  updateOrCheckHtml("site/index.html", {
    "bundle.js": assetHashes["bundle.js"],
    "styles.css": assetHashes["styles.css"],
  }, failures);
  updateOrCheckHtml("site/404.html", {
    "styles.css": assetHashes["styles.css"],
    "app.js": assetHashes["app.js"],
  }, failures);

  if (failures.length > 0) {
    throw new Error(`Deterministic site build check failed:\n - ${failures.join("\n - ")}`);
  }

  if (checkOnly) {
    console.log("Site bundle, LF normalization, and SHA-256 asset cache keys are current.");
  } else {
    const stat = fs.statSync(outFile);
    console.log(`Wrote ${outFile} (${(stat.size / 1024).toFixed(1)} KiB)`);
  }
} finally {
  if (tempDir) fs.rmSync(tempDir, { recursive: true, force: true });
}
