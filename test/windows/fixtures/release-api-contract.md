# Release rehearsal API contract

Fixture B runs production scripts with local candidate Git history and v1.3.136's
real, digest-checked payload bytes. Its API records form a controlled model, not
a captured hosted publication. The following boundaries apply to every shim
response and mutation.

## Release discovery and publication

- [GitHub releases REST docs](https://docs.github.com/en/rest/releases/releases#get-a-release-by-tag-name)
  describe the tag endpoint as returning a **published** release. It returns 404
  for a draft. Listing releases includes drafts for a token with push access;
  reading `/releases/{id}` returns the selected draft too.
- [gh v2.100.0 FetchRelease and fetchDraftRelease](https://github.com/cli/cli/blob/v2.100.0/pkg/cmd/release/shared/fetch.go)
  implement separate published-tag and draft lookups. Our production lookup
  lists all pages, refuses duplicate pending tags and reads the selected ID.
  Fixture B models tag 404, ID success, pagination, duplicate drafts and absence.
  A listed ID returning HTTP 200 with `[]` gets up to three reads in total.
  A recovered object still blocks preflight create, and exhaustion refuses
  without creating or uploading anything.
  Every build case rejects use of the tag endpoint; these include the corrected
  reviewer cases: stable/prerelease, retry, lost response, exhaustion and drift.
- The list and release records contain the fields the caller consumes. The
  selected record has an ID and tag, draft/prerelease flags and asset records;
  unrelated pagination records are projections. Build cases record the
  submitted notes and generated notes in the returned body. The local
  candidate SHA replaces the historical SHA consistently in run, manifest and
  tag records.
- Mutations are recording operations with **no real gh fallback**. Creating a
  draft, uploading, and publishing update local state. Duplicate asset names
  fail; lost responses retain the successful upload. A `starter` asset without
  a digest fails closed with no publish. No asset is replaced or deleted.
  Remote tag refs include absent, lightweight and annotated success/mismatch
  cases. Publishing updates draft/prerelease state and models latest selection;
  lost edit responses and connection-read retries have positive and refusal twins.
  Local Git supplies candidate history; actual GitHub tag creation is not measured.
  This proves script decisions, not a hosted API write.
- Drafts may have only one asset. Only drafts receive manual delete-and-rebuild
  advice. Every published release without a manifest has a legacy outcome, including
  pre-rename payload names; manifest-bearing incomplete releases require preservation.
  Shared-tag drafts and tagless drafts receive guarded, ID-only manual advice.

## Actions evidence and attempts

- [Workflow attempts and jobs REST docs](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run-attempt)
  expose each attempt separately. Unqualified jobs default to the latest
  attempt. The reviewer measured this on run 43498380944, attempt 2.
- The fixture models each attempt's metadata and jobs separately, including an
  earlier successful publish followed by a failed rerun and cancellation before
  or after publication. Production must read every attempt. A successful
  prerelease build has skipped channel steps; failed/cancelled jobs have skipped
  suffixes. Publisher outcome markers distinguish completion from credential skips;
  missing old markers conservatively resume. Wrong attempt SHA and no successful publish refuse resume.
- Recorded historical Test/job metadata is projected to the consumed fields,
  the Test run's `event` (`workflow_dispatch`) included.
  The recorded run also lists an interactive job and artifact; promotion reads
  neither since 2026-11-22. Payload tamper and identity cases deliberately
  violate those records. Fixed future expiry timestamps and renewed run IDs are
  synthetic.
  Release artifact records are empty because no release artifact is consumed.

## Publishers and remaining boundaries

- Bootstrap reads accept only the two exact configured Scoop/WinGet paths and
  have an unavailable-path twin. Fixture B never pretends to publish a feed.
- The separate publisher fixture models REST HTTP status/JSON framing, bounded
  identifier-only open-PR title/body search, candidate file pagination,
  default-branch existence, transient 502 and exhausted 5xx retries. It rejects
  GraphQL and unbounded PR enumeration. A population of thousands of unrelated
  open PRs requires no extra reads. Sleep is recorded in this unit fixture;
  production pacing/backoff is measured separately by the live read-only probe.
- Final stable-copy and full public-verifier collaborators remain recording
  stand-ins. Their inputs, order and failure propagation are exercised, while
  signatures, provenance, ConPTY and PDB verification have separate real-asset
  verification evidence. The local Git negative ancestry return is a seam,
  not a second real non-ancestor history. These limits do not establish hosted
  build, signing, tag publication, feed acceptance or real-input behavior.

The WinGet search uses the package identifier alone over open PR title/body,
with no author/version filter and a complete-set bound of 100. Each discovered
PR is checked by manifest paths; the exact version directory is also checked
on the default branch. The 100-candidate positive control reaches 203 GETs;
over-bound, incomplete and failed-query twins refuse with named outcomes.
A miss is explicitly **absent within the stated limit**. A PR from any account
is outside the search if both title and body omit the identifier, including a
publisher-owned PR edited after wingetcreate opened it. No global changed-path
query is claimed.

Post-write controls model lost create/flip responses, a different writer's
matching draft, missing or late ID visibility, wrong draft identity, delayed
publication flags, tag 404 visibility, stale/missing latest, and true HTTP 503
framing with retry/exhaustion twins. The tag-ref preflight and prerelease latest
controls also refuse HTTP 200 with `[]` after three reads in total. Mutations are
issued once, then reconciliation uses reads only. Backoff is bounded to three
logical observations, with at most three transport attempts per observation.
Actual GitHub write propagation times remain unmeasured under this task's grant.

The cleanup controls exercise the system-temp fallback, an override, a literal
bracketed parent and failures during Fixture A's clone and Fixture B's asset
setup under outer WhatIf. Fixture B's default downloads stay in its owned
bulk tree. On failure that tree is removed, and the run directory retains the
available logs and JSON evidence. On success the whole run directory is
removed. An explicitly supplied asset cache remains caller-owned. The default
parent is `RUNNER_TEMP` on GitHub Actions and the system temp directory
locally. Pass `-WorkDirectory` or set `NOCTTY_RELEASE_FIXTURE_ROOT` to use
an existing scratch parent.
