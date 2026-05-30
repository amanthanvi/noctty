#!/usr/bin/env node
/**
 * Bundle site/main.jsx and emit precompiled site/bundle.js via esbuild.
 * Run: node scripts/build-site-bundle.mjs
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const entryFile = path.join(root, "site", "main.jsx");
const outFile = path.join(root, "site", "bundle.js");
const esbuildFile = path.join(root, "site", "node_modules", "esbuild", "bin", "esbuild");

if (!fs.existsSync(entryFile)) throw new Error(`Missing ${entryFile}`);
if (!fs.existsSync(esbuildFile)) {
  throw new Error("Missing site/node_modules/esbuild. Run npm install --prefix site first.");
}

execFileSync(process.execPath, [
  esbuildFile,
  entryFile,
  "--bundle",
  "--loader:.jsx=jsx",
  "--format=iife",
  "--platform=browser",
  `--outfile=${outFile}`,
], { cwd: root, stdio: "inherit" });
const stat = fs.statSync(outFile);
console.log(`Wrote ${outFile} (${(stat.size / 1024).toFixed(1)} KiB)`);
