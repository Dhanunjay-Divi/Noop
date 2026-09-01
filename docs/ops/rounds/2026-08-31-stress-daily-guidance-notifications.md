# Round: 2026-08-31 - Stress and daily guidance notification reliability

## Status

- State: `completed locally; physical-device validation remains`
- Owner: project team
- Branch: `main`
- Start commit: `64c3b75b`
- End implementation commit: commit containing this record
- Record commit or PR: direct-to-`main` commit requested by the owner

## Objective

Address reports that opted-in users were not receiving timely stress prompts
or useful journal reminders. Success means Android evaluates qualified stress
evidence while live data is arriving, both mobile platforms expose private
morning and evening guidance, the evening prompt opens Journal and is
suppressed after that day is logged, lifecycle and permission failures remain
visible, and the verified commit is published through the community testing
build.

## Scope

### In scope

- Preserve the existing conservative stress detector while making Android
  invoke it from fresh R-R and committed motion updates.
- Add Android parity for the default-off morning Sleep and evening Journal
  reminders already offered on Apple.
- Make evening journal reminders completion-aware on both platforms.
- Keep notification permission, channel, routing, time-change, process-death,
  quiet-hour, cooldown, and privacy behavior explicit.
- Run local app, simulator, localization, and policy verification; push the
  result to `main`; verify hosted CI; and publish a community testing build.

### Non-goals

- Send random, diagnostic, emergency, or guaranteed real-time stress alerts.
- Treat a user's subjective stress as equivalent to the detector's autonomic
  proxy.
- Claim exact Android WorkManager or Apple Notification Center delivery.
- Claim physical-band, background, haptic, battery, or sensor accuracy from a
  unit test, build, or simulator.

## Starting evidence

- Reproduction or observed symptom: a user reported intermittent or absent
  stress and journal notifications.
- Relevant source/device/OS/firmware class: Apple local notifications; Android
  notification channels, WorkManager, app routing, and compatible-band live
  R-R and motion ingestion.
- Existing tests, logs, exports, screenshots, or documents: Apple already had
  default-off daily review and conservative stress policy; Android stress
  evaluation was primarily tied to completed history handoff and lacked the
  daily review pair.
- Unknowns that must remain unknown until measured: whether a specific
  physical phone displayed a notification, whether a band delivered a haptic,
  and whether a reported subjective event met detector evidence thresholds.

## Delivered

- Android stress evaluation now receives bounded requests from fresh R-R
  packets and committed wrist-motion chunks instead of waiting only for a full
  history completion. Existing worn, encrypted, freshness, stillness,
  baseline, active-session, quiet-hour, replay, and four-hour cooldown gates
  remain unchanged.
- Android detects app-level and feature-channel notification disablement before
  presenting the stress phone lane as active.
- Android adds two independent persisted daily-guidance WorkManager chains.
  Morning opens Sleep; evening opens Journal and queries the native journal at
  delivery time so a completed day is suppressed. Reboot, date, time, and time
  zone changes rebuild both schedules.
- Android onboarding and Automations expose a clear default-off opt-in, morning
  and evening time controls, privacy copy, channel failure state, and a direct
  notification-settings action.
- Apple evening guidance now routes directly to Journal. A bounded set of
  completion-aware one-shot evening requests replaces the repeating evening
  request, while the morning request remains repeating. Native journal writes,
  clears, launch, and restore reconcile the bounded schedule.
- Apple immediate contextual prompts await registration of the private hidden
  preview category before posting.
- Both platforms use trusted internal routes and generic lock-screen content
  with no scores, health values, observations, or journal answers.
- Notification lifecycle records use static identifiers only and do not claim
  operating-system presentation or delivery.
- The persisted DEBUG demo fixture now repairs a complete date-relative
  trailing Active Minutes week, so production-shell UI checks keep exercising
  current seven-day coverage instead of aging into an empty state.

## Data, privacy, and medical truth

- Schema or migration impact: no database schema or migration change.
- Existing-data retention impact: existing journal rows and notification
  preferences remain intact. New Android daily-guidance preferences default
  off. Apple adds bounded completion and pending-request metadata in local
  defaults.
