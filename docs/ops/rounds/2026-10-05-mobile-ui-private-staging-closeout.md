# Round: 2026-10-05 - Mobile UI and private staging closeout

## Status

- State: `mobile product integrated; corrected private staging deployed and verified; lifecycle follow-up protected integration pending`
- Owner: project team
- Branch: `codex/mobile-ui-private-staging-rollout-20261005`
- Product merge: protected PR `#33`, merge
  `f6b19568bac65acfc5e1803862ae7a1aa56696ba`
- Deployment implementation commit:
  `9b835fe9c81c296a5eb297255c372eb43ef0d60f`
- Record commit or PR: pending protected follow-up
- Environment: private synthetic GCP staging only

## Objective

Close the consolidated mobile refinement and its required private-cloud rollout
without converting simulator or synthetic evidence into a physical-band claim.
Success requires:

- protected integration of the metric-first Today surface, complete Trends
  access, movable NOOP `N`, unified customer scanner, and cross-platform
  onboarding behavior;
- zero customer-visible retired vendor naming while preserving required
  internal protocol, persisted, provenance, import, and legal identifiers;
- one immutable reviewed server image, a zero-finding scan, guarded migration,
  private workload rollout, least-privilege lifecycle execution, complete
  fictional managed-runtime smoke, configuration restoration, and zero drift;
- no public invocation, real phone number, real health data, supplier binary,
  firmware flash, signed install, or physical-device claim.

## Scope

### In scope

- Protected-main integration and exact hosted checks for PR `#33`.
- The server/static changes included by that product merge.
- Feedback and managed-lifecycle pool, secret-version, database-role, and
  account-erasure corrections found while rolling out the merged image.
- Immutable build, remote vulnerability scan, OpenTofu apply, migration,
  lifecycle jobs, private verifier, fictional end-to-end smoke, cleanup, and
  no-drift proof.
- Customer-facing naming review across Apple, Android, web, notifications, and
  exports.
- Exact cleanup of stale NOOP build products that were consuming local disk.

### Non-goals

- Public Cloud Run ingress, production customer traffic, payment, or launch.
- Real OTP, carrier delivery, APNs/FCM delivery, signed App Attest or Play
  Integrity proof, or customer identity recovery.
- BLE, supplier transport, firmware, haptics, battery, background collection,
  sensor accuracy, retention, or physiological validation on physical devices.
- Removing internal compatibility identifiers required for protocol,
  persistence, provenance, imports, migrations, tests, or legal notices.

## Starting evidence

- PR `#33` had merged the mobile product changes to protected `main`, but
  private staging still served an older server image.
- The retained staging runtime was private and synthetic, with separate
  workload credentials and App Check enforced.
- Local storage had fallen to approximately `16 GiB` free because stale NOOP
  Xcode, Android, Swift, Node, temporary-clone, and diagnostic build products
  accumulated.
- Physical-device validation remained explicitly unrun.

## Delivered

- Verified PR `#33` merged at
  `f6b19568bac65acfc5e1803862ae7a1aa56696ba` with all required hosted
  contexts successful. The integrated product keeps Today metric-first,
  preserves complete metric history and Trends interaction, uses the movable
  geometric NOOP `N`, and routes both customer band entries through unified
  live discovery.
- Completed an independent read-only customer-brand audit. Apple, Android,
  web, notification, and export boundaries expose zero customer-visible
  retired vendor values; internal protocol, persisted, provenance, import,
  historical, and legal compatibility identifiers remain intact.
- Reclaimed approximately `25 GiB`, increasing free space from about `16 GiB`
  to `41 GiB`. Cleanup removed only stale NOOP build outputs and a failed
  diagnostic virtual environment. Source, branches, dirty work, simulator and
  phone data, screenshots, test evidence, secure configuration, and the active
  deployment checkout were preserved.
- Corrected feedback lifecycle sizing by disabling the unrelated embedded
  Safety worker in the bounded lifecycle job. Its concurrency otherwise
  exceeded the two-connection job pool.
- Corrected enabled Secret Manager version detection to use the provider's
  uppercase `ENABLED` state instead of silently treating an existing version
  as absent.
- Kept runtime principals least-privilege while adding only the lifecycle
  access required by managed account erasure:
  - execute on the two indirect erasure-context helpers;
  - `SELECT` plus four-column `UPDATE` on unified account principals;
  - `SELECT, DELETE` on unified managed-account links;
  - `SELECT` on unified ownership-account links.
- Added negative provisioning tests that reject principal insert/delete,
  managed-link insert/update, or ownership-link mutation.
