-- First-party NOOP Band ownership control plane.
--
-- This schema is deliberately separate from NOOP+ managed health storage.
-- It stores no health payload, contact address, password, OTP, printed band
-- number, raw possession proof, or plaintext identity-provider subject.

CREATE TABLE IF NOT EXISTS ownership_accounts (
    account_id uuid PRIMARY KEY,
    status text NOT NULL DEFAULT 'active',
    auth_valid_after timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deletion_requested_at timestamptz,
    retired_at timestamptz,
    CONSTRAINT ownership_account_status
        CHECK (status IN ('active', 'deletion_pending', 'retired')),
    CONSTRAINT ownership_account_updated_order
        CHECK (updated_at >= created_at),
    CONSTRAINT ownership_account_deletion_order
        CHECK (
            deletion_requested_at IS NULL
            OR deletion_requested_at >= created_at
        ),
    CONSTRAINT ownership_account_retired_order
        CHECK (retired_at IS NULL OR retired_at >= created_at),
    CONSTRAINT ownership_account_status_times
        CHECK (
            (status <> 'deletion_pending' OR deletion_requested_at IS NOT NULL)
            AND (status <> 'retired' OR retired_at IS NOT NULL)
        )
);

CREATE INDEX IF NOT EXISTS ownership_accounts_status_idx
    ON ownership_accounts (status, updated_at);

