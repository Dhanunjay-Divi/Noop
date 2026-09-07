# Round: 2026-09-07 - Production readiness execution

## Status

- State: `in progress`
- Owner: project team
- Branch: `main`
- Start commit: `52a84649c33c57b091c110e2b2912d2021ce7ffb`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Complete every supplier-independent production-readiness action that can be
implemented and honestly verified in the current environment. Re-audit
calibration, metric truth, storage, performance, Apple/Android behavior,
backend/cloud operation, security, release controls, and resource cleanup from
current source; fix defects found; and leave only gates that require supplier
contracts, first-party hardware, physical-device evidence, participants,
external approval, signing authority, or elapsed production operation.

## Scope

### In scope

- Reconcile all pending engineering checklist actions against current source
  and evidence.
- Run fresh calibration, causality, missing-data, longitudinal-stability,
  provenance, and cross-platform metric checks.
- Exercise long-history storage, migration, backup, restore, export, and
  performance tooling that does not require personal health data.
- Rebuild and test Apple, Android, server, Swift packages, study tools,
  repository policy, and private synthetic staging.
- Implement and verify supplier-independent defects and missing controls.
- Review observability at every changed user-visible or operational boundary.
- Remove temporary resources created by this round.

### Non-goals

- Do not invent first-party firmware, protocol bytes, sensor calibration, or
  possession proof before the supplier dossier exists.
- Do not claim physiological accuracy, physical background reliability,
  battery life, haptics, carrier delivery, signed distribution, legal approval,
  certification, manufacturing readiness, or store acceptance without their
  required evidence.
- Do not enable public ingress, production traffic, real paging, payment, or
  real health-data transfer.

## Starting evidence

- Reproduction or observed symptom: the owner requested complete end-to-end
  execution with a fresh review of calibration and all currently executable
  work.
- Relevant source/device/OS/firmware class: Apple and Android apps, shared
  Swift/Kotlin analytics and storage, FastAPI/PostgreSQL services, guarded GCP
  staging, release tooling, and the future first-party band boundary.
- Existing tests, logs, exports, screenshots, or documents: clean synchronized
  `main` at the start commit; 396 stable checklist actions with 44 evidenced
  complete and 352 pending. Prior rounds report green source matrices and
  private synthetic staging but no first-party firmware, production band,
  signed physical-client, participant, carrier, legal, certification, or
  storefront evidence.
- Unknowns that must remain unknown until measured: supplier protocol and
  firmware behavior; production sensor calibration; physical BLE/background,
  battery, haptic, OTA, and storage behavior; population metric accuracy;
  carrier delivery; legal/certification/store outcomes.

## Delivered

- Added matched provenance-gated official-reference comparison and
  holdout-validated personal presentation calibration on Apple and Android.
  The UI deliberately exposes only Charge, Effort, and Rest for calibration;
  the engine supports nine additional raw/direct metric comparisons without
  misrepresenting them as independently recomputed score families.
- Made calibration persistence fail closed on both platforms and bound every
  stored model to its metric, scoring revision, chronological holdout evidence,
  untouched raw estimate, and separately labeled calibrated estimate.
- Added a machine-readable 12-metric calibration contract and a release gate
  that rejects Apple/Android drift in series keys, ranges, revisions,
  thresholds, chronological holdout, duplicate rejection, RMSE non-regression,
  calibrated-output exclusion, and source-namespace separation.
- Made official-import provenance manifests transaction-aware: stale evidence
  is invalidated before replacement and a successful manifest is written only
  after the data transaction commits.
- Reconciled Apple and Android computed scores atomically across daily and
  metric-series surfaces, including forced late-failure rollback and a
  1,200-day case that avoids SQLite variable-bind limits. Both clients reject
  malformed dates, duplicate ownership, invalid managed keys, non-finite
  values, and out-of-window rows before mutating either store.
- Kept Apple analysis retryable after persistence failure: the idle-analysis
  watermark now advances only when score publication, active-minute
  publication, and repair all succeed. Bounded diagnostics retain only a fixed
  failure category rather than database error text.
- Added bounded generic metric reads and rejected non-finite and legacy
  sleep-efficiency-unit values rather than letting invalid rows reach UI or
  calibration.
- Added a deterministic long-history harness for 10, 30, 90, and 365 days,
  exact retained-content backup/restore verification, storage attribution,
  WAL, export, and bounded read timing.
