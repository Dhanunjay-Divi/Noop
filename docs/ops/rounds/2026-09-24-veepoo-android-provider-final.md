# Round: 2026-09-24 - Veepoo Android provider final

## Status

- State: `implementation complete; focused supplier compile/tests passed`
- Owner: project team
- Branch: `codex/android-veepoo-provider-final-20260924`
- Start commit: `2b7422036cce2a8d5f85639e706fc43097512e45`
- End implementation commit: local commit containing this record; exact SHA in
  the completion handoff
- Record commit or PR: local commit only; push is out of scope

## Objective

Implement the optional Android supplier provider loaded as
`com.noop.ble.veepoo.vendor.VeepooBridgeProviderImpl`, while preserving the
ordinary WHOOP and Demo build graphs when local supplier configuration is
absent.

Success means:

- the provider is compiled only in the local supplier-enabled Full source set;
- the exact reviewed SDK API is used for explicit scan, selection, connection,
  four-digit password confirmation, battery, live heart rate, and teardown;
- durable connection status and every asynchronous callback are fenced by the
  active app attempt;
- supplier statuses and callback failures are reduced to fixed
  `VeepooFailure` values without sensitive logging;
- the supplier service and required external modules are present only in the
  supplier-enabled Full lane; and
- source tests cover lifecycle ordering, stale callbacks, fixed failure
  mapping, and clean teardown.

## Scope

### In scope

- `android/app/src/veepoo/`
- `android/app/src/veepooTest/`
- conditional supplier-only source-set, manifest, and dependency wiring in
  `android/app/build.gradle.kts`
- dependency lock and verification metadata only when required by the
  supplier-only external module graph
- this focused round record

### Non-goals

- Main app lifecycle, source coordination, registry, ViewModel, or pairing UI
  changes.
- Apple source changes.
- Supplier binaries, APKs, firmware, credentials, demo assets, documentation,
  or private filesystem paths in Git.
- WHOOP transport changes.
- Supplier history, OTA, ownership proof, formulas, or medical claims.
- Release packaging, deployment, emulator, or physical-device approval.
- Changes to `docs/ops/ACTIVE.md` or `docs/ops/rounds/INDEX.md`.

## Starting evidence

- Worktree is clean on the requested branch and exact start commit.
- The current app bridge requires opaque candidates, explicit selection,
  identity/capability return, battery before display-only live heart rate,
  durable drop reporting, and fixed failure values.
- The provider loader expects the exact class named in the objective and keeps
  it behind `VEEPOO_ADAPTER_AVAILABLE`.
- The local supplier verifier previously identified seven exact AAR inputs.
  They remain external and untracked.
- `javap` and supplier integration material were inspected locally before
  implementation. The relevant SDK surface includes:
  - `VPOperateManager.getInstance`, `init`, `setAutoConnectBTBySdk`,
    `startScanDevice`, `stopScanDevice`, `connectDevice`,
    `registerConnectStatusListener`, `unregisterConnectStatusListener`,
    `confirmDevicePwd`, `readBattery`, `startDetectHeart`,
    `stopDetectHeart`, `disconnectWatch`, and `release`;
  - search, connect, notify, durable connection, password, battery, and heart
    callbacks; and
  - the supplier `BluetoothService` declaration required by its integration
    guide.
- No lifecycle Gradle process was active when this round began. Every heavy
  command remains conditional on a fresh process check and will use the
  repository bounded-command runner.
- Unknowns that remain physical-device questions: exact model/firmware
  behavior, confirmation timing, scan filtering quality, reconnect stability,
  battery semantics, wear detection, background behavior, and measurement
  accuracy.

## Delivered

- Added the optional
  `com.noop.ble.veepoo.vendor.VeepooBridgeProviderImpl` and its supplier adapter
  under `src/veepoo`.
- Initialized the singleton manager with the application context, disabled SDK
  auto-connect and supplier logging, and implemented explicit scan/candidate
  selection without exposing device names, addresses, IDs, passwords, health
  values, or raw exceptions.
- Added attempt-token and operation-identity fences for scan, transport,
  password confirmation, battery, live heart rate, disconnect, and close.
