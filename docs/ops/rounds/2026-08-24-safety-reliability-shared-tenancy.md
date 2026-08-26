# Round: 2026-08-24 - Safety reliability and shared tenancy

## Status

- State: `completed in code; external launch gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `b11c7c2e`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commits requested by the owner

## Objective

Finish the interrupted Safety and notification work without converting wellness
signals into medical paging, make paging behavior observable and fail-closed,
add an enforceable shared-server authorization boundary, complete credential
and data lifecycle controls, and state exactly what remains before a
10,000-user production launch.

## Scope

### In scope

- Apple and Android Safety delivery state, recovery actions, notification
  lifecycle diagnostics, relaunch reconciliation, localization, and malformed
  response handling.
- Durable paging invitations, leases, retries, receipts, worker health,
  sender-rate coordination, kill switch, and restore contracts.
- Shared per-installation credentials, device ownership, tenant isolation,
  rotation, export, erasure, and adversarial API tests.
- Safety-token rotation, profile export/deletion, bounded retention, replay
  tombstones, production configuration, capacity tooling, and operations docs.

### Non-goals

- Automatic medical, anomaly, fall, ECG, AFib, or emergency-services paging.
- Claiming that a provider receipt proves a person saw or accepted a page.
- Selecting or provisioning cloud, identity, recovery, carrier, monitoring,
  signing, or store accounts.
- Physical-device, real-carrier, participant-accuracy, or clinical evidence.
- Changing NOOP's license, owner declaration, or exact dependency inventory.

## Starting evidence

- The previous audit found stable notification identifiers, authorization
  checks, and a durable paging pipeline, but it had not exercised a real
  carrier.
- A follow-up concurrency review found provider-outcome, finalization,
  submission-control, deletion, tenancy, and client lifecycle risks that
  required code changes and regression tests.
- The repository already contained local Apple, Android, and server test
  coverage plus a fail-closed distribution gate.
- Carrier delivery, managed-cloud failover, 10,000-user capacity, physical
  device behavior, signing, and store behavior remain unknown until measured.

## Delivered

- Apple and Android now distinguish contacts targeted, reached, pending, and
  explicitly failed. All-contact terminal failure offers a direct local
  emergency call path and does not relabel an unknown provider outcome.
- Safety screens reconcile active incident state after relaunch and reject
  malformed/impossible contact summaries instead of presenting false status.
- Phone validation is strict ASCII E.164 on both platforms.
- Notification producers retain stable identifiers and authorization checks.
  Bounded local ledgers record only lifecycle state and time for diagnostics;
  they do not claim an unobserved banner, vibration, or human receipt.
- Paging invitations and incident deliveries are durable jobs with leases,
  immutable attempts, bounded retries, provider receipts, SMS-first voice
  fallback, DTMF acknowledgement, signed responder links, cancellation,
  expiry, and terminal explicit-failure handling.
- Paging starts fail-closed behind a revisioned, audited database control.
  Workers heartbeat, coordinate sender throughput through PostgreSQL, drain a
  bounded wave on shutdown, and expose privacy-safe operations state.
- `NOOP_AUTH_MODE=shared` keeps the operator token administrative. Versioned
  `noop_install_...` credentials own exclusive native device namespaces, and
  foreign reads/exports/deletes return `404`.
- Installation credentials support retry-safe rotation, self export/revocation,
  and hard deletion. Installation deletion covers owned biometric rows,
  Friends data, Safety data, and credential/device-ownership rows.
- Safety credentials support retry-safe versioned rotation. Profile export
  includes contacts, incident/location state, and delivery history without
  credential or invitation hashes. Confirmed profile deletion hard-deletes the
  Safety graph.
- Retention deletes only terminal incidents and pending-expired, declined, or
  revoked contacts. A short data-minimal tombstone prevents an old
  `Idempotency-Key` from creating a second page after incident retirement.
- Restore smoke now requires tenancy and lifecycle migrations/tables and checks
  ownership, queue, attempt, and replay-tombstone relationships.
- The capacity harness now emits valid native device namespaces, accepts a
  private shared-credential file, and has a fail-closed provisioning helper for
  disposable load targets.

## Data, privacy, and medical truth

- Schema impact: migrations `008` through `012` add paging controls/reliability,
  installation tenancy, Safety credential lifecycle, retention indexes,
  data-minimal replay tombstones, and post-cutover ownership triggers.
- Existing biometric values and app-local history are not rewritten by these
  migrations.
- Secrets remain digests in PostgreSQL. Plaintext replacement credentials are
  generated and retained by the client.
- Shared-mode operator authorization cannot read or write biometric routes.
- Delivery status never means a human saw the message. Automatic wellness or
  rhythm signals cannot enter the paging API.
- Fall Response remains visibly inert until a separately validated
  activity-scoped detector and cancellation flow exist.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Server full suite | 129 passed; 9 database and 1 live-Twilio test skip without their environments | API, paging, tenancy, retention, restore, and policy contracts pass | Carrier delivery or production capacity |
| PostgreSQL runtime integration | 9/9 passed on isolated PostgreSQL 14 after removing only unavailable Timescale hooks from a disposable migration copy | Real SQL locks, FKs, rotation, isolation, lifecycle, retention, and resolve/cancel execute | Timescale extension or managed failover |
| Restore application smoke | SQL smoke passed against the isolated database; 12 migration checksums verified | Migrations `010/011/012`, ownership, queue, attempt, and tombstone relations are usable | Recovery time from a real encrypted archive |
| Ruff | Check and format gates passed | Python source is lint/format clean | Runtime topology |
| NoopRemoteSync | 42/42 passed | Apple Safety response decoding and malformed-summary guards pass | Network/carrier behavior |
| macOS app suite | 1,428 passed, 1 intentional skip | Full Apple app graph and localization contracts pass | iPhone/BLE/background behavior |
| iOS simulator build | Passed unsigned; current UI action host-blocked before test launch by Xcode debugger-store failure | Current iOS source/resources compile | A fresh UI result, signing, archive, or physical phone behavior |
| Android Full Debug | 3,646 tests, 0 failures, 6 skips; APK, androidTest sources, and lint pass | Full Android logic/resources compile and unit contracts pass | Physical OEM behavior or Play release |
| Localization | Strict gate passed; Safety source has 211 keys with nine-locale parity | No new baseline debt and generated Apple/Android Safety parity | Native-speaker approval |
| Tool/policy suite | 62/62 passed; private-data, ops, legal inventory, and claims gates pass | Repository policy contracts remain intact | Signing, store, carrier, or physical-device readiness |
| Distribution gate | Current gate passes under the 2026-08-25 NOOP owner declaration | The NOOP license, owner record, and dependency notices are coherent | Current signing, store, carrier, or physical-device readiness |

The host had no Docker daemon, TimescaleDB extension, `k6`, Twilio staging
credentials, usable cloud session, signing identity, or Android release
keystore. The PostgreSQL test intentionally removed only the unavailable
Timescale extension/hypertable conversion in a disposable copy; repository
migration checksums remained unchanged and were verified separately. This is
useful SQL evidence, not a substitute for the pinned Timescale container or
managed staging topology.

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: simulator and host builds only; no physical
  phone, watch, band, or Android OEM was exercised in this round.
- Data-preservation result: no physical-device data store was modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: overnight sync, reconnect, background termination,
  haptics, tap SOS, alarms, HealthKit/Health Connect, Watch handoff, OEM battery
  policies, and upgrade retention.

## Git and release state

- Changed paths: Apple/Android notification and Safety clients, server paging,
  tenancy, migrations, backup/load tooling, tests, and operations records.
- Commits: client `82dcc042`; server `29efcfc6`; operations record in the
  commit containing this file.
- Branch and remote state: local `main` started at `b11c7c2e`; final push and
  remote-branch cleanup follow the validated record commit.
- Repository visibility verified: private and standalone (`isFork=false`, no
  parent).
- Version/build impact: no marketing version or build-number change.
- Release or distribution impact: no artifact was uploaded or published.

## Decisions

- D-020: shared biometric routes require an installation credential; the
  operator credential is administrative.
- D-021: provider and human delivery states remain distinct; only manual SOS
  enters paging.
- D-022: Safety retention is terminal/inactive-only and preserves a bounded
  replay guard.

## Open risks and honest limitations

- The current NOOP owner declaration governs source rights without changing
  this round's carrier or infrastructure limitations.
- No real Twilio page, carrier receipt, provider outage, or human response has
  been observed.
- A shared authorization boundary is not consumer signup, identity proof,
  recovery, abuse handling, support access, or an independently tested
  multi-tenant service.
- The private GitHub repository currently has no Actions secrets or deployment
  environments. Hosted jobs are stopped by the account Actions budget, and the
  current account tier does not provide protected branches/rulesets for this
  private repository.
- The Mac has no valid code-signing identity. Store signing, upgrade continuity,
  review, and rollout evidence are absent.
- A standard signed App Store/Play build cannot safely distribute APNs/FCM
  provider credentials to user-operated servers. Cloud-grade push requires an
  explicit local-only or privacy-minimized relay decision.

## Next round

1. Preserve the cleared owner-rights record; restore hosted CI and
   protected-main controls.
2. Procure Twilio senders, complete A2P/country registration, and run the
   controlled carrier matrix with median/p95 delivery evidence.
3. Select identity/recovery, cloud/regions, RPO/RTO, monitoring/on-call, push
   posture, and budget.
4. Deploy the production-like topology and run 10,000-enrollment, burst, soak,
   mixed-workload, tenant-adversarial, restart, failover, and encrypted-restore
   evidence.
5. Complete representative physical-device, accuracy, signing, store, privacy,
   and regional legal/safety evidence.

## Privacy check

- [x] No credentials, phone numbers, provider SIDs, raw biometric exports,
      personal device identifiers, signing identities, or absolute personal
      paths are present in this record.
