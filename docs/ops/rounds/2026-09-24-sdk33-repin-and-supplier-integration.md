# Round: 2026-09-24 - SDK 33 repin and supplier integration

## Status

- State: `local verification complete; exact-SHA hosted checks and protected merge pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `5978bda7760d6f8378d0c5439ab1788f8e0aa24e`
- End implementation commit:
  `ddb0315f76d7551916ef8b6bf54de5a2a5653d07`
- Record commit or PR: application pull request `#17`; the closeout record is
  carried by the documentation commit immediately after the implementation
  commit
- Supplier binaries: local and ignored only; absent from Git
- Physical-device claims: unchanged and unproven

## Objective

Consume the reviewed `NoopBandSDK` PR `#33` merge, close the remaining
application review contradictions, integrate optional/default-off Apple and
Android supplier-band adapters, and preserve WHOOP as an independent default
test transport until physical supplier validation passes.

## Scope

### In scope

- Repin the app-owned neutral boundary to the reviewed `NoopBandSDK` PR `#33`
  source export.
- Integrate the optional Apple and Android supplier adapters, local-only build
  wiring, Android provider, lifecycle corrections, and source-aware first-run
  setup.
- Preserve ordinary WHOOP and Demo builds when supplier-local configuration is
  absent.
- Record exact source, focused test, build, privacy, and release state without
  converting slice evidence into a combined-candidate or physical-device
  claim.

### Non-goals

- Commit or redistribute supplier binaries, firmware, credentials, signing
  material, private demo source, or private filesystem paths.
- Enable the supplier source by default or replace WHOOP as the comparison
  transport.
- Claim ownership, possession, physical pairing, background behavior, history
  retention, battery accuracy, haptics, firmware, physiological accuracy, or
  production readiness.
- Push, deploy, sign, distribute, or merge without the remaining combined and
  protected checks.

## Starting evidence

- The round started from application head
  `5978bda7760d6f8378d0c5439ab1788f8e0aa24e`.
- `NoopBandSDK` PR `#33` had merged normally at
  `b02808372b7c537f22058c7ebc75d92c750373be`.
- Two independent source-only exports were byte-identical, and the checked-in
  ten-file manifest SHA-256 was
  `6beca829f3b2a367cf7046544e8d06dc74ae9f905e1eefe4bb58ccf41615fd34`.
- Supplier adapter, local wiring, provider, lifecycle, and onboarding work
  arrived through isolated rounds with their own bounded evidence.
- No supplier binary, firmware, physical phone, or band result was available
  as checked-in evidence. Those facts had to remain unproven.

## Delivered

- SDK PR `#33` merged normally at
  `b02808372b7c537f22058c7ebc75d92c750373be`.
- Two clean source exports are byte-identical. The ten-file manifest SHA-256 is
  `6beca829f3b2a367cf7046544e8d06dc74ae9f905e1eefe4bb58ccf41615fd34`.
- The app-owned Swift/Kotlin boundaries and adversarial verifier are pinned to
  that exact revision and manifest.
- D-061 supersedes D-012: Today shows selected three-to-five metrics while the
  explicit all-history/Explore action keeps the full catalog reachable.
- Isolated Apple and Android supplier-integration commits are ready for review.
  They are optional/default-off, retain explicit candidate selection and
  printed-ID verification, read battery before live HR, and keep
  phone-receipt-time supplier HR display-only.
- Android supplier lifecycle consistency is integrated through
  `2f30a3a2f` and the reviewed removal correction `43cadcc37`. Credential
  persistence is compensated when verified registration fails; unavailable
  and rejected supplier sources durably reconcile to the transport actually
  running; active removal stops the source, clears its credential, archives
  the row, and promotes the fallback in one transaction.
- The Android provider is confined to the supplier-enabled Full source set.
  Ordinary Full and Demo graphs exclude its source, manifest, external
  modules, and supplier lock when the ignored local configuration is absent.
- Source-aware first-run setup is integrated through `6ce43f0fe`. Apple and
  Android now use the shared add-device wizard, preserve WHOOP as the default,
  and fail closed on invalid or unavailable registry state.
- Android supplier Live copy now uses the translated app-wide catalog rather
  than local English literals. The final source-graph verifier matches the
  supplier-only manifest and test source sets, and the Apple Live
  presentation contract follows the current displayed-heart-rate freshness
  boundary.
- The reviewed terminology ratchet now records 18,089 classified occurrences
  across 1,613 path/category groups with zero forbidden mappings. Its two
  generated files are repinned by the protected required-CI gate.
- The final current-head verification covers the complete default-off Apple
  and Android app graphs, all repository policy tests, a fresh synthetic
  PostgreSQL server wall, and the unchanged GCP plan-only contracts. No
  supplier binary, credential, public traffic, live health-data transfer, or
  physical-device result was introduced.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: supplier transport credentials use the
  existing platform-secure stores only after the recorded pairing boundary;
  no durable health-history migration was added.
- Source/provenance or formula impact: supplier live heart rate remains
  phone-receipt display data and is not promoted into durable samples or
  formulas.
