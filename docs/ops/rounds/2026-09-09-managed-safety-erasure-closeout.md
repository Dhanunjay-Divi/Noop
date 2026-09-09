# Round: 2026-09-09 - Managed Safety erasure closeout

## Status

- State: `implemented and completely locally verified; hosted gates pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `5c8987a1789f9cda6b989f9f4f85efdc2761c381`
- End implementation commit: commit containing this record
- Record commit or PR: protected pull request `#10`

## Objective

Close the three actionable findings from the exact-head review of `5c8987a1`
without weakening managed Safety privacy, account erasure, rolling secret
rotation, or transactional lock ordering:

1. make both Cloud Run services wait for the previous push-token secret IAM
   grant as well as the current-key grant;
2. lock active contact profiles and accounts before incident creation locks
   accepted-contact rows; and
3. retire an erasing account's active Safety ownership and participation in the
   same transaction that marks the account `erasure_pending`.

## Scope

### In scope

- OpenTofu runtime dependency ordering for the current and previous push-token
  secrets.
- PostgreSQL incident/contact/profile lock ordering and revalidation.
- Immediate cancellation, participant revocation, acknowledgement
  reconciliation, latest-location deletion, and retryable-delivery rejection
  when account erasure begins.
- Fresh PostgreSQL regressions, complete server verification, protected review,
  and normal merge.

### Non-goals

- Enable public ingress, real paging, real participant data, or automatic
  emergency inference.
- Retract a provider notification that was already accepted for delivery.
- Treat simulator or database tests as physical push, location, haptic,
  background-execution, or battery evidence.

## Starting evidence

- Exact-head automated review completed at `2026-09-09T13:20:09Z` on
  `5c8987a1`.
- The review found two P2 ordering defects and one P1 account-erasure defect.
- The reviewed head had 33 successful hosted checks, two expected skips, and
  one still-running Apple production-shell check before replacement work began.

## Delivered

- The managed API and lifecycle Cloud Run resources now depend on both current
  and previous push-token secret IAM memberships, preventing a rolling
  deployment from starting before either configured key can be read.
- Incident creation first snapshots eligible contact IDs, locks their active
  profile and account rows in stable profile-ID order, and then re-queries and
  locks only still-valid accepted-contact rows. Deleted, blocked, or inactive
  contacts are revalidated before the minimum-contact rule and inserts.
- Account erasure now locks the account and active social profile before active
  incidents. It cancels incidents owned by the profile, deletes their retained
  latest location, and rejects retryable deliveries.
- For incidents owned by another account, erasure revokes the departing
  participant, preserves any prior response timestamp, recomputes whether a
  responder still exists, reopens falsely acknowledged incidents when needed,
  and rejects that participant's retryable deliveries.
- All Safety retirement changes and the `erasure_pending` account transition
  occur in one PostgreSQL transaction. A failure rolls back both.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: account erasure removes active location
  state sooner and prevents active incident participation from surviving the
  erasure transition.
- Permissions or network impact: none; this round changes deployment ordering
  only and does not expose a service publicly.
- Health or medical claim impact: none. Manual Safety paging remains a
  user-initiated coordination feature, not diagnosis or guaranteed emergency
  delivery.

## Observability

- Existing bounded lifecycle, erasure, and Safety delivery outcomes remain the
  diagnostic boundary.
- No account, contact, incident, location, token, secret, health value, or
  arbitrary error text is added to logs.
- Transaction failure remains visible through the existing typed API failure
  and request-correlation path; partial retirement cannot commit.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Python compilation and Ruff | Changed server source compiles; Ruff check and format pass | The replacement source is syntactically valid and follows the pinned server style | Runtime concurrency or production behavior |
| OpenTofu format and deployment contract | Format check passed; 18 deployment-contract tests passed | Both previous-secret IAM dependencies are present and source remains valid | Live IAM propagation timing |
| Focused fresh-PostgreSQL regressions | Five lock-order, deletion, and erasure cases passed | The new paths execute without the reviewed lock inversion and retire active Safety state atomically | Production load or physical delivery |
| Complete managed-Safety suite | 23 tests passed on a clean PostgreSQL database | Existing invitations, contacts, incidents, push, expiry, and concurrency behavior remain compatible | Complete server compatibility |
| Existing account-erasure regression | Passed with the PostgreSQL overlay | Identity deletion and reenrollment behavior remains compatible with immediate Safety retirement | External identity-provider deletion |
| Complete clean server suite | 413 tests passed; one real-provider staging test intentionally skipped | Every locally available API, repository, migration, ownership, paging, lifecycle, tenancy, retention, and deployment contract remains compatible | Real provider traffic or hosted TimescaleDB behavior |
| Repository policy matrix | 187 release-control tests, 8 health-claims tests, 9 legal-inventory tests, the 1,195-file claims scan, 230-component legal inventory, i18n, privacy, calibration, required-CI, operations, terminology, ShellCheck, and diff checks passed | The replacement tree preserves repository release, claims, localization, provenance, privacy, and evidence contracts | Hosted exact-SHA checks or physical behavior |
| OpenTofu gates | Recursive format and validation passed; 4 ownership-default tests passed | The current and previous secret dependencies preserve the private default-off runtime contract | Live IAM propagation or service startup |

### Failed and corrected attempts

- A widened managed-Safety run reused the focused-test database. One existing
  test deliberately uses a single-use fixed invitation capability, so the
  second invocation correctly rejected that duplicate. The complete suite
  passed on a new clean database without changing product code or weakening
  uniqueness.
- The first release-policy rerun correctly rejected a stale terminology
  inventory after the new round shifted one historical index line. Regeneration
  changed only that line metadata: 17,376 classified occurrences, unchanged
  category counts, and zero forbidden mappings. The reviewed digest was pinned.
- The new round initially omitted the mandatory `Decisions` heading. The
  operations validator rejected it; the decision record was added before the
  complete 46-round validation passed.

## Physical device and deployment

- No public invoker, real push target, participant, phone, band, or health data
  was used.
- Physical APNs/FCM, terminated/background execution, latest-location
  continuation, haptic, battery, monitoring, failover, and staffed operations
  remain release gates.

## Git and release state

- Pull request `#10` remains the protected integration path.
- The replacement commit must pass complete local gates, exact-head automated
  review, every required hosted check, resolved verified conversations, and a
  normal protected merge.
- No release, tag, artifact, store upload, or public deployment is authorized
  by this round.

## Decisions

- Starting account erasure immediately retires active Safety authority; the
  cooling-off period may restore account access but must not silently revive a
  canceled incident or revoked response.
- Rolling push-token key rotation is deployable only after both configured
  secret versions are readable by each consuming service.
- Incident creation may use an eligibility snapshot only to choose a stable
  lock set; it must revalidate contact, profile, account, and block state while
  holding the final locks.
- Decision-log entry: this round record unless a broader account-erasure or
  Safety architecture decision supersedes it.

## Open risks and honest limitations

- Database tests cannot prove provider delivery or OS background behavior.
- Already-sent provider notifications cannot be retracted when erasure begins;
  authenticated incident access is retired server-side.
- The retained private synthetic GCP staging stack is intentionally not mutated
  by this source-review round.

## Next round

1. Push the replacement exact head and request a new automated review.
2. Resolve only findings proven closed on that exact head, require every
   protected check, and merge normally.
3. Rebase and verify the separate large-data lag branch against the merged
   Safety head.

## Privacy check

- [x] No credentials, project identifiers, phone numbers, participant
      identities, push tokens, incident identifiers, locations, health values,
      or absolute personal paths are present.
