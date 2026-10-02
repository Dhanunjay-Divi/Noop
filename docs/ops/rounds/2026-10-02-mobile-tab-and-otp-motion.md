# Round: 2026-10-02 - Mobile tab and OTP motion

## Status

- State: `hosted iOS failure reproduced and corrected in the UI harness; replacement protected integration pending`
- Owner: project team
- Branch: `codex/mobile-liquid-tab-otp-motion-20261002`
- Start commit: `dbd23c25e4f681c4a087642b41441270fa15c3a0`
- End implementation commit: pending final checkpoint
- Record commit or PR: pending protected pull request

## Objective

Give iPhone and Android one matched five-tab navigation treatment and a clearer
managed-account verification interaction without changing health data,
formulas, band transport, account authority, or server behavior.

## Scope

### In scope

- The selected-tab lens and fixed five-tab geometry on iPhone and Android.
- Managed-cloud verification-code entry, SMS autofill, invalid-code feedback,
  server-confirmed success feedback, reduced motion, and accessibility.
- Shared design tokens, focused contracts, bounded builds, and paired visual
  review.

### Non-goals

- Identity-provider behavior, real SMS delivery, App Check, payment,
  entitlement, backend deployment, BLE, firmware, background collection,
  haptics, battery, or metric accuracy.
- Replacing the separate movable NOOP `N` quick-action lens.

## Starting evidence

- The five destinations and labels already matched semantically, but selection
  still read as separate per-item highlights rather than one moving lens.
- Managed-cloud verification used a generic text field and did not provide
  bounded visual confirmation after the server advanced the account state.
- The underlying Apple and Android services accept four through eight numeric
  characters. A first UI draft incorrectly narrowed that contract to exactly
  six ASCII digits and retained the code for its success animation. Independent
  review blocked that draft before commit.

## Delivered

- Added one raised selected lens that moves across Today, Trends, Workouts,
  Sleep, and More on both platforms while retaining all labels, tab roles,
  reselect behavior, minimum touch targets, localized text fitting, and the
  separate movable N action center.
- Moved the new rail, lens, verification-slot, and confirmation dimensions into
  matched Apple and Android design tokens.
- Reduced Motion now snaps the selected position, tint, scale, invalid-code
  feedback, and confirmation state instead of running shortened animations.
- Added an eight-slot maximum verification field with a four-digit minimum,
  SMS one-time-code autofill, paste support, and localized decimal-digit
  normalization to ASCII. Four-, five-, six-, seven-, and eight-digit service
  codes remain submit-capable.
- Invalid server responses keep the entry visible and trigger bounded feedback;
  no verification value is written to diagnostics.
- A confirmed service transition clears the code immediately, stores only a
  Boolean presentation state, and shows an abstract checkmark. The verified
  code is never copied into or redrawn by the success overlay.
- The editable verification field exposes only a masked accessibility value on
  both platforms, and the server-confirmed success state remains visible for
  three seconds without retaining the code.
- Apple and Android route dismissal through testable cancellation-aware
  policies. Phase reset and sheet disposal cancel pending dismissal work, so a
  stale overlay cannot mutate a later presentation state.
- Android success dismissal runs in a sheet-owned job that is canceled on
  phase reset or disposal, preventing a stale pointer-blocking overlay.
- Removed untranslated numeric accessibility status and hint text. Apple and
  Android retain their existing localized field labels and native editable-field
  semantics; the server-confirmed overlay takes accessibility focus or emits an
  assertive live-region announcement while underlying controls are hidden.
- Completed the selected-lens token pass on both platforms, including body,
  rim, highlight, spacing, label padding, and palette ownership.
- iPhone now reserves the measured dock footprint at every text size while the
  keyboard is hidden. The dock still reads as floating glass, but metric cards
  no longer render beneath persistent navigation; Android already obtained the
  equivalent non-overlap from `Scaffold`.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none. Demo values are synthetic.
