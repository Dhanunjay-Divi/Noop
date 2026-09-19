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
                '038_managed_safety_band_sos.sql',
                '041_managed_safety_writer_compatibility.sql'
            ]
        )
    ) <> 6 THEN
        RAISE EXCEPTION 'required managed contract migration is missing';
    END IF;
    IF to_regclass('public.feedback_reports') IS NULL THEN
        RAISE EXCEPTION 'feedback reports table is missing';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                ('report_id', 'uuid', TRUE),
                ('client_app_id', 'text', TRUE),
                ('subject_hash', 'character(64)', TRUE),
                ('principal_hash_version', 'smallint', TRUE),
                ('principal_hash', 'character(64)', TRUE),
                ('idempotency_hash', 'character(64)', TRUE),
                ('request_hash', 'character(64)', TRUE),
                ('platform', 'text', TRUE),
                ('app_version', 'text', TRUE),
                ('archive_bytes', 'integer', TRUE),
                ('archive_sha256', 'character(64)', TRUE),
                ('includes_user_note', 'boolean', TRUE),
                ('includes_screenshot', 'boolean', TRUE),
                ('receipt', 'character varying(19)', TRUE),
                ('object_key', 'text', TRUE),
                ('status', 'text', TRUE),
                ('object_generation', 'bigint', FALSE),
                ('created_at', 'timestamp with time zone', TRUE),
                ('upload_expires_at', 'timestamp with time zone', TRUE),
                ('completed_at', 'timestamp with time zone', FALSE),
                ('retained_until', 'timestamp with time zone', TRUE),
                ('deleted_at', 'timestamp with time zone', FALSE),
                ('cleanup_after', 'timestamp with time zone', FALSE),
                ('cleanup_phase', 'text', FALSE),
                ('cleanup_claimed_at', 'timestamp with time zone', FALSE),
                ('object_absence_confirmed_at', 'timestamp with time zone', FALSE)
        ) AS required(column_name, expected_type, expected_not_null)
        LEFT JOIN pg_attribute column_state
          ON column_state.attrelid = to_regclass('public.feedback_reports')
         AND column_state.attname = required.column_name
         AND column_state.attnum > 0
         AND NOT column_state.attisdropped
        WHERE column_state.attname IS NULL
           OR format_type(
                column_state.atttypid,
                column_state.atttypmod
              ) <> required.expected_type
           OR column_state.attnotnull IS DISTINCT FROM
                required.expected_not_null
    ) THEN
        RAISE EXCEPTION 'feedback reports runtime column contract is missing or invalid';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                (
                    'feedback_completion_consistent',
                    'c',
                    $definition$CHECK (status = 'sent'::text AND completed_at IS NOT NULL AND object_generation IS NOT NULL OR status <> 'sent'::text)$definition$
                ),
                (
                    'feedback_cleanup_phase_valid',
                    'c',
                    $definition$CHECK (cleanup_phase IS NULL OR (cleanup_phase = ANY (ARRAY['delete_pending'::text, 'confirm_absent'::text])))$definition$
                ),
                (
                    'feedback_time_order',
                    'c',
                    $definition$CHECK (upload_expires_at > created_at AND upload_expires_at <= retained_until AND retained_until > created_at AND (completed_at IS NULL OR completed_at >= created_at) AND (deleted_at IS NULL OR deleted_at >= created_at) AND (object_absence_confirmed_at IS NULL OR object_absence_confirmed_at >= created_at) AND (cleanup_after IS NULL OR cleanup_after >= created_at) AND (cleanup_claimed_at IS NULL OR cleanup_claimed_at >= created_at))$definition$
                ),
                (
                    'feedback_cleanup_consistent',
                    'c',
                    $definition$CHECK ((status = ANY (ARRAY['reserved'::text, 'deleting'::text])) AND cleanup_after IS NOT NULL AND cleanup_phase IS NOT NULL AND cleanup_after >= upload_expires_at OR status = 'rejected'::text AND (cleanup_after IS NOT NULL AND cleanup_phase IS NOT NULL AND cleanup_after >= upload_expires_at OR cleanup_after IS NULL AND cleanup_phase IS NULL) OR (status = ANY (ARRAY['sent'::text, 'deleted'::text])) AND cleanup_after IS NULL AND cleanup_phase IS NULL)$definition$
                ),
                (
                    'feedback_cleanup_claim_consistent',
                    'c',
                    $definition$CHECK (cleanup_claimed_at IS NULL OR cleanup_phase IS NOT NULL OR retained_until <= cleanup_claimed_at)$definition$
                ),
                (
                    'feedback_absence_confirmation_consistent',
                    'c',
                    $definition$CHECK (object_absence_confirmed_at IS NULL OR cleanup_after IS NULL AND cleanup_phase IS NULL AND (cleanup_claimed_at IS NULL OR retained_until <= cleanup_claimed_at))$definition$
                ),
                (
                    'feedback_reports_client_app_id_subject_hash_idempotency_has_key',
                    'u',
                    $definition$UNIQUE (client_app_id, subject_hash, idempotency_hash)$definition$
                ),
                (
                    'feedback_reports_principal_idempotency_unique',
                    'u',
                    $definition$UNIQUE (client_app_id, principal_hash_version, principal_hash, idempotency_hash)$definition$
                ),
                (
                    'feedback_reports_receipt_key',
                    'u',
                    $definition$UNIQUE (receipt)$definition$
                ),
                (
                    'feedback_reports_object_key_key',
                    'u',
                    $definition$UNIQUE (object_key)$definition$
                )
        ) AS required(
            constraint_name,
            constraint_type,
            expected_definition
        )
        LEFT JOIN pg_constraint constraint_row
          ON constraint_row.conrelid = 'feedback_reports'::regclass
         AND constraint_row.conname = required.constraint_name
         AND constraint_row.contype =
                required.constraint_type::"char"
        WHERE constraint_row.oid IS NULL
           OR NOT constraint_row.convalidated
           OR btrim(
                regexp_replace(
                    pg_get_constraintdef(constraint_row.oid, true),
                    '\s+',
                    ' ',
                    'g'
                )
              ) <> required.expected_definition
    ) THEN
        RAISE EXCEPTION 'feedback report runtime constraint is missing, unvalidated, or invalid';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                (
                    'feedback_report_compatibility',
                    'noop_feedback_report_compatibility',
                    23::smallint,
                    false
                ),
                (
                    'feedback_report_retire_idempotency',
                    'noop_feedback_report_retire_idempotency',
                    11::smallint,
                    true
                )
        ) AS required(
            trigger_name,
            function_name,
            expected_type,
            requires_exact_duration
        )
        LEFT JOIN pg_trigger trigger_row
          ON trigger_row.tgrelid = 'feedback_reports'::regclass
         AND trigger_row.tgname = required.trigger_name
         AND NOT trigger_row.tgisinternal
        LEFT JOIN pg_proc function_row
          ON function_row.oid = trigger_row.tgfoid
        LEFT JOIN pg_namespace function_schema
          ON function_schema.oid = function_row.pronamespace
        WHERE trigger_row.oid IS NULL
           OR trigger_row.tgenabled NOT IN ('O', 'A')
           OR trigger_row.tgtype IS DISTINCT FROM required.expected_type
           OR trigger_row.tgconstraint IS DISTINCT FROM 0::oid
           OR trigger_row.tgnargs IS DISTINCT FROM 0
           OR trigger_row.tgattr IS DISTINCT FROM ''::int2vector
           OR trigger_row.tgqual IS NOT NULL
           OR trigger_row.tgoldtable IS NOT NULL
           OR trigger_row.tgnewtable IS NOT NULL
           OR function_schema.nspname IS DISTINCT FROM 'public'
           OR function_row.proname IS DISTINCT FROM required.function_name
           OR (
                required.requires_exact_duration
                AND (
                    position(
                        '1080 hours'
                        IN COALESCE(function_row.prosrc, '')
                    ) = 0
                    OR position(
                        '45 days'
                        IN COALESCE(function_row.prosrc, '')
                    ) > 0
                )
           )
    ) THEN
        RAISE EXCEPTION 'feedback report runtime trigger binding or shape is invalid';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                ('feedback_reports_retention_idx'),
                ('feedback_reports_status_idx'),
                ('feedback_reports_subject_quota_idx'),
                ('feedback_reports_cleanup_v2_idx'),
                ('feedback_reports_principal_quota_idx'),
                ('feedback_reports_app_quota_idx')
        ) AS required(index_name)
        LEFT JOIN pg_class index_row
          ON index_row.relname = required.index_name
         AND index_row.relnamespace = 'public'::regnamespace
        LEFT JOIN pg_index index_state
          ON index_state.indexrelid = index_row.oid
         AND index_state.indrelid = 'feedback_reports'::regclass
        LEFT JOIN pg_am access_method
          ON access_method.oid = index_row.relam
        WHERE index_state.indexrelid IS NULL
           OR NOT index_state.indisvalid
           OR NOT index_state.indisready
           OR access_method.amname <> 'btree'
    ) THEN
        RAISE EXCEPTION 'feedback report runtime index is missing or invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version = '042_feedback_idempotency_tombstones.sql'
    ) THEN
        RAISE EXCEPTION 'required feedback tombstone migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version = '044_feedback_idempotency_duration.sql'
    ) THEN
        RAISE EXCEPTION 'required feedback tombstone duration migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM noop_schema_migrations
        WHERE version = '045_ownership_account_deletion_progress.sql'
    ) THEN
        RAISE EXCEPTION 'required ownership deletion progress migration is missing';
    END IF;
    IF to_regclass(
        'public.ownership_account_deletion_target_progress'
    ) IS NULL THEN
        RAISE EXCEPTION 'ownership deletion progress table is missing';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                ('deletion_request_id', 'uuid', true),
                ('target_kind', 'text', true),
                ('current_state', 'text', true),
                ('blocker', 'text', false),
                ('progress_version', 'bigint', true),
                ('attempt_count', 'integer', true),
                ('lease_owner', 'uuid', false),
                ('lease_expires_at', 'timestamp with time zone', false),
                ('retry_after', 'timestamp with time zone', false),
                ('managed_erasure_job_id', 'uuid', false),
                ('last_error_kind', 'text', false),
                ('updated_at', 'timestamp with time zone', true),
                ('completed_at', 'timestamp with time zone', false)
        ) AS required(column_name, expected_type, expected_not_null)
        LEFT JOIN pg_attribute column_state
          ON column_state.attrelid =
                'ownership_account_deletion_target_progress'::regclass
         AND column_state.attname = required.column_name
         AND column_state.attnum > 0
         AND NOT column_state.attisdropped
        WHERE column_state.attname IS NULL
           OR column_state.attnotnull IS DISTINCT FROM
                required.expected_not_null
           OR format_type(
                column_state.atttypid,
                column_state.atttypmod
              ) <> required.expected_type
    ) THEN
        RAISE EXCEPTION 'ownership deletion progress column contract is invalid';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                ('ownership_account_deletion_target_progress_pkey', 'p'),
                ('ownership_account_deletion_progress_target_fk', 'f'),
                ('ownership_account_deletion_progress_managed_job_fk', 'f'),
                ('ownership_account_deletion_progress_state', 'c'),
                ('ownership_account_deletion_progress_blocker', 'c'),
                ('ownership_account_deletion_progress_state_blocker', 'c'),
                ('ownership_account_deletion_progress_attempts', 'c'),
                ('ownership_account_deletion_progress_version', 'c'),
                ('ownership_account_deletion_progress_lease_pair', 'c'),
                ('ownership_account_deletion_progress_retry_state', 'c'),
                ('ownership_account_deletion_progress_managed_target', 'c'),
                ('ownership_account_deletion_progress_failure_kind', 'c'),
                ('ownership_account_deletion_progress_completion_state', 'c')
        ) AS required(constraint_name, constraint_type)
        LEFT JOIN pg_constraint constraint_row
          ON constraint_row.conrelid =
                'ownership_account_deletion_target_progress'::regclass
         AND constraint_row.conname = required.constraint_name
         AND constraint_row.contype = required.constraint_type
        WHERE constraint_row.oid IS NULL
           OR NOT constraint_row.convalidated
    ) THEN
        RAISE EXCEPTION 'ownership deletion progress constraint is missing or invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_class index_row
        JOIN pg_index index_state
          ON index_state.indexrelid = index_row.oid
        JOIN pg_am access_method
          ON access_method.oid = index_row.relam
        WHERE index_state.indrelid =
                'ownership_account_deletion_target_progress'::regclass
          AND index_row.relname =
                'ownership_account_deletion_progress_due_idx'
          AND access_method.amname = 'btree'
          AND index_state.indisvalid
          AND index_state.indisready
          AND NOT index_state.indisunique
          AND index_state.indpred IS NOT NULL
          AND position(
                'current_state = ANY'
                IN pg_get_expr(
                    index_state.indpred,
                    index_state.indrelid
                )
              ) > 0
    ) THEN
        RAISE EXCEPTION 'ownership deletion progress due index is missing or invalid';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                (
                    'ownership_account_deletion_progress_guard',
                    'noop_ownership_account_deletion_progress_guard',
                    false
                ),
                (
                    'ownership_account_deletion_progress_seed',
                    'noop_ownership_account_deletion_progress_seed',
                    true
                )
        ) AS required(trigger_name, function_name, security_definer)
        LEFT JOIN pg_trigger trigger_row
          ON trigger_row.tgrelid = CASE required.trigger_name
                WHEN 'ownership_account_deletion_progress_guard'
                THEN 'ownership_account_deletion_target_progress'::regclass
                ELSE 'ownership_account_deletion_targets'::regclass
             END
         AND trigger_row.tgname = required.trigger_name
         AND NOT trigger_row.tgisinternal
        LEFT JOIN pg_proc function_row
          ON function_row.oid = trigger_row.tgfoid
         AND function_row.proname = required.function_name
        LEFT JOIN pg_namespace function_schema
          ON function_schema.oid = function_row.pronamespace
         AND function_schema.nspname = 'public'
        WHERE trigger_row.oid IS NULL
           OR trigger_row.tgenabled NOT IN ('O', 'A')
           OR function_row.oid IS NULL
           OR function_row.prosecdef IS DISTINCT FROM
                required.security_definer
    ) THEN
        RAISE EXCEPTION 'ownership deletion progress trigger binding is invalid';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_proc function_row
        JOIN pg_namespace function_schema
          ON function_schema.oid = function_row.pronamespace
        CROSS JOIN LATERAL aclexplode(
            COALESCE(
                function_row.proacl,
                acldefault('f', function_row.proowner)
            )
        ) privilege
        WHERE function_schema.nspname = 'public'
          AND function_row.proname =
                'noop_ownership_account_deletion_progress_seed'
          AND privilege.grantee = 0
          AND privilege.privilege_type = 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'ownership deletion progress seed is executable by PUBLIC';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM ownership_account_deletion_targets target
        FULL OUTER JOIN ownership_account_deletion_target_progress progress
          USING (deletion_request_id, target_kind)
        WHERE target.deletion_request_id IS NULL
           OR progress.deletion_request_id IS NULL
    ) THEN
        RAISE EXCEPTION 'ownership deletion target progress is incomplete or orphaned';
    END IF;
    IF to_regclass('public.feedback_idempotency_tombstones') IS NULL THEN
        RAISE EXCEPTION 'feedback idempotency tombstone table is missing';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                ('reserved_at', 'timestamp with time zone'),
                ('expires_at', 'timestamp with time zone')
        ) AS required(column_name, expected_type)
        LEFT JOIN pg_attribute column_state
          ON column_state.attrelid =
                'feedback_idempotency_tombstones'::regclass
         AND column_state.attname = required.column_name
         AND column_state.attnum > 0
         AND NOT column_state.attisdropped
        WHERE column_state.attname IS NULL
           OR NOT column_state.attnotnull
           OR format_type(
                column_state.atttypid,
                column_state.atttypmod
              ) <> required.expected_type
    ) THEN
        RAISE EXCEPTION 'feedback tombstone lifecycle timestamp is missing, nullable, or not timestamptz';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES
                (
                    'feedback_tombstone_client_app_id_bounded',
                    $definition$CHECK (char_length(client_app_id) >= 8 AND char_length(client_app_id) <= 256)$definition$
                ),
                (
                    'feedback_tombstone_principal_version_supported',
                    $definition$CHECK (principal_hash_version = ANY (ARRAY[0, 1]))$definition$
                ),
                (
                    'feedback_tombstone_principal_hash_format',
                    $definition$CHECK (principal_hash ~ '^[0-9a-f]{64}$'::text)$definition$
                ),
                (
                    'feedback_tombstone_idempotency_hash_format',
                    $definition$CHECK (idempotency_hash ~ '^[0-9a-f]{64}$'::text)$definition$
                ),
                (
                    'feedback_tombstone_time_order',
                    $definition$CHECK (expires_at = (reserved_at + '1080:00:00'::interval) AND expires_at > reserved_at)$definition$
                )
        ) AS required(constraint_name, expected_definition)
        LEFT JOIN pg_constraint constraint_row
          ON constraint_row.conrelid =
                'feedback_idempotency_tombstones'::regclass
         AND constraint_row.conname = required.constraint_name
         AND constraint_row.contype = 'c'
        WHERE constraint_row.oid IS NULL
           OR NOT constraint_row.convalidated
           OR btrim(
                regexp_replace(
                    pg_get_constraintdef(constraint_row.oid, true),
                    '\s+',
                    ' ',
                    'g'
                )
              ) <> required.expected_definition
    ) THEN
        RAISE EXCEPTION 'feedback tombstone check constraint is missing, unvalidated, or invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger trigger_row
        JOIN pg_proc function_row
          ON function_row.oid = trigger_row.tgfoid
        JOIN pg_namespace function_schema
          ON function_schema.oid = function_row.pronamespace
        WHERE trigger_row.tgrelid =
                'feedback_idempotency_tombstones'::regclass
          AND trigger_row.tgname =
                'feedback_tombstone_normalize_expiry'
          AND NOT trigger_row.tgisinternal
          AND trigger_row.tgenabled IN ('O', 'A')
          AND trigger_row.tgtype = 23
          AND trigger_row.tgconstraint = 0::oid
          AND trigger_row.tgnargs = 0
          AND trigger_row.tgqual IS NULL
          AND trigger_row.tgoldtable IS NULL
          AND trigger_row.tgnewtable IS NULL
          AND ARRAY(
                SELECT attribute.attname::text
                FROM unnest(
                    trigger_row.tgattr::smallint[]
                ) WITH ORDINALITY AS selected(attnum, position)
                JOIN pg_attribute attribute
                  ON attribute.attrelid = trigger_row.tgrelid
                 AND attribute.attnum = selected.attnum
                ORDER BY selected.position
              ) = ARRAY['reserved_at', 'expires_at']
          AND function_schema.nspname = 'public'
          AND function_row.proname =
                'noop_feedback_tombstone_normalize_expiry'
          AND position('1080 hours' IN function_row.prosrc) > 0
          AND position('45 days' IN function_row.prosrc) = 0
    ) THEN
        RAISE EXCEPTION 'feedback tombstone duration normalization trigger is missing or invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint constraint_row
        WHERE constraint_row.conrelid =
                'feedback_idempotency_tombstones'::regclass
          AND constraint_row.conname =
                'feedback_idempotency_tombstones_pkey'
          AND constraint_row.contype = 'p'
          AND constraint_row.convalidated
          AND pg_get_constraintdef(constraint_row.oid) =
                'PRIMARY KEY (client_app_id, principal_hash_version, principal_hash, idempotency_hash)'
    ) THEN
        RAISE EXCEPTION 'feedback tombstone primary key is missing or invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_class index_row
        JOIN pg_index index_state
          ON index_state.indexrelid = index_row.oid
        JOIN pg_am access_method
          ON access_method.oid = index_row.relam
        WHERE index_state.indrelid =
                'feedback_idempotency_tombstones'::regclass
          AND index_row.relname =
                'feedback_idempotency_tombstones_expiry_idx'
          AND access_method.amname = 'btree'
          AND index_state.indisvalid
          AND index_state.indisready
          AND NOT index_state.indisunique
          AND index_state.indpred IS NULL
          AND index_state.indexprs IS NULL
          AND index_state.indnkeyatts = 4
          AND index_state.indnatts = 4
          AND position(
                '(expires_at, client_app_id, principal_hash, idempotency_hash)'
                IN pg_get_indexdef(index_row.oid)
              ) > 0
    ) THEN
        RAISE EXCEPTION 'feedback tombstone expiry index is missing or invalid';
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
          AND NOT attnotnull
          AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION 'managed Safety quota writer compatibility is missing';
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
