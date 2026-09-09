# Round: 2026-09-09 - Managed Safety late-review closeout

## Status

- State: `implemented and completely locally verified; replacement protected head pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `dadafd827a4f16cec9807d24e628e286dac93ff4`
- End implementation commit: commit containing this record
- Record commit or PR: protected pull request `#10`

## Objective

Close the five actionable findings posted against the exact protected head
without weakening private app-based Safety paging, authenticated latest-location
access, bounded background execution, or foreground-service lifecycle
guarantees.

Success requires reachable app alerts before contact acceptance, two reachable
contacts at page creation, launch authorization before foreground presentation,
an exact-once iOS background completion deadline, a push claim longer than the
provider's bounded delivery path, and Android foreground-service release after
managed location sharing ends.

## Scope

### In scope

- Apple and Android app-alert eligibility before accepting a Safety contact
  role.
- PostgreSQL incident eligibility serialized with current active push
  installations.
- Apple foreground launch authorization and bounded background catch-up.
- Provider-derived push-delivery leases and exact-claim completion.
- Android Safety-only foreground-service release.
- Bounded diagnostics, regressions, broad gates, protected review, and cleanup.

### Non-goals

- Enable public ingress, SMS or voice delivery, automatic emergency inference,
  or real participant paging.
- Treat simulator or source tests as physical push, location, background,
  haptic, battery, BLE, or emergency-delivery evidence.

## Starting evidence

- Reproduction or observed symptom: exact-head automated review on pull request
  `#10` identified five source-level gaps after the preceding head passed its
  local gates.
- Relevant source/device/OS/firmware class: Apple and Android managed app-alert
  entry points, Android foreground services, and PostgreSQL managed Safety push
  delivery.
- Existing tests, logs, exports, screenshots, or documents: the preceding
  Safety round and protected review threads were bound to start commit
  `dadafd82`.
- Unknowns that must remain unknown until measured: APNs/FCM delivery,
  terminated/background wake, physical location continuation, band haptic,
  battery impact, and real operational latency.

## Decisions

- Durable decision added or changed: an accepted managed Safety contact must
  have an active app-alert path, and a new page must have at least two accepted
  contacts with active app-alert installations at the serialized creation
  boundary.
- Decision-log entry: this round record; the existing manual app-paging
  decision remains unchanged.

## Delivered

- Apple and Android now stop before backend contact acceptance when managed
  notification registration is unavailable. Both surfaces retain localized
  user guidance and emit only a fixed `notification_not_authorized` category.
- Incident creation locks accepted contact candidates and all of their active
  push-installation rows in deterministic order. Only contacts represented by
  a locked active installation count toward the two-contact minimum, so
  concurrent revocation cannot create an unreachable page.
- Apple foreground managed Safety notifications now require current launch
  authorization before lifecycle capture, contextual routing, banner, sound,
  or list presentation. Unauthorized delivery is suppressed and recorded as a
  fixed `terms_required` category.
- Apple background catch-up races the authenticated refresh against a
  20-second deadline. One main-actor completion object cancels the losing task
  and invokes the system callback exactly once.
- FCM exposes a conservative bounded maximum of seven configured request
  windows. The repository claim is at least that duration plus a 30-second
  receipt margin; with the current 30-second provider timeout, the lease is
  240 seconds.
- A delayed provider receipt can complete only the exact still-current claim.
  Expiry alone no longer rejects it, while any reclaim changes the claim ID and
  preserves conflict rejection.
- Android reconciles the service after managed location sharing ends. It stops
  only when durable BLE reconnect, workout GPS, legacy Safety location, and
  managed Safety location are all inactive.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: contact acceptance now fails closed
  until the platform notification path is available; payload classes and
  permissions are unchanged.
- Health/medical claim impact and limitations: manual Safety paging remains
  best effort and is not diagnosis, automatic emergency detection, or an
  emergency-service substitute.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  managed Safety request, push receipt, provider dispatch, lifecycle, and
  foreground-service evidence, plus fixed rejection/deadline categories.
