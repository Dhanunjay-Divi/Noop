# Round: 2026-09-26 - Step evidence source correction

## Status

- State: `exact implementation checkpoint pushed and all ten required hosted
  contexts green; requested non-author review, protected integration/main
  verification, and physical validation pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `8da3ebf4c2d0fecc4cd924e81b27f60bb90ab106`
- End implementation commit:
  `6c7d3fa2b1e7f744774a89a942465ff1aa137216`
- Record commit or PR: application pull request `#17`

## Objective

Prevent stationary wrist movement, including bathing and head washing, from
publishing primary Steps. Correct the source contract after finding that the
same historical-record byte is currently interpreted as both wear/contact
quality and still/walk/run activity. Keep heart rate as wear and effort context,
not as proof that motion is gait.

## Scope

### In scope

- Remove the disputed historical byte from gait authority on Apple and Android.
- Make customer-facing band-counter Steps fail closed until a validated
  pedometer or supplier step stream exists.
- Remove the same byte from wake refinement, workout-type classification, and
  Today activity glyphs.
- Preserve imported Apple Health and Health Connect pedometer totals as the
  primary measured sources.
- Add mirrored regressions for a 4,000-tick stationary sequence whose legacy
  byte values falsely resemble walking or running.
- Record bounded aggregate diagnostics without raw counters, health values,
  timestamps, or identifiers.

### Non-goals

- Inventing a heart-rate, cadence, or gravity threshold without synchronized
  physical ground truth.
- Deleting historical rows or changing the database schema.
- Claiming physical step accuracy, firmware semantics, or supplier SDK support
  from simulator and unit-test evidence.

## Starting evidence

- Reproduction or observed symptom: a user reported approximately 4,000 added
  steps during a head bath and additional counts from ordinary hand movement.
- Relevant source/device/OS/firmware class: current compatible-band historical
  records expose a cumulative motion counter at byte 57 and a raw byte at 63.
- Existing tests, logs, exports, screenshots, or documents: prior regressions
  reject a 4,000-tick sequence only when byte 63 is labelled still. They do not
  reject the same stationary sequence when byte 63 contains 1 or 2.
- Unknowns that must remain unknown until measured: byte 63 semantics, byte 59
  cadence units, counter-to-step calibration, and physical false-positive and
  false-negative rates.

## Delivered

- Apple and Android protocol extraction no longer turns historical-record byte
  63 into a still/walk/run class. The byte remains available only as raw
  `motion_wear_quality`; the cumulative counter at byte 57 remains stored as
  unverified motion with no gait label.
- Swift and Kotlin now have an explicit production policy,
  `rejectUnverifiedBandMotion` / `rejectUnverifiedBandCounter`. It records that
  a counter was observed and counts rejected deltas in bounded diagnostics, but
  publishes no ticks or Steps regardless of legacy 0/1/2 values.
- Production daily analysis, intelligence recomputation, wake refinement,
  workout-type feature extraction, manual-workout summaries, and Today
  presentation no longer authorize gait from the disputed field. Heart rate
  remains wear and effort context and cannot convert wrist motion into steps.
- Primary Steps on Apple and Android Today, Liquid Today, Health detail,
  Calendar/day overview, Workout day overview, and their 14-day trends now
  accepts only same-day imported Apple Health or Health Connect pedometer
  evidence. Legacy band motion and calibrated gravity estimates remain
  retained only for diagnostics/export, are hidden from customer metric
  pickers, and cannot fill a blank primary Steps value.
- Generic Apple/Health Connect metric resolution no longer falls back to a
  computed band-motion Steps row. Active energy keeps its independent computed
  fallback.
- Apple and Android no longer expose the raw-counter "Step calibration" control.
  The separate motion-based estimate remains explicitly labelled as an
  estimate and cannot publish primary Steps.
- The motion-aware wake control is retired on Apple and Android. Production
  call sites pass `false`, stale preferences cannot reactivate it, and the
  withdrawn algorithm is reachable only through an explicit synthetic/research
  parameter.
