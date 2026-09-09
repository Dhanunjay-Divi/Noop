-- Preserve manual Safety paging abuse controls across social-profile deletion
-- and recreation. Incidents remain profile-scoped for participant access, but
-- the account-scoped quota ledger survives those profile cascades.

CREATE TABLE IF NOT EXISTS managed_safety_page_quota_events (
    owner_account_id uuid NOT NULL
        REFERENCES managed_accounts(account_id) ON DELETE CASCADE,
    client_request_id uuid NOT NULL,
    incident_id uuid NOT NULL UNIQUE,
    duration_hours integer NOT NULL,
    share_location boolean NOT NULL,
    created_at timestamptz NOT NULL,
    purge_after timestamptz NOT NULL,
    PRIMARY KEY (owner_account_id, client_request_id),
    CONSTRAINT managed_safety_page_quota_duration
        CHECK (duration_hours IN (8, 12)),
    CONSTRAINT managed_safety_page_quota_retention
        CHECK (purge_after >= created_at + interval '30 days')
);

CREATE INDEX IF NOT EXISTS managed_safety_page_quota_account_created_idx
    ON managed_safety_page_quota_events (
        owner_account_id,
        created_at DESC,
        client_request_id
    );

CREATE INDEX IF NOT EXISTS managed_safety_page_quota_purge_idx
    ON managed_safety_page_quota_events (purge_after, owner_account_id);

INSERT INTO managed_safety_page_quota_events (
    owner_account_id,
    client_request_id,
    incident_id,
    duration_hours,
    share_location,
    created_at,
    purge_after
)
SELECT profile.account_id,
       incident.client_request_id,
       incident.incident_id,
       incident.duration_hours,
       incident.share_location,
       incident.created_at,
       incident.purge_after
FROM managed_safety_incidents incident
JOIN managed_social_profiles profile
  ON profile.profile_id = incident.owner_profile_id
ON CONFLICT DO NOTHING;
