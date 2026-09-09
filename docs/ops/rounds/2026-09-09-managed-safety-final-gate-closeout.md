# Round: 2026-09-09 - Managed Safety final gate closeout

## Status

- State: `implemented and completely locally verified; exact-head review pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `51f11179a2d50530320b6533d4f1716bd162ac5d`
- End implementation commit: commit containing this record
- Record commit or PR: protected pull request `#10`

## Objective

Close the three actionable exact-head review findings without weakening the
current Terms gate, app-to-app Safety privacy model, bounded contact model, or
urgent delivery semantics:

1. reject and defer managed push registration/catch-up until the current Terms
   version is accepted on Apple and Android;
2. bound pending requests received by one Safety profile and serialize that
   quota with request creation; and
3. dispatch due urgent Safety pushes before slower storage-lifecycle cleanup.

A later exact-head review of the previously green replacement head identified
three additional correctness gaps: deleting a responding contact could leave a
surviving incident falsely acknowledged, a successful contact request could
retain its replay record if the following refresh failed, and active-row limits
did not bound invitation create/revoke churn.

Success requires focused regressions, complete affected-platform verification,
clean repository policy gates, a replacement exact-head review, protected
checks, and normal merge. Physical push, background execution, location,
haptic, battery, legal, monitoring, failover, and staffed operations remain
external gates.

## Scope

### In scope

- Apple and Android current-Terms gating for remote Safety wake and push-token
  refresh paths, with a retry path after acceptance.
- PostgreSQL recipient-scoped pending-request quotas under the existing active
  profile/account lock order.
- Lifecycle ordering for due Safety push dispatch.
- Bounded diagnostics and regression coverage for accepted, deferred,
  rejected, and failed boundaries.
- Protected review, hosted verification, merge, and local temporary-resource
  cleanup.
- Account-scoped invitation churn limits that survive profile deletion, plus
  incident-state reconciliation when a responding profile is deleted.
- Apple and Android contact-request replay retirement immediately after the
  server confirms success.

### Non-goals

- Enable public ingress, real participant paging, carrier fallback, automatic
  medical/fall inference, or production traffic.
- Treat simulator builds as physical APNs/FCM, background, location, haptic,
  battery, or physiology evidence.
- Change Safety payload contents or retain additional location history.

## Starting evidence

- Reproduction or observed symptom: exact-head automated review on pull request
  `#10` identified an update-time Terms bypass, unbounded recipient request
  pressure, and urgent retry work ordered after potentially long cleanup.
- Relevant source/device/OS/firmware class: Apple and Android managed app push
  entry points plus the PostgreSQL managed Safety and lifecycle services.
- Existing tests, logs, exports, screenshots, or documents: all prior local
  Safety suites and the replacement protected checks were green before these
  findings; the review threads are bound to start commit `51f11179`.
- Unknowns that must remain unknown until measured: provider delivery,
  terminated/background wake, physical location continuation, band haptic,
  battery impact, and real operational latency.

## Delivered

- Apple and Android now fail closed at every managed push entry point until
  launch access is unlocked and the exact current Terms version is accepted.
  Pre-Terms token refresh, remote wake, notification presentation, and worker
  scheduling are rejected without bootstrapping the managed service.
- Apple preserves an APNs token received before acceptance only in process
  memory and retries configuration through the normal managed bootstrap after
  acceptance. Android uses the same local-only Terms receipt before Firebase,
  WorkManager, Room, or managed-service initialization.
- Notification taps preserve the pending Safety route but defer authenticated
  incident catch-up until the runtime gate is current.
- A Safety profile can receive at most 40 pending requests while retaining its
  existing allowance of 10 outgoing pending requests. The combined bound
  matches the 50-row request-list contract, and request creation holds the
  active contact profile/account row lock through count and insert.
- Idempotent request replay is checked before quota enforcement, so a lost
  response can be retried after the recipient reaches the bound.
- The lifecycle lease now dispatches due urgent Safety push retries before
  chunk reconciliation, retention deletion, export deletion, identity
  deletion, and expired-row cleanup. Due claims still expire stale incidents
  before selecting delivery candidates.
- Existing mobile diagnostics now distinguish fixed `terms_required` and
  `invalid_payload` outcomes. No token, payload, identifier, location, health
  value, arbitrary error, or user content is recorded.
- Migration `031` adds an account-scoped Safety invitation quota ledger. It
  retains consumed request IDs and capability hashes independently of the
  profile-scoped invitation row, caps creation at 50 per rolling 24 hours, and
  preserves same-request replay. Profile deletion and recreation cannot reset
  the limit or reuse a retained capability.
