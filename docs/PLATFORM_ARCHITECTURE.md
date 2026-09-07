# NOOP platform architecture

**Status:** principal design and release contract
**Reviewed:** 2026-09-04
**Scope:** native clients, day guidance, managed storage, and 1K-to-1M growth

This document works backward from the customer experience. It is both a target
architecture and a record of which parts exist today. A target is not a shipped
claim. The evidence required to move a row from target to available is listed
below.

## 1. Customer promise

NOOP should help a person understand and improve the shape of their day without
making the band, an account, or the network a single point of failure.

The product contract is:

1. App exploration and imports remain account-free. A first-party band needs a
   one-time ownership claim; after activation, collection, current metrics,
   immediate coaching, export, and user controls continue locally without
   NOOP+, payment, subscription, or continuous network.
2. Opening the app never waits for cloud login, upload, restore, or a large
   analytics query.
3. The user sees data freshness, gaps, source, confidence, and sync progress.
   NOOP never displays fake random progress or treats missing data as zero.
4. Guidance is timely but quiet. One useful action is better than several
   competing notifications.
5. Every interruption has fresh evidence, an explicit setting, a useful action,
   quiet-hour and cooldown rules, and a traceable reason.
6. Wellness guidance is not diagnosis, treatment, emergency monitoring, or a
   guarantee of an outcome.
7. A user can export local data without paying. NOOP+ restricts managed storage,
   restore, and multi-device history only, not metrics or coaching.
8. A user can disconnect, revoke a device, and erase the managed account
   without deleting the local app database. Apple and Android can assemble a
   snapshot-bound ZIP containing every currently retained managed chunk and
   personal record, including history no longer present on that phone.
9. Band ownership identity and NOOP+ health-data consent are separate. A plan
   downgrade or payment failure cannot deactivate a band or remove core local
   capability.
10. The exact accepted Terms and Conditions come from immutable NOOP-controlled
    remote storage and are not persisted as a full document by the app. Return,
    inspection, deduction, refund, and appeal rules are published before sale.

These are architecture constraints, not marketing copy.

The current source implements local export, managed snapshot/incremental
restore, complete managed-history ZIP export, device revocation, and managed
erasure. The native export intentionally uses the snapshot restore/list/download
APIs so it includes cloud-only history; it does not use the separate server
`/exports` contract, which accepts and verifies a client-produced encrypted
archive. The managed-history ZIP is locally verified source, not a deployed
production claim, and an importer plus interrupted-export resume remain future
portability work.

## 2. Work backward from a day

The intended customer loop is:

```text
wearable and phone signals
          |
          v
local durable capture -> source and quality qualification -> local metrics
          |                                             |
          |                                             v
          |                                  candidate opportunities
          |                                             |
          v                                             v
background backup <-------------------------- day arbiter
                                                        |
                                      +-----------------+----------------+
                                      |                 |                |
                                      v                 v                v
                                  in-app action    notification     band cue
                                      |                 |                |
                                      +-----------------+----------------+
                                                        |
                                                        v
                                            local outcome and fatigue log
```

The app should help at moments that have enough evidence and a reasonable next
action:

- **Morning:** explain sleep and recovery, acknowledge uncertainty, and offer a
  realistic plan rather than a judgment.
- **During the day:** surface one hydration, breathing, movement, or recovery
  action only when the relevant signal is fresh and the user opted in.
- **During a workout:** keep live safety-adjacent caution separate from ordinary
  wellness guidance. A fresh sustained heart-rate cue may suggest pausing, but
  NOOP cannot diagnose severity.
- **Evening:** protect the selected sleep window and collect useful journal
  context without repeatedly prompting.
- **After travel or a disrupted routine:** describe the observed shift and adapt
  timing. Do not infer a party, alcohol, illness, work stress, or intent.
- **After sync gaps:** explain freshness and continue catch-up in the background.
  Cloud storage cannot prevent phone suspension or a BLE disconnect.

## 3. Current implementation versus target

