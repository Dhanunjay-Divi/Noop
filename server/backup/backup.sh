#!/bin/sh
set -eu

umask 077

backup_directory=${NOOP_BACKUP_DIRECTORY:-/backups}
retention_days=${NOOP_BACKUP_RETENTION_DAYS:-30}
passphrase_file=${NOOP_BACKUP_PASSPHRASE_FILE:-/run/secrets/noop_backup_passphrase}

case "$retention_days" in
    ''|*[!0-9]*)
        echo "NOOP_BACKUP_RETENTION_DAYS must be a non-negative integer" >&2
        exit 64
        ;;
esac

if [ ! -r "$passphrase_file" ] || [ ! -s "$passphrase_file" ]; then
    echo "backup passphrase file is required and must be non-empty" >&2
    exit 78
fi
if [ "$(wc -c < "$passphrase_file")" -lt 32 ]; then
    echo "backup passphrase file must contain at least 32 bytes" >&2
    exit 78
fi
if [ ! -d "$backup_directory" ] || [ ! -w "$backup_directory" ]; then
    echo "backup directory must exist and be writable" >&2
    exit 73
fi
backup_directory=$(cd "$backup_directory" && pwd)
gpg_home=$(mktemp -d /tmp/noop-gpg.XXXXXX)
chmod 0700 "$gpg_home"

timestamp=$(date -u +%Y%m%dT%H%M%SZ-%N)
basename="noop-${timestamp}"
plain_partial=$(mktemp /tmp/noop-backup.XXXXXX.dump)
encrypted_partial="${backup_directory}/.${basename}.$$.dump.gpg.partial"
checksum_partial="${backup_directory}/.${basename}.$$.sha256.partial"
marker_partial="${backup_directory}/.last-success.$$.partial"
encrypted_final="${backup_directory}/${basename}.dump.gpg"
checksum_final="${encrypted_final}.sha256"

cleanup() {
    rm -f \
        "$plain_partial" \
        "$encrypted_partial" \
        "$checksum_partial" \
        "$marker_partial"
    rm -rf -- "$gpg_home"
}
trap cleanup EXIT HUP INT TERM

pg_dump \
    --format=custom \
    --compress=9 \
    --no-owner \
    --no-privileges \
    --file="$plain_partial"

gpg \
    --homedir "$gpg_home" \
    --batch \
    --yes \
    --pinentry-mode loopback \
    --passphrase-file "$passphrase_file" \
    --symmetric \
    --cipher-algo AES256 \
    --output "$encrypted_partial" \
    "$plain_partial"

rm -f "$plain_partial"
mv "$encrypted_partial" "$encrypted_final"
(
    cd "$backup_directory"
    sha256sum "$(basename "$encrypted_final")" > "$checksum_partial"
)
mv "$checksum_partial" "$checksum_final"
sync "$encrypted_final" "$checksum_final"

# Delete only files produced by this script. Partials from an interrupted run
# are also bounded, while unrelated operator files are never selected.
find "$backup_directory" -type f \
    \( -name 'noop-*.dump.gpg' -o -name 'noop-*.dump.gpg.sha256' \
       -o -name '.noop-*.partial' \) \
    -mtime "+$retention_days" -delete

date -u +%Y-%m-%dT%H:%M:%SZ > "$marker_partial"
mv "$marker_partial" "${backup_directory}/.last-success"
echo "encrypted backup completed: $(basename "$encrypted_final")"
