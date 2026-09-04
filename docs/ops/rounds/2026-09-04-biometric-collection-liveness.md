# Round: 2026-09-04 - Biometric collection liveness

## Status

- State: `implemented and locally verified; physical-band validation remains`
- Owner: project team
- Branch: `main`
- Start commit: `4fc72d50`
- End implementation commit: commit containing this record

## Objective

Prevent a connected-looking band session from silently stopping biometric
collection while battery, metadata, or command traffic continues. Apply the
same recovery contract on Apple and Android, preserve off-wrist battery
behavior, and make exported diagnostics prove whether durable collection is
advancing. Preserve locked-phone CoreBluetooth restoration across launch-gate
upgrades, and make the iPhone shake report actionable when a user can only
describe the app as "buggy."

## Scope

### In scope

- Apple and Android live-biometric liveness clocks and recovery actions.
- Degraded 5/MG live-HR-only watchdog startup.
- Explicit off-wrist reconnect suppression.
- Empty-history/live-health separation.
- Persisted Apple model diagnostics and focused regression coverage.
- Locked-launch receipt accessibility and legacy-receipt migration.
- Indexed persisted-HR evidence in Apple and Android report metadata.
- Privacy-bounded iPhone shake reports with optional user context and explicit
  screen-snapshot consent.
- App, database, self-hosted sync, and NOOP+ sync breadcrumbs needed to
  distinguish UI pressure from storage, transport, and backend failures.
- Build, lint, launch, documentation, and source publication gates.

### Non-goals

- Claim or invent 5/MG stored-history support without physical evidence.
- Override iOS force-quit or background-suspension contracts.
- Change physiological formulas, metrics, storage schemas, or cloud behavior.
- Treat simulator evidence as physical BLE validation.
- Upload diagnostics automatically or include the health database, raw sensor
  history, credentials, endpoints, tokens, account IDs, or server payloads.
- Claim that one report can diagnose every possible defect without a
  reproducible path or delayed operating-system diagnostics.

## Starting evidence

- A physical-phone report showed multi-hour biometric gaps while the app still
  appeared connected.
- Battery/control traffic could keep the old generic BLE activity timestamp
  fresh even when live heart-rate delivery had stopped.
- The 5/MG live-HR-only fallback marked the link usable but did not start the
  existing keep-alive watchdog.
- Sustained empty 5/MG history support stretched the old liveness fuse, coupling
  historical capability to live collection health.
- Apple diagnostics compared persisted model values against legacy short names,
  so a current 5/MG selection could be mislabeled as 4.0.
- The reported band did not hand over usable stored history. That is a separate
  firmware/protocol limitation: reconnecting can restore future live
  collection, but cannot reconstruct samples the app never received.

## Delivered

- Split transport activity from biometric activity on Apple and Android.
  Battery, DIS, command responses, and other control packets remain useful
  diagnostics but no longer reset the biometric watchdog.
- Advance biometric liveness only for checksum-valid, physiologically plausible
  live HR. Apple 5/MG continues to use standard `0x2A37` as its sole liveness
  source because that is its authoritative persisted live stream.
- Added staged recovery:
  - after biometric silence, rewrite live notification subscriptions once;
  - if accepted HR still does not resume, reconnect the link;
  - use a two-minute 4.0 stall fuse and a ten-minute 5/MG fuse;
  - suppress repeated reconnects only when a fresh `WRIST_OFF` event explicitly
    proves the band is off-body, and expire that evidence after 15 minutes so a
    missed `WRIST_ON` cannot disable recovery indefinitely.
- Start the watchdog when 5/MG standard HR establishes the degraded
  live-HR-only link, while keeping encrypted command and battery maintenance
  gated on a genuine bond.
- Decoupled empty-history detection from live-stream recovery. Empty history
  still produces honest experimental-history status and slower history probes;
  it cannot disable biometric recovery.
- Added recovery logs that state whether subscriptions were re-armed or the
  link was reconnected, including transport-silence context.
- Corrected Apple diagnostic model decoding for both current display-string
  values and legacy short values.
- Changed the launch-access receipt to
  `AfterFirstUnlockThisDeviceOnly`, preserving its device-only boundary while
  allowing a CoreBluetooth relaunch to resume after the phone has been unlocked
  once. Existing `WhenUnlockedThisDeviceOnly` receipts migrate when first read;
  a protected-data availability edge retries an upgrade that initially launched
  while locked.
- Added an indexed latest-persisted-HR frontier to Apple and Android report
  metadata and to the human-readable report. This distinguishes a transport
  that still shows battery/control traffic from a biometric stream that is
  actually saving new samples.
- Added `Tools/verify-ios-band-collection.sh` to copy and inspect an installed
  app database without modifying the phone. It compares persisted HR and
  battery frontiers and can watch them advance during a locked-phone test.
