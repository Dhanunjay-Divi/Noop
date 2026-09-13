# Round: 2026-09-13 - PR 15 late data-integrity review

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `6766b30c28162f82b649f50deeb385692ab4407b`
- End implementation commit: pending
- Record commit or PR: pull request `#15`

## Objective

Close the three data-integrity findings added after replacement head
`6766b30c` passed its complete hosted matrix, then re-run the affected local
and repository walls and integrate the exact verified revision through normal
protected `main`.

Success requires:

- managed hydration document application to reject or roll back a merged day
  above the shared 10,000 ml current-day limit on Apple and Android;
- hydration band-first reminders to retain a durable phone occurrence unless a
  live cue and its bounded tap-window fallback were both accepted;
- a newly reserved feedback report to retain an authorization identity for its
  full 28-day lifecycle without breaking operations for reports already bound
  to another identity;
- capability-upgrade and cursor-recovery snapshots to preserve remote deletion
  tombstones on Apple and Android before advancing the local change cursor;
- focused tests, complete affected-platform verification, exact-SHA hosted
  checks, review resolution, protected integration, repository privacy
  restoration, and round-owned cleanup.

## Scope

### In scope

- Apple and Android managed hydration document aggregation and rollback tests.
- Apple and Android hydration band-first phone-fallback policy, direct tests,
  and honest setting copy.
- Apple and Android feedback anonymous-identity lifetime policy and tests.
- Apple and Android managed snapshot transport/coordinator tombstone handling
  and tests.
- Operations records, release controls, exact-SHA hosted evidence, merge,
  privacy restoration, canonical sync, and round-owned cleanup.

### Non-goals

- Enabling feedback ingestion, public traffic, real health-data transfer, or
  production deployment.
- Changing hydration goals, recommendation formulas, notification behavior
  outside the bounded hydration phone-fallback repair, unrelated UI
  presentation, or health claims.
- Claiming physical-device, BLE, background, notification, haptic, battery, or
  sensor behavior from simulator or unit-test evidence.

## Starting evidence

- Reproduction or observed symptom: pull-request review threads
  `PRRT_kwDOTiE28c6h6dCa`, `PRRT_kwDOTiE28c6h6dCb`, and
  `PRRT_kwDOTiE28c6h6dCd` identify an unchecked post-merge hydration total,
  anonymous identities whose remaining lifetime may be shorter than a report,
  and snapshot requests that exclude tombstones before cursor advancement.
- Relevant source/device/OS/firmware class: shared Apple storage and managed
  sync packages, iOS feedback authorization, Android managed sync and feedback
  authorization, and default-off GCP identity configuration.
- Existing tests, logs, exports, screenshots, or documents: exact head
  `6766b30c` passed all 35 executed hosted checks with three intentional skips;
  all sixteen preceding review threads were resolved before these three later
  findings appeared.
- Unknowns that must remain unknown until measured: production Identity
  Platform cleanup timing, physical-phone background upload, real network
  interruption behavior, and participant-data merge frequency.

## Delivered

### Hydration phone-fallback follow-up

- Apple band-first mode now schedules a bounded horizon of 24 exact,
  non-repeating phone occurrences. A live cue replaces only its matching phone
  occurrence after Notification Center accepts the delayed tap-window request;
  a failed replacement leaves the original phone occurrence available.
- Apple confirmation cancels only the matching exact occurrence and matching
  tap-window request. A stale confirmation cannot remove a newer reminder.
- Android now serializes the worker and live-band paths per process. Worker
  first posts once and prevents a later buzz; cue first owns one tap window;
  buzz, tap-arm, or escalation-scheduling failure leaves the phone worker
  eligible.
- Android reads durable worker/cue state inside the serialized decision instead
  of passing potentially stale values into it.
- Apple and Android settings now say that the phone fallback stays scheduled
  and that only a successful live cue starts the tap window. Alarms and Safety
  behavior is unchanged.

## Data, privacy, and medical truth

- Schema or migration impact: no schema or migration change; the repair adds
  bounded local reminder-state keys only.
- Existing-data retention impact: fixes must preserve valid hydration entries,
  report lifecycle access, and remote deletion semantics without fabricating
  records or silently normalizing health data.
- Source/provenance or formula impact: no health formula change.
- Permissions/network disclosure impact: feedback remains explicit,
  user-initiated, redacted, bounded, and default-off for public ingestion.
