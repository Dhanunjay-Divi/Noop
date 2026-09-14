# Round: 2026-09-13 - UI audit terminology closeout

## Status

- State: `local implementation and complete verification finished; hosted integration pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `9cfea5669a28be205d700e9237c8ce0560f8c788`
- End implementation commit: pending
- Record commit or PR: pull request `#15`

## Objective

Close the two customer-facing terminology gaps found by an independent
read-only review of the completed UI audit:

- Apple Watch and iOS Live Activity score labels must say `Recovery`, matching
  Today, Calendar, Trends, and Android.
- Current mounted primary-device copy must say `Noop Band` or `band`, while
  preserving legitimate `heart-rate strap` and `chest strap` device-type
  language and stable internal compatibility identifiers.

Success requires matched Apple and Android presentation, focused regression
tests, affected app builds/tests, localization and terminology policy gates, a
fresh exact-SHA hosted check cycle, and protected integration.

## Scope

### In scope

- Watch glance and Live Activity score labels.
- Current primary-device instructions and status copy on active Apple and
  Android surfaces.
- Focused source/presentation regression contracts.
- Operations and release evidence for the replacement pull-request head.

### Non-goals

- Renaming internal score enums, persisted identifiers, BLE symbols, diagnostic
  filenames, or historical release notes.
- Replacing the valid `heart-rate strap` or `chest strap` device types.
- Changing Recovery formulas, sensor ingestion, notifications, data storage,
  network behavior, or medical claims.
- Claiming physical-device BLE, background, haptic, Watch, Live Activity,
  VoiceOver, or TalkBack behavior from source and simulator evidence.

## Starting evidence

- Reproduction or observed symptom: the private UI audit reported P2-9 and
  P2-10 as closed, but an independent source review found residual mounted
  customer copy.
- Relevant source/device/OS/firmware class: Apple Watch glance, iOS Live
  Activity, shared Apple UI, and Android Compose UI.
- Existing tests, logs, exports, screenshots, or documents: private audit report
  and 61 evidence files outside Git; exact source findings at the start commit.
- Unknowns that must remain unknown until measured: physical Watch and phone
  rendering, notification presentation, accessibility traversal, BLE, haptics,
  and background behavior.

## Delivered

- Apple Watch and Live Activity score labels now use `Recovery`.
- Mounted Apple and Android primary-device copy now uses `Noop Band` or
  `band`; valid heart-rate/chest-strap device types and internal compatibility
  identifiers remain unchanged.
- Nine-locale generated catalogs and focused source/presentation contracts pin
  the corrected vocabulary and unavailable-Recovery coach branch.
- The independent UI audit's four P1 and sixteen P2 corrections remain covered
  by the complete Apple, Android, server, localization, privacy, claims, and
  release-policy wall.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none; presentation wording only.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: no new health or medical claim.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: compile,
  presentation-contract tests, localization gates, and exact-SHA hosted checks.
- Why existing evidence is sufficient, or why new evidence is required:
  wording-only rendering has no new runtime operation, persistence, transport,
  or failure-prone lifecycle boundary.
- Existing evidence reused: native build/test diagnostics and repository policy
  gates.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: unchanged.
- Cross-platform/backend correlation: not applicable.
- Remaining blind spots: physical-device rendering and accessibility traversal.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| macOS app suite | 1,929 tests; 1,928 passed, one external Xiaomi-fixture skip, zero failures | Complete current-tree Apple app behavior and source contracts pass | Physical Watch, VoiceOver, BLE, haptic, and notification behavior |
| iPhone 17 Pro simulator UI suite | 39 tests; 38 passed, one intentional private-pilot skip, zero failures | Current iPhone navigation, audit states, and measured Today scrolling pass | Physical-device timing, memory pressure, accessibility, and background execution |
| Android Full variant | `assembleFullDebug`, complete unit suite, lint, and instrumentation Kotlin compilation passed in 70 tasks | Full product variant compiles and its complete local gates pass | OEM rendering, TalkBack, BLE, and physical background behavior |
| Android Demo variant | `assembleDemoDebug`, complete unit suite, lint, and instrumentation Kotlin compilation passed in 87 tasks | Demo variant and synthetic audit fixtures compile and pass | Physical-device behavior |
| Server wall | Complete PostgreSQL suite, Ruff, format check, and both locked dependency audits passed on separate disposable databases | Backend contracts remain compatible with the UI-only closeout | Public traffic, provider delivery, and production operations |
| UI audit contracts | Apple 12/12 and focused Android audit/localization suites passed | All reported P1/P2 presentation branches remain mounted on both clients | Pixel identity on every physical display and font scale |
| Window-only visual attempt | Kept outside Git under `$HOME/Documents/NOOP-private-audit-2026-09-14`; excluded from release proof because macOS retained stale rendered coach copy despite the loaded object and localization bundle containing only corrected keys | The capture limitation is disclosed rather than hidden | It does not disprove the directly executed source contracts, but it must not be presented as corrected visual evidence |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local Apple/Android toolchains only
- Data-preservation result: no participant or owner data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: Watch, Live Activity, BLE, background execution,
  notifications, haptics, battery, VoiceOver, and TalkBack on physical devices

## Git and release state

- Changed paths: Apple/Watch/widgets presentation and localization, Android
  presentation/localization, focused contracts, generated terminology
  inventories, release integrity pins, and operations evidence.
- Commits: bounded closeout commit pending after final policy snapshot.
- Branch and remote state: pull request `#15`; one consolidated replacement
  head and exact-SHA hosted checks pending.
- Repository visibility verified: temporarily public for hosted checks; must
  return to private immediately after protected integration.
- Version/build impact: no version change planned
- Release or distribution impact: no artifact released

## Decisions

- Durable decision added or changed: no new global decision; this applies the
  existing customer vocabulary and cross-platform parity contracts.
- Decision-log entry: none.

## Open risks and honest limitations

- Physical-device presentation and accessibility remain external gates.
- A fresh hosted exact-SHA cycle is required because this correction changes
  the already-pushed pull-request head.
- The macOS capture path produced stale rendered text that is absent from the
  loaded executable resources and compiled source object. It is retained only
  as tooling evidence; direct state contracts and complete suites are the
  release evidence until a clean physical or separately provisioned visual run.

## Next round

1. Push the bounded replacement head, run exact-SHA hosted checks, resolve only
   proven review threads, integrate through branch protection, restore
   repository privacy, and clean round-owned temporary resources.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
