-- Expand the managed-document registry without changing the accepted payload
-- modes. The stricter privacy contract cannot be installed safely until every
-- supported client can encrypt, restore, and re-upload each non-day document.
-- Migration 035 therefore inventories readiness without mutating user data.

CREATE OR REPLACE FUNCTION noop_managed_day_ownership_payload_valid(
    selected_payload jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $function$
DECLARE
    selected_key jsonb;
    selected_record jsonb;
    key_day text;
    record_day text;
    device_id text;
    locked_value jsonb;
BEGIN
    IF jsonb_typeof(selected_payload) <> 'object'
       OR NOT selected_payload ?& ARRAY[
            'schema_version',
            'table',
            'key',
            'record'
       ]
       OR selected_payload - ARRAY[
            'schema_version',
            'table',
            'key',
            'record'
       ] <> '{}'::jsonb
       OR jsonb_typeof(selected_payload -> 'schema_version') <> 'number'
       OR selected_payload ->> 'schema_version' <> '1'
       OR jsonb_typeof(selected_payload -> 'table') <> 'string'
       OR selected_payload ->> 'table' <> 'dayOwnership'
    THEN
        RETURN false;
    END IF;

    selected_key := selected_payload -> 'key';
    selected_record := selected_payload -> 'record';
    IF jsonb_typeof(selected_key) <> 'object'
       OR NOT selected_key ? 'day'
       OR selected_key - 'day' <> '{}'::jsonb
       OR jsonb_typeof(selected_key -> 'day') <> 'string'
       OR jsonb_typeof(selected_record) <> 'object'
       OR NOT selected_record ?& ARRAY['day', 'deviceId', 'locked']
       OR selected_record - ARRAY['day', 'deviceId', 'locked'] <> '{}'::jsonb
       OR jsonb_typeof(selected_record -> 'day') <> 'string'
       OR jsonb_typeof(selected_record -> 'deviceId') <> 'string'
    THEN
        RETURN false;
    END IF;

    key_day := selected_key ->> 'day';
    record_day := selected_record ->> 'day';
    IF key_day <> record_day
       OR key_day !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'
    THEN
        RETURN false;
    END IF;
    BEGIN
        IF to_char(key_day::date, 'YYYY-MM-DD') <> key_day THEN
            RETURN false;
        END IF;
    EXCEPTION
        WHEN invalid_datetime_format OR datetime_field_overflow THEN
            RETURN false;
    END;

    device_id := selected_record ->> 'deviceId';
    IF octet_length(device_id) NOT BETWEEN 1 AND 256
       OR device_id <> btrim(device_id)
       OR device_id ~ '^[[:space:]]'
       OR device_id ~ '[[:space:]]$'
       OR device_id ~ '[[:cntrl:]]'
    THEN
        RETURN false;
    END IF;

    locked_value := selected_record -> 'locked';
    IF NOT (
        (
            jsonb_typeof(locked_value) = 'boolean'
            AND locked_value::text IN ('true', 'false')
        )
        OR (
            jsonb_typeof(locked_value) = 'number'
            AND locked_value::text IN ('0', '1')
        )
    ) THEN
        RETURN false;
    END IF;

    RETURN true;
END
$function$;

DO $managed_document_contract_v2_add$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'managed_document_kind_v2'
          AND conrelid = 'managed_documents'::regclass
    ) THEN
        ALTER TABLE managed_documents
            ADD CONSTRAINT managed_document_kind_v2
            CHECK (
                document_kind IN (
                    'automation',
                    'caffeine',
                    'coach_history',
                    'coach_memory',
                    'cycle',
                    'day_ownership',
                    'device_registry',
                    'dismissal',
                    'hydration',
                    'journal',
                    'lab_marker',
                    'medication',
                    'mood',
                    'notification_settings',
                    'nutrition',
                    'nutrition_catalog',
                    'other',
                    'preferences',
                    'profile',
                    'strength_log',
                    'strength_plan',
                    'user_marker',
                    'workout_plan'
                )
            ) NOT VALID;
    END IF;

END
$managed_document_contract_v2_add$;