- Deleting a social profile now locks every surviving active incident in which
  that profile participates, lets the existing cascade remove the participant,
  and recomputes acknowledgement from the remaining responders in the same
  transaction.
- Apple and Android clear a successful contact-request replay record before
  applying local presentation state or refreshing Safety data. A refresh
  failure therefore cannot resend a request already accepted by the server.

## Data, privacy, and medical truth

- Schema or migration impact: additive migration `031` creates
  `managed_safety_invite_quota_events`, keyed by account and client request,
  with unique invite and capability hashes. Existing retained invitations are
  backfilled idempotently.
- Existing-data retention impact: the new ledger retains only UUIDs, one
  capability digest, and timestamps through the invitation's existing bounded
  purge horizon. It contains no capability, profile, contact, location, or
  health payload.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: no new permission or payload;
  pre-Terms managed network work must remain disabled.
- Health/medical claim impact and limitations: none; manual Safety paging is not
  medical diagnosis or automatic emergency detection.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  `managed_safety.push_received`, push-token refresh, provider-dispatch, request
  rejection, lifecycle result, and request-correlation evidence.
- Why existing evidence is sufficient, or why new evidence is required:
  mobile Terms rejection must retain a fixed categorical outcome; server quota
  rejection uses the existing typed rate-limit boundary; lifecycle result
  counts already expose push dispatch outcomes.
- Existing evidence reused: Apple and Android `AppDiagnosticsRecorder`, server
  request middleware, and `emit_operational_event`.
- New bounded events or operation spans: none. Contact-request operations
  already record fixed success/failure categories, typed rate-limit responses
  are covered by request middleware, and profile deletion plus incident
  reconciliation is one transaction whose failure rolls back the deletion.
- Redaction, retention, and high-frequency controls: fixed categories and
  bounded counts only; no Terms content, identity, token, incident payload,
  location, health value, arbitrary error, or dynamic identifier.
- Cross-platform/backend correlation: static event names and server-generated
  request IDs remain the correlation boundary.
- Remaining blind spots: physical provider delivery and OS relaunch behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-head review | Three unresolved actionable findings on `51f11179` | The remaining source defects are explicitly identified before merge | That any replacement implementation is correct |
| Focused server regressions | Lifecycle and policy: 9 passed. Fresh PostgreSQL recipient-race and replay cases: 2 passed. Ruff and Python compilation passed. | Urgent retry ordering, serialized recipient quota, and replay semantics execute against the changed paths | Provider delivery or production database behavior |
| Late-review focused server regressions | Five fresh-PostgreSQL migration, invitation-churn, profile-deletion, cascade, and lock-order cases passed; Ruff and Python compilation passed | The account-scoped rolling quota, retained replay/capability rules, incident reconciliation, and deletion concurrency execute against migration `031` | Complete-suite compatibility or production database behavior |
| Complete local server suite | 393 passed, 19 expected skips, and one dependency deprecation warning against a fresh PostgreSQL database | Every locally available server path remains compatible with the quota, migration `031`, profile-deletion reconciliation, and lifecycle changes | Real provider traffic, the unavailable external lanes, or hosted exact-head CI |
| Android complete gate | 4,142 Full unit tests passed with zero failures/errors and 7 skips; lint, Full debug APK assembly, and instrumentation-source compilation passed | The current-Terms gate, scheduler, messaging service, app graph, and source contracts compile and pass repository tests | Physical FCM, process death, OEM background limits, location, haptic, battery, or band behavior |
| Apple focused and complete gates | 33 Safety tests passed; the full Strand suite passed 1,666 tests with one expected data-dependent skip and zero failures; the `NOOPiOS` generic simulator graph built for arm64 and x86_64 across the app, widget, and watch targets | Runtime authorization, replay retirement ordering, tap deferral, post-accept bootstrap, shared source, and iOS application compilation are intact | Signed physical APNs, terminated/background wake, location continuation, haptic, battery, or App Store behavior |
| Fresh-eyes source review | Gate placement, post-accept retry, profile-lock serialization, replay ordering, request-list capacity, and expiry-before-claim behavior were re-read after tests | The implementation closes the three reviewed source defects without weakening idempotency or expiry | Runtime behavior unavailable without physical/provider evidence |
| Repository release matrix | 227 Tools tests and 49 localization-audit tests passed; no-new-copy i18n, 9 release controls, required CI, calibration parity, terminology, health claims across 1,195 files, private-data, legal inventory across 230 runtime components, distribution provenance, workflow-scoped ShellCheck, Ruff, Python compilation, operations-record validation, and diff checks passed | The final local tree preserves protected-release, localization, claims, privacy, provenance, and evidence contracts | Hosted exact-SHA checks or protected merge |

