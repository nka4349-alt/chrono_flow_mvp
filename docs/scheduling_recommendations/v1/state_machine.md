# Scheduling Recommendations v1 State Machine

## 1. Normative machine

**SR-STATE-001 — Closed versioned state machine.** Scheduling recommendation
lifecycle state is owned by ChronoFlow server state, never by a caller-supplied
field. For contract version `1.0`, the state allowlist and transition allowlist
are exactly the JSON object below. A state or transition not listed is invalid.
Neither a Specialist wire payload nor a model-visible Tool argument/result may
set, request, or override lifecycle state. An otherwise valid payload containing
a state field is rejected as an unknown property.

```json
{
  "schema_version": "1.0",
  "machine": "scheduling_recommendation",
  "states": [
    "generated",
    "presented",
    "selected",
    "edited",
    "revalidated",
    "confirmed",
    "committed",
    "infeasible",
    "rejected",
    "dismissed",
    "stale",
    "expired"
  ],
  "transitions": [
    { "from": "generated", "to": "presented" },
    { "from": "presented", "to": "selected" },
    { "from": "presented", "to": "edited" },
    { "from": "presented", "to": "rejected" },
    { "from": "presented", "to": "dismissed" },
    { "from": "presented", "to": "stale" },
    { "from": "presented", "to": "expired" },
    { "from": "selected", "to": "revalidated" },
    { "from": "selected", "to": "expired" },
    { "from": "edited", "to": "revalidated" },
    { "from": "edited", "to": "expired" },
    { "from": "revalidated", "to": "confirmed" },
    { "from": "revalidated", "to": "infeasible" },
    { "from": "confirmed", "to": "committed" }
  ],
  "commit_entry_from": [
    "confirmed"
  ],
  "forbidden_transitions": [
    { "from": "generated", "to": "committed" },
    { "from": "presented", "to": "committed" },
    { "from": "selected", "to": "committed" },
    { "from": "edited", "to": "committed" },
    { "from": "revalidated", "to": "committed" },
    { "from": "infeasible", "to": "committed" },
    { "from": "expired", "to": "committed" },
    { "from": "stale", "to": "committed" }
  ]
}
```

## 2. State meaning

| State | Meaning | Permitted Event side effect |
| --- | --- | --- |
| `generated` | Server produced a recommendation against one schedule snapshot. | None |
| `presented` | At least one candidate was actually rendered to the user. | None |
| `selected` | User explicitly selected an unchanged candidate. | None |
| `edited` | User submitted an edited candidate for revision. | None |
| `revalidated` | Server loaded authoritative state and completed the binding, expiry, snapshot, feasibility, and constraint evaluation; its outcome gates the next transition. | None |
| `confirmed` | Exact active confirmation evidence, its bound token, and the logical-attempt idempotency checks succeeded; commit transaction may begin. | None until transaction commit |
| `committed` | Event and required feedback/idempotency records committed atomically. | Exactly one new Event |
| `infeasible` | Revalidation found that the selected or edited slot cannot be committed. | None |
| `rejected` | User explicitly rejected all presented candidates. | Feedback record only |
| `dismissed` | User dismissed the presented recommendation without rejecting each candidate. | Feedback record only |
| `stale` | The canonical schedule snapshot no longer matches the recommendation. | None |
| `expired` | The recommendation deadline was reached. | None |

`committed`, `infeasible`, `rejected`, `dismissed`, `stale`, and `expired` are
terminal in version `1.0`; the transition allowlist gives them no outgoing edge.
A fresh recommendation starts a new machine instance rather than reviving a
terminal one.

## 3. Transition guards and side effects

**SR-STATE-002 — Confirmation is the sole commit predecessor.** The only state
that may enter `committed` is `confirmed`. The transition from `confirmed` to
`committed` occurs only when the Event, append-only feedback record, and
idempotency result have committed in one transaction. A response MUST NOT claim
`committed` before that transaction completes. Transaction rollback leaves no
committed state or Event.

The server applies these guards:

1. `generated -> presented` occurs only after the UI actually renders at least
   one candidate. Generating or fetching data alone is not presentation.
2. `presented -> selected` requires an explicit user choice of a displayed,
   unchanged candidate.
3. `presented -> edited` requires an explicit user edit submitted through
   `revise_time_slot`.
4. `presented -> rejected` and `presented -> dismissed` require the exact user
   action recorded by `reject_schedule_recommendation`; neither creates an
   Event.
5. `presented -> stale` occurs when canonical schedule state invalidates the
   stored snapshot before selection. A mismatch discovered after the machine has
   left `presented` aborts the operation with `STALE_SCHEDULE_SNAPSHOT` and MUST
   NOT synthesize an unlisted transition or proceed to `confirmed`; the client
   must start a fresh recommendation machine.
