# Round: 2026-09-17 - UI, account, and cross-platform readiness review

## Status

- State: `historical checkpoint; final evidence and authority scope are superseded by the 2026-09-19 round`
- Owner: project team
- Branch: `codex/ui-cloud-readiness-20260917`
- Start commit: `b688b3b725cd497e96a31b28540a219bf50446e1`
- End implementation commit: commit containing this record
- Record commit or PR: protected pull request opened from this branch
- Final local verification counts: macOS 2,144 passed plus 1 skip; iPhone shell
  38 passed plus 1 skip; Android Full and Demo 4,883 tests per variant plus 7
  skips; API 35 114 passed plus 2 private-pilot skips and Review Sample 1/1;
  server 647 passed plus 1 skip; 11 Swift package/tool build-and-test pairs,
  6 OpenTofu tests, and 134 bounded-runner/required/trusted-control tests passed
- Hosted required contexts and protected merge: not established by this
  checkpoint; pull request `#16` and the 2026-09-19 successor round are
  authoritative for the replacement candidate.

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
- Integrated v2 managed-history integrity, resumable snapshot export, complete
  prevalidation before local mutation, and resumable idempotent import on
  Apple and Android. `day_ownership` remains the only managed document in the
  current selected scope; live expiry, scale, isolation, low-storage, and
  physical process-death evidence keep `DAT-170` open.
- Implemented supplier-independent ownership-account deletion request, status,
  cooling-off cancellation, session revocation, target coordination, matched
  Apple/Android state, localization, and bounded diagnostics. Provider identity
  erasure and approved physical band retirement/wipe keep `ACC-340` open.
- Added feedback duration idempotency migration `044` and durable ownership
  deletion progress migration `045`, backup/restore manifest coverage, and
  direct PostgreSQL regression tests.
- Added a default-off ownership deletion lifecycle coordinator. Its separate
  exact least-privilege database role may schedule and monitor the existing
  managed erasure service only for the declared `managed_cloud_data` target;
  it cannot read or mutate arbitrary managed health rows.
- Hardened the bounded command runner so omitted logs are discarded, explicit
  logs are private and capped, the CLI enforces automatic 10% free-memory and
  10 GiB free-disk floors, and output/memory/disk pressure terminates the
  complete process group. Android managed-device CI now uploads capped logs
  only for failure/cancellation.
- Added a deterministic Safety paging smoke that routes preselected dummy
  registrations through the production token codec, managed push service, and
  FCM payload builder without provider traffic. It captures a test-only owner
  confirmation plus two dummy emergency-contact deliveries across iOS and
  Android and rejects location, health values, and names in the push. Accepted
  contact selection/revocation and latest-only location persistence/deletion
  remain separate PostgreSQL integration-test boundaries.

## External finding disposition

The September 17 bundle was treated as review input, not as an approved product
specification:

| Bundle finding | Disposition |
|---|---|
| Cloud-authoritative core storage and mandatory account | Rejected for this round because it conflicts with the current local-first decisions. No authority flip, silent enrollment, or core cloud dependency was introduced. |
| Application-level database encryption | The factual posture is confirmed: Apple uses file protection and platform disk encryption, Android uses platform device encryption, and neither app database is SQLCipher-encrypted. The bundle's proposed encrypted seven-day cloud-authoritative cache is not the current architecture. A cross-platform database-encryption migration, key recovery, performance, backup, and rollback design remains a separate security/product decision under the existing store and security gates; this round makes no stronger encryption claim. |
| Existing-user cloud-authority migration | Not applicable without an approved authority change. Optional NOOP+ upload remains explicit and resumable; local history remains authoritative. |
| Production cloud authority before C8.2/C8.3/C8.6 | Rejected. Public ingress, recovery/restore operations, and load evidence remain explicit production gates. |
| Automatic managed-window pruning | Not enabled globally. Exact server validation remains mandatory before the existing optional NOOP+ pruning path; low-storage, ack-loss, and physical lifecycle evidence remain open rather than weakening the local-first retention contract. |
| Cross-device conflict card and automatic merge | Kept as a proposal. Existing conflict deferral is fail-closed; changing personal-document merge semantics needs a separately reviewed product/data decision. |
| Managed restore corruption and resume | Implemented for the selected managed scope with v2 integrity, complete prevalidation, resumable export, and idempotent resumable import. Live scale, expiry, cancellation/auth refresh, cross-tenant, low-storage, and physical process-death evidence remain under `DAT-170`. |
| Trends loading, navigation accessibility, Recovery/Daily Signal vocabulary, formula explanation/revision, missing-state and terminology findings | Confirmed defects were corrected and covered by the complete Apple/Android, simulator, localization, visual, and policy walls. |
| First-run ownership visibility | Corrected when the ownership capability is configured; transient service unavailability no longer hides the step. Core exploration remains account-free and supplier possession remains hardware-gated. |
| Account deletion surface | Supplier-independent request, status, cooling-off cancellation, session revocation, durable per-target progress, restricted `managed_cloud_data` erasure scheduling/monitoring, mobile presentation, localization, and bounded diagnostics are implemented default-off. Provider identity erasure, ownership control-plane final erasure, and physical band retirement/wipe remain under `ACC-340`. |
| Sync/provenance presentation and broader UI reimagination | Existing source, confidence, collection, and sync states were retained or corrected where source-proven. Cloud-authority-specific visual proposals were not adopted without the corresponding product decision and runtime truth. |

## Data, privacy, and medical truth

- Schema or migration impact: additive ownership deletion declarations from
  migration `043`, feedback idempotency-duration migration `044`, and durable
  immutable ownership deletion progress from migration `045`; backup manifests
  and restore smoke were updated and verified.
- Existing-data retention impact: no retention policy change is enabled by this
  round.
- Source/provenance or formula impact: Recovery/Rest explanation and revision
  contracts were aligned without changing unvalidated physiology; no
  physiological-accuracy claim follows from these source edits or tests. Direct
  phone/watch or device step counts remain preferred over NOOP motion estimates.
  Exact-band rejection of stationary hand movement remains a physical
  ground-truth gate because the supplier SDK exposes firmware-computed totals,
  not enough evidence for reliable app-side false-step removal.
- Permissions/network disclosure impact: no new transfer or permission is
  enabled by this review.
- Cloud-authority impact: none. NOOP+ remains opt-in and cannot become a
  dependency of core collection, scoring, local history, export, or device
  control.
- Health/medical claim impact and limitations: missing data remains missing;
  no diagnosis, sleep-apnea detection, body-composition inference, or automatic
  emergency inference is introduced.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: ownership
  deletion request/refresh/cancel, managed export/import, managed retry, report
  upload, and server request boundaries use fixed-category bounded operation
  events plus deterministic persisted state.
- Why existing evidence is sufficient, or why new evidence is required:
  managed import and ownership deletion introduced new fallible boundaries and
  received matching bounded events; presentation-only changes reuse tested
  deterministic state and existing diagnostics.
- Existing evidence reused: platform `AppDiagnosticsRecorder` paths, server
  request observability, and current loading/sync lifecycle tests.
- New bounded events or operation spans: `managed_import`, resumed
  `managed_export`, and ownership account-deletion request/refresh/cancel
  lifecycle events with categorical outcomes and bounded durations/counts. The
  coordinator emits `ownership_deletion.lifecycle` using fixed status/failure
  categories and aggregate counts only.
- Redaction, retention, and high-frequency controls: no health values, content,
  credentials, identifiers, URLs, payloads, or per-frame/sample events.
- Cross-platform/backend correlation: no new correlation at round start.
- Remaining blind spots: OS and hardware behavior that requires physical
  devices.
- Safety smoke evidence is deterministic and bounded: it reports only fixed
  roles, platforms, target kinds, payload category, route, priority, generic
  localization keys, and aggregate delivery counts. It emits no token, account,
  installation, incident, capability, phone, name, health, or coordinate value
  and makes no external network request.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `git status --short --branch` at start | clean `main` at start commit | Review begins from protected integrated source | Product behavior |