- Diagnosed the first deployed lifecycle failure as missing transitive erasure
  permissions, reprovisioned the lifecycle principal through the guarded
  secret workflow, and proved the corrected grants with a local
  `finalize_erasure_jobs` execution.
- Diagnosed the second deployed lifecycle failure as a real account-erasure
  state-machine defect. Ten prior synthetic jobs had completed database and
  object erasure, created their tombstones, and entered external-identity
  deletion with the account correctly marked `erased`; a repeated lifecycle
  pass incorrectly required the earlier `erasure_pending` fence.
- Corrected the state machine so external-identity deletion can continue only
  when all four completion facts agree: the identity target is pending or
  running, the account is erased, the database target is completed, the
  object-storage target is completed, and the matching account tombstone
  exists. Any inconsistent state still raises a fail-closed conflict.
- Added a PostgreSQL regression that proves both the repeated valid lifecycle
  pass and rejection when the database completion marker is removed.
- Built immutable image
  `asia-south1-docker.pkg.dev/noop-health-stg-20261002/noop-staging/api@sha256:36ad895879c84c226b006469f4ceb8f2fb5cf1abd5c5e5c761fa5233ec698192`
  from commit `9b835fe9c81c296a5eb297255c372eb43ef0d60f`.
  Cloud Build `71b1d976-d6ca-4e54-8a04-3bc3eb58c1f2` succeeded.
- Remote scan operation
  `1e75c5a1-fd56-44d3-a695-c3039ada3130` reported zero vulnerabilities at all
  severities.
- Applied the reviewed seven-resource image rollout: the private API, managed
  API, managed processor, migration job, managed lifecycle job, feedback
  lifecycle job, and migration execution marker. No IAM, database, storage,
  identity, public-ingress, or scheduler resource was widened.
- Migration execution `noop-staging-migrate-q8df7` completed successfully with
  release marker `57910e5d3a93e816`.
- Kept secret references pinned to numeric versions only:
  migration `2`; private API `8`; managed API `5`; managed processor `5`;
  managed lifecycle `5`; feedback lifecycle `5`; feedback capability current
  and previous `3`.
- Proved both corrected lifecycle jobs manually:
  `noop-staging-managed-lifecycle-s9rv5` and
  `noop-staging-feedback-lifecycle-zmrl5` completed successfully.
- Resumed both schedulers and proved scheduled executions, including managed
  executions `noop-staging-managed-lifecycle-pbcjg`,
  `noop-staging-managed-lifecycle-d2w8j`, and
  `noop-staging-managed-lifecycle-lfxft`, plus feedback execution
  `noop-staging-feedback-lifecycle-hgqs2`.
- Passed the complete private managed-runtime smoke in `202` seconds:
  fictional OTP and App Check, three disposable identities, pilot claims,
  enrollment, upload, processing, idempotency, isolation, restore, object
  erasure, Friends, disposable Safety targets, fail-closed fictional delivery,
  social cleanup, account erasure, and provider-identity cleanup.
- Restored Identity Platform to exactly one retained fictional phone and
  verified zero App Check debug tokens.
- Re-ran the private-runtime verifier and a final OpenTofu
  `-detailed-exitcode` plan. Private IAM boundaries passed and the plan
  reported `No changes`.

## Data, privacy, and medical truth

- Schema or migration impact: no new migration; the guarded migration job
  revalidated the existing manifest under the new image.
- Existing-data retention impact: synthetic staging only. The lifecycle
  completed previously queued fictional erasures.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: least-privilege database access was
  narrowed to the required erasure path; Cloud Run remains IAM-only with zero
  broad invoker bindings.
- Health/medical claim impact and limitations: no real health data,
  physiological inference validation, sensor validation, or physical-band
  evidence was produced.

## Observability

- Success evidence: exact Cloud Build and scan receipts, migration marker and
  execution, Cloud Run Ready conditions, manual and scheduled lifecycle
  executions, bounded smoke checkpoints, private-IAM verification, cleanup
  counts, and no-drift output.
- Failure evidence: the first runtime failure was a redacted database privilege
  failure; the second was the bounded
  `ManagedConflictError: managed account erasure lost its account fence`.
  Dynamic account, phone, token, credential, and payload values were not
  logged or copied into this record.
- Existing evidence reused: fixed-route operation events, release controls,
  terminology and localization audits, protected hosted checks, and guarded
  database-secret provisioning.
- New high-frequency logging: none. The account-erasure repair uses durable
  database state and existing bounded lifecycle events instead of payload or
  per-row logging.
- Remaining blind spots: signed clients, provider delivery, physical BLE,
  supplier hardware, background execution, battery, haptics, firmware, sensor
  accuracy, real retention, and production load.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| PR `#33` protected integration | Merged at `f6b19568b`; required contexts successful | The consolidated mobile product is on protected `main` | Physical behavior or cloud rollout |
