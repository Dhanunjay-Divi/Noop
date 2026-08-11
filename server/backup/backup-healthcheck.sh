#!/bin/sh
set -eu

marker=${NOOP_BACKUP_DIRECTORY:-/backups}/.last-success
interval_seconds=${NOOP_BACKUP_INTERVAL_SECONDS:-86400}
case "$interval_seconds" in
    ''|*[!0-9]*) exit 1 ;;
esac
[ "$interval_seconds" -gt 0 ] || exit 1
[ -s "$marker" ] || exit 1

now=$(date -u +%s)
modified=$(stat --format=%Y "$marker")
# Allow one scheduled interval plus one hour for a large database dump.
[ "$((now - modified))" -le "$((interval_seconds + 3600))" ]
