# Round: 2026-09-05 - First production release plan

## Status

- State: `planning audit completed; implementation and external gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `d3d05095`
- End implementation commit: `f49af635` plus the commit containing the editable
  checklist update
- Record commit or PR: the direct-to-`main` documentation commits requested by
  the owner

## Objective

Create one durable execution plan for NOOP's first public production release.
The plan must include a production-grade NOOP Band SDK, removal of unintended
third-party wearable terminology from the customer and core product surfaces,
the remaining Apple, Android, backend, operations, privacy, security,
measurement, hardware, signing, store, and launch gates, and explicit evidence
required to close each gate.

The first public build is a production release, not a customer-facing beta.
Private release-candidate validation remains mandatory evidence before
submission.

## Scope

### In scope

- Audit the existing device/protocol architecture and terminology footprint.
- Define the NOOP Band SDK boundary across firmware, protocol, mobile clients,
  storage, analytics, diagnostics, test tools, and future external consumers.
- Define a safe terminology migration that preserves data compatibility,
  truthful import provenance, required legal notices, and release evidence.
- Consolidate all remaining first-release work into ordered gates with owners,
  dependencies, evidence, exit criteria, and user-supplied prerequisites.
- Update the durable operations handoff and release-readiness references.

### Non-goals

- Implement or guess a protocol before production band firmware, GATT schema,
  security design, and sample hardware are available.
- Rename persisted identifiers or migrations destructively.
- Remove legally required attribution, truthful import/export provenance, or
  compatibility identifiers that remain necessary for supported legacy data.
- Enable production traffic, upload real health data, sign applications, or
  claim physical-device validation.

## Starting evidence

- Reproduction or observed symptom: the current product and architecture still
  contain extensive third-party wearable terminology, while forthcoming NOOP
  bands require a first-party protocol and SDK contract before hardware
  integration can be release-ready.
- Relevant source/device/OS/firmware class: current Apple and Android
  applications, shared Swift packages, Android protocol/storage layers,
  forthcoming NOOP band firmware and engineering samples, and optional NOOP+
  managed services.
- Existing tests, logs, exports, screenshots, or documents: current mainline
  release-readiness records, device-driver architecture, protocol and data
  model documentation, private synthetic managed pilot evidence, and current
  hosted CI.
- Unknowns that must remain unknown until measured: final band chipset,
  firmware ownership and update model, GATT services and characteristics,
  packet schema, cryptographic provisioning, flash-history behavior, clock
  accuracy, sensor cadence, power budget, haptic commands, bootloader/DFU
  contract, manufacturing test interface, regulatory identity, and physical
  performance.

## Delivered

- Added
  [`../../FIRST_PRODUCTION_RELEASE_PLAN.md`](../../FIRST_PRODUCTION_RELEASE_PLAN.md)
  as the canonical ordered plan for the first public production release.
- Added
  [`../../FIRST_PRODUCTION_RELEASE_CHECKLIST.md`](../../FIRST_PRODUCTION_RELEASE_CHECKLIST.md)
  as the day-to-day action ledger: 325 pending points across 15 dependency
  phases, stable insertion IDs, ownership labels, checkbox/evidence rules, and
  a copyable form for owner-added work.
- Defined the hardware/firmware input dossier that must exist before a
  production protocol is implemented: chipset, GATT, wire schema, security,
  sensors, calibration, history, clock, commands, power, OTA, manufacturing,
  regulatory identity, samples, and ownership.
- Defined neutral firmware, specification, simulator, conformance, Swift,
  Kotlin, storage, transport, product-adapter, and CLI boundaries for the
  first-party NOOP Band SDK.
- Required per-device identity, authenticated state-changing commands, offline
  flash collection, monotonic device time plus wall anchors, post-commit
  history acknowledgement, capability negotiation, signed firmware, and
  rollback/recovery.
- Defined bounded Apple/Android evidence for discovery, authentication, live
  progress, history completion/stall, clock, command, firmware update, storage,
  and responsiveness without logging identifiers, payloads, or health values.
- Audited the terminology surface: 15,451 matching tracked lines across 1,313
  files, including customer text, active core types, protocol adapters,
  persisted IDs, database paths/classes, backups, managed namespaces, imports,
  legal notices, fixtures, and historical records.
- Defined a zero-unallowlisted-match target rather than unsafe literal
  deletion. Customer/core terminology is removed; legal, provenance,
  migrations, fixtures, deliberate compatibility, and historical evidence are
  retained only through a reviewed machine-readable allowlist.
- Defined the additive migration order for a distinct first-party source
  identity, neutral modules, dual-read/new-write storage, database path moves,
  backup/export versions, managed namespaces, compatibility isolation, and
  rollback fixtures. The current false legacy-to-`Noop Band` display mapping is
  an explicit release blocker.
- Recorded 12 ordered execution phases covering current CI repair, scope and
  ownership, firmware, SDK, migration, mobile parity, storage/performance,
  metric evidence, optional NOOP+ productionization, security/privacy/legal,
  certification, manufacturing/support, signing/stores, private release
  candidates, go-live, and post-launch review.
- Recorded the complete physical validation matrix, final go/no-go gates, and
  secure owner-supplied prerequisites.
- Added durable decisions D-042 through D-044 and linked the plan from the
  active handoff, round index, production-readiness ledger, and prior blocker
  handoff.

## Data, privacy, and medical truth

- Schema or migration impact: documentation-only in this round. The plan will
  require additive migrations and compatibility aliases for future renames.
- Existing-data retention impact: none in this round.
- Source/provenance or formula impact: none in this round. The plan preserves
  truthful source labels and blocks unsupported sensor-derived claims.
- Permissions/network disclosure impact: none in this round.
- Health/medical claim impact and limitations: a first-party band does not
  validate physiology or medical claims; each signal still requires sensor and
  reference evidence.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: this planning
  round changes no runtime boundary. The resulting plan will require bounded
  lifecycle evidence for discovery, provisioning, connection, subscription,
  live collection, history drain, durable progress, clock sync, commands,
  firmware update, disconnect, retry, and terminal failure on Apple and Android.
- Why existing evidence is sufficient, or why new evidence is required:
  existing mobile diagnostic recorders provide the required privacy-safe
  facility, but NOOP Band-specific event categories cannot be finalized before
  the protocol lifecycle is defined.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`, server
  `RequestObservabilityMiddleware`, and `emit_operational_event`.
