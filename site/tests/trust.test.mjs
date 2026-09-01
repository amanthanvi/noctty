import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, join, posix, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const repoDir = resolve(siteDir, "..");
const trustHtml = readFileSync(join(siteDir, "why-noctty.html"), "utf8");
const publishedVerifier = readFileSync(
  join(repoDir, "scripts/verify-published-release.ps1"),
  "utf8",
);

// Docs cited by the trust page and the migration guides that land with another
// pull request. Each entry names the dependency it waits on so the exemption
// can retire itself: waiting for one exact path to appear would keep skipping a
// genuinely broken link forever if that PR lands the document somewhere else.
const PENDING_DOCS = new Map([
  [
    "docs/windows-benchmark-methodology.md",
    { issue: "#121", pr: "#191", label: "#121 / PR #191" },
  ],
  [
    "docs/accessibility-matrix.md",
    { issue: "#145", pr: "#192", label: "#145 / PR #192" },
  ],
]);

const MIGRATION_GUIDES = [
  "docs/migrate-from-windows-terminal.md",
  "docs/migrate-from-git-bash.md",
];

// A repository-relative link target, resolved from the document that carries
// it rather than assumed to sit beside it.
const linkTargetPath = (fromRelativePath, target) =>
  posix.normalize(
    posix.join(posix.dirname(fromRelativePath), target.split("#", 1)[0]),
  );

// This page publishes no performance figure of its own; every number lives in
// docs/windows-benchmark-methodology.md, so a re-measurement can never strand
// a stale one here. The contract is only worth as much as the units it covers,
// so it covers the formulations a benchmark result is actually written in.
// Case-sensitive where a unit is (MB, GB, KiB) so the lowercase SPKI pin and
// the lowercase ?v= cache keys cannot collide with a byte-size unit.
const BYTE_SIZE_FIGURE_PATTERNS = [
  /\b\d[\d,]*(?:\.\d+)?\s*[KMGT]i?B\b/,
  /\b\d[\d,]*(?:\.\d+)?\s*(?:kilo|mega|giga|tera|kibi|mebi|gibi|tebi)(?:byte|bit)s?\b/i,
];

const BYTE_THROUGHPUT_FIGURE_PATTERNS = [
  /\b\d[\d,]*(?:\.\d+)?\s*[KMGT]i?B\s*\/\s*s(?:ec)?\b/,
  /\b\d[\d,]*(?:\.\d+)?\s*(?:kilo|mega|giga|tera|kibi|mebi|gibi|tebi)(?:byte|bit)s?\s+per\s+second\b/i,
];

const PERFORMANCE_FIGURE_PATTERNS = [
  // Durations.
  /\b\d[\d,]*(?:\.\d+)?\s*(?:ms|milliseconds?|µs|μs|us|microseconds?|ns|nanoseconds?|seconds?|minutes?)\b/i,
  /\b\d[\d,]*(?:\.\d+)?\s+s\b/,
  // Rates, abbreviated and spelled out. "60 fps" and "60 frames per second"
  // are the same published figure, so the guard cannot depend on the author
  // reaching for an abbreviation.
  /\b\d[\d,]*(?:\.\d+)?\s*(?:fps|Hz|kHz|MHz|GHz)\b/i,
  /\b\d[\d,]*(?:\.\d+)?\s*(?:kilo|mega|giga|tera)?hertz\b/i,
  // Benchmark work rates. Keep the work unit explicit so operational facts
  // such as "1 API request per hour" are not mistaken for performance data.
  /\b\d[\d,]*(?:\.\d+)?\s*(?:(?:rendered|painted|processed)\s+)?(?:frames?|renders?|paints?|updates?|cells?|glyphs?|lines?|bytes?|bits?|keystrokes?)\s+per\s+(?:second|minute|hour|frame|millisecond|microsecond|nanosecond)\b/i,
  // Byte sizes and throughput, decimal or binary, abbreviated or spelled out.
  ...BYTE_SIZE_FIGURE_PATTERNS,
  ...BYTE_THROUGHPUT_FIGURE_PATTERNS,
  // Percentages framed as a performance delta.
  /\b\d+(?:\.\d+)?\s*(?:%|percent)\s*(?:\w+[\s-]+){0,3}(?:faster|slower|improvement|improved|reduction|reduced|speed-?up|overhead|gain|drop|regression|less|fewer|more)\b/i,
  /\b(?:faster|slower|improvement|reduction|speed-?up|overhead|gain|regression)\b[^.]{0,24}?\b\d+(?:\.\d+)?\s*(?:%|percent)/i,
  // "3x throughput", "2.5x faster", and bare multipliers such as "12x".
  /\b\d+(?:\.\d+)?\s*(?:x|×)\s*(?:faster|slower|throughput|speed|performance)\b/i,
  /\b\d+(?:\.\d+)?(?:x|×)\b(?!\d)/,
];

