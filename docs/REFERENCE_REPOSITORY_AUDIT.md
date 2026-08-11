# Reference repository audit

Audit date: 2026-08-11

This document records the external projects inspected while improving NOOP. The
checkouts live outside this worktree in a machine-local reference directory whose
absolute path is intentionally not recorded; they are research inputs, not build
dependencies. Exact revisions are pinned in `reference-repositories.lock.json`.

## Ground rules

- Clone broadly, but never add a reference checkout to an app target, package
  search path, container context, or release artifact.
- Copy source only when its license clearly permits the intended use. Retain the
  complete notice and record the exact source revision and files.
- Treat AGPL, unlicensed, and ambiguously licensed implementations as behavioral
  references only. Algorithms, published equations, file-format facts, and BLE
  wire facts must be independently expressed and tested.
- Never import sample health exports, secrets, participant datasets, model
  weights, fonts, or artwork merely because the surrounding code is licensed.
- Do not run third-party install scripts, Gradle wrappers, notebooks, Actions, or
  containers as part of this audit.

## Inventory and useful lessons

| Project | License posture | Most useful lesson for NOOP |
|---|---|---|
| `ryanbr/noop` | PolyForm Noncommercial; inherited-code provenance requires care | Direct upstream fixes, parity tests, BLE research and current product baseline |
| `OpenStrap/edge` | MIT | Mobile BLE lifecycle, HealthKit/Health Connect and background-sync comparison |
| `OpenStrap/protocol` | Ambiguous: root MIT; package metadata ISC | Independently testable WHOOP 4 protocol package and decoder fixtures; concepts only until upstream reconciles the terms |
| `OpenStrap/analytics` | MIT | Honest metric envelopes, input coverage, confidence tiers, signal quality and published algorithms |
| `HealthyApps/health-auto-export-server` | No root license; package metadata alone is ambiguous | Grafana-oriented Apple Health ingestion; concepts only |
| `krumjahn/health-dashboard` | No license | Simple portable dashboard; do not adopt its public-health-JSON hosting model |
| `krumjahn/applehealth` | MIT intent but no license file | Local Apple Health reporting and LLM workflow; independently implement ideas |
| `the-momentum/open-wearables` | MIT | Provider capability registry, normalized records, OAuth/webhook lifecycle and sync cursors |
| `woop/awesome-quantified-self` | CC0 index | Discovery only; every linked project keeps its own license |
| `wger-project/wger` | AGPL-3.0 | Exercise catalog, routines, sets/reps, nutrition and weight workflows; concepts or separate service only |
| `endurain-project/endurain` | AGPL-3.0 | FIT/GPX/TCX ingestion, self-hosted endurance analytics and route UX; concepts only |
| `RuochenLyu/apple-health-analyst` | MIT | Coverage-aware Apple Health parsing, reconciliation and training-load reports |
| `markwk/qs_ledger` | MIT, dormant | Historical connector/notebook patterns; modernize rather than embed |
| `ashishworkacc/life-tracker` | AGPL-3.0 | Journal, habit, reminder and correlation flows; concepts only |
| `jimmykane/quantified-self` | AGPL-3.0 | Provider lifecycle, performance curves and training-load exploration; concepts only |
| `b-nnett/goose` | No license | WHOOP 5 observations and behavior only; no source/assets |
| `tigercraft4/goose` | PolyForm Noncommercial for original additions only | Self-hosted upload comparison; inherited Goose code needs separate provenance |
| `johnmiddleton12/wearable` | No license | Provenance review for inherited WHOOP 4 code; facts-only unless permission is obtained |
| `muftiarfan/noop` | No license | Fork-lineage review for `ryanbr/noop`; facts-only unless permission is obtained |

## What NOOP already does better

NOOP is already broader than any one reference: native WHOOP 4/5 and Oura BLE,
local SQLite scoring, Apple Health and Health Connect, portable imports, raw
research capture, sleep/recovery/effort, local insights, optional self-hosting,
friends, watch surfaces, iOS/macOS/Android parity tests, backups, and explicit
source provenance. Replacing NOOP wholesale with another project would lose more
than it gains.

