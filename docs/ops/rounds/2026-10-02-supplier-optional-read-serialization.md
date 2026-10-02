# Round: 2026-10-02 - Supplier optional-read serialization

## Status

- State: `completed locally; physical-device validation pending`
- Owner: project team
- Branch: `codex/supplier-read-serialization-20261002`
- Start commit: `a8a617593b4b81485fca672353ebcebe2d073f55`
- End implementation commit: commit containing this round
- Record commit or PR: local commit only; no push or merge

## Objective

Adapt only the optional supplier step/sleep read ordering represented by stale
commit `2e676e75dda24c203c12d755fe0530b92ca56f3b` to current protected-main
source. Step and sleep commands must share one serialized lane, stale results
must not persist, and every terminal source path must discard queued or
in-flight optional-read state.

## Scope

### In scope

- Apple supplier source runtime ordering for optional step and sleep reads.
- Focused `VeepooBandAdapterCoreTests` regressions.
- Current operations evidence and handoff records.

### Non-goals

- Supplier SDK trust pins, binaries, firmware, entitlements, or artifact
  configuration.
- Physical-device, battery, background, retention, accuracy, or BLE claims.
- Existing comparison-transport behavior, Today catalog/UI ancestry,
  persistence schema, formulas, account behavior, Android transport,
  deployment, push, or merge.

## Starting evidence

- Current main could start step polling and the delayed sleep read
  independently, allowing both optional supplier commands to overlap.
- Step and sleep readings were persisted without confirming that their
  corresponding command was still outstanding.
- `cancelMetricReads()` already owned disconnect and stop cleanup, but it had
  no queued-sleep state to clear.
- The stale commit provided a behavioral reference only; it was not
  cherry-picked and no unrelated historical changes were imported.

## Delivered

- Added a pending-sleep state and one guarded transition that starts sleep only
  after the current step read succeeds or fails.
- Carried a monotonic app-owned request ID through the source, adapter core,
  quarantined SDK wrapper, and every success/failure callback.
- Added 15-second step and 60-second sleep timeouts. A timeout emits only a
  fixed categorical failure, resets the transport, and cannot let a delayed
  callback satisfy a later request after reconnect.
- Blocked subsequent step polls while sleep is pending or in flight.
- Accepted step and sleep readings only while the exact request ID and stage
  are in flight, preventing unsolicited, duplicate, delayed, or
  post-disconnect values from reaching persistence sinks.
- Cleared pending, step-in-flight, and sleep-in-flight state through the
  existing disconnect, credential-failure, compatibility-failure,
  battery-failure, connection-failure, permanent-credential, reconnect, and
  stop cancellation paths.
- Added focused coverage for step success and failure ordering, sleep-lane
  ownership, unsolicited results, disconnect cleanup, stop cleanup, and
  continued suppression when no durable sink exists.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact: none; this changes command ordering only.
- No supplier artifact, firmware, credential, identifier, biometric value,
  timestamp, payload, raw SDK error, or personal data was added to source or
  diagnostics.

## Observability

- Existing fixed-category supplier lifecycle and adapter diagnostics remain
  unchanged.
- No event was added for each read or result, avoiding high-frequency or raw
  health-data logging.
- Focused tests observe only command counts and bounded persistence-sink
  counts, which distinguish ordering, rejection, cancellation, and completion
  without recording metric values outside synthetic fixtures.
- Physical transport timing and supplier SDK callback behavior remain device
  validation gates.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `xcodegen generate` | Pass | Current project graph generated from tracked configuration | App runtime behavior |
| Bounded macOS `Strand` test with `-only-testing:StrandTests/VeepooBandAdapterCoreTests` | 75 tests passed, 0 failures | Supplier adapter/source unit contracts, including serialized optional reads, request fencing, bounded timeout reset, delayed-callback rejection, and terminal cleanup | Physical BLE or supplier SDK timing |
| Bounded `NOOPiOS` generic iOS Simulator build | Pass | The complete iPhone app graph compiles with the source change | Signed installation, background execution, or physical transport |
| Repository policy gates | 117 operations records valid; private-data guard passed; health-claims clear across 1,324 files; terminology ratchet passed with 18,605 unchanged occurrences; legal inventory verified 230 runtime components and 3 container inputs; supplier wrapper/quarantine tests 33/33 | Operations, private-data, claims, terminology, legal, and supplier-artifact boundaries remain coherent | Hosted checks, external approval, or physical behavior |
| `git diff --check` | Pass | No whitespace error in the current diff | Runtime correctness |

The iOS build reported a package-cache refresh warning, then used the checked
out package state and completed successfully.

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: not run.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: signed iPhone installation, exact-model supplier
  pairing, optional read timing, live HR continuity, reconnect, battery,
  history catch-up, background, retention, haptics, accuracy, and source
  switching.
- Deployment: none.

## Git and release state

- Changed paths:
  `Strand/BLE/VeepooBandSource.swift`,
  `StrandTests/VeepooBandAdapterCoreTests.swift`,
  this round, `docs/ops/ACTIVE.md`, `docs/ops/rounds/INDEX.md`, and the
  mechanically refreshed terminology inventory.
- Commits: local commit containing this round.
- Branch and remote state: local branch only; not pushed or merged.
- Repository visibility verified: not changed by this round.
- Version/build impact: no version change.
- Release or distribution impact: none.

## Resource cleanup

- Removed the round-owned 3.3 GiB focused-test DerivedData, focused log/status,
  generated Xcode project files, and the separate 5.6 GiB iOS-build evidence
  directory after recording the bounded results.
- Restored the tracked package lock unchanged after generated-project cleanup;
  no generated or untracked build path remains in the checkout.
- No simulator, server, tunnel, database, or cloud resource was started.

## Decisions

- Preserve the current adapter, persistence, qualification, privacy, and
  diagnostics boundaries; only serialize optional command ownership.
- Treat build and simulator evidence as source integration evidence, never as
  physical supplier-band proof.
- Durable decision added or changed: none.
- Decision-log entry: none.

## Open risks and honest limitations

- Physical hardware still must confirm the supplier SDK's callback timing and
  timeout envelopes for the approved model/firmware pair.
- Physical command ordering, live-HR coexistence, reconnect behavior, battery,
  retention, background execution, and sensor accuracy remain unverified.

## Next round

1. Review and integrate this local commit through the normal protected path.
2. From clean protected main, run the signed physical-device supplier and
   comparison-transport matrix in
   `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, absolute personal paths, supplier
      artifacts, or private inputs are present.
