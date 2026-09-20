-- Additive authority re-consent evidence and formula-shadow immutability.
-- Migrations 048 and 049 are already committed and remain byte-identical.

ALTER TABLE managed_authority_states
    ADD COLUMN last_reconsented_at timestamptz,
    ADD COLUMN reconsent_consent_event_id uuid,
    ADD COLUMN reconsent_policy_version text,
    ADD COLUMN reconsent_policy_sha256 char(64);

ALTER TABLE managed_authority_states
    ADD CONSTRAINT managed_authority_state_reconsent_event_fk
        FOREIGN KEY (reconsent_consent_event_id)
        REFERENCES managed_consent_events(consent_event_id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT managed_authority_state_reconsent_evidence
        CHECK (
            (
                last_reconsented_at IS NULL
                AND reconsent_consent_event_id IS NULL
                AND reconsent_policy_version IS NULL
                AND reconsent_policy_sha256 IS NULL
            )
            OR (
                last_reconsented_at IS NOT NULL
                AND reconsent_consent_event_id IS NOT NULL
                AND last_reconsented_at >= created_at
                AND reconsent_policy_version
                    ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
                AND reconsent_policy_sha256 ~ '^[0-9a-f]{64}$'
            )
        );

ALTER TABLE managed_authority_transitions
    ADD COLUMN last_opt_out_at timestamptz,
    ADD COLUMN last_reconsented_at timestamptz,
    ADD COLUMN reconsent_consent_event_id uuid,
    ADD COLUMN reconsent_policy_version text,
    ADD COLUMN reconsent_policy_sha256 char(64);

ALTER TABLE managed_authority_transitions
    ADD CONSTRAINT managed_authority_transition_reconsent_event_fk
        FOREIGN KEY (reconsent_consent_event_id)
        REFERENCES managed_consent_events(consent_event_id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT managed_authority_transition_opt_out_order
        CHECK (
            last_opt_out_at IS NULL
            OR last_opt_out_at <= occurred_at
        ),
    ADD CONSTRAINT managed_authority_transition_opt_out_event
        CHECK (
            reason <> 'opt_out_requested'
            OR last_opt_out_at = occurred_at
        ),
    ADD CONSTRAINT managed_authority_transition_reconsent_evidence
        CHECK (
            (
                last_reconsented_at IS NULL
                AND reconsent_consent_event_id IS NULL
                AND reconsent_policy_version IS NULL
                AND reconsent_policy_sha256 IS NULL
            )
            OR (
                last_reconsented_at IS NOT NULL
                AND reconsent_consent_event_id IS NOT NULL
                AND last_reconsented_at <= occurred_at
                AND reconsent_policy_version
                    ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
                AND reconsent_policy_sha256 ~ '^[0-9a-f]{64}$'
            )
        ),
    ADD CONSTRAINT managed_authority_transition_reconsent_event
        CHECK (
            reason <> 'reconsent_recorded'
            OR last_reconsented_at = occurred_at
        );

ALTER TABLE managed_authority_transitions
    DROP CONSTRAINT managed_authority_transition_reason,
    DROP CONSTRAINT managed_authority_transition_reason_target;

ALTER TABLE managed_authority_transitions
    ADD CONSTRAINT managed_authority_transition_reason
        CHECK (
            reason IN (
                'migration_started',
                'upload_acknowledged',
                'parity_approved',
                'restore_proven',
                'cloud_authority_enabled',
                'rollback_requested',
                'opt_out_requested',
                'local_authority_restored',
                'reconsent_recorded'
            )
        ),
    ADD CONSTRAINT managed_authority_transition_reason_target
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
                AND reason IN (
                    'local_authority_restored',
                    'reconsent_recorded'
                )
            )
        );

