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
        AND to_regclass('public.installation_credentials') IS NOT NULL
        AND to_regclass('public.installation_devices') IS NOT NULL
        AND to_regclass('public.safety_profiles') IS NOT NULL
        AND to_regclass('public.safety_contacts') IS NOT NULL
        AND to_regclass('public.safety_dispatches') IS NOT NULL
        AND to_regclass('public.safety_deliveries') IS NOT NULL
        AND to_regclass('public.safety_delivery_attempts') IS NOT NULL
        AND to_regclass('public.safety_responses') IS NOT NULL
        AND to_regclass('public.safety_incident_locations') IS NOT NULL
        AND to_regclass('public.safety_runtime_controls') IS NOT NULL
        AND to_regclass('public.safety_runtime_control_audit') IS NOT NULL
        AND to_regclass('public.safety_worker_heartbeats') IS NOT NULL
        AND to_regclass('public.safety_invitation_jobs') IS NOT NULL
        AND to_regclass('public.safety_invitation_attempts') IS NOT NULL
        AND to_regclass('public.safety_provider_rate_state') IS NOT NULL
        AND to_regclass('public.safety_dispatch_tombstones') IS NOT NULL
        AND to_regclass('public.managed_accounts') IS NOT NULL
        AND to_regclass('public.managed_social_profiles') IS NOT NULL
        AND to_regclass('public.managed_documents') IS NOT NULL
        AND to_regclass('public.managed_document_heads') IS NOT NULL
        AND to_regclass('public.managed_account_change_sequences') IS NOT NULL
        AND to_regclass('public.managed_change_events') IS NOT NULL
        AND to_regclass(
            'public.managed_document_contract_v2_readiness'
        ) IS NOT NULL
        AND to_regclass('public.managed_safety_incidents') IS NOT NULL
        AND to_regclass(
            'public.managed_safety_page_quota_events'
        ) IS NOT NULL
        AND to_regclass('public.managed_safety_locations') IS NOT NULL
        AND to_regclass('public.managed_safety_push_deliveries') IS NOT NULL
    )::int;")
if [ "$schema_ok" != "1" ]; then
    echo "restore drill failed schema verification" >&2
    exit 65
fi

control_ok=$(psql \
    --dbname="$drill_database" \
    --set=ON_ERROR_STOP=1 \
    --no-align \
    --tuples-only \
    --command="SELECT (
        (SELECT count(*) = 1
         FROM safety_runtime_controls
         WHERE control_name = 'paging' AND revision > 0)
        AND
        (SELECT count(*) >= 1
         FROM safety_runtime_control_audit
         WHERE control_name = 'paging')
    )::int;")
if [ "$control_ok" != "1" ]; then
    echo "restore drill failed Safety control verification" >&2
    exit 65
fi

PGDATABASE="$drill_database" \
    sh /opt/noop/restore-application-smoke.sh "$drill_database"

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
        'journal_entries', (SELECT count(*) FROM journal_entries),
        'installation_credentials', (
            SELECT count(*) FROM installation_credentials
        ),
        'installation_devices', (SELECT count(*) FROM installation_devices),
        'safety_profiles', (SELECT count(*) FROM safety_profiles),
        'safety_contacts', (SELECT count(*) FROM safety_contacts),
        'safety_dispatches', (SELECT count(*) FROM safety_dispatches),
        'safety_deliveries', (SELECT count(*) FROM safety_deliveries),
        'safety_delivery_attempts', (
            SELECT count(*) FROM safety_delivery_attempts
        ),
        'safety_invitation_jobs', (
            SELECT count(*) FROM safety_invitation_jobs
        ),
        'safety_invitation_attempts', (
            SELECT count(*) FROM safety_invitation_attempts
        ),
        'safety_responses', (SELECT count(*) FROM safety_responses),
        'safety_incident_locations', (
            SELECT count(*) FROM safety_incident_locations
        ),
        'safety_control_audit', (
            SELECT count(*) FROM safety_runtime_control_audit
        ),
        'safety_dispatch_tombstones', (
            SELECT count(*) FROM safety_dispatch_tombstones
        ),
        'managed_accounts', (SELECT count(*) FROM managed_accounts),
        'managed_documents', (SELECT count(*) FROM managed_documents),
        'managed_change_events', (SELECT count(*) FROM managed_change_events),
        'managed_safety_incidents', (
            SELECT count(*) FROM managed_safety_incidents
        ),
        'managed_safety_locations', (
            SELECT count(*) FROM managed_safety_locations
        )
    );"

echo "restore drill passed in disposable database ${drill_database}"
