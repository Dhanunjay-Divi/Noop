# Round: 2026-09-14 - PR 15 final review remediation

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

Close three late review findings without weakening retention, health-input, or
local-data integrity contracts:

- preserve a submitted feedback report's automatic-attempt budget while new
  reservation admission is operationally drained;
- require confirmed profile weight before Android Health presents BMI, matching
  every other BMI surface;
- migrate previously accepted oversized Android hydration totals into a
  correction-capable compatibility state instead of a permanently non-editable
  scalar-only state.

## Scope

### In scope

- Server feedback admission response semantics.
- Apple and Android feedback retry classification and durable scheduling.
- Android Health BMI visibility.
- Android Room hydration migration and correction behavior.
- Focused cross-platform/server regression tests, complete affected walls,
  operations records, hosted exact-SHA checks, and protected integration.

### Non-goals

- Enabling feedback ingress, real health-data transfer, or public traffic.
- Treating an imported weight as user confirmation.
- Reinterpreting an oversized historical hydration total as physiologically
  valid or silently clamping it to the current 10 L limit.
- Claiming physical-device, clinical, or production behavior from local tests.

## Starting evidence

- A disabled `feedback_accepting_reservations` gate returns HTTP `503` and
  `Retry-After: 300`; both clients classify it as an ordinary retryable server
  failure, so repeated drains can consume all eight automatic attempts.
- Android Health derives `currentWeight` from an imported reading but gates BMI
  only on age, height, and weight availability, not
  `profile.weightInputConfirmed`.
- Android migration `48 -> 49` creates an editable hydration row only when the
  historical scalar is at most 10,000 ml. Larger previously accepted values
  remain scalar-only while all mutation paths reject scalar/entry mismatch.
- Exact-SHA hosted checks for `270a221f` were canceled early after these
  findings were confirmed, avoiding a stale full matrix.

## Delivered

### Feedback reservation drain

- The server retains HTTP `503` and `Retry-After: 300` for new reservations
  during an operational drain and adds the bounded categorical header
  `X-NOOP-Feedback-Deferral: reservation-drain`.
- Apple and Android recognize only that exact status/header pair as a durable
  reservation-continuity wait. It remains automatically retryable without
  consuming the submitted report's finite delivery-attempt budget.
- Existing status, completion, recovery, and cancellation paths remain
  available. No report content, identity, URL, token, or retry timestamp is
  added to diagnostics.

### Confirmed BMI inputs

- Android Health now uses the shared adult-BMI presentation policy and requires
  confirmed profile age, height, and current weight.
- An imported weight remains visible with its provenance but cannot silently
  become a user-confirmed profile input or authorize BMI presentation.
- The formula and one-decimal display contract do not change.

### Oversized historical hydration correction

- Android Room schema `53` materializes an accepted whole-number hydration
  scalar above 10,000 ml as one marked correction-only entry when no editable
  rows already exist.
- The original value is preserved exactly. Users may reduce it to a valid
  total, replace it, or clear it; normal additions and replacements remain
  capped at 10,000 ml per day.
- Correction and deletion reproject the scalar in the same Room transaction.
  Synthetic projection failures prove that both the entry and scalar roll back
  together.
- Existing valid editable rows are not duplicated, malformed/fractional
  scalars remain fail-closed, and Health Connect data is not relabeled.

### Final independent review follow-ups

- A journal notification or in-app contextual action now carries the canonical
  logical journal day through cold launch and navigation rather than opening
  whichever day happens to be current.
- Android records the original logical day as soon as quiet hours move a normal
  daily-review schedule across midnight. Time, quiet-hour, settings, and
  process-restoration reconciliation therefore preserve yesterday's pending
  journal instead of replacing it with today's.
- Apple force-refreshes EventKit before accepting either planned-workout
  decision and rejects a deleted, rescheduled, expired, permission-revoked, or
  superseded candidate.
- Android force-refreshes Calendar Provider before either choice, keeps the
  broadcast alive with `goAsync`, binds coroutine cancellation to the platform
  query through `CancellationSignal`, and rejects a provider stall at the
  bounded receiver deadline.
- Android samples current time and validates the matching future calendar
  snapshot while holding the notification and calendar locks in one consistent
  order through the decision commit. Deleted, moved, newly started,
  superseded, or permission-revoked evidence cannot mutate state, and
  concurrent posting cannot deadlock the action.
- Apple and Android now preserve the server's bounded `Retry-After` delay for
  the exact reservation-drain response while refunding the automatic attempt.
- Android durably clears an expired planned-workout decision only when it still
  owns that evidence instance, preserving newer guidance.
- An independent exact-tree review found no remaining concrete source defect
  after the lock-order correction. Physical EventKit, Calendar Provider, Room,
  and background behavior remain device gates.

## Data, privacy, and medical truth

- Schema or migration impact: Android compatibility migration behavior only;
  no server schema change is expected.
- Existing-data retention impact: submitted feedback archives remain queued
  during a bounded admission drain; oversized local hydration history remains
  preserved until the user explicitly corrects or clears it.
- Source/provenance or formula impact: BMI formulas do not change; presentation
  requires confirmed profile inputs. Hydration formulas do not change.
- Permissions/network disclosure impact: no new permission or data field.
- Health/medical claim impact and limitations: oversized hydration remains
  labelled historical/correction-only data and is not normalized into a
  recommended value.

## Observability

- Feedback admission deferral must emit only bounded categorical status, never
  report content, identity, URL, token, or retry timestamp.
- Android migration and BMI changes require no new runtime logging; deterministic
  tests and existing bounded feedback lifecycle events are sufficient.
