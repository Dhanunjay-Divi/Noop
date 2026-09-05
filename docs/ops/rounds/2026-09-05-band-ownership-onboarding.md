# Round: 2026-09-05 - Band ownership and onboarding contract

## Status

- State: `owner direction recorded; implementation and external gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `43f9209a`
- End implementation commit: documentation commit containing this record
- Record commit or PR: direct-to-`main` documentation update requested by the
  owner

## Objective

Record the owner-confirmed India-first, USA-second release sequence and define
the production contract for first-party NOOP Band discovery, physical
confirmation, account claim, single-account ownership, future-phone recovery,
restricted transfer, and the pre-home NOOP versus NOOP+ choice.

The release checklist must retain stable IDs, put the new work in dependency
order, and keep unknown supplier protocol details, payment infrastructure,
legal approval, and physical-device behavior explicitly open.

## Scope

### In scope

- Record India as the first launch market and the USA as the next market.
- Define a one-time first-party band ownership/activation account boundary
  without moving local collection, metrics, export, or device control behind
  NOOP+ or a subscription.
- Define the target flow from pairing-mode discovery through printed-code
  confirmation, identify haptic, exact physical gesture, account creation,
  atomic ownership claim, remaining onboarding, and plan selection.
- Define email/password identity with optional verified mobile number, recovery,
  new-phone use, ownership conflicts, transfer restrictions, support exits,
  deletion, and future upgrade release.
- Define an accessible gold NOOP+ presentation and a non-functional payment
  placeholder until the India payment and store-billing decision is approved.
- Define lifetime v1 account binding with no user-facing unpair, remote-only
  canonical terms, and the unresolved 14- versus 30-day return decision plus
  condition-based refund rules.
- Update release, readiness, architecture, operations, and prior India guidance
  so they describe one consistent target.

### Non-goals

- Implement or infer the supplier's GATT, packet, haptic, gesture, identity,
  key, or SDK behavior before the versioned specifications and engineering
  bands are provided.
- Implement authentication, ownership APIs, database migrations, payment,
  entitlement, or mobile onboarding in this documentation round.
- Enable public cloud ingress, production accounts, real health-data upload,
  billing, or transfer.
- Claim that a printed number, vibration, simulator, or unit test proves secure
  physical possession.

## Starting evidence

- Reproduction or observed symptom: the release checklist had only broad
  pairing and ownership points and did not preserve the owner-specified
  onboarding sequence or first-market decision.
- Relevant source/device/OS/firmware class: future first-party NOOP Band,
  firmware and supplier SDK, Apple and Android apps, Firebase Identity
  Platform, managed backend, and NOOP/NOOP+ product selection.
- Existing tests, logs, exports, screenshots, or documents: the 325-point first
  production release checklist, master plan, current phone-OTP-only private
  managed staging, and current account-free compatible-device implementation.
- Unknowns that must remain unknown until measured: printed identifier format,
  pairing-mode command, identify haptic, gesture event, cryptographic possession
  proof, ownership key lifecycle, supplier SDK license/API, physical reliability,
  payment gateway, prices, tax treatment, and legal enforceability of transfer
  restrictions.

## Delivered

- Recorded India as the first public market and the USA as the second. This
  closes only the sequence decision; territories, languages, certifications,
  privacy, billing, stores, support, and launch approval remain open.
- Reconciled the first-party ownership account with NOOP's local-first
  boundary. App exploration, imports, local metrics, and exports remain
  account-free. A new first-party band requires one ownership claim, after
  which local collection, scoring, export, and device control remain
  independent of NOOP+, payment, subscription, and continuous network.
- Defined printed-band-number matching as discovery only, not authentication.
  The selected pairing-mode band identifies itself by vibration, and firmware
  must turn at least three deliberate taps into one debounced, expiring,
  cryptographically challenge-bound possession event.
- Defined the customer sequence: initial education, worn pairing mode, scan,
  printed-number match, identify vibration, physical confirmation, ownership
  disclosure, explicit `I agree`, account create/sign-in, atomic claim,
  remaining onboarding, NOOP/NOOP+ selection, then Home.
- Defined verified email/password as the release identity target and optional
  mobile OTP only when a number is supplied. Existing private staging remains
  phone-OTP-only and therefore needs migration rather than being relabeled as
  complete.
- Required atomic and idempotent single-owner claim, app attestation,
  band-proven possession, privacy-preserving conflicts, partial-failure
  recovery, owner-key provisioning, replacement-phone authorization, and
  installation revocation.
- Recorded the owner's v1 no-general-self-service-resale direction while
  requiring India/USA review and support-controlled return, RMA, recovery,
  deletion, dispute, fraud, recycling, and future eligible-upgrade exits.
- Tightened the v1 direction: the app exposes no user-facing unpair or transfer
  and ordinary ownership remains bound for the band's lifetime. Consumer
  release appears only for a future eligible successor-band upgrade.
- Defined immutable, content-addressed, locale-specific terms in
  NOOP-controlled remote storage, an ephemeral no-persistent-cache app fetch,
  fail-closed integrity/version checks, exact server-side acceptance metadata,
  public historical versions, sanitized static rendering, and no full terms
  document persisted by the app.
- Recorded a voluntary return-policy target while leaving 14 versus 30 days and
  the clock start open. Added objective condition grades, pre-purchase
  deduction disclosure, original-rail itemized refund, appeal, and
  operator-only revoke/wipe/unlink/quarantine requirements.
- Separated band ownership, NOOP+ consent, and NOOP+ entitlement. Payment
  failure or cancellation cannot deactivate the band or remove core local
  capability.
- Required a pre-Home NOOP/NOOP+ chooser on both platforms. NOOP continues
  without payment. NOOP+ uses an accessible gold identity that is not
  color-only; its payment surface remains explicitly unavailable and grants no
  entitlement until billing is approved.
- Expanded the release ledger from 325 pending actions across 15 phases to 396
  total actions across 16 phases: five owner decisions are evidenced complete
  and 391 implementation or external actions remain pending. IDs are unique.
- Added durable decisions D-045 through D-051 and updated the master plan,
  readiness ledger, cloud/platform contracts, contributor boundary, active
  handoff, prior India/hardware guidance, and round index.

## Data, privacy, and medical truth

- Schema or migration impact: documentation-only. Future work requires
  additive account, band, claim, ownership-event, installation, release, and
  entitlement schemas with tenant isolation and erasure.
- Existing-data retention impact: none in this round.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: the target introduces a disclosed
  network dependency for first-party band claim, recovery, and transfer.
  Ongoing local collection and metrics remain independent of NOOP+ and payment.
- Health/medical claim impact and limitations: none. Pairing and ownership do
  not validate any sensor or metric.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: future Apple,
  Android, firmware, and backend work must use fixed categories for discovery,
  candidate selection, identify haptic, possession challenge, consent,
  identity, claim, provisioning, conflict, recovery, release, and terminal
  outcome.
- Why existing evidence is sufficient, or why new evidence is required:
  existing mobile and backend recorders provide the facilities, but the new
  lifecycle categories and tests do not exist.
- Existing evidence reused: `AppDiagnosticsRecorder`,
  `RequestObservabilityMiddleware`, and `emit_operational_event`.
- New bounded events or operation spans: planning requirements only in this
  round.
- Redaction, retention, and high-frequency controls: diagnostics must exclude
  printed numbers, serials, BLE addresses, account IDs, email, phone, OTP,
  password, tokens, keys, challenge payloads, health data, and arbitrary
  errors. Only fixed states, outcome categories, durations, and bounded counts
  are permitted.
- Cross-platform/backend correlation: future claim requests use a
  server-generated ephemeral correlation ID and static route category, never a
  band or account identifier.
- Remaining blind spots: all physical and production behavior until the
  supplier dossier, implementation, production identity, and representative
  band matrix exist.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Repository preflight | `main` clean at `43f9209a`, equal to `origin/main` | Planning starts from published source | Any runtime behavior |
| Current identity audit | Native Firebase clients and private managed staging use phone OTP; email/password band ownership is not implemented | The plan must describe a new identity and migration boundary | Production identity, account recovery, or ownership |
| Current product-contract audit | Core compatible-device use is account-free and NOOP+ is optional | A one-time first-party activation exception must be explicit and narrow | That the future exception is implemented or legally approved |
| Stable checklist audit | 396 valid actions, 391 pending, five complete, 16 phases, and no duplicate IDs or invalid live action labels | Owner additions are preserved in one dependency-ordered ledger | Completion of any unchecked action |
| Operations record validation | `python3 Tools/validate-ops-rounds.py --all .` passed for 28 records | This record and index satisfy the durable-ledger contract | Product behavior |
| Relative Markdown links | All relative links passed across the 12 changed documentation files | Updated records resolve locally | External-site availability |
| Private-data checks | Filename guard and targeted personal-path, email, credential, key, and token patterns passed | No detected private data or credential-shaped value entered the changed records | Exhaustive secret analysis outside these files |
| Distribution gate | `python3 Tools/release-legal-gate.py distribution` passed | Planning changes preserve the current distribution record | Trademark, transfer-policy, supplier-SDK, or market counsel approval |
| Health-claims gate | Passed across 1,175 files | The new ownership language introduces no prohibited health claim | Sensor or metric accuracy |
| Localization audit | `python3 Tools/i18n_audit.py --ci origin/main` passed with no new customer literal or brand regression | Documentation-only work does not alter localized app copy | Future onboarding translation or native-speaker quality |
| Whitespace and added-text encoding | `git diff --check` passed; newly added lines contain no non-ASCII characters | The patch is mechanically clean and follows the editing character-set rule | Markdown rendering on every external viewer |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: no runtime data changed.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: discovery, printed-label match, identify vibration,
  exact gesture, cryptographic possession, claim, provisioning, reconnect,
  replacement phone, release, and transfer.

## Git and release state

- Changed paths: contributor boundary, release checklist and master plan,
  production readiness, cloud and platform architecture, active handoff,
  durable decisions, prior India/hardware guidance, round index, and this
  record.
- Commits: pending.
- Branch and remote state: `main` at `43f9209a`, equal to `origin/main` at
  round start.
- Repository visibility verified: not repeated; current operations record
  states private.
- Version/build impact: none in this documentation round.
- Release or distribution impact: none; no app, firmware, server, billing, or
  production deployment changes.

## Decisions

- D-045: India first, USA second.
- D-046: one-time ownership account for first-party activation; local
  post-activation operation and NOOP+ independence remain mandatory.
- D-047: printed number plus vibration identifies the candidate; authenticated
  physical-band confirmation proves possession for an atomic claim.
- D-048: no general v1 self-service resale release; controlled legal/support
  exits and future eligible-upgrade release remain mandatory.
- D-049: show NOOP and accessible gold NOOP+ before Home; no working payment or
  entitlement before billing approval.
- D-050: load immutable versioned terms from NOOP-controlled remote storage,
  persist no full app copy, and retain exact acceptance metadata and historical
  versions.
- D-051: offer either 14 or 30 days, still undecided; condition deductions
  require objective disclosed grades, lawful itemized refund handling, appeal,
  and operator-only wipe/unlink.
- Decision-log entry: `docs/ops/DECISIONS.md`.

## Open risks and honest limitations

- The requested account-bound activation changes the account-free hardware
  promise and therefore requires explicit product, privacy, support, and legal
  treatment.
- A printed number and unauthenticated tap event cannot establish ownership.
- A no-transfer policy without return, RMA, recovery, deletion, and dispute
  exits can strand paid hardware and create consumer-law and support failures.
- A payment placeholder must not imply a purchasable entitlement or collect
  payment before gateway, store, tax, refund, and receipt behavior are ready.
- The owner has not selected 14 versus 30 days, the clock start, eligibility,
  or condition-deduction schedule. No return policy can be published or coded
  as final until those decisions and market reviews exist.
- Remote-only terms make terms availability a claim dependency. The service
  needs integrity, rollback, availability, accessibility, and historical
  retention evidence, while an outage must never stop an activated band.
- Existing Firebase staging proves phone-OTP managed enrollment only. It does
  not prove email/password, band ownership, claim concurrency, support release,
  or entitlement separation.
- No app build was needed for this documentation-only round, and no simulator
  or physical-band evidence was produced.

## Next round

1. Define the account/claim/release schemas and deterministic virtual-band
   state machine without inventing supplier bytes.
2. Obtain and approve the supplier dossier and SDK, then freeze the
   cryptographic pairing and ownership protocol before physical implementation.
3. Obtain India/USA legal and support approval for transfer restrictions and
   choose the India payment/store-billing path before enabling checkout.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
