# Scheduling knowledge R1 document foundation

This supplement authorizes the local R1 document foundation following the owner's
instruction to proceed to implementation. It narrows acceptance to R1. It does not
declare the entire travel RAG v0.1 specification frozen or ready for production.
The machine-readable companion is
`contracts/scheduling_knowledge/r1_document_foundation.json`.

## Authority and scope

Existing Scheduling Recommendation v1.0, frozen HC-001–018 and OD-001/002 remain
authoritative. This supplement does not modify their wire schemas, travel context,
ranking, errors, feasibility rules, disclosure or confirmation behavior.

The reviewed originals remain unchanged:

| Input | SHA-256 |
| --- | --- |
| `chronoflow_travel_rag_handoff_2026-09-17.md` | `e288faff745047cbb804ff39f26ff3f78fd394694250112d2c033ce766824b0b` |
| `chronoflow_travel_rag_spec_v0.1.md` | `634300f687f76d8865aeebafd50e5d55638086a9535a180d9b392d8b22d9ba0d` |

The prior review is `cf-travel-rag-r0-freeze-20260919-073002`. Its six findings are
dispositioned below; its historical HOLD result is not rewritten.

R1 contains only documents, chunks, place links, registration, explicit versioning,
canonical text chunking and deletion/invalidation. The only accepted source types
are `official_facility_document` and `user_note`. `tenant_policy_document` remains
vocabulary for a later gate and is rejected by R1 registration.

R1 adds no retrieval, ranking, extraction, embeddings, pgvector, Routes calls,
Scheduling integration, public endpoint, AI Tool, Event write or production audit
retention. No feature is enabled or wired into the existing recommendation path.
The four existing proposed flags remain off by default; R1 needs no environment
or production configuration change. A migration artifact and isolated local tests
do not authorize applying a migration to the production database or deploying.

## Trusted access boundary

An internal `AccessScope` carries the authenticated tenant and user references. Its
caller must derive both from trusted server authentication; constructing this
value from model arguments or arbitrary request fields does not authenticate it.
R1 has no public caller or endpoint that binds those values.

Every read and mutation uses an explicit scope. Private documents require an exact
tenant and owner-user match. User notes are always private and may never be shared.
An official document is visible to other users of the same tenant only when its
visibility was explicitly registered as tenant-shared through trusted input.
There is no inferred sharing from a missing user reference or a place match.

Read visibility does not confer write authority. A tenant-shared document retains
its owner; another tenant member cannot version, revoke or delete it simply
because it is readable. R1 supports owner-scoped mutations. Any administrator
write capability requires a separate explicit contract rather than an implicit
bypass. Tenant scope is enforced before document/chunk/link data is returned.

One document version binds exactly one canonical `place_ref`. A place link must
match its parent document's tenant, owner and place. It cannot widen visibility.
Its `knowledge_requirement` is one of `none`, `optional`, or `required`; R1 stores
this policy and does not act on it in Scheduling. Inactive links are ineligible.
No fuzzy place matching, address lookup or automatic UserPlace/Event binding is
introduced.

R1 accepts only the closed scalar fields its registrar defines. It does not accept
arbitrary `source_reference_json` or unbounded caller metadata copied from the old
DB sketch. Temporal provenance is kept in dedicated `source_temporal_json` and
`source_timezone` fields; it does not provide a general metadata escape hatch.

## Canonical text and evidence coordinates

The registrar accepts valid UTF-8 text. Canonicalization converts CRLF and lone CR
to LF, and makes no other change: no trimming, Unicode normalization, whitespace
collapse, case folding, BOM removal or synthetic heading insertion. Invalid UTF-8
and NUL characters are rejected. Original upload parsing, OCR and PDF extraction are outside R1.

Each immutable document version persists its canonical text. The document hash is
SHA-256 of that text's exact UTF-8 bytes. The separate `source_sha256` stores the
exact input text's UTF-8 hash before line-ending normalization; it is not an upload
file hash and cannot substitute for the canonical content hash.

All character positions use zero-based Unicode code points in the entire
canonical document, with an exclusive end. They are not UTF-8 byte indexes,
UTF-16 code units, grapheme counts, page-local positions or chunk-local positions.
For every chunk:

```text
0 <= character_start < character_end <= canonical_text.codepoint_length
chunk.content == canonical_text[character_start...character_end]
chunk.content_sha256 == SHA256(chunk.content's UTF-8 bytes)
```

Later quote offsets must use the same document-global coordinate system, fall
inside the selected chunk, and reproduce the exact quote in both the document
and chunk. An adapter using a different coordinate system must convert and verify
it explicitly before acceptance.

