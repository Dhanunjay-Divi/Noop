# Round: 2026-10-01 — Connected-phone band test attempt

## Status

- State: `SDK integration and device installs verified; physical collection blocked`
- Owner: recovery agent
- Branch: `codex/physical-band-review-20261001`
- Start commit: `22876c30f3f45194b384472dd1501fc00cf81fac`
- End implementation commit: SDK intake follow-up to the start commit; recorded in PR 28
- Record commit or PR: draft PR 28 follow-up

## Objective

The owner connected iOS and Android phones and authorized installation and
physical band testing. Verify actual device readiness, install compatible exact
candidates while preserving existing data, and measure WHOOP then supplier
behavior only where configuration and exact hardware gates permit.

## Scope

### In scope

- Owner-provided SDK archive intake, exact version/pin adaptation and native
  SDK-enabled build verification; local copies preserved with checksum receipts.
- Read-only phone/app inventory, exact artifact verification, signed-build
  retry, fresh Android install and ordinary first-run UI checks.
- Physical BLE scenarios only after platform/source prerequisites pass.

### Non-goals

- Firmware changes, guessed supplier package, account bypass, uninstall/reset,
  release, remote merge, or exposing private identifiers and health values.

## Starting evidence

- Main remains `08ad0f472a577e66fd612281550f549fa09c7703`; review PR 28 remains
  open/unmerged at the start commit, with retained Android Full Debug APK.
- iPhone 13 Pro Max / iOS 27.0.1: Developer Mode enabled, wired, paired,
  developer services available; successful app inventory contains no NOOP.
- iPhone 17 Pro Max / iOS 27.0: Developer Mode enabled, network transport;
  app inventory fails, so installed state is unknown.
- Physical Android SM-F731U1 / Android 16 / API 36, arm64-v8a: owner accepted
  USB debugging, authorized; package inventory contains no NOOP apps.
- Account/supplier configuration remains absent. Expected supplier root absent;
  scoped filename discovery in owner file locations found no supplier package.
  Neutral SDK is present and does not contain supplier transport binaries.
- Exact band model/firmware and phone-to-band assignment remain unknown.

## Delivered

- Sanitized read-only device/app preflight.
- Fresh Android Full Debug 9.2.1-debug / 304 installed and launched successfully;
  observed normal Terms screen. No existing NOOP package was overwritten.
- Exact wired 13 Pro Max signed-build retry fails with exit 65: same required
  capability/profile mismatch. No valid local development profile covers all
  required capabilities; no iPhone installation performed.
- Owner then supplied the actual iOS and Android SDK ZIPs and requested keeping
  needed inputs in the repo. Originals preserved in ignored `LocalSupplierSDK/`
  with receipts; safe extracted working copies outside Git satisfy existing
  verifier layout. Existing downloads and source trees preserved.
- Candidate supplier trust pins updated only for the changed iOS primary library
  inventory and Android protocol 2.3.86.15, using exact owner-supplied files. All
  companion framework/AAR hashes and required class constraints remain intact.
  Public source contains hashes/configuration recipes; private binaries remain
  local. Release/Archive, ownership, exact-model and missing-input gates unchanged.
  Android verifier passes all seven AARs; enabled Full Debug build and 52 supplier
  tests pass. All nine iOS frameworks verify; the enabled unsigned and signed
  app/Watch/widget graphs build. Physical transport is not claimed.
- Strict Gradle verification required two Jackson parent-POM checksum entries;
  cached inputs matched canonical Maven Central mirror bytes before adding them.
- FMDB and MJExtension generated framework inventories match across two fresh
  local builds from unchanged protected Pod inputs. Their candidate pins record
  these exact outputs; cross-machine reproducibility is not asserted.
- A pre-existing localization test hardcoded 15 brand mapping entries while the
  unchanged generator has 14. The test now verifies the full mapping key set;
  all locale completeness checks remain. The focused three-case suite passes.
- Android updated in place to the SDK-enabled 9.2.1-debug / 304 APK after matching
  signing certificates. Install and launch succeed; the current UI is locked.
  APK SHA-256: `042a8b5ffb9dbec62c459a8c888d8813e4f55dc23dbb6ed12b323dbe5a1e75bd`.
