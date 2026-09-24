# Round: 2026-09-24 - Veepoo iOS app integration

## Status

- State: `completed`
- Owner: project team
- Branch: `codex/veepoo-ios-app-20260924`
- Start commit: `5978bda7760d6f8378d0c5439ab1788f8e0aa24e`
- End implementation commit: local commit containing this record
- Record commit or PR: local only; no push authorized

## Objective

Integrate the optional owner-supplied Veepoo iPhoneOS SDK into the Apple app
without changing the existing WHOOP default path. The slice must remain
default-off and iPhone-only, require explicit discovered-candidate selection
and printed-identifier confirmation before accepting the supplier password,
serialize battery verification before live heart rate, expose only those two
physically unproven capabilities, and keep live receipt timestamps out of
durable health history and formulas.

## Scope

### In scope

- Cherry-pick the reviewed local-only SDK wiring commit.
- Port and harden the app-owned adapter core and device-only framework client.
- Add the source factory, reconnect credential handling, pairing UI, registry
  routing, fixed-category diagnostics, and deterministic tests.
- Run lightweight source-contract tests and the local artifact verifier through
  the bounded runner.
- Record the exact deferred Apple compile and XCTest commands for the parent.

### Non-goals

- Vendor binaries, transitive supplier dependencies, credentials, firmware, or
  private demo source in Git.
- Durable supplier HR history, analytics/formula input, history offload,
  ownership claim, OTA, haptics, or medical features.
- WHOOP transport changes.
- Physical-device, background, battery-life, accuracy, signing, distribution,
  or production claims.

## Starting evidence

- Reproduction or observed symptom: the app has a supplier-neutral default-off
  factory seam but no concrete Veepoo iOS source or pairing flow.
- Relevant source/device/OS/firmware class: owner-supplied arm64 iPhoneOS
  `VeepooBleSDK.framework` 2.2.XX.15; exact production band model and firmware
  remain unverified.
- Existing tests, logs, exports, screenshots, or documents: D-055/D-056,
  `docs/NOOP_BAND_SUPPLIER_SDK_ASSESSMENT.md`, the local SDK verifier, the
  source-only sidecar adapter, and the existing source-coordinator regressions.
- Unknowns that must remain unknown until measured: printed-label semantics,
  callback ordering on hardware, correct supplier password, transitive runtime
  dependencies, device confirmation behavior, background reconnect, battery
  interpretation, sensor accuracy, and runtime egress.

## Delivered

- Cherry-picked `2a2aec4bb96685f676f395039c9e485cdd0d63e2` as
  `51042f943`, adding default-off, iPhoneOS-only local framework wiring and its
  verifier.
- Added an app-owned adapter state machine and quarantined framework client.
  The supplier import exists in one file behind
  `os(iOS) && NOOP_SUPPLIER_VEEPOO && canImport(VeepooBleSDK)`.
- Added explicit candidate selection and exact normalized printed-identifier
  confirmation before the four-digit transport password is accepted. The UI
  never echoes scanned names, identifiers, addresses, or RSSI.
- Serialized password verification, battery read, and live-HR start. Only a
  validated battery response advances the adapter to the live-HR-capable
  state.
- Added device-only Keychain storage after battery and live-HR proof, bounded
  reconnect attempts, credential-rejection cleanup, and explicit disconnect
  teardown.
- Routed only `.veepoo` rows through the optional source factory. An unavailable
  supplier source fails before pausing WHOOP; all existing source kinds retain
  their prior factories.
- Added a separate display-only HR lane in `LiveState`. Supplier receipt times
  drive freshness presentation without advancing the accepted HR sequence or
  publisher used by smoothing, workouts, history, and health formulas.
- Added the pairing wizard flow and a supplier-specific device profile that
  claims only battery and current live-HR display, with no HRV, Effort,
  Recovery, Sleep, history, ownership, or medical claim.
- Added deterministic adapter/source tests and source-contract tests for
  compile gates, pairing order, battery ordering, redaction, reconnect
  lifecycle, WHOOP preservation, capability claims, and display-only HR.

