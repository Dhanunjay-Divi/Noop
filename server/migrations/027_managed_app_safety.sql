-- Managed account-to-account Safety paging. This path is separate from
-- managed Friends sharing and from the optional SMS/voice fallback. Push
-- tokens are application-encrypted before insertion and replaced by a
-- non-secret hash tombstone when invalidated or revoked. Location is
-- latest-only: one row per active incident, deleted as soon as the incident
-- ends or expires.

CREATE TABLE IF NOT EXISTS managed_push_installations (
    account_id uuid NOT NULL,
    installation_id text NOT NULL,
    platform text NOT NULL,
    environment text NOT NULL,
    target_kind text NOT NULL,
    token_hash char(64) NOT NULL UNIQUE,
    token_ciphertext text NOT NULL,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    PRIMARY KEY (account_id, installation_id),
    FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_account_installations(account_id, installation_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_push_installation_platform
        CHECK (platform IN ('ios', 'android')),
    CONSTRAINT managed_push_installation_environment
        CHECK (environment IN ('development', 'production')),
    CONSTRAINT managed_push_installation_target_kind
        CHECK (
            (platform = 'ios' AND target_kind = 'fid')
            OR (platform = 'android' AND target_kind = 'token')
        ),
    CONSTRAINT managed_push_installation_digest
        CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_push_installation_ciphertext
        CHECK (
            length(token_ciphertext) BETWEEN 32 AND 8192
            AND token_ciphertext !~ '[[:space:]]'
        ),
    CONSTRAINT managed_push_installation_status
        CHECK (status IN ('active', 'invalid', 'revoked')),
    CONSTRAINT managed_push_installation_updated_order
        CHECK (
            updated_at >= created_at
            AND last_seen_at >= created_at
        ),
    CONSTRAINT managed_push_installation_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= created_at),
    CONSTRAINT managed_push_installation_state
        CHECK (
            (status = 'active' AND revoked_at IS NULL)
            OR (status IN ('invalid', 'revoked') AND revoked_at IS NOT NULL)
        )
);

