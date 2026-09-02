# Scheduling Recommendations v1 Feedback and Learning Contract

## 1. Closed action vocabulary

**SR-FEEDBACK-001 — Exact feedback actions.** Feedback action is server-derived
from an observed lifecycle transition. Clients and models MUST NOT provide an
arbitrary action. Contract version `1.0` recognizes exactly these actions:

```json
{
  "schema_version": "1.0",
  "contract": "scheduling_feedback_actions",
  "actions": [
    "accepted_as_is",
    "selected_alternative",
    "edited_and_accepted",
    "rejected_all",
    "dismissed",
    "cancelled_after_creation",
    "completed"
  ]
}
```

| Action | Evidence required | Learning interpretation |
| --- | --- | --- |
| `accepted_as_is` | An originally presented candidate was selected without revision and reached `committed`. | Positive evidence for the committed candidate only. |
| `selected_alternative` | A presented candidate other than the initially ranked candidate reached `committed` without revision. | Positive evidence for the chosen candidate; rank comparison is limited to candidates proved presented. |
| `edited_and_accepted` | A feasible revision received explicit confirmation and reached `committed`. | Positive evidence for the committed revision, not for the unedited slot. |
| `rejected_all` | User explicitly chose `rejected_all` after candidates were presented. | Recommendation-level negative evidence; not an automatic negative label for every candidate. |
| `dismissed` | User explicitly dismissed a presented recommendation. | Weak/neutral interaction evidence, not candidate rejection. |
| `cancelled_after_creation` | A previously committed Event was later cancelled through authoritative ChronoFlow Event lifecycle data. | Post-commit outcome signal; it does not retroactively rewrite the original acceptance record. |
| `completed` | Authoritative ChronoFlow Event lifecycle data shows the committed Event completed. | Post-commit outcome signal for that Event. |

## 2. Evidence gates

**SR-FEEDBACK-002 — No inference from non-actions.** Merely generating, fetching,
opening, or viewing the recommendation container MUST NOT produce learning
feedback. Candidate presentation is evidence only after the UI records actual
rendering; even verified presentation by itself MUST NOT emit a feedback action
or update learned ranking. An in-progress edit, an abandoned form, and an edit
cancellation MUST NOT create a final feedback action. An infeasible revision
MUST NOT be treated as a strong positive action.

The following acceptance actions are valid only after the Event transaction has
reached `committed`: `accepted_as_is`, `selected_alternative`, and
`edited_and_accepted`. They MUST NOT be emitted from `selected`, `edited`,
`revalidated`, or `confirmed` state. If commit rolls back, no acceptance action
is created.

**SR-FEEDBACK-003 — Presentation-aware labels.** An unshown candidate, meaning a
candidate that was not actually displayed to the user, MUST NOT be labeled as
rejected, ignored, or otherwise negative. `rejected_all` applies to the presented recommendation interaction;
it does not authorize per-candidate negatives for hidden, filtered, paginated,
or newly generated candidates. `selected_alternative` may compare ranking only
within the candidate set that the server can prove was presented in that same
recommendation.

## 3. Persistence and corrections

**SR-FEEDBACK-004 — Append-only tenant-scoped history.** Scheduling feedback is
append-only. A later outcome such as `cancelled_after_creation` or `completed`
creates a new record linked server-side to the committed Event; it MUST NOT
update, overwrite, relabel, or delete the original acceptance action. Duplicate
delivery is deduplicated by a server-owned event/idempotency identity without
coalescing records across users or workspaces.

Each feedback record is bound server-side to the authenticated user/workspace,
recommendation lineage, and, when applicable, candidate, revision, Event, policy
version, and schedule snapshot. Feedback MUST NOT be read, joined, trained, or
ranked across that boundary. A request never supplies `user_id` or
`workspace_id`, and an LLM never chooses that binding.

Append-only is an application audit/learning invariant; it does not override a
lawful account deletion or privacy-erasure workflow. Such a workflow operates
under platform data-governance controls rather than rewriting one feedback
action into another.

## 4. Learning precedence and rollout

**SR-FEEDBACK-005 — Explicit preferences win.** Explicit user profile settings
and explicit current-request constraints MUST take precedence over any inferred
or learned scheduling preference. Learning MUST NOT silently change a hard
constraint, confirmation requirement, travel-time policy, Event duration, or
timezone. Contradictory, sparse, stale, or low-confidence feedback MUST fall back
to the explicit profile and deterministic policy.

`record_scheduling_feedback` is an internal server action and MUST NOT be a
public Tool, model-callable function, or client operation. Its input is derived
from authoritative state transitions, not model prose.

**SR-FEEDBACK-006 — User action and required record boundary.** A model MUST NOT
select or infer a feedback action. The `action` in a model-visible reject Tool
argument is only a closed relay of an authenticated explicit user interaction;
the adapter MUST verify it against server-owned interaction state before
dispatch. Model prose, silence, navigation, or Tool invocation alone is not
evidence for `rejected_all`, `dismissed`, or an acceptance action.

Feature rollout is fail-closed:

- `SCHEDULING_FEEDBACK_LOGGING_ENABLED=off` disables optional feedback logging
  and downstream export by default.
- `SCHEDULING_LEARNED_RANKING_ENABLED=off` prevents feedback from changing rank
  by default, even when contract-required feedback records exist.
- Enabling learned ranking requires tenant isolation, presentation evidence,
  deduplication, explicit-preference precedence, monitoring, and rollback to be
  verified first.

The `feedback_event_id` required by committed-confirm and recorded-reject wire
responses identifies the authoritative append-only contract record. Optional
telemetry/export controlled by the logging flag is separate and MUST NOT be used
to fabricate that identifier. Setting
`SCHEDULING_FEEDBACK_LOGGING_ENABLED=off` disables optional observability and
export only; it does not waive the authoritative contract record required for a
`committed` confirm or `recorded` reject. An implementation MUST NOT return
either status without its required `feedback_event_id`, even while optional
logging is off. With the top-level scheduling feature off, no public scheduling
operation executes.
