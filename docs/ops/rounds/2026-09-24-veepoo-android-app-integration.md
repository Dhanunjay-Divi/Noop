# Round: 2026-09-24 - Veepoo Android app integration

## Status

- State: `Android lifecycle consistency complete; focused JVM verification passed`
- Owner: project team
- Branch: `codex/veepoo-android-app-20260924`
- Start commit: `5978bda7760d6f8378d0c5439ab1788f8e0aa24e`
- End implementation commit: local commit containing this record; SHA reported in the final handoff
- Record commit or PR: local commit only; push is out of scope

### Android lifecycle consistency continuation

- Continuation branch: `codex/android-supplier-lifecycle-final-20260924`
- Continuation base: `9edf5ab0b5de122f0e9f6943369390dd70053f10`
- Authorized slice: atomic or compensated supplier adoption, active supplier
  removal teardown and credential cleanup, unavailable/rejected supplier
  fallback reconciliation, fixed-category lifecycle diagnostics, and focused
  deterministic JVM tests.
- Explicit exclusions: Apple source, `project.yml`, shared operations
  `ACTIVE.md`/`rounds/INDEX.md`, build wiring, supplier binaries, emulator,
  deployment, and physical-device execution.
- Continuation result:
  - supplier adoption now compensates secure persistence when the verified
    transactional registry mutation fails;
  - active supplier removal stops its source, clears its credential before the
    archive, atomically promotes a fallback source, and restores
    credential/source state if the archive fails;
  - missing provider/credential and rejected reconnect authentication reconcile
    the durable active row to the still-running or resumed fallback transport;
  - lifecycle diagnostics expose fixed stage/outcome/trigger/failure categories
    only; and
  - the worker's bounded focused FullDebug JVM suite passed 58 tests with no
    failures, and the receiving branch passed 59/59 after adding the active
    removal fallback regression.

## Objective

Implement the Android supplier-band adapter and app pairing/source integration
without changing existing WHOOP behavior or editing Gradle/build wiring files.

Success means:

- default source compiles without local supplier AARs through an internal
  reflection boundary;
- pairing requires explicit candidate selection and printed-ID verification;
- first pairing and reconnect remain distinct;
- only wrapper-proven battery and display-only live heart rate are exposed;
- supplier operations are serialized, generation-fenced, contained, and
  cleaned up on every terminal path;
- bounded diagnostics contain fixed categories only; and
- deterministic fake-based tests cover scan, select, authentication, connect,
  battery, live heart rate, disconnect, reconnect, and failure cleanup.

## Scope

### In scope

- Android app-owned supplier bridge, adapter, source factory, and credentials.
- Source-coordinator and pairing UI integration.
- Deterministic JVM and source-contract tests.
- A new round record and exact verification handoff.

### Non-goals

- Gradle, dependency, manifest, workflow, lockfile, or build-source-set edits.
- Supplier AAR/JAR/source inclusion.
- WHOOP transport changes.
- History, formulas, ownership proof, OTA, haptics, alarms, or medical claims.
- Push, deployment, emulator, or physical-device execution.
- Changes to `docs/ops/ACTIVE.md` or `docs/ops/rounds/INDEX.md`.

## Starting evidence

- Reproduction or observed symptom: the repository has a current
  supplier-neutral schema-v3 SDK and a default-null source-factory seam, but no
  Android supplier adapter or app pairing flow.
- Relevant source/device/OS/firmware class: Android app source and plain-JVM
  fakes; no supplier binary, signed app, phone, band, or firmware is available
  in this round.
- Existing tests, logs, exports, screenshots, or documents:
  - clean requested branch at the exact requested base;
  - current `NoopBandSDK` revision
    `50a16fbc75f9ae604e773ff6608c87f0b96b67f7`;
  - prior adapter worktree inspected read-only for safe ideas only;
  - prior review records uncontained supplier exceptions and terminal
    diagnostic-ordering defects.
- Unknowns that must remain unknown until measured: exact production model
  printed-ID mapping, callback timing, password lifecycle, physical
  confirmation behavior, BLE stability, battery accuracy, background behavior,
  firmware support, and physiological accuracy.
- Resource hold: free disk is approximately 18 GiB and swap is approximately
  21.7/22 GiB. No compile, assemble, lint, full Gradle wall, or emulator task
  may run in this worktree. Heavy verification will be handed to the
  parent-controlled sequential lane.

## Delivered

- Added an app-owned supplier bridge boundary with opaque attempt,
  authentication, candidate, target, and binding types.
- Added a reflected, default-off provider loader. Normal app source contains no
  supplier SDK imports and treats a missing build flag or provider as
  unavailable.
- Added a serialized supplier adapter over the current neutral SDK schema-v3
  session contract:
  - discovery never selects or connects a candidate;
  - the user must explicitly select one numbered opaque candidate;
  - first pairing waits for physical confirmation input, authenticates, and
    compares the supplier-reported device number with the printed ID;
  - reconnect uses the stored transport credential without presenting the
    first-pair confirmation flow;
  - an established drop uses `interruptForReconnect` and
    `resumeAfterReconnect`, rejecting changed binding, identity, or capability
    reports;
  - battery completes before continuous live HR starts; and
  - all supplier calls and terminal cleanup are exception-contained and
    callback-fenced.