CREATE INDEX IF NOT EXISTS managed_push_installations_account_idx
    ON managed_push_installations (account_id, status, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS managed_safety_invites (
    invite_id uuid PRIMARY KEY,
    owner_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    creation_request_id uuid NOT NULL,
    capability_hash char(64) NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    redeemed_at timestamptz,
    redeemed_by_profile_id uuid
        REFERENCES managed_social_profiles(profile_id) ON DELETE SET NULL,
    safety_request_id uuid,
    purge_after timestamptz NOT NULL,
    CONSTRAINT managed_safety_invite_creation_unique
        UNIQUE (owner_profile_id, creation_request_id),
    CONSTRAINT managed_safety_invite_digest
        CHECK (capability_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_safety_invite_status
        CHECK (status IN ('active', 'revoked', 'redeemed', 'expired')),
    CONSTRAINT managed_safety_invite_expiry
        CHECK (
            expires_at > created_at
            AND expires_at <= created_at + interval '168 hours'
            AND purge_after >= expires_at + interval '30 days'
        ),
    CONSTRAINT managed_safety_invite_state
        CHECK (
            (status = 'active' AND revoked_at IS NULL AND redeemed_at IS NULL)
            OR (status = 'revoked' AND revoked_at IS NOT NULL)
            OR (status = 'redeemed' AND redeemed_at IS NOT NULL)
            OR status = 'expired'
        )
);

CREATE INDEX IF NOT EXISTS managed_safety_invites_owner_idx
    ON managed_safety_invites (owner_profile_id, status, expires_at DESC);

CREATE INDEX IF NOT EXISTS managed_safety_invites_expiry_idx
    ON managed_safety_invites (expires_at, invite_id)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS managed_safety_invites_purge_idx
    ON managed_safety_invites (purge_after, invite_id);

CREATE TABLE IF NOT EXISTS managed_safety_requests (
    request_id uuid PRIMARY KEY,
    client_request_id uuid NOT NULL,
    owner_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    contact_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    invite_id uuid
        REFERENCES managed_safety_invites(invite_id) ON DELETE SET NULL,
    source text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz,
    expires_at timestamptz NOT NULL,
    purge_after timestamptz NOT NULL,
    CONSTRAINT managed_safety_request_client_unique
        UNIQUE (owner_profile_id, client_request_id),
    CONSTRAINT managed_safety_request_distinct
        CHECK (owner_profile_id <> contact_profile_id),
    CONSTRAINT managed_safety_request_source
        CHECK (source IN ('noop_id', 'invite')),
    CONSTRAINT managed_safety_request_status
        CHECK (
            status IN (
                'pending',
                'accepted',
                'declined',
                'canceled',
                'expired'
            )
        ),
    CONSTRAINT managed_safety_request_expiry
        CHECK (
            expires_at > created_at
            AND expires_at <= created_at + interval '30 days'
            AND purge_after >= expires_at + interval '30 days'
        ),
    CONSTRAINT managed_safety_request_state
        CHECK (
            (status = 'pending' AND decided_at IS NULL)
            OR (status <> 'pending' AND decided_at IS NOT NULL)
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_safety_requests_pending_pair_idx
    ON managed_safety_requests (owner_profile_id, contact_profile_id)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS managed_safety_requests_contact_idx
    ON managed_safety_requests (
        contact_profile_id,
        status,
        created_at DESC
    );

CREATE INDEX IF NOT EXISTS managed_safety_requests_expiry_idx
    ON managed_safety_requests (expires_at, request_id)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS managed_safety_requests_purge_idx
    ON managed_safety_requests (purge_after, request_id);

DO $managed_safety_invite_request_fk$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'managed_safety_invite_request_fk'
          AND conrelid = 'managed_safety_invites'::regclass
    ) THEN
        ALTER TABLE managed_safety_invites
            ADD CONSTRAINT managed_safety_invite_request_fk
            FOREIGN KEY (safety_request_id)
            REFERENCES managed_safety_requests(request_id)
            ON DELETE SET NULL;
    END IF;
END
$managed_safety_invite_request_fk$;

CREATE TABLE IF NOT EXISTS managed_safety_contacts (
    owner_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    contact_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    accepted_request_id uuid NOT NULL
        REFERENCES managed_safety_requests(request_id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_profile_id, contact_profile_id),
    CONSTRAINT managed_safety_contact_distinct
        CHECK (owner_profile_id <> contact_profile_id)
);

CREATE INDEX IF NOT EXISTS managed_safety_contacts_contact_idx
    ON managed_safety_contacts (contact_profile_id, created_at DESC);

CREATE TABLE IF NOT EXISTS managed_safety_incidents (
    incident_id uuid PRIMARY KEY,
    owner_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    client_request_id uuid NOT NULL,
    trigger text NOT NULL,
    status text NOT NULL DEFAULT 'open',
    duration_hours integer NOT NULL,
    share_location boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    acknowledged_at timestamptz,
    ended_at timestamptz,
    purge_after timestamptz NOT NULL,
    CONSTRAINT managed_safety_incident_request_unique
        UNIQUE (owner_profile_id, client_request_id),
    CONSTRAINT managed_safety_incident_trigger
        CHECK (trigger = 'manual_sos'),
    CONSTRAINT managed_safety_incident_status
        CHECK (
            status IN (
                'open',
                'acknowledged',
                'resolved',
                'canceled',
                'expired'
            )
        ),
    CONSTRAINT managed_safety_incident_duration
        CHECK (duration_hours IN (8, 12)),
    CONSTRAINT managed_safety_incident_expiry
        CHECK (
            expires_at = created_at + duration_hours * interval '1 hour'
            AND purge_after >= expires_at + interval '30 days'
        ),
    CONSTRAINT managed_safety_incident_ack_order
        CHECK (
            acknowledged_at IS NULL
            OR acknowledged_at >= created_at
        ),
    CONSTRAINT managed_safety_incident_end_order
        CHECK (ended_at IS NULL OR ended_at >= created_at),
    CONSTRAINT managed_safety_incident_state
        CHECK (
            (status = 'open' AND acknowledged_at IS NULL AND ended_at IS NULL)
            OR (
                status = 'acknowledged'
                AND acknowledged_at IS NOT NULL
                AND ended_at IS NULL
            )
            OR (
                status IN ('resolved', 'canceled', 'expired')
                AND ended_at IS NOT NULL
            )
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_safety_incidents_active_owner_idx
    ON managed_safety_incidents (owner_profile_id)
    WHERE status IN ('open', 'acknowledged');

CREATE INDEX IF NOT EXISTS managed_safety_incidents_expiry_idx
    ON managed_safety_incidents (expires_at, incident_id)
    WHERE status IN ('open', 'acknowledged');

CREATE INDEX IF NOT EXISTS managed_safety_incidents_purge_idx
    ON managed_safety_incidents (purge_after, incident_id);

CREATE TABLE IF NOT EXISTS managed_safety_participants (
    incident_id uuid NOT NULL
        REFERENCES managed_safety_incidents(incident_id) ON DELETE CASCADE,
    contact_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'pending',
    paged_at timestamptz NOT NULL,
    responded_at timestamptz,
    PRIMARY KEY (incident_id, contact_profile_id),
    CONSTRAINT managed_safety_participant_status
        CHECK (
            status IN (
                'pending',
                'responding',
                'cannot_respond',
                'revoked'
            )
        ),
    CONSTRAINT managed_safety_participant_response_order
        CHECK (responded_at IS NULL OR responded_at >= paged_at),
    CONSTRAINT managed_safety_participant_state
        CHECK (
            (status = 'pending' AND responded_at IS NULL)
            OR (status <> 'pending' AND responded_at IS NOT NULL)
        )
);

CREATE INDEX IF NOT EXISTS managed_safety_participants_contact_idx
    ON managed_safety_participants (
        contact_profile_id,
        paged_at DESC
    );

CREATE TABLE IF NOT EXISTS managed_safety_locations (
    incident_id uuid PRIMARY KEY
        REFERENCES managed_safety_incidents(incident_id) ON DELETE CASCADE,
    sequence bigint NOT NULL,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    horizontal_accuracy_m double precision NOT NULL,
    captured_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_safety_location_sequence
        CHECK (sequence > 0),
    CONSTRAINT managed_safety_location_latitude
        CHECK (latitude BETWEEN -90 AND 90),
    CONSTRAINT managed_safety_location_longitude
        CHECK (longitude BETWEEN -180 AND 180),
    CONSTRAINT managed_safety_location_accuracy
        CHECK (horizontal_accuracy_m BETWEEN 0 AND 10000),
    CONSTRAINT managed_safety_location_order
        CHECK (received_at >= captured_at - interval '24 hours')
);

CREATE TABLE IF NOT EXISTS managed_safety_push_deliveries (
    delivery_id uuid PRIMARY KEY,
    incident_id uuid NOT NULL,
    contact_profile_id uuid NOT NULL,
    account_id uuid NOT NULL,
    installation_id text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    attempts integer NOT NULL DEFAULT 0,
    claim_id uuid,
    claim_expires_at timestamptz,
    last_attempt_at timestamptz,
    delivered_at timestamptz,
    provider_reference_hash char(64),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (incident_id, contact_profile_id, installation_id),
    FOREIGN KEY (incident_id, contact_profile_id)
        REFERENCES managed_safety_participants(incident_id, contact_profile_id)
        ON DELETE CASCADE,
    FOREIGN KEY (account_id, installation_id)
        REFERENCES managed_push_installations(account_id, installation_id)
        ON DELETE CASCADE,
    CONSTRAINT managed_safety_delivery_status
        CHECK (
            status IN (
                'pending',
                'sending',
                'sent',
                'invalid',
                'transient_failure',
                'unavailable',
                'rejected'
            )
        ),
    CONSTRAINT managed_safety_delivery_attempts
        CHECK (attempts BETWEEN 0 AND 3),
    CONSTRAINT managed_safety_delivery_reference
        CHECK (
            provider_reference_hash IS NULL
            OR provider_reference_hash ~ '^[0-9a-f]{64}$'
        ),
    CONSTRAINT managed_safety_delivery_state
        CHECK (
            (
                status = 'sending'
                AND claim_id IS NOT NULL
                AND claim_expires_at IS NOT NULL
                AND last_attempt_at IS NOT NULL
            )
            OR (
                status <> 'sending'
                AND claim_id IS NULL
                AND claim_expires_at IS NULL
            )
        )
);

CREATE INDEX IF NOT EXISTS managed_safety_push_delivery_queue_idx
    ON managed_safety_push_deliveries (
        incident_id,
        status,
        attempts,
        created_at
    );

CREATE INDEX IF NOT EXISTS managed_safety_push_retry_queue_idx
    ON managed_safety_push_deliveries (
        status,
        attempts,
        last_attempt_at,
        created_at,
        delivery_id
    )
    WHERE status IN ('pending', 'transient_failure', 'unavailable')
      AND attempts < 3;
