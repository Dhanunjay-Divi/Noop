# NOOP Physical Band Test Review

Date: 2026-10-01
Reviewer: Codex recovery agent
Status: scoped source fix locally verified; physical collection not yet run

## Candidate

- Repository: Dhanunjay-Divi/Noop
- Candidate branch: `codex/today-metric-catalog-fitness-age-20261001`
- Exact baseline SHA: `232f746e045d2755947579c3408efc5c3b84ff69`
- Exact implementation SHA: `2e676e75dda24c203c12d755fe0530b92ca56f3b` (source/test fix; review documentation follows)
- Published review branch: `codex/physical-band-review-20261001`
- Draft review PR: https://github.com/Dhanunjay-Divi/Noop/pull/28 (base is the pinned Today-catalog branch; no merge performed)
- iOS version/build: 9.2.1 / 231; unsigned graph builds; signed install unavailable.
- Android Full Debug version/build: 9.2.1-debug / 304; APK assembled, not installed.
- Android APK SHA-256: `77c4513713f95166e4502ff273f1d9b780ccccec4f4091baf15ca04bd5832fb6`.
- Build/signing method: Xcode 26.6, Debug iPhoneOS, existing local development
  identity, bounded runner. Same bundle prefix retained for an in-place update.
- Shared SDK: exact ten-file source artifact verified; supplier binaries absent
  by manifest policy. Supplier-enabled build remains unavailable locally.

## Test Environment

| Platform | Phone and OS | Band | Firmware | Account state |
|---|---|---|---|---|
| iOS | iPhone 13 Pro Max / 27.0.1 | Assignment pending | Unknown | NOOP not found in installed-app inventory; provider configuration absent locally |
| iOS | iPhone 17 Pro Max / 27.0 | Assignment pending | Unknown | Installed-app audit pending; provider configuration absent locally |
| Android | No phone provided | Not assigned | Unknown | Not run |

Both iPhones reported Developer Mode enabled and wired connected in live detail
queries. Both bands will use the NOOP app. Use one collector per band; prevent
competing apps from connecting to that band. Existing app data must survive.
No uninstallation or reset is authorized by the attached clean-install procedure.

## Result Matrix

| Platform | Source | First run | Pair | Live data | History | Background | Reconnect | Notifications | Result |
|---|---|---|---|---|---|---|---|---|---|
| iOS | WHOOP | Not run | Not run | Not run | Not run | Not run | Not run | Not run | Awaiting signed configured candidate |
| iOS | Supplier NOOP | Not run | Not run | Not run | Not run | Not run | Not run | Not run | Approved external SDK/configuration missing |
| Android | WHOOP | Not run | Not run | Not run | Not run | Not run | Not run | Not run | Phone not provided |
| Android | Supplier NOOP | Not run | Not run | Not run | Not run | Not run | Not run | Not run | Phone not provided |

## Observations

- SDK artifact: expected the exact pinned shared SDK. Actual ten files match
  manifest at the required revision. Reproduced once with the checked-in verifier.
  This verifies shared source provenance; it does not enable supplier BLE.
- Supplier preflight: expected a complete approved external SDK. Actual verifier
  exits 1 with incomplete SDK root. Known local Documents, Downloads, and managed
  worktree searches found no supplier binary or generated supplier config.
  Reproduced once; scope is this Mac, not all machines or packages.
- Account preflight: expected environment-specific account and ownership setup.
  Actual ignored managed config absent in checked local checkouts. Current source
  requires this boundary; first-run completion remains untested.
- Developer Mode: previously disabled on the 13 Pro Max. Latest live queries
  report enabled on both phones with connected wired transport. This establishes
  device readiness for further queries; no installed candidate or BLE proof.

## Changes Made

- Product code: supplier optional step/sleep command serialization at `2e676e75dda24c203c12d755fe0530b92ca56f3b` on the local
  review branch. No merge, firmware, installation, or phone data changes.
- Before: one step and one sleep command could be outstanding simultaneously.
  After: a due sleep read waits for step completion/failure and prevents the next
  step poll until its own completion/failure. Disconnect/stop clears pending work.
  Unrequested result events do not persist values. No calculation changes.
- Regression coverage added: optional failure releases the lane, pending sleep
  receives priority, polling resumes after sleep, stop cancels polling, and
  disconnect discards queued/unsolicited metric results.
- Configuration: copied only the existing bundle prefix and development team
  into ignored `Config/BundleIdSecrets.xcconfig` in the isolated review checkout.
  Values remain private. No entitlement or trust-gate edits.
- Operations: local round record, ACTIVE, and round index; generated ignored Xcode
  project. Project generation passes through the bounded runner.
- Tests: Android Full Debug APK assembly passes. Neutral SDK ten-file verification and Swift parsing pass. Focused Apple
  supplier regressions pass 70/70 and SDK boundary checks pass 7/7. Signed build retry failed
  during the grpc binary dependency download before compile/sign/install. A subsequent resolved-graph signing preflight exits
  65 on required profile capabilities. Unsigned iOS app, Watch, complication and widget graph compiles successfully with zero compiler errors. Supplier transport remains disabled because approved artifacts/compatibility are absent. The
  retry overlapped the local fix and is not evidence for an immutable signed SHA.
