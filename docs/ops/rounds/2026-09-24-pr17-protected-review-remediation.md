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

## iOS supplier trust-root follow-up

- State: `completed locally; no push authorized`
- Isolated branch:
  `codex/pr17-apple-supplier-runtime-review-20260924`
- Exact base:
  `60df38a2ad3e1a825198909336e75c415459b310`
- Confirmed findings: generated FMDB and MJExtension device frameworks are
  accepted without reviewed hashes or inventories, and the iOS supplier
  verifier, embed script, and verifier tests are absent from the owner-only
  protected-path set.
- Write scope: iOS supplier local tools, their focused Python tests, tracked
  supplier trust data/configuration, and this existing operations handoff
  only. App runtime source is excluded.
- External boundary: the supplier SDK, Pods checkout, and generated frameworks
  remain owner-supplied local inputs outside Git. This follow-up may bind an
  exact reviewed snapshot but cannot establish redistribution rights,
  provenance beyond that snapshot, signing, or physical-device behavior.
- Delivered: a tracked strict iOS trust manifest pins the exact Podfile,
  lockfile, complete Pods tree, and complete generated FMDB and MJExtension
  framework inventories and executable hashes. The verifier rejects path,
  digest, inventory, symlink, metadata, or architecture drift before config
  generation and again immediately before embedding.
- Owner-only authority: the iOS manifest, tracked example config, configure
  script, embed script, and focused verifier test are protected release-control
  paths. The reviewed digest for the protected-path verifier is repinned in the
  required-CI gate.
- Focused evidence: 29/29 tests passed in
  `Tools.tests.test_veepoo_ios_sdk_wiring` and
  `Tools.tests.test_trusted_release_controls`; the direct local verifier
  matched the reviewed iPhoneOS arm64 bundle; Python compilation, shell syntax,
  scoped diff hygiene, and all 91 operations records passed.
- Concurrency note: unrelated Apple runtime and XCTest edits appeared during
  the round. They were neither inspected nor staged and are excluded from this
  follow-up commit.
- Observability decision: no runtime boundary changed. The local verifier
  emits bounded categorical failures without artifact contents, credentials,
  device identifiers, or health data; no app diagnostic event is warranted.

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

## Isolated failOperation review follow-up

- Branch: `codex/pr17-sdk-fail-operation-20260924`
- Start commit: `60df38a2ad3e1a825198909336e75c415459b310`
- Scope: the vendored Swift and Kotlin `failOperation` category-order finding
  only; no supplier adapter, app behavior, deployment, or physical claim.
- Source audit: both pinned production state machines already validate the
  operation-specific failure allowlist before any operation state transition.
  Existing authentication and security branches already invalidate the
  authenticated generation, clear the active operation and live state, and
  emit bounded terminal evidence.
- Regression result: app-owned Swift and Kotlin tests prove rejected
  non-operation categories preserve the exact active operation and generation,
  operation-specific history storage failure remains valid, and active live
  authentication/security failures terminate in the required order.
- Focused Swift command: bounded `swift test` with an external scratch path and
  filters for the two new `NoopBandSDKArtifactTests`; 2 passed, 0 failed.
- Focused Kotlin command: bounded single-worker
  `:app:testFullDebugUnitTest` with the two new
  `NoopBandSdkIntegrationTest` selectors; 2 passed, 0 failed.
- Production source change: none. The exact pinned Swift and Kotlin state
  machines already contained the required pre-mutation whitelist and terminal
  authentication/security behavior; this follow-up adds direct app-side
  regression coverage without altering the vendored source revision.
- Broader verification: intentionally not run under the urgent narrow-test
  instruction. No push, deployment, supplier binary, or physical-device action
  occurred.

## Integrated replacement checkpoint

- Integrated local commits: `f7ac75205`, `b490e2969`, `0ff3afeff`, and
  `bdcca95aa`, plus the reviewed-source digest, terminology, and Swift
  isolation corrections in the final working tree.
- Apple runtime: supplier terminal live failure/stoppage clears display state,
  supplier mode hides WHOOP-only controls, and onboarding accepts only a
  supplier registration with an available adapter, valid peripheral UUID, and
  valid stored credential.
- Android runtime: supplier removal cannot activate an import-only source,
  display HR expires within the bounded freshness interval, and WHOOP 5.0/MG
  remains reachable beside WHOOP 4.0 and the supplier band.
- SDK parity: Swift and Kotlin reject non-operation failure categories before
  mutation and preserve the existing ordered authentication/security terminal
  behavior.
- Artifact trust: generated FMDB and MJExtension device frameworks, their
  approved build inputs, and the complete iOS supplier script/test surface are
  protected by reviewed hashes and inventories.
- Focused verification: iOS trust tests pass 29/29; Swift SDK filtering
  executes 3/3; Android supplier/runtime filtering passes 5/5 after verifying
  seven exact AARs; Apple app-target filtering passes 4/4.
