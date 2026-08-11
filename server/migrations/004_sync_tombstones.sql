-- A bounded deletion ledger prevents a client retry from immediately recreating
-- an exact batch after retention or explicit erasure. It intentionally stores
-- no device identifier or biometric row, only the batch UUID and canonical
-- payload digest required for replay defense.
CREATE TABLE IF NOT EXISTS sync_batch_tombstones (
    batch_id uuid PRIMARY KEY,
    payload_hash char(64) NOT NULL,
    deleted_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    CONSTRAINT sync_batch_tombstones_expiry_ordered
        CHECK (expires_at > deleted_at)
);

CREATE INDEX IF NOT EXISTS sync_batch_tombstones_payload_hash_idx
    ON sync_batch_tombstones (payload_hash);

CREATE INDEX IF NOT EXISTS sync_batch_tombstones_expiry_idx
    ON sync_batch_tombstones (expires_at);
