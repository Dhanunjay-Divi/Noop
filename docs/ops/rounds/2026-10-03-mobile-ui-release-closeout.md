# Round: 2026-10-03 - Mobile UI release closeout

## Status

- State: `locally verified release candidate; protected integration pending`
- Owner: project team
- Branch: `codex/noop-release-candidate-handoff-20261002`
- Start commit: `f2b2612ed`
- End implementation commit: commit containing this round record
- Record commit or PR: pending protected review

## Objective

Close the remaining iPhone and Android product-review findings before protected
integration:

- keep Today number-first and let a customer select any supported metrics;
- keep metric history and Trends useful without duplicating long explanation on
  the dashboard;
- make the mobile tab shell and movable NOOP N compact, aligned, and reachable;
- preserve Terms -> supported band -> account onboarding with no local-test
  customer bypass;
- verify the exact managed artifacts and record an executable physical-device
  continuation without claiming simulator behavior as hardware proof.

## Scope

### In scope

- Apple and Android Today metric selection, compact cards, sparse trends,
  source labels, cycle eligibility, tab shell, and command-lens presentation.
- Backup/restore parity for every supported Today metric.
- Focused source, UI, localization, legal, claims, privacy, and release gates.
- Final managed Debug artifacts, clean first launch, and synthetic visual
  review.
- Operations and physical-validation handoff evidence.

### Non-goals

- No cloud deployment mutation, public traffic, store upload, signed release,
  firmware action, real OTP, real health data, or payment operation.
- No claim about physical BLE, WHOOP or supplier transport, vibration,
  double-tap possession, permanent ownership, battery, background collection,
  retention, source accuracy, VoiceOver, or TalkBack.

## Starting evidence

- Consolidated candidate base `f2b2612ed` already contained the protected
  command-N repair, mobile tab/OTP motion work, account-first onboarding,
  supplier request fencing, and physical-validation handoff.
- Private synthetic staging was already integrated and verified at protected
  merge `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c`.
- Two independent read-only reviews identified backup parity, cycle
  eligibility/history, same-day Weight arbitration, tab-shell containment, N
  edge geometry, and stale UI-test assertions as the remaining actionable
  issues.
- Physical WHOOP and supplier-band behavior was not available to this software
  round and remained explicitly outside its evidence boundary.

## Delivered

- Today now accepts the complete 19-metric catalog rather than enforcing a
  six-card ceiling. The fresh-install default remains HRV, Resting HR, Blood
  Oxygen, Respiratory, Steps, and Weight.
- Selected metric cards remain compact and aligned. Sparse history traces are
  available for Recovery, Effort, Rest, Weight, and Skin Temperature in
  addition to the existing measured metrics.
- Compact chart badges remain neutral visually; rise, fall, and steady
  direction remains available through accessibility values.
- Apple and Android use the same primary metric colors, status washes, compact
  tab hierarchy, and source-origin groups.
- The metric editor shows a selected count without implying a maximum, retains
  search and explicit ordering/removal, and keeps the complete eligible catalog
  available.
- Menstrual Cycle is shown only when profile eligibility applies, cycle
  tracking is enabled, or a previously saved choice must be preserved. It is a
  measured/imported value, not a NOOP insight, and historical days do not reuse
  the current global setting.
- Android Weight display and sparkline now use the same same-day arbitration;
  Apple Health wins an equal-day tie consistently.
- Apple and Android bottom navigation now reserve enough height for the
  selected icon and label. The Apple selected lens uses its actual visual frame.
- The movable NOOP N keeps its `48x52` target, reaches the safe screen edge,
  preserves bounded drag/snap/persistence, and does not cover the tab shell.
- Apple backup restore now accepts the same 19 supported metric identifiers as
  Android.
- The full-history action remains one tap away and opens the complete metric
  explorer. Existing Trends range, exact-date interaction, and export behavior
  remain unchanged.

## Review findings closed

