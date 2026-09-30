# Round: 2026-09-30 - Supplier band metrics integration

## Status

- State: `implementation and local verification complete; protected integration pending`
- Owner: project team
- Branch: `codex/supplier-metrics-integration-20260930`
- Start commit: `fd2f0f8165742c328767add904d69a74d67c0d81`
- Product baseline preserved:
  `7ca94bf8ab79375ce8bc363a2718aae2bebed710`
- Development-only commit excluded:
  `0b99aca0c40680c19bb1a29b798b42cb1229146d`
- End implementation commit:
  `719b724a6a084c07a384a34c789fcfe2406ab1d6`
- Record commit or PR: closeout commit containing this record; pull request
  intentionally pending an approved required-check runner path

## Objective

Reconcile the owner-validated supplier connection, live HR, native day-step,
and sleep behavior from pull request `#20` with current protected main. Preserve
the newer pairing lease, ownership, viewer, source-switching, privacy,
diagnostics, and release safeguards instead of wholesale-merging the historical
branch.

## Scope

- Supplier adapter, persistence, analytics, Apple presentation, Android
  analytics parity, bounded diagnostics, SDK path handling, tests, tracked
  handoff, and release evidence.
- No firmware, signing, physical-device claim, production enablement, or
  unreviewed Android transport.

## Starting evidence

- The owner reported commit `7ca94bf8...` physically connected to the supplier
  band and returned live HR, native steps, and sleep data.
- Current protected main contains newer pairing lease, ownership, viewer,
  source-switching, privacy, and release controls that must remain.
- Commit `0b99aca0...` is explicitly development-only.

## Delivered

- Preserved quoted external SDK paths and normalized only their verified outer
  quote pair before Python or framework-copy use.
- Added supplier adapter events and reviewed SDK calls for battery, native
  day-cumulative steps, and sleep reports.
- Made battery, step, and sleep reads optional: bounded failures do not tear down
  an otherwise valid live-HR transport.
- Serialized step polling, bounded retries, coalesced same-second live HR,
  flushed pending batches on timer/stop/disconnect, and cancelled all polling
  work on terminal paths.
- Persisted live HR with phone receipt time, native steps with an atomic partial
  day update, and supplier sleep with an atomic report/session update.
- Kept existing fields intact during partial updates, including a valid zero
  step total.
- Allowed a supplier sleep window to seed a missing session only after the
  existing sparse-reading gate. Existing stronger sleep evidence is preserved.
- Passed supplier-native steps to analytics only when the authoritative
  registered day owner has `sourceKind == .veepoo`.
- Presented supplier-native Steps on Apple Today only when the exact active
  registry row is `.veepoo`. Apple Health retains same-day precedence; WHOOP
  motion counters, gravity estimates, heart rate, and hand motion remain
  excluded from primary Steps.
- Added source-aware Today cache keys and read-spine invalidation so a same-ID
  source change cannot reuse stale supplier eligibility.
- Mirrored the measured day-total analytics contract on Android without
  inventing an Android supplier transport.
- Added a tracked reusable handoff at
  `.agents/skills/noop-ops/references/supplier-band-integration.md`.

## Excluded

- The development-only artifact repin, entitlement removals, Watch changes, and
  exploratory HRV database probing from commit `0b99aca0...`.
- Raw `NSLog`, `print`, SDK error payloads, health values, timestamps, device
  identifiers, and unbounded console diagnostics.
- Any release enablement, firmware flash, guessed key/package/procedure, or
  claim of physical validation.

## Data, privacy, and medical truth

- This round changes local persistence for supplier HR, native steps, and sleep
  only after explicit source qualification.
- It does not change Recovery, Effort, Rest, Fitness Age, Vitality, or medical
  formulas.
- Supplier sleep remains band-scored evidence, not a diagnosis or sleep-apnea
  claim.
- Primary Steps accepts measured Apple Health/Health Connect data or the
  registry-qualified supplier-native counter. Wrist motion and heart rate do
  not become gait evidence.
- No supplier binary, firmware, credential, signing material, private input,
  personal data, or health data is committed.

## Observability

- `band.supplier_persistence` records only the first bounded categorical outcome
  per data class.
