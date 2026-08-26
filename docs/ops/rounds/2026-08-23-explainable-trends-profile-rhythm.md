# Round: 2026-08-23 - Explainable trends, profile identity, and rhythm context

## Status

- State: `completed`
- Owner: project team
- Branch: `main`
- Start commit: `2e09c09f`
- Concurrent baseline retained: `d3b741dc` landed the independent brand-literal
  ratchet while this round was in progress.
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Make Today patterns state what changed, make Trends values inspectable and
self-explanatory, exclude recorded activity from the experimental Rhythm read,
and add a local editable display name defaulting to Noop. Confirm the existing
stress and breathing haptic behavior, and make band-tap precedence clear.

## Scope

### In scope

- Apple and Android analytics/UI parity for changed evidence and Rhythm gates.
- Hold/drag trend inspection on iPhone and clearer range-average labels.
- Local-only profile display name and personalized Today greeting.
- Honest stress, breathing, and tap-action guidance.
- Regression tests, app builds, and operations handoff.

### Non-goals

- Diagnostic rhythm or stress claims.
- Enabling automatic Android stress interruption without timestamp-matched
  wrist-motion evidence.
- Changing score formulas or releasing a production artifact.

## Starting evidence

- The pattern card exposed an internal Foster monotony value instead of a
  plain description of the observed Effort range.
- Apple trend charts supported pointer hover but not deliberate touch
  inspection; Android already supported tap and drag.
- Rhythm used stillness and resting-rate gates but did not explicitly reject a
  recorded workout overlapping a quiet-looking window.
- The profile had an on-device photo but no local display name.
- Qualified Apple stress nudges and paced band haptics already existed. Android
  automatic stress nudges were intentionally capability-gated off.

## Delivered

- Replaced the internal Foster monotony evidence with the recorded Effort
  range and average on Apple and Android. Pattern cards and detail sheets now
  lead with `WHAT CHANGED`.
- Added a 0.25-second hold, haptic acknowledgement, and drag inspection to
  iPhone trend charts while preserving ordinary card taps. Range summaries now
  say they are averages, show each score scale, localize `AVG`, and expose the
  descriptor to VoiceOver.
- Added a local display name that defaults to Noop, normalizes whitespace, and
  caps at 32 user-perceived characters without splitting accents, flags, skin
  tones, or joined emoji. Today greetings use it on Apple and Android.
- Kept the display name out of Self-hosted Sync and shareable backup settings.
  Empty input removes the preference and restores Noop.
- Added recorded-workout context to the experimental Rhythm screener. Any
  overlapping, non-dismissed workout makes the window unreadable even when a
  stationary wrist looks still.
- Wired Android Rhythm to the latest consent-gated night. Both platforms read
  active and canonical R-R namespaces, keep duplicate beat trains separate,
  rank readable/covered sources conservatively, refresh after history sync,
  and fail closed on missing motion or an elevated resting-window rate.
- Applied durable false-workout dismissals before Android Rhythm activity
  gating so a bout the user rejected cannot keep suppressing the night.
- Kept Rhythm opt-in, descriptive, non-diagnostic, and unable to send an alert.
- Added a band-tap precedence guide for alarm, hydration, SOS, and the selected
  fallback action. SOS copy now says accepted contacts are paged, matching the
  SMS-first delivery path rather than promising an immediate voice call.
- Added restrained phone haptics for paced breathing when no band is bonded.
  Existing qualified Apple stress nudges and band-paced breathing haptics were
  confirmed; Android automatic stress interruption remains disabled without
  timestamp-matched wrist-motion evidence.
- Added 22 shared app-wide localization keys across nine locales and corrected
  the localization parity ratchet from 100 to 122 generated keys.
- Completed an independent source review and fixed every reported issue,
  including Unicode graphemes, translated SOS semantics, sparse/noisy R-R
  source selection, canonical data after re-pairing, and dismissed workouts.

## Data, privacy, and medical truth

- Schema or migration impact: none. Android adds a read-only DAO query; no
  table, column, or migration changed.
- Existing-data retention impact: additive local display-name preference only;
  no existing health, profile, band, or app data is reset.
- Source/provenance or formula impact: no score, baseline, calibration, or
  biological-age formula changed. Readiness presentation and Rhythm context
  selection changed.