| Finding | Resolution |
|---|---|
| Apple restore retained only part of the expanded metric catalog | Apple backup boundary and tests now retain all 19 identifiers |
| Bottom bars could not contain the selected icon plus label | Apple measured dock height and Android icon region were corrected |
| Android Weight card and trace could select different same-day sources | Both now resolve through one day-scoped arbitration map |
| Menstrual Cycle bypassed profile eligibility | Both editors and Today grids enforce the profile/tracking gate while preserving saved state |
| Current cycle setting appeared as historical data and as a NOOP insight | Historical values fail closed and origin is measured/imported |
| Apple cycle copy was unlocalized | Existing localized profile summary is reused |
| Apple N body stopped short of the edge | Body pull is derived from target/body geometry and now reaches the safe edge |
| Android command-lens source contract asserted unused geometry | Runtime path consumes the tested geometry and the contract was updated |
| More-than-six UI tests depended on stale copy or lazy-grid materialization | Android uses the compact current label; Apple verifies each card while traversing the lazy grid |

The odd final metric row intentionally keeps the same column width as every
other card. It is not stretched across the grid because equal card dimensions
were an explicit layout requirement.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Metric formula impact: none.
- Permissions, account, and network impact: none.
- Source impact: display-only Weight arbitration is now consistent; cycle
  presentation is gated and source-honest.
- Health claim impact: none. Missing data remains missing and synthetic values
  do not establish sensor accuracy or delivery.

## Observability

- Success and failure evidence uses bounded status/log files, test result
  bundles, screenshot hashes, fixed test names, and repository controls.
- No verification code, account identifier, raw frame, health value, device
  address, credential, or arbitrary supplier payload was added to logs.
- The iOS UI assertions completed 2/2 before Xcode 27 stalled during local
  teardown. The bounded parent was stopped only after the passing XCTest suite
  was recorded.
- Remaining runtime blind spots are signed-device accessibility, physical
  radio behavior, OS/OEM background policy, provider delivery, haptics,
  battery, retention, and sensor truth.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Apple source wall | 90/90 passed | Today/editor, trends, shell, cycle, and accessibility source contracts compile and pass together | Signed-device behavior |
| Apple backup parity | WhoopStore 21/21 passed | All 19 metric identifiers survive Apple backup/restore | Cloud restore or another app version |
| Android source wall | Full and Demo unit walls plus Android-test Kotlin compile passed | Production, demo, and instrumented sources agree on the expanded catalog and shell | OEM rendering or physical sensors |
| Android more-than-six device case | API 35 test passed with `BUILD SUCCESSFUL` in 26 seconds | Eight selected cards render, the editor reports eight, and another catalog item remains available | Physical TalkBack or source delivery |
| Apple more-than-six UI cases | 2/2 XCTest bodies passed in 49.417 seconds; local Xcode teardown was interrupted afterward | Eight pinned cards, complete history, add/remove boundaries, and three-card minimum work in the rendered app | A clean local Xcode process exit |
| Unchanged onboarding suites | iPhone exact tests 2/2 and Android exact classes 2/2 passed before the presentation review corrections; no onboarding source changed afterward | Terms, supported-band setup, account ordering, and configured synthetic completion remain intact | Real band discovery, real account provider, or ownership claim |
| Final iOS managed build | `BUILD SUCCEEDED`; app executable SHA-256 `b6054189869c025840d8dac4b9015e2861731635f96b9e954e6c2886a4f148c5` | Exact managed iPhone Simulator candidate builds | Signing or physical installation |
| Final Android managed build | `BUILD SUCCESSFUL`; Full APK SHA-256 `d90bb7764863d49d29104084adb1788abe8ed0c943f44653f987185b8ba1895c` | Exact managed Full APK packages | Release signing or physical installation |
| Exact clean first launch | iOS `1206x2622` SHA-256 `7a7fe242f3bcddca123f0bde76e5b58b1d09f787af91fb8901c06ccb826df892`; Android `1080x2424` SHA-256 `521d26483d8a838cd59f98c5d052feca4cb9859adebeb3998481cd68b5c1f80e` | Both exact final artifacts open at the matching Terms gate after uninstall/install | Completion of a real account or physical pairing |
| iOS tab-shell matrix | 21/21 deterministic scenarios validated on iPhone 17 Pro, including dark/light, accessibility, keyboard, Today, Trends, Safety, and quick actions | No observed clipping, overlap, blank render, or shell regression in those simulator states | Every locale, device, or physical display |
| iOS key captures | Today top `9c95b4335ebeae8fa450edb34eb117f4943e11735b3e190b7287cd9d6287a7e6`; Today bottom `af5d6474a264fd74db8bfab04bc5d16e829e767a266ac61522d6544aa26c0782`; quick actions `fe2a777f23cb788c3b2702eeab003dd55f9efc9e3cc616f25f70f549f217538a`; Trends `867a7891518973ec4210441de3b92442dcd8c39c9e7ffd63dbc6189ba567f6b7` | Current tab shell, N, cards, history, and Trends render coherently | Physical touch comfort or assistive technology |
| Android visual review | Today SHA-256 `60c39f8c3b66599c8670f024f6e43c73008f28337e5ea03cc618d254af9f7d19`; eight-selected editor SHA-256 `665df32feea608caf3ea12379a72b15c12dbfecccdff1c94aaf76226ae765faa` | Current Today, bottom shell, N, aligned cards, full editor, and over-six state render without observed overlap | Physical display, TalkBack, or sensor data |
| Repository controls | Private-data guard, 1,325-file health-claims scan, nine release controls, legal inventory of 230 runtime components plus three container inputs, terminology ratchet, string-catalog parse, and diff hygiene passed | Final source/evidence remains coherent and policy-bounded | Hosted exact-head status or release approval |