- Registered a durable connection-status listener before transport connect,
  compared callback addresses case-insensitively, and unregistered the listener
  before disconnect/release.
- Required a four-ASCII-digit transport password and returned binding,
  supplier identity, and heart-rate capability only after all authentication
  callbacks completed.
- Enforced a successful battery read before live heart rate. A valid battery
  percentage is retained when the supplier also marks it low. Heart busy,
  detecting, not-worn, and low-battery measurement states remain pending and
  do not terminate the supplier session.
- Added focused source tests for explicit selection, transport gating,
  authentication completion, stale callback fences, teardown ordering,
  fixed failure mapping, battery-before-heart ordering, low-battery retention,
  transient heart states, and case-insensitive durable-status addresses.
- Added supplier-only source/test source sets, manifest wiring, exact external
  dependency declarations, a separate supplier dependency lock, and dependency
  verification hashes. The ordinary app lockfile remains unchanged.

## Exact supplier API mapping

- Lifecycle/configuration:
  `VPOperateManager.getInstance()`, `init(Context)`,
  `setAutoConnectBTBySdk(false)`, `setDeviceShowConfirm(boolean)`,
  `setPwdCheckTimeoutListener(...)`, `removePwdCheckTimeoutListener()`,
  `removeConnectionConfirmationTask()`, `disconnectWatch(IBleWriteResponse)`,
  and `release()`.
- Discovery/transport:
  `startScanDevice(int, SearchResponse)`, `stopScanDevice()`,
  `isVPDevice(byte[])`,
  `connectDevice(String, IConnectResponse, INotifyResponse)`,
  `registerConnectStatusListener(String, IABleConnectStatusListener)`, and
  `unregisterConnectStatusListener(String, IABleConnectStatusListener)`.
- Authentication/identity/capability:
  the seven-argument `confirmDevicePwd(...)` overload with
  `IPwdDataListener`, `IDeviceFuctionDataListener`,
  `ISocialMsgDataListener`, and `ICustomSettingDataListener`;
  `PwdData.deviceNumber`, `deviceTestVersion`, and `deviceVersion`; and
  `getFunctionCheck().checkRate()`.
- Measurements:
  `readBattery(IBleWriteResponse, IBatteryDataListener)`,
  `startDetectHeart(IBleWriteResponse, IHeartDataListener)`, and
  `stopDetectHeart(IBleWriteResponse)`.
- Supplier diagnostics disabled:
  `BluetoothLog.setDebug(false)`, `VPLogger.setDebug(false)`,
  `VPLocalLogger.stopMonitor()`, and
  `VPOperateManager.setShowFunctionNotSupportToast(false)`.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: supplier live heart rate remains
  phone-receipt display data and is not promoted to durable samples.
- Permissions/network disclosure impact: no permission was added. The
  supplier-only manifest declares the required non-exported service, forces
  `allowBackup=false`, and removes legacy external-storage permissions
  contributed by supplier manifests.
- Health/medical claim impact and limitations: compilation and source tests do
  not validate physiological accuracy, wear detection, battery accuracy, or
  safety behavior.

## Observability

- The provider does not emit names, addresses, IDs, passwords, supplier raw
  errors, or health values to logs.
- Public outcomes are limited to existing typed callbacks and fixed
  `VeepooFailure` categories.
- High-frequency heart callbacks have no diagnostic event or logging path.
- Remaining blind spots require an instrumented internal build and a physical
  band.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Initial branch/base/status check | Pass | Authorized clean starting state | Runtime behavior |