- Health/medical claim impact and limitations: none; hydration remains a
  user-entered record and does not imply dehydration or treatment.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing typed
  managed-document transaction failures, bounded feedback queue stages, and
  snapshot checkpoint/cursor state.
- Why existing evidence is sufficient, or why new evidence is required:
  existing notification lifecycle ledgers already record bounded
  scheduled/post/suppressed/cancelled outcomes under the stable hydration
  category. The occurrence coordinator persists only local categorical state,
  so no new high-frequency event was added.
- Existing evidence reused: `AppDiagnosticsRecorder`, durable feedback outbox
  state, managed snapshot checkpoints, and typed sync/storage errors.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: no health values, user
  text, credentials, tokens, URLs, object payloads, or persistent identifiers
  may enter diagnostics.
- Cross-platform/backend correlation: existing report reservation correlation
  and managed change sequence.
- Remaining blind spots: provider-side anonymous cleanup timing and
  physical-device network/background behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-SHA hosted matrix for `6766b30c` | 35 successful, three intentional skips, zero failures | The pre-follow-up source passed every protected hosted job | The three later review findings |
| `ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :app:testFullDebugUnitTest --tests 'com.noop.notif.HydrationReminderPolicyTest'` | Passed, `BUILD SUCCESSFUL` | Full variant worker-first, cue-first, trust-gate, dedupe, and buzz-failure policy | Physical WorkManager/OEM timing or band vibration |
| `ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :app:testDemoDebugUnitTest --tests 'com.noop.notif.HydrationReminderPolicyTest'` | Passed, `BUILD SUCCESSFUL` | Demo variant compiles and passes the same focused policy/integration tests | Physical device behavior |
| `xcrun swiftc -frontend -parse Strand/System/HydrationReminders.swift StrandTests/HydrationRemindersTests.swift Strand/Screens/HydrationView.swift Strand/Screens/AutomationsView.swift` | Passed | Modified Apple source and tests parse | XCTest execution |
| `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /private/tmp/noop-hydration-phone-fallback-apple-dd CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -jobs 2 -only-testing:StrandTests/HydrationRemindersTests test` | Blocked before tests: third-party `MarkdownUI` compile could not create a temporary directory because the host volume had no free space | The focused Apple test command and infrastructure limitation were reproduced | No Apple XCTest assertion result |
| `python3 Tools/i18n_audit.py --platform all --full` | Passed | Modified localized strings have no catalog gap | Rendering on every locale/device |
| `python3 -m json.tool Strand/Resources/Localizable.xcstrings` and `git diff --check` | Passed | Catalog JSON and patch whitespace are valid | Runtime behavior |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local macOS, iOS Simulator, Android build
  toolchain, and synthetic backend tests
- Data-preservation result: no participant, owner, production, or real health
  data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical iPhone and Android upload/background behavior,
  BLE, band history, haptics, battery, VoiceOver, TalkBack, and sensor accuracy

## Git and release state

- Changed paths: hydration reminder source, focused tests, setting copy and
  localization on Apple and Android, plus this existing round record
- Commits: local detached hydration follow-up commit is this commit
- Branch and remote state: isolated detached worktree based on `e96c414b`; no
  push performed
- Repository visibility verified: public at round start; must return to private
  immediately after protected integration
- Version/build impact: no product version or build-number change
- Release or distribution impact: no artifact released or distributed

## Decisions

- Durable decision added or changed: none yet
- Decision-log entry: none

## Open risks and honest limitations

- The three review findings remain open until implementation and direct tests
  prove their contracts.
- A second replacement push is necessary because these findings were created
  only after the first exact-SHA matrix had completed.
- All physical-device and external launch gates remain unchanged.
- iOS can keep accepted local notifications available while the app is
  suspended or terminated, but cannot guarantee that app code will run to issue
  a BLE haptic in those states. The 24 exact occurrences are refreshed on app
  launch/settings changes and cover at least 24 hours at the minimum interval.
- Android WorkManager timing remains subject to OS/OEM scheduling, and neither
  platform's physical band vibration was verified in this round.
- Focused Apple XCTest execution remains unproven on this host because the
  volume exhausted its free space while compiling `MarkdownUI`; Swift parsing
  passed and the failure occurred before the hydration test bundle ran.

## Next round

1. Trace and implement the three parity fixes, run focused tests, and perform a
   fresh independent review before the complete wall.
2. Push the bounded replacement head, wait for exact-SHA hosted checks, resolve
   only proven threads, and integrate through branch protection.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
