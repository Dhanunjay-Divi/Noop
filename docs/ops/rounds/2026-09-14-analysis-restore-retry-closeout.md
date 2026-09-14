# Round: 2026-09-14 - Analysis scheduling and restore retry closeout

## Status

- State: `implementation and complete local verification finished; final
  commit, exact-SHA hosted checks, protected integration, repository privacy
  restoration, and round-owned cleanup pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `703727e6087ab8b1384d1cfab50cf4e28f18b430`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#15`

## Objective

Close the final three independent review findings without weakening health-data
retention or reminder intent:

- Apple must defer score-bearing claims that cannot advance beyond the current
  local-day coverage cutoff.
- Apple must process actionable recent claims before a long historical backlog.
- Android must not withhold an accepted restored database because optional
  daily-review WorkManager reconciliation is temporarily unavailable.

## Scope

### In scope

- Apple analysis-window selection and durable claim-finalization ordering.
- Android restored daily-review schedule reconciliation and durable retry.
- Focused cross-platform regressions, complete affected walls, operations
  evidence, hosted exact-SHA verification, and protected integration.

### Non-goals

- Metric, sleep-stage, Recovery, Effort, or notification-content changes.
- Claiming physical background delivery, BLE behavior, or sensor accuracy.
- Enabling public traffic, real paging, or participant health-data transfer.

## Starting evidence

- Apple's current-day analysis coverage ends at local 18:00. A non-forced
  claim ending later could trigger a full pass without becoming finalizable.
- Apple's planner selected historical catch-up whenever any old range existed,
  even when another source had actionable recent input.
- Android's first daily-review restore fix converted a WorkManager exception
  into a restore-finalization error after the accepted database had entered its
  irreversible `FINALIZING` phase.
- A fresh independent patch review additionally found that a selected Apple
  historical turn could keep winning after its fallible work failed, and that
  an older Android scheduler success could clear a newer failure marker unless
  the operation and marker write were one serialized transaction.

## Delivered

### Apple analysis scheduling

- Added explicit recent, historical, and deferred pass kinds.
- A non-forced pass with no finalizable claim at the current coverage edge
  returns after the bounded generation snapshot instead of rescanning history.
- Claims whose newest edge is inside current coverage run before historical
  backlog; cutoff-straddling or wholly late claims remain pending.
- Historical work still runs when every other range is beyond the cutoff.
- Selecting one due historical turn consumes that preference before fallible
  read or persistence work. A failed archive attempt therefore yields the next
  ordinary turn to fresh data; later recent progress can arm another bounded
  historical turn.
- Forced formula or repair work may complete once without falsely
  acknowledging unsupported late input; the next ordinary pass defers.
- Diagnostics use fixed `deferred` and `coverage_cutoff` categories only.

### Android restore scheduling

- Hydration and daily-review restore reconciliation share one bounded durable
  retry contract.
- A scheduler failure records a fixed component/outcome and synchronously
  commits a component-specific retry marker before restore completion.
- The accepted database remains available; process maintenance retries only a
  marked daily-review failure after Room is ready.
- Ordinary startup keeps `ExistingWorkPolicy.KEEP`; the after-database path
  does not issue an unmarked `REPLACE`.
- A successful retry clears the marker durably. Failure to persist retry state
  remains a restore-finalization error because no durable recovery contract
  would otherwise exist.
- Scheduler execution and its component marker update share one serialized
  transaction, so an older success cannot erase a newer restore failure.

## Data, privacy, and medical truth

- Schema or migration impact: no health database schema change; one private
  Android restore-maintenance boolean key.
- Existing-data retention impact: analysis claims remain pending until their
  exact affected range is covered; accepted restored databases are not hidden
  by repairable scheduler failures.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none.

## Observability

- Apple records only fixed pass outcome, mode, and reason categories.
- Android records only fixed restore component and outcome categories.
- No device identifier, timestamp, preference value, sensor value, health
  record, work identifier, or exception message is added.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Apple `ReadSpineActiveDeviceTests` | 30 passed, zero failed/skipped | Late-only deferral, next-day eligibility, forced-pass non-acknowledgement, recent priority, bounded historical fairness after success or failure, historical fallback, and cutoff-straddling behavior | Physical iOS scheduling or battery impact |
| Android `BackupSettingsCodecTest` and `DailyReviewReminderPolicyTest` | Full and Demo each passed 44 cases, zero failed/skipped | Durable retry, accepted-database availability, serialized marker recovery, normal startup `KEEP`, and immediate restore `REPLACE` contracts | OEM WorkManager behavior |
| Complete Apple and Android product walls | macOS executed 2,015 tests with 2,014 passes, one external-fixture skip, and zero failures; the 39-case iPhone UI suite passed with 38 passes and one private-pilot skip; Android Full and Demo each executed 4,775 tests with 4,768 passes, seven skips, and zero failures/errors, and both APK, lint, and instrumentation-source walls passed across 124 Gradle tasks | Broad source and target integration on the final local source | Physical hardware, signing, background delivery, BLE, haptics, or sensor accuracy |
| Server, Swift packages, and repository policy wall | Server passed 597 tests with one provider/environment skip; nine packages passed 2,961 of 2,971 tests with ten fixture skips and the two harnesses passed 14 more; 230 tool tests, 49 i18n tests, 12 OpenTofu tests, localization, privacy, health-claims, calibration, terminology, legal/distribution, release-control, required-CI, operations, secret, shell, workflow, JSON, and diff gates passed | Backend, package, infrastructure, policy, privacy, localization, claims, release, and operations consistency | Hosted checks, production operation, or external approvals |
| Hosted exact-SHA matrix | Pending | Protected verification of the committed revision | Physical hardware or production operation |

## Physical device and deployment

- Install/update action: not run
- Data-preservation result: no participant or production data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: representative iPhone and Android process lifetime,
  notification delivery, WorkManager repair, BLE, haptics, and battery

## Git and release state

- Changed paths: Apple analysis planner and tests; Android restore-maintenance,
  application startup, and tests; operations records.
- Branch and remote state: pull request `#15`; local changes are not yet
  committed or pushed.
- Repository visibility: public during protected checks; restore to private
  immediately after protected integration.
- Version/build impact: none.
- Release or distribution impact: no deployment or distribution.

## Decisions

- A pass is actionable only when the durable ledger can acknowledge or advance
  at least one claim under that pass's actual coverage.
- A selected historical turn is consumed before fallible work so failure cannot
  starve current evidence.
- Repairable OS scheduling is process maintenance, not a prerequisite for
  opening an already accepted restored health database.
- Daily-review recovery uses `REPLACE` only for an actual restore or a durable
  retry marker; ordinary startup retains `KEEP`.

## Open risks and honest limitations

- Hosted exact-SHA verification, protected integration, privacy restoration,
  and cleanup remain.
- Physical-device, supplier, legal, carrier, signing, store, participant,
  licensing, public-runtime, and elapsed-operation gates remain external.

## Next round

1. Stage and inspect every intended path, create one bounded commit, and push
   once.
2. Resolve only review threads proven by the committed exact SHA and green
   protected checks.
3. Integrate through protection, immediately restore privacy, synchronize
   canonical `main`, and remove only round-owned resources.

## Privacy check

- [x] No credentials, personal identifiers, health values, absolute owner
      paths, or private evidence are present.
