-- Production paging reliability and observability.
--
-- Existing migration checksums remain immutable. An untouched paging control
-- from migration 008 is moved to a fail-closed state; controls that an operator
-- has already revised retain their explicit state.

ALTER TABLE safety_runtime_control_audit
    ADD COLUMN IF NOT EXISTS actor text,
    ADD COLUMN IF NOT EXISTS request_id uuid;

UPDATE safety_runtime_control_audit
SET actor = 'legacy-migration'
WHERE actor IS NULL;

ALTER TABLE safety_runtime_control_audit
    ALTER COLUMN actor SET NOT NULL;

ALTER TABLE safety_runtime_control_audit
    DROP CONSTRAINT IF EXISTS safety_runtime_control_audit_actor_length;

ALTER TABLE safety_runtime_control_audit
    ADD CONSTRAINT safety_runtime_control_audit_actor_length
        CHECK (char_length(actor) BETWEEN 1 AND 128);

WITH disabled AS (
    UPDATE safety_runtime_controls
    SET enabled = FALSE,
        reason = 'Awaiting explicit production paging enablement',
        revision = revision + 1,
        updated_at = clock_timestamp()
    WHERE control_name = 'paging'
      AND enabled = TRUE
      AND revision = 1
      AND reason IS NULL
    RETURNING control_name, revision, enabled, reason, updated_at
)
INSERT INTO safety_runtime_control_audit (
    control_name, revision, enabled, reason, changed_at, actor, request_id
)
SELECT control_name, revision, enabled, reason, updated_at,
       'migration-009', NULL
FROM disabled
ON CONFLICT (control_name, revision) DO NOTHING;

ALTER TABLE safety_worker_heartbeats
    ADD COLUMN IF NOT EXISTS worker_version text NOT NULL DEFAULT 'legacy';

ALTER TABLE safety_worker_heartbeats
    DROP CONSTRAINT IF EXISTS safety_worker_version_length;

ALTER TABLE safety_worker_heartbeats
    ADD CONSTRAINT safety_worker_version_length
        CHECK (char_length(worker_version) BETWEEN 1 AND 64);

CREATE TABLE IF NOT EXISTS safety_invitation_jobs (
    contact_id uuid PRIMARY KEY
        REFERENCES safety_contacts(contact_id) ON DELETE CASCADE,
    invitation_nonce uuid NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    available_at timestamptz NOT NULL,
    lease_owner text,
    lease_expires_at timestamptz,
    active_attempt_id uuid,
    attempt_count integer NOT NULL DEFAULT 0,
    max_attempts integer NOT NULL DEFAULT 3,
    provider_reference text,
    error text,
    last_attempt_at timestamptz,
    terminal_at timestamptz,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CONSTRAINT safety_invitation_job_status
        CHECK (
            status IN (
                'pending', 'leased', 'retry_wait', 'queued', 'sent',
                'delivered', 'failed', 'cancelled', 'unknown'
            )
        ),
    CONSTRAINT safety_invitation_job_attempt_bounds
        CHECK (
            attempt_count >= 0
            AND max_attempts BETWEEN 1 AND 10
            AND attempt_count <= max_attempts
        ),
    CONSTRAINT safety_invitation_job_lease
        CHECK (
            (status = 'leased'
             AND lease_owner IS NOT NULL
             AND lease_expires_at IS NOT NULL
             AND active_attempt_id IS NOT NULL)
            OR
            (status <> 'leased'
             AND lease_owner IS NULL
             AND lease_expires_at IS NULL
             AND active_attempt_id IS NULL)
        )
);

CREATE INDEX IF NOT EXISTS safety_invitation_jobs_due_idx
    ON safety_invitation_jobs (available_at, created_at)
    WHERE status IN ('pending', 'retry_wait');

CREATE INDEX IF NOT EXISTS safety_invitation_jobs_stale_lease_idx
    ON safety_invitation_jobs (lease_expires_at)
    WHERE status = 'leased';

CREATE UNIQUE INDEX IF NOT EXISTS safety_invitation_jobs_provider_reference_idx
    ON safety_invitation_jobs (provider_reference)
    WHERE provider_reference IS NOT NULL;

CREATE TABLE IF NOT EXISTS safety_invitation_attempts (
    attempt_id uuid PRIMARY KEY,
    contact_id uuid NOT NULL
        REFERENCES safety_invitation_jobs(contact_id) ON DELETE CASCADE,
    invitation_nonce uuid NOT NULL,
    attempt_number integer NOT NULL,
    status text NOT NULL DEFAULT 'started',
    provider_reference text,
    error text,
    started_at timestamptz NOT NULL,
    finished_at timestamptz,
    CONSTRAINT safety_invitation_attempt_number CHECK (attempt_number > 0),
    CONSTRAINT safety_invitation_attempt_status
        CHECK (
            status IN (
                'started', 'queued', 'sent', 'delivered', 'failed', 'unknown'
            )
        ),
    UNIQUE (contact_id, invitation_nonce, attempt_number)
);

CREATE UNIQUE INDEX IF NOT EXISTS safety_invitation_attempt_provider_reference_idx
    ON safety_invitation_attempts (provider_reference)
    WHERE provider_reference IS NOT NULL;

CREATE INDEX IF NOT EXISTS safety_contacts_invitation_provider_reference_idx
    ON safety_contacts (invitation_provider_reference)
    WHERE invitation_provider_reference IS NOT NULL;

CREATE TABLE IF NOT EXISTS safety_provider_rate_state (
    provider_name text PRIMARY KEY,
    next_slot_at timestamptz NOT NULL,
    CONSTRAINT safety_provider_rate_name
        CHECK (provider_name IN ('twilio'))
);

INSERT INTO safety_provider_rate_state (provider_name, next_slot_at)
VALUES ('twilio', clock_timestamp())
ON CONFLICT (provider_name) DO NOTHING;

CREATE INDEX IF NOT EXISTS safety_dispatches_status_completed_idx
    ON safety_dispatches (status, completed_at);

CREATE INDEX IF NOT EXISTS safety_deliveries_status_updated_idx
    ON safety_deliveries (status, updated_at);

CREATE INDEX IF NOT EXISTS safety_deliveries_created_idx
    ON safety_deliveries (created_at);

CREATE INDEX IF NOT EXISTS safety_deliveries_delivered_at_idx
    ON safety_deliveries (delivered_at)
    WHERE delivered_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS safety_delivery_attempts_status_finished_idx
    ON safety_delivery_attempts (status, finished_at, started_at);

CREATE INDEX IF NOT EXISTS safety_invitation_jobs_status_updated_idx
    ON safety_invitation_jobs (status, updated_at);

CREATE INDEX IF NOT EXISTS safety_invitation_attempts_status_finished_idx
    ON safety_invitation_attempts (status, finished_at, started_at);
