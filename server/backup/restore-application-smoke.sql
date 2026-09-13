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
    IF (
        SELECT count(*)
        FROM noop_schema_migrations
        WHERE version = ANY(
            ARRAY[
                '034_managed_document_contract_v2_add.sql',
                '035_managed_document_plaintext_quarantine.sql',
                '036_managed_document_contract_v2_validate.sql',
                '037_managed_document_contract_v2_activate.sql',
                '038_managed_safety_band_sos.sql'
            ]
        )
    ) <> 5 THEN
        RAISE EXCEPTION 'required managed contract migration is missing';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                (
                    'managed_documents'::regclass,
                    'managed_document_kind'
                ),
                (
                    'managed_safety_incidents'::regclass,
                    'managed_safety_incident_trigger'
                ),
                (
                    'managed_safety_page_quota_events'::regclass,
                    'managed_safety_page_quota_trigger'
                )
        ) AS required(table_oid, constraint_name)
        LEFT JOIN pg_constraint constraint_row
          ON constraint_row.conrelid = required.table_oid
         AND constraint_row.conname = required.constraint_name
        WHERE constraint_row.oid IS NULL
           OR NOT constraint_row.convalidated
    ) THEN
        RAISE EXCEPTION 'managed document or Safety constraint is missing or unvalidated';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute
        WHERE attrelid = 'managed_safety_page_quota_events'::regclass
          AND attname = 'trigger'
          AND attnotnull
          AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION 'managed Safety quota trigger column is nullable or missing';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                (
                    'managed_social_profiles'::regclass,
                    'managed_social_profile_account_immutability'
                ),
                (
                    'managed_safety_incidents'::regclass,
                    'managed_safety_incident_quota_immutability'
                ),
                (
                    'managed_safety_page_quota_events'::regclass,
                    'managed_safety_page_quota_incident_consistency'
                )
        ) AS required(table_oid, trigger_name)
        LEFT JOIN pg_trigger trigger_row
          ON trigger_row.tgrelid = required.table_oid
         AND trigger_row.tgname = required.trigger_name
         AND NOT trigger_row.tgisinternal
        WHERE trigger_row.oid IS NULL
           OR trigger_row.tgenabled NOT IN ('O', 'A')
    ) THEN
        RAISE EXCEPTION 'managed Safety provenance trigger is missing or disabled';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'managed_documents'::regclass
          AND conname IN (
              'managed_document_content_contract',
              'managed_document_content_contract_v2'
          )
    ) THEN
        RAISE EXCEPTION 'managed document content contract activated before client readiness';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM managed_document_contract_v2_readiness
        WHERE readiness_key = 'managed_document_content_v2'
          AND legacy_plaintext_revisions >= 0
          AND legacy_plaintext_heads >= 0
          AND invalid_day_ownership_revisions >= 0
          AND invalid_day_ownership_heads >= 0
          AND encrypted_non_day_revisions >= 0
          AND encrypted_non_day_heads >= 0
    ) THEN
        RAISE EXCEPTION 'managed document readiness inventory is missing';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM managed_document_heads head
        LEFT JOIN managed_documents document
          ON document.account_id = head.account_id
         AND document.document_kind = head.document_kind
         AND document.document_id = head.document_id
         AND document.document_revision = head.current_revision
        WHERE document.account_id IS NULL
           OR document.content_sha256 IS DISTINCT FROM head.content_sha256
           OR document.deleted_at IS DISTINCT FROM head.deleted_at
    ) THEN
        RAISE EXCEPTION 'managed document head does not match its current revision';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM managed_safety_page_quota_events quota
        JOIN managed_safety_incidents incident
          ON incident.incident_id = quota.incident_id
        JOIN managed_social_profiles owner
          ON owner.profile_id = incident.owner_profile_id
        WHERE quota.owner_account_id IS DISTINCT FROM owner.account_id
           OR quota.trigger IS DISTINCT FROM incident.trigger
    ) THEN
        RAISE EXCEPTION 'managed Safety quota provenance is inconsistent';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM managed_safety_locations location
        JOIN managed_safety_incidents incident
          ON incident.incident_id = location.incident_id
        WHERE incident.status NOT IN ('open', 'acknowledged')
    ) THEN
        RAISE EXCEPTION 'terminal managed Safety incident retained precise location';
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
