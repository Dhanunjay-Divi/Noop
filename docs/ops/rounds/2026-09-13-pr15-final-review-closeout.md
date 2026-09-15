# Round: 2026-09-13 - PR 15 final review closeout

## Status

- State: `local implementation and complete local wall finished; exact-SHA
  hosted checks and protected integration pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `8bef6e5cb0e82935763512bc81fa607077fdc5a3`
- End implementation commit: pending
- Record commit or PR: pull request `#15`

## Objective

Close the final actionable review findings after the first fully green
replacement-head matrix, preserve the completed four-P1/sixteen-P2 UI audit,
and integrate the exact verified revision through protected `main`.

Success requires:

- Android feedback retries and cancellation reconciliation to use the app
  version captured inside the immutable archive rather than the currently
  installed build;
- Apple hydration days authored before the current 10,000 ml write limit to
  remain readable, editable toward a valid value, and clearable without
  silently truncating or normalizing the user's record;
- explicit Apple daily-review, hydration, and wind-down opt-ins to survive
  transient Notification Center failure or capacity deferral while OS
  authorization denial still disables delivery;
- the desktop, wind-down/journal/morning-prompt, and adaptive-day reference
  images to be checked against NOOP's current behavior without copying
  third-party branding, copy, artwork, event details, or unsupported claims;
- focused and complete local verification, one consolidated exact-SHA hosted
  matrix, review-thread resolution, protected integration, repository privacy
  restoration, and round-owned resource cleanup.

## Scope

### In scope

- Android feedback queue metadata, legacy queue migration, retry/cancellation
  reservation construction, and focused tests.
- Apple hydration compatibility migration, monotonic oversized-day correction,
  transactional total/entry persistence, and focused tests.
- Apple daily-review, hydration, and wind-down authorization/preference
  lifecycle plus affected onboarding and settings UI.
- Confirmation that current Apple and Android source branches workout-coach
  copy when Recovery is unavailable.
- Confirmation that both clients already implement private opt-in wind-down,
  journal, morning recap, and calendar-aware planned-workout guidance.
- Complete affected-platform, repository-policy, exact-SHA hosted, review,
  merge, privacy, and cleanup evidence.

### Non-goals

- Copying Bevel, Lucie, or another product's branding, notification text,
  emoji treatment, imagery, fixed times, calendar details, or algorithm claims.
- Exposing health values, journal content, event titles, or sensitive
  interpretations in protected lock-screen notification previews.
- Changing a Recovery, Sleep, Effort, Fitness Age, workout, hydration, or
  notification recommendation formula.
- Enabling public traffic, real health-data transfer, automatic medical/fall
  inference, carrier paging, or production distribution.
- Claiming BLE, background execution, notification timing/presentation,
  haptics, battery, or sensor accuracy without physical devices.

## Starting evidence

- Reproduction or observed symptom: pull-request review found that Android
  rebuilt feedback reservation requests with the currently installed version,
  Apple rejected pre-limit hydration days before they could be migrated or
  corrected, and transient notification scheduling outcomes silently cleared
  explicit opt-ins.
- Relevant source/device/OS/firmware class: Android durable feedback outbox and
  worker; shared Apple/macOS hydration store; Apple/macOS local-notification
  scheduling and opt-in UI.
- Existing tests, logs, exports, screenshots, or documents: the independent
  read-only UI audit at source commit `2efd5e89`, its 61 private evidence files
  outside Git, pull request `#15` review threads, prior exact-head hosted
  matrix, and focused reproductions added in this round.
- Unknowns that must remain unknown until measured: physical-phone
  notification presentation/timing, OS background scheduling, BLE and band
  behavior, haptics, battery, sensor accuracy, and production provider
  behavior.

## Delivered

### Android feedback

- `FeedbackRecord` now persists the archive's validated `app_version`.
- Existing non-terminal queues migrate the value from the single bounded
  `meta.json` entry inside the immutable ZIP; a disagreement between persisted
  state and archive metadata fails closed.
- Reservation creation and cancellation reconciliation use the staged record's
  version, so an app update cannot change the idempotent request contract.
- Cancellation reconciliation performs an authenticated, identity-bound
  reservation lookup and never mints a replacement upload capability.
- Invalid ZIP structure is terminal, while transient archive I/O or protected
  storage unavailability preserves the queued report for retry.
- Version, archive digest, archive size, attachment flags, and request identity
  remain immutable across state transitions.

### Apple hydration

- Current writes remain capped at 10,000 ml per day.
- A dedicated compatibility path validates and imports older positive,
  timestamped hydration entries without applying a limit that did not exist
  when they were authored.
- An already oversized day can only move monotonically downward while it
  remains above the current cap: no new entries, amount increases, identity
  changes, or timestamp rewrites are accepted.
- Once the total is within the current limit, the regular strict write path
  resumes. Entries and their canonical metric total remain one transaction.