- Android manual-workout Steps now remain missing because no validated,
  inexpensive windowed pedometer source is wired there; the unverified band
  counter and elevated heart rate cannot fill the value.
- A successfully read band-counter day clears stale NOOP-computed `steps` and
  `steps_est` values across validated `-noop` source namespaces. Imported Apple
  Health and Health Connect rows remain outside the cleanup boundary.
- The cleanup also checks alternate registered day sources with a bounded
  one-row probe when an import owns the usable heart-rate day, preventing an
  old band-derived value from surviving only because the band did not own the
  score window.
- Swift and Android transactional APIs reject imported primary identifiers
  before any score or step cleanup mutation. The Android regression is present
  in both the JVM transaction fixture and the in-memory Room instrumentation
  suite.
- Mirrored regressions cover the reported 4,000-tick stationary sequence,
  legacy walk/run-looking byte values, classless data, source-scoped cleanup,
  alternate HR ownership, and preservation of imported rows.
- Swift and Android decoder oracle copies are synchronized without the removed
  activity class.

## Data, privacy, and medical truth

- Schema or migration impact: none; the legacy nullable activity-class column
  remains for compatibility but has no production authority.
- Existing-data retention impact: raw sensor rows are retained. Derived
  NOOP-computed daily Steps and `steps_est` rows are cleared for days where the
  unverified counter was observed. Imported pedometer rows are preserved.
- Source/provenance or formula impact: primary band-counter step eligibility is
  tightened; imported OS pedometer totals retain precedence and validity.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: no medical claim. Heart rate may
  support effort or wear context but cannot authorize a step.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: the existing
  bounded step-analysis trace records the fixed
  `unverifiedBandMotion` / `unverifiedBandCounter` mode and aggregate accepted,
  rejected, flat, reset, and gap counts.
- Why existing evidence is sufficient, or why new evidence is required: the
  new fixed mode distinguishes production rejection from class-missing and
  explicit legacy research analysis without recording raw motion or health
  values.
- Existing evidence reused: platform app diagnostics and step-analysis aggregate
  trace.
- New bounded events or operation spans: no new high-frequency event. The
  existing one-per-analysis aggregate trace gains the fixed rejection mode.
- Redaction, retention, and high-frequency controls: no per-sample logging and
  no raw values, timestamps, identifiers, or health values.
- Cross-platform/backend correlation: Apple and Android use the same policy
  name and counters; managed history may retain the legacy field but formulas
  must not consume it.
- Remaining blind spots: firmware meaning and physical accuracy remain opaque
  until synchronized device validation.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Source/provenance audit | Complete for the changed Apple/Android protocol, analytics, intelligence, wake, workout, storage, and Today paths | The disputed byte is no longer a production gait authority | Physical sensor semantics |