- New bounded events or operation spans: none in this documentation-only round.
- Redaction, retention, and high-frequency controls: the plan will prohibit
  addresses, serials, raw frames, sensor timestamps or values, firmware
  payloads, credentials, and arbitrary errors; counts and fixed categories
  must be throttled and bounded.
- Cross-platform/backend correlation: not applicable to this planning-only
  change.
- Remaining blind spots: every physical NOOP Band behavior until firmware
  specifications and engineering samples exist.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Repository and remote audit | `main` clean at `d3d05095`, equal to `origin/main` | Planning starts from the published source of truth | Release readiness |
| First-party architecture audit | No `firmware/`, first-party device protocol, provisioning, secure-boot/DFU, manufacturing-test, or NOOP Band SDK implementation exists | The plan starts from the actual hardware boundary and identifies reusable host foundations | Any behavior of forthcoming bands |
| Terminology audit | 15,451 matching tracked lines in 1,313 files; largest file counts are Android 509, packages 369, Apple app 144, and docs 101 | Removal is a compatibility migration, not a cosmetic replacement | Classification of every match; that is phase T4.2 |
| Persisted-identity audit | `my-whoop`, `OpenWhoop/whoop.sqlite`, `noop_whoop.db`, `WhoopDatabase`, protocol/store package names, backup and managed namespaces are active compatibility surfaces | Additive dual-read/new-write migration and rollback fixtures are required | A completed migration |
| Hosted CI audit at `d3d05095` | Swift packages/policy/localization/ops pass; Apple app workflow, Android managed-emulator workflow, and server workflow are red | Phase R1 starts from current hosted evidence | Signed or physical release behavior |
| Apple hosted details | App build passes; iOS production-shell test exits 65 | The Apple failure is after compile | Root cause or a fix |
| Android hosted details | APK, unit tests, and instrumentation compile pass; managed-emulator test is cancelled | The failure is the runtime instrumentation stage | OEM or physical-device behavior |
| Server hosted details | 272 pass, three fail, one skip because reused PostgreSQL state reports changed checksum for `001_init.sql` | Migration-fixture isolation is a current blocker | Production database health |
| Master plan and durable records | Added and cross-linked | Future rounds have one ordered source of truth with honest gates | Completion of any open implementation/external gate |
| Editable release checklist | 325 pending points across 15 ordered phases; stable IDs are unique | Release work can be inserted, completed, superseded, and evidenced without renumbering or losing history | Completion of any listed point |
| Operations record validation | `python3 Tools/validate-ops-rounds.py --all .` passed for 27 records | The new record and index satisfy the durable-ledger contract | Runtime behavior |
| Private-data and targeted secret checks | Filename guard, credential-pattern, personal-path, and email scans passed | The changed documentation does not contain detected private paths, emails, or credential-shaped values | Exhaustive secret scanning outside the changed documentation |
| Legal and distribution gates | Legal inventory verified for 213 runtime components and three container inputs; distribution provenance passed | This documentation did not break the current rights/notices contract | Trademark, store, hardware, or counsel approval |
| Health-claims gate | Passed across 1,175 scanned files | The plan does not introduce a prohibited product claim | Physiological accuracy |
| Localization audit | The first `--ci` invocation omitted its required base and was rejected before scanning; `--full` and `--ci origin/main` then passed with no new Apple/Android literal or customer-brand regression | Documentation changes do not regress current localization/customer-text gates | Native-speaker quality or removal of existing baselined literals |
| Relative-link and whitespace checks | Modified-document links, new-document trailing whitespace, and `git diff --check` passed | The documentation is internally linked and mechanically clean | Correctness of external websites |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: no runtime or device data changed.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all NOOP Band and existing wearable physical gates.

