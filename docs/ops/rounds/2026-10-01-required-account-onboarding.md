# Round: 2026-10-01 - Band-first required-account onboarding

## Status

- State: `locally reverified after first hosted-head remediation; replacement exact-head verification, protected integration, and live-provider validation pending`
- Owner: project team
- Branch: `codex/mobile-navigation-sparkline-redesign-20260930`
- Start commit: `4d034b92f6fcfd1dfe05fbe4c698c469f44e4f0a`
- End implementation commit: `dc9d7efef4561e854bb5c0504335e442a8a7696f`
- Record commit or PR: PR `#25`

## Objective

Remove the obsolete account-free/local-test first-run path and implement the
owner-approved order: Welcome, Bluetooth explanation, supported-band setup,
Create account or Sign in, ownership confirmation when required, profile,
plan, and app entry. A build without NOOP account-service configuration must
fail closed at the account step rather than allow anonymous progression.

The account requirement does not remove the bounded phone collector and
offline working set required by D-059. It also does not claim that every health
data class or formula is already cloud-authoritative.

## Scope

### In scope

- Apple and Android first-run account gates and active onboarding copy.
- Explicit DEBUG/instrumentation-only synthetic account paths used by automated
  UI tests.
- Cross-platform regression contracts, localization, product decisions, and
  operations evidence.
- Active customer-facing claims that incorrectly describe NOOP as account-free,
  local-first, or cloud-optional.

### Non-goals

- Enabling production identity credentials, public traffic, or real health-data
  transfer.
- Removing the bounded edge collector or safe offline working state.
- Claiming that the staged D-059 authority migration is complete.
- Physical-device, BLE, background, notification, or physiology validation.
- Deleting the legacy self-hosted compatibility implementation without a
  separate data-migration and removal review.

## Starting evidence

- Reproduction or observed symptom: the iPhone first-run flow says
  `your health data, local by default` and exposes `Continue in local test mode`
  when account configuration is absent.
- Relevant source/device/OS/firmware class: iPhone Simulator screenshot plus
  matching Apple and Android source.
- Existing tests, logs, exports, screenshots, or documents: D-059 establishes
  the staged cloud-authoritative target; current onboarding tests explicitly
  preserve anonymous progression and therefore encode the defect.
- Unknowns that must remain unknown until measured: live identity-provider
  registration, signed-device attestation, production account recovery, and
  physical first-run behavior.

## Delivered

- Apple and Android now use the same band-first eight-stage route and fail
  closed at account setup when the managed account service is unavailable.
- A versioned completion marker forces installs upgraded from the retired
  account-free flow back through supported-band verification and the required
  account boundary before the operational shell can mount.
- Launch-band discovery uses neutral customer copy, keeps all three launch
  rows visible, and truthfully disables the unavailable account-linked row.
- Discovery animation is state-driven and suppressed by reduced-motion policy.
- The owner-configured public order link is HTTPS-only, excludes credentials,
  logs no URL, and remains disabled when no official URL is configured.
- New work is split into focused routing, device-eligibility, discovery, and
  order-link files instead of expanding the legacy multi-thousand-line screens.
- The active Bluetooth prompt now uses neutral `your compatible band` wording
  across Apple and Android instead of naming one transport or product family.
- Stale UI tests that expected Account before Bluetooth were corrected to
  exercise the actual owner-approved sequence from a reset installation.
- Active README, privacy, settings, and changelog copy no longer promise an
  account-free customer path or describe incomplete cloud-authority migration
  work as already complete.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: none planned.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: account access becomes a required
  setup gate; health-data authority and consent remain separately staged.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  bounded onboarding progress and account-service state, focused gate tests,
  and simulator/emulator first-run automation.
- Why existing evidence is sufficient, or why new evidence is required: this
  slice changes synchronous first-run gating and copy; the account network
  service already owns its bounded operation evidence.
- Existing evidence reused: `onboarding.progress`, account phase/status, and
  hermetic UI-test outcomes.
- New bounded events or operation spans: none planned.
- Redaction, retention, and high-frequency controls: existing fixed categories
  only; no email, account identifier, token, request body, or health value.
- Cross-platform/backend correlation: Apple and Android source contracts plus
  their independent configured-provider UI-test harnesses.
