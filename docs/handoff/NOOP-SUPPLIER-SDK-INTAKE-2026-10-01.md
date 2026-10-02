# Owner-supplied supplier SDK intake — 2026-10-01

This supersedes the earlier “supplier archives absent” preparation finding.
The owner supplied both ZIPs and asked for the needed files to be retained in
this repo. The original archives, their checksum receipt and a private working
location note are preserved locally under `LocalSupplierSDK/2026-10-01/` in the
original checkout. This directory is Git-ignored; the public source keeps the
integration code, exact artifact manifests and this handoff. Working SDK copies
are extracted outside the repository because the existing verifiers require it.
The original downloads are retained too.

## Exact intake

| Input | SHA-256 | Adaptation |
|---|---|---|
| `iOS_Ble_SDK-master.zip` | `ee6ac93669c3db8c47397b004b8d3c6d444aee5ba80aac1551661c1e068374f4` | Changed primary iPhoneOS arm64 SDK; companion hashes and Pod sources unchanged |
| `Android_Ble_SDK-master.zip` | `a721c63f77731a8e142107fb4a538bc19aa024ce99aeca253be5c06f29beccc6` | Protocol AAR advances from 2.3.81.15 to 2.3.86.15; other six AAR hashes unchanged |
| iOS primary `VeepooBleSDK` | `ef553626d64ee625d9eb3121445d0c8a60f7958cdf721f7da5ecebca77d4d7b0` | Exact framework inventory repinned in candidate manifest |
| Android `vpprotocol-2.3.86.15.aar` | `f383e81e5314d4d4d97b1a0ebe59e5bc9d76b0968ba73deec517641be52211d3` | Existing required classes and native ABI constraints preserved |

Archive extraction checks paths, symlinks, file count and total expansion size.
No vendor demo application, firmware or flasher is executed or installed.
Only the app's existing native adapter and required dependency set are built.
The package-level Apache license text is present; this intake does not by itself
approve redistribution of every bundled artifact or qualify a physical model.

## Verification and concrete changes

- Android: all seven exact AARs pass the existing verifier, including required
  classes and ABI inventories. SDK-enabled Full Debug APK builds, and focused
  supplier tests pass **52/52** including the real supplier source-set bridge
  tests. The installed default-off APK was updated in place after comparing
  signing certificates; version remains **9.2.1-debug / 304**. Updated APK
  SHA-256: `042a8b5ffb9dbec62c459a8c888d8813e4f55dc23dbb6ed12b323dbe5a1e75bd`.
- SDK-enabled dependency resolution exposed two unrecorded Jackson 2.13.5 parent
  POM checksums. Both cached files matched the canonical Maven Central mirror
  bytes over HTTPS; only those two checksum entries were added. Strict Gradle
  verification and version locks remain enabled.
- iOS: the protected Podfile, lock and complete Pods tree match. FMDB and
  MJExtension build successfully from those inputs; both generated framework
  inventories and binaries match across two fresh builds on this Mac. Candidate
  generated pins record these outputs. This is local reproduction evidence;
  cross-machine reproducibility is not asserted.
- The exact new nine-framework iOS bundle verifies and writes the ignored local
  SDK config. The complete supplier-enabled unsigned iPhoneOS graph builds with
  `NOOP_SUPPLIER_VEEPOO` active. The complete manually signed development graph
  also passes after device registration and required profile provisioning.
  iOS **9.2.1 / 231** is freshly installed on the **13 Pro Max / iOS 27.0.1**;
  post-install inventory confirms it. Launch is blocked by the locked phone.
  The 17 Pro Max existing-app inventory remains unavailable; no install there.
- Native client source signatures and the common SDK-client interfaces needed
  no changes for this supplied revision. No formulas, schema, provenance,
  calibration, account or ownership policy changed. The compatibility manifest
  remains unchanged with zero approved model/firmware rows.

The Tools wall initially exposed a stale brand-mapping count fixture (15 versus
the unchanged generator’s 14 keys). It now asserts the exact full mapping key
set and retains all locale completeness checks; the focused suite passes 3/3.

The repository Tools suite passes 372 cases with one skip. The documentation-only
terminology snapshot update changes historical counts; the active allowlist is
unchanged. The corresponding required-control source digest is updated after
classification review. Privacy, operations and local release-control checks pass.
Hosted review and protected-main integration are still pending.

## What NoopSDK means

`Vendor/NoopBandSDK` is the binary-free common contract and state machinery.
`Strand/BLE/VeepooBandAdapter.swift` and Android's `src/veepoo/.../vendor/` bridge
adapt supplier-native APIs into that contract and the app's source interfaces.
The owner-supplied frameworks/AARs implement actual Bluetooth transport beneath
those adapters. The app needs both layers for supplier operation.

A future supplier SDK replacement should change its exact input manifests and,
where API signatures or behavior changed, these native adapters. Persisted
samples and common analytics stay source-qualified and versioned. Run artifact,
wrapper-boundary, native adapter and enabled-build gates again. Do not make
shared formulas accept opaque vendor scores or manufacture absent signals merely
because a new SDK exposes more methods.

## Physical continuation

The owner requests **NOOP band first on Android**. Android has the supplied SDK
included and an initial installation/launch check. No live sensor, history,
reconnect, background or accuracy pass is recorded here. Follow the
[connected session](../ops/rounds/2026-10-01-connected-band-test-attempt.md) for
current signing/install evidence. Both installed phones currently require owner
unlock and ordinary first-run completion.
Approved account/provider configuration and exact band model/firmware must still
be established before customer supplier activation and collection. Complete the
ordinary Terms and onboarding path; preserve existing history and keep each
band assigned to one collector.

The source candidate and changed trust roots are for owner/primary-agent review
on `codex/physical-band-review-20261001` (draft PR 28), not a claim of protected
main integration, release readiness or physical sensor parity.