## Git and release state

- Changed paths: master release plan, this round record, round index, active
  handoff, durable decisions, production-readiness ledger, prior release
  blocker pointer, and editable release checklist.
- Commits: `f49af635` plus the commit containing the checklist update.
- Branch and remote state: `main` was clean and equal to `origin/main` at
  `d3d05095` before this documentation-only work; the completed record is
  published directly to the tracked `origin/main` as requested.
- Repository visibility verified: not repeated; current record states private.
- Version/build impact: none in this planning round.
- Release or distribution impact: none; no artifact or production service is
  changed.

## Decisions

- D-042: the first public release is production, with no customer-facing beta;
  private release-candidate evidence and manual release remain mandatory.
- D-043: a first-party band has a distinct identity and versioned
  firmware/protocol/SDK contract; existing third-party identities are never
  relabeled as proof.
- D-044: terminology migration targets zero unallowlisted customer/core
  references while preserving required legal, provenance, migration,
  compatibility, and historical truth additively.

## Open risks and honest limitations

- Band specifications and engineering samples are not yet available, so SDK
  implementation estimates remain conditional.
- A literal repository-wide trademark deletion would damage compatibility,
  provenance, migrations, tests, legal notices, and historical evidence.
- Current hosted `main` is red in three workflows and is not a release base.
- The first-party source identity, neutral storage/path migration, firmware,
  native SDK, manufacturing, certification, and physical validation all remain
  implementation or external work.
- NOOP+ remains private synthetic staging; the plan does not authorize public
  ingress or real health-data upload.

## Next round

1. Repair the three red hosted workflows and record the phase-zero owner
   decisions.
2. Build the terminology classifier/allowlist and correct the false
   legacy-to-first-party presentation.
3. Add neutral core boundaries, old-data fixtures, the protocol-spec template,
   native SDK interfaces, and deterministic virtual-band conformance harness
   before hardware arrives.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
