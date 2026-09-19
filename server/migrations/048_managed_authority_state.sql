-- D-059 per-account, per-data-class authority state. This is an additive,
-- fail-closed control plane: no row authorizes local pruning before the exact
-- upload acknowledgement and an exact restore proof have both been recorded.

CREATE TABLE managed_authority_states (
    principal_id uuid NOT NULL,
    managed_account_id uuid NOT NULL,
    data_class text NOT NULL,
    state text NOT NULL DEFAULT 'local_only',
    transition_version bigint NOT NULL DEFAULT 0,
    last_transition_id uuid,
    upload_acknowledgement_id uuid,
    upload_acknowledgement_sha256 char(64),
    upload_acknowledged_at timestamptz,
    restore_proof_id uuid,
    restore_proof_sha256 char(64),
    restore_proven_at timestamptz,
    pruning_authorized_at timestamptz,
    last_opt_out_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (managed_account_id, data_class),
    CONSTRAINT managed_authority_state_scope_unique
        UNIQUE (principal_id, managed_account_id, data_class),
    CONSTRAINT managed_authority_state_principal_fk
        FOREIGN KEY (principal_id, managed_account_id)
        REFERENCES unified_managed_account_links (
            principal_id,
            managed_account_id
        )
        ON DELETE RESTRICT,
    CONSTRAINT managed_authority_state_data_class
        CHECK (data_class ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT managed_authority_state_value
        CHECK (
            state IN (
                'local_only',
                'uploading',
                'shadow',
                'parity_approved',
                'cloud_authoritative',
                'rollback',
                'restore_proven'
            )
        ),
    CONSTRAINT managed_authority_state_version
        CHECK (transition_version >= 0),
    CONSTRAINT managed_authority_state_upload_evidence
        CHECK (
            (
                upload_acknowledgement_id IS NULL
                AND upload_acknowledgement_sha256 IS NULL
                AND upload_acknowledged_at IS NULL
            )
            OR (
                upload_acknowledgement_id IS NOT NULL
                AND upload_acknowledgement_sha256
                    ~ '^[0-9a-f]{64}$'
                AND upload_acknowledged_at IS NOT NULL
            )
        ),
    CONSTRAINT managed_authority_state_restore_evidence
        CHECK (
            (
                restore_proof_id IS NULL
                AND restore_proof_sha256 IS NULL
                AND restore_proven_at IS NULL
            )
            OR (
                restore_proof_id IS NOT NULL
                AND restore_proof_sha256 ~ '^[0-9a-f]{64}$'
                AND restore_proven_at IS NOT NULL
                AND upload_acknowledged_at IS NOT NULL
                AND restore_proven_at >= upload_acknowledged_at
            )
        ),
    CONSTRAINT managed_authority_state_evidence_by_state
        CHECK (
            (
                state IN ('local_only', 'uploading', 'rollback')
                AND upload_acknowledgement_id IS NULL
                AND restore_proof_id IS NULL
                AND pruning_authorized_at IS NULL
            )
            OR (
                state IN ('shadow', 'parity_approved')
                AND upload_acknowledgement_id IS NOT NULL
                AND restore_proof_id IS NULL
                AND pruning_authorized_at IS NULL
            )
            OR (
                state = 'restore_proven'
                AND upload_acknowledgement_id IS NOT NULL
                AND restore_proof_id IS NOT NULL
                AND pruning_authorized_at IS NULL
            )
            OR (
                state = 'cloud_authoritative'
                AND upload_acknowledgement_id IS NOT NULL
                AND restore_proof_id IS NOT NULL
            )
        ),
    CONSTRAINT managed_authority_state_pruning_evidence
        CHECK (
            pruning_authorized_at IS NULL
            OR (
                state = 'cloud_authoritative'
                AND upload_acknowledged_at IS NOT NULL
                AND restore_proven_at IS NOT NULL
                AND pruning_authorized_at >= upload_acknowledged_at
                AND pruning_authorized_at >= restore_proven_at
            )
        ),
    CONSTRAINT managed_authority_state_updated_order
        CHECK (updated_at >= created_at),
    CONSTRAINT managed_authority_state_opt_out_order
        CHECK (last_opt_out_at IS NULL OR last_opt_out_at >= created_at)
);

CREATE INDEX managed_authority_states_state_idx
    ON managed_authority_states (state, updated_at, managed_account_id);

CREATE TABLE managed_authority_transitions (
    transition_id uuid PRIMARY KEY,
    principal_id uuid NOT NULL,
    managed_account_id uuid NOT NULL,
    data_class text NOT NULL,
    request_id uuid NOT NULL,
    request_sha256 char(64) NOT NULL,
    transition_version bigint NOT NULL,
    from_state text NOT NULL,
    to_state text NOT NULL,
    reason text NOT NULL,
    upload_acknowledgement_id uuid,
    upload_acknowledgement_sha256 char(64),
    upload_acknowledged_at timestamptz,
    restore_proof_id uuid,
    restore_proof_sha256 char(64),
    restore_proven_at timestamptz,
    pruning_authorized_at timestamptz,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_authority_transition_state_fk
        FOREIGN KEY (principal_id, managed_account_id, data_class)
        REFERENCES managed_authority_states (
            principal_id,
            managed_account_id,
            data_class
        )
        ON DELETE RESTRICT,
    CONSTRAINT managed_authority_transition_request_unique
        UNIQUE (managed_account_id, data_class, request_id),
    CONSTRAINT managed_authority_transition_version_unique
        UNIQUE (
            managed_account_id,
            data_class,
            transition_version
        ),
    CONSTRAINT managed_authority_transition_request_digest
        CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_authority_transition_version
        CHECK (transition_version > 0),
    CONSTRAINT managed_authority_transition_from_state
        CHECK (
            from_state IN (
                'local_only',
                'uploading',
                'shadow',
                'parity_approved',
                'cloud_authoritative',
                'rollback',
                'restore_proven'
            )
        ),
    CONSTRAINT managed_authority_transition_to_state
        CHECK (
            to_state IN (
                'local_only',
                'uploading',
                'shadow',
                'parity_approved',
                'cloud_authoritative',
                'rollback',
                'restore_proven'
            )
        ),
    CONSTRAINT managed_authority_transition_reason
        CHECK (
            reason IN (
                'migration_started',
                'upload_acknowledged',
                'parity_approved',
                'restore_proven',
                'cloud_authority_enabled',
                'rollback_requested',
                'opt_out_requested',
                'local_authority_restored'
            )
        ),
    CONSTRAINT managed_authority_transition_reason_target
        CHECK (
            (to_state = 'uploading' AND reason = 'migration_started')
            OR (
                to_state = 'shadow'
                AND reason = 'upload_acknowledged'
            )
            OR (
                to_state = 'parity_approved'
                AND reason = 'parity_approved'
            )
            OR (
                to_state = 'restore_proven'
                AND reason = 'restore_proven'
            )
            OR (
                to_state = 'cloud_authoritative'
                AND reason = 'cloud_authority_enabled'
            )
            OR (
                to_state = 'rollback'
                AND reason IN ('rollback_requested', 'opt_out_requested')
            )
            OR (
                to_state = 'local_only'
                AND reason = 'local_authority_restored'
            )
        ),
    CONSTRAINT managed_authority_transition_upload_evidence
        CHECK (
            (
                upload_acknowledgement_id IS NULL
                AND upload_acknowledgement_sha256 IS NULL
                AND upload_acknowledged_at IS NULL
            )
            OR (
                upload_acknowledgement_id IS NOT NULL
                AND upload_acknowledgement_sha256
                    ~ '^[0-9a-f]{64}$'
                AND upload_acknowledged_at IS NOT NULL
            )
        ),
    CONSTRAINT managed_authority_transition_restore_evidence
        CHECK (
            (
                restore_proof_id IS NULL
                AND restore_proof_sha256 IS NULL
                AND restore_proven_at IS NULL
            )
            OR (
                restore_proof_id IS NOT NULL
                AND restore_proof_sha256 ~ '^[0-9a-f]{64}$'
                AND restore_proven_at IS NOT NULL
                AND upload_acknowledged_at IS NOT NULL
                AND restore_proven_at >= upload_acknowledged_at
            )
        ),
    CONSTRAINT managed_authority_transition_pruning_evidence
        CHECK (
            pruning_authorized_at IS NULL
            OR (
                to_state = 'cloud_authoritative'
                AND upload_acknowledged_at IS NOT NULL
                AND restore_proven_at IS NOT NULL
                AND pruning_authorized_at >= upload_acknowledged_at
                AND pruning_authorized_at >= restore_proven_at
            )
        )
);

CREATE INDEX managed_authority_transitions_account_idx
    ON managed_authority_transitions (
        managed_account_id,
        data_class,
        transition_version DESC
    );

CREATE OR REPLACE FUNCTION noop_managed_authority_transition_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'managed authority transitions are append-only'
        USING ERRCODE = '23514';
END
$function$;

CREATE TRIGGER managed_authority_transition_append_only
BEFORE UPDATE OR DELETE ON managed_authority_transitions
FOR EACH ROW
EXECUTE FUNCTION noop_managed_authority_transition_append_only();

CREATE OR REPLACE FUNCTION noop_managed_authority_state_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    matching_transition boolean;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'managed authority state cannot be deleted'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.principal_id IS DISTINCT FROM OLD.principal_id
       OR NEW.managed_account_id IS DISTINCT FROM OLD.managed_account_id
       OR NEW.data_class IS DISTINCT FROM OLD.data_class
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'managed authority scope is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.transition_version <> OLD.transition_version + 1
       OR NEW.last_transition_id IS NULL
       OR NEW.last_transition_id IS NOT DISTINCT FROM OLD.last_transition_id
       OR NEW.updated_at < OLD.updated_at THEN
        RAISE EXCEPTION 'managed authority revision is invalid'
            USING ERRCODE = '23514';
    END IF;
    IF NOT (
        (OLD.state = 'local_only' AND NEW.state = 'uploading')
        OR (
            OLD.state = 'uploading'
            AND NEW.state IN ('shadow', 'rollback')
        )
        OR (
            OLD.state = 'shadow'
            AND NEW.state IN ('parity_approved', 'rollback')
        )
        OR (
            OLD.state = 'parity_approved'
            AND NEW.state IN ('restore_proven', 'rollback')
        )
        OR (
            OLD.state = 'restore_proven'
            AND NEW.state IN ('cloud_authoritative', 'rollback')
        )
        OR (
            OLD.state = 'cloud_authoritative'
            AND NEW.state = 'rollback'
        )
        OR (
            OLD.state = 'rollback'
            AND NEW.state IN ('local_only', 'uploading')
        )
    ) THEN
        RAISE EXCEPTION 'managed authority transition is not allowed'
            USING ERRCODE = '23514';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM managed_authority_transitions AS transition
        WHERE transition.transition_id = NEW.last_transition_id
          AND transition.principal_id = NEW.principal_id
          AND transition.managed_account_id = NEW.managed_account_id
          AND transition.data_class = NEW.data_class
          AND transition.transition_version = NEW.transition_version
          AND transition.from_state = OLD.state
          AND transition.to_state = NEW.state
          AND transition.upload_acknowledgement_id
                IS NOT DISTINCT FROM NEW.upload_acknowledgement_id
          AND transition.upload_acknowledgement_sha256
                IS NOT DISTINCT FROM NEW.upload_acknowledgement_sha256
          AND transition.upload_acknowledged_at
                IS NOT DISTINCT FROM NEW.upload_acknowledged_at
          AND transition.restore_proof_id
                IS NOT DISTINCT FROM NEW.restore_proof_id
          AND transition.restore_proof_sha256
                IS NOT DISTINCT FROM NEW.restore_proof_sha256
          AND transition.restore_proven_at
                IS NOT DISTINCT FROM NEW.restore_proven_at
          AND transition.pruning_authorized_at
                IS NOT DISTINCT FROM NEW.pruning_authorized_at
          AND transition.occurred_at = NEW.updated_at
    ) INTO matching_transition;

    IF matching_transition IS NOT TRUE THEN
        RAISE EXCEPTION 'managed authority transition ledger entry is required'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER managed_authority_state_guard
BEFORE UPDATE OR DELETE ON managed_authority_states
FOR EACH ROW
EXECUTE FUNCTION noop_managed_authority_state_guard();

CREATE OR REPLACE FUNCTION noop_managed_authority_transition_applied()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    transition_applied boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM managed_authority_states AS state
        WHERE state.principal_id = NEW.principal_id
          AND state.managed_account_id = NEW.managed_account_id
          AND state.data_class = NEW.data_class
          AND state.last_transition_id = NEW.transition_id
          AND state.transition_version = NEW.transition_version
          AND state.state = NEW.to_state
    ) INTO transition_applied;

    IF transition_applied IS NOT TRUE THEN
        RAISE EXCEPTION 'managed authority transition was not applied'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END
$function$;

CREATE CONSTRAINT TRIGGER managed_authority_transition_applied
AFTER INSERT ON managed_authority_transitions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION noop_managed_authority_transition_applied();
