-- Client-produced exports avoid assembling large health archives in Cloud Run.
-- The control plane records the immutable upload contract and publishes the
-- object only after generation, size, content type, and digest verification.

ALTER TABLE managed_export_jobs
    ADD COLUMN IF NOT EXISTS expected_sha256 char(64),
    ADD COLUMN IF NOT EXISTS expected_bytes bigint,
    ADD COLUMN IF NOT EXISTS content_type text;

ALTER TABLE managed_export_jobs
    DROP CONSTRAINT IF EXISTS managed_export_job_expected_contract;

ALTER TABLE managed_export_jobs
    ADD CONSTRAINT managed_export_job_expected_contract
    CHECK (
        (
            expected_sha256 IS NULL
            AND expected_bytes IS NULL
            AND content_type IS NULL
        )
        OR (
            expected_sha256 ~ '^[0-9a-f]{64}$'
            AND expected_bytes BETWEEN 1 AND 1073741824
            AND content_type IN (
                'application/vnd.noop.backup',
                'application/octet-stream'
            )
        )
    );

CREATE INDEX IF NOT EXISTS managed_export_jobs_delete_idx
    ON managed_export_jobs (expires_at, export_job_id)
    WHERE output_generation IS NOT NULL
      AND status IN ('completed', 'expired');
