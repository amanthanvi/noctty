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

// This page publishes no performance figure of its own; every number lives in
// docs/windows-benchmark-methodology.md, so a re-measurement can never strand
// a stale one here. The contract is only worth as much as the units it covers,
// so it covers the formulations a benchmark result is actually written in.
// Case-sensitive where a unit is (MB, GB, KiB) so the lowercase SPKI pin and
// the lowercase ?v= cache keys cannot collide with a byte-size unit.
const PERFORMANCE_FIGURE_PATTERNS = [
  // Durations.
  /\b\d[\d,]*(?:\.\d+)?\s*(?:ms|milliseconds?|µs|μs|us|microseconds?|ns|nanoseconds?|seconds?|minutes?)\b/i,
  /\b\d[\d,]*(?:\.\d+)?\s+s\b/,
  // Rates.
  /\b\d[\d,]*(?:\.\d+)?\s*(?:fps|Hz|kHz|MHz|GHz)\b/i,
  // Byte sizes and throughput, decimal or binary, with or without "per second".
  /\b\d[\d,]*(?:\.\d+)?\s*[KMGT]i?B(?:\s*\/\s*s(?:ec)?)?\b/,
  /\b\d[\d,]*(?:\.\d+)?\s*(?:kilo|mega|giga|tera)bytes?(?:\s+per\s+second)?\b/i,
  // Percentages framed as a performance delta.
  /\b\d+(?:\.\d+)?\s*(?:%|percent)\s*(?:\w+[\s-]+){0,3}(?:faster|slower|improvement|improved|reduction|reduced|speed-?up|overhead|gain|drop|regression|less|fewer|more)\b/i,
  /\b(?:faster|slower|improvement|reduction|speed-?up|overhead|gain|regression)\b[^.]{0,24}?\b\d+(?:\.\d+)?\s*(?:%|percent)/i,
  // "3x throughput", "2.5x faster", and bare multipliers such as "12x".
  /\b\d+(?:\.\d+)?\s*(?:x|×)\s*(?:faster|slower|throughput|speed|performance)\b/i,
  /\b\d+(?:\.\d+)?(?:x|×)\b(?!\d)/,
];

// The page positions the fork without ranking it against anybody. No
// cross-terminal speed claim of any kind is permitted, so the guard has to
// catch comparative performance language generally, not two known phrasings.
const CROSS_TERMINAL_CLAIM_PATTERNS = [
  /\bfast(?:er|est)\b/i,
  /\bslow(?:er|est)\b/i,
  /\b(?:quick|snapp|smooth|responsiv|light|lean)(?:er|est)\b/i,
  /\bblazing(?:ly)?\b/i,
  /\boutperform(?:s|ed|ing)?\b/i,
  /\boutclass(?:es|ed|ing)?\b/i,
  /\b(?:beats|outruns)\b/i,
  /\b(?:best[-\s]performing|most\s+performant|leading\s+terminal)\b/i,
  // "lower latency", "higher throughput", "less memory use than ...".
  /\b(?:lower|higher|less|fewer|more|better|worse|reduced|improved|greater)\s+(?:\w+[\s-]+){0,3}(?:latency|throughput|frame\s?times?|start-?up|overhead|performance|speed|fps|memory\s+use)\b/i,
  // Multipliers of a performance quantity.
  /\b(?:twice|thrice|double|triple|\d+(?:\.\d+)?\s*(?:x|×|times))\s+(?:the\s+)?(?:\w+\s+){0,2}(?:throughput|speed|performance|latency|faster|slower|frame\s?rate|framerate)\b/i,
  // Any measurement stated relative to a named competitor.
  /\b(?:than|versus|vs\.?|compared\s+(?:to|with)|against)\s+(?:\w+\s+){0,2}(?:Windows\s+Terminal|conhost|cmd\.exe|Alacritty|WezTerm|kitty|mintty|ConEmu|Cmder|Hyper|iTerm2?|PuTTY)\b/i,
];

function findClaimViolations(text, patterns) {
  return patterns
    .map((pattern) => text.match(pattern))
    .filter(Boolean)
    .map((match) => match[0].replace(/\s+/g, " ").trim());
}

// A skip that outlives its reason is a hole. Once the document is on the
// branch, the entry has to go, and the link checks below become enforcing.
test("no pending-document exemption outlives the document landing", () => {
  const landed = [...PENDING_DOCS.keys()].filter((relativePath) =>
    existsSync(join(repoDir, relativePath)),
  );
  assert.deepEqual(
    landed,
    [],
    `remove the PENDING_DOCS entries for ${landed.join(", ")}; the links are now checkable`,
  );
});

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
  assert.match(trustHtml, /Two results miss a budget stated in PRODUCT\.md/);
  assert.match(trustHtml, /Key-to-pixel\s+latency is not measured at all/);
  assert.match(trustHtml, /No screen reader has been run/);
  assert.match(
    trustHtml,
    /No comparison against another terminal is published/,
  );
});

test("trust page hardcodes no performance figure", () => {
  // Benchmark numbers move with the machine state and the build they were
  // taken against. The page cites the methodology doc so a re-measurement
  // never leaves an unreproducible figure published here.
  const figures = findClaimViolations(trustHtml, PERFORMANCE_FIGURE_PATTERNS);
  assert.deepEqual(
    figures,
    [],
    `cite docs/windows-benchmark-methodology.md instead of: ${figures.join(", ")}`,
  );
});

test("trust page makes no cross-terminal performance claim", () => {
  const claims = findClaimViolations(trustHtml, CROSS_TERMINAL_CLAIM_PATTERNS);
  assert.deepEqual(
    claims,
    [],
    `no cross-terminal result is published; remove: ${claims.join(", ")}`,
  );
});

test("trust page keeps its scrollable code blocks keyboard-reachable", () => {
  // The verification commands overflow horizontally on a narrow viewport and
  // the hidden part is the argument the reader needs. A scroll container that
  // is not focusable cannot be scrolled without a pointer (WCAG 2.1.1).
  const blocks =
    trustHtml.match(/<pre\b[^>]*class="nc-proof-code"[^>]*>/g) || [];
  assert.ok(blocks.length > 0);
  for (const block of blocks) assert.match(block, /\stabindex="0"/, block);
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
    const claims = findClaimViolations(markdown, CROSS_TERMINAL_CLAIM_PATTERNS);
    assert.deepEqual(
      claims,
      [],
      `no cross-terminal result is published; remove: ${claims.join(", ")}`,
    );
  });
}
