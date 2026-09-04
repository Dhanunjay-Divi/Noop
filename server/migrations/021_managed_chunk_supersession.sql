-- A late strap backfill can change an already uploaded fixed-time window.
-- Preserve immutable objects for audit and replay, but expose only the newest
-- validated object for an exact source/class/window tuple in snapshot listings.
-- Change-feed consumers still receive each immutable revision in sequence and
-- deterministically apply the later revision over the same natural keys.

ALTER TABLE managed_chunks
    ADD COLUMN IF NOT EXISTS authoritative_snapshot boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS superseded_by_chunk_id uuid,
    ADD COLUMN IF NOT EXISTS superseded_at timestamptz;

ALTER TABLE managed_chunks
    DROP CONSTRAINT IF EXISTS managed_chunk_superseded_by_fk,
    DROP CONSTRAINT IF EXISTS managed_chunk_superseded_order,
    DROP CONSTRAINT IF EXISTS managed_chunk_superseded_pair,
    DROP CONSTRAINT IF EXISTS managed_chunk_authoritative_mode;

ALTER TABLE managed_chunks
    ADD CONSTRAINT managed_chunk_superseded_by_fk
    FOREIGN KEY (account_id, superseded_by_chunk_id)
    REFERENCES managed_chunks(account_id, chunk_id)
    ON DELETE RESTRICT,
    ADD CONSTRAINT managed_chunk_superseded_order
    CHECK (
        superseded_at IS NULL
        OR (
            available_at IS NOT NULL
            AND superseded_at >= available_at
        )
    ),
    ADD CONSTRAINT managed_chunk_superseded_pair
    CHECK (
        (superseded_by_chunk_id IS NULL AND superseded_at IS NULL)
        OR (
            superseded_by_chunk_id IS NOT NULL
            AND superseded_at IS NOT NULL
            AND superseded_by_chunk_id <> chunk_id
        )
    ),
    ADD CONSTRAINT managed_chunk_authoritative_mode
    CHECK (
        NOT authoritative_snapshot
        OR content_mode = 'server_readable'
    );

CREATE INDEX IF NOT EXISTS managed_chunks_current_window_idx
    ON managed_chunks (
        account_id,
        source_id,
        data_class,
        event_start,
        event_end,
        chunk_id
    )
    WHERE state = 'available'
      AND superseded_by_chunk_id IS NULL;

CREATE INDEX IF NOT EXISTS managed_chunks_superseded_idx
    ON managed_chunks (account_id, superseded_at, chunk_id)
    WHERE superseded_by_chunk_id IS NOT NULL;
