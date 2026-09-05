-- Optional managed Friends for NOOP+ accounts. Core NOOP and self-hosted
-- Friends do not depend on these tables. Invitation capabilities are stored
-- only as digests. Social summaries are a six-field projection and never
-- contain raw samples, locations, journals, workouts, routes, sleep stages, or
-- device identifiers.

CREATE TABLE IF NOT EXISTS managed_social_profiles (
    profile_id uuid PRIMARY KEY,
    account_id uuid NOT NULL UNIQUE
        REFERENCES managed_accounts(account_id) ON DELETE CASCADE,
    creation_request_id uuid NOT NULL,
    display_name text NOT NULL,
    status text NOT NULL DEFAULT 'active',
    poke_opt_in boolean NOT NULL DEFAULT false,
    quiet_start_minute integer NOT NULL DEFAULT 1320,
    quiet_end_minute integer NOT NULL DEFAULT 420,
    time_zone text NOT NULL DEFAULT 'UTC',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_social_profile_creation_request_unique
        UNIQUE (account_id, creation_request_id),
    CONSTRAINT managed_social_profile_name
        CHECK (
            length(display_name) BETWEEN 1 AND 64
            AND display_name = btrim(display_name)
            AND display_name !~ '[[:cntrl:]]'
        ),
    CONSTRAINT managed_social_profile_status
        CHECK (status IN ('active', 'disabled')),
    CONSTRAINT managed_social_profile_quiet_start
        CHECK (quiet_start_minute BETWEEN 0 AND 1439),
    CONSTRAINT managed_social_profile_quiet_end
        CHECK (quiet_end_minute BETWEEN 0 AND 1439),
    CONSTRAINT managed_social_profile_time_zone
        CHECK (
            length(time_zone) BETWEEN 1 AND 64
            AND (
                time_zone ~ '^[A-Za-z0-9][A-Za-z0-9_+./:-]{0,63}$'
                OR time_zone ~ '^[+-][0-9]{2}:[0-9]{2}$'
            )
        ),
    CONSTRAINT managed_social_profile_updated_order
        CHECK (updated_at >= created_at)
);

CREATE INDEX IF NOT EXISTS managed_social_profiles_status_idx
    ON managed_social_profiles (status, updated_at);

