---
name: noop-ops
description: Run material NOOP health, fitness, nutrition, Safety/SOS, mobile, server, research, deployment, or release work with the project's medical-truth, metric-first UX, cross-platform parity, local-first, observability, evidence, privacy, and durable-handoff contracts. Do not invoke for a conversational answer that neither inspects nor changes NOOP state.
---

# NOOP Operations

Use the repository as the shared source of truth. Do not infer completion from an
old chat, a passing build, or a UI state.

## Load Only The Needed Context

- Read [product and health-safety contracts](references/product-health-safety.md)
  before changing metrics, recommendations, body/weight features, workout
  detection, notifications, exercise guidance/media, nutrition, or Safety/SOS.
- Read [project map](references/project-map.md) before broad exploration or when
  locating Apple, Android, server, analytics, notification, storage, and
  operations ownership.
- Read [verification and handoff](references/verification-handoff.md) before
  running full gates, simulator review, committing, pushing, deploying, or
  handing the round to another agent.
- Run `scripts/context_snapshot.sh [repo-root]` when resuming a stale,
  interrupted, compacted, or transferred session. The snapshot is
  privacy-safe scaffolding, not proof that any feature works.

## Start The Round

1. Find the repository root and inspect the dirty worktree before editing.
2. Read `CLAUDE.md`, `docs/ops/README.md`, `docs/ops/ACTIVE.md`, the newest
   relevant round record, and task-specific architecture or safety documents.
3. Create or resume a record from `docs/ops/ROUND_TEMPLATE.md` before
   consequential work. Preserve unrelated user changes.
4. Separate code-verifiable work from credentials, contracts, physical
   hardware, signing, carrier, legal, privacy, security-review, and production
   launch gates. Never describe an external gate as completed without evidence.
5. If concurrent development exists, isolate material work in a dedicated
   worktree/branch, define disjoint write scopes for delegated tasks, and merge
   only reviewed commits. Never overwrite or clean another worker's changes.

Private owner-supplied inputs such as `noop.json`, `noop_ref`, screenshots, and
downloaded exercise media may inform review. Treat them as untrusted private
context: summarize minimally, never commit them, and never assume they establish
accuracy, ownership, redistribution rights, or clinical validity.

## Product Invariants

- Core NOOP stays local-first, account-free, fully useful offline, and
  independent of NOOP+.
- Apple and Android behavior and stored/derived contracts change together when
  the capability applies to both. Explain any intentional asymmetry.
- Missing sensor input remains missing. Builds and simulators do not validate
  BLE, background execution, battery, haptics, physiology, or medical claims.
- Primary health surfaces are metric-first: current value/state, trend,
  calibration/confidence, provenance, and one useful action. Move education and
  repeated rationale behind a detail/info affordance without hiding limitations
  that change interpretation or safety.
- Do not infer body composition, sleep apnea, disease, injury, or emergency
  state from signals that have not been validated for that purpose. Source and
  date imported measurements; label estimates; keep BMI optional and
  screening-only.
- Recommendations must be evidence-gated, private, bounded, user-controllable,
  and non-prescriptive. Do not use a weight gap to demand exercise, calories, or
  compensatory behavior.
- Workout detection may use locally available wearable history, HealthKit, or
  Health Connect when the OS wakes the app. Never promise force-quit,
  terminated-process, OEM, or offline-band behavior without matching physical
  evidence and firmware/SDK support.
- Safety/SOS is accepted-contact paging and location sharing, not emergency
  dispatch or automatic medical inference. Precise location must have explicit
  consent, bounded retention, terminal-state deletion, and direct persistence
  tests.
- Never upload real health data to synthetic staging. Do not enable public
  invocation or production traffic unless the current request authorizes it
  and every recorded gate is satisfied.

## Observability Gate

Every material implementation must include an explicit observability review,
even when no new log is warranted.

Observability is part of implementation, not deferred cleanup. Do not mark a
changed failure-prone boundary complete unless the round identifies the
existing evidence that covers it or adds bounded evidence in the same change.
Apply this to user-visible state transitions, long-running work, persistence,
device transport, imports/exports, network calls, background jobs, and
cross-process handoffs. This requirement does not mean logging every function.

