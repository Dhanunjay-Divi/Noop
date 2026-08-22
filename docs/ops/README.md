# NOOP Operations Record

This directory is NOOP's durable engineering memory. It records what a work
round was asked to accomplish, what actually changed, what evidence passed,
what happened to user data, and what remains unresolved.

Git history and release notes existed before this record. They preserve code
and user-facing milestones, but they do not consistently preserve requests,
assumptions, failed attempts, physical-device evidence, or handoff state. Work
before 2026-08-21 is therefore summarized in
[`HISTORY.md`](HISTORY.md) as a **reconstruction**, not presented as a
contemporaneous log.

## Source-of-truth order

1. Checked-in code, migrations, tests, and generated-at-build configuration.
2. Current architecture, protocol, data-model, privacy, and platform documents.
3. Contemporaneous round records in [`rounds/`](rounds/).
4. Reconstructed history in [`HISTORY.md`](HISTORY.md).
5. User-facing changelogs and release notes.

A round record cannot override the implementation. If a record and the code
disagree, fix the product or the record and document the discrepancy.

## Required workflow

For every material code, research, device, install, release, or repository
round:

1. Read [`ACTIVE.md`](ACTIVE.md), the newest round record, and the relevant
   task-specific documentation.
2. Copy [`ROUND_TEMPLATE.md`](ROUND_TEMPLATE.md) to
   `rounds/YYYY-MM-DD-<short-slug>.md` and fill the starting state before making
   consequential changes.
3. Update the record while working. Record failed or inconclusive checks; do not
   rewrite them as successes.
4. Before stopping, record exact verification, data and migration effects,
   physical-device evidence, Git/remote state, open limitations, and the next
   ordered action.
5. Update [`rounds/INDEX.md`](rounds/INDEX.md), [`ACTIVE.md`](ACTIVE.md), and
   [`DECISIONS.md`](DECISIONS.md) when a durable product or engineering decision
   changed.
6. If work is interrupted, mark the round `incomplete` or `blocked` and leave a
   reproducible handoff. An unfinished record is better than an invented result.

Run `python3 Tools/validate-ops-rounds.py --all .` before handing off. Pull
requests to `main` run the same validator and require at least one material
round record to change relative to the base commit.

Pure conversational answers that neither inspect nor change NOOP state may be
added to the current round when relevant; they do not require a new file. Any
session that changes code, research conclusions, device state, a build, a
release artifact, or a remote repository does.

## Evidence rules

- A simulator render is UI evidence, not BLE, background, battery, haptic, or
  sensor validation.
- A build proves compilation, not clinical validity, metric parity, or real
  device behavior.
- A physical-device claim names the generalized device/OS/firmware class and
  the scenario, while excluding serial numbers and personal identifiers.
- Missing input stays missing. An estimate is labeled as an estimate. A NOOP
  score is not relabeled as a vendor score.
- Background delivery is best effort on iOS and Android unless the platform
  provides stronger evidence for the exact path being discussed.
- Health and medical language must match the evidence and the project
  disclaimer.

## Privacy rules

Do not commit credentials, API keys, passwords, email addresses, raw biometric
exports, user names, precise device identifiers/UDIDs, provisioning identities,
or absolute personal paths. Summarize private exports with aggregate counts and
sanitized source labels. Keep supporting raw evidence outside Git.

## Indexes

- [Active handoff](ACTIVE.md)
- [Newest-first round index](rounds/INDEX.md)
- [Reconstructed pre-ledger history](HISTORY.md)
- [Durable decisions](DECISIONS.md)
- [Round template](ROUND_TEMPLATE.md)

The optional local Codex skill `$noop-ops` automates this preflight and
documentation discipline. Repository files remain the shared source of truth.
