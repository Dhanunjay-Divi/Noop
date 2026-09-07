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
or creates a draft. Branch protection and reviewed GitHub environments are
still owner-controlled settings and remain mandatory before production use.

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

Destructive down migrations are forbidden. Rollback deploys a compatible prior
application/firmware version or disables a new path with its kill switch; it
does not edit migration history or assume removed data can be recreated. Each
release records the oldest compatible app, API, schema, protocol, firmware,
metric revision, and restore version.

## Evidence format

`Tools/release-evidence.py` generates:

- one deterministic CycloneDX 1.5 SBOM covering the reviewed 213 runtime
  libraries and three digest-pinned container inputs;
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

```bash
# Repository and policy
python3 Tools/release-control-gate.py check
python3 Tools/release-legal-gate.py distribution
python3 Tools/check-private-data.py
python3 Tools/health_claims_gate.py
python3 Tools/i18n_audit.py --ci HEAD
python3 Tools/validate-ops-rounds.py --all .
git diff --check

# Server
cd server
python -m ruff check app tests
pip-audit --requirement requirements.lock
pip-audit --requirement requirements-dev.txt
python -m pytest -q
cd ..

# Android
cd android
./gradlew --no-daemon \
  assembleFullDebug testFullDebugUnitTest lintFullDebug \
  compileFullDebugAndroidTestKotlin
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

The corresponding hosted workflows are `Release Controls`, `Apple Application
Build`, `Android`, `Server`, `Swift Packages`, `Localization Coverage`, `Health
Claims`, `Runtime License Inventory`, and `Operations Record`. Production
branch/tag creation must require all applicable workflows on the exact source
commit. Signed archives, physical-device matrices, hardware/firmware
conformance, legal/certification approvals, store records, production
operations, and final go/no-go remain separately required.

## Hotfixes

A hotfix branches from the latest immutable production tag, receives a new
patch version and monotonic platform build numbers, and passes the same
applicable gates. It never replaces an existing tag or artifact. Emergency
scope may reduce unrelated test breadth only through a documented release
decision; it cannot bypass signing, migration integrity, credential, privacy,
tenant-isolation, hardware compatibility, or rollback evidence.
