# Calendar-aware guidance physical-device runbook

This handoff covers the physical iOS and Android evidence that cannot be
collected on the current development Mac. It is intentionally narrower than a
general NOOP release test.

Use the repository's `$noop-ops` skill before starting. The checked-in source,
tests, and current operations record remain authoritative:

- `docs/ops/rounds/2026-09-10-calendar-aware-daily-guidance.md`
- `docs/ops/README.md`
- `docs/OBSERVABILITY.md`
- `docs/PRIVACY.md`

## Source state

- Branch: `codex/calendar-aware-daily-guidance-20260910`
- Pull request: `#14`
- Physical-device evidence must use the exact reviewed commit selected for the
  next replacement checks. Record that commit before installing either app.
- Do not merge, rebase, push, or regenerate policy snapshots while another
  agent is changing this branch.
- Do not use personal calendar content or real health exports. Create synthetic
  events and use a synthetic or empty test profile.

## Already verified locally

- Shared analytics: 1,461 tests passed, 7 expected skips, 0 failures.
- Complete macOS app suite: 1,750 tests passed, 1 expected external-data skip,
  0 failures.
- Android clean Full and Demo matrix: both APKs, both unit suites, both lint
  variants, and both instrumentation-source compilations passed.
- Unsigned iPhone, widget, and Watch dependency graph built successfully.
- Seven deterministic iPhone visual states passed, including accessibility
  text, increased contrast, dark mode, and the 6 h 12 min / 5:30 PM /
  1 h 18 min planned-workout fixture.
- The current Mac's iOS UI-test runner is not usable: two runs compiled the
  graph but Xcode repeatedly failed to materialize the UI-test worker with
  `DebuggerLLDB.DebuggerVersionStore.StoreError` and `no debugger version`.
  This is local test infrastructure evidence, not an app pass or app failure.

## Required devices

Use at least:

1. One supported iPhone on iOS 17 or later.
2. One Google-reference or near-reference Android phone on a currently
   supported release.
3. One Android phone from a vendor with restrictive background/battery policy.

A physical band is not required for the Calendar workflow. Hardware workout
detection, BLE collection, haptics, and firmware behavior belong to a separate
band round after the owner supplies the hardware/SDK dossier.

## Preparation

1. Record the exact Git commit, app version/build, phone class, OS version,
   locale, time zone, 12/24-hour setting, text size, notification state, and
   battery optimization state. Do not record serial numbers or account IDs.
2. Accept the current Terms through the normal launch flow.
3. Enable Adaptive Day Guidance, then enable its separate planned-workout
   Calendar option.
4. Grant Calendar and notification permission only when the app asks.
5. Create synthetic events such as `Strength workout`, `Yoga`, and `Morning
   run`. Do not use names, addresses, attendees, notes, or real locations.
6. Export one app report before testing and one after any failure. Verify that
   the archive contains only bounded categorical diagnostics, not calendar
   titles, exact times, health values, identifiers, or arbitrary errors.

## Core scenario matrix

Record each scenario as `pass`, `fail`, or `not run`. Capture a screenshot or
screen recording only when it contains synthetic data.