- Secret handling: verification codes remain transient view state, are cleared
  immediately after confirmed success or sheet dismissal, and are not logged,
  persisted, copied into success state, or committed in evidence.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  managed-service phase/status state, focused contracts, bounded command status
  files, exact app-package and screenshot hashes, and launch results.
- Why existing evidence is sufficient: send and verify operations already emit
  bounded service outcomes without OTP values. The new boundary is presentation
  state and requires no new payload logging.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: no code values, phone
  numbers, tokens, health rows, or drag coordinates enter repository evidence.
- Cross-platform/backend correlation: matched Apple/Android contracts; backend
  behavior is unchanged.
- Remaining blind spots: real carrier delivery, signed-device autofill,
  VoiceOver/TalkBack traversal, physical frame pacing, and provider rejection
  timing.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Independent review | Two reviews found the original contract narrowing, OTP retention/exposure, lifecycle, Reduced Motion, accessibility, tokenization, geometry, and evidence defects. The exact-current re-review found no remaining code defect after direct dock-boundary geometry and executable success-window/cancellation coverage were added; its procedural file-tracking and stale-record findings are closed by the final checkpoint | The review process changed the implementation and its tests before protected integration rather than accepting build status as closure | Physical-device behavior or provider correctness |
| Android production compile | Bounded `compileFullDebugKotlin` passed | Current Full production Kotlin compiles with the corrected UI | Signed phone behavior |
| Android focused contract | Exact-current `PrimaryNavigationContractTest` passed 12/12 with Full production and instrumentation-source compilation | Five-tab semantics, moving lens, four-to-eight digit normalization, Reduced Motion, autofill, non-retained success state, a full three-second virtual-time window, and cancellation are enforced | Instrumented TalkBack behavior or real OTP |
| Android APK | Bounded `assembleFullDebug` passed; SHA-256 `3a134fc284b029c82afb2e9859191f0cdbd01d055d145a5761b12808ec6ada05` | The exact Full debug candidate packages | Store signing or physical install |
| Android onboarding, Trends, and package wall | `OnboardingOwnershipStepSelectionTest`, `OnboardingInstrumentationHarnessTest`, `TrendsHistoryLoadTest`, `TrendsAxisLabelsTest`, and `assembleFullDebug` passed together | Required onboarding policy, useful Trends history/axis behavior, and packaging remain intact around the navigation change | Physical BLE, signed install, or OEM background behavior |
| Android visual review | API 35 `1080x2424` Today capture SHA-256 `39ca83ea18cb2cd9b64abd188dc6d2da0298fa8d70f7f0045e280708953ff23b` | Labels fit, the selected lens is centered, content is not covered incoherently, and the N remains bounded | OEM rendering, touch comfort, or physical TalkBack |
| Apple focused contracts | Original managed-cloud/shell set passed 67/67; exact-current `ManagedCloudRetryContractTests`, `MoreListParityTests`, and `SafetyPagingAndShellContractTests` passed 86/86 after the dock-reservation and success-lifecycle corrections | Verification normalization/privacy, a real three-second minimum window, cancellation, tab semantics, and non-overlapping persistent navigation are enforced with existing Safety shell contracts | iOS-only compilation by itself |
| Complete iPhone graph | Exact-current bounded `NOOPiOS` Simulator build passed, including Watch and widgets | The iOS-conditional verification view and shared design package compile in the mobile graph | Signing, physical Watch, BLE, or background behavior |
| Clean iPhone first-run journey | `testFreshInstallOrdersTermsBluetoothAndBandSetupBeforeAccount` and `testConfiguredProviderAndSyntheticBandCompleteFullOnboarding` passed 2/2 | Terms, Bluetooth, supported-band setup, account, and configured synthetic completion remain in the required order | Real provider, carrier, physical band, or signed-phone behavior |
| iPhone dock-boundary regression | `testTodayOrdinaryTextViewportReservesExpandedNavigation` passed 1/1 using the minimum tab `frame.minY` as the actual navigation boundary | The ordinary-text Today viewport ends above every expanded persistent tab control | Other screens, physical display scaling, or touch comfort |
| Hosted Recovery scrub correction | PR `#32` run `37022388421` reproduced a single iOS shell failure in `testRecoveryTrendSupportsExactDateScrubbing`: the chart was present and hittable, but the short `0.35`-second, five-percent-width gesture did not consistently publish the selected-date accessibility value. The production chart was not changed. A clean regenerated project and fresh DerivedData first passed the replacement `0.8`-second, thirteen-percent-width gesture 5/5. Independent review then required the harness to prove the expected seeded date rather than only a changed value. The final exact-date regression passed 5/5 in `118.707` seconds with zero failures; every iteration confirms the new duration, coordinates, and seeded `Tue 15 Sep` selection | The replacement harness deterministically exercises the existing long-press scrub interaction and x-to-date mapping on the current simulator graph instead of relying on a threshold-adjacent gesture | Physical touch latency, other devices, or the replacement hosted head until protected CI reruns |
| Private native pilot sources | Apple and Android private-pilot assertions compile and verify masked/password semantics, success-overlay appearance, and secret-field removal after the confirmed phase transition | The opt-in physical/provider pilot will fail if those semantics regress | Runtime provider behavior because private pilot inputs were unavailable and the cases were not executed |
| iPhone visual review | iPhone 17 Pro Simulator `1206x2622` Today capture SHA-256 `61bf5f650a6781ec3e4a1d1f511b77791683312efe380213a8fb2080b455af34` | The matched selected lens, labels, cards, movable N, and reserved dock region render without observed clipping or incoherent overlap | Every locale, Dynamic Type size, or physical display |
| All-platform i18n | Full audit passed with zero translated-key gaps in supported Apple catalogs | New localized Apple accessibility text and existing Android resources remain within coverage policy | Human linguistic review |
| Diff hygiene | `git diff --check` passed on the exact current source before documentation closeout | No whitespace-error regression | Runtime correctness outside listed gates |

