# Round: 2026-09-09 - Managed Safety race closeout

## Status

- State: `implemented and locally verified; replacement exact-head review pending`
- Owner: project team
- Branch: `codex/managed-app-safety-paging-20260908`
- Start commit: `33ae426edf363865b0f44b4b0fc864f4f43228e0`
- End implementation commit: pending
- Record commit or PR: protected pull request `#10`

## Objective

Close every actionable finding from the automated review of the exact
replacement head while preserving tenant isolation, push-token
confidentiality, retry safety, cross-platform behavior, localization, and the
existing external launch gates.

## Scope

### In scope

- Make owned Safety invitation revocation idempotent after redemption,
  expiration, prior revocation, or response loss.
- Make accepted-contact removal idempotent after response loss.
- Bind an invalid provider receipt to the exact push-token hash claimed for
  that delivery so a stale receipt cannot invalidate a rotated token.
- Serialize managed push registration with disconnect revocation on Apple and
  Android.
- Correct the post-redemption instruction in all nine supported locales.
- Add focused regressions, rerun every affected full gate, obtain a clean
  exact-head review, and merge only through protected controls.

### Non-goals

- Enable public traffic, automatic emergency inference, SMS or voice paging,
  or real participant paging.
- Claim physical APNs or FCM delivery, terminated execution, background
  location, haptic, battery, legal, monitoring, failover, or staffed
  operations evidence.

## Starting evidence

- Exact reviewed head:
  `33ae426edf363865b0f44b4b0fc864f4f43228e0`.
- The exact-head reviewer identified five remaining defects: two non-idempotent
  delete paths, stale invalid-receipt token retirement, a registration versus
  disconnect race on both mobile platforms, and reversed invitation
  acceptance copy.
- Required hosted checks on the prior head were green or still running when
  this remediation began; no failing hosted check was hidden.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: none planned.
- Source, provenance, or formula impact: none.
- Permissions or network disclosure impact: none.
- Health or medical claim impact: none.

## Observability

- Existing `managed_safety.push_registration`,
  `managed_safety.push_revocation`, operation-correlation, and bounded provider
  receipt outcomes cover the changed network boundaries.
- Evidence remains limited to fixed outcomes, reasons, durations, and counts.
  Tokens, token hashes, account or installation identifiers, contact or
  incident identifiers, coordinates, provider bodies, payloads, and arbitrary
  exception text remain excluded.
- Delete retries remain visible through existing request correlation and
  fixed operation outcomes; no additional high-frequency event is warranted.

## Delivered

- Safety invitation revocation is idempotent for an already redeemed, expired,
  revoked, purged, foreign, or missing invitation. The endpoint does not reveal
  whether another account owns the supplied opaque identifier.
- Accepted-contact removal is idempotent after a committed response is lost;
  repeated client cleanup can refresh and clear local presentation state.
- Every claimed push delivery now carries the exact token hash used for that
  provider attempt. An invalid receipt retires an installation only while its
  active token still matches that claim, preserving a later token rotation.
- Apple tracks main-actor-confined push registrations and waits for every
  in-flight registration before disconnect revocation. Android serializes
  registration and disconnect revocation through one mutex after setting the
  volatile disconnect flag. Both reject post-registration publication when
  managed state changed.
- The invitation redeemer is told to accept the request in Contact requests.
  The source catalog and all nine generated Apple and Android locales carry the
  corrected instruction.
- Existing bounded `managed_safety.push_registration` and
  `managed_safety.push_revocation` evidence now includes a fixed
  `managed_state_changed` cancellation reason. No token, token hash, account,
  installation, contact, incident, coordinate, provider body, or arbitrary
  exception text is recorded.
- The terminology snapshot was regenerated after the source-line and
  localization changes. It records 17,376 classified occurrences, zero
  forbidden mappings, and no active-allowlist change. The required-CI digest
  pins that exact reviewed inventory.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused server regressions | Push service: 20 passed. Fresh PostgreSQL review cases: 3 passed. Full managed-Safety file: 16 passed. | Idempotent delete paths, stale invalid-receipt protection, and push-service hash propagation work against an isolated database. | Provider delivery or production database behavior |
