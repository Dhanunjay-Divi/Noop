# Round: 2026-09-23 - Codex session hygiene and SDK closeout cleanup

## Status

- State: `local cleanup complete`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `9095b6b0444416eda938259c71cf6bfe03d9edcf`
- Record commit or PR: app PR `#17` consolidated closeout candidate

## Objective

Recover local disk space without deleting the active NOOP context, open agent
sessions, source, private inputs, or uncaptured evidence, and leave a reusable
active-session-aware cleanup procedure for future recurrence.

## Scope

### In scope

- Audit `$HOME/.codex/sessions`, `archived_sessions`, and
  `recovery_backups`.
- Preserve the current date and every rollout with an open file handle.
- Remove only exact closed regular rollout/archive/recovery files after an
  inspectable dry run.
- Record a reusable local skill and checksummed cleanup manifests.

### Non-goals

- Date-only deletion.
- Unattended age-based deletion through `launchd`.
- Deleting project worktrees, build evidence, private inputs, credentials, or
  any open agent session.

## Starting evidence

- The Data volume was at 97% capacity with about 13 GiB free.
- `$HOME/.codex/sessions` was approximately 109 GiB.
- A resumed active session can live under an older date, so preserving only
  the current date was not a safe ownership test.

## Delivered

- Added the local `codex-session-hygiene` skill with a Python helper that:
  - fails closed if `lsof` discovery is unavailable;
  - ignores symlinks and unknown files;
  - preserves the configured day and every open rollout;
  - records device, inode, size, and modification time before apply;
  - rechecks open handles and file identity immediately before deletion; and
  - writes an audit/apply TSV plus SHA-256 checksum.
- The dry run selected 82 closed files totaling 86,643,702,452 bytes and
  preserved 28 files, including all six open rollouts observed at the time.
- The exact apply removed those 82 closed files and reclaimed 86.6 GB. Closed
  archive and recovery directories became empty.
- Post-cleanup verification showed approximately 102 GiB free on the Data
  volume. The remaining session directory was about 37 GiB because open and
  retained context was intentionally preserved.
- No `launchd` retention agent was installed. Age alone cannot prove a session
  is disposable, and cleanup must remain an explicit active-session-aware
  operation.

## Data, privacy, and medical truth

- No user health data, app database, credential, private reference input, or
  product source was read or deleted.
- The manifests contain only local file metadata needed to audit deletion.

## Observability

- The helper reports bounded candidate, preserved, open, deleted, and changed
  counts plus aggregate byte totals.
- It never reads or logs rollout contents.
- The apply manifest SHA-256 is
  `798aa0535a72b25e6b48527fdf4e26b8155c5d7b32d74814b448ad2133a8178e`.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Active-file-aware dry run | 82 closed candidates, 86,643,702,452 bytes; 28 preserved; six open | The deletion set excluded every open rollout discovered at audit time | That every closed session was semantically disposable without the project handoff already captured |
| Exact apply with identity recheck | 82 files removed; zero newly open or changed candidates deleted | Apply matched the reviewed audit set and failed closed on drift | Future unattended cleanup safety |
| Post-cleanup disk and directory audit | About 102 GiB free; archives/recovery empty; active session files remained | The pressure condition was relieved while active context survived | That session growth cannot recur |

## Physical device and deployment

- No app build, simulator, phone, band, cloud service, or deployment was
  changed by this cleanup.

## Git and release state

- The cleanup skill and manifests live outside the product repository.
- This record is the only product-repository change for the cleanup.
- No commit, push, merge, release, or deployment is claimed by this record.

## Decisions

- No unattended cleanup job was installed. Open-file discovery and an explicit
  audited apply remain required.
- No product decision or release contract changed.

## Open risks and honest limitations

- Codex session growth can recur while long-running agents are active.
- The safe remedy is a periodic explicit dry run and apply, not a blind
  calendar-based daemon.
- Open sessions may still consume substantial space and must remain until their
  results are durably captured and their handles close.

## Next round

1. Continue the NOOP Band SDK app-integration closeout.
2. Re-run the cleanup skill only when disk pressure recurs and after current
   evidence has been captured.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