- Defined fail-closed metric reprocessing and rollback, complete key lifecycle
  ownership, and coordinated vulnerability/security-update handling; made all
  four policy documents required release inputs without claiming that
  production keys, staffed intake, firmware, or response drills exist.
- Replaced false first-party labels on compatibility hardware with
  `Compatible band`, added a complete classified terminology inventory and
  machine-readable active-use ratchet, and wired the ratchet into release CI.
- Normalized stable hosted check names so protected-main required checks can be
  configured against durable contexts.
- Verified and closed three matched mobile behavior contracts: automatic
  history recovery expands for three seconds over cached content before
  compacting without blocking the app; each month-calendar metric opens its
  own category-scoped day overview; and reselecting the active bottom tab
  returns nested metric/calendar routes to that tab's root.
- Passed the staged release-control, health-claims, localization, runtime
  license, distribution-rights, private-data, operations-record, workflow
  syntax, and exact-diff whitespace gates.
- Reverified retained private GCP staging: OpenTofu format, validation, all
  three configuration tests, IAM-only runtime checks, and detailed live plan
  exit `0` pass with no drift.
- Removed every generated local resource created or reused for this round from
  the workspace: the isolated Python environment, Android build/cache output,
  all Swift package build directories, custom Xcode DerivedData, OpenTofu
  provider cache, Python bytecode caches, and temporary reports/plans. More
  than 20 GB was moved to macOS Trash through the explicit-path system utility;
  the user's unrelated Trash was not emptied. No Gradle daemon, Android
  emulator, or booted Apple simulator remains.

## Data, privacy, and medical truth

- Schema or migration impact: no production schema migration was added. Apple
  and Android score reconciliation changes transaction semantics only; the
  long-history harness uses production APIs against disposable synthetic
  databases.
- Existing-data retention impact: no new destructive migration is authorized.
  The measured candidate keeps seven days of high-rate raw detail, 30 days of
  essential time series, and full compact/user-authored history. Managed
  pruning remains conditional on exact server validation of an unchanged,
  complete window.
- Source/provenance or formula impact: Charge, Effort, and Rest raw formulas
  are unchanged. Personal calibration is presentation-only, chronological,
  revision-bound, and accepted only on unseen holdout improvement. Imported
  official outcomes never enter the raw formulas.
- Permissions/network disclosure impact: no public or production network
  boundary is enabled by this round.
- Health/medical claim impact and limitations: wellness outputs remain
  non-medical; unvalidated inputs and claims remain unavailable.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  bounded app diagnostics, server request/operation events, deterministic test
  results, migration manifests, performance summaries, and private staging
  checks.
