# Managed History Portability

NOOP+ managed-history archives are optional portability artifacts. They do not
replace the local-first store, make cloud history authoritative, or change
collection, scoring, retention, or device-control behavior.

## Archive contract

- `manifest.json` is written last and is the only archive index.
- Format version 2 adds:
  - a snapshot cursor containing the server snapshot timestamp and change
    sequence;
  - a SHA-256 aggregate over every expected chunk and document record; and
  - an exact expected entry count.
- Each manifest object also carries its own path, byte length, and SHA-256.
- Readers accept existing format version 1 archives. New exports use version 2.
- The archive entry set must exactly equal the manifest entry set plus
  `manifest.json`; duplicates, extra files, missing files, traversal paths, and
  oversized entries fail closed.

The cross-platform aggregate digest is SHA-256 over records sorted by path and
then kind. Each UTF-8 record is:

```text
kind<NUL>path<NUL>entry_sha256<NUL>entry_bytes<LF>
```

## Resumable export

An export checkpoint is account-scoped and binds:

- the restore request and restore job;
- snapshot timestamp, change sequence, and expiry;
- selected object and byte totals;
- current data class and chunk/document cursors;
- every committed manifest record; and
- whether server completion succeeded.

Downloaded objects are staged as immutable private files. An identical replay
is a no-op; a divergent replay at the same path is a conflict. The checkpoint
advances only after the staged object is durable. This permits safe replay when
the process stops between object staging and checkpoint persistence.

The final ZIP is built only after every selected object is staged and the
server restore job confirms matching delivered totals. Publication copies the
verified ZIP to the caller-selected destination and then clears only that
account's export staging state. Cancellation and transient transport failures
retain the checkpoint. Expired, missing, conflicting, or corrupt snapshots are
discarded and must start a new export.

## Resumable import

The selected archive is copied into protected app-private storage before
validation. A checkpoint is bound to the canonical manifest SHA-256 and stores
the next object index plus imported object and chunk-byte totals.

Import is deliberately two-pass:

1. Decode and validate the manifest, exact entry set, aggregate integrity,
   every object digest and size, canonical chunk payload, and document identity.
2. Apply objects through the existing local managed restore adapters,
   checkpointing after each successful local transaction.

No local mutation occurs until the entire archive passes pass one. Existing
restore adapters provide idempotent chunk application and revision-aware
document behavior. Equal-revision divergent documents and dirty local
generations fail as conflicts. A completed checkpoint returns the same summary
without replaying objects.

Selecting the same manifest again preserves import progress while replacing
the staged archive bytes. Selecting a different manifest clears only the old
import checkpoint. Successful completion clears the staged import and
checkpoint.

## Privacy and observability

- Apple transfer state uses complete file protection and is excluded from
  backup.
- Android transfer state uses app-private no-backup storage and atomic
  checkpoint files.
- Diagnostics contain only bounded outcome, fixed failure category, object
  count, chunk-byte count, and whether work resumed.
- Archive paths, account scope hashes, object IDs, timestamps, cursor values,
  health values, document payloads, tokens, and exception messages are not
  recorded.

## Remaining external evidence

Code and synthetic tests cannot prove production service expiry behavior,
large-account throughput, low-storage behavior, process termination on real
devices, or cross-tenant authorization. Those remain staging and physical
device gates.