// Migration tables may state configuration-size facts such as the default
// scrollback limit. They still may not publish durations, rates, throughput,
// percentages, or multipliers as performance results.
const MIGRATION_PERFORMANCE_FIGURE_PATTERNS =
  PERFORMANCE_FIGURE_PATTERNS.filter(
    (pattern) => !BYTE_SIZE_FIGURE_PATTERNS.includes(pattern),
  );

// Terminals a comparison could name, plus the unnamed stand-ins for one.
const RIVAL_TERMINAL =
  "Windows\\s+Terminal|conhost|cmd\\.exe|Alacritty|WezTerm|kitty|mintty|" +
  "ConEmu|Cmder|Hyper|iTerm2?|PuTTY";
const RIVAL_REFERENT = `${RIVAL_TERMINAL}|(?:another|any\\s+other|every\\s+other|other|competing|rival|mainstream)\\s+terminals?|the\\s+competition`;

// Verbs that only ever assert a ranking, wherever they appear.
const RANKING_VERB =
  "outperform(?:s|ed|ing)?|outclass(?:es|ed|ing)?|outpac(?:e|es|ed|ing)|" +
  "outrun(?:s|ning)?|outstrip(?:s|ped|ping)?|outdo(?:es|ing)?|" +
  "outmatch(?:es|ed|ing)?|outgun(?:s|ned|ning)?|beats?\\b|" +
  "dominat(?:e|es|ed|ing)";
// Verbs and phrases that assert a ranking once a rival is in the same clause.
// "Noctty's throughput exceeds Alacritty's" carries no preposition at all.
const COMPARATIVE_VERB =
  `${RANKING_VERB}|exceed(?:s|ed|ing)?|surpass(?:es|ed|ing)?|` +
  "overtak(?:e|es|en|ing)|eclips(?:e|es|ed|ing)|edg(?:e|es|ed)\\s+out|" +
  "trail(?:s|ed|ing)?|(?:lag|fall|fell|falls)(?:s|ged|ging|ing)?\\s+behind|" +
  "(?:pull|pulls|pulled|come|comes|came)\\s+(?:out\\s+)?ahead|ahead\\s+of|" +
  "stack(?:s|ed)?\\s+up\\s+(?:well\\s+)?against|" +
  "fast(?:er|est)|slow(?:er|est)|quicker";

