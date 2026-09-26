# Round: 2026-09-25 - Android Live source controls

## Status

- State: `implementation committed locally; evidence push and protected integration pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `fe616b5dc7a7ea51f345e5c940af38cab3612477`
- End implementation commit:
  `12e7819c968eea5006e18f4d000874dac6b4673b`
- Record commit or PR: application pull request `#17`

## Objective

Close the unresolved Android review finding where the Live screen selected
supplier versus WHOOP controls from transient supplier adapter display state.
An active supplier registry row must continue to show only supplier controls
when encrypted credential access temporarily fails and the supplier display
resets to `IDLE`; ordinary WHOOP Scan & Connect must neither render nor call
`AppViewModel.connect()` under that durable supplier identity.

## Scope

### In scope

- Android active-source presentation projection.
- Android Live control routing.
- Focused plain-JVM regression tests.

### Non-goals

- Apple runtime changes.
- Supplier lifecycle, registry mutation, credential retry, or transport changes.
- Gradle/build wiring, supplier artifacts, deployment, or physical-device work.
- Commit or push.

## Starting evidence

- Reproduction or observed symptom: `LiveScreen` selected the supplier screen
  only while `VeepooDisplayState.adapterState` was neither `IDLE` nor
  `STOPPED`. The existing temporary credential-read path resets that display
  while retaining the durable supplier row for retry.
- Relevant source/device/OS/firmware class: Android Compose source and
  plain-JVM policy tests; no phone or band was used.
- Existing tests, logs, exports, screenshots, or documents: the active PR `#17`
  remediation record documents the retry and durable-source behavior, while
  `SupplierDisplayHeartRatePolicyTest` already owns supplier Live presentation
  policy.
- Unknowns that must remain unknown until measured: physical supplier
  credential-store behavior, BLE reconnect timing, background behavior,
  battery accuracy, and physiological accuracy.

## Delivered

- Added an `AppViewModel` projection of the durable active registry row's
  `SourceKind`. A failed registry refresh retains the last confirmed
  projection instead of temporarily substituting another source.
- Changed `LiveScreen` to route through a four-state durable source policy:
  unresolved or malformed ownership shows a neutral waiting surface, `veepoo`
  shows only the supplier Live surface, a confirmed non-supplier kind enables
  the existing standard controls, and a successful read with no active device
  preserves the ordinary connection path.
- The supplier route returns before the WHOOP permission/connect callback is
  created, so an `IDLE` supplier display cannot render or invoke ordinary
  `AppViewModel.connect()`.
- Added focused Android regressions for supplier `IDLE`, transient supplier
  display under a WHOOP row, unresolved durable source, confirmed no-active
  behavior, and source-before-connect routing.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none; supplier heart rate remains
  display-only.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: no new health claim; source and
  JVM evidence do not validate physical measurements.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  `band.supplier_lifecycle` secure-read/recovery categories and
  `device_registry.resolve` outcomes cover the underlying boundaries.
- Why existing evidence is sufficient, or why new evidence is required: this
  change only selects presentation from already durable state; it adds no new
  transport, persistence, or long-running operation.
- Existing evidence reused: supplier secure-read/recovery diagnostics and
  registry resolution diagnostics.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: unchanged; no identifiers,
  credentials, health values, or payloads are added.
- Cross-platform/backend correlation: Android-only review correction.
- Remaining blind spots: physical encrypted-store and supplier transport
  behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Bounded Full debug compile plus focused JVM test | Exit 0; `BUILD SUCCESSFUL in 30s`; 30 tasks, 8 executed and 22 up-to-date | Production/test Kotlin compile and the focused policy suite runs | Physical-device behavior |
| `SupplierDisplayHeartRatePolicyTest` XML | 10 tests, 0 skipped, 0 failures, 0 errors | Supplier `IDLE`, WHOOP isolation, unresolved-source fail-closed behavior, confirmed no-active routing, freshness, battery, and source-before-connect contracts | Compose rendering on a phone |
| Android supplier artifact verifier | 7 exact AARs verified during the Gradle run | The configured Full supplier build inputs still match the reviewed manifest | Supplier redistribution rights or runtime behavior |
| `git diff --check` | Pass | Changed text has no whitespace errors | Kotlin behavior beyond executed tests |

### Verification command

```text
python3 Tools/run-bounded-command.py \
  --timeout-seconds 1200 \
  --grace-seconds 30 \
  --heartbeat-seconds 20 \
  --min-free-disk-gib 12 \
  --disk-path . \
  --label android-live-source-controls-exact-final \
  --log-file /tmp/noop-android-live-source-controls-exact-final.log \
  --status-file /tmp/noop-android-live-source-controls-exact-final.status \
  -- env ANDROID_HOME="$HOME/Library/Android/sdk" \
    ./android/gradlew -p android --no-daemon --no-configuration-cache \
    --max-workers=1 \
    :app:compileFullDebugKotlin \
    :app:testFullDebugUnitTest \
    --tests com.noop.ui.SupplierDisplayHeartRatePolicyTest
```

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: local JVM/Android build host only.
- Data-preservation result: no schema or stored-data change.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical supplier and WHOOP behavior.

## Git and release state

- Changed paths:
  - `android/app/src/main/java/com/noop/ui/AppViewModel.kt`
  - `android/app/src/main/java/com/noop/ui/LiveScreen.kt`
  - `android/app/src/test/java/com/noop/ui/SupplierDisplayHeartRatePolicyTest.kt`
  - this operations record
  - `docs/ops/rounds/INDEX.md`
  - `docs/ops/ACTIVE.md`
- Commits: implementation
  `12e7819c968eea5006e18f4d000874dac6b4673b`.
- Branch and remote state: the implementation commit is local; evidence/docs
  remain pending in the working tree and no replacement push has occurred.
- Repository visibility verified: unchanged and not rechecked.
- Version/build impact: none.
- Release or distribution impact: none until normal protected integration.

## Decisions

- Durable decision added or changed: none; this enforces the existing durable
  source-ownership contract.
- Decision-log entry: none.

## Open risks and honest limitations

- The focused JVM suite and Full debug compilation pass, but no emulator,
  instrumentation, full Android wall, or physical-device run was requested.
- The corresponding Apple reconnect correction is recorded and verified in its
  own September 25 round.

## Next round

1. Review and integrate this uncommitted Android-only correction through the
   existing PR `#17` protected process.
2. Retain physical encrypted-store and supplier reconnect validation as a
   separate signed-device gate.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
