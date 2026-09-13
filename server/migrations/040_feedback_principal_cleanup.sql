-- Expand the immutable feedback schema without renaming or removing the
-- subject-only identity contract used by the previous server revision.
-- Existing and old-revision rows are principal version 0; new revisions also
-- store a tenant-aware principal while continuing to write subject_hash.

ALTER TABLE feedback_reports
    ADD COLUMN principal_hash_version smallint,
    ADD COLUMN principal_hash char(64),
    ADD COLUMN cleanup_phase text,
    ADD COLUMN object_absence_confirmed_at timestamptz;

UPDATE feedback_reports
SET principal_hash_version = 0,
    principal_hash = subject_hash,
    upload_expires_at = LEAST(upload_expires_at, retained_until),
    cleanup_after = CASE
        WHEN status IN ('reserved', 'rejected', 'deleting')
            THEN LEAST(
                retained_until,
                GREATEST(
                    COALESCE(cleanup_after, upload_expires_at),
                    upload_expires_at
                )
            )
        ELSE NULL
    END,
    cleanup_phase = CASE
        WHEN status IN ('reserved', 'rejected', 'deleting')
            THEN 'delete_pending'
        ELSE NULL
    END,
    cleanup_claimed_at = CASE
        WHEN status IN ('reserved', 'rejected', 'deleting')
            THEN cleanup_claimed_at
        ELSE NULL
    END;

-- Old application revisions omit the new principal and cleanup columns. This
-- trigger derives those values before constraints run, while new revisions
-- dual-write the legacy and tenant-aware identity representations explicitly.
CREATE OR REPLACE FUNCTION noop_feedback_report_compatibility()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.principal_hash_version IS NULL AND NEW.principal_hash IS NULL THEN
        NEW.principal_hash_version := 0;
        NEW.principal_hash := NEW.subject_hash;
    ELSIF NEW.principal_hash_version IS NULL OR NEW.principal_hash IS NULL THEN
        RAISE EXCEPTION 'feedback principal identity is incomplete'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.principal_hash_version = 0
       AND NEW.principal_hash IS DISTINCT FROM NEW.subject_hash
    THEN
        RAISE EXCEPTION 'legacy feedback principal must match subject_hash'
            USING ERRCODE = '23514';
    END IF;

    NEW.upload_expires_at := LEAST(
        NEW.upload_expires_at,
        NEW.retained_until
    );

    IF NEW.status IN ('sent', 'deleted') THEN
        NEW.cleanup_after := NULL;
        NEW.cleanup_phase := NULL;
        IF TG_OP = 'INSERT' THEN
            NEW.cleanup_claimed_at := NULL;
        ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
            NEW.cleanup_claimed_at := NULL;
        END IF;
    ELSIF NEW.status = 'rejected'
          AND NEW.cleanup_after IS NULL
          AND NEW.cleanup_claimed_at IS NULL
    THEN
        -- The previous cleanup worker left rejected tombstones in this shape
        -- after deleting their object.
        NEW.cleanup_phase := NULL;
    ELSIF NEW.cleanup_phase = 'confirm_absent' THEN
        -- Confirmation may intentionally occur after the retention timestamp;
        -- metadata remains protected while cleanup_phase is populated.
        NEW.cleanup_after := GREATEST(
            COALESCE(NEW.cleanup_after, NEW.upload_expires_at),
            NEW.upload_expires_at
        );
    ELSE
        NEW.cleanup_after := LEAST(
            NEW.retained_until,
            GREATEST(
                COALESCE(NEW.cleanup_after, NEW.upload_expires_at),
                NEW.upload_expires_at
            )
        );
        NEW.cleanup_phase := 'delete_pending';
    END IF;

    RETURN NEW;
END
$function$;

CREATE TRIGGER feedback_report_compatibility
BEFORE INSERT OR UPDATE ON feedback_reports
FOR EACH ROW
EXECUTE FUNCTION noop_feedback_report_compatibility();