| Capability | Current evidence | Target or remaining gate |
|---|---|---|
| Local BLE capture and durable SQLite | Implemented on Apple and Android | Physical-device reconnect, suspension, battery, and upgrade matrix remains |
| First-party band ownership account | Supplier-independent schema, isolated runtime, verified email/password flow, optional phone linking, atomic claim, replacement-installation authorization, revocation, and matched mobile state machines are implemented default-off; possession always returns unavailable | Supplier printed-label mapping, approved cryptographic possession provider, owner-key provisioning, controlled release, physical validation, production identity/abuse operations, and India/USA legal review |
| Remote terms and returns | Digest-verified no-cache terms fetch, exact acceptance metadata, and static mobile rendering are implemented default-off; no approved document is published and return duration remains undecided between 14 and 30 days | Immutable signed publication and historical availability, approved return clock, objective condition grades, lawful refund deductions, appeals, and operator-only wipe/release |
| Local scoring and source provenance | Implemented with pure Swift/Kotlin engines and explicit missing-data behavior | Held-out accuracy and subgroup validation remains metric-specific |
| Stress breathing cue | Local, opt-in, freshness/corroboration/cooldown/quiet-hour gated | Physical delivery and false-interruption evidence remains |
| Morning Sleep and evening Journal prompts | Local, opt-in, private copy, completion aware | One shared cross-domain arbiter is not yet implemented |
| Hydration, wind-down, workout caution, adaptive sleep/routine/travel | Implemented as bounded local policies and compact in-app actions | Cross-family fatigue budget and outcome learning remain |
| Contextual action center | Implemented on Apple and Android with expiry, deduplication, dismiss, and completion | A shared candidate/outcome event schema remains |
| NOOP+ phone OTP and App Check clients | Implemented; Firebase Identity Platform and enforced Authentication App Check are deployed in synthetic Mumbai staging | Migrate release identity to the approved email/password ownership account with optional linked phone while preserving separate NOOP+ consent, then prove signed physical clients, recovery, and abuse controls |
| Immutable managed chunk upload/restore | Implemented and passed private synthetic upload, processing, duplicate, tenant-isolation, restore, retention, and erasure smoke against one scanned digest | Signed physical clients, recovery/load evidence, and public launch gates |
| Complete managed-history ZIP export | Apple and Android finish pending phone backup, pin a server snapshot, page every retained chunk and current personal record, verify digests/counts/bytes, and finalize a manifest-backed archive | Live large-account/expiry/interruption tests, resumable continuation, and a documented importer remain |
| Optional seven-day raw and 30-day essential local window after validated backup | Implemented, default off | Physical storage-pressure and interrupted-prune validation |
| GCP managed runtime | Identity, App Check, Cloud SQL, API, processor, lifecycle, scheduler, KMS, Pub/Sub, and storage are deployed IAM-only; migration/lifecycle, private smoke, and zero drift pass | Recovery/load evidence and every public-ingress gate |
| Outcome-based personalization | Existing actions record local completion/dismissal in feature-specific stores | No general learning policy ships; experimental design and consent are required |

## 4. Architectural principles

### 4.1 Local authority

The phone is authoritative for:

- BLE session state and durable receipt of wearable history;
- current freshness and data-quality assessment;
- immediate user-facing metrics;
- active workout and breathing interactions;
- notification eligibility and quiet hours;
- the final decision to present any cloud-originated suggestion.

The cloud must never be required to render today's core experience. A server
result may enrich a long-horizon trend, but it cannot make a stale local signal
fresh or silently override a local safety/privacy gate.

### 4.2 Durable before derived

Every producer writes normalized source data durably before advancing a cursor,
acknowledging a wearable trim, marking an upload complete, or publishing a
derived read model. Process death between any two steps must leave retryable
work, not an ambiguous success.

### 4.3 Immutable high-rate data

Compressed, checksummed, bounded chunks belong in object storage. PostgreSQL
stores identity, authorization, manifests, cursors, quotas, aggregate
provenance, export/erasure state, and queryable summaries. It does not become an
indefinite duplicate of every high-rate sample.

### 4.4 Explicit trust boundaries

