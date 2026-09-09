# Round: 2026-09-09 - Managed Safety lock and retention closeout

## Status

- State: `implemented and completely locally verified; replacement hosted gates pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `0e45f44abdec302c1d0bf623dc6e9d27201fb969`
- End implementation commit: commit containing this record
- Record commit or PR: protected pull request `#10`

## Objective

Close all four findings from the automated review of exact head `0e45f44a`
without weakening tenant isolation, idempotency, erasure cooling-off behavior,
Safety request usability, bounded retention, or the external paging launch
gates.

## Scope

### In scope

- Give Safety relationship creation and removal one advisory/profile lock
  order.
- Give incident expiry and incident creation one incident/profile lock order.
- Serialize erasure request and cancellation by account and prevent a canceled
  job from reactivating an account while another live erasure remains.
- Add an account-scoped rolling Safety contact-request ledger that counts
  terminal rows and survives contact removal and profile recreation.
- Add deterministic PostgreSQL race, replay, quota, purge, and lifecycle
  regressions and rerun the complete affected release matrix.

### Non-goals

- Enable public traffic, real participant paging, SMS/voice fallback,
  automatic emergency inference, or health-data transfer.
- Claim physical APNs/FCM, location, background, haptic, BLE, battery, legal,
  monitoring, failover, or staffed-operations evidence.

## Starting evidence

- Reproduction or observed symptom: exact-head automated review identified two
  cross-operation PostgreSQL deadlock cycles, one multi-job erasure
  reactivation race, and unbounded accepted/remove request churn.
- Relevant source/device/OS/firmware class: PostgreSQL managed Safety and
  managed account lifecycle only; no device behavior changes.
- Existing tests, logs, exports, screenshots, or documents: all local source
  gates and 31 hosted checks passed before the exact-head review; four review
  threads remain unresolved.
- Unknowns that must remain unknown until measured: production contention,
  physical push delivery, carrier behavior, and real participant operations.

## Delivered

- Every profile-facing Safety operation now performs global expiry in a short
  committed transaction before taking profile rows. Incident creation then
  performs owner-scoped incident expiry only after locking the owner and
  eligible contacts. Expiry and creation therefore preserve one
  profile-before-incident hierarchy without weakening active-incident
  uniqueness at the expiry boundary.
- Contact-request creation takes the directed pair advisory lock before either
  profile/account row. Contact removal takes both directed pair locks in stable
  order before profiles, active incidents, and accepted-contact rows. A
  deterministic PostgreSQL schedule proves concurrent removal and request
  creation complete without the reviewed deadlock.
- Migration `032_managed_safety_request_quota.sql` adds an account-scoped
  contact-request quota ledger. It counts accepted, declined, canceled, and
  expired request churn toward a rolling 50-per-24-hour limit, preserves
  idempotent replay, survives contact deletion and social-profile recreation,
  and backfills retained requests.
- Request and quota rows are inserted atomically. Quota evidence is purged only
  after the linked profile-scoped request is gone and its retention boundary
  has elapsed, bounding storage without allowing delete-and-recreate quota
  resets.
- Account erasure request and cancellation now share one account advisory
  lock, then lock the target job before the account row. Timestamps are sampled
  after those locks. A cancellation reactivates the account only when no other
  broad erasure remains live, and the lifecycle worker claims broad jobs only
  while the account is `erasure_pending`.
- Raw/derived-only erasure jobs remain claimable only for active accounts.
  Idempotent request replay is preserved, while a fresh erasure request is
  rejected when the account is not active.

## Data, privacy, and medical truth

- Schema or migration impact: one additive account-scoped quota ledger is
  included. It backfills retained request metadata without changing or
  deleting an existing request.
- Existing-data retention impact: terminal Safety contact requests will remain
  profile-scoped while their quota evidence remains account-scoped and bounded
  to the linked request's retention boundary.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none; manual Safety paging
  remains non-guaranteed and externally gated.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  managed request middleware and operational events already record fixed route,
  status-family, latency, and correlation evidence for these server paths.
- Why existing evidence is sufficient, or why new evidence is required:
  changes are transactional ordering and durable quota enforcement; no new
  externally meaningful lifecycle state is introduced.
- Existing evidence reused: bounded server request correlation and fixed
  Safety rejection/rate-limit outcomes.
- New bounded events or operation spans: none. The API surface and externally
  meaningful lifecycle states are unchanged.
- Redaction, retention, and high-frequency controls: no dynamic account,
  profile, request, incident, job, token, payload, location, or exception data
  enters observability.