| Independent customer-brand audit | Terminology and i18n audits passed; zero customer-visible retired vendor values | Current Apple, Android, web, notification, and export boundaries are neutral | Future dynamic content outside the sanitizer contracts |
| Storage cleanup | Free space increased from about `16 GiB` to `41 GiB` | Stale regeneratable NOOP build output was removed | Cloud cost or simulator data reduction |
| Focused Python wall | Database-role and deployment-contract tests passed; managed lifecycle `12/12`; account cloud erasure `6/6`; PostgreSQL account-erasure regression passed | Least-privilege grants and the repeated identity-erasure phase behave as designed | Production load or external identity-provider availability |
| OpenTofu feedback wall | `8/8` passed with the live deployment override explicitly reset | Lifecycle defaults and bounded drain behavior remain enforced | Live provider behavior |
| Immutable build and scan | Build `71b1d976...` succeeded; zero scan findings | The deployed image is exact and had no known scan findings | Future disclosures |
| Migration | `noop-staging-migrate-q8df7` succeeded; marker `57910e5d3a93e816` | Existing guarded schema is compatible with the image | A new schema change |
| Runtime readiness and IAM | All six workloads Ready on one digest; zero broad service invokers | Private staging is deployed without public invocation | Application behavior |
| Managed lifecycle | Manual and resumed scheduled executions succeeded | Corrected role and account-erasure state machine run in Cloud Run | Long-duration reliability |
| Feedback lifecycle | Manual and resumed scheduled executions succeeded | Bounded feedback cleanup runs with ingestion-independent credentials | Public feedback readiness |
| Private synthetic smoke | Passed in `202` seconds | Fictional managed identity, storage, social, Safety fail-closed, and erasure paths work end to end | Real SMS, push, signed attestation, or physical devices |
| Synthetic cleanup | One fictional phone configuration and zero App Check debug tokens | Temporary smoke configuration was restored | Production user recovery |
| Private verifier and drift | Passed; OpenTofu reported `No changes` | Applied infrastructure matches reviewed configuration | Future drift |

## Physical device and deployment

- Install/update action: private synthetic cloud runtime updated; no signed
  mobile candidate was installed.
- Generalized device and OS class: simulator/emulator evidence belongs to the
  protected product round; no clean supported physical iPhone or Android phone
  was used here.
- Data-preservation result: no phone or simulator data was erased during
  storage cleanup.
- BLE/background/haptic/battery scenarios exercised: none.
- Unrun hardware gates: all signed-phone, WHOOP comparison, supplier-band,
  connection, battery, live data, history catch-up, background, notification,
  diagnostics, accessibility, source-switching, haptic, firmware, and sensor
  accuracy cases.

## Git and release state

- Product branch: protected PR `#33` merged to `main` at
  `f6b19568bac65acfc5e1803862ae7a1aa56696ba`.
- Deployment follow-up branch:
  `codex/mobile-ui-private-staging-rollout-20261005`.
- Deployment implementation commit:
  `9b835fe9c81c296a5eb297255c372eb43ef0d60f`.
- Repository visibility: public by owner decision. Credentials, secure local
  variables, supplier binaries, firmware, signing material, personal data, and
  health data remain excluded.
- Version/build impact: no customer version change in this follow-up.
- Release/distribution impact: private synthetic staging only.

## Decisions

- Durable decision added or changed: none. Existing private-staging,
  synthetic-only, least-privilege, customer-neutral naming, and physical-gate
  decisions remain authoritative.
- Decision-log entry: none.

## Open risks and honest limitations

- The project continues to incur Cloud SQL, Cloud Run, storage, scheduler,
  registry, KMS, logging, and related staging cost. Budget alerts are not a
  hard spending cap.
- App Check is enforced, but the smoke uses a temporary debug assertion.
  Signed App Attest and Play Integrity remain unverified.
- Real OTP, push delivery, public ingress, payment, ownership possession, and
  physical-band behavior remain prohibited and unverified.
- Simulator and emulator parity does not prove BLE, background, battery,
  haptic, notification, retention, accessibility, or sensor behavior on
  physical devices.

## Next round

1. Integrate this lifecycle follow-up through protected `main`.
2. Start the signed iPhone and Android physical-validation handoff from clean
   protected `main`, preserving the existing comparison transport and exact
   supplier quarantine.

## Privacy check

- [x] No credentials, phone numbers, OTP codes, tokens, identity subjects,
      account identifiers, raw health values, signing identities, personal
      names, or absolute personal paths are present.
