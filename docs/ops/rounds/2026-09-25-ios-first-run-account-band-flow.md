# Round: 2026-09-25 - iOS first-run account and band flow

## Status

- State: `local implementation and complete verification green; push and hosted integration pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `4604fd53d15b459d0c2251da8e8697134bdb30e1`
- End implementation commit: pending
- Record commit or PR: application pull request `#17`

## Objective

Make first launch unambiguous and short: do not mount Home before setup
completion, put account creation or sign-in before band setup, show only the
supported launch bands during onboarding, and preserve a direct returning-user
path after completed setup. Capture fresh and returning iOS simulator evidence.

## Scope

### In scope

- iOS launch gating for fresh and returning users.
- First-run step order and reduction.
- Launch-only device selection for NOOP Band and the retained WHOOP test
  transport.
- Focused tests, iOS simulator captures, accessibility review, localization,
  observability review, and cross-platform follow-up identification.

### Non-goals

- Claim simulator BLE, account-provider, signing, background, battery, haptic,
  firmware, or physiological evidence.
- Fabricate an account, band connection, ownership proof, or metric.
- Remove WHOOP while it remains the independent qualification transport.
- Commit supplier binaries, credentials, identifiers, or health data.

## Starting evidence

- `RootTabView` is mounted after Terms acceptance even while onboarding remains
  incomplete, so stale state or transition defects can expose Home underneath
  first-run setup.
- The onboarding map contains sixteen pages.
- When ownership configuration is absent, first-run device setup opens the
  complete device catalog rather than a launch-only list.
- The Apple device picker labels the WHOOP transport as `Noop Band`, while the
  actual supplier adapter is a separate optional row.
- The current macOS viewer screenshot is not physical-band evidence. macOS is a
  managed viewer and does not load the supplier adapter.

## Delivered

- Apple and Android use the same concise eight-stage first-run sequence:
  welcome, account, Bluetooth rationale, band setup, ownership, profile, plan,
  and completion.
- Returning users with completed setup retain the direct app path instead of
  replaying first-run pages.
- Apple derives setup completion from the durable registry after launch. A
  restarted process cannot skip band setup or supplier ownership because of a
  transient in-memory source.
- Apple advances only after device registration is verified by an
  authoritative registry read-back. Failed persistence remains in the picker
  with a localized retryable error instead of reporting setup success.
- Onboarding and the normal Devices action open the supported-band scope rather
  than the complete experimental source catalog.
- The supplier row appears only when its native adapter is available. A build
  that cannot pair the supplier band no longer presents a dead row.
- Android constructs optional scanners only when the matching supported action
  starts, and its concise onboarding page survives ordinary Activity
  recreation through schema-keyed saveable state.
- Customer-facing Devices actions now say `Connect band`; Apple and Android
  empty states explain that only pairable launch bands are shown.
- Dynamic accent-filled controls use the paired inverse-ink token. Android
  runtime tints use a tested black-or-white contrast resolver where no semantic
  ink token exists.
- Shared copy was added to the canonical nine-locale source and regenerated for
  Apple and Android.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: account and Bluetooth rationale remain
  explicit; unconfigured ownership remains unavailable rather than fabricating
  a successful account or claim.
- Health/medical claim impact and limitations: none. A saved source does not
  prove ownership, connection, measurement validity, or physiological accuracy.

## Observability

- Evidence that diagnoses success, rejection, and failure: bounded
  `onboarding.progress`, `onboarding.device_setup`, `device.registration`, and
  the existing source-specific pairing lifecycle.
- Existing evidence is sufficient for this presentation-only picker and
  contrast change; no additional event is needed for opening a list or drawing
  a button.
- Fixed step, direction, outcome, source-kind, and registration status are
  retained. High-frequency rendering and discovery samples are not logged.
- Account inputs, user text, identifiers, addresses, credentials, raw errors,
  timestamps, RSSI, sensor values, and health values remain excluded.
- Apple and Android share the same categorical setup outcomes. Physical radio
  and supplier SDK behavior remain blind until signed-device testing.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Pre-change complete macOS wall | 2,304 tests, one intentional skip, zero failures | Existing shared Apple source is green before the first-run change | iOS rendering or physical behavior |
