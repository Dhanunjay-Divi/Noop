# Round 21 - Validation, calibration, and import integrity

**Date:** 2026-08-25
**Status:** implementation and local cross-platform verification are complete;
physical-device and external-service release gates remain

## Decisions to preserve

- Recovery centers Rest on a personal `rest_quality` EWMA baseline. The fixed
  `0.85` center is cold-start fallback only.
- Rest sensitivity stays `0.12`; the fixed personal-baseline logistic stays
  unchanged. Neither is tuned to the three private cohorts, and cold start
  remains nil.
- Reference Sleep Performance is an outcome only. NOOP Rest is derived from
  raw sleep aggregates before it enters Recovery.
- Non-finite and out-of-range Rest fractions are missing data, not values to
  clamp into plausible scores.
- Missing trustworthy R-R or respiration evidence lowers confidence. It does
  not rewrite stages or scores.
- Importers normalize sleep efficiency to `0...1`; compatibility repair is
  idempotent.
- Shipped migrations are immutable. Apple uses a post-open compatibility
  repair; Android uses the new data-only `33 -> 34` migration.
- Exact duplicate journal rows are removed. Contradictory answers for one
  day/question are omitted instead of selecting an arbitrary truth.
- Android import parity includes the complete cycle metric series, temperature
  normalization, and workout heart-rate zone aggregates.
- `SleepStagerRealPSGTests` must exercise shipped `SleepStagerV2`, not legacy
  V1.
- Internal provider-specific format and persistence identifiers remain where
  compatibility or provenance requires them. Customer-visible labels remain
  neutral.

## Corrected evidence

SleepStagerV2 on the fixed Walch PSG fixture:

- 4-class agreement 61.6%
- sleep/wake agreement 91.6%
- deep recall 83.1%
- REM recall 75.6%
- wake recall 10.0%

Leakage-safe Recovery across cohorts A/B/C:

| Cohort | Days | Bias | MAE | r | Band | Direction |
|---|---:|---:|---:|---:|---:|---:|
| A | 165 | -10.0 | 12.1 | 0.869 | 63.0% | 95.0% |
| B | 409 | -3.2 | 9.3 | 0.898 | 72.9% | 93.9% |
| C | 339 | -6.8 | 11.1 | 0.850 | 71.1% | 88.3% |

Independently derived Rest:

| Cohort | Bias | MAE | r |
|---|---:|---:|---:|
| A | +4.9 | 6.5 | 0.807 |
| B | +3.4 | 6.1 | 0.775 |
| C | +6.1 | 6.8 | 0.858 |

These are fixed-sample associations with proprietary reference outcomes, not
provider-tuned calibration, clinical validation, or physiological ground
truth.

## Verification completed

- StrandAnalytics: 1,390 passed, 7 explicit data-dependent skips.
- StrandImport: 232 passed, 2 explicit fixture-dependent skips.
- WhoopStore: 386 passed.
- WhoopProtocol: 406 passed, 1 explicit corpus-dependent skip.
- Study harness: 12 passed.
- Corrected PSG V2 and three-cohort Recovery/Rest harnesses passed.
- All three private archives passed the production-parser path. No archive or
  prepared fixture is tracked.
- macOS app suite: 1,463 passed, 1 explicit fixture-dependent skip.
- iPhone production-shell suite: 23 of 23 passed on both compact and larger
  simulator classes, including Accessibility Dynamic Type captures.
- Generic iOS Simulator build passed unsigned.
- Android Full Debug: 3,712 passed, 7 explicit skips; APK, lint, and
  instrumentation compilation passed.
- Android API 35 managed-device migration/import suite: 12 of 12 passed.
- Generated app-wide localization has exact 285-key parity across all nine
  shipped locales.

## Exact reproduction commands

Run from the repository root.

PSG preparation and shipped-stager measurement:

```bash
python3 Tools/validation/fetch_walch_sleep.py \
  --subjects 6 \
  --raw /tmp/noop-walch/raw \
  --out /tmp/noop-walch/prepared

NOOP_WALCH_DIR=/tmp/noop-walch/prepared \
  swift test --package-path Packages/StrandAnalytics \
  --filter SleepStagerRealPSGTests
```

Privacy-safe structural audit, preparation, and three-cohort comparison:

```bash
python3 Tools/validation/audit_wearable_exports.py \
  /absolute/path/to/cohort-a.zip \
  /absolute/path/to/cohort-b.zip \
  /absolute/path/to/cohort-c.zip

python3 Tools/validation/prepare_whoop_export.py \
  /absolute/path/to/cohort-a.zip \
  /absolute/path/to/cohort-b.zip \
  /absolute/path/to/cohort-c.zip \
  --out-dir /tmp/noop-validation/cohorts

for cohort in /tmp/noop-validation/cohorts/export-*.json; do
  NOOP_WHOOP_CYCLES="$cohort" \
    swift test --package-path Packages/StrandAnalytics \
    --filter WhoopExportRecoveryComparisonTests
done
```

Full affected Swift packages:

```bash
swift test --package-path Packages/StrandAnalytics
swift test --package-path Packages/StrandImport
swift test --package-path Packages/WhoopStore
```

Production parser against one local archive:

```bash
NOOP_WEARABLE_EXPORT_ARCHIVE=/absolute/path/to/cohort-a.zip \
  swift test --package-path Packages/StrandImport \
  --filter WearableExportProductionParserTests

cd android
NOOP_WEARABLE_EXPORT_ARCHIVE=/absolute/path/to/cohort-a.zip \
  ./gradlew :app:testFullDebugUnitTest \
  --tests com.noop.ingest.WhoopExportProductionParserTest
```

Android migration/import regression and artifact checks:

```bash
cd android
./gradlew :app:testFullDebugUnitTest
./gradlew :app:assembleFullDebug
./gradlew lintFullDebug compileFullDebugAndroidTestKotlin
```

App and repository gates:

```bash
xcodebuild -scheme NOOPiOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild test -scheme Strand -destination 'platform=macOS'
python3 Tools/i18n_audit.py --ci origin/main
python3 Tools/check-private-data.py
python3 Tools/release-legal-gate.py check
python3 Tools/release-legal-gate.py distribution
git diff --check
```

`release-legal-gate.py distribution` must pass. It validates the owner-rights
record, NOOP license, and exact independent dependency notices.

## Remaining before production release

1. Complete signing, store metadata, privacy disclosures, and release controls.
2. Complete physical-device, overnight sync, background collection, haptic,
   HealthKit, Watch, Android OEM, and carrier paging validation.
3. Treat automatic medical/anomaly paging, fall detection, and accuracy claims
   as separate prospective validation and regulatory programs.
4. Acquire a wrist R-R plus respiration plus PSG dataset, improve wake
   sensitivity, and validate on a held-out cohort before making sleep-stage
   accuracy claims.
5. Run signed store archives, upgrade testing on backed-up physical devices,
   native-speaker review, production topology/load/restore exercises, and the
   controlled carrier delivery matrix.

## Privacy

Personal archives and prepared fixtures remain outside git. Do not place real
archive names, dates, row-level values, logs containing health rows, or
temporary outputs in documentation, commits, CI artifacts, or tickets.