- Legacy timestamps must remain finite and inside the supported Unix-time
  compatibility window through the end of 2100; malformed, overflowing, or
  implausibly future values fail before integer conversion.

### Apple notification preferences

- Daily Review and Hydration now distinguish `scheduled` from retryable
  `deferred`; both retain the user's explicit opt-in after capacity deferral or
  transient add failure.
- Wind-Down likewise retains opt-in after an authorized transient scheduling
  failure, including when no older accepted schedule exists.
- Restore logic separates user intent from OS authorization:
  authorized/provisional/ephemeral reschedules, not-determined retains intent
  without prompting, and denied or unknown authorization disables and cancels.
- Wind-down reconciliation specifically leaves a not-determined opt-in intact
  without adding or canceling requests; a focused regression run also caught
  and corrected an over-eager latest-intent guard before the full wall.
- Onboarding and settings toggles display the retained intent rather than
  silently flipping off after a retryable failure.

### UI audit and supplied references

- The audit's four P1 and sixteen P2 findings remain closed on both clients.
- Apple tabs use Dynamic Type and Large Content Viewer support; Android bottom
  navigation now exposes a selectable tab group, `Role.Tab`, stable scaled
  labels, ellipsis, and complete TalkBack descriptions.
- Current Apple and Android workout-coach entry copy uses live heart rate when
  today's Recovery is unavailable; a disconnected or unready band instead
  shows the explicit band-required state.
- Calibration progress is evidence collection, not a positive health result;
  current Apple and Android presentation uses neutral calibration tones.
- NOOP already provides opt-in sleep-need-based wind-down, evening journal,
  post-sync morning recap, and conservative calendar-aware planned-workout
  guidance on Apple and Android.
- The supplied third-party screenshots were used only to confirm product
  intent. NOOP retains its own metric-first hierarchy, consent boundaries,
  private notification doorway, evidence view, and cautious optional wording.
- The September 9 desktop screenshot is historical evidence, not the current
  result. Fresh September 13 window-only captures show the corrected neutral
  unavailable state and a separate scored state without reusing the stale
  WindowServer surface.

## Data, privacy, and medical truth

- Schema or migration impact: Android local feedback state adds one
  archive-derived field and self-migrates existing eligible records. No health
  schema changes. Apple hydration uses an explicit compatibility API rather
  than weakening the normal write contract.
- Existing-data retention impact: immutable feedback archives keep their
  original version contract; valid legacy hydration records are retained
  exactly and may be reduced or cleared by the user; no record is silently
  truncated.
- Source/provenance or formula impact: none. The changes preserve stored
  provenance and lifecycle state; metric formulas are unchanged.
- Permissions/network disclosure impact: notification permission remains
  explicit and user-owned. Feedback remains user-initiated, redacted, bounded,
  and default-off for public ingestion.
- Health/medical claim impact and limitations: no diagnosis, treatment,
  dehydration inference, medical alert, or automatic emergency inference is
  introduced. Adaptive workout copy remains optional and evidence-gated.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: Android
  feedback keeps bounded queue state, retry/cancel stage, attempt category,
  archive validation, progress, and terminal receipt evidence; notification
  reconciliation keeps fixed lifecycle outcomes and suppressed-request counts;
  hydration exposes transactional success or typed validation/persistence
  failure to the existing UI error path.
- Why existing evidence is sufficient, or why new evidence is required:
  feedback and notification paths already have bounded lifecycle recorders.
  The hydration correction is a local synchronous transaction with typed
  errors and no new long-running or cross-process boundary, so focused direct
  persistence tests are stronger than a new log event.
- Existing evidence reused: `AppDiagnosticsRecorder`, notification lifecycle
  categories, feedback outbox state, worker progress, and typed hydration
  store errors.
- New bounded events or operation spans: none; this round changes persisted
  lifecycle interpretation rather than adding an operational boundary.
- Redaction, retention, and high-frequency controls: unchanged. No health
  values, user text, identifiers, archive contents, tokens, URLs, or arbitrary
  exception strings enter diagnostics.
- Cross-platform/backend correlation: feedback continues to use its existing
  server-generated reservation/report correlation; notification and hydration
  remain local.
- Remaining blind spots: OS notification delivery after process suspension,
  OEM/OS capacity behavior, and physical-device background execution.

## Evidence