## Managed configuration and cloud state

- Ignored managed mobile configuration paths:
  `Config/ManagedCloudSecrets.xcconfig` and
  `android/managed-cloud.properties`.
- Both local files were mode `0600`, remained ignored by Git, and were not
  printed or copied into repository evidence.
- Private synthetic staging was not changed:
  - protected source merge
    `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c`;
  - image digest
    `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`.
- No public invocation, real OTP, real health data, or cloud resource mutation
  occurred in this round.

## Physical device and deployment

- Install/update action: exact unsigned managed builds were installed only on
  an iPhone 17 Pro Simulator and Android API 35 emulator.
- Generalized device and OS class: iOS 26.5 at `1206x2622` and Android API 35
  at `1080x2424`.
- Data-preservation result: fictional demo/test state only; no user phone or
  health data was read, replaced, or cleared.
- BLE/background/haptic/battery scenarios exercised: none.
- Cloud deployment action: none.
- Unrun hardware gates: signed candidates, WHOOP comparison, supplier exact
  model, vibration/double tap, permanent account claim, source switching,
  battery, background, notification delivery, retention, accessibility
  services, and metric accuracy.

## Git and release state

- Changed paths: Apple and Android Today/editor/shell source, focused tests,
  localized compact editor copy, backup parity, terminology inventory, and
  operations records.
- Branch and remote state at record creation: local candidate verified; one
  authorized push, protected exact-head checks, normal merge, and exact-main
  verification remain.
- Repository visibility: unchanged. Public-source exclusions for supplier
  binaries, firmware, credentials, signing material, private references, and
  personal or health data remain in force.
- Version/build impact: none.
- Distribution impact: none. These are unsigned simulator/debug candidates.

## Decisions

- Today has no six-card maximum. The complete eligible catalog may be selected,
  while a compact six-card default keeps first use scannable.
- Today remains metric-first. Long education and complete history stay behind
  metric detail and the history action.
- Cycle presentation is profile/tracking gated and never fabricated across
  historical dates.
- Equal metric card dimensions take precedence over stretching an odd final
  item.

## Open risks and honest limitations

- Protected exact-head checks and merge are still pending at record creation.
- Physical WHOOP comparison has not run on a signed candidate.
- Supplier physical validation remains blocked until the exact approved
  artifact tuple and trust manifest are restored and verified.
- Physical BLE, vibration, double tap, ownership, source switching, battery,
  background, notification delivery, accessibility, retention, and metric
  accuracy remain unvalidated.
- Real OTP, public traffic, payments, provider delivery, and external launch
  approval remain open.

## Next round

1. Push this exact branch once, wait for every required protected context, merge
   normally only when green, and verify exact protected `main`.
2. Start the signed physical round from clean protected `main`.
3. Follow `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`, validate
   WHOOP first, and do not enable the quarantined supplier source without the
   approved exact-model artifacts.
4. Record privacy-safe iPhone and Android evidence for connection, battery,
   live data, catch-up, background, notifications, diagnostics,
   accessibility, and source switching.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, physical
      device identifiers, signing identities, or absolute personal paths are
      present.
