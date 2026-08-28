# Round: 2026-08-27 - Performance, health profile, and testing release

## Status

- State: `completed locally; physical-device and external production gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `153237aa`
- End implementation commit: commit containing this record
- Record commit or PR: direct-to-`main` commit requested by the owner

## Objective

Recover and complete the interrupted release work without relying on an
oversized chat transcript. Success means startup and rendering changes remain
measurably covered, HealthKit paths fail safely when capabilities are absent,
post-workout summaries are private and opt-in, profile and vital-range
presentation stays medically honest, backup settings remain cross-platform,
all local release gates pass, `main` is pushed, hosted CI is verified, and the
community testing build is dispatched from that exact commit.

## Scope

### In scope

- Audit and finish the recovered Apple and Android performance changes.
- Preserve HealthKit capability guards and unsigned-build behavior.
- Finish post-sync workout-summary notifications and routing.
- Add BMI presentation, an optional user-selected target weight, and an honest
  aggregate vital-range summary.
- Keep target weight portable through settings schema v4 on Apple and Android.
- Complete localization, privacy, backup-format, release, and operations
  documentation.
- Run focused and full local validation, push `main`, verify hosted CI, and
  dispatch the testing-build workflow.

### Non-goals

- Infer body composition, blood pressure, ECG meaning, or a recommended target
  weight or rate of change.
- Claim real-time workout detection when delivery follows wearable sync.
- Claim physical-device, carrier, signing, notarization, store, production
  deployment, or clinical evidence from local and hosted software checks.
- Change the PolyForm license or independent dependency notices.

## Starting evidence

- Reproduction or observed symptom: the prior Codex chat exceeded the request
  size limit; its compact handoff and the existing dirty worktree preserved the
  implementation state.
- Relevant source/device/OS/firmware class: Apple app and iPhone shell, Android
  full application, HealthKit capability boundaries, local notifications, and
  cross-platform native backup settings.
- Existing tests, logs, exports, screenshots, or documents: focused
  WhoopStore and Android profile/backup/vital tests passed before this record;
  the resumed macOS run completed 43 selected tests with zero failures.
- Unknowns that must remain unknown until measured: representative physical
  startup, scrolling, HealthKit, background notification, wearable sync,
  battery, and in-place upgrade behavior.

## Delivered

- Android first composition no longer waits on the active-device Room query or
  opt-in WorkManager schedule repair. The process-wide active source resolves
  asynchronously and remains switch-safe, while deferred maintenance remains
  idempotent and preference-gated.
- Workouts and Insights use lifecycle-aware collection, deep workout
  projections are memoized, and expensive liquid canvases use
  display-synchronized 60/30/20-fps budgets. Fresh installs use the OLED Black
  default while existing explicit appearance choices remain unchanged.
- The iPhone SE Key Metrics header separates the trend badge from long labels,
  retaining stable card dimensions and full readable names.
- HealthKit capability resolution now distinguishes embedded-profile
  entitlements, App Store/TestFlight receipts, and unsigned profile-less
  processes. Entitlement-dependent observer, sync, write-back, and own-source
  filtering paths fail closed before evaluating HealthKit APIs.
- Profile shows a one-decimal, explicitly limited BMI and an optional
  user-selected target weight with no recommendation or rate. Settings schema
  v4 carries that target between Apple and Android.
- Health Monitor summarizes only finite, calibrated readings. Missing values
  and raw SpO2 ADC do not enter the aggregate range count.
- Apple adds a separate default-off post-workout summary. It snapshots existing
  history before requesting notification access, checks only after a completed
  persisted sync, uses generic privacy-safe lock-screen copy, routes to
  Workouts, and advances its frontier only after accepted delivery.
- Apple and Android strings cover all maintained locales. Privacy, App Store,
  backup, release, and operations records now describe the exact behavior and
  limitations.

## Data, privacy, and medical truth

- Schema or migration impact: settings payload schema advances from v3 to v4;
  native database schemas are unchanged.
- Existing-data retention impact: native database schemas are unchanged.
  Existing Android appearance choices and active-device selection are
  preserved. Target weight is additive and optional. Existing workout history
  becomes the notification frontier when the user opts in and is not announced.
- Source/provenance or formula impact: BMI uses the existing height/weight
  calculation; no body-composition or vendor-score inference is added.
- Permissions/network disclosure impact: post-workout notifications remain
  off by default and use existing local notification permission.
- Health/medical claim impact and limitations: target weight is a neutral
  remembered preference, and missing or raw vital readings do not count as
  outside range.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Android cold-launch sample | Same Pixel 2/API 35 emulator, eight launches each: median approximately 1.465s before and 1.064s after, approximately 27% lower | The measured emulator launch path improved under one controlled configuration | Physical-device startup, OEM behavior, battery, or broad statistical performance |
| Selected macOS app tests | 43 tests; 0 failures | Profile target, backup restore, and vital-summary logic pass in the app integration suite | Physical Apple behavior |
| WhoopStore `BackupSettingsTests` | 18 tests; 0 failures | Settings schema v4 and target-weight round trips pass | Full app restore on a physical device |
| Focused Android profile, backup, and vital-summary tests | Passed | The changed Kotlin logic compiles and focused persistence/summary contracts pass | Android OEM or physical-device behavior |
| Post-workout notification tests after final race fix | 6 tests; 0 failures | Opt-in, frontier, generic routing, denial, and re-enable behavior pass while the full macOS target recompiles | Operating-system delivery or background wearable timing |
| Android widget appearance test | Passed | Explicit System remains adaptive and absent/unknown values match the fresh-install Black default | Launcher-specific widget rendering |
| Full macOS app suite | 1,520 passed, 1 skipped, 0 failed; 1,521 total | The complete `Strand` test action passes after the final localization fix | Physical Apple behavior or signed distribution |
| Swift packages and StudyHarness | Nine packages: 2,729 tests, 10 skipped, 0 failed; StudyHarness: 12 passed | Reusable protocol, storage, analytics, design, import, local-access, remote-sync, and study components pass | App-store signing or physical-device integration |
| Android Full and Demo matrix | Each variant: 3,837 tests, 7 ignored, 0 failed; both debug APKs and both instrumentation test sources compiled | Both product flavors compile and their complete JVM suites pass | On-device instrumentation or OEM behavior |
| Server suite and static checks | 143 passed, 11 skipped; Ruff lint and format checks passed | The checked-in server contracts pass without a configured external integration environment | Deployed infrastructure, load, failover, restore, or provider delivery |
| Unsigned app compile matrix | Universal macOS executable verified as `x86_64 arm64`; generic iOS Simulator graph includes the app, widget, Watch app, and Watch complication | Both Apple application graphs compile without signing material | Device installation, signing, notarization, or store acceptance |
| Policy and localization gates | Legal, distribution, privacy, health-claims, operations, launch-isolation, Android XML, and strict i18n checks passed; 49 i18n tests passed | Checked-in policy contracts and maintained localization coverage remain intact | Qualified legal, medical, regulatory, or native-speaker review |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: a Pixel 2/API 35 emulator was used for the
  bounded cold-launch measurement; no physical device was run.
- Data-preservation result: no physical application container was mutated.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: representative Apple and Android startup, scrolling,
  HealthKit authorization, post-sync notification delivery, wearable history,
  background execution, battery, and in-place upgrade matrices.

## Git and release state

- Changed paths: Apple notification, HealthKit, profile, Health Monitor, Today,
  demo fixture, localization, and integration tests; Android startup, active
  source, rendering, profile, Health Monitor, appearance, localization, and
  tests; cross-platform backup settings; release/privacy/operations docs.
- Commits: direct `main` commit containing this record.
- Branch and remote state: the recovered work started from `153237aa`, with
  the closeout prepared directly on `main`; authenticated push equality is a
  post-commit release check.
- Repository visibility: authenticated GitHub verification is a post-push
  release check; local validation does not make a visibility claim.
- Version/build impact: no version or build-number change planned.
- Release or distribution impact: the on-demand community testing build is
  the post-push distribution check; no production upload or store release is
  claimed.

## Decisions

- Added D-033 for neutral BMI, optional user-selected target weight, and honest
  vital aggregation.
- Added D-034 for privacy-safe post-sync workout notifications.

## Open risks and honest limitations

- Physical-device, signing, store, infrastructure, carrier, held-out accuracy,
  native-speaker localization, and regulatory gates remain external.
- The approximately 27% startup result is a small controlled emulator sample,
  not a general Android or physical-phone claim.

## Next round

1. Complete representative physical-device and in-place upgrade validation,
   then continue the separately owned signing, store, infrastructure, carrier,
   held-out accuracy, native-speaker, and regulatory gates.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