- Expanded the iPhone and Android shake reports into a consent-first flow:
  - an optional, 1,000-character explanation asks what the user tapped,
    expected, and observed;
  - the note is control-character filtered, whole-bundle redacted, reviewed,
    and attached only to that report;
  - a pre-report screen snapshot is transient, excluded by default, accepted
    only as a valid PNG under 8 MiB, and attached only after explicit opt-in;
  - the user can remove the snapshot from the completed report before sharing;
  - closing the flow discards the note, snapshot, and assembled entries.
- Record the shake trigger and process-resource snapshot before attempting the
  optional screen render, so a slow or failed screenshot cannot hide the report
  edge itself. Android also exposes the same flow from Test Centre.
- The app-runtime bundle now includes current and previous bounded sessions,
  scroll/frame hitch summaries, main-thread stalls, lifecycle and fixed-screen
  breadcrumbs, database open/refresh/analysis operations, process memory,
  database and disk footprints, thermal and low-power state, Apple MetricKit
  crash/hang payloads, Android OS exit/ANR evidence, bounded crash traces,
  redacted band logs, selected model/capability metadata, and durable HR age.
  Runtime diagnostic bodies remain attached but are only named in the Android
  review UI, avoiding a large Compose text layout while retaining the evidence.
- Install Android crash capture immediately after the bounded diagnostics
  recorder, before application initialization that could itself fail.
- Added privacy-safe begin/end breadcrumbs for self-hosted and NOOP+ sync.
  Success records bounded counts and continuation state; failure records only a
  stable category such as offline, timeout, authentication, quota, integrity,
  or local-store failure. URLs, credentials, identifiers, request/response
  bodies, and server text are excluded.
- Pinned the Maven Central SHA-256 for the JUnit 5.9.2 Gradle module used only
  when the hosted managed-device runner resolves Unified Test Platform. The
  independently downloaded artifact matched the local Gradle cache byte for
  byte.
- Preserved the existing stale-family scan recovery: both clients rotate to the
  other supported family after eight seconds and persist the family actually
  discovered.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none; the change affects future live delivery
  recovery and does not delete or rewrite stored samples.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none. Reports remain local until the
  native share sheet opens after explicit review.
- Optional-report context: free text is bounded and redacted; screenshots are
  transient and opt-in. Neither is written to always-on diagnostics.
- Health/medical claim impact and limitations: none; HR plausibility bounds are
  transport acceptance guards, not diagnosis or physiological validation.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused Apple liveness, empty-history, and diagnostic tests | 15/15 passed | Recovery ordering, family fuses, bounded off-wrist behavior, battery/control separation policy, and model decoding are pinned | CoreBluetooth behavior on a physical phone |
| Apple app-target integration suite | 1,605 tests executed, one intentional external-fixture skip, zero failures | The report, launch-access, liveness, and existing app contracts remain green | iOS background execution or physical BLE |
| Android Full and Demo unit suites | 4,026 tests executed per flavour, seven intentional skips per flavour, zero failures or errors | Report parity, liveness, and existing Android contracts remain green in both product flavours | OEM background execution or physical BLE |
| Android Full lint | Passed | Changed Kotlin and tests satisfy the current static gate | Runtime radio behavior |
| Android Full production-shell instrumentation | 40/40 passed on API 35 | The rebuilt app installs and the touch-driven report flow, consent default, navigation, and production shell execute on-device | Physical band behavior |
| Clean Android Full Debug build | Passed; exact APK installed | The complete installable app compiles and packages with the change | Signed Play release behavior |
| Android emulator cold-launch smoke | Passed; process remained alive with no fatal exception | The rebuilt APK installs and starts | Band pairing, notifications, reconnect, or data persistence |
| Focused Apple app-target compile/test | Passed | Changed Swift sources and tests compile in the app graph | iOS background behavior |
| Focused Apple report and launch-access tests | 27/27 passed | Optional context, screenshot validation, report privacy, metadata, bounded diagnostics, and locked-launch receipt contracts are pinned | A physical shake or locked-phone BLE wake |
| Focused iOS app-report UI test | Passed | The consent sheet presents optional context, defaults the screenshot off, builds, reviews, and reaches the share action | Physical shake delivery or user-selected share destination |
| iOS Debug simulator app graph after report changes | Passed for app, Watch, widgets, and both simulator architectures | The production target graph accepts the report and launch changes | Signing or a physical phone |
| Android focused report tests | Passed | Optional context, PNG validation, report/Test Centre isolation, metadata, bounded recorder storage, route sanitization, shake thresholding, and review rendering are pinned | OEM sensor behavior |
| Clean iOS Release simulator graph | Passed for app, Watch, complications, and widgets; changed files emitted no warnings | The complete Apple production configuration compiles for arm64 and x86_64 simulator architectures | Signing, App Store archive, or physical CoreBluetooth |
| CoreDevice probe | Service responded, but no iPhone was connected | The prior host-service timeout is no longer the current blocker | Any claim about new on-phone samples |
| `git diff --check` | Passed | The source delta has no whitespace errors | Functional correctness |