- Added encrypted per-device four-digit transport-credential storage. The UI
  states explicitly that this password opens the transport and is not
  ownership proof.
- Added an atomic registry insert-and-activate operation with credential
  compensation if the registry write fails.
- Added source-coordinator, application, ViewModel, device-wizard, device-icon,
  and live-screen integration. WHOOP remains the default and the supplier type
  is hidden unless the optional provider loads.
- Kept supplier live HR in a dedicated display-only state. The neutral
  capability report contains only battery and HR capabilities, no live/history
  streams, and no stream semantics because the wrapper has no device timestamp.
  No supplier source references the repository, `StreamBatch`,
  `BandSample`, or `publishExternalLiveHr`.
- Added deterministic fake-based unit tests for explicit scan/select, first
  pairing confirmation, printed-ID rejection, authentication, direct
  reconnect, neutral reconnect after a durable drop, battery-before-HR,
  display-only/no-durable-sample behavior, explicit disconnect, credential
  handling, bounded diagnostics, and throwing cleanup.
- Completed Android supplier lifecycle consistency:
  - verified registry adoption is transactional and credential persistence is
    compensated on failure;
  - supplier removal performs source teardown and secure cleanup before archive
    with rollback compensation, and an active removal archives/promotes the
    fallback in one transaction before transport reconciliation;
  - source-unavailable and authentication-rejected paths durably restore the
    actual WHOOP or generic fallback source without changing WHOOP removal
    behavior; and
  - fixed-category lifecycle diagnostics cover adoption, reconciliation,
    secure cleanup, and removal without identifiers, raw errors, or health
    values.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: supplier credentials and registry state will
  be saved only after explicit candidate selection, printed-ID verification,
  and completed first-pair authentication.
- Source/provenance or formula impact: phone-receipt live heart rate is
  display-only and will not be persisted or supplied to formulas.
- Permissions/network disclosure impact: no permissions or network behavior
  added in this app-source round.
- Health/medical claim impact and limitations: no supplier measurement is
  validated by source compilation or JVM tests.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: fixed
  discovery, selection, printed-ID, connection, pairing, reconnect,
  capability, battery, live, disconnect, and cleanup categories.
- Why existing evidence is sufficient, or why new evidence is required:
  existing app diagnostics provide bounded local retention, but a new
  supplier-specific categorical event is required for this lifecycle.
- Existing evidence reused: `AppDiagnosticsRecorder` and neutral SDK
  diagnostics.
- New bounded events or operation spans: `band.supplier_lifecycle`, carrying
  only fixed `stage`, `outcome`, optional `trigger`, and optional
  `failure_kind` fields.
- Redaction, retention, and high-frequency controls: no names, addresses,
  printed IDs, RSSI, passwords, raw errors, timestamps, or health values; no
  per-sample diagnostic events.
- Cross-platform/backend correlation: Android-only supplier runtime; neutral
  SDK contract remains cross-platform.
- Remaining blind spots: all supplier binary and physical-device behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Initial worktree/base check | Clean branch at exact requested base | Work started from the authorized source | Runtime behavior |
| NOOP skill, project contracts, active handoff, supplier assessment, and wrapper handoff | Read | Implementation boundaries and open gates were reviewed | Supplier behavior |
| Prior adapter worktree | Inspected read-only; not cherry-picked | Safe ideas and prior defects were identified | Correctness of the new implementation |
| Bounded `git diff --check` | Pass | Edited text has no whitespace errors | Kotlin compilation or runtime behavior |
| Bounded exact-base ancestry check | Pass | Requested base remains an ancestor of the implementation | Absence of later source defects |
| Bounded forbidden-path diff check | Pass | Gradle, manifest, `docs/ops/ACTIVE.md`, and `docs/ops/rounds/INDEX.md` were not edited | Build success |
| Source-boundary audit | No repository, neutral-sample, or WHOOP live-publish calls under the supplier package | Phone-receipt HR has no app persistence/formula route in this implementation | Future provider correctness |
| Focused supplier lifecycle JVM suite | Worker pass: 58 tests, 0 failures/errors/skips; receiving-branch pass after review correction: 59/59, bounded command exit 0, `BUILD SUCCESSFUL in 33s` | FullDebug main/test Kotlin compilation and deterministic adoption, fallback reconciliation, authentication cleanup, atomic active-removal fallback, removal ordering/compensation, diagnostics, and ViewModel contract behavior | Optional provider binary compatibility or physical BLE behavior |
| Full/Demo Kotlin compile | FullDebug main/test Kotlin compiled as part of the focused suite; Demo and broader compile wall not run | The changed default FullDebug source and selected tests compile | Demo variant and unrelated modules |
| Final whitespace/path audit | Pass: `git diff --check`; only scoped Android source/tests and this existing round record changed | No whitespace defects or forbidden Apple/build/shared-ops/vendor path edits | Runtime behavior |

