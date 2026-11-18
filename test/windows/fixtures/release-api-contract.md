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
  Every build case rejects use of the tag endpoint; these include the corrected
  reviewer cases: stable/prerelease, retry, lost response, exhaustion and drift.
- The list and release records contain the fields the caller consumes. The
  selected record has an ID and tag, draft/prerelease flags and asset records;
  unrelated pagination records are projections. URLs, authors and notes are
  omitted because no predicate consumes them. The local candidate SHA replaces
  the historical SHA consistently in run, manifest and tag records.
- Mutations are recording operations with **no real gh fallback**. Creating a
  draft, uploading, and publishing update local state. Duplicate asset names
  fail; lost responses retain the successful upload. A `starter` asset without
  a digest fails closed with no publish. No asset is replaced or deleted.
  GitHub tag creation and latest-release selection are not simulated: local Git
  already supplies the candidate tag, and mutation flags/order are asserted.
  This proves script decisions, not a hosted API write.
- Drafts may have only one asset. Only drafts receive manual delete-and-rebuild
  advice. Complete published releases without a manifest have a legacy outcome;
  incomplete published releases require inspection and preservation.

## Actions evidence and attempts

- [Workflow attempts and jobs REST docs](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run-attempt)
  expose each attempt separately. Unqualified jobs default to the latest
  attempt. The reviewer measured this on run 43498380944, attempt 2.
- The fixture models each attempt's metadata and jobs separately, including an
  earlier successful publish followed by a failed rerun and cancellation before
  or after publication. Production must read every attempt. A successful
  prerelease build has skipped channel steps; failed/cancelled jobs have skipped
  suffixes. Wrong attempt SHA and no successful publish refuse resume.
- Recorded historical Test/job metadata is projected to the consumed fields.
  Downloaded interactive evidence is a small, locally generated hash-bound
  object; payload/evidence tamper and identity cases deliberately violate those
  records. Fixed future expiry timestamps and renewed run IDs are synthetic.
  Release artifact records are empty because no release artifact is consumed.

## Publishers and remaining boundaries

- Bootstrap reads accept only the two exact configured Scoop/WinGet paths and
  have an unavailable-path twin. Fixture B never pretends to publish a feed.
- The separate publisher fixture models REST HTTP status/JSON framing, bounded
  package/version and publishing-author searches, candidate file pagination,
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