- Remaining blind spots: live provider and signed physical-device behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| iOS Simulator app graph | Pass | Shared Apple source and new onboarding components compile in the iOS app | Signed phone, BLE, provider, or physical-band behavior |
| Apple onboarding and Bluetooth contracts | 33/33 pass | Band-first routing, fail-closed account handling, durable setup requirements, supplier-row gating, neutral permission copy, and source-aware pairing delegation | Live identity registration or physical BLE |
| Clean iPhone first-run automation | Unconfigured and configured journeys 2/2 pass; final neutral-copy rerun 1/1 pass | Terms gates shell entry; Bluetooth and supported-band setup precede Account; configured synthetic account and band complete the eight-stage flow; the final rendered footer contains `your compatible band` without truncation | Production credentials, signed installation, or physical-band pairing |
| Android API 35 first-run automation | 3/3 pass | Unconfigured, reset-order, and configured synthetic-provider journeys preserve the same band-first sequence | OEM behavior, live provider, or physical band |
| Android focused onboarding policy | 17/17 pass | Resume, redirect, durable device setup, account readiness, and supplier-claim boundaries fail closed | Full Android regression wall |
| Android Full/Demo compilation | Pass; obsolete translated exploration resources removed and warning absent on rerun | Both Android product flavors compile with the extracted policies/components and no dead local/exploration boundary resource | Physical phone or BLE behavior |
| Final cross-slice focused wall | Apple 57/57 and Android 78/78 pass | The versioned legacy-account migration and band-first account boundary remain green beside the final actionable-notification contracts | Live identity provider, signed phone, or physical band |
| Copy and repository policy gates | App-wide nine-locale generation, brand check, claims gate, private-data filename guard, 110-record operations validation, and diff hygiene pass | Active onboarding copy and configuration boundaries remain internally coherent | Production account credentials or public traffic |
| Visual and OCR review | Pass at 1206x2622 | Terms, Bluetooth, supported-band picker, Account, ownership, and completion captures have no observed clipping or overlap; current Bluetooth copy matches the account-required direction | Dynamic Type and physical-device rendering outside the tested simulator |
| First exact hosted head `294ff9b5a` | Failed a scoped localization-policy check and an obsolete Android test that still required Safety and Appearance inside onboarding | Hosted verification reached the current band-first implementation and isolated stale repository contracts | A green replacement SHA, live identity provider, or signed phone |
| Hosted-head remediation | Pass locally: localization 6/6, Safety shell 3/3, complete Full Debug 5,255 tests with seven intentional skips, i18n audit, release-control wall, and iOS Simulator graph | The exact eight-page required-account sequence remains enforced while Safety stays reachable from the persistent shell | Hosted replacement execution, production identity, or physical BLE |
| Second exact hosted head `45731f878` | Android production-shell failed eight app-shell setup timeouts after 110 instrumentation tests had passed; all failures were at the fixture wait for `noop.today.list` | The shared fixture set `KEY_ONBOARDED` but omitted `REQUIRED_ACCOUNT_ONBOARDING_VERSION_KEY`, so the app correctly redirected it to required onboarding | A green final exact head or live-provider behavior |
| Versioned shell-fixture remediation | Exact API 35 `AppShellInstrumentedTest` 8/8 pass | Existing-user shell tests now seed and restore the same versioned completion boundary enforced by production code | Production identity, physical BLE, or signed-phone behavior |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: iPhone Simulator and Android API 35 emulator
- Data-preservation result: no data-path change planned
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: all signed physical-device and band-dependent cases

## Git and release state

- Changed paths: shared onboarding flow policies, supported-band picker and
  discovery components, order-link boundary, active copy/localization,
  configured test harnesses, and cross-platform first-run tests
- Commits: implementation `dc9d7efef4561e854bb5c0504335e442a8a7696f`;
  first remote verification pin `294ff9b5ae6dd81310b0fc372af1473ba43027ac`;
  first hosted remediation `45731f8780e2c0593a0b9ed14a04914bc002bf10`;
  the commit containing this record carries the final shell-fixture remediation
- Branch and remote state: PR `#25` is open at remote head `45731f878`;
  the commit containing this record is the locally verified replacement
  candidate
- Repository visibility verified: unchanged
- Version/build impact: no version change planned
- Release or distribution impact: first-run source correction only

## Decisions

- Durable decision added or changed: every ordinary customer installation
  verifies a supported band first, then requires a NOOP account before
  ownership completion and shell entry.
- Decision-log entry: D-062.

## Open risks and honest limitations

- A repository build without identity configuration will intentionally stop at
  account setup. It is not a usable release candidate.
- Account-required onboarding does not prove managed health-data upload,
  canonical server formulas, production identity, or provider availability.

## Next round

1. Verify live configured-provider registration and recovery on signed iPhone
   and Android candidates, then continue the D-059 per-data-class authority
   gates.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
