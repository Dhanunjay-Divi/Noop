# TLS, network exposure, and backups

## Internet exposure

Do not expose Uvicorn or TimescaleDB directly to the internet. Keep the Compose
port on loopback, terminate TLS in a maintained reverse proxy, and forward only
to `127.0.0.1:8080`. The API token protects the application route; TLS protects
the token and biometric data in transit.

Minimal Caddy configuration after DNS points to the server:

```caddyfile
noop.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
    }
    request_body {
        max_size 10MB
    }
}
```

Use `https://noop.example.com` in the app. Restrict SSH, patch the host and proxy,
do not log `Authorization` headers, and rate-limit repeated authentication
failures at the proxy. If the service is only for one household, a private VPN
such as WireGuard/Tailscale is a smaller attack surface than a public hostname.

The API has bounded process-local sliding-window limits for both the trusted
client address and a digest of each Bearer credential. Those counters are not
shared across workers, hosts, or replicas. Keep a distributed limit at the
reverse proxy as the authoritative public-edge control; key it by validated
client address and route, and apply a stricter budget to repeated 401/403
responses. Never use an untrusted `X-Forwarded-For` value as the rate-limit key.

`--forwarded-allow-ips` in the Docker command trusts loopback only. If the proxy
runs outside the host network namespace, set that option to the exact proxy
address rather than `*`.

## Automated encrypted backups

The live TimescaleDB volume is not a backup. Compose therefore runs a separate
`backup` service that creates a PostgreSQL custom-format dump immediately at
startup and every `NOOP_BACKUP_INTERVAL_SECONDS` thereafter. A dump is written
to a private temporary file, encrypted with GnuPG AES-256 using a Docker-mounted
secret, and only then published alongside a SHA-256 manifest. Unencrypted
partials are removed on success, failure, or termination. The healthcheck also
fails when the last successful backup is older than one interval plus one hour.

Create the secret before the first Compose start:

```sh
install -d -m 0700 secrets
openssl rand -base64 48 > secrets/backup-passphrase.txt
chmod 0600 secrets/backup-passphrase.txt
```

The scripts reject a missing, unreadable, empty, or shorter-than-32-byte secret
before dumping or decrypting. Do not place the passphrase in `.env`, command-line
arguments, source control, backup filenames, or operator logs. Keep a separately
protected copy: losing it makes every encrypted archive unrecoverable. Preserve
old keys for backups encrypted before a planned rotation.

The encrypted files live in the `noop_encrypted_backups` volume, separate from
the live database volume. List them without exposing the secret:

```sh
docker compose exec backup find /backups -maxdepth 1 -name 'noop-*.dump.gpg' -print
```

Copy each `.dump.gpg` and matching `.sha256` to versioned, access-controlled
off-host storage. A second volume on the same machine does not protect against
host loss or ransomware. Monitor the backup container's health/restart state
and alert on failure; local retention defaults to 30 days and never selects
unrelated filenames.

## Mandatory restore drill

At least monthly, and after PostgreSQL/TimescaleDB or backup-image upgrades, run
the included drill against the newest archive. It creates a uniquely named
disposable database on the same PostgreSQL server, verifies the manifest,
decrypts and validates the complete `pg_restore` catalog before changing that
database, follows TimescaleDB's pre/post-restore protocol, restores it, checks
core biometric, social, installation-tenancy, and Safety lifecycle tables,
verifies the paging control and its audit seed, checks ownership, queue, and
replay-tombstone relationships, reports row counts, and drops the drill
database on exit:

```sh
docker compose exec backup \
  sh /opt/noop/restore-drill.sh /backups/noop-YYYYMMDDTHHMMSSZ-NNN.dump.gpg
```

The Compose `noop` database owner can create the disposable drill database. In
a custom least-privilege deployment, run the drill with a separate maintenance
credential that can create/drop databases; do not grant that capability to the
steady-state API credential.

Record the archive name, date, script exit status, elapsed time, and restored row
counts in your private operations log. This repository's unit tests validate the
fail-closed/script contract, but only a drill against your running TimescaleDB
validates credentials, extensions, storage capacity, and real backup contents.

## Disaster restore

Stop the API, preserve the current database volume, and restore to a newly
created database. The script deliberately refuses a destination that already
contains public tables; it does not use `--clean` against the only live copy.
The sequence follows TimescaleDB's official
[logical-backup procedure](https://docs.timescale.com/self-hosted/latest/backup-and-restore/logical-backup/):

```sh
docker compose stop api
docker compose exec db createdb --username=noop noop_restored
docker compose run --rm \
  -e PGDATABASE=noop_restored \
  -e NOOP_RESTORE_CONFIRM=RESTORE_EMPTY_DATABASE \
  backup sh /opt/noop/restore.sh \
  /backups/noop-YYYYMMDDTHHMMSSZ-NNN.dump.gpg
# After the restore drill/inspection succeeds, set NOOP_DB_NAME=noop_restored
# in .env so the API and future backups use the restored database.
docker compose up -d
curl --fail http://127.0.0.1:8080/readyz
```

`restore.sh` verifies the SHA-256 manifest, decrypts to private temporary storage,
runs `pg_restore --list`, creates/enables the TimescaleDB extension, invokes
`timescaledb_pre_restore()`, restores without parallel mode, always attempts
`timescaledb_post_restore()` after a prepared failure, and analyzes a successful
restore. A failed target can be dropped and recreated without touching the old
database. The confirmation gate does not replace an off-host copy or a tested
cutover/rollback plan. Keep the database password, API token, and backup
encryption key separate.

## Updating

1. Export or back up the database.
2. Review application and TimescaleDB release notes.
3. Pull the intended source revision.
4. Run `docker compose build --pull`.
5. Run `docker compose up -d`.
6. Confirm `docker compose ps`, `/healthz`, `/readyz`, authenticated
   `/v1/status`, a fresh client sync, and a successful encrypted backup.

Never use `docker compose down -v` during a routine update; `-v` deletes the
database volume.
