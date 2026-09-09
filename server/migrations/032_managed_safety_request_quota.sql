-- Bound Safety contact-request churn independently of request state. The
-- account-scoped ledger survives contact removal and social-profile
-- recreation, while request rows remain profile-scoped for access control.

CREATE TABLE IF NOT EXISTS managed_safety_request_quota_events (
    owner_account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE CASCADE,
    client_request_id uuid NOT NULL,
    safety_request_id uuid NOT NULL UNIQUE,
    contact_account_id uuid NOT NULL,
    source text NOT NULL,
    created_at timestamptz NOT NULL,
    purge_after timestamptz NOT NULL,
    PRIMARY KEY (owner_account_id, client_request_id),
    CONSTRAINT managed_safety_request_quota_source
        CHECK (source IN ('noop_id', 'invite')),
    CONSTRAINT managed_safety_request_quota_distinct_accounts
        CHECK (owner_account_id <> contact_account_id),
    CONSTRAINT managed_safety_request_quota_retention
        CHECK (purge_after >= created_at + interval '30 days')
);

CREATE INDEX IF NOT EXISTS managed_safety_request_quota_account_created_idx
    ON managed_safety_request_quota_events (
        owner_account_id,
        created_at DESC,
        client_request_id
    );

CREATE INDEX IF NOT EXISTS managed_safety_request_quota_purge_idx
    ON managed_safety_request_quota_events (
        purge_after,
        owner_account_id,
        client_request_id
    );

INSERT INTO managed_safety_request_quota_events (
    owner_account_id,
    client_request_id,
    safety_request_id,
    contact_account_id,
    source,
    created_at,
    purge_after
)
SELECT owner.account_id,
       request.client_request_id,
       request.request_id,
       contact.account_id,
       request.source,
       request.created_at,
       request.purge_after
FROM managed_safety_requests request
JOIN managed_social_profiles owner
  ON owner.profile_id = request.owner_profile_id
JOIN managed_social_profiles contact
  ON contact.profile_id = request.contact_profile_id
ON CONFLICT DO NOTHING;
