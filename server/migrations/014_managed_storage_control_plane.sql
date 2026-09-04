-- Optional NOOP+ managed-storage control plane. Core NOOP and the existing
-- self-hosted row-sync path do not depend on these tables. Identity-provider
-- subjects are stored only as digests; phone numbers and email addresses do
-- not belong in this database or in object names.

CREATE TABLE IF NOT EXISTS managed_accounts (
    account_id uuid PRIMARY KEY,
    storage_namespace uuid NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'active',
    home_region text NOT NULL,
    residency_policy_version text NOT NULL,
    auth_valid_after timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    suspended_at timestamptz,
    erasure_requested_at timestamptz,
    erased_at timestamptz,
    CONSTRAINT managed_account_scope_unique
        UNIQUE (account_id, storage_namespace),
    CONSTRAINT managed_account_status
        CHECK (
            status IN (
                'active',
                'suspended',
                'erasure_pending',
                'erased'
            )
        ),
    CONSTRAINT managed_account_region
        CHECK (home_region ~ '^[a-z][a-z0-9-]{1,31}$'),
    CONSTRAINT managed_account_residency_version
        CHECK (
            residency_policy_version
            ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
        ),
    CONSTRAINT managed_account_updated_order
        CHECK (updated_at >= created_at),
    CONSTRAINT managed_account_suspension_order
        CHECK (suspended_at IS NULL OR suspended_at >= created_at),
    CONSTRAINT managed_account_erasure_request_order
        CHECK (
            erasure_requested_at IS NULL
            OR erasure_requested_at >= created_at
        ),
    CONSTRAINT managed_account_erased_order
        CHECK (
            erased_at IS NULL
            OR (
                erasure_requested_at IS NOT NULL
                AND erased_at >= erasure_requested_at
            )
        ),
    CONSTRAINT managed_account_status_times
        CHECK (
            (status <> 'erasure_pending' OR erasure_requested_at IS NOT NULL)
            AND (status <> 'erased' OR erased_at IS NOT NULL)
        )
);

CREATE INDEX IF NOT EXISTS managed_accounts_status_idx
    ON managed_accounts (status, updated_at);