Local NOOP, Self-hosted Sync, and NOOP+ are distinct destinations:

- Local NOOP exploration, imports, metrics, records, and exports require no
  account. First-party band activation uses a minimal ownership account, but
  its identity/control records contain no health payload and ongoing local band
  use does not depend on NOOP+ or payment.
- Self-hosted Sync trusts the operator selected by the user.
- NOOP+ uses the approved release identity, app attestation, per-installation
  credentials, separate health-data consent, and an internal tenant identifier.

Server-readable sync and a future end-to-end encrypted private backup are
different products. The current managed chunk format is server-readable and
must be described that way.

### 4.5 Evidence before automation

Rules with transparent evidence and conservative thresholds ship before
adaptive machine learning. A model can rank only candidates that already passed
hard eligibility, freshness, privacy, and medical-safety rules. It cannot invent
a candidate or weaken those rules.

## 5. Native client architecture

Each platform keeps native UI and lifecycle integration while sharing a product
contract and equivalent pure-domain behavior.

```text
Platform sensors / BLE / Health APIs
                 |
                 v
         ingestion coordinator
                 |
        durable transaction + outbox
                 |
       +---------+----------+
       |                    |
       v                    v
 local analytics       sync chunker
       |                    |
       v                    v
 read models          resumable transfer
       |
       +-------> Today / Sleep / Activity / Trends
       |
       +-------> guidance candidate generators
```

### 5.1 Threading and responsiveness

- Database, compression, decompression, large decode, export, restore, and
  network operations run off the main/UI thread.
- Screens render bounded read models, not unbounded table scans.
- Long history uses paging, aggregation, and cancellable queries.
- Collection writes have priority over decorative rendering and cloud upload.
- Upload, restore, and pruning pause or back off under thermal, low-storage, low
  battery, metered-network, or foreground contention according to platform
  capabilities.
- A sync banner may show initial activity briefly, but it must disappear into a
  truthful background state. Progress is based on durable bytes/windows and
  server acknowledgements, never an animation pretending work completed.

### 5.2 Frontend parity

Parity means the same information architecture, actions, state semantics,
terminology, evidence, and accessibility on iOS and Android. Native status bars,
back gestures, typography metrics, permission sheets, and platform controls do
not need artificial pixel identity.

Both apps must expose:

- the same five primary destinations and root reselect behavior;
- equivalent loading, stale, empty, unavailable, error, and partial-data states;
- source, confidence, freshness, and related-signal explanations;
- the same NOOP+ consent, storage, device revocation, export, and deletion
  boundaries;
- compact contextual actions that never cover navigation or primary content;
- Dynamic Type/font-scale, screen-reader, contrast, reduced-motion, and narrow
  viewport behavior.

### 5.3 Client performance release budgets

These are release objectives to measure on representative physical mid-tier
devices, not claims from simulator builds:

| Journey | Pilot budget |
|---|---|
| Warm launch to interactive shell | p95 at or below 750 ms |
| Cold launch to interactive shell | p95 at or below 2 s |
| Primary screen transition response | p95 at or below 200 ms |
| Core scrolling | At least 95% of frames within the device refresh budget |
| Main-thread database/network work | None by design |
| Newly committed local data visible | p95 at or below 2 s |
| Foreground sync blocking the UI | 0 s; all transfer is asynchronous |
| Crash-free sessions | At least 99.8% in pilot, with privacy-safe evidence |

Budgets must be collected without sending raw health values, phone numbers,
tokens, or device identifiers. Until a reviewed telemetry consent exists,
diagnostic evidence is user-exported from the in-app report bundle.

## 6. The day orchestrator

The day orchestrator is a local policy layer, not a chatbot and not an
unbounded notification generator.

### 6.1 Candidate contract

Every candidate should carry:

```text
candidate_id             deterministic idempotency key
kind and domain          sleep, stress, hydration, workout, journal, utility
observed_at / expires_at freshness boundary
evidence_refs            source-qualified local observations
confidence               building or strong, never implied certainty
action                   one concrete in-app destination
interruptibility         in-app only, ordinary, time-sensitive, or safety lane
preference_requirement   exact user opt-in that permits it
quiet-hour behavior      respect, defer, or separately justified bypass
cooldown and budget_cost anti-fatigue controls
conflicts                candidates this action supersedes
copy_revision            auditable wording version
policy_revision          reproducible decision version
```

