#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: restore-drill.sh /backups/noop-TIMESTAMP.dump.gpg" >&2
    exit 64
fi

encrypted_backup=$1
drill_database="noop_restore_drill_$(date -u +%s)_$$"

cleanup() {
    dropdb --if-exists --force --maintenance-db=postgres "$drill_database" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

createdb --maintenance-db=postgres "$drill_database"
PGDATABASE="$drill_database" \
NOOP_RESTORE_CONFIRM=RESTORE_EMPTY_DATABASE \
    sh /opt/noop/restore.sh "$encrypted_backup"

schema_ok=$(psql \
    --dbname="$drill_database" \
    --set=ON_ERROR_STOP=1 \
    --no-align \
    --tuples-only \
    --command="SELECT (
        to_regclass('public.noop_schema_migrations') IS NOT NULL
        AND to_regclass('public.devices') IS NOT NULL
        AND to_regclass('public.sync_batches') IS NOT NULL
        AND to_regclass('public.sync_batch_tombstones') IS NOT NULL
        AND to_regclass('public.metric_samples') IS NOT NULL
        AND to_regclass('public.events') IS NOT NULL
        AND to_regclass('public.daily_metrics') IS NOT NULL
        AND to_regclass('public.sleep_sessions') IS NOT NULL
        AND to_regclass('public.workouts') IS NOT NULL
        AND to_regclass('public.journal_entries') IS NOT NULL
        AND to_regclass('public.friend_profiles') IS NOT NULL
    )::int;")
if [ "$schema_ok" != "1" ]; then
    echo "restore drill failed schema verification" >&2
    exit 65
fi

psql \
    --dbname="$drill_database" \
    --set=ON_ERROR_STOP=1 \
    --no-align \
    --tuples-only \
    --command="SELECT json_build_object(
        'migrations', (SELECT count(*) FROM noop_schema_migrations),
        'devices', (SELECT count(*) FROM devices),
        'sync_batches', (SELECT count(*) FROM sync_batches),
        'metric_samples', (SELECT count(*) FROM metric_samples),
        'daily_metrics', (SELECT count(*) FROM daily_metrics),
        'sleep_sessions', (SELECT count(*) FROM sleep_sessions),
        'workouts', (SELECT count(*) FROM workouts),
        'journal_entries', (SELECT count(*) FROM journal_entries)
    );"

echo "restore drill passed in disposable database ${drill_database}"
