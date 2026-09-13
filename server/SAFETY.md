# Safety Network operations

NOOP Safety Network is an opt-in contact paging service. Current production
origins are an app SOS and the configured repeated-tap Noop Band SOS gesture.
The server also reserves a fail-closed request model for a future, separately
validated live-motion fall workflow. Automatic fall transport is hard-disabled
because authenticated detector attestation is not implemented. It is not
emergency dispatch, clinical monitoring, or a substitute for calling local
emergency services.

## Incident flow

1. The owner must have two to five contacts who explicitly accepted an
   invitation.
2. An app SOS or repeated band SOS creates one durable incident. The reserved
   `validated_fall` request shape is always rejected in this release, including
   when its preparatory flag and detector allowlist are populated. A future
   implementation must authenticate detector evidence before evaluating its
   freshness, warning haptic, and unanswered response window.
3. Each incident queues a bounded number of independent paging rounds for every
   accepted contact. Each round has one SMS job and one deferred voice job.
4. SMS is eligible at the start of its round. Voice becomes eligible after the
   acknowledgement window. The default is four rounds, 15 minutes apart.
5. A recipient can choose **I'm responding** or **I cannot respond** from the
   signed SMS link. Voice calls accept `1` or `2` by DTMF.
6. The first responding contact acknowledges the incident and cancels every
   pending retry and future round. A cannot-respond decision stops future jobs
   only for that contact. The owner sees human responses individually and a
   deduplicated contact count backed by either a response or provider-confirmed
   delivery, plus each delivery state.
7. The owner selects an 8- or 12-hour incident window. Only the newest location
   fix is retained and exposed through the signed responder page; no route
   history is stored. Every terminal transition (`resolved`, `cancelled`,
   `expired`, or `failed`) deletes that precise fix in the same repository
   transaction. Incident and delivery history may remain without coordinates.
8. If every SMS and voice path explicitly fails for every contact, the incident
   becomes terminal `failed`. The client tells the owner that no contact
   delivery was confirmed and directs them to call local emergency services. An
   unconfirmed provider receipt remains `unknown`; it is not relabelled as
   delivered or failed.

Responder links use an expiring HMAC capability derived at send time. Plaintext
capabilities are never stored. Provider callbacks require both the configured
callback capability and a valid Twilio webhook signature.

Delivery is at least once. A worker crash after Twilio accepts a request but
before the database records the response can produce a duplicate retry. Contact
copy and UI must tolerate duplicate pages. Leases, bounded exponential retries,
provider receipts, and immutable attempt records prevent silent one-shot loss.

## Configuration

Paging is disabled unless every required variable is present:

```text
NOOP_PUBLIC_BASE_URL=https://noop.example.com
NOOP_TWILIO_ACCOUNT_SID=AC...
NOOP_TWILIO_AUTH_TOKEN=<account Auth Token for webhook verification>
NOOP_TWILIO_API_KEY_SID=SK...
NOOP_TWILIO_API_KEY_SECRET=<restricted outbound API key secret>
NOOP_TWILIO_FROM_PHONE=+14155550123
NOOP_TWILIO_STATUS_CALLBACK_SECRET=<at least 32 random bytes>
NOOP_SAFETY_CAPABILITY_SECRET=<different, at least 32 random bytes>
```

The `SK...` pair is optional but recommended for least-privilege outbound REST
calls. If it is absent, the account Auth Token is also used for outbound calls.
The account Auth Token remains required because Twilio signs callbacks with it.
Rotate any credential that was pasted into chat, a ticket, source control, or a
diagnostic report before use.

Generate the two application secrets independently:

```sh
openssl rand -hex 32
openssl rand -hex 32
```

The Twilio number must support both SMS and voice in every intended destination.
Complete carrier registration, geographic permissions, and trial-account
recipient verification before staging. `NOOP_PUBLIC_BASE_URL` must be the exact
public HTTPS origin Twilio reaches; redirects and alternate hostnames can break
webhook signature validation.

Policy controls and defaults:

