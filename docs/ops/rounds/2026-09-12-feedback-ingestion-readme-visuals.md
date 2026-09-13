# Round: 2026-09-12 - Feedback ingestion and README visuals

## Status

- State: `implementation and exact-current-tree local verification complete;
  consolidated push, hosted exact-SHA checks, and protected integration pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `2a94bb5e8916f40004cfd1a938df2f2cf72d2824`
- End implementation commit: `156937fc642980286355cb663b9f3840af7e4923`
- Record commit or PR: pull request `#15`

## Objective

Confirm the separate private NOOP Band SDK repository, turn the root README
into a polished visual product and engineering guide using only NOOP-owned or
deterministically generated imagery, and replace the report sheet's
share-first workflow with a user-initiated **Send feedback** flow on Apple and
Android.

The feedback flow must show durable queued/uploading/sent/failed progress,
continue a consented upload in the background where the operating system
allows it, store a bounded redacted report in NOOP-operated feedback storage,
and give operators enough status evidence to diagnose ingestion without
collecting health values, the health database, credentials, dynamic
identifiers, or arbitrary exception text.

## Scope

### In scope

- Verify the remote `Dhanunjay-Divi/NoopBandSDK` visibility and exact head.
- Add a visual README hierarchy with NOOP-owned/generated desktop and phone
  captures and honest captions.
- Add a versioned feedback-ingestion contract, bounded storage, retention,
  authorization/rate limits, deletion, and direct server tests.
- Add Apple and Android persistent upload queues, user-visible progress,
  retry/cancellation behavior, and matched consent semantics.
- Keep optional note and screenshot inclusion explicit and previewable.
- Add bounded mobile/server observability for queued, uploading, sent,
  rejected, retrying, and terminal failure states.
- Exercise the end-to-end flow with synthetic, non-health fixtures.

### Non-goals

- Automatic crash reporting, telemetry, or background upload without a user
  pressing **Send feedback**.
- Uploading the health database, raw sensor data, biometric values, journal
  content, calendar content, credentials, tokens, device identifiers, or
  arbitrary logs.
- Committing the owner-supplied comparison screenshot, competitor branding, or
  third-party imagery.
- Claiming production public ingestion, abuse resistance, App Attest/Play
  Integrity, signed background transfer, or store readiness without matching
  deployment and physical-device evidence.

## Starting evidence

- Reproduction or observed symptom: the current report review ends in a
  platform share sheet. The owner wants one direct **Send feedback** action,
  visible progress, background continuation, and server-side storage for
  analysis.
- Relevant source/device/OS/firmware class: Apple report builder and app shell,
  Android report controller and Compose sheet, managed server/API/storage, and
  README assets.
- Existing tests, logs, exports, screenshots, or documents: current app-report
  UI tests, redacted diagnostic archive tests, managed request observability,
  repository-owned assets under `docs/assets`, and deterministic visual QA
  tooling.
- Unknowns that must remain unknown until measured: physical-device background
  continuation, cellular interruption behavior, production abuse volume,
  operator review latency, user opt-in rate, and the final production
  retention/legal policy.

## Delivered

- Verified that `Dhanunjay-Divi/NoopBandSDK` is a separate private,
  non-archived repository at exact head
  `ee82cc084d361c35267b4228af897e137a6fd66b`.
- Cancelled the obsolete in-progress Apple workflow for superseded app head
  `2a94bb5e8916f40004cfd1a938df2f2cf72d2824` before starting this new source
  delta; no duplicate workflow was triggered.
- Replaced the share-first report action on Apple and Android with one explicit
  **Send feedback** action. The user reviews the optional note, screenshot, and
  bounded diagnostics before transfer; nothing is uploaded automatically.
- Added durable local outboxes with queued, uploading, retrying, sent,
  cancelled, and terminal-failure states. A consented send may continue
  best-effort in the background, resumes after process interruption, preserves
  retry ownership, and exposes progress without requiring the user to manage a
  share sheet.
- Added versioned archive validation, bounded redacted diagnostics, screenshot
  preview/sanitization, attachment limits, retention, cancellation, deletion,
  and exact-attachment-set checks on both phones.
- Added a fail-closed backend capability and principal boundary, request
  validation, tenant isolation, PostgreSQL lifecycle state, object-storage
  cleanup, size/rate limits, cancellation, retention, and payload-free
  operational events. Health databases, sensor rows, biometric values,
  credentials, persistent device identifiers, dynamic URLs, and arbitrary
  exception text are rejected from the report contract.
- Added default-off GCP/OpenTofu feedback resources and lifecycle tests without
  applying public ingress or production traffic. New production reservations
  remain gated by App Check/attestation, external abuse controls, operator
  access, monitoring, legal retention approval, and physical-device evidence.