| `xcodebuild -license check` | exit `0` on 2026-09-18 | The prior local license blocker is resolved | Any app behavior |
| Private audit bundle inventory | reports, current captures, and mockups present | Review input is available | Accuracy of its conclusions |
| Final focused Apple `StrandTests` rerun | 31 passed, 0 failed, 0 skipped across `FormulaPublicationGateTests`, `MoreListParityTests`, `RootDynamicTypeContractTests`, and `ManagedCloudRetryContractTests` | The exact-current formula-publication gate, Apple navigation/accessibility, and managed-cloud retry contracts compile and pass on macOS | Complete Apple app, iPhone simulator, Watch connectivity, or physical behavior |
| `NOOPiOSWidgets` narrow simulator build | success, exit `0` | The widget target and target-owned localization catalog compile | Host-app integration or physical widget refresh |
| Final focused Android Full-debug unit run | 50 passed, 0 failed/errors/skips across `PrimaryNavigationContractTest`, `FormulaPublicationGateTest`, `RemoteSyncCoordinatorTest`, `ManagedCloudSchedulerTest`, and `IntelligenceDaySourceTokenTest`; build success | The exact-current navigation/accessibility, formula-publication, remote-sync, managed-retry, and bounded historical-diagnostic contracts compile and pass on the JVM | Demo flavor, lint, APK, instrumentation, emulator, OEM, or physical behavior |
| Exact round-owned resource cleanup | The earlier checksummed session cleanup removed 47 closed September 18 session JSONLs totaling 51.92 GiB while preserving the current goal and active agents. Final September 19 cleanup then removed exactly 16 regeneratable targets: Android app/root build output and worktree `.gradle`, the local OpenTofu cache, 11 Swift package/tool `.build` directories, and the synthetic server virtualenv; synthetic database `noop_ui_cloud_deletion_20260918_r1` was dropped. Every target and database absence was verified, no matching DerivedData remained, and free disk rose from about 15 GiB to 20 GiB. | Enumerated round-owned generated resources were removed without deleting source, credentials, sessions, simulators, user data, or unidentified external resources | Future cache growth, unrelated application memory, hosted resources, or product correctness |
| Terminal-output memory guard | The bounded runner discards child output unless a private log is explicitly requested, checks explicit logs every 100 ms, stops the complete process group at the default 128 MiB ceiling, truncates overshoot, and reports `resource-output`; its CLI now refuses to start or continue below 10% free system memory or 10 GiB free disk unless a narrow recorded caller override is supplied. All eight Android managed-device CI calls retain capped private logs as uploaded diagnostics. The active iTerm profile has unlimited scrollback disabled with a 1,000-line limit. The final runner/required/trusted-control regression executed 134 tests in 27.006 seconds with zero failures; iTerm stayed near 219 MiB with 48% free system memory. | Repository heavy commands cannot flood iTerm merely because a caller omitted `--log-file`; explicit runner logs cannot grow without a hard ceiling; and output, timeout, resource-pressure, and process-group cleanup paths are regression-covered | Commands run outside the bounded runner, unrelated applications, OS-wide faults, or a user changing terminal preferences |
| Hosted Android disk-floor correction | PR `#16` candidate `1505be75` built both managed-device APK sets successfully, then production-shell and Review Sample emulator setup each stopped before tests with exact uploaded `resource-disk`/`125` status under the generic 10 GiB floor. The correction retains that floor for compilation, applies `--min-free-disk-gib 4` only to the six managed-emulator execution/reset commands, and makes every bounded resource status parse as valid fail-closed non-retry evidence. The exact production artifact now classifies as `bounded-resource-disk`; 304 tool tests with one intentional skip, required-CI `10/10`, actionlint, Python compilation, and diff validation pass locally. | The two failures share one diagnosed hosted-capacity boundary; the correction does not hide assertion failures, and a genuine test result still prevents retry | The replacement hosted API 35 run, OEM/physical behavior, or proof that every future runner image has sufficient capacity |
| Complete Apple wall | macOS 2,144 passed and 1 intentional skip; iPhone shell 38 passed and 1 intentional skip; unsigned iOS, widgets, Watch, and Watch complications builds passed; ownership contract 8/8 passed after localization | Exact-current Apple source compiles across app targets and the complete app/simulator contracts pass | Physical BLE, Watch connectivity, notification delivery, battery, physiology, or physical accessibility |
| Apple visual and accessibility review | The preserved tab-shell output revalidated 21 scenarios on each of iPhone 17 Pro Max and 17e plus 42 unique manifest rows. All 11 expected Daily Plan captures revalidated at 1170x2532 with clean crash logs and distinct check-in/stop states. Representative normal, dark, contrast, and accessibility-size renders were inspected during capture. | No blocking overlap or clipping was found in the exercised simulator states, and cleanup did not destroy the evidence | VoiceOver order, touch ergonomics, physical contrast, haptics, or device performance |
| Complete Android wall | Full and Demo each completed 4,883 unit tests with 7 skips and 0 failures after the final stale expectation was corrected; both lint variants, APKs, and instrumentation source compilation passed | Exact-current Android source compiles and passes both shipped variants | OEM/background/BLE/haptic/battery/attestation or physical accessibility |
| Android API 35 lanes | production shell passed 114 tests with 2 expected private-pilot skips; fresh Review Sample passed 1/1 | Current packaging, WorkManager startup, navigation, and production-shell runtime contracts pass on the managed emulator | OEM, terminated-process delivery, physical sensors, or hardware behavior |
| Swift packages and tools | all 11 build-and-test pairs passed: nine packages plus `StudyHarness` and `Backfill` | Shared protocol, storage, analytics, import, design, access, managed-sync, and tool code compiles and tests | App signing, live cloud, or hardware behavior |
| Server wall | PostgreSQL-backed suite passed 647 tests with 1 intentional skip; Ruff check and format check passed; restore-application smoke passed | Ownership deletion declarations and durable progress, restricted managed erasure coordination, feedback migration, backup/restore, tenancy, Safety, and server contracts pass against the test database | Production credentials, public runtime, regional recovery, load, or live provider deletion |
| Synthetic Safety paging smoke | `Tools/safety-paging-smoke.py` reported 3/3 installations and 2/2 preselected dummy emergency-contact roles reached for a test-only owner preview, one iOS contact, and one Android contact. Its direct pytest passed 1/1 and Ruff passed. Three PostgreSQL tests passed: accepted-contact selection with encrypted token opening, acknowledgement and revocation; latest-only location with direct resolved-state deletion; and transactional expiry with direct deletion. The Apple `SafetyPagingAndShellContractTests` passed 51/51. Android Full and Demo each passed 45/45 across payload, scheduler, runtime-notification, and paging-policy contracts. Database `noop_safety_paging_20260919_r3`, the temporary Python environment, and test logs were removed after evidence. | Dummy owner-preview and iOS/Android contact payload construction make no provider request and contain no name, health value, or coordinate. Separate database tests cover accepted-recipient and precise-location contracts, while both client suites cover fixed payload parsing, notification routing, private generic copy, and bounded lifecycle behavior. | APNs/FCM receipt, lock-screen presentation on a physical phone, background wake, carrier/SMS/voice delivery, physical-device acknowledgement, or emergency suitability |
| OpenTofu ownership defaults | 6 of 6 tests passed | Managed ownership deletion coordination stays default-off and wires only a separate secret-backed lifecycle database credential when explicitly enabled | Applied cloud IAM, production secrets, runtime reachability, or public traffic |
| Localization and policy walls | The September 19 post-documentation rerun passed release controls, calibration, terminology, required-CI, trusted self-verification, distribution provenance, private-data, health-claims across 1,273 files, changed-file localization, complete Apple/Android localization, validation of all 75 operations records, and `git diff --check`. The terminology snapshot contains 17,702 classified occurrences across 1,565 path/category groups, zero forbidden mappings, and is pinned by required-CI. | The exact pre-commit working tree satisfies the repository-controlled localization, policy, claim, terminology, operations, and trust contracts | Counsel approval, physiological truth, signing, stores, hosted exact-SHA checks, or production authorization |
| Hosted protected checks and integration | The protected pull request for the end implementation commit records the exact candidate SHA, ten required contexts, merge result, and protected-main verification | Exact-head source integration only after recorded success | Signing, stores, legal, carrier, hardware, physiology, or production launch |
| Documentation reconciliation | `git diff --check`, private-data filename validation, and all 75 operations records passed on the final pre-commit tree | The active records are structurally valid and this slice introduced no rejected private filename | Product behavior, hosted checks, physical behavior, or production readiness |
| Health-claim source gate | clear; 1,273 files scanned | The current tracked source and documentation pass the repository's claim-pattern policy | Physiological accuracy, clinical validation, regulatory approval, or safe real-world outcomes |
| Legal inventory source gate | 230 runtime components and three container inputs verified | The repository's current license/inventory structure passes its source check | Counsel approval, commercial rights, supplier rights, certification, signing, or store approval |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: only synthetic test databases, archives, and
  simulator state were used; no user health database was mutated.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all supplier-band, BLE, Watch connectivity, background,
  battery, haptic, notification-delivery, and physiological validation.