### Continuation verification command

```text
python3 Tools/run-bounded-command.py \
  --timeout-seconds 1200 \
  --grace-seconds 30 \
  --heartbeat-seconds 20 \
  --min-free-disk-gib 12 \
  --disk-path . \
  --label android-supplier-lifecycle-focused \
  --log-file /tmp/noop-android-supplier-lifecycle-focused.log \
  --status-file /tmp/noop-android-supplier-lifecycle-focused.status \
  -- env ANDROID_HOME="$HOME/Library/Android/sdk" \
    ./android/gradlew -p android --no-daemon --no-configuration-cache \
    :app:testFullDebugUnitTest \
    --tests com.noop.ble.SourceCoordinatorAdoptionTest \
    --tests com.noop.ble.veepoo.VeepooBandSourceTest \
    --tests com.noop.ble.veepoo.VeepooCredentialStoreTest \
    --tests com.noop.data.DeviceRegistryTest \
    --tests com.noop.ui.AnalysisInputGateContractTest
```

Test-result XML totals:

- `SourceCoordinatorAdoptionTest`: 16
- `VeepooBandSourceTest`: 12
- `VeepooCredentialStoreTest`: 4
- `DeviceRegistryTest`: 20
- `AnalysisInputGateContractTest`: 7

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: not run
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all supplier-band and Android physical-device gates

## Git and release state

- Changed paths:
  - `android/app/src/main/java/com/noop/NoopApplication.kt`
  - `android/app/src/main/java/com/noop/ble/SourceCoordinator.kt`
  - `android/app/src/main/java/com/noop/ble/veepoo/`
  - `android/app/src/main/java/com/noop/data/DeviceRegistry.kt`
  - `android/app/src/main/java/com/noop/data/PairedDevice.kt`
  - `android/app/src/main/java/com/noop/ui/AddDeviceWizard.kt`
  - `android/app/src/main/java/com/noop/ui/AppViewModel.kt`
  - `android/app/src/main/java/com/noop/ui/DevicesScreen.kt`
  - `android/app/src/main/java/com/noop/ui/LiveScreen.kt`
  - `android/app/src/test/java/com/noop/ble/veepoo/`
  - this round record
- Continuation lifecycle commit paths:
  - `android/app/src/main/java/com/noop/NoopApplication.kt`
  - `android/app/src/main/java/com/noop/ble/SourceCoordinator.kt`
  - `android/app/src/main/java/com/noop/ble/veepoo/VeepooBandSource.kt`
  - `android/app/src/main/java/com/noop/ble/veepoo/VeepooDiagnostics.kt`
  - `android/app/src/main/java/com/noop/data/DeviceRegistry.kt`
  - `android/app/src/main/java/com/noop/ui/AppViewModel.kt`
  - `android/app/src/test/java/com/noop/ble/SourceCoordinatorAdoptionTest.kt`
  - `android/app/src/test/java/com/noop/ble/veepoo/VeepooBandSourceTest.kt`
  - `android/app/src/test/java/com/noop/ble/veepoo/VeepooCredentialStoreTest.kt`
  - `android/app/src/test/java/com/noop/data/DeviceRegistryTest.kt`
  - `android/app/src/test/java/com/noop/ui/AnalysisInputGateContractTest.kt`
  - this round record
- Commits: local implementation commit containing this record
- Branch and remote state: local requested branch; no push
- Repository visibility verified: not reverified in this round
- Version/build impact: no version change
- Release or distribution impact: supplier factory remains default-off

## Decisions

- Durable decision added or changed: none
- Decision-log entry: none

## Open risks and honest limitations

- The focused FullDebug lifecycle suite passed. Demo compilation and a broader
  Gradle wall remain intentionally unrun.
- The separate build-wiring lane must provide
  `com.noop.ble.veepoo.vendor.VeepooBridgeProviderImpl` and the explicit
  `VEEPOO_ADAPTER_AVAILABLE` BuildConfig flag. This source branch deliberately
  does not provide or compile that vendor implementation.
- Reflection/provider compatibility and supplier behavior remain unproven
  until the exact reviewed AAR set is compiled and exercised on a physical
  device.

## Next round

1. Optional broader default-source verification, if the release lane requires
   it:

   ```text
   python3 Tools/run-bounded-command.py \
     --timeout-seconds 1200 \
     --grace-seconds 30 \
     --heartbeat-seconds 20 \
     --min-free-disk-gib 12 \
     --disk-path . \
     --label veepoo-full-demo-compile \
     -- env ANDROID_HOME="$HOME/Library/Android/sdk" \
       ./gradlew --no-daemon --no-configuration-cache \
       :app:compileFullDebugKotlin \
       :app:compileDemoDebugKotlin
   ```

2. After the separate wiring lane lands, compile the optional provider against
   the exact reviewed supplier binaries, then exercise scan, explicit candidate
   choice, band confirmation, printed-ID match/mismatch, app relaunch reconnect,
   unexpected drop reconnect, battery-before-HR, background/foreground, and
   teardown on a physical Android device.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
