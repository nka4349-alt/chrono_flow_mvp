# Personal AI route integration

This change connects the personal/home AI consultation to Google Routes API
`directions/v2:computeRoutes`. It is separate from R1 Document foundation and
does not activate RAG retrieval, extraction, the frozen Scheduling Specialist
contract, or knowledge feature flags. No database migration is added.

## User behavior

- Supply a date, time, origin, destination and exactly one mode: public transit,
  driving or walking. Example input: `明日10時に東京駅から新宿駅まで徒歩で移動`.
- Public transit also accepts an arrival deadline or a fixed appointment:
  `東京駅から大阪駅まで電車で移動、明日15時から16時に会議、15分前に到着`.
  These examples describe accepted input, not verified provider coverage.
- Driving and walking require departure time. Google ignores arrival time for
  these modes, so ChronoFlow requests clarification instead of inventing a
  backward estimate. Mode, missing addresses and missing times are not guessed.
- Rail and bus requests verify every returned transit vehicle type as well as
  sending the provider's mode preference. Mixed or unknown types fail closed.
  A generic public-transit request may include both. Shinkansen-specific and
  mixed rail/bus requests need clarification in this version.
- Exact active saved-place aliases use only the signed-in user's address.
  Ordinary saved-route-minute suggestions and explicit durations retain their
  existing behavior. Multi-leg, return and intermediate-meal requests ask for
  clarification; they are not silently reduced to one leg.
- No route, missing key, provider failure, partial geocoding, malformed response
  or changed feasibility produces no route candidate. Failure never means zero
  minutes. API-derived cards show Google Maps attribution.

## Proposal and acceptance checks

Transit times come from the provider's actual transit departure/arrival and
walking segments. Transfer waits are counted once. Arrival buffer stays separate
from travel and appointment duration; applicable explicit and saved buffers use
their maximum, with exact directional/mode matching for saved routes. Route
proposals expire after 15 minutes.

Before persistence and before acceptance, the guard checks the complete union
of the user's created and participating events, including the waiting/buffer gap
before an appointment. It does not rely on the AI context's truncated event list.
Acceptance locks the user and reloads/locks the recommendation, then takes shared
locks on the complete canonical calendar rows in ID order. Existing event times
cannot be changed between the final conflict check and event creation. These row
locks are held through the bounded provider call and transaction; concurrent
calendar edits may briefly wait. Acceptance validates the saved-place binding
and approval digest, calls the provider again, and rechecks current time, buffer
settings and calendar rows before event creation. A route that no longer fits the approved
interval requires a new proposal; acceptance does not silently shift times.
Repeated acceptance of the same recommendation creates no duplicate events.
This uses row locks within route acceptance, not a global calendar lock.
The proposal covers the requested single leg and optional appointment. It does
not automatically route from a preceding event or onward to a succeeding event,
perform general time-slot ranking, or prove canonical identity from free text.

## Provider and data boundary

The server uses only `https://routes.googleapis.com/directions/v2:computeRoutes`.
It sends the two endpoints, mode and time, with a narrow response field mask.
There are no redirects, retries, user-controlled endpoints, raw provider-body
logs or browser API keys. Connect/read/write/overall timeouts, body-size and
response validation bounds apply. The provider rejects fallback routing and
partial address matches. Full geometry, stop details and raw HTTP responses are
not persisted. The internal recommendation stores the bounded request and
timing evidence needed to verify acceptance; it is not a reusable route cache.
Its `routing` envelope is removed from public chat and acceptance JSON. Saved
addresses are never included in tool telemetry. User-visible travel endpoints
use the labels the user supplied.

## Deployment handoff (manual, not executed by this change)

1. In the Google Cloud project, enable billing and Routes API. Configure a
   server key restricted to Routes API and the deployment's permitted server
   addresses where available. Do not use a browser/referrer-restricted key.
2. Set `GOOGLE_ROUTES_API_KEY` on the **ChronoFlow Rails Web service**
   (`srv-d6rvbmjuibrs73e1ekt0`), using Render's secret environment configuration.
   The Python AI private service does not make Routes requests. No key value is
   committed, printed or included in this document. Current production key
   configuration has not been verified.
3. Manually deploy the merged main commit when ready. This work stops at merge;
   commits and the PR carry `[skip render]` because the private AI service also
   watches this repository. Production environment variables and services are
   not changed by the implementation task.
4. Verify an actual walking/driving request and representative public-transit
   routes with a test user, then exercise acceptance and revalidation. Check
   attribution and that unavailable routes create no candidate. Live provider
   success, credentials, quota and **Japanese transit coverage remain unverified**
   by the mocked test suite. Google's coverage table explicitly omits transit;
   do not infer support from country coverage or from a successful parser test.
   If required transit routes are unavailable, a provider supporting those routes
   is needed before considering that use case operational.

The local suite uses injected HTTP responses and an isolated PostgreSQL test
database with external-network attempts blocked. It verifies request wiring,
parsing, failure behavior, proposal persistence and acceptance. It is not an
end-to-end live Google API test.

## Official references

- [Routes setup and credentials](https://developers.google.com/maps/documentation/routes/get-api-key)
- [Compute Routes request/response contract](https://developers.google.com/maps/documentation/routes/reference/rest/v2/TopLevel/computeRoutes)
- [Transit routing](https://developers.google.com/maps/documentation/routes/transit-route)
- [Coverage limitations](https://developers.google.com/maps/coverage)
- [Attribution and policies](https://developers.google.com/maps/documentation/routes/policies)
- [Render deploy skip marker](https://render.com/docs/deploys#skipping-an-auto-deploy)