## Correctness work before more surface area

1. **Effort integration:** integrate every adjacent HR interval using its actual
   duration and cap sensor gaps. A single stale sample must not earn minutes or
   hours of load.
2. **Training load:** keep ACWR only as a descriptive ratio, add transparent
   additive daily load plus CTL/ATL/TSB, and remove fixed injury-risk promises.
3. **Nutrition units:** normalize imported weight to kilograms from explicit
   headers/units and reject ambiguity instead of storing pounds as kilograms.
4. **HealthKit workouts:** retain workout-scoped HR and coverage-qualified zones/Effort where
   HealthKit supplies them. Precise workout routes are deliberately excluded from general Health
   access until NOOP has a separate opt-in and protected, bounded, erasable storage design.

## Next architecture improvements

### One metric contract

Every derived metric should eventually carry:

- value and canonical unit;
- source/device/firmware and detector version;
- confidence and evidence tier (`measured`, `high`, `estimate`, `relative`);
- input coverage and missing-input reasons;
- baseline window and time zone;
- whether the value is provisional, corrected, imported, or independently
  computed.

This prevents a dashboard from making weak or unavailable inputs look as certain
as direct measurements.

### Workout Detection V2

- Preserve the low-power HR/motion gate.
- Feed the existing WHOOP 5/MG 100 Hz accelerometer/gyroscope energy, jerk,
  rotation and cadence features into a versioned retrospective classifier.
- Use temporal states and specialist classifiers, not isolated labels.
- Preserve `Unknown`, show top suggestions, and learn from accepted, rejected,
  boundary-edited and sport-corrected episodes.
- Validate with participant/day/device-held-out data and report false starts per
  wear-hour, event precision/recall, boundary error, unknown rejection,
  calibration and battery impact.

The evidence, validation gates and separate fall-safety boundary are detailed in
[`DETECTION_VALIDATION_PLAN.md`](DETECTION_VALIDATION_PLAN.md).

### Device capability registry

Model each source by what it can actually deliver: continuous versus banked,
sample rate, HR/RR/IMU/GPS/temperature/SpO2 availability, background behavior,
provenance, authorization and latency. The UI should say `live`, `after sync`,
`import only`, or `unavailable`; it should never imply fake parity.

### Portable data and self-hosting

Replace fragmented exports with one versioned manifest containing provenance,
canonical units, checksums, deletion tombstones and restore support. Extend the
self-hosted protocol beyond archival upload only after round-trip restore and
conflict tests exist.

### Strength and nutrition

Treat strength sets/reps/routines and food/meal detail as separate optional
modules. Do not make the core physiological pipeline dependent on a large food
database or AGPL service. Prefer user-owned imports and clearly versioned local
schemas.

## Safety and provenance blocker

The existing `ATTRIBUTION.md` and `NOTICE` say portions of `WhoopProtocol`,
`WhoopStore`, and collection logic were adapted from the unlicensed
`johnmiddleton12/my-whoop` repository (now `johnmiddleton12/wearable`).
Attribution is not permission. Both lineage repositories are pinned in the local
reference inventory for comparison, but their source is not an allowed copy
source. Before claiming that the entire tree has clean
redistribution rights, obtain written permission/a retroactive license or
clean-room replace the inherited expression using protocol facts and owned-device
fixtures.

This does not prevent local research or independent improvements, but it does
prevent a responsible project from saying “licenses do not matter.” Provenance is
part of making NOOP clean.

## Upstream synchronization

At audit time the custom branch is eight commits ahead and 343 commits behind
`ryanbr/noop/main` by history. The custom beta work is a large squash touching
hundreds of files, so a blanket merge produces extensive conflicts and is not a
safe update strategy. Port upstream fixes in tested, reviewable slices while
retaining the local-first UI, backend, friends, onboarding and beta workflow.

