# Scheduling Recommendations v1 Integration Contract

## 1. Status and normative language

This document defines the closed Phase 0 integration contract for ChronoFlow
scheduling recommendations. The wire contract is versioned as
`schema_version: "1.0"` and uses JSON Schema Draft 2020-12. The JSON Schemas in
`contracts/scheduling_recommendations/v1/` are authoritative for field shape and
type; this document is authoritative for ownership, lifecycle, persistence, and
cross-operation invariants.

The Specialist wire schemas, `model_tool.schema.json`, `tool_manifest.json`,
`operation_error_matrix.json`, `recommend_input_ownership.json`, and
`semantic_invariants.json` are separate machine-readable contract surfaces.
The wire schemas apply only to server-to-server Specialist traffic. The model
schema and manifest are authoritative for the smaller model-visible Tool
projection. A wire payload MUST NOT be reused as a model Tool argument or
result.

The words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, and **MAY** are
normative. Every instance object is closed with `additionalProperties: false`.
Fields that are not present in the applicable schema MUST be rejected rather
than ignored.

## 2. Boundary and operations

The public Specialist operations are exactly:

| Operation | Purpose | Calendar `Event` side effect |
| --- | --- | --- |
| `recommend_time_slots` | Rank feasible candidate slots | Forbidden |
| `revise_time_slot` | Revalidate an edited candidate slot | Forbidden |
| `confirm_schedule_candidate` | Explicitly confirm and commit one candidate | Required only for a `committed` response |
| `reject_schedule_recommendation` | Record `rejected_all` or `dismissed` feedback | Forbidden |

`record_scheduling_feedback` is an internal server action. It is not a public
Specialist operation or Tool and MUST NOT be exposed to a model or client.

Requests MUST NOT contain any of the following trust-boundary fields:
`user_id`, `workspace_id`, `authorization`, `api_key`, `home_address`,
`office_address`, `raw_profile`, `database_id`, `cookie`, `access_token`,
`refresh_token`, or `secret`.

**SR-ID-001 — Server-bound identity.** The authenticated ChronoFlow server MUST
bind the effective user and workspace before calling a Specialist operation.
The server MUST NOT derive either identity from request JSON. A recommendation,
candidate, revision, confirmation token, idempotency record, Event, and feedback
record MUST be read and written only within that same server-bound user/workspace
scope. A missing or cross-scope object is treated as not found or as an invalid
confirmation token; it MUST NOT reveal whether an object exists in another
scope.

`request_id` (`req_...`) and `trace_id` (`trc_...`) are correlation identifiers,
not authorization or identity credentials. The remaining public identifiers use
their schema-defined prefixes: `rec_`, `cand_`, `rev_`, `cnf_`, `idem_`, `evt_`,
`fb_`, and `sch_`. Identifiers are opaque and MUST NOT be parsed for identity or
business meaning.

## 3. Time and expiry

All date-time fields MUST be RFC 3339 date-times with an explicit UTC offset
(`Z` is an explicit offset). Offset-less local date-times are invalid. A server
MUST preserve the instant and MUST NOT infer an offset from the process timezone.

**SR-TIME-001 — Leap-second-free application profile.** ChronoFlow v1.0 uses a
restricted RFC 3339 application profile in which seconds MUST be `00` through
`59`. A `:60` representation is invalid on the wire even when it names a known
leap second. This rule applies to every Specialist, adapter, and model-projection
timestamp. Schema validation MUST fail closed before dispatch: an adapter MUST
NOT normalize `:60` into the next minute, and a server MUST NOT clamp it to `59`,
round it, or otherwise rewrite it to a different instant. An invalid request
MUST NOT create an Event, MUST NOT finalize feedback, and MUST NOT fall back to
an external API. Contract acceptance MUST NOT vary according to whether an
implementation or runtime can otherwise represent leap seconds.

`time_zone` MUST be an existing IANA timezone identifier. Its syntax has at
least two non-empty slash-separated components, no leading or trailing slash,
no empty component, and no ASCII space or control character. Satisfying the
string pattern alone is insufficient: the adapter MUST also resolve the value
through the locally installed TZInfo or Rails timezone registry before
dispatch. Timezone validation MUST NOT make an external request.

For a recommendation, `generated_at` MUST be earlier than `expires_at`. Each
candidate slot start MUST be earlier than its end and MUST agree with the
declared duration. Search-window start MUST be earlier than search-window end.

A feasible revision inherits the original recommendation's absolute
`expires_at`. Revision MUST NOT extend or refresh that deadline. At or after the
deadline, revise and confirm fail with `RECOMMENDATION_EXPIRED`; no Event or
positive feedback is created.

## 4. Persistence and transaction boundary