- Why existing evidence is sufficient, or why new evidence is required:
  source-only changes reuse established evidence where it answers the exact
  boundary; new persistence, long-running, transport, or network boundaries
  require bounded lifecycle evidence in the same change.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`, server
  request middleware and operational events, release manifests, and operations
  records.
- New bounded events or operation spans: Apple and Android comparison work
  records a fixed metric category, duration, paired-day count, calibration
  decision, persistence outcome, and bounded failure kind. Import replacement
  records only invalidate/stamp phase, result, and range count. Apple score and
  active-minute persistence failures expose only the bounded failure kind and
  deliberately clear the analysis watermark so the next idle pass retries.
- Redaction, retention, and high-frequency controls: no raw health values,
  sensor rows, user text, credentials, identifiers, dynamic URLs, payloads, or
  arbitrary errors enter diagnostics.
- Cross-platform/backend correlation: static operation/route categories and
  server-generated request IDs only.
- Remaining blind spots: physical hardware and every external gate listed
  above.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Starting Git and release-ledger audit | Clean synchronized `main`; 44 complete and 352 pending actions | Exact source and planning baseline | Production readiness |
| Swift package matrix | Nine package build/test lanes green; StudyHarness 12 tests and HistoryHarness 2 tests green | Shared analytics, storage, import, design, remote-sync, study, and history source behavior | Physical app behavior |
| Calibration parity gate | 12 metrics, 3 revisions, 13 thresholds, and 16 critical guards match on Apple and Android; 15 audit/release-gate tests pass | Machine-enforced cross-platform calibration contract and fail-closed drift detection | Physiological accuracy on production hardware |
| macOS application suite | 1,652 tests completed with one external-fixture skip and 0 failures | Current application source and backup/calibration contracts on macOS | Signing, notarization, or phone behavior |
| iOS simulator application suite | 34 UI tests completed with one private-pilot skip and 0 failures | Current production shell, navigation, onboarding, settings, calendar, body-map, updates, and scroll behavior on the simulator | Physical iPhone, signing, background radio, thermal, or battery behavior |
| Android source gate | Full debug assemble, unit, lint, and instrumentation compile succeeded in 6m 07s | Current Android source, resources, and lint contract | Physical OEM/background/BLE behavior |
| Android API 35 managed device | 53 selected tests completed with 2 private-pilot skips and 0 failures | Production-shell, persistence, rollback, navigation, and emulator behavior | Physical phone, radio, battery, or attestation |
| Server Python 3.12 | Ruff and runtime/dev dependency audits green; 296 passed and 63 environment-gated skips | Source behavior and dependency policy in the isolated local environment | Container, PostgreSQL, public topology, or production operations |
| GCP private staging plan | OpenTofu format, validate, three tests, and live plan green with zero drift | Retained IAM-only synthetic staging matches source | Public or production deployment |
| GCP private runtime verifier | Passed internal ingress, no broad invoker, digest pin, scale bounds, PITR, and deletion-protection checks | Current private synthetic runtime keeps its intended infrastructure controls | Application correctness, public topology, or real-data operation |
| Long-history synthetic matrix | All 10/30/90/365-day scenarios passed integrity and exact restore; report in `validation/HISTORY-HARNESS-2026-09-07.json` | Current host storage shape and exact retained-content recovery | Phone memory, thermal, battery, background, BLE, or population accuracy |
| Staged repository policy matrix | Release controls 9/9; release-policy tests 25/25; health-claims 1,191 files clear; i18n audit and 49 tests pass; legal inventory 213 runtime plus 3 container inputs and 9 tests pass; private-data and all 36 operations records pass; 11 workflows parse | The exact staged source satisfies repository release, privacy, claims, localization, legal, and operations contracts | Hosted execution or store approval |
| Scoped local cleanup | Generated Python, Android, Swift, Xcode, OpenTofu, bytecode, and temporary artifacts absent; no Gradle daemon, emulator, or booted simulator; only the pre-existing PostgreSQL listener remains on the audited ports | This round left no active local app/test runtime or generated workspace cache | Reclaimed disk until macOS Trash is emptied, or removal of intentionally retained private staging |

## Physical device and deployment

- Install/update action: Android managed-device test installation only; no
  physical-device update was claimed.
- Generalized device and OS class: API 35 managed Pixel-class emulator and
  current Apple simulators/host.
- Data-preservation result: synthetic exact restore passed; signed
  physical-device upgrade preservation remains open.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all first-party band and production physical-device
  gates until corresponding hardware exists.

## Git and release state

- Changed paths: calibration, import provenance, Apple and Android score
  reconciliation and validity, Apple analysis retry semantics,
  comparison/export UI, compatibility labels, long-history tooling,
  localization, metric rollback, key/security operations, release
  workflows/policy, validation evidence, and release documentation.
- Commits: pending.
- Branch and remote state: clean synchronized `main` at round start; the exact
  candidate is staged locally and passes all current local release gates.
- Repository visibility verified: inherited from current release evidence.
- Version/build impact: none at round start.
- Release or distribution impact: none at round start.

## Decisions

- Durable decision added or changed: none at round start.
- Decision-log entry: pending only if implementation changes a durable product
  boundary.

## Open risks and honest limitations

- A complete source pass cannot close supplier, physical, participant,
  regulatory, carrier, signing, store, or elapsed production-operation gates.
- Review Sample Mode remains open: Android has a separate demo application and
  Apple has a debug-only fixture, but neither proves a disclosed production
  review path isolated from the released app's BLE, storage, health, cloud,
  Friends, notification, and Safety boundaries.
- Seven-day raw and 30-day essential managed retention remains a measured,
  implemented candidate rather than the final owner-approved all-class policy.
- The measured retained 365-day database is about 444 MB and exact
  backup/restore temporarily reaches about 1.33 GB. Indexed host reads are fast,
  but only representative phones can establish launch, scroll, memory,
  thermal, background-collection, and low-storage budgets.

## Next round

1. Continue from the first remaining dependency after this execution round
   closes.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