### Failed and corrected attempts

- Running ShellCheck over every historical utility included unsupported zsh
  scripts and known findings in unrelated legacy helpers. The repository's
  required workflow scope, `Tools/release.sh` and
  `Tools/publish-testing-snapshot.sh`, passes.
- The system Python does not include Ruff. The retained isolated server
  environment used by the complete server verification passes Ruff.
- A direct localization audit without its CI baseline correctly printed the
  tracked backlog and returned nonzero. The required
  `Tools/i18n_audit.py --ci origin/main` gate reports no new Android or Apple
  copy and complete focus locales.
- The first localization unit-test invocation used the repository root, where
  the script module is not importable by name. Running the documented test
  module from `Tools` passes all 49 cases.
- The first exact-head hosted server run passed Ruff lint but failed
  `ruff format --check` for the two edited Safety repository/test files. The
  pinned formatter changed layout only; focused server regressions and every
  local release-policy gate were rerun before the replacement push.
- The first post-format focused rerun reused a prior integration database and
  collided with a deliberately single-use synthetic invitation capability. A
  fresh `template0` database passed all 27 lifecycle and managed-Safety tests;
  the temporary database was then removed.
- The first late-review focused invocation used an outdated test function name
  and collected no matching case. The corrected five-case selection passed
  against a fresh throwaway database, which was removed by the test trap.
- A replacement hosted iOS run on the preceding head was canceled after the
  later exact-head review found three new actionable defects. It is not
  evidence against the current implementation; a new exact-head run is
  required after this patch is pushed.
- The first complete late-review server run passed every runtime and migration
  case but failed the immutable-backup manifest contract because migration
  `031` had not yet been listed. Its exact SHA-256 was added to the manifest
  before rerunning the contract and complete suite.
- The first late-review Tools suite reported three errors from one expected
  fail-closed condition: the reviewed source digest still named the prior
  terminology inventory. Review confirmed the inventory delta was only five
  shifted historical-test line numbers, with unchanged counts, unchanged
  active allowlist, and zero forbidden mappings; the exact new digest was then
  pinned before rerunning the suite.

## Physical device and deployment

- Install/update action: unsigned local simulator/debug builds only.
- Generalized device and OS class: Apple simulator and Android compile/test
  graph; no physical phone was touched.
- Data-preservation result: no physical app container was changed.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: APNs/FCM delivery, terminated/background execution,
  location permission and continuation, haptic, battery, and representative
  physical phones.

## Git and release state

- Changed paths: Apple application delegate and notification routing, Android
  application/runtime gate/scheduler/messaging service, managed Safety and
  social repositories/lifecycle, migration `031`, focused regressions,
  terminology inventory, required-CI digest, and operations records.
- Commits: the replacement implementation is the commit containing this
  record.
- Branch and remote state: pull request `#10` remains the protected integration
  path; the prior head is obsolete and this replacement requires exact-head
  review and checks.
- Repository visibility verified: inherited from the current protected round.
- Version/build impact: no version change planned.
- Release or distribution impact: none until replacement review and protected
  merge; no public traffic is authorized.

## Decisions

- Durable decision added or changed: current Terms acceptance gates every
  managed push entry point, not only normal app startup.
- Decision-log entry: this round record unless a broader architecture decision
  changes.

## Open risks and honest limitations

- Passing source and simulator tests cannot establish provider delivery or
  physical background behavior.
- A recipient quota must preserve idempotent replay and existing invitation
  semantics while preventing request-list starvation.
- Invitation limits must survive create/revoke churn and profile recreation
  without retaining the secret capability or exposing account identifiers in
  diagnostics.
- Urgent dispatch-first ordering improves retry latency but does not replace
  monitoring, failover, or staffed operations.

## Next round

1. Run the complete server, Android, Apple, policy, migration, and operations
   gates for the late-review head.
2. Push the replacement head, resolve all exact-head threads, and require a
   clean review plus every protected hosted check before a normal merge.
3. Integrate and reverify the separate large-data scroll-lag pull request. A
   friend pulling yesterday's `main` did not receive those performance fixes.
4. Collect a reviewed shake-to-report ZIP while lag reproduces on the affected
   physical phone after the merged-main build is installed.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
