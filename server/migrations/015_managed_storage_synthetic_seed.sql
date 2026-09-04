-- Synthetic-only reference policy and plan. The managed API remains disabled
-- unless every NOOP_MANAGED_* setting is explicitly supplied. Production must
-- add a separately reviewed policy and plan revision instead of reusing these
-- staging limits.

INSERT INTO managed_policy_documents (
    policy_kind,
    policy_version,
    document_sha256,
    document_uri,
    effective_at
) VALUES (
    'managed_storage',
    'synthetic-v1',
    'e9324e49b411f124635c24b2de509f4e459cb164b7bdd23519c65c778d12d7ef',
    'noop-policy://managed-storage/synthetic-v1',
    timestamptz '2026-09-03 00:00:00+00'
);

INSERT INTO managed_storage_plans (
    plan_code,
    revision,
    status,
    display_tier,
    max_total_bytes,
    max_inflight_bytes,
    max_chunk_bytes,
    max_uncompressed_chunk_bytes,
    max_installations,
    effective_at,
    configuration
) VALUES (
    'noop_plus_staging',
    1,
    'active',
    'noop_plus',
    2147483648,
    134217728,
    16777216,
    268435456,
    5,
    timestamptz '2026-09-03 00:00:00+00',
    '{
        "environment": "synthetic_staging",
        "account_optional": true,
        "feature_restrictions": [],
        "quota_basis": "compressed_committed_plus_reserved_bytes"
    }'::jsonb
);

INSERT INTO managed_plan_data_rules (
    plan_code,
    plan_revision,
    data_class,
    cloud_retention_days,
    summary_retention_days,
    recommended_local_raw_days,
    maximum_daily_bytes,
    storage_class,
    server_processing_allowed,
    configuration
) VALUES
    (
        'noop_plus_staging',
        1,
        'essential_timeseries',
        30,
        365,
        30,
        67108864,
        'standard',
        true,
        '{"description": "compressed core physiological timeseries"}'::jsonb
    ),
    (
        'noop_plus_staging',
        1,
        'raw_ppg',
        14,
        90,
        7,
        268435456,
        'standard',
        true,
        '{"description": "high-rate optical waveform"}'::jsonb
    ),
    (
        'noop_plus_staging',
        1,
        'raw_motion',
        14,
        90,
        7,
        268435456,
        'standard',
        true,
        '{"description": "high-rate accelerometer and gyroscope"}'::jsonb
    ),
    (
        'noop_plus_staging',
        1,
        'derived_summaries',
        30,
        365,
        3650,
        16777216,
        'standard',
        true,
        '{"description": "daily, sleep, workout, and metric summaries"}'::jsonb
    ),
    (
        'noop_plus_staging',
        1,
        'user_documents',
        30,
        NULL,
        3650,
        8388608,
        'standard',
        true,
        '{"description": "journal, preferences, plans, and user-entered data"}'::jsonb
    ),
    (
        'noop_plus_staging',
        1,
        'encrypted_backup',
        30,
        NULL,
        30,
        536870912,
        'standard',
        false,
        '{"description": "opaque client-encrypted recovery backup"}'::jsonb
    );