**SR-PERSIST-001 — Event creation boundary.** `recommend_time_slots`,
`revise_time_slot`, and `reject_schedule_recommendation` MUST NOT create, update,
or delete a calendar `Event`. Only `confirm_schedule_candidate` may create an
Event, and it MUST do so only after explicit confirmation, token verification,
snapshot revalidation, and feasibility revalidation have all succeeded. Only a
`committed` confirm response contains `event_id`; every other response MUST omit
it.

Recommendation metadata, candidate metadata, revision metadata, token state,
and idempotency state MAY be stored as non-Event server records so that later
operations can verify their binding. That storage does not authorize an Event
side effect.

**SR-PERSIST-002 — Atomic commit and feedback.** A committed confirmation MUST
atomically persist the new Event, its `feedback_event_id`, and the idempotency
result. If any part fails, the transaction MUST roll back and MUST NOT return a
`committed` response. `reject_schedule_recommendation` persists an append-only
feedback record and returns its `feedback_event_id`, but MUST NOT create an
Event. Recommend and revise MUST NOT report `event_id`. An infeasible revision
MUST return the closed `status: "error"` branch and MUST NOT report either an
Event creation or a partial candidate.

No operation in this contract authorizes Event update or deletion. Existing
Event persistence behavior is outside this Phase 0 contract.

## 5. Confirmation-token contract

**SR-CONFIRM-001 — Explicit confirmation.** The ChronoFlow server MUST issue a
fresh opaque confirmation token for every candidate returned by
`recommend_time_slots`. A feasible `revise_time_slot` response MUST issue a new
revision-specific token and MUST include `revision_id`,
`schedule_snapshot_version`, `expires_at`, `confirmation_token`,
`revised_candidate`, and `requires_confirmation: true`.

The server-side token record MUST bind all of the following:

- the authenticated user and workspace;
- `recommendation_id` and `candidate_id`;
- `revision_id` when confirming a revision;
- the applicable `schedule_snapshot_version`; and
- the original recommendation `expires_at`.

The raw token is required in a confirm request, but it is not authorization on
its own. Confirmation MUST fail unless every request identifier, the server
identity, the stored binding, the snapshot, and the token agree. A revised token
cannot confirm the unrevised candidate, and an original candidate token cannot
confirm a revision. Invalid, expired, consumed, cross-user, cross-workspace, or
cross-binding tokens MUST NOT create an Event.

The token MUST NOT be displayed in user-facing UI, sent to an LLM, included in
analytics, or emitted to production logs. It MUST be handled as a secret bearer
value at the application boundary. An idempotent replay of a previously
committed request may return the stored result without reusing the token to make
a second commit.

## 6. Schedule snapshot contract

**SR-SNAPSHOT-001 — Server-owned snapshot.** The ChronoFlow server, not the LLM
or Specialist, is the source of `schedule_snapshot_version`. It derives the
opaque `sch_...` version from the canonical schedule state visible to the
server-bound user/workspace. Any relevant committed schedule mutation MUST
advance that version according to the server's snapshot implementation.

Recommend evaluates against a server-supplied snapshot and returns that version.
A feasible revision revalidates against the then-current canonical schedule and
returns the version actually used. Confirm MUST compare the request/token-bound
version to the current canonical version and then revalidate the final slot
immediately before commit. A mismatch returns `STALE_SCHEDULE_SNAPSHOT` with no
Event or feedback side effect. A matching version does not waive conflict or
feasibility checks: a newly detected conflict returns `CONFLICT_DETECTED` or
`CANDIDATE_NOT_FEASIBLE` and does not commit.

The snapshot in a confirm request and its token binding is the pre-commit
version used for revalidation. Creating the Event is a canonical schedule
mutation and MUST advance the version atomically. Therefore a `committed`
response MUST return the new post-commit `schedule_snapshot_version`; it MUST
NOT echo the pre-commit version. The Event, feedback record, idempotency result,
and post-commit snapshot version become visible as one successful transaction.

Clients MUST replace stale recommendation state by requesting a new
recommendation; they MUST NOT rewrite a snapshot identifier or silently retry a
confirmation against a different snapshot.

## 7. Idempotency contract

**SR-IDEMPOTENCY-001 — Required key and binding.** Every
`confirm_schedule_candidate` request MUST contain an `idempotency_key` matching
the `idem_...` pattern. The server MUST bind the key to the authenticated
user/workspace, operation, recommendation, candidate, optional revision, and a
canonical hash of the closed request payload. The key is never a substitute for
a confirmation token.

**SR-IDEMPOTENCY-002 — Replay and conflict.** The first terminal processing
result for a key MUST be stored before it is returned. An exact replay in the
same server scope MUST return the stored response, including the same `event_id`
and `feedback_event_id` when committed, and MUST NOT create another Event or
feedback record. Concurrent requests with the same key MUST be serialized to
one winning execution. Reuse of a key with any different bound identifier or
semantic payload MUST return `IDEMPOTENCY_CONFLICT` /
`IDEMPOTENCY_KEY_CONFLICT` and MUST have no Event side effect. Idempotency state
MUST remain available for the complete supported retry window; an implementation
MUST NOT enable confirm until that window and its cleanup policy are configured.

