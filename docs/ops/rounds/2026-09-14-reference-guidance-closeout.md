# Round: 2026-09-14 - Reference guidance closeout

## Status

- State: `supplier-independent implementation and exact-current local
  verification complete; exact-SHA hosted checks, protected integration,
  repository privacy restoration, and round-owned cleanup pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `270a221f6be298c577a343fd9243a1f5334d49f4`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#15`

## Objective

Close the remaining cross-platform interaction gaps identified from private
notification and adaptive-day references without copying third-party branding,
wording, visual assets, categorical health judgments, or performance promises:

- let users control the clock-based morning check-in and evening journal
  reminder independently;
- keep both daily-review reminders out of configured quiet hours, including
  delayed Android work;
- present an explicit choice to keep the current workout plan or review lighter
  options when local evidence supports adaptive planned-workout guidance.

## Scope

### In scope

- Apple and Android daily-review preference, scheduling, delivery, settings,
  onboarding migration, localization, and focused tests.
- Apple and Android adaptive planned-workout notification and in-app actions.
- Explicit no-mutation behavior for the keep-plan and review-options choices.
- Review of wind-down permission-revocation parity.
- Focused and complete affected verification, operations records, hosted
  exact-SHA checks, and protected integration.

### Non-goals

- Copying competitor copy, branding, iconography, layout, or promises.
- Silently changing a calendar event, workout, target, or training plan.
- Diagnosing sleep, recovery, fatigue, readiness, or health conditions.
- Enabling notification permissions, calendar access, cloud transfer, public
  traffic, real paging, or participant data by default.
- Claiming OS delivery, background execution, or haptic behavior without
  physical-device evidence.

## Starting evidence

- Wind-down and morning recap are independently default-off, permission-gated,
  local, private, routed, and evidence-gated on both platforms.
- The daily-review pair is currently controlled by one preference, so a user
  cannot choose only the evening journal reminder.
- Daily-review scheduling currently does not apply the shared quiet-hours
  contract. Android one-time work can execute up to three hours late.
- Adaptive planned-workout guidance is local, default-off, calendar-gated,
  freshness-bound, quiet-hour-aware, and does not mutate the plan, but its
  notification and in-app action provide only a generic Workouts route rather
  than an explicit keep-versus-review choice.
- The prior private UI audit's 20 findings have no open source defect on the
  current branch. Historical release-note terminology remains intentionally
  historical.

## Delivered

### Independent daily-review controls

- Morning Sleep review and evening Journal are separate, default-off opt-ins on
  Apple and Android. The legacy pair preference migrates once to both values
  without enabling a previously disabled user.
- Each control requests notification permission only from its own explicit
  enable action and cancels only its own requests when disabled.
- Completing a native journal entry suppresses only that logical day's journal
  reminder. Notification and contextual-action routing preserve the canonical
  journal day through cold launch and navigation.

### Quiet-hour and lifecycle behavior

- Clock-based morning and journal schedules move to the first eligible local
  time outside configured quiet hours.
- Android delayed work rechecks quiet hours immediately before delivery.
- When quiet hours move a normal Android schedule across midnight, the original
  logical day is persisted immediately and survives time, settings,
  quiet-hour, and process-restoration reconciliation.
- Preference, time, and quiet-hour changes reconcile tracked one-shot requests;
  disable and permission restoration do not leave an untracked reminder.
- Daily review and wind-down retain the user's opt-in when OS permission is
  revoked while canceling pending requests and recording a bounded suppressed
  outcome.

### Planned-workout choice

- Eligible adaptive planned-workout guidance presents two neutral choices:
  `Keep current plan` and `Review lighter options`.
- Both actions require the current local guidance instance, future event,
  active opt-ins, current calendar permission, and a force-refreshed matching
  calendar candidate. Stale, deleted, rescheduled, expired, superseded, or
  permission-revoked evidence is rejected.
- Android keeps the notification action receiver alive asynchronously, makes
  the Calendar Provider query cancellable at the platform boundary, and
  serializes the final current/future check with state mutation under a
  consistent notification-then-calendar lock order.
- Neither action edits a calendar event, target, or workout plan. Review opens
  Workouts; keep dismisses only that evidence instance.
- Android durably retires only the owned expired/resolved instance and
  preserves newer guidance.

### Reference disposition and presentation truth

- The private notification and adaptive-day images were used only to identify
  useful interaction principles. NOOP does not reuse third-party branding,
  assets, copy, layout, categorical health judgments, or performance promises.
- The historical NOOP desktop capture exposed a contradiction: Recovery was
  unavailable while the workout row promised Recovery-guided effort. Current
  source selects live-heart-rate-only wording when Recovery is absent.
