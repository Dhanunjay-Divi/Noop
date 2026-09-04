-- A snapshot restore must hand back to the incremental change feed without
-- skipping writes that committed while the snapshot was being enumerated.
-- Capture the account feed high-water mark when the restore job is created;
-- clients advance to it only after every selected snapshot object is applied.

ALTER TABLE managed_restore_jobs
    ADD COLUMN change_sequence bigint NOT NULL DEFAULT 0;

ALTER TABLE managed_restore_jobs
    ADD CONSTRAINT managed_restore_job_change_sequence
    CHECK (change_sequence >= 0);
