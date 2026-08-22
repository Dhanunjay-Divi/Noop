# Safety Network operations

NOOP Safety Network is an opt-in, user-triggered contact paging service. It is
not emergency dispatch, fall detection, clinical monitoring, or a substitute
for calling local emergency services.

## Incident flow

1. The owner must have two to five contacts who explicitly accepted an
   invitation.
2. A manual page creates one durable incident and one SMS plus one deferred
   voice job per accepted contact.
3. SMS jobs are leased immediately. Voice jobs become eligible only after the
   acknowledgement window.
4. A recipient can choose **I'm responding** or **I cannot respond** from the
   signed SMS link. Voice calls accept `1` or `2` by DTMF.
5. The first responding contact acknowledges the incident and cancels pending
   retries and voice jobs. The owner sees who responded and each delivery state.
6. The owner marks the incident resolved or cancelled. An unacknowledged
   incident expires at its configured TTL.

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
NOOP_TWILIO_AUTH_TOKEN=...
NOOP_TWILIO_FROM_PHONE=+14155550123
NOOP_TWILIO_STATUS_CALLBACK_SECRET=<at least 32 random bytes>
NOOP_SAFETY_CAPABILITY_SECRET=<different, at least 32 random bytes>
```

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
| `NOOP_SAFETY_INCIDENT_TTL_SECONDS` | `1800` | Response-link and open-incident lifetime |
| `NOOP_SAFETY_WORKER_POLL_SECONDS` | `2` | Idle queue poll interval |
| `NOOP_SAFETY_DELIVERY_LEASE_SECONDS` | `30` | Worker crash-recovery lease |
| `NOOP_SAFETY_RETRY_BASE_SECONDS` | `5` | Initial exponential retry delay |
| `NOOP_SAFETY_PROVIDER_RECEIPT_TIMEOUT_SECONDS` | `300` | Time before an unconfirmed provider submission becomes `unknown` |

Multiple API replicas can process jobs concurrently because claims use
PostgreSQL row locks with `SKIP LOCKED`. Keep clocks synchronized and do not set
the lease shorter than the longest expected provider request.

## Monitoring

An administrator can inspect privacy-safe counts:

```sh
curl -H "Authorization: Bearer $NOOP_API_TOKEN" \
  https://noop.example.com/v1/safety/operations
```

Alert on:

- any `stale_leases`;
- sustained `retry_wait`, `failed`, or `unknown` counts;
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
7. resolve and cancel separate incidents and confirm no pending voice call starts;
8. verify callback, retry, and `unknown` alerts in operations telemetry.

Record carrier, country, Twilio message/call SIDs, timestamps, app builds, and
server revision as release evidence. The automated staging test proves Twilio
accepted real SMS and voice submissions; it does not prove carrier delivery,
human acknowledgement, or emergency suitability.

Automatic anomaly-triggered incidents remain disabled. Enabling them requires a
separate validated detector, cancellation window, participant/device-held-out
study, dispatch reliability evidence, safety review, and regulatory review.
