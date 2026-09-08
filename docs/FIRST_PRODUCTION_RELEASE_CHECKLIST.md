# NOOP first production release checklist

- **Status date:** 2026-09-08
- **Purpose:** one editable, ordered list of everything still required for the
  first public production release
- **Confirmed market sequence:** India first, then the USA
- **Architecture and rationale:**
  [`FIRST_PRODUCTION_RELEASE_PLAN.md`](FIRST_PRODUCTION_RELEASE_PLAN.md)
- **Release status ledger:** [`PRODUCTION_READINESS.md`](PRODUCTION_READINESS.md)

Every unchecked point is pending. This checklist does not convert a simulator,
build, document, or staging result into physical-device or production evidence.

## How to use this checklist

1. Add a request at the correct dependency position.
2. Keep the stable phase ID. To insert between `MOB-020` and `MOB-030`, use
   `MOB-025`; do not renumber existing points.
3. Use one of these ownership labels:
   - `[OWNER]`: requires a product/account/business decision or access.
   - `[ENG]`: can be completed in source, tests, tools, or controlled systems.
   - `[JOINT]`: requires owner input plus engineering work.
   - `[EXT]`: requires a manufacturer, lab, carrier, counsel, store, reviewer,
     participant cohort, or another external party.
4. Mark a point complete only as `- [x]` and append
   `(Evidence: path, run, artifact, or approval date)`.
5. If a point is intentionally removed, keep it and append
   `(Superseded by: ID, reason, date)`.
6. Never put credentials, personal information, device identifiers, raw health
   data, signing identities, or private exports in this file.

Copy this form when adding a point:

```text
- [ ] PHASE-000 [OWNER|ENG|JOINT|EXT] Action with a measurable completion condition.
```

## Owner additions inbox

If the correct phase is not obvious, add the request here with `USR-010`,
`USR-020`, and so on. The next planning round moves it to the correct dependency
position without changing its ID. This inbox intentionally starts empty.

## 1. Product scope and accountable ownership

- [x] DEC-010 [OWNER] Confirm India as the first launch country.
  (Evidence:
  `ops/rounds/2026-09-05-band-ownership-onboarding.md`, 2026-09-05)
- [x] DEC-020 [OWNER] Confirm that the USA follows India rather than launching
  simultaneously. (Evidence:
  `ops/rounds/2026-09-05-band-ownership-onboarding.md`, 2026-09-05)
- [ ] DEC-030 [OWNER] Confirm the languages included in the first public
  release.
- [x] DEC-035 [OWNER] Require a NOOP ownership account to claim and activate a
  first-party band while keeping ongoing local collection, metrics, export,
  and device control independent of NOOP+ and payment. (Evidence:
  `ops/rounds/2026-09-05-band-ownership-onboarding.md`, 2026-09-05)
- [ ] DEC-040 [OWNER] Confirm whether paid NOOP+ enrollment, rather than its
  visible plan option, is enabled in the first release.
- [x] DEC-045 [OWNER] Show NOOP and NOOP+ before Home, give NOOP+ an accessible
  gold identity, and keep payment unavailable until its gateway is approved.
  (Evidence:
  `ops/rounds/2026-09-05-band-ownership-onboarding.md`, 2026-09-05)
- [ ] DEC-050 [OWNER] Confirm whether Friends is enabled in the first release.
- [x] DEC-060 [OWNER] Include manual, user-confirmed app SOS paging to accepted
  NOOP accounts in the first public release. Share only the newest location for
  the user's selected 8- or 12-hour incident window, and stop sharing when the
  incident is cancelled, resolved, disconnected, or expires. SMS/voice is a
  later fallback; band-triggered and automatic origins follow their separate
  gates. (Evidence:
  `ops/rounds/2026-09-07-launch-owner-decisions.md`, 2026-09-07)
- [ ] DEC-070 [OWNER] Confirm that automatic medical, anomaly, Rhythm, SpO2,
  temperature, stress, and fall paging remains unavailable.
- [ ] DEC-080 [OWNER] Confirm the public product and band names after trademark
  review.
- [ ] DEC-090 [OWNER] Confirm the public app version and monotonic Apple and
  Android build numbers.
- [ ] DEC-100 [OWNER] Confirm free NOOP versus NOOP+ pricing and entitlement
  boundaries.
- [ ] DEC-110 [OWNER] Confirm that every core local metric remains account-free
  and available without a subscription.
- [x] DEC-115 [OWNER] Keep v1 bands bound to the claiming account for the
  band's ordinary lifetime with no user-facing unpair or transfer; permit
  consumer release only through an eligible successor-band upgrade while
  retaining operator-only return, RMA, legal, and security exits. (Evidence:
  `ops/rounds/2026-09-05-band-ownership-onboarding.md`, 2026-09-05)
- [ ] DEC-116 [OWNER] Choose a 14-day or 30-day return window and the event from
  which it starts.
- [ ] DEC-117 [JOINT] Approve the objective condition-grading and lawful refund
  deduction schedule for marked or damaged returned bands.
- [ ] DEC-120 [OWNER] Decide whether the legacy direct-band adapter is removed
  from public builds or retained as an isolated compatibility module.
- [ ] DEC-130 [OWNER] Approve the general-wellness-only claims boundary for
  app, store, packaging, support, and advertising.
- [ ] DEC-140 [OWNER] Name the legal entity that owns the apps, band, store
  records, contracts, warranties, and privacy obligations.
- [ ] DEC-150 [OWNER] Name one accountable owner and one backup for hardware,
  firmware, Apple, Android, backend, security, privacy, validation,
  manufacturing, support, and release.
- [ ] DEC-160 [JOINT] Define release-blocking defect severity and who may
  approve or reject a release.
- [ ] DEC-170 [JOINT] Define which checklist points are mandatory if NOOP+
  remains disabled at launch.
- [ ] DEC-180 [JOINT] Record all decisions above in the durable release round.

## 2. Mainline, CI, and release controls

- [x] CI-010 [ENG] Reproduce and fix the current iOS production-shell test
  failure on current `main`. (Evidence:
  `ops/rounds/2026-09-06-hosted-release-gates.md`, GitHub Actions run
  `34080116658`)
- [x] CI-020 [ENG] Make the Android managed-emulator production-shell test
  deterministic and retain diagnostics on failure. (Evidence:
  `ops/rounds/2026-09-06-hosted-release-gates.md`, GitHub Actions run
  `34079190997`)
- [x] CI-030 [ENG] Isolate PostgreSQL test databases or migration ledgers so
  immutable migration checks cannot inherit another test engine's state.
  (Evidence: `ops/rounds/2026-09-06-hosted-release-gates.md`, GitHub Actions
  run `34078811154`)
- [x] CI-040 [ENG] Make Apple application CI green on the release commit.
  (Evidence: exact-main GitHub Actions run `34080116658`)
- [x] CI-050 [ENG] Make Android build, unit, lint, and instrumentation CI green
  on the release commit. (Evidence: exact-main GitHub Actions run
  `34079190997`)
- [x] CI-060 [ENG] Make server lint, dependency, migration, database, backup,
  restore, and container CI green on the release commit. (Evidence: exact-main
  GitHub Actions run `34078811154`)
