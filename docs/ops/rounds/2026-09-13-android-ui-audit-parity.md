# Round: 2026-09-13 - Android UI audit parity

## Status

- State: `completed locally`
- Owner: project team
- Branch: `codex/android-ui-audit-parity-20260913`
- Start commit: `f7baaddc0818b238b86962e60c5664eb6b746d34`
- End implementation commit: commit containing this record
- Record commit or PR: local commit only; no push or PR authorized

## Objective

Verify and complete Android parity for P1-1, P1-2, P1-3 and every applicable
P2-1 through P2-16 in the private UI audit. Exclude P1-4 Trends loading and
performance, leave Apple source untouched, add focused Android tests, and
commit the isolated result without pushing or running full suites.

## Scope

### In scope

- Android Recovery, Daily Signal, navigation accessibility, missing-state,
  terminology, device, Stress, Recovery-breakdown, Journal, NOOP+, Health
  Monitor, and Sleep presentation contracts.
- Focused JVM tests for the audited presentation behavior.
- A finding-by-finding applicability review against the pinned source.

### Non-goals

- P1-4 Trends loading or performance.
- Apple source changes.
- Formula, schema, persistence, BLE, backend, deployment, or release changes.
- Full Android suites, hosted CI, physical-device validation, or remote push.

## Starting evidence

- Audit report: private local UI-audit report supplied outside Git.
- Start tree: clean isolated worktree at the requested commit.
- Existing source already contains most cross-platform audit remediations.
- Fresh inspection found a residual Android missing-value inconsistency in
  Sleep formatting: private/raw hyphens remained outside
  `NoopDisplayFormat.MISSING`.
- Unknowns that must remain unknown until measured: physical TalkBack order,
  OEM font rendering, and signed-device layout behavior.

## Delivered

- Replaced the remaining Sleep-specific hyphen and private em-dash fallbacks
  with `NoopDisplayFormat.MISSING` in the Sleep model, trend, percentage, and
  typical-comparison paths.
- Extracted the Daily Signal status-resource mapping into a testable
  presentation helper while retaining the localized Steady, Watch, Check in,
  and Building vocabulary.
- Expanded the Android UI-audit contract to pin centralized Recovery meaning
  and color, Daily Signal separation, scalable/ellipsized navigation with
  TalkBack selection semantics, shared missing states, current-day workout
  coach copy, device presentation, visible Age context, Stress wording,
  Recovery confidence and signed-point formatting, Journal padding, NOOP+
  evidence rows, Health connection copy, and Sleep naming/information tone.
- Added focused pure-format tests for Sleep missing values and signed
  comparisons, plus a Daily Signal resource-mapping test.

## Finding disposition

| Finding | Android result |
|---|---|
| P1-1 | Applicable and verified: Today, Calendar, and Weekly Digest derive Recovery labels/colors from the shared Recovery-band presentation. |
| P1-2 | Applicable and verified: Daily Signal uses its own localized Steady/Watch/Check in/Building vocabulary. |
| P1-3 | Applicable and verified: navigation adapts to font scale, ellipsizes rather than clips, and exposes selected/content-description semantics to TalkBack. |
| P1-4 | Excluded by request; no Trends loading or performance work was performed. |
| P2-1 through P2-3 | Applicable and verified in Weekly Digest: sub-one-percent deltas are not malformed, imported Sleep Score absence is disclosed, and Recovery chip tone follows Recovery meaning. |
| P2-4 | Applicable; completed in this round by removing the remaining Sleep raw missing-value tokens and pinning the shared em-dash contract. |
| P2-5 through P2-7 | Applicable and verified: workout-coach copy is gated on current Recovery, duplicate device model text is hidden, and the estimate footnote is visible. |
| P2-8 | The reported unlabeled Date-of-birth age defect is not present on Android. Android already renders a visible Age row and an `Age, N years` TalkBack description; this parity contract is now pinned. |
| P2-9 through P2-16 | Applicable and verified: customer-facing Recovery/band vocabulary, Light load Stress wording, Recovery confidence/temperature/sign formatting, Journal margins, NOOP+ evidence rows, connection-aware Health copy, and unified neutral Sleep Score presentation remain mounted. |

