# NOOP production and physical-validation handoff

Date: 2026-10-02

## Purpose

This handoff starts only after the software changes named below are present on
clean protected `main` and all required checks are green. It guides the next
device-connected agent through signed iPhone and Android validation without
weakening supplier, privacy, account, or release gates.

Simulator builds do not prove BLE, background execution, battery use, haptics,
retention, notification delivery, sensor accuracy, or physical ownership.

## Required starting state

1. Use a new clean checkout of protected `main`; do not use a dirty development
   worktree or preserve a preconfigured simulator state as first-run evidence.
2. Load `.agents/skills/noop-ops/SKILL.md`, run
   `.agents/skills/noop-ops/scripts/context_snapshot.sh .`, and read
   `CLAUDE.md`, `docs/ops/ACTIVE.md`, this handoff, and
   `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`.
3. Record `git rev-parse HEAD`, verify all required protected checks for that
   exact SHA, and attach the result to a new operations round.
4. Confirm the supplier-neutral SDK source revision remains
   `b02808372b7c537f22058c7ebc75d92c750373be` and its manifest SHA-256 remains
   `6beca829f3b2a367cf7046544e8d06dc74ae9f905e1eefe4bb58ccf41615fd34`.
5. Keep `supplierArtifactsIncluded` false in public source. Enable a native
   supplier adapter only through ignored local configuration and exact
   approved artifacts for the tested model, hardware, firmware, and protocol.
6. Do not flash firmware from an inferred package, key, command, or procedure.

The tracked `.agents/skills/noop-ops` skill is the required agent contract. It
is already present on protected `main`; do not create a second physical-testing
skill or rely on chat history instead of this record.

### Device-agent start prompt

Use this instruction when handing the integrated candidate to the
device-connected agent:

> Start from a new clean checkout of protected main. Load
> `.agents/skills/noop-ops/SKILL.md`, run its context snapshot, and read both
> physical handoffs. Verify the exact protected SHA and required checks, then
> build one signed iPhone and Android qualification candidate without clearing
> retained phone data. Validate WHOOP first. Keep the supplier adapter disabled
> unless the exact approved model/firmware/artifact tuple matches every trust
> manifest. Run the full account, connection, live data, history, background,
> battery, notification, diagnostics, accessibility, source-switching, and
> metric protocols. Record privacy-safe PASS, FAIL, SKIPPED, or BLOCKED evidence
> in a new operations round. Never infer physical behavior from a simulator,
> repin an unapproved archive, or flash guessed firmware.

## Confirmed software and deployment evidence

- Local consolidation branch
  `codex/noop-release-candidate-handoff-20261002` has implementation/evidence
  base `e5f11cfe1602ec02e8b08bc4a766f7b07689e752`. It combines mobile commits
  `3d8256978` and `628554748`, consolidated supplier commits `cc8df6123` and
  `eae1c5d71`, and handoff commits `13e787d0b` and `e5f11cfe1`.
- Exact combined verification passed 88 Apple supplier/neutral-SDK tests, the
  complete iPhone Simulator graph, two first-run UI cases, the Recovery
  exact-date UI case on the dedicated review simulator, 58 StrandDesign tests,
  12 Android navigation/OTP tests with production and Android-test compilation,
  62 supplier/quarantine Python tests, and the repository release controls.
  The green UI assertions completed before a known local Xcode teardown hang;
  protected exact-head checks remain the integration authority.
- This local branch has not been pushed or merged, and no Actions workflow or
  deployment mutation was dispatched from it. Do not install it as a release
  candidate until normal protected integration produces an exact protected
  SHA.
- Private synthetic staging was integrated through protected PR `#31`, merge
  `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c`.