- Cross-platform/backend correlation: mobile API contracts remain unchanged.
- Remaining blind spots: database deadlock behavior outside the deterministic
  local race schedule and production-scale contention.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-head automated review | Four actionable findings reproduced in source | The round is tied to the reviewed head | Remediation correctness |
| Focused PostgreSQL quota and replay cases | Request churn, replay, profile recreation, rolling-window expiry, and linked-row purge passed on clean databases | Terminal churn is bounded per account without breaking replay or retention | Production-scale traffic |
| Deterministic PostgreSQL overlap cases | Contact removal/request creation, invitation redemption/profile deletion, targeted incident expiry, and erasure request/cancel contention passed | The reviewed lock cycles do not reproduce under controlled overlap | Every scheduler interleaving |
| Erasure lifecycle cases | Multi-job cancellation, account-state claim filtering, and source lock contracts passed | One canceled broad job cannot reactivate an account with another live broad erasure | External identity-provider deletion |
| Complete server suite | All 423 cases were collected; 422 passed and the one real-provider Twilio staging case was intentionally skipped | The replacement is compatible with the complete local API, migration, tenancy, Safety, retention, and worker surface | Real provider traffic or physical devices |
| Server formatting and lint | Ruff format and check passed across 67 files | Changed Python remains syntactically and stylistically valid | Runtime behavior |
| Tooling and release controls | 227 tests and 30 subtests passed; trusted release controls, all 10 required CI contexts, and all 9 release-control checks passed | The replacement preserves the fail-closed release-control implementation | Hosted exact-head execution |
| Terminology inventory | 17,376 classified occurrences, unchanged category totals, unchanged active allowlist, zero forbidden mappings, and one reviewed historical index line shift | The new round record did not introduce customer-facing legacy terminology or broaden an allowlist | Runtime copy on physical devices |
| Policy and repository checks | Calibration, health-claims, private-data, legal/distribution, localization, ShellCheck, shell syntax, operations, and diff checks passed | The server-only replacement preserves repository policy contracts | Hosted or physical behavior |

### Failed and corrected attempts

- Initial complete-suite output appeared idle because pytest output was
  buffered. The process was inspected instead of being treated as a pass or
  failure.
- One deterministic invitation/profile overlap test then genuinely waited
  forever because its harness monkeypatched the former in-transaction expiry
  helper as a proxy for profile-lock acquisition. Expiry now intentionally
  occurs before profiles. The test was corrected to pause the actual
  profile/account lock helper, after which the focused and complete suites
  passed without reverting product behavior.
- The release-policy gate correctly rejected the stale terminology inventory
  after the new index row shifted one historical line. Regeneration changed
  only that line range. The active allowlist and category counts remained
  byte-for-byte unchanged, and the reviewed inventory digest was repinned.
- The first tooling rerun used the host Python, which does not contain pytest,
  and one trusted-control command omitted its required root argument. The
  pinned isolated server environment and explicit repository root were used
  for the successful complete reruns.

## Physical device and deployment

- Install/update action: not run; this server-only closeout does not create a
  new app binary.
- Generalized device and OS class: not applicable.
- Data-preservation result: no physical or real-user data touched.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical Safety paging and band gates.

## Git and release state

- Changed paths: managed Safety and erasure repositories, migration `032`,
  migration manifest, focused PostgreSQL tests, terminology inventory and
  required-CI digest, this round record, index, and active handoff.
- Commits: commit containing this record is pending until the final local
  documentation gate passes.
- Branch and remote state: pull request `#10` remains open and unmerged.
- Repository visibility verified: inherited from the exact-head review.
- Version/build impact: no version change planned.
- Release or distribution impact: none until protected review and normal merge.

## Decisions

- Durable decision added or changed: Safety relationship churn is bounded by
  an account-scoped durable ledger; every profile-facing expiry operation must
  complete before profile locks, with only targeted expiry allowed after those
  locks; and broad erasure cancellation cannot reactivate an account while
  another broad erasure is live.
- Decision-log entry: the behavior refines existing managed Safety and erasure
  contracts in this implementation record; no separate product decision is
  required.

## Open risks and honest limitations

- Production lock pressure, real-provider delivery, physical push and location
  behavior, legal/security review, monitoring, failover, and staffed
  operations remain unproven external or physical gates.
- The protected replacement head still requires a clean exact-head automated
  review, every hosted required check, resolved verified conversations, and a
  normal protected merge.

## Next round

1. Push the completely locally verified replacement head.
2. Resolve only conversations whose exact replacement source proves closure,
   then obtain a clean exact-head automated review and every protected hosted
   check.
3. Merge normally only after the replacement head is clean, then integrate and
   verify the large-data mobile performance pull request against that protected
   main.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, dynamic Safety identifiers, locations,
      or absolute personal paths are present.
