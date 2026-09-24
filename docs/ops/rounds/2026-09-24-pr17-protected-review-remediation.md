# Round: 2026-09-24 - PR 17 protected review remediation

## Status

- State: `active`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `1df3e367bc8fe7bd2a563eae38b7afdbde3c25ff`
- Record commit or PR: application pull request `#17`
- Supplier binaries: local and ignored only; absent from Git
- Physical-device claims: unchanged and unproven

## Objective

Audit every unresolved protected-review conversation on application PR `#17`,
correct each confirmed software or handoff defect, close stale or disproven
threads with exact evidence, rerun affected and release-level verification,
and merge normally only after the exact replacement head satisfies all branch
protections.

## Scope

### In scope

- Apple and Android supplier-adapter lifecycle, pairing, reconnect, freshness,
  registry, and artifact-verification findings raised against PR `#17`.
- Current Today metric-selection tests and durable decision consistency.
- Exact SDK revision and physical-validation handoff consistency.
- Focused regression tests, complete applicable local gates, exact-SHA hosted
  checks, protected merge, protected-main verification, and round-owned
  cleanup.

### Non-goals

- Commit or redistribute supplier binaries, firmware, credentials, signing
  material, private reference inputs, or personal or health data.
- Infer printed-label mappings, firmware compatibility, physical BLE behavior,
  background behavior, or sensor accuracy without approved hardware evidence.
- Enable the supplier source by default, remove WHOOP, bypass branch
  protection, or claim production readiness from source and simulator tests.

## Starting evidence

- Exact candidate `1df3e367bc8fe7bd2a563eae38b7afdbde3c25ff`
  passed all hosted checks: 33 success, 5 intentional skips, and 0 failures.
- Branch protection still blocked merge because conversation resolution is
  required and 25 review threads remained unresolved.
- Seven unresolved threads were already marked outdated. Eighteen remained on
  current lines, including exact-head findings about Apple shared-manager
  handoff, printed-label mapping, reconnect confirmation, Android artifact and
  identity persistence, and stale supplier heart-rate presentation.
- Supplier documentation identifies Apple `deviceAddress` as a device address,
  not a verified printed label, and requires app-managed confirmation policy
  when the app controls scanning and reconnect.

## Delivered

- Enabled the supplier adapter in the same iPhone app whenever the verified
  local device SDK is present; WHOOP remains available.
- Replaced the unavailable printed-label mapping with supplier on-band
  confirmation for first pairing while retaining exact comparison whenever a
  trusted mapping exists.
- Added bounded reconnect discovery, stale live-HR expiry, pairing-owner
  handoff, compensated registration/removal, and bounded lifecycle evidence.
- Pinned and verified the complete Android supplier AAR set and built the Full
  debug APK with the provider included.
- Pinned the Apple primary and companion frameworks, reproducibly built
  FMDB/MJExtension from the supplied SDK checkout, linked all static
  dependencies, and embedded all required dynamic frameworks.

## Data, privacy, and medical truth

- Schema or migration impact: none; this round changes adapter, registry,
  presentation, local build wiring, and tests only.
- Existing-data retention impact: none; supplier live heart rate remains
  display-only and is explicitly cleared when stale, stopped, disconnected, or
  failed.
- Source/provenance or formula impact: supplier live heart rate must remain
  display-only and freshness-bounded; no durable promotion is allowed.
- Permissions/network disclosure impact: supplier binaries remain ignored and
  local; no public traffic or live health-data transfer is enabled.
- Health/medical claim impact and limitations: no physical or physiological
  claim is added by this remediation.

## Observability

- Evidence that diagnoses success, rejection, and failure: retain bounded
  supplier lifecycle, adapter stage, outcome, and fixed failure categories.
- Why existing evidence is sufficient, or why new evidence is required:
  source and synthetic tests can prove lifecycle ordering and fail-closed
  behavior; physical callback ordering and identifier truth still require a
  signed-device round.
- Existing evidence reused: `band.supplier_adapter`,
  `band.supplier_lifecycle`, registry diagnostics, and exact review threads.
- New bounded events or operation spans: supplier registration/removal and
  adapter stages record fixed stage, outcome, trigger, failure-kind, and
  count-bucket fields only.
- Redaction, retention, and high-frequency controls: no addresses, printed
  identifiers, passwords, raw errors, health values, or per-sample logs.
- Cross-platform/backend correlation: not added; this local BLE lifecycle has
  no server operation and does not emit user, band, address, or sample values.
