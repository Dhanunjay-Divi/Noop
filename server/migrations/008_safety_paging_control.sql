-- Durable operator control for outbound Safety paging.
--
-- The switch defaults on to preserve existing deployments. It is checked
-- before invitations/pages are accepted, while queue rows are claimed, and
-- immediately before a leased delivery is submitted to the provider.

CREATE TABLE IF NOT EXISTS safety_runtime_controls (
    control_name text PRIMARY KEY,
    enabled boolean NOT NULL,
    reason text,
    revision bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL,
    CONSTRAINT safety_runtime_control_name
        CHECK (control_name IN ('paging')),
    CONSTRAINT safety_runtime_control_reason_length
        CHECK (reason IS NULL OR char_length(reason) <= 160),
    CONSTRAINT safety_runtime_control_revision
        CHECK (revision > 0)
);

INSERT INTO safety_runtime_controls (
    control_name, enabled, reason, revision, updated_at
)
VALUES ('paging', TRUE, NULL, 1, now())
ON CONFLICT (control_name) DO NOTHING;

CREATE TABLE IF NOT EXISTS safety_runtime_control_audit (
    control_name text NOT NULL,
    revision bigint NOT NULL,
    enabled boolean NOT NULL,
    reason text,
    changed_at timestamptz NOT NULL,
    PRIMARY KEY (control_name, revision),
    CONSTRAINT safety_runtime_control_audit_name
        CHECK (control_name IN ('paging')),
    CONSTRAINT safety_runtime_control_audit_reason_length
        CHECK (reason IS NULL OR char_length(reason) <= 160),
    CONSTRAINT safety_runtime_control_audit_revision
        CHECK (revision > 0)
);

INSERT INTO safety_runtime_control_audit (
    control_name, revision, enabled, reason, changed_at
)
SELECT control_name, revision, enabled, reason, updated_at
FROM safety_runtime_controls
WHERE control_name = 'paging'
ON CONFLICT (control_name, revision) DO NOTHING;

ALTER TABLE safety_contacts
    DROP CONSTRAINT IF EXISTS safety_contact_delivery_status;

ALTER TABLE safety_contacts
    ADD CONSTRAINT safety_contact_delivery_status
        CHECK (
            invitation_delivery_status IN (
                'pending', 'queued', 'sent', 'delivered', 'failed', 'unknown'
            )
        );

CREATE TABLE IF NOT EXISTS safety_worker_heartbeats (
    worker_id text PRIMARY KEY,
    started_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    CONSTRAINT safety_worker_id_length
        CHECK (char_length(worker_id) BETWEEN 1 AND 128),
    CONSTRAINT safety_worker_heartbeat_order
        CHECK (last_seen_at >= started_at)
);

CREATE INDEX IF NOT EXISTS safety_worker_heartbeats_seen_idx
    ON safety_worker_heartbeats (last_seen_at);

-- All delivery channels have exhausted only when the worker/provider has
-- explicitly failed them. This is a terminal incident state, distinct from an
-- unconfirmed provider receipt or normal expiry.
ALTER TABLE safety_dispatches
    DROP CONSTRAINT IF EXISTS safety_dispatch_status;

ALTER TABLE safety_dispatches
    ADD CONSTRAINT safety_dispatch_status
        CHECK (
            status IN (
                'open', 'acknowledged', 'resolved', 'cancelled', 'expired',
                'failed'
            )
        );
