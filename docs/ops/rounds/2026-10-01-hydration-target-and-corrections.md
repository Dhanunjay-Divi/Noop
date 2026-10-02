# Round: 2026-10-01 - Hydration target explanation and corrections

## Status

- State: `implementation and focused verification complete; visual and protected integration pending`
- Owner: project team
- Branch: `codex/today-metric-catalog-fitness-age-20261001`
- Start commit: `232f746e045d2755947579c3408efc5c3b84ff69`
- End implementation commit: commit containing this round record
- Record commit or PR: PR `#27`

## Objective

Make Hydration understandable and safely correctable on Apple and Android:

- make clear that the displayed target is not a permanent three-litre constant;
- expose the confirmed profile and Effort inputs behind a compact detail action;
- keep body-composition estimates and wrist skin temperature out of a falsely
  precise fluid prescription;
- place editable NOOP drink entries immediately after quick logging;
- let a person clear an accidental day's NOOP entries behind confirmation while
  preserving imported Apple Health or Health Connect records;
- preserve source provenance, transactional totals, accessibility, and
  cross-platform semantic parity.

## Scope

### In scope

- Apple and Android hydration target explanation.
- Ordering and discoverability of exact NOOP drink-entry correction controls.
- Atomic Apple clear-day support matching the existing Android store boundary.
- Confirmation before destructive clear on both platforms.
- Focused storage, formula, UI contract, localization, build, and visual checks.

### Non-goals

- Treating hydration logging as diagnosis or treatment.
- Inferring dehydration from missing logs.
- Deriving an exact target from body-fat, lean-mass, wrist-temperature, or one
  ambient-weather reading.
- Editing or deleting imported Apple Health or Health Connect records.
- Claiming physical notification, band, background, battery, or sensor behavior.

## Starting evidence

- The reviewed iPhone screen showed `of 3.0 L` without explaining the confirmed
  inputs that produced the target.
- The formula already prefers confirmed adult weight, falls back to confirmed
  profile sex, and applies a bounded Effort adjustment; skin temperature is
  deliberately excluded.
- Individual NOOP entries are editable and deletable, but Apple places them
  below reminders and Android places them below history.
- Android exposes immediate clear-day mutation without confirmation. Apple has
  no equivalent clear-day UI/API despite the shared localized label.
- Imported intake is resolved separately and must remain read-only.

## Delivered

- Apple and Android now derive both the displayed target and its explanation from
  one shared breakdown: confirmed-weight or confirmed-profile baseline, plus
  the existing bounded Effort adjustment.
- The disclosure explicitly states that body composition, wrist temperature,
  and one ambient-weather reading are not used to manufacture a precise target.
- Editable NOOP drink entries now appear directly after quick logging, before
  reminders and history.
- Apple now has an atomic clear-day repository operation matching Android's
  storage boundary.
- Both platforms require destructive confirmation before clearing the selected
  day's NOOP-owned entries.
- Clear, edit, and delete operations preserve imported Apple Health or Health
  Connect intake.
- Existing bounded persistence diagnostics are reused without logging amounts,
  profile values, dates, or identifiers.
- All new copy is generated for every supported app-wide locale.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: only an explicit confirmed clear may remove
  the selected day's NOOP-owned drink entries.
- Source/provenance or formula impact: no goal formula change; explanation and
  source boundaries become visible.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: the target remains general
  wellness guidance, not a diagnosis, treatment, or measured fluid requirement.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: reuse bounded
  `hydration.persistence` operations for add, edit, delete, clear, and read.
- Why existing evidence is sufficient, or why new evidence is required:
  persistence already records fixed operation/outcome/failure categories.
- Existing evidence reused: Apple `AppDiagnosticsRecorder`; Android
  `AppDiagnosticsRecorder`.
- New bounded events or operation spans: none planned.
- Redaction, retention, and high-frequency controls: no amounts, profile fields,
  dates, identifiers, or imported values enter diagnostics.
- Cross-platform/backend correlation: not applicable; this remains mobile-local.
- Remaining blind spots: physical notification delivery and imported-provider
  mutation behavior require device/provider evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Resource preflight | Pass after exact cleanup: Data volume recovered from 3.6 GiB to about 21 GiB free | Local bounded verification may proceed without deleting source or durable evidence | Runtime performance |
| Apple focused tests | Consolidated focused `xcodebuild` exited 0, including `HydrationEntriesTests`; `HydrationGoalTests` had passed in the same implementation round | Apple formula breakdown, transactional entry correction, source preservation, and UI contracts compile and pass | Physical notification delivery or provider behavior |
| Android Full focused wall | `BUILD SUCCESSFUL`; hydration goal, persistence, accessibility, catalog, and compact-status tests passed with Full Kotlin/resource compilation | Android formula parity, confirmation/accessibility contracts, persistence boundaries, and compilation | Android visual appearance or physical Health Connect behavior |
| Apple app graphs | macOS `Strand` and complete `NOOPiOS` Simulator builds exited 0 | Shared Apple source and iPhone/Watch extension graphs compile with the hydration changes | Signed installation, physical notifications, or band cues |
| App-wide localization generation | `Generated 994 app-wide strings and 45 Android-only resources for 9 locales` | Apple and Android generated resources remain synchronized | Human linguistic review of every translation |
| Operations and diff hygiene | All 114 round records validate and `git diff --check` passes | Durable handoff format and patch hygiene | Runtime behavior outside the tested scope |

## Physical device and deployment

- Install/update action: unsigned iPhone Simulator candidate installed for the
  shared Today/catalog review; Hydration itself was not visually exercised.
- Generalized device and OS class: iPhone 17 Pro Simulator on iOS 26.5.
- Data-preservation result: unit/storage contracts prove imported-source
  preservation; no real provider account was mutated.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical-device and band behavior.

## Git and release state

- Changed paths: shared analytics formula breakdown, Apple/Android hydration
  store and UI, focused tests, generated localization, and operations records.
- Commits: pending consolidated commit.
- Branch and remote state: local isolated clone ahead of the current PR `#27`
  head.
- Repository visibility verified: unchanged.
- Version/build impact: no version bump.
- Release or distribution impact: protected source integration only after gates.

## Decisions

- Use confirmed weight/profile and Effort as an explainable wellness estimate;
  do not use body-composition estimates or wrist temperature to manufacture a
  precise daily requirement.
- Ambient weather may influence opt-in reminder timing where supported, but it
  does not silently rewrite the displayed target.
- Imported intake remains read-only; clear affects only NOOP-owned entries.
- Destructive clear requires explicit confirmation.

## Open risks and honest limitations

- Population hydration references do not establish one exact individual target.
- Simulator and unit evidence cannot validate thirst, sweat loss, heat exposure,
  notification delivery, or physical band behavior.

## Next round

1. Run hydration-specific iPhone and Android visual/accessibility review.
2. Push the consolidated replacement and require all protected contexts before
   merge.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
