-- Preserve the producer and batch identity on every row. Device metadata is a
-- latest-seen summary and is not sufficient evidence when multiple app
-- installations replay the same logical source.

ALTER TABLE metric_samples
    ADD COLUMN IF NOT EXISTS sync_batch_id uuid
        REFERENCES sync_batches(batch_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS source_platform text,
    ADD COLUMN IF NOT EXISTS source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS sync_batch_id uuid
        REFERENCES sync_batches(batch_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS source_platform text,
    ADD COLUMN IF NOT EXISTS source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE daily_metrics
    ADD COLUMN IF NOT EXISTS sync_batch_id uuid
        REFERENCES sync_batches(batch_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS source_platform text,
    ADD COLUMN IF NOT EXISTS source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE sleep_sessions
    ADD COLUMN IF NOT EXISTS sync_batch_id uuid
        REFERENCES sync_batches(batch_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS source_platform text,
    ADD COLUMN IF NOT EXISTS source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE workouts
    ADD COLUMN IF NOT EXISTS sync_batch_id uuid
        REFERENCES sync_batches(batch_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS source_platform text,
    ADD COLUMN IF NOT EXISTS source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE journal_entries
    ADD COLUMN IF NOT EXISTS sync_batch_id uuid
        REFERENCES sync_batches(batch_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS source_platform text,
    ADD COLUMN IF NOT EXISTS source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;