- Guidance remains local, opt-in, private, explainable, conservative, and
  non-diagnostic.

## Data, privacy, and medical truth

- Schema or migration impact: preferences only; no health database or server
  schema change.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none; existing evidence and freshness
  gates remain authoritative.
- Permissions/network disclosure impact: no new permission or transfer.
- Health/medical claim impact and limitations: copy remains conditional and
  non-diagnostic. Missing or stale evidence produces no adaptive prompt.

## Observability

- Record only bounded notification kind, delivery outcome, and action category.
- Never log notification copy, health values, calendar content, journal
  content, precise schedule time, or user-entered text.
- Physical OS delivery, action routing, and permission-revocation behavior
  remain device-validation gates.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused Apple notification, route, contextual-action, and calendar tests | 113 passed, zero failed/skipped | Split consent, journal day, quiet hours, tracked requests, current EventKit candidate, and both choices | Physical notification timing, EventKit/provider behavior, or cold-launch latency |
| Focused Android notification and contextual-action wall | Build successful, including final calendar-cancellation, carryover, current/future, and lock-order contracts; independent re-review found no remaining defect | Split consent, delayed quiet-hour checks, durable route state, owned expiry, bounded provider cancellation, and both choices compile and pass | OEM scheduler behavior, an intentionally stalled physical provider, or a physical notification shade |
| Complete macOS and iPhone simulator walls | macOS 2,006 passed plus one expected fixture skip; iPhone UI 38 passed plus one intentional pilot skip; zero failures | Exact Apple source and shell behavior | Physical iPhone/Watch delivery, haptics, or assistive-technology behavior |
| Complete Android Full, Demo, and API 35 walls | Each variant 4,759 passed plus seven intentional skips; API 35 107 passed plus two intentional skips; zero failures/errors | Exact Android source, lint, APK, migration, WorkManager, and instrumentation contracts | Representative OEM, BLE, battery, or background behavior |
| Localization generation and audit | 788 app-wide strings plus 45 Android-only resources across nine locales were idempotent; 86 report strings verified; strict i18n and 49 i18n tests passed | Source catalogs, placeholders, and customer-facing brand boundaries are consistent | Human translation quality |
| Health/privacy/release policy wall | Claims, calibration, private-data, terminology, legal/distribution, release-control, required-CI, trusted-control, JSON, shell, Actionlint, OpenTofu, and diff gates passed | Reference-inspired behavior did not weaken medical truth, privacy, or release controls | Legal, clinical, store, or production approval |
| Replacement exact-SHA hosted matrix | Pending after the final bounded commit | Will prove the committed revision under protected CI | Hardware, legal, store, or operational readiness |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local hosts and simulators only
- Data-preservation result: no participant or production data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical notification timing/actions, permission
  revocation, background/force-quit behavior, accessibility, BLE, haptics, and
  battery validation

## Git and release state

- Changed paths: included in the same 85-path bounded final audit change.
- Commits: one bounded final commit remains; this record is included in it.
- Branch and remote state: pull request `#15`; remote head `270a221f` is
  historical and replacement exact-SHA verification remains.
- Repository visibility verified: public during protected checks; restore to
  private immediately after integration.
- Version/build impact: no marketing-version change.
- Release or distribution impact: no deployment or distribution.

## Decisions

- User intent is granular: a journal prompt is not implicit consent to a
  morning check-in.
- Quiet hours apply at both scheduling and actual delivery time.
- Adaptive guidance supports a decision; it never makes the decision.
- Private references are behavioral evidence only, not reusable product assets.

## Open risks and honest limitations

- Simulator and unit evidence cannot establish OS delivery, OEM scheduler
  timing, EventKit/provider refresh behavior, haptics, BLE, battery, or
  assistive-technology behavior on representative physical devices.
- Hosted exact-SHA checks, protected integration, privacy restoration, and
  round-owned resource cleanup remain.
- Physical-device, supplier, legal, carrier, signing, store, participant,
  licensing, public-runtime, and elapsed-operation gates remain external.

## Next round

1. Include these changes in the single staged final review and bounded commit.
2. Wait for the replacement exact-SHA hosted matrix and resolve only proven
   review threads.
3. Integrate through protected `main`, restore private visibility immediately,
   synchronize canonical `main`, and clean only round-owned resources.
4. Validate physical notification delivery/actions, calendar-provider changes,
   background behavior, accessibility, BLE, haptics, and battery before launch.

## Privacy check

- [x] No credentials, personal identifiers, health values, calendar content,
      report contents, absolute owner paths, or private evidence are present.
