# Secretary mutation runtime contract — `draft-0.1`

This directory is the canonical byte source for the local M1A mutation contract. It is derived from ADR-0006 and `docs/proposals/secretary_mutation/v1/` without changing those Proposed documents.

It defines the six allowlisted operations:

- ChronoFlow: `event.update`, `event.delete`
- ChronoTask: `task.update`, `task.delete`, `task.complete`, `task.postpone`

All request, response, snapshot, effect-plan, receipt, and error objects are closed. Runtime validation and canonical SHA-256 are implemented by `SecretaryMutation::Contract` in `lib/secretary_mutation/contract.rb`. The wire version remains `draft-0.1`.

Text safety is field-specific. Raw user messages and descriptions preserve LF-delimited multiline text, while rejecting NUL, TAB, CR, every other C0 character, DEL, and C1 controls. Event/task titles, event locations, candidate/target display titles, and provider-generated question/error text reject every C0 character, DEL, and C1 controls. Validation never strips, normalizes, case-folds, or replaces accepted text. A provider must therefore show the accepted canonical value before confirmation, bind that exact value into the digest, revalidate it immediately before save, and write that same value exactly. Invalid text must cause zero domain writes; legacy malformed records must be excluded or safely represented without crashing a complete provider response.

The `examples/` directory is a byte-identical runtime copy of the reviewed proposal examples. In particular, `mutation-digest-vectors.json` and its six digest-input files are executable cross-repository vectors; consumers must recompute their hashes.

Provider mirrors are never hand-edited. From the Home repository root, synchronize and then verify them with:

```sh
bin/secretary_mutation_contract_mirror sync /absolute/path/to/chrono_flow_mvp /absolute/path/to/chrono_task_mvp
bin/secretary_mutation_contract_mirror check /absolute/path/to/chrono_flow_mvp /absolute/path/to/chrono_task_mvp
```

The synchronizer mirrors this complete package plus `lib/secretary_mutation/contract.rb`. It refuses to delete unexpected destination package files. `check` requires the complete relative file set and every package/runtime byte to match the Home canonical sources.

Production enablement remains blocked and all feature flags remain default-off:

```text
FLOW_NATIVE_WRITER_SHARED_LOCK=NOT_IMPLEMENTED_PRODUCTION_BLOCKER
TASK_NATIVE_WRITER_SHARED_LOCK=REVIEW_REQUIRED_PRODUCTION_BLOCKER
CLEANUP_SCHEDULER=NOT_CONFIGURED_PRODUCTION_BLOCKER
```

These review gates do not claim production readiness and must be resolved before production enablement or canary use.