## Physical device and deployment

- Install/update action: unsigned Full debug APK installed on an API 35
  emulator; unsigned iOS app installed on an iPhone 17 Pro Simulator.
- Data-preservation result: synthetic demo state only; no store or migration
  changed.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun gates: signed phones, real SMS/autofill, App Attest, Play Integrity,
  physical band sources, BLE, background, battery, haptics, and sensor accuracy.

## Git and release state

- Changed paths: shared design tokens and verification-success policy,
  iPhone/Android shell navigation, iPhone/Android managed-cloud verification
  views, focused contracts, and this operations record.
- Implementation commit: pending replacement checkpoint after the hosted scrub
  harness correction.
- Branch and remote state: local branch includes protected `main`
  `a8a617593b4b81485fca672353ebcebe2d073f55`; PR `#32` is open with auto-merge
  armed. Its first exact-head run passed Android, macOS, packages, policy, and
  repository controls but failed the threshold-adjacent iOS Recovery scrub
  gesture. One replacement push, exact-head protected checks, normal merge,
  and exact-main verification remain.
- Repository visibility: unchanged; public-source exclusions remain in force.
- Version/build impact: none.
- Release impact: source integration only; no store upload or production
  traffic.

## Decisions

- Managed verification UI must preserve the service's four-through-eight digit
  contract and normalize localized decimal input rather than narrowing it.
- A successful verification animation may reflect server-confirmed state but
  must not retain or redraw the verification secret.
- Reduced Motion means no shortened navigation or confirmation animation.

## Open risks and honest limitations

- Simulator evidence cannot establish real SMS delivery, provider behavior,
  autofill presentation, assistive-technology traversal, or physical frame
  pacing.
- Account creation, cloud deployment, band pairing, and data authority are
  unchanged by this presentation round.

## Next round

1. Commit and push the deterministic Recovery scrub harness correction, then
   require the replacement exact head to pass every protected context before
   normal merge and exact-main verification.
2. Run real OTP/autofill and physical-device accessibility in the signed-phone
   validation round.

## Privacy check

- [x] No credentials, phone numbers, OTP values, personal health values,
      signing identities, or absolute personal paths are present.
