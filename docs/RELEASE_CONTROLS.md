# NOOP release controls

**Status:** source controls implemented; owner, hosted-environment, signing,
hardware, legal, certification, store, and production approval remain separate
release gates.

This document defines the repository-controlled portion of a NOOP release. The
machine-readable authority is [`../release/release-policy.json`](../release/release-policy.json).
The policy does not authorize a public release and cannot replace external
evidence.

## Release boundary

A production release starts from one reviewed commit on protected `main` or an
approved `release/<version>` branch. Its source, dependency graph, build inputs,
artifacts, SBOM, checks, schemas, and rollback targets are tied to that commit.
No release command may silently use a moving branch, floating Action, mutable
container tag, unreviewed dependency graph, or local credential.

The repository gate verifies:

- required lockfiles and Gradle artifact verification metadata;
- full 40-character commit pins for every external GitHub Action;
- SHA-256 digest pins for container build and runtime inputs;
- the immutable server migration manifest;
- the reviewed runtime inventory and distribution notices;
- tracked credential/private-artifact filenames and high-confidence token
  formats;
- release naming, reproducibility, migration, vulnerability, environment, and
  evidence policy structure;
- exact Apple/Android reference-calibration revisions, metric keys/ranges,
  thresholds, and critical chronological holdout guards;
- presence of the metric reprocessing/rollback, key lifecycle, and coordinated
  vulnerability/security-update contracts.

Run it from the repository root:

```bash
python3 Tools/release-control-gate.py check
python3 Tools/calibration-parity-audit.py check
python3 -m unittest \
  Tools.tests.test_release_control_gate \
  Tools.tests.test_release_evidence \
  Tools.tests.test_calibration_parity_audit
```

The `Release Controls` workflow runs on every pull request and every push to
`main`. The release workflow invokes the same gate before it mutates a version
or creates a draft.

## Protected merge contract

Live GitHub settings were reverified on 2026-09-18. `main` is protected with
strict up-to-date status checks, administrator enforcement, and linear history;
force pushes and deletion are disabled. Repository release work is prepared on
a branch and integrated through a protected pull request. Do not push release
work directly to `main`.

The machine-readable hosted contract is
[`../release/required-ci.json`](../release/required-ci.json). Protected `main`
requires these ten stable contexts, all owned by GitHub Actions application
`15368`:

1. `android-ci-required`
2. `apple-ci-required`
3. `health-claims`
4. `i18n-coverage`
5. `operations-record`
6. `release-controls`
7. `runtime-license-required`
8. `server-ci-required`
9. `swift-packages-required`
10. `trusted-release-controls`

Health claims, localization, operations records, release controls, and trusted
release controls are universal pull-request checks. Android, Apple, runtime
license, server, and Swift-package workflows publish always-present,
fail-closed required results after their applicability jobs; expensive work may
skip only when the reviewed applicability contract says it is irrelevant.

`trusted-release-controls` is the release-authority trust root, not a duplicate
product test:

- On a pull request, `pull_request_target` executes only protected-base source
  and checks out the candidate separately as untrusted data.
- Changes to workflows or other enumerated release-authority paths require an
  in-repository head whose exact `opened` or `synchronize` actor is the
  repository owner. Other changes are checked against the protected base's
  required-CI structure.
- The source-only NOOP Band SDK verifier and its tamper-test module are
  enumerated release-authority paths. A candidate may update the vendored
  source and manifest, but cannot also weaken their digest, layout, symlink, or
  supplier-binary checks without the same owner-bound trust-root review.
- The workflow publishes one custom `trusted-release-controls` result to the
  exact pull-request head. A failed, skipped, or canceled validation fails the
  context. The independent `release-controls` context still validates the
  candidate's release-policy semantics.
- After merge, the same trusted workflow verifies the exact protected `main`
  source and publishes a distinct `protected-main` result. Release publication
  accepts only that scope; a successful pull-request-scoped result cannot
  authorize a production release.

