# Round: 2026-10-02 - Mobile tab and OTP motion

## Status

- State: `verified locally; protected integration pending`
- Owner: project team
- Branch: `codex/mobile-liquid-tab-otp-motion-20261002`
- Start commit: `dbd23c25e4f681c4a087642b41441270fa15c3a0`
- End implementation commit: `1268a2cb82188fdaed53a2cc148587dc9d186b9e`
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
- Android success dismissal runs in a sheet-owned job that is canceled on
  phase reset or disposal, preventing a stale pointer-blocking overlay.
- Removed untranslated numeric accessibility status text; Apple count and hint
  text use localized resources, and Android retains the localized field label
  and native editable-field semantics.

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
| Independent review | Initial review reported unresolved merge state, six-only validation, retained OTP digits, cancellable-overlay risk, partial Reduced Motion, untranslated status text, and ad-hoc dimensions; the implementation was corrected before commit and submitted for re-review | The known privacy, contract, lifecycle, accessibility, and maintainability risks were explicitly handled | A formal external security audit |
| Android production compile | Bounded `compileFullDebugKotlin` passed | Current Full production Kotlin compiles with the corrected UI | Signed phone behavior |
| Android focused contract | `PrimaryNavigationContractTest` passed 10/10 after one stale token assertion was updated | Five-tab semantics, moving lens, four-to-eight digit normalization, reduced motion, autofill, and non-retained success state are enforced | Instrumented TalkBack behavior |
| Android APK | Bounded `assembleFullDebug` passed; SHA-256 `a4fe157427c615c67909a97516992353b8446ae1e19f542dcae8113fc3f17e02` | The exact Full debug candidate packages | Store signing or physical install |
| Android visual review | API 35 `1080x2424` Today capture SHA-256 `312c7e02ae629dc4b3b62e2beb406b5892f413fca4a2b6af4e03b1570c993585` | Labels fit, the selected lens is centered, content is not covered incoherently, and the N remains bounded | OEM rendering, touch comfort, or physical TalkBack |
| Apple focused contracts | 67/67 passed in `ManagedCloudRetryContractTests` and `SafetyPagingAndShellContractTests` | Verification normalization/privacy and tab semantics remain green with existing Safety shell contracts | iOS-only compilation by itself |
| Complete iPhone graph | Bounded `NOOPiOS` Simulator build passed, including Watch and widgets | The iOS-conditional verification view and shared design package compile in the mobile graph | Signing, physical Watch, BLE, or background behavior |
| iPhone visual review | iPhone 17 Pro Simulator `1206x2622` Today capture SHA-256 `c163c70f0982568d0c852a62070424226440507b1f7e873c1d532ffddc392823` | The matched selected lens, labels, cards, and movable N render without observed clipping or incoherent overlap | Every locale, Dynamic Type size, or physical display |
| All-platform i18n | Full audit passed with zero translated-key gaps in supported Apple catalogs | New localized Apple accessibility text and existing Android resources remain within coverage policy | Human linguistic review |
| Diff hygiene | `git diff --check` passed before record creation | No whitespace-error regression | Runtime correctness outside listed gates |

## Physical device and deployment

- Install/update action: unsigned Full debug APK installed on an API 35
  emulator; unsigned iOS app installed on an iPhone 17 Pro Simulator.
- Data-preservation result: synthetic demo state only; no store or migration
  changed.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun gates: signed phones, real SMS/autofill, App Attest, Play Integrity,
  physical band sources, BLE, background, battery, haptics, and sensor accuracy.

## Git and release state

- Changed paths: shared design tokens, iPhone/Android shell navigation,
  iPhone/Android managed-cloud verification views, focused contracts, and this
  operations record.
- Implementation commit: `1268a2cb82188fdaed53a2cc148587dc9d186b9e`.
- Branch and remote state: local only; protected pull request and exact-main
  verification pending.
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

1. Merge current protected `main`, run repository gates, push a normal pull
   request, and complete exact-main verification.
2. Run real OTP/autofill and physical-device accessibility in the signed-phone
   validation round.

## Privacy check

- [x] No credentials, phone numbers, OTP values, personal health values,
      signing identities, or absolute personal paths are present.
