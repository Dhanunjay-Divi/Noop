# Round: 2026-09-26 - Step release and app-report scroll

## Status

- State: `local implementation and verification complete; one push, exact-head
  hosted checks, protected review, integration, and physical validation pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `d775d7c36bed7795f67ff447f0a8d645625be5ba`
- Record commit or PR: application pull request `#17`

## Objective

Move the already-reviewed stationary-motion step rejection toward protected
mainline by correcting the one current hosted iOS UI regression. Preserve the
existing rule that heart rate is supporting wear and effort context, not proof
that wrist motion is walking.

## Scope

### In scope

- Confirm whether the reported hand-motion/head-washing inflation is still
  possible on protected `main`.
- Preserve the shared Swift/Kotlin rejection of still and unclassified motion.
- Reset the iOS app-report sheet to the visible top of each newly rendered
  phase so the reviewed attachment summary is immediately reachable.
- Run focused Apple UI and shared step verification before any push.
- Reconcile the PR and active operations records with exact evidence.

### Non-goals

- Inventing a heart-rate threshold for step detection.
- Claiming firmware classification or physical step accuracy without a
  synchronized band capture and manual count.
- Bypassing branch protection or required non-author review.
- Enabling supplier binaries, public traffic, or production health transfer.

## Starting evidence

- Protected `main` is still based at
  `9c5141754f65d46eb69dcea8807ba3bdb29ca3a1` and does not contain the shared
  stationary-motion step correction.
- PR `#17` head
  `d775d7c36bed7795f67ff447f0a8d645625be5ba` contains the correction but the
  hosted iOS production shell failed
  `testAppReportRequiresConsentAndBuildsPrivateAttachmentReview`.
- The failure occurred after tapping the initially off-screen Build report
  action: SwiftUI retained the old low scroll offset when replacing consent
  content with the review phase, leaving the report-ready summary outside the
  visible accessibility window.
- Existing shared tests reject exact 4,000-tick bursts when activity is still
  or classification is absent. Physical firmware can still require separate
  tuning if it labels stationary wrist motion as walk/run.

## Delivered

- Primary Steps on Apple and Android now accepts only an imported pedometer
  total or a classification-gated band counter total. Gravity-only calibrated
  motion no longer fills the Today value, dashboard row, key-metric trend, or
  primary Steps detail.
- The calibrated gravity model remains available as the explicitly separate
  `Steps estimate` metric. This preserves calibration and diagnostics without
  presenting wrist movement as gait.
- Apple and Android primary Steps details now route to `steps`; a missing
  primary source can no longer fall back to `steps_est` after the user taps a
  blank card.
- Added mirrored Swift and Kotlin regressions for a variable-delta,
  multi-sample head-washing/hand-gesture sequence that advances the raw counter
  by exactly 4,000 while activity remains still. Both implementations reject
  every delta and publish no steps.
- Preserved the existing exact 4,000 stationary-burst and current classless-
  burst regressions. Heart rate remains useful for wear and effort context but
  cannot independently authorize a step.
- The iOS app-report sheet now moves to a phase-specific top anchor when
  consent becomes review, upload, success, or failure. The generated attachment
  list and report-ready state therefore remain visible and accessible after
  building a report from an initially scrolled consent view.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: primary Steps source eligibility is
  tightened; no new physiological formula, heart-rate threshold, or fabricated
  cadence rule is introduced.
- Permissions/network disclosure impact: none.
- Health/medical claim impact: none. Steps remain source-labelled estimates
  where the hardware exposes motion rather than validated pedometer evidence.

## Observability

- Existing bounded step diagnostics retain fixed counts for accepted,
  still-rejected, unknown-rejected, and gap-rejected deltas.
- No raw counter values, health values, timestamps, or identifiers will be
  added to normal logs.
