-- Durable execution state for first-party ownership-account deletion targets.
--
-- The immutable rows in migration 043 remain the declaration of required work.
-- This table records bounded worker progress without granting the ownership API
-- access to managed health tables or allowing it to claim destructive success.

CREATE TABLE IF NOT EXISTS ownership_account_deletion_target_progress (
    deletion_request_id uuid NOT NULL,
    target_kind text NOT NULL,
    current_state text NOT NULL,
    blocker text,
    progress_version bigint NOT NULL DEFAULT 0,
    attempt_count integer NOT NULL DEFAULT 0,
    lease_owner uuid,
    lease_expires_at timestamptz,
    retry_after timestamptz,
    managed_erasure_job_id uuid,
    last_error_kind text,
    updated_at timestamptz NOT NULL,
    completed_at timestamptz,
    PRIMARY KEY (deletion_request_id, target_kind),
    CONSTRAINT ownership_account_deletion_progress_target_fk
        FOREIGN KEY (deletion_request_id, target_kind)
        REFERENCES ownership_account_deletion_targets (
            deletion_request_id,
            target_kind
        )
        ON DELETE RESTRICT,
    CONSTRAINT ownership_account_deletion_progress_managed_job_fk
        FOREIGN KEY (managed_erasure_job_id)
        REFERENCES managed_erasure_jobs(erasure_job_id)
        ON DELETE RESTRICT,
    CONSTRAINT ownership_account_deletion_progress_state
        CHECK (
            current_state IN (
                'scheduled',
                'processing',
                'blocked',
                'not_required',
                'completed',
                'failed'
            )
        ),
    CONSTRAINT ownership_account_deletion_progress_blocker
        CHECK (
            blocker IS NULL
            OR blocker IN (
                'policy_unapproved',
                'hardware_capability_unavailable',
                'operator_approval_required',
                'provider_credentials_unavailable',
                'band_retirement_pending',
                'identity_provider_pending',
                'target_dependencies_pending'
            )
        ),
    CONSTRAINT ownership_account_deletion_progress_state_blocker
        CHECK ((current_state = 'blocked') = (blocker IS NOT NULL)),
    CONSTRAINT ownership_account_deletion_progress_attempts
        CHECK (attempt_count BETWEEN 0 AND 20),
    CONSTRAINT ownership_account_deletion_progress_version
        CHECK (progress_version >= 0),
    CONSTRAINT ownership_account_deletion_progress_lease_pair
        CHECK (
            (lease_owner IS NULL AND lease_expires_at IS NULL)
            OR (
                lease_owner IS NOT NULL
                AND lease_expires_at IS NOT NULL
                AND current_state = 'processing'
            )
        ),
    CONSTRAINT ownership_account_deletion_progress_retry_state
        CHECK (retry_after IS NULL OR current_state = 'scheduled'),
    CONSTRAINT ownership_account_deletion_progress_managed_target
        CHECK (
            managed_erasure_job_id IS NULL
            OR target_kind = 'managed_cloud_data'
        ),
    CONSTRAINT ownership_account_deletion_progress_failure_kind
        CHECK (
            last_error_kind IS NULL
            OR last_error_kind IN (
                'managed_account_conflict',
                'managed_erasure_canceled',
                'managed_erasure_failed',
                'managed_erasure_unavailable',
                'invalid_target',
                'retry_exhausted'
            )
        ),
    CONSTRAINT ownership_account_deletion_progress_completion_state
        CHECK (
            (
                current_state IN ('not_required', 'completed', 'failed')
                AND completed_at IS NOT NULL
            )
            OR (
                current_state NOT IN ('not_required', 'completed', 'failed')
                AND completed_at IS NULL
            )
        )
);

CREATE INDEX IF NOT EXISTS ownership_account_deletion_progress_due_idx
    ON ownership_account_deletion_target_progress (
        target_kind,
        current_state,
        retry_after,
        lease_expires_at,
        updated_at
    )
    WHERE current_state IN ('scheduled', 'processing');