ALTER TABLE feedback_reports
    ALTER COLUMN principal_hash_version SET NOT NULL,
    ALTER COLUMN principal_hash SET NOT NULL;

ALTER TABLE feedback_reports
    DROP CONSTRAINT IF EXISTS feedback_deleting_cleanup_consistent,
    DROP CONSTRAINT IF EXISTS feedback_time_order;

ALTER TABLE feedback_reports
    ADD CONSTRAINT feedback_principal_hash_version_supported
        CHECK (principal_hash_version IN (0, 1)),
    ADD CONSTRAINT feedback_principal_hash_format
        CHECK (principal_hash ~ '^[0-9a-f]{64}$'),
    ADD CONSTRAINT feedback_legacy_principal_consistent
        CHECK (
            principal_hash_version <> 0
            OR principal_hash = subject_hash
        ),
    ADD CONSTRAINT feedback_cleanup_phase_valid
        CHECK (
            cleanup_phase IS NULL
            OR cleanup_phase IN ('delete_pending', 'confirm_absent')
        ),
    ADD CONSTRAINT feedback_time_order
        CHECK (
            upload_expires_at > created_at
            AND upload_expires_at <= retained_until
            AND retained_until > created_at
            AND (completed_at IS NULL OR completed_at >= created_at)
            AND (deleted_at IS NULL OR deleted_at >= created_at)
            AND (
                object_absence_confirmed_at IS NULL
                OR object_absence_confirmed_at >= created_at
            )
            AND (cleanup_after IS NULL OR cleanup_after >= created_at)
            AND (cleanup_claimed_at IS NULL OR cleanup_claimed_at >= created_at)
        ),
    ADD CONSTRAINT feedback_cleanup_consistent
        CHECK (
            (
                status IN ('reserved', 'deleting')
                AND cleanup_after IS NOT NULL
                AND cleanup_phase IS NOT NULL
                AND cleanup_after >= upload_expires_at
            )
            OR (
                status = 'rejected'
                AND (
                    (
                        cleanup_after IS NOT NULL
                        AND cleanup_phase IS NOT NULL
                        AND cleanup_after >= upload_expires_at
                    )
                    OR (
                        cleanup_after IS NULL
                        AND cleanup_phase IS NULL
                    )
                )
            )
            OR (
                status IN ('sent', 'deleted')
                AND cleanup_after IS NULL
                AND cleanup_phase IS NULL
            )
        ),
    ADD CONSTRAINT feedback_cleanup_claim_consistent
        CHECK (
            cleanup_claimed_at IS NULL
            OR cleanup_phase IS NOT NULL
            OR retained_until <= cleanup_claimed_at
        ),
    ADD CONSTRAINT feedback_absence_confirmation_consistent
        CHECK (
            object_absence_confirmed_at IS NULL
            OR (
                cleanup_after IS NULL
                AND cleanup_phase IS NULL
                AND (
                    cleanup_claimed_at IS NULL
                    OR retained_until <= cleanup_claimed_at
                )
            )
        ),
    ADD CONSTRAINT feedback_reports_principal_idempotency_unique
        UNIQUE (
            client_app_id,
            principal_hash_version,
            principal_hash,
            idempotency_hash
        );

-- Keep the legacy subject quota index and uniqueness constraint for the prior
-- revision. New indexes are additive and use distinct names.
CREATE INDEX feedback_reports_cleanup_v2_idx
    ON feedback_reports (cleanup_after, report_id)
    WHERE cleanup_after IS NOT NULL
      AND status IN ('reserved', 'rejected', 'deleting');

CREATE INDEX feedback_reports_principal_quota_idx
    ON feedback_reports (
        client_app_id,
        principal_hash_version,
        principal_hash,
        created_at DESC
    );

CREATE INDEX feedback_reports_app_quota_idx
    ON feedback_reports (client_app_id, created_at DESC);
