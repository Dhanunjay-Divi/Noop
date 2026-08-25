\set ON_ERROR_STOP on

BEGIN READ ONLY;

DO $smoke$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version !~ '^[0-9]{3}_[a-z0-9_]+[.]sql$'
           OR btrim(checksum) !~ '^[0-9a-f]{64}$'
    ) THEN
        RAISE EXCEPTION 'invalid migration version or checksum';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version = '010_installation_tenancy.sql'
    ) THEN
        RAISE EXCEPTION 'required tenancy migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version = '011_safety_data_lifecycle.sql'
    ) THEN
        RAISE EXCEPTION 'required Safety lifecycle migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version = '012_tenancy_cutover_invariants.sql'
    ) THEN
        RAISE EXCEPTION 'required tenancy cutover migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version = '013_safety_escalation_contract.sql'
    ) THEN
        RAISE EXCEPTION 'required Safety escalation migration is missing';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM installation_devices device
        LEFT JOIN installation_credentials installation
          USING (installation_id)
        WHERE installation.installation_id IS NULL
    ) THEN
        RAISE EXCEPTION 'orphaned installation device ownership was restored';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM devices device
        LEFT JOIN installation_devices ownership USING (device_id)
        WHERE ownership.device_id IS NULL
    ) THEN
        RAISE EXCEPTION 'device without installation ownership was restored';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM friend_profiles profile
        LEFT JOIN installation_credentials installation
          USING (installation_id)
        WHERE installation.installation_id IS NULL
    ) OR EXISTS (
        SELECT 1
        FROM safety_profiles profile
        LEFT JOIN installation_credentials installation
          USING (installation_id)
        WHERE installation.installation_id IS NULL
    ) THEN
        RAISE EXCEPTION 'profile without installation ownership was restored';
    END IF;
    IF (
        SELECT count(*)
        FROM safety_runtime_controls
        WHERE control_name = 'paging'
          AND revision > 0
    ) <> 1 THEN
        RAISE EXCEPTION 'paging control row is missing or duplicated';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM safety_runtime_controls control
        JOIN safety_runtime_control_audit audit
          ON audit.control_name = control.control_name
         AND audit.revision = control.revision
        WHERE control.control_name = 'paging'
          AND char_length(audit.actor) BETWEEN 1 AND 128
    ) THEN
        RAISE EXCEPTION 'current paging control has no actor audit';
    END IF;
    IF (
        SELECT count(*)
        FROM safety_provider_rate_state
        WHERE provider_name = 'twilio'
          AND next_slot_at IS NOT NULL
    ) <> 1 THEN
        RAISE EXCEPTION 'Twilio sender-rate state is missing';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM safety_deliveries delivery
        JOIN safety_dispatches incident
          ON incident.dispatch_id = delivery.dispatch_id
        WHERE delivery.escalation_round < 0
           OR (
                incident.escalation_rounds IS NOT NULL
                AND delivery.escalation_round >= incident.escalation_rounds
           )
    ) THEN
        RAISE EXCEPTION 'Safety escalation round is outside its incident contract';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM safety_invitation_jobs job
        LEFT JOIN safety_contacts contact
          ON contact.contact_id = job.contact_id
        WHERE contact.contact_id IS NULL
    ) OR EXISTS (
        SELECT 1
        FROM safety_invitation_attempts attempt
        LEFT JOIN safety_invitation_jobs job
          ON job.contact_id = attempt.contact_id
        WHERE job.contact_id IS NULL
    ) OR EXISTS (
        SELECT 1
        FROM safety_delivery_attempts attempt
        LEFT JOIN safety_deliveries delivery
          ON delivery.delivery_id = attempt.delivery_id
        WHERE delivery.delivery_id IS NULL
    ) THEN
        RAISE EXCEPTION 'orphaned Safety queue rows were restored';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM safety_dispatch_tombstones tombstone
        LEFT JOIN safety_profiles profile
          USING (profile_id)
        WHERE profile.profile_id IS NULL
    ) THEN
        RAISE EXCEPTION 'orphaned Safety replay tombstone was restored';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM safety_invitation_jobs job
        LEFT JOIN safety_invitation_attempts attempt
          ON attempt.attempt_id = job.active_attempt_id
         AND attempt.contact_id = job.contact_id
         AND attempt.invitation_nonce = job.invitation_nonce
         AND attempt.status = 'started'
        WHERE job.status = 'leased'
          AND attempt.attempt_id IS NULL
    ) OR EXISTS (
        SELECT 1
        FROM safety_deliveries delivery
        WHERE delivery.status = 'leased'
          AND NOT EXISTS (
              SELECT 1
              FROM safety_delivery_attempts attempt
              WHERE attempt.delivery_id = delivery.delivery_id
                AND attempt.status = 'started'
          )
    ) THEN
        RAISE EXCEPTION 'leased Safety work has no active attempt';
    END IF;
END
$smoke$;

PREPARE noop_safety_profile_lookup(text) AS
SELECT profile_id, enrollment_id, display_name, installation_id,
       token_version, last_rotation_id, created_at, updated_at
FROM safety_profiles
WHERE token_hash = $1 AND disabled_at IS NULL;
EXECUTE noop_safety_profile_lookup('__restore_smoke_missing_token__');

PREPARE noop_installation_lookup(text) AS
SELECT installation_id, enrollment_id, token_version, last_rotation_id,
       created_at, updated_at
FROM installation_credentials
WHERE token_hash = $1 AND revoked_at IS NULL;
EXECUTE noop_installation_lookup('__restore_smoke_missing_token__');

PREPARE noop_latest_metric(text, text) AS
SELECT value, unit, recorded_at
FROM metric_samples
WHERE device_id = $1 AND metric = $2
ORDER BY recorded_at DESC
LIMIT 1;
EXECUTE noop_latest_metric(
    '__restore_smoke_missing_device__',
    '__restore_smoke_missing_metric__'
);

SELECT status, count(*)
FROM safety_deliveries
WHERE status IN ('pending', 'retry_wait', 'leased', 'queued', 'sent')
   OR updated_at >= clock_timestamp() - interval '24 hours'
GROUP BY status;

SELECT count(*)
FROM safety_delivery_attempts
WHERE status = 'unknown'
  AND COALESCE(finished_at, started_at) >=
      clock_timestamp() - interval '24 hours';

DEALLOCATE noop_safety_profile_lookup;
DEALLOCATE noop_installation_lookup;
DEALLOCATE noop_latest_metric;

ROLLBACK;
