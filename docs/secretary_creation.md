# Secretary creation gateway (local implementation)

The new `/api/v1/secretary/creation_proposals` routes are separate from the existing read-only Specialist API. They support one explicitly timed personal event, with a 15-minute owner-bound draft and explicit confirmation. The normal chat conversation and its recommendations are never archived or changed by these routes.

`SECRETARY_CREATION_ENABLED` must equal `true` to enable the gateway. It is disabled by default. It reuses the existing configured trusted issuer, JWKS and shared replay store, with the separate `chrono-flow-secretary-actions` audience and `secretary:chrono_flow:propose`, `create`, `cancel`, `status` scopes. Tokens bind method, path and exact request bytes. Read tokens cannot be used here.

Apply the additive migration only as part of a separately approved release. Event insertion, copied owner participation and the execution receipt share one transaction. User-row and draft-row locks serialize this gateway; a unique actor/idempotency-key constraint backs up retry protection. Completed markers and receipts must not be deleted by a TTL cleanup. Cancellation only affects an unexecuted proposal.

The existing account deletion flow remains available: when the actor's account itself is deleted, its drafts and receipts cascade with that account. A newly created account cannot revive the deleted account's opaque proposal IDs. This is distinct from periodic receipt cleanup for a live actor, which is not implemented.

Immediately before confirmation the user's active identity and current overlapping events are checked again. A new overlap is refused; the confirmed time is never automatically moved. Ready candidates require explicit dates and either explicit start/end or start/duration, or an explicit all-day request. Multi-event, recurring, shared, reminder and edit/delete operations are not executed by this API.

The runtime wire schema and canonical digest implementation live under `contracts/secretary_creation/v1/` and `lib/secretary_creation/contract.rb`, shared with Home and ChronoTask.

Focused tests: `test/integration/secretary_creation_proposals_test.rb` and `test/services/secretary_creation_event_parser_test.rb`. Existing Specialist contract tests must also pass unchanged. Genuine concurrent independent transaction testing requires native PostgreSQL; PGlite's multiplexed backend cannot establish that guarantee.