| Variable | Default | Purpose |
| --- | ---: | --- |
| `NOOP_SAFETY_ACKNOWLEDGEMENT_TIMEOUT_SECONDS` | `90` | Delay before voice fallback |
| `NOOP_SAFETY_INCIDENT_TTL_SECONDS` | `43200` | Deployment ceiling for the selected 8- or 12-hour incident window; must allow 12 hours |
| `NOOP_SAFETY_ESCALATION_ROUNDS` | `4` | SMS-and-voice rounds per accepted contact; range 1 through 8 |
| `NOOP_SAFETY_ESCALATION_INTERVAL_SECONDS` | `900` | Delay between rounds; all rounds must finish inside eight hours |
| `NOOP_SAFETY_AUTOMATIC_PAGING_ENABLED` | `false` | Reserved gate for a future live-motion fall workflow; this release still refuses automatic transport |
| `NOOP_SAFETY_APPROVED_FALL_DETECTORS` | empty | Reserved `detector_id:version` metadata; not authentication or validation evidence |
| `NOOP_SAFETY_WORKER_POLL_SECONDS` | `2` | Idle queue poll interval |
| `NOOP_SAFETY_WORKER_HEARTBEAT_TIMEOUT_SECONDS` | `30` | Age after which the API blocks new pages |
| `NOOP_SAFETY_DELIVERY_LEASE_SECONDS` | `30` | Worker crash-recovery lease |
| `NOOP_SAFETY_RETRY_BASE_SECONDS` | `5` | Initial exponential retry delay |
| `NOOP_SAFETY_PROVIDER_REQUEST_TIMEOUT_SECONDS` | `15` | Provider HTTP request timeout |
| `NOOP_SAFETY_PROVIDER_RECEIPT_TIMEOUT_SECONDS` | `300` | Time before an unconfirmed provider submission becomes `unknown` |
| `NOOP_SAFETY_INCIDENT_RETENTION_DAYS` | `0` | Age for terminal incident deletion; `0` disables |
| `NOOP_SAFETY_CONTACT_RETENTION_DAYS` | `0` | Age after expiry, decline, or revocation for inactive contact deletion; `0` disables |
| `NOOP_SAFETY_RETENTION_INTERVAL_HOURS` | `24` | Scheduled retention interval |
| `NOOP_SAFETY_RETENTION_MAX_BATCHES_PER_RUN` | `20` | Maximum bounded cleanup batches per run |

Multiple worker replicas can process jobs concurrently because claims use
PostgreSQL row locks with `SKIP LOCKED`. Keep clocks synchronized and do not set
the lease shorter than provider request timeout plus the poll interval.

Production Compose runs a one-shot migration job, stateless API process, and
independent `safety-worker`. Scale API and worker processes separately. Worker
batch/concurrency controls are:

| Variable | Default | Purpose |
| --- | ---: | --- |
| `NOOP_SAFETY_WORKER_BATCH_SIZE` | `20` | Jobs leased per cycle |
| `NOOP_SAFETY_WORKER_MAX_CONCURRENCY` | `6` | Concurrent provider submissions per worker |

Each active submission holds a database-backed permit, so concurrency must stay
below the worker's database pool maximum. Provider sender throughput remains an
external limit even when more workers are added.

## Credential and data lifecycle

The app generates Safety credentials. The server stores only their SHA-256
digests. `PUT /v1/safety/me/token` performs retry-safe, version-checked rotation;
the prior token stops working immediately. `GET /v1/safety/me/export` returns
the profile, contacts, incident states, latest-only locations, and delivery
history without credential or invitation hashes. It accepts UTC-offset `start`
and `end` bounds and fails with HTTP `413` rather than truncating when the
configured aggregate export limit would be exceeded. `DELETE /v1/safety/me`
requires `X-Noop-Confirm: DELETE MY SAFETY PROFILE` and hard-deletes the
profile's Safety rows. Installation-wide erasure also removes its Safety and
Friends profiles.

