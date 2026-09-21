# Round: 2026-09-20 - Managed erasure and Safety infrastructure remediation

## Status

- State: `focused implementation and verification complete; branch integration pending`
- Owner: project team
- Branch: `codex/ui-cloud-readiness-20260917`
- Start commit: `3edddda180963444b8eb8caa48e5298623cd66f4`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#16`; consolidated replacement push
  pending

## Objective

Close five bounded review findings without changing the managed formula
executor:

1. fence managed chunk reservation, upload-grant activation, and completion
   while an ownership-led `all_managed_data` erasure is pending;
2. include `managed_formula_shadow_results` in derived/account erasure and
   direct database verification;
3. serialize ownership-account deletion cancellation against managed-erasure
   claim and scheduling with the existing account lock and terminal-state
   contract;
4. explicitly configure bounded managed Safety repeat paging in the GCP
   runtime while public traffic and provider delivery remain default-off; and
5. give Android FCM Safety pages the same incident-scoped collapse/dedup
   behavior as APNs.

Success requires focused synthetic tests, bounded privacy-safe observability,
no secrets or health data, a scoped local commit, and no remote push.

## Scope

### In scope

- Managed storage repository/API fences for ownership-led broad erasure.
- Managed and ownership deletion lock ordering and terminal-state handling.
- Direct PostgreSQL erasure verification for formula shadow rows.
- Default-off GCP runtime configuration for bounded Safety repeats.
- Android FCM incident collapse/dedup payload parity.
- Focused server, infrastructure, and Android tests.

### Non-goals

- Any change to `server/app/managed_formula_executor.py`.
- Public invocation, production traffic, real provider delivery, real contact
  or location transfer, or automatic emergency inference.
- Apple, BLE, analytics, UI, managed-history import, or macOS remediation.
- Reworking the pre-existing dirty files owned by other slices:
  `Packages/NoopRemoteSync/Sources/NoopRemoteSync/ManagedHistoryImport.swift`,
  `Packages/NoopRemoteSync/Tests/NoopRemoteSyncTests/ManagedHistoryImportTests.swift`,
  `Strand/App/AppRuntimeRole.swift`, `Strand/BLE/BLEManager.swift`,
  `Strand/Data/IntelligenceEngine.swift`,
  `StrandTests/BandDiagnosticsTests.swift`,
  `StrandTests/LiquidTodayFeatureMountTests.swift`, and
  `StrandTests/MacViewerRuntimeContractTests.swift`.

## Starting evidence

- Reproduction or observed symptom: protected-review findings identified that
  a pending ownership-led broad erasure did not fence all managed upload
  lifecycle mutations, formula shadow rows were omitted from erasure, account
  deletion cancellation could race erasure claim/scheduling, GCP did not
  explicitly wire the bounded repeat policy, and FCM lacked APNs-equivalent
  incident collapse.
- Relevant source/device/OS/firmware class: PostgreSQL/FastAPI managed and
  ownership services, OpenTofu GCP runtime, Android FCM payload construction.
- Existing tests, logs, exports, screenshots, or documents: managed repository,
  ownership PostgreSQL, managed erasure, managed push, and OpenTofu plan tests.
- Unknowns that must remain unknown until measured: production lock pressure,
  deployed IAM/configuration, APNs/FCM delivery, Android OS presentation, and
  real participant behavior.

## Delivered

- Fenced managed upload mutations during broad ownership-led erasure.
- Added migration 057 and direct verification for formula-shadow erasure.
- Serialized ownership cancellation against managed-erasure claim/scheduling.
- Wired bounded default-off Safety repeat settings and Android incident
  collapse/dedup parity.
- Preserved the published `noop-charge-v2` behavior after review found an
  unversioned optional-baseline change; no net formula behavior change remains
  in this round.
- Made account enrollment report existing consent/upload state truthfully and
  bound enrolled installations to their stored platform and selected plan
  limit.
- Made migration 058 fail closed when any pre-existing Friends communication
  column has the wrong type, nullability, generated state, or default.
- Limited ownership-deletion advisory-lock attempts to the already bounded
  claimed batch instead of attempting locks across every due account before
  `LIMIT`.
- Strengthened account-only erasure verification with real managed Friends
  profile and alias rows, and added mobile App Check cross-platform rejection
  plus lowered installation-limit coverage.
- Split database authority across one migration principal and five
  workload-specific runtime principals and Secret Manager containers:
  private API, managed API, managed processor, managed lifecycle, and feedback
  lifecycle.
- Made credential provisioning fail closed and compensating: a failed secret
  publication or verification restores the previous Cloud SQL password, or
  quarantines a newly created runtime principal, before returning failure.

## Data, privacy, and medical truth

- Schema or migration impact: migration 057 adds formula-shadow erasure
  coverage; migration 058 adds false-default Friends communication columns.
- Existing-data retention impact: deletion coverage becomes stricter for the
  requested account; no unrelated account data is changed.
