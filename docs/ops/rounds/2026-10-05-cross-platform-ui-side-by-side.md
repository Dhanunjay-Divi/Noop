# Round: 2026-10-05 - Cross-platform UI side-by-side review

## Status

- State: `completed locally; PR #36 integration pending; physical validation pending`
- Owner: project team
- Branch: `codex/cross-platform-ui-review-20261005`
- Start commit:
  `366ed412f450a997daf378210bb04b4e2a8d207d`
- End implementation commit:
  `366ed412f450a997daf378210bb04b4e2a8d207d` (no product-source change)
- Record commit or PR: PR `#36`

## Objective

Run the current protected-main iOS and Android apps side by side from equivalent
clean and configured states, inspect the rendered product directly, and close
confirmed customer-facing parity or visual gaps. Verify the resulting branch
and protected-main state without converting simulator evidence into a physical
band claim.

## Scope

### In scope

- Fresh-install Terms, onboarding, band discovery, account ordering, and
  customer wording on both phone platforms.
- Configured Today, metric editor, complete metric history, Trends, expanded
  and compact navigation, movable NOOP `N`, quick actions, and representative
  detail surfaces.
- Normal and dark appearance, compact-screen pressure, large text where the
  existing harness supports it, accessibility identifiers, clipping,
  overlap, blank space, and cross-platform semantic parity.
- Focused fixes, tests, builds, simulator/emulator installs, visual captures,
  repository controls, and durable handoff updates when evidence requires a
  change.

### Non-goals

- BLE, background execution, battery, haptics, notification delivery, sensor
  accuracy, firmware, or retention claims from a simulator or emulator.
- Real OTP, production customer traffic, payment, public launch, or real
  health data.
- Reworking unrelated analytics, storage, or concurrent dirty worktrees.

## Starting evidence

- Protected `main` is
  `366ed412f450a997daf378210bb04b4e2a8d207d`; all ten exact-main hosted
  workflows are successful.
- The original checkout contains unrelated dirty September step-source work,
  so this round uses an isolated clean worktree from protected `main`.
- A clean iOS simulator runtime and an Android API 35 virtual device are
  available locally.
- Existing Apple UI tests and visual harnesses cover fresh install, configured
  onboarding, tab navigation, metric history, metric editing, quick actions,
  and representative accessibility states. Android production-shell tests
  cover equivalent onboarding and app-shell behavior.
- Prior screenshots are historical evidence only and do not prove the current
  exact-main render.
- Unknowns that must remain unknown until measured: whether any current render
  still clips, overlaps, exposes stale wording, leaves unexplained blank space,
  or behaves differently between equivalent Apple and Android checkpoints.

## Delivered

- Built the exact protected-main iPhone Simulator app, Android Demo APK,
  Android Full APK, and Full instrumentation APK through bounded runners.
- Installed and rendered equivalent synthetic Today states on iPhone 17 Pro
  Simulator and Android API 35, then reviewed Today, Trends, Workouts, Sleep,
  More, compact navigation, quick actions, metric selection/history, scanner,
  fresh install, configured onboarding, ordinary text, and accessibility text.
- Passed eight focused Android API 35 UI cases: five-tab navigation, large
  text, quick actions, full metric selection beyond six pins, unified scanner,
  post-Terms band-first flow, fresh-install ordering, and configured account
  completion. An initial command contained two invalid class selectors; those
  selectors were corrected and the two real onboarding cases passed.
- Passed all 12 selected iPhone UI cases with zero failures. Xcode printed the
  complete passing suite before hanging in post-test diagnostics; only that
  stale finalization process was interrupted.
- Completed and validated the repository's 21-scenario iPhone 17 Pro visual
  matrix, including dark contrast, accessibility text, keyboard restoration,
  compact navigation, Safety, and quick actions.
- Repeated Android cold starts without competing build load: Workouts
  `3.664 s`, Sleep `1.644 s`, and Today `1.791 s`. The earlier splash-only
  captures were discarded because forced restarts occurred under concurrent
  iPhone compilation.
- Generated and opened one side-by-side iPhone/Android Today review composite
  outside Git. No confirmed current-main visual or semantic gap required a
  product-code change.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: disposable simulator/emulator state only;
  no user phone or health data will be erased.
- Source/provenance or formula impact: none planned.
- Permissions/network disclosure impact: synthetic local review only; no
  public traffic or real identity is permitted.
- Health/medical claim impact and limitations: UI review only; no
  physiological or medical validation is claimed.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  UI-test identifiers, bounded launch logs, screenshots, test result bundles,
  and build status files.
