# Round: 2026-09-24 - Veepoo Android app integration

## Status

- State: `implementation complete; heavy verification deferred by resource hold`
- Owner: project team
- Branch: `codex/veepoo-android-app-20260924`
- Start commit: `5978bda7760d6f8378d0c5439ab1788f8e0aa24e`
- End implementation commit: local commit containing this record; SHA reported in the final handoff
- Record commit or PR: local commit only; push is out of scope

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
- New bounded events or operation spans: pending.
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
| Focused supplier JVM tests | Added, not run under the resource hold | Deterministic coverage exists for the required lifecycle | Passing compilation/execution |
| Full/Demo Kotlin compile | Not run under the resource hold | Nothing | Android source/resource integration |

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
- Commits: local implementation commit containing this record
- Branch and remote state: local requested branch; no push
- Repository visibility verified: not reverified in this round
- Version/build impact: no version change
- Release or distribution impact: supplier factory remains default-off

## Decisions

- Durable decision added or changed: none
- Decision-log entry: none

## Open risks and honest limitations

- The resource hold defers every Android compile/build wall to the
  parent-controlled sequential lane.
- The separate build-wiring lane must provide
  `com.noop.ble.veepoo.vendor.VeepooBridgeProviderImpl` and the explicit
  `VEEPOO_ADAPTER_AVAILABLE` BuildConfig flag. This source branch deliberately
  does not provide or compile that vendor implementation.
- Reflection/provider compatibility and supplier behavior remain unproven
  until the exact reviewed AAR set is compiled and exercised on a physical
  device.

## Next round

1. Parent-controlled focused JVM verification:

   ```text
   python3 Tools/run-bounded-command.py \
     --timeout-seconds 1200 \
     --grace-seconds 30 \
     --heartbeat-seconds 20 \
     --min-free-disk-gib 12 \
     --disk-path . \
     --label veepoo-focused-jvm \
     -- env ANDROID_HOME="$HOME/Library/Android/sdk" \
       ./gradlew --no-daemon --no-configuration-cache \
       :app:testFullDebugUnitTest \
       --tests com.noop.ble.veepoo.VeepooBandSourceTest \
       --tests com.noop.ble.veepoo.VeepooCredentialStoreTest \
       --tests com.noop.ble.SourceCoordinatorAdoptionTest \
       --tests com.noop.data.DeviceRegistryTest
   ```

2. Parent-controlled default source compile:

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

3. After the separate wiring lane lands, compile the optional provider against
   the exact reviewed supplier binaries, then exercise scan, explicit candidate
   choice, band confirmation, printed-ID match/mismatch, app relaunch reconnect,
   unexpected drop reconnect, battery-before-HR, background/foreground, and
   teardown on a physical Android device.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
