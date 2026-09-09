-- Bound Safety invitation churn independently of active-row count. The
-- account-scoped ledger survives social-profile deletion and recreation, while
-- invite rows remain profile-scoped for access and lifecycle enforcement.

CREATE TABLE IF NOT EXISTS managed_safety_invite_quota_events (
    owner_account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE CASCADE,
    client_request_id uuid NOT NULL,
    invite_id uuid NOT NULL UNIQUE,
    capability_hash char(64) NOT NULL UNIQUE,
    created_at timestamptz NOT NULL,
    purge_after timestamptz NOT NULL,
    PRIMARY KEY (owner_account_id, client_request_id),
    CONSTRAINT managed_safety_invite_quota_digest
        CHECK (capability_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT managed_safety_invite_quota_retention
        CHECK (purge_after >= created_at + interval '30 days')
);

CREATE INDEX IF NOT EXISTS managed_safety_invite_quota_account_created_idx
    ON managed_safety_invite_quota_events (
        owner_account_id,
        created_at DESC,
        client_request_id
    );

CREATE INDEX IF NOT EXISTS managed_safety_invite_quota_purge_idx
    ON managed_safety_invite_quota_events (purge_after, owner_account_id);

INSERT INTO managed_safety_invite_quota_events (
    owner_account_id,
    client_request_id,
    invite_id,
    capability_hash,
    created_at,
    purge_after
)
SELECT profile.account_id,
       invite.creation_request_id,
       invite.invite_id,
       invite.capability_hash,
       invite.created_at,
       invite.purge_after
FROM managed_safety_invites invite
JOIN managed_social_profiles profile
  ON profile.profile_id = invite.owner_profile_id
ON CONFLICT DO NOTHING;