- Build verification: the generic unsigned iPhoneOS build succeeds without the
  new Swift isolation warnings and embeds ABParTool, FMDB, GRDFUSDK,
  JLDialUnit, MJExtension, and ZipZap. Android `assembleFullDebug` succeeds
  after the exact supplier verifier passes.
- Repository verification: source release control passes 9 checks; the exact
  hosted release unit matrix passes 204/204; required CI validates ten
  contexts; calibration parity reports 12 metrics, 3 revisions, 13 thresholds,
  and 16 guards; terminology records 18,138 occurrences across 1,616 groups
  with zero forbidden mappings; distribution provenance, private-data, diff,
  and all 91 operations-record gates pass.
- Test artifacts:
  - Android Full debug APK:
    `~/Downloads/NOOP-band-test-2026-09-24/NOOP-Android-supplier-debug.apk`
    with SHA-256
    `161317662b8054343243a192c8e4813d263865ea5d3be9b2b7b2a9ed16ed2b62`.
  - Unsigned iPhoneOS app ZIP:
    `~/Downloads/NOOP-band-test-2026-09-24/NOOP-iPhone-supplier-unsigned-app.zip`
    with SHA-256
    `c88dac96161005123c2e5d8c6582feb4ed95d5f5eb05865b2e1ebb63510abc5b`.
- Remaining protected work: commit and push one replacement candidate, reply
  to and resolve the eight confirmed review threads with exact evidence, wait
  for all exact-SHA hosted contexts, merge normally, verify protected `main`,
  and remove only round-owned generated output after checking open handles.
- Remaining external evidence: Apple signing/install, physical supplier and
  WHOOP pairing, reconnect/background collection, history retention, battery,
  haptics, firmware, egress, and physiological accuracy.

## Debug qualification compatibility checkpoint

- State: `locally verified; replacement push pending`
- The supplier documents its `deviceNumber` callback as product metadata, not
  the identifier printed on an individual band. Android therefore no longer
  asks the user to compare that callback with the printed label. Apple retains
  printed-label comparison only when discovery supplies a trusted mapping;
  otherwise both platforms rely on explicit candidate selection and the
  supplier's on-band pairing confirmation.
- A shared, protected compatibility manifest now binds platform, model code,
  hardware revision, firmware revision, protocol revision, and wrapper
  revision. It is embedded byte-for-byte in both apps, rejects malformed,
  wildcard, placeholder, oversized, and duplicate entries, and is empty by
  default.
- Normal builds fail closed when the exact product tuple is absent. A verified
  local supplier configuration enables unlisted qualification only in Debug
  physical-device builds. Apple Release/install actions are blocked, Android
  requires both a Debug build and the locally verified supplier flavor, and
  qualification turns off for a platform as soon as that platform has an
  approved manifest row.
- WHOOP remains available in the same Full/iPhone app. Supplier live heart rate
  remains display-only and cannot enter durable history, recovery, sleep,
  Effort, or other derived metrics.
- Focused Apple compatibility and adapter tests passed 34/34. Focused Android
  supplier lifecycle, source-coordinator, and vendor-bridge tests passed with
  all seven exact AARs verified. The shared manifest, iOS artifact wiring, and
  trusted release controls passed 34/34 Python tests.
- The complete repository Tools wall passed 360 tests with one intentional
  skip after the protected terminology snapshot was reviewed and repinned.
  Terminology now records 18,145 classified occurrences across 1,616 groups
  with zero forbidden mappings. Required CI validates all ten contexts, all 91
  operations records validate, and protected-main self-verification passes.
- The unsigned Debug iPhoneOS build passed with the exact supplier bundle and
  embedded ABParTool, FMDB, GRDFUSDK, JLDialUnit, MJExtension, and ZipZap
  frameworks. The Android Full Debug APK passed assembly and contains the
  protected compatibility manifest plus supplier native libraries for all
  packaged ABIs.
- Current test artifacts:
  - Android Full Debug APK:
    `~/Downloads/NOOP-band-test-2026-09-24-qualification/NOOP-Android-supplier-debug.apk`
    with SHA-256
    `354ea1c6a879885d92feee4fdfda0b4c0497ac3fb0826131047d7e0c472356a3`.
  - Unsigned iPhoneOS app ZIP:
    `~/Downloads/NOOP-band-test-2026-09-24-qualification/NOOP-iPhone-supplier-unsigned-app.zip`
    with SHA-256
    `dc9216033fef7834b66e37da3612ef70836efdfa61896fc7aa2950a2af291f63`.
- These artifacts prove compilation and packaging only. Signing/install,
  candidate identity truth, on-band confirmation, live data, reconnect,
  background behavior, history, battery, haptics, firmware compatibility, and
  sensor accuracy remain physical-device gates.

## Privacy check

- [x] No credentials, personal names, email addresses, raw health exports,
      band identifiers, Bluetooth addresses, signing identities, supplier
      binaries, or absolute private supplier paths are present in this record.
