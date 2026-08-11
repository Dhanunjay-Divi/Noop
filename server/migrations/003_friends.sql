-- Private, invitation-only social sharing. Friend credentials are independent
-- of the server-wide sync/admin token and only their SHA-256 digests are stored.

CREATE TABLE IF NOT EXISTS friend_profiles (
    profile_id uuid PRIMARY KEY,
    enrollment_id uuid NOT NULL,
    display_name text NOT NULL,
    installation_id text NOT NULL,
    daily_device_id text NOT NULL,
    token_hash char(64) NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz,
    CONSTRAINT friend_profile_display_name_length
        CHECK (char_length(display_name) BETWEEN 1 AND 64),
    CONSTRAINT friend_profile_device_installation_scope
        CHECK (
            split_part(daily_device_id, ':', 1) IN ('ios', 'android', 'macos')
            AND split_part(daily_device_id, ':', 2) = installation_id
            AND split_part(daily_device_id, ':', 3) <> ''
        )
);

CREATE INDEX IF NOT EXISTS friend_profiles_daily_device_idx
    ON friend_profiles (daily_device_id)
    WHERE disabled_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS friend_profiles_one_active_installation_idx
    ON friend_profiles (installation_id)
    WHERE disabled_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS friend_profiles_enrollment_idx
    ON friend_profiles (enrollment_id);

CREATE TABLE IF NOT EXISTS friend_invites (
    invite_id uuid PRIMARY KEY,
    inviter_id uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    code_hash char(64) NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    redeemed_at timestamptz,
    redeemed_by uuid REFERENCES friend_profiles(profile_id) ON DELETE SET NULL,
    revoked_at timestamptz,
    CONSTRAINT friend_invite_expiry_ordered CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS friend_invites_active_code_idx
    ON friend_invites (code_hash)
    WHERE redeemed_at IS NULL AND revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS friend_requests (
    request_id uuid PRIMARY KEY,
    invite_id uuid NOT NULL UNIQUE REFERENCES friend_invites(invite_id) ON DELETE CASCADE,
    inviter_id uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    requester_id uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz,
    CONSTRAINT friend_request_distinct_profiles CHECK (inviter_id <> requester_id),
    CONSTRAINT friend_request_status
        CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled'))
);

CREATE UNIQUE INDEX IF NOT EXISTS friend_requests_one_pending_pair_idx
    ON friend_requests (
        LEAST(inviter_id, requester_id),
        GREATEST(inviter_id, requester_id)
    )
    WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS friendships (
    profile_a uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    profile_b uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (profile_a, profile_b),
    CONSTRAINT friendship_canonical_pair CHECK (profile_a < profile_b)
);

CREATE TABLE IF NOT EXISTS friend_visibility (
    owner_id uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    viewer_id uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    share_charge boolean NOT NULL DEFAULT true,
    share_effort boolean NOT NULL DEFAULT true,
    share_rest boolean NOT NULL DEFAULT true,
    share_sleep_duration boolean NOT NULL DEFAULT false,
    share_hrv boolean NOT NULL DEFAULT false,
    share_rhr boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_id, viewer_id),
    CONSTRAINT friend_visibility_distinct_profiles CHECK (owner_id <> viewer_id)
);

CREATE TABLE IF NOT EXISTS friend_blocks (
    blocker_id uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    blocked_id uuid NOT NULL REFERENCES friend_profiles(profile_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_id, blocked_id),
    CONSTRAINT friend_block_distinct_profiles CHECK (blocker_id <> blocked_id)
);

CREATE INDEX IF NOT EXISTS friend_blocks_blocked_idx
    ON friend_blocks (blocked_id, blocker_id);
