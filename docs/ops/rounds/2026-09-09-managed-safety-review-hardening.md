# Round: 2026-09-09 - Managed Safety review hardening

## Status

- State: `implemented and locally verified; replacement exact-head review pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `4a606f45f5bb83bce80a60876a2fc6dcde15c988`
- End implementation commit: commit containing this record
- Record commit or PR: protected pull request `#10`

## Objective

Close the four actionable findings from the exact-head review without
weakening account isolation, emergency-page availability, push-token
confidentiality, or existing external launch gates.

## Scope

### In scope

- Require and lock active managed accounts for both profiles before creating
  or accepting a Safety relationship.
- Make incident throttles account-scoped and durable across social-profile
  deletion/recreation while preserving exact idempotent replay.
- Make the first versioned push-token rollout readable by both old and new
  revisions, then distinguish retryable missing/forward keys from terminal
  malformed or known-key-corrupt envelopes.
- Make invitation redemption follow the profile/account-before-invite lock
  order used by profile deletion.
- Add focused regressions, run the complete server suite and repository gates,
  and obtain a clean exact-head review before protected merge.

### Non-goals

- Enable public traffic, automatic emergency inference, SMS/voice paging, or
  real participant paging.
- Claim physical APNs/FCM, background location, haptic, battery, legal,
  monitoring, failover, or staffed-operations evidence.

## Starting evidence

- Exact reviewed head:
  `4a606f45f5bb83bce80a60876a2fc6dcde15c988`.
- The replacement exact-head reviewer identified four remaining defects: the
  first v2 writer could overlap a v1-only revision; profile deletion and
  recreation erased the per-profile paging quota; every token-open failure was
  treated as retryable even when the current-key envelope was corrupt; and
  invitation redemption locked the invite before the owner profile while
  profile deletion acquired those locks in the opposite order.

## Delivered

- Safety relationship creation now locks both social profiles and their managed
  accounts in deterministic profile order and requires both account rows to be
  active. Acceptance uses the same account/profile-before-request order.
  The shared current-profile lookup also requires an active database account,
  so a stale authenticated principal cannot race a suspension into a Safety
  mutation.
- Migration `030` adds an account-scoped paging quota ledger independent of
  social profiles and incidents. It backfills retained incidents, survives
  profile cascades, consumes a client request ID for the retention window, and
  is purged in bounded batches. Incident creation serializes on account ID,
  preserves exact replay while the incident exists, refuses a consumed replay
  after its profile-scoped incident was erased, and still enforces four pages
  per rolling hour and twelve per rolling day.
- The token codec defaults to writing the existing v1 envelope while reading
  both v1 and v2. Operators first deploy that dual reader and drain prior
  revisions, then promote all API and lifecycle revisions together with
  `NOOP_MANAGED_PUSH_TOKEN_WRITE_VERSION=v2`. Current and staged key rotation
  remains a separate two-deployment operation.
- Unknown envelope versions, unknown v2 key IDs, and ambiguous v1
  authentication failures remain retryable. Strict-base64/short legacy
  envelopes, malformed v2 envelopes, invalid plaintext, and authentication
  failure under the v2 envelope's known key are terminal and retire the
  unusable registration rather than consuming three retries.
- Invitation redemption now snapshots without a row lock, acquires the
  profile-pair advisory lock, locks both active profiles and accounts in
  deterministic order, then re-locks and revalidates the invite. A forced
  redeem-versus-owner-profile-delete regression completes without deadlock and
  leaves no relationship rows after the delete cascade.
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

- Schema or migration impact: migration `030` adds
  `managed_safety_page_quota_events`, keyed by account and client request ID,
  with bounded purge indexes and no incident/profile foreign key.
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
| Managed push, config, deployment, backup, and migration regressions | 72 passed; 20 unrelated integration cases deselected | v1-safe rollout, v2 promotion, both reader directions, corruption classification, configuration validation, immutable migration pinning, and GCP source contracts hold | Live FCM or a deployed rotation |
| Fresh PostgreSQL managed-Safety file | 15 passed | Account-scoped quota survival, consumed replay, ordered purge, four-per-hour and twelve-per-day limits, forced invite/delete lock race, retained token state, and existing Safety integration hold | Cross-region load or physical delivery |
| Complete server suite | 406 collected; 405 passed; only the explicitly opt-in real-Twilio staging test skipped; zero failures/errors | Both separate standard-PostgreSQL migration lanes, server APIs, repositories, lifecycle, ownership, social, Safety, and restore-manifest behavior pass on fresh `template0` databases | The local machine lacks TimescaleDB; hosted server CI remains the TimescaleDB proof |
| Server quality | Ruff check and format passed; Python compile and diff checks passed | Changed Python source is syntactically valid and conforms to pinned formatting/lint rules | Live provider behavior |
| GCP infrastructure | OpenTofu format and validation passed; shell syntax and ShellCheck passed | Coordinated write-version injection, secondary secret, IAM, runtime, and bootstrap source are internally valid | A deployed promotion or IAM propagation |
| Repository policy matrix | 187 tests passed; required CI verified ten contexts; release controls passed nine checks; 43 rounds validated | Trusted-release, workflow, operations-record, and generated-source controls remain fail closed | Hosted execution |
| Terminology ratchet | 17,376 occurrences across 1,509 path/category groups; zero forbidden mappings; active allowlist unchanged; reviewed digest repinned | The generated line movement was reviewed without introducing a first-party legacy mapping | Removal of existing compatibility terminology |
| Prior protected hosted matrix | All required contexts passed on `1dd98935`; every completed check on reviewed head `4a606f45` succeeded, while its iOS simulator job remained in progress at the final query | The branch entered this remediation with no known hosted failure | The replacement head still requires a fresh complete hosted run |

## Physical device and deployment

- Install/update action: none planned in this server-hardening slice.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: APNs, FCM, process termination, background location,
  haptics, battery, and physical contact paging.

## Git and release state

- Changed paths: managed Safety repository, push codec/runtime configuration,
  migration and restore manifest, GCP rollout controls, focused server tests,
  and operations records.
- Commits: commit containing this record.
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

1. Push the replacement head.
2. Resolve all four corresponding review threads with exact-head evidence.
3. Require a clean exact-head review and all hosted checks.
4. Merge normally without bypassing protected branch controls.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, dynamic Safety identifiers, locations,
      or absolute personal paths are present.