Raw values do not need to enter notification copy or diagnostics. The local
candidate may retain references to the underlying rows for an in-app
explanation.

### 6.2 Arbitration order

1. Reject missing, stale, implausible, conflicting, or unsupported evidence.
2. Require the exact opt-in and an available useful action.
3. Apply current context: worn state, active workout, sleep/quiet window,
   driving/focus state only when a platform permission and product policy allow
   it, notification permission, and recent user actions.
4. Deduplicate the observation and merge semantically equivalent candidates.
5. Apply topic cooldown, global interruption budget, and user fatigue.
6. Resolve conflicts by priority and expected usefulness.
7. Deliver at most one interruptive wellness action; keep lower-priority current
   actions available in-app when useful.
8. Persist the decision only after the OS accepts the request.

Safety and workout-caution lanes remain separate. An SOS is never suppressed by
a wellness budget. Conversely, a wellness score can never enter the Safety
paging pipeline.

### 6.3 Initial deterministic ranking

The first shared arbiter should use an inspectable score:

```text
rank =
  urgency
  + evidence_confidence
  + freshness
  + preference_fit
  + expected_action_value
  - interruption_cost
  - recent_prompt_fatigue
  - conflict_penalty
```

The constants, tie-breaks, and reason tokens must be versioned and tested
identically across Swift and Kotlin. Hard rejection gates run before ranking and
cannot be offset by a high score.

### 6.4 Outcome loop

Record these local events:

- eligible, suppressed with reason, scheduled, presented when observable;
- opened, action started, completed, snoozed, dismissed, expired;
- data became stale, permission unavailable, or route unavailable.

Completion means the user performed the explicit app action, not that a health
outcome improved. Correlation with later sleep, stress, or recovery is
descriptive and cannot establish causation.

Outcome events remain local initially. Uploading even pseudonymous engagement
data requires a separate purpose, consent, minimization, retention, and deletion
decision. A future contextual bandit may personalize timing only after:

- deterministic policy and holdout evaluation are stable;
- exploration is bounded and never applies to safety or medical-like prompts;
- a no-learning baseline and kill switch exist;
- subgroup, fatigue, false-interruption, and opt-out results pass review.

## 7. Managed backend

### 7.1 Request path

```text
iOS / Android
  | Firebase phone identity + App Check + installation credential
  v
Cloud Run managed API
  | reserve immutable key and quota
  v
signed one-object upload capability
  |
  v
CMEK Cloud Storage ---- finalize event ----> Pub/Sub
                                                |
                                                v
                                      idempotent processor
                                                |
                         +----------------------+------------------+
                         |                                         |
                         v                                         v
              PostgreSQL control plane                   derived summaries
```

The mobile app uploads directly to the one object key authorized by a
short-lived signed capability. The API never proxies large chunk bodies through
its own instance memory.

### 7.2 Authorization layers

A request must pass all layers:

1. TLS and bounded request parsing.
2. Firebase App Check for an allowed signed app.
3. Firebase ID-token validation, expiry, disablement, and revocation.
4. Per-installation random credential.
5. Internal identity-to-account mapping.
6. Tenant predicate on every database and object operation.
7. Resource ownership, plan, quota, state-machine, and idempotency checks.

App Check is abuse resistance, not tenant authorization. A valid app instance
cannot read another account.

### 7.3 Data classes

- `essential_timeseries`: normalized HR, R-R, battery, events, and related
  durable essentials.
- `raw_auxiliary`: qualified auxiliary sensor streams.
- `raw_ppg`: bounded optical detail.
- `raw_motion`: bounded motion detail.
- `derived_summaries`: daily, sleep, workout, journal, and other supported
  restore records.

