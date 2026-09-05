# NOOP observability contract

NOOP diagnostics exist to explain failures without becoming telemetry, a
privacy leak, or a performance problem. Core mobile diagnostics are always
local and bounded. A user explicitly reviews and shares an app report. The
optional managed backend writes payload-free operational events to its
deployment log sink.

Observability is an engineering acceptance criterion for every material change.
That does not mean every function needs a log. It means the change must identify
its important lifecycle, latency, and failure boundaries and either use an
existing signal or add a bounded one.

Before merge, the change and its round record must answer:

1. What exact evidence will diagnose each material user-visible or operational
   boundary when it succeeds, stalls, is rejected, or fails?
2. How is that evidence bounded, and what prevents health data, user content,
   credentials, dynamic identifiers, or payloads from entering it?

## Mobile evidence

Apple and Android use their platform `AppDiagnosticsRecorder` implementations.
The report includes operational evidence rather than health history:

- process, scene/activity, protected-data, memory, power, and thermal edges;
- active-screen or fixed-route navigation;
- aggregated scroll/frame hitches and main-thread stalls;
- band transport connect/disconnect/failure transitions with fixed reason and
  reconnect-plan categories, including whether an active history attempt was
  interrupted;
- band history-sync begin/end spans with duration plus aggregate persisted-row
  and acknowledged-batch counts;
- database open/refresh, analysis, self-hosted sync, and managed-sync duration
  and outcome;
- managed HTTP target, static route group, method, status, duration, and the
  server-generated request ID;
- Apple MetricKit crash/hang evidence or Android process-exit/ANR evidence;
- database file footprint, available storage, and process-memory summaries.

Current and previous session logs are capped at 512 KiB each. Apple MetricKit
evidence is capped at 2 MiB. Android exit evidence is capped at 512 KiB.
High-frequency display and sensor work is summarized or throttled; individual
sensor samples, health values, database rows, frames, recompositions, and taps
are not recorded.

Band events never include the Bluetooth address, peripheral identifier,
advertising name, serial, RSSI, raw GATT/CoreBluetooth status, frame content,
sensor timestamp, or exception text. A fixed `modern`/`legacy` family category
may be included to distinguish protocol paths without identifying a band.

On iPhone or Android, a physical shake opens the report flow. The user may add
bounded context and may explicitly include a screen image; the image is off by
default. The exact attachment list is shown before the system share sheet
opens. The report does not automatically upload and does not include the health
database.

## Backend evidence

`RequestObservabilityMiddleware` emits one Cloud Logging-compatible JSON record
per non-health-probe request:

- `schema`, timestamp, severity, service, and event;
- server-generated `request_id`;
- HTTP method and FastAPI route template, never a dynamic path or query;
- status code/family, duration, and a response-size bucket;
- fixed authentication scope/result categories;
- an exception class category when an unhandled failure occurs.

The same request ID is returned in `X-Noop-Request-ID`, including generic
privacy-safe 500 responses. Apple and Android store that ID with the matching
managed-request breadcrumb so a user report can be correlated with server logs
without an account, device, or installation identifier.

Processor, lifecycle, retention, and Safety workers emit stable operation
outcomes, durations, counts, retry categories, and provider-state categories.
They do not emit persistent job, contact, dispatch, object, account, or device
identifiers. Successful `/healthz` and `/readyz` probes are omitted to control
noise and cost; failed probes remain visible.

## Prohibited data

No operational log may contain:

- health, biometric, location, or raw sensor values;
- journal, Coach, support, questionnaire, or other user-entered text;
- screenshots or request/response payloads;
- names, addresses, phone numbers, or email addresses;
- OTPs, passwords, authorization headers, cookies, tokens, credentials,
  signed URLs, or signed capabilities;
- account, profile, member, contact, device, source, installation, session, or
  persistent worker/job identifiers;
- dynamic URLs, paths, queries, object keys, or arbitrary exception messages.

Recorder and server sinks apply field-name redaction as a final boundary.
Callers still must pass only fixed categorical values; boundary filtering is not
permission to send an unsafe field under a vague key.

## Adding or changing code

For each material path:

1. Identify a user-visible failure, expensive operation, state transition, or
   external dependency that needs evidence.
2. Reuse an existing operation or request event when it already answers the
   question. Do not narrate internal steps without a concrete diagnostic need.
3. Use fixed event and field names. Prefer outcome, duration, count, size
   bucket, status family, and stable failure category.
4. Add Apple and Android coverage together when the path exists on both.
5. Prove redaction, bounding, route templating, and failure behavior with tests.
6. Record the observability decision and remaining blind spots in the active
   round record.

Use the structured facilities above instead of `print`, `NSLog`, Logcat, or
arbitrary exception strings. Platform console logging may still be appropriate
for a deliberately opt-in, redacted developer capture, but it does not satisfy
the app-report or backend-operability contract.

Backend log retention, dashboards, alert thresholds, access control, and cost
budgets remain deployment policies. They must be explicitly reviewed before
public traffic; adding structured events alone does not establish an on-call or
production reliability claim.
