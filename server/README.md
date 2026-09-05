# Noop self-hosted

An optional, self-hosted destination for data already stored by the Noop app.
It is off by default, has no vendor account or telemetry, and sends data only to
the URL and Bearer token that the user configures. An optional invitation-only
Friends API can create local profiles on this server; it has no public directory
and limits those credentials to computed daily-summary upload and social reads.

This service is not affiliated with or endorsed by WHOOP. It does not log in to,
scrape, or bypass WHOOP services. Imported WHOOP subscription exports remain a
separate `official_reference` namespace; transparent Noop estimates remain
`noop_computed`. Noop does not claim to reproduce proprietary scores.

> **Not a medical device.** Data and scores are informational. A row labelled
> `raw_sensor` or `unclassified_sensor`—especially `unit: raw_adc`—is an
> uncalibrated sensor count, not an SpO₂ percentage, temperature, respiration
> rate, diagnosis, or treatment recommendation.

## Quick start

Requirements: Docker Engine with Compose v2.

```sh
cd server
cp .env.example .env
openssl rand -hex 32
openssl rand -hex 32
# Put those two different values into NOOP_API_TOKEN and NOOP_DB_PASSWORD.
install -d -m 0700 secrets
openssl rand -base64 48 > secrets/backup-passphrase.txt
chmod 0600 secrets/backup-passphrase.txt
docker compose up --build -d
curl http://127.0.0.1:8080/healthz
curl http://127.0.0.1:8080/readyz
```

Compose runs schema migration once, then starts separate API and Safety worker
processes. This prevents each API replica from starting another paging loop.

The dashboard is at `http://127.0.0.1:8080/`. Paste `NOOP_API_TOKEN` to
connect. It is kept in browser session storage, disappears when that browser tab
session ends, and is never put in a URL.