Every chunk contains a schema version, source, exact event window, stream
manifests, compressed and uncompressed sizes, content digests, and a stable
idempotency identity. Processor limits are checked before and after
decompression.

### 7.4 Restore and multi-device convergence

- Initial restore obtains a server snapshot and high-water change sequence.
- Chunk pages are ordered and checkpointed.
- Each object is generation-bound, checksum-verified, decompressed within a hard
  limit, schema-validated, and applied transactionally.
- Incremental changes resume after the snapshot high-water mark.
- Applied changes are idempotent and recorded before advancing the local
  sequence.
- Authoritative replacement chunks supersede only the exact source, data class,
  and time window.
- Source provenance is never collapsed merely because two devices show the same
  day.

## 8. Regional cell architecture

Large wearable platforms commonly combine durable edge buffering, immutable
event storage, asynchronous processing, query-oriented summaries, and bounded
regional failure domains. NOOP should use those proven patterns while keeping
its stronger local-first boundary.

One production cell contains:

- regional API and worker services;
- a regional object bucket and KMS keys;
- regional queues and dead-letter queues;
- one HA PostgreSQL cluster with bounded pools;
- regional secrets, dashboards, alerts, and runbooks;
- no cross-cell database queries in the request path.

A small global control plane contains only account-to-home-cell routing,
service configuration, release metadata, and non-health operational state.
Phone number and health data remain in the selected home region unless a
separately disclosed migration runs.

### 8.1 Why cells

- limit the accounts affected by a bad deploy or database incident;
- preserve residency and reduce latency;
- scale by adding a known unit rather than enlarging one global database;
- test backup, restore, failover, and deletion per unit;
- move an account through an explicit dual-write-free migration state machine.

### 8.2 Growth stages

| Scale | Topology | Evidence that permits the next step |
|---|---|---|
| Up to 1K enrolled users | One synthetic/private-pilot cell, Cloud Run, object storage, Pub/Sub, PostgreSQL | Physical sync, tenant isolation, restore/erasure, and measured bytes/user-day |
| 1K-10K | HA database, minimum API/worker instances, bounded pools, WAF/rate limits, on-call | Mixed workload load test, 30-day soak, zone failover, cost per active user |
| 10K-100K | Partition manifests/change feed, independent read and ingestion scaling, replicas/cache only from measured need | p95/p99 SLOs under reconnect bursts and processor backlog |
| 100K-1M | Multiple capped regional cells, automated placement, cell health routing, canary by cell | Cell evacuation, account migration, regional recovery, abuse and support operations |

Kubernetes, Spanner, global active-active SQL, Kafka, and a separate service for
every domain are not starting requirements. Adopt one only when measured
limits, failure isolation, or staffing justify its operational cost.

### 8.3 Capacity model

Do not size from the approximately 600 MB SQLite footprint observed on one
phone. SQLite indexes, WAL, caches, duplicate representations, and local raw
formats do not equal compressed cloud bytes.

Measure:

```text
B = p50 / p95 compressed bytes per enrolled user-day by data class
C = p50 / p95 chunks per user-day
R = API and object requests per user-day
Q = processor CPU-seconds per compressed MB
D = restore bytes and objects per restore
A = daily and peak concurrently active enrolled users
```

Then calculate per cell:

```text
daily object ingress = A * B
daily request volume = A * R
peak processor demand = reconnect_burst_bytes * Q / recovery_window
retained object bytes = daily object ingress * retention_days * replica_factor
```

Plans and lifecycle rules are set only after these distributions are measured.
Cost alerts are guardrails, not capacity controls.

## 9. Reliability and operations

### 9.1 Pilot service objectives

These are objectives requiring production-like evidence:

| SLI | Pilot objective |
|---|---|
| Managed API successful request availability | 99.9% monthly, excluding invalid/auth-rejected requests |
| Chunk reservation-to-available latency | p95 under 5 minutes outside declared backlog incidents |
| Duplicate upload creates duplicate logical data | 0 in tested contracts |
| Cross-tenant object or row access | 0 tolerated |
| Restore integrity mismatch accepted | 0 tolerated |
| Erasure jobs past policy deadline | 0 tolerated; alert before breach |
| Queue oldest-message age | Alert before the restore/freshness objective is threatened |

