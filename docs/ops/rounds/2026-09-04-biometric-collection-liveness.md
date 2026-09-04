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
behavior, and make exported Apple diagnostics report the actual selected band
family.

## Scope

### In scope

- Apple and Android live-biometric liveness clocks and recovery actions.
- Degraded 5/MG live-HR-only watchdog startup.
- Explicit off-wrist reconnect suppression.
- Empty-history/live-health separation.
- Persisted Apple model diagnostics and focused regression coverage.
- Build, lint, launch, documentation, and source publication gates.

### Non-goals

- Claim or invent 5/MG stored-history support without physical evidence.
- Override iOS force-quit or background-suspension contracts.
- Change physiological formulas, metrics, storage schemas, or cloud behavior.
- Treat simulator evidence as physical BLE validation.

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
    proves the band is off-body.
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
- Preserved the existing stale-family scan recovery: both clients rotate to the
  other supported family after eight seconds and persist the family actually
  discovered.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none; the change affects future live delivery
  recovery and does not delete or rewrite stored samples.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none; HR plausibility bounds are
  transport acceptance guards, not diagnosis or physiological validation.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused Apple liveness, empty-history, and diagnostic tests | 14/14 passed | Recovery ordering, family fuses, off-wrist behavior, battery/control separation policy, and model decoding are pinned | CoreBluetooth behavior on a physical phone |
| Android Full unit suite | 4,017 tests passed, seven intentional skips, zero failures | The mirrored liveness policy and existing Android contracts remain green | OEM background execution or physical BLE |
| Android Full lint | Passed | Changed Kotlin and tests satisfy the current static gate | Runtime radio behavior |
| Clean Android Full Debug build | Passed; exact APK installed | The complete installable app compiles and packages with the change | Signed Play release behavior |
| Android emulator cold-launch smoke | Passed; process remained alive with no fatal exception | The rebuilt APK installs and starts | Band pairing, notifications, reconnect, or data persistence |
| Focused Apple app-target compile/test | Passed | Changed Swift sources and tests compile in the app graph | iOS background behavior |
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
  diagnostics, mirrored tests, and this operations record.
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

## Next round

1. Connect the physical iPhone and worn band, install without clearing data,
   and run the validation sequence above.
2. Compare before/after durable HR frontiers and export the in-app diagnostic
   bundle if a gap remains.
3. If live collection recovers but no backfill arrives, continue 5/MG history
   protocol research as a separate capability rather than weakening the live
   watchdog.
4. Run signed iOS and Android release gates when distribution credentials and
   target devices are available.

## Privacy check

- [x] No credentials, raw biometric rows, personal identifiers, device
      identifiers, signing identities, or absolute personal paths are present.