The protected baseline
`b688b3b725cd497e96a31b28540a219bf50446e1` had all ten exact-SHA contexts
complete successfully when rechecked on 2026-09-18. That proves the repository
merge contract for that commit only. Reviewed GitHub deployment environments,
production credentials and rotation, signing identities, signed artifacts,
supplier and physical-device evidence, legal/certification approvals, store
records, production operations, and final go/no-go approval remain separate
open gates.

For the active SDK app-integration branch, the recorded inputs and current
local evidence are:

- upstream SDK source: `NoopBandSDK` PR `#31` protected merge
  `9fd84ff6af3d48c41fb5af3128efec9dcc6948a4`
- application candidate: the consolidated SDK PR `#31` source and evidence
  replacement carried by this branch
- pull request: `#17`; only its final exact candidate head can authorize merge
- exact current local verification: upstream Swift 100/100, Kotlin/JVM
  102/102 plus `installDist`, 50/50 conformance, and the 71-file SDK repository gate
  pass. The app artifact verifier and its 9-test adversarial suite, vendored
  Swift package 16/16, real macOS app boundary 10/10, Android Full and Demo
  integration 15/15 each, both Android instrumentation source graphs, and the
  unsigned Release iPhone/Watch/complication/widget graph pass. The exact
  focused iOS profile clear-and-retype regression passes 1/1. Repository
  release, trust, terminology, privacy, claims, localization, operations,
  artifact, shell, and diff gates pass in the final 318-test wall with one
  intentional skip before the branch push.
- required contexts: prior exact heads do not authorize this replacement. The
  final PR `#31` source and documentation candidate must pass all ten exact-SHA
  hosted contexts before protected integration.
- merged protected-main commit: `<pending exact 40-character SHA>`
- protected-main trusted result: `<pending>`

Metric publication and rollback must also follow
[`METRIC_REPROCESSING_AND_ROLLBACK.md`](METRIC_REPROCESSING_AND_ROLLBACK.md).
Credential and signing material must follow
[`KEY_MANAGEMENT.md`](KEY_MANAGEMENT.md), and security reports/updates follow
[`../SECURITY.md`](../SECURITY.md) plus
[`SECURITY_OPERATIONS.md`](SECURITY_OPERATIONS.md). Their presence is enforced
as a release input; production drills and external evidence remain separate
gates.

## Naming

- Release branch: `release/<semver>`, for example `release/1.0.0`
- Hotfix branch: `hotfix/<semver>`, for example `hotfix/1.0.1`
- Immutable production tag: `v<semver>`, for example `v1.0.0`
- Artifact: `NOOP-<platform>-v<semver>.<type>`

Moving names such as `latest` may point to testing convenience artifacts only.
They are never production provenance. A published production tag and its
artifacts are immutable. A corrected release receives a new SemVer and build
number.

## Dependency and vulnerability gate

Runtime SwiftPM revisions, Gradle modules, Python packages, and container bases
are exact inputs. Android additionally verifies downloaded metadata and
artifacts against SHA-256 entries in
`android/gradle/verification-metadata.xml`. A dependency update must change its
lock and reviewed license inventory together.

The release threshold is zero known Critical or High vulnerabilities. Medium
findings require review. Any time-bounded exception requires a named owner,
affected artifact and dependency, exploitability assessment, compensating
control, expiry date, and release approver. Exceptions cannot waive a
launch-severity credential, tenant-isolation, firmware-authentication, signing,
or health-data exposure defect.

Required evidence includes:

```bash
cd server
pip-audit --requirement requirements.lock
pip-audit --requirement requirements-dev.txt
cd ..
python3 Tools/release-legal-gate.py distribution
```

Every production OCI digest also requires its registry scan result. Exact
SwiftPM and Gradle locks require platform advisory review. A source gate
confirms that this policy exists; the final release manifest must reference the
actual scan/advisory evidence.

## Reproducibility

Reproducibility means the same reviewed inputs and an explainable comparison,
not an unsupported promise that Apple/Google signatures or archives containing
timestamps are byte-identical.

### Apple