| Project contracts and current bridge/factory source | Read | Scope and app-facing lifecycle contract | Supplier implementation correctness |
| Local AAR API inspection with `javap` | Complete for required surface | Exact class, callback, and method signatures were identified | Device callback order or firmware behavior |
| Exact local AAR verifier | Pass: seven configured AARs | Local supplier inputs matched the reviewed metadata before compilation | Redistribution rights or runtime behavior |
| Bounded supplier compile/test | Pass: exit `0`, `BUILD SUCCESSFUL in 2m 13s` | Supplier-enabled Full Kotlin and unit-test sources compile against the exact local SDK/dependency graph | Release assembly, emulator, or physical BLE behavior |
| `VeepooVendorBridgeTest` XML | Pass: `7/7`, zero skipped/failures/errors | Focused lifecycle, mapping, stale-callback, and teardown behavior passes | Firmware callback order or physiological accuracy |
| Merged Full debug manifest review | Pass | Supplier service is enabled/non-exported; legacy storage permissions are absent; backup remains disabled | Installed-device component behavior |
| Ordinary app lock comparison | Pass: byte-identical to start commit | Supplier lock selection did not rewrite the default WHOOP/Demo lock | Every possible default build task |
| `git diff --check` and owned-path privacy review | Pass | No whitespace errors, private supplier path, local config, or binary was included in the owned change set | Third-party legal approval |

The final focused command was:

```text
python3 Tools/run-bounded-command.py \
  --timeout-seconds 1200 --grace-seconds 30 --heartbeat-seconds 20 \
  --min-free-disk-gib 12 --disk-path . \
  --label veepoo-provider-final-focused \
  --log-file /tmp/noop-veepoo-provider-final-focused.log \
  --status-file /tmp/noop-veepoo-provider-final-focused.status \
  -- env ANDROID_HOME="$HOME/Library/Android/sdk" \
  ./android/gradlew -p android --no-daemon --no-configuration-cache \
  :app:compileFullDebugKotlin :app:testFullDebugUnitTest \
  --tests com.noop.ble.veepoo.vendor.VeepooVendorBridgeTest
```

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: not run
- BLE/background/battery/wear scenarios exercised: not run
- Unrun hardware gates: all supplier-band and Android physical-device gates

## Git and release state

- Changed paths:
  - `android/app/build.gradle.kts`
  - `android/app/noop-supplier-sdk.lockfile`
  - `android/gradle/verification-metadata.xml`
  - `android/app/src/veepoo/AndroidManifest.xml`
  - `android/app/src/veepoo/java/com/noop/ble/veepoo/vendor/VeepooBridgeProviderImpl.kt`
  - `android/app/src/veepoo/java/com/noop/ble/veepoo/vendor/VeepooVendorBridge.kt`
  - `android/app/src/veepooTest/java/com/noop/ble/veepoo/vendor/VeepooVendorBridgeTest.kt`
  - this round record
- Commits: one local implementation commit containing the paths above; exact
  SHA in the completion handoff
- Branch and remote state: local requested branch; no push
- Repository visibility verified: inherited; not reverified in this round
- Version/build impact: no version change
- Release or distribution impact: supplier-enabled Full release packaging
  remains blocked

## Decisions

- Durable decision added or changed: none
- Decision-log entry: none

## Open risks and honest limitations

- Focused supplier-enabled compilation and source tests pass. Broader
  supplier-enabled assemble, lint, release, emulator, and instrumentation
  tasks were not run.
- No physical band was used. Scan filtering, confirmation timing, identity,
  battery semantics, live heart callbacks, drop/reconnect handling,
  background behavior, model/firmware compatibility, and physiological
  accuracy remain unverified.
- The exact supplier-documented external graph is locked and checksum
  verified, but licensing, notices/SBOM, vulnerability review, support policy,
  and redistribution approval remain external gates.
- The Nordic transitive graph compiles with the reviewed SDK. Physical runtime
  compatibility remains a device gate.
- Existing unrelated Kotlin/Gradle deprecation warnings remain; the bounded
  run reported no provider compilation error.

## Next round

- Exercise scan, explicit selection, four-digit confirmation, identity,
  battery, live heart rate, transport drop, reconnect, stop, and close on a
  supported physical band/Android matrix.
- Complete supplier and external-module legal, security, notice/SBOM,
  vulnerability, support, and redistribution review before release use.
- The parent operations owner may link this round from shared `ACTIVE.md` or
  `INDEX.md`; those shared files were intentionally not edited here.

## Privacy check

- [x] No credentials, personal names, device identifiers, signing identities,
      supplier binaries, or absolute private supplier paths are present.