6. Any listed transition to `expired` occurs when the original recommendation
   deadline is reached. A revision never moves that deadline.
7. `selected -> revalidated` and `edited -> revalidated` require the server to
   run identity-binding, snapshot, expiry, feasibility, and constraint checks;
   reaching `revalidated` does not itself declare the slot feasible.
8. `revalidated -> confirmed` requires a feasible evaluation and exact active
   server-owned confirmation evidence created from an authenticated
   user-originated action. The evidence MUST bind the authenticated user and
   workspace, recommendation, candidate, exact-or-absent revision, canonical
   final-slot fingerprint, pre-commit snapshot, and recommendation expiry. Only
   after that exact match may the server create or retrieve the one logical
   confirmation attempt, retrieve its existing idempotency key, and look up the
   bound confirmation token. All token and idempotency checks remain mandatory.
9. `revalidated -> infeasible` records an infeasible evaluation without creating
   a calendar Event or positive acceptance feedback.
10. `confirmed -> committed` is executed at most once for one confirmation
    evidence/logical-attempt/idempotency-key identity. The successful Event
    transaction atomically consumes the evidence and token and stores the Event,
    feedback record, advanced snapshot, and terminal idempotency result. Exact
    retries return that stored result without an additional transition, Event,
    feedback record, key, or token lookup.

The server MUST reject direct state assignment. In particular, these paths are
forbidden even if a caller supplies syntactically valid IDs or a token:
`generated -> committed`, `presented -> committed`, `selected -> committed`,
`edited -> committed`, `revalidated -> committed`, `infeasible -> committed`,
`expired -> committed`, and `stale -> committed`.

The machine records lifecycle semantics; it does not weaken the closed JSON
Schemas. A valid transition with an invalid request still fails contract
validation, and a schema-valid request with a disallowed transition still fails
the state guard.

**SR-STATE-003 — Adapter injection is not a transition.** Looking up a token,
injecting a pre-commit `schedule_snapshot_version`, or creating or retrieving a
logical attempt and its `idempotency_key` prepares a Specialist wire request;
none of those actions changes lifecycle state or proves user confirmation. The
server MUST establish exact authenticated confirmation evidence and execute
every listed guard before `revalidated -> confirmed`. A model Tool call, model
prose, an available token, prior candidate presentation alone, a generic session
flag, or a recommendation-level confirmation flag cannot create that evidence
and cannot cause `confirmed -> committed`.

Evidence validation precedes all secret and idempotency work. The server first
binds the authenticated tenant, then looks up evidence for the exact
recommendation/candidate/exact-or-absent-revision/final-slot/snapshot/expiry
tuple. A missing, inactive, or mismatched record fails with
`CONFIRMATION_REQUIRED`. Candidate A evidence MUST NOT confirm candidate B; an
unrevised-candidate record MUST NOT confirm a revision; revision A evidence MUST
NOT confirm revision B; and final-slot, tenant, snapshot, or expiry pivoting is
forbidden. On any such failure, token lookup, logical-attempt or idempotency-key
allocation, and Event or feedback side effects are all zero. Only an exact
active match permits atomic get-or-create of the logical attempt, retrieval of
its existing key, and then retrieval of the token.

The evidence itself is server-owned guard state, not a caller-supplied lifecycle
field. Repeated delivery of the same authenticated user action converges on the
same active evidence rather than creating multiple evidence records. A new
candidate, revision, or final slot requires a new authenticated confirmation
action and new evidence after revalidation. Creating a logical attempt is also
not a lifecycle transition and cannot substitute for any guard.

The snapshot injected into a confirm request is the pre-commit snapshot bound
to the selected candidate or accepted revision. A successful Event transaction
MUST atomically advance canonical schedule state, and the committed response
MUST contain the new post-commit snapshot. Equality between the injected
pre-commit snapshot and the committed response snapshot is a contract failure.
An error response never advances the snapshot and never synthesizes an
unlisted transition.

**SR-STATE-004 — Single use and terminal replay.** Only `active` evidence may
start or continue a new confirmation execution. A successful commit changes it
to `consumed` in the same transaction as the Event, feedback record, advanced
snapshot, terminal idempotency result, and token consumption. `consumed`,
`expired`, and `revoked` evidence cannot enter `confirmed`, allocate another
attempt or key, retrieve a token for a new dispatch, or create an Event.

Lost-response recovery is not a new confirmation execution or state transition.
Exact consumed evidence may identify only its already-existing committed
logical attempt so the server can return the stored response with the same
`event_id` and `feedback_event_id`. That replay performs no token lookup, no key
allocation, no Specialist redispatch, and no Event or feedback creation. If a
consumed evidence record has no matching stored committed result, the server
fails closed; it MUST NOT revive the evidence or infer that a commit may proceed.
Likewise, a committed or failed-terminal logical attempt cannot transition back
to an in-progress state.
