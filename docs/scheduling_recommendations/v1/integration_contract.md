# Scheduling Recommendations v1 Integration Contract

## 1. Status and normative language

This document defines the closed Phase 0 integration contract for ChronoFlow
scheduling recommendations. The wire contract is versioned as
`schema_version: "1.0"` and uses JSON Schema Draft 2020-12. The JSON Schemas in
`contracts/scheduling_recommendations/v1/` are authoritative for field shape and
type; this document is authoritative for ownership, lifecycle, persistence, and
cross-operation invariants.

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

A retry after a stale, expired, invalid-token, or infeasible response requires
the client to obtain the appropriate fresh recommendation/revision state and use
a new idempotency key. The server MUST NOT mutate a stored idempotency result to
convert a failed attempt into a commit.

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

`details`, when present, is a closed object. Its only possible keys are:
`conflicting_event_count`, `expected_schedule_snapshot_version`,
`current_schedule_snapshot_version`, `expired_at`, `retry_after_seconds`,
`candidate_count`, `unknown_leg_count`, `invalid_field_names`,
`missing_profile_keys`, and `required_reference`. The applicable JSON Schema
decides which values and combinations are valid. Unknown keys MUST be rejected.
Details MUST NOT include raw Event titles, another user's schedule, addresses,
confirmation tokens, credentials, internal exceptions, stack traces, or database
identifiers.

## 11. Tool exposure

**SR-TOOL-001 — Public Tool allowlist.** If these operations are exposed through
a Tool layer, the allowlist is exactly the four public operations in Section 2.
The Tool adapter MUST validate the closed request before dispatch, supply
server-bound identity and schedule state out of band, and validate the response
before returning it. An unknown operation fails with `OPERATION_NOT_ALLOWED`;
it is never dynamically dispatched.

**SR-TOOL-002 — Internal feedback action.** `record_scheduling_feedback` MUST
remain an internal, authenticated server call after the relevant state change.
It MUST NOT be added to a Tool manifest, prompt, client API, or model-callable
function. The model cannot choose, rewrite, or manufacture a feedback action.

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
