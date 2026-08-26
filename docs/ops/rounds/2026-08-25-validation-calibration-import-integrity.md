# Round: 2026-08-25 - Validation, calibration, and import integrity

## Status

- State: `completed locally; physical-device and external-service gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `b431d51a`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Correct the overnight calibration and wearable-import paths using the three
private reference cohorts and the public PSG fixture, then verify the complete
Apple and Android product tree without fitting NOOP to a proprietary score.

Success means Recovery uses a causal personal Rest center, invalid inputs stay
missing, imported data is unit-safe and replacement-safe, sleep-stage evidence
is reported honestly, existing local data is repaired without destructive
reset, compact and larger iPhone layouts remain usable, and every local
build/test/policy gate is recorded.

## Scope

### In scope

- Recovery/Rest calibration, calibration-progress presentation, score
  confidence, and no-fabrication guards on Apple and Android.
- Sleep-stage and Recovery validation harness corrections.
- Apple and Android wearable CSV parsing, unit normalization, journal conflict
  handling, cycle/workout series parity, atomic replacement, and compatibility
  repair.
- Customer-facing provenance/explanation copy, large-text navigation clearance,
  localization, privacy guards, and reproducible validation documentation.
- Full local package, app, simulator, emulator, artifact, and policy checks.

### Non-goals

- Fitting NOOP coefficients or a fixed offset to three private cohorts.
- Claiming the proprietary reference outcomes are ground truth.
- Enabling automatic medical, anomaly, Rhythm, or unvalidated fall paging.
- Claiming physical-band, overnight, background, haptic, carrier, clinical, or
  store evidence from simulator and unit tests.
- Removing internal compatibility identifiers or required dependency notices.

## Starting evidence

- One completed night could still display `0 of 4` because progress used only
  the strictly prior scoring baseline instead of separately acknowledging the
  newly synced seed night.
- Recovery centered Rest on a fixed `0.85` value while its other main drivers
  were personal-baseline relative.
- The first validation pass accidentally exercised a legacy stager and fed the
  reference Sleep Performance outcome into the Recovery comparison.
- Historical imported `sleep_efficiency` series could remain percentage-scale;
  Android temperature, disturbance, workout-zone, cycle-series, and journal
  behavior had parity and replacement gaps.
- Re-import upserts could leave stale values that disappeared from a later
  source export.
- Private archives and prepared research fixtures had to remain outside Git.
- Compact-device screenshots exposed XCTest frame false positives beneath the
  custom navigation mask; rendered pixels, endpoint tests, and source
  contracts were needed to distinguish real overlap from masked accessibility
  frames.

## Delivered

- Centered Recovery's Rest-quality term on a usable causal personal
  `rest_quality` EWMA baseline. The fixed `0.85` center is cold-start only;
  sensitivity and the fixed personal-baseline logistic mapping remain unchanged.
- Made non-finite physiology, corrupt baselines, invalid Rest fractions, and
  invalid optional drivers fail closed instead of becoming plausible scores.
- Split scoring eligibility from visible calibration progress so a just-synced
  night advances the count without influencing its own score; the seed boundary
  reports baseline readiness.
- Persisted Rest confidence and independent evidence flags for motion, R-R,
  respiration, stage availability, and implausible stage mix. Confidence does
  not rewrite Rest or Recovery.
- Corrected the PSG harness to exercise shipped `SleepStagerV2`, pinned its
  dataset manifest, and documented degraded-input limits. Corrected the
  three-cohort harness to use causal production baselines and independently
  derived Rest.
- Added strict finite/range validation, complete cycle metric projection,
  Celsius normalization, workout-zone aggregates, and deterministic journal
  de-duplication/conflict omission across Apple and Android importers.
- Made Apple CSV persistence atomic and authoritative only inside represented
  source ranges while preserving local fields, edited sleep windows, and raw
  evidence. Android mirrors the replacement contract.
- Added an idempotent Apple post-open efficiency repair and immutable Android
  data-only migration `33 -> 34`; generated Room schema snapshots are tracked.
- Added private-fixture filename guards and owner-only preparation output.
- Preserved neutral customer-facing source wording while retaining internal
  format/provenance identifiers.
- Kept the full-bleed iPhone shell and transparent glass navigation, added a
  foreground mask below its measured bar, retained visible labels at
  Accessibility Dynamic Type, and verified compact and larger simulator
  classes.
- Replaced stale prior-repository blocker wording with the current NOOP owner
  declaration while preserving NOOP's PolyForm license and exact independent
  dependency notices.
- Finished the bottom shell with regular navigation glass and a 24-point
  foreground fade into reserved scroll clearance, then verified every final
  tab-shell scenario on a compact simulator.

## Data, privacy, and medical truth

- Schema or migration impact: Android Room schema advances from 33 to 34 with
  idempotent data repair. Apple schema migrations remain immutable; a
  transaction-marked post-open compatibility repair normalizes legacy generic
  efficiency values.
- Existing-data retention impact: in-place upgrade is preserved. Re-import
  replaces only importer-owned rows/keys in represented source ranges and
  preserves user-edited sleep windows, local evidence, unrelated sources, and
  out-of-range history.
- Source/provenance or formula impact: Recovery's Rest center becomes personal
  after calibration. No coefficient or logistic mapping parameter was fit to private
  cohorts. Reference outcomes remain comparison targets, not scoring inputs.
- Permissions/network disclosure impact: none. Validation preparation writes
  owner-only local files and adds no upload path.
- Health/medical claim impact and limitations: findings are engineering
  associations and regression evidence, not clinical validation. Wake
  sensitivity remains inadequate for a sleep-stage accuracy claim, and no
  result supports diagnosis or automatic emergency decisions.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| StrandAnalytics | 1,390 passed; 7 explicit data-dependent skips | Scoring, confidence, staging, physiology guards, and shared analytics contracts pass | Population calibration or clinical accuracy |
| StrandImport | 232 passed; 2 explicit fixture-dependent skips | Parser, unit, provenance, journal, and round-trip contracts pass | Every future export dialect |
| WhoopStore | 386 passed | Apple migration, atomic import, replacement, edit preservation, and storage contracts pass | Crash behavior on every physical device |
| WhoopProtocol | 406 passed; 1 explicit corpus-dependent skip | Changed diagnostic presentation preserves protocol tests | Live BLE or new firmware behavior |
| Study harness | 12 passed | Walk-forward causality and validation split controls pass | A completed prospective study |
| Corrected external-data harnesses | PSG V2 and all three private cohorts passed; aggregate verdicts recorded | The fixed harnesses reproduce the reported associations and limits | Ground truth, population validity, or first-party band accuracy |
| macOS app suite | 1,465 executed; 1 explicit fixture-dependent skip; 0 failures | Complete Apple app graph and source contracts pass | iPhone, BLE, or background behavior |
| iPhone production-shell suite | 23 of 23 passed on both compact and larger simulator classes | Navigation, large text, key flows, and endpoint clearance work in both simulated layouts | Physical-device rendering or every accessibility combination |
| Final bottom-glass visual QA | 20 of 20 iPhone 17e tab-shell scenarios passed | Regular glass, endpoint fade, labels, and compact navigation render coherently | Physical-device rendering or every possible page state |
| Generic iOS Simulator build | Passed unsigned | App, widgets, Watch dependencies, resources, and current source compile | Signing, installation, or App Review |
| Android Full Debug | 3,712 passed; 7 explicit skips; APK, lint, and instrumentation compilation passed | Android logic, resources, migration source, localization, and artifact construction are coherent | OEM, signed Play, battery, or background behavior |
| Android managed device | 12 of 12 API 35 migration/import tests passed | Room `33 -> 34` and atomic replacement execute on a managed emulator | Upgrade behavior on every OEM/device |
| Localization | 290 generated app-wide keys have exact parity across nine locales; strict i18n passed | Generated resources are structurally complete | Native-speaker quality |
| Server | 142 passed; 11 environment-dependent skips; Ruff check and format check passed | Local API, paging, tenancy, retention, and deployment contracts are coherent | Managed production infrastructure or real carrier delivery |
| Repository policy | 77 Python unit tests, claims across 1,061 files, private-data, legal inventory, distribution, ops, and whitespace gates passed | Tracked-source policy contracts are coherent | Signing, store, carrier, or physical-device readiness |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: iPhone SE and iPhone 14 Pro simulator
  classes; managed Android Pixel-class API 35 emulator.
- Data-preservation result: migration/import tests preserve modeled existing
  data; no personal physical-device container was modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: representative in-place physical upgrades, live band
  overnight sync and reconnect, background collection, HealthKit, Watch,
  haptics, battery, Android OEM behavior, and carrier paging.

## Git and release state

- Changed paths: shared analytics/import/store packages, Apple and Android app
  scoring/import/UI paths, Room schema snapshots, validation/privacy tools,
  localization, tests, and validation/operations documentation.
- Commits: the direct-to-`main` commit containing this record.
- Branch and remote state: local `main` is pushed and checked against
  `origin/main` after all gates pass; the merged App Store feature branch is
  removed so `origin/main` is the only remote branch.
- Repository visibility verified: authenticated GitHub inspection reports
  private, `isFork=false`, and no parent.
- Version/build impact: Android database schema 34 and wearable CSV importer
  revision 5; no marketing version or build-number change.
- Release or distribution impact: no artifact publication. The NOOP owner
  declaration, project license, and dependency notices pass the distribution
  gate.

## Decisions

- Added D-025: Recovery centers Rest on a causal personal Rest baseline once
  usable; fixed `0.85` is cold-start only, the `0.12` scale and fixed
  personal-baseline logistic remain unchanged, cold start remains nil, and
  private reference outcomes are never production inputs.

## Open risks and honest limitations

- Six PSG subjects without wrist R-R or respiration are insufficient for a
  stage-accuracy claim; wake recall remains the clearest model weakness.
- Three private cohorts reveal repeated behavior but are not population
  calibration, demographic coverage, or an independent outcome study.
- Simulator/emulator and unit evidence do not validate physical sensors,
  overnight delivery, background execution, haptics, battery, or carrier
  receipt.
- Generated localization parity is not native-speaker approval.
- Production release remains blocked on signing, store, infrastructure,
  physical-device, carrier, localization, and regulatory evidence.

## Next round

1. Validate backed-up in-place upgrades and overnight/background/band behavior
   on representative physical Apple and Android devices.
2. Complete production topology, load/failover/restore, monitoring/on-call, and
   controlled carrier delivery evidence.
3. Acquire a wrist R-R plus respiration plus PSG dataset and run a preregistered
   held-out staging/Recovery study before accuracy claims.
4. Complete native-speaker review, signing, privacy labels, store metadata, and
   signed release archives with every release gate green.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