| ID | Scenario | Expected result |
|---|---|---|
| CAL-01 | First enable with Calendar denied | No plan is published, no prompt is scheduled, and the UI explains how to grant access without blocking core NOOP. |
| CAL-02 | Grant permission and add one future same-day workout | Today's Plan refreshes without navigation and retains only generic workout timing. |
| CAL-03 | Move the workout by five minutes | The visible start updates; the old action, notification, fingerprint, and retry state are retracted. |
| CAL-04 | Delete or decline the workout | Planned-workout guidance and its Workouts action disappear synchronously. |
| CAL-05 | Change the title from workout to meeting/runbook/commute | The event fails closed and no fitness guidance remains. |
| CAL-06 | Use a reviewed localized workout phrase | The event is recognized only when its language/context is supported. |
| CAL-07 | Use an ambiguous phrase such as train ride or deployment run | No workout guidance is produced. |
| CAL-08 | Revoke Calendar permission in system settings while app is open | Existing guidance, action, pending notification, and cooldown ownership are removed. |
| CAL-09 | Revoke permission while app is backgrounded, then reopen | No stale plan or prompt is shown after foreground reconciliation. |
| CAL-10 | Disable only the Calendar option | Calendar-derived state is removed while other Adaptive Day guidance remains eligible. |
| CAL-11 | Disable the Adaptive Day master switch | Every adaptive planned-workout artifact is removed, including a notification posted before private state persisted. |
| CAL-12 | Make Terms stale or unaccepted | No Calendar query, diagnostic start, durable worker, or prompt runs before the runtime gate is accepted again. |
| CAL-13 | Edit the sleep target or submit pain/unwell | The plan recomputes immediately; pain/unwell suppresses workout encouragement. |
| CAL-14 | Publish fresher sleep/readiness data during an in-flight evaluation | The older evaluator cannot publish or recreate the prior plan. |
| CAL-15 | Background the app before the two-hour boundary | One bounded best-effort reevaluation occurs; no stale notification copy is preloaded. |
| CAL-16 | Force-stop/terminate before the boundary | Record actual OS behavior. Never mark missing delivery as a product pass; iOS/Android may defer or suppress background work. |
| CAL-17 | Cross quiet hours or a global cooldown that ends before start | At most one retry is armed inside the remaining pre-workout window. |
| CAL-18 | Let the workout start pass naturally | Visible guidance expires, but accepted delivery history remains for cooldown integrity. |
| CAL-19 | Schedule a higher-priority timezone/travel prompt | Travel wins and stale workout notification/action/ownership are retracted first. |
| CAL-20 | Accept the prompt and relaunch the app | The canonical action opens Workouts and preserves prior dismissal/completion history. |
| CAL-21 | Reboot the phone with a future eligible workout | Restart reconciliation is fail closed and does not invent missing consent/evidence. |
| CAL-22 | Change time zone and cross DST/date boundaries | The event remains attached to the correct local planning day or is safely withdrawn. |

## Notification checks

- Confirm title/body text includes no event title, organizer, attendee,
  location, note, calendar name, exact health value, or diagnosis.
- Confirm the notification expires at the actual workout start.
- Confirm tapping opens Workouts, not Sleep or a stale route.
- Confirm a false positive can be corrected by editing/removing the synthetic
  calendar event and that the prompt disappears.
- Confirm permission loss immediately retracts the delivered notification when
  it is still owned by the workout path.
- Confirm removing a workout does not cancel a newer notification owned by
  another adaptive-day topic.
- Confirm quiet hours, global cooldown, topic cooldown, and higher-priority
  guidance remain authoritative.

## Performance and accessibility

Run CAL-02 through CAL-05 with:

- default text,
- the largest supported accessibility text size,
- increased contrast,
- reduced motion,
- light and dark appearance,
- VoiceOver or TalkBack,
- the app backgrounded and foregrounded repeatedly.

Record:

- cold and warm launch time,
- time from Calendar edit to visible plan update,
- dropped-frame or visible hitch evidence while scrolling Today,
- memory-pressure exit or ANR evidence,
- whether any label clips, overlaps navigation, or loses its accessibility
  name,
- whether controls retain at least the platform minimum touch target.

Do not log frame-by-frame telemetry. Use the existing bounded app report,
Instruments/MetricKit on Apple, and Perfetto/Android vitals-style traces on
Android. Keep raw traces outside Git and summarize only aggregate timing,
memory, and fixed failure categories.

## Suggested local commands

Generate the project before an Apple source build:

```bash
xcodegen generate
xcodebuild -scheme NOOPiOS -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Use the normal signing team to install the exact test commit on an iPhone.
Never commit provisioning files or print signing identities in the report.

For Android:

```bash
cd android
./gradlew --no-daemon assembleFullDebug
adb install -r app/build/outputs/apk/full/debug/app-full-debug.apk
```

Use `adb shell am force-stop` only for the explicit process-death scenarios.
Record whether the OS/OEM permits the scheduled worker afterward.

## Evidence handoff

Add one new operations round containing:

- exact commit and build identifiers,
- generalized device and OS classes,
- every scenario result,
- screenshots with synthetic data only,
- bounded timing/memory summaries,
- app-report redaction result,
- failure reproduction steps,
- what remains unproved,
- no credentials, serial numbers, calendar content, or health payloads.

Run:

```bash
python3 Tools/validate-ops-rounds.py --all .
python3 Tools/private-data-gate.py
git diff --check
```

Physical success does not close band, firmware, carrier, signing, legal,
clinical, calibration, store, or production-operations gates.
