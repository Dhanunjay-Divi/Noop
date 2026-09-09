# Round: 2026-09-09 - Managed Safety review hardening

## Status

- State: `implemented and locally verified; replacement exact-head review pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `1dd989356dc6defd2e0342a8ea1f62024a76af9d`
- End implementation commit: pending
- Record commit or PR: protected pull request `#10`

## Objective

Close the three actionable findings from the exact-head review without
weakening account isolation, emergency-page availability, push-token
confidentiality, or existing external launch gates.

## Scope

### In scope

- Require and lock active managed accounts for both profiles before creating
  or accepting a Safety relationship.
- Add durable, race-safe incident creation throttles while preserving exact
  idempotent replay.
- Add versioned push-token encryption with previous-key read grace and prevent
  local key-configuration failures from invalidating provider registrations.
- Add focused regressions, run the complete server suite and repository gates,
  and obtain a clean exact-head review before protected merge.

### Non-goals

- Enable public traffic, automatic emergency inference, SMS/voice paging, or
  real participant paging.
- Claim physical APNs/FCM, background location, haptic, battery, legal,
  monitoring, failover, or staffed-operations evidence.

## Starting evidence

- Exact reviewed head:
  `1dd989356dc6defd2e0342a8ea1f62024a76af9d`.
- The exact-head reviewer identified three defects: inactive managed accounts
  could retain active social profiles during relationship creation, an owner
  could repeatedly end and recreate incidents without a durable throttle, and
  replacing the single push-token encryption secret made existing encrypted
  registrations unreadable and then incorrectly invalidated them.

## Delivered

- Safety relationship creation now locks both social profiles and their managed
  accounts in deterministic profile order and requires both account rows to be
  active. Acceptance uses the same account/profile-before-request order.
  The shared current-profile lookup also requires an active database account,
  so a stale authenticated principal cannot race a suspension into a Safety
  mutation.
- Incident creation remains exactly idempotent for a repeated client request
  ID, then applies a durable per-owner quota under the existing PostgreSQL
  advisory lock: at most four created incidents in a rolling hour and twelve
  in a rolling day. Every status counts because a canceled page has already
  notified contacts. The API returns `429` with the longest applicable bounded
  `Retry-After` value when hourly and daily windows overlap.
- Push-token envelopes are now `v2.<key-id>.<ciphertext>`. The codec reads the
  current and one staged/previous key, remains compatible with legacy `v1`
  envelopes, and compare-and-swap reseals successfully opened old envelopes
  under the current key without delaying provider delivery if the best-effort
  database update fails.
- A local decryption or missing-key failure is classified as provider
  unavailable, not as evidence of an invalid FCM registration. Only an
  explicit provider invalid-token response can disable an installation.
- GCP staging has a region-scoped secondary push-token secret with
  least-privilege access for only the managed API and lifecycle identities.
  Runtime examples document the two-phase zero-downtime rotation: stage the
  next key as secondary and fully deploy, then promote it while retaining the
  old current key as secondary for the second deployment.
- Focused tests cover suspended and erasure-pending accounts, invite and
  direct request creation, acceptance, hourly and daily quotas, exact replay,
  API retry headers, legacy/current/secondary key envelopes, rolling revision
  interoperability, compare-and-swap resealing, and failure without
  registration invalidation.

## Data, privacy, and medical truth

- Schema or migration impact: no schema change; throttles use retained
  incident rows and the existing per-owner transaction lock.
- Existing-data retention impact: encrypted push-token envelopes gain rolling
  read compatibility; no token is logged or exported.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: no automatic emergency or
  guaranteed-delivery claim is introduced.

## Observability

- Only bounded success, retryable, terminal, and receipt outcomes may be
  recorded.
- Tokens, key material, account/profile/incident identifiers, coordinates,
  provider bodies, and arbitrary exception text remain excluded.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Managed push, API, config, and deployment regressions | 87 passed | Versioned envelopes, previous-key grace, resealing, non-invalidation, `429`/`Retry-After`, configuration validation, and GCP source contracts hold | Live FCM or secret rotation |
| Fresh PostgreSQL managed-Safety file | 12 passed | Active-account locks, exact replay, four-per-hour and twelve-per-day quotas, honest daily retry, retained token state, and existing Safety integration hold in PostgreSQL | Cross-region load or physical delivery |
| Complete server suite | 398 collected; 397 passed; only the explicitly opt-in real-Twilio staging test skipped; zero failures/errors | Both separate standard-PostgreSQL migration lanes, server APIs, repositories, lifecycle, ownership, social, and Safety behavior pass on fresh `template0` databases | The local machine lacks TimescaleDB; hosted server CI remains the TimescaleDB proof |
| Server quality | Ruff check and format passed; Python compile and diff checks passed | Changed Python source is syntactically valid and conforms to pinned formatting/lint rules | Live provider behavior |
| GCP infrastructure | OpenTofu format and validation passed; shell syntax and ShellCheck passed | Secondary secret, IAM, runtime injection, and bootstrap source are internally valid | A deployed rotation or IAM propagation |
| Repository policy matrix | 84 tests and 27 subtests passed; required CI verified ten contexts; release controls passed nine checks; 43 rounds validated | Trusted-release, workflow, operations-record, and generated-source controls remain fail closed | Hosted execution |
| Terminology ratchet | 17,376 occurrences across 1,509 path/category groups; zero forbidden mappings; active allowlist unchanged; reviewed digest repinned | The generated line movement was reviewed without introducing a first-party legacy mapping | Removal of existing compatibility terminology |
| Prior exact-head hosted matrix | All required Apple, Android, server, package, policy, and trusted-release contexts passed on `1dd98935` | The preceding protected head was fully green before these three findings | The replacement head still requires a new hosted run |

## Physical device and deployment

- Install/update action: none planned in this server-hardening slice.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: APNs, FCM, process termination, background location,
  haptics, battery, and physical contact paging.

## Git and release state

- Changed paths: managed Safety repository/API errors, push codec and runtime
  configuration, GCP secret/IAM/runtime bootstrap, focused server tests, and
  operations records.
- Commits: the replacement commit containing this record is pending.
- Branch and remote state: protected pull request `#10` remains open.
- Version/build impact: no version change planned.
- Release or distribution impact: no release artifact or public deployment.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: not required.

## Open risks and honest limitations

- Source and PostgreSQL tests cannot prove provider delivery or physical-phone
  behavior.
- Legal, monitoring, failover, and staffed-operations gates remain outside
  this supplier-independent source round.

## Next round

1. Commit and push the replacement head.
2. Resolve the corresponding review threads with exact-head evidence.
3. Require a clean exact-head review and all hosted checks.
4. Merge normally without bypassing protected branch controls.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, dynamic Safety identifiers, locations,
      or absolute personal paths are present.