## Data, privacy, and medical truth

- Schema or migration impact: none planned; `SourceKind` remains free-text.
- Existing-data retention impact: none.
- Source/provenance or formula impact: supplier live HR is display-only and
  receipt-timestamped; it must not be inserted into the health store or used as
  durable formula input.
- Permissions/network disclosure impact: no new permission; supplier runtime
  egress remains unverified.
- Health/medical claim impact and limitations: only battery and live HR are
  exposed, with no medical or accuracy claim.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: fixed adapter
  stage, outcome, failure-kind, and bounded count-bucket events.
- Why existing evidence is sufficient, or why new evidence is required: the
  supplier path needs a distinct categorical lifecycle while reusing the
  existing local `AppDiagnosticsRecorder`.
- Existing evidence reused: `AppDiagnosticsRecorder`.
- New bounded events or operation spans: `band.supplier_adapter`.
- Redaction, retention, and high-frequency controls: no printed identifiers,
  peripheral identifiers, addresses, names, RSSI, passwords, raw errors,
  timestamps, battery values, or heart-rate values; live samples are counted
  only and stale-callback reports are deduplicated per stage.
- Cross-platform/backend correlation: none; this slice is iPhone-only and
  local.
- Remaining blind spots: all physical framework and band behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-base and clean-worktree preflight | Pass | Requested branch started at the exact base | Implementation correctness |
| Context snapshot and current operations review | Pass | Current repository contracts were loaded | Product behavior |
| `python3 Tools/run-bounded-command.py ... -- python3 -m unittest Tools.tests.test_veepoo_ios_sdk_wiring Tools.tests.test_veepoo_ios_app_slice` | Pass, 17 tests in 0.021s | Default-off wiring and app source contracts | Swift type checking or runtime behavior |
| `python3 Tools/run-bounded-command.py ... -- xcrun swiftc -frontend -parse ...` for all changed Swift paths | Pass | Changed Swift files are syntactically valid | Cross-module type checking or linking |
| `python3 Tools/run-bounded-command.py ... -- python3 Tools/local/configure-veepoo-ios-sdk.py` | Pass: iPhoneOS arm64 and SHA-256 matched | The one approved local framework artifact matches its verifier contract | Transitive dependencies or runtime behavior |
| `git diff --check` | Pass | No whitespace errors in the implementation patch | Compile or runtime behavior |
| `python3 Tools/run-bounded-command.py ... -- python3 Tools/validate-ops-rounds.py --all .` | Expected fail: missing `rounds/INDEX.md` link | The new round itself is discoverable by the validator | Repository-wide ops validation until the parent adds the intentionally deferred shared index entry |
| Heavy Apple verification | Not run by resource-coordination instruction | No Xcode, simulator, DerivedData-heavy, or full-wall command was started | Apple type checking, linking, tests, simulator, signing, or device behavior |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no schema or durable health-history mutation; the
  supplier HR lane does not emit accepted health samples
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: scan, explicit selection, printed-ID match, connection,
  band-side confirmation, password rejection/retry, battery ordering, live HR,
  disconnect/reconnect, background execution, battery life, egress, and
  physiological accuracy

## Git and release state

- Changed paths: `.gitignore`, `Config/NOOPiOS.xcconfig`,
  `Config/VeepooLocalSDK.example.xcconfig`, `project.yml`, `docs/IOS.md`,
  `docs/IOS_RESTRICTED_VEEPOO_SDK.md`, local SDK verifier/tests,
  `PairedDevice.swift`, `AppModel.swift`, `LiveState.swift`,
  `SourceCoordinator.swift`, the three Veepoo BLE files, pairing/device/live
  UI, live-HR presentation, focused Swift/Python tests, and this round.
- Commits: `51042f943` plus the local implementation commit containing this
  record
- Branch and remote state: local branch; not pushed
- Repository visibility verified: unchanged
- Version/build impact: no version change
- Release or distribution impact: none; adapter remains default-off

## Decisions

