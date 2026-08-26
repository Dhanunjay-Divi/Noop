# Round: 2026-08-24 - Cycle tracking and profile metric reconciliation

## Status

- State: `completed`
- Owner: project team
- Branch: `main`
- Start commit: `d1f238f8`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Make menstrual-cycle tracking discoverable and conservative on both platforms,
prevent profile-dependent age metrics from showing stale results, simplify
Sleep hero provenance, and keep Daily Signal source/state information legible
while Noop Band history is syncing.

## Scope

### In scope

- Apple and Android cycle setup, presentation, localization, and engine parity.
- Profile/device/birthday reconciliation for Fitness Age and Vitality.
- Neutral imported Sleep hero source copy.
- Compact Daily Signal layout and honest indeterminate band-sync feedback.
- Regression tests, app builds, UI tests, independent review, and handoff.

### Non-goals

- Fertility, ovulation, contraception, pregnancy, or diagnostic claims.
- Clinical validation of cycle, Fitness Age, Vitality, Sleep, or band signals.
- Physical-device BLE, background, haptic, battery, or accuracy validation.
- Commercial release or distribution-gate changes.

## Starting evidence

- Changing Sex to Female did not reliably reveal menstrual-cycle setup in an
  already-mounted Health screen, and the entry point disappeared with empty
  wearable history.
- The cycle estimate used a fixed forecast width and could accept a one-night
  elevated-temperature artifact as a shift.
- Fitness Age and Vitality surfaces could read a result generated for an older
  date-of-birth, sex, waist, or active-device profile.
- Sleep showed both a provider brand and `PROVIDER SCORE` in the hero.
- Daily Signal source/state chips did not fit predictably on compact layouts,
  and Noop Band history sync had no truthful progress treatment.

## Delivered

- Added a Menstrual cycle row directly below Sex in Apple and Android Profile,
  with the same private opt-in and tracker reachable from Health before any
  wearable data exists.
- Added a localized cycle ring, confidence state, logged day-one marker, period
  window, flow/symptom history, and clear empty states. The ring does not invent
  a day-one marker without a user log and contains no fertility prediction.
- Advanced explicit period logs to the current civil day even when the last
  wearable night is older. Logged cadence wins over indirect temperature-shift
  spacing for period forecasts.
- Required two elevated nights in a trailing three-night window before treating
  temperature evidence as a shift. Recent interval variability widens forecast
  windows; stale, out-of-range, or highly variable history suppresses a
  forecast while preserving an honest current cycle-day count when possible.
- Added stable note categories and localized all cycle presentation across nine
  locales on Apple and Android.
- Added focused Fitness Age/Vitality reconciliation after profile and active
  source changes, on onboarding completion, and on foreground return across a
  birthday. Stale asynchronous reads cannot publish under a newer profile.
- Kept failure semantics strict: read/write failures do not become successful
  no-value outcomes. Android completion-marker persistence uses a checked
  background commit and updates the in-memory watermark only after success.
- Replaced the Sleep hero's provider-specific pair with one neutral `Imported`
  badge. On-device values continue to show local source and confidence.
- Reworked Daily Signal into responsive identity/source/state groups and added
  an indeterminate Noop Band sync sweep with reduced-motion handling and a
  short completion confirmation.
- Expanded the generated shared catalog from 136 to 183 keys and kept exact
  Apple/Android parity across nine locales.
- Confirmed the prior large-text tab-label guard and populated-week Trends
  landing behavior remain present.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: no container, band, health, profile, period,
  flow, or symptom history is deleted or reset.
- Source/provenance or formula impact: visible Sleep source wording is neutral,
  but stored import provenance remains. Cycle awareness now confirms shifts and
  adapts or suppresses forecasts from explicit log variability. Fitness Age and
  Vitality formulas are unchanged; only recomputation and stale-result
  publication are hardened.
- Permissions/network disclosure impact: no new network path. Existing optional
  HealthKit cycle import remains consent-gated. Cycle logs remain local under
  the existing storage contract.
