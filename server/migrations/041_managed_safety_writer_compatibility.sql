-- Keep migration-first deployment and application rollback compatible with
-- the pre-038 Safety writer, which omits quota-event trigger. The referenced
-- incident remains the authoritative trigger source; no default is invented.

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
    WHERE incident.incident_id = NEW.incident_id;

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
