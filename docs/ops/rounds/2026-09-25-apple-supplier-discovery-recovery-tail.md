# Round: 2026-09-25 - Apple supplier discovery recovery tail

## Status

- State: `implementation committed locally; evidence push and protected integration pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `fe616b5dc7a7ea51f345e5c940af38cab3612477`
- End implementation commit:
  `12e7819c968eea5006e18f4d000874dac6b4673b`
- Record commit or PR: application pull request `#17`

## Objective

Close the unresolved Apple review finding where supplier discovery stopped
permanently after the initial reconnect delays were exhausted. A durable active
supplier row must retain a bounded recovery path while its source policy keeps
WHOOP paused.

## Scope

### In scope

- Apple supplier discovery retry scheduling.
- Cancellation and successful-sample reset behavior.
- Focused macOS source tests.

### Non-goals

- Android presentation or transport changes.
- Changing source ownership, credentials, compatibility, or persistence.
- Claiming physical iPhone or supplier-band behavior.
- Commit, push, signing, installation, or deployment.

## Starting evidence

- Reproduction or observed symptom: the final discovery timeout called
  `scheduleReconnect()`, whose attempt-count guard returned after the configured
  burst. The durable supplier row remained active and WHOOP remained paused.
- Relevant source/device/OS/firmware class: shared Apple supplier source tested
  through the macOS app test target; no physical radio or band was used.
- Existing tests, logs, exports, screenshots, or documents: the existing
  supplier source tests covered the short reconnect burst and live-stream
  restart tail, but not post-burst discovery recovery.
- Unknowns that must remain unknown until measured: real radio wake timing,
  iOS suspension behavior, supplier callback timing, battery effect, and
  physical reconnect success.

## Delivered

- Preserved the configured short discovery delays.
- After the burst is exhausted, schedules one cancellable discovery attempt
  every 60 seconds instead of terminating recovery.
- Reuses the existing bounded discovery timeout and single-task guard, so only
  one delayed scan or timeout can be active.
- Existing stop, accepted-candidate, and successful-live paths cancel or reset
  the recovery state.
- Added focused tests proving that discovery continues beyond the burst and
  that stopping the source prevents a pending tail from starting another scan.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none; source tests do not
  validate sensor measurements or physiology.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: the existing
  supplier adapter diagnostics record fixed discovery begin/failure outcomes,
  and supplier lifecycle diagnostics cover credential and ownership failures.
- Why existing evidence is sufficient, or why new evidence is required: the
  correction reuses the existing discovery operation and does not create a new
  payload, persistence, or health-data boundary.
- Existing evidence reused: bounded `band.supplier_lifecycle` and adapter
  discovery categories.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: unchanged; diagnostics
  contain fixed categories and omit identifiers, health values, and raw errors.
- Cross-platform/backend correlation: Apple-only review correction; Android
  already retains its own cancellable recovery tail.
- Remaining blind spots: physical iOS background scheduling and supplier radio
  behavior.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused bounded macOS test command | Exit 0; 2 tests, 0 failures | Recovery continues after the initial burst and source stop cancels a pending tail | Physical BLE reconnects or iOS suspension |
| `git diff --check` | Pass | Changed text has no whitespace errors | Runtime behavior beyond executed tests |

### Verification command

```text
python3 Tools/run-bounded-command.py \
  --timeout-seconds 1800 \
  --grace-seconds 30 \
  --heartbeat-seconds 30 \
  --min-free-disk-gib 12 \
  --disk-path . \
  --label apple-supplier-reconnect-tail-parent-review \
  --log-file /tmp/noop-apple-supplier-reconnect-tail-parent-review.log \
  --status-file /tmp/noop-apple-supplier-reconnect-tail-parent-review.status \
  -- xcodebuild -project Strand.xcodeproj -scheme Strand \
    -destination 'platform=macOS' \
    -derivedDataPath /tmp/noop-pr17-final-review-regressions-dd \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:StrandTests/VeepooBandAdapterCoreTests/testInitialActivationDiscoveryContinuesWithLowFrequencyReconnectTail \
    -only-testing:StrandTests/VeepooBandAdapterCoreTests/testStoppingSourceCancelsPendingLowFrequencyReconnectTail \
    test
```

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: local macOS app test target only.
- Data-preservation result: no schema or stored-data change.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: signed iPhone reconnect, foreground/background
  transitions, radio-off recovery, source switching, and supplier-band timing.

## Git and release state

- Changed paths:
  - `Strand/BLE/VeepooBandSource.swift`
  - `StrandTests/VeepooBandAdapterCoreTests.swift`
  - this operations record
  - `docs/ops/rounds/INDEX.md`
  - `docs/ops/ACTIVE.md`
- Commits: implementation
  `12e7819c968eea5006e18f4d000874dac6b4673b`.
- Branch and remote state: the implementation commit is local; evidence/docs
  remain pending in the working tree and no replacement push has occurred.
- Repository visibility verified: unchanged and not rechecked.
- Version/build impact: none.
- Release or distribution impact: none until normal protected integration.

## Decisions

- Durable decision added or changed: none; this enforces the existing
  active-source recovery contract.
- Decision-log entry: none.

## Open risks and honest limitations

- A 60-second tail is a bounded reliability policy, not physical proof that iOS
  will execute on that cadence while suspended.
- Physical iPhone and supplier-band testing remains required.

## Next round

1. Integrate the correction through PR `#17` after exact-head hosted checks.
2. Validate reconnect timing on a signed iPhone with a real supplier band.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
