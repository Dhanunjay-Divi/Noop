-- Optional shared-server tenancy. The operator credential never owns biometric
-- rows; opaque per-installation credentials claim only device identifiers whose
-- native namespace includes that exact installation identifier.

CREATE TABLE IF NOT EXISTS installation_credentials (
    installation_id text PRIMARY KEY,
    enrollment_id uuid NOT NULL UNIQUE,
    token_hash char(64) NOT NULL UNIQUE,
    token_version bigint NOT NULL DEFAULT 1,
    last_rotation_id uuid,
    last_rotation_token_hash char(64),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    revoked_at timestamptz,
    CONSTRAINT installation_id_format
        CHECK (
            installation_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
        ),
    CONSTRAINT installation_token_version_positive
        CHECK (token_version > 0),
    CONSTRAINT installation_rotation_pair
        CHECK (
            (last_rotation_id IS NULL AND last_rotation_token_hash IS NULL)
            OR
            (last_rotation_id IS NOT NULL AND last_rotation_token_hash IS NOT NULL)
        ),
    CONSTRAINT installation_updated_after_created
        CHECK (updated_at >= created_at),
    CONSTRAINT installation_revoked_after_created
        CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE INDEX IF NOT EXISTS installation_credentials_active_token_idx
    ON installation_credentials (token_hash)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS installation_devices (
    device_id text PRIMARY KEY,
    installation_id text NOT NULL
        REFERENCES installation_credentials(installation_id) ON DELETE CASCADE,
    claimed_at timestamptz NOT NULL,
    CONSTRAINT installation_device_scope
        CHECK (
            split_part(device_id, ':', 1)
                IN ('ios', 'android', 'macos', 'import', 'other')
            AND split_part(device_id, ':', 2) = installation_id
            AND split_part(device_id, ':', 3) <> ''
        )
);

CREATE INDEX IF NOT EXISTS installation_devices_owner_idx
    ON installation_devices (installation_id, device_id);

-- Existing single-owner databases predate installation credentials. Preserve
-- their ownership instead of making data inaccessible when shared mode is
-- enabled. The deterministic token digest has no valid client plaintext; an
-- operator must rotate each legacy credential before distributing it.
DO $legacy_validation$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM devices
        WHERE split_part(device_id, ':', 1)
                  NOT IN ('ios', 'android', 'macos', 'import', 'other')
           OR split_part(device_id, ':', 2)
                  !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
           OR split_part(device_id, ':', 3) = ''
    ) THEN
        RAISE EXCEPTION
            'legacy device identifiers must be <platform>:<installation>:<producer> before tenancy migration';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM friend_profiles
        WHERE installation_id
              !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    ) OR EXISTS (
        SELECT 1
        FROM safety_profiles
        WHERE installation_id
              !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    ) THEN
        RAISE EXCEPTION
            'legacy profile installation identifiers are not valid tenancy identifiers';
    END IF;
END
$legacy_validation$;

WITH legacy_installations AS (
    SELECT DISTINCT split_part(device_id, ':', 2) AS installation_id
    FROM devices
    UNION
    SELECT DISTINCT installation_id FROM friend_profiles
    UNION
    SELECT DISTINCT installation_id FROM safety_profiles
)
INSERT INTO installation_credentials (
    installation_id,
    enrollment_id,
    token_hash,
    created_at,
    updated_at
)
SELECT
    installation_id,
    md5('noop-legacy-enrollment:' || installation_id)::uuid,
    encode(
        sha256(
            convert_to(
                'noop-legacy-unusable-credential:' || installation_id,
                'UTF8'
            )
        ),
        'hex'
    ),
    clock_timestamp(),
    clock_timestamp()
FROM legacy_installations
ON CONFLICT (installation_id) DO NOTHING;

INSERT INTO installation_devices (device_id, installation_id, claimed_at)
SELECT
    device_id,
    split_part(device_id, ':', 2),
    clock_timestamp()
FROM devices
ON CONFLICT (device_id) DO NOTHING;