A retry after a stale, expired, invalid-token, infeasible, or failed-terminal
result requires fresh recommendation/revision state and a new authenticated
user confirmation. Only the server may then create new evidence, a new logical
attempt, and its new idempotency key. Neither a client nor a model selects a new
key. The server MUST NOT mutate a stored idempotency result to convert a failed
attempt into a commit.

## 8. Operation-specific invariants

### 8.1 `recommend_time_slots`

The operation is read-only with respect to calendar Events. A successful
response includes one `recommendation_id`, `policy_version`,
`schedule_snapshot_version`, `generated_at`, `expires_at`, `constraint_policy`,
and the ranked `candidates`. Candidate rank and `candidate_id` are unique within
the response. Every candidate is feasible (`feasible: true`), has score in
`0..1`, and contains a confirmation token plus only allowlisted reason and
penalty codes.

### 8.2 `revise_time_slot`

The operation revalidates a proposed edit; it does not mutate the calendar. The
success and error shapes form a closed `oneOf`. A feasible response creates a
new `revision_id` and confirmation token but retains the recommendation's
deadline. An infeasible edit uses the error branch and MUST NOT leak a partial
candidate, confirmation token, or `event_id`.

`optional_change_reason`, when present, is restricted to:

- `PREFERRED_EARLIER_TIME`
- `PREFERRED_LATER_TIME`
- `AVOID_BACK_TO_BACK`
- `REDUCE_TRAVEL`
- `OTHER`

### 8.3 `confirm_schedule_candidate`

The operation has a closed committed-success branch and a closed error branch.
Only the committed branch contains the required `event_id`,
`feedback_event_id`, and `final_slot`. A committed response is proof that the
server completed the transaction described in `SR-PERSIST-002`; it is not merely
an acknowledgement that confirmation was requested.

### 8.4 `reject_schedule_recommendation`

The request action is exactly `rejected_all` or `dismissed`. A successful
response is `status: "recorded"`, echoes the action, and includes
`feedback_event_id`. It MUST NOT contain `event_id` or create an Event.

`optional_reason`, when present, is restricted to:

- `NO_SUITABLE_TIME`
- `TOO_EARLY`
- `TOO_LATE`
- `TOO_MUCH_TRAVEL`
- `SCHEDULE_TOO_FULL`
- `OTHER`

### 8.5 Machine-checked semantic invariants

**SR-SEMANTIC-001 — Closed semantic invariant registry.**
`semantic_invariants.json` defines exactly `SR-SEM-001` through `SR-SEM-017`.
The adapter and Specialist implementation MUST enforce them even when a payload
is structurally valid JSON Schema. In particular:

- search-window, expiry, and every slot start are strictly earlier than their
  corresponding end;
- every slot's elapsed minutes equal `duration_minutes`;
- candidate identifiers are unique and ranks are unique and contiguous from
  `1` through the candidate count;
- nested recommendation, candidate, and revision identifiers equal their
  envelope bindings;
- request and response correlation identifiers match;
- a revision preserves the original recommendation expiry;
- committed identifiers and final slot match the selected candidate or
  accepted revision;
- a committed response contains a post-commit snapshot different from the
  pre-commit confirm snapshot; and
- a reject response echoes the request recommendation and action.

Every invariant MUST have a negative mutation test. A valid happy-path fixture
alone does not demonstrate conformance, and a semantic failure MUST occur
before any Event or feedback side effect.

## 9. Constraint ownership

`travel_time_unknown` is not an LLM request field. ChronoFlow determines the
policy server-side and returns `constraint_policy.travel_time_unknown` as
exactly `strict` or `advisory` in recommend and revise results. Phase 0 MUST NOT
call a live routing or travel-time API. The production default remains
deliberately undecided and MUST be selected, documented, and tested before Phase
1 starts. Until that decision, no implementation may infer a default from an
LLM response.

## 10. Closed error contract

The error code, message code, and details shape are machine-readable contract
data, not free text. `message_code` MUST use the unique mapping below; clients
localize that code and MUST NOT display internal exception text.