- The physical validation handoff remains the authority for bathing, ordinary
  hand motion, walking, running, driving, and cycling false-positive tests.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| iOS app-report UI suite | 3/3 pass, zero failures | Consent, report build/review, screenshot removal, and cancellation remain reachable after the phase-scroll correction | Signed-device sharing or production upload |
| Apple app metric tests | 22/22 pass, zero failures | Primary Steps value, route, and sparkline omit calibrated-only motion | Physical sensor classification |
| Swift analytics step suites | 76/76 pass, zero failures | Still, classless, gap/reset, calibration, trace, and explicit head-washing gesture vectors behave as specified | Real firmware labels or cadence accuracy |
| Android focused step/Today/detail suite | 104/104 pass, zero failures | Kotlin counter, daily analytics, transactional integrity, Today values, and primary detail merge match the source contract | OEM background behavior or physical BLE |
| Final iOS Simulator build | Build succeeded | The final shared Apple source compiles in the complete iPhone app graph | Signing, installation, Watch delivery, or device performance |
| Repository policy controls | 82/82 focused control tests; 10 required contexts; 9 release controls; trusted self-verification and exact 10-file SDK artifact verification pass | The terminology repin, workflow contract, release policy, and supplier artifact boundary remain enforced | Hosted exact-head execution or physical behavior |
| Terminology, localization, claims, and operations | 18,532 classified occurrences across 1,628 groups, zero forbidden mappings, customer count unchanged; no new hardcoded copy; 1,310 files clear the health-claims gate; 98 operations records validate | The final source and records preserve brand, localization, claims, privacy, and operations ratchets | Human translation quality or regulatory approval |
| Local diff hygiene | `git diff --check` passes | The patch contains no whitespace errors | Hosted policy or product behavior |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: local macOS tests plus iOS Simulator
  compilation and UI automation.
- Data-preservation result: no schema or stored-data mutation.
- BLE/background/haptic/battery scenarios exercised: not run.
- Remaining physical matrix: synchronized manual count versus band output for
  bathing/head washing, ordinary gestures, walking, running, driving, cycling,
  reconnect, background collection, and firmware activity classification.

## Git and release state

- Changed paths: shared Apple and Android Today/Steps presentation, Android
  primary detail projection, iOS app-report scrolling, mirrored regressions,
  reviewed terminology snapshots/digests, and operations records.
- Commit: pending the one consolidated replacement commit.
- Branch and remote state: remote PR `#17` remains at
  `d775d7c36bed7795f67ff447f0a8d645625be5ba`; the verified replacement is
  local until repository controls pass.
- Protected state: auto-merge remains armed, but non-author approval and a
  green exact replacement head are still required.
- Release/deployment impact: no signed artifact, store submission, public
  traffic, or production health transfer.

## Decisions

- Heart rate is not accepted as gait proof. It may corroborate wear and effort,
  but low heart rate can occur during walking and elevated heart rate can occur
  while stationary.
- Primary Steps and calibrated motion estimate are separate product concepts.
  A calibrated gravity estimate remains inspectable but cannot silently fill a
  gait metric.
- No durable decision-log entry is required because this enforces the existing
  source/provenance and health-truth contracts rather than changing product
  authority.

## Open risks and honest limitations

- A firmware activity class that falsely reports bathing motion as walking
  cannot be corrected safely from heart rate alone.
- Raw high-rate IMU or a physically validated firmware cadence signal may be
  required if synchronized captures prove activity-class false positives.
- Signed-device, physical BLE, background collection, battery, and metric
  accuracy remain external gates.

## Next round

1. Create and push one consolidated replacement commit.
2. Inspect every required exact-head hosted context and obtain the required
   non-author approval without bypass.
3. Allow normal protected integration, then verify protected `main`.
4. Execute the synchronized physical movement matrix and tune firmware/raw IMU
   classification only from recorded ground truth.

## Privacy check

- [x] No credentials, personal identifiers, raw health values, device
      identifiers, or absolute personal paths are recorded.
