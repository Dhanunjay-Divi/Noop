-- Keep the 45-day feedback idempotency lifetime duration-exact across daylight
-- saving transitions. PostgreSQL calendar-day intervals preserve local wall
-- time for timestamptz values and can otherwise add or remove one real hour.
--
-- The repository runs each migration in one transaction. Repair existing rows
-- before taking the final writer fence so the migration never performs an
-- unbounded row rewrite while holding ACCESS EXCLUSIVE. UTC makes the legacy
-- validated calendar-duration constraint compatible with the exact repair.

SET LOCAL TIME ZONE 'UTC';

CREATE OR REPLACE FUNCTION noop_feedback_tombstone_normalize_expiry()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.expires_at := NEW.reserved_at + INTERVAL '1080 hours';
    RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION noop_feedback_report_retire_idempotency()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF OLD.created_at + INTERVAL '1080 hours' > CURRENT_TIMESTAMP THEN
        INSERT INTO feedback_idempotency_tombstones (
            client_app_id,
            principal_hash_version,
            principal_hash,
            idempotency_hash,
            reserved_at,
            expires_at
        )
        VALUES (
            OLD.client_app_id,
            COALESCE(OLD.principal_hash_version, 0),
            COALESCE(OLD.principal_hash, OLD.subject_hash),
            OLD.idempotency_hash,
            OLD.created_at,
            OLD.created_at + INTERVAL '1080 hours'
        )
        ON CONFLICT (
            client_app_id,
            principal_hash_version,
            principal_hash,
            idempotency_hash
        ) DO NOTHING;
    END IF;
    RETURN OLD;
END
$function$;

DO $repair$
DECLARE
    repaired_rows integer;
BEGIN
    LOOP
        WITH repair_batch AS MATERIALIZED (
            SELECT ctid
            FROM feedback_idempotency_tombstones
            WHERE expires_at IS DISTINCT FROM
                    reserved_at + INTERVAL '1080 hours'
            ORDER BY
                expires_at,
                client_app_id,
                principal_hash,
                idempotency_hash
            FOR UPDATE SKIP LOCKED
            LIMIT 256
        )
        UPDATE feedback_idempotency_tombstones AS tombstone
        SET expires_at = tombstone.reserved_at + INTERVAL '1080 hours'
        FROM repair_batch
        WHERE tombstone.ctid = repair_batch.ctid;

        GET DIAGNOSTICS repaired_rows = ROW_COUNT;
        EXIT WHEN repaired_rows = 0;
    END LOOP;
END
$repair$;

-- Stop old writers and row-locking readers only after the initial repair.
-- EXCLUSIVE still permits ordinary reads, but it waits for both UPDATE/INSERT
-- writers and SELECT FOR UPDATE readers. Once granted, the final catch-up can
-- no longer skip a legacy-duration row held by an earlier transaction.
LOCK TABLE feedback_idempotency_tombstones
IN EXCLUSIVE MODE;

DROP TRIGGER IF EXISTS feedback_tombstone_normalize_expiry
ON feedback_idempotency_tombstones;

CREATE TRIGGER feedback_tombstone_normalize_expiry
BEFORE INSERT OR UPDATE OF reserved_at, expires_at
ON feedback_idempotency_tombstones
FOR EACH ROW
EXECUTE FUNCTION noop_feedback_tombstone_normalize_expiry();

DO $repair$
DECLARE
    repaired_rows integer;
BEGIN
    LOOP
        WITH repair_batch AS MATERIALIZED (
            SELECT ctid
            FROM feedback_idempotency_tombstones
            WHERE expires_at IS DISTINCT FROM
                    reserved_at + INTERVAL '1080 hours'
            ORDER BY
                expires_at,
                client_app_id,
                principal_hash,
                idempotency_hash
            FOR UPDATE
            LIMIT 256
        )
        UPDATE feedback_idempotency_tombstones AS tombstone
        SET expires_at = tombstone.reserved_at + INTERVAL '1080 hours'
        FROM repair_batch
        WHERE tombstone.ctid = repair_batch.ctid;

        GET DIAGNOSTICS repaired_rows = ROW_COUNT;
        EXIT WHEN repaired_rows = 0;
    END LOOP;
END
$repair$;

DO $verify$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM feedback_idempotency_tombstones
        WHERE expires_at IS DISTINCT FROM
                reserved_at + INTERVAL '1080 hours'
        LIMIT 1
    ) THEN
        RAISE EXCEPTION
            'feedback tombstone exact-duration repair did not converge';
    END IF;
END
$verify$;

-- Add and validate the replacement before removing the legacy check so there
-- is never a constraint-validation gap. The row repair is already complete;
-- the remaining ACCESS EXCLUSIVE work is catalog replacement and validation.
ALTER TABLE feedback_idempotency_tombstones
ADD CONSTRAINT feedback_tombstone_time_order_v2
CHECK (
    expires_at = reserved_at + INTERVAL '1080 hours'
    AND expires_at > reserved_at
) NOT VALID;

ALTER TABLE feedback_idempotency_tombstones
VALIDATE CONSTRAINT feedback_tombstone_time_order_v2;

ALTER TABLE feedback_idempotency_tombstones
DROP CONSTRAINT feedback_tombstone_time_order;

ALTER TABLE feedback_idempotency_tombstones
RENAME CONSTRAINT feedback_tombstone_time_order_v2
TO feedback_tombstone_time_order;
