import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const repoDir = resolve(siteDir, "..");
const trustHtml = readFileSync(join(siteDir, "why-noctty.html"), "utf8");

// Docs cited by the trust page and the migration guides that land with another
// pull request. Each entry must be removed once its PR merges; until then the
// link-resolution checks below skip it and say why.
const PENDING_DOCS = new Map([
  ["docs/windows-benchmark-methodology.md", "#121 / PR #191"],
  ["docs/accessibility-matrix.md", "#145 / PR #192"],
]);

test("trust page publishes exactly eleven standing non-goals", () => {
  assert.equal((trustHtml.match(/\sdata-no-goal(?:\s|>)/g) || []).length, 11);
  assert.doesNotMatch(
    trustHtml,
    /\bAI\b/i,
    "the public page must preserve the ratified silent posture",
  );
});

test("trust page carries every release verification layer", () => {
  assert.match(trustHtml, /Get-FileHash/);
  assert.match(trustHtml, /gh attestation verify/);
  assert.match(trustHtml, /Get-AuthenticodeSignature/);
  assert.match(trustHtml, /verify-published-release\.ps1/);
  assert.match(
    trustHtml,
    /671ec822c41f39b1d79c31d27169b37486333c008c7a038261b4fae53818ce2a/,
  );
});

test("trust page states its limits without hedging", () => {
  // These are the claims the page exists to make. Softening any of them is a
  // regression, not an edit.
  assert.match(
    trustHtml,
    /no code-signing certificate from a public certificate\s+authority/i,
  );
  assert.match(trustHtml, /SmartScreen will\s+warn/);
  assert.match(trustHtml, /32\.14 MB against a 20 MB budget/);
  assert.match(trustHtml, /313 ms p95/);
  assert.match(trustHtml, /No screen reader has been run/);
  assert.match(
    trustHtml,
    /No comparison against another terminal is published/,
  );
});

test("trust page makes no cross-terminal performance claim", () => {
  assert.doesNotMatch(trustHtml, /fast(?:er|est) than/i);
  assert.doesNotMatch(trustHtml, /blazing/i);
});

test("trust page routes to both migration guides", () => {
  assert.match(trustHtml, /docs\/migrate-from-windows-terminal\.md/);
  assert.match(trustHtml, /docs\/migrate-from-git-bash\.md/);
});

test("trust page fragment links point at real section ids", () => {
  const ids = new Set(
    [...trustHtml.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]),
  );
  const fragments = [...trustHtml.matchAll(/\shref="#([^"]+)"/g)].map(
    (match) => match[1],
  );
  assert.ok(fragments.length > 0);
  for (const fragment of fragments)
    assert.ok(ids.has(fragment), `missing #${fragment}`);
});

test("trust page links to repository files that exist", (t) => {
  const linked = [
    ...trustHtml.matchAll(
      /https:\/\/github\.com\/amanthanvi\/noctty\/blob\/main\/([^"#]+)/g,
    ),
  ].map((match) => match[1]);
  assert.ok(linked.length > 0);
  for (const relativePath of new Set(linked)) {
    const pending = PENDING_DOCS.get(relativePath);
    if (pending) {
      t.diagnostic(`${relativePath} lands with ${pending}; not checked yet`);
      continue;
    }
    assert.ok(
      existsSync(join(repoDir, relativePath)),
      `missing ${relativePath}`,
    );
  }
});

for (const relativePath of [
  "docs/migrate-from-windows-terminal.md",
  "docs/migrate-from-git-bash.md",
]) {
  test(`${relativePath} has no broken local Markdown links`, (t) => {
    const absolutePath = join(repoDir, relativePath);
    const markdown = readFileSync(absolutePath, "utf8");
    for (const match of markdown.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
      const target = match[1];
      if (/^(?:https?:|#)/.test(target)) continue;
      const localPath = target.split("#", 1)[0];
      const pending = PENDING_DOCS.get(`docs/${localPath}`);
      if (pending) {
        t.diagnostic(`${localPath} lands with ${pending}; not checked yet`);
        continue;
      }
      assert.ok(
        existsSync(resolve(dirname(absolutePath), localPath)),
        `missing ${target}`,
      );
    }
  });
}

for (const relativePath of [
  "docs/migrate-from-windows-terminal.md",
  "docs/migrate-from-git-bash.md",
]) {
  test(`${relativePath} keeps the honest-gap section`, () => {
    const markdown = readFileSync(join(repoDir, relativePath), "utf8");
    assert.match(markdown, /## Honest gaps/);
    assert.match(markdown, /no screen reader has been\s+measured/i);
    assert.doesNotMatch(markdown, /fast(?:er|est) than/i);
  });
}
