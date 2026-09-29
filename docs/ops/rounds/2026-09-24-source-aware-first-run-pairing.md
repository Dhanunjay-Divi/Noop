# Round: 2026-09-24 - Source-aware first-run pairing

## Status

- State: `completed locally; integration verification pending`
- Owner: project team
- Branch: `codex/source-aware-onboarding-20260924`
- Start commit: `43cadcc378f3cbf1a0796a9160f7e2c1fa6ee738`
- Record commit or PR: commit containing this record

## Objective

Route Apple and Android first-run device setup through the existing
source-aware add-device wizard. Preserve WHOOP as the default test transport,
allow exploration without a band, and require a real claim-eligible source in
configured ownership mode without claiming physical pairing or accuracy.

## Scope

### In scope

- Source-aware first-run selection and fail-closed completion on both phones.
- Durable Android registration and retryable registry-read failures.
- Localized and accessible setup, completion, and mandatory WHOOP pairing copy.
- Bounded setup and registration diagnostics.

### Non-goals

- Supplier binaries, credentials, distribution, or default enablement.
- Ownership proof, firmware, physical BLE, accuracy, or background validation.
- Cloud authority or formula changes.

## Starting evidence

- First run owned separate WHOOP-only scan/connect paths.
- Supplier registry commits could not complete onboarding without
  WHOOP-specific bonded state.
- Independent review found stale supplier eligibility, a fabricated accessible
  Recovery score, cancellable Android writes, unretryable registry failures,
  unavailable-option copy, and mixed-language mandatory Android pairing UI.
- Physical transport behavior remained unmeasured.

## Delivered

- Both platforms present the shared `AddDeviceWizard`. Configured ownership
  limits selection to claim-eligible bands; exploration retains all sources and
  `Continue without a band`.
- Completion rejects imports, activity files, archived/inactive rows, the
  untouched seed, blank identity, mismatched source metadata, and unavailable
  supplier rows.
- The completion visual is decorative and accessibility-hidden rather than
  fabricating a Recovery score.
- Android registry reads fail closed with a localized retry and bounded
  `read_failed` outcome. Oura file import routes to the Import page.
- Android registration is duplicate-guarded and completes persistence inside a
  non-cancellable section while dismiss/back actions are disabled.
- The unreachable `supplierCommitFailed` state was removed; the real
  `registrationFailed` state remains user-visible.
- Mandatory WHOOP headers, guidance, warnings, discovery state, actions, and
  accessibility text use the shared nine-locale source on both platforms.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical limitation: setup completion means only that a supported
  source was saved. It does not prove ownership, current connection,
  physiological accuracy, or a valid health measurement.

## Observability

- Existing per-source pairing diagnostics remain in `AddDeviceWizard`.
- `onboarding.device_setup` records only `opened`, `dismissed`, `completed`, or
  `read_failed`, with an optional fixed source-kind enum.
- `device.registration` records only `completed` or `failed`.
- Names, addresses, printed IDs, passwords, peripheral IDs, RSSI, raw errors,
  timestamps, health values, and user text are excluded.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Shared localization generator | 865 app-wide strings and 45 Android-only resources for 9 locales | Generated catalogs match source | Native-speaker review |
| Full i18n audit | Exit 0 | No locale-key gap introduced | Physical visual fit |
| Android Full compile and focused tests | Pass in 1m12s | Kotlin/resources and focused contracts pass | Phone BLE/runtime behavior |
| Focused macOS XCTest | 22/22 pass | Apple source and focused contracts pass | Signed iPhone behavior |
| Unsigned iOS Simulator build | Pass with Watch and widget embedded | Complete Apple graph builds | Physical background/BLE behavior |
| Swift parse, JSON/XML parse, diff check | Pass | Changed source/catalog structure is valid | Runtime behavior |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: macOS host and unsigned iOS Simulator graph.
- Data-preservation result: no schema or stored-data mutation.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: WHOOP and supplier discovery/pairing, printed-ID and
  password truth, battery/live-HR accuracy, reconnect, background history,
  haptics, retention, and battery life.

## Git and release state

- Changed paths: Apple/Android onboarding and add-device UI, focused tests,
  shared localization source/catalogs, and this record.
- Commits: commit containing this record.
- Branch and remote state: isolated local branch; integration pending.
- Repository visibility verified: unchanged.
- Version/build impact: none.
- Release or distribution impact: none until protected integration.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: none; existing ownership, offline, and supplier-default-
  off contracts are preserved.

## Open risks and honest limitations

- Supplier-enabled faces remain in the combined supplier round and must be
  localized before supplier distribution.
- The receiving supplier branch has Swift concurrency warnings to remove.
- Build/simulator evidence does not validate physical transport behavior.

## Next round

1. Integrate this commit into the supplier candidate.
2. Localize supplier-enabled faces and remove supplier concurrency warnings.
3. Run combined platform, visual, policy, and operations walls before one push.

## Privacy check

- [x] No credentials, personal identifiers, raw biometric exports, signing
      identities, or absolute personal paths are present.
