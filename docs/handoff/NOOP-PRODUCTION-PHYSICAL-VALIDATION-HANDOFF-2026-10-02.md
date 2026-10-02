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

## Confirmed software and deployment evidence

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

### Android

1. Run `Tools/verify-android-supplier-sdk.py`.
2. Run `:app:noopSupplierSdkStatus` and `:app:verifyNoopSupplierSdk`.
3. Build the exact Full Debug APK from the same protected SHA.
4. Record the APK SHA-256 and install with `adb` while preserving existing data
   outside an explicitly recorded clean-install case.

Do not use GitHub Actions dispatches for physical testing. Required protected
checks still remain mandatory for integration.

## First-run and account sequence

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

## Inaccessible transferred review

The checkout previously named under another user's home directory, commit
`d390e4a9a`, handoff
`docs/handoff/NOOP-DISCOVERY-ACCOUNT-REVIEW-2026-10-02.md`, and commit
`6bf66cdb1` were not available in this workspace. To review them, place a Git
bundle or patch series, the handoff document, and a SHA-256 manifest in an
accessible private transfer directory. Exclude credentials, phone data,
supplier binaries, firmware, and signing material.
