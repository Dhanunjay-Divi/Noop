# Round: 2026-10-01 — Physical-band candidate preparation

## Status

- State: `incomplete`
- Owner: recovery agent
- Branch: `codex/physical-band-review-20261001`
- Start commit: `232f746e045d2755947579c3408efc5c3b84ff69`
- End implementation commit: `2e676e75dda24c203c12d755fe0530b92ca56f3b`
- Record commit or PR: none

## Objective

Continue the owner's two-iPhone WHOOP/supplier comparison using the attached
handoff's exact candidate as the base. The owner subsequently authorized scoped
fixes on a review branch, a review document for the primary agent, and stable
SDK adaptation boundaries. Prepare the candidate without claiming unrun physical
results or treating attached procedures as broader authority.

## Scope

### In scope

- Exact candidate and source-only SDK verification, local signing/artifact audit,
  connected-device preflight, bounded device build, and evidence report.
- WHOOP and supplier on separate phones with one collector per band.
- Supplier optional-read serialization and cancellation regressions; full metric
  input-parity audit and SDK replacement contract for primary-agent review.

### Non-goals

- Remote merge, release, firmware change, account bypass, uninstall, or reset.
- Claiming Android results when no Android phone has been provided.

## Starting evidence

- Candidate branch: `codex/today-metric-catalog-fitness-age-20261001`.
- Isolated clean checkout at the exact handoff commit; original trees preserved.
- iPhone 13 Pro Max / iOS 27.0.1 reports Developer Mode disabled and unavailable
  transport; iPhone 17 Pro Max / iOS 27.0 reports enabled but disconnected.
- One development signing identity is present; compatibility remains unverified.
- Neutral SDK source revision and manifest SHA-256 match the handoff.
- Phone-to-band assignments, hardware/firmware, account configuration, installed
  app identity, backup state, and approved supplier artifacts remain unknown.

## Delivered

- Isolated the pinned candidate and ran its recovery context snapshot.
- Prepared a privacy-safe review scaffold; no band scenarios completed yet.
- Fixed Apple optional step/sleep overlap. Due sleep waits for step completion or
  failure and receives priority over the next poll; disconnect/stop clears the
  pending read. Unrequested results are ignored. Added behavioral regressions.
- Audited derived-metric input parity. Supplier event/persistence seams currently
  carry HR, native steps, and sleep summaries, with no R-R, oxygen, temperature,
  raw-motion, or REM ingest channel. Shared calculation presence cannot establish
  physical input/output parity. Shared formula and SDK-client APIs are unchanged.
- Both test phones now report enabled Developer Mode and connected wired
  transport. The 13 Pro Max app inventory contains no NOOP app; the 17 Pro Max
  app query was rejected while locked.
- Configured only the existing ignored signing prefix/team and generated the
  Xcode project. Supplier verifier failed because the external SDK root is
  incomplete; approved managed-account configuration is absent locally.

## Data, privacy, and medical truth

- Schema or migration impact: none; no formula or calibration policy changed.
- Existing-data retention impact: no installation, deletion, or reset yet.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: no changes or health uploads.
- Health/medical claim impact and limitations: comparison does not prove accuracy.

## Observability

- Evidence: sanitized device metadata, bounded build status, exact artifact gates,
  and existing user-initiated AppDiagnosticsRecorder reports.
- Existing evidence reused: pinned handoff, source verification records, core
  categorical command diagnostics, and the passing 70-case native source suite.
- New bounded events or operation spans: none. Existing core step/sleep begin,
  completion, rejection, and categorical failure events diagnose the requests.
  Serialization removes overlap; awaiting a callback remains visible as a
  request without completion. The pending sleep emits begin only when dispatched.
- Redaction/retention: identifiers and signing/config secrets stay out of Git.
- Cross-platform/backend correlation: Android and live provider not run.
- Remaining blind spots: live bands, account provider, background, history, battery,
  and a supplier SDK request that never produces any callback. Timeout/retry
  semantics are not invented by this fix. Android bridge has HR/battery only and
  no step/sleep command path to mirror; wider Android capability parity remains open.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Context snapshot and clean starting status | Pass | Candidate provenance | Physical operation |
