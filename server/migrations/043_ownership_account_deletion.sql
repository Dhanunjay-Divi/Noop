-- First-party ownership-account deletion coordination.
--
-- This migration schedules destructive work but does not perform or claim
-- cloud deletion, identity-provider deletion, band retirement, or hardware
-- unpairing. The customer API can only create a request or cancel it before
-- the recorded deadline. Later destructive workers require separate reviewed
-- credentials, policy, hardware capability, and database privileges.

CREATE TABLE IF NOT EXISTS ownership_account_deletion_requests (
    deletion_request_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    request_id uuid NOT NULL,
    request_digest char(64) NOT NULL,
    requester_identity_hash char(64) NOT NULL,
    requester_installation_hash char(64) NOT NULL,
    policy_version text NOT NULL,
    locale text NOT NULL,
    document_sha256 char(64) NOT NULL,
    export_acknowledged_at timestamptz NOT NULL,
    retention_acknowledged_at timestamptz NOT NULL,
    sessions_revoked_at timestamptz NOT NULL,
    sessions_revoked_count integer NOT NULL,
    requested_at timestamptz NOT NULL,
    cancel_before timestamptz NOT NULL,
    canceled_at timestamptz,
    CONSTRAINT ownership_account_deletion_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT ownership_account_deletion_request_digest
        CHECK (
            request_digest ~ '^[0-9a-f]{64}$'
            AND requester_identity_hash ~ '^[0-9a-f]{64}$'
            AND requester_installation_hash ~ '^[0-9a-f]{64}$'
            AND document_sha256 ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT ownership_account_deletion_policy_version
        CHECK (policy_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
    CONSTRAINT ownership_account_deletion_locale
        CHECK (locale ~ '^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$'),
    CONSTRAINT ownership_account_deletion_session_count
        CHECK (sessions_revoked_count BETWEEN 1 AND 10),
    CONSTRAINT ownership_account_deletion_ack_order
        CHECK (
            export_acknowledged_at = requested_at
            AND retention_acknowledged_at = requested_at
            AND sessions_revoked_at = requested_at
        ),
    CONSTRAINT ownership_account_deletion_cancel_window
        CHECK (cancel_before > requested_at),
    CONSTRAINT ownership_account_deletion_canceled_order
        CHECK (
            canceled_at IS NULL
            OR (
                canceled_at >= requested_at
                AND canceled_at < cancel_before
            )
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS ownership_account_deletion_live_idx
    ON ownership_account_deletion_requests (account_id)
    WHERE canceled_at IS NULL;

CREATE INDEX IF NOT EXISTS ownership_account_deletion_due_idx
    ON ownership_account_deletion_requests (cancel_before, requested_at)
    WHERE canceled_at IS NULL;

CREATE OR REPLACE FUNCTION noop_ownership_account_deletion_request_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'ownership account deletion requests cannot be deleted'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.deletion_request_id IS DISTINCT FROM OLD.deletion_request_id
       OR NEW.account_id IS DISTINCT FROM OLD.account_id
       OR NEW.request_id IS DISTINCT FROM OLD.request_id
       OR NEW.request_digest IS DISTINCT FROM OLD.request_digest
       OR NEW.requester_identity_hash IS DISTINCT FROM OLD.requester_identity_hash
       OR NEW.requester_installation_hash
            IS DISTINCT FROM OLD.requester_installation_hash
       OR NEW.policy_version IS DISTINCT FROM OLD.policy_version
       OR NEW.locale IS DISTINCT FROM OLD.locale
       OR NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256
       OR NEW.export_acknowledged_at IS DISTINCT FROM OLD.export_acknowledged_at
       OR NEW.retention_acknowledged_at
            IS DISTINCT FROM OLD.retention_acknowledged_at
       OR NEW.sessions_revoked_at IS DISTINCT FROM OLD.sessions_revoked_at
       OR NEW.sessions_revoked_count IS DISTINCT FROM OLD.sessions_revoked_count
       OR NEW.requested_at IS DISTINCT FROM OLD.requested_at
       OR NEW.cancel_before IS DISTINCT FROM OLD.cancel_before
       OR OLD.canceled_at IS NOT NULL
       OR NEW.canceled_at IS NULL THEN
        RAISE EXCEPTION 'ownership account deletion request is immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS ownership_account_deletion_request_guard
    ON ownership_account_deletion_requests;
CREATE TRIGGER ownership_account_deletion_request_guard
BEFORE UPDATE OR DELETE ON ownership_account_deletion_requests
FOR EACH ROW
EXECUTE FUNCTION noop_ownership_account_deletion_request_guard();

CREATE TABLE IF NOT EXISTS ownership_account_deletion_targets (
    deletion_request_id uuid NOT NULL
        REFERENCES ownership_account_deletion_requests(deletion_request_id)
        ON DELETE RESTRICT,
    target_kind text NOT NULL,
    initial_state text NOT NULL,
    blocker text,
    policy_version text,
    hardware_capability_version text,
    scheduled_at timestamptz NOT NULL,
    not_before timestamptz NOT NULL,
    PRIMARY KEY (deletion_request_id, target_kind),
    CONSTRAINT ownership_account_deletion_target_kind
        CHECK (
            target_kind IN (
                'managed_cloud_data',
                'identity_provider',
                'band_retirement',
                'ownership_control_plane'
            )
        ),
    CONSTRAINT ownership_account_deletion_target_state
        CHECK (initial_state IN ('scheduled', 'blocked', 'not_required')),
    CONSTRAINT ownership_account_deletion_target_blocker
        CHECK (
            blocker IS NULL
            OR blocker IN (
                'policy_unapproved',
                'hardware_capability_unavailable',
                'operator_approval_required',
                'provider_credentials_unavailable',
                'band_retirement_pending',
                'identity_provider_pending'
            )
        ),
    CONSTRAINT ownership_account_deletion_target_state_blocker
        CHECK (
            (initial_state = 'blocked' AND blocker IS NOT NULL)
            OR (initial_state <> 'blocked' AND blocker IS NULL)
        ),
    CONSTRAINT ownership_account_deletion_target_versions
        CHECK (
            (
                target_kind = 'band_retirement'
                AND (
                    policy_version IS NULL
                    OR policy_version
                        ~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'
                )
                AND (
                    hardware_capability_version IS NULL
                    OR hardware_capability_version
                        ~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'
                )
            )
            OR (
                target_kind <> 'band_retirement'
                AND policy_version IS NULL
                AND hardware_capability_version IS NULL
            )
        ),
    CONSTRAINT ownership_account_deletion_target_schedule
        CHECK (not_before >= scheduled_at)
);

CREATE INDEX IF NOT EXISTS ownership_account_deletion_target_due_idx
    ON ownership_account_deletion_targets (
        target_kind,
        initial_state,
        not_before
    );

DROP TRIGGER IF EXISTS ownership_account_deletion_target_append_only
    ON ownership_account_deletion_targets;
CREATE TRIGGER ownership_account_deletion_target_append_only
BEFORE UPDATE OR DELETE ON ownership_account_deletion_targets
FOR EACH ROW
EXECUTE FUNCTION noop_ownership_append_only();

ALTER TABLE ownership_events
    DROP CONSTRAINT ownership_event_kind;
ALTER TABLE ownership_events
    ADD CONSTRAINT ownership_event_kind
        CHECK (
            event_kind IN (
                'account_registered',
                'terms_accepted',
                'band_claimed',
                'claim_conflict',
                'installation_authorized',
                'installation_revoked',
                'plan_selected',
                'release_requested',
                'release_completed',
                'account_deletion_requested',
                'account_sessions_revoked',
                'cloud_deletion_scheduled',
                'band_retirement_evaluated',
                'account_deletion_canceled'
            )
        );

ALTER TABLE ownership_events
    DROP CONSTRAINT ownership_event_outcome;
ALTER TABLE ownership_events
    ADD CONSTRAINT ownership_event_outcome
        CHECK (
            outcome IN (
                'accepted',
                'rejected',
                'completed',
                'conflict',
                'scheduled',
                'blocked',
                'eligible',
                'canceled'
            )
        );