U+000C form feed is retained in the canonical text and occupies one code point.
It separates pages: page numbers start at 1 and advance after each form feed.
Chunks do not cross a page boundary, and a form-feed separator need not itself
become a content chunk. Section paths and page numbers are metadata derived from
the original text; they are not copied into chunk content. Combining characters,
emoji and supplementary-plane characters remain unchanged and participate in
the same coordinate system.

## Chunk boundaries

The size target is 300–800 code points, the maximum is 1200, and the maximum
overlap is 80 within the same section and page. Short sections may produce shorter
chunks. Overlap contains complete semantic units; it is zero when safe overlap
would exceed 80. This R1 implementation always uses zero overlap. A target size does not override exact evidence or semantic
boundaries.

Preserve headings with their following content where present, numbers with their
units, condition with conclusion, and table header with its rows. A paragraph or
table that cannot be safely divided is an atomic unit. An atomic unit larger than
1200 is rejected with a bounded internal error; it is not silently truncated,
arbitrarily sliced or passed to an external service. This deliberately limits R1
to supported plain-text structure instead of claiming semantic understanding of
arbitrary formats.

Generated chunks remain contiguous source spans. A repeated table header must
not be manufactured to fit a new chunk. Sequence is deterministic. Duplicate
registration of the same document version, start, end and hash is prevented;
equal text occurring at different source positions keeps its separate identity
and provenance.

## Dates and temporal applicability

Persist normalized UTC instants and retain the supplied date/timestamp forms and
the trusted server IANA timezone used to interpret source dates. The source
provenance makes normalization inspectable. No timezone is inferred from a place
name, document text, model output, process locale or UTC fallback.

| Source input | Normalized meaning |
| --- | --- |
| Date-only `valid_from` | Inclusive start of that local calendar date |
| Date-only `valid_until` or `verified_until` | Inclusive source calendar date, represented by the exclusive start of the following local date |
| Timestamp `valid_from` | Inclusive exact instant |
| Timestamp `valid_until` or `verified_until` | Exclusive exact instant |
| Missing `valid_from` | No declared lower temporal restriction; no invented issuance date |
| Missing upper bounds | No declared upper temporal restriction; never proof of freshness or Hard eligibility |

Timestamp inputs require an explicit offset. Date conversion requires a valid
trusted IANA timezone and uses calendar-day advancement, never a fixed 86,400
seconds. An ambiguous or nonexistent local date boundary is rejected rather than
silently choosing an offset. Invalid dates, invalid timestamps and a nonpositive
effective interval are rejected.

Where both `valid_until` and `verified_until` exist, the effective upper bound is
the earlier instant. Verification cannot extend an explicit document expiry.
Where only one exists, it is the upper bound. A target instant is applicable only
when it is at or after the lower bound and strictly before the upper bound. For a
positive target interval, the entire interval must fit: start is at or after the
lower bound and end is at or before the exclusive upper bound. An interval ending
exactly at that bound does not include the expired instant.

These rules apply equally to registration, foundation applicability checks and
the later retrieval/evidence gates. They replace the v0.1 universal non-null
`valid_from <= target < valid_until` example with nullable, explicit bounds.

Temporal applicability is **not Hard eligibility** and is not a complete
retrieval predicate. In particular:

- An official document without either upper bound can be stored. R1 computes a
  freshness deadline from the later available `issued_at` or `verified_at`, plus
  90 elapsed days (90 × 86,400 seconds). A missing anchor or an anchor later than
  the evaluation time is ineligible. The evaluation time must be strictly before
  the deadline and the entire target interval must end at or before it, in
  addition to any declared lower bound. This computed eligibility deadline does
  not overwrite persisted expiry provenance and permits only a later Soft path;
  it does not establish Hard eligibility.
- `verified_until` can bound an otherwise undated official document, but all
  future evidence, source, applicability, coverage and conflict checks remain
  mandatory before any Hard use.
- A user note may remain stored until changed or deleted. R1 exposes whether
  reconfirmation is due after 180 elapsed days (180 × 86,400 seconds) from the
  immutable document version's `created_at`. This indicates version age while
  there is no extraction confirmation implementation. It does not automatically
  expire or delete the note, alter foundation eligibility, or renew from unrelated
  `updated_at` changes. Actual confirmation and its application remain a later
  extraction/application gate.
- R1 records no confirmation that makes an entire note Hard-ready. Later user
  confirmation must bind to the exact extracted constraint and document version;
  confirmation of an earlier version cannot transfer silently to a new version.

For example, source expiry `2026-12-31` in `Asia/Tokyo` becomes
`2026-12-31T15:00:00Z` (local `2027-01-01T00:00:00+09:00`). Local noon on December
31 is inside the interval; local midnight starting January 1 is outside it.

## Immutable versions and invalidation

