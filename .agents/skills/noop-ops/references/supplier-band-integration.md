# Supplier Band Integration

Use this reference for the optional supplier transport and its source-qualified
metrics. Current branch, verification, artifact hashes, and next commands remain
in `docs/ops/ACTIVE.md`, the newest supplier operations round, and
`docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`. For separate-phone
WHOOP and NOOP Band testing, also use
`docs/handoff/NOOP-DUAL-BAND-TWO-PHONE-TEST-HANDOFF-2026-10-05.md`.

## Stable Boundaries

- Preserve the existing WHOOP comparison transport. Do not remove, relabel, or
  route around it while qualifying supplier hardware.
- Keep one collector and band per lane, then cross the bands between iPhone and
  Android before claiming cross-platform transport support.
- The owner-validated product baseline is commit
  `7ca94bf8ab79375ce8bc363a2718aae2bebed710`. Treat its connection, live-HR,
  native day-step, and sleep behavior as relevant physical evidence to preserve,
  not as an unsafe branch. Reconcile it against current `main`; do not blindly
  replace newer pairing, ownership, privacy, viewer, or reliability safeguards.
- Commit `0b99aca0c40680c19bb1a29b798b42cb1229146d` is explicitly
  development-only. Do not merge its artifact repin, entitlement changes,
  Watch-target changes, or exploratory diagnostics.
- Keep supplier binaries, firmware, credentials, signing material, private
  reference inputs, and health data out of Git. The supplier-neutral wrapper and
  simulator compile do not prove a hardware transport.
- Enable the transport only for the exact approved hardware, firmware, SDK
  artifact, compatibility manifest, and local physical-device build. Never
  improvise a firmware flash, key, package, or pairing procedure.

## Metric Provenance

- Supplier live HR uses phone receipt time unless the reviewed wrapper provides
  a validated observation timestamp. Persist in bounded batches; never log
  samples or values.
- Supplier-native day-cumulative steps may populate primary Steps only when the
  authoritative paired-device registry says the exact active source is
  `.veepoo`. Apple Health or Health Connect measured steps keep their existing
  precedence. A source-id prefix alone is not sufficient authorization.
- Reverse-engineered WHOOP motion counters, gravity calibration, heart rate, and
  hand movement are not gait proof. Keep them out of primary Steps.
- Supplier sleep may seed a missing session only when the reviewed SDK supplies
  a bounded sleep report and the existing sparse-reading gate passes. Do not
  overwrite stronger local or imported sleep evidence.
- Android must remain honest when no reviewed supplier transport exists. Shared
  analytics contracts may be mirrored, but do not invent BLE or SDK behavior.

## Observability And Validation

- Use `AppDiagnosticsRecorder` with fixed operation names, categorical outcomes,
  bounded counts, and source-kind categories. Never emit raw health values,
  timestamps, names, identifiers, payloads, SDK errors, or console dumps.
- Optional battery, steps, or sleep reads must not tear down an otherwise valid
  HR transport. Serialize polling, cancel work on disconnect, and bound retries.
- Builds, unit tests, and simulators cannot prove pairing, reconnect, battery,
  history catch-up, background behavior, haptics, sensor accuracy, or retention.
  Leave those gates to the signed physical-device handoff.
- Honor the owner preference to avoid GitHub-hosted runner spend. Do not weaken
  protected-branch rules, forge required checks, or misstate local evidence as a
  hosted check. If no approved self-hosted runner can emit the required
  app-bound contexts, push the reviewed branch without triggering hosted CI and
  record protected integration as an external gate.