CREATE TABLE IF NOT EXISTS managed_social_aliases (
    alias_id uuid PRIMARY KEY,
    profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    alias_value text NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    purge_after timestamptz,
    CONSTRAINT managed_social_alias_value
        CHECK (
            alias_value
            ~ '^NOOP-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$'
        ),
    CONSTRAINT managed_social_alias_status
        CHECK (status IN ('active', 'revoked')),
    CONSTRAINT managed_social_alias_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= created_at),
    CONSTRAINT managed_social_alias_status_time
        CHECK (
            (status = 'active' AND revoked_at IS NULL AND purge_after IS NULL)
            OR (
                status = 'revoked'
                AND revoked_at IS NOT NULL
                AND purge_after IS NOT NULL
                AND purge_after >= revoked_at
            )
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_social_aliases_active_profile_idx
    ON managed_social_aliases (profile_id)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS managed_social_aliases_purge_idx
    ON managed_social_aliases (purge_after, alias_id)
    WHERE status = 'revoked';

CREATE TABLE IF NOT EXISTS managed_social_invites (
    invite_id uuid PRIMARY KEY,
    inviter_profile_id uuid NOT NULL
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
    friend_request_id uuid,
    CONSTRAINT managed_social_invite_creation_request_unique
        UNIQUE (inviter_profile_id, creation_request_id),
    CONSTRAINT managed_social_invite_digest
        CHECK (capability_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_social_invite_status
        CHECK (status IN ('active', 'revoked', 'redeemed', 'expired')),
    CONSTRAINT managed_social_invite_expiry
        CHECK (
            expires_at > created_at
            AND expires_at <= created_at + interval '168 hours'
        ),
    CONSTRAINT managed_social_invite_revoked_order
        CHECK (revoked_at IS NULL OR revoked_at >= created_at),
    CONSTRAINT managed_social_invite_redeemed_order
        CHECK (redeemed_at IS NULL OR redeemed_at >= created_at),
    CONSTRAINT managed_social_invite_state
        CHECK (
            (status = 'active' AND revoked_at IS NULL AND redeemed_at IS NULL)
            OR (status = 'revoked' AND revoked_at IS NOT NULL)
            OR (status = 'redeemed' AND redeemed_at IS NOT NULL)
            OR status = 'expired'
        )
);

CREATE INDEX IF NOT EXISTS managed_social_invites_owner_idx
    ON managed_social_invites (
        inviter_profile_id,
        status,
        expires_at DESC
    );

CREATE INDEX IF NOT EXISTS managed_social_invites_expiry_idx
    ON managed_social_invites (expires_at, invite_id)
    WHERE status = 'active';

CREATE TABLE IF NOT EXISTS managed_social_requests (
    request_id uuid PRIMARY KEY,
    client_request_id uuid NOT NULL,
    sender_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    recipient_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    invite_id uuid
        REFERENCES managed_social_invites(invite_id) ON DELETE SET NULL,
    source text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz,
    expires_at timestamptz NOT NULL,
    CONSTRAINT managed_social_request_client_unique
        UNIQUE (sender_profile_id, client_request_id),
    CONSTRAINT managed_social_request_distinct
        CHECK (sender_profile_id <> recipient_profile_id),
    CONSTRAINT managed_social_request_source
        CHECK (source IN ('noop_id', 'invite')),
    CONSTRAINT managed_social_request_status
        CHECK (
            status IN (
                'pending',
                'accepted',
                'declined',
                'canceled',
                'expired'
            )
        ),
    CONSTRAINT managed_social_request_expiry
        CHECK (
            expires_at > created_at
            AND expires_at <= created_at + interval '30 days'
        ),
    CONSTRAINT managed_social_request_decided_order
        CHECK (decided_at IS NULL OR decided_at >= created_at),
    CONSTRAINT managed_social_request_state
        CHECK (
            (status = 'pending' AND decided_at IS NULL)
            OR (status <> 'pending' AND decided_at IS NOT NULL)
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS managed_social_requests_pending_pair_idx
    ON managed_social_requests (
        LEAST(sender_profile_id, recipient_profile_id),
        GREATEST(sender_profile_id, recipient_profile_id)
    )
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS managed_social_requests_recipient_idx
    ON managed_social_requests (
        recipient_profile_id,
        status,
        created_at DESC
    );

CREATE INDEX IF NOT EXISTS managed_social_requests_expiry_idx
    ON managed_social_requests (expires_at, request_id)
    WHERE status = 'pending';

ALTER TABLE managed_social_invites
    ADD CONSTRAINT managed_social_invite_friend_request_fk
    FOREIGN KEY (friend_request_id)
    REFERENCES managed_social_requests(request_id)
    ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS managed_social_friendships (
    friendship_id uuid PRIMARY KEY,
    profile_low_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    profile_high_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    accepted_request_id uuid NOT NULL
        REFERENCES managed_social_requests(request_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT managed_social_friendship_pair_unique
        UNIQUE (profile_low_id, profile_high_id),
    CONSTRAINT managed_social_friendship_order
        CHECK (profile_low_id < profile_high_id)
);

CREATE INDEX IF NOT EXISTS managed_social_friendships_high_idx
    ON managed_social_friendships (profile_high_id, created_at DESC);

CREATE TABLE IF NOT EXISTS managed_social_visibility (
    owner_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    reader_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    charge boolean NOT NULL DEFAULT false,
    effort boolean NOT NULL DEFAULT false,
    rest boolean NOT NULL DEFAULT false,
    sleep_duration boolean NOT NULL DEFAULT false,
    hrv boolean NOT NULL DEFAULT false,
    rhr boolean NOT NULL DEFAULT false,
    poke_allowed boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_profile_id, reader_profile_id),
    CONSTRAINT managed_social_visibility_distinct
        CHECK (owner_profile_id <> reader_profile_id)
);

CREATE TABLE IF NOT EXISTS managed_social_blocks (
    blocker_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    blocked_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_profile_id, blocked_profile_id),
    CONSTRAINT managed_social_block_distinct
        CHECK (blocker_profile_id <> blocked_profile_id)
);

CREATE INDEX IF NOT EXISTS managed_social_blocks_target_idx
    ON managed_social_blocks (blocked_profile_id, blocker_profile_id);

CREATE TABLE IF NOT EXISTS managed_social_daily_summaries (
    profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    day date NOT NULL,
    request_id uuid NOT NULL,
    charge double precision,
    effort double precision,
    rest double precision,
    sleep_duration double precision,
    hrv double precision,
    rhr double precision,
    revision bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (profile_id, day),
    CONSTRAINT managed_social_summary_request_unique
        UNIQUE (profile_id, request_id),
    CONSTRAINT managed_social_summary_charge
        CHECK (charge IS NULL OR charge BETWEEN 0 AND 100),
    CONSTRAINT managed_social_summary_effort
        CHECK (effort IS NULL OR effort BETWEEN 0 AND 100),
    CONSTRAINT managed_social_summary_rest
        CHECK (rest IS NULL OR rest BETWEEN 0 AND 100),
    CONSTRAINT managed_social_summary_sleep
        CHECK (
            sleep_duration IS NULL
            OR sleep_duration BETWEEN 0 AND 2880
        ),
    CONSTRAINT managed_social_summary_hrv
        CHECK (hrv IS NULL OR hrv BETWEEN 0 AND 1000),
    CONSTRAINT managed_social_summary_rhr
        CHECK (rhr IS NULL OR rhr BETWEEN 20 AND 260),
    CONSTRAINT managed_social_summary_revision
        CHECK (revision > 0)
);

CREATE INDEX IF NOT EXISTS managed_social_daily_summaries_day_idx
    ON managed_social_daily_summaries (profile_id, day DESC);

CREATE TABLE IF NOT EXISTS managed_social_badges (
    profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    badge_code text NOT NULL,
    earned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (profile_id, badge_code),
    CONSTRAINT managed_social_badge_code
        CHECK (
            badge_code IN (
                'connected',
                'steady_week',
                'steady_month'
            )
        )
);

CREATE TABLE IF NOT EXISTS managed_social_pokes (
    poke_id uuid PRIMARY KEY,
    request_id uuid NOT NULL,
    sender_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    recipient_profile_id uuid NOT NULL
        REFERENCES managed_social_profiles(profile_id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'queued',
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    claim_id uuid,
    claimed_installation_id text,
    claimed_at timestamptz,
    claim_expires_at timestamptz,
    acknowledged_at timestamptz,
    notification_outcome text,
    haptic_outcome text,
    CONSTRAINT managed_social_poke_request_unique
        UNIQUE (sender_profile_id, request_id),
    CONSTRAINT managed_social_poke_distinct
        CHECK (sender_profile_id <> recipient_profile_id),
    CONSTRAINT managed_social_poke_status
        CHECK (status IN ('queued', 'claimed', 'acknowledged', 'expired')),
    CONSTRAINT managed_social_poke_expiry
        CHECK (
            expires_at > created_at
            AND expires_at <= created_at + interval '24 hours'
        ),
    CONSTRAINT managed_social_poke_claim_order
        CHECK (
            claimed_at IS NULL
            OR (
                claimed_at >= created_at
                AND claim_expires_at > claimed_at
                AND claim_expires_at <= expires_at
            )
        ),
    CONSTRAINT managed_social_poke_ack_order
        CHECK (
            acknowledged_at IS NULL
            OR (claimed_at IS NOT NULL AND acknowledged_at >= claimed_at)
        ),
    CONSTRAINT managed_social_poke_notification_outcome
        CHECK (
            notification_outcome IS NULL
            OR notification_outcome IN (
                'scheduled',
                'not_authorized',
                'failed'
            )
        ),
    CONSTRAINT managed_social_poke_haptic_outcome
        CHECK (
            haptic_outcome IS NULL
            OR haptic_outcome IN (
                'requested',
                'band_unavailable',
                'not_eligible',
                'failed'
            )
        ),
    CONSTRAINT managed_social_poke_state
        CHECK (
            (
                status = 'queued'
                AND claim_id IS NULL
                AND claimed_installation_id IS NULL
                AND claimed_at IS NULL
                AND claim_expires_at IS NULL
                AND acknowledged_at IS NULL
            )
            OR (
                status = 'claimed'
                AND claim_id IS NOT NULL
                AND claimed_installation_id IS NOT NULL
                AND claimed_at IS NOT NULL
                AND claim_expires_at IS NOT NULL
                AND acknowledged_at IS NULL
            )
            OR (
                status = 'acknowledged'
                AND claim_id IS NOT NULL
                AND claimed_installation_id IS NOT NULL
                AND claimed_at IS NOT NULL
                AND claim_expires_at IS NOT NULL
                AND acknowledged_at IS NOT NULL
                AND notification_outcome IS NOT NULL
                AND haptic_outcome IS NOT NULL
            )
            OR status = 'expired'
        )
);

CREATE INDEX IF NOT EXISTS managed_social_pokes_recipient_queue_idx
    ON managed_social_pokes (
        recipient_profile_id,
        status,
        created_at,
        poke_id
    );

CREATE INDEX IF NOT EXISTS managed_social_pokes_sender_rate_idx
    ON managed_social_pokes (sender_profile_id, created_at DESC);

CREATE INDEX IF NOT EXISTS managed_social_pokes_pair_rate_idx
    ON managed_social_pokes (
        sender_profile_id,
        recipient_profile_id,
        created_at DESC
    );

CREATE INDEX IF NOT EXISTS managed_social_pokes_expiry_idx
    ON managed_social_pokes (expires_at, poke_id)
    WHERE status IN ('queued', 'claimed');