CREATE TABLE IF NOT EXISTS managed_external_identities (
    identity_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    issuer text NOT NULL,
    provider_tenant text NOT NULL DEFAULT '',
    subject_hash char(64) NOT NULL,
    status text NOT NULL DEFAULT 'active',
    claims_version bigint NOT NULL DEFAULT 1,
    verified_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_external_identity_scope_unique
        UNIQUE (account_id, identity_id),
    CONSTRAINT managed_external_identity_subject_unique
        UNIQUE (issuer, provider_tenant, subject_hash),
    CONSTRAINT managed_external_identity_issuer
        CHECK (
            length(issuer) BETWEEN 1 AND 512
            AND issuer !~ '[[:space:]]'
        ),
    CONSTRAINT managed_external_identity_tenant
        CHECK (
            provider_tenant = ''
            OR provider_tenant ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT managed_external_identity_subject_digest
        CHECK (subject_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_external_identity_status
        CHECK (status IN ('active', 'revoked')),
    CONSTRAINT managed_external_identity_claims_version
        CHECK (claims_version > 0),
    CONSTRAINT managed_external_identity_seen_order
        CHECK (last_seen_at >= verified_at),
    CONSTRAINT managed_external_identity_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= verified_at),
    CONSTRAINT managed_external_identity_status_time
        CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS managed_external_identities_account_idx
    ON managed_external_identities (account_id, status);

CREATE TABLE IF NOT EXISTS managed_account_installations (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    installation_id text NOT NULL UNIQUE
        REFERENCES installation_credentials(installation_id) ON DELETE RESTRICT,
    platform text NOT NULL,
    status text NOT NULL DEFAULT 'active',
    device_key_fingerprint char(64),
    attestation_state text NOT NULL DEFAULT 'not_evaluated',
    token_valid_after timestamptz NOT NULL,
    registered_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    PRIMARY KEY (account_id, installation_id),
    CONSTRAINT managed_account_installation_platform
        CHECK (platform IN ('ios', 'android', 'macos', 'other')),
    CONSTRAINT managed_account_installation_status
        CHECK (status IN ('active', 'limited', 'revoked')),
    CONSTRAINT managed_account_installation_key_digest
        CHECK (
            device_key_fingerprint IS NULL
            OR device_key_fingerprint ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_account_installation_attestation
        CHECK (
            attestation_state IN (
                'not_evaluated',
                'accepted',
                'rejected',
                'unavailable'
            )
        ),
    CONSTRAINT managed_account_installation_seen_order
        CHECK (last_seen_at >= registered_at),
    CONSTRAINT managed_account_installation_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= registered_at),
    CONSTRAINT managed_account_installation_status_time
        CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS managed_account_installations_status_idx
    ON managed_account_installations (account_id, status, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS managed_policy_documents (
    policy_kind text NOT NULL,
    policy_version text NOT NULL,
    document_sha256 char(64) NOT NULL,
    document_uri text NOT NULL,
    effective_at timestamptz NOT NULL,
    retired_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (policy_kind, policy_version),
    CONSTRAINT managed_policy_kind
        CHECK (policy_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_policy_version
        CHECK (policy_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
    CONSTRAINT managed_policy_digest
        CHECK (document_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_policy_uri
        CHECK (
            length(document_uri) BETWEEN 1 AND 1024
            AND document_uri !~ '[[:space:]]'
        ),
    CONSTRAINT managed_policy_retirement_order
        CHECK (retired_at IS NULL OR retired_at > effective_at)
);

CREATE TABLE IF NOT EXISTS managed_consent_events (
    consent_event_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    policy_kind text NOT NULL,
    policy_version text NOT NULL,
    decision text NOT NULL,
    data_classes text[] NOT NULL,
    installation_id text,
    request_id uuid NOT NULL,
    locale text,
    occurred_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_consent_policy_fk
        FOREIGN KEY (policy_kind, policy_version)
        REFERENCES managed_policy_documents(policy_kind, policy_version)
        ON DELETE RESTRICT,
    CONSTRAINT managed_consent_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_consent_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT managed_consent_decision
        CHECK (decision IN ('granted', 'withdrawn')),
    CONSTRAINT managed_consent_data_classes
        CHECK (
            cardinality(data_classes) BETWEEN 1 AND 32
            AND array_position(data_classes, NULL) IS NULL
        ),
    CONSTRAINT managed_consent_locale
        CHECK (
            locale IS NULL
            OR locale ~ '^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$'
        ),
    CONSTRAINT managed_consent_recorded_order
        CHECK (recorded_at >= occurred_at)
);

CREATE INDEX IF NOT EXISTS managed_consent_events_latest_idx
    ON managed_consent_events (
        account_id,
        policy_kind,
        occurred_at DESC,
        recorded_at DESC
    );

CREATE TABLE IF NOT EXISTS managed_storage_plans (
    plan_code text NOT NULL,
    revision integer NOT NULL,
    status text NOT NULL DEFAULT 'draft',
    display_tier text NOT NULL,
    max_total_bytes bigint,
    max_inflight_bytes bigint NOT NULL,
    max_chunk_bytes bigint NOT NULL,
    max_uncompressed_chunk_bytes bigint NOT NULL,
    max_installations integer NOT NULL,
    effective_at timestamptz,
    retired_at timestamptz,
    configuration jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (plan_code, revision),
    CONSTRAINT managed_storage_plan_code
        CHECK (plan_code ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_storage_plan_revision
        CHECK (revision > 0),
    CONSTRAINT managed_storage_plan_status
        CHECK (status IN ('draft', 'active', 'retired')),
    CONSTRAINT managed_storage_plan_tier
        CHECK (display_tier IN ('noop', 'noop_plus')),
    CONSTRAINT managed_storage_plan_total_bytes
        CHECK (max_total_bytes IS NULL OR max_total_bytes > 0),
    CONSTRAINT managed_storage_plan_inflight_bytes
        CHECK (max_inflight_bytes > 0),
    CONSTRAINT managed_storage_plan_chunk_bytes
        CHECK (
            max_chunk_bytes > 0
            AND max_chunk_bytes <= max_inflight_bytes
            AND (
                max_total_bytes IS NULL
                OR max_chunk_bytes <= max_total_bytes
            )
        ),
    CONSTRAINT managed_storage_plan_uncompressed_chunk_bytes
        CHECK (
            max_uncompressed_chunk_bytes >= max_chunk_bytes
            AND max_uncompressed_chunk_bytes <= 1073741824
        ),
    CONSTRAINT managed_storage_plan_installations
        CHECK (max_installations BETWEEN 1 AND 100),
    CONSTRAINT managed_storage_plan_configuration
        CHECK (jsonb_typeof(configuration) = 'object'),
    CONSTRAINT managed_storage_plan_effective_state
        CHECK (status = 'draft' OR effective_at IS NOT NULL),
    CONSTRAINT managed_storage_plan_retirement_order
        CHECK (
            retired_at IS NULL
            OR (effective_at IS NOT NULL AND retired_at > effective_at)
        ),
    CONSTRAINT managed_storage_plan_retired_state
        CHECK (status <> 'retired' OR retired_at IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS managed_plan_data_rules (
    plan_code text NOT NULL,
    plan_revision integer NOT NULL,
    data_class text NOT NULL,
    cloud_retention_days integer,
    summary_retention_days integer,
    recommended_local_raw_days integer NOT NULL,
    maximum_daily_bytes bigint,
    storage_class text NOT NULL,
    server_processing_allowed boolean NOT NULL DEFAULT false,
    configuration jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (plan_code, plan_revision, data_class),
    CONSTRAINT managed_plan_data_rule_plan_fk
        FOREIGN KEY (plan_code, plan_revision)
        REFERENCES managed_storage_plans(plan_code, revision)
        ON DELETE RESTRICT,
    CONSTRAINT managed_plan_data_rule_class
        CHECK (data_class ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_plan_data_rule_cloud_retention
        CHECK (
            cloud_retention_days IS NULL
            OR cloud_retention_days BETWEEN 1 AND 36500
        ),
    CONSTRAINT managed_plan_data_rule_summary_retention
        CHECK (
            summary_retention_days IS NULL
            OR summary_retention_days BETWEEN 1 AND 36500
        ),
    CONSTRAINT managed_plan_data_rule_local_retention
        CHECK (recommended_local_raw_days BETWEEN 1 AND 3650),
    CONSTRAINT managed_plan_data_rule_daily_bytes
        CHECK (maximum_daily_bytes IS NULL OR maximum_daily_bytes > 0),
    CONSTRAINT managed_plan_data_rule_storage_class
        CHECK (
            storage_class IN (
                'standard',
                'nearline',
                'coldline',
                'archive'
            )
        ),
    CONSTRAINT managed_plan_data_rule_configuration
        CHECK (jsonb_typeof(configuration) = 'object')
);

CREATE TABLE IF NOT EXISTS managed_subscriptions (
    subscription_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    plan_code text NOT NULL,
    plan_revision integer NOT NULL,
    status text NOT NULL,
    billing_provider text NOT NULL,
    provider_customer_hash char(64),
    provider_subscription_hash char(64),
    period_started_at timestamptz NOT NULL,
    period_ends_at timestamptz,
    grace_ends_at timestamptz,
    canceled_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_subscription_scope_unique
        UNIQUE (account_id, subscription_id),
    CONSTRAINT managed_subscription_plan_fk
        FOREIGN KEY (plan_code, plan_revision)
        REFERENCES managed_storage_plans(plan_code, revision)
        ON DELETE RESTRICT,
    CONSTRAINT managed_subscription_status
        CHECK (
            status IN (
                'trial',
                'active',
                'grace',
                'paused',
                'canceled',
                'expired'
            )
        ),
    CONSTRAINT managed_subscription_provider
        CHECK (
            billing_provider IN (
                'manual',
                'apple',
                'google',
                'stripe',
                'other'
            )
        ),
    CONSTRAINT managed_subscription_customer_digest
        CHECK (
            provider_customer_hash IS NULL
            OR provider_customer_hash ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_subscription_reference_digest
        CHECK (
            provider_subscription_hash IS NULL
            OR provider_subscription_hash ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_subscription_period_order
        CHECK (
            period_ends_at IS NULL
            OR period_ends_at > period_started_at
        ),
    CONSTRAINT managed_subscription_grace_order
        CHECK (
            grace_ends_at IS NULL
            OR (
                period_ends_at IS NOT NULL
                AND grace_ends_at >= period_ends_at
            )
        ),
    CONSTRAINT managed_subscription_cancel_order
        CHECK (canceled_at IS NULL OR canceled_at >= period_started_at),
    CONSTRAINT managed_subscription_updated_order
        CHECK (updated_at >= created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_subscriptions_one_current_idx
    ON managed_subscriptions (account_id)
    WHERE status IN ('trial', 'active', 'grace', 'paused');

CREATE INDEX IF NOT EXISTS managed_subscriptions_provider_idx
    ON managed_subscriptions (
        billing_provider,
        provider_subscription_hash
    )
    WHERE provider_subscription_hash IS NOT NULL;

CREATE TABLE IF NOT EXISTS managed_subscription_events (
    subscription_event_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    provider_event_hash char(64) NOT NULL,
    event_kind text NOT NULL,
    effective_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    payload_sha256 char(64) NOT NULL,
    CONSTRAINT managed_subscription_event_subscription_fk
        FOREIGN KEY (account_id, subscription_id)
        REFERENCES managed_subscriptions(account_id, subscription_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_subscription_event_provider_unique
        UNIQUE (provider_event_hash),
    CONSTRAINT managed_subscription_event_provider_digest
        CHECK (provider_event_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_subscription_event_kind
        CHECK (event_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_subscription_event_payload_digest
        CHECK (payload_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_subscription_event_received_window
        CHECK (
            effective_at
            BETWEEN received_at - interval '10 years'
                AND received_at + interval '10 years'
        )
);

CREATE TABLE IF NOT EXISTS managed_quota_overrides (
    quota_override_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    data_class text NOT NULL,
    maximum_bytes bigint NOT NULL,
    maximum_daily_bytes bigint,
    reason_code text NOT NULL,
    effective_at timestamptz NOT NULL,
    expires_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_quota_override_class
        CHECK (data_class ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_quota_override_bytes
        CHECK (maximum_bytes > 0),
    CONSTRAINT managed_quota_override_daily
        CHECK (
            maximum_daily_bytes IS NULL
            OR maximum_daily_bytes > 0
        ),
    CONSTRAINT managed_quota_override_reason
        CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_quota_override_expiry
        CHECK (expires_at IS NULL OR expires_at > effective_at),
    CONSTRAINT managed_quota_override_revocation
        CHECK (revoked_at IS NULL OR revoked_at >= effective_at)
);

CREATE INDEX IF NOT EXISTS managed_quota_overrides_active_idx
    ON managed_quota_overrides (account_id, data_class, effective_at DESC)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS managed_retention_policy_snapshots (
    retention_snapshot_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    subscription_id uuid NOT NULL,
    plan_code text NOT NULL,
    plan_revision integer NOT NULL,
    data_class text NOT NULL,
    cloud_retention_days integer,
    summary_retention_days integer,
    local_raw_days integer NOT NULL,
    storage_class text NOT NULL,
    policy_sha256 char(64) NOT NULL,
    effective_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_retention_snapshot_scope_unique
        UNIQUE (account_id, retention_snapshot_id),
    CONSTRAINT managed_retention_snapshot_subscription_fk
        FOREIGN KEY (account_id, subscription_id)
        REFERENCES managed_subscriptions(account_id, subscription_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_retention_snapshot_rule_fk
        FOREIGN KEY (plan_code, plan_revision, data_class)
        REFERENCES managed_plan_data_rules(
            plan_code,
            plan_revision,
            data_class
        )
        ON DELETE RESTRICT,
    CONSTRAINT managed_retention_snapshot_cloud
        CHECK (
            cloud_retention_days IS NULL
            OR cloud_retention_days BETWEEN 1 AND 36500
        ),
    CONSTRAINT managed_retention_snapshot_summary
        CHECK (
            summary_retention_days IS NULL
            OR summary_retention_days BETWEEN 1 AND 36500
        ),
    CONSTRAINT managed_retention_snapshot_local
        CHECK (local_raw_days BETWEEN 1 AND 3650),
    CONSTRAINT managed_retention_snapshot_storage_class
        CHECK (
            storage_class IN (
                'standard',
                'nearline',
                'coldline',
                'archive'
            )
        ),
    CONSTRAINT managed_retention_snapshot_digest
        CHECK (policy_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE INDEX IF NOT EXISTS managed_retention_snapshots_account_idx
    ON managed_retention_policy_snapshots (
        account_id,
        data_class,
        effective_at DESC
    );

CREATE TABLE IF NOT EXISTS managed_storage_usage (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    data_class text NOT NULL,
    committed_bytes bigint NOT NULL DEFAULT 0,
    reserved_bytes bigint NOT NULL DEFAULT 0,
    object_count bigint NOT NULL DEFAULT 0,
    revision bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, data_class),
    CONSTRAINT managed_storage_usage_class
        CHECK (data_class ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_storage_usage_committed
        CHECK (committed_bytes >= 0),
    CONSTRAINT managed_storage_usage_reserved
        CHECK (reserved_bytes >= 0),
    CONSTRAINT managed_storage_usage_objects
        CHECK (object_count >= 0),
    CONSTRAINT managed_storage_usage_revision
        CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS managed_storage_usage_ledger (
    usage_event_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    data_class text NOT NULL,
    chunk_id uuid,
    idempotency_hash char(64) NOT NULL,
    reason text NOT NULL,
    committed_bytes_delta bigint NOT NULL DEFAULT 0,
    reserved_bytes_delta bigint NOT NULL DEFAULT 0,
    object_count_delta bigint NOT NULL DEFAULT 0,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    purge_after timestamptz NOT NULL,
    CONSTRAINT managed_usage_ledger_usage_fk
        FOREIGN KEY (account_id, data_class)
        REFERENCES managed_storage_usage(account_id, data_class)
        ON DELETE RESTRICT,
    CONSTRAINT managed_usage_ledger_idempotency_unique
        UNIQUE (account_id, idempotency_hash),
    CONSTRAINT managed_usage_ledger_idempotency_digest
        CHECK (idempotency_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_usage_ledger_reason
        CHECK (
            reason IN (
                'reserve',
                'release_reservation',
                'commit_upload',
                'delete_object',
                'reconcile'
            )
        ),
    CONSTRAINT managed_usage_ledger_nonzero
        CHECK (
            committed_bytes_delta <> 0
            OR reserved_bytes_delta <> 0
            OR object_count_delta <> 0
        ),
    CONSTRAINT managed_usage_ledger_purge_order
        CHECK (purge_after > occurred_at)
);

CREATE INDEX IF NOT EXISTS managed_usage_ledger_account_time_idx
    ON managed_storage_usage_ledger (account_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS managed_usage_ledger_purge_idx
    ON managed_storage_usage_ledger (purge_after);

CREATE TABLE IF NOT EXISTS managed_worker_leases (
    lease_name text PRIMARY KEY,
    owner_id uuid NOT NULL,
    acquired_at timestamptz NOT NULL,
    heartbeat_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    CONSTRAINT managed_worker_lease_name
        CHECK (lease_name ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_worker_lease_heartbeat_order
        CHECK (heartbeat_at >= acquired_at),
    CONSTRAINT managed_worker_lease_expiry_order
        CHECK (expires_at > heartbeat_at)
);

CREATE INDEX IF NOT EXISTS managed_worker_leases_expiry_idx
    ON managed_worker_leases (expires_at);

CREATE TABLE IF NOT EXISTS managed_sources (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    source_id uuid NOT NULL,
    installation_id text NOT NULL,
    source_kind text NOT NULL,
    platform text NOT NULL,
    logical_source_hash char(64) NOT NULL,
    status text NOT NULL DEFAULT 'active',
    first_seen_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    retired_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (account_id, source_id),
    CONSTRAINT managed_source_id_unique UNIQUE (source_id),
    CONSTRAINT managed_source_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_source_kind
        CHECK (source_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_source_platform
        CHECK (platform IN ('ios', 'android', 'macos', 'import', 'other')),
    CONSTRAINT managed_source_logical_digest
        CHECK (logical_source_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_source_status
        CHECK (status IN ('active', 'retired')),
    CONSTRAINT managed_source_seen_order
        CHECK (last_seen_at >= first_seen_at),
    CONSTRAINT managed_source_retired_order
        CHECK (retired_at IS NULL OR retired_at >= first_seen_at),
    CONSTRAINT managed_source_status_time
        CHECK (status <> 'retired' OR retired_at IS NOT NULL),
    CONSTRAINT managed_source_metadata
        CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS managed_sources_installation_idx
    ON managed_sources (account_id, installation_id, status);

CREATE TABLE IF NOT EXISTS managed_client_keys (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    client_key_id uuid NOT NULL,
    installation_id text,
    purpose text NOT NULL,
    algorithm text NOT NULL,
    public_key bytea,
    key_fingerprint char(64) NOT NULL,
    recovery_method text NOT NULL,
    hardware_backed boolean,
    created_at timestamptz NOT NULL DEFAULT now(),
    rotated_at timestamptz,
    revoked_at timestamptz,
    PRIMARY KEY (account_id, client_key_id),
    CONSTRAINT managed_client_key_id_unique UNIQUE (client_key_id),
    CONSTRAINT managed_client_key_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_client_key_purpose
        CHECK (purpose IN ('backup', 'sync', 'recovery')),
    CONSTRAINT managed_client_key_algorithm
        CHECK (algorithm ~ '^[A-Za-z0-9][A-Za-z0-9._+-]{1,63}$'),
    CONSTRAINT managed_client_key_public_size
        CHECK (
            public_key IS NULL
            OR octet_length(public_key) BETWEEN 16 AND 8192
        ),
    CONSTRAINT managed_client_key_digest
        CHECK (key_fingerprint ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_client_key_recovery
        CHECK (
            recovery_method IN (
                'none',
                'device_transfer',
                'recovery_key',
                'platform_escrow'
            )
        ),
    CONSTRAINT managed_client_key_rotation_order
        CHECK (rotated_at IS NULL OR rotated_at >= created_at),
    CONSTRAINT managed_client_key_revocation_order
        CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE TABLE IF NOT EXISTS managed_chunks (
    chunk_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    storage_namespace uuid NOT NULL,
    source_id uuid NOT NULL,
    installation_id text NOT NULL,
    retention_snapshot_id uuid NOT NULL,
    client_key_id uuid,
    data_class text NOT NULL,
    schema_version integer NOT NULL,
    idempotency_key uuid NOT NULL,
    content_mode text NOT NULL,
    state text NOT NULL DEFAULT 'reserved',
    event_start timestamptz NOT NULL,
    event_end timestamptz NOT NULL,
    compression text NOT NULL,
    content_type text NOT NULL,
    expected_sha256 char(64) NOT NULL,
    expected_compressed_bytes bigint NOT NULL,
    expected_uncompressed_bytes bigint NOT NULL,
    object_key text GENERATED ALWAYS AS (
        'v1/' || storage_namespace::text || '/' || chunk_id::text
    ) STORED,
    object_generation bigint,
    object_metageneration bigint,
    object_crc32c text,
    verified_sha256 char(64),
    actual_compressed_bytes bigint,
    actual_uncompressed_bytes bigint,
    sample_count bigint,
    expires_at timestamptz,
    reserved_at timestamptz NOT NULL DEFAULT now(),
    reservation_expires_at timestamptz NOT NULL
        DEFAULT (now() + interval '24 hours'),
    uploaded_at timestamptz,
    validated_at timestamptz,
    available_at timestamptz,
    delete_requested_at timestamptz,
    deleted_at timestamptz,
    CONSTRAINT managed_chunk_scope_unique
        UNIQUE (account_id, chunk_id),
    CONSTRAINT managed_chunk_idempotency_unique
        UNIQUE (account_id, idempotency_key),
    CONSTRAINT managed_chunk_object_key_unique
        UNIQUE (object_key),
    CONSTRAINT managed_chunk_account_fk
        FOREIGN KEY (account_id, storage_namespace)
        REFERENCES managed_accounts(account_id, storage_namespace)
        ON DELETE RESTRICT,
    CONSTRAINT managed_chunk_source_fk
        FOREIGN KEY (account_id, source_id)
        REFERENCES managed_sources(account_id, source_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_chunk_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_chunk_retention_fk
        FOREIGN KEY (account_id, retention_snapshot_id)
        REFERENCES managed_retention_policy_snapshots(
            account_id,
            retention_snapshot_id
        )
        ON DELETE RESTRICT,
    CONSTRAINT managed_chunk_client_key_fk
        FOREIGN KEY (account_id, client_key_id)
        REFERENCES managed_client_keys(account_id, client_key_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_chunk_data_class
        CHECK (data_class ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_chunk_schema_version
        CHECK (schema_version BETWEEN 1 AND 10000),
    CONSTRAINT managed_chunk_content_mode
        CHECK (content_mode IN ('server_readable', 'client_encrypted')),
    CONSTRAINT managed_chunk_key_mode
        CHECK (
            (content_mode = 'server_readable' AND client_key_id IS NULL)
            OR (
                content_mode = 'client_encrypted'
                AND client_key_id IS NOT NULL
            )
        ),
    CONSTRAINT managed_chunk_state
        CHECK (
            state IN (
                'reserved',
                'uploading',
                'uploaded',
                'validating',
                'available',
                'quarantined',
                'delete_pending',
                'deleted'
            )
        ),
    CONSTRAINT managed_chunk_event_order
        CHECK (event_end >= event_start),
    CONSTRAINT managed_chunk_event_window
        CHECK (event_end - event_start <= interval '7 days'),
    CONSTRAINT managed_chunk_compression
        CHECK (compression IN ('zstd', 'gzip', 'none')),
    CONSTRAINT managed_chunk_content_type
        CHECK (
            content_type IN (
                'application/vnd.noop.chunk+protobuf',
                'application/vnd.noop.chunk+cbor',
                'application/vnd.noop.chunk+json',
                'application/vnd.noop.backup'
            )
        ),
    CONSTRAINT managed_chunk_expected_digest
        CHECK (expected_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_chunk_expected_compressed_size
        CHECK (expected_compressed_bytes > 0),
    CONSTRAINT managed_chunk_expected_uncompressed_size
        CHECK (expected_uncompressed_bytes > 0),
    CONSTRAINT managed_chunk_object_generation
        CHECK (object_generation IS NULL OR object_generation > 0),
    CONSTRAINT managed_chunk_object_metageneration
        CHECK (object_metageneration IS NULL OR object_metageneration > 0),
    CONSTRAINT managed_chunk_crc32c
        CHECK (
            object_crc32c IS NULL
            OR object_crc32c ~ '^[A-Za-z0-9+/]{6}==$'
        ),
    CONSTRAINT managed_chunk_verified_digest
        CHECK (
            verified_sha256 IS NULL
            OR verified_sha256 ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_chunk_actual_compressed_size
        CHECK (
            actual_compressed_bytes IS NULL
            OR actual_compressed_bytes > 0
        ),
    CONSTRAINT managed_chunk_actual_uncompressed_size
        CHECK (
            actual_uncompressed_bytes IS NULL
            OR actual_uncompressed_bytes > 0
        ),
    CONSTRAINT managed_chunk_sample_count
        CHECK (sample_count IS NULL OR sample_count >= 0),
    CONSTRAINT managed_chunk_expiry_order
        CHECK (expires_at IS NULL OR expires_at > reserved_at),
    CONSTRAINT managed_chunk_reservation_expiry_order
        CHECK (reservation_expires_at > reserved_at),
    CONSTRAINT managed_chunk_upload_order
        CHECK (uploaded_at IS NULL OR uploaded_at >= reserved_at),
    CONSTRAINT managed_chunk_validation_order
        CHECK (
            validated_at IS NULL
            OR (uploaded_at IS NOT NULL AND validated_at >= uploaded_at)
        ),
    CONSTRAINT managed_chunk_available_order
        CHECK (
            available_at IS NULL
            OR (validated_at IS NOT NULL AND available_at >= validated_at)
        ),
    CONSTRAINT managed_chunk_delete_request_order
        CHECK (
            delete_requested_at IS NULL
            OR delete_requested_at >= reserved_at
        ),
    CONSTRAINT managed_chunk_deleted_order
        CHECK (
            deleted_at IS NULL
            OR (
                delete_requested_at IS NOT NULL
                AND deleted_at >= delete_requested_at
            )
        ),
    CONSTRAINT managed_chunk_uploaded_fields
        CHECK (
            state IN ('reserved', 'uploading')
            OR (
                object_generation IS NOT NULL
                AND object_metageneration IS NOT NULL
                AND object_crc32c IS NOT NULL
                AND actual_compressed_bytes IS NOT NULL
                AND uploaded_at IS NOT NULL
            )
            OR (
                state IN ('delete_pending', 'deleted')
                AND uploaded_at IS NULL
                AND object_generation IS NULL
                AND object_metageneration IS NULL
                AND object_crc32c IS NULL
                AND actual_compressed_bytes IS NULL
            )
        ),
    CONSTRAINT managed_chunk_available_fields
        CHECK (
            state <> 'available'
            OR (
                verified_sha256 = expected_sha256
                AND validated_at IS NOT NULL
                AND (
                    (
                        content_mode = 'server_readable'
                        AND actual_uncompressed_bytes IS NOT NULL
                        AND sample_count IS NOT NULL
                    )
                    OR content_mode = 'client_encrypted'
                )
            )
        ),
    CONSTRAINT managed_chunk_deleted_time
        CHECK (state <> 'deleted' OR deleted_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS managed_chunks_account_time_idx
    ON managed_chunks (account_id, event_start DESC, chunk_id);

CREATE INDEX IF NOT EXISTS managed_chunks_processing_idx
    ON managed_chunks (state, uploaded_at, chunk_id)
    WHERE state IN ('uploaded', 'validating', 'quarantined');

CREATE INDEX IF NOT EXISTS managed_chunks_reservation_expiry_idx
    ON managed_chunks (reservation_expires_at, chunk_id)
    WHERE state IN ('reserved', 'uploading');

CREATE INDEX IF NOT EXISTS managed_chunks_retention_idx
    ON managed_chunks (expires_at, chunk_id)
    WHERE state IN (
        'uploaded',
        'validating',
        'available',
        'quarantined'
    ) AND expires_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS managed_chunks_source_idx
    ON managed_chunks (account_id, source_id, event_start DESC);

ALTER TABLE managed_storage_usage_ledger
    ADD CONSTRAINT managed_usage_ledger_chunk_fk
    FOREIGN KEY (account_id, chunk_id)
    REFERENCES managed_chunks(account_id, chunk_id)
    ON DELETE RESTRICT;

CREATE TABLE IF NOT EXISTS managed_chunk_streams (
    account_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    stream_key text NOT NULL,
    sample_count bigint NOT NULL,
    first_event_at timestamptz,
    last_event_at timestamptz,
    encoded_bytes bigint NOT NULL,
    schema_revision integer NOT NULL,
    PRIMARY KEY (account_id, chunk_id, stream_key),
    CONSTRAINT managed_chunk_stream_chunk_fk
        FOREIGN KEY (account_id, chunk_id)
        REFERENCES managed_chunks(account_id, chunk_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_chunk_stream_key
        CHECK (stream_key ~ '^[a-z][a-z0-9_]{0,63}$'),
    CONSTRAINT managed_chunk_stream_samples
        CHECK (sample_count >= 0),
    CONSTRAINT managed_chunk_stream_event_pair
        CHECK (
            (first_event_at IS NULL AND last_event_at IS NULL)
            OR (
                first_event_at IS NOT NULL
                AND last_event_at IS NOT NULL
                AND last_event_at >= first_event_at
            )
        ),
    CONSTRAINT managed_chunk_stream_bytes
        CHECK (encoded_bytes >= 0),
    CONSTRAINT managed_chunk_stream_schema
        CHECK (schema_revision BETWEEN 1 AND 10000)
);

CREATE TABLE IF NOT EXISTS managed_chunk_key_envelopes (
    account_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    recipient_key_id uuid NOT NULL,
    envelope_algorithm text NOT NULL,
    encrypted_data_key bytea NOT NULL,
    envelope_sha256 char(64) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, chunk_id, recipient_key_id),
    CONSTRAINT managed_chunk_envelope_chunk_fk
        FOREIGN KEY (account_id, chunk_id)
        REFERENCES managed_chunks(account_id, chunk_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_chunk_envelope_recipient_fk
        FOREIGN KEY (account_id, recipient_key_id)
        REFERENCES managed_client_keys(account_id, client_key_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_chunk_envelope_algorithm
        CHECK (
            envelope_algorithm
            ~ '^[A-Za-z0-9][A-Za-z0-9._+-]{1,63}$'
        ),
    CONSTRAINT managed_chunk_envelope_ciphertext
        CHECK (octet_length(encrypted_data_key) BETWEEN 32 AND 16384),
    CONSTRAINT managed_chunk_envelope_digest
        CHECK (envelope_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE TABLE IF NOT EXISTS managed_upload_grants (
    upload_grant_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    installation_id text NOT NULL,
    request_id uuid NOT NULL,
    capability_hash char(64) NOT NULL UNIQUE,
    expected_sha256 char(64) NOT NULL,
    expected_bytes bigint NOT NULL,
    status text NOT NULL DEFAULT 'issued',
    issued_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    revoked_at timestamptz,
    CONSTRAINT managed_upload_grant_chunk_fk
        FOREIGN KEY (account_id, chunk_id)
        REFERENCES managed_chunks(account_id, chunk_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_upload_grant_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_upload_grant_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT managed_upload_grant_capability_digest
        CHECK (capability_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_upload_grant_expected_digest
        CHECK (expected_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_upload_grant_expected_bytes
        CHECK (expected_bytes > 0),
    CONSTRAINT managed_upload_grant_status
        CHECK (status IN ('issued', 'consumed', 'expired', 'revoked')),
    CONSTRAINT managed_upload_grant_expiry
        CHECK (expires_at > issued_at),
    CONSTRAINT managed_upload_grant_consumed_order
        CHECK (consumed_at IS NULL OR consumed_at >= issued_at),
    CONSTRAINT managed_upload_grant_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= issued_at),
    CONSTRAINT managed_upload_grant_status_times
        CHECK (
            (status <> 'consumed' OR consumed_at IS NOT NULL)
            AND (status <> 'revoked' OR revoked_at IS NOT NULL)
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_upload_grants_one_live_idx
    ON managed_upload_grants (account_id, chunk_id)
    WHERE status = 'issued';

CREATE INDEX IF NOT EXISTS managed_upload_grants_expiry_idx
    ON managed_upload_grants (expires_at)
    WHERE status = 'issued';

CREATE TABLE IF NOT EXISTS managed_processing_attempts (
    processing_attempt_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    processor_revision text NOT NULL,
    queue_event_hash char(64) NOT NULL,
    lease_token_hash char(64) NOT NULL,
    status text NOT NULL,
    attempt_number integer NOT NULL,
    started_at timestamptz NOT NULL,
    lease_expires_at timestamptz NOT NULL,
    finished_at timestamptz,
    next_attempt_at timestamptz,
    error_code text,
    error_detail_sha256 char(64),
    decompressed_bytes bigint,
    decoded_samples bigint,
    CONSTRAINT managed_processing_attempt_chunk_fk
        FOREIGN KEY (account_id, chunk_id)
        REFERENCES managed_chunks(account_id, chunk_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_processing_attempt_unique
        UNIQUE (
            account_id,
            chunk_id,
            processor_revision,
            attempt_number
        ),
    CONSTRAINT managed_processing_revision
        CHECK (
            processor_revision
            ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT managed_processing_queue_digest
        CHECK (queue_event_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_processing_lease_digest
        CHECK (lease_token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_processing_status
        CHECK (
            status IN (
                'leased',
                'succeeded',
                'retryable_error',
                'terminal_error'
            )
        ),
    CONSTRAINT managed_processing_attempt_number
        CHECK (attempt_number > 0),
    CONSTRAINT managed_processing_lease_order
        CHECK (lease_expires_at > started_at),
    CONSTRAINT managed_processing_finished_order
        CHECK (finished_at IS NULL OR finished_at >= started_at),
    CONSTRAINT managed_processing_retry_order
        CHECK (
            next_attempt_at IS NULL
            OR (
                finished_at IS NOT NULL
                AND next_attempt_at >= finished_at
            )
        ),
    CONSTRAINT managed_processing_error_pair
        CHECK (
            (error_code IS NULL AND error_detail_sha256 IS NULL)
            OR (
                error_code ~ '^[a-z][a-z0-9_]{1,63}$'
                AND error_detail_sha256 ~ '^[0-9a-f]{64}$'
            )
        ),
    CONSTRAINT managed_processing_error_status
        CHECK (
            status NOT IN ('retryable_error', 'terminal_error')
            OR error_code IS NOT NULL
        ),
    CONSTRAINT managed_processing_terminal_time
        CHECK (status = 'leased' OR finished_at IS NOT NULL),
    CONSTRAINT managed_processing_decompressed_bytes
        CHECK (decompressed_bytes IS NULL OR decompressed_bytes >= 0),
    CONSTRAINT managed_processing_decoded_samples
        CHECK (decoded_samples IS NULL OR decoded_samples >= 0)
);

CREATE INDEX IF NOT EXISTS managed_processing_attempts_retry_idx
    ON managed_processing_attempts (next_attempt_at, chunk_id)
    WHERE status = 'retryable_error';

CREATE TABLE IF NOT EXISTS managed_aggregate_provenance (
    provenance_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    algorithm_id text NOT NULL,
    algorithm_revision text NOT NULL,
    computed_by text NOT NULL,
    input_set_sha256 char(64) NOT NULL,
    window_start timestamptz NOT NULL,
    window_end timestamptz NOT NULL,
    coverage_fraction double precision,
    quality_fraction double precision,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_provenance_scope_unique
        UNIQUE (account_id, provenance_id),
    CONSTRAINT managed_provenance_algorithm_id
        CHECK (algorithm_id ~ '^[a-z][a-z0-9_.-]{1,127}$'),
    CONSTRAINT managed_provenance_algorithm_revision
        CHECK (
            algorithm_revision
            ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT managed_provenance_computed_by
        CHECK (computed_by IN ('ios', 'android', 'server', 'import')),
    CONSTRAINT managed_provenance_input_digest
        CHECK (input_set_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_provenance_window
        CHECK (window_end >= window_start),
    CONSTRAINT managed_provenance_coverage
        CHECK (
            coverage_fraction IS NULL
            OR coverage_fraction BETWEEN 0 AND 1
        ),
    CONSTRAINT managed_provenance_quality
        CHECK (
            quality_fraction IS NULL
            OR quality_fraction BETWEEN 0 AND 1
        )
);

CREATE TABLE IF NOT EXISTS managed_aggregate_inputs (
    account_id uuid NOT NULL,
    provenance_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    input_role text NOT NULL,
    PRIMARY KEY (account_id, provenance_id, chunk_id, input_role),
    CONSTRAINT managed_aggregate_input_provenance_fk
        FOREIGN KEY (account_id, provenance_id)
        REFERENCES managed_aggregate_provenance(account_id, provenance_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_aggregate_input_chunk_fk
        FOREIGN KEY (account_id, chunk_id)
        REFERENCES managed_chunks(account_id, chunk_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_aggregate_input_role
        CHECK (input_role ~ '^[a-z][a-z0-9_]{1,63}$')
);

CREATE TABLE IF NOT EXISTS managed_daily_aggregates (
    daily_aggregate_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    day date NOT NULL,
    metric_key text NOT NULL,
    value double precision NOT NULL,
    unit text NOT NULL,
    aggregate_revision bigint NOT NULL,
    provenance_id uuid NOT NULL,
    is_current boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    superseded_at timestamptz,
    CONSTRAINT managed_daily_aggregate_provenance_fk
        FOREIGN KEY (account_id, provenance_id)
        REFERENCES managed_aggregate_provenance(account_id, provenance_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_daily_aggregate_version_unique
        UNIQUE (account_id, day, metric_key, aggregate_revision),
    CONSTRAINT managed_daily_aggregate_metric
        CHECK (metric_key ~ '^[a-z][a-z0-9_.-]{1,127}$'),
    CONSTRAINT managed_daily_aggregate_value
        CHECK (value BETWEEN '-1e308'::float8 AND '1e308'::float8),
    CONSTRAINT managed_daily_aggregate_unit
        CHECK (length(unit) BETWEEN 1 AND 64),
    CONSTRAINT managed_daily_aggregate_revision
        CHECK (aggregate_revision > 0),
    CONSTRAINT managed_daily_aggregate_superseded_order
        CHECK (superseded_at IS NULL OR superseded_at >= created_at),
    CONSTRAINT managed_daily_aggregate_current_time
        CHECK (is_current = (superseded_at IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_daily_aggregates_current_idx
    ON managed_daily_aggregates (account_id, day, metric_key)
    WHERE is_current;

CREATE INDEX IF NOT EXISTS managed_daily_aggregates_history_idx
    ON managed_daily_aggregates (account_id, metric_key, day DESC)
    WHERE is_current;

CREATE TABLE IF NOT EXISTS managed_sleep_summaries (
    sleep_summary_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    logical_sleep_id uuid NOT NULL,
    source_id uuid NOT NULL,
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    summary_revision bigint NOT NULL,
    provenance_id uuid NOT NULL,
    summary_sha256 char(64) NOT NULL,
    summary jsonb NOT NULL,
    is_current boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    superseded_at timestamptz,
    CONSTRAINT managed_sleep_summary_source_fk
        FOREIGN KEY (account_id, source_id)
        REFERENCES managed_sources(account_id, source_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_sleep_summary_provenance_fk
        FOREIGN KEY (account_id, provenance_id)
        REFERENCES managed_aggregate_provenance(account_id, provenance_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_sleep_summary_version_unique
        UNIQUE (account_id, logical_sleep_id, summary_revision),
    CONSTRAINT managed_sleep_summary_window
        CHECK (end_at > start_at),
    CONSTRAINT managed_sleep_summary_revision
        CHECK (summary_revision > 0),
    CONSTRAINT managed_sleep_summary_digest
        CHECK (summary_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_sleep_summary_json
        CHECK (jsonb_typeof(summary) = 'object'),
    CONSTRAINT managed_sleep_summary_superseded_order
        CHECK (superseded_at IS NULL OR superseded_at >= created_at),
    CONSTRAINT managed_sleep_summary_current_time
        CHECK (is_current = (superseded_at IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_sleep_summaries_current_idx
    ON managed_sleep_summaries (account_id, logical_sleep_id)
    WHERE is_current;

CREATE INDEX IF NOT EXISTS managed_sleep_summaries_time_idx
    ON managed_sleep_summaries (account_id, start_at DESC)
    WHERE is_current;

CREATE TABLE IF NOT EXISTS managed_workout_summaries (
    workout_summary_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    logical_workout_id uuid NOT NULL,
    source_id uuid NOT NULL,
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    sport_key text NOT NULL,
    summary_revision bigint NOT NULL,
    provenance_id uuid NOT NULL,
    summary_sha256 char(64) NOT NULL,
    summary jsonb NOT NULL,
    is_current boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    superseded_at timestamptz,
    CONSTRAINT managed_workout_summary_source_fk
        FOREIGN KEY (account_id, source_id)
        REFERENCES managed_sources(account_id, source_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_workout_summary_provenance_fk
        FOREIGN KEY (account_id, provenance_id)
        REFERENCES managed_aggregate_provenance(account_id, provenance_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_workout_summary_version_unique
        UNIQUE (account_id, logical_workout_id, summary_revision),
    CONSTRAINT managed_workout_summary_window
        CHECK (end_at > start_at),
    CONSTRAINT managed_workout_summary_sport
        CHECK (sport_key ~ '^[a-z][a-z0-9_.-]{1,127}$'),
    CONSTRAINT managed_workout_summary_revision
        CHECK (summary_revision > 0),
    CONSTRAINT managed_workout_summary_digest
        CHECK (summary_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_workout_summary_json
        CHECK (jsonb_typeof(summary) = 'object'),
    CONSTRAINT managed_workout_summary_superseded_order
        CHECK (superseded_at IS NULL OR superseded_at >= created_at),
    CONSTRAINT managed_workout_summary_current_time
        CHECK (is_current = (superseded_at IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_workout_summaries_current_idx
    ON managed_workout_summaries (account_id, logical_workout_id)
    WHERE is_current;

CREATE INDEX IF NOT EXISTS managed_workout_summaries_time_idx
    ON managed_workout_summaries (account_id, start_at DESC)
    WHERE is_current;

CREATE TABLE IF NOT EXISTS managed_documents (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    document_kind text NOT NULL,
    document_id uuid NOT NULL,
    document_revision bigint NOT NULL,
    origin_installation_id text NOT NULL,
    content_mode text NOT NULL,
    client_key_id uuid,
    content_sha256 char(64) NOT NULL,
    payload_json jsonb,
    payload_ciphertext bytea,
    updated_at timestamptz NOT NULL,
    deleted_at timestamptz,
    PRIMARY KEY (
        account_id,
        document_kind,
        document_id,
        document_revision
    ),
    CONSTRAINT managed_document_origin_fk
        FOREIGN KEY (account_id, origin_installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_document_client_key_fk
        FOREIGN KEY (account_id, client_key_id)
        REFERENCES managed_client_keys(account_id, client_key_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_document_kind
        CHECK (
            document_kind IN (
                'journal',
                'profile',
                'preferences',
                'automation',
                'strength_plan',
                'strength_log',
                'hydration',
                'nutrition',
                'medication',
                'cycle',
                'user_marker',
                'other'
            )
        ),
    CONSTRAINT managed_document_revision
        CHECK (document_revision > 0),
    CONSTRAINT managed_document_mode
        CHECK (content_mode IN ('server_readable', 'client_encrypted')),
    CONSTRAINT managed_document_digest
        CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_document_payload
        CHECK (
            (
                deleted_at IS NOT NULL
                AND payload_json IS NULL
                AND payload_ciphertext IS NULL
            )
            OR (
                deleted_at IS NULL
                AND content_mode = 'server_readable'
                AND client_key_id IS NULL
                AND payload_json IS NOT NULL
                AND jsonb_typeof(payload_json) = 'object'
                AND pg_column_size(payload_json) <= 1048576
                AND payload_ciphertext IS NULL
            )
            OR (
                deleted_at IS NULL
                AND content_mode = 'client_encrypted'
                AND client_key_id IS NOT NULL
                AND payload_json IS NULL
                AND payload_ciphertext IS NOT NULL
                AND octet_length(payload_ciphertext) BETWEEN 17 AND 1048576
            )
        )
);

CREATE INDEX IF NOT EXISTS managed_documents_latest_idx
    ON managed_documents (
        account_id,
        document_kind,
        document_id,
        document_revision DESC
    );

CREATE TABLE IF NOT EXISTS managed_sync_checkpoints (
    account_id uuid NOT NULL,
    installation_id text NOT NULL,
    source_id uuid NOT NULL,
    stream_key text NOT NULL,
    direction text NOT NULL,
    cursor_sequence bigint NOT NULL DEFAULT 0,
    last_event_at timestamptz,
    last_chunk_id uuid,
    opaque_cursor bytea,
    revision bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (
        account_id,
        installation_id,
        source_id,
        stream_key,
        direction
    ),
    CONSTRAINT managed_sync_checkpoint_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_sync_checkpoint_source_fk
        FOREIGN KEY (account_id, source_id)
        REFERENCES managed_sources(account_id, source_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_sync_checkpoint_chunk_fk
        FOREIGN KEY (account_id, last_chunk_id)
        REFERENCES managed_chunks(account_id, chunk_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_sync_checkpoint_stream
        CHECK (stream_key ~ '^[a-z][a-z0-9_]{0,63}$'),
    CONSTRAINT managed_sync_checkpoint_direction
        CHECK (direction IN ('upload', 'download')),
    CONSTRAINT managed_sync_checkpoint_sequence
        CHECK (cursor_sequence >= 0),
    CONSTRAINT managed_sync_checkpoint_cursor_size
        CHECK (
            opaque_cursor IS NULL
            OR octet_length(opaque_cursor) BETWEEN 1 AND 4096
        ),
    CONSTRAINT managed_sync_checkpoint_revision
        CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS managed_object_access_grants (
    access_grant_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    installation_id text NOT NULL,
    chunk_id uuid NOT NULL,
    request_id uuid NOT NULL,
    capability_hash char(64) NOT NULL UNIQUE,
    purpose text NOT NULL,
    issued_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    revoked_at timestamptz,
    CONSTRAINT managed_access_grant_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_access_grant_chunk_fk
        FOREIGN KEY (account_id, chunk_id)
        REFERENCES managed_chunks(account_id, chunk_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_access_grant_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT managed_access_grant_capability_digest
        CHECK (capability_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_access_grant_purpose
        CHECK (purpose IN ('restore', 'sync', 'export')),
    CONSTRAINT managed_access_grant_expiry
        CHECK (expires_at > issued_at),
    CONSTRAINT managed_access_grant_consumed_order
        CHECK (consumed_at IS NULL OR consumed_at >= issued_at),
    CONSTRAINT managed_access_grant_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= issued_at)
);

CREATE INDEX IF NOT EXISTS managed_access_grants_expiry_idx
    ON managed_object_access_grants (expires_at)
    WHERE consumed_at IS NULL AND revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS managed_restore_jobs (
    restore_job_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    installation_id text NOT NULL,
    request_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'queued',
    snapshot_at timestamptz NOT NULL,
    filters jsonb NOT NULL DEFAULT '{}'::jsonb,
    cursor_event_at timestamptz,
    cursor_chunk_id uuid,
    selected_objects bigint,
    selected_bytes bigint,
    delivered_objects bigint NOT NULL DEFAULT 0,
    delivered_bytes bigint NOT NULL DEFAULT 0,
    error_code text,
    error_detail_sha256 char(64),
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    expires_at timestamptz NOT NULL,
    CONSTRAINT managed_restore_job_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_restore_job_cursor_chunk_fk
        FOREIGN KEY (account_id, cursor_chunk_id)
        REFERENCES managed_chunks(account_id, chunk_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_restore_job_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT managed_restore_job_status
        CHECK (
            status IN (
                'queued',
                'running',
                'completed',
                'failed',
                'canceled',
                'expired'
            )
        ),
    CONSTRAINT managed_restore_job_filters
        CHECK (jsonb_typeof(filters) = 'object'),
    CONSTRAINT managed_restore_job_selected_objects
        CHECK (selected_objects IS NULL OR selected_objects >= 0),
    CONSTRAINT managed_restore_job_selected_bytes
        CHECK (selected_bytes IS NULL OR selected_bytes >= 0),
    CONSTRAINT managed_restore_job_delivered_objects
        CHECK (delivered_objects >= 0),
    CONSTRAINT managed_restore_job_delivered_bytes
        CHECK (delivered_bytes >= 0),
    CONSTRAINT managed_restore_job_error_pair
        CHECK (
            (error_code IS NULL AND error_detail_sha256 IS NULL)
            OR (
                error_code ~ '^[a-z][a-z0-9_]{1,63}$'
                AND error_detail_sha256 ~ '^[0-9a-f]{64}$'
            )
        ),
    CONSTRAINT managed_restore_job_started_order
        CHECK (started_at IS NULL OR started_at >= created_at),
    CONSTRAINT managed_restore_job_completed_order
        CHECK (
            completed_at IS NULL
            OR (started_at IS NOT NULL AND completed_at >= started_at)
        ),
    CONSTRAINT managed_restore_job_expiry
        CHECK (expires_at > created_at),
    CONSTRAINT managed_restore_job_terminal_time
        CHECK (
            status NOT IN ('completed', 'failed', 'canceled', 'expired')
            OR completed_at IS NOT NULL
        )
);

CREATE INDEX IF NOT EXISTS managed_restore_jobs_account_idx
    ON managed_restore_jobs (account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS managed_export_jobs (
    export_job_id uuid PRIMARY KEY,
    account_id uuid NOT NULL,
    storage_namespace uuid NOT NULL,
    installation_id text NOT NULL,
    request_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'queued',
    format text NOT NULL,
    content_mode text NOT NULL,
    client_key_id uuid,
    scope jsonb NOT NULL,
    output_object_key text GENERATED ALWAYS AS (
        'e1/' || storage_namespace::text || '/' || export_job_id::text
    ) STORED,
    output_generation bigint,
    output_sha256 char(64),
    output_bytes bigint,
    error_code text,
    error_detail_sha256 char(64),
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    expires_at timestamptz NOT NULL,
    CONSTRAINT managed_export_job_account_fk
        FOREIGN KEY (account_id, storage_namespace)
        REFERENCES managed_accounts(account_id, storage_namespace)
        ON DELETE RESTRICT,
    CONSTRAINT managed_export_job_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_export_job_client_key_fk
        FOREIGN KEY (account_id, client_key_id)
        REFERENCES managed_client_keys(account_id, client_key_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_export_job_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT managed_export_job_object_unique
        UNIQUE (output_object_key),
    CONSTRAINT managed_export_job_status
        CHECK (
            status IN (
                'queued',
                'running',
                'completed',
                'failed',
                'canceled',
                'expired'
            )
        ),
    CONSTRAINT managed_export_job_format
        CHECK (format IN ('noopbak', 'json', 'csv_bundle')),
    CONSTRAINT managed_export_job_content_mode
        CHECK (content_mode IN ('server_readable', 'client_encrypted')),
    CONSTRAINT managed_export_job_key_mode
        CHECK (
            (content_mode = 'server_readable' AND client_key_id IS NULL)
            OR (
                content_mode = 'client_encrypted'
                AND client_key_id IS NOT NULL
            )
        ),
    CONSTRAINT managed_export_job_scope
        CHECK (jsonb_typeof(scope) = 'object'),
    CONSTRAINT managed_export_job_generation
        CHECK (output_generation IS NULL OR output_generation > 0),
    CONSTRAINT managed_export_job_digest
        CHECK (
            output_sha256 IS NULL
            OR output_sha256 ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_export_job_bytes
        CHECK (output_bytes IS NULL OR output_bytes > 0),
    CONSTRAINT managed_export_job_error_pair
        CHECK (
            (error_code IS NULL AND error_detail_sha256 IS NULL)
            OR (
                error_code ~ '^[a-z][a-z0-9_]{1,63}$'
                AND error_detail_sha256 ~ '^[0-9a-f]{64}$'
            )
        ),
    CONSTRAINT managed_export_job_started_order
        CHECK (started_at IS NULL OR started_at >= created_at),
    CONSTRAINT managed_export_job_completed_order
        CHECK (
            completed_at IS NULL
            OR (started_at IS NOT NULL AND completed_at >= started_at)
        ),
    CONSTRAINT managed_export_job_expiry
        CHECK (expires_at > created_at),
    CONSTRAINT managed_export_job_completed_fields
        CHECK (
            status <> 'completed'
            OR (
                completed_at IS NOT NULL
                AND output_generation IS NOT NULL
                AND output_sha256 IS NOT NULL
                AND output_bytes IS NOT NULL
            )
        )
);

CREATE INDEX IF NOT EXISTS managed_export_jobs_account_idx
    ON managed_export_jobs (account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS managed_export_jobs_expiry_idx
    ON managed_export_jobs (expires_at)
    WHERE status = 'completed';

CREATE TABLE IF NOT EXISTS managed_erasure_jobs (
    erasure_job_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    request_id uuid NOT NULL,
    requested_by_identity_id uuid,
    scope text NOT NULL,
    status text NOT NULL DEFAULT 'queued',
    tenant_replay_hash char(64) NOT NULL,
    confirmation_sha256 char(64) NOT NULL,
    objects_selected bigint,
    objects_deleted bigint NOT NULL DEFAULT 0,
    bytes_selected bigint,
    bytes_deleted bigint NOT NULL DEFAULT 0,
    database_rows_deleted bigint NOT NULL DEFAULT 0,
    error_code text,
    error_detail_sha256 char(64),
    requested_at timestamptz NOT NULL,
    not_before timestamptz NOT NULL,
    started_at timestamptz,
    completed_at timestamptz,
    verification_expires_at timestamptz NOT NULL,
    CONSTRAINT managed_erasure_job_identity_fk
        FOREIGN KEY (account_id, requested_by_identity_id)
        REFERENCES managed_external_identities(account_id, identity_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_erasure_job_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT managed_erasure_job_scope
        CHECK (
            scope IN (
                'all_managed_data',
                'raw_chunks',
                'derived_data',
                'account'
            )
        ),
    CONSTRAINT managed_erasure_job_status
        CHECK (
            status IN (
                'queued',
                'cooling_off',
                'running',
                'verifying',
                'completed',
                'failed',
                'canceled'
            )
        ),
    CONSTRAINT managed_erasure_job_tenant_digest
        CHECK (tenant_replay_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_erasure_job_confirmation_digest
        CHECK (confirmation_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_erasure_job_objects_selected
        CHECK (objects_selected IS NULL OR objects_selected >= 0),
    CONSTRAINT managed_erasure_job_objects_deleted
        CHECK (objects_deleted >= 0),
    CONSTRAINT managed_erasure_job_bytes_selected
        CHECK (bytes_selected IS NULL OR bytes_selected >= 0),
    CONSTRAINT managed_erasure_job_bytes_deleted
        CHECK (bytes_deleted >= 0),
    CONSTRAINT managed_erasure_job_rows_deleted
        CHECK (database_rows_deleted >= 0),
    CONSTRAINT managed_erasure_job_error_pair
        CHECK (
            (error_code IS NULL AND error_detail_sha256 IS NULL)
            OR (
                error_code ~ '^[a-z][a-z0-9_]{1,63}$'
                AND error_detail_sha256 ~ '^[0-9a-f]{64}$'
            )
        ),
    CONSTRAINT managed_erasure_job_not_before
        CHECK (not_before >= requested_at),
    CONSTRAINT managed_erasure_job_started_order
        CHECK (started_at IS NULL OR started_at >= not_before),
    CONSTRAINT managed_erasure_job_completed_order
        CHECK (
            completed_at IS NULL
            OR (started_at IS NOT NULL AND completed_at >= started_at)
        ),
    CONSTRAINT managed_erasure_job_verification_expiry
        CHECK (verification_expires_at > requested_at),
    CONSTRAINT managed_erasure_job_terminal_time
        CHECK (
            status NOT IN ('completed', 'failed', 'canceled')
            OR completed_at IS NOT NULL
        )
);

CREATE INDEX IF NOT EXISTS managed_erasure_jobs_status_idx
    ON managed_erasure_jobs (status, not_before, requested_at);

CREATE TABLE IF NOT EXISTS managed_erasure_targets (
    erasure_job_id uuid NOT NULL
        REFERENCES managed_erasure_jobs(erasure_job_id) ON DELETE CASCADE,
    target_kind text NOT NULL,
    target_partition text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    selected_count bigint,
    deleted_count bigint NOT NULL DEFAULT 0,
    last_cursor_hash char(64),
    attempts integer NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    PRIMARY KEY (erasure_job_id, target_kind, target_partition),
    CONSTRAINT managed_erasure_target_kind
        CHECK (
            target_kind IN (
                'object_storage',
                'database',
                'identity',
                'cache',
                'analytics',
                'backup'
            )
        ),
    CONSTRAINT managed_erasure_target_partition
        CHECK (
            target_partition
            ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
        ),
    CONSTRAINT managed_erasure_target_status
        CHECK (
            status IN (
                'pending',
                'running',
                'completed',
                'failed',
                'not_applicable'
            )
        ),
    CONSTRAINT managed_erasure_target_selected
        CHECK (selected_count IS NULL OR selected_count >= 0),
    CONSTRAINT managed_erasure_target_deleted
        CHECK (deleted_count >= 0),
    CONSTRAINT managed_erasure_target_cursor_digest
        CHECK (
            last_cursor_hash IS NULL
            OR last_cursor_hash ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_erasure_target_attempts
        CHECK (attempts >= 0),
    CONSTRAINT managed_erasure_target_terminal_time
        CHECK (
            status NOT IN ('completed', 'not_applicable')
            OR completed_at IS NOT NULL
        )
);

CREATE TABLE IF NOT EXISTS managed_replay_tombstones (
    replay_tombstone_id uuid PRIMARY KEY,
    tenant_replay_hash char(64) NOT NULL,
    resource_kind text NOT NULL,
    resource_id_hash char(64) NOT NULL,
    content_sha256 char(64),
    deletion_reason text NOT NULL,
    deleted_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    CONSTRAINT managed_replay_tombstone_unique
        UNIQUE (
            tenant_replay_hash,
            resource_kind,
            resource_id_hash
        ),
    CONSTRAINT managed_replay_tombstone_tenant_digest
        CHECK (tenant_replay_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_replay_tombstone_kind
        CHECK (resource_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_replay_tombstone_resource_digest
        CHECK (resource_id_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_replay_tombstone_content_digest
        CHECK (
            content_sha256 IS NULL
            OR content_sha256 ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_replay_tombstone_reason
        CHECK (
            deletion_reason IN (
                'retention',
                'user_delete',
                'account_erasure',
                'invalid_upload'
            )
        ),
    CONSTRAINT managed_replay_tombstone_expiry
        CHECK (expires_at > deleted_at)
);

CREATE INDEX IF NOT EXISTS managed_replay_tombstones_expiry_idx
    ON managed_replay_tombstones (expires_at);

CREATE TABLE IF NOT EXISTS managed_support_access_grants (
    support_grant_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    operator_subject_hash char(64) NOT NULL,
    approved_by_identity_id uuid NOT NULL,
    scopes text[] NOT NULL,
    reason_code text NOT NULL,
    status text NOT NULL DEFAULT 'active',
    approved_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    CONSTRAINT managed_support_grant_scope_unique
        UNIQUE (account_id, support_grant_id),
    CONSTRAINT managed_support_grant_identity_fk
        FOREIGN KEY (account_id, approved_by_identity_id)
        REFERENCES managed_external_identities(account_id, identity_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_support_grant_operator_digest
        CHECK (operator_subject_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_support_grant_scopes
        CHECK (
            cardinality(scopes) BETWEEN 1 AND 16
            AND array_position(scopes, NULL) IS NULL
        ),
    CONSTRAINT managed_support_grant_reason
        CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_support_grant_status
        CHECK (status IN ('active', 'expired', 'revoked')),
    CONSTRAINT managed_support_grant_expiry
        CHECK (expires_at > approved_at),
    CONSTRAINT managed_support_grant_revocation
        CHECK (revoked_at IS NULL OR revoked_at >= approved_at),
    CONSTRAINT managed_support_grant_status_time
        CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS managed_support_grants_active_idx
    ON managed_support_access_grants (
        operator_subject_hash,
        expires_at
    )
    WHERE status = 'active';

CREATE TABLE IF NOT EXISTS managed_audit_events (
    audit_event_id uuid PRIMARY KEY,
    account_id uuid
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    actor_kind text NOT NULL,
    actor_subject_hash char(64),
    installation_id text,
    support_grant_id uuid,
    request_id uuid NOT NULL,
    action text NOT NULL,
    target_kind text NOT NULL,
    target_id_hash char(64),
    outcome text NOT NULL,
    origin_hash char(64),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    purge_after timestamptz NOT NULL,
    CONSTRAINT managed_audit_installation_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_audit_support_grant_fk
        FOREIGN KEY (account_id, support_grant_id)
        REFERENCES managed_support_access_grants(
            account_id,
            support_grant_id
        )
        ON DELETE RESTRICT,
    CONSTRAINT managed_audit_request_unique
        UNIQUE (request_id, action, target_kind),
    CONSTRAINT managed_audit_actor_kind
        CHECK (
            actor_kind IN (
                'account',
                'installation',
                'operator',
                'service',
                'anonymous'
            )
        ),
    CONSTRAINT managed_audit_actor_digest
        CHECK (
            actor_subject_hash IS NULL
            OR actor_subject_hash ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_audit_action
        CHECK (action ~ '^[a-z][a-z0-9_.]{1,127}$'),
    CONSTRAINT managed_audit_target_kind
        CHECK (target_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_audit_target_digest
        CHECK (
            target_id_hash IS NULL
            OR target_id_hash ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_audit_outcome
        CHECK (outcome IN ('allowed', 'denied', 'failed')),
    CONSTRAINT managed_audit_origin_digest
        CHECK (origin_hash IS NULL OR origin_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_audit_metadata
        CHECK (jsonb_typeof(metadata) = 'object'),
    CONSTRAINT managed_audit_account_bound_fields
        CHECK (
            (installation_id IS NULL OR account_id IS NOT NULL)
            AND (support_grant_id IS NULL OR account_id IS NOT NULL)
        ),
    CONSTRAINT managed_audit_purge_order
        CHECK (purge_after > occurred_at),
    CONSTRAINT managed_audit_operator_grant
        CHECK (
            actor_kind <> 'operator'
            OR (
                support_grant_id IS NOT NULL
                AND actor_subject_hash IS NOT NULL
            )
        )
);

CREATE INDEX IF NOT EXISTS managed_audit_events_account_time_idx
    ON managed_audit_events (account_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS managed_audit_events_operator_time_idx
    ON managed_audit_events (actor_subject_hash, occurred_at DESC)
    WHERE actor_kind = 'operator';

CREATE INDEX IF NOT EXISTS managed_audit_events_purge_idx
    ON managed_audit_events (purge_after);

-- Once a chunk reservation is created, content identity, ownership, event
-- window, retention, and expected bytes cannot be rewritten. Object finalizer
-- and processor fields may be filled once; lifecycle state and timestamps may
-- continue to advance.
CREATE OR REPLACE FUNCTION noop_managed_chunk_preserve_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.account_id IS DISTINCT FROM OLD.account_id
       OR NEW.storage_namespace IS DISTINCT FROM OLD.storage_namespace
       OR NEW.source_id IS DISTINCT FROM OLD.source_id
       OR NEW.installation_id IS DISTINCT FROM OLD.installation_id
       OR NEW.retention_snapshot_id IS DISTINCT FROM OLD.retention_snapshot_id
       OR NEW.client_key_id IS DISTINCT FROM OLD.client_key_id
       OR NEW.data_class IS DISTINCT FROM OLD.data_class
       OR NEW.schema_version IS DISTINCT FROM OLD.schema_version
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.content_mode IS DISTINCT FROM OLD.content_mode
       OR NEW.event_start IS DISTINCT FROM OLD.event_start
       OR NEW.event_end IS DISTINCT FROM OLD.event_end
       OR NEW.compression IS DISTINCT FROM OLD.compression
       OR NEW.content_type IS DISTINCT FROM OLD.content_type
       OR NEW.expected_sha256 IS DISTINCT FROM OLD.expected_sha256
       OR NEW.expected_compressed_bytes
          IS DISTINCT FROM OLD.expected_compressed_bytes
       OR NEW.expected_uncompressed_bytes
          IS DISTINCT FROM OLD.expected_uncompressed_bytes
       OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
       OR NEW.reservation_expires_at
          IS DISTINCT FROM OLD.reservation_expires_at THEN
        RAISE EXCEPTION 'managed chunk content identity is immutable'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.state IS DISTINCT FROM OLD.state
       AND NOT (
           (OLD.state = 'reserved'
            AND NEW.state IN ('uploading', 'uploaded', 'delete_pending'))
           OR (OLD.state = 'uploading'
               AND NEW.state IN ('uploaded', 'delete_pending'))
           OR (OLD.state = 'uploaded'
               AND NEW.state
                   IN ('validating', 'available', 'quarantined', 'delete_pending'))
           OR (OLD.state = 'validating'
               AND NEW.state IN ('available', 'quarantined', 'delete_pending'))
           OR (OLD.state = 'available' AND NEW.state = 'delete_pending')
           OR (OLD.state = 'quarantined'
               AND NEW.state IN ('validating', 'delete_pending'))
           OR (OLD.state = 'delete_pending' AND NEW.state = 'deleted')
       ) THEN
        RAISE EXCEPTION 'invalid managed chunk lifecycle transition'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.object_generation IS NOT NULL
       AND NEW.object_generation IS DISTINCT FROM OLD.object_generation THEN
        RAISE EXCEPTION 'managed chunk object generation is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.object_metageneration IS NOT NULL
       AND NEW.object_metageneration
           IS DISTINCT FROM OLD.object_metageneration THEN
        RAISE EXCEPTION 'managed chunk object metageneration is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.object_crc32c IS NOT NULL
       AND NEW.object_crc32c IS DISTINCT FROM OLD.object_crc32c THEN
        RAISE EXCEPTION 'managed chunk object checksum is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.verified_sha256 IS NOT NULL
       AND NEW.verified_sha256 IS DISTINCT FROM OLD.verified_sha256 THEN
        RAISE EXCEPTION 'managed chunk verified digest is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.actual_compressed_bytes IS NOT NULL
       AND NEW.actual_compressed_bytes
           IS DISTINCT FROM OLD.actual_compressed_bytes THEN
        RAISE EXCEPTION 'managed chunk compressed size is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.actual_uncompressed_bytes IS NOT NULL
       AND NEW.actual_uncompressed_bytes
           IS DISTINCT FROM OLD.actual_uncompressed_bytes THEN
        RAISE EXCEPTION 'managed chunk uncompressed size is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.sample_count IS NOT NULL
       AND NEW.sample_count IS DISTINCT FROM OLD.sample_count THEN
        RAISE EXCEPTION 'managed chunk sample count is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.uploaded_at IS NOT NULL
       AND NEW.uploaded_at IS DISTINCT FROM OLD.uploaded_at THEN
        RAISE EXCEPTION 'managed chunk upload time is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.validated_at IS NOT NULL
       AND NEW.validated_at IS DISTINCT FROM OLD.validated_at THEN
        RAISE EXCEPTION 'managed chunk validation time is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.available_at IS NOT NULL
       AND NEW.available_at IS DISTINCT FROM OLD.available_at THEN
        RAISE EXCEPTION 'managed chunk availability time is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.delete_requested_at IS NOT NULL
       AND NEW.delete_requested_at
           IS DISTINCT FROM OLD.delete_requested_at THEN
        RAISE EXCEPTION 'managed chunk deletion request time is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.deleted_at IS NOT NULL
       AND NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN
        RAISE EXCEPTION 'managed chunk deletion time is immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS managed_chunks_preserve_identity ON managed_chunks;
CREATE TRIGGER managed_chunks_preserve_identity
BEFORE UPDATE ON managed_chunks
FOR EACH ROW
EXECUTE FUNCTION noop_managed_chunk_preserve_identity();