// The page positions the fork without ranking it against anybody. No
// cross-terminal speed claim of any kind is permitted, so the guard has to
// catch comparative performance language generally, not two known phrasings.
const CROSS_TERMINAL_CLAIM_PATTERNS = [
  /\bfast(?:er|est)\b/i,
  /\bslow(?:er|est)\b/i,
  /\b(?:quick|snapp|smooth|responsiv)(?:er|est)\b/i,
  /\bblazing(?:ly)?\b/i,
  new RegExp(`\\b(?:${RANKING_VERB})`, "i"),
  /\b(?:best[-\s]performing|most\s+performant|leading\s+terminal)\b/i,
  // "lower latency", "higher throughput", "less memory use than ...".
  /\b(?:lower|higher|less|fewer|more|better|worse|reduced|improved|greater)\s+(?:\w+[\s-]+){0,3}(?:latency|throughput|frame\s?times?|start-?up|overhead|performance|speed|fps|memory\s+use)\b/i,
  // The same claim with the quantity first: "throughput is higher", "start-up
  // comes in lower". A preposition is not required for a ranking to be stated.
  /\b(?:latency|throughput|frame\s?times?|start-?up|overhead|performance|speed|fps|memory\s+use)\b[^.!?;]{0,32}?\b(?:is|are|was|were|runs?|sits?|stays?|lands?|comes?\s+in)\s+(?:\w+[\s-]+){0,2}(?:lower|higher|less|fewer|more|better|worse|reduced|improved|greater)\b/i,
  // Multipliers of a performance quantity.
  /\b(?:twice|thrice|double|triple|\d+(?:\.\d+)?\s*(?:x|×|times))\s+(?:the\s+)?(?:\w+\s+){0,2}(?:throughput|speed|performance|latency|faster|slower|frame\s?rate|framerate)\b/i,
  // Any measurement stated relative to a named competitor.
  new RegExp(
    `\\b(?:than|versus|vs\\.?|compared\\s+(?:to|with)|against|relative\\s+to)\\s+(?:\\w+\\s+){0,2}(?:${RIVAL_TERMINAL})\\b`,
    "i",
  ),
  // A comparative verb and a rival in the same clause, in either order and
  // with no preposition between them.
  new RegExp(
    `\\b(?:${COMPARATIVE_VERB})\\b[^.!?;]{0,60}?\\b(?:${RIVAL_REFERENT})\\b`,
    "i",
  ),
  new RegExp(
    `\\b(?:${RIVAL_REFERENT})\\b[^.!?;]{0,60}?\\b(?:${COMPARATIVE_VERB})\\b`,
    "i",
  ),
];

function visibleHtmlText(html) {
  const text = html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
    .replace(
      /<\/?(?:address|article|aside|blockquote|br|dd|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|table|tbody|td|tfoot|th|thead|tr|ul)\b[^>]*>/gi,
      " ",
    )
    // Inline elements do not add rendered whitespace. Removing them without a
    // separator keeps split claims such as f<em>p</em>s visible to the guard.
    .replace(/<[^>]+>/g, "")
    .replace(/&#(x[\da-f]+|\d+);/gi, (_, value) => {
      const radix = value[0].toLowerCase() === "x" ? 16 : 10;
      const digits = radix === 16 ? value.slice(1) : value;
      const codePoint = Number.parseInt(digits, radix);
      return Number.isNaN(codePoint) ? " " : String.fromCodePoint(codePoint);
    })
    .replace(/&nbsp;/gi, " ")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, '"')
    .replace(/&apos;/gi, "'")
    .replace(/&micro;/gi, "µ")
    .replace(/&(?:ensp|emsp|thinsp|hairsp);/gi, " ");

  const unresolved = text.match(/&[a-z][a-z\d]+;/i);
  if (unresolved) {
    throw new Error(
      `claims scanner cannot decode named HTML entity ${unresolved[0]}; use literal UTF-8 or a numeric reference`,
    );
  }

  return text;
}

const trustText = visibleHtmlText(trustHtml);

function findClaimViolations(text, patterns) {
  return patterns
    .map((pattern) => text.match(pattern))
    .filter(Boolean)
    .map((match) => match[0].replace(/\s+/g, " ").trim());
}

