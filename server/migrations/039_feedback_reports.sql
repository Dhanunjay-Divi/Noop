-- Store only bounded operational metadata for explicitly submitted app reports.
-- Report archives live in a separate private object bucket and are addressed
-- only through server-created keys.

CREATE TABLE feedback_reports (
    report_id uuid PRIMARY KEY,
    client_app_id text NOT NULL,
    subject_hash char(64) NOT NULL,
    idempotency_hash char(64) NOT NULL,
    request_hash char(64) NOT NULL,
    platform text NOT NULL,
    app_version text NOT NULL,
    archive_bytes integer NOT NULL,
    archive_sha256 char(64) NOT NULL,
    includes_user_note boolean NOT NULL,
    includes_screenshot boolean NOT NULL,
    receipt varchar(19) NOT NULL UNIQUE,
    object_key text NOT NULL UNIQUE,
    status text NOT NULL,
    object_generation bigint,
    created_at timestamptz NOT NULL,
    upload_expires_at timestamptz NOT NULL,
    completed_at timestamptz,
    retained_until timestamptz NOT NULL,
    deleted_at timestamptz,
    cleanup_after timestamptz,
    cleanup_claimed_at timestamptz,
    CONSTRAINT feedback_client_app_id_bounded
        CHECK (char_length(client_app_id) BETWEEN 8 AND 256),
    CONSTRAINT feedback_subject_hash_format
        CHECK (subject_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT feedback_idempotency_hash_format
        CHECK (idempotency_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT feedback_request_hash_format
        CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT feedback_platform_valid
        CHECK (platform IN ('ios', 'android')),
    CONSTRAINT feedback_app_version_bounded
        CHECK (
            char_length(app_version) BETWEEN 1 AND 32
            AND app_version ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,31}$'
        ),
    CONSTRAINT feedback_archive_bytes_bounded
        CHECK (archive_bytes BETWEEN 1 AND 20971520),
    CONSTRAINT feedback_archive_sha256_format
        CHECK (archive_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT feedback_receipt_format
        CHECK (receipt ~ '^NF-[A-Z2-7]{16}$'),
    CONSTRAINT feedback_object_key_bounded
        CHECK (
            char_length(object_key) BETWEEN 16 AND 256
            AND object_key ~ '^v1/feedback/[0-9]{4}/[0-9]{2}/[0-9]{2}/[0-9a-f-]{36}\.zip$'
        ),
    CONSTRAINT feedback_status_valid
        CHECK (
            status IN ('reserved', 'sent', 'rejected', 'deleting', 'deleted')
        ),
    CONSTRAINT feedback_generation_positive
        CHECK (object_generation IS NULL OR object_generation > 0),
    CONSTRAINT feedback_time_order
        CHECK (
            upload_expires_at > created_at
            AND retained_until > created_at
            AND (completed_at IS NULL OR completed_at >= created_at)
            AND (deleted_at IS NULL OR deleted_at >= created_at)
            AND (cleanup_after IS NULL OR cleanup_after >= created_at)
            AND (cleanup_claimed_at IS NULL OR cleanup_claimed_at >= created_at)
        ),
    CONSTRAINT feedback_completion_consistent
        CHECK (
            (status = 'sent' AND completed_at IS NOT NULL AND object_generation IS NOT NULL)
            OR status <> 'sent'
        ),
    CONSTRAINT feedback_deleting_cleanup_consistent
        CHECK (
            status NOT IN ('rejected', 'deleting')
            OR (
                cleanup_after IS NOT NULL
                AND cleanup_after >= upload_expires_at
            )
        ),
    UNIQUE (client_app_id, subject_hash, idempotency_hash)
);

CREATE INDEX feedback_reports_retention_idx
    ON feedback_reports (retained_until, report_id);

CREATE INDEX feedback_reports_cleanup_idx
    ON feedback_reports (cleanup_after, report_id)
    WHERE cleanup_after IS NOT NULL
      AND status IN ('rejected', 'deleting');

CREATE INDEX feedback_reports_status_idx
    ON feedback_reports (status, created_at);

CREATE INDEX feedback_reports_subject_quota_idx
    ON feedback_reports (client_app_id, subject_hash, created_at DESC);