```json
{
  "schema_version": "1.0",
  "error_message_codes": {
    "NO_FEASIBLE_SLOT": "NO_FEASIBLE_SLOT_AVAILABLE",
    "LOCATION_REQUIRED": "LOCATION_REQUIRED",
    "TRAVEL_TIME_UNAVAILABLE": "TRAVEL_TIME_UNAVAILABLE",
    "OPENING_HOURS_UNAVAILABLE": "OPENING_HOURS_UNAVAILABLE",
    "PROFILE_NOT_CONFIGURED": "PROFILE_NOT_CONFIGURED",
    "INVALID_TIME_WINDOW": "TIME_WINDOW_INVALID",
    "INVALID_DURATION": "DURATION_INVALID",
    "RECOMMENDATION_NOT_FOUND": "RECOMMENDATION_NOT_FOUND",
    "CANDIDATE_NOT_FOUND": "CANDIDATE_NOT_FOUND",
    "REVISION_NOT_FOUND": "REVISION_NOT_FOUND",
    "RECOMMENDATION_EXPIRED": "RECOMMENDATION_EXPIRED",
    "STALE_SCHEDULE_SNAPSHOT": "SCHEDULE_CHANGED_RETRY_REQUIRED",
    "CANDIDATE_NOT_FEASIBLE": "CANDIDATE_NOT_FEASIBLE",
    "CONFLICT_DETECTED": "SLOT_NO_LONGER_AVAILABLE",
    "CONFIRMATION_REQUIRED": "CONFIRMATION_REQUIRED",
    "INVALID_CONFIRMATION_TOKEN": "CONFIRMATION_TOKEN_INVALID",
    "IDEMPOTENCY_CONFLICT": "IDEMPOTENCY_KEY_CONFLICT",
    "SPECIALIST_TIMEOUT": "SPECIALIST_TIMEOUT",
    "CONTRACT_INVALID": "REQUEST_CONTRACT_INVALID",
    "OPERATION_NOT_ALLOWED": "OPERATION_NOT_ALLOWED"
  }
}
```

| Error code | Message code |
| --- | --- |
| NO_FEASIBLE_SLOT | NO_FEASIBLE_SLOT_AVAILABLE |
| LOCATION_REQUIRED | LOCATION_REQUIRED |
| TRAVEL_TIME_UNAVAILABLE | TRAVEL_TIME_UNAVAILABLE |
| OPENING_HOURS_UNAVAILABLE | OPENING_HOURS_UNAVAILABLE |
| PROFILE_NOT_CONFIGURED | PROFILE_NOT_CONFIGURED |
| INVALID_TIME_WINDOW | TIME_WINDOW_INVALID |
| INVALID_DURATION | DURATION_INVALID |
| RECOMMENDATION_NOT_FOUND | RECOMMENDATION_NOT_FOUND |
| CANDIDATE_NOT_FOUND | CANDIDATE_NOT_FOUND |
| REVISION_NOT_FOUND | REVISION_NOT_FOUND |
| RECOMMENDATION_EXPIRED | RECOMMENDATION_EXPIRED |
| STALE_SCHEDULE_SNAPSHOT | SCHEDULE_CHANGED_RETRY_REQUIRED |
| CANDIDATE_NOT_FEASIBLE | CANDIDATE_NOT_FEASIBLE |
| CONFLICT_DETECTED | SLOT_NO_LONGER_AVAILABLE |
| CONFIRMATION_REQUIRED | CONFIRMATION_REQUIRED |
| INVALID_CONFIRMATION_TOKEN | CONFIRMATION_TOKEN_INVALID |
| IDEMPOTENCY_CONFLICT | IDEMPOTENCY_KEY_CONFLICT |
| SPECIALIST_TIMEOUT | SPECIALIST_TIMEOUT |
| CONTRACT_INVALID | REQUEST_CONTRACT_INVALID |
| OPERATION_NOT_ALLOWED | OPERATION_NOT_ALLOWED |

**SR-ERROR-001 — Operation-specific error allowlist.**
`operation_error_matrix.json` is the exact allowlist. No operation may emit or
accept a code assigned only to another operation:

| Operation | Allowed error codes |
| --- | --- |
| `recommend_time_slots` | `NO_FEASIBLE_SLOT`, `LOCATION_REQUIRED`, `TRAVEL_TIME_UNAVAILABLE`, `OPENING_HOURS_UNAVAILABLE`, `PROFILE_NOT_CONFIGURED`, `INVALID_TIME_WINDOW`, `INVALID_DURATION`, `SPECIALIST_TIMEOUT`, `CONTRACT_INVALID`, `OPERATION_NOT_ALLOWED` |
| `revise_time_slot` | `RECOMMENDATION_NOT_FOUND`, `CANDIDATE_NOT_FOUND`, `RECOMMENDATION_EXPIRED`, `STALE_SCHEDULE_SNAPSHOT`, `CANDIDATE_NOT_FEASIBLE`, `CONFLICT_DETECTED`, `LOCATION_REQUIRED`, `TRAVEL_TIME_UNAVAILABLE`, `OPENING_HOURS_UNAVAILABLE`, `PROFILE_NOT_CONFIGURED`, `INVALID_TIME_WINDOW`, `INVALID_DURATION`, `SPECIALIST_TIMEOUT`, `CONTRACT_INVALID`, `OPERATION_NOT_ALLOWED` |
| `confirm_schedule_candidate` | `RECOMMENDATION_NOT_FOUND`, `CANDIDATE_NOT_FOUND`, `REVISION_NOT_FOUND`, `RECOMMENDATION_EXPIRED`, `STALE_SCHEDULE_SNAPSHOT`, `CANDIDATE_NOT_FEASIBLE`, `CONFLICT_DETECTED`, `CONFIRMATION_REQUIRED`, `INVALID_CONFIRMATION_TOKEN`, `IDEMPOTENCY_CONFLICT`, `SPECIALIST_TIMEOUT`, `CONTRACT_INVALID`, `OPERATION_NOT_ALLOWED` |
| `reject_schedule_recommendation` | `RECOMMENDATION_NOT_FOUND`, `RECOMMENDATION_EXPIRED`, `SPECIALIST_TIMEOUT`, `CONTRACT_INVALID`, `OPERATION_NOT_ALLOWED` |

