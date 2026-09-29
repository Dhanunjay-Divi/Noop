# Round: 2026-09-26 - Step cross-surface parity

## Status

- State: `local implementation and complete final repository wall green; exact-head hosted review, protected integration, and physical validation pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `7b72b5555f3e3b1e97314c849a60ffb51dcd3b47`
- Record commit or PR: application pull request `#17`

## Objective

Keep the tightened primary Steps source contract consistent in exact-day
calendar, workout overview, and fused-record surfaces. Imported Apple Health or
Health Connect counts may outrank classified band motion, while gravity-only
`steps_est` must remain a separately labelled estimate.

## Scope

### In scope

- Exact-day step-source arbitration on Apple and Android.
- Android Health Connect daily-step projection.
- Calendar, Workout detail, Today, and Fusion parity.

### Non-goals

- New gait inference, firmware classification, or heart-rate thresholds.
- Schema, permission, network, notification, or medical-claim changes.

## Starting evidence

- Today on Apple and Android already prefers an imported aggregate over a
  classification-gated band count and excludes `steps_est`.
- The owner repeated the concrete approximately 4,000-count head-washing
  false-positive report. The existing Swift/Kotlin regression for that exact
  stationary hand-motion sequence remains the governing acceptance test.
- Apple exact-day overviews read only the active/canonical band daily rows.
- Android exact-day overviews read the merged daily row, whose Health Connect
  projection does not currently carry steps.
- Android Fusion reads Health Connect `DailyMetric` rows, so it cannot resolve
  Health Connect steps until that owned projection includes the field.
- The currently integrated supplier-band app adapters expose pairing, battery,
  and live display heart rate only; they do not publish a supplier step stream
  into the repository. A physical report still needs its installed build and
  active step source identified before assigning the defect to firmware.

## Delivered

- Apple exact-day Calendar and Workout overviews now read the bounded
  Apple-Health aggregate for that day and prefer its pedometer count over the
  classified band counter.
- Android Health Connect now projects owned step totals into `DailyMetric`, so
  Fusion and detail surfaces see the same source that Today already resolves.
- The live Health Connect top-up atomically merges the exact total into both
  `AppleDaily` and `DailyMetric`, preserving unrelated columns and advancing
  metric invalidation for writes and owned-value deletions.
- Android Calendar and Workout overviews read exact-day Apple Health and Health
  Connect aggregates, prefer the most-complete imported count, and clear the
  prior day's value while the next day loads.
- Today separates the one-shot live provider read from metric-version-driven
  local reads, preventing the write from retriggering itself. Calendar and
  Workout detail treat an imported-step read failure as best effort and retain
  the day's classified band metrics.
- Apple Health and Health Connect choose the largest cumulative day total
  between those overlapping phone/watch stores rather than summing them.
  Band counters and estimated sources retain stable source priority and cannot
  win through the max rule merely by reporting a larger value.
- Exact-day rows now say `Phone/watch steps` or `Band steps` rather than
  collapsing measured provenance into a generic label. The two strings are
  generated for all nine supported locales on Apple and Android.
- No gravity-only estimate or heart-rate threshold was added to primary Steps.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance impact: imported pedometer totals retain precedence over
  classification-gated band counters; gravity-only estimates remain separate.
- Permissions/network disclosure impact: none.
- Health limitation: heart rate remains supporting wear/effort context, not
  gait proof. Imported totals cannot retrospectively validate their raw motion.

## Observability

This change adds bounded local reads and deterministic presentation
arbitration, not a new transport, persistence write, or background operation.
Existing import and database diagnostics remain the owning evidence. A failed
or absent exact-day read degrades to the already supported missing/fallback
state; no health values, dates, source identifiers, or payloads were added to
diagnostics.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Swift `StepsCounterTests` plus `FusionResolverTests` rerun | 42/42 passed | The exact 4,000-count head-washing sequence, classless fail-closed behavior, mixed locomotion, gaps, wrap handling, phone-health-store max arbitration, band-source priority, and estimate-source priority remain green | Whether physical firmware classifies that motion correctly |
| Android focused step/projection/Fusion/overview rerun | 58/58 passed with Full Debug app/test compilation | Kotlin parity for stationary-motion rejection, Health Connect projection, exact-day precedence, source refresh, and phone/watch-versus-band arbitration | Physical Android sensor or firmware behavior |
| Apple `DailyOverviewPresentationTests` | 8/8 passed | Imported-first exact-day arbitration, classified-band fallback, and source classification | Physical pedometer or firmware accuracy |
| Android Full Debug wall | 5,196 tests passed, 7 intentional skips, 0 failures; compile, lint, and APK assembly passed | The final Android source integrates with the broader app and release variant | OEM background behavior or physical sensors |
| App-wide localization audit | 50/50 passed | Both new provenance labels are generated and structurally aligned across Apple, Android, and nine locales | Professional translation review |
| macOS focused app test graph | Passed unsigned with 8/8 presentation tests | Shared Apple app code and exact-day presentation compile and execute | Signed distribution or runtime UX |
| iPhone Simulator Debug graph | Passed unsigned with Watch, complications, and widgets | Apple launch-target integration compiles | Physical Watch/iPhone behavior |
| Final repository policy controls | 370/370 Tools tests; 9 release checks; all 10 required contexts; trusted protected-main self-check; exact SDK artifact; legal distribution; 12-metric calibration parity; 99 operations records; private-data; 1,311-file claims scan; terminology and full localization all passed | The exact final local tree satisfies repository-controlled release contracts | External approval, signing, stores, hosted replacement checks, or hardware |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: local macOS build host and simulators only.
- Data-preservation result: no migration or destructive write.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: synchronized manual-count walking, stationary
  wrist-motion/head-washing, firmware classification, reconnect, and background.

## Git and release state

- Changed paths: Apple repository/detail UI/tests, Android Health Connect and
  exact-day UI/tests, reviewed terminology inventory pin, and operations
  records.
- Commits: the consolidated replacement containing this record is the PR `#17`
  candidate; its exact SHA is recorded by repository history and hosted checks.
- Branch and remote state: PR `#17` replacement candidate.
- Repository visibility verified: canonical protected repository unchanged.
- Version/build impact: no version change.
- Release or distribution impact: no artifact published or installed.

## Decisions

- Durable decision added or changed: none; this applies the existing
  imported-first primary Steps contract to missing surfaces.
- Decision-log entry: none required.

## Open risks and honest limitations

- Physical firmware classification and synchronized manual-count accuracy
  remain unverified.
- Hosted replacement checks and required non-author approval remain open.

## Next round

1. Verify exact-head protected checks and integrate normally after approval.
2. Run the documented physical step-accuracy matrix.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
