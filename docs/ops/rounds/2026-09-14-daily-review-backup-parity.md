# Round: 2026-09-14 - Daily review backup parity

## Status

- State: `implementation and exact-current local verification complete; final
  commit, hosted exact-SHA verification, protected integration, repository
  privacy restoration, and round-owned cleanup pending`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `b495558628b925821c4a4b50360c8f4a7a44fffe`
- End implementation commit: commit containing this record
- Record commit or PR: pull request `#15`

## Objective

Preserve the user's independent morning-review and journal-reminder choices in
portable `.noopbak` settings on Apple and Android. Keep restore additive,
cross-platform, and compatible with the legacy aggregate preference without
allowing the first post-restore read to overwrite the restored choices.

## Scope

### In scope

- Portable settings schema v6 on Apple and Android.
- Two platform-neutral daily-review opt-in keys.
- Legacy aggregate and split-migration compatibility after restore.
- Durable Android preference-file restore and cross-platform codec tests.
- Exact-current product, policy, hosted, integration, privacy, and cleanup
  evidence.

### Non-goals

- Backing up notification authorization or OS delivery state.
- Backing up scheduled request IDs, WorkManager state, completed journal days,
  delivery dedupe, or other device-local lifecycle state.
- Enabling a reminder the user did not opt into.
- Claiming physical notification delivery from codec or simulator tests.

## Starting evidence

- Pull request `#15` review thread
  `PRRT_kwDOTiE28c6iEzmX` identified that the two split opt-ins were absent from
  both portable settings codecs and their platform preference mappings.
- Apple and Android both retain a legacy aggregate preference plus a one-time
  split-migration marker. Restoring only the split booleans without updating
  those compatibility fields would let the first feature read overwrite the
  restored values.

## Delivered

- Schema v6 adds `dailyReview.morningEnabled` and
  `dailyReview.journalEnabled` as bounded booleans on both platforms.
- Apple maps the canonical keys directly to UserDefaults and marks the split
  migration complete after applying either key.
- Android maps the canonical keys into the dedicated `noop_daily_review`
  preference file and commits them durably with the aggregate and migration
  compatibility values.
- Android immediately reconciles both daily-review WorkManager identities after
  portable or managed preference restore. A scheduling failure leaves restore
  finalization retryable instead of silently waiting for a process restart.
- Legacy aggregate-only installations export both portable choices so an
  older explicit opt-in is not lost.
- Scheduled requests, permission receipts, completion state, and delivery
  bookkeeping remain excluded.

## Data, privacy, and medical truth

- Schema impact: additive portable settings schema v6; no health database
  migration.
- Existing-data retention impact: preserves two user-authored booleans.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none. Notification authorization is
  deliberately not exported.
- Health/medical claim impact and limitations: none.

## Observability

- No new runtime telemetry is required for a deterministic settings-codec
  contract.
- Existing restore diagnostics now include the fixed `daily_review` component
  and `failed` outcome without preference values, work IDs, or health data.
- Physical OS scheduling and notification delivery remain outside codec
  evidence.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Apple `BackupSettingsTests` | 21 passed, zero failed/skipped | Portable schema, legacy fallback, and split restore compatibility | OS notification delivery |
| Android `BackupSettingsCodecTest`, `PendingDatabaseRestoreTest`, and `DailyReviewReminderPolicyTest` | Full and Demo each passed 87 focused cases, zero failed/skipped | Codec parity, durable dedicated-preference restore, immediate reminder reconciliation, retryable finalization, and reminder policy compatibility | OEM background behavior |
| Complete Apple and Android product walls | macOS passed 2,006 of 2,007 with one external-fixture skip; iPhone Simulator passed 38 of 39 with one intentional private-pilot skip; Android Full and Demo each passed 4,764 of 4,771 with seven intentional skips, and both APK, lint, and instrumentation-source walls passed across 137 tasks | No product regression on the exact source across supported local targets | Physical hardware, background delivery, signing, or store behavior |
| Complete repository policy wall | 230 tool tests, 49 i18n tests, localization, privacy, health-claims, calibration, terminology, legal/distribution, release-control, required-CI, operations, secret, and diff gates passed | Source, policy, localization, privacy, and release contracts remain internally consistent | Hosted exact-SHA checks or external approvals |
| Hosted exact-SHA matrix | Pending | Branch-protected verification of the committed fix | Physical hardware or production operation |

## Physical device and deployment

- Install/update action: not run
- Data-preservation result: no participant or production data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical notification permission, delivery, process
  suspension, reboot/timezone repair, and accessibility

## Git and release state

- Changed paths: portable settings codecs, Android reminder preference
  contract, regression tests, and operations records.
- Branch and remote state: pull request `#15`; replacement exact-SHA push
  pending.
- Repository visibility: public during protected checks; restore to private
  immediately after protected integration.
- Version/build impact: portable settings schema v6; no marketing-version or
  build-number change.
- Release or distribution impact: no deployment or distribution.

## Decisions

- Split reminder intent is durable user-authored configuration.
- OS permission, scheduled work, delivery cursors, and completion state remain
  device-local and are never portable settings.
- Applying either split key must atomically establish compatibility fields so
  legacy migration cannot overwrite the restored choice.

## Open risks and honest limitations

- Hosted exact-SHA verification, protected integration, repository privacy
  restoration, and round-owned cleanup remain pending.
- Physical notification behavior and external launch gates remain unproven.

## Next round

1. Create one reviewed commit and one consolidated push.
2. Wait for the hosted exact-SHA matrix and resolve only the review threads
   proven by that SHA.
3. Integrate through protection, restore privacy, synchronize canonical
   `main`, and clean only round-owned resources.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
