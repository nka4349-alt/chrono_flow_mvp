# Scheduling Recommendations v1 Privacy and Logging Contract

## 1. Data minimization and trust boundary

**SR-PRIVACY-001 — Minimum closed payload.** Scheduling request and response
payloads MUST contain only fields declared by the version `1.0` JSON Schemas.
User/workspace identity, authorization, credentials, database identifiers,
addresses, and raw profiles are server context and MUST NOT be accepted from the
wire payload. In particular, requests reject `user_id`, `workspace_id`,
`authorization`, `api_key`, `home_address`, `office_address`, `raw_profile`,
`database_id`, `cookie`, `access_token`, `refresh_token`, and `secret`.

The server MUST minimize data supplied to ranking logic and LLM providers. It
MUST NOT send confirmation tokens, credentials, full profiles, another user's
schedule, or raw home/office addresses. `travel_time_unknown` is decided by
ChronoFlow server policy and is not an LLM request field. Phase 0 makes no live
travel or routing API call.

## 2. Token and secret handling

**SR-PRIVACY-002 — Never expose confirmation tokens.** A confirmation token is
an opaque secret issued by ChronoFlow and returned for server-mediated confirm
flow. It MUST NOT be rendered in user-facing UI, copied to model context, placed
in analytics, used as a URL query value, included in exception text, or emitted
to production logs. Request/response inspection and error reporting MUST redact
the value before serialization. A raw token MUST NOT be recoverable from its log
representation.

The same no-log rule applies to authorization headers, cookies, API keys, access
tokens, refresh tokens, and application secrets. Redaction MUST be fail-closed:
if a structured logger cannot establish that a payload conforms to its safe
allowlist, it logs only correlation metadata and the validation outcome, not the
payload.

## 3. Production log allowlist

**SR-PRIVACY-003 — Metadata-only structured logging.** Production logs MAY
contain only the minimum structured operational metadata needed to diagnose the
contract:

- `schema_version`, operation, outcome/status, error `code`, and
  `message_code`;
- `request_id` and `trace_id` as opaque correlation identifiers;
- policy version and feature-flag state;
- aggregate candidate, conflict, and unknown-leg counts;
- coarse duration/latency and retry information; and
- a one-way, tenant-scoped diagnostic reference where existing platform policy
  explicitly permits it.

Production logs MUST NOT contain raw Event titles or descriptions, attendee
names, another user's Event data, exact free-form user text, addresses, raw
profiles, precise route endpoints, candidate payloads, final-slot payloads,
confirmation tokens, credentials, database IDs, internal exceptions, stack
traces returned to clients, or complete request/response bodies.

Error `details` is also a closed disclosure boundary. It may use only
`conflicting_event_count`, `expected_schedule_snapshot_version`,
`current_schedule_snapshot_version`, `expired_at`, `retry_after_seconds`,
`candidate_count`, `unknown_leg_count`, `invalid_field_names`,
`missing_profile_keys`, and `required_reference`, subject to the JSON Schema. It
MUST NOT reveal a conflicting Event's title, time details beyond the caller's
own submitted data, owner, address, token, or internal exception.

Metrics MUST use bounded labels. Raw identifiers, titles, timestamps, user text,
and addresses MUST NOT become metric names or labels. Traces follow the same
payload and token restrictions as logs.

## 4. Isolation, access, and lifecycle

**SR-PRIVACY-004 — Tenant isolation and governed retention.** Every
recommendation, candidate, revision, token, idempotency result, Event, and
feedback record is bound by the server to the authenticated user/workspace.
Authorization checks apply on every read and write. Cache keys, idempotency keys,
joins, analytics partitions, and learned-ranking inputs MUST include that
server-owned scope; identifiers supplied in JSON never establish access.

Recommendation and token state MUST become unusable at `expires_at`; cleanup may
occur later under server policy but MUST NOT restore usability. Idempotency
results remain available for the complete supported retry window to prevent
duplicate Event creation. Feedback is append-only for product semantics and is
retained, exported, anonymized, or erased only under documented platform data
governance. Access is least-privilege and auditable. Privacy deletion requests
override product-history retention without relabeling surviving feedback.

Backups, development logs, support tooling, and observability exports are not
exceptions to these restrictions. Production data MUST NOT be copied to local
fixtures or test logs. Test fixtures use synthetic fixed identifiers and contain
no real user or schedule data.

## 5. Feature flags and incident handling

The documented Phase 0 defaults are:

```text
SCHEDULING_RECOMMENDATIONS_ENABLED=off
SCHEDULING_FEEDBACK_LOGGING_ENABLED=off
SCHEDULING_LEARNED_RANKING_ENABLED=off
SCHEDULING_ROUTE_CONSTRAINTS_ENABLED=off
```

Flags are configuration controls, not permission to weaken validation, identity
binding, logging redaction, or explicit confirmation. On suspected leakage,
operators disable the relevant feature, revoke or invalidate affected token
state, preserve only sanitized audit metadata, and follow the existing security
and privacy incident process. Feature rollback MUST NOT delete or rewrite a
committed Event.
