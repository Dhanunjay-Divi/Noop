-- Safety credential lifecycle and retention support.

ALTER TABLE safety_profiles
    ADD COLUMN IF NOT EXISTS token_version bigint NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS last_rotation_id uuid,
    ADD COLUMN IF NOT EXISTS last_rotation_token_hash char(64);

ALTER TABLE safety_profiles
    DROP CONSTRAINT IF EXISTS safety_profile_token_version_positive;

ALTER TABLE safety_profiles
    ADD CONSTRAINT safety_profile_token_version_positive
        CHECK (token_version > 0);

ALTER TABLE safety_profiles
    DROP CONSTRAINT IF EXISTS safety_profile_rotation_pair;

ALTER TABLE safety_profiles
    ADD CONSTRAINT safety_profile_rotation_pair
        CHECK (
            (last_rotation_id IS NULL AND last_rotation_token_hash IS NULL)
            OR
            (last_rotation_id IS NOT NULL
             AND last_rotation_token_hash IS NOT NULL)
        );

CREATE INDEX IF NOT EXISTS safety_dispatches_retention_idx
    ON safety_dispatches (completed_at, dispatch_id)
    WHERE status IN ('resolved', 'cancelled', 'expired', 'failed');

CREATE INDEX IF NOT EXISTS safety_contacts_retention_idx
    ON safety_contacts (
        COALESCE(revoked_at, declined_at, invite_expires_at),
        contact_id
    )
    WHERE status IN ('pending', 'declined', 'revoked');

-- Retiring the incident row must not make an old Idempotency-Key reusable.
-- The short tombstone contains no contact, location, or delivery data.
CREATE TABLE IF NOT EXISTS safety_dispatch_tombstones (
    profile_id uuid NOT NULL
        REFERENCES safety_profiles(profile_id) ON DELETE CASCADE,
    idempotency_key uuid NOT NULL,
    request_hash char(64) NOT NULL,
    retired_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (profile_id, idempotency_key),
    CONSTRAINT safety_dispatch_tombstone_expiry
        CHECK (expires_at > retired_at)
);

CREATE INDEX IF NOT EXISTS safety_dispatch_tombstones_expiry_idx
    ON safety_dispatch_tombstones (expires_at, profile_id, idempotency_key);
