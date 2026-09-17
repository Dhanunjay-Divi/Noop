# Round: 2026-09-13 - Apple UI audit content follow-up

## Status

- State: `completed in an isolated local fork and integrated into the active
  audit branch; physical accessibility evidence remains`
- Owner: project team
- Branch: `codex/apple-ui-audit-content-20260913`
- Start commit: `f7baaddc0818b238b86962e60c5664eb6b746d34`
- End implementation commit: `0672d6f8`
- Record commit or PR: integrated into pull request `#15`

## Objective

Recheck the Apple/shared implementation of P1-1 through P1-3 and every
applicable P2 item in the private UI audit. Close remaining content defects
without changing Recovery thresholds, Trends loading, Android source, or the
iPhone UI test target.

## Scope

### In scope

- Recovery, Daily Signal, missing-value, digest, device, Stress, Journal,
  NOOP+, Health Monitor, and Sleep presentation contracts on Apple.
- Focused source tests for the corrected call sites.

### Non-goals

- P1-4 Trends loading or aggregation.
- Android parity.
- Physical VoiceOver, notification, BLE, haptic, or background validation.
- Bulk deletion of unreferenced translation history or low-level diagnostic
  terminology.

## Starting evidence

- The private audit report and its screenshot set were reviewed outside Git.
- The base already contained the intended Recovery, Daily Signal, tab
  accessibility, digest, device, Stress, NOOP+, Health, and Sleep corrections.
- Three Health live-HR placeholders and one Journal numeric placeholder still
  rendered a raw hyphen instead of the shared missing-value token.
- The supplied macOS screenshot showed stale workout-coach copy. Current source
  already selected unavailable-Recovery copy unless the chosen day owned a
  scored Recovery.

## Delivered

- Routed the four remaining Health and Journal placeholders through
  `StrandFormat.missing`.
- Extended focused contracts for the shared missing token, Recovery
  presentation, Daily Signal vocabulary, and workout-coach copy selection.
- Kept Trends, Android, and `NOOPiOSUITests.swift` outside this isolated change.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: presentation only; no score, threshold,
  or provenance change.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: unavailable Recovery remains
  unavailable and cannot shape the coach subtitle; no new claim was added.

## Observability

- Existing evidence reused: deterministic presentation/source contracts.
- New bounded events or operation spans: none; no operational boundary changed.
- Redaction, retention, and high-frequency controls: no diagnostics or payload
  recording changed.
- Remaining blind spots: physical VoiceOver rendering and notification or
  background behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused Apple/shared selection | 21 tests passed with zero failures | Localization, Recovery, Daily Signal, Dynamic Type/Large Content Viewer, digest, breakdown, device naming, and missing-value contracts pass together | Full app regression or physical accessibility |
| Live-session copy selection | `LiquidChargeCarryTests/testOnlyTodaysOwnScoreCanShapeLiveSessionCopy` passed | Carried, calibrating, baseline-ready, and no-data states cannot claim today's Recovery | Physical workout coaching or band cues |
| Scope and diff checks | `git diff --check` passed; no Android, Trends, or iPhone UI-test source changed | The isolated correction stayed within its assigned ownership | Integration compatibility, later covered by the active branch wall |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local macOS test target only
- Data-preservation result: no participant or owner data changed
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: VoiceOver, BLE, notification presentation, background
  execution, haptics, battery, and sensor behavior

## Git and release state

- Changed paths: `Strand/Screens/HealthView.swift`,
  `Strand/Screens/JournalLogCard.swift`, focused Apple source contracts, and
  this operations record
- Commits: `0672d6f8`
- Branch and remote state: isolated local fork integrated into the active audit
  branch; protected exact-head verification remains owned by pull request `#15`
- Repository visibility verified: unchanged by this sub-round
- Version/build impact: no schema or marketing-version change
- Release or distribution impact: none

## Decisions

- Durable decision added or changed: shared missing-value formatting and
  unavailable-Recovery copy are acceptance requirements across Apple surfaces.
- Decision-log entry: no new global decision number.

## Open risks and honest limitations

- Unreferenced catalog history can still contain legacy words without being
  mounted by current product UI.
- Physical VoiceOver and macOS/iPhone rendering were not established by this
  focused sub-round.

## Next round

1. Complete exact-current Apple/Android integration and protected verification
   in the parent UI-audit round.

## Privacy check

- [x] Private screenshots and owner paths are not committed.
- [x] No credentials, health values, raw sensor data, or user content were
      added.
