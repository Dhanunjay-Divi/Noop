-- Keep the installation-ownership invariant true after migration 010. A
-- single-owner deployment may continue writing devices and profiles before a
-- later shared-mode cutover; those rows need deterministic, non-authenticatable
-- placeholder credentials just like rows that existed when migration 010 ran.

CREATE OR REPLACE FUNCTION noop_ensure_legacy_installation(
    requested_installation_id text
) RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    IF requested_installation_id IS NULL
       OR requested_installation_id
          !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' THEN
        RAISE EXCEPTION 'invalid installation identifier for tenancy ownership'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO installation_credentials (
        installation_id,
        enrollment_id,
        token_hash,
        created_at,
        updated_at
    ) VALUES (
        requested_installation_id,
        md5(
            'noop-legacy-enrollment:' || requested_installation_id
        )::uuid,
        encode(
            sha256(
                convert_to(
                    'noop-legacy-unusable-credential:'
                    || requested_installation_id,
                    'UTF8'
                )
            ),
            'hex'
        ),
        clock_timestamp(),
        clock_timestamp()
    )
    ON CONFLICT (installation_id) DO NOTHING;
END
$function$;

CREATE OR REPLACE FUNCTION noop_maintain_device_installation_owner()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    requested_installation_id text;
BEGIN
    requested_installation_id := split_part(NEW.device_id, ':', 2);
    PERFORM noop_ensure_legacy_installation(requested_installation_id);
    INSERT INTO installation_devices (
        device_id,
        installation_id,
        claimed_at
    ) VALUES (
        NEW.device_id,
        requested_installation_id,
        clock_timestamp()
    )
    ON CONFLICT (device_id) DO NOTHING;
    RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION noop_maintain_profile_installation_owner()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM noop_ensure_legacy_installation(NEW.installation_id);
    RETURN NEW;
END
$function$;

-- Close the window between migrations 010 and 012 before installing triggers.
SELECT noop_ensure_legacy_installation(installation_id)
FROM (
    SELECT DISTINCT split_part(device_id, ':', 2) AS installation_id
    FROM devices
    UNION
    SELECT DISTINCT installation_id FROM friend_profiles
    UNION
    SELECT DISTINCT installation_id FROM safety_profiles
) AS existing_installations;

INSERT INTO installation_devices (device_id, installation_id, claimed_at)
SELECT device_id, split_part(device_id, ':', 2), clock_timestamp()
FROM devices
ON CONFLICT (device_id) DO NOTHING;

DROP TRIGGER IF EXISTS devices_maintain_installation_owner ON devices;
CREATE TRIGGER devices_maintain_installation_owner
AFTER INSERT ON devices
FOR EACH ROW
EXECUTE FUNCTION noop_maintain_device_installation_owner();

DROP TRIGGER IF EXISTS friend_profiles_maintain_installation_owner
    ON friend_profiles;
CREATE TRIGGER friend_profiles_maintain_installation_owner
BEFORE INSERT ON friend_profiles
FOR EACH ROW
EXECUTE FUNCTION noop_maintain_profile_installation_owner();

DROP TRIGGER IF EXISTS safety_profiles_maintain_installation_owner
    ON safety_profiles;
CREATE TRIGGER safety_profiles_maintain_installation_owner
BEFORE INSERT ON safety_profiles
FOR EACH ROW
EXECUTE FUNCTION noop_maintain_profile_installation_owner();