All four Specialist operations have a closed success branch and a closed error
branch. Their branches are disjoint by `status`. An instance containing fields
from both branches is invalid; an adapter MUST NOT discard the extra fields to
make it valid.

**SR-ERROR-002 — Retryability and disclosure are fixed by code.** Only
`TRAVEL_TIME_UNAVAILABLE`, `OPENING_HOURS_UNAVAILABLE`, and
`SPECIALIST_TIMEOUT` have `retryable: true`; every other code has
`retryable: false`. The value is not provider-selected advice.

For every version `1.0` code, `details` is required and is the code-specific
closed object below. No details key is shared into a branch merely because
another error uses it:

| Error code | Exact required details | Optional details |
| --- | --- | --- |
| `NO_FEASIBLE_SLOT` | `candidate_count: 0` | None |
| `LOCATION_REQUIRED` | `required_reference: "location_preference_ref"` | None |
| `TRAVEL_TIME_UNAVAILABLE` | `unknown_leg_count` (integer, at least 1) | `retry_after_seconds` |
| `OPENING_HOURS_UNAVAILABLE` | `required_reference: "opening_hours"` | `retry_after_seconds` |
| `PROFILE_NOT_CONFIGURED` | non-empty unique `missing_profile_keys`, limited to `home_location`, `office_location`, `time_zone`, `working_hours`, `lunch_window`, `route_preferences` | None |
| `INVALID_TIME_WINDOW` | non-empty unique `invalid_field_names`, limited by operation to `search_window.start_at`, `search_window.end_at`, `time_zone`, `proposed_slot.start_at`, `proposed_slot.end_at` | None |
| `INVALID_DURATION` | non-empty unique `invalid_field_names`, limited by operation to `duration_minutes` or `proposed_slot.duration_minutes` | None |
| `RECOMMENDATION_NOT_FOUND` | `required_reference: "recommendation_id"` | None |
| `CANDIDATE_NOT_FOUND` | `required_reference: "candidate_id"` | None |
| `REVISION_NOT_FOUND` | `required_reference: "revision_id"` | None |
| `RECOMMENDATION_EXPIRED` | `expired_at` | None |
| `STALE_SCHEDULE_SNAPSHOT` | `expected_schedule_snapshot_version`, `current_schedule_snapshot_version` | None |
| `CANDIDATE_NOT_FEASIBLE` | `required_reference: "candidate_id"` | None |
| `CONFLICT_DETECTED` | `conflicting_event_count` (integer, at least 1) | None |
| `CONFIRMATION_REQUIRED` | `required_reference: "explicit_confirmation"` | None |
| `INVALID_CONFIRMATION_TOKEN` | `required_reference: "confirmation_token"` | None |
| `IDEMPOTENCY_CONFLICT` | `required_reference: "idempotency_key"` | None |
| `SPECIALIST_TIMEOUT` | `retry_after_seconds` (integer, at least 0) | None |
| `CONTRACT_INVALID` | non-empty unique `invalid_field_names` | None |
| `OPERATION_NOT_ALLOWED` | `required_reference: "operation"` | None |

Every listed details object has `additionalProperties: false`. A branch with no
optional key rejects all other keys. Details MUST NOT include raw Event titles,
another user's schedule, addresses, confirmation tokens, credentials, internal
exceptions, stack traces, database identifiers, or any field assigned to a
different error code. The model-visible error projection omits `details`
entirely by default.

## 11. Tool exposure

### 11.1 Four separate boundaries

**SR-TOOL-001 — Public Tool allowlist.** `tool_manifest.json` exposes exactly
`recommend_time_slots`, `revise_time_slot`, `confirm_schedule_candidate`, and
`reject_schedule_recommendation`. An unknown operation fails closed with
`OPERATION_NOT_ALLOWED`; it is never dynamically dispatched.

The four boundary surfaces are not interchangeable:

1. The **Specialist wire contract** is server-to-server only and is defined by
   the operation request and response schemas. It may carry a raw
   `confirmation_token`, schedule snapshot, idempotency key, Event identifier,
   or feedback identifier where the applicable wire schema permits it.
2. The **model-visible Tool boundary** is the smaller closed projection defined
   by `model_tool.schema.json` and `tool_manifest.json`. Only a manifest
   fragment may be used as a Tool arguments or result schema. A wire schema,
   raw wire payload, or validation diagnostic MUST NOT be exposed to the model.
