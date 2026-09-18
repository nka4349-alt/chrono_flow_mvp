# Approved creation scope: fixed implementation wire contract v1

All new runtime features default disabled. Existing read APIs/contracts remain untouched.

Provider names: `chrono_flow`, `chrono_task` (not *_ai).
Base route on BOTH providers: `/api/v1/secretary/creation_proposals`.

## HTTP
- POST base: initial candidate or revise/clarify candidate.
- POST base/:proposal_id/confirm: create domain record.
- POST base/:proposal_id/cancel: cancel unexecuted candidate.
- GET base/:proposal_id: read candidate/receipt. No request body.
- Header Authorization Bearer RS256 JWT; typ at+jwt; known kid; configured trusted issuer/JWKS; TTL60 skew5 replay71; signed identity pair/public Home sub; Task signed workspace_id required, Flow workspace_id prohibited. No Cookie auth fallback. Creation replay retention covers future-iat skew + token lifetime + expiry skew + the inclusive boundary (5+60+5+1 seconds); the existing read profile is unchanged.
- Required headers Accept application/json, Content-Type application/json for POST, X-Request-Id and X-Trace-Id (UUIDs) exact body matches for POST. GET correlation from headers.
- New audience `chrono-flow-secretary-actions` / `chrono-task-secretary-actions`.
- Exact single scope `secretary:chrono_flow:propose|create|cancel|status` respectively (task equivalent).
- JWT additionally binds exact HTTP method, path and raw body hash with `creation_method`, `creation_path`, `creation_body_sha256` (SHA256 of empty bytes for GET). Verify before execution. Replay and domain idempotency are independent.
- Provider enable env `SECRETARY_CREATION_ENABLED=true` (exact string), otherwise 503 unavailable without parsing/issuing network calls. Use existing configured trusted issuer/JWKS/key config, separate expected audience/scope.
- Home enable env `ASSISTANT_CREATION_MODE=live`, and per provider `ASSISTANT_CHRONO_FLOW_CREATION_MODE=live` / TASK. Endpoints `CHRONO_FLOW_CREATION_ENDPOINT` / TASK: HTTPS URI exactly base route, no credentials/query/fragment. Use same signing settings as existing specialist JWKS. No redirect following or automatic new-key confirm retry.

## Request objects (additionalProperties false; every listed key required)
Propose:
version:"1.0", request_id:UUID, trace_id:UUID, message:nonblank UTF8 max4000,
locale:"ja-JP", time_zone:"Asia/Tokyo", proposal_id:UUID|null, expected_revision:positive integer|null.
Initial requires both nullable keys null; follow-up requires both nonnull. Store accumulated messages on provider, never parse domain language in Home.

Confirm:
version:"1.0", request_id:UUID, trace_id:UUID, proposal_id:UUID, revision:positive integer,
content_digest:lowercase SHA256, idempotency_key:UUID (Home SERVER chooses once per candidate; browser/model cannot provide key).

Cancel:
version:"1.0", request_id:UUID, trace_id:UUID, proposal_id:UUID, revision:positive integer.

## Uniform success response (every key present, additionalProperties false)
version:"1.0", request_id:UUID, trace_id:UUID, provider:"chrono_flow"|"chrono_task",
proposal_id:UUID, revision:positive integer, status:"needs_clarification"|"ready"|"rejected"|"completed"|"cancelled"|"expired",
expires_at:ISO8601 offset timestamp, content_digest:SHA256|null, question:string(max1000)|null,
details:typed Event|Task|null, result_id:UUID|null, completed_at:ISO8601 offset timestamp|null.
ready: details+digest required, question/result_id/completed_at null. needs_clarification: question required, details/digest/result/completed null.
completed: details+digest+result_id+completed_at required, question null. rejected: question explaining unsupported input, details/digest/result/completed null.
cancelled/expired: details+digest may remain from ready (or both null), result/completed null.
Receipt result_id is an opaque UUID, never raw provider DB ID.

Event details: kind:"event", title:nonblank max200, description:string max4000, location:string max500,
start_at:ISO8601 offset timestamp, end_at:ISO8601 offset timestamp, all_day:boolean, time_zone:"Asia/Tokyo".
end>start. All-day boundaries must be local midnight and preserve exclusive end semantics; otherwise ask clarification, do not guess.
Task details: kind:"task", title:nonblank max200, description:string max4000,
due_date:valid YYYY-MM-DD|null, due_time:HH:MM|null, time_zone:"Asia/Tokyo".
due_time requires due_date. Missing due_date means no deadline (display explicitly). Never convert date-only into arbitrary clock time.

Digest: lowercase SHA256 of UTF8 JSON.generate recursively lexicographically sorted hash keys for exactly:
{provider, proposal_id, revision, expires_at, details}. Arrays preserve order. No floats in typed details. All apps recompute using the same schema+canonical utility supplied by root.

## Error response (additionalProperties false)
version:"1.0", request_id:UUID|null, trace_id:UUID|null,
error:{code:enum, message:nonblank generic safe string, retryable:boolean}.
Codes/status: invalid_request400, unauthenticated401, forbidden403, not_found404,
proposal_changed409, already_completed409 (cancel/revise completed), idempotency_conflict409,
expired410, unsupported422, unavailable503, outcome_unknown503.
Never expose raw exceptions, identity/token/cookies or internal IDs.
Provider candidate create success HTTP201; followup/status/cancel/confirm200. Rejected/clarification can be normal success envelope with status. Error envelopes non2xx only.

## Domain invariants
Dedicated draft storage actor/public Home subject + verified identity snapshot + (Task) workspace binding. Expiry15min. Ready revision immutable; revision increments on edits. No domain record before confirm. Cancelled/expired/rejected/completed terminal, cannot re-open. Home uncertainty cannot create a fresh key and retry.
Confirm transaction: serialize per actor/workspace using DB lock, reload active identity/workspace membership, draft lock, check bindings/revision/digest and key. Domain record + opaque receipt + permanent executed marker committed atomically. Same key retry returns same receipt even after expiry; DIFFERENT key for executed proposal never creates again. Store receipts >=24h; never allow cleanup to resurrect executed proposals. Deleting the bound account/workspace may delete its private drafts and receipts through the existing account deletion flow; the deleted identity or absent workspace can no longer execute them. Idempotency key unique per actor/workspace; wrong content/key combination409. Candidate interpretation and external calls run outside row locks; reauthorize and compare the revision after interpretation.
Flow: final schedule conflict/snapshot recheck; changed conflicts require re-confirmation of new revision or clear refusal, never silently move time. Preserve standard event participant creation, own personal calendar only. Do not archive candidates belonging to normal Flow conversation.
Task: personal internal todo container within confirmed workspace; no sharing/assignment/multi-child creation. Current read context excludes undated/out-of-window items: receipt success remains authoritative.

## Scope decision
Initial implementation single create only + successful receipt and Home refresh. Assess completion/postpone/reminders but defer if separate target disambiguation, concurrency update contracts, or delivery infra increases risk (user explicitly permits this fallback).

Root owns shared strict schemas+canonical validator (portable Ruby no Rails dependency) under `lib/secretary_creation/contract.rb` and `contracts/secretary_creation/v1/`; tell root required missing nuance before changing wire.
