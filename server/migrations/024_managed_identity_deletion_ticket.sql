-- Account erasure is delayed by a cooling-off period, but the managed identity
-- table deliberately stores only a one-way Firebase subject digest. Retain one
-- AEAD-sealed provider deletion ticket on the erasure job until cancellation
-- or verified completion. The plaintext UID never enters PostgreSQL.

ALTER TABLE managed_erasure_jobs
    ADD COLUMN IF NOT EXISTS identity_deletion_ticket bytea;

ALTER TABLE managed_erasure_jobs
    DROP CONSTRAINT IF EXISTS managed_erasure_job_identity_ticket;

ALTER TABLE managed_erasure_jobs
    ADD CONSTRAINT managed_erasure_job_identity_ticket
    CHECK (
        identity_deletion_ticket IS NULL
        OR (
            scope = 'account'
            AND octet_length(identity_deletion_ticket) BETWEEN 29 AND 1024
        )
    );

CREATE INDEX IF NOT EXISTS managed_erasure_jobs_identity_pending_idx
    ON managed_erasure_jobs (requested_at, erasure_job_id)
    WHERE (
        scope = 'account'
        AND status = 'verifying'
        AND identity_deletion_ticket IS NOT NULL
    );