3. The **server vault** is authenticated, tenant-scoped server state. It stores
   raw confirmation tokens, snapshot bindings, idempotency state, and the
   minimum response metadata needed for a later operation.
4. The **browser/UI boundary** carries only display data and opaque
   recommendation, candidate, and revision identifiers. A browser never
   receives or stores a raw confirmation token.

Every model-visible object is closed. Tool arguments are exactly:

| Operation | Model-visible arguments |
| --- | --- |
| `recommend_time_slots` | `title`, `duration_minutes`, `search_window` |
| `revise_time_slot` | `recommendation_id`, `candidate_id`, `proposed_slot`, optional `optional_change_reason` |
| `confirm_schedule_candidate` | `recommendation_id`, `candidate_id`, optional `revision_id` |
| `reject_schedule_recommendation` | `recommendation_id`, `action`, optional `optional_reason` |

The model-visible schemas MUST NOT declare, accept, or return
`confirmation_evidence`, `confirmation_evidence_id`, `confirmation_token`,
`logical_confirmation_attempt`, `logical_attempt_id`, `idempotency_state`,
`schedule_snapshot_version`, `idempotency_key`,
`user_id`, `workspace_id`, `authorization`, `cookie`, `access_token`,
`refresh_token`, `api_key`, `secret`, `feedback_event_id`, or `event_id` at any
nested depth.

### 11.2 Adapter validation, injection, vaulting, and projection

**SR-TOOL-003 — Ordered fail-closed adapter.** The Tool adapter MUST perform
these steps in this exact order:

1. validate the closed model-visible arguments;
2. bind the authenticated server identity;
3. resolve and inject server-owned wire fields using the operation-specific
   sequence below;
4. validate the complete Specialist request;
5. dispatch only the selected allowlisted Specialist operation;
6. validate the complete Specialist response;
7. persist the required secret and binding fields in the server vault;
8. construct the allowlisted model-visible projection;
9. validate that projection against its manifest result schema; and
10. return only the validated projection to the model.

A failure at any step stops the sequence. The adapter MUST NOT repair an
invalid Specialist payload by deleting unknown fields, MUST NOT fall back to a
raw response, and MUST NOT expose raw error `details` or validator diagnostics
to the model.

For `confirm_schedule_candidate`, step 3 is not a bulk injection shortcut. It
MUST execute the closed `tool_manifest.json` confirm sequence: exact evidence
lookup and binding validation; existing-attempt lookup and committed-result
replay when applicable; atomic attempt get-or-create for active evidence;
retrieval of that attempt's existing key; and only then token lookup and wire
construction. No token lookup or key allocation may occur merely because step
2 succeeded. The later response/storage/projection portion likewise follows
the manifest sequence and atomic-consumption rule.

The adapter injects these wire fields, never the model:

| Operation | Adapter-injected wire fields |
| --- | --- |
| `recommend_time_slots` | `schema_version`, `operation`, `request_id`, `trace_id`, `time_zone`, `schedule_snapshot_version` |
| `revise_time_slot` | `schema_version`, `operation`, `request_id`, `trace_id`, `schedule_snapshot_version` |
| `confirm_schedule_candidate` | `schema_version`, `operation`, `request_id`, `trace_id`, `schedule_snapshot_version`, `confirmation_token`, `idempotency_key` |
| `reject_schedule_recommendation` | `schema_version`, `operation`, `request_id`, `trace_id` |

After a valid recommend response, the vault binds every returned
`recommendation_id`, `candidate_id`, and candidate-specific
`confirmation_token` to the applicable `schedule_snapshot_version`,
`expires_at`, `policy_version`, authenticated user, and workspace. After a
valid revise response, it binds `recommendation_id`, `candidate_id`,
`revision_id`, the fresh revision-specific `confirmation_token`, snapshot,
expiry, user, and workspace. A value being model-visible, such as an opaque
candidate identifier, does not make it an authorization credential.

**SR-TOOL-004 — Token-free result projection.** Model-visible success results
contain only the manifest allowlist:

- recommend returns `status`, `recommendation_id`, `expires_at`, and candidate
  projections containing only `candidate_id`, `rank`, `slot`, `reason_codes`,
  `penalty_codes`, and `score`;
- revise returns `status`, the recommendation/candidate/revision identifiers,
  `expires_at`, a token-free revised candidate, and
  `requires_confirmation`;
- confirm returns `status`, the recommendation/candidate identifiers, optional
  revision identifier, and `final_slot`; and
- reject returns `status`, `recommendation_id`, and `action`.

All model-visible error results are the flattened closed object `status:
"error"`, `code`, `message_code`, and code-fixed `retryable`. Raw `details` is
not returned by default. The adapter MUST validate the operation-specific
model error branch, so a code prohibited for that operation cannot enter model
context.