- All three deployed services use immutable image digest
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`.
- Ready revisions:
  - `noop-staging-api-00001-rsg`
  - `noop-staging-managed-api-00002-6k7`
  - `noop-staging-managed-processor-00001-cq8`
- The bounded private-runtime verifier passed and the final OpenTofu plan
  reported zero drift.
- PyJWT is pinned and hash-locked at `2.15.0`; its license inventory and notice
  SHA-256 agree. The unavailable transferred commit `6bf66cdb1` must not be
  guessed into the release. Transfer and review it separately if it contains
  anything beyond that already-integrated upgrade.
- Supplier optional step/sleep reads are serialized, request-fenced, and
  bounded by timeouts in local commit `6d0805485`. Integration evidence must
  name its protected replacement SHA after normal merge.

The accessible historical branch
`codex/physical-band-review-20261001` is review evidence only. Its remote head
`7db906359` is based on superseded main `08ad0f472`, lacks the newer request-ID
and timeout correction, and would revert current PyJWT and product work if
merged wholesale. The transferred commits `d390e4a9a` and `6bf66cdb1`, plus
`docs/handoff/NOOP-DISCOVERY-ACCOUNT-REVIEW-2026-10-02.md`, are unavailable and
must not be guessed.

## Current supplier-artifact stop condition

The supplier adapter must remain disabled until the exact approved archives are
available and match the reviewed trust manifests.

The current local archive copies do not match the October 1 transfer evidence:

- iOS archive SHA-256 is
  `bbaa48df28c421608df7683be23fd13d455889d537722750529a9b550176e185`;
  its `2.2.XX.15` primary binary SHA-256 is
  `39fef6cc140bac8f45d9a60113300be923d04a96df008d9acda0e25a17b8c89a`.
- Android archive SHA-256 is
  `a335d5ecf53e6928fd13940cb166c78fab63fe1772e854fe35099e70c489ec83`;
  it contains protocol `2.3.80.15` with SHA-256
  `1d657bb6251a214eb1e941f1a25793b38378483352ef4e50de00e4270969ab04`.

Those values match neither protected-main trust pins nor the transferred
October 1 claims for iOS and Android. Do not repin to these archives, copy them
into Git, or use them for a supplier-band result. Obtain the authoritative
approved artifact bundle with a SHA-256 manifest, then rerun every artifact,
license, wrapper, build, and physical gate. WHOOP comparison testing may
continue independently.

The staging evidence uses synthetic identities and fictional data. It does not
prove real OTP delivery, public traffic, production health-data transfer,
physical ownership, or provider delivery.

## Secure local configuration

Keep these files ignored, mode `0600` where supported, and never print their
contents into chat, logs, screenshots, operations records, or commits:

- `Config/BundleIdSecrets.xcconfig`
- `Config/VeepooLocalSDK.xcconfig`
- `Config/ManagedCloudSecrets.xcconfig`
- `android/noop-supplier-sdk.properties`
- `android/managed-cloud.properties`
- `infra/gcp/backend.hcl`
- `infra/gcp/staging.auto.tfvars`

Do not commit supplier binaries, firmware, credentials, signing material,
private reference inputs, generated configuration, phone backups, or health
data.

## Candidate preparation

Use section 1.2 of
`docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md` as the executable command
source. Run every build through `Tools/run-bounded-command.py` with private
round-owned log and status files. The summaries below do not replace those
commands.

### iPhone

1. Run the exact Apple SDK verification/configuration commands in
   `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`.
2. Generate the project from `project.yml`.
3. Build one signed Debug qualification candidate from the recorded protected
   SHA.
4. Record app bundle version, code-sign identity class, and app artifact
   SHA-256 without recording a personal signing identity.
5. Install with `xcrun devicectl` while preserving existing phone data unless
   a specific clean-install case requires removal.
6. Before install, run `codesign --verify --deep --strict --verbose=2` on the
   app. Inspect the embedded provisioning profile and entitlements privately;
   record only bundle family, version/build, required capability presence, app
   SHA-256, and a redacted certificate fingerprint.

### Android

1. Run `Tools/verify-android-supplier-sdk.py`.
2. Run `:app:noopSupplierSdkStatus` and `:app:verifyNoopSupplierSdk`.
3. Build the exact Full Debug APK from the same protected SHA.
4. Record the APK SHA-256 and install with `adb` while preserving existing data
   outside an explicitly recorded clean-install case.
5. Before install, run `apksigner verify --print-certs` and inspect package,
   version, ABI, and debuggable state with Android build tools. Keep certificate
   owner text private; record only the approved fingerprint and artifact facts.

Do not use GitHub Actions dispatches for physical testing. Required protected
checks still remain mandatory for integration.

## First-run and account sequence

Use a dedicated clean test phone for first-run evidence. Use a separate
data-preserving phone for upgrade/reconnect evidence. Do not clear app data,
Keychain, Keystore, account state, or health history on a retained personal or
upgrade-test phone.

Exercise a genuinely clean first run before a preconfigured development state:

1. Review and accept the current remote Terms document.
2. Grant only the permissions requested at the corresponding step.
3. Open supported-band setup. Normal customer UI must list only transports the
   installed candidate can actually use.
4. Select the exact physical band and complete identification. Vibration is
   provisional discovery evidence, not ownership.
5. Create or sign in to the required account.
6. Perform a fresh possession challenge.
7. Confirm the server claim is atomic and single-owner for the device.
8. Confirm restart restores the same account/device state without exposing a
   local-test bypass.

Permanent account linking, concurrent claim behavior, supplier-approved
double-tap/gesture proof, and identify vibration remain device/server
validation gates until recorded with the exact candidate.

## Transport validation order

Validate the existing WHOOP comparison transport first. Do not remove, relabel,
or route around it.

Before supplier testing begins, record the WHOOP candidate, active source,
source-qualified row counts, durable history cursor, reconnect/background
outcomes, and fixed diagnostic category counts as `PASS`, `FAIL`, or `BLOCKED`.
Confirm the supplier factory remains disabled during this baseline.

For WHOOP on iPhone and Android, record:

- discovery, identification, connect, disconnect, and reconnect;
- battery and live heart rate;
- history catch-up and durable progress after interruption;
- background/foreground transitions and process restart;
- app notification behavior;
- privacy-safe diagnostics export;
- source provenance on Today, Trends, details, and export.

Then enable the supplier adapter only for an exact approved tuple and repeat
the same matrix. Include:

- optional step and sleep callbacks completing normally;
- callback omission reaching the bounded timeout;
- delayed/duplicate callback rejection after timeout and reconnect;
- source stop/disconnect cancelling pending reads;
- live heart rate continuing without optional command overlap;
- history retention/overflow behavior while the phone is unavailable.

Supplier prerequisites are a hard checklist: exact model, project code, board,
MCU, BLE controller, bootloader, firmware, protocol, wrapper and transitive
artifact hashes; compatibility row; distribution/support/vulnerability rights;
SBOM and privacy review; pairing/reset/recovery procedures; retained control
units; and pre-approved accuracy, latency, battery, thermal and reliability
budgets. Any missing item is `BLOCKED`.

Finally run source switching in both directions:

1. WHOOP to supplier.
2. Supplier to WHOOP.
3. Restart after each selection.
4. Confirm one collector owns the active source and provenance never crosses
   source namespaces.

## Account, cloud, and viewer checks

- Use synthetic test accounts and fictional Safety contacts.
- Verify account isolation, restore, export, deletion, retry, pagination, and
  idempotency against the private staging deployment.
- Verify explicit managed-health-data consent before upload.
- Verify the phone remains the encrypted edge collector and retains the safe
  offline working set during service outage.
- Verify Mac, Watch, and a second phone remain viewer/controller surfaces only
  where the current architecture requires that behavior.
- Keep public invocation, real health transfer, real Safety paging, payment,
  and real provider delivery disabled unless separately authorized and gated.

Use approved synthetic-account tooling to prove account creation, concurrent
single-owner claims, privacy-preserving loser behavior, restart, logout,
restore, cross-account isolation, export, erasure, and replacement-phone
recovery. Shared evidence may contain only a redacted correlation reference,
never an account or band identifier.

Immediately before installing a candidate, reverify private staging against the
integrated protected SHA:

```bash
cd infra/gcp
./scripts/verify-private-runtime.sh
tofu plan -detailed-exitcode
```

Exit `0` is no drift; exit `2` is drift and blocks the round. Never paste
provider output or secret values into shared evidence.

## Metric, battery, and egress protocols

Execute `PHY-MET-001` through `PHY-MET-006` exactly as defined in
`docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`. This includes
synchronized manual/video step references, stationary false-step scenarios,
both wrists, pre-registered cohorts and error budgets, approved reference
instruments, missingness distributions, and client/server formula parity over
the same accepted physical window. Unsupported or absent channels stay
missing.

Execute `PHY-PWR-001` and the 24-hour/multi-day/30-day soak plan with
pre-approved budgets. Record app, wrapper, firmware, phone class, radio state,
collection state, elapsed time, and aggregate resource result.

Capture signed-app egress only with approved synthetic data and an authorized
test network. Compare destinations and purposes with the allowlist. Unexpected
supplier-SDK egress fails the scenario. Remove test certificates, proxies,
captures, and temporary trust settings after review.

## Evidence and privacy

Create a new round under `docs/ops/rounds/` and attach only privacy-safe
evidence. Use generalized device/OS/band classes and fixed diagnostic
categories.

Never record names, emails, phone numbers, serials, printed band identifiers,
BLE addresses, device IDs, account/contact IDs, tokens, precise locations, raw
frames, sensor rows, biometric values, screenshots containing personal data,
or arbitrary SDK errors.

For each case, record:

- exact protected SHA and artifact digest;
- platform and generalized OS/device class;
- pass, fail, skipped, or blocked;
- bounded elapsed time and aggregate counts where useful;
- fixed failure category;
- whether user data was preserved;
- next reproducible action.

Generate the report through the in-app user-reviewed app-report flow. Store the
export in a private mode-`0600` round directory, hash it, and scan it before
sharing. Reject any report containing health values, precise timestamps,
names, addresses, serials, printed IDs, BLE addresses, account/contact/device
identifiers, tokens, URLs, payloads, raw frames, arbitrary SDK errors, or user
text. Do not use broad `logcat`, sysdiagnose, packet capture, or console dumps
as routine evidence. Remove temporary copies after the sanitized result is
recorded.

## Physical and external gates

The following remain unvalidated until the exact signed candidates are tested:

- physical discovery and BLE connection;
- identify vibration and possession gesture/double-tap;
- permanent single-owner account linking and concurrent claims;
- reconnect, background execution, process death, and OS/OEM restrictions;
- flash retention, catch-up, overflow, and overwrite behavior;
- battery consumption and charging behavior;
- haptics and audible notification delivery;
- Watch/Mac notification and viewer behavior;
- false-step rejection and manual-count accuracy;
- heart rate, HRV, sleep, oxygen, respiratory, calorie, stress, hydration, and
  every other sensor or derived-metric accuracy claim;
- firmware OTA, rollback, rescue, and factory procedures;
- signed-app network egress;
- 24-hour, multi-day, and 30-day soak validation;
- accessibility on physical VoiceOver and TalkBack configurations.

Failures or missing supplier inputs must be recorded. Do not weaken a gate,
substitute simulator evidence, or call the release production-ready while any
required physical, security, privacy, signing, legal, or provider gate remains
open.

## Completion and hand-back

The physical round is complete only when every applicable authoritative
`PHY-*` row has a recorded result, UTC boundary, reset scope, expected and
observed behavior, app/wrapper/hardware/firmware/formula revisions, artifact
reference, defect/retest link, data-preservation result, and reviewer. Update
`docs/FIRST_PRODUCTION_RELEASE_CHECKLIST.md`, a new operations round,
`docs/ops/ACTIVE.md`, and `docs/ops/rounds/INDEX.md`.

Return the exact protected SHA, signed artifact digests, deployment
revision/digest, configuration path inventory, pass/fail/blocked matrix,
privacy-safe report hashes, defects, and external gates. Do not return
credentials, identifiers, personal signing details, raw health data, or
supplier binaries.

## Inaccessible transferred review

The checkout previously named under another user's home directory, commit
`d390e4a9a`, handoff
`docs/handoff/NOOP-DISCOVERY-ACCOUNT-REVIEW-2026-10-02.md`, and commit
`6bf66cdb1` were not available in this workspace. To review them, place a Git
bundle or patch series, the handoff document, and a SHA-256 manifest in an
accessible private transfer directory. Exclude credentials, phone data,
supplier binaries, firmware, and signing material.