- Durable decision added or changed: none; D-055/D-056 remain authoritative.
- Decision-log entry: none

## Open risks and honest limitations

- Free disk is about 18 GiB and swap is about 21.7/22 GiB. Per the resource
  coordinator, this round must not start Xcode, simulator, DerivedData-heavy, or
  full-wall commands.
- The vendor framework's transitive dependencies are not approved or present in
  the repository, so a vendor-enabled iPhoneOS link remains gated.
- Repository-wide ops validation remains gated only by the deliberately
  untouched `docs/ops/rounds/INDEX.md`; `docs/ops/ACTIVE.md` is also left for
  the parent integration owner.

## Next round

1. Add this round to `docs/ops/rounds/INDEX.md` and update
   `docs/ops/ACTIVE.md` with the implementation commit and deferred gates.
2. Run, sequentially, the bounded `xcodegen`, focused macOS XCTest,
   default-off macOS build, and default-off iOS Simulator build commands from
   the handoff.
3. Obtain an approved, pinned, hashed restricted intake for FMDB, MJExtension,
   ABParTool, JL, ZipZap, and any other link-discovered dependencies before
   attempting the vendor-enabled generic-iPhoneOS build.
4. Exercise scan, explicit selection, printed-ID confirmation, password
   rejection/retry, battery-before-HR ordering, live display freshness,
   disconnect/reconnect, background behavior, and egress on a physical iPhone
   and supplier band.

### Deferred serial verification commands

Run these only after resource coordination permits Xcode work:

```bash
python3 Tools/run-bounded-command.py --timeout-seconds 180 --grace-seconds 15 --heartbeat-seconds 30 --min-free-disk-gib 10 --disk-path . --label veepoo-xcodegen --status-file /tmp/noop-veepoo-xcodegen.status --log-file /tmp/noop-veepoo-xcodegen.log -- xcodegen generate
python3 Tools/run-bounded-command.py --timeout-seconds 1200 --grace-seconds 30 --heartbeat-seconds 30 --min-free-disk-gib 10 --disk-path . --label veepoo-focused-macos-tests --status-file /tmp/noop-veepoo-focused-macos-tests.status --log-file /tmp/noop-veepoo-focused-macos-tests.log -- xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/noop-veepoo-dd-macos-tests CODE_SIGNING_ALLOWED=NO -only-testing:StrandTests/VeepooBandAdapterCoreTests -only-testing:StrandTests/NoopBandSDKIntegrationTests test
python3 Tools/run-bounded-command.py --timeout-seconds 1200 --grace-seconds 30 --heartbeat-seconds 30 --min-free-disk-gib 10 --disk-path . --label veepoo-default-off-macos-build --status-file /tmp/noop-veepoo-default-off-macos-build.status --log-file /tmp/noop-veepoo-default-off-macos-build.log -- xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/noop-veepoo-dd-macos-build CODE_SIGNING_ALLOWED=NO build
python3 Tools/run-bounded-command.py --timeout-seconds 1200 --grace-seconds 30 --heartbeat-seconds 30 --min-free-disk-gib 10 --disk-path . --label veepoo-default-off-ios-simulator-build --status-file /tmp/noop-veepoo-default-off-ios-simulator-build.status --log-file /tmp/noop-veepoo-default-off-ios-simulator-build.log -- xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/noop-veepoo-dd-ios-simulator CODE_SIGNING_ALLOWED=NO build
```

After the full transitive restricted intake is approved and wired, enable the
local SDK and run the device compile:

```bash
python3 Tools/local/configure-veepoo-ios-sdk.py --write-config
python3 Tools/run-bounded-command.py --timeout-seconds 1200 --grace-seconds 30 --heartbeat-seconds 30 --min-free-disk-gib 10 --disk-path . --label veepoo-vendor-iphoneos-build --status-file /tmp/noop-veepoo-vendor-iphoneos-build.status --log-file /tmp/noop-veepoo-vendor-iphoneos-build.log -- xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/noop-veepoo-dd-iphoneos CODE_SIGNING_ALLOWED=NO build
```

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