### 11.3 Confirmation injection and no-token UI

**SR-VAULT-001 — Tenant-scoped secret retrieval.** The vault lookup key and
every stored binding include the authenticated user and workspace. A confirm
Tool call supplies only opaque recommendation/candidate and optional revision
identifiers. After the server verifies the explicit user-confirmation state,
the adapter uses those identifiers to retrieve the one matching unexpired,
unconsumed token and pre-commit snapshot, creates or retrieves the correctly
bound idempotency state, and injects the raw values into the Specialist wire
request. Missing, ambiguous, expired, consumed, or cross-tenant state fails
closed without revealing whether another tenant's record exists.

Token injection is not proof of explicit confirmation and does not perform or
replace a lifecycle transition. The state-machine guards, current snapshot,
expiry, and final feasibility checks remain mandatory. Token consumption and
the idempotency result are committed atomically with a successful Event; an
exact replay returns the stored result instead of consuming a token again.

**SR-UI-001 — No client-side token transport.** A raw confirmation token MUST
NOT appear in rendered HTML, a hidden input, a DOM attribute, JavaScript state,
a URL or URL fragment, browser local storage, browser session storage, a
service-worker cache, or any browser-readable cookie. The UI sends opaque
candidate identifiers through an authenticated request, and only the server
vault supplies the raw token. A token MUST NOT be copied into a prompt, model
argument, model result, validation error, analytics event, trace, or log.

### 11.4 Exact initial recommend input ownership

**SR-INPUT-001 — Ten units, each owned exactly once.**
`recommend_input_ownership.json` is the exact one-to-one registry:

| Initial input unit | Ownership | Version 1.0 delivery |
| --- | --- | --- |
| `task_title` | `MODEL_VISIBLE_USER_DERIVED` | model argument to wire `title` |
| `task_category` | `PHASE_1_DEFERRED` | absent; the closed category vocabulary is not frozen |
| `duration` | `MODEL_VISIBLE_USER_DERIVED` | model argument to wire `duration_minutes` |
| `location_preference_reference` | `SERVER_BOUND_PROFILE_CONTEXT` | authenticated server context; never model-supplied |
| `search_window` | `MODEL_VISIBLE_USER_DERIVED` | model argument to wire `search_window` |
| `timezone` | `SERVER_INJECTED` | wire `time_zone`; not model-visible |
| `minimum_buffer` | `SERVER_BOUND_PROFILE_CONTEXT` | authenticated server context; never model-supplied |
| `lunch_protection` | `SERVER_BOUND_PROFILE_CONTEXT` | authenticated server context; never model-supplied |
| `return_route_preference` | `SERVER_BOUND_RANKING_CONTEXT` | server ranking context; never model-supplied |
| `top_k` | `SERVER_POLICY` | default `3`, structural maximum `20`; never model-supplied |

An unmapped input, duplicate input unit, or unknown ownership value is a
contract failure. Server-bound context is passed out of band unless an existing
wire field is explicitly named above; an implementation MUST NOT invent an
undeclared wire property.

**SR-TOOL-002 — Internal feedback action.** `record_scheduling_feedback` MUST
remain an internal, authenticated server call after the relevant state change.
It MUST NOT be added to the public operation array, prompt, client API, or
model-callable function. A reject `action` visible at the Tool boundary relays
an authenticated explicit user action; the model MUST NOT infer, choose,
rewrite, or manufacture it.

### 11.5 Bound confirmation attempts and closed metadata

**SR-CONFIRM-002 — Candidate-bound confirmation evidence.** An explicit
confirmation is a server-created record derived from an authenticated user
action after the final slot was actually shown and the recommendation was
revalidated. It is bound to the authenticated user and workspace,
`recommendation_id`, `candidate_id`, an exact `revision_id` or its required
absence, a canonical fingerprint of `final_slot`, the pre-commit
`schedule_snapshot_version`, and the recommendation `expires_at`. Candidate
confirmation requires an absent revision; revision confirmation requires the
exact revision. Evidence for candidate A can never authorize candidate B, and
evidence for revision A can never authorize revision B. Tenant, final-slot,
snapshot, revision, or expiry pivoting is forbidden. Missing or mismatched
evidence returns `CONFIRMATION_REQUIRED` with no Event side effect.

A model Tool selection, model-generated confirmation sentence, generic session
flag, recommendation-only flag, token presence, or past presentation alone is
not evidence. Duplicate delivery of one authenticated user action MUST converge
on the same active evidence. Evidence is single-use and has exactly the states
`active`, `consumed`, `expired`, and `revoked`. Only an exact active record may
start a new confirm attempt. A successful commit consumes it in the same
transaction as the token, Event, feedback, snapshot, and stored idempotency
result. An exact consumed record may only locate and replay its already
committed result; it cannot allocate, dispatch, or create another Event.
Any terminal response assembled before that transaction is only a non-durable
staged value. The authoritative terminal result, Event, feedback record,
post-commit snapshot, evidence consumption, and token consumption MUST become
durable in one atomic commit; no terminal result may be visible between staging
and that commit.