- Health/medical claim impact and limitations: cycle output remains an
  awareness estimate, not fertility, contraception, diagnosis, or medical
  advice. Fitness Age, Vitality, Sleep, and Daily Signal remain wellness
  estimates.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| StrandAnalytics package | 1,330 tests passed | Shared cycle and analytics contracts pass | Clinical or participant validity |
| macOS app suite | 1,402 passed, 1 skipped, 0 failed | Broad shared Apple graph and new app contracts pass | iOS hardware behavior |
| Generic iOS simulator build | Passed | Final Apple source and resources compile for iOS | Signing, App Review, or physical sensors |
| iOS production-shell suite | 21/21 passed on iPhone 17 Pro simulator | Production navigation/layout regressions pass, including clear Trends range copy | Every device size, Dynamic Type combination, or physical phone |
| Android Full Debug unit suite | 3,595 tests, 0 failures, 6 skipped | Broad Android source, engine, localization, and retry contracts pass | Android OEM runtime or instrumentation execution |
| Android Full Debug APK | Passed | The application assembles with final code and resources | Store signing or Play acceptance |
| Managed Pixel API 35 instrumentation | 3/3 passed | Production-shell tests execute on the managed emulator | Android OEM or physical-device behavior |
| Shared localization generator | 183 keys across nine locales; idempotent | Apple/Android resource parity | Native-speaker approval |
| i18n gate | Passed; no new debt | Focus locales are complete and baseline debt did not increase | Translation quality |
| Health-claims gate | Clear across 1,042 files | No prohibited wording was introduced | Regulatory clearance |
| Legal inventory | 152 runtime components and 3 container inputs verified | Runtime inventory remains exact | Commercial source rights |
| Independent source review | Persistence finding fixed; follow-up review clear | Cancellation, captured source, stale-target, partial publication, and retry paths received separate review | Hardware or medical validation |
| `git diff --check` | Passed | Final diff is whitespace-clean | Behavioral correctness |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: iPhone 17 Pro simulator, generic iOS
  simulator compile destination, macOS host, and local Android JVM/build tools.
- Data-preservation result: no physical app container or band data was touched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: Noop Band offload/reconnect, HealthKit device reads,
  background collection, haptics, overnight cycle temperature, Android OEM
  behavior, and battery impact.

## Git and release state

- Changed paths: shared cycle analytics; Apple and Android Profile, Health,
  cycle, Sleep, Today, age-metric reconciliation, localization, and tests;
  operations and handoff records.
- Commits: one direct-to-`main` implementation and documentation commit.
- Branch and remote state: local `main` is pushed to canonical `origin/main`
  only after all recorded gates pass.
- Version/build impact: no marketing version or build number change.
- Release or distribution impact: no artifact published. The source-rights
  review active during this round was cleared on 2026-08-25.

## Decisions

- Cycle tracking is private, opt-in awareness. Explicit logs anchor period
  cadence, uncertain histories suppress prediction, and the UI never presents
  fertility or contraception guidance.
- Imported Sleep values retain stored provenance while the hero uses a neutral
  `Imported` label instead of provider-specific promotional copy.
- Profile-dependent projections must reach their persistence boundary before a
  completion watermark advances.
- Decision-log entries: D-015 and D-016.

## Open risks and honest limitations

- Cycle thresholds and forecast widths are engineering bounds with unit parity,
  not a clinical or fertility validation study.
- Machine-translated reproductive-health copy requires native-speaker review.
- Simulator evidence does not establish physical band sync, haptic, background,
  battery, or sensor behavior.
- The app still needs representative-device and participant accuracy studies.
- The current release gate still requires the owner-rights record, NOOP license,
  and exact independent dependency notices.

## Next round

1. Run the cycle, age-metric, and band-sync paths on representative physical
   devices without resetting existing app data.
2. Obtain native-speaker review for every reproductive-health string.
3. Execute participant/device studies before changing cycle awareness into any
   more assertive prediction.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