## Data, privacy, and medical truth

- Schema or migration impact: none expected.
- Existing-data retention impact: none expected.
- Source/provenance or formula impact: presentation only.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: no stronger health claim is
  introduced; missing input remains missing.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: not applicable
  to these synchronous presentation-only changes; focused deterministic tests
  cover the changed formatting and source contracts.
- Why existing evidence is sufficient, or why new evidence is required:
  no long-running, persistence, transport, network, or operational boundary is
  changed.
- Existing evidence reused: localized resources, pure presentation helpers,
  and Android JVM source-contract tests.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: no logging added.
- Cross-platform/backend correlation: not applicable; Apple and backend remain
  unchanged.
- Remaining blind spots: physical TalkBack and OEM rendering.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused Android JVM tests: 11 selected classes, 60 tests | Pass, zero failures/errors/skips | Audited pure formatting and source contracts compile and pass on the pinned Android source | Physical rendering, OEM font behavior, or TalkBack traversal |
| `git diff --check` | Pass | Edited text has no whitespace errors | Runtime behavior |
| Apple-path diff check | Pass, no paths | This round did not edit Apple source | Whether an independent Apple branch remains behaviorally aligned |

### Focused test command

```text
ANDROID_HOME="$ANDROID_SDK_ROOT" \
./gradlew --no-daemon \
  -Dorg.gradle.jvmargs='-Xmx8192m -XX:MaxMetaspaceSize=1536m -Dfile.encoding=UTF-8' \
  -Pkotlin.compiler.execution.strategy=in-process \
  :app:testFullDebugUnitTest \
  --tests com.noop.ui.UiAuditPresentationContractTest \
  --tests com.noop.ui.RecoveryBandPresentationTest \
  --tests com.noop.ui.DailySignalPresentationTest \
  --tests com.noop.ui.PrimaryNavigationContractTest \
  --tests com.noop.ui.WeeklyDigestCardFormattingTest \
  --tests com.noop.ui.DeviceDisplayNameTest \
  --tests com.noop.ui.RecoveryDriversUiTest \
  --tests com.noop.ui.StressModelTest \
  --tests com.noop.ui.CalendarMonthPresentationTest \
  --tests com.noop.ui.AppWideLocalizationContractTest \
  --tests com.noop.ui.SleepFormattingTest
```

Result: `BUILD SUCCESSFUL in 2m 56s`; 60 tests, zero failures, zero errors,
zero skips.

Two failed verification attempts remain recorded rather than hidden. The first
stopped before compilation because the isolated worktree had no SDK location.
The second reached Kotlin compilation but the shared 4 GB compiler daemon
exhausted heap while transforming unrelated `HealthScreen.kt`. Supplying the
known SDK path and using an isolated 8 GB in-process compiler produced the
passing result above without stopping shared daemons.

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no data path is changed
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical TalkBack, narrow-device rendering, and OEM
  font-scale behavior

## Git and release state

- Changed paths: four Android production files, three Android test files, and
  this operations record plus its index/active handoff entries
- Commits: local commit containing this record
- Branch and remote state: isolated local branch; no push authorized
- Repository visibility verified: not changed
- Version/build impact: no version change
- Release or distribution impact: none; no artifact assembled or distributed

## Decisions

- Durable decision added or changed: none; this applies the existing
  cross-platform parity and missing-data truth contracts.
- Decision-log entry: none

## Open risks and honest limitations

- Source and JVM tests cannot prove physical TalkBack traversal or every OEM
  font renderer.
- No full suite, lint, instrumentation, simulator, physical-device, hosted-CI,
  deploy, or push was run because the request explicitly constrained the
  verification scope.

## Next round

1. Integrate only after normal review and the repository's required protected
   checks.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or private audit evidence are committed.