**SR-CONFIRM-003 — Evidence must precede token lookup.** The confirm adapter
MUST validate model-visible arguments and authenticated tenant scope, then look
up and validate the exact evidence tuple before it allocates an idempotency
identity or reads a confirmation token. On missing, model-only, expired,
revoked, consumed-without-a-committed-result, or mismatched evidence, token
lookup count and idempotency allocation count remain zero. Evidence and attempt
identities are vault-only and MUST NOT appear in model/browser output.

**SR-IDEMPOTENCY-003 — One key per logical confirmation attempt.** The server
atomically derives exactly one logical attempt from exactly one confirmation
evidence record, and exactly one idempotency key from that attempt. Adapter,
response, model, and concurrent retries reuse the stored attempt and key. A new
key requires new authenticated confirmation evidence; terminal recommendation
states cannot create a new attempt.

**SR-IDEMPOTENCY-004 — Lost-response and concurrent retry handling.** A retry
first consults authoritative attempt state. `outcome_unknown` resumes with the
same key. A response lost after commit replays the stored committed result with
the same `event_id` and `feedback_event_id` and creates neither another Event
nor another feedback record. `committed` and `failed_terminal` have no outgoing
transition, and a terminal failure cannot later become committed.

**SR-IDEMPOTENCY-005 — Retry and retention window.** One logical attempt uses
its same key and stored result for the half-open interval beginning at
`allocated_at` and ending at 86400 seconds. The idempotency result retention
minimum is 86400 seconds and may be longer, never shorter. At and after the
retry-window boundary, the permanent consumed-evidence and committed-Event
uniqueness records still prohibit a second Event from the same evidence.

**SR-TIMEZONE-001 — IANA zone/offset alignment.** For each of
`search_window.start_at` and `search_window.end_at`, the adapter parses the RFC
3339 value as an instant, obtains the IANA `time_zone` period at that exact UTC
instant from the local TZInfo registry, and requires the supplied numeric
offset to equal `utc_total_offset`. It evaluates both endpoints independently,
including DST transitions, never rewrites an offset, and never infers a zone
from the process environment. A mismatch returns `INVALID_TIME_WINDOW` without
an Event side effect.

**SR-DATA-001 — Closed machine-readable contract data.**
`contract_data.schema.json` is the recursive closed-shape authority for the
seven contract-data documents. Every object rejects unknown keys; arrays have
fixed or bounded counts, closed vocabularies, and duplicate-identity checks;
unexpected nulls and broken references fail validation. Contract tests MUST
validate deep-copy mutations, not just repository originals.

**SR-ERROR-003 — Safe contract-invalid disclosure.** `CONTRACT_INVALID` may
name only the public field paths in `contract_invalid_field_matrix.json`.
Operation responses use their own subset; the standalone error Schema uses the
global union. Internal class, table, column, tenant identity, credential,
token, secret, vault, snapshot, and infrastructure names MUST be rejected and
MUST NOT be reflected from validator diagnostics.

**SR-STRING-001 — Absolute string boundaries.** ID, token, snapshot,
date-time, and timezone patterns match the entire JSON string under both the
subset validator and JSONSchemer. C0 controls, DEL, NEL, U+2028, and U+2029 are
invalid in leading, embedded, or trailing positions. Test code MUST evaluate
the raw Schema pattern and MUST NOT rewrite `$` into a stricter Ruby anchor.

**SR-SEMANTIC-002 — Required semantic context.** Every semantic invariant
declares `required_context_paths` and a deterministic `failure_path`. The
validator verifies presence and object shape before executing the relation;
missing, null, wrong-type, or malformed context fails at that path and is never
silently skipped. `SR-SEM-012` specifically requires request, response,
recommendation, and a valid recommendation expiry.

## 12. Feature flags and rollout

**SR-FLAG-001 — Fail-closed defaults.** Phase 0 defines the following flags in
documentation only. This contract does not modify environment variables. All
defaults are `off`:

```text
SCHEDULING_RECOMMENDATIONS_ENABLED=off
SCHEDULING_FEEDBACK_LOGGING_ENABLED=off
SCHEDULING_LEARNED_RANKING_ENABLED=off
SCHEDULING_ROUTE_CONSTRAINTS_ENABLED=off
```

`SCHEDULING_RECOMMENDATIONS_ENABLED=off` blocks all four public operations.
Feedback logging, learned ranking, and route constraints MUST NOT activate merely
because the top-level feature is enabled; each requires its own flag. Learned
ranking MUST NOT consume feedback while its flag is off. Route constraints MUST
NOT cause a live travel API call in Phase 0, even if configuration is
accidentally enabled. Operators MUST roll back by disabling the applicable flag,
not by weakening schema validation or confirmation requirements.