Use the same Xcode build, SDK, `Package.resolved`, source tree, configuration,
entitlements, and destination. Compare normalized unsigned bundle contents,
bundle graph, architectures, versions, and release contract. Signed release
artifacts additionally require the same approved signing/notarization pipeline.

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS='x86_64 arm64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
```

### Android

Use JDK 17, the committed Gradle wrapper, dependency lock, verification
metadata, exact source, variant, and approved signing identity. Compare the
normalized AAB entries and signing certificate identity.

```bash
cd android
./gradlew --no-daemon clean testFullDebugUnitTest lintFullDebug
./gradlew --no-daemon bundleFullRelease
cd ..
```

### Server

Use the digest-pinned bases and hash-locked Python runtime. Compare OCI config
and layer digests for the same target platform and build frontend.

```bash
python3 Tools/release-legal-gate.py distribution
docker build --pull=false --no-cache -t noop-server:release server
docker build --pull=false --no-cache -t noop-backup:release server/backup
```

### Firmware

Firmware reproducibility is defined but blocked: the supplier dossier,
repository, compiler/container, board configurations, bootloader, application,
signing-key identifiers, and image-manifest contract do not exist in this
repository. No firmware artifact may be listed as reproducible until those
exact inputs and clean builds are available.

## Migration and rollback

Applied migrations are immutable. Database and API evolution follows:

1. **Expand:** add backward-compatible schema/API support.
2. **Migrate:** backfill in bounded, resumable, observable batches.
3. **Verify:** prove old and new readers, invariants, backup, restore, and
   tenant isolation.
4. **Contract:** remove old behavior only after the supported client window and
   rollback period close.

Destructive down migrations are forbidden. Database-backed application rollback
uses a reviewed code revert rebuilt with the current immutable migration set, or
disables a new path with its kill switch. Exact older images are eligible only
when a tested readiness compatibility matrix explicitly allows their migration
set; the default exact-manifest readiness contract rejects them. Rollback never
edits migration history or assumes removed data can be recreated. Each release
records the oldest compatible app, API, schema, protocol, firmware, metric
revision, and restore version.

## Evidence format

`Tools/release-evidence.py` generates:

- one deterministic CycloneDX 1.5 SBOM whose exact component and container-input
  counts are derived from and recorded for the candidate commit;
- one manifest tied to the full source commit and tree;
- artifact records containing only basename, SHA-256, byte size, and media
  type;
- fixed static-check names with passed outcomes.

The schema deliberately rejects paths, timestamps, account/device identifiers,
health data, logs, payloads, credentials, signing identities, and arbitrary
errors. See [`../release/evidence/README.md`](../release/evidence/README.md).

## Final command order

Run the following on the exact candidate commit. Commands that need accounts,
signing, devices, providers, or production systems remain explicit external
gates rather than local substitutes.

The command list below defines required payloads. Every payload that can run
longer than one minute or emit verbose build/test output MUST be passed after
`--` to `Tools/run-bounded-command.py`; do not invoke raw `xcodebuild`, Gradle,
Swift package, full pytest, OpenTofu, Docker, or equivalent walls in an
interactive terminal. Use a unique safe label plus round-owned private
`--status-file` and `--log-file`. The CLI automatically stops below 10% free
system memory, below 10 GiB free disk, after its deadline, or when the private
log reaches 128 MiB. Lowering or disabling a floor requires a narrow evidenced
exception in the active operations record.

Example wrapper:

```bash
EVIDENCE_ROOT="$(mktemp -d)"
python3 Tools/run-bounded-command.py \
  --timeout-seconds 3600 \
  --grace-seconds 30 \
  --label apple-complete-wall \
  --status-file "$EVIDENCE_ROOT/apple-complete-wall.status" \
  --log-file "$EVIDENCE_ROOT/apple-complete-wall.log" \
  -- \
  xcodebuild -project Strand.xcodeproj -scheme Strand \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