CREATE OR REPLACE FUNCTION noop_ownership_account_deletion_progress_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'ownership account deletion progress cannot be deleted'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.deletion_request_id IS DISTINCT FROM OLD.deletion_request_id
       OR NEW.target_kind IS DISTINCT FROM OLD.target_kind
       OR NEW.progress_version < OLD.progress_version
       OR NEW.attempt_count < OLD.attempt_count
       OR (
            OLD.managed_erasure_job_id IS NOT NULL
            AND NEW.managed_erasure_job_id
                IS DISTINCT FROM OLD.managed_erasure_job_id
       )
       OR (
            OLD.current_state IN ('not_required', 'completed', 'failed')
            AND ROW(
                NEW.current_state,
                NEW.blocker,
                NEW.progress_version,
                NEW.attempt_count,
                NEW.lease_owner,
                NEW.lease_expires_at,
                NEW.retry_after,
                NEW.managed_erasure_job_id,
                NEW.last_error_kind,
                NEW.updated_at,
                NEW.completed_at
            ) IS DISTINCT FROM ROW(
                OLD.current_state,
                OLD.blocker,
                OLD.progress_version,
                OLD.attempt_count,
                OLD.lease_owner,
                OLD.lease_expires_at,
                OLD.retry_after,
                OLD.managed_erasure_job_id,
                OLD.last_error_kind,
                OLD.updated_at,
                OLD.completed_at
            )
       ) THEN
        RAISE EXCEPTION 'ownership account deletion progress is immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS ownership_account_deletion_progress_guard
    ON ownership_account_deletion_target_progress;
CREATE TRIGGER ownership_account_deletion_progress_guard
BEFORE UPDATE OR DELETE ON ownership_account_deletion_target_progress
FOR EACH ROW
EXECUTE FUNCTION noop_ownership_account_deletion_progress_guard();

INSERT INTO ownership_account_deletion_target_progress (
    deletion_request_id,
    target_kind,
    current_state,
    blocker,
    updated_at,
    completed_at
)
SELECT target.deletion_request_id,
       target.target_kind,
       CASE target.initial_state
           WHEN 'scheduled' THEN 'scheduled'
           WHEN 'blocked' THEN 'blocked'
           ELSE 'not_required'
       END,
       target.blocker,
       target.scheduled_at,
       CASE
           WHEN target.initial_state = 'not_required'
           THEN target.scheduled_at
           ELSE NULL
       END
FROM ownership_account_deletion_targets target
ON CONFLICT (deletion_request_id, target_kind) DO NOTHING;

CREATE OR REPLACE FUNCTION noop_ownership_account_deletion_progress_seed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
    INSERT INTO public.ownership_account_deletion_target_progress (
        deletion_request_id,
        target_kind,
        current_state,
        blocker,
        updated_at,
        completed_at
    ) VALUES (
        NEW.deletion_request_id,
        NEW.target_kind,
        CASE NEW.initial_state
            WHEN 'scheduled' THEN 'scheduled'
            WHEN 'blocked' THEN 'blocked'
            ELSE 'not_required'
        END,
        NEW.blocker,
        NEW.scheduled_at,
        CASE
            WHEN NEW.initial_state = 'not_required'
            THEN NEW.scheduled_at
            ELSE NULL
        END
    );
    RETURN NEW;
END
$function$;

REVOKE ALL
ON FUNCTION noop_ownership_account_deletion_progress_seed()
FROM PUBLIC;

DROP TRIGGER IF EXISTS ownership_account_deletion_progress_seed
    ON ownership_account_deletion_targets;
CREATE TRIGGER ownership_account_deletion_progress_seed
AFTER INSERT ON ownership_account_deletion_targets
FOR EACH ROW
EXECUTE FUNCTION noop_ownership_account_deletion_progress_seed();