- Why existing evidence is sufficient, or why new evidence is required:
  existing harnesses cover the reviewed routes; add product diagnostics only
  if a confirmed failure cannot be distinguished with current bounded state.
- Existing evidence reused: protected checks, Apple UI tests, Android
  production-shell tests, visual QA launch states, and customer-brand gates.
- New bounded events or operation spans: none planned.
- Redaction, retention, and high-frequency controls: captures use synthetic
  fixtures and remain outside Git; logs must not contain health values,
  credentials, device identifiers, or payloads.
- Cross-platform/backend correlation: compare equivalent local launch
  scenarios; no backend correlation is required for visual parity.
- Remaining blind spots: VoiceOver/TalkBack traversal, physical BLE,
  background work, haptics, battery, notifications, and sensor behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Protected-main hosted workflows | 10/10 successful at the start SHA | Mainline policy and build gates are clean before local review | Current side-by-side visual quality or hardware behavior |
| Exact-main Apple build | Passed; executable SHA-256 `c924f2f4c21952a5f6f94f09ab82640be7cab28387406bc3bd70a0b2d7412b46` | Current iPhone Simulator product compiles and installs | Store signing or physical-phone behavior |
| Exact-main Android build | Demo, Full, and Full-test APKs passed; SHA-256 `de3a5d60c5c3c1439fd684e9f52a646fd47d05020f9d33d88c68de4caa7bc754`, `5531b0da2a9b827983ccfed737307b18858271517e028929828058767a3f08c0`, and `33a0ff86a616178cc67a6779bbb3c433803c1cdbc3fb2beba36ddc187b7df000` | Both Android product variants and focused instrumentation package assemble | Play signing or physical-phone behavior |
| Android focused UI wall | 8/8 passed on API 35 after correcting two command selectors | App shell, accessibility-sized navigation, metric catalog, unified scan, and account-order contracts execute in the product shell | TalkBack traversal, real BLE, or background behavior |
| iPhone focused UI wall | 12/12 passed; post-result diagnostics interrupted after the complete passing summary | First run, account flow, unified scan, navigation, quick actions, metrics, scroll-tail, and accessibility contracts execute | VoiceOver traversal, real BLE, or background behavior |
| iPhone visual matrix | 21/21 scenarios captured and validated | Required screenshots exist, are nonblank, use expected fixtures, and show no crash signature | A screenshot alone cannot prove focus order or touch quality |
| Direct paired review | Settled Today pair plus Android Trends, Workouts, Sleep, and More manually inspected | No observed clipping, unexplained blank route, stale customer model row, or selected-tab mismatch in reviewed states | Exhaustive coverage of every destination and device size |
| Android cold starts | `3.664 s`, `1.644 s`, `1.791 s` | Splash-only captures under build contention were not a persistent launch failure | Physical-device startup or release-build performance |

## Physical device and deployment

- Install/update action: disposable simulator/emulator installs only; no signed
  phone, distribution, backend deployment, or cloud mutation.
- Generalized device and OS class: disposable iOS Simulator and Android API 35
  emulator only; the existing user phone and health data were not touched.
- Data-preservation result: synthetic app state only.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all signed-phone and physical-band scenarios.

## Git and release state

- Changed paths: operations records, generated terminology inventory, and the
  reviewed required-CI source pin; product source is unchanged.
- Commits: review closeout plus generated-evidence trust-pin correction.
- Branch and remote state: isolated review branch from exact protected
  `origin/main`, proposed as PR `#36`; the older September Android step-source
  checkout remains dirty with unrelated user work and was not modified.
- Repository visibility verified: public by current owner decision.
- Version/build impact: none.
- Release or distribution impact: none.

## Decisions

- Durable decision added or changed: keep the current expanded-navigation
  overlay contract. Ordinary text may extend behind it while sustained scroll
  compacts the control; accessibility-sized text reserves the expanded
  navigation footprint. Both platform contracts passed, so this review does
  not add padding or reintroduce a fixed footer.
- Decision-log entry: none.

## Open risks and honest limitations

- A matching screenshot does not prove focus order, hardware transport, or
  background behavior.
- Simulator/emulator fixtures can hide production configuration failures; the
  review must keep configured and unconfigured states distinct.
- VoiceOver/TalkBack traversal, signed-device performance, notification
  delivery, physical movement/drag feel, BLE, haptics, battery, firmware,
  sensor accuracy, and real account/provider behavior remain unproven here.

## Next round

1. Start from clean protected `main` and execute
   `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`.
2. Install one exact signed candidate on supported iPhone and Android phones.
3. Validate first-run, comparison transport, quarantined supplier adapter,
   background, notification, accessibility, and source-switching cases with
   privacy-safe physical evidence.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