- Permissions/network disclosure impact: no supplier binary is tracked. The
  Android supplier-only manifest adds its non-exported service and removes
  legacy external-storage permissions; supplier runtime egress remains
  unverified.
- Health/medical claim impact and limitations: source tests and builds do not
  validate battery, wear state, live heart rate, physiology, or medical use.

## Observability

- Evidence that diagnoses success, rejection, and failure: the neutral SDK and
  app adapters use fixed lifecycle, outcome, trigger, and failure categories.
- Why existing evidence is sufficient, or why new evidence is required:
  existing app diagnostics cover the supplier lifecycle; physical callback and
  background behavior remain opaque until device validation.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder` plus
  neutral SDK diagnostics.
- New bounded events or operation spans: the isolated adapter rounds record
  fixed `band.supplier_adapter`, `band.supplier_lifecycle`,
  `onboarding.device_setup`, and `device.registration` outcomes.
- Redaction, retention, and high-frequency controls: device addresses, printed
  IDs, passwords, names, RSSI, raw errors, frames, timestamps, health values,
  and persistent identifiers are excluded. High-rate heart-rate callbacks do
  not emit per-sample diagnostics.
- Cross-platform/backend correlation: no backend correlation is added; both
  mobile adapters retain the same neutral lifecycle meaning.
- Remaining blind spots: physical callback ordering, background operation,
  firmware behavior, egress, battery semantics, and sensor accuracy.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Upstream SDK exact merge | Swift 106/106; Kotlin/JVM 114/114 plus `installDist`; conformance 50/50; repository gate 74 files | The reviewed neutral source passed its upstream automated surface | App integration or physical behavior |
| Dual source export and app artifact verifier | Exports byte-identical; direct verifier and 9 adversarial cases passed | The checked-in source matches the reviewed source-only artifact and rejects tampering, symlinks, gitlinks, and supplier binaries | Supplier runtime behavior |
| Vendored Swift SDK package | 16/16 passed | The exact vendored neutral Swift package passes its app-side artifact tests | App-target or device behavior |
| Android supplier lifecycle receiving suite | 59/59 focused FullDebug JVM tests passed | Adoption, fallback reconciliation, removal compensation, credentials, diagnostics, and analysis gates pass in the focused graph | Optional provider binary or physical BLE behavior |
| Android concrete supplier provider receiving graph | Exact seven ignored AARs verified; Full app compiled; `VeepooVendorBridgeTest` 7/7 passed; bounded run reported `BUILD SUCCESSFUL in 2m 19s` | The quarantined provider compiles against the reviewed local dependency graph and its focused lifecycle tests pass | Release assembly, emulator, or hardware behavior |
| Android default-off receiving graph | Full and Demo compiled and each passed 59/59 focused tests; `BUILD SUCCESSFUL in 2m 23s` | Ordinary WHOOP and Demo graphs exclude provider source, manifest, external modules, and supplier lock | Complete Android wall |
| Source-aware first-run slice | Android Full compile/focused tests passed in 1m12s; focused macOS XCTest 22/22; unsigned iOS Simulator graph passed with Watch/widget; i18n audit passed | The isolated onboarding slice compiles and its focused contracts pass | A post-integration combined wall or physical pairing |
| `python3 Tools/validate-ops-rounds.py --all .` | Pass: 90 round records validated | Required headings, operations-doc privacy checks, and all index links pass on the documentation-repair tree | Product compilation or runtime behavior |
| `git diff --check` | Pass | The documentation repair has no whitespace errors | Product behavior |
| Complete Android default-off wall | Full and Demo each executed 5,031 tests with 7 intentional skips and 0 failures; compile, lint, APK assembly, and instrumentation-source compilation passed across 137 tasks | Ordinary WHOOP and Demo graphs remain coherent with the supplier source absent; shared UI, localization, persistence, and transport contracts compile and pass together | API 35 execution, physical GATT, background collection, haptics, battery, or supplier behavior |
| Final Android Live localization rerun | Full and Demo Kotlin compilation plus the localization/UI-audit selectors passed serially | The final translated supplier Live surface compiles in both ordinary variants without the earlier concurrent compiler-memory artifact | Physical locale switching or TalkBack |
| Complete macOS app wall | 2,248 tests executed, 1 intentional Xiaomi-fixture skip, 0 failures | Shared Apple app, UI, account/cloud, analytics, storage, accessibility-contract, and supplier-default-off source pass together | Signed distribution, physical accessibility, BLE, or live service access |
| Unsigned Apple product graph | iPhone app, widget, Watch app, and Watch complication build succeeded with 0 compiler warnings and 0 errors | All Apple launch products and shared source compile together from the final implementation tree | Signing, App Store review, Watch connectivity, notifications, or background suspension |
| Focused Apple supplier contract | 11/11 passed; the corrected Live freshness contract also passed before the complete wall | Default-off supplier lifecycle and displayed-HR presentation contracts remain covered | Physical callbacks, battery semantics, sensor accuracy, or firmware |
| Repository policy/tool wall | 348 tests passed with 1 intentional skip; direct release controls 9/9; 10 required contexts; trusted self-verification; calibration 12 metrics/3 revisions/13 thresholds/16 guards; distribution, privacy, claims, terminology, SDK artifact, i18n delta, operations, and diff gates passed | The final local source satisfies repository release, privacy, health-claim, localization, terminology, calibration, provenance, and trust contracts | Hosted exact-SHA enforcement, physical localization, or external approvals |
| Exact SDK artifact verifier | 10 source files verified at upstream revision `b02808372b7c537f22058c7ebc75d92c750373be`; supplier artifacts absent | The checked-in neutral boundary is the approved source-only export and contains no supplier payload | Supplier redistribution rights, local ignored binaries, or runtime behavior |
| Fresh synthetic PostgreSQL server wall | 816 tests collected; 815 passed, 1 explicitly opt-in provider skip, 0 failures; Ruff, format, and dependency checks passed | Current account, managed-history, Friends, Safety, formula, migration, retention, deletion, retry, and isolation contracts pass against two extension-free disposable databases | Production Cloud SQL, load, provider delivery, real identities/data, or elapsed operations |
| GCP plan-only wall | Formatting and validation passed; 20 OpenTofu tests passed, 0 failed | Default-off ownership, feedback lifecycle, pinned database credentials, and workload separation remain coherent without apply | Deployed IAM/secrets, drift, public traffic, or production runtime behavior |

## Resource cleanup

- The completed Android provider worker was closed after its commit was
  reviewed, cherry-picked, and reverified.
- Its clean 418 MiB worktree and round-owned build output were removed. The
  integrated source, focused test results, and this durable record remain.
- Six obsolete, handle-free Apple DerivedData directories from earlier
  receiving rounds were exact-deleted after evidence capture, reclaiming about
  22 GiB and raising Data-volume headroom from 41 GiB to 63 GiB.
- The final server wall used two extension-free synthetic databases and a
  round-owned Python 3.12 environment. Both databases and the 116 MiB
  environment were deleted after the 816-case result was captured.
- The 243 MiB OpenTofu provider directory and the two final current-head Apple
  DerivedData directories remain only until the hosted candidate is durable;
  the final closeout removes them explicitly.

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: focused host builds and an unsigned iOS
  Simulator graph only; no signed phone installation.
- Data-preservation result: no schema migration; no physical-device data test.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: WHOOP comparison, supplier discovery and explicit
  selection, printed-ID and password truth, reconnect, background collection,
  history retention, battery, haptics, firmware, egress, and physiological
  accuracy.

## Git and release state

- Changed paths: the round spans the exact SDK source export, Apple and Android
  app adapters, local-only supplier wiring/provider source, focused tests,
  onboarding integration, final Live localization/contracts, the generated
  terminology ratchet, supporting release/handoff records, and this operations
  record.
- Commits: SDK repin `ea4634ee1`; Apple wiring/source `e106ff8c1` and
  `ea24354b9`; Android wiring/source `38d556602` and `637d6a987`; lifecycle
  corrections through `43cadcc37`; Android provider `59a7c1aa0`; source-aware
  onboarding `6ce43f0fe`; final verification correction
  `ddb0315f76d7551916ef8b6bf54de5a2a5653d07`.
- Branch and remote state: final implementation and documentation are local on
  `codex/noop-band-sdk-app-integration-20260921`; PR `#17` still points to
  `5978bda7760d6f8378d0c5439ab1788f8e0aa24e` until the one consolidated push.
  No deployment or release occurred.
