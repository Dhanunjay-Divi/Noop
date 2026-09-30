# Round: 2026-09-30 - GitHub pull-request remediation

## Status

- State: `in progress`
- Owner: project team
- Branch: multi-PR remediation staged from
  `codex/github-pr-remediation-20260930`; dependency completion is committed
  onto `dependabot/pip/server/pyjwt-2.14.0`
- Start commit: `ac6f72583513d5c8b4a65f6069d8a1503dab608b`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Resolve the four open pull requests against current protected `main` without
merging stale branch history:

- close PR `#17` as superseded after confirming current main retains its SDK,
  pairing, and viewer safeguards;
- review PR `#20` from `nobelchowdary`, exclude its development-only commit,
  repair privacy-unsafe diagnostics, and integrate only useful supplier metric
  behavior that remains absent from current main;
- reconcile PR `#14` with current calendar, consent, and routine-notification
  contracts and integrate only confirmed missing behavior;
- replace or repair PR `#21` with the PyJWT dependency lock, license inventory,
  operations record, and verification required by protected CI.

Normal protected pull requests and required checks remain mandatory. No branch
protection, release gate, supplier quarantine, or physical-device gate may be
bypassed.

## Scope

### In scope

- Exact current-main comparison for PRs `#14`, `#17`, `#20`, and `#21`.
- Minimal reviewed replacements for dependency, supplier metric, and calendar
  behavior where current main is missing valid changes.
- Privacy-safe bounded diagnostics for any supplier ingestion boundary changed.
- Focused and complete applicable local verification, hosted required checks,
  normal protected merges, and durable closeout records.
- A ready-to-paste physical-device validation handoff.

### Non-goals

- Wholesale merging any conflicting historical branch.
- Integrating the PR `#20` development-only commit
  `0b99aca0c40680c19bb1a29b798b42cb1229146d`.
- Enabling unapproved supplier binaries, firmware, Release transports, public
  health-data traffic, or automatic medical inference.
- Claiming BLE, background, battery, haptic, sensor accuracy, or physical metric
  behavior from builds, unit tests, simulators, or hosted CI.

## Starting evidence

- Reproduction or observed symptom: PR `#21` fails operations, release,
  runtime-license, and server required checks. PRs `#14`, `#17`, and `#20` are
  conflicting with current main.
- Relevant source/device/OS/firmware class: protected source at
  `ac6f72583513d5c8b4a65f6069d8a1503dab608b`; no physical device or supplier
  firmware was used.
- Existing tests, logs, exports, screenshots, or documents: current protected
  main record, PR metadata and hosted check conclusions, SDK physical-validation
  handoff, and the repository operations ledger.
- Unknowns that must remain unknown until measured: supplier-band physical
  compatibility, sensor semantics and accuracy, background collection,
  reconnect timing, haptics, battery behavior, and signed-device delivery.

## Delivered

- Repaired the PyJWT `2.14.0` update as a complete dependency change:
  synchronized the two direct manifests, refreshed the hash-locked Python
  runtime, replaced the exact reviewed PyJWT license file, and regenerated the
  root/server/backup notices plus runtime inventory.
- Kept dependency behavior unchanged beyond the reviewed version update. The
  JWT/JWK authentication path continues to use the same bounded request
  observability and does not add token, claim, request-body, or exception
  logging.
- Audited local resource pressure before verification. The repository worktree
  was only 131 MiB; 38 closed, non-current Codex rollout files were the exact
  disk owner. The active-session-aware cleanup preserved the current-day
  directory and all four open files, removed 111,777,580,912 bytes, and restored
  about 108 GiB free space. The checksummed deletion manifest remains outside
  Git.
- PR `#17`, PR `#20`, and PR `#14` remediation remains in progress.

## Data, privacy, and medical truth

- Schema or migration impact: under review.
- Existing-data retention impact: under review.
- Source/provenance or formula impact: supplier metric provenance changes, if
  retained, must remain source-qualified and unavailable when unsupported.
- Permissions/network disclosure impact: calendar permission and proactive
  notification consent remain explicit, optional, and default-off.
- Health/medical claim impact and limitations: no medical inference is
  authorized. Builds and synthetic data cannot validate physiological accuracy.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: supplier
  ingestion must use fixed lifecycle categories, bounded counts and durations,
  and the existing platform diagnostics recorders.
