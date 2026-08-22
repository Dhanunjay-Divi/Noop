# Round: 2026-08-21 — Metric truth and Live Activity reliability

## Status

- State: `completed` for the scoped commit; broader Day-4 sync/performance work is open.
- Owner: project team
- Branch: `codex/day4-sync-performance`
- Start commit: `d2b201c5`
- End implementation commit: `241f2000`
- Remote: private repository branch verified at the same commit after push.

## Objective

Carry the truthful metric-resolution and Live Activity work onto the newer NOOP
9.2 integration branch without regressing its performance, theme, or safety
improvements, then publish that bounded delta to a private branch.

## Scope

### In scope

- Measured-versus-estimated step resolution and source-pinned metric details.
- Source-specific empty-state guidance.
- Deterministic Live Activity selection, freshness, duplicate cleanup, and app
  lifecycle reconciliation.
- Focused tests, iOS Simulator build, privacy/i18n checks, and a private push.

### Non-goals

- Diagnosing the later Day-4 3/4 calibration report.
- Profiling scrolling on a physical phone.
- Changing BLE backfill, SQLite storage, or score formulas.
- Claiming WHOOP score parity or public-distribution readiness.

## Starting evidence

- The newer integration branch already contained the broader 9.2 evidence-first
  and performance work.
- Incoming metric and Live Activity changes overlapped newer code and required
  semantic conflict resolution rather than blind replay.
- No physical-device sync or scrolling trace was part of this round.

## Delivered

- Preserved measured Apple Health/Health Connect steps ahead of WHOOP motion-
  derived estimates and calibrated fallback values.
- Kept Today/detail routing source aware and maintained truthful unavailable
  guidance.
- Added a pure deterministic Live Activity selection helper and tests.
- Preserved the newer serialized, generation-fenced Live Activity controller
  while adding adoption and duplicate cleanup across launch, foreground, and
  preference changes.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none; no database, container, or app uninstall
  action occurred.
- Provenance impact: stronger measured-versus-estimated and source labeling.
- Health claim impact: none; no metric was promoted to clinical or vendor parity.
- Private-data scan found no secrets, device identifiers, or local paths in the
  published delta.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused source/metric/Live Activity tests | 21/21 passed | Resolver and pure lifecycle-selection contracts | Physical ActivityKit lifecycle or BLE behavior |
| Unsigned generic iOS Simulator build | Passed | iOS target compiled with the integrated source | Signing, install, scroll performance, BLE, background delivery |
| i18n audit | Passed | No new focus-locale extraction regression | Copy quality in every locale |
| Private-data scanner and `git diff --check` | Passed | Published text/diff met repository hygiene checks | Runtime privacy behavior |
| Private remote hash check | Local and remote `241f2000` matched | The intended commit reached the private branch | Public release readiness |

## Physical device and deployment

- Install/update action: not run in this scoped round.
- Physical-device validation: not run.
- Data-preservation result: no device mutation occurred.
- Unrun gates: overnight offload, Day-4 scoring, real-device scroll profiling,
  signing/trust, haptics, battery, and background transitions.

## Git and release state

- Changed paths: eight Swift production/test paths.
- Commit: `241f2000`.
- Branch: `codex/day4-sync-performance`, pushed to the private repository.
- Version/build impact: none in this commit.
- Distribution impact: none; public distribution legal clearance remains open.

## Decisions

- Newer integration behavior won when an older incoming hunk would regress
  source truth, lifecycle serialization, or performance.
- Simulator evidence was recorded as compile/UI evidence only.

## Open risks and honest limitations

- The user's later screenshot shows 3/4 recovery calibration on Day 4, but this
  commit does not touch the path that could explain it.
- The reported physical-phone lag has not been profiled.
- Metric/capability breadth remains constrained by sensor inputs, validation,
  platform scheduling, proprietary formulas, and regulated-feature boundaries.

## Next round

1. Reproduce and instrument the Day-4 missing-night path without deleting data.
2. Profile scrolling and database/query work on the physical iPhone.
3. Refresh the official-source competitor audit and prioritize only evidence-
   supportable gaps.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
