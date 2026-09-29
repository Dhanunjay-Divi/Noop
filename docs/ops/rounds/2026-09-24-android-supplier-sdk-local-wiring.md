# Round: 2026-09-24 - Android supplier SDK local wiring

## Status

- State: `scoped implementation complete; parent-controlled heavy verification and ops indexing pending`
- Owner: project team
- Branch: `codex/veepoo-android-wiring-20260924`
- Start commit: `5978bda7760d6f8378d0c5439ab1788f8e0aa24e`
- End implementation commit: this round's local commit; exact SHA is reported
  in the final handoff because a commit cannot contain its own SHA
- Record commit or PR: local commit only; push not authorized

## Objective

Add source-only Android build wiring for an explicitly configured external
supplier SDK without committing supplier artifacts or changing the default
WHOOP build. Add deterministic local verification, focused tests, and explicit
legal, transitive-dependency, release, and physical-device gates.

## Scope

### In scope

- Gitignored local supplier configuration and staging boundaries.
- Conditional Full-only Gradle source/dependency wiring.
- Exact AAR hash, class, archive, native ABI/library, and Git-index checks.
- Focused verifier/default-off contract tests and local handoff documentation.

### Non-goals

- Editing the app adapter Kotlin sources.
- Supplier release packaging, dependency approval, signing, deployment, or
  physical BLE validation.
- Changing WHOOP selection, Demo dependencies, health behavior, or product UI.

## Starting evidence

- The exact branch and start commit matched the requested base.
- The worktree was clean before edits.
- Owner-supplied Android inputs remain outside Git under the supplied local SDK
  directory.
- The supplier demo identifies multiple local AAR lanes and additional runtime
  dependencies; that demo is reference evidence, not an approved production
  dependency or redistribution grant.
- Free disk was 18 GiB and encrypted swap use was approximately 21.7 of 22 GiB.
  The user restricted this round to lightweight verifier, unit, and Gradle
  configuration checks.
- Unknowns that remain open: legal redistribution, complete transitive SBOM and
  notices, exact model/firmware behavior, signed packaging, egress, physical
  BLE/background/history/battery/haptic behavior, and physiological accuracy.

## Delivered

- Added a gitignored local supplier config and optional ignored staging
  location. The config is the only source of local AAR paths, filenames,
  hashes, required classes, native ABIs, and native library names.
- Added Full-only conditional source/dependency wiring. No config means zero
  supplier artifacts, no supplier source set, a false adapter-availability
  build flag, and the existing WHOOP path remains unchanged. Demo never
  receives the supplier source or AARs.
- Added a release task-graph block for supplier-enabled Full packaging.
- Added a deterministic verifier for Git-index policy, strict config parsing,
  external/symlink-safe paths, exact SHA-256, AAR/class archive structure,
  required classes, exact JNI ABI/library inventory, and prohibited nested or
  tracked binaries.
- Added 12 focused tests covering valid, disabled, malformed, non-file, tampered,
  missing-class, native-inventory, tracked-artifact, tracked-config, and
  default-off Gradle contracts.
- Added the local wiring handoff with setup, verification, legal,
  transitive-dependency, release, and physical-device gates.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: no permission or network change.
- Health/medical claim impact and limitations: none; build verification is not
  physical-device or health-validity evidence.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: deterministic
  verifier exit status and fixed validation messages; Gradle status task reports
  only enabled state, artifact count, and source-set inclusion.
- Why existing evidence is sufficient, or why new evidence is required: this
  round changes build-time selection only and does not add a runtime boundary.
- Existing evidence reused: Gradle task failures and the repository bounded
  command runner.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: verifier output excludes
  absolute supplier paths and reports only configured relative paths, hashes,
  sizes, class counts, and ABI categories.
- Cross-platform/backend correlation: not applicable.
- Remaining blind spots: runtime loading, BLE callbacks, egress, and physical
  behavior remain unobserved.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| First focused verifier test attempt | failed before discovery: Python 3.14 dynamic module registration was missing for dataclasses; test loader corrected | Failure was in the test harness, not artifact verification | Verifier behavior |
| Second focused verifier test attempt | 4 failures and 3 errors: synthetic macOS temporary paths retained the `/var` symlink while the verifier correctly rejects symlinked configured paths; test roots canonicalized | The symlink rejection remained fail-closed | Remaining verifier behavior |
| `python3 Tools/run-bounded-command.py ... -- python3 -m unittest Tools.tests.test_android_supplier_sdk_verifier` | passed, 12 tests in 0.967 seconds | Local config/archive/index fail-closed behavior and tracked default-off Gradle contract | Android compilation or hardware |
| Bounded offline `:app:noopSupplierSdkStatus` with the ignored config temporarily absent | passed: `enabled=false`, zero artifacts, supplier source excluded | Ordinary configuration excludes supplier source/dependencies | Full compile or packaging |
| Bounded offline `:app:noopSupplierSdkStatus :app:verifyNoopSupplierSdk` with 512 MiB heap and one worker | passed: enabled, seven exact AARs, required classes present, configured JNI inventories exact | Local dependency identity and Gradle selection | Legal rights, transitive runtime completeness, adapter compilation, or physical behavior |
| `python3 Tools/validate-ops-rounds.py --all .` through the bounded runner | failed only because `rounds/INDEX.md` does not link this new round | All other operations records/privacy validation passed | Index completeness; the task explicitly prohibited editing `rounds/INDEX.md` |
| `git diff --check`; tracked binary scan; ignored-config check; changed-file path audit | passed | Diff hygiene, no prohibited tracked artifact, local config ignored, scoped paths only | Android runtime behavior |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: no data path changed.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all supplier Android physical-device rows.

## Git and release state

- Changed paths: `.gitignore`, `android/app/build.gradle.kts`,
  `Tools/local/verify-android-supplier-sdk.py`,
  `Tools/tests/test_android_supplier_sdk_verifier.py`,
  `docs/handoff/ANDROID-SUPPLIER-SDK-LOCAL-WIRING.md`, and this round record.
  The populated `android/noop-supplier-sdk.properties` remains ignored and
  untracked.
- Commits: one local commit pending at record-write time.
- Branch and remote state: local branch only; no push authorized.
- Repository visibility verified: treated as public per D-056 and current
  repository records.
- Version/build impact: no version change; optional local Full build only.
- Release or distribution impact: supplier-enabled Full release packaging is
  blocked.

## Decisions

- Durable decision added or changed: none; implements D-055/D-056.
- Decision-log entry: not required.

## Open risks and honest limitations

- Heavy Android compile, lint, assemble, and full test walls are deferred to the
  parent-controlled sequential run because of current disk/swap pressure.
- No supplier binary may be redistributed or treated as production-approved.
- `docs/ops/rounds/INDEX.md` still needs a parent-owned link before the complete
  operations validator can pass; this task explicitly prohibited editing it.

## Next round

1. Run the documented parent-controlled heavy Android commands sequentially
   after resource pressure is resolved.
2. Add this round to `docs/ops/rounds/INDEX.md` in the parent integration
   branch, then rerun the complete operations validator.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
