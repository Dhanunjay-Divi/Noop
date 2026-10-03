# Round: 2026-10-03 - Mobile main and private cloud closeout

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/mobile-cloud-release-finalization-20261003`
- Start commit: `1cd401f69dd8b4df75872a830ed33a84918ea344`
- End implementation commit:
  `0d76116178a90f2a93cf7f61b9df579078672868`
- Record commit or PR: evidence commit and protected follow-up PR pending
- Environment: iPhone Simulator, protected GitHub repository, and private
  synthetic GCP staging

## Objective

Close the software, repository, and private-staging portion of the mobile UI
round after the exact-main Apple workflow exposed one intermittent Recovery
chart interaction failure. Preserve normal vertical scrolling and direct chart
navigation while making exact-date inspection deterministic, then integrate
through protected main without turning simulator or synthetic-cloud evidence
into a signed or physical-device claim.

## Scope

### In scope

- Remediate the exact-main Recovery chart scrub failure.
- Preserve direct chart navigation, vertical page scrolling, macOS pointer
  hover, and assistive-technology date stepping.
- Verify the complete local Apple graph and repository release controls.
- Reconcile protected mobile source with the already-deployed private synthetic
  GCP source and reverify the immutable runtime state.
- Prepare the durable signed-device continuation.

### Non-goals

- No public Cloud Run invocation, real OTP, real health data, payment, app-store
  upload, production traffic, firmware action, or physical-band claim.
- No cloud rebuild, migration, or infrastructure apply when `server` and
  `infra/gcp` are byte-identical to the reviewed deployed source.
- No claim about BLE, haptics, battery, background execution, retention,
  accessibility services, or sensor accuracy from simulator or cloud evidence.

## Starting evidence

- PR `#32` exact head
  `cc6739996e11e466c33795bfd1f5d7a189350205` passed all ten required
  contexts and merged normally to protected main as
  `1cd401f69dd8b4df75872a830ed33a84918ea344`.
- Exact-main Apple workflow `37108981075` failed only
  `NOOPiOSUITests.testRecoveryTrendSupportsExactDateScrubbing`; the other nine
  required contexts passed.
- The private synthetic staging deployment remained recorded at protected
  source merge `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c` and immutable
  digest
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`.

## Delivered

- Touch dates now map through the live Swift Charts scale rather than a
  first-to-last linear estimate.
- The chart clears stale selection when its point set changes.
- macOS retains a full-chart hit shape and pointer hover.
- iOS uses a native hold/tap interaction surface that cooperates with the
  enclosing scroll view:
  - a vertical drag scrolls without selecting a date;
  - a held horizontal drag selects and persists an exact dated value;
  - a short tap opens metric detail once;
  - one back action returns to Trends.
- The native interaction applies an explicit horizontal-intent threshold before
  mutating selection state.
- VoiceOver retains the summarized series value and can step through dates with
  the adjustable action.
- The selected point resets when the series or interactive state changes.
- Added focused UI coverage for bidirectional scrub, vertical scrolling,
  direct navigation, and single-entry back-stack behavior.
- Confirmed `server` and `infra/gcp` are unchanged from the reviewed deployment
  source through protected mobile main. No image build, migration, or OpenTofu
  apply was required.
- Reverified all six private Cloud Run services/jobs on the recorded digest,
  private-runtime policy before and after smoke, a complete three-account
  synthetic smoke in 191 seconds, retained-pilot restoration, enabled
  schedulers, zero temporary App Check debug tokens, and zero OpenTofu drift.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Formula, source authority, calibration, and medical-claim impact: none.
- Existing-data impact: fictional synthetic staging only; no personal or health
  data entered this round.
- No raw chart value, phone number, OTP, token, account identifier, private URL,
  database credential, request body, or response body is retained in repository
  evidence.
- The chart change affects interaction and accessibility only; it does not
  change metric values, timestamps, provenance, or health interpretation.

## Observability

- Success is diagnosed through named package and UI tests, bounded command
  logs, terminal XCTest suite summaries, protected-context identities, immutable
  image digests, private-runtime verification, synthetic smoke, and OpenTofu
  refresh plans.
- Gesture rejection is visible because the exact-date accessibility value must
  replace the chart summary after one held horizontal drag. Vertical scroll,
  direct navigation, and one-back behavior have separate assertions.
- The complete iPhone run emitted its terminal passing XCTest result before
  Xcode 27 stalled in teardown; only the owned test processes were then stopped.
- No new production telemetry or high-frequency touch logging was added. The
  interaction is verified at the package and rendered UI boundaries.
- Existing private-staging evidence was reused only after source-tree identity,
  runtime policy, lifecycle smoke, cleanup, scheduler, token, and drift checks
  were reverified.
- Logs and repository evidence exclude raw chart values, account identifiers,
  phone numbers, OTPs, tokens, private URLs, request bodies, response bodies,
  credentials, and personal or health data.
- Remaining blind spots are signed-device touch and accessibility behavior,
  physical radio/background delivery, retention, haptics, battery, supplier
  transport, and sensor truth.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| StrandDesign package | 59 tests passed | Shared chart rendering, selection intent, state reset, and design contracts | Rendered iPhone gestures or physical touch |
| Recovery exact-date focused UI | Passed | One held horizontal drag exposes one exact dated value; reverse scrub selects another date | Every device, frame rate, or physical hand motion |
| Recovery scroll/tap focused UI | Passed | A vertical chart drag scrolls; a tap opens one detail route; one back returns | Physical-device gesture arbitration |
| Recovery repeated relaunch stress | 10 starts, 10 passes, 0 failures | The original intermittent simulator failure did not recur across relaunched test processes | Statistical proof of zero future failures |
| Complete iPhone Simulator graph | 43 tests executed, 1 intentionally skipped, 0 failures | The full local Apple integration boundary passed; the owned Xcode process was stopped only after terminal XCTest output | A clean Xcode teardown, signing, installation, or physical behavior |
| Release-control source gate | 9 checks passed | The reviewed source release-control manifest is coherent | Hosted follow-up status |
| Release-control unit wall | 258 tests passed | Release, evidence, supplier-boundary, and repository-control helpers pass | Runtime cloud or device behavior |
| Local required-CI and trusted controls | Passed | Required context names and trusted reporter binding remain enforced locally | That this follow-up has run any hosted context |
| PR `#32` protected contexts | 10/10 passed on exact head `cc6739996e11e466c33795bfd1f5d7a189350205` | The protected base integrated through the required hosted checks | This follow-up commit's hosted result |
| Calibration and terminology | Passed | Apple/Android metric contracts remain aligned and the legacy-term ratchet did not expand | Sensor calibration or physical parity |
| Legal, private data, and claims | Passed; health-claims tests 8/8 | Distribution provenance, filename privacy, and health wording remain bounded | External legal, medical, or store approval |
| Strict i18n audit | Passed | Supported string catalogs and rendered customer wording remain coherent | Every locale on every physical display |
| Deployment-tree comparison | No `server` or `infra/gcp` changes | A cloud rebuild or apply would deploy identical source | That mobile runtime changes are deployed through a cloud service |
| Private runtime and smoke | Passed before and after; 191-second smoke | Private IAM, storage, processing, isolation, cleanup, and lifecycle behavior remain healthy | Public traffic, real OTP, or personal health data |
| OpenTofu refresh plans | Exit 0 and `No changes` before and after smoke | Applied private staging matches reviewed configuration | Future drift or production launch approval |

