# Round: 2026-09-24 - SDK 33 repin and supplier integration

## Status

- State: `implementation and serial verification in progress`
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `5978bda7760d6f8378d0c5439ab1788f8e0aa24e`
- Application pull request: `#17`
- Supplier binaries: local and ignored only; absent from Git
- Physical-device claims: unchanged and unproven

## Objective

Consume the reviewed `NoopBandSDK` PR `#33` merge, close the remaining
application review contradictions, integrate optional/default-off Apple and
Android supplier-band adapters, and preserve WHOOP as an independent default
test transport until physical supplier validation passes.

## Current implementation

- SDK PR `#33` merged normally at
  `b02808372b7c537f22058c7ebc75d92c750373be`.
- Two clean source exports are byte-identical. The ten-file manifest SHA-256 is
  `6beca829f3b2a367cf7046544e8d06dc74ae9f905e1eefe4bb58ccf41615fd34`.
- The app-owned Swift/Kotlin boundaries and adversarial verifier are pinned to
  that exact revision and manifest.
- D-061 supersedes D-012: Today shows selected three-to-five metrics while the
  explicit all-history/Explore action keeps the full catalog reachable.
- Isolated Apple and Android supplier-integration commits are ready for review.
  They are optional/default-off, retain explicit candidate selection and
  printed-ID verification, read battery before live HR, and keep
  phone-receipt-time supplier HR display-only.

## Observability

The neutral SDK uses fixed bounded lifecycle diagnostics. Supplier adapters
must record only fixed lifecycle/outcome/failure categories through the app
diagnostics recorder. Device addresses, printed IDs, passwords, names, RSSI,
raw errors, frames, timestamps, HR values, and persistent identifiers remain
excluded. High-rate HR never emits per-sample diagnostics.

## Verification

- Upstream SDK exact merge: Swift 106/106; Kotlin/JVM 114/114 plus
  `installDist`; conformance 50/50; repository gate 74 files.
- Dual source export: byte-identical.
- Application artifact verifier: direct verification passed; all 9 adversarial
  tamper, symlink, gitlink, and supplier-binary cases passed.
- Vendored Swift SDK package: 16/16 passed against the exact repin.
- Platform app boundary builds/tests: pending combined candidate.
- Apple supplier default-off builds/tests: pending parent-controlled serial
  Xcode verification.
- Android supplier source/wiring builds/tests: pending parent-controlled serial
  Gradle verification.
- Simulator visual/accessibility review: pending after compilation.

## External gates

Supplier redistribution rights, complete dependency notices/SBOM, signing,
store review, firmware, physical discovery, printed-ID truth, possession proof,
password behavior, battery accuracy, live HR accuracy, disconnect/reconnect,
background execution, on-band retention, haptics, OTA, egress, and battery-life
evidence remain open.
