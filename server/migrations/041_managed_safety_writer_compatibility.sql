-- Keep migration-first deployment compatible with the pre-038 Safety writer,
-- which omits quota-event trigger. The referenced incident remains the
-- authoritative trigger source; no default is invented. Runtime rollback uses
-- a forward-built image that retains the current immutable migration manifest.

ALTER TABLE managed_safety_page_quota_events
    ALTER COLUMN trigger DROP NOT NULL;

ALTER TABLE managed_safety_page_quota_events
    ALTER COLUMN trigger DROP DEFAULT;

CREATE OR REPLACE FUNCTION noop_managed_safety_quota_incident_consistent()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    incident_trigger text;
    incident_account_id uuid;
BEGIN
    SELECT incident.trigger, owner.account_id
    INTO incident_trigger, incident_account_id
    FROM managed_safety_incidents incident
    JOIN managed_social_profiles owner
      ON owner.profile_id = incident.owner_profile_id
    WHERE incident.incident_id = NEW.incident_id
    FOR SHARE OF incident;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'managed Safety quota incident was not found'
            USING ERRCODE = '23503';
    END IF;
    IF NEW.trigger IS NULL THEN
        NEW.trigger := incident_trigger;
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

-- Incident ownership and trigger provenance never have a valid mutable state.
-- Rejecting every later change removes the write-skew window that existed when
-- the trigger first checked for a concurrently inserted quota row.
CREATE OR REPLACE FUNCTION noop_managed_safety_incident_quota_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.owner_profile_id IS DISTINCT FROM OLD.owner_profile_id
       OR NEW.trigger IS DISTINCT FROM OLD.trigger
    THEN
        RAISE EXCEPTION 'managed Safety incident quota provenance is immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;
