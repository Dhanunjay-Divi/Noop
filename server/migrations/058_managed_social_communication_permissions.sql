-- Add recipient-controlled communication capabilities to each directional
-- friendship policy. Existing and new relationships remain denied by default.

ALTER TABLE managed_social_visibility
    ADD COLUMN IF NOT EXISTS messages_allowed boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS photos_allowed boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS audio_calls_allowed boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS video_calls_allowed boolean NOT NULL DEFAULT false;

DO $migration$
DECLARE
    target_table pg_catalog.regclass :=
        'managed_social_visibility'::pg_catalog.regclass;
    communication_column text;
BEGIN
    FOREACH communication_column IN ARRAY ARRAY[
        'messages_allowed',
        'photos_allowed',
        'audio_calls_allowed',
        'video_calls_allowed'
    ]
    LOOP
        PERFORM 1
        FROM pg_catalog.pg_attribute AS attribute
        JOIN pg_catalog.pg_attrdef AS default_value
          ON default_value.adrelid = attribute.attrelid
         AND default_value.adnum = attribute.attnum
        WHERE attribute.attrelid = target_table
          AND attribute.attname = communication_column
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped
          AND attribute.atttypid =
              'pg_catalog.bool'::pg_catalog.regtype
          AND attribute.atttypmod = -1
          AND attribute.attnotnull
          AND attribute.atthasdef
          AND attribute.attgenerated = ''
          AND pg_catalog.pg_get_expr(
              default_value.adbin,
              default_value.adrelid,
              true
          ) = 'false';

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'migration 058 schema validation failed for %.%',
                target_table,
                communication_column
                USING
                    ERRCODE = 'check_violation',
                    HINT = 'Expected boolean NOT NULL DEFAULT false.';
        END IF;
    END LOOP;
END
$migration$;