| Swift protocol wall | 406 tests pass, 1 opt-in corpus test skipped | Historical extraction and the synchronized oracle omit the disputed activity class | Real firmware behavior |
| Swift analytics wall | 1,513 tests pass, 7 documented skips | Production rejection, wake/workout consumers, traces, and stationary 4,000-tick vectors behave deterministically | Physical false-negative rate |
| Swift storage wall | 555 tests pass, zero failures | Computed cleanup is transactional, source-scoped, and rejects imported targets before mutation | Device collection continuity |
| Apple app/data tests | 75/75 pass across `ReadSpineActiveDeviceTests` and `IntelligenceDaySourceTests` | Alternate day ownership, imported-row preservation, stale computed cleanup, and app orchestration agree | Signed-device HealthKit or BLE behavior |
| Apple primary-Steps presentation tests | 25/25 pass across day overview, metric catalog, and provenance safety | Today/detail/day-overview routing and values cannot fall back to motion-only evidence | Physical pedometer accuracy or permission behavior |
| iOS Simulator graph | `NOOPiOS` build succeeds with Watch app, complications, and widgets embedded and validated | The final shared source compiles in the complete iPhone/Watch/widget graph | Installation, signing, background collection, Watch delivery, or performance |
| Exact-head macOS app wall | 2,358 tests pass with 1 intentional fixture skip and zero failures | The exact pushed shared/app source passes the complete unsigned macOS test graph | Signed installation, physical BLE, or production performance |
| Android primary-Steps focused wall | 75 tests pass across Today, day overview, Health detail merge, provenance safety, and counter policy | Every customer-facing primary Steps surface rejects motion-only data | OEM pedometer or physical BLE behavior |
| Android complete unit wall | 5,213 tests pass, 7 intentional skips; Full and Demo Kotlin, Full instrumentation source, lint, and Full APK assembly pass | Kotlin protocol, analytics, repository, UI, and both flavors remain coherent | OEM or physical BLE behavior |
| Android Room instrumentation source | `compileFullDebugAndroidTestKotlin` succeeds | The in-memory Room imported-target regression compiles against the real database implementation | Emulator/runtime execution or physical accuracy |
| Complete Tools wall | 372 tests pass, 1 intentional skip | Release, trust, artifact, policy, and bounded-runner regressions remain coherent | Hosted checks or physical behavior |
| Standalone repository controls | Health claims 1,312 files; localization; private-data; 12-metric calibration; 9 release checks; 10 required contexts; trusted self; exact 10-file SDK artifact; legal inventory/distribution; 18,508 classified terminology occurrences across 1,629 groups with zero forbidden mappings; 101 operations records all pass | The current source satisfies the repository's independent source-control gates | Exact-head hosted execution, review approval, signed distribution, or launch |
| Exact-head hosted checks | Commit `6c7d3fa2` passes all 10 required contexts; Apple run `36264295238`, Android run `36264295298`, package run `36264295274`, and the policy/server runs are green | The exact remote source satisfies protected hosted source and build gates | Non-author approval, protected integration, physical behavior, signing, or launch |
| Diff hygiene | `git diff --check` passes | The local patch has no whitespace errors | Hosted policy or protected integration |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: macOS XCTest host, iOS Simulator
  compilation, Android JVM tests, and Android instrumentation-source
  compilation.
- Data-preservation result: raw rows and imported pedometer rows are preserved;
  stale NOOP-derived step fields are intentionally removed.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: synchronized stationary hand movement, bathing/head
  washing, walking, running, driving, cycling, phone pedometer comparison, and
  supplier-native step-stream comparison.

## Git and release state

- Changed paths: shared protocol, analytics, storage, intelligence,
  presentation, mirrored tests/fixtures, BLE documentation, and operations
  records. Concurrent supplier/pairing paths remain separately owned.
- Commits: implementation checkpoint
  `6c7d3fa2b1e7f744774a89a942465ff1aa137216`.
- Branch and remote state: local and remote branch point to the same exact
  checkpoint. Pull request `#17` is open and mergeable, all ten required hosted
  contexts pass, and the requested non-author review remains pending.
- Repository visibility verified: canonical repository is public.
- Version/build impact: none planned.
- Release or distribution impact: no artifact or production traffic.

## Decisions

- Durable decision added or changed: unverified historical motion bytes cannot
  authorize primary Steps or gait-dependent features.
- Decision-log entry: not required. This enforces the existing provenance and
  missing-data contracts rather than adding a new product authority.

## Open risks and honest limitations

- Removing false-positive authority may make Steps unavailable when OS
  pedometer access is absent. Missing is safer than publishing stationary hand
  motion as walking.
- A validated supplier/native step stream can restore band-only Steps later
  without re-authorizing the disputed raw byte.

## Next round

1. Obtain the requested non-author approving review without bypassing protected
   integration.
2. Integrate through protected `main` and verify all required contexts on the
   resulting exact mainline commit.
3. Remove only the exact round-owned generated outputs after the evidence is
   durable.
4. Execute the physical-device validation matrix before any accuracy claim.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