CREATE OR REPLACE FUNCTION noop_managed_authority_state_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    matching_transition boolean;
    matching_reconsent boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.state <> 'local_only'
           OR NEW.transition_version <> 0
           OR NEW.last_transition_id IS NOT NULL
           OR NEW.upload_acknowledgement_id IS NOT NULL
           OR NEW.upload_acknowledgement_sha256 IS NOT NULL
           OR NEW.upload_acknowledged_at IS NOT NULL
           OR NEW.restore_proof_id IS NOT NULL
           OR NEW.restore_proof_sha256 IS NOT NULL
           OR NEW.restore_proven_at IS NOT NULL
           OR NEW.pruning_authorized_at IS NOT NULL
           OR NEW.last_opt_out_at IS NOT NULL
           OR NEW.last_reconsented_at IS NOT NULL
           OR NEW.reconsent_consent_event_id IS NOT NULL
           OR NEW.reconsent_policy_version IS NOT NULL
           OR NEW.reconsent_policy_sha256 IS NOT NULL
           OR NEW.updated_at IS DISTINCT FROM NEW.created_at THEN
            RAISE EXCEPTION
                'managed authority state must start at the ledger baseline'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
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
        (
            OLD.state = 'local_only'
            AND NEW.state IN ('local_only', 'uploading', 'rollback')
        )
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
            AND NEW.state IN ('local_only', 'uploading', 'rollback')
        )
    ) THEN
        RAISE EXCEPTION 'managed authority transition is not allowed'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.state = 'uploading'
       AND NEW.last_opt_out_at IS NOT NULL
       AND (
            NEW.last_reconsented_at IS NULL
            OR NEW.last_reconsented_at <= NEW.last_opt_out_at
       ) THEN
        RAISE EXCEPTION
            'managed authority promotion requires explicit re-consent'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.reconsent_consent_event_id IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1
            FROM managed_consent_events AS consent
            JOIN managed_policy_documents AS policy
              ON policy.policy_kind = consent.policy_kind
             AND policy.policy_version = consent.policy_version
            JOIN managed_account_installations AS installation
              ON installation.account_id = consent.account_id
             AND installation.installation_id = consent.installation_id
            JOIN installation_credentials AS credential
              ON credential.installation_id = installation.installation_id
            WHERE consent.consent_event_id
                    = NEW.reconsent_consent_event_id
              AND consent.account_id = NEW.managed_account_id
              AND consent.decision = 'granted'
              AND consent.data_classes = ARRAY[NEW.data_class]::text[]
              AND consent.installation_id IS NOT NULL
              AND consent.occurred_at = NEW.last_reconsented_at
              AND consent.policy_version = NEW.reconsent_policy_version
              AND policy.document_sha256 = NEW.reconsent_policy_sha256
              AND policy.effective_at <= consent.occurred_at
              AND (
                    policy.retired_at IS NULL
                    OR policy.retired_at > consent.occurred_at
              )
              AND installation.registered_at <= consent.occurred_at
              AND (
                    installation.revoked_at IS NULL
                    OR installation.revoked_at > consent.occurred_at
              )
              AND credential.created_at <= consent.occurred_at
              AND (
                    credential.revoked_at IS NULL
                    OR credential.revoked_at > consent.occurred_at
              )
        ) INTO matching_reconsent;
        IF matching_reconsent IS NOT TRUE THEN
            RAISE EXCEPTION
                'managed authority re-consent evidence is invalid'
                USING ERRCODE = '23514';
        END IF;
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
          AND transition.last_opt_out_at
                IS NOT DISTINCT FROM NEW.last_opt_out_at
          AND transition.last_reconsented_at
                IS NOT DISTINCT FROM NEW.last_reconsented_at
          AND transition.reconsent_consent_event_id
                IS NOT DISTINCT FROM NEW.reconsent_consent_event_id
          AND transition.reconsent_policy_version
                IS NOT DISTINCT FROM NEW.reconsent_policy_version
          AND transition.reconsent_policy_sha256
                IS NOT DISTINCT FROM NEW.reconsent_policy_sha256
          AND transition.occurred_at = NEW.updated_at
    ) INTO matching_transition;

    IF matching_transition IS NOT TRUE THEN
        RAISE EXCEPTION 'managed authority transition ledger entry is required'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

DROP TRIGGER managed_authority_state_guard
    ON managed_authority_states;

CREATE TRIGGER managed_authority_state_guard
BEFORE INSERT OR UPDATE ON managed_authority_states
FOR EACH ROW
EXECUTE FUNCTION noop_managed_authority_state_guard();

CREATE OR REPLACE FUNCTION noop_managed_formula_shadow_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'managed formula shadow results are append-only'
            USING ERRCODE = '23514';
    END IF;
    IF (
        to_jsonb(NEW)
        - 'is_current'
        - 'superseded_by_result_id'
        - 'superseded_at'
    ) IS DISTINCT FROM (
        to_jsonb(OLD)
        - 'is_current'
        - 'superseded_by_result_id'
        - 'superseded_at'
    )
       OR OLD.is_current IS NOT TRUE
       OR NEW.is_current IS NOT FALSE
       OR OLD.superseded_by_result_id IS NOT NULL
       OR NEW.superseded_by_result_id IS NULL
       OR OLD.superseded_at IS NOT NULL
       OR NEW.superseded_at IS NULL THEN
        RAISE EXCEPTION 'managed formula shadow result is immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER managed_formula_shadow_immutable
BEFORE UPDATE OR DELETE ON managed_formula_shadow_results
FOR EACH ROW
EXECUTE FUNCTION noop_managed_formula_shadow_immutable();