- Source/provenance or formula impact: no formula implementation or result
  computation changes.
- Permissions/network disclosure impact: no public traffic or provider
  delivery enablement; runtime settings remain default-off.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  bounded managed-operation and ownership deletion outcomes plus direct
  database assertions for rejected mutations, terminal state, and deleted-row
  counts. Account and storage enrollment now emit one bounded outcome event
  containing only `created`, `existing`, or `rejected`, the declared platform,
  and storage data-class count.
- Why existing evidence is sufficient, or why new evidence is required:
  repository mutations already emit fixed operation outcomes at the API and
  lifecycle boundaries; focused tests will pin the new rejection and deletion
  behavior without adding payload logging.
- Existing evidence reused: request correlation, fixed operation categories,
  bounded lifecycle counts, and provider-free push payload construction tests.
- New bounded events or operation spans:
  `managed_account.enrollment` and `managed_storage.enrollment`.
- Redaction, retention, and high-frequency controls: no account, incident,
  contact, token, location, health value, payload, or exception text enters
  diagnostics.
- Cross-platform/backend correlation: APNs and FCM share the opaque incident
  identifier only inside provider payloads; diagnostics remain identifier-free.
- Remaining blind spots: deployed provider behavior, physical-device delivery,
  and production contention.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Context snapshot and dirty-state review | Passed | Correct isolated branch and unrelated dirty ownership are known | Product correctness |
| Tools wall | 305 passed, 1 intentional skip; top-level i18n 50 passed | Required controls and tooling remain green after terminology review | Platform/runtime behavior |
| Focused server formula/API tests | Passed | Published formula revision is stable and account enrollment returns bounded truthful state | PostgreSQL integration without a configured disposable database |
| Independent server/infrastructure review | No P0; unresolved P1/P2 findings recorded | Release blockers are bounded instead of hidden | Their correction or production deployment |
| Migration 058 PostgreSQL 16 wall | 19 passed | The additive migration is idempotent and rejects each malformed type/null/default variant for all four communication columns | Production migration duration or drift outside the tested contracts |
| Consolidated disposable PostgreSQL wall | 38 passed | Migration 058, real Friends account erasure, reduced installation-limit enforcement, ownership claim/reclaim, and lifecycle contracts pass together | Production contention, regional Cloud SQL, or deployed credentials |
| Mobile enrollment API and bounded event wall | 4 passed; Ruff check and format check passed | iOS/Android App Check claims cannot cross-enroll, accepted Android account enrollment succeeds, and only bounded enrollment outcomes are emitted | Signed physical App Check enforcement |
| Complete server wall against disposable PostgreSQL 14 | 783 passed, 1 intentional skip, 1 warning | The complete server suite remains green with the erasure, enrollment, migration, lifecycle, observability, database-principal, and Friends communication changes integrated | Cloud SQL behavior, production load, or PostgreSQL 16 parity beyond the focused migration wall |
| Database-role provisioning contracts | 13 passed; Python compilation and shell syntax passed | Exact release-migration verification, per-workload relation grants, migration/runtime separation, and compensating password restore or first-time-role quarantine execute without printing secrets | Live Cloud SQL role creation, credential rotation, or service restart behavior |
| Production deployment contracts | 22 passed | Terraform and deployment source bind each workload to its own database secret and identity, pin numeric secret versions, and keep public traffic/provider delivery default-off | Apply behavior, provider drift, or deployed service health |
| OpenTofu plan-only infrastructure wall | 20 passed, 0 failed | Migration-only IAM, five workload-specific runtime identities and secrets, pinned credential versions, ownership defaults, feedback gates, and default-off public traffic plan together | Apply behavior, provider drift, or deployed service health |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: not run
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: Android physical FCM receipt, audible presentation,
  background wake, and provider collapse behavior

## Git and release state

- Changed paths: pending
- Commits: pending
- Branch and remote state: local branch only; no push authorized
- Repository visibility verified: not changed
- Version/build impact: none planned
- Release or distribution impact: none until later protected integration

## Decisions

- Durable decision added or changed: none; existing deletion and Safety
  contracts are being enforced.
- Decision-log entry: not required unless implementation changes policy.

## Open risks and honest limitations

- Source and PostgreSQL tests cannot prove deployed provider behavior,
  production contention, or physical Android notification collapse.
- The source-defined GCP setup now separates migration authority from five
  workload-specific restricted runtime credentials, but provisioning and
  secret rotation have not been applied to a live Cloud SQL instance.
- Database row-level security is not claimed. Current defense in depth is
  application tenant authorization plus workload-specific relation grants;
  live least-privilege and cross-tenant staging evidence remains required.
- Fresh branch-wide Apple, Android, server, infrastructure, policy, and hosted
  exact-SHA checks remain required before protected integration.

## Next round

1. Integrate only after independent review and the complete required protected
   checks pass on the eventual pushed candidate.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