- Authorized Apple developer session resolved missing device registration and
  required capabilities. Four device-specific development profiles are local.
  The complete manually signed SDK-enabled iOS 9.2.1 / 231 graph passes. Fresh
  app inventory again showed no NOOP; installation on the 13 Pro Max succeeds,
  post-install inventory confirms the app. Launch is blocked by device lock.
  No installation is attempted on the 17 Pro Max with unknown existing state.

- Repository Tools suite passes 372 cases with one skip after the stale fixture
  correction and reviewed historical-only terminology snapshot/digest update.
  The active terminology allowlist is unchanged. Operations/privacy/diff and
  local release-control checks pass; these are not hosted required-check results.

## Data, privacy, and medical truth

- Schema or migration impact: none intended.
- Existing-data retention impact: fresh installs where no app existed; Android
  subsequently updated in place with the same certificate. No uninstall/reset.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: USB trust and Apple developer sign-in
  completed by owner; existing app-required signing capabilities provisioned.
  No health upload, Terms acceptance or account creation by this agent.
- Health/medical claim impact and limitations: no band measurement yet.

## Observability

- Evidence: private device inventory and bounded build/install status, ordinary
  first-run UI state, and existing in-app categorical diagnostics.
- Existing evidence reused: reviewed artifact/build logs and retained APK hash.
- New bounded events or operation spans: none; device operations only.
- Redaction/retention: device identifiers, raw command output and UI captures
  stay in private round-owned evidence outside Git.
- Cross-platform/backend correlation: no live provider or BLE evidence yet.
- Remaining blind spots: all band scenarios and unavailable external inputs.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Connected Android metadata and package inventory | Pass; physical, authorized, no NOOP packages | Device available for fresh install | Band or account readiness |
| iPhone 13 app inventory | Pass; no NOOP app | Trusted device inventory available | Signing/profile pass |
| iPhone 17 app inventory | Fail | Installed state remains unknown | No app is installed |
| Owner-supplied native SDK verification and enabled builds | Pass on both platforms | Native transport libraries compile through existing adapters | Band compatibility, sensor behavior or backend readiness |
| Signed iPhone graph and install | Pass on 13 Pro Max | Valid development profile and installable artifact | Unlocked launch or band collection |
| Android enabled APK and supplier tests | Pass; installed in place, 52/52 cases | Exact inputs, adapter compile and mocked callback behavior | Real sensors, history or background behavior |
| Account/provider configuration and exact band approval | Missing | Local customer activation prerequisites remain absent | That an SDK cannot connect compatible hardware |

## Physical device and deployment

- Install/update action: Android fresh install then same-signature in-place SDK
  update; 13 Pro Max fresh signed SDK-enabled installation.
- Generalized device and OS class: iPhone 13 Pro Max / 27.0.1; iPhone 17 Pro Max /
  27.0; Android SM-F731U1 / 16, API 36.
- Data-preservation result: no existing app before fresh installations; Android
  update retains app data. No reset, uninstall or identity change.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical band scenarios.

## Git and release state

- Changed paths: supplier artifact manifests, iOS exact pin/helper fixture,
  Gradle checksum metadata, local SDK ignore, stale localization fixture and
  operations/review handoffs. Native app contracts and formulas unchanged.
- Commits: supplier-intake follow-up recorded on the review branch.
- Branch and remote state: review branch; draft PR 28, no merge.
- Repository visibility verified: prior verified public source, unchanged.
- Version/build impact: retained Android 9.2.1-debug / 304; iOS 9.2.1 / 231.
- Release or distribution impact: local device development only; no store release.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: not needed.

## Open risks and honest limitations

- Supplied native SDKs and 13 Pro Max signing are resolved. Exact model/firmware
  approval, account/provider configuration and owner-completed unlocked setup
  remain gates. No band connection, live health, history, reconnect, background,
  battery endurance, sensor parity or derived-metric accuracy pass is claimed.

## Next round

1. Owner unlocks both installed phones, opens NOOP and completes Terms personally.
2. Obtain approved local account/provider configuration and exact NOOP model and
   firmware qualification; do not fabricate ownership or compatibility rows.
3. Start with NOOP on Android as requested, then compare WHOOP on a separate
   collector. Record the physical matrix and qualified/missing metric inputs.
4. Obtain an unlocked, readable 17 Pro Max inventory before any update there.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
