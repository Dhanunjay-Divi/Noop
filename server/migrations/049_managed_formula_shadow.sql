-- D-059 canonical formula shadow boundary. These rows are comparison evidence
-- only. They do not publish into managed_daily_aggregates and cannot change
-- production metric authority.

CREATE TABLE managed_formula_shadow_results (
    shadow_result_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE RESTRICT,
    request_id uuid NOT NULL,
    metric_key text NOT NULL,
    formula_revision text NOT NULL,
    input_schema_revision integer NOT NULL,
    output_unit text NOT NULL,
    local_day date NOT NULL,
    timezone_name text NOT NULL,
    day_start_at timestamptz NOT NULL,
    day_end_at timestamptz NOT NULL,
    utc_offset_start_minutes smallint NOT NULL,
    utc_offset_end_minutes smallint NOT NULL,
    source_kind text NOT NULL,
    source_revision text NOT NULL,
    input_manifest_sha256 char(64) NOT NULL,
    input_set_sha256 char(64) NOT NULL,
    calibration_revision text,
    server_status text NOT NULL,
    server_value double precision,
    client_status text NOT NULL,
    client_formula_revision text,
    client_value double precision,
    parity_status text NOT NULL,
    absolute_delta double precision,
    parity_tolerance double precision NOT NULL,
    missing_inputs text[] NOT NULL DEFAULT '{}'::text[],
    execution_sha256 char(64) NOT NULL,
    publication_kind text NOT NULL DEFAULT 'shadow',
    rollback_source_result_id uuid,
    is_current boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    superseded_by_result_id uuid,
    superseded_at timestamptz,
    CONSTRAINT managed_formula_shadow_scope_unique
        UNIQUE (account_id, shadow_result_id),
    CONSTRAINT managed_formula_shadow_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT managed_formula_shadow_metric
        CHECK (metric_key ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_formula_shadow_revision
        CHECK (
            formula_revision
            ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT managed_formula_shadow_input_schema_revision
        CHECK (input_schema_revision > 0),
    CONSTRAINT managed_formula_shadow_output_unit
        CHECK (length(output_unit) BETWEEN 1 AND 32),
    CONSTRAINT managed_formula_shadow_timezone
        CHECK (
            timezone_name
            ~ '^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$'
        ),
    CONSTRAINT managed_formula_shadow_day_window
        CHECK (day_end_at > day_start_at),
    CONSTRAINT managed_formula_shadow_offset_start
        CHECK (utc_offset_start_minutes BETWEEN -840 AND 840),
    CONSTRAINT managed_formula_shadow_offset_end
        CHECK (utc_offset_end_minutes BETWEEN -840 AND 840),
    CONSTRAINT managed_formula_shadow_source_kind
        CHECK (source_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_formula_shadow_source_revision
        CHECK (
            source_revision
            ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT managed_formula_shadow_calibration_revision
        CHECK (
            calibration_revision IS NULL
            OR calibration_revision
                ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT managed_formula_shadow_input_manifest_digest
        CHECK (input_manifest_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_formula_shadow_input_set_digest
        CHECK (input_set_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_formula_shadow_execution_digest
        CHECK (execution_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_formula_shadow_server_status
        CHECK (server_status IN ('present', 'missing')),
    CONSTRAINT managed_formula_shadow_server_value
        CHECK (
            (server_status = 'present'
                AND server_value BETWEEN '-1e308'::float8 AND '1e308'::float8)
            OR (server_status = 'missing' AND server_value IS NULL)
        ),
    CONSTRAINT managed_formula_shadow_client_status
        CHECK (client_status IN ('present', 'missing', 'not_supplied')),
    CONSTRAINT managed_formula_shadow_client_value
        CHECK (
            (client_status = 'present'
                AND client_value BETWEEN '-1e308'::float8 AND '1e308'::float8
                AND client_formula_revision IS NOT NULL)
            OR (client_status = 'missing'
                AND client_value IS NULL
                AND client_formula_revision IS NOT NULL)
            OR (client_status = 'not_supplied'
                AND client_value IS NULL
                AND client_formula_revision IS NULL)
        ),
    CONSTRAINT managed_formula_shadow_client_revision
        CHECK (
            client_formula_revision IS NULL
            OR client_formula_revision
                ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT managed_formula_shadow_parity_status
        CHECK (
            parity_status IN (
                'match',
                'mismatch',
                'both_missing',
                'server_missing',
                'client_missing',
                'not_compared',
                'revision_mismatch'
            )
        ),
    CONSTRAINT managed_formula_shadow_parity_tolerance
        CHECK (
            parity_tolerance BETWEEN 0::float8 AND '1e308'::float8
        ),
    CONSTRAINT managed_formula_shadow_delta
        CHECK (
            absolute_delta IS NULL
            OR absolute_delta BETWEEN 0::float8 AND '1e308'::float8
        ),
    CONSTRAINT managed_formula_shadow_parity_pair
        CHECK (
            (parity_status = 'not_compared'
                AND client_status = 'not_supplied'
                AND absolute_delta IS NULL)
            OR (parity_status = 'revision_mismatch'
                AND client_status <> 'not_supplied'
                AND client_formula_revision <> formula_revision
                AND absolute_delta IS NULL)
            OR (parity_status = 'both_missing'
                AND server_status = 'missing'
                AND client_status = 'missing'
                AND client_formula_revision = formula_revision
                AND absolute_delta IS NULL)
            OR (parity_status = 'server_missing'
                AND server_status = 'missing'
                AND client_status = 'present'
                AND client_formula_revision = formula_revision
                AND absolute_delta IS NULL)
            OR (parity_status = 'client_missing'
                AND server_status = 'present'
                AND client_status = 'missing'
                AND client_formula_revision = formula_revision
                AND absolute_delta IS NULL)
            OR (parity_status = 'match'
                AND server_status = 'present'
                AND client_status = 'present'
                AND client_formula_revision = formula_revision
                AND absolute_delta IS NOT NULL
                AND absolute_delta <= parity_tolerance)
            OR (parity_status = 'mismatch'
                AND server_status = 'present'
                AND client_status = 'present'
                AND client_formula_revision = formula_revision
                AND absolute_delta IS NOT NULL
                AND absolute_delta > parity_tolerance)
        ),
    CONSTRAINT managed_formula_shadow_missing_inputs
        CHECK (
            cardinality(missing_inputs) <= 64
            AND array_position(missing_inputs, NULL) IS NULL
        ),
    CONSTRAINT managed_formula_shadow_publication_kind
        CHECK (publication_kind IN ('shadow', 'rollback')),
    CONSTRAINT managed_formula_shadow_rollback_pair
        CHECK (
            (publication_kind = 'shadow'
                AND rollback_source_result_id IS NULL)
            OR (publication_kind = 'rollback'
                AND rollback_source_result_id IS NOT NULL)
        ),
    CONSTRAINT managed_formula_shadow_superseded_pair
        CHECK (
            (is_current
                AND superseded_by_result_id IS NULL
                AND superseded_at IS NULL)
            OR (NOT is_current
                AND superseded_by_result_id IS NOT NULL
                AND superseded_at IS NOT NULL
                AND superseded_by_result_id <> shadow_result_id
                AND superseded_at >= created_at)
        )
);

ALTER TABLE managed_formula_shadow_results
    ADD CONSTRAINT managed_formula_shadow_superseded_by_fk
    FOREIGN KEY (account_id, superseded_by_result_id)
    REFERENCES managed_formula_shadow_results(account_id, shadow_result_id)
    ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED,
    ADD CONSTRAINT managed_formula_shadow_rollback_source_fk
    FOREIGN KEY (account_id, rollback_source_result_id)
    REFERENCES managed_formula_shadow_results(account_id, shadow_result_id)
    ON DELETE RESTRICT;

CREATE UNIQUE INDEX managed_formula_shadow_current_idx
    ON managed_formula_shadow_results (account_id, local_day, metric_key)
    WHERE is_current;

CREATE INDEX managed_formula_shadow_history_idx
    ON managed_formula_shadow_results (
        account_id,
        metric_key,
        local_day,
        created_at DESC,
        shadow_result_id DESC
    );

CREATE INDEX managed_formula_shadow_parity_idx
    ON managed_formula_shadow_results (
        formula_revision,
        parity_status,
        created_at DESC
    );
