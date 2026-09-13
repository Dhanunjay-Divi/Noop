# App feedback reporting

NOOP app feedback is an explicit support workflow. It is not passive crash
reporting, health sync, emergency monitoring, or a NOOP+ feature gate.

## User flow

1. The user shakes an iPhone or Android phone, or opens the app-report entry
   provided by the platform.
2. NOOP explains the bounded evidence it can collect. Nothing is uploaded.
3. The user may add a short note and may separately opt into the pre-report
   screen snapshot. The snapshot is off by default and may show health values.
4. NOOP builds the redacted report and shows the exact attachment list plus a
   bounded text preview.
5. The user taps **Send feedback**. This freezes the reviewed attachment set
   into an immutable local ZIP and creates a durable outbox item.
6. The sheet shows queued, uploading, retrying, sent, or failed state. The user
   can close the sheet while an already consented transfer continues through
   the operating system's background mechanism.
7. NOOP marks the report sent only after the server verifies the stored object
   and returns a receipt.

The app never creates or uploads a report because of a crash, app launch,
background wake, or shake alone. A fresh **Send feedback** action is required.

## Local queue and screenshot limits

Apple and Android use the same bounded local policy:

- at most three active reports and two retained terminal summaries;
- at most 20 MiB per immutable ZIP and 64 MiB across active archives;
- active local records transition to cancellation after 14 days and terminal
  records are removed after 24 hours;
- upload and remote-cancellation paths each have an independent eight-attempt
  budget;
- a successfully sent or cancelled report records whether its local ZIP was
  actually removed, so cleanup failure remains visible and retryable.

Transient state-file reads or metadata lookups preserve the report and defer
work. Structurally invalid records are rejected; temporary I/O failure is not
treated as corruption. A clock rollback cannot move a report backwards because
persisted update times remain monotonic.

The optional screenshot is captured only while the review sheet is presented.
It is capped at 8 MiB and re-encoded or sampled to bounded dimensions before
review. Android additionally caps capture output to a 1,440-pixel edge and
approximately two million pixels. Both clients remove nonessential
metadata-bearing PNG chunks, and the server independently decodes and validates
the final PNG.

## Report contents

Allowed:

- bounded current and previous app-session lifecycle/performance events;
- bounded platform-authored crash, hang, or ANR evidence when available;
- app/OS/build information and aggregate storage-size information;
- fixed band connection/history-sync outcome categories;
- an optional user note, capped and reviewed;
- an optional PNG screen snapshot, explicitly selected and listed.

Rejected:

- the health database or database sidecars;
- sensor rows, raw band frames, raw captures, biometric values, and exact
  health timestamps;
- credentials, cookies, API keys, signed URLs, account/contact identifiers, or
  arbitrary dynamic paths;
- unknown, duplicate, encrypted, nested, malformed, or oversized ZIP entries;
- an attachment whose presence differs from the reviewed consent flags.

Free-form notes and screenshots can still contain private information chosen by
the user. The UI warns about this and keeps both optional.

## Transfer contract

The app uses a dedicated `noop-feedback` Firebase app. It obtains App Check
attestation and an auto-cleaned anonymous Firebase identity without creating or
changing a NOOP+ account. It reserves one report with:

```text
POST /v1/feedback/reports/reservations
X-Firebase-AppCheck: <attestation>
Authorization: Bearer <anonymous identity token>
Idempotency-Key: <one report UUID>
```

The request contains only schema version, platform, app version, archive size
and SHA-256, and note/screenshot inclusion flags. The server returns:

- an opaque report ID;
- a report-scoped capability for status, completion, and deletion;
- a short-lived signed `PUT` capability for one immutable object key;
- the retention deadline.

The client uploads the ZIP from an app-private file. It then calls:

```text
POST /v1/feedback/reports/{report_id}/complete
X-Firebase-AppCheck: <attestation>
Authorization: Bearer <anonymous identity token>
X-NOOP-Feedback-Token: <report capability>
```

The server verifies object generation, size, content type, digest metadata,
actual SHA-256, ZIP limits, file allowlist, UTF-8 text, PNG signature,
app-report metadata, and consent flags. Only then does it return `sent` and a
short support receipt.

`GET` recovers state after process or network interruption. `DELETE` removes
the object and marks the report deleted. A deleted capability cannot reserve a
replacement under the same idempotency key.

