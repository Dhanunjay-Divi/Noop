# Round: 2026-08-26 - Metric evidence and training-load boundaries

## Status

- State: `completed locally; physical-device and external-service gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `8b733c15`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Close the remaining metric-audit findings without fitting NOOP to a proprietary
reference score. Success means detailed local sleep stages fail closed without
sustained R-R evidence, discredited acute-to-chronic workload ratios are absent,
bounded Effort cannot enter additive load math, Recovery cold start remains
honest, and Apple Health SDNN never contaminates a strap RMSSD baseline.

## Scope

### In scope

- Apple and Android detailed-stage publication policy, persistence filtering,
  Sleep presentation, history, comparisons, and localization.
- Removal of ACWR from shared readiness models and customer surfaces.
- Recovery display-mapping terminology and removal of the unused numeric
  cold-start fallback symbol without changing score behavior.
- Typed Watch HRV source/method provenance and isolated baseline construction.
- Cross-platform tests, release documentation, and repository policy gates.

### Non-goals

- Fitting a Recovery offset or logistic parameter to private reference exports.
- Changing the sleep classifier or claiming clinical sleep-stage accuracy.
- Treating bounded Effort as session-RPE, TRIMP, MET-minutes, or another
  additive impulse-load unit.
- Enabling medical, anomaly, Rhythm, or unvalidated fall paging.
- Claiming physical-device, carrier, signing, store, or population evidence.

## Starting evidence

- The corrected public PSG pass measured shipped V2 at 61.6% 4-class
  agreement, but wake recall remained 10.0%, the fixture lacked R-R and
  respiration, and detailed local stages were still publishable without a
  durable evidence gate.
- `ReadinessEngine` retained a coupled 7-day/28-day ratio built from bounded
  nonlinear Effort even though the project already documented ACWR's lack of
  predictive validity and prohibited bounded scores as impulse load.
- Apple Health SDNN and strap RMSSD shared millisecond units but did not carry a
  typed source/method boundary through Watch Recovery baseline construction.
- Recovery's unused `populationMean` symbol suggested a numeric cold-start
  fallback even though production scoring correctly withholds Recovery until a
  personal HRV baseline is usable.

## Delivered

- Added one cross-platform detailed-stage publication policy. Local Deep, REM,
  Light, awake, restorative history, and comparisons require persisted session,
  staged-sleep, and sustained R-R evidence for the exact source, wake day, and
  canonical main-sleep group. Same-day naps cannot borrow the main night's
  verdict. Missing or corrupt evidence fails closed; total sleep remains available.
- Preserved independently classified imported stages with source disclosure and
  retained raw local estimates for diagnostics and future reprocessing.
  NOOP-authored HealthKit and Health Connect records keep imported classifier
  labels stage-free because those stores cannot preserve the original classifier
  as the visible source.
- Applied the gate in Apple and Android repositories as well as current-night,
  historical, typical, comparison, and restorative UI paths.
- Capped the cross-platform full-history upper-bound buffer at `9999-12-31`.
  Formatting its next day as year 10000 sorted before every 2xxx ISO key and
  could empty a detailed-stage full-history query.
- Removed ACWR fields, arithmetic, signals, risk wording, and dead localization
  copy from Swift and Kotlin readiness. A bounded-Effort variety note remains
  descriptive and excluded from readiness synthesis.
- Kept `TrainingLoadModel` as the sole ATL/CTL/TSB path for explicit additive
  load entries.
- Removed the unused Recovery population fallback symbol and renamed the fixed
  logistic parameters as a personal-baseline display mapping. Values and score
  behavior are unchanged; cold start remains nil.
- Added source-and-method provenance to Watch HRV samples and results. Baseline
  history is filtered to an exact source/method match, and customer copy
  explains Apple Health SDNN versus strap RMSSD.
- Restored reliable Today pull-to-sync feedback on iOS 26 with a top-gated
  vertical drag fallback, a two-second minimum indicator presentation, and
  honest local-refresh wording when no band is connected.
- Updated analytics, validation, release, top-level product, operations, and
  agent-handoff documentation to match the shipped behavior.

## Data, privacy, and medical truth

- Schema impact: additive and fail-closed. GRDB v44 and Room v35 add nullable
  `rrEligibleWindowCount` and `rrValidWindowCount` columns to each sleep session;
  GRDB v45 and Room v36 add nullable `hrvMethod` beside each daily HRV value.
  Existing rows remain unknown until that exact session or HRV method is
  recomputed/imported. One-time, permission-gated publication migrations replace
  NOOP-authored HealthKit and Health Connect sleep records across available
  history. Their completion flags are per active device and are written only
  after the full replacement succeeds.
- Existing-data retention impact: raw local and imported stage estimates remain
  stored in NOOP. Previously published unsupported or re-attributed stage detail
  is replaced with unspecified sleep in HealthKit or a stage-free sleep session
  in Health Connect; total sleep bounds remain available.
- Source/provenance or formula impact: ACWR is removed. Recovery constants are
  renamed but unchanged. Watch HRV baseline membership now requires exact
  source/method provenance.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: the sleep-stage gate reduces
  unsupported precision but does not validate the classifier. Effort variety,
  ATL/CTL/TSB, Recovery, and HRV remain wellness/training context, not diagnosis,
  injury prediction, or permission to train.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| StrandAnalytics | 1,402 total; 7 data-dependent skips; 0 failures | Shared scoring, stage policy, readiness, and HRV provenance contracts pass | Population or clinical validity |
| macOS app suite | 1,490 total; 1 fixture-dependent skip; 0 failures | Apple repository and UI integration compile and pass app tests | Physical iPhone, Watch, BLE, or background behavior |
| Android Full Debug | 3,775 total; 3,768 passed; 7 skips; 0 failures/errors | Full Android logic, UI-model, resource, and policy tests pass | OEM or physical-band behavior |
| Android Demo Debug | 3,775 total; 3,768 passed; 7 skips; 0 failures/errors | Demo variant remains behaviorally and structurally coherent | Signed Play distribution |
| Focused Apple sleep/Watch tests | 27 executed; 0 failures | Stage publication and Watch source isolation pass focused app tests | Overnight physical-device evidence |
| Focused iOS pull-to-sync UI test | 1 executed; 0 failures | Circular refresh feedback appears after a top pull on an iPhone 14 Pro simulator | Physical-device gesture, BLE, or background-sync behavior |
| Localization audit | Catalog JSON valid; no missing shipped Apple translations | Catalog structure and translated-key coverage remain complete | Native-speaker quality |
| Health-claims gate | Clear across 1,066 tracked source files | Protected customer-copy boundaries remain intact | Regulatory approval |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: local macOS host; unit and app test targets.
- Data-preservation result: NOOP database rows are not mutated. Authorized
  HealthKit/Health Connect writeback performs a retryable, one-time replacement
  of app-authored sleep records so old unsupported stage detail cannot remain.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: overnight band sync, reconnect, sustained R-R capture,
  HealthKit source changes, Watch handoff, haptics, battery, Android OEM
  background behavior, and representative in-place upgrades.

## Git and release state

- Changed paths: shared analytics, Apple and Android repository/presentation
  paths, localization, tests, validation records, release notes, and ops docs.
- Commits: the direct-to-`main` commit containing this record.
- Branch and remote state: local `main` is pushed and checked against
  `origin/main` after all local gates pass.
- Version/build impact: no marketing version or build-number change. The local
  stores advance to GRDB v45 and Room v36 with nullable additive columns.
- Release or distribution impact: no artifact publication. Signing, carrier,
  physical-device, infrastructure, and store gates remain separate.

## Decisions

- Added D-029: detailed local sleep stages require durable R-R evidence.
- Added D-030: ACWR is retired and bounded Effort is not additive load.
- Added D-031: HRV baselines are isolated by source and method.
- Preserved D-025: proprietary reference outcomes and
  `PersonalCalibrationModel` remain outside production Recovery scoring.

## Open risks and honest limitations

- Detailed-stage withholding prevents unsupported display precision; it does not
  improve the classifier's measured wake sensitivity or establish accuracy.
  Session-level publication uses persisted exact-session counts and the same
  deterministic main-night selector used by the product.
- Independently classified imports retain provider staging because their
  provenance is explicit; NOOP does not claim those values as its classifier.
- A fixed personal-baseline Recovery display mapping remains an internal product
  choice. Three private cohorts are not enough evidence to refit it.
- Simulator and unit evidence do not validate live source changes, overnight
  collection, physical haptics, battery use, or Android OEM scheduling.
- Production release still requires the external gates in
  `docs/handoff/RELEASE-BLOCKERS.md`.

## Next round

1. Acquire wrist R-R plus respiration plus PSG data and run a preregistered
   held-out staging study before making stage-accuracy claims.
2. Validate overnight R-R capture, Watch/HealthKit source changes, reconnect,
   background collection, haptics, battery, and in-place upgrades on physical
   Apple and Android devices.
3. Complete production topology, load/failover/restore, controlled carrier
   delivery, signing, store metadata, and native-speaker review.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
