-- Bounded lifecycle indexes for the NOOP+ control plane. Object payloads live
-- in Cloud Storage; these indexes keep scheduled cleanup proportional to each
-- maintenance batch rather than to total account history.

ALTER TABLE managed_export_jobs
    DROP CONSTRAINT IF EXISTS managed_export_job_status;

ALTER TABLE managed_export_jobs
    ADD CONSTRAINT managed_export_job_status
    CHECK (
        status IN (
            'queued',
            'running',
            'completed',
            'failed',
            'canceled',
            'expired'
        )
    );

CREATE INDEX IF NOT EXISTS managed_chunks_deleted_cleanup_idx
    ON managed_chunks (deleted_at, chunk_id)
    WHERE state = 'deleted';

CREATE INDEX IF NOT EXISTS managed_processing_attempts_finished_idx
    ON managed_processing_attempts (finished_at, processing_attempt_id)
    WHERE finished_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS managed_documents_history_cleanup_idx
    ON managed_documents (updated_at, account_id, document_kind, document_id)
    WHERE deleted_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS managed_restore_jobs_expiry_idx
    ON managed_restore_jobs (expires_at, restore_job_id)
    WHERE status IN ('queued', 'running', 'completed', 'failed', 'canceled');

CREATE INDEX IF NOT EXISTS managed_export_jobs_lifecycle_idx
    ON managed_export_jobs (expires_at, export_job_id)
    WHERE status IN ('queued', 'running', 'completed', 'failed', 'canceled');
