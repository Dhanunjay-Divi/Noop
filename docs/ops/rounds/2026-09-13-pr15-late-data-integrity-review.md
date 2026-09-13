# Round: 2026-09-13 - PR 15 late data-integrity review

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/product-safety-quality-audit-20260911`
- Start commit: `6766b30c28162f82b649f50deeb385692ab4407b`
- End implementation commit: pending
- Record commit or PR: pull request `#15`

## Objective

Close the three data-integrity findings added after replacement head
`6766b30c` passed its complete hosted matrix, then re-run the affected local
and repository walls and integrate the exact verified revision through normal
protected `main`.

Success requires:

- managed hydration document application to reject or roll back a merged day
  above the shared 10,000 ml current-day limit on Apple and Android;
- a newly reserved feedback report to retain an authorization identity for its
  full 28-day lifecycle without breaking operations for reports already bound
  to another identity;
- capability-upgrade and cursor-recovery snapshots to preserve remote deletion
  tombstones on Apple and Android before advancing the local change cursor;
- focused tests, complete affected-platform verification, exact-SHA hosted
  checks, review resolution, protected integration, repository privacy
  restoration, and round-owned cleanup.

## Scope

### In scope

- Apple and Android managed hydration document aggregation and rollback tests.
- Apple and Android feedback anonymous-identity lifetime policy and tests.
- Apple and Android managed snapshot transport/coordinator tombstone handling
  and tests.
- Operations records, release controls, exact-SHA hosted evidence, merge,
  privacy restoration, canonical sync, and round-owned cleanup.

### Non-goals

- Enabling feedback ingestion, public traffic, real health-data transfer, or
  production deployment.
- Changing hydration goals, recommendation formulas, notification behavior,
  UI presentation, or health claims.
- Claiming physical-device, BLE, background, notification, haptic, battery, or
  sensor behavior from simulator or unit-test evidence.

## Starting evidence

- Reproduction or observed symptom: pull-request review threads
  `PRRT_kwDOTiE28c6h6dCa`, `PRRT_kwDOTiE28c6h6dCb`, and
  `PRRT_kwDOTiE28c6h6dCd` identify an unchecked post-merge hydration total,
  anonymous identities whose remaining lifetime may be shorter than a report,
  and snapshot requests that exclude tombstones before cursor advancement.
- Relevant source/device/OS/firmware class: shared Apple storage and managed
  sync packages, iOS feedback authorization, Android managed sync and feedback
  authorization, and default-off GCP identity configuration.
- Existing tests, logs, exports, screenshots, or documents: exact head
  `6766b30c` passed all 35 executed hosted checks with three intentional skips;
  all sixteen preceding review threads were resolved before these three later
  findings appeared.
- Unknowns that must remain unknown until measured: production Identity
  Platform cleanup timing, physical-phone background upload, real network
  interruption behavior, and participant-data merge frequency.

## Delivered

Pending.

## Data, privacy, and medical truth

- Schema or migration impact: pending review; no migration is currently
  expected.
- Existing-data retention impact: fixes must preserve valid hydration entries,
  report lifecycle access, and remote deletion semantics without fabricating
  records or silently normalizing health data.
- Source/provenance or formula impact: no health formula change.
- Permissions/network disclosure impact: feedback remains explicit,
  user-initiated, redacted, bounded, and default-off for public ingestion.
- Health/medical claim impact and limitations: none; hydration remains a
  user-entered record and does not imply dehydration or treatment.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing typed
  managed-document transaction failures, bounded feedback queue stages, and
  snapshot checkpoint/cursor state.
- Why existing evidence is sufficient, or why new evidence is required:
  pending implementation review.
- Existing evidence reused: `AppDiagnosticsRecorder`, durable feedback outbox
  state, managed snapshot checkpoints, and typed sync/storage errors.
- New bounded events or operation spans: pending review.
- Redaction, retention, and high-frequency controls: no health values, user
  text, credentials, tokens, URLs, object payloads, or persistent identifiers
  may enter diagnostics.
- Cross-platform/backend correlation: existing report reservation correlation
  and managed change sequence.
- Remaining blind spots: provider-side anonymous cleanup timing and
  physical-device network/background behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Exact-SHA hosted matrix for `6766b30c` | 35 successful, three intentional skips, zero failures | The pre-follow-up source passed every protected hosted job | The three later review findings |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: local macOS, iOS Simulator, Android build
  toolchain, and synthetic backend tests
- Data-preservation result: no participant, owner, production, or real health
  data touched
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: physical iPhone and Android upload/background behavior,
  BLE, band history, haptics, battery, VoiceOver, TalkBack, and sensor accuracy

## Git and release state

- Changed paths: operations record only at round start
- Commits: pending
- Branch and remote state: local and remote PR head are `6766b30c`; repository
  is temporarily public for protected hosted checks
- Repository visibility verified: public at round start; must return to private
  immediately after protected integration
- Version/build impact: no product version or build-number change
- Release or distribution impact: no artifact released or distributed

## Decisions

- Durable decision added or changed: none yet
- Decision-log entry: none

## Open risks and honest limitations

- The three review findings remain open until implementation and direct tests
  prove their contracts.
- A second replacement push is necessary because these findings were created
  only after the first exact-SHA matrix had completed.
- All physical-device and external launch gates remain unchanged.

## Next round

1. Trace and implement the three parity fixes, run focused tests, and perform a
   fresh independent review before the complete wall.
2. Push the bounded replacement head, wait for exact-SHA hosted checks, resolve
   only proven threads, and integrate through branch protection.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
