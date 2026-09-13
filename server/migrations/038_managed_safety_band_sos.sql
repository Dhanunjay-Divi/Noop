-- Route an explicitly enabled band SOS gesture through the managed in-app
-- Safety network. SMS/voice paging remains a separate fallback system.
--
-- Build and validate replacement constraints before swapping names so existing
-- incident and quota writes are not held behind a table scan under the final
-- constraint replacement lock.

ALTER TABLE managed_safety_incidents
    ADD CONSTRAINT managed_safety_incident_trigger_v2
        CHECK (trigger IN ('manual_sos', 'band_sos')) NOT VALID;

ALTER TABLE managed_safety_page_quota_events
    ADD COLUMN IF NOT EXISTS trigger text;

DO $block$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM managed_safety_page_quota_events quota
        JOIN managed_safety_incidents incident
          ON incident.incident_id = quota.incident_id
        JOIN managed_social_profiles owner
          ON owner.profile_id = incident.owner_profile_id
        WHERE quota.owner_account_id IS DISTINCT FROM owner.account_id
    ) THEN
        RAISE EXCEPTION
            'managed Safety quota owner does not match incident owner account'
            USING ERRCODE = '23514';
    END IF;
END
$block$;

UPDATE managed_safety_page_quota_events quota
SET trigger = incident.trigger
FROM managed_safety_incidents incident
WHERE incident.incident_id = quota.incident_id
  AND quota.trigger IS DISTINCT FROM incident.trigger;

-- Migration 030 intentionally retains quota rows after incident/profile
-- deletion. Those historical rows predate band SOS, so the only valid
-- classification for a trigger that could not be recovered is manual_sos.
UPDATE managed_safety_page_quota_events
SET trigger = 'manual_sos'
WHERE trigger IS NULL;

ALTER TABLE managed_safety_page_quota_events
    ADD CONSTRAINT managed_safety_page_quota_trigger_required_v2
        CHECK (trigger IS NOT NULL) NOT VALID;

ALTER TABLE managed_safety_page_quota_events
    ADD CONSTRAINT managed_safety_page_quota_trigger_v2
        CHECK (trigger IN ('manual_sos', 'band_sos')) NOT VALID;

ALTER TABLE managed_safety_incidents
    VALIDATE CONSTRAINT managed_safety_incident_trigger_v2;

ALTER TABLE managed_safety_page_quota_events
    VALIDATE CONSTRAINT managed_safety_page_quota_trigger_required_v2;

ALTER TABLE managed_safety_page_quota_events
    VALIDATE CONSTRAINT managed_safety_page_quota_trigger_v2;

ALTER TABLE managed_safety_page_quota_events
    ALTER COLUMN trigger SET NOT NULL;

-- A default would silently misclassify a future writer that forgot the new
-- column. New quota writes must provide the incident trigger explicitly.
ALTER TABLE managed_safety_page_quota_events
    ALTER COLUMN trigger DROP DEFAULT;

ALTER TABLE managed_safety_incidents
    DROP CONSTRAINT managed_safety_incident_trigger;

ALTER TABLE managed_safety_incidents
    RENAME CONSTRAINT managed_safety_incident_trigger_v2
        TO managed_safety_incident_trigger;

ALTER TABLE managed_safety_page_quota_events
    DROP CONSTRAINT IF EXISTS managed_safety_page_quota_trigger;

ALTER TABLE managed_safety_page_quota_events
    RENAME CONSTRAINT managed_safety_page_quota_trigger_v2
        TO managed_safety_page_quota_trigger;

ALTER TABLE managed_safety_page_quota_events
    DROP CONSTRAINT managed_safety_page_quota_trigger_required_v2;

CREATE OR REPLACE FUNCTION noop_managed_safety_quota_incident_consistent()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    incident_trigger text;
    incident_account_id uuid;
BEGIN
    -- Leave omitted values to the explicit NOT NULL contract. This preserves a
    -- clear writer failure instead of silently inventing manual_sos.
    IF NEW.trigger IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT incident.trigger, owner.account_id
    INTO incident_trigger, incident_account_id
    FROM managed_safety_incidents incident
    JOIN managed_social_profiles owner
      ON owner.profile_id = incident.owner_profile_id
    WHERE incident.incident_id = NEW.incident_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'managed Safety quota incident was not found'
            USING ERRCODE = '23503';
    END IF;
    IF incident_account_id IS DISTINCT FROM NEW.owner_account_id
       OR incident_trigger IS DISTINCT FROM NEW.trigger
    THEN
        RAISE EXCEPTION 'managed Safety quota incident provenance is inconsistent'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS managed_safety_page_quota_incident_consistency
    ON managed_safety_page_quota_events;

CREATE TRIGGER managed_safety_page_quota_incident_consistency
BEFORE INSERT OR UPDATE OF owner_account_id, incident_id, trigger
ON managed_safety_page_quota_events
FOR EACH ROW
EXECUTE FUNCTION noop_managed_safety_quota_incident_consistent();

CREATE OR REPLACE FUNCTION noop_managed_safety_incident_quota_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.owner_profile_id IS DISTINCT FROM OLD.owner_profile_id
       OR NEW.trigger IS DISTINCT FROM OLD.trigger
    THEN
        IF EXISTS (
            SELECT 1
            FROM managed_safety_page_quota_events quota
            WHERE quota.incident_id = OLD.incident_id
        ) THEN
            RAISE EXCEPTION 'managed Safety incident quota provenance is immutable'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS managed_safety_incident_quota_immutability
    ON managed_safety_incidents;

CREATE TRIGGER managed_safety_incident_quota_immutability
BEFORE UPDATE OF owner_profile_id, trigger
ON managed_safety_incidents
FOR EACH ROW
EXECUTE FUNCTION noop_managed_safety_incident_quota_immutable();

CREATE OR REPLACE FUNCTION noop_managed_social_profile_account_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.account_id IS DISTINCT FROM OLD.account_id THEN
        RAISE EXCEPTION 'managed social profile account ownership is immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS managed_social_profile_account_immutability
    ON managed_social_profiles;

CREATE TRIGGER managed_social_profile_account_immutability
BEFORE UPDATE OF account_id
ON managed_social_profiles
FOR EACH ROW
EXECUTE FUNCTION noop_managed_social_profile_account_immutable();