- Step-count accuracy is not claimed: the exact production firmware still
  needs synchronized manual/video ground truth for stationary hand-motion
  false positives and representative walking conditions on both wrists.

## Git and release state

- Changed paths: the active branch contains Apple, Android, package,
  localization, project, release-metadata, and operations-record changes. The
  final reconciliation also hardens the bounded runner and its reviewed
  required-CI source digest.
- Documentation reconciled in this slice:
  `docs/FEATURE_PARITY.md`, `docs/FIRST_PRODUCTION_RELEASE_PLAN.md`,
  `docs/PLATFORM_ARCHITECTURE.md`, `docs/PRIVACY_SECURITY.md`,
  `docs/PRODUCTION_READINESS.md`, `docs/RELEASE_CONTROLS.md`,
  `docs/handoff/HARDWARE-AND-PREMIUM-STRATEGY.md`,
  `docs/handoff/RELEASE-BLOCKERS.md`, `docs/ops/ACTIVE.md`,
  `docs/ops/rounds/INDEX.md`, and this round record.
- Commits: local implementation commits through `431c4c60`, initial candidate
  `9d859d9a`, and hosted candidate `1505be75`; the managed-emulator disk-floor
  correction and exact final head are recorded by protected PR `#16`.
- Branch and remote state: pushed to protected PR `#16`. The initial candidate's
  remaining Apple, Android, and server workflows were canceled after a late
  independent audit found portability blockers; it was not merged.