No objective is a current production claim.

### 9.2 Backpressure

- Mobile work is chunked and bounded per run.
- Exponential retry includes jitter and honors `Retry-After`.
- Authentication refresh retries once around idempotent operations.
- Workers lease work and make completion idempotent.
- Queue age, dead-letter count, validation rejection, and per-tenant quota are
  observable without recording health values.
- Reconnect storms cannot open unbounded database connections.
- Cloud throttling never blocks local collection.

### 9.3 Deployment

- OpenTofu owns infrastructure; no console-only production drift.
- Runtime images are digest pinned and scanned before deployment.
- Database changes use expand, migrate, verify, contract. Rollback never assumes
  an irreversible down migration.
- Canary one staging/private cell before broader cells.
- Identity enrollment, upload, processing, restore, local pruning, export, and
  deletion each have independent kill switches.
- Public Cloud Run invocation is a separate gate from deploying an IAM-only
  service. Application authentication remains mandatory after public invocation
  is enabled.

### 9.4 Disaster recovery

Before pilot:

- restore PostgreSQL to a new instance from PITR;
- restore object manifests and verify generation-bound objects;
- prove an account restore from a clean mobile install;
- prove queue replay is idempotent;
- rotate identity lookup, database, replay, and signing access;
- rehearse a lost device, revoked installation, and account erasure;
- record measured RPO/RTO and revise customer language to match.

## 10. Security and privacy

- No email, phone number, wearable serial, readable health label, or user name
  appears in an object key.
- Plain identity tokens, App Check tokens, installation tokens, API keys with
  secret authority, raw health values, and signed URLs never enter logs.
- API keys embedded in mobile apps are treated as public identifiers and
  restricted by app identity and API target; they are not authorization.
- KMS, database, bucket, and service identities use least-purpose roles.
- Support access is default-deny, reason-bound, time-limited, approved, and
  audited before production support can inspect server-readable data.
- The managed-history exporter covers every selected immutable object
  generation, derived-summary chunk, current personal record, and provenance
  manifest in one consistent restore snapshot. Erasure state machines exist.
  Live large-account export, resumable continuation, archive import, and
  documented backup-deletion timelines remain launch gates.
- BigQuery receives no raw health data by default.
- App diagnostics use value-free reason tokens and a user-initiated export.

Required independent work includes mobile and API penetration testing, tenant
isolation review, dependency response, privacy/legal review per launch market,
and incident-response exercises.

## 11. Observability

The minimum operational view is:

- client local collection freshness and gap duration;
- local database size, query latency classes, WAL/checkpoint health, and prune
  counts without row values;
- sync windows pending, uploaded, awaiting validation, available, restored, and
  pruned;
- auth rejection category, never the token or phone;
- API rate, latency, status family, and bounded correlation identifier;
- database pool saturation, transaction latency, lock wait, and storage growth;
- queue age, retries, dead letters, processor rejection reason, and throughput;
- export/erasure age and deadline;
- per-cell active accounts, bytes, requests, and cost.

An alert must point to a runbook and an owner. Dashboards without a response
path are not a reliability system.

## 12. How NOOP can be better

NOOP does not beat a mature wearable platform by copying every screen or moving
all intelligence to the cloud. It can be materially better through:

- useful account-free exploration and subscription-independent post-activation
  operation with immediate local feedback;
- source-visible, confidence-visible metrics with missing data kept missing;
- transparent deterministic guidance before opaque personalization;
- one coherent action at a time instead of notification volume;
- user-owned export and self-hosting alongside optional managed convenience;
- local responsiveness even during cloud incidents;
- bounded regional data placement and explicit deletion;
- reproducible Swift/Kotlin policy parity and honest physical-validation gates.

The differentiator is trustworthy daily usefulness, not the number of generated
insights.

## 13. Delivery sequence

### Phase 0: current code completion

- Keep the implemented first-party ownership foundation disabled until an
  approved supplier possession provider replaces the fail-closed unavailable
  provider; then prove its virtual-band and physical-band claim matrices.