```bash
# Repository and policy
python3 Tools/release-control-gate.py check
python3 Tools/calibration-parity-audit.py check
python3 Tools/terminology-audit.py check
python3 Tools/required-ci-gate.py check
python3 Tools/trusted-release-controls.py verify-self --root .
python3 Tools/release-legal-gate.py distribution
python3 Tools/check-private-data.py
python3 Tools/health_claims_gate.py
python3 Tools/i18n_audit.py --platform all --full
python3 Tools/i18n_audit.py --ci HEAD
python3 Tools/validate-ops-rounds.py --all .
git diff --check

# Nine Swift packages
for package in \
  Packages/WhoopProtocol \
  Packages/OuraProtocol \
  Packages/PolarProtocol \
  Packages/WhoopStore \
  Packages/StrandAnalytics \
  Packages/StrandImport \
  Packages/StrandDesign \
  Packages/NoopLocalAccess \
  Packages/NoopRemoteSync
do
  (cd "$package" && swift build && swift test)
done

# Standalone Swift verification harnesses
for package in Tools/StudyHarness Tools/Backfill
do
  (cd "$package" && swift build && swift test)
done

# Server
cd server
python -m ruff check .
python -m ruff format --check .
pip-audit --requirement requirements.lock
pip-audit --requirement requirements-dev.txt
python -m pip check
python -m pytest -q
cd ..

# Android Full and Demo variants
cd android
./gradlew --no-daemon \
  assembleFullDebug assembleDemoDebug \
  testFullDebugUnitTest testDemoDebugUnitTest \
  lintFullDebug lintDemoDebug \
  compileFullDebugAndroidTestKotlin compileDemoDebugAndroidTestKotlin

# API 35 production-shell managed-device lane
./gradlew --no-daemon --no-configuration-cache \
  assembleFullDebug assembleFullDebugAndroidTest
./gradlew --no-daemon --no-configuration-cache \
  pixel2Api35FullDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.notClass=com.noop.ui.ReviewSampleInstrumentedTest

# API 35 fresh-process Review Sample managed-device lane
./gradlew --no-daemon --no-configuration-cache cleanManagedDevices
./gradlew --no-daemon --no-configuration-cache \
  pixel2Api35FullDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.noop.ui.ReviewSampleInstrumentedTest \
  -Pandroid.testInstrumentationRunnerArguments.requireFreshWorkManager=true
cd ..

# Apple source and simulator graph
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build test
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# Evidence
VERSION=<approved-semver>
OUT="$(mktemp -d)"
python3 Tools/release-control-gate.py check \
  --report "$OUT/release-controls.json"
python3 Tools/release-evidence.py sbom --source-ref HEAD \
  --version "$VERSION" --output "$OUT/NOOP-source-v$VERSION.cdx.json"
python3 Tools/release-evidence.py manifest --source-ref HEAD \
  --version "$VERSION" \
  --artifact "$OUT/NOOP-source-v$VERSION.cdx.json" \
  --artifact "$OUT/release-controls.json" \
  --checks "$OUT/release-controls.json" \
  --output "$OUT/NOOP-source-v$VERSION.manifest.json"
python3 Tools/release-evidence.py verify \
  --manifest "$OUT/NOOP-source-v$VERSION.manifest.json" \
  --artifact-directory "$OUT" --expect-ref HEAD
```

The two API 35 commands mirror the required production-shell and fresh-process
Review Sample lanes. The hosted workflow's classified one-time retry is
permitted only when
`Tools/android-managed-device-retry.py` proves that infrastructure failed
before any test started.

The corresponding protected contexts are the ten listed in the protected merge
contract above. A pull request must pass all ten on its exact head before normal
integration. Release and repair tooling then reverify the required workflow
owner, GitHub Actions application, exact SHA, conclusion, and the
`protected-main` trusted scope before any candidate publication. Signed
archives, physical-device matrices, supplier hardware/firmware conformance,
legal/certification approvals, store records, reviewed production environments,
production operations, and final go/no-go remain separately required.

## Hotfixes

A hotfix branches from the latest immutable production tag, receives a new
patch version and monotonic platform build numbers, and passes the same
applicable gates. It never replaces an existing tag or artifact. Emergency
scope may reduce unrelated test breadth only through a documented release
decision; it cannot bypass signing, migration integrity, credential, privacy,
tenant-isolation, hardware compatibility, or rollback evidence.