- Integration recommendation: focused app regressions and default-off iOS build
  pass. Review the command-lane fix and verify affected physical cases. New SDK
  channels remain separate implementation work; no all-metric parity claimed.

## SDK adaptation contract

Keep the common NOOP layer stable above vendor-specific native clients. The
current SDK import remains confined to the private client in
`Strand/BLE/VeepooBandAdapter.swift`. That client maps vendor APIs into the
existing adapter events and source-qualified NOOP storage types; the shared
`NoopBandSDK` and analytics contracts remain the common layer. This fix changes
source scheduling, not the vendor client or any SDK API.

An SDK update changes its native adapter/mapping, pinned artifact verification,
compatibility row and fixtures as needed. It must preserve normalized units,
time/timestamp quality, missing states, source, cancellation, generation fencing,
and capability truth. Additional SDK families use their own adapters behind
these contracts. An arbitrary SDK is not automatically drop-in compatible.
Vendor structs, frames, proprietary scores and unsupported medical claims must
not leak into shared metrics or UI. Prove each newly exposed channel with approved
hardware/firmware and run affected lifecycle/provenance tests before enabling it.

## Derived-metric parity audit

The owner requires both bands to expose the complete applicable derived-metric
set in NOOP. This is a source audit, not a physical validation result. Identical
sensor hardware has not been established, and matching hardware would not prove
that both transports expose identical inputs. The Apple supplier event and persistence
seams currently carry HR, steps, and sleep summaries only. There is no current
supplier event/ingest path for R-R, respiration, oxygen, skin temperature, raw
motion, or REM epochs. The shared SDK package does not fill those missing channels.

| Metric family | Required evidence | Current Apple supplier path / validation gap |
|---|---|---|
| Average/max HR; HR zones; cardio Effort; observed calorie estimate | Sufficient timestamped HR, profile, coverage, gap policy | Live HR stored with receipt time; no historical HR channel in this adapter; cadence and coverage not physically tested |
| Resting HR; overnight recovery-index slope | Sustained overnight HR in a valid sleep window | HR and reported sleep window can reach analysis; locked/background/overnight coverage unproven |
| HRV | Trustworthy beat-to-beat intervals and sufficient clean coverage | No supplier R-R ingest channel; bpm is insufficient to reconstruct HRV |
| Recovery | HRV, resting HR, usable personal HRV baseline; optional rest/respiration/temperature terms | Blocked for band-only supplier data by missing R-R/HRV path; no score may be fabricated |
| Respiratory rate | Supported respiration stream or qualified R-R-derived estimate | Neither supplier stream currently ingested |
| Blood oxygen | Validated oxygen channel or explicit supported import | No supplier channel; raw optical counts alone are not oxygen saturation |
| Skin-temperature trend | Approved temperature stream, calibration and baseline | No supplier temperature ingest channel |
| Sleep total, deep/light duration and efficiency | Device sleep summary/staging with source and valid epochs | Supplier summary persisted; no REM field or full stage timeline; physical report semantics untested |
| Rest score; restorative minutes/share; REM; in-bed time | Qualified sleep evidence with necessary stages/timing and coverage | Summary is partial; full staging/REM equivalence not established; sparse-input gates remain |
| Sleep consistency, need, debt, hours-vs-needed | Supported sleep windows across sufficient history, profile and activity context | Potential shared calculation with valid history; collection and coverage not yet measured |
| Stress timeline; sustained stress prompts | HR/R-R, baseline, signal quality and corroboration | No supplier R-R; HR-only evidence cannot unlock multi-signal stress prompts |
| Fitness Age; estimated VO2 max | Supported confirmed profile, valid resting HR/activity history and smoothing; waist for VO2 estimate | Shared engine present; history/readiness gates still apply; not an immediate first-run output |
| Vitality; Wellness Age | At least three valid factors across three physiological domains and profile | Shared engine present; identical contributing factors are not guaranteed by current supplier ingress |
| Steps; movement contribution to Effort | Source-qualified native/measured steps; no wrist-motion substitute | Supplier native daily total stored; manual-count comparison pending; WHOOP primary steps require an eligible measured import |
| Strength time and activity intensity | Supported workout/activity evidence | Supplier raw-motion/workout channel absent in current adapter; requires separately supported inputs |
| Weight, body composition, BMI, absolute body temperature, imported energy/VO2 | Explicit profile or supported external measurements/imports | Not derived from the band sensor list; must keep the true input source |
| Hydration, nutrition, mood | User-entered or explicitly imported records | Independent of band choice; absent logs remain not logged |

Physical checks must compare actual availability, provenance, completeness,
freshness, calibration state and formula revision for every family—not only
whether a card is visible. Use matched profiles, units and timezones, distinct
band sources, synchronized activity windows, ordinary resting/walking intervals,
and overnight coverage. Imported phone/Health data must be labeled so it cannot
masquerade as a band sensor path. Differences in cold-start history must be
recorded rather than erased by resetting user data.