- Remaining blind spots: supplier callback behavior, exact printed-label
  mapping, background reconnect, hardware revisions, firmware, egress,
  battery, retention, haptics, and sensor accuracy.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-head hosted checks | 33 success, 5 intentional skips, 0 failures | Candidate compiles and passes the configured hosted surface | Review correctness, physical behavior, or protected merge |
| Protected review inventory | 25 unresolved: 7 outdated, 18 current-line | Conversation resolution is the remaining branch-protection class | Which findings are valid without code audit |
| Supplier Apple headers and API guide | `deviceAddress` is an address; self-managed reconnect must maintain `deviceShowConfirm` | The exact-head direct printed-ID comparison and reconnect default need review | The real printed-label mapping for supplied hardware |
| Supplier-enabled Android Full build | compile, unit test, and APK assembly passed with 7 verified AARs | Android supplier code and binaries compile/package together | Physical BLE behavior |
| Supplier-enabled generic iPhoneOS build | passed; app embeds ABParTool, FMDB, GRDFUSDK, JLDialUnit, MJExtension, and ZipZap | Apple supplier code and complete dependency bundle compile/link/package together | Signing, installation, or physical BLE behavior |
| Focused Apple supplier tests | 39 passed, 0 failed | Pairing, reconnect, freshness, registry, and presentation contracts | Vendor callback behavior on hardware |
| Operations-record validator | 91 records passed, including required branch round change | The replacement record is complete, indexed, and privacy-scanned | Hosted exact-SHA completion |
| Terminology audit | 18,121 classified occurrences across 1,614 groups; 0 forbidden mappings | Supplier compatibility changes preserve the terminology policy | Customer research or naming preference |
| Release-control matrix | 204 passed, 0 failed after exact generated-cache cleanup | Reviewed digests, SDK artifact integrity, workflow contracts, and trusted self-verification agree | Hosted exact-SHA completion |

## Resource cleanup

- No new long-lived service or public resource was created.
- Round-owned build products, temporary logs, and simulators remain pending
  exact deletion after replacement evidence and protected integration are
  durable.

## Physical device and deployment

- Install/update action: unsigned generic iPhoneOS app built; installation not
  run because no physical phone is attached.
- Generalized device and OS class: source, simulator, emulator, and hosted
  runner evidence only.
- Data-preservation result: registry registration and removal rollback are
  covered synthetically; physical install/update preservation is unrun.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: printed-label mapping, possession confirmation,
  password truth, connection/reconnect, background collection, history,
  battery, haptics, firmware, egress, and physiological accuracy.

## Git and release state

- Changed paths: supplier lifecycle/presentation, Apple local SDK wiring,
  Android artifact trust, focused tests, and operations records.
- Commits: `4ad0496e7ed0f0bcdc3a7f7a2aa3b6eac89d4637`.
- Branch and remote state: PR `#17` exact head
  `4ad0496e7ed0f0bcdc3a7f7a2aa3b6eac89d4637` is pushed and open. Exact-SHA
  hosted checks and protected review resolution remain before merge.
- Repository visibility verified: not changed by this round.
- Version/build impact: no version change; verified local supplier
  configuration now builds the same app target with the complete dependency
  bundle.
- Release or distribution impact: no supplier binary is committed or
  redistributed.

## Decisions

- Durable decision added or changed: none; existing source-only and
  local-artifact decisions remain in force.
- Decision-log entry: existing D-055, D-056, D-059, and D-061 remain
  authoritative unless a confirmed review finding requires an explicit update.

## Open risks and honest limitations

The current candidate is not merge-ready despite green builds. Review findings
must not be dismissed merely to satisfy conversation resolution. Supplier
identity mapping, physical BLE, signed-device behavior, redistribution rights,
firmware, background operation, and physiological accuracy remain unproven.

## Next round

1. Classify every unresolved thread against exact current code and tests.
2. Implement only confirmed software and handoff corrections with focused
   regressions.
3. Run affected platform suites, repository policy gates, and complete
   applicable local walls.
4. Push one replacement candidate, require all exact-SHA hosted contexts, and
   resolve each thread with evidence.
5. Merge normally, verify protected `main`, and delete exact round-owned
   resources after checking active handles.

## Privacy check

- [x] No credentials, personal names, email addresses, raw health exports,
      band identifiers, Bluetooth addresses, signing identities, supplier
      binaries, or absolute private supplier paths are present in this record.
