# NOOP backup format

This document is the normative contract for NOOP's native `.noopbak` backup container.
The format is shared across Apple and Android, while the SQLite database inside remains
platform-native.

## Scope

A current native backup contains:

1. a consistent snapshot of the source platform's complete NOOP SQLite database;
2. an optional, explicitly whitelisted `settings.json`;
3. a required integrity and compatibility `manifest.json`.

The database includes every row stored in that platform's database, including biometric
history, derived scores, sleep, workouts, journals, nutrition, and strength data.

Settings schema v4 carries only validated, explicitly allowlisted, user-authored values:

- profile: exact civil date of birth plus legacy age fallback, sex, weight, optional user-selected
  target weight, height, waist, and manual maximum-heart-rate override;
- units and interpretation: distance system, independent mass/height/temperature choices,
  Effort display scale, and whole-night versus deep-sleep HRV window;
- appearance: app appearance, data colour style, trend chart shape, day-cycle background,
  sky-behind-cards choice, and card opacity;
- dashboard and interaction: Today section order, key-metric selection/detail/window,
  workout keep-awake, hydration tracking, and supported layout choices;
- planning and reminders: wind-down enable/sleep need/lead, canonical wake target,
  notification master/worn/quiet-hours choices, inactivity reminder configuration, and
  hydration reminder configuration.

Only values explicitly stored on the source device are emitted. An absent key leaves the
destination's current value alone.

The payload does not include credentials, API/member tokens, Bluetooth peripheral or
installation identifiers, sync cursors, security-scoped file bookmarks, active sessions,
permission/authorization receipts, notification-delivery de-duplication slots, migration
flags, derived recovery minutes, alarm-enabled state, scheduled alarm epochs/windows,
per-day wake overrides, or raw preference files. Those exclusions are deliberate: secrets,
hardware bindings, and volatile machine state must not be copied into a portable backup.

## Outer encrypted envelope

Manual Apple and Android exports wrap the inner ZIP in the shared binary `NOOPBAK` v1
envelope:

- magic: `NOOPBAK\0`;
- PBKDF2-HMAC-SHA256 passphrase derivation;
- chunked AES-256-GCM authenticated encryption;
- authenticated version, length, chunk index, and chunk length;
- atomic publication after encryption succeeds.

The passphrase is never stored and cannot be recovered. A wrong passphrase or modified,
truncated, appended, or reordered ciphertext fails before a restore is staged.

Unattended Apple folder snapshots use the plaintext inner ZIP because Apple does not
persist a passphrase for that workflow. Android unattended folder snapshots use the same
encrypted envelope with a recovery secret stored in Keystore-backed encrypted preferences.

## Inner ZIP

Current writers use this exact order:

| Order | Entry | Required | Maximum uncompressed size |
|---:|---|---|---:|
| 1 | `noop-backup.sqlite` | yes | 2 GiB |
| 2 | `settings.json` | no | 1 MiB |
| 3 | `manifest.json` | yes for current writers | 1 MiB |

Keeping the historical database and settings entries first allows older readers to keep
working. Current readers inspect at most 128 file entries and reject duplicate canonical
basenames, including duplicates hidden in different ZIP paths. Unknown entries are ignored.

## Manifest v1

`manifest.json` is UTF-8 JSON. Current writers emit sorted keys where the platform encoder
supports it, but consumers must not depend on key order.

Example:

```json
{
  "appVersion": "8.0.0",
  "createdAtEpochMs": 1787395200000,
  "databaseEngine": "grdb",
  "databaseSchemaVersion": 41,
  "format": "noop-backup",
  "payloads": {
    "database": {
      "bytes": 10485760,
      "path": "noop-backup.sqlite",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "settings": {
      "bytes": 268,
      "path": "settings.json",
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  },
  "settingsSchemaVersion": 4,
  "sourcePlatform": "apple",
  "version": 1
}
```

| Field | Contract |
|---|---|
| `format` | Must equal `noop-backup`. |
| `version` | Container contract version. Current value is `1`. |
| `createdAtEpochMs` | Non-negative Unix epoch milliseconds. |
| `sourcePlatform` | `apple` or `android`. |
| `databaseEngine` | `grdb` for Apple or `room` for Android. |
| `databaseSchemaVersion` | Positive source database schema version. Current code is Apple `41`, Android `36`. |
| `settingsSchemaVersion` | Present only when a settings payload is declared. Current value is `4`. |
| `appVersion` | Optional human-readable source app version. It is informational, not a restore gate. |
| `payloads.database` | Required canonical path, uncompressed byte length, and lowercase SHA-256. |
| `payloads.settings` | Optional canonical path, uncompressed byte length, and lowercase SHA-256. |

Payload hashes are computed and verified with streaming reads; the database is not loaded
into memory.

## Restore gates

For a manifest-bearing backup, restore fails before opening SQLite when:

- the format or container version is unsupported;
- platform or database engine is unknown or does not match the current client;
- the source database schema is newer than the current client;
- a declared path is not canonical;
- a declared payload is absent, undeclared settings are present, or settings metadata and
  payload presence disagree;
- a byte length or SHA-256 digest does not match;
- a canonical ZIP entry is duplicated or exceeds its size limit;
- the archive contains more than 128 file entries.

After those gates, the importer still verifies the SQLite header, database origin,
migration compatibility, required tables, and `PRAGMA quick_check`. Restore is staged for
a cold launch and the current database is preserved as a rollback snapshot before the
replacement is committed.

Settings values are type-, enum-, length-, character-, and range-checked independently.
Unknown or malformed settings are dropped without invalidating an otherwise healthy
database restore. After the restored database is accepted, in-process appearance mirrors
and supported reminder schedules are reconciled. A restored enabled reminder is scheduled
only when the OS has already granted notification permission; restore never prompts for a
permission or silently enables the Android phone wake alarm. A restored disabled reminder
removes stale pending work owned by that feature.

## Cross-platform behavior

The container and encrypted envelope are shared. The databases are not:

- Apple backups contain a GRDB-managed schema.
- Android backups contain a Room-managed schema.

A native backup can replace only a database from the same platform family. Use NOOP's
portable data ZIP to move supported user data between Apple and Android. The ZIP is not a
replacement for a native backup: platform settings and every auxiliary/local feature record
are not included.

## Portable data ZIP

Settings → Backup & restore → **Export data** creates an unencrypted, open ZIP intended for
inspection and cross-platform transfer. It contains:

| Entry | Purpose |
|---|---|
| `physiological_cycles.csv` | WHOOP-compatible daily/recovery history |
| `sleeps.csv` | WHOOP-compatible sleep sessions |
| `workouts.csv` | WHOOP-compatible workout summaries |
| `journal_entries.csv` | WHOOP-compatible journal history |
| `noop_metric_series.json` | readable scalar-series sidecar for inspection |
| `noop_user_data.json` | versioned editable nutrition and Strength Trainer records |

`noop_user_data.json` has:

- `format`: `noop.user-data`;
- `schemaVersion`: `1`;
- `exportedAt`: Unix epoch seconds;
- `nutritionEntries`;
- `strengthExercises`;
- `strengthRoutines`;
- `strengthRoutineExercises`;
- `strengthSessions`;
- `strengthSets`.

The file preserves stable IDs, nullable nutrients, notes, archive state, ordered
routine/set relationships, kilograms, reps, duration, RPE, rest targets, and timestamps.
Secondary muscles are emitted as a real JSON string array rather than the database's
internal JSON string.

Readers enforce a 64 MiB sidecar limit, exact JSON field types, model bounds, unique IDs,
unique ordered positions, and complete exercise/routine/session references before writes.
Future schema versions fail clearly. Import merges by stable ID; a local editable row wins
when its `updatedAt` is equal to or newer than the export. Existing built-in exercise
definitions are never overwritten. Accepted nutrition/strength writes are one database
transaction. ZIPs created before schema v1, with no `noop_user_data.json`, continue to
import their CSV history unchanged.

The portable ZIP is unencrypted because it is designed to be open and readable. Treat it
as sensitive health data and store/share it only through a location you trust.

## Backward compatibility and evolution

Current readers continue to accept:

- manifest-less historical ZIP backups;
- older ZIPs without `settings.json`;
- legacy plain SQLite backups after normal origin and integrity validation;
- the platform's historical unencrypted `.noopbak` inputs.

Evolution rules:

- Additive optional manifest fields may be introduced without changing `version`; v1
  readers must ignore unknown fields.
- Existing field meaning, required entry names, or validation semantics must not change
  incompatibly under version 1.
- An incompatible container change requires a new manifest `version`.
- New payloads must be explicitly declared with path, byte length, and SHA-256 before a
  current reader may apply them.
- Settings fields are additive. Existing canonical names and meanings remain stable; a
  new settings schema version documents a widened allowlist.
- Writers should preserve database-first, settings-second ordering while legacy readers
  remain supported.

## Implementations

- Shared Swift contract: `Packages/WhoopStore/Sources/WhoopStore/BackupManifest.swift`
- Apple writer/reader: `Strand/Data/DataBackup.swift`
- Shared Kotlin contract: `android/app/src/main/java/com/noop/data/BackupManifest.kt`
- Android writer/reader: `android/app/src/main/java/com/noop/data/DataBackup.kt`
- Settings schema: `Packages/WhoopStore/Sources/WhoopStore/BackupSettings.swift` and
  `android/app/src/main/java/com/noop/data/BackupSettings.kt`
- Portable user-data schema: `Packages/WhoopStore/Sources/WhoopStore/PortableUserData.swift`
  and `android/app/src/main/java/com/noop/data/PortableUserData.kt`