function git(...args) {
  try {
    return execFileSync("git", args, {
      cwd: repoDir,
      encoding: "utf8",
      timeout: 20_000,
      maxBuffer: 64 * 1024 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null;
  }
}

// The integration branch, however this checkout happens to name it. A
// single-branch or shallow clone may have neither, in which case the
// main-side signals below are unavailable and say so.
const mainRefs = ["main", "origin/main", "refs/remotes/origin/main"].filter(
  (ref) => git("rev-parse", "--verify", "--quiet", `${ref}^{commit}`) !== null,
);

// "Similar name" is deliberately loose: same file name, or the same stem once
// case and separators are normalised away.
const nameKey = (path) =>
  basename(path)
    .toLowerCase()
    .replace(/\.[^.]*$/, "")
    .replace(/[^a-z0-9]/g, "");

function pathsNamedLike(candidates, relativePath) {
  const wanted = nameKey(relativePath);
  return candidates.filter(
    (candidate) => candidate !== relativePath && nameKey(candidate) === wanted,
  );
}

const trackedPaths = (git("ls-files", "-co", "--exclude-standard") ?? "")
  .split("\n")
  .filter(Boolean);

const mainTrees = mainRefs.map((ref) => ({
  ref,
  paths: (git("ls-tree", "-r", "--name-only", ref) ?? "")
    .split("\n")
    .filter(Boolean),
}));

// A skip that outlives its reason is a hole. Waiting for one exact path to
// reappear is not enough: if the dependency lands the document somewhere else,
// the exemption keeps skipping a genuinely broken link while the suite stays
// green. So the exemption retires on any of these, whichever arrives first:
// the file is here, a document with the same name is here under another path,
// the file or a same-named one is on main, or main carries the merge of the PR
// this entry waits on. What it cannot see: a checkout with no main ref (the
// main-side signals are then skipped, and the diagnostic says so), or a
// dependency that both renames the document past recognition and lands with a
// commit subject that omits its PR number.
test("no pending-document exemption outlives the dependency it waits on", (t) => {
  if (mainRefs.length === 0) {
    t.diagnostic(
      "no main ref in this checkout; only worktree signals are available",
    );
  }
  const stale = [];
  for (const [relativePath, pending] of PENDING_DOCS) {
    const reasons = [];
    if (existsSync(join(repoDir, relativePath))) {
      reasons.push("it is on this branch");
    }
    const renamedHere = pathsNamedLike(trackedPaths, relativePath);
    if (renamedHere.length > 0) {
      reasons.push(`this branch carries ${renamedHere.join(", ")}`);
    }
    for (const mainTree of mainTrees) {
      if (mainTree.paths.includes(relativePath)) {
        reasons.push(`${mainTree.ref} carries it`);
      }
      const renamedOnMain = pathsNamedLike(mainTree.paths, relativePath);
      if (renamedOnMain.length > 0) {
        reasons.push(`${mainTree.ref} carries ${renamedOnMain.join(", ")}`);
      }
      const merged = git(
        "log",
        "--max-count=1",
        "--format=%h %s",
        "--fixed-strings",
        `--grep=(${pending.pr})`,
        mainTree.ref,
      );
      if (merged && merged.trim()) {
        reasons.push(
          `PR ${pending.pr} is on ${mainTree.ref}: ${merged.trim()}`,
        );
      }
    }
    if (reasons.length > 0) {
      stale.push(`${relativePath} (${reasons.join("; ")})`);
    }
  }
  assert.deepEqual(
    stale,
    [],
    `the dependency landed, so these PENDING_DOCS entries must go and their links become checkable: ${stale.join(" | ")}`,
  );
});

// An exemption nobody cites is also an exemption that outlived its reason.
test("every pending-document exemption is still cited by something", () => {
  const cited = new Set(
    [
      ...trustHtml.matchAll(
        /https:\/\/github\.com\/amanthanvi\/noctty\/blob\/main\/([^"#]+)/g,
      ),
    ].map((match) => match[1]),
  );
  for (const relativePath of MIGRATION_GUIDES) {
    const markdown = readFileSync(join(repoDir, relativePath), "utf8");
    for (const match of markdown.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
      if (/^(?:https?:|#)/.test(match[1])) continue;
      cited.add(linkTargetPath(relativePath, match[1]));
    }
  }
  const uncited = [...PENDING_DOCS.keys()].filter((path) => !cited.has(path));
  assert.deepEqual(
    uncited,
    [],
    `nothing links to ${uncited.join(", ")} any more; drop the PENDING_DOCS entry`,
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

test("claims guards read rendered text without blocking operational rates", () => {
  assert.deepEqual(
    findClaimViolations(
      visibleHtmlText("Throughput: <strong>&#54;0</strong> frames per second"),
      PERFORMANCE_FIGURE_PATTERNS,
    ),
    ["60 frames per second"],
  );
  assert.deepEqual(
    findClaimViolations(
      visibleHtmlText("Throughput: 60&thinsp;fps"),
      PERFORMANCE_FIGURE_PATTERNS,
    ),
    ["60 fps"],
  );
  assert.deepEqual(
    findClaimViolations(
      visibleHtmlText("Throughput: 60 f<em>p</em>s"),
      PERFORMANCE_FIGURE_PATTERNS,
    ),
    ["60 fps"],
  );
  assert.notDeepEqual(
    findClaimViolations(
      visibleHtmlText("Noctty out<em>performs</em> Windows Terminal"),
      CROSS_TERMINAL_CLAIM_PATTERNS,
    ),
    [],
  );
  assert.throws(
    () => visibleHtmlText("Throughput: 60&NoSuchEntity;fps"),
    /cannot decode named HTML entity &NoSuchEntity;/,
  );
  assert.deepEqual(
    findClaimViolations(
      "The updater makes 1 API request per hour",
      PERFORMANCE_FIGURE_PATTERNS,
    ),
    [],
  );
  assert.deepEqual(
    findClaimViolations(
      "The default scrollback limit is 10 MB",
      MIGRATION_PERFORMANCE_FIGURE_PATTERNS,
    ),
    [],
  );
  assert.notDeepEqual(
    findClaimViolations(
      "Noctty renders at 500 MB/s",
      MIGRATION_PERFORMANCE_FIGURE_PATTERNS,
    ),
    [],
  );
  assert.notDeepEqual(
    findClaimViolations(
      "Noctty processes 2 gibibytes per second",
      MIGRATION_PERFORMANCE_FIGURE_PATTERNS,
    ),
    [],
  );
  assert.deepEqual(
    findClaimViolations(
      "Windows Terminal places this setting higher in settings.json",
      CROSS_TERMINAL_CLAIM_PATTERNS,
    ),
    [],
  );
  assert.notDeepEqual(
    findClaimViolations(
      "Windows Terminal has higher rendering throughput",
      CROSS_TERMINAL_CLAIM_PATTERNS,
    ),
    [],
  );
});

test("trust page carries every implemented release verification layer", () => {
  assert.match(trustHtml, /Get-FileHash/);
  assert.doesNotMatch(
    trustHtml,
    /gh attestation verify|every published asset carries\s+a GitHub\s+build-provenance attestation/i,
  );
  assert.match(
    trustHtml,
    /do not currently publish\s+build-provenance attestations/i,
  );
  assert.match(trustHtml, /Assert-ReleaseSignature/);
  assert.match(
    trustHtml,
    /\$PSVersionTable\.PSVersion\.Major -lt 7.*?PowerShell 7 \(pwsh\)/,
  );
  assert.match(
    trustHtml,
    /checkout --detach 5220df49e39c96182cf13150c53c4fd71fbc5b10/,
  );
  assert.match(trustHtml, /Expand-Archive/);
  assert.match(
    trustHtml,
    /noctty-release-verification-.*?\[Guid\]::NewGuid\(\)/s,
  );
  assert.match(
    trustHtml,
    /finally\s*{.*?\[IO\.Directory\]::Delete\(\$workRoot, \$true\)/s,
  );
  assert.match(trustHtml, /winghostty\\winghostty\.com/);
  assert.match(trustHtml, /winghostty\\winghostty\.exe/);
  assert.match(trustHtml, /winghostty\\ghostty-vt\.dll/);
  assert.match(
    trustHtml,
    /ReadByte\(\) -eq 0x4D.*?ReadByte\(\) -eq 0x5A.*?unexpected:.*?\$unexpectedPe/s,
  );
  assert.match(trustHtml, /-AllowedPins @\(\$expectedSpki\)/);
  assert.match(trustHtml, /-TrustSelfSigned \$true/);
  assert.match(trustHtml, /verify-published-release\.ps1/);
  assert.match(
    trustHtml,
    /\$version = "&lt;1\.3\.124-or-later&gt;".*?git clone --branch "v\$version" --depth 1.*?-Version \$version/s,
  );
  assert.match(
    publishedVerifier,
    /function Get-PortablePeRelativePaths.*?ReadByte\(\) -eq 0x4D.*?ReadByte\(\) -eq 0x5A/s,
  );
  assert.match(
    publishedVerifier,
    /\$unexpectedPortablePe.*?PE inventory mismatch.*?foreach \(\$relativePath in \$expectedPortablePePaths\)/s,
  );
  assert.match(
    trustHtml,
    /v1\.3\.123 uses the legacy\s+<code>winghostty-\*<\/code> asset layout/i,
  );
  assert.match(
    trustHtml,
    /verifier accepts v1\.3\.124 and later.*?first release that uses the current Noctty asset\s+contract/is,
  );
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
  const figures = findClaimViolations(trustText, PERFORMANCE_FIGURE_PATTERNS);
  assert.deepEqual(
    figures,
    [],
    `cite docs/windows-benchmark-methodology.md instead of: ${figures.join(", ")}`,
  );
});

test("trust page makes no cross-terminal performance claim", () => {
  const claims = findClaimViolations(trustText, CROSS_TERMINAL_CLAIM_PATTERNS);
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
      t.diagnostic(
        `${relativePath} lands with ${pending.label}; not checked yet`,
      );
      continue;
    }
    assert.ok(
      existsSync(join(repoDir, relativePath)),
      `missing ${relativePath}`,
    );
  }
});

for (const relativePath of MIGRATION_GUIDES) {
  test(`${relativePath} has no broken local Markdown links`, (t) => {
    const markdown = readFileSync(join(repoDir, relativePath), "utf8");
    assert.doesNotMatch(markdown, /\bprovenance\b/i);
    for (const match of markdown.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
      const target = match[1];
      if (/^(?:https?:|#)/.test(target)) continue;
      const resolved = linkTargetPath(relativePath, target);
      const pending = PENDING_DOCS.get(resolved);
      if (pending) {
        t.diagnostic(
          `${resolved} lands with ${pending.label}; not checked yet`,
        );
        continue;
      }
      assert.ok(existsSync(join(repoDir, resolved)), `missing ${target}`);
    }
  });
}

test("Windows Terminal opacity is converted from percent to fraction", () => {
  const markdown = readFileSync(
    join(repoDir, "docs/migrate-from-windows-terminal.md"),
    "utf8",
  );
  assert.match(markdown, /divide the Windows Terminal percentage by 100/i);
  assert.match(markdown, /50.*0\.5/);
});

for (const relativePath of MIGRATION_GUIDES) {
  test(`${relativePath} keeps the honest-gap section and no performance claims`, () => {
    const markdown = readFileSync(join(repoDir, relativePath), "utf8");
    assert.match(markdown, /## Honest gaps/);
    assert.match(markdown, /no screen reader has been\s+measured/i);
    const claims = findClaimViolations(markdown, [
      ...MIGRATION_PERFORMANCE_FIGURE_PATTERNS,
      ...CROSS_TERMINAL_CLAIM_PATTERNS,
    ]);
    assert.deepEqual(
      claims,
      [],
      `no performance result is published; remove: ${claims.join(", ")}`,
    );
  });
}