- [x] CI-070 [ENG] Keep Swift package, localization, health-claims, legal,
  privacy, dependency, and operations-record gates green. (Evidence:
  exact-main GitHub Actions runs `34078979831`, `34078811190`, `34078811160`,
  `34078979957`, `34078811177`, and `34078811154`)
- [ ] CI-080 [OWNER] Restore or fund hosted CI capacity sufficient for all
  required release gates.
- [x] CI-090 [OWNER] Enable protected `main` or an equivalent reviewed release
  control for the private repository. (Evidence: strict live branch protection
  with administrator enforcement, conversation resolution, linear history,
  ten app-bound required contexts, and no force-push or deletion bypass;
  `ops/rounds/2026-09-08-trusted-release-control-activation.md`)
- [x] CI-100 [ENG] Require every applicable release check before a production
  merge or tag. (Evidence: exact merged-main `10/10` verification on
  `d8cee4f6c2caaa5a2705c94a7985fc3ac5aae819`, custom protected-main check
  `101959809854`, four active tag rulesets, and enabled immutable releases;
  `ops/rounds/2026-09-08-trusted-release-control-activation.md`)
- [ ] CI-110 [ENG] Create separately approved staging and production
  environments in source control.
- [x] CI-120 [ENG] Create a release evidence directory and manifest format that
  contains no private data. (Evidence: `release/evidence/`,
  `Tools/release-evidence.py`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [x] CI-130 [ENG] Generate an SBOM and artifact provenance tied to one commit.
  (Evidence: exact-main GitHub Actions run `34084340375`, source commit
  `b5caec527496bb0eedbac27bf35eb9b1fa7fbf25`)
- [x] CI-140 [ENG] Verify dependency locks, pinned actions, container digests,
  and vulnerability policy. (Evidence: `Tools/release-control-gate.py`,
  `release/release-policy.json`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [x] CI-150 [ENG] Define build reproducibility checks for iOS, Android,
  firmware, server, and tools. (Evidence: `docs/RELEASE_CONTROLS.md`,
  `release/release-policy.json`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [x] CI-160 [ENG] Define rollback-compatible database and API migration rules.
  (Evidence: `docs/RELEASE_CONTROLS.md`, `release/release-policy.json`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [ ] CI-170 [ENG] Rotate every production-capable credential previously
  exposed in chat, logs, screenshots, or local scripts.
- [x] CI-180 [ENG] Verify no production credential, key, token, certificate, or
  private export is tracked by Git. (Evidence:
  `Tools/release-control-gate.py`, `Tools/check-private-data.py`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [x] CI-190 [ENG] Define release branch, tag, artifact, and hotfix naming.
  (Evidence: `docs/RELEASE_CONTROLS.md`, `release/release-policy.json`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [x] CI-200 [ENG] Record exact local and hosted commands required for the
  final release gate. (Evidence: `docs/RELEASE_CONTROLS.md`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)

## 3. NOOP Band hardware and protocol intake

- [ ] HW-010 [OWNER] Name the band hardware supplier, firmware owner, and
  escalation contacts.
- [ ] HW-020 [EXT] Deliver the exact MCU, BLE controller, BLE stack, and board
  revision specification.
- [ ] HW-030 [EXT] Deliver the complete sensor bill of materials and
  datasheets.
- [ ] HW-040 [EXT] Deliver flash, RAM, secure-storage, battery, charger, and
  power-tree specifications.
- [ ] HW-050 [EXT] Deliver the production GATT services, characteristics,
  permissions, and connection parameters.
- [ ] HW-060 [EXT] Deliver the packet envelope, command, event, live, history,
  clock, haptic, and error schemas.
- [ ] HW-070 [EXT] Deliver units, resolutions, sample rates, ranges, channel
  order, quality flags, and calibration coefficients for every sensor.
- [ ] HW-080 [EXT] Deliver the flash-history capacity, layout, cursor,
  acknowledgement, overflow, and factory-reset contract.
- [ ] HW-090 [EXT] Deliver the device-clock epoch or tick model, drift,
  reset/reboot, and invalid-clock behavior.
- [ ] HW-100 [EXT] Deliver per-unit identity, key provisioning, pairing,
  authentication, replay protection, and revocation design.
- [ ] HW-110 [EXT] Deliver secure boot, firmware signing, DFU, recovery,
  rollback, and anti-downgrade design.
- [ ] HW-120 [EXT] Deliver haptic limits, waveform support, command
  acknowledgement, and thermal/power constraints.
- [ ] HW-130 [EXT] Deliver on-wrist, off-wrist, charging, low-battery, thermal,
  and brownout state behavior.
- [ ] HW-140 [EXT] Deliver the manufacturing test, calibration, identity
  injection, key custody, and traceability interface.
- [ ] HW-150 [OWNER] Obtain at least three representative engineering units per
  hardware revision for parallel and destructive testing.
- [ ] HW-160 [OWNER] Obtain firmware builds, symbols, changelogs, known issues,
  and approved debug access.
- [ ] HW-170 [JOINT] Approve one versioned hardware/firmware input dossier.
- [x] HW-180 [ENG] Reject guessed production protocol behavior until the
  corresponding dossier section is approved. (Evidence:
  `Tools/terminology-audit.py`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)

## 4. Band firmware foundation

- [ ] FW-010 [ENG] Establish a reproducible firmware and bootloader build.
- [ ] FW-020 [ENG] Separate development, manufacturing, staging, and production
  signing and provisioning.
- [ ] FW-030 [ENG] Provision a unique identity and key material per band.
- [ ] FW-040 [ENG] Prevent use of one shared fleet authentication secret.
- [ ] FW-050 [ENG] Implement secure boot and production debug-lock policy.
- [ ] FW-060 [ENG] Implement authenticated pairing and ownership transfer.
- [ ] FW-070 [ENG] Implement capability and protocol-version negotiation.
- [ ] FW-080 [ENG] Implement calibrated sensor initialization and scheduling.
- [ ] FW-090 [ENG] Implement wear detection with measured false-on and
  false-off behavior.
- [ ] FW-100 [ENG] Implement off-wrist low-power behavior in firmware.
- [ ] FW-110 [ENG] Implement safe wake and full sampling restoration when worn.
- [ ] FW-120 [ENG] Implement local collection while no phone is connected.
- [ ] FW-130 [ENG] Implement durable flash history with explicit capacity and
  overflow behavior.
- [ ] FW-140 [ENG] Implement immutable chunk or record identity for retry-safe
  history.
- [ ] FW-150 [ENG] Advance history only after an authenticated durable
  acknowledgement.
- [ ] FW-160 [ENG] Implement device monotonic time and explicit wall-clock
  anchors.
- [ ] FW-170 [ENG] Implement drift reporting and safe clock correction.
- [ ] FW-180 [ENG] Implement live stream start, stop, mode, and backpressure.
- [ ] FW-190 [ENG] Implement battery, charge, wear, storage, reset, and fault
  status.
- [ ] FW-200 [ENG] Implement bounded haptic and alarm commands with explicit
  acknowledgements.
- [ ] FW-210 [ENG] Implement signed resumable OTA/DFU.
- [ ] FW-220 [ENG] Implement power-loss-safe activation and rollback or rescue.
- [ ] FW-230 [ENG] Reject wrong-board, corrupt, unsigned, stale, and
  downgraded firmware.
- [ ] FW-240 [ENG] Implement privacy-safe manufacturing and RMA diagnostics.
- [ ] FW-250 [ENG] Measure on-wrist, off-wrist, live, history, charging, and OTA
  power consumption.
- [ ] FW-260 [ENG] Meet the approved battery-life and thermal budgets.
- [ ] FW-270 [ENG] Pass firmware unit, fuzz, conformance, and hardware-in-loop
  gates.
- [ ] FW-280 [ENG] Define firmware support, critical-update, revocation, and
  end-of-life policy.

## 5. First-party NOOP Band SDK

- [ ] SDK-010 [ENG] Create the canonical versioned protocol and capability
  schema.
- [ ] SDK-020 [ENG] Create synthetic golden, malformed, replay, duplicate, and
  out-of-order protocol fixtures.
- [ ] SDK-030 [ENG] Implement device-neutral measured sample types with units,
  quality, calibration revision, device time, and provenance.
- [ ] SDK-040 [ENG] Implement pure Swift framing, integrity, decoding, clock,
  history, command, and update state machines.
- [ ] SDK-050 [ENG] Implement equivalent pure Kotlin state machines.
- [ ] SDK-060 [ENG] Prove Swift, Kotlin, and firmware agree on every golden
  fixture.
- [ ] SDK-070 [ENG] Implement a deterministic virtual band and virtual clock.
- [ ] SDK-080 [ENG] Add fault injection for packet loss, corruption,
  duplicates, disconnects, stale callbacks, full flash, bad clock, and low
  battery.
- [ ] SDK-090 [ENG] Add OTA interruption, verification failure, activation
  failure, and rollback simulation.
- [ ] SDK-100 [ENG] Build a protocol/conformance CLI without production
  credentials or private captures.
- [ ] SDK-110 [ENG] Implement one serialized CoreBluetooth session state
  machine.
- [ ] SDK-120 [ENG] Implement one serialized Android BLE session state machine.
- [ ] SDK-130 [ENG] Keep GATT objects and platform callbacks out of screens and
  analytics.
- [ ] SDK-140 [ENG] Implement durable store commit before history
  acknowledgement.
- [ ] SDK-150 [ENG] Implement idempotent resume from the last acknowledged
  range.
- [ ] SDK-160 [ENG] Expose connection, freshness, battery, wear, backlog,
  firmware, and capability state to the app.
- [ ] SDK-170 [ENG] Add bounded diagnostics for discovery, authentication,
  subscriptions, live progress, history, clock, commands, and OTA.
- [ ] SDK-180 [ENG] Prove SDK diagnostics exclude identifiers, payloads, raw
  health data, credentials, and arbitrary errors.
- [ ] SDK-190 [ENG] Document SDK APIs, compatibility policy, protocol versions,
  and integration examples.
- [ ] SDK-200 [ENG] Publish the firmware/Swift/Kotlin compatibility matrix.

## 6. Band claim, account, and plan onboarding

- [x] ACC-010 [JOINT] Freeze the activation boundary: app exploration, imports,
  local metrics, and exports remain available without NOOP+, a first-party band
  requires one ownership claim, and an activated band keeps working locally
  without a subscription or continuous network.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-020 [EXT] Obtain the supplier contract mapping the public identifier
  printed on each band to its opaque provisioned identity, hardware revision,
  and per-unit cryptographic material.
- [ ] ACC-030 [ENG] Treat the printed band number only as a discovery
  disambiguator, never as an authentication secret or ownership proof.
- [ ] ACC-040 [ENG] Require the band to be worn and explicitly in a
  time-bounded pairing mode with cancel, expiry, and rate-limit behavior.
- [ ] ACC-050 [ENG] Scan only eligible pairing-mode NOOP Bands and suppress
  stale, incompatible, already-bonded, or unsupported candidates.
- [ ] ACC-060 [ENG] Show only the minimum privacy-safe label characters needed
  for the user to match the discovered candidate to the number printed on the
  band.
- [ ] ACC-070 [ENG] Send the identify vibration only to the selected candidate
  and present clear retry, choose-another-band, and timeout actions.
- [ ] ACC-080 [ENG] Have firmware convert at least three deliberate taps inside
  the possession window into one debounced confirmation event; the apps must
  not count raw motion as taps.
- [ ] ACC-090 [ENG] Bind the confirmation event cryptographically to the exact
  band, app challenge, session, and expiry window.
- [ ] ACC-100 [ENG] Reject replay, stale confirmation, wrong-band responses,
  simultaneous-phone races, and confirmation outside pairing mode.
- [ ] ACC-110 [ENG] Provide matched no-band, multiple-band, wrong-number,
  vibration-missed, gesture-missed, Bluetooth-denied, offline, and retry states.
- [ ] ACC-120 [JOINT] Approve a concise ownership disclosure explaining that a
  successful claim binds the band to one account and describing all supported
  recovery and release paths.
- [x] ACC-130 [ENG] Require an explicit versioned `I agree` action before
  account creation or ownership claim; persist policy version, locale, and
  server time without storing the rendered copy in diagnostics.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [x] ACC-140 [ENG] Implement account creation and existing-account sign-in
  with email, password, and password confirmation where applicable using native
  password-manager and autofill support.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-150 [ENG] Verify the email address before final ownership claim and
  define safe resend, expiry, correction, and already-used-email behavior.
- [ ] ACC-160 [ENG] Keep mobile number optional; if supplied, verify it by OTP
  and support resend, expiry, attempt limits, country code, and number change.
- [x] ACC-170 [ENG] Use a managed identity provider and never store, proxy, or
  log plaintext passwords or OTPs in NOOP application databases or services.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-180 [ENG] Add password policy, breached-password controls where
  supported, rate limits, enumeration resistance, App Check/attestation, and
  abuse monitoring.
- [ ] ACC-190 [ENG] Implement password reset, email change, optional phone
  change, reauthentication, session rotation, sign-out, lost-phone recovery,
  and account recovery.
- [ ] ACC-200 [ENG] Give every identity, network, verification, consent, and
  claim failure a private actionable state without revealing another account.
- [x] ACC-210 [ENG] Implement an atomic backend claim that links one opaque
  account tenant to one provisioned band identity.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-220 [ENG] Require valid app attestation and a fresh band-signed
  possession challenge before the claim transaction can commit.
- [x] ACC-230 [ENG] Make claim creation idempotent and concurrency-safe so two
  phones or accounts cannot both succeed.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [x] ACC-240 [ENG] Return the same privacy-preserving already-claimed response
  regardless of the current owner's identity or account state.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-250 [ENG] Recover safely when account creation, server claim, band
  provisioning, local persistence, or final acknowledgement succeeds only
  partially.
- [ ] ACC-260 [ENG] Provision owner-scoped band credentials only after the
  durable claim and bind them to protocol and firmware versions.
- [ ] ACC-270 [ENG] Store local account and band credentials only in
  Keychain/Keystore-backed storage and rotate or revoke them independently.
- [ ] ACC-280 [ENG] Ensure a successfully activated band continues collecting,
  backfilling, scoring, exporting, and accepting supported local controls
  during account-service or network outages.
- [ ] ACC-290 [ENG] On a replacement phone, require sign-in to the same account,
  fresh physical possession proof, and installation authorization without
  creating a second ownership claim.
- [x] ACC-300 [ENG] Let the owner revoke a lost or replaced phone installation
  without deleting band history or disabling other authorized installations.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-310 [JOINT] Disclose before purchase and claim that v1 has no general
  self-service unpair or transfer and remains bound to the claiming account for
  its ordinary lifetime, subject only to approved operator and legal exits.
- [ ] ACC-320 [EXT] Obtain India and USA consumer, warranty, privacy, account
  deletion, and transfer review for the ownership-lock policy.
- [ ] ACC-330 [ENG] Implement support-controlled release for returns, RMA,
  replacement, account recovery, verified disputes, fraud handling, recycling,
  and other legally required cases.
- [ ] ACC-340 [ENG] Make account deletion erase personal data without exposing
  user-facing unpair: the v1 band must enter the approved retired, wiped, or
  operator-recovery state, and ownership lock must never block a deletion right.
- [ ] ACC-350 [ENG] Only after an eligible successor NOOP Band is released, add
  an upgrade flow that reauthenticates the owner, proves possession,
  permanently releases the old band, and records the release before another
  account can claim it.
- [ ] ACC-360 [ENG] On approved release, revoke owner keys and sessions, remove
  personal state from the band, preserve only required bounded anti-replay
  records, and prove factory-ready state.
- [ ] ACC-370 [JOINT] Define proof-of-purchase, stolen-band, inheritance,
  chargeback, closed-account, and ownership-dispute procedures.
- [x] ACC-380 [ENG] Add additive schemas for accounts, bands, claims,
  ownership events, installations, challenges, releases, and entitlement state
  without storing raw health data in the ownership control plane.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-390 [ENG] Prove tenant isolation, least-privilege support access,
  immutable security audit, backup/PITR, restoration, retention, and erasure
  for the ownership control plane.
- [ ] ACC-400 [ENG] Add bounded lifecycle evidence for discovery, selection,
  vibration, possession confirmation, consent, identity, claim, provisioning,
  conflict, recovery, and release without identifiers or payloads.
- [x] ACC-410 [ENG] Show the NOOP versus NOOP+ chooser after remaining
  onboarding and before the first Home presentation on Apple and Android.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [x] ACC-420 [ENG] Let NOOP continue immediately without payment while keeping
  every core local metric, workout, Journal, Coach, automation, backup, and
  export promised for the free product.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [x] ACC-430 [ENG] Give NOOP+ a restrained gold mark and highlight with text,
  shape, contrast, screen-reader labels, and non-color selection state.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [x] ACC-440 [ENG] Until billing is approved, render NOOP+ payment as clearly
  unavailable or coming later; do not open a fake checkout, collect payment, or
  grant an entitlement.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-450 [OWNER] Select India hardware checkout, Apple/Google digital
  subscription billing, gateway, tax, refund, receipt, renewal, and support
  ownership before enabling payment.
- [x] ACC-460 [ENG] Keep band ownership separate from NOOP+ entitlement so
  cancellation, payment failure, or downgrade never deactivates the band or
  removes core local capability.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [x] ACC-470 [ENG] Let users inspect and change plan later from a stable
  account destination without repeating pairing or base onboarding.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [x] ACC-480 [ENG] Resume the remaining existing initial pages after a claim,
  persist each completion boundary idempotently, and never strand a user after
  process death or network loss.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-06)
- [ ] ACC-490 [ENG] Pass virtual-band, backend, Apple, Android, accessibility,
  two-phone/two-account race, offline, recovery, support-release, and
  representative physical-band end-to-end matrices.
- [ ] ACC-500 [OWNER] Select 14 or 30 calendar days for voluntary returns.
- [ ] ACC-510 [JOINT] Define whether the return clock begins at order,
  shipment, delivery, activation, or another legally approved event in each
  market.
- [ ] ACC-520 [JOINT] Define unopened, opened, paired, worn, defective,
  incorrect-item, damaged-in-transit, warranty, and change-of-mind eligibility.
- [ ] ACC-530 [EXT] Obtain India and USA legal review of the return window,
  exclusions, inspection, condition deductions, refund timing, and appeals.
- [ ] ACC-540 [ENG] Implement an authenticated return request with order lookup,
  eligibility result, return authorization, shipping instructions, status, and
  support escalation.
- [ ] ACC-550 [ENG] Define a repeatable condition inspection for cosmetic
  marks, structural damage, missing accessories, hygiene, battery, radio,
  sensors, and tamper state using privacy-safe evidence.
- [ ] ACC-560 [JOINT] Publish an objective condition-grade and refund-deduction
  schedule before purchase; distinguish ordinary inspection, manufacturing
  defect, transit damage, customer damage, and normal wear.
- [ ] ACC-570 [ENG] Apply only lawful disclosed deductions to the refund through
  the original payment rail, issue an itemized decision, and provide a bounded
  appeal path; never create an undisclosed post-return charge.
- [ ] ACC-580 [ENG] On accepted return or RMA, use an operator-only workflow to
  revoke owner credentials, wipe personal band state, remove the account link,
  and quarantine, refurbish, reprovision, or destroy the unit.
- [ ] ACC-590 [ENG] Store every Terms and Conditions version as an immutable,
  content-addressed, locale-specific document and signed manifest in
  NOOP-controlled object storage.
- [x] ACC-600 [ENG] Fetch terms over authenticated TLS with an ephemeral,
  no-persistent-cache client; do not bundle or write the full terms document to
  the app container, preferences, database, diagnostics, or report archive.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [x] ACC-610 [ENG] Fail claim closed if the exact terms version cannot be
  fetched or verified, and retain server-side acceptance evidence containing
  only account scope, document version/hash, locale, policy version, and time.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-620 [ENG] Retain every accepted historical terms version remotely,
  expose its public immutable URL, and require reacceptance only under a
  reviewed version/effective-date policy.
- [ ] ACC-630 [ENG] Make the remotely loaded terms readable without login on
  the public website and accessible in-app with screen readers, text scaling,
  localization, copy/share, and an explicit return to the claim flow.
- [x] ACC-640 [ENG] Render only sanitized static terms content with no arbitrary
  script, third-party tracker, advertising, fingerprinting, or credential
  capture.
  (Evidence:
  `ops/rounds/2026-09-05-ownership-account-foundation.md`, 2026-09-05)
- [ ] ACC-650 [ENG] Add version, integrity, availability, latency, publication,
  rollback, and acceptance monitoring without logging document contents,
  account identifiers, contact data, or band identifiers.
- [ ] ACC-660 [ENG] Test terms outage/tamper/version races and the complete
  return, inspection, deduction, refund, appeal, operator wipe, and
  reconditioning matrix on Apple, Android, backend, and operations tooling.

## 7. Terminology, identity, and existing-data migration

- [x] MIG-010 [ENG] Generate a tracked classification of every legacy-name
  occurrence. (Evidence: `release/terminology/legacy-inventory.json`,
  `Tools/terminology-audit.py`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] MIG-020 [JOINT] Approve categories for customer, core, persisted, import,
  compatibility, legal, fixture, generated, and historical references.
- [x] MIG-030 [ENG] Create a machine-readable exception allowlist with reason,
  owner, and removal condition. (Evidence:
  `release/terminology/active-allowlist.json`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] MIG-040 [ENG] Fail CI on every new unapproved customer or core reference.
  (Evidence: `Tools/terminology-audit.py`,
  `.github/workflows/release-controls.yml`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] MIG-050 [ENG] Stop displaying the seeded legacy source as a first-party
  NOOP Band. (Evidence: `Packages/WhoopStore/Sources/WhoopStore/PairedDevice.swift`,
  `Strand/BLE/WhoopModel.swift`,
  `android/app/src/main/java/com/noop/ble/WhoopModel.kt`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] MIG-060 [ENG] Introduce neutral stream, store, repository, device, and
  protocol abstractions.
- [ ] MIG-070 [ENG] Give each first-party band a new opaque local identity.
- [ ] MIG-080 [ENG] Never reuse `my-whoop` or another legacy ID for a
  first-party band.
- [ ] MIG-090 [ENG] Write only neutral identities for newly paired NOOP Bands.
- [ ] MIG-100 [ENG] Continue reading old source IDs without relabeling their
  provenance.
- [ ] MIG-110 [ENG] Rename active Swift packages and types through compatible
  forwarding boundaries.
- [ ] MIG-120 [ENG] Rename active Android classes, resources, generated schema
  ownership, and product code through compatible boundaries.
- [ ] MIG-130 [ENG] Migrate the Apple database directory and filename through a
  cold-open, integrity-checked, rollback-capable path.
- [ ] MIG-140 [ENG] Migrate the Android database filename without destructive
  fallback.
- [ ] MIG-150 [ENG] Preserve SQLite sidecars and never replace a non-empty
  destination.
- [ ] MIG-160 [ENG] Version backups, portable exports, managed manifests,
  widgets, Live Activities, Watch payloads, and source namespaces.
- [ ] MIG-170 [ENG] Retain readers for every supported old format.
- [ ] MIG-180 [ENG] Add oldest-supported Apple database upgrade fixtures.
- [ ] MIG-190 [ENG] Add every supported Android Room schema upgrade fixture.
- [ ] MIG-200 [ENG] Add old backup, managed snapshot, widget, Watch, and
  interrupted-migration fixtures.
- [ ] MIG-210 [ENG] Prove low-storage, process-death, corrupt-candidate,
  rollback, and retry behavior.
- [ ] MIG-220 [ENG] Preserve truthful external import/export provenance and
  required legal notices.
- [ ] MIG-230 [ENG] Isolate or remove the direct legacy adapter only after NOOP
  Band physical parity.
- [ ] MIG-240 [ENG] Reach zero unallowlisted customer and active-core matches.

## 8. Apple and Android product experience

- [ ] MOB-010 [ENG] Build matched first-run NOOP Band education on Apple and
  Android.
- [ ] MOB-020 [ENG] Build matched discovery, secure pairing, and pairing
  recovery.
- [ ] MOB-030 [ENG] Build ownership transfer, replacement-band, unpair, and
  factory-reset guidance.
- [ ] MOB-040 [ENG] Show truthful connection, authentication, subscription,
  live, history, and error states.
- [ ] MOB-050 [ENG] Show battery, charging, wear, storage, backlog, firmware,
  and capability state.
- [x] MOB-060 [ENG] Show sync progress briefly without blocking normal app use.
  (Evidence: `Strand/BLE/LiveState.swift`,
  `StrandTests/HistorySyncProgressTests.swift`,
  `android/app/src/main/java/com/noop/ble/BackfillBurstProgress.kt`,
  `android/app/src/test/java/com/noop/ble/BackfillBurstProgressTest.kt`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] MOB-070 [ENG] Continue eligible history work in the background and
  disclose OS limits honestly.
- [ ] MOB-080 [ENG] Distinguish no history, completed-empty history,
  interrupted history, retry, timeout, and durable-progress stall.
- [ ] MOB-090 [ENG] Integrate live and history data through one
  provenance-aware store path.
- [ ] MOB-100 [ENG] Prevent duplicate rows, wrong-day ownership, and clock
  discontinuities.
- [ ] MOB-110 [ENG] Build firmware update eligibility, deferral, progress,
  interruption, retry, activation, and rollback UI.
- [ ] MOB-120 [ENG] Keep the app useful while firmware update is unavailable or
  deferred.
- [ ] MOB-130 [ENG] Integrate haptics and alarms only when negotiated
  capabilities permit them.
- [ ] MOB-140 [ENG] Implement low-battery, off-wrist, charging, and thermal
  messaging.
- [ ] MOB-150 [ENG] Validate workout start, tracking explanation, caution,
  haptic, finish, and recovery flows.
- [ ] MOB-160 [ENG] Validate every metric card and detail route against actual
  NOOP Band capabilities.
- [x] MOB-170 [ENG] Ensure a calendar day shows category-relevant detail rather
  than the same aggregate panel everywhere. (Evidence:
  `Strand/Screens/CalendarMonthView.swift`,
  `StrandTests/WorkoutEffortCellTests.swift`,
  `android/app/src/main/java/com/noop/ui/CalendarMonthScreen.kt`,
  `android/app/src/test/java/com/noop/ui/CalendarMonthPresentationTest.kt`,
  `StrandTests/ScreenStateContractTests.swift`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] MOB-180 [ENG] Ensure bottom navigation returns from nested metric and
  calendar routes correctly. (Evidence:
  `StrandiOS/App/RootTabView.swift`,
  `android/app/src/main/java/com/noop/ui/AppRoot.kt`,
  `android/app/src/test/java/com/noop/ui/PrimaryNavigationContractTest.kt`,
  `android/app/src/androidTest/java/com/noop/ui/AppShellInstrumentedTest.kt`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] MOB-190 [ENG] Audit every screen, modal, empty state, error state, and
  loading state for Apple/Android behavioral parity.
- [ ] MOB-200 [ENG] Audit Apple/Android visual parity with platform-appropriate
  glass, controls, safe areas, and status bars.
- [ ] MOB-210 [ENG] Verify no text clips, overlaps, becomes opaque incorrectly,
  or falls behind floating controls.
- [ ] MOB-220 [ENG] Complete VoiceOver, TalkBack, Dynamic Type, font scaling,
  contrast, reduced motion, and touch-target review.
- [ ] MOB-230 [ENG] Complete orientation, small-screen, tablet, foldable, and
  large-screen layout review where supported.
- [ ] MOB-240 [ENG] Complete localization extraction and native-speaker review
  for every launch locale.
- [ ] MOB-250 [ENG] Ensure notification settings use consistent enabled,
  disabled, permission, and unavailable states.
- [ ] MOB-260 [ENG] Validate morning, evening, stress, workout, hydration,
  breathing, sleep, Journal, and update notifications against explicit opt-ins
  and evidence gates.
- [ ] MOB-270 [ENG] Validate shake-to-report during lag, collection, history,
  OTA, storage pressure, and managed sync.
- [x] MOB-280 [ENG] Ensure app reports show optional user context and reviewed
  attachments without automatic upload. (Evidence:
  `StrandiOS/System/ShakeDiagnosticReport.swift`,
  `android/app/src/main/java/com/noop/ui/AppDiagnosticReport.kt`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [x] MOB-290 [ENG] Add a disclosed isolated Review Sample Mode for store
  reviewers without hardware. (Evidence:
  `StrandiOS/App/ReviewSampleMode.swift`,
  `android/app/src/main/java/com/noop/ui/ReviewSampleMode.kt`,
  `NOOPiOSUITests/NOOPiOSUITests.swift`,
  `android/app/src/androidTest/java/com/noop/ui/ReviewSampleInstrumentedTest.kt`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] MOB-300 [ENG] Ensure Review Sample Mode never touches BLE, production
  storage, health stores, cloud, Friends, notifications, or Safety. (Evidence:
  the sample presentation trees contain no operational dependencies or
  persistence/network tasks; Android defers Room, BLE, cloud, and workers until
  current Terms are accepted, removes WorkManager's pre-application AndroidX
  Startup initializer, and proves on API 35 that WorkManager stays
  uninitialized through sample exit to Terms; Apple starts `AppModel` with
  operational work disabled and never writes sample values to its constructed
  inert bootstrap objects; source contracts, focused simulator/device tests,
  and Release builds are recorded in
  `ops/rounds/2026-09-07-production-readiness-execution.md`)

## 9. Storage, performance, backup, and recovery

- [ ] DAT-010 [JOINT] Approve local raw, essential time-series, aggregate,
  user-authored, and backup retention rules.
- [ ] DAT-020 [ENG] Keep compact derived and user-authored records local for
  their documented lifetime.
- [ ] DAT-030 [ENG] Bound raw frames and high-rate sample retention.
- [x] DAT-040 [ENG] Prune managed windows only after exact server validation.
  (Evidence: `ops/rounds/2026-09-05-noop-plus-live-staging.md`,
  `Tools/Backfill/HISTORY-HARNESS.md`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] DAT-050 [ENG] Never prune dirty, changed, partial, failed, or unverified
  data. (Evidence: `ops/rounds/2026-09-05-noop-plus-live-staging.md`,
  `Tools/Backfill/HISTORY-HARNESS.md`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] DAT-060 [ENG] Generate worst-case 10-, 30-, 90-, and 365-day datasets.
  (Evidence: `Tools/Backfill/`,
  `validation/HISTORY-HARNESS-2026-09-07.json`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] DAT-070 [ENG] Measure database, WAL, backup, temporary, and available
  storage across those datasets. (Evidence:
  `validation/HISTORY-HARNESS-2026-09-07.json`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] DAT-080 [ENG] Measure cold launch, scrolling, calendar, metrics, analysis,
  sync, backup, export, and restore latency.
- [ ] DAT-090 [ENG] Measure process memory, background survival, thermal state,
  and battery impact during normal and backlog work.
- [ ] DAT-100 [ENG] Define and enforce release performance and resource
  budgets.
- [ ] DAT-110 [ENG] Profile before changing indexes, compaction, retention, or
  query architecture.
- [ ] DAT-120 [ENG] Preserve collector write throughput during reads, analysis,
  export, backup, and backfill.
- [ ] DAT-130 [ENG] Prove low-storage and full-disk behavior without silent
  loss.
- [ ] DAT-140 [ENG] Prove WAL growth, corruption, failed migration, process
  death, and concurrent read/write recovery.
- [x] DAT-150 [ENG] Complete same-platform backup and restore for the final
  schema. (Evidence: `StrandTests/BackupSyncRoundTripTests.swift`,
  `android/app/src/main/java/com/noop/data/DataBackup.kt`,
  `Tools/Backfill/`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] DAT-160 [ENG] Complete portable Apple-to-Android and Android-to-Apple
  import for documented data classes.
- [ ] DAT-170 [ENG] Complete managed-history export, resume, corruption
  rejection, expiry, and import.
- [ ] DAT-180 [ENG] Verify existing local data survives every signed app
  upgrade and band replacement.

## 10. Sensor and metric evidence

- [ ] MET-010 [JOINT] Approve a preregistered validation protocol and frozen
  metric revisions.
- [ ] MET-020 [EXT] Recruit representative participants with informed consent
  and privacy controls.
- [ ] MET-030 [ENG] Validate timestamps, units, quality flags, calibration,
  gaps, duplicates, and loss for every sensor.
- [ ] MET-040 [ENG] Validate HR against approved references across rest, sleep,
  exercise, motion, fit, sweat, temperature, and battery states.
- [ ] MET-050 [ENG] Validate R-R intervals and HRV coverage/error against
  approved references.
- [ ] MET-060 [ENG] Validate wear detection and off-wrist suppression.
- [ ] MET-070 [ENG] Validate accelerometer/gyro axes, scale, cadence, clipping,
  and timestamp alignment.
- [ ] MET-080 [ENG] Validate SpO2 only against an approved protocol or keep the
  result unavailable.
- [ ] MET-090 [ENG] Validate skin/body temperature only for its exact displayed
  claim or keep it unavailable.
- [ ] MET-100 [ENG] Validate respiration input and derived presentation.
- [ ] MET-110 [ENG] Validate sleep interval detection.
- [ ] MET-120 [ENG] Validate sleep stages against the approved reference
  protocol with held-out participants and devices.
- [ ] MET-130 [ENG] Validate workout detection precision, recall, latency,
  confusion matrix, and false prompts per day.
- [x] MET-140 [ENG] Keep automatic workout detection in Ask mode until its
  unattended-save evidence passes. (Evidence:
  `Strand/BLE/PuffinExperiment.swift`,
  `android/app/src/main/java/com/noop/ui/MainActivity.kt`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [ ] MET-150 [ENG] Validate steps, daily movement, standing, and activity
  classification.
- [ ] MET-160 [ENG] Validate Charge, Effort, Rest, stress, and related
  dependency behavior.
- [ ] MET-170 [ENG] Validate Fitness Age, Vitality, and Wellness Age only as
  transparent wellness estimates.
- [x] MET-180 [ENG] Require sufficient tracking history and bounded weekly
  changes before longitudinal age movement. (Evidence:
  `Packages/StrandAnalytics/Sources/StrandAnalytics/FitnessAgeEngine.swift`,
  `Strand/Data/IntelligenceEngine.swift`,
  `android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] MET-190 [ENG] Prevent unsupported abrupt multi-year age changes.
  (Evidence:
  `Packages/StrandAnalytics/Sources/StrandAnalytics/FitnessAgeEngine.swift`,
  `android/app/src/test/java/com/noop/analytics/FitnessAgeEngineTest.kt`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] MET-200 [ENG] Audit every metric dependency when a sensor is missing,
  stale, changed, imported, or replaced.
- [ ] MET-210 [ENG] Ensure related calendar, Coach, notification, export, and
  trend views use the same missing-data contract.
- [ ] MET-220 [ENG] Publish confidence, coverage, provenance, known failure,
  subgroup, and revision limitations.
- [x] MET-230 [ENG] Define safe reprocessing and metric rollback rules.
  (Evidence: `METRIC_REPROCESSING_AND_ROLLBACK.md`,
  `release/release-policy.json`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] MET-240 [EXT] Obtain independent statistical and claims review.

## 11. NOOP+ production services, if enabled

- [ ] CLD-010 [OWNER] Confirm the GCP organization, billing owner, launch
  regions, and data-residency policy.
- [ ] CLD-020 [ENG] Separate development, staging, and production projects,
  identities, networks, data, and secrets.
- [ ] CLD-030 [ENG] Provision production through reviewed, digest-pinned IaC.
- [ ] CLD-040 [ENG] Establish production domain, DNS, TLS, WAF, and rate
  limiting.
- [ ] CLD-050 [ENG] Enable public ingress only through authenticated,
  abuse-controlled routes.
- [ ] CLD-060 [ENG] Prove Firebase phone identity, App Check/attestation,
  installation credentials, rotation, revocation, and recovery on signed
  physical clients.
- [ ] CLD-070 [ENG] Complete explicit versioned health-data consent and
  withdrawal.
- [ ] CLD-080 [ENG] Prove immutable chunk validation, idempotency, quotas,
  isolation, processing, restore, and erasure.
- [ ] CLD-090 [ENG] Operate HA PostgreSQL with bounded pools and tested PITR.
- [ ] CLD-100 [ENG] Test object recovery, queue recovery, KMS, secret rotation,
  and region/cell failure.
- [ ] CLD-110 [ENG] Define retention, lifecycle, deletion, support access, and
  audit controls.
- [ ] CLD-120 [ENG] Define dashboards, SLOs, alerts, log retention/access, cost
  budgets, and on-call.
- [ ] CLD-130 [ENG] Run incident, restore, secret-compromise, and deletion
  game days.
- [ ] CLD-140 [ENG] Load-test enrollment, reconnect bursts, upload, processing,
  restore, export, and mixed workloads.
- [ ] CLD-150 [ENG] Prove launch capacity and the documented 10,000-user target
  with a scaling plan beyond it.
- [ ] CLD-160 [ENG] Add production HTTPS universal and Android app links.
- [ ] CLD-170 [ENG] Implement opaque minimal APNs/FCM wake delivery with token
  lifecycle and abuse controls.
- [ ] CLD-180 [ENG] Prove closed-app push delivery and deletion on physical
  Apple and Android devices.
- [ ] CLD-190 [ENG] Prove NOOP+ OTP delivery, rate limits, retries, recovery,
  and support using controlled numbers.
- [ ] CLD-200 [ENG] Prove Friends invite, consent, six-field sharing, remove,
  block, delete, badges, pokes, push, and eligible haptics.
- [ ] CLD-210 [ENG] Add Friends abuse reporting, support, throttling, and
  incident operations before broader discovery.
- [ ] CLD-220 [EXT] Complete country-specific sender, template, carrier, and
  provider registration for the optional SMS/voice Safety fallback.
- [ ] CLD-230 [ENG] Prove SMS, voice, DTMF, callback, retry,
  cancellation, provider failover, worker restart, and all-contact failure.
- [x] CLD-240 [OWNER] Keep NOOP+ health-data storage and SMS/voice paging
  fallback disabled until their applicable gates are complete. Managed
  app-to-app Safety paging may ship only after opaque push delivery, signed
  physical-phone validation, security/legal review, monitoring, failover, and
  staffed operations pass. (Evidence:
  `ops/rounds/2026-09-07-launch-owner-decisions.md`,
  `ops/rounds/2026-09-08-managed-app-safety-paging.md`)

## 12. Security, privacy, legal, and certification

- [ ] SEC-010 [JOINT] Complete hardware, firmware, BLE, mobile, cloud,
  manufacturing, account, Friends, OTA, and Safety threat models.
- [ ] SEC-020 [ENG] Resolve every launch-severity threat-model action.
- [ ] SEC-030 [EXT] Run independent band/firmware security assessment.
- [ ] SEC-040 [EXT] Run independent mobile/API/cloud penetration testing.
- [ ] SEC-050 [ENG] Remediate and retest every release-severity finding.
- [x] SEC-060 [ENG] Define key generation, custody, access, backup, rotation,
  compromise, revocation, and destruction. (Evidence: `KEY_MANAGEMENT.md`,
  `release/release-policy.json`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [x] SEC-070 [ENG] Define coordinated vulnerability disclosure and security
  update policy. (Evidence: `../SECURITY.md`, `SECURITY_OPERATIONS.md`,
  `release/release-policy.json`,
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] SEC-080 [EXT] Complete trademark and product-name review.
- [ ] SEC-090 [EXT] Complete launch-market privacy, consumer-health,
  cross-border, processor, and breach analysis.
- [ ] SEC-100 [JOINT] Publish accurate privacy, consent, access, correction,
  export, erasure, grievance, and support policies.
- [ ] SEC-110 [JOINT] Complete data-processing, manufacturing, cloud, carrier,
  support, and subprocessors contracts.
- [ ] SEC-120 [EXT] Complete BIS registration for the production design where
  required.
- [ ] SEC-130 [EXT] Complete WPC/ETA approval for the production radio where
  required.
- [ ] SEC-140 [EXT] Complete FCC authorization for the production design where
  required.
- [ ] SEC-150 [EXT] Complete Bluetooth SIG membership and product
  qualification.
- [ ] SEC-160 [EXT] Complete UN38.3 battery transport evidence.
- [ ] SEC-170 [EXT] Complete IEC 62133 and other applicable battery/product
  safety evidence.
- [ ] SEC-180 [EXT] Complete RoHS, REACH, recycling, labeling, and
  market-specific compliance.
- [ ] SEC-190 [JOINT] Review app, store, packaging, notifications, support, and
  marketing claims for general-wellness accuracy.
- [x] SEC-200 [ENG] Keep all clinical and automatic emergency claims disabled
  unless separately authorized. (Evidence: `server/app/main.py`,
  `Tools/health_claims_gate.py`,
  `ops/rounds/2026-09-07-production-checklist-execution.md`)
- [ ] SEC-210 [ENG] Pass exact release SBOM, license, dependency notice, owner
  rights, and distribution gates.

## 13. Manufacturing, fulfillment, and support

- [ ] OPS-010 [EXT] Qualify pilot and production manufacturers.
- [ ] OPS-020 [EXT] Approve golden units, test limits, calibration, yield, and
  traceability.
- [ ] OPS-030 [JOINT] Define component and firmware change control after
  validation.
- [ ] OPS-040 [EXT] Run a production-representative pilot build.
- [ ] OPS-050 [ENG] Analyze pilot yield, calibration, power, radio, sensor,
  flash, provisioning, and update results.
- [ ] OPS-060 [EXT] Complete packaging, labels, regulatory marks, inserts, and
  battery shipping preparation.
- [ ] OPS-070 [OWNER] Complete SKU, inventory, customs/import, fulfillment, and
  returns operations.
- [ ] OPS-080 [OWNER] Approve warranty, refund, replacement, repair, and RMA
  policies.
- [ ] OPS-090 [ENG] Prove replacement-band pairing and user-data continuity.
- [ ] OPS-100 [ENG] Define lost/stolen-band revocation and replacement.
- [ ] OPS-110 [JOINT] Define recycling, disposal, recall, and safety escalation.
- [ ] OPS-120 [ENG] Publish setup, fit, charging, cleaning, troubleshooting,
  privacy, export, deletion, and firmware-update support content.
- [ ] OPS-130 [ENG] Train support to use privacy-safe reports without requesting
  raw databases, health exports, or credentials.
- [ ] OPS-140 [ENG] Define firmware rollout rings, halt criteria, minimum
  supported version, rollback, and critical updates.
- [ ] OPS-150 [ENG] Rehearse app, backend, firmware, key, carrier, and product
  incident response.
- [ ] OPS-160 [OWNER] Staff launch support and on-call coverage.

## 14. Signing and storefront preparation

- [ ] STO-010 [OWNER] Confirm paid Apple organization membership, agreements,
  tax, banking, and App Store Connect roles.
- [ ] STO-020 [ENG] Verify Apple identifiers and capabilities for the app,
  widgets, Watch app, complications, HealthKit, and App Group.
- [ ] STO-030 [OWNER] Create or renew Apple Distribution certificates and App
  Store profiles through approved custody.
- [ ] STO-040 [ENG] Produce and validate the signed Apple archive.
- [ ] STO-050 [OWNER] Confirm Google Play organization, agreements, merchant,
  tax, and role access.
- [ ] STO-060 [OWNER] Create and protect the Android upload key and Play App
  Signing identity.
- [ ] STO-070 [ENG] Produce and validate the signed Android App Bundle.
- [ ] STO-080 [ENG] Prove in-place upgrade from every supported installed build
  without clearing data.
- [ ] STO-090 [JOINT] Complete App Privacy and Google Data Safety from the exact
  release artifacts.
- [ ] STO-100 [JOINT] Complete encryption/export, wellness/medical, age/content,
  category, territory, trader, contact, copyright, and pricing answers.
- [ ] STO-110 [OWNER] Provide monitored review contact and support channels.
- [x] STO-120 [ENG] Keep public privacy and support URLs available without
  authentication. (Evidence:
  `ops/rounds/2026-09-07-production-checklist-execution.md`, anonymous HTTP
  200 checks on 2026-09-07)
- [ ] STO-130 [ENG] Capture final iPhone media from the exact signed release
  candidate using fictional data.
- [ ] STO-140 [ENG] Capture final iPad media or deliberately remove unsupported
  iPad availability.
- [ ] STO-150 [ENG] Capture final Apple Watch media.
- [ ] STO-160 [ENG] Capture final Android phone, tablet, and other declared
  device-class media.
- [ ] STO-170 [JOINT] Review every image and video for privacy, rights,
  identifiers, claims, status bars, safe areas, and current UI.
- [ ] STO-180 [ENG] Record a sanitized reviewer video for hardware setup and
  truthful unavailable states.
- [ ] STO-190 [ENG] Provide the disclosed Review Sample Mode path and private
  review information. (Source path complete on Apple and Android; exact signed
  archive/AAB exercise, sanitized reviewer video, and private App Review/store
  console information remain pending. Evidence:
  `ops/rounds/2026-09-07-production-readiness-execution.md`)
- [ ] STO-200 [JOINT] Approve final names, descriptions, keywords, release
  notes, screenshots, limitations, and support copy.
- [ ] STO-210 [OWNER] Keep first storefront release under manual release
  control.

## 15. Signed private release-candidate validation

- [ ] RC-010 [ENG] Freeze one app, firmware, protocol, schema, metric, and
  backend compatibility manifest.
- [ ] RC-020 [ENG] Install signed RCs without clearing existing data.
- [ ] RC-030 [ENG] Test clean installation and empty/no-hardware experience.
- [ ] RC-040 [ENG] Test upgrade from every supported local schema and app
  version.
- [ ] RC-050 [ENG] Test multiple production-representative bands from different
  pilot lots.
- [ ] RC-060 [ENG] Test current and oldest-supported iPhone/iOS combinations.
- [ ] RC-070 [ENG] Test Pixel, Samsung, and at least one aggressive
  background-policy Android OEM per launch market.
- [ ] RC-080 [ENG] Test current and oldest-supported Android versions.
- [ ] RC-090 [ENG] Test foreground, screen-off, locked, backgrounded, OS-killed,
  force-stopped, rebooted, Bluetooth-off, and airplane-mode states.
- [ ] RC-100 [ENG] Test low-power mode, battery saver, thermal pressure, memory
  pressure, and low/full storage.
- [ ] RC-110 [ENG] Test on-wrist, off-wrist, loose fit, charging, low battery,
  band reboot, and clock reset.
- [ ] RC-120 [ENG] Test flash empty, near-full, full, overflow, long backlog,
  corrupt chunk, duplicate, and interrupted acknowledgement.
- [ ] RC-130 [ENG] Test timezone, DST, travel, phone clock change, and band
  drift.
- [ ] RC-140 [ENG] Test live HR/R-R and every supported sensor capability.
- [ ] RC-150 [ENG] Test haptics, alarms, workouts, notifications, Watch,
  HealthKit, and Health Connect.
- [ ] RC-160 [ENG] Test backup, export, import, restore, erasure, band
  replacement, and phone replacement.
- [ ] RC-170 [ENG] Test OTA success, pause, disconnect, app kill, phone reboot,
  low battery, corrupt image, wrong board, signature failure, activation
  failure, and rollback.
- [ ] RC-180 [ENG] Complete at least one 24-hour continuous collection run.
- [ ] RC-190 [ENG] Complete multi-day phone-absence and history-recovery runs.
- [ ] RC-200 [ENG] Complete a 30-day storage, collection, battery, and
  reliability soak.
- [ ] RC-210 [ENG] Validate NOOP+ install, enrollment, consent, background sync,
  restore, revoke, export, and deletion if enabled.
- [ ] RC-220 [ENG] Validate Friends and push/haptic journeys between two
  physical users if enabled.
- [ ] RC-230 [ENG] Validate controlled real-carrier OTP and paging journeys if
  enabled.
- [ ] RC-240 [ENG] Review every diagnostic attachment before sharing and
  confirm privacy boundaries.
- [ ] RC-250 [JOINT] Run private TestFlight and Play internal release-candidate
  testing.
- [ ] RC-260 [ENG] Fix every release-blocking report and repeat affected
  matrices.
- [ ] RC-270 [JOINT] Reach zero open release-severity defects.
- [ ] RC-280 [ENG] Archive generalized evidence without raw health data or
  personal identifiers.

## 16. Final go-live and post-launch

- [ ] LCH-010 [JOINT] Verify every applicable checklist point has evidence or a
  documented superseding decision.
- [ ] LCH-020 [JOINT] Hold final product, engineering, hardware, firmware,
  security, privacy, legal, manufacturing, support, and release go/no-go.
- [ ] LCH-030 [OWNER] Reject undocumented waivers for physical, security,
  privacy, legal, signing, carrier, or certification gates.
- [ ] LCH-040 [ENG] Tag the exact source commit and archive checksums, SBOM,
  schemas, compatibility manifests, and rollback versions.
- [ ] LCH-050 [ENG] Pin and record the exact production firmware and backend
  digests.
- [ ] LCH-060 [ENG] Verify production dashboards, alerts, SLOs, costs, backups,
  restore, status, support, and on-call.
- [ ] LCH-070 [ENG] Verify storefront artifacts are the exact signed RCs.
- [ ] LCH-080 [OWNER] Release manually, with staged storefront and firmware
  rollout where available.
- [ ] LCH-090 [ENG] Monitor crashes, ANRs, hangs, collection freshness, history,
  OTA, API SLOs, battery, support, and RMA signals within privacy limits.
- [ ] LCH-100 [JOINT] Apply documented halt and rollback criteria when a launch
  signal crosses its threshold.
- [ ] LCH-110 [JOINT] Publish accurate release notes and known limitations.
- [ ] LCH-120 [JOINT] Run the 24-hour production review.
- [ ] LCH-130 [JOINT] Run the 7-day production review.
- [ ] LCH-140 [JOINT] Run the 30-day production review.
- [ ] LCH-150 [ENG] Move verified post-launch work into a new ordered operations
  round without rewriting release evidence.