CREATE TABLE IF NOT EXISTS ownership_external_identities (
    identity_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    issuer text NOT NULL,
    provider_tenant text NOT NULL DEFAULT '',
    subject_hash char(64) NOT NULL,
    email_verified boolean NOT NULL,
    phone_verified boolean NOT NULL DEFAULT false,
    status text NOT NULL DEFAULT 'active',
    verified_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ownership_external_identity_subject_unique
        UNIQUE (issuer, provider_tenant, subject_hash),
    CONSTRAINT ownership_external_identity_scope_unique
        UNIQUE (account_id, identity_id),
    CONSTRAINT ownership_external_identity_issuer
        CHECK (
            length(issuer) BETWEEN 1 AND 512
            AND issuer !~ '[[:space:]]'
        ),
    CONSTRAINT ownership_external_identity_tenant
        CHECK (
            provider_tenant = ''
            OR provider_tenant ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        ),
    CONSTRAINT ownership_external_identity_subject_digest
        CHECK (subject_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ownership_external_identity_status
        CHECK (status IN ('active', 'revoked')),
    CONSTRAINT ownership_external_identity_seen_order
        CHECK (last_seen_at >= verified_at),
    CONSTRAINT ownership_external_identity_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= verified_at),
    CONSTRAINT ownership_external_identity_status_time
        CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ownership_external_identities_account_idx
    ON ownership_external_identities (account_id, status);

CREATE TABLE IF NOT EXISTS ownership_terms_documents (
    policy_version text NOT NULL,
    locale text NOT NULL,
    document_sha256 char(64) NOT NULL,
    document_uri text NOT NULL,
    effective_at timestamptz NOT NULL,
    retired_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (policy_version, locale),
    CONSTRAINT ownership_terms_document_exact_unique
        UNIQUE (policy_version, locale, document_sha256),
    CONSTRAINT ownership_terms_version
        CHECK (policy_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
    CONSTRAINT ownership_terms_locale
        CHECK (locale ~ '^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$'),
    CONSTRAINT ownership_terms_digest
        CHECK (document_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ownership_terms_uri
        CHECK (
            length(document_uri) BETWEEN 12 AND 1024
            AND document_uri
                ~ '^https://[^:/?#@[:space:]]+(:443)?(/[^?#[:space:]]*)?$'
            AND document_uri !~ '[@?#]'
        ),
    CONSTRAINT ownership_terms_retirement_order
        CHECK (retired_at IS NULL OR retired_at > effective_at)
);

CREATE INDEX IF NOT EXISTS ownership_terms_active_idx
    ON ownership_terms_documents (locale, effective_at DESC)
    WHERE retired_at IS NULL;

CREATE OR REPLACE FUNCTION noop_ownership_terms_document_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'ownership terms documents cannot be deleted'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.policy_version IS DISTINCT FROM OLD.policy_version
       OR NEW.locale IS DISTINCT FROM OLD.locale
       OR NEW.document_sha256 IS DISTINCT FROM OLD.document_sha256
       OR NEW.document_uri IS DISTINCT FROM OLD.document_uri
       OR NEW.effective_at IS DISTINCT FROM OLD.effective_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'ownership terms document identity is immutable'
            USING ERRCODE = '23514';
    END IF;
    IF OLD.retired_at IS NOT NULL
       AND NEW.retired_at IS DISTINCT FROM OLD.retired_at THEN
        RAISE EXCEPTION 'ownership terms retirement is immutable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS ownership_terms_document_immutable
    ON ownership_terms_documents;
CREATE TRIGGER ownership_terms_document_immutable
BEFORE UPDATE OR DELETE ON ownership_terms_documents
FOR EACH ROW
EXECUTE FUNCTION noop_ownership_terms_document_immutable();

CREATE OR REPLACE FUNCTION noop_ownership_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = '23514';
END
$function$;

CREATE TABLE IF NOT EXISTS ownership_terms_acceptances (
    acceptance_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    policy_version text NOT NULL,
    locale text NOT NULL,
    document_sha256 char(64) NOT NULL,
    request_id uuid NOT NULL,
    request_digest char(64) NOT NULL,
    accepted_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ownership_terms_acceptance_document_fk
        FOREIGN KEY (policy_version, locale, document_sha256)
        REFERENCES ownership_terms_documents(
            policy_version,
            locale,
            document_sha256
        )
        ON DELETE RESTRICT,
    CONSTRAINT ownership_terms_acceptance_request_unique
        UNIQUE (account_id, request_id),
    CONSTRAINT ownership_terms_acceptance_digest
        CHECK (
            document_sha256 ~ '^[0-9a-f]{64}$'
            AND request_digest ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT ownership_terms_acceptance_recorded_order
        CHECK (recorded_at >= accepted_at)
);

CREATE INDEX IF NOT EXISTS ownership_terms_acceptance_account_idx
    ON ownership_terms_acceptances (account_id, accepted_at DESC);

DROP TRIGGER IF EXISTS ownership_terms_acceptance_append_only
    ON ownership_terms_acceptances;
CREATE TRIGGER ownership_terms_acceptance_append_only
BEFORE UPDATE OR DELETE ON ownership_terms_acceptances
FOR EACH ROW
EXECUTE FUNCTION noop_ownership_append_only();

CREATE TABLE IF NOT EXISTS ownership_installations (
    installation_id text PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    platform text NOT NULL,
    token_hash char(64) NOT NULL,
    device_key_fingerprint char(64),
    status text NOT NULL DEFAULT 'active',
    auth_valid_after timestamptz NOT NULL,
    registered_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    CONSTRAINT ownership_installation_scope_unique
        UNIQUE (account_id, installation_id),
    CONSTRAINT ownership_installation_platform
        CHECK (platform IN ('ios', 'android')),
    CONSTRAINT ownership_installation_token_digest
        CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ownership_installation_key_digest
        CHECK (
            device_key_fingerprint IS NULL
            OR device_key_fingerprint ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT ownership_installation_status
        CHECK (status IN ('active', 'revoked')),
    CONSTRAINT ownership_installation_seen_order
        CHECK (last_seen_at >= registered_at),
    CONSTRAINT ownership_installation_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= registered_at),
    CONSTRAINT ownership_installation_status_time
        CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ownership_installations_account_idx
    ON ownership_installations (account_id, status, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS ownership_bands (
    band_id uuid PRIMARY KEY,
    provisioned_identity_hash char(64) NOT NULL UNIQUE,
    hardware_revision text NOT NULL,
    protocol_version text NOT NULL,
    firmware_version text NOT NULL,
    status text NOT NULL DEFAULT 'unclaimed',
    current_account_id uuid
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    provisioned_at timestamptz NOT NULL DEFAULT now(),
    claimed_at timestamptz,
    released_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ownership_band_identity_digest
        CHECK (provisioned_identity_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ownership_band_hardware_revision
        CHECK (hardware_revision ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
    CONSTRAINT ownership_band_protocol_version
        CHECK (protocol_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
    CONSTRAINT ownership_band_firmware_version
        CHECK (firmware_version ~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'),
    CONSTRAINT ownership_band_status
        CHECK (
            status IN (
                'unclaimed',
                'claimed',
                'return_pending',
                'quarantined',
                'retired'
            )
        ),
    CONSTRAINT ownership_band_lifecycle_state
        CHECK (
            (
                status = 'unclaimed'
                AND current_account_id IS NULL
                AND claimed_at IS NULL
                AND released_at IS NULL
            )
            OR (
                status IN ('claimed', 'return_pending')
                AND current_account_id IS NOT NULL
                AND claimed_at IS NOT NULL
                AND released_at IS NULL
            )
            OR (
                status IN ('quarantined', 'retired')
                AND current_account_id IS NULL
                AND (
                    (
                        claimed_at IS NULL
                        AND released_at IS NULL
                    )
                    OR (
                        claimed_at IS NOT NULL
                        AND released_at IS NOT NULL
                    )
                )
            )
        ),
    CONSTRAINT ownership_band_claim_time
        CHECK (claimed_at IS NULL OR claimed_at >= provisioned_at),
    CONSTRAINT ownership_band_release_time
        CHECK (
            released_at IS NULL
            OR (claimed_at IS NOT NULL AND released_at >= claimed_at)
        ),
    CONSTRAINT ownership_band_updated_order
        CHECK (updated_at >= provisioned_at)
);

CREATE INDEX IF NOT EXISTS ownership_bands_owner_idx
    ON ownership_bands (current_account_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS ownership_bands_active_owner_unique_idx
    ON ownership_bands (current_account_id)
    WHERE current_account_id IS NOT NULL
      AND status IN ('claimed', 'return_pending');

CREATE TABLE IF NOT EXISTS ownership_possession_challenges (
    challenge_id uuid PRIMARY KEY,
    request_id uuid NOT NULL UNIQUE,
    challenge_value text NOT NULL,
    platform text NOT NULL,
    app_id_hash char(64) NOT NULL,
    status text NOT NULL DEFAULT 'issued',
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    CONSTRAINT ownership_challenge_value
        CHECK (challenge_value ~ '^[A-Za-z0-9_-]{43}$'),
    CONSTRAINT ownership_challenge_platform
        CHECK (platform IN ('ios', 'android')),
    CONSTRAINT ownership_challenge_app_digest
        CHECK (app_id_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ownership_challenge_status
        CHECK (status IN ('issued', 'consumed', 'rejected', 'expired')),
    CONSTRAINT ownership_challenge_expiry
        CHECK (expires_at > created_at),
    CONSTRAINT ownership_challenge_consumed_order
        CHECK (consumed_at IS NULL OR consumed_at >= created_at),
    CONSTRAINT ownership_challenge_status_time
        CHECK (status = 'issued' OR consumed_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ownership_challenges_expiry_idx
    ON ownership_possession_challenges (status, expires_at);

CREATE TABLE IF NOT EXISTS ownership_claim_requests (
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    request_id uuid NOT NULL,
    request_digest char(64) NOT NULL,
    installation_id text NOT NULL
        REFERENCES ownership_installations(installation_id)
        ON DELETE RESTRICT,
    band_id uuid
        REFERENCES ownership_bands(band_id) ON DELETE RESTRICT,
    challenge_id uuid NOT NULL UNIQUE
        REFERENCES ownership_possession_challenges(challenge_id)
        ON DELETE RESTRICT,
    proof_digest char(64) NOT NULL,
    outcome text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, request_id),
    CONSTRAINT ownership_claim_request_band_unique
        UNIQUE (account_id, request_id, band_id),
    CONSTRAINT ownership_claim_installation_scope_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES ownership_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT ownership_claim_request_digest
        CHECK (
            request_digest ~ '^[0-9a-f]{64}$'
            AND proof_digest ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT ownership_claim_request_outcome
        CHECK (outcome IN ('claimed', 'already_owned', 'conflict'))
);

CREATE TABLE IF NOT EXISTS ownership_band_claims (
    claim_id uuid PRIMARY KEY,
    band_id uuid NOT NULL
        REFERENCES ownership_bands(band_id) ON DELETE RESTRICT,
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    request_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'active',
    claimed_at timestamptz NOT NULL,
    released_at timestamptz,
    CONSTRAINT ownership_band_claim_request_fk
        FOREIGN KEY (account_id, request_id)
        REFERENCES ownership_claim_requests(account_id, request_id)
        ON DELETE RESTRICT,
    CONSTRAINT ownership_band_claim_request_band_fk
        FOREIGN KEY (account_id, request_id, band_id)
        REFERENCES ownership_claim_requests(
            account_id,
            request_id,
            band_id
        )
        ON DELETE RESTRICT,
    CONSTRAINT ownership_band_claim_status
        CHECK (status IN ('active', 'released')),
    CONSTRAINT ownership_band_claim_release_order
        CHECK (released_at IS NULL OR released_at >= claimed_at),
    CONSTRAINT ownership_band_claim_status_time
        CHECK (status <> 'released' OR released_at IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS ownership_band_active_claim_idx
    ON ownership_band_claims (band_id)
    WHERE status = 'active';

CREATE TABLE IF NOT EXISTS ownership_installation_authorizations (
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    request_id uuid NOT NULL,
    request_digest char(64) NOT NULL,
    challenge_id uuid NOT NULL UNIQUE
        REFERENCES ownership_possession_challenges(challenge_id)
        ON DELETE RESTRICT,
    band_id uuid NOT NULL
        REFERENCES ownership_bands(band_id) ON DELETE RESTRICT,
    installation_id text NOT NULL
        REFERENCES ownership_installations(installation_id)
        ON DELETE RESTRICT,
    proof_digest char(64) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, request_id),
    CONSTRAINT ownership_authorization_installation_scope_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES ownership_installations(account_id, installation_id)
        ON DELETE RESTRICT,
    CONSTRAINT ownership_installation_authorization_digest
        CHECK (
            request_digest ~ '^[0-9a-f]{64}$'
            AND proof_digest ~ '^[0-9a-f]{64}$'
        )
);

CREATE TABLE IF NOT EXISTS ownership_plan_selections (
    account_id uuid PRIMARY KEY
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    selection text NOT NULL,
    request_id uuid NOT NULL,
    selected_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CONSTRAINT ownership_plan_selection
        CHECK (selection IN ('noop', 'noop_plus')),
    CONSTRAINT ownership_plan_selection_updated_order
        CHECK (updated_at >= selected_at)
);

CREATE TABLE IF NOT EXISTS ownership_plan_selection_requests (
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    request_id uuid NOT NULL,
    selection text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, request_id),
    CONSTRAINT ownership_plan_selection_request_value
        CHECK (selection IN ('noop', 'noop_plus'))
);

-- Deliberately independent from plan selection. No customer endpoint in this
-- release writes this table, so choosing NOOP+ cannot grant an entitlement.
CREATE TABLE IF NOT EXISTS ownership_entitlements (
    entitlement_id uuid PRIMARY KEY,
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    entitlement_kind text NOT NULL,
    status text NOT NULL,
    provider text NOT NULL,
    provider_reference_hash char(64),
    valid_from timestamptz NOT NULL,
    valid_until timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ownership_entitlement_unique
        UNIQUE (account_id, entitlement_kind),
    CONSTRAINT ownership_entitlement_kind
        CHECK (entitlement_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT ownership_entitlement_status
        CHECK (status IN ('pending', 'active', 'grace', 'expired', 'revoked')),
    CONSTRAINT ownership_entitlement_provider
        CHECK (provider ~ '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT ownership_entitlement_reference
        CHECK (
            provider_reference_hash IS NULL
            OR provider_reference_hash ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT ownership_entitlement_validity
        CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT ownership_entitlement_updated_order
        CHECK (updated_at >= created_at)
);

-- Release records exist for future operator/legal workflows only. V1 exposes
-- no customer transfer or unpair endpoint.
CREATE TABLE IF NOT EXISTS ownership_releases (
    release_id uuid PRIMARY KEY,
    band_id uuid NOT NULL
        REFERENCES ownership_bands(band_id) ON DELETE RESTRICT,
    account_id uuid NOT NULL
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    reason text NOT NULL,
    status text NOT NULL,
    approved_actor_hash char(64),
    requested_at timestamptz NOT NULL,
    approved_at timestamptz,
    completed_at timestamptz,
    CONSTRAINT ownership_release_reason
        CHECK (
            reason IN (
                'return',
                'rma',
                'replacement',
                'recovery',
                'deletion',
                'dispute',
                'fraud',
                'recycling',
                'legal',
                'security',
                'eligible_upgrade'
            )
        ),
    CONSTRAINT ownership_release_status
        CHECK (status IN ('requested', 'approved', 'rejected', 'completed')),
    CONSTRAINT ownership_release_actor_digest
        CHECK (
            approved_actor_hash IS NULL
            OR approved_actor_hash ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT ownership_release_approval_order
        CHECK (approved_at IS NULL OR approved_at >= requested_at),
    CONSTRAINT ownership_release_completion_order
        CHECK (
            completed_at IS NULL
            OR (approved_at IS NOT NULL AND completed_at >= approved_at)
        ),
    CONSTRAINT ownership_release_status_times
        CHECK (
            (
                status = 'requested'
                AND approved_at IS NULL
                AND completed_at IS NULL
                AND approved_actor_hash IS NULL
            )
            OR (
                status IN ('approved', 'rejected')
                AND approved_at IS NOT NULL
                AND completed_at IS NULL
                AND approved_actor_hash IS NOT NULL
            )
            OR (
                status = 'completed'
                AND approved_at IS NOT NULL
                AND completed_at IS NOT NULL
                AND approved_actor_hash IS NOT NULL
            )
        )
);

CREATE TABLE IF NOT EXISTS ownership_events (
    event_id uuid PRIMARY KEY,
    account_id uuid
        REFERENCES ownership_accounts(account_id) ON DELETE RESTRICT,
    band_id uuid
        REFERENCES ownership_bands(band_id) ON DELETE RESTRICT,
    installation_id text
        REFERENCES ownership_installations(installation_id) ON DELETE RESTRICT,
    event_kind text NOT NULL,
    outcome text NOT NULL,
    actor_kind text NOT NULL,
    occurred_at timestamptz NOT NULL,
    CONSTRAINT ownership_event_kind
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
                'release_completed'
            )
        ),
    CONSTRAINT ownership_event_outcome
        CHECK (outcome IN ('accepted', 'rejected', 'completed', 'conflict')),
    CONSTRAINT ownership_event_actor
        CHECK (actor_kind IN ('customer', 'operator', 'system')),
    CONSTRAINT ownership_event_installation_scope
        CHECK (installation_id IS NULL OR account_id IS NOT NULL),
    CONSTRAINT ownership_event_installation_scope_fk
        FOREIGN KEY (account_id, installation_id)
        REFERENCES ownership_installations(account_id, installation_id)
        ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ownership_events_account_idx
    ON ownership_events (account_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS ownership_events_band_idx
    ON ownership_events (band_id, occurred_at DESC);

DROP TRIGGER IF EXISTS ownership_event_append_only ON ownership_events;
CREATE TRIGGER ownership_event_append_only
BEFORE UPDATE OR DELETE ON ownership_events
FOR EACH ROW
EXECUTE FUNCTION noop_ownership_append_only();