- Repository visibility verified: previously verified public on 2026-09-23;
  not reverified by this documentation-only repair.
- Version/build impact: no application version change.
- Release or distribution impact: none until combined local gates, exact-SHA
  hosted checks, review, and protected merge pass.

## Decisions

- Durable decision added or changed: D-061 supersedes D-012 for the selected
  three-to-five Today metric surface while preserving full-history access.
  D-055 and D-056 continue to require one active phone collector, quarantined
  supplier dependencies, public source-only SDK handling, and exclusion of
  private supplier artifacts.
- Decision-log entry: existing D-055, D-056, and D-061 entries; no new decision
  is added by this documentation repair.

## Open risks and honest limitations

Supplier redistribution rights, complete dependency notices/SBOM, signing,
store review, firmware, physical discovery, printed-ID truth, possession proof,
password behavior, battery accuracy, live HR accuracy, disconnect/reconnect,
background execution, on-band retention, haptics, OTA, egress, and battery-life
evidence remain open. Hosted exact-SHA checks and protected integration also
remain until the final push completes. No local software, localization,
policy, server, or plan-only verification gap remains in this round.

## Next round

1. Commit this closeout record and push the two final local commits once to PR
   `#17`.
2. Require every protected exact-SHA context, resolve any current review
   threads without bypassing checks, and merge normally.
3. Verify protected `main`, re-run its trust/required-context checks, and remove
   the remaining exact round-owned DerivedData, OpenTofu provider cache, and
   temporary logs.
4. Begin the signed physical-device round only after supplier
   rights/SBOM/security inputs and representative iPhone, Android, WHOOP, and
   supplier devices are available.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, supplier binaries, or absolute personal
      paths are present.