## Physical device and deployment

Physical-band validation remains mandatory before calling the field issue
closed:

1. Install the resulting build on a phone without deleting its app container.
2. Confirm the app identifies the actual family and receives current HR.
3. Record persisted HR and battery frontiers, then leave the band worn with the
   phone locked for at least one family stall window.
4. Verify new persisted HR rows continue landing, not merely that the UI says
   connected or shows battery.
5. Force a controlled notification interruption if a reproducible method is
   available and verify the log shows one re-arm followed by reconnect only if
   HR remains absent.
6. Repeat through foreground, locked-background, app relaunch, Bluetooth
   toggle, and an in-place upgrade while preserving the existing database.

- Install/update action: rebuilt Android APK installed on an emulator only; no
  physical app container was changed.
- Generalized device and OS class: Android emulator and iOS simulator build
  targets.
- Data-preservation result: emulator update used install-in-place; physical user
  data was not accessed or modified.
- BLE/background/haptic/battery scenarios exercised: none on hardware.
- Unrun hardware gates: the six-step sequence above.

## Git and release state

- Changed paths: Apple and Android BLE clients, Apple frame routing and
  diagnostics, launch access, report assembly/UI, sync diagnostics, durable
  frontier probes, mirrored tests, the field verifier, and this operations
  record.
- Branch and remote state at start: `main` matched `origin/main` at
  `4fc72d50`.
- Version/build impact: no version, database, entitlement, permission, or
  dependency change.
- Release or distribution impact: source publication only until signed release
  credentials and physical targets are available.

## Decisions

- Generic BLE traffic is not evidence of biometric persistence.
- Live collection health and stored-history capability are independent state
  machines.
- Recovery is staged: one subscription repair before reconnect.
- Only explicit live wrist evidence suppresses reconnect; default UI state does
  not.
- Durable stored HR advancement, not a connected label or battery percentage,
  is the field-validation criterion.
- A bug report should collect bounded operational evidence continuously, then
  ask for a short optional explanation at report time. It should not turn
  health data, arbitrary UI state, or network payloads into telemetry.
- A screenshot is useful UI evidence but is sensitive binary data; capture it
  transiently before the report sheet, exclude it by default, and require
  explicit reviewable consent.
- The shake breadcrumb must precede screenshot rendering so the diagnostic path
  cannot erase its own trigger evidence.

## Open risks and honest limitations

- A user force-quitting the iOS app prevents iOS from relaunching it for
  Bluetooth events. App code cannot override that operating-system contract.
- iOS may suspend timers in the background. The watchdog evaluates accumulated
  silence when execution resumes, but simulator tests cannot prove wake cadence.
- If a band returns an empty history cursor, no phone-side cloud or database
  change can recover samples never transmitted by the band. Cloud backup helps
  retention and device performance after upload; it does not create missing
  sensor history.
- Battery visibility proves some transport capability, not ongoing biometric
  persistence. The durable HR frontier is the collection proof.
- The longer 5/MG fuse limits reconnect churn on an off-body or partially
  bonded band, so recovery from an otherwise silent stream can take up to ten
  minutes while the process is executing.
- Fresh off-wrist evidence can defer that reconnect for at most 15 minutes.
  This trades one bounded recovery delay for lower off-body radio churn; stale
  evidence is never allowed to suppress recovery indefinitely.
- A completely blocked main thread cannot present the report sheet until it
  recovers. The watchdog records the stall/recovery, and MetricKit may provide
  delayed hang diagnostics on a later launch; a user can then shake and export
  the current and previous bounded sessions.
- Free-form context can still contain information the user chooses to type.
  The UI warns against names/contact details, applies known redaction, and
  requires exact-bundle review, but no finite scrubber can infer every form of
  personal prose.
- Backend evidence is client-observed timing, counts, continuation state, and a
  stable failure category. A server-only defect still requires correlating the
  report's UTC timestamps with retained Cloud Logging; credentials, endpoints,
  account identifiers, and server payloads are intentionally not copied into
  the user ZIP.

## Next round

1. Connect the physical iPhone and worn band, install without clearing data,
   and run the validation sequence above.
2. Compare before/after durable HR frontiers and export the in-app diagnostic
   bundle if a gap remains.
3. Ask a field tester who observes lag to enter the exact tap/expected/result
   sequence, leave the screen snapshot off first, and verify the report shows
   the matching UI/backend breadcrumbs. Repeat with snapshot consent only when
   visual evidence is necessary.
4. If live collection recovers but no backfill arrives, continue 5/MG history
   protocol research as a separate capability rather than weakening the live
   watchdog.
5. Run signed iOS and Android release gates when distribution credentials and
   target devices are available.

## Privacy check

- [x] No credentials, raw biometric rows, personal identifiers, device
      identifiers, signing identities, or absolute personal paths are present.