Source evidence: `Strand/BLE/VeepooBandAdapterCore.swift`,
`Strand/App/AppModel.swift` supplier persistence,
`Strand/Data/IntelligenceEngine.swift` source-qualified day inputs,
`Strand/Data/KeyMetricPrefs.swift`, `Strand/Data/MetricCatalog.swift`, and shared
`StrandAnalytics` engines. The Today editor contains 14 choices; the full catalog
contains 64 producer-specific entries with 51 unique metric keys, including
external imports and user records. The 14-card editor is not the full calculation
inventory.

## Remaining Findings

| Severity | Finding | Evidence | Recommendation |
|---|---|---|---|
| Test blocker | No approved supplier compatibility rows | Runtime manifest contains zero approvedBands entries | Primary agent must approve exact hardware/firmware with evidence before activation |
| Test blocker | Approved supplier dependency bundle unavailable locally | Supplier preflight exits 1 | Obtain secure artifact location and pass exact verifier; keep supplier disabled |
| Test blocker | Required account/ownership environment unconfigured | Ignored-config inventory and target defaults | Obtain approved local configuration; preserve account gates |
| Test blocker | Derived supplier inputs incomplete | Source adapter lacks R-R, oxygen, temperature, raw-motion and REM channels | Investigate approved SDK/firmware capabilities; implement and verify exact channels before claiming parity |
| Test blocker | Local signing setup lacks required capabilities | Signed iOS build exits 65; App Groups, HealthKit, push and App Attest profile mismatches | Configure a capable approved development team/profile for all embedded targets; preserve entitlements |
| Unverified | Physical band behavior and comparative accuracy | No collection cases run | Run WHOOP baseline, supplier comparison, lifecycle and overnight checks |

## Unverified Or Blocked

- Missing supplier inputs: runtime compatibility approval (zero rows currently),
  approved iOS framework/dependency tree, exact band model
  and firmware, compatibility approval, and local supplier configuration.
- Missing service inputs: approved account and ownership configuration.
- Signing gate: approved profiles supporting App Groups, HealthKit, push and
  App Attest are required for the app and every embedded target.
- No installed exact candidate, physical pairing, HR/battery/steps/sleep/history,
  source switching, background, notifications, haptics, retention, or sensor
  accuracy result is claimed.
- Android physical tests not run: owner will connect an Android phone next.
  Detect its exact class/OS and prepare the Full build; two iPhones do not prove Android.
- No screenshots or raw health data captured. Build logs stay private outside Git.
- Silent SDK callbacks/timeouts remain an open lifecycle concern. This change
  serializes requests; it does not add guessed timeout/retry semantics.
- Android supplier bridge currently exposes HR/battery only and has no matching
  step/sleep read commands, so this Apple-native scheduling fix has no Android
  command path to mirror. Android metric/sensor parity remains unverified.

## Evidence Artifacts

- Android APK: `android/app/build/outputs/apk/full/debug/app-full-debug.apk`
  in the review worktree; source at implementation SHA above, supplier disabled.

- `private round-owned evidence directory/supplier-preflight.log`
- `private round-owned evidence directory/project-generation.log`
- `private round-owned evidence directory/project-generation.status`
- `private round-owned evidence directory/signed-ios-build.log`
- `private round-owned evidence directory/signed-ios-build.status`

Private logs can contain tool-generated signing/path metadata; do not publish them
without sanitization. The shared operations record contains only bounded findings.

## Review and integration route

Review the dedicated branch against the exact baseline above, not the whole
unmerged Today-catalog delta against older main. The primary Today-catalog PR is
still open at that baseline. Apply this scoped implementation after reviewing
its source diff and operation log, using normal branch policy and required exact
checks. The review branch is published as draft PR #28. No merge, force-push, release or
firmware action is performed by this
review round. The requester explicitly authorized the fix and review branch.

## Reviewer Conclusion

- Recommendation: scoped source fix passes local focused regression, default-off
  iOS compilation and Android Full APK assembly; primary agent should review and run affected physical cases.
  No physical pass or full derived-metric parity claimed.
- Next action: primary-agent source review; complete iOS signing and obtain
  approved supplier/account/compatibility inputs, then validate both bands.
- Focused test command: `xcodebuild -project Strand.xcodeproj -scheme Strand
  -destination 'platform=macOS' -only-testing:StrandTests/VeepooBandAdapterCoreTests
  CODE_SIGNING_ALLOWED=NO test`, executed through the bounded runner with private
  log/status paths and a round-owned DerivedData directory. Result: 70/70 pass.
- SDK boundary command: `python3 -m unittest discover -s Tools/tests
  -p test_supplier_sdk_wrapper_boundary.py`, through the bounded runner. Result:
  7/7 pass.
- Physical retest priority: long step callback while sleep becomes due; optional
  step failure before sleep; sleep completion/failure before next step poll;
  disconnect/stop with a queued sleep request; confirm HR stays available and
  persisted values retain their source. Then run the complete two-band matrix.
- Release blockers: physical behavior remains unverified, independent of source
  and simulator results. Controlled two-band agreement alone cannot prove accuracy.
