-- Retire feedback idempotency keys after report metadata is removed. Only
-- tenant/principal/key hashes and bounded lifecycle timestamps remain.
-- A conservative 45-day total lifetime from server reservation exceeds the
-- client's maximum 29-day, 5-minute automatic continuity horizon without
-- retaining another 45 days after report deletion.

CREATE TABLE feedback_idempotency_tombstones (
    client_app_id text NOT NULL,
    principal_hash_version smallint NOT NULL,
    principal_hash char(64) NOT NULL,
    idempotency_hash char(64) NOT NULL,
    reserved_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    CONSTRAINT feedback_tombstone_client_app_id_bounded
        CHECK (char_length(client_app_id) BETWEEN 8 AND 256),
    CONSTRAINT feedback_tombstone_principal_version_supported
        CHECK (principal_hash_version IN (0, 1)),
    CONSTRAINT feedback_tombstone_principal_hash_format
        CHECK (principal_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT feedback_tombstone_idempotency_hash_format
        CHECK (idempotency_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT feedback_tombstone_time_order
        CHECK (
            expires_at = reserved_at + INTERVAL '45 days'
            AND expires_at > reserved_at
        ),
    PRIMARY KEY (
        client_app_id,
        principal_hash_version,
        principal_hash,
        idempotency_hash
    )
);

CREATE INDEX feedback_idempotency_tombstones_expiry_idx
    ON feedback_idempotency_tombstones (
        expires_at,
        client_app_id,
        principal_hash,
        idempotency_hash
    );

-- Keep mixed-version cleanup safe. A worker from the previous revision can
-- still issue a direct DELETE without the application-side retirement CTE.
-- The database is the final boundary: every report deletion preserves only
-- the bounded hash tuple for the remainder of the original 45-day lifetime.
CREATE OR REPLACE FUNCTION noop_feedback_report_retire_idempotency()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF OLD.created_at + INTERVAL '45 days' > CURRENT_TIMESTAMP THEN
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
            OLD.created_at + INTERVAL '45 days'
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

CREATE TRIGGER feedback_report_retire_idempotency
BEFORE DELETE ON feedback_reports
FOR EACH ROW
EXECUTE FUNCTION noop_feedback_report_retire_idempotency();
