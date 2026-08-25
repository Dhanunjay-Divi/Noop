-- Safety incident origin, bounded evidence, long-lived latest-only location,
-- and independently retryable acknowledgement escalation rounds.

ALTER TABLE safety_dispatches
    DROP CONSTRAINT IF EXISTS safety_dispatch_trigger;

ALTER TABLE safety_dispatches
    ADD CONSTRAINT safety_dispatch_trigger
        CHECK (trigger IN ('manual_sos', 'band_sos', 'validated_fall')),
    ADD COLUMN IF NOT EXISTS share_duration_hours smallint,
    ADD COLUMN IF NOT EXISTS evidence jsonb,
    ADD COLUMN IF NOT EXISTS escalation_rounds smallint,
    ADD COLUMN IF NOT EXISTS escalation_interval_seconds integer;

ALTER TABLE safety_dispatches
    ADD CONSTRAINT safety_dispatch_share_duration
        CHECK (share_duration_hours IS NULL OR share_duration_hours IN (8, 12)),
    ADD CONSTRAINT safety_dispatch_evidence_object
        CHECK (evidence IS NULL OR jsonb_typeof(evidence) = 'object'),
    ADD CONSTRAINT safety_dispatch_evidence_origin
        CHECK (
            (trigger = 'validated_fall' AND evidence IS NOT NULL)
            OR (trigger <> 'validated_fall' AND evidence IS NULL)
        ),
    ADD CONSTRAINT safety_dispatch_escalation_rounds
        CHECK (escalation_rounds IS NULL OR escalation_rounds BETWEEN 1 AND 8),
    ADD CONSTRAINT safety_dispatch_escalation_interval
        CHECK (
            escalation_interval_seconds IS NULL
            OR escalation_interval_seconds BETWEEN 60 AND 86400
        );

ALTER TABLE safety_deliveries
    ADD COLUMN IF NOT EXISTS escalation_round smallint NOT NULL DEFAULT 0;

ALTER TABLE safety_deliveries
    ADD CONSTRAINT safety_delivery_escalation_round
        CHECK (escalation_round BETWEEN 0 AND 7);

ALTER TABLE safety_deliveries
    DROP CONSTRAINT IF EXISTS safety_deliveries_dispatch_id_contact_id_channel_key;

ALTER TABLE safety_deliveries
    ADD CONSTRAINT safety_delivery_round_unique
        UNIQUE (dispatch_id, contact_id, channel, escalation_round);

CREATE INDEX IF NOT EXISTS safety_deliveries_dispatch_round_idx
    ON safety_deliveries (dispatch_id, escalation_round, available_at);

CREATE UNIQUE INDEX IF NOT EXISTS safety_dispatches_fall_event_unique
    ON safety_dispatches (profile_id, (evidence ->> 'event_id'))
    WHERE trigger = 'validated_fall';
