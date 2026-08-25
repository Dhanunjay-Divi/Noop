# Round 20 - Customer-facing brand boundary

**Date:** 2026-08-25  
**Status:** implementation and local verification complete; physical-device and
distribution gates remain

## Product contract

- Normal customer UI uses NOOP, Noop Band, compatible band, wearable import, or
  provider wording according to context.
- The retired transport-vendor name must not render in app screens,
  notifications, accessibility text, diagnostics, release notes, Coach
  context, or customer exports.
- Internal BLE symbols, GATT-family names, database paths, persisted IDs,
  importer formats, and test fixtures remain stable for compatibility.
- Required legal provenance remains truthful and available. It must not be
  removed to create the appearance of independent source rights.
- NOOP Band remains in development; neutral product wording does not claim that
  first-party hardware is available.

## Implementation map

- `Strand/System/CustomerFacingBrand.swift` and
  `android/app/src/main/java/com/noop/brand/CustomerFacingBrand.kt` scrub
  runtime-generated customer text.
- `Tools/i18n_audit.py` rejects the retired term in rendered Apple catalog
  values, Android resource values, and hardcoded UI text.
- Apple and Android UI/resource changes cover onboarding, Sleep, scoring,
  Today, Coach, diagnostics, exports, release notes, source labels, and terms.
- `Tools/AppWideLocalization/appwide_strings.json` remains the source for the
  affected generated app-wide localization.
- The complete evidence and limitations are recorded in
  `docs/ops/rounds/2026-08-25-customer-facing-brand-boundary.md`.

## Do not weaken

- Do not rename persisted identifiers or protocol symbols as a visual cleanup.
- Do not expose raw runtime logs or imported source strings without the
  customer-facing scrubber.
- Do not permit a legacy catalog source key to render by removing its explicit
  neutral English localization.
- Do not remove legal provenance or claim that hosting independence resolves
  source rights.
- Do not represent currently compatible third-party hardware as an available
  first-party NOOP Band product.

## Verification

- Strict rendered-text/localization audit: passed with no customer-facing
  retired term.
- Audit suite: 42 passed.
- Focused Apple brand/source/export tests: 27 passed.
- Rendered iPhone UI: 2 passed for terms and band onboarding.
- StrandAnalytics: 1,367 passed, 7 intentional skips.
- StrandDesign: 44 passed.
- Complete macOS app suite: passed.
- Android Full Debug: 3,653 passed, 6 skipped; APK assembled.
- Unsigned iOS Simulator build: passed.
- Generator parity, ops validation, and whitespace checks: passed.

No physical device, BLE, background, haptic, notification-delivery, signing,
store, accuracy, carrier, or production-infrastructure claim follows from these
local checks.
