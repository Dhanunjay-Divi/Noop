# Round: 2026-09-14 - Android Review Sample terms gate

## Status

- State: `implementation, exact-current local Android verification, and
  repository policy gates complete; replacement exact-SHA hosted checks,
  protected integration, repository privacy restoration, and round-owned
  cleanup pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `e0297be1896a87493c2b3ce4ad1482801078f3f4`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#15`

## Objective

Keep the disclosed Android Review Sample and every other pre-Terms state free
from operational WorkManager initialization when Android delivers a date,
clock, timezone, or time-tick broadcast. Preserve the existing fail-closed
authorization boundary, add bounded diagnostic evidence, prove the exact
hosted failure locally, and replace the failed hosted check on one reviewed
commit.

## Scope

### In scope

- Android daily-review worker and time-change receiver authorization ordering.
- A source-order contract that keeps the authorization check before reminder
  input, preference, health, scheduling, or WorkManager access.
- Exact API 35 Review Sample reproduction and the complete affected Android
  verification wall.
- Durable operations records, repository policy gates, hosted checks, protected
  integration, privacy restoration, and owned-resource cleanup.

### Non-goals

- Starting operational scheduling before current Terms are accepted.
- Enabling notifications, health-data access, managed sync, public traffic, or
  real participant data.
- Claiming physical-device background delivery from a managed emulator.
- Changing reminder timing, content, consent, or quiet-hour policy.

## Starting evidence

- Hosted run `34833623470`, job `103942482997`, failed
  `ReviewSampleInstrumentedTest.reviewSampleIsVisibleNavigableAndExitableWithoutHardware`
  because WorkManager was initialized before Terms acceptance.
- The same test failed deterministically on the local API 35 managed device.
- A process-local initialization trace identified this call path:
  `NoopApplication.getWorkManagerConfiguration` ->
  `WorkManagerImpl.getInstance` -> `WorkManager.getInstance` ->
  `DailyReviewReminders.cancel` -> `DailyReviewReminders.reconcile` ->
  `DailyReviewTimeChangeReceiver.onReceive`.
- At failure, Terms were not accepted, both cleanup flags were false, daily
  guidance and calendar guidance were disabled, and the operational runtime had
  not started. This excluded the normal launch and cleanup paths.
- The preceding committed revision's Review Sample check was green, confirming
  the failure was introduced by the split daily-review reconciliation path.

## Delivered

### Pre-Terms operational gate

- `DailyReviewTimeChangeReceiver` now verifies
  `ManagedRuntimeGate.isAuthorized` immediately after recognizing a supported
  system action and before reading reminder state or invoking reconciliation.
- `DailyReviewReminderWorker` applies the same gate before reading work input
  or touching reminder, preference, health, or notification state.
- Rejected pre-Terms entry points return successfully without repairing or
  scheduling operational work. This avoids retry churn while preserving the
  requirement that later authorized reconciliation owns operational setup.

### Regression contract

- The Android JVM test reads the production source and proves the worker gate
  precedes work input and the receiver gate precedes reminder restoration.
- The exact Review Sample managed-device test requires a fresh WorkManager and
  proves navigation remains usable without hardware while WorkManager remains
  uninitialized.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none. The change prevents
  unauthorized operational access; it does not infer or alter a health signal.

## Observability

- Evidence that diagnoses rejection is the bounded local event
  `daily_review.operational_gate`.
- The event contains only fixed categorical fields:
  `entrypoint=worker|time_change_receiver` and `outcome=blocked`.
- No health value, reminder content, identity, device identifier, system action,
  timestamp payload, preference value, URL, credential, or exception text is
  recorded.
- The event is emitted only when a system/worker entry point is rejected and is
  not a high-frequency sensor or rendering event.
- Existing Android application diagnostics remain local and user-reviewed.
- Remaining blind spots are OEM broadcast timing, physical-device process
  suspension, and real notification delivery.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Hosted run `34833623470`, job `103942482997` | Failed on the prior remote head | The Review Sample exposed a real pre-Terms WorkManager initialization regression | The local correction |
| `./gradlew testFullDebugUnitTest --tests com.noop.notif.DailyReviewReminderPolicyTest --no-daemon --no-configuration-cache --stacktrace` | Passed in 24 seconds | The authorization-order and bounded-event source contracts pass | Android framework behavior |
| Focused API 35 `ReviewSampleInstrumentedTest` with `requireFreshWorkManager=true` | One passed in 42 seconds | The disclosed Review Sample is navigable and leaves WorkManager uninitialized on a fresh managed runtime | Physical OEM behavior |
| Complete Full and Demo Android unit/build/lint/source wall | Each variant: 4,767 cases, 4,760 passed, seven intentional skips, zero failures/errors; 137 Gradle tasks passed in 3 minutes 53 seconds | Both product variants compile and the complete JVM contract remains green | Physical BLE, background, notification, battery, or haptic behavior |
| API 35 production shell excluding the separately proven Review Sample class | 108 completed, two intentional private-pilot skips, zero failures in 49 seconds | The remaining Room, WorkManager, notification, managed-data, and app-shell instrumentation contracts remain green | Representative physical devices or public services |
| Exact-current repository policy wall | 68 operations records, 17,644 classified terminology occurrences with zero forbidden mappings, 1,252-file health-claims scan, 12-metric calibration parity, 230-component legal inventory, distribution provenance, private-data, required-CI, 230 repository tests, 49 i18n tests, bounded added-line secret scan, and diff checks passed | The correction and durable record preserve repository safety, privacy, release, and evidence contracts | Hosted exact-SHA checks or external approvals |
| Replacement exact-SHA hosted matrix | Pending after the bounded commit | Will prove the committed correction under branch protection | Hardware, external approval, or production operation |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local JVM and Android API 35 managed device
- Data-preservation result: no participant or production data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical Android process/background broadcasts,
  notification delivery, BLE, haptics, battery, and accessibility

## Git and release state

- Changed paths: Android daily-review production source, its JVM regression
  test, and operations records.
- Commits: the bounded corrective commit containing this record is the current
  local branch head.
- Branch and remote state: pull request `#15`; remote head `e0297be1` retains
  the failed Review Sample check and does not contain the local correction.
- Repository visibility verified: public during protected checks; restore to
  private immediately after protected integration.
- Version/build impact: no marketing-version or build-number change.
- Release or distribution impact: no deployment or distribution.

## Decisions

- System broadcasts and already-enqueued workers are operational entry points
  and must independently enforce the current Terms/runtime gate.
- A rejected pre-Terms operational entry point completes without retry and
  records only a bounded categorical local event.
- No durable product decision changed; no decision-log entry is required.

## Open risks and honest limitations

- Replacement hosted checks have not yet run on the corrective commit.
- A managed API 35 device does not validate OEM-specific process management,
  physical notification delivery, or elapsed background reliability.
- Supplier hardware, physical-device, legal, carrier, signing, store,
  participant, licensing, public-runtime, and elapsed-operation gates remain
  external.

## Next round

1. Push the reviewed bounded correction once.
2. Wait for every required hosted check on the replacement SHA and resolve only
   review threads proven by that exact source.
3. Integrate through protected `main`, immediately restore repository privacy,
   synchronize canonical `main`, and remove only round-owned resources.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
