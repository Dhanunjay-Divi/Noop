-- Durable, acknowledged Safety incidents.
--
-- The incident is the source of truth. Delivery rows are leased jobs, while
-- immutable attempt rows retain provider outcomes across retries. Responder
-- capabilities are HMAC-derived at send time and are never stored.

ALTER TABLE safety_dispatches
    ADD COLUMN IF NOT EXISTS updated_at timestamptz,
    ADD COLUMN IF NOT EXISTS expires_at timestamptz,
    ADD COLUMN IF NOT EXISTS acknowledged_at timestamptz,
    ADD COLUMN IF NOT EXISTS resolved_at timestamptz,
    ADD COLUMN IF NOT EXISTS cancelled_at timestamptz,
    ADD COLUMN IF NOT EXISTS acknowledged_contact_id uuid
        REFERENCES safety_contacts(contact_id) ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS resolution_note text;

-- The legacy constraint does not admit the new incident states, so it must be
-- removed before existing transport-only rows are converted.
ALTER TABLE safety_dispatches
    DROP CONSTRAINT IF EXISTS safety_dispatch_status;

UPDATE safety_dispatches
SET status = 'expired',
    updated_at = COALESCE(completed_at, created_at),
    expires_at = COALESCE(completed_at, created_at) + interval '30 minutes'
WHERE status IN ('pending', 'submitted', 'partial_failure', 'failed');

UPDATE safety_dispatches
SET updated_at = COALESCE(updated_at, created_at),
    expires_at = COALESCE(expires_at, created_at + interval '30 minutes');

ALTER TABLE safety_dispatches
    ALTER COLUMN updated_at SET NOT NULL,
    ALTER COLUMN expires_at SET NOT NULL,
    ADD CONSTRAINT safety_dispatch_status
        CHECK (status IN ('open', 'acknowledged', 'resolved', 'cancelled', 'expired')),
    ADD CONSTRAINT safety_dispatch_expiry
        CHECK (expires_at > created_at),
    ADD CONSTRAINT safety_dispatch_resolution_note_length
        CHECK (resolution_note IS NULL OR char_length(resolution_note) <= 160);

CREATE INDEX IF NOT EXISTS safety_dispatches_open_expiry_idx
    ON safety_dispatches (expires_at)
    WHERE status = 'open';

CREATE UNIQUE INDEX IF NOT EXISTS safety_dispatches_one_active_profile_idx
    ON safety_dispatches (profile_id)
    WHERE status IN ('open', 'acknowledged');

ALTER TABLE safety_deliveries
    ADD COLUMN IF NOT EXISTS available_at timestamptz,
    ADD COLUMN IF NOT EXISTS lease_owner text,
    ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz,
    ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS max_attempts integer NOT NULL DEFAULT 3,
    ADD COLUMN IF NOT EXISTS last_attempt_at timestamptz,
    ADD COLUMN IF NOT EXISTS delivered_at timestamptz,
    ADD COLUMN IF NOT EXISTS terminal_at timestamptz;

-- As above, retry_wait is intentionally absent from the legacy constraint.
ALTER TABLE safety_deliveries
    DROP CONSTRAINT IF EXISTS safety_delivery_status;

UPDATE safety_deliveries
SET status = CASE
        WHEN status = 'submitting' THEN 'retry_wait'
        ELSE status
    END,
    available_at = COALESCE(available_at, created_at),
    max_attempts = CASE WHEN channel = 'voice' THEN 2 ELSE 3 END;

ALTER TABLE safety_deliveries
    ALTER COLUMN available_at SET NOT NULL,
    ADD CONSTRAINT safety_delivery_status
        CHECK (
            status IN (
                'pending', 'leased', 'retry_wait', 'queued', 'sent',
                'delivered', 'failed', 'cancelled', 'unknown'
            )
        ),
    ADD CONSTRAINT safety_delivery_attempt_bounds
        CHECK (
            attempt_count >= 0
            AND max_attempts BETWEEN 1 AND 10
            AND attempt_count <= max_attempts
        );

CREATE INDEX IF NOT EXISTS safety_deliveries_due_idx
    ON safety_deliveries (available_at, created_at)
    WHERE status IN ('pending', 'retry_wait');

CREATE INDEX IF NOT EXISTS safety_deliveries_stale_lease_idx
    ON safety_deliveries (lease_expires_at)
    WHERE status = 'leased';

CREATE TABLE IF NOT EXISTS safety_delivery_attempts (
    attempt_id uuid PRIMARY KEY,
    delivery_id uuid NOT NULL
        REFERENCES safety_deliveries(delivery_id) ON DELETE CASCADE,
    attempt_number integer NOT NULL,
    status text NOT NULL DEFAULT 'started',
    provider_reference text,
    error text,
    started_at timestamptz NOT NULL,
    finished_at timestamptz,
    CONSTRAINT safety_delivery_attempt_number CHECK (attempt_number > 0),
    CONSTRAINT safety_delivery_attempt_status
        CHECK (
            status IN (
                'started', 'queued', 'sent', 'delivered', 'failed', 'unknown'
            )
        ),
    UNIQUE (delivery_id, attempt_number)
);

CREATE UNIQUE INDEX IF NOT EXISTS safety_attempt_provider_reference_idx
    ON safety_delivery_attempts (provider_reference)
    WHERE provider_reference IS NOT NULL;

CREATE TABLE IF NOT EXISTS safety_responses (
    dispatch_id uuid NOT NULL
        REFERENCES safety_dispatches(dispatch_id) ON DELETE CASCADE,
    contact_id uuid NOT NULL
        REFERENCES safety_contacts(contact_id) ON DELETE RESTRICT,
    decision text NOT NULL,
    source text NOT NULL,
    responded_at timestamptz NOT NULL,
    CONSTRAINT safety_response_decision
        CHECK (decision IN ('responding', 'cannot_respond')),
    CONSTRAINT safety_response_source
        CHECK (source IN ('sms_link', 'voice_dtmf')),
    PRIMARY KEY (dispatch_id, contact_id)
);

CREATE INDEX IF NOT EXISTS safety_responses_dispatch_idx
    ON safety_responses (dispatch_id, responded_at);