- Source/provenance or formula impact: no score or detector formula changed.
  Stress remains a conservative autonomic proxy against the user's own
  baseline.
- Permissions/network disclosure impact: local notification access is requested
  only from an explicit user enable action. No server, account, upload, or new
  network path is added.
- Health/medical claim impact and limitations: prompts are wellness guidance,
  not diagnosis, treatment, emergency detection, or proof that the user is
  stressed.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused Apple notification tests | 23 passed, 0 failed | Daily review scheduling/routing and contextual intervention policy pass | OS delivery or physical-device behavior |
| Android full debug unit suite and build | 3,901 tests completed, 7 skipped, 0 failed; Full debug APK and instrumentation sources compiled | Kotlin policy, localization, routing, app compilation, and JVM contracts pass | OEM scheduling, physical BLE, or notification display |
| Android API 35 managed-device suite | 23 passed, 0 failed | The production shell installs and its instrumentation contracts pass on the managed emulator | Physical-phone background policy or band behavior |
| Localization and policy gates | Strict i18n, health-claims, and launch-isolation checks passed | Maintained locale coverage and checked-in policy contracts pass | Native-speaker, medical, or legal review |
| Active Minutes fixture regression tests | 11 passed, 0 failed | The persisted DEBUG fixture maintains an idempotent date-relative trailing week and the app reads the canonical computed source | Production user data or physical-device behavior |
| Full macOS app suite | 1,563 executed, 1 skipped, 0 failed | The complete `Strand` test action passes with the final notification and fixture code | Physical Apple behavior or signed distribution |
| iOS production-shell simulator suite | 28 passed, 0 failed, including measured scroll performance and large-text Active Minutes coverage | The complete production iPhone shell builds, launches, routes, scrolls, and exposes the expected accessibility contracts on the simulator | Physical iPhone performance, background execution, or notification display |
| Hosted CI and testing release | Post-push check | Pending exact-commit workflow verification and artifact publication | Store or production release |

## Physical device and deployment

- Install/update action: not run on a physical device.
- Generalized device and OS class: Android API 35 managed emulator; iOS 26.5
  simulator; local macOS test host.
- Data-preservation result: no physical application container was mutated.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: representative Android and iPhone notification
  permission/channel transitions, process termination, reboot/time change,
  Doze/background delay, compatible-band R-R and motion flow, wrist haptic,
  battery impact, and in-place upgrade.

## Git and release state

- Changed paths: Apple daily review, journal reconciliation, contextual
  delivery, routing, onboarding, Automations, localization, and tests; Android
  daily review scheduling, stress cadence, routing, onboarding, Automations,
  manifest, localization, lifecycle identifiers, and tests.
- Commits: direct `main` commit containing this record.
- Branch and remote state: local `main` started equal to `origin/main` at
  `64c3b75b`; push equality is a post-commit check.
- Repository visibility verified: private canonical GitHub repository verified
  through the authenticated CLI.
- Version/build impact: no version or build-number change.
- Release or distribution impact: the community testing build is a post-push
  check; production/store release is not requested.

## Decisions

- Durable decision added or changed: daily guidance remains default-off and
  private; stress interruptions remain corroborated and rate-limited rather
  than random or subjective-event notifications.
- Decision-log entry: D-035.

## Open risks and honest limitations

- Android WorkManager and Apple local notifications are best effort and remain
  subject to permission, channel, force-stop, focus, battery, and OS scheduling
  policy.
- The stress prompt intentionally does not fire for every perceived stressful
  moment. It needs current corroborating physiology and motion, a warmed
  baseline, an eligible session state, and cooldown clearance.
- The Apple completion-aware evening schedule is bounded and repaired when the
  app launches or journal data changes; long periods without opening the app
  remain an operating-system scheduling limitation.
- Physical-device and representative band validation remain open.

## Next round

1. Exercise stress onset, journal completion, permission/channel changes,
   process termination, reboot, time-zone change, and in-place upgrade on
   representative physical Android and iPhone devices with a compatible band.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
