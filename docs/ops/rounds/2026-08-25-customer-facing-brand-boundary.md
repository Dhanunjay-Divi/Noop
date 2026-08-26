# Round: 2026-08-25 - Customer-facing brand boundary

## Status

- State: `completed locally; physical-device and external release gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `ba81a3aa`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Remove the retired transport-vendor name from customer-facing NOOP experiences
on Apple and Android while preserving existing local data, BLE compatibility,
import formats, source metadata, and independent dependency license texts.

Success means normal UI, onboarding, notifications, diagnostics, release notes,
exports, accessibility text, and every shipped locale render neutral NOOP or
compatible-wearable wording. A standing audit must reject regressions.

## Scope

### In scope

- Apple and Android UI/resource/catalog wording, including Sleep provider
  badges, score explanations, onboarding, Coach, diagnostics, and history.
- Runtime-generated release-note, connection-log, diagnostic-bundle, and export
  text that cannot rely on localization overrides.
- Customer-facing source labels in shared analytics models.
- Terms wording and first-launch re-acknowledgement.
- Tests and a strict rendered-text audit for both platforms.

### Non-goals

- Renaming internal protocol modules, BLE classes, GATT families, persisted
  device IDs, database namespaces, importer formats, or compatibility symbols.
- Rewriting history or changing metric formulas, source arbitration, sync,
  pairing, or sensor behavior.
- Renaming compatibility-sensitive internal identifiers or deleting license
  texts for independent runtime dependencies.
- Claiming first-party NOOP Band hardware is available.

## Starting evidence

- The reported screen still exposed the retired vendor name in a provider
  score/source presentation.
- The same wording remained across catalog values, Android resources, runtime
  release notes, diagnostic logs, exports, and source labels.
- Existing identifiers and database values are compatibility-sensitive and
  cannot be renamed as a presentation fix.
- The localization gate did not previously enforce this customer-facing brand
  boundary.

## Delivered

- Reworded customer-visible Apple and Android experiences to use `Noop Band`,
  `compatible band`, `wearable import`, `imported`, or `provider score` where
  each description is accurate.
- Removed model-generation wording such as 4.0/5/MG from normal customer
  identity while retaining generation distinctions only where a technical
  capability explanation requires `legacy band` or `newer band`.
- Added Apple and Android `CustomerFacingBrand` scrubbers for runtime text and
  applied them before logs, release notes, diagnostics, exports, Coach context,
  onboarding summaries, and update history reach customer surfaces.
- Preserved the existing source key or resource identifier when changing it
  would break localization lookup or compatibility; every rendered value is
  neutral.
- Added a strict cross-platform audit that checks localized catalog values,
  Android resources, and hardcoded UI values for the retired term.
- Added focused audit, rendering, source-label, export, bundle, and dynamic-text
  tests. Shrunk the hardcoded-localization baseline from 247 to 245 Android
  entries and from 166 to 165 Apple entries.
- Updated the bundled terms to version 2.4 so existing users acknowledge the
  neutral third-party hardware wording.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none. Persisted IDs such as `my-whoop`,
  importer namespaces, and database paths remain unchanged.
- Source/provenance or formula impact: source presentation is neutralized;
  source arbitration, formulas, raw provenance, and dependency license
  inventory are unchanged.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none. This is a presentation
  and regression-boundary change, not sensor or clinical validation.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Rendered-text and localization audit | Passed with no retired vendor wording in rendered Apple catalog, Android resource, or hardcoded UI values | Statically known shipped customer text is neutral across the audited surfaces | Text supplied by an untrusted future external service |
| i18n audit unit suite | 42 tests passed | Catalog fallback, resource-name exclusion, interpolation handling, and regression checks behave as intended | Native-speaker quality |
| Focused Apple brand/source/export tests | 27 tests passed | Dynamic scrubbing, source labels, diagnostics, exports, and screen contracts are neutral | Physical-device rendering |
| Rendered iPhone UI | 2 tests passed on the iPhone 14 Pro simulator for terms and band onboarding | Visible labels and the accessibility tree use neutral NOOP wording on the two highest-risk setup surfaces | Physical-device rendering or every navigable screen |
| StrandAnalytics | 1,367 tests passed; 7 intentional data-dependent skips | Shared source labels and arbitration changes preserve analytics behavior | Accuracy on a new participant cohort |
| StrandDesign | 44 tests passed | Shared state-pill wording and package behavior remain coherent | Complete app navigation |
| macOS app suite | Passed | The complete Apple app graph accepts the presentation changes | iPhone layout, BLE, or background behavior |
| Android Full Debug | 3,653 tests passed; 6 skipped; debug APK assembled | Android logic, resources, generated localization, and app packaging remain coherent | OEM behavior or signed Play release |
| iOS simulator build | Passed unsigned | Current Apple sources, resources, widgets, and Watch dependencies compile for iOS Simulator | Signing, App Review, or physical-device behavior |
| Repository policy | Generator parity, strict i18n, ops validation, and `git diff --check` passed | Generated files, standing text gate, round records, and whitespace are coherent | Distribution rights |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: no physical device in this round.
- Data-preservation result: no device container, database, pairing, or band
  state was modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: representative iPhone/Android layouts, dynamic type,
  notification rendering, overnight sync, background reconnect, and diagnostics
  generated from a live band.

## Git and release state

- Changed paths: Apple/Android UI and tests, shared analytics labels, generated
  localization, dynamic customer-text boundaries, App Store copy, terms, and
  operations/handoff records.
- Commits: the direct-to-`main` commit containing this record.
- Branch and remote state: local `main` tracks `origin/main`; the validated
  commit is pushed immediately after creation.
- Repository visibility verified: not rechecked in this round.
- Version/build impact: Terms acknowledgement version 2.4; no marketing version
  or build-number change.
- Release or distribution impact: no artifact publication. Existing rights,
  signing, infrastructure, carrier, physical-device, and store gates remain.

## Decisions

- Added D-024: customer-rendered text uses NOOP or neutral compatible-wearable
  language. Compatibility identifiers remain internal, while NOOP licensing and
  dependency notices stay in their legal surfaces.

## Open risks and honest limitations

- The NOOP owner declaration governs source rights.
  Independent runtime dependencies retain only their own license notices.
- Legacy localization source keys and Android resource names can retain the old
  token as implementation identifiers. Explicit localized values prevent those
  identifiers from rendering, and CI checks that invariant.
- Static and unit evidence cannot prove every physical-device notification,
  accessibility size, external-data, or OS fallback path.
- Native-speaker review remains required for store-quality localization.

## Next round

1. Keep the owner-rights record, NOOP license, and independent dependency
   notices enforced by the distribution gate.
2. Validate representative Apple and Android UI, notifications, dynamic type,
   diagnostics, pairing, and overnight sync on physical devices without
   resetting existing data.
3. Continue carrier, infrastructure, signing, store, accuracy, and regulatory
   work already ordered in `docs/ops/ACTIVE.md`.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