| Complete local server suite | 388 passed, 19 skipped, 1 dependency deprecation warning in 56.52 seconds; Ruff passed and all 67 Python files were already formatted | Every locally available server path remains compatible; changed PostgreSQL-overlay paths execute against a fresh `template0` database | The unavailable local Timescale lane and real-Twilio staging test; protected hosted CI remains the exact-head gate |
| Android complete gate | 4,140 tests, zero failures/errors, 7 skips; lint, Full debug APK assembly, and instrumentation-source compilation passed in 6 minutes 8 seconds | Android serialization, copy, generated resources, and application graph compile and pass repository tests | Physical FCM, terminated/background execution, location, haptic, battery, or OEM behavior |
| Apple focused and app gates | 31 Safety tests passed with zero failures; clean `NOOPiOS` simulator graph built successfully | Main-actor registration tracking, disconnect ordering, corrected copy, and iOS application compilation | Signed physical APNs, background location, haptic, battery, or App Store behavior |
| Localization | Safety generator produced 313 strings for 9 locales idempotently; full i18n audit and 49 audit tests passed with no translated-key gaps | Apple and Android ship the corrected supported-locale instruction from one source catalog | Human linguistic review by native speakers |
| Repository release matrix | 227 Tools tests; 9 release checks; required CI, calibration parity, terminology, health claims, distribution, private-data, shell syntax, and shellcheck gates passed | The exact local tree preserves protected-release, claims, privacy, and evidence contracts | Hosted exact-SHA checks or protected merge |
| Review of diagnostics | Existing registration/revocation operation spans plus fixed cancellation and failure categories cover success, rejection, cancellation, and failure | A reviewed app report can distinguish the changed lifecycle states without retaining private payloads | Provider-side traces or physical radio behavior |

### Failed and corrected attempts

- The first PostgreSQL stale-receipt fixture omitted the required
  `last_attempt_at` value for a `sending` delivery. The fixture was corrected
  and the focused and complete suites passed.
- A reused synthetic invitation capability collided across reruns. The test now
  generates a unique valid capability, and clean reruns pass.
- An initial shell wrapper used zsh's read-only `status` name after pytest had
  already passed. The corrected wrapper and retained pytest output confirm the
  product result.
- The first localization audit invocation used an unsupported `--check` flag.
  The repository's supported full audit and all 49 audit tests pass.
- The first required-CI rerun correctly rejected the stale terminology digest.
  The inventory was regenerated, reviewed, repinned without changing the
  active allowlist, and every release-control test then passed.
- A clean-build wrapper attempted to remove a temporary DerivedData directory
  and was rejected before Xcode ran. A new isolated DerivedData path was used;
  the complete iOS build passed.

## Physical device and deployment

- Install or update action: unsigned local simulator/debug builds only; no
  physical app container was changed.
- BLE, background, haptic, battery, APNs, FCM, and physical location scenarios:
  not run.

## Git and release state

- Branch: `codex/managed-app-safety-paging-20260908`.
- Protected pull request: `#10`.
- Exact replacement commit: pending this record's commit and push.
- No public traffic, real participant paging, tag, artifact, or release is
  enabled by this round.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: not required.

## Open risks and honest limitations

- Source, simulator, and local PostgreSQL tests do not prove physical push,
  background location, haptic, battery, or provider behavior.
- Legal, monitoring, failover, and staffed-operations gates remain external.

## Next round

1. Push the replacement head and reply to the five review threads with exact
   implementation and test evidence.
2. Require a clean review of that exact commit plus every protected hosted
   check, including the Timescale-backed server lane.
3. Merge normally without bypassing protected branch controls.
4. Rebase and reverify the separate large-data scroll-lag pull request before
   merging it, then collect a user-reviewed report from the affected phone.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, dynamic Safety identifiers, locations,
      or absolute personal paths are present.