The server stores a versioned SHA-256 identity digest derived from Firebase
issuer, tenant, and subject. It never stores the raw Firebase subject. A legacy
local report that already has remote state but cannot prove identity continuity
fails closed before making a network request. Report capabilities are opaque
43-character URL-safe tokens, optionally prefixed with a bounded key version
such as `v2.`; both clients reject every other token shape.

Reservations are idempotent and subject to all of these default ceilings:

- six reports per tenant-aware anonymous principal per UTC day;
- 64 MiB of pending compressed data per principal;
- 500 reports app-wide per UTC day;
- 1 GiB of pending compressed data app-wide;
- 20 MiB per compressed archive;
- two concurrent validators with a ten-second queue/execution timeout.

Archive admission reserves validation capacity before downloading or parsing
the object. This prevents rejected work from bypassing the concurrency ceiling.

## Storage and operator access

- Archives use a feedback-only private Cloud Storage bucket with public access
  prevention, uniform access, CMEK encryption, no object listing permission for
  the app service, and an independent lifecycle rule.
- PostgreSQL stores bounded operational metadata only: platform/version,
  digest/size, consent flags, state, object generation, and lifecycle times.
- The default retention window is 28 days and is deployment-configurable from
  1 through 28 days, below Identity Platform's anonymous-account cleanup edge.
- Object cleanup uses a deletion pass followed by a delayed absence-confirmation
  pass. Metadata is not finalized as deleted from one ambiguous object-store
  response.
- There is no public report-download endpoint. Approved operators use audited,
  least-privilege database and object IAM to retrieve a known receipt.
- Operational logs contain fixed outcomes, platform, size bucket, attachment
  count, file count, and request correlation. They do not contain report IDs,
  capabilities, object keys, URLs, user text, screenshots, health values, or
  payload bodies.

An authorized support operator starts from the `NF-...` receipt shown by the
app and performs an exact metadata lookup:

```sql
SELECT receipt, status, platform, app_version, created_at, retained_until,
       object_key, object_generation
FROM feedback_reports
WHERE receipt = $1;
```

The operator then reads only that exact generation from the feedback bucket
through approved IAM. Bucket listing is not granted to the API, and support
must not move the ZIP into tickets, chat, or general-purpose drives. Analysis
notes should reference the receipt and fixed failure category, not copy user
text or health values into operational logs.

## Deployment and rotation gates

Feedback is default-off. Enabling the route does not admit new reports until
`NOOP_FEEDBACK_ACCEPTING_RESERVATIONS=true` and the separate external abuse
gate is approved. Operators can turn reservation admission off while retaining
status, completion, cancellation, and cleanup for already accepted reports.
The lifecycle worker is a separately controlled job so cleanup can continue
while the API is drained.

Capability rotation is staged. Deploy dual-read support first, retain the prior
key for the complete 28-day retention horizon, then move new writes from the
legacy format to a named version. Removing a verification key while a report
may still exist is a release failure.

Public traffic remains blocked until physical App Check validation, edge
throttling, abuse monitoring, operator access controls, alert ownership,
incident response, and staged key-rotation evidence all pass.

## Failure behavior

| Boundary | App behavior | Server evidence |
| --- | --- | --- |
| Report build fails | Remains local; user can retry | No request |
| Reservation offline/unavailable | Durable queued state; bounded retry | Request status family and fixed auth/outcome |
| Signed upload interrupted | Progress stops, then retry is scheduled | Reservation exists; no completed object |
| Upload completes but acknowledgement is lost | `GET`/idempotent completion recovers state | Verified object and state transition |
| Object metadata or archive is invalid | Terminal rejected state; object deletion attempted | Fixed rejected outcome only |
| App is closed after Send | OS-supported worker/session continues best effort | Same report capability and idempotency key |
| User cancels | Worker stops and `DELETE` is attempted | Fixed deletion outcome |
| Retention expires | Object and metadata state are deleted in bounded batches | Claimed/deleted/failed counts |
| State file is temporarily unreadable | Preserve item and retry without contacting the server | Local fixed `state_unavailable` outcome |
| Legacy remote item has unverifiable identity | Fail closed before any status/delete call | Local fixed identity-continuity failure |
| Reservation admission is drained | Existing reports recover/complete/delete; new reports remain queued | Fixed reservation-disabled outcome |

## Evidence boundary

Unit, integration, simulator, and emulator tests can prove report assembly,
state transitions, retries, API authorization, archive validation, storage
metadata, and retention. They do not prove background continuation after
force-quit, locked-device transfer, cellular switching, OEM restrictions, or
signed App Attest/Play Integrity behavior. Those remain physical-device release
gates.
