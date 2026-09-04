-- Scale contracts for NOOP+ managed storage. High-rate samples remain in
-- immutable compressed objects. These tables version the object payload,
-- meter ingress without rescanning manifests, and expose an account-local
-- monotonic change feed so late backfill cannot be skipped by another device.

CREATE TABLE IF NOT EXISTS managed_chunk_schemas (
    data_class text NOT NULL,
    schema_version integer NOT NULL,
    status text NOT NULL DEFAULT 'draft',
    content_mode text NOT NULL,
    content_type text NOT NULL,
    allowed_compressions text[] NOT NULL,
    schema_sha256 char(64) NOT NULL,
    schema_uri text NOT NULL,
    maximum_event_span_seconds integer NOT NULL,
    maximum_streams integer NOT NULL,
    effective_at timestamptz,
    retired_at timestamptz,
    configuration jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (data_class, schema_version),
    CONSTRAINT managed_chunk_schema_class
        CHECK (data_class ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_chunk_schema_version
        CHECK (schema_version BETWEEN 1 AND 10000),
    CONSTRAINT managed_chunk_schema_status
        CHECK (status IN ('draft', 'active', 'retired')),
    CONSTRAINT managed_chunk_schema_content_mode
        CHECK (content_mode IN ('server_readable', 'client_encrypted')),
    CONSTRAINT managed_chunk_schema_content_type
        CHECK (
            content_type IN (
                'application/vnd.noop.chunk+protobuf',
                'application/vnd.noop.chunk+cbor',
                'application/vnd.noop.chunk+json',
                'application/vnd.noop.backup'
            )
        ),
    CONSTRAINT managed_chunk_schema_compressions
        CHECK (
            cardinality(allowed_compressions) BETWEEN 1 AND 3
            AND array_position(allowed_compressions, NULL) IS NULL
            AND allowed_compressions
                <@ ARRAY['zstd', 'gzip', 'none']::text[]
        ),
    CONSTRAINT managed_chunk_schema_digest
        CHECK (schema_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_chunk_schema_uri
        CHECK (
            length(schema_uri) BETWEEN 1 AND 1024
            AND schema_uri !~ '[[:space:]]'
        ),
    CONSTRAINT managed_chunk_schema_event_span
        CHECK (maximum_event_span_seconds BETWEEN 1 AND 604800),
    CONSTRAINT managed_chunk_schema_stream_count
        CHECK (maximum_streams BETWEEN 0 AND 128),
    CONSTRAINT managed_chunk_schema_configuration
        CHECK (jsonb_typeof(configuration) = 'object'),
    CONSTRAINT managed_chunk_schema_effective_state
        CHECK (status = 'draft' OR effective_at IS NOT NULL),
    CONSTRAINT managed_chunk_schema_retirement_order
        CHECK (
            retired_at IS NULL
            OR (effective_at IS NOT NULL AND retired_at > effective_at)
        ),
    CONSTRAINT managed_chunk_schema_retired_state
        CHECK (status <> 'retired' OR retired_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS managed_chunk_schemas_active_idx
    ON managed_chunk_schemas (data_class, schema_version)
    WHERE status = 'active';

CREATE TABLE IF NOT EXISTS managed_stream_schemas (
    data_class text NOT NULL,
    stream_key text NOT NULL,
    schema_revision integer NOT NULL,
    status text NOT NULL DEFAULT 'draft',
    schema_sha256 char(64) NOT NULL,
    schema_uri text NOT NULL,
    value_schema jsonb NOT NULL,
    effective_at timestamptz,
    retired_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (data_class, stream_key, schema_revision),
    CONSTRAINT managed_stream_schema_class
        CHECK (data_class ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_stream_schema_key
        CHECK (stream_key ~ '^[a-z][a-z0-9_]{0,63}$'),
    CONSTRAINT managed_stream_schema_revision
        CHECK (schema_revision BETWEEN 1 AND 10000),
    CONSTRAINT managed_stream_schema_status
        CHECK (status IN ('draft', 'active', 'retired')),
    CONSTRAINT managed_stream_schema_digest
        CHECK (schema_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_stream_schema_uri
        CHECK (
            length(schema_uri) BETWEEN 1 AND 1024
            AND schema_uri !~ '[[:space:]]'
        ),
    CONSTRAINT managed_stream_schema_value
        CHECK (jsonb_typeof(value_schema) = 'object'),
    CONSTRAINT managed_stream_schema_effective_state
        CHECK (status = 'draft' OR effective_at IS NOT NULL),
    CONSTRAINT managed_stream_schema_retirement_order
        CHECK (
            retired_at IS NULL
            OR (effective_at IS NOT NULL AND retired_at > effective_at)
        ),
    CONSTRAINT managed_stream_schema_retired_state
        CHECK (status <> 'retired' OR retired_at IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS managed_chunk_schema_streams (
    data_class text NOT NULL,
    chunk_schema_version integer NOT NULL,
    stream_key text NOT NULL,
    stream_schema_revision integer NOT NULL,
    required boolean NOT NULL DEFAULT false,
    PRIMARY KEY (
        data_class,
        chunk_schema_version,
        stream_key,
        stream_schema_revision
    ),
    CONSTRAINT managed_chunk_schema_stream_chunk_fk
        FOREIGN KEY (data_class, chunk_schema_version)
        REFERENCES managed_chunk_schemas(data_class, schema_version)
        ON DELETE RESTRICT,
    CONSTRAINT managed_chunk_schema_stream_stream_fk
        FOREIGN KEY (
            data_class,
            stream_key,
            stream_schema_revision
        )
        REFERENCES managed_stream_schemas(
            data_class,
            stream_key,
            schema_revision
        )
        ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS managed_daily_ingest_usage (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    data_class text NOT NULL,
    utc_day date NOT NULL,
    accepted_bytes bigint NOT NULL DEFAULT 0,
    committed_bytes bigint NOT NULL DEFAULT 0,
    accepted_objects bigint NOT NULL DEFAULT 0,
    committed_objects bigint NOT NULL DEFAULT 0,
    revision bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, data_class, utc_day),
    CONSTRAINT managed_daily_ingest_class
        CHECK (data_class ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_daily_ingest_accepted_bytes
        CHECK (accepted_bytes >= 0),
    CONSTRAINT managed_daily_ingest_committed_bytes
        CHECK (
            committed_bytes >= 0
            AND committed_bytes <= accepted_bytes
        ),
    CONSTRAINT managed_daily_ingest_accepted_objects
        CHECK (accepted_objects >= 0),
    CONSTRAINT managed_daily_ingest_committed_objects
        CHECK (
            committed_objects >= 0
            AND committed_objects <= accepted_objects
        ),
    CONSTRAINT managed_daily_ingest_revision
        CHECK (revision > 0)
);

CREATE INDEX IF NOT EXISTS managed_daily_ingest_expiry_idx
    ON managed_daily_ingest_usage (utc_day, account_id);

CREATE TABLE IF NOT EXISTS managed_account_change_sequences (
    account_id uuid PRIMARY KEY
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    last_sequence bigint NOT NULL DEFAULT 0,
    minimum_retained_sequence bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_account_change_last
        CHECK (last_sequence >= 0),
    CONSTRAINT managed_account_change_floor
        CHECK (
            minimum_retained_sequence >= 1
            AND minimum_retained_sequence <= last_sequence + 1
        )
);

CREATE TABLE IF NOT EXISTS managed_change_events (
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    change_sequence bigint NOT NULL,
    change_event_id uuid NOT NULL UNIQUE,
    idempotency_hash char(64) NOT NULL,
    resource_kind text NOT NULL,
    resource_id uuid NOT NULL,
    resource_revision bigint,
    operation text NOT NULL,
    content_sha256 char(64),
    data_class text,
    event_start timestamptz,
    event_end timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL,
    purge_after timestamptz NOT NULL,
    PRIMARY KEY (account_id, change_sequence),
    CONSTRAINT managed_change_event_idempotency_unique
        UNIQUE (account_id, idempotency_hash),
    CONSTRAINT managed_change_event_sequence
        CHECK (change_sequence > 0),
    CONSTRAINT managed_change_event_idempotency_digest
        CHECK (idempotency_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_change_event_resource_kind
        CHECK (
            resource_kind IN (
                'chunk',
                'document',
                'daily_aggregate',
                'sleep_summary',
                'workout_summary',
                'account'
            )
        ),
    CONSTRAINT managed_change_event_resource_revision
        CHECK (resource_revision IS NULL OR resource_revision >= 0),
    CONSTRAINT managed_change_event_operation
        CHECK (
            operation IN (
                'upsert',
                'available',
                'deleted',
                'tombstone'
            )
        ),
    CONSTRAINT managed_change_event_content_digest
        CHECK (
            content_sha256 IS NULL
            OR content_sha256 ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_change_event_data_class
        CHECK (
            data_class IS NULL
            OR data_class ~ '^[a-z][a-z0-9_]{1,63}$'
        ),
    CONSTRAINT managed_change_event_window
        CHECK (
            (event_start IS NULL AND event_end IS NULL)
            OR (
                event_start IS NOT NULL
                AND event_end IS NOT NULL
                AND event_end >= event_start
            )
        ),
    CONSTRAINT managed_change_event_metadata
        CHECK (jsonb_typeof(metadata) = 'object'),
    CONSTRAINT managed_change_event_purge_order
        CHECK (purge_after > occurred_at)
);

CREATE INDEX IF NOT EXISTS managed_change_events_resource_idx
    ON managed_change_events (
        account_id,
        resource_kind,
        resource_id,
        change_sequence DESC
    );

CREATE INDEX IF NOT EXISTS managed_change_events_purge_idx
    ON managed_change_events (purge_after, account_id, change_sequence);

CREATE TABLE IF NOT EXISTS managed_document_heads (
    account_id uuid NOT NULL,
    document_kind text NOT NULL,
    document_id uuid NOT NULL,
    current_revision bigint NOT NULL,
    content_sha256 char(64) NOT NULL,
    origin_installation_id text NOT NULL,
    updated_at timestamptz NOT NULL,
    deleted_at timestamptz,
    PRIMARY KEY (account_id, document_kind, document_id),
    CONSTRAINT managed_document_head_version_fk
        FOREIGN KEY (
            account_id,
            document_kind,
            document_id,
            current_revision
        )
        REFERENCES managed_documents(
            account_id,
            document_kind,
            document_id,
            document_revision
        )
        ON DELETE RESTRICT,
    CONSTRAINT managed_document_head_origin_fk
        FOREIGN KEY (account_id, origin_installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT managed_document_head_revision
        CHECK (current_revision > 0),
    CONSTRAINT managed_document_head_digest
        CHECK (content_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE OR REPLACE FUNCTION noop_managed_append_change(
    selected_account_id uuid,
    selected_idempotency_hash char(64),
    selected_resource_kind text,
    selected_resource_id uuid,
    selected_resource_revision bigint,
    selected_operation text,
    selected_content_sha256 char(64),
    selected_data_class text,
    selected_event_start timestamptz,
    selected_event_end timestamptz,
    selected_metadata jsonb,
    selected_occurred_at timestamptz,
    selected_purge_after timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
AS $function$
DECLARE
    existing_sequence bigint;
    allocated_sequence bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'noop-managed-change:' || selected_account_id::text,
            0
        )
    );

    SELECT change_sequence
    INTO existing_sequence
    FROM managed_change_events
    WHERE account_id = selected_account_id
      AND idempotency_hash = selected_idempotency_hash;

    IF existing_sequence IS NOT NULL THEN
        RETURN existing_sequence;
    END IF;

    INSERT INTO managed_account_change_sequences (
        account_id,
        last_sequence,
        minimum_retained_sequence,
        updated_at
    ) VALUES (
        selected_account_id,
        1,
        1,
        selected_occurred_at
    )
    ON CONFLICT (account_id) DO UPDATE
    SET last_sequence =
            managed_account_change_sequences.last_sequence + 1,
        updated_at = EXCLUDED.updated_at
    RETURNING last_sequence INTO allocated_sequence;

    INSERT INTO managed_change_events (
        account_id,
        change_sequence,
        change_event_id,
        idempotency_hash,
        resource_kind,
        resource_id,
        resource_revision,
        operation,
        content_sha256,
        data_class,
        event_start,
        event_end,
        metadata,
        occurred_at,
        purge_after
    ) VALUES (
        selected_account_id,
        allocated_sequence,
        gen_random_uuid(),
        selected_idempotency_hash,
        selected_resource_kind,
        selected_resource_id,
        selected_resource_revision,
        selected_operation,
        selected_content_sha256,
        selected_data_class,
        selected_event_start,
        selected_event_end,
        selected_metadata,
        selected_occurred_at,
        selected_purge_after
    );

    RETURN allocated_sequence;
END
$function$;