- Replaced the root README with a product-first, local-first guide and
  NOOP-owned/deterministically generated visual assets. All 35 checked local
  links resolve; private comparison screenshots and third-party artwork remain
  outside Git.
- Generated and verified feedback strings across all nine supported locales.

## Data, privacy, and medical truth

- Schema or migration impact: PostgreSQL feedback lifecycle/principal cleanup
  is versioned in migration `040`; no health schema or scoring formula changed.
- Existing-data retention impact: feedback objects and lifecycle records use
  bounded retention and terminal cleanup; local health data is not attached.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: feedback is a new optional network
  destination and must be disclosed immediately before first send.
- Health/medical claim impact and limitations: none; report ingestion is a
  support/quality path and cannot become health interpretation or emergency
  monitoring.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: each client
  records one bounded lifecycle transition and operation timing; the server
  records static route, status family, bounded size/count, and generated
  correlation only.
- Why existing evidence is sufficient, or why new evidence is required: a
  durable cross-process upload adds lifecycle states not covered by the current
  share-sheet path, so bounded queue and ingestion evidence is required.
- Existing evidence reused: platform `AppDiagnosticsRecorder`,
  `RequestObservabilityMiddleware`, and server operational events.
- New bounded events or operation spans: queued, upload-begin, retry,
  cancellation, completion, rejection category, and terminal failure.
- Redaction, retention, and high-frequency controls: one event per state
  transition; fixed categories/counts/durations only.
- Cross-platform/backend correlation: server-generated report receipt only,
  never a persistent device or health identifier.
- Remaining blind spots: physical background transfer, public abuse controls,
  and operator workflow.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| SDK repository verification | Private, non-archived repository at `ee82cc084d361c35267b4228af897e137a6fd66b` | The neutral SDK boundary is already separate from the app repository | Supplier rights, binary integration, or physical hardware behavior |
| Complete server suite | 433 passed, 106 external/configuration skips, one Starlette deprecation warning | Feedback validation, capabilities, tenant isolation, lifecycle, cancellation, cleanup, PostgreSQL/object-storage behavior, and the broader server remain coherent | Public abuse resistance, real operator workflow, or production ingress |
| Focused backend/infra | 25 passed, 9 external/configuration skips; eight OpenTofu lifecycle tests passed; configuration validated | The feedback API and default-off GCP lifecycle fail closed under synthetic fixtures | A deployed public endpoint or production IAM review |
| Complete Apple app and UI | 1,913 app tests passed with one external fixture skip; the 39-test iPhone UI suite had one private-pilot skip and zero failures | Apple archive, outbox, screenshot review, consent, progress, retry, and UI contracts compile and execute on the current tree | Signed physical background transfer or cellular interruption |
| Android exact-source matrix | Full and Demo unit suites, both lint variants, APK assemblies, and instrumentation Kotlin compilation passed | Android archive, outbox, WorkManager, screenshot, consent, progress, retry, and localization contracts compile together | OEM background policy, process death under pressure, or signed physical transfer |
| Privacy and release gates | Feedback localization, strict i18n, private-data, terminology, claims, required-CI, release-control, legal, distribution, and diff gates passed before record refresh | The new path remains explicit, localized, bounded, and protected from obvious secret/private-data regressions | Legal approval, attestation quality, monitoring, or operator staffing |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no participant or owner health data changed
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical background upload, cellular interruption,
  process termination, notification presentation, BLE, haptics, and battery

## Git and release state

- Changed paths: Apple/Android feedback archive, outbox, review, upload, tests,
  localization; server API, capability, principal, lifecycle, repository,
  migration and tests; GCP source/tests; README and owned visual assets;
  feedback architecture and operations records
- Commits: implementation `156937fc`; record follow-up containing this entry
- Branch and remote state: PR `#15` remains open; the superseded exact-head
  Apple workflow was cancelled before further source changes
- Repository visibility verified: app repository public temporarily for the
  active protected integration; SDK repository private
- Version/build impact: PostgreSQL migration `040`; no app marketing-version or
  health-schema change
- Release or distribution impact: no artifact released

## Decisions

- Durable decision added or changed: user feedback remains explicit,
  user-initiated network transfer. Background continuation begins only after
  that consented send and cannot become passive telemetry.
- Decision-log entry: `D-057`.

## Open risks and honest limitations

- A direct upload endpoint needs production abuse controls and an operator
  access/retention policy before public launch.
- iOS and Android background execution remain best effort until validated on
  signed physical builds.
- Screenshots and free-form notes are sensitive; they must remain separate,
  optional inclusion choices with explicit review.

## Next round

1. Create the bounded replacement commit, push once, require fresh hosted
   exact-SHA checks, and integrate through the normal protected path.
2. Validate signed physical background/cellular behavior and complete
   attestation, public-edge abuse control, operator access, monitoring, legal
   retention, and production deployment gates before enabling public ingestion.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