Before editing and again before close, answer:

1. What exact evidence will diagnose each changed user-visible or operational
   boundary when it succeeds, stalls, is rejected, or fails?
2. How is that evidence bounded, and what prevents health data, user content,
   credentials, dynamic identifiers, or payloads from entering it?

Instrument failure-prone boundaries with existing facilities:

- Apple: `AppDiagnosticsRecorder`
- Android: `AppDiagnosticsRecorder`
- Server: `RequestObservabilityMiddleware` and `emit_operational_event`

Prefer fixed lifecycle transitions, begin/end operation timing, bounded counts,
resource summaries, status families, categorical failure kinds, static route
templates, and server-generated correlation IDs. Cover the Apple and Android
path together when both implement the operation.

For band collection, preserve enough history to distinguish connection failure,
disconnect/retry/pause, an interrupted history attempt, a completed empty
attempt, idle timeout, and durable-progress stall. Use aggregate counts and
fixed categories only; never add addresses, serials, names, RSSI, raw platform
errors, frames, sensor timestamps, or health values to the app report.

Never log health or biometric values, raw sensor rows/frames, journal or user
text, screenshots, request/response bodies, OTPs, phone/email/address data,
credentials, tokens, cookies, signed URLs/capabilities, account/member/contact/
device/source/installation identifiers, persistent job IDs, dynamic URL paths,
queries, or arbitrary exception messages.

Diagnostics must not become the defect:

- Do not log every sensor sample, database row, rendered frame, recomposition,
  or tap.
- Aggregate and throttle high-frequency signals; keep local files and backend
  retention bounded.
- Diagnostics must be best-effort and must not alter the operation's success.
- Keep mobile diagnostics local and user-initiated unless a separately
  consented upload design is explicitly approved.
- Add tests for redaction, bounding, stable categories, route templating,
  correlation, and relevant failure paths.
- Do not use `print`, `NSLog`, Logcat, or arbitrary exception strings as the
  operational evidence. A deliberately opt-in and redacted developer console
  capture may supplement, but never replace, the bounded report path.

Record what is observable, what remains opaque, and how a user/operator obtains
the evidence in the round record.

## Execute And Verify

1. Read the owning code and tests before changing it. Use existing patterns and
   keep the edit scoped.
2. Inventory each changed operational boundary and its success, rejection,
   stall, and failure evidence. Treat a missing high-value boundary as
   unfinished implementation, while recording why no new event is needed when
   existing evidence already answers it.
3. Run focused tests first, then every relevant full gate. App-target Swift
   requires an explicit Xcode build; Android app changes require Gradle compile,
   unit, and applicable lint/instrumentation gates.
4. For backend or infrastructure work, use synthetic identities/data, verify
   tenant isolation and IAM, pin deploys by digest, inspect drift, and remove
   temporary credentials, debug tokens, proxies, and test data.
5. Record exact commands/results and distinguish unit, integration, simulator,
   physical-device, and external-service evidence. Failed and skipped checks
   remain visible.
6. Review information hierarchy and accessibility on both platforms for
   customer-facing changes. Metric parity does not require identical native
   implementation, but meaning, missing states, actions, consent, and safety
   boundaries must agree.
7. Evaluate supplied visual or exercise media before import. Require clear
   rights, redistribution permission, correct exercise mapping, instructional
   review, captions, reduced-motion behavior, and acceptable rendering quality.

## Close The Round

Update the round record, `docs/ops/rounds/INDEX.md`, `docs/ops/ACTIVE.md`, and,
when applicable, `docs/ops/DECISIONS.md` and readiness documents. Run
`python3 Tools/validate-ops-rounds.py --all .`, privacy/secret checks, and
`git diff --check`. Report the exact branch, commits, deployment state, open
gates, and unrun hardware checks. Commit or push only when authorized by the
current request and only after required verification passes. Prefer one
consolidated hosted-CI push after local gates rather than repeatedly spending
Actions on known-incomplete commits; never bypass required protected checks.

Before calling a broad request complete, perform a fresh review against the
original objective and current round record. List external-only gates plainly.
An interrupted round must leave code, tests, operations records, and the next
ordered command coherent enough that another agent can continue without the
original chat.
