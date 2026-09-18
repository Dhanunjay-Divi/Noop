# Round: 2026-09-17 - UI, account, and cross-platform readiness review

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/ui-cloud-readiness-20260917`
- Start commit: `b688b3b725cd497e96a31b28540a219bf50446e1`
- End implementation commit:
- Record commit or PR:
- Final local verification counts: `<pending exact-current closeout>`
- Hosted required contexts: `<pending candidate SHA and 10/10 result>`
- Protected merge SHA: `<pending>`

## Objective

Independently review the private September 17 UI reimagination bundle against
the exact current repository, correct source-verifiable defects, and verify that
iPhone, Android, macOS, and Watch contracts remain aligned where the capability
applies.

Success means:

- external findings are classified as confirmed defects, proposals, owner
  decisions, configuration gates, hardware gates, or stale findings;
- proven formula-explanation, terminology, loading, accessibility, navigation,
  and account-journey defects are corrected on every applicable platform;
- cloud-authoritative storage is not silently introduced in conflict with the
  current local-first contract;
- focused and complete applicable automated checks are recorded honestly; and
- release readiness separates software evidence from Xcode, signing, store,
  legal, carrier, production-runtime, supplier SDK, and physical-device gates.

## Scope

### In scope

- Independent source and visual review of the supplied reports and mockups.
- Apple/Android semantic parity for account visibility, metric vocabulary,
  missing/loading states, accessibility, and navigation.
- Shared Apple review covering iOS, macOS, widgets, and Watch source/build
  contracts.
- Recovery and Sleep Score formula explanation/revision audit without changing
  unvalidated physiology.
- Focused observability review for every changed user-visible boundary.
- Bounded local verification and durable release-handoff updates.

### Non-goals

- Making managed cloud storage authoritative for core health data without an
  explicit decision that supersedes the current local-first product contract.
- Enabling public traffic, production health-data transfer, real Safety paging,
  billing, or customer accounts.
- Claiming BLE, background collection, battery, haptics, notification delivery,
  physiological accuracy, or Watch connectivity without physical-device
  evidence.
- Creating signing identities or completing legal, carrier, store, supplier,
  or manufacturing actions for the owner.

## Starting evidence

- Reproduction or observed symptom: the private audit reports account
  invisibility in first run, inconsistent metric language, incomplete
  accessibility behavior, and a proposed cloud-authoritative redesign.
- Relevant source/device/OS/firmware class: exact `main` at the start commit;
  iOS 17+, macOS 13+, Android Full/Demo, Watch sources, and the managed server.
- Existing tests, logs, exports, screenshots, or documents: 26 current
  simulator captures, 86 proposed mockups, five summary reports, three detailed
  source audits, prior exact-main protected checks, and the production release
  checklist.
- Unknowns that must remain unknown until measured: physical BLE and Watch
  behavior, terminated-app collection, real notification delivery, supplier
  protocol behavior, production cloud latency/availability, and clinical or
  physiological accuracy.
- At round start, Xcode 27 was installed but its license was not accepted. On
  2026-09-18, `xcodebuild -license check` exited `0`; this is no longer a
  blocker.

## Delivered

- Opened an isolated review branch and preserved the clean protected main
  worktree.
- Classified the cloud-authoritative direction as a proposed product decision,
  not an implementation requirement under the current repository contract.
- Kept core collection, scoring, current history, local export, and device
  control local-first; NOOP+ remains a separately consented optional replica.
- Corrected ownership-step availability to follow configured capability rather
  than transient runtime availability, and made Android resume an unavailable
  saved Ownership/Account checkpoint at Profile/About You rather than Welcome.
- Aligned confirmed Recovery explanation, Sleep Score terminology, Watch
  labels, Android large-text navigation, widget localization, and managed-sync
  retry behavior in the affected sources.
- Confirmed that managed-history portability is incomplete: the current
  exporter is non-resumable, has no importer, and includes `day_ownership` as
  the only managed document in its current export scope. `DAT-170` remains
  open.
- Confirmed that NOOP+ managed-data erasure is distinct from first-party band
  ownership-account deletion. The ownership deletion/retirement lifecycle in
  `ACC-340` is not implemented.

## Data, privacy, and medical truth

- Schema or migration impact: no schema or migration change in the current
  reviewed slice.
- Existing-data retention impact: no retention policy change is enabled by this
  round.
- Source/provenance or formula impact: explanation and revision contracts are
  under review; no physiological-accuracy claim follows from the source edits
  or focused tests.
- Permissions/network disclosure impact: no new transfer or permission is
  enabled by this review.
- Cloud-authority impact: none. NOOP+ remains opt-in and cannot become a
  dependency of core collection, scoring, local history, export, or device
  control.
- Health/medical claim impact and limitations: missing data remains missing;
  no diagnosis, sleep-apnea detection, body-composition inference, or automatic
  emergency inference is introduced.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  bounded platform diagnostics and deterministic UI/test state will be reviewed
  for every changed boundary.
- Why existing evidence is sufficient, or why new evidence is required: to be
  recorded per implemented slice.
- Existing evidence reused: platform `AppDiagnosticsRecorder` paths, server
  request observability, and current loading/sync lifecycle tests.
- New bounded events or operation spans: none at round start.
- Redaction, retention, and high-frequency controls: no health values, content,
  credentials, identifiers, URLs, payloads, or per-frame/sample events.
- Cross-platform/backend correlation: no new correlation at round start.
- Remaining blind spots: OS and hardware behavior that requires physical
  devices.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `git status --short --branch` at start | clean `main` at start commit | Review begins from protected integrated source | Product behavior |
| `xcodebuild -license check` | exit `0` on 2026-09-18 | The prior local license blocker is resolved | Any app behavior |
| Private audit bundle inventory | reports, current captures, and mockups present | Review input is available | Accuracy of its conclusions |
| Final focused Apple `StrandTests` rerun | 31 passed, 0 failed, 0 skipped across `FormulaPublicationGateTests`, `MoreListParityTests`, `RootDynamicTypeContractTests`, and `ManagedCloudRetryContractTests` | The exact-current formula-publication gate, Apple navigation/accessibility, and managed-cloud retry contracts compile and pass on macOS | Complete Apple app, iPhone simulator, Watch connectivity, or physical behavior |
| `NOOPiOSWidgets` narrow simulator build | success, exit `0` | The widget target and target-owned localization catalog compile | Host-app integration or physical widget refresh |
| Final focused Android Full-debug unit run | 50 passed, 0 failed/errors/skips across `PrimaryNavigationContractTest`, `FormulaPublicationGateTest`, `RemoteSyncCoordinatorTest`, `ManagedCloudSchedulerTest`, and `IntelligenceDaySourceTokenTest`; build success | The exact-current navigation/accessibility, formula-publication, remote-sync, managed-retry, and bounded historical-diagnostic contracts compile and pass on the JVM | Demo flavor, lint, APK, instrumentation, emulator, OEM, or physical behavior |
| Exact round-owned resource cleanup | Checksummed manifest `/tmp/noop-ui-cloud-session-cleanup-20260918.tsv` and SHA-256 sidecar recorded; 47 closed 2026-09-18 session JSONLs totaling 51.92 GiB were removed while the current goal and then-active agents were preserved. Failed/old round-owned DerivedData and `AppleFocusedFinal` DerivedData were exact-deleted after preserving the focused result summary; the post-cleanup disk measurement was approximately 65 GiB free. | Enumerated regeneratable local resources were removed without blanket session or worktree deletion, and focused evidence was preserved before deleting its DerivedData | Current memory pressure, future disk growth, product correctness, hosted resources, or unidentified external resources |
| Complete Apple wall | `<pending final exact-current count and result>` | To be recorded after the final source tree is stable | Physical BLE, Watch connectivity, notification delivery, battery, physiology, or physical accessibility |
| Complete Android wall | `<pending final exact-current count and result>` | To be recorded after the final source tree is stable | OEM/background/BLE/haptic/battery/attestation or physical accessibility |
| Package, server, static, privacy, and operations walls | `<pending final exact-current count and result>` | To be recorded after the final source tree is stable | Production credentials, public runtime, load, Docker restore unless explicitly run, or external launch approval |
| Hosted protected checks and integration | `<pending candidate SHA, 10/10 contexts, PR, and merged SHA>` | Exact-head source integration only after recorded success | Signing, stores, legal, carrier, hardware, physiology, or production launch |
| Documentation reconciliation | `git diff --check` passed; 74 operations records validated; private-data filename guard passed | The active records are structurally valid and this documentation slice introduced no rejected private filename | Product behavior, hosted checks, physical behavior, or production readiness |
| Health-claim source gate | clear; 1,260 files scanned | The current tracked source and documentation pass the repository's claim-pattern policy | Physiological accuracy, clinical validation, regulatory approval, or safe real-world outcomes |
| Legal inventory source gate | 230 runtime components and three container inputs verified | The repository's current license/inventory structure passes its source check | Counsel approval, commercial rights, supplier rights, certification, signing, or store approval |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: no product data mutation at round start.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all supplier-band, BLE, Watch connectivity, background,
  battery, haptic, notification-delivery, and physiological validation.

## Git and release state

- Changed paths: the active branch contains Apple, Android, package,
  localization, project, release-metadata, and operations-record changes. The
  documentation-reconciliation worker edits only documentation and does not
  alter code, generated metadata, required-CI hashes, or release JSON.
- Documentation reconciled in this slice:
  `docs/FEATURE_PARITY.md`, `docs/FIRST_PRODUCTION_RELEASE_PLAN.md`,
  `docs/PLATFORM_ARCHITECTURE.md`, `docs/PRIVACY_SECURITY.md`,
  `docs/PRODUCTION_READINESS.md`, `docs/RELEASE_CONTROLS.md`,
  `docs/handoff/HARDWARE-AND-PREMIUM-STRATEGY.md`,
  `docs/handoff/RELEASE-BLOCKERS.md`, `docs/ops/ACTIVE.md`,
  `docs/ops/rounds/INDEX.md`, and this round record.
- Commits: none.
- Branch and remote state: isolated local branch, not pushed.
- Repository visibility verified: not re-verified in this round yet.
- Version/build impact: none at round start.
- Release or distribution impact: no deployment or release action.

## Decisions

- Durable decision added or changed: none. The private bundle's
  cloud-authoritative direction remains a proposal because it conflicts with
  the current hard local-first contract.
- Portability and account-deletion status are clarified, not redefined:
  `DAT-170` and `ACC-340` remain open.
- Decision-log entry: none at round start.

## Open risks and honest limitations

- Complete exact-current Apple, Android, Swift-package, server, localization,
  static-policy, operations, hosted exact-SHA, and integration gates remain
  unrun for the final branch state.
- Managed-history export is not resumable and has no archive importer or
  complete live expiry/corruption/large-account proof (`DAT-170`).
- First-party ownership-account deletion, approved band retirement/quarantine,
  provider identity cleanup, retention policy, and operator recovery remain
  unfinished (`ACC-340` plus external legal/operations decisions).
- The first-party band SDK/protocol, representative hardware, signing/store,
  legal, carrier, production-runtime, and physical accessibility/device gates
  remain release blockers outside this source-only review.

## Next round

1. Finish the remaining source review and stabilize the dirty implementation.
2. Run the complete exact-current Apple wall; Android Full/Demo build, unit,
   lint, instrumentation-compile, and both API 35 managed-device lanes; all nine
   Swift packages; `Tools/StudyHarness`; `Tools/Backfill`; and the complete
   server, localization, calibration, terminology, privacy, static-policy,
   required-CI, trusted-release, and operations walls.
3. Record the resulting exact counts without converting simulator or source
   evidence into physical-device claims.
4. Commit once, run all ten hosted required checks on that exact SHA, and
   integrate normally only if every applicable gate is green; candidate SHA,
   pull request, hosted `10/10`, protected merge SHA, and protected-main trusted
   result remain pending until they exist.
5. Preserve `DAT-170`, `ACC-340`, and every physical, signing/store, legal,
   carrier, credential, production-runtime, and elapsed-soak gate until direct
   evidence closes it.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
