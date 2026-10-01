# Round: 2026-10-01 - Actionable wellness notifications

## Status

- State: `implemented and locally verified; protected integration and physical validation pending`
- Owner: project team
- Branch: `codex/mobile-navigation-sparkline-redesign-20260930`
- Start commit: `4d034b92f6fcfd1dfe05fbe4c698c469f44e4f0a`
- End implementation commit: pending
- Record commit or PR: PR `#25`

## Objective

Make the existing opt-in hydration, inactivity, and qualified stress check-ins
useful from the notification itself. A user response must reach a concrete,
bounded action on both Apple and Android:

- stress check-in -> start a one-minute paced-breathing session;
- hydration check-in -> open the confirmed water-log flow without silently
  recording intake;
- inactivity check-in -> open a short movement-break timer without silently
  recording exercise.

The stress lane must remain a non-medical wellness estimate based on qualified
personalized evidence, not heart rate alone. All three lanes must remain
private, opt-in, quiet-hours-aware where applicable, deduplicated, and
rate-limited.

## Scope

### In scope

- Trusted notification routes, action identifiers, and cold/warm launch
  hand-off on Apple and Android.
- One-shot breathing-session launch state.
- A compact two-minute movement-break surface with start, finish, and dismiss
  behavior.
- Existing hydration quick-log navigation.
- Cross-platform tests, localization, bounded diagnostics, and operations
  evidence.

### Non-goals

- Diagnosing emotional stress, dehydration, illness, or a medical condition.
- Silently logging water, exercise, standing time, or a completed breathing
  session from notification delivery alone.
- Increasing sensor polling or background execution cadence.
- Claiming notification timing, background wake, wrist haptics, battery, or
  sensor accuracy without signed physical-device evidence.

## Starting evidence

- Reproduction or observed symptom: stress and hydration notifications carry
  trusted routes, but stress opens Breathe without starting the promised cue;
  inactivity notifications open the generic app root.
- Relevant source/device/OS/firmware class: shared Apple app, iPhone shell,
  macOS shell, and Android app source.
- Existing tests, logs, exports, screenshots, or documents: contextual
  intervention policy, hydration reminder policy, sedentary detector,
  notification lifecycle ledger, route-bridge tests, and breathing-session
  implementations.
- Unknowns that must remain unknown until measured: physical notification
  presentation, OS/OEM scheduling, terminated-process behavior, band haptics,
  and real sensor accuracy.

## Delivered

- Apple and Android hydration notifications expose `Log water` and route to
  Hydration. Opening the route never writes an intake.
- Qualified stress notifications expose `Start breathing` and start one
  visible, dismissible, one-minute paced-breathing session. A saved resonance
  pace is used when available; otherwise the existing coherence pace is used.
- Inactivity notifications expose `Move now` and open a dedicated two-minute
  movement break. The timer records no workout, standing, steps, or exercise
  claim.
- Apple and Android calculate the one-minute breathing and two-minute movement
  sessions from monotonic elapsed time. Backgrounding and returning to the UI
  cannot stretch a promised session merely because UI timer callbacks paused.
- Cold and warm notification launches preserve a trusted finite route plus a
  finite presentation value, consume it once, and reject arbitrary stored
  navigation values.
- Apple action categories require foreground authentication and use a generic
  hidden-preview placeholder. Android reminders use the existing private
  notification contract and enter through a non-exported activity.
- The Android movement timer preserves its monotonic start across recreation
  and uses a one-shot terminal guard so completion and dismissal cannot
  produce duplicate terminal outcomes.
- Disabling the Apple stress phone lane retracts its pending and presented
  notification; delivery also rechecks that preference. A cold Android
  breathing launch no longer cancels itself merely because no band is bonded.
- Existing morning review, Journal, wind-down, metric-review, strain, planned
  workout, and Safety notification sources were inventoried and retain their
  existing trusted destination routes.
- Twelve concise action, timer, and inactivity strings were generated for all
  nine supported app-wide locales. The movement title is the direct
  `Time to move`, while the private action remains `Move now`.

## Interruption and usefulness policy

- Every lane is optional and defaults off. Notification permission is requested
  only after an explicit user enable action.
- Hydration keeps a user-selected active window, respects global quiet hours,
  and cannot schedule more often than once per hour.
- Qualified stress keeps its four-hour topic cooldown, the shared 30-minute
  contextual anti-pileup cooldown, quiet hours, replay protection, and
  corroborated fresh evidence gates.
- Inactivity starts only after the configured sedentary threshold, which
  defaults to 45 minutes. A continuing bout defaults to a 30-minute re-nudge,
  is limited to the configured active window, defaults to worn-only, and
  respects the notification master and quiet hours.
