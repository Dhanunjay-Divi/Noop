#!/bin/sh
set -eu

interval_seconds=${NOOP_BACKUP_INTERVAL_SECONDS:-86400}
case "$interval_seconds" in
    ''|*[!0-9]*)
        echo "NOOP_BACKUP_INTERVAL_SECONDS must be a positive integer" >&2
        exit 64
        ;;
esac
if [ "$interval_seconds" -le 0 ]; then
    echo "NOOP_BACKUP_INTERVAL_SECONDS must be greater than zero" >&2
    exit 64
fi

# Run once at startup. Any failure exits the container so the restart policy
# and operator alerting see it; a failed dump is never marked successful.
while :; do
    sh /opt/noop/backup.sh
    sleep "$interval_seconds"
done