- Adapter/source failures use fixed failure kinds and bounded lifecycle events.
- No per-sample event is emitted. HR is coalesced before persistence and
  diagnostics never include values, timestamps, identifiers, payloads, or raw
  errors.
- Optional metric failure remains distinguishable from transport failure and
  cannot alter transport success.

## Evidence

| Evidence | Result | Proves | Does not prove |
|---|---|---|---|
| Supplier iOS repository slice | 8/8 pass | SDK wiring/path controls | Physical SDK compatibility |
| Supplier Apple adapter/source wall | 106/106 pass | pairing safeguards, persistence, batching, cancellation | BLE behavior |
| Apple source/provenance follow-up | 101/101 pass | Today routing, trends, cache/source transitions, read spine | Physical step accuracy |
| StrandAnalytics focused | 5/5 pass | measured zero, scaling bypass, sleep sparse gate | Population calibration |
| StrandAnalytics complete | 1,519 pass, 7 documented skips | analytics regression wall | Sensor validity |
| WhoopStore focused | 2/2 pass | atomic partial persistence | Flash retention |
| WhoopStore complete | 558/558 pass | storage regression wall | Device history delivery |
| Android focused Full Debug | 22/22 pass | measured-total analytics parity | Supplier BLE transport |
| Supplier repository controls | 65/65 pass | artifact/wrapper/localization controls | Signed installation |
| Default-off macOS build | pass | Apple graph compiles without supplier artifact | Physical pairing |
| Default-off iOS Simulator graph | pass | iPhone app embeds Watch/widgets/complications | Background or BLE |
| Diff hygiene and raw-log search | pass | no whitespace defect or raw supplier logging found | Runtime operations |

The first Android attempt failed only because this isolated worktree had no
`android/local.properties`; the exact rerun with explicit
`ANDROID_HOME`/`ANDROID_SDK_ROOT` passed.

## GitHub and runner state

- The owner requested no GitHub-hosted runner spend for this merge.
- Three repository self-hosted runners exist, but all were offline during this
  round.
- Every protected required context is bound to the GitHub Actions application,
  while current workflows target hosted labels such as `ubuntu-24.04`,
  `ubuntu-latest`, `macos-15`, and `macos-26`.
- This round will not weaken branch protection, forge check identities, or
  misstate local evidence as a hosted check. The reviewed branch may be pushed
  without opening a pull request; protected merge remains blocked until an
  approved runner path can emit the required contexts or the owner authorizes
  hosted execution.

## Physical device and deployment

- Signed iPhone/Android installation: not run.
- Supplier and WHOOP physical pairing, live HR, native step comparison, sleep,
  battery, reconnect, history catch-up, background, notifications, haptics,
  source switching, retention, and accessibility: not run.
- Follow
  `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md` from clean protected
  main. Do not enable the supplier source or flash firmware from a guessed
  package.
- No production or public deployment occurred.

## Git and release state

- Local implementation and verification are complete on
  `codex/supplier-metrics-integration-20260930` at implementation commit
  `719b724a6a084c07a384a34c789fcfe2406ab1d6`.
- The reviewed branch is prepared for one no-pull-request push. No pull request
  is opened because the current required workflows would spend GitHub-hosted
  runners.
- Protected main is unchanged.

## Decisions

- Preserve the owner-validated product behavior while excluding only the
  explicit development-only changes and unbounded diagnostics.
- Require registry-qualified `.veepoo` provenance before supplier-native steps
  become a primary metric.
- Do not weaken protected checks or fake hosted evidence.

## Open risks and honest limitations

- Simulator/build evidence cannot prove supplier or WHOOP physical behavior.
- No approved online self-hosted runner currently emits the required protected
  contexts.
- Supplier artifact rights, firmware compatibility, signed installation,
  background collection, battery, retention, haptics, and accuracy remain
  external gates.

## Next round

1. Complete final post-change Apple builds and repository policy controls.
2. Commit and push the reviewed branch without triggering hosted workflows.
3. Obtain an approved required-check runner path, open/review the replacement
   pull request, merge through protected main, and verify exact main.
4. Run the signed physical-device matrix on clean iPhone and Android hardware.

## Privacy check

- [x] No credentials, raw biometric values, device identifiers, local paths,
      supplier artifacts, or private inputs are present in tracked changes.