## Physical device and deployment

- Install/update action: unsigned follow-up code ran only in the iPhone
  Simulator; no signed phone install, store upload, or public release occurred.
- Generalized device and OS class: current supported iPhone Simulator.
- Data-preservation result: fictional simulator and synthetic staging state
  only; no personal phone or health data was read, replaced, or cleared.
- BLE/background/haptic/battery scenarios exercised: not run.
- Cloud deployment action: no rebuild, migration, or infrastructure apply.
  `server` and `infra/gcp` remain byte-identical to the reviewed source, so a
  mutation would deploy identical content.
- Cloud verification: all six private Cloud Run services and jobs remain on
  immutable digest
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`;
  policy, smoke, retained-pilot restoration, schedulers, temporary-token
  cleanup, and OpenTofu drift were reverified.
- Unrun hardware gates: signed iPhone and Android installation, connection,
  battery, live data, history catch-up, background, notifications, diagnostics,
  accessibility services, retention, haptics, source switching, and metric
  accuracy.

## Git and release state

- Changed paths: `TrendChart.swift`, focused StrandDesign tests, iPhone UI
  interaction tests, `docs/ops/ACTIVE.md`, the round index, and this record.
- Commits: protected base
  `1cd401f69dd8b4df75872a830ed33a84918ea344`; implementation
  `0d76116178a90f2a93cf7f61b9df579078672868`; evidence commit pending.
- Branch and remote state: the implementation commit is local on
  `codex/mobile-cloud-release-finalization-20261003`; push, protected exact-head
  checks, normal merge, and exact-main verification remain pending.
- Repository visibility verified: unchanged. Supplier binaries, firmware,
  credentials, signing material, private references, and personal or health
  data remain excluded from public source.
- Version/build impact: no version or build-number change; chart touch,
  navigation, and accessibility interaction behavior changes.
- Release or distribution impact: none yet. No signed archive, store upload,
  release tag, public service, or physical install is claimed.

## Decisions

- Use the live chart scale and a scroll-cooperative native iOS interaction
  surface instead of estimating date positions from first and last points.
- Preserve direct tap navigation, macOS hover, and adjustable accessibility
  date stepping while requiring clear horizontal intent for touch scrubbing.
- Do not rebuild or mutate private staging when cloud source is unchanged and
  the immutable runtime has passed policy, smoke, cleanup, and drift checks.
- Integrate only through protected pull-request checks; do not dispatch or
  rerun hosted workflows manually to manufacture release evidence.
- Keep simulator, synthetic-cloud, signed-device, and physical-band evidence as
  separate gates.

## Open risks and honest limitations

- Protected follow-up exact-head checks and the normal merge remain pending.
- Exact protected-main checks on the follow-up merge remain pending.
- Signed iPhone and Android install, connection, battery, live data, history
  catch-up, background, notification, diagnostics, accessibility services,
  retention, haptics, source switching, and metric accuracy remain untested.
- Supplier physical validation remains blocked until the approved exact-model
  artifact tuple and trust manifest are available and verified.
- Real OTP, public traffic, payments, provider delivery, app-store review, and
  external launch approval remain open.

## Next round

1. Push this exact candidate and wait for all ten required protected contexts.
2. Merge normally only when exact-head checks are green.
3. Verify all ten required contexts on the exact protected-main merge.
4. Start signed physical validation from clean protected main and follow
   `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`.
5. Validate the existing comparison transport first. Enable the quarantined
   supplier source only with approved exact-model artifacts and trust evidence.
6. Record privacy-safe physical evidence without weakening any gate.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, physical
      device identifiers, signing identities, or absolute personal paths are
      present.