Retention deletes only terminal incidents and pending-expired, declined, or
revoked contacts. It never ages an active incident or accepted contact. Precise
incident locations are deleted immediately on terminal transition, independent
of `NOOP_SAFETY_INCIDENT_RETENTION_DAYS`.
Retiring an incident leaves a short idempotency tombstone without contact,
location, or delivery data, preventing a delayed client retry from creating a
second page. Operators can run the same bounded policy with:

```sh
curl -fsS -X POST \
  -H "Authorization: Bearer $NOOP_API_TOKEN" \
  -H "X-Noop-Confirm: PURGE SAFETY" \
  https://noop.example.com/v1/admin/safety/retention/run
```

The standalone worker handles `SIGTERM` as a drain request: it finishes the
current bounded submission wave, records the provider outcomes, and then exits.
Compose grants 45 seconds by default through
`NOOP_SAFETY_WORKER_STOP_GRACE_PERIOD`; keep that duration longer than the
configured provider request timeout plus database completion headroom.

## Operator kill switch

`PUT /v1/safety/operations/paging-control` is authenticated by the administrator
token and persisted in PostgreSQL. Disabling requires a reason. It blocks new
invitations and pages, stops claims, and releases a row leased just before the
switch without consuming a retry. Callbacks and responder links remain active
so already-submitted work can settle.

Updates require the current `revision`, preventing a stale enable from undoing
a newer emergency disable. Every change is appended to
`safety_runtime_control_audit`. A disable waits for database-backed submission
permits to drain before returning. It cannot recall a request the provider
already accepted. Full commands and incident procedure are in
[`PRODUCTION_OPERATIONS.md`](PRODUCTION_OPERATIONS.md).

## Monitoring

An administrator can inspect privacy-safe counts:

```sh
curl -H "Authorization: Bearer $NOOP_API_TOKEN" \
  https://noop.example.com/v1/safety/operations
```

Alert on:

- zero active worker heartbeats while paging is enabled;
- `oldest_due_seconds` above the tested queue SLO;
- any `stale_leases`;
- sustained `retry_wait`, `failed`, or `unknown` counts;
- provider-delivery p95 above the country/carrier SLO;
- open incidents at or beyond expiry;
- missing Twilio status callbacks;
- worker exception logs.

The endpoint contains no names, phone numbers, health values, or responder
capabilities. Provider identifiers are not returned to consumer clients.

## Staging release gate

Run transport tests only against a number controlled by the tester:

```sh
export NOOP_RUN_TWILIO_STAGING=I_CONTROL_THIS_NUMBER
export NOOP_TWILIO_STAGING_TO=+14155550199
export NOOP_TWILIO_STAGING_RESPONSE_URL=https://noop-staging.example.com/healthz
python -m pytest tests/test_twilio_staging.py -q
```

Then exercise a complete incident from each shipping client:

1. accept two contact invitations on real phones;
2. open one incident and verify both SMS deliveries;
3. leave it unacknowledged and verify voice fallback;
4. press `2` for one contact and `1` for the other;
5. verify the owner sees both responses and the acknowledging contact;
6. repeat with a forced provider rejection, worker restart, and API restart;
7. leave a page unacknowledged and verify each configured follow-up round;
8. acknowledge during a later round and verify every remaining job is cancelled;
9. verify latest-only location for both 8- and 12-hour choices without route history;
10. resolve and cancel separate incidents and confirm no pending voice call starts;
11. verify callback, retry, and `unknown` alerts in operations telemetry.

Record carrier, country, Twilio message/call SIDs, timestamps, app builds, and
server revision as release evidence. The automated staging test proves Twilio
accepted real SMS and voice submissions; it does not prove carrier delivery,
human acknowledgement, or emergency suitability.

Automatic medical, rhythm, ECG, SpO2, temperature, stress, and other wellness
incidents are not accepted by the API. The API models bounded possible-fall
evidence for future compatibility, but its production route always rejects that
origin because authenticated detector attestation does not exist. Do not remove
that hard block until firmware authentication, staged-fall and hard-negative
studies, participant/device-held-out evidence, physical background and haptic
tests, carrier staging, human-factors review, legal review, and any required
regulatory work are complete. NOOP never contacts emergency services.