Record exact commands and results. Distinguish unit, integration, simulator,
physical-device, and external-service evidence.

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused Apple hydration and wind-down app tests | Hydration 41 and wind-down 35 passed, zero failures | New authorization, compatibility, timestamp, migration, correction, and coalescing branches are directly covered | Physical notification delivery or background timing |
| Focused `WhoopStore` hydration tests | 11 tests passed, zero failures | SQLite compatibility migration, strict writes, monotonic reduction, timestamp bounds, rollback, and clear behavior pass | Participant data or physiology |
| Focused Android feedback and navigation tests | 29 tests passed | Archive-version migration, mismatch rejection, immutable retry, reservation recovery, transient-read preservation, and tab semantics pass | Cellular/background upload or TalkBack on a phone |
| Complete `WhoopStore` package suite | 497 tests passed, zero failures | Storage changes preserve the complete package contract | App UI, BLE, or physical devices |
| Complete macOS app suite | 1,947 tests executed; one expected external Xiaomi-fixture skip and zero failures | Current shared Apple app code, UI contracts, notifications, and hydration behavior pass | Physical notification, BLE, haptic, and accessibility behavior |
| Complete Android Full/Demo wall | Build successful; both unit suites, both lint variants, both APKs, and both instrumentation Kotlin compilations passed in 137 tasks | Current Android feedback implementation compiles and passes both product variants | OEM UI, TalkBack, BLE, or physical background behavior |
| Complete PostgreSQL-backed server suite | Reached 100%; one provider/environment skip and zero failures | Current feedback reservation-recovery API and repository isolation pass with the complete backend contract | Public deployment, production IAM, or real-data transfer |
| OpenTofu format, validation, and focused tests | Configuration valid; 12 tests passed | Feedback remains bounded/default-off and ownership remains guarded and IAM-only | A cloud apply or deployed runtime |
| Strict feedback localization and i18n audit | Passed; nine generated locales and no new hardcoded/unextracted UI copy | New and retained customer copy stays in the shared localization contract | Linguistic review by native speakers |
| Health-claims, calibration-parity, and private-data gates | Passed | No unsupported claim, calibration-policy drift, or private artifact entered the tree | Clinical validity or physical-device accuracy |
| Generic iOS Simulator build | Complete unsigned Debug graph passed, including app, widgets, Watch app, App Intents, and embedded validation | The current iOS graph compiles for the simulator | Signing, App Store distribution, or a physical phone |
| Complete iPhone 17 Pro simulator UI suite | 39 tests executed; one intentional private-pilot skip and zero failures | Current navigation, accessibility contracts, feedback, automations, Trends, calendar, reminders, and performance paths operate on iOS 26.5 simulator | Physical notification, VoiceOver, BLE, background, battery, or haptic behavior |
| iPhone Today scroll sample | 4.709 s average, 0.138 s CPU average, about 67.8 MB average peak physical memory across three simulator iterations | The audited screen remains responsive under the repository's bounded simulator workload | Long-duration participant use or older physical devices |
| Fresh exact-build macOS visuals | Scored and unavailable-Recovery window-only captures reviewed outside Git | Recovery 34 is amber/Low; missing Recovery is neutral; independent Sleep/Effort remain visible; coach copy does not promise unavailable Recovery | Pixel parity on every display or physical sensor behavior |
| Repository policy wall and operations validation | 230 tool-contract tests and 49 top-level i18n tests passed; strict localization, 1,250-file health-claims, release-control, required-CI, calibration, terminology, legal/distribution, private-data, shell, diff, and all 63 operations-record checks passed | Current source and repository controls fail closed against unsupported claims, unreviewed copy, terminology drift, private artifacts, and unverified release paths | Professional translation, clinical/legal approval, or hosted exact-SHA execution |
| Exact-SHA hosted matrix | Pending one consolidated push | Pending | Physical-device and external-service gates |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local macOS and iOS Simulator toolchains;
  Android JVM/build toolchain
- Data-preservation result: no participant, owner, production, or real health
  data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical iPhone and Android notification presentation,
  OS background/force-quit behavior, BLE, band history, wrist haptics, battery,
  VoiceOver, TalkBack, and sensor accuracy

## Git and release state

- Changed paths: Android feedback outbox/worker and tests; Apple hydration
  store/app adapter and tests; Apple notification schedulers, onboarding,
  settings UI, and tests; operations evidence.
- Commits: bounded replacement-head commit pending after final policy and
  operations validation.
- Branch and remote state: local changes are based on pushed PR `#15` head
  `8bef6e5c`; replacement head has not been pushed.
- Repository visibility verified: temporarily public for hosted checks; it
  must return to private immediately after protected integration.
- Version/build impact: no product version or build-number change.
- Release or distribution impact: no artifact released or distributed.

## Decisions

- Durable decision added or changed: no new global product decision. Existing
  contracts are applied: immutable feedback metadata, exact user-record
  retention, user-owned notification consent, metric-first UI, private
  notification copy, and third-party screenshots as non-copyable references.
- Decision-log entry: none.

## Open risks and honest limitations

- The hosted exact-SHA matrix, review resolution, protected merge, privacy
  restoration, and cleanup remain open.
- The exact device behaviors listed above cannot be closed on this laptop.
- Public ingress, real feedback transfer, provider/carrier behavior, client
  encryption and key recovery, legal approval, 24/7 operations, signing,
  stores, participant validation, and exercise-media licensing remain external
  release gates.

## Next round

1. Commit and push one replacement head, wait for exact-SHA hosted checks,
   resolve only proven review threads, and merge through branch protection.
2. Restore repository privacy, sync canonical `main`, and remove only
   round-owned temporary resources.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