| Neutral SDK manifest assertions | Pass | Exact source-only artifact | Supplier compatibility |
| Sanitized devicectl discovery | Incomplete connection | Cached phone state | Install readiness |
| Development signing identity inventory | One identity | Local identity exists | Profiles or entitlements valid |
| Exact ten-file neutral SDK verifier | Pass | Pinned source artifacts | Physical transport |
| Swift frontend parse of changed source/tests | Pass | Swift syntax | App linking or async behavior |
| Supplier SDK wrapper boundary tests | Pass: 7/7 | Imports remain confined to native wrapper | Exact-model runtime |
| Signed iOS first build | Interrupted after dependency clone stalled | Bounded process-group cleanup | Signing or build pass |
| Signed iOS network-bounded retry | Fail: grpc binary download lost connection, exit 74 | Concrete dependency gate | Product defect, signing or installation |
| Focused Apple supplier regression wall | Pass: 70/70, zero failures | Shared source scheduling, failure release, pending priority, cancellation, unsolicited result rejection | Physical SDK or BLE behavior |
| iOS signing preflight with resolved graph | Fail: exit 65, required capability/profile mismatch | Concrete signing gate: App Groups, HealthKit, push, App Attest | Installed candidate |
| Unsigned iOS fix build | Pass: complete app/Watch/complication/widget graph; zero compiler errors | Default-off iPhoneOS compilation | Signing or supplier-enabled build |
| Android Full Debug APK assembly | Pass: version 9.2.1-debug / 304; not installed | Exact-source default-off Android package | Physical Android or supplier transport |
| Runtime compatibility inventory | Zero approved band rows | Exact current activation gate | Hardware compatibility approval |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: iPhone 13 Pro Max / 27.0.1; 17 Pro Max / 27.0.
- Data-preservation result: existing data untouched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical band cases; Android phone not provided.

## Git and release state

- Changed paths: supplier source scheduler, its existing Apple test file, public-safe
  dated review under docs/handoff, this record, ACTIVE.md, and rounds/INDEX.md.
- Ignored local inputs: existing signing prefix/team only and generated Xcode project.
- Commits: `2e676e75dda24c203c12d755fe0530b92ca56f3b` contains the scoped source/test fix.
- Branch and remote state: local review branch from exact baseline with the
  committed fix; review branch publication pending. Candidate PR 27 remains open
  at the original baseline; main has not advanced during this round.
- Repository visibility verified: public via GitHub REST; no supplier or personal
  artifacts are included in the source review.
- Version/build impact: iOS 9.2.1 / 231 unsigned; Android 9.2.1-debug / 304 APK assembled. Neither installed.
- Android artifact SHA-256: `77c4513713f95166e4502ff273f1d9b780ccccec4f4091baf15ca04bd5832fb6`.
- Release or distribution impact: none.

## Decisions

- Durable decision added or changed: owner reaffirmed existing common-layer
  SDK architecture (D-054/D-056); no new abstraction or decision needed.
- Decision-log entry: not needed.

## Open risks and honest limitations

- Both phones now have Developer Mode enabled and wired transport available.
  Approved supplier artifacts, account setup, and local signing compatibility
  must still pass before physical install and collection claims.
- Review branch has a local fix beyond the pinned baseline. No signed immutable
  fix artifact or physical behavior has yet been validated.
- Attached clean-install procedure cannot authorize deletion of existing history.

## Next round

1. Finish focused supplier regressions, review the exact diff, and prepare the
   committed review branch for the primary agent.
2. Verify local configurations and artifact gates; run bounded exact-device build.
3. Detect the owner's Android phone when connected; Full Debug APK is ready.
   Audit existing app/signature and backup state before an in-place install.
4. Recheck unlocked wired phones, existing app identity, and data recovery path.
5. Upgrade in place and record WHOOP baseline then separate supplier evidence.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