- Permissions/network disclosure impact: display name remains local and is not
  added to Self-hosted Sync or shareable backups.
- Health/medical claim impact and limitations: Rhythm remains an opt-in,
  descriptive visualization that never sends alerts. Workout, motion, and
  elevated-rate gates reduce false interpretation; they do not validate AFib,
  ECG, arrhythmia, medical accuracy, or emergency detection.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| StrandAnalytics package | 1,323 tests passed | Readiness evidence and Rhythm activity/rate gates pass with the broad analytics graph | Clinical validity or production sensor accuracy |
| StrandDesign package | 44 tests passed | Shared trend-chart and design contracts remain green | Touch behavior on a physical phone |
| Focused Android readiness, Rhythm, profile, and localization tests | Passed | New source selection, workout dismissal, grapheme, and 122-key parity regressions pass | Android OEM runtime behavior |
| Android Full Debug unit suite | 3,573 tests, 0 failures, 6 skipped | Broad Android source and behavior graph is green | Instrumentation, BLE, background, or physical haptics |
| Android `assembleFullDebug` | Passed | The Full Debug APK assembles with the Room query and generated resources | Release signing or Play acceptance |
| Generic iOS simulator Debug build | Passed | Final Apple source and String Catalog compile for iOS | Runtime layout, hardware, signing, or App Review |
| macOS Debug build | Passed | Final shared Apple source compiles for macOS | Full app-suite behavior or notarization |
| Focused macOS profile and brand-ratchet tests | Passed | Local profile persistence and existing brand-localization debt ratchet remain intact | Every profile workflow |
| `python3 Tools/i18n_audit.py --ci origin/main` | Passed; no new debt | Focus locales are complete and no baseline debt was added | Native-speaker approval of translations |
| Health-claims, legal-inventory, and private-data gates | Passed; 1,041 source files scanned by the claims gate | This diff adds no prohibited claim, missing legal inventory item, or private-data filename | Commercial distribution clearance |
| Independent source review | All findings resolved | A separate reviewer found no remaining concrete issue in the changed source | Physical-device or medical validation |
| `git diff --check` | Passed | The implementation diff is whitespace-clean | Behavioral correctness |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: generic iOS simulator compile destination
  and macOS host build only; no runtime simulator or physical device session.
- Data-preservation result: no app container, phone, or band data was mutated.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: physical band and phone vibration, tap gestures, workout
  overlap from real recordings, overnight sync, reconnect, background delivery,
  OEM behavior, and device-specific rendering.

## Git and release state

- Changed paths: shared analytics/design packages; Apple profile, Today, Trends,
  Rhythm, breathing, automations, localization, and tests; Android analytics,
  profile, Today, Trends, Rhythm route/storage read, breathing, automations,
  generated localization, and tests; operations and release handoffs.
- Commits: one direct-to-`main` implementation and documentation commit after
  the retained concurrent brand-ratchet commit.
- Branch and remote state: local `main` will be pushed to canonical
  `origin/main`; exact parity is verified after the push.
- Repository visibility verified: private at the preceding authenticated
  repository audit.
- Version/build impact: no marketing version or build number change.
- Release or distribution impact: no artifact published. The source-rights
  review active during this round was cleared on 2026-08-25.

## Decisions

- Experimental Rhythm remains a consent-gated descriptive view, never an alert
  path, and fails closed when resting context is not supported.
- A profile display name is local UI identity, not account, Friends, sync, or
  backup identity.
- Decision-log entry: D-013 and D-014.

## Open risks and honest limitations

- Physical-device haptics and wearable context cannot be proven by simulator
  or unit tests.
- A recorded-workout gate cannot identify an unrecorded workout. Motion and
  elevated-rate gates still fail closed, but require participant/device
  validation.
- Choosing among duplicate R-R namespaces improves data completeness; it does
  not establish medical-quality beat timing.
- The 22 translated keys remain subject to native-speaker review.
- The current release gate still requires the owner-rights record, NOOP license,
  and exact independent dependency notices.

## Next round

1. Complete physical-device validation for tap precedence, phone/band haptics,
   re-paired canonical history, overnight Rhythm refresh, and real workout
   overlap without resetting user data.
2. Continue native-speaker localization review, accuracy studies, Safety
   provider staging, store signing, and release metadata under their existing
   release gates.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