- Remaining blind spots: real maintenance-drain duration, WorkManager/background
  timing, iOS suspension, and participant migration data.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused server, Apple, and Android remediation tests | Passed, including 58 Apple feedback tests and the final Android calendar, daily-review, feedback, and notification wall | Exact drain classification, server-delay persistence, attempt preservation, BMI confirmation, migration, correction, deletion, cancellation, current-event commit, and rollback contracts | Public ingress, a real operator drain, or physical background timing |
| Focused Apple notification and calendar tests | 113 passed, zero failed/skipped | Journal-day routing, planned-workout freshness, choices, and notification policy | Physical EventKit mutation races or notification delivery |
| Focused Android API 35 hydration shell | 3 passed, zero failed | Real Room migration plus transactional correction/delete rollback on the managed device | Participant databases or OEM-specific behavior |
| Complete macOS app suite | 2,006 passed, one expected external-fixture skip, zero failed | Complete Apple product source on the exact worktree | Physical iPhone, Watch, BLE, or background behavior |
| Complete iPhone simulator UI suite | 38 passed, one intentional private-pilot skip, zero failed | Current app-shell navigation and UI contracts | Signed physical-device responsiveness |
| Generic iOS Simulator build | Passed for app, widgets, and Watch targets with signing disabled | The complete Apple target graph compiles | Signing or store acceptance |
| Complete Android Full and Demo wall | Each variant: 4,759 passed, seven intentional skips, zero failed/errors; 137 tasks including APK, lint, and instrumentation-source compile | Both Android product variants, generated schema, cancellable calendar boundary, carryover policy, and action-lock contracts compile against the exact tree | Physical OEM delivery, BLE, battery, or haptics |
| Complete Android API 35 shell | 107 passed, two intentional private-pilot skips, zero failed/errors | Current Room migrations, WorkManager, notification, and instrumentation contracts on the managed runtime | Representative physical Android behavior or an intentionally stalled calendar provider |
| Complete PostgreSQL server suite | 597 passed, one provider/environment skip, zero failed/errors; Ruff check and format clean over 81 files | Server behavior against fresh isolated PostgreSQL in the supported plain-PostgreSQL mode | Production Timescale deployment or public traffic |
| Swift packages and harnesses | Nine core packages: 2,961 passed, ten fixture-dependent skips, zero failed; StudyHarness and Backfill build/test passed | Shared protocol, store, analytics, import, design, local-access, remote-sync, study, and backfill source | Proprietary or personal datasets that are deliberately absent |
| Repository policy wall | 230 tool tests, 49 i18n tests, 12 OpenTofu tests, 111 JSON parses, 27 interpreter-matched shell syntax checks, 25 ShellCheck warning/error passes, Actionlint, localization, privacy, claims, calibration, terminology, legal/distribution, release-control, required-CI, trusted-control, and diff gates passed | Source, workflow, policy, localization, and infrastructure contracts are internally consistent | Hosted exact-SHA checks or external approvals |
| Replacement exact-SHA hosted matrix | Pending after the final bounded commit | Will prove the committed revision under protected CI | Physical hardware, legal approval, or production operation |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local test hosts and simulators only
- Data-preservation result: no participant or production data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical migration, background retry, notification,
  BLE, haptic, battery, and accessibility validation

## Git and release state

- Changed paths: 85 intended product, test, generated localization/schema,
  policy-ratchet, and operations-record paths before the final staged review.
- Commits: one bounded final commit remains; this record is included in it.
- Branch and remote state: pull request `#15`; remote head `270a221f` is
  historical and does not prove this final worktree.
- Repository visibility verified: public during protected checks; restore to
  private immediately after integration.
- Version/build impact: no marketing-version change.
- Release or distribution impact: no deployment or distribution.

## Decisions

- Operational feedback admission drains are durable deferrals and must not
  consume the user-approved report's finite automatic-attempt budget.
- Imported body measurements remain visible as measurements, but BMI requires
  the same explicit profile-input confirmations on every surface.
- Previously accepted oversized hydration totals remain preserved but must
  expose an explicit correction/clear path; they are not silently clamped.

## Open risks and honest limitations

- The first isolated iOS build attempt exhausted local disk space. Only
  generated round-owned build products were removed; the unchanged source then
  built successfully.
- The first exact-localization rebuild selected the macOS-only `Strand` scheme
  with an iOS Simulator destination, so Xcode stopped before compilation. The
  same source then passed the intended `NOOPiOS` Release build, including
  widgets and Watch targets.
- The first fresh server invocation accidentally selected the Timescale engine
  against plain Homebrew PostgreSQL and failed 21 tests during setup. The
  database was recreated and the supported `postgresql` engine rerun passed
  597 tests with one provider/environment skip.
- Hosted exact-SHA checks, protected integration, privacy restoration, and
  round-owned resource cleanup remain.
- Physical-device, supplier, legal, carrier, signing, store, participant,
  licensing, public-runtime, and elapsed-operation gates remain external.

## Next round

1. Stage and inspect every intended path, create one bounded commit, and push
   once.
2. Wait for the complete required matrix on that exact SHA and resolve only
   review threads whose fixes are proven by the committed source and checks.
3. Integrate through protected `main`, immediately restore the repository to
   private, synchronize canonical `main`, and remove only round-owned resources.
4. Keep the named physical-device, supplier, legal, carrier, signing, store,
   participant, licensing, public-runtime, and elapsed-operation gates open.

## Privacy check

- [x] No credentials, personal identifiers, health values, report contents,
      absolute owner paths, or private evidence are present.