The default Compose port is deliberately bound to `127.0.0.1`, so another
machine cannot reach it. To sync from an iPhone on the same trusted network,
publish `8080:8080` (or bind to the server's specific LAN address), allow only
that LAN in the host firewall, and use `http://<private-LAN-IP>:8080` in Noop.
The Apple client permits cleartext HTTP only for loopback/private-LAN hosts.

For any public hostname, use HTTPS through a reverse proxy and keep port 8080
private. See [TLS_AND_BACKUPS.md](TLS_AND_BACKUPS.md).

## Configuration

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `NOOP_API_TOKEN` | yes | none | At least 32 random bytes; authenticates full-data and social-admin routes |
| `NOOP_AUTH_MODE` | no | `single_owner` | `single_owner` permits the administrator credential to access biometric routes; `shared` requires an enrolled `noop_install_...` credential and keeps the operator credential administrative |
| `NOOP_DATABASE_URL` | in non-Compose deployments | none | PostgreSQL/TimescaleDB URL |
| `NOOP_DATABASE_ENGINE` | no | `timescaledb` | `timescaledb` uses the canonical initial migration; `postgresql` uses the separately checksummed standard-PostgreSQL initial migration for services such as Cloud SQL |
| `NOOP_DB_NAME` | Compose only | `noop` | Database selected by the DB, API, and backup services; useful for a staged restore cutover |
| `NOOP_MAX_REQUEST_BYTES` | no | `10485760` | Hard maximum sync body size |
| `NOOP_EXPORT_MAX_ROWS` | no | `100000` | Aggregate export row ceiling; oversized exports fail with `413` and require a narrower `start`/`end` window |
| `NOOP_DB_POOL_MIN_SIZE` | no | `1` | Minimum async database connections |
| `NOOP_DB_POOL_MAX_SIZE` | no | `8` | Maximum async database connections |
| `NOOP_DB_STATEMENT_CACHE_SIZE` | no | `100` | Asyncpg statement cache; set to `0` behind PgBouncer transaction pooling |
| `NOOP_RUN_MIGRATIONS` | no | `true` | Apply schema migrations at process startup; production runtime processes set false after a one-shot migration job |
| `NOOP_RETENTION_DAYS` | no | `0` | `0` disables purging; positive values enable scheduled and explicit retention runs |
| `NOOP_RETENTION_INTERVAL_HOURS` | no | `24` | Hours between automatic retention cycles when retention is enabled |
| `NOOP_IDEMPOTENCY_REPLAY_GUARD_DAYS` | no | `30` | Days to retain non-biometric batch UUID/digest tombstones after data deletion |
| `NOOP_RATE_LIMIT_REQUESTS_PER_MINUTE` | no | `120` | Per-process, per-Bearer-credential API request ceiling |
| `NOOP_RATE_LIMIT_ORIGIN_REQUESTS_PER_MINUTE` | no | `300` | Per-process API request ceiling for each trusted direct peer/client address |
| `NOOP_RATE_LIMIT_MAX_KEYS` | no | `10000` | Maximum in-memory limiter identities before new identities share a fail-closed overflow bucket |
| `NOOP_FORWARDED_ALLOW_IPS` | no | `127.0.0.1` | Comma-separated exact proxy IPs/CIDRs trusted to supply client addresses; wildcard and all-address networks are rejected |
| `NOOP_DASHBOARD_ENABLED` | no | `true` | Serve the static dashboard |
| `NOOP_PUBLIC_BASE_URL` | for paging | none | Exact public HTTPS origin used in responder links and Twilio signature validation |
| `NOOP_TWILIO_ACCOUNT_SID` | for paging | none | Twilio account SID |
| `NOOP_TWILIO_AUTH_TOKEN` | for paging | none | Twilio account Auth Token used to validate provider webhook signatures; also the outbound fallback when no API key is configured |
| `NOOP_TWILIO_API_KEY_SID` | no | none | Optional restricted `SK...` credential for outbound REST calls; requires `NOOP_TWILIO_API_KEY_SECRET` |
| `NOOP_TWILIO_API_KEY_SECRET` | no | none | Secret for the optional restricted outbound API key |
| `NOOP_TWILIO_FROM_PHONE` | for paging | none | SMS-and-voice-capable E.164 sender |
| `NOOP_TWILIO_STATUS_CALLBACK_SECRET` | for paging | none | Independent random callback capability, at least 32 bytes |
| `NOOP_SAFETY_CAPABILITY_SECRET` | for paging | none | Independent random responder-link signing secret, at least 32 bytes |
| `NOOP_SAFETY_ACKNOWLEDGEMENT_TIMEOUT_SECONDS` | no | `90` | Delay before an unacknowledged SMS page becomes eligible for voice fallback |
| `NOOP_SAFETY_INCIDENT_TTL_SECONDS` | no | `43200` | Deployment ceiling for the user-selected 8- or 12-hour incident and latest-location window; must be at least 12 hours |
| `NOOP_SAFETY_ESCALATION_ROUNDS` | no | `4` | Independent SMS-and-voice rounds queued per accepted contact; range 1 through 8 |
| `NOOP_SAFETY_ESCALATION_INTERVAL_SECONDS` | no | `900` | Delay between paging rounds; must exceed voice fallback and keep all rounds inside eight hours |
| `NOOP_SAFETY_AUTOMATIC_PAGING_ENABLED` | no | `false` | Reserved fail-closed gate for a future live-motion fall contract; authenticated detector attestation is not implemented, so this release still refuses automatic fall transport |
| `NOOP_SAFETY_APPROVED_FALL_DETECTORS` | no | empty | Reserved comma-separated `detector_id:version` metadata; an allowlist is neither authentication nor validation evidence and cannot enable transport |
| `NOOP_SAFETY_WORKER_POLL_SECONDS` | no | `2` | Idle delivery-worker poll interval |
| `NOOP_SAFETY_WORKER_HEARTBEAT_TIMEOUT_SECONDS` | no | `30` | Maximum heartbeat age before new paging is blocked |
| `NOOP_SAFETY_DELIVERY_LEASE_SECONDS` | no | `30` | Crash-recovery lease; must exceed provider request timeout plus the poll interval |
| `NOOP_SAFETY_RETRY_BASE_SECONDS` | no | `5` | Initial bounded exponential delivery retry delay |
| `NOOP_SAFETY_PROVIDER_REQUEST_TIMEOUT_SECONDS` | no | `15` | Twilio HTTP request timeout; interrupted outcomes remain `unknown` |
| `NOOP_SAFETY_PROVIDER_RECEIPT_TIMEOUT_SECONDS` | no | `300` | Age at which a provider submission without a receipt becomes `unknown` |
| `NOOP_SAFETY_WORKER_ENABLED` | no | `true` | Run the in-process paging loop; Compose disables it on API processes and uses `safety-worker` |
| `NOOP_SAFETY_WORKER_BATCH_SIZE` | no | `20` | Maximum jobs leased per worker cycle |
| `NOOP_SAFETY_WORKER_MAX_CONCURRENCY` | no | `6` | Maximum concurrent submissions; must remain below the worker database-pool maximum |
| `NOOP_SAFETY_INCIDENT_RETENTION_DAYS` | no | `0` | Days to keep terminal Safety incidents; `0` disables incident retention |
| `NOOP_SAFETY_CONTACT_RETENTION_DAYS` | no | `0` | Days after expiry/decline/revocation to keep inactive contacts; accepted contacts are never aged; `0` disables |
| `NOOP_SAFETY_RETENTION_INTERVAL_HOURS` | no | `24` | Hours between bounded Safety retention runs |
| `NOOP_SAFETY_RETENTION_MAX_BATCHES_PER_RUN` | no | `20` | Maximum Safety retention batches per scheduled or manual run |
| `NOOP_SAFETY_WORKER_STOP_GRACE_PERIOD` | Compose only | `45s` | Graceful worker shutdown window; keep longer than the provider request timeout |
| `NOOP_PORT` | Compose only | `8080` | Loopback host port |
| `NOOP_BACKUP_SECRET_FILE` | Compose only | `./secrets/backup-passphrase.txt` | Host path to an untracked file containing at least 32 random bytes |
| `NOOP_BACKUP_INTERVAL_SECONDS` | no | `86400` | Seconds between encrypted PostgreSQL backups; one backup also runs at container start |
| `NOOP_BACKUP_RETENTION_DAYS` | no | `30` | Age after which this backup job deletes only its own encrypted archives/manifests |
| `NOOP_BACKUP_TMPFS_SIZE` | Compose only | `2g` | Memory-backed plaintext workspace ceiling for dump/restore; size above the largest compressed dump |

Changing `NOOP_API_TOKEN` invalidates existing app/dashboard connections. Never
commit `.env`, put the token in a URL, or send it in a bug report.

Paging remains disabled unless all six base paging values are present. A
partial configuration fails startup, and `NOOP_PUBLIC_BASE_URL` must be a public
HTTPS origin. Use a restricted Twilio API key for outbound calls when possible;
the account Auth Token is still required for webhook validation. Complete
carrier registration and geographic permissions before enabling it. See
[SAFETY.md](SAFETY.md) for the incident contract, staging test, monitoring
thresholds, and the explicit non-emergency boundary.
For multi-replica deployment, capacity testing, paging controls, and the honest
10,000-user tenancy boundary, see
[PRODUCTION_OPERATIONS.md](PRODUCTION_OPERATIONS.md).

## API contract

`GET /healthz` is a process liveness probe and does not touch the database.
`GET /readyz` executes a database query and verifies the exact immutable
migration manifest for this build. It returns HTTP 503 when storage is
unavailable, a migration is missing, or applied migration bytes differ. Both
probes are public and reveal only a generic state. In `single_owner` mode,
full-data sync/reads, data control, and bootstrap routes accept:

```text
Authorization: Bearer <NOOP_API_TOKEN>
```

In `shared` mode, the administrator first enrolls an installation through
`POST /v1/admin/installations`, supplying a client-generated enrollment UUID
and `noop_install_...` token. The server stores only the digest. That
installation credential can claim only device IDs in its own namespace and can
rotate, export, or erase itself through `/v1/installation/me`; the operator
token cannot read or write shared biometric data. This is suitable for
pre-provisioned shared testing, but public signup, identity proof, and
lost-device recovery remain external product decisions. See
[PRODUCTION_OPERATIONS.md](PRODUCTION_OPERATIONS.md).

Friends endpoints use a separate per-installation `noop_member_…` credential
issued by the admin-authenticated bootstrap route or generated and saved by a
joining client before it consumes an invite. The server stores only its SHA-256
digest. A member token cannot call export, device, raw-stream, journal, workout,
or admin read routes. It can upload only its exact, dedicated `noop_computed`
Friends producer through `POST /v1/sync`; each supplied day replaces the six
allowlisted social keys for that day. A first-time join is retry-safe through
its client-generated enrollment UUID and token, so a lost response does not
orphan the profile. Shared-mode joins also require the joining installation
credential, preventing an invite holder from selecting another installation's
producer namespace. The server admin token is never shared. See
[FRIENDS.md](FRIENDS.md) for the complete flow and privacy contract.

The app uploads to `POST /v1/sync`. `batch_id` is the durable idempotency key;
the optional `Idempotency-Key` header must contain that same UUID. A replay with
identical normalized content returns `duplicate: true`; reusing the UUID for
different content returns HTTP 409.

Every `/v1` request is bounded in-process by its direct client address and, when
present, a SHA-256 fingerprint of its Bearer credential. Plaintext tokens are
not retained by the limiter. These limits protect one API process only: a
multi-replica or internet deployment must also use a shared/distributed limit at
its trusted reverse proxy. Do not accept client-supplied forwarding headers from
untrusted peers.

Sync is atomic: malformed or out-of-range records return HTTP 422 with their
field/index path; the server never silently drops a sensor row and acknowledges
the rest. Epoch-era legacy timestamps are accepted from 1970 through 2100, and
user-entered notes/sport labels have comfortable limits under the separate 10 MB
request ceiling. The app should surface a rejected row for correction/quarantine
rather than retrying an unchanged poison batch forever.

Canonical measured-source payload (abbreviated). A `strap_measured` envelope is
raw-only; it cannot mix daily/sleep/workout/journal rows into the same source:

```json
{
  "schema_version": 1,
  "batch_id": "27b96e25-4475-4c60-9c40-d53194b0fb75",
  "source": {
    "device_id": "ios:11111111-1111-4111-8111-111111111111:strap-abc-strap",
    "sent_at": "2026-07-24T18:30:00Z",
    "app_version": "10.0",
    "platform": "ios",
    "device": {"display_name": "My strap"},
    "metadata": {
      "installation_id": "11111111-1111-4111-8111-111111111111",
      "logical_source_id": "strap-abc-strap",
      "namespace": "strap_measured",
      "paired_device_id": "strap-abc",
      "privacy": "explicit_opt_in",
      "score_provenance": "strap_measured"
    }
  },
  "streams": {
    "hr": [
      {
        "recorded_at": 1784917770,
        "value": 72,
        "metadata": {"unit": "bpm", "provenance": "strap_measured"}
      }
    ],
    "rr": [
      {
        "recorded_at": 1784917770,
        "value": 812,
        "metadata": {"unit": "ms", "seq": "0"}
      },
      {
        "recorded_at": 1784917770,
        "value": 812,
        "metadata": {"unit": "ms", "seq": "1"}
      }
    ],
    "spo2": [
      {
        "recorded_at": 1784917770,
        "value": 18000,
        "metadata": {
          "unit": "raw_adc",
          "uncalibrated": "true",
          "infrared": "17000"
        }
      }
    ],
    "events": []
  },
  "daily_metrics": {},
  "sleep_sessions": [],
  "workouts": [],
  "journal": []
}
```

An imported official reference uses a separate, derived-only producer:

```json
{
  "schema_version": 1,
  "batch_id": "f117a247-3fdd-4fc3-aaeb-59d5c0b11745",
  "source": {
    "device_id": "ios:11111111-1111-4111-8111-111111111111:whoop-official-reference",
    "sent_at": "2026-07-24T18:30:00Z",
    "platform": "ios",
    "metadata": {
      "installation_id": "11111111-1111-4111-8111-111111111111",
      "logical_source_id": "whoop-official-reference",
      "namespace": "official_reference",
      "paired_device_id": "strap-abc",
      "privacy": "explicit_opt_in",
      "score_provenance": "user_imported_whoop_export"
    }
  },
  "streams": {},
  "daily_metrics": {
    "2026-07-24": {
      "efficiency": 0.91,
      "recovery": 72,
      "effort": 59.047619,
      "whoop_strain": 12.4
    }
  },
  "sleep_sessions": [],
  "workouts": [],
  "journal": []
}
```

The complete golden examples are
[`tests/data/apple_sync_v1.json`](tests/data/apple_sync_v1.json) and
[`tests/data/official_reference_sync_v1.json`](tests/data/official_reference_sync_v1.json).

Sleep efficiency is always a `0...1` fraction: `0.91` means 91%. Canonical
sleep stage totals are integer **seconds** keyed by stage. Legacy JSON strings
and segment arrays are accepted without silently converting their units.
Same-second R-R intervals remain distinct through their interval value plus
`metadata.seq` (the client's full natural key is timestamp + value + duplicate
sequence).

The raw `steps` stream is a wrapping `cumulative_counter`, not a daily step
total. Daily estimated/imported steps live in `daily_metrics.steps`; clients and
the dashboard must not relabel the device register as a day's steps.

Every `source.metadata` object must contain non-empty strings for
`installation_id`, `logical_source_id`, `namespace`, `paired_device_id`,
`privacy`, and `score_provenance`; `privacy` must equal
`explicit_opt_in`. `noop_computed` also requires `algorithm_revision`.

The current clients keep provenance in separate producer namespaces:

| `metadata.namespace` | Required `score_provenance` | Permitted payload |
| --- | --- | --- |
| `strap_measured` | `strap_measured` | Decoded streams/events only |
| `official_reference` | `user_imported_whoop_export` | Daily/sleep/workout rows only; may carry `whoop_strain` |
| `noop_computed` | `noop_transparent_algorithm` | Daily/sleep/workout rows only; requires `algorithm_revision` |
| `noop_journal` | `user_entered_noop_journal` | Journal rows only |
| `apple_health_import` | `user_imported_apple_health` | Daily/sleep/workout rows only |
| `health_connect_import` | `user_imported_health_connect` | Daily/sleep/workout rows only |
| `activity_file_import` | `user_imported_activity_file` | Daily/sleep/workout rows only |
| `wearable_import` | `user_imported_wearable` | Daily/sleep/workout rows only |

The wire `source.device_id` is a producer identity scoped by platform and app
installation, such as
`ios:<installation UUID>:whoop-official-reference`. It is deliberately not just
the paired strap id. The readable source before scoping remains in
`logical_source_id`, while `paired_device_id` retains the unsuffixed local strap
identity.

Consumers must compare namespaces by paired day/time; they must not overwrite one
with another or present Noop-computed values as official WHOOP results.

The local database stores the activity-load column on Noop's common 0–100
**Effort** axis. On the wire, clients therefore emit `effort` (0–100) and never
the ambiguous key `strain`. An `official_reference` row additionally emits
`whoop_strain` after the exact inverse conversion to WHOOP's native 0–21 axis.
Likewise, an official export's absolute skin temperature is
`skin_temp_c`; `skin_temp_dev_c` is reserved for an actual deviation.

### Replication boundary and deletion

Sync v1 accepts HR, R-R intervals, battery, raw optical/temperature/respiration
channels, cumulative step-counter samples, protocol events, supported daily
metrics, sleep summaries/stage totals, workouts, and journal answers. It does
not mirror gravity, band sleep state, PPG waveform/derived PPG-HR storage, raw
IMU, compressed `rawBatch` frames, Oura raw pages, arbitrary `metricSeries`,
labs, nutrition, hydration, mood, or per-epoch sleep motion/state JSON.

The service is an archival upsert target, not a two-way app restore system.
Updating a supported natural key replaces that server row. Deleting a local app
row does not emit a tombstone, and disconnecting an app only stops future
uploads. Use `DELETE /v1/devices/{id}` or the dashboard for server deletion.
Because IDs are installation-scoped, repeat deletion for each producer identity
you intend to erase.

Apple clients catch up on launch/foreground activation or **Run now**; this is
not a guaranteed iOS background task. Android also uses best-effort WorkManager
scheduling. Destination replay is resumable and bounded: pending raw rows are
drained, while supported derived history is currently capped at ten years.

### Read and control routes

- `GET /v1/status`
- `GET /v1/devices`
- `GET /v1/devices/{id}/latest`
- `GET /v1/devices/{id}/streams/{hr|rr|battery|spo2|skin_temp|respiration|steps|gravity|sleep_state}`
- `GET /v1/devices/{id}/freshness` (server-observed sample age and gap summary)
- `GET /v1/devices/{id}/events`
- `GET /v1/devices/{id}/daily`
- `GET /v1/devices/{id}/sleep`
- `GET /v1/devices/{id}/workouts`
- `GET /v1/devices/{id}/journal`
- `GET /v1/devices/{id}/export`
- `DELETE /v1/devices/{id}` with `X-Noop-Confirm: DELETE <id>`
- `POST /v1/admin/retention/run` with `X-Noop-Confirm: PURGE`

When `NOOP_RETENTION_DAYS` is positive, the API also runs the same global purge
on a bounded schedule. The first automatic cycle occurs after
`NOOP_RETENTION_INTERVAL_HOURS`; the manual route remains available for an
immediate, explicitly confirmed run. A failed scheduled cycle is logged and
retried at the next interval without interrupting sync ingestion. PostgreSQL
serializes retention cycles across API replicas with a transaction-scoped
advisory lock; the in-memory test repository uses an equivalent async lock.

### Invitation-only Friends

Friends is an optional local-server feature. Bootstrap is protected by
`NOOP_API_TOKEN`; existing profiles use member tokens, while invite join uses
the one-time code to authorize a client-generated enrollment UUID and member
token. There is no username search, contact upload, public profile, or public
discovery.

- `POST /v1/social/bootstrap`
- `GET /v1/social/admin/profiles`
- `PATCH /v1/social/admin/profiles/{id}`
- `POST /v1/social/admin/profiles/{id}/rotate-token`
- `DELETE /v1/social/admin/profiles/{id}`
- `GET /v1/social/me`
- `DELETE /v1/social/me` with
  `X-Noop-Confirm: DELETE MY SOCIAL PROFILE`
- `DELETE /v1/social/enrollments/{enrollment_id}` with
  `X-Noop-Confirm: DELETE PENDING SOCIAL ENROLLMENT`
- `POST /v1/social/invites`
- `DELETE /v1/social/invites/{id}`
- `POST /v1/social/invites/join`
- `POST /v1/social/invites/redeem`
- `GET /v1/social/requests`
- `POST /v1/social/requests/{id}`
- `GET /v1/social/friends`
- `PATCH /v1/social/friends/{id}/privacy`
- `DELETE /v1/social/friends/{id}`
- `POST /v1/social/blocks/{id}`
- `DELETE /v1/social/blocks/{id}`
- `GET /v1/social/feed`

The feed is a server-side allowlist over `noop_computed` daily rows on or after
the friendship's UTC creation date. Charge, Effort, and Rest are enabled when a
friendship is accepted; sleep duration, HRV, and resting heart rate are disabled
until the owner enables each field for that specific friend. Raw samples,
events, location, journals, workouts, sleep stages, metadata, and provenance are
never returned by the Friends API. A member-confirmed self-delete removes only
that profile's exact dedicated social producer and social graph state, not the
separate full-data archive producer. Pending-enrollment deletion is
credential-bound, idempotent, and exists so a client can safely clean up after
an interrupted first-join response.

Export before destructive operations:

```sh
NOOP_DEVICE_ID='ios:11111111-1111-4111-8111-111111111111:strap-abc-strap'
curl --fail-with-body \
  -H "Authorization: Bearer $NOOP_API_TOKEN" \
  -o noop-export.json \
  "http://127.0.0.1:8080/v1/devices/$NOOP_DEVICE_ID/export"
```

Device, installation, and Safety exports share `NOOP_EXPORT_MAX_ROWS`. They
return HTTP `413` rather than silently truncating when the aggregate result is
too large. Supply UTC-offset `start` and/or `end` query parameters to retrieve
bounded windows. Installation exports apply one aggregate budget across all
owned devices; Safety windows include contacts created and incidents started in
that interval together with their child delivery records.

Set a positive `NOOP_RETENTION_DAYS` and restart to enable scheduled retention;
the authenticated endpoint remains available for an immediate confirmed run.
When a retention run or explicit device deletion removes an idempotency receipt,
the server retains only its batch UUID and canonical payload digest for
`NOOP_IDEMPOTENCY_REPLAY_GUARD_DAYS`. An exact retry returns HTTP 410 instead of
silently recreating deleted rows. The tombstone has no device identifier or
biometric values and expires automatically. It cannot prevent a deliberately
modified payload with a new identity, so local-to-server deletion is still not
a two-way protocol tombstone.

Compose also starts an encrypted backup worker. It performs a custom-format
`pg_dump` at startup and on the configured interval, encrypts it with GnuPG
AES-256 using the mounted secret file, publishes it atomically with a SHA-256
manifest, and prunes only archives it owns. The worker fails before invoking
`pg_dump` when the secret is missing, unreadable, empty, or shorter than 32
bytes. See [TLS_AND_BACKUPS.md](TLS_AND_BACKUPS.md) for off-host copies and the
required disposable restore drill.

## Development and tests

API tests use `MemoryRepository` and require no Docker:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest
```

The production repository applies immutable SQL files in lexical order, records
each checksum in `noop_schema_migrations`, and refuses to start if an
already-applied migration was edited. `NOOP_DATABASE_ENGINE=timescaledb` uses
`migrations/` and makes the metric-sample table a hypertable.
`NOOP_DATABASE_ENGINE=postgresql` substitutes only
`migrations-postgresql/001_init.sql`, which removes the Timescale extension and
hypertable calls; all later migrations remain canonical. The two initial
migrations intentionally have different checksums, so changing engines under an
existing database fails rather than silently changing its storage contract.

Migration `002_row_provenance.sql` preserves `sync_batch_id`,
`source_platform`, and the full `source_metadata` object on each metric, event,
daily, sleep, workout, and journal row—not just on the latest device summary.
The schema also keeps units, measurement class, and an explicit
`clinical_interpretation_allowed` flag. Raw/unclassified sensor rows are
database-constrained to `false`.

Migration `003_friends.sql` adds invitation-only profiles, one-time invite and
request state, canonical friendships, directional visibility, and blocks. Only
credential/code digests are persisted.

Migration `004_sync_tombstones.sql` adds the bounded, device-unlinked deletion
ledger used to reject exact replay after idempotency receipts are removed.