- Why existing evidence is sufficient, or why new evidence is required: the
  two newly visible rejection boundaries need categorical evidence; provider
  and lifecycle operations already expose bounded outcomes and counts.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`, server
  request middleware, and server operational events.
- New bounded events or operation spans: `notification_not_authorized`,
  `terms_required`, and `background_deadline` outcomes on existing event
  families.
- Redaction, retention, and high-frequency controls: fixed statuses and bounded
  counts only; no notification payload, token, contact, account, installation,
  incident, location, health value, arbitrary error, or user content.
- Cross-platform/backend correlation: static event names and server-generated
  request correlation remain the boundary; no persistent identifier enters the
  mobile report.
- Remaining blind spots: physical provider delivery, OS wake behavior,
  location continuation, and device-specific foreground-service behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Fresh PostgreSQL managed Safety and push suites | 51 passed | Active-installation eligibility, revocation serialization, exact-claim late receipt, provider bound, and affected retry behavior execute together | Complete server compatibility or production-provider behavior |
| Apple focused Safety suite | 36 passed | Authorization suppression, exact-once deadline source contract, app-alert acceptance gate, and existing Safety behavior remain covered | Physical APNs, OS wake, location, haptic, or battery behavior |
| Android focused Full unit suites | Build succeeded; all selected cases passed | App-alert acceptance and independent foreground-service lease reasons compile and pass | Physical FCM, OEM process policy, GPS, BLE, haptic, or battery behavior |
| Complete unsigned iOS simulator graph | Build succeeded | The changed application delegate, presenter, managed client, app, widget, and watch graph compile together | Signed or physical-device behavior |
| Repository release controls | Required CI, calibration parity, legal distribution, and private-data gates passed | The changed tree retains the reviewed release, metric, provenance, and privacy constraints | Hosted exact-head checks or protected merge |
| Complete local server suite | 424 passed; the one explicitly opt-in real-provider test skipped; one dependency deprecation warning | Every locally available API, migration, tenancy, ownership, social, Safety, retention, worker, and restore path remains compatible | Real provider traffic, TimescaleDB CI, or production database behavior |
| Android complete local gate | 4,143 Full unit tests with zero failures/errors and 7 skips; Full APK assembly, lint, and instrumentation-source compilation passed in 3m35s | The changed managed client and foreground-service graph compile and pass the complete local Android surface | Physical FCM, OEM process policy, GPS, BLE, haptic, battery, or signed release behavior |
| Apple complete local gate | Full Strand suite passed 1,669 tests with one expected data-dependent skip and zero failures; the complete unsigned iOS simulator app/widget/watch graph also builds | The changed presenter, application delegate, managed client, shared source, and complete Apple app graph remain compatible | Physical APNs, OS wake, location, haptic, battery, signing, or App Store behavior |
| iOS launcher UI regression | The exact quick-action test passed alone, after its hosted predecessor, and in ten consecutive relaunch iterations: 13 passes and zero failures | The production launcher opens from the floating action in the tested simulator state and the predecessor does not leak persistent navigation into it | It does not explain the single old-head hosted simulator failure or prove every OS/device timing |
| Server and repository quality | Ruff check/format passed across 67 files; Python compilation passed; 227 Tools tests passed | Changed Python and fail-closed release tooling remain syntactically and behaviorally valid | External-service behavior |
| Terminology and policy matrix | 17,378 classified occurrences, zero forbidden mappings, unchanged active allowlist, reviewed inventory digest repinned; required CI, 9 release controls, calibration, health claims, localization, legal/distribution, private-data, operations, and diff checks passed | The final local tree preserves terminology, release, metric, claim, localization, provenance, privacy, and evidence contracts | Hosted exact-head checks or protected merge |

### Failed and corrected attempts

- The first terminology snapshot exposed one new active Android legacy symbol
  because managed location cleanup called the compatibility service directly.
  Cleanup now reacts inside the existing service state collector, the active
  allowlist is byte-for-byte unchanged, and the reviewed historical inventory
  digest is explicitly repinned.
- One focused Tools invocation named a nonexistent operations-validator test
  module and collected no tests. The repository's actual complete Tools suite
  then passed all 227 tests, and the standalone operations validator passed all
  48 round records.
- The preceding hosted head had one iOS UI failure when opening the floating
  quick-action launcher. There was no retained artifact, the test passed alone,
  passed after the exact preceding test, and passed ten consecutive relaunches,
  so no unsupported production change was made. The replacement exact head
  must still pass the fresh protected Apple run.
- The first repeated-launch command incorrectly supplied `NO` after Xcode's
  flag-only retry option and exited before running a product test. The corrected
  ten-iteration command then passed every iteration.

## Physical device and deployment

- Install/update action: unsigned local simulator/debug builds only.
- Generalized device and OS class: Apple simulator and Android local compile/test
  graph; no physical phone was changed.
- Data-preservation result: no physical app container or real participant data
  was touched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: APNs/FCM delivery, terminated/background execution,
  location permission and continuation, OEM foreground-service policy, haptic,
  battery, and representative physical phones.

## Git and release state

- Changed paths: Apple notification and application entry points, Apple and
  Android managed Safety clients, Android connection service, server push and
  Safety repositories, focused regressions, and operations records.
- Commits: the replacement implementation is the commit containing this
  record.
- Branch and remote state: pull request `#10` remains the protected integration
  path; the replacement head still requires push, exact-head review, hosted
  checks, and normal merge.
- Repository visibility verified: inherited from the current protected round.
- Version/build impact: no version change planned.
- Release or distribution impact: none until protected merge; no public traffic
  or real paging is authorized by this round.

## Open risks and honest limitations

- Source and simulator evidence cannot establish provider delivery or physical
  background execution.
- Notification authorization can change after contact acceptance; page
  creation therefore rechecks current active installations but cannot guarantee
  a provider or OS will deliver every alert.
- A provider exceeding its declared bounded path is handled as a failed or
  reclaimable delivery, not hidden as success.
- Manual paging still requires monitoring, failover, legal review, physical
  validation, and staffed operations before production reliance.

## Next round

1. Push the replacement head, close all five exact-head threads with evidence,
   and require a clean review plus every protected check before normal merge.
2. Rebase, fully verify, review, and merge the separate large-data scroll-lag
   pull request.
3. Install merged `main` on representative phones and collect a reviewed
   shake-to-report ZIP while any remaining lag reproduces.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