- Repository visibility verified: private on 2026-09-19.
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

- Replacement hosted exact-SHA checks, protected integration, and the
  protected-main trusted result remain pending until the disk-floor correction
  is pushed and every required context passes.
- Managed-history code has resumable export/import and corruption rejection;
  live expiry, large-account, cancellation/auth-refresh, cross-tenant,
  low-storage, and physical process-death proof remain (`DAT-170`).
- Ownership deletion coordination and its restricted managed-data target are
  implemented default-off; provider identity cleanup, ownership control-plane
  final erasure, approved band retirement/quarantine/wipe, retention approval,
  and operator recovery remain (`ACC-340` plus external legal/operations
  decisions).
- The first-party band SDK/protocol, representative hardware, signing/store,
  legal, carrier, production-runtime, and physical accessibility/device gates
  remain release blockers outside this source-only review.
- Final-band step accuracy remains unproven. The current source correctly
  prefers phone/watch or device counts and labels motion-only output as an
  estimate, but seated hand-motion rejection must pass the supplier acceptance
  matrix before a measured-step claim.

## Next round

1. Commit once, run all ten hosted required checks on that exact SHA, and
   integrate normally only if every applicable gate is green; candidate SHA,
   pull request, hosted `10/10`, protected merge SHA, and protected-main trusted
   result remain pending until they exist.
2. Preserve `DAT-170`, `ACC-340`, database-encryption migration, and every
   physical, signing/store, legal,
   carrier, credential, production-runtime, and elapsed-soak gate until direct
   evidence closes it.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