- Why existing evidence is sufficient, or why new evidence is required: PR
  `#20` requires a fresh audit because its raw diagnostic output may expose
  sensor values or payloads.
- Existing evidence reused: current pairing/source lifecycle events, sync
  notification reservation ledger, and hosted required-check metadata.
- New bounded events or operation spans: pending review.
- Redaction, retention, and high-frequency controls: no raw frames, values,
  timestamps, identifiers, arbitrary errors, or per-sample logging.
- Cross-platform/backend correlation: Apple and Android metric meaning and
  missing-state behavior must remain aligned.
- Remaining blind spots: all physical supplier behavior and firmware-owned
  buffering/classification.
- Dependency slice review: no new runtime boundary or log was introduced.
  Existing server request observability remains sufficient because the PyJWT
  update changes package version and legal/lock metadata only.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Context snapshot from clean current-main worktree | Passed | Work is isolated from unrelated dirty Android changes | Runtime behavior |
| GitHub PR inventory | `#14`, `#17`, `#20` conflicting; `#21` required gates failing | Exact live branch/check state | Correctness of any proposed patch |
| `python3 Tools/release-legal-gate.py check` and `distribution` | Passed; 230 runtime components and 3 container inputs | Lock, inventory, notices, project license, and distribution provenance agree | Server runtime behavior |
| `python3 -m unittest Tools.tests.test_release_legal_gate` | Passed, 9 tests | Legal gate parsing and drift checks remain covered | Authentication behavior |
| Python 3.14 dependency environment | Failed before tests because pinned `pydantic-core` supports PyO3 through Python 3.13 | The failure is a local toolchain mismatch and is retained rather than rewritten as success | Python 3.12 CI behavior |
| Python 3.12 exact dependency environment | Passed; PyJWT reports `2.14.0`, `pip check` clean, `pip-audit` found no known vulnerabilities | The reviewed dependency graph installs and resolves on the repository target | PostgreSQL/container behavior |
| `pytest -q server/tests/test_managed_app_check.py` | Passed, 4 tests | JWT/JWK authentication compatibility | Complete server behavior |
| `ruff check server` and `ruff format --check server` | Passed | Server source remains lint/format clean | Runtime behavior |
| `pytest -q server` | Passed with expected environment-dependent skips | Complete local in-memory server test wall is green under Python 3.12 | Hosted TimescaleDB/PostgreSQL service and container builds |
| `python3 Tools/validate-ops-rounds.py --all .` and `git diff --check` | Passed | Operations record/index and patch hygiene are valid | Product/runtime correctness |
| Active-session-aware Codex cleanup | 38 closed files and 111,777,580,912 bytes removed; current day and 4 open files preserved | Exact stale-session cleanup restored the resource gate without deleting live sessions | General machine cleanup |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: source review only.
- Data-preservation result: no data mutation yet.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical WHOOP and supplier-band validation cases.

## Git and release state

- Changed paths: this operations record only at round start.
- Dependency slice paths: `server/pyproject.toml`,
  `server/requirements.txt`, `server/requirements.lock`, the exact PyJWT
  license record, `ThirdPartyNotices/runtime-inventory.json`, `NOTICE`,
  `server/NOTICE`, and `server/backup/NOTICE`.
- Commits: pending.
- Branch and remote state: isolated local branch from protected `main`; no push
  or remote merge yet.
- Repository visibility verified: private at round start.
- Version/build impact: none yet.
- Release or distribution impact: none yet.

## Decisions

- Durable decision added or changed: none yet.
- Decision-log entry: none.

## Open risks and honest limitations

- Historical branches contain broad stale history and cannot be treated as
  merge-ready.
- Supplier metric behavior may depend on undocumented firmware or wrapper
  semantics and must fail closed when provenance is missing.
- Physical-device testing requires a later signed-device agent and approved
  exact supplier artifacts.

## Next round

1. Complete exact-delta audits for PRs `#14`, `#20`, and `#21`.
2. Implement and verify minimal current-main replacements.
3. Open, review, and merge protected pull requests, then close superseded PRs.
4. Publish the exact hardware-testing handoff.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