Lifecycle values are closed: `draft`, `active`, `superseded`, `revoked`, `expired`.
Deletion is orthogonal through `deleted_at`, not a sixth lifecycle value. Only an
active, undeleted parent with a matching active link can make its children
foundation-eligible; expired time bounds still exclude an otherwise active row.

Content, source identity, scope, place and provenance cannot be changed in place
after registration. An explicit new version registers new content/chunks and
supersedes the old version atomically under the same tenant/owner/place binding.
Historical versions remain distinguishable. A failure must not leave the old
version superseded without a complete replacement. To preserve a unique active
version, the transaction may mark the old version superseded before inserting the
replacement. That intermediate state is not committed or externally visible;
failure rolls back the old document, chunks and link state together.

Revocation, explicit expiration, supersession and deletion make the parent and
its derived chunks ineligible immediately and deactivate links as appropriate.
R1 deletion is owner-scoped soft deletion: it sets the orthogonal deletion state
and invalidates the parent, chunks and links transactionally. Deleted content is
not eligible for downstream use. It does not claim physical erasure of stored
rows or text. Physical erasure, retained-history access and retention periods
require an explicit production/privacy gate before activation; no production
audit retention is enabled in R1. This implements RAG-OD-013's invalidation
requirement without adding an unapproved erasure policy. The foundation does not
create embeddings, extracted constraints, retrieval caches or evidence records.
Their later implementations must join the same invalidation boundary before
activation.

R1 logs and errors must not include raw text, raw notes, chunks, credentials,
unbounded request data or another scope's identifiers. Bounded internal reason
codes are not additions to the public P0 error allowlist.

## Disposition of the six review findings

| Finding | R1 disposition | Remaining gate |
| --- | --- | --- |
| F-001: null validity contradicts common filter | Resolved for foundation by nullable source bounds, an explicit undated-official freshness predicate and separation from Hard eligibility | R2 must preserve the same predicate before retrieval; R3 verifies evidence eligibility |
| F-002: date, timezone and verification precedence | Resolved for foundation by explicit normalization, retained provenance, exclusive instants and earlier-bound rule | Boundary fixtures must pass before R1 acceptance |
| F-003: top-20/top-5 cannot prove no conflict | Deferred; R1 creates no Hard consumer and makes no conflict-free claim | Hard requires a separate complete applicable-authority coverage/conflict proof; partial coverage fails closed |
| F-004: extraction schema/type/phase not closed | Deferred by explicitly narrowing this approval to the R1 foundation schema | Before R3, freeze full closed extraction schema, allowed type/phase combinations, aliases, unit derivations, range representation and evidence rejection rules |
| F-005: hash and offset basis unspecified | Resolved for foundation by persisted canonical UTF-8 text and document-global code-point spans | Exact traceability fixtures must pass before R1 acceptance |
| F-006: next-place reception omitted from outbound mapping | Deferred; R1 persists source identity and introduces no route or phase mapping | Before integration, next-place ingress and pre-task reception must each apply once with independent evidence and deduplication |

For F-003, relevance limits stay 20 retrieved and 5 reranked. Absence of a
conflicting constraint in that sample is never proof of absence. Before Hard
activation, a separately designed proof must cover every applicable authoritative
document/version and relevant clause. Missing, partial or stale proof means a
required-knowledge candidate is excluded; optional knowledge is unused and only
the independently safe base path may continue. R1 does not implement that proof
or expand retrieval limits.

For F-006, the later outbound next-destination component must include N's
independent ingress and reception requirements. Preserve document-local phase
identity and count each verified evidence/constraint identity once, even when it
is projected into a leg-specific component. Ingress and reception must not be
collapsed into a single untraceable value or counted twice. Existing HC travel,
effective-buffer, unknown-data and duration rules still govern.

## Acceptance evidence and later gates

R1 verification must cover scope denial before content disclosure, private user
notes, explicit official sharing, owner-only mutation, matching place links,
immutable versioning, atomic supersession, terminal lifecycle states and scoped
soft deletion/invalidation. It must also cover source date versus timestamp expiry,
null bounds, verification that cannot extend expiry, interval boundaries, invalid
timezone/date handling, Japanese text, CRLF, combining characters, supplementary
Unicode, page breaks, overlap, oversized atoms and exact hashes/spans.

Document foundation tests must demonstrate no Event mutation, external API call,
embedding or LLM call, and no connection to production databases. Existing public
Scheduling contracts must remain unchanged. Test results belong in implementation
evidence; this specification is not a claim that those tests have already passed.

R2 retrieval, R3 extraction, R4 shadow integration/audit, R5 presentation, R6 Hard
activation and R7 model-visible response changes remain separate gates. Audit
retention needs an owner decision before R4. Public/model-visible additions need
a versioned closed-schema compatibility review. Full v0.1 freeze remains
**NOT COMPLETE** while those deferred contracts remain unresolved.
