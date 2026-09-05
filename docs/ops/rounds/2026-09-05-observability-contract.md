# Round: 2026-09-05 - Privacy-safe observability contract

## Status

- State: `implemented and locally verified; physical-device and backend deployment-policy gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `68e305bd`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Make diagnostic coverage a durable part of NOOP development and close the
highest-value blind spots across iOS, Android, and the managed backend. A user
report must provide enough bounded operational evidence to investigate hangs,
sync failures, and backend errors without collecting health values, user text,
credentials, account identifiers, or request/response payloads.

## Scope

### In scope

- Audit the existing app report, performance, storage, navigation, and sync
  breadcrumbs on Apple and Android.
- Add structured, payload-free request and worker logging to the managed
  backend.
- Correlate managed client requests with backend logs on Apple and Android.
- Add privacy and retention tests for new diagnostic surfaces.
- Make observability review part of contribution, round, and local Codex-skill
  workflows.
- Record synthetic-only NOOP+ staging as a separate deployment gate; this
  round does not authorize a cloud mutation.

### Non-goals

- Upload app diagnostics automatically or add third-party analytics.
- Log raw health values, journal text, screenshots, phone numbers, wearable or
  installation identifiers, URLs, signed capabilities, tokens, or payloads.
- Log every rendered frame, sensor sample, database row, or UI tap.
- Treat simulator or synthetic evidence as physical-device validation.

## Starting evidence

- Reproduction or observed symptom: users described intermittent lag and
  collection/sync failures as only "a bit buggy", which requires an actionable
  user-initiated report rather than guesswork.
- Relevant source/device/OS/firmware class: iOS 17+, Android API 26+, FastAPI
  managed API/processor/lifecycle on Cloud Run.
- Existing tests, logs, exports, screenshots, or documents: both apps already
  retain bounded current/previous session logs, main-thread stalls, resource
  snapshots, navigation, database/sync operations, and OS-authored crash/hang
  evidence. The backend disables raw access logs but has no equivalent
  payload-free request latency/status/correlation record.
- Unknowns that must remain unknown until measured: physical-device report
  completeness during a real hang, Cloud Logging volume under representative
  load, and whether a reported user issue reproduces after these changes.

## Delivered

- Apple and Android now retain bounded current/previous app-session evidence
  for lifecycle, foreground responsiveness, resource pressure, database and
  analysis work, import/export, self-hosted sync, managed sync, report
  assembly/sharing, and collection freshness.
- Both band clients record categorical connect, disconnect, and connect-failed
  transitions. They include reconnect disposition and whether an in-flight
  history attempt was interrupted, but no band address, serial, RSSI, raw
  platform error, payload, sensor value, or sensor timestamp.
- Each band history attempt is a begin/end operation span with a fixed outcome,
  elapsed time, and aggregate persisted-row and acknowledged-batch counts.
  Process termination leaves an unmatched begin marker, which distinguishes a
  killed/stalled attempt from a completed one.
- Managed Apple and Android requests record static route groups, status family,
  duration, target, and the server-generated request ID. The managed API
  returns the same request ID without exposing account or installation
  identity.
- FastAPI request, lifecycle, processor, retention, and Safety-worker paths
  emit structured, payload-free events with fixed failure categories. Logging
  is best effort and cannot change request or worker outcomes.
- Shake reports remain local and user-reviewed. They exclude the health
  database, raw captures, strap transcripts, raw health timestamps, and
  research questionnaires by default; screenshots are explicit opt-in.
- The contribution guide, PR checklist, round template, durable decision, and
  local `$noop-ops` skill now require an observability review for every
  material change.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: app diagnostic caps remain bounded; backend
  log retention remains an infrastructure policy and must be reviewed before
  public traffic.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: no new mobile permission or automatic
  diagnostic upload.
- Health/medical claim impact and limitations: none; operational diagnostics
  do not validate a physiological metric.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: operation
  begin/end spans, fixed lifecycle transitions, bounded latency/count/resource
  summaries, static managed-route groups, server request IDs, OS crash/ANR
  evidence, collection freshness buckets, and categorical worker outcomes.
- Why existing evidence is sufficient, or why new evidence is required: the
  previous report described current band state but could not reconstruct an
  intermittent disconnect or history attempt. The new transport and history
  spans close that specific blind spot.
- Existing evidence reused: both `AppDiagnosticsRecorder` implementations,
  Apple MetricKit, Android historical process exits/ANR traces, managed HTTP
  clients, and backend structured logging.
- New bounded events or operation spans: `band.transport`,
  `band.history_sync`, managed request spans, backend request events, and fixed
  worker lifecycle events.
- Redaction, retention, and high-frequency controls: mobile sessions are
  capped at 512 KiB each; OS evidence has separate caps; backend events contain
  no payload; field-name redaction is a final boundary; no sample/frame/row/
  recomposition/tap logging was added.
- Cross-platform/backend correlation: Apple and Android use the same band and
  managed-request vocabulary; managed client records carry the matching
  server-generated request ID.
- Remaining blind spots: physical-device BLE/background behavior, OS delivery
  after force-quit, actual user-report completeness during a hang, backend log
  volume/cost, dashboard thresholds, retention policy, and on-call ownership.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Initial source audit | Completed | Existing mobile diagnostic coverage and the backend request-correlation gap are identified | Runtime behavior after implementation |
| Focused Apple recorder + band diagnostics (`xcodebuild`, 11 tests) | Passed | Apple app target compiles and recorder/category invariants pass | Physical BLE delivery or background execution |
| Focused Android recorder + band diagnostics (`testFullDebugUnitTest`) | Passed | Android full-debug code compiles and fixed categories/redaction tests pass | Physical GATT behavior or OS background survival |
| Server Ruff check and format check | Passed | New middleware, structured events, and tests satisfy the server's static Python policy | Live Cloud Logging ingestion, volume, or retention |
| Complete server `pytest` suite | Passed | Existing API/worker behavior and the new correlation/redaction paths remain compatible | Managed staging or production behavior |
| `NoopRemoteSync` package suite, 89 tests | Passed | Apple managed-request route grouping, request-ID validation, and package behavior pass | A real managed endpoint or object-store transfer |
| Full iOS simulator app/Watch/widgets build graph | Passed | The complete Apple graph compiles with the diagnostics changes | Signing, physical shake, BLE, background execution, or sharing |
| macOS Strand test action, 1,614 tests with 1 intentional skip and 0 failures | Passed | The Apple application and analytics regression graph remains green | iPhone-only runtime behavior |
| Android full matrix, 4,038 unit tests plus lint, debug APK, and instrumentation compilation | Passed | Android diagnostics, app code, resources, and instrumentation sources compile and pass locally | Physical Android BLE/background behavior or an installed APK |
| `$noop-ops` `quick_validate.py` | Passed | The updated local skill is structurally valid | That every future change will apply the contract correctly |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: no app data modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: physical shake report, locked-background collection,
  managed sync, and report sharing.

## Git and release state

- Changed paths: bounded Apple/Android recorders and app-report assembly, BLE
  transport/history diagnostics, managed clients, backend request/workers,
  observability tests, engineering policy documents, and the local
  `$noop-ops` skill.
- Commits: pending.
- Branch and remote state: local `main` is one pre-existing commit ahead of
  `origin/main`; this round remains uncommitted.
- Repository visibility verified: not repeated in this round.
- Version/build impact: no version bump.
- Release or distribution impact: no commit, push, cloud deployment, store
  upload, or physical-device install occurred; staging remains synthetic-only
  and private.

## Decisions

- Durable decision added or changed: observability is an acceptance criterion
  for every material change, with bounded local mobile reports and
  payload-free backend events.
- Decision-log entry: `D-039`.

## Open risks and honest limitations

- Excessive logging can itself cause latency, battery, privacy, and cost
  regressions. Coverage must therefore use stable state transitions, bounded
  summaries, and failure categories rather than per-sample narration.
- Backend correlation does not replace traces, dashboards, alert ownership, or
  physical-device evidence.

## Next round

1. Install on representative iPhone and Android hardware, reproduce a report
   during collection/background and UI-lag scenarios, and verify the reviewed
   ZIP is useful and contains no unexpected health or identity data.
2. Define backend log retention, access control, volume/cost budgets,
   dashboards, alert thresholds, and ownership before managed public traffic.
3. Complete the remaining synthetic NOOP+ staging gates without real health
   data.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