- Finish NOOP+ source review and full local test/build matrix.
- Accept Firebase terms and deploy identity/App Check to synthetic staging.
- Generate ignored environment configuration and register debug attestation.
- Deploy the managed API, processor, and lifecycle service IAM-only.
- Run synthetic upload, duplicate, reconnect, restore, isolation, and erasure
  tests.
- Prove the implemented managed-history export against live synthetic
  cloud-only history, large accounts, token refresh, cancellation, snapshot
  expiry, and interrupted transfer before any public launch.
- Add resumable continuation and a documented archive importer before claiming
  round-trip account portability.

### Phase 1: private physical-device pilot

- Keep public enrollment closed and admit explicit testers.
- Test signed iOS and Android builds, process death, background deferral,
  reconnect bursts, large history, low storage, upgrade, restore, and revoke.
- Measure compressed bytes/user-day, database growth, battery, latency, and
  notification false-interruption/fatigue.
- Complete legal, privacy, security, recovery, and support-access review.

### Phase 2: day-orchestrator consolidation

- Introduce the shared candidate and outcome schemas.
- Route ordinary wellness prompts through one deterministic arbiter.
- Keep safety, utility, and workout-caution lanes explicitly separate.
- Add an in-app decision history with source/evidence explanation.
- Validate parity and user-control behavior on both physical platforms.

### Phase 3: controlled launch

- Move the cell to HA/PITR and production budgets.
- Enable public invocation only after application auth and abuse gates pass.
- Roll out by signed build, region, and cohort with kill switches.
- Publish measured SLOs, retention, export, erasure, and support policies.

### Phase 4: measured growth

- Add cells and data partitions only at documented thresholds.
- Evaluate privacy-preserving outcome personalization only after the
  deterministic baseline, consent, and safety program pass.

## 14. Launch-blocking acceptance journeys

The product is not launch-ready until all of these work end to end:

1. A new user matches the printed number, receives the identify vibration,
   confirms possession from the worn band, accepts the ownership disclosure,
   verifies an email account, and becomes the band's only owner despite a
   simultaneous second-account claim.
2. The owner chooses NOOP rather than NOOP+ and still collects, scores, exports,
   exercises, journals, and uses automations without a managed-health request.
3. A user optionally verifies a phone but declines NOOP+ consent; no health
   data uploads.
4. An enrolled user loses network mid-upload; local collection continues and
   the exact chunk resumes without duplication.
5. A second signed device restores an exact snapshot, catches incremental
   changes, and preserves source provenance.
6. A token for account A cannot discover, reserve, download, export, revoke, or
   erase any resource for account B.
7. Storage reduction prunes only exact server-validated clean windows after
   seven days for high-rate raw streams or 30 days for essential time series,
   and keeps summaries, user records, dirty windows, and unvalidated data.
8. Revoking a device stops its managed access without deleting its local data
   or the account backup.
9. Account erasure requires recent authentication, honors cooling-off/cancel,
   and completes every documented data-class timeline.
10. A cloud outage leaves the app interactive and local collection durable.
11. A replacement phone signed into the same account proves possession and
    reconnects without changing ownership; a different account learns no owner
    identity and cannot claim the band.
12. Return, RMA, recovery, deletion, verified dispute, and eligible-upgrade
    release revoke owner credentials and wipe personal band state before any
    new account can claim it.
13. A new claim cannot proceed with missing or altered remote terms; the app
    stores no full terms copy, while the server can reproduce the exact accepted
    version and an already-activated band remains locally usable during a terms
    outage.
14. An eligible return follows the approved 14- or 30-day clock, receives a
    repeatable condition grade and itemized lawful refund decision, permits an
    appeal, and finishes with operator-only wipe, unlink, and quarantine.
10. Several simultaneous wellness candidates result in one explainable action,
    while a separate explicit SOS remains unsuppressed.

Passing builds and unit tests are necessary evidence, but physical behavior,
scale, privacy, metric accuracy, and production readiness remain separate gates.