| App-wide localization generator | 936 app-wide strings and 45 Android-only resources generated for 9 locales | Canonical source and generated catalogs are synchronized | Native-speaker review or visual fit |
| JSON and generated XML parse | Pass | Apple catalog and all Android locale resources are structurally valid | Runtime rendering |
| Root localization parser and full i18n audit | 50/50 parser tests pass; all supported translated-key catalogs have zero gaps; existing 236 Android and 132 Apple hardcoded-literal inventories remain visible | No locale-key gap was introduced and the existing literal backlog was not hidden | Native-speaker review or elimination of the existing hardcoded-literal backlog |
| Focused Apple app tests | 81/81 pass | The launch-band scope, explicit picker scope, first-run order, restart-safe durable setup, verified registry persistence, ownership selection, button ink, and related shared Apple contracts remain green | Physical BLE, signed-device behavior, or account-provider reachability |
| Focused Android app tests and compile | 31/31 pass; build successful | The launch-band policy, explicit picker scope, lazy scanner lifecycle, recreation-safe onboarding state, ownership selection, and contrast resolver compile and pass in the Full Debug app | Emulator rendering, physical BLE, or supplier native behavior |
| Exact iOS simulator build | Pass; phone app, Watch app, Watch complications, and widgets embedded | The current shared source and all Apple launch products compile together | Signing, App Store distribution, Watch transfer, or physical-band behavior |
| iOS first-run UI tests | 2/2 pass in 19.6 seconds | Onboarding opens the real supported-band picker, exposes compatible 5/MG and 4.0 test transports, hides supplier and experimental rows when their adapters are unavailable, and keeps the footer clear at an accessibility text size | Supplier availability on a native build, VoiceOver traversal, or physical discovery |
| iOS dark and light visual review | Pass; `/tmp/noop-20260925-supported-band-captures-v2/ios-band-picker-dark.png` and `ios-band-picker-light.png` | The real picker renders only the two pairable simulator rows and keeps foreground/background contrast legible in both appearances | Automated contrast certification or physical-device rendering |
| Android API 35 visual and hierarchy review | Pass; the exact Full Debug picker shows only `NOOP Band` when the adapter is available plus compatible 5/MG and 4.0 test transports, with no experimental rows; white `Connect band` uses black text and icon | The real Full APK presentation, labels, supported-only scope, and light-surface contrast are coherent on the emulator | Physical BLE, TalkBack traversal, OEM rendering, or supplier callbacks |
| Complete Android Full wall | `assembleFullDebug`, 5,099 unit tests with 7 intentional skips, `lintFullDebug`, and `compileFullDebugAndroidTestKotlin` pass; APK SHA-256 `0d52ccc50ec395477d262236a943eff1e12a2db4dbd925df88f989c6815a6abc` | The exact supplier-capable Full APK, complete unit surface, lint, and instrumentation sources compile together | Installation on a phone, background execution, or hardware transport |
| Complete macOS app wall | 2,312 tests with 1 intentional private-fixture skip and 0 failures | Shared Apple source, account/onboarding contracts, navigation, storage, metrics, and presentation regressions remain green | iPhone hardware, BLE, physical accessibility, or signed distribution |
| Complete repository and direct policy wall | 365 Tools tests with 1 intentional skip; 9 release controls; 10 required contexts; trusted self-check; 12 metrics, 3 revisions, 13 thresholds, 16 calibration guards; 18,330 terminology occurrences across 1,621 groups with 0 forbidden mappings; distribution, private-data, 1,310-file health-claims, Actionlint, shell, ShellCheck, changed-Python compile, 93 operations records, and diff hygiene pass | The exact local source satisfies repository-controlled release, privacy, claim, localization, workflow, trust, metric, and evidence contracts | Hosted exact-SHA execution, legal/store approval, or physical accuracy |

## Physical device and deployment

- Install/update action: exact Debug iOS simulator app and Android Full Debug APK
  installed and exercised in local simulators.
- Generalized device and OS class: local macOS host, iOS 26.5 simulator, and
  Android API 35 emulator.
- Data-preservation result: no schema or stored-data mutation.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: WHOOP and supplier discovery, pairing, authentication,
  reconnect, background collection, history, haptics, retention, battery, and
  physiological accuracy.

## Git and release state

- Changed paths: Apple/Android onboarding, band picker, Devices UI, shared
  button contrast call sites, design tokens/tests, generated localization, and
  operations records.
- Commits: pending.
- Branch and remote state: local branch is dirty; remote remains
  `4604fd53d15b459d0c2251da8e8697134bdb30e1`.
- Repository visibility verified: unchanged by this round.
- Version/build impact: none.
- Release or distribution impact: none until local verification, exact-head
  hosted checks, and protected integration pass.

## Decisions

- Durable decision added or changed: none. Existing launch-band, retained-WHOOP
  qualification, local edge collector, and fail-closed ownership contracts are
  preserved.
- Decision-log entry: none.

## Open risks and honest limitations

- Hosted exact-SHA checks and protected integration remain.
- Build/simulator evidence cannot validate physical BLE or supplier SDK
  behavior.
- GCP staging authentication is expired; this UI slice does not claim a live
  account or ownership deployment.

## Next round

1. Commit and push the verified working milestone, then inspect the replacement
   exact-SHA hosted checks.
2. Resolve only evidence-backed hosted findings, if any.
3. Integrate normally only after protected checks pass.

## Failed attempts and cleanup

- The first complete Apple and Android walls found only stale source-shape and
  localization-count assertions after the intentional first-run and catalog
  changes. Those assertions were updated to the current behavior and both
  complete walls then passed.
- Independent review found an Apple restart bypass, premature Apple setup
  success before durable registration, eager Android construction of hidden
  scanners, and non-saveable Android page state. All four were corrected before
  the final focused and complete walls.
- The first Apple complete-wall attempt inherited a signing setting that was
  inappropriate for the unsigned local run. The exact rerun with
  `CODE_SIGNING_ALLOWED=NO` passed.
- One Android focused assertion still expected the pre-change eager scanner
  lifecycle. It was updated to the intended inert-until-action contract, then
  the focused and complete reruns passed.
- The first complete Tools wall found five stale source-contract assertions.
  The second failed closed because the reviewed terminology snapshots had not
  yet been repinned in the release trust map. Focused review, exact digest
  repinning, and the unchanged complete rerun passed.
- The Android emulator was shut down after evidence capture. The exact
  5.7-GiB round-owned Apple DerivedData tree and temporary terminology-review
  directories were deleted after confirming no build held them. Supplier
  binaries, simulator data, source, screenshots, credentials, and unrelated
  caches were not removed.

## Privacy check

- [x] No credentials, personal identifiers, raw biometric values, signing
      identities, or supplier artifacts are included.