- Notification delivery does not increase sensor polling. Wrist or band cues
  remain a separate best-effort lane and are never treated as proven until
  validated on the exact signed phone, band, firmware, and SDK combination.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: none planned.
- Source/provenance or formula impact: no stress, hydration, or inactivity
  formula change planned.
- Permissions/network disclosure impact: no new permission or network lane.
- Health/medical claim impact and limitations: prompts remain optional wellness
  actions and do not state that the user is stressed or dehydrated.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  notification lifecycle states plus one bounded action-route outcome at the
  trusted hand-off and timer lifecycle.
- Why existing evidence is sufficient, or why new evidence is required:
  notification posting is already covered, but the new user-visible route
  presentation and one-shot session start need fixed categorical evidence.
- Existing evidence reused: `LocalNotificationLifecycle`,
  `NotificationLifecycleLedger`, route-bridge tests, and contextual prompt
  delivery ledgers.
- New bounded events or operation spans:
  `wellness_notification.action`,
  `wellness_notification.action_started`,
  `wellness_notification.action_finished`, and
  `wellness_notification.movement_break`.
- Redaction, retention, and high-frequency controls: fixed route/action/status
  categories only; no health values, notification text, timestamps, user
  identifiers, device identifiers, or payloads.
- Cross-platform/backend correlation: Apple and Android use matching route
  presentation semantics; backend not involved.
- Remaining blind spots: physical delivery and background wake behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Complete iOS Simulator graph | Pass | Shared Apple source, notification routing, breathing, and movement surfaces compile in the iPhone app | Signed-device delivery, terminated-process wake, wrist feedback, or sensor behavior |
| Final Apple focused wall | 57/57 pass | Monotonic timer boundaries, private foreground action categories, trusted presentation decoding, one-shot route consumption, account/onboarding, Bluetooth, and shared screen contracts | OS scheduling or physical interaction |
| Apple reminder/intervention regressions | 108/108 pass | Hydration, contextual intervention, and daily-review policies retain existing eligibility and scheduling behavior | Long-running physical background behavior |
| Final Android focused wall | 78/78 pass | Action routing, non-exported entry, monotonic sessions, no silent logging, hydration cadence, stress cooldown, sedentary gating, supported locales, and account-flow contracts | OEM delivery timing, physical haptics, or process death on a phone |
| Android Full and Demo compilation | Pass | Both customer and demo product flavors compile with the new routes and surfaces | Physical-device runtime behavior |
| All-platform localization audit | Pass with 237 Android and 131 Apple pre-existing UI-literal warnings outside this slice | Generated action/timer keys are present and Apple translated-key coverage has no gaps | Resolution of the repository-wide pre-existing literal backlog |
| Brand, claims, privacy, and operations gates | Pass: 14 brand phrases across eight non-English locales; health-claims clear across 1,324 files; private-data filename guard clear; 110 operations records valid | The final copy and evidence retain current release-policy boundaries | Physical delivery or external launch approval |
| Notification route inventory | Pass | Existing user-facing wellness/Safety notification producers retain trusted destinations; the three formerly incomplete lanes now open exact actions | Human usefulness or delivery cadence on physical devices |
| Diff hygiene | Pass | No whitespace/error-marker defect in the current working diff | Functional correctness beyond the listed gates |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: iPhone Simulator and Android API 35 emulator
- Data-preservation result: no schema or history mutation planned
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all physical notification, haptic, background, and
  sensor-dependent cases

## Git and release state

- Changed paths: shared notification route/category handling, Apple and Android
  breathing presentation, new movement surfaces and timer policies, reminder
  producers, localization source/generated resources, focused tests, decision
  log, and operations records
- Commits: pending
- Branch and remote state: dirty isolated PR branch; no new push
- Repository visibility verified: unchanged
- Version/build impact: none planned
- Release or distribution impact: none until protected integration

## Decisions

- Durable decision added or changed: an optional wellness notification must
  open a concrete user-controlled action; delivery alone never records a
  health behavior.
- Decision-log entry: D-063.

## Open risks and honest limitations

- A simulator can validate route state and UI, not OS delivery timing,
  terminated-app wake, or wrist feedback.
- Automatic stress check-ins remain limited by current qualified R-R, heart
  rate, motion, wear, workout, baseline, freshness, quiet-hour, and cooldown
  gates.
- Apple Watch may mirror an authorized iPhone notification according to the
  user's Apple settings. NOOP does not claim supplier-band or WHOOP haptic
  delivery from this software-only round.

## Next round

1. Validate notification actions and haptic/background behavior on signed
   supported iPhone and Android candidates with a compatible physical band.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