### Previously pending fixes verified

The upstream pull requests called out in the prior watch list are no longer
pending: GitHub reports all of them merged. Their behavior and regression seams
are already present in this custom tree, so this branch does not re-copy or
re-cherry-pick them:

| Upstream PR | Behavior verified in this tree |
|---|---|
| [#1066](https://github.com/ryanbr/noop/pull/1066) | Android waits for the MTU operation to settle, generation-checks the delayed service-discovery kick, and tests stale/replaced GATT rejection. |
| [#1123](https://github.com/ryanbr/noop/pull/1123), [#1125](https://github.com/ryanbr/noop/pull/1125), [#1145](https://github.com/ryanbr/noop/pull/1145) | Swift and Kotlin count empty and stalled offloads toward backoff, preserve productive continuation tails, and guard auto-continuation on rows actually persisted. |
| [#1138](https://github.com/ryanbr/noop/pull/1138) | The iOS reject-history archive and replacement receive `completeUntilFirstUserAuthentication` protection for locked background sync. |
| [#1107](https://github.com/ryanbr/noop/pull/1107) | Oura banked timestamps are capped against an injected current clock and already-stored future R-R rows are quarantined by additive database migrations. |
| [#1108](https://github.com/ryanbr/noop/pull/1108) | HRV beat-value trust is gated separately from timestamp coverage in scoring, sleep, rhythm screening and both platform test suites. |
| [#1154](https://github.com/ryanbr/noop/pull/1154) | WHOOP 5/MG battery reads are throttled and known-empty history polling stretches to the low-power interval on Apple and Android. |

This is source/test verification, not a substitute for owned-hardware validation.
WHOOP 5/MG offload, battery, background reconnection and firmware-specific paths
still need a real-device matrix before a release can claim them as validated.

### Bounded ports completed in this integration branch

These changes were ported as reviewable slices with Swift/Kotlin fixtures instead
of merging the 343-commit history gap:

| Upstream PR | Integrated behavior |
|---|---|
| [#475](https://github.com/ryanbr/noop/pull/475) | WHOOP RMSSD is no longer written or exported as Apple Health SDNN. Apple SDNN remains readable, and legacy NOOP-authored mislabelled samples are removed when HealthKit permits it. |
| [#869](https://github.com/ryanbr/noop/pull/869) | Android keeps unsigned-u32 historical timestamps and record indices as `Long` through production consumers, with post-2038 decoder oracles. |
| [#895](https://github.com/ryanbr/noop/pull/895) | WHOOP 5 optical-v20 records are CRC16/CRC32-gated and decode signed samples/configuration against the same deterministic synthetic golden vectors on Swift and Kotlin; no captured biometric data is committed. |
| [#957](https://github.com/ryanbr/noop/pull/957) | Standalone diagnostic logs/raw captures fail closed on binary or malformed input, are PII-scrubbed and capped at 20 MB, and require an explicit review/confirmation before interactive sharing. Normal user health exports are unchanged. |
| [#959](https://github.com/ryanbr/noop/pull/959) | Apple Health starts with a smaller core permission request; body composition, detailed write-back and cycle data remain separate explicit choices. RMSSD/SDNN semantics are stated at the permission surface. |

This branch also hardens the existing auto-workout rules against invalid BPM,
duplicate timestamps, telemetry gaps and sparse motion. Candidates now expose a
fixed detector version, input provenance and an explicitly uncalibrated event
confidence rather than inventing a probability. The change is replay-tested on
both platforms, but it is not a claim of held-out or owned-hardware accuracy.

### Still open after this pass

- WHOOP 4 R-R overcounting in [#1118](https://github.com/ryanbr/noop/pull/1118)
  needs a fixture-backed port and owned-hardware replay before changing stored HRV.
- HealthKit deleted-workout reconciliation must distinguish authorization denial
  from a genuine deletion before removing local workouts.
- HealthKit incremental queries currently bound their look-back window to 31 days.
  Samples or deletion notifications outside that window can leave a local row
  stale unless the user performs a full re-import. A release-ready fix needs a
  durable source identifier/tombstone reconciliation path, not a wider arbitrary
  look-back.
- Sleep imported from more than one HealthKit writer can overlap. The current
  aggregation does not yet reconcile competing source episodes, so totals must
  not be presented as source-independent truth until interval/source de-duplication
  and conflict tests are in place.
- Shortcut/automation Health exports have no producer acknowledgement protocol.
  Replaying the same file can duplicate work at the transport boundary, and local
  wall-clock timestamps around daylight-saving transitions are ambiguous. Add a
  stable export ID, idempotency ledger, acknowledged consumption and explicit UTC
  offsets before treating unattended Shortcut ingestion as exactly-once.
- Apple Health heart-rate write-back intentionally revisits only the most recent
  48 hours. Late corrections older than that window are not repaired automatically;
  a bounded manual reconciliation operation is still needed.
- The iOS app still constructs its BLE manager before Terms acceptance even though
  scan/connect/background hooks are gated; making construction lazy needs a focused
  lifecycle refactor and device test. Android now defers its BLE view model/hooks.
- Training-load CTL/ATL/TSB exists as a tested additive analytics foundation, but
  must not enter the dashboard until a real additive daily-load pipeline and
  migration are wired. Nonlinear daily Effort/strain is not additive input.
- Fall detection remains research-only planning. No emergency or fall-detection
  claim is implemented.
- Complete third-party dependency notices and the inherited unlicensed WHOOP 4
  provenance blocker above remain release gates.
- This fork is private. Its raw GitHub `altstore-source.json`, icon and release
  assets cannot be fetched anonymously by AltStore/SideStore or friends. Release
  automation now refuses to publish the AltStore entry unless GitHub reports the
  repository as public; an intentionally public HTTPS host for all three assets
  is the alternative. Private releases remain collaborator-only.
- Android release and staging-release variants now fail closed without a private
  signing identity supplied through gitignored local configuration or four CI
  secrets. The tracked `android/fork-debug.keystore` has public credentials and
  is no longer used by Gradle or release workflows; it remains untrusted,
  forgeable historical material. Local debug builds remain available but are
  disposable and are not a distribution/update identity.
- Moving existing `com.noop.whoop.staging` users from the historical public key
  to the private staging key is a signing-identity migration, not an in-place
  update. Testers must export and verify a backup before uninstalling the old
  app, then restore it into the new install. The private key must be kept durable
  and backed up or future Android updates will break again.

## Integration validation record

The following gates passed from this branch on 2026-08-11:

- `StrandAnalytics`: 1,208 tests, zero failures.
- `WhoopProtocol`: 402 tests, zero failures and one environment-gated optional
  test skipped.
- `StrandImport`: 219 tests, zero failures and one environment-gated optional
  Xiaomi-export test skipped.
- Android `testDemoDebugUnitTest` and `testFullDebugUnitTest`: both variants
  completed successfully.
- iOS `NOOPiOS` Debug build for the selected iPhone simulator: successful with
  code signing disabled.
- macOS `Strand` Debug `build-for-testing`: successful with code signing
  disabled. A focused app-hosted workout automation policy test also passed.
- Focus-locale audit, JSON/XML/workflow-YAML parsing, reference-lock SHA checks,
  credential/private-key pattern scan and `git diff --check`: successful.
- Swift and Android optical-v20 oracles are byte-identical, fully synthetic and
  explicitly declare that they contain no captured biometric data.

These are source, simulator and unit-test gates. They do not validate real
WHOOP/Oura/HealthKit background behavior, firmware compatibility, battery cost,
workout accuracy, fall safety, signing, installation or upgrade preservation on
owned hardware. The Apple builds also retain pre-existing deprecation and Swift
6 actor-isolation warnings; compilation is green, but the tree is not
warning-clean or Swift-6-readiness complete.
