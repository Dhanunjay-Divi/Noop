#!/bin/sh
set -eu

umask 077

if [ "$#" -ne 1 ]; then
    echo "usage: restore.sh /backups/noop-TIMESTAMP.dump.gpg" >&2
    exit 64
fi
if [ "${NOOP_RESTORE_CONFIRM:-}" != "RESTORE_EMPTY_DATABASE" ]; then
    echo "set NOOP_RESTORE_CONFIRM=RESTORE_EMPTY_DATABASE for this operation" >&2
    exit 78
fi

encrypted_backup=$1
passphrase_file=${NOOP_BACKUP_PASSPHRASE_FILE:-/run/secrets/noop_backup_passphrase}
if [ ! -r "$passphrase_file" ] || [ ! -s "$passphrase_file" ]; then
    echo "backup passphrase file is required and must be non-empty" >&2
    exit 78
fi
if [ "$(wc -c < "$passphrase_file")" -lt 32 ]; then
    echo "backup passphrase file must contain at least 32 bytes" >&2
    exit 78
fi
if [ ! -r "$encrypted_backup" ] || [ ! -s "$encrypted_backup" ]; then
    echo "encrypted backup does not exist or is empty" >&2
    exit 66
fi

backup_directory=$(dirname "$encrypted_backup")
backup_name=$(basename "$encrypted_backup")
checksum_name="${backup_name}.sha256"
if [ ! -r "${backup_directory}/${checksum_name}" ]; then
    echo "matching SHA-256 manifest is required" >&2
    exit 66
fi
(
    cd "$backup_directory"
    sha256sum --check "$checksum_name"
)

plain_backup=$(mktemp /tmp/noop-restore.XXXXXX.dump)
gpg_home=""
restore_prepared=0
cleanup() {
    if [ "$restore_prepared" -eq 1 ]; then
        psql \
            --dbname="${PGDATABASE:?PGDATABASE is required}" \
            --set=ON_ERROR_STOP=1 \
            --command="SELECT timescaledb_post_restore();" \
            >/dev/null 2>&1 || true
    fi
    rm -f "$plain_backup"
    if [ -n "$gpg_home" ]; then
        rm -rf -- "$gpg_home"
    fi
}
trap cleanup EXIT HUP INT TERM
gpg_home=$(mktemp -d /tmp/noop-gpg.XXXXXX)
chmod 0700 "$gpg_home"

gpg \
    --homedir "$gpg_home" \
    --batch \
    --yes \
    --pinentry-mode loopback \
    --passphrase-file "$passphrase_file" \
    --decrypt \
    --output "$plain_backup" \
    "$encrypted_backup"

# Validate the complete archive before changing the destination database.
pg_restore --list "$plain_backup" >/dev/null

user_table_count=$(psql \
    --dbname="${PGDATABASE:?PGDATABASE is required}" \
    --set=ON_ERROR_STOP=1 \
    --no-align \
    --tuples-only \
    --command="SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');")
if [ "$user_table_count" != "0" ]; then
    echo "destination database must be empty; restore to a new database" >&2
    exit 65
fi

psql \
    --dbname="$PGDATABASE" \
    --set=ON_ERROR_STOP=1 \
    --command="CREATE EXTENSION IF NOT EXISTS timescaledb;"
psql \
    --dbname="$PGDATABASE" \
    --set=ON_ERROR_STOP=1 \
    --command="SELECT timescaledb_pre_restore();"
restore_prepared=1
pg_restore \
    --exit-on-error \
    --no-owner \
    --no-privileges \
    --dbname="${PGDATABASE:?PGDATABASE is required}" \
    "$plain_backup"
psql \
    --dbname="$PGDATABASE" \
    --set=ON_ERROR_STOP=1 \
    --command="SELECT timescaledb_post_restore();"
restore_prepared=0
psql \
    --dbname="$PGDATABASE" \
    --set=ON_ERROR_STOP=1 \
    --command="ANALYZE;"

echo "restore completed for database ${PGDATABASE}"
